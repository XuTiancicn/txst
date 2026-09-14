chmod +x custom/scripts/prepare-image.sh
WORK="$PWD/work-src-${EDITION}" EDITION="${EDITION}" DEBS="$PWD/out-adapt" \
  ROOTFS_SIZE_GB="${ROOTFS_SIZE_GB}" \
  ./custom/scripts/prepare-image.sh
