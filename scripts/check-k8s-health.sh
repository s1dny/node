#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${KUBECONFIG:-}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

failures=0

run_check() {
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

check_rollouts_for_kind() {
  local namespace="$1"
  local kind="$2"
  local names

  names="$(kubectl -n "${namespace}" get "${kind}" -o name 2>/dev/null || true)"
  if [[ -z "${names}" ]]; then
    return
  fi

  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    run_check "${namespace} ${name} rollout" kubectl -n "${namespace}" rollout status "${name}" --timeout=10m
  done <<< "${names}"
}

run_check "All nodes are Ready" kubectl wait --for=condition=Ready nodes --all --timeout=2m

if kubectl get namespace flux-system >/dev/null 2>&1; then
  run_check "Flux source is Ready" kubectl -n flux-system wait --for=condition=Ready gitrepository/flux-system --timeout=5m

  for kustomization in flux-system infrastructure apps; do
    run_check "Flux kustomization ${kustomization} is Ready" \
      kubectl -n flux-system wait --for=condition=Ready "kustomization/${kustomization}" --timeout=10m
  done
fi

for namespace in libsql backup immich vaultwarden tuwunel; do
  check_rollouts_for_kind "${namespace}" deployment
  check_rollouts_for_kind "${namespace}" statefulset
done

kubectl get pods -A
kubectl get ingress -A
kubectl get pvc -A

if (( failures > 0 )); then
  exit 1
fi
