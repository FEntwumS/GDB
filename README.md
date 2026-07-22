# FEntwumS GDB

Portable GDB-Distribution für den **SvNR-Debugger** im Rahmen des Projekts
[FEntwumS](https://www.th-koeln.de/informations-medien-und-elektrotechnik/forschungsprojekt-fentwums_112124.php).

Ausgeliefert wird eine relokierte, plattformunabhängige GDB-Binary, die vom
[OneWare Studio Extension Manager](https://oneware.io) heruntergeladen und
vom SvNR-Debugger-Plugin verwendet wird.

## Aktuelles Artefakt

| Plattform    | Version | Release-Asset                    |
|--------------|---------|----------------------------------|
| macOS ARM64  | 17.2    | `gdb-macos-arm64.tar.gz`         |

Weitere Plattformen (Windows x64, Linux x64) werden analog ergänzt.

## Herkunft und Lizenz

Die Binary basiert auf dem GDB 17.2, wie er über
[Homebrew](https://github.com/Homebrew/homebrew-core/blob/master/Formula/g/gdb.rb)
verteilt wird. Die zugrundeliegenden Quellen sind bei der Free Software
Foundation verfügbar:

    https://ftp.gnu.org/gnu/gdb/gdb-17.2.tar.xz

GDB steht unter der **GPLv3**. Diese Weitergabe erfolgt konform zur Lizenz;
die Quellen sind über den obigen Link öffentlich zugänglich. Siehe
`LICENSE` für den vollständigen Lizenztext.

## Reproduzierbarkeit

Das Skript `build-gdb.sh` erzeugt aus einer bestehenden Homebrew-GDB-Installation
ein portables Bundle: es kopiert die Binary samt Abhängigkeiten, schreibt alle
absoluten Homebrew-Pfade auf `@executable_path`- bzw. `@loader_path`-relative
Referenzen um und signiert das Ergebnis ad-hoc neu.

Voraussetzungen:

- macOS auf Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools
- Homebrew mit installiertem `gdb` (`brew install gdb`)

Ausführung:

    ./build-gdb.sh all

Ergebnis unter `~/dev/gdb-macos-arm64/`. Verpackung zum Release-Artefakt:

    cd ~/dev
    tar --exclude='.DS_Store' -czf gdb-macos-arm64.tar.gz gdb-macos-arm64
    shasum -a 256 gdb-macos-arm64.tar.gz > gdb-macos-arm64.tar.gz.sha256

## Verifikation der Binary

Die entstandene Binary sollte drei Eigenschaften erfüllen:

1. **Portabel**: `otool -L bin/gdb` zeigt ausschließlich `@executable_path/...`,
   `/usr/lib/...` und `/System/...`-Referenzen. Keine `/opt/homebrew/...`-Pfade.
2. **Multiarch**: `bin/gdb --batch -ex 'set architecture' 2>&1 | grep m68k`
   liefert einen Treffer (m68k ist die Trägerarchitektur des SvNR).
3. **Funktionsfähig**: `bin/gdb --version` gibt "GNU gdb (GDB) 17.2" aus.

## Integration im Plugin

Das SvNR-Debugger-Plugin verweist im `oneware-extension.json` auf die
Release-URL des aktuellen Assets und prüft die SHA256-Summe.

## Ausgeliefertes Bundle

    gdb-macos-arm64/
    ├── bin/gdb              # eigentliche Binary
    ├── lib/                 # umgeschriebene dylibs (readline, mpfr, gmp, ...)
    └── Frameworks/          # Python.framework (für Dolatas m/M-Skripte)

Nutzung: Bundle irgendwo entpacken, `bin/gdb` starten. Kein Homebrew,
kein Python, keine weiteren Voraussetzungen auf dem Zielsystem.
