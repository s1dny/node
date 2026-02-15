#!/usr/bin/env bash
set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-15151}"
KOPIA_SERVER_HOSTNAME="${KOPIA_SERVER_HOSTNAME:-kopia.aza.network}"

exec cloudflared access tcp \
  --hostname "${KOPIA_SERVER_HOSTNAME}" \
  --url "localhost:${LOCAL_PORT}"
