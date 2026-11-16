// desk-result/1, the one shape a declared tool's answer reaches Neovim, the notebook and the drawer in
// (docs/desk-tools.md, "The answer"). This file is the only converter edge: the json shapes, the toolio envelope and
// symdeps' fox-symdeps/2 (both taken as they are), lines, dot and fox-contract/1. A field a format does not have is
// ignored; one it should have and lacks comes out null, read as unknown, never invented. Nothing here runs or writes.

// The formats, and the kinds each can give.
const std::map<std::string, std::set<std::string>>& result_formats() {
    static const std::map<std::string, std::set<std::string>> formats{
        {"json", {"graph", "findings", "figures", "status"}}, {"toolio", {"graph", "findings", "figures", "status"}},
        {"fox-symdeps/2", {"graph", "findings", "figures", "status"}}, {"lines", {"findings", "figures", "status"}},
        {"dot", {"graph"}}, {"fox-contract/1", {"status"}}};
    return formats;
}

// fox-contract/1, the record a contract-test runner writes (symdeps' tests/run.sh writes it after a full run), is read
// through this table alone: when the record's fields move, only these rows change. Each is a JSON pointer; the
// "input …" rows point inside one input of inputs.end (inputs.start when there is no end). Two rows are values, not
// pointers: "tree folder", the folder whose tree id an input keeps, and "input order", the order inputs are shown in.
// Then the record's words for its outcome, as the card's four.
const std::map<std::string, std::string>& contract_fields() {
    static const std::map<std::string, std::string> fields{
        {"kind", "/kind"}, {"started", "/started_epoch"}, {"ended", "/ended_epoch"}, {"log", "/log"},
        {"missing", "/missing"}, {"moved", "/moved"},
        {"state", "/result/state"}, {"why", "/result/why"}, {"summary", "/result/summary"},
        {"passed", "/result/passed"}, {"failed", "/result/failed"}, {"skipped", "/result/skipped"}, {"expected", "/result/expected"},
        {"failed tests", "/result/failed_tests"}, {"skipped tests", "/result/skipped_tests"},
        {"inputs", "/inputs/end"}, {"inputs at start", "/inputs/start"},
        {"input root", "/root"}, {"input how", "/how"}, {"input why", "/why"}, {"input head", "/head"}, {"input commit", "/commit"},
        {"input dirty", "/dirty"}, {"input uncommitted", "/uncommitted"},
        {"input tree", "/tools_tree"}, {"input tree dirty", "/tools_dirty"}, {"input tree uncommitted", "/tools_uncommitted"},
        {"input version", "/toolchain_version"},
        {"tree folder", "tools"}, {"input order", "plugin workspace engine"}};
    return fields;
}
const std::map<std::string, std::string>& contract_states() {
    static const std::map<std::string, std::string> states{
        {"pass", "pass"}, {"passed", "pass"}, {"fail", "fail"}, {"failed", "fail"}, {"partial", "partial"}, {"refused", "refused"}};
    return states;
}

// Where a tool's text came from: the declaration's names, and the file read or the run that printed it.
struct ResultFrom {
    std::string id, name, gives, format, root, command, origin, producer;
    int exit = -1;          // the run's exit status; -1 when the text is a file the tool writes
    long long at = 0;       // when the text was written
};

