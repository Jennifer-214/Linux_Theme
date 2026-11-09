# Security next steps

Reviewed on 2026-11-08. This is a read-only review; boot, encryption and
security policies were not changed.

The live system has UFW, fail2ban, auditd, AppArmor and USBGuard running.
The local model server listens on 127.0.0.1:8080. SSH is inactive. AppArmor
profile enforcement could not be inspected without root access, so an active
service alone is not proof that desktop applications are confined.

1. **Encrypt the Linux system and backups.** The root filesystem is mounted
   directly from an ext4 partition, with no dm-crypt mapping in the observed
   block-device tree. LUKS2 would protect data at rest if the laptop or drive
   is lost. Plan this as a separate migration with a tested backup and a
   recovery key stored elsewhere. TPM2 or a FIDO2 key can be added later;
   retain a recovery method. See the [systemd LUKS2 enrollment
   documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html).

2. **Use Secure Boot with a signed unified kernel image.** Firmware reports
   Secure Boot disabled in setup mode; the current systemd-boot entry loads
   a separate kernel and initramfs. A signed UKI covers the kernel, initramfs
   and embedded command line together. Include the Windows boot path and
   NVIDIA module signing in the plan. See [systemd-stub's Secure Boot
   behavior](https://www.freedesktop.org/software/systemd/man/latest/systemd-stub.html).

3. **Constrain background services individually.** Start with the model server
   and Fox monitoring services. Use `systemd-analyze security` to find missing
   restrictions, then test suitable settings such as `NoNewPrivileges=yes`,
   a small capability set and read-only filesystem access. Some desktop
   helpers deliberately launch applications or need writable project paths,
   so each unit needs its own policy. A good numerical score is not proof of
   security. See [systemd's service controls](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)
   and [security analysis limitations](https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html).

4. **Verify application confinement and backup recovery.** Check which
   AppArmor profiles are actually enforced for browsers and network-facing
   services, and perform a restore of an important project into a temporary
   folder. Prefer verified protection and recovery over adding more alerts.

If SSH is enabled later, verify a working key login before disabling password
authentication; the installed drop-in currently allows passwords.
