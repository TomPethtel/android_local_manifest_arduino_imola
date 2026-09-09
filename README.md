# android_local_manifest_arduino_imola

WIP

repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --depth=1

curl -o .repo/local_manifests/local_manifest.xml -L https://raw.githubusercontent.com/YAJATapps/android_local_manifest_arduino_imola/refs/heads/lineage-23.2/local_manifest.xml --create-dirs

repo sync

