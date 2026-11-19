// The project map's graph code alone (map_graph.hpp): the disassembly reader on a fixture (no binary is run), the
// names the readers meet at, merging, every query with its caps and cycle marks, a commit's line ranges, staleness.
#include "../map_graph.hpp"

#include <cstdio>
#include <fstream>
#include <iostream>
#include <set>
#include <sstream>
#include <string>

using desk_map::J;
static int passed = 0, failed = 0;
#define CHECK(cond, msg) do { if (cond) ++passed; else { ++failed; std::fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)

static std::set<std::string> ids(const J& nodes) {
    std::set<std::string> out;
    for (const auto& n : nodes) out.insert(n["id"].get<std::string>());
    return out;
}
static std::set<std::pair<std::string, std::string>> pairs(const J& edges, const std::string& kind = {}) {
    std::set<std::pair<std::string, std::string>> out;
    for (const auto& e : edges) if (kind.empty() || e["kind"] == kind) out.insert({e["from"].get<std::string>(), e["to"].get<std::string>()});
    return out;
}
static J node(const std::string& id, const std::string& label, const std::string& file, int line, const std::string& kind = "function") {
    return J{{"id", id}, {"label", label}, {"file", file.empty() ? J() : J(file)}, {"line", line > 0 ? J(line) : J()}, {"kind", kind}};
}
static J edge(const std::string& a, const std::string& b, const std::string& kind = "call-by-name") { return J{{"from", a}, {"to", b}, {"kind", kind}}; }
static const J* step(const J& answer, const std::string& from, const std::string& to) {
    for (const auto& s : answer["steps"]) if (s["from"] == from && s["to"] == to) return &s;
    return nullptr;
}

