// A project's own tools (docs/desk-tools.md), declared in ONE format: .desk/tools.json at a checkout's top level, or the
// same format as ${XDG_CONFIG_HOME:-~/.config}/foxml/desk.d/<name>.json with a root, for a repo that must not change or
// a path that must stay private. Viewing (tools list, show and result, work health and its toolchain card) runs
// nothing a declaration names, only git reads. An argv tool runs on her keypress alone: tools run, at a terminal, after
// her yes on that exact entry (pinned to its hash in the checkout's records); agents read results. No result is
// copied: a reads tool's file is read where its tool writes it, a run's answer is that job's own output, and
// results.hpp turns either into desk-result/1.
fs::path desk_d() { return fs::path(env("XDG_CONFIG_HOME", env("HOME") + "/.config")) / "foxml/desk.d"; }

// One declared tool, checked: the fields desk-work reads, and `refused` with the reason when it cannot be used.
// Fields it does not read are ignored.
J check_tool(const J& raw) {
    J t = J::object();
    const auto no = [&](const std::string& why) { t["refused"] = why; return t; };
    if (!raw.is_object()) return no("an entry is not an object");
    const auto id = str(raw, "id");
    t["id"] = id;
    if (!std::regex_match(id, std::regex("[A-Za-z0-9][A-Za-z0-9_-]{0,47}")))
        return no(id.empty() ? "no id" : "id \"" + one_line(id, 60) + "\" is not 1 to 48 letters, digits, - and _");
    const auto name = text_or_null(raw.value("name", J()), 80);
    t["name"] = name.is_null() ? J(id) : name;
    const auto gives = str(raw, "gives"), format = str(raw, "format");
    t["gives"] = gives; t["format"] = format;
    if (!std::set<std::string>{"graph", "findings", "figures", "status"}.count(gives)) return no("gives must be graph, findings, figures or status");
    const auto kinds = result_formats().find(format);
    if (kinds == result_formats().end()) return no("format must be json, toolio, fox-symdeps/2, lines, dot or fox-contract/1");
    if (!kinds->second.count(gives)) return no(format + " does not give " + gives);
    if (raw.contains("argv")) {
        const auto& argv = raw["argv"];
        if (!argv.is_array() || argv.empty() || argv.size() > 64) return no("argv must be a list of 1 to 64 strings (no shell)");
        for (const auto& a : argv)
            if (!a.is_string() || a.get<std::string>().size() > 4096 || a.get<std::string>().find('\0') != std::string::npos)
                return no("argv must be a list of 1 to 64 strings (no shell)");
        if (argv[0].get<std::string>().empty()) return no("argv names no program");
        t["argv"] = argv;
    }
    if (raw.contains("reads")) {
        const auto reads = raw["reads"].is_string() ? raw["reads"].get<std::string>() : std::string();
        if (reads.empty() || reads.size() > 1024 || !fs::path(reads).is_absolute() || reads.find_first_of(std::string("\0\n", 2)) != std::string::npos)
            return no("reads must be the absolute path of the file the tool writes");
        t["reads"] = fs::path(reads).lexically_normal().string();
    }
    if (!t.contains("argv") && !t.contains("reads")) return no("neither argv nor reads: nothing to run or read");
    t["when"] = raw.contains("when") ? raw["when"] : J("ask");
    if (!t["when"].is_string() || !std::set<std::string>{"ask", "save", "run"}.count(str(t, "when"))) return no("when must be ask, save or run");
    if (raw.contains("timeout_ms")) {
        if (!raw["timeout_ms"].is_number_integer() || raw["timeout_ms"].get<long long>() < 100 || raw["timeout_ms"].get<long long>() > 3600000)
            return no("timeout_ms must be 100 to 3600000");
        t["timeout_ms"] = raw["timeout_ms"];
    }
    return t;
}

