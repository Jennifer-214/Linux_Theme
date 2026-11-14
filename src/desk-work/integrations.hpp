J report_client(const std::string& client, const std::string& build, long long pid, const std::string& root, const J& fields) {
    const auto process = proc_stamp(pid);
    if (!std::regex_match(client, std::regex("[a-z][a-z0-9_-]{0,31}")) || build.size() > 80) return refuse("A client report needs a lowercase client name and a build of up to 80 characters");
    if (process.empty()) return refuse("That process is not running");
    const auto key = hash(client + ':' + std::to_string(pid) + (root.empty() ? "" : ':' + root));
    Lock lock(base() / "clients" / (key + ".lock")); if (lock.fd < 0) return unwritable();
    const auto path = base() / "clients" / (key + ".json");
    auto record = json(path);
    if (!record.is_object() || str(record, "process") != process) record = J::object();
    for (const auto& [name, value] : fields.items()) {
        if (name == "stream") {
            if (!value.is_string() || !std::set<std::string>{"starting", "connected", "retrying", "stopped", "polling"}.count(value.get<std::string>())) return refuse("A stream is starting, connected, retrying, stopped or polling");
        } else if (name == "refreshError" || name == "watchProcess") {
            if (!value.is_string() || value.get<std::string>().size() > 240) return refuse("Report text is limited to 240 characters");
        } else if (name == "eventAt" || name == "refreshAt" || name == "retryAt" || name == "watchPid") {
            if (!value.is_number_integer() || value.get<long long>() < 0 || (name != "watchPid" && value.get<long long>() > now() + 86400)) return refuse("Report times are seconds, at most a day ahead");
        } else return refuse("A client report does not keep \"" + name + "\"");
        record[name] = value;
    }
    record.update(J{{"client", client}, {"build", build}, {"root", root}, {"pid", pid}, {"process", process}, {"at", now()}});
    return written(atomic(path, record.dump()), "client report");
}
J client_loaded(const std::string& client, const std::string& build, long long pid) {
    return report_client(client, build, pid, "", J::object());
}
J live_clients() {
    J clients = J::array(); std::error_code ec;
    for (const auto& file : fs::directory_iterator(base() / "clients", ec)) {
        if (file.path().extension() != ".json") continue;
        auto record = json(file.path());
        if (!record.is_object() || str(record, "process").empty() || proc_stamp(num(record, "pid")) != str(record, "process")) continue;
        if (str(record, "stream") == "connected" && num(record, "watchPid") > 0 && proc_stamp(num(record, "watchPid")) != str(record, "watchProcess"))
            record["stream"] = "retrying";
        record["refreshState"] = !str(record, "refreshError").empty() ? "failed" : num(record, "refreshAt") > 0 ? "current" : "unverified";
        record.erase("process"); record.erase("watchProcess");
        clients.push_back(record);
    }
    return clients;
}
// How each kind of session loads installed code while keeping its work. One place, so every client says the same.
std::string reload_steps(const std::string& client, const std::string& session) {
    if (client == "notebook")
        return "In that Claude pane: /exit, then claude " + (session.empty() ? std::string("--continue") : "--resume " + session)
            + ". The conversation comes back with the new notebook.";
    if (client == "nvim")
        return "Save your files and let terminal jobs inside Neovim finish (a restart ends them), then :restart and :WorkResume "
               "to reopen your files where they were.";
    if (client == "pi") return "Type /reload in that pi session. The conversation stays.";
    if (client == "desktop") return "Run quickshell -c foxml kill, then desktop-menu --start. The drawer comes back with the new files.";
    return "Restart it to load the installed update.";
}
J integration_status(const std::string& client, const std::string& loaded, bool full = true, const std::string& session = {}) {
    const auto manifest = json(base() / "integrations/current.json");
    const auto backups = desk_install::work_updates::inventory(base() / "integrations", full);
    const auto pending = backups["pending"];
    if (!manifest.is_object() || !manifest.value("clients", J()).is_object())
        return J{{"status", pending.empty() ? "unverified" : "interrupted"}, {"message", pending.empty() ? "Integration versions have not been recorded yet" : "An unfinished update needs inspection or recovery"},
            {"pending", pending}, {"backups", backups}, {"clients", full ? live_clients() : J::array()}};
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
    auto clients = full ? live_clients() : J::array();
    for (auto& record : clients) {
        const auto token = str(record, "build"), expected = str(versions, str(record, "client").c_str());
        record["loadedStatus"] = token.empty() || token == "development" || expected.empty() ? "unverified" : token == expected ? "current" : "reload-pending";
    }
    const auto add = [&](const std::string& name, const std::string& token, long long pid, const std::string& session = {},
                         const std::string& pane = {}, const std::string& where = {}) {
        const auto expected = str(versions, name.c_str());
        const std::string status = token.empty() || token == "development" || expected.empty() ? "unverified" : token == expected ? "current" : "reload-pending";
        J row{{"client", name}, {"pid", pid}, {"loaded", token}, {"installed", expected}, {"status", status}};
        if (!session.empty()) row["session"] = session;
        if (!pane.empty()) row["pane"] = pane;
        if (!where.empty()) row["root"] = where;
        if (status == "reload-pending") row["reload"] = reload_steps(name, session);
        sessions.push_back(row);
    };
    if (full) {
        for (const auto& record : clients) {
            add(str(record, "client"), str(record, "build"), num(record, "pid"), "", "", str(record, "root"));
        }
        for (const auto& agent : agents())
            add(str(agent, "agent") == "claude" ? "notebook" : str(agent, "agent"), str(agent, "build"), num(agent, "pid"),
                str(agent, "id"), str(agent, "pane"), str(agent, "root"));
    }
    std::string state = "current", message = "Installed integrations match their recorded versions";
    const auto expected = str(versions, client.c_str());
    if (!client.empty() && (loaded.empty() || loaded == "development" || expected.empty())) { state = "unverified"; message = "This session has no verified loaded version"; }
    else if (!client.empty() && loaded != expected) { state = "reload-pending"; message = "Update installed · reload pending"; }
    if (!client.empty()) add(client, loaded, 0, session);
    if (client.empty()) {
        for (const auto& session : sessions) if (str(session, "status") == "unverified") { state = "unverified"; message = "Some sessions have not reported a verified loaded version"; }
        for (const auto& session : sessions) if (str(session, "status") == "reload-pending") { state = "reload-pending"; message = "Updates are installed; some running sessions still have older code loaded"; }
    }
    if (!source_changed.empty()) { state = "update-available"; message = "Repository changes have not been installed"; }
    if (!installed_changed.empty()) { state = "modified"; message = "Installed integration files differ from the recorded update"; }
    if (!pending.empty()) {
        const bool interrupted = std::any_of(pending.begin(), pending.end(), [](const J& item) { return item.value("interrupted", false); });
        state = interrupted ? "interrupted" : "updating";
        message = interrupted ? "An interrupted update needs recovery before another update can start" : "An integration update is still running";
    }
    return J{{"status", state}, {"message", message}, {"bundle", str(manifest, "bundle")}, {"installed", expected},
        {"loaded", loaded}, {"installedChanged", installed_changed}, {"sourceChanged", source_changed}, {"sessions", sessions},
        {"clients", clients}, {"pending", pending}, {"backups", backups}};
}
std::string health_time(long long at) {
    if (at <= 0) return "not reported";
    const std::time_t value = at; const auto local = std::localtime(&value); char text[64]{};
    if (local) std::strftime(text, sizeof(text), "%Y-%m-%d %H:%M:%S", local);
    return text;
}
J integration_health() {
    auto health = integration_status("", "", true);
    J checks = J::array(), alerts = J::array();
    if (std::set<std::string>{"modified", "update-available", "interrupted", "updating", "reload-pending"}.count(str(health, "status"))) alerts.push_back(str(health, "message"));
    checks.push_back(J{{"id", "versions"}, {"label", str(health, "message")}, {"detail", "Installed and reported loaded versions · " + str(health, "status")}});
    for (const auto& client : health.value("clients", J::array())) {
        const auto name = str(client, "client"), root = str(client, "root");
        std::string detail = "Stream: " + str(client, "stream", "not reported") + "\nLoaded: " + str(client, "loadedStatus", "unverified")
            + "\nLast event: " + health_time(num(client, "eventAt")) + "\nLast refresh: " + health_time(num(client, "refreshAt"));
        if (num(client, "retryAt") > 0) detail += "\nNext retry: " + health_time(num(client, "retryAt"));
        if (!str(client, "refreshError").empty()) detail += "\n" + str(client, "refreshError");
        if (str(client, "stream") == "retrying") alerts.push_back(name + ": live updates are reconnecting; polling may still refresh");
        if (str(client, "stream") != "stopped" && !str(client, "refreshError").empty()) alerts.push_back(name + ": " + str(client, "refreshError"));
        checks.push_back(J{{"id", name + ':' + std::to_string(num(client, "pid")) + ':' + hash(root)},
            {"label", name + (root.empty() ? "" : " · " + fs::path(root).filename().string())}, {"detail", detail}});
    }
    for (const auto& item : health.value("pending", J::array())) {
        const auto id = str(item, "transaction");
        checks.push_back(J{{"id", "update:" + id}, {"label", item.value("active", false) ? "Update still running" : "Interrupted update"},
            {"detail", str(item, "phase") + " · " + id + (str(item, "error").empty() ? "" : "\n" + str(item, "error"))},
            {"transaction", id}, {"recoverable", !item.value("active", false)}});
    }
    for (const auto& session : health.value("sessions", J::array())) if (str(session, "status") == "reload-pending") {
        const auto name = str(session, "client");
        checks.push_back(J{{"id", "reload:" + name + ':' + std::to_string(num(session, "pid"))},
            {"label", name + (str(session, "root").empty() ? "" : " · " + fs::path(str(session, "root")).filename().string()) + " runs older code"},
            {"detail", str(session, "reload")}});
    }
    const auto records = records_health();
    for (const auto& record : records["broken"]) {
        const auto root = str(record, "root");
        alerts.push_back(fs::path(root).filename().string() + ": the " + str(record, "label") + " record cannot be read");
        checks.push_back(J{{"id", "records:" + hash(root) + ':' + str(record, "file")}, {"root", root}, {"repairable", true},
            {"label", "Records · " + fs::path(root).filename().string() + " · " + str(record, "label") + " unreadable"},
            {"detail", str(record, "file") + " is " + str(record, "why") + ". Writes to it are refused until it is set aside.\n"
                       ":WorkRepair in that project previews setting it aside; the original is kept."}});
    }
    if (records["broken"].empty())
        checks.push_back(J{{"id", "records"}, {"label", "Project records"}, {"detail", "Every record in the projects on disk is readable"
            + std::string(num(records, "gone") ? "\nRecords are kept for " + std::to_string(num(records, "gone")) + " checkouts no longer on disk" : "")}});
    const auto backups = health.value("backups", J::object());
    if (!backups.value("complete", true)) {
        alerts.push_back("Rollback history needs inspection; backups are retained");
        checks.push_back(J{{"id", "backup-inspection"}, {"label", "Rollback history needs inspection"}, {"detail", "Cleanup retains every backup until the history can be fully inspected"}});
    }
    const auto bytes = backups.value("bytes", 0ULL);
    checks.push_back(J{{"id", "backups"}, {"label", "Update backups"},
        {"detail", std::to_string(backups.value("transactions", J::array()).size()) + " transactions · " + std::to_string(bytes / 1024) + " KiB\nRollback chains and unfinished updates are retained"}});
    health["checks"] = checks;
    health["alerts"] = alerts;
    return health;
}
