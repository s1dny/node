{ config, lib, pkgs, ... }:

let
  homelabSrc = ../.;
  homelabSourcePath = "/etc/homelab/source";
  homelabRuntimeSecretsDir = "/run/secrets/homelab";
  homelabCloudflaredSecretsFile = "${homelabRuntimeSecretsDir}/cloudflare-tunnel-token.env";
  homelabKopiaR2SecretsFile = "${homelabRuntimeSecretsDir}/kopia-r2.env";
  homelabHostSecretsSopsFile = "${homelabSrc}/nixos/secrets/host-secrets.sops.yaml";
  homelabSopsAgeKeyFile = "/var/lib/sops-nix/key.txt";
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

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "${config.networking.hostName} samba";
        "netbios name" = config.networking.hostName;
        "security" = "user";
        "map to guest" = "Bad User";
      };
      public = {
        "path" = "/srv/samba/public";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0644";
        "directory mask" = "0775";
        "force user" = defaultHostUsername;
      };
      rootfs = {
        "path" = "/";
        "browseable" = "yes";
        "read only" = "yes";
        "guest ok" = "yes";
        "force user" = defaultHostUsername;
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
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
  environment.etc."homelab/host-secrets/kopia-r2.env.example".source = "${homelabSrc}/nixos/secrets/kopia-r2.env.example";

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
    sops
    age
    neovim
    eza
    claude-code
    codex
    opencode

    (writeShellScriptBin "homelab-check-k8s-health" ''
      set -euo pipefail
      if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      fi

      kubectl wait --for=condition=Ready nodes --all --timeout=2m

      if kubectl get namespace flux-system >/dev/null 2>&1; then
        kubectl -n flux-system wait --for=condition=Ready gitrepository/flux-system --timeout=5m
        kubectl -n flux-system wait --for=condition=Ready kustomizations.kustomize.toolkit.fluxcd.io --all --timeout=10m
        kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io,kustomizations.kustomize.toolkit.fluxcd.io
      fi

      kubectl get pods -A
      kubectl get ingress -A
      kubectl get pvc -A
    '')
  ];

  environment.sessionVariables = {
    KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    CLUSTER = config.networking.hostName;
  };

  sops.age = {
    keyFile = homelabSopsAgeKeyFile;
    generateKey = true;
  };
  sops.secrets."homelab/cloudflare-tunnel-token.env" = {
    sopsFile = homelabHostSecretsSopsFile;
    format = "yaml";
    key = "cloudflare_tunnel_token_env";
    path = homelabCloudflaredSecretsFile;
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "cloudflared-dashboard-tunnel.service" ];
  };
  sops.secrets."homelab/kopia-r2.env" = {
    sopsFile = homelabHostSecretsSopsFile;
    format = "yaml";
    key = "kopia_r2_env";
    path = homelabKopiaR2SecretsFile;
    owner = "root";
    group = "root";
    mode = "0400";
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

  systemd.services.homelab-ensure-flux-sops-age = {
    description = "Ensure flux-system/sops-age secret exists";
    after = [ "k3s.service" "network-online.target" ];
    wants = [ "k3s.service" "network-online.target" ];
    path = [ pkgs.kubectl pkgs.bash pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      set -euo pipefail
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

      if [[ ! -s "${homelabSopsAgeKeyFile}" ]]; then
        echo "homelab-ensure-flux-sops-age: key file ${homelabSopsAgeKeyFile} is missing"
        exit 0
      fi

      if [[ ! -r "$KUBECONFIG" ]]; then
        echo "homelab-ensure-flux-sops-age: kubeconfig is not readable yet"
        exit 0
      fi

      if ! kubectl --request-timeout=5s get namespace flux-system >/dev/null 2>&1; then
        echo "homelab-ensure-flux-sops-age: flux-system namespace not present yet"
        exit 0
      fi

      kubectl -n flux-system create secret generic sops-age \
        --from-file=age.agekey="${homelabSopsAgeKeyFile}" \
        --dry-run=client -o yaml \
        | kubectl apply -f -
    '';
  };

  systemd.timers.homelab-ensure-flux-sops-age = {
    description = "Reconcile flux-system/sops-age secret";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "15m";
      RandomizedDelaySec = "1m";
      Persistent = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /etc/homelab 0755 root root -"
    "d /var/lib/sops-nix 0700 root root -"
    "d /var/lib/homelab 0755 root root -"
    "d /var/lib/homelab/generated 0750 root wheel -"
    "d /var/lib/homelab/generated/k8s 0750 root wheel -"
    "d /srv/libsql/data 0750 root root -"
    "d /srv/immich/library 0750 root root -"
    "d /srv/immich/postgres 0750 root root -"
    "d /srv/immich/redis 0750 root root -"
    "d /srv/kopia/repository 0750 root root -"
    "d /srv/samba 0755 root root -"
    "d /srv/samba/public 0775 ${defaultHostUsername} users -"
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
