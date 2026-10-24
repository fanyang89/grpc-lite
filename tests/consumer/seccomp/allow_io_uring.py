#!/usr/bin/env python3
"""Derive the trusted consumer's profile from the pinned Moby default allowlist."""

import hashlib
import json
from pathlib import Path
import sys


MOBY_SHA256 = "6416b47770785a41ac59073cdc77d9fe98517df2799dc83ef207e622de3053f6"
IO_URING_SYSCALLS = ["io_uring_setup", "io_uring_enter", "io_uring_register"]


def consumer_profile(source):
    if hashlib.sha256(source).hexdigest() != MOBY_SHA256:
        raise ValueError("pinned Moby seccomp profile SHA-256 mismatch")
    profile = json.loads(source)
    # Do not rewrite or remove any upstream restrictions. These three syscalls
    # are absent from the pinned default allowlist and therefore denied there.
    profile["syscalls"].append({"names": IO_URING_SYSCALLS, "action": "SCMP_ACT_ALLOW"})
    return profile


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: allow_io_uring.py <output.json>")
    source = Path(__file__).with_name("moby-default.json").read_bytes()
    Path(sys.argv[1]).write_text(json.dumps(consumer_profile(source), indent=2) + "\n")
