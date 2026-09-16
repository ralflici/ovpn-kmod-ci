# SPDX-License-Identifier: GPL-2.0
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("patchwork_ci", Path(__file__).resolve().parents[1] / "scripts/patchwork_ci.py")
ci = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci)


def mail(subject, body="Message\n"):
    return f"From: Author <author@example.org>\nSubject: {subject}\n\n{body}".encode()


class SubmissionTests(unittest.TestCase):
    def test_target_tokens_and_default(self):
        for subject, target in [("[PATCH] fix internet", "net-next"),
                                ("[RFC ovpn net-next v3 1/9] foo", "net-next"),
                                ("[Openvpn-devel,PATCH,net,1/2] foo", "net")]:
            self.assertEqual(ci.target_and_base([mail(subject)]), (target, None))
        with self.assertRaisesRegex(ValueError, "Conflicting net"):
            ci.target_and_base([mail("[PATCH net] one"), mail("[PATCH net-next] two")])

    def test_declared_base_in_cover_and_invalid_declarations(self):
        base = "a" * 40
        self.assertEqual(ci.target_and_base([mail("[PATCH 0/2] cover", f"base-commit: {base}\n"),
                                             mail("[PATCH 1/2] first")]), ("net-next", base))
        with self.assertRaisesRegex(ValueError, "full commit"):
            ci.target_and_base([mail("[PATCH] test", "base-commit: abc123\n")])
        with self.assertRaisesRegex(ValueError, "Conflicting base"):
            ci.target_and_base([mail("[PATCH] test", f"base-commit: {base}\nbase-commit: {'b' * 40}\n")])

    def test_mime_encoded_mail(self):
        raw = (b"Subject: [PATCH net] test\nContent-Type: text/plain; charset=utf-8\n"
               b"Content-Transfer-Encoding: quoted-printable\n\nbase-commit: " + b"a" * 40 + b"\n")
        self.assertEqual(ci.target_and_base([raw]), ("net", "a" * 40))

    def test_order_and_reject_missing_or_duplicate_numbering(self):
        first, second = ("first", mail("[PATCH 1/2] A")), ("second", mail("[PATCH 2/2] B"))
        self.assertEqual(ci.ordered_patches([second, first]), [first, second])
        for invalid in ([first, first], [first, ("other", mail("[PATCH] other"))]):
            with self.assertRaises(ValueError):
                ci.ordered_patches(invalid)

    def test_results_preserve_warning_and_map_patchwork_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory) / "1/1/checkpatch"
            result.mkdir(parents=True)
            (result / "retcode").write_text("250")
            records = ci.read_results(directory, {"id": 4064, "patches": [{"index": 1, "id": 5357}]},
                                      ["checkpatch", "missing"], ["ynl"])
            self.assertEqual([r["state"] for r in records], ["fail", "warning", "fail"])
            self.assertEqual(records[1]["id"], 5357)

    def test_checkout_applies_cumulative_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin = root / "origin"
            origin.mkdir()
            ci.git(origin, "init", "--quiet")
            ci.git(origin, "config", "user.name", "Test")
            ci.git(origin, "config", "user.email", "test@example.org")
            (origin / "value").write_text("base\n")
            ci.git(origin, "add", "value")
            ci.git(origin, "commit", "-qm", "base")
            base = ci.git(origin, "rev-parse", "HEAD")
            submission = root / "submission"
            patches = submission / "patches"
            patches.mkdir(parents=True)
            entries = []
            for index in (1, 2):
                (origin / "value").write_text(f"patch {index}\n")
                ci.git(origin, "commit", "-qam", f"patch {index}")
                filename = f"{index}.patch"
                (patches / filename).write_text(ci.git(origin, "format-patch", "-1", "--stdout") + "\n")
                entries.append({"index": index, "id": 100 + index, "subject": f"patch {index}", "file": filename})
            (submission / "manifest.json").write_text(json.dumps({"base": base,
                "kernel_repository": str(origin), "patches": entries}))
            for through in (1, 2):
                source = root / f"checkout-{through}"
                ci.checkout(submission, source, through)
                self.assertEqual((source / "value").read_text(), f"patch {through}\n")
                self.assertEqual(int(ci.git(source, "rev-list", "--count", f"{base}..HEAD")), through)

    def test_prepare_freezes_base_and_keeps_cover_separate(self):
        data = {"received_all": True, "received_total": 2, "total": 2,
                "cover_letter": {"mbox": "cover"}, "web_url": "https://patchwork.test/series/9/",
                "patches": [{"id": 12, "mbox": "second"}, {"id": 11, "mbox": "first"}]}
        emails = {"cover": mail("[PATCH net-next 0/2] cover"),
                  "first": mail("[PATCH net-next 1/2] first"), "second": mail("[PATCH net-next 2/2] second")}
        with tempfile.TemporaryDirectory() as directory, patch.object(ci, "get_object", return_value=data), \
                patch.object(ci, "fetch", side_effect=emails.__getitem__), \
                patch.object(subprocess, "check_output", return_value=f"{'a' * 40}\trefs/heads/main\n"):
            output = Path(directory) / "submission"
            manifest = ci.prepare("series", 9, output, 1)
            self.assertEqual(manifest["base"], "a" * 40)
            self.assertEqual([p["id"] for p in manifest["patches"]], [11, 12])
            self.assertEqual(len(list((output / "patches").iterdir())), 3)


class GuestResultTests(unittest.TestCase):
    def run_guest(self, tap, make_status=0):
        with tempfile.TemporaryDirectory() as directory:
            fake_make = Path(directory) / "make"
            fake_make.write_text('#!/bin/sh\n[ "$1" = headers ] && exit 0\n'
                                 'printf "%s\\n" "$TEST_TAP"\nexit "$TEST_MAKE_STATUS"\n')
            fake_make.chmod(0o755)
            script = Path(__file__).resolve().parents[1] / "scripts/run-kselftests-guest.sh"
            env = {**os.environ, "PATH": f"{directory}:{os.environ['PATH']}",
                   "TEST_TAP": tap, "TEST_MAKE_STATUS": str(make_status)}
            return subprocess.run(["bash", str(script)], env=env, text=True,
                                  capture_output=True, check=False)

    def test_passing_guest_produces_marker(self):
        result = self.run_guest("TAP version 13\n1..1\nok 1 basic")
        self.assertEqual(result.returncode, 0)
        self.assertIn("OVPN_CI_SELFTESTS_PASSED", result.stdout)

    def test_failure_missing_results_and_all_skipped_fail(self):
        for tap, status in [("not ok 1 basic", 0), ("ok 1 basic\n# not ok 2 nested", 0),
                            ("ok 1 basic", 2), ("ok 1 basic # SKIP unavailable", 0),
                            ("no TAP output", 0)]:
            with self.subTest(tap=tap, status=status):
                result = self.run_guest(tap, status)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("OVPN_CI_SELFTESTS_PASSED", result.stdout)


if __name__ == "__main__":
    unittest.main()
