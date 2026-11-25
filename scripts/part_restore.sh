#!/bin/bash
# part_restore.sh - put the ORIGINAL partition table back (from a part_backup.sh backup) and optionally re-flash the factory super/userdata.
# The phone must be in RECOVERY with root adb. Dry run unless --execute.
# usage: part_restore.sh [--backup DIR] [--factory ROMDIR] [--flash-factory] [--execute] [--assume-yes]
#   --flash-factory  after the table is back: bootloader, flash ROM super.img + erase metadata + flash userdata, reboot  (needed: the data inside
#                    the partitions was recreated by part_resize.sh). EVERYTHING ON THE PHONE IS ERASED.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
BACKUP=; ROMARG=; EXEC=0; FLASH=0; ASSUME_YES=0
while [ $# -gt 0 ]; do case $1 in
  --backup) BACKUP=$2; shift 2;; --factory|--rom) ROMARG=$2; shift 2;; --flash-factory) FLASH=1; shift;; --execute) EXEC=1; shift;; --assume-yes) ASSUME_YES=1; shift;;
  -h|--help) sed -n '2,8p' "$0"; exit 0;; *) die "unknown argument: $1";; esac; done
start_log
need_cmds python3 timeout; check_tool_exists "$ADB" adb
[ -n "$BACKUP" ] || BACKUP=$(ls -dt "$PART_DATA"/backups/2*/ 2>/dev/null | head -1)
[ -f "$BACKUP/gpt_sda.sgdisk" ] && [ -f "$BACKUP/print_sda.txt" ] || die "backup not found: '$BACKUP'"
( cd "$BACKUP" && sha256sum -c SHA256.txt --quiet 2>/dev/null ) && ok "backup checksums match" || warn "backup checksums could not be verified (SHA256.txt missing or files changed)"
say "phone"
st=$(adb_state); [ "$st" = recovery ] || die "the phone must be in recovery (state '${st:-none}'). adb reboot recovery"
adb_is_root || { explain_no_root; die "no root adb"; }
setup_sgdisk
DISKDEV=$(find_disk) || die "cannot find the disk that holds 'super'"; echo "disk: $DISKDEV"
[ "$DISKDEV" = /dev/block/sda ] || die "the backup file is for sda but super is on $DISKDEV"
timeout 60 "$ADB" push "$(winpath "$BACKUP/gpt_sda.sgdisk")" $DEVTMP/gpt_sda.sgdisk >/dev/null 2>&1 || die "adb push of the backup table failed"
# a backup belongs to ONE phone: refuse to write it onto a disk of another size (128/256/512 GB variants differ)
bk=$(sed -n 's/^Disk [^:]*: \([0-9]*\) sectors.*/\1/p' "$BACKUP/print_sda.txt" | head -1); lv=$(adbq "$SG --print $DISKDEV" | sed -n 's/^Disk [^:]*: \([0-9]*\) sectors.*/\1/p' | head -1)
[ -n "$bk" ] && [ "$bk" = "$lv" ] || die "this backup is for a disk of $bk sectors but this phone's disk has ${lv:-?} sectors: it is a different storage variant or phone. Refusing to restore it."
ok "backup and phone have the same disk size ($((lv * 4096 / 1073741824)) GiB)"
echo "-- current table:"; adbq "$SG --print $DISKDEV" | grep -E " super| userdata"
echo "-- table that will be restored (dry run, nothing written):"; adbq "$SG --pretend --load-backup=$DEVTMP/gpt_sda.sgdisk --print $DISKDEV" | grep -E " super| userdata|Warning|Error|problem"
[ $EXEC = 1 ] || { echo; echo "${C_G}DRY RUN ONLY.${C_0} Re-run with --execute (and --flash-factory --factory <ROM>)."; exit 0; }
if [ $FLASH = 1 ]; then ROM=$(resolve_rom "$ROMARG") || die "--flash-factory needs --factory <ROM folder with super.img/userdata.img>"; check_rom "$ROM" || die "ROM not usable"; fi
confirm "About to write the ORIGINAL partition table back${FLASH:+ and re-flash the factory super/userdata (ALL DATA IS ERASED)}." ERASE
say "writing the original table back"
adbq "$SG --load-backup=$DEVTMP/gpt_sda.sgdisk $DISKDEV" | tail -3; adbq sync >/dev/null
want=$(grep -E "^ +[0-9]+ " "$BACKUP/print_sda.txt" | awk '{print $1,$2,$3,$7}'); live=$(adbq "$SG --print $DISKDEV" | grep -E "^ +[0-9]+ " | awk '{print $1,$2,$3,$7}')
[ "$live" = "$want" ] || { diff <(echo "$want") <(echo "$live"); die "table after restore differs from the backup"; }
ok "restored: the live table equals the backup"
[ $FLASH = 1 ] || { echo "Table restored. Now flash the ROM's super/metadata/userdata (run again with --flash-factory --factory <ROM>, or use the ROM's flash_all)."; exit 0; }
say "clear the recovery flag, bootloader, factory super/userdata"
adbq 'dd if=/dev/zero of=/dev/block/by-name/misc bs=2048 count=1 2>&1 | tail -1; sync' >/dev/null
timeout 20 "$ADB" reboot bootloader; wait_fastboot 40 || die "no bootloader (hold Power + Volume-Down), then flash by hand: fastboot flash super super.img; fastboot erase metadata; fastboot flash userdata userdata.img"
prod=$(fb_var product); [ -z "$prod" ] || echo "$prod" | grep -qi peridot || die "fastboot says product='$prod': refusing"
anti=$(fb_var anti | tr -dc 0-9); ra=$(tr -dc 0-9 < "$ROM/anti_version.txt" 2>/dev/null); [ -z "$anti" ] || [ -z "$ra" ] || [ "$anti" -le "$ra" ] || die "anti-rollback: phone $anti > ROM $ra"
"$FB" flash super "$(winpath "$ROM/super.img")" || die "flash super failed"
"$FB" erase metadata && "$FB" flash userdata "$(winpath "$ROM/userdata.img")" || die "userdata step failed"
"$FB" reboot; say "waiting for Android"; wait_android 150 && ok "Android is up" || warn "no finished boot reported in time (a first boot after a wipe can take 5+ minutes)"
