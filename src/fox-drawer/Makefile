CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX   ?= $(HOME)/.local/bin
COMMON   := ../fox-common
BIN      := fox-drawer

.DEFAULT_GOAL := all
all: fox-drawer

fox-drawer: main.o $(COMMON)/libfox-common.a
	$(CXX) $(CXXFLAGS) -o $@ main.o -L$(COMMON) -lfox-common

main.o: main.cpp $(COMMON)/shell.hpp $(COMMON)/json.hpp
	$(CXX) $(CXXFLAGS) -I$(COMMON) -c main.cpp -o $@

$(COMMON)/libfox-common.a:
	$(MAKE) --no-print-directory -C $(COMMON)

install: all
	install -d "$(PREFIX)"
	install -m 755 fox-drawer "$(PREFIX)/fox-drawer"

test: all
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_backend.py

clean:
	rm -f fox-drawer main.o

.PHONY: all install test clean
