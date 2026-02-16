#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_DIR="${HOMELAB_STATIC_DIR:-${ROOT_DIR}}"
FLUX_CLUSTER_PATH="${HOMELAB_FLUX_CLUSTER_PATH:-${STATIC_DIR}/flux/clusters/azalab-0}"
FLUX_INSTALL_MANIFEST_URL="${HOMELAB_FLUX_INSTALL_MANIFEST_URL:-https://github.com/fluxcd/flux2/releases/latest/download/install.yaml}"

# Default to k3s kubeconfig on host systems if caller did not set one.
if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

if [[ ! -f "${FLUX_CLUSTER_PATH}/flux-system-sync.yaml" ]]; then
  echo "error: missing Flux cluster sync file: ${FLUX_CLUSTER_PATH}/flux-system-sync.yaml" >&2
  exit 1
fi

if ! kubectl -n flux-system get deployment/source-controller >/dev/null 2>&1; then
  kubectl apply -f "${FLUX_INSTALL_MANIFEST_URL}"
fi

kubectl -n flux-system rollout status deployment/source-controller --timeout=5m
kubectl -n flux-system rollout status deployment/kustomize-controller --timeout=5m
kubectl -n flux-system rollout status deployment/helm-controller --timeout=5m

"${STATIC_DIR}/scripts/sync-k8s-secrets.sh"

wait_for_flux_kustomization() {
  local name="$1"
  local timeout="$2"

  for _ in {1..30}; do
    if kubectl -n flux-system get "kustomization/${name}" >/dev/null 2>&1; then
      kubectl -n flux-system wait "kustomization/${name}" --for=condition=Ready=True --timeout="${timeout}"
      return 0
    fi
    sleep 2
  done

  echo "error: kustomization/${name} was not created in flux-system namespace" >&2
  return 1
}

kubectl apply -f "${FLUX_CLUSTER_PATH}/flux-system-sync.yaml"
wait_for_flux_kustomization "flux-system" "5m"
wait_for_flux_kustomization "infrastructure" "10m"
wait_for_flux_kustomization "apps" "15m"

echo
echo "Flux GitOps reconciliation is active."
echo "Run to verify:"
echo "  ${STATIC_DIR}/scripts/check-k8s-health.sh"
