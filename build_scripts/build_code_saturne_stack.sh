#!/bin/bash
#
# Code_Saturne Build Script
#
# This script automates the build and installation of several packages required for Code_Saturne, 
# including HDF5, CGNS, MED, HYPRE, and Code_Saturne itself, using
#
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

set -ex  # Exit immediately on error

# Resolve script directory and source common functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/build_common.sh"
source "$SCRIPT_DIR/compilers-config.sh"

# Display usage help
show_help() {
    cat >&2 <<EOF

Usage: $(basename "$0") STACK_CONFIG OPENMPI_PREFIX SOURCES_DIR INSTALL_PREFIX [TEMP_DIR]

    STACK_CONFIG    - file that will be sourced and that should define the following variables: 
                      HDF5_VER, CGNS_VER, MED_VER, HYPRE_VER, CODE_SATURNE_VER, ARCH_PATH
    OPENMPI_PREFIX  - base dir of openmpi
    SOURCES_DIR     - directory where the sources can be found
    INSTALL_PREFIX  - the installation prefix
    [TEMP_DIR]      - temporary directory for the build, can be e.g. /dev/shm. If not provided, one will be created in /tmp/

Requires AMD Optimizing compiler to be loaded when COMPILER=AMD
Requires AOCL_ROOT to be defined when COMPILER=AMD - AMD Optimizing CPU Libraries

Optional GPU (CUDA) build - set in STACK_CONFIG:
    CUDA_ENABLED     - "yes" to enable CUDA support (default: no)
    CUDA_ARCH_NUM    - target compute capability, e.g. 90 for H100 (required if CUDA_ENABLED=yes)
    CUDA_PATH        - CUDA toolkit root (default: derived from 'nvcc' on PATH,
                        e.g. after 'module load nvhpc-hpcx')
    TPL_BLAS_LIBRARIES, TPL_LAPACK_LIBRARIES
                     - BLAS/LAPACK lib dirs used to build HYPRE (default: \$AOCL_ROOT/lib)
    CS_BLAS_ARGS     - bash array of --with-blas* configure args for Code_Saturne
                        (default: AOCL blis/flame; set to an empty array to let
                        configure auto-detect, as recommended for NVHPC builds)
EOF
}

# Parse and validate input arguments
STACK_CONFIG="$1"
OPENMPI_PREFIX="$(realpath $2)"
SOURCES_DIR="$(realpath $3)"
INSTALL_PREFIX=$4
TEMP_DIR="$5"

is_nonempty STACK_CONFIG || (show_help; die "STACK_CONFIG undefined" )
is_nonempty INSTALL_PREFIX || (show_help; die "INSTALL_PREFIX undefined" )
is_nonempty SOURCES_DIR || (show_help; die "SOURCES_DIR undefined" )
is_nonempty OPENMPI_PREFIX || (show_help; die "OPENMPI_PREFIX undefined" )

# Load stack config
source "$STACK_CONFIG"

is_nonempty HDF5_VER || die "Error: HDF5_VER undefined in STACK_CONFIG"
is_nonempty CGNS_VER || die "Error: CGNS_VER undefined in STACK_CONFIG"
is_nonempty HYPRE_VER || die "Error: HYPRE_VER undefined in STACK_CONFIG"
is_nonempty MED_VER || die "Error: MED_VER undefined in STACK_CONFIG"
is_nonempty CODE_SATURNE_VER || die "Error: CODE_SATURNE_VER undefined in STACK_CONFIG"
is_nonempty ARCH_PATH || die "Error: ARCH_PATH undefined in STACK_CONFIG"
is_nonempty COMPILER || die "Error: COMPILER undefined in STACK_CONFIG"
is_nonempty PERFORMANCE_LIBS || die "Error: PERFORMANCE_LIBS undefined in STACK_CONFIG"

readonly HDF5_VER_S=${HDF5_VER%.*}
readonly CGNS_VER_S=${CGNS_VER%.*}
readonly CODE_SATURNE_VER_S=$(extract_short_version $CODE_SATURNE_VER)
readonly HYPRE_VER_S=${HYPRE_VER%.*}
readonly MED_VER_S=${MED_VER%.*}

