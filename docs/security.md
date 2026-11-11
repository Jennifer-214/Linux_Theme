# Security tools

[← Back to FoxML](../README.md)

Configuration and commands for the workstation’s security stack. See the [threat model and reporting policy](../SECURITY.md) and [recovery guide](../RECOVERY.md).

## Installer hardening

The workstation defaults combine several modules. `--secure` configures the
kernel/userspace baseline; firewall, browser and daily audit setup also have
their own modules.

- **UFW firewall** with default-deny incoming and allowed outgoing traffic; egress filtering is opt-in through `fox sec firewall`
- **Fail2ban** brute-force protection on sshd
- **Auditd** kernel honeypot rules (`foxml_honey` tag → `fox-dispatch` phone alert)
- **USBGuard** allowlist with `fox-bouncer` alerting when blocked devices appear during screen-lock
- **AppArmor** and kernel sysctls, alongside separate `hidepid`, `no_coredumps` and makepkg-hardening modules
- **arch-audit** systemd-user timer (daily CVE surface)

Additional choices include:

| Option | Purpose |
| --- | --- |
| `--ssh-harden` | SSH wizard for a custom port, passphrase enforcement and keys-only authentication |
| `--iommu` | IOMMU DMA protection and compatible-host kernel lockdown |
| `--noexec-tmp` | `noexec`, `nosuid` and `nodev` on `/tmp` and `/dev/shm` |
| `--polkit-strict` | Require authentication for privileged GUI actions |
| `fox sec dns-shield` | Configure a StevenBlack DNS sinkhole blocklist |
| `fox sec dnssec` | Choose DNSSEC strictness |

Keyring setup also masks limited SSH/GPG `gnome-keyring-daemon` autostart units.

**The password prompt.** When something needs an administrator (a restart, a package install), the desktop asks on
a paper slip that says what is asking in plain words. `hyprpolkitagent` holds the prompt from login; the shell takes
it over once it is up and hands it back if it cannot hold it. `fox-pulse` starts `hyprpolkitagent` again whenever no
paper prompt is registered, so a prompt is always there. `FOXML_POLKIT_PROMPT=off` in the shell's environment keeps
the plain one. With `hidepid` on, the paper prompt cannot register (Quickshell looks its session up from its own
process, which needs `/proc/1`), so the shell leaves the plain one in place from the start.

## Browser hardening

`--browser-harden`, on by default, wraps Firefox in Firejail and puts arkenfox's
`user.js` in the profile selected by `profiles.ini`. The previous file is backed up.

Firefox does not read `user-overrides.js` directly. The installer appends its
overrides after arkenfox, followed by the theme's own settings. On first run, the
overrides restore the last session, keep you signed in and retain the themed new
tab and Home pages. Delete an override line to restore arkenfox's stricter setting.

## Secrets and authentication

Opt-in via dedicated flags: `--vault` (mlock-protected secret store), `--endlessh` (SSH tarpit on `:22`, real sshd moved to high port), `--mac-random` (NetworkManager randomization), `--fprint` + `--fprint-pam` (fingerprint + safe PAM splice into `system-local-login` only; sudo fingerprint authentication has its own `--sudo-fingerprint` module).

## Everyday commands

| Command | What it does |
|---|---|
| `fox sys doctor` | Config drift + posture check |
| `fox sec dashboard [--live]` | Unified security dashboard |
| `fox sec audit [--score]` | Lynis wrapper, 0-100 hardening score |
| `fox sec snitch` | Per-app outbound firewall (OpenSnitch) |
| `fox sec honey plant <dir>` | Honeytoken + auditd watch in a repo |
| `fox sec vpn [up\|down]` | WireGuard wizard with UFW kill-switch |
| `fox sec cafe` | Auto-tighten on untrusted WiFi (NetworkManager dispatcher) |

See `fox help` for the full surface and `fox sec help` for security commands.
