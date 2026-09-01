{
  description = "Pesmarica signage appliance -- Raspberry Pi Zero 2 W";

  inputs = {
    # raspberry-pi-nix pins its own nixpkgs; following ours would mean building
    # the vendor kernel locally instead of pulling it from its cachix.
    raspberry-pi-nix.url = "github:nix-community/raspberry-pi-nix";
    nixpkgs.follows = "raspberry-pi-nix/nixpkgs";
  };

  outputs = { self, nixpkgs, raspberry-pi-nix, ... }:
    let
      system = "aarch64-linux";

      appliance = extra: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          raspberry-pi-nix.nixosModules.raspberry-pi
          raspberry-pi-nix.nixosModules.sd-image
          ./modules/pesmarica.nix
        ] ++ extra;
      };
    in
    {
      nixosConfigurations = {
        pesmarica = appliance [ ];

        # The image the same, only left uncompressed. CI compresses it with xz
        # itself, and unpacking zstd only to repack it would be a few minutes of
        # a runner spent on nothing.
        pesmarica-raw = appliance [ { sdImage.compressImage = false; } ];
      };

      packages.${system} = {
        default = self.nixosConfigurations.pesmarica.config.system.build.sdImage;
        sdImage = self.nixosConfigurations.pesmarica.config.system.build.sdImage;
        sdImageRaw = self.nixosConfigurations.pesmarica-raw.config.system.build.sdImage;
        flutter-pi = nixpkgs.legacyPackages.${system}.callPackage ./pkgs/flutter-pi.nix { };
      };
    };
}
