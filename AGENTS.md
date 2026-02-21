# AGENTS

## Overview

NixOS homelab infrastructure for a Dell Optiplex 7060 (`azalab-0`) running k3s. The repo is a Nix flake that provides a NixOS module (`nixosModules.default`) consumed by a host bootstrap flake on the server at `/etc/nixos/flake.nix`. The repo is never cloned on the host — NixOS pins it via `flake.lock` and mounts the pinned source read-only at `/etc/homelab/source`.

## Architecture

```
flake.nix                       # Flake entry — exports nixosModules.default
├── nixos/
│   ├── homelab-module.nix      # Core NixOS module (all host config)
│   ├── disko.nix               # Disk partitioning layout
│   ├── configuration.nix       # Minimal wrapper importing homelab-module
│   ├── flake.nix               # Host-side bootstrap flake (reference copy)
│   └── secrets/
│       └── host-secrets.sops.yaml  # SOPS-encrypted host secrets (age)
├── flux/clusters/azalab-0/     # Flux GitOps for k3s cluster
│   ├── flux-system-sync.yaml   # Git source + root Kustomization
│   ├── infrastructure.yaml     # Cluster resources (namespaces, PVs)
│   ├── apps.yaml               # App Kustomization (depends on infra)
│   └── manifests/
│       ├── cluster/            # Namespaces, PersistentVolumes
│       └── apps/               # Per-app K8s manifests + SOPS secrets
│           ├── secrets.sops.yaml
│           ├── libsql/
│           ├── immich/
│           ├── kopia/
│           ├── vaultwarden/
│           ├── tuwunel/
│           └── zeroclaw/
├── scripts/                    # Backup automation (run by systemd)
├── macbook/                    # Client-side backup scripts
└── templates/host-bootstrap/   # Template for new host /etc/nixos flake
```

## Deployment
The flow is push git changes to `main` -> Flux auto-syncs K8s manifests (1m interval). NixOS host config requires manual `sudo nix flake update homelab && sudo nixos-rebuild switch --flake /etc/nixos#$(hostname -s)`.

## Key Technical Details

- **Secrets management**: SOPS with age encryption. Two creation rules in `.sops.yaml`: one for host secrets (`nixos/secrets/`), one for K8s secrets (`flux/clusters/*/manifests/apps/`). Both use the same age recipient. The age private key lives at `/var/lib/sops-nix/key.txt` on the host and is also provisioned as a K8s secret (`flux-system/sops-age`) for Flux decryption.
- **K8s services**: libsql (db.aza.network), Immich (photos.aza.network), Kopia (kopia.aza.network), Vaultwarden (vault.aza.network), Tuwunel/Matrix (matrix.aza.network), ZeroClaw (Matrix AI bot).
- **Networking**: All external access via Cloudflare Tunnel (no open ingress ports). Firewall allows only SSH (22) and k3s API (6443).
- **Backups**: Kopia host backup at 2:30 AM daily → R2 sync every 6 hours. Sources: `/srv/libsql`, `/srv/immich`, `/srv/vaultwarden`, `/srv/tuwunel`, `/etc/nixos`.
- **Storage**: All persistent data under `/srv/`. PersistentVolumes are `hostPath`-backed, defined in `flux/clusters/azalab-0/manifests/cluster/persistent-volumes.yaml`.
- **Default user**: `aiden`, groups: wheel/networkmanager/docker, shell: fish, SSH key-only auth.
- **NixOS version**: 25.11 (pinned in host flake.lock). Flake input: `sops-nix`.

## Policy
- Execute tasks end-to-end by default. Do not ask the user to run commands you can run yourself.
- Ask the user to do something only when truly blocked by one of these:
  - Interactive authentication the agent cannot complete (for example, sudo password prompts).
  - Missing secret values or credentials the agent cannot infer.
  - Explicit user approval required for destructive or out-of-sandbox actions.
- If blocked by permissions, attempt the command and then request escalation/approval; do not hand the task back to the user as a first response.
- Report actions taken and results.