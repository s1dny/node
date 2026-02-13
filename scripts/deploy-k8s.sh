#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

: "${IMMICH_CHART_VERSION:=0.9.3}"
: "${IMMICH_APP_VERSION:=v1.136.0}"

# Default to k3s kubeconfig on host systems if caller did not set one.
if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

kubectl apply -f "${ROOT_DIR}/k8s/00-namespaces.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/01-persistent-volumes.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/libsql-auth.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/kopia-auth.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/immich-db-secret.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/secrets/immich-redis-secret.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/02-libsql.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/03-kopia.yaml"

sed "s/__IMMICH_APP_VERSION__/${IMMICH_APP_VERSION}/" "${ROOT_DIR}/k8s/04-immich-values.yaml" \
  | helm upgrade --install immich oci://ghcr.io/immich-app/immich-charts/immich \
      --version "${IMMICH_CHART_VERSION}" \
      --namespace immich --create-namespace \
      -f -
