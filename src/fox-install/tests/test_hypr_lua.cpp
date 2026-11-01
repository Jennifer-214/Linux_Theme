// Unit test for modules/hypr_lua.hpp — the Hyprland 0.57 (Lua-only) helpers.
// Locks: version parsing + the Lua threshold, the generated monitors/nvidia
// conversions (incl. transform, fallback, commented AQ_DRM_DEVICES), the
// workspace pin line, and which greetd config.toml bodies the installer may
// rewrite (stock + its own old commands yes; a hand-edited command never).

#include "../modules/hypr_lua.hpp"

#include <cstdio>
#include <filesystem>
#include <string>
#include <unistd.h>

namespace {

int failed = 0;

void check(const char* name, bool ok) {
    if (!ok) {
        std::printf("FAIL: %s\n", name);
        ++failed;
    }
}

bool has(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

}  // namespace

int main() {
    using namespace fox_install::hypr_lua;

    // ── version → format ────────────────────────────────────────────────
    {
        Version v = parse_version("Hyprland 0.57.0 built from branch v0.57.0 at commit 0aa6745 clean");
        check("parse 0.57.0", v.major == 0 && v.minor == 57 && v.patch == 0);
        check("0.57 reads Lua only", reads_lua_only(v));
        check("0.56.2 reads hyprlang",
              !reads_lua_only(parse_version("Hyprland 0.56.2 built from branch v0.56.2")));
        check("0.58 reads Lua only", reads_lua_only(parse_version("Hyprland 0.58.1 built")));
        check("1.0 reads Lua only", reads_lua_only(parse_version("Hyprland 1.0.0")));
        check("garbage is unknown", !parse_version("command not found").known());
        check("unknown defaults to Lua", reads_lua_only(parse_version("")));
    }

    // ── monitors.conf → monitors.lua ───────────────────────────────────
    {
        check("plain monitor",
              monitor_line_to_lua("monitor = eDP-1, preferred, 0x0, 1") ==
              "hl.monitor({ output = \"eDP-1\", mode = \"preferred\", position = \"0x0\", scale = 1 })");
        check("rotated + scaled",
              monitor_line_to_lua("monitor = DP-2, preferred, -1728x-996, 1.25, transform, 3") ==
              "hl.monitor({ output = \"DP-2\", mode = \"preferred\", position = \"-1728x-996\", scale = 1.25, transform = 3 })");
        check("fallback rule",
              monitor_line_to_lua("monitor = , preferred, auto, 1") ==
              "hl.monitor({ output = \"\", mode = \"preferred\", position = \"auto\", scale = 1 })");
        check("non-numeric scale quoted",
              has(monitor_line_to_lua("monitor = , preferred, auto, auto"), "scale = \"auto\""));
        check("disable",
              monitor_line_to_lua("monitor = HDMI-A-1, disable") ==
              "hl.monitor({ output = \"HDMI-A-1\", disabled = true })");
        check("not a monitor line", monitor_line_to_lua("env = A, b").empty());
        check("monitorx is not a monitor line", monitor_line_to_lua("monitorx = a, b, c, d").empty());

        const std::string conf =
            "# Generated — re-run to reconfigure.\n"
            "\n"
            "monitor = eDP-1, preferred, 0x0, 1\n"
            "monitor = HDMI-A-1, preferred, 1920x-420, 1, transform, 3\n"
            "    # indented comment\n"
            "monitor = , preferred, auto, 1\n";
        const std::string lua = generated_conf_to_lua(conf);
        check("comment carried", has(lua, "-- Generated — re-run to reconfigure.\n"));
        check("indented comment carried", has(lua, "    -- indented comment\n"));
        check("blank line kept", has(lua, "\n\nhl.monitor"));
        check("three monitors", has(lua, "output = \"eDP-1\"") && has(lua, "output = \"HDMI-A-1\"") &&
                                has(lua, "output = \"\""));
        check("no leftover hyprlang", !has(lua, "monitor ="));
        check("unknown line kept as comment",
              generated_conf_to_lua("bogus line\n") == "-- (not converted) bogus line\n");
    }

    // ── nvidia.conf → nvidia.lua ───────────────────────────────────────
    {
        check("env line", env_line_to_lua("env = LIBVA_DRIVER_NAME, nvidia") ==
                          "hl.env(\"LIBVA_DRIVER_NAME\", \"nvidia\")");
        check("commented env stays commented",
              env_line_to_lua("# env = AQ_DRM_DEVICES, /dev/dri/card1:/dev/dri/card0") ==
              "-- hl.env(\"AQ_DRM_DEVICES\", \"/dev/dri/card1:/dev/dri/card0\")");
        const std::string lua = generated_conf_to_lua(
            "# Nvidia\n"
            "env = AQ_DRM_DEVICES, /dev/dri/by-path/pci-0000:01:00.0-card\n"
            "env = WLR_NO_HARDWARE_CURSORS, 1\n");
        check("active AQ line", has(lua, "hl.env(\"AQ_DRM_DEVICES\", \"/dev/dri/by-path/pci-0000:01:00.0-card\")\n"));
        check("numeric value quoted", has(lua, "hl.env(\"WLR_NO_HARDWARE_CURSORS\", \"1\")"));
        check("placeholder is comment-only", std::string(nvidia_lua_placeholder()).rfind("-- ", 0) == 0);
    }

    // ── workspace pin ──────────────────────────────────────────────────
    check("pin line", workspace_pin_lua("eDP-1") ==
                      "hl.workspace_rule({ workspace = \"1\", monitor = \"eDP-1\", default = true })");
    check("pin escapes quotes", has(workspace_pin_lua("a\"b"), "\"a\\\"b\""));

    // ── greetd config.toml ─────────────────────────────────────────────
    {
        auto toml = [](const std::string& cmd) {
            return "[terminal]\nvt = 1\n[default_session]\ncommand = \"" + cmd + "\"\nuser = \"greeter\"\n";
        };
        check("missing → write", greeter_toml_action("", false) == GreeterToml::Write);
        check("stock agreety → write",
              greeter_toml_action(toml("agreety --cmd /bin/sh"), true) == GreeterToml::Write);
        check("old .conf command → write",
              greeter_toml_action(toml("Hyprland -c /etc/greetd/hyprland.conf"), true) == GreeterToml::Write);
        check("hand-switched .lua command → write",
              greeter_toml_action(toml("Hyprland -c /etc/greetd/hyprland.lua"), true) == GreeterToml::Write);
        check("launcher → already",
              greeter_toml_action(toml("/etc/greetd/start-greeter.sh"), true) == GreeterToml::AlreadyLauncher);
        check("custom command → keep",
              greeter_toml_action(toml("cage -s -- regreet"), true) == GreeterToml::Keep);
        check("custom Hyprland flags → keep",
              greeter_toml_action(toml("Hyprland -c /etc/greetd/mine.conf"), true) == GreeterToml::Keep);
        check("no command line → keep", greeter_toml_action("[terminal]\nvt = 1\n", true) == GreeterToml::Keep);
        check("verify ok", verify_output_ok("======== Config parsing result:\n\nconfig ok\n"));
        check("verify error", !verify_output_ok("hyprland.lua:2: unexpected symbol near '#'"));
    }

    // ── Lua twins of per-machine modules (existing users moving to 0.57) ──
    {
        namespace fs = std::filesystem;
        const fs::path dir = fs::temp_directory_path() / ("fox_hypr_lua_" + std::to_string(::getpid()));
        fs::create_directories(dir);
        const std::string fallback = "-- generic\n";
        check("no .conf → fallback", lua_twin_body(dir / "monitors.conf", fallback) == fallback);

        write_text_atomic(dir / "monitors.conf",
                          "monitor = eDP-1, preferred, 0x0, 1\nmonitor = DP-2, preferred, -1728x-996, 1.25, transform, 3\n");
        const std::string mon = lua_twin_body(dir / "monitors.conf", fallback);
        check("existing layout converted, not replaced",
              has(mon, "output = \"DP-2\"") && has(mon, "transform = 3") && !has(mon, "generic"));

        const std::string placeholder = "# nvidia.conf: nothing here\n";
        write_text_atomic(dir / "nvidia.conf", placeholder);
        check("placeholder .conf → fallback", lua_twin_body(dir / "nvidia.conf", fallback, placeholder) == fallback);
        write_text_atomic(dir / "nvidia.conf", "env = AQ_DRM_DEVICES, /dev/dri/card1\n");
        check("real nvidia setup converted",
              lua_twin_body(dir / "nvidia.conf", fallback, placeholder) ==
              "hl.env(\"AQ_DRM_DEVICES\", \"/dev/dri/card1\")\n");
        check("atomic write leaves no temp file", !fs::exists(dir / "nvidia.conf.foxin.tmp"));
        fs::remove_all(dir);
    }

    if (failed == 0) std::printf("test_hypr_lua: OK\n");
    return failed ? 1 : 0;
}
