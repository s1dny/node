{
  description = "Homelab NixOS module and deployment assets";

  outputs = { self }: {
    nixosModules.default = import ./nixos/homelab-module.nix;
    nixosModules.homelab = self.nixosModules.default;

    templates.host-bootstrap = {
      path = ./templates/host-bootstrap;
      description = "Bootstrap /etc/nixos flake that pins this homelab module";
    };
  };
}
