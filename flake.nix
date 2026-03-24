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
          gitonScript = ./giton.py;
          runtimeDeps = [ python pkgs.git pkgs.gh pkgs.nix pkgs.openssh pkgs.process-compose ];
          testFiles = pkgs.runCommand "giton-test-files" { } ''
            mkdir -p $out
            cp ${./test/run.sh} $out/run.sh
            cp ${./test/test_single_step.sh} $out/test_single_step.sh
            cp ${./test/test_github_status.sh} $out/test_github_status.sh
            cp ${./test/test_sha_pinning.sh} $out/test_sha_pinning.sh
            cp ${./test/test_multi_step.sh} $out/test_multi_step.sh
          '';
        in
        {
          packages.default = pkgs.writeShellApplication {
            name = "giton";
            meta.description = "Local CI tool — run commands on Nix platforms with GitHub status reporting";
            runtimeInputs = runtimeDeps;
            text = ''
              exec python3 ${gitonScript} "$@"
            '';
          };

          # Test runner (unwrapped so mock gh takes precedence in PATH)
          packages.test = pkgs.writeShellApplication {
            name = "giton-test";
            runtimeInputs = [ python pkgs.git pkgs.nix pkgs.process-compose ];
            text = ''
              export GITON="python3 ${gitonScript}"
              exec bash ${testFiles}/run.sh "$@"
            '';
          };
        };
    };
}
