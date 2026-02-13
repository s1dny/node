#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Default to k3s kubeconfig on host systems if caller did not set one.
if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

SECRETS_ENV="${ROOT_DIR}/secrets/homelab-secrets.env"
if [[ -r "${SECRETS_ENV}" ]]; then
  "${ROOT_DIR}/scripts/render-secrets.sh" "${SECRETS_ENV}"
fi

required_secret_files=(
  "${ROOT_DIR}/k8s/secrets/libsql-auth.yaml"
  "${ROOT_DIR}/k8s/secrets/kopia-auth.yaml"
  "${ROOT_DIR}/k8s/secrets/immich-db-secret.yaml"
  "${ROOT_DIR}/k8s/secrets/immich-redis-secret.yaml"
  "${ROOT_DIR}/k8s/secrets/vaultwarden-secret.yaml"
)

for f in "${required_secret_files[@]}"; do
  if [[ ! -r "${f}" ]]; then
    echo "error: missing secret manifest ${f}" >&2
    echo "hint: create ${SECRETS_ENV} then run ./scripts/render-secrets.sh" >&2
    exit 1
  fi
done

kubectl apply -f "${ROOT_DIR}/k8s/00-namespaces.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/01-persistent-volumes.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/libsql-auth.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/kopia-auth.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/immich-db-secret.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/immich-redis-secret.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/vaultwarden-secret.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/02-libsql.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/03-kopia.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/04-immich-postgres.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/05-vaultwarden.yaml"
kubectl -n immich rollout status statefulset/immich-postgres --timeout=5m

helm upgrade --install immich oci://ghcr.io/immich-app/immich-charts/immich \
  --namespace immich --create-namespace \
  -f "${ROOT_DIR}/k8s/04-immich-values.yaml"

echo
echo "  ${ROOT_DIR}/scripts/check-k8s-health.sh"
