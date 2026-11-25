# peridot-partition-tools

Back up, resize and restore the partition layout of the **Xiaomi POCO F6 / Redmi Turbo 3 "peridot" (Snapdragon 8s Gen 3, SM8635)**:
make the `super` partition bigger (taking the space from `userdata`), flash a matching `super` image, and go back to the original layout if anything goes wrong.

> ## READ THIS FIRST - WARNINGS
>
> **This can permanently brick your phone.** A wrong partition table on a phone can leave it unable to boot and unable to reach the bootloader.
> The recovery methods are limited (see [docs/RECOVERY_AND_TROUBLESHOOTING.md](docs/RECOVERY_AND_TROUBLESHOOTING.md)); on some devices the last-resort method (EDL) needs files and authorisation you may not have.
>
> 1. **ALL DATA ON THE PHONE IS ERASED** (photos, apps, accounts). `userdata` is moved and recreated empty. Copy anything you want to keep off the phone first.
> 2. **Only for the POCO F6 / Redmi Turbo 3 `peridot`** with the layout shown in [docs/PERIDOT_LAYOUT.md](docs/PERIDOT_LAYOUT.md). The scripts refuse other devices. Do **not** try them on another model.
> 3. **Make and keep a backup first** (`part_backup.sh`). Keep a copy **outside** the phone and outside the folder you are working in. Without it you cannot go back.
> 4. You need an **unlocked bootloader** and a **factory (fastboot) ROM matching the ROM you are on**. Do not mix ROM versions.
> 5. **Never unplug the cable, power the phone off, or close the terminal** while a step says it is writing or flashing. Charge the phone to at least 60 % first.
> 6. Everything here is provided **as is, with no warranty**. You are responsible for your device. Nothing in this repository has been reviewed by Xiaomi or Qualcomm.
> 7. If you do not understand a step, **stop and ask** before running it. Run every script **without `--execute`** first: that is a dry run which changes nothing.

## What it does

| Script | What it does | Changes the phone? |
|---|---|---|
| `scripts/pull_sgdisk.sh` | Copies Android's own `sgdisk` tool (and 2 libraries) from your booted phone to your PC so it can be used in recovery | no |
| `scripts/part_backup.sh` | Saves the partition tables of all 6 storage units (LUNs) of the phone, with checksums, in two places | no (read only) |
| `scripts/part_resize.sh` | Dry run by default. With `--execute`: writes a new partition table (bigger `super`, smaller `userdata`), flashes a matching `super`, erases `metadata`, flashes `userdata`, boots, verifies | **yes** |
| `scripts/part_restore.sh` | Dry run by default. With `--execute`: puts the original partition table back from your backup. With `--flash-factory`: also re-flashes the factory `super`/`userdata` so the phone boots again | **yes** |
| `scripts/lp_resize.py` | Builds the bigger `super` image from the factory one (patches only the dynamic-partition metadata) and verifies it. Used by `part_resize.sh`; also usable on its own (`info`, `resize`, `verify`) | no (works on files) |

How it works, in plain words: [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md).

## Why would anyone do this?

The stock `super` partition is 8.5 GiB and is nearly full of the system, vendor, product, ... images. A custom ROM, a bigger GSI, or extra dynamic partitions may not fit.
Android cannot grow `super` by itself, and the space has to come from the neighbour, `userdata`.

## What you need

- A Windows PC with **WSL2** (Ubuntu). The phone's USB is used through Windows `adb.exe`/`fastboot.exe`, the scripts run in WSL.
- **Android platform-tools** (adb + fastboot) at `C:\platform-tools` (override with `ADB=`/`FB=` environment variables).
- In WSL: `bash`, `python3`, `coreutils` (the scripts use `wslpath`, `sha256sum`, `dd`).
- The phone: unlocked bootloader, **USB debugging on**, and a ROM where `adb` can run as root (the factory **eng/userdebug** ROM works; locked-down user builds usually do not).
- The **factory fastboot ROM** for your exact version, unpacked: the folder called `images` that contains `super.img`, `userdata.img` and the `rawprogram*.xml` files.
- A free-space buffer on the PC: about 10 GB for the generated image.

## Step by step

All commands run in a WSL terminal, from the root of this repository. Replace the example paths with yours.

### 0. Prepare (once)

```bash
export PART_DATA=$HOME/peridot-partition-data        # where backups/images are kept
export FACTORY="/mnt/c/Users/<you>/Downloads/<factory-rom>/images"   # the folder with super.img
adb devices                                          # the phone must be listed (use adb.exe from Windows if "adb" is not in WSL)
bash scripts/pull_sgdisk.sh                          # phone booted in Android, USB debugging on, adb root
```

### 1. Back up (read only) - do not skip

```bash
bash scripts/part_backup.sh
```