// A project's own declaration arrives with the repo (a clone, an agent's edit), so what it reads stays in its checkout:
// no "..", and the path, symbolic links resolved, inside the checkout's folder. A desk.d file is hers and may name any
// path. Each desk-work command reads the declarations afresh, so a link the repo gains later is caught then. Empty
// when `reads` may be read, else why not.
std::string reads_outside(const std::string& root, const std::string& reads) {
    const std::string rule = ": a project's own declaration reads only files in its checkout (a desk.d file may name any path)";
    for (const auto& part : fs::path(reads)) if (part == "..") return "reads " + one_line(reads, 200) + " goes through .." + rule;
    std::error_code ec;
    const auto top = fs::canonical(root, ec);
    const auto real = ec ? fs::path() : fs::weakly_canonical(reads, ec);
    const auto inside = real.lexically_relative(top);
    if (ec || inside.empty() || *inside.begin() == "..") return "reads " + one_line(reads, 200) + " is outside " + root + rule;
    return {};
}

// One declaration file and its tools, each checked; null when there is no file. A file that cannot be used says why
// and declares nothing. A desk.d file names the checkout its tools are for (root); a project's own file is for its
// checkout, and its tools run at the checkout's top level.
J read_declaration(const fs::path& file, const std::string& project) {
    struct stat st{};
    if (::lstat(file.c_str(), &st) != 0) return J();
    J out{{"file", file.string()}, {"root", project}, {"ok", false}, {"tools", J::array()}};
    const auto no = [&](const std::string& why) { out["message"] = why; return out; };
    if (!S_ISREG(st.st_mode)) return no("not a regular file");
    if (st.st_size > 64 * 1024) return no("larger than 64 KiB");
    const auto doc = J::parse(read(file, 64 * 1024), nullptr, false);
    if (doc.is_discarded()) return no("not valid JSON");
    if (!doc.is_object()) return no("not a JSON object");
    if (!doc.contains("version") || doc["version"] != 1)
        return no("version " + (doc.contains("version") ? one_line(doc["version"].dump(), 20) : std::string("missing")) + ": this desk-work reads version 1");
    std::string root = project, cwd = project;
    if (project.empty()) {
        const auto named = str(doc, "root");
        if (named.empty()) return no("a desk.d declaration names the checkout its tools are for (root)");
        if (!fs::path(named).is_absolute()) return no("root " + one_line(named, 200) + " is not an absolute path");
        std::error_code ec;
        const auto folder = fs::canonical(named, ec);
        if (ec || !fs::is_directory(folder, ec)) return no("root " + one_line(named, 200) + " is not a folder");
        cwd = folder.string(); root = root_of(cwd);
    }
    out["root"] = root;
    if (doc.contains("written_by")) out["written_by"] = text_or_null(doc["written_by"], 80);
    if (!doc.contains("tools") || !doc["tools"].is_array()) return no("no tools list");
    if (doc["tools"].size() > 64) return no("more than 64 tools");
    out["ok"] = true;
    for (size_t i = 0; i < doc["tools"].size(); ++i) {
        auto t = check_tool(doc["tools"][i]);
        if (!project.empty() && !t.contains("refused") && t.contains("reads"))
            if (const auto why = reads_outside(root, doc["tools"][i]["reads"].get<std::string>()); !why.empty()) t["refused"] = why;
        t["file"] = file.string(); t["index"] = i; t["root"] = root; t["cwd"] = cwd;
        if (out.contains("written_by")) t["written_by"] = out["written_by"];
        out["tools"].push_back(t);
    }
    return out;
}
std::vector<fs::path> desk_d_files() {
    std::vector<fs::path> files; std::error_code ec;
    for (const auto& e : fs::directory_iterator(desk_d(), ec)) {
        const auto name = e.path().filename().string();
        if (name.size() > 5 && name[0] != '.' && name.compare(name.size() - 5, 5, ".json") == 0) files.push_back(e.path());
    }
    std::sort(files.begin(), files.end());
    if (files.size() > 64) files.resize(64);
    return files;
}
// The declaration files for one checkout: its .desk/tools.json and each desk.d file naming it. A desk.d file that
// cannot be read names no checkout, so it is listed for every one: a typo there is never silent.
J declarations_for(const std::string& root) {
    J files = J::array();
    if (auto own = read_declaration(fs::path(root) / ".desk/tools.json", root); !own.is_null()) files.push_back(own);
    for (const auto& file : desk_d_files()) {
        auto d = read_declaration(file, "");
        if (!d.is_null() && (!d.value("ok", false) || str(d, "root") == root)) files.push_back(d);
    }
    return files;
}
// Every declaration desk-work can see: .desk/tools.json in each checkout it keeps records of, and each desk.d file
// (in the order declarations_for reads them, so a refusal names its places the same way everywhere).
J all_declarations() {
    J files = J::array();
    for (const auto& value : known_roots()) {
        const auto root = value.get<std::string>();
        if (auto own = read_declaration(fs::path(root) / ".desk/tools.json", root); !own.is_null()) files.push_back(own);
    }
    for (const auto& file : desk_d_files()) if (auto d = read_declaration(file, ""); !d.is_null()) files.push_back(d);
    return files;
}
// The tools of these files. A tool id declared more than once for one checkout is refused in every place, naming each:
// desk-work never picks one.
J tools_of(const J& files) {
    J tools = J::array();
    for (const auto& f : files) for (const auto& t : f.value("tools", J::array())) tools.push_back(t);
    std::map<std::pair<std::string, std::string>, std::vector<size_t>> by_id;
    for (size_t i = 0; i < tools.size(); ++i) if (!str(tools[i], "id").empty()) by_id[{str(tools[i], "root"), str(tools[i], "id")}].push_back(i);
    for (const auto& [key, places] : by_id) {
        if (places.size() < 2) continue;
        std::string list;
        for (size_t k = 0; k < places.size(); ++k) {
            const auto file = str(tools[places[k]], "file");
            const bool again = std::count_if(places.begin(), places.end(), [&](size_t j) { return str(tools[j], "file") == file; }) > 1;
            list += (k == 0 ? "" : k + 1 == places.size() ? " and " : ", ") + file
                  + (again ? " (tool " + std::to_string(num(tools[places[k]], "index") + 1) + ")" : "");
        }
        for (const auto i : places)
            tools[i]["refused"] = (places.size() == 2 ? std::string("declared twice: ") : "declared " + std::to_string(places.size()) + " times: ") + list;
    }
    return tools;
}
J find_tool(const J& tools, const std::string& id) {
    for (const auto& t : tools) if (str(t, "id") == id) return t;
    return J();
}

