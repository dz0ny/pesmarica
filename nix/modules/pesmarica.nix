{ config, pkgs, lib, ... }:

let
  # Staged by the Makefile from build/flutter-pi/<cpu>/ -- the AOT snapshot,
  # the Flutter engine and the assets. Built on macOS because the Dart
  # snapshotter only ships as an x86_64 binary.
  bundle = pkgs.runCommand "pesmarica-bundle" { } ''
    mkdir -p $out
    cp -r ${../bundle}/. $out/
    # flutterpi_tool ships a prebuilt embedder; we use the one from nixpkgs,
    # linked against this system's libraries.
    rm -f $out/flutter-pi $out/.last_build_id
  '';

  flutter-pi = pkgs.callPackage ../pkgs/flutter-pi.nix { };

  # Staged next to the bundle: a flake cannot reference paths outside its root.
  content = ../content;
in
{
  system.stateVersion = "24.11";

  raspberry-pi-nix.board = "bcm2711";

  hardware.raspberry-pi.config.all = {
    base-dt-params = {
      # No analogue audio, and do not probe for cameras or DSI panels.
      audio.enable = false;
    };
    dt-overlays.vc4-kms-v3d = {
      enable = true;
      params.cma-128 = { enable = true; };
    };
  };

  networking = {
    hostName = "pesmarica";
    wireless = {
      enable = true;
      # Replace before building, or use networking.wireless.environmentFile.
      networks."CHANGEME".psk = "CHANGEME";
    };
  };

  services.resolved.llmnr = "false";
  services.avahi = {
    enable = true;
    publish = { enable = true; addresses = true; };
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };
  users.users.root.initialPassword = "pesmarica";

  # Nothing here has a keyboard or a shell user.
  documentation.enable = false;
  documentation.nixos.enable = false;

  systemd.services.pesmarica = {
    description = "Pesmarica digital signage";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];

    serviceConfig = {
      Type = "simple";
      Environment = "PESMARICA_CONTENT=/var/lib/pesmarica";
      ExecStart = "${lib.getExe flutter-pi} --release ${bundle}";
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

  # Seed the songbook once; pages written through the web UI stay put.
  systemd.tmpfiles.rules = [
    "C /var/lib/pesmarica - - - - ${content}"
  ];

  # tty1 belongs to flutter-pi.
  systemd.services."getty@tty1".enable = false;
}
