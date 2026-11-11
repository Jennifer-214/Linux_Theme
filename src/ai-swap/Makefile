# src/ai-swap/Makefile

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O3 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

BIN = ai-swap

all: $(BIN)

$(BIN): ai-swap.cpp
	$(CXX) $(CXXFLAGS) ai-swap.cpp -o $@

install: all
	@mkdir -p $(PREFIX)
	@cp $(BIN) $(PREFIX)/
	@echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(BIN)

.PHONY: all install clean