# --- Optional GPU (CUDA) support ---------------------------------------------
CUDA_ENABLED="${CUDA_ENABLED:-no}"
if [[ "$CUDA_ENABLED" == "yes" ]]; then
    is_nonempty CUDA_ARCH_NUM || die "Error: CUDA_ARCH_NUM undefined in STACK_CONFIG (required when CUDA_ENABLED=yes)"
    if [[ -z "$CUDA_PATH" ]]; then
        command -v nvcc >/dev/null 2>&1 || die "Error: CUDA_ENABLED=yes but nvcc not found on PATH (load the NVIDIA HPC SDK module first, or set CUDA_PATH)"
        CUDA_PATH="$(dirname "$(dirname "$(command -v nvcc)")")"
    fi
fi

# BLAS/LAPACK used to build HYPRE (kept as separate TPL_* libs since HYPRE's
# own BLAS/LAPACK are disabled below). Defaults to AOCL for backward
# compatibility; override in STACK_CONFIG for non-AMD (e.g. NVHPC) builds.
if [[ -z "$TPL_BLAS_LIBRARIES" && -n "$AOCL_ROOT" ]]; then
    TPL_BLAS_LIBRARIES="${AOCL_ROOT}/lib"
fi
if [[ -z "$TPL_LAPACK_LIBRARIES" && -n "$AOCL_ROOT" ]]; then
    TPL_LAPACK_LIBRARIES="${AOCL_ROOT}/lib"
fi
is_nonempty TPL_BLAS_LIBRARIES || die "Error: TPL_BLAS_LIBRARIES undefined (set AOCL_ROOT, or define TPL_BLAS_LIBRARIES in STACK_CONFIG)"
is_nonempty TPL_LAPACK_LIBRARIES || die "Error: TPL_LAPACK_LIBRARIES undefined (set AOCL_ROOT, or define TPL_LAPACK_LIBRARIES in STACK_CONFIG)"

# --with-blas* args for Code_Saturne's configure. Defaults to AOCL blis/flame
# for backward compatibility; override (e.g. to an empty array) in STACK_CONFIG.
if [[ -z "${CS_BLAS_ARGS+x}" ]]; then
    CS_BLAS_ARGS=(--with-blas --with-blas-type=BLAS --with-blas-libs="-lblis -lflame")
fi

if [[ -z "${TEMP_DIR}" ]]; then
  TEMP_DIR="$(mktemp -d -t build-ompi-XXXXXX)"
else
  TEMP_DIR="$(readlink -f -- "${TEMP_DIR}")" || true
  mkdir -p -- "${TEMP_DIR}"
fi

# Switch to AMD compiler for HYPRE and Code_Saturne, optimize for Epyc 4 processors
set_compiler "$COMPILER" "$PERFORMANCE_LIBS" "$OPENMPI_PREFIX" #"CFLAGS=-march=znver4"

if [[ "$CUDA_ENABLED" == "yes" ]]; then
    export CPPFLAGS="${CPPFLAGS:-} -I${CUDA_PATH}/include"
    export LDFLAGS="${LDFLAGS:-} -L${CUDA_PATH}/lib64"
fi

# Fetch upstream release tarballs on demand into SOURCES_DIR instead of
# shipping them alongside the scripts. Re-run-safe: skipped if already cached.
ensure_source_tarball "$SOURCES_DIR" "hdf5-${HDF5_VER}.tar.gz" \
    "https://github.com/HDFGroup/hdf5/archive/refs/tags/hdf5-${HDF5_VER//./_}.tar.gz"
ensure_source_tarball "$SOURCES_DIR" "CGNS-${CGNS_VER}.tar.gz" \
    "https://github.com/CGNS/CGNS/archive/refs/tags/v${CGNS_VER}.tar.gz"
ensure_source_tarball "$SOURCES_DIR" "med-${MED_VER}.tar.bz2" \
    "https://files.salome-platform.org/Salome/medfile/med-${MED_VER}.tar.bz2"
ensure_source_tarball "$SOURCES_DIR" "hypre-${HYPRE_VER}.tar.gz" \
    "https://github.com/hypre-space/hypre/archive/refs/tags/v${HYPRE_VER}.tar.gz"

