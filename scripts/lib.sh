#!/bin/bash
# lib.sh - shared helpers for the peridot partition tools. Sourced by the other scripts; not meant to be run directly.

# ---------- configuration (override with environment variables) ----------
PART_DATA=${PART_DATA:-$HOME/peridot-partition-data}      # backups, logs, sgdisk bundle and generated images live here (use a normal local folder, NOT OneDrive/Dropbox)
SGB=${SGB:-$PART_DATA/sgdisk_bundle}
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ---------- environment: WSL (Windows adb/fastboot) or plain Linux/macOS ----------
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=1
  ADB=${ADB:-$( [ -x /mnt/c/platform-tools/adb.exe ] && echo /mnt/c/platform-tools/adb.exe || echo adb.exe )}
  FB=${FB:-$( [ -x /mnt/c/platform-tools/fastboot.exe ] && echo /mnt/c/platform-tools/fastboot.exe || echo fastboot.exe )}
  WIN_STAGE=${WIN_STAGE:-/mnt/c/peridot_flash}            # a Windows folder (seen from WSL) where Windows fastboot can read big images
else
  IS_WSL=0
  ADB=${ADB:-adb}; FB=${FB:-fastboot}
  WIN_STAGE=${WIN_STAGE:-$PART_DATA/stage}
fi
# path as the Windows tools need it (WSL) or unchanged (native)
winpath(){ if [ "$IS_WSL" = 1 ]; then wslpath -w "$1"; else echo "$1"; fi; }