std::string lowered(std::string s) { std::transform(s.begin(), s.end(), s.begin(), ::tolower); return s; }
// One line of at most `limit` bytes, cut at a character boundary.
std::string one_line(const std::string& text, size_t limit) {
    auto s = clean(text);
    for (auto& c : s) if (c == '\n' || c == '\t') c = ' ';
    s = trim(s);
    if (s.size() <= limit) return s;
    size_t cut = limit;
    while (cut > 0 && (static_cast<unsigned char>(s[cut]) & 0xC0) == 0x80) --cut;
    return s.substr(0, cut) + "\xe2\x80\xa6";
}
J text_or_null(const J& v, size_t limit) { return v.is_string() && !trim(v.get<std::string>()).empty() ? J(one_line(v.get<std::string>(), limit)) : J(); }
J positive(const J& v) { return v.is_number_integer() && v.get<long long>() > 0 ? v : J(); }
J count_or_null(const J& v) { return v.is_number_integer() && v.get<long long>() >= 0 ? v : J(); }
// A one-word kind (function, type, file, task, …), or unknown.
J word(const J& v) {
    if (!v.is_string()) return J();
    const auto s = v.get<std::string>();
    return !s.empty() && s.size() <= 32 && std::all_of(s.begin(), s.end(), [](unsigned char c) { return std::isalnum(c) || c == '_' || c == '-'; }) ? J(s) : J();
}
J severity(const J& v) {
    if (!v.is_string()) return J();
    const auto s = lowered(trim(v.get<std::string>()));
    if (s == "error" || s == "err" || s == "fatal" || s == "failure") return "error";
    if (s == "warn" || s == "warning") return "warn";
    if (s == "info" || s == "note" || s == "hint" || s == "notice") return "info";
    return J();
}
// A file as the checkout names it: an absolute path inside the root becomes relative to it.
J checkout_file(const J& v, const std::string& root) {
    if (!v.is_string() || v.get<std::string>().empty() || v.get<std::string>().size() > 1024) return J();
    const fs::path p = v.get<std::string>();
    if (p.is_absolute() && !root.empty()) {
        const auto rel = p.lexically_normal().lexically_relative(root);
        if (!rel.empty() && *rel.begin() != "..") return rel.string();
    }
    return p.string();
}
std::string node_key(const J& v) {
    if (v.is_string()) return v.get<std::string>().substr(0, 512);
    if (v.is_number_integer()) return std::to_string(v.get<long long>());
    return {};
}
// A value at a JSON pointer, or null: a record of the wrong shape is unknown, never an error.
J at_pointer(const J& doc, const std::string& pointer) {
    try {
        const J::json_pointer p(pointer);
        return doc.contains(p) ? doc.at(p) : J();
    } catch (const std::exception&) { return J(); }
}

J result_base(const ResultFrom& from) {
    J r{{"format", "desk-result/1"},
        {"source", J{{"kind", "tool"}, {"id", from.id}, {"name", from.name},
                     {"producer", J{{"tool", from.producer.empty() ? J() : J(from.producer)}, {"version", nullptr},
                                    {"command", from.command.empty() ? J() : J(from.command)}}}}},
        {"gives", from.gives}, {"read", J{{"format", from.format}, {"from", from.origin}, {"ok", true}}},
        {"at", from.at > 0 ? J(from.at) : J()}, {"about", J::array()}, {"summary", ""}, {"complete", true}, {"why", nullptr},
        {"findings", J::array()}, {"facts", J::array()}};
    if (from.exit >= 0) r["read"]["exit"] = from.exit;
    if (from.gives == "status") r["state"] = "unknown";
    if (from.gives == "graph") r["graph"] = J{{"nodes", J::array()}, {"edges", J::array()}, {"focus", nullptr}};
    return r;
}
// Refuse, never lie: no answer, and why. `unread`: desk-work could not read what the tool wrote (read.ok false), as
// against the tool itself refusing.
J refused_result(J r, const std::string& why, bool unread = false) {
    r["complete"] = false; r["why"] = one_line(why, 500);
    if (unread) r["read"]["ok"] = false;
    if (r.contains("state")) r["state"] = "unknown";
    if (r.value("summary", std::string()).empty()) r["summary"] = one_line(why, 120);
    return r;
}

void add_finding(J& r, const J& file, const J& line, const J& col, const J& sev, const J& message, const J& kind, const std::string& root) {
    auto& list = r["findings"];
    if (list.size() >= 2000) { r["complete"] = false; r["why"] = "over 2000 findings; the rest are left out"; return; }
    list.push_back(J{{"id", "f" + std::to_string(list.size() + 1)}, {"file", checkout_file(file, root)}, {"line", positive(line)},
                     {"col", positive(col)}, {"severity", severity(sev)}, {"kind", word(kind)}, {"message", text_or_null(message, 500)}});
}
void add_fact(J& r, const J& name, const J& value, const J& unit) {
    auto& facts = r["facts"];
    if (!name.is_string() || name.get<std::string>().empty() || facts.size() >= 500) return;
    J fact{{"name", one_line(name.get<std::string>(), 80)}, {"value", value.is_number() ? value : J()},
           {"unit", unit.is_string() && unit.get<std::string>() != "-" ? J(one_line(unit.get<std::string>(), 16)) : J("")}};
    // A name given twice keeps its last value, as a run's printed figures do.
    for (auto& f : facts) if (f["name"] == fact["name"]) { f = fact; return; }
    facts.push_back(fact);
}
void findings_summary(J& r) {
    if (!r.value("summary", std::string()).empty()) return;
    const auto n = r["findings"].size();
    r["summary"] = n == 0 ? std::string("no findings") : std::to_string(n) + (n == 1 ? " finding" : " findings");
}

