#!/usr/bin/env bash
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

set -euo pipefail

DEMO_ROOT="${FROST_DEMO_ROOT:-/opt/frost-demo}"
MEM_CONFIG="bram"
TARGET_APP="all"
MAX_CYCLES=""
REQUESTED_THREADS="${FROST_THREADS:-}"
CHILD_PID=""

usage() {
    cat <<'EOF'
Usage: docker run --rm -it frost-demo:local [options]

Runs FROST's SystemVerilog CPU and SoC RTL in Verilator on prebuilt RISC-V
programs (hello_world followed by a single-iteration CoreMark correctness run).

Options:
  --threads <1|4|8>       Simulator thread count (default: 4 when >=4 CPUs, else 1)
  --mem-config <bram|ddr> Memory configuration: bram (default) or ddr
  --app <name>            all (default), hello_world, or coremark
  --max-cycles <N>        Optional cycle limit override
  -h, --help              Show this help message
EOF
}

is_pos_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] ;;
    esac
}

detect_effective_cpus() {
    local cpus
    cpus="$(nproc 2>/dev/null || echo 1)"
    if ! is_pos_int "$cpus"; then
        cpus=1
    fi
    if [ -r "${FROST_CGROUP_CPU_MAX:-/sys/fs/cgroup/cpu.max}" ]; then
        local quota="" period="" _rest=""
        read -r quota period _rest < "${FROST_CGROUP_CPU_MAX:-/sys/fs/cgroup/cpu.max}" || true
        if is_pos_int "$quota" && is_pos_int "$period"; then
            local cg_cpus=$(( quota / period ))
            if [ "$cg_cpus" -lt 1 ]; then
                cg_cpus=1
            fi
            if [ "$cg_cpus" -lt "$cpus" ]; then
                cpus="$cg_cpus"
            fi
        fi
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
        local quota="" period="" _rest=""
        read -r quota _rest < /sys/fs/cgroup/cpu/cpu.cfs_quota_us || true
        read -r period _rest < /sys/fs/cgroup/cpu/cpu.cfs_period_us || true
        if is_pos_int "$quota" && is_pos_int "$period"; then
            local cg_cpus=$(( quota / period ))
            if [ "$cg_cpus" -lt 1 ]; then
                cg_cpus=1
            fi
            if [ "$cg_cpus" -lt "$cpus" ]; then
                cpus="$cg_cpus"
            fi
        fi
    fi
    echo "$cpus"
}

forward_signal() {
    local sig="$1"
    local exit_code="$2"
    if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill -s "$sig" "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    exit "$exit_code"
}

trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --threads)
            if [ $# -lt 2 ]; then
                echo "Error: --threads requires a value" >&2
                exit 2
            fi
            REQUESTED_THREADS="$2"
            shift 2
            ;;
        --mem-config)
            if [ $# -lt 2 ]; then
                echo "Error: --mem-config requires a value" >&2
                exit 2
            fi
            MEM_CONFIG="$2"
            shift 2
            ;;
        --app)
            if [ $# -lt 2 ]; then
                echo "Error: --app requires a value" >&2
                exit 2
            fi
            TARGET_APP="$2"
            shift 2
            ;;
        --max-cycles)
            if [ $# -lt 2 ]; then
                echo "Error: --max-cycles requires a value" >&2
                exit 2
            fi
            MAX_CYCLES="$2"
            shift 2
            ;;
        *)
            echo "Error: unrecognized option '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$MEM_CONFIG" in
    bram|ddr) ;;
    *)
        echo "Error: --mem-config must be bram or ddr (got '$MEM_CONFIG')" >&2
        exit 2
        ;;
esac

case "$TARGET_APP" in
    all|hello_world|coremark) ;;
    *)
        echo "Error: --app must be all, hello_world, or coremark (got '$TARGET_APP')" >&2
        exit 2
        ;;
esac

if [ -z "$REQUESTED_THREADS" ]; then
    effective_cpus="$(detect_effective_cpus)"
    if [ "$effective_cpus" -ge 4 ]; then
        ACTIVE_THREADS=4
    else
        ACTIVE_THREADS=1
    fi