int main(int, char** argv) {
    // ─── an answer with a broken character (2026-11-19, the trader's map: one → cut in half lost the whole map) ───
    {
        const std::string good = "{\"label\":\"tick → order\",\"n\":1}";
        CHECK(desk_map::utf8_clean(good) == good, "utf8_clean: valid text unchanged");
        const std::string half = std::string("{\"args\":[\"(K=%d) \xe2\x86\"],\"n\":1}");
        const auto cleaned = desk_map::utf8_clean(half);
        CHECK(cleaned == std::string("{\"args\":[\"(K=%d) \xef\xbf\xbd\"],\"n\":1}"), "… a split arrow becomes one U+FFFD");
        const auto parsed = J::parse(cleaned, nullptr, false);
        CHECK(!parsed.is_discarded() && parsed["n"] == 1, "… and the answer parses, the rest of it kept");
        CHECK(J::parse(half, nullptr, false).is_discarded(), "(as the reader's answer was, it did not parse at all)");
        CHECK(desk_map::utf8_clean(std::string("a\xc3(b\xff\xf0\x9f\x98\x80")) == std::string("a\xef\xbf\xbd(b\xef\xbf\xbd\xf0\x9f\x98\x80"),
              "… a lead byte with no follower and a byte never valid, each one U+FFFD; a 4-byte character kept");
    }
    // ─── the disassembly reader ────────────────────────────────────────────────────────────────────────────────
    const std::string here = std::string(argv[0]).substr(0, std::string(argv[0]).rfind('/') + 1);
    std::ifstream fixture(here + "fixtures/objdump-sample.txt");
    CHECK(fixture.good(), "the fixture disassembly is there");
    desk_map::Objdump reader;
    for (std::string line; std::getline(fixture, line);) reader.line(line);
    const auto bin = reader.graph();
    const auto nodes = ids(bin["nodes"]);
    const auto overload = [](const std::string& full) {
        std::ostringstream o; o << std::hex << (std::hash<std::string>{}(full) & 0xffffffffu); return "bin:fox::Queue::push#" + o.str();
    };
    const std::string push = overload("fox::Queue<int>::push(int)"), push_double = overload("fox::Queue<int>::push(double)"),
                      grow = "bin:fox::Queue::grow", vec = "bin:std::vector::_M_realloc_insert", lambda = "bin:run()::{lambda()#1}::operator()";
    CHECK(nodes.count("bin:main") && nodes.count("bin:walk") && nodes.count("bin:leaf_a64") && nodes.count("bin:run"), "the defined functions are nodes, by the name both readers share");
    CHECK(nodes.count(push) && nodes.count(push_double) && push != push_double, "overloads keep one label and two ids (a hash of each signature)");
    CHECK(nodes.count(lambda), "a lambda is its own node, never its function");
    CHECK(nodes.count(grow) && std::none_of(bin["nodes"].begin(), bin["nodes"].end(), [](const J& n) { return n["label"].get<std::string>().find("clone") != std::string::npos; }),
          "a clone folds into its function, even one with no plain copy left");
    CHECK(std::count_if(bin["nodes"].begin(), bin["nodes"].end(), [](const J& n) { return n["label"] == "fox::Queue::grow"; }) == 1,
          "only copies left (.isra.0 and its cold part): still one node");
    for (const auto& n : bin["nodes"]) if (n["label"] == "fox::Queue::grow") {
        // what it is in the binary (Codex's #15): its symbol as linked, and the copy folded into it
        CHECK(n["binary"]["symbol"].get<std::string>().find("grow") != std::string::npos && n["binary"]["clones"].size() == 1
              && n["binary"]["clones"][0].get<std::string>().find(".cold") != std::string::npos,
              "grow's node: its hot copy's symbol, its cold part kept as a clone");
    }
    {
        // a source function matched to a binary one takes what it is there
        J src = J::parse(R"({"nodes": [{"id": "q.cpp::grow", "label": "fox::Queue::grow", "kind": "function", "file": "q.cpp", "line": 3}], "edges": []})");
        J bn = J::parse(R"({"nodes": [{"id": "bin:fox::Queue::grow", "label": "fox::Queue::grow", "kind": "function", "file": "q.cpp", "line": 3,
            "binary": {"symbol": "fox::Queue::grow() [clone .isra.0]", "clones": ["fox::Queue::grow() [clone .isra.0] [clone .cold]"]}}], "edges": []})");
        const auto m = desk_map::merge(src, bn);
        CHECK(m["nodes"].size() == 1 && m["nodes"][0].contains("binary") && m["nodes"][0]["binary"]["clones"].size() == 1,
              "merged: the source function carries its binary symbol and clones");
    }
    CHECK(nodes.count("bin:helper@1300") && nodes.count("bin:helper@1400") && !nodes.count("bin:helper"), "two static functions with one name keep their addresses");
    CHECK(!nodes.count("bin:_start") && !nodes.count("bin:frame_dummy") && !nodes.count("bin:_init") && !nodes.count("bin:register_tm_clones"), "C start-up code is left out");
    CHECK(!nodes.count("bin:puts") && nodes.count("ext:puts") && nodes.count("ext:abort") && nodes.count("ext:memcpy"), "PLT and GOT calls end at library leaves");
    CHECK(nodes.count("ext:operator delete"), "a library leaf by its name, not its signature");
    for (const auto& n : bin["nodes"]) {
        if (n["id"] == "bin:placed") CHECK(n["file"] == "/work/project/src/placed.cpp" && n["line"] == 12, "debug info: where the function's first instruction is, not where it inlines from");
        if (n["id"] == "bin:main") CHECK(n["file"].is_null(), "no debug info: no file");
    }
    const auto calls = pairs(bin["edges"], "call");
    CHECK(calls.count({push, "ext:abort"}) && calls.count({grow, "ext:abort"}), "the cold part's call belongs to its function");
    CHECK(calls.count({"bin:main", push}) && calls.count({"bin:main", "ext:puts"}) && calls.count({"bin:main", "ext:memcpy"}), "direct, PLT and GOT calls");
    CHECK(calls.count({"bin:main", "ext:(indirect)"}) && calls.count({vec, "ext:(indirect)"}), "indirect calls (x86 *reg, through a pointer variable, aarch64 blr) end at one leaf");
    CHECK(calls.count({push, grow}), "a bare jmp to another function's start is a tail call");
    CHECK(calls.count({"bin:helper@1400", "bin:helper@1300"}), "a tail call between two functions of one name");
    CHECK(calls.count({"bin:walk", "bin:walk"}), "recursion is an edge to itself");
    CHECK(calls.count({"bin:helper@1300", "bin:walk"}), "raw instruction bytes before the instruction are skipped");
    CHECK(calls.count({vec, "bin:leaf_a64"}), "aarch64's bl, tab-separated");
    CHECK(calls.count({"bin:placed", push_double}) && calls.count({"bin:placed", lambda}) && calls.count({"bin:placed", "bin:run"}), "calls under -l's location lines");
    CHECK(!calls.count({"bin:main", "bin:frame_dummy"}) && !calls.count({"bin:main", "bin:main"}), "calls into start-up code and jumps inside a function are no edges");
    CHECK(bin["edges"].size() == calls.size(), "every binary edge is kind call, one per pair");
    CHECK(bin["stats"]["tail_calls"] == 2, "two tail calls counted");

    // ─── names ─────────────────────────────────────────────────────────────────────────────────────────────────
    CHECK(desk_map::strip_clones("foo.isra.0.cold") == "foo" && desk_map::strip_clones("f.part.1") == "f" && desk_map::strip_clones("g.llvm.4711") == "g", "C clone suffixes");
    CHECK(desk_map::strip_clones("Q::f(int) [clone .constprop.0] [clone .cold]") == "Q::f(int)" && desk_map::strip_clones("vector_grow2") == "vector_grow2", "C++ clone marks; a digit in a name stays");
    CHECK(desk_map::match_key("fox::Queue<int>::push(int) const") == "fox::Queue::push", "parameters, qualifiers, template arguments go");
    CHECK(desk_map::match_key("void std::sort<int*>(int*, int*)") == "std::sort", "a template's return type goes");
    CHECK(desk_map::match_key("(anonymous namespace)::helper()") == "helper" && desk_map::match_key("Q::~Q()") == "Q::~Q", "anonymous namespaces; destructors");
    CHECK(desk_map::match_key("Q::operator==(Q const&) const") == "Q::operator==" && desk_map::match_key("Q::operator<<(int)") == "Q::operator<<", "operators keep their names");
    CHECK(desk_map::match_key("Q::operator()(int) const") == "Q::operator()" && desk_map::match_key("Q::operator()") == "Q::operator()" && desk_map::match_key("Q::operator[](long)") == "Q::operator[]", "call and index operators");
    CHECK(desk_map::match_key("operator new(unsigned long)") == "operator new" && desk_map::match_key("Queue<T>::push") == "Queue::push", "operator new; treesitter's templated scope");
    CHECK(desk_map::match_key("(anonymous namespace)::f(std::map<int, int> const&)::{lambda(int)#1}::operator()(int) const") == "f()::{lambda()#1}::operator()", "a lambda keeps where it is");
    const std::string longest = "(anonymous namespace)::map_query(std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const&, "
        "std::map<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::__cxx11::basic_string<char, std::char_traits<char>, "
        "std::allocator<char> >, std::less<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::allocator<std::pair<"
        "std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, "
        "std::allocator<char> > > > >&)";
    CHECK(desk_map::match_key(longest) == "map_query", "a signature far longer than a label may be");
    CHECK(desk_map::module_of("src/desk-work/main.cpp") == "src/desk-work" && desk_map::module_of("tests/test_x.py") == "tests", "a part is a top folder, or the folder inside a holder like src");
    CHECK(desk_map::module_of("README.md") == "(top level)" && desk_map::module_of("", "ext:puts") == "(library)" && desk_map::module_of("", "bin:x") == "(binary)", "files at the top, libraries, the binary's own");
    CHECK(desk_map::module_of("", "bin:std::vector::push_back") == "(library)" && desk_map::module_of("", "bin:__gnu_cxx::f") == "(library)", "the C++ runtime's code compiled in is library code");
    CHECK(desk_map::module_of("src/main.cpp") == "src", "a file directly in a holder");

    // ─── merging ───────────────────────────────────────────────────────────────────────────────────────────────
    const J syntax = desk_map::clean_graph(J{{"nodes", J::array({
        node("a.cpp::main", "main", "a.cpp", 3), node("q.hpp::fox::Queue::push", "fox::Queue::push", "q.hpp", 10),
        node("w.cpp::walk", "walk", "w.cpp", 1), node("w.cpp::walk#2", "walk", "w.cpp", 9), node("x.lua::grow", "grow", "x.lua", 1),
        node("h.c::helper", "helper", "h.c", 2), node("src/placed.cpp::placed", "placed", "src/placed.cpp", 12),
        node("src/other.cpp::placed", "placed", "src/other.cpp", 1), node("evil", "x", "/etc/passwd", 1)})},
        {"edges", J::array({edge("a.cpp::main", "src/placed.cpp::placed"), edge("a.cpp::main", "nowhere")})},
        {"spans", J{{"a.cpp::main", J::array({3, 20})}, {"stray", J::array({1, 2})}}}});
    CHECK(syntax["nodes"].size() == 9 && syntax["nodes"][8]["file"].is_null(), "an absolute file is dropped from a node");
    CHECK(syntax["edges"].size() == 1 && !syntax["spans"].contains("stray"), "edges and spans to unknown nodes are dropped");
    J placed_bin = bin;   // as desk-work hands it over: the debug info's paths made relative to the checkout
    for (auto& n : placed_bin["nodes"]) if (n["file"] == "/work/project/src/placed.cpp") n["file"] = "src/placed.cpp";
    const auto merged = desk_map::merge(syntax, desk_map::clean_graph(placed_bin));
    const auto mids = ids(merged["nodes"]);
    CHECK(!mids.count("bin:main"), "a function both readers found is one node");
    CHECK(!mids.count("bin:placed") && mids.count("src/other.cpp::placed"), "with debug info, the same name in the same file: another of that name elsewhere is no obstacle");
    CHECK(merged["matched"] == 2, "main and placed matched");
    CHECK(mids.count(push) && mids.count(push_double) && mids.count("q.hpp::fox::Queue::push"), "two overloads in the binary: neither is taken for the one in the source");
    CHECK(mids.count("bin:walk") && mids.count("w.cpp::walk") && mids.count("w.cpp::walk#2"), "two syntax nodes of one name: not merged");
    CHECK(mids.count("bin:helper@1300") && mids.count("h.c::helper"), "two binary functions of one name: not merged");
    CHECK(mids.count(grow) && mids.count("x.lua::grow"), "a Lua function never meets a compiled one");
    const auto all = pairs(merged["edges"]);
    CHECK(all.count({"a.cpp::main", push}), "binary edges move onto the merged nodes");
    std::set<std::string> kinds;
    for (const auto& e : merged["edges"]) if (e["from"] == "a.cpp::main" && e["to"] == "src/placed.cpp::placed") kinds.insert(e["kind"].get<std::string>());
    CHECK(kinds == std::set<std::string>({"call", "call-by-name"}), "each edge keeps its kind: an exact call and a call by name stay two");
    for (const auto& n : merged["nodes"]) if (n["id"] == "bin:helper@1300") CHECK(n["detail"] == "in the binary only", "a function only the binary has says so");
    CHECK(merged["spans"].contains("a.cpp::main"), "spans come along");
    // A checkout of many programs: "trim" in two of them; the binary built in b/ is b's.
    const J trims = desk_map::clean_graph(J{{"nodes", J::array({node("a/x.cpp::trim", "trim", "a/x.cpp", 1), node("b/y.cpp::trim", "trim", "b/y.cpp", 1)})}});
    const J built = desk_map::clean_graph(J{{"nodes", J::array({node("bin:trim", "trim", "", 0)})}});
    CHECK(desk_map::merge(trims, built, "b/")["matched"] == 1 && !ids(desk_map::merge(trims, built, "b/")["nodes"]).count("bin:trim"), "the binary's own folder breaks the tie");
    CHECK(desk_map::merge(trims, built, "")["matched"] == 0 && desk_map::merge(trims, built, "c/")["matched"] == 0, "without that, a tie stays two nodes");

    // ─── queries ───────────────────────────────────────────────────────────────────────────────────────────────
    // a → b → c → a (a cycle), a → d → e, b → d (d is reached twice), e → f → g (deep), x alone.
    J doc{{"nodes", J::array({node("m/a.lua::a", "M.a", "m/a.lua", 1), node("m/a.lua::b", "M.b", "m/a.lua", 5), node("m/b.lua::c", "c", "m/b.lua", 1),
                              node("n/d.lua::d", "d", "n/d.lua", 1), node("n/d.lua::e", "e", "n/d.lua", 4), node("n/f.lua::f", "f", "n/f.lua", 1),
                              node("n/f.lua::g", "g", "n/f.lua", 3), node("n/f.lua::x", "x", "n/f.lua", 8), node("n/f.lua::T", "T", "n/f.lua", 10, "type"),
                              node("n/f.lua::T.m", "T.m", "n/f.lua", 11), node("m/b.lua::dup", "dup", "m/b.lua", 9), node("n/d.lua::dup", "dup", "n/d.lua", 9)})},
          {"edges", J::array({edge("m/a.lua::a", "m/a.lua::b"), edge("m/a.lua::b", "m/b.lua::c"), edge("m/b.lua::c", "m/a.lua::a", "call"),
                              edge("m/a.lua::a", "n/d.lua::d"), edge("m/a.lua::b", "n/d.lua::d"), edge("n/d.lua::d", "n/d.lua::e"),
                              edge("n/d.lua::e", "n/f.lua::f"), edge("n/f.lua::f", "n/f.lua::g"), edge("n/f.lua::T", "n/f.lua::T.m", "contains")})},
          {"spans", J{{"m/a.lua::a", J::array({1, 4})}, {"m/a.lua::b", J::array({5, 9})}, {"n/f.lua::T", J::array({10, 20})}, {"n/f.lua::T.m", J::array({11, 14})}}}};
    const desk_map::Graph g(doc);
    const auto at = [&](const std::string& id) { return g.at.at(id); };
    auto reach = desk_map::walk(g, at("m/a.lua::a"), 3, false, 100);
    CHECK(reach["q"] == "reach" && reach["from"]["id"] == "m/a.lua::a", "reach names where it starts");
    const auto* back = step(reach, "m/b.lua::c", "m/a.lua::a");
    CHECK(back && (*back)["mark"] == "seen" && back->value("cycle", false) && (*back)["kind"] == "call", "the call back to the start is marked as a cycle");
    CHECK(step(reach, "m/a.lua::a", "m/a.lua::b") && step(reach, "m/a.lua::a", "m/a.lua::b")->value("cycle", false), "every call on the cycle carries the mark");
    CHECK(step(reach, "m/a.lua::a", "n/d.lua::d") && !(*step(reach, "m/a.lua::a", "n/d.lua::d")).contains("cycle"), "a call off the cycle does not");
    CHECK((*step(reach, "m/a.lua::b", "n/d.lua::d"))["mark"] == "seen", "a node reached twice is read once");
    CHECK((*step(reach, "n/d.lua::e", "n/f.lua::f"))["mark"] == "capped" && !step(reach, "n/f.lua::f", "n/f.lua::g"), "depth 3 stops at f, which calls more");
    int deepest = 0;
    for (const auto& n : reach["nodes"]) deepest = std::max(deepest, n["depth"].get<int>());
    CHECK(deepest == 3 && reach["nodes"][0]["depth"] == 0, "each node at its nearest depth");
    CHECK(reach["nodes"][0]["module"] == "m", "nodes say their part");
    auto deep = desk_map::walk(g, at("m/a.lua::a"), 12, false, 100);
    CHECK((*step(deep, "n/f.lua::f", "n/f.lua::g"))["mark"] == "leaf", "deeper, g is a leaf");
    auto few = desk_map::walk(g, at("m/a.lua::a"), 12, false, 2);
    CHECK(few["steps"].size() == 2 && few["more"].get<int>() > 0 && few["capped"] == true, "the step cap says how many were left out");
    auto callers = desk_map::walk(g, at("n/d.lua::d"), 1, true, 100);
    CHECK(callers["q"] == "callers" && callers["steps"].size() == 2 && step(callers, "m/a.lua::a", "n/d.lua::d") && step(callers, "m/a.lua::b", "n/d.lua::d"), "callers, one deep, in the call's direction");
    auto callers2 = desk_map::walk(g, at("n/d.lua::d"), 5, true, 100);
    CHECK(step(callers2, "m/b.lua::c", "m/a.lua::a") != nullptr, "callers deeper go round the cycle");
    CHECK(desk_map::walk(g, at("n/f.lua::x"), 3, false, 100)["steps"].empty(), "a function calling nothing reaches nothing");

    auto ways = desk_map::paths(g, at("m/a.lua::a"), at("n/f.lua::g"), 10, 20);
    CHECK(ways["paths"].size() == 2, "two ways from a to g");
    CHECK(ways["paths"][0]["nodes"].size() == 5 && ways["paths"][1]["nodes"].size() == 6, "the shortest first");
    CHECK(ways["paths"][0]["kinds"].size() == 4 && ways["capped"] == false, "a kind for each call on the way");
    CHECK(desk_map::paths(g, at("m/a.lua::a"), at("n/f.lua::g"), 3, 20)["paths"].empty(), "nothing within too few calls");
    CHECK(desk_map::paths(g, at("n/f.lua::g"), at("m/a.lua::a"), 10, 20)["paths"].empty(), "no way back from a leaf");
    auto one = desk_map::paths(g, at("m/a.lua::a"), at("n/f.lua::g"), 10, 1);
    CHECK(one["paths"].size() == 1 && one["capped"] == true, "the way cap");
    auto loop = desk_map::paths(g, at("m/a.lua::a"), at("m/a.lua::a"), 10, 20);
    CHECK(loop["paths"].size() == 1 && loop["paths"][0]["nodes"].size() == 4, "a function's way back to itself is its cycle");

    auto parts = desk_map::modules(g);
    CHECK(parts["modules"].size() == 2 && parts["modules"][0]["name"] == "m" && parts["modules"][0]["files"] == 2 && parts["modules"][0]["functions"] == 4, "parts with their sizes");
    CHECK(parts["modules"][1]["types"] == 1, "types counted apart");
    CHECK(parts["edges"].size() == 1 && parts["edges"][0]["from"] == "m" && parts["edges"][0]["to"] == "n" && parts["edges"][0]["count"] == 2, "distinct calls between parts");
    auto inside = desk_map::module_contents(g, "n", 100);
    CHECK(inside["files"].size() == 2 && inside["nodes"].size() == 8, "a part's files and nodes");
    CHECK(ids(inside["outside"]) == std::set<std::string>({"m/a.lua::a", "m/a.lua::b"}), "the far ends of calls into it");
    CHECK(pairs(inside["edges"], "contains").count({"n/f.lua::T", "n/f.lua::T.m"}), "a class's methods come with it");
    auto capped = desk_map::module_contents(g, "n", 3);
    CHECK(capped["nodes"].size() == 3 && capped["more"] == 5, "the node cap says how many more");
    CHECK(desk_map::module_contents(g, "zz", 100)["ok"] == false, "an unknown part is refused, naming the ones there are");

    CHECK(desk_map::resolve(g, "m/a.lua::a").index == static_cast<long>(at("m/a.lua::a")), "an id");
    CHECK(desk_map::resolve(g, "M.a").index == static_cast<long>(at("m/a.lua::a")), "a label");
    CHECK(desk_map::resolve(g, "m").index == static_cast<long>(at("n/f.lua::T.m")), "a unique last part");
    auto two = desk_map::resolve(g, "dup");
    CHECK(two.index < 0 && two.candidates.size() == 2, "several: refused with the candidates");
    CHECK(desk_map::resolve(g, "nope").index < 0 && desk_map::resolve(g, "nope").candidates.empty(), "nothing: refused");

    // ─── what a commit touched ─────────────────────────────────────────────────────────────────────────────────
    const auto ranges = desk_map::diff_ranges(
        "diff --git a/m/a.lua b/m/a.lua\n--- a/m/a.lua\n+++ b/m/a.lua\n@@ -2 +2 @@ x\n-a\n+b\n@@ -30,2 +29,0 @@\n"
        "diff --git a/n/f.lua b/n/f.lua\n--- a/n/f.lua\n+++ b/n/f.lua\n@@ -12,1 +12,2 @@\n+y\n@@ -18 +19 @@\n"
        "diff --git a/gone.lua b/gone.lua\n--- a/gone.lua\n+++ /dev/null\n@@ -1,3 +0,0 @@\n"
        "diff --git a/\"sp ace.lua\" b/\"sp ace.lua\"\n+++ \"b/sp\\303\\251.lua\"\n@@ -0,0 +1,2 @@\n");
    CHECK(ranges.at("m/a.lua") == (std::vector<std::pair<long, long>>{{2, 2}, {29, 29}}), "changed lines, and the line a deletion follows");
    CHECK(ranges.at("n/f.lua") == (std::vector<std::pair<long, long>>{{12, 13}, {19, 19}}) && !ranges.count("gone.lua"), "a count; a deleted file has no new side");
    CHECK(ranges.count("sp\xc3\xa9.lua") == 1, "a quoted path is unquoted");
    CHECK(desk_map::unquote("\"Icon\\r\"") == "Icon\r" && desk_map::unquote("\"a\\tb\\\\c\\\"d\\v\"") == "a\tb\\c\"d\v",
          "each of git's C escapes is decoded (a macOS Icon\\r file)");
    auto hit = desk_map::touched(g, ranges);
    const auto touched = ids(hit["nodes"]);
    CHECK(touched.count("m/a.lua::a") && !touched.count("m/a.lua::b"), "the function around the change");
    CHECK(touched.count("n/f.lua::T.m") && touched.count("n/f.lua::T"), "a method's edit touches the method; the class's own line (19) the class");
    auto method_only = desk_map::touched(g, desk_map::Ranges{{"n/f.lua", {{12, 13}}}});
    CHECK(ids(method_only["nodes"]) == std::set<std::string>({"n/f.lua::T.m"}), "an edit inside a method is not the whole class's");

    // ─── staleness ─────────────────────────────────────────────────────────────────────────────────────────────
    const J then{{"head", "aaaaaaaaaa"}, {"dirty", "d1"}, {"binary", J{{"path", "/b"}, {"size", 10}, {"mtime", 5}}}};
    CHECK(desk_map::stale_reason(then, then, false).empty() && desk_map::stale_reason(then, then, true).empty(), "the same: not stale");
    CHECK(desk_map::stale_reason(then, J{{"head", "bbbbbbbbbb"}, {"dirty", "d1"}}, false) == "HEAD moved: aaaaaaa → bbbbbbb", "HEAD moved");
    CHECK(desk_map::stale_reason(then, J{{"head", "aaaaaaaaaa"}, {"dirty", "d2"}, {"dirty_count", 3}}, false).find("3 changed files") == 0, "changed files");
    CHECK(desk_map::stale_reason(then, J{{"head", "aaaaaaaaaa"}, {"dirty", "d2"}, {"dirty_count", 0}}, false).find("put back or committed") != std::string::npos, "edits undone");
    CHECK(desk_map::stale_reason(then, J{{"head", "x"}, {"binary", J{{"path", "/b"}, {"size", 11}, {"mtime", 5}}}}, true) == "the binary was rebuilt", "a rebuilt binary; HEAD does not matter to it");
    CHECK(desk_map::stale_reason(then, J{{"binary", J{{"path", "/b"}, {"size", -1}}}}, true) == "the binary is gone", "a binary gone");

    const auto text = desk_map::dot(g, "modules", "");
    CHECK(text.rfind("digraph", 0) == 0 && text.find("\"m\" -> \"n\" [label=\"2\"]") != std::string::npos, "DOT at the module level");
    CHECK(desk_map::dot(g, "functions", "n").find("[style=dotted, arrowhead=none]") != std::string::npos, "DOT at the function level");

    // ─── the trace's facts: a function's signature and a call's arguments, kept bounded through cleaning and merging ───
    {
        J raw = J::parse(R"({"nodes": [
            {"id": "a.cpp::f", "label": "f", "kind": "function", "file": "a.cpp", "line": 3, "returns": "const Book *",
             "params": [{"name": "tick", "type": "const Tick &", "pass": "const ref", "dir": "in"},
                        {"name": "out", "type": "Order *", "pass": "pointer", "dir": "inout"},
                        {"name": "bad", "type": "X", "pass": "teleported", "dir": "in"},
                        {"name": "worse", "type": "X", "pass": "value", "dir": "sideways"}, 7]},
            {"id": "a.cpp::g", "label": "g", "kind": "function", "file": "a.cpp", "line": 9}],
          "edges": [{"from": "a.cpp::f", "to": "a.cpp::g", "kind": "call-by-name", "line": 5, "args": ["tick", 3, "&o"]}]})");
        for (int i = 0; i < 20; ++i) raw["nodes"][0]["params"].push_back(J{{"name", "p"}, {"type", "int"}, {"pass", "value"}, {"dir", "in"}});
        raw["nodes"][0]["params"][0]["type"] = std::string(500, 'T');
        const auto clean = desk_map::clean_graph(raw);
        const auto& f = clean["nodes"][0];
        CHECK(f["returns"] == "const Book *" && f["params"].size() == 16, "a signature is kept: its return, at most 16 parameters");
        CHECK(f["params"][1] == J({{"name", "out"}, {"type", "Order *"}, {"pass", "pointer"}, {"dir", "inout"}}),
              "… each { name, type, pass, dir } as the reader gave it");
        CHECK(f["params"][0]["type"].get<std::string>().size() == 120, "… a type cut to 120 characters");
        CHECK(std::none_of(f["params"].begin(), f["params"].end(), [](const J& p) { return p["name"] == "bad" || p["name"] == "worse"; }),
              "… a pass or dir outside their closed sets is dropped, not trusted");
        CHECK(!clean["nodes"][1].contains("params"), "a node without them gets none");
        const auto& call = clean["edges"][0];
        CHECK(call["line"] == 5 && call["args"] == J({"tick", "&o"}), "a call keeps its line and its string arguments");
        const auto merged = desk_map::merge(clean, desk_map::clean_graph(J::parse(R"({"nodes": [], "edges": []})")));
        CHECK(merged["nodes"][0]["params"].size() == 16 && merged["edges"][0]["args"] == J({"tick", "&o"}), "… and the merge keeps both");
        // A call the reader could not tell apart by name, on the function that makes it (at most 8, a count of 2+).
        J amb = raw;
        amb["nodes"][1]["ambiguous"] = J::array({J{{"name", "send"}, {"count", 2}, {"line", 4}}, J{{"name", "solo"}, {"count", 1}}, "x"});
        const auto amb_clean = desk_map::clean_graph(amb);
        CHECK(amb_clean["nodes"][1].value("ambiguous", J::array()) == J::array({J{{"name", "send"}, {"count", 2}, {"line", 4}}}),
              "an ambiguous call kept on its caller (one that matched once, or not an object, dropped)");
        // The #if branch a function is in, and whether the flags turn it on: kept (a bad active dropped, text cut to 120).
        {
            J cond = raw;
            cond["nodes"][1]["cond"] = J{{"text", "#ifdef LINUX"}, {"active", true}};
            cond["nodes"][0]["cond"] = J{{"text", std::string(300, 'x')}, {"active", "yes"}};
            const auto kept = desk_map::clean_graph(cond);
            CHECK(kept["nodes"][1].value("cond", J()) == J({{"text", "#ifdef LINUX"}, {"active", true}}) && kept["nodes"][0]["cond"]["text"].get<std::string>().size() == 120
                  && !kept["nodes"][0]["cond"].contains("active"), "a function's #if branch kept, whether it is on only as true or false");
        }
        // What a rebuild changed (Codex's #42): calls and functions added and removed, source found and lost, and why.
        {
            J prev = J::parse(R"({"head": "aaaaaaa1", "dirty": "x", "built_at": 10, "binary": "/b/app",
                "binary_stamp": {"path": "/b/app", "size": 1, "mtime": 5},
                "providers": [{"name": "syntax", "notes": ["no treesitter parser for .zig 2"]}],
                "nodes": [{"id": "f", "label": "f", "file": "a.c"}, {"id": "g", "label": "g", "file": null}, {"id": "old", "label": "old", "file": "a.c"}],
                "edges": [{"from": "f", "to": "g", "kind": "call"}, {"from": "f", "to": "old", "kind": "call"}]})");
            J now = prev;
            now["head"] = "bbbbbbb2"; now["built_at"] = 20;
            now["binary_stamp"]["mtime"] = 6;
            now["providers"] = J::parse(R"([{"name": "syntax", "notes": []}])");
            now["nodes"] = J::parse(R"([{"id": "f", "label": "f", "file": "a.c"}, {"id": "g", "label": "g", "file": "b.c"}, {"id": "new", "label": "new", "file": "b.c"}])");
            now["edges"] = J::parse(R"([{"from": "f", "to": "g", "kind": "call"}, {"from": "g", "to": "new", "kind": "call-by-name"}])");
            const auto c = desk_map::changes(prev, now);
            CHECK(c["edges_added"] == 1 && c["edges_removed"] == 1 && c["nodes_added"] == 1 && c["nodes_removed"] == 1
                  && c["edges_added_list"][0]["to"] == "new" && c["nodes_removed_list"][0]["label"] == "old", "a rebuild: the calls and functions it added and removed");
            CHECK(c["found_source"] == 1 && c["lost_source"] == 0, "… g found its source");
            CHECK(c["because"] == J({"the source changed (aaaaaaa → bbbbbbb)", "the binary was rebuilt", "a parser became available"}),
                  "… and why: the source, the binary rebuilt, a parser now there");
            CHECK(desk_map::changes(J(), now).value("first", false), "the first build: nothing to compare");
            // where each change is, to open it (Codex's E9): an added call in the caller's file today, a removed one and a
            // removed function in the source the build before read
            J lined_prev = prev, lined_now = now;
            lined_prev["nodes"][0]["line"] = 3; lined_prev["nodes"][2]["line"] = 9;
            lined_prev["edges"][1]["line"] = 5;
            lined_now["nodes"][1]["line"] = 1;
            lined_now["edges"][1]["line"] = 2;
            const auto w = desk_map::changes(lined_prev, lined_now);
            const auto& added = w["edges_added_list"][0];
            const auto& removed = w["edges_removed_list"][0];
            CHECK(added.value("file", "") == "b.c" && added.value("line", 0) == 2 && removed.value("file", "") == "a.c" && removed.value("line", 0) == 5,
                  "an added call: its caller's file and the call's line now; a removed one: as the build before had them");
            CHECK(w["nodes_removed_list"][0].value("file", "") == "a.c" && w["nodes_removed_list"][0].value("line", 0) == 9, "… a removed function: its file and line then");
            CHECK(w.value("head", "") == "bbbbbbb2" && w.value("previous_head", "") == "aaaaaaa1", "… and the two builds' commits");
        }
        // What the reader left out, counted: kept as whole numbers, never a string or a negative.
        J counted = raw;
        counted["nodes"][0]["params_more"] = 4;
        counted["nodes"][0]["params"][0]["reads"] = J::array({"px"});
        counted["nodes"][0]["params"][0]["reads_more"] = 2;
        counted["nodes"][0]["params"][1]["writes_more"] = "lots";
        counted["edges"][0]["args_more"] = 3;
        counted["edges"][0]["sites_more"] = -1;
        counted["edges"][0]["sites"] = J::array({J{{"line", 5}, {"args_more", 3}}});
        const auto kept = desk_map::clean_graph(counted);
        CHECK(kept["nodes"][0].value("params_more", 0) == 4 && kept["nodes"][0]["params"][0].value("reads_more", 0) == 2 && !kept["nodes"][0]["params"][1].contains("writes_more"),
              "what the reader left out: the parameters and fields it counted (a count that is not a number dropped)");
        CHECK(kept["edges"][0].value("args_more", 0) == 3 && !kept["edges"][0].contains("sites_more") && kept["edges"][0]["sites"][0].value("args_more", 0) == 3,
              "… a call's arguments, on the call and its site (a negative count dropped)");
        J flow = kept;
        flow["nodes"][1]["params"] = J::array();
        const desk_map::Graph cg(flow);
        CHECK(desk_map::trace(cg, cg.at.at("a.cpp::f"), 16)["calls"][0].value("args_more", 0) == 3, "… and it reaches the trace's call");
    }
    // ─── the trace: one lane through a function, up to where it starts and down to where it ends ───
    {
        // entry → a → F → b → c → end, with a side caller s → F, a side callee F → x, a cycle c → b, and an outside
        // caller of a (deeper: entry2 → mid → a, so entry2 is the farthest start).
        J doc = J::parse(R"({"nodes": [], "edges": []})");
        for (const char* id : {"entry", "entry2", "mid", "a", "F", "b", "c", "end", "s", "x"})
            doc["nodes"].push_back(J{{"id", id}, {"label", id}, {"kind", "function"}, {"file", "f.cpp"}, {"line", 1}});
        doc["nodes"][4]["params"] = J::array({J{{"name", "t"}, {"type", "const T &"}, {"pass", "const ref"}, {"dir", "in"},
                                                 {"reads", J::array({"px", "ts", 7})}, {"writes", J::array({"seq"})}}});
        const auto call = [&](const char* a, const char* b) { doc["edges"].push_back(J{{"from", a}, {"to", b}, {"kind", "call-by-name"}}); };
        call("entry", "a"); call("entry2", "mid"); call("mid", "a"); call("a", "F"); call("s", "F"); call("F", "b"); call("F", "x");
        call("b", "c"); call("c", "b"); call("c", "end");
        doc["edges"][3]["line"] = 12; doc["edges"][3]["args"] = J::array({"tick"});
        doc["spans"] = J::object();
        doc["spans"]["F"] = J::array({10, 41});
        const desk_map::Graph g(doc);
        const auto lane = [](const J& t) { std::vector<std::string> ids; for (const auto& st : t["steps"]) ids.push_back(st["id"]); return ids; };
        const auto t = desk_map::trace(g, g.at.at("F"), 16);
        CHECK(lane(t) == std::vector<std::string>({"entry2", "mid", "a", "F", "b", "c", "end"}),
              "the lane: up to the farthest start (entry2, not entry), down to the farthest end, a cycle walked once");
        CHECK(t["steps"][3]["role"] == "focus" && t["steps"][0]["role"] == "up" && t["steps"][6]["role"] == "down", "… each step says where it is");
        // the other starts (T3, 2026-11-19: on the trader the farthest start was main → the backtest GUI, not the live
        // producer thread): every function above F that nothing calls, farthest first, the one picked left out
        std::vector<std::string> others;
        for (const auto& st : t.value("starts", J::array())) others.push_back(st["id"]);
        CHECK(others == std::vector<std::string>({"entry", "s"}), "the other starts: entry (2 calls up), then s (1)");
        CHECK(t["steps"][3]["params"][0]["pass"] == "const ref", "… with its signature");
        CHECK(desk_map::clean_graph(doc)["nodes"][4]["params"][0]["reads"] == J({"px", "ts"}) && desk_map::clean_graph(doc)["nodes"][4]["params"][0]["writes"] == J({"seq"}),
              "… and what it reads and writes of each parameter, strings only");
        CHECK(t["steps"][3]["lines"] == 32 && !t["steps"][2].contains("lines"), "… and how big it is, where the reader gave its lines");
        // F: up are a, s, entry, mid, entry2 (5); down b, x, c, end (4).
        CHECK(t["steps"][3]["before"] == 5 && t["steps"][3]["after"] == 4, "… and how many come before it and after it");
        CHECK(t["steps"][3]["more_callers"] == 1 && t["steps"][3]["callers"][0]["id"] == "s" && t["steps"][3]["more_callees"] == 1
              && t["steps"][3]["callees"][0]["id"] == "x", "… and what is off the lane: F's other caller s and callee x");
        CHECK(t["steps"][2]["more_callers"] == 1 && t["steps"][2]["callers"][0]["id"] == "entry", "… a's other caller, entry");
        CHECK(t["calls"][2]["from"] == "a" && t["calls"][2]["to"] == "F" && t["calls"][2]["line"] == 12 && t["calls"][2]["args"] == J({"tick"}),
              "the call into each next step, with its line and arguments");
        const auto to_x = desk_map::trace(g, g.at.at("F"), 16, static_cast<long>(g.at.at("x")));
        CHECK(lane(to_x).back() == "x" && to_x["reached"] == true, "--to: down the shortest way to the chosen function");
        const auto to_s = desk_map::trace(g, g.at.at("F"), 16, static_cast<long>(g.at.at("s")));
        CHECK(lane(to_s).back() == "F" && to_s["reached"] == false, "… and says so when it is not below");
        // The whole trace (her ask, 2026-11-19: "an entire trace would be nice"): every way through F in one picture,
        // what leads to it and what it leads to. A way round F (a → g → b) is not through it; nor is what F's callers
        // call besides F.
        J wide = doc;
        wide["nodes"].push_back(J{{"id", "g"}, {"label", "g"}, {"kind", "function"}, {"file", "g.cpp"}, {"line", 3}});
        wide["edges"].push_back(J{{"from", "a"}, {"to", "g"}, {"kind", "call-by-name"}});
        wide["edges"].push_back(J{{"from", "g"}, {"to", "b"}, {"kind", "call-by-name"}});
        wide["edges"].push_back(J{{"from", "s"}, {"to", "x"}, {"kind", "call-by-name"}});   // s calls x itself, not through F
        const desk_map::Graph wg(wide);
        const auto ids = [](const J& f, bool lane_only) {
            std::set<std::string> out;
            for (const auto& n : f["nodes"]) if (!lane_only || n.value("lane", false)) out.insert(n["id"]);
            return out;
        };
        const auto calls_of = [](const J& f) {
            std::set<std::string> out;
            for (const auto& e : f["edges"]) out.insert(e["from"].get<std::string>() + ">" + e["to"].get<std::string>());
            return out;
        };
        const auto fl = desk_map::flow(wg, wg.at.at("F"), 16);
        CHECK(fl["q"] == "flow" && fl["focus"] == "F", "flow: the whole trace through F");
        CHECK(ids(fl, false) == std::set<std::string>({"entry", "entry2", "mid", "a", "s", "F", "b", "x", "c", "end"}),
              "… every caller up to every start (entry and entry2, s), every call down to every end (x and end); g, round F, not");
        CHECK(ids(fl, true) == std::set<std::string>({"entry2", "mid", "a", "F", "b", "c", "end"}), "… the trace's own lane marked");
        const auto e = calls_of(fl);
        CHECK(e.count("s>F") && e.count("F>x") && e.count("c>b") && e.count("entry>a") && !e.count("a>g") && !e.count("g>b")
              && !e.count("s>x"), "… and the calls on those ways, the cycle's too; none round F, none from a caller past it (s → x)");
        for (const auto& n : fl["nodes"])
            if (n["id"] == "entry2") CHECK(n["at"] == -3, "… a caller's place: 3 calls above F");
        bool lined = false;
        for (const auto& ed : fl["edges"]) if (ed["from"] == "a" && ed["to"] == "F") lined = ed.value("line", 0) == 12;
        CHECK(lined, "… each call with its line where the map read one (a → F at 12), for gj's hint");
        const auto fl_x = desk_map::flow(wg, wg.at.at("F"), 16, static_cast<long>(wg.at.at("x")));
        CHECK(fl_x["to"] == "x" && ids(fl_x, false) == std::set<std::string>({"entry", "entry2", "mid", "a", "s", "F", "x"}),
              "--to x: below F only the ways that reach x");
        const auto fl_s = desk_map::flow(wg, wg.at.at("F"), 16, -1, static_cast<long>(wg.at.at("s")));
        CHECK(fl_s["start"] == "s" && ids(fl_s, false) == std::set<std::string>({"s", "F", "b", "x", "c", "end"}),
              "--start s: above F only what s leads through");
        // A handoff (end → consumer, through a ring): walked like a call, said as a handoff with its label.
        J handed = doc;
        handed["nodes"].push_back(J{{"id", "consumer"}, {"label", "consumer"}, {"kind", "function"}, {"file", "f.cpp"}, {"line", 40}});
        handed["edges"].push_back(J{{"from", "end"}, {"to", "consumer"}, {"kind", "handoff"}, {"label", "ring: push :3 → pop :41"}, {"line", 3}});
        const desk_map::Graph hg(desk_map::clean_graph(handed));
        const auto ht = desk_map::trace(hg, hg.at.at("F"), 16);
        CHECK(lane(ht).back() == "consumer", "a handoff carries the lane on past the end of the calls");
        CHECK(ht["calls"].back()["kind"] == "handoff" && ht["calls"].back()["label"] == "ring: push :3 → pop :41",
              "… said as a handoff, with what it went through");
        CHECK(desk_map::paths(hg, hg.at.at("entry"), hg.at.at("consumer"), 16, 5)["paths"].size() == 1, "… and the map's ways go through it");
        // Every call between two kept as its sites, and a handoff's pop line: through the stored graph into the trace.
        J sited = doc;
        for (auto& e : sited["edges"]) if (e["from"] == "a" && e["to"] == "F") e["sites"] = J::array({J{{"line", 12}, {"args", J::array({"tick"})}}, J{{"line", 15}}});
        sited["nodes"].push_back(J{{"id", "consumer"}, {"label", "consumer"}, {"kind", "function"}, {"file", "f.cpp"}, {"line", 40}});
        sited["edges"].push_back(J{{"from", "end"}, {"to", "consumer"}, {"kind", "handoff"}, {"label", "ring"}, {"line", 3}, {"to_line", 41}});
        const desk_map::Graph sg(desk_map::clean_graph(sited));
        const auto st = desk_map::trace(sg, sg.at.at("F"), 16);
        const auto sites = st["calls"][2].value("sites", J::array());
        CHECK(sites.size() == 2 && sites[1].value("line", 0) == 15, "a call's sites reach the trace, each its line");
        CHECK(st["calls"].back().value("to_line", 0) == 41, "… and a handoff's pop line");
        // No way: where to look next, and why.
        const auto shallow = desk_map::paths(g, g.at.at("entry2"), g.at.at("x"), 1, 5);
        CHECK(shallow["paths"].empty() && shallow["why"] == "depth" && shallow["ends"].size() == 1 && shallow["ends"][0]["id"] == "mid"
              && shallow["callers"].size() == 1 && shallow["callers"][0]["id"] == "F", "no way within 1 call: the search stopped there; mid reached, F calls x");
        const auto dead = desk_map::paths(g, g.at.at("end"), g.at.at("F"), 16, 5);
        CHECK(dead["paths"].empty() && dead["why"] == "ran_out" && dead["ends"].empty() && dead["callers"].size() >= 2,
              "no way at all: both sides ran out of known calls; what calls F listed");
        CHECK(!desk_map::paths(g, g.at.at("entry"), g.at.at("x"), 16, 5).contains("why"), "a way found: no why");
        // Every call into a function with its lines (where its result goes is read from them); a handoff takes no result.
        {
            const auto into = desk_map::calls_into(sg, sg.at.at("F"), 40);
            bool sites_kept = false;
            for (const auto& row : into["callers"]) if (row["node"]["id"] == "a" && row["sites"].size() == 2) sites_kept = true;
            CHECK(sites_kept, "calls into F: a's two call lines kept");
            const auto into_consumer = desk_map::calls_into(sg, sg.at.at("consumer"), 40);
            CHECK(into_consumer["callers"].empty(), "… a handoff into a function is not a call that takes its result");
        }
        // The interface one part uses of another: the calls that cross, by the entry function they reach.
        {
            J parts{{"version", 1}, {"nodes", J::array()}, {"edges", J::array()}};
            for (const auto& [id, file] : std::vector<std::pair<std::string, std::string>>{{"a1", "a/x.cpp"}, {"a2", "a/y.cpp"}, {"b1", "b/z.cpp"}, {"b2", "b/w.cpp"}})
                parts["nodes"].push_back(J{{"id", id}, {"label", id}, {"kind", "function"}, {"file", file}, {"line", 1}});
            for (const auto& [f, t2] : std::vector<std::pair<std::string, std::string>>{{"a1", "b1"}, {"a2", "b1"}, {"a1", "b2"}, {"b1", "b2"}, {"a1", "a2"}})
                parts["edges"].push_back(J{{"from", f}, {"to", t2}, {"kind", "call"}});
            const desk_map::Graph pg(desk_map::clean_graph(parts));
            const auto x = desk_map::crossings(pg, "a", "b", 40);
            CHECK(x["entries"].size() == 2 && x["entries"][0]["node"]["id"] == "b1" && x["entries"][0]["count"] == 2 && x["entries"][1]["node"]["id"] == "b2"
                  && x["calls"] == 3, "a's calls into b by entry function, the most-called first; b's own and a's own calls left out");
        }
        // Her corrections: the handoff dropped is gone; one she adds carries the lane on, marked by_hand.
        const desk_map::Graph dropped(desk_map::corrected(desk_map::clean_graph(handed), J{{"drop", J::array({J{{"from", "end"}, {"to", "consumer"}}})}}));
        CHECK(lane(desk_map::trace(dropped, dropped.at.at("F"), 16)).back() == "end", "a dropped handoff is gone: the lane ends at the calls' end");
        J calls_too = handed;
        calls_too["edges"].push_back(J{{"from", "end"}, {"to", "consumer"}, {"kind", "call"}});
        const desk_map::Graph kept_call(desk_map::corrected(desk_map::clean_graph(calls_too), J{{"drop", J::array({J{{"from", "end"}, {"to", "consumer"}}})}}));
        CHECK(lane(desk_map::trace(kept_call, kept_call.at.at("F"), 16)).back() == "consumer", "… a call between the two stays");
        const desk_map::Graph added(desk_map::corrected(desk_map::clean_graph(handed), J{{"add", J::array({J{{"from", "consumer"}, {"to", "s"}, {"label", "order queue"}},
            J{{"from", "consumer"}, {"to", "nobody"}}, J{{"from", "end"}, {"to", "consumer"}, {"label", "mine"}}})}}));
        const auto at = desk_map::trace(added, added.at.at("F"), 16, static_cast<long>(added.at.at("s")));
        CHECK(lane(at).back() == "s" && at["reached"] == true && at["calls"].back()["kind"] == "handoff" && at["calls"].back()["by_hand"] == true
              && at["calls"].back()["label"] == "order queue", "an added handoff: walked, marked by hand, with her label");
        CHECK(added.all.size() == desk_map::Graph(desk_map::clean_graph(handed)).all.size() + 1,
              "… one naming a function the map does not have, or one already inferred, is skipped");
        const auto from_entry = desk_map::trace(g, g.at.at("F"), 16, -1, static_cast<long>(g.at.at("entry")));
        CHECK(lane(from_entry) == std::vector<std::string>({"entry", "a", "F", "b", "c", "end"}) && from_entry["start_reached"] == true,
              "--start: up from the start she chose (entry, not the farther entry2)");
        const auto from_x = desk_map::trace(g, g.at.at("F"), 16, -1, static_cast<long>(g.at.at("x")));
        CHECK(lane(from_x).front() == "F" && from_x["start_reached"] == false, "… and says so when it does not lead to the function");
        CHECK(lane(desk_map::trace(g, g.at.at("F"), 1)) == std::vector<std::string>({"s", "F", "x"}),
              "depth bounds each way; within it a real start and end win (s and x) over a and b, which go on");
    }
    std::printf("test_map: %d passed%s\n", passed, failed ? (", " + std::to_string(failed) + " failed").c_str() : "");
    return failed ? 1 : 0;
}
