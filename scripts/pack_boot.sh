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
[ -f "$STOCK_BOOT" ]          || die "not found: $STOCK_BOOT"
[ -f "$KERNEL_IMG" ]          || die "new kernel not found: $KERNEL_IMG — run scripts/build.sh first"
command -v python3 >/dev/null || die "python3 is required"

# ------------------------------------------------------------------ 1
if [ ! -d "$TOOLS/mkbootimg-tools" ]; then
  log "Fetching AOSP mkbootimg / unpack_bootimg tools"
  git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg "$TOOLS/mkbootimg-tools"
fi

# ------------------------------------------------------------------ 2
log "Unpacking your boot image: $STOCK_BOOT"
rm -rf "$UNPACK_DIR"; mkdir -p "$UNPACK_DIR"
python3 "$TOOLS/mkbootimg-tools/unpack_bootimg.py" \
  --boot_img "$STOCK_BOOT" --out "$UNPACK_DIR" --format mkbootimg \
  2>&1 | tee "$UNPACK_DIR/unpack.log"

# ------------------------------------------------------------------ 3
# Parse the arguments emitted by unpack_bootimg (a bare "--header_version ..."
# line, optionally prefixed with "mkbootimg"), swap in the new kernel and
# rebuild the image with mkbootimg.py — keeping the stock ramdisk/dtb/cmdline.
log "Repacking with the new kernel"
python3 - "$UNPACK_DIR" "$KERNEL_IMG" "$FINAL_IMG" "$TOOLS/mkbootimg-tools" <<'PYEOF'
import os, shlex, subprocess, sys

unpack_dir, new_kernel, out_img, tools = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(os.path.join(unpack_dir, "unpack.log")) as f:
    log = f.read()

args = None
for line in log.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        toks = shlex.split(line)
    except ValueError:
        continue
    if toks and toks[0] == "mkbootimg":
        toks = toks[1:]
    # the arguments line: starts with an option and contains --kernel
    if toks and toks[0].startswith("--") and "--kernel" in toks:
        args = toks
        break

if args is None:
    print(log)
    sys.exit("could not parse unpack_bootimg output — see log above")

def set_arg(a, name, value):
    if name in a:
        a[a.index(name) + 1] = value
    else:
        a += [name, value]

# swap in the freshly built kernel
set_arg(args, "--kernel", new_kernel)

# dtb: keep the one extracted from the stock image if present
dtb = os.path.join(unpack_dir, "dtb")
if "--dtb" not in args:
    if os.path.exists(dtb) and os.path.getsize(dtb) > 0:
        args += ["--dtb", dtb]
    else:
        dtbs_dir = os.path.normpath(os.path.join(unpack_dir, "..", "out", "dtbs"))
        if os.path.isdir(dtbs_dir):
            built = sorted(os.path.join(dtbs_dir, f) for f in os.listdir(dtbs_dir))
            if built:
                joined = os.path.join(unpack_dir, "dtb-built")
                with open(joined, "wb") as o:
                    for b in built:
                        o.write(open(b, "rb").read())
                args += ["--dtb", joined]

set_arg(args, "--output", out_img)

script = os.path.join(tools, "mkbootimg.py")
print("running: python3", script, " ".join(args))
subprocess.check_call([sys.executable, script] + args)
PYEOF

[ -s "$FINAL_IMG" ] || die "repack failed"

log "Done"
ls -lh "$FINAL_IMG"
sha256sum "$FINAL_IMG" || true
echo
echo "Flashable image : $FINAL_IMG"
echo "Flash it with SmartPack-Kernel-Manager (Flasher -> flash boot image),"
echo "or:  fastboot flash boot $FINAL_IMG"
