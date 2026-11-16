// modules/ssh_apply.hpp — how ssh_harden changes sshd without locking anyone out. The new drop-in is written and
// checked with `sshd -t` before sshd is touched; sshd reloads, and must then answer on the new port. A drop-in that
// turns passwords off is kept only if a key logs in on the new port after the reload — whatever the caller decided,
// so no path writes keys-only on trust. Any failure puts the previous drop-in back (or removes ours when there was
// none) and restarts sshd on it, then proves the old port answers again. The steps are injected, so
// tests/test_ssh_apply drives every path, the revert included, without a system call.
#pragma once

#include <functional>
#include <optional>
#include <sstream>
#include <string>

namespace desk_install::ssh_apply {

struct Steps {
    std::function<bool(const std::string&)> write;   // the drop-in gets this text
    std::function<bool()> remove;                    // the drop-in goes: there was none before
    std::function<bool()> check;                     // sudo sshd -t
    std::function<bool()> reload;                    // systemctl reload sshd
    std::function<bool()> restart;                   // sshd restarted, even from failed, on the file now in place
    std::function<bool()> answers;                   // sshd answers on the new config's ports
    std::function<bool()> key_logs_in;               // a key logs in on the new port (BatchMode, publickey only)
    std::function<bool()> answers_before;            // the restored config answers on the old port
};

enum class Result {
    Applied,       // written, checked, reloaded and proven; or written and checked while sshd is not running
    Unproven,      // keys-only with sshd not running: no key can log in to prove it, so nothing was written
    WriteFailed,   // the new file was not written: nothing changed
    Refused,       // sshd -t refused it: the previous file is back, the running sshd untouched
    Reverted,      // the reload or the proof failed: the previous file is back, sshd restarted and answering on it
    Stuck,         // the previous file could not be put back, or sshd did not come back on it: the console it is
};

// The drop-in turns password login off (`PasswordAuthentication no`, the key in any case, as sshd reads it).
inline bool keys_only(const std::string& text) {
    std::istringstream in(text);
    for (std::string line; std::getline(in, line);) {
        std::istringstream f(line);
        std::string key, value;
        if (!(f >> key >> value)) continue;
        for (auto& c : key) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c);
        if (key == "passwordauthentication") return value == "no";
    }
    return false;
}

// `before`: the drop-in as it was (nullopt: there was none). `running`: sshd is active, so it is reloaded and proven.
// `key_before`: a key logged in before the change, so one must log in after it too.
inline Result apply(const std::optional<std::string>& before, const std::string& next, bool running, bool key_before,
                    const Steps& s) {
    const auto restore = [&] { return before ? s.write(*before) : s.remove(); };
    if (!running && keys_only(next)) return Result::Unproven;
    if (!s.write(next)) return Result::WriteFailed;
    if (!s.check()) return restore() ? Result::Refused : Result::Stuck;
    if (!running) return Result::Applied;
    const bool need_key = key_before || keys_only(next);
    if (s.reload() && s.answers() && (!need_key || s.key_logs_in())) return Result::Applied;
    if (!restore() || !s.restart() || !s.answers_before()) return Result::Stuck;
    return Result::Reverted;
}

}  // namespace desk_install::ssh_apply
