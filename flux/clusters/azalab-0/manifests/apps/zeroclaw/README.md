# ZeroClaw (Matrix bot)

This deployment runs ZeroClaw in a Kubernetes container as a Matrix bot using:

- runtime image: `rust:1.93-slim`
- bootstrap: init container builds `zeroclaw` from source into `/zeroclaw-data/bin/zeroclaw`
- command: `zeroclaw channel start`
- config secret: `zeroclaw-config` (key: `config.toml`)
- persistent data: `zeroclaw-data-pvc` mounted at `/zeroclaw-data`

## 1) Prepare config

Start from:

`flux/clusters/azalab-0/manifests/apps/zeroclaw/zeroclaw-config.toml.example`

Set:

- `api_key`
- `[channels_config.matrix].access_token`
- `[channels_config.matrix].room_id`
- `[channels_config.matrix].allowed_users`

Note: current upstream Zeroclaw sets OpenRouter model IDs but does not expose OpenRouter's `provider` request field. Endpoint pinning to a specific provider is not hard-enforced from this config alone.

## 2) Update secret in Git (SOPS)

```bash
sops edit flux/clusters/azalab-0/manifests/apps/zeroclaw/secret.sops.yaml
```

`zeroclaw-config` is reconciled by Flux from `secret.sops.yaml`.

## 3) Apply manifests / reconcile

```bash
ssh aiden@azalab-0 'kubectl apply -f /etc/homelab/source/flux/clusters/azalab-0/manifests/cluster/namespaces.yaml'
ssh aiden@azalab-0 'kubectl apply -f /etc/homelab/source/flux/clusters/azalab-0/manifests/cluster/persistent-volumes.yaml'
ssh aiden@azalab-0 'kubectl apply -f /etc/homelab/source/flux/clusters/azalab-0/manifests/apps/zeroclaw/manifest.yaml'
ssh aiden@azalab-0 'kubectl -n flux-system reconcile source git flux-system'
ssh aiden@azalab-0 'kubectl -n flux-system reconcile kustomization apps --with-source'
```
