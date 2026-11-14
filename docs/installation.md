# Installation reference

[← Back to the README](../README.md)

Install paths, module selection, flags and first-run setup.

Interactive installation requires a terminal for both input and output. The entry wrapper checks this before
self-update, sudo, building deployment binaries or copying files; it and the native orchestrator consume the same
input-policy table. `--yes` explicitly chooses unattended defaults. Selecting a preset or module alone does not
waive prompts. Help, version, dry-run and wizard-demo bypass update and deployment, although the wrapper may
build the orchestrator in the repository. Automated checks still use disposable deployment fixtures.

## Work integrations on a fresh install

The wrapper builds and installs native tools before deploying configuration. The default `symlinks`, `specials`,
`fox_aliases` and `drawer` modules deploy the notebook and its palette, Neovim modules (including `work_events.lua`),
pi's lifecycle/job adapter, drawer pages and compatible command names. The mod folder is added to Claude settings
after its manifest exists, while preserving other mod folders and user settings. A new attention page is offered
once to an existing user menu; project roots, favorites and deliberately removed items stay owned by the user.
The default `integrations` module finalizes generated client version stamps and an installed-file manifest after
the normal deployment. The same native inventory and backup helpers drive scoped updates; no app is restarted.

### Update only the work integrations

Build the current tools with `make`, then preview with:

```sh
desk-work integrations plan
```

The JSON lists destinations, changes, expected versions and a `plan` token. It stages rendering in a temporary
folder without deploying anything. Apply that exact preview, using its token:

```sh
desk-work integrations apply --expected PLAN_TOKEN
desk-work integration-status
desk-work integrations rollback --transaction TRANSACTION_ID
```

`desk-work health` and the drawer's **Work health** page show loaded versions, refresh timestamps and update
recovery state. Each update records preparation, deployment, publication and rollback phases. An unfinished
transaction blocks another update; a live writer stays running. After inspecting its details, recover a stopped
transaction with:

```sh
desk-work integrations recover --transaction TRANSACTION_ID
```

Recovery restores the original files through the same guarded rollback, preserving later edits and permission
changes. A completed publication whose final bookkeeping was interrupted is recorded as complete without
rolling back its files. `:WorkHealth` opens the details and explicit recovery controls in Neovim, and lists each
session still on older code with the steps that reload it without closing your work.

### Inspect and clean update backups

`desk-work integrations backups` lists transaction phases and disk usage. Preview cleanup before removing
anything:

```sh
desk-work integrations cleanup-plan --keep 3 --older-than 30
desk-work integrations cleanup --keep 3 --older-than 30 --expected CLEANUP_PLAN_TOKEN
```

The defaults keep at least three recent completed transactions and consider only backups over thirty days old.
Current rollback chains, unfinished updates, live writers and unknown records remain protected regardless of
age. The preview explains each retained backup and shows the selected bytes. If the inventory changes, cleanup
requires a new preview. It never follows transaction-directory symlinks or changes installed files.
`:WorkBackups` opens the same preview; **D** asks for confirmation with Cancel selected. Reading health or opening
the backups page never performs cleanup. The installer does not schedule automatic deletion.

### Required work checks

`make test-work-integrations` is the mandatory local/CI entry point. Missing Claude, TypeScript, Neovim,
Quickshell, Node or Python msgpack fails the check. The hosted workflow reads its engine/compiler pins and
verified generated declarations from [the SDK fixture](../tests/fixtures/claude-sdk/README.md); it requires no
Claude credentials. To use a retained pinned executable locally without changing your installed CLI, set
`CLAUDE_TEST_BIN` to that executable when running the target. Logs identify every required group and the first
failure. The SDK fixture is never deployed by the installer.

