# src/fox-theme-check/Makefile — `fox theme check`, a read-only desktop self-check.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX   ?= $(HOME)/.local/bin

FOX_COMMON_DIR := ../fox-common
FOX_HEALTH_DIR := ../fox-health
LIBS := $(FOX_HEALTH_DIR)/libfox-health.a $(FOX_COMMON_DIR)/libfox-common.a

BIN := fox-theme-check

all: $(BIN)

$(BIN): main.o $(LIBS)
	$(CXX) $(CXXFLAGS) -o $@ main.o -L$(FOX_HEALTH_DIR) -lfox-health -L$(FOX_COMMON_DIR) -lfox-common

main.o: main.cpp drift.hpp
	$(CXX) $(CXXFLAGS) -c main.cpp -o $@

$(FOX_COMMON_DIR)/libfox-common.a:
	$(MAKE) --no-print-directory -C $(FOX_COMMON_DIR)

$(FOX_HEALTH_DIR)/libfox-health.a:
	$(MAKE) --no-print-directory -C $(FOX_HEALTH_DIR)

tests/test_drift: tests/test_drift.cpp drift.hpp
	$(CXX) $(CXXFLAGS) -o $@ tests/test_drift.cpp

install: all
	@mkdir -p $(PREFIX)
	@install -m 755 $(BIN) $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

test: $(BIN) tests/test_drift
	@./tests/test_drift

clean:
	@rm -f $(BIN) main.o tests/test_drift

.PHONY: all install clean test
