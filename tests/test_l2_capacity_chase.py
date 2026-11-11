#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

"""Exercise the measurement program's bounds and corrupt-cycle rejection."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def test_chase_rejects_invalid_sizes_and_pointer_cycles(tmp_path: Path) -> None:
    """Run the actual C helpers with normal, short and malformed cycles."""
    (tmp_path / "csr.h").write_text(
        "#include <stdint.h>\nstatic inline uint64_t rdcycle64(void) { return 0; }\n"
    )
    (tmp_path / "uart.h").write_text("void uart_printf(const char *, ...);\n")
    source = tmp_path / "check.c"
    source.write_text(
        "#include <assert.h>\n#define main benchmark_main\n"
        f'#include "{ROOT / "sw/apps/l2_capacity_chase/main.c"}"\n'
        """
#undef main
void uart_printf(const char *format, ...) { (void) format; }
int main(void) {
    uint32_t lines = 0;
    assert(!working_set_lines(0, &lines));
    assert(working_set_lines(1, &lines) && lines == 16);
    assert(working_set_lines(16384, &lines) && lines == 262144);
    assert(!working_set_lines(16385, &lines));
    assert(!working_set_lines(UINT32_MAX, &lines));
    uint64_t ws[4 * LINE / 8] = {0};
    uint32_t perm[4];
    uint64_t start = (uint64_t) (uintptr_t) ws;
    build_cycle(ws, perm, 4);
    assert(validate_cycle(start, 4));
    assert(walk(start, 4) == start);
    ws[0] = start;
    assert(!validate_cycle(start, 4));
    ws[0] = start + LINE;
    ws[LINE / 8] = start;
    assert(!validate_cycle(start, 4));
    ws[0] = start + 1;
    assert(!validate_cycle(start, 4));
    ws[0] = start + sizeof(ws);
    assert(!validate_cycle(start, 4));
    assert(!validate_cycle(start, 0));
    return 0;
}
"""
    )
    executable = tmp_path / "check"
    subprocess.run(
        [
            "gcc",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            f"-I{tmp_path}",
            str(source),
            "-o",
            str(executable),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run([str(executable)], check=True, timeout=10)
