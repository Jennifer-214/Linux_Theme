// The project map of a checkout, kept with its work records and never in the project (docs/agent-workflows.md,
// "Project map"): map/graph.json is the merged graph and how it was built, map/summary.json what status reads,
// map/providers/<name>.json each reader's last answer, map/settings.json the binary it reads, map/building.json a
// build under way. Built only when asked (map build: a job like any other, with its log, its cap and its failure
// notice); status says stale instead of rebuilding. The graph itself is computed in map_graph.hpp.
fs::path map_dir(const std::string& root) { return project_dir(root) / "map"; }
const std::vector<std::string>& map_providers() { static const std::vector<std::string> names{"syntax", "binary"}; return names; }
J map_json(const fs::path& p) { auto j = J::parse(read(p, 512u * 1024 * 1024), nullptr, false); return j.is_discarded() ? J() : j; }

// Code the syntax reader reads, and whose edits make the map stale: by extension, outside folders that hold someone
// else's code or build output (git's ignore rules have already left out the rest).
bool map_source(const std::string& rel) {
    static const std::set<std::string> exts{".c", ".h", ".cc", ".cpp", ".cxx", ".c++", ".hpp", ".hh", ".hxx", ".h++", ".ipp", ".inl",
        ".tpp", ".tcc", ".lua", ".py", ".pyi", ".sh", ".bash", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".rs", ".go", ".java"};
    static const std::set<std::string> skipped{"node_modules", "vendor", "vendored", "third_party", "thirdparty", "3rdparty", "external",
        "extern", "deps", "build", "builds", "out", "dist", "target", "_build", "__pycache__", "venv", "site-packages", "bower_components", "Pods"};
    const fs::path p(rel);
    if (rel.empty() || p.is_absolute() || rel.find('\n') != std::string::npos) return false;
    for (const auto& part : p.parent_path()) {
        const auto s = part.string();
        if (s.empty() || s[0] == '.' || skipped.count(s) || s.rfind("cmake-build-", 0) == 0 || s.rfind("bazel-", 0) == 0) return false;
    }
    auto ext = p.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    return exts.count(ext) > 0;
}

