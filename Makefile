.DEFAULT_GOAL := check
EMACS ?= emacs
LOAD = -Q --batch -L . -L test -L .deps --eval '(setq load-prefer-newer t)'
SOURCES = $(filter-out vox-pkg.el,$(wildcard vox*.el))
TESTS = $(wildcard test/vox-*-test.el)

.PHONY: test compile check benchmark dist

dist: check
	mkdir -p dist/vox-0.1.0
	cp $(SOURCES) vox-pkg.el README.md LICENSE Makefile dist/vox-0.1.0/
	cp -R docs test dist/vox-0.1.0/
	tar -C dist -cf dist/vox-0.1.0.tar vox-0.1.0

test:
	$(EMACS) $(LOAD) -l ert $(foreach file,$(TESTS),--eval '(require (quote $(basename $(notdir $(file)))))') -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) $(LOAD) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SOURCES)

check: compile test

benchmark:
	$(EMACS) $(LOAD) -l test/vox-benchmark.el -f vox-benchmark-run
