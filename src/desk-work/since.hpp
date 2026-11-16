// "Since you last looked", for the editor's since page: new commits, test runs, job runs (with how their figures
// moved) and Claude turns (with the files they edited) after the reader last opened it in this checkout. The time it
// was opened is kept per reader in seen.json, beside the digest's read positions; `mark` sets it to now, after the
// list is read against the time before. A reader that never looked gets the last day.
J since_page(const std::string& root, const std::string& reader, bool mark) {
    if (!std::regex_match(reader, std::regex("[A-Za-z0-9:_-]{1,100}"))) return refuse("A reader name uses letters, digits, : _ and -, up to 100");
    const auto path = project_dir(root) / "seen.json";
    const auto key = hash("since:" + reader);
    const auto seen = json(path);
    const long long from = seen.is_object() ? num(seen, key.c_str()) : 0;
    const long long after = from > 0 ? from : now() - 86400;
    J items = J::array();
    A log{"git", "--no-optional-locks", "-C", root, "log", "-50", "--since=@" + std::to_string(after - 1), "--format=%H%x1f%ct%x1f%an%x1f%s%x1e"};
    std::error_code error;
    if (fs::exists(fs::path(root) / ".git", error)) for (const auto& entry : split(query(log), '\x1e')) {
        std::vector<std::string> f; std::istringstream fields(trim(entry)); std::string field;
        while (std::getline(fields, field, '\x1f')) f.push_back(field);
        long long at = 0;
        if (f.size() < 4 || f[0].size() != 40 || std::from_chars(f[1].data(), f[1].data() + f[1].size(), at).ec != std::errc{} || at < after) continue;
        items.push_back(J{{"kind", "commit"}, {"at", at}, {"sha", f[0]}, {"author", f[2]}, {"label", f[3]}});
    }
    const auto all = runs(root);
    for (const auto& r : all) {
        const auto at = num(r, "ended") > 0 ? num(r, "ended") : num(r, "started");
        if (at < after) continue;
        const bool tests = r.value("testRun", false);
        J item{{"kind", tests ? "tests" : "job"}, {"at", at}, {"id", str(r, "id")}, {"label", str(r, "title", str(r, "command"))},
               {"state", str(r, "state")}};
        if (tests && r.contains("tests") && r["tests"].is_object()) { item["passed"] = r["tests"].value("passed", J()); item["failed"] = r["tests"].value("failed", J()); }
        // A job's figures that moved since its previous run; a test run's counts are its result already.
        if (!tests && finished_run(r)) {
            J moved = J::array();
            const auto report = metrics_against(r, all);
            for (const auto& m : report["metrics"]) {
                const auto verdict = str(m, "verdict");
                if ((verdict == "better" || verdict == "worse" || verdict == "changed") && moved.size() < 6) moved.push_back(m);
            }
            item["metrics"] = moved;
        }
        items.push_back(item);
    }
    for (const auto& event : timeline(root, 0, 500)) if (str(event, "kind") == "turn" && num(event, "at") >= after)
        items.push_back(J{{"kind", "turn"}, {"at", num(event, "at")}, {"label", str(event, "label")}, {"files", event.value("files", J::array())},
                          {"agent", str(event, "agent")}, {"session", str(event, "session")}, {"name", str(event, "name")}});
    std::stable_sort(items.begin(), items.end(), [](const J& a, const J& b) { return num(a, "at") > num(b, "at"); });
    const bool truncated = items.size() > 60;
    if (truncated) items.erase(items.begin() + 60, items.end());
    if (mark) {
        if (!register_root(root)) return unwritable();
        Lock lock(project_dir(root) / "seen.lock");
        auto current = json(path);
        if (lock.fd < 0) return unwritable();
        std::error_code missing;
        if ((fs::exists(path, missing) || !current.is_null()) && !current.is_object()) return unreadable("seen.json");
        if (current.is_null()) current = J::object();
        current[key] = now();
        if (!atomic(path, current.dump())) return written(false, "read position");
    }
    return J{{"ok", true}, {"root", root}, {"from", from}, {"first", from <= 0}, {"since", since_words(from)}, {"at", now()},
             {"items", items}, {"truncated", truncated}};
}
