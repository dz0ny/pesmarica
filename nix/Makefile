# Pesmarica appliance image, the Nix way.
#
#   make image   -> nix/out/sd-image/*.img.zst
#   make flash DISK=/dev/rdisk4
#
# Nix runs inside the colima VM: it is aarch64 Linux, so cache.nixos.org serves
# prebuilt binaries for all of userland. The Raspberry Pi kernel is NOT cached
# despite what raspberry-pi-nix claims, so expect it to compile here.
#
# The Flutter bundle is still produced on macOS (scripts/build-bundle.sh): the
# Dart AOT snapshotter only exists as an x86_64 binary.

HERE      := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
NIX_IMAGE ?= nixos/nix:latest
STORE_VOL ?= pesmarica-nix-store

# ~/.docker/config.json sets credsStore=osxkeychain, but that helper is not
# installed here and the CLI runs it even for public images. A scratch config
# dir plus an explicit DOCKER_HOST sidesteps it without touching your setup.
export DOCKER_CONFIG := $(HERE)/.docker
export DOCKER_HOST := unix://$(HOME)/.colima/default/docker.sock

# gcc segfaults inside the Nix build sandbox here: cc1 dies on a trivial
# `int main(){}` under the sandbox's seccomp filter, while the same compiler
# builds it fine outside. It is aarch64-under-virtualization that breaks the
# filter, not the toolchain -- both the kernel config step and flutter-pi's
# CMake probe failed identically before this.
#
# The isolation the sandbox provides is worth less here than usual: this whole
# thing already runs in a throwaway container whose only mounts are the store
# and this directory.
SANDBOX_OFF = --option sandbox false --option filter-syscalls false

NIX_RUN = docker run --rm \
	-v $(STORE_VOL):/nix \
	-v $(HERE):/work \
	-w /work \
	$(NIX_IMAGE) \
	nix --extra-experimental-features "nix-command flakes" \
	    $(SANDBOX_OFF) \
	    --extra-substituters "https://nix-community.cachix.org" \
	    --extra-trusted-public-keys "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="

.PHONY: image bundle store lock eval shell clean flash

$(HERE)/.docker/config.json:
	@mkdir -p $(dir $@) && echo '{}' > $@

image: bundle store
	$(NIX_RUN) build .#sdImage --print-build-logs --out-link /work/out/sd-image
	@ls -lh $(HERE)/out/sd-image/sd-image/ 2>/dev/null || ls -lh $(HERE)/out/sd-image/

# Stage the pieces the flake needs from outside its root.
bundle:
	$(HERE)/scripts/build-bundle.sh
	rm -rf $(HERE)/bundle $(HERE)/content
	cp -R "$$(cat $(HERE)/../build/flutter-pi/.bundle-path)" $(HERE)/bundle
	cp -R $(HERE)/../content $(HERE)/content

# An empty volume mounted at /nix would hide the image's own store, so seed it
# from the image the first time.
store: $(HERE)/.docker/config.json
	@docker volume inspect $(STORE_VOL) >/dev/null 2>&1 || { \
		echo "==> seeding the nix store volume"; \
		docker volume create $(STORE_VOL) >/dev/null; \
		docker run --rm -v $(STORE_VOL):/seed $(NIX_IMAGE) \
			sh -c 'cp -a /nix/. /seed/'; }

lock: store
	$(NIX_RUN) flake lock

eval: store
	$(NIX_RUN) eval .#sdImage.drvPath

shell: store
	docker run --rm -it -v $(STORE_VOL):/nix -v $(HERE):/work -w /work $(NIX_IMAGE) sh

clean:
	rm -rf $(HERE)/out $(HERE)/bundle $(HERE)/content

flash:
	@test -n "$(DISK)" || { echo "usage: make flash DISK=/dev/rdiskN"; exit 1; }
	diskutil unmountDisk $(DISK)
	zstd -dc $(HERE)/out/sd-image/sd-image/*.img.zst | sudo dd of=$(DISK) bs=4m status=progress
	sync
	diskutil eject $(DISK)
