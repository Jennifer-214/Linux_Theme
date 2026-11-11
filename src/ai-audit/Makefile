CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
LIBS     := -lcurl
PREFIX   ?= $(HOME)/.local/bin

DESK_INTEL_DIR := ../desk-intel
DESK_INTEL_LIB := $(DESK_INTEL_DIR)/libdesk-intel.a
BIN := ai-audit

all: $(BIN)

$(BIN): ai-audit.cpp $(DESK_INTEL_LIB)
	$(CXX) $(CXXFLAGS) ai-audit.cpp -o $@ -L$(DESK_INTEL_DIR) -ldesk-intel $(LIBS)

# FORCE: desk-intel's own Makefile decides whether the library is stale. Without it, a library that
# merely exists counts as current, and a desk-intel change never reached the installed tools.
$(DESK_INTEL_LIB): FORCE
	$(MAKE) -C $(DESK_INTEL_DIR) libdesk-intel.a

install: all
	@mkdir -p $(PREFIX) && cp $(BIN) $(PREFIX)/ && echo "  + $(BIN) installed to $(PREFIX)"

clean:
	@rm -f $(BIN)

FORCE:

.PHONY: all install clean FORCE
