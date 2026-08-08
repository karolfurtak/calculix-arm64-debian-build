#!/usr/bin/env bash
#
# build-calculix-arm64.sh
#
# Builds CalculiX CrunchiX (ccx) 2.23 from source on Debian 13 (Trixie)
# ARM64/aarch64, including SPOOLES 2.2 (sparse solver), and installs the
# resulting binary to /usr/bin/ccx. ARPACK and BLAS/LAPACK are taken from
# Debian system packages.
#
# Why this script exists: as of Debian 13, the `calculix-ccx` package has
# no installable candidate on arm64 (only `calculix-ccx-test`, which ships
# examples/docs but no solver binary). This script reproduces a build that
# was verified on a Raspberry Pi 5 (Debian 13 Trixie, aarch64) in ~5 minutes.
#
# See README.md for the four upstream/toolchain workarounds this script
# applies, and why each one is necessary on GCC 14 / Debian 13.
#
# Usage:
#   ./build-calculix-arm64.sh [--keep-build-dir] [--build-dir DIR]
#
# Exit codes: non-zero on any failure (checksum mismatch, missing
# dependency, compile/link failure). The script does not continue silently
# past an error (set -euo pipefail).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CCX_VERSION="2.23"
CCX_URL="https://www.dhondt.de/ccx_${CCX_VERSION}.src.tar.bz2"
CCX_ARCHIVE="ccx_${CCX_VERSION}.src.tar.bz2"
CCX_SHA256="9c88385c10fb04f5dc6c4e98027a51bebdd8aee3920e05190d6c1dd08357d6e7"

SPOOLES_URL="https://www.netlib.org/linalg/spooles/spooles.2.2.tgz"
SPOOLES_ARCHIVE="spooles.2.2.tgz"
SPOOLES_SHA256="a84559a0e987a1e423055ef4fdf3035d55b65bbe4bf915efaa1a35bef7f8c5dd"

# Checksums above were verified against the independent sha256 published by
# the costerwi/homebrew-calculix Homebrew formula (github.com/costerwi/
# homebrew-calculix), since upstream (dhondt.de) does not publish its own
# checksums. If CalculiX releases a newer version, update CCX_VERSION /
# CCX_URL / CCX_SHA256 and re-verify against that formula (or another
# independent source) before trusting the new hash.

BUILD_DIR="${BUILD_DIR:-$HOME/build-ccx}"
KEEP_BUILD_DIR=0
INSTALL_PATH="/usr/bin/ccx"
JOBS="$(nproc 2>/dev/null || echo 2)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: build-calculix-arm64.sh [--keep-build-dir] [--build-dir DIR]

