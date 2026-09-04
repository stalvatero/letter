#!/usr/bin/env bash
# Install Letter from source for GNOME 50+.
# Run from a clone, or let the script clone the public repository.
#
# This path compiles Letter on your machine. Package managers will pull
# compilers and -devel/-dev headers (normal for any from-source build).
# A Flatpak or distro package, when available, is the lighter choice for
# everyday users who do not want a build toolchain.
set -euo pipefail

REPO_URL="${LETTER_REPO_URL:-https://github.com/stalvatero/letter.git}"
PREFIX="${LETTER_PREFIX:-/usr/local}"
BUILD_DIR="_build"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

say() {
  printf '%s\n' "$*"
}

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
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

clone_source() {
  need_cmd git || die "git is required to download Letter"
  local dest="${LETTER_SRC:-${XDG_CACHE_HOME:-$HOME/.cache}/letter/src}"
  mkdir -p "$(dirname "$dest")"
  if [ -d "$dest/.git" ]; then
    say "Updating $dest"
    git -C "$dest" fetch --depth 1 origin
    git -C "$dest" reset --hard origin/HEAD 2>/dev/null || git -C "$dest" pull --ff-only
  else
    say "Cloning $REPO_URL into $dest"
    rm -rf "$dest"
    git clone --depth 1 "$REPO_URL" "$dest"
  fi
  cd "$dest" && pwd
}

detect_pm() {
  if need_cmd pacman; then
    echo pacman
  elif need_cmd zypper; then
    echo zypper
  elif need_cmd dnf; then
    echo dnf
  elif need_cmd apt-get; then
    echo apt
  else
    echo unknown
  fi
}

try_packages() {
  sudo_run "$@" || say "Skipping optional packages that are not available on this system."
}

explain_build_deps() {
  say
  say "Letter is built from source on this machine."
  say "That needs a compiler and development headers (-devel / -dev packages)."
  say "GNOME itself is already there; these extras are only for compiling Letter."
  say "Optional packages (Microsoft 365 helper, Sushi preview, spell check) come next if available."
  say
}

install_packages() {
  local pm="$1"
  explain_build_deps
  say "Installing build packages with $pm…"
  case "$pm" in
    pacman)
      sudo_run pacman -S --needed --noconfirm \
        git meson ninja vala blueprint-compiler pkgconf gcc \
        gtk4 libadwaita gdk-pixbuf2 \
        evolution-data-server gnome-online-accounts \
        webkitgtk-6.0 gsound gettext appstream desktop-file-utils
      try_packages pacman -S --needed --noconfirm \
        evolution-ews sushi hunspell hunspell-en_us
      ;;
    zypper)
      # openSUSE Tumbleweed / Leap 16+: webkitgtk4-devel provides webkitgtk-6.0.pc
      sudo_run zypper --non-interactive install --no-recommends \
        git meson ninja vala blueprint-compiler pkgconf-pkg-config gcc \
        gtk4-devel libadwaita-devel gdk-pixbuf-devel \
        evolution-data-server-devel gnome-online-accounts-devel \
        webkitgtk4-devel libgsound-devel libical-devel \
        gettext-tools AppStream desktop-file-utils
      try_packages zypper --non-interactive install --no-recommends \
        evolution-ews sushi hunspell hunspell-en
      ;;
    dnf)
      # Fedora splits libraries from headers: *-devel is required to compile.
      sudo_run dnf install -y \
        git meson ninja-build vala blueprint-compiler pkgconf-pkg-config gcc \
        gtk4-devel libadwaita-devel gdk-pixbuf2-devel \
        evolution-data-server-devel gnome-online-accounts-devel \
        webkitgtk6.0-devel gsound-devel gettext appstream desktop-file-utils
      try_packages dnf install -y evolution-ews sushi hunspell hunspell-en
      ;;
    apt)
      sudo_run apt-get update
      # Debian/Ubuntu package names: libecal2.0-dev (not libecal-2.0-dev);
      # libical-dev ships the libical-glib.pc Meson looks for.
      sudo_run apt-get install -y \
        git meson ninja-build valac blueprint-compiler pkg-config gcc \
        libgtk-4-dev libadwaita-1-dev libgdk-pixbuf-2.0-dev \
        libcamel1.2-dev libedataserver1.2-dev libedataserverui4-dev \
        libebook1.2-dev libecal2.0-dev libical-dev \
        libgoa-1.0-dev libwebkitgtk-6.0-dev libgsound-dev \
        gettext appstream desktop-file-utils
      try_packages apt-get install -y evolution-ews gnome-sushi hunspell hunspell-en-us
      ;;
    *)
      die "unsupported package manager. Install Meson, Vala, GTK 4, libadwaita, Evolution Data Server, GNOME Online Accounts, WebKitGTK 6, and gsound, then rerun."
      ;;
  esac
}

root="$(find_source_root || true)"
if [ -z "${root:-}" ]; then
  root="$(clone_source)"
fi
cd "$root"

pm="$(detect_pm)"
install_packages "$pm"

need_cmd meson || die "meson is not installed"
need_cmd ninja || die "ninja is not installed"

say "Configuring Letter (profile=default, prefix=$PREFIX)"
if [ -d "$BUILD_DIR" ]; then
  meson setup "$BUILD_DIR" --prefix="$PREFIX" -Dprofile=default --reconfigure
else
  meson setup "$BUILD_DIR" --prefix="$PREFIX" -Dprofile=default
fi

say "Compiling…"
meson compile -C "$BUILD_DIR"

say "Installing to $PREFIX (needs administrator rights)"
sudo_run meson install -C "$BUILD_DIR"

say
say "Letter is installed. Open it from the app grid, or run: letter"
say "Add an email account in Settings → Online Accounts, then restart Letter."
say "To remove this build later, from this source tree run:"
say "  ./scripts/uninstall.sh"
say "Add --purge-data to delete the local mail cache as well."