// What her yes is for: the command and where it runs. A changed entry asks again, so editing a declaration cannot get a
// command run.
std::string tool_hash(const J& t) {
    return hash(J{{"cwd", str(t, "cwd")}, {"argv", t.value("argv", J())}, {"timeout_ms", t.value("timeout_ms", J())}}.dump());
}
fs::path approvals_file(const std::string& root) { return project_dir(root) / "tool-approvals.json"; }
bool approved(const J& t) {
    const auto record = json(approvals_file(str(t, "root")));
    const auto id = str(t, "id");
    return record.is_object() && record.contains(id) && record[id].is_object() && str(record[id], "hash") == tool_hash(t);
}
J approve(const J& t) {
    const auto root = str(t, "root");
    if (!register_root(root)) return unwritable();
    Lock lock(project_dir(root) / "tools.lock");
    if (lock.fd < 0) return unwritable();
    const auto file = approvals_file(root);
    auto record = json(file);
    std::error_code ec;
    if (fs::exists(file, ec) && !record.is_object()) return unreadable("tool-approvals.json");
    if (!record.is_object()) record = J::object();
    record[str(t, "id")] = J{{"hash", tool_hash(t)}, {"at", now()}, {"argv", t["argv"]}, {"cwd", str(t, "cwd")}, {"file", str(t, "file")}};
    return written(atomic(file, record.dump()), "tool approval");
}

