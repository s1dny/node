#!/usr/bin/env bash
set -euo pipefail

: "${KOPIA_REPOSITORY_PASSWORD:?KOPIA_REPOSITORY_PASSWORD is required}"
: "${KOPIA_R2_ACCESS_KEY_ID:?KOPIA_R2_ACCESS_KEY_ID is required}"
: "${KOPIA_R2_SECRET_ACCESS_KEY:?KOPIA_R2_SECRET_ACCESS_KEY is required}"
: "${KOPIA_R2_BUCKET:?KOPIA_R2_BUCKET is required}"
: "${KOPIA_R2_ENDPOINT:?KOPIA_R2_ENDPOINT is required}"

export KOPIA_CONFIG_PATH="${KOPIA_CONFIG_PATH:-/var/lib/kopia/r2-sync.config}"

if ! kopia repository status >/dev/null 2>&1; then
  kopia repository connect filesystem \
    --path /srv/kopia/repository \
    --password "${KOPIA_REPOSITORY_PASSWORD}"
fi

kopia repository sync-to s3 \
  --bucket "${KOPIA_R2_BUCKET}" \
  --endpoint "${KOPIA_R2_ENDPOINT}" \
  --region auto \
  --access-key "${KOPIA_R2_ACCESS_KEY_ID}" \
  --secret-access-key "${KOPIA_R2_SECRET_ACCESS_KEY}"
