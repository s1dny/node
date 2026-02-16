{ lib, pkgs, ... }:

let
  homelabSrc = ../.;
  homelabSourcePath = "/etc/homelab/source";
  homelabSecretsFile = "/etc/homelab/secrets.env";
  homelabGeneratedDir = "/var/lib/homelab/generated";
  homelabK8sSecretsDir = "${homelabGeneratedDir}/k8s/secrets";
  defaultHostHostname = "azalab-0";
  defaultHostUsername = "aiden";
  defaultHostAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNLDRhkSlst/ch4vyH8gm3bh79BRB4MIdLiB/jrT5w6 aiden@plarza.com"
  ];
in
{
  networking.hostName = defaultHostHostname;
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
  environment.etc."homelab/secrets.env.example".source = "${homelabSrc}/secrets/secrets.env.example";

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

    (writeShellScriptBin "homelab-render-secrets" ''
      set -euo pipefail
      export HOMELAB_STATIC_DIR="${homelabSourcePath}"
      export HOMELAB_SECRETS_ENV="${homelabSecretsFile}"
      export HOMELAB_GENERATED_DIR="${homelabGeneratedDir}"
      export HOMELAB_K8S_SECRETS_DIR="${homelabK8sSecretsDir}"
      exec "${homelabSourcePath}/scripts/render-secrets.sh" "$@"
    '')

    (writeShellScriptBin "homelab-deploy-k8s" ''
      set -euo pipefail
      export HOMELAB_STATIC_DIR="${homelabSourcePath}"
      export HOMELAB_SECRETS_ENV="${homelabSecretsFile}"
      export HOMELAB_GENERATED_DIR="${homelabGeneratedDir}"
      export HOMELAB_K8S_SECRETS_DIR="${homelabK8sSecretsDir}"
      exec "${homelabSourcePath}/scripts/deploy-k8s.sh" "$@"
    '')

    (writeShellScriptBin "homelab-check-k8s-health" ''
      set -euo pipefail
      exec "${homelabSourcePath}/scripts/check-k8s-health.sh" "$@"
    '')
  ];

  environment.sessionVariables = {
    KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
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

  systemd.services.render-k8s-secrets = {
    description = "Render Kubernetes secrets from homelab secrets file";
    wantedBy = lib.mkForce [ ];
    unitConfig = {
      StartLimitIntervalSec = 0;
    };
    path = [ pkgs.bash ];
    environment = {
      HOMELAB_STATIC_DIR = homelabSourcePath;
      HOMELAB_SECRETS_ENV = homelabSecretsFile;
      HOMELAB_GENERATED_DIR = homelabGeneratedDir;
      HOMELAB_K8S_SECRETS_DIR = homelabK8sSecretsDir;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };
    script = ''
      set -euo pipefail

      if [[ ! -r "${homelabSecretsFile}" ]]; then
        echo "render-k8s-secrets: ${homelabSecretsFile} not found; skipping."
        exit 0
      fi

      exec "${homelabSourcePath}/scripts/render-secrets.sh" "${homelabSecretsFile}"
    '';
  };

  systemd.paths.render-k8s-secrets = {
    description = "Watch homelab secrets and render Kubernetes manifests";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = homelabSecretsFile;
      PathChanged = homelabSecretsFile;
    };
  };

  systemd.services.host-identity-sync = {
    description = "Apply host username and hostname from homelab secrets";
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      StartLimitIntervalSec = 0;
    };
    path = [ pkgs.bash pkgs.coreutils pkgs.gawk pkgs.shadow pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };
    script = ''
      set -euo pipefail

      secrets_file="${homelabSecretsFile}"
      if [[ ! -r "$secrets_file" ]]; then
        echo "host-identity-sync: $secrets_file not found; skipping."
        exit 0
      fi

      set -a
      # shellcheck disable=SC1090
      source "$secrets_file"
      set +a

      host_hostname="''${HOST_HOSTNAME:-${defaultHostHostname}}"
      host_username="''${HOST_USERNAME:-${defaultHostUsername}}"

      if [[ ! "$host_hostname" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo "host-identity-sync: invalid HOST_HOSTNAME '$host_hostname'; skipping hostname update."
      else
        current_hostname="$(${pkgs.util-linux}/bin/hostnamectl --static 2>/dev/null || ${pkgs.coreutils}/bin/hostname)"
        if [[ "$current_hostname" != "$host_hostname" ]]; then
          if ! ${pkgs.util-linux}/bin/hostnamectl set-hostname "$host_hostname"; then
            echo "host-identity-sync: failed to apply HOST_HOSTNAME '$host_hostname'; continuing."
          fi
        fi
      fi

      if [[ "$host_username" == "root" || ! "$host_username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "host-identity-sync: invalid HOST_USERNAME '$host_username'; skipping user sync."
        exit 0
      fi

      supplemental_groups="wheel"
      if ${pkgs.gawk}/bin/awk -F: '$1 == "networkmanager" { found = 1 } END { exit(found ? 0 : 1) }' /etc/group; then
        supplemental_groups="${supplemental_groups},networkmanager"
      fi

      if ! ${pkgs.gawk}/bin/awk -F: -v user="$host_username" '$1 == user { found = 1 } END { exit(found ? 0 : 1) }' /etc/passwd; then
        if ! ${pkgs.shadow}/bin/useradd \
          --create-home \
          --shell "${pkgs.fish}/bin/fish" \
          --groups "$supplemental_groups" \
          "$host_username"; then
          echo "host-identity-sync: failed to create user '$host_username'; skipping user sync."
          exit 0
        fi
      fi

      if ! ${pkgs.shadow}/bin/usermod \
        --append \
        --groups "$supplemental_groups" \
        --shell "${pkgs.fish}/bin/fish" \
        "$host_username"; then
        echo "host-identity-sync: failed to update user '$host_username'; skipping user sync."
        exit 0
      fi

      passwd_entry="$(${pkgs.gawk}/bin/awk -F: -v user="$host_username" '$1 == user { print; exit }' /etc/passwd)"
      home_dir="$(printf '%s\n' "$passwd_entry" | ${pkgs.gawk}/bin/awk -F: '{print $6}')"
      primary_gid="$(printf '%s\n' "$passwd_entry" | ${pkgs.gawk}/bin/awk -F: '{print $4}')"
      if [[ -n "$home_dir" && -n "$primary_gid" ]]; then
        if ! ${pkgs.coreutils}/bin/install -d -m 0700 -o "$host_username" -g "$primary_gid" "$home_dir/.ssh"; then
          echo "host-identity-sync: failed to prepare $home_dir/.ssh; skipping authorized_keys bootstrap."
          exit 0
        fi
        keys_file="$home_dir/.ssh/authorized_keys"
        if [[ ! -s "$keys_file" ]]; then
          cat >"$keys_file" <<'KEYS'
${lib.concatStringsSep "\n" defaultHostAuthorizedKeys}
KEYS
          if ! ${pkgs.coreutils}/bin/chown "$host_username:$primary_gid" "$keys_file"; then
            echo "host-identity-sync: failed to set owner on $keys_file."
          fi
          if ! ${pkgs.coreutils}/bin/chmod 0600 "$keys_file"; then
            echo "host-identity-sync: failed to set mode on $keys_file."
          fi
        fi
      else
        echo "host-identity-sync: unable to determine home dir/group for '$host_username'; skipping authorized_keys bootstrap."
      fi
    '';
  };

  systemd.paths.host-identity-sync = {
    description = "Watch homelab secrets and re-apply host identity";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = homelabSecretsFile;
      PathChanged = homelabSecretsFile;
    };
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
      EnvironmentFile = homelabSecretsFile;
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

  systemd.services.cloudflared-dashboard-tunnel-refresh = {
    description = "Restart cloudflared when homelab secrets change";
    path = [ pkgs.systemd ];
    unitConfig = {
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      systemctl try-restart cloudflared-dashboard-tunnel.service
    '';
  };

  systemd.paths.cloudflared-dashboard-tunnel-refresh = {
    description = "Watch homelab secrets and refresh cloudflared";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = homelabSecretsFile;
      PathChanged = homelabSecretsFile;
    };
  };

  systemd.tmpfiles.rules = [
    "d /etc/homelab 0755 root root -"
    "d /var/lib/homelab 0755 root root -"
    "d /var/lib/homelab/generated 0750 root wheel -"
    "d /var/lib/homelab/generated/k8s 0750 root wheel -"
    "d /var/lib/homelab/generated/k8s/secrets 0750 root wheel -"
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
      EnvironmentFile = homelabSecretsFile;
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
      EnvironmentFile = homelabSecretsFile;
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
