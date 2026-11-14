// security's edit of /etc/audit/rules.d/99-foxml.rules: the installer's block is replaced, never duplicated; every
// line another tool added (desk-honey's foxml_honey watches) stays; a re-run changes nothing; an empty or missing
// file gets just the block. The file used to be rewritten whole on every run, dropping the honey watches.
#include "../modules/audit_rules.hpp"

#include <cstdio>

using namespace desk_install::audit_rules;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}

static std::size_t count(const std::string& text, const std::string& needle) {
    std::size_t n = 0;
    for (auto at = text.find(needle); at != std::string::npos; at = text.find(needle, at + 1)) ++n;
    return n;
}

int main() {
    const std::string honey = "-w /home/u/.aws/aws_production_keys.pem -p r -k foxml_honey\n";
    const std::string legacy = std::string(kLegacyHeader) + "\n" + kWatches;

    expect(merged("") == block(), "an empty or missing file gets just the block");

    const auto from_legacy = merged(legacy + honey);
    expect(from_legacy == block() + honey, "an unmarked file: the installer's lines become the block, honey stays");
    expect(merged(from_legacy) == from_legacy, "a re-run changes nothing");

    const std::string other = "-w /etc/hosts -p wa -k hosts_changes\n";
    const std::string marked = other + block() + honey;
    expect(merged(marked) == marked, "a marked file with foreign lines on both sides stays as it is");

    const std::string old_block = std::string(kBegin) + "\n-w /etc/group -p wa -k group_changes\n" + kEnd + "\n";
    const auto replaced = merged(other + old_block + honey);
    expect(replaced == other + block() + honey, "an older block is replaced in place, not added to");
    expect(count(replaced, kBegin) == 1 && count(replaced, "passwd_changes") == 1, "one block, each watch once");

    expect(merged(honey) == honey + block(), "a file only another tool wrote gains the block after its lines");
    expect(merged(legacy + honey + honey) == block() + honey, "a repeated honey line is dropped (auditctl refuses it)");

    const std::string open = std::string(kBegin) + "\n" + kWatches + honey;
    expect(merged(open) == block() + honey, "a block with no end marker: only the installer's own lines go");

    const auto glued = merged(legacy + "-w /srv/x -p r -k foxml_honey");
    expect(glued == block() + "-w /srv/x -p r -k foxml_honey\n", "no final newline: the last line is kept whole");

    if (failures == 0) std::printf("test_audit_rules: ok\n");
    return failures == 0 ? 0 : 1;
}
