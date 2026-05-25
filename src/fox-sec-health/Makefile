# src/fox-sec-health/Makefile — `fox sec health` leaf binary.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

FOX_HEALTH_DIR := ../fox-health
FOX_HEALTH_LIB := $(FOX_HEALTH_DIR)/libfox-health.a

BIN = fox-sec-health

all: $(BIN)

$(BIN): main.cpp $(FOX_HEALTH_LIB)
	$(CXX) $(CXXFLAGS) main.cpp -L$(FOX_HEALTH_DIR) -lfox-health -o $@

# Ensure the library is fresh before linking.
$(FOX_HEALTH_LIB):
	$(MAKE) --no-print-directory -C $(FOX_HEALTH_DIR) all

install: all
	@mkdir -p $(PREFIX)
	@cp $(BIN) $(PREFIX)/
	@echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(BIN)

.PHONY: all install clean
