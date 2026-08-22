#!/bin/zsh
# Builds SANE's hp3900 backend from the same sane-backends release Homebrew installed, with
# hp3900-g3010-film-window.patch applied, and installs it over Homebrew's copy. The stock backend
# is kept next to it as libsane-hp3900.1.so.orig.
#
# Re-run after `brew upgrade sane-backends` (it restores the stock backend).
# Undo with `brew reinstall sane-backends`.
set -euo pipefail

repo=${0:a:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

brew unpack --destdir="$work" sane-backends
cd "$work"/sane-backends-*
patch -p1 < "$repo/Driver/hp3900-g3010-film-window.patch"

# Same flags as the Homebrew formula, only the one backend.
BACKENDS=hp3900 ./configure --enable-local-backends --localstatedir="$(brew --prefix)/var" \
    --without-gphoto2 --with-usb=yes --prefix="$(brew --prefix sane-backends)" \
    --disable-dependency-tracking
make -j"$(sysctl -n hw.ncpu)"

dest="$(brew --prefix sane-backends)/lib/sane/libsane-hp3900.1.so"
[[ -e "$dest.orig" ]] || cp -p "$dest" "$dest.orig"
chmod u+w "$dest"
cp backend/.libs/libsane-hp3900.1.so "$dest"
echo "Installed the patched hp3900 backend at $dest (stock copy: $dest.orig). Restart Scanjet."
