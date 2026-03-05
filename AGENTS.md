# AGENTS

## Overview

NixOS homelab infrastructure for a Dell Optiplex 7060 (`azalab-0`) running k3s. The repo is a Nix flake that provides a NixOS module (`nixosModules.default`) consumed by a host bootstrap flake on the server at `/etc/nixos/flake.nix`. The repo is never cloned on the host — NixOS pins it via `flake.lock` and mounts the pinned source read-only at `/etc/homelab/source`.

## Deployment
The flow is push git changes to `main` -> Flux auto-syncs K8s manifests (1m interval). NixOS host config requires manual `sudo nix flake update homelab && sudo nixos-rebuild switch --flake /etc/nixos#$(hostname -s)`.

## Policy
- Execute tasks end-to-end by default. Do not ask the user to run commands you can run yourself.
- Ask the user to do something only when truly blocked by one of these:
  - Interactive authentication the agent cannot complete (for example, sudo password prompts).
  - Missing secret values or credentials the agent cannot infer.
  - Explicit user approval required for destructive or out-of-sandbox actions.
- If blocked by permissions, attempt the command and then request escalation/approval; do not hand the task back to the user as a first response.
- Report actions taken and results.