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
ARG VERILATOR_VERSION=5.050

# Yosys version (Ubuntu 24.04 apt has 0.33, we need 0.64+)
ARG YOSYS_VERSION=0.64

# SymbiYosys version (formal verification frontend for Yosys)
ARG SBY_VERSION=0.63

# Z3 SMT solver version (used by SymbiYosys for bounded model checking)
ARG Z3_VERSION=4.15.0

# Boolector SMT solver version (word-level solver, efficient for bitvector-heavy designs)
ARG BOOLECTOR_VERSION=3.2.4

# xPack RISC-V toolchain version (bare-metal, includes newlib)
ARG XPACK_RISCV_VERSION=15.2.0-1

# Ubuntu's clang-tidy package is used by the local pre-commit hook. Assert its
# exact frontend version so a base-image/package drift fails the image build
# instead of silently changing the lint gate.
ARG CLANG_TIDY_VERSION=18.1.3

# Install system dependencies
RUN apt-get update && apt-get install -y \
    # Python
    python3 \
    python3-venv \
    python3-pip \
    # Build tools (shared by Verilator, Yosys, and Boolector)
    make \
    cmake \
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

RUN clang-tidy --version | grep -F "version ${CLANG_TIDY_VERSION}"

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

# Build Boolector SMT solver from source (word-level, efficient for memory arrays)
# Lingeling (SAT dependency) needs -Wno-error=incompatible-pointer-types for GCC 14+
# so we build it manually instead of using contrib/setup-lingeling.sh
RUN git clone https://github.com/Boolector/boolector.git /tmp/boolector \
    && cd /tmp/boolector \
    && git checkout ${BOOLECTOR_VERSION} \
    && mkdir -p deps/install/lib deps/install/include \
    && cd deps \
    && git clone https://github.com/arminbiere/lingeling.git \
    && cd lingeling \
    && git checkout 7d5db72420b95ab356c98ca7f7a4681ed2c59c70 \
    && ./configure.sh -fPIC \
    && sed -i 's/^CFLAGS=\(.*\)/CFLAGS=\1 -Wno-error=incompatible-pointer-types/' makefile \
    && make -j$(nproc) \
    && cp liblgl.a ../install/lib/ \
    && cp lglib.h ../install/include/ \
    && cd /tmp/boolector \
    && ./contrib/setup-btor2tools.sh \
    && ./configure.sh \
    && cd build \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/boolector

# Install xPack RISC-V GCC toolchain (bare-metal with newlib)
RUN curl -fL https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${XPACK_RISCV_VERSION}/xpack-riscv-none-elf-gcc-${XPACK_RISCV_VERSION}-linux-x64.tar.gz \
    | tar -xz -C /opt \
    && ln -s /opt/xpack-riscv-none-elf-gcc-${XPACK_RISCV_VERSION}/bin/* /usr/local/bin/

# Set RISC-V toolchain prefix for Makefiles
ENV RISCV_PREFIX=riscv-none-elf-

# Fix git "dubious ownership" error when mounting repo as volume
RUN git config --global --add safe.directory /workspace

# Buildroot host dependencies + QEMU. Used by the FROST no-MMU Linux CI jobs:
#   * build-frost-linux  - builds the kernel + initramfs + FROST memory images
#     from the linux/buildroot-external tree (Buildroot compiles its own rv64
#     uClibc cross toolchain from source, so it needs a full host build env).
#   * qemu-linux-boot     - boots the same Image + rootfs to a shell under
#     qemu-system-riscv64 (qemu-system-misc provides the riscv64 target).
# `load_software.py <board> linux_boot` self-builds via the same path, so these
# are the single source of truth for the Linux build's host deps. Kept as a late
# layer so the expensive Verilator/Yosys/SMT source builds above stay cached.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    patch \
    cpio \
    rsync \
    bc \
    file \
    unzip \
    wget \
    bzip2 \
    ccache \
    libssl-dev \
    libelf-dev \
    libncurses-dev \
    device-tree-compiler \
    qemu-system-misc \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies (cocotb, pytest, pre-commit, etc.)
# Deliberately NO standalone ruff/mypy: linting runs through pre-commit
# (CI: `pre-commit run --all-files` in this image), which builds its own
# hook environments at the versions pinned in .pre-commit-config.yaml.
# Unpinned standalone binaries drift ahead of those pins and disagree
# with the real gate (seen 2026-07-11: image ruff 0.15.20 vs pin v0.8.4).
ARG COCOTB_VERSION=2.0.1
ARG PYTEST_VERSION=9.1.1
ARG PYTEST_COV_VERSION=7.1.0
ARG PRE_COMMIT_VERSION=4.6.0
ARG CLICK_VERSION=8.4.2
RUN pip install --no-cache-dir --break-system-packages \
    "cocotb==${COCOTB_VERSION}" \
    "pytest==${PYTEST_VERSION}" \
    "pytest-cov==${PYTEST_COV_VERSION}" \
    "pre-commit==${PRE_COMMIT_VERSION}" \
    "click==${CLICK_VERSION}"

# Spike (riscv-isa-sim) - the golden-reference generator for the arch-test
# signature suites (docs/rv64/phase1_plan.md D10). Pinned so reference
# regeneration (sw/apps/arch_test/generate_references.py) is
# containerized and reproducible; the previously-unpinned host-Spike
# provenance is retired. Runtime dep (dtc) comes from device-tree-compiler
# in the apt layer above. Kept late so the cached tool builds above survive.
ARG SPIKE_VERSION=3d8eb089bd289c59dcb506f197a172e02beb7b5b
RUN git clone https://github.com/riscv-software-src/riscv-isa-sim.git /tmp/riscv-isa-sim \
    && cd /tmp/riscv-isa-sim \
    && git checkout ${SPIKE_VERSION} \
    && mkdir build \
    && cd build \
    && ../configure --prefix=/usr/local \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/riscv-isa-sim

# Set working directory
WORKDIR /workspace

# Embed the exact local image inputs so ``frost.py doctor`` can distinguish a
# current image from one that merely happens to expose similar tool versions.
COPY Dockerfile docker_entrypoint.py /usr/local/share/frost-image-inputs/

# Copy and set entrypoint script (initializes submodules if needed).
COPY docker_entrypoint.py /usr/local/bin/
# Some source-tool install steps preserve an unexpectedly private mode on the
# shared bin directory.  Keep the image usable with ``docker run --user`` so a
# bind-mounted checkout does not accumulate root-owned build artifacts.
RUN chmod 0755 /usr/local/bin \
    && chmod 0755 /usr/local/bin/docker_entrypoint.py \
    && chmod 0444 /usr/local/share/frost-image-inputs/*
ENTRYPOINT ["/usr/local/bin/docker_entrypoint.py"]

# Default command
CMD ["/bin/bash"]

# Usage:
#   docker build -t frost .
#   ./scripts/frost.py doctor
#   ./scripts/frost.py check
#   ./scripts/frost.py cocotb hello_world
#   ./scripts/frost.py shell
