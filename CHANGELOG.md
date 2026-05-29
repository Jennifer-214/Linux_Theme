# Changelog

All notable changes to this Arch + Hyprland workstation setup.

## Unreleased

### Install-breaking failure modes: prevention at the point of mutation

An audit pass over every module that edits the bootloader, initramfs, fstab, PAM, or sudoers. The project already had good *detection* (`fox-health`) and *recovery* (`recovery_entry`, `.foxml-bak`); these add *prevention* where a module could brick or lock out a machine before either kicked in. Guiding rule: a failure halts the whole install only when it leaves the system in a state it couldn't undo — recoverable failures warn, skip the module, and let the run finish (and are reported), matching the existing warn-and-continue convention.

- **`fprint_pam` no longer reopens the documented lockout cascade.** It spliced `pam_fprintd` into `system-local-login` ahead of the included faillock/`pam_unix` block with no check on `try_first_pass` — the exact password-eating cascade `sudo_fingerprint` already guards against. It now refuses when `system-auth`'s `pam_unix` carries `try_first_pass`, mirroring `sudo_fingerprint`'s gate.
- **`nvidia` won't bake a broken initramfs.** It now skips the `mkinitcpio.conf` MODULES edit unless `modinfo nvidia` confirms the DKMS module actually built (a failed build no longer leaves a MODULES line referencing absent `.ko` files); a failed driver `pacman` warns + skips rather than editing; and if `mkinitcpio -P` fails it restores the pre-edit conf and rebuilds a known-good image, halting the install only if that recovery itself fails. The `nvidia_drm.modeset=1` cmdline arg moved ahead of the initramfs edit so it survives every early-out.
- **`noexec_tmp` validates the edited `/etc/fstab`.** After editing it runs `findmnt --verify` against a pre-edit baseline and reverts from `fstab.foxml-bak` if our change broke parsing — a malformed/duplicate `/tmp` line otherwise drops the next boot to an emergency shell. Also fixed the amend that silently no-op'd on a `/tmp` line spelled without `defaults`.
- **waybar sudoers is `visudo`-validated before install.** The `/etc/sudoers.d/99-foxml-waybar` fragment is now built from a validated username and checked with `visudo -cf` on a staged file before landing in `/etc/sudoers.d/` — a malformed fragment there breaks *every* `sudo` invocation system-wide.
- **AppArmor cmdline edits are backed up.** Each `/boot/loader/entries/*.conf` and `/etc/default/grub` gets a create-if-missing `.foxml-bak` before the kernel-cmdline `sed`, matching the PAM modules.
- **fail2ban whitelists the remote admin.** When the install is over SSH, the client's source IP is added to the sshd jail's `ignoreip`, so a fumbled password during the install can't ban you off a headless box.
- **`ssh_harden` validates before it can lock you out.** It runs `sshd -t` before restarting (a bad drop-in would otherwise take sshd down on a headless box) and runs a live `BatchMode` key self-test before offering keys-only, so a present-but-non-working key can't disable passwords into a lockout.
- **`post_install` stops defeating drift protection.** It no longer deletes `rendered/` (which is gitignored anyway) — that deletion had been making `render`'s drift detection early-out empty, so every subsequent install silently overwrote hand-edited `~/.config` files. Re-runs now warn before clobbering live edits as intended.
- **Config deploys won't clobber without a backup.** `symlinks`/`specials` refuse to overwrite a file whose backup failed, rather than replacing it with no recoverable copy.

### Frictionless + safe fingerprint chain

- **The whole fingerprint chain auto-enables when a reader is detected.** `detect` now flips on `fprint` → `fprint_pam` → `greetd_fingerprint` → `sudo_fingerprint` as an atomic, hardware-gated set: reader present → all four; absent → all four off (even under `--full`, so a box with no reader never gets `pam_fprintd` wired). Mirrors the GPU-module pattern and follows the opt-out convention for hardware-conditional modules — safety lives in each module's gates, not in default-off.
- **`fprint` now enrolls a finger during install.** A fresh machine has nothing enrolled, so every PAM-wiring module would correctly no-op and fingerprint would silently never work. `fprint` installs the daemon, then offers an interactive `fprintd-enroll` (touch prompt). Skips cleanly under `--yes`/CI. The three PAM modules were reordered to Phase 5 *after* `fprint` so the daemon + finger exist before any splice.
- **All targets stay `auth sufficient`** — fingerprint is an accelerator, never a gate. A missed/absent finger falls straight through to the password prompt at greetd, TTY login, and sudo. No `required`, no lockout.
- **`sudo_fingerprint` enrollment gate hardened against the polkit blind spot.** `fprintd-list`'s enrolled-finger listing is polkit-gated and returns `PermissionDenied` outside an active graphical session — even when a finger *is* enrolled. The gate used to read that as "none enrolled" and refuse. It now distinguishes Yes / None / Unknown and proceeds on Unknown (safe, because `sufficient` falls through to password regardless).
- Supersedes the earlier "opt-in / default-off" framing for `sudo_fingerprint` below — it's now part of the auto-enabled chain, with the same B1/B2 safety gates.

### `recovery_entry` — authenticated console fallback for systemd-boot

- **New install module** (`--recovery-entry`, default-on) that clones the default systemd-boot loader entry into an `…-recovery.conf` booting straight to `multi-user.target` — a console login, no greetd. Selectable from the boot menu, no editor needed.
- **Why:** hardened installs set `editor no` in `loader.conf` (stops a keyboard attacker appending `init=/bin/bash`). The side effect is you can't append `systemd.unit=multi-user.target` at boot either, leaving USB-rescue as the only way back into a box with a broken login PAM. This entry is the authenticated escape hatch that makes auto-wiring login/sudo fingerprint safe — reboot → pick "(recovery console)" → fix `/etc/pam.d` or `faillock --reset`.
- **Still secure:** boots to a normal login (requires credentials), never a root shell — so it does not undo what `editor no` protects against. Builds the options line in C++ (`line + " " + arg`), so it can't glue kernel params the way a hand-`sed` can.

### `battery_charge` — Li-ion charge cap

- **New install module** (`--battery`, default-on, laptop-self-gating) that installs a oneshot `battery-charge-threshold.service` setting charge start 75 / stop 80 on every battery exposing the sysfs knob, and applies it immediately. Caps wear on an always-docked laptop without a usable-reserve hit.
- **Deliberately not TLP** — TLP also drives the CPU governor / turbo / scaling and would stomp hand-tuned clock settings. This touches only the charge-threshold knobs. Self-skips on desktops / batteries without the feature.

### Hardened deploy: shell assets may not touch PAM / sudoers / bootloader

