# src/ai-snitch/Makefile — links against ../desk-intel/libfox-intel.a.
CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
LIBS     := -lcurl
PREFIX   ?= $(HOME)/.local/bin

FOX_INTEL_DIR := ../desk-intel
FOX_INTEL_LIB := $(FOX_INTEL_DIR)/libfox-intel.a
BIN := ai-snitch

all: $(BIN)

$(BIN): ai-snitch.cpp $(FOX_INTEL_LIB)
	$(CXX) $(CXXFLAGS) ai-snitch.cpp -o $@ -L$(FOX_INTEL_DIR) -lfox-intel $(LIBS)

# FORCE: desk-intel's own Makefile decides whether the library is stale. Without it, a library that
# merely exists counts as current, and a desk-intel change never reached the installed tools.
$(FOX_INTEL_LIB): FORCE
	$(MAKE) -C $(FOX_INTEL_DIR) libfox-intel.a

install: all
	@mkdir -p $(PREFIX) && cp $(BIN) $(PREFIX)/ && echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(BIN)

FORCE:

.PHONY: all install clean FORCE