Builds CalculiX CrunchiX 2.23 + SPOOLES 2.2 from source and installs the
resulting solver to /usr/bin/ccx. See README.md for details.

  --keep-build-dir   do not delete the scratch build directory on exit
  --build-dir DIR    use DIR instead of $HOME/build-ccx as the scratch
                      build directory (must not already exist)
  -h, --help         show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-build-dir)
      KEEP_BUILD_DIR=1
      shift
      ;;
    --build-dir)
      [[ $# -ge 2 ]] || die "--build-dir requires an argument"
      BUILD_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

log "Checking architecture and OS"
ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
  echo "WARNING: this script targets ARM64/aarch64; detected '$ARCH'. Continuing anyway." >&2
fi
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "Detected OS: ${PRETTY_NAME:-unknown}"
  if [[ "${VERSION_CODENAME:-}" != "trixie" ]]; then
    echo "WARNING: this procedure was verified on Debian 13 (Trixie). Package versions on ${VERSION_CODENAME:-this release} may differ." >&2
  fi
fi

for cmd in curl sha256sum tar make gfortran gcc; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command '$cmd' not found. Install build-essential + gfortran first (see README)."
done

if ! dpkg -s libarpack2-dev >/dev/null 2>&1; then
  die "package 'libarpack2-dev' is not installed. Run: sudo apt-get install -y gfortran libarpack2-dev libopenblas-dev"
fi
if ! dpkg -s libopenblas-dev >/dev/null 2>&1; then
  die "package 'libopenblas-dev' is not installed. Run: sudo apt-get install -y gfortran libarpack2-dev libopenblas-dev"
fi

if [[ -e "$BUILD_DIR" ]]; then
  die "build directory '$BUILD_DIR' already exists. Remove it or pass --build-dir DIR."
fi

log "Creating build directory: $BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || die "could not enter build directory: $BUILD_DIR"

cleanup() {
  if [[ "$KEEP_BUILD_DIR" == "0" ]]; then
    log "Cleaning up build directory: $BUILD_DIR"
    cd / || return
    rm -rf "$BUILD_DIR"
  else
    echo "Build directory kept at: $BUILD_DIR"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Download + checksum verification (mandatory — the build aborts on mismatch)
# ---------------------------------------------------------------------------

log "Downloading CalculiX ${CCX_VERSION} source"
curl -fsSL -o "$CCX_ARCHIVE" "$CCX_URL" || die "download failed: $CCX_URL"

log "Downloading SPOOLES 2.2 source"
curl -fsSL -o "$SPOOLES_ARCHIVE" "$SPOOLES_URL" || die "download failed: $SPOOLES_URL"

log "Verifying SHA-256 checksums"
echo "${CCX_SHA256}  ${CCX_ARCHIVE}" | sha256sum -c - \
  || die "checksum mismatch for ${CCX_ARCHIVE} — aborting, will NOT build from an unverified archive."
echo "${SPOOLES_SHA256}  ${SPOOLES_ARCHIVE}" | sha256sum -c - \
  || die "checksum mismatch for ${SPOOLES_ARCHIVE} — aborting, will NOT build from an unverified archive."
echo "Checksums OK."

# ---------------------------------------------------------------------------
# Step 1 — SPOOLES 2.2 (sparse linear system solver)
# ---------------------------------------------------------------------------

log "Extracting SPOOLES 2.2"
mkdir -p SPOOLES.2.2
tar xzf "$SPOOLES_ARCHIVE" --one-top-level=SPOOLES.2.2
cd SPOOLES.2.2 || die "could not enter SPOOLES.2.2"

log "Patching SPOOLES Make.inc for a modern GCC toolchain"
sed -i 's|CC = /usr/lang-4.0/bin/cc|CC = gcc|' Make.inc
sed -i 's|CFLAGS = \$(OPTLEVEL)$|CFLAGS = \$(OPTLEVEL) -fcommon -fPIC -std=gnu89 -Wno-implicit-function-declaration -Wno-return-type|' Make.inc

# Workaround 1: the SPOOLES 2.2 source distribution ships a Makefile
# (Tree/src/makeGlobalLib) that references a file, drawTree.c, which does
# not exist in the tarball. The actual file is draw.c. Without this fix,
# `make global` fails with:
#   make: *** No rule to make target 'drawTree.o'
log "Workaround 1/4: fixing SPOOLES Tree/src/makeGlobalLib (drawTree.c -> draw.c)"
sed -i 's/drawTree\.c/draw.c/' Tree/src/makeGlobalLib

log "Building SPOOLES (make global)"
make global || die "SPOOLES build failed"
[[ -f spooles.a ]] || die "SPOOLES build did not produce spooles.a"
cd "$BUILD_DIR" || die "could not return to build directory: $BUILD_DIR"

# ---------------------------------------------------------------------------
# Step 2 — CalculiX CrunchiX 2.23
# ---------------------------------------------------------------------------

log "Extracting CalculiX ${CCX_VERSION} source"
tar xjf "$CCX_ARCHIVE"
CCX_SRC_DIR="$BUILD_DIR/CalculiX/ccx_${CCX_VERSION}/src"
[[ -d "$CCX_SRC_DIR" ]] || die "unexpected archive layout, expected: $CCX_SRC_DIR"
cd "$CCX_SRC_DIR" || die "could not enter $CCX_SRC_DIR"

[[ -f Makefile ]] || die "Makefile not found in $CCX_SRC_DIR"

log "Patching CalculiX Makefile for GCC 14 and system ARPACK/BLAS/LAPACK"

# Workaround 2: GCC >= 10 rejects Fortran argument type mismatches (common
# throughout CalculiX's Fortran 77-era code) as hard errors by default.
# Without -fallow-argument-mismatch (and -fallow-invalid-boz), compilation
# of the Fortran sources fails.
echo "Workaround 2/4: adding -fallow-argument-mismatch -fallow-invalid-boz to FFLAGS"
if grep -q '^FFLAGS' Makefile; then
  sed -i 's/^FFLAGS[[:space:]]*=.*/&  -fallow-argument-mismatch -fallow-invalid-boz/' Makefile
else
  die "could not find FFLAGS in Makefile — upstream layout may have changed"
fi

# Workaround 3: GCC 14 promoted several C diagnostics from warnings to hard
# errors by default (return-type mismatch, implicit function declaration,
# implicit int conversion, incompatible pointer types). CalculiX's C sources
# trip several of these, e.g. readnewmesh.c:468 returns NULL from a function
# declared void. The values themselves are harmless/discarded; without these
# flags the build aborts on the first such file.
echo "Workaround 3/4: adding -Wno-error=return-mismatch and related flags to CFLAGS"
if grep -q '^CFLAGS' Makefile; then
  sed -i 's/^CFLAGS[[:space:]]*=.*/&  -Wno-error=return-mismatch -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=implicit-int/' Makefile
else
  die "could not find CFLAGS in Makefile — upstream layout may have changed"
fi

# Workaround 4: the stock Makefile points LIBS at a locally-built ARPACK
# (../../../ARPACK/libarpack_INTEL.a), which this script does not build —
# it uses the Debian libarpack2-dev / libopenblas-dev packages instead.
# Adding -lgfortran explicitly (as some guides suggest) breaks the build:
# GNU Make's implicit rule for "-lNAME" prerequisites only searches
# '.', /lib, /usr/lib, /usr/local/lib — not the multiarch directory
# (/usr/lib/gcc/aarch64-linux-gnu/14/) where libgfortran.so actually lives
# on this system, so Make reports:
#   make: *** No rule to make target '-lgfortran'
# $(FC) (gfortran) already links libgfortran implicitly — do not add it.
echo "Workaround 4/4: pointing LIBS at system ARPACK/BLAS/LAPACK, no explicit -lgfortran"
if grep -q '^LIBS' Makefile; then
  sed -i "s|^LIBS[[:space:]]*=.*|LIBS = \$(DIR)/spooles.a -larpack -llapack -lblas -lpthread -lm -lc|" Makefile
else
  die "could not find LIBS in Makefile — upstream layout may have changed"
fi

log "Building CalculiX (make -j${JOBS} ccx_${CCX_VERSION})"
make -j"${JOBS}" "ccx_${CCX_VERSION}" || die "CalculiX build failed"
[[ -f "ccx_${CCX_VERSION}" ]] || die "build did not produce ccx_${CCX_VERSION}"

# ---------------------------------------------------------------------------
# Step 3 — install
# ---------------------------------------------------------------------------

log "Installing to ${INSTALL_PATH} (requires sudo)"
sudo cp "ccx_${CCX_VERSION}" "$INSTALL_PATH"
sudo chmod 755 "$INSTALL_PATH"
sudo chown root:root "$INSTALL_PATH"

log "Verifying installation"
if ! OUT="$("$INSTALL_PATH" -v 2>&1)"; then
  die "installed binary failed to run: $OUT"
fi
echo "$OUT"
echo "$OUT" | grep -q "Version ${CCX_VERSION}" || die "unexpected version output: $OUT"

log "Done. CalculiX CrunchiX ${CCX_VERSION} installed at ${INSTALL_PATH}."
