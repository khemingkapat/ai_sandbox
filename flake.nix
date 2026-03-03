{
  description = "HPC Toolkit Local Simulation Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11"; # Stable version
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
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.python3
            pkgs.uv
            pkgs.pyright
            pkgs.black
          ];

          shellHook = ''
                        export UV_PYTHON_DOWNLOADS=never
            	    export DOCKER_DEFAULT_PLATFORM=linux/arm64
                        echo "--- HPC Local Simulation Shell ---"
                        echo "Tools available: docker-compose, uv, python3"
                        echo "Run 'docker-compose up -d' to start your local cluster."
          '';
        };
      }
    );
}
