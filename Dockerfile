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

# Development and CI image. The core tools use pinned upstream releases.
FROM ubuntu:26.04

# Disable interactive package prompts.
ENV DEBIAN_FRONTEND=noninteractive

# cocotb 2.1 requires Verilator 5.036 or newer.
ARG VERILATOR_VERSION=5.052

# Yosys and SymbiYosys are released together.
ARG YOSYS_VERSION=0.69

# Keep SymbiYosys aligned with Yosys; older SBY used the removed ABC -fast option.
ARG SBY_VERSION=0.69

ARG Z3_VERSION=5.1.0

ARG BOOLECTOR_VERSION=3.2.4

# LLVM supplies clang, clang-format and clang-tidy from the same release.
ARG LLVM_VERSION=23.1.1
ARG LLVM_SHA256=832aeb58d105de1cabc7b982dd2c65de0610f7377df48ae8fc2dd8e97420a15c

# Install system dependencies
RUN apt-get update && apt-get install -y \
    # Python
    python3 \
    python3-venv \
    python3-pip \
    # Build tools (shared by Verilator, Yosys, and Boolector)
    make \
    git \
    xxd \
    gawk \
    autoconf \
    flex \
    bison \
    g++ \
    pkg-config \
    # Python, GCC and QEMU source-build dependencies
    ca-certificates \
    libbz2-dev \
    liblzma-dev \
    libsqlite3-dev \
    libzstd-dev \
    uuid-dev \
    libgdbm-dev \
    libgmp-dev \
    libmpfr-dev \
    libmpc-dev \
    libglib2.0-dev \
    libpixman-1-dev \
    libssl-dev \
    libncurses-dev \
    texinfo \
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

# Build a released native GCC; Ubuntu's gcc-16 package is a prerelease.
ARG GCC_VERSION=16.2.0
ARG GCC_SHA256=e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e
RUN curl -fL -o /tmp/gcc.tar.xz https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz \
    && echo "${GCC_SHA256}  /tmp/gcc.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/gcc.tar.xz -C /tmp \
    && mkdir /tmp/gcc-build \
    && cd /tmp/gcc-build \
    && /tmp/gcc-${GCC_VERSION}/configure --prefix=/opt/gcc \
        --enable-languages=c,c++ --disable-multilib --disable-bootstrap \
    && make -j$(nproc) \
    && make install-strip \
    && ln -sf /opt/gcc/bin/gcc /opt/gcc/bin/cc \
    && ln -sf /opt/gcc/bin/g++ /opt/gcc/bin/c++ \
    && echo /opt/gcc/lib64 > /etc/ld.so.conf.d/frost-gcc.conf \
    && ldconfig \
    && rm -rf /tmp/gcc*
ENV PATH="/opt/gcc/bin:${PATH}"

# cocotb embeds Python, so install the shared library and register it with ld.so.
# Keep /usr/bin/python3 for distribution utilities; repo commands use /usr/local.
ARG PYTHON_VERSION=3.14.7
ARG PYTHON_SHA256=3b48dac8fb59f62eaa67ac83c1eb12bda1b7a08406dd286e252c11a66be27f81
RUN curl -fL -o /tmp/python.tar.xz https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz \
    && echo "${PYTHON_SHA256}  /tmp/python.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/python.tar.xz -C /tmp \
    && cd /tmp/Python-${PYTHON_VERSION} \
    && ./configure --enable-shared --with-ensurepip=install \
    && make -j$(nproc) \
    && make install \
    && ldconfig \
    && rm -rf /tmp/Python-* /tmp/python.tar.xz

# Install the three tools used by the repo and Clang's builtin headers/runtime.
# These upstream executables statically link LLVM; the archive's other tools
# and shared LLVM libraries would add several GB to every CI image transfer.
RUN curl -fL -o /tmp/llvm.tar.xz https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/LLVM-${LLVM_VERSION}-Linux-X64.tar.xz \
    && echo "${LLVM_SHA256}  /tmp/llvm.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/llvm \
    && tar -xJf /tmp/llvm.tar.xz -C /opt/llvm --strip-components=1 --wildcards \
        '*/bin/clang' '*/bin/clang++' '*/bin/clang-[0-9]*' \
        '*/bin/clang-format' '*/bin/clang-tidy' '*/lib/clang/*' \
    && rm /tmp/llvm.tar.xz
ENV PATH="/opt/llvm/bin:${PATH}"
# Ubuntu also has a prerelease GCC directory without C++ libraries. Tell both
# native Clang drivers to use the complete, released GCC installed above.
RUN echo '--gcc-toolchain=/opt/gcc' > /opt/llvm/bin/clang.cfg \
    && cp /opt/llvm/bin/clang.cfg /opt/llvm/bin/clang++.cfg \
    && clang --version | grep -F "version ${LLVM_VERSION}" \
    && clang-tidy --version | grep -F "version ${LLVM_VERSION}" \
    && clang-format --version | grep -F "version ${LLVM_VERSION}"

