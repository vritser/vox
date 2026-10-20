#!/bin/sh
# Complete offline development gate.  EMACS is one executable, not shell words.
set -eu

root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
EMACS=${EMACS:-emacs}
export EMACS
parent=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd -P)
tmpdir=$(mktemp -d "$parent/vox-verify.XXXXXX")
created=$tmpdir
readonly parent tmpdir created
cleanup() {
    if [ -d "$tmpdir" ] && [ ! -L "$tmpdir" ] &&
       [ "$tmpdir" = "$created" ] &&
       [ "$(CDPATH= cd "$tmpdir" && pwd -P)" = "$created" ]; then
        case "$created" in
            "$parent"/vox-verify.??????) rm -rf -- "$created" ;;
            *) printf 'verify: refusing unexpected cleanup path: %s\n' "$created" >&2 ;;
        esac
    else
        printf 'verify: refusing unverified cleanup path: %s\n' "$created" >&2
    fi
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

failed=0
run() {
    label=$1
    key=$2
    shift 2
    if "$@" >"$tmpdir/$key.log" 2>&1; then
        printf 'ok   %s\n' "$label"
    else
        printf 'FAIL %s\n' "$label"
        sed 's/^/     /' "$tmpdir/$key.log"
        printf '==> verify FAIL\n'
        exit 1
    fi
}

printf '== Vox verification ==\n'
run 'syntax (root, scripts, test)' syntax \
    "$EMACS" -Q --batch -l scripts/check-lisp.el
run 'tooling self-tests' tooling \
    "$EMACS" -Q --batch -l test/vox-tooling-test.el
run 'runner self-tests' runner \
    "$EMACS" -Q --batch -l test/vox-test-runner.el
run 'strict compilation (temporary output)' compile \
    "$EMACS" -Q --batch -l scripts/compile.el

run 'required dependencies (websocket, FFmpeg, sh, GnuTLS, zlib)' dependencies \
    "$EMACS" -Q --batch -L .deps --eval '
(progn
  (setq load-suffixes (list ".el"))
  (unless (require (quote websocket) nil t)
    (error "Missing websocket.el: run scripts/setup-deps.sh"))
  (unless (executable-find "ffmpeg")
    (error "Missing FFmpeg: see scripts/setup-deps.sh; install ffmpeg on PATH"))
  (unless (executable-find "sh")
    (error "The full offline suite requires sh on PATH"))
  (require (quote gnutls))
  (unless (gnutls-available-p)
    (error "The full offline suite requires Emacs with native GnuTLS support"))
  (unless (and (fboundp (quote zlib-available-p)) (zlib-available-p))
    (error "The full offline suite requires Emacs with native zlib support")))'
run 'complete unit suite' suite \
    "$EMACS" -Q --batch -l test/vox-test.el

if "$EMACS" -Q --batch -L . -L .deps \
    --eval '(setq load-suffixes (list ".el"))' -l vox.el \
    >"$tmpdir/load.log" 2>&1; then
    if [ -s "$tmpdir/load.log" ]; then
        printf 'FAIL clean load (must produce zero output)\n'
        sed 's/^/     /' "$tmpdir/load.log"
        failed=1
    else
        printf 'ok   clean load (silent)\n'
    fi
else
    printf 'FAIL clean load (nonzero exit)\n'
    sed 's/^/     /' "$tmpdir/load.log"
    failed=1
fi

if command -v git >/dev/null 2>&1 &&
   git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    run 'git diff HEAD --check' whitespace git diff HEAD --check
else
    printf 'skip git diff HEAD --check (no Git worktree or Git unavailable)\n'
fi

run 'source-tree hygiene' hygiene "$EMACS" -Q --batch --eval '
(progn
  (require (quote cl-lib))
  (let ((ignored (quote (".deps" "dist" ".git" ".playwright-mcp"
                          "stream-asr-implementation-spec.md")))
        junk)
    (cl-labels
        ((junk-p (name)
           (or (cl-some (lambda (suffix) (string-suffix-p suffix name))
                        (quote (".elc" "~" ".orig" ".rej" ".swp" ".swo")))
               (string-prefix-p ".#" name)
               (string-prefix-p "._" name)
               (and (string-prefix-p "#" name) (string-suffix-p "#" name))
               (equal name ".DS_Store")))
         (scan (directory recurse)
           (dolist (file (directory-files directory t directory-files-no-dot-files-regexp))
             (let ((name (file-name-nondirectory file)))
               (unless (member name ignored)
                 (cond
                  ((and (junk-p name)
                        (or (file-regular-p file) (file-symlink-p file)))
                   (push file junk))
                  ((and (file-directory-p file) (not (file-symlink-p file))
                        (or recurse (member name (quote ("scripts" "test" "docs" "postmortems")))))
                   (scan file t))))))))
      (scan default-directory nil))
    (when junk
      (dolist (file (sort junk (function string<))) (princ (concat file "\n"))))
    (kill-emacs (if junk 1 0))))'

if [ "$failed" -eq 0 ]; then
    printf '==> verify PASS\n'
else
    printf '==> verify FAIL\n'
fi
exit "$failed"
