// ssh_harden's apply (modules/ssh_apply.hpp): the steps are stand-ins that record what ran and answer as scripted,
// so every path is driven without a system call — above all the revert, which puts the previous drop-in back and
// restarts sshd when the new port does not prove itself, and the rule that a keys-only drop-in stays only after a
// key has logged in on the new port, whatever the caller believed.
#include "../modules/ssh_apply.hpp"

#include <cstdio>
#include <string>
#include <vector>

using namespace desk_install::ssh_apply;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}

const std::string KEYS = "Port 4022\nPasswordAuthentication no\n";    // keys only
const std::string PASS = "Port 4022\nPasswordAuthentication yes\n";   // passwords on
const std::string OLD = "Port 22\nPasswordAuthentication yes\n";

struct Rig {
    std::vector<std::string> ran;
    std::string file = OLD;
    bool exists = true;
    bool write_ok = true, reload_ok = true, restart_ok = true, answers_ok = true, key_ok = true, before_ok = true;
    // sshd -t passes for any file but BAD; a restored file passes, as it did when sshd started on it.
    Steps steps() {
        Steps s;
        s.write = [this](const std::string& t) {
            ran.push_back(t == OLD ? "write old" : "write new");
            if (!write_ok) return false;
            file = t;
            exists = true;
            return true;
        };
        s.remove = [this] { ran.push_back("remove"); exists = false; return true; };
        s.check = [this] { ran.push_back("check"); return file != "BAD"; };
        s.reload = [this] { ran.push_back("reload"); return reload_ok; };
        s.restart = [this] { ran.push_back("restart"); return restart_ok; };
        s.answers = [this] { ran.push_back("answers"); return answers_ok; };
        s.key_logs_in = [this] { ran.push_back("key"); return key_ok; };
        s.answers_before = [this] { ran.push_back("answers_before"); return before_ok; };
        return s;
    }
};

using V = std::vector<std::string>;

int main() {
    {
        Rig r;
        expect(apply(OLD, KEYS, true, true, r.steps()) == Result::Applied, "keys only, a key logs in after: applied");
        expect((r.ran == V{"write new", "check", "reload", "answers", "key"}), "checked before the reload, proven after");
        expect(r.file == KEYS, "the new file stays");
    }
    {
        Rig r;
        r.key_ok = false;
        expect(apply(OLD, KEYS, true, true, r.steps()) == Result::Reverted, "keys only, no key login after: reverted");
        expect((r.ran == V{"write new", "check", "reload", "answers", "key", "write old", "restart", "answers_before"}),
               "the previous file back, sshd restarted on it, the old port proven");
        expect(r.file == OLD, "passwords are back on: the old file is in place");
    }
    {
        Rig r;
        r.key_ok = false;
        expect(apply(OLD, KEYS, true, /*key_before=*/false, r.steps()) == Result::Reverted,
               "a caller that wrote keys only without a key test still gets the key login asked, and the revert");
        expect(r.file == OLD, "so keys only never stays on trust");
    }
    {
        Rig r;
        expect(apply(OLD, PASS, true, false, r.steps()) == Result::Applied, "passwords on, no key known: applied");
        expect((r.ran == V{"write new", "check", "reload", "answers"}), "sshd answering is the proof; no key is asked");
    }
    {
        Rig r;
        r.key_ok = false;
        expect(apply(OLD, PASS, true, /*key_before=*/true, r.steps()) == Result::Reverted,
               "a key logged in before the move and not after it: reverted, even with passwords on");
    }
    {
        Rig r;
        expect(apply(OLD, "BAD", true, true, r.steps()) == Result::Refused, "sshd -t refuses: refused");
        expect((r.ran == V{"write new", "check", "write old"}), "the previous file back, sshd never reloaded");
        expect(r.file == OLD, "the old file is in place");
    }
    {
        Rig r;
        r.answers_ok = false;
        expect(apply(OLD, PASS, true, false, r.steps()) == Result::Reverted, "no answer on the new port: reverted");
        expect((r.ran == V{"write new", "check", "reload", "answers", "write old", "restart", "answers_before"}),
               "no key is asked of a port that does not answer");
    }
    {
        Rig r;
        r.reload_ok = false;
        expect(apply(OLD, PASS, true, false, r.steps()) == Result::Reverted, "a failed reload reverts too");
        expect((r.ran == V{"write new", "check", "reload", "write old", "restart", "answers_before"}),
               "no proof is asked of a reload that failed");
    }
    {
        Rig r;
        r.answers_ok = false;
        expect(apply(std::nullopt, PASS, true, false, r.steps()) == Result::Reverted, "no drop-in before: reverted");
        expect((r.ran == V{"write new", "check", "reload", "answers", "remove", "restart", "answers_before"}),
               "ours is removed, not left behind");
        expect(!r.exists, "no drop-in afterwards, as before");
    }
    {
        Rig r;
        r.answers_ok = false;
        r.before_ok = false;
        expect(apply(OLD, PASS, true, false, r.steps()) == Result::Stuck,
               "the old port does not come back either: stuck, so the module sends you to the console");
    }
    {
        Rig r;
        r.answers_ok = false;
        r.restart_ok = false;
        expect(apply(OLD, PASS, true, false, r.steps()) == Result::Stuck, "sshd does not restart: stuck");
    }
    {
        Rig r;
        r.write_ok = false;
        expect(apply(OLD, PASS, true, false, r.steps()) == Result::WriteFailed, "a failed write: nothing changed");
        expect((r.ran == V{"write new"}), "and nothing else ran");
    }
    {
        Rig r;
        expect(apply(OLD, PASS, false, false, r.steps()) == Result::Applied, "sshd not running: written, checked");
        expect((r.ran == V{"write new", "check"}), "not started, not reloaded: sshd stays off");
    }
    {
        Rig r;
        expect(apply(OLD, KEYS, false, false, r.steps()) == Result::Unproven, "keys only with sshd off: refused");
        expect(r.ran.empty() && r.file == OLD, "nothing written: no key could log in to prove it");
    }
    expect(keys_only(KEYS) && !keys_only(PASS) && !keys_only("") && keys_only("passwordauthentication  no\n")
           && !keys_only("# PasswordAuthentication no\nPasswordAuthentication yes\n"), "what turns passwords off");

    if (failures == 0) std::printf("test_ssh_apply: ok\n");
    return failures == 0 ? 0 : 1;
}
