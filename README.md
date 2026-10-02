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
   Second, Debian's `calculix-ccx` 2.21-1 `debian/rules` adds
   `-fallow-argument-mismatch` to `FFLAGS` — needed for **2.21**'s Fortran
   sources, but measurably NOT needed for 2.23 (see workaround 2 below:
   upstream cleaned these up between 2.21 and 2.23) — and one of its four
   patches adds explicit prototypes to fix an implicit-function-declaration
   error. Whether Debian's 2.21 build hits the other GCC-14 C errors we
   could not confirm without attempting the rebuild.
2. **Pull the forky/sid package directly** (add that suite and pin
   `calculix-ccx` + `spooles` from it on an otherwise-Trixie system).
   Works, but drags a newer-release dependency chain onto a stable(-ish)
   system — the usual apt-pinning risk of partial upgrades and version
   skew. Treat as a stopgap, not a clean install.
3. **Build from the publisher's source — this repository.** The right
   choice when you specifically need **2.23**, newer than Debian's current
   2.21-1 (Debian's own package tracker flags 2.23 as a newer upstream
   version not yet packaged). This is where the three workarounds
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
chmod +x build-calculix-arm64.sh verify-calculix-arm64.sh
./build-calculix-arm64.sh          # add --no-install to build without sudo
./verify-calculix-arm64.sh         # then PROVE the binary computes correctly
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
5. Builds CalculiX 2.23, applying workarounds 2–3 below.
6. Installs the resulting binary to `/usr/bin/ccx` (`root:root`, `755`) —
   or leaves it in the build directory if you pass `--no-install` (no sudo
   needed then).
7. Runs `ccx -v` and checks the output — fails if the binary doesn't run or
   reports an unexpected version. (Judged by the printed version string:
   `ccx -v` exits with a non-zero status code even on success.)
8. Removes the scratch build directory (pass `--keep-build-dir` to keep it
   for inspection, or `--build-dir DIR` to choose its location).

