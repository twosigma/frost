#!/usr/bin/env python3
"""Enumerate/run reproducible FROST branch-predictor geometry sweeps."""
from __future__ import annotations
import argparse
import math
import shlex
import subprocess

def bits_for_entries(entries: int) -> int:
    if entries < 4 or entries & (entries - 1):
        raise ValueError(f"BTB size must be a power of two >= 4, got {entries}")
    return int(math.log2(entries))

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--sizes', nargs='+', type=int, default=[128, 256, 512])
    ap.add_argument('--command', help='optional shell command template; use {entries} and {bp_bits}')
    args = ap.parse_args()
    for entries in args.sizes:
        bits = bits_for_entries(entries)
        print(f'{entries:4d} -> BP_BTB_INDEX_BITS={bits}')
        if args.command:
            cmd = args.command.format(entries=entries, bp_bits=bits)
            print('+', cmd)
            rc = subprocess.run(shlex.split(cmd), check=False).returncode
            if rc:
                return rc
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
