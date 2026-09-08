#!/usr/bin/env bash
# Host-side wrapper for the real XiangShan validation.
#
# Runs docker/xiangshan-validate.sh inside divefuzz-xiangshan:latest with a
# persistent bind mount, then asserts from the *host* that the seeds, the
# emulator output and the logs survived outside the container.
#
# This is not the smoke test: the DUT is the XiangShan Verilator emulator
# compiled inside the image, not a fixture.
#
# Usage:  ./docker/xiangshan-validate-host.sh [--no-diff]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${XIANGSHAN_IMAGE:-divefuzz-xiangshan:latest}"
OUT_DIR="${DIVEFUZZ_WORKDIR:-${REPO_ROOT}/docker-xiangshan-out}"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

echo "==> Running XiangShan validation in ${IMAGE}"
echo "    persistent workdir (host): ${OUT_DIR}"
echo

docker run --rm \
    --platform linux/amd64 \
    -v "${OUT_DIR}:/work" \
    "${IMAGE}" xiangshan-validate "$@"
container_rc=$?

echo
echo "==> Container exit code: ${container_rc}"
echo "==> Host-side artifact verification"

host_fail=0
note() { printf '%-6s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && host_fail=1; return 0; }

for kind in "seeds:*.S" "seeds/elf_file:*.elf" "seeds/img_file:*.img"; do
    dir="${kind%%:*}"; pat="${kind##*:}"
    n=$(find "${OUT_DIR}/${dir}" -maxdepth 1 -name "${pat}" -size +0c 2>/dev/null | wc -l | tr -d ' ')
    [ "${n}" -ge 1 ] \
        && note PASS "host sees ${n} non-empty ${pat} in ${OUT_DIR}/${dir}" \
        || note FAIL "no non-empty ${pat} visible on the host in ${OUT_DIR}/${dir}"
done

logs=$(find "${OUT_DIR}/outputs" -name '*.log' -size +0c 2>/dev/null | wc -l | tr -d ' ')
[ "${logs}" -ge 1 ] \
    && note PASS "host sees ${logs} non-empty log(s) in ${OUT_DIR}/outputs" \
    || note FAIL "no non-empty logs visible on the host"

# The emulator's own output must be in the persisted per-seed logs.
if grep -rqiE 'HIT (GOOD|BAD) TRAP|simulated .*flash|ABORT at pc' "${OUT_DIR}/outputs" 2>/dev/null; then
    note PASS "host sees XiangShan emulator output in the persisted logs"
else
    note FAIL "no XiangShan emulator output in the persisted logs"
fi

[ "${container_rc}" -eq 0 ] \
    && note PASS "container exited 0" \
    || note FAIL "container exited ${container_rc}"

echo
if [ "${host_fail}" -eq 0 ] && [ "${container_rc}" -eq 0 ]; then
    echo "=== XIANGSHAN END-TO-END VALIDATION PASSED ==="
    echo "artifacts: ${OUT_DIR}"
    exit 0
fi
echo "=== XIANGSHAN END-TO-END VALIDATION FAILED ==="
echo "artifacts (for diagnosis): ${OUT_DIR}"
exit 1
