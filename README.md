
# Code Saturne (GPU / NVHPC build)

## How to build

There are two ways to get the NVHPC compiler + CUDA-aware MPI this build
needs: a site `module load`, or a standalone NVHPC install (e.g. via
`install_sem3d_nvhpc.sh` in the `aws_nvidia` repo, which also builds an HDF5
against that same toolchain). Pick the config file matching your GPU and
setup:

- `CFG_code_saturne_8.3.0-h100.sh` — H100 (`CUDA_ARCH_NUM=90`), `module load`-based NVHPC/MPI, builds its own HDF5.
- `CFG_code_saturne_8.3.0-nvhpc-a100.sh` — A100 (`CUDA_ARCH_NUM=80`), standalone NVHPC install, reuses an existing HDF5 via `HDF5_PREBUILT_ROOT` instead of building one.

1) Set install dir:
```bash
export CS_INSTALL_PREFIX="/lustre/software/benchmarking"   # must be writable by your user
```

2) Make NVHPC's compilers (`nvc`/`nvc++`/`nvfortran`) and bundled MPI
available on `PATH`:

```bash
# site module:
module purge
module load nvhpc-hpcx   # name varies by site; check `module avail nvhpc`

# OR, standalone install (e.g. from install_sem3d_nvhpc.sh):
source /etc/profile.d/nvhpc.sh
```

Do **not** run the build with `sudo` — it resets `PATH` and drops `nvc`/
`nvcc` again. If `CS_INSTALL_PREFIX` needs root to create, do that once ahead
of time and `chown` it to your user, then build as yourself:
```bash
sudo mkdir -p "$CS_INSTALL_PREFIX" && sudo chown "$(id -u):$(id -g)" "$CS_INSTALL_PREFIX"
```

3) Build Code_Saturne and its dependencies with the stack config, which
selects the NVHPC compiler and enables CUDA for HYPRE and Code_Saturne:

```bash
./build_code_saturne_stack.sh CFG_code_saturne_8.3.0-nvhpc-a100.sh auto $CS_INSTALL_PREFIX/saturne/a100
```

`OPENMPI_PREFIX` (2nd argument) can be `auto` to auto-detect the MPI bundled
with a standalone NVHPC install, or an explicit path (e.g. derived from
`mpicc` when using a site module: `"$(dirname "$(dirname "$(command -v mpicc)")")"`).

where the arguments are:
```bash
# Usage:
#   ./build_script.sh STACK_CONFIG OPENMPI_PREFIX INSTALL_PREFIX [SOURCES_DIR] [TEMP_DIR]
#
# Arguments:
#
#   STACK_CONFIG    - file that will be sourced and that should define the following variables: 
#                     HDF5_VER, CGNS_VER=4.5.0, MED_VER=5.0.0, HYPRE_VER=2.33.0, CODE_SATURNE_VER, ARCH_PATH
#   OPENMPI_PREFIX  - Path to the OpenMPI installation, or "auto" for a standalone NVHPC install
#   INSTALL_PREFIX  - Target installation prefix
#   SOURCES_DIR     - Optional cache dir for downloaded source tarballs (default: INSTALL_PREFIX/sources)
#   TEMP_DIR        - Optional temporary build directory (defaults to /tmp if not provided)
```

See the stack config for the GPU-specific variables (`CUDA_ENABLED`,
`CUDA_ARCH_NUM`, `CUDA_PATH`, `TPL_BLAS_LIBRARIES`, `TPL_LAPACK_LIBRARIES`,
`CS_BLAS_ARGS`, `HDF5_PREBUILT_ROOT`) and adjust `TPL_BLAS_LIBRARIES` /
`TPL_LAPACK_LIBRARIES` to a valid system LAPACK/BLAS install on your cluster
(e.g. `sudo dnf install -y lapack-devel blas-devel` on Amazon Linux 2023).

Note: none of the dependencies are vendored in this repo. `CODE_SATURNE_VER`
in that config is a `git:<repo url>#<tag>` spec, so Code_Saturne itself is
cloned directly from its official GitHub mirror
(https://github.com/code-saturne/code_saturne). HDF5 (unless
`HDF5_PREBUILT_ROOT` is set), CGNS, MED and HYPRE are fetched automatically
from their official upstream locations into `SOURCES_DIR` the first time you
build (cached there for subsequent builds, see `ensure_source_tarball` in
`build_common.sh`).

4) Load the built Code_Saturne (via the resulting module file, or by adding
its `bin/` to `PATH`) so that `code_saturne` is available before running the
test case generation script below.

## How to run the tests cases

On the root folder, run, with `code_saturne` (the GPU/CUDA build) on the PATH:
```bash
./generate_cases_gpu.sh
```

This will compile the test case under `SRC_04` and generate one Slurm
submission directory per node count under `F128_04_GPU/RESU`, sweeping GPU
node count for a fixed mesh (strong scaling). To launch a run, go into the
corresponding test case folder (this is important, the launch script uses
the submission directory as reference) and do

```bash
sbatch run_solver
```

To change parameters (GPUs per node, node counts, partition, mesh size),
modify directly the `generate_cases_gpu.sh` script.

The Code Saturne config file used is `DATA/setup.xml`. By default, I/O is
disabled as much as possible, but there are some other config file at `DATA`
with I/O enabled.

## How to analyze the results

Code Saturne will write a performace log at `performance.log`, timings for each
iteration at `timer_stats.csv` and residuals at `residuals.csv`.
