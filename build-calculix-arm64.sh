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
# See README.md for the three upstream/toolchain workarounds this script
# applies, and why each one is necessary on GCC 14 / Debian 13. Each
# workaround was verified to be the MINIMAL set needed: a clean-room build
# without them fails on exactly the spots they address, and with them the
# full CalculiX verification suite was run against the resulting binary
# (see "Verifying computational correctness" in README.md).
#
# Usage:
#   ./build-calculix-arm64.sh [--keep-build-dir] [--build-dir DIR] [--no-install]
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
NO_INSTALL=0
INSTALL_PATH="/usr/bin/ccx"
JOBS="$(nproc 2>/dev/null || echo 2)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: build-calculix-arm64.sh [--keep-build-dir] [--build-dir DIR] [--no-install]

Builds CalculiX CrunchiX 2.23 + SPOOLES 2.2 from source and installs the
resulting solver to /usr/bin/ccx. See README.md for details.

  --keep-build-dir   do not delete the scratch build directory on exit
  --build-dir DIR    use DIR instead of $HOME/build-ccx as the scratch
                      build directory (must not already exist)
  --no-install       build only; skip the sudo install to /usr/bin/ccx and
                      leave the binary in the build directory (implies
                      --keep-build-dir)
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
    --no-install)
      NO_INSTALL=1
      KEEP_BUILD_DIR=1
      shift
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
log "Workaround 1/3: fixing SPOOLES Tree/src/makeGlobalLib (drawTree.c -> draw.c)"
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

# Workaround 2: GCC 14 treats a `return` with a value inside a `void`
# function as a hard error (-Wreturn-mismatch was promoted to an error).
# CalculiX 2.23 trips this in exactly ONE place: readnewmesh.c:468 does
# `return NULL;` at the end of a void multithreading helper — the value is
# discarded, so the code is harmless; only the diagnostic severity changed.
# Evidence that this is the MINIMAL C workaround: a clean-room build on
# Debian 13/arm64 with pristine CFLAGS and `make -k` produced exactly one
# error in the entire C codebase (readnewmesh.c:468) and none elsewhere,
# so the broader -Wno-error=implicit-function-declaration/int-conversion/
# incompatible-pointer-types/implicit-int batch recommended by some guides
# is NOT needed for 2.23 and is deliberately not applied here.
# Note on Fortran: -fallow-argument-mismatch, widely recommended for older
# CalculiX releases, is NOT needed for 2.23 either — the same clean-room
# build compiled every Fortran source without a single argument-mismatch
# diagnostic, so this script leaves FFLAGS untouched.
echo "Workaround 2/3: adding -Wno-error=return-mismatch to CFLAGS (single benign hit: readnewmesh.c:468)"
if grep -q '^CFLAGS' Makefile; then
  sed -i 's/^CFLAGS[[:space:]]*=.*/&  -Wno-error=return-mismatch/' Makefile
else
  die "could not find CFLAGS in Makefile — upstream layout may have changed"
fi

# Workaround 3: the stock Makefile defines LIBS as a MULTI-LINE block
# (backslash continuations) pointing at a locally-built ARPACK
# (../../../ARPACK/libarpack_INTEL.a), which this script does not build —
# it uses the Debian libarpack2-dev / libopenblas-dev packages instead.
# The whole continuation block must be replaced as a unit: replacing only
# the first `LIBS = \` line (as a naive `sed s/^LIBS=.*/.../` does) leaves
# the orphaned continuation lines behind and make dies at parse time with
#   Makefile:24: *** missing separator.  Stop.
# The address range /^LIBS/,/[^\\]$/ spans from the LIBS line to the first
# line that does NOT end in a backslash, i.e. the entire block.
# Also: do NOT add -lgfortran here (some guides suggest it). LIBS is used
# both as linker arguments and as Make prerequisites; GNU Make's library
# search for "-lNAME" prerequisites does not look in the GCC-internal
# directory (/usr/lib/gcc/aarch64-linux-gnu/14/) where libgfortran.so
# lives, so make reports:
#   make: *** No rule to make target '-lgfortran'
# $(FC) (gfortran) already links libgfortran implicitly — do not add it.
echo "Workaround 3/3: replacing the multi-line LIBS block with system ARPACK/BLAS/LAPACK"
if grep -q '^LIBS' Makefile; then
  sed -i -e '/^LIBS[[:space:]]*=/,/[^\\]$/c\LIBS = $(DIR)/spooles.a -larpack -llapack -lblas -lpthread -lm -lc' Makefile
else
  die "could not find LIBS in Makefile — upstream layout may have changed"
fi
grep -q '^LIBS = \$(DIR)/spooles.a -larpack' Makefile \
  || die "LIBS replacement did not take effect — upstream Makefile layout may have changed"

log "Building CalculiX (make -j${JOBS} ccx_${CCX_VERSION})"
make -j"${JOBS}" "ccx_${CCX_VERSION}" || die "CalculiX build failed"
[[ -f "ccx_${CCX_VERSION}" ]] || die "build did not produce ccx_${CCX_VERSION}"

# ---------------------------------------------------------------------------
# Step 3 — install (or report, with --no-install)
# ---------------------------------------------------------------------------

if [[ "$NO_INSTALL" == "1" ]]; then
  BINARY_PATH="$CCX_SRC_DIR/ccx_${CCX_VERSION}"
else
  log "Installing to ${INSTALL_PATH} (requires sudo)"
  sudo cp "ccx_${CCX_VERSION}" "$INSTALL_PATH"
  sudo chmod 755 "$INSTALL_PATH"
  sudo chown root:root "$INSTALL_PATH"
  BINARY_PATH="$INSTALL_PATH"
fi

log "Verifying the binary starts and reports the right version"
# Note: `ccx -v` exits with a NON-ZERO status (201) even on success, so the
# exit code must not be treated as failure — judge by the output instead.
OUT="$("$BINARY_PATH" -v 2>&1 || true)"
echo "$OUT"
echo "$OUT" | grep -q "Version ${CCX_VERSION}" \
  || die "unexpected version output from ${BINARY_PATH}: $OUT"

if [[ "$NO_INSTALL" == "1" ]]; then
  log "Done. Binary built (not installed): ${BINARY_PATH}"
else
  log "Done. CalculiX CrunchiX ${CCX_VERSION} installed at ${INSTALL_PATH}."
fi
echo "A binary that starts is not yet proof it computes correctly."
echo "Run ./verify-calculix-arm64.sh to check it against the official"
echo "CalculiX verification suite (~630 reference problems, ~35 min on a Pi 5)."
