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
| macOS ARM64  | 17.2    | `gdb-macos-arm64.tar.gz`    | locally (`build-gdb.sh`)|

Every archive comes with a `.sha256` file holding its checksum. Windows x64
will be added as a further CI job in the same fashion.

## Release process

Linux binaries are no longer produced on a developer machine but in CI. The
authoritative definition is the workflow `.github/workflows/build-gdb.yml`.

**Triggering a release** — a tag matching `v*` starts the workflow:

    git tag v17.2-1
    git push origin v17.2-1

The workflow builds GDB from the official GNU sources, verifies the result,
and automatically attaches the archive and its checksum to the GitHub release
for that tag.

**Trial run without a release** — Actions tab → *Build GDB for linux-x64* →
*Run workflow*. The `with_python` switch there also allows building the
variant without Python scripting. The result is kept for 30 days as a
workflow artifact, without creating a release.

The GDB version is maintained in the workflow's `env` block (`GDB_VERSION`,
`GDB_SHA256`).

### Why an ubuntu:20.04 container

The job runs on `ubuntu-latest` but builds inside an `ubuntu:20.04` container.
The reason is the binding to the host system's libraries: their binary
compatibility only holds upwards. An artifact produced on a newer distribution
would not start on the VM image used in teaching (Ubuntu 20.04) — conversely,
an artifact produced here also runs on newer systems. This affects `glibc`
(2.31 at most) and — with scripting enabled — `libpython` (3.8).

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

It additionally logs `ldd` and the highest referenced GLIBC symbol version, so
the 2.31 limit can be traced in the log.

## Origin and license

Both artifacts are based on GDB 17.2. The Linux binary is built in CI directly
from the official sources of the Free Software Foundation; the macOS binary is
relocated from the build distributed via
[Homebrew](https://github.com/Homebrew/homebrew-core/blob/master/Formula/g/gdb.rb).
The underlying sources are available from the Free Software Foundation:

    https://ftp.gnu.org/gnu/gdb/gdb-17.2.tar.xz

GDB is licensed under the **GPLv3**. This redistribution complies with that
license; the sources are publicly accessible via the link above. See `LICENSE`
for the full license text.

## Local build (macOS ARM64)

There is no CI job for macOS yet, so this artifact is produced with
`build-gdb.sh` on an Apple Silicon Mac. The script turns an existing Homebrew
GDB installation into a portable bundle: it copies the binary along with its
dependencies, rewrites all absolute Homebrew paths to `@executable_path`- and
`@loader_path`-relative references, and re-signs the result ad hoc.

Prerequisites:

- macOS on Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools
- Homebrew with `gdb` installed (`brew install gdb`)

Execution:

    ./build-gdb.sh all

The result lands in `~/dev/gdb-macos-arm64/`. Packaging it as a release
artifact:

    cd ~/dev
    tar --exclude='.DS_Store' -czf gdb-macos-arm64.tar.gz gdb-macos-arm64
    shasum -a 256 gdb-macos-arm64.tar.gz > gdb-macos-arm64.tar.gz.sha256

## Verifying the binary

For Linux these checks run automatically in the workflow (see *Automated
checks*). For the locally built macOS bundle, the resulting binary should
satisfy three properties:

1. **Portable**: `otool -L bin/gdb` shows only `@executable_path/...`,
   `/usr/lib/...` and `/System/...` references. No `/opt/homebrew/...` paths.
2. **Multiarch**: `bin/gdb --batch -ex 'set architecture' 2>&1 | grep m68k`
   returns a hit (m68k is the SvNR's host architecture).
3. **Functional**: `bin/gdb --version` prints "GNU gdb (GDB) 17.2".

## Plugin integration

In `oneware-extension.json`, the SvNR debugger plugin points at the release
URL of the current asset and checks its SHA256 sum.

## Shipped bundle

macOS:

    gdb-macos-arm64/
    ├── bin/gdb              # the actual binary
    ├── lib/                 # rewritten dylibs (readline, mpfr, gmp, ...)
    └── Frameworks/          # Python.framework (for Dolata's m/M scripts)

Linux:

    gdb-linux-x64-py/
    ├── bin/gdb              # the actual binary (stripped)
    └── share/, include/     # data files from the install prefix

The exact Linux layout is whatever `make install` puts under the prefix; the
*Diagnostics after make* step prints it into the workflow log.

Usage: extract the bundle anywhere and run `bin/gdb`. On macOS no Homebrew, no
Python and no further prerequisites are needed on the target system. The Linux
build relies on the target system's `glibc` (≤ 2.31 required at build time)
and, for the `-py` variant, on `libpython3.8`.
