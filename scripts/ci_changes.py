"""Conservative, offline change selection for CI (no workflow path filters)."""

import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def documentation(path):
    return path.endswith(".md") and (path.startswith("docs/") or "/" not in path)


def classify(paths):
    return {"heavy": any(not documentation(path) for path in paths)}


def changed_paths(base, head, pull_request=False):
    if not base or set(base) == {"0"}:
        raise ValueError("no trustworthy baseline")
    if pull_request:
        base = subprocess.check_output(["git", "merge-base", base, head], cwd=ROOT).decode().strip()
    subprocess.run(["git", "merge-base", "--is-ancestor", base, head], cwd=ROOT, check=True)
    output = subprocess.check_output(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, head], cwd=ROOT
    )
    return [path for path in output.decode("utf-8").split("\0") if path]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--pull-request", action="store_true")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        result = classify(changed_paths(args.base, args.head, args.pull_request))
    except (ValueError, subprocess.CalledProcessError, UnicodeError):
        result = classify(["unknown"])
    if args.force:
        result = classify(["unknown"])
    lines = [f"{key}={str(value).lower()}" for key, value in result.items()]
    print(json.dumps(result))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
