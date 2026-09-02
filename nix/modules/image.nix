# The card image: two FAT32 partitions and nothing else.
#
#   1  FIRMWARE   the Pi firmware, config.txt, and nixos/default/ with the
#                 kernel, the initrd, cmdline.txt, the device trees and
#                 rootfs.img -- the whole system as one squashfs. Also where
#                 wifi.conf and display.conf go.
#   2  PESMARICA  the songbook, grown to the rest of the card on the box.
#
# There is no root partition. The initrd mounts FIRMWARE, loop-mounts
# rootfs.img as /nix/store, and root itself is a tmpfs -- the shape of the
# NixOS netboot image, with the squashfs on the card instead of inside the
# initrd, because the closure does not fit in a Zero 2 W's RAM. Updating the
# system is replacing the files in nixos/default/ from any laptop; the
# firmware's os_prefix is what would later let a second folder be a second
# slot.
#
# Both partitions are populated with mtools, so this runs unprivileged: no
# loop devices, no mounting, and the same recipe for the songbook as before.
{ config, lib, pkgs, ... }:

let
  cfg = config.pesmarica.image;
  toplevel = config.system.build.toplevel;

  # zstd: the Zero 2 W decompresses it at a useful speed, which xz would not
  # manage, and the level only costs build time on a CI runner.
  rootfs = pkgs.callPackage (pkgs.path + "/nixos/lib/make-squashfs.nix") {
    storeContents = [ toplevel ];
    fileName = "rootfs";
    comp = "zstd -Xcompression-level 15";
  };

  songbookMiB = 512;
  songbookClusterSectors = 8; # 4 KiB clusters: a sane FAT once this fills a card.
in
{
  options.pesmarica.image = {
    compress = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Compress the finished image with zstd.";
    };
    content = lib.mkOption {
      type = lib.types.path;
      description = "The songbook the PESMARICA partition ships with.";
    };
    hostapdConf = lib.mkOption {
      type = lib.types.path;
      description = "The access point config the PESMARICA partition ships with.";
    };
  };

  config.system.build.sdImage = pkgs.callPackage (
    { stdenv, dosfstools, mtools, libfaketime, util-linux, zstd }:
    stdenv.mkDerivation {
      name = "pesmarica-rpi02-image";
      nativeBuildInputs = [ dosfstools mtools libfaketime util-linux ]
        ++ lib.optional cfg.compress zstd;

      buildCommand = ''
        mkdir -p $out/nix-support $out/sd-image
        img=$out/sd-image/pesmarica-rpi02.img
        echo "${pkgs.stdenv.buildPlatform.system}" > $out/nix-support/system
        echo "file sd-image $img${lib.optionalString cfg.compress ".zst"}" \
          >> $out/nix-support/hydra-build-products

        # Populates a FAT from a directory, in a fixed order for determinism.
        fill() { # fill <partition image> <directory>
          local part=$(realpath "$1")
          (
            cd "$2"
            for d in $(find . -mindepth 1 -type d | sort); do
              faketime "2000-01-01 00:00:00" mmd -i "$part" "::/$d"
            done
            for f in $(find . -type f | sort); do
              mcopy -pvm -i "$part" "$f" "::/$f"
            done
          )
          fsck.vfat -vn "$part"
        }

        # -- 1: the system --------------------------------------------------

        mkdir firmware
        ${config.boot.loader.raspberry-pi.firmwarePopulateCmd} -c ${toplevel} -f ./firmware
        cp ${rootfs} firmware/nixos/default/rootfs.img
        chmod -R u+w firmware
        find firmware -exec touch --date=2000-01-01 {} +

        # Twice what it holds, so a second slot fits beside it one day, and a
        # floor that keeps mkfs on FAT32.
        fwBytes=$(du -sb --apparent-size firmware | cut -f1)
        fwMiB=$(( fwBytes * 2 / 1048576 + 256 ))
        [ "$fwMiB" -ge 1024 ] || fwMiB=1024

        # -- the table ------------------------------------------------------

        # 8 MiB in front, as the Pi images have. The songbook's start is a
        # whole MiB, so the box's own alignment check has nothing to move.
        gap=8
        truncate -s $(( gap + fwMiB + ${toString songbookMiB} ))M $img
        # type=b is W95 FAT32, which the Pi firmware wants to see first;
        # type=c is the LBA flavour a laptop expects.
        sfdisk --no-reread --no-tell-kernel $img <<EOF
          label: dos
          label-id: 0x2175794e
          start=''${gap}M, size=''${fwMiB}M, type=b, bootable
          start=$(( gap + fwMiB ))M, type=c
        EOF

        eval $(partx $img -o START,SECTORS --nr 1 --pairs)
        truncate -s $(( SECTORS * 512 )) firmware_part.img
        mkfs.vfat --invariant -i 2175794e -F 32 -n FIRMWARE firmware_part.img
        fill firmware_part.img firmware
        dd conv=notrunc if=firmware_part.img of=$img seek=$START count=$SECTORS

        # -- 2: the songbook ------------------------------------------------

        eval $(partx $img -o START,SECTORS --nr 2 --pairs)
        # A small FAT32 is one mkfs warns about and some systems read as
        # FAT16. Better a build that stops than a card that holds seven
        # megabytes of songbook.
        [ "$SECTORS" -ge ${toString ((songbookMiB - 16) * 2048)} ] || {
          echo "pesmarica: songbook partition came out $((SECTORS / 2048)) MiB, expected ${toString songbookMiB}" >&2
          exit 1
        }
        truncate -s $(( SECTORS * 512 )) songbook_part.img
        mkfs.vfat --invariant -i 50534d43 -F 32 -s ${toString songbookClusterSectors} \
          -n PESMARICA songbook_part.img

        mkdir songbook
        cp -r ${cfg.content}/. songbook/
        # The access point config ships here too, so the name and passphrase
        # of the network the box hands out can be edited before it is ever
        # powered on. systemd-tmpfiles puts it back if it goes missing.
        cp ${cfg.hostapdConf} songbook/hostapd.conf
        chmod -R u+w songbook
        find songbook -exec touch --date=2000-01-01 {} +
        fill songbook_part.img songbook
        dd conv=notrunc if=songbook_part.img of=$img seek=$START count=$SECTORS

        ${lib.optionalString cfg.compress ''
          zstd -T$NIX_BUILD_CORES --rm $img
        ''}
      '';
    }
  ) { };
}
