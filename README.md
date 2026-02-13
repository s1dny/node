# Homelab Setup Guide (Pinned Flake Workflow)

This stack gives you:
- NixOS on bare metal (Dell Optiplex 7060)
- k3s for orchestration
- Cloudflare Tunnel for inbound traffic (`db`, `photos`, `kopia`, `vault`)
- Cloudflare Access policies for `photos` and `kopia`
- `libsql` in k3s at `https://db.aza.network`
- Immich in k3s at `https://photos.aza.network`
- Vaultwarden in k3s at `https://vault.aza.network`
- Kopia local encrypted repository on the Optiplex, replicated to Cloudflare R2
- MacBook backups to Optiplex via Kopia Repository Server through Cloudflare Access

## Architecture
This setup is clone-free on the host and reproducible by lock file:
- `/etc/nixos/flake.nix`: small host bootstrap flake
- `/etc/nixos/flake.lock`: pinned revisions for `nixpkgs` and this homelab repo
- `/etc/homelab/source`: read-only symlink to the pinned homelab source
- `/etc/homelab/secrets.env`: single runtime secrets file
- `/var/lib/homelab/generated/k8s/secrets`: generated Kubernetes secret manifests

## 0) Prerequisites
- Domain in Cloudflare: `aza.network`
- Cloudflare Zero Trust account (`<team>.cloudflareaccess.com`)
- Dashboard-managed Cloudflare Tunnel token
- NixOS installer USB
- Console/KVM access for first boot (SSH key auth is enforced)
- Homelab repo pushed to GitHub

## 0.5) Prepare repo defaults before first install
Update these in Git before installing:
- `users.users.homelab.openssh.authorizedKeys.keys` in `nixos/homelab-module.nix`
- Any default hostname/timezone you want in `nixos/homelab-module.nix`

Commit and push. The host will pin and deploy exactly what is in Git.

## 1) Install NixOS (fresh machine)
1. Boot NixOS installer.
2. Partition using `disko` (this erases the target disk):
   ```bash
   sudo -i
   lsblk -d -o NAME,SIZE,MODEL,SERIAL
   ls -l /dev/disk/by-id

   # Fetch pinned disk layout from your repo commit
   export GH_OWNER="YOUR_GITHUB_OWNER"
   export GH_REPO="YOUR_REPO"
   export GH_REV="YOUR_COMMIT_SHA"

   curl -fsSL "https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/${GH_REV}/nixos/disko.nix" -o /tmp/disko.nix
   # edit /tmp/disko.nix and set disko.devices.disk.main.device correctly
   $EDITOR /tmp/disko.nix

   nix --extra-experimental-features "nix-command flakes" run github:nix-community/disko/latest -- --mode disko /tmp/disko.nix
   nixos-generate-config --root /mnt
   ```
3. Create host bootstrap flake at `/mnt/etc/nixos/flake.nix`:
   ```bash
   mkdir -p /mnt/etc/nixos
   cat > /mnt/etc/nixos/flake.nix <<'FLAKE'
   {
     description = "Host bootstrap flake for homelab";

     inputs = {
       nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
       homelab.url = "github:YOUR_GITHUB_OWNER/YOUR_REPO";
     };

     outputs = { nixpkgs, homelab, ... }:
       let
         system = "x86_64-linux";
       in {
         nixosConfigurations.azalab-0 = nixpkgs.lib.nixosSystem {
           inherit system;
           modules = [
             ./hardware-configuration.nix
             homelab.nixosModules.default
           ];
         };
       };
   }
   FLAKE
   ```
4. Create and pin lock file:
   ```bash
   cd /mnt/etc/nixos
   nix flake lock --override-input homelab "github:${GH_OWNER}/${GH_REPO}?rev=${GH_REV}"
   ```
5. Install runtime secrets file:
   ```bash
   install -d -m 0755 /mnt/etc/homelab
   cp /path/to/homelab-secrets.env /mnt/etc/homelab/secrets.env
   chmod 0600 /mnt/etc/homelab/secrets.env
   ```
6. Install and reboot:
   ```bash
   nixos-install --flake /mnt/etc/nixos#azalab-0
   reboot
   ```

## 2) Day-2 updates (reproducible)
When you change this repo:
1. Commit + push Git changes.
2. On host, advance only the pinned homelab input and rebuild:
   ```bash
   cd /etc/nixos
   sudo nix flake lock --update-input homelab
   sudo nixos-rebuild switch --flake /etc/nixos#azalab-0
   ```

`/etc/nixos/flake.lock` is the exact deployed source-of-truth.

