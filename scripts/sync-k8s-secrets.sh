#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_DIR="${HOMELAB_STATIC_DIR:-${ROOT_DIR}}"
K8S_SECRET_ENV_DIR="${HOMELAB_K8S_SECRET_ENV_DIR:-/etc/homelab/k8s-secrets}"

if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

kubectl apply -f "${STATIC_DIR}/k8s/cluster/namespaces.yaml"

apply_secret() {
  local namespace="$1"
  local name="$2"
  local env_file="$3"
  local required="$4"

  if [[ ! -r "${env_file}" ]]; then
    if [[ "${required}" == "true" ]]; then
      echo "error: missing secret env file ${env_file}" >&2
      return 1
    fi
    echo "warning: optional secret env file missing, skipping: ${env_file}" >&2
    return 0
  fi

  kubectl -n "${namespace}" create secret generic "${name}" \
    --from-env-file="${env_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

apply_secret "libsql" "libsql-auth" "${K8S_SECRET_ENV_DIR}/libsql-auth.env" true
apply_secret "backup" "kopia-auth" "${K8S_SECRET_ENV_DIR}/kopia-auth.env" true
apply_secret "immich" "immich-db-secret" "${K8S_SECRET_ENV_DIR}/immich-db-secret.env" true
apply_secret "immich" "immich-redis-secret" "${K8S_SECRET_ENV_DIR}/immich-redis-secret.env" false
apply_secret "vaultwarden" "vaultwarden-secret" "${K8S_SECRET_ENV_DIR}/vaultwarden-secret.env" true
apply_secret "tuwunel" "tuwunel-secret" "${K8S_SECRET_ENV_DIR}/tuwunel-secret.env" true
