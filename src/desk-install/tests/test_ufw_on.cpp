// Whether `ufw enable` left the firewall on (modules/ufw_on.hpp). In the test VM (2026-11-16) the install's
// pacman -Syu replaced the running kernel's modules, `ufw enable` failed, and the module still said "UFW enabled": after
// the reboot ufw-init skipped the firewall (ENABLED=no). Pure: ufw's own outputs, as it printed them there.
#include "../modules/ufw_on.hpp"

#include <cstdio>

using namespace desk_install::ufw_on;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}

int main() {
    const std::string on = "Status: active\n\nTo                         Action      From\n--                         ------      ----\n"
                           "22/tcp                     LIMIT       Anywhere\n";
    const std::string off = "Status: inactive\n";
    const std::string broken = "ERROR: problem running iptables: iptables v1.8.13 (nf_tables): Could not fetch rule set "
                               "generation id: Invalid argument\n";

    expect(after_enable(on, true) == Firewall::On && after_enable(on, false) == Firewall::On, "on when ufw says so");
    expect(after_enable(off, true) == Firewall::Off, "not on, for no known reason: off, never \"enabled\"");
    expect(after_enable(broken, true) == Firewall::Off, "iptables broken with the kernel's modules there: off");
    expect(after_enable(broken, false) == Firewall::AtNextBoot && after_enable(off, false) == Firewall::AtNextBoot,
           "the running kernel lost its modules (upgraded in this run): on at the next boot");
    expect(!active("") && !active("Status: inactive\n") && active(on), "what ufw status says");

    const std::string conf = "# /etc/ufw/ufw.conf\n#\n\n# Set to yes to start on boot. If setting this remotely, be sure "
                             "to add a rule\n# to allow your remote connection before starting ufw. Eg: 'ufw allow 22/tcp'\n"
                             "ENABLED=no\n\n# Please use the 'ufw logging' command to set the logging level\nLOGLEVEL=low\n";
    const auto set = enabled_at_boot(conf);
    expect(set && set->find("\nENABLED=yes\n") != std::string::npos && set->find("ENABLED=no") == std::string::npos,
           "ufw.conf gets ENABLED=yes");
    expect(set && set->find("LOGLEVEL=low\n") != std::string::npos && set->find("'ufw allow 22/tcp'") != std::string::npos,
           "and keeps the rest");
    expect(!enabled_at_boot(*set), "already yes: nothing to write");
    expect(!enabled_at_boot("LOGLEVEL=low\n"), "no ENABLED line: nothing written blind");
    expect(!enabled_at_boot("#ENABLED=no\n"), "a comment is not the setting");

    // Whether UFW filters IPv6 (/etc/default/ufw), so the SSH ports need IPv6 rules before it is armed for boot.
    expect(ipv6_on("# /etc/default/ufw\nIPV6=yes\nDEFAULT_INPUT_POLICY=\"DROP\"\n"), "IPV6=yes");
    expect(!ipv6_on("IPV6=no\n") && !ipv6_on("ipv6=\"NO\"\n"), "IPV6=no, in any case, quoted or not");
    expect(ipv6_on("IPV6=no\nIPV6=yes\n") && !ipv6_on("IPV6=yes\nIPV6=no\n"), "the last line wins, as in ufw");
    expect(ipv6_on("#IPV6=no\n"), "a comment is not the setting");
    expect(ipv6_on(""), "unreadable or unset: yes — a firewall left off beats an IPv6 login locked out");

    if (failures == 0) std::printf("test_ufw_on: ok\n");
    return failures == 0 ? 0 : 1;
}
