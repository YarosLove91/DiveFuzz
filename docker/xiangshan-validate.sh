#!/usr/bin/env bash
# Real XiangShan validation, run entirely inside divefuzz-xiangshan:latest.
#
# This is NOT the smoke test. There is no fixture: the DUT is the XiangShan
# Verilator emulator that was compiled inside this image from the pinned
# commit. The script proves, in order:
#
#   1. no host toolchain is involved (mill/java/verilator are absent from the
#      runtime image; only the discarded build stage ever had them);
#   2. the emulator binary exists in the image and is executable;
#   3. DiveFuzz generated .S, then .elf, then .img through the real pipeline;
#   4. the emulator received the generated .img via `$1` and `emu_path`;
#   5. the emulator actually started executing (its own banner in the log);
#   6. seed artifacts and logs are in the mounted, persistent location.
#
# Usage:  xiangshan-validate.sh [--no-diff] [--config /work/my.yaml]
#   --no-diff  rewrite the DUT command to disable differential testing
set -uo pipefail

APP_HOME="${DIVEFUZZ_HOME:-/opt/DiveFuzz}"
XS_HOME="${XIANGSHAN_HOME:-/opt/xiangshan}"
WORK="${PWD}"
CONFIG_SRC="${APP_HOME}/docker/xiangshan.yaml"

no_diff=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-diff) no_diff=1; shift ;;
        --config)  CONFIG_SRC="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

echo "=== DiveFuzz + XiangShan end-to-end validation ==="
echo "workdir: ${WORK}"
echo "config:  ${CONFIG_SRC}"
echo
if [ -r "${XS_HOME}/build-info.txt" ]; then
    echo "--- XiangShan build info (recorded at image build time) ---"
    cat "${XS_HOME}/build-info.txt"
    echo
fi

