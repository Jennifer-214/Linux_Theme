// Work health's toolchain card (docs/desk-tools.md, "The toolchain card"): one check per contract-test record a tool
// declares (a status tool in fox-contract/1), read from the file its runner writes. Viewing runs no test: the card reads
// the declarations and the record, and asks git about the tested folder (rev-parse and status, read-only).

// A path from a record's list of uncommitted paths: a plain path, or a `git status --porcelain` line ("XY path",
// "R  old -> new", a quoted path). git quotes a path holding a control character or, by default (core.quotePath), a
// byte past ASCII, in C escapes ("tools/caf\303\251.py"): decoded, it is the name git status -z gives now.
std::string uncommitted_path(std::string entry) {
    const std::string codes = " MTADRCU?!";
    if (entry.size() > 3 && codes.find(entry[0]) != std::string::npos && codes.find(entry[1]) != std::string::npos && entry[2] == ' ')
        entry = entry.substr(3);
    const auto arrow = entry.find(" -> ");
    if (arrow != std::string::npos) entry = entry.substr(arrow + 4);
    return desk_map::unquote(entry);
}
// A directory holding its own .git is a nested repository (a worktree or a clone kept inside the folder), not the
// folder's content: neither counted nor compared.
bool nested_repo(const std::string& root, const std::string& rel) {
    std::error_code ec;
    return !root.empty() && !rel.empty() && fs::exists(fs::path(root) / rel / ".git", ec);
}
std::string some_of(const std::vector<std::string>& names) {
    std::string list;
    for (size_t i = 0; i < names.size() && i < 5; ++i) list += (i ? ", " : "") + names[i];
    if (names.size() > 5) list += " and " + std::to_string(names.size() - 5) + " more";
    return list;
}
std::string counted(size_t n, const std::string& one, const std::string& many) { return std::to_string(n) + " " + (n == 1 ? one : many); }
// The uncommitted files an input's record lists as its own content (nested repositories left out), and how many
// nested repositories it listed. `listed`: the record gives a list at all.
struct Uncommitted { std::vector<std::string> files; size_t nested = 0; bool listed = false; };
Uncommitted recorded_uncommitted(const J& ref) {
    Uncommitted out;
    const auto list = ref.value("version", J::object()).value("uncommitted", J());
    if (!list.is_array()) return out;
    out.listed = true;
    std::set<std::string> seen;
    for (const auto& entry : list) if (entry.is_string()) {
        const auto rel = uncommitted_path(entry.get<std::string>());
        if (nested_repo(str(ref, "path"), rel)) ++out.nested;
        else if (seen.insert(rel).second) out.files.push_back(rel);
    }
    return out;
}
// git, read-only, in the folder a record names: no optional locks, no fsmonitor, three seconds.
std::string git_read(const std::string& path, A rest, bool& ok) {
    A a{"git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path};
    a.insert(a.end(), rest.begin(), rest.end());
    if (sh::have("timeout")) a.insert(a.begin(), {"timeout", "-k", "1", "3"});
    std::string text;
    ok = sh::capture(a, text);
    return text;
}
// Whether the uncommitted path `rel` in `path` changed after `when` (seconds): a file by its own time; a folder (git
// names a new folder once) by the times of the files in it git does not ignore, as git ls-files --others lists them,
// so a cache written there after the run (__pycache__) is no change, and neither is the folder's own time, which such
// a cache moves. Nested repositories are left out. A change within that last second counts as after, so the card is
// never fresher than it can show. 1 changed, 0 not, -1 cannot tell (git cannot list the folder, or over 2000 files).
int changed_after(const std::string& path, const std::string& rel, long long when) {
    const auto later = [&](const fs::path& p) {
        struct stat st{};
        return ::lstat(p.c_str(), &st) == 0 && (st.st_mtim.tv_sec > when || (st.st_mtim.tv_sec == when && st.st_mtim.tv_nsec > 0));
    };
    std::error_code ec;
    if (!fs::is_directory(fs::symlink_status(fs::path(path) / rel, ec))) return later(fs::path(path) / rel) ? 1 : 0;
    bool ok = false;
    const auto files = split(git_read(path, {"ls-files", "--others", "--exclude-standard", "-z", "--", rel}, ok), '\0');
    if (!ok) return -1;
    size_t seen = 0;
    for (const auto& file : files) {
        if (file.back() == '/') continue;   // a nested repository, listed as a folder
        if (++seen > 2000) return -1;
        if (later(fs::path(path) / file)) return 1;
    }
    return 0;
}
// The card's freshness, by the tested folder (the tools tree the record names): stale when its tree id differs now
// (committed since), when the set of its uncommitted files differs, or when one of those files changed after the run
// ended. Read with git rev-parse HEAD:<folder> and status --porcelain -- <folder>/ (no optional locks, no fsmonitor,
// 3 s each) and the files' times; nested repositories are not the folder's content.
J compare_tested(const J& ref, long long ended) {
    const auto name = str(ref, "name"), path = str(ref, "path"), scope = str(ref, "scope");
    const auto version = ref.value("version", J::object());
    const auto tested = str(version, "tree");
    const auto folder = scope.empty() ? name : name + " " + scope;
    J out{{"name", name}, {"state", "unverified"}, {"why", ""}};
    const auto say = [&](const std::string& state, const std::string& why) { out["state"] = state; out["why"] = why; return out; };
    std::error_code ec;
    if (path.empty()) return say("unverified", "the record names no folder for " + name);
    if (tested.empty()) return say("unverified", "the record keeps no tree id for " + folder);
    if (!fs::is_directory(path, ec)) return say("unverified", path + " is not there");
    bool ok = false;
    const auto now_tree = trim(git_read(path, {"rev-parse", "--verify", "--quiet", "HEAD:" + scope}, ok));
    if (!ok || now_tree.empty()) return say("unverified", "git cannot read " + (scope.empty() ? path : scope + " in " + path));
    const auto fields = split(git_read(path, {"status", "--porcelain=v1", "-z", "--", scope.empty() ? "." : scope + "/"}, ok), '\0');
    if (!ok) return say("unverified", "git status cannot read " + (scope.empty() ? path : scope + " in " + path));
    std::set<std::string> now;
    for (size_t i = 0; i < fields.size(); ++i) {
        if (fields[i].size() < 4) continue;
        if (!nested_repo(path, fields[i].substr(3))) now.insert(fields[i].substr(3));
        if (fields[i][0] == 'R' || fields[i][0] == 'C') ++i;   // the next field is where it came from
    }
    const auto recorded = recorded_uncommitted(ref);
    const std::set<std::string> then(recorded.files.begin(), recorded.files.end());
    const auto dirty = version.value("dirty", J());
    if (!dirty.is_boolean() && !recorded.listed) return say("unverified", "the record does not say whether " + folder + " had uncommitted files");
    std::vector<std::string> reasons, changes;
    const auto stale = [&] {
        std::string why;
        for (const auto& r : reasons) why += (why.empty() ? "" : " · ") + r;
        return say("stale", why);
    };
    if (now_tree != tested)
        reasons.push_back((scope.empty() ? name : scope) + " committed since the run (" + folder + " tree " + tested.substr(0, 8) + " → " + now_tree.substr(0, 8) + ")");
    // Uncommitted files the record does not name cannot be compared one by one, but a commit since is still stale.
    if (dirty == true && !recorded.listed) {
        if (now.empty()) reasons.push_back("the uncommitted files the run tested in " + folder + " are gone");
        return reasons.empty() ? say("unverified", "the record names none of the uncommitted files it tested in " + folder) : stale();
    }
    std::vector<std::string> added, gone, edited, unknown;
    for (const auto& p : now) if (!then.count(p)) added.push_back(p);
    for (const auto& p : then) if (!now.count(p)) gone.push_back(p);
    if (!added.empty()) changes.push_back(std::to_string(added.size()) + " new (" + some_of(added) + ")");
    if (!gone.empty()) changes.push_back(std::to_string(gone.size()) + " no longer uncommitted (" + some_of(gone) + ")");
    for (const auto& p : now) if (then.count(p)) {
        const int changed = ended > 0 ? changed_after(path, p, ended) : -1;
        if (changed > 0) edited.push_back(p);
        else if (changed < 0) unknown.push_back(p);
    }
    if (!edited.empty()) changes.push_back("edited after it ended: " + some_of(edited));
    if (!changes.empty()) {
        std::string list;
        for (const auto& c : changes) list += (list.empty() ? "" : ", ") + c;
        reasons.push_back("uncommitted files in " + folder + " changed since the run: " + list);
    }
    if (!reasons.empty()) return stale();
    if (!unknown.empty())
        return say("unverified", counted(unknown.size(), "uncommitted file", "uncommitted files") + " in " + folder
                                 + (ended > 0 ? " could not be checked for edits after the run: " : " cannot be checked: the record gives no end time: ") + some_of(unknown));
    return say("same", folder + " unchanged since the run (tree " + now_tree.substr(0, 8)
                       + (now.empty() ? ", nothing uncommitted)" : "; the same " + counted(now.size(), "uncommitted file", "uncommitted files") + ", none edited since it ended)"));
}
std::string age_words(long long at) {
    const auto s = now() - at;
    if (at <= 0) return "at an unknown time";
    if (s < 0) return "in the future (the clock?)";
    if (s < 90) return "just now";
    if (s < 3600) return std::to_string(s / 60) + " minutes ago";
    if (s < 7200) return "an hour ago";
    if (s < 86400) return std::to_string(s / 3600) + " hours ago";
    if (s < 2 * 86400) return "a day ago";
    return std::to_string(s / 86400) + " days ago";
}
bool contract_tool(const J& t) { return str(t, "gives") == "status" && str(t, "format") == "fox-contract/1"; }
// One card for one contract-test record: its outcome, when, its counts and test names, what it ran against (and with
// which uncommitted files), whether that is still what is there, and its log.
J contract_card(const J& t, const std::vector<std::string>& declared_in, J& alerts) {
    const auto name = str(t, "name", str(t, "id"));
    std::string declared;
    for (const auto& f : declared_in) declared += (declared.empty() ? "" : ", ") + f;
    J check{{"id", "contract:" + hash(t.contains("reads") ? str(t, "reads") : str(t, "root") + '\0' + str(t, "id")).substr(0, 16)},
            {"root", str(t, "root")}};
    if (t.contains("refused")) {
        alerts.push_back(name + ": its declaration is refused");
        check["label"] = "Contract tests · " + name + " · declaration refused";
        check["detail"] = str(t, "refused") + "\nDeclared in " + declared;
        return check;
    }
    std::string why;
    auto r = tool_result(t, why);
    if (r.is_null()) {
        check["label"] = "Contract tests · " + name + " · not recorded yet";
        check["detail"] = "No result yet: " + why + "\nDeclared in " + declared;
        return check;
    }
    const auto state = str(r, "state");
    const bool refused = r["complete"] == false, unread = r["read"]["ok"] == false;
    std::string word = unread ? "unreadable" : refused ? "refused" : state == "ok" ? "passed" : state == "warn" ? "partial" : state == "fail" ? "failed" : "unknown";
    const auto at = r["at"].is_number_integer() ? r["at"].get<long long>() : 0LL;
    std::vector<std::string> lines;
    std::string first = std::string(1, static_cast<char>(std::toupper(static_cast<unsigned char>(word[0])))) + word.substr(1) + " "
                      + (at > 0 ? health_time(at) + ", " + age_words(at) : std::string("at a time the record does not give"));
    for (const auto& fact : r["facts"])
        first += " · " + (fact["value"].is_number() ? std::to_string(fact["value"].get<long long>()) : std::string("?")) + " " + str(fact, "name");
    lines.push_back(first);
    if (refused) lines.push_back(str(r, "why"));
    if (!str(r, "summary").empty() && !refused) lines.push_back(str(r, "summary"));
    for (const auto& [kind, title] : {std::pair<const char*, const char*>{"inconsistent", "Inconsistent: "}, {"failed", "Failed: "},
                                      {"skipped", "Skipped: "}, {"missing", "Did not run: "}}) {
        std::string names; size_t n = 0;
        for (const auto& f : r["findings"]) if (str(f, "kind") == kind) { if (++n <= 12) names += (names.empty() ? "" : ", ") + str(f, "message"); }
        if (n > 12) names += " and " + std::to_string(n - 12) + " more";
        if (n) lines.push_back(title + names);
    }
    // What it ran against, with which uncommitted files, and whether each tested tree is still what is there.
    std::string against, not_compared, moved;
    bool stale = false, unverified = false;
    size_t tested_files = 0;
    std::vector<std::string> fresh, unread_inputs, ran_with;
    for (const auto& ref : r["about"]) {
        const auto v = ref.value("version", J::object());
        for (const auto& value : ref.value("moved", J::array()))
            moved += (moved.empty() ? "" : ", ") + str(ref, "name") + (value.is_string() && !value.get<std::string>().empty() ? "." + value.get<std::string>() : std::string());
        if (!str(ref, "why").empty()) unread_inputs.push_back(str(ref, "name") + ": " + str(ref, "why"));
        if (!ref.contains("version")) continue;
        const auto folder = str(ref, "scope").empty() ? str(ref, "name") : str(ref, "name") + " " + str(ref, "scope");
        const auto files = recorded_uncommitted(ref);
        std::string part = str(ref, "name");
        if (!str(v, "release").empty()) part += " " + str(v, "release");
        if (!str(v, "head").empty()) part += " " + str(v, "head").substr(0, 8);
        if (!str(v, "tree").empty()) part += ", " + str(ref, "scope", "tree") + " tree " + str(v, "tree").substr(0, 8);
        if (!files.files.empty()) part += " + " + counted(files.files.size(), "uncommitted file", "uncommitted files");
        else if (v.value("dirty", J()) == true && !files.listed) part += " + uncommitted changes";
        against += (against.empty() ? "" : " · ") + part;
        if (!files.files.empty() || files.nested)
            ran_with.push_back("Ran with " + counted(files.files.size(), "uncommitted file", "uncommitted files") + " in " + folder
                               + (files.files.empty() ? "" : ": " + some_of(files.files))
                               + (files.nested ? " (" + counted(files.nested, "nested repository", "nested repositories") + " not counted)" : ""));
        if (str(v, "tree").empty()) { not_compared += (not_compared.empty() ? "" : ", ") + str(ref, "name"); continue; }
        tested_files += files.files.size();
        const auto compared = compare_tested(ref, at);
        const auto how = str(compared, "state");
        stale = stale || how == "stale"; unverified = unverified || how == "unverified";
        fresh.push_back(how == "stale" ? "STALE: " + str(compared, "why") : how == "unverified" ? "Unverified: " + str(compared, "why") : str(compared, "why"));
    }
    lines.push_back("Ran against: " + (against.empty() ? std::string("not recorded") : against));
    for (const auto& line : ran_with) lines.push_back(line);
    for (const auto& line : unread_inputs) lines.push_back(line);
    for (const auto& line : fresh) lines.push_back(line);
    if (!moved.empty()) { unverified = true; lines.push_back("Inputs changed during the run: " + moved); }
    if (fresh.empty() && !unread) { unverified = true; lines.push_back("Unverified: the record names no tested tree to compare"); }
    lines.push_back("Not compared: " + (not_compared.empty() ? std::string() : not_compared + ", ") + "gitignored files and the machine's tools");
    lines.push_back("Log: " + (r["log"].is_string() ? r["log"].get<std::string>() : std::string("not recorded")));
    lines.push_back("Read from " + str(r["read"], "from") + " · declared in " + declared);
    std::string detail;
    for (const auto& line : lines) detail += (detail.empty() ? "" : "\n") + line;
    // A pass on uncommitted tested files is no clean pass, and says so.
    if (word == "passed" && tested_files) word += " with " + counted(tested_files, "uncommitted file", "uncommitted files");
    check["label"] = "Contract tests · " + name + " · " + word + (stale ? " · STALE" : unverified ? " · unverified" : "");
    check["detail"] = detail;
    if (r["log"].is_string()) check["log"] = r["log"];
    if (word.rfind("passed", 0) != 0) alerts.push_back(name + ": " + word);
    else if (stale) alerts.push_back(name + ": stale, what it tested changed since the run");
    else if (!moved.empty()) alerts.push_back(name + ": inputs changed during the run");
    else if (unverified) alerts.push_back(name + ": what it tested could not be compared with now");
    return check;
}
// Work health's toolchain card: one check per contract-test record a tool declares, "Contract tests · none declared"
// when there is none. A refused declaration is also named by declaration_checks (tools.hpp).
void contract_checks(J& checks, J& alerts) {
    const auto tools = tools_of(all_declarations());
    // One card per record: the same record declared from two checkouts (worktrees of one project) is one result.
    std::vector<std::pair<std::string, std::vector<J>>> results;
    for (const auto& t : tools) if (contract_tool(t)) {
        const auto key = t.contains("refused") ? str(t, "file") + '\0' + std::to_string(num(t, "index"))
                       : t.contains("reads") ? str(t, "reads") : str(t, "root") + '\0' + str(t, "id");
        const auto at = std::find_if(results.begin(), results.end(), [&](const auto& r) { return r.first == key; });
        if (at == results.end()) results.push_back({key, {t}}); else at->second.push_back(t);
    }
    if (results.empty())
        checks.push_back(J{{"id", "contract-tests"}, {"label", "Contract tests · none declared"},
            {"detail", "No tool declares a contract-test record. A test runner that writes fox-contract/1 is declared as a status tool "
                       "in .desk/tools.json, or in " + desk_d().string() + "/<name>.json for a repo that must not change (docs/desk-tools.md)."}});
    for (const auto& [key, same] : results) {
        std::vector<std::string> declared;
        for (const auto& t : same) declared.push_back(str(t, "file"));
        // Named as its own declaration names it: the desk.d file a tool writes for itself, when there is one.
        const auto own = std::find_if(same.begin(), same.end(), [](const J& t) { return t.contains("written_by"); });
        checks.push_back(contract_card(own == same.end() ? same.front() : *own, declared, alerts));
    }
}
