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
- `/etc/homelab/source/flux/clusters/azalab-0/manifests/apps/<app>/`: app manifests and per-app k8s secret templates
- `/etc/homelab/source/flux/clusters/azalab-0/`: Flux cluster reconciliation entrypoint
- `/etc/homelab/cloudflare/tunnel-token.env`: Cloudflare dashboard tunnel token
- `/etc/homelab/host-secrets/kopia-r2.env`: host Kopia-to-R2 sync credentials
- `/etc/homelab/k8s-secrets/*.env`: per-secret Kubernetes env files used with explicit `kubectl create secret` commands

## Prerequisites
- Domain in Cloudflare: `aza.network`
- Cloudflare Zero Trust account
- Dashboard-managed Cloudflare Tunnel token
- NixOS installer USB
- Console/KVM access for first boot (SSH key auth is enforced)

## 1) Install NixOS (fresh machine)
1. Boot NixOS installer. Make sure you have network (Ethernet should auto-connect).
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
6. From your local machine (in the root of your clone of this repo), create host/service secrets and per-secret k8s env files:
   ```bash
   mkdir -p nixos/secrets/live
   cp cloudflare/tunnel-token.env.example nixos/secrets/live/tunnel-token.env
   cp nixos/secrets/kopia-r2.env.example nixos/secrets/live/kopia-r2.env
   vi nixos/secrets/live/*.env

   mkdir -p flux/live
   for f in flux/clusters/azalab-0/manifests/apps/*/*.env.example; do cp "$f" "flux/live/$(basename "${f%.example}")"; done
   vi flux/live/*.env

   scp nixos/secrets/live/*.env aiden@<IP>:/tmp/
   scp flux/live/*.env aiden@<IP>:/tmp/
   ```
7. On the server, install secrets and rebuild:
   ```bash
   sudo install -d -m 0750 -o root -g wheel /etc/homelab/cloudflare
   sudo mv /tmp/tunnel-token.env /etc/homelab/cloudflare/tunnel-token.env
   sudo chmod 0640 /etc/homelab/cloudflare/tunnel-token.env
   sudo chgrp wheel /etc/homelab/cloudflare/tunnel-token.env

   sudo install -d -m 0750 -o root -g wheel /etc/homelab/host-secrets
   sudo mv /tmp/kopia-r2.env /etc/homelab/host-secrets/kopia-r2.env
   sudo chmod 0640 /etc/homelab/host-secrets/kopia-r2.env
   sudo chgrp wheel /etc/homelab/host-secrets/kopia-r2.env

   sudo install -d -m 0750 -o root -g wheel /etc/homelab/k8s-secrets
   for f in libsql-auth kopia-auth immich-db-secret immich-redis-secret vaultwarden-secret tuwunel-secret; do sudo mv "/tmp/${f}.env" "/etc/homelab/k8s-secrets/${f}.env"; done
   sudo chmod 0640 /etc/homelab/k8s-secrets/*.env
   sudo chgrp wheel /etc/homelab/k8s-secrets/*.env
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

Put the token in `/etc/homelab/cloudflare/tunnel-token.env` as `CLOUDFLARE_TUNNEL_TOKEN` and rebuild.

## 4) Bootstrap Flux, apply secrets, and reconcile workloads
```bash
kubectl get nodes
kubectl apply -f https://github.com/fluxcd/flux2/releases/download/v2.6.4/install.yaml
kubectl -n flux-system rollout status deployment/source-controller --timeout=5m
kubectl -n flux-system rollout status deployment/kustomize-controller --timeout=5m
kubectl -n flux-system rollout status deployment/helm-controller --timeout=5m

