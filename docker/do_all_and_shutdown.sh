#!/usr/bin/env bash
# Unattended DiveFuzz + XiangShan run for a compute server or cluster node.
#
# Nothing is installed on the host: no JDK, no mill, no Verilator, no Scala,
# no XiangShan. Only docker (and git, for the build step) are used.
#
# The script:
#   1. optionally builds divefuzz-xiangshan:latest (skipped if it exists);
#   2. runs DiveFuzz inside the container with a persistent /work mount;
#   3. leaves seeds, per-seed logs and a run transcript on the host;
#   4. exits with the container's exit code;
#   5. optionally powers the machine off afterwards (opt-in, never default).
#
# It never requires an interactive shell inside the container.
#
# Usage:
#   ./docker/do_all_and_shutdown.sh                          # validation config
#   ./docker/do_all_and_shutdown.sh my_run.yaml              # your own config
#   ./docker/do_all_and_shutdown.sh --config my_run.yaml     # same, explicit
#   ./docker/do_all_and_shutdown.sh my_run.yaml --shutdown
#
# Options:
#   <file>            A bare argument is taken as --config.
#   --config <file>   YAML config on the HOST. It is copied into the work
#                     directory and passed as a /work path, so it must only
#                     reference container paths inside (see docker/xiangshan.yaml).
#                     Omitted: runs docker/xiangshan-validate.sh instead.
#   --work <dir>      host directory mounted at /work (default: ./divefuzz-run)
#   --build           force an image build even if the image already exists
#   --shutdown        `shutdown -h now` after the run. OFF by default: it
#                     powers off the machine, so it must be asked for.
#   --                everything after this is passed to `docker run`
#
# Environment:
#   XIANGSHAN_IMAGE   image to use (default divefuzz-xiangshan:latest)
#   XS_CONFIG, XS_JVM_XMX, ...  forwarded to docker/xiangshan-build.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${XIANGSHAN_IMAGE:-divefuzz-xiangshan:latest}"

CONFIG=""
WORK_DIR="${REPO_ROOT}/divefuzz-run"
FORCE_BUILD=0
DO_SHUTDOWN=0
DOCKER_EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --config)   CONFIG="$2"; shift 2 ;;
        --work)     WORK_DIR="$2"; shift 2 ;;
        --build)    FORCE_BUILD=1; shift ;;
        --shutdown) DO_SHUTDOWN=1; shift ;;
        --)         shift; DOCKER_EXTRA=("$@"); break ;;
        -h|--help)  sed -n '2,42p' "$0"; exit 0 ;;
        -*)         echo "unknown option: $1" >&2; exit 2 ;;
        # A bare path is the config, so `do_all_and_shutdown.sh my_run.yaml`
        # works as well as the explicit --config form.
        *)          if [ -n "${CONFIG}" ]; then
                        echo "ERROR: more than one config given: ${CONFIG}, $1" >&2
                        exit 2
                    fi
                    CONFIG="$1"; shift ;;
    esac
done

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required." >&2; exit 1; }

# Validate the config BEFORE the image build. Building the XiangShan image can
# take hours, so a typo in the path must fail in the first second, not after.
if [ -n "${CONFIG}" ] && [ ! -r "${CONFIG}" ]; then
    echo "ERROR: config not readable: ${CONFIG}" >&2
    exit 1
fi

mkdir -p "${WORK_DIR}" || { echo "ERROR: cannot create ${WORK_DIR}" >&2; exit 1; }
WORK_DIR="$(cd "${WORK_DIR}" && pwd)"
TRANSCRIPT="${WORK_DIR}/run-$(date -u +%Y%m%dT%H%M%SZ).log"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "${TRANSCRIPT}"; }

log "DiveFuzz + XiangShan unattended run"
log "image:     ${IMAGE}"
log "work dir:  ${WORK_DIR}"
log "transcript:${TRANSCRIPT}"

# --- 1. image ---------------------------------------------------------------
if [ "${FORCE_BUILD}" -eq 1 ] || ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    log "building ${IMAGE} (XiangShan RTL build; expect hours on first run)"
    if ! "${REPO_ROOT}/docker/xiangshan-build.sh" 2>&1 | tee -a "${TRANSCRIPT}"; then
        log "BUILD FAILED — see ${TRANSCRIPT}"
        exit 1
    fi
else
    log "reusing existing image ${IMAGE}"
fi

docker run --rm --platform linux/amd64 "${IMAGE}" \
    cat /opt/xiangshan/build-info.txt 2>&1 | tee -a "${TRANSCRIPT}" || true

# --- 2. run -----------------------------------------------------------------
# The container runs as uid 1000 (`divefuzz`). On a cluster node the caller is
# usually not uid 1000, so run as the caller and make /work theirs.
# A numeric --user that has no /etc/passwd entry gets HOME=/, which is not
# writable for it; point HOME at the mounted work directory instead.
run_args=(--rm --platform linux/amd64
          -v "${WORK_DIR}:/work"
          --user "$(id -u):$(id -g)"
          -e HOME=/work)

if [ -n "${CONFIG}" ]; then
    cp "${CONFIG}" "${WORK_DIR}/$(basename "${CONFIG}")"
    # run_dut.py writes `outputs` relative to the cwd (/work) and names logs
    # after the config stem, so pass the copy that lives in /work.
    cmd=(--config "/work/$(basename "${CONFIG}")")
    log "running: docker run ... ${IMAGE} ${cmd[*]}"
else
    cmd=(xiangshan-validate)
    log "no --config given; running the built-in XiangShan validation"
fi

docker run "${run_args[@]}" "${DOCKER_EXTRA[@]+"${DOCKER_EXTRA[@]}"}" \
    "${IMAGE}" "${cmd[@]}" 2>&1 | tee -a "${TRANSCRIPT}"
rc=${PIPESTATUS[0]}

log "container exit code: ${rc}"
log "seeds:   ${WORK_DIR}/seeds"
log "logs:    ${WORK_DIR}/outputs"

# --- 3. optional shutdown ---------------------------------------------------
if [ "${DO_SHUTDOWN}" -eq 1 ]; then
    log "--shutdown requested; powering off in 60s (Ctrl-C to abort)"
    sleep 60
    if command -v systemctl >/dev/null 2>&1; then
        systemctl poweroff
    else
        shutdown -h now
    fi
fi

exit "${rc}"
