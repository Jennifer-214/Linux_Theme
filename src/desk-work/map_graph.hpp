// The project map's graph, the parts that only compute: reading a disassembly, merging what the readers found, and
// answering the queries. Kept out of desk-work's records code so tests/test_map.cpp can include it alone.
//
// One shape throughout, the one a project's own graph tool prints (docs/agent-workflows.md, "Project map"):
// { version, nodes: [{ id, label, file, line, kind, detail? }], edges: [{ from, to, kind }], complete, why? }. An
// edge's kind says who found it: call (objdump: exact after inlining, for what was compiled), call-by-name
// (treesitter: overloads, macros and virtual dispatch are not resolved), contains (a class and its methods).
#ifndef DESK_WORK_MAP_GRAPH_HPP
#define DESK_WORK_MAP_GRAPH_HPP
#include "json.hpp"
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace desk_map {
using J = nlohmann::json;

// Text with each byte that is not part of a whole UTF-8 character replaced by U+FFFD (2026-11-19: the syntax reader
// cut a → in half in one call's arguments, the answer did not parse, and the trader's whole map was dropped for it;
// the reader cuts at characters now, and an answer it cannot vouch for still reads, a character at most lost).
inline std::string utf8_clean(const std::string& in) {
    std::string out;
    out.reserve(in.size());
    const auto* s = reinterpret_cast<const unsigned char*>(in.data());
    const size_t n = in.size();
    for (size_t i = 0; i < n;) {
        const unsigned char c = s[i];
        size_t len = c < 0x80 ? 1 : (c >= 0xC2 && c < 0xE0) ? 2 : (c >= 0xE0 && c < 0xF0) ? 3 : (c >= 0xF0 && c < 0xF5) ? 4 : 0;
        bool ok = len > 0 && i + len <= n;
        for (size_t k = 1; ok && k < len; ++k) ok = (s[i + k] & 0xC0) == 0x80;
        // no overlong 3-byte forms, no surrogates, nothing past U+10FFFF
        if (ok && len == 3) ok = !(c == 0xE0 && s[i + 1] < 0xA0) && !(c == 0xED && s[i + 1] >= 0xA0);
        if (ok && len == 4) ok = !(c == 0xF0 && s[i + 1] < 0x90) && !(c == 0xF4 && s[i + 1] >= 0x90);
        if (ok) { out.append(in, i, len); i += len; continue; }
        // one U+FFFD for the broken piece: its lead byte and the continuation bytes that follow it (a cut → is one)
        size_t k = 1;
        while (len > 1 && k < len && i + k < n && (s[i + k] & 0xC0) == 0x80) ++k;
        out += "\xef\xbf\xbd";
        i += k;
    }
    return out;
}

inline std::string text(const J& j, const char* key) {
    const auto it = j.find(key);
    return it != j.end() && it->is_string() ? it->get<std::string>() : std::string();
}
inline long long number(const J& j, const char* key, long long fallback = 0) {
    const auto it = j.find(key);
    return it != j.end() && it->is_number_integer() ? it->get<long long>() : fallback;
}
// A count the reader gives ("how many more it left out"): a whole number, at most a million; 0 otherwise.
inline long long count_of(const J& j, const char* key) { return std::clamp(number(j, key), 0LL, 1000000LL); }
inline bool ends_with(const std::string& s, const std::string& tail) {
    return s.size() >= tail.size() && s.compare(s.size() - tail.size(), tail.size(), tail) == 0;
}
inline bool flag(const J& j, const char* key, bool fallback) {
    const auto it = j.find(key);
    return it != j.end() && it->is_boolean() ? it->get<bool>() : fallback;
}
inline const J& list(const J& j, const char* key) {
    static const J empty = J::array();
    const auto it = j.find(key);
    return it != j.end() && it->is_array() ? *it : empty;
}
inline bool call_kind(const std::string& kind) { return kind == "call" || kind == "call-by-name"; }
// A handoff (the syntax reader's: a push to a pop on one object, a function passed by name, a call through a function
// pointer set): no call between the two, yet what one gives the other takes. Walked like a call; said as what it is.
inline bool walked_kind(const std::string& kind) { return call_kind(kind) || kind == "handoff"; }

// ─── names ──────────────────────────────────────────────────────────────────────────────────────────────────────
// A copy the compiler made of a function (its cold part, a specialised or partial copy) is that function:
// "f.cold", "f.isra.0", "f.part.1.cold", "Q::f(int) [clone .constprop.0]" are all f.
inline std::string strip_clones(std::string s) {
    static const std::vector<std::string> marks{".cold", ".part", ".isra", ".constprop", ".lto_priv", ".localalias",
                                                ".llvm", ".specialized", ".clone"};
    for (bool again = true; again && !s.empty();) {
        again = false;
        const auto bracket = s.rfind(" [clone ");
        if (bracket != std::string::npos && s.back() == ']') { s.erase(bracket); again = true; continue; }
        auto end = s.size();
        while (end > 0 && std::isdigit(static_cast<unsigned char>(s[end - 1]))) --end;
        const auto bare = end < s.size() && end > 0 && s[end - 1] == '.' ? s.substr(0, end - 1) : s;
        for (const auto& mark : marks)
            if (bare.size() > mark.size() && ends_with(bare, mark)) { s = bare.substr(0, bare.size() - mark.size()); again = true; break; }
    }
    return s;
}

// The name both readers can agree on: no parameters, template arguments, return type, ABI tag or anonymous
// namespace. "void fox::Queue<int>::push(int) const" and treesitter's "fox::Queue::push" meet at fox::Queue::push;
// a lambda inside f keeps its place, f()::{lambda()#1}::operator(), so it never meets f.
inline std::string match_key(std::string s) {
    s = strip_clones(s);
    for (size_t at; (at = s.find("[abi:")) != std::string::npos;) {
        const auto close = s.find(']', at);
        if (close == std::string::npos) break;
        s.erase(at, close - at + 1);
    }
    // A method's qualifiers after its parameters, then the parameters: the "(" that closes at the last ")".
    for (bool again = true; again;) {
        again = false;
        for (const char* tail : {" const", " volatile", " &&", " &", " noexcept"})
            if (ends_with(s, tail)) { s.erase(s.size() - std::string(tail).size()); again = true; }
    }
    if (!s.empty() && s.back() == ')' && !ends_with(s, "operator()")) {
        int depth = 0;
        for (size_t i = s.size(); i-- > 0;) {
            if (s[i] == ')') ++depth;
            else if (s[i] == '(' && --depth == 0) { if (i > 0) s.erase(i); break; }
        }
    }
    // Parameters left inside the name (the function a lambda sits in) become "()"; template arguments go, but not
    // the brackets of an operator's own name (operator(), operator<<, operator->, operator[]).
    std::string out;
    int round = 0, angle = 0;
    for (size_t i = 0; i < s.size(); ++i) {
        const char c = s[i];
        if (round == 0 && angle == 0 && s.compare(i, 8, "operator") == 0
            && (i == 0 || (!std::isalnum(static_cast<unsigned char>(s[i - 1])) && s[i - 1] != '_'))) {
            size_t j = i + 8;
            if (s.compare(j, 2, "()") == 0 || s.compare(j, 2, "[]") == 0) j += 2;
            else while (j < s.size() && std::string("<>=!+-*/%^&|~,").find(s[j]) != std::string::npos) ++j;
            out += s.substr(i, j - i);
            i = j - 1;
            continue;
        }
        if (c == '<' && round == 0) { ++angle; continue; }
        if (c == '>' && round == 0 && angle > 0) { --angle; continue; }
        if (angle > 0) continue;
        if (c == '(' && s.compare(i, 21, "(anonymous namespace)") == 0) { out += "(anonymous namespace)"; i += 20; continue; }
        if (c == '(') { if (round++ == 0) out += "()"; continue; }
        if (c == ')') { if (round > 0) --round; continue; }
        if (round == 0) out += c;
    }
    s = out;
    for (size_t at; (at = s.find("(anonymous namespace)::")) != std::string::npos;) s.erase(at, 23);
    // A return type before the name (function templates are demangled with one): what follows the last space
    // outside brackets, and before an operator's name.
    const auto named = s.find("operator");
    size_t space = std::string::npos;
    int depth = 0;
    for (size_t i = 0; i < s.size() && (named == std::string::npos || i < named); ++i) {
        if (s[i] == '(' || s[i] == '{' || s[i] == '[') ++depth;
        else if ((s[i] == ')' || s[i] == '}' || s[i] == ']') && depth > 0) --depth;
        else if (s[i] == ' ' && depth == 0) space = i;
    }
    if (space != std::string::npos) s = s.substr(space + 1);
    while (!s.empty() && s.back() == ' ') s.pop_back();
    return s;
}

// The checkout's parts: a top-level folder, or the folder inside one that only holds parts (src/desk-work, lua/desk).
// With no file: (library) for library calls and the C++ runtime's code compiled in (std::, __gnu_cxx::), (binary)
// for the rest of what only the binary has.
inline std::string module_of(const std::string& file, const std::string& id = {}) {
    if (file.empty()) {
        for (const char* lib : {"ext:", "bin:std::", "bin:__gnu_cxx::", "bin:__cxxabiv1::"}) if (id.rfind(lib, 0) == 0) return "(library)";
        return "(binary)";
    }
    static const std::set<std::string> holders{"src", "source", "sources", "lib", "libs", "pkg", "pkgs", "packages",
                                               "apps", "crates", "modules", "components", "internal", "cmd", "include",
                                               "lua", "shared", "plugins", "services"};
    const auto slash = file.find('/');
    if (slash == std::string::npos) return "(top level)";
    const auto top = file.substr(0, slash);
    const auto next = file.find('/', slash + 1);
    if (holders.count(top) && next != std::string::npos) return file.substr(0, next);
    return top;
}

// ─── the binary reader: objdump -d --no-show-raw-insn --demangle ───────────────────────────────────────────────
// Nodes are the functions the binary defines (clones folded into their function); edges are its direct calls and
// bare tail jumps to another function. A call through the PLT or the GOT ends at a library leaf (ext:name), an
// indirect call at one shared leaf (ext:(indirect)): what they reach is not in this binary.
class Objdump {
public:
    void line(const std::string& raw) {
        std::string l = raw;
        while (!l.empty() && (l.back() == '\r' || l.back() == ' ')) l.pop_back();
        if (l.rfind("Disassembly of section ", 0) == 0) {
            section_ = l.substr(23);
            if (!section_.empty() && section_.back() == ':') section_.pop_back();
            current_ = -1;
            return;
        }
        // "0000000000001139 <main>:"
        if (!l.empty() && std::isxdigit(static_cast<unsigned char>(l[0])) && l.back() == ':') {
            const auto open = l.find(" <");
            if (open != std::string::npos && l.size() > open + 3 && l[l.size() - 2] == '>') {
                const auto addr = hex(l.substr(0, open));
                const auto name = l.substr(open + 2, l.size() - open - 4);
                start(addr, name);
                return;
            }
        }
        if (current_ < 0) return;
        // With -l (a binary with debug info): "main():" names the function, then "/src/prog.c:9" (perhaps with
        // " (discriminator 1)") where its first instruction is; the first of them is where the function is.
        if (!l.empty() && l[0] != ' ' && l[0] != '\t') {
            if (ends_with(l, "():") || !fns_[static_cast<size_t>(current_)].file.empty()) return;
            auto place = l;
            const auto note = place.find(" (discriminator ");
            if (note != std::string::npos) place.erase(note);
            const auto at = place.rfind(':');
            if (at == std::string::npos || at == 0 || at + 1 >= place.size()) return;
            long line = 0;
            for (size_t i = at + 1; i < place.size(); ++i) {
                if (!std::isdigit(static_cast<unsigned char>(place[i]))) return;
                line = line * 10 + (place[i] - '0');
            }
            fns_[static_cast<size_t>(current_)].file = place.substr(0, at);
            fns_[static_cast<size_t>(current_)].line = line;
            return;
        }
        // "    113d:\tcall   1149 <helper>"; with raw bytes shown ("e8 07 00 00 00 \tcall ...") they come first.
        const auto colon = l.find(":\t");
        if (colon == std::string::npos) return;
        auto insn = l.substr(colon + 2);
        const auto tab = insn.find('\t');
        if (tab != std::string::npos && raw_bytes(insn.substr(0, tab))) insn = insn.substr(tab + 1);
        instruction(insn);
    }
    size_t functions() const { return fns_.size(); }
    bool any_text() const { return text_sections_ > 0; }

    // The graph, in the plan's shape, plus a short count of what was read.
    J graph() const {
        std::vector<size_t> order;
        for (size_t i = 0; i < fns_.size(); ++i) if (!fns_[i].plt && !fns_[i].skip) order.push_back(i);
        std::sort(order.begin(), order.end(), [&](size_t a, size_t b) { return fns_[a].addr < fns_[b].addr; });
        // One node per function, a clone folded into the function it was made from (the nearest one before it); when
        // only copies are left (f.isra.0 and its cold part), into the hot copy.
        std::map<std::string, std::vector<size_t>> plain, copies;
        for (auto i : order) (fns_[i].clone ? copies : plain)[fns_[i].base].push_back(i);
        std::vector<size_t> owner(fns_.size());
        for (auto i : order) {
            owner[i] = i;
            if (!fns_[i].clone) continue;
            const auto& same = plain[fns_[i].base];
            if (!same.empty()) {
                owner[i] = same.front();
                for (auto s : same) if (fns_[s].addr <= fns_[i].addr) owner[i] = s;
                continue;
            }
            const auto& kin = copies[fns_[i].base];
            const auto hot = std::find_if(kin.begin(), kin.end(), [&](size_t k) { return !fns_[k].cold; });
            owner[i] = hot != kin.end() ? *hot : kin.front();
        }
        // Labelled by the name both readers share (fox::Queue::push); the id adds what tells two apart: a hash of
        // the full signature for overloads, the address for two static functions with one signature.
        std::map<std::string, std::set<std::string>> fulls;
        std::map<std::string, int> per_full;
        for (auto i : order) if (owner[i] == i) { fulls[match_key(fns_[i].base)].insert(fns_[i].base); ++per_full[fns_[i].base]; }
        const auto hexs = [](uint64_t v) { std::ostringstream o; o << std::hex << v; return o.str(); };
        // what each function's symbol is, and the compiler's copies folded into it (Codex's #15: why a function seen in
        // the source is not a box of its own in the binary)
        std::map<size_t, std::vector<std::string>> folded;
        for (auto i : order) if (owner[i] != i && folded[owner[i]].size() < 16) folded[owner[i]].push_back(fns_[i].symbol);
        std::vector<std::string> node_of(fns_.size());
        J nodes = J::array();
        std::set<std::string> made;
        for (auto i : order) {
            const auto& f = fns_[owner[i]];
            const auto key = match_key(f.base);
            std::string id = "bin:" + key;
            if (per_full[f.base] > 1) id += "@" + hexs(f.addr);
            else if (fulls[key].size() > 1) id += "#" + hexs(std::hash<std::string>{}(f.base) & 0xffffffffu);
            node_of[i] = id;
            if (!made.insert(id).second) continue;
            J node{{"id", id}, {"label", key}, {"file", nullptr}, {"line", nullptr}, {"kind", "function"}};
            if (!f.file.empty()) { node["file"] = f.file; node["line"] = f.line; }
            J clones = J::array();
            for (const auto& c : folded[owner[i]]) clones.push_back(c);
            node["binary"] = J{{"symbol", f.symbol.substr(0, 200)}, {"clones", clones}};
            nodes.push_back(node);
        }
        // Every label, the skipped ones too: a call into start-up code is dropped, never pinned on the label before it.
        std::map<uint64_t, size_t> at;
        for (size_t i = 0; i < fns_.size(); ++i) if (!at.count(fns_[i].addr) || at[fns_[i].addr] == i || fns_[at[fns_[i].addr]].skip) at[fns_[i].addr] = i;
        std::set<std::pair<std::string, std::string>> seen;
        J edges = J::array();
        std::set<std::string> leaves;
        long long sites = 0, library = 0, indirect = 0, tail = 0;
        // A library function is one leaf by its name ("operator delete", not each of its signatures).
        const auto leaf = [&](const std::string& raw, const std::string& detail) {
            const auto name = raw == "(indirect)" ? raw : match_key(raw);
            const auto id = "ext:" + name;
            if (leaves.insert(id).second)
                nodes.push_back(J{{"id", id}, {"label", name}, {"file", nullptr}, {"line", nullptr}, {"kind", "function"}, {"detail", detail}});
            return id;
        };
        for (const auto& c : calls_) {
            const auto& from = fns_[c.from];
            if (from.plt || from.skip || node_of[c.from].empty()) continue;
            std::string to;
            if (c.type == 'i') { to = leaf("(indirect)", "indirect calls: the target is not known"); ++indirect; }
            else if (c.type == 'g') { to = leaf(c.sym, "library call (GOT)"); ++library; }
            else {
                // The target by address: a PLT stub is a library leaf; a defined function is its node.
                auto it = at.upper_bound(c.target);
                long target = -1;
                if (it != at.begin()) { --it; target = static_cast<long>(it->second); }
                std::string sym = c.sym;
                const auto plus = sym.find("+0x");
                if (target >= 0 && fns_[static_cast<size_t>(target)].skip) continue;
                if (target >= 0 && fns_[static_cast<size_t>(target)].plt) {
                    to = leaf(fns_[static_cast<size_t>(target)].base, "library call (PLT)"); ++library;
                } else if (ends_with(plus == std::string::npos ? sym : sym.substr(0, plus), "@plt")) {
                    const auto bare = plus == std::string::npos ? sym : sym.substr(0, plus);
                    to = leaf(bare.substr(0, bare.size() - 4), "library call (PLT)"); ++library;
                } else if (target >= 0 && !node_of[static_cast<size_t>(target)].empty()) {
                    // A jump is a tail call only to the start of another function: into its own cold part it is not.
                    if (c.type == 't' && (c.target != fns_[static_cast<size_t>(target)].addr || node_of[static_cast<size_t>(target)] == node_of[c.from])) continue;
                    to = node_of[static_cast<size_t>(target)];
                    if (c.type == 't') ++tail;
                } else continue;
            }
            ++sites;
            if (seen.insert({node_of[c.from], to}).second) edges.push_back(J{{"from", node_of[c.from]}, {"to", to}, {"kind", "call"}});
        }
        return J{{"version", 1}, {"nodes", nodes}, {"edges", edges}, {"complete", true},
                 {"stats", J{{"functions", made.size()}, {"edges", edges.size()}, {"call_sites", sites}, {"library_sites", library},
                             {"indirect_sites", indirect}, {"tail_calls", tail}}}};
    }

private:
    struct Fn { uint64_t addr; std::string base; bool plt, clone, skip, cold; std::string file = {}; long line = 0; std::string symbol = {}; };
    struct Call { size_t from; uint64_t target; std::string sym; char type; };  // c call, t tail jump, i indirect, g GOT
    std::vector<Fn> fns_;
    std::vector<Call> calls_;
    std::string section_;
    long current_ = -1;
    int text_sections_ = 0;
    std::string last_section_;

    // "e8 07 00 00 00" or "94000003": pairs of hex digits, never a lone letter (aarch64's "b" is a mnemonic).
    static bool raw_bytes(const std::string& field) {
        std::istringstream words(field);
        std::string word;
        bool any = false;
        while (words >> word) {
            if (word.size() < 2 || word.size() % 2 != 0) return false;
            for (char c : word) if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
            any = true;
        }
        return any;
    }
    static uint64_t hex(const std::string& s) {
        uint64_t v = 0;
        for (char c : s) {
            if (!std::isxdigit(static_cast<unsigned char>(c))) break;
            v = v * 16 + static_cast<uint64_t>(std::isdigit(static_cast<unsigned char>(c)) ? c - '0' : std::tolower(c) - 'a' + 10);
        }
        return v;
    }
    void start(uint64_t addr, const std::string& name) {
        static const std::set<std::string> startup{"_init", "_fini", "_start", "deregister_tm_clones", "register_tm_clones",
            "__do_global_dtors_aux", "frame_dummy", "__libc_csu_init", "__libc_csu_fini", "_dl_relocate_static_pie"};
        const bool plt = section_.rfind(".plt", 0) == 0 || ends_with(name, "@plt");
        std::string base = name;
        if (ends_with(base, "@plt")) base.erase(base.size() - 4);
        const auto stripped = strip_clones(base);
        const bool text = section_.rfind(".text", 0) == 0;
        if (text && section_ != last_section_) { ++text_sections_; last_section_ = section_; }
        // Section labels (".text"), offsets ("abort@plt-0x10", the PLT's own first entry) and the C runtime's start-up
        // code are no project functions.
        const bool skip = (!plt && !text) || name.empty() || name[0] == '.' || startup.count(stripped)
                          || stripped.rfind("__x86.get_pc_thunk", 0) == 0 || name.find("+0x") != std::string::npos
                          || name.find("-0x") != std::string::npos;
        fns_.push_back(Fn{addr, stripped, plt, stripped != base, skip, name.find(".cold") != std::string::npos});
        fns_.back().symbol = base;   // as linked, its clone marks kept ("f.isra.0", "Q::f(int) [clone .constprop.0]")
        current_ = static_cast<long>(fns_.size() - 1);
    }
    void instruction(const std::string& insn) {
        std::istringstream words(insn);
        std::string word, mnemonic;
        static const std::set<std::string> prefixes{"notrack", "bnd", "rex", "rex.W", "data16", "cs", "ds", "lock", "rep", "repz", "repnz", "addr32"};
        while (words >> word) { if (!prefixes.count(word)) { mnemonic = word; break; } }
        if (mnemonic.empty()) return;
        static const std::set<std::string> calls{"call", "callq", "calll", "bl", "blx"}, jumps{"jmp", "jmpq", "b"};
        const bool is_call = calls.count(mnemonic) > 0, is_jump = jumps.count(mnemonic) > 0;
        if (!is_call && !is_jump && mnemonic != "blr") return;
        std::string rest;
        std::getline(words, rest);
        const auto first = rest.find_first_not_of(" \t");
        rest = first == std::string::npos ? "" : rest.substr(first);
        std::string comment;
        const auto hash = rest.find(" # ");
        if (hash != std::string::npos) { comment = rest.substr(hash + 3); rest = rest.substr(0, hash); }
        while (!rest.empty() && (rest.back() == ' ' || rest.back() == '\t')) rest.pop_back();
        const auto from = static_cast<size_t>(current_);
        if (mnemonic == "blr" || (!rest.empty() && rest[0] == '*')) {
            if (!is_call && mnemonic != "blr") return;   // an indirect jump is a switch table, or a tail call nobody can name
            // A call through the GOT names its target in objdump's comment: "# 3ff0 <puts@GLIBC_2.2.5>".
            const auto open = comment.find('<'), at = comment.find('@', open == std::string::npos ? 0 : open);
            if (open != std::string::npos && at != std::string::npos && comment.find("+0x") == std::string::npos)
                calls_.push_back(Call{from, 0, comment.substr(open + 1, at - open - 1), 'g'});
            else calls_.push_back(Call{from, 0, "", 'i'});
            return;
        }
        // "1149 <helper>", "1149 <Q::push(int) [clone .cold]>"
        const auto space = rest.find(' ');
        if (space == std::string::npos || rest.size() < space + 3 || rest[space + 1] != '<' || rest.back() != '>') return;
        const auto target = hex(rest.substr(0, space));
        const auto sym = rest.substr(space + 2, rest.size() - space - 3);
        if (is_jump && sym.find("+0x") != std::string::npos) return;   // a jump inside a function
        calls_.push_back(Call{from, target, sym, is_call ? 'c' : 't'});
    }
};

// ─── merging the readers ────────────────────────────────────────────────────────────────────────────────────────
inline bool compiled_file(const std::string& file) {
    static const std::vector<std::string> exts{".c", ".h", ".cc", ".cpp", ".cxx", ".c++", ".hpp", ".hh", ".hxx", ".h++", ".ipp", ".inl", ".tpp", ".tcc"};
    for (const auto& e : exts) if (ends_with(file, e)) return true;
    return false;
}

// A provider's answer, kept to what the shape allows: string ids, root-relative files, 1-based lines, edges between
// nodes it has. Anything else is dropped rather than trusted.
inline J clean_graph(const J& raw) {
    J nodes = J::array(), edges = J::array(), spans = J::object();
    std::set<std::string> ids;
    if (raw.is_object() && raw.contains("nodes") && raw["nodes"].is_array()) {
        for (const auto& n : raw["nodes"]) {
            if (!n.is_object()) continue;
            const auto id = text(n, "id"), label = text(n, "label"), kind = text(n, "kind");
            if (id.empty() || id.size() > 1024 || label.empty() || kind.empty() || !ids.insert(id).second) continue;
            J node{{"id", id}, {"label", label.substr(0, 512)}, {"kind", kind.substr(0, 32)}, {"file", nullptr}, {"line", nullptr}};
            const auto file = text(n, "file");
            if (!file.empty() && file[0] != '/' && file.find("..") == std::string::npos && file.find('\n') == std::string::npos) node["file"] = file;
            if (number(n, "line") > 0) node["line"] = number(n, "line");
            if (!text(n, "detail").empty()) node["detail"] = text(n, "detail").substr(0, 200);
            // what it is in the binary read: its linked symbol, the compiler's copies folded into it (at most 16)
            if (n.contains("binary") && n["binary"].is_object() && !text(n["binary"], "symbol").empty()) {
                J clones = J::array();
                for (const auto& c : list(n["binary"], "clones")) if (c.is_string() && clones.size() < 16) clones.push_back(c.get<std::string>().substr(0, 200));
                node["binary"] = J{{"symbol", text(n["binary"], "symbol").substr(0, 200)}, {"clones", clones}};
            }
            // the #if branch it is in, as written, and whether the compile flags turn it on (true / false / unknown)
            if (n.contains("cond") && n["cond"].is_object() && !text(n["cond"], "text").empty()) {
                J cond{{"text", text(n["cond"], "text").substr(0, 120)}};
                if (n["cond"].contains("active") && n["cond"]["active"].is_boolean()) cond["active"] = n["cond"]["active"];
                node["cond"] = cond;
            }
            // the calls of it the reader could not tell apart by name ("send: 2 match"), at most 8
            if (n.contains("ambiguous") && n["ambiguous"].is_array()) {
                J list = J::array();
                for (const auto& a : n["ambiguous"])
                    if (a.is_object() && !text(a, "name").empty() && count_of(a, "count") > 1 && list.size() < 8)
                        list.push_back(J{{"name", text(a, "name").substr(0, 80)}, {"count", count_of(a, "count")}, {"line", count_of(a, "line")}});
                if (!list.empty()) node["ambiguous"] = list;
            }
            // A function's signature, for the trace: its return type and at most 16 parameters, each { name, type as
            // written, pass, dir } with pass and dir from closed sets (the syntax reader's desk.map.passing).
            if (!text(n, "returns").empty()) node["returns"] = text(n, "returns").substr(0, 120);
            if (n.contains("params") && n["params"].is_array()) {
                static const std::set<std::string> passes{"value", "ref", "const ref", "rvalue", "pointer", "const pointer",
                                                           "array", "const array", "smart"};
                J params = J::array();
                for (const auto& p : n["params"]) {
                    if (params.size() >= 16) break;
                    if (!p.is_object() || !passes.count(text(p, "pass")) || (text(p, "dir") != "in" && text(p, "dir") != "inout")) continue;
                    J param{{"name", text(p, "name").substr(0, 64)}, {"type", text(p, "type").substr(0, 120)},
                            {"pass", text(p, "pass")}, {"dir", text(p, "dir")}};
                    // The fields it reads and writes of this parameter (at most 12 each, each at most 80 characters).
                    for (const char* side : {"reads", "writes"}) {
                        if (!p.contains(side) || !p[side].is_array()) continue;
                        J fields = J::array();
                        for (const auto& f : p[side]) if (f.is_string() && fields.size() < 12) fields.push_back(f.get<std::string>().substr(0, 80));
                        param[side] = fields;
                    }
                    // How many more the reader left out ("12 shown · more omitted" beside the list).
                    for (const char* more : {"reads_more", "writes_more"}) if (count_of(p, more) > 0) param[more] = count_of(p, more);
                    params.push_back(param);
                }
                node["params"] = params;
                if (count_of(n, "params_more") > 0) node["params_more"] = count_of(n, "params_more");
            }
            nodes.push_back(node);
        }
    }
    if (raw.is_object() && raw.contains("edges") && raw["edges"].is_array())
        for (const auto& e : raw["edges"]) {
            if (!e.is_object() || !ids.count(text(e, "from")) || !ids.count(text(e, "to")) || text(e, "kind").empty()) continue;
            J edge{{"from", text(e, "from")}, {"to", text(e, "to")}, {"kind", text(e, "kind").substr(0, 32)}};
            if (!text(e, "label").empty()) edge["label"] = text(e, "label").substr(0, 80);
            // A call's line and its arguments as written (at most 12, each at most 80 characters): what flows in.
            if (number(e, "line") > 0) edge["line"] = number(e, "line");
            const auto strings = [](const J& list) {
                J out = J::array();
                for (const auto& a : list) if (a.is_string() && out.size() < 12) out.push_back(a.get<std::string>().substr(0, 80));
                return out;
            };
            if (e.contains("args") && e["args"].is_array()) edge["args"] = strings(e["args"]);
            if (count_of(e, "args_more") > 0) edge["args_more"] = count_of(e, "args_more");
            // Every call between the two (at most 8), each its line and arguments: the trace offers each site.
            if (e.contains("sites") && e["sites"].is_array()) {
                J sites = J::array();
                for (const auto& site : e["sites"])
                    if (site.is_object() && number(site, "line") > 0 && sites.size() < 8) {
                        J one{{"line", number(site, "line")}};
                        if (site.contains("args") && site["args"].is_array()) one["args"] = strings(site["args"]);
                        if (count_of(site, "args_more") > 0) one["args_more"] = count_of(site, "args_more");
                        sites.push_back(one);
                    }
                if (!sites.empty()) edge["sites"] = sites;
                if (count_of(e, "sites_more") > 0) edge["sites_more"] = count_of(e, "sites_more");
            }
            // A handoff: where the other side takes it (the pop's line)
            if (number(e, "to_line") > 0) edge["to_line"] = number(e, "to_line");
            edges.push_back(edge);
        }
    if (raw.is_object() && raw.contains("spans") && raw["spans"].is_object())
        for (const auto& [id, span] : raw["spans"].items())
            if (ids.count(id) && span.is_array() && span.size() == 2 && span[0].is_number_integer() && span[1].is_number_integer())
                spans[id] = span;
    J out{{"version", 1}, {"nodes", nodes}, {"edges", edges}, {"spans", spans},
          {"complete", raw.is_object() && flag(raw, "complete", true)}};
    if (raw.is_object() && !text(raw, "why").empty()) out["why"] = text(raw, "why").substr(0, 500);
    return out;
}

// The syntax reader's graph and the binary reader's in one: a function both found becomes one node, the syntax one
// (it has the function's lines); the binary's edges move onto it. Found by both means the same name in the same file
// once on each side, where the binary knows the file (built with debug info); else the same name once on each side
// in the checkout's C and C++, or once in the folder the binary was built in (`near`, root-relative with a slash).
// Every edge keeps its kind, so an exact call and a call by name between two functions stay two edges.
// What a rebuild changed against the build before it (Codex's #42): the calls and functions added and removed, the
// functions that found their source and those that lost it, and why, as far as the stored builds can say: the source
// changed (another commit, other edits), the binary was another or rebuilt, a parser came or went. prev: the last
// graph.json (null: the first build). The lists keep the first 20 of each; the counts are whole.
inline J changes(const J& prev, const J& now) {
    J out{{"built_at", number(now, "built_at")}};
    if (!prev.is_object() || !prev.contains("nodes")) { out["first"] = true; return out; }
    out["previous_built_at"] = number(prev, "built_at");
    const auto label_of = [](const J& graph) {
        std::map<std::string, J> m;
        for (const auto& n : list(graph, "nodes")) if (n.is_object()) m[text(n, "id")] = n;
        return m;
    };
    const auto before = label_of(prev), after = label_of(now);
    const auto edge_keys = [](const J& graph) {
        std::map<std::string, J> m;
        for (const auto& e : list(graph, "edges"))
            if (e.is_object() && text(e, "kind") != "contains")
                m[text(e, "from") + '\x1f' + text(e, "to") + '\x1f' + text(e, "kind")] = J{{"from", text(e, "from")}, {"to", text(e, "to")}, {"kind", text(e, "kind")}};
        return m;
    };
    const auto eb = edge_keys(prev), ea = edge_keys(now);
    const auto diff = [](const std::map<std::string, J>& a, const std::map<std::string, J>& b, J& list_out) {
        long long n = 0;
        for (const auto& [k, v] : a) if (!b.count(k)) { if (list_out.size() < 20) list_out.push_back(v); ++n; }
        return n;
    };
    J edges_added = J::array(), edges_removed = J::array(), nodes_added = J::array(), nodes_removed = J::array();
    out["edges_added"] = diff(ea, eb, edges_added);
    out["edges_removed"] = diff(eb, ea, edges_removed);
    out["nodes_added"] = diff(after, before, nodes_added);
    out["nodes_removed"] = diff(before, after, nodes_removed);
    out["edges_added_list"] = edges_added; out["edges_removed_list"] = edges_removed;
    J slim_added = J::array(), slim_removed = J::array();
    for (const auto& n : nodes_added) slim_added.push_back(J{{"id", text(n, "id")}, {"label", text(n, "label")}, {"file", n.value("file", J())}, {"line", n.value("line", J())}});
    for (const auto& n : nodes_removed) slim_removed.push_back(J{{"id", text(n, "id")}, {"label", text(n, "label")}});
    out["nodes_added_list"] = slim_added; out["nodes_removed_list"] = slim_removed;
    long long found = 0, lost = 0;
    for (const auto& [id, n] : after) {
        const auto was = before.find(id);
        if (was == before.end()) continue;
        const bool had = was->second.contains("file") && was->second["file"].is_string(), has = n.contains("file") && n["file"].is_string();
        if (!had && has) ++found;
        if (had && !has) ++lost;
    }
    out["found_source"] = found;
    out["lost_source"] = lost;
    J because = J::array();
    if (text(prev, "head") != text(now, "head") || text(prev, "dirty") != text(now, "dirty")) {
        std::string head = text(prev, "head") != text(now, "head")
            ? "the source changed (" + text(prev, "head").substr(0, 7) + " → " + text(now, "head").substr(0, 7) + ")" : std::string("the source changed (edits not committed)");
        because.push_back(head);
    }
    if (text(prev, "binary") != text(now, "binary")) because.push_back(text(now, "binary").empty() ? "no binary read now" : "another binary was read");
    else if (prev.contains("binary_stamp") && now.contains("binary_stamp") && prev["binary_stamp"] != now["binary_stamp"]) because.push_back("the binary was rebuilt");
    const auto parsers = [](const J& graph) {
        std::string said;
        for (const auto& p : list(graph, "providers"))
            if (text(p, "name") == "syntax") for (const auto& n : list(p, "notes")) if (n.is_string() && n.get<std::string>().rfind("no treesitter parser", 0) == 0) said = n.get<std::string>();
        return said;
    };
    if (parsers(prev) != parsers(now)) because.push_back(parsers(now).empty() ? "a parser became available" : "the files without a parser changed: " + parsers(now));
    out["because"] = because;
    return out;
}

inline J merge(const J& syntax, const J& binary, const std::string& near = {}) {
    J nodes = J::array(), edges = J::array(), spans = J::object();
    std::set<std::string> ids;
    std::map<std::string, std::vector<std::string>> by_key;
    std::map<std::string, std::string> file_of;
    std::vector<std::string> why;
    bool complete = true;
    for (const J* part : {&syntax, &binary}) {
        if (!part->is_object()) continue;
        complete = complete && flag(*part, "complete", true);
        if (!text(*part, "why").empty()) why.push_back(text(*part, "why"));
    }
    std::map<std::string, size_t> index_of;
    if (syntax.is_object()) {
        for (const auto& n : list(syntax, "nodes")) {
            if (!ids.insert(text(n, "id")).second) continue;
            index_of[text(n, "id")] = nodes.size();
            nodes.push_back(n);
            if (text(n, "kind") == "function" && compiled_file(text(n, "file"))) {
                by_key[match_key(text(n, "label"))].push_back(text(n, "id"));
                file_of[text(n, "id")] = text(n, "file");
            }
        }
        for (const auto& e : list(syntax, "edges")) edges.push_back(e);
        const auto found = syntax.find("spans");
        if (found != syntax.end() && found->is_object()) spans = *found;
    }
    std::map<std::string, std::string> alias;
    long long matched = 0;
    if (binary.is_object()) {
        std::map<std::string, int> binary_keys;
        std::map<std::pair<std::string, std::string>, int> binary_places;
        for (const auto& n : list(binary, "nodes")) if (text(n, "id").rfind("bin:", 0) == 0) {
            ++binary_keys[match_key(text(n, "label"))];
            if (!text(n, "file").empty()) ++binary_places[{match_key(text(n, "label")), text(n, "file")}];
        }
        const auto only = [&](const std::vector<std::string>& candidates, const std::function<bool(const std::string&)>& keep) {
            std::string pick;
            for (const auto& c : candidates) if (keep(c)) { if (!pick.empty()) return std::string(); pick = c; }
            return pick;
        };
        for (const auto& n : list(binary, "nodes")) {
            const auto id = text(n, "id");
            if (id.rfind("bin:", 0) == 0) {
                const auto key = match_key(text(n, "label")), file = text(n, "file");
                const auto found = by_key.find(key);
                std::string pick;
                if (found != by_key.end()) {
                    if (!file.empty() && binary_places[{key, file}] == 1)
                        pick = only(found->second, [&](const std::string& s) { return file_of[s] == file; });
                    if (pick.empty() && binary_keys[key] == 1) {
                        pick = only(found->second, [](const std::string&) { return true; });
                        if (pick.empty() && !near.empty())
                            pick = only(found->second, [&](const std::string& s) { return file_of[s].rfind(near, 0) == 0; });
                    }
                }
                if (!pick.empty()) {
                    alias[id] = pick; ++matched;
                    // the source function says what it is in the binary: its symbol and the copies folded into it
                    if (n.contains("binary") && index_of.count(pick)) nodes[index_of[pick]]["binary"] = n["binary"];
                    continue;
                }
            }
            if (!ids.insert(id).second) continue;
            J node = n;
            if (id.rfind("bin:", 0) == 0 && !node.contains("detail")) node["detail"] = "in the binary only";
            nodes.push_back(node);
        }
        std::set<std::tuple<std::string, std::string>> seen;
        for (const auto& e : list(binary, "edges")) {
            const auto from = alias.count(text(e, "from")) ? alias[text(e, "from")] : text(e, "from");
            const auto to = alias.count(text(e, "to")) ? alias[text(e, "to")] : text(e, "to");
            if (!ids.count(from) || !ids.count(to) || !seen.insert({from, to}).second) continue;
            edges.push_back(J{{"from", from}, {"to", to}, {"kind", text(e, "kind")}});
        }
    }
    J out{{"version", 1}, {"nodes", nodes}, {"edges", edges}, {"spans", spans}, {"complete", complete}, {"matched", matched}};
    if (!why.empty()) {
        std::string joined;
        for (const auto& w : why) joined += (joined.empty() ? "" : "; ") + w;
        out["why"] = joined;
    }
    return out;
}

// ─── her corrections to the inferred handoffs ─────────────────────────────────────────────────────────────────
// The syntax reader infers handoffs (a push to a pop on one object, a function passed by name, a function pointer set)
// and can be wrong or miss one. Her corrections, { drop: [ { from, to } ], add: [ { from, to, label? } ] } (a desk.d
// file's "map": { "handoffs" }, kept out of the checkout), apply as a query reads the stored graph: a dropped handoff
// is gone (a call between the two stays), an added one is a handoff marked by_hand. A pair naming a function the map
// does not have is skipped; one the reader already inferred is kept as it is.
inline J corrected(J doc, const J& handoffs) {
    if (!doc.is_object() || !handoffs.is_object() || !doc.contains("edges") || !doc["edges"].is_array()) return doc;
    std::set<std::pair<std::string, std::string>> drop, have;
    for (const auto& d : list(handoffs, "drop")) if (d.is_object()) drop.insert({text(d, "from"), text(d, "to")});
    std::set<std::string> ids;
    for (const auto& n : list(doc, "nodes")) if (n.is_object()) ids.insert(text(n, "id"));
    J kept = J::array();
    for (const auto& e : doc["edges"]) {
        const std::pair<std::string, std::string> pair{text(e, "from"), text(e, "to")};
        if (text(e, "kind") == "handoff") {
            if (drop.count(pair)) continue;
            have.insert(pair);
        }
        kept.push_back(e);
    }
    for (const auto& a : list(handoffs, "add")) {
        if (!a.is_object()) continue;
        const std::pair<std::string, std::string> pair{text(a, "from"), text(a, "to")};
        if (!ids.count(pair.first) || !ids.count(pair.second) || pair.first == pair.second || drop.count(pair) || have.count(pair)) continue;
        const auto label = text(a, "label");
        kept.push_back(J{{"from", pair.first}, {"to", pair.second}, {"kind", "handoff"}, {"by_hand", true},
                         {"label", label.empty() ? std::string("by hand") : label.substr(0, 80)}});
        have.insert(pair);
    }
    doc["edges"] = kept;
    return doc;
}

// ─── the stored graph, indexed for queries ─────────────────────────────────────────────────────────────────────
struct Graph {
    J doc;
    std::vector<J> nodes;
    std::vector<std::string> module;
    std::unordered_map<std::string, size_t> at;
    // Call edges and handoffs, one per pair: the kinds as bits (1 call, 2 call-by-name, 4 handoff).
    std::vector<std::vector<std::pair<size_t, int>>> out, in;
    std::vector<std::tuple<size_t, size_t, std::string>> all;   // every edge, contains included
    // The first call between two functions, as the syntax reader saw it: its line and arguments (the trace's).
    std::map<std::pair<size_t, size_t>, J> calls;

    explicit Graph(J d) : doc(std::move(d)) {
        if (doc.is_object() && doc.contains("nodes") && doc["nodes"].is_array())
            for (const auto& n : doc["nodes"]) {
                if (!n.is_object() || text(n, "id").empty() || at.count(text(n, "id"))) continue;
                at[text(n, "id")] = nodes.size();
                nodes.push_back(n);
                module.push_back(module_of(text(n, "file"), text(n, "id")));
            }
        out.resize(nodes.size()); in.resize(nodes.size());
        std::map<std::pair<size_t, size_t>, int> bits;
        if (doc.is_object() && doc.contains("edges") && doc["edges"].is_array())
            for (const auto& e : doc["edges"]) {
                const auto a = at.find(text(e, "from")), b = at.find(text(e, "to"));
                if (a == at.end() || b == at.end()) continue;
                const auto kind = text(e, "kind");
                all.emplace_back(a->second, b->second, kind);
                if (walked_kind(kind)) bits[{a->second, b->second}] |= kind == "call" ? 1 : kind == "call-by-name" ? 2 : 4;
                if (walked_kind(kind) && (e.contains("line") || e.contains("args") || e.contains("label")) && !calls.count({a->second, b->second})) {
                    J facts = J::object();
                    if (e.contains("line")) facts["line"] = e["line"];
                    if (e.contains("args")) facts["args"] = e["args"];
                    if (e.contains("args_more")) facts["args_more"] = e["args_more"];
                    if (e.contains("sites_more")) facts["sites_more"] = e["sites_more"];
                    if (e.contains("label")) facts["label"] = e["label"];
                    if (e.contains("by_hand")) facts["by_hand"] = e["by_hand"];
                    if (e.contains("sites")) facts["sites"] = e["sites"];
                    if (e.contains("to_line")) facts["to_line"] = e["to_line"];
                    calls[{a->second, b->second}] = facts;
                }
            }
        for (const auto& [pair, mask] : bits) { out[pair.first].push_back({pair.second, mask}); in[pair.second].push_back({pair.first, mask}); }
        const auto by_label = [&](const std::pair<size_t, int>& x, const std::pair<size_t, int>& y) {
            return text(nodes[x.first], "label") != text(nodes[y.first], "label") ? text(nodes[x.first], "label") < text(nodes[y.first], "label") : x.first < y.first;
        };
        for (auto& list : out) std::sort(list.begin(), list.end(), by_label);
        for (auto& list : in) std::sort(list.begin(), list.end(), by_label);
    }
    J node(size_t i) const { J n = nodes[i]; n["module"] = module[i]; return n; }
};

inline std::string kinds_of(int mask) { return mask & 1 ? "call" : mask & 2 ? "call-by-name" : "handoff"; }

// A name typed by a person (or the id a view sends) to one node: the id, else the label, else the label without its
// parameters, else a unique last part ("push" for Queue::push). Several: refused, with the candidates to pick from.
struct Found { long index = -1; std::string message; J candidates = J::array(); };
inline Found resolve(const Graph& g, const std::string& name) {
    Found found;
    if (name.empty()) { found.message = "Name a function (or paste its id)"; return found; }
    const auto it = g.at.find(name);
    if (it != g.at.end()) { found.index = static_cast<long>(it->second); return found; }
    const auto key = match_key(name);
    const auto last_part = [](const std::string& s) {
        size_t cut = 0;
        for (size_t i = 0; i < s.size(); ++i) if (s[i] == ':' || s[i] == '.') cut = i + 1;
        return s.substr(cut);
    };
    std::vector<std::function<bool(size_t)>> rules{
        [&](size_t i) { return text(g.nodes[i], "label") == name; },
        [&](size_t i) { return match_key(text(g.nodes[i], "label")) == key; },
        [&](size_t i) { return last_part(match_key(text(g.nodes[i], "label"))) == key; },
    };
    for (const auto& rule : rules) {
        std::vector<size_t> hits;
        for (size_t i = 0; i < g.nodes.size(); ++i) if (rule(i)) hits.push_back(i);
        if (hits.size() == 1) { found.index = static_cast<long>(hits[0]); return found; }
        if (hits.size() > 1) {
            found.message = "Several things in the map are named " + name + "; pick one";
            for (size_t k = 0; k < hits.size() && k < 12; ++k) found.candidates.push_back(g.node(hits[k]));
            return found;
        }
    }
    found.message = "Nothing in the map is named " + name;
    return found;
}

// Which nodes sit on a cycle with which (strongly connected parts of the call edges), so a walk can mark a call that
// is part of recursion whichever way it reached it.
inline std::vector<long> cycles(const Graph& g) {
    const size_t n = g.nodes.size();
    std::vector<long> index(n, -1), low(n, 0), part(n, -1);
    std::vector<char> stacked(n, 0);
    std::vector<size_t> stack;
    long next = 0, parts = 0;
    for (size_t root = 0; root < n; ++root) {
        if (index[root] >= 0) continue;
        std::vector<std::pair<size_t, size_t>> frames{{root, 0}};
        index[root] = low[root] = next++; stack.push_back(root); stacked[root] = 1;
        while (!frames.empty()) {
            auto& [v, k] = frames.back();
            if (k < g.out[v].size()) {
                const auto w = g.out[v][k++].first;
                if (index[w] < 0) { index[w] = low[w] = next++; stack.push_back(w); stacked[w] = 1; frames.push_back({w, 0}); }
                else if (stacked[w]) low[v] = std::min(low[v], index[w]);
                continue;
            }
            const auto done = v;
            frames.pop_back();
            if (!frames.empty()) low[frames.back().first] = std::min(low[frames.back().first], low[done]);
            if (low[done] == index[done]) {
                for (;;) { const auto w = stack.back(); stack.pop_back(); stacked[w] = 0; part[w] = parts; if (w == done) break; }
                ++parts;
            }
        }
    }
    return part;
}

// Everything reachable from a node along calls (or everything that reaches it, for callers), breadth first so each
// node shows at its nearest depth. Every step says what is at its end: follow (read further), leaf (calls nothing),
// seen (already in the answer), capped (the depth limit; it calls more); cycle marks a call that is part of
// recursion. At most `cap` steps; `more` counts the ones left out.
inline J walk(const Graph& g, size_t start, int depth, bool backwards, size_t cap) {
    const auto part = cycles(g);
    const auto& next = backwards ? g.in : g.out;
    std::vector<int> level(g.nodes.size(), -1);
    std::deque<size_t> queue{start};
    level[start] = 0;
    J steps = J::array();
    size_t more = 0;
    std::vector<size_t> order{start};
    while (!queue.empty()) {
        const auto v = queue.front();
        queue.pop_front();
        for (const auto& [w, mask] : next[v]) {
            if (steps.size() >= cap) { ++more; continue; }
            std::string mark;
            if (level[w] >= 0) mark = "seen";
            else {
                level[w] = level[v] + 1;
                order.push_back(w);
                if (next[w].empty()) mark = "leaf";
                else if (level[w] >= depth) mark = "capped";
                else { mark = "follow"; queue.push_back(w); }
            }
            J step{{"from", text(g.nodes[backwards ? w : v], "id")}, {"to", text(g.nodes[backwards ? v : w], "id")},
                   {"kind", kinds_of(mask)}, {"depth", level[v] + 1}, {"mark", mark}};
            if ((part[v] == part[w] && part[v] >= 0) || v == w) step["cycle"] = true;
            steps.push_back(step);
        }
    }
    J nodes = J::array();
    for (auto i : order) { auto n = g.node(i); n["depth"] = level[i]; nodes.push_back(n); }
    return J{{"ok", true}, {"q", backwards ? "callers" : "reach"}, {"from", g.node(start)}, {"depth", depth},
             {"nodes", nodes}, {"steps", steps}, {"more", more}, {"capped", more > 0}};
}

// Every way from one node to another along calls, each node at most once per way, shortest first: at most `max`
// ways of at most `depth` calls. Only nodes that can still reach the end in the calls left are tried, and the work
// is bounded, so a large graph answers quickly (and says when it stopped early).
// The trace: one lane THROUGH a function, up its callers to where it starts (the
// farthest function nothing calls, within depth) and down its callees to where it ends (the farthest that calls
// nothing more in the map), or to `to` by the shortest way. Each step: its node (with its signature when the reader
// gave one), and the call into the next (its kind, line and arguments); off the lane, its other callers above and
// callees below, up to 8 named and counted. A cycle never loops: each function is on the lane once.
inline J trace(const Graph& g, size_t focus, int depth, long to = -1, long start = -1) {
    const auto farthest = [&](bool backwards, std::vector<long>& prev) {
        std::vector<int> dist(g.nodes.size(), -1);
        std::deque<size_t> queue{focus};
        dist[focus] = 0;
        size_t best = focus;
        bool best_end = false;
        while (!queue.empty()) {
            const auto v = queue.front();
            queue.pop_front();
            const auto& next = backwards ? g.in[v] : g.out[v];
            const bool end = next.empty();
            // The farthest end wins; a function in a cycle is an end only when nothing farther is.
            if ((end && (!best_end || dist[v] > dist[best])) || (!best_end && dist[v] > dist[best])) { best = v; best_end = end; }
            if (dist[v] >= depth) continue;
            for (const auto& [w, mask] : next) {
                (void)mask;
                if (dist[w] >= 0) continue;
                dist[w] = dist[v] + 1;
                prev[w] = static_cast<long>(v);
                queue.push_back(w);
            }
        }
        return best;
    };
    std::vector<long> up_prev(g.nodes.size(), -1), down_prev(g.nodes.size(), -1);
    std::vector<size_t> lane;
    // Up: from a chosen start, the shortest way down from it to the function (found walking its callers); else the
    // farthest start.
    size_t top = focus;
    bool start_reached = true;
    if (start >= 0) {
        std::vector<int> dist(g.nodes.size(), -1);
        std::deque<size_t> queue{focus};
        dist[focus] = 0;
        while (!queue.empty() && dist[static_cast<size_t>(start)] < 0) {
            const auto v = queue.front();
            queue.pop_front();
            if (dist[v] >= depth) continue;
            for (const auto& [w, mask] : g.in[v]) {
                (void)mask;
                if (dist[w] >= 0) continue;
                dist[w] = dist[v] + 1;
                up_prev[w] = static_cast<long>(v);
                queue.push_back(w);
            }
        }
        start_reached = dist[static_cast<size_t>(start)] >= 0;
        if (start_reached) top = static_cast<size_t>(start);
    } else top = farthest(true, up_prev);
    for (long v = static_cast<long>(top); v >= 0; v = up_prev[static_cast<size_t>(v)]) lane.push_back(static_cast<size_t>(v));
    std::vector<size_t> down;
    size_t end = focus;
    if (to >= 0) {
        // To a chosen function: the shortest way down, when there is one within depth.
        std::vector<int> dist(g.nodes.size(), -1);
        std::deque<size_t> queue{focus};
        dist[focus] = 0;
        while (!queue.empty() && dist[static_cast<size_t>(to)] < 0) {
            const auto v = queue.front();
            queue.pop_front();
            if (dist[v] >= depth) continue;
            for (const auto& [w, mask] : g.out[v]) {
                (void)mask;
                if (dist[w] >= 0) continue;
                dist[w] = dist[v] + 1;
                down_prev[w] = static_cast<long>(v);
                queue.push_back(w);
            }
        }
        if (dist[static_cast<size_t>(to)] >= 0) end = static_cast<size_t>(to);
    } else end = farthest(false, down_prev);
    for (long v = static_cast<long>(end); v >= 0 && static_cast<size_t>(v) != focus; v = down_prev[static_cast<size_t>(v)]) down.push_back(static_cast<size_t>(v));
    std::set<size_t> on_lane(lane.begin(), lane.end());
    for (auto it = down.rbegin(); it != down.rend(); ++it) if (on_lane.insert(*it).second) lane.push_back(*it);
    J steps = J::array(), calls = J::array();
    for (size_t k = 0; k < lane.size(); ++k) {
        const auto v = lane[k];
        J step = g.node(v);
        // How big it is: its lines, from the reader's spans (first and last line).
        const auto spans = g.doc.find("spans");
        if (spans != g.doc.end() && spans->is_object()) {
            const auto span = spans->find(text(g.nodes[v], "id"));
            if (span != spans->end() && span->is_array() && span->size() == 2 && (*span)[0].is_number_integer() && (*span)[1].is_number_integer())
                step["lines"] = (*span)[1].get<long long>() - (*span)[0].get<long long>() + 1;
        }
        // How many come before it (functions that reach it, up its callers) and after (functions it reaches), within depth.
        const auto reach_count = [&](bool backwards) {
            std::vector<char> seen(g.nodes.size(), 0);
            std::deque<std::pair<size_t, int>> queue{{v, 0}};
            seen[v] = 1;
            long long count = 0;
            while (!queue.empty()) {
                const auto [x, d] = queue.front();
                queue.pop_front();
                if (d >= depth) continue;
                for (const auto& [w, mask] : backwards ? g.in[x] : g.out[x]) {
                    (void)mask;
                    if (seen[w]) continue;
                    seen[w] = 1;
                    ++count;
                    queue.push_back({w, d + 1});
                }
            }
            return count;
        };
        step["before"] = reach_count(true);
        step["after"] = reach_count(false);
        step["role"] = v == focus ? "focus" : (k < static_cast<size_t>(std::find(lane.begin(), lane.end(), focus) - lane.begin()) ? "up" : "down");
        const auto off = [&](const std::vector<std::pair<size_t, int>>& list, size_t skip) {
            J named = J::array();
            size_t count = 0;
            for (const auto& [w, mask] : list) {
                (void)mask;
                if (w == skip) continue;
                ++count;
                if (named.size() < 8) {
                    // With where it is, so Enter on it goes to its code.
                    J one{{"id", text(g.nodes[w], "id")}, {"label", text(g.nodes[w], "label")}};
                    if (g.nodes[w].contains("file")) one["file"] = g.nodes[w]["file"];
                    if (g.nodes[w].contains("line")) one["line"] = g.nodes[w]["line"];
                    named.push_back(one);
                }
            }
            return std::make_pair(named, count);
        };
        const auto [callers, ncallers] = off(g.in[v], k > 0 ? lane[k - 1] : g.nodes.size());
        const auto [callees, ncallees] = off(g.out[v], k + 1 < lane.size() ? lane[k + 1] : g.nodes.size());
        step["callers"] = callers; step["more_callers"] = ncallers;
        step["callees"] = callees; step["more_callees"] = ncallees;
        steps.push_back(step);
        if (k + 1 < lane.size()) {
            const auto w = lane[k + 1];
            int mask = 0;
            for (const auto& [x, m] : g.out[v]) if (x == w) mask = m;
            J call{{"from", text(g.nodes[v], "id")}, {"to", text(g.nodes[w], "id")}, {"kind", mask ? kinds_of(mask) : "none"}};
            const auto facts = g.calls.find({v, w});
            if (facts != g.calls.end()) call.update(facts->second);
            calls.push_back(call);
        }
    }
    J out{{"ok", true}, {"q", "trace"}, {"focus", text(g.nodes[focus], "id")}, {"depth", depth}, {"steps", steps}, {"calls", calls}};
    if (to >= 0) { out["to"] = text(g.nodes[static_cast<size_t>(to)], "id"); out["reached"] = end == static_cast<size_t>(to); }
    if (start >= 0) { out["start"] = text(g.nodes[static_cast<size_t>(start)], "id"); out["start_reached"] = start_reached; }
    return out;
}

// The whole trace (2026-11-19, her "an entire trace would be nice"): every way THROUGH a function in one picture:
// everything that leads to it (up its callers) and everything it leads to (down its calls), within depth each way. A
// chosen start keeps only the callers it reaches; a chosen end, only the calls that reach it. Each node says whether it
// is on the trace's lane and its side ("at": negative above, positive below); a call is kept when it is on a way
// through the function, a cycle's too (the drawing breaks it once).
inline J flow(const Graph& g, size_t focus, int depth, long to = -1, long start = -1) {
    const J t = trace(g, focus, depth, to, start);
    const auto walk = [&](size_t from, bool backwards) {
        std::vector<int> dist(g.nodes.size(), -1);
        std::deque<size_t> queue{from};
        dist[from] = 0;
        while (!queue.empty()) {
            const auto v = queue.front();
            queue.pop_front();
            if (dist[v] >= depth) continue;
            for (const auto& [w, mask] : backwards ? g.in[v] : g.out[v]) {
                (void)mask;
                if (dist[w] >= 0) continue;
                dist[w] = dist[v] + 1;
                queue.push_back(w);
            }
        }
        return dist;
    };
    auto up = walk(focus, true), down = walk(focus, false);
    if (start >= 0) {
        const auto from_start = walk(static_cast<size_t>(start), false);
        for (size_t v = 0; v < up.size(); ++v) if (from_start[v] < 0) up[v] = -1;
    }
    if (to >= 0) {
        const auto to_end = walk(static_cast<size_t>(to), true);
        for (size_t v = 0; v < down.size(); ++v) if (to_end[v] < 0) down[v] = -1;
    }
    up[focus] = down[focus] = 0;
    std::set<std::string> lane_ids;
    J lane = J::array();
    for (const auto& st : t["steps"]) { lane_ids.insert(text(st, "id")); lane.push_back(text(st, "id")); }
    J nodes = J::array(), edges = J::array();
    for (size_t v = 0; v < g.nodes.size(); ++v) {
        if (up[v] < 0 && down[v] < 0) continue;
        J node = g.node(v);
        node["lane"] = lane_ids.count(text(g.nodes[v], "id")) > 0;
        node["at"] = down[v] >= 0 ? down[v] : -up[v];
        nodes.push_back(node);
    }
    for (size_t v = 0; v < g.nodes.size(); ++v)
        for (const auto& [w, mask] : g.out[v])
            if ((up[v] >= 0 && up[w] >= 0 && v != focus) || (down[v] >= 0 && down[w] >= 0 && w != focus))
                edges.push_back(J{{"from", text(g.nodes[v], "id")}, {"to", text(g.nodes[w], "id")}, {"kind", mask ? kinds_of(mask) : "none"}});
    J out{{"ok", true}, {"q", "flow"}, {"focus", text(g.nodes[focus], "id")}, {"depth", depth}, {"nodes", nodes}, {"edges", edges}, {"lane", lane}};
    if (to >= 0) { out["to"] = text(g.nodes[static_cast<size_t>(to)], "id"); out["reached"] = t["reached"]; }
    if (start >= 0) { out["start"] = text(g.nodes[static_cast<size_t>(start)], "id"); out["start_reached"] = t["start_reached"]; }
    return out;
}

inline J paths(const Graph& g, size_t from, size_t to, int depth, size_t max) {
    std::vector<int> left(g.nodes.size(), -1);   // calls from here to the end
    std::deque<size_t> queue{to};
    left[to] = 0;
    while (!queue.empty()) {
        const auto v = queue.front(); queue.pop_front();
        if (left[v] >= depth) continue;
        for (const auto& [w, mask] : g.in[v]) if (left[w] < 0) { left[w] = left[v] + 1; queue.push_back(w); }
    }
    J found = J::array();
    std::vector<size_t> path{from};
    std::vector<int> masks;
    std::vector<char> on(g.nodes.size(), 0);
    on[from] = 1;
    size_t budget = 200000;
    bool stopped = false;
    // Iterative deepening: every way of exactly `length` calls, for each length in turn, so the shortest come first.
    std::function<void(size_t, int)> go = [&](size_t v, int length) {
        if (found.size() >= max || stopped) return;
        if (budget-- == 0) { stopped = true; return; }
        for (const auto& [w, mask] : g.out[v]) {
            if (found.size() >= max) return;
            const int remaining = length - static_cast<int>(masks.size()) - 1;
            if (w == to && remaining == 0) {
                J ids = J::array(), kinds = J::array();
                for (auto p : path) ids.push_back(text(g.nodes[p], "id"));
                ids.push_back(text(g.nodes[to], "id"));
                for (auto m : masks) kinds.push_back(kinds_of(m));
                kinds.push_back(kinds_of(mask));
                found.push_back(J{{"nodes", ids}, {"kinds", kinds}});
                continue;
            }
            if (w == to || on[w] || left[w] < 0 || left[w] > remaining) continue;
            on[w] = 1; path.push_back(w); masks.push_back(mask);
            go(w, length);
            on[w] = 0; path.pop_back(); masks.pop_back();
        }
    };
    if (left[from] > 0 || (from == to && !g.in[to].empty()))
        for (int length = std::max(1, left[from]); length <= depth && found.size() < max && !stopped; ++length) go(from, length);
    std::set<std::string> ids;
    for (const auto& p : found) for (const auto& id : p["nodes"]) ids.insert(id.get<std::string>());
    J nodes = J::array();
    for (const auto& id : ids) nodes.push_back(g.node(g.at.at(id)));
    J out{{"ok", true}, {"q", "paths"}, {"from", g.node(from)}, {"to", g.node(to)}, {"depth", depth}, {"max", max},
          {"paths", found}, {"nodes", nodes}, {"capped", stopped || found.size() >= max}};
    if (found.empty()) {
        // No way: where to look next — where the start's calls end (the farthest it reaches, and what calls nothing
        // further), what calls the end nearest, and why the search stopped (her ask: "a useful result").
        std::vector<int> far(g.nodes.size(), -1);
        std::deque<size_t> q{from};
        far[from] = 0;
        bool cut = false;
        while (!q.empty()) {
            const auto v = q.front(); q.pop_front();
            if (far[v] >= depth) { if (!g.out[v].empty()) cut = true; continue; }
            for (const auto& [w, mask] : g.out[v]) if (far[w] < 0) { far[w] = far[v] + 1; q.push_back(w); }
        }
        int deepest = 0;
        for (size_t i = 0; i < g.nodes.size(); ++i) deepest = std::max(deepest, far[i]);
        J ends = J::array(), callers = J::array();
        for (size_t i = 0; i < g.nodes.size() && ends.size() < 8; ++i)
            if (far[i] > 0 && (far[i] == deepest || g.out[i].empty())) { J n = g.node(i); n["depth"] = far[i]; ends.push_back(n); }
        for (int d = 1; d <= depth && callers.size() < 8; ++d)
            for (size_t i = 0; i < g.nodes.size() && callers.size() < 8; ++i)
                if (left[i] == d) { J n = g.node(i); n["depth"] = d; callers.push_back(n); }
        for (size_t i = 0; i < g.nodes.size() && !cut; ++i) if (left[i] == depth && !g.in[i].empty()) cut = true;
        const bool partial = g.doc.is_object() && g.doc.value("complete", true) == false;
        out["ends"] = ends;
        out["callers"] = callers;
        out["why"] = cut ? "depth" : partial ? "partial" : "ran_out";
    }
    return out;
}

// Every call into function `to`: each caller with the lines it calls it on (the reader's sites, else its first line) —
// where the function's result goes is read from those lines.
inline J calls_into(const Graph& g, size_t to, size_t cap) {
    J callers = J::array();
    for (const auto& [v, mask] : g.in[to]) {
        if (callers.size() >= cap) break;
        if (!(mask & 3)) continue;   // a handoff hands data on; it does not take a result
        J row{{"node", g.node(v)}, {"sites", J::array()}};
        const auto facts = g.calls.find({v, to});
        if (facts != g.calls.end()) {
            if (facts->second.contains("sites")) row["sites"] = facts->second["sites"];
            else if (facts->second.contains("line")) row["sites"].push_back(J{{"line", facts->second["line"]}});
        }
        callers.push_back(row);
    }
    return J{{"ok", true}, {"q", "calls-into"}, {"to", g.node(to)}, {"callers", callers}};
}

// The calls from part `from` into part `to`, by the entry function they reach in `to` (the interface `from` uses), each
// with its callers in `from`, the most-called first. A part's own helpers do not show: only calls that cross.
inline J crossings(const Graph& g, const std::string& from, const std::string& to, size_t cap) {
    std::map<size_t, std::set<size_t>> by_entry;
    for (size_t v = 0; v < g.nodes.size(); ++v) {
        if (g.module[v] != from) continue;
        for (const auto& [w, mask] : g.out[v]) if (g.module[w] == to && w != v) by_entry[w].insert(v);
    }
    std::vector<std::pair<size_t, std::set<size_t>>> list(by_entry.begin(), by_entry.end());
    std::stable_sort(list.begin(), list.end(), [&](const auto& x, const auto& y) {
        return x.second.size() != y.second.size() ? x.second.size() > y.second.size() : text(g.nodes[x.first], "label") < text(g.nodes[y.first], "label");
    });
    J entries = J::array();
    size_t calls = 0;
    for (const auto& [w, callers] : list) {
        calls += callers.size();
        if (entries.size() >= cap) continue;
        J who = J::array();
        for (const auto v : callers) if (who.size() < 12) who.push_back(g.node(v));
        entries.push_back(J{{"node", g.node(w)}, {"callers", who}, {"count", callers.size()}});
    }
    return J{{"ok", true}, {"q", "crossings"}, {"from", from}, {"to", to}, {"entries", entries}, {"calls", calls},
             {"more", list.size() > cap ? list.size() - cap : 0}};
}

// The checkout's parts with their sizes, and how many distinct calls go from each part to each other one.
inline J modules(const Graph& g) {
    struct Size { std::set<std::string> files; long long functions = 0, types = 0; };
    std::map<std::string, Size> sizes;
    for (size_t i = 0; i < g.nodes.size(); ++i) {
        auto& s = sizes[g.module[i]];
        if (!text(g.nodes[i], "file").empty()) s.files.insert(text(g.nodes[i], "file"));
        (text(g.nodes[i], "kind") == "type" ? s.types : s.functions)++;
    }
    std::map<std::pair<std::string, std::string>, long long> between;
    for (size_t v = 0; v < g.out.size(); ++v)
        for (const auto& [w, mask] : g.out[v]) if (g.module[v] != g.module[w]) ++between[{g.module[v], g.module[w]}];
    J list = J::array(), edges = J::array();
    for (const auto& [name, s] : sizes)
        list.push_back(J{{"name", name}, {"files", s.files.size()}, {"functions", s.functions}, {"types", s.types}});
    for (const auto& [pair, count] : between) edges.push_back(J{{"from", pair.first}, {"to", pair.second}, {"count", count}});
    std::stable_sort(edges.begin(), edges.end(), [](const J& a, const J& b) { return number(a, "count") > number(b, "count"); });
    return J{{"ok", true}, {"q", "module"}, {"modules", list}, {"edges", edges}};
}

// One part's contents: its files with their sizes, its nodes (at most `cap`), every edge that touches them, and the
// nodes at the far end of the edges that leave the part.
inline J module_contents(const Graph& g, const std::string& name, size_t cap) {
    std::vector<size_t> mine;
    for (size_t i = 0; i < g.nodes.size(); ++i) if (g.module[i] == name) mine.push_back(i);
    if (mine.empty()) {
        std::set<std::string> names(g.module.begin(), g.module.end());
        std::string some;
        size_t shown = 0;
        for (const auto& n : names) { if (shown++ == 12) { some += ", …"; break; } some += (some.empty() ? "" : ", ") + n; }
        return J{{"ok", false}, {"message", "No part of the map is called " + name + (some.empty() ? "" : "; it has " + some)}};
    }
    std::sort(mine.begin(), mine.end(), [&](size_t a, size_t b) {
        const auto fa = text(g.nodes[a], "file"), fb = text(g.nodes[b], "file");
        return fa != fb ? fa < fb : number(g.nodes[a], "line") != number(g.nodes[b], "line") ? number(g.nodes[a], "line") < number(g.nodes[b], "line") : a < b;
    });
    const size_t more = mine.size() > cap ? mine.size() - cap : 0;
    if (more) mine.resize(cap);
    std::set<size_t> kept(mine.begin(), mine.end()), outside;
    struct Size { long long functions = 0, types = 0; };
    std::map<std::string, Size> files;
    J nodes = J::array(), edges = J::array();
    for (auto i : mine) {
        nodes.push_back(g.node(i));
        if (!text(g.nodes[i], "file").empty()) (text(g.nodes[i], "kind") == "type" ? files[text(g.nodes[i], "file")].types : files[text(g.nodes[i], "file")].functions)++;
    }
    size_t dropped = 0;
    for (const auto& [a, b, kind] : g.all) {
        if (!kept.count(a) && !kept.count(b)) continue;
        if ((!kept.count(a) && g.module[a] == name) || (!kept.count(b) && g.module[b] == name)) continue;  // a dropped node of this part
        if (edges.size() >= 20000) { ++dropped; continue; }
        edges.push_back(J{{"from", text(g.nodes[a], "id")}, {"to", text(g.nodes[b], "id")}, {"kind", kind}});
        if (!kept.count(a)) outside.insert(a);
        if (!kept.count(b)) outside.insert(b);
    }
    J far = J::array(), list = J::array();
    for (auto i : outside) far.push_back(g.node(i));
    for (const auto& [file, s] : files) list.push_back(J{{"file", file}, {"functions", s.functions}, {"types", s.types}});
    return J{{"ok", true}, {"q", "module"}, {"module", name}, {"files", list}, {"nodes", nodes}, {"edges", edges},
             {"outside", far}, {"more", more}, {"edges_left_out", dropped}};
}

// ─── what a commit touched ─────────────────────────────────────────────────────────────────────────────────────
// `git diff -U0` to the changed line ranges on the new side, by file. A hunk that only deletes marks the line it
// deleted after, so the function around a deletion counts as touched.
using Ranges = std::map<std::string, std::vector<std::pair<long, long>>>;
inline std::string unquote(std::string path) {
    if (path.size() < 2 || path.front() != '"' || path.back() != '"') return path;
    std::string out;
    for (size_t i = 1; i + 1 < path.size(); ++i) {
        if (path[i] == '\\' && i + 2 < path.size()) {
            const char c = path[++i];
            if (c >= '0' && c <= '7' && i + 2 < path.size()) { out += static_cast<char>((c - '0') * 64 + (path[i + 1] - '0') * 8 + (path[i + 2] - '0')); i += 2; }
            else out += c == 't' ? '\t' : c == 'n' ? '\n' : c == 'r' ? '\r' : c == 'a' ? '\a' : c == 'b' ? '\b' : c == 'f' ? '\f' : c == 'v' ? '\v' : c;
        } else out += path[i];
    }
    return out;
}
inline Ranges diff_ranges(const std::string& diff) {
    Ranges out;
    std::istringstream lines(diff);
    std::string line, file;
    while (std::getline(lines, line)) {
        if (line.rfind("+++ ", 0) == 0) {
            auto path = unquote(line.substr(4));
            file = path == "/dev/null" ? "" : path.rfind("b/", 0) == 0 ? path.substr(2) : path;
            continue;
        }
        if (file.empty() || line.rfind("@@ ", 0) != 0) continue;
        const auto plus = line.find(" +");
        if (plus == std::string::npos) continue;
        long start = 0, count = 1;
        size_t at = plus + 2;
        while (at < line.size() && std::isdigit(static_cast<unsigned char>(line[at]))) start = start * 10 + (line[at++] - '0');
        if (at < line.size() && line[at] == ',') {
            count = 0; ++at;
            while (at < line.size() && std::isdigit(static_cast<unsigned char>(line[at]))) count = count * 10 + (line[at++] - '0');
        }
        if (count == 0) out[file].push_back({std::max(1L, start), std::max(1L, start)});
        else out[file].push_back({start, start + count - 1});
    }
    return out;
}
inline J touched(const Graph& g, const Ranges& ranges) {
    J nodes = J::array(), files = J::array();
    const J spans = g.doc.is_object() && g.doc.contains("spans") && g.doc["spans"].is_object() ? g.doc["spans"] : J::object();
    std::map<std::string, std::vector<size_t>> in_file;
    for (size_t i = 0; i < g.nodes.size(); ++i) if (!text(g.nodes[i], "file").empty()) in_file[text(g.nodes[i], "file")].push_back(i);
    for (const auto& [file, changed] : ranges) {
        J hit = J::array(), spans_json = J::array();
        for (const auto& r : changed) spans_json.push_back(J::array({r.first, r.second}));
        std::vector<std::pair<size_t, std::pair<long, long>>> units;
        for (auto i : in_file[file]) {
            const auto id = text(g.nodes[i], "id");
            const auto span = spans.find(id);
            if (span == spans.end() || !span->is_array() || span->size() != 2) continue;
            units.push_back({i, {(*span)[0].get<long>(), (*span)[1].get<long>()}});
        }
        // A changed range belongs to the innermost unit that holds all of it: a method's edit touches the method, not
        // its class too; an edit to the class's own lines (a field) touches the class.
        for (const auto& [i, span] : units) {
            const bool mine = std::any_of(changed.begin(), changed.end(), [&, span = span, i = i](const std::pair<long, long>& r) {
                if (r.first > span.second || r.second < span.first) return false;
                return std::none_of(units.begin(), units.end(), [&](const std::pair<size_t, std::pair<long, long>>& other) {
                    const auto& s = other.second;
                    return other.first != i && s.first >= span.first && s.second <= span.second && s != span
                           && r.first >= s.first && r.second <= s.second;
                });
            });
            if (!mine) continue;
            nodes.push_back(g.node(i)); hit.push_back(text(g.nodes[i], "id"));
        }
        files.push_back(J{{"file", file}, {"ranges", spans_json}, {"nodes", hit}});
    }
    return J{{"ok", true}, {"q", "touched"}, {"nodes", nodes}, {"files", files}};
}

// ─── staleness ─────────────────────────────────────────────────────────────────────────────────────────────────
// Why an answer built against `then` no longer matches `now` (each { head, dirty, binary? }), or "" while it does.
inline std::string stale_reason(const J& then, const J& now, bool binary) {
    if (binary) {
        const auto a = then.value("binary", J()), b = now.value("binary", J());
        if (!b.is_object() || number(b, "size", -1) < 0) return "the binary is gone";
        if (!a.is_object() || number(a, "size") != number(b, "size") || number(a, "mtime") != number(b, "mtime")) return "the binary was rebuilt";
        return "";
    }
    const auto head = text(then, "head"), current = text(now, "head");
    if (head != current) return "HEAD moved: " + (head.empty() ? std::string("none") : head.substr(0, 7)) + " → " + (current.empty() ? std::string("none") : current.substr(0, 7));
    if (text(then, "dirty") != text(now, "dirty")) {
        const auto count = number(now, "dirty_count");
        return count > 0 ? std::to_string(count) + (count == 1 ? " changed file differs" : " changed files differ") + " from when it was built"
                         : "the changed files were put back or committed";
    }
    return "";
}

// ─── DOT, for the big picture outside Neovim ───────────────────────────────────────────────────────────────────
inline std::string dot_quote(const std::string& s) {
    std::string out = "\"";
    for (char c : s) { if (c == '"' || c == '\\') out += '\\'; out += c == '\n' ? ' ' : c; }
    return out + "\"";
}
inline std::string dot(const Graph& g, const std::string& level, const std::string& only) {
    std::ostringstream o;
    o << "digraph \"project map\" {\n  graph [rankdir=TB];\n  node [shape=box, fontname=\"monospace\"];\n";
    if (level == "modules") {
        const auto m = modules(g);
        for (const auto& mod : m["modules"])
            o << "  " << dot_quote(text(mod, "name")) << " [label=" << dot_quote(text(mod, "name") + "\\n" + std::to_string(number(mod, "functions")) + " functions") << "];\n";
        for (const auto& e : m["edges"])
            o << "  " << dot_quote(text(e, "from")) << " -> " << dot_quote(text(e, "to")) << " [label=" << dot_quote(std::to_string(number(e, "count"))) << "];\n";
    } else {
        std::set<size_t> shown;
        for (size_t i = 0; i < g.nodes.size(); ++i) if (only.empty() || g.module[i] == only) {
            shown.insert(i);
            o << "  " << dot_quote(text(g.nodes[i], "id")) << " [label=" << dot_quote(text(g.nodes[i], "label")) << "];\n";
        }
        for (const auto& [a, b, kind] : g.all)
            if (shown.count(a) && shown.count(b))
                o << "  " << dot_quote(text(g.nodes[a], "id")) << " -> " << dot_quote(text(g.nodes[b], "id"))
                  << (kind == "call-by-name" ? " [style=dashed]" : kind == "contains" ? " [style=dotted, arrowhead=none]" : "") << ";\n";
    }
    o << "}\n";
    return o.str();
}
}  // namespace desk_map
#endif
