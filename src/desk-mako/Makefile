CC ?= cc
BIN := desk-mako
PREFIX ?= $(HOME)/.local/bin
.DEFAULT_GOAL := all
all: $(BIN)

vendor/.ready: prepare.py paper-edge.h paper-stamp.h bar-bridge.h
	python3 prepare.py

$(BIN): vendor/.ready
	python3 prepare.py --build

# install.sh invokes the umbrella install before run_deps. Only the native
# drawer module can build this after dependencies and snapshot the old binary.
install:
	@echo "  - desk-mako: build and backup-first deployment handled by desk-install --drawer"

test: all
	python3 tests.py

clean:
	rm -f $(BIN) vendor/.ready
	rm -rf build

.PHONY: all install test clean
