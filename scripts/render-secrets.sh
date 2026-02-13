#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_ENV_PATH="${1:-${ROOT_DIR}/secrets/homelab-secrets.env}"

if [[ ! -r "${SECRETS_ENV_PATH}" ]]; then
  echo "error: missing secrets env file: ${SECRETS_ENV_PATH}" >&2
  echo "hint: copy ${ROOT_DIR}/secrets/homelab-secrets.env.example to ${ROOT_DIR}/secrets/homelab-secrets.env and fill it in" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${SECRETS_ENV_PATH}"
set +a

required_vars=(
  CLOUDFLARE_TUNNEL_TOKEN
  SQLD_AUTH_JWT_KEY
  KOPIA_REPOSITORY_PASSWORD
  KOPIA_SERVER_USERNAME
  KOPIA_SERVER_PASSWORD
  KOPIA_R2_ACCESS_KEY_ID
  KOPIA_R2_SECRET_ACCESS_KEY
  KOPIA_R2_BUCKET
  KOPIA_R2_ENDPOINT
  IMMICH_DB_POSTGRES_PASSWORD
  IMMICH_DB_PASSWORD
  IMMICH_DB_REPLICATION_PASSWORD
  IMMICH_REDIS_PASSWORD
  VAULTWARDEN_ADMIN_TOKEN
)

missing_vars=()
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    missing_vars+=("${v}")
  fi
done

if [[ "${#missing_vars[@]}" -gt 0 ]]; then
  echo "error: missing required variables in ${SECRETS_ENV_PATH}:" >&2
  printf '  - %s\n' "${missing_vars[@]}" >&2
  exit 1
fi

placeholder_vars=()
for v in "${required_vars[@]}"; do
  if [[ "${!v}" =~ REPLACE_WITH|REPLACE_ME|CHANGE_ME ]]; then
    placeholder_vars+=("${v}")
  fi
done

if [[ "${#placeholder_vars[@]}" -gt 0 ]]; then
  echo "error: unresolved placeholder values in ${SECRETS_ENV_PATH}:" >&2
  printf '  - %s\n' "${placeholder_vars[@]}" >&2
  exit 1
fi

yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "${s}"
}

write_secret_file() {
  local path="$1"
  umask 077
  cat >"${path}"
  chmod 0600 "${path}"
}

mkdir -p "${ROOT_DIR}/k8s/secrets"
mkdir -p "${ROOT_DIR}/scripts"
mkdir -p "${ROOT_DIR}/cloudflare"

write_secret_file "${ROOT_DIR}/k8s/secrets/libsql-auth.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: libsql-auth
  namespace: libsql
type: Opaque
stringData:
  SQLD_AUTH_JWT_KEY: "$(yaml_escape "${SQLD_AUTH_JWT_KEY}")"
EOF

write_secret_file "${ROOT_DIR}/k8s/secrets/kopia-auth.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kopia-auth
  namespace: backup
type: Opaque
stringData:
  KOPIA_REPOSITORY_PASSWORD: "$(yaml_escape "${KOPIA_REPOSITORY_PASSWORD}")"
  KOPIA_SERVER_USERNAME: "$(yaml_escape "${KOPIA_SERVER_USERNAME}")"
  KOPIA_SERVER_PASSWORD: "$(yaml_escape "${KOPIA_SERVER_PASSWORD}")"
EOF

write_secret_file "${ROOT_DIR}/k8s/secrets/immich-db-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: immich-db-secret
  namespace: immich
type: Opaque
stringData:
  postgres-password: "$(yaml_escape "${IMMICH_DB_POSTGRES_PASSWORD}")"
  password: "$(yaml_escape "${IMMICH_DB_PASSWORD}")"
  replication-password: "$(yaml_escape "${IMMICH_DB_REPLICATION_PASSWORD}")"
EOF

write_secret_file "${ROOT_DIR}/k8s/secrets/immich-redis-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: immich-redis-secret
  namespace: immich
type: Opaque
stringData:
  password: "$(yaml_escape "${IMMICH_REDIS_PASSWORD}")"
EOF

write_secret_file "${ROOT_DIR}/k8s/secrets/vaultwarden-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vaultwarden-secret
  namespace: vaultwarden
type: Opaque
stringData:
  ADMIN_TOKEN: "$(yaml_escape "${VAULTWARDEN_ADMIN_TOKEN}")"
EOF

write_secret_file "${ROOT_DIR}/scripts/kopia.env" <<EOF
KOPIA_REPOSITORY_PASSWORD=${KOPIA_REPOSITORY_PASSWORD}
KOPIA_R2_ACCESS_KEY_ID=${KOPIA_R2_ACCESS_KEY_ID}
KOPIA_R2_SECRET_ACCESS_KEY=${KOPIA_R2_SECRET_ACCESS_KEY}
KOPIA_R2_BUCKET=${KOPIA_R2_BUCKET}
KOPIA_R2_ENDPOINT=${KOPIA_R2_ENDPOINT}
EOF

write_secret_file "${ROOT_DIR}/cloudflare/tunnel-token.env" <<EOF
CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
EOF

echo "rendered:"
echo "  - k8s/secrets/*.yaml"
echo "  - scripts/kopia.env"
echo "  - cloudflare/tunnel-token.env"
