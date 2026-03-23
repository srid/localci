{
  description = "Local CI tool — run commands on Nix platforms with GitHub status reporting";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      perSystem = { pkgs, ... }: {
        packages.default = pkgs.writeShellApplication {
          name = "giton";
          meta.description = "Local CI tool — run commands on Nix platforms with GitHub status reporting";
          runtimeInputs = [ pkgs.git pkgs.gh pkgs.nix pkgs.jq pkgs.openssh pkgs.process-compose ];
          excludeShellChecks = [ "SC2029" "SC2317" "SC2329" ];
          text = builtins.readFile ./giton;
        };
      };
    };
}
