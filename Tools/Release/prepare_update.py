"""Prepare verified helper update/rollback copies; never install or run an app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess

IDENTIFIER = "local.codex.prompt-assistant-poc"
EXECUTABLE = "Contents/MacOS/CodexPromptAssistantPOC"
ROLES = {"candidate": "candidate.app", "rollback": "rollback.app"}
REPOSITORY = Path(__file__).resolve().parents[2]


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_digest(bundle):
    """Bind relative names, types, permissions and bytes; fail on unsupported links."""
    require(bundle.is_dir() and not bundle.is_symlink(), "bundle must be a real directory")
    digest = hashlib.sha256()
    for path in [bundle, *sorted(bundle.rglob("*"))]:
        mode = path.lstat().st_mode
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), "symlinks/special files are unsupported")
        record = [str(path.relative_to(bundle)), stat.S_IFMT(mode), stat.S_IMODE(mode),
                  sha256(path) if stat.S_ISREG(mode) else None]
        digest.update(json.dumps(record, ensure_ascii=True).encode() + b"\n")
    return digest.hexdigest()


def verify_signature(bundle):
    # Requirement supplements strict verification; inspected executables are never run.
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                    "-R", '=identifier "' + IDENTIFIER + '"', str(bundle)],
                   check=True, capture_output=True, timeout=30)


def copy_bundle(source, destination):
    subprocess.run(["/usr/bin/ditto", str(source), str(destination)],
                   check=True, capture_output=True, timeout=120)


def inspect(bundle, signature_check=verify_signature):
    before = tree_digest(bundle)
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    require(isinstance(info, dict), "invalid bundle plist")
    require(info.get("CFBundleIdentifier") == IDENTIFIER, "unexpected bundle identifier")
    require(info.get("CFBundleExecutable") == Path(EXECUTABLE).name, "unexpected executable")
    identity = info.get("CPABuildMetadata")
    require(isinstance(identity, dict), "legacy/missing build metadata is unsupported")
    require(type(identity.get("SchemaVersion")) is int and identity["SchemaVersion"] == 1,
            "unsupported metadata schema")
    require(identity.get("WorktreeDirty") is False, "dirty/unknown build is unsupported")
    require(re.fullmatch(r"[0-9a-f]{40}", str(identity.get("GitCommit", ""))), "invalid build commit")
    require(bool((bundle / EXECUTABLE).stat().st_mode & 0o111), "executable permission is missing")
    signature_check(bundle)
    executable_hash = sha256(bundle / EXECUTABLE)
    require(before == tree_digest(bundle), "bundle changed during inspection")
    return {"build": identity, "executableSHA256": executable_hash, "treeSHA256": before}


def write_manifest(directory, manifest):
    # The manifest is the last write. Incomplete directories are retained for inspection.
    temporary = directory / "manifest.pending"
    with temporary.open("x") as stream:
        json.dump(manifest, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.rename(directory / "manifest.json")


def prepare(candidate, installed, output, expected_commit, expected_installed_sha256,
            signature_check=verify_signature, copier=copy_bundle):
    require(re.fullmatch(r"[0-9a-f]{40}", expected_commit), "expected commit must be a full SHA")
    require(re.fullmatch(r"[0-9a-f]{64}", expected_installed_sha256), "expected installed hash must be SHA256")
    require(not output.exists() and not output.is_symlink(), "output already exists; choose a new name")
    sources = {"candidate": candidate.resolve(), "rollback": installed.resolve()}
    destination = output.resolve()
    for source in sources.values():
        require(destination != source and source not in destination.parents
                and destination not in source.parents, "output must not overlap a source bundle")
    original = {role: inspect(source, signature_check) for role, source in sources.items()}
    require(original["candidate"]["build"]["GitCommit"] == expected_commit, "candidate commit mismatch")
    require(original["rollback"]["executableSHA256"] == expected_installed_sha256, "installed hash mismatch")
    output.mkdir(mode=0o700)  # Exclusive reservation; never merge with an existing preparation.
    for role, filename in ROLES.items():
        copied = output / filename
        copier(sources[role], copied)
        require(inspect(copied, signature_check) == original[role], "copied bundle mismatch: " + role)
    for role, source in sources.items():
        require(inspect(source, signature_check) == original[role], "source changed during preparation: " + role)
    manifest = {"schema": 1, "state": "prepared-artifacts-only", "bundles": original}
    write_manifest(output, manifest)
    return manifest


def verify_preparation(directory, signature_check=verify_signature):
    require(directory.is_dir() and not directory.is_symlink(), "preparation must be a real directory")
    require(not (directory / "manifest.json").is_symlink(), "manifest must not be a symlink")
    manifest = json.loads((directory / "manifest.json").read_text())
    require(isinstance(manifest, dict) and manifest.get("schema") == 1
            and manifest.get("state") == "prepared-artifacts-only", "invalid preparation manifest")
    records = manifest.get("bundles")
    require(isinstance(records, dict) and set(records) == set(ROLES), "both bundle records are required")
    # Fixed paths only; no path from a manifest is executed or used as a destination.
    for role, filename in ROLES.items():
        require(inspect(directory / filename, signature_check) == records[role], "prepared bundle mismatch: " + role)
    return manifest


def preparation_output(name):
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", name), "invalid preparation name")
    parent = REPOSITORY / ".build" / "update-preparations"
    require(parent.resolve() == parent, "preparation parent must not contain symlinks")
    parent.mkdir(parents=True, exist_ok=True)
    return parent / name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    staging = actions.add_parser("prepare", help="write copies under .build/update-preparations only")
    staging.add_argument("--candidate", type=Path, required=True)
    staging.add_argument("--installed", type=Path, required=True)
    staging.add_argument("--expected-commit", required=True)
    staging.add_argument("--expected-installed-sha256", required=True)
    staging.add_argument("--name", required=True)
    checking = actions.add_parser("verify", help="read and verify an existing preparation")
    checking.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            directory = preparation_output(args.name)
            result = prepare(args.candidate, args.installed, directory,
                             args.expected_commit, args.expected_installed_sha256)
        else:
            directory = args.directory
            result = verify_preparation(directory)
        print(json.dumps({"directory": str(directory), **result}, indent=2))
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, ValueError) else type(error).__name__
        parser.exit(1, f"Preparation failed: {reason}; no installation or service action performed.\n")


if __name__ == "__main__":
    main()
