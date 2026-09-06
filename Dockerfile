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

# GitHub CI environment; Ubuntu 24.04 supplies Python 3.12.
FROM ubuntu:24.04

# Disable interactive package prompts.
ENV DEBIAN_FRONTEND=noninteractive

# cocotb 2.1 requires Verilator 5.036 or newer.
ARG VERILATOR_VERSION=5.052

# Ubuntu ships Yosys 0.33; FROST needs 0.64+.
ARG YOSYS_VERSION=0.68

# Keep SymbiYosys aligned with Yosys; older SBY used the removed ABC -fast option.
ARG SBY_VERSION=0.68

ARG Z3_VERSION=4.15.0

ARG BOOLECTOR_VERSION=3.2.4

# Bare-metal toolchain with newlib.
ARG XPACK_RISCV_VERSION=15.2.0-1

# Pin Ubuntu clang-tidy so package drift cannot change the lint gate.
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
    # Downloads and archive extraction
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

# Build Yosys from source (0.67+ uses CMake).
RUN git clone https://github.com/YosysHQ/yosys.git /tmp/yosys \
    && cd /tmp/yosys \
    && git checkout v${YOSYS_VERSION} \
    && git submodule update --init --recursive \
    && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DYOSYS_USE_BUNDLED_LIBS=ON \
    && cmake --build build --parallel $(nproc) \
    && cmake --install build --strip \
    && rm -rf /tmp/yosys

# Build SymbiYosys from source.
RUN git clone https://github.com/YosysHQ/sby.git /tmp/sby \
    && cd /tmp/sby \
    && git checkout v${SBY_VERSION} \
    && make install \
    && rm -rf /tmp/sby

# yosys-smtbmc needs the Z3 CLI.
RUN git clone https://github.com/Z3Prover/z3.git /tmp/z3 \
    && cd /tmp/z3 \
    && git checkout z3-${Z3_VERSION} \
    && python3 scripts/mk_make.py \
    && cd build \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/z3

# Lingeling needs -Wno-error=incompatible-pointer-types with GCC 14+, so build
# it directly instead of using contrib/setup-lingeling.sh.
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

