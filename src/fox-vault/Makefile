# src/fox-vault/Makefile — mlock'd in-RAM secret store.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

OBJ = vault_store.o
BIN = fox-vault

all: $(BIN)

vault_store.o: vault_store.cpp vault_store.hpp
	$(CXX) $(CXXFLAGS) -c vault_store.cpp -o $@

$(BIN): fox-vault.cpp $(OBJ)
	$(CXX) $(CXXFLAGS) fox-vault.cpp $(OBJ) -o $@ -lcrypto

install: all
	@mkdir -p $(PREFIX)
	@# Atomic-rename pattern: cp/install with O_TRUNC fails ETXTBSY when
	@# the existing binary is a running daemon (fox-vault start --foreground).
	@# rename(2) replaces the directory entry without touching the running
	@# inode, so the live process keeps executing and the next launch
	@# picks up the new binary.
	@install -m 755 $(BIN) $(PREFIX)/$(BIN).new
	@mv $(PREFIX)/$(BIN).new $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"

test: tests/test_store
	@./tests/test_store

tests/test_store: tests/test_store.cpp $(OBJ)
	$(CXX) $(CXXFLAGS) tests/test_store.cpp $(OBJ) -o $@ -lcrypto

clean:
	@rm -f $(OBJ) $(BIN) tests/test_store

.PHONY: all install clean test
