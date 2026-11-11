# src/desk-pulse/Makefile — event-driven Hyprland+inotify daemon.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

OBJ = hypr_socket.o debouncer.o polkit_watch.o
BIN = desk-pulse

all: $(BIN)

hypr_socket.o: hypr_socket.cpp hypr_socket.hpp
	$(CXX) $(CXXFLAGS) -c hypr_socket.cpp -o $@

debouncer.o: debouncer.cpp debouncer.hpp
	$(CXX) $(CXXFLAGS) -c debouncer.cpp -o $@

polkit_watch.o: polkit_watch.cpp polkit_watch.hpp
	$(CXX) $(CXXFLAGS) -c polkit_watch.cpp -o $@

$(BIN): desk-pulse.cpp $(OBJ)
	$(CXX) $(CXXFLAGS) desk-pulse.cpp $(OBJ) -o $@

install: all
	@mkdir -p $(PREFIX)
	@# Atomic-rename pattern — survives ETXTBSY when the daemon is running.
	@# See src/desk-vault/Makefile for the full rationale.
	@install -m 755 $(BIN) $(PREFIX)/$(BIN).new
	@mv $(PREFIX)/$(BIN).new $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

test: tests/test_polkit_watch
	@./tests/test_polkit_watch

tests/test_polkit_watch: tests/test_polkit_watch.cpp polkit_watch.o
	$(CXX) $(CXXFLAGS) tests/test_polkit_watch.cpp polkit_watch.o -o $@

clean:
	@rm -f $(OBJ) $(BIN) tests/test_polkit_watch

.PHONY: all install clean
