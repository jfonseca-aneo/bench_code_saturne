#!/bin/bash
#
# Script for installing software packages from source archives.
#
# Supported build systems:
#   - Custom workflows (user-defined preparation and compilation functions)
#   - Autotools (configure/make)
#   - CMake with MPI compilers
#
# Features:
#   - Tracks installed packages to avoid redundant installations
#   - Supports tarball extraction and source preparation
#   - Logs progress and errors with consistent formatting

# ------------------------------------------------------------------------------
# Logging and Error Handling
# ------------------------------------------------------------------------------

# Print an informational message to stderr
# Usage: log "Message"
log() {
    printf '[INFO] %s\n' "$*" >&2
}

# Print a warning message to stderr
# Usage: warn "Message"
warn() {
    printf '[WARN] %s\n' "$*" >&2
}

# Print an error message and exit with optional exit code
# Usage: die "Message" [exit_code]
die() {
    local message="$1"
    local exit_code="${2:-1}"
    printf '[ERROR] %s\n' "$message" >&2
    exit "$exit_code"
}

# ------------------------------------------------------------------------------
# Installation Tracking
# ------------------------------------------------------------------------------

# Mark a package as installed by creating a file in the prefix/etc/installed_packages
# Arguments:
#   $1 - Package name
#   $2 - Package version
#   $3 - Installation prefix
signal_installed() {
    local package="$1"
    local version="$(extract_version $2)"
    local prefix="$3"
    mkdir -p "${prefix}/etc/installed_packages" && \
    touch "${prefix}/etc/installed_packages/${package}-${version}"
}

is_git_version() {
    [[ "$1" == git:* ]]
    return $?
}