A binary that builds and starts is **not** yet evidence that it computes
correctly — after building, run the verification suite:
see [Verifying computational correctness](#verifying-computational-correctness).

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

## The three workarounds

Building 20+ year old Fortran/C on a 2026-era Debian toolchain (GCC 14) hits
three specific problems. Each fix is applied automatically by the script;
they're documented here so you understand what it's doing to the sources
before you run it. Each was verified to be **minimal**: a clean-room build
with pristine flags and `make -k` (keep going past errors, to collect all of
them) was run on Debian 13/arm64 specifically to enumerate what actually
fails — see the evidence notes in each subsection.

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

### 2. `-Wno-error=return-mismatch` for GCC 14 — one benign hit

GCC 14 promoted several C diagnostics from warnings to hard errors by
default (return-type mismatches, implicit function declarations, implicit
int conversions, incompatible pointer types). For CalculiX **2.23**, exactly
**one** of them fires, in exactly **one** place:

```
readnewmesh.c:468:10: error: 'return' with a value, in function returning void [-Wreturn-mismatch]
```

That line is `return NULL;` at the end of a `void` multithreading helper —
the returned value is discarded, so the code's behaviour is unaffected;
only the diagnostic's severity changed in GCC 14. Fix: add
`-Wno-error=return-mismatch` to `CFLAGS` (this demotes it back to the
warning it was before GCC 14 — the warning still prints).

**Evidence this is minimal:** the clean-room `make -k` build compiled the
entire C codebase with pristine `CFLAGS` and produced exactly one error —
the line above. The broader flag batch that circulates in build guides
(`-Wno-error=implicit-function-declaration -Wno-error=int-conversion
-Wno-error=incompatible-pointer-types -Wno-error=implicit-int`) is **not
needed** for 2.23, so this script does not apply it — silencing compiler
checks that never fire would only mask future problems.

**What about `-fallow-argument-mismatch`?** Widely recommended for CalculiX
(and genuinely required for older releases such as the 2.21 that Debian
packages — Debian's own `debian/rules` adds it), this flag turns Fortran
argument-type/rank mismatches between a call and the called routine from
errors back into warnings. Such mismatches in a finite element solver would
be a real correctness concern — passing a `REAL*4` where `REAL*8` is
expected can silently corrupt numbers, which is why we tested rather than
assumed: the clean-room build compiled **every Fortran source file of 2.23
with pristine `FFLAGS`, without a single argument-mismatch diagnostic**
(gfortran 14.2.0 checks these within each compilation unit). Upstream
cleaned these up by 2.23. This script therefore leaves `FFLAGS` untouched —
no Fortran checks are silenced at all.

### 3. Replace the multi-line `LIBS` block (system ARPACK, no `-lgfortran`)

The stock CalculiX `Makefile` defines `LIBS` as a **multi-line block** with
backslash continuations, pointing at a locally-built ARPACK:

```make
LIBS = \
       $(DIR)/spooles.a \
	../../../ARPACK/libarpack_INTEL.a \
       -lpthread -lm -lc
```

This procedure does not build a local ARPACK — it links against the Debian
`libarpack2-dev` / `libopenblas-dev` packages instead (`-larpack -llapack
-lblas`). Two traps here, both verified by hitting them:

- **The whole continuation block must be replaced as a unit.** A naive
  `sed 's/^LIBS.*=.*/LIBS = .../'` replaces only the first line (`LIBS = \`)
  and leaves the orphaned continuation lines behind; `make` then dies at
  parse time with `Makefile:24: *** missing separator.  Stop.` The script
  uses a sed *range* (`/^LIBS[[:space:]]*=/,/[^\\]$/`) that spans the block
  to its last line (the first one not ending in a backslash), and asserts
  afterwards that the replacement took effect.
- **Do not add `-lgfortran`** (some build guides suggest it). `$(FC)`
  (gfortran) already links `libgfortran` implicitly. Adding it explicitly
  breaks the build, because the Makefile uses `$(LIBS)` both as linker
  arguments *and* as Make prerequisites, and GNU Make's library search for
  `-lNAME` prerequisites does not look in the GCC-internal directory
  (`/usr/lib/gcc/aarch64-linux-gnu/14/`) where `libgfortran.so` lives:

  ```
  make: *** No rule to make target '-lgfortran'
  ```

## Result

Verified on Raspberry Pi 5, Debian 13 Trixie, aarch64 — by running this
exact script end-to-end (`--no-install --build-dir …`), not a manual
approximation of it:

| Metric | Value |
|---|---|
| `ccx -v` | `This is Version 2.23` |
| Binary | ELF aarch64, ~5.5 MB, not stripped |
| Build time (`make -j4`, 4 cores) | ~5 minutes total (SPOOLES ~1 min, CalculiX ~4 min) |
| Scratch disk usage during build | ~67 MB, removed after install |
| Verification suite | see next section |

## Verifying computational correctness

**Why this section exists.** This build demotes one compiler error back to a
warning (workaround 2). For a solver whose output people may use for
strength assessment, the worst failure mode is not a crash — it is a result
that *looks* plausible and is wrong. A binary that builds and prints its
version number proves nothing about the numbers it computes. The only
meaningful evidence is comparing its results against the reference
solutions published by the CalculiX author — so this repository ships a
second script that does exactly that:

```bash
./verify-calculix-arm64.sh                # verifies /usr/bin/ccx
./verify-calculix-arm64.sh --ccx PATH     # verifies any ccx binary
```

It downloads the official CalculiX 2.23 verification suite
(`ccx_2.23.test.tar.bz2` from dhondt.de, SHA-256 checked against the same
independent source as the build inputs), runs all ~630 example problems
(35–40 min on a Pi 5, single-threaded by upstream's design), and compares
every `.dat`/`.frd` output numerically against the reference results using
upstream's own `datcheck.pl`/`frdcheck.pl` tolerances and NaN checks.

**Measured result on Raspberry Pi 5 (Debian 13, aarch64), binary built by
this script:** 633 examples executed, **597 fully clean (94.3%)**, 36
flagged by upstream's comparison, all in these categories:

| Category | Count | Assessment |
|---|---|---|
| Missing `.ref` file in the upstream archive (`*.rfn.dat.ref`) | 4 | Defect of the test archive, not of the binary — the reference file simply is not shipped. |
| Pure sign flip (computed value equal in magnitude, opposite sign) | 4 | Eigenvectors/mode shapes: **v** and **−v** are both mathematically valid solutions of an eigenproblem; the sign is arbitrary and platform-dependent. |
| Small numeric deviations (~0.1–10% of the block maximum) | 14 | Consistent with different BLAS/architecture rounding on iterative/nonlinear problems; **not independently confirmed as benign** — see honesty note below. |
| Output file missing or its length differs from reference | 14 | Typically a different iteration count changes how many lines land in `.dat`; **not independently confirmed as benign** — see honesty note below. |

**Honesty note — read before trusting results.** The upstream reference
files were generated on the author's x86-64 machine; the suite is known not
to compare bit-identically across platforms/BLAS builds even for correct
binaries. We did **not** have an x86-64 baseline run to separate
"ARM64-specific deviation" from "any modern rebuild deviates here". What we
can honestly state: 94% of the examples agree with the published reference
results within upstream's own tolerances, the remainder falls into the
categories above, and the discrepancy report was **byte-for-byte identical**
for two independently compiled binaries (different diagnostic flag sets,
same sources, same machine) — which points at platform/library arithmetic,
not at this build procedure. If your
work depends on one of the flagged analysis types (see
`verify-calculix-arm64.sh` output for the exact example names — e.g. tied
contact `beamptied*`, substructures, sensitivity `sens_*`), validate that
feature against a known solution or a trusted x86-64 CalculiX before
relying on it.

## Licensing of components

This repository's own script and documentation are licensed as described in
[LICENSE](LICENSE). The software this script *builds* carries its own,
separate licenses — this repository does not redistribute any of it (see
[What this repository does — and deliberately does not — provide](#what-this-repository-does--and-deliberately-does-not--provide)),
but you should know what you're building under:

- **CalculiX CrunchiX** — [GNU General Public License v2](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html).
  Source: [dhondt.de/ccx.html](http://www.dhondt.de/ccx.html) /
  [calculix.de](http://www.calculix.de/).
- **SPOOLES 2.2** — released into the **public domain** by its authors.
  The source archive ships no standalone license file; the statement lives
  in the bundled Reference Manual
  (`documentation/ReferenceManual/main.tex`): "This release of the package
  is totally within the public domain; there are absolutely no licensing
  restrictions as with other software packages." (Cross-checked against
  Debian's `spooles` source package — Debian ships SPOOLES in its `main`
  archive area, which only accepts DFSG-compliant licenses, so public
  domain checks out; it is simply absent from Trixie specifically, see
  [The problem](#the-problem).) Source:
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
both shell scripts (`build-calculix-arm64.sh`, `verify-calculix-arm64.sh`)
on every push and pull request.

It does **not** actually run the build on ARM64. GitHub-hosted Actions
runners are Ubuntu-based, not Debian, and the point of this procedure is
specifically the package/toolchain combination on Debian 13 Trixie —
running it on a different distribution wouldn't validate the thing this
repository is about, and would add a slow, resource-heavy job for
comparatively little assurance. If you want to verify the build itself,
run the script on real Debian 13 ARM64 hardware (or a matching container),
then run `verify-calculix-arm64.sh` against the produced binary (see
[Verifying computational correctness](#verifying-computational-correctness)).
This is stated here explicitly rather than left implied by a CI badge that
only proves the shell syntax is clean.

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

**Poprawność obliczeń, nie tylko kompilacja:** budowa wymaga zdegradowania
jednej kontroli kompilatora GCC 14 z błędu do ostrzeżenia (pojedyncze,
nieszkodliwe `return NULL;` w funkcji `void` — wartość jest odrzucana).
Żadna kontrola Fortranu nie jest wyciszana (sprawdzono budową bez obejść:
zero niezgodności argumentów w 2.23). Drugi skrypt,
`verify-calculix-arm64.sh`, uruchamia oficjalny zestaw ~630 zadań
weryfikacyjnych autora CalculiX i porównuje wyniki liczbowo z wynikami
referencyjnymi — szczegóły i uczciwe omówienie odchyłek w sekcji
*Verifying computational correctness*. Binarka, która się uruchamia, nie
jest jeszcze dowodem, że liczy poprawnie — uruchom weryfikację.

Repozytorium **nie zawiera** ani binarki `ccx`, ani kodu źródłowego
CalculiX/SPOOLES — to świadoma decyzja: CalculiX jest na licencji GPL w
wersji 2, a publikacja skompilowanej binarki wymagałaby udostępnienia
odpowiadającego jej kodu źródłowego. Skrypt i dokumentacja własna są na
licencji MIT (patrz [LICENSE](LICENSE)); nie dotyczy to licencji CalculiX,
SPOOLES, ARPACK ani OpenBLAS — patrz sekcja *Licensing of components*
wyżej.
