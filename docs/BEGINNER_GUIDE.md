# Beginner guide (read this before anything else)

This guide is for people who have never repartitioned a phone. It explains the words, the risks, what to prepare, where you can safely stop, and what to do when something goes wrong.
It is written assuming **you might brick the phone**. Nobody can promise that you will not.

## 0. Should you do this at all?

Do it only if **all** of these are true:

- You have a **real reason**: for example the ROM you want does not fit into the stock 8.5 GiB `super` (the tool tells you: `scripts/rom_check.sh`).
- The phone is a **POCO F6 / Redmi Turbo 3 "peridot"**, with an **unlocked bootloader**.
- You can accept **losing everything on the phone** and **possibly the phone itself**. Ideally you have **another phone** for daily use while this one is being worked on.
- You can follow instructions exactly and **stop when something looks different** from this guide.

Do **not** do it if: the phone is your only phone; the bootloader is locked; it is a different model; you are in a hurry; the battery is low; you are not sure which ROM is installed.

## 1. Words you will meet

| Word | What it means here |
|---|---|
| **ROM / firmware** | The operating system image set that is installed on the phone |
| **Fastboot ROM / factory images** | A download with all the image files (`super.img`, `boot.img`, ...) and scripts to write them from the PC |
| **Bootloader / fastboot mode** | The small program that starts before Android. You reach it with **Power + Volume-Down**; the PC then talks to it with `fastboot` |
| **Recovery** | A small separate system for maintenance. Here it is stored in `vendor_boot`. You reach it with `adb reboot recovery` |
| **adb** | The tool for talking to a phone that runs Android or recovery (needs USB debugging) |
| **Root** | Administrator rights. The partition table can only be edited with root |
| **Partition** | A fixed slice of the phone's storage (`boot`, `super`, `userdata`, ...) |
| **Partition table (GPT)** | The list at the start (and end) of a disk that says where each partition starts and ends |
| **`super`** | One big partition that holds `system`, `vendor`, `product`, ... |
| **`userdata`** | Your apps and files. It is **erased** by this tool |
| **LUN / `sda`..`sdf`** | The phone's flash chip shows up as six disks. These scripts write only `sda` |
| **Slot `_a` / `_b`** | Many partitions exist twice (A/B). The phone runs from one slot |
| **Dry run** | A run that only checks and prints the plan and changes **nothing** (every script does this unless you add `--execute`) |
| **Soft brick** | Phone does not boot Android, but fastboot/recovery work: **fixable** by flashing |
| **Hard brick** | Phone shows nothing and no mode works: usually needs special tools (EDL) |
| **EDL** | Qualcomm emergency mode, the last resort; it needs files/authorisation you may not have |
| **Anti-rollback** | A number in the firmware; flashing an **older** ROM than the phone allows can be refused or brick |
| **WSL** | A Linux inside Windows; the scripts run there |

## 2. What can go wrong, and how bad it is

| Situation | What happens | Seriousness |
|---|---|---|
| A script refuses with `ERROR` | A safety check stopped it. **Nothing was changed** | none - read the message |
| You run a dry run | Nothing changes | none |
| Wrong ROM version | The phone does not boot Android | soft brick, fixable: flash the matching full ROM |
| Cable/power lost **while flashing `super`** | `super` is half written, Android will not boot | soft brick: put the phone in fastboot, re-run `part_resize.sh ... --reflash-only --execute` |
| Cable/power lost **right after the table was written** | New table, old data: Android will not boot | soft brick: continue with `--reflash-only`, or restore from your backup |
| Phone returns to recovery again and again | A recovery flag is still set | fixable: see RECOVERY_AND_TROUBLESHOOTING.md |
| The partition table itself ends up corrupt | The phone may not boot **and** flashing by partition name may not work | **possible hard brick**. We never produced this in our tests, and the tool reads the table back and compares it before it continues, but it is the main danger of this whole project |
| Your own backup is lost | You cannot restore the original table | you are on your own |

What the testing covered, honestly: we ran the **successful** paths and the **refusals** on one phone (see [TESTING.md](TESTING.md)). We **never tested** a failure in the middle (unplugging the cable, power loss) and **never** made the partition table invalid. The "soft brick, fixable" statements above for those cases are what we expect from how the phone behaves, **not** something we tried.
The boot chain (`xbl`, `abl`, ...) lives on other storage units (`sdb`..`sdf`) which the scripts never write, and in all our runs the bootloader stayed reachable.

## 3. Points of no return (map of a resize)

```
 safe  ------------------------------------------------>|  not safe to interrupt  |---->  safe
 rom_check  pull_sgdisk  part_backup  dry run | WRITE TABLE | flash super | flash userdata | first boot | done
   (no risk, repeat as often as you like)      ^ you type ERASE here        ^ do not unplug / close anything until 'Done'
```