It creates `$PART_DATA/backups/<date>/` and a second copy under `C:\peridot_flash\partition_backup\<date>\`.
**Copy that folder somewhere safe (cloud / another PC / USB stick).** Check that `SHA256.txt` exists and that `gpt_sda.sgdisk` is about 5 KB.

### 2. Reboot to recovery

```bash
adb reboot recovery            # the phone's recovery must give you "adb root"; nothing from userdata/super may be mounted
adb get-state                  # must print: recovery
```

### 3. Dry run (changes nothing)

```bash
bash scripts/part_resize.sh --super-gib 12 --factory "$FACTORY"
```

Read the output. It checks that your live partition table equals your backup, builds the new `super` image, and shows what the new table would be
(`super` 12.0 GiB, `userdata` 223.5 GiB). It must end with `DRY RUN ONLY`. If any line starts with `ERROR`, **stop** and read the message.

### 4. Do it

Only when step 3 looked right, and you accept that **all data will be erased**:

```bash
bash scripts/part_resize.sh --super-gib 12 --factory "$FACTORY" --execute
```

The script writes the table (in recovery), reboots to the bootloader, flashes the new `super` (several minutes, do not touch the phone), erases `metadata`, flashes `userdata`,
reboots and prints the new sizes. The first boot after a data wipe can take several minutes.

If the phone does not reach the bootloader by itself, hold **Power + Volume-Down**, then follow the message the script prints.

### 5. Check

On the phone (`adb shell`):

```bash
lpdump | grep -A3 "Block device table"      # Size: 12884901888 bytes  (= 12 GiB)
sgdisk --print /dev/block/sda | grep -E " super| userdata"
df -h /data
```

### 6. Go back to the original layout (if you want, or if something is wrong)

```bash
adb reboot recovery
bash scripts/part_restore.sh                                                  # dry run
bash scripts/part_restore.sh --execute --flash-factory --factory "$FACTORY"   # restore the table and re-flash the factory super/userdata
```

## Options

| Option | Meaning |
|---|---|
| `--super-gib N` | new size of `super` in GiB (default 12). Must be larger than today's; leave at least 1 GiB for `userdata` |
| `--factory DIR` | the factory ROM `images` folder (or environment variable `FACTORY`) |
| `--backup DIR` | which backup to compare with / restore from (default: the newest in `$PART_DATA/backups`) |
| `--execute` | actually write. Without it every script is a dry run |
| environment `PART_DATA`, `WIN_STAGE`, `ADB`, `FB`, `SGB` | data folder, Windows-visible staging folder (default `/mnt/c/peridot_flash`), adb/fastboot paths, sgdisk bundle folder |

## Limits (by design, to keep it safe)

- Only **growing** `super` is supported (shrinking needs the partition images unpacked and rebuilt).
- Only the layout where `userdata` starts **right after** `super` on `sda` (the stock layout).
- Sector size must be 4096 bytes. Other storage units (`sdb`..`sdf`) are never modified (they are only backed up).
- The new `super` is built from the **factory** `super.img`. A custom/modded `super.img` should be resized the same way with `lp_resize.py resize`, as long as it is a normal Android sparse image.

## Status / tested on

Tested on **one** POCO F6 (peridot), factory eng ROM `FACTORY-PERIDOT-24.4.17_14.0` (Android 14, stock 6.1 kernel), on 2026-11-25:

- `part_resize.sh --execute` with `--super-gib 12`: `super` 8.5 -> 12 GiB, `userdata` 227 -> 223.5 GiB. Android booted from the resized `super`; `lpdump` showed the 12 GiB device and group sizes, all logical partitions (`system_ext`, `product`, `vendor`, `vendor_dlkm`, `system_dlkm`, `odm`) were mounted, `/data` was 224 GiB.
- That real run used an earlier version of the scripts that did **not** clear the recovery flag: the phone kept booting into recovery until the flag in `misc` was cleared by hand. The scripts now clear it (see [troubleshooting](docs/RECOVERY_AND_TROUBLESHOOTING.md)).
- The final versions of `part_backup.sh`, `part_resize.sh` (dry run, also 12 -> 14 GiB) and `part_restore.sh` (dry run) were run against the phone; the final `--execute` paths of the resize and the restore have **not** been re-run after the last fixes, and `part_restore.sh --execute` has never been run on real hardware.
- Not tested: any other device, ROM version, or a user (locked-down) build.

## Help and details

- [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) - what is a GPT, a LUN, `super`, dynamic partitions, why only the metadata changes.
- [docs/RECOVERY_AND_TROUBLESHOOTING.md](docs/RECOVERY_AND_TROUBLESHOOTING.md) - when something goes wrong, restore paths, EDL.
- [docs/PERIDOT_LAYOUT.md](docs/PERIDOT_LAYOUT.md) - the stock partition table this was written for.

No license has been chosen for this repository yet; ask the owners before reusing the code.