The scoped dispatcher runs only the native integration-update path; it does not enter the installation wizard.
An update refuses if source builds are stale, preview targets moved or dependencies cannot be staged/backed up.
Compatibility command names derive from the existing alias table, so old `fox-*` copies use the updated native
tools. Custom command aliases are preserved; replaced copies and links are included in backup and rollback.
Rollback restores original files, modes and symlinks, including a separate XDG config directory, and refuses to
overwrite later edits or permission changes. Transactions live under
`$XDG_STATE_HOME/foxml/work/integrations/transactions/` (default `~/.local/state/foxml/work/integrations/transactions/`).
This updates an existing base installation; normal installation still configures the Claude mod setting and other
application wiring.

`desk-work integration-status` compares source inputs, installed files and versions reported by live clients.
Unknown loaded versions stay unknown. A normal app/module reload picks up new code; the updater does not close
Claude, tmux, editor windows or agent processes. `desk theme check` includes these checks. Generated build stamps
are checked against the integration manifest rather than compared with their development placeholders.

`make -C src/desk-install test` includes a disposable-home deployment fixture. It discovers every runtime module,
copies it through the production mapping and atomic deployment helper, renders the notebook palette, checks native
backend permissions and old aliases, and repeats deployment. It also checks menu upgrades reach an older install.
This complements the existing hook-wiring and drawer-install fixtures; it does not replace a boot/login VM test.

After the normal install in a VM, check:

- `command -v desk-work desk-drawer desktop-menu` resolves the installed commands.
- A new Claude session accepts `/notebook compact` and `/notebook expand`.
- In Neovim, a clean sample buffer reloads an external atomic save. With unsaved edits, `:AgentChanges` offers a
  comparison and saving refuses to overwrite the external copy until it is resolved.
- `:WorkAttention`, the notebook and the drawer's **Needs you** page agree about the same project.
- A pi session appears on the Agents page; its completed test run reaches the work store.
- `desk-work watch --root "$PWD"` receives a versioned event when another terminal runs
  `desk-work signal --root "$PWD"`.

Running sessions keep their loaded code until the app reloads it. Deployment never needs to close Claude or tmux.

## Requirements

- Arch Linux with Hyprland; the installer uses `pacman`.
- `bash`, `git`, `curl` and access to `sudo` for package and system changes.
- A C++17 compiler, Make and OpenSSL development files for the native tools.
  The wrapper installs `base-devel` if the compiler or Make is missing.
- Allow room for kernel updates: a 1 GiB boot partition is recommended, with
  at least 256 MiB free. The wrapper stops below 128 MiB free.
- Additional disk space for the applications and optional local models.

## Choose an install path

Run these from the repository root:

| Command | Scope |
| --- | --- |
| `./install.sh` | Interactive module wizard and preview before applying changes |
| `./setup-minimal` | System packages, shell plugins, icons, monitors and the theme deployment pipeline |
| `./setup` | Default workstation modules, plus packages, OpenCode/aider, model downloads and GitHub workspace cloning |

The setup scripts pass `--yes`. They use your saved theme, falling back to
`FoxML_Classic`; append a theme name to choose another.

`setup-minimal` excludes the firewall, security, boot and login-screen modules.
It still installs packages and deploys configuration across the desktop.

`setup` uses [`presets/workstation.preset`](../presets/workstation.preset).
Local model serving is a separate module; see [Local AI](local-ai.md).

### Bootstrap without cloning first

```bash
curl -fsSL https://raw.githubusercontent.com/Jennifer-214/Linux_Theme/main/bootstrap.sh | bash
```

The bootstrap installs missing build prerequisites, clones into
`~/code/Linux_Theme` and runs `install.sh --full --yes`. This enables every
registered module, including opt-in modules, so its scope is broader than
`./setup`. GitHub authentication and hardware-specific steps may still need input.

## Select individual modules

```bash
./install.sh --monitor
./install.sh FoxML_Classic --render
./install.sh --only ai,models,llama_server --yes
./install.sh --preset desktop --yes
```

Module flags select an exclusive set; `--render` also selects the modules needed
to deploy and refresh the theme. Presets override the defaults additively.
Use `--only` with comma-separated module **slugs** (for example `llama_server`);
individual flags use their registered spelling (for example `--llama-server`).

