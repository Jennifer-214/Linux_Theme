# Installation reference

[← Back to the README](../README.md)

Install paths, module selection, flags and first-run setup.

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
`Classic`; append a theme name to choose another.

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
./install.sh Classic --render
./install.sh --only ai,models,llama_server --yes
./install.sh --preset desktop --yes
```

Module flags select an exclusive set; `--render` also selects the modules needed
to deploy and refresh the theme. Presets override the defaults additively.
Use `--only` with comma-separated module **slugs** (for example `llama_server`);
individual flags use their registered spelling (for example `--llama-server`).

### Inspect a plan directly

The shell wrapper can self-update, install build prerequisites and install native
binaries before handing off to the orchestrator, even with `--dry-run` or `--help`.
To inspect the orchestrator without those wrapper steps, build and call it directly:

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
