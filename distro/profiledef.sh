#!/usr/bin/env bash

iso_name="FoxML-OS"
iso_label="FOXML_$(date +%Y%m)"
iso_publisher="Jennifer-214 <https://github.com/Jennifer-214/Linux_Theme>"
iso_application="Linux_Theme"
iso_version="1.5.9"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito' 'uefi-ia32.grub.esp' 'uefi-x64.grub.esp' 'uefi-ia32.grub.eltorito' 'uefi-x64.grub.eltorito')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_permissions=(
  ["/usr/local/bin/fox-install"]="0:0:755"
  ["/root"]="0:0:750"
)
