# src/sec-health/Makefile — `desk sec health` leaf binary.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

DESK_HEALTH_DIR := ../desk-health
DESK_HEALTH_LIB := $(DESK_HEALTH_DIR)/libdesk-health.a

BIN = sec-health

all: $(BIN)

$(BIN): main.cpp $(DESK_HEALTH_LIB)
	$(CXX) $(CXXFLAGS) main.cpp -L$(DESK_HEALTH_DIR) -ldesk-health -o $@

# Ensure the library is fresh before linking.
$(DESK_HEALTH_LIB):
	$(MAKE) --no-print-directory -C $(DESK_HEALTH_DIR) all

install: all
	@mkdir -p $(PREFIX)
	@cp $(BIN) $(PREFIX)/
	@echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(BIN)

.PHONY: all install clean
