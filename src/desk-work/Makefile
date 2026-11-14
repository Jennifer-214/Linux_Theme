CXX ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
PREFIX ?= $(HOME)/.local/bin
COMMON := ../desk-common
BIN := desk-work
.DEFAULT_GOAL := all
all: desk-work
desk-work: main.cpp Makefile $(wildcard *.hpp) $(COMMON)/work_updates.hpp $(COMMON)/libdesk-common.a
	$(CXX) $(CXXFLAGS) -I$(COMMON) main.cpp -L$(COMMON) -ldesk-common -lcrypto -o $@
$(COMMON)/libdesk-common.a: $(COMMON)/shell.cpp $(COMMON)/shell.hpp
	$(MAKE) --no-print-directory -C $(COMMON)
install: all
	install -d "$(PREFIX)"
	install -m 755 desk-work "$(PREFIX)/desk-work"
test: all
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_work.py
clean:
	rm -f desk-work
.PHONY: all install test clean
