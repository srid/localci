{
  description = "Local CI tool — run commands on Nix platforms with GitHub status reporting";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      perSystem = { pkgs, ... }:
        let
          python = pkgs.python3;
          runtimeDeps = [ python pkgs.git pkgs.gh pkgs.nix pkgs.openssh pkgs.process-compose ];
        in
        {
          packages.default = pkgs.writeShellApplication {
            name = "giton";
            meta.description = "Local CI tool — run commands on Nix platforms with GitHub status reporting";
            runtimeInputs = runtimeDeps;
            text = ''
              exec python3 ${./giton.py} "$@"
            '';
          };
        };
    };
}