// What a map answer is built against: HEAD, and the content of every mapped file that differs from it (edited,
// staged or new), so editing such a file again makes the map stale again; for the binary reader, the binary's size
// and time.
J map_stamp(const std::string& root, const std::string& binary) {
    J out{{"head", trim(query({"git", "--no-optional-locks", "-C", root, "rev-parse", "--verify", "--quiet", "HEAD"}))}};
    std::vector<std::string> dirty;
    const auto fields = split(query({"git", "--no-optional-locks", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all"}, 10), '\0');
    for (size_t i = 0; i < fields.size(); ++i) {
        const auto& f = fields[i];
        if (f.size() < 4) continue;
        if (map_source(f.substr(3))) dirty.push_back(f.substr(3));
        if (f[0] == 'R' || f[0] == 'C') ++i;   // the next field is where it was renamed or copied from
    }
    std::sort(dirty.begin(), dirty.end());
    dirty.erase(std::unique(dirty.begin(), dirty.end()), dirty.end());
    std::string all;
    size_t bytes = 0, hashed = 0;
    for (const auto& rel : dirty) {
        struct stat st{};
        const auto full = fs::path(root) / rel;
        std::string state;
        if (::lstat(full.c_str(), &st) != 0) state = "gone";
        else if (!S_ISREG(st.st_mode)) state = "not a file";
        else if (hashed < 2000 && st.st_size <= 4 * 1024 * 1024 && bytes + static_cast<size_t>(st.st_size) <= 64u * 1024 * 1024) {
            state = hash(read(full, 4 * 1024 * 1024)); bytes += static_cast<size_t>(st.st_size); ++hashed;
        } else state = std::to_string(st.st_size) + "@" + std::to_string(st.st_mtim.tv_sec) + "." + std::to_string(st.st_mtim.tv_nsec);
        all += rel + '\t' + state + '\n';
    }
    out["dirty"] = hash(all);
    out["dirty_count"] = dirty.size();
    J files = J::array();
    for (size_t i = 0; i < dirty.size() && i < 50; ++i) files.push_back(dirty[i]);
    out["dirty_files"] = files;
    if (!binary.empty()) {
        struct stat st{};
        out["binary"] = ::stat(binary.c_str(), &st) == 0
            ? J{{"path", binary}, {"size", static_cast<long long>(st.st_size)}, {"mtime", static_cast<long long>(st.st_mtim.tv_sec) * 1000000000LL + st.st_mtim.tv_nsec}}
            : J{{"path", binary}, {"size", -1}};
    }
    return out;
}

std::string map_binary(const std::string& root) { return str(json(map_dir(root) / "settings.json"), "binary"); }
std::string map_lua() {
    const auto chosen = env("DESK_MAP_LUA");
    return !chosen.empty() ? chosen : (fs::path(env("XDG_CONFIG_HOME", env("HOME") + "/.config")) / "nvim/lua/desk/map.lua").string();
}

// Each reader's gate: "" when it can run here, else the one line that says what it needs.
std::string syntax_problem(const std::string& root) {
    std::error_code ec;
    if (!fs::exists(fs::path(root) / ".git", ec)) return "requires a git checkout (the files to read come from git)";
    if (!sh::have("nvim")) return "requires nvim (0.10 or newer: it reads the files with treesitter)";
    if (!fs::is_regular_file(map_lua(), ec)) return "requires the desk Neovim modules (" + map_lua() + " is missing)";
    return "";
}
std::string binary_problem(const std::string& path) {
    std::error_code ec;
    if (path.empty()) return "requires a built binary: desk-work map build --binary PATH (kept for the next builds)";
    if (!fs::exists(path, ec)) return "the binary " + path + " is gone; build it, or give another with --binary PATH";
    if (!fs::is_regular_file(path, ec)) return path + " is not a file";
    std::ifstream f(path, std::ios::binary);
    unsigned char head[18] = {};
    f.read(reinterpret_cast<char*>(head), sizeof head);
    if (f.gcount() < 18 || std::memcmp(head, "\x7f" "ELF", 4) != 0) return path + " is not an ELF binary";
    const int type = head[5] == 2 ? (head[16] << 8 | head[17]) : (head[17] << 8 | head[16]);
    if (type == 1) return path + " is an object file: its calls are not linked yet; give the linked binary";
    if (type != 2 && type != 3) return path + " is neither a program nor a library";
    if (!sh::have("objdump")) return "requires objdump (binutils)";
    return "";
}

J map_result(const std::string& name, const J& stamp) {
    J r{{"name", name}, {"state", "refused"}, {"why", ""}, {"built_at", now()}, {"head", str(stamp, "head")}, {"dirty", str(stamp, "dirty")}};
    if (name == "binary" && stamp.contains("binary")) r["binary"] = stamp["binary"];
    return r;
}

// The syntax reader: a headless Neovim runs desk/map.lua over the checkout's code (desk-work lists the files, so
// git's ignore rules and the caps above apply) and writes its graph to a file in this folder.
J map_syntax(const std::string& root, const J& stamp) {
    auto result = map_result("syntax", stamp);
    const auto problem = syntax_problem(root);
    if (!problem.empty()) { result["why"] = problem; return result; }
    std::string listed;
    if (!sh::capture({"git", "--no-optional-locks", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"}, listed)) {
        result["why"] = "git could not list the files"; return result;
    }
    std::set<std::string> wanted;
    for (const auto& rel : split(listed, '\0')) if (map_source(rel)) wanted.insert(rel);
    J files = J::array();
    size_t bytes = 0, big = 0, over = 0;
    for (const auto& rel : wanted) {
        struct stat st{};
        const auto full = fs::path(root) / rel;
        if (::lstat(full.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
        if (st.st_size > 1024 * 1024) { ++big; continue; }
        if (files.size() >= 4000 || bytes + static_cast<size_t>(st.st_size) > 64u * 1024 * 1024) { ++over; continue; }
        bytes += static_cast<size_t>(st.st_size);
        files.push_back(rel);
    }
    const auto request = map_dir(root) / "syntax-request.json", answer = map_dir(root) / "syntax-answer.json";
    std::error_code ec;
    fs::remove(answer, ec);
    if (!atomic(request, J{{"version", 1}, {"root", root}, {"files", files}, {"limits", J{{"nodes", 50000}, {"edges", 200000}}}}.dump(), false)) {
        result["why"] = "could not write the reader's request in " + map_dir(root).string(); return result;
    }
    A argv{"nvim", "--headless", "--clean", "-l", map_lua(), "--syntax-graph", request.string(), answer.string()};
    if (sh::have("timeout")) argv.insert(argv.begin(), {"timeout", "-k", "5", "900"});
    const int code = sh::run(argv);
    const auto raw = map_json(answer);
    fs::remove(request, ec); fs::remove(answer, ec);
    if (code != 0 || !raw.is_object()) {
        result["why"] = code == 124 ? std::string("the syntax reader took longer than 15 minutes")
                                    : "the syntax reader stopped (exit " + std::to_string(code) + "); its output is in this job's log";
        return result;
    }
    auto graph = desk_map::clean_graph(raw);
    J notes = J::array();
    for (const auto& n : desk_map::list(raw, "notes")) if (n.is_string()) notes.push_back(n.get<std::string>().substr(0, 300));
    if (big) notes.push_back(std::to_string(big) + (big == 1 ? " file over 1 MiB was" : " files over 1 MiB were") + " left out");
    if (over) {
        graph["complete"] = false;
        graph["why"] = "read the first 4000 files (64 MiB at most); " + std::to_string(over) + " more were left out";
    }
    result["state"] = "ok";
    result["graph"] = graph;
    result["notes"] = notes;
    result["stats"] = raw.contains("stats") && raw["stats"].is_object() ? raw["stats"] : J::object();
    return result;
}

// A path from the binary's debug info as the map keeps files: relative to the checkout, or nothing when it is outside
// (a system header, another checkout).
std::string map_relative(const std::string& root, const std::string& path) {
    if (path.empty()) return "";
    std::error_code ec;
    const auto full = fs::path(path).is_absolute() ? fs::path(path).lexically_normal() : (fs::path(root) / path).lexically_normal();
    const auto rel = full.lexically_relative(root);
    if (rel.empty() || *rel.begin() == ".." || !fs::is_regular_file(full, ec)) return "";
    return rel.string();
}

// The binary reader: objdump's disassembly read as it streams (never held whole), at most 400 000 functions. With
// debug info (-g), -l adds where each function's code is, so a function the binary has is matched by its file too.
J map_binary_graph(const std::string& root, const std::string& binary, const J& stamp) {
    auto result = map_result("binary", stamp);
    const auto problem = binary_problem(binary);
    if (!problem.empty()) { result["why"] = problem; return result; }
    desk_map::Objdump reader;
    std::string headers;
    const bool lines = sh::capture({"env", "LC_ALL=C", "objdump", "-h", binary}, headers) && headers.find(".debug_line") != std::string::npos;
    A argv{"env", "LC_ALL=C", "objdump", "-d", "--no-show-raw-insn", "--demangle", binary};
    if (lines) argv.insert(argv.begin() + 4, "-l");
    if (sh::have("timeout")) argv.insert(argv.begin(), {"timeout", "-k", "5", "900"});
    bool full = false;
    const int code = sh::each_line(argv, [&](const std::string& line) {
        reader.line(line);
        full = reader.functions() >= 400000;
        return !full;
    });
    if (code != 0 && !full) {
        result["why"] = code == 124 ? "objdump took longer than 15 minutes on " + binary : "objdump could not read " + binary + " (exit " + std::to_string(code) + ")";
        return result;
    }
    auto graph = reader.graph();
    auto stats = graph["stats"];
    if (desk_map::number(stats, "functions") == 0) { result["why"] = binary + " names no functions (stripped?): give a build that keeps its symbols"; return result; }
    long long placed = 0;
    std::map<std::string, std::string> seen;
    for (auto& node : graph["nodes"]) {
        const auto raw = str(node, "file");
        const auto it = seen.find(raw);
        const auto file = it != seen.end() ? it->second : (seen[raw] = map_relative(root, raw));
        if (file.empty()) { node["file"] = nullptr; node["line"] = nullptr; } else { node["file"] = file; ++placed; }
    }
    stats["debug_info"] = lines;
    stats["placed"] = placed;
    graph.erase("stats");
    graph = desk_map::clean_graph(graph);
    if (full) { graph["complete"] = false; graph["why"] = "the binary has more than 400000 functions; the rest were left out"; }
    result["state"] = "ok";
    result["graph"] = graph;
    result["stats"] = stats;
    return result;
}

std::string map_said(const J& r) {
    char seconds[32];
    std::snprintf(seconds, sizeof seconds, " (%.1f s)", static_cast<double>(num(r, "ms")) / 1000.0);
    const std::string name = str(r, "name"), took = seconds;
    if (str(r, "state") != "ok") return name + ": " + str(r, "why");
    const auto s = r.value("stats", J::object());
    if (name == "syntax")
        return "syntax: " + std::to_string(num(s, "functions")) + " functions and " + std::to_string(num(s, "types")) + " types in "
               + std::to_string(num(s, "parsed")) + " files, with " + std::to_string(num(s, "edges")) + " calls by name" + took;
    return "binary: " + std::to_string(num(s, "functions")) + " functions in " + fs::path(str(r.value("binary", J::object()), "path")).filename().string()
           + ", with " + std::to_string(num(s, "edges")) + " calls (" + std::to_string(num(s, "library_sites")) + " into libraries, "
           + std::to_string(num(s, "indirect_sites")) + " indirect)" + took;
}

// The build itself: run inside a desk-work job (map build starts it), one build per checkout at a time.
int map_build_run(const std::string& root, std::string provider) {
    if (provider.empty()) provider = "all";
    if (!register_root(root) || !private_dir(map_dir(root) / "providers")) { std::cout << unwritable()["message"].get<std::string>() << '\n'; return 1; }
    const auto lock_path = map_dir(root) / "build.lock";
    const int fd = ::open(lock_path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0 || ::flock(fd, LOCK_EX | LOCK_NB) != 0) {
        std::cout << "Another map build is running in this checkout; this one stops.\n";
        if (fd >= 0) ::close(fd);
        return 0;
    }
    atomic(map_dir(root) / "building.json", J{{"pid", ::getpid()}, {"process", proc_stamp(::getpid())}, {"started", now()}, {"provider", provider}}.dump(), false);
    const auto binary = map_binary(root);
    const auto stamp = map_stamp(root, binary);
    const auto dirty = num(stamp, "dirty_count");
    std::cout << "Project map of " << root << " at " << str(stamp, "head").substr(0, 7)
              << (dirty > 0 ? " with " + std::to_string(dirty) + " changed files" : std::string()) << '\n' << std::flush;
    std::map<std::string, J> results;
    for (const auto& name : map_providers()) {
        if (provider != "all" && provider != name) { results[name] = map_json(map_dir(root) / "providers" / (name + ".json")); continue; }
        const auto started = std::chrono::steady_clock::now();
        auto r = name == "syntax" ? map_syntax(root, stamp) : map_binary_graph(root, binary, stamp);
        r["ms"] = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        std::cout << map_said(r) << '\n';
        for (const auto& note : desk_map::list(r, "notes")) std::cout << name << ": " << note.get<std::string>() << '\n';
        std::cout << std::flush;
        atomic(map_dir(root) / "providers" / (name + ".json"), r.dump(), false);
        results[name] = r;
    }
    const auto graph_of = [&](const std::string& name) {
        const auto& r = results[name];
        return r.is_object() && str(r, "state") == "ok" && r.contains("graph") ? r["graph"] : J();
    };
    // The folder the binary was built in breaks a tie between functions of one name (a checkout of many programs).
    const auto folder = binary.empty() ? std::string() : fs::path(binary).parent_path().lexically_relative(root).string();
    const auto near = folder.empty() || folder == "." || folder.rfind("..", 0) == 0 ? std::string() : folder + "/";
    auto merged = desk_map::merge(graph_of("syntax"), graph_of("binary"), near);
    J providers = J::array();
    bool any = false;
    for (const auto& name : map_providers()) {
        auto r = results[name];
        if (!r.is_object()) r = J{{"name", name}, {"state", "not built"}, {"why", ""}};
        any = any || str(r, "state") == "ok";
        r.erase("graph");
        providers.push_back(r);
    }
    merged["root"] = root;
    merged["built_at"] = now();
    merged["head"] = str(stamp, "head");
    merged["dirty"] = str(stamp, "dirty");
    merged["dirty_files"] = stamp["dirty_files"];
    merged["providers"] = providers;
    if (!binary.empty()) merged["binary"] = binary;
    bool saved = atomic(map_dir(root) / "graph.json", merged.dump(-1, ' ', false, J::error_handler_t::replace), false);
    J summary = merged;
    for (const char* bulky : {"nodes", "edges", "spans"}) summary.erase(bulky);
    summary["nodes"] = merged["nodes"].size();
    summary["edges"] = merged["edges"].size();
    saved = saved && atomic(map_dir(root) / "summary.json", summary.dump(-1, ' ', false, J::error_handler_t::replace), false);
    std::error_code ec;
    fs::remove(map_dir(root) / "building.json", ec);
    ::flock(fd, LOCK_UN);
    ::close(fd);
    if (!saved) { std::cout << "Could not save the map in " << map_dir(root).string() << "; the disk may be full or read-only\n"; return 1; }
    std::cout << "Map: " << merged["nodes"].size() << " nodes and " << merged["edges"].size() << " edges"
              << (num(merged, "matched") > 0 ? "; " + std::to_string(num(merged, "matched")) + " functions found by both readers" : std::string())
              << (merged.value("complete", true) ? std::string() : " (partial: " + str(merged, "why") + ")") << '\n';
    return any ? 0 : 1;
}

J map_building(const std::string& root) {
    const auto b = json(map_dir(root) / "building.json");
    if (!b.is_object()) return J();
    if (num(b, "pid") > 0) return !str(b, "process").empty() && proc_stamp(num(b, "pid")) == str(b, "process") ? b : J();
    // Written by map build before the job starts: the job's own record replaces it within seconds.
    return now() - num(b, "at") < 60 ? b : J();
}

J map_status(const std::string& root) {
    const auto summary = json(map_dir(root) / "summary.json");
    const auto building = map_building(root);
    const auto binary = map_binary(root);
    J out{{"ok", true}, {"root", root}, {"built", summary.is_object()}, {"building", building.is_object()},
          {"binary", binary.empty() ? J() : J(binary)}};
    if (building.is_object()) out["building_since"] = num(building, "started", num(building, "at"));
    std::map<std::string, J> stored;
    if (summary.is_object()) {
        for (const char* key : {"built_at", "head", "nodes", "edges", "complete", "why", "matched"}) if (summary.contains(key)) out[key] = summary[key];
        for (const auto& p : desk_map::list(summary, "providers")) stored[str(p, "name")] = p;
    }
    // While a build writes, a poll costs no git call; the answer after it says whether the new map is current.
    const J current = building.is_object() || !summary.is_object() ? J() : map_stamp(root, binary);
    std::string stale_why;
    J providers = J::array();
    for (const auto& name : map_providers()) {
        const J p = stored.count(name) ? stored[name] : J{{"state", "not built"}};
        J row{{"name", name}, {"state", str(p, "state", "not built")}, {"why", str(p, "why")}};
        if (str(row, "state") == "not built") row["why"] = name == "syntax" ? syntax_problem(root) : binary_problem(binary);
        if (str(row, "state") == "ok") {
            row["built_at"] = num(p, "built_at");
            if (p.contains("stats")) row["stats"] = p["stats"];
            if (name == "binary") row["binary"] = str(p.value("binary", J::object()), "path");
            if (current.is_object()) {
                auto why = desk_map::stale_reason(p, current, name == "binary");
                if (name == "binary" && why.empty() && str(p.value("binary", J::object()), "path") != binary) why = "another binary was chosen";
                row["stale"] = !why.empty();
                if (!why.empty()) { row["stale_why"] = why; if (stale_why.empty()) stale_why = (name == "binary" ? "binary: " : "") + why; }
            }
        }
        providers.push_back(row);
    }
    out["providers"] = providers;
    if (current.is_object()) { out["stale"] = !stale_why.empty(); out["stale_why"] = stale_why; out["current_head"] = str(current, "head"); }
    return out;
}

int map_number(const std::string& s, int fallback) {
    int n = 0;
    const auto parsed = std::from_chars(s.data(), s.data() + s.size(), n);
    return !s.empty() && parsed.ec == std::errc{} && parsed.ptr == s.data() + s.size() ? n : fallback;
}

// ─── her corrections to the handoffs, in the declaration format (docs/desk-tools.md, "map") ───────────────────────
// Read from the checkout's own .desk/tools.json and every desk.d file naming it (root), each "map": { "handoffs" }
// joined; written only to a desk.d file of desk-work's own (map-<folder>.json), never into the checkout.
std::vector<fs::path> desk_d_files();   // tools.hpp
fs::path desk_d();
J declaration_doc(const fs::path& file) {
    struct stat st{};
    if (::lstat(file.c_str(), &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > 64 * 1024) return J();
    auto doc = J::parse(read(file, 64 * 1024), nullptr, false);
    return doc.is_object() && doc.contains("version") && doc["version"] == 1 ? doc : J();
}
bool names_root(const J& doc, const std::string& root) {
    const auto named = str(doc, "root");
    if (named.empty() || !fs::path(named).is_absolute()) return false;
    std::error_code ec;
    const auto folder = fs::canonical(named, ec);
    return !ec && root_of(folder.string()) == root;
}
J map_corrections(const std::string& root) {
    J out{{"drop", J::array()}, {"add", J::array()}};
    const auto take = [&](const J& doc) {
        if (!doc.is_object() || !doc.contains("map") || !doc["map"].is_object()) return;
        const auto& h = doc["map"].value("handoffs", J::object());
        if (!h.is_object()) return;
        for (const char* side : {"drop", "add"})
            for (const auto& p : desk_map::list(h, side)) if (p.is_object() && out[side].size() < 4096) out[side].push_back(p);
    };
    take(declaration_doc(fs::path(root) / ".desk/tools.json"));
    for (const auto& file : desk_d_files()) if (auto doc = declaration_doc(file); names_root(doc, root)) take(doc);
    return out;
}
// The stored graph with her corrections applied: what every query reads.
J corrected_graph(const std::string& root) {
    auto doc = map_json(map_dir(root) / "graph.json");
    return doc.is_object() ? desk_map::corrected(std::move(doc), map_corrections(root)) : doc;
}
// desk-work's own desk.d file for a checkout: map-<folder>.json, or map-<folder>-<hash>.json when that name is another
// checkout's (two checkouts with one folder name).
fs::path corrections_file(const std::string& root) {
    const auto base = "map-" + fs::path(root).filename().string();
    const auto plain = desk_d() / (base + ".json");
    const auto doc = declaration_doc(plain);
    std::error_code ec;
    // an unreadable file there is not passed over: the write refuses, naming it
    if (!fs::exists(plain, ec) || !doc.is_object() || names_root(doc, root)) return plain;
    char hash[16];
    std::snprintf(hash, sizeof hash, "%06zx", std::hash<std::string>{}(root) & 0xffffff);
    return desk_d() / (base + "-" + hash + ".json");
}
// desk-work map handoff add|drop|forget|list --from A --to B [--label L]: a name as `trace` takes one (an id, a label, a
// unique last part). add: a handoff the reader missed; drop: one it got wrong (one she added is forgotten instead);
// forget: her correction of that pair undone.
J map_handoff(const std::string& root, const std::string& verb, std::map<std::string, std::string>& opts) {
    const auto file = corrections_file(root);
    if (verb == "list") return J{{"ok", true}, {"file", file.string()}, {"handoffs", map_corrections(root)}};
    if (verb != "add" && verb != "drop" && verb != "forget") return refuse("desk-work map handoff add|drop|forget|list --from A --to B [--label L]");
    auto graph = map_json(map_dir(root) / "graph.json");
    if (!graph.is_object()) return refuse("No project map of this checkout yet; build one with desk-work map build --root " + root);
    const desk_map::Graph g(desk_map::corrected(std::move(graph), map_corrections(root)));
    std::string ids[2];
    const char* flags[2] = {"--from", "--to"};
    for (int i = 0; i < 2; ++i) {
        const auto found = desk_map::resolve(g, opts[flags[i]]);
        // forget: an end the map no longer has (renamed, deleted) is taken as the id it was kept by
        if (found.index < 0 && verb == "forget" && found.candidates.empty() && !opts[flags[i]].empty()) { ids[i] = opts[flags[i]]; continue; }
        if (found.index < 0) {
            auto refusal = refuse(std::string(i ? "To: " : "From: ") + found.message);
            if (!found.candidates.empty()) { refusal["candidates"] = found.candidates; refusal["flag"] = i ? "--to" : "--from"; }
            return refusal;
        }
        ids[i] = desk_map::text(g.nodes[static_cast<size_t>(found.index)], "id");
    }
    std::error_code ec;
    J doc = declaration_doc(file);
    if (fs::exists(file, ec) && !doc.is_object()) return refuse(file.string() + " is not a declaration desk-work can read; it is left as it is");
    if (!doc.is_object()) doc = J{{"version", 1}, {"root", root}, {"written_by", "desk-work map handoff"}, {"tools", J::array()}};
    if (!doc.contains("map") || !doc["map"].is_object()) doc["map"] = J::object();
    if (!doc["map"].contains("handoffs") || !doc["map"]["handoffs"].is_object()) doc["map"]["handoffs"] = J::object();
    auto& h = doc["map"]["handoffs"];
    for (const char* side : {"drop", "add"}) if (!h.contains(side) || !h[side].is_array()) h[side] = J::array();
    const auto same = [&](const J& p) { return p.is_object() && desk_map::text(p, "from") == ids[0] && desk_map::text(p, "to") == ids[1]; };
    const auto remove = [&](const char* side) {
        const auto before = h[side].size();
        J kept = J::array();
        for (const auto& p : h[side]) if (!same(p)) kept.push_back(p);
        h[side] = kept;
        return kept.size() != before;
    };
    std::string did;
    if (verb == "forget") did = (remove("add") | remove("drop")) ? "forgotten" : "nothing to forget";
    else if (verb == "drop") {
        if (remove("add")) did = "forgotten (it was yours)";
        else { h["drop"].push_back(J{{"from", ids[0]}, {"to", ids[1]}}); did = "dropped"; }
    } else {
        remove("drop"); remove("add");
        J pair{{"from", ids[0]}, {"to", ids[1]}};
        if (!opts["--label"].empty()) pair["label"] = opts["--label"].substr(0, 80);
        h["add"].push_back(pair);
        did = "added";
    }
    fs::create_directories(desk_d(), ec);
    const auto tmp = file.string() + ".tmp-" + std::to_string(::getpid());
    {
        std::ofstream o(tmp, std::ios::binary | std::ios::trunc);
        o << doc.dump(2) << '\n';
        if (!o.good()) { fs::remove(tmp, ec); return refuse("could not write " + file.string()); }
    }
    fs::rename(tmp, file, ec);
    if (ec) { fs::remove(tmp, ec); return refuse("could not write " + file.string()); }
    return J{{"ok", true}, {"did", did}, {"from", ids[0]}, {"to", ids[1]}, {"file", file.string()}};
}

// desk-work map query --q handoffs: her corrections to review — each added and dropped pair, its label and the file it
// is declared in (desk-work's own, which forget and rebind edit, or another she keeps herself), and each end checked
// against the map as built now: "ok", "moved" (gone from where it was, one function of its name now: `now`),
// "ambiguous" (several: `candidates`) or "gone". A drop whose handoff the reader no longer finds says so (stale).
J map_handoff_review(const std::string& root) {
    auto raw = map_json(map_dir(root) / "graph.json");
    if (!raw.is_object()) return refuse("No project map of this checkout yet; build one with desk-work map build --root " + root);
    std::set<std::pair<std::string, std::string>> read;
    for (const auto& e : desk_map::list(raw, "edges"))
        if (e.is_object() && desk_map::text(e, "kind") == "handoff") read.insert({desk_map::text(e, "from"), desk_map::text(e, "to")});
    const desk_map::Graph g(std::move(raw));
    const auto own = corrections_file(root).string();
    const auto end_of = [&](const std::string& id) {
        if (g.at.count(id)) return J{{"id", id}, {"state", "ok"}, {"node", g.node(g.at.at(id))}};
        // rel::label (or rel::label#2): by its label, else its last part
        auto label = id.substr(id.rfind("::") == std::string::npos ? 0 : id.find("::") + 2);
        if (const auto hash = label.rfind('#'); hash != std::string::npos) label = label.substr(0, hash);
        const auto found = desk_map::resolve(g, label);
        if (found.index >= 0) return J{{"id", id}, {"state", "moved"}, {"now", g.node(static_cast<size_t>(found.index))}};
        if (!found.candidates.empty()) return J{{"id", id}, {"state", "ambiguous"}, {"candidates", found.candidates}};
        return J{{"id", id}, {"state", "gone"}};
    };
    J entries = J::array();
    const auto take = [&](const J& doc, const std::string& file) {
        if (!doc.is_object() || !doc.contains("map") || !doc["map"].is_object()) return;
        const auto h = doc["map"].value("handoffs", J::object());
        if (!h.is_object()) return;
        for (const char* side : {"add", "drop"})
            for (const auto& p : desk_map::list(h, side)) {
                if (!p.is_object() || entries.size() >= 4096) continue;
                const auto from = desk_map::text(p, "from"), to = desk_map::text(p, "to");
                J entry{{"side", side}, {"from", end_of(from)}, {"to", end_of(to)}, {"declared_in", file}, {"own", file == own}};
                if (!desk_map::text(p, "label").empty()) entry["label"] = desk_map::text(p, "label").substr(0, 80);
                if (std::string(side) == "drop" && !read.count({from, to})) entry["stale"] = true;
                entries.push_back(entry);
            }
    };
    take(declaration_doc(fs::path(root) / ".desk/tools.json"), (fs::path(root) / ".desk/tools.json").string());
    for (const auto& file : desk_d_files()) if (auto doc = declaration_doc(file); names_root(doc, root)) take(doc, file.string());
    return J{{"ok", true}, {"q", "handoffs"}, {"file", own}, {"entries", entries}};
}

J map_query(const std::string& root, std::map<std::string, std::string>& opts) {
    if (opts["--q"] == "handoffs") return map_handoff_review(root);
    auto doc = corrected_graph(root);
    if (!doc.is_object()) return refuse("No project map of this checkout yet; build one with desk-work map build --root " + root);
    // --exclude ID\nID…: functions left out of this one question, as if the map did not have them (a logger, an
    // allocator every path goes through): their calls with them. Said back as `excluded` (the ones the map had).
    J excluded = J::array(), avoided;
    std::set<std::string> out_ids;
    // --avoid NAME (paths): every way that does not go through this function ("can anything reach B without A?"),
    // a name as --from takes one; several fit: refused with the candidates, under --avoid
    if (!opts["--avoid"].empty()) {
        const desk_map::Graph whole(doc);
        const auto found = desk_map::resolve(whole, opts["--avoid"]);
        if (found.index < 0) {
            auto refusal = refuse("Avoid: " + found.message);
            if (!found.candidates.empty()) { refusal["candidates"] = found.candidates; refusal["flag"] = "--avoid"; }
            return refusal;
        }
        avoided = whole.node(static_cast<size_t>(found.index));
        out_ids.insert(desk_map::text(avoided, "id"));
    }
    if (!opts["--exclude"].empty() || !out_ids.empty()) {
        std::stringstream lines(opts["--exclude"]);
        for (std::string id; std::getline(lines, id) && out_ids.size() < 64;) if (!id.empty()) out_ids.insert(id);
        J kept = J::array(), edges = J::array();
        for (const auto& n : desk_map::list(doc, "nodes")) {
            if (n.is_object() && out_ids.count(desk_map::text(n, "id"))) excluded.push_back(desk_map::text(n, "id"));
            else kept.push_back(n);
        }
        for (const auto& e : desk_map::list(doc, "edges"))
            if (!(e.is_object() && (out_ids.count(desk_map::text(e, "from")) || out_ids.count(desk_map::text(e, "to"))))) edges.push_back(e);
        doc["nodes"] = kept;
        doc["edges"] = edges;
    }
    const desk_map::Graph g(std::move(doc));
    const auto q = opts["--q"];
    const auto pick = [&](const std::string& name, const char* role, long& index) {
        const auto found = desk_map::resolve(g, name);
        index = found.index;
        if (index >= 0) return J();
        auto refusal = refuse(std::string(role) + found.message);
        refusal["candidates"] = found.candidates;
        // which of the question's names it is: what a picker puts the chosen id back in
        const std::string r = role;
        refusal["flag"] = r == "To: " ? "--to" : r == "Start: " ? "--start" : !opts["--from"].empty() ? "--from" : "--of";
        return refusal;
    };
    J out;
    long a = -1, b = -1;
    if (q == "reach" || q == "callers" || q == "trace") {
        if (opts["--file"].empty()) {
            const auto refusal = pick(!opts["--from"].empty() ? opts["--from"] : opts["--of"], "", a);
            if (!refusal.is_null()) return refusal;
        } else {
            const auto file = map_relative(root, opts["--file"]);
            const auto line = map_number(opts["--line"], 0);
            if (file.empty() || line < 1) return refuse("Name a file and its function's line in this checkout");
            const auto name = desk_map::match_key(opts["--from"]);
            const auto dot = name.find_last_of(":.");
            const auto leaf = dot == std::string::npos ? name : name.substr(dot + 1);
            const J empty_spans = J::object();
            const auto stored_spans = g.doc.find("spans");
            const auto& spans = stored_spans != g.doc.end() && stored_spans->is_object() ? *stored_spans : empty_spans;
            for (size_t i = 0; i < g.nodes.size(); ++i) {
                const auto& n = g.nodes[i];
                if (str(n, "file") != file || str(n, "kind") != "function") continue;
                const auto first = num(n, "line");
                const auto span = spans.find(str(n, "id"));
                if (first != line && (span == spans.end() || !span->is_array() || span->size() < 2
                    || !(*span)[1].is_number_integer() || first > line || (*span)[1].get<int>() < line)) continue;
                const auto label = desk_map::match_key(str(n, "label"));
                const auto last = label.find_last_of(":.");
                if (!leaf.empty() && leaf != (last == std::string::npos ? label : label.substr(last + 1))) continue;
                if (a >= 0) return refuse("Several functions in the map match this location");
                a = static_cast<long>(i);
            }
            if (a < 0) return refuse("No function in the map matches this location");
        }
        if (q == "trace") {
            // Through the function, up to where it starts and down to where it ends (or to --to): at most 16 calls each way.
            if (!opts["--to"].empty()) {
                const auto refusal = pick(opts["--to"], "To: ", b);
                if (!refusal.is_null()) return refusal;
            }
            long c = -1;
            if (!opts["--start"].empty()) {
                const auto refusal = pick(opts["--start"], "Start: ", c);
                if (!refusal.is_null()) return refusal;
            }
            out = desk_map::trace(g, static_cast<size_t>(a), std::clamp(map_number(opts["--depth"], 16), 1, 16), b, c);
        } else
            out = desk_map::walk(g, static_cast<size_t>(a), std::max(1, map_number(opts["--depth"], 3)), q == "callers",
                                 static_cast<size_t>(std::clamp(map_number(opts["--cap"], 300), 1, 3000)));
        if (!opts["--file"].empty()) out["root"] = root;
    } else if (q == "paths") {
        auto refusal = pick(opts["--from"], "From: ", a);
        if (refusal.is_null()) refusal = pick(opts["--to"], "To: ", b);
        if (!refusal.is_null()) return refusal;
        out = desk_map::paths(g, static_cast<size_t>(a), static_cast<size_t>(b), std::clamp(map_number(opts["--depth"], 10), 1, 16),
                              static_cast<size_t>(std::clamp(map_number(opts["--max"], 20), 1, 100)));
    } else if (q == "calls-into") {
        auto refusal = pick(opts["--of"], "", a);
        if (!refusal.is_null()) return refusal;
        out = desk_map::calls_into(g, static_cast<size_t>(a), static_cast<size_t>(std::clamp(map_number(opts["--cap"], 40), 1, 400)));
    } else if (q == "crossings") {
        if (opts["--from"].empty() || opts["--to"].empty()) return refuse("Name the two parts: --from PART --to PART");
        out = desk_map::crossings(g, opts["--from"], opts["--to"], static_cast<size_t>(std::clamp(map_number(opts["--cap"], 40), 1, 400)));
    } else if (q == "module") {
        out = opts["--name"].empty() ? desk_map::modules(g)
                                     : desk_map::module_contents(g, opts["--name"], static_cast<size_t>(std::clamp(map_number(opts["--cap"], 3000), 1, 20000)));
        if (out.value("ok", true) == false) return out;
    } else if (q == "touched") {
        const auto rev = opts["--commit"].empty() ? std::string("HEAD") : opts["--commit"];
        if (rev[0] == '-' || rev.size() > 200) return refuse("That is not a commit name");
        const auto git = [&](A args, int seconds = 3) {
            A argv{"git", "--no-optional-locks", "-C", root, "-c", "core.quotePath=false"};
            argv.insert(argv.end(), args.begin(), args.end());
            return query(argv, seconds);
        };
        const auto sha = trim(git({"rev-parse", "--verify", "--quiet", "--end-of-options", rev + "^{commit}"}));
        if (sha.size() < 40) return refuse("That is not a commit in this checkout: " + rev);
        auto parent = trim(git({"rev-parse", "--verify", "--quiet", sha + "^"}));
        if (parent.empty()) parent = trim(git({"hash-object", "-t", "tree", "/dev/null"}));
        out = desk_map::touched(g, desk_map::diff_ranges(git({"diff", "-U0", "--no-color", "--no-ext-diff", parent, sha}, 10)));
        out["commit"] = sha;
        out["subject"] = trim(git({"log", "-1", "--format=%s", sha}));
        // The map's lines are from its build: a file changed since that commit may have moved them.
        std::set<std::string> since, mapped;
        for (const auto& n : g.nodes) if (!str(n, "file").empty()) mapped.insert(str(n, "file"));
        const auto head = str(g.doc, "head");
        if (!head.empty() && head != sha) for (const auto& f : split(git({"diff", "--name-only", "-z", sha, head}, 10), '\0')) since.insert(f);
        for (const auto& f : desk_map::list(g.doc, "dirty_files")) if (f.is_string()) since.insert(f.get<std::string>());
        J moved = J::array();
        for (auto& f : out["files"]) {
            const bool shifted = since.count(str(f, "file")) > 0 && mapped.count(str(f, "file")) > 0;
            f["moved"] = shifted;
            if (shifted) moved.push_back(str(f, "file"));
        }
        out["moved"] = moved;
    } else return refuse("Ask one of reach, paths, callers, module or touched (--q)");
    out["built_at"] = num(g.doc, "built_at");
    out["head"] = str(g.doc, "head");
    out["complete"] = g.doc.value("complete", true);
    J answered = J::array();
    for (const auto& p : desk_map::list(g.doc, "providers")) if (str(p, "state") == "ok") answered.push_back(str(p, "name"));
    out["providers"] = answered;
    if (!avoided.is_null()) {
        out["avoided"] = avoided;
        // what a "no" covers: the map as built, the kinds of edge walked, the bounds (a negative is only that strong)
        out["searched"] = J{{"built_at", num(g.doc, "built_at")}, {"edges", J::array({"call", "call-by-name", "handoff"})},
                            {"depth", out.value("depth", 0)}, {"max", out.value("max", 0)}, {"complete", g.doc.value("complete", true)}};
        J rest = J::array();
        for (const auto& id : excluded) if (id != desk_map::text(avoided, "id")) rest.push_back(id);
        excluded = rest;
    }
    if (!excluded.empty()) out["excluded"] = excluded;
    return out;
}

// Starts the build as a desk-work job in the background (detached, so the caller's pipes close at once), or with
// --wait yes in the foreground; either way it is the same job, with its log and its notice when it fails.
int map_build(const std::string& root, std::map<std::string, std::string>& opts) {
    const auto say = [](const J& j) { std::cout << j.dump(-1, ' ', false, J::error_handler_t::replace) << '\n'; return j.value("ok", false) ? 0 : 1; };
    auto provider = opts["--provider"].empty() ? std::string("all") : opts["--provider"];
    if (provider != "all" && std::find(map_providers().begin(), map_providers().end(), provider) == map_providers().end())
        return say(refuse("The readers are syntax and binary (or all)"));
    if (!register_root(root) || !private_dir(map_dir(root))) return say(unwritable());
    if (!opts["--binary"].empty()) {
        std::error_code ec;
        const auto path = fs::canonical(fs::absolute(opts["--binary"], ec), ec).string();
        const auto problem = ec ? opts["--binary"] + " does not exist" : binary_problem(path);
        if (!problem.empty()) return say(refuse(problem));
        if (!atomic(map_dir(root) / "settings.json", J{{"binary", path}}.dump(), false)) return say(unwritable());
    }
    if (map_building(root).is_object()) return say(J{{"ok", true}, {"running", true}, {"message", "A map build is already running here"}});
    std::error_code ec;
    const auto self = fs::canonical("/proc/self/exe", ec).string();
    if (ec) return say(refuse("Could not find desk-work itself to start the build"));
    // stdout and stderr go to the job's log; the caller hears nothing until it asks map status.
    A argv{"sh", "-c", "exec >/dev/null 2>&1 </dev/null; exec \"$@\"", "sh", self, "run", "--root", root, "--title", "Project map",
           "--", self, "map", "build-run", "--root", root, "--provider", provider};
    if (opts["--wait"] == "yes") {
        const int code = sh::run(argv);
        auto status = map_status(root);
        status["exit"] = code;
        std::cout << status.dump(-1, ' ', false, J::error_handler_t::replace) << '\n';
        return code == 0 ? 0 : 1;
    }
    if (!sh::have("setsid")) return say(refuse("requires setsid (util-linux) to build in the background; --wait yes builds in the foreground"));
    atomic(map_dir(root) / "building.json", J{{"at", now()}, {"provider", provider}}.dump(), false);
    argv.insert(argv.begin(), {"setsid", "-f"});
    if (sh::run(argv) != 0) { fs::remove(map_dir(root) / "building.json", ec); return say(refuse("The build could not be started")); }
    return say(J{{"ok", true}, {"started", true}, {"message", "Building the project map in the background"}});
}

int map_command(const A& args, std::map<std::string, std::string>& opts) {
    const auto sub = args.size() > 1 ? args[1] : std::string();
    const auto root = root_of(opts.count("--root") ? opts["--root"] : fs::current_path().string());
    if (root.empty()) return 2;
    J out;
    if (sub == "build") return map_build(root, opts);
    if (sub == "build-run") return map_build_run(root, opts["--provider"]);
    if (sub == "status") out = map_status(root);
    else if (sub == "query") out = map_query(root, opts);
    else if (sub == "handoff") out = map_handoff(root, args.size() > 2 ? args[2] : std::string(), opts);
    else if (sub == "show" || sub == "export") {
        auto doc = map_json(map_dir(root) / "graph.json");
        if (!doc.is_object()) out = refuse("No project map of this checkout yet; build one with desk-work map build --root " + root);
        else if (sub == "show") { std::cout << doc.dump(-1, ' ', false, J::error_handler_t::replace) << '\n'; return 0; }
        else if (opts["--format"] != "dot") out = refuse("Export writes DOT: --format dot");
        else {
            const desk_map::Graph g(desk_map::corrected(std::move(doc), map_corrections(root)));
            std::cout << desk_map::dot(g, opts["--level"] == "functions" || !opts["--module"].empty() ? "functions" : "modules", opts["--module"]);
            return 0;
        }
    } else if (sub == "objdump-parse") {
        // What the binary reader makes of a disassembly on stdin (objdump -d --no-show-raw-insn --demangle).
        desk_map::Objdump reader;
        for (std::string line; std::getline(std::cin, line);) reader.line(line);
        out = reader.graph();
    } else {
        std::cerr << "desk-work map: choose build, status, query, show or export\n";
        return 2;
    }
    std::cout << out.dump(-1, ' ', false, J::error_handler_t::replace) << '\n';
    return out.is_object() && out.contains("ok") && out["ok"] == false ? 1 : 0;
}
