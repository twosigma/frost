#!/usr/bin/env python3

"""Patch the temporary Linux bring-up image for the MRET restore window.

The external linux-mvp tree currently builds a debug kernel whose
ret_from_exception sequence contains:

    lw   a2, PT_EPC(sp)
    sc.w zero, a2, (sp)
    csrw mstatus, a0
    csrw mepc, a2
    ...
    mret

If the restored mstatus image has MIE set, the timer can preempt between the
CSR write and MRET.  The trap then saves mepc at the MRET instruction itself,
which later returns into MRET as user code and produces SIGILL at
ret_from_exception+0x76.

For bring-up, replace the non-essential reservation-clear SC with
`andi a0, a0, -9`, clearing MIE in the value written to mstatus.  MRET still
restores the final interrupt-enable state from MPIE, but the restore window is
not interruptible.
"""

from __future__ import annotations

import argparse
from pathlib import Path


TARGET_WORD_INDEX = 0x00388B70 // 4
OLD_WORD = "18c1202f"
NEW_WORD = "ff757513"


def patch_dense(path: Path) -> None:
    lines = path.read_text().splitlines()
    if TARGET_WORD_INDEX >= len(lines):
        raise SystemExit(f"{path}: target word index 0x{TARGET_WORD_INDEX:x} is out of range")
    old = lines[TARGET_WORD_INDEX].strip().lower()
    if old == NEW_WORD:
        return
    if old != OLD_WORD:
        raise SystemExit(
            f"{path}: expected {OLD_WORD} at word 0x{TARGET_WORD_INDEX:x}, found {old}"
        )
    lines[TARGET_WORD_INDEX] = NEW_WORD
    path.write_text("\n".join(lines) + "\n")


def patch_mem(path: Path) -> None:
    lines = path.read_text().splitlines()
    word_index = 0
    for line_no, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("@"):
            word_index = int(stripped[1:], 16)
            continue
        if word_index == TARGET_WORD_INDEX:
            old = stripped.lower()
            if old == NEW_WORD:
                return
            if old != OLD_WORD:
                raise SystemExit(
                    f"{path}: expected {OLD_WORD} at word 0x{TARGET_WORD_INDEX:x}, found {old}"
                )
            lines[line_no] = NEW_WORD
            path.write_text("\n".join(lines) + "\n")
            return
        word_index += 1
    raise SystemExit(f"{path}: target word index 0x{TARGET_WORD_INDEX:x} not found")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("sw_ddr_mem", type=Path)
    parser.add_argument("sw_ddr_txt", type=Path)
    args = parser.parse_args()

    patch_mem(args.sw_ddr_mem)
    patch_dense(args.sw_ddr_txt)
    print(
        "Patched Linux ret_from_exception restore window: "
        f"word 0x{TARGET_WORD_INDEX:x} {OLD_WORD}->{NEW_WORD}"
    )


if __name__ == "__main__":
    main()