// The tool's newest finished run in its checkout.
J tool_last_run(const J& t) {
    for (const auto& r : runs(str(t, "root")))
        if (str(r, "kind") == "tool" && r.value("tool", J()).is_object() && str(r["tool"], "id") == str(t, "id") && finished_run(r)) return r;
    return J();
}
ResultFrom result_from(const J& t) {
    ResultFrom from;
    from.id = str(t, "id"); from.name = str(t, "name"); from.gives = str(t, "gives"); from.format = str(t, "format");
    from.root = str(t, "root"); from.producer = str(t, "written_by");
    return from;
}
// What a run answered: its stdout alone, or for lines everything it printed (compilers warn on stderr), which is the
// job's own log. `cut` says the answer lost its end (stdout past 4 MiB) or the log its start.
std::string run_answer(const J& run, const std::string& format, bool& cut) {
    if (format == "lines") { cut = run.value("truncated", false); return read(run_dir(str(run, "id")) / "output.log", 4 * 1024 * 1024); }
    cut = run.value("tool", J::object()).value("answerCut", false);
    return read(run_dir(str(run, "id")) / "answer", 4 * 1024 * 1024);
}
// A tool's answer as desk-result/1: the file it writes (reads), else its newest finished run's answer here. Reads files
// and run records only. Null, with `why`, when there is no answer yet.
J tool_result(const J& t, std::string& why) {
    auto from = result_from(t);
    std::string text; bool cut = false;
    if (t.value("reads", J()).is_string()) {
        const fs::path path = str(t, "reads");
        struct stat st{};
        if (::lstat(path.c_str(), &st) != 0) { why = "nothing at " + path.string() + " yet (its tool writes it)"; return J(); }
        from.origin = path.string(); from.at = st.st_mtime;
        if (!S_ISREG(st.st_mode)) return refused_result(result_base(from), path.string() + " is not a regular file", true);
        if (st.st_size > 16 * 1024 * 1024) return refused_result(result_base(from), path.string() + " is larger than 16 MiB", true);
        text = read(path, 16 * 1024 * 1024);
    } else {
        const auto run = tool_last_run(t);
        if (!run.is_object()) { why = str(t, "id") + " has not run here yet (desk-work tools run " + str(t, "id") + ")"; return J(); }
        from.origin = "run " + str(run, "id"); from.at = num(run, "ended"); from.exit = static_cast<int>(num(run, "exit", -1));
        from.command = str(run, "command");
        text = run_answer(run, from.format, cut);
    }
    auto r = desk_result(text, from);
    if (cut) {
        r["complete"] = false;
        r["why"] = "the tool printed more than 4 MiB; this is part of it" + (r["why"].is_string() ? "; " + r["why"].get<std::string>() : std::string());
    }
    return r;
}
// A figures tool's run, as the run's figures, so desk-work metrics sets them against its previous run. Only figures in
// a unit desk-work compares (or none, a count) are kept.
J tool_figures(const J& job) {
    const auto tool = job.value("tool", J::object());
    J out = J::array();
    if (str(tool, "gives") != "figures") return out;
    auto from = result_from(tool);
    from.root = str(job, "root");
    bool cut = false;
    const auto text = tool.value("reads", J()).is_string() ? read(str(tool, "reads"), 16 * 1024 * 1024) : run_answer(job, from.format, cut);
    const auto answer = desk_result(text, from);
    for (const auto& fact : answer["facts"]) {
        const auto unit = str(fact, "unit");
        if (!fact["value"].is_number() || (!unit.empty() && metric_unit(unit).dimension.empty())) continue;
        out.push_back(J{{"name", fact["name"]}, {"value", fact["value"]}, {"unit", unit}, {"source", "tool"}});
    }
    return out;
}

