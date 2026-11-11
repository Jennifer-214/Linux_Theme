CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX   ?= $(HOME)/.local/bin
COMMON   := ../desk-common
BIN      := desk-drawer

.DEFAULT_GOAL := all
all: desk-drawer

desk-drawer: main.o $(COMMON)/libfox-common.a
	$(CXX) $(CXXFLAGS) -o $@ main.o -L$(COMMON) -lfox-common -lcrypto

main.o: main.cpp $(COMMON)/shell.hpp $(COMMON)/json.hpp
	$(CXX) $(CXXFLAGS) -I$(COMMON) -c main.cpp -o $@

$(COMMON)/libfox-common.a:
	$(MAKE) --no-print-directory -C $(COMMON)

install: all
	install -d "$(PREFIX)"
	install -m 755 desk-drawer "$(PREFIX)/desk-drawer"

test: all
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_backend.py

clean:
	rm -f desk-drawer main.o

.PHONY: all install test clean
