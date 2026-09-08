# syntax=docker/dockerfile:1.7
#
# DiveFuzz + XiangShan image  ->  divefuzz-xiangshan:latest
#
# Self-contained: the XiangShan Verilator emulator is BUILT INSIDE this image
# from the commit pinned by this repository's `dut/XiangShan` gitlink. Nothing
# (JDK, mill, Verilator, Scala/Chisel, XiangShan) is installed on the host.
#
# This file is deliberately separate from the root Dockerfile:
#   * the core image `divefuzz:latest` stays small and unchanged;
#   * the RTL build stage pulls in a JDK, mill, a coursier cache, Verilator and
#     tens of GB of generated C++ — none of which reaches the final image.
#
# The final stage is FROM the core DiveFuzz image, so ONE container generates
# the seeds and runs the DUT through the ordinary emu_path/`$1` path.
#
# Build with docker/xiangshan-build.sh, which resolves the pinned gitlink and
# builds the amd64 core image first.
#
# ---------------------------------------------------------------------------
# PLATFORM: linux/amd64 ONLY. This is not a preference, it is a hard upstream
# constraint, verified against the pinned commit:
#
#  1. XiangShan build.sc pins Chisel 6.7.0, which resolves firtool 1.62.0. The
#     Maven artifact org.chipsalliance:llvm-firtool:1.62.0 ships binaries for
#     macos-x64, linux-x64 and windows-x64 only -- there is no linux-arm64
#     build, and the CIRCT firtool-1.62.0 release has the same three assets.
#     Without firtool there is no Chisel -> SystemVerilog step at all.
#  2. XiangShan's `ready-to-run` differential references
#     (riscv64-spike-so, riscv64-nemu-interpreter-so) are
#     "ELF 64-bit LSB shared object, x86-64" -- they cannot be dlopen()ed by an
#     aarch64 emulator.
#
# On an arm64 host this image builds and runs under emulation (Docker Desktop
# / QEMU), which is correct but very slow. Native x86_64 is the supported path.
# ---------------------------------------------------------------------------

# The core DiveFuzz image this one extends. Must be an amd64 build of the root
# Dockerfile; docker/xiangshan-build.sh produces it.
ARG DIVEFUZZ_BASE_IMAGE=divefuzz:amd64

# Same digest-pinned base as the core image, so both stages agree on package
# versions and on libstdc++.
ARG BASE_IMAGE=debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

# XiangShan install prefix. Identical in the build and runtime stages on
# purpose: difftest compiles the absolute path into the emulator
# (-DNOOP_HOME=...), so moving the tree would break run-time lookups.
ARG XS_HOME=/opt/xiangshan


###############################################################################
# Stage 1 -- xs-build: build the XiangShan Verilator emulator.
###############################################################################
FROM --platform=linux/amd64 ${BASE_IMAGE} AS xs-build

ARG XS_HOME
ENV DEBIAN_FRONTEND=noninteractive

# XiangShan source pin. Defaults match this repository's recorded gitlink;
# docker/xiangshan-build.sh passes the value it reads from `git ls-tree HEAD
# dut/XiangShan` so the two can never silently drift. Never a branch name.
ARG XS_REPO_URL=https://github.com/youzi27/XiangShan.git
ARG XS_COMMIT=d5cc24e88fe207105d4ad6d113a972dd6847dd56

# mill is pinned to the version XiangShan itself records in .mill-version at
# the commit above (0.12.3). Verified after download by sha256.
ARG MILL_VERSION=0.12.3
ARG MILL_SHA256=86acc0b9869d09c8983ecfdbeb39682d47eb585e2b46d94148cc528fbb4b83b8

# NOTE: the RTL build-tuning ARGs (XS_CONFIG, XS_JVM_XMX, XS_BUILD_JOBS, ...)
# are deliberately declared LATE, immediately above the `make emu` step. An ARG
# instruction is part of the build graph, so changing its value invalidates
# every layer that follows it. Declared here, retuning the heap would
# re-install the JDK, re-clone XiangShan and re-resolve all Chisel
# dependencies on every attempt. Declared late, only `make emu` re-runs.

