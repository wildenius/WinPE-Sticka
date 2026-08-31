# WinPE-Sticka

PowerShell-script for creating a bootable Windows PE USB stick with two partitions:

- **WINPE** — FAT32 boot partition with Windows PE files.
- **STUFF** — NTFS data partition for drivers, images, scripts, tools and logs.

## Warning

This script is destructive by design:

- It must be run as Administrator.
- It formats and repartitions the selected USB disk.
- All data on the selected USB disk will be erased.
- Always double-check the disk number before confirming.

Use at your own risk.

## Usage

```powershell
.\New-WinPEStick.ps1
```

Optional example:

```powershell
.\New-WinPEStick.ps1 -BootPartitionSizeMB 8192 -SkipAdkInstall
```

The script downloads/install Windows ADK + WinPE add-on if needed, builds a WinPE working directory, then prepares the USB stick.
