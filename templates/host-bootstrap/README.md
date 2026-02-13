Copy `flake.nix` from this folder into `/etc/nixos/flake.nix` on the host.

Then:
1. Replace `github:YOUR_GITHUB_OWNER/YOUR_REPO` with your real repo.
2. Pin inputs in `/etc/nixos` (use a commit SHA for `YOUR_COMMIT_SHA`):
   - `sudo nix flake lock --override-input homelab "github:YOUR_GITHUB_OWNER/YOUR_REPO?rev=YOUR_COMMIT_SHA"`
3. Rebuild with `sudo nixos-rebuild switch --flake /etc/nixos#azalab-0`.
