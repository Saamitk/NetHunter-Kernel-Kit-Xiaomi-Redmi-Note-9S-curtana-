#!/usr/bin/env bash
# =====================================================================
# pack_boot.sh — create a flashable boot.img for curtana
#
# Usage:  ./scripts/pack_boot.sh /path/to/stock/boot.img
#
# Takes the freshly built kernel (work/out/arch/arm64/boot/Image.gz)
# and re-uses the ramdisk, dtb, cmdline and header parameters of YOUR
# device's boot image, so the result stays compatible with your exact
# MIUI build (V14.0.3.0.SJWMIXM).
#
# If you pass your current Magisk-patched boot.img, root is preserved
# automatically. If you pass a stock boot.img, re-patch the resulting
# image in the Magisk app afterwards.
# =====================================================================
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK_DIR:-$KIT_DIR/work}"
OUT="$WORK/out"
TOOLS="$WORK/tools"
UNPACK_DIR="$WORK/boot-unpack"

KERNEL_IMG="${KERNEL_IMG:-$OUT/arch/arm64/boot/Image.gz}"
FINAL_IMG="$KIT_DIR/out/boot-nethunter-curtana.img"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 /path/to/boot.img   (stock or Magisk-patched)"
STOCK_BOOT="$1"
[ -f "$STOCK_BOOT" ]        || die "not found: $STOCK_BOOT"
[ -f "$KERNEL_IMG" ]        || die "new kernel not found: $KERNEL_IMG — run scripts/build.sh first"
command -v python3 >/dev/null || die "python3 is required"

# ------------------------------------------------------------------ 1
if [ ! -d "$TOOLS/mkbootimg-tools" ]; then
  log "Fetching AOSP mkbootimg / unpack_bootimg tools"
  git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg "$TOOLS/mkbootimg-tools"
fi
export PYTHONPATH="$TOOLS/mkbootimg-tools${PYTHONPATH:+:$PYTHONPATH}"

# ------------------------------------------------------------------ 2
log "Unpacking your boot image: $STOCK_BOOT"
rm -rf "$UNPACK_DIR"; mkdir -p "$UNPACK_DIR"
python3 "$TOOLS/mkbootimg-tools/unpack_bootimg.py" \
  --boot_img "$STOCK_BOOT" --out "$UNPACK_DIR" --format mkbootimg \
  | tee "$UNPACK_DIR/unpack.log"

# ------------------------------------------------------------------ 3
# Parse the mkbootimg command emitted by unpack_bootimg and rebuild the
# image with our new kernel. Everything else (ramdisk, dtb, cmdline,
# header version, offsets, os patch level) is kept from the original.
log "Repacking with the new kernel"
python3 - "$UNPACK_DIR" "$KERNEL_IMG" "$FINAL_IMG" <<'PYEOF'
import shlex, subprocess, sys, os

unpack_dir, new_kernel, out_img = sys.argv[1], sys.argv[2], sys.argv[3]
tools = os.path.join(os.path.dirname(unpack_dir), "tools", "mkbootimg-tools")

with open(os.path.join(unpack_dir, "unpack.log")) as f:
    log = f.read()

cmd = None
for line in log.splitlines():
    line = line.strip()
    if line.startswith("mkbootimg"):
        cmd = line
        break
if cmd is None:
    sys.exit("could not find the mkbootimg command in unpack output")

args = shlex.split(cmd)

def set_arg(args, name, value):
    if name in args:
        args[args.index(name) + 1] = value
    else:
        args += [name, value]

# swap in the freshly built kernel
set_arg(args, "--kernel", new_kernel)

# keep the stock dtb if it was extracted; else keep ours if we built dtbs
dtb = os.path.join(unpack_dir, "dtb")
if not (os.path.exists(dtb) and os.path.getsize(dtb) > 0):
    dtbs_dir = os.path.normpath(os.path.join(unpack_dir, "..", "out", "dtbs"))
    built = sorted(
        os.path.join(dtbs_dir, f) for f in os.listdir(dtbs_dir)
    ) if os.path.isdir(dtbs_dir) else []
    if built:
        joined = os.path.join(unpack_dir, "dtb-built")
        with open(joined, "wb") as o:
            for b in built:
                o.write(open(b, "rb").read())
        dtb = joined
    else:
        dtb = None

if dtb:
    if "--dtb" in args:
        set_arg(args, "--dtb", dtb)
    else:
        args += ["--dtb", dtb]

set_arg(args, "--output", out_img)

script = os.path.join(tools, "mkbootimg.py")
print("running:", " ".join([script] + args[1:]))
subprocess.check_call([sys.executable, script] + args[1:])
PYEOF

[ -s "$FINAL_IMG" ] || die "repack failed"

log "Done"
ls -lh "$FINAL_IMG"
echo
echo "Flashable image : $FINAL_IMG"
echo "Flash it with SmartPack-Kernel-Manager (Flasher -> flash boot image),"
echo "or:  fastboot flash boot $FINAL_IMG"
