# peridot-partition-tools

Back up, **grow the `super` partition**, and restore the partition layout of the **Xiaomi POCO F6 / Redmi Turbo 3 "peridot" (Snapdragon 8s Gen 3, SM8635)**.
The tool looks at what your ROM's `super` really contains, suggests a safe size, checks everything it can **before** it writes anything, and can always take you back to the original layout.

> ## READ THIS FIRST - WARNINGS
>
> **This can permanently brick your phone.** A wrong partition table can leave a phone unable to boot *and* unable to reach the bootloader. The last-resort recovery (EDL) needs files and
> authorisation you may not have (see [docs/RECOVERY_AND_TROUBLESHOOTING.md](docs/RECOVERY_AND_TROUBLESHOOTING.md)). Only do this on a phone you can afford to lose.
>
> 1. **ALL DATA ON THE PHONE IS ERASED.** `userdata` is moved and recreated empty. Copy your files off the phone first.
> 2. **Only for the POCO F6 / Redmi Turbo 3 `peridot`.** The scripts refuse other devices. Never run them on another model. It is meant for every storage variant of the phone (128/256/512 GB class): the scripts read the real layout from your phone, but only a 256 GB-class phone has been tested. **A backup is tied to the one phone (and disk size) it was taken from: never restore it onto another phone.**
> 3. **Make a backup first and keep a copy somewhere else** (`part_backup.sh`). Without it you cannot go back.
> 4. You need an **unlocked bootloader**. **Never relock it** and **never use a ROM's `flash_all_lock.*` script** with a custom/engineering setup: that can brick the phone.
> 5. The ROM you give the tool must be **the ROM that is installed on the phone** (same version). The tool only replaces `super`/`metadata`/`userdata`; it does not touch firmware or boot images.
>    To change to a different ROM version, flash that whole ROM with its own `flash_all` first (see "Switching to another ROM" below).
> 6. **Charge the phone above 60 %. Never unplug the cable, power off, or close the terminal** while a step is writing or flashing.
> 7. Everything here is provided **as is, without warranty**. You are responsible for your device.
> 8. **Always run every script without `--execute` first.** That is a dry run: it checks and shows the plan, and changes nothing.

