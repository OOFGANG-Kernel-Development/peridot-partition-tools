#!/bin/bash
# rom_check.sh - check a downloaded ROM WITHOUT a phone: is the package complete, what does its super contain, which size is suggested.
# usage: rom_check.sh <ROM folder>        (the unpacked fastboot ROM; the 'images' folder or its parent)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
need_cmds python3 df; [ $# -eq 1 ] || die "usage: rom_check.sh <ROM folder>"
ROM=$(resolve_rom "$1") || die "no super.img in '$1' (or its 'images' subfolder). Did you unpack the .tgz completely (it must be unpacked twice: .tgz -> .tar -> folder)?"
say "package: $ROM"; check_rom "$ROM" || { echo; die "the package is incomplete or unsupported (see above)"; }
say "what is inside the super image"; python3 "$HERE/lp_resize.py" check "$ROM/super.img"; rc=$?
say "disk space"; echo "free in $PART_DATA: $(free_gib "$(dirname "$PART_DATA")") GiB; free in $WIN_STAGE: $(free_gib "$(dirname "$WIN_STAGE")" 2>/dev/null) GiB; a resized image needs about $(( $(stat -c %s "$ROM/super.img") / 1073741824 + 1 )) GiB in each"
[ $rc -le 1 ] && { echo; echo "Use e.g.:  part_resize.sh --factory \"$1\" --super-gib $(python3 "$HERE/lp_resize.py" suggest "$ROM/super.img")"; }
exit $rc
