
# Code Saturne

## How to build

1) Set install dir:
```bash
export CS_INSTALL_PREFIX="/lustre/software/benchmarking"
```
2) Add your compiler to the `compilers_config.sh` if not there already

3) Modify the `CFG_....sh` files to use your compiler(s) of choice

4) Compile OpenMPI stack with 5.0.7

```bash
./build_openmpi_stack.sh CFG_ompi_5.0.7.sh ./sources $CS_INSTALL_PREFIX/ompi-5.0.7
```

Or compile OMPI Improved stack
```bash
./build_openmpi_stack.sh CFG_ompi_improved.sh ./sources $CS_INSTALL_PREFIX/ompi-improved
```
where the arguments are:
```bash
# Usage:
#   ./build_openmpi_stack.sh STACK_CONFIG SOURCES_DIR INSTALL_PREFIX [TEMP_DIR]
#
#   STACK_CONFIG - Path to a file that will be sourced and that must define:
#                  M4_VER, AUTOCONF_VER, AUTOMAKE_VER, LIBTOOL_VER, LIBFABRIC_VER,
#                  OPENMPI_VER, COMPILER                  
#   SOURCES_DIR     - Directory that contains the source tarballs
#   INSTALL_PREFIX  - Installation prefix where packages will be installed
#   [TEMP_DIR]      - Temporary directory for builds (e.g., /dev/shm). If not
#                    supplied, a fresh temporary directory is created under /tmp.
```

5) Load the compiled OMPI using the module file, e.g.
```bash
module load $CS_INSTALL_PREIFX/ompi-5.0.7/etc/modulefiles/ompi-5.0.7
```

6) Compile Code Saturne and a minimal set of dependencies (change to fit the CS and OMPI versions used)
```bash
./build_code_saturne_stack.sh CFG_code_saturne_8.3.0.sh $CS_INSTALL_PREFIX/ompi-5.0.7 ./sources $CS_INSTALL_PREFIX/saturne/ompi-5.0.7 
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

## How to build for NVIDIA GPUs (H100)

Code_Saturne's CUDA support requires a CUDA-aware MPI. Rather than building
the OpenMPI stack above, use the OpenMPI ("hpcx", UCX-based) bundled with the
NVIDIA HPC SDK:

```bash
module purge
module load nvhpc-hpcx   # name varies by site; check `module avail nvhpc`
```

Derive its prefix from `mpicc` and use that as `OPENMPI_PREFIX` (skip
`build_openmpi_stack.sh` entirely):

```bash
export OPENMPI_PREFIX="$(dirname "$(dirname "$(command -v mpicc)")")"
```

Then build Code_Saturne and its dependencies with the H100 stack config,
which selects the NVHPC compiler (`nvc`/`nvc++`/`nvfortran`) and enables
CUDA for HYPRE and Code_Saturne (`CUDA_ARCH_NUM=90` for H100):

```bash
./build_code_saturne_stack.sh CFG_code_saturne_8.3.0-h100.sh "$OPENMPI_PREFIX" ./sources $CS_INSTALL_PREFIX/saturne/h100
```

See `CFG_code_saturne_8.3.0-h100.sh` for the GPU-specific variables
(`CUDA_ENABLED`, `CUDA_ARCH_NUM`, `CUDA_PATH`, `TPL_BLAS_LIBRARIES`,
`TPL_LAPACK_LIBRARIES`, `CS_BLAS_ARGS`) and adjust `TPL_BLAS_LIBRARIES` /
`TPL_LAPACK_LIBRARIES` to a valid system LAPACK/BLAS install on your cluster.

## How to run the tests cases

On the root folder, run, with `code_saturne` on the PATH:
```bash
./generate_cases.sh 
```

This will compile the test case under SRC_04 and generate some test case
inpouts on the `F128_04/RESU` directory. To launch the test on a Slurm cluster,
go into the test case folder (this is important, the launch script uses as
reference the submission directory) and do 

```bash
sbatch run_solver
```

To change parameters for the tests, modify directy the `generate_cases.sh` script.

The Code Saturne config file used is `DATA/setup.xml`. By default, I/O is
disabled as much as possible, but there are some other config file at `DATA`
with I/O enabled.

## How to analyze the results

Code Saturne will write a performace log at `performance.log`, timings for each
iteration at `timer_stats.csv` and residuals at `residuals.csv`.



