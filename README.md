# NetHunter Kernel Kit — Xiaomi Redmi Note 9S (curtana)

**Target:** stock MIUI 14 / Android 12 (`V14.0.3.0.SJWMIXM`), rooted, no custom recovery.
**Goal:** a kernel with external USB Wi-Fi adapter support + monitor mode + packet injection,
delivered as a plain `boot.img` you can flash from **SmartPack-Kernel-Manager** (or fastboot).

> **Works for the whole "miatoll" family:** Redmi Note 9S (curtana), Note 9 Pro India
> (joyeuse), Note 9 Pro Max (excalibur), Note 9 Pro International (gram).

---

## What you get

| Adapter / chipset | Driver in this kernel | Monitor mode | Injection |
|---|---|---|---|
| **TP-Link TL-WN722N V1** (Atheros AR9271) | `ath9k_htc` (module, auto-loaded via Magisk zip) | ✅ | ✅ |
| **Ralink RT3070 / RT2870 / RT3572 / RT5370** | `rt2800usb` (built-in) | ✅ | ✅ |
| **MediaTek MT7601U** (cheap "USB Wi-Fi" dongles) | `mt7601u` (built-in) | ✅ | ✅ |
| **Realtek RTL8812AU / 8821AU** (dual-band) | `88XXau` (aircrack-ng driver, built-in) | ✅ | ✅ |
| Realtek RTL8188EU/8192EU (**TL-WN722N V2/V3**) | `rtl8xxxu` (built-in) | ⚠️ limited | ⚠️ limited |
| USB Ethernet (RTL8152, AX88179, RNDIS, CDC-NCM…) | built-in | — | — |

Plus the usual NetHunter prerequisites: `CONFIG_USB_CONFIGFS_F_HID` (USB HID / Rubber-Ducky
attacks — already on in stock), `mac80211` with minstrel rate control, wext, and relaxed module
signature enforcement.

**All adapter firmware is baked directly into the kernel image** (via `CONFIG_EXTRA_FIRMWARE`),
so you never need to push `htc_9271.fw` / `rt2870.bin` to `/vendor/firmware` — Android's vendor
partition isn't Magisk-overlayable anyway.

### Why ath9k_htc is a module (and everything else is built-in)

Building `ath9k_htc` into the kernel fails at link time with
`duplicate symbol: htc_stop` — the stock Qualcomm Wi-Fi stack (`qca-wifi-host-cmn`, built-in for
`CONFIG_QCA_CLD_WLAN=y`) exports the same symbols. So the AR9271 driver ships as `ath9k_htc.ko`,
auto-loaded at boot by the generated Magisk module zip. Module signing is relaxed
(`CONFIG_MODULE_SIG_FORCE=n`) so it can load.

### Base source

