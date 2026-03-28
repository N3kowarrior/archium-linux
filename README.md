# Archium Linux 🐧
- Archium Linux is based on Arch Linux and aims to make Arch easier to install, removing the headace of configuring the system, providing meaningful performance gains. 

## Warning Archium linux is still in early stage and it might change or break with updates 🔴
- If you find any bugs, capture screenshots, provide relevant logs, speak english, open new issues.

## Features: 🧰
- [Linux LTG kernel](https://github.com/frogging-family/linux-tkg)
- Easy TUI installer, based on dialog.
- Automatic configuration, based on user input.
- Precompiled Nvidia aur driver, paru and few utilities
- [Papirus Icons](https://github.com/PapirusDevelopmentTeam/papirus-icon-theme)
- [Monochrome-kde theme](https://github.com/pwyde/monochrome-kde)
- Custom backgrounds (My own work, very silly).
- Btrfs or Ext4 installation
- Smart disk selector

## Smart disk selector 🎀
- Smallest SSD will be used for root partition, second smallest will be used for home, other any selected drive will be formated and mounted under /mnt/. If no ssd is selected, same logic is applied.

## Archium repo 🎀
- Archium repo is currently "hosted" on github, you can visit it [here](https://github.com/N3kowarrior/archium-repo/releases/tag/stable).

## TODO: 🛠️
- Write docs
- Add guard rails for newbie users.
- Add gui updater which updates when needed with needed changes.
- Figure out more optimizations.
- Grub theme

## Showcase: 🖼️
### Archium linux with Ext4 in vm:
![Archium Screenshot](https://github.com/N3kowarrior/archium-linux/blob/main/assets/showcase_ext4.png)
- Currently buggless, virtual machine use only
### Archium linux with BTRFS in vm:
![Archium Screenshot](https://github.com/N3kowarrior/archium-linux/blob/main/assets/showcase_btrfs.png)
- Warning, install script fails at the end while installing with btrfs, ignore it and reboot your vm

## Downloads for early adopters: 📁
[![Download archium-linux](https://a.fsdn.com/con/app/sf-download-button)](https://sourceforge.net/projects/archium-linux/files/Releases/)

