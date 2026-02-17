{
  description = "Homelab NixOS module and deployment assets";

  inputs = {
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs = { self, sops-nix, ... }: {
    nixosModules.default = { ... }: {
      imports = [
        sops-nix.nixosModules.sops
        ./nixos/homelab-module.nix
      ];
    };
    nixosModules.homelab = self.nixosModules.default;

    templates.host-bootstrap = {
      path = ./templates/host-bootstrap;
      description = "Bootstrap /etc/nixos flake that pins this homelab module";
    };
  };
}