extract_version() {
    if is_git_version $1; then
        local url_and_ref=${1#git:}
        local ref="${url_and_ref##*\#}"
        echo $ref
    else
        echo $1
    fi
}

extract_short_version() {
    local version=$(extract_version $1)
    echo ${version%.*}
}

git_extract_repo() {
    local url_and_ref=${1#git:}
    local url="${url_and_ref%%.git#*}.git"
    echo $url
}

# Check if a package is already installed
# Arguments:
#   $1 - Package name
#   $2 - Package version
#   $3 - Installation prefix
# Returns:
#   1 if installed, 0 otherwise
check_installed() {
    local package="$1"
    local version="$(extract_version $2)"
    local prefix="$3"
    if [[ -f "${prefix}/etc/installed_packages/${package}-${version}" ]]; then
        echo 1
    else
        echo 0
    fi
}

# ------------------------------------------------------------------------------
# Tarball and sources handling
# ------------------------------------------------------------------------------

# Check out a git reference
# Arguments 
#   $1 - Ref spec, can be
#         - A local branch name
#         - A (remote) origin branch name
#         - A commit hash
# Returns: 1 on error
git_checkout() {

  if git show-ref --verify --quiet "refs/heads/$1"; then
    # If the argument is a branch name
    git checkout "$1"
  
  elif git show-ref --verify --quiet "refs/remotes/origin/$1"; then
    # If the argument is a remote branch name
    git checkout "origin/$1"

  elif git rev-parse --verify --quiet "$1"; then
    # If the argument is a commit hash
    git checkout "$1" --detach
  else
    echo "Error: '$1' is neither a valid branch nor a commit hash."
    return 1
  fi
}

# Determine the root folder of a tarball
# Arguments:
#   $1 - Path to tarball
# Returns:
#   Prints the most common top-level directory in the archive
get_tar_root_folder() {
    local tar_file="$1"
    if [ ! -f "$tar_file" ]; then
        echo "File not found: $tar_file"
        return 1
    fi

    tar -tf "$tar_file" | awk -F/ '{print $1}' | sort | uniq -c | sort -nr | head -n 1 | awk '{print $2}'
}

# Extract a tarball (.tar.gz or .tar.bz2)
# Arguments:
#   $1 - Path to tarball
extract_tarball() {
    local tarball="$1"
    if [[ "$tarball" == *.tar.gz ]]; then
        tar -xzf "$tarball"
    elif [[ "$tarball" == *.tar.bz2 ]]; then
        tar -xjf "$tarball"
    else
        die "Unsupported file type for $tarball"
    fi
}

# Find a tarball in a directory and its subdirectories
# Arguments:
#   $1 - Directory
#   $2 - Package name
#   $3 - Version
find_tarball() {
    # Find a matching tarball robustly
    local source_dir=$1
    local package_name=$2
    local version=$3

    local matches=()
    while IFS= read -r -d '' f; do
        matches+=("$f")
    done < <(find "${source_dir}" -maxdepth 1 -type f -name "${package_name}-${version}*" -print0)
    # [[ ${#matches[@]} -ge 1 ]]
    tarball="${matches[0]}"
    echo $tarball
}


# Download a tarball into a cache directory if it isn't already there, so
# dependency archives don't need to be vendored/shipped alongside the scripts.
# Arguments:
#   $1 - Cache/source directory (created if missing)
#   $2 - Filename to save it as (must match "<package>-<version>*" so
#        find_tarball can locate it)
#   $3 - URL to download it from
ensure_source_tarball() {
    local source_dir="$1"
    local filename="$2"
    local url="$3"

    mkdir -p "$source_dir"
    if [[ -f "$source_dir/$filename" ]]; then
        return 0
    fi

    command -v curl > /dev/null 2>&1 || die "Error: curl is required to download $filename"

    log "Downloading $filename from $url"
    curl -fsSL --retry 3 --retry-delay 2 -o "$source_dir/$filename.part" "$url" \
        || die "Failed to download $filename from $url"
    mv "$source_dir/$filename.part" "$source_dir/$filename"
}

# ------------------------------------------------------------------------------
# Source Preparation
# ------------------------------------------------------------------------------

# Prepare the source directory for building
# Arguments:
#   $1 - Source directory
#   $2 - Preparation function name or nonr
#   $3 - Package name
#   $4 - Package version: a string or a "git:<GIT URL>#<REF_SPEC>" git spec
prepare_package_source() {
    local source_dir="$1"
    local prepare_sources="$2"
    local package_name="$3"
    local version="$4"

    if declare -F "$prepare_sources" > /dev/null; then
        "$prepare_sources" "$source_dir" "$package_name" "$version"

    elif is_git_version $version; then
        local url=$(git_extract_repo $version)
        local ref=$(extract_version $version)
        git clone --recurse-submodules "$url"
        pushd "$(basename "$url" .git)"
        git fetch --all
        git_checkout $ref

    else
        local tarball
        if [[ -f "$source_dir/$prepare_sources" && "$prepare_sources" != "none" ]]; then
            tarball="$source_dir/$prepare_sources"
        else
            tarball=$(find_tarball $source_dir $package_name $version)
        fi
        extract_tarball "$tarball"

        if [[ -d "${package_name}-${version}" ]]; then
            pushd "${package_name}-${version}" || die "Directory ${package_name}-${version} not found"
        else
            root_folder=$(get_tar_root_folder "$tarball")
            pushd "$root_folder" || die "Directory ${root_folder} not found"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Installation Workflows
# ------------------------------------------------------------------------------

# Install a package using custom preparation and compilation functions
# Arguments:
#   $1 - Source directory
#   $2 - Package name
#   $3 - Package version
#   $4 - Preparation function name or "none"
#   $5 - Compilation function name
#   $6 - Installation prefix
install_custom_package() {
    local source_dir="$1"; shift
    local package_name="$1"; shift
    local version="$1"; shift
    local prepare_sources="$1"; shift
    local compile_package="$1"; shift
    local prefix="$1"; shift

    if [[ "$(check_installed "$package_name" "$version" "$prefix")" -ne 0 ]]; then
        echo "$package_name-$version is already installed at $prefix"
        return 0
    fi

    pushd "$TEMP_DIR" || die "Failed to enter TEMP_DIR"
    prepare_package_source "$source_dir" "$prepare_sources" "$package_name" "$version"
    "$compile_package" "$prefix" "$version"
    popd || die "Failed to return from package directory"
    signal_installed "$package_name" "$version" "$prefix"
}

# Install a package using autotools (configure/make)
# Arguments:
#   $1 - Source directory
#   $2 - Package name
#   $3 - Package version
#   $4 - Preparation function name or "none"
#   $5 - Installation prefix
#   $@ - Additional arguments passed to configure
install_auto_package() {
    local source_dir="$1"; shift
    local package_name="$1"; shift
    local version="$1"; shift
    local prepare_sources="$1"; shift
    local prefix="$1"; shift

    if [[ "$(check_installed "$package_name" "$version" "$prefix")" -ne 0 ]]; then
        echo "$package_name-$version is already installed at $prefix"
        return 0
    fi

    pushd "$TEMP_DIR" || die "Failed to enter TEMP_DIR"
    prepare_package_source "$source_dir" "$prepare_sources" "$package_name" "$version"

    # expanded_args=()
    # for arg in "$@"; do
    #     echo "$arg"
    #     expanded_args+=($(eval echo "$arg"))
    # done

    rm -rf build && mkdir -p build
    pushd build || die "Failed to enter build directory"

    ../configure --prefix="$prefix" "$@" || die "Configuration failed"
    make -j "${PARALLEL_PROCESSES:-$(nproc)}" || die "Build failed"
    make install || die "Installation failed"

    popd || die "Failed to return from build directory"
    popd || die "Failed to return from package directory"
    signal_installed "$package_name" "$version" "$prefix"
}

# Install a package using CMake with MPI compilers
# Arguments:
#   $1 - Source directory
#   $2 - Package name
#   $3 - Package version
#   $4 - Preparation function name or "none"
#   $5 - Installation prefix
#   $@ - Additional arguments passed to CMake
install_mpi_cmake_package() {
    local source_dir="$1"; shift
    local package_name="$1"; shift
    local version="$1"; shift
    local prepare_sources="$1"; shift
    local prefix="$1"; shift

    if [[ "$(check_installed "$package_name" "$version" "$prefix")" -ne 0 ]]; then
        echo "$package_name-$version is already installed at $prefix"
        return 0
    fi

    pushd "$TEMP_DIR" || die "Failed to enter TEMP_DIR"
    prepare_package_source "$source_dir" "$prepare_sources" "$package_name" "$version"

    # expanded_args=()
    # for arg in "$@"; do
    #     echo "$arg"
    #     expanded_args+=($(eval echo "$arg"))
    # done

    rm -rf build && mkdir -p build
    pushd build || die "Failed to enter build directory"

    # CMAKE_FIND_USE_*_PACKAGE_REGISTRY=OFF: without this, find_package(...
    # CONFIG) calls (e.g. MED's HDF5 detection) can silently pick up an
    # unrelated HDF5/CGNS/etc. build from ~/.cmake/packages/, left there by
    # export(PACKAGE ...) in some other project's build tree (e.g. one built
    # by install_sem3d_nvhpc.sh) -- entirely bypassing the *_ROOT_DIR/prefix
    # hints passed below.
    #
    # CMAKE_POLICY_DEFAULT_CMP0074=NEW: some vendored packages (e.g. MED
    # 5.0.0) predate CMP0074 and don't set it themselves, so CMake silently
    # *ignores* any <PackageName>_ROOT variable (e.g. HDF5_ROOT) passed to
    # them with just a dev warning -- forcing the policy here makes it work
    # without touching their CMakeLists.txt.
    cmake .. --debug-trycompile \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_FORTRAN_COMPILER="$FC" \
        -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
        -DCMAKE_POLICY_DEFAULT_CMP0074=NEW \
        -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
        "$@" || die "CMake configuration failed"
        # "${expanded_args[@]}" || die "CMake configuration failed"

    cmake --build . --parallel "${PARALLEL_PROCESSES:-$(nproc)}" || die "Build failed"
    cmake --install . || die "Installation failed"

    popd || die "Failed to return from build directory"
    popd || die "Failed to return from package directory"
    signal_installed "$package_name" "$version" "$prefix"
}