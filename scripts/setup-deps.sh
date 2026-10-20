#!/bin/sh
# Fetch only the audited websocket.el revision.  Install FFmpeg separately.
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
commit=3210187c107cdbb075b2e47454068a22f38213fc
sha256=95c653a3013288cad061394ea3ab175a8d6834caf19acf83e384f6c5cbf20ad2
deps=$root/.deps
if [ -L "$deps" ]; then
    printf 'setup-deps: refusing symlink dependency directory: %s\n' "$deps" >&2
    exit 1
fi
mkdir -p "$deps"
[ "$(CDPATH= cd "$deps" && pwd -P)" = "$deps" ] || exit 1
if [ -L "$deps/websocket.el" ]; then
    printf 'setup-deps: refusing symlink websocket.el\n' >&2
    exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    checksum() { sha256sum "$1"; }
elif command -v shasum >/dev/null 2>&1; then
    checksum() { shasum -a 256 "$1"; }
else
    printf 'setup-deps: install sha256sum or shasum to verify downloads\n' >&2
    exit 1
fi
verified() {
    [ -f "$1" ] || return 1
    digest=$(checksum "$1") || return 1
    [ "${digest%% *}" = "$sha256" ]
}

if verified "$deps/websocket.el"; then
    printf 'ok   websocket.el checksum verified (cached; no network)\n'
else
    command -v curl >/dev/null 2>&1 || {
        printf 'setup-deps: curl is required to download websocket.el\n' >&2
        exit 1
    }
    # Keep the download on the destination filesystem for an atomic rename.
    tmpdir=$(mktemp -d "$deps/vox-download.XXXXXX")
    created=$tmpdir
    readonly tmpdir created
    cleanup() {
        if [ -d "$tmpdir" ] && [ ! -L "$tmpdir" ] &&
           [ "$tmpdir" = "$created" ] &&
           [ "$(CDPATH= cd "$tmpdir" && pwd -P)" = "$created" ]; then
            case "$created" in
                "$deps"/vox-download.??????) rm -rf -- "$created" ;;
                *) printf 'setup-deps: refusing unexpected cleanup path: %s\n' "$created" >&2 ;;
            esac
        else
            printf 'setup-deps: refusing unverified cleanup path: %s\n' "$created" >&2
        fi
    }
    trap cleanup 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "https://raw.githubusercontent.com/ahyatt/emacs-websocket/$commit/websocket.el" \
        --output "$tmpdir/websocket.el"
    if ! verified "$tmpdir/websocket.el"; then
        printf 'setup-deps: SHA256 mismatch; existing dependency left unchanged\n' >&2
        exit 1
    fi
    # Verify both absolute paths immediately before replacing the dependency.
    [ "$tmpdir" = "$created" ] && [ ! -L "$tmpdir" ] &&
        [ "$(CDPATH= cd "$tmpdir" && pwd -P)" = "$created" ] &&
        [ "$(CDPATH= cd "$deps" && pwd -P)" = "$deps" ] &&
        [ ! -L "$deps/websocket.el" ] && [ ! -d "$deps/websocket.el" ] || exit 1
    mv -f -- "$created/websocket.el" "$deps/websocket.el"
    printf 'ok   websocket.el downloaded and SHA256 verified\n'
fi

if command -v ffmpeg >/dev/null 2>&1; then
    printf 'ok   FFmpeg available\n'
else
    printf 'setup-deps: FFmpeg is required for complete verification.\n' >&2
    printf 'Install it separately (brew install ffmpeg, or apt-get install ffmpeg).\n' >&2
    exit 1
fi