// An argument as she reads it: in single quotes, or, when it holds a character a terminal acts on (a C0 or C1 control,
// DEL, a bidi override or isolate), in $'…' with that character escaped, so the command shown for her yes is the one
// that runs. The tool's job keeps the same line as its command.
std::string shown_arg(const std::string& s) {
    std::string plain = "'", escaped = "$'";
    bool special = false;
    for (size_t i = 0; i < s.size(); ++i) {
        const auto at = [&](size_t k) -> unsigned { return i + k < s.size() ? static_cast<unsigned char>(s[i + k]) : 0u; };
        unsigned code = 0;
        size_t len = 0;
        if (at(0) < 0x20 || at(0) == 0x7f) { code = at(0); len = 1; }
        else if (at(0) == 0xc2 && at(1) >= 0x80 && at(1) <= 0x9f) { code = at(1); len = 2; }
        else if (at(0) == 0xe2 && ((at(1) == 0x80 && at(2) >= 0xaa && at(2) <= 0xae) || (at(1) == 0x81 && at(2) >= 0xa6 && at(2) <= 0xa9))) {
            code = 0x2000u | ((at(1) & 0x3fu) << 6) | (at(2) & 0x3fu); len = 3;
        }
        if (len) {
            char hex[8];
            // \x is one byte in $'…'; a C1 control or bidi mark is a UTF-8 character, so \u names it.
            std::snprintf(hex, sizeof hex, code < 0x80 ? "\\x%02x" : "\\u%04x", code);
            escaped += code == '\n' ? std::string("\\n") : code == '\t' ? std::string("\\t") : code == '\r' ? std::string("\\r") : std::string(hex);
            special = true;
            i += len - 1;
        } else {
            plain += s[i] == '\'' ? std::string("'\\''") : std::string(1, s[i]);
            escaped += s[i] == '\'' ? std::string("\\'") : s[i] == '\\' ? std::string("\\\\") : std::string(1, s[i]);
        }
    }
    return special ? escaped + "'" : plain + "'";
}
// A name or path in that question: as it is, or in $'…' when it holds such a character.
std::string shown_text(const std::string& s) { const auto arg = shown_arg(s); return arg.rfind("$'", 0) == 0 ? arg : s; }
std::string argv_label(const J& argv) {
    std::string label;
    for (const auto& a : argv) label += (label.empty() ? "" : " ") + shown_arg(a.get<std::string>());
    return label;
}
// The program an argv tool needs and this machine lacks (on PATH, or a path from the tool's folder), else empty.
std::string tool_requires(const J& t) {
    if (!t.value("argv", J()).is_array()) return {};
    const auto program = t["argv"][0].get<std::string>();
    if (program.find('/') == std::string::npos) return sh::have(program) ? std::string() : program;
    const auto path = fs::path(program).is_absolute() ? fs::path(program) : fs::path(str(t, "cwd")) / program;
    std::error_code ec;
    return fs::is_regular_file(path, ec) && ::access(path.c_str(), X_OK) == 0 ? std::string() : program;
}
// tools run: her keypress, at a terminal. The first run of an entry, and the first after it changed, shows the exact
// command and asks for her yes; an agent (no terminal, or Claude Code's own shell) is refused and reads results instead.
int run_tool(const J& t) {
    const auto say = [](const J& j) { std::cout << j.dump(-1, ' ', false, J::error_handler_t::replace) << '\n'; return 1; };
    const auto id = str(t, "id"), name = str(t, "name"), cwd = str(t, "cwd"), root = str(t, "root");
    if (t.contains("refused")) return say(refuse(id + " is refused: " + str(t, "refused")));
    if (!t.value("argv", J()).is_array())
        return say(refuse(id + " has no argv: its tool writes " + str(t, "reads") + " itself, and desk-work only reads it"));
    if (!env("CLAUDECODE").empty() || !::isatty(STDIN_FILENO) || !::isatty(STDOUT_FILENO))
        return say(refuse("desk-work tools run starts a declared command only at your keypress, in a terminal; "
                          "agents read the answer with desk-work tools result " + id));
    if (const auto missing = tool_requires(t); !missing.empty()) return say(refuse(id + " requires " + missing + ", which is not installed here; nothing was run"));
    if (t.contains("timeout_ms") && !sh::have("timeout")) return say(refuse(id + " requires timeout (coreutils) for its timeout_ms; nothing was run"));
    const auto label = argv_label(t["argv"]);
    if (!approved(t)) {
        std::cout << shown_text(name) << " (" << id << ") runs, in " << shown_text(cwd) << ":\n  " << label << "\ndeclared in "
                  << shown_text(str(t, "file")) << "\nNew or changed since your last yes. Run it? [y/N] " << std::flush;
        std::string answer;
        std::getline(std::cin, answer);
        answer = lowered(trim(answer));
        if (answer != "y" && answer != "yes") { std::cout << "Not run.\n"; return 1; }
        const auto ok = approve(t);
        if (!ok.value("ok", false)) return say(ok);
    }
    std::error_code ec;
    fs::current_path(cwd, ec);
    if (ec) return say(refuse(cwd + " is gone; nothing was run"));
    A child;
    if (t.contains("timeout_ms")) {
        char seconds[32]{};
        std::snprintf(seconds, sizeof seconds, "%.3f", t["timeout_ms"].get<long long>() / 1000.0);
        child = {"timeout", "--kill-after=2", seconds};
    }
    for (const auto& a : t["argv"]) child.push_back(a.get<std::string>());
    // A Python tool leaves no bytecode in the project it reads.
    ::setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    J tool{{"id", id}, {"name", name}, {"gives", str(t, "gives")}, {"format", str(t, "format")}, {"file", str(t, "file")}, {"hash", tool_hash(t)}};
    if (t.contains("reads")) tool["reads"] = t["reads"];
    if (t.contains("written_by")) tool["written_by"] = t["written_by"];
    auto job = begin(label, root, "", ::getpid(), false, name, cwd, J{{"kind", "tool"}, {"tool", tool}});
    if (!job.is_object()) return say(refuse("Could not record the run in " + base().string() + ", so nothing was run"));
    bool truncated = false, cut = false;
    const auto dir = run_dir(str(job, "id"));
    const int code = sh::run_logged(child, dir / "output.log", 4 * 1024 * 1024, truncated, dir / "answer", cut);
    job["tool"]["answerCut"] = cut;
    finish(job, code, truncated);
    if (str(job, "state") == "failed") notify_failure(name, str(job, "id"), false);
    std::string why;
    const auto result = tool_result(t, why);
    std::cout << "\n── " << id << " · " << str(job, "state");
    if (result.is_object()) {
        std::cout << " · " << str(t, "gives") << (result.contains("state") ? " " + str(result, "state") : std::string())
                  << (str(result, "summary").empty() ? std::string() : " · " + str(result, "summary"))
                  << (result["complete"] == false ? " · incomplete: " + str(result, "why") : std::string())
                  << "\n   desk-work tools result " << id << " prints the whole answer\n";
    } else std::cout << " · no answer: " << why << '\n';
    return code < 0 ? 125 : code;
}

