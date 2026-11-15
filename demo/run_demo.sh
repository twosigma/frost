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

DEMO_ROOT="/opt/frost-demo"
MEM_CONFIG="bram"
TARGET_APP="all"
MAX_CYCLES=""
REQUESTED_THREADS="${FROST_THREADS:-}"

usage() {
    cat <<'EOF'
Usage: docker run --rm frost-demo:local [options]

Runs FROST's SystemVerilog CPU, cache, and SoC RTL in Verilator on prebuilt
RISC-V programs (hello_world followed by 1-iteration CoreMark).

Options:
  --threads <1|4|8>       Simulator thread count (default: 4 when >=4 CPUs, else 1)
  --mem-config <bram|ddr> Memory configuration: bram (default) or ddr
  --app <name>            all (default), hello_world, or coremark
  --max-cycles <N>        Optional cycle limit override
  -h, --help              Show this help message
EOF
}

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
    host_cpus="$(nproc 2>/dev/null || echo 1)"
    if [ "$host_cpus" -ge 4 ]; then
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

cat <<EOF
FROST RTL demonstration (cycle-accurate SystemVerilog simulation)
Running the real out-of-order RV64GCB CPU, MMUs, coherent L1/L2 caches, and SoC RTL.
Memory tier: ${MEM_CONFIG} | Simulator threads: ${ACTIVE_THREADS}
Every clock cycle evaluates the full hardware model in software at thousands of
cycles per second; physical hardware runs many thousands of times faster.
EOF

if [ -n "$REQUESTED_THREADS" ] && [ "$REQUESTED_THREADS" != "$ACTIVE_THREADS" ]; then
    echo "Note: requested ${REQUESTED_THREADS} threads; using prebuilt ${ACTIVE_THREADS}-thread partition."
fi

run_one() {
    local label="$1"
    local app="$2"
    local stop_marker="$3"
    local drain="$4"
    echo ""
    echo "${label}"
    "$MODEL_BIN" \
        --mem-dir "${DEMO_ROOT}/apps/${app}_${MEM_CONFIG}" \
        --threads "$ACTIVE_THREADS" \
        --stop "$stop_marker" \
        --drain "$drain" \
        "${EXTRA_ARGS[@]}"
}

if [ "$TARGET_APP" = "all" ]; then
    run_one "[1/2] Simulating hello_world on FROST RTL..." "hello_world" "Hello, world!" 10000
    run_one "[2/2] Simulating CoreMark (1 iteration, CRC-checked) on FROST RTL..." "coremark" "<<PASS>>" 0
    echo ""
    echo "Demonstration finished: hello_world and CoreMark completed on the FROST RTL."
elif [ "$TARGET_APP" = "hello_world" ]; then
    run_one "[1/1] Simulating hello_world on FROST RTL..." "hello_world" "Hello, world!" 10000
elif [ "$TARGET_APP" = "coremark" ]; then
    run_one "[1/1] Simulating CoreMark (1 iteration, CRC-checked) on FROST RTL..." "coremark" "<<PASS>>" 0
fi
