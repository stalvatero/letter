#!/usr/bin/env bash
# Build a Letter Flatpak bundle for the release candidate / local testing
# (not Flathub). By default does NOT install into the user Flatpak store, so
# it will not replace a /usr/local source install in the app drawer (same app-id).
#
# Requires: flatpak, flatpak-builder, network (Flathub + GNOME sources).
#
# Usage:
#   ./scripts/build-flatpak.sh              # build repo + .flatpak only
#   FLATPAK_INSTALL=1 ./scripts/build-flatpak.sh   # also install --user
#   FLATPAK_BUNDLE=Letter-1.0.0-rc.5-x86_64.flatpak ./scripts/build-flatpak.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

manifest=io.github.stalvatero.Letter.yml
build_dir="${FLATPAK_BUILD_DIR:-build-flatpak}"
repo_dir="${FLATPAK_REPO_DIR:-repo}"
# Prefer meson version for Release asset names (Letter-1.0.0-rc.N-…, no leading "v").
project_ver="$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([^']*\)'.*/\1/p" meson.build | head -1)"
bundle="${FLATPAK_BUNDLE:-Letter-${project_ver:-1.0.0}-x86_64.flatpak}"
do_install="${FLATPAK_INSTALL:-0}"

if ! command -v flatpak-builder >/dev/null; then
  echo "flatpak-builder is required (e.g. dnf install flatpak-builder)." >&2
  exit 1
fi

flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y --user flathub org.gnome.Platform//50 org.gnome.Sdk//50

echo "Building $manifest (first run downloads EDS/GOA and can take a while)…"
# dir source copies the tree; leftover Meson/flatpak dirs break the letter module.
rm -rf "$root/_flatpak_build" "$root/build-flatpak"
# Ensure icon validation has a real home (bwrap + rofiles can otherwise fail).
export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

builder_args=(
  --force-clean
  --user
  --disable-rofiles-fuse
  --repo="$repo_dir"
)
if [ "$do_install" = "1" ]; then
  builder_args+=(--install)
fi

flatpak-builder \
  "${builder_args[@]}" \
  "$build_dir" \
  "$manifest"

echo
flatpak build-bundle "$repo_dir" "$bundle" io.github.stalvatero.Letter
echo "Bundle: $root/$bundle"
echo
echo "Copy that file to another machine (or a VM), then:"
echo "  flatpak install --user ./$(basename "$bundle")"
echo "  flatpak run io.github.stalvatero.Letter"
if [ "$do_install" = "1" ]; then
  echo
  echo "Also installed for this user. Note: same app-id as a /usr/local install,"
  echo "so the app drawer may prefer Flatpak. Uninstall with:"
  echo "  flatpak uninstall --user io.github.stalvatero.Letter"
else
  echo
  echo "Not installed locally (source install / drawer unchanged)."
  echo "To install on this machine as well: FLATPAK_INSTALL=1 $0"
fi
echo
echo "Notes for this Flatpak:"
echo "  - Run: flatpak run io.github.stalvatero.Letter  (no --env needed)."
echo "  - LETTER_MS_CLIENT_ID + LETTER_MS_MAIL=graph are baked in finish-args."
echo "  - GOA remains optional (Preferences); LETTER_SKIP_GOA is not forced."
echo "  - Not published to Flathub yet."
