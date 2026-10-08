"""Create a new owner-only output directory before writing employee data."""
from __future__ import annotations

import csv
import io
import json
import os
from pathlib import Path
import re
import subprocess


def create_private_directory(path: Path):
    path = Path(path).absolute()
    # Never replace an existing package, directory or symlink during conversion.
    path.mkdir(mode=0o700, parents=False, exist_ok=False)
    if os.name == "nt":
        result = subprocess.run(["whoami", "/user", "/fo", "csv", "/nh"],
                                capture_output=True, text=True, check=True)
        records = list(csv.reader(io.StringIO(result.stdout)))
        sid = next((cell for record in records for cell in record if re.fullmatch(r"S-1-\d+(?:-\d+)+", cell)), None)
        if not sid:
            raise ValueError("Unable to resolve the current user's Windows SID; no private data was written")
        subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"*{sid}:(OI)(CI)F"],
                       capture_output=True, text=True, check=True)
    else:
        os.chmod(path, 0o700)
    return path


def write_private_json(directory: Path, name: str, value):
    if Path(name).name != name or not name.endswith(".json"):
        raise ValueError("A plain JSON output filename is required")
    target = directory / name
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        json.dump(value, output, indent=2, ensure_ascii=True, allow_nan=False)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