ARG PIP_VERSION=26.2.1
ARG CMAKE_VERSION=4.4.3
ARG MESON_VERSION=1.12.0
ARG NINJA_VERSION=1.13.2
RUN python3 -m pip install --no-cache-dir \
    "pip==${PIP_VERSION}" "cmake==${CMAKE_VERSION}" "meson==${MESON_VERSION}" "ninja==${NINJA_VERSION}"

# Install Verible (SystemVerilog formatter and linter)
ARG VERIBLE_VERSION=0.0-4294-gc1d8f5e8
ARG VERIBLE_SHA256=64499cf72cfe88911a015b707a06e18a47effbc0296348b7ca13331d94db6940
RUN curl -fL -o /tmp/verible.tar.gz https://github.com/chipsalliance/verible/releases/download/v${VERIBLE_VERSION}/verible-v${VERIBLE_VERSION}-linux-static-x86_64.tar.gz \
    && echo "${VERIBLE_SHA256}  /tmp/verible.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/verible.tar.gz -C /usr/local --strip-components=1 \
    && rm /tmp/verible.tar.gz

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

# Build Lingeling directly rather than through contrib/setup-lingeling.sh, so
# it gets -Wno-error=incompatible-pointer-types (needed with GCC 14+) and C17
# instead of GCC 15+'s C23 default. Boolector and its bundled btor2tools
# predate CMake 4, so the policy-compatibility setting applies only to them.
RUN git clone https://github.com/Boolector/boolector.git /tmp/boolector \
    && cd /tmp/boolector \
    && git checkout ${BOOLECTOR_VERSION} \
    && mkdir -p deps/install/lib deps/install/include \
    && cd deps \
    && git clone https://github.com/arminbiere/lingeling.git \
    && cd lingeling \
    && git checkout 7d5db72420b95ab356c98ca7f7a4681ed2c59c70 \
    && ./configure.sh -fPIC \
    && sed -i 's/^CFLAGS=\(.*\)/CFLAGS=\1 -std=gnu17 -Wno-error=incompatible-pointer-types/' makefile \
    && make -j$(nproc) \
    && cp liblgl.a ../install/lib/ \
    && cp lglib.h ../install/include/ \
    && cd /tmp/boolector \
    && CMAKE_POLICY_VERSION_MINIMUM=3.5 ./contrib/setup-btor2tools.sh \
    && CMAKE_POLICY_VERSION_MINIMUM=3.5 ./configure.sh \
    && cd build \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/boolector

# Permit a bind-mounted checkout owned by the invoking host user.
RUN git config --global --add safe.directory /workspace

# OpenOCD comes from the apt layer below; ``frost.py doctor`` checks its
# version against this value.
ARG OPENOCD_VERSION=0.12.0

