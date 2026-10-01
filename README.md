# LineageOS 23.2 (Android 16) for Arduino Uno Q (Imola)

Local manifest to set up and sync repositories for building LineageOS 23.2 (Android 16) on the Arduino Uno Q (`imola`).

---

## 1. Initialize LineageOS 23.2 Source Tree

```bash
mkdir -p lineage-23.2 && cd lineage-23.2
repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --depth=1
```

---

## 2. Add Local Manifest

```bash
curl -o .repo/local_manifests/local_manifest.xml -L https://raw.githubusercontent.com/YAJATapps/android_local_manifest_arduino_imola/refs/heads/lineage-23.2/local_manifest.xml --create-dirs
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

