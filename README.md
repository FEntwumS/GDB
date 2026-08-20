# FEntwumS GDB

Portable GDB distribution for the **SvNR debugger**, built as part of the
[FEntwumS](https://www.th-koeln.de/informations-medien-und-elektrotechnik/forschungsprojekt-fentwums_112124.php)
project.

What ships is a relocated, self-contained GDB binary that the
[OneWare Studio Extension Manager](https://oneware.io) downloads and the
SvNR debugger plugin uses.

## Current artifacts

| Platform       | Version | Release asset                  | Produced by         |
|----------------|---------|--------------------------------|---------------------|
| linux-x86_64   | 17.2    | `gdb-linux-x86_64-py.tar.gz`   | CI (GitHub Actions) |
| macOS ARM64    | 17.2    | `gdb-macos-arm64-py.tar.gz`    | CI (GitHub Actions) |
| windows-x86_64 | 17.2    | `gdb-windows-x86_64.zip`       | CI (GitHub Actions) |

Every archive holds the binary at the same relative path: `bin/gdb-multiarch-py`
with Python scripting, `bin/gdb-multiarch.exe` on Windows. The plugin therefore
needs no per-platform special case.

Every archive comes with a `.sha256` file holding its checksum. Windows ships
as `.zip` -- double-click extraction without an extra tool -- the other two
as `.tar.gz`. All three are
produced entirely in CI; there is no local build step left.

## Release process

Binaries are no longer produced on a developer machine but in CI. The
authoritative definition is the workflow `.github/workflows/build-gdb.yml`,
which holds one explicit job per platform (`build-linux`, `build-macos`,
`build-windows`) — deliberately no matrix, since package management, configure
flags and verification differ too much per platform.

**Triggering a release** — a tag matching `v*` starts the workflow:

    git tag v17.2-1
    git push origin v17.2-1

The workflow builds GDB from the official GNU sources, verifies the result,
and automatically attaches the archive and its checksum to the GitHub release
for that tag.

**Trial run without a release** — Actions tab → *Build GDB* → *Run workflow*.
The form offers four checkboxes, all ticked by default:

- `with_python` — build the variant without Python scripting when unticked.
  Applies to linux and macOS only; Windows never builds with Python
- `build_linux` / `build_macos` / `build_windows` — which platforms to build,
  so a trial run can be limited to the job you are working on

The platform checkboxes only affect a manual start. A tag push always builds
all three. The result is kept for 30 days as a workflow artifact, without
creating a release.

The GDB version is maintained in the workflow's `env` block (`GDB_VERSION`,
`GDB_SHA256`).

### Linux: why an ubuntu:20.04 container

The job runs on `ubuntu-latest` but builds inside an `ubuntu:20.04` container.
The reason is the binding to the host system's libraries: their binary
compatibility only holds upwards. An artifact produced on a newer distribution
would not start on the VM image used in teaching (Ubuntu 20.04) — conversely,
an artifact produced here also runs on newer systems. This affects `glibc`
(2.31 at most) and — with scripting enabled — `libpython` (3.8).

### macOS: why `--target=m68k-elf` is mandatory

The job runs on `macos-14` (Apple Silicon). A *native* GDB build fails there:
the top-level configure moves `gdb` into `noconfigdirs` when host and target
are identical, because native debugging is unsupported on arm64 Darwin. Passing
`--target=m68k-elf` makes host and target differ and keeps `gdb` in the build
plan — and m68k is the architecture the SvNR needs anyway. The
*Check that GDB is part of the build plan* step exists to catch exactly this
failure mode before `make` runs.

Two consequences of the cross build:

- the binary is installed as `m68k-elf-gdb`; the workflow renames it to
  `bin/gdb-multiarch-py` (or `bin/gdb-multiarch` without Python scripting),
  the same name every platform ships
- after `strip` the binary is ad-hoc signed (`codesign --force --sign -`),
  otherwise Gatekeeper blocks it on other machines

`gmp` and `mpfr` come from Homebrew and are passed to configure explicitly via
`--with-gmp` / `--with-mpfr`, so the freshly linked binary references
`/opt/homebrew/...` at runtime. The *Relocate bundle* step removes that
dependency:

1. every Homebrew dylib the binary needs is copied into `lib/` — transitively,
   so libraries pulled in by other libraries are caught as well. The list is
   discovered from the binary rather than hardcoded, so it follows whatever
   configure actually linked
2. for the `-py` variant, `Python.framework` is copied into `Frameworks/`
3. all absolute Homebrew paths are rewritten to `@loader_path`-relative
   references via `install_name_tool`, and each dylib's own ID is pointed at
   `@rpath`
4. everything is re-signed ad hoc, because `install_name_tool` invalidates
   signatures — and without a signature Gatekeeper blocks the binary on other
   machines

The *Portability check* step afterwards is a hard gate: a remaining
`/opt/homebrew` reference in the binary fails the build.

### Windows: MSYS2 and static linking

The job runs on `windows-latest` and builds in the MSYS2 UCRT64 environment
(`msys2/setup-msys2@v2`); all run steps go through `shell: 'msys2 {0}'`, set
once via the job's `defaults`. Dependencies come from pacman
(`mingw-w64-ucrt-x86_64-{gcc,gmp,mpfr,expat,ncurses,zlib}` plus `make` and
`texinfo`).

Native debugging is supported on x86_64 Windows, so unlike macOS no `--target`
detour is needed — m68k comes from `--enable-targets=all`. The binary is
`bin/gdb-multiarch.exe`. `LDFLAGS="-static"` is passed but does not reach the
final link of gdb, so the binary keeps importing the UCRT64 libraries
(`libexpat-1`, `libgmp-10`, `libmpfr-6`, `libncursesw6`, `libiconv-2`, `zlib1`,
`libstdc++-6`, `libgcc_s_seh-1`, `libwinpthread-1`). The *Bundle mingw DLLs*
step therefore copies them next to the binary — transitively, discovered from
the image rather than hardcoded — which works because Windows searches the
directory of the executable before the system ones. This mirrors what the macOS
job does with its Homebrew dylibs.

Dependencies are inspected with `objdump -p | grep "DLL Name"` rather than
`ldd`, which under MSYS2 reports the MSYS view instead of the PE imports. The
*Portability check* is a hard gate: every imported DLL that exists under
`/ucrt64/bin` must also sit in `bin/`. It used to be a mere warning, and that
is how v0.3.1 shipped a binary that could not start without MSYS2 while CI
stayed green. No code signing and no glibc check apply here.

### Python scripting

This applies to linux and macOS. Windows is deliberately built without
Python: the mingw interpreter cannot be linked statically, so the `-py`
variant would drag a `libpython` DLL onto the target machine and defeat the
`-static` linking that makes the Windows artifact self-contained.

By default the build embeds the interpreter (`WITH_PYTHON: 'true'`),
recognizable by the `-py` suffix in the asset name. Only this variant can run
GDB Python scripts, such as the RAM commands from the preliminary work. The
price is a dynamic dependency on exactly `libpython3.8` — matching the VM
image, but not arbitrary systems; the standard library is not included in the
bundle. The variant without Python (asset without the suffix) is leaner and
sufficient as long as the data is displayed in the user interface.

### Automated checks

The workflow aborts if any of these conditions is violated:

- the SHA256 of the source tarball matches `GDB_SHA256`
- `gdb` is present as a build target in the generated Makefile
- expat is active (`--with-expat` in `gdb --configuration`)
- m68k appears in the architecture list (the SvNR's host architecture)
- the embedded Python interpreter is actually operational (linux and macOS)
- on macOS, the binary contains no `/opt/homebrew` reference after relocation
- on Windows, every imported mingw DLL is bundled next to the binary

On Linux it additionally logs `ldd` and the highest referenced GLIBC symbol
version, so the 2.31 limit can be traced in the log. On macOS the equivalent is
`otool -L`; there is no glibc counterpart to check.

## Origin and license

All three artifacts are based on GDB 17.2 and are built in CI directly from the
official sources of the Free Software Foundation. On macOS, `gmp`, `mpfr` and
Python come from [Homebrew](https://brew.sh) and are bundled into the artifact
by the relocation step. The underlying GDB sources are available from the Free
Software Foundation:

    https://ftp.gnu.org/gnu/gdb/gdb-17.2.tar.xz

GDB is licensed under the **GPLv3**. This redistribution complies with that
license; the sources are publicly accessible via the link above. See `LICENSE`
for the full license text.

## Verifying the binary

These checks run automatically in the workflow (see *Automated checks*). To
repeat them by hand on a downloaded macOS bundle:

1. **Portable**: `otool -L bin/gdb-multiarch-py` shows only `@loader_path/...`,
   `/usr/lib/...` and `/System/...` references. No `/opt/homebrew/...` paths.
2. **Multiarch**: `bin/gdb-multiarch-py --batch -ex 'set architecture' 2>&1 | grep m68k`
   returns a hit (m68k is the SvNR's host architecture).
3. **Functional**: `bin/gdb-multiarch-py --version` prints "GNU gdb (GDB) 17.2".

## Plugin integration

In `oneware-extension.json`, the SvNR debugger plugin points at the release
URL of the current asset and checks its SHA256 sum.

## Shipped bundle

macOS, after the relocation step (self-contained):

    bin/gdb-multiarch-py     # the actual binary (stripped, ad-hoc signed)
    lib/                     # rewritten dylibs (mpfr, gmp, ...)
    Frameworks/              # Python.framework (for Dolata's m/M scripts)
    share/, include/         # data files from the install prefix

Linux and Windows (plain install prefix):

    bin/gdb-multiarch-py     # the actual binary (stripped)
    share/, include/         # data files from the install prefix

The archives are flat: they unpack to `bin/`, `share/` and so on, without a
platform-named directory in between. On Windows the binary is
`bin/gdb-multiarch.exe`. It stays under `bin/` on purpose — GDB derives its
data directory from the location of its own executable as `../share/gdb`, and
a binary moved to the archive root would look for it one level too high, which
breaks Python scripting.

The exact layout is whatever `make install` puts under the prefix; the
*Diagnostics after make* step prints it into the workflow log.

Usage: extract the bundle anywhere and run the binary under `bin/`.
Remaining runtime
dependencies per platform:

- **macOS**: none. Homebrew dylibs and, in the `-py` variant, the Python
  framework travel inside the bundle
- **Linux**: the target system's `glibc` (≤ 2.31 required at build time) and,
  for the `-py` variant, `libpython3.8`
- **Windows**: nothing beyond the system DLLs thanks to `-static` — there is
  no `-py` variant here, so no mingw Python DLL either
