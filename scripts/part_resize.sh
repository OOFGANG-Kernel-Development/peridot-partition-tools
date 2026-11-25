#!/bin/bash
# part_resize.sh - grow the 'super' partition of a peridot phone (userdata shrinks and is recreated EMPTY) and flash a matching super.
#
#   FIRST:  run it WITHOUT --execute. That is a dry run: it checks everything and changes nothing.
#
# usage:
#   part_resize.sh --factory ROMDIR [--super-gib N|auto] [--backup DIR] [--execute] [--assume-yes] [--allow-android] [--allow-rom-mismatch]
#   part_resize.sh --factory ROMDIR --super-gib N --reflash-only [--execute]     # table already N GiB: only (re)flash super+userdata, needs ONLY the bootloader
#
#   ROMDIR   the folder with super.img/userdata.img of a factory OR retail fastboot ROM (the 'images' folder, or its parent)
#   --super-gib  new size in GiB, or 'auto' (default): the size the tool suggests from what the ROM really contains (+30 % headroom)
#   --execute    really do it. ALL DATA ON THE PHONE IS ERASED. You will be asked to type ERASE.
# The phone must be in RECOVERY with root adb (normal mode) or in the BOOTLOADER (--reflash-only). Read README.md first: this can brick the phone.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
ROMARG=; GIBARG=auto; BACKUP=; EXEC=0; ASSUME_YES=0; ALLOW_ANDROID=0; ALLOW_MISMATCH=0; REFLASH=0
while [ $# -gt 0 ]; do case $1 in
  --factory|--rom) ROMARG=$2; shift 2;; --super-gib) GIBARG=$2; shift 2;; --backup) BACKUP=$2; shift 2;; --execute) EXEC=1; shift;;
  --assume-yes) ASSUME_YES=1; shift;; --allow-android) ALLOW_ANDROID=1; shift;; --allow-rom-mismatch) ALLOW_MISMATCH=1; shift;; --reflash-only) REFLASH=1; shift;;
  -h|--help) sed -n '2,16p' "$0"; exit 0;; *) die "unknown argument: $1 (see --help)";; esac; done
start_log
STAGE=start; GIB=0
stage_help(){
  echo; echo "${C_Y}--- where things stand ---${C_0}"
  case $STAGE in
    start|checks) echo "Nothing was changed on the phone.";;
    table_written) echo "The NEW partition table is written but super/userdata were NOT flashed yet. Do NOT boot Android. Continue with the phone in the bootloader:"
                   echo "   part_resize.sh --factory <ROM> --super-gib $GIB --reflash-only --execute"
                   echo "or go back (needs recovery): part_restore.sh --execute --flash-factory --factory <ROM>";;
    flashing) echo "The table is written and flashing started but did not finish. Put the phone in the bootloader (Power + Volume-Down) and run:"
              echo "   part_resize.sh --factory <ROM> --super-gib $GIB --reflash-only --execute";;
    booting) echo "Everything was flashed. The phone did not report a finished Android boot in time. A first boot after a data wipe can take 5+ minutes; wait, then check with adb.";;
  esac
  echo "Log: $LOGFILE"
}
trap 'rc=$?; [ $rc -ne 0 ] && stage_help' EXIT

need_cmds python3 timeout df tee; check_tool_exists "$ADB" adb; check_tool_exists "$FB" fastboot

