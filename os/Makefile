# Pesmarica appliance image.
#
#   make image     -> os/out/sdcard.img, ready for dd
#   make flash DISK=/dev/rdisk4
#
# The Flutter bundle is cross-compiled on macOS (that is where the Dart AOT
# snapshotter runs); everything else happens inside a Linux container, because
# buildroot cannot build on macOS.

BUILDROOT_VERSION ?= 2026.05.2
DEFCONFIG         ?= pesmarica_zero2w_defconfig
IMAGE             ?= pesmarica-builder:$(BUILDROOT_VERSION)
# The VM's core count, not the Mac's -- colima gets a subset.
JOBS              ?= $(shell docker run --rm $(IMAGE) nproc 2>/dev/null || sysctl -n hw.ncpu)

HERE     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
OVERLAY  := $(HERE)/external/board/pesmarica/rootfs-overlay

# Named volumes, not bind mounts: macOS APFS is case-insensitive by default and
# buildroot's output tree has files that collide there.
DOCKER_RUN = docker run --rm \
	-v pesmarica-br-output:/home/br/output \
	-v pesmarica-br-dl:/home/br/dl \
	-v $(HERE)/external:/home/br/external:ro \
	-e BR2_DL_DIR=/home/br/dl \
	$(IMAGE)

# O and BR2_EXTERNAL must be make arguments, not environment: buildroot ignores
# them from the environment and would build in-tree, inside the container's
# throwaway layer instead of the output volume.
BR_MAKE = make O=/home/br/output BR2_EXTERNAL=/home/br/external

# menuconfig and a shell need a terminal; the batch targets must not have one.
DOCKER_RUN_TTY = $(subst docker run --rm,docker run --rm -it,$(DOCKER_RUN))

.PHONY: image bundle builder config menuconfig shell clean distclean flash

image: bundle config
	$(DOCKER_RUN) $(BR_MAKE) -j$(JOBS)
	mkdir -p $(HERE)/out
	docker run --rm -v pesmarica-br-output:/o -v $(HERE)/out:/out \
		$(IMAGE) cp /o/images/sdcard.img /out/sdcard.img
	@ls -lh $(HERE)/out/sdcard.img

# Stage the Flutter bundle and the seed songbook into the rootfs overlay.
bundle:
	$(HERE)/scripts/build-bundle.sh
	rm -rf $(OVERLAY)/opt/pesmarica/bundle $(OVERLAY)/usr/share/pesmarica/content
	mkdir -p $(OVERLAY)/opt/pesmarica $(OVERLAY)/usr/share/pesmarica
	cp -R "$$(cat $(HERE)/../build/flutter-pi/.bundle-path)" $(OVERLAY)/opt/pesmarica/bundle
	rm -f $(OVERLAY)/opt/pesmarica/bundle/flutter-pi $(OVERLAY)/opt/pesmarica/bundle/.last_build_id
	cp -R $(HERE)/../content $(OVERLAY)/usr/share/pesmarica/content

builder:
	docker build --build-arg BUILDROOT_VERSION=$(BUILDROOT_VERSION) -t $(IMAGE) $(HERE)

config: builder
	$(DOCKER_RUN) $(BR_MAKE) $(DEFCONFIG)

menuconfig:
	$(DOCKER_RUN_TTY) $(BR_MAKE) menuconfig

# Drop into the build container to inspect output/, run `make flutterpi-rebuild`, etc.
shell:
	$(DOCKER_RUN_TTY) bash

clean:
	$(DOCKER_RUN) $(BR_MAKE) clean

# Nukes the output volume but keeps the download cache.
distclean:
	docker volume rm -f pesmarica-br-output
	rm -rf $(HERE)/out

flash:
	@test -n "$(DISK)" || { echo "usage: make flash DISK=/dev/rdiskN  (check with diskutil list)"; exit 1; }
	diskutil unmountDisk $(DISK)
	sudo dd if=$(HERE)/out/sdcard.img of=$(DISK) bs=4m status=progress
	sync
	diskutil eject $(DISK)
