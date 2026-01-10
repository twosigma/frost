# Contributors

- **Adam Bagley** ([@adambagley](https://github.com/adambagley)) - Original author and maintainer

- **Jordan Slott** ([@jslott2sigma](https://github.com/jslott2sigma)) - Built out the C standard library for the RISC-V soft core, implementing string functions (`strcmp`, `strncpy`, `strstr`, `strchr`), character classification (`isdigit`, `isalpha`, `toupper`), and number parsing (`strtol`, `atoi`), along with a comprehensive test application to validate them.

- **Tom Detwiler** ([@tdetwile](https://github.com/tdetwile)) - Optimized the ALU by sharing a single subtractor across SLT/SUB operations and unifying immediate/register operand paths, halved the divider pipeline depth by folding two radix-2 iterations per stage, and added register stages on the memory write path to improve timing closure.

- **Charles Saternos** ([@clsater](https://github.com/clsater)) - Implemented a heap memory system with an arena allocator (`arena_push`, `arena_push_zero`, `arena_push_align`) and a freelist-based `malloc`/`free`, including linker script changes to carve out an 8KB heap region.
