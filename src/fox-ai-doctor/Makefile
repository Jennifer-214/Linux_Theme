# src/fox-ai-doctor/Makefile — AI-augmented diagnostics binary.
#
# Links against ../fox-intel/libfox-intel.a, so building fox-ai-doctor
# implicitly requires fox-intel to have built first. `make -C src/fox-intel`
# is idempotent — the dependency line below kicks off only when needed.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
LIBS     := -lcurl
PREFIX   ?= $(HOME)/.local/bin

FOX_INTEL_DIR := ../fox-intel
FOX_INTEL_LIB := $(FOX_INTEL_DIR)/libfox-intel.a

BIN := fox-ai-doctor

all: $(BIN)

$(BIN): fox-ai-doctor.cpp $(FOX_INTEL_LIB)
	$(CXX) $(CXXFLAGS) fox-ai-doctor.cpp -o $@ \
		-L$(FOX_INTEL_DIR) -lfox-intel $(LIBS)

# Recurse into fox-intel if its library is missing — keeps the umbrella
# `make` from root resilient to subdir build order.
# FORCE: fox-intel's own Makefile decides whether the library is stale. Without it, a library that
# merely exists counts as current, and a fox-intel change never reached the installed tools.
$(FOX_INTEL_LIB): FORCE
	$(MAKE) -C $(FOX_INTEL_DIR) libfox-intel.a

install: all
	@mkdir -p $(PREFIX)
	@cp $(BIN) $(PREFIX)/
	@echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(BIN)

FORCE:

.PHONY: all install clean FORCE
