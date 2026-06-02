# Recovery — when you lock yourself out

## The cardinal rule

**Physical TTY access at the laptop itself bypasses everything in this
stack.** Ctrl-Alt-F2 (or F3, F4, F5) drops you to a text console.
Log in with your local username + password (no fingerprint, no SSH).
From there you can fix anything below.

If you can't even reach a TTY (e.g. SysRq=0 blocks it AND the GUI is
crashed), boot from a live USB and chroot into your install.

## Symptoms and fixes

### "I can't SSH in anymore"

You may have run the SSH wizard, picked a custom port, and forgot it.
At the laptop TTY:

```
sudo grep '^Port ' /etc/ssh/sshd_config.d/50-foxml-hardening.conf
```

If the port is unexpected, edit the file and `sudo systemctl restart sshd`.

### "I disabled password auth, lost the key, can't get back in"

At the laptop TTY:

```
sudo nano /etc/ssh/sshd_config.d/50-foxml-hardening.conf
# Change PasswordAuthentication no → yes
sudo systemctl restart sshd
```

Then SSH in with password and add your key to `~/.ssh/authorized_keys`.

### "I forgot the knock sequence (`fox knock`)"

At the laptop TTY:

```
cat ~/.config/foxml/knock.conf      # shows SEQUENCE=
```

Or regenerate / disable:

```
fox knock --reset
fox knock --disable
```

### "I lost the SPA keys (`fox spa`)"

```
fox spa --reveal       # interactive read (asks confirm)
fox spa --disable      # stop fwknopd + re-open SSH
```

### "UFW is denying everything"

```
sudo ufw default allow outgoing
# Or full kill:
sudo ufw disable
```

### "I enabled egress lockdown and now an app can't reach the internet"

```
fox firewall unlock                # revert to default-allow outgoing
# Or selectively:
fox firewall allow <port>/[tcp|udp]
```

### "fox-deadman just locked + dropped network on a normal USB removal"

```
sudo nmcli networking on
fox deadman --disarm
```

### "I want to back out of the entire hardening stack"

```
fox arm --disarm           # reverses the lockdown-style opt-ins
fox harden disable hidepid # repeat for each layer you want off
sudo systemctl disable --now ufw fail2ban auditd usbguard
sudo rm /etc/sysctl.d/99-foxml-hardening.conf && sudo sysctl --system
sudo rm /etc/ssh/sshd_config.d/50-foxml-hardening.conf && sudo systemctl restart sshd
```

### "I lost `~/.config/foxml/` (reinstalled OS, etc.)"

If you ran `fox backup` before the loss:

```
fox backup --restore ~/Documents/foxml-backup-YYYYMMDD.tar.gpg
```

If not, re-run each opt-in's `--setup`:

```
fox dispatch --setup
fox knock --setup        # or fox spa --setup
fox cafe --setup
fox deadman --setup
fox proximity --setup
```

System-side configs (`/etc/ssh/sshd_config.d/`, `/etc/wireguard/`,
`/etc/usbguard/`) survive a `~/` wipe — only personal config is at risk.

### "Everything is broken — full rollback"

Each FoxML install drops backups under `~/.theme_backups/foxml-backup-*`.
Find the most recent and restore the affected files. The installer
also runs `fox-doctor` at the end, which prints actionable hints.
