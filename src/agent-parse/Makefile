CXX = g++
CXXFLAGS = -std=c++17 -O3 -Wall -Wextra -flto -march=native -DNDEBUG
BIN = agent-parse
PREFIX ?= $(HOME)/.local/bin

all: $(BIN)

$(BIN): main.cpp
	$(CXX) $(CXXFLAGS) -o $(BIN) main.cpp

install: $(BIN)
	install -d $(PREFIX)
	install -m 755 $(BIN) $(PREFIX)/$(BIN)

clean:
	rm -f $(BIN)

.PHONY: all install clean