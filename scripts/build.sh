#!/usr/bin/env bash
# =====================================================================
# NetHunter multi-WiFi kernel builder
# Device : Xiaomi Redmi Note 9S (curtana) — stock MIUI 14 / Android 12
#          (also works for the whole miatoll family: joyeuse, excalibur,
#           gram — Redmi Note 9 Pro / Pro Max)
# Base   : LineageOS android_kernel_xiaomi_sm6250 (Linux 4.14)
# Output : work/out/arch/arm64/boot/Image.gz        (new kernel)
#          out/modules/ath9k_htc.ko                 (AR9271 driver)
#          out/nethunter-usb-wifi-magisk.zip        (module loader)
# =====================================================================
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK_DIR:-$KIT_DIR/work}"
SRC="$WORK/kernel"
OUT="$WORK/out"
TOOLS="$WORK/tools"
FW_DIR="$WORK/firmware"
JOBS="${JOBS:-$(nproc)}"

KERNEL_REPO="${KERNEL_REPO:-https://github.com/LineageOS/android_kernel_xiaomi_sm6250}"
KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-21}"
DEFCONFIG="${DEFCONFIG:-vendor/xiaomi/miatoll_defconfig}"
FRAGMENT="$KIT_DIR/config/nethunter.fragment"

CLANG_REPO="${CLANG_REPO:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"
CLANG_BRANCH="${CLANG_BRANCH:-android13-release}"
GCC64_REPO="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9"
GCC32_REPO="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9"

RTL8812AU_REPO="https://github.com/aircrack-ng/rtl8812au"
SKIP_RTL8812AU="${SKIP_RTL8812AU:-0}"

FW_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0
log "Checking host dependencies"
MISSING=""
for c in git curl python3 make gcc bc; do
  command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
[ -z "$MISSING" ] || die "missing tools:$MISSING  (Ubuntu: sudo apt install git curl python3 build-essential bc bison flex libssl-dev libelf-dev)"
mkdir -p "$WORK" "$TOOLS" "$KIT_DIR/out/modules"

# ---------------------------------------------------------------- 1
if [ ! -d "$SRC/.git" ]; then
  log "Cloning kernel source ($KERNEL_BRANCH)"
  git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$SRC"
else
  log "Kernel source already cloned — skipping"
fi
[ -f "$SRC/arch/arm64/configs/$DEFCONFIG" ] || die "defconfig not found: arch/arm64/configs/$DEFCONFIG"

# ---------------------------------------------------------------- 2
if [ ! -d "$TOOLS/clang/.git" ]; then
  log "Fetching AOSP clang ($CLANG_BRANCH)"
  git clone --depth 1 -b "$CLANG_BRANCH" "$CLANG_REPO" "$TOOLS/clang"
fi
# AOSP prebuilt layout: tools live in clang-r<rev>/bin, NOT clang/bin
CLANG_BIN="$(ls -d "$TOOLS/clang"/clang-r*/bin 2>/dev/null | head -1)"
[ -n "$CLANG_BIN" ] && [ -x "$CLANG_BIN/clang" ] || die "clang prebuilt not found under $TOOLS/clang (expected clang-r*/bin)"
log "Using clang toolchain at $CLANG_BIN"
if [ ! -d "$TOOLS/gcc64/bin" ]; then
  log "Fetching aarch64 GCC 4.9 prebuilt (binutils/linker)"
  git clone --depth 1 "$GCC64_REPO" "$TOOLS/gcc64"
fi
if [ ! -d "$TOOLS/gcc32/bin" ]; then
  log "Fetching arm GCC 4.9 prebuilt (compat binutils)"
  git clone --depth 1 "$GCC32_REPO" "$TOOLS/gcc32"
fi
export PATH="$CLANG_BIN:$TOOLS/gcc64/bin:$TOOLS/gcc32/bin:$PATH"
# sanity: everything the build needs must resolve now
for t in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip; do
  command -v "$t" >/dev/null 2>&1 || die "required tool missing from PATH: $t"
done

# ---------------------------------------------------------------- 3
# Realtek RTL8812AU/8821AU (aircrack-ng 88XXau) — placed in-tree
if [ "$SKIP_RTL8812AU" = "1" ]; then
  warn "SKIP_RTL8812AU=1 — not adding the RTL8812AU driver"
