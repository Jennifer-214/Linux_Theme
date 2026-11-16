// Figures a job printed ("p99 412ns", "throughput: 1.2M/s", "elapsed=4.1s"), read back so a run can be set against
// the previous run of the same job. Read conservatively: a whole line has to be name/value/unit pairs with a unit this
// file knows, so a log line that merely holds a number ("Ran 12 tests in 0.4s", "line 42", "port=8080") is no metric.
// A project adds exact patterns of its own in .desk/metrics (docs/agent-workflows.md, "Run-to-run numbers").
struct MetricUnit { std::string dimension; double factor = 0; };   // factor: one of this unit in the dimension's base
// "ns", "µs", "ms", "s", "%", "/s", "ops/s", "K/s", "MB", "ns/op", "M" (a count): its dimension and size, or none.
MetricUnit metric_unit(std::string unit) {
    for (const std::string micro : {"\xc2\xb5", "\xce\xbc"}) if (unit.rfind(micro, 0) == 0) unit = "u" + unit.substr(micro.size());
    static const std::map<std::string, double> times{{"ns", 1e-9}, {"us", 1e-6}, {"ms", 1e-3}, {"s", 1}};
    if (times.count(unit)) return {"time", times.at(unit)};
    if (unit.size() > 3 && unit.compare(unit.size() - 3, 3, "/op") == 0 && times.count(unit.substr(0, unit.size() - 3)))
        return {"time", times.at(unit.substr(0, unit.size() - 3))};
    if (unit == "%") return {"percent", 1};
    static const std::map<std::string, double> bytes{{"B", 1}, {"KB", 1e3}, {"MB", 1e6}, {"GB", 1e9}, {"KiB", 1024.0}, {"MiB", 1048576.0}, {"GiB", 1073741824.0}};
    if (bytes.count(unit)) return {"bytes", bytes.at(unit)};
    if (unit.size() > 2 && unit.compare(unit.size() - 2, 2, "/s") == 0 && bytes.count(unit.substr(0, unit.size() - 2)))
        return {"rate", bytes.at(unit.substr(0, unit.size() - 2))};
    double scale = 1; std::string rest = unit;
    if (!rest.empty() && std::string("kKMG").find(rest[0]) != std::string::npos) {
        scale = rest[0] == 'M' ? 1e6 : rest[0] == 'G' ? 1e9 : 1e3; rest = rest.substr(1);
    }
    if (rest == "/s" || rest == "ops/s" || rest == "op/s") return {"rate", scale};
    if (rest.empty() && scale > 1) return {"count", scale};
    return {};
}
// Which way is better for a dimension: time lower, rates higher; anything else is only "changed".
std::string metric_better(const std::string& dimension, const std::string& name) {
    if (dimension == "time") return "lower";
    if (dimension == "rate") return "higher";
    if (name == "tests failed") return "lower";
    return "";
}
bool metric_name_char(unsigned char c) { return std::isalnum(c) || c == '_' || c == '.' || c == '-' || c == '/'; }
// One line read as metric pairs, or nothing. `[tag]` and a bullet may lead; pairs are separated by spaces, commas,
// semicolons or bars. A name=value pair with no unit is skipped (logfmt carries counters and ids); any other pair
// without a known unit, or any word that is not part of a pair, makes the line no metric at all.
std::vector<std::pair<std::string, J>> metric_line(const std::string& line) {
    std::vector<std::pair<std::string, J>> out;
    if (line.size() > 300 || line.find_first_of("0123456789") == std::string::npos) return {};
    size_t at = 0;
    const auto spaces = [&] { while (at < line.size() && (line[at] == ' ' || line[at] == '\t')) ++at; };
    spaces();
    if (at < line.size() && line[at] == '[') {
        const auto close = line.find(']', at);
        if (close == std::string::npos || close - at > 40) return {};
        at = close + 1; spaces();
    }
    if (at + 1 < line.size() && std::string("-*>").find(line[at]) != std::string::npos && line[at + 1] == ' ') { ++at; spaces(); }
    while (at < line.size()) {
        const auto start = at;
        if (!std::isalpha(static_cast<unsigned char>(line[at]))) return {};
        while (at < line.size() && metric_name_char(static_cast<unsigned char>(line[at]))) ++at;
        const auto name = line.substr(start, at - start);
        if (name.size() > 48) return {};
        char sep = ' ';
        const auto gap = at; spaces();
        if (at < line.size() && (line[at] == ':' || line[at] == '=')) { sep = line[at++]; spaces(); }
        else if (at == gap) return {};
        const auto number = at;
        if (at < line.size() && (line[at] == '-' || line[at] == '+')) ++at;
        const auto digits = at;
        while (at < line.size() && std::isdigit(static_cast<unsigned char>(line[at]))) ++at;
        if (at == digits) return {};
        if (at + 1 < line.size() && line[at] == '.' && std::isdigit(static_cast<unsigned char>(line[at + 1]))) {
            ++at; while (at < line.size() && std::isdigit(static_cast<unsigned char>(line[at]))) ++at;
        }
        const auto value = std::strtod(line.substr(number, at - number).c_str(), nullptr);
        // The unit: right after the number, or after one space. Only a known unit that ends where a pair may end counts.
        const auto ends = [&](size_t p) {
            return p >= line.size() || std::string(" \t,;|").find(line[p]) != std::string::npos
                || (p + 1 == line.size() && (line[p] == '.' || line[p] == ')'));
        };
        std::string unit;
        for (const size_t from : {at, at + 1}) {
            if (from > at && (at >= line.size() || line[at] != ' ')) break;
            size_t to = from;
            while (to < line.size() && (std::isalpha(static_cast<unsigned char>(line[to])) || line[to] == '%' || line[to] == '/'
                                        || static_cast<unsigned char>(line[to]) >= 0x80)) ++to;
            const auto candidate = line.substr(from, to - from);
            if (!candidate.empty() && ends(to) && !metric_unit(candidate).dimension.empty()) { unit = candidate; at = to; break; }
            if (from == at && !candidate.empty()) break;   // letters glued to the number that are not a unit: "3x", "12abc"
        }
        if (!ends(at)) return {};
        // A name that is itself a unit ("ns/op 38.2", "ops/s 1200") carries it.
        if (unit.empty() && !metric_unit(name).dimension.empty() && name.find('/') != std::string::npos) unit = name;
        if (!unit.empty()) out.push_back({name, J{{"name", name}, {"value", value}, {"unit", unit}, {"source", "output"}}});
        else if (sep != '=') return {};
        while (at < line.size() && std::string(" \t,;|").find(line[at]) != std::string::npos) ++at;
        if (at + 1 == line.size() && (line[at] == '.' || line[at] == ')')) ++at;
    }
    return out;
}
// A project's own patterns, from .desk/metrics: one per line, "name unit regex", the regex's first group the number
// ("-" for a plain number with no unit). Blank lines and # comments are skipped; so is a line that does not compile.
struct DeclaredMetric { std::string name, unit; std::regex pattern; };
std::vector<DeclaredMetric> declared_metrics(const std::string& root) {
    std::vector<DeclaredMetric> out;
    if (root.empty()) return out;
    for (const auto& raw : split(read(fs::path(root) / ".desk/metrics", 16 * 1024))) {
        const auto line = trim(raw);
        if (line.empty() || line[0] == '#' || out.size() >= 40) continue;
        std::istringstream fields(line); std::string name, unit;
        if (!(fields >> name >> unit)) continue;
        std::string pattern; std::getline(fields, pattern); pattern = trim(pattern);
        if (pattern.empty() || pattern.size() > 400 || name.size() > 48 || (unit != "-" && metric_unit(unit).dimension.empty())) continue;
        try { out.push_back({name, unit == "-" ? "" : unit, std::regex(pattern)}); } catch (const std::regex_error&) {}
    }
    return out;
}
// Every metric a run's output reports, in the order first seen; a name printed twice keeps its last value. Declared
// patterns read the last 5,000 lines (each up to 1,000 characters); they win over the built-in reading of the same name.
J extract_metrics(const std::string& log, const std::string& root, const J& tests = J()) {
    std::vector<std::string> order; std::map<std::string, J> found;
    const auto keep = [&](const std::string& name, J metric) { if (!found.count(name)) order.push_back(name); found[name] = std::move(metric); };
    const auto lines = split(clean(log));
    for (const auto& line : lines) for (auto& [name, metric] : metric_line(line)) if (found.size() < 200 || found.count(name)) {
        if (found.count(name) && str(found[name], "source") == "declared") continue;
        keep(name, metric);
    }
    const auto declared = declared_metrics(root);
    if (!declared.empty()) {
        for (size_t i = lines.size() > 5000 ? lines.size() - 5000 : 0; i < lines.size(); ++i) {
            if (lines[i].size() > 1000) continue;
            for (const auto& d : declared) {
                std::smatch m;
                if (!std::regex_search(lines[i], m, d.pattern) || m.size() < 2 || !m[1].matched) continue;
                const auto text = m[1].str(); char* end = nullptr;
                const auto value = std::strtod(text.c_str(), &end);
                if (text.empty() || end != text.c_str() + text.size()) continue;
                keep(d.name, J{{"name", d.name}, {"value", value}, {"unit", d.unit}, {"source", "declared"}});
            }
        }
    }
    if (tests.is_object()) for (const auto& [key, name] : {std::pair<const char*, const char*>{"passed", "tests passed"}, {"failed", "tests failed"}})
        if (tests.contains(key) && tests[key].is_number_integer() && !found.count(name))
            keep(name, J{{"name", name}, {"value", tests[key].get<long long>()}, {"unit", ""}, {"source", "tests"}});
    J out = J::array();
    for (const auto& name : order) out.push_back(found[name]);
    return out;
}
// A difference for reading: "+38", "-0.1", "+1.2e+03"; three significant figures, no trailing zeros.
std::string metric_delta(double change) {
    char text[32]{};
    std::snprintf(text, sizeof text, "%+.3g", change);
    return text;
}
// One metric set against the same name in an earlier run: change in the current unit, and better/worse when the unit
// says which way is better.
J compare_metric(J metric, const J& before) {
    const auto unit = metric_unit(str(metric, "unit"));
    const auto dimension = str(metric, "unit").empty() ? std::string("count") : unit.dimension;
    const double factor = str(metric, "unit").empty() ? 1 : unit.factor;
    metric["better"] = metric_better(dimension, str(metric, "name")).empty() ? J() : J(metric_better(dimension, str(metric, "name")));
    metric["previous"] = nullptr; metric["change"] = nullptr; metric["percent"] = nullptr; metric["delta"] = "";
    metric["verdict"] = "new";
    if (!before.is_object() || !before.contains("value") || !before["value"].is_number()) return metric;
    const auto was = metric_unit(str(before, "unit"));
    const auto was_dimension = str(before, "unit").empty() ? std::string("count") : was.dimension;
    if (was_dimension != dimension) return metric;
    const double then = before["value"].get<double>() * (str(before, "unit").empty() ? 1 : was.factor);
    const double value = metric["value"].get<double>() * factor;
    const double change = (value - then) / factor;
    metric["previous"] = then / factor;
    metric["change"] = change;
    if (then != 0) metric["percent"] = (value - then) / std::fabs(then) * 100;
    const bool same = std::fabs(value - then) <= 1e-9 * std::max(std::fabs(value), std::fabs(then));
    metric["delta"] = same ? "" : metric_delta(change);
    const auto better = str(metric, "better");
    metric["verdict"] = same ? "same" : better.empty() ? "changed"
        : (better == "lower") == (value < then) ? "better" : "worse";
    return metric;
}
bool same_job(const J& a, const J& b) {
    if (str(a, "root") != str(b, "root")) return false;
    if (command_key(a) == command_key(b)) return true;
    return !str(a, "title").empty() && str(a, "title") == str(b, "title");
}
bool finished_run(const J& r) { const auto s = str(r, "state"); return (s == "passed" || s == "failed") && num(r, "ended") > 0; }
// A run's metrics: those recorded when it finished, else (only when asked for by id) read from its log now.
J run_metrics(const J& r, bool from_log) {
    if (r.contains("metrics") && r["metrics"].is_array()) return r["metrics"];
    if (!from_log) return J::array();
    return extract_metrics(read(run_dir(str(r, "id")) / "output.log"), str(r, "root"), r.value("tests", J()));
}
// One run's metrics against the previous run of the same job; `all` is runs() for its checkout (newest first).
// Each metric's previous value comes from the newest earlier run of the job that reported that name, looking back
// at most 30 runs.
J metrics_against(const J& job, const J& all, bool from_log = false) {
    const auto mine = run_metrics(job, from_log);
    const auto started = num(job, "startedNs", num(job, "started") * 1000000000LL);
    std::vector<J> earlier;
    for (const auto& r : all) {
        if (earlier.size() >= 30) break;
        if (str(r, "id") == str(job, "id") || !finished_run(r) || !same_job(r, job)
            || num(r, "startedNs", num(r, "started") * 1000000000LL) >= started) continue;
        earlier.push_back(r);
    }
    J metrics = J::array();
    for (const auto& metric : mine) {
        J before;
        for (const auto& r : earlier) {
            for (const auto& m : run_metrics(r, false)) if (str(m, "name") == str(metric, "name")) { before = m; break; }
            if (before.is_object()) break;
        }
        metrics.push_back(compare_metric(metric, before));
    }
    J out{{"job", J{{"id", str(job, "id")}, {"title", str(job, "title")}, {"command", str(job, "command")}, {"state", str(job, "state")},
                    {"ended", num(job, "ended")}, {"testRun", job.value("testRun", false)}}},
          {"previous", earlier.empty() ? J() : J{{"id", str(earlier[0], "id")}, {"ended", num(earlier[0], "ended")}}},
          {"metrics", metrics}};
    return out;
}
// `desk-work metrics`: the named run, or the newest finished run in the checkout that reported any metric (of the
// newest 20 finished runs), against the run before it of the same job.
J metrics_report(const std::string& root, const std::string& id) {
    const auto all = runs(root);
    if (!id.empty()) {
        for (const auto& r : all) if (str(r, "id") == id) {
            auto out = metrics_against(r, all, true); out["ok"] = true; out["root"] = root; return out;
        }
        return refuse("That run is not one of this checkout's");
    }
    int looked = 0;
    for (const auto& r : all) {
        if (!finished_run(r)) continue;
        if (++looked > 20) break;
        if (run_metrics(r, false).empty()) continue;
        auto out = metrics_against(r, all); out["ok"] = true; out["root"] = root; return out;
    }
    return J{{"ok", true}, {"root", root}, {"job", nullptr}, {"previous", nullptr}, {"metrics", J::array()}};
}
