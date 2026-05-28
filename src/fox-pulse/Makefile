# src/fox-pulse/Makefile — event-driven Hyprland+inotify daemon.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

OBJ = hypr_socket.o debouncer.o
BIN = fox-pulse

all: $(BIN)

hypr_socket.o: hypr_socket.cpp hypr_socket.hpp
	$(CXX) $(CXXFLAGS) -c hypr_socket.cpp -o $@

debouncer.o: debouncer.cpp debouncer.hpp
	$(CXX) $(CXXFLAGS) -c debouncer.cpp -o $@

$(BIN): fox-pulse.cpp $(OBJ)
	$(CXX) $(CXXFLAGS) fox-pulse.cpp $(OBJ) -o $@

install: all
	@mkdir -p $(PREFIX)
	@# Atomic-rename pattern — survives ETXTBSY when the daemon is running.
	@# See src/fox-vault/Makefile for the full rationale.
	@install -m 755 $(BIN) $(PREFIX)/$(BIN).new
	@mv $(PREFIX)/$(BIN).new $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(OBJ) $(BIN)

.PHONY: all install clean
