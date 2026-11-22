#!/bin/bash
# The UNO Q's half of the shared-system build. The UNO Q and the IQ-9075 run one LineageOS system build
# (lineage_lumina_arm64: system, system_ext and product, from device/lumina/lumina_arm64 in the lineage-iq9075
# repo), and each board builds only its own parts: vendor, vendor_dlkm, system_dlkm, boot.img and linux.img.
# merge_target_files puts the two together per board (lineage-iq9075's build-host/build-lumina.sh), and the
# merged target-files give the board's super.img, linux.img and A/B OTA.
#
# This adds lineage_imola_vendor, a product that inherits lineage_imola and switches its system-side images
# off. Its target-files-package goal then compiles none of the system side: the target-files rule only pulls
# in the system image's modules when it builds one. lineage_imola itself is unchanged and still builds a whole
# image on its own.
#
# Run after the other build-host scripts (annex.sh, ota-ab.sh, ...), from a copy of build-host/ in the VM.
# Idempotent. Revert with `git checkout AndroidProducts.mk` in device/arduino/imola, removing
# lineage_imola_vendor.mk, and deleting the "Shared-system build" block at the end of BoardConfig.mk.
set -euo pipefail
cd ~/lineage-24
D=device/arduino/imola

cat > $D/lineage_imola_vendor.mk <<'MK'
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Local (build-host/shared-system.sh): the UNO Q's half of the shared-system build. Everything lineage_imola
# makes except system, system_ext and product, which come from the shared lineage_lumina_arm64 build.

$(call inherit-product, device/arduino/imola/lineage_imola.mk)

PRODUCT_NAME := lineage_imola_vendor

PRODUCT_BUILD_SYSTEM_IMAGE := false
PRODUCT_BUILD_SYSTEM_OTHER_IMAGE := false
PRODUCT_BUILD_SYSTEM_EXT_IMAGE := false
PRODUCT_BUILD_PRODUCT_IMAGE := false
PRODUCT_BUILD_SUPER_PARTITION := false
TARGET_SKIP_OTA_PACKAGE := true
MK

# The target-files step asserts an image for every A/B partition, so a vendor-only build must not list the system
# side's. That filter goes in BoardConfig.mk: product inheritance is deferred, so device.mk's AB_OTA_PARTITIONS
# appends land after anything lineage_imola_vendor.mk could do (cuttlefish gates its list in BoardConfig too).
if ! grep -q 'build-host/shared-system.sh' $D/BoardConfig.mk; then
  cat >> $D/BoardConfig.mk <<'MK'

# Shared-system build (build-host/shared-system.sh): a vendor-only product (lineage_imola_vendor) builds no
# system-side images, and the target-files step asserts an image for every A/B partition. The shared system build
# brings these three, and merge_target_files unions the two lists, so the merged build still updates all of them.
# The vendor's ro.vendor.build.ab_ota_partitions then lists only its own partitions; update_engine reads it only
# for partial OTAs, so build full ones.
ifeq ($(PRODUCT_BUILD_SYSTEM_IMAGE),false)
AB_OTA_PARTITIONS := $(filter-out product system system_ext,$(AB_OTA_PARTITIONS))
endif
MK
  echo "patched: $D/BoardConfig.mk (vendor-only A/B list)"
fi

python3 - $D/AndroidProducts.mk <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
n = s
if 'lineage_imola_vendor.mk' not in n:
    n = n.replace('    $(LOCAL_DIR)/lineage_imola.mk \\\n',
                  '    $(LOCAL_DIR)/lineage_imola.mk \\\n    $(LOCAL_DIR)/lineage_imola_vendor.mk \\\n', 1)
if 'lineage_imola_vendor-cp2a-userdebug' not in n:
    n = n.replace('    lineage_imola-cp2a-eng \\\n',
                  '    lineage_imola-cp2a-eng \\\n'
                  '    lineage_imola_vendor-cp2a-user \\\n'
                  '    lineage_imola_vendor-cp2a-userdebug \\\n', 1)
for need in ('$(LOCAL_DIR)/lineage_imola_vendor.mk', 'lineage_imola_vendor-cp2a-userdebug'):
    if need not in n:
        sys.exit('AndroidProducts.mk: could not add ' + need)
if n != s:
    open(p, 'w').write(n)
    print('patched: %s (lineage_imola_vendor)' % p)
PY

grep -n 'imola_vendor' $D/AndroidProducts.mk
echo "SHARED SYSTEM OK"
