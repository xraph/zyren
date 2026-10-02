#!/usr/bin/env python3
"""Run a native qualification command with source provenance and a local log."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def snapshot():
    paths = git("ls-files", "-z", "--cached", "--others", "--exclude-standard",
                "packages", "examples", "tool", "pubspec.yaml",
                "pubspec.lock", ".fvmrc").decode().split("\0")
    hashes = {}
    for name in sorted(set(paths) - {""}):
        path = ROOT / name
        hashes[name] = (hashlib.sha256(path.read_bytes()).hexdigest()
                        if path.is_file() else None)
    digest = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    return {"head": git("rev-parse", "HEAD").decode().strip(),
            "branch": git("branch", "--show-current").decode().strip(),
            "status": git("status", "--porcelain=v1").decode().splitlines(),
            "source_digest": digest, "files": hashes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cwd", type=Path, default=ROOT)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provide a command after --")
    args.output.mkdir(parents=True, exist_ok=True)
    before = snapshot()
    started = time.time()
    with (args.output / "command.log").open("w") as log:
        result = subprocess.run(command, cwd=args.cwd, stdout=log,
                                stderr=subprocess.STDOUT, check=False)
    after = snapshot()
    evidence = {"command": command, "cwd": str(args.cwd.resolve()),
                "started_unix": started, "elapsed_seconds": time.time() - started,
                "exit_code": result.returncode, "before": before, "after": after,
                "source_unchanged": before["source_digest"] == after["source_digest"]}
    (args.output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({key: evidence[key] for key in
                      ("exit_code", "source_unchanged", "elapsed_seconds")}))
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
