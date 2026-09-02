{
  description = "Pesmarica signage appliance -- Raspberry Pi Zero 2 W";

  # Where the kernel comes from. raspberry-pi-nix advertises a cache too, but
  # every path in it is long gone; this one is real, and checked before the
  # switch: linux_rpi02 resolves in it rather than 404ing.
  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  inputs = {
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
    # Follow theirs: their cache is only useful for the nixpkgs their kernel and
    # firmware were built against.
    nixpkgs.follows = "nixos-raspberrypi/nixpkgs";
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, ... }@inputs:
    let
      system = "aarch64-linux";

      # nixosSystem, not nixosSystemFull: Full injects the Pi-optimised package
      # overlays globally, which rebuilds userland this box never runs and costs
      # the cache hits that made this upstream worth moving to.
      appliance = extra: nixos-raspberrypi.lib.nixosSystem {
        specialArgs = inputs;
        modules = [
          ({ nixos-raspberrypi, ... }: {
            imports = with nixos-raspberrypi.nixosModules; [
              # The Zero 2 W as its own target, rather than a Pi 4 config that
              # happens to boot on one.
              raspberry-pi-02.base
              # Not sd-image: that module is an ext4 root and U-Boot, and the
              # card here is two FAT partitions with the system in a file.
            ];
          })
          ./modules/pesmarica.nix
          ./modules/image.nix
        ] ++ extra;
      };
    in
    {
      nixosConfigurations = {
        pesmarica = appliance [ ];

        # The image the same, only left uncompressed. CI compresses it with xz
        # itself, and unpacking zstd only to repack it would be a few minutes of
        # a runner spent on nothing.
        pesmarica-raw = appliance [ { pesmarica.image.compress = false; } ];
      };

      packages.${system} = {
        default = self.nixosConfigurations.pesmarica.config.system.build.sdImage;
        sdImage = self.nixosConfigurations.pesmarica.config.system.build.sdImage;
        sdImageRaw = self.nixosConfigurations.pesmarica-raw.config.system.build.sdImage;
        flutter-pi = nixpkgs.legacyPackages.${system}.callPackage ./pkgs/flutter-pi.nix { };
      };
    };
}
