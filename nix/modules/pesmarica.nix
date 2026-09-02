{ config, pkgs, lib, ... }:

let
  # Staged by the Makefile from build/flutter-pi/<cpu>/ -- the AOT snapshot, the
  # Flutter engine and the assets. Built on macOS because the Dart snapshotter
  # only ships as an x86_64 binary.
  bundle = pkgs.runCommand "pesmarica-bundle" { } ''
    mkdir -p $out
    cp -r ${../bundle}/. $out/
    # flutterpi_tool ships a prebuilt embedder; we use our own, linked against
    # this system's libraries.
    rm -f $out/flutter-pi $out/.last_build_id
  '';

  flutter-pi = pkgs.callPackage ../pkgs/flutter-pi.nix { };

  # Staged next to the bundle: a flake cannot reference paths outside its root.
  content = ../content;

  apAddress = "192.168.4.1";

  # The image defines the system, so the unit runs the bundle from the store
  # until something is deployed. tool/deploy_pi.sh and the web interface fill
  # one of two slots beside the songbook and flip a pointer at it; empty the
  # directory to go back to the image's own bundle.
  slots = "/var/lib/pesmarica/bundles";

  # How many starts a freshly deployed bundle gets to reach its first frame
  # before this reverts to the one that was running before. Keep in step with
  # BundleSlots.trialAttempts in lib/src/update/bundle_slots.dart.
  trialAttempts = 3;

  # flutter-pi takes the rotation as a startup flag, so it is read here rather
  # than by the app: the web interface writes it into settings.json and restarts
  # the unit. A panel mounted sideways is the normal case for signage.
  #
  # This script is also the half of the A/B updater that has to survive a bundle
  # too broken to start, which is why the slot bookkeeping is here in shell and
  # not in the app: it still runs when nothing else does. The on-disk format it
  # reads is documented once, in lib/src/update/bundle_slots.dart.
  launch = pkgs.writeShellScript "pesmarica-launch" ''
    settings=/var/lib/pesmarica/settings.json
    rotation=0
    if [ -r "$settings" ]; then
      rotation=$(${pkgs.jq}/bin/jq -r '.rotation // 0' "$settings" 2>/dev/null || echo 0)
    fi
    # A rotation on the boot partition wins: it is the one you can set on a
    # card, for a screen that has never been readable enough to reach the web
    # interface on. Delete the line to hand the setting back to the web UI.
    if [ -r ${rotationFile} ]; then
      read -r rotation < ${rotationFile} || rotation=0
    fi
    case "$rotation" in
      0|90|180|270) ;;
      # Anything else would put the picture off the panel, and the box would
      # look dead with no way in but ssh.
      *) echo "pesmarica: ignoring rotation $rotation" >&2; rotation=0 ;;
    esac

    # A bundle is the three files flutter-pi will not start without, plus the
    # marker a deploy writes last. Half an upload has no marker.
    complete() {
      [ -f "$1/.complete" ] || return 1
      for f in app.so icudtl.dat libflutter_engine.so; do
        [ -f "$1/$f" ] || return 1
      done
      return 0
    }

    # Renamed into place, like every other write in this project: a pointer
    # truncated by a power cut would send the next boot to a slot nobody chose.
    point_at() {
      printf '%s\n' "$1" > "${slots}/active.tmp" 2>/dev/null &&
        ${pkgs.coreutils}/bin/mv "${slots}/active.tmp" "${slots}/active" 2>/dev/null
    }

    forget_trial() {
      ${pkgs.coreutils}/bin/rm -f "${slots}/trial"
    }

    # Nothing here goes through the ambient PATH. This script is what runs when
    # the deployed app cannot, so it may not depend on anything but the store.
    active=a
    if [ -r "${slots}/active" ]; then
      read -r active < "${slots}/active" || true
    fi
    active=''${active//[[:space:]]/}
    case "$active" in a|b) ;; *) active=a ;; esac
    if [ "$active" = a ]; then other=b; else other=a; fi

    # The trial file exists only between a deploy and the first frame the new
    # bundle draws, so in steady state a boot writes nothing to the card here.
    if [ -f "${slots}/trial" ]; then
      n=""
      read -r n < "${slots}/trial" || true
      n=''${n//[[:space:]]/}
      case "$n" in ""|*[!0-9]*) n=0 ;; esac
      if [ "$n" -ge ${toString trialAttempts} ]; then
        echo "pesmarica: slot $active did not come up in $n starts, reverting to $other" >&2
        forget_trial
        point_at "$other"
        tmp=$active; active=$other; other=$tmp
      else
        printf '%s\n' "$((n + 1))" > "${slots}/trial"
      fi
    fi

    if ! complete "${slots}/$active" && complete "${slots}/$other"; then
      echo "pesmarica: slot $active is not a bundle, running $other" >&2
      forget_trial
      point_at "$other"
      tmp=$active; active=$other; other=$tmp
    fi

    if complete "${slots}/$active"; then
      echo "pesmarica: running slot $active" >&2
      exec ${lib.getExe flutter-pi} --release --rotation "$rotation" "${slots}/$active"
    fi

    # Nothing deployed, or both slots unusable. The image's own bundle is in the
    # read-only store, so this is the one copy a bad update cannot reach.
    forget_trial
    echo "pesmarica: no deployed bundle, running the image's own" >&2
    exec ${lib.getExe flutter-pi} --release --rotation "$rotation" ${bundle}
  '';

  # The fallback access point. The web interface rewrites the copy on the data
  # directory (/var/lib/pesmarica/hostapd.conf); this one is what gets restored
  # if that copy is missing or unusable, so a bad SSID typed into a phone can
  # never lock you out of the box.
  defaultHostapdConf = pkgs.writeText "hostapd.conf" ''
    interface=wlan0
    driver=nl80211
    country_code=SI
    ieee80211d=1

    ssid=Pesmarica
    hw_mode=g
    channel=6
    # 802.11n: the Zero 2 W radio is 2.4 GHz only. Enough for a text editor.
    ieee80211n=1
    wmm_enabled=1

    auth_algs=1
    wpa=2
    wpa_key_mgmt=WPA-PSK
    rsn_pairwise=CCMP
    wpa_passphrase=pesmarica

    # Clients have no reason to talk to each other, only to the box.
    ap_isolate=1
    macaddr_acl=0
    ignore_broadcast_ssid=0
  '';

  # Where the box keeps what it worked out at boot. tmpfs: a wifi passphrase,
  # hashed or not, has no business being written to a card.
  runtimeDir = "/run/pesmarica";
  clientMarker = "${runtimeDir}/client";
  supplicantConf = "${runtimeDir}/wpa_supplicant.conf";
  rotationFile = "${runtimeDir}/rotation";

  # networkd applies the first .network that matches, in lexical order across
  # /run and /etc together, so a 10- file dropped here wins over the access
  # point's 20-wlan below without either knowing about the other.
  clientNetwork = "/run/systemd/network/10-wlan-client.network";

  # How long a configured network gets to hand out a lease before the box gives
  # up and becomes an access point instead. It is the window in which a screen
  # in a hall with no wifi is unreachable, so it is short.
  joinTimeout = 45;

  # How the box is set up before it has ever been switched on: files on the
  # boot partition -- the FAT one, which is the only partition a freshly
  # flashed card has, and the one both Windows and macOS mount by themselves.
  # One file per thing it configures, next to the firmware's own config.txt.
  #
  #   wifi.conf      ssid=Zupnija        the network to join instead of being one
  #                  psk=nekogeslo       8..63 characters, or absent for an open network
  #                  country=SI          the regulatory domain to scan in
  #
  #   display.conf   rotation=90         0, 90, 180 or 270
  #
  # Rotation is here rather than in the firmware's own config.txt because the
  # picture goes through vc4-kms-v3d, and the KMS driver ignores the
  # display_rotate that the old firmware path honoured. flutter-pi takes it as
  # a startup flag instead, so the value is handed to the launcher above.
  #
  # Anything unusable is ignored with a line in the journal rather than taken
  # half-applied: the alternative to an access point is a box nobody can reach,
  # and the alternative to a readable screen is a box nobody can read.
  #
  # Every boot reads these again and nothing consumes them, so carrying the box
  # from a house with wifi to a hall without one needs nobody to touch the card.
  bootConfig = pkgs.writeShellApplication {
    name = "pesmarica-boot-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.wpa_supplicant
    ];
    text = ''
      WIFI=/boot/firmware/wifi.conf
      DISPLAY_CONF=/boot/firmware/display.conf

      mkdir -p ${runtimeDir} /run/systemd/network
      # Boot from a clean slate: whatever the last boot decided says nothing
      # about this one, and a leftover marker would keep the AP down.
      rm -f ${supplicantConf} ${clientNetwork} ${clientMarker} ${rotationFile}

      # These are written on a laptop, so a CRLF line ending and a UTF-8 BOM
      # are both normal. A value is everything after the first '=', which is
      # what lets a passphrase contain one.
      value() { # value <file> <key>
        [ -r "$1" ] || return 0
        sed -e '1s/^\xEF\xBB\xBF//' "$1" \
          | sed -n "s/^$2=//p" \
          | head -1 \
          | tr -d '\r'
      }

      # -- the screen ------------------------------------------------------

      rotation=$(value "$DISPLAY_CONF" rotation)
      case "$rotation" in
        # Written for the launcher, which prefers it over the one in
        # settings.json: this is the rotation you can set on a card, for a
        # screen nobody has ever been able to read the web interface on.
        0 | 90 | 180 | 270) printf '%s\n' "$rotation" > ${rotationFile} ;;
        "") ;;
        *) echo "pesmarica: $DISPLAY_CONF asks for rotation $rotation, which is not 0, 90, 180 or 270" >&2 ;;
      esac

      # -- the radio -------------------------------------------------------

      ssid=$(value "$WIFI" ssid)
      psk=$(value "$WIFI" psk)
      country=$(value "$WIFI" country)

      if [ -z "$ssid" ]; then
        echo "pesmarica: no network in $WIFI, staying an access point" >&2
        exit 0
      fi

      # 1..32 bytes, per 802.11.
      if [ "$(printf %s "$ssid" | wc -c)" -gt 32 ]; then
        echo "pesmarica: the ssid in $WIFI is too long, staying an access point" >&2
        exit 0
      fi

      if [ -n "$psk" ]; then
        len=$(printf %s "$psk" | wc -c)
        if [ "$len" -lt 8 ] || [ "$len" -gt 63 ]; then
          echo "pesmarica: $WIFI has a passphrase wpa_supplicant will not take, staying an access point" >&2
          exit 0
        fi
      fi

      umask 077
      {
        echo "# Generated at boot from $WIFI. Lives in tmpfs, never on a card."
        echo "ctrl_interface=/run/wpa_supplicant"
        if [ -n "$country" ]; then
          echo "country=$country"
        fi
      } > ${supplicantConf}

      if [ -n "$psk" ]; then
        # wpa_passphrase hashes it, and also prints the plaintext in a comment;
        # drop that line so the only cleartext copy is the one on the card.
        # scan_ssid: a hidden network answers a directed probe and nothing else.
        wpa_passphrase "$ssid" "$psk" \
          | grep -v '^[[:space:]]*#psk=' \
          | sed 's/^network={$/network={\n\tscan_ssid=1/' >> ${supplicantConf}
      else
        {
          echo "network={"
          echo "	ssid=\"$ssid\""
          echo "	scan_ssid=1"
          echo "	key_mgmt=NONE"
          echo "}"
        } >> ${supplicantConf}
      fi

      cat > ${clientNetwork} <<EOF
      [Match]
      Name=wlan0

      [Network]
      DHCP=ipv4
      # How the box is found once it is a guest on someone else's network:
      # pesmarica.local, the same name as on its own.
      MulticastDNS=yes
      IPv6AcceptRA=no

      [DHCPv4]
      UseNTP=no
      # The machine id is made up at every boot (see environment.etc above),
      # and so would be the DUID networkd derives from it; the MAC is what
      # keeps this box on the same lease from one boot to the next.
      ClientIdentifier=mac
      EOF
      # networkd reads its configuration as systemd-network, not as root, and
      # the umask above would leave this unreadable to it.
      chmod 0644 ${clientNetwork}

      touch ${clientMarker}
      echo "pesmarica: joining \"$ssid\"; the access point stays down" >&2
    '';
  };

  # Second line of defence behind the web interface's own validation: a
  # half-written file after a power cut, a hand-edit over SSH, or a future bug.
  # Losing the access point means losing the only way in, so the box always
  # comes up on *something*.
  apPreflight = pkgs.writeShellApplication {
    name = "pesmarica-ap-preflight";
    runtimeInputs = [ pkgs.coreutils pkgs.gnused pkgs.gnugrep ];
    text = ''
      RUNTIME=/var/lib/pesmarica/hostapd.conf
      DEFAULT=${defaultHostapdConf}

      valid() {
        conf="$1"
        [ -r "$conf" ] || return 1

        ssid=$(sed -n 's/^ssid=//p' "$conf" | head -1)
        # 1..32 bytes, per 802.11.
        [ -n "$ssid" ] || return 1
        [ "$(printf %s "$ssid" | wc -c)" -le 32 ] || return 1

        # Either open, or a WPA passphrase of a length hostapd will accept.
        if grep -q '^wpa=' "$conf"; then
          psk=$(sed -n 's/^wpa_passphrase=//p' "$conf" | head -1)
          len=$(printf %s "$psk" | wc -c)
          [ "$len" -ge 8 ] && [ "$len" -le 63 ] || return 1
        fi
        return 0
      }

      if ! valid "$RUNTIME"; then
        echo "pesmarica: $RUNTIME unusable, falling back to the shipped default" >&2
        cp "$DEFAULT" "$RUNTIME"
      fi
    '';
  };
