# CalculiX ARM64 Debian Build

A verified, repeatable procedure for building the **CalculiX CrunchiX (ccx)**
finite element solver from source on **Debian 13 (Trixie), ARM64/aarch64**
(tested on a Raspberry Pi 5) — because the `calculix-ccx` package has no
installable binary on this platform.

## The problem

On Debian 13 (Trixie), `arm64`:

```
$ apt-cache policy calculix-ccx
calculix-ccx:
  Installed: (none)
  Candidate: (none)
  Version table:
```

There is no candidate to install. The only related package available is
`calculix-ccx-test`, which ships example decks and documentation — **not**
the solver binary. Anyone running CalculiX on a Raspberry Pi, or any other
ARM64 board on Debian 13, hits this same wall.

This is a **Trixie-specific gap**, not a permanent absence from Debian.
Per the [Debian package tracker](https://tracker.debian.org/pkg/calculix-ccx),
`calculix-ccx` shipped in bookworm/oldstable (2.20-1) and is present again in
forky/testing and sid/unstable (2.21-1) — it was dropped from testing before
the Trixie freeze and only re-entered testing on 2025-10-21, after Trixie had
already been released. Its dependency `spooles` (providing `libspooles-dev`)
has the same shape: packaged in bookworm (2.2-14) and in forky/sid (2.2-16),
absent from Trixie and Trixie-backports.

### Three ways to get `ccx` on Debian 13 arm64, simplest first

1. **Rebuild Debian's own source packages for Trixie**
   (`apt-get source spooles`, `apt-get source calculix-ccx` from forky/sid,
   then `dpkg-buildpackage` locally). This produces a real `.deb`,
   installable/removable/upgradeable through `apt`, carrying Debian's own
   patch set. Two caveats — we read Debian's patches and `debian/rules` to
   write this section, but did **not** perform this build ourselves, so
   treat both as leads to verify, not settled facts: first, since
   `libspooles-dev` is also absent from Trixie, you'd need to rebuild
   `spooles` *before* `calculix-ccx` — two source packages, not one.
   Second, Debian's `calculix-ccx` 2.21-1 `debian/rules` does add
   `-fallow-argument-mismatch` to `FFLAGS` (the same GCC-14 Fortran fix as
   workaround 2 below, confirming it's a genuine toolchain issue and not
   something specific to a manual build) and one of its four patches adds
   explicit prototypes to fix an implicit-function-declaration error (a
   targeted version of workaround 3) — but nothing in the patch set or
   rules file visibly addresses the return-mismatch/int-conversion/
   incompatible-pointer-types errors or the `-lgfortran` linking problem
   (workarounds 3's remainder and workaround 4). Whether that means they
   aren't hit on Debian's exact build, or the package's GCC 14 build health
   is itself an open question, we could not confirm without attempting the
   rebuild.
2. **Pull the forky/sid package directly** (add that suite and pin
   `calculix-ccx` + `spooles` from it on an otherwise-Trixie system).
   Works, but drags a newer-release dependency chain onto a stable(-ish)
   system — the usual apt-pinning risk of partial upgrades and version
   skew. Treat as a stopgap, not a clean install.
3. **Build from the publisher's source — this repository.** The right
   choice when you specifically need **2.23**, newer than Debian's current
   2.21-1 (Debian's own package tracker flags 2.23 as a newer upstream
   version not yet packaged). This is where the four GCC-14 workarounds
   below are load-bearing, and they're verified end-to-end because this is
   the exact build we performed: on a Raspberry Pi 5, building
   **CalculiX CrunchiX 2.23** together with **SPOOLES 2.2** (built from
   source here to get a version this script controls end-to-end,
   independent of what happens to be in whichever suite), while using
   Debian's system packages for **ARPACK** (eigenvalue/eigenvector
   computation, used for modal analysis) and **BLAS/LAPACK** (Basic Linear
   Algebra Subprograms / Linear Algebra Package). The full build — SPOOLES
   + CalculiX — took **about 5 minutes**.

The rest of this document covers path 3.

## What this repository does — and deliberately does not — provide

This repository provides only the **build procedure**: a script that
downloads source archives from their original publishers, verifies their
checksums, applies the toolchain fixes needed for a modern GCC, and compiles
locally.

It does **not** contain, and will never contain, the CalculiX or SPOOLES
source code, nor a prebuilt `ccx` binary. CalculiX is licensed under
**GPLv2** (see [Licensing of components](#licensing-of-components) below);
distributing a compiled GPLv2 binary would obligate the distributor to also
offer the corresponding source. Publishing only the build procedure — and
letting the script fetch sources directly from upstream — avoids that
obligation entirely while still getting you a working solver in minutes.

## Requirements

- Debian 13 (Trixie), ARM64/aarch64 (verified on Raspberry Pi 5; other
  Debian 13 arm64 systems should work identically since this is the same
  package set)
- `sudo` access (the script installs the final binary to `/usr/bin/ccx`)
- Internet access to `dhondt.de` and `netlib.org`
- ~70 MB free disk space during the build (removed again on completion)

Install build dependencies:

```bash
sudo apt-get install -y gfortran libarpack2-dev libopenblas-dev
```

| Package | Verified version (Trixie/arm64) | Role |
|---|---|---|
| `gfortran` | 4:14.2.0-1 (GCC 14.2.0) | Fortran compiler — most of CalculiX is Fortran 77 |
| `libarpack2-dev` | 3.9.1-6 | ARPACK (packaged as arpack-ng) — modal analysis |
| `libopenblas-dev` | 0.3.29+ds-3 | BLAS + LAPACK, selected via `update-alternatives` |
| `build-essential` | usually already installed | gcc, make, ar |

`build-essential` is assumed present; the script checks for `gcc`/`make` and
fails fast with a clear message if they're missing.

## Usage

```bash
git clone https://github.com/karolfurtak/calculix-arm64-debian-build.git
cd calculix-arm64-debian-build
chmod +x build-calculix-arm64.sh
./build-calculix-arm64.sh
```

The script:

1. Checks architecture, OS release, and required tools/packages — exits
   with a clear error instead of failing halfway through a compile.
2. Downloads `ccx_2.23.src.tar.bz2` (from dhondt.de) and `spooles.2.2.tgz`
   (from netlib.org) into a scratch build directory.
3. Verifies both archives against **known-good SHA-256 checksums** before
   touching them — see [Checksum verification](#checksum-verification). If
   a checksum doesn't match, the build aborts. It does not continue with an
   unverified archive.
4. Builds SPOOLES 2.2, applying workaround 1 below.
5. Builds CalculiX 2.23, applying workarounds 2–4 below.
6. Installs the resulting binary to `/usr/bin/ccx` (`root:root`, `755`).
7. Runs `ccx -v` and checks the output — fails if the binary doesn't run or
   reports an unexpected version.
8. Removes the scratch build directory (pass `--keep-build-dir` to keep it
   for inspection, or `--build-dir DIR` to choose its location).

Expected result:

```
$ ccx -v
This is Version 2.23
```

## Checksum verification

Upstream (dhondt.de / calculix.de) does not publish its own checksums for
the CalculiX source tarball. The checksums baked into the build script were
cross-checked against the independently published `sha256` in the
[`costerwi/homebrew-calculix`](https://github.com/costerwi/homebrew-calculix)
Homebrew formula, and matched byte-for-byte.

| File | SHA-256 |
|---|---|
| `ccx_2.23.src.tar.bz2` | `9c88385c10fb04f5dc6c4e98027a51bebdd8aee3920e05190d6c1dd08357d6e7` |
| `spooles.2.2.tgz` | `a84559a0e987a1e423055ef4fdf3035d55b65bbe4bf915efaa1a35bef7f8c5dd` |

If CalculiX ever publishes a newer version, update the version/URL/checksum
constants at the top of the script — and re-verify the new hash against an
independent source (e.g. the Homebrew formula above) before trusting it.

## The four workarounds

Building 20+ year old Fortran/C on a 2026-era Debian toolchain (GCC 14) hits
four specific problems. Each one is applied automatically by the script;
they're documented here so you understand what it's doing to the sources
before you run it.

### 1. SPOOLES 2.2 source tarball references a file that doesn't exist

`Tree/src/makeGlobalLib` (inside the SPOOLES source tree) references
`drawTree.c`. That file is not present in the tarball — the actual file is
`draw.c`. Without a fix, `make global` fails with:

```
make: *** No rule to make target 'drawTree.o'
```

Fix: `sed -i 's/drawTree\.c/draw.c/' Tree/src/makeGlobalLib`

This is a known defect in the SPOOLES 2.2 distribution itself (also noted in
CalculiX's own installation notes), not something introduced by Debian or by
this script.

### 2. `-fallow-argument-mismatch` for GCC 14

GCC 10 and later reject Fortran argument-type mismatches (e.g. passing a
`REAL` where a `REAL*8` is expected) as hard errors by default. CalculiX's
Fortran 77-era code relies on such mismatches throughout — without
`-fallow-argument-mismatch -fallow-invalid-boz` added to `FFLAGS`,
compilation fails on the first mismatched call.

### 3. `-Wno-error=return-mismatch` and related flags for GCC 14

GCC 14 promoted several C diagnostics from warnings to hard errors by
default: return-type mismatches, implicit function declarations, implicit
int conversions, and incompatible pointer types. CalculiX's C sources trip
several of these — for example `readnewmesh.c:468` does `return NULL;`
inside a function declared `void`. The value is harmless (it's discarded by
the caller either way), but GCC 14 now stops the build over it. Fix: add
`-Wno-error=return-mismatch -Wno-error=implicit-function-declaration
-Wno-error=int-conversion -Wno-error=incompatible-pointer-types
-Wno-error=implicit-int` to `CFLAGS`.

### 4. Remove the unneeded `-lgfortran` from `LIBS`

The stock CalculiX `Makefile` expects a locally-built ARPACK at
`../../../ARPACK/libarpack_INTEL.a`, which this procedure does not build —
it links against the Debian `libarpack2-dev` / `libopenblas-dev` packages
instead (`-larpack -llapack -lblas`). Some build guides also add
`-lgfortran` explicitly to `LIBS` at this point — don't. `$(FC)` (gfortran)
already links `libgfortran` implicitly. Adding it explicitly breaks the
build, because GNU Make's implicit rule for resolving `-lNAME`
prerequisites only searches `.`, `/lib`, `/usr/lib`, and `/usr/local/lib` —
not the multiarch directory (`/usr/lib/gcc/aarch64-linux-gnu/14/`) where
`libgfortran.so` actually lives on this system:

```
make: *** No rule to make target '-lgfortran'
```

## Result

Verified on Raspberry Pi 5, Debian 13 Trixie, aarch64:

| Metric | Value |
|---|---|
| `ccx -v` | `This is Version 2.23` |
| Binary | `/usr/bin/ccx`, ELF aarch64, ~5.5 MB, not stripped |
| Build time (`make -j4`, 4 cores) | ~5 minutes total (SPOOLES ~1 min, CalculiX ~4 min) |
| Scratch disk usage during build | ~67 MB, removed after install |

## Licensing of components

This repository's own script and documentation are licensed as described in
[LICENSE](LICENSE). The software this script *builds* carries its own,
separate licenses — this repository does not redistribute any of it (see
[What this repository does — and deliberately does not — provide](#what-this-repository-does--and-deliberately-does-not--provide)),
but you should know what you're building under:

- **CalculiX CrunchiX** — [GNU General Public License v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html).
  Source: [dhondt.de/ccx.html](http://www.dhondt.de/ccx.html) /
  [calculix.de](http://www.calculix.de/).
- **SPOOLES 2.2** — released into the **public domain** by its authors; the
  license file bundled in the source archive states "this release is
  entirely within the public domain; there are no licensing restrictions,
  and there is no warranty of any sort" (cross-checked against Debian's
  `spooles` source package copyright file — Debian ships SPOOLES in its
  `main` archive area, which only accepts DFSG-compliant licenses, so
  public domain checks out; it is simply absent from Trixie specifically,
  see [The problem](#the-problem)). Read the license file included in the
  SPOOLES source archive itself before redistributing anything built with
  it. Source:
  [netlib.org/linalg/spooles](https://www.netlib.org/linalg/spooles/).
- **ARPACK** (via Debian's `libarpack2-dev`, packaged as arpack-ng) —
  [BSD 3-Clause License](https://github.com/opencollab/arpack-ng/blob/master/COPYING).
  Source: [github.com/opencollab/arpack-ng](https://github.com/opencollab/arpack-ng).
- **OpenBLAS** (via Debian's `libopenblas-dev`) — BSD 3-Clause License.
  Source: [github.com/OpenMathLib/OpenBLAS](https://github.com/OpenMathLib/OpenBLAS).

This section is a pointer to those licenses, not a reproduction of them —
consult the original sources for the authoritative text before
redistributing anything you build.

## Continuous integration

CI runs [ShellCheck](https://www.shellcheck.net/) static analysis against
`build-calculix-arm64.sh` on every push and pull request.

It does **not** actually run the build on ARM64. GitHub-hosted Actions
runners are Ubuntu-based, not Debian, and the point of this procedure is
specifically the package/toolchain combination on Debian 13 Trixie —
running it on a different distribution wouldn't validate the thing this
repository is about, and would add a slow, resource-heavy job for
comparatively little assurance. If you want to verify the build itself,
run the script on real Debian 13 ARM64 hardware (or a matching container)
and check `ccx -v`. This is stated here explicitly rather than left
implied by a CI badge that only proves the shell syntax is clean.

## License

This repository's script and documentation are released under the
[MIT License](LICENSE) — permissive and effectively frictionless to reuse,
appropriate for a short automation script whose value is in being copied,
adapted, and redistributed by anyone who hits the same ARM64 packaging gap.
It applies **only** to the contents of this repository (the script and this
documentation); it says nothing about, and grants no rights to, CalculiX,
SPOOLES, ARPACK, or OpenBLAS themselves — see
[Licensing of components](#licensing-of-components) above.

---

## Po polsku (skrót)

W Debianie 13 na ARM64 pakiet `calculix-ccx` nie ma kandydata do instalacji
— dostępna jest tylko wersja z dokumentacją, bez binarki solvera. To
repozytorium zawiera skrypt budujący **CalculiX CrunchiX 2.23** ze źródeł
(wraz z **SPOOLES 2.2**, ARPACK i BLAS/LAPACK z pakietów systemowych),
zweryfikowany na Raspberry Pi 5 (Debian 13 Trixie) — budowa trwa ok. 5
minut. Skrypt pobiera źródła bezpośrednio od wydawców i weryfikuje sumy
kontrolne SHA-256 przed budową; przerywa działanie przy niezgodności.
Repozytorium **nie zawiera** ani binarki `ccx`, ani kodu źródłowego
CalculiX/SPOOLES — to świadoma decyzja: CalculiX jest na licencji GPL w
wersji 2, a publikacja skompilowanej binarki wymagałaby udostępnienia
odpowiadającego jej kodu źródłowego. Skrypt i dokumentacja własna są na
licencji MIT (patrz [LICENSE](LICENSE)); nie dotyczy to licencji CalculiX,
SPOOLES, ARPACK ani OpenBLAS — patrz sekcja *Licensing of components*
wyżej.