# Host packages for the Buildroot Linux image build (OpenSBI, the test
# userspace, and the NIC module built against Debian's kernel headers; no
# kernel is compiled here), the QEMU boot check, and the OpenOCD debug tests.
# The same packages serve ``load_software.py <board> linux_boot``. Keep the
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
    libfdt-dev \
    openocd \
    libslirp-dev \
    && rm -rf /var/lib/apt/lists/*

# Python's ensurepip does not install setuptools or wheel, and QEMU's offline
# build environment needs both to install its bundled qemu.qmp wheel.
ARG SETUPTOOLS_VERSION=84.0.0
ARG WHEEL_VERSION=0.48.0
RUN python3 -m pip install --no-cache-dir \
    "setuptools==${SETUPTOOLS_VERSION}" "wheel==${WHEEL_VERSION}"

# QEMU's RISC-V system emulator and its bundled OpenSBI, for CI's Linux boot check.
ARG QEMU_VERSION=11.1.1
ARG QEMU_SHA256=079ffbff8a7111bbc89022107cbabf3bbfd614d5fc9d7cc675991196aca12482
RUN curl -fL -o /tmp/qemu.tar.xz https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz \
    && echo "${QEMU_SHA256}  /tmp/qemu.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/qemu.tar.xz -C /tmp \
    && cd /tmp/qemu-${QEMU_VERSION} \
    && ./configure --target-list=riscv64-softmmu --disable-docs --disable-werror \
        --disable-gtk --disable-sdl --disable-opengl --disable-virglrenderer \
        --disable-download \
    && make -j$(nproc) \
    && make install \
    && qemu-system-riscv64 --version | grep -F "${QEMU_VERSION}" \
    && test -f /usr/local/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin \
    && rm -rf /tmp/qemu*

# Python test and pre-commit dependencies. Ruff and mypy live in the pinned
# pre-commit hook environments, so the lint gate has only one version of each.
ARG COCOTB_VERSION=2.1.0
ARG PYTEST_VERSION=9.1.1
ARG PYTEST_COV_VERSION=7.1.0
ARG PRE_COMMIT_VERSION=4.6.2
ARG CLICK_VERSION=8.5.0
RUN python3 -m pip install --no-cache-dir \
    "cocotb==${COCOTB_VERSION}" \
    "pytest==${PYTEST_VERSION}" \
    "pytest-cov==${PYTEST_COV_VERSION}" \
    "pre-commit==${PRE_COMMIT_VERSION}" \
    "click==${CLICK_VERSION}"

# Spike is pinned so architecture-test reference signatures are reproducible.
# Its bundled libfdt needs C17: C23 makes memchr preserve const qualifiers.
# ``dtc`` comes from the apt layer. Keep this late to preserve earlier
# tool-build caches.
ARG SPIKE_VERSION=02b1dc182164bb73b19b050676dd89f0834f8b2e
RUN git clone https://github.com/riscv-software-src/riscv-isa-sim.git /tmp/riscv-isa-sim \
    && cd /tmp/riscv-isa-sim \
    && git checkout ${SPIKE_VERSION} \
    && mkdir build \
    && cd build \
    && CFLAGS="-O2 -std=gnu17" ../configure --prefix=/usr/local \
    && make -j$(nproc) \
    && make install \
    && strip --strip-debug /usr/local/bin/spike /usr/local/bin/spike-log-parser \
        /usr/local/bin/xspike /usr/local/bin/termios-xspike \
        /usr/local/lib/libriscv.so /usr/local/lib/libcustomext.so \
        /usr/local/lib/libsoftfloat.so \
    && rm -rf /tmp/riscv-isa-sim

# sv2v converts SystemVerilog for the portable Ethernet synthesis check, which
# uses Yosys's read_verilog frontend. Keep this release identical to the pin in
# tests/net10g/synthesize.py, which uses this binary only when its version
# matches that pin and otherwise downloads the pinned archive. ``unzip`` comes
# from the apt layer above. Keep this late to preserve earlier tool-build
# caches.
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

# One RISC-V toolchain for bare-metal apps, OpenSBI and Linux. Bare-metal
# Makefiles explicitly disable PIE and use FROST's startup/runtime; OpenSBI
# retains its PIE link and Linux userspace uses musl. Keep this archive aligned
# with frost_rv64_defconfig and the external tree's toolchain hash.
ARG BOOTLIN_RISCV64_MUSL_VERSION=2026.08-1
ARG BOOTLIN_RISCV64_MUSL_SHA256=747286a6aec5def762a68491a884195a3a415352c76f70140e36eac48c77b73c
RUN curl -fL -o /tmp/bootlin-riscv64.tar.xz \
        https://toolchains.bootlin.com/downloads/releases/toolchains/riscv64-lp64d/tarballs/riscv64-lp64d--musl--stable-${BOOTLIN_RISCV64_MUSL_VERSION}.tar.xz \
    && echo "${BOOTLIN_RISCV64_MUSL_SHA256}  /tmp/bootlin-riscv64.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/bootlin-riscv64.tar.xz -C /opt \
    && rm -f /tmp/bootlin-riscv64.tar.xz \
    && ln -s /opt/riscv64-lp64d--musl--stable-${BOOTLIN_RISCV64_MUSL_VERSION} /opt/riscv64-linux-musl

# Shared compiler prefix. Buildroot downloads the same release itself so
# native Vivado loaders can build the userspace too.
ENV PATH="/opt/riscv64-linux-musl/bin:${PATH}"
ENV RISCV_PREFIX=riscv64-linux-
ENV FROST_LINUX_CROSS_COMPILE=riscv64-linux-
ENV FROST_LINUX_TOOLCHAIN_PATH=/opt/riscv64-linux-musl

# Reproducible VS Code extension build/test/package tooling.
ARG NODE_VERSION=26.9.0
ARG NPM_VERSION=12.0.2
ARG NODE_SHA256=c6ecd8efc1c1d395265891675319da7a7b3785c6be174bd78933cf4f057624d1
RUN curl -fL -o /tmp/node.tar.xz https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz \
    && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && npm install --global --ignore-scripts "npm@${NPM_VERSION}"

# Buildroot rejects Ubuntu 26.04's uutils install (upstream issue #12166).
# GNU install is supplied by coreutils alongside it; select that implementation
# for the native host-package and target-rootfs installs at container runtime.
RUN update-alternatives --install /usr/bin/install install /usr/bin/gnuinstall 100

# Use the bind-mounted repository as the workspace.
WORKDIR /workspace

# Embed the exact local image inputs so ``frost.py doctor`` can distinguish a
# current image from one that merely happens to expose similar tool versions.
COPY Dockerfile docker_entrypoint.py /usr/local/share/frost-image-inputs/

# Install the submodule-initializing entrypoint.
COPY docker_entrypoint.py /usr/local/bin/
# Some source installs leave /usr/local/bin too private for ``docker run --user``.
RUN chmod 0755 /usr/local/bin \
    && chmod 0755 /usr/local/lib /usr/local/share /usr/local/include \
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
