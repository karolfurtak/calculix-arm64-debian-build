#!/usr/bin/env bash
#
# verify-calculix-arm64.sh
#
# Runs the official CalculiX 2.23 verification suite (published by the
# CalculiX author at dhondt.de) against an installed ccx binary, and reports
# whether the computed results agree with the reference results.
#
# Why this exists: the build procedure in this repository silences several
# compiler checks (see README, workarounds 2 and 3) to get 20+ year old
# Fortran/C code through GCC 14. A binary that merely *builds and starts* is
# not evidence that it *computes correctly*. This script provides that
# evidence: it runs the ~630 example problems shipped by upstream and
# compares every .dat/.frd output numerically against the reference files
# (via upstream's own datcheck.pl/frdcheck.pl tolerances).
#
# Usage:
#   ./verify-calculix-arm64.sh [--ccx PATH] [--work-dir DIR] [--keep-work-dir]
#
# Runtime: about 35-40 minutes on a Raspberry Pi 5 (measured; the suite is
# single-threaded by upstream's design: it exports OMP_NUM_THREADS=1).
#
# Exit codes: 0 = all examples agree with the reference results;
# non-zero = download/extraction failure, or at least one discrepancy
# (the discrepancies are printed and kept in the work directory).

set -euo pipefail

CCX_VERSION="2.23"
TEST_URL="https://www.dhondt.de/ccx_${CCX_VERSION}.test.tar.bz2"
TEST_ARCHIVE="ccx_${CCX_VERSION}.test.tar.bz2"
# Independent source for this hash: costerwi/homebrew-calculix formula
# (github.com/costerwi/homebrew-calculix, calculix-ccx.rb, resource "test").
TEST_SHA256="be2259fd9a7b990d0453b30708e1b05f2cd4b6df4a90fa96f0e4abd1ae7beaa0"

CCX_BIN="/usr/bin/ccx"
WORK_DIR="${WORK_DIR:-$HOME/verify-ccx}"
KEEP_WORK_DIR=0

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: verify-calculix-arm64.sh [--ccx PATH] [--work-dir DIR] [--keep-work-dir]

Downloads the official CalculiX verification suite and runs it against an
installed ccx binary, comparing all results against upstream references.

  --ccx PATH         ccx binary to verify (default /usr/bin/ccx)
  --work-dir DIR     scratch directory (default $HOME/verify-ccx;
                     must not already exist)
  --keep-work-dir    keep the scratch directory even on success
  -h, --help         show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ccx)
      [[ $# -ge 2 ]] || die "--ccx requires an argument"
      CCX_BIN="$2"; shift 2 ;;
    --work-dir)
      [[ $# -ge 2 ]] || die "--work-dir requires an argument"
      WORK_DIR="$2"; shift 2 ;;
    --keep-work-dir)
      KEEP_WORK_DIR=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1 (see --help)" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "required command 'curl' not found"
command -v sha256sum >/dev/null 2>&1 || die "required command 'sha256sum' not found"
command -v perl >/dev/null 2>&1 || die "required command 'perl' not found (datcheck.pl/frdcheck.pl need it)"
[[ -x "$CCX_BIN" ]] || die "ccx binary not found or not executable: $CCX_BIN"

VERSION_OUT="$("$CCX_BIN" -v 2>&1 || true)"
echo "$VERSION_OUT" | grep -q "Version ${CCX_VERSION}" \
  || die "binary reports '${VERSION_OUT}' — expected Version ${CCX_VERSION}. Reference results are version-specific; refusing to compare across versions."

[[ -e "$WORK_DIR" ]] && die "work directory '$WORK_DIR' already exists. Remove it or pass --work-dir DIR."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || die "could not enter work directory: $WORK_DIR"

log "Downloading CalculiX ${CCX_VERSION} verification suite"
curl -fsSL -o "$TEST_ARCHIVE" "$TEST_URL" || die "download failed: $TEST_URL"

log "Verifying SHA-256 checksum"
echo "${TEST_SHA256}  ${TEST_ARCHIVE}" | sha256sum -c - \
  || die "checksum mismatch for ${TEST_ARCHIVE} — aborting."

log "Extracting"
tar xjf "$TEST_ARCHIVE"
TEST_DIR="$WORK_DIR/CalculiX/ccx_${CCX_VERSION}/test"
[[ -d "$TEST_DIR" ]] || die "unexpected archive layout, expected: $TEST_DIR"
cd "$TEST_DIR" || die "could not enter $TEST_DIR"
[[ -f compare ]] || die "upstream 'compare' script not found in the suite"

# Upstream's compare script hardcodes the binary path ~/CalculiX/src/CalculiX.
# Point it at the binary under test instead; everything else (tolerances,
# NaN detection, .dat/.frd numeric comparison) is upstream's own logic.
sed "s|~/CalculiX/src/CalculiX|${CCX_BIN}|" compare > compare_installed
chmod +x compare_installed

N_TOTAL="$(find . -maxdepth 1 -name '*.inp' | wc -l)"
log "Running the verification suite (${N_TOTAL} example problems, single-threaded)"
echo "This takes about 35-40 minutes on a Raspberry Pi 5. Progress: tail -f ${TEST_DIR}/compare_run.log"
./compare_installed > compare_run.log 2>&1 || true

# The suite writes discrepancies to error.<pid>; no such file (or an empty
# one) means every example agreed with the reference results within
# upstream's tolerances.
shopt -s nullglob
ERROR_FILES=(error.*)
FAILED=0
for f in "${ERROR_FILES[@]}"; do
  if [[ -s "$f" ]]; then
    FAILED=1
  fi
done

if [[ "$FAILED" == "0" ]]; then
  log "RESULT: PASS — all ${N_TOTAL} examples agree with upstream reference results."
  if [[ "$KEEP_WORK_DIR" == "0" ]]; then
    cd / && rm -rf "$WORK_DIR"
    echo "Work directory removed. (Pass --keep-work-dir to keep it.)"
  else
    echo "Work directory kept at: $WORK_DIR"
  fi
  exit 0
else
  log "RESULT: DISCREPANCIES — upstream comparison flagged the following:"
  cat "${ERROR_FILES[@]}"
  echo
  echo "Full run log: ${TEST_DIR}/compare_run.log (work directory kept for inspection)"
  echo "Interpretation: see 'Verifying computational correctness' in README.md."
  echo "On Debian 13/arm64 a known set of ~36 items is expected (missing upstream"
  echo ".ref files, eigenvector sign flips, small platform-arithmetic deviations)."
  echo "Anything beyond that set — or any NaN — means: do NOT trust this binary"
  echo "for real analyses until the discrepancy is understood."
  exit 1
fi
