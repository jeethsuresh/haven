#!/usr/bin/env python3
"""Derive an immutable Android release identity for each GitHub workflow run."""
import argparse
import json
import os
from pathlib import Path
import re


def prepare(root, number):
    if not re.fullmatch(r"[1-9][0-9]*", str(number)) or not 1 <= int(number) <= 2100000000:
        raise ValueError("Workflow run number must be a valid positive Android version code")
    source = root / "client/pubspec.yaml"
    text = source.read_text()
    match = re.search(r"^version: (\d+)\.(\d+)\.\d+\+\d+$", text, re.M)
    if not match:
        raise ValueError("pubspec.yaml must declare a stable version series")
    name = f"{match[1]}.{match[2]}.{number}"
    changes = json.loads((root / "changelog.json").read_text())
    if changes.get("schemaVersion") != 1 or not changes.get("changes"):
        raise ValueError("A source changelog is required before release allocation")
    source.write_text(re.sub(r"^version: .*", f"version: {name}+{number}", text, flags=re.M))
    changes.update(version=name, versionCode=int(number))
    (root / "changelog.json").write_text(json.dumps(changes, indent=2) + "\n")
    return name, int(number)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-number", default=os.environ.get("GITHUB_RUN_NUMBER", ""))
    args = parser.parse_args()
    name, code = prepare(Path(__file__).resolve().parents[1], args.run_number)
    print(f"Prepared Haven {name}, Android build {code}")