## Contents
1. [What you need and what to download](#what-you-need-and-what-to-download)
2. [Which ROM package? (factory images vs retail fastboot ROM)](#which-rom-package)
3. [Quick start](#quick-start)
4. [What every script does](#what-every-script-does)
5. [Switching to another ROM (for example engineering ROM to HyperOS)](#switching-to-another-rom)
6. [Choosing the size](#choosing-the-size)
7. [Limits and what is checked](#limits-and-what-is-checked)
8. [Status / tested on](#status--tested-on)
9. [More documentation](#more-documentation)

## What you need and what to download

| # | What | Why | Where / how |
|---|---|---|---|
| 1 | A **Windows 10/11 PC** (Linux and macOS also work, see note) with about **30 GB free** on a normal local drive | ROM (7-10 GB) + generated image (7-10 GB) + a Windows copy of it | Do **not** use a OneDrive/Dropbox/Google-Drive synced folder for the working data |
| 2 | **WSL 2 with Ubuntu** (Windows only) | the scripts are bash scripts | Open PowerShell as administrator: `wsl --install -d Ubuntu`, reboot, create your Linux user. Guide: <https://learn.microsoft.com/windows/wsl/install> |
| 3 | In Ubuntu: `python3`, `coreutils`, `git` | the scripts and the image patcher | `sudo apt update && sudo apt install -y python3 coreutils git` |
| 4 | **Android SDK Platform-Tools** (`adb.exe`, `fastboot.exe`) | talk to the phone | Download from <https://developer.android.com/tools/releases/platform-tools>, unzip to `C:\platform-tools` (other place: set `ADB=` and `FB=`) |
| 5 | **USB drivers** | Windows must see the phone in Android, recovery **and** fastboot mode | Usually automatic. If `fastboot devices` stays empty, install the Google USB driver <https://developer.android.com/studio/run/win-usb> or Xiaomi's driver. Use a good cable and a USB 2.0 port |
| 6 | The **phone**: unlocked bootloader, **USB debugging** on, this PC authorised | adb | Settings > About > tap MIUI/OS version 7 times > Developer options > USB debugging. Unlocking needs the official Xiaomi unlock process (account binding + waiting period) |
| 7 | A **ROM package for your exact installed version** (see next section) | its `super.img` is the basis of the new `super` | Factory/engineering images, or Xiaomi's official **"Fastboot ROM"** `.tgz` for `peridot` (also on trusted firmware mirrors such as <https://xiaomifirmwareupdater.com>; check any checksum they publish) |
| 8 | **7-Zip** (only if your ROM is a `.tgz`) | a `.tgz` must be unpacked **twice**: `.tgz` -> `.tar` -> folder | <https://www.7-zip.org/> (or in Ubuntu: `tar -xzf rom.tgz`) |
| 9 | **This repository** | the scripts | `git clone` it (it is private: you need access) or download the ZIP and unpack it inside WSL (e.g. into `~/peridot-partition-tools`) |
| 10 | Recovery that gives **root adb** | the partition table is edited from recovery | The engineering/factory ROM's recovery does. A retail ROM's recovery usually only offers sideload: see "Which ROM package?" |

*Linux/macOS users:* install `adb`/`fastboot` from your package manager; the scripts detect that they are not on WSL and use them directly (`WIN_STAGE` then defaults to `$PART_DATA/stage`). Only Windows+WSL was tested.

Unpack your ROM into a short local path, for example `C:\roms\peridot_xyz\` (WSL sees it as `/mnt/c/roms/peridot_xyz/`). The folder you give to the tools is the one that contains **`super.img`** (usually named `images`).
Check the download **before** you touch the phone:

```bash
bash scripts/rom_check.sh /mnt/c/roms/peridot_xyz     # no phone needed
```

## Which ROM package?

Two kinds of packages work, because they have the same structure and the same partition layout (verified on two real packages):

| | Factory / engineering images | Retail **Fastboot ROM** (`.tgz`) |
|---|---|---|
| Example (tested) | `peridot_factory_images_FACTORY-PERIDOT-24.4.17_14.0` (Android 14, userdebug) | `peridot_in_global_images_OS3.0.303.0.WNPINXM_16.0` (HyperOS `OS3.0.303.0.WNPINXM`, Android 16 / sdk 36, global; kernel `6.1.138-android14-11`) |
| Contains | `images/super.img`, `userdata.img`, `rawprogram*.xml`, `patch*.xml`, `gpt_*.bin`, `flash_all.bat/.sh` | the same files |
| `super` content | 14 partitions, **3.9 GiB** used | 16 partitions (adds `mi_ext_a`), **7.3 GiB** used |
| Partition layout on `sda` | all 33 partitions identical in position and size; `super` = 8.5 GiB at sector 208896 | identical |
| Anti-rollback value | 1 | 1 |
| Root adb in Android and recovery | **yes** | no (user build) |

What that means for you:

- **Everything the tool does to `super`/`userdata` works with both** (`rom_check.sh`, building the new `super`, flashing).
- **Changing the partition table needs root adb in recovery** (we use Android's `sgdisk`). That is only available on an engineering/userdebug ROM or with a recovery that gives root adb.
  So: do the table change while the phone runs the engineering ROM, then switch to the retail ROM, then use `--reflash-only` (it needs only the bootloader). See [Switching to another ROM](#switching-to-another-rom).
- **Measured on the retail HyperOS recovery** (`OS3.0.303.0.WNPINXM`): it gives an `adb shell`, but as the plain `shell` user (uid 2000) on a production build; `adb root` is refused ("cannot run as root in production builds"), the disk device nodes are root-only and there is no `su`. So **the table cannot be edited from a stock retail recovery**.
- **Options for root in recovery on a retail ROM**: (a) a **custom recovery** that gives root adb (TWRP/OrangeFox-style, built for peridot). On this phone the recovery lives in `vendor_boot`, so flashing one **replaces the vendor ramdisk**: use a build made for your ROM version and **keep the ROM's own `vendor_boot.img`** (it is in the ROM folder) to flash back if Android no longer boots;
  (b) Magisk/KernelSU root in Android (`su` is supported: run with `--allow-android`, less safe); (c) the engineering ROM's recovery.
  A custom recovery may not ship `sgdisk`; the tool then pushes the one you pulled with `pull_sgdisk.sh`.
- **Root with KernelSU/Magisk** (Android mode, `--allow-android`): `adb shell su` only works after you grant root to the **Shell** app in the manager's superuser list (adb runs as that app); the phone may show a grant popup. After a data wipe the grant is gone and must be given again.
- The ROM must be **complete**: `super.img` (a single Android sparse or raw image) and `userdata.img`. A ROM whose super is split into pieces (`super.img_sparsechunk.N`) is detected and refused.

## Quick start

All commands run in a **WSL terminal**, from the root of this repository. Replace the example paths with yours.

```bash
export PART_DATA=$HOME/peridot-partition-data                 # where backups, logs and images are kept (a real local folder)
export ROM=/mnt/c/roms/peridot_xyz                            # the ROM that is INSTALLED on the phone
```

1. **Check the ROM** (no phone): `bash scripts/rom_check.sh "$ROM"` - shows what the `super` contains and a suggested size.
2. **Get `sgdisk`** (once; phone booted in Android, USB debugging on): `bash scripts/pull_sgdisk.sh`.
3. **Back up** (read only): `bash scripts/part_backup.sh` - then **copy the backup folder somewhere else** (another PC/cloud/USB).
4. **Reboot to recovery**: `adb reboot recovery`; `adb get-state` must print `recovery`.
5. **Dry run**: `bash scripts/part_resize.sh --factory "$ROM" --super-gib auto` - every line should be `OK`; it ends with `DRY RUN ONLY - nothing was changed`.
6. **Do it** (erases everything, asks you to type `ERASE`): `bash scripts/part_resize.sh --factory "$ROM" --super-gib auto --execute`
7. **Check**: when it prints `Done`, run `adb shell lpdump | grep -A3 "Block device table"`, `adb shell df -h /data`.

The script clears the recovery flag itself, reboots to the bootloader, flashes `super`, erases `metadata`, flashes `userdata`, boots, and prints the new sizes. A first boot after the wipe can take several minutes.
**On a retail ROM, USB debugging is OFF after the wipe**, so the script will wait and print a hint: finish the setup wizard, enable USB debugging again and authorise the PC; Android has booted fine if you see the setup screen.
Every run writes a log to `$PART_DATA/logs/`; attach it when you ask for help.

**Go back** to the original layout at any time (recovery, root adb):

```bash
bash scripts/part_restore.sh                                              # dry run
bash scripts/part_restore.sh --execute --flash-factory --factory "$ROM"   # table back + re-flash that ROM's super/userdata
```

## What every script does

| Script | Purpose | Changes the phone? |
|---|---|---|
| `scripts/rom_check.sh <ROM>` | Is the ROM package complete? What does its `super` contain? Suggested size. **No phone needed.** | no |
| `scripts/pull_sgdisk.sh` | Copies Android's own `sgdisk` (+2 libraries) from your booted phone, because recovery has none | no |
| `scripts/part_backup.sh` | Saves the partition tables of all storage units (sda..sdf) with checksums, two copies, integrity-checked | no (read only) |
| `scripts/part_resize.sh` | Dry run by default; `--execute` repartitions and flashes. `--reflash-only` flashes a ROM's `super` into a table that is already the right size (bootloader only) | **yes** |
| `scripts/part_restore.sh` | Dry run by default; `--execute` writes the original table back, `--flash-factory` also re-flashes the ROM | **yes** |
| `scripts/lp_resize.py` | The engine: `info`, `check`, `suggest`, `resize`, `verify`, `match` on a `super` image (works on files only) | no |
| `scripts/lib.sh` | shared helpers (not run directly) | - |

### Options of `part_resize.sh`

| Option | Meaning |
|---|---|
| `--factory DIR` | the ROM folder (`images` or its parent). Required |
| `--super-gib N` or `auto` | new size in GiB. `auto` (default) = what the ROM needs + 30 % headroom, whole GiB. Must be larger than today's `super`; at least 1 GiB must stay for `userdata` |
| `--execute` | actually write. Without it: dry run |
| `--reflash-only` | do not touch the partition table; flash the `N` GiB `super` of this ROM. The `super` partition must already be exactly `N` GiB (checked via `fastboot getvar partition-size:super`). Needs only the bootloader, no root adb |
| `--backup DIR` | which backup to compare with (default: the newest) |
| `--assume-yes` | do not ask for the `ERASE` confirmation (automation only) |
| `--allow-android` | allow running while Android is booted instead of recovery (advanced, less safe) |
| `--allow-rom-mismatch` | continue although the ROM does not look like the installed one (will almost certainly not boot) |
| environment | `PART_DATA`, `WIN_STAGE` (Windows-visible staging folder, default `C:\peridot_flash` via WSL), `ADB`, `FB`, `SGB` |

## Switching to another ROM

Example: you are on the engineering ROM with the table already enlarged, and want the retail HyperOS ROM with the extra space.

1. **Keep a way back**: keep the engineering ROM folder and your table backup. Going back to a smaller table needs a recovery with root adb, i.e. the engineering ROM.
2. Check the new ROM: `bash scripts/rom_check.sh <new ROM>` (it tells you the size it needs; with the HyperOS example 7.3 GiB, suggested 10 GiB).
3. Flash the **whole new ROM with its own script**: `flash_all.bat` (Windows) or `flash_all.sh` from the ROM folder, **not** the `flash_all_lock.*` variants. This writes firmware + `super` + `userdata` and **erases the phone**.
   It does not change the partition table, so an enlarged table stays enlarged. The ROM's `super.img` describes an 8.5 GiB device, so the extra space is simply unused for now. The ROM's script also checks anti-rollback for you.
4. Optional, to use the extra space: put the phone in the bootloader (**Power + Volume-Down**) and run
   `bash scripts/part_resize.sh --factory <new ROM> --super-gib 12 --reflash-only` (dry run), then add `--execute`.
   It builds a 12 GiB version of the new ROM's `super` and flashes it; it does not need adb or recovery. `userdata` is wiped again.

If the table is still the small original one and you only have a retail ROM (no root recovery), install the engineering ROM first, do the table change there, then switch ROM as above.

## Choosing the size

The tool computes it for you: `rom_check.sh` / `lp_resize.py check` print, for **your** ROM,
what each slot uses, how much the image holds, the minimum possible size and the suggestion (`ROM + 30 %`, rounded up to whole GiB, never below today's size).
Examples from the two tested ROMs: engineering ROM uses 3.9 GiB (suggest 9 GiB); HyperOS (Android 16) uses 7.3 GiB (suggest 10 GiB).
Remember the extra space is taken from `userdata`. On a Virtual A/B phone (this one) only slot `_a` holds data; slot `_b` is empty, OTA updates stage their data in `userdata`.

## Limits and what is checked

Not supported, on purpose: shrinking `super`; a `super` that is not directly followed by `userdata`; sector sizes other than 4096; other devices; ROMs with a split or non-LP `super`; retrofit (multi-device) dynamic partitions; LP metadata other than v10.x.

Checked automatically before anything is written: the ROM package is complete; the size is valid for this ROM; host disk space; the device is a peridot; the battery is at least 50 %; the phone is in recovery with root adb;
the live table equals your backup and the backup exists in two places; `super`/`userdata` positions and GUIDs are read from the live table; the new table is dry-run by `sgdisk --pretend`;
the ROM matches the installed one (same partition names/sizes in `super`); in the bootloader: product is peridot, anti-rollback is not higher than the ROM, and (reflash-only) the partition has exactly the requested size.
After the write: the table is read back and compared. After the flash: Android must report a finished boot; `lpdump`, `sgdisk` and `df` are printed.

## Status / tested on

Tested on **one** POCO F6 (peridot), 2026-11-25, factory engineering ROM `FACTORY-PERIDOT-24.4.17_14.0` (Android 14):

- real `--execute` runs on earlier versions of the scripts: resize 8.5 -> 12 GiB (Android booted, `lpdump` showed the new sizes), restore to the original table + factory `super` (Android booted), and resize 8.5 -> 12 GiB again.
  Found and fixed on the way: the recovery flag in `misc` (phone kept returning to recovery), and a WSL-symlink problem with Windows adb.
- the image engine (`lp_resize.py`) was cross-checked against Android's own `lpdump` and also built a 12 GiB `super` from the retail HyperOS `OS3.0.303.0.WNPINXM` ROM.
- **This version (v2: ROM analysis, matching, `--reflash-only`, new checks and docs) is new**: the parts that need a phone (`part_resize.sh` normal mode, `--reflash-only`, `part_restore.sh`, `part_backup.sh`) have not all been re-run since the rewrite.
  See the table in [docs/TESTING.md](docs/TESTING.md) for exactly what was and was not tested.
- Custom recovery on the retail ROM: root + `sgdisk` + `lpdump` available; backup, dry runs and the refusal paths verified there (see TESTING.md).
- Never tested: any other device, a retail ROM installed on the phone, Linux/macOS hosts.

## More documentation

- [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) - GPT, LUNs, `super`, LP metadata, why only the metadata changes, Virtual A/B.
- [docs/RECOVERY_AND_TROUBLESHOOTING.md](docs/RECOVERY_AND_TROUBLESHOOTING.md) - when something goes wrong, restore paths, EDL.
- [docs/PERIDOT_LAYOUT.md](docs/PERIDOT_LAYOUT.md) - the stock partition table and the two ROMs' `super` contents.
- [docs/TESTING.md](docs/TESTING.md) - what has been tested and how to test a change.

No license has been chosen for this repository yet; ask the owners before reusing the code.
