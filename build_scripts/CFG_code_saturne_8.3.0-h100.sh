# Versions
export HDF5_VER="1.12.3"
export CGNS_VER="4.5.0"
export MED_VER="5.0.0"
export HYPRE_VER="2.33.0"

# Fetched directly from the official code_saturne GitHub mirror instead of a
# vendored tarball under sources/ (git:<repo url>#<tag/branch/commit>).
export CODE_SATURNE_VER="git:https://github.com/code-saturne/code_saturne.git#v8.3.0"

export ARCH_PATH="ompi_hpcx_h100"
export COMPILER=NVHPC
export PERFORMANCE_LIBS=System

# GPU (CUDA) support - H100 = compute capability 9.0
export CUDA_ENABLED=yes
export CUDA_ARCH_NUM=90
# CUDA_PATH is left unset: derived from 'nvcc' on PATH after
# 'module load nvhpc-hpcx' (or another NVHPC module providing CUDA-aware MPI).

# BLAS/LAPACK used to build HYPRE. Point these at a system LAPACK/BLAS
# install (e.g. from the distro, or NVPL on aarch64); adjust for your site.
export TPL_BLAS_LIBRARIES="/usr/lib/x86_64-linux-gnu"
export TPL_LAPACK_LIBRARIES="/usr/lib/x86_64-linux-gnu"

# Let Code_Saturne's configure auto-detect BLAS rather than forcing AOCL's
# blis/flame, which are not available with the NVHPC toolchain.
export CS_BLAS_ARGS=()
