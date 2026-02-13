{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "azalab-0";
  time.timeZone = "Australia/Sydney";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 6443 ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  programs.fish.enable = true;
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  programs.fish.shellAliases = {
    cd = "z";
    v = "nvim";
    ls = "eza";
  };

  environment.systemPackages = with pkgs; [
    git
    curl
    jq
    yq-go
    rustc
    cargo
    python3
    kubectl
    kubernetes-helm
    k3s
    kopia
    cloudflared
    neovim
    eza
  ];

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    extraFlags = toString [
      "--write-kubeconfig-mode=0640"
    ];
  };

  systemd.services.cloudflared-dashboard-tunnel = {
    description = "Cloudflare Tunnel (dashboard-managed)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.cloudflared pkgs.bash ];
    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      EnvironmentFile = "/etc/cloudflared/tunnel-token.env";
      Restart = "always";
      RestartSec = "5s";
    };
    script = ''
      exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN"
    '';
  };

  systemd.tmpfiles.rules = [
    "d /etc/cloudflared 0700 root root -"
    "d /srv/libsql/data 0750 root root -"
    "d /srv/immich/library 0750 root root -"
    "d /srv/immich/postgres 0750 root root -"
    "d /srv/immich/redis 0750 root root -"
    "d /srv/kopia/repository 0750 root root -"
    "d /srv/vaultwarden/data 0750 root root -"
    "d /var/lib/kopia 0700 root root -"
    "d /etc/kopia 0700 root root -"
  ];

  systemd.services.kopia-host-backup = {
    description = "Kopia host snapshots to local repository";
    after = [ "network-online.target" "k3s.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.kopia pkgs.coreutils pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = "/etc/kopia/kopia.env";
      ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/homelab/scripts/kopia-host-backup.sh";
    };
  };

  systemd.timers.kopia-host-backup = {
    description = "Run Kopia host backup every night";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  systemd.services.kopia-r2-sync = {
    description = "Kopia sync local repository to Cloudflare R2";
    after = [ "network-online.target" "kopia-host-backup.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.kopia pkgs.coreutils pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = "/etc/kopia/kopia.env";
      ExecStart = "${pkgs.bash}/bin/bash /etc/nixos/homelab/scripts/kopia-r2-sync.sh";
    };
  };

  systemd.timers.kopia-r2-sync = {
    description = "Run Kopia R2 sync every 6 hours";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/6:10:00";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
  };

  users.users.homelab = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNLDRhkSlst/ch4vyH8gm3bh79BRB4MIdLiB/jrT5w6 aiden@plarza.com"
    ];
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.11";
}
