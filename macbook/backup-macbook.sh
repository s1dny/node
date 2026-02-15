#!/usr/bin/env bash
set -euo pipefail

: "${KOPIA_SERVER_USERNAME:?KOPIA_SERVER_USERNAME is required}"
: "${KOPIA_SERVER_PASSWORD:?KOPIA_SERVER_PASSWORD is required}"

LOCAL_PORT="${LOCAL_PORT:-15151}"
KOPIA_SERVER_HOSTNAME="${KOPIA_SERVER_HOSTNAME:-kopia.aza.network}"

if ! kopia repository status >/dev/null 2>&1; then
  kopia repository connect server \
    --url="http://127.0.0.1:${LOCAL_PORT}" \
    --override-hostname="${KOPIA_SERVER_HOSTNAME}" \
    --server-username="${KOPIA_SERVER_USERNAME}" \
    --server-password="${KOPIA_SERVER_PASSWORD}"
fi

kopia policy set --global \
  --keep-latest 14 \
  --keep-daily 30 \
  --keep-weekly 12 \
  --keep-monthly 12

kopia snapshot create "$HOME/Documents" "$HOME/Pictures" "$HOME/Desktop"
