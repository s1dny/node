#!/usr/bin/env bash
set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-15151}"

exec cloudflared access tcp \
  --hostname kopia.aza.network \
  --url "localhost:${LOCAL_PORT}"
