set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# amd64 multiarch so Rosetta can load AOSP's x86_64 host prebuilts (they link against glibc)
sudo dpkg --add-architecture amd64
sudo tee /etc/apt/sources.list.d/amd64.sources >/dev/null <<'SRC'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main restricted universe multiverse
Architectures: amd64
SRC
# restrict the default (ports) source to arm64 so apt doesn't look for amd64 there
sudo sed -i '/^Architectures:/d' /etc/apt/sources.list.d/ubuntu.sources
sudo sed -i '/^Components:/a Architectures: arm64' /etc/apt/sources.list.d/ubuntu.sources
sudo apt-get update -qq
sudo apt-get install -y -qq \
  bc bison build-essential ccache curl flex git git-lfs gnupg gperf imagemagick \
  libelf-dev liblz4-tool libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush \
  rsync schedtool squashfs-tools xsltproc zip unzip zlib1g-dev libncurses-dev \
  python3 python-is-python3 python3-pip repo openjdk-21-jdk-headless \
  libc6:amd64 libstdc++6:amd64 zlib1g:amd64 libncurses6:amd64 libtinfo6:amd64 libgcc-s1:amd64 \
  libssl3t64:amd64 libxml2:amd64 libz3-4:amd64 libgomp1:amd64 liblzma5:amd64 libbz2-1.0:amd64 libffi8:amd64 libsqlite3-0:amd64
git lfs install --skip-repo
echo DEPS_DONE
