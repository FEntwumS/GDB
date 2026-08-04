# FEntwumS GDB

Portable GDB distribution for the **SvNR debugger**, built as part of the
[FEntwumS](https://www.th-koeln.de/informations-medien-und-elektrotechnik/forschungsprojekt-fentwums_112124.php)
project.

What ships is a relocated, self-contained GDB binary that the
[OneWare Studio Extension Manager](https://oneware.io) downloads and the
SvNR debugger plugin uses.

## Current artifacts

| Platform     | Version | Release asset               | Produced by             |
|--------------|---------|-----------------------------|-------------------------|
| linux-x64    | 17.2    | `gdb-linux-x64-py.tar.gz`   | CI (GitHub Actions)     |
| macOS ARM64  | 17.2    | `gdb-macos-arm64-py.tar.gz` | CI (GitHub Actions)     |
| windows-x64  | 17.2    | `gdb-windows-x64-py.tar.gz` | CI (GitHub Actions)     |

Every archive comes with a `.sha256` file holding its checksum. All three are
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

**Trial run without a release** — Actions tab → *Build GDB* →
*Run workflow*. The `with_python` switch there also allows building the
variant without Python scripting. The result is kept for 30 days as a
workflow artifact, without creating a release.

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
  `bin/gdb`, which is what the plugin expects
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
`/opt/homebrew` reference in `bin/gdb` fails the build.

### Windows: MSYS2 and static linking

The job runs on `windows-latest` and builds in the MSYS2 UCRT64 environment
(`msys2/setup-msys2@v2`); all run steps go through `shell: 'msys2 {0}'`, set
once via the job's `defaults`. Dependencies come from pacman
(`mingw-w64-ucrt-x86_64-{gcc,gmp,mpfr,expat,ncurses,zlib}` plus `make` and
`texinfo`).

Native debugging is supported on x86_64 Windows, so unlike macOS no `--target`
detour is needed — m68k comes from `--enable-targets=all`. The binary is
`bin/gdb.exe`, and `LDFLAGS="-static"` keeps the mingw runtime DLLs
(`libstdc++-6`, `libgcc_s_seh-1`, `libwinpthread-1`) out of the image.
Dependencies are inspected with `objdump -p | grep "DLL Name"` rather than
`ldd`, which under MSYS2 reports the MSYS view instead of the PE imports. No
code signing and no glibc check apply here.

### Python scripting

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
- the embedded Python interpreter is actually operational
- on macOS, `bin/gdb` contains no `/opt/homebrew` reference after relocation

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

1. **Portable**: `otool -L bin/gdb` shows only `@loader_path/...`,
   `/usr/lib/...` and `/System/...` references. No `/opt/homebrew/...` paths.
2. **Multiarch**: `bin/gdb --batch -ex 'set architecture' 2>&1 | grep m68k`
   returns a hit (m68k is the SvNR's host architecture).
3. **Functional**: `bin/gdb --version` prints "GNU gdb (GDB) 17.2".

## Plugin integration

In `oneware-extension.json`, the SvNR debugger plugin points at the release
URL of the current asset and checks its SHA256 sum.

## Shipped bundle

macOS, after the relocation step (self-contained):

    gdb-macos-arm64-py/
    ├── bin/gdb              # the actual binary (stripped, ad-hoc signed)
    ├── lib/                 # rewritten dylibs (mpfr, gmp, ...)
    ├── Frameworks/          # Python.framework (for Dolata's m/M scripts)
    └── share/, include/     # data files from the install prefix

Linux and Windows (plain install prefix):

    gdb-linux-x64-py/
    ├── bin/gdb              # the actual binary (stripped; gdb.exe on Windows)
    └── share/, include/     # data files from the install prefix

The exact layout is whatever `make install` puts under the prefix; the
*Diagnostics after make* step prints it into the workflow log.

Usage: extract the bundle anywhere and run `bin/gdb`. Remaining runtime
dependencies per platform:

- **macOS**: none. Homebrew dylibs and, in the `-py` variant, the Python
  framework travel inside the bundle
- **Linux**: the target system's `glibc` (≤ 2.31 required at build time) and,
  for the `-py` variant, `libpython3.8`
- **Windows**: nothing beyond the system DLLs thanks to `-static`, except the
  mingw Python DLL in the `-py` variant