## 3) Secrets
Single runtime file:
- `/etc/homelab/secrets.env`
- Template is available at `/etc/homelab/secrets.env.example`

Edit secrets:
```bash
sudoedit /etc/homelab/secrets.env
```

Optional Wi-Fi values in the same file:
- `WIFI_SSID`
- `WIFI_PASSWORD`

On rebuild (or secrets file change), these happen declaratively:
- `render-k8s-secrets.service` regenerates k8s secrets
- `wifi-autoconnect.service` updates NetworkManager profile
- `cloudflared-dashboard-tunnel` is refreshed

## 4) Cloudflare Tunnel + DNS
In Cloudflare Zero Trust dashboard:
1. Go to `Networks` -> `Tunnels` -> `Create a tunnel` -> `Cloudflared`.
2. Name it `azalab-0`.
3. Add hostnames:
   - `db.aza.network` -> `http://localhost:80`
   - `photos.aza.network` -> `http://localhost:80`
   - `kopia.aza.network` -> `http://localhost:80`
   - `vault.aza.network` -> `http://localhost:80`
4. Put token into `/etc/homelab/secrets.env` as `CLOUDFLARE_TUNNEL_TOKEN`.
5. Validate:
   ```bash
   sudo systemctl status cloudflared-dashboard-tunnel --no-pager
   ```

## 5) Deploy Kubernetes workloads
1. Confirm secrets rendering is healthy:
   ```bash
   sudo systemctl status render-k8s-secrets --no-pager
   ```
2. Placeholder check:
   ```bash
   grep -nE "REPLACE_WITH|REPLACE_ME|CHANGE_ME" \
     /etc/homelab/secrets.env /var/lib/homelab/generated/k8s/secrets/*.yaml || true
   ```
   Expected: no output.
3. Confirm k3s:
   ```bash
   sudo systemctl status k3s --no-pager
   kubectl get nodes
   ```
4. Deploy:
   ```bash
   homelab-deploy-k8s
   ```

## 6) Cloudflare Access policies (edge auth)
Create two Access applications:
- `photos.aza.network`
- `kopia.aza.network`

Policy recommendation:
- Allow only your IdP group/emails.
- Add device posture checks if you use WARP.

Do not put `vault.aza.network` behind Cloudflare Access if you need native Bitwarden clients.

## 7) Vaultwarden first account + hardening
After deploy:
1. Open `https://vault.aza.network` and create first account.
2. Open `https://vault.aza.network/admin` and sign in with `ADMIN_TOKEN` from `/var/lib/homelab/generated/k8s/secrets/vaultwarden-secret.yaml`.
3. Disable public registrations:
   - edit `/etc/homelab/source/k8s/05-vaultwarden.yaml`
   - set `SIGNUPS_ALLOWED` to `"false"`
   - apply:
   ```bash
   kubectl apply -f /etc/homelab/source/k8s/05-vaultwarden.yaml
   ```

## 8) Kopia: local encrypted repo + R2 replication
Required values in `/etc/homelab/secrets.env`:
- `KOPIA_REPOSITORY_PASSWORD` (must match k8s secret)
- `KOPIA_R2_ACCESS_KEY_ID`
- `KOPIA_R2_SECRET_ACCESS_KEY`
- `KOPIA_R2_BUCKET`
- `KOPIA_R2_ENDPOINT` (format: `https://<accountid>.r2.cloudflarestorage.com`)

Security note:
- `/etc/homelab/source/k8s/03-kopia.yaml` uses `--insecure` and `--disable-csrf-token-checks`.
- Keep `kopia.aza.network` behind Cloudflare Access.

Timers are declarative (`kopia-host-backup.timer`, `kopia-r2-sync.timer`).
Run once immediately if needed:
```bash
sudo systemctl start kopia-host-backup.service
sudo systemctl start kopia-r2-sync.service
```

## 9) MacBook backup via Access
On macOS:
```bash
brew install cloudflared kopia
```

Start authenticated local tunnel:
```bash
cloudflared access tcp --hostname kopia.aza.network --url localhost:15151
```

In another terminal:
```bash
kopia repository connect server \
  --url=http://127.0.0.1:15151 \
  --override-hostname=kopia.aza.network \
  --server-username=<KOPIA_SERVER_USERNAME> \
  --server-password=<KOPIA_SERVER_PASSWORD>
```

Create snapshots:
```bash
kopia snapshot create ~/Documents ~/Pictures ~/Desktop
```

## 10) Verification
Run:
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
sudo journalctl -u kopia-host-backup.service -n 100 --no-pager
sudo journalctl -u kopia-r2-sync.service -n 100 --no-pager
```
