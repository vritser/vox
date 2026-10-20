#!/bin/sh
# Verify first, then build a fresh standard Emacs multi-file package archive.
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
EMACS=${EMACS:-emacs}
export EMACS
"$root/scripts/verify.sh"

version=$("$EMACS" -Q --batch --eval '
(let* ((version
        (with-temp-buffer
          (insert-file-contents "vox.el")
          (goto-char (point-min))
          (unless (re-search-forward "^;; Version: \\([0-9][0-9A-Za-z.+-]*\\)[ \t]*$" nil t)
            (error "Missing or unsafe Version header in vox.el"))
          (match-string 1)))
       (descriptor
        (with-temp-buffer
          (insert-file-contents "vox-pkg.el")
          (goto-char (point-min))
          (read (current-buffer)))))
  (unless (and (eq (car-safe descriptor) (quote define-package))
               (equal (nth 1 descriptor) "vox")
               (equal (nth 2 descriptor) version))
    (error "vox.el Version does not match vox-pkg.el"))
  (version-to-list version)
  (princ version))')
case "$version" in
    ''|*[!0-9A-Za-z.+-]*) printf 'package: unsafe version: %s\n' "$version" >&2; exit 1 ;;
esac

parent=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd -P)
tmpdir=$(mktemp -d "$parent/vox-package.XXXXXX")
created=$tmpdir
readonly parent tmpdir created
cleanup() {
    if [ -d "$tmpdir" ] && [ ! -L "$tmpdir" ] &&
       [ "$tmpdir" = "$created" ] &&
       [ "$(CDPATH= cd "$tmpdir" && pwd -P)" = "$created" ]; then
        case "$created" in
            "$parent"/vox-package.??????) rm -rf -- "$created" ;;
            *) printf 'package: refusing unexpected cleanup path: %s\n' "$created" >&2 ;;
        esac
    else
        printf 'package: refusing unverified cleanup path: %s\n' "$created" >&2
    fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

name=vox-$version
stage=$created/$name
mkdir "$stage"
for required in vox.el vox-pkg.el README.md LICENSE CHANGELOG.md AGENTS.md docs scripts test; do
    if [ ! -e "$required" ] || [ -L "$required" ]; then
        printf 'package: missing input or unexpected symlink: %s\n' "$required" >&2
        exit 1
    fi
done

# A filtered input archive populates the empty stage; dist is never an input.
# COPYFILE_DISABLE avoids AppleDouble files on macOS without GNU-only flags.
export COPYFILE_DISABLE=1
tar --exclude='.deps' --exclude='dist' --exclude='.git' \
    --exclude='.playwright-mcp' --exclude='*.elc' --exclude='*~' \
    --exclude='*.orig' --exclude='*.rej' --exclude='.#*' --exclude='#*#' \
    --exclude='.DS_Store' --exclude='._*' --exclude='*.swp' --exclude='*.swo' \
    -cf "$created/inputs.tar" \
    vox*.el README.md LICENSE CHANGELOG.md AGENTS.md docs scripts test
tar -xf "$created/inputs.tar" -C "$stage"
tar -cf "$created/$name.tar" -C "$created" "$name"

if [ -L "$root/dist" ]; then
    printf 'package: refusing symlink output directory\n' >&2
    exit 1
fi
mkdir -p "$root/dist"
# Check the actual source/output directories before moving the created archive.
[ "$tmpdir" = "$created" ] && [ ! -L "$tmpdir" ] &&
    [ "$(CDPATH= cd "$tmpdir" && pwd -P)" = "$created" ] &&
    [ "$(CDPATH= cd "$root/dist" && pwd -P)" = "$root/dist" ] &&
    [ -f "$created/$name.tar" ] && [ ! -L "$created/$name.tar" ] &&
    [ ! -L "$root/dist/$name.tar" ] && [ ! -d "$root/dist/$name.tar" ] || exit 1
mv -f -- "$created/$name.tar" "$root/dist/$name.tar"
printf 'package: %s\n' "$root/dist/$name.tar"
