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
        Medieval = with pkgs; [
          kind # Creates the local multi-node cluster inside Docker
          kubectl # The CLI tool to talk to Kubernetes
          kubernetes-helm # Installs Slinky charts
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = Medieval;

          shellHook = ''
            echo "🎒 Welcome to your AI Sandbox prototyping shell!"
            echo "Tools loaded: kind ($(kind --version)), kubectl, helm"
          '';
        };
      }
    );
}
