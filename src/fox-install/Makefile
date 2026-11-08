# src/fox-install/Makefile — C++ orchestrator.
#
# Every .cpp under core/ and modules/ is compiled and linked into one
# binary. To add a new module, drop a .cpp into modules/ and add one
# line to core/modules.def — no Makefile changes needed.

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
PREFIX   ?= $(HOME)/.local/bin

# Shared core library — produces libfox-common.a (ui/shell helpers, and
# in future slices the dispatcher). Linked into our binary.
FOX_COMMON_DIR := ../fox-common
FOX_COMMON_LIB := $(FOX_COMMON_DIR)/libfox-common.a

# foxml-health check library — Phase 2 preflight integration. The
# preflight module calls fox_health::run_all() on the A+B subset and
# bails on any Critical fail.
FOX_HEALTH_DIR := ../fox-health
FOX_HEALTH_LIB := $(FOX_HEALTH_DIR)/libfox-health.a

# monitor library — the single sidecar (monitor-layout.conf) read/write
# implementation. monitors/personalize/summary modules link this so there
# is exactly one sidecar code path shared with the fox-monitor binary.
FOX_MONITOR_DIR := ../fox-monitor
FOX_MONITOR_LIB := $(FOX_MONITOR_DIR)/libfox-monitor.a

CORE_SRC    := $(wildcard core/*.cpp)
MODULE_SRC  := $(wildcard modules/*.cpp)
MAIN_SRC    := fox-install.cpp

CORE_OBJ    := $(CORE_SRC:.cpp=.o)
MODULE_OBJ  := $(MODULE_SRC:.cpp=.o)
MAIN_OBJ    := $(MAIN_SRC:.cpp=.o)

BIN := fox-install

all: $(BIN)

$(BIN): $(MAIN_OBJ) $(CORE_OBJ) $(MODULE_OBJ) $(FOX_COMMON_LIB) $(FOX_HEALTH_LIB) $(FOX_MONITOR_LIB)
	$(CXX) $(CXXFLAGS) -o $@ $(MAIN_OBJ) $(CORE_OBJ) $(MODULE_OBJ) \
		-L$(FOX_MONITOR_DIR) -lfox-monitor \
		-L$(FOX_COMMON_DIR) -lfox-common \
		-L$(FOX_HEALTH_DIR) -lfox-health \
		-lcrypto

# Ensure libfox-common.a is built before linking.
$(FOX_COMMON_LIB):
	$(MAKE) --no-print-directory -C $(FOX_COMMON_DIR)

$(FOX_HEALTH_LIB):
	$(MAKE) --no-print-directory -C $(FOX_HEALTH_DIR)

$(FOX_MONITOR_LIB):
	$(MAKE) --no-print-directory -C $(FOX_MONITOR_DIR)

# -MMD records every project header each object includes, so a header edit rebuilds exactly its includers.
# Makefile is a prerequisite so a flag change rebuilds objects from before the .d files existed.
DEPFLAGS := -MMD -MP
%.o: %.cpp Makefile
	$(CXX) $(CXXFLAGS) $(DEPFLAGS) -c $< -o $@

-include $(CORE_OBJ:.o=.d) $(MODULE_OBJ:.o=.d) $(MAIN_OBJ:.o=.d)

install: all
	@mkdir -p $(PREFIX)
	@install -m 755 $(BIN) $(PREFIX)/$(BIN)
	@echo "  + $(BIN) installed to $(PREFIX)"
	@# Record the source repo path so the installed binary can find
	@# templates/ + themes/ when invoked from outside the repo.
	@mkdir -p $(HOME)/.local/share/foxml
	@cd ../.. && pwd > $(HOME)/.local/share/foxml/repo-dir
	@echo "  + repo path recorded: $$(cat $(HOME)/.local/share/foxml/repo-dir)"

test: tests/test_registry tests/test_args tests/test_state_manifest tests/test_classifier tests/test_state_checks tests/test_conflict_resolve tests/test_wizard tests/test_install_lock tests/test_subprocess_log tests/test_banner_font tests/test_gaming tests/test_iommu tests/test_hyprlock_pin tests/test_nvidia_modules tests/test_claude_wiring tests/test_hw_autoenable tests/test_built_tools tests/test_hidepid tests/test_health_boot tests/test_dry_run tests/test_git_clone tests/test_hypr_lua tests/test_drawer_deploy tests/test_cursor_sync tests/test_cursor_recolor tests/test_folder_recolor tests/test_gtk_appearance tests/test_icon_deploy
	@./tests/test_registry
	@./tests/test_args
	@./tests/test_state_manifest
	@./tests/test_classifier
	@./tests/test_state_checks
	@./tests/test_conflict_resolve
	@./tests/test_wizard
	@./tests/test_install_lock
	@./tests/test_subprocess_log
	@./tests/test_banner_font
	@./tests/test_gaming
	@./tests/test_iommu
	@./tests/test_hyprlock_pin
	@./tests/test_nvidia_modules
	@./tests/test_claude_wiring
	@./tests/test_hw_autoenable
	@./tests/test_built_tools
	@./tests/test_git_clone
	@./tests/test_hidepid
	@./tests/test_health_boot
	@./tests/test_dry_run
	@./tests/test_hypr_lua
	@./tests/test_drawer_deploy
	@./tests/test_cursor_sync
	@./tests/test_cursor_recolor
	@./tests/test_folder_recolor
	@./tests/test_gtk_appearance
	@./tests/test_icon_deploy
	@./tests/test_firefox_appearance
	@./tests/test_notification_refresh
	@./tests/test_theme_choice
	@./tests/test_ide_settings
	@./tests/test_firefox_policies
	@./tests/test_arkenfox_userjs
	@./tests/test_private_extras
	@bash ./tests/lint_shell_assets.sh
	@bash ./tests/lint_unit_escaping.sh

# Test binary links only core/registry.o (the X-macro table); modules
# are stubbed inside the test file so we don't drag in their real
# implementations.
tests/test_registry: tests/test_registry.cpp core/registry.o
	$(CXX) $(CXXFLAGS) tests/test_registry.cpp core/registry.o -o $@


test: tests/test_firefox_appearance
test: tests/test_notification_refresh
test: tests/test_theme_choice tests/test_ide_settings tests/test_firefox_policies tests/test_arkenfox_userjs
test: tests/test_private_extras

tests/test_private_extras: tests/test_private_extras.cpp modules/private_extras.hpp modules/private_extras.cpp
	$(CXX) $(CXXFLAGS) $< -o $@

tests/test_firefox_policies: tests/test_firefox_policies.cpp modules/firefox_policies.hpp
	$(CXX) $(CXXFLAGS) $< -o $@

tests/test_arkenfox_userjs: tests/test_arkenfox_userjs.cpp modules/arkenfox_userjs.hpp
	$(CXX) $(CXXFLAGS) $< -o $@

tests/test_theme_choice: tests/test_theme_choice.cpp core/theme_choice.hpp
	$(CXX) $(CXXFLAGS) $< -o $@

tests/test_ide_settings: tests/test_ide_settings.cpp modules/ide_settings.hpp core/backup.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) $(filter %.cpp %.o %.a,$^) -o $@

tests/test_notification_refresh: tests/test_notification_refresh.cpp modules/notification_refresh.hpp
	$(CXX) $(CXXFLAGS) $< -o $@

test-notification-refresh: tests/test_notification_refresh
	./tests/test_notification_refresh
.PHONY: test-notification-refresh

tests/test_firefox_appearance: tests/test_firefox_appearance.cpp modules/firefox_appearance.hpp core/backup.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) $(filter %.cpp %.o %.a,$^) -o $@

tests/test_icon_deploy: tests/test_icon_deploy.cpp modules/symlinks.o core/backup.o $(FOX_COMMON_LIB) modules/gtk_appearance.hpp
	$(CXX) $(CXXFLAGS) $(filter %.cpp %.o %.a,$^) -o $@

tests/test_drawer_deploy: tests/test_drawer_deploy.cpp modules/drawer.o core/backup.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) $^ -o $@

tests/test_cursor_sync: tests/test_cursor_sync.cpp modules/catppuccin_cursor.o core/backup.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) $^ -o $@

tests/test_cursor_recolor: tests/test_cursor_recolor.cpp modules/cursor_recolor.hpp
	$(CXX) $(CXXFLAGS) $< -o $@

tests/test_folder_recolor: tests/test_folder_recolor.cpp modules/folder_recolor.hpp modules/cursor_recolor.hpp
	$(CXX) $(CXXFLAGS) $< -o $@

tests/test_gtk_appearance: tests/test_gtk_appearance.cpp modules/gtk_appearance.hpp $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) $< $(FOX_COMMON_LIB) -o $@

# [I-08] flag-layer semantics — parse-time precedence (every shipped
# accepted-but-overridden flag bug is a case here). Links the real
# state_checks for the registry's check_* symbols; run_* are stubbed
# inside the test via the modules.def X-macro.
tests/test_args: tests/test_args.cpp core/args.o core/registry.o core/state_checks.o core/state_manifest.o core/classifier.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_args.cpp core/args.o core/registry.o core/state_checks.o core/state_manifest.o core/classifier.o -L$(FOX_COMMON_DIR) -lfox-common -lcrypto -o $@

tests/test_state_manifest: tests/test_state_manifest.cpp core/state_manifest.o
	$(CXX) $(CXXFLAGS) tests/test_state_manifest.cpp core/state_manifest.o -o $@ -lcrypto

# gaming tests the [multilib]-enable IDEMPOTENCY (the fixed-point proof that
# guards against the iommu boot-corruption class). Runs the real
# MULTILIB_UNCOMMENT_SED against a temp fixture; links gaming.o for
# multilib_already_enabled + libfox-common for sh::run.
tests/test_gaming: tests/test_gaming.cpp modules/gaming.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_gaming.cpp modules/gaming.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

tests/test_classifier: tests/test_classifier.cpp core/classifier.o
	$(CXX) $(CXXFLAGS) tests/test_classifier.cpp core/classifier.o -o $@

# iommu pins the lockdown gate (build_iommu_args) + the self-heal strip
# (LOCKDOWN_STRIP_SED idempotency) + the post-edit self-check
# (cmdline_options_sane) against a real boot-entry fixture — no VM, no sudo.
# Links iommu.o for the real symbols + libfox-common for sh::run.
tests/test_iommu: tests/test_iommu.cpp modules/iommu.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_iommu.cpp modules/iommu.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

# nvidia_modules pins the MERGE that replaced the destructive whole-line
# MODULES sed (the unbootable-initramfs brick): every existing MODULES entry
# survives + the nvidia modules are added (dedup, order preserved). Pure
# header (no .o), so no sudo and no VM — runs the REAL merge against fixtures.
tests/test_nvidia_modules: tests/test_nvidia_modules.cpp modules/nvidia_modules.hpp
	$(CXX) $(CXXFLAGS) tests/test_nvidia_modules.cpp -o $@

# Hyprland 0.57 (Lua-only) helpers — header-only, links nothing.
tests/test_hypr_lua: tests/test_hypr_lua.cpp modules/hypr_lua.hpp
	$(CXX) $(CXXFLAGS) tests/test_hypr_lua.cpp -o $@

# hyprlock panel pinner — pure pin_foreground_monitors() guards that the
# login panel pins to PRIMARY while per-monitor background blocks (inside
# the sentinels) stay untouched. Links personalize.o + libfox-monitor
# (sidecar::Layout, the personalize API's parameter type) + libfox-common (sh::/ui::).
tests/test_hyprlock_pin: tests/test_hyprlock_pin.cpp modules/personalize.o $(FOX_MONITOR_LIB) $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_hyprlock_pin.cpp modules/personalize.o -L$(FOX_MONITOR_DIR) -lfox-monitor -L$(FOX_COMMON_DIR) -lfox-common -o $@

# Claude hook wiring (S10 / S10b, 2026-10-15): merge_hook_entries + restore_theme_wiring on a throwaway fixture
# (a home, a git checkout with .claude/ ignored, a fake workspace), and snapshot_one, moved to core/backup.cpp.
tests/test_claude_wiring: tests/test_claude_wiring.cpp modules/claude_wiring.o core/backup.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_claude_wiring.cpp modules/claude_wiring.o core/backup.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

# NOTE: the pure plan_variants() characterization moved to fox-monitor's own
# test target (tests/test_variants there) when the variant generator became
# the libfox-monitor variants submodule (Slice C2).

# state_checks links the real implementation (not stubs) so the empty-
# manifest paths exercise the actual code. That pulls in shell/ui
# helpers from libfox-common + libcrypto for hash_string.
tests/test_state_checks: tests/test_state_checks.cpp core/state_checks.o core/state_manifest.o core/classifier.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_state_checks.cpp core/state_checks.o core/state_manifest.o core/classifier.o -L$(FOX_COMMON_DIR) -lfox-common -lcrypto -o $@

# conflict_resolve exercises real file-IO (the apply() path); the
# interactive prompt() path is not driven from tests. Links libfox-common
# because the diff invocation goes through sh::run.
tests/test_conflict_resolve: tests/test_conflict_resolve.cpp core/conflict_resolve.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_conflict_resolve.cpp core/conflict_resolve.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

# wizard tests the data types + default_plan (pure logic). Step 9
# adds the interactive run() body, which isn't unit-tested. The link
# pulls classifier + conflict_resolve in because wizard's structs
# embed their types.
tests/test_wizard: tests/test_wizard.cpp core/wizard.o core/classifier.o core/conflict_resolve.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_wizard.cpp core/wizard.o core/classifier.o core/conflict_resolve.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

# install_lock — POSIX flock + lockfile path resolution. No fox-common
# dependency; pure libc plus filesystem.
tests/test_install_lock: tests/test_install_lock.cpp core/install_lock.o
	$(CXX) $(CXXFLAGS) tests/test_install_lock.cpp core/install_lock.o -o $@

# subprocess_log — fox-common's stderr-log sink, exercised end-to-end
# through sh::run/capture. Links libfox-common because that's where
# the implementation now lives.
tests/test_subprocess_log: tests/test_subprocess_log.cpp $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_subprocess_log.cpp -L$(FOX_COMMON_DIR) -lfox-common -o $@

# banner_font — pure glyph table + constructor. No deps beyond libstdc++.
tests/test_dry_run: tests/test_dry_run.cpp modules/vault.o $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) tests/test_dry_run.cpp modules/vault.o -L$(FOX_COMMON_DIR) -lfox-common -o $@

tests/test_health_boot: tests/test_health_boot.cpp modules/foxml_health_boot_script.hpp $(FOX_COMMON_LIB)
	$(CXX) $(CXXFLAGS) -DBUILD_DIR='"$(CURDIR)/tests"' tests/test_health_boot.cpp -L$(FOX_COMMON_DIR) -lfox-common -o $@

tests/test_hidepid: tests/test_hidepid.cpp modules/hidepid_check.hpp
	$(CXX) $(CXXFLAGS) tests/test_hidepid.cpp -o $@

tests/test_built_tools: tests/test_built_tools.cpp core/built_tools.hpp
	$(CXX) $(CXXFLAGS) -DBUILD_DIR='"$(CURDIR)/tests"' tests/test_built_tools.cpp -o $@

tests/test_git_clone: tests/test_git_clone.cpp core/git_clone.hpp
	$(CXX) $(CXXFLAGS) -DBUILD_DIR='"$(CURDIR)/tests"' tests/test_git_clone.cpp -o $@

tests/test_hw_autoenable: tests/test_hw_autoenable.cpp core/hw_autoenable.hpp
	$(CXX) $(CXXFLAGS) tests/test_hw_autoenable.cpp -o $@

tests/test_banner_font: tests/test_banner_font.cpp modules/banner_font.o
	$(CXX) $(CXXFLAGS) tests/test_banner_font.cpp modules/banner_font.o -o $@

clean:
	@rm -f $(BIN) $(CORE_OBJ) $(MODULE_OBJ) $(MAIN_OBJ) $(patsubst %.cpp,%,$(wildcard tests/test_*.cpp))
	@rm -f $(CORE_OBJ:.o=.d) $(MODULE_OBJ:.o=.d) $(MAIN_OBJ:.o=.d)

.PHONY: all install clean test