say "1. the ROM package"
[ -n "$ROMARG" ] || die "give the ROM folder: --factory <folder with super.img>"
ROM=$(resolve_rom "$ROMARG") || die "no super.img found in '$ROMARG' (or its 'images' subfolder). Point --factory at the unpacked fastboot ROM."
echo "ROM images: $ROM"
check_rom "$ROM" || die "the ROM package is not usable (see above)"
python3 "$HERE/lp_resize.py" check "$ROM/super.img" > /tmp/lp_check.$$ 2>&1; lp_rc=$?; sed 's/^/    /' /tmp/lp_check.$$; rm -f /tmp/lp_check.$$
[ $lp_rc -le 1 ] || die "this super.img cannot be handled by this tool (see UNSUPPORTED above)"
if [ "$GIBARG" = auto ]; then GIB=$(python3 "$HERE/lp_resize.py" suggest "$ROM/super.img") || die "cannot compute a size"; echo "size chosen automatically: ${GIB} GiB"; else GIB=$GIBARG; fi
[[ "$GIB" =~ ^[0-9]+$ ]] || die "--super-gib must be a whole number of GiB (or 'auto')"
python3 "$HERE/lp_resize.py" check "$ROM/super.img" "$GIB" | grep -E "PROBLEM|VERDICT|requested" | sed 's/^/    /'
python3 "$HERE/lp_resize.py" check "$ROM/super.img" "$GIB" >/dev/null || die "${GIB} GiB is not acceptable for this ROM (see PROBLEM above)"
SUPER_BYTES=$(( GIB * 1024 * 1024 * 1024 ))
ROMSZ=$(( $(stat -c %s "$ROM/super.img") / 1024 / 1024 / 1024 + 1 ))
OUT=$PART_DATA/super_resize; mkdir -p "$OUT" "$WIN_STAGE/super_resize" 2>/dev/null
[ "$(free_gib "$OUT")" -ge $((ROMSZ + 1)) ] || die "not enough free disk space in $OUT (need about $((ROMSZ + 1)) GiB, have $(free_gib "$OUT"))"
[ "$(free_gib "$WIN_STAGE")" -ge $((ROMSZ + 1)) ] || die "not enough free disk space in $WIN_STAGE (need about $((ROMSZ + 1)) GiB, have $(free_gib "$WIN_STAGE"))"
ok "disk space"
ROMTAG=$(basename "$(dirname "$ROM")" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40); NEW="$OUT/super_${GIB}g_${ROMTAG}.img"

build_image(){
  if [ -f "$NEW" ] && python3 "$HERE/lp_resize.py" verify "$NEW" "$GIB" >/dev/null 2>&1; then echo "reusing $NEW"
  else say "building the ${GIB} GiB super image from this ROM (about 1-2 minutes)"; python3 "$HERE/lp_resize.py" resize "$ROM/super.img" "$NEW" "$GIB" || die "building the image failed"; fi
  cp -u "$NEW" "$WIN_STAGE/super_resize/" || die "could not copy the image to $WIN_STAGE/super_resize"
  WSUPER=$(winpath "$WIN_STAGE/super_resize/$(basename "$NEW")")
}

flash_stage(){ # phone must be in the bootloader
  fb_present || die "no phone in fastboot mode"
  local prod anti romanti
  prod=$(fb_var product); [ -z "$prod" ] || echo "$prod" | grep -qi peridot || die "fastboot says product='$prod', not peridot: refusing to flash"
  anti=$(fb_var anti | tr -dc 0-9); romanti=$(tr -dc 0-9 < "$ROM/anti_version.txt" 2>/dev/null)
  if [ -n "$anti" ] && [ -n "$romanti" ]; then [ "$anti" -le "$romanti" ] || die "anti-rollback: the phone has $anti, this ROM only $romanti. Flashing would fail or brick. Use a newer ROM."; ok "anti-rollback ok (phone $anti, ROM $romanti)"; fi
  STAGE=flashing
  "$FB" flash super "$WSUPER" || die "flash super failed"
  "$FB" erase metadata || die "erase metadata failed"
  "$FB" flash userdata "$(winpath "$ROM/userdata.img")" || die "flash userdata failed"
  "$FB" reboot; STAGE=booting
  say "waiting for Android (the first boot after a wipe can take several minutes)"
  wait_android 150 && ok "Android is up" || die "Android did not report a finished boot in time"
}
final_report(){ echo; if adb_is_root; then adbq 'lpdump 2>&1 | grep -A3 "Block device table"; lpdump 2>&1 | grep "Maximum size" | tail -2; df -h /data | tail -1'; else echo "(adb is not root here: cannot run lpdump; check storage in Settings)"; fi; echo; echo "${C_G}Done.${C_0} Log: $LOGFILE"; }