- **Removed `shared/hyprland_scripts/fingerprint_setup.sh`** — it did `sed -i '1i … pam_fprintd' /etc/pam.d/sudo` (prepend *above* the header — the canonical lockout pattern), was bulk-deployed verbatim on every install, and a `fox-fingerprint` alias in `zsh_aliases.zsh` pointed at it, shadowing the safe `shared/bin/fox-fingerprint` wrapper. Alias removed too.
- **New guard, two layers:** `specials.cpp` refuses to deploy any shell asset whose content mutates a sensitive system path (PAM / sudoers / `/boot/loader` / `/etc/default/grub` / faillock), and `tests/lint_shell_assets.sh` enforces the same at build time (runs under `make test`, so it's in CI). PAM/bootloader edits stay the exclusive job of the gated fox-install modules.
- **`fox-fingerprint` status now reports per-PAM-file truth** — it used to claim `system-local-login` "unlocks sudo" (wrong; that's TTY login) and report "(none enrolled)" when it merely couldn't read. Now shows each of sudo/greetd/login separately and distinguishes "can't read" from "none".

### `fox-install` warms sudo up front

- The bare `fox-install` binary now warms sudo once before running modules, matching what `install.sh` already does for its own invocation. Previously, running the binary directly left sudo cold and root-needing modules bailed silently (`failures: 0` but nothing applied). Non-fatal — each module still re-checks sudo itself.

### Resize / move submap on `ALT+R`

- **New Hyprland submap** for keyboard-driven manipulation of floating ("non-snapped") windows. `ALT+R` enters the mode: bare `h/j/k/l` call `resizeactive` (±40px per step), `SHIFT+h/j/k/l` call `moveactive` (±40px). `binde` repeats on hold so you can glide. `Esc` or `Enter` exits back to the default submap.
- Floating windows previously needed the mouse — `ALT+drag` to move, `ALT+right-drag` to resize were the only paths. The submap closes that gap without overloading the regular hjkl focus bindings.
- Lives in `shared/hyprland_modules/keybinds.conf` alongside the existing window-management section. `ALT+R` was the obvious mnemonic and the only single-letter `ALT` slot left free (the heavy hitters — F/B/W/V/G/P/S/hjkl — were already taken).

### `fox-wallpaper --add` — seamless image import

- **New subcommand** that imports any image into the wallpaper rotation. Upscales to 4K via Real-ESRGAN (`realesrgan-x4plus`, x4 mode → 5120×2880 → 3840×2160 Lanczos downscale) when the binary's available, falls back to ImageMagick Lanczos otherwise. Names by sanitizing the source basename or accepts an explicit `name` as the second arg. Mirrors into the repo's `shared/wallpapers/` automatically when run from inside the clone.
- **`shared/wallpapers/source/` — untouched originals are now first-class**. Every editing operation (`--add`, watermark strip, future re-upscale with a newer model) reads from `source/` and writes a separate copy into the deployable directory. The source files are never overwritten, so re-derives are always possible. `--add` stashes the input into `source/` before processing.
- **Per-monitor variants render at 2× pixel target.** Filenames still match the monitor's reported 1× resolution (so `rotate_wallpaper.sh`'s lookup keeps working), but the file holds 2× pixels — `foxml_earth_2_1920x1080.jpg` is actually 3840×2160. Compositor downsamples cleanly for 1× displays and pixel-doubles cleanly at HiDPI scale 2.0, futureproofing the wallpaper set against higher-DPI monitors. Both `personalize.cpp` (install-time) and `fox-wallpaper --add` (import-time) use this target.
- **`--add` pre-bakes per-monitor variants inline** by reading `~/.config/foxml/monitor-layout.conf` (written by `configure_monitors`). A freshly-imported wallpaper shows up on every active monitor immediately, no personalize re-run. The compositor-agnostic story (laptop wallpapers fitting docked monitors later) still holds — `personalize.cpp` / `fox-monitor-watch` re-bake variants when the active layout changes.
- **`rotate_wallpaper.sh --cycle` (the Alt+W keybind) is no longer hardcoded to four slots**. It now discovers every non-variant wallpaper in `~/.wallpapers/` and cycles through all of them, so `--add`'d wallpapers appear in the keybind rotation. The time-of-day bucket rotation (the systemd timer) still uses the 4-slot calendar.
- **`wallpaper` install module auto-installs `realesrgan-ncnn-vulkan-bin`** from the AUR so a fresh setup gets the 4K-upscale path for free. Gracefully falls back to the ImageMagick path when no AUR helper is available.
- **Two new wallpapers added** to the `foxml_earthy` family: `foxml_earth_2.jpg` (native 4K forest path) and `foxml_earth_3.jpg` (AI-upscaled sunbeam glade, 720p source → 4K via Real-ESRGAN). Watermarks stripped from the originals before commit (`wallpaperswide.com` from earth_2, `malkowitch.deviantart.com` from cave_data_center).

### `sudo_fingerprint` — opt-in fingerprint auth for sudo

- **New install module** (`--sudo-fingerprint`, default-off) that wires `pam_fprintd` into `/etc/pam.d/sudo` *safely*. Default-off because the historical lockout pattern came from this exact splice — but the actual cascade trigger (`pam_unix.so try_first_pass` consuming pam_fprintd's empty token) is closed now that the B2 fix removed `try_first_pass` from `system-auth`. Module refuses to run unless three preconditions hold:
  1. `/etc/pam.d/sudo` line 1 is the `#%PAM-1.0` header (B1's check).
  2. `system-auth`'s pam_unix has no `try_first_pass` (B2's check).
  3. `pam_fprintd` isn't already wired into sudo.
- Tagged as `risky` in the fox-install interactive prompt — gets the `[LOCKOUT RISK]` indicator alongside `fprint_pam` and `greetd_fingerprint`.

### Repo renamed back to `Linux_Theme`

- **GitHub repo renamed** from `FoxML_Workstation` → `Linux_Theme` on 2026-05-25. The "Workstation" suffix read corporate / brand-performative for a personal config repo. `fox-*` CLI binaries stay — the prefix namespaces commands away from system-tool collisions and renaming would touch every dispatch.def + Makefile + systemd unit for cosmetic gain.
- `CHANGELOG.md` preamble updated from "Fox ML theme" → "this Arch + Hyprland workstation setup" — descriptive, no brand performance.
- Documentation URLs in `foxml-health-boot.service` and `foxml-health.service` point at the renamed repo.

### `hyprpolkitagent` autostart for GUI auth prompts

- **New autostart entry** in `shared/hyprland_modules/autostart.conf` — `exec-once = systemctl --user start hyprpolkitagent`. Without an auth agent, polkit denies any action that needs interactive auth (GNOME Disks, blueman, fprintd verify, etc.) and the failures surface as silent GUI no-ops + "Authorization denied" lines in the journal.
- **`hyprpolkitagent` added to base pacman deps** so a fresh install gets the agent without a follow-up `pacman -S`.

### `sudo_fingerprint` auto-enables on hardware detection

- **Module flips from opt-in to opt-out when a fingerprint reader is present.** `fox-install`'s post-detect block already auto-enables `nvidia`/`amd_gpu`/`intel_gpu`/`fprint` when the matching hardware lands; `sudo_fingerprint` joins them. The module's existing safety gates (refuses to splice if `/etc/pam.d/sudo`'s header is missing or if `system-auth`'s pam_unix carries `try_first_pass`) mean auto-enable doesn't reopen the lockout cascade — unsafe PAM stacks still get skipped, just with auto-detection of the safe case instead of mandatory opt-in. The original `--sudo-fingerprint` opt-in flag still works.

### Installer robustness — stale-binary preflight, daemon-safe install, surfaced sudo errors

- **`fox-install` startup warns when PATH resolves to an older copy of itself.** Walks PATH for the first `fox-install`; if that binary exists, has a different inode than `/proc/self/exe`, and a different mtime, prints a warning with the path + a hint to refresh. Catches the footgun where `~/.local/bin/fox-install` (last refreshed by `make install`) drifts behind a freshly-built source-tree binary — invoking the wrong one silently uses older module logic.
- **Atomic-rename install for daemon binaries.** `src/fox-vault/Makefile` and `src/fox-pulse/Makefile` switched from `cp $(BIN) $(PREFIX)/` to `install -m 755 $(BIN) $(PREFIX)/$(BIN).new && mv ... $(BIN)`. Plain `cp` opens the destination with `O_TRUNC` which fails `ETXTBSY` against a running executable; `rename(2)` replaces the directory entry without touching the inode the daemon is still running. Without this, `make install` silently left `~/.local/bin/fox-vault` stale every time the vault daemon was up.
- **`install.sh` no longer swallows `sudo -v` stderr.** Previously `sudo -v 2>/dev/null` was hiding password-prompt failures, so when fingerprint-for-sudo wasn't wired and the user expected a fingerprint prompt that never came, the warmup just silently exited and every module then reported `sudo cache cold`. Stderr now visible, error message includes the `--sudo-fingerprint` hint.

### Waybar pending-updates pill

- **New `custom/updates` module** (`shared/waybar_scripts/updates.sh`, wired into both `shared/waybar_config` and `_secondary`). Shows pending pacman updates as a digit with a Nerd Font `󰚰` glyph. Reads the same cache `clock.sh` already maintains (`$XDG_RUNTIME_DIR/foxml-waybar/updates`) so only one process runs `checkupdates` per cycle. Cache auto-invalidates when `/var/log/pacman.log` mtime exceeds cache mtime, so a post-`pacman -Syu` refresh happens on the next poll without a system hook.
- **Severity = max(age, count).** Two orthogonal dimensions — sync-age (`pacman -Sy` recency) and pending count — each classify into a 0-3 ladder; the worse wins and drives a single class. `.calm` (blush) for fresh + empty, `.low` (green) for small backlog or mild drift, `.mid` (yellow + glow) for meaningful backlog or week-old sync, `.high` (red + glow) for large backlog or month-old sync. Same shape as the battery widget's escalation.
- **Click → rofi menu.** Replaces the old `kitty -e checkupdates | less` terminal. The menu (`shared/hyprland_scripts/updates_menu.sh`) lists every pending update as `pkg curver → newver`; Enter spawns a floating kitty popup running `sudo pacman -Syu` (window class `FoxmlUpdater`). Matches the rest of the FoxML rofi surface — `ne` zone (drops below waybar on the right), hjkl navigation, input bar hidden via `inputbar {enabled: false;}` + `-no-custom` (no typing, no free-form selection).
- **Instant pill refresh on update.** `"signal": 1` on the module + `pkill -SIGRTMIN+1 waybar` after the kitty popup closes means the count drops to its post-upgrade value the moment the upgrade finishes — no waiting for the 300s poll.

### Readability — tmux inactive panes + nvim/editor comments

Working across multiple tmux panes was forcing focus-switches just to read the non-active ones — `TMUX_INACTIVE_FG` was sitting essentially at the background color (`#3a3a3a` on dark themes), so inactive pane content blended into the wallpaper. Three rounds of tuning landed at ~70% of active luminance — clearly readable, still obviously the inactive pane:

- **FoxML_Classic** `TMUX_INACTIVE_FG` `#3a3a3a` → `#8c8070` (active `#c4b4a0`)
- **FoxML_Rose** `#3a3a3a` → `#988390` (active `#d4bcc4`)
- **Cave_Data_Center** `#3a3a4a` → `#828292` (active `#b8b8cc`)
- **FoxML_Paper** `#bcbcbc` → `#8d8d8d` (light-theme inverse — darker to gain contrast against the light background)

`COMMENT` (the palette var driving nvim's `Comment` highlight, OpenCode's `syntaxComment`, Gemini's `ui.comment`, and bat's syntax-comment color in `foxml.tmTheme`) also bumped on every theme so editor comments come up from "noise" to "muted-but-legible":

- Classic `#5a6270` → `#7a8290`
- Rose `#6a5a70` → `#8a7a90`
- Cave `#535461` → `#7a7c8a`
- Paper `#8e8e8e` → `#6e6e6e` (darker for light-theme contrast)

### Release discipline rule in `AGENT.md`

- **Codified "commits ≠ releases"** in `AGENT.md`'s Core mandates. The earlier v2.8.2 → v2.8.3 → v2.8.4 in-three-days cadence was churn for users tracking tags. Going forward, fixes accumulate on `main` as "next release" content at the top of `CHANGELOG.md`; version numbers and git tags only get assigned at explicit release moments (~every 2-4 weeks, not every PR). This entry sits under an `Unreleased` header until the next tag.

---

## 2026-05-25 — v2.9.0

### `fox sec health` — boot path + PAM stack drift detection

The retrospective incident that bit the maintainer's machine (a long-overdue `pacman -Syu` that broke wayland's ABI, swept the running kernel's module tree, and corrupted `arch.conf` — six stacked problems surfacing on the next reboot) drove a full health-check architecture. Five detection points, one check library.

- **`src/fox-health/` — `libfox-health.a`** — new library with the `CheckResult` / `CheckOptions` / `run_all` / `worst_exit` primitives, a hand-maintained registry of every check, and try/catch isolation so a misbehaving probe can't derail callers. One source of truth for all five integration points below.
- **`fox sec health` CLI** (`src/fox-sec-health/`) — manual check invocation. `--quiet` (exit-code-only for scripts), default (one-line summary), `--verbose` (detail + fix-hint per non-pass). Filter via `--only PREFIX,...` / `--exclude PREFIX,...` (e.g. `--only A,B` for boot + auth only). Exit codes: 0 ok / 1 warn / 2 critical / 3 high.
- **Phase 1 — eight critical checks** covering the categories that have actually bitten:
  - **A1** running kernel `/lib/modules/<uname>/modules.dep` present (distinguishes stale-running-kernel from genuine-partial-upgrade — fix hint differs)
  - **A2** `pacman -Qkk linux linux-lts` reports zero altered files
  - **A3** `/boot/vmlinuz-*` matches the kernel package's running version (handles `arch` / `zen` / `hardened` / `rt` / `lts` suffix conventions)
  - **A4** every kernel/initramfs/ucode in `/boot` byte-matches its ESP copy (via `bootctl --print-esp-path` + fallback probe)
  - **A7** every `/boot/loader/entries/*.conf` has exactly one `options` line with no duplicated kernel-arg keys
  - **B1** `/etc/pam.d/sudo` line 1 is `#%PAM-1.0`, not `pam_fprintd` (the recurring lockout incident's signature)
  - **B2** `pam_fprintd sufficient` does NOT precede `pam_unix try_first_pass` in any resolved PAM chain (the actual password-eaten faillock cascade — correctly handles `[success=1 default=bad]` bracketed control fields)
  - **B3** `faillock --user $USER` valid-entry count below `deny=` threshold
- **Phase 2 — fox-install preflight integration** — preflight calls `fox_health::run_all({"only": {"A","B"}})`. Category-A Critical fails (boot-path corruption) abort the install via `ctx.preflight_failed`. Category-B Critical fails (auth-stack risk) warn loudly but proceed — they're real but don't compound during a fox-install run. Slow probes (`pacman -Qkk`) skip in dry-run. Container detection (Docker / podman / systemd-nspawn / `$container` env) short-circuits boot-path checks cleanly.
- **Phase 3 — `foxml_health_hook` install module** (default-on) — sudo-installs `fox-sec-health` to `/usr/local/bin/` and writes `/etc/pacman.d/hooks/99-foxml-health.hook` triggering on Install/Upgrade/Remove of `etc/pam.d/*`, `boot/*`, `etc/fstab`, `etc/default/grub`, `etc/mkinitcpio.conf`, `etc/security/faillock.conf`. Hook runs `fox-sec-health --only A,B --no-slow` with `AbortOnFail` — Critical drifts surface inline in pacman's output, immediately after the transaction that caused them.
- **Phase 4 — `foxml_health_boot` install module** (default-on) — installs `/etc/systemd/system/foxml-health-boot.service` (Type=oneshot, Before=graphical.target) and a wrapper at `/usr/local/lib/foxml/foxml-health-boot`. Runs A-category once per boot. Output goes to BOTH the journal AND `/var/log/foxml/last-boot-health.txt` so the result is readable even when journald is unhappy. Wrapper always exits 0 — the LOG is the signal, never blocks boot.
- **Phase 6 — phone-alert escalation** — when the boot service's exit code ≥ 2 (Critical or High), the wrapper enumerates active local users via `loginctl list-users` and fires `fox-dispatch` per user (their Discord/Telegram/Pushover tokens live in `$HOME`, root can't reach them directly). Failure to dispatch is silently tolerated; the log is the authoritative signal.
- **Phase 7 — `foxml_health_timer` install module** (default-on, user-scope) — writes `~/.config/systemd/user/foxml-health.{service,timer}` and `enable --now`s the timer. `OnCalendar=daily`, `RandomizedDelaySec=30min`, `Persistent=true` (catches up if the host was off). Runs the full check set with `--verbose` so the user's journal shows fix-hints for every non-pass.

### Cross-config CI matrix (`.github/workflows/cross-config.yml`)

A regression in any boot-touching module used to silently break users on layouts other than the maintainer's. The matrix catches it at PR time.

- **Five fixtures, free CI** (public repo = unlimited GitHub-hosted minutes): `systemd-boot-separate`, `systemd-boot-merged`, `systemd-boot-xbootldr`, `grub`, `none` (rEFInd / UKI / EFISTUB equivalent). Each job synthesizes its bootloader layout in an `archlinux:latest` container, builds, runs `make test`, then `./install.sh --dry-run --full --yes` and asserts (a) exit code 0, (b) no `aborting install` / `preflight detected` / `fatal:` / `failures > 0` markers. Module-level "missing dep X" notes don't trip CI; abort-class signals do.
- **`fox-sec-health` smoke-check** — every matrix variant verifies the binary returns one of the well-known exit codes (0/1/2/3), catching crashes or signal-deaths under synthesized layouts.

### Boot-path cross-config support

- **`boot_sync` auto-detects the ESP** — `bootctl --print-esp-path` first (authoritative on systemd-boot), then probes `/efi` and `/boot/efi` via `findmnt`. Works for the legacy `/boot/efi` layout, XBOOTLDR (`/efi`), and the merged `/boot=ESP` setup. Warns loudly if the ESP path is in fstab but not currently mounted — the silent-drift mode that originally caused the kernel-on-wrong-ESP incident.
- **`iommu` no longer silently skips rEFInd / UKI / EFISTUB users** — when neither `/boot/loader/entries/arch.conf` nor `/etc/default/grub` is detected, the module prints the exact kernel args the user should add to their own boot config instead of leaving DMA protection silently disabled.
- **`preflight` partial-upgrade detection** — kernel modules tree check moved from a hand-rolled inline test to the foxml-health A1 library entry. A1 now distinguishes "stale running kernel after `pacman -Syu`" (fix: reboot) from "genuine partial upgrade, no kernel installed" (fix: reinstall + mkinitcpio -P).

### Audit-driven hardening sweep — 34 verified-real bugs

Three rounds of parallel audits + targeted self-review across every install module, `shared/bin/`, runtime Hyprland hooks, the template engine, and the user-invokable `fox-ai-*` / `fox-sec-*` leaves. False positives (~30) were filed but not fixed; everything in this section is a verified real issue.

- **`iommu.cpp` append-class bug** — `sed -i 's|^options |options <args> |'` was prepending IOMMU + lockdown kernel args on every `--full` run, accumulating duplicates in `/boot/loader/entries/arch.conf` (the user's machine had dozens of copies of `intel_iommu=on iommu=pt lockdown=integrity` stacked in the options line). Idempotency guard now applies regardless of `force_reapply`; backup is create-if-missing so a corrupted file can't clobber the true original.
- **`noexec_tmp` backup-clobber** — same backup-clobber pattern (`cp X X.foxml-bak` inside a force_reapply-bypassed guard). Same fix.
- **`fox-cafe`** — `${USER}` was baked into a NetworkManager dispatcher that runs as **root**. Refuses to run unless `$USER` matches a strict login-name regex — closes the env-poisoning privesc path.
- **`fox-ai-swap`** — `unload_model()` built a shell string with the model name from JSON config and ran `std::system()`. Switched to `fork`+`execlp`.
- **`fox-ai-bouncer`** — `argv[1]` device_id was concatenated into `sh -c "sudo usbguard list-devices | grep <id>"`. Captures the full list and filters in-process now.
- **`ssh_harden`** — `import_github_keys()` interpolated the user-typed `gh_user` straight into a `curl -fsSL https://github.com/$gh_user.keys >> ~/.ssh/authorized_keys` shell pipeline. Now validates `gh_user` against GitHub's username regex first, fetches via `sh::capture` argv, appends via `std::ofstream`.
- **`fox-vault` per-secret keystream** — was XOR'ing every secret against the same 32-byte session key (OTP-key-reuse weakness: two ciphertexts XOR'd against each other revealed `plaintext_A XOR plaintext_B`). Now each `SecureBuffer` generates a 16-byte random salt at construction and XORs against an HMAC-SHA256-derived keystream. Daemon refuses to start when both `getrandom()` and `/dev/urandom` fail (was silently running with a zeroed key). Added `prctl(PR_SET_DUMPABLE, 0)` to block coredumps + ptrace + portable `explicit_bzero` fallback for non-glibc.
- **`fox-vault` socket peer-creds** — `accept4()` didn't verify peer credentials. Adds an `SO_PEERCRED` check that rejects any peer with a different uid — defense in depth on top of the 0600 socket and per-uid runtime dir.
- **`fox-pulse` fd leaks + reconnect logging** — `inotify_add_watch` / `epoll_ctl ADD` failures left the inotify fd open, marching restart cycles toward EMFILE. Hyprland reconnect attempts silently retried forever; now logs at exponential backoff (1, 4, 16, 64…) so a wedged daemon is visible.
- **`fox-render`** — substitution `reserve()` capped at 256 MiB (was unbounded), template walk no longer follows symlinks (cycle-trap protection), `atomic_write` falls back to 0600 instead of umask defaults when `fs::status` fails.
- **`wizard.cpp` signal-safe TTY restore** — SIGINT/SIGTERM/SIGHUP during the cbreak window inside `read_key()` used to leave the terminal in raw mode. Added a `sigaction` handler that restores termios via `tcsetattr` (async-signal-safe per POSIX) before re-raising.
- **`fox-sandbox`** — `SANDBOX` was a multi-word string passed unquoted to `setsid`. Profile args with internal spaces silently broke the sandbox. Bash-array now.
- **`fox-vpn`** — `_import_url` mv'd a tempfile to `/tmp/${name}.conf` (user-typed name → predictable path → symlink race). Uses `mktemp -d` staging dir.
- **`fox-test`** — roundtrip log went to predictable `/tmp/fox-test-roundtrip.log`. `mktemp -t` with trap-on-EXIT cleanup.
- **`fox-dispatch`** — ledger trim (`tail >tmp + mv`) raced concurrent dispatch invocations and dropped entries between the tail read and the rename. `flock`-wrapped now.
- **`fprint_pam` + `ollama_hardening` /tmp TOCTOU** — predictable `/tmp/foxin-*.tmp` staging paths → `mkstemp(3)` unguessable names.
- **`specials.cpp` atomic JSON writes** — four sites (Firefox userjs, Gemini, Claude × 2) wrote settings via direct `ofstream` then renamed without checking ofstream state. A disk-full would have silently replaced a working config with empty content. Centralized `write_json_atomic()` checks stream state on close, leaves dst untouched if the write didn't complete.
- **`post_install`** — `pgrep`/`pkill`/`setsid` converted from `sh -c` string-concat to argv arrays.
- **`github`** — `ssh-keygen` calls converted to argv (was `sh -c` + concatenation).
- **`ufw`** — `server_port` from `SSH_CONNECTION` env var re-stringified from the validated int before interpolation. `stoi` accepts trailing garbage; the old form fed `22; malicious` straight into `sudo ufw limit`.
- **`xgboost`** — `cd $build_dir && cmd` replaced with `env -C $dir cmd` so the build directory name never enters shell parsing.
- **`install.sh` json.hpp fetch** — curl swallowed failures, leaving an empty/missing file and a confusing C++ build error three minutes in. Now bails loudly with a clear "re-run or drop in manually" hint.
- **`rotate_wallpaper.sh`** — `mktemp` without trap leaked the staging file on awk failure under `set -e`. Added `trap 'rm -f "$tmp"' EXIT`.
- **`Makefile` `.DEFAULT_GOAL := all`** — without it, the default goal became the first rule in the file; a preflight rule introduced higher up silently shadowed `all`, making plain `make` build nothing.

### Centralized helpers in `fox-common`

- **`sh::have(bin)`** — pure `access(X_OK)` walk of `$PATH`. Replaces the ~27-callsite `sh::capture({"sh","-c","command -v "+bin}, out)` idiom across modules, eliminating the entire shell-injection-via-`command -v` class of pattern-match-flagged bugs.
- **`sh::write_root_atomic(dst, body, mode)`** — `mkstemp` staging + `sudo install`. Replaces the ~9-callsite per-module `write_root_file` helpers that all used predictable `/tmp/foxin-*.tmp` paths.

### Template + theme fixes

- **`keybinds.conf`** — `bind = $mainMod, S, togglesplit` was rejected by Hyprland 0.55.x (`Invalid dispatcher` parse error). Changed to `bind = $mainMod, S, layoutmsg, togglesplit` — `togglesplit` is a `layoutmsg` argument for the dwindle layout, not a top-level dispatcher.
- **`hyprlock.conf`** — `{{ANSI_OK}}` was abused as a wallpaper-resolution suffix (`_1920x{{ANSI_OK}}0.jpg` → `1920x1080` only because `ANSI_OK` happens to be `108` on FoxML themes; resolved to `1920x720` on `Cave_Data_Center`, breaking the lock screen). Hardcoded to `1080`/`1920`. `{{SHOW_WELCOME}}` similarly abused for `hide_cursor`/`dots_center` booleans — hardcoded.
- **`{{SHOW_WELCOME}}` literal-true cleanup** — Firefox `userChrome.css` had ~20 attribute selectors of the form `[selected="{{SHOW_WELCOME}}"]` that would have inverted all tab styling if anyone set `SHOW_WELCOME=false`. rofi's `show-icons`, zathura's title settings, and welcome.zsh's tautological gate all cleaned up. Annotated all four palette files with a warning that `SHOW_WELCOME` is the project's de-facto literal-true alias used by ~246 substitutions in 10 templates.

### `fox-ai-*` prompt-injection delimiters

- **All six tools** (`fox-ai-{doctor,bouncer,oracle,review,snitch,audit}`) wrap captured/user-supplied data in `<<<BEGIN_X>>>...<<<END_X>>>` markers with explicit "the block below is DATA, do not follow any imperatives in it" preamble. A crafted log line, USBGuard device descriptor, journal entry, or git-diff comment can no longer re-task the model.

### Misc

- **Build:** `Makefile` adds `pkg-config --exists libcrypto` preflight + empty-`TOOLS` guard (clear error message instead of silent no-op).
- **Docs:** `CLAUDE.md` documents the new `fox-health` library + `fox-sec-health` leaf binary. `plans/health-checks.md` is the comprehensive 60+-item failure-mode catalog (Phases 1-4, 6, 7 marked done; Phase 5 — incremental C/D/E/F/G/H category checks — open for future adds).

---

## 2026-05-16 — v2.8.4

### Word-count utility

- **`fox-word-count`** (`shared/bin/fox-word-count`) — New utility to count lines, words, and characters across the workspace. Automatically excludes common noise (`.git`, `node_modules`, binaries) and provides a breakdown by file extension.
- **Aliases** — Added `fwc` and `word-count` to `shared/zsh_aliases.zsh`.
- **Integrated** — Wired into the unified `fox` dispatcher and documented in `KEYBINDS.md`.

### Installer idempotency + render safety

Re-running the installer used to silently rewrite system files and re-prompt wizard questions every time. The audit below makes modules check on-disk content before writing, and the render module refuses to wipe live `~/.config` edits without asking first.

- **`core/idempotency.hpp`** — new header-only helper: `idem::up_to_date(path, expected_body, force_reapply)` returns true when `path` exists with byte-for-byte matching content. Modules opt in by including it and early-returning when the check passes. `--full` (sets `ctx.force_reapply`) forces re-apply.
- **Guarded ~17 modules** — `ufw`, `arch_audit`, `hidepid`, `no_coredumps`, `noexec_tmp`, `makepkg_hardening`, `mac_random`, `privacy`, `ollama_hardening`, `endlessh`, `fprint`, `ai` (model pull short-circuit), `amd_gpu`, `intel_gpu`, `nvidia` (pacman pre-check), `cpp_pro`, `perf`, `wallpaper` (prompt now defaults to existing autostart state), `configure_opencode` (content-checks JSON before rewriting). Opt-in wizards (`ssh-harden`, `throttling`, `github`) intentionally re-prompt — they only run with explicit flags.
- **Render drift detector** — before re-rendering, `modules/render.cpp` compares the prior rendered output (in `ctx.rendered_dir`) against the deployed copies in `~/.config`. If any deployed file differs, it lists the drifted paths, suggests `./update.sh`, and prompts y/N. `--yes` / non-TTY aborts to protect edits; `--full` overrides.
- **`ui::skipped()`** — new dim-text helper for "already configured" lines. Re-runs now print a wall of dim `- foo already configured` lines so successful no-op installs are visually distinct from real work.
- **`--no-update` CLI flag** — surfaces the existing `FOXML_NO_UPDATE=1` env var. Skips `install.sh`'s git self-update + sudo warmup. Stripped from argv by `install.sh` and silently consumed by `fox-install` so calling either directly accepts it.
- **`fox-install` finds the repo from anywhere** — previously, running the installed binary from outside the repo set `script_dir` to `fs::current_path()`, which caused `themes/` resolution to fail. New resolution order: `$FOXML_REPO` env → walk-up from argv0 → `~/.local/share/foxml/repo-dir` marker (written by `make install`) → cwd. The marker is written automatically when `install.sh` triggers `make install`, so a fresh clone + first install still works.
- **Lean theme swap path** — `swap.sh` and `fox-theme-tweak` no longer route through `install.sh` (with its boot-space check, git self-update, sudo warmup, and full default-on module list). They exec `fox-install` directly with `--only theme,render,symlinks,specials --yes --quiet`. Falls back to `install.sh` if the native binary isn't built yet.
- **`fox swap [theme]` non-interactive** — `swap.sh` now accepts a positional theme name and skips the interactive picker; `fox swap FoxML_Classic` works from anywhere.
- **`fox tweak`** — new dispatcher verb in `shared/bin/fox` that delegates to `fox-theme-tweak`. Surfaces live aesthetic tweaks (`--primary`, `--rounding`, `--opacity`, etc.) under the unified `fox` entrypoint.
- **No stray `.foxml-bak` files** — `noexec_tmp` now only writes `/etc/fstab.foxml-bak` when it's actually about to edit fstab. Other backup callers (`fprint_pam`, `greetd_fingerprint`, `iommu`, `nvidia`) were already gated.
- **`FoxML_Rose` theme** — rose-gold + lilac on cool purple-black, softer geometry (rounding 16, blur 5/3, gaps 8/16, 1px border, opacity 0.55). Swap with `fox swap FoxML_Rose`.

---

## 2026-05-15 — v2.8.3

### Popup glass: blur + tunable transparency

- **Notification blur fixed** — mako/dunst bubbles now correctly blur their backdrop. The previous rule used the `layerrule { ... }` block form with `ignorealpha`, which Hyprland 0.54.3 silently rejects (block form only accepts `blur`/`xray`/`unset`/`noanim`/`name`/`match:*`). Rewrote `shared/hyprland_modules/rules.conf` to the keyword form: `layerrule = blur on, ignore_alpha 0.1, match:namespace ^(rofi|mako|dunst|notifications)$`. The `ignore_alpha 0.1` threshold keeps blur from leaking into the transparent margin around the bubble (mako's layer surface is larger than the visible popup).
- **`POPUP_BG_OPACITY` palette knob** — new `0.0–1.0` variable in `palette.sh` (default `0.7`) drives rofi + mako + dunst background alpha. Float → 2-char hex conversion (`{{POPUP_BG_OPACITY_HEX}}`) is derived in both `fox-render-fast` (C++) and `render.sh` (shell fallback), mirroring the existing `KITTY_BG_OPACITY_HEX` pattern.
- **`fox-theme-tweak --popup-opacity`** — wired the new knob into the live-tweak tool. `fox-theme-tweak --popup-opacity 0.55` writes the palette, re-renders templates, and reloads Hyprland. `--opacity` continues to control the terminal (`KITTY_BG_OPACITY`) only.
- **Gemini notifications match Claude** — both AI-agent notification rules in mako + dunst now use the primary peach border (`PRIMARY`) instead of the lavender accent (`ACCENT`). Notification chrome now reads as "an agent is talking to you" uniformly; `app-name` still distinguishes them in the title.
- **`INVARIANTS.md`** — extended [I-02] with the layerrule keyword-form sub-rule so the next person editing rules.conf doesn't re-step on the same parse error.

### Previously-undocumented (rolled forward from recent unreleased commits)

- **`fox-theme-tweak`** (`shared/bin/fox-theme-tweak`) — bash tool that edits the active palette in place, re-renders, and reloads. Flags: `--rounding`, `--blur-size`, `--blur-passes`, `--gap-in`, `--gap-out`, `--border-size`, `--primary`, `--secondary`, `--accent`, `--bg`, `--fg`, `--opacity`, `--popup-opacity`, `--render`.
- **Centralized aesthetic controls in palette.sh** — `ROUNDING`, `BLUR_SIZE`, `BLUR_PASSES`, `GAP_IN`, `GAP_OUT`, `BORDER_SIZE` are now palette variables (was: hardcoded across templates).
- **Unified popup borders** — 2px solid peach across rofi/mako/dunst/waybar for a consistent look.

---

## 2026-05-14 — v2.8.2

### Installation Safety & UX

- **Disk Space Verification** — Added a pre-installation check in `install.sh` and `bootstrap.sh` to ensure at least 1GB of free space on the boot partition (detects `/boot` or falls back to `/`). Includes a critical threshold (256MB) that hard-fails to prevent boot breakage during kernel/initramfs updates.
- **Improved Installer Interactivity** — Updated all major confirmation prompts (disk space check, self-update, installer selection) to use single-key input (`read -n 1`). Prompts now respond immediately to `y`, `n`, `1`, or `2` without requiring the Enter key.
- **Requirements Update** — `README.md` now explicitly lists the 1GB free space requirement for safe operation.

---

## 2026-05-13 — v2.8.1

### Orchestrator & RAG Stability

- **Command-style module execution** — `fox-install` now accepts module slugs as positional arguments. `fox install monitors` runs exactly that wizard; `fox install monitors render` runs both. Bypasses the main loop for surgical configuration.
- **Strict `--only` mode** — running a subset of modules (via `--only` or positional names) now suppresses prompts for unrelated "default-on" modules. No more `Execute module deps?` noise during a monitor re-run.
- **`--monitor` shorthand** — new dedicated flag for re-running the multi-monitor layout wizard (`--only monitors`).
- **Fixed `findex` threading race** — the RAG indexer now uses isolated `CURL` handles per thread and thread-safe global initialization. No more random segmentation faults during 8-thread parallel indexing.
- **Fixed `fox-install` progress bar crash** — `std::length_error` no longer fires if more modules are run than originally planned (happened when interactively enabling skipped steps).
- **Cleaned build warnings** — removed unused internal parser helpers in `fox-install`.

---

## 2026-05-13 — v2.8.0

### Local RAG quality pass + install hardening

- **Chunked RAG index** — `findex` now splits files into 100-line chunks with 10-line overlap (was: one whole-file embedding capped at 8 KB). A 25k-line file gets ~277 chunks instead of vanishing into a single average vector. Schema: `{path, chunk_id, line_start, line_end, vector, mtime, model}`. Embedding model name is persisted alongside each vector; re-running with a different model triggers a clean rebuild rather than mixing incompatible vector spaces.
- **Embedding model: `nomic-embed-text` → `mxbai-embed-large`** (768-d → 1024-d). Better semantic discrimination on code. Re-index required (`findex` auto-detects the model mismatch and rebuilds).
- **`fask` reads chunk line-ranges** instead of file prefixes. Top-K=8 chunks, scored. Long files no longer have their tails invisible to retrieval.
- **`findex` exclusions and extensions widened** — skips `build/ target/ dist/ node_modules/ .venv/ __pycache__/ .cache/ .cargo/ rendered/ distro/`; covers `.py .yaml .toml .rs .ts .tsx .js .sql .proto` in addition to the existing list. 2 MB per-file cap.
- **`fox-ask` (new C++ binary)** — one-shot terminal Q&A. `fox ask "<question>"` or pipe via stdin. Streams the answer using whatever model OpenCode is configured for. No index required.
- **`fox-ai-swap` unloads the previous model** via `ollama stop` after writing the new config. VRAM freed immediately instead of waiting for the 5-minute idle timer.
- **Theme-matched accent in `FoxIntel`** — reads `~/.config/foxml/ansi_colors.json` (rendered from the active palette) and uses palette `ANSI_ACCENT1` for the `[Thinking...]` banner. Falls back to hardcoded green if the JSON isn't deployed.
- **`templates/foxml/ansi_colors.json`** — new template wired into `mappings.sh` and `symlinks_data.hpp` so `fox-render` + `--symlinks` deploy it as part of any install.

### Install hardening (`fox-install`)

- **`ai` module installs aider** — AUR `aider-chat` → `pipx install aider-chat` fallback. Alongside OpenCode for a full local-model agent stack. Module description + section header updated to reflect aider inclusion.
- **`ai` module post-install smoke test** — curls `/api/tags`, then runs a real embedding query against `mxbai-embed-large`. Warns loudly on failure so broken stacks surface at install time, not when `fox-ask` silently does nothing.
- **`ai` module pulls `mxbai-embed-large`** (was: `nomic-embed-text`).
- **`models` module HF realm fix** — Ollama rejects `hf.co/...` because the manifest server redirects to `huggingface.co`. Switched to the long form so the auth realm matches. Retry hint now points at the actual attempted target.
- **`models` module dedupes embedding pull** — `mxbai-embed-large` lives in `ai` only.

### Fixes

- **`.gitignore` no longer hides `fox-ai-*` source files** — the bare `src/fox-ai-*/fox-ai-*` pattern was meant for compiled binaries but also matched `.cpp/.hpp/.h`. Added explicit negations so sources commit but binaries stay out. Same fix for `src/fox-ask/`.
- **`fox-mac` requires sudo for `nmcli connection modify`** — was failing silently when polkit didn't authorize the user.
- **`fox-ai-status` uses `jq`** for model field extraction instead of `grep | cut | tr` chains. Handles tags with provider prefixes and missing-VRAM cases without crashing.

---

## 2026-05-13 — v2.7.1

### AI Tooling & Workflow Polish

- **Enhanced Model Status Display (`fox-ai-status`)** — Improved model tag parsing to show a standardized `Family-Size` format.
- **Custom Model Discovery** — Updated the `fox-install` models module to support additional discovery paths for user-defined model lists.
- **Improved Pull Resilience** — Added a fallback mechanism for namespaced model pulls and refined library aliasing.
- **Dev Workflow Helper (`fox-tail`)** — Added a utility to consolidate local project metadata into a temporary markdown file for tool ingestion.
- **Project Maintenance** — Updated `.gitignore` to exclude local metadata files and refined tool discovery in `fox-menu`.

---

## 2026-05-13 — v2.7.0

### Unified AI Model Management & Dynamic Sync

- **Unified C++ AI Hotswapper (`fox-ai-swap`)** — A new, fast C++ utility replacing the bash-based model switcher. Features improved hardware detection (RAM/VRAM), a "Show All Models" browser, and intelligent model tag expansion.
- **Dynamic Neovim AI Integration** — Updated Neovim configuration (`init.lua`) to dynamically read the preferred AI model from `~/.config/opencode/opencode.json` on startup. CodeCompanion and Avante now stay perfectly in sync with the global system choice.
- **AI-Powered CLI Help** — Added `fox help --ai [command]` support. It identifies the source code for any tool (C++ or Bash) and uses the local AI model to provide a technical deep-dive into its logic and invariants.
- **C++ Core Synchronization** — Updated the `FoxIntel` library to prioritize global OpenCode settings, ensuring all C++ CLI tools (`fox-ai-review`, `fask`, etc.) respect the user's selected model.
- **Neovim Syntax Stability** — Fixed a Lua syntax regression in the plugin configuration to ensure reliable headless syncs and startup.
- **Network Compatibility** — Added the ability to easily toggle MAC randomization to ensure compatibility with restricted environments like dorm WiFi.

---

## 2026-05-12 — v2.6.1

### Install/CI follow-ups for v2.6.0
Patch release fixing two symlink-related regressions surfaced shortly after v2.6.0.

- **`.agent/commands/*.md` are now relative symlinks back into `shared/ai_skills/`.** Replaces the absolute symlinks the repo previously shipped — those broke on any checkout outside the original author's home path.
- **`distro/build.sh` symlink corrected to a relative path.** Matches the rest of the symlink fix.
- **`install.sh` no longer aborts when `.agent/commands/<name>.md` already resolves to its source.** The skill-deploy loop did `cp shared/ai_skills/<name>.md .agent/commands/`, but with the relative symlinks above cp errors with "same file." `install.sh` now `-ef`-checks each pair and skips the redundant copy, so the loop is a no-op on a fresh checkout and still copies if a destination has been replaced with a real file.

---

## 2026-05-12 — v2.6.0

### Security Update — Hardened SSH & Agent Protection
A cumulative security release focused on protecting local credentials and ensuring a reliable SSH environment.

- **Automated SSH Passphrase Protection:** `install.sh` now enforces passphrase protection for `~/.ssh/id_ed25519`. On new installs, it auto-generates a strong 40-char passphrase and stashes it at `~/.config/foxml/ssh-passphrase.txt` (0600) for the user to move to a manager. `fox doctor` now warns if a key is passphraseless or if the plaintext stash remains on disk.
- **SSH Agent Hijack Prevention:** Updated the installer to mask newer `gnome-keyring-daemon` systemd units (`.service` and `.socket`). This prevents "limited" systemd-started daemons from winning the race against Hyprland's full-component agent, fixing the "Error connecting to agent" issue.
- **SSH De-jailing:** Removed the restrictive Firejail wrapper from the `ssh` command. The default sandbox was isolating `ssh` from system agents and causing `Memfd` / GTK crashes during passphrase prompts. Restoring native access ensures reliable agent forwarding and stable UI prompts.
- **Enhanced Security Audits:** `fox doctor` and `fox sec` now include checks for kernel hardening sysctls, `auditd` honeypot rules, and `usbguard` status.
- **Slack Dispatch Support:** Added Slack incoming-webhook support to `fox-dispatch` for phone alerts.

---

## 2026-05-11 — v2.5.6

### `fox-doctor` diagnostic + `install.sh` treesitter parser rebuild
Two changes addressing the class of nvim breakage where a Neovim version bump leaves treesitter parsers or plugin pins in an incompatible state. Triggered by hitting `attempt to call method 'range' (a nil value)` in `languagetree.lua` on Neovim 0.12.2 with `nvim-treesitter` pinned to the archived `master` branch.

- **`install.sh` now rebuilds treesitter parsers after Lazy sync.** Added a `nvim --headless "+TSUpdateSync" "+qa"` call (120s cap) after the existing Lazy sync block. Stale `.so` parsers compiled against an older Neovim ABI produce `range`-nil errors and other latent crashes after a version bump; rebuilding them post-sync makes a parser ABI mismatch self-healing across installer runs. No-op when parsers are already fresh.
- **New `shared/bin/fox-doctor` config sanity checker.** Auto-discovered by the `fox` CLI (copied to `~/.local/bin/` via the existing `shared/bin/*` loop in `install.sh:503`, so it shows up in `fox help` with no wrapper edits). Runs `:checkhealth` headless and surfaces ERROR lines, parses `hyprctl reload` output for errors, and dry-runs `waybar -c <cfg>` to catch config breakage. Reports pass/warn/fail with exit code matching.
- **`fox-doctor --fix` for the nvim-0.12 + treesitter-master pattern.** Detects Neovim ≥0.12 with `branch = "master"` pinned in `~/.config/nvim`; if `--fix` is passed, downloads the latest 0.11.x neovim and matching 0.25.x tree-sitter from the Arch Linux Archive to `/tmp`, confirms with the user, then runs a single bundled `sudo` block: `pacman -U` for both packages plus an idempotent edit to add `neovim tree-sitter` to `IgnorePkg` in `/etc/pacman.conf` (handles "no line", "line exists missing one of the names", and "line already complete"). One fingerprint scan, fully reversible.

Why this approach over migrating to `nvim-treesitter` `main`: the legacy `master`-branch `require("nvim-treesitter.configs").setup()` block in `templates/nvim/init.lua` configures `highlight`, `incremental_selection`, `indent`, and `textobjects.{select,move,swap}` keymaps. `main` drops `incremental_selection` and `indent` entirely and requires manual keymap wiring for textobjects, so migration would lose features. Pinning Neovim to 0.11.x keeps the existing config working unchanged and is reversible.

---

## 2026-05-10 — v2.5.5

### Unified `fox` CLI & Interactive Rollback System
- **New `fox` unified command wrapper** — added a single `fox` CLI to `shared/bin/` (symlinked to `~/.local/bin/fox` on install). Replaces navigating the repo to run `./install.sh`, `./swap.sh`, and `./update.sh`. Users can now run `fox install`, `fox swap`, `fox update`, and `fox rollback` directly from any directory.
- **Interactive `fox rollback` tool** — created `shared/bin/fox-rollback` to manage the automatic backups the installer makes in `~/.theme_backups/`. It lists all backups sorted by newest first with cleanly formatted timestamps. Selecting a backup instantly restores the `.config/`, `.zshrc`, `.tmux.conf` and other backed-up files directly into the home directory, and automatically reloads Hyprland.
- Provides users with an easy "undo button" if an installation or customization breaks their setup.

---

## 2026-05-10 — v2.5.4

### `install.sh --all` now produces a fully wired AI stack on a fresh box
Closing the gaps between "AI deps installed" and "AI tools actually usable" so a single command stands up the whole stack:

- **Pro tier model pull no longer aborts the installer.** `qwen2.5-coder:70b` doesn't exist on the Ollama registry — the family tops out at 32B — so any host with >32GB RAM hit `ollama pull` failure under `set -e` and aborted mid-install after the 14B/32B pulls had already succeeded. Pro tier now pulls 14B + 32B and stops there. Lite tier label corrected (`1B` → `1.5B`) to match the actual pulled tag.
- **`~/.opencode/bin` joins PATH on shell start.** The opencode installer drops its binary at `~/.opencode/bin/opencode`, which wasn't on PATH — so the `opencode` zsh wrapper (which wakes ollama before delegating to the binary) failed with `command not found`. `shared/zsh_paths.zsh` now adds the dir conditionally on `[[ -d ]]`, so machines without opencode aren't affected. Re-deployed via the existing `SHARED_MAPPINGS` copy on every install run.
- **Claude Code TUI inherits the FoxML palette via `dark-ansi`.** Claude only exposes a small set of named themes — none of them custom — but `dark-ansi` routes the whole UI through the terminal's ANSI color slots, which `kitty.conf` already paints with the FoxML palette. `mappings.sh` now writes `theme: "dark-ansi"` on first creation and force-merges it on the re-run path (previous default was `dark`), so existing users get migrated on their next `install.sh`.

### Opencode source case in the notification triage scripts
`agent_notify.sh` and `agent_rofi.sh` got a third source case so an opencode-tagged event would render in cream (`C_WARN`) and visually distinguish from Claude (peach) and Gemini (sage) in the rofi triage list. Smoke-tested by piping the same JSON shape claude/gemini hooks pass — entries land in the queue and rofi correctly.

A matching opencode plugin to actually emit those events on `session.idle` / `permission.asked` is **pending**. The bare-function and `{ server: Plugin }` exports both load (the file is imported, confirmed via `module: evaluated` traces) but neither exported handler ever fires when the bus publishes `session.idle`. Opencode's plugin loader contract for unprefixed plugin files is more involved than the docs example suggests — likely needs explicit registration via `plugin: [...]` in opencode.json, or a different module shape. Deferred until the loader contract is figured out; the source case in the notification scripts is in place so wiring up the plugin later is a one-file change.

End result: `./install.sh --all --yes` on a fresh Arch box now installs AI deps, configures opencode to auto-route to local Ollama (already true before this release), wires Claude + Gemini notifications, themes Claude's TUI to match, and doesn't blow up on >32GB hosts.

---

## 2026-05-10 — v2.5.3

### `configure_monitors` — HiDPI scale picker per monitor
The wizard previously hardcoded scale `1` in every generated `monitor =` rule, which made 4K monitors (and especially 4K laptop panels) render text at microscopic native pixel size with no way to tell the installer "use 2x". Added a per-monitor scale prompt — `[1] 1x  [2] 1.25x  [3] 1.5x  [4] 2x` — covering both the primary monitor (asked up front, before the external loop) and each external (asked alongside position + orientation).

Implementation notes:
- **Bash has no float math, but Hyprland's coordinate system is logical.** Scale values are stored both as a decimal string (for the `monitors.conf` rule) and as `value × 100` integer (`125`, `150`, `200`) for the layout math. Logical width = `physical_w * 100 / scale_x100` — exact for the four supported steps.
- **Anchor bounds are logical, not physical.** A 4K external at 2x scale contributes a 1920×1080 logical box to its right/left/above/below neighbors, so daisy-chained mixed-DPI layouts (1080p laptop + 4K@2x sidecar + 1440p above) compose correctly with no manual coordinate math.
- **`_pick_scale` helper** routes its menu prompts to stderr and the chosen `decimal x100` pair to stdout, so it can be called via `$(...)` capture without polluting the captured value with the prompt text.
- **Defaults preserve v2.5.2 behavior.** Blank input or any non-1/2/3/4 selection falls back to `1 100` — the same scale=1 that every previous wizard run produced. Existing setups don't shift unless the user explicitly picks a non-1 scale.

---

## 2026-05-10 — v2.5.2

### `configure_monitors` — multi-anchor wizard for daisy-chained setups
The wizard previously positioned every external relative to primary, which limited it to 5 monitors max (primary + one in each cardinal direction) and broke as soon as you wanted two monitors stacked side-by-side ("right of HDMI-A-1, not right of primary"). Two externals both placed to the right would overlap at the same x coordinate.

Now each external can be anchored to **primary OR any previously-placed external**:
- Per-monitor bounds (x, y, effective width/height post-rotation) are tracked in a bash associative array as the loop iterates.
- When more than one monitor has already been placed, the wizard shows an "Anchor relative to which monitor:" sub-prompt listing every prior placement (with primary marked). Default = primary, non-numeric / out-of-range input falls back silently.
- Position math (left/right/above/below) uses the anchor's bounds instead of always primary's, so `right of HDMI-A-1 anchored at x=1920` correctly computes ext_x = 1920 + anchor_width.
- Portrait rotations contribute their post-rotation footprint (1080-wide instead of 1920-wide) to right/left neighbors automatically — the bounds tracker stores effective dimensions, not physical.

The first external still skips the anchor prompt (only choice is primary, no point asking). For typical 2-3 monitor setups the UX is unchanged from v2.5.1; only when there are 3+ monitors does the anchor selector appear.

---

## 2026-05-10 — v2.5.1

### Interactive wizards now run under `--yes` when a TTY is available
The monitor and CPU-throttling wizards were gated by `if ! $ASSUME_YES; then ... fi`, so `bootstrap.sh --full --yes` (the new default curl-bash flow) would skip them entirely and either pick mediocre defaults (right + landscape per external monitor) or skip the whole power-tuning step. Both now gate on `[[ -t 0 ]]` instead — TTY-present means prompt, no-TTY (curl-bash piped from stdin) means skip silently. So:

- A user running `./install.sh --full --yes` from a terminal gets the monitor layout picker and the throttling wizard interactively, because that's where they actually want input.
- A user piping `bootstrap.sh | bash` gets the same auto-defaults as before — `read` against EOF returns empty, the case statements' wildcard branch handles it.

### `foxml_prompt_yn` helper — defensive y/N reads
Added a shared y/N prompt helper at the top of `mappings.sh` and migrated every `read -p "...[y/N]" -n 1 -r` + `[[ ! $REPLY =~ ^[Yy]$ ]] && return` pattern in `install_throttling`, `configure_monitors`, and the SSH hardening wizard to use it. The helper:

- Returns 0 only on Y/y; **anything else (digit, word, EOF, no TTY) is treated as "no"** instead of falling through to a downstream error.
- Wraps `read` with `2>/dev/null || true` so a missing terminal (curl-bash) doesn't trip `set -e` and abort the whole installer.
- Returns 1 immediately when stdin isn't a TTY, so non-interactive runs don't hang waiting on input that'll never arrive.

This was triggered by a reported crash where entering `2` at `Cap CPU max frequency via cpupower? [y/N]` broke the installer. Defensive reads everywhere matter more than tracking down whichever individual prompt was the culprit.

### Numeric prompt validation
- **SSH custom port** — the SSH hardening wizard accepted any text as the custom port and passed it straight to `sudo ufw allow "$custom_port/tcp"`, which under `set -e` would crash the installer on a typo *and* leave SSH in a half-configured state. Now validates `^[0-9]+$` and `1 ≤ port ≤ 65535`; non-numeric or out-of-range falls back to 22 with a warning instead of erroring out.
- **CPU max frequency** — the `Cap max frequency in MHz` prompt already validated numeric input downstream, but the `read` itself had no `|| true` so an EOF stdin would crash. Added defensive guards on both the read and the validate-then-skip path.
- **CPU governor** — same defensive pattern: `read … 2>/dev/null || true`, validate against `scaling_available_governors`, skip with a clear message on no-match.

### `install_resolved_dnssec` — verify probe with retry + fallback target
The verify probe at the end of `install_resolved_dnssec` (a single `resolvectl query 2.arch.pool.ntp.org` with no retry) was persistently failing post-install, even on machines where the DNSSEC fix was correctly applied. Cause: the NetworkManager restart earlier in the function triggers a several-second reconnection window during which `resolvectl` queries can transiently fail. Now retries up to 3 times with a 2-second sleep, and falls back from the unsigned probe target (`2.arch.pool.ntp.org`, the actual fix target) to a signed sanity-check zone (`archlinux.org`) if the unsigned target keeps failing — only emits the warning if both targets fail across all retries.

---

## 2026-05-10 — v2.5.0

### `install.sh` self-update — pull origin/main and re-exec before doing any work
Added a `foxml_self_update()` step that runs before mappings.sh / render.sh are sourced and before any user prompts or sudo. It fetches `origin/main`, fast-forward-pulls if behind, and re-execs `install.sh` so the new copy (including helper functions in mappings.sh) is what actually runs. The re-exec is guarded by `FOXML_UPDATED=1` so the second invocation skips the update step instead of looping.

Skip conditions, each short-circuiting cleanly to "continue with current version":
- `FOXML_NO_UPDATE=1` in env (explicit pin / offline / dev iteration on a local-only branch)
- not inside a git work tree (someone curl-bashed it from a tarball)
- HEAD not on `main` (don't auto-update arbitrary branches a developer is testing)
- working tree dirty (don't clobber in-progress edits — caught by `git diff --quiet HEAD`)
- `git fetch` fails within a 15-second timeout (offline / GitHub down)
- pull would require a non-FF (local commits ahead of origin)

### `--full` / `--all` flag — single-flag full-fat install
`./install.sh --full` flips every opt-in module on at once: `--deps`, `--secure`, `--perf`, `--privacy`, `--vault`, `--ai`, `--models`, `--github`, `--nvidia`. `--xgboost` deliberately stays out — it's a heavy from-source build for the bundled trading models that would dominate install time for users who don't need it. Both `--full` and `--all` are accepted as the same alias.

### Auto-applied security baseline (no flag required)
Promoted from the opt-in `--secure` module to always-on, because they're pure-win on a personal Arch+Hyprland laptop and reversible-by-file-delete:

- **`install_ufw_baseline()`** — default-deny incoming, allow outgoing, conditional `allow ssh` only when `sshd` is enabled or active. Idempotent (skips when UFW is already active so a user-customized ruleset isn't reset). `ufw` moved into the always-installed pacman list so the auto-baseline actually has the binary on a default install — `fail2ban` / `audit` / `lynis` stay behind `--secure` (server-grade tools that are dead weight on a personal laptop with no public services).
- **`install_kernel_hardening()`** — drop-in at `/etc/sysctl.d/99-foxml-hardening.conf` setting `kernel.kptr_restrict=2`, `kernel.dmesg_restrict=1`, `kernel.unprivileged_bpf_disabled=1`, `kernel.yama.ptrace_scope=1`, `net.ipv4.tcp_syncookies=1`, `rp_filter=1` + `log_martians=1` on `all` and `default`, and `fs.suid_dumpable=0`. Only writes the file when its content differs from the desired value, so re-runs are quiet. Applies via `sysctl --system` immediately. Reversible by deleting the file and re-running `sudo sysctl --system`.

Both run as part of the user-environment phase between `install_gpg_agent_cache` and `install_catppuccin_cursor`. Neither needs a flag — the only way to suppress them is to delete the drop-in / disable UFW manually.

### `install_privacy()` DNSSEC fix — stop reintroducing the v2.4.7 NTP-failure mode
The `--privacy` module's DoH config was writing `DNSSEC=yes`, which directly contradicted the auto `install_resolved_dnssec` drop-in's `DNSSEC=no`. Anyone running `--privacy` would re-introduce the exact "resolvers advertise DNSSEC but return unsigned answers → systemd-resolved fails validation → chrony NTP sources never resolve → clock never syncs" failure mode that v2.4.7 was written to fix. Changed to `DNSSEC=no` for consistency with the auto-fix; DoH still encrypts the query path (which is what the privacy claim rests on), DNSSEC=yes was only adding answer-validation, which was the part that broke.

---

## 2026-05-10 — v2.4.10

### New `install_github_gpg_signing()` — generate + upload commit-signing key, end-to-end
Bootstrapping a new PC previously stopped at SSH: the installer would generate `~/.ssh/id_ed25519` and upload it to GitHub for cloning, but commit signing was a separate manual chore (generate key, configure git, upload pubkey, refresh `gh` scope). Added an end-to-end function that handles all four steps, called from `install_github_workspace` immediately after the SSH-key block.

- **Idempotent key discovery** — parses `gpg --list-secret-keys --with-colons "$email"` for a non-revoked, non-expired secret key with sign capability (`s` in field 12). Reuses an existing matching key if found; only generates when nothing usable matches the configured `git config user.email`.
- **Key shape: ed25519 sign-only, no expiry** — `gpg --quick-generate-key "Name <email>" ed25519 sign 0`. Sign-only (no encryption subkey) keeps the key minimal for its single purpose. Pinentry prompts for a passphrase during generation; the existing `install_gpg_agent_cache` TTL keeps it from re-prompting mid-session.
- **Idempotent upload** — exports armored pubkey, checks `gh gpg-key list` for the fingerprint, skips upload if already registered. Auto-refreshes `gh` auth to include `write:gpg_key` scope when missing.
- **Auto-configures git** — sets `user.signingkey` to the new fingerprint, turns on `commit.gpgsign` and `tag.gpgsign` only if those keys aren't already set (preserves power-user overrides).

### Fresh-PC bootstrap fixes uncovered by the new flow
- **`GPG_TTY` exported defensively before key generation** — install.sh runs without the user's `.zshrc`, so pinentry-curses had no way to find the controlling terminal on a fresh machine. Now exports `GPG_TTY=$(tty)` if unset before invoking `gpg --quick-generate-key`.
- **`install_gpg_agent_cache` re-invoked at the end of GPG setup** — the early `install_gpg_agent_cache` call at install.sh:559 short-circuits on a fresh PC because no signing key exists yet (its guard skips when `commit.gpgsign != true && no secret keys`). On a fresh-bootstrap machine the cache TTL would never have applied, so agent-driven commits would have re-prompted every 10 minutes. Fixed by calling `install_gpg_agent_cache` from inside `install_github_gpg_signing` after enabling `commit.gpgsign`, so the second call passes the guard and the TTL actually lands.
- **Non-TTY guard** — if stdin isn't a TTY (CI, piped-in install), skips key generation with a hint to either re-run interactively or generate manually. Avoids hanging on a passphrase prompt that has no terminal to write to.

---

## 2026-05-09 — v2.4.9

### `install_resolved_dnssec()` — restart NetworkManager to actually push cleared per-link DNSSEC
The v2.4.8 implementation cleared `connection.dnssec` on each NM connection profile but didn't restart NetworkManager, so the active links kept reporting `DNSSEC=yes/supported` to systemd-resolved. `nmcli connection modify` only touches the persistent profile — the live link inherits the new value at next connection-up. Added a `systemctl restart NetworkManager` (~3s blip, conditional on NM being active) after the modify loop so cleared values actually propagate to the running resolver state.

### New `install_clock_sync()` — bypass DNS entirely for one-shot clock correction
Chrony's normal slew mode refuses to step the clock past a small offset, so a system that's hours behind/ahead never catches up no matter how many NTP sources resolve. Added a one-shot synchronous correction that talks UDP/123 directly to Cloudflare NTP at a hardcoded IP (`162.159.200.1`), bypassing DNS, DNSSEC, and resolved entirely. Falls back to Google Public NTP (`216.239.35.0`) if Cloudflare is unreachable. Persists corrected time to the RTC via `hwclock --systohc` so a power-off doesn't undo it. Skipped when chrony isn't installed.

Wired into `install.sh` immediately after `install_resolved_dnssec` (DNS fix first so chrony's normal sync starts working again, hardcoded-IP one-shot second so a wedged clock catches up regardless).

---

## 2026-05-09 — v2.4.8

### `install_resolved_dnssec()` — diagnose and fix all three DNSSEC layers
The v2.4.7 implementation only wrote a drop-in. That's not always enough — on real machines it left DNSSEC validation failures in place because the override was being beaten by either an explicit `DNSSEC=` in the main `resolved.conf` or a NetworkManager per-connection `connection.dnssec` setting. This pass audits and fixes all three places DNSSEC can be set:

- **Main `/etc/systemd/resolved.conf`** — any active `DNSSEC=` line gets commented so the drop-in actually wins.
- **`/etc/systemd/resolved.conf.d/00-foxml-dnssec.conf`** — drop-in is written/refreshed with `DNSSEC=no` (unchanged from v2.4.7).
- **NetworkManager per-link override** — iterates every connection via `nmcli`, finds any with a non-default `connection.dnssec` value, and clears it (empty string = "inherit global"). NM's per-link DNSSEC beats the global resolved setting outright, so any `connection.dnssec=yes` would keep silent NTP failures going indefinitely regardless of what the drop-in says.

After applying, restarts `systemd-resolved`, flushes caches, then verifies by resolving `2.arch.pool.ntp.org` (a known-unsigned zone). If verification still fails, surfaces a loud warning pointing at `resolvectl status` instead of leaving DNS silently broken.

Idempotent at every step: skips main-conf edit if no DNSSEC line is active, skips drop-in write if already correct, skips NM modify if no connection has a non-default value, no-op altogether when `systemd-resolved` isn't the active resolver.

---

## 2026-05-09 — v2.4.7

### systemd-resolved DNSSEC — fix silent NTP / DNS failures
- **New `install_resolved_dnssec()` in `mappings.sh`** — drops a `[Resolve] DNSSEC=no` snippet at `/etc/systemd/resolved.conf.d/00-foxml-dnssec.conf` and restarts `systemd-resolved`. Idempotent: skips if the override is already in place; no-op when `systemd-resolved` isn't the active resolver (NM-dnsmasq, custom resolvconf, etc.).
- **Why DNSSEC=no instead of allow-downgrade** — `allow-downgrade` only relaxes when the upstream resolver explicitly signals "I don't speak DNSSEC." Many ISPs / recursive resolvers advertise DNSSEC support but return unsigned answers anyway, which `allow-downgrade` still rejects with `DNSSEC validation failed: no-signature`. The visible symptom is `chronyc sources` showing "8 sources with unknown address" forever and the system clock never syncing. `DNSSEC=no` is the only setting that actually fixes the upstream-says-yes-but-returns-unsigned case.
- **Wired into `install.sh`** between `install_specials` and `install_gpg_agent_cache` (user-environment phase, runs once near install start so it's in effect before any later step that resolves names).
- **Drop-in pattern** — uses `/etc/systemd/resolved.conf.d/` rather than editing the main `resolved.conf`, so future systemd package upgrades don't clobber the change.

---

## 2026-05-09 — v2.4.6

### Fingerprint authentication for the greetd login screen
- **New `install_greetd_fingerprint()` in `mappings.sh`** — adds `auth sufficient pam_fprintd.so` as the first auth rule of `/etc/pam.d/greetd` on hosts with a fingerprint reader, so the login screen accepts fingerprint before falling back to password. Runs from `install.sh` immediately after `install_greetd` inside the `greetd-regreet` block.
- **Bus-agnostic detection via `fprintd-list`** — uses libfprint's device enumeration rather than a sysfs-USB scan, so it covers USB internal sensors (Synaptics, Goodix, Validity), I2C/SPI hardwired readers (newer Lenovos), and anything else fprintd supports. If no devices are reported the function exits silently.
- **Idempotent + crash-safe** — reads `/etc/pam.d/greetd` without `sudo` (the file is mode 644), so a missed sudo prompt during the idempotency check can't be misread as "line not present" and trigger a duplicate insert. `sudo -v` is invoked before any destructive write so the function bails cleanly on sudo timeout instead of half-applying. Backs up the original to `/etc/pam.d/greetd.foxml-bak` before modifying. Leaves an existing `pam_fprintd` line wherever the user already placed it.
- **Enrollment hint** — if a reader is detected and PAM is configured but no fingerprints are enrolled for the current user, prints a one-line nudge to run `fprintd-enroll`. The installer never enrolls on the user's behalf — that's an interactive step requiring physical sensor input.

---

## 2026-05-09 — v2.4.5

### gpg-agent passphrase cache TTL — agent-friendly commits
- **New `install_gpg_agent_cache()` in `mappings.sh`** — extends the gpg-agent cached-passphrase TTL so agent-driven commits don't re-prompt every 10 minutes (the gpg-agent default). Idempotent: skips entirely if the user doesn't sign with GPG (`commit.gpgsign != true` and no secret keys), writes a fresh `~/.gnupg/gpg-agent.conf` if none exists, appends only the missing `default-cache-ttl` / `max-cache-ttl` keys if a config already exists, and leaves any user-set TTL alone. Ends with `gpgconf --reload gpg-agent` so the new value is live without a relog.
- **Override at install time** with `FOXML_GPG_CACHE_TTL=<seconds> ./install.sh`. Default 3600 (1h) — conservative for the OOTB case. Power users on personal encrypted laptops can bump to 28800 (8h) for a friction-free work session; shared workstations should stay at the default or lower.
- **`gnupg` added to the explicit pacman dep list** — was implicitly available via Arch's keyring deps but is now declared so the new function never hits a missing-binary path on minimal installs.
- **Wired into `install.sh` between `install_specials` and `install_catppuccin_cursor`** — runs as part of the user-environment phase, before greetd's system-level (sudo) deploys. No `sudo` is ever invoked by this step; only writes to `~/.gnupg/`.
- **What's not exposed** — the cache extension affects only the in-memory passphrase cache of the user's local gpg-agent process; no key material moves, no secrets touch disk or git, and the only repo artifact is the integer TTL value.

---

## 2026-05-09 — v2.4.4

Tmux ergonomics + greetd monitor portability.

### Tmux — pop-session UX (`prefix + m`, `prefix + M`)
- **Pre-size the placeholder session** — the old `tmux new-session -d -s "$sess"` ran at the default 80×24 before `move-window -k` swapped in the popped window. On `switch-client` the window snapped to the real client size, firing SIGWINCH at any TUI inside (nvim, btop, lazygit) and producing a visible redraw flash. New session now passes `-x #{client_width} -y #{client_height}` so the placeholder matches from the start; popped panes attach without resize.
- **Race-free, descriptive session names** — was `sess_$(date +%s)` (second-resolution, opaque, collides if `m` fires twice in the same second). Now `pop-${pane_current_command}-$$` for `m` and `kpop-${pane_current_command}-$$` for `M` (e.g. `pop-nvim-19421` / `kpop-btop-19422`), so `prefix + s` listings tell you what each popped session is and the PID suffix prevents collision.
- **Confirmation message held longer** — `display-message -d 2000` (was the default ~750ms) so the new session name stays readable long enough to remember.

### Tmux — global ergonomics
- **`default-terminal "tmux-256color"`** — properly advertises italics/undercurl to apps inside tmux. Pairs with the existing `terminal-features ",*:24-bit:RGB"` for true color.
- **`allow-passthrough on`** — kitty graphics protocol now reaches apps through tmux. Image previews in nvim image plugins, yazi, ranger, etc. start working inside tmux sessions instead of breaking silently.
- **`detach-on-destroy previous`** — exiting the last pane of a popped session now drops you back to your previous session instead of detaching the client to a bare shell. Natural pair for the `m`/`M` pop bindings.
- **`aggressive-resize on`** — when two clients on different sessions share a window (which happens with the kitty-pop binding), tmux only resizes for the client actively viewing it. Cuts redraw thrash in the popped kitty when the source kitty is a different size.
- **`set-titles on`** + `"tmux: #S → #W"` — propagates current session/window into the kitty title bar so the kitty window list shows what each tmux is doing.

### Tmux — copy mode + sync panes
- **Mouse drag-end → wl-copy** (`bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-no-clear "wl-copy"`) — selecting with the mouse now copies to the Wayland clipboard on drag-release without exiting copy mode. Previously mouse selection went nowhere wl-pastable; you had to switch to vi-mode and `v`+`y`.
- **`Y` copy-line** and **`r` rectangle-toggle** in `copy-mode-vi` — whole-line yank and block selection, matching vi expectations.
- **`prefix + e` synchronize-panes toggle** — mirror keystrokes to every pane in the current window. One key on, one key off; useful for multi-host SSH or "do this everywhere" moments.

### Tmux — pane-border-format optimization
- **Halved `tmux-pane-info` fork rate** — the format previously inlined the helper script call inside both branches of `#{?pane_active,...,...}`, so each pane border refresh ran the script twice (active styling, then inactive). Refactored to call once and wrap the styling around it. Halves the fork count per status refresh on dense layouts.

### Greetd — monitor portability
- **New `shared/greetd_select_monitor.sh`** — runs inside the minimal Hyprland greeter session before regreet starts. Walks `hyprctl monitors`, finds the first internal panel by name pattern (`eDP*`/`LVDS*`/`DSI*`), and disables every other connected output via `hyprctl keyword monitor "$m,disable"`. On desktops with no internal display it's a no-op — every monitor stays live and Hyprland's default order applies.
- **Why this exists** — the greeter Hyprland session is its own minimal config (`/etc/greetd/hyprland.conf`), totally separate from the user's daily Hyprland. Without per-monitor rules, the wildcard `monitor = , preferred, auto, 1` enabled every connected output without applying any rotation, so on a setup with a portrait-rotated external the greeter would land on the sideways monitor unrotated. Hardcoding monitor names per-host doesn't survive other users cloning the repo, so the runtime heuristic handles it.
- **`shared/greetd_hyprland.conf`** — `exec-once` now invokes `/etc/greetd/select-monitor.sh` before regreet.
- **`mappings.sh`**: `install_specials` stages `select-monitor.sh` to `~/.config/regreet/` alongside the css/toml/hyprland.conf; `install_greetd` requires the staged script (existence check refuses to deploy without it) and `sudo install`s it to `/etc/greetd/select-monitor.sh` mode 755.

---

## 2026-05-09 — v2.4.3

### Fixes
- **Suppress "waiting for your input" idle pings** — Claude Code and Gemini CLI both fire the `Notification` hook for two semantically different things: a real permission prompt (*"Claude needs your permission to use Bash"*) and a 60s-idle reminder (*"Claude is waiting for your input"*). Both came through with `urgency=critical`, indistinguishable. The idle variant is noise during multi-pane work — same red border, no action required. `agent_notify.sh` now matches the message body case-insensitively against `*waiting for {your,user,} input*` and exits silently before notifying or landing in the rofi triage queue. Real permission prompts pass through unchanged.

---

## 2026-05-09 — v2.4.2

### Fixes
- **Mako display queue overflowing during multi-agent bursts** — `max-visible=3` + `urgency=critical timeout=15s` meant a single "Claude needs input" popup held a lane for 15s while subsequent turn-completes and subagent-done events queued invisibly, dripping onto the screen seconds-to-minutes after the actual event (the hook fires on time; mako rate-limits the display). Bumped `max-visible` 3 → 6 and trimmed `default-timeout` 5s → 4s, `urgency=low` 3s → 2s. Critical stays 15s — you don't want a permission prompt expiring before you notice it.

---

## 2026-05-09 — v2.4.1

### Polish
- **Subagent body color** — was `C_SECONDARY` (#b8967a, a muted tan that read near-white on warm palettes). Now `C_WARN` (yellow) in both `agent_notify.sh` body markup and `agent_rofi.sh` event glyphs. Three-color traffic-light split: Stop=green, Subagent=yellow, Notification=red.
- **Gemini subagent parity** — Gemini CLI exposes no `SubagentStop` event, but subagents register as tools (built-in `codebase_investigator`, plus anything in `~/.gemini/agents/`). Added an `AfterTool` hook with an empty matcher; `agent_notify.sh` filters out the built-in primitives (`read_file`, `write_file`, `replace`, `run_shell_command`, `list_directory`, `search_file_content`, `glob`, `web_fetch`, `web_search`, `save_memory`, `read_many_files`) and any `mcp_*` tool, so only subagent invocations notify. Tool name is used as the body message so you can see *which* subagent finished. Custom subagents are auto-covered without us maintaining a regex.
- **Auto-restart Firefox after userChrome deploy** — `install_specials` now sends Firefox a SIGTERM (so session restore writes), waits up to 10s for graceful exit, then relaunches via `setsid`. Tabs, form fields, and scroll positions come back on the restored session. Drops the "Manual step (intentional): Restart Firefox" line from the post-install summary.

---

## 2026-05-09 — v2.4.0

AI agent notification suite — themed Claude/Gemini hooks with multi-pane rofi triage. Crisp notifications.

### Agent hooks
- **New `shared/hyprland_scripts/agent_notify.sh`** — single themed `notify-send` + JSONL queue helper that all Claude Code / Gemini CLI hooks call. Reads hook payload from stdin; sources `~/.config/hypr/modules/border_colors.sh` at fire time so a palette swap takes effect without re-running install.sh. ERR trap + no `set -u` / `set -e` so a hook can never paint a "stop hook error" banner in the agent TUI; failures land in `$XDG_RUNTIME_DIR/foxml-agent-notify.log`.
- **Claude `~/.claude/settings.json`** — Stop, SubagentStop, **Notification** hooks all routed through `agent_notify.sh`. The Notification hook (input/permission needed, critical urgency) is new — previously Claude permission prompts were silent.
- **Gemini `~/.gemini/settings.json`** — `AfterAgent` and `Notification` hooks routed through `agent_notify.sh`. Dropped bogus `SubagentStop` block (Gemini CLI has no such event); leftover entries from prior installs get cleaned up by the new merge logic.
- **`mappings.sh` Claude block** — replaced brittle inline-jq escaping with a heredoc → `jq -s '.[0] * .[1]'` deep-merge. Idempotent across re-runs.
- **`mappings.sh` Gemini block** — merge now replaces `.hooks` and `.ui` wholesale (instead of pure deep-merge) so removed events don't linger from prior installs. Other top-level keys like `security` are preserved.

### Triage UI
- **New `shared/hyprland_scripts/agent_rofi.sh`** — centered rofi list of pending agent notifications. Markup-rows with theme-colored event glyphs (red Notification, secondary subagent, OK Stop). hjkl navigation. Selecting an entry tmux-routes to the originating pane (`switch-client` / `select-window` / `select-pane`) and removes the entry; "Clear all" first item. Permission prompts still answered in the agent TUI — this is a router, not a remote-control panel.
- **`ALT + SHIFT + E`** opens it (`keybinds.conf`).
- **`KEYBINDS.md`** — new "AI Agents" section.

### Themed routing
- **`templates/mako/config`** — `[app-name=Claude]` PRIMARY-tinted border, `[app-name=Gemini]` ACCENT-tinted border. `notify-send -a Claude/Gemini` triggers them.
- **`templates/dunst/dunstrc`** — same pattern via `[claude]` / `[gemini]` rule blocks.
- Critical urgency (Notification hook = permission/input prompt) keeps the red `urgency=critical` border on both daemons.
- **`mappings.sh install_specials`** — reloads mako (`makoctl reload`) and dunst (`SIGHUP`) at the end so new app-name rules go live without a relog.

### Crisp notifications
- **`rules.conf` layerrule** — narrowed namespace match from `^(rofi|notifications|mako|dunst)$` to `^(rofi)$`. Mako/dunst layer surfaces are larger than the visible popup, so blur leaked across the border into adjacent windows (most visibly, kitty). Rofi is a single solid surface, so blur reads cleanly there.

### Caveat
- Already-running agent sessions need to be restarted to pick up new hooks — Claude Code and Gemini CLI both read `settings.json` once at startup, not per-turn.

---

## 2026-05-09 — v2.3.0

Polish + bootstrap pass — menu anchoring system, SSH auto-provisioning, post-install automation, CI scaffolding, runtime-dep cleanup, eww surface removal.

### Rofi — per-modal anchor zones
- **New `shared/hyprland_scripts/_rofi_zone.sh`** — sourceable helper resolving `ROFI_ZONE=nw|ne|center` into a `$ROFI_POS_THEME` rasi fragment. Per-modal nudge still honored via `ROFI_X` / `ROFI_Y`.
- Each rofi-opening script self-classifies into a zone:
  - **NE** (system menus): `hub.sh`, `network.sh`, `bluetooth.sh`, `audio_switcher.sh`, `powermenu.sh`
  - **NW** (launcher): `toggle_rofi.sh`, `clipmanager.sh`, `fox-ai-quick`
  - **Center** (reference): `fox-cheatsheet`
- Replaces `north west` hardcodes scattered across 7 scripts. Spatial mapping now matches the macOS Control Center / Win11 Quick Settings pattern: status cluster top-right → control modal opens below it; workspace switcher top-left → launcher modal opens below it; cheatsheet has no spatial home so it centers.
- `keybinds.conf` unchanged — scripts self-classify, no per-bind `ROFI_ZONE` prefix needed.

### Bootstrap — SSH provisioning
- **`install_github_workspace()` now generates `~/.ssh/id_ed25519` and uploads it via `gh ssh-key add`** if missing. Idempotent: skips keygen if the file exists; skips upload if `gh ssh-key list` already shows the pubkey. Auto-runs `gh auth refresh -s admin:public_key` when the gh token lacks the upload scope.
- Without this, `git clone git@github.com:...` failed on fresh boxes after `bootstrap.sh` because no SSH key existed yet — the workspace-clone step itself succeeded over HTTPS, but subsequent SSH clones broke.

### Install — post-install automation
- **New `apply_post_install()` in `install.sh`** auto-applies what used to be a manual checklist:
  - `hyprctl reload` (only inside an active Hyprland session)
  - Waybar / Dunst restart (only if currently running)
  - `nvim --headless +Lazy! sync +qa` (60s cap, only if nvim + lazy.nvim are present)
  - Cursor / VS Code `workbench.colorTheme = "Fox ML"` via `jq` merge into `User/settings.json`
- Each step self-skips when its precondition isn't met. Restart-Firefox stays manual (auto-restart kills open tabs).
- **Dropped stale "ReGreet staged / To activate: sudo cp ..." block** in `install_specials()` — `install_greetd()` already auto-deploys to `/etc/greetd/`, so the manual instructions were misleading clutter.

### CI + tests
- **`.github/workflows/shellcheck.yml`** — runs `shellcheck --severity=error` on every shebang-detected bash/sh script in the repo on push and PR. Severity capped at error initially (only fails on real bugs); tighten to `warning` later.
- **`tests/roundtrip.sh`** — codifies CONTRIBUTING.md's manual round-trip test. Refuses on dirty `templates/`, runs `./install.sh --render-only --yes` then `./update.sh`, fails if `git diff templates/` shows drift. Catches I-04 violations before push.

### Deps — fresh-box runtime gaps closed
- **Added** to `install_sys_deps`: `cloc`, `tree`, `rsync`, `shellcheck`, `ripgrep` (Core & CLI Tools), and `networkmanager`, `wireplumber`, `libnotify`, `upower`, `lm_sensors` (new "Networking + audio + notifications + power telemetry" line).
- Without these explicit deps, fresh Arch boxes silently failed at runtime: `nmcli` (no NetworkManager), `wpctl` (no Wireplumber), `notify-send` (no libnotify) — every script that called these would no-op or break.

### Cleanup
- **Eww surface removed.** `templates/eww/` (eww.yuck + eww.scss + dir), `shared/hyprland_scripts/eww_action.sh`, `shared/hyprland_scripts/toggle_control_center.sh` deleted. `install.sh` AUR-eww install block, `mappings.sh` eww template mappings, `startup.sh` disabled-eww-daemon comment, and `README.md` eww row also removed. The eww control center turned out to need significant work to match the rofi syshub (no native hjkl, GTK keyboard nav only) and was never actually used; dropping it removes ~25 lines of dead code.
- **`hub.sh:107` — `swww query` → `awww query`** in the "Sync Theme to Wallpaper" action. The theme installs `awww` (line 132 of `install.sh`) but the hub action was calling `swww query`, which silently returned nothing on this box, so the action did nothing.

---

## 2026-05-08 — v2.2.5

### Fixes
- **Landscape wallpapers letterboxed on 16:9 screens** — the source landscape wallpapers were 3840×2655 (~3:2), so `awww --resize fit` (introduced in v2.2.0's per-monitor rewrite) drew the laptop's 16:9 panel with black bars on left and right.
- **Resized source wallpapers to 3840×2160** — center-cropped via ImageMagick. All 5 landscape wallpapers in `shared/wallpapers/` are now exactly 16:9, so they fill any standard 16:9 panel without scaling artifacts and downscale cleanly to HiDPI.
- **`rotate_wallpaper.sh` landscape default flipped from `fit` to `crop`** — `crop` scales-to-fill and trims overflow rather than letterboxing. With the new 16:9 sources this is a no-op on 16:9 panels, but on 16:10 / 21:9 / ultrawide screens it still fills cleanly. Portrait monitors still use `fit` against the pre-cropped 1080×1920 variants for a 1:1 match.

---

## 2026-05-08 — v2.2.4

### Fixes
- **`source ~/.zshrc` errored with "no matches found: ??"** — `shared/zsh_aliases.zsh` line 42 defined a function named `??` (the natural-language-to-bash helper). zsh treats a bare `??` token as a glob pattern (any 2-character filename) and errored on every shell startup if the cwd had no matching files. Fixed by quoting the name and using the `function` keyword: `function '??'() { … }`.

---

## 2026-05-08 — v2.2.3

Documentation overhaul. Replaced stale planning prose and incorrect references with factual, current docs that match the actual repo layout. Also pruned tracked editor backups.

### README.md
- Finalized the in-progress rewrite from "FoxML Workstation — high-discipline AI-powered platform" marketing prose to the plain reference-tone "Arch + Hyprland theme + dotfiles" framing.
- Added the 5 themed apps that were missing from the table — `eww`, `lazygit`, `git delta`, `gemini`, `opencode`. Total now matches the 25 directories under `templates/`.
- New **Multi-monitor** section documenting `configure_monitors`, the layout sidecar, name-keyed Hyprland rules, the secondary waybar, and portrait wallpaper auto-generation.
- New **Tmux: pop a pane to the portrait monitor** subsection covering `prefix + m` and `prefix + M`.

### CONTRIBUTING.md
- Full rewrite. Old version documented a non-existent folder structure (`FoxML/btop/`, `FoxML/cursor/`…) and referenced `FoxML.md` (doesn't exist) and `update_file` (not a thing).
- New version documents the actual layout (`templates/<app>/`, `themes/<theme>/`, `shared/`), the correct add-an-app flow via `TEMPLATE_MAPPINGS` in `mappings.sh`, when to add a special handler, and the round-trip test that catches missed `{{TOKEN}}`s.

### AGENT.md / INVARIANTS.md
- Removed the "Future C++ Refactor" planning sections from both files. That work isn't active and was leaking into agent context as if it were.
- INVARIANTS.md gained `[I-05] Per-machine config preservation` documenting the `monitors.conf` skip-if-exists behavior.
- AGENT.md picked up a Multi-monitor architecture note pointing at the layout sidecar.

### KEYBINDS.md
- Audited the Hyprland section against actual `keybinds.conf` and fixed several entries that documented bindings that don't exist or pointed at the wrong key:
  - `ALT + Shift + H` → FoxML Hub: never bound. The hub is on `ALT + Shift + D`.
  - `ALT + Shift + D` → Rofi App Launcher: there's no separate launcher; D is the hub.
  - `ALT + Shift + V` → Steam: actually clipboard image picker. Steam is `ALT + Shift + M`.
  - `ALT + Shift + M` → ncspot: actually Steam.
  - `ALT + Shift + S` → Spotify: never bound, removed.
- Added the missing entries: `ALT + Shift + V` (clipboard images), `ALT + Shift + K` (panic kill).
- Tmux section: replaced the misleading "Move pane to new session" entry with the rewritten `prefix + m` (auto-switches client), added `prefix + M` (pops to own kitty window).

### Repo hygiene
- **Removed 5 tracked nvim backup files** — `templates/nvim/init.lua.bak{2..6}` had been accidentally committed despite CONTRIBUTING.md saying `.bak` files are local safety nets. They're gone now.
- **`.gitignore`** — added `*.bak`, `*.bak[0-9]*`, `*~` (editor backups), and `rendered/` (regenerated on every install).

---

## 2026-05-08 — v2.2.2

Floating-window focus binds + KEYBINDS doc cleanup.

### Hyprland — Targeted window focus
- **`ALT + Tab`** — `cyclenext, floating`. Cycles focus through *only* floating windows, skipping tiled ones. Useful when a floating Spotify scratchpad / terminal / picker is mixed in with tiled editor panes.
- **`ALT + Ctrl + Tab`** — `cyclenext, tiled`. Inverse: cycles only the tiled stack. (Couldn't double up `$mainMod` since `$mainMod = ALT` makes `ALT+ALT+Tab` unfireable, so used CTRL as the second modifier.)
- **`ALT + Shift + Tab`** — unchanged, still cycles all windows in reverse.

### Docs
- **`KEYBINDS.md` Core Workflow table** — replaced the stale `ALT + Tab → Rofi Window Search` entry that described a binding that was never actually present in `keybinds.conf`. Now matches reality.

---

## 2026-05-08 — v2.2.1

Bug fixes and portability cleanup following v2.2.0.

### Fixes
- **Install silently aborted before `install_throttling`** — `_generate_portrait_wallpapers()` ended with `(( generated > 0 )) && echo …`, which returns 1 on every re-run after the first (when all portrait variants already exist). Under `set -e`, that made the function exit 1, which propagated out of the post-`configure_monitors` backstop block and aborted the script before the waybar restart and CPU throttling wizard ever ran. Replaced the `&&` form with an explicit `if/fi` and added `return 0` to lock the function's success contract.
- **Stale `FoxML_Workstation` repo path** — both `bootstrap.sh`'s curl-pipe-bash documentation and `shared/foxml-profile.json`'s `user_commands` referenced the old repo name. Updated to `Linux_Theme` so the published one-liner actually resolves.

---

## 2026-05-08 — v2.2.0

Multi-monitor support: interactive layout picker, name-keyed Hyprland rules that survive undocking, secondary waybar for external displays, auto-generated portrait wallpapers, and a tmux keybind to pop a pane into its own kitty window for placement on a rotated monitor.

### Multi-monitor — Interactive setup
- **`configure_monitors()`** — new handler in `mappings.sh`. Detects every connected output via `hyprctl monitors -j`, then for each non-primary monitor prompts position (left/right/above/below) and orientation (landscape / portrait-left / portrait-right). Writes `~/.config/hypr/modules/monitors.conf` with name-keyed rules and a sidecar at `~/.config/foxml/monitor-layout.conf` consumed downstream by waybar and the wallpaper rotator.
- **Portable per-machine layout** — rules are keyed on output name (`HDMI-A-1`, `eDP-1`, …); Hyprland silently ignores rules for absent outputs, so undocking just falls back to the catch-all `monitor = , preferred, auto, 1`. Plug the same external back in and the saved layout reapplies. Re-installing on a new dock setup re-prompts.
- **Skip-if-exists for `monitors.conf`** — the shared modules deploy loop in `mappings.sh` no longer clobbers a per-machine `monitors.conf`. First-run still seeds the catch-all default.
- **`-y` auto-pilot** — under non-interactive install, externals default to right-of-laptop landscape with no prompts.

### Waybar — Secondary bar on external monitors
- **`shared/waybar_config_secondary`** — new bar definition: `group/launcher` (fox + workspaces) plus `custom/clock`. Inherits the same height/style tokens as the main bar so the shaded container matches.
- **Multi-bar render** — `start_waybar.sh` reads the layout sidecar; if `SECONDARY_OUTPUTS` is set, merges main + secondary configs into a JSON array via `jq`, with `output` keys pinning each bar to its monitor(s). Single-monitor path unchanged.
- **Install-time render moved** — waybar render now runs *after* `configure_monitors` (was running before, which baked in a single-bar config that survived configuration). Install also bounces a running waybar so the new layout takes effect immediately instead of waiting for next session.

### Wallpapers — Portrait-aware
- **Auto-generated portrait variants** — `_generate_portrait_wallpapers()` uses ImageMagick to center-crop every landscape wallpaper to 1080×1920 (`scale-to-fill, then extent`) into `${name}_portrait.${ext}`. Idempotent. Called by `configure_monitors()` when a rotated output is detected, plus a backstop in `install.sh` that re-runs whenever the sidecar lists a portrait output (covers the case where ImageMagick was installed in the same run after the first detection pass).
- **Per-monitor application** — `rotate_wallpaper.sh` now iterates `hyprctl monitors -j` and applies via `awww img -o <name>` per output. Rotated monitors prefer the `_portrait` variant with `--resize fit`; fall back to landscape source with `--resize crop` if no variant exists.
- **`imagemagick` added to deps** — installed via `--deps` for the generator.

### Tmux — Pop pane to its own kitty window
- **`prefix + M`** — new bind in `templates/tmux/.tmux.conf`. Captures the broken-out pane's window ID via `break-pane -P -F`, moves it into a fresh tmux session (placeholder window killed via `move-window -k`), then spawns `kitty --detach` attached to it via `env -u TMUX tmux attach`. Unsetting `TMUX` is what makes the new kitty actually attach to the popped session instead of nesting/falling back to the parent — without it both kitty windows mirror the original session.
- **`prefix + m` rewritten** — same mechanics as `M` (clean session, no placeholder), and now auto-`switch-client`s your existing kitty into the new session instead of leaving you on the old one wondering whether anything happened.

### Fixes
- **`@anthropic-ai.agent-code` → `@anthropic-ai/claude-code`** — install.sh's npm globals had a malformed package name (no slash between scope and name) and a broken `command -v.agent` check. Fixed to install `@anthropic-ai/claude-code` and check for `claude` on PATH.
- **Compiled `fox-intel` binaries removed from tree** — `src/fox-intel/fask` and `findex` are build artifacts; `install.sh` already rebuilds them on every run, so they never belonged in version control.

---

## 2026-05-08 — v2.1.0

OpenCode integration: palette-driven theming, multi-model picker, automatic skill discovery, and consolidated single-command bootstrap.

### OpenCode — First-class integration
- **FoxML custom theme** — added `templates/opencode/foxml.json` using the standard `{{TOKEN}}` system. Renders through `render.sh` like every other config; swapping palettes via `swap.sh` re-themes OpenCode automatically. Maps secondary text to `WHEAT` (matching Gemini CLI's warm feel) and uses `NVIM_BG_HL` for input bg to avoid the plum-tinted default.
- **Multi-model picker** — `configure_opencode()` queries `ollama list` and writes every installed model into `provider.ollama.models`, so the in-app picker shows them all instead of the single hard-coded default.
- **Skill discovery** — `skills.paths` is populated by globbing `~/code/*/claude-skills/`; any workspace with `SKILL.md` files (public + private) is auto-wired without naming any private repo in the public installer.
- **`tui.json` theme persistence** — installer writes both `opencode.json` and `tui.json`. OpenCode auto-migrates `theme` between files on first launch; writing both directly means a fresh-PC install boots themed without an in-app step.
- **Project-local config** — installer drops `.opencode/opencode.json` in the repo so the project-local skill paths are always picked up regardless of where the user invokes opencode from.

### Bootstrap — Consolidated single-command install
- **`~/code/Linux_Theme` clone target** — `bootstrap.sh` now clones into `~/code/Linux_Theme` instead of `~/FoxML_Workstation`, eliminating the duplicate clone that happened when `--github` was on (it would otherwise clone everything *including* the workstation repo into `~/code/`). One workspace, one location.
- **Deferred OpenCode config** — `configure_opencode()` runs *after* the GitHub block so skill-path discovery sees freshly-cloned private workspaces on a brand-new machine.

### Fixes
- **Tier detection bug** — `source "$SHARED_DIR/bin/fox-hw-info"` only echoed values without setting them, so `$TIER` was always empty and `--models` silently fell through the `case` without pulling anything. Replaced with `eval "$(bash ...)"` which actually populates the vars.
- **Empty skill scaffolds removed** — deleted five empty subdirs in `claude-skills/` (`dust`, `foxlib-promotion`, `ml-audit`, `plan-check`, `sync-workspace`) that misled OpenCode's skill scanner. The actual skill content lives in a separate workspace and is wired in via the path glob.

---

## 2026-05-08 — v2.0.0

Fox Intelligence Layer. Transitioned from a theme repository to an AI-Integrated Workstation. High-performance C++ Semantic RAG, project-aware shell, and unified command suite.

### Intelligence — Fox Intelligence Layer (RAG)
- **C++ Core**: Implemented `findex` and `fask` in high-performance C++ using `libcurl` and `nlohmann/json`. Replaces previous experimental Bash/Python scripts.
- **Semantic Indexing**: `findex` generates mathematical meaning vectors (embeddings) for all project files via the `nomic-embed-text` model.
- **RAG Engine**: `fask` performs native vector similarity search to build project-specific context before answering user questions.
- **`fhelp`**: New interactive documentation system with deep-dive help, technical details, and usage examples for all tools.

### Shell — Project Awareness & Ergonomics
- **Auto-Context**: Added `chpwd` hooks to `zsh` for automatic detection of FoxML-enabled projects (via `AGENT.md`). Exports `$FOXML_PROJECT_ROOT` and scopes AI tools instantly.
- **Unified "f" Suite**: Implemented ergonomic aliases for all AI and distro tools (`fcommit`, `fstatus`, `flog`, `fbench`, `fproject`, `fdistro`, etc.) removing the `fox-ai-` prefix friction.
- **Project Bootstrapping**: `fproject` (alias for `fox-new-project`) now creates high-discipline workspaces with `AGENT.md` and `INVARIANTS.md` out-of-the-box.

### Infrastructure
- **Installer Integration**: `install.sh` now automatically compiles the C++ Intel Layer and manages `json.hpp` dependency.

---

## 2026-05-07 — v1.5.9

FoxML OS & ISO Pipeline. Complete operating system specification, automated ISO build suite, and hardware-agnostic AI scaling.

### Distro — FoxML OS Experience
- **`archinstall` Profile**: Created `shared/foxml-profile.json` for fully automated OS deployment with **linux-zen** kernel and pre-configured hardware drivers.
- **ISO Build Suite**: Added `distro/` infrastructure (`profiledef.sh`, `packages.x86_64`) to package FoxML as a standalone bootable ISO.
- **`ai-distro-build`**: New utility to automate the creation of the FoxML-OS image.
- **`ai-distro-flash`**: New safety-first utility to flash the FoxML ISO to a USB drive with system-drive protection.
- **`ai-distro`**: Distro Guide utility for instant deployment instructions.

### AI — Hardware-Agnostic Scaling
- **`fox-hw-info`**: Implemented dynamic hardware detection. The system now categorizes itself into **Lite**, **Standard**, or **Pro** tiers based on actual RAM/VRAM.
- **Dynamic Stack**: `--models` now pulls a curated stack (e.g., 7B/14B/32B for Standard) optimized for the user's detected hardware.
- **Context-Aware Switcher**: `ai-swap` now dynamically labels model choices (Safe/Balanced/Heavy) based on detected system capacity.

### Maintenance & Safety
- **Universal Commands**: Generalized all `/slash` commands in `.agent/commands/` for use in any project.
- **Improved Backups**: Refined `backup_and_copy` logic to ensure system configs are safely versioned before being overwritten.
- **Emoji Purge**: Stripped emojis from installer and CLI tools for a high-discipline, professional terminal experience.

---

## 2026-05-07 — v1.5.8

Total Workstation Automation. Single-command workstation bootstrap, automated GitHub workspace, and integrated AI Lab.

### One-Command Bootstrap (`bootstrap.sh`)
- **Complete Environment Deployment**: The `bootstrap.sh` script now defaults to a full workstation stack (`--deps --ai --models --github`). A single `curl | bash` line now delivers a complete, professional dev environment from a fresh Arch install.

### GitHub — Automated Workspace (`--github`)
- **Seamless Repository Deployment**: New `--github` flag automates the creation of `~/code` and clones all public and private repositories for the user via `gh`.
- **Integrated Auth**: Synchronized with the SSH hardening wizard for a zero-password cloning experience once keys are authorized.
- **Git Identity Management**: Automatically prompts for and configures global Git name/email if missing.

### AI — Local LLM Workspace (Ollama & OpenCode)
- **Automated AI Stack**: `--ai` installs Ollama/OpenCode; `--models` automates pulling the **Qwen2.5-Coder stack (7B, 14B, 32B)**.
- **Universal Skills Vault**: Deploys a central vault at `~/.local/share/foxml/ai_skills/` and plugs high-discipline AI protocols (/readiness, /ship, /dust, etc.) into any project.
- **Model Management**: Added `ai-swap` (Tier switcher), `ai-purge` (VRAM/RAM flush), and `ai-bench` (Hardware performance tracking).
- **Project Tools**: Added `ai-new` (High-discipline project creator) and `ai-init` (Instant skill symlinking).

### Neovim — AI-Powered IDE
- **CodeCompanion.nvim**: Integrated for inline code generation and workspace chat.
- **Avante.nvim (Local)**: Cursor-style AI sidebar reconfigured for local-first privacy.

### Terminal — AI Superpowers
- **`??` Alias**: Natural language to Linux command generator.
- **`ai-commit`**: Automated Conventional Commit message generation.
- **`ai-log` / `ai-find`**: Instant error analysis and semantic codebase search.

### UI — Real-time AI Monitoring
- **Waybar AI Status**: Real-time tier display (7B/14B/32B) with **Live VRAM Tracking** for 4GB hardware.
- **SysHub Integration**: Added "Quick AI Chat" to the Rofi hub for floating, context-free queries.

---

## 2026-05-07 — v1.5.7

Performance, Privacy, and Vault pass. High-precision time, encrypted DNS, secure secret management, and Panic Button.

### Security — Vault, Panic Button & Auditing
- **Secure Vault (Pass)**: Integrated the `pass` (GPG-encrypted) password manager into the installer (`--vault`).
    - **Automated GPG**: Automatically detects or generates a personal GPG key to bootstrap the vault.
    - **SysHub Integration**: Added a "Vault (Passwords)" option to the Rofi Hub for instant searching/copying of secrets.
    - **Git Signing**: Automatically configures Git to cryptographically sign all commits with your GPG key.
- **The Panic Button**: Introduced a "Panic Button" script for instant system lockdown.
    - **Total Wipe**: Clears clipboard history (cliphist/wl-copy), kills sensitive apps (nvim, rofi-pass), stops trading engines, and locks the screen.
    - **Hotkeys**: Bound to **`Alt + Shift + K`** and available in the SysHub.
- **Lynis Auditing**: Added `lynis` to the security toolset. A full system security audit can now be launched directly from the SysHub.
- **Sudo Hardening**: Integrated a `NOPASSWD` sudoers drop-in for Waybar modules, enabling seamless security monitoring without password prompts.

### Performance & Privacy — Chrony & DoH
- **High-Precision Time (Chrony)**: Added the `--perf` flag to replace `systemd-timesyncd` with `chrony`. Provides sub-millisecond precision for trading engine logs and data correlation.
- **Encrypted DNS (DoH)**: Added the `--privacy` flag to enable **DNS-over-HTTPS** via `systemd-resolved`. Encrypts all DNS queries to prevent ISP tracking/spoofing (works seamlessly on restricted dorm/public WiFi).
- **Security Overwatch 2.0**:
    - **Always Visible**: The security shield icon (`󰒃`) is now always visible on the Waybar when secure (glowing green).
    - **Time Monitoring**: The shield now tracks `chronyd` status and alerts you if the system clock loses sync with atomic time.

### UI — Hub Expansion
- **SysHub 2.5**: Added "Vault", "Panic Button", and "Security Audit" entries to the primary Hub.

---

## 2026-05-07 — v1.5.6

Security hardening pass. Automated firewall, brute-force protection, and SSH hardening.

### Security — Automated Hardening & SSH Wizard
- **New `--secure` Installer Flag**: Added an opt-in `--secure` flag to `install.sh` that automates system-level security hardening.
- **Automated Firewall (UFW)**: The installer now configures `ufw` with a "Deny-by-Default" policy, explicitly allowing only the SSH port and outgoing traffic.
- **Brute-Force Protection (Fail2ban)**: Integrated `fail2ban` into the installation flow to automatically block IP addresses attempting brute-force attacks.
- **Interactive SSH Hardening Wizard**: Added a comprehensive wizard to `mappings.sh` that safely guides the user through:
    - **Custom SSH Port**: Configures a non-standard port (e.g., 5125) to reduce bot visibility and log spam.
    - **Automated Key Import**: Offers to fetch public keys directly from GitHub (`github.com/username.keys`) to simplify SSH key setup.
    - **Passwordless Auth**: Safely disables `PasswordAuthentication` only after verifying that SSH keys are present, preventing accidental lockouts.
- **Clean Configuration**: Hardening settings are written to `/etc/ssh/sshd_config.d/50-foxml-hardening.conf`, preserving the integrity of the main system `sshd_config` and ensuring settings survive OS updates.
- **Firewall/SSH Sync**: The script automatically updates UFW rules when a custom SSH port is selected, ensuring the firewall and SSH daemon stay in lockstep.

---

## 2026-05-07 — v1.5.5

A stability + UX pass. Hyprland 0.54.3 config errors resolved, Rofi popups seamlessly integrated with Waybar, and installer deployment logic fixed.

### UI — Seamless Rofi Dropdowns & Waybar Integration
- **Unified Launcher Box**: Grouped the Waybar `custom/logo` and `hyprland/workspaces` modules into a single, cohesive `group/launcher` box with a shared border and background.
- **Dynamic Popup Anchoring**: `start_waybar.sh` now dynamically calculates the exact pixel coordinates for the bottom edge of the Waybar and the left edge of the launcher box, exporting them as `ROFI_Y` and `ROFI_X`.
- **Flush Glass Theme**: Updated the Rofi `glass.rasi` theme to use a 1px 40%-opacity border (matching Waybar) and removed top padding. The popup now overlaps the Waybar border by exactly 1px, creating a seamless "drop-down" extension of the launcher box.
- **Global Toggle Wrapper**: Introduced `shared/hyprland_scripts/toggle_rofi.sh` to centralize Rofi toggling (killing active instances) and positioning injection. This fixes the "unexpected pixels" syntax error caused by Hyprland aggressively evaluating `$$` as PIDs instead of passing variables to the shell.
- **Centralized Hub Workflow**: Swapped the primary hotkey **`Alt + Shift + D`** (and the Waybar Fox icon) to open the **SysHub** directly. Standalone hotkeys for Search and Active Windows were removed to encourage a Hub-centric workflow.
- **Vim-Style Navigation & Exits**:
    - **`j/k`**: Scroll up/down through all menus.
    - **`l` or `Enter`**: Select/Execute items.
    - **`h`**: Instantly exits the Hub and sub-menus (Power, Network, etc.), providing a fast Vim-like escape.
- **Calculator & Emoji Picker**: Added `rofi-calc` and `rofi-emoji` to the installer dependencies and integrated them directly into the SysHub. Both use the unified `j/k/l` navigation.
- **Workspace App Icons**: Implemented Waybar's `window-rewrite` feature to display Nerd Font application icons next to the active workspace numbers (e.g., `1 󰈹` for Firefox), providing lightweight, real-time app tracking.
- **Fox Launcher Logo**: Swapped the default Arch Linux logo in the Waybar launcher for a Fox icon (`🦊`) to match the project's branding.
- **Polished Tooltips & Notifications**: Themed Waybar hover tooltips and system notifications (Dunst & Mako) to perfectly match the new Rofi glass aesthetic—featuring 90% opaque earthy backgrounds, 0px corner radii, and translucent 1px borders.
- **Tmux Git Ahead/Behind Counts**: The tmux status bar now tracks how many commits your current feature branch is ahead (↑) or behind (↓) the default branch (`main` or `master`), alongside the existing dirty indicator.

### Installer — Proper Deployment & Performance
- **Fixed `--render-only`**: The `install.sh --render-only` flag now correctly deploys updated `shared/` scripts, `bin/` helpers, and modules to your live config directories. Previously, it only regenerated templates, leaving the system running outdated logic.
- **Hub Speedup**: The SysHub (`hub.sh`) now uses `nmcli connection show --active` instead of a full WiFi scan, eliminating the 2-3 second startup lag.

### Hyprland — Window-Rule Compatibility
- **Swappy windowrules fixed for 0.54.3**: The inline form (`windowrule = float, class:^(swappy)$`) was failing parser validation because the colon in the regex matcher was being read as a key/value separator (`invalid field class:^(swappy)$: missing a value`). Converted to the unified block form already used throughout `rules.conf`:
  ```
  windowrule {
      name = swappy-float
      match:class = ^(swappy)$
      float = true
      size = 1200 800
      center = true
  }
  ```

### UI — Rofi Popup Alignment
- **Top-left anchor across the board**: The drun launcher (`Mod+Shift+D`) and the `Mod+Tab` window switcher both anchor `north west` with `x-offset: 12px` and `y-offset: 50px`, so popups land directly under the workspaces in the bar instead of top-center. Folds in the recent `force top-alignment on Rofi drun launcher` and `align Rofi to top and update layer animations` commits.
- **Robust theme loading**: Standardized on `-theme-str` overrides where positional offsets matter, so the override wins regardless of `~/.config/rofi/config.rasi` ordering. Fixes Alt+Shift+D occasionally picking up the wrong theme.

### Waybar — GPU Tooltip
- **GPU metrics folded into CPU tooltip**: Removed the standalone GPU pill; the CPU bubble's hover tooltip now lists CPU temp/load and GPU usage/temp together, matching the v1.5.4 density direction.

### Eww Control Center — Paused
- **Experiment, then revert**: Tried replacing the Rofi syshub with a graphical Eww panel + right-extending drawer for sub-menus (Audio, Network, Bluetooth, Power). Eww 0.5.0 has no native `hjkl` navigation (only GTK Tab/arrow keys), and matching the Rofi syshub UX — close handling, toggle behavior, keyboard nav — needed more plumbing than the visual upgrade justified.
- **Disabled, not removed**: Templates (`templates/eww/eww.yuck`, `eww.scss`), the action dispatcher (`shared/hyprland_scripts/eww_action.sh`), and the toggle script remain in the repo. Disabled at three integration points so nothing auto-launches: the `Mod+Shift+H` keybind reverted to `hub.sh`, the Rofi hub's "Open Control Center (Eww)" entry removed, and `eww daemon &` commented out in `startup.sh`. Re-enabling is a one-line flip if revisited later.
- **Toggle-loop bug fixed in the dormant script** for if/when it's re-enabled: `eww active-windows` outputs `<id>: <name>`, so the previous `^control_center$` grep never matched and the close path was unreachable. Switched to `eww list-windows` with a more lenient pattern.

---

## 2026-05-07 — v1.5.4

Power tuning gets a guided installer pass, and Waybar is consolidated from a 15-module sprawl into 10 dense bubbles with everything else folded into hover tooltips.

### Installer — CPU Throttling Wizard
- **Always-prompt setup**: New `install_throttling()` runs at the end of every interactive install (skipped under `-y`). Each step is its own y/N so users can pick & choose.
- **Intel turbo disable**: Writes `/etc/tmpfiles.d/disable-turbo.conf` so `no_turbo=1` re-applies on every boot — survives suspend/wake and kernel resets.
- **`cpupower` max-frequency cap**: Prompts for an MHz value (showing the hardware max as a hint), persists via `/etc/default/cpupower`, and enables `cpupower.service` so the cap survives reboots — fixing the common gotcha where `cpupower frequency-set -u` is a one-shot.
- **CPU governor**: Validates the requested governor against the kernel-reported list before applying, then persists it alongside `max_freq`.
- **`throttled` (ThinkPad MSR fix)**: Auto-detected via DMI. Installs from AUR using `yay`/`paru` and enables the service. Tunables (PL1/PL2, `Trip_Temp_C`, voltage offsets) stay hand-edited in `/etc/throttled.conf` — wrong undervolts crash silently, so no risky defaults are imposed.
- **Sample config**: New `shared/throttled.conf` ships a documented starting point (P15 Gen 2i, conservative PL1/PL2, no undervolt) with per-CPU tuning notes in the header.

### Aesthetics — Waybar Streamlining
- **Density cut from 15 → 10 modules**. Six standalone pills folded into composite tooltips so the right-hand cluster has room to breathe.
- **`custom/clock`**: Date + time in the bubble (with the `` calendar glyph and the same peach-bold + glow as before). Hover reveals weather (via `wttr.in`, cached 30 min) and pending pacman updates (via `checkupdates`, cached 10 min).
- **`custom/battery`**: Capacity + charge icon in the bubble. Hover reveals current speaker volume and screen brightness. Charging / warning / critical states preserved via JSON `class` field — same color set as the old built-in module.
- **`custom/net_speed` tooltip**: When on a wireless link, hover now shows the active SSID and signal strength (read via `nmcli`) — the standalone `network` module is gone.
- **Removed from bar**: `weather`, `network`, `updates`, `pulseaudio`, `backlight`, `project_name`. Their data lives in tooltips now.
- **Pure-bash `net_speed`**: Dropped the `bc` runtime dependency — speed formatting now uses integer math.

### Branding — Fox ASCII Repair
- **Welcome banner**: Fixed a corrupted escape sequence (`/\\\\_∕\\\\` → `/\_/\`) so the Fox face renders cleanly in `welcome.zsh` and the Neovim dashboard header.
- **Quieter post-submit prompt**: The caramel theme's accept-line indicator changed from `❯` (accent2) to `•` (ANSI_OK) — softer visual hand-off after each command.

---

## 2026-05-06 — v1.5.3

Final UI refinement for a distraction-free experience.

### Aesthetics — Distraction-Free UI & Scaling
- **Hidden Search Bars**: Removed the search bar from all non-launcher Rofi menus (Bluetooth, Network, Audio, Hub, and App Switcher). These menus now feel like clean, native desktop utilities.
- **Universal `j/k` Navigation**: All utility menus now use **plain `j` and `k`** for navigation and **`l`** for selection. This allows for unified, home-row navigation without modifier conflicts.
- **Resolution Scaling**: Replaced hardcoded pixel widths with **relative percentages**. All menus now automatically scale to your screen size, ensuring they remain perfectly centered and proportional on 1080p, 1440p, and 4K displays.
- **Persistent Launcher**: The search bar remains active only in the main Application Launcher (`ALT + Shift + D`), where it is functionally required for fuzzy searching.

---

## 2026-05-06 — v1.5.2

Aesthetic refinement and power-user window management. Perfected UI transparency, bar alignment, and browser integration.

### Workflow — Tabbed Window Groups
- **Themed Groupbar**: Enabled Hyprland "Groups" (Window Tabs) with a custom FoxML look. Active tabs use the earthy Peach palette, while inactive tabs stay in the subtle Slate color.
- **Group Keybinds**:
    - **`ALT + G`**: Toggle the current window into/out of a group.
    - **`ALT + [`** and **`ALT + ]`**: Cycle between tabs in the current group.

### Aesthetics — Perfect Transparency & Glass
- **Rofi Fixed**: Resolved "opacity stacking" where inner elements were making the menus look opaque. Transparency is now applied only at the window level, allowing for a pure frosted glass look.
- **Waybar Alignment**: The top bar now dynamically reads your Hyprland `gaps_out` and sets its margins to match. It now aligns perfectly with your windows for a seamless "floating" aesthetic.
- **Improved Scaling**: Refined font sizes and heights across all resolution profiles to ensure UI elements are proportional and highly readable on 1080p, 1440p, and 4K displays.

### Firefox — Distro-Grade UI Refinement
- **Context Menu Fix**: Eliminated the "white background" glitch on context menus by aggressively forcing earthy backgrounds and disabling native theme overrides.
- **URL Bar Dropdown**: Refined the search suggestion dropdown with proper dark backgrounds, sharp borders, and high-contrast peach selection highlights.
- **Unified Sharpness**: Ensured all popups, panels, and menus maintain 0px rounding for a consistent FoxML aesthetic.

---

## 2026-05-06 — v1.5.1


Major suite of Workflow and Creative upgrades. This release transitions FoxML from a "Theme" to a complete "Distro Lite" experience for developers.

### Installer — "Distro Lite" Features
- **Biometric Automation**: New `fox-fingerprint` command automates enrollment and PAM setup for the Lenovo P15.
- **Dependency Sync**: Integrated Steam (multilib), Bluetooth drivers, and creative tools into the core installer.
- **Thermal Awareness**: Gated heavy dependencies and optimized keybinds for lower resource usage.

### Workflow — Centralized Control
- **FoxML Hub**: Unified control center (**`ALT + Shift + H`**) for Power, Connectivity, and Maintenance.
- **Fast Switching**: Themed **`ALT + Tab`** window switcher and rapid workspace cycling (**`ALT + , / .`**).
- **Audio Switcher**: Dedicated Rofi menu for device switching.

### Creative — Design & Annotation
- **Color Picker**: Integrated `hyprpicker`. Press **`ALT + Shift + P`** to click any pixel on screen and instantly copy its Hex code to your clipboard.
- **Pro Screenshots**: Upgraded the screenshot utility with `swappy`. Region screenshots now open a lightweight GUI editor that always floats in the center of your screen. 
- **User UX**: Fixed the "heavy app" feel by forcing the editor to float. To discard a screenshot, simply hit **`ESC`**. To save and copy, click the **Save** icon.

### Documentation & UX
- **Keybind Overhaul**: Full refresh of `KEYBINDS.md` covering all new desktop-wide features.
- **Aesthetic Refinement**: Perfected Frosted Glass transparency and Waybar alignment.

---

## 2026-05-06 — v1.4.2

Aesthetic refinement and hardware-software synchronization. Fixed transparency issues and improved bar alignment.

### Aesthetics — Perfect Transparency & Glass
- **Rofi Fixed**: Resolved "opacity stacking" where inner elements were making the menus look opaque. Transparency is now applied only at the window level, allowing for a pure frosted glass look.
- **Waybar Alignment**: The top bar now dynamically reads your Hyprland `gaps_out` and sets its margins to match. It now aligns perfectly with your windows for a seamless "floating" aesthetic.
- **Improved Scaling**: Refined font sizes and heights across all resolution profiles to ensure UI elements are proportional and highly readable on 1080p, 1440p, and 4K displays.

---

## 2026-05-06 — v1.4.1

Project cleanup and focus refinement. Removed all Spotify/Spicetify components as requested.

### Cleanup — Spotify Removal
- **Deleted Integration**: Removed `spotify` and `spicetify-cli` from the installer and dependency lists.
- **Removed Themes**: Deleted all Spicetify theme templates (`color.ini`, `user.css`) and mappings.
- **UI Decoupling**: Removed the Spotify Waybar module and associated helper scripts.
- **Keybind Cleanup**: Deleted dedicated Spotify/ncspot keybinds. Standard media keys now use generic `playerctl` commands for maximum compatibility with any running player.

---

## 2026-05-06 — v1.4.0

Complete biometric automation for the FoxML environment.

### Hardware — FoxML Fingerprint
- **`fox-fingerprint`**: New automated setup utility. One command to enroll fingerprints, configure PAM for `sudo`, `login`, and `greetd`, and integrate SSH Keyring auto-unlocking.
- **Biometric Sudo**: Optimized the authentication flow so `sudo` commands can be authorized with a touch, while maintaining a password fallback.
- **SSH Automation**: Integrated GNOME Keyring with Zsh to automatically manage SSH passphrases, allowing biometrics to unlock your Git workflow.

---

## 2026-05-06 — v1.3.9

Integrated hardware support for the Lenovo P15's fingerprint reader.

### Hardware — Fingerprint Support
- **Dependencies**: Added `fprintd` to the base installer.
- **Auto-Detection**: The installer now detects Synaptics (and other) fingerprint readers via `lsusb` and provides a themed setup guide for enrollment and PAM (auth) integration.
- **Git/Sudo Integration**: Unified the hardware with the system auth stack, allowing for fingerprint-authorized `sudo` and SSH key unlocking for GitHub pushes.

---

## 2026-05-06 — v1.3.8

Created a unified "Seamless Navigation" system and addressed critical thermal issues.

### Workflow — Seamless Navigation
- **Unified `ALT + hjkl`**: Navigation is now identical across the entire desktop.
  - **Hyprland**: Moves focus between windows.
  - **Tmux**: Moves focus between panes (no prefix required).
  - **Neovim**: Moves focus between splits.
- **Rapid Workspaces**: Added **`ALT + ,`** and **`ALT + .`** to cycle through workspaces instantly without using the number row.

### Performance — Thermal Management
- **`ncspot` by Default**: Switched the primary music keybind to `ncspot` (terminal client). It uses ~90% less CPU/RAM than the Spotify Electron app, keeping your laptop cool while you work.

---

## 2026-05-06 — v1.3.7

Refined the Rofi experience with Vim-like navigation and a distraction-free Hub.

### Workflow — Vim Navigation
- **Global `Alt + hjkl`**: All Rofi menus (Launcher, Bluetooth, Network, etc.) now support navigation using **`Alt + k`** (Up), **`Alt + j`** (Down), and **`Alt + l`** (Select).
- **Clean Hub**: The **FoxML Hub** and **Power Menu** now have the search bar hidden for a cleaner "app-like" look. Since there is no search conflict, you can navigate these menus with **plain `j` and `k`** and select with **`l`**.

---

## 2026-05-06 — v1.3.6

Aesthetic and functional unification. Upgraded all major UI elements to a frosted glass look and added a central control hub.

### Aesthetics — Frosted Glass Upgrades
- **Rofi**: Dropped opacity to 70% and enabled backdrop blur. The launcher and manager menus now have a beautiful frosted glass aesthetic.
- **Waybar**: Increased transparency (70%) for a lighter, more integrated feel on the desktop.

### Workflow — FoxML Hub & Night Light
- **FoxML Hub**: Introduced a unified control center (**`ALT + Shift + H`**). Access Power, Bluetooth, Network, Wallpapers, and Cleanup from a single menu.
- **Night Light**: Integrated `wlsunset` for an automated earthy blue-light filter. Automatically warms the screen to 4500K after sunset.
- **Interactive Wallpapers**: Added a "Next Wallpaper" option to the Hub to quickly cycle through the FoxML collection with a fade transition.

---

## 2026-05-06 — v1.3.5

Enhanced system management and maintenance utilities.

### Connectivity — Rofi Managers
- **Bluetooth Manager**: Added a themed Rofi menu (**`ALT + Shift + B`**) to power on/off, scan, and connect to paired devices.
- **Network Manager**: Added a Rofi Wi-Fi selector (**`ALT + Shift + N`**) for quick network switching.
- **Keybind Refactor**: Moved `btop` to **`ALT + Shift + T`** (Task manager) to make room for the new connectivity binds.

### Maintenance — FoxML Cleanup
- **`fox-clean`**: New Zsh utility for automated system maintenance. Purges package cache (keeping 2 versions), removes orphans, rotates system logs (7 days), and trims clipboard history (keeping last 100).

---

## 2026-05-06 — v1.3.4

Introduced a suite of themed Quality of Life (QL) upgrades for a smoother desktop experience.

### Hyprland — Clipboard & Power Management
- **Clipboard History**: Integrated `cliphist`. Press **`ALT + V`** to see a searchable Rofi menu of your recent copies (text and images).
- **Power Menu**: Added a themed Rofi power menu. Press **`ALT + Shift + X`** for Shutdown, Reboot, Suspend, Lock, and Logout options.
- **Themed OSD**: Created a new On-Screen Display (OSD) system for Volume and Brightness. Changes now trigger a transient, themed notification with a progress bar that matches the FoxML palette.

### System — Lock Screen Sync
- **Hyprlock Sync**: Replaced legacy `swaylock` references with `hyprlock`. The lock screen now perfectly matches your active theme's colors, wallpaper, and blur settings.
- **Autostart**: Added clipboard background services to the autostart sequence.

---

## 2026-05-06 — v1.3.3

Cleaned up dependencies and removed broken components to ensure a reliable out-of-the-box experience.

### Installer — Dependency Sync
- **Added Core Apps**: Added `lazygit`, `ncspot`, `steam`, and `thunar` to the mandatory `PACMAN_PKGS` list.
- **Multilib Support**: The installer now detects if Steam is requested and automatically offers to enable the `[multilib]` repository in `/etc/pacman.conf` if it's missing (required for 32-bit apps like Steam).
- **Removed Vencord**: Deleted all Vencord (Discord) theme templates and mappings as they were reported as non-functional.

---

## 2026-05-06 — v1.3.2

Refined the Spotify experience for performance and aesthetics. Gated heavy dependencies for better thermals and upgraded the theme to a modern glass look.

### Installer — Thermal Management
- **Gated Spotify**: Spotify and Spicetify are now moved to an optional `--spotify` flag. `./install.sh --deps` no longer installs these heavy apps by default, protecting system thermals on low-spec hardware.

### Spotify — Glassmorphism & UX
- **Theme Upgrade**: Rewrote the Spicetify `user.css` with a "Glassmorphism" aesthetic. Includes `16px` backdrop blur, 70% transparency, and sage (lavender) accents for a more balanced, premium feel.
- **Scratchpad Fix**: Improved `toggle_spotify.sh` to handle "ghost" processes. It now detects if Spotify is running in the tray without a window and restarts it automatically when the keybind (**ALT + Shift + S**) is pressed.
- **Waybar Interaction**: The new Waybar module now supports scrolling to skip tracks and right-clicking to toggle the scratchpad.

---

## 2026-05-06 — v1.3.1

Automated the remaining manual steps for Spotify and Bluetooth support. This release makes the installation process truly "one-command" for users needing music and wireless audio.

### Installer — Spotify & AUR Support
- **AUR Helper Automation**: The installer now detects `yay` or `paru`. If neither is found, it offers to automatically install `yay-bin` from the AUR (requires confirmation or `--yes`).
- **Spotify & Spicetify**: Added `spotify` and `spicetify-cli` to the automated dependency list. When `--deps` and `--yes` are passed, they are installed unattended.
- **Auto-Theming**: The installer now handles the `chmod` permissions for `/opt/spotify` and runs `spicetify backup apply` automatically. Spotify now boots fully themed on the first run.

### Installer — Bluetooth Support
- **Dependencies**: Added `bluez`, `bluez-utils`, and `blueman` (GUI manager) to the base `PACMAN_PKGS`.
- **Auto-Enable**: The installer now automatically enables and starts the `bluetooth` systemd service.
- **Audio Integration**: Integrated with `pavucontrol` and `playerctl` (already in deps) for a seamless wireless audio experience.

---

## 2026-05-06 — v1.3.0

Frictionless first-boot pass. The previous release got the login screen and waybar to the user without manual steps; this one closes the remaining holes that surfaced on a clean Arch box: CLI auth flows that died with `xdg-open ENOENT`, btop launching unthemed because no `btop.conf` existed yet, and the AI CLIs (Gemini, Claude Code) needing a separate manual install pass. Also adds Gemini CLI to the themed-app list and gates the heavy XGBoost source build behind its own flag.

### Installer — XDG default browser + `xdg-utils`
- **`xdg-utils`** added to `PACMAN_PKGS` (Apps + viewers group). Without it, CLI auth helpers — gcloud, gh, oauth flows — try to spawn a browser via `xdg-open` and die with `ENOENT` on a fresh install.
- New post-pacman block runs `xdg-settings set default-web-browser firefox.desktop` automatically (idempotent — writes `~/.config/mimeapps.list`). Guarded on `xdg-settings` being on PATH and `firefox.desktop` existing in `/usr/share/applications`, so re-runs and non-firefox systems are no-ops.

### Installer — AI CLIs via npm
- New global-CLI block in `--deps` installs `@google/gemini-cli` (→ `gemini`) and `@anthropic-ai.agent-code` (→ .agent`) via `sudo npm install -g`. Idempotent: probes PATH for each command name and only installs the missing ones, so re-runs print `✓ Gemini CLI + Claude Code already installed`.
- Sits after the Oh My Zsh step and depends on `nodejs npm` already being in `PACMAN_PKGS` (was added in v1.0.1 for nvim Mason).

### Installer — `--xgboost` flag (source build)
- New top-level `if $INSTALL_XGBOOST;` section, gated behind `--xgboost`. Clones `dmlc/xgboost` (recursive) to `~/code/xgboost`, runs `cmake .. -DBUILD_STATIC_LIB=OFF && make -j$(nproc) && sudo make install && sudo ldconfig`. ~5–10 min compile, opt-in because most users won't need it.
- Idempotent at three levels: skipped entirely if `/usr/local/lib/libxgboost.so` already exists; clone is guarded by an `[[ -d ... ]]` check; the build runs in a subshell with its own `set -e` so a compile failure doesn't abort the rest of the installer.
- Hard-fails early if `cmake` is missing with a hint to run `--deps` first or `pacman -S cmake`.
- `--xgboost` joins `--deps` / `--nvidia` in the unattended-mode sudo-cache check, so `-y --xgboost` doesn't pause for a password mid-build.
- `cmake` added to `PACMAN_PKGS` (new "Build tools" group) so `--deps --xgboost` works in one pass.

### Themes — Gemini CLI integration
- `templates/gemini/settings.json` (placeholders for the FoxML custom theme) and `rendered/gemini/settings.json` (FoxML_Classic-rendered output) added. Uses placeholders already present in both shipping palettes (`BG`, `FG`, `PRIMARY`, `SURFACE`, `YELLOW`, `BLUE`, `GREEN_BRIGHT`, `RED`, `COMMENT`, `DIFF_ADD`, `DIFF_DELETE`).
- New `GEMINI_DIR` placeholder in `TEMPLATE_MAPPINGS` (`mappings.sh`), resolved to `${GEMINI_CONFIG_HOME:-$HOME/.gemini}` by the special handler. Skip-guards added in `install.sh` and `update.sh` so the generic copy loop bypasses the entry — the merge can't be a plain copy or it would clobber `security.auth`.
- `install_specials()` jq-merges the rendered `ui` block into `~/.gemini/settings.json` (`jq -s '.[0] * .[1]'`), so existing keys (auth, MCP servers, model selection) are preserved across re-installs. Falls back to a plain copy if the file doesn't exist yet, or prints a warning if jq fails.
- `update_specials()` reverses the flow: `jq '{ui: .ui}'` extracts only the UI block back into `templates/gemini/settings.json`, keeping security/auth state out of the captured template (so `update.sh` doesn't leak session creds into the repo).
- `AGENT.md` ported from the cpp-rewrite branch — architectural mandates and refactor notes for the future C++ CLI.

### Bugfix — btop on fresh install
- `mappings.sh` btop handler now creates `~/.config/btop/btop.conf` with `color_theme = "foxml"` if the file doesn't exist. Previously the handler only flipped an existing config, so on a fresh box (no `btop.conf` yet — btop creates it on first launch) the theme silently no-op'd: the rendered `foxml.theme` landed in `~/.config/btop/themes/`, but nothing pointed at it. btop auto-fills the rest of the defaults on first run, so the one-line config is enough.
- Three explicit branches: missing file → create; `color_theme = "foxml"` already → noop; `color_theme = ` line present → sed; line entirely absent → append.

---

## 2026-05-06 — v1.2.0

Hands-off install pass. The previous release left three things to the user as manual post-install dances: copy regreet files into `/etc/greetd/` and write `config.toml`, fetch the Catppuccin cursor theme by hand, and re-tune the waybar by hand when moving between a 4K and a 1080p screen. All three are now driven by the installer + a single runtime wrapper.

### Installer — Login screen, cursor, deps
- **`install_greetd()`** (in `mappings.sh`) auto-runs whenever `greetd-regreet` is installed. It deploys regreet css/toml + the staged Hyprland greeter config to `/etc/greetd/`, copies the wallpaper referenced by `regreet.toml` into `/usr/share/wallpapers/` (creating the dir), writes `/etc/greetd/config.toml` to launch Hyprland as the greeter, and `systemctl enable greetd`. Idempotent — preserves a customized `config.toml` and skips when the system already has the right state.
- **`install_catppuccin_cursor()`** fetches `catppuccin-mocha-peach-cursors` from the upstream `catppuccin/cursors` GitHub releases and extracts it to `~/.local/share/icons/` (XDG user dir, no sudo). Runs unconditionally because every theme references this cursor; bails early if already present, if the asset URL can't be resolved, or if `unzip`/`curl` are missing.
- **New `PACMAN_PKGS` entries:** `greetd`, `greetd-regreet` (login screen now installs by default), `gnome-keyring`, `libsecret` (the keyring/secrets stack the autostart line and `seahorse` askpass already assumed was present), `unzip` (consumed by `install_catppuccin_cursor`).
- **`XCURSOR_PATH`** added to `env-init.sh` and `environment.conf` so apps actually find `~/.local/share/icons` — the default path (`~/.icons:/usr/share/icons:/usr/share/pixmaps`) doesn't include the XDG user dir, which is why a previously-extracted Catppuccin theme was silently ignored.

### Waybar — Auto-scaling per monitor
- New `shared/hyprland_scripts/start_waybar.sh` wrapper. Reads `hyprctl monitors -j` for the primary monitor's effective width (pixels ÷ scale), picks one of three profiles, sed-substitutes `__SIZE__` tokens into `~/.config/waybar/{style.css,config}` from `.tmpl` source files, then `exec waybar`.
  - **1080p (≤1920):** font 9.5pt, bar height 32, margin 6, cursor 24
  - **1440p (≤2560):** font 11pt, bar height 40, margin 8, cursor 28
  - **4K (else):** font 12.5pt, bar height 52, margin 12, cursor 32 *(the original 4K-tuned values)*
- `templates/waybar/style.css` and `shared/waybar_config` now carry `__FONT_BASE__`, `__FONT_LOGO__`, `__FONT_STATS__`, `__PAD_WIN__`, `__PAD_MOD__`, `__MARGIN_MOD__`, `__HEIGHT__`, `__MARGIN_BAR__`, `__TRAY_ICON__` placeholders. Mappings deploy them as `style.css.tmpl` / `config.tmpl`; the wrapper writes the live files.
- `--render-only` mode lets `install.sh` produce the live files without launching waybar, so a fresh install ends up with a correctly-sized config before the next Hyprland session.
- Cursor sizing piggybacks on the same profile pick: the wrapper also `hyprctl setcursor`s the running session and `setenv`s `XCURSOR_SIZE` for new children. The hardcoded `XCURSOR_SIZE=30` in `env-init.sh` / `environment.conf` is now a 24 fallback that the wrapper overrides on the first apply pass.
- `startup.sh` calls the wrapper instead of `waybar &` directly.

### Kitty — CJK fallback for the welcome banner
- Added `symbol_map U+3000-U+30FF,U+FF00-U+FFEF,U+4E00-U+9FFF Noto Sans CJK JP` to `templates/kitty/kitty.conf`. The fox banner's kaomoji glyphs (`じ`, `し`, `ノ`, `〵`, etc.) were rendering as tofu boxes because `noto-fonts-cjk` is installed but fontconfig picks Latin-only Noto Sans for those codepoints — kitty needs the explicit map.

### Docs
- README "Login Screen" section: removed the manual `sudo cp` + `tee` post-install dance — now a one-paragraph note that `install.sh --deps` does it.
- README "Post-Install" step 7 (manual greetd copy) dropped.
- `install.sh` summary line for restarting waybar updated to `~/.config/hypr/scripts/start_waybar.sh` so you don't need to remember to bypass the wrapper.

---

## 2026-04-30 — v1.1.0

Major update to the wallpaper system, moving from random rotation to time-of-day "buckets" that match the solar cycle.

### Wallpaper — Time-of-Day Rotation ("Buckets")
- Converted `rotate_wallpaper.sh` from random selection to a bucket-based system. The wallpaper now automatically matches the current hour:
  - **05:00 – 10:00 (Dawn):** `foxml_misty_dawn.jpg`
  - **10:00 – 18:00 (Midday):** `foxml_earthy.jpg`
  - **18:00 – 22:00 (Sunset):** `foxml_sunrise_sunbeams.jpg`
  - **22:00 – 05:00 (Night):** `foxml_night_woods.jpg`
- Added `foxml_night_woods.jpg` (4K) to the wallpaper pool for the night slot.
- Rotation is now **idempotent**: if the correct wallpaper for the current slot is already active, the script exits silently without triggering a fade or notification.
- New `--cycle` flag for manual rotation (ALT+W). It advances one slot forward regardless of the time, allowing manual "mood" changes that persist until the next scheduled bucket transition.

### Systemd — Precise Rotation Timer
- Updated `wallpaper-rotate.timer` to fire exactly on slot boundaries (05, 10, 18, 22) plus a 30-minute mid-hour check.
- Added `Persistent=true` to the timer so missed fires during suspend or power-off are caught up immediately on wake.

### Hyprland — Integration Improvements
- **Autostart:** `autostart.conf` now calls `rotate_wallpaper.sh` directly on startup. This ensures the correct time-of-day wallpaper is applied immediately on login, replacing the old behavior of just restoring the last-saved symlink.
- **Keybinds:** Added `--cycle` to the `ALT+W` bind so manual rotation always changes the image instead of snapping to the current hour's bucket.

---

## 2026-04-28 — v1.0.1

Patch release covering the missing-deps gap discovered immediately post-v1.0.0.

### Installer — Neovim runtime deps
- Added `nodejs`, `npm`, `tree-sitter-cli` to `install.sh`'s `PACMAN_PKGS`. v1.0.0 worked on the verifying box because these were already present from earlier setup, but a fresh Arch laptop hit four cascading errors on first nvim launch:
  - `Copilot.lua: Could not determine Node.js version` → no `node` in `PATH`
  - `Failed to run config for avante.nvim` → cascaded from the copilot failure
  - `mason-lspconfig.nvim` failed to install pyright / bashls / jsonls / yamlls → all are npm-distributed
  - `tree-sitter CLI not found: latex parser must be generated from grammar definitions` → the latex parser on the current `nvim-treesitter` line generates from source

### Neovim — Pin nvim-treesitter to `master`
- `nvim-treesitter` and `nvim-treesitter-textobjects` shipped a major rewrite on their default `main` branches that dropped the `nvim-treesitter.configs` module entirely. Our `init.lua` calls `require("nvim-treesitter.configs").setup({...})`, which errors with `module not found` against `main`.
- Pinned both lazy specs to `branch = "master"` — the legacy v0.x branch that retains the `configs.setup()` API. The migration to the new API is a separate (larger) task; pinning is the right move for a 1.0 stability line.

### Neovim — Drop `latex` parser from `ensure_installed`
- `tree-sitter-cli 0.26.x` changed how `--no-bindings` is passed to `tree-sitter generate` (now requires `-- --no-bindings` to disambiguate from a flag), and `nvim-treesitter` `master`'s build script still calls the old form. The `latex` parser on this line generates from source so it hit the error every nvim launch
- Removed `latex` from the `ensure_installed` list. Other parsers in the list ship pre-compiled grammars and are unaffected. Add `latex` back when nvim-treesitter updates its build script for the 0.26.x CLI

---

## 2026-04-27 — v1.0.0 <3

First tagged release. The earthy palette is settled, the installer is one-command, and a fresh Arch+Hyprland laptop boots into the full FoxML experience without manual surgery. Verified end-to-end on a Dell Precision 5540 (Quadro T2000 + Intel UHD 630).

### Hyprland — NVIDIA Optimus Support (`install.sh --nvidia`)
- New `install_nvidia()` hook routes the entire Wayland session to the discrete GPU on hybrid Optimus laptops where the iGPU bottlenecks under compositor + multi-Chromium + transparent windows + TUIs sharing it
- Pulls `nvidia-open-dkms` + `linux-headers` + `libva-nvidia-driver` (auto-rebuilds on kernel updates), drops env vars into `~/.config/hypr/modules/nvidia.conf`, sets `MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)` in `mkinitcpio.conf`, and appends `nvidia_drm.modeset=1 nvidia_drm.fbdev=1` to the kernel cmdline (systemd-boot only; GRUB/refind users get manual instructions)
- Lists **both** GPUs in `AQ_DRM_DEVICES` (dGPU first as primary render, iGPU second for eDP scanout) — Optimus eDP is hardwired to the iGPU at the hardware level, so dGPU-only would leave Hyprland with no outputs
- Resolves `/dev/dri/by-path/...` symlinks to `/dev/dri/cardN` before joining — the by-path names contain colons (PCI BDF) that shredded Aquamarine's `:`-split device list
- Refuses to touch `mkinitcpio.conf` if `/boot` has under 80 MB free — the nvidia-bearing initramfs is ~135 MB and a half-written `.img` on a full ESP bricks boot
- Idempotent. Backups of every system file edited go to `<file>.foxml-bak`. Recovery instructions print at the end. Battery cost flagged in docs (~5W idle vs ~1-2W on iGPU)
- `bootstrap.sh` auto-detects an NVIDIA dGPU by walking `/sys/bus/pci/devices` for vendor `0x10de` class `0x03*` and appends `--nvidia` for you — works on a freshly-imaged box before pciutils is installed

### Hyprland — Layer Blur, Peach-Glow Active Window, Lockscreen Widgets
- `layerrule` block (Hyprland 0.53+ syntax) blurs rofi/notifications/mako/dunst — launcher and toasts now sit on the desktop instead of pasted on top, matching window blur. Collapsed all four namespaces into one alternation regex
- Active-window shadow tinted to `PRIMARY` (peach) at 0.40 alpha, range 20→24. Inactive stays a neutral dark drop-shadow at 0.30 — focus gets a subtle warm halo without changing the border
- Hyprlock gains a `BAT %` widget (top-right) and a now-playing line (`♪ artist — title` via `playerctl`, exits silently when nothing's playing)
- Stripped `general.conf` of a dead `general{}` block silently overridden by `theme.conf` (it included a `layout=master` conflicting with theme's `dwindle`) and a duplicate `input{}` already owned by `input.conf`

### Hyprland — Window Rules
- Steam launcher/library/store/friends pinned to 85% opacity (exact-match regex on class `steam` so game windows stay opaque) — `[3963a20]` opens Steam to main library view rather than restoring last-active tab
- `engine_gui` (custom trading app) gets the same 85% treatment as `foxml_suite`

### Wallpaper — `awww` (swww fork) replaces hyprpaper
- hyprpaper 0.8.3 and Hyprland 0.54 disagreed on IPC protocol version, so every IPC call failed and rotation always fell back to a kill+restart with a fixed `0.3s sleep` (where the "sometimes wallpaper rotation just doesn't work" came from)
- `awww` talks raw `wlr-layer-shell` so it doesn't care about Hyprland's IPC version. Bonus: real fade transitions on rotation
- Autostart waits for the daemon socket and restores the last-picked wallpaper from `~/.wallpapers/.current`. Templates removed; deploy path simplified

### Waybar — Stats Bar, Power Profile, Updates, Idle Inhibitor
- New CPU/RAM/GPU/DISK modules with temps + totals. CPU resolves `coretemp` by hwmon name (not index, which drifts on reboot). GPU module is **Optimus-aware**: skips `nvidia-smi` while the dGPU is runtime-suspended so polling doesn't keep it awake on battery, and validates exit code + numeric output to handle the post-wake window where the driver is reachable but `nvidia-smi` still errors
- `pacman` updates count via `checkupdates` (hides at 0; click opens the list in kitty); 30-min poll
- `power-profiles-daemon` cycle on click (balanced → performance → power-saver). Pulls `power-profiles-daemon` + `pacman-contrib` into `--deps` and enables the service post-install
- Idle-inhibitor toggle for video / long reads
- Battery tooltip shows time remaining and current draw (W)

### SSH — Themed Askpass via Seahorse
- Pulls `seahorse` via `--deps` so the GTK askpass binary exists; auto-picks up the FoxML GTK theme instead of the bright-blue x11-ssh-askpass dialog
- Exports `SSH_ASKPASS` / `SSH_ASKPASS_REQUIRE=prefer` / `SSH_AUTH_SOCK` to all Hyprland-launched processes (and to interactive shells via `.zshrc` for ssh-into-the-box / TTY logins). Agent socket comes from `gnome-keyring-daemon` already started in `autostart.conf`

### Firefox — XDG Profile Path + Auto-Set Legacy Stylesheet Pref
- Firefox 150 on Arch switched to `~/.config/mozilla/firefox` (XDG-compliant) instead of `~/.mozilla/firefox`. The old profile resolver returned empty and theming silently skipped on fresh installs — now probes both, prefers XDG
- Writes `toolkit.legacyUserProfileCustomizations.stylesheets = true` into `user.js` so `userChrome.css` / `userContent.css` actually load. `user.js` overrides `prefs.js` on every launch, so this can't drift back

### Tooling — zoxide, fd, jq, git-delta, gh, themed delta diff
- `--deps` pulls `fd`, `zoxide`, `jq`, `git-delta`, `github-cli`. `.zshrc` initializes zoxide if installed
- New `templates/git/delta.gitconfig` with a themed `[delta]` block, deployed to `~/.config/git/delta-foxml.gitconfig` and pulled in via `include.path` from `~/.gitconfig` so the user's commit identity stays untouched
- `shared/bin/tmux-git-pane-label`: the missing helper that `.tmux.conf` has always called — pane border was silently empty in git directories. New install loop deploys `shared/bin/*` to `~/.local/bin`

---

### Icons — Papirus-Dark with Catppuccin Mocha Peach folders
- The GTK ini referenced `Papirus-Dark` but the theme files weren't installed, so Thunar (and other GTK apps) silently fell back to Adwaita's default blue folder icons — clashing with the warm peach UI chrome
- Added an install hook that runs the upstream Papirus `install.sh` with `DESTDIR=~/.local/share/icons` (no sudo), then clones `catppuccin/papirus-folders` shallowly to inject the Catppuccin folder SVGs into `Papirus/` (Papirus-Dark and Papirus-Light symlink to it for size dirs, so they inherit), then applies the `cat-mocha-peach` color via the `papirus-folders` helper. Sets `gsettings icon-theme` so GTK apps pick it up immediately
- Folder hue now matches the cursor and the peach `#d4985a` primary

### Cursor — Catppuccin Mocha Peach
- The Hyprland env and GTK settings already pointed at `catppuccin-mocha-peach-cursors` but the theme files were never installed, so everything was silently falling back to the default Adwaita cursor
- Added an install hook in `mappings.sh::install_specials` that fetches the v2.0.0 release zip from `github.com/catppuccin/cursors` into `~/.local/share/icons/` if it's not already present, then sets `cursor-theme`/`cursor-size` via `gsettings` so GTK/Adwaita apps pick it up too
- Catppuccin Mocha Peach (peach hue + dark base) lines up cleanly with the FoxML earthy palette's primary `#d4985a`

### Wallpapers — Curation Pass
- Removed `foxml_redwood_mist.jpg` and `foxml_path_sunbeams.jpg` — both had a person in a brightly-colored jacket in frame; humans break the moody-landscape feel of the FoxML earthy palette
- Removed `foxml_autumn_sunlit.jpg` — central sunburst was too white/washed-out for the muted earthy aesthetic
- Final rotation pool is 3 atmospheric foggy-forest wallpapers (`foxml_earthy`, `foxml_misty_dawn`, `foxml_sunrise_sunbeams`) — all warm-toned mist over dark forest, no sunbursts, no humans

### Wallpapers — Active Wallpaper Tracking
- `shared/hyprland_scripts/rotate_wallpaper.sh` now writes a `~/.wallpapers/.current` symlink each rotation, so anything pointing at it follows the active wallpaper instead of a fixed path
- Pointed `templates/hyprlock/hyprlock.conf` at `~/.wallpapers/.current`. Previously the lock screen always showed `foxml_earthy.jpg` regardless of what the desktop wallpaper had rotated to
- Rotation now drops the current wallpaper from the pool before picking, so consecutive rotations always change image (was hitting the same `RANDOM % N` slot too often with a 6-image pool)
- Added a `notify-send` toast on rotation showing the new wallpaper name

### Hyprland — Manual Rotation Keybind
- `ALT+W` → run `rotate_wallpaper.sh` immediately. Pairs well with the 4h timer for when you just want a different image right now

### Power — Battery-Aware Idle Timeouts
- Split `shared/hyprland_hypridle.conf` into `shared/hyprland_hypridle_ac.conf` (lock 5min, DPMS off 6min) and `shared/hyprland_hypridle_battery.conf` (lock 3min, DPMS off 4min). On battery the panel goes dark sooner, saving juice and tightening burn-in protection
- Added `shared/hyprland_scripts/power_state_watcher.sh`: polls `/sys/class/power_supply/A{C,DP}*/online` every 30s, and on AC↔battery transitions copies the right config into `~/.config/hypr/hypridle.conf` and restarts hypridle
- Added `shared/systemd_user/power-state-watcher.service` (Type=simple, Restart=on-failure, WantedBy=graphical-session.target). The new install hook for `shared/systemd_user/` enables it automatically
- Removed `exec-once = hypridle` from `shared/hyprland_modules/autostart.conf`. The watcher now owns hypridle's lifecycle — running both would race on startup
- Updated `SHARED_MAPPINGS` to deploy the new AC/battery configs to `~/.config/hypr/hypridle-{ac,battery}.conf`

### Installer — Bat Theme Activation
- Added a hook in `mappings.sh::install_specials` that writes `--theme="Fox ML"` to `~/.config/bat/config`. Idempotent — updates the existing line if present, appends if not. `bat` was already getting the FoxML `tmTheme` deployed but had no config telling it to use it, so it was sitting on the default theme

### Cleanup — Stale Backups
- Deleted `themes/FoxML_Classic/palette.sh.bak` and `palette.sh.bak2` — leftovers from earlier palette edits, no longer referenced

### OLED — Burn-In Mitigations
- Tightened `shared/hyprland_hypridle.conf` DPMS-off listener from `600` → `360` seconds, so the lock screen sits visible for at most ~1 minute before the panel goes dark (was 5 minutes of static lockscreen)
- Dimmed `templates/hyprlock/hyprlock.conf` background: `brightness 0.75 → 0.10`, `vibrancy 0.25 → 0.10`, `contrast 1.15 → 1.05`, and bumped `blur_size 8 → 12` / `blur_passes 3 → 4`. The lock screen still shows the wallpaper but at near-black luminance during its short window before DPMS off
- Added `ALT+B` waybar toggle (`killall -SIGUSR1 waybar`) in `shared/hyprland_modules/keybinds.conf` so the always-on top bar — the largest static-pixel surface on a tiling-WM setup — can be hidden on demand

### Wallpapers — Rotation
- Added `shared/hyprland_scripts/rotate_wallpaper.sh`: random pick from `~/.wallpapers/`, excluding dotfiles and `cave_data_center*` (other-theme image). Tries hyprpaper IPC first, falls back to a kill-and-relaunch when IPC returns "invalid hyprpaper request" on older versions
- Added `shared/systemd_user/wallpaper-rotate.{service,timer}` — fires 10 min after boot, then every 4 hours
- Extended `mappings.sh::install_specials` to copy any `shared/systemd_user/*.{service,timer}` units into `~/.config/systemd/user/`, run `daemon-reload`, and `enable --now` every `.timer`. Generic, so future user units drop in without editing the installer

### Wallpapers — Curated Earthy 4K Set
- Replaced `shared/wallpapers/foxml_earthy.jpg` with a 4K upscale (`1920x1280` → `3840x2560`) produced by `waifu2x-ncnn-vulkan` with the `models-upconv_7_photo` model. Native-res on a 4K eDP-1 panel; previous version was being bilinearly stretched by 2× at display time
- Added 5 palette-matched 4K wallpapers from Unsplash: `foxml_misty_dawn`, `foxml_autumn_sunlit`, `foxml_redwood_mist`, `foxml_path_sunbeams`, `foxml_sunrise_sunbeams` — all warm-fog / golden-hour / autumn forest tones that match the FoxML earthy palette (peach `#d4985a`, sage `#8a9a7a`, dark `#1a1214`)
- Removed `foxml.png`, `foxml-alt.jpg`, `foxml-alt-original.jpg`, `new2.jpg`, `new_tmp.png`. The first two were the OG vaporwave/Firewatch-purple FoxML wallpapers — they fit the original purple palette but clash with the current earthy one. The other three were duplicates (matching md5 of `foxml-alt.jpg`) or staging temp files

### Installer — btop Theme Activation
- Added a sed hook in `mappings.sh::install_specials` that flips `color_theme` in `~/.config/btop/btop.conf` to `"foxml"`. Idempotent (skips if already set). Previously `install.sh` deployed `templates/btop/foxml.theme` to `~/.config/btop/themes/` but never told btop to use it, so the theme file sat unused until manually selected. `btop.conf` itself stays user-owned (not templated) since btop rewrites it on every config change

---

## 2026-04-24

### Installer — CJK + Emoji Font Fallback
- Added `noto-fonts`, `noto-fonts-cjk`, `noto-fonts-emoji` to `PACMAN_PKGS` so the welcome-banner cat (じ し ノ kana) and other Unicode glyphs that Hack Nerd Font doesn't cover fall back to Noto instead of rendering as tofu boxes

### Installer — One-Command Bootstrap
- Added `bootstrap.sh` for `curl | bash` install on a fresh Arch+Hyprland laptop. Caches sudo upfront, installs `git`/`curl` if missing, clones the repo to `~/FoxML_Workstation` (or `git pull`s if already there), then runs `install.sh THEME --deps --yes`
- Added `-y` / `--yes` flag to `install.sh`. In yes-mode every `read -p` prompt is skipped, `pacman -S` runs with `--noconfirm`, oh-my-zsh installs unattended, and the theme defaults to `FoxML_Classic` if no name is given
- `--yes` primes the sudo cache via `sudo -v` and keeps it alive in a background loop so dep install runs unattended end-to-end
- Updated README Quick Start to lead with the one-liner; manual `git clone && ./install.sh` flow is documented as the read-before-running alternative

### Hyprland — Frictionless First-Boot
- Added `shared/hyprland.conf` — the missing main config that sources every module under `~/.config/hypr/modules/` (skipping `main_mod.conf` and `hyprlock.conf`). Without this, fresh installs left Hyprland on its default example config and none of the FoxML modules ever loaded
- Mapped `hyprland.conf` and the four `launchers/toggle/*.sh` scripts in `SHARED_MAPPINGS` so they actually install
- Made `monitors.conf` portable: `monitor = , preferred, auto, 1` with per-machine overrides commented out, instead of hardcoding a Surface Pro `2736x1824@60` that broke on every other panel

### Hyprland — Hyprland 0.54+ Syntax Migration
- Converted `scratchpads.conf` and `workspace_layout.conf` to the new `windowrule { match:class = ...; float = yes; ... }` block syntax. The old `windowrule = float, class:^(yazi)$` form errors out on 0.54+
- Removed deprecated `general:no_border_on_floating` from `general.conf`
- Replaced `noborder` (no longer a valid field) with `border_size = 0` inside the yazi rule
- Cleaned `workspace_layout.conf`: dropped duplicate `kitty --title Terminal1` exec-once (already in autostart) and the wrong `monitor:DP-1` workspace binding

### Hyprland — Removed Conflicting/Orphan Files
- Deleted `main_mod.conf` (a near-duplicate of `keybinds.conf` that registered every binding twice — `ALT+ENTER` was launching two terminals)
- Deleted orphan `hyprland_modules/hyprlock.conf` (hyprlock-syntax sitting in the Hyprland modules dir; the real hyprlock config is rendered from `templates/hyprlock/hyprlock.conf`)
- Commented out `pulseaudio --start` in `autostart.conf` — modern Arch defaults to pipewire via systemd-user

### Scripts — Region Screenshot
- Added `shared/hyprland_scripts/screenshot.sh` (grim + slurp + wl-copy + notify-send), saving to `~/Pictures/Screenshots`
- Updated `keybinds.conf` so `ALT+SHIFT+O` points at the new script instead of the never-shipped `~/screenshot/screenshot.sh`

### Installer — Dependencies & Plugin Install
- Expanded `PACMAN_PKGS` with everything the configs actually reference: `ttf-hack-nerd` (default font), `mako`, `hypridle`, `grim`, `slurp`, `wl-clipboard`, `playerctl`, `brightnessctl`, `pavucontrol`
- Moved zsh plugin clones (`zsh-syntax-highlighting`, `zsh-autosuggestions`, `zsh-completions`) out of the `--deps` block — they now install whenever oh-my-zsh is present, so a fresh install never opens to "[oh-my-zsh] plugin not found"
- Filtered the wallpaper copy loop to image extensions (`*.{jpg,jpeg,png,webp}`) so `README.md` stops landing in `~/.wallpapers/`

### Waybar — Strip Broken Modules
- Removed `custom/system_health`, `custom/media`, `custom/weather` modules whose backing scripts were never shipped (they spammed `No such file or directory` in waybar's stderr)
- Dropped hardcoded `"bat": "BAT1"` so the battery module auto-detects (`BAT0` / `BAT1` / etc.)

### Cleanup
- Deleted empty `shared/hyprland_scripts/set-theme.sh` (just a `#!/bin/bash` shebang)
- Deleted empty `shared/hyprpaper.conf` stub (the real config is rendered from `templates/hyprpaper/hyprpaper.conf`)

---

## 2026-04-12

### Shell — Git Workflow Functions
- Added `shared/zsh_git.zsh` with git workflow shortcuts that complement the Oh My Zsh `git` plugin
- `gpush` — push current branch, auto-sets upstream on first push
- `gnew` — create + switch to new branch (prompts for name if omitted)
- `gsave` / `gquick` — stage all + commit in one shot / WIP checkpoint with timestamp
- `gundo` / `gamend` — undo last commit (soft reset) / amend last commit with new changes
- `gbr` / `grecent` — fzf branch switcher / list recent branches with relative dates
- `gsync` / `gclean` — rebase on latest main / delete merged branches
- `gstash` / `gpop` — named stash / fzf stash picker
- `gtoday` / `gds` — today's commits / diff staged changes
- Added mapping in `mappings.sh` and source line in `.zshrc` template
- Removed stale `prompt.zsh`, `gradient.zsh`, `async.zsh` references from README (files were deleted in 2026-03-16)

---

## 2026-03-28

### Theme — New Cave Data Center Theme
- Added second theme: Cave Data Center — dark navy palette with blue (`#2ea3f2`) and gold (`#ffb200`) accents, inspired by HRT's website colors
- Themes can be hotswapped with `./swap.sh`, switching nvim, kitty, hyprland, waybar, tmux, zsh, wallpaper, and all other configs in one command

### Theme — Templatize Nvim & Wallpaper
- Nvim `init.lua` palette table now renders from `palette.sh` instead of hardcoded hex values — all themes share one template
- Added `NVIM_BG_HL`, `NVIM_SEL`, `WARM`, `SAND`, `WHEAT`, `CLAY` palette variables for nvim-specific colors
- Moved `hyprpaper.conf` from shared to templates with `{{WALLPAPER}}` variable so wallpaper swaps per-theme
- Added `SHOW_BANNER` toggle to show/hide the FOXML block text in the zsh welcome (cat stays)
- Added `SHOW_WELCOME` toggle to disable the entire welcome splash per-theme
- Added 4K dark blue textured wallpaper for Cave Data Center

### Theme — Render Engine
- Added `WARM`, `SAND`, `WHEAT`, `CLAY`, `NVIM_BG_HL`, `NVIM_SEL` to `render.sh` hex variable lists (forward and reverse)
- Added `SHOW_WELCOME`, `SHOW_BANNER`, `WALLPAPER` to `render.sh` string variable lists

---

## 2026-03-20

### Shell — New `trade` Alias
- Added `trade` alias that disables screensaver/DPMS before running `./engine`, then re-enables it after

---

## 2026-03-19

### Bat — Expanded tmTheme for Richer Syntax Highlighting
- Expanded bat theme from ~15 to ~40 TextMate scope rules to match Neovim's highlighting
- Added distinct colors for: string escapes/regex/interpolation (cyan), preprocessor directives (cyan), define/macro keywords (pink), booleans (bold peach), return keyword (bold lavender), import keywords (cyan), operators (lavender), variable parameters (yellow_br), variable builtins/self/this (pink), namespaces/modules (pink), brackets (sand), punctuation separators/delimiters (peach), constructors, function macros, type qualifiers, inherited classes, decorators/annotations
- Added language-specific scopes: JSON/YAML/TOML keys (green), CSS properties/selectors/values/units, shell variables
- Added markup scopes: bold, italic, strikethrough, code/raw blocks (green), list markers (pink), diff changed (yellow), deprecated (italic yellow)
- Updated template, rendered Classic, and installed theme; rebuilt bat cache

---

## 2026-03-19

### Nvim — Fix indent-blankline Startup Error & Deprecation Cleanup
- Fixed indent-blankline crash on startup — `RainbowIndent` highlight groups are now defined before `ibl.setup()` runs (previously only existed in `apply_foxml_theme()` which runs later)
- Replaced deprecated `lsp_fallback = true` with `lsp_format = "fallback"` in conform.nvim config
- Replaced deprecated `vim.diagnostic.goto_prev`/`goto_next` with `vim.diagnostic.jump()` (Neovim 0.11+)
- Removed duplicate `signcolumn` setting (was set twice, consolidated to `"yes:2"`)

---

## 2026-03-17

### Font — Templated FONT_FAMILY + Switch to Hack Nerd Font
- Added `FONT_FAMILY` variable to `palette.sh` — font is now configurable per-theme
- Added `FONT_FAMILY` to render engine (`render.sh`) for forward and reverse rendering
- Replaced hardcoded `JetBrainsMono Nerd Font` with `{{FONT_FAMILY}}` in all templates: kitty, waybar, rofi, dunst, mako, regreet CSS, spicetify, zathura, hyprlock
- Updated shared configs (GTK 3/4 settings, regreet.toml, hyprland general/hyprlock) to Hack Nerd Font
- Default font changed from JetBrainsMono Nerd Font → Hack Nerd Font (blockier, sturdier)
- Documented font customization in README

---

## 2026-03-16

### Nvim — Dashboard Fox Art
- Replaced plain ASCII `FoxML` logo with the fox character from zsh welcome splash in snacks dashboard

### ReGreet — FoxML Login Screen
- Added ReGreet (GTK4 greetd greeter) template with full FoxML theming
- CSS theme: dark background with wallpaper, peach borders/accents, sharp corners, frosted login box
- Config: wallpaper background, dark theme, peach cursor, Papirus-Dark icons, JetBrains Mono font
- Added template and shared mappings for install/sync support
- To switch from tuigreet: `sudo pacman -S greetd-regreet` then update `/etc/greetd/config.toml`

### Nvim — Gitsigns Blame, Beacon, Notifications Cleanup
- Added inline git blame on current line (author, relative time, summary) via gitsigns `current_line_blame`
- Added beacon.nvim — cursor flashes peach on large jumps for visual tracking
- Replaced nvim-notify with snacks.nvim minimal notifier (single-line, bottom-right, less screen clutter)
- Removed nvim-notify plugin dependency from noice
- Synced cursor blink: removed `guicursor` blink to match kitty's `cursor_blink_interval 0`
- Added `BeaconDefault` and `GitSignsCurrentLineBlame` highlight groups to FoxML colorscheme

### Tmux — Pane Border Shows Running Command
- Pane border format now includes `#{pane_current_command}` (shows `nvim`, `python`, `zsh`, etc.)

### Cursor — Peach Theme + Size Fix
- Hyprland cursor theme: `catppuccin-latte-pink-cursors` → `catppuccin-mocha-peach-cursors`
- Kitty terminal cursor color: `SECONDARY` (dusty rose) → `PRIMARY` (peach)
- GTK 3/4: added `gtk-cursor-theme-name=catppuccin-mocha-peach-cursors` and `gtk-cursor-theme-size=30`
- Fixed cursor size mismatch (GTK apps were 30, Hyprland was defaulting smaller) — set `XCURSOR_SIZE=30` in `env-init.sh` for early session export
- Added Hyprland `cursor {}` section to `general.conf`

### Zsh — Hardening, Cleanup & Dead Code Removal
- Removed `async.zsh` (never sourced, callback never registered, output unused)
- Removed `gradient.zsh` (`gradient_text()` defined but never called anywhere)
- Removed `prompt.zsh` (bash-style PS1 fallback that doesn't work in zsh — caramel handles everything)
- Removed `welcome.zsh.bak` (identical to `welcome.zsh`)
- Removed duplicate `list-colors` zstyle from `colors.zsh` (already set in `.zshrc`)
- Cleaned up `mappings.sh` to remove references to deleted files
- Template dir reduced from 8 files to 3 focused ones: caramel theme, colors, welcome

### Zsh — Shell Options & History
- Added `NO_CLOBBER` (prevents accidental file overwrites with `>`, use `>|` to force)
- Added `HIST_IGNORE_DUPS`, `HIST_IGNORE_SPACE`, `EXTENDED_HISTORY`, `SHARE_HISTORY`, `HIST_REDUCE_BLANKS`
- Added explicit `HISTFILE`, `HISTSIZE=50000`, `SAVEHIST=50000`
- Added `typeset -U path PATH` to deduplicate PATH in nested shells/tmux

### Zsh — fzf & Completions
- Added `zsh-completions` plugin (extended completions for docker, systemctl, etc.)
- Added `zsh-completions` to `--deps` installer in `install.sh`
- fzf now uses `fd` as default command (faster, respects `.gitignore`)
- Added hidden preview panel to fzf (`ctrl-/` to toggle — bat for files, eza for dirs)

### Zsh — Robustness
- Tmux auto-attach now skips IDE terminals (VS Code, IntelliJ) to prevent hijacking embedded terminals
- `todo()` now checks for duplicates before adding
- Welcome splash now shows active theme name next to the fox (e.g. `▸ FoxML Classic`)

### Caramel Theme — Configurable Timer
- Elapsed time threshold is now configurable via `CARAMEL_CMD_THRESHOLD` (defaults to 3s)

---

## 2026-03-14

### Firefox — Earthy Theme Overhaul
- Rewrote `userContent.css` for Firefox 140+ (new CSS variable names, modern card selectors)
- Forced `border-radius: 0` globally on new tab page — kills rounded cards/buttons
- Swapped plum `BG_ALT` (#2d1a2d) for warm dark brown (#2a2018) in both `userChrome.css` and `userContent.css`
- Added theming for `about:preferences` and `about:addons` pages
- Added follow/topic button, weather widget, and link color overrides

### Thunar — Transparency & Earthy Styling
- Added GTK CSS transparency for Thunar (`rgba` bg at 85% opacity, no compositor opacity — avoids rubberband trail artifacts)
- Filenames use peach (`PRIMARY`) for readability on transparent background
- Sidebar labels use `FG_PASTEL`, selected sidebar items use peach
- Icon view cells: removed bordered boxes, selection highlight uses warm clay (`rgba(176,96,58,0.35)`)
- Rubberband (drag selection) uses wheat fill (`rgba(212,180,131,0.20)`) with wheat border

### Hyprland — Window Rule Syntax Fix
- Migrated Thunar opacity rule to Hyprland 0.54 `match:class` syntax (old `class:` field caused parse errors)
- Removed compositor opacity rule for Thunar (caused rubberband rendering artifacts on some GPUs)

### Nvim — External Edit QOL (Claude Code / git)
- Added `autoread`, `undofile`, `swapfile=false`, `writebackup=false`, `autowriteall` options
- Added `checktime` autocmds on `FocusGained`, `BufEnter`, `CursorHold`, `CursorHoldI` — buffers now auto-reload when changed on disk (e.g. by Claude Code or `git checkout`)
- Added `FileChangedShellPost` notification so reloads aren't silent
- Disabled swap files (git is the safety net) and enabled persistent undo across sessions

---

## 2026-03-13

### Neovim — Struct Field Color Variation & LSP Token Fix
- Added color variation for struct member access chains (e.g. `pool->slots[index].price.price`)
- Fields/properties (`@variable.member`, `@property`) now use `green` (#6b9a7a) instead of blending with foreground
- Punctuation delimiters (`.`, `;`) now use `peach` (#c4956e) for visible structure
- Brackets (`[]`, `()`) now use `sand` (#a89a7a) for subtle differentiation
- Added `@lsp.typemod.variable.member` highlight (+ `.c`/`.cpp` variants) — fixes clangd semantic tokens overriding treesitter colors after ~2s
- LSP property/member groups now `link` to treesitter groups so only one color change is needed
- Added `sand` (#a89a7a) to palette

### Cohesive Earthy Theme — Full System Sync
- Removed all remaining neon pink/pastel references from shared configs, READMEs, and comments
- Fixed Hyprland `general.conf` — hardcoded neon pink borders updated to earthy peach/wheat gradient
- Fixed Hyprland `theme.conf` — updated color palette comment block and active border to earthy tones
- Migrated all `windowrulev2` → `windowrule` across scratchpads, workspace_layout, and rules configs (deprecated in Hyprland 0.54+)
- GTK-4 settings: switched from `Catppuccin-Mocha-Pink-Standard` to `Adwaita` dark (lets custom `gtk.css` apply)
- Icon theme: switched from `Papirus-Dark-Pink` to `Papirus-Dark` with palebrown folder color
- Firefox: enabled `toolkit.legacyUserProfileCustomizations.stylesheets` on active profile, deployed earthy `userChrome.css` and `userContent.css`
- Updated FoxML Classic theme README with current earthy palette values
- Cleaned up firefox template comments (pastel pink → tinted)

### Palette Overhaul — Neon → Earthy
- Reworked entire FoxML Classic palette from neon pastels to muted earthy tones
- Primary: `#f4b58a` → `#c4956e` (peach), Secondary: `#f5a9b8` → `#b8967a` (warm pink → dusty rose), Accent: `#9a8ac4` → `#8a9a7a` (lavender → sage)
- FG: `#f5f5f7` → `#d5c4b0` (cold white → warm cream), all ANSI colors shifted to lower-saturation earthy variants
- ANSI 256-color codes updated for zsh prompts/gradients (pink rainbow → clay/wheat/sage gradient)
- FZF, ZSH command highlight, OK/WARN semantic colors all updated to match
- Kitty opacity raised from 0.45 → 0.6 for readability with new palette

### Tmux — Pane Visibility Rework
- Active border now uses PRIMARY peach (`#c4956e`) with bold (thicker border)
- Removed solid background on active pane — all panes fully transparent (`bg=default`)
- Dimmed inactive pane text from `#555555` → `#3a3a3a` for stronger active/inactive contrast
- Hyprland active window border updated: peach → wheat gradient

### Nvim — Transparency & Separator Fixes
- Fixed `colorful-winsep.nvim` config: plugin API changed from `hi = { fg = ... }` table to `highlight = "..."` string — was silently falling back to default lavender `#957CC6`
- Active window separator now renders earthy wheat (`#b8a87e`)
- Visual selection background warmed from `#2d1f27` → `#3d2a1e` (muted plum → warm brown)
- `NormalNC` (inactive windows) set to transparent instead of solid bg
- `StatusLine`/`StatusLineNC` backgrounds set to transparent
- `VertSplit`/`WinSeparator` changed from solid `bg_deep` to wheat fg on transparent bg
- Variables (`@variable`) changed from lavender to default fg for cleaner code readability

### Zsh — Simplified Welcome Splash
- Condensed welcome screen: removed system info block (kernel, shell, WM, terminal, battery)
- Cleaner date/time format, compact FoxML ASCII banner
- Updated color comments to match earthy palette names

### Misc
- Wallpaper changed to `foxml_earthy.jpg`
- Removed packages line from fastfetch config
- Updated README screenshots (terminal, nvim, nvim+avante) — removed outdated desktop screenshot
- Updated README to remove old desktop screenshot reference

### Neovim - Syntax Color Refinement & Window Fixes
- Improved syntax color differentiation: types (peach italic), functions (peach), variables (lavender), parameters (cyan), members (soft pink), operators (pink), keywords (pink bold)
- Updated LSP semantic token highlights to match treesitter palette — fixes colors shifting 1-2 seconds after file open when clangd attaches
- Added `ColorScheme` autocmd to re-apply FoxML theme after plugin/treesitter loads
- Fixed which-key popup transparency — added `WhichKeyNormal` highlight group with solid `bg_deep` background
- Set inactive window background to solid `bg` — provides visual distinction from active (transparent) window
- Removed `tint.nvim` plugin (inactive window dimming)
- Updated README screenshots (nvim 3-pane layout + avante sidebar)

### Neovim - Custom FoxML Colorscheme (Tokyo Night removed)
- Replaced `folke/tokyonight.nvim` dependency with a fully self-contained FoxML colorscheme — all highlights now live in `apply_foxml_theme()` inside init.lua
- Added `local P = { ... }` palette table (32 colors) as single source of truth — all hex values reference `P.xxx` instead of repeating strings
- Added built-in Vim syntax groups (~35): Comment, String, Function, Keyword, Type, Statement, PreProc, Special, etc.
- Added full diagnostics coverage (~18): Error/Warn/Info/Hint with undercurl underlines, virtual text, and sign variants
- Added Treesitter highlight groups (~55): all @function, @keyword, @string, @constant, @markup, @tag families
- Added LSP semantic token groups (~21): @lsp.type.class, @lsp.type.function, @lsp.mod.deprecated, etc.
- Added Diff & Spell groups (8): DiffAdd/Change/Delete/Text, SpellBad/Cap/Rare/Local with undercurl
- Added terminal ANSI colors (16): vim.g.terminal_color_0 through _15 mapped to FoxML palette
- Registered as proper colorscheme via `vim.g.colors_name = "foxml"`
- Converted all plugin opts (bufferline, notify, scrollbar, colorful-winsep, lualine) from hardcoded hex to `P.xxx` references
- Removed tokyonight from lazy-lock.json
- Changed default fg from cold white `#f5f5f7` to warm coffee cream `#d5c4b0`
- Fixed sidebar transparency — neo-tree, Avante, Trouble, and aerial panels now get solid `bg_deep` backgrounds via `NormalSidebar` + FileType autocmd (prevents terminal opacity bleeding through)
- Removed transparent gap between splits — WinSeparator and VertSplit use solid `bg_deep` on both fg/bg, fillchars vert changed to space
- Removed global `winblend = 15` (was making all floats semi-transparent); kept `pumblend = 15` for popup menu only
- Improved Avante edit (`<leader>ae`) UX — removed Visual blend for solid selection highlight, brighter prompt input background, bolder inline hints

### Neovim - Avante & Copilot QoL
- Set `auto_add_current_file = false` — visual selections now send only the selected code to Copilot, not the entire file
- Added `<leader>ae` — edit selection in-place with Avante (visual mode)
- Added `<leader>ar` — refresh Avante response
- Added `<leader>aS` — stop Avante generation
- Enabled `auto_apply_diff_after_generation` — diffs apply automatically after Avante responds
- Show model name in Avante sidebar header
- Bumped Avante history token limit to 8192 for longer conversations
- Added 150ms debounce to Copilot suggestions to reduce keystroke lag
- Disabled Copilot ghost text in Avante input/sidebar buffers
- Added Copilot status indicator in lualine (green = ready, yellow = thinking, red = error)
- Fixed `vim.tbl_filter` deprecation warnings → `vim.iter():filter():totable()` (nvim 0.11+)
- Suppressed `vim.lsp.buf_get_clients` deprecation from project.nvim/telescope (upstream issue)
- Full FoxML theme for all Avante highlights — sidebar, titles, buttons, spinners, conflict markers, task status, thinking indicator
- Themed missing core UI groups: PmenuSbar/Thumb, CurSearch, Folded, TabLine, StatusLine, WildMenu, Title, Directory, Question, SpecialKey, NonText, Conceal
- Themed noice message split window and :messages highlights (MsgArea, WarningMsg, ErrorMsg, ModeMsg, MoreMsg)

---

## 2026-03-12

### Neovim - Visual Polish (Round 2)
- Added **noice.nvim** — floating cmdline popup, search popup, and message routing (replaces bottom cmdline)
- Added **nvim-notify** — animated notification popups with FoxML-themed borders
- Added **nvim-colorizer** — renders hex colors inline with their actual color
- Added **rainbow-delimiters.nvim** — colors nested brackets/parens in rotating FoxML palette (peach → pink → mint → yellow → cyan → red)
- Added **colorful-winsep.nvim** — highlights active window border in peach when using splits
- Added **nvim-scrollbar** + **nvim-hlslens** — scrollbar showing diagnostics, git changes, and search hits; search match counter overlay
- Added **tint.nvim** — subtly dims inactive splits so focused window stands out
- Full FoxML palette highlights for all new plugins (noice, notify, rainbow delimiters, scrollbar, hlslens)
- Disabled colorizer for C/C++/H files — hex constants like `0xFFFFFFFF` no longer get painted as literal colors
- Made number/hex literals bold warm yellow for better glow against dark background
- Backed up pre-polish config as `init.lua.bak`

### Neovim - Visual Polish
- Custom FoxML lualine theme — peach normal, mint insert, pink visual, red replace, yellow command
- Replaced encoding/fileformat statusline clutter with active LSP server name
- Enabled native smooth scrolling (`smoothscroll`)
- Enabled cursorline highlight and guicursor (block/beam/blink)
- Added warm-tinted window separator using `bg_highlight`
- Fixed deprecated `vim.loop` → `vim.uv` calls

### Removed FoxML Paper Theme
- Removed WIP light theme (FoxML Paper) — keeping only FoxML Classic
- Cleaned up README references to Paper

### Neovim - Window & Buffer Keybind Fixes
- `Space q` is now smart — won't leave neo-tree filling the whole screen when closing the last file window
- `Space bd` no longer silently fails on empty/unnamed buffers
- Added `Space o` to unsplit (close all other windows, keep current)

### Multi-Theme Hub Restructure
- Converted from single-theme repo to **multi-theme hub** with template-based rendering
- All 23+ app configs are now **templates** with `{{COLOR}}` placeholders — one set of configs, any number of themes
- Each theme is just a `palette.sh` file defining ~60 color variables; adding a new theme = writing one file
- New render engine (`render.sh`) handles hex, RGB decomposition, ANSI codes, and metadata substitution
- New `mappings.sh` with source→destination mappings and special handlers (Firefox, Cursor, Spicetify, Bat, Hyprland)
- New `swap.sh` — theme swapper with 24-bit truecolor color swatches in terminal
- Shared (non-color) files split into `shared/` directory
- Updated install.sh and update.sh to work with the template system
- Reverse rendering: `update.sh` pulls system configs back into templates by replacing colors with placeholders

### Docs
- Friendly note added to README for fellow CS students

### Neovim - Plugin Cleanup
- Removed `oil.nvim` — neo-tree covers all file management needs
- Remapped `-` to reveal current file in neo-tree sidebar
- Removed Oil highlight groups and keybinds

### Docs
- Added `CHANGELOG.md` with full project history
- Added `/changelog` skill for auto-updating changelog
- Expanded neo-tree keybinds in `KEYBINDS.md` (navigation, file ops, opening, help)
- Added nvim screenshot to README

### Neovim - RAM Reduction & IDE Features
- Dropped `noice.nvim`, `neoscroll.nvim`, `neotest-ctest`, standalone `dressing.nvim`
- Disabled snacks.nvim notifier
- Lazy-loaded 15+ plugins (copilot, vimtex, neotest, diffview, undotree, trouble, spectre, aerial, dap, cmake-tools, overseer, toggleterm, project.nvim)
- Added **neo-tree.nvim** — file tree sidebar (`Space e`)
- Added **bufferline.nvim** — buffer tabs at top (`Shift+H/L` to cycle, `Space bd` to close)
- Added window management keybinds (`Space v/s` for splits, `Ctrl+Arrow` to resize)
- Moved neotest setup into lazy config function
- Removed all `Noice*` highlight groups, added `NeoTree*` highlights in Fox ML palette
- Silenced project.nvim CWD notifications

### Neovim - QoL Improvements
- `Ctrl+h/j/k/l` to navigate splits directly
- `Alt+j/k` in visual mode to move lines up/down
- `Ctrl+d/u` and `n/N` keep cursor centered
- `Esc` clears search highlights and exits terminal mode
- Visual mode `<`/`>` indent without losing selection
- `Space q` to close window
- Auto yank highlight (200ms flash)
- Auto cursor position restore on file reopen
- Auto trailing whitespace strip on save
- Smarter `Space bd` — prevents neo-tree from expanding when closing last buffer

### Docs
- Added nvim screenshot to README
- Updated KEYBINDS.md with neo-tree, bufferline, split, and QoL keybinds
- Removed neoscroll references from KEYBINDS.md
- Updated README nvim section (removed noice, added neo-tree/bufferline)

---

## 2026-03-11

### Neovim - AI & Plugin Expansion
- Added copilot.lua (inline ghost-text completions, `Ctrl+l` to accept)
- Added avante.nvim (Cursor-style AI chat panel with Copilot provider)
- Added noice.nvim, snacks.nvim (dashboard), dropbar.nvim (breadcrumbs)
- Added mini.ai, flash.nvim, nvim-surround, harpoon, undotree
- Added diffview.nvim, nvim-spectre, lazygit.nvim, persistence.nvim
- Added friendly-snippets, zen-mode.nvim, clangd_extensions.nvim
- Added neotest + gtest/ctest adapters, cmake-tools, overseer, toggleterm
- Added DAP debugging with CodeLLDB via mason-nvim-dap
- Added treesitter textobjects and context
- Fixed copilot keybinds: Alt to Ctrl (Alt conflicts with Hyprland mainMod)
- Fixed Ctrl+[ breaking Escape, switched to Ctrl+k/j for copilot prev/dismiss

### Theme Polish
- Fixed background color mismatches and typos across theme configs
- Added zathura and bat themes
- Enhanced hyprland animations
- Full Fox ML palette applied to all 60+ nvim plugins

### Hyprland
- Reduced blur intensity (size 2, 1 pass)
- Synced repo with live system configs

### Wallpaper
- Warm-shifted wallpaper to match palette
- Adjusted kitty opacity for readability
- Reverted wallpaper to original after testing

---

## 2026-03-06

### Hyprland & System
- Added hyprland, waybar, mako, fastfetch, launcher configs
- Added KEYBINDS.md with full hyprland and tmux reference
- Cleaned up launcher scripts

---

## 2026-02-22

### Shell
- Added full zsh config (caramel theme, aliases, colors, welcome screen)
- Added screenshots to repo and README
- Added pacman deps and zsh install to installer
- Added zsh config backup to update script

---

## 2026-02-18

### Initial Release
- First commit with Fox ML theme files
- Kitty, tmux, nvim, GTK, rofi, spicetify, vencord, firefox configs
- Install script and wallpapers
