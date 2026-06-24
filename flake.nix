{
  description = "Local Slinky Rapid Prototype Environment";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    { self
    , nixpkgs
    , flake-utils
    ,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Define commands as binary scripts on the PATH
        kup = pkgs.writeShellScriptBin "kup" ''
          echo "Creating Kubernetes cluster..."
          kind create cluster --config kind-config.yaml
          echo "Waiting for cluster to be ready..."
          kubectl wait --for=condition=Ready nodes --all --timeout=60s
          echo "Running Slinky installation script..."
          ./scripts/start-slinky.sh
        '';
        kdown = pkgs.writeShellScriptBin "kdown" ''
          exec kind delete cluster "$@"
        '';
        kstat = pkgs.writeShellScriptBin "kstat" ''
          exec kubectl get pods -n slurm "$@"
        '';
        slurm-shell = pkgs.writeShellScriptBin "slurm-shell" ''
          exec kubectl exec -it slurm-controller-0 -n slurm -- bash "$@"
        '';

        tools = with pkgs; [
          kind
          kubectl
          kubernetes-helm
          go
          kup
          kdown
          kstat
          slurm-shell
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = tools;
          shellHook = ''
            echo "🚀 Slinky Prototype Shell Initialized"
            echo "✅ Commands loaded: kup, kdown, kstat, slurm-shell"

            export SHELL=/home/khemi/.nix-profile/bin/zsh
            exec /home/khemi/.nix-profile/bin/zsh
          '';
        };
      }
    );
}
