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

inline std::string text(const J& j, const char* key) {
    const auto it = j.find(key);
    return it != j.end() && it->is_string() ? it->get<std::string>() : std::string();
}
inline long long number(const J& j, const char* key, long long fallback = 0) {
    const auto it = j.find(key);
    return it != j.end() && it->is_number_integer() ? it->get<long long>() : fallback;
}
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
    struct Fn { uint64_t addr; std::string base; bool plt, clone, skip, cold; std::string file = {}; long line = 0; };
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
            nodes.push_back(node);
        }
    }
    if (raw.is_object() && raw.contains("edges") && raw["edges"].is_array())
        for (const auto& e : raw["edges"]) {
            if (!e.is_object() || !ids.count(text(e, "from")) || !ids.count(text(e, "to")) || text(e, "kind").empty()) continue;
            edges.push_back(J{{"from", text(e, "from")}, {"to", text(e, "to")}, {"kind", text(e, "kind").substr(0, 32)}});
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
    if (syntax.is_object()) {
        for (const auto& n : list(syntax, "nodes")) {
            if (!ids.insert(text(n, "id")).second) continue;
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
                if (!pick.empty()) { alias[id] = pick; ++matched; continue; }
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

// ─── the stored graph, indexed for queries ─────────────────────────────────────────────────────────────────────
struct Graph {
    J doc;
    std::vector<J> nodes;
    std::vector<std::string> module;
    std::unordered_map<std::string, size_t> at;
    // Call edges only, one per pair: the kinds as bits (1 call, 2 call-by-name).
    std::vector<std::vector<std::pair<size_t, int>>> out, in;
    std::vector<std::tuple<size_t, size_t, std::string>> all;   // every edge, contains included

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
                if (call_kind(kind)) bits[{a->second, b->second}] |= kind == "call" ? 1 : 2;
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

inline std::string kinds_of(int mask) { return mask & 1 ? "call" : "call-by-name"; }

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
    return J{{"ok", true}, {"q", "paths"}, {"from", g.node(from)}, {"to", g.node(to)}, {"depth", depth}, {"max", max},
             {"paths", found}, {"nodes", nodes}, {"capped", stopped || found.size() >= max}};
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