# ======================= bootloader-only mode =======================
if [ $REFLASH = 1 ]; then
  say "2. --reflash-only: the phone must be in the bootloader"
  if ! fb_present; then
    s=$(adb_state)
    if [ "$s" = device ] || [ "$s" = recovery ]; then
      if [ $EXEC = 1 ]; then echo "rebooting the phone to the bootloader..."; "$ADB" reboot bootloader; wait_fastboot 40 || die "no bootloader: hold Power + Volume-Down"
      else echo "(dry run: the phone is in adb mode; with --execute I would reboot it to the bootloader)"; fi
    elif [ $EXEC = 1 ]; then die "no phone found (adb or fastboot). Put it in the bootloader: Power + Volume-Down."; fi
  fi
  if fb_present; then
    psz=$(fb_var partition-size:super | tr -dc 0-9a-fA-Fx); [ -n "$psz" ] || die "the bootloader did not tell the size of 'super' (getvar partition-size:super). Cannot verify the table; use the normal mode in recovery."
    have=$(( psz )); [ "$have" -eq "$SUPER_BYTES" ] || die "the 'super' partition is $((have / 1024 / 1024)) MiB but you asked for ${GIB} GiB ($((SUPER_BYTES / 1024 / 1024)) MiB). --reflash-only never changes the table: choose --super-gib $((have / 1024 / 1024 / 1024)) or run the normal mode in recovery."
    ok "'super' partition is exactly ${GIB} GiB"
  fi
  [ $EXEC = 1 ] || { echo; echo "DRY RUN ONLY (reflash-only). Add --execute to flash. ALL DATA ON THE PHONE IS ERASED."; exit 0; }
  confirm "This flashes super (${GIB} GiB build of this ROM), erases metadata and flashes userdata: EVERYTHING ON THE PHONE IS ERASED." ERASE
  build_image; flash_stage; final_report; exit 0
fi

# ======================= normal mode (recovery, root adb) =======================
say "2. the phone"
st=$(adb_state)
case "$st" in
  recovery) ok "phone is in recovery";;
  device) [ $ALLOW_ANDROID = 1 ] || die "the phone is booted in Android. Reboot to recovery (adb reboot recovery) - editing the table there is safest. (Advanced: --allow-android)";;
  "") if fb_present; then die "the phone is in the bootloader. For the normal mode boot recovery. To only flash a ROM's super use --reflash-only."; else die "no phone found. Check the cable/driver and that 'adb devices' lists it."; fi;;
  *) die "unexpected adb state '$st' (need: recovery)";;
