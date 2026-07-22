#!/bin/bash
# =============================================================================
# relocate-gdb.sh — Homebrew-GDB in portables Bundle umwandeln
#
# Kopiert /opt/homebrew/opt/gdb/bin/gdb + alle Homebrew-Abhängigkeiten nach
# ~/dev/gdb-macos-arm64/, schreibt via install_name_tool alle absoluten Homebrew-Pfade
# auf @executable_path/../lib/... um, und signiert die Binaries neu.
#
# Ergebnis: ~/dev/gdb-macos-arm64/ ist auf jeden Apple-Silicon-Mac kopierbar,
#           auch wenn dort kein Homebrew installiert ist.
#
# Aufruf:  ./relocate-gdb.sh <schritt>
# Schritte: prepare | copy | relocate | sign | verify | pack | all
# =============================================================================
set -u

BUNDLE="$HOME/dev/gdb-macos-arm64"             # Ausgabe: portables Bundle
BUNDLE_BIN="$BUNDLE/bin"
BUNDLE_LIB="$BUNDLE/lib"
BUNDLE_FW="$BUNDLE/Frameworks"

HB="/opt/homebrew"                      # Homebrew-Prefix (arm64)
GDB_SRC="$HB/opt/gdb/bin/gdb"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
info() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# -----------------------------------------------------------------------------
step_prepare() {
  info "Schritt 1: Voraussetzungen"
  [ "$(uname -sm)" = "Darwin arm64" ] \
    && ok "macOS auf Apple Silicon" \
    || fail "Erwartet: Darwin arm64 (bekommen: $(uname -sm))"

  [ -x "$GDB_SRC" ] \
    && ok "Homebrew-GDB gefunden: $GDB_SRC" \
    || fail "Kein GDB unter $GDB_SRC — brew install gdb"

  [ -d "$HB/opt/python@3.14/Frameworks/Python.framework" ] \
    && ok "Python.framework gefunden" \
    || fail "Kein Python-Framework unter $HB/opt/python@3.14"

  rm -rf "$BUNDLE"
  mkdir -p "$BUNDLE_BIN" "$BUNDLE_LIB" "$BUNDLE_FW"
  ok "Zielverzeichnis $BUNDLE geleert und angelegt"
}

# -----------------------------------------------------------------------------
step_copy() {
  info "Schritt 2: Binary + Abhängigkeiten kopieren"

  cp "$GDB_SRC" "$BUNDLE_BIN/gdb"
  chmod u+w "$BUNDLE_BIN/gdb"
  ok "gdb -> $BUNDLE_BIN/gdb"

  # Homebrew-Dylibs (nicht die System-Pfade)
  # Wir kopieren die konkreten Zieldateien der Symlinks, damit später
  # install_name_tool eindeutige Pfade hat.
  for src in \
      "$HB/opt/readline/lib/libreadline.8.dylib" \
      "$HB/opt/zstd/lib/libzstd.1.dylib" \
      "$HB/opt/ncurses/lib/libncursesw.6.dylib" \
      "$HB/opt/xz/lib/liblzma.5.dylib" \
      "$HB/opt/mpfr/lib/libmpfr.6.dylib" \
      "$HB/opt/gmp/lib/libgmp.10.dylib"
  do
    [ -f "$src" ] || fail "Nicht gefunden: $src"
    # -L folgt Symlinks und kopiert die reale Datei
    cp -L "$src" "$BUNDLE_LIB/"
    chmod u+w "$BUNDLE_LIB/$(basename "$src")"
  done
  ok "6 Homebrew-Dylibs -> $BUNDLE_LIB/"

  # Python-Framework als Ganzes -- GDB linkt gegen den Framework-Pfad,
  # den lassen wir intakt und relozieren nur die Referenz darauf.
  # -R (rekursiv) plus -L (Symlinks auflösen) für Framework-Struktur.
  cp -RL "$HB/opt/python@3.14/Frameworks/Python.framework" "$BUNDLE_FW/"
  ok "Python.framework -> $BUNDLE_FW/"

  # mpfr braucht libgmp, gmp ist eigenständig -- die transitive Kette
  # (readline -> ncurses etc.) prüfen wir im relocate-Schritt.
}

# -----------------------------------------------------------------------------
# Ersetzt in einer Ziel-Binary/-Dylib jeden Verweis auf einen Homebrew-Pfad
# durch @loader_path- bzw. @executable_path-relative Referenzen.
_relocate_one() {
  local target="$1"
  local kind="$2"           # "bin" oder "lib"
  local rel_prefix

  if [ "$kind" = "bin" ]; then
    rel_prefix='@executable_path/../lib'
    # ID der Binary muss nicht gesetzt sein
  else
    rel_prefix='@loader_path'
    # Eigene ID auf @rpath umbiegen, damit sie unter beliebigem Pfad läuft
    install_name_tool -id "@rpath/$(basename "$target")" "$target" 2>/dev/null || true
  fi

  # Alle Homebrew-Referenzen ("/opt/homebrew/...") auf relativ umschreiben
  otool -L "$target" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      /opt/homebrew/opt/python@3.14/Frameworks/Python.framework/*)
        # GDB verweist auf .../Versions/3.14/Python -- Suffix beibehalten
        suffix="${dep#/opt/homebrew/opt/python@3.14/Frameworks/}"
        if [ "$kind" = "bin" ]; then
          new="@executable_path/../Frameworks/$suffix"
        else
          new="@loader_path/../Frameworks/$suffix"
        fi
        install_name_tool -change "$dep" "$new" "$target"
        ;;
      /opt/homebrew/*.dylib|/opt/homebrew/*/*.dylib|/opt/homebrew/*/*/*.dylib|/opt/homebrew/*/*/*/*.dylib|/opt/homebrew/*/*/*/*/*.dylib|/opt/homebrew/*/*/*/*/*/*.dylib)
        new="$rel_prefix/$(basename "$dep")"
        install_name_tool -change "$dep" "$new" "$target"
        ;;
    esac
  done
}

