# Contributing to FROST

Use the [quick start](README.md#quick-start) to set up the pinned Docker image.
Run simulation, formal, synthesis checks, and lint through `scripts/frost.py`;
Vivado and board workflows run natively. See [tooling](docs/tooling.md) for setup
and [software contributions](sw/CONTRIBUTING.md) for bare-metal applications.

## Development Workflow

1. Create a branch and run the affected checks to establish a baseline.
2. Make the change and update affected READMEs, comments, diagrams, and test descriptions.
3. Run the relevant tests below and `./scripts/frost.py check`. Review any lint fixes.
4. Open a pull request describing the problem, resulting behavior, and validation.

Keep commit messages focused on the change and its verification. Do not add
assistant co-authorship or model references.

Bug reports should include the commit, pinned-image/tool versions, reproduction
commands, expected and actual behavior, and relevant logs or waveforms.

## Coding Style Guide

The repository formatters are authoritative: Verible for SystemVerilog,
clang-format for C/C++, and Ruff for Python. Pre-commit also runs Verible lint,
clang-tidy, and mypy. See [`.pre-commit-config.yaml`](.pre-commit-config.yaml).

### License Headers

Keep license and attribution notices. The `insert-license` hooks add the
Apache 2.0 header from [`.license-header.txt`](.license-header.txt) to supported
source types; add it manually to new assembly files. Third-party code retains
its own license.

### SystemVerilog

- Use `snake_case` names, `i_`/`o_` port prefixes, `*_t` structs/unions,
  `*_e` enums, and uppercase parameters and enum values.
- Use `*_registered` for registered signals.
- Preserve a portable core implementation. Gate optional Xilinx primitives
  with `FROST_XILINX_PRIMS`; keep board-specific integration in `boards/`.
- Keep `.f` source lists current and verify Verilator, Yosys, and Vivado compatibility.
- Explain interface, ordering, recovery, and timing constraints in comments.
  Avoid narrating assignments or recording abandoned implementations.

### Python

- Use `snake_case` functions/variables and `CamelCase` classes/type aliases.
- Add docstrings and public type annotations; `verif/` and `tests/` require
  complete function annotations.
- Use explicit configuration objects and reproducible seeds in verification.
- Keep comments and long strings readable; Ruff does not wrap them.

### C and Assembly

Use fixed-width types for hardware data and `volatile` MMIO accesses. Names
use `snake_case`, types end in `_t`, and macros/constants use uppercase.
Bare-metal programs use FROST's startup, linker scripts, and `sw/lib/` runtime.
See [sw/CONTRIBUTING.md](sw/CONTRIBUTING.md) for build and memory constraints.

### Build Scripts

Use overridable Make defaults (`?=`), quote shell variables, and start Bash
scripts with `set -euo pipefail`. Explain non-obvious build steps and validate
Tcl inputs with actionable errors.

## Testing Requirements

Run commands from the repository root. The cocotb and pytest shortcuts clean
`tests/` before running; host-native cocotb results are not regression evidence.

| Change | Checks |
|--------|--------|
| All | `./scripts/frost.py check` (lint and fast Python tests) |
| RTL | Affected cocotb targets, full CPU suite, both memory tiers, synthesis, relevant formal targets |
| Software | App simulation and `./scripts/frost.py run python3 sw/apps/build_all_apps.py` |
| Verification | Fast Python tests and affected cocotb targets or marker shards |
| Formal properties | Affected target, then the full formal registry |
| FPGA integration | Native Vivado build and relevant hardware regression |

```bash
./scripts/frost.py pytest -v
./scripts/frost.py cocotb directed_traps
./scripts/frost.py cocotb isa_test
FROST_COCOTB_MEM_CONFIG=ddr ./scripts/frost.py cocotb isa_test
./scripts/frost.py synthesis
./scripts/frost.py formal --target trap_unit
./scripts/frost.py formal
```

### Test Markers

| Marker | Selects |
|--------|---------|
| `cocotb` | Simulation targets |
| `cocotb_unit` | Unit benches |
| `cocotb_real_program` | Application tests |
| `coremark_pro` | CoreMark-PRO workloads |
| `synthesis` | Yosys checks |
| `formal` | SymbiYosys checks |
| `slow` | Long-running tests |

For example, `./scripts/frost.py pytest -m "cocotb and cocotb_unit" -v`
selects unit benches. See the [test guide](tests/README.md) for compliance,
torture, environment options, and CI coverage.

## Adding New Components

- **Board:** follow the [board checklist](boards/README.md#adding-support-for-new-boards).
- **Application or library:** follow [sw/CONTRIBUTING.md](sw/CONTRIBUTING.md).
- **Peripheral:** add RTL under `hw/rtl/peripherals/`, integrate address decoding,
  update the hardware/software memory maps and device tree as applicable, and
  add a driver and test.
- **Formal target:** follow [formal/README.md](formal/README.md#adding-a-new-formal-target).

For a cocotb test, add a module under `verif/cocotb_tests/` and register it in
`TEST_REGISTRY` in `tests/test_run_cocotb.py`:

```python
"new_feature": CocotbRunConfig(
    python_test_module="cocotb_tests.path.test_new_feature",
    hdl_toplevel_module="new_feature",
    description="New feature unit tests",
),
```

Check discovery with `./scripts/frost.py cocotb --list-tests`, then run
`./scripts/frost.py cocotb new_feature`.
