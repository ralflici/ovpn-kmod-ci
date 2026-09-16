#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Prepare Patchwork submissions and adapt NIPA's local runner to Actions.

The workflow uses three separate directories, relative to its working directory:
  submission/  Downloaded emails and manifest.json, shared between jobs as an artifact.
  source/      A Linux kernel checkout, created independently in each test job.
  nipa/        NIPA's own checkout, supplied by actions/checkout in the NIPA job.

The prepare command writes submission/. The checkout command creates source/
at the recorded base and optionally applies patches 1 through N. The nipa
command runs NIPA against a base checkout; NIPA applies the patches itself.
All directory names are caller-selected paths, not special keywords.
"""

import argparse
import email.policy
from email.parser import BytesParser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


PATCHWORK_API = "https://patchwork.openvpn.net/api/1.3"
KERNEL_REPOSITORY = "https://github.com/OpenVPN/ovpn-net-next.git"
NIPA_REVISION = "3bf66a684322168bfb175b000c728280f8e6961e"
PATCH_TESTS = [
    "check_selftest", "checkpatch", "deprecated_api", "header_inline", "kdoc",
    "pylint", "ruff", "shellcheck", "source_inline", "verify_fixes",
    "verify_signedoff", "yamllint",
]
SERIES_TESTS = ["series_format", "fixes_present", "maintainers", "ynl"]


def git(source, *args):
    return subprocess.check_output(
        ["git", "-C", str(source), *args], text=True,
    ).strip()


def fetch(url):
    # API-provided mbox URLs must stay on the configured Patchwork instance.
    if urlsplit(url).scheme != "https" or urlsplit(url).netloc != urlsplit(PATCHWORK_API).netloc:
        raise ValueError(f"Unexpected Patchwork URL: {url}")
    request = Request(url, headers={"User-Agent": "ovpn-patchwork-ci"})
    with urlopen(request, timeout=30) as response:
        return response.read()


def get_object(kind, ident):
    data = json.loads(fetch(f"{PATCHWORK_API}/{kind}/{ident}/"))
    if data["project"]["link_name"] != "ovpn":
        raise ValueError("Submission is not in the ovpn project")
    return data


def parse_mail(raw):
    message = BytesParser(policy=email.policy.default).parsebytes(raw)
    subject = " ".join(str(message.get("Subject", "")).split())
    body = message.get_body(preferencelist=("plain",))
    if body is None:
        raise ValueError("Submission has no plain-text email body")
    return subject, body.get_content()


def target_and_base(mails):
    targets, bases = set(), set()
    for raw in mails:
        subject, body = parse_mail(raw)
        for prefix in re.findall(r"\[([^]]*)\]", subject):
            targets.update(set(re.split(r"[,\s]+", prefix.lower())) & {"net", "net-next"})
        for line in body.splitlines():
            if line.startswith("base-commit:"):
                value = line.partition(":")[2].strip()
                if not re.fullmatch(r"[0-9a-fA-F]{40}", value):
                    raise ValueError("base-commit must contain a full commit SHA")
                bases.add(value.lower())
    if len(targets) > 1:
        raise ValueError("Conflicting net/net-next subject prefixes")
    if len(bases) > 1:
        raise ValueError("Conflicting base-commit declarations")
    return next(iter(targets), "net-next"), next(iter(bases), None)


def ordered_patches(patches):
    """Use the posted X/N numbering, not arrival order or Patchwork IDs."""
    if len(patches) == 1:
        return patches
    numbered = {}
    total = len(patches)
    for metadata, raw in patches:
        subject, _ = parse_mail(raw)
        prefixes = " ".join(re.findall(r"\[([^]]*)\]", subject))
        match = re.search(r"(?<!\d)(\d+)/(\d+)(?!\d)", prefixes)
        if not match or int(match[2]) != total:
            raise ValueError("Missing or inconsistent series numbering")
        index = int(match[1])
        if index in numbered or not 1 <= index <= total:
            raise ValueError("Duplicate or invalid series position")
        numbered[index] = (metadata, raw)
    return [numbered[index] for index in range(1, total + 1)]


def prepare(kind, ident, output, event_id=None):
    data = get_object("series" if kind == "series" else "patches", ident)
    cover = None
    if kind == "series":
        if not data["received_all"] or data["received_total"] != data["total"]:
            raise ValueError("Series is incomplete")
        if data["cover_letter"]:
            cover = fetch(data["cover_letter"]["mbox"])
        patches = [(patch, fetch(patch["mbox"])) for patch in data["patches"]]
    else:
        if data.get("series"):
            raise ValueError("Patch belongs to a series; dispatch its series ID instead")
        patches = [(data, fetch(data["mbox"]))]
    if not 1 <= len(patches) <= 256:
        raise ValueError("Expected 1 to 256 patches (Actions matrix limit)")
    patches = ordered_patches(patches)
    mails = ([cover] if cover else []) + [raw for _, raw in patches]
    target, base = target_and_base(mails)
    branch = "net" if target == "net" else "main"
    declared_base = base is not None
    if base is None:
        refs = subprocess.check_output(
            ["git", "ls-remote", "--exit-code", KERNEL_REPOSITORY, f"refs/heads/{branch}"],
            text=True,
        ).split()
        base = refs[0]
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("Could not resolve base SHA")

    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    maildir = output / "patches"
    maildir.mkdir()
    if cover:
        (maildir / "0000-cover.patch").write_bytes(cover)
    entries = []
    for index, (metadata, raw) in enumerate(patches, 1):
        filename = f"{index:04d}-{int(metadata['id'])}.patch"
        (maildir / filename).write_bytes(raw)
        entries.append({"index": index, "id": metadata["id"],
                        "subject": parse_mail(raw)[0], "file": filename})
    manifest = {
        "kind": kind, "id": ident, "patchwork_event_id": event_id,
        "url": data["web_url"], "target": target, "branch": branch,
        "base": base, "declared_base": declared_base,
        "kernel_repository": KERNEL_REPOSITORY, "nipa_revision": NIPA_REVISION,
        "patches": entries,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    outputs = {"matrix": json.dumps({"include": [{"index": p["index"], "id": p["id"]} for p in entries]}),
               "nipa_revision": NIPA_REVISION}
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            for key, value in outputs.items():
                handle.write(f"{key}={value}\n")
    print(json.dumps(manifest, indent=2))
    return manifest


def checkout(submission, source, through):
    submission, source = Path(submission).resolve(), Path(source).resolve()
    manifest = json.loads((submission / "manifest.json").read_text())
    if not 0 <= through <= len(manifest["patches"]):
        raise ValueError("Patch index outside this submission")
    source.mkdir(parents=True, exist_ok=False)
    git(source, "init", "--quiet")
    git(source, "config", "user.name", "OVPN CI")
    git(source, "config", "user.email", "ci@openvpn.invalid")
    git(source, "remote", "add", "origin", manifest["kernel_repository"])
    # Keep commit history for NIPA's Fixes validation; fetch blobs on demand.
    git(source, "fetch", "--no-tags", "--filter=blob:none", "origin", manifest["base"])
    git(source, "checkout", "-b", "ci-base", manifest["base"])
    for patch in manifest["patches"][:through]:
        print(f"Applying {patch['index']}: {patch['subject']}", flush=True)
        git(source, "am", "-s", "--", str(submission / "patches" / patch["file"]))
    print(f"Base: {manifest['base']}\nHEAD: {git(source, 'rev-parse', 'HEAD')}")
    print(f"Tree: {git(source, 'rev-parse', 'HEAD^{tree}')}")


def read_results(results, manifest, patch_tests, series_tests):
    """ingest_mdir assigns local sequential IDs; translate back to Patchwork IDs."""
    root = Path(results) / "1"
    records = []
    expected = [(root / name, "series", manifest["id"], name) for name in series_tests]
    for patch in manifest["patches"]:
        expected.extend((root / str(patch["index"]) / name, "patch", patch["id"], name)
                        for name in patch_tests)
    for directory, kind, ident, name in expected:
        try:
            code = int((directory / "retcode").read_text().strip())
        except (FileNotFoundError, ValueError):
            code = 1
        description = directory / "desc"
        state = {0: "success", 250: "warning"}.get(code, "fail")
        records.append({"kind": kind, "id": ident, "test": name, "state": state,
                        "description": description.read_text().strip() if description.exists()
                        else "See test output; missing results are failures"})
    return records


def run_nipa(submission, source, nipa, results):
    submission, source = Path(submission).resolve(), Path(source).resolve()
    nipa, results = Path(nipa).resolve(), Path(results).resolve()
    manifest = json.loads((submission / "manifest.json").read_text())
    if git(nipa, "rev-parse", "HEAD") != manifest["nipa_revision"]:
        raise ValueError("NIPA checkout does not match the prepared revision")
    results.mkdir(parents=True, exist_ok=False)
    series_tests = SERIES_TESTS if manifest["kind"] == "series" else []
    tests = [f"patch/{name}" for name in PATCH_TESTS] + [f"series/{name}" for name in series_tests]
    command = [sys.executable, str(nipa / "ingest_mdir.py"), "--noninteractive",
               "--mdir", str(submission / "patches"), "--tree", str(source),
               "--tree-name", manifest["target"], "--result-dir", str(results),
               "--test", *tests]
    # NIPA runs a worker thread: also guard against a worker exiting without notifying its queue.
    try:
        rc = subprocess.run(command, cwd=nipa, timeout=1800, check=False).returncode
    except subprocess.TimeoutExpired:
        rc = 1
    records = read_results(results, manifest, PATCH_TESTS, series_tests)
    (results / "results.json").write_text(json.dumps(records, indent=2) + "\n")
    summary = "\n".join(f"{r['kind']} {r['id']} / {r['test']}: {r['state']}" for r in records)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(f"### NIPA results\n\n```text\n{summary}\n```\n")
    return 1 if rc or any(r["state"] == "fail" for r in records) else 0


def positive_id(value):
    value = int(value)
    if value <= 0:
        raise argparse.ArgumentTypeError("ID must be positive")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare", help="Download emails and record the selected kernel base")
    prep.add_argument("--kind", choices=["series", "patch"], required=True)
    prep.add_argument("--id", type=positive_id, required=True)
    prep.add_argument("--event-id", type=positive_id)
    prep.add_argument("--output", required=True, metavar="DIR",
                      help="New directory for manifest.json and the downloaded patch emails")
    clone = commands.add_parser("checkout", help="Fetch the kernel base and optionally apply a patch prefix")
    clone.add_argument("--submission", required=True, metavar="DIR",
                       help="Prepared submission directory containing manifest.json and patches/")
    clone.add_argument("--source", required=True, metavar="DIR",
                       help="New directory in which to create the Linux kernel checkout")
    clone.add_argument("--through", type=int, default=0, metavar="N",
                       help="Apply patches 1 through N; default 0 checks out only the base for NIPA")
    nipa = commands.add_parser("nipa", help="Run NIPA checks and translate their results")
    nipa.add_argument("--submission", required=True, metavar="DIR",
                      help="Prepared submission directory containing manifest.json and patches/")
    nipa.add_argument("--source", required=True, metavar="DIR",
                      help="Existing Linux kernel checkout at the prepared base, before applying patches")
    nipa.add_argument("--nipa", required=True, metavar="DIR",
                      help="Existing NIPA repository checkout containing ingest_mdir.py")
    nipa.add_argument("--results", required=True, metavar="DIR",
                      help="New directory for NIPA logs and the translated results.json")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.kind, args.id, args.output, args.event_id)
    elif args.command == "checkout":
        checkout(args.submission, args.source, args.through)
    else:
        return run_nipa(args.submission, args.source, args.nipa, args.results)
    return 0


if __name__ == "__main__":
    sys.exit(main())
