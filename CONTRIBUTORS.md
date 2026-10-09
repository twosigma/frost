# Contributors

## Two Sigma Employees

### Adam Bagley ([@adambagley](https://github.com/adambagley))

- Original author and maintainer

### Dr. Jordan Slott ([@jslott2sigma](https://github.com/jslott2sigma))

- Implemented C standard library string functions (`strcmp`, `strncpy`, `strstr`, `strchr`)
- Implemented character classification functions (`isdigit`, `isalpha`, `toupper`)
- Implemented number parsing functions (`strtol`, `atoi`)
- Created the stdlib validation application

### Dr. Thomas Detwiler ([@tdetwile](https://github.com/tdetwile))

- Optimized ALU by sharing a single subtractor across SLT/SUB operations
- Unified immediate/register operand paths in ALU
- Halved divider pipeline depth by folding two radix-2 iterations per stage
- Added register stages on memory write path to improve timing closure

### Charles Saternos ([@clsater](https://github.com/clsater))

- Implemented heap memory system with arena allocator (`arena_push`, `arena_push_zero`, `arena_push_align`)
- Implemented freelist-based `malloc`/`free`
- Modified linker script to carve out 8KB heap region
- Wrote original packet parser software app

### Erez Strauss ([@erez-strauss](https://github.com/erez-strauss))

- Implemented portable `sprintf`/`snprintf` library with full format support (`%d`, `%f`, `%e`, `%g`, `%x`, flags, width, precision, length modifiers)
- Created the ~260-case integer, floating-point, string, and truncation test suite

## External

### Dr. Nicholas Beser ([@ndbeser](https://github.com/ndbeser))

- Johns Hopkins University Applied Physics Laboratory
- Advisor for architecting and developing the Tomasulo out-of-order back-end

### Prof. John Goodacre ([@goodacre-manchester](https://github.com/goodacre-manchester))

- Professor at the University of Manchester, contributing in a personal capacity
- Found four RISC-V conformance bugs by differential testing against the Sail model ([#58](https://github.com/twosigma/frost/issues/58))
- Co-authored the fixes that make the machine HPM counters read-only zero and that page-fault on a non-leaf PTE with D, A, or U set
