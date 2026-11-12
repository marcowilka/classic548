#!/usr/bin/env python3
"""Bump ClassicAFP marketing version / build number in project.yml (app + appex).

Source of truth (edit here, then xcodegen):
  ClassicAFP/settings/base/CURRENT_PROJECT_VERSION  → CFBundleVersion (Build)
  ClassicAFP/settings/base/MARKETING_VERSION       → CFBundleShortVersionString
  AFPFS uses the same keys so app and extension stay in sync.

Info.plist only references $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION).

Usage (from classic548/):
  ./version.py --bump-build
  ./version.py --bump-version
  ./version.py --show
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROJECT_YML = ROOT / "project.yml"

BUILD_RE = re.compile(r"^(\s*CURRENT_PROJECT_VERSION:\s*)(\d+)\s*$", re.MULTILINE)
VERSION_RE = re.compile(r"^(\s*MARKETING_VERSION:\s*)(\S+)\s*$", re.MULTILINE)


def read_yml() -> str:
    if not PROJECT_YML.is_file():
        sys.exit(f"Missing {PROJECT_YML}")
    return PROJECT_YML.read_text(encoding="utf-8")


def write_yml(text: str) -> None:
    PROJECT_YML.write_text(text, encoding="utf-8")


def current_values(text: str) -> tuple[str, int]:
    versions = VERSION_RE.findall(text)
    builds = BUILD_RE.findall(text)
    if not versions or not builds:
        sys.exit("Could not find MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml")
    marketing = versions[0][1]
    build = int(builds[0][1])
    if len({v[1] for v in versions}) > 1 or len({int(b[1]) for b in builds}) > 1:
        print("Warning: ClassicAFP and AFPFS version/build differ; script will unify them.", file=sys.stderr)
    return marketing, build


def run_xcodegen() -> None:
    print("Running xcodegen…")
    subprocess.run(["xcodegen", "generate"], cwd=ROOT, check=True)


def bump_build(run_gen: bool) -> None:
    text = read_yml()
    marketing, build = current_values(text)
    new_build = build + 1

    def repl(m: re.Match[str]) -> str:
        return f"{m.group(1)}{new_build}"

    new_text, n = BUILD_RE.subn(repl, text)
    if n == 0:
        sys.exit("No CURRENT_PROJECT_VERSION lines updated")
    write_yml(new_text)
    print(f"Build {build} → {new_build}  (version {marketing}, {n} target(s))")
    if run_gen:
        run_xcodegen()


def bump_version(run_gen: bool) -> None:
    text = read_yml()
    marketing, build = current_values(text)
    print(f"Current version: {marketing}  (build {build})")
    try:
        raw = input("New version: ").strip()
    except EOFError:
        sys.exit("No input")
    if not raw:
        sys.exit("Aborted (empty version)")
    if not re.fullmatch(r"\d+(\.\d+)*", raw):
        sys.exit(f"Invalid version '{raw}' (expected e.g. 1.0 or 1.0.2)")

    def repl(m: re.Match[str]) -> str:
        return f"{m.group(1)}{raw}"

    new_text, n = VERSION_RE.subn(repl, text)
    if n == 0:
        sys.exit("No MARKETING_VERSION lines updated")
    write_yml(new_text)
    print(f"Version {marketing} → {raw}  (build {build} unchanged, {n} target(s))")
    if run_gen:
        run_xcodegen()


def show() -> None:
    marketing, build = current_values(read_yml())
    print(f"version {marketing}  build {build}")
    print(f"  → {PROJECT_YML.relative_to(ROOT)}")
    print("  ClassicAFP + AFPFS settings.base")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--bump-build", action="store_true", help="Increment CURRENT_PROJECT_VERSION by 1")
    group.add_argument("--bump-version", action="store_true", help="Prompt for new MARKETING_VERSION")
    group.add_argument("--show", action="store_true", help="Print current version and build")
    parser.add_argument(
        "--no-xcodegen",
        action="store_true",
        help="Only edit project.yml (skip regenerating the Xcode project)",
    )
    args = parser.parse_args()
    run_gen = not args.no_xcodegen

    if args.show:
        show()
    elif args.bump_build:
        bump_build(run_gen)
    else:
        bump_version(run_gen)


if __name__ == "__main__":
    main()
