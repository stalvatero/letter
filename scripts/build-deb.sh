#!/usr/bin/env bash
# Build a native .deb of Letter for Debian/Ubuntu (internal / release use).
# Installs under /usr (not /usr/local). Requires the same build packages as
# scripts/install.sh, plus dpkg-dev.
#
# Usage:
#   ./scripts/build-deb.sh
#   DEB_OUT=Letter-1.0.0-rc.4-amd64.deb ./scripts/build-deb.sh
#   ./scripts/build-deb.sh --install   # also sudo dpkg -i the result
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

do_install=0
for arg in "$@"; do
  case "$arg" in
    --install) do_install=1 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing tool: $1" >&2
    exit 1
  }
}

need meson
need ninja
need dpkg-deb
need dpkg-shlibdeps
need dpkg-architecture

# Prefer version from meson.build (source of truth).
project_ver="$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\\([^']*\\)'.*/\\1/p" meson.build | head -1)"
if [ -z "$project_ver" ]; then
  echo "Could not read project version from meson.build" >&2
  exit 1
fi

# Debian sorts 1.0.0~rc.4 before 1.0.0. Revision: DEB_REVISION, else bump
# past the installed letter package so apt install ./….deb upgrades cleanly.
debian_upstream="$project_ver"
if [[ "$project_ver" == *-* ]]; then
  debian_upstream="${project_ver%%-*}~${project_ver#*-}"
fi
if [ -n "${DEB_REVISION:-}" ]; then
  deb_rev="$DEB_REVISION"
else
  deb_rev=1
  installed_ver="$(dpkg-query -W -f='${Version}' letter 2>/dev/null || true)"
  if [[ "$installed_ver" == "${debian_upstream}-"* ]]; then
    cur_rev="${installed_ver##*-}"
    if [[ "$cur_rev" =~ ^[0-9]+$ ]]; then
      deb_rev=$((cur_rev + 1))
    else
      deb_rev=2
    fi
  fi
fi
debian_ver="${debian_upstream}-${deb_rev}"
arch="$(dpkg-architecture -qDEB_HOST_ARCH)"
pkg_name="letter"
build_dir="${DEB_BUILD_DIR:-_build-deb}"
stage_dir="${DEB_STAGE_DIR:-build-deb/stage}"
out_dir="${DEB_OUT_DIR:-.}"
bundle="${DEB_OUT:-${out_dir}/Letter-${project_ver}-${arch}.deb}"

echo "Package version: ${debian_ver} (file $(basename "$bundle"))"

echo "Configuring $build_dir (prefix=/usr, profile=default, release)…"
if [ -d "$build_dir" ]; then
  meson setup "$build_dir" --prefix=/usr --buildtype=release -Dprofile=default --reconfigure
else
  meson setup "$build_dir" --prefix=/usr --buildtype=release -Dprofile=default
fi

echo "Compiling…"
meson compile -C "$build_dir"

echo "Staging into $stage_dir…"
rm -rf "$stage_dir"
mkdir -p "$stage_dir"
DESTDIR="$root/$stage_dir" meson install -C "$build_dir" --no-rebuild

# Drop meson post-install stamp noise if any; keep only packaged files.
find "$stage_dir" -name '*.pyc' -delete 2>/dev/null || true

bin_path="$stage_dir/usr/bin/letter"
if [ ! -x "$bin_path" ]; then
  echo "Expected binary missing: $bin_path" >&2
  exit 1
fi

# Strip for a smaller internal package (keep a .dbg-less release binary).
if command -v strip >/dev/null 2>&1; then
  strip --strip-unneeded "$bin_path" || true
fi

mkdir -p "$stage_dir/DEBIAN"

# shlibdeps needs a fake debian/control nearby when run outside a source package.
shlib_work="$(mktemp -d)"
cleanup() { rm -rf "$shlib_work"; }
trap cleanup EXIT
mkdir -p "$shlib_work/debian"
cat >"$shlib_work/debian/control" <<EOF
Source: letter
Section: mail
Priority: optional
Maintainer: Letter packaging <noreply@localhost>
Standards-Version: 4.7.0

Package: ${pkg_name}
Architecture: any
Depends: \${shlibs:Depends}
Description: Letter mail client
EOF

# Resolve runtime library Depends from the staged binary.
(
  cd "$shlib_work"
  dpkg-shlibdeps -T"$shlib_work/substvars" --ignore-missing-info \
    "$root/$bin_path"
)
shlibs_depends="$(sed -n 's/^shlibs:Depends=//p' "$shlib_work/substvars")"

# Soft runtime helpers (same idea as install.sh optional packages).
recommends="evolution-ews, gnome-sushi | sushi, hunspell"

size_kb="$(du -sk "$stage_dir" --exclude=DEBIAN | awk '{print $1}')"

cat >"$stage_dir/DEBIAN/control" <<EOF
Package: ${pkg_name}
Version: ${debian_ver}
Architecture: ${arch}
Maintainer: Letter packaging <noreply@localhost>
Section: mail
Priority: optional
Homepage: https://github.com/stalvatero/letter
Depends: ${shlibs_depends}
Recommends: ${recommends}
Installed-Size: ${size_kb}
Description: GNOME mail client (Letter)
 Letter is a GNOME mail app that uses Online Accounts and Evolution Data
 Server. This package is built for local/internal use on Debian/Ubuntu.
EOF

cat >"$stage_dir/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v glib-compile-schemas >/dev/null 2>&1; then
  glib-compile-schemas /usr/share/glib-2.0/schemas || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk4-update-icon-cache >/dev/null 2>&1; then
  gtk4-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
elif command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
exit 0
EOF

cat >"$stage_dir/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = purge ]; then
  if command -v glib-compile-schemas >/dev/null 2>&1; then
    glib-compile-schemas /usr/share/glib-2.0/schemas || true
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
  if command -v gtk4-update-icon-cache >/dev/null 2>&1; then
    gtk4-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
  elif command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
  fi
fi
exit 0
EOF

chmod 0755 "$stage_dir/DEBIAN/postinst" "$stage_dir/DEBIAN/postrm"
chmod 0644 "$stage_dir/DEBIAN/control"

# Ensure package metadata ownership is root for dpkg-deb.
if [ "$(id -u)" -eq 0 ]; then
  chown -R root:root "$stage_dir"
fi

mkdir -p "$(dirname "$bundle")"
echo "Building $bundle…"
# root-owner-group so install as user still produces a valid package.
dpkg-deb --root-owner-group --build "$stage_dir" "$bundle"

echo
echo "Package: $root/$bundle"
dpkg-deb -I "$bundle"
echo
echo "Install with (preferred — resolves Depends):"
echo "  sudo apt install ./$(basename "$bundle")"
echo "Same upstream version already installed? Use:"
echo "  sudo apt install --reinstall ./$(basename "$bundle")"
echo
echo "Remove with:"
echo "  sudo apt remove letter"

if [ "$do_install" = "1" ]; then
  echo
  echo "Installing…"
  # apt handles local .deb paths and pulls missing Depends; dpkg -i does not.
  # Local files must be passed as ./path or absolute — never a bare filename.
  case "$bundle" in
    /*|./*) apt_deb="$bundle" ;;
    *) apt_deb="./$bundle" ;;
  esac
  if [ "$(id -u)" -eq 0 ]; then
    apt install -y --reinstall "$apt_deb"
  else
    sudo apt install -y --reinstall "$apt_deb"
  fi
fi
