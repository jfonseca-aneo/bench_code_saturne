# Versions
# HDF5_VER is informational only: HDF5_PREBUILT_ROOT below makes
# build_code_saturne_stack.sh reuse an existing HDF5 install instead of
# building one, so this must just document what that install actually is.
export HDF5_VER="1.14.6"
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

# Reuse the HDF5 already built by install_sem3d_nvhpc.sh against the same
# NVHPC toolchain/MPI, instead of rebuilding a second HDF5 here.
export HDF5_PREBUILT_ROOT="/opt/hdf5-nvhpc"

# BLAS/LAPACK used to build HYPRE. No AOCL on this box: point at a system
# LAPACK/BLAS install. install_sem3d_nvhpc.sh does not install lapack/blas
# dev packages, so on Amazon Linux 2023 you may need e.g.:
#   sudo dnf install -y lapack-devel blas-devel
export TPL_BLAS_LIBRARIES="/usr/lib64"
export TPL_LAPACK_LIBRARIES="/usr/lib64"

# Let Code_Saturne's configure auto-detect BLAS rather than forcing AOCL's
# blis/flame, which are not available with the NVHPC toolchain.
export CS_BLAS_ARGS=()