fail=0
note() { printf '%-6s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }

# --- 0. no host / runtime build tooling ------------------------------------
# The RTL toolchain lives only in the discarded build stage. If any of these
# resolve at runtime, the image layering is wrong.
echo "--- toolchain isolation ---"
for tool in mill verilator javac java sbt; do
    if command -v "${tool}" >/dev/null 2>&1; then
        note FAIL "${tool} is present in the runtime image (should be build-stage only)"
    else
        note PASS "${tool} absent from the runtime image"
    fi
done

# --- 1. the emulator exists and is the real thing --------------------------
echo
echo "--- emulator ---"
EMU="${XIANGSHAN_EMU:-${XS_HOME}/build/emu}"
if [ -x "${EMU}" ]; then
    note PASS "XiangShan emulator present: ${EMU} ($(stat -c %s "${EMU}") bytes)"
else
    note FAIL "XiangShan emulator missing at ${EMU}"
    echo
    echo "=== VALIDATION FAILED (no emulator; was the image built with docker/xiangshan.Dockerfile?) ==="
    exit 1
fi

if "${EMU}" --help >/dev/null 2>&1; then
    note PASS "emulator --help runs"
else
    note FAIL "emulator --help failed"
fi

# --- 2. run the real pipeline ----------------------------------------------
# run_dut.py resolves `outputs` relative to the cwd and the config stem becomes
# part of every log filename, so keep the config next to the outputs.
CONFIG="${WORK}/xiangshan.yaml"
if [ "${no_diff}" -eq 1 ]; then
    sed 's#--diff \./ready-to-run/riscv64-spike-so#--no-diff#' "${CONFIG_SRC}" > "${CONFIG}"
    echo
    echo "NOTE: differential testing disabled (--no-diff)."
else
    cp "${CONFIG_SRC}" "${CONFIG}"
fi

# Start from a clean slate so the assertions cannot pass on stale files.
rm -rf "${WORK}/seeds" "${WORK}/outputs"
mkdir -p "${WORK}/seeds" "${WORK}/outputs"

echo
echo "--- running DiveFuzz against XiangShan ---"
python "${APP_HOME}/fuzzer/run_dut.py" --config "${CONFIG}"
run_rc=$?
echo "--- run_dut.py exit code: ${run_rc} ---"
echo

# --- 3. generated artifacts, through the real project pipeline -------------
echo "--- generated artifacts ---"
asm_count=$(find "${WORK}/seeds" -maxdepth 1 -name '*.S' -size +0c | wc -l | tr -d ' ')
[ "${asm_count}" -ge 1 ] \
    && note PASS "generated ${asm_count} non-empty .S assembly seed(s)" \
    || note FAIL "no non-empty .S files in ${WORK}/seeds"

elf_count=$(find "${WORK}/seeds/elf_file" -maxdepth 1 -name '*.elf' -size +0c 2>/dev/null | wc -l | tr -d ' ')
[ "${elf_count}" -ge 1 ] \
    && note PASS "converted ${elf_count} non-empty .elf file(s)" \
    || note FAIL "no non-empty .elf files in ${WORK}/seeds/elf_file"

img_count=$(find "${WORK}/seeds/img_file" -maxdepth 1 -name '*.img' -size +0c 2>/dev/null | wc -l | tr -d ' ')
[ "${img_count}" -ge 1 ] \
    && note PASS "converted ${img_count} non-empty .img seed(s)" \
    || note FAIL "no non-empty .img files in ${WORK}/seeds/img_file"

log_count=$(find "${WORK}/outputs" -name '*.log' -size +0c | wc -l | tr -d ' ')
[ "${log_count}" -ge 1 ] \
    && note PASS "wrote ${log_count} non-empty log file(s) to ${WORK}/outputs" \
    || note FAIL "no non-empty logs in ${WORK}/outputs"

# --- 4. the emulator was invoked with the generated seed via $1 ------------
echo
echo "--- DUT invocation ---"
if grep -rqE 'Command: \./build/emu -i "/work/seeds/img_file/.*\.img"' "${WORK}/outputs" 2>/dev/null; then
    note PASS "\$1 was substituted with the generated .img path"
    grep -rhoE 'Command: \./build/emu .*' "${WORK}/outputs" | head -3 | sed 's/^/       /'
else
    note FAIL "no log shows ./build/emu invoked with a generated .img path"
fi

if grep -rq "Working directory: ${XS_HOME}" "${WORK}/outputs" 2>/dev/null; then
    note PASS "emulator ran with cwd == emu_path (${XS_HOME})"
else
    note FAIL "emulator cwd did not match emu_path"
fi

# --- 5. the emulator actually executed -------------------------------------
# difftest's emu prints these before/while simulating. Any of them proves the
# binary started and consumed the image, as opposed to failing to launch.
echo
echo "--- emulator execution evidence ---"
if grep -rqiE 'HIT (GOOD|BAD) TRAP|simulated .*flash|Simulation Aborted|difftest|core [0-9]+ .*trap|ABORT at pc' \
        "${WORK}/outputs" 2>/dev/null; then
    note PASS "emulator produced its own output in the seed log(s)"
    grep -rhiE 'HIT (GOOD|BAD) TRAP|simulated .*flash|ABORT at pc|Simulation Aborted' \
        "${WORK}/outputs" 2>/dev/null | head -5 | sed 's/^/       /'
else
    note FAIL "no XiangShan emulator output found in ${WORK}/outputs"
    echo "       (seed logs below, for diagnosis)"
    find "${WORK}/outputs" -name '*.img.log' -exec tail -20 {} + 2>/dev/null | sed 's/^/       /'
fi

# Differential result is reported, not asserted: a mismatch is a *finding*,
# which is what a fuzzer is for, not a broken container.
if grep -rq 'HIT GOOD TRAP' "${WORK}/outputs" 2>/dev/null; then
    echo "INFO   emulator reported HIT GOOD TRAP (no difference against the reference)"
elif grep -rqE 'HIT BAD TRAP|ABORT at pc' "${WORK}/outputs" 2>/dev/null; then
    echo "INFO   emulator reported a BAD TRAP / abort — that is a DUT finding, not a container fault"
fi

echo
if [ "${fail}" -eq 0 ]; then
    echo "=== XIANGSHAN VALIDATION PASSED ==="
    echo "seeds: ${WORK}/seeds   logs: ${WORK}/outputs"
else
    echo "=== XIANGSHAN VALIDATION FAILED ==="
fi
exit "${fail}"
