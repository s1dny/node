# Homelab NixOS Setup

Personal homelab configuration for a Dell Optiplex 7060 running NixOS with k3s. Defaults are hardcoded to my setup (domain, hostnames, SSH keys, etc.). If you want to change the defaults, fork the repo and edit them there.

## What's running
- NixOS on bare metal
- k3s for orchestration
- Cloudflare Tunnels
- Kopia backup server at `https://kopia.aza.network`, replicated to Cloudflare R2
- MacBook backups to Optiplex via Kopia + Cloudflare Access

## Architecture
Clone-free on the host, reproducible by lock file:
- `/etc/nixos/flake.nix`: host bootstrap flake
- `/etc/nixos/flake.lock`: pinned revisions for `nixpkgs` and this repo
- `/etc/homelab/source`: read-only symlink to the pinned source
- `/etc/homelab/secrets.env`: single runtime secrets file
- `/var/lib/homelab/generated/k8s/secrets`: generated Kubernetes secret manifests

## Prerequisites
- Domain in Cloudflare: `aza.network`
- Cloudflare Zero Trust account
- Dashboard-managed Cloudflare Tunnel token
- NixOS installer USB
- Console/KVM access for first boot (SSH key auth is enforced)

## 1) Install NixOS (fresh machine)
1. Boot NixOS installer. Make sure you have network (ethernet auto-connects, for wifi use `nmtui`).
2. Partition using `disko` (this erases the target disk):
   ```bash
   sudo -i
   lsblk -d -o NAME,SIZE,MODEL,SERIAL

   curl -fsSL "https://raw.githubusercontent.com/s1dny/node/main/nixos/disko.nix" -o /tmp/disko.nix
   # edit and set disko.devices.disk.main.device to your disk
   vi /tmp/disko.nix

   nix --extra-experimental-features "nix-command flakes" run github:nix-community/disko/latest -- --mode disko /tmp/disko.nix
   nixos-generate-config --root /mnt
   ```
3. Fetch host bootstrap flake and generate lock file:
   ```bash
   mkdir -p /mnt/etc/nixos
   curl -fsSL "https://raw.githubusercontent.com/s1dny/node/main/nixos/host-flake.nix" -o /mnt/etc/nixos/flake.nix
   cd /mnt/etc/nixos
   nix --extra-experimental-features "nix-command flakes" flake lock
   ```
4. Install and reboot:
   ```bash
   nixos-install --flake /mnt/etc/nixos#azalab-0
   sudo passwd aiden
   reboot
   ```
5. After reboot, find the machine's IP (check your router or run `ip a` on the console). If `sudo` works in your current console session
   ```bash
   ssh aiden@<IP>
   ```
   Do everything from here on over SSH.
6. From your local machine (in the root of your clone of this repo), create a secrets file from the template and copy it over:
   ```bash
   cp secrets/secrets.env.example secrets/secrets.env
   vi secrets/secrets.env  # fill in values needed for features you are enabling
   scp secrets/secrets.env aiden@<IP>:/tmp/secrets.env
   ```
7. On the server, install secrets and rebuild:
   ```bash
   sudo mv /tmp/secrets.env /etc/homelab/secrets.env
   sudo chmod 0600 /etc/homelab/secrets.env
   sudo nixos-rebuild switch --flake /etc/nixos#azalab-0
   ```

## 2) Day-2 updates
```bash
cd /etc/nixos
sudo nix flake update homelab
sudo nixos-rebuild switch --flake /etc/nixos#azalab-0
```

`/etc/nixos/flake.lock` is the exact deployed source-of-truth.

## 3) Cloudflare Tunnel
In Cloudflare Zero Trust dashboard, create a tunnel named `azalab-0` with these hostnames:
- `db.aza.network` -> `http://localhost:80`
- `photos.aza.network` -> `http://localhost:80`
- `kopia.aza.network` -> `http://localhost:80`
- `vault.aza.network` -> `http://localhost:80`
- `matrix.aza.network` -> `http://localhost:80`

Put the token in `/etc/homelab/secrets.env` as `CLOUDFLARE_TUNNEL_TOKEN` and rebuild.

## 4) Deploy Kubernetes workloads
```bash
sudo systemctl status render-k8s-secrets --no-pager
kubectl get nodes
homelab-deploy-k8s
homelab-check-k8s-health
```

## 5) Cloudflare Access policies
Put `photos.aza.network` and `kopia.aza.network` behind Cloudflare Access. Don't put `vault.aza.network` behind it if you need native Bitwarden clients.

## 6) Vaultwarden setup
1. Create first account at `https://vault.aza.network`.
2. Sign into admin at `https://vault.aza.network/admin` using `VAULTWARDEN_ADMIN_TOKEN` from `/etc/homelab/secrets.env`.
3. Disable public registrations:
   ```bash
   kubectl -n vaultwarden set env deployment/vaultwarden SIGNUPS_ALLOWED="false"
   ```
   Then commit the same change to `k8s/05-vaultwarden.yaml` in Git so it persists across rebuilds.

## 7) Tuwunel (Matrix homeserver)
1. After deploy, verify it's running:
   ```bash
   kubectl -n tuwunel get pods
   curl -s https://matrix.aza.network/_matrix/client/versions
   ```
2. Registration is disabled by default. To create the first account, temporarily enable it:
   ```bash
   kubectl -n tuwunel set env deployment/tuwunel TUWUNEL_ALLOW_REGISTRATION="true"
   ```
   Register via a Matrix client (e.g. Element), then disable registration again:
   ```bash
   kubectl -n tuwunel set env deployment/tuwunel TUWUNEL_ALLOW_REGISTRATION="false"
   ```

## 8) Kopia backups
`k8s/03-kopia.yaml` uses `--insecure` and `--disable-csrf-token-checks`. Keep `kopia.aza.network` behind Cloudflare Access.

`KOPIA_R2_ENDPOINT` format: `https://<accountid>.r2.cloudflarestorage.com`

Timers run automatically (`kopia-host-backup.timer`, `kopia-r2-sync.timer`). Run manually if needed:
```bash
sudo systemctl start kopia-host-backup.service
sudo systemctl start kopia-r2-sync.service
```

## 9) MacBook backup
```bash
brew install cloudflared kopia
cloudflared access tcp --hostname kopia.aza.network --url localhost:15151
```

In another terminal:
```bash
kopia repository connect server \
  --url=http://127.0.0.1:15151 \
  --override-hostname=kopia.aza.network \
  --server-username=YOUR_USERNAME \
  --server-password=YOUR_PASSWORD

kopia snapshot create ~/Documents ~/Pictures ~/Desktop
```

## 10) Verification
```bash
homelab-check-k8s-health
```

Manual checks:
```bash
sudo systemctl status cloudflared-dashboard-tunnel --no-pager
kubectl get pods -A
kubectl -n libsql get ingress,svc,pods
kubectl -n immich get ingress,svc,pods
kubectl -n backup get ingress,svc,pods
kubectl -n vaultwarden get ingress,svc,pods
kubectl -n tuwunel get ingress,svc,pods
sudo journalctl -u kopia-host-backup.service -n 100 --no-pager
sudo journalctl -u kopia-r2-sync.service -n 100 --no-pager
```