// What tools list and show say about a tool's last answer, without reading it: when, and from where.
J last_answer(const J& t) {
    if (t.value("reads", J()).is_string()) {
        struct stat st{};
        if (::lstat(str(t, "reads").c_str(), &st) != 0) return J();
        return J{{"at", static_cast<long long>(st.st_mtime)}, {"from", str(t, "reads")}};
    }
    const auto run = tool_last_run(t);
    return run.is_object() ? J{{"at", num(run, "ended")}, {"from", "run " + str(run, "id")}, {"state", str(run, "state")}} : J();
}
J tool_listing(const std::string& root, const J& files, const J& tools) {
    J listed = J::array(), declared = J::array();
    for (const auto& f : files) {
        J file{{"file", str(f, "file")}, {"ok", f.value("ok", false)}};
        for (const char* key : {"message", "written_by", "root"}) if (f.contains(key) && !f[key].is_null()) file[key] = f[key];
        declared.push_back(file);
    }
    for (auto t : tools) {
        if (!str(t, "id").empty() && !t.contains("refused")) {
            if (t.contains("argv")) t["approved"] = approved(t);
            if (const auto missing = tool_requires(t); !missing.empty()) t["requires"] = missing;
            t["last"] = last_answer(t);
        }
        listed.push_back(t);
    }
    return J{{"ok", true}, {"root", root}, {"files", declared}, {"tools", listed}};
}
J tool_show(J t) {
    if (!t.contains("refused")) {
        if (t.contains("argv")) { t["approved"] = approved(t); t["command"] = argv_label(t["argv"]); }
        if (const auto missing = tool_requires(t); !missing.empty()) t["requires"] = missing;
        t["last"] = last_answer(t);
        if (str(t, "when") != "ask") t["note"] = "when " + str(t, "when") + " is not built yet: it runs when you ask (desk-work tools run)";
    }
    t["ok"] = true;
    return t;
}

