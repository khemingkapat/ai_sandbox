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

        # Define commands as binary scripts on the PATH
        kup = pkgs.writeShellScriptBin "kup" ''
          echo "Creating Kubernetes cluster..."
          kind create cluster --config k8s/kind-config.yaml
          echo "Waiting for cluster to be ready..."
          kubectl wait --for=condition=Ready nodes --all --timeout=60s
          echo "Running Slinky installation script..."
          ./scripts/start-slinky.sh
        '';
        kdown = pkgs.writeShellScriptBin "kdown" ''
          exec kind delete cluster "$@"
        '';
        kstat = pkgs.writeShellScriptBin "kstat" ''
          echo "=== Slurm Namespace ==="
          kubectl get pods -n slurm "$@"
          if kubectl get ns workload &>/dev/null; then
            echo ""
            echo "=== Workload Namespace ==="
            kubectl get pods -n workload "$@" 2>/dev/null || echo "  (no pods)"
          fi
        '';
        slurm-shell = pkgs.writeShellScriptBin "slurm-shell" ''
          exec kubectl exec -it slurm-controller-0 -n slurm -- bash "$@"
        '';

        # SSH tunnel to Proxmox Kubernetes API (port 6443 via port-forward over SSH)
        ptunnel = pkgs.writeShellScriptBin "ptunnel" ''
          TUNNEL_PID=$(pgrep -f "ssh.*-L 6443" || true)
          if [ -n "$TUNNEL_PID" ]; then
            echo "⚠️  Tunnel already running (PID: $TUNNEL_PID). Run ptunnel-stop first to restart."
            exit 0
          fi
          echo "🔌 Starting SSH tunnel: localhost:6443 → ai-control:6443"
          ssh -f -N -L 6443:127.0.0.1:6443 admin_ai@10.35.123.50
          sleep 1
          NEW_PID=$(pgrep -f "ssh.*-L 6443" || true)
          if [ -n "$NEW_PID" ]; then
            echo "✅ Tunnel established (PID: $NEW_PID). kubectl is now pointing at Proxmox k3s."
          else
            echo "❌ Tunnel failed to start. Check SSH access to 10.35.123.50."
            exit 1
          fi
        '';

        ptunnel-stop = pkgs.writeShellScriptBin "ptunnel-stop" ''
          TUNNEL_PID=$(pgrep -f "ssh.*-L 6443" || true)
          if [ -z "$TUNNEL_PID" ]; then
            echo "ℹ️  No active tunnel found."
          else
            kill "$TUNNEL_PID"
            echo "🔌 Tunnel (PID: $TUNNEL_PID) stopped."
          fi
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
          ptunnel
          ptunnel-stop
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = tools;
          shellHook = ''
            	    echo "🚀 Slinky Prototype Shell Initialized"
                        echo "✅ Commands loaded: kup, kdown, kstat, slurm-shell"
                        echo "🔌 Proxmox tunnel: ptunnel (start) | ptunnel-stop (kill)"

                        export SHELL=/home/khemi/.nix-profile/bin/zsh
                        export KUBECONFIG="$HOME/.kube/config-proxmox"
                        exec /home/khemi/.nix-profile/bin/zsh
          '';
        };
      }
    );
}
