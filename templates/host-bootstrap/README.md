Copy `flake.nix` from this folder into `/etc/nixos/flake.nix` on the host.

Then:
1. Replace `github:YOUR_GITHUB_OWNER/YOUR_REPO` with your real repo.
2. Set the hostname in `flake.nix` by updating both:
   - `nixosConfigurations.<name>`
   - `networking.hostName = "<name>";`
   Use `azalab-0`, `azalab-1`, `azalab-2`, etc.
3. Pin inputs in `/etc/nixos` (use a commit SHA for `YOUR_COMMIT_SHA`):
   - `sudo nix flake lock --override-input homelab "github:YOUR_GITHUB_OWNER/YOUR_REPO?rev=YOUR_COMMIT_SHA"`
4. Rebuild with `sudo nixos-rebuild switch --flake /etc/nixos#azalab-0`.
