{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "azalab-0";
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
    description = "Render Kubernetes secrets from homelab-secrets.env";
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      User = "homelab";
      Group = "users";
      WorkingDirectory = "/etc/nixos/homelab";
    };
    script = ''
      set -euo pipefail

      secrets_file="/etc/nixos/homelab/secrets/homelab-secrets.env"
      if [[ ! -r "$secrets_file" ]]; then
        echo "render-k8s-secrets: ${secrets_file} not found; skipping."
        exit 0
      fi

      /etc/nixos/homelab/scripts/render-secrets.sh "$secrets_file"
    '';
  };

  systemd.paths.render-k8s-secrets = {
    description = "Watch homelab secrets and render Kubernetes manifests";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/etc/nixos/homelab/secrets/homelab-secrets.env";
      PathChanged = "/etc/nixos/homelab/secrets/homelab-secrets.env";
    };
  };

  systemd.services.wifi-autoconnect = {
    description = "Configure Wi-Fi from homelab secrets";
    after = [ "NetworkManager.service" ];
    wants = [ "NetworkManager.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.bash pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.networkmanager ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail

      secrets_file="/etc/nixos/homelab/secrets/homelab-secrets.env"
      if [[ ! -r "$secrets_file" ]]; then
        echo "wifi-autoconnect: ${secrets_file} not found; skipping."
        exit 0
      fi

      set -a
      # shellcheck disable=SC1090
      source "$secrets_file"
      set +a

      if [[ -z "${WIFI_SSID:-}" || -z "${WIFI_PASSWORD:-}" ]]; then
        echo "wifi-autoconnect: WIFI_SSID/WIFI_PASSWORD unset; skipping."
        exit 0
      fi

      wifi_if=""
      for _ in $(seq 1 20); do
        wifi_if="$(${pkgs.networkmanager}/bin/nmcli -t -f DEVICE,TYPE device status | ${pkgs.gawk}/bin/awk -F: '$2 == "wifi" { print $1; exit }')"
        if [[ -n "$wifi_if" ]]; then
          break
        fi
        sleep 1
      done

      if [[ -z "$wifi_if" ]]; then
        echo "wifi-autoconnect: no Wi-Fi interface found; skipping."
        exit 0
      fi

      if ${pkgs.networkmanager}/bin/nmcli -t -f NAME connection show | ${pkgs.gnugrep}/bin/grep -Fxq "homelab-wifi"; then
        ${pkgs.networkmanager}/bin/nmcli connection modify homelab-wifi \
          connection.interface-name "$wifi_if" \
          802-11-wireless.ssid "$WIFI_SSID" \
          wifi-sec.key-mgmt wpa-psk \
          wifi-sec.psk "$WIFI_PASSWORD" \
          connection.autoconnect yes
      else
        ${pkgs.networkmanager}/bin/nmcli connection add \
          type wifi \
          ifname "$wifi_if" \
          con-name homelab-wifi \
          ssid "$WIFI_SSID" \
          wifi-sec.key-mgmt wpa-psk \
          wifi-sec.psk "$WIFI_PASSWORD" \
          connection.autoconnect yes
      fi

      ${pkgs.networkmanager}/bin/nmcli connection up homelab-wifi || true
    '';
  };

  systemd.paths.wifi-autoconnect = {
    description = "Watch homelab secrets and re-apply Wi-Fi profile";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/etc/nixos/homelab/secrets/homelab-secrets.env";
      PathChanged = "/etc/nixos/homelab/secrets/homelab-secrets.env";
    };
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
      EnvironmentFile = "/etc/nixos/homelab/secrets/homelab-secrets.env";
      Restart = "always";
      RestartSec = "5s";
    };
    script = ''
      : "''${CLOUDFLARE_TUNNEL_TOKEN:?CLOUDFLARE_TUNNEL_TOKEN is required}"
      exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN"
    '';
  };

  systemd.services.cloudflared-dashboard-tunnel-refresh = {
    description = "Restart cloudflared when homelab secrets change";
    path = [ pkgs.systemd ];
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
      PathExists = "/etc/nixos/homelab/secrets/homelab-secrets.env";
      PathChanged = "/etc/nixos/homelab/secrets/homelab-secrets.env";
    };
  };

  systemd.tmpfiles.rules = [
    "L+ /etc/nixos/configuration.nix - - - - /etc/nixos/homelab/nixos/configuration.nix"
    "L+ /etc/nixos/homelab/nixos/hardware-configuration.nix - - - - /etc/nixos/hardware-configuration.nix"
    "Z /etc/nixos/homelab - homelab users -"
    "d /srv/libsql/data 0750 root root -"
    "d /srv/immich/library 0750 root root -"
    "d /srv/immich/postgres 0750 root root -"
    "d /srv/immich/redis 0750 root root -"
    "d /srv/kopia/repository 0750 root root -"
    "d /srv/vaultwarden/data 0750 root root -"
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
      EnvironmentFile = "/etc/nixos/homelab/secrets/homelab-secrets.env";
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
      EnvironmentFile = "/etc/nixos/homelab/secrets/homelab-secrets.env";
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
    extraGroups = [ "wheel" "networkmanager" ];
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGNLDRhkSlst/ch4vyH8gm3bh79BRB4MIdLiB/jrT5w6 aiden@plarza.com"
    ];
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "25.11";
}
