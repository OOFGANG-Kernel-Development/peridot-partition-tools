# Recovery and troubleshooting

> Read the warnings in the [README](../README.md) first. Everything below assumes you made a backup with `scripts/part_backup.sh` **before** changing anything.

## Quick decision table

| What you see | What it means | What to do |
|---|---|---|
| A script prints `ERROR: ...` before `--execute` writes anything | A safety check failed; **nothing was changed** | Read the message. Fix the cause (phone not in recovery, wrong ROM folder, no backup, table differs from the backup). Do not bypass the check |
| `live partition table differs from the backup` | Someone/something changed the table since the backup | Take a **new** backup, make sure you know why it changed, then retry |
| Dry run is fine, `--execute` stops at "table after the write is not what was intended" | The write did not give the expected table | **Do not reboot.** Run `part_restore.sh --execute` right away (still in recovery) |
| Phone stays on the logo / reboots / goes to recovery after the flash | Image flashed but Android did not come up | Reach the bootloader (Power + Volume-Down), re-flash `super`, erase `metadata`, flash `userdata` (see "Re-flash by hand") |
| Phone reaches the bootloader (fastboot works), but nothing boots | The table is probably fine; the data is incomplete | Run the factory ROM's own `flash_all` script, or "Re-flash by hand" below |
| Phone is **dead** (no logo, no fastboot) | The bootloader chain or the table is damaged | See "Last resort: EDL" |
| Phone keeps booting into **recovery** after the script, although the flash steps all succeeded | `adb reboot recovery` left a `boot-recovery` command in the `misc` partition and nothing cleared it (older script versions) | From recovery: `adb shell dd if=/dev/zero of=/dev/block/by-name/misc bs=2048 count=1` then `adb reboot`. This only clears the 2048-byte boot message, exactly what recovery itself does. The current scripts do it for you |
| `adb` does not list the phone in recovery | USB / driver / recovery without adb | Reconnect, try another cable/port, `adb kill-server`, reboot to recovery again. If this recovery has no adb, you cannot use these scripts on that ROM |
| `fastboot devices` empty although the phone shows the fastboot screen | Windows driver / cable | Reinstall the Google/Xiaomi USB driver, use a USB 2.0 port, do not use hubs |
| Windows `fastboot flash super` is very slow | 4 GB over USB | Normal: several minutes. Do not unplug |

## Restore the original partition table (from your backup)

The phone must be in recovery (`adb reboot recovery`) with adb root.

```bash
bash scripts/part_restore.sh                                                  # dry run: shows what would be restored
bash scripts/part_restore.sh --execute                                        # writes the saved table back and checks it
bash scripts/part_restore.sh --execute --flash-factory --factory "$FACTORY"   # same + re-flash factory super/userdata and boot
```

The table comes from `gpt_sda.sgdisk` (created by `sgdisk --backup`), the same format Android's `sgdisk --load-backup` reads.
Restoring the table does not bring back the *contents* of `userdata`: that data is gone after a resize. Restoring only gives you the original layout, onto which the factory `super`/`userdata` can be flashed.

## Re-flash by hand (bootloader)

Put the phone in the bootloader (**Power + Volume-Down**, or `adb reboot bootloader`). Then, from Windows (`cmd`) or WSL with `fastboot.exe`:

```text
fastboot flash super    <factory images>\super.img          (or the resized image, if the table is the resized one!)
fastboot erase metadata
fastboot flash userdata <factory images>\userdata.img
fastboot reboot
```

Important: the `super` image **must match the table in use**. The factory `super.img` (8.5 GiB) is fine on the original layout *and* on a bigger partition,
but a **resized** image (for example 12 GiB) must not be flashed onto the original, smaller partition.

To flash everything the factory way, use the `flash_all.sh` / `flash_all.bat` of your factory ROM. That does **not** repartition the phone; it only writes the images into the existing partitions.

## Check the current state at any time (read only)

```bash
adb shell sgdisk --print /dev/block/sda          # the partition table (in recovery use the bundle: see part_restore.sh)
adb shell lpdump                                 # the dynamic-partition metadata (Android system, not recovery)
adb shell blockdev --getsize64 /dev/block/by-name/super
```

## Last resort: EDL (Qualcomm Emergency Download)

If the phone no longer shows a logo **and** no fastboot, the only way back is usually EDL (9008) mode.

- The factory ROM contains `rawprogram*.xml`, `patch*.xml` and `gpt_*.bin`: they describe the **factory partition layout** and are used with QFIL/`edl`-style tools together with a **firehose programmer** (a signed `prog_firehose*.elf/.mbn`).
  That programmer is **not** part of these scripts and is often **not** in the fastboot package. On many Xiaomi devices EDL also needs a **Xiaomi-authorised** account/tool. You may not be able to use it.
- If you can use EDL: flash the factory `rawprogram`/`patch` set. That rewrites the original table (including `super`/`userdata` at their stock positions).
- The LUN tables saved by `part_backup.sh` (`gpt_<lun>.sgdisk`, `head_<lun>.bin`, `tail_<lun>.bin`) are extra evidence of the exact layout of **your** phone if you need to compare.

Because EDL may be unavailable, treat the partition-table change as **risky** and only do it on a phone you can afford to lose.

## Things that usually go wrong for beginners

1. **Wrong ROM folder.** `--factory` must point to the folder that contains `super.img` (usually `images`), for the **same ROM version** as on the phone.
2. **Not in recovery.** `part_resize.sh --execute` refuses unless `adb get-state` says `recovery`.
3. **Forgetting the data loss.** `userdata` is recreated. Copy your files off first.
4. **No second copy of the backup.** The scripts store one on the PC and one on the Windows side; also copy it to another device.
5. **Interrupting a flash.** Wait for the script to print the final `boot_completed=1` and sizes.
6. **Running a script from a 'cloud' folder** (OneDrive etc.). Use a normal local folder for `PART_DATA`; synced folders can lock or delay big files.

## Collecting information for a bug report

Include the output of the script (copy the whole terminal), `sgdisk --print /dev/block/sda`, `getprop ro.build.fingerprint`, and which step failed. **Do not** post the `gpt_*.sgdisk`/`head_*`/`tail_*` files publicly: they contain your disk and partition GUIDs.
