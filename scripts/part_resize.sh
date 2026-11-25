#!/bin/bash
# part_resize.sh - grow the 'super' partition of peridot's sda (userdata shrinks and is recreated EMPTY), then flash a matching super.
#
# Flow (phone must be in STOCK RECOVERY with adb root, nothing mounted):
#   1. checks the backup exists (host + Windows copy) and that the live table still equals the backed-up one
#   2. builds a resized super image from the factory package (lp_resize.py patches the LP metadata only)
#   3. dry-runs the new GPT with sgdisk --pretend on the phone
#   4. [--execute] writes the GPT, reboots to the bootloader, flashes super + erases metadata + flashes userdata, reboots, verifies
#
# usage: part_resize.sh [--super-gib N] [--factory DIR] [--backup DIR] [--execute]
#   default: dry run, N=12.   Everything on the phone's /data is lost when --execute is used.
# Restore: part_restore.sh (uses the same backup).  READ README.md FIRST: this can brick the phone.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ADB=${ADB:-/mnt/c/platform-tools/adb.exe}; FB=${FB:-/mnt/c/platform-tools/fastboot.exe}
DATA=${PART_DATA:-$HOME/peridot-partition-data}      # backups, sgdisk bundle and generated images live here
WIN_STAGE=${WIN_STAGE:-/mnt/c/peridot_flash}             # a Windows folder (seen from WSL) where Windows fastboot can read files
FACTORY=${FACTORY:-}                                     # the factory/fastboot ROM "images" folder (must contain super.img, userdata.img)
BACKUP=${BACKUP:-$(ls -dt "$DATA"/backups/2*/ 2>/dev/null | head -1)}
SGB=${SGB:-$DATA/sgdisk_bundle}
OUT=${OUT:-$DATA/super_resize}; WINOUT=$WIN_STAGE/super_resize
GIB=12; EXEC=0
while [ $# -gt 0 ]; do case $1 in
  --super-gib) GIB=$2; shift 2;; --factory) FACTORY=$2; shift 2;; --backup) BACKUP=$2; shift 2;; --execute) EXEC=1; shift;;
  *) echo "unknown arg $1"; exit 2;; esac; done
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo; echo "== $*"; }
adbq(){ timeout 120 "$ADB" shell "$@" 2>&1 | tr -d '\r'; }

say "0. preconditions"
[ -d "$BACKUP" ] && [ -f "$BACKUP/gpt_sda.sgdisk" ] && [ -f "$BACKUP/print_sda.txt" ] || die "no partition backup found (run part_backup.sh first): '$BACKUP'"
ls "$WIN_STAGE/partition_backup/$(basename "$BACKUP")/gpt_sda.sgdisk" >/dev/null 2>&1 || die "backup has no second copy in $WIN_STAGE/partition_backup (cp -r \"$BACKUP\" there first)"
[ -n "$FACTORY" ] || die "set --factory DIR (the factory ROM 'images' folder)"
[ -f "$FACTORY/super.img" ] || die "factory super.img not found in $FACTORY"
for f in sgdisk libext2_uuid.so libc++.so; do [ -f "$SGB/$f" ] || die "missing $SGB/$f (pull it from /system/bin and /system/lib64 of the booted phone)"; done
st=$(timeout 10 "$ADB" get-state 2>/dev/null | tr -d '\r'); [ "$st" = recovery ] || die "phone must be in recovery (adb reboot recovery); state='$st'"
echo "backup: $BACKUP (+ second copy)"

say "1. push sgdisk and compare the live table with the backup"
adbq 'mkdir -p /tmp/sgb' >/dev/null
for f in sgdisk libext2_uuid.so libc++.so; do timeout 60 "$ADB" push "$(wslpath -w "$SGB/$f")" /tmp/sgb/$f >/dev/null 2>&1 || die "adb push of $f failed (is the phone reachable? is $SGB a real folder, not a symlink?)"; done
adbq 'chmod 755 /tmp/sgb/sgdisk'
SG='LD_LIBRARY_PATH=/tmp/sgb:/system/lib64 /tmp/sgb/sgdisk'
live=$(adbq "$SG --print /dev/block/sda" | grep -E "^ +[0-9]+ " | awk '{print $1,$2,$3,$7}')
want=$(grep -E "^ +[0-9]+ " "$BACKUP/print_sda.txt" | awk '{print $1,$2,$3,$7}')
[ "$live" = "$want" ] || { diff <(echo "$want") <(echo "$live"); die "live partition table differs from the backup; refusing"; }
echo "live table == backup ($(echo "$live" | wc -l) partitions)"

