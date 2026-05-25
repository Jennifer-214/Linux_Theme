# src/fox-health/Makefile — health-check library.
#
# Produces libfox-health.a, used by:
#   - src/fox-sec-health/ (CLI wrapper for `fox sec health`)
#   - src/fox-install/   (future preflight integration)
#   - src/foxml-health-pacman/ (future pacman hook binary)

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic -fPIC
AR       ?= ar
PREFIX   ?= $(HOME)/.local/bin

OBJS = health.o checks_a_boot.o checks_b_auth.o
LIB  = libfox-health.a

all: $(LIB)

%.o: %.cpp health.hpp checks.hpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(LIB): $(OBJS)
	$(AR) rcs $@ $(OBJS)

# Library only — nothing to install at the binary level. Leaf binaries
# that link this archive get installed by their own Makefiles.
install: all
	@true

test: tests/test_health
	@./tests/test_health

tests/test_health: tests/test_health.cpp $(OBJS) health.hpp checks.hpp
	$(CXX) $(CXXFLAGS) tests/test_health.cpp $(OBJS) -o $@

clean:
	@rm -f $(OBJS) $(LIB) tests/test_health

.PHONY: all install test clean
