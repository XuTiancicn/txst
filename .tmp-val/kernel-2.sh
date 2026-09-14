sudo apt-get update -qq
# binutils-aarch64-linux-gnu: 让 kbuild 的 `which aarch64-linux-gnu-elfedit`
# 能解析到 /usr/bin/ ⇒ --prefix=/usr/bin/aarch64-linux-gnu- 正常
sudo apt-get install -y -qq --no-install-recommends \
  build-essential bc flex bison libssl-dev libelf-dev \
  cpio kmod zstd lz4 xz-utils device-tree-compiler \
  binutils-aarch64-linux-gnu \
  python3 python3-yaml git
df -h / | tail -1
