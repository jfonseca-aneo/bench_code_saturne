
# Code Saturne (GPU / H100 build)

## How to build

1) Set install dir:
```bash
export CS_INSTALL_PREFIX="/lustre/software/benchmarking"
```

2) Code_Saturne's CUDA support requires a CUDA-aware MPI. Rather than building
an OpenMPI stack, use the OpenMPI ("hpcx", UCX-based) bundled with the
NVIDIA HPC SDK:

```bash
module purge
module load nvhpc-hpcx   # name varies by site; check `module avail nvhpc`
```

Derive its prefix from `mpicc` and use that as `OPENMPI_PREFIX` (there is no
OpenMPI stack to build for this path):

```bash
export OPENMPI_PREFIX="$(dirname "$(dirname "$(command -v mpicc)")")"
```

3) Build Code_Saturne and its dependencies with the H100 stack config, which
selects the NVHPC compiler (`nvc`/`nvc++`/`nvfortran`) and enables CUDA for
HYPRE and Code_Saturne (`CUDA_ARCH_NUM=90` for H100):

```bash
./build_code_saturne_stack.sh CFG_code_saturne_8.3.0-h100.sh "$OPENMPI_PREFIX" ./sources $CS_INSTALL_PREFIX/saturne/h100
```

where the arguments are:
```bash
# Usage:
#   ./build_script.sh STACK_CONFIG OPENMPI_PREFIX SOURCES_DIR INSTALL_PREFIX [TEMP_DIR]
#
# Arguments:
#
#   STACK_CONFIG    - file that will be sourced and that should define the following variables: 
#                     HDF5_VER, CGNS_VER=4.5.0, MED_VER=5.0.0, HYPRE_VER=2.33.0, CODE_SATURNE_VER, ARCH_PATH
#   OPENMPI_PREFIX  - Path to the OpenMPI installation
#   SOURCES_DIR     - Directory containing source tarballs
#   INSTALL_PREFIX  - Target installation prefix
#   TEMP_DIR        - Optional temporary build directory (defaults to /tmp if not provided)
```

See `CFG_code_saturne_8.3.0-h100.sh` for the GPU-specific variables
(`CUDA_ENABLED`, `CUDA_ARCH_NUM`, `CUDA_PATH`, `TPL_BLAS_LIBRARIES`,
`TPL_LAPACK_LIBRARIES`, `CS_BLAS_ARGS`) and adjust `TPL_BLAS_LIBRARIES` /
`TPL_LAPACK_LIBRARIES` to a valid system LAPACK/BLAS install on your cluster.

4) Load the built Code_Saturne (via the resulting module file, or by adding
its `bin/` to `PATH`) so that `code_saturne` is available before running the
test case generation script below.

## How to run the tests cases

On the root folder, run, with `code_saturne` (the H100/CUDA build) on the PATH:
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