// A graph's nodes and edges, as the guide's graph shape has them. Caps: 5000 nodes, 20000 edges, past which the graph
// is refused and the tool asked for a part of it (its `around` arguments).
J graph_result(J r, const J& nodes, const J& edges, const J& focus, const std::string& root) {
    if ((nodes.is_array() && nodes.size() > 5000) || (edges.is_array() && edges.size() > 20000))
        return refused_result(r, "over 5000 nodes or 20000 edges: ask the tool for the part around one node (its around arguments)");
    std::set<std::string> seen;
    auto& g = r["graph"];
    for (const auto& n : nodes.is_array() ? nodes : J::array()) {
        if (!n.is_object()) continue;
        const auto id = node_key(n.value("id", J()));
        if (id.empty() || !seen.insert(id).second) continue;
        J node{{"id", id}, {"label", text_or_null(n.value("label", J()), 200)}, {"file", checkout_file(n.value("file", J()), root)},
               {"line", positive(n.value("line", J()))}, {"kind", word(n.value("kind", J()))}};
        if (node["label"].is_null()) node["label"] = id;
        if (n.contains("detail")) node["detail"] = text_or_null(n["detail"], 500);
        if (n.contains("metrics") && n["metrics"].is_object()) node["metrics"] = n["metrics"];
        g["nodes"].push_back(node);
    }
    for (const auto& e : edges.is_array() ? edges : J::array()) {
        if (!e.is_object()) continue;
        const auto from = node_key(e.value("from", J())), to = node_key(e.value("to", J()));
        if (from.empty() || to.empty()) continue;
        J edge{{"from", from}, {"to", to}, {"kind", word(e.value("kind", J()))}};
        if (e.contains("label")) edge["label"] = text_or_null(e["label"], 200);
        g["edges"].push_back(edge);
    }
    const auto f = node_key(focus);
    g["focus"] = f.empty() ? J() : J(f);
    r["summary"] = std::to_string(g["nodes"].size()) + " nodes · " + std::to_string(g["edges"].size()) + " edges";
    return r;
}

// json: the guide's four shapes.
J from_json(const std::string& text, J r, const ResultFrom& from) {
    const auto doc = J::parse(text, nullptr, false);
    if (doc.is_discarded()) return refused_result(r, "the answer is not valid JSON", true);
    if (from.gives == "graph") {
        if (!doc.is_object()) return refused_result(r, "a graph is an object { nodes, edges, complete }", true);
        r = graph_result(r, doc.value("nodes", J()), doc.value("edges", J()), doc.value("focus", J()), from.root);
        if (!r.value("complete", true)) return r;
        // Only the tool knows whether its graph is whole; one that does not say is unknown.
        r["complete"] = doc.contains("complete") && doc["complete"].is_boolean() ? doc["complete"] : J();
        if (doc.contains("why")) r["why"] = text_or_null(doc["why"], 500);
        return r;
    }
    if (from.gives == "findings") {
        if (!doc.is_array()) return refused_result(r, "findings are a list [{ file, line, severity, message }]", true);
        for (const auto& f : doc) if (f.is_object())
            add_finding(r, f.value("file", J()), f.value("line", J()), f.value("col", J()), f.value("severity", J()),
                        f.value("message", J()), f.value("kind", J()), from.root);
        findings_summary(r);
        return r;
    }
    if (from.gives == "figures") {
        if (!doc.is_array()) return refused_result(r, "figures are a list [{ name, value, unit }]", true);
        for (const auto& f : doc) if (f.is_object()) add_fact(r, f.value("name", J()), f.value("value", J()), f.value("unit", J()));
        r["summary"] = std::to_string(r["facts"].size()) + " figures";
        return r;
    }
    if (!doc.is_object()) return refused_result(r, "a status is an object { state, text }", true);
    const auto state = lowered(str(doc, "state"));
    r["state"] = std::set<std::string>{"ok", "warn", "fail", "unknown"}.count(state) ? state : "unknown";
    r["summary"] = one_line(str(doc, "text"), 40);
    return r;
}

