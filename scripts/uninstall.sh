#!/usr/bin/env bash
# Remove a Letter build installed by scripts/install.sh (or meson install).
# Uninstalls files under the prefix, then deletes this source tree (including a
# clone under ~/.cache/letter/src left by install.sh).
set -euo pipefail

PREFIX="${LETTER_PREFIX:-/usr/local}"
BUILD_DIR="_build"
PURGE_DATA=0

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'uninstall.sh: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sudo_run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif need_cmd sudo; then
    sudo "$@"
  else
    die "need root to run: $*"
  fi
}

script_dir() {
  local source="${BASH_SOURCE[0]:-}"
  if [ -n "$source" ] && [ -f "$source" ]; then
    cd "$(dirname "$source")" && pwd
  else
    pwd
  fi
}

find_source_root() {
  local dir
  dir="$(script_dir)"
  if [ -f "$dir/../meson.build" ]; then
    cd "$dir/.." && pwd
    return
  fi
  if [ -f "$PWD/meson.build" ]; then
    pwd
    return
  fi
  return 1
}

usage() {
  cat <<EOF
Usage: ./scripts/uninstall.sh [--purge-data]

  Removes Letter from ${PREFIX} (needs administrator rights), then deletes
  this source tree so a clone left by install.sh is gone too.

  --purge-data   also delete local Letter data and mail cache under
                 ~/.local/share/letter and ~/.cache/letter
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --purge-data)
      PURGE_DATA=1
      ;;
    *)
      die "unknown option: $arg (try --help)"
      ;;
  esac
done

root="$(find_source_root || true)"
if [ -z "${root:-}" ]; then
  die "run this from a Letter source tree (./scripts/uninstall.sh)"
fi
cd "$root"

say "Uninstalling Letter from $PREFIX…"
if [ -d "$BUILD_DIR" ] && [ -f "$BUILD_DIR/build.ninja" ]; then
  need_cmd ninja || die "ninja is required to uninstall the installed files"
  sudo_run ninja -C "$BUILD_DIR" uninstall
else
  say "No usable $BUILD_DIR here; removing common installed files under $PREFIX"
  sudo_run rm -f \
    "$PREFIX/bin/letter" \
    "$PREFIX/share/applications/io.github.stalvatero.Letter.desktop" \
    "$PREFIX/share/metainfo/io.github.stalvatero.Letter.metainfo.xml" \
    "$PREFIX/share/glib-2.0/schemas/io.github.stalvatero.Letter.gschema.xml" \
    "$PREFIX/share/glib-2.0/schemas/io.github.stalvatero.Mail.gschema.xml" \
    "$PREFIX/share/icons/hicolor/scalable/apps/io.github.stalvatero.Letter.svg" \
    "$PREFIX/share/icons/hicolor/symbolic/apps/io.github.stalvatero.Letter-symbolic.svg"
  sudo_run rm -rf "$PREFIX/share/letter"
  # Translations and any leftover schema compile artifacts.
  sudo_run find "$PREFIX/share/locale" -name 'letter.mo' -delete 2>/dev/null || true
  if need_cmd glib-compile-schemas && [ -d "$PREFIX/share/glib-2.0/schemas" ]; then
    sudo_run glib-compile-schemas "$PREFIX/share/glib-2.0/schemas" 2>/dev/null || true
  fi
  if need_cmd update-desktop-database && [ -d "$PREFIX/share/applications" ]; then
    sudo_run update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
  fi
  if need_cmd gtk-update-icon-cache && [ -d "$PREFIX/share/icons/hicolor" ]; then
    sudo_run gtk-update-icon-cache -f "$PREFIX/share/icons/hicolor" 2>/dev/null || true
  fi
fi

if [ "$PURGE_DATA" -eq 1 ]; then
  say "Removing local Letter data and cache…"
  rm -rf \
    "${XDG_DATA_HOME:-$HOME/.local/share}/letter" \
    "${XDG_CACHE_HOME:-$HOME/.cache}/letter"
else
  say "Keeping local mail cache (pass --purge-data to delete it too)."
fi

say
say "Letter has been uninstalled from $PREFIX."
if [ "$PURGE_DATA" -eq 1 ]; then
  say "Local Letter data and cache were deleted."
else
  say "Online Accounts were left unchanged (Settings → Online Accounts)."
fi

say
say "This will delete the source tree:"
say "  $root"
printf 'Continue? [y/N] '
read -r answer
case "$answer" in
  y|Y|yes|YES) ;;
  *)
    say "Stopped. Installed files are already removed; source tree kept."
    exit 0
    ;;
esac

say "Deleting source tree…"

# Delete after this process exits so the script can finish while living in $root.
root_to_remove="$root"
(
  sleep 1
  rm -rf "$root_to_remove"
  parent="$(dirname "$root_to_remove")"
  if [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null || true)" ]; then
    rmdir "$parent" 2>/dev/null || true
  fi
) >/dev/null 2>&1 &
disown $! 2>/dev/null || true