say "1b. read super/userdata from the live table (by name, nothing hard-coded)"
prod=$(adbq 'getprop ro.product.device; getprop ro.build.product' | tr -d '\n ')
if [ -n "$prod" ] && ! echo "$prod" | grep -qi peridot; then [ "${FORCE_OTHER_DEVICE:-0}" = 1 ] || die "this does not look like a peridot (got '$prod'). These scripts are written for peridot (SM8635) only."; fi
printout=$(adbq "$SG --print /dev/block/sda")
echo "$printout" | grep -q "Sector size (logical/physical): 4096/4096" || die "unexpected sector size (the maths here assumes 4096-byte sectors)"
SN=$(echo "$printout" | awk '$1 ~ /^[0-9]+$/ && $NF=="super" {print $1}'); UN=$(echo "$printout" | awk '$1 ~ /^[0-9]+$/ && $NF=="userdata" {print $1}')
[ -n "$SN" ] && [ -n "$UN" ] || die "partitions named super/userdata not found on sda"
field(){ adbq "$SG --info=$1 /dev/block/sda" | grep "$2" | head -1 | sed 's/^[^:]*: *//; s/ .*//'; }
SUPER_START=$(field $SN "First sector"); SUPER_OLD_END=$(field $SN "Last sector"); SUPER_GUID_TYPE=$(field $SN "Partition GUID code"); SUPER_GUID=$(field $SN "unique GUID")
UD_OLD_START=$(field $UN "First sector"); USERDATA_END=$(field $UN "Last sector"); UD_GUID_TYPE=$(field $UN "Partition GUID code"); UD_GUID=$(field $UN "unique GUID")
[ $UD_OLD_START -eq $((SUPER_OLD_END + 1)) ] || die "userdata does not start right after super (super ends $SUPER_OLD_END, userdata starts $UD_OLD_START): this tool only handles that layout"
SECT=$(( GIB * 1024 * 1024 * 1024 / 4096 )); SUPER_END=$(( SUPER_START + SECT - 1 )); UD_START=$(( SUPER_END + 1 ))
[ $SECT -gt $((SUPER_OLD_END - SUPER_START + 1)) ] || die "new super ($GIB GiB) is not larger than the current one; shrinking is not supported"
[ $((UD_START + 262144)) -lt $USERDATA_END ] || die "super of $GIB GiB leaves less than 1 GiB for userdata"
echo "partition numbers: super=$SN userdata=$UN"; echo "new layout: super ${GIB} GiB = sectors $SUPER_START..$SUPER_END, userdata $UD_START..$USERDATA_END"

say "2. build the resized super image ($GIB GiB)"
mkdir -p "$OUT" "$WINOUT"; NEW="$OUT/super_${GIB}g.img"
if [ -f "$NEW" ] && python3 "$HERE/lp_resize.py" verify "$NEW" $GIB >/dev/null 2>&1; then echo "reusing $NEW"; else python3 "$HERE/lp_resize.py" resize "$FACTORY/super.img" "$NEW" $GIB || die "lp_resize failed"; fi
NEWSG="--set-alignment=1 --delete=$SN --delete=$UN --new=$SN:$SUPER_START:$SUPER_END --typecode=$SN:$SUPER_GUID_TYPE --partition-guid=$SN:$SUPER_GUID --change-name=$SN:super --new=$UN:$UD_START:$USERDATA_END --typecode=$UN:$UD_GUID_TYPE --partition-guid=$UN:$UD_GUID --change-name=$UN:userdata"

say "3. dry run on the phone (sgdisk --pretend, nothing is written)"
adbq "$SG --pretend $NEWSG --print /dev/block/sda" | grep -E " super| userdata|free space|Warning|Error|problem"
adbq "$SG --pretend $NEWSG --print /dev/block/sda" | grep -qE "^ +$SN +$SUPER_START +$SUPER_END " || die "dry run did not give the expected super extent"
[ $EXEC = 1 ] || { echo; echo "DRY RUN ONLY. Re-run with --execute to write the table and flash (ALL DATA ON THE PHONE IS LOST)."; exit 0; }

say "4. WRITE the new GPT (recovery, nothing mounted)"
adbq "$SG $NEWSG /dev/block/sda" | tail -3; adbq sync
after=$(adbq "$SG --print /dev/block/sda"); echo "$after" | grep -E " super| userdata"
echo "$after" | grep -qE "^ +$SN +$SUPER_START +$SUPER_END " || die "table after the write is not what was intended: restore with part_restore.sh!"
adbq "$SG --backup=/tmp/gpt_sda_after.sgdisk /dev/block/sda" >/dev/null; ( cd "$BACKUP" && timeout 30 "$ADB" pull /tmp/gpt_sda_after.sgdisk "gpt_sda_after_${GIB}g.sgdisk" >/dev/null 2>&1 )
echo "$after" > "$BACKUP/print_sda_after_${GIB}g.txt"

say "5. clear the recovery flag, then bootloader + flash"
# 'adb reboot recovery' leaves a "boot-recovery" command in the misc partition; if it is not cleared every later boot goes back to recovery
adbq 'dd if=/dev/zero of=/dev/block/by-name/misc bs=2048 count=1 2>&1 | tail -1; sync' >/dev/null
timeout 20 "$ADB" reboot bootloader
for i in $(seq 1 40); do timeout 6 "$FB" devices 2>/dev/null | grep -q fastboot && break; sleep 3; done
timeout 6 "$FB" devices 2>/dev/null | grep -q fastboot || die "phone did not reach the bootloader (hold Power + Volume-Down), then run: part_resize.sh --flash-only"
cp -u "$NEW" "$WINOUT/"; WSUPER=$(wslpath -w "$WINOUT/super_${GIB}g.img"); WUD=$(wslpath -w "$FACTORY/userdata.img")
"$FB" flash super "$WSUPER" || die "flash super failed"
"$FB" erase metadata || die "erase metadata failed"
"$FB" flash userdata "$WUD" || die "flash userdata failed"
"$FB" reboot
say "6. boot + verify"
# wait for a real Android boot: adb state 'device' (NOT 'recovery') and sys.boot_completed=1
for i in $(seq 1 120); do st=$(timeout 8 "$ADB" get-state 2>/dev/null | tr -d '\r'); r=$(timeout 8 "$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r'); [ "$st" = device ] && [ "$r" = 1 ] && break; sleep 6; done
echo "adb state=$st boot_completed=$r"; [ "$st" = device ] || echo "WARNING: the phone is not in Android (state '$st'). If it is in recovery, see docs/RECOVERY_AND_TROUBLESHOOTING.md (recovery flag)."
adbq 'lpdump 2>&1 | grep -A3 "Block device table" ; lpdump 2>&1 | grep -E "Maximum size"; sgdisk --print /dev/block/sda | grep -E " super| userdata"; df -h /data | tail -1'
