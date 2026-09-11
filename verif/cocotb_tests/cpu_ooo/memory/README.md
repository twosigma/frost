# Data-memory response seam tests

Run the portable and explicit Xilinx primitive variants through the repository's
Docker wrapper, which cleans before each target:

```sh
./scripts/frost.py cocotb data_mem_response_mux
./scripts/frost.py cocotb data_mem_response_mux_xilinx
```

Both targets enable assertions and use the same `data_mem_response_mux_tb`.
Standalone 32-bit and 64-bit helper instances check all 32 LUT5 input combinations
and walking data bits. The test-only LUT5 model implements indexed `INIT`; the
separate formal proof uses the pinned toolchain's installed Xilinx primitive
model. The bench also supplies LUT4 for the actual router's existing MMIO gate.

The integration pair instantiates the unchanged `data_mem_request_router` twice.
The reference receives the original procedural BRAM/MMIO selection and a separate
cached payload. The candidate's own `o_cached_read_ready` feeds its response helper,
whose output connects to both of that router's payload inputs. Tests compare all
25 router outputs before and after each edge, including invalid-cycle payloads.
Directed checks cover overlapping fast/cached responses, stale MMIO valid, cached
response IDs, queued address/ID capture behind writes, device staging and arming,
store-drain stalls, flush cancellation, reset, and destructive FIFO side effects.
A deterministic 1,200-cycle test varies payloads and controls while respecting the
router's one-entry pending-request contract.

This checks the real router seam and helper behavior. It does not model the whole
CPU, prove architectural liveness, or predict placement timing. The existing
`data_mem_request_router` target remains the broader request-router regression.