# ---------------------------------------------------------------------------
# Toolchain.
#
#   openjdk-21   -- trixie carries no openjdk-17; mill 0.12.3 and Scala 2.13
#                   support 21.
#   verilator    -- 5.032. difftest/verilator.mk enables --no-timing (>=5.000)
#                   and --quiet-stats (>=5.024), so 5.032 satisfies every
#                   version gate it tests for.
#   libsqlite3/z/zstd-dev -- difftest/Makefile links -lsqlite3 (ChiselDB),
#                   -lz (gz images) and -lzstd (zstd images).
#   git          -- XiangShan's SIM_TOP_V rule shells out to `git log`/`git
#                   diff` and prepends the result to the generated Verilog, so
#                   the source tree must be a real repository, not a tarball.
#   time         -- GNU /usr/bin/time. XiangShan's Makefile uses
#                   `time -avp -o build/time.log` around the mill invocations.
#                   That is not the bash keyword: recipes run under /bin/sh
#                   (dash), which has no `time` builtin at all, so without this
#                   package every RTL target dies with "time: not found".
#
# Pinned to the candidate versions resolved against the digest-pinned base,
# matching the convention of the root Dockerfile.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        openjdk-21-jdk-headless=21.0.12.1+1-1~deb13u1 \
        verilator=5.032-1+b2 \
        build-essential=12.12 \
        make=4.4.1-2 \
        cmake=3.31.6-2 \
        git=1:2.47.3-0+deb13u1 \
        time=1.9-0.2 \
        curl=8.14.1-2+deb13u4 \
        ca-certificates=20250419 \
        python3=3.13.5-1 \
        python-is-python3=3.13.3-1 \
        libsqlite3-dev=3.46.1-7+deb13u1 \
        zlib1g-dev=1:1.3.dfsg+really1.3.1-1+b1 \
        libzstd-dev=1.5.7+dfsg-1 \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# mill launcher, pinned and checksum-verified.
#
# The released artifact is a polyglot sh/cmd script with a JAR appended, and it
# carries NO shebang. That matters here: GNU make execve()s a recipe line
# directly when the line contains no shell metacharacters, and XiangShan's
# `deps` recipe is exactly `mill -i __.prepareOffline`. execve() on a
# shebang-less file fails with ENOEXEC, which make reports as the very
# confusing "Error 127" even though `mill` is on PATH and works from a shell.
#
# So keep the verified artifact untouched in /usr/local/lib and expose a real
# shebang'd wrapper on PATH. The launcher uses "$0" as its own classpath
# (-DMILL_CLASSPATH=$0 -cp "$0"), so it must be invoked with the assembly's
# path as $0 -- `exec sh <assembly>` does exactly that.
# ---------------------------------------------------------------------------
RUN mkdir -p /usr/local/lib/mill \
    && curl -fsSL -o "/usr/local/lib/mill/mill-${MILL_VERSION}-assembly" \
        "https://github.com/com-lihaoyi/mill/releases/download/${MILL_VERSION}/${MILL_VERSION}-assembly" \
    && echo "${MILL_SHA256}  /usr/local/lib/mill/mill-${MILL_VERSION}-assembly" | sha256sum -c - \
    && printf '#!/bin/sh\nexec /bin/sh "/usr/local/lib/mill/mill-%s-assembly" "$@"\n' "${MILL_VERSION}" \
        > /usr/local/bin/mill \
    && chmod +x /usr/local/bin/mill \
    && mill --version

ENV NOOP_HOME=${XS_HOME} \
    LC_ALL=C.UTF-8 \
    JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8 \
    COURSIER_CACHE=/root/.cache/coursier
