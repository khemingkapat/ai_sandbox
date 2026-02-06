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
            pkgs.pyright
            pkgs.black
          ];

          shellHook = ''
            echo "--- Python Dev Environment (Stable) ---"
            echo "Python:  $(python --version)"
            echo "LSP:     Pyright $(pyright --version | grep -oE '[0-9.]+')"
            echo "Format:  Black $(black --version | grep -oE '[0-9.]+')"

            # Ensures uv doesn't download its own Python
            export UV_PYTHON_DOWNLOADS=never
          '';
        };
      }
    );
}