Xiaomi never published curtana OSS sources, so the base is
[LineageOS/android_kernel_xiaomi_sm6250](https://github.com/LineageOS/android_kernel_xiaomi_sm6250)
(branch `lineage-21`, Linux 4.14, defconfig `vendor/xiaomi/miatoll_defconfig`) — the same tree
used by LineageOS for this exact device, so all Xiaomi hardware drivers are present. Your MIUI
ramdisk, dtb and cmdline are reused verbatim when packing the boot image.

---

## Repo layout

```
config/nethunter.fragment        kernel .config additions (the whole "feature list")
scripts/build.sh                 clones sources+toolchain, builds kernel + Magisk zip
scripts/pack_boot.sh             merges new kernel into YOUR boot.img -> boot.img
extras/github-actions-workflow.yml  build on GitHub's free runners instead of your PC
```

---

## Before you start

- **Unlocked bootloader + working Magisk root** (you have both).
- **A copy of your current boot image.** Get it one of two ways:
  1. **Recommended:** dump your *current Magisk-patched* boot — then root survives the flash:
     ```sh
     # in Termux/adb shell with root
     su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot.img'
     ```
  2. Or extract `boot.img` from the full MIUI fastboot ROM `V14.0.3.0.SJWMIXM`
     (`images/boot.img` inside the .tgz). In that case, after flashing, open Magisk app →
     Install → "Install to inactive slot"/"Patch a file" on the new image and reflash,
     to restore root.
- A Linux machine (Ubuntu 22.04+, WSL2 works fine) with ~15 GB free disk, **or** a GitHub
  account for the Actions route.
- Expect **20–40 min** build time on 8 cores (60–90 min on 4 cores).

---

## Build (local)

```sh
sudo apt install git curl python3 build-essential bc bison flex libssl-dev libelf-dev
cd curtana-nethunter-kernel
bash scripts/build.sh                        # ~30 min, mostly downloads + compile
bash scripts/pack_boot.sh ~/my-device/boot.img
```

Output:

```
out/boot-nethunter-curtana.img        <- flash this
out/nethunter-usb-wifi-magisk.zip     <- Magisk module (loads ath9k_htc.ko)
out/modules/ath9k_htc.ko
```

## Build (no PC — GitHub Actions)

1. Push this folder to a **private** GitHub repo.
2. Put your `boot.img` at the repo root.
3. Copy `extras/github-actions-workflow.yml` to `.github/workflows/build.yml`.
4. Actions tab → *Build curtana NetHunter kernel* → **Run workflow**.
5. Download the `curtana-nethunter` artifact (~40 min later).

---

## Flash

1. Boot Android normally.
2. Install the Magisk module: Magisk app → Modules → *Install from storage* →
   `out/nethunter-usb-wifi-magisk.zip` → reboot.
3. Flash the kernel: **SmartPack-Kernel-Manager → Flasher → Flash boot image** →
   select `boot-nethunter-curtana.img` → reboot.
   (or `fastboot flash boot boot-nethunter-curtana.img`)
4. If the device bootloops on the MIUI logo, you hit AVB verification — flash a patched vbmeta:
   ```
   fastboot flash vbmeta --disable-verity --disable-verification vbmeta.img
   ```
   (vbmeta.img = the one from your ROM package; with Magisk you may already have this state).

**Rollback:** just reflash your original `boot.img` the same way. The stock boot image is your
undo button — keep it safe.

---

## Using monitor mode

Plug the adapter via a **USB-OTG adapter**. It appears as `wlan1` (or `wlan2`).
From a root shell (Termux + `tsu`, or the Kali NetHunter rootless app):

```sh
ip link set wlan1 down
iw dev wlan1 set type monitor
ip link set wlan1 up
iw dev wlan1 set channel 6
# verify:
iw dev            # should say "type monitor"
airodump-ng wlan1 # if you have the aircrack suite installed
```

Useful installs: NetHunter Store app → *Kali NetHunter* (rootless) gives you the chroot with
aircrack-ng/wifite/reaver pre-packaged; or `pkg install aircrack-ng` in Termux.

### Hardware notes

- **TL-WN722N V1 check:** only hardware version **V1** has the AR9271 chip. V2/V3 are Realtek
  RTL8188EUS — they will *not* get monitor mode from any kernel; check the label on the back.
- **AR9271 pulls up to ~500 mA.** If it randomly disconnects under load, use a **powered USB
  hub** between phone and adapter (a known issue on all Android devices).
- RTL8812AU is the best all-rounder here: dual-band, injection, stable on 4.14.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| No `wlan1` when adapter plugged in | `su -c dmesg \| grep -iE 'usb\|ath9k\|rt2\|wlan'` — check for firmware or power errors |
| `insmod: ... required key not available` | Module signing still forced: rebuild happened without the fragment; check `zcat /proc/config.gz \| grep MODULE_SIG` |
| Adapter works, injection doesn't | Use `wlan1` not `wlan0`; confirm `iw phy` shows "valid interface combinations" with monitor |
| Internal Wi-Fi/BT broke after flash | Should not happen (stock `QCA_CLD_WLAN=y` untouched); if it does, rollback and report dmesg |
| Build fails in rtl8812au | `SKIP_RTL8812AU=1 bash scripts/build.sh` — everything else still builds |

## Legal / ethical

Monitor mode and packet injection are for auditing **your own** networks and devices, CTFs, and
authorized pentests. Unauthorized capture/injection is illegal in most jurisdictions.

## Credits & references

- Kernel source: [LineageOS/android_kernel_xiaomi_sm6250](https://github.com/LineageOS/android_kernel_xiaomi_sm6250)
- 88XXau driver: [aircrack-ng/rtl8812au](https://github.com/aircrack-ng/rtl8812au)
- Similar working build for Redmi Note 10 Pro: [RiasJ1Dar/sweet-nethunter-kernel](https://github.com/RiasJ1Dar/sweet-nethunter-kernel)
- Automated miatoll NetHunter+KSU build (LineageOS-ROMs only): [r3n3o/KernelSU-Next_Actions-builder_Miatoll](https://github.com/r3n3o/KernelSU-Next_Actions-builder_Miatoll)
- boot.img tooling: AOSP `system/tools/mkbootimg`
