#!/usr/bin/env bash

#===============================================================================
# Description: Build a Open MPI stack + libfabric
#
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
#
# Example:
#   ./build_openmpi_stack.sh my_config.sh /path/to/sources /opt/mpi/openmpi-5.0.7 /dev/shm
#
# Prerequisites:
#   - Bash 4+; typical build tools available.
#   - Sources at SOURCES_DIR for all packages defined in the STACK_CONFIG file
#
# Notes:
#   - Parallelism defaults to 20 (PARALLEL_PROCESSES) if not provided.
#   - A modulefile is generated under $INSTALL_PREFIX/etc/modulefiles.
#
#===============================================================================

set -Eeuo pipefail
set -x
IFS=$'\n\t'

#--------------------------------------
# Globals & defaults
#--------------------------------------
readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"

# Build deps installation prefix inside the target prefix
BUILD_DEPS_PREFIX=""

#--------------------------------------
# Help/Usage
#--------------------------------------
show_help() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} STACK_CONFIG SOURCES_DIR INSTALL_PREFIX [TEMP_DIR]

   STACK_CONFIG    - Path to a file that will be sourced and that must define:
                    M4_VER, AUTOCONF_VER, AUTOMAKE_VER, LIBTOOL_VER, LIBFABRIC_VER,
                    OPENMPI_VER, COMPILER                  
   SOURCES_DIR     - Directory that contains the source tarballs
   INSTALL_PREFIX  - Installation prefix where packages will be installed
   [TEMP_DIR]      - Temporary directory for builds (e.g., /dev/shm). If not
                    supplied, a fresh temporary directory is created under /tmp.

Examples:
  ${SCRIPT_NAME} my_config.sh /path/to/sources /opt/mpi/openmpi-5.0.7 /dev/shm

This script builds and installs:
  - Autotools toolchain (m4, autoconf, automake, libtool) under:
      \$INSTALL_PREFIX/opt/build
  - libfabric and  Open MPI under \$INSTALL_PREFIX

It also writes a modulefile under:
  \$INSTALL_PREFIX/etc/modulefiles/openmpi-OPENMPI_VERSION
EOF
}

# Input parsing & validation
STACK_CONFIG="${1:-}"
SOURCES_DIR="${2:-}"
PREFIX="${3:-}"
TEMP_DIR="${4:-}"

if [[ -z "${STACK_CONFIG}" ]]; then
  show_help
  die "Error: COMPILER_CONFIG is undefined"
fi
if [[ -z "${SOURCES_DIR}" ]]; then
  show_help
  die "Error: SOURCES_DIR is undefined"
fi
if [[ -z "${PREFIX}" ]]; then
  show_help
  die "Error: INSTALL_PREFIX is undefined"
fi

# Normalize paths
STACK_CONFIG="$(readlink -f -- "${STACK_CONFIG}")" || true
SOURCES_DIR="$(readlink -f -- "${SOURCES_DIR}")" || true
PREFIX="$(readlink -f -- "${PREFIX}")" || true

[[ -f "${STACK_CONFIG}" ]] || die "Compiler config not found: ${STACK_CONFIG}"
[[ -d "${SOURCES_DIR}" ]]    || die "Sources directory not found: ${SOURCES_DIR}"

if [[ -z "${TEMP_DIR}" ]]; then
  TEMP_DIR="$(mktemp -d -t build-ompi-XXXXXX)"
else
  TEMP_DIR="$(readlink -f -- "${TEMP_DIR}")" || true
  mkdir -p -- "${TEMP_DIR}"
fi

# Source helper library & compiler config
if [[ -f "${SCRIPT_DIR}/build_common.sh" ]]; then
  source "${SCRIPT_DIR}/build_common.sh"
else
  die "Required helper not found: ${SCRIPT_DIR}/build_common.sh"
fi

if [[ -f "${SCRIPT_DIR}/compilers-config.sh" ]]; then
  source "${SCRIPT_DIR}/compilers-config.sh"
else
  die "Required helper not found: ${SCRIPT_DIR}/compilers-config.sh"
fi


source "${STACK_CONFIG}"


BUILD_DEPS_PREFIX="${PREFIX}/opt/build"

# Build parallelism knobs (honor pre-set env if any)
export PARALLEL_PROCESSES="${PARALLEL_PROCESSES:-20}"
export MAKEFLAGS="${MAKEFLAGS:--j${PARALLEL_PROCESSES}}"

# Paths/LDFLAGS
set_compiler GCC AOCL "CFLAGS=-Wno-implicit-function-declaration" "LDFLAGS=-L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib -L${BUILD_DEPS_PREFIX}/lib -Wl,-rpath,${BUILD_DEPS_PREFIX}/lib"


#--------------------------------------
# Build steps
#--------------------------------------
log "Installing build dependencies (Autotools) under ${BUILD_DEPS_PREFIX}"
install_auto_package "${SOURCES_DIR}" m4        "${M4_VER}"        none "${BUILD_DEPS_PREFIX}"
install_auto_package "${SOURCES_DIR}" autoconf  "${AUTOCONF_VER}"  none "${BUILD_DEPS_PREFIX}"
install_auto_package "${SOURCES_DIR}" automake  "${AUTOMAKE_VER}"  none "${BUILD_DEPS_PREFIX}"
install_auto_package "${SOURCES_DIR}" libtool   "${LIBTOOL_VER}"   none "${BUILD_DEPS_PREFIX}"

log "Building libfabric ${LIBFABRIC_VER}"
prepare_libfabric_source() {
  prepare_package_source $1 none $2 $3
  if [[ -x "./autogen.sh" ]]; then
    ./autogen.sh
  else
    die "autogen.sh not found or not executable in $(pwd)"
  fi
}
install_auto_package "${SOURCES_DIR}" libfabric "${LIBFABRIC_VER}" prepare_libfabric_source "${PREFIX}" \
 --enable-shm --enable-efa --enable-sm2

log "Building Open MPI ${OPENMPI_VER} (with libfabric)"
prepare_ompi_sources() {
  prepare_package_source $1 none $2 $3
  if is_git_version $3; then
    ./autogen.pl
  fi
}
install_auto_package "${SOURCES_DIR}" openmpi "${OPENMPI_VER}" prepare_ompi_sources "${PREFIX}" \
 "--with-libfabric=${PREFIX}" 

#--------------------------------------
# Modulefile generation
#--------------------------------------
MODULE_DIR="${PREFIX}/etc/modulefiles"
MODULE_NAME="openmpi-$(extract_version $OPENMPI_VER)"
MODULE_FILE="${MODULE_DIR}/${MODULE_NAME}"

mkdir -p -- "${MODULE_DIR}"

# Create a simple environment modulefile
cat > "${MODULE_FILE}" <<EOF
#%Module1.0#####################################################################
##
## OpenMPI Modulefile
##
proc ModulesHelp { } {
    puts stderr "This module loads OpenMPI ${OPENMPI_VER} with libfabric ${LIBFABRIC_VER} from ${PREFIX}"
}

module-whatis "Loads OpenMPI ${OPENMPI_VER} with libfabric ${LIBFABRIC_VER} from ${PREFIX}"

prepend-path PATH ${PREFIX}/bin
prepend-path LD_LIBRARY_PATH ${PREFIX}/lib
setenv MPI_HOME ${PREFIX}
EOF

echo "Done. Open MPI Module file installed at: ${MODULE_FILE}"