# Install HDF5
install_mpi_cmake_package "$SOURCES_DIR" hdf5 $HDF5_VER none "$INSTALL_PREFIX/opt/hdf5-$HDF5_VER_S/arch/$ARCH_PATH" \
    -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release -DHDF5_BUILD_FORTRAN=ON -DHDF5_ENABLE_PARALLEL=ON

# Install CGNS
install_mpi_cmake_package "$SOURCES_DIR" CGNS $CGNS_VER none "$INSTALL_PREFIX/opt/cgns-$CGNS_VER_S/arch/$ARCH_PATH"

# Install MED
install_mpi_cmake_package "$SOURCES_DIR" med $MED_VER none "$INSTALL_PREFIX/opt/med-$MED_VER_S/arch/$ARCH_PATH" \
    -DHDF5_ROOT_DIR="$INSTALL_PREFIX/opt/hdf5-${HDF5_VER_S}/arch/$ARCH_PATH"


# Prepare HYPRE source
prepare_hypre_source() {
    local source_dir="$1"
    local package_name="$2"
    local version="$3"
    local tarball
    tarball=$(ls "$source_dir/${package_name}-${version}"*)
    extract_tarball "$tarball"
    pushd "${package_name}-${version}/src" || die "Error: Directory ${package_name}-${version}/src not found"
}

# Install HYPRE
HYPRE_CUDA_ARGS=()
if [[ "$CUDA_ENABLED" == "yes" ]]; then
    HYPRE_CUDA_ARGS=(
        -DHYPRE_ENABLE_CUDA=ON
        -DHYPRE_CUDA_SM="$CUDA_ARCH_NUM"
        -DCMAKE_CUDA_COMPILER=nvcc
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH_NUM"
    )
fi

install_mpi_cmake_package "$SOURCES_DIR" hypre $HYPRE_VER prepare_hypre_source "$INSTALL_PREFIX/opt/hypre-$HYPRE_VER_S/arch/$ARCH_PATH" \
    -DHYPRE_ENABLE_HYPRE_LAPACK=OFF -DHYPRE_ENABLE_HYPRE_BLAS=OFF \
    -DTPL_LAPACK_LIBRARIES="$TPL_LAPACK_LIBRARIES" -DTPL_BLAS_LIBRARIES="$TPL_BLAS_LIBRARIES" \
    "${HYPRE_CUDA_ARGS[@]}"

# Prepare Code_Saturne source
prepare_cs_source() {
    prepare_package_source $1 none $2 $3
    if [ ! -f "configure" ]; then
        ./sbin/bootstrap
    fi

    # Patch Fortran files to avoid syntax issues
    find . -type f -name "*.f90" -exec sed -i 's/\s*procedure\s*()\s*::/!procedure() :: /g' {} \;
}

# Install Code_Saturne
CS_CUDA_ARGS=()
if [[ "$CUDA_ENABLED" == "yes" ]]; then
    CS_CUDA_ARGS=(
        --enable-cuda
        --with-cublas="$CUDA_PATH"
        --with-cusparse="$CUDA_PATH"
        "CUDA_ARCH_NUM=$CUDA_ARCH_NUM"
    )
fi

install_auto_package "$SOURCES_DIR" code_saturne $CODE_SATURNE_VER prepare_cs_source "$INSTALL_PREFIX/code_saturne/$CODE_SATURNE_VER_S/arch/$ARCH_PATH" \
    --disable-gui \
    --with-mpi="$OPENMPI_PREFIX" \
    "${CS_BLAS_ARGS[@]}" \
    --with-hdf5="$INSTALL_PREFIX/opt/hdf5-$HDF5_VER_S/arch/$ARCH_PATH" \
    --without-metis --without-scotch \
    --with-med="$INSTALL_PREFIX/opt/med-$MED_VER_S/arch/$ARCH_PATH" \
    --with-cgns="$INSTALL_PREFIX/opt/cgns-$CGNS_VER_S/arch/$ARCH_PATH" \
    --with-hypre="$INSTALL_PREFIX/opt/hypre-$HYPRE_VER_S/arch/$ARCH_PATH" \
    --with-hypre-lib="$INSTALL_PREFIX/opt/hypre-$HYPRE_VER_S/arch/$ARCH_PATH/lib64" \
    "${CS_CUDA_ARGS[@]}"
