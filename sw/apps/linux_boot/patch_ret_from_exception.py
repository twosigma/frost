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
CSR write and MRET (an M-mode restore-window race). The trap then saves mepc at
the MRET instruction itself, which later returns into MRET as user code and
produces SIGILL at ret_from_exception+0x76. (The U-mode variant of that race is
fixed in hardware -- cpu_ooo.sv seeds interrupt_resume_pc from csr_mepc on
mret_taken -- but the M-mode restore-window variant is not yet, so this software
crutch is still required: without it the unpatched kernel hangs at the CLINT
clocksource switch once the periodic timer tick ramps up.)

For bring-up, replace the reservation-clear SC with `andi a0, a0, -9`, clearing
MIE in the value written to mstatus.  MRET still restores the final
interrupt-enable state from MPIE, but the restore window is not interruptible.

The target instruction is located by its unique machine-code word
(`18c1202f`) rather than a fixed offset, so the patch survives kernel rebuilds
that shift ret_from_exception. If the word is absent the image is assumed
already patched (idempotent); if it occurs more than once the patch aborts
rather than risk hitting the wrong site.
"""

from __future__ import annotations

import argparse
from pathlib import Path


OLD_WORD = "18c1202f"  # sc.w zero, a2, (sp) -- ret_from_exception reservation clear
NEW_WORD = "ff757513"  # andi a0, a0, -9    -- clear mstatus.MIE in the restore value


def patch_words(path: Path) -> None:
    """Patch the single OLD_WORD occurrence to NEW_WORD.

    Works for both the dense FPGA-loader form (one word per line) and the
    $readmemh form (skips '@<addr>' directives and blank lines).
    """
    lines = path.read_text().splitlines()
    old_hits = []
    new_hits = 0
    for i, line in enumerate(lines):
        s = line.strip().lower()
        if not s or s.startswith("@"):
            continue
        if s == OLD_WORD:
            old_hits.append(i)
        elif s == NEW_WORD:
            new_hits += 1
    if not old_hits:
        if new_hits:
            return  # already patched
        raise SystemExit(f"{path}: target word {OLD_WORD} not found (and not already patched)")
    if len(old_hits) > 1:
        raise SystemExit(
            f"{path}: {OLD_WORD} occurs {len(old_hits)}x; ambiguous, refusing to patch"
        )
    lines[old_hits[0]] = NEW_WORD
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("sw_ddr_mem", type=Path)
    parser.add_argument("sw_ddr_txt", type=Path)
    args = parser.parse_args()

    patch_words(args.sw_ddr_mem)
    patch_words(args.sw_ddr_txt)
    print(f"Patched Linux ret_from_exception restore window: {OLD_WORD}->{NEW_WORD}")


if __name__ == "__main__":
    main()
