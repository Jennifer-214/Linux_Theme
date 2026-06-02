# Security

## What FoxML is

FoxML is a personal Arch + Hyprland configuration with a defense-in-depth
security stack. It is **not** a hardened distribution, a security product,
or an audit-grade installer. It is one engineer's daily-driver setup,
made reusable. Treat the security choices here as a strong default
starting point that you can tighten or relax for your own threat model.

## Threat model the stack assumes

- A laptop used in mixed environments (home, café, conference, dorm)
- Realistic adversaries: phishing, opportunistic scanners, stolen-laptop
  attempts, lateral movement after a low-privilege compromise

## What it defends

Layered (each cheap, attacker pays full cost to bypass each):

- **Kernel**: KSPP-aligned sysctls + IOMMU + `hidepid=2` + `noexec` on
  `/tmp`+`/dev/shm` + SysRq hardening + ARP/MITM protection + OS
  fingerprint obfuscation + core-dump suppression
- **MAC**: AppArmor LSM enabled
- **Network**: UFW deny-incoming + fail2ban + DNS-over-HTTPS +
  systemd-resolved DNSSEC + optional egress lockdown + optional
  DNS sinkhole (StevenBlack blocklist)
- **Auth**: SSH keys-only on a custom port + Endlessh tarpit on :22
  + optional knock / SPA gate + fingerprint via fprintd
- **Sandbox**: Firejail Firefox + arkenfox user.js + AppArmor + opt-in
  OpenSnitch per-app egress prompts + `fox offline` network-namespace
  void for sketchy code
- **Hardware**: USBGuard allowlist + IOMMU DMA isolation + optional
  USB-tether dead-man switch
- **Honeypots**: kernel-level auditd watch + userspace inotifywait
  watch + optional Cowrie SSH honeypot
- **Watchers**: USB-while-locked alerts (bouncer), /etc drift alerts
  (etckeeper + path watcher), fail2ban → phone-alert hook with geo +
  whois enrichment

## What it does NOT defend against

- Physical access to an unlocked laptop (mitigations: aggressive idle
  lock + Bluetooth proximity lock, but none are 100%)
- Cold-boot RAM forensics on a stolen laptop (mitigations: full-disk
  encryption with a strong passphrase + immediate shutdown, both out
  of scope here)
- Adversaries with physical access during boot (Secure Boot + signed
  kernels mitigate some, but out of scope here)

## Reporting issues

Open a GitHub issue with `[security]` in the title. If the issue is a
real vulnerability (not a hardening suggestion), email the maintainer
directly first — see git log for the address.

## Secrets handling

The repo contains no secrets. Every user-private value
(webhook URLs, knock sequences, SPA keys, deadman USB serials, GPG
keys, SSH keys, passwords) is stored in `~/.config/foxml/`,
`/etc/wireguard/`, `~/.password-store/`, or `~/.ssh/` with `0600`
perms. gitleaks runs on every push as a backstop.

Back up the local secrets with:
```
fox backup
```
which produces a GPG-encrypted tarball readable only by you.

## Recovery

See `RECOVERY.md` for what to do when you lock yourself out of SSH,
the firewall, the SPA gate, or fingerprint auth.
