#pragma once
#include "workflow_assets.hpp"
#include "menu_upgrade.hpp"
#include "fox_aliases.hpp"
#include "../core/backup.hpp"
#include "../../desk-common/shell.hpp"
#include <openssl/sha.h>
#include <fstream>
#include <ctime>
#include <chrono>
#include <map>
#include <set>
#include <sys/stat.h>
#include <unistd.h>

namespace desk_install::workflow {
using Json = nlohmann::json;
inline std::string bytes(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), {}};
}
inline std::string digest(const std::string& data) {
    unsigned char sum[SHA256_DIGEST_LENGTH]; SHA256(reinterpret_cast<const unsigned char*>(data.data()), data.size(), sum);
    const char* hex = "0123456789abcdef"; std::string out;
    for (auto part : sum) { out += hex[part >> 4]; out += hex[part & 15]; } return out;
}
inline Json load(const fs::path& path) { const auto data = bytes(path); return Json::parse(data, nullptr, false); }
inline std::string node_hash(const fs::path& path) {
    std::error_code ec; const auto status = fs::symlink_status(path, ec);
    if (status.type() == fs::file_type::not_found) return {};
    if (ec) return "unreadable";
    if (fs::is_symlink(status)) return digest("symlink:" + fs::read_symlink(path, ec).string());
    return fs::is_regular_file(status) ? digest(bytes(path)) : "unsupported";
}
inline fs::path backup_relative(const Context& ctx, const fs::path& path) {
    const auto relative = path.lexically_relative(ctx.home);
    return !relative.empty() && *relative.begin() != ".." ? relative : fs::path("_abs" + path.string());
}
inline bool write(const fs::path& path, const std::string& data) {
    std::error_code ec; fs::create_directories(path.parent_path(), ec); if (ec) return false;
    const auto previous = fs::status(path, ec);
    const auto mode = !ec && fs::is_regular_file(previous) ? previous.permissions() : fs::perms::owner_read | fs::perms::owner_write;
    ec.clear();
    const auto temporary = path.string() + "." + std::to_string(::getpid()) + ".tmp";
    std::ofstream output(temporary, std::ios::binary); output << data; output.close();
    if (!output) { fs::remove(temporary, ec); return false; }
    fs::permissions(temporary, mode, fs::perm_options::replace, ec);
    if (ec) { fs::remove(temporary, ec); return false; }
    fs::rename(temporary, path, ec); return !ec;
}
inline fs::path state_home(const Context& ctx) {
    const auto value = std::getenv("XDG_STATE_HOME");
    return (value && *value ? fs::path(value) : ctx.home / ".local/state") / "foxml/work/integrations";
}
struct Stage {
    fs::path folder;
    std::vector<Asset> files;
    Json clients = Json::object(), plan = Json::object();
    ~Stage() { std::error_code ec; if (!folder.empty()) fs::remove_all(folder, ec); }
};
inline bool prepare(const Context& ctx, Stage& stage, std::string& error) {
    for (const char* tool : {"desk-work", "desk-drawer", "desk-install", "theme-check"}) {
        std::string ignored;
        if (!sh::capture({"make", "-q", "-C", (ctx.script_dir / "src" / tool).string(), tool}, ignored)) {
            error = "Build the current native tool before previewing: make -C " + (ctx.script_dir / "src" / tool).string(); return false;
        }
    }
    auto pattern = (fs::temp_directory_path() / "desk-integrations-XXXXXX").string();
    std::vector<char> writable(pattern.begin(), pattern.end()); writable.push_back(0);
    const char* folder = ::mkdtemp(writable.data());
    if (!folder) { error = "Could not create a staging directory"; return false; }
    stage.folder = folder;
    auto source = assets(ctx.script_dir, ctx.home, ctx.config_home);
    std::sort(source.begin(), source.end(), [](const Asset& a, const Asset& b) { return a.destination < b.destination; });
    Json source_versions = Json::array();
    for (const char* component : {"desk-work", "desk-drawer", "desk-install", "desk-common", "theme-check"}) {
        const auto directory = ctx.script_dir / "src" / component;
        for (const auto& file : fs::recursive_directory_iterator(directory)) {
            const auto rel = file.path().lexically_relative(directory);
            if (!rel.empty() && *rel.begin() == "tests") continue;
            const auto extension = file.path().extension();
            if (file.is_regular_file() && (extension == ".cpp" || extension == ".hpp" || extension == ".def" || file.path().filename() == "Makefile"))
                source_versions.push_back(Json{{"path", file.path().string()}, {"hash", digest(bytes(file.path()))}});
        }
    }
    for (const auto& asset : source) {
        std::error_code ec;
        if (!fs::is_regular_file(asset.source, ec)) { error = "Missing build or runtime asset: " + asset.source.string(); return false; }
        const auto staged = stage.folder / "files" / std::to_string(stage.files.size());
        fs::create_directories(staged.parent_path(), ec);
        fs::copy_file(asset.source, staged, fs::copy_options::overwrite_existing, ec);
        if (ec) { error = "Could not stage " + asset.source.string(); return false; }
        fs::permissions(staged, fs::status(asset.source, ec).permissions(), ec);
        stage.files.push_back({staged, asset.destination, asset.client});
        source_versions.push_back(Json{{"path", asset.source.string()}, {"hash", digest(bytes(asset.source))}});
    }
    const auto rendered = stage.folder / "rendered";
    const auto renderer = ctx.script_dir / "src/desk-render/desk-render-fast";
    source_versions.push_back(Json{{"path", ctx.palette_path.string()}, {"hash", digest(bytes(ctx.palette_path))}});
    for (const auto& directory : {ctx.templates_dir / "claude", ctx.templates_dir / "quickshell/foxml"})
        for (const auto& file : fs::recursive_directory_iterator(directory)) if (file.is_regular_file())
            source_versions.push_back(Json{{"path", file.path().string()}, {"hash", digest(bytes(file.path()))}});
    std::string render_output;
    if (!sh::capture({renderer.string(), ctx.palette_path.string(), (ctx.templates_dir / "claude").string(), (rendered / "claude").string()}, render_output)
        || !sh::capture({renderer.string(), ctx.palette_path.string(), (ctx.templates_dir / "quickshell/foxml").string(), (rendered / "desktop").string()}, render_output)) {
        error = "Integration theme rendering failed"; return false;
    }
    stage.files.push_back({rendered / "claude/mods/foxml-paper/hooks/theme.ts", ctx.home / ".claude/mods/foxml-paper/hooks/theme.ts", "notebook"});
    std::error_code ec;
    for (const auto& file : fs::directory_iterator(rendered / "desktop", ec))
        if (file.is_regular_file(ec)) stage.files.push_back({file.path(), ctx.config_home / "quickshell/foxml" / file.path().filename(), "desktop"});
    std::sort(stage.files.begin(), stage.files.end(), [](const Asset& a, const Asset& b) { return a.destination < b.destination; });
    std::map<std::string, std::string> inputs;
    for (const auto& file : stage.files) {
        if (build_stamp(file.destination)) continue;
        inputs[file.client] += file.destination.lexically_relative(ctx.home).string() + ':' + digest(bytes(file.source)) + '\n';
    }
    for (const auto& [client, data] : inputs) stage.clients[client] = digest(data);
    for (const auto& file : stage.files) {
        const auto name = file.destination.filename().string();
        const auto token = stage.clients.value(file.client, "development");
        std::string generated;
        if (name == "build.ts") generated = "export const BUILD_ID = '" + token + "'\n";
        else if (name == "build.lua") generated = "return { id = '" + token + "' }\n";
        else if (name == "Build.js") generated = ".pragma library\nvar id = '" + token + "';\n";
        if (!generated.empty() && !write(file.source, generated)) { error = "Could not stage a loaded-version stamp"; return false; }
    }
    auto shipped = load(ctx.shared_dir / "quickshell/foxml/menus.json");
    const auto menu_path = ctx.config_home / "quickshell/foxml/menus.json";
    auto menu = fs::exists(menu_path) ? load(menu_path) : shipped;
    if (!menu_upgrade::usable(menu, shipped)) { error = "The existing menu is not valid; it was left unchanged"; return false; }
    const auto record = ctx.home / ".local/state/foxml/menu-offered.json";
    const auto seen = load(record);
    std::set<std::string> offered;
    if (seen.is_array()) for (const auto& id : seen) if (id.is_string()) offered.insert(id.get<std::string>());
    bool relaid = false, sectioned = false;
    menu_upgrade::relayout(menu, shipped, offered, relaid);
    menu_upgrade::resection(menu, shipped, offered, sectioned);
    menu_upgrade::offer(menu, shipped, offered, !seen.is_array());
    const auto staged_menu = stage.folder / "menu.json", staged_record = stage.folder / "offered.json";
    if (!write(staged_menu, menu.dump(2) + '\n') || !write(staged_record, Json(offered).dump() + '\n')) return false;
    const auto menu_mode = fs::status(fs::exists(menu_path) ? menu_path : ctx.shared_dir / "quickshell/foxml/menus.json", ec).permissions();
    if (ec) { error = "Could not inspect menu permissions"; return false; }
    fs::permissions(staged_menu, menu_mode, fs::perm_options::replace, ec);
    if (ec) { error = "Could not preserve menu permissions"; return false; }
    stage.files.push_back({staged_menu, menu_path, "user-menu"});
    stage.files.push_back({staged_record, record, "user-menu"});
    // Compute aliases through the existing alias owner, inside staging; the live write uses the backup helper.
    const auto aliases = stage.folder / "aliases";
    fs::create_directories(aliases, ec);
    for (const auto& asset : stage.files) if (asset.destination.parent_path() == ctx.home / ".local/bin")
        if (!write(aliases / asset.destination.filename(), "staged target")) { error = "Could not stage alias targets"; return false; }
    for (const auto& [old_name, new_name] : kFoxAliases) {
        if (!fs::exists(aliases / new_name)) continue;
        const auto live = ctx.home / ".local/bin" / old_name;
        const auto status = fs::symlink_status(live, ec); ec.clear();
        if (fs::is_symlink(status)) fs::create_symlink(fs::read_symlink(live, ec), aliases / old_name, ec);
        else if (fs::exists(status) && !fs::is_regular_file(status)) fs::create_directory(aliases / old_name, ec);
        else if (fs::is_regular_file(status)) write(aliases / old_name, "previous tool");
        if (ec) { error = "Could not inspect a command alias"; return false; }
    }
    lay_fox_aliases(aliases, false);
    for (const auto& [old_name, new_name] : kFoxAliases)
        if (fs::is_symlink(aliases / old_name, ec) && fs::read_symlink(aliases / old_name, ec) == fs::path(new_name))
            stage.files.push_back({aliases / old_name, ctx.home / ".local/bin" / old_name, "aliases"});
    Json rows = Json::array(); std::string bundle;
    for (const auto& file : stage.files) {
        const auto after = node_hash(file.source);
        const auto after_link = fs::is_symlink(file.source) ? fs::read_symlink(file.source).string() : std::string();
        const auto before = node_hash(file.destination);
        if (before == "unsupported" || before == "unreadable") { error = "Unsupported update target: " + file.destination.string(); return false; }
        const auto mode = !after_link.empty() ? 0U : static_cast<unsigned>(fs::status(file.source).permissions()) & 0777;
        const auto before_mode = before.empty() ? 0U : static_cast<unsigned>(fs::status(file.destination, ec).permissions()) & 0777;
        const auto before_link = fs::is_symlink(fs::symlink_status(file.destination, ec)) ? fs::read_symlink(file.destination, ec).string() : std::string();
        rows.push_back(Json{{"destination", file.destination.string()}, {"client", file.client}, {"before", before}, {"beforeLink", before_link},
            {"beforeMode", before_mode}, {"after", after}, {"afterLink", after_link}, {"mode", mode}, {"changed", before != after || (after_link.empty() && before_mode != mode)}});
        bundle += file.destination.string() + ':' + after + ':' + std::to_string(mode) + '\n';
    }
    stage.plan = Json{{"version", 1}, {"repo", ctx.script_dir.string()}, {"bundle", digest(bundle)}, {"plan", digest(bundle + rows.dump())},
        {"clients", stage.clients}, {"files", rows}, {"source", source_versions}};
    return true;
}
inline Json apply(Context ctx, Stage& stage, const std::string& expected) {
    if (expected.empty() || expected != stage.plan.value("plan", "")) return Json{{"ok", false}, {"message", "Preview again: source files or installed targets changed"}};
    const auto state = state_home(ctx);
    const auto transaction = std::to_string(std::time(nullptr)) + '-' + std::to_string(::getpid()) + '-'
        + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
    const auto folder = state / "transactions" / transaction;
    ctx.backup_dir = folder / "before";
    std::error_code ec; fs::create_directories(folder, ec);
    if (ec) return Json{{"ok", false}, {"message", "Could not create the update backup"}};
    ::chmod(state.c_str(), 0700); ::chmod(folder.c_str(), 0700);
    auto manifest = stage.plan;
    manifest["transaction"] = transaction; manifest["home"] = ctx.home.string(); manifest["config"] = ctx.config_home.string();
    // Refuse the whole update before replacing anything if a preview target moved or cannot be backed up.
    for (size_t i = 0; i < stage.files.size(); ++i) {
        const auto& file = stage.files[i]; const auto& row = manifest["files"][i];
        if (node_hash(file.source) != row.value("after", "")) return Json{{"ok", false}, {"message", "A staged dependency is missing or changed; preview again"}};
        const auto actual = node_hash(file.destination);
        const auto actual_mode = actual.empty() ? 0U : static_cast<unsigned>(fs::status(file.destination, ec).permissions()) & 0777;
        if (actual != row.value("before", "") || actual_mode != row.value("beforeMode", 0U)
            || (row.value("changed", false) && !snapshot_one(ctx, file.destination)))
            return Json{{"ok", false}, {"message", "A target changed or could not be backed up: " + file.destination.string()}};
    }
    const auto previous = load(state / "current.json");
    if (!previous.is_discarded() && !write(folder / "previous-current.json", previous.dump(2))) return Json{{"ok", false}};
    if (!write(folder / "manifest.json", manifest.dump(2))) return Json{{"ok", false}};
    // Registration lands last, after dependencies and generated version stamps.
    std::vector<size_t> order;
    for (size_t i = 0; i < stage.files.size(); ++i) order.push_back(i);
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        const auto last = [&](size_t i) { const auto name = stage.files[i].destination.filename().string(); return name == "register.tsx" || name == "shell.qml"; };
        return last(a) < last(b);
    });
    for (const auto i : order) {
        if (!manifest["files"][i].value("changed", false)) continue;
        const auto& file = stage.files[i];
        const auto link = manifest["files"][i].value("afterLink", "");
        const bool deployed = link.empty() ? deploy_file_atomic(ctx, file.source, file.destination) : deploy_symlink_atomic(ctx, link, file.destination);
        if (!deployed || node_hash(file.destination) != manifest["files"][i].value("after", ""))
            return Json{{"ok", false}, {"transaction", transaction}, {"message", "Deployment stopped; use the recorded transaction to inspect and roll back"}};
    }
    if (!write(state / "current.json", manifest.dump(2))) return Json{{"ok", false}, {"transaction", transaction}};
    return Json{{"ok", true}, {"transaction", transaction}, {"bundle", stage.plan["bundle"]}, {"backup", folder.string()}};
}
inline Json rollback(const Context& ctx, const std::string& transaction) {
    if (transaction.empty() || transaction.find_first_not_of("0123456789-") != transaction.npos) return Json{{"ok", false}};
    const auto folder = state_home(ctx) / "transactions" / transaction;
    const auto manifest = load(folder / "manifest.json");
    if (!manifest.is_object() || manifest.value("home", "") != ctx.home.string() || manifest.value("config", "") != ctx.config_home.string()) return Json{{"ok", false}};
    for (const auto& row : manifest["files"]) if (row.value("changed", false)) {
        const fs::path dest = row.value("destination", "");
        const auto home_rel = dest.lexically_relative(ctx.home), config_rel = dest.lexically_relative(ctx.config_home);
        if ((home_rel.empty() || *home_rel.begin() == "..") && (config_rel.empty() || *config_rel.begin() == ".."))
            return Json{{"ok", false}, {"message", "Rollback path is outside this home and config directory"}};
        const auto actual = node_hash(dest);
        const auto before = row.value("before", "");
        if (actual != row.value("after", "") && actual != before) return Json{{"ok", false}, {"message", "A file was edited after the update; rollback left it untouched: " + dest.string()}};
        std::error_code mode_error;
        const auto mode = actual.empty() ? 0U : static_cast<unsigned>(fs::status(dest, mode_error).permissions()) & 0777;
        if (!actual.empty() && row.value(actual == before ? "beforeLink" : "afterLink", "").empty() && mode != row.value(actual == before ? "beforeMode" : "mode", 0U))
            return Json{{"ok", false}, {"message", "File permissions changed after the update; rollback left them untouched: " + dest.string()}};
        if (!before.empty() && node_hash(folder / "before" / backup_relative(ctx, dest)) != before) return Json{{"ok", false}, {"message", "A required backup is missing or changed"}};
    }
    Context restore = ctx; restore.backup_dir = folder / "rollback-backup";
    for (const auto& row : manifest["files"]) if (row.value("changed", false)) {
        const fs::path dest = row.value("destination", "");
        if (row.value("before", "").empty()) {
            if (!snapshot_one(restore, dest)) return Json{{"ok", false}};
            std::error_code ec; fs::remove(dest, ec); if (ec) return Json{{"ok", false}};
        } else if (!row.value("beforeLink", "").empty()) {
            if (!deploy_symlink_atomic(restore, row.value("beforeLink", ""), dest)) return Json{{"ok", false}};
        } else if (!deploy_file_atomic(restore, folder / "before" / backup_relative(ctx, dest), dest)) return Json{{"ok", false}};
    }
    // The restored files will be checked against their actual manifest on the next update/health check.
    const auto previous = load(folder / "previous-current.json");
    if (!write(state_home(ctx) / "current.json", previous.is_discarded() ? Json{{"version", 1}, {"rolledBack", transaction}}.dump() : previous.dump(2))) return Json{{"ok", false}};
    return Json{{"ok", true}, {"transaction", transaction}};
}
}
