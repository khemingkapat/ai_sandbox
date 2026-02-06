{
  description = "AI Sandbox Demo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
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
            pkgs.python3Packages.jupyterlab
            pkgs.pyright
            pkgs.black
          ];

          shellHook = ''
            export UV_PYTHON_DOWNLOADS=never
            echo "--- Nix-Managed Jupyter Sandbox ---"
            echo "Jupyter is now provided by Nixpkgs (Stable 25.11)"
          '';
        };
      }
    );
}