// toolio and fox-symdeps/2, taken as they are: { producer, status { ok, code, findings }, target, payload }.
J from_toolio(const std::string& text, J r, const ResultFrom& from) {
    const auto doc = J::parse(text, nullptr, false);
    if (doc.is_discarded() || !doc.is_object()) return refused_result(r, "the answer is not a " + from.format + " envelope (a JSON object)", true);
    if (doc.contains("producer") && doc["producer"].is_object()) {
        const auto& p = doc["producer"];
        r["source"]["producer"] = J{{"tool", text_or_null(p.value("tool", J()), 80)}, {"version", text_or_null(p.value("version", J()), 80)},
                                    {"command", from.command.empty() ? text_or_null(p.value("command", J()), 400) : J(from.command)}};
    }
    if (doc.contains("target") && doc["target"].is_object() && doc["target"].value("git_head", J()).is_string())
        r["about"].push_back(J{{"kind", "checkout"}, {"label", "target"}, {"version", J{{"head", doc["target"]["git_head"]}}}});
    const auto status = doc.value("status", J::object());
    std::vector<std::string> refusals;
    for (const auto& row : status.is_object() ? status.value("findings", J::array()) : J::array()) {
        const auto cell = [&](size_t i, const char* key) { return row.is_array() ? (i < row.size() ? row[i] : J()) : row.is_object() ? row.value(key, J()) : J(); };
        if (cell(2, "severity").is_string() && lowered(cell(2, "severity").get<std::string>()) == "refused") {
            if (cell(3, "message").is_string()) refusals.push_back(cell(3, "message").get<std::string>());
            continue;
        }
        add_finding(r, cell(0, "file"), cell(1, "line"), J(), cell(2, "severity"), cell(3, "message"), cell(4, "kind"), from.root);
    }
    const J code = status.is_object() ? status.value("code", J()) : J();
    if ((code.is_number_integer() && code.get<long long>() == 2) || !refusals.empty()) {
        std::string why;
        for (const auto& reason : refusals) why += (why.empty() ? "" : "; ") + reason;
        return refused_result(r, "refused: " + (why.empty() ? std::string("the tool gave no reason") : why));
    }
    // A payload table, by its column names: rows as objects.
    const auto table = [](const J& t) {
        J rows = J::array();
        if (!t.is_object() || !t.value("schema", J()).is_array() || !t.value("rows", J()).is_array()) return rows;
        const auto& schema = t["schema"];
        for (const auto& row : t["rows"]) {
            if (!row.is_array()) continue;
            J out = J::object();
            for (size_t i = 0; i < schema.size() && i < row.size(); ++i) if (schema[i].is_string()) out[schema[i].get<std::string>()] = row[i];
            rows.push_back(out);
        }
        return rows;
    };
    const auto payload = doc.value("payload", J::object());
    if (from.gives == "graph") {
        if (!payload.is_object() || !payload.contains("nodes")) return refused_result(r, "the envelope has no nodes table (payload.nodes)", true);
        return graph_result(r, table(payload["nodes"]), payload.contains("edges") ? table(payload["edges"]) : J::array(), J(), from.root);
    }
    if (from.gives == "figures" && payload.is_object()) {
        for (const auto& [name, t] : payload.items()) {
            const auto& schema = t.is_object() ? t.value("schema", J::array()) : J::array();
            if (std::find(schema.begin(), schema.end(), J("name")) == schema.end() || std::find(schema.begin(), schema.end(), J("value")) == schema.end()) continue;
            for (const auto& row : table(t)) add_fact(r, row.value("name", J()), row.value("value", J()), row.value("unit", J()));
        }
        r["summary"] = std::to_string(r["facts"].size()) + " figures";
    }
    if (from.gives == "status") {
        const J ok = status.is_object() ? status.value("ok", J()) : J();
        r["state"] = code.is_number_integer() ? (code.get<long long>() == 0 ? "ok" : code.get<long long>() == 1 ? "warn" : "fail")
                   : ok.is_boolean() ? (ok.get<bool>() ? "ok" : "fail") : "unknown";
        const auto n = r["findings"].size();
        r["summary"] = n ? std::to_string(n) + (n == 1 ? " finding" : " findings") : std::string(r["state"] == "ok" ? "answered" : "answered, no findings listed");
    }
    if (from.gives == "findings") findings_summary(r);
    return r;
}

