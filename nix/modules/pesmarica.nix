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

  # The base profile brings ZFS in. On a box with 512 MB of RAM and one exFAT
  # partition it is closure weight and a boot-time warning, nothing else.
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

  # noatime alone removes a write for every page the display reads. commit=600
  # lets ext4 batch ten minutes of metadata instead of flushing every five
  # seconds -- the box is a screen on a wall, and a power cut costs at most the
  # view counter, which is the one thing here nobody would notice losing.
  fileSystems."/".options = [ "noatime" "nodiratime" "commit=600" ];

  # systemd's own state is disposable on an appliance: a fresh random seed and
  # an empty lease file every boot cost nothing and keep the card idle.
  fileSystems."/var/lib/systemd" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=0755" "size=8M" ];
  };
  fileSystems."/var/log" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=0755" "size=8M" ];
  };

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
    # way into a box whose screen is broken, with it. The keys live on the root
    # filesystem instead, written once on the first boot. One ed25519 key, not
    # also a 4096-bit RSA one: this generates on a Zero 2 W, at boot.
    hostKeys = [
      {
        path = "/var/lib/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };
  users.users.root.initialPassword = "pesmarica";

  # Same read-only /etc, upstream's own unit: it registers the store paths (on
  # /nix, writable) and then touches /etc/NIXOS, which cannot work here, so the
  # unit fails before it clears /nix-path-registration and retries every boot.
  # The tag is for nixos-rebuild, which an appliance whose system comes from a
  # flashed image never runs; the registration itself is worth keeping.
  systemd.services.register-nix-paths.script =
    let
      inherit (config.sdImage) nixPathRegistrationFile;
      nix = config.nix.package.out;
    in
    lib.mkForce ''
      ${lib.getExe' nix "nix-store"} --load-db < ${nixPathRegistrationFile}
      ${lib.getExe' nix "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system
      rm -f ${nixPathRegistrationFile}
    '';

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
  nix.channel.enable = false;
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
    after = [ "systemd-tmpfiles-setup.service" "sys-subsystem-net-devices-wlan0.device" ];
    bindsTo = [ "sys-subsystem-net-devices-wlan0.device" ];
    # The config it starts from is on the songbook partition.
    unitConfig.RequiresMountsFor = "/var/lib/pesmarica";
    before = [ "systemd-networkd.service" ];

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

  systemd.services.pesmarica = {
    description = "Pesmarica digital signage";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = "/var/lib/pesmarica";

    # systemctl: the web interface restarts hostapd after it rewrites the access
    # point config, and restarts this unit onto a bundle it has just installed.
    # tar and gzip: unpacking that bundle.
    path = [ pkgs.systemd pkgs.gnutar pkgs.gzip ];

    serviceConfig = {
      Type = "simple";
      Environment = "PESMARICA_CONTENT=/var/lib/pesmarica";
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

  # The songbook lives on its own exFAT partition so the card can be pulled and
  # the pages edited from any laptop -- which is how a songbook actually gets
  # updated in a parish hall, rather than over ssh. exFAT has no journal and
  # weaker rename semantics than ext4, so a power cut mid-write can take out the
  # directory rather than one file; that is the price of a card Windows and
  # macOS will both mount.
  boot.supportedFilesystems.exfat = true;

  # The image ships two partitions and the root one is not grown, so the rest of
  # the card is free for this. ConditionPathExists means it runs once, ever.
  sdImage.expandOnBoot = false;

  systemd.services.pesmarica-data = {
    description = "Create the songbook partition on first boot";
    wantedBy = [ "local-fs.target" ];
    before = [ "var-lib-pesmarica.mount" ];
    unitConfig.ConditionPathExists = "!/dev/disk/by-label/PESMARICA";
    path = [ pkgs.util-linux pkgs.exfatprogs pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      root=$(findmnt --noheadings --output SOURCE --target /)
      disk=/dev/$(lsblk --noheadings --output PKNAME "$root" | head -1)
      [ -b "$disk" ] || { echo "pesmarica: no disk behind $root" >&2; exit 1; }

      # type 7 is the one Windows and macOS both read as exFAT.
      echo ',,7' | sfdisk --append --no-reread "$disk"
      partprobe "$disk" || true
      udevadm settle

      part=$(lsblk --noheadings --output PATH "$disk" | tail -1)
      mkfs.exfat -L PESMARICA "$part"
      udevadm settle
    '';
  };

  fileSystems."/var/lib/pesmarica" = {
    device = "/dev/disk/by-label/PESMARICA";
    fsType = "exfat";
    # nofail: a card whose data partition never appeared should still boot to a
    # reachable box with an empty songbook, not drop into an emergency shell.
    options = [
      "nofail"
      "noatime"
      # exFAT has no permissions of its own, so they come from the mount. The
      # wifi passphrase sits in hostapd.conf here.
      "umask=0077"
      "x-systemd.requires=pesmarica-data.service"
      "x-systemd.device-timeout=30s"
    ];
  };

  systemd.tmpfiles.rules = [
    # Seed the songbook once; pages written through the web UI stay put.
    "C /var/lib/pesmarica - - - - ${content}"
    # The access point config lives beside the songbook so the web interface can
    # change it and so it survives a rebuild of the system closure.
    # No mode here: the songbook is exFAT, which has no permissions to set --
    # the mount's umask covers it instead.
    "C /var/lib/pesmarica/hostapd.conf - - - - ${defaultHostapdConf}"
    # The two app slots. Deploys fill them; the launcher above picks between
    # them. Empty on a fresh card, which is how the image's own bundle runs.
    "d ${slots} - - - -"
  ];

  # tty1 belongs to flutter-pi.
  systemd.services."getty@tty1".enable = false;
}
