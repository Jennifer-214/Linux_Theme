J client_loaded(const std::string& client, const std::string& build, long long pid) {
    const auto process = proc_stamp(pid);
    if (!std::regex_match(client, std::regex("[a-z][a-z0-9_-]{0,31}")) || build.size() > 80 || process.empty()) return J{{"ok", false}};
    const auto record = J{{"client", client}, {"build", build}, {"pid", pid}, {"process", process}, {"at", now()}};
    return J{{"ok", atomic(base() / "clients" / (hash(client + ':' + std::to_string(pid)) + ".json"), record.dump())}};
}
J integration_status(const std::string& client, const std::string& loaded, bool full = true) {
    const auto manifest = json(base() / "integrations/current.json");
    if (!manifest.is_object() || !manifest.value("clients", J()).is_object())
        return J{{"status", "unverified"}, {"message", "Integration versions have not been recorded yet"}};
    J installed_changed = J::array(), source_changed = J::array(), sessions = J::array();
    if (full) {
        for (const auto& row : manifest.value("files", J::array())) {
            if (str(row, "client") == "user-menu") continue;
            std::error_code ec; const fs::path path = str(row, "destination");
            if (!str(row, "afterLink").empty()) {
                if (!fs::is_symlink(path, ec) || fs::read_symlink(path, ec).string() != str(row, "afterLink")) installed_changed.push_back(path.string());
                continue;
            }
            const auto mode = static_cast<unsigned>(fs::status(path, ec).permissions()) & 0777;
            if (ec || hash(read(path, 64 * 1024 * 1024)) != str(row, "after") || mode != row.value("mode", 0U)) installed_changed.push_back(path.string());
        }
        for (const auto& row : manifest.value("source", J::array()))
            if (hash(read(str(row, "path"), 64 * 1024 * 1024)) != str(row, "hash")) source_changed.push_back(row["path"]);
    }
    const auto versions = manifest["clients"];
    const auto add = [&](const std::string& name, const std::string& token, long long pid) {
        const auto expected = str(versions, name.c_str());
        sessions.push_back(J{{"client", name}, {"pid", pid}, {"loaded", token}, {"installed", expected},
            {"status", token.empty() || token == "development" || expected.empty() ? "unverified" : token == expected ? "current" : "reload-pending"}});
    };
    if (full) {
        std::error_code ec;
        for (const auto& file : fs::directory_iterator(base() / "clients", ec)) {
            const auto record = json(file.path());
            if (!record.is_object() || str(record, "process").empty() || proc_stamp(num(record, "pid")) != str(record, "process")) continue;
            add(str(record, "client"), str(record, "build"), num(record, "pid"));
        }
        for (const auto& agent : agents()) add(str(agent, "agent") == "claude" ? "notebook" : str(agent, "agent"), str(agent, "build"), num(agent, "pid"));
    }
    std::string state = "current", message = "Installed integrations match their recorded versions";
    const auto expected = str(versions, client.c_str());
    if (!client.empty() && (loaded.empty() || loaded == "development" || expected.empty())) { state = "unverified"; message = "This session has no verified loaded version"; }
    else if (!client.empty() && loaded != expected) { state = "reload-pending"; message = "Update installed · reload pending"; }
    if (!client.empty()) add(client, loaded, 0);
    if (client.empty()) {
        for (const auto& session : sessions) if (str(session, "status") == "unverified") { state = "unverified"; message = "Some sessions have not reported a verified loaded version"; }
        for (const auto& session : sessions) if (str(session, "status") == "reload-pending") { state = "reload-pending"; message = "Updates are installed; some running sessions still have older code loaded"; }
    }
    if (!source_changed.empty()) { state = "update-available"; message = "Repository changes have not been installed"; }
    if (!installed_changed.empty()) { state = "modified"; message = "Installed integration files differ from the recorded update"; }
    return J{{"status", state}, {"message", message}, {"bundle", str(manifest, "bundle")}, {"installed", expected},
        {"loaded", loaded}, {"installedChanged", installed_changed}, {"sourceChanged", source_changed}, {"sessions", sessions}};
}
