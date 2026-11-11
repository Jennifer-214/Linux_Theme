CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

DESK_COMMON_DIR := ../desk-common
DESK_COMMON_LIB := $(DESK_COMMON_DIR)/libdesk-common.a
BIN := gen-keybinds

all: $(BIN)

$(BIN): gen-keybinds.cpp $(DESK_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -I$(DESK_COMMON_DIR) gen-keybinds.cpp -o $@ -L$(DESK_COMMON_DIR) -ldesk-common

$(DESK_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(DESK_COMMON_DIR)

install: all
	@mkdir -p $(PREFIX) && install -m 755 $(BIN) $(PREFIX)/$(BIN) && echo "  + $(BIN) installed to $(PREFIX)"

test: $(BIN)
	@bash tests/gen_keybinds_test.sh

clean:
	@rm -f $(BIN)

.PHONY: all install clean test
