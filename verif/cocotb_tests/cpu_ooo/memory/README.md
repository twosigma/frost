# Data-memory response mux tests

These cocotb benches check
[`data_mem_response_mux`](../../../../hw/rtl/cpu_and_mem/data_mem_response_mux.sv),
which merges BRAM, MMIO, and cached-DDR load data into one payload for the
data-memory router. The testbench
([`data_mem_response_mux_tb.sv`](../../../../hw/sim/data_mem_response_mux_tb.sv))
runs two copies of the real `data_mem_request_router` side by side. One gets
the mux's merged payload on both of its data inputs. The other gets the plain
selection (MMIO data while MMIO is valid, otherwise BRAM data) and the cached
data separately. Every router output must match on every cycle, valid or not,
across stalls, device reads, flushes, and resets. Standalone 32- and 64-bit
instances also go through all 32 combinations of the three data inputs and two
selects, and walk a one across every data bit.

```sh
./scripts/frost.py cocotb data_mem_response_mux          # portable RTL
./scripts/frost.py cocotb data_mem_response_mux_xilinx   # Xilinx LUT primitives (FROST_XILINX_PRIMS)
```

The Xilinx build simulates the LUTs with test-only models from
`hw/sim/data_mem_response_mux_lut_models.sv`. The `data_mem_response_mux`
[formal target](../../../../formal/README.md) proves the mux equal to the
plain selection for every input, using Yosys's own Xilinx cell models. For
the router's own regression, run `data_mem_request_router`.
