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
test: all tests/test_map
	./tests/test_map
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_work.py
	PYTHONDONTWRITEBYTECODE=1 python3 tests/test_map.py
tests/test_map: tests/test_map.cpp map_graph.hpp $(COMMON)/json.hpp
	$(CXX) $(CXXFLAGS) -I$(COMMON) tests/test_map.cpp -o $@
clean:
	rm -f desk-work tests/test_map
.PHONY: all install test clean
