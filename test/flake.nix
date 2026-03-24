{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    giton.url = "path:..";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      perSystem = { pkgs, system, ... }:
        let
          giton = inputs.giton.packages.${system}.default;
          testFiles = pkgs.runCommand "giton-test-files" { } ''
            mkdir -p $out
            cp ${./run.sh} $out/run.sh
            cp ${./test_single_step.sh} $out/test_single_step.sh
            cp ${./test_github_status.sh} $out/test_github_status.sh
            cp ${./test_sha_pinning.sh} $out/test_sha_pinning.sh
            cp ${./test_multi_step.sh} $out/test_multi_step.sh
          '';
        in
        {
          packages.default = pkgs.writeShellApplication {
            name = "giton-test";
            runtimeInputs = [ pkgs.git pkgs.nix pkgs.process-compose ];
            text = ''
              export GITON="${giton}/bin/giton"
              exec bash ${testFiles}/run.sh "$@"
            '';
          };
        };
    };
}