step_relocate() {
  info "Schritt 3: Pfade umschreiben (install_name_tool)"

  # Erst die dylibs (die verweisen ggf. aufeinander), dann die Binary
  for lib in "$BUNDLE_LIB"/*.dylib; do
    _relocate_one "$lib" lib
    ok "reloziert: $(basename "$lib")"
  done

  _relocate_one "$BUNDLE_BIN/gdb" bin
  ok "reloziert: bin/gdb"

  # rpath in der Binary setzen, damit @rpath-IDs der libs auflösen
  install_name_tool -add_rpath "@executable_path/../lib" "$BUNDLE_BIN/gdb" 2>/dev/null || true
  ok "rpath @executable_path/../lib gesetzt"
}

# -----------------------------------------------------------------------------
step_sign() {
  info "Schritt 4: Ad-hoc-Signaturen erneuern"
  # install_name_tool zerstört bestehende Signaturen — neu signieren.
  # "-" = ad-hoc (keine Developer-ID nötig), --force = überschreiben.
  find "$BUNDLE_LIB" -name '*.dylib' -exec codesign --force --sign - {} \;
  find "$BUNDLE_FW" -type f \( -name 'Python' -o -name '*.dylib' \) \
    -exec codesign --force --sign - {} \; 2>/dev/null || true
  codesign --force --sign - "$BUNDLE_BIN/gdb"
  ok "Alle Binaries ad-hoc-signiert"
}

# -----------------------------------------------------------------------------
step_verify() {
  info "Schritt 5: Verifikation"
  G="$BUNDLE_BIN/gdb"
  [ -x "$G" ] || fail "$G existiert nicht"

  # 5.1 Portabilität: keine /opt/homebrew-Referenzen mehr in der Binary
  echo "--- otool -L $G ---"
  otool -L "$G"
  if otool -L "$G" | grep -q "/opt/homebrew"; then
    fail "Binary verweist noch auf /opt/homebrew -- Relozierung unvollständig"
  else
    ok "Keine /opt/homebrew-Verweise in der Binary"
  fi

  # 5.2 Auch in den mitgelieferten dylibs prüfen
  for lib in "$BUNDLE_LIB"/*.dylib; do
    if otool -L "$lib" | grep -q "/opt/homebrew"; then
      echo "  WARN: $(basename "$lib") verweist noch auf /opt/homebrew:"
      otool -L "$lib" | grep "/opt/homebrew" | head -n 5
    fi
  done
  ok "dylibs auf Homebrew-Verweise geprüft"

  # 5.3 Signatur gültig?
  codesign --verify "$G" 2>&1 \
    && ok "Signatur der Binary gültig" \
    || fail "codesign --verify schlug fehl"

  # 5.4 Funktioniert die Binary?
  echo "--- $G --version ---"
  "$G" --version | head -n 2 \
    && ok "Binary startet" \
    || fail "Binary lässt sich nicht ausführen -- ggf. dyld-Fehler oben"

  # 5.5 Multiarch-Check: m68k dabei?
  "$G" --batch -nx --ex 'set architecture' 2>&1 | grep -qo 'm68k' \
    && ok "m68k in der Architekturliste (Ziel: Dolatas Tarnung)" \
    || fail "m68k fehlt in der Architekturliste"

  # 5.6 SvNR-Artefakte, falls Pfade gesetzt
  if [ -n "${SVNR_ELF:-}" ] && [ -n "${SVNR_TDESC:-}" ]; then
    OUT=$("$G" -batch -nx \
      -ex "set architecture m68k" \
      -ex "file $SVNR_ELF" \
      -ex "set tdesc filename $SVNR_TDESC" 2>&1)
    echo "$OUT"
    echo "$OUT" | grep -qiE "error|not recognized" \
      && fail "GDB meldet Probleme mit ELF/tdesc" \
      || ok "ELF + Target Description akzeptiert"
  else
    echo "  INFO: SVNR_ELF/SVNR_TDESC nicht gesetzt — Artefakt-Test übersprungen"
  fi
}

# -----------------------------------------------------------------------------
step_pack() {
  info "Schritt 6: Paketieren"
  cd "$HOME/dev"
  TARBALL="svnr-gdb-relocated-darwin-arm64.tar.gz"
  tar -czf "$TARBALL" "$(basename "$BUNDLE")"
  shasum -a 256 "$TARBALL" | tee "$TARBALL.sha256"
  du -sh "$TARBALL"
  ok "Release-Artefakt: $HOME/dev/$TARBALL"
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  prepare)  step_prepare ;;
  copy)     step_copy ;;
  relocate) step_relocate ;;
  sign)     step_sign ;;
  verify)   step_verify ;;
  pack)     step_pack ;;
  all)      step_prepare; step_copy; step_relocate; step_sign; step_verify ;;
  *) echo "Aufruf: $0 {prepare|copy|relocate|sign|verify|pack|all}"; exit 1 ;;
esac