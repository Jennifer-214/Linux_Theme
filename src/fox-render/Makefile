# src/fox-render/Makefile — concurrent template renderer.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O3 -Wall -Wextra -pthread
LDFLAGS  ?= -pthread
PREFIX   ?= $(HOME)/.local/bin

OBJ = palette.o render.o reverse.o icon_family.o paper_assets.o
BIN = fox-render-fast

all: $(BIN)

palette.o: palette.cpp palette.hpp
	$(CXX) $(CXXFLAGS) -c palette.cpp -o $@

render.o: render.cpp render.hpp
	$(CXX) $(CXXFLAGS) -c render.cpp -o $@

reverse.o: reverse.cpp reverse.hpp
	$(CXX) $(CXXFLAGS) -c reverse.cpp -o $@

icon_family.o: icon_family.cpp icon_family.hpp render.hpp ../fox-common/json.hpp
	$(CXX) $(CXXFLAGS) -c icon_family.cpp -o $@

paper_assets.o: paper_assets.cpp paper_assets.hpp render.hpp
	$(CXX) $(CXXFLAGS) -c paper_assets.cpp -o $@

$(BIN): fox-render-fast.cpp $(OBJ)
	$(CXX) $(CXXFLAGS) fox-render-fast.cpp $(OBJ) -o $@ $(LDFLAGS)

install: all
	@mkdir -p $(PREFIX)
	@cp $(BIN) $(PREFIX)/
	@echo "  + $(BIN) installed to $(PREFIX)"

test: tests/test_main
	@./tests/test_main

tests/test_main: tests/test_main.cpp $(OBJ)
	$(CXX) $(CXXFLAGS) tests/test_main.cpp $(OBJ) -o $@ $(LDFLAGS)

clean:
	@rm -f $(OBJ) $(BIN) tests/test_main

.PHONY: all install clean test
