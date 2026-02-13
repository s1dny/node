#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_DIR="${HOMELAB_STATIC_DIR:-${ROOT_DIR}}"
GENERATED_DIR="${HOMELAB_GENERATED_DIR:-/var/lib/homelab/generated}"
K8S_SECRETS_DIR="${HOMELAB_K8S_SECRETS_DIR:-${GENERATED_DIR}/k8s/secrets}"
SECRETS_ENV_PATH="${1:-${HOMELAB_SECRETS_ENV:-${STATIC_DIR}/secrets/homelab-secrets.env}}"

if [[ ! -r "${SECRETS_ENV_PATH}" ]]; then
  echo "error: missing secrets env file: ${SECRETS_ENV_PATH}" >&2
  echo "hint: copy ${STATIC_DIR}/secrets/homelab-secrets.env.example to ${SECRETS_ENV_PATH} and fill it in" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${SECRETS_ENV_PATH}"
set +a

required_vars=(
  SQLD_AUTH_JWT_KEY
  KOPIA_REPOSITORY_PASSWORD
  KOPIA_SERVER_USERNAME
  KOPIA_SERVER_PASSWORD
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
  umask 027
  cat >"${path}"
  chmod 0640 "${path}"
  chgrp wheel "${path}" 2>/dev/null || true
}

mkdir -p "${K8S_SECRETS_DIR}"
chmod 0750 "${K8S_SECRETS_DIR}" 2>/dev/null || true
chgrp wheel "${K8S_SECRETS_DIR}" 2>/dev/null || true

write_secret_file "${K8S_SECRETS_DIR}/libsql-auth.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: libsql-auth
  namespace: libsql
type: Opaque
stringData:
  SQLD_AUTH_JWT_KEY: "$(yaml_escape "${SQLD_AUTH_JWT_KEY}")"
EOF

write_secret_file "${K8S_SECRETS_DIR}/kopia-auth.yaml" <<EOF
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

write_secret_file "${K8S_SECRETS_DIR}/immich-db-secret.yaml" <<EOF
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

write_secret_file "${K8S_SECRETS_DIR}/immich-redis-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: immich-redis-secret
  namespace: immich
type: Opaque
stringData:
  password: "$(yaml_escape "${IMMICH_REDIS_PASSWORD}")"
EOF

write_secret_file "${K8S_SECRETS_DIR}/vaultwarden-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vaultwarden-secret
  namespace: vaultwarden
type: Opaque
stringData:
  ADMIN_TOKEN: "$(yaml_escape "${VAULTWARDEN_ADMIN_TOKEN}")"
EOF

echo "rendered:"
echo "  - ${K8S_SECRETS_DIR}/*.yaml"
