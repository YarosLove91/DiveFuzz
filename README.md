# DiveFuzz

DiveFuzz is a diversified instruction generation approach designed specifically for RISC-V CPUs. Its core idea is to drive testing through dynamically diversified instruction write-back values, enabling effective exploration of CPU states. More details can be found in the [paper](https://dl.acm.org/doi/10.1145/3719027.3765167). In addition, the project is under active development and will continue to incorporate new extensions and features.


## Run with Docker (recommended)

The container image bundles Python and the pinned Python dependencies, the
`riscv64-unknown-elf-*` bare-metal toolchain, the pinned custom Spike adapter and
a built `spike_engine` extension. Nothing from the host is reused.

The base image is Debian 13 (trixie), pinned by digest. This is deliberate:
DiveFuzz's default ISA profile ends in `_zfa`, and Debian 12's binutils 2.40
rejects that whole `-march` string (`unknown prefixed ISA extension 'zfa'`),
which silently breaks every `dive_enable: true` run. Trixie ships binutils 2.44
and GCC 14, which accept it.

All `apt-get install` packages in the Dockerfile are pinned with `=<version>`
to the exact candidate versions resolved against that digest, in addition to
the digest pin on the base image itself. Without the `=<version>` pins, a
rebuild months later could silently pick up a newer point-release package
(e.g. a later `binutils-riscv64-unknown-elf`) even though the base rootfs
digest is unchanged — apt talks to the live Debian mirror at build time, the
base image digest only fixes the rootfs. If a pinned version is later removed
from the archive (e.g. superseded by a Debian point release), the build fails
loudly with an apt "Version ... not found" error rather than silently
substituting a different version.

### Prerequisites

* Docker Engine with BuildKit (tested with Docker 29.2.1).
* `git` and network access to GitHub — the build initializes the pinned
  submodules `ref/riscv-isa-sim-adapter` and
  `fuzzer/generator/reg_analyzer/riscv-opcodes` at their recorded commits.
* Roughly 4 GB of free disk and ~8 GB RAM for the Spike compile.

### Build

```shell
./docker/build.sh
```

This initializes the two required pinned submodules and builds `divefuzz:latest`.
No `--privileged`, host networking or Docker socket access is required.
Real DUTs (XiangShan, NutShell, rocket-chip) are **not** baked into the image.

### Run

```shell
docker run --rm -v "$PWD/work:/work" divefuzz:latest --config /work/your_test.yaml
```

`/work` is the container working directory. `run_dut.py` resolves its `outputs`
directory relative to the working directory, so logs land in `/work/outputs`
and generated seeds wherever `seeds_output` points (use a path under `/work`).

Other entrypoint verbs:

```shell
docker run --rm divefuzz:latest --help    # CLI help
docker run --rm divefuzz:latest probe     # runtime dependency probes
docker run --rm -v "$PWD/work:/work" divefuzz:latest smoke   # end-to-end smoke test
docker run --rm -it divefuzz:latest bash  # shell
```

Or with Compose:

```shell
docker compose build
docker compose run --rm probe
docker compose run --rm smoke
docker compose run --rm divefuzz --config /work/your_test.yaml
```

### Smoke test

```shell
./docker/build.sh
./docker/smoke-test-host.sh
```

The smoke test runs the real pipeline inside the container — seed generation
with `dive_enable: true` (so `spike_engine` diversification is exercised),
assembly, ELF and IMG conversion, then DUT execution through the same `$1`
substitution and `emu_path` working directory used for real DUTs — against a
tiny fixture DUT (`docker/smoke-dut/emu`). It then verifies from the host that
the seed images and logs exist and are non-empty in `docker-smoke-out/`.

Pass `--no-dive` to run the same flow with `dive_enable: false`:

```shell
./docker/smoke-test-host.sh --no-dive
```

The fixture only checks that it received a readable, non-empty seed image in the
right working directory. **It is not a CPU model and validates no CPU
behaviour.**

### Volumes and paths

| Purpose            | Container path                     | Notes                                    |
| ------------------ | ---------------------------------- | ---------------------------------------- |
| Application        | `/opt/DiveFuzz`                    | source, Spike adapter, `spike_engine`    |
| Working directory  | `/work`                            | mount this to persist results            |
| Logs               | `/work/outputs`                    | relative `outputs` dir of `run_dut.py`   |
| Generated seeds    | wherever `seeds_output` points     | put it under `/work`                     |
| External DUT       | e.g. `/dut/XiangShan`              | bind-mount, see below                    |

The runtime process is the non-root user `divefuzz` (uid 1000). If your host uid
differs and the bind mount is not writable, run with `--user "$(id -u):$(id -g)"`
or use a named volume.

### External DUT

The image intentionally ships no real DUT. Mount an already-built DUT tree and
point `emu_path` and `cmd` at container paths:

```shell
docker run --rm \
  -v "$PWD/work:/work" \
  -v /host/path/to/XiangShan:/dut/XiangShan \
  divefuzz:latest --config /work/xiangshan.yaml
```

```yaml
dut_target:
- name: "XiangShan"
  threads: 8
  version: commit:718a93f
  diff_ref: Spike
  # container path, not a host path
  emu_path: /dut/XiangShan
  cmd: ./build/emu -i $1 --diff /dut/XiangShan/ready-to-run/riscv64-spike-so

seeds:
- name: divefuzz_ins_100
  input: divefuzz
  divefuzz:
    gen_only: false
    threads: 8
    dive_enable: true
    mode: generate
    seeds_output: /work/seeds
    seeds_num: 4
    ins_num: 100
    is_cva6: false
    is_rv32: false
    template_type: 'xiangshan'
```

`cmd` is executed with `shell=True` and `cwd` set to `emu_path`, and `$1` is
replaced with the seed path wrapped in double quotes, so paths containing spaces
are handled. A real DUT has never been built or executed in this container — see
"Troubleshooting" below.

### XiangShan inside Docker (`divefuzz-xiangshan:latest`)

The core image ships no DUT. A second, optional image builds the **XiangShan
Verilator emulator inside Docker** from the commit pinned by this repository's
`dut/XiangShan` gitlink, so a server or cluster node needs no JDK, no `mill`, no
Verilator, no Scala/Chisel and no XiangShan checkout of its own — only `docker`
and `git`.

```shell
./docker/xiangshan-build.sh          # builds divefuzz:amd64, then divefuzz-xiangshan:latest
./docker/xiangshan-validate-host.sh  # real end-to-end run against the built emulator
```

The final image is the core DiveFuzz image plus `/opt/xiangshan/build/emu` and
upstream's `ready-to-run/` references, so **one** container generates the seeds
and executes them on the DUT. The heavy build stage (JDK, mill, coursier cache,
Verilator, tens of GB of generated C++) is discarded and never ships.

Pinned: OpenJDK 21, mill `0.12.3` (from XiangShan's own `.mill-version`),
Verilator `5.032`, XiangShan at its recorded gitlink, and every nested submodule
(difftest, rocket-chip, ready-to-run, …) at the commits that XiangShan commit
records — `docker/xiangshan-build.sh` reads the pin with `git ls-tree`, never a
branch. What was actually built is recorded in `/opt/xiangshan/build-info.txt`
inside the image.

**`linux/amd64` only.** This is an upstream constraint, not a preference:
XiangShan's `build.sc` pins Chisel 6.7.0, which resolves firtool 1.62.0, and the
`org.chipsalliance:llvm-firtool:1.62.0` artifact (and the matching CIRCT
release) ships `linux-x64`/`macos-x64`/`windows-x64` binaries only — there is no
`linux-arm64` firtool, so there is no Chisel→Verilog step on arm64. Upstream's
`ready-to-run/riscv64-spike-so` differential reference is likewise an x86-64
shared object. On arm64 hosts everything runs under QEMU: correct, but slow.

#### Two modes: laptop sanity vs. server/cluster

The XiangShan RTL build is a server workload. Treat a laptop as a *sanity*
environment, not the target one.

**Local sanity mode** (any host, including Apple Silicon):

```shell
./docker/build.sh              # core image
docker run --rm divefuzz:latest probe
./docker/smoke-test-host.sh    # fixture DUT: proves container plumbing only
```

That is the whole laptop story. You *may* attempt the XiangShan build locally,
but keep it gentle and expect it to be slow or resource-bound:

```shell
XS_BUILD_JOBS=2 XS_JVM_XMX=8G ./docker/xiangshan-build.sh
```

On an arm64 Mac this runs the entire amd64 toolchain under QEMU emulation.
Chisel elaboration alone takes tens of minutes, and the Verilator + g++ phase is
far longer; `XS_BUILD_JOBS=6` on a 15.6 GB Docker VM is already too aggressive,
because each g++ job wants roughly 1 GB on top of the JVM. A full local build is
**not** a supported path and its absence says nothing about the workflow.

This was measured, not assumed: three attempts on a 24 GB Apple Silicon Mac all
died of kernel/native OOM in the **firtool** step (Chisel elaboration itself
succeeded twice). See §4.1 of
[docs/docker-xiangshan.md](docs/docker-xiangshan.md) for the exact table. The
emulator has therefore **not** been built or executed on this host; that
validation belongs on a native `linux/amd64` node.

**Server/cluster mode** (native `linux/amd64` — the supported path) is below.

#### Running on a server or cluster node

Nothing is installed on the host — no JDK, no `mill`, no Verilator, no Scala,
no XiangShan checkout. The node needs only `docker` and `git`.

```shell
# 1. build the XiangShan-enabled image (once per node, or push it to a registry)
XS_JVM_XMX=10G XS_BUILD_JOBS=16 ./docker/xiangshan-build.sh

# 2. minimal validation against the built emulator (not the smoke fixture)
./docker/xiangshan-validate-host.sh

# 3. fuzzing run with your own config
cp docker/xiangshan.yaml work/my_run.yaml     # edit seeds_num / ins_num / threads
docker run --rm --platform linux/amd64 -v "$PWD/work:/work" \
    divefuzz-xiangshan:latest --config /work/my_run.yaml

# 4. unattended, no interactive shell, exits with the container's code
./docker/do_all_and_shutdown.sh --config work/my_run.yaml --work /scratch/run
```

`do_all_and_shutdown.sh` builds the image if missing, mounts the work directory
at `/work`, runs as your uid/gid so the artifacts belong to you, writes a
transcript, and powers the node off only if you pass `--shutdown` (off by
default).

Artifacts land under the mounted work directory: `seeds/*.S`,
`seeds/elf_file/*.elf`, `seeds/img_file/*.img`, and per-seed emulator logs in
`outputs/`.

Resource knobs (all are build-time environment variables for
`xiangshan-build.sh`):

| Knob | Purpose | Default | Guidance |
| --- | --- | --- | --- |
| `XS_JVM_XMX` | JVM heap for Chisel elaboration | `6G` | **≲ 60 % of the Docker VM memory**; `MinimalConfig` wants `10G` |
| `XS_BUILD_JOBS` | `make -j` for Verilator/g++ | `$(nproc)` | ~1 GB RAM per job |
| `XS_CONFIG` | XiangShan core configuration | `MinimalConfig` | `DefaultConfig` needs ~40 GB heap |
| `XS_EMU_THREADS` | emulator threads | `1` | affects run speed, not build |
| `XS_NUM_CORES` | cores in the SoC | `1` | more cores → much costlier build |

Minimum recommended: **16 GB** RAM and **60 GB** free disk for `MinimalConfig`;
64 GB / 200 GB+ for `DefaultConfig`.

Two different OOMs are possible and they are fixed in *opposite* directions:
no Java stack trace plus BuildKit `cannot allocate memory` is the **kernel** OOM
killer (raise the Docker/VM memory), while `java.lang.OutOfMemoryError: Java
heap space` means the heap is genuinely too small (raise `XS_JVM_XMX`).

Full documentation — resources, YAML reference, cluster usage, corner cases and
troubleshooting — is in [docs/docker-xiangshan.md](docs/docker-xiangshan.md).

The `smoke` verb remains a fixture-based sanity check only; it proves container
plumbing and is **not** evidence about XiangShan. Use `xiangshan-validate` for
that.

### Spike discovery (README vs. code)

The non-Docker instructions above talk about putting Spike on `PATH`, but
`fuzzer/executor/divefuzz_adapter.py` actually reads a **lowercase `spike`
environment variable** and warns when its value does not contain the string
`DiveFuzz`. The image sets both, deliberately:

* `PATH` includes `/opt/DiveFuzz/ref/riscv-isa-sim-adapter/build`, so
  `command -v spike` works;
* `spike=/opt/DiveFuzz/ref/riscv-isa-sim-adapter/build/spike`, which contains
  `DiveFuzz`, so the diversity warning is not emitted.

`docker run --rm divefuzz:latest probe` asserts both.

### Troubleshooting

* **`ref/riscv-isa-sim-adapter is empty in the build context`** — the pinned
  submodule was not initialized. Use `./docker/build.sh`, or run
  `git submodule update --init ref/riscv-isa-sim-adapter`.
* **Permission denied writing to `/work`** — bind-mount uid mismatch; see
  "Volumes and paths".
* **`spike_engine import failed`** — the extension is built against the image's
  Python 3.13. It is verified during the build and by `probe`; if you rebuilt it
  by hand with another interpreter, rebuild the image.
* **Host architecture** — the image has been built and tested on `linux/arm64`
  (Apple Silicon). It is not multi-platform tested; on other architectures the
  Debian packages and the Spike build are expected to work but are unverified.
* **`gen_only`** — this key is accepted by the config parser but is not
  referenced anywhere in the execution path, so it does **not** skip DUT
  execution.

---

## Get Start


Clone the main repository

```
git clone https://github.com/In2Sec/DiveFuzz
cd DiveFuzz
```

Clone the runtime-diversified version of riscv-isa-sim adapted for DiveFuzz as a `git submodule`

```
git submodule init ref/riscv-isa-sim-adapter
git submodule update ref/riscv-isa-sim-adapter
```

Navigate to the dut directory and select your target RISC-V CPU for testing. **If you already have the target existing, you can skip this step.**

```
cd dut

# Example: XiangShan
git submodule init XiangShan
```

## Requirements

### RISC-V toolchain

*DiveFuzz using RISC-V toolchain to generate test cases. For base usage, the following dependencies are required: `riscv64-unknown-elf-*`*

You can obtain the toolchain by following the instructions [here](https://github.com/riscv-collab/riscv-gnu-toolchain). We need the `newlib` version of the toolchain, which prefixes with `riscv64-unknown-elf-`, designed for embedded applications and bare metal development.

We recommend version 2025.11.27; Older versions may have issues with certain extensions not being supported.


### Spike RISC-V ISA simulator
*DiveFuzz's diverse test generation capability relies on the Spike RISC-V ISA simulator.*

The following dependencies are required to install Spike on Debian-based systems:

```
apt-get install device-tree-compiler libboost-regex-dev libboost-system-dev
```

Enter the submodule directory (`ref/riscv-isa-sim-adapter` and `ref/riscv-isa-sim`) to compile and install Spike.

```shell
cd riscv-isa-sim-adapter # or cd riscv-isa-sim
mkdir build
cd build
../configure
make
```

### Python libraries

*DiveFuzz requires the installation of Python, pip, and the necessary Python libraries.*

Assumes you have Python and pip installed, with a Python version **of** 3.10 **or newer**.Then install the necessary Python packages using pip:

```shell
cd DiveFuzz
pip install -r requirements.txt
```

Then, build the Spike C/C++ and python wrapper

```shell
cd ref/riscv-isa-sim-adapter/spike_engine
make
```

## Environment Setup

### REF Configuration

To ensure that the system can locate the `spike` executable you just built, you need to add its path to your shell's `PATH` variable.

```shell
# make sure you are in the DiveFuzz root directory, then run:
export PATH="$(pwd)/riscv-isa-sim-adapter/build:${PATH}"
```

**Important**: You need to re-run this command every time you open a new terminal session.

### DUT Configuration

Enter your DUT directory and build the emulator with:
```shell
export NOOP_HOME="$(pwd)"
make emu   
```



## Usage Example
This project is adapted for the **XiangShan** processor developed by the Beijing Institute of Open Source Chip (BOSC). The following examples are based on XiangShan; usage on other CPUs is similar.

`fuzzer/demo.yaml.dev` is the configuration file for DiveFuzz. You can modify it to fit your needs. Then rename it to `your_test.yaml` and place it in the `fuzzer` directory.

```yaml
# Device under test target config
dut_target:
# The name of the DUT target
- name: "XiangShan KMH DiveFuzz Inst 100"
  # How many threads to use
  threads: 16
  # The version of the DUT target
  version: commit:718a93f
  # Spike or NEMU or None
  diff_ref: Spike
  # The path of the DUT
  emu_path: /path/many_version/718a93f/XiangShan
  # Tell DiveFuzz how to run the DUT
  # notice: $1 is the input file
  cmd: ./build/emu -i $1  --diff /path/dut_fuzz/dut_instance/xs-env/XiangShan/ready-to-run/riscv64-spike-so

seeds:
- name: divefuzz_ins_10
  # Type of input for the seed. Allowed values: dir (directory input), divefuzz (DiveFuzz-formatted input), or leave unset for a single test case.
  input: divefuzz
  divefuzz:
    # TODO: Only generate seeds, do not deliver to DUT
    # gen_only: false
    # parallelism
    threads: 128
    # Whether to enable error elimination
    dive_enable: true
    # Generate or mutate
    mode: generate
    # Path to store seeds after generation/mutation
    seeds_output: /path/seeds_output_inst_100

    # The following features are only effective when the mode is set to generate
    # Number of seeds to generate
    seeds_num: 4
    # Number of instructions for each seed
    ins_num: 100
    # Special instruction generation for cva6
    is_cva6: false
    # Special instruction generation for rv32
    is_rv32: false
    template_type: 'xiangshan'
    # # The following features are only effective when the mode is set to mutate
    # # In mutation mode, the path to the initial corpus
    # mutate_input: /path/seeds_output_inst_100
    # # Enable instruction expansion mutation
    # enable_extension: true
    # # Excluded instruction extensions
    # exclude_extension: ['zicsr']
- name: dir_seeds
  # directory input
  input: dir
  # filter seeds by file suffix
  suffix: elf
  # the path of the directory
  path: /path/riscv_a

- name: seed_0
  # the path of the single test case
  path: /path/riscv_b/seed_0.elf

```


When you are ready to run DiveFuzz, run the following command:

```shell
cd fuzzer/
python run_dut.py --config your_test.yaml
```


After the execution is complete, you can find the results in the `outputs` directory.

DiveFuzz implements a three-tier logging system
1. **DiveFuzz runtime logs**  
   Directly output during execution of `run_dut.py`
   
2. **Seed configuration logs**  
   Stored at: `outputs/{configuration_file}-{seed_profile_name}.log`, like `outputs/your_test_divefuzz_ins_10.log`

3. **Per-seed execution logs**  
   Stored at: `outputs/{configuration_file}-{seed_profile_name}_{seed_basename}.log`, like `outputs/your_test-divefuzz_ins_10_seed_0_.elf.log`




## Affiliation

This project is developed by the Institute of Information Engineering, Chinese Academy of Sciences (CAS).

## Citation
```
@inproceedings{guo2025divefuzz,
  title={DiveFuzz: Enhancing CPU Fuzzing via Diverse Instruction Construction},
  author={Guo, Zihui and Yuan, Miaomiao and Yang, Yanqi and Chen, Liwei and Shi, Gang and Meng, Dan},
  booktitle={Proceedings of the 2025 ACM SIGSAC Conference on Computer and Communications Security},
  pages={1964--1978},
  year={2025}
}
```