- **Before you type `ERASE`** you can stop at any moment (close the terminal, unplug): nothing was changed.
- **After `ERASE`** do not touch the phone, the cable, the PC, or the terminal until the script prints `Done`.
  If it stops with an error, **do not reboot the phone and do not start improvising**: read the "where things stand" text at the end of the output, it tells you the one command to run next.
- **Never press Ctrl+C** after `ERASE`. If you absolutely must stop: leave the phone in fastboot (Power + Volume-Down) and run the `--reflash-only` command the script printed.

## 4. Go / no-go checklist (all boxes must be ticked)

- [ ] I understand that **everything on the phone will be erased** and I have copied my files elsewhere
- [ ] The phone is a **peridot** and the bootloader is **unlocked** (`fastboot getvar unlocked` prints `unlocked: yes`)
- [ ] The phone is charged to **at least 60 %** and I will keep it **plugged into the PC with a good cable**, directly in the PC (no USB hub, no extension)
- [ ] I know exactly **which ROM is installed** and I have **that same ROM** unpacked (`scripts/rom_check.sh` says OK)
- [ ] I have a **backup** (`part_backup.sh`) in **two places**, and a third copy on another device/cloud
- [ ] I can get into **recovery with root** (see the README: engineering ROM recovery or a custom recovery) - **or** I only use `--reflash-only`
- [ ] **Windows will not go to sleep** (Settings > Power) and nothing else is using the phone (no Mi PC Suite, Mi Flash, Android Studio, scrcpy, other adb windows); antivirus is not blocking `adb.exe`/`fastboot.exe`
- [ ] I ran the script **without `--execute`** and **every line was OK**
- [ ] I have time (about 30 minutes) and nobody will unplug anything
- [ ] I have **another phone** and I accept that this one may stop working

If one box is not ticked: **stop**.

## 5. The safe order

1. `rom_check.sh <ROM>` - is the ROM complete and what does it need? (no phone)
2. `pull_sgdisk.sh` - once, with the phone booted in Android.
3. `part_backup.sh` - then copy the backup folder **somewhere else**.
4. Reboot to **recovery** (`adb reboot recovery`), check `adb get-state` says `recovery`.
5. `part_resize.sh --factory <ROM> --super-gib auto` - **dry run**. Read every line.
6. Only then add `--execute`, type `ERASE`, and wait for `Done`.
7. After the first boot enable USB debugging again (a retail ROM turns it off after the wipe) and check the sizes.

To go back: `part_restore.sh` (dry run), then `--execute --flash-factory --factory <ROM>`.

## 6. PC-side problems that look like phone problems

| Symptom | Likely cause | What to do |
|---|---|---|
| `adb devices` shows nothing or `unauthorized` | USB debugging off / not authorised / bad cable | enable USB debugging, accept the prompt on the phone, change cable/port |
| `fastboot devices` empty although the phone is in fastboot | driver / USB hub | install the USB driver, use a direct USB 2.0 port |
| Script waits forever at "waiting for Android" | on a retail ROM USB debugging is off after a wipe | finish the setup screen and turn USB debugging on again |
| Very slow flashing or timeouts | USB hub, long/cheap cable, power saving | direct port, original cable, disable USB power saving |
| `adb: more than one device`, `server version mismatch` | two adb versions / another program holds adb | close other tools, `adb kill-server`, use one platform-tools folder |
| The script says a path does not exist | data folder is a symlink or in a cloud-synced folder | use a plain local folder (`PART_DATA`) |

## 7. If it goes wrong - what to do and what NOT to do

Do:
1. **Stay calm and stop typing commands.** Read the last lines of the script output and `$PART_DATA/logs/`.
2. Try to reach **fastboot** (Power + Volume-Down) and then **recovery**.
3. Use the matching case in [RECOVERY_AND_TROUBLESHOOTING.md](RECOVERY_AND_TROUBLESHOOTING.md).
4. If you ask for help, give: the full terminal output, the log file, `fastboot getvar all` (or at least `product`, `unlocked`, `current-slot`, `anti`), and the exact step where it stopped. **Do not post the backup files** (they contain your device's disk and partition IDs).

Do **not**:
- re-run the same command in a loop hoping it works;
- flash random images "to see if it helps";
- relock the bootloader;
- use `flash_all_lock` scripts;
- run these tools on a second phone with the first one's backup (a backup belongs to one phone and one disk size; the restore script refuses a different disk size).

## 8. What this project does NOT promise

No warranty. Only one phone (256 GB-class) and two ROMs were tested; other storage sizes (128 / 512 GB), other ROM versions, Linux/macOS, and any failure in the middle of a write were **not** tested. The scripts are built to **refuse** instead of guess, but a refusal is a safety net, not a guarantee.
