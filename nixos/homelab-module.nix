{ config, lib, pkgs, ... }:

let
  homelabSrc = ../.;
  homelabSourcePath = "/etc/homelab/source";
  homelabHostSecretsDir = "/etc/homelab/host-secrets";
  homelabCloudflaredSecretsFile = "/etc/homelab/cloudflare/tunnel-token.env";
  homelabKopiaR2SecretsFile = "${homelabHostSecretsDir}/kopia-r2.env";
  defaultHostHostname = "azalab-0";
  defaultHostUsername = "aiden";
  defaultHostAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNLDRhkSlst/ch4vyH8gm3bh79BRB4MIdLiB/jrT5w6 aiden@plarza.com"
  ];
in
{
  networking.hostName = lib.mkDefault defaultHostHostname;
  networking.networkmanager.enable = true;
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

  environment.etc."homelab/source".source = homelabSrc;
  environment.etc."homelab/cloudflare/tunnel-token.env.example".source = "${homelabSrc}/cloudflare/tunnel-token.env.example";
  environment.etc."homelab/host-secrets/kopia-r2.env.example".source = "${homelabSrc}/nixos/secrets/kopia-r2.env.example";
  environment.etc."homelab/k8s-secrets/libsql-auth.env.example".source = "${homelabSrc}/flux/clusters/azalab-0/manifests/apps/libsql/libsql-auth.env.example";
  environment.etc."homelab/k8s-secrets/kopia-auth.env.example".source = "${homelabSrc}/flux/clusters/azalab-0/manifests/apps/kopia/kopia-auth.env.example";
  environment.etc."homelab/k8s-secrets/immich-db-secret.env.example".source = "${homelabSrc}/flux/clusters/azalab-0/manifests/apps/immich/immich-db-secret.env.example";
  environment.etc."homelab/k8s-secrets/immich-redis-secret.env.example".source = "${homelabSrc}/flux/clusters/azalab-0/manifests/apps/immich/immich-redis-secret.env.example";
  environment.etc."homelab/k8s-secrets/vaultwarden-secret.env.example".source = "${homelabSrc}/flux/clusters/azalab-0/manifests/apps/vaultwarden/vaultwarden-secret.env.example";
  environment.etc."homelab/k8s-secrets/tuwunel-secret.env.example".source = "${homelabSrc}/flux/clusters/azalab-0/manifests/apps/tuwunel/tuwunel-secret.env.example";

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
    claude-code
    codex
    opencode

    (writeShellScriptBin "homelab-check-k8s-health" ''
      set -euo pipefail
      exec "${homelabSourcePath}/scripts/check-k8s-health.sh" "$@"
    '')
  ];

  environment.sessionVariables = {
    KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    CLUSTER = config.networking.hostName;
  };

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    extraFlags = toString [
      "--write-kubeconfig-mode=0640"
      "--write-kubeconfig-group=wheel"
    ];
  };

  systemd.services.cloudflared-dashboard-tunnel = {
    description = "Cloudflare Tunnel (dashboard-managed)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.cloudflared pkgs.bash ];
    unitConfig = {
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      EnvironmentFile = homelabCloudflaredSecretsFile;
      Restart = "always";
      RestartSec = "5s";
    };
    script = ''
      set -euo pipefail
      set +u
      if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
        echo "cloudflared-dashboard-tunnel: CLOUDFLARE_TUNNEL_TOKEN is required"
        exit 1
      fi
      set -u

      exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN"
    '';
  };

  systemd.tmpfiles.rules = [
    "d /etc/homelab 0755 root root -"
    "d /etc/homelab/cloudflare 0750 root wheel -"
    "d /etc/homelab/host-secrets 0750 root wheel -"
    "d /etc/homelab/k8s-secrets 0750 root wheel -"
    "d /var/lib/homelab 0755 root root -"
    "d /var/lib/homelab/generated 0750 root wheel -"
    "d /var/lib/homelab/generated/k8s 0750 root wheel -"
    "d /srv/libsql/data 0750 root root -"
    "d /srv/immich/library 0750 root root -"
    "d /srv/immich/postgres 0750 root root -"
    "d /srv/immich/redis 0750 root root -"
    "d /srv/kopia/repository 0750 root root -"
    "d /srv/vaultwarden/data 0750 root root -"
    "d /srv/tuwunel/data 0750 root root -"
    "d /var/lib/kopia 0700 root root -"
  ];

  systemd.services.kopia-host-backup = {
    description = "Kopia host snapshots to local repository";
    after = [ "network-online.target" "k3s.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.kopia pkgs.coreutils pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = homelabKopiaR2SecretsFile;
      ExecStart = "${pkgs.bash}/bin/bash ${homelabSourcePath}/scripts/kopia-host-backup.sh";
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
      EnvironmentFile = homelabKopiaR2SecretsFile;
      ExecStart = "${pkgs.bash}/bin/bash ${homelabSourcePath}/scripts/kopia-r2-sync.sh";
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

  users.users.${defaultHostUsername} = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = defaultHostAuthorizedKeys;
  };

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.11";
}
