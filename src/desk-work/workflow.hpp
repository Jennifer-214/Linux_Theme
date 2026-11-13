J overlaps(const std::string& root, const std::string& file, const std::string& own_agent, const std::string& own_session) {
    std::error_code ec;
    const auto path = fs::weakly_canonical(fs::path(root) / file, ec);
    const auto rel = path.lexically_relative(root).string();
    J result = J::array();
    if (ec || !review_file_ok(rel)) return result;
    for (const auto& agent : agents(root)) {
        if (str(agent, "agent") == own_agent && str(agent, "id") == own_session) continue;
        const auto times = agent.value("fileTimes", J::object());
        const auto at = times.is_object() ? num(times, rel.c_str()) : 0;
        if (at <= 0 || now() - at > 900) continue;
        result.push_back(J{{"key", str(agent, "key")}, {"agent", str(agent, "agent")}, {"name", str(agent, "name")},
            {"file", rel}, {"at", at}, {"pane", str(agent, "pane")}, {"canMessage", agent.value("canMessage", false)},
            {"attribution", str(agent, "attribution", "unknown")}});
    }
    std::sort(result.begin(), result.end(), [](const J& a, const J& b) { return num(a, "at") > num(b, "at"); });
    return result;
}
J project_digest(const std::string& root, const std::string& consumer, long long through = -1) {
    auto result = digest(root, consumer, through);
    if (!result.value("ok", false)) return result;
    int passed = 0, failed = 0, ready = 0;
    for (const auto& event : result["events"]) if (str(event, "kind") == "job") {
        passed += str(event, "state") == "passed"; failed += str(event, "state") == "failed";
    }
    for (const auto& request : review_requests(root)) ready += str(request, "state") == "ready";
    std::string label;
    const auto add = [&](const std::string& text) { label += (label.empty() ? "" : " · ") + text; };
    const auto files = num(result, "files");
    if (files) add(std::to_string(files) + (files == 1 ? " observed file edited" : " observed files edited"));
    if (passed) add(std::to_string(passed) + (passed == 1 ? " run passed" : " runs passed"));
    if (failed) add(std::to_string(failed) + (failed == 1 ? " run failed" : " runs failed"));
    if (ready) add(std::to_string(ready) + (ready == 1 ? " request ready" : " requests ready"));
    if (label.empty()) label = num(result, "total") ? std::to_string(num(result, "total")) + " project events" : "No new project events";
    result["summary"] = label;
    return result;
}
J suggested_tests(const std::string& root, const std::string& file) {
    if (!review_file_ok(file)) return J::array();
    J result = J::array(); std::set<std::string> commands;
    const auto source = snapshot(root);
    const auto stem = fs::path(file).stem().string();
    for (const auto& row : runs(root)) {
        const auto cwd = str(row, "cwd");
        if (cwd.empty() || !row.value("cwdKnown", false) || root_of(cwd) != root || !row.value("testRun", false) || !commands.insert(command_key(row)).second) continue;
        std::string reason = "Previously run in this checkout; coverage of this file is not established";
        int rank = 2;
        const auto targets = test_targets(str(row, "command"), cwd);
        for (const auto& target : targets) {
            auto name = fs::path(target).stem().string();
            if ((fs::path(cwd) / target).lexically_normal() == (fs::path(root) / file).lexically_normal()) { reason = "This command ran this test file"; rank = 0; break; }
            if (name.rfind("test_", 0) == 0) name = name.substr(5);
            if (name.size() > 5 && name.substr(name.size() - 5) == "_test") name.resize(name.size() - 5);
            if (name == stem) { reason = "Test name matches this source file; coverage is inferred"; rank = 1; }
        }
        const auto counts = row.value("tests", J::object());
        for (const auto& failure : counts.value("failures", J::array()))
            if (str(failure, "filename") == (fs::path(root) / file).string()) { reason = "The captured result reported a failure in this file"; rank = 0; }
        auto run = load_run(str(row, "id")); freshness(run, source);
        result.push_back(J{{"id", str(row, "id")}, {"root", root}, {"cwd", cwd}, {"command", str(row, "command")},
            {"label", str(row, "title", str(row, "command"))}, {"reason", reason}, {"rank", rank},
            {"stale", run.value("stale", true)}, {"state", str(row, "state")},
            {"action", J{{"kind", "suggested-test"}, {"id", str(row, "id")}}}});
        if (result.size() >= 20) break;
    }
    std::stable_sort(result.begin(), result.end(), [](const J& a, const J& b) { return num(a, "rank") < num(b, "rank"); });
    if (result.size() > 5) result.erase(result.begin() + 5, result.end());
    return result;
}
J snooze(const std::string& root, const std::string& id, long long seconds, bool until_change, bool clear) {
    if (id.empty() || id.size() > 1200 || seconds < 0 || seconds > 30 * 86400 || !register_root(root)) return J{{"ok", false}};
    J item;
    for (const auto& candidate : attention(root, "", false, true)) if (str(candidate, "id") == id) { item = candidate; break; }
    if (!clear && !item.is_object()) return J{{"ok", false}, {"message", "That item is already settled"}};
    if (item.is_object()) item.erase("snoozed");
    Lock lock(project_dir(root) / "snoozed.lock");
    auto stored = json(project_dir(root) / "snoozed.json");
    if (lock.fd < 0 || (!stored.is_null() && !stored.is_object())) return J{{"ok", false}};
    if (stored.is_null()) stored = J::object();
    if (clear) stored.erase(id);
    else stored[id] = J{{"until", now() + seconds}, {"untilChange", until_change}, {"fingerprint", attention_fingerprint(root, item)}};
    return J{{"ok", atomic(project_dir(root) / "snoozed.json", stored.dump())}};
}
J workspace(const std::string& root, const std::string& client, const std::string& input) {
    if (!std::regex_match(client, std::regex("[A-Za-z0-9:_-]{1,120}"))) return J{{"ok", false}};
    const auto path = project_dir(root) / "views" / (hash(client) + ".json");
    if (input.empty()) return json(path);
    auto view = J::parse(input, nullptr, false);
    if (input.size() > 65536 || !view.is_object() || !register_root(root)) return J{{"ok", false}};
    // Views carry positions and selections, never editor contents or commands to execute on restore.
    static const std::set<std::string> keys{"version", "page", "scope", "selected", "offset", "compact", "adaptive", "request", "show", "query", "tabs", "activeTab", "branch"};
    for (const auto& [key, value] : view.items()) if (!keys.count(key)) return J{{"ok", false}};
    view["version"] = 1;
    return J{{"ok", atomic(path, view.dump())}};
}
J workspace_list(const std::string& client) {
    J result = J::array();
    for (const auto& root : known_roots()) {
        const auto view = workspace(root.get<std::string>(), client, "");
        if (view.is_object() && view.value("version", 0) == 1)
            result.push_back(J{{"root", root}, {"project", fs::path(root.get<std::string>()).filename().string()}});
    }
    return result;
}