### Inspect a plan directly

The shell wrapper routes informational flags directly to the local orchestrator, bypassing self-update, sudo and
binary installation. To inspect without even invoking the bootstrap build, build and call it directly:

```bash
make -C src/desk-install
./src/desk-install/desk-install --help
./src/desk-install/desk-install --preset workstation --dry-run
```

The build requires the compiler, Make and OpenSSL files listed above. For a normal
install, use `install.sh` so the other native tools are built and installed too.

## Common flags

| Flag | What it does |
| --- | --- |
| `--yes` | Skip the wizard and assume yes for prompts |
| `--preset NAME` | Apply saved module choices; user presets take precedence over repo presets |
| `--only SLUGS` | Run only the listed modules |
| `--no-<slug>` | Disable a module |
| `--reapply` | Run selected modules even if already up to date |
| `--resume` | Resume from the last successful module |
| `--no-update` | Skip the wrapper's Git self-update |
| `--dry-run` | Print the orchestrator's planned commands |
| `--full` | Enable every registered module and sub-toggle, except explicit exclusions |

## Module flags

| Flag | What it does |
| --- | --- |
| `--monitor` | Surgical run of the multi-monitor layout wizard only |
| `--deps` | Install system and application packages; use `--zsh-plugins` for shell plugins |
| `--ai` | Install OpenCode + aider (see [Local AI](local-ai.md)) |
| `--models` | Queue background Hugging Face model downloads, resuming across reboots |
| `--llama-server` | Install llama.cpp's local model router (`127.0.0.1:8080`) |
| `--llama-turbo` | Build the optional TurboQuant llama.cpp fork for long-context roles |
| `--github` | Authenticate with GitHub and clone workspace repositories into `~/code` |
| `--secure` | Configure kernel sysctls, UFW, Fail2ban, Auditd, USBGuard and AppArmor |
| `--ssh-harden` | Run the SSH hardening wizard |
| `--perf` | Configure Chrony time synchronization |
| `--privacy` | Configure DNS-over-HTTPS |
| `--vault` | Install the in-memory `desk-vault` secret-store service |
| `--nvidia` | nvidia-open-dkms + Hyprland on dGPU (Optimus laptops) |
| `--render` | Apply the theme everywhere: render, deploy, scripts, drawer, cursor and banner, then restart waybar/mako/dunst. Folder colours can need sudo, so it warns and leaves them to `--only papirus_icons` |
| `--private-extras` | The repo owner's own extras, from a script in her private `linux-theme-workspace` (off by default) |

The installer exits `0` when everything finished, `1` when a module failed, `2` when a render stopped to protect live edits, and `3` when it finished but a module reported an error.

`--private-extras` runs `~/code/linux-theme-workspace/private-extras.sh` only after checking that the GitHub
login is the repo owner's, that the checkout is her private `linux-theme-workspace` and GitHub still serves it,
that the script is the committed one, and that the commit is signed by her key (its fingerprint is pinned in
`modules/private_extras.hpp`). On anyone else's machine it prints why it did not run and the install goes on,
finishing with exit `3`.

`--nvidia` requires `systemd-boot`; other bootloaders print manual instructions. Reboot afterwards.

`./src/desk-install/desk-install --help` lists the current module flags after building.

### Archinstall profile

Boot the Arch ISO and load Linux_Theme directly:

```bash
archinstall --config https://raw.githubusercontent.com/Jennifer-214/Linux_Theme/main/shared/foxml-profile.json
```

Installs `linux-zen`, NVIDIA drivers, and runs the bootstrap on first boot.

## Post-install

1. `hyprctl reload`
2. Restart terminals/apps
3. Firefox: enable `toolkit.legacyUserProfileCustomizations.stylesheets` in `about:config`
4. Cursor: select "Fox ML" in the color theme picker

Run `desk theme check` to verify the desktop; see the [check reference](desktop.md#checking-the-desktop).
