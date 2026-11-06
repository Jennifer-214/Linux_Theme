#include "../variants.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>

int main() {
    char pattern[] = "/tmp/fox-monitor-source-XXXXXX";
    const char* created = mkdtemp(pattern);
    if (!created) return 1;
    const std::filesystem::path dir(created);
    int failures = 0;
    auto check = [&](bool ok) { if (!ok) ++failures; };
    auto source = [&](int w, int h) {
        return fox_monitor::variants::source_for(dir, "paper.jpg", w, h);
    };
    check(source(1080, 1920) == dir / "paper.jpg");
    std::ofstream(dir / "paper_portrait.png") << "fixture";
    check(source(1080, 1920) == dir / "paper_portrait.png");
    check(source(2160, 3840) == dir / "paper_portrait.png");
    check(source(1920, 1080) == dir / "paper.jpg");
    check(source(1080, 1080) == dir / "paper.jpg");
    check(source(0, 1920) == dir / "paper.jpg");
    std::ofstream(dir / "paper_portrait.jpg") << "fixture";
    check(source(1080, 1920) == dir / "paper_portrait.jpg");
    std::filesystem::remove_all(dir);
    std::printf("test_source: %s\n", failures ? "FAILED" : "OK");
    return failures ? 1 : 0;
}
