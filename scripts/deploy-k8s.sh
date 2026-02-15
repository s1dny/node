#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_DIR="${HOMELAB_STATIC_DIR:-${ROOT_DIR}}"
GENERATED_DIR="${HOMELAB_GENERATED_DIR:-/var/lib/homelab/generated}"
K8S_SECRETS_DIR="${HOMELAB_K8S_SECRETS_DIR:-${GENERATED_DIR}/k8s/secrets}"
SECRETS_ENV="${HOMELAB_SECRETS_ENV:-/etc/homelab/secrets.env}"
KOPIA_MANIFEST_PATH="${GENERATED_DIR}/k8s/03-kopia.yaml"

# Default to k3s kubeconfig on host systems if caller did not set one.
if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

if [[ -r "${SECRETS_ENV}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${SECRETS_ENV}"
  set +a
  "${STATIC_DIR}/scripts/render-secrets.sh" "${SECRETS_ENV}"
fi

KOPIA_SERVER_HOSTNAME="${KOPIA_SERVER_HOSTNAME:-kopia.aza.network}"

required_secret_files=(
  "${K8S_SECRETS_DIR}/libsql-auth.yaml"
  "${K8S_SECRETS_DIR}/kopia-auth.yaml"
  "${K8S_SECRETS_DIR}/immich-db-secret.yaml"
  "${K8S_SECRETS_DIR}/immich-redis-secret.yaml"
  "${K8S_SECRETS_DIR}/vaultwarden-secret.yaml"
)

for f in "${required_secret_files[@]}"; do
  if [[ ! -r "${f}" ]]; then
    echo "error: missing secret manifest ${f}" >&2
    echo "hint: create ${SECRETS_ENV} then run ${STATIC_DIR}/scripts/render-secrets.sh" >&2
    exit 1
  fi
done

kubectl apply -f "${STATIC_DIR}/k8s/00-namespaces.yaml"
kubectl apply -f "${STATIC_DIR}/k8s/01-persistent-volumes.yaml"
kubectl apply -f "${K8S_SECRETS_DIR}/libsql-auth.yaml"
kubectl apply -f "${K8S_SECRETS_DIR}/kopia-auth.yaml"
kubectl apply -f "${K8S_SECRETS_DIR}/immich-db-secret.yaml"
kubectl apply -f "${K8S_SECRETS_DIR}/immich-redis-secret.yaml"
kubectl apply -f "${K8S_SECRETS_DIR}/vaultwarden-secret.yaml"
kubectl apply -f "${STATIC_DIR}/k8s/02-libsql.yaml"

mkdir -p "$(dirname "${KOPIA_MANIFEST_PATH}")"
sed "s/host: kopia\\.aza\\.network/host: ${KOPIA_SERVER_HOSTNAME}/" \
  "${STATIC_DIR}/k8s/03-kopia.yaml" > "${KOPIA_MANIFEST_PATH}"
kubectl apply -f "${KOPIA_MANIFEST_PATH}"

kubectl apply -f "${STATIC_DIR}/k8s/04-immich-postgres.yaml"
kubectl apply -f "${STATIC_DIR}/k8s/05-vaultwarden.yaml"
kubectl -n immich rollout status statefulset/immich-postgres --timeout=5m

helm upgrade --install immich oci://ghcr.io/immich-app/immich-charts/immich \
  --namespace immich --create-namespace \
  -f "${STATIC_DIR}/k8s/04-immich-values.yaml"

echo
echo "  ${STATIC_DIR}/scripts/check-k8s-health.sh"
