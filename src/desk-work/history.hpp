// Shared project history and read cursors. No client keeps a second event list.
void record_event(const std::string& root, const std::string& kind, const std::string& identity,
                  const std::string& label, J action, J extra) {
    if (root.empty() || !register_root(root)) return;
    Lock lock(project_dir(root) / "events.lock");
    if (lock.fd < 0) return;
    const auto file = project_dir(root) / "events.json";
    auto journal = json(file);
    std::error_code ec;
    if (journal.is_null() && !fs::exists(file, ec)) journal = J{{"version", 1}, {"next", 1}, {"items", J::array()}};
    if (!journal.is_object() || !journal.value("items", J()).is_array()) return;
    auto& items = journal["items"];
    const auto key = kind + ':' + identity;
    for (const auto& item : items) if (str(item, "key") == key) return;
    const auto sequence = num(journal, "next", 1);
    extra.update(J{{"id", std::to_string(sequence)}, {"seq", sequence}, {"key", key}, {"kind", kind},
                   {"root", root}, {"at", now()}, {"label", label.substr(0, 240)}, {"action", action}});
    items.push_back(extra); journal["next"] = sequence + 1;
    if (items.size() > 500) items.erase(items.begin(), items.begin() + static_cast<long>(items.size() - 500));
    atomic(file, journal.dump());
}
J timeline(const std::string& root, long long after = 0, int limit = 100) {
    const auto journal = json(project_dir(root) / "events.json");
    J result = J::array();
    if (journal.is_object() && journal.value("items", J()).is_array())
        for (auto at = journal["items"].rbegin(); at != journal["items"].rend(); ++at)
            if (num(*at, "seq") > after && result.size() < static_cast<size_t>(std::clamp(limit, 1, 500))) result.push_back(*at);
    return result;
}
J digest(const std::string& root, const std::string& consumer, long long through = -1) {
    if (!std::regex_match(consumer, std::regex("[A-Za-z0-9:_-]{1,100}"))) return refuse("A reader name uses letters, digits, : _ and -, up to 100");
    const auto path = project_dir(root) / "seen.json";
    const auto key = hash(consumer);
    if (through >= 0) {
        if (!register_root(root)) return unwritable();
        Lock lock(project_dir(root) / "seen.lock");
        auto seen = json(path);
        if (lock.fd < 0) return unwritable();
        if (!seen.is_null() && !seen.is_object()) return unreadable("seen.json");
        if (seen.is_null()) seen = J::object();
        const auto journal = json(project_dir(root) / "events.json");
        const auto latest = std::max(0LL, num(journal, "next", 1) - 1);
        if (through > latest) return J{{"ok", false}, {"message", "That event has not been recorded"}};
        seen[key] = std::max(num(seen, key.c_str()), through);
        if (!atomic(path, seen.dump())) return written(false, "read position");
    }
    const auto seen = json(path);
    const auto cursor = seen.is_object() ? num(seen, key.c_str()) : 0;
    const auto events = timeline(root, cursor, 500);
    J counts = J::object();
    std::set<std::string> files;
    long long latest = cursor;
    for (const auto& event : events) {
        const auto kind = str(event, "kind"); counts[kind] = counts.value(kind, 0) + 1;
        if (kind == "edit") files.insert(str(event, "file"));
        latest = std::max(latest, num(event, "seq"));
    }
    const auto journal = json(project_dir(root) / "events.json");
    const auto first = journal.is_object() && journal.value("items", J()).is_array() && !journal["items"].empty()
        ? num(journal["items"][0], "seq") : 0;
    return J{{"ok", true}, {"from", cursor}, {"through", latest}, {"counts", counts}, {"files", files.size()},
             {"total", events.size()}, {"truncated", first > cursor + 1}, {"events", events}};
}
std::string attention_fingerprint(const std::string& root, const J& item) {
    const auto rel = str(item, "file");
    std::string content;
    if (!rel.empty() && rel[0] != '/' && rel.find("..") == rel.npos) {
        std::error_code ec;
        const auto path = fs::weakly_canonical(fs::path(root) / rel, ec);
        const auto relative = path.lexically_relative(root);
        if (!ec && !relative.empty() && *relative.begin() != "..") content = hash(read(path));
    }
    return hash(item.dump() + content);
}
J filter_attention(const std::string& root, const J& items, bool include_snoozed) {
    const auto settings = json(project_dir(root) / "snoozed.json");
    J result = J::array();
    for (auto item : items) {
        const auto id = str(item, "id");
        const auto snooze = settings.is_object() && settings.contains(id) ? settings[id] : J();
        const bool held = snooze.is_object() && str(snooze, "fingerprint") == attention_fingerprint(root, item)
            && (snooze.value("untilChange", false) || num(snooze, "until") > now());
        if (held && !include_snoozed) continue;
        if (held) item["snoozed"] = snooze;
        result.push_back(item);
    }
    return result;
}
