# src/theme-check/Makefile — `desk theme check`, a read-only desktop self-check.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX   ?= $(HOME)/.local/bin

DESK_COMMON_DIR := ../desk-common
DESK_HEALTH_DIR := ../desk-health
LIBS := $(DESK_HEALTH_DIR)/libdesk-health.a $(DESK_COMMON_DIR)/libdesk-common.a

BIN := theme-check

all: $(BIN)

$(BIN): main.o $(LIBS)
	$(CXX) $(CXXFLAGS) -o $@ main.o -L$(DESK_HEALTH_DIR) -ldesk-health -L$(DESK_COMMON_DIR) -ldesk-common

main.o: main.cpp drift.hpp Makefile
	$(CXX) $(CXXFLAGS) -MMD -MP -c main.cpp -o $@

-include main.d

$(DESK_COMMON_DIR)/libdesk-common.a:
	$(MAKE) --no-print-directory -C $(DESK_COMMON_DIR)

$(DESK_HEALTH_DIR)/libdesk-health.a:
	$(MAKE) --no-print-directory -C $(DESK_HEALTH_DIR)

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