in
{
  system.stateVersion = "26.05";

  hardware.raspberry-pi.config.all = {
    base-dt-params.audio.enable = false;
    dt-overlays.vc4-kms-v3d = {
      enable = true;
      params.cma-128 = { enable = true; };
    };
  };
  # linux-firmware is 1.85 GB unpacked -- firmware for every device Linux
  # supports, on a board with one wifi chip that is soldered on. Something
  # upstream turns it on, so it takes mkForce to turn back off.
  #
  # What replaces it is the Broadcom blob the radio actually needs. Getting this
  # wrong means no access point, which is the only way into the box, so if a
  # freshly flashed card comes up with no wifi this is the first line to suspect.
  # The Pi's own GPU firmware is separate and comes from raspberry-pi-02.base.
  hardware.enableRedistributableFirmware = lib.mkForce false;
  #
  # wireless-regdb is the other half: without it the kernel logs a failed load
  # of regulatory.db at boot and falls back to the world regulatory domain,
  # which quietly ignores the country_code hostapd is started with. It is a few
  # kilobytes, and it is what makes the AP legal on the channel it picks.
  # No U-Boot. The Pi firmware loads a kernel and an initramfs itself, given
  # kernel= and initramfs lines in config.txt; U-Boot only earned its place
  # with an extlinux menu of generations to choose from, and this box has
  # exactly one, flashed from the image. "kernel" is upstream's generational
  # direct-kernel loader: one folder under /boot/firmware/nixos per system,
  # holding kernel.img, initrd, cmdline.txt and the device trees, with
  # config.txt pointing at it through os_prefix -- which is also the shape a
  # second slot and the firmware's tryboot would want, later.
  boot.loader.raspberry-pi.bootloader = "kernel";
  # The slot is the folder name, and it is baked into this system: os_prefix
  # in config.txt, the tree the firmware populates, and the fstab line below
  # all come from it. Building the other slot is one option away
  # (pesmarica.slot = "b"), and a running box reports its own in
  # /etc/pesmarica-slot so a deploy knows which one is free.
  boot.loader.raspberry-pi.nixosGenerationsDir = "nixos-${config.pesmarica.slot}";
  environment.etc."pesmarica-slot".text = config.pesmarica.slot + "\n";
  # Reboot through sysrq. Asking the kernel to shut down cleanly means tearing
  # down a loop device whose backing file is the store every process is
  # executing from, and it does not come back from that -- the box sat at
  # "failed unmounting" until somebody pulled the plug, twice. The deploy
  # syncs and then writes b to sysrq-trigger, which restarts without the
  # teardown. Root is a tmpfs and the store is read-only; the sync is for the
  # two FAT partitions and is all a clean shutdown would have done for them.
  boot.kernel.sysctl."kernel.sysrq" = 1;

  # The panel is the product, and a congregation should not watch it boot.
  # Upstream ships loglevel=7 with console=tty1, so every kernel message and
  # every unit systemd starts scrolls across the screen until flutter-pi takes
  # it. Errors still reach the serial console for anyone debugging with a
  # cable; routine progress is gone from both. The screen stays black until
  # the first frame -- a real splash image is its own piece of work.
  boot.consoleLogLevel = lib.mkForce 3;
  boot.initrd.verbose = false;
  boot.kernelParams = [
    "quiet"
    "systemd.show_status=false"
    "vt.global_cursor_default=0"
  ];

  # /run/opengl-driver. flutter-pi links libgbm and libEGL, and since mesa 25
  # both are thin front ends that find the actual driver -- dri_gbm.so and the
  # EGL vendor file -- through this path and nowhere else. Without it flutter-pi
  # says "Could not create GBM device" on a perfectly good /dev/dri/card0 and
  # the box boots to a console.
  hardware.graphics.enable = true;

  # Stock mesa builds twenty-eight gallium drivers, so that one binary can
  # drive every GPU there is. This box has one, a VideoCore IV. Among the
  # twenty-six it will never meet is llvmpipe, the software rasteriser, and
  # llvmpipe is what drags in LLVM: 591 MB, about a third of the closure, for
  # a fallback that would draw this UI at a frame every few seconds if it ever
  # ran -- and if the GPU is gone the box is a dead screen either way.
  #
  # vc4 is the driver the Zero 2 W actually uses; v3d is its VideoCore VI
  # successor, kept because it is a few megabytes and the alternative to
  # guessing wrong is a black screen and a card reader. Neither needs LLVM.
  # flutter-pi is EGL/GLES throughout and VC4 has no Vulkan driver at all.
  #
  # The price is that mesa stops being a cache hit and builds from source on
  # every CI run. If that ever costs more than the megabytes are worth, the
  # way back is deleting this override.
  #
  # gallium-va has to go by hand: nixpkgs' meson hook sets auto_features=enabled,
  # which force-enables the VA-API state tracker, and that one refuses to build
  # without r600, radeonsi, nouveau, d3d12 or virgl among the drivers. Nothing
  # here decodes video anyway.
  hardware.graphics.package = (pkgs.mesa.override {
    galliumDrivers = [ "v3d" "vc4" ];
    vulkanDrivers = [ ];
  }).overrideAttrs (old: {
    mesonFlags = old.mesonFlags ++ [ (lib.mesonEnable "gallium-va" false) ];
    # mesa declares a spirv2dxil output unconditionally, but the library only
    # exists when the d3d12 driver is built -- and d3d12 drives a GPU that
    # exists inside WSL. With it gone, moveToOutput finds nothing, the output
    # path is never created, and nix fails the derivation for an empty output
    # rather than for anything being wrong. An empty directory satisfies it.
    postInstall = old.postInstall + ''
      mkdir -p "$spirv2dxil"
    '';
  });

  hardware.firmware = [
    pkgs.raspberrypiWirelessFirmware
    pkgs.wireless-regdb
  ];

  networking = {
    hostName = "pesmarica";
    # The box is always the access point and never a client: people connect *to*
    # it to reach the web interface. No wpa_supplicant, no credentials to leak.
    wireless.enable = false;
    useNetworkd = true;
    useDHCP = false;
    # dnsmasq answers every name with our own address; nothing else may bind :53.
    firewall.enable = false;
  };

  systemd.network.networks."20-wlan" = {
    matchConfig.Name = "wlan0";
    address = [ "${apAddress}/24" ];
    networkConfig = {
      MulticastDNS = true;
      # The box is the only router this link will ever have, so nothing to
      # accept. With RA on, networkd also arms a DHCPv6 client on the link, and
      # anything that client cannot set up takes the whole link to "failed"
      # with the static address never applied -- which is how the missing
      # machine-id above turned into an access point with no leases.
      IPv6AcceptRA = false;
      # Handing out leases here rather than from dnsmasq keeps the two
      # responsibilities apart: networkd owns addresses, dnsmasq owns names.
      DHCPServer = true;
    };
    dhcpServerConfig = {
      PoolOffset = 10;
      PoolSize = 40;
      EmitDNS = true;
      DNS = apAddress;
      EmitRouter = false;
    };
  };

  services.resolved = {
    enable = true;
    settings.Resolve = {
      LLMNR = "no";
      # Answers "pesmarica.local" without pulling in avahi.
      MulticastDNS = "yes";
      # dnsmasq owns :53 on wlan0; resolved must not try to claim it.
      DNSStubListener = "no";
    };
  };

  # The captive portal belongs to the access point: on someone else's network
  # the box is a guest, and a guest that answers every name is a nuisance.
  systemd.services.dnsmasq = {
    after = [ "pesmarica-boot-config.service" ];
    unitConfig.ConditionPathExists = "!${clientMarker}";
  };

  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      port = 53;
      no-resolv = true;
      no-hosts = true;
      bind-interfaces = true;
      interface = "wlan0";
      listen-address = apAddress;
      # Every name resolves to the box. There is no uplink to forward to, and it
      # is what makes a phone pop the captive-portal sheet open on the songbook
      # instead of sitting on "no internet".
      address = "/#/${apAddress}";
    };
  };

  # Nothing dials out, so there is no clock to sync and nobody to sync with.
  services.timesyncd.enable = false;

  # ZFS comes in by default. On a box with 512 MB of RAM, a squashfs and two
  # FAT partitions it is closure weight and a boot-time warning.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # The SD card is the part that dies. Everything that writes continuously is
  # moved to RAM, so that in steady state the only thing reaching the card is
  # the songbook itself: the front matter the display stamps as pages are shown,
  # and the access point config when someone changes it through the web UI.
  services.journald = {
    storage = "volatile";
    extraConfig = ''
      # 512 MB of RAM total, so the log in memory has to be bounded.
      RuntimeMaxUse=16M
    '';
  };
  boot.tmp.useTmpfs = true;

  # The system is rootfs.img on the boot partition: one squashfs holding the
  # closure, which the initrd loop-mounts as /nix/store. Root is a tmpfs, so
  # nothing on the card is ever written by the system itself -- the logs,
  # systemd's state, /var, all of it goes with the power. The only things
  # that persist are the two FAT partitions, and both of those a laptop can
  # read. See modules/image.nix for how the card is laid out.
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=0755" "noatime" ];
  };
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    neededForBoot = true;
    # umask: wifi.conf on this partition carries a passphrase.
    options = [ "noatime" "umask=0077" "x-systemd.device-timeout=30s" ];
  };
  # The device is named by its path *in the initrd*, where the boot partition
  # sits under /sysroot -- and systemd orders this after that mount from the
  # path alone. The same line lands in the final /etc/fstab, where it is
  # already mounted and never looked at again. The slot in the path is why a
  # system can only ever boot from the slot it was built for.
  fileSystems."/nix/.ro-store" = {
    device = "/sysroot/boot/firmware/${config.boot.loader.raspberry-pi.nixosGenerationsDir}/default/rootfs.img";
    fsType = "squashfs";
    options = [ "loop" "threads=multi" ];
    neededForBoot = true;
  };
  fileSystems."/nix/store" = {
    device = "/nix/.ro-store";
    fsType = "none";
    options = [ "bind" ];
    neededForBoot = true;
  };
  boot.initrd.supportedFilesystems = { vfat = true; squashfs = true; };
  boot.initrd.kernelModules = [ "loop" ];
  boot.supportedFilesystems = { vfat = true; squashfs = true; };

  # NixOS activation rewrites the whole of /etc on every boot, which is the
  # largest thing still touching the card once the logs are in RAM. Mounting
  # /etc as an overlay of the store instead makes a boot write nothing: the
  # generated files are already in the closure, and the writable layer is a
  # tmpfs that goes away with the power.
  boot.initrd.systemd.enable = true;
  system.etc.overlay = {
    enable = true;
    mutable = false;
  };
  # systemd refuses to boot with no /etc/machine-id and no way to create one:
  # "System cannot boot: Missing /etc/machine-id and /etc/ is read-only". It
  # does not actually stop, it carries on with no id at all, and everything
  # that asks for one fails in its own way -- dbus-broker exits with ENOENT, so
  # every unit ordered after it waits its 90 seconds; networkd builds its DHCP
  # identifiers from it, so wlan0 never gets an address and the access point
  # hands out no leases. An empty file is the documented third way: systemd
  # then makes an id up at boot and bind-mounts it over this one.
  environment.etc."machine-id".text = "";

  # An immutable /etc means /etc/passwd and /etc/shadow come from the closure,
  # so accounts cannot be edited on the box -- useradd would have nowhere to
  # write. For an appliance with one account that is the point.
  users.mutableUsers = false;
  # With /etc in the store, the accounts have to exist before anything mounts
  # it: sysusers creates them from the closure at boot instead of an activation
  # script editing /etc/passwd in place.
  systemd.sysusers.enable = true;

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    # /etc is a read-only overlay of the store, so sshd-keygen cannot write the
    # host key where it normally does and the unit fails -- taking ssh, the only
    # way into a box whose screen is broken, with it. With root in RAM the
    # only place a key can outlive a boot is the songbook partition, so it
    # lives there, in a dotfile the laptops will not show. One ed25519 key,
    # not also a 4096-bit RSA one: this generates on a Zero 2 W, at boot.
    hostKeys = [
      {
        path = "/var/lib/pesmarica/.ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    # Authorized keys have the same problem as the host key, and it bites
    # later: root's home is on the tmpfs, so a key copied there works until
    # the next reboot and then is gone -- including the reboot that
    # deploy_system.sh does at the end of its own run, which makes the ssh
    # update path good for exactly one use. Beside the host key it survives,
    # and because that partition is FAT32 a laptop with a card reader can
    # authorize a machine on a box that is on no network.
    #
    # Appended, not forced: /root/.ssh still works for the length of a boot,
    # which is how a key gets put here in the first place.
    authorizedKeysFiles = [ "/var/lib/pesmarica/.ssh/authorized_keys" ];
  };
  # Wants, not Requires: a card with no songbook partition still gets an
  # sshd, with a key that lasts one boot.
  systemd.services.sshd = {
    after = [ "var-lib-pesmarica.mount" ];
    wants = [ "var-lib-pesmarica.mount" ];
  };
  users.users.root.initialPassword = "pesmarica";

  # No nix on the box at all: the system comes from a flashed image and the
  # store is never queried, so the daemon, the database and the tools are
  # weight on the card and a few seconds of every boot. Upstream's
  # register-nix-paths would load that database on the first boot and then
  # touch /etc/NIXOS, which the read-only /etc refuses -- so the unit failed,
  # never cleared its trigger, and retried every boot. With no database to
  # fill there is nothing left for it to do.
  nix.enable = false;
  systemd.services.register-nix-paths.enable = lib.mkForce false;

  # pam_lastlog2 seeds its database from /var/log/lastlog, which on this box is
  # a fresh tmpfs every boot with no such file in it, so the import unit fails.
  # Nobody logs in but the person holding an ssh key, and the record of it would
  # be one more thing writing to the card.
  systemd.services.lastlog2-import.enable = lib.mkForce false;

  documentation.enable = false;
  documentation.nixos.enable = false;

  # An appliance with no keyboard and no shell user: everything below is weight
  # on a card that has to hold a songbook, and none of it is reachable from the
  # screen or the web interface.
  environment.defaultPackages = lib.mkForce [ ];
  programs.command-not-found.enable = false;
  # Flutter carries its own text stack and the fonts are inside the bundle, so
  # nothing on this box asks fontconfig anything.
  fonts.fontconfig.enable = lib.mkForce false;

  # NixOS ships its own hostapd module, but it renders an immutable config into
  # the store. The web interface rewrites this config at runtime, so the unit is
  # defined by hand against the mutable copy instead.
  systemd.services.hostapd = {
    description = "Pesmarica access point";
    wantedBy = [ "multi-user.target" ];
    # The AP is the only way in, so it comes up early and independently of the app.
    after = [
      "systemd-tmpfiles-setup.service"
      "sys-subsystem-net-devices-wlan0.device"
      "pesmarica-boot-config.service"
    ];
    bindsTo = [ "sys-subsystem-net-devices-wlan0.device" ];
    unitConfig = {
      # The config it starts from is on the songbook partition.
      RequiresMountsFor = "/var/lib/pesmarica";
      # One radio: the box is either a network or on one. The marker says which,
      # and the fallback below removes it and starts this unit by hand when the
      # network it was told to join does not materialise.
      ConditionPathExists = "!${clientMarker}";
    };
    before = [ "systemd-networkd.service" ];
    conflicts = [ "wpa_supplicant.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStartPre = lib.getExe apPreflight;
      ExecStart = "${pkgs.hostapd}/bin/hostapd /var/lib/pesmarica/hostapd.conf";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      # Keep trying: a radio that comes up late must not leave the box unreachable.
      Restart = "always";
      RestartSec = 2;
    };
  };

  # Runs before anything touches the radio and decides which of the two the box
  # is this boot. Everything downstream reads the marker it leaves behind.
  systemd.services.pesmarica-boot-config = {
    description = "Read the preconfiguration off the boot partition";
    wantedBy = [ "sysinit.target" ];
    wants = [ "network-pre.target" ];
    before = [ "network-pre.target" ];
    after = [ "local-fs.target" ];
    unitConfig.RequiresMountsFor = "/boot/firmware";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe bootConfig;
    };
  };

  # NixOS has a wpa_supplicant module, but like hostapd above it renders an
  # immutable config into the store, and this one is written at boot from a file
  # somebody dropped on the card. So: by hand, against the runtime copy.
  systemd.services.wpa_supplicant = {
    description = "Join the configured wifi network";
    wantedBy = [ "multi-user.target" ];
    after = [
      "pesmarica-boot-config.service"
      "sys-subsystem-net-devices-wlan0.device"
    ];
    bindsTo = [ "sys-subsystem-net-devices-wlan0.device" ];
    unitConfig.ConditionPathExists = supplicantConf;
    conflicts = [ "hostapd.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -i wlan0 -c ${supplicantConf}";
      # An access point that comes back after the router does is worth more than
      # a clean failure: the box is on a wall and nobody is going to restart it.
      Restart = "always";
      RestartSec = 2;
    };
  };

  # The half that makes the whole thing safe to try. A wrong passphrase, a
  # router that has been replaced, a hall with no wifi at all: after a
  # ${toString joinTimeout} second wait the box goes back to being an access
  # point, which is the state someone standing next to it can do something
  # about. It runs again on the next boot, so carrying the box between a house
  # with wifi and a hall without one needs nobody to touch the card.
  systemd.services.pesmarica-wifi-fallback = {
    description = "Fall back to the access point if the network never comes up";
    wantedBy = [ "multi-user.target" ];
    after = [ "wpa_supplicant.service" "systemd-networkd.service" ];
    unitConfig = {
      ConditionPathExists = clientMarker;
      RequiresMountsFor = "/boot/firmware";
    };
    path = [ pkgs.systemd pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      status=/boot/firmware/wifi.status

      # Written only when it changes: a boot that goes the way the last one did
      # leaves the card alone, and one that does not leaves an explanation on
      # the partition any laptop can read -- which is the whole diagnostic
      # story for a box that is not answering on the network it was told to
      # join and no longer has an access point to ask.
      record() {
        [ "$(cat "$status" 2>/dev/null || true)" = "$1" ] || printf '%s\n' "$1" > "$status" || true
      }

      if ${config.systemd.package}/lib/systemd/systemd-networkd-wait-online \
          --interface=wlan0:routable --timeout=${toString joinTimeout}; then
        echo "pesmarica: on the configured network" >&2
        record "joined, $(date -Is)"
        exit 0
      fi

      echo "pesmarica: no address after ${toString joinTimeout}s, falling back to the access point" >&2
      record "could not join, running as the access point instead"

      # Order matters: the radio has to stop being a client before it can be an
      # access point, and networkd must forget the client address before it
      # applies the static one.
      rm -f ${clientMarker} ${clientNetwork} ${supplicantConf}
      systemctl stop wpa_supplicant.service
      systemctl start hostapd.service
      networkctl reload
      networkctl reconfigure wlan0
      systemctl start dnsmasq.service
    '';
  };

  # The same decision the boot makes, made again on demand: the web interface
  # writes wifi.conf and starts this. It is one unit rather than the app doing
  # the steps itself, because the app is the thing that goes away when the radio
  # does -- and because the boot and a change from a phone must not be able to
  # drift apart.
  systemd.services.pesmarica-network-apply = {
    description = "Apply a change to wifi.conf without a reboot";
    unitConfig.RequiresMountsFor = "/boot/firmware";
    path = [ pkgs.systemd pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      ${lib.getExe bootConfig}

      if [ -e ${clientMarker} ]; then
        systemctl stop dnsmasq.service hostapd.service
        systemctl start wpa_supplicant.service
      else
        systemctl stop wpa_supplicant.service
        systemctl start hostapd.service
        systemctl start dnsmasq.service
      fi
      networkctl reload
      networkctl reconfigure wlan0

      # Re-arm the way back. Joining from a phone is the same gamble as joining
      # at boot -- the network may not be there -- so it gets the same watchdog,
      # and --no-block because that watchdog waits ${toString joinTimeout}s.
      systemctl restart --no-block pesmarica-wifi-fallback.service
    '';
  };

  systemd.services.pesmarica = {
    description = "Pesmarica digital signage";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = [
      "/var/lib/pesmarica"
      # wifi.conf and display.conf: the web interface edits both.
      "/boot/firmware"
    ];

    # systemctl: the web interface applies a network change and restarts this
    # unit onto a bundle it has just installed. tar and gzip: unpacking that
    # bundle.
    path = [ pkgs.systemd pkgs.gnutar pkgs.gzip ];

    serviceConfig = {
      Type = "simple";
      Environment = [
        "PESMARICA_CONTENT=/var/lib/pesmarica"
        "PESMARICA_BOOT=/boot/firmware"
      ];
      ExecStart = launch;
      Restart = "always";
      RestartSec = 2;

      # flutter-pi drives KMS/DRM directly: it needs a VT of its own, and
      # nothing else may be drawing on it.
      StandardInput = "tty";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # The songbook lives on its own FAT32 partition so the card can be pulled and
  # the pages edited from any laptop -- which is how a songbook actually gets
  # updated in a parish hall, rather than over ssh. FAT32 rather than exFAT
  # because it is the only filesystem both a laptop and this build can write:
  # mtools populates it offline, so the partition ships in the image with the
  # songbook already in it, and a freshly flashed card shows the pages before
  # the box has ever been switched on. It has no journal, so a power cut
  # mid-write can take out the directory rather than one file; that is the price
  # of a card Windows and macOS will both mount.
  #
  # The 4 GB per-file ceiling is not a limit anything here can reach: the pages
  # are markdown and the pictures are photographs of hymn sheets.

  # How the image is built is modules/image.nix; what it ships is set here.
  pesmarica.image = {
    inherit content;
    hostapdConf = defaultHostapdConf;
  };

  systemd.services.pesmarica-data = {
    description = "Grow the songbook partition into the rest of the card";
    wantedBy = [ "local-fs.target" ];
    before = [ "var-lib-pesmarica.mount" ];
    path = [
      pkgs.util-linux
      pkgs.parted
      pkgs.fatresize
      pkgs.dosfstools
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Nothing here may fail the unit: the mount below requires it, and a card
    # that cannot be grown still holds the songbook the image put on it. No
    # marker either, now that nothing outlives a boot -- the card itself says
    # whether there is work: a partition that stops short of the disk, or a
    # filesystem that stops short of its partition, which is what a power cut
    # during the first boot leaves behind.
    script = ''
      part=$(readlink -f /dev/disk/by-label/PESMARICA) || exit 0
      [ -b "$part" ] || { echo "pesmarica: no songbook partition to grow" >&2; exit 0; }
      name=$(basename "$part")
      disk=/dev/$(lsblk --noheadings --output PKNAME "$part" | head -1)
      number=$(cat "/sys/class/block/$name/partition")
      start=$(cat "/sys/class/block/$name/start")
      size=$(cat "/sys/class/block/$name/size")
      disksize=$(blockdev --getsz "$disk")

      # More than 8 MiB of card after the partition: take it.
      if [ $(( disksize - start - size )) -gt 16384 ]; then
        if echo ",+," | sfdisk -N"$number" --no-reread "$disk"; then
          partprobe "$disk" || true
          udevadm settle
          size=$(cat "/sys/class/block/$name/size")
        else
          echo "pesmarica: could not grow the songbook partition" >&2
        fi
      fi

      # FAT32 keeps its size in the boot sector: total sectors, 4 bytes at 32.
      fssize=$(od -An -t u4 -j 32 -N 4 "$part" | tr -d ' ')
      if [ $(( size - fssize )) -gt 2048 ]; then
        # fatresize will not touch a filesystem that has not been checked,
        # and the check is worth having anyway on a card that was pulled out
        # of a laptop mid-copy.
        fsck.fat -a "$part" || true
        fatresize -s max "$part" \
          || echo "pesmarica: fatresize failed, the songbook stays at $(( fssize / 2048 )) MiB" >&2
        udevadm settle
      fi
    '';
  };

  fileSystems."/var/lib/pesmarica" = {
    device = "/dev/disk/by-label/PESMARICA";
    fsType = "vfat";
    # nofail: a card whose data partition never appeared should still boot to a
    # reachable box with an empty songbook, not drop into an emergency shell.
    options = [
      "nofail"
      "noatime"
      # FAT has no permissions of its own, so they come from the mount. The
      # wifi passphrase sits in hostapd.conf here.
      "umask=0077"
      # Pesmarica folds čšž out of the names it writes itself, but the point of
      # this partition is that a person can drop files on it from a laptop, and
      # theirs will not be folded. Without this the kernel reads those names as
      # latin-1 and the songbook shows mojibake.
      "utf8=1"
      "x-systemd.requires=pesmarica-data.service"
      "x-systemd.device-timeout=30s"
    ];
  };

  systemd.tmpfiles.rules = [
    # Seed the songbook once; pages written through the web UI stay put.
    "C /var/lib/pesmarica - - - - ${content}"
    # The access point config lives beside the songbook so the web interface can
    # change it and so it survives a rebuild of the system closure.
    # No mode here: the songbook is FAT, which has no permissions to set -- the
    # mount's umask covers it instead. The image ships this file already; the
    # rule is what puts it back if it is deleted from a laptop.
    "C /var/lib/pesmarica/hostapd.conf - - - - ${defaultHostapdConf}"
    # The two app slots. Deploys fill them; the launcher above picks between
    # them. Empty on a fresh card, which is how the image's own bundle runs.
    "d ${slots} - - - -"
  ];

  # tty1 belongs to flutter-pi. Both names: getty@tty1 is what the getty
  # generator would start, autovt@tty1 is what logind starts for whichever
  # console is active -- and the unit above hangs up the tty when it starts,
  # the getty hangs it back on its own restart, and the two take turns killing
  # each other every two seconds. Masking only the first is what that looked
  # like: a login prompt on the panel and NRestarts climbing.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;
}