elif [ ! -d "$SRC/drivers/net/wireless/rtl8812au" ]; then
  log "Adding aircrack-ng/rtl8812au driver in-tree"
  git clone --depth 1 "$RTL8812AU_REPO" "$SRC/drivers/net/wireless/rtl8812au"
  sed -i 's/^CONFIG_88XXAU *= *m/CONFIG_88XXAU = y/'      "$SRC/drivers/net/wireless/rtl8812au/Makefile"
  sed -i 's/^CONFIG_PLATFORM_I386_PC *= *y/CONFIG_PLATFORM_I386_PC = n/' "$SRC/drivers/net/wireless/rtl8812au/Makefile"
  # GCC-only warning flags (e.g. -Wno-stringop-overread, -Wno-cast-function-type)
  # are fatal under clang because the tree builds with -Werror=unknown-warning-option.
  # They only suppress warnings, so dropping them all is safe.
  sed -i -E 's/-Wno-[a-zA-Z0-9=-]+//g' "$SRC/drivers/net/wireless/rtl8812au/Makefile"
  # The driver only defines CONFIG_IOCTL_CFG80211 inside platform blocks
  # (I386_PC/RPi/Android...), which we deliberately don't enable. Without it,
  # rtw_ap.c references sta_info members that sta_info.h guards behind the
  # ifdef -> compile error. Inject the defines unconditionally.
  grep -q 'NETHUNTER_RTW_FLAGS' "$SRC/drivers/net/wireless/rtl8812au/Makefile" || \
    sed -i '1a EXTRA_CFLAGS += -DCONFIG_IOCTL_CFG80211 -DRTW_USE_CFG80211_STA_EVENT -DCONFIG_LITTLE_ENDIAN # NETHUNTER_RTW_FLAGS' \
      "$SRC/drivers/net/wireless/rtl8812au/Makefile"
  grep -q 'rtl8812au' "$SRC/drivers/net/wireless/Kconfig" ||
    echo 'source "drivers/net/wireless/rtl8812au/Kconfig"' >> "$SRC/drivers/net/wireless/Kconfig"
  grep -q 'rtl8812au' "$SRC/drivers/net/wireless/Makefile" ||
    echo 'obj-$(CONFIG_88XXAU) += rtl8812au/'             >> "$SRC/drivers/net/wireless/Makefile"
fi

# ---------------------------------------------------------------- 4
# Adapter firmware, baked into the kernel via CONFIG_EXTRA_FIRMWARE
log "Downloading adapter firmware blobs"
fetch_fw() { # <repo path> <local name>
  local src="$1" dst="$FW_DIR/$2"
  mkdir -p "$(dirname "$dst")"
  [ -s "$dst" ] && return 0
  curl -fsSL "$FW_BASE/$src" -o "$dst" || die "firmware download failed: $src"
}
fetch_fw "htc_9271.fw"                     "htc_9271.fw"
fetch_fw "ath9k_htc/htc_9271-1.4.0.fw"     "ath9k_htc/htc_9271-1.4.0.fw"
fetch_fw "htc_7010.fw"                     "htc_7010.fw"
fetch_fw "ath9k_htc/htc_7010-1.4.0.fw"     "ath9k_htc/htc_7010-1.4.0.fw"
fetch_fw "rt2870.bin"                      "rt2870.bin"
fetch_fw "mediatek/mt7601u.bin"            "mt7601u.bin"
FW_LIST="htc_9271.fw ath9k_htc/htc_9271-1.4.0.fw htc_7010.fw ath9k_htc/htc_7010-1.4.0.fw rt2870.bin mt7601u.bin"

# ---------------------------------------------------------------- 5
log "Configuring: $DEFCONFIG + NetHunter fragment"
export ARCH=arm64 SUBARCH=arm64
make -C "$SRC" O="$OUT" "$DEFCONFIG" >/dev/null
sed -e "s|__FW_DIR__|$FW_DIR|g" -e "s|__FW_LIST__|$FW_LIST|g" "$FRAGMENT" >> "$OUT/.config"
make -C "$SRC" O="$OUT" olddefconfig >/dev/null
grep -q "CONFIG_ATH9K_HTC=m" "$OUT/.config" || die "CONFIG_ATH9K_HTC did not survive olddefconfig"
grep -q "CONFIG_RT2800USB=y" "$OUT/.config" || die "CONFIG_RT2800USB did not survive olddefconfig"
[ "$SKIP_RTL8812AU" = "1" ] || grep -q "CONFIG_88XXAU=y" "$OUT/.config" || warn "CONFIG_88XXAU missing — RTL8812AU will NOT be built (re-run with SKIP_RTL8812AU=1 to silence)"

# ---------------------------------------------------------------- 6
log "Toolchain versions"
echo "clang  : $(command -v clang)  —  $(clang --version 2>/dev/null | head -n 1)"
echo "ld.lld : $(command -v ld.lld)  —  $(ld.lld --version 2>/dev/null | head -n 1)"

