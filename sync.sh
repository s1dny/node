#!/usr/bin/env bash
set -euo pipefail

cd /etc/nixos
sudo nix flake update homelab
sudo nixos-rebuild switch --flake "/etc/nixos#$(hostname -s)"
