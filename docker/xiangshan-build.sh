#!/usr/bin/env bash
# Documented build command for the DiveFuzz + XiangShan image.
#
#   ./docker/xiangshan-build.sh
#
# Builds, in order:
#   1. divefuzz:amd64            -- the core image (root Dockerfile), linux/amd64
#   2. divefuzz-xiangshan:latest -- core image + XiangShan emulator built from
#                                   the commit pinned by dut/XiangShan
#
# Nothing is installed on the host: no JDK, no mill, no Verilator, no Scala.
# Only docker and git are used.
#
# Environment overrides:
#   DIVEFUZZ_BASE_IMAGE   core image tag to build/reuse   (divefuzz:amd64)
#   XIANGSHAN_IMAGE       output image tag                (divefuzz-xiangshan:latest)
#   XS_CONFIG             XiangShan config                (MinimalConfig)
#   XS_EMU_THREADS        emulator threads                (1)
#   XS_NUM_CORES          cores in the SoC                (1)
#   XS_JVM_XMX            JVM heap for Chisel elaboration (6G)
#   XS_BUILD_JOBS         make -j for Verilator/g++       ($(nproc) in image)
#   SKIP_BASE=1           reuse an existing core image without rebuilding
#
# Everything after `--` is passed to the XiangShan `docker build`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BASE_IMAGE="${DIVEFUZZ_BASE_IMAGE:-divefuzz:amd64}"
IMAGE="${XIANGSHAN_IMAGE:-divefuzz-xiangshan:latest}"
XS_CONFIG="${XS_CONFIG:-MinimalConfig}"
XS_EMU_THREADS="${XS_EMU_THREADS:-1}"
XS_NUM_CORES="${XS_NUM_CORES:-1}"
XS_JVM_XMX="${XS_JVM_XMX:-6G}"
XS_BUILD_JOBS="${XS_BUILD_JOBS:-}"

for tool in git docker; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "ERROR: ${tool} is required." >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Resolve the XiangShan pin from the repository itself, never from a branch.
#
# `git ls-tree` reads the gitlink recorded in HEAD, so this works whether or
# not dut/XiangShan has ever been checked out on this machine.
# ---------------------------------------------------------------------------
XS_COMMIT="$(git ls-tree HEAD dut/XiangShan | awk '$2 == "commit" { print $3 }')"
XS_REPO_URL="$(git config --file .gitmodules --get submodule.dut/XiangShan.url || true)"

if [ -z "${XS_COMMIT}" ] || [ -z "${XS_REPO_URL}" ]; then
    echo "ERROR: could not resolve the pinned dut/XiangShan commit or URL." >&2
    echo "       Expected a gitlink in HEAD and an entry in .gitmodules." >&2
    exit 1
fi

echo "==> Pinned DiveFuzz revision : $(git rev-parse HEAD)"
echo "==> Pinned XiangShan         : ${XS_COMMIT}"
echo "==> XiangShan repository     : ${XS_REPO_URL}"
echo "==> RTL configuration        : ${XS_CONFIG} (NUM_CORES=${XS_NUM_CORES}, EMU_THREADS=${XS_EMU_THREADS})"
echo

# ---------------------------------------------------------------------------
# Platform note. This is a hard constraint, not a preference:
#   * Chisel 6.7.0 -> firtool 1.62.0, published for linux-x64 only (no arm64);
#   * XiangShan's ready-to-run diff references are x86-64 shared objects.
# On arm64 hosts Docker runs the build under QEMU: correct, but very slow.
# ---------------------------------------------------------------------------
host_arch="$(uname -m)"
if [ "${host_arch}" != "x86_64" ]; then
    echo "NOTE: host architecture is ${host_arch}; this image is linux/amd64 only."
    echo "      (Chisel 6.7.0 resolves firtool 1.62.0, which has no linux-arm64"
    echo "       binary, and XiangShan's diff references are x86-64 objects.)"
    echo "      The build will run under emulation and take considerably longer."
    echo
fi

# ---------------------------------------------------------------------------
# 1. Core DiveFuzz image, linux/amd64.
# ---------------------------------------------------------------------------
if [ "${SKIP_BASE:-0}" = "1" ]; then
    docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1 || {
        echo "ERROR: SKIP_BASE=1 but ${BASE_IMAGE} does not exist locally." >&2
        exit 1; }
    echo "==> Reusing existing core image ${BASE_IMAGE}"
else
    echo "==> Building core image ${BASE_IMAGE} (linux/amd64)"
    DIVEFUZZ_IMAGE="${BASE_IMAGE}" "${REPO_ROOT}/docker/build.sh" --platform linux/amd64
fi
echo

# ---------------------------------------------------------------------------
# 2. XiangShan image.
# ---------------------------------------------------------------------------
echo "==> Building ${IMAGE} (this compiles XiangShan RTL; expect hours)"
docker build \
    --platform linux/amd64 \
    -f docker/xiangshan.Dockerfile \
    -t "${IMAGE}" \
    --build-arg "DIVEFUZZ_BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "XS_REPO_URL=${XS_REPO_URL}" \
    --build-arg "XS_COMMIT=${XS_COMMIT}" \
    --build-arg "XS_CONFIG=${XS_CONFIG}" \
    --build-arg "XS_EMU_THREADS=${XS_EMU_THREADS}" \
    --build-arg "XS_NUM_CORES=${XS_NUM_CORES}" \
    --build-arg "XS_JVM_XMX=${XS_JVM_XMX}" \
    --build-arg "XS_BUILD_JOBS=${XS_BUILD_JOBS}" \
    "$@" \
    .

echo
echo "Built ${IMAGE}"
docker run --rm --platform linux/amd64 "${IMAGE}" cat /opt/xiangshan/build-info.txt || true
echo
echo "Next: ./docker/xiangshan-validate-host.sh"
