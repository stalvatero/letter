#!/bin/sh
set -e

input="$1"
stamp="$2"
locale_root="$3"
lang="$4"
package="$5"

dest="$locale_root/$lang/LC_MESSAGES"
mkdir -p "$dest"
msgfmt -c -o "$dest/$package.mo" "$input"
cp "$dest/$package.mo" "$stamp"
