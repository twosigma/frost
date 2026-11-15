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

# Standalone runtime image for running FROST RTL on hello_world and CoreMark.
# Compiles portable baseline x86-64 Verilator models (-march=x86-64) and
# copies only the compiled binaries and memory images into ubuntu:26.04.

ARG BUILD_IMAGE=frost:latest
FROM ${BUILD_IMAGE} AS build

ARG BUILD_JOBS=8

WORKDIR /src
COPY hw/rtl /src/hw/rtl
COPY hw/sim/native /src/hw/sim/native
COPY sw/common /src/sw/common
COPY sw/lib /src/sw/lib
COPY sw/apps/compile_app.py sw/apps/riscv_toolchain.py sw/apps/software_registry.py /src/sw/apps/
COPY sw/apps/hello_world /src/sw/apps/hello_world
COPY sw/apps/coremark /src/sw/apps/coremark
COPY demo/run_demo.sh /src/demo/run_demo.sh

RUN set -eux; \
    make -C /src/hw/sim/native stage-app APP=hello_world MEM_CONFIG=bram; \
    make -C /src/hw/sim/native stage-app APP=hello_world MEM_CONFIG=ddr; \
    make -C /src/hw/sim/native stage-app APP=coremark MEM_CONFIG=bram; \
    make -C /src/hw/sim/native stage-app APP=coremark MEM_CONFIG=ddr; \
    static_libs="-static-libstdc++ -static-libgcc -Wl,-Bstatic -latomic -Wl,-Bdynamic -Wl,--as-needed"; \
    for t in 1 4 8; do \
        make -C /src/hw/sim/native build \
            THREADS="$t" \
            ASSERTIONS=0 \
            SAVABLE=0 \
            PORTABLE=1 \
            NUMBER_OF_CPU_CORES="${BUILD_JOBS}" \
            NATIVE_LDFLAGS="$static_libs"; \
        install -D -m 0755 \
            "/src/hw/sim/native/sim_build/model_t${t}_a0_s0_x86_64/frost-native" \
            "/out/opt/frost-demo/bin/frost-native-t${t}"; \
        strip --strip-unneeded "/out/opt/frost-demo/bin/frost-native-t${t}"; \
        ! readelf -d "/out/opt/frost-demo/bin/frost-native-t${t}" | grep -E 'lib(stdc\+\+|gcc_s|atomic)'; \
    done; \
    mkdir -p /out/opt/frost-demo/apps; \
    cp -r /src/hw/sim/native/sim_build/apps/* /out/opt/frost-demo/apps/; \
    chmod -R a+rX /out/opt/frost-demo/apps; \
    install -D -m 0755 /src/demo/run_demo.sh /out/opt/frost-demo/bin/run_demo.sh

FROM ubuntu:26.04

COPY --from=build /out/opt/frost-demo /opt/frost-demo

USER ubuntu
WORKDIR /opt/frost-demo
ENTRYPOINT ["/opt/frost-demo/bin/run_demo.sh"]
