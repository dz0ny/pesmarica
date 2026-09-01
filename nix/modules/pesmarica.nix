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

  # The image defines the system, so the unit runs the bundle from the store.
  # tool/deploy_pi.sh pushes a working build into the override directory to
  # iterate on the app without reflashing; delete it to go back to the image's
  # own bundle.
  override = "/var/lib/pesmarica/bundle-override";

  launch = pkgs.writeShellScript "pesmarica-launch" ''
    if [ -d ${override} ]; then
      echo "pesmarica: running the override bundle from ${override}" >&2
      exec ${lib.getExe flutter-pi} --release ${override}
    fi
    exec ${lib.getExe flutter-pi} --release ${bundle}
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
        install -m 0600 "$DEFAULT" "$RUNTIME"
      fi
    '';
  };
in
{
  system.stateVersion = "24.11";

  raspberry-pi-nix.board = "bcm2711";
  # raspberry-pi-nix defaults to v6_6_51 (October 2024). Nothing is cached for
  # any of the three available versions, so a newer kernel costs the same build.
  raspberry-pi-nix.kernel-version = "v6_12_17";

  hardware.raspberry-pi.config.all = {
    base-dt-params.audio.enable = false;
    dt-overlays.vc4-kms-v3d = {
      enable = true;
      params.cma-128 = { enable = true; };
    };
  };
  hardware.enableRedistributableFirmware = true;

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
    llmnr = "false";
    extraConfig = ''
      # Answers "pesmarica.local" without pulling in avahi.
      MulticastDNS=yes
      # dnsmasq owns :53 on wlan0; resolved must not try to claim it.
      DNSStubListener=no
    '';
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

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };
  users.users.root.initialPassword = "pesmarica";

  documentation.enable = false;
  documentation.nixos.enable = false;

  # NixOS ships its own hostapd module, but it renders an immutable config into
  # the store. The web interface rewrites this config at runtime, so the unit is
  # defined by hand against the mutable copy instead.
  systemd.services.hostapd = {
    description = "Pesmarica access point";
    wantedBy = [ "multi-user.target" ];
    # The AP is the only way in, so it comes up early and independently of the app.
    after = [ "systemd-tmpfiles-setup.service" "sys-subsystem-net-devices-wlan0.device" ];
    bindsTo = [ "sys-subsystem-net-devices-wlan0.device" ];
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

    # The web interface shells out to `systemctl restart hostapd` after it
    # rewrites the access point config.
    path = [ pkgs.systemd ];

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

  systemd.tmpfiles.rules = [
    # Seed the songbook once; pages written through the web UI stay put.
    "C /var/lib/pesmarica - - - - ${content}"
    # The access point config lives beside the songbook so the web interface can
    # change it and so it survives a rebuild of the system closure.
    "C /var/lib/pesmarica/hostapd.conf 0600 root root - ${defaultHostapdConf}"
  ];

  # tty1 belongs to flutter-pi.
  systemd.services."getty@tty1".enable = false;
}
