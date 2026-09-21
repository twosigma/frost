# Data-memory response seam tests

Run the portable and explicit Xilinx primitive variants through the repository's
Docker wrapper, which cleans before each target:

```sh
./scripts/frost.py cocotb data_mem_response_mux
./scripts/frost.py cocotb data_mem_response_mux_xilinx
```

Both targets compare the response helper with the original BRAM/MMIO/cached
selection through the actual `data_mem_request_router`. They check 32/64-bit
payloads and all router outputs across stalls, device reads, flushes, and
reset. The Xilinx variant uses test-only LUT models; the separate formal
proof uses the pinned toolchain's primitive model.

These are focused response-path tests. Use `data_mem_request_router` for the
broader router regression and full-system tests for CPU behavior; neither
target predicts placement timing.
