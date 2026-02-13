#!/usr/bin/env bash
set -euo pipefail

: "${KOPIA_REPOSITORY_PASSWORD:?KOPIA_REPOSITORY_PASSWORD is required}"

export KOPIA_CONFIG_PATH="${KOPIA_CONFIG_PATH:-/var/lib/kopia/host.config}"

if ! kopia repository status >/dev/null 2>&1; then
  kopia repository connect filesystem \
    --path /srv/kopia/repository \
    --password "${KOPIA_REPOSITORY_PASSWORD}"
fi

kopia policy set --global \
  --keep-latest 30 \
  --keep-daily 30 \
  --keep-weekly 12 \
  --keep-monthly 12

# Backup full service directories (excluding /srv/kopia to avoid backing up the backup repository itself).
SOURCES=(/etc/nixos /srv/libsql /srv/immich /srv/vaultwarden)
if [[ -n "${KOPIA_HOST_SOURCES:-}" ]]; then
  # shellcheck disable=SC2206
  SOURCES=(${KOPIA_HOST_SOURCES})
fi

kopia snapshot create "${SOURCES[@]}" --parallel=8
