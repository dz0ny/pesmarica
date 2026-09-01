#!/bin/sh
# Runs after the target filesystem is assembled, before it is packed.
set -eu

TARGET_DIR="$1"

# tty1 belongs to flutter-pi; a getty there would fight it for the VT.
rm -f "${TARGET_DIR}/etc/systemd/system/getty.target.wants/getty@tty1.service"

# Enable our units without needing systemctl on the host.
mkdir -p "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/pesmarica.service \
	"${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/pesmarica.service"

# Network stack. The box is an access point and never a client: hostapd owns
# the radio, networkd owns the address and the DHCP pool, dnsmasq answers every
# name with our own address so a phone opens the songbook instead of complaining
# about no internet.
ln -sf /etc/systemd/system/hostapd.service \
	"${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/hostapd.service"
ln -sf /usr/lib/systemd/system/systemd-networkd.service \
	"${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sf /usr/lib/systemd/system/systemd-resolved.service \
	"${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
ln -sf /usr/lib/systemd/system/dnsmasq.service \
	"${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/dnsmasq.service"
ln -sf /run/systemd/resolve/resolv.conf "${TARGET_DIR}/etc/resolv.conf"

# Nothing dials out, so there is no clock to sync and nobody to sync with.
ln -sf /dev/null "${TARGET_DIR}/etc/systemd/system/systemd-timesyncd.service"

# The data partition mount must be pulled in even though nothing Requires it
# before pesmarica.service exists.
ln -sf /etc/systemd/system/var-lib-pesmarica.mount \
	"${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/var-lib-pesmarica.mount"
mkdir -p "${TARGET_DIR}/var/lib/pesmarica"

# Units that only cost boot time on an appliance with no removable storage,
# no swap and no fsck-able rootfs to wait for.
for unit in systemd-udev-settle.service systemd-random-seed.service; do
	ln -sf /dev/null "${TARGET_DIR}/etc/systemd/system/${unit}"
done

# Empty root password, console login only over the serial port.
sed -i 's|^root:[^:]*:|root::|' "${TARGET_DIR}/etc/shadow"
