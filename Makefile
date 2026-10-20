EMACS ?= emacs
LOAD = -Q --batch -L . -L test -L .deps --eval '(setq load-prefer-newer t)'
SOURCES = $(wildcard vox*.el)
TESTS = $(wildcard test/vox-*-test.el)

.PHONY: test compile check benchmark

test:
	$(EMACS) $(LOAD) -l ert $(foreach file,$(TESTS),-l $(file)) -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) $(LOAD) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SOURCES)

check: compile test

benchmark:
	$(EMACS) $(LOAD) -l test/vox-benchmark.el -f vox-benchmark-run