# ---------- output ----------
if [ -t 1 ]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[1m'; C_0=$'\e[0m'; else C_R=; C_G=; C_Y=; C_B=; C_0=; fi
say(){ echo; echo "${C_B}== $*${C_0}"; }
ok(){ echo "  ${C_G}OK${C_0}    $*"; }
warn(){ echo "  ${C_Y}WARN${C_0}  $*"; }
bad(){ echo "  ${C_R}FAIL${C_0}  $*"; }
die(){ echo; echo "${C_R}ERROR:${C_0} $*" >&2; [ -n "${LOGFILE:-}" ] && echo "(log: $LOGFILE)" >&2; exit 1; }
start_log(){ mkdir -p "$PART_DATA/logs"; LOGFILE="$PART_DATA/logs/$(basename "$0" .sh)_$(date +%Y%m%d_%H%M%S).log"; exec > >(tee -a "$LOGFILE") 2>&1; echo "log: $LOGFILE"; }

# type the word to continue (beginner brake). ASSUME_YES=1 skips (for automation).
confirm(){ # confirm "what will happen" WORD
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  [ -t 0 ] || die "this step needs you to confirm by typing; run it in an interactive terminal (or pass --assume-yes if you really know what you are doing)"
  echo; echo "${C_Y}$1${C_0}"; read -r -p "Type  $2  to continue, anything else cancels: " ans
  [ "$ans" = "$2" ] || die "cancelled, nothing was changed"
}

# ---------- adb / fastboot ----------
adbq(){ timeout "${ADB_TIMEOUT:-120}" "$ADB" shell "$@" 2>&1 | tr -d '\r'; }
adb_state(){ timeout 10 "$ADB" get-state 2>/dev/null | tr -d '\r'; }
fb_present(){ timeout 8 "$FB" devices 2>/dev/null | grep -q fastboot; }
fb_var(){ timeout 15 "$FB" getvar "$1" 2>&1 | tr -d '\r' | grep -E "^$1:" | head -1 | sed "s/^$1: *//"; }
wait_adb_state(){ # wait_adb_state recovery|device [tries]
  local want=$1 n=${2:-60} i s; for i in $(seq 1 "$n"); do s=$(adb_state); [ "$s" = "$want" ] && return 0; sleep 4; done; return 1; }
wait_fastboot(){ local i; for i in $(seq 1 "${1:-40}"); do fb_present && return 0; sleep 3; done; return 1; }
wait_android(){ local i st r; for i in $(seq 1 "${1:-150}"); do st=$(adb_state); r=$(timeout 8 "$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r'); [ "$st" = device ] && [ "$r" = 1 ] && return 0; sleep 6; done; return 1; }
# 'adb shell' must give uid 0 for everything we do
adb_is_root(){ [ "$(adbq id -u | tr -dc 0-9)" = 0 ]; }
# stock recovery of a retail ROM often has no adb shell; say so clearly
explain_no_root(){ cat <<'E'
  The phone answers adb but 'adb shell' is not root (or there is no shell). This tool needs root adb to edit the partition table:
    - the factory/engineering ROM (userdebug) gives root adb in Android AND in recovery;
    - retail ROM recoveries usually only offer sideload. Use the engineering ROM, or a recovery that gives root adb.
  If the table is already the size you want and you only need to flash a ROM's super, use:  --reflash-only  (needs only the bootloader).
E
}

# writable scratch folder ON THE PHONE: recovery has /tmp, Android does not (use /data/local/tmp there)
DEVTMP=
devtmp_init(){ DEVTMP=$(adbq '[ -d /tmp ] && echo /tmp || echo /data/local/tmp' | tr -d '\n '); [ -n "$DEVTMP" ] || DEVTMP=/data/local/tmp; adbq "mkdir -p $DEVTMP" >/dev/null; }

# ---------- sgdisk (recovery has none: use the bundle pulled from the phone) ----------
SG=
setup_sgdisk(){
  [ -n "$DEVTMP" ] || devtmp_init
  if adbq 'which sgdisk' | grep -q sgdisk; then SG=sgdisk; return 0; fi
  local f; for f in sgdisk libext2_uuid.so libc++.so; do [ -f "$SGB/$f" ] || die "missing $SGB/$f. Run scripts/pull_sgdisk.sh once while the phone is booted in Android."; done
  [ -n "$DEVTMP" ] || devtmp_init
  adbq "mkdir -p $DEVTMP/sgb" >/dev/null
  for f in sgdisk libext2_uuid.so libc++.so; do timeout 60 "$ADB" push "$(winpath "$SGB/$f")" $DEVTMP/sgb/$f >/dev/null 2>&1 || die "adb push of $f failed (is $SGB a real folder, not a symlink / synced cloud folder?)"; done
  adbq "chmod 755 $DEVTMP/sgb/sgdisk" >/dev/null
  SG="LD_LIBRARY_PATH=$DEVTMP/sgb:/system/lib64 $DEVTMP/sgb/sgdisk"
  adbq "$SG --version" | grep -qi sgdisk || die "sgdisk does not run on this phone/recovery (libraries differ). Pull a fresh bundle from THIS ROM with pull_sgdisk.sh."
}

# which disk holds 'super', e.g. /dev/block/sda
find_disk(){
  local p; p=$(adbq 'readlink -f /dev/block/by-name/super' | tr -d '\n ')
  [[ "$p" =~ ^/dev/block/(sd[a-z])[0-9]+$ ]] || { echo ""; return 1; }
  echo "/dev/block/${BASH_REMATCH[1]}"
}

# ---------- ROM folder ----------
# accepts the images folder, or its parent (one level), returns the folder that contains super.img
resolve_rom(){
  local d=$1
  [ -d "$d" ] || { echo ""; return 1; }
  if [ -f "$d/super.img" ]; then echo "$d"; return 0; fi
  if [ -f "$d/images/super.img" ]; then echo "$d/images"; return 0; fi
  echo ""; return 1
}
# ROM folder sanity: prints findings, returns non-zero on blocking problems
check_rom(){
  local R=$1 rc=0 f
  for f in super.img userdata.img; do [ -f "$R/$f" ] && ok "$f present ($(du -h "$R/$f" | cut -f1))" || { bad "$f missing in $R"; rc=1; }; done
  ls "$R"/super.img_sparsechunk.* "$R"/super_[0-9]*.img >/dev/null 2>&1 && { bad "this ROM ships a SPLIT super image (sparsechunk). Merge it first (simg2img) - not supported by this tool."; rc=1; }
  [ -f "$R/rawprogram0.xml" ] && ok "rawprogram0.xml present (partition layout of this ROM)" || warn "rawprogram0.xml not found: cannot compare the ROM's layout with the phone"
  [ -f "$R/anti_version.txt" ] && ok "anti-rollback value of this ROM: $(tr -dc 0-9 < "$R/anti_version.txt")" || warn "no anti_version.txt"
  [ -f "$R/../flash_all.sh" ] || [ -f "$R/../flash_all.bat" ] || warn "no flash_all script next to the images folder (is this a complete fastboot ROM?)"
  return $rc
}
# in rawprogram0.xml: super start sector / size (KiB) and userdata start, to compare with the live table
rom_layout(){ python3 - "$1/rawprogram0.xml" <<'E' 2>/dev/null
import re,sys
t=open(sys.argv[1]).read(); d={}
for m in re.finditer(r'<program ([^>]*)/>',t):
    a=dict(re.findall(r'(\w+)="([^"]*)"',m.group(1)))
    if a.get('label') in ('super','userdata','metadata'): d[a['label']]=(a.get('start_sector'),a.get('num_partition_sectors'))
print(' '.join(f"{k}:{v[0]}:{v[1]}" for k,v in d.items()))
E
}

# ---------- host checks ----------
free_gib(){ df -P --block-size=1G "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
need_cmds(){ local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "'$c' is not installed (in WSL/Ubuntu: sudo apt install -y python3 coreutils)"; done; }
check_tool_exists(){ # adb / fastboot present and runnable
  local t=$1 name=$2; "$t" version >/dev/null 2>&1 || "$t" --version >/dev/null 2>&1 || die "$name not found or not runnable at '$t'. Install Android platform-tools (see README) or set ADB= / FB="; }
