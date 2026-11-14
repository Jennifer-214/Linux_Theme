#pragma once
#include "json.hpp"
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <ctime>

namespace desk_install::work_updates {
namespace fs = std::filesystem;
using Json = nlohmann::json;
inline std::string text(const Json& value, const char* key) {
    const auto field = value.find(key);
    return field != value.end() && field->is_string() ? field->get<std::string>() : std::string();
}
inline long long number(const Json& value, const char* key) {
    const auto field = value.find(key);
    return field != value.end() && field->is_number_integer() ? field->get<long long>() : 0;
}
inline bool valid_id(const std::string& id) {
    return !id.empty() && id.size() < 100 && id.find_first_not_of("0123456789-") == id.npos && id.find_first_of("0123456789") != id.npos;
}
inline bool version_record(const Json& value) {
    return value.is_object() && ((valid_id(text(value, "transaction")) && value.value("files", Json()).is_array())
        || (!value.contains("transaction") && number(value, "version") == 1 && valid_id(text(value, "rolledBack"))));
}
inline std::string bytes(const fs::path& path) {
    std::error_code ec;
    if (!fs::is_regular_file(fs::symlink_status(path, ec)) || ec || fs::file_size(path, ec) > 16 * 1024 * 1024 || ec) return {};
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), {}};
}
inline Json read(const fs::path& path) {
    auto value = Json::parse(bytes(path), nullptr, false);
    return value.is_discarded() ? Json() : value;
}
inline std::string process_stamp(long long pid) {
    if (pid <= 0) return {};
    std::ifstream input("/proc/" + std::to_string(pid) + "/stat");
    std::string line; std::getline(input, line);
    const auto end = line.rfind(')');
    if (end == line.npos) return {};
    std::istringstream fields(line.substr(end + 2)); std::string field;
    for (int index = 3; index <= 22; ++index) {
        if (!(fields >> field) || (index == 3 && (field == "Z" || field == "X"))) return {};
    }
    std::ifstream boot("/proc/sys/kernel/random/boot_id"); std::string boot_id; std::getline(boot, boot_id);
    return boot_id.empty() ? std::string() : boot_id + ':' + field;
}
inline bool unfinished(const std::string& phase) {
    return phase == "preparing" || phase == "prepared" || phase == "applying" || phase == "applied" || phase == "failed" || phase == "rolling-back";
}
inline Json inventory(const fs::path& state, bool measure = true) {
    const auto current = read(state / "current.json");
    const auto current_id = text(current, "transaction");
    std::map<std::string, Json> records, rows;
    std::error_code ec;
    const auto current_status = fs::symlink_status(state / "current.json", ec);
    bool complete = current_status.type() == fs::file_type::not_found || (!ec && fs::is_regular_file(current_status) && version_record(current));
    ec.clear();
    const auto directory = state / "transactions";
    if (fs::exists(directory, ec)) {
        fs::directory_iterator it(directory, ec), end;
        while (!ec && it != end) {
            const auto path = it->path(); const auto id = path.filename().string();
            if (valid_id(id) && fs::is_directory(it->symlink_status(ec))) {
                const auto parsed = read(path / "manifest.json");
                const auto record = parsed.is_object() ? parsed : Json::object();
                auto phase = text(record, "phase");
                const bool valid = text(record, "transaction") == id && record.value("files", Json()).is_array();
                if (!valid) phase = "unknown";
                if (valid && (phase.empty() || phase == "applied") && id == current_id) phase = "verified";
                if (phase.empty()) phase = "unknown";
                const auto owner = text(record, "process");
                const bool active = unfinished(phase) && phase != "failed" && !owner.empty() && process_stamp(number(record, "pid")) == owner;
                const bool pending = unfinished(phase);
                unsigned long long size = 0; bool scanned = true;
                fs::recursive_directory_iterator files = measure ? fs::recursive_directory_iterator(path, ec) : fs::recursive_directory_iterator(), finish;
                while (!ec && files != finish) {
                    const auto status = files->symlink_status(ec);
                    if (!ec && fs::is_regular_file(status)) { const auto count = files->file_size(ec); if (!ec) size += count; }
                    else if (!ec && fs::is_symlink(status)) size += fs::read_symlink(files->path(), ec).string().size();
                    if (!ec) files.increment(ec);
                }
                if (ec) { scanned = false; ec.clear(); }
                records[id] = record;
                rows[id] = Json{{"transaction", id}, {"phase", phase}, {"active", active}, {"interrupted", pending && !active},
                    {"pending", pending}, {"bytes", size}, {"createdAt", number(record, "createdAt")},
                    {"updatedAt", number(record, "updatedAt")}, {"scanned", scanned}, {"error", text(record, "error")}, {"protected", true}};
            }
            if (!ec) it.increment(ec);
        }
        if (ec) complete = false;
    } else if (ec) complete = false;
    std::set<std::string> protected_ids;
    const auto protect_chain = [&](std::string id) {
        std::set<std::string> seen;
        while (!id.empty()) {
            if (!valid_id(id) || !seen.insert(id).second || !records.count(id)) { complete = false; break; }
            protected_ids.insert(id);
            const auto previous = read(directory / id / "previous-current.json");
            const auto had_previous = records[id].find("hadPrevious");
            if (had_previous != records[id].end() && !had_previous->is_boolean()) { complete = false; break; }
            const auto previous_status = fs::symlink_status(directory / id / "previous-current.json", ec);
            const bool missing = previous_status.type() == fs::file_type::not_found;
            if (((had_previous != records[id].end() && had_previous->get<bool>()) || !missing)
                && (ec || !fs::is_regular_file(previous_status) || !version_record(previous))) { complete = false; ec.clear(); break; }
            ec.clear();
            id = text(previous, "transaction");
        }
    };
    protect_chain(current_id);
    for (const auto& [id, row] : rows) if (row.value("pending", false) || row.value("active", false)) protect_chain(id);
    Json transactions = Json::array(), pending = Json::array(); unsigned long long total = 0;
    for (auto& [id, row] : rows) {
        const auto phase = text(row, "phase");
        std::string reason;
        if (!complete) reason = "Rollback history needs inspection";
        else if (protected_ids.count(id)) reason = id == current_id ? "Current installed update" : "Required by rollback or recovery";
        else if (!row.value("scanned", false)) reason = "Backup could not be fully inspected";
        else if (phase != "verified" && phase != "rolled-back" && phase != "aborted") reason = "Unrecognized or unfinished transaction";
        row["protected"] = !reason.empty(); row["reason"] = reason;
        total += row.value("bytes", 0ULL);
        if (row.value("pending", false)) pending.push_back(row);
        transactions.push_back(row);
    }
    std::sort(transactions.begin(), transactions.end(), [](const Json& a, const Json& b) {
        return number(a, "createdAt") != number(b, "createdAt") ? number(a, "createdAt") > number(b, "createdAt") : text(a, "transaction") > text(b, "transaction");
    });
    return Json{{"version", 1}, {"current", current_id}, {"bytes", total}, {"measured", measure}, {"complete", complete}, {"transactions", transactions}, {"pending", pending}};
}
}
