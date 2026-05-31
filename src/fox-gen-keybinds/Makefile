CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

FOX_COMMON_DIR := ../fox-common
FOX_COMMON_LIB := $(FOX_COMMON_DIR)/libfox-common.a
BIN := fox-gen-keybinds

all: $(BIN)

$(BIN): fox-gen-keybinds.cpp $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -I$(FOX_COMMON_DIR) fox-gen-keybinds.cpp -o $@ -L$(FOX_COMMON_DIR) -lfox-common

$(FOX_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(FOX_COMMON_DIR)

install: all
	@mkdir -p $(PREFIX) && install -m 755 $(BIN) $(PREFIX)/$(BIN) && echo "  + $(BIN) installed to $(PREFIX)"

test: $(BIN)
	@bash tests/gen_keybinds_test.sh

clean:
	@rm -f $(BIN)

.PHONY: all install clean test
