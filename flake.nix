{
  description = "Local Slinky Rapid Prototype Environment";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        tools = with pkgs; [
          kind
          kubectl
          kubernetes-helm
          go
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = tools;
          shellHook = ''
            echo "🚀 Slinky Prototype Shell Initialized"
            # Function to boot cluster AND install Slinky
            kup() {
              echo "Creating Kubernetes cluster..."
              kind create cluster --config kind-config.yaml
              echo "Waiting for cluster to be ready..."
              kubectl wait --for=condition=Ready nodes --all --timeout=60s
              echo "Running Slinky installation script..."
              ./scripts/start-slinky.sh
            }
            # Export the function so it is available in subshells
            export -f kup
            # Simple aliases
            alias kdown="kind delete cluster"
            alias kstat="kubectl get pods -n slurm"
            alias slurm-shell="kubectl exec -it slurm-controller-0 -n slurm -- bash"
            echo "✅ Aliases loaded: kup, kdown, kstat, slurm-shell"

            export SHELL=/home/khemi/.nix-profile/bin/zsh
            exec /home/khemi/.nix-profile/bin/zsh
          '';
        };
      }
    );
}