esac
adb_is_root || { explain_no_root; die "no root adb"; }
ok "root adb"
prod=$(adbq 'getprop ro.product.device; getprop ro.build.product' | tr -d '\n ')
if [ -n "$prod" ] && ! echo "$prod" | grep -qi peridot; then [ "${FORCE_OTHER_DEVICE:-0}" = 1 ] || die "this does not look like a peridot (got '$prod'). These scripts are written for peridot (SM8635) only."; warn "not a peridot, continuing because FORCE_OTHER_DEVICE=1"; else ok "device: ${prod:-peridot (recovery does not report it)}"; fi
bat=$(adbq 'cat /sys/class/power_supply/battery/capacity' | tr -dc 0-9); if [ -n "$bat" ]; then [ "$bat" -ge 50 ] && ok "battery $bat %" || die "battery is $bat %: charge to at least 50 % first (a flash that stops halfway is dangerous)"; else warn "battery level unknown: make sure it is above 50 %"; fi
DISKDEV=$(find_disk) || die "cannot find which disk holds 'super' (/dev/block/by-name/super)"; ok "'super' lives on $DISKDEV"
setup_sgdisk
printout=$(adbq "$SG --print $DISKDEV")
echo "$printout" | grep -q "Sector size (logical/physical): 4096/4096" || die "unexpected sector size (the maths here assumes 4096-byte sectors)"
SN=$(echo "$printout" | awk '$1 ~ /^[0-9]+$/ && $NF=="super" {print $1}'); UN=$(echo "$printout" | awk '$1 ~ /^[0-9]+$/ && $NF=="userdata" {print $1}')
[ -n "$SN" ] && [ -n "$UN" ] || die "partitions named super/userdata not found on $DISKDEV"
field(){ adbq "$SG --info=$1 $DISKDEV" | grep "$2" | head -1 | sed 's/^[^:]*: *//; s/ .*//'; }
SUPER_START=$(field "$SN" "First sector"); SUPER_OLD_END=$(field "$SN" "Last sector"); SUPER_GUID_TYPE=$(field "$SN" "Partition GUID code"); SUPER_GUID=$(field "$SN" "unique GUID")
UD_OLD_START=$(field "$UN" "First sector"); USERDATA_END=$(field "$UN" "Last sector"); UD_GUID_TYPE=$(field "$UN" "Partition GUID code"); UD_GUID=$(field "$UN" "unique GUID")
[ "$UD_OLD_START" -eq $((SUPER_OLD_END + 1)) ] || die "userdata does not start right after super (super ends $SUPER_OLD_END, userdata starts $UD_OLD_START): this tool only handles that layout"
# storage variants (128/256/512 GB ...): the disk size differs, so make sure userdata really is the LAST partition and fills the disk to its last usable sector
LAST_USABLE=$(echo "$printout" | sed -n 's/.*last usable sector is \([0-9]*\).*/\1/p' | head -1); DISK_SECT=$(echo "$printout" | sed -n 's/^Disk [^:]*: \([0-9]*\) sectors.*/\1/p' | head -1)
[ -n "$LAST_USABLE" ] && [ "$USERDATA_END" -eq "$LAST_USABLE" ] || die "userdata ends at $USERDATA_END but the last usable sector of the disk is ${LAST_USABLE:-unknown}: userdata is not the last partition, so this layout is not the stock one. Refusing."
echo "disk: $((DISK_SECT * 4096 / 1073741824)) GiB ($DISK_SECT sectors of 4096 bytes); userdata fills the rest of the disk"
OLD_SECT=$(( SUPER_OLD_END - SUPER_START + 1 )); SECT=$(( SUPER_BYTES / 4096 )); SUPER_END=$(( SUPER_START + SECT - 1 )); UD_START=$(( SUPER_END + 1 ))
echo "live table: super #$SN sectors $SUPER_START..$SUPER_OLD_END ($((OLD_SECT * 4096 / 1073741824)) GiB), userdata #$UN $UD_OLD_START..$USERDATA_END"
[ $SECT -gt $OLD_SECT ] || die "the new super (${GIB} GiB) is not larger than the current one ($((OLD_SECT * 4096 / 1073741824)) GiB). Only growing is supported. (If the table is already ${GIB} GiB use --reflash-only.)"
[ $((UD_START + 262144)) -lt "$USERDATA_END" ] || die "a ${GIB} GiB super would leave less than 1 GiB for userdata"
ok "layout understood; new layout: super ${GIB} GiB = sectors $SUPER_START..$SUPER_END, userdata $UD_START..$USERDATA_END ($(( (USERDATA_END - UD_START + 1) * 4096 / 1073741824 )) GiB)"
rl=$(rom_layout "$ROM")
if [ -n "$rl" ]; then rs=$(echo "$rl" | tr ' ' '\n' | grep '^super:' | cut -d: -f2); ru=$(echo "$rl" | tr ' ' '\n' | grep '^userdata:' | cut -d: -f2)
  if [ "$rs" = "$SUPER_START" ] && [ "$ru" = "$UD_OLD_START" ]; then ok "the ROM's own layout (rawprogram0.xml) starts super/userdata at the same sectors as the phone"; else warn "the ROM's rawprogram0.xml puts super at $rs and userdata at $ru; the phone has $SUPER_START / $UD_OLD_START (expected if you already resized)"; fi; fi

say "3. backup of the partition tables"
[ -n "$BACKUP" ] || BACKUP=$(ls -dt "$PART_DATA"/backups/2*/ 2>/dev/null | head -1)
[ -d "$BACKUP" ] && [ -f "$BACKUP/gpt_sda.sgdisk" ] && [ -f "$BACKUP/print_sda.txt" ] || die "no partition backup found. Run part_backup.sh first (it is read-only)."
[ -f "$WIN_STAGE/partition_backup/$(basename "$BACKUP")/gpt_sda.sgdisk" ] || die "the backup has no second copy in $WIN_STAGE/partition_backup. Copy it there (cp -r \"$BACKUP\" \"$WIN_STAGE/partition_backup/\") - a backup in one place is not a backup."
live=$(echo "$printout" | grep -E "^ +[0-9]+ " | awk '{print $1,$2,$3,$7}'); want=$(grep -E "^ +[0-9]+ " "$BACKUP/print_sda.txt" | awk '{print $1,$2,$3,$7}')
[ "$live" = "$want" ] || { diff <(echo "$want") <(echo "$live"); die "the live partition table differs from the backup '$BACKUP'. Take a fresh backup (part_backup.sh) and be sure you know why it changed."; }
ok "backup $(basename "$BACKUP") exists in two places and equals the live table"

