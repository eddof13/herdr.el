EMACS ?= emacs
BATCH := $(EMACS) -Q --batch -L . -L test

TESTS := $(wildcard test/*-test.el)
SRC   := $(filter-out %-autoloads.el,$(wildcard *.el))

.PHONY: test test-live compile clean all

all: compile test

## Run the hermetic suite (no herdr server required).
test:
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (not (tag :live))))'

## Run only the tests that need a live herdr server.
## Set HERDR_SOCKET to a session socket so this does not touch the
## default server, and so the suite does not read the adopted-pane file.
test-live:
	$(BATCH) \
	  $(if $(HERDR_SOCKET),--eval "(setq herdr-socket-path \"$(HERDR_SOCKET)\" herdr-adopted-panes-file nil)") \
	  $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag :live)))'

## Byte-compile everything, treating warnings as failures.
compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)

clean:
	rm -f *.elc test/*.elc
