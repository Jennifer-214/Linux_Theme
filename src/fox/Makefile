# src/fox/Makefile — top-level dispatcher binary.
#
# Builds the `fox` entry-point that dispatches `fox <ns> <sub> [args]`
# to the appropriate namespace binary. Namespace registry lives in
# dispatch.def (X-macro expanded by main.cpp).
#
# Each new namespace (fox-ai, fox-sec, ...) adds one line to dispatch.def.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX   ?= $(HOME)/.local/bin

FOX_COMMON_DIR := ../fox-common
FOX_COMMON_LIB := $(FOX_COMMON_DIR)/libfox-common.a

BIN := fox

all: $(BIN)

$(BIN): main.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -o $@ main.o -L$(FOX_COMMON_DIR) -lfox-common

main.o: main.cpp dispatch.def
	$(CXX) $(CXXFLAGS) -I$(FOX_COMMON_DIR) -c main.cpp -o $@

# Ensure libfox-common.a is built before linking ourselves.
$(FOX_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(FOX_COMMON_DIR)

install: all
	@mkdir -p $(PREFIX)
	@install -m 755 $(BIN) $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(BIN) main.o

.PHONY: all install clean
