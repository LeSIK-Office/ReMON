#!/usr/bin/env python3
"""빌드 입력(소스·리소스·스크립트)의 SHA-256 목록을 만들거나 대조한다. 오래된 빌드 포장을 막는다(Folder Backup 방식)."""
import hashlib
import json
import pathlib
import sys

if len(sys.argv) != 3 or sys.argv[1] not in ["create", "verify"]:
    raise SystemExit("Usage: python3 scripts/build-manifest.py create|verify MANIFEST")
base = pathlib.Path(__file__).resolve().parent.parent
paths = [base / name for name in ["Package.swift", "scripts/build.sh", "scripts/build-manifest.py"]]
for folder in ["Sources", "Resources"]:
    paths.extend(p for p in (base / folder).rglob("*") if p.is_file() and p.name != ".DS_Store")
if any(p.is_symlink() for p in paths):
    raise SystemExit("Build inputs must not be symbolic links.")
current = {str(p.relative_to(base)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
manifest = pathlib.Path(sys.argv[2])
if sys.argv[1] == "create":
    manifest.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
elif json.loads(manifest.read_text()) != current:
    raise SystemExit("Build inputs changed during the build. Rebuild.")
print("Build source manifest:", sys.argv[1], "PASS")