// lines: a status (the last line; a leading ok, warn or fail sets its state, else a run's exit status does),
// compiler-style findings (file:line[:col]: message), or figures read as desk-work reads a run's printed numbers.
J from_lines(const std::string& text, J r, const ResultFrom& from) {
    const auto lines = split(clean(text));
    if (from.gives == "status") {
        std::string last;
        for (auto it = lines.rbegin(); it != lines.rend() && last.empty(); ++it) last = trim(*it);
        std::smatch m;
        if (std::regex_match(last, m, std::regex("(ok|warn|fail|unknown)\\b[:\\s]*(.*)", std::regex::icase))) {
            r["state"] = lowered(m[1].str()); last = m[2].str();
        } else r["state"] = from.exit < 0 ? "unknown" : from.exit == 0 ? "ok" : "fail";
        r["summary"] = one_line(last, 40);
        return r;
    }
    if (from.gives == "findings") {
        const std::regex loc("^\\s*(.+?):([0-9]+)(?::([0-9]+))?:\\s*(?:(fatal error|error|warning|note|info)\\s*:)?\\s*(.*)$", std::regex::icase);
        for (const auto& line : lines) {
            std::smatch m;
            if (line.size() > 4096 || !std::regex_match(line, m, loc)) continue;
            add_finding(r, m[1].str(), count(m[2].str()), m[3].matched ? J(count(m[3].str())) : J(),
                        m[4].matched ? J(lowered(m[4].str()) == "fatal error" ? "error" : m[4].str()) : J(), m[5].str(), J(), from.root);
        }
        findings_summary(r);
        return r;
    }
    for (const auto& line : lines) for (const auto& [name, metric] : metric_line(line)) add_fact(r, name, metric["value"], metric["unit"]);
    r["summary"] = std::to_string(r["facts"].size()) + " figures";
    return r;
}

