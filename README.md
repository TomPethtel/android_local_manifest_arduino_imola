# LineageOS 24 (Android 17) for Arduino Uno Q (Imola)

Local manifest to set up and sync repositories for building LineageOS 24 (Android 17) on the Arduino Uno Q (`imola`).

---

## 1. Initialize LineageOS 24 Source Tree

```bash
mkdir -p lineage-24 && cd lineage-24
repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs --depth=1
```

---

## 2. Add Local Manifest

```bash
curl -o .repo/local_manifests/local_manifest.xml -L https://raw.githubusercontent.com/TomPethtel/android_local_manifest_arduino_imola/refs/heads/lineage-24/local_manifest.xml --create-dirs
```

---

## 3. Sync Repositories

```bash
repo sync
```

This will pull:
- `device/arduino/imola` (Device tree & packaging tools)
- `kernel/arduino/imola` (Linux 6.18 Android Common Kernel)
- `vendor/arduino/imola` (Firmware blobs, Mesa 3D Turnip/Freedreno, U-Boot bootloader)
- `vendor/arduino/imola/qcombin` (Qualcomm Firehose EDL programmer & partition XMLs)
- `packages/apps/WiringUno` (Hardware GPIO & RGB LED control companion app)

---

## 4. Apply Patches

```bash
./device/arduino/imola/patches.sh
```


---

## Building on an Apple Silicon Mac

See [`build-host/README.md`](build-host/README.md) for the Lima/Rosetta VM recipe, the build scripts, and the experimental native arm64 host setup.