kubectl apply -f /etc/homelab/source/flux/clusters/azalab-0/manifests/cluster/namespaces.yaml
kubectl -n libsql create secret generic libsql-auth --from-env-file=/etc/homelab/k8s-secrets/libsql-auth.env --dry-run=client -o yaml | kubectl apply -f -
kubectl -n backup create secret generic kopia-auth --from-env-file=/etc/homelab/k8s-secrets/kopia-auth.env --dry-run=client -o yaml | kubectl apply -f -
kubectl -n immich create secret generic immich-db-secret --from-env-file=/etc/homelab/k8s-secrets/immich-db-secret.env --dry-run=client -o yaml | kubectl apply -f -
if [ -r /etc/homelab/k8s-secrets/immich-redis-secret.env ]; then kubectl -n immich create secret generic immich-redis-secret --from-env-file=/etc/homelab/k8s-secrets/immich-redis-secret.env --dry-run=client -o yaml | kubectl apply -f -; fi
kubectl -n vaultwarden create secret generic vaultwarden-secret --from-env-file=/etc/homelab/k8s-secrets/vaultwarden-secret.env --dry-run=client -o yaml | kubectl apply -f -
kubectl -n tuwunel create secret generic tuwunel-secret --from-env-file=/etc/homelab/k8s-secrets/tuwunel-secret.env --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f /etc/homelab/source/flux/clusters/azalab-0/flux-system-sync.yaml
kubectl -n flux-system wait --for=condition=Ready=True kustomization/flux-system --timeout=5m
kubectl -n flux-system wait --for=condition=Ready=True kustomization/infrastructure --timeout=10m
kubectl -n flux-system wait --for=condition=Ready=True kustomization/apps --timeout=10m
homelab-check-k8s-health
```

If you fork this repo, update `flux/clusters/azalab-0/flux-system-sync.yaml` so `spec.url` and `spec.ref.branch` point at your Git remote and branch.

## 5) Cloudflare Access policies
Put `photos.aza.network` and `kopia.aza.network` behind Cloudflare Access. Don't put `vault.aza.network` behind it if you need native Bitwarden clients.

## 6) Vaultwarden setup
1. Create first account at `https://vault.aza.network`.
2. Sign into admin at `https://vault.aza.network/admin` using `ADMIN_TOKEN` from `/etc/homelab/k8s-secrets/vaultwarden-secret.env`.
3. Disable public registrations:
   ```bash
   kubectl -n vaultwarden set env deployment/vaultwarden SIGNUPS_ALLOWED="false"
   ```
   Then commit the same change to `flux/clusters/azalab-0/manifests/apps/vaultwarden/manifest.yaml` in Git so it persists across rebuilds.

## 7) Tuwunel (Matrix homeserver)
1. After deploy, verify it's running:
   ```bash
   kubectl -n tuwunel get pods
   curl -s https://matrix.aza.network/_matrix/client/versions
   ```
2. Registration is token-gated by default (`TUWUNEL_ALLOW_REGISTRATION=true` + `TUWUNEL_REGISTRATION_TOKEN`).
3. Set `TUWUNEL_REGISTRATION_TOKEN` in `/etc/homelab/k8s-secrets/tuwunel-secret.env`, then run:
   ```bash
   kubectl -n tuwunel create secret generic tuwunel-secret --from-env-file=/etc/homelab/k8s-secrets/tuwunel-secret.env --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n tuwunel rollout restart deployment/tuwunel
   ```
4. Register users in your Matrix client (e.g. Element) using that token.

## 8) Kopia backups
`flux/clusters/azalab-0/manifests/apps/kopia/manifest.yaml` uses `--insecure` and `--disable-csrf-token-checks`. Keep `kopia.aza.network` behind Cloudflare Access.

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
kubectl -n flux-system get gitrepositories,kustomizations
kubectl -n immich get helmreleases
kubectl -n libsql get ingress,svc,pods
kubectl -n immich get ingress,svc,pods
kubectl -n backup get ingress,svc,pods
kubectl -n vaultwarden get ingress,svc,pods
kubectl -n tuwunel get ingress,svc,pods
sudo journalctl -u kopia-host-backup.service -n 100 --no-pager
sudo journalctl -u kopia-r2-sync.service -n 100 --no-pager
```
