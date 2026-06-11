#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0

"""Run selected NIPA patch tests against the checked-out HEAD commit."""

import argparse
import os
import pathlib
import subprocess
import sys
from dataclasses import dataclass


DEFAULT_TESTS = [
    "check_selftest",
    "checkpatch",
    "deprecated_api",
    "header_inline",
    "kdoc",
    "pylint",
    "ruff",
    "shellcheck",
    "source_inline",
    "verify_fixes",
    "verify_signedoff",
    "yamllint",
]


@dataclass
class Tree:
    # NIPA patch tests only need these two attributes from the tree object.
    path: str
    branch: str


def run(cmd, cwd):
    return subprocess.check_output(cmd, cwd=cwd, text=True).strip()


def read_file(path):
    try:
        return pathlib.Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def one_line(text):
    return " ".join(text.split())


def result_label(retcode):
    if retcode == 0:
        return "OKAY"
    if retcode == 250:
        return "WARNING"
    return "FAILED"


def print_result_details(test_name, test_dir):
    # NIPA writes one result directory per test. Keep the common summary visible
    # and fold the noisier streams under a GitHub log group.
    desc = read_file(test_dir / "desc").strip()
    stdout = read_file(test_dir / "stdout").strip()
    stderr = read_file(test_dir / "stderr").strip()

    print(f"::group::{test_name} details")
    print(read_file(test_dir / "summary").rstrip())
    if desc:
        print("\nDescription:")
        print(desc)
    if stdout:
        print("\nstdout:")
        print(stdout)
    if stderr:
        print("\nstderr:")
        print(stderr)
    print("::endgroup::")


def print_result(results_dir, test_name):
    test_dir = pathlib.Path(results_dir) / test_name
    retcode = read_file(test_dir / "retcode").strip()
    retcode = int(retcode or 1)
    desc = read_file(test_dir / "desc").strip()

    print(f" {result_label(retcode):7} {test_name:24} {one_line(desc)}")

    if retcode != 0:
        print_result_details(test_name, test_dir)

    return retcode


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--nipa", required=True)
    parser.add_argument("--results", required=True)
    parser.add_argument("--tests", default=",".join(DEFAULT_TESTS))
    return parser.parse_args()


def main():
    args = parse_args()

    repo = os.path.abspath(args.repo)
    nipa = os.path.abspath(args.nipa)
    results = os.path.abspath(args.results)
    tests = [test.strip() for test in args.tests.split(",") if test.strip()]

    # Use the checked-out NIPA tree directly; it is not installed as a package.
    sys.path.insert(0, nipa)

    import core  # pylint: disable=import-outside-toplevel

    os.makedirs(results, exist_ok=True)
    core.log_init("org", os.path.join(results, "nipa.log"), force_single_thread=True)

    # The workflow dispatches one commit at a time. Present it to NIPA as a
    # single-patch series matching HEAD~..HEAD.
    sha = run(["git", "rev-parse", "HEAD"], repo)
    run(["git", "rev-parse", "--verify", "HEAD~"], repo)
    raw_patch = run(["git", "format-patch", "-1", "--stdout", sha], repo)
    patch = core.Patch(raw_patch, ident=sha)
    patch.first_in_series = True
    tree = Tree(path=repo, branch="HEAD~..HEAD")

    failed = []
    print("Patch level tests:")
    for test_name in tests:
        test_path = os.path.join(nipa, "tests", "patch", test_name)
        if not os.path.isdir(test_path):
            raise SystemExit(f"unknown NIPA patch test: {test_name}")

        # Some tests inspect or temporarily touch the source tree. Start each
        # one from the commit under test so the selected checks stay independent.
        run(["git", "checkout", "-q", sha], repo)
        test = core.Test(test_path, test_name)
        test.exec(tree, patch, results)
        retcode = print_result(results, test_name)
        if retcode != 0:
            failed.append((test_name, retcode))

    run(["git", "checkout", "-q", sha], repo)

    if failed:
        print("Failed NIPA patch tests:")
        for test_name, retcode in failed:
            print(f"  {test_name}: {retcode}")
        return 1

    print("All selected NIPA patch tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