// dot: a digraph (or graph) as `ninja -t graph` and graphviz writers print it. Node and edge statements, attribute
// lists, subgraphs (flattened; `a -> { b c }` is two edges) and comments; ports are dropped. Node attributes read:
// label, kind, file, line, tooltip (as detail); edge attributes: label, kind.
struct DotReader {
    std::vector<std::pair<char, std::string>> tokens;   // kind: 'i' an id, else the punctuation itself ('-' for -> and --)
    size_t at = 0; int depth = 0; std::string error;
    J nodes = J::array(), edges = J::array();
    std::map<std::string, size_t> index;
    explicit DotReader(const std::string& s) {
        for (size_t i = 0; i < s.size() && tokens.size() < 2000000;) {
            const char c = s[i];
            if (std::isspace(static_cast<unsigned char>(c))) { ++i; continue; }
            if (c == '/' && i + 1 < s.size() && s[i + 1] == '/') { while (i < s.size() && s[i] != '\n') ++i; continue; }
            if (c == '/' && i + 1 < s.size() && s[i + 1] == '*') { const auto e = s.find("*/", i + 2); i = e == std::string::npos ? s.size() : e + 2; continue; }
            if (c == '#' && (i == 0 || s[i - 1] == '\n')) { while (i < s.size() && s[i] != '\n') ++i; continue; }
            if (c == '"') {
                std::string v; ++i;
                while (i < s.size() && s[i] != '"') {
                    if (s[i] == '\\' && i + 1 < s.size()) {
                        if (s[i + 1] == '\n') { i += 2; continue; }
                        if (s[i + 1] == '"' || s[i + 1] == '\\') { v += s[i + 1]; i += 2; continue; }
                    }
                    v += s[i++];
                }
                ++i; tokens.push_back({'i', v}); continue;
            }
            if (c == '<') {
                int level = 0; const auto start = i;
                for (; i < s.size(); ++i) { if (s[i] == '<') ++level; else if (s[i] == '>' && --level == 0) { ++i; break; } }
                tokens.push_back({'i', s.substr(start + 1, i - start - 2)}); continue;
            }
            if (c == '-' && i + 1 < s.size() && (s[i + 1] == '>' || s[i + 1] == '-')) { tokens.push_back({'-', "->"}); i += 2; continue; }
            if (std::string("{}[];,=:").find(c) != std::string::npos) { tokens.push_back({c, std::string(1, c)}); ++i; continue; }
            const auto start = i;
            while (i < s.size() && (std::isalnum(static_cast<unsigned char>(s[i])) || s[i] == '_' || s[i] == '.' || s[i] == '-'
                                    || static_cast<unsigned char>(s[i]) >= 0x80)) {
                if (s[i] == '-' && i + 1 < s.size() && (s[i + 1] == '>' || s[i + 1] == '-')) break;
                ++i;
            }
            if (i == start) { ++i; continue; }
            tokens.push_back({'i', s.substr(start, i - start)});
        }
    }
    bool is(char kind, const char* text = nullptr) const {
        return at < tokens.size() && tokens[at].first == kind && (!text || lowered(tokens[at].second) == text);
    }
    J attributes() {
        J a = J::object();
        while (is('[')) {
            ++at;
            while (at < tokens.size() && !is(']')) {
                if (!is('i')) { ++at; continue; }
                const auto key = tokens[at++].second;
                std::string value;
                if (is('=')) { ++at; if (is('i')) value = tokens[at++].second; }
                a[key] = value;
                if (is(',') || is(';')) ++at;
            }
            if (is(']')) ++at;
        }
        return a;
    }
    std::string node_id() {
        auto id = tokens[at++].second;
        if (is(':')) { ++at; if (is('i')) ++at; if (is(':')) { ++at; if (is('i')) ++at; } }
        return id;
    }
    void node(const std::string& id, const J& attrs) {
        auto it = index.find(id);
        if (it == index.end()) {
            if (nodes.size() > 5000) return;
            it = index.emplace(id, nodes.size()).first;
            nodes.push_back(J{{"id", id}});
        }
        auto& n = nodes[it->second];
        if (attrs.contains("label")) n["label"] = trim(attrs["label"].get<std::string>());
        if (attrs.contains("kind")) n["kind"] = attrs["kind"];
        if (attrs.contains("file")) n["file"] = attrs["file"];
        if (attrs.contains("line")) { const int line = count(attrs["line"].get<std::string>()); if (line > 0) n["line"] = line; }
        if (attrs.contains("tooltip")) n["detail"] = attrs["tooltip"];
    }
    // One endpoint of an edge: a node, or every node a subgraph declares.
    std::vector<std::string> endpoint() {
        if (is('{') || is('i', "subgraph")) return group();
        if (!is('i')) return {};
        const auto id = node_id();
        node(id, J::object());
        return {id};
    }
    std::vector<std::string> group() {
        if (is('i', "subgraph")) { ++at; if (is('i')) ++at; }
        if (!is('{')) return {};
        ++at;
        if (++depth > 64) { error = "subgraphs nest deeper than 64"; at = tokens.size(); return {}; }
        std::vector<std::string> members;
        while (at < tokens.size() && !is('}')) statement(members);
        if (is('}')) ++at;
        --depth;
        return members;
    }
    void statement(std::vector<std::string>& members) {
        if (is(';') || is(',')) { ++at; return; }
        if (is('i', "graph") || is('i', "node") || is('i', "edge")) { ++at; attributes(); return; }
        if (!is('i') && !is('{')) { ++at; return; }
        if (is('i') && !is('i', "subgraph") && at + 1 < tokens.size() && tokens[at + 1].first == '=') { at += 2; if (is('i')) ++at; return; }
        auto left = endpoint();
        std::vector<std::vector<std::string>> chain{left};
        while (is('-')) { ++at; chain.push_back(endpoint()); }
        const auto attrs = attributes();
        for (const auto& id : left) members.push_back(id);
        if (chain.size() == 1) { for (const auto& id : left) node(id, attrs); return; }
        for (size_t k = 1; k < chain.size(); ++k) {
            for (const auto& id : chain[k]) members.push_back(id);
            for (const auto& from : chain[k - 1]) for (const auto& to : chain[k]) {
                if (edges.size() > 20000) return;
                J edge{{"from", from}, {"to", to}};
                if (attrs.contains("label")) edge["label"] = trim(attrs["label"].get<std::string>());
                if (attrs.contains("kind")) edge["kind"] = attrs["kind"];
                edges.push_back(edge);
            }
        }
    }
    bool read() {
        if (is('i', "strict")) ++at;
        if (!is('i', "digraph") && !is('i', "graph")) { error = "not a DOT graph (it starts with graph or digraph)"; return false; }
        ++at;
        if (is('i')) ++at;
        if (!is('{')) { error = "not a DOT graph (no { after its name)"; return false; }
        std::vector<std::string> members;
        group();
        return error.empty();
    }
};
J from_dot(const std::string& text, J r, const ResultFrom& from) {
    DotReader dot(text);
    if (!dot.read()) return refused_result(r, dot.error, true);
    r = graph_result(r, dot.nodes, dot.edges, J(), from.root);
    // DOT has no way to say a graph is whole.
    if (r.value("complete", false)) r["complete"] = nullptr;
    return r;
}

