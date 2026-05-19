# src/fox-common/Makefile — shared core library.
#
# Produces libfox-common.a. Linked into every fox-* tool that needs the
# pacman-style UI, subprocess helpers (sh::run / sh::pacman / etc.), and
# (in future slices) the namespace dispatcher (dispatch.hpp).
#
# To add a new shared utility: drop a .hpp/.cpp pair into this directory.
# It's auto-picked-up by the wildcard below — no Makefile changes needed.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic -fPIC

SRC := $(wildcard *.cpp)
OBJ := $(SRC:.cpp=.o)
LIB := libfox-common.a

all: $(LIB)

$(LIB): $(OBJ)
	ar rcs $@ $^

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

# fox-common is a library, not a binary — `install` is a no-op so the
# root Makefile's `install` target can recurse here without copying
# anything to ~/.local/bin. Consumers link the .a at build time.
install:
	@true

test:
	@true

clean:
	@rm -f $(OBJ) $(LIB)

.PHONY: all install clean test