# XiangShan's scripts/Makefile.docker re-launches targets inside its own
# xsdev container when it finds a docker CLI. We are already the container.
ENV IN_XSDEV_DOCKER=y

# The Makefile runs `git log`/`git diff` inside the tree; the checkout below is
# owned by root and git's ownership check would otherwise abort the build.
RUN git config --global --add safe.directory '*'

# ---------------------------------------------------------------------------
# Fetch XiangShan at the exact pinned commit.
#
# Fetching the single commit (not a branch, not a clone of all history) keeps
# the pin explicit and the download small. Submodules are then initialized by
# XiangShan's own `make init`, so difftest, rocket-chip, ready-to-run, huancun,
# fudian, utility, yunsuan, coupledL2, openLLC and ChiselAIA all land on the
# commits recorded *by that XiangShan commit*, not on floating branches.
# ---------------------------------------------------------------------------
RUN mkdir -p "${XS_HOME}" \
    && cd "${XS_HOME}" \
    && git init -q \
    && git remote add origin "${XS_REPO_URL}" \
    && git fetch -q --depth 1 origin "${XS_COMMIT}" \
    && git checkout -q FETCH_HEAD \
    && echo "XiangShan at $(git rev-parse HEAD)" \
    && test "$(git rev-parse HEAD)" = "${XS_COMMIT}"

# `make init` is upstream's own submodule bootstrap (it additionally pulls
# rocket-chip's cde/hardfloat and openLLC's openNCB).
RUN cd "${XS_HOME}" && make init

# Guard the mill version we installed against the one the tree asks for. mill
# would silently bootstrap a different version from .mill-version otherwise.
RUN cd "${XS_HOME}" \
    && test "$(cat .mill-version)" = "${MILL_VERSION}" \
       || { echo "ERROR: XiangShan pins mill $(cat .mill-version), image installed ${MILL_VERSION}."; \
            echo "       Rebuild with --build-arg MILL_VERSION=$(cat .mill-version) and the matching MILL_SHA256."; \
            exit 1; }

# ---------------------------------------------------------------------------
# Resolve Chisel/firtool/Scala dependencies in their own layer, so a rebuild
# that only changes the RTL configuration does not re-download ~1GB, and so an
# unavailable firtool binary fails here with a clear message instead of deep
# inside the Verilog generation step.
# ---------------------------------------------------------------------------
RUN cd "${XS_HOME}" && make deps

# ---------------------------------------------------------------------------
# RTL build configuration. Declared here, not at the top of the stage, so that
# changing any of it re-runs only the step below (see the note above).
#
#   MinimalConfig is the smallest synthesizable XiangShan core. DefaultConfig
#   (the Makefile default) needs ~40G of JVM heap and far more Verilator time
#   and disk; MinimalConfig is what upstream's own README uses for a quick
#   `make emu`. Override with --build-arg for a full core on a big machine.
# ---------------------------------------------------------------------------
ARG XS_CONFIG=MinimalConfig
ARG XS_EMU_THREADS=1
ARG XS_NUM_CORES=1
# XiangShan's Makefile defaults JVM_XMX to 40G, which a small Docker VM cannot
# satisfy. Note this bounds ONLY the JVM: the `make emu` Verilog step also runs
# firtool, a separate NATIVE binary whose memory sits on top of this value. On
# a memory-tight machine an oversized heap therefore makes the kernel OOM
# killer *more* likely, not less. Keep it well under the VM's memory.
ARG XS_JVM_XMX=6G
# Parallelism for the Verilator/C++ compile. Empty means $(nproc).
# Budget roughly 1GB of RAM per job, on top of everything above.
ARG XS_BUILD_JOBS=