// fox-contract/1: a contract-test run's outcome, counts, test names, what it ran against and its log. The outcome
// becomes the status: pass ok, partial warn, fail fail, refused no answer (complete false); a skipped or missing test is
// never a pass. Each input becomes an `about` checkout: its folder, head, the tree id the record keeps (with `scope`,
// the folder it is of), whether that was uncommitted and which paths, and which of its values moved during the run.
J from_contract(const std::string& text, J r, const ResultFrom&) {
    const auto doc = J::parse(text, nullptr, false);
    if (doc.is_discarded() || !doc.is_object()) return refused_result(r, "the record is not a fox-contract/1 object", true);
    const auto& names = contract_fields();
    const auto field = [&](const char* name, const J& in) { return at_pointer(in, names.at(name)); };
    const auto kind = field("kind", doc);
    if (kind.is_string() && kind.get<std::string>() != "fox-contract/1")
        return refused_result(r, "the record says it is " + one_line(kind.get<std::string>(), 40) + ", not fox-contract/1", true);
    if (positive(field("ended", doc)).is_number()) r["at"] = field("ended", doc);
    r["started"] = positive(field("started", doc));
    const auto log = field("log", doc);
    r["log"] = log.is_string() && fs::path(log.get<std::string>()).is_absolute() ? log : J();
    for (const char* name : {"passed", "failed", "skipped", "expected"}) add_fact(r, name, count_or_null(field(name, doc)), J(""));
    size_t unrun = 0;
    for (const auto& [list, sev, what] : {std::tuple<const char*, const char*, const char*>{"failed tests", "error", "failed"},
                                          {"skipped tests", "warn", "skipped"}, {"missing", "warn", "missing"}}) {
        const auto tests = field(list, doc);
        for (const auto& test : tests.is_array() ? tests : J::array()) if (test.is_string() && r["findings"].size() < 2000) {
            if (std::string(what) != "failed") ++unrun;
            r["findings"].push_back(J{{"id", std::string(what) + ':' + one_line(test.get<std::string>(), 120)}, {"file", nullptr},
                                      {"line", nullptr}, {"col", nullptr}, {"severity", sev}, {"kind", what},
                                      {"message", one_line(test.get<std::string>(), 120)}});
        }
    }
    // What it ran against: each input at the run's end (else its start), in the record's order.
    auto inputs = field("inputs", doc);
    if (!inputs.is_object()) inputs = field("inputs at start", doc);
    std::map<std::string, J> moved;
    const auto moved_list = field("moved", doc);
    for (const auto& m : moved_list.is_array() ? moved_list : J::array()) if (m.is_string()) {
        const auto what = m.get<std::string>();
        const auto dot = what.find('.');
        moved[what.substr(0, dot)].push_back(dot == std::string::npos ? std::string() : what.substr(dot + 1));
    }
    auto order = split(names.at("input order"), ' ');
    if (inputs.is_object()) for (const auto& [name, input] : inputs.items())
        if (std::find(order.begin(), order.end(), name) == order.end()) order.push_back(name);
    for (const auto& name : order) {
        if (!inputs.is_object() || !inputs.contains(name) || !inputs[name].is_object()) continue;
        const auto& input = inputs[name];
        const auto root = field("input root", input), version = field("input version", input), tree = field("input tree", input);
        const bool scoped = tree.is_string();
        const auto dirty = field(scoped ? "input tree dirty" : "input dirty", input);
        const auto uncommitted = field(scoped ? "input tree uncommitted" : "input uncommitted", input);
        J paths;
        if (uncommitted.is_array()) {
            paths = J::array();
            for (const auto& p : uncommitted) if (p.is_string() && paths.size() < 1000) paths.push_back(p);
        }
        auto head = field("input head", input);
        if (!head.is_string()) head = field("input commit", input);
        J ref{{"kind", "checkout"}, {"name", name},
              {"label", name + (version.is_string() ? " " + one_line(version.get<std::string>(), 40) : std::string())},
              {"path", root.is_string() && fs::path(root.get<std::string>()).is_absolute() ? root : J()},
              {"how", text_or_null(field("input how", input), 80)}, {"scope", scoped ? names.at("tree folder") : std::string()},
              {"version", J{{"head", text_or_null(head, 64)}, {"tree", text_or_null(tree, 64)}, {"release", text_or_null(version, 40)},
                            {"dirty", dirty.is_boolean() ? dirty : J()}, {"uncommitted", paths}}}};
        const auto why = text_or_null(field("input why", input), 200);
        if (!why.is_null()) ref["why"] = why;
        if (moved.count(name)) ref["moved"] = moved[name];
        r["about"].push_back(ref);
    }
    for (const auto& [name, values] : moved)
        if (!inputs.is_object() || !inputs.contains(name)) r["about"].push_back(J{{"kind", "checkout"}, {"name", name}, {"label", name}, {"moved", values}});
    const auto said = field("state", doc);
    const auto found = said.is_string() ? contract_states().find(lowered(trim(said.get<std::string>()))) : contract_states().end();
    std::string outcome = found == contract_states().end() ? "unknown" : found->second;
    const auto skipped = field("skipped", doc);
    if (outcome == "pass" && (unrun > 0 || (skipped.is_number_integer() && skipped.get<long long>() > 0))) outcome = "partial";
    std::string counts;
    for (const auto& fact : r["facts"]) if (fact["value"].is_number() && fact["name"] != "expected")
        counts += (counts.empty() ? "" : ", ") + std::to_string(fact["value"].get<long long>()) + " " + fact["name"].get<std::string>();
    const auto summary = field("summary", doc);
    r["summary"] = summary.is_string() ? one_line(summary.get<std::string>(), 200) : counts;
    if (outcome == "refused") {
        const auto why = field("why", doc);
        return refused_result(r, "refused: " + (why.is_string() ? why.get<std::string>() : std::string("the runner gave no reason")));
    }
    r["state"] = outcome == "pass" ? "ok" : outcome == "partial" ? "warn" : outcome == "fail" ? "fail" : "unknown";
    return r;
}

// The answer a tool gave, as desk-result/1.
J desk_result(const std::string& text, const ResultFrom& from) {
    auto r = result_base(from);
    if (!result_formats().count(from.format)) return refused_result(r, "desk-work does not read the format " + from.format, true);
    if (from.format == "json") return from_json(text, r, from);
    if (from.format == "toolio" || from.format == "fox-symdeps/2") return from_toolio(text, r, from);
    if (from.format == "lines") return from_lines(text, r, from);
    if (from.format == "dot") return from_dot(text, r, from);
    return from_contract(text, r, from);
}