say "4. does the ROM match the phone?"
DHEAD=$(mktemp); timeout 120 "$ADB" exec-out 'dd if=/dev/block/by-name/super bs=4096 count=256 2>/dev/null' > "$DHEAD"
python3 "$HERE/lp_resize.py" match "$DHEAD" "$ROM/super.img" | sed 's/^/    /'; mrc=${PIPESTATUS[0]}; rm -f "$DHEAD"
if [ "$mrc" = 1 ]; then
  [ $ALLOW_MISMATCH = 1 ] || die "this ROM differs from the one installed. Only super/userdata would be replaced; the firmware and boot images would NOT match and the phone will not boot. Flash the whole ROM first with its own flash_all script (NOT the _lock one), then use --reflash-only. (Override: --allow-rom-mismatch)"
  warn "ROM mismatch overridden"
elif [ "$mrc" = 2 ]; then warn "could not compare (the phone's super is unreadable): make sure this ROM is the one installed"
else ok "same ROM"; fi

say "5. plan"
NEWSG="--set-alignment=1 --delete=$SN --delete=$UN --new=$SN:$SUPER_START:$SUPER_END --typecode=$SN:$SUPER_GUID_TYPE --partition-guid=$SN:$SUPER_GUID --change-name=$SN:super --new=$UN:$UD_START:$USERDATA_END --typecode=$UN:$UD_GUID_TYPE --partition-guid=$UN:$UD_GUID --change-name=$UN:userdata"
adbq "$SG --pretend $NEWSG --print $DISKDEV" | grep -E " super| userdata|free space|Warning|Error|problem" | sed 's/^/    /'
adbq "$SG --pretend $NEWSG --print $DISKDEV" | grep -qE "^ +$SN +$SUPER_START +$SUPER_END " || die "the dry run of the new table did not give the expected result"
ok "the new table checks out (sgdisk --pretend, nothing written)"
[ $EXEC = 1 ] || { echo; echo "${C_G}DRY RUN ONLY - nothing was changed.${C_0} If every line above is OK, run again with --execute. ALL DATA ON THE PHONE WILL BE ERASED."; exit 0; }

confirm "About to repartition: super -> ${GIB} GiB, userdata recreated EMPTY, super/metadata/userdata reflashed from this ROM. EVERYTHING ON THE PHONE WILL BE ERASED. Do not unplug the cable until it says Done." ERASE
STAGE=checks
build_image
say "6. write the new partition table"
adbq "$SG $NEWSG $DISKDEV" | tail -3; adbq sync >/dev/null; STAGE=table_written
after=$(adbq "$SG --print $DISKDEV"); echo "$after" | grep -E " super| userdata"
echo "$after" | grep -qE "^ +$SN +$SUPER_START +$SUPER_END " || die "the table read back is not what was intended. Do NOT reboot: run part_restore.sh --execute now."
adbq "$SG --backup=$DEVTMP/gpt_sda_after.sgdisk $DISKDEV" >/dev/null; ( cd "$BACKUP" && timeout 30 "$ADB" pull $DEVTMP/gpt_sda_after.sgdisk "gpt_sda_after_${GIB}g.sgdisk" >/dev/null 2>&1 ); echo "$after" > "$BACKUP/print_sda_after_${GIB}g.txt"
say "7. clear the recovery flag, bootloader, flash"
# 'adb reboot recovery' leaves a boot-recovery command in misc; if it stays, every later boot returns to recovery
adbq 'dd if=/dev/zero of=/dev/block/by-name/misc bs=2048 count=1 2>&1 | tail -1; sync' >/dev/null
timeout 20 "$ADB" reboot bootloader
wait_fastboot 40 || die "the phone did not reach the bootloader (hold Power + Volume-Down), then run: part_resize.sh --factory <ROM> --super-gib $GIB --reflash-only --execute"
flash_stage
say "8. result"; final_report
