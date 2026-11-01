#!/usr/bin/env bash
# jsdos-override.sh - serve a newer js-dos to RomM without touching the RomM install.
#
# RomM loads js-dos from <prefix>/assets/jsdos/ (served by RomM's internal nginx
# from ~/opt/romm/www, which install.sh rebuilds with the js-dos version pinned in
# RomM's Dockerfile). This script puts a newer js-dos in its own directory and
# adds a separate location block to the front nginx that answers that one path
# first. Nothing under ~/opt/romm, romm.env, install.sh or romm.conf is modified.
#
#   ./jsdos-override.sh install   download, verify, unpack, write the nginx snippet
#   ./jsdos-override.sh remove    delete the nginx snippet (RomM's bundled js-dos is used again)
#   ./jsdos-override.sh status    show what is active
#
# Reload the front nginx the usual Ultra.cc way after install/remove.
set -euo pipefail

VERSION="${JSDOS_VERSION:-8.5.3}"
SHA256="${JSDOS_SHA256:-bff63d50dbec7c6f21ababc23a2b587c32785f66b464ffe68df38e821b945c89}"
URL_PREFIX="${ROMM_URL_PREFIX:-/romm}"
JSDOS_HOME="${JSDOS_HOME:-$HOME/opt/jsdos}"
PROXY_D_DIR="${PROXY_D_DIR:-$HOME/.apps/nginx/proxy.d}"
CONF="$PROXY_D_DIR/jsdos-override.conf"
MARKER="# managed by jsdos-override.sh"
RELEASE_URL="https://github.com/caiiiycuk/js-dos/releases/download/v${VERSION}/release.zip"

TMP_DIR=""
trap 'if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

extract_zip() { # <zip> <destdir>
    if command -v unzip >/dev/null; then unzip -q "$1" -d "$2"; return; fi
    for t in bsdtar "$HOME/opt/romm/tools/bin/bsdtar"; do
        if command -v "$t" >/dev/null || [ -x "$t" ]; then "$t" -xf "$1" -C "$2"; return; fi
    done
    for t in 7zz "$HOME/opt/romm/tools/bin/7zz"; do
        if command -v "$t" >/dev/null || [ -x "$t" ]; then "$t" x -mmt2 -bd -y "-o$2" "$1" >/dev/null; return; fi
    done
    die "need unzip, bsdtar or 7zz to unpack the release"
}

our_conf_or_absent() {
    [ ! -e "$CONF" ] || grep -qF "$MARKER" "$CONF" \
        || die "$CONF exists and was not written by this script; refusing to touch it"
}

cmd_install() {
    local dir="$JSDOS_HOME/$VERSION"
    our_conf_or_absent
    if [ -f "$dir/dist/js-dos.js" ]; then
        echo "js-dos $VERSION already unpacked in $dir"
    else
        [ ! -e "$dir" ] || die "$dir exists but is incomplete; remove it and re-run"
        TMP_DIR="$(mktemp -d)"
        local tmp="$TMP_DIR"
        echo "Downloading $RELEASE_URL"
        curl -fL --retry 3 -o "$tmp/release.zip" "$RELEASE_URL"
        echo "$SHA256  $tmp/release.zip" | sha256sum -c - || die "checksum mismatch"
        mkdir "$tmp/x"
        extract_zip "$tmp/release.zip" "$tmp/x"
        [ -f "$tmp/x/dist/js-dos.js" ] || die "unexpected release layout (no dist/js-dos.js)"
        # Same cleanup as RomM's Dockerfile: demo page, type declarations, maps, symbols.
        rm -rf "$tmp/x/dist/index.html" "$tmp/x/dist/emulators/types"
        find "$tmp/x/dist" \( -name '*.map' -o -name '*.symbols' \) -exec rm -f {} +
        mkdir -p "$dir.partial"
        mv "$tmp/x/dist" "$dir.partial/dist"
        mv "$dir.partial" "$dir"
        echo "Unpacked js-dos $VERSION into $dir"
    fi

    mkdir -p "$PROXY_D_DIR"
    cat > "$CONF.tmp" <<EOF
$MARKER (js-dos $VERSION)
# Delete this file and reload nginx to go back to the js-dos bundled with RomM.
location ^~ ${URL_PREFIX}/assets/jsdos/ {
    alias $dir/dist/;
    types {
        application/javascript js mjs;
        application/wasm       wasm;
        text/css               css;
        image/png              png;
        font/woff              woff;
    }
    add_header Cache-Control "no-cache" always;
    add_header X-Jsdos-Override "$VERSION" always;
}
EOF
    mv "$CONF.tmp" "$CONF"
    echo "Wrote $CONF"
    echo "Now reload the front nginx, then check:"
    echo "  curl -sI https://DOMAIN_NAME${URL_PREFIX}/assets/jsdos/js-dos.js | grep -i x-jsdos-override"
}

cmd_remove() {
    our_conf_or_absent
    if [ -e "$CONF" ]; then
        rm -f "$CONF"
        echo "Removed $CONF - reload the front nginx to go back to RomM's bundled js-dos."
    else
        echo "No override active."
    fi
    echo "Unpacked versions in $JSDOS_HOME are kept; delete them by hand if unwanted."
}

cmd_status() {
    if [ -e "$CONF" ]; then echo "Active snippet ($CONF):"; cat "$CONF"; else echo "No override snippet."; fi
    echo "Unpacked versions:"; ls -1 "$JSDOS_HOME" 2>/dev/null || echo "  (none)"
}

case "${1:-}" in
    install) cmd_install ;;
    remove)  cmd_remove ;;
    status)  cmd_status ;;
    *) echo "usage: $0 install|remove|status" >&2; exit 2 ;;
esac
