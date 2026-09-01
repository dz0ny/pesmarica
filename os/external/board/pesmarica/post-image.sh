#!/bin/bash
# Assembles sdcard.img: FAT boot + ext4 rootfs + ext4 data.
set -e

BOARD_DIR="$(dirname "$0")"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"
GENIMAGE_CFG="${BINARIES_DIR}/genimage.cfg"

# Same trick buildroot's own raspberrypi/post-image.sh uses: the list of files
# that must land on the FAT partition is only known after the build.
FILES=()
for i in "${BINARIES_DIR}"/*.dtb "${BINARIES_DIR}"/rpi-firmware/*; do
	[ -e "$i" ] || continue
	FILES+=( "${i#${BINARIES_DIR}/}" )
done
FILES+=( "$(sed -n 's/^kernel=//p' "${BINARIES_DIR}/rpi-firmware/config.txt")" )

BOOT_FILES=$(printf '\\t\\t\\t"%s",\\n' "${FILES[@]}")
sed "s|#BOOT_FILES#|${BOOT_FILES}|" "${BOARD_DIR}/genimage.cfg.in" > "${GENIMAGE_CFG}"

trap 'rm -rf "${ROOTPATH_TMP}"' EXIT
ROOTPATH_TMP="$(mktemp -d)"
rm -rf "${GENIMAGE_TMP}"

genimage \
	--rootpath "${ROOTPATH_TMP}" \
	--tmppath "${GENIMAGE_TMP}" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "${GENIMAGE_CFG}"
