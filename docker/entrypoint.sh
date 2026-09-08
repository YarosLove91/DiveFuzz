#!/usr/bin/env bash
# DiveFuzz container entrypoint.
#
#   <no args> | --help | --config X   -> fuzzer/run_dut.py
#   probe                             -> runtime dependency probes
#   smoke                             -> end-to-end smoke test (fixture DUT)
#   xiangshan-validate                -> real XiangShan validation; only present
#                                        in divefuzz-xiangshan:latest
#   anything else                     -> executed verbatim (bash, python, ...)
set -euo pipefail

APP_HOME="${DIVEFUZZ_HOME:-/opt/DiveFuzz}"

case "${1:-}" in
    "")
        exec python "${APP_HOME}/fuzzer/run_dut.py" --help
        ;;
    -*)
        exec python "${APP_HOME}/fuzzer/run_dut.py" "$@"
        ;;
    probe)
        exec "${APP_HOME}/docker/probe.sh"
        ;;
    smoke)
        shift
        exec "${APP_HOME}/docker/smoke-test.sh" "$@"
        ;;
    xiangshan-validate)
        shift
        # The script ships in every image, but the emulator it drives only
        # exists in divefuzz-xiangshan. Fail with an actionable message.
        if [ ! -x "${XIANGSHAN_EMU:-/opt/xiangshan/build/emu}" ]; then
            echo "ERROR: no XiangShan emulator in this image." >&2
            echo "       xiangshan-validate needs divefuzz-xiangshan:latest;" >&2
            echo "       build it with ./docker/xiangshan-build.sh." >&2
            exit 1
        fi
        exec "${APP_HOME}/docker/xiangshan-validate.sh" "$@"
        ;;
    *)
        exec "$@"
        ;;
esac
