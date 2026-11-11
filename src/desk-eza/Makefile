CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX   ?= $(HOME)/.local/bin
COMMON   := ../desk-common
BIN      := desk-eza

.DEFAULT_GOAL := all
all: $(BIN)

$(BIN): main.cpp $(COMMON)/json.hpp $(COMMON)/shell.hpp $(COMMON)/libdesk-common.a
	$(CXX) $(CXXFLAGS) -o $@ main.cpp -L$(COMMON) -ldesk-common

$(COMMON)/libdesk-common.a:
	$(MAKE) --no-print-directory -C $(COMMON)

install: all
	install -d "$(PREFIX)"
	install -m 755 $(BIN) "$(PREFIX)/.$(BIN).new"
	mv -f "$(PREFIX)/.$(BIN).new" "$(PREFIX)/$(BIN)"

test: all
	python3 tests.py

clean:
	rm -f $(BIN)

.PHONY: all install test clean