int tools_command(const A& args, std::map<std::string, std::string>& opts) {
    const auto sub = args.size() > 1 ? args[1] : std::string();
    const auto id = args.size() > 2 ? args[2] : opts["--id"];
    const auto root = root_of(opts.count("--root") ? opts["--root"] : fs::current_path().string());
    const auto say = [](const J& j) {
        std::cout << j.dump(-1, ' ', false, J::error_handler_t::replace) << '\n';
        return j.is_object() && j.contains("ok") && j["ok"] == false ? 1 : 0;
    };
    if (root.empty()) return 2;
    if (!std::set<std::string>{"list", "show", "run", "result"}.count(sub)) { std::cerr << "desk-work tools: choose list, show, run or result\n"; return 2; }
    const auto files = declarations_for(root);
    const auto tools = tools_of(files);
    if (sub == "list") return say(tool_listing(root, files, tools));
    if (id.empty()) { std::cerr << "desk-work tools " << sub << ": name the tool (desk-work tools " << sub << " ID)\n"; return 2; }
    const auto t = find_tool(tools, id);
    if (t.is_null()) return say(refuse("No tool " + id + " is declared for " + root + "; desk-work tools list shows what is"));
    if (sub == "show") return say(tool_show(t));
    if (sub == "run") return run_tool(t);
    if (t.contains("refused")) return say(refuse(id + " is refused: " + str(t, "refused")));
    std::string why;
    const auto result = tool_result(t, why);
    return say(result.is_null() ? refuse("No answer yet: " + why) : result);
}

// Work health's check for the declarations desk-work refused (a file it cannot read, a tool it cannot use, an id
// declared twice), each with its reason; none while every declaration is fine.
void declaration_checks(J& checks, J& alerts) {
    const auto files = all_declarations();
    std::vector<std::string> problems;
    for (const auto& f : files) if (!f.value("ok", false)) problems.push_back(str(f, "file") + ": " + str(f, "message"));
    for (const auto& t : tools_of(files)) if (t.contains("refused"))
        problems.push_back(str(t, "file") + ": " + (str(t, "id").empty() ? std::string("a tool") : "tool " + str(t, "id")) + ": " + str(t, "refused"));
    if (problems.empty()) return;
    alerts.push_back("Tool declarations: " + std::to_string(problems.size()) + " refused");
    std::string detail;
    for (size_t i = 0; i < problems.size() && i < 10; ++i) detail += (i ? "\n" : "") + problems[i];
    if (problems.size() > 10) detail += "\nand " + std::to_string(problems.size() - 10) + " more (desk-work tools list in each checkout)";
    checks.push_back(J{{"id", "tool-declarations"}, {"label", "Tool declarations · " + std::to_string(problems.size()) + " refused"}, {"detail", detail}});
}