log "Compiling kernel ($JOBS jobs) — this takes a while (full log in $OUT/build.log)"
BUILD_LOG="$OUT/build.log"
if ! make -C "$SRC" O="$OUT" -j"$JOBS" \
  CC=clang LLVM_IAS=1 \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip \
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump \
  CROSS_COMPILE=aarch64-linux-android- \
  CROSS_COMPILE_COMPAT=arm-linux-androideabi- \
  Image.gz modules > "$BUILD_LOG" 2>&1; then
  echo "==============================================================="
  echo "BUILD FAILED — showing error context from $BUILD_LOG"
  echo "==============================================================="
  grep -n -iE "error|undefined|cannot|no such|not found" "$BUILD_LOG" | head -n 40 || true
  echo "---- last 90 lines of build log ----"
  tail -n 90 "$BUILD_LOG"
  exit 1
fi
KERNEL_IMG="$OUT/arch/arm64/boot/Image.gz"
[ -s "$KERNEL_IMG" ] || die "build failed: Image.gz not found"

# --- optional: device-tree blobs (fallback for pack_boot.sh if the
#     stock boot image carries no separate dtb section) -----------------
if make -C "$SRC" O="$OUT" -j"$JOBS" \
     CC=clang LLVM_IAS=1 CLANG_TRIPLE=aarch64-linux-gnu- \
     LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip \
     OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump \
     CROSS_COMPILE=aarch64-linux-android- \
     CROSS_COMPILE_COMPAT=arm-linux-androideabi- dtbs 2>/dev/null; then
  mkdir -p "$KIT_DIR/out/dtbs"
  find "$OUT" -name '*.dtb' -exec cp {} "$KIT_DIR/out/dtbs/" \; 2>/dev/null || true
  log "Built $(ls "$KIT_DIR/out/dtbs" 2>/dev/null | wc -l) dtb files"
else
  warn "dtbs target unavailable — pack_boot.sh will reuse the stock dtb (fine: we changed no device-tree)"
fi

# ---------------------------------------------------------------- 7
log "Collecting modules"
find "$OUT" -name 'ath9k_htc.ko' -exec cp -v {} "$KIT_DIR/out/modules/ath9k_htc.ko" \;
[ -s "$KIT_DIR/out/modules/ath9k_htc.ko" ] || die "ath9k_htc.ko was not built"

# ---------------------------------------------------------------- 8
log "Packaging Magisk module zip (ath9k_htc.ko auto-loader)"
python3 - "$KIT_DIR/out/modules/ath9k_htc.ko" "$KIT_DIR/out/nethunter-usb-wifi-magisk.zip" <<'PYEOF'
import sys, zipfile, os

ko, out_zip = sys.argv[1], sys.argv[2]

INSTALLER = r'''#!/sbin/sh
umask 022
ui_print() { echo "$1"; }
require_new_magisk() {
  ui_print "*******************************"
  ui_print " Please install Magisk v20.4+! "
  ui_print "*******************************"
  exit 1
}
OUTFD=$2
ZIP=$3
mount /data 2>/dev/null
[ -f /data/adb/magisk/util_functions.sh ] || require_new_magisk
. /data/adb/magisk/util_functions.sh
[ $MAGISK_VER_CODE -lt 20400 ] && require_new_magisk
install_module
exit 0
'''

MODULE_PROP = '''id=nethunter-usb-wifi
name=NetHunter USB WiFi Driver (ath9k_htc)
version=v1.0
versionCode=1
author=curtana-nethunter-kit
description=Loads ath9k_htc.ko (Atheros AR9271 / TP-Link TL-WN722N V1) at boot for monitor mode & injection.
'''

SERVICE_SH = r'''#!/system/bin/sh
MODDIR=${0%/*}
# give the USB core a moment, then load the AR9271 driver
sleep 20
insmod "$MODDIR/system/lib/modules/ath9k_htc.ko" 2>/dev/null
exit 0
'''

with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('META-INF/com/google/android/update-binary', INSTALLER)
    z.writestr('META-INF/com/google/android/updater-script', '#MAGISK\n')
    z.writestr('module.prop', MODULE_PROP)
    z.writestr('service.sh', SERVICE_SH)
    z.write(ko, 'system/lib/modules/ath9k_htc.ko')
    for name in ('service.sh',):
        pass
print('wrote', out_zip)
PYEOF

# ---------------------------------------------------------------- 9
log "Build finished successfully"
echo "  Kernel image : $KERNEL_IMG"
echo "  AR9271 module: $KIT_DIR/out/modules/ath9k_htc.ko"
echo "  Magisk module: $KIT_DIR/out/nethunter-usb-wifi-magisk.zip"
echo
echo "Next step — create the flashable boot image:"
echo "  ./scripts/pack_boot.sh /path/to/your/boot.img"