else
    case "$REQUESTED_THREADS" in
        ''|*[!0-9]*|0)
            echo "Error: --threads must be a positive integer (got '$REQUESTED_THREADS')" >&2
            exit 2
            ;;
    esac
    if [ "$REQUESTED_THREADS" -ge 8 ]; then
        ACTIVE_THREADS=8
    elif [ "$REQUESTED_THREADS" -ge 4 ]; then
        ACTIVE_THREADS=4
    else
        ACTIVE_THREADS=1
    fi
fi

MODEL_BIN="${DEMO_ROOT}/bin/frost-native-t${ACTIVE_THREADS}"
EXTRA_ARGS=()
if [ -n "$MAX_CYCLES" ]; then
    EXTRA_ARGS+=(--max-cycles "$MAX_CYCLES")
fi

if [ "$MEM_CONFIG" = "bram" ]; then
    MEM_DESC="256 KiB on-chip BRAM"
else
    MEM_DESC="coherent L1/L2 caches and behavioral AXI memory model"
fi

cat <<EOF
FROST RTL demonstration (Verilator SystemVerilog simulation, assertions enabled)
Simulating the two-wide out-of-order RV64GCB CPU and SoC RTL from hw/rtl/frost.f.
Memory path: ${MEM_DESC} | Simulator threads: ${ACTIVE_THREADS}
Every clock cycle evaluates the full hardware model in software; RTL simulation
is far slower than hardware.
EOF

if [ -n "$REQUESTED_THREADS" ] && [ "$REQUESTED_THREADS" != "$ACTIVE_THREADS" ]; then
    echo "Note: requested ${REQUESTED_THREADS} threads; using prebuilt ${ACTIVE_THREADS}-thread partition."
fi

print_coremark_note() {
    cat <<'EOF'
Note: Simulation compiles CoreMark for 1 CRC-checked iteration with a nominal
20000 Hz clock constant to satisfy CoreMark's minimum-time check. The printed
Total time, Iterations/Sec, and CoreMark 1.0 score lines are not meaningful at
simulation speed; Total ticks is the simulated CPU's cycle count for that
iteration.
EOF
}

run_supervised() {
    local app="$1"
    local stop_marker="$2"
    local drain="$3"
    "$MODEL_BIN" \
        --mem-dir "${DEMO_ROOT}/apps/${app}_${MEM_CONFIG}" \
        --threads "$ACTIVE_THREADS" \
        --stop "$stop_marker" \
        --drain "$drain" \
        "${EXTRA_ARGS[@]}" &
    CHILD_PID=$!
    local status=0
    wait "$CHILD_PID" || status=$?
    CHILD_PID=""
    if [ "$status" -ne 0 ]; then
        exit "$status"
    fi
}

if [ "$TARGET_APP" = "all" ]; then
    echo ""
    echo "[1/2] Simulating hello_world on FROST RTL..."
    run_supervised "hello_world" "Hello, world!" 10000

    echo ""
    echo "[2/2] Simulating CoreMark (single-iteration correctness run) on FROST RTL..."
    print_coremark_note
    run_supervised "coremark" "<<PASS>>" 0

    echo ""
    echo "Demonstration finished: hello_world and CoreMark completed on the FROST RTL."
elif [ "$TARGET_APP" = "hello_world" ]; then
    echo ""
    echo "[1/1] Simulating hello_world on FROST RTL..."
    exec "$MODEL_BIN" \
        --mem-dir "${DEMO_ROOT}/apps/hello_world_${MEM_CONFIG}" \
        --threads "$ACTIVE_THREADS" \
        --stop "Hello, world!" \
        --drain 10000 \
        "${EXTRA_ARGS[@]}"
elif [ "$TARGET_APP" = "coremark" ]; then
    echo ""
    echo "[1/1] Simulating CoreMark (single-iteration correctness run) on FROST RTL..."
    print_coremark_note
    exec "$MODEL_BIN" \
        --mem-dir "${DEMO_ROOT}/apps/coremark_${MEM_CONFIG}" \
        --threads "$ACTIVE_THREADS" \
        --stop "<<PASS>>" \
        --drain 0 \
        "${EXTRA_ARGS[@]}"
fi