# Install the xPack bare-metal RISC-V toolchain.
RUN curl -fL https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${XPACK_RISCV_VERSION}/xpack-riscv-none-elf-gcc-${XPACK_RISCV_VERSION}-linux-x64.tar.gz \
    | tar -xz -C /opt \
    && ln -s /opt/xpack-riscv-none-elf-gcc-${XPACK_RISCV_VERSION}/bin/* /usr/local/bin/

# Prefix consumed by the software Makefiles.
ENV RISCV_PREFIX=riscv-none-elf-

# Permit a bind-mounted checkout owned by the invoking host user.
RUN git config --global --add safe.directory /workspace

# Buildroot host dependencies and QEMU for the no-MMU Linux build and boot
# lanes. This also supports ``load_software.py <board> linux_boot``. Keep the
# layer late to preserve the expensive tool-build cache above.
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
    openocd \
    && rm -rf /var/lib/apt/lists/*

# Python test and pre-commit dependencies. Do not install standalone ruff or
# mypy: pre-commit creates the pinned hook environments used by CI. Standalone
# versions have drifted from the gate (ruff 0.15.20 vs pinned 0.8.4 on
# 2026-07-11).
ARG COCOTB_VERSION=2.1.0
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

# Pinned Spike generates reproducible architecture-test signatures. ``dtc``
# comes from the apt layer. Keep this late
# to preserve earlier tool-build caches.
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

# SystemVerilog conversion for the portable Ethernet synthesis check, which
# uses Yosys's read_verilog frontend. Keep this release
# identical to the pin in tests/net10g/synthesize.py, which prefers this binary
# and only downloads the same archive when an older image lacks it. ``unzip``
# comes from the apt layer above. Keep this late to preserve earlier
# tool-build caches.
ARG SV2V_VERSION=0.0.13
ARG SV2V_SHA256=552799a1d76cd177b9b4cc63a3e77823a3d2a6eb4ec006569288abeff28e1ff8
RUN curl -fL -o /tmp/sv2v-Linux.zip https://github.com/zachjs/sv2v/releases/download/v${SV2V_VERSION}/sv2v-Linux.zip \
    && echo "${SV2V_SHA256}  /tmp/sv2v-Linux.zip" | sha256sum -c - \
    && unzip -j /tmp/sv2v-Linux.zip sv2v-Linux/sv2v -d /usr/local/bin \
    && mkdir -p /usr/local/share/doc/sv2v \
    && unzip -j /tmp/sv2v-Linux.zip sv2v-Linux/LICENSE sv2v-Linux/NOTICE \
        -d /usr/local/share/doc/sv2v \
    && chmod 0755 /usr/local/bin/sv2v \
    && chmod 0444 /usr/local/share/doc/sv2v/* \
    && rm -f /tmp/sv2v-Linux.zip

# Linux-targeted RISC-V toolchain: the Bootlin riscv64 musl release that the
# Buildroot MMU Linux lane uses as its external toolchain. It also builds the
# OpenSBI firmware (linux/opensbi_build.py): OpenSBI links as a PIE, which the
# bare-metal xPack linker above cannot do. Pinned to the release Buildroot's
# BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_RISCV64_LP64D_MUSL_STABLE selects, with the
# hash from toolchain-external-bootlin.hash. Keep this late to preserve the
# earlier tool-build caches.
ARG BOOTLIN_RISCV64_MUSL_VERSION=2025.08-1
ARG BOOTLIN_RISCV64_MUSL_SHA256=2c5155ce133c9c8dddde8f69b0715aa07e0520d99b1fd0131d915357c6fbce39
RUN curl -fL -o /tmp/bootlin-riscv64.tar.xz \
        https://toolchains.bootlin.com/downloads/releases/toolchains/riscv64-lp64d/tarballs/riscv64-lp64d--musl--stable-${BOOTLIN_RISCV64_MUSL_VERSION}.tar.xz \
    && echo "${BOOTLIN_RISCV64_MUSL_SHA256}  /tmp/bootlin-riscv64.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/bootlin-riscv64.tar.xz -C /opt \
    && rm -f /tmp/bootlin-riscv64.tar.xz \
    && ln -s /opt/riscv64-lp64d--musl--stable-${BOOTLIN_RISCV64_MUSL_VERSION} /opt/riscv64-linux-musl

# Prefix consumed by linux/opensbi_build.py and the Buildroot lane's
# preinstalled-toolchain path (BR2_TOOLCHAIN_EXTERNAL_PATH).
ENV PATH="/opt/riscv64-linux-musl/bin:${PATH}"
ENV FROST_LINUX_CROSS_COMPILE=riscv64-linux-
ENV FROST_LINUX_TOOLCHAIN_PATH=/opt/riscv64-linux-musl

# Use the bind-mounted repository as the workspace.
WORKDIR /workspace

# Embed the exact local image inputs so ``frost.py doctor`` can distinguish a
# current image from one that merely happens to expose similar tool versions.
COPY Dockerfile docker_entrypoint.py /usr/local/share/frost-image-inputs/

# Install the submodule-initializing entrypoint.
COPY docker_entrypoint.py /usr/local/bin/
# Some source installs leave /usr/local/bin too private for ``docker run --user``.
RUN chmod 0755 /usr/local/bin \
    && chmod 0755 /usr/local/bin/docker_entrypoint.py \
    && chmod 0444 /usr/local/share/frost-image-inputs/*
ENTRYPOINT ["/usr/local/bin/docker_entrypoint.py"]

# Default to a shell when no command is supplied.
CMD ["/bin/bash"]

# Usage:
#   docker build -t frost .
#   ./scripts/frost.py doctor
#   ./scripts/frost.py check
#   ./scripts/frost.py cocotb hello_world
#   ./scripts/frost.py shell