# ---------------------------------------------------------------------------
# Build the emulator: Chisel elaboration -> SystemVerilog -> Verilator -> g++.
# This is the expensive step (hours, tens of GB of intermediate files).
# ---------------------------------------------------------------------------
RUN cd "${XS_HOME}" \
    && make emu \
        CONFIG="${XS_CONFIG}" \
        NUM_CORES="${XS_NUM_CORES}" \
        EMU_THREADS="${XS_EMU_THREADS}" \
        JVM_XMX="${XS_JVM_XMX}" \
        -j"${XS_BUILD_JOBS:-$(nproc)}"

# Fail the build here rather than at fuzzing time.
RUN test -x "${XS_HOME}/build/emu" \
    && "${XS_HOME}/build/emu" --help >/dev/null 2>&1 \
    && echo "XiangShan emulator built: $(ls -l "${XS_HOME}/build/emu")"

# Record what was actually built, for the runtime image to report.
RUN cd "${XS_HOME}" && { \
        echo "xiangshan_commit=$(git rev-parse HEAD)"; \
        echo "xiangshan_config=${XS_CONFIG}"; \
        echo "xiangshan_num_cores=${XS_NUM_CORES}"; \
        echo "xiangshan_emu_threads=${XS_EMU_THREADS}"; \
        echo "mill_version=${MILL_VERSION}"; \
        echo "verilator_version=$(verilator --version)"; \
        echo "jdk_version=$(java -version 2>&1 | head -1)"; \
        echo "difftest_commit=$(git -C difftest rev-parse HEAD)"; \
        echo "ready_to_run_commit=$(git -C ready-to-run rev-parse HEAD)"; \
        echo "rocket_chip_commit=$(git -C rocket-chip rev-parse HEAD)"; \
    } > /xiangshan-build-info.txt && cat /xiangshan-build-info.txt

# Strip the emulator: an unstripped MinimalConfig emu is ~1GB of debug info.
RUN strip "${XS_HOME}/build/emu"


###############################################################################
# Stage 2 -- runtime: the core DiveFuzz image plus the built emulator.
###############################################################################
FROM ${DIVEFUZZ_BASE_IMAGE} AS runtime

ARG XS_HOME
ENV DEBIAN_FRONTEND=noninteractive

USER root

# Shared libraries the emulator links against (difftest/Makefile: -lsqlite3
# for ChiselDB, -lz and -lzstd for compressed images). libstdc++6 is already
# present in the core image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsqlite3-0=3.46.1-7+deb13u1 \
        zlib1g=1:1.3.dfsg+really1.3.1-1+b1 \
        libzstd1=1.5.7+dfsg-1 \
    && rm -rf /var/lib/apt/lists/*

# The emulator, at the exact path compiled into it as NOOP_HOME.
COPY --from=xs-build ${XS_HOME}/build/emu ${XS_HOME}/build/emu
# Upstream's prebuilt differential references and reference workloads. These
# are x86-64 shared objects; see the platform note at the top of this file.
COPY --from=xs-build ${XS_HOME}/ready-to-run/ ${XS_HOME}/ready-to-run/
COPY --from=xs-build /xiangshan-build-info.txt ${XS_HOME}/build-info.txt

# Refresh the helper scripts and configs (the core image copied an older
# docker/ directory; this keeps xiangshan-validate.sh and the entrypoint verb
# in sync with the source tree).
COPY docker/ /opt/DiveFuzz/docker/

ENV NOOP_HOME=${XS_HOME} \
    XIANGSHAN_HOME=${XS_HOME} \
    XIANGSHAN_EMU=${XS_HOME}/build/emu

# The emulator writes its ChiselDB/perf artifacts relative to its working
# directory, which dut_executor.py sets to emu_path. Make that writable by the
# non-root runtime user instead of requiring root or a read-only failure.
RUN chmod +x /opt/DiveFuzz/docker/*.sh /opt/DiveFuzz/docker/smoke-dut/emu \
    && chown -R divefuzz:divefuzz "${XS_HOME}"

USER divefuzz
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/divefuzz"]
CMD ["xiangshan-validate"]
