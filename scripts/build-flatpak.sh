#!/usr/bin/env bash
# Build a Letter Flatpak bundle for the release candidate / local testing
# (not Flathub). By default does NOT install into the user Flatpak store, so
# it will not replace a /usr/local source install in the app drawer (same app-id).
#
# Requires: flatpak, flatpak-builder, network (Flathub + GNOME sources).
# Google OAuth: flatpak/oauth.env (from oauth.env.example) or LETTER_GOOGLE_* in the
# environment. Microsoft client id stays in the committed manifest.
#
# Usage:
#   ./scripts/build-flatpak.sh              # build repo + .flatpak only
#   FLATPAK_INSTALL=1 ./scripts/build-flatpak.sh   # also install --user
#   FLATPAK_BUNDLE=Letter-1.0.0-rc.5-x86_64.flatpak ./scripts/build-flatpak.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

manifest_src=io.github.stalvatero.Letter.yml
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

load_google_oauth () {
  if [[ -n "${LETTER_GOOGLE_CLIENT_ID:-}" && -n "${LETTER_GOOGLE_CLIENT_SECRET:-}" ]]; then
    return 0
  fi
  local env_file="$root/flatpak/oauth.env"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    set -a
    # Only assign KEY=VALUE lines; ignore comments / blanks.
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
      fi
    done < "$env_file"
    set +a
  fi
  if [[ -z "${LETTER_GOOGLE_CLIENT_ID:-}" || -z "${LETTER_GOOGLE_CLIENT_SECRET:-}" ]]; then
    echo "Missing Google OAuth for the Flatpak build." >&2
    echo "  cp flatpak/oauth.env.example flatpak/oauth.env" >&2
    echo "  # then set LETTER_GOOGLE_CLIENT_ID and LETTER_GOOGLE_CLIENT_SECRET" >&2
    echo "  # or export those two variables before running this script." >&2
    exit 1
  fi
}

write_generated_manifest () {
  local out="$1"
  local marker="  - --env=LETTER_MS_MAIL=graph"
  if ! grep -qxF "$marker" "$manifest_src"; then
    echo "Manifest marker not found (LETTER_MS_MAIL=graph). Update scripts/build-flatpak.sh." >&2
    exit 1
  fi
  awk -v id="$LETTER_GOOGLE_CLIENT_ID" -v secret="$LETTER_GOOGLE_CLIENT_SECRET" -v marker="$marker" '
    $0 == marker {
      print
      print "  - --env=LETTER_GOOGLE_CLIENT_ID=" id
      print "  - --env=LETTER_GOOGLE_CLIENT_SECRET=" secret
      next
    }
    { print }
  ' "$manifest_src" > "$out"
}

load_google_oauth
manifest_gen="$root/_flatpak_manifest.generated.yml"
write_generated_manifest "$manifest_gen"
trap 'rm -f "$manifest_gen"' EXIT

flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y --user flathub org.gnome.Platform//50 org.gnome.Sdk//50

echo "Building Flatpak (Google OAuth injected at build time; not committed)…"
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
  "$manifest_gen"

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
echo "  - Run: flatpak run io.github.stalvatero.Letter  (no --env needed on the installed bundle)."
echo "  - Google OAuth came from flatpak/oauth.env or LETTER_GOOGLE_* at build time."
echo "  - LETTER_MS_CLIENT_ID + LETTER_MS_MAIL=graph are in the committed manifest."
echo "  - GOA remains optional (Preferences); LETTER_SKIP_GOA is not forced."
echo "  - Not published to Flathub yet."
