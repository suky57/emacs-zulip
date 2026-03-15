EMACS   ?= emacs
BATCH    = $(EMACS) -Q --batch -L .

EL_FILES = zulip-cache.el zulip-api.el zulip-events.el \
           zulip-ui.el zulip-compose.el zulip.el zulip-doom.el
ELC_FILES = $(EL_FILES:.el=.elc)
TEST_FILES = $(wildcard test/*.el)

.PHONY: all compile test lint clean

all: compile test

# Byte-compile every source file
compile: $(ELC_FILES)

%.elc: %.el
	@echo "  COMPILE $<"
	@$(BATCH) -f batch-byte-compile $<

# Run ERT test suite
test: compile
	@echo "  TEST"
	@$(BATCH) -l ert \
	  $(foreach f,$(TEST_FILES),-l $(f)) \
	  -f ert-run-tests-batch-and-exit

# Strict compilation — treat warnings as errors
lint:
	@echo "  LINT"
	@$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(EL_FILES)

clean:
	rm -f $(ELC_FILES)
