// What a project's records hold and what still points somewhere real. Nothing here changes a record unless a repair
// that was previewed is confirmed with its token; a repair sets the original aside under a dated name, never deletes it.
std::string record_stamp() {
    char text[32]{}; const std::time_t t = now();
    if (const auto local = std::localtime(&t)) std::strftime(text, sizeof text, "%Y%m%d-%H%M%S", local);
    return text;
}
J records_report(const std::string& root) {
    std::error_code ec;
    const bool exists = fs::is_directory(root, ec);
    J out{{"root", root}, {"exists", exists}, {"records", J::array()}, {"stale", J::array()}};
    int problems = 0;
    std::set<std::string> commits; bool listed = false;
    // A commit "on a branch" is one any ref reaches. No answer from git means nothing is called stale.
    const auto on_branch = [&](const std::string& sha) {
        if (!listed) {
            for (const auto& line : split(query({"git", "--no-optional-locks", "-C", root, "rev-list", "--all"}, 5))) commits.insert(line);
            listed = true;
        }
        return commits.empty() || commits.count(sha) > 0;
    };
    for (const auto& spec : record_specs()) {
        auto state = record_state(root, spec);
        if (str(state, "state") == "unreadable") ++problems;
        out["records"].push_back(state);
        if (str(state, "state") != "ok" || !exists) continue;
        const std::string file = spec.file;
        const auto data = json(project_dir(root) / file);
        J stale = J::array(); std::string reason;
        if (file == "review-requests.json") {
            reason = "change requests for files that no longer exist";
            for (const auto& [rel, request] : data.items()) if (!fs::exists(fs::path(root) / rel, ec)) stale.push_back(rel);
        } else if (file == "reviewed.json" || file == "commit-plans.json") {
            reason = "entries for commits no branch reaches any more";
            for (const auto& [sha, value] : data.items()) if (!on_branch(sha)) stale.push_back(sha);
        }
        // Only requests are tidied: finished reviews and plans of rewritten commits are history, and harmless.
        if (!stale.empty()) out["stale"].push_back(J{{"file", file}, {"label", spec.label}, {"reason", reason},
                                                     {"entries", stale}, {"tidy", file == "review-requests.json"}});
    }
    out["problems"] = problems;
    return out;
}
J records_repair(const std::string& root, const std::string& expected) {
    const auto report = records_report(root);
    J actions = J::array(); std::string inputs;
    const auto stamp = record_stamp();
    for (const auto& state : report["records"]) if (str(state, "state") == "unreadable") {
        const auto file = str(state, "file");
        const auto aside = fs::path(file).stem().string() + ".broken-" + stamp + ".json";
        actions.push_back(J{{"kind", "set-aside"}, {"file", file}, {"to", aside},
            {"says", "Set " + file + " (" + str(state, "label") + ", " + str(state, "why") + ") aside as " + aside + "; the next write starts a fresh one"}});
        inputs += file + ':' + hash(read(project_dir(root) / file, 64 * 1024 * 1024)) + '\n';
    }
    for (const auto& stale : report["stale"]) if (stale.value("tidy", false)) {
        const auto file = str(stale, "file");
        const auto copy = fs::path(file).stem().string() + ".before-repair-" + stamp + ".json";
        const auto count = stale["entries"].size();
        actions.push_back(J{{"kind", "tidy"}, {"file", file}, {"remove", stale["entries"]}, {"copy", copy},
            {"says", "Remove " + std::to_string(count) + " " + str(stale, "reason") + " from " + file + "; the current copy is kept as " + copy}});
        inputs += file + ':' + hash(read(project_dir(root) / file)) + '\n';
    }
    // The token covers what the preview showed and the bytes it was read from, not the moment: dated names differ.
    J shown = actions;
    for (auto& action : shown) { action.erase("to"); action.erase("copy"); action.erase("says"); }
    const auto token = hash(shown.dump() + inputs);
    if (expected.empty()) return J{{"ok", true}, {"root", root}, {"actions", actions}, {"plan", token}, {"report", report}};
    if (expected != token) return refuse("The records changed since the preview; preview the repair again");
    int done = 0;
    for (const auto& action : actions) {
        const auto file = str(action, "file");
        const RecordSpec* spec = nullptr;
        for (const auto& candidate : record_specs()) if (file == candidate.file) spec = &candidate;
        if (!spec) continue;
        Lock lock(project_dir(root) / spec->lock);
        if (lock.fd < 0) return unwritable();
        const auto path = project_dir(root) / file;
        std::error_code ec;
        if (str(action, "kind") == "set-aside") {
            // A rename in the same folder keeps every original byte; the writers then start from nothing.
            fs::rename(path, project_dir(root) / (fs::path(file).stem().string() + ".broken-" + record_stamp() + ".json"), ec);
            if (ec) return refuse("Could not set " + file + " aside (" + ec.message() + "); " + std::to_string(done) + " of the repairs were made");
        } else {
            auto data = json(path);
            if (!data.is_object()) return refuse(file + " changed during the repair; preview it again");
            if (!atomic(project_dir(root) / (fs::path(file).stem().string() + ".before-repair-" + record_stamp() + ".json"), data.dump()))
                return written(false, "copy of " + file);
            for (const auto& entry : action["remove"]) data.erase(entry.get<std::string>());
            if (!atomic(path, data.dump())) return written(false, file);
        }
        ++done;
    }
    if (done) signal_change(root);
    return J{{"ok", true}, {"repaired", done}, {"message", done == 0 ? "Nothing needed repair"
        : std::to_string(done) + (done == 1 ? " repair made" : " repairs made") + "; the originals are kept beside the records"}};
}
// For work health: unreadable records in any checkout still on disk, and how many checkouts are gone.
J records_health() {
    J broken = J::array(); int gone = 0;
    for (const auto& value : known_roots()) {
        const auto root = value.get<std::string>();
        std::error_code ec;
        if (!fs::is_directory(root, ec)) { ++gone; continue; }
        for (auto state : records_brief(root)) { state["root"] = root; broken.push_back(state); }
    }
    return J{{"broken", broken}, {"gone", gone}};
}
