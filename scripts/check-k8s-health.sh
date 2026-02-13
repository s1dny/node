#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

failures=0

check_cmd() {
  local description="$1"
  shift

  echo "==> ${description}"
  if "$@"; then
    echo "ok"
  else
    echo "failed: ${description}" >&2
    failures=$((failures + 1))
  fi
  echo
}

check_endpoint() {
  local namespace="$1"
  local service="$2"

  echo "==> Endpoint check ${namespace}/${service}"
  local addresses
  addresses="$(kubectl -n "${namespace}" get endpoints "${service}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  if [[ -n "${addresses}" ]]; then
    echo "ok (${addresses})"
  else
    echo "failed: no ready endpoints for ${namespace}/${service}" >&2
    failures=$((failures + 1))
  fi
  echo
}

check_cmd "All nodes are Ready" kubectl wait --for=condition=Ready nodes --all --timeout=2m

check_cmd "libsql rollout" kubectl -n libsql rollout status deployment/libsql --timeout=5m
check_cmd "kopia rollout" kubectl -n backup rollout status deployment/kopia-repository-server --timeout=5m
check_cmd "vaultwarden rollout" kubectl -n vaultwarden rollout status deployment/vaultwarden --timeout=5m
check_cmd "immich-postgres rollout" kubectl -n immich rollout status statefulset/immich-postgres --timeout=5m
check_cmd "immich pods ready" kubectl -n immich wait --for=condition=Ready pod -l app.kubernetes.io/instance=immich --timeout=10m

check_endpoint "libsql" "libsql"
check_endpoint "backup" "kopia-repository-server"
check_endpoint "vaultwarden" "vaultwarden"
check_endpoint "immich" "immich-postgres"
check_endpoint "immich" "immich-valkey"
check_endpoint "immich" "immich-server"

echo "==> Snapshot"
kubectl get pods -A
kubectl get ingress -A
kubectl get pvc -A
echo

if (( failures > 0 )); then
  echo "health check result: FAILED (${failures} checks)" >&2
  exit 1
fi

echo "health check result: PASS"
