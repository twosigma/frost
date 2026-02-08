# Copyright 2026 Two Sigma Open Source, LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Development environment matching GitHub Actions CI
# Using Ubuntu 24.04 for native Python 3.12 support
FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Verilator version (cocotb 2.0 requires >= 5.036)
ARG VERILATOR_VERSION=5.044

# Yosys version (Ubuntu 24.04 apt has 0.33, we need 0.60+)
ARG YOSYS_VERSION=0.60

# SymbiYosys version (formal verification frontend for Yosys)
ARG SBY_VERSION=0.62

# Z3 SMT solver version (used by SymbiYosys for bounded model checking)
ARG Z3_VERSION=4.15.0

# xPack RISC-V toolchain version (bare-metal, includes newlib)
ARG XPACK_RISCV_VERSION=15.2.0-1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    # Python
    python3 \
    python3-venv \
    python3-pip \
    # HDL simulators (Verilator and Yosys built from source below)
    iverilog \
    # Build tools (shared by Verilator and Yosys)
    make \
    git \
    xxd \
    gawk \
    autoconf \
    flex \
    bison \
    g++ \
    clang \
    clang-format \
    clang-tidy \
    pkg-config \
    # For downloading verible and extracting RISC-V toolchain
    curl \
    xz-utils \
    # Verilator build dependencies
    help2man \
    perl \
    libfl2 \
    libfl-dev \
    zlib1g-dev \
    # Yosys build dependencies
    tcl-dev \
    libreadline-dev \
    libffi-dev \
    libboost-all-dev \
    # Cleanup apt cache
    && rm -rf /var/lib/apt/lists/*

# Install Verible (SystemVerilog formatter and linter)
ARG VERIBLE_VERSION=0.0-4051-g9fdb4057
RUN curl -L https://github.com/chipsalliance/verible/releases/download/v${VERIBLE_VERSION}/verible-v${VERIBLE_VERSION}-linux-static-x86_64.tar.gz \
    | tar -xz -C /usr/local --strip-components=1

# Build Verilator from source
RUN git clone https://github.com/verilator/verilator.git /tmp/verilator \
    && cd /tmp/verilator \
    && git checkout v${VERILATOR_VERSION} \
    && autoconf \
    && ./configure \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/verilator

# Build Yosys from source
RUN git clone https://github.com/YosysHQ/yosys.git /tmp/yosys \
    && cd /tmp/yosys \
    && git checkout v${YOSYS_VERSION} \
    && git submodule update --init \
    && make config-clang \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/yosys

# Build SymbiYosys from source (formal verification frontend for Yosys)
RUN git clone https://github.com/YosysHQ/sby.git /tmp/sby \
    && cd /tmp/sby \
    && git checkout v${SBY_VERSION} \
    && make install \
    && rm -rf /tmp/sby

# Build Z3 SMT solver from source (yosys-smtbmc needs the z3 CLI binary)
RUN git clone https://github.com/Z3Prover/z3.git /tmp/z3 \
    && cd /tmp/z3 \
    && git checkout z3-${Z3_VERSION} \
    && python3 scripts/mk_make.py \
    && cd build \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/z3

# Install xPack RISC-V GCC toolchain (bare-metal with newlib)
RUN curl -fL https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${XPACK_RISCV_VERSION}/xpack-riscv-none-elf-gcc-${XPACK_RISCV_VERSION}-linux-x64.tar.gz \
    | tar -xz -C /opt \
    && ln -s /opt/xpack-riscv-none-elf-gcc-${XPACK_RISCV_VERSION}/bin/* /usr/local/bin/

# Set RISC-V toolchain prefix for Makefiles
ENV RISCV_PREFIX=riscv-none-elf-

# Fix git "dubious ownership" error when mounting repo as volume
RUN git config --global --add safe.directory /workspace

# Install Python dependencies (cocotb, pytest, pre-commit, etc.)
RUN pip install --no-cache-dir --break-system-packages \
    "cocotb==2.0.1" \
    pytest \
    pytest-cov \
    mypy \
    ruff \
    pre-commit \
    click

# Set working directory
WORKDIR /workspace

# Copy and set entrypoint script (initializes submodules if needed)
COPY docker_entrypoint.py /usr/local/bin/
RUN chmod +x /usr/local/bin/docker_entrypoint.py
ENTRYPOINT ["/usr/local/bin/docker_entrypoint.py"]

# Default command
CMD ["/bin/bash"]

# Usage:
#   docker build -t frost-dev .
#   docker run -it --rm -v $(pwd):/workspace frost-dev
#   pytest tests/ -m cocotb --sim verilator
