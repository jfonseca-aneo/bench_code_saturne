# Versions
# MED 5.0.0's medMacros.cmake hard-requires HDF5 1.12.x exactly (it checks
# HDF_VERSION_MINOR_REF EQUAL 12, not really ">= 1.12.1" as its error message
# claims), so we can't reuse the HDF5 1.14.6 built by install_sem3d_nvhpc.sh
# for SEM3D. Build our own 1.12.3 against the same NVHPC/MPI toolchain instead.
export HDF5_VER="1.12.3"
export CGNS_VER="4.5.0"
export MED_VER="5.0.0"
export HYPRE_VER="2.33.0"

# Fetched directly from the official code_saturne GitHub mirror instead of a
# vendored tarball under sources/ (git:<repo url>#<tag/branch/commit>).
export CODE_SATURNE_VER="git:https://github.com/code-saturne/code_saturne.git#v8.3.0"

export ARCH_PATH="ompi_nvhpc_a100"
export COMPILER=NVHPC
export PERFORMANCE_LIBS=System

# GPU (CUDA) support - A100 = compute capability 8.0
export CUDA_ENABLED=yes
export CUDA_ARCH_NUM=80
# CUDA_PATH is left unset: derived from 'nvcc' on PATH after sourcing
# /etc/profile.d/nvhpc.sh (installed by install_sem3d_nvhpc.sh), or after
# 'module load nvhpc-hpcx' if that's how NVHPC is exposed instead.

# BLAS/LAPACK used to build HYPRE. No AOCL on this box: point at a system
# LAPACK/BLAS install. install_sem3d_nvhpc.sh does not install lapack/blas
# dev packages, so on Amazon Linux 2023 you may need e.g.:
#   sudo dnf install -y lapack-devel blas-devel
export TPL_BLAS_LIBRARIES="/usr/lib64"
export TPL_LAPACK_LIBRARIES="/usr/lib64"

# Let Code_Saturne's configure auto-detect BLAS rather than forcing AOCL's
# blis/flame, which are not available with the NVHPC toolchain.
export CS_BLAS_ARGS=()
