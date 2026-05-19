# src/fox-sec/Makefile — namespace dispatcher for security tools.
#
# Mirrors src/fox-ai/Makefile. Builds the `fox-sec` binary which
# dispatches `fox sec <sub>` to the appropriate leaf binary.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX   ?= $(HOME)/.local/bin

FOX_COMMON_DIR := ../fox-common
FOX_COMMON_LIB := $(FOX_COMMON_DIR)/libfox-common.a

BIN := fox-sec

all: $(BIN)

$(BIN): main.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -o $@ main.o -L$(FOX_COMMON_DIR) -lfox-common

main.o: main.cpp dispatch.def
	$(CXX) $(CXXFLAGS) -I$(FOX_COMMON_DIR) -c main.cpp -o $@

$(FOX_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(FOX_COMMON_DIR)

install: all
	@mkdir -p $(PREFIX)
	@install -m 755 $(BIN) $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

test: $(BIN)
	@bash tests/dispatch_test.sh

clean:
	@rm -f $(BIN) main.o

.PHONY: all install clean test
