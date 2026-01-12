# Contributors

## Adam Bagley ([@adambagley](https://github.com/adambagley))

- Original author and maintainer

## Jordan Slott ([@jslott2sigma](https://github.com/jslott2sigma))

- Implemented C standard library string functions (`strcmp`, `strncpy`, `strstr`, `strchr`)
- Implemented character classification functions (`isdigit`, `isalpha`, `toupper`)
- Implemented number parsing functions (`strtol`, `atoi`)
- Created comprehensive test application to validate stdlib functions

## Tom Detwiler ([@tdetwile](https://github.com/tdetwile))

- Optimized ALU by sharing a single subtractor across SLT/SUB operations
- Unified immediate/register operand paths in ALU
- Halved divider pipeline depth by folding two radix-2 iterations per stage
- Added register stages on memory write path to improve timing closure

## Charles Saternos ([@clsater](https://github.com/clsater))

- Implemented heap memory system with arena allocator (`arena_push`, `arena_push_zero`, `arena_push_align`)
- Implemented freelist-based `malloc`/`free`
- Modified linker script to carve out 8KB heap region
- Wrote original packet parser software app
