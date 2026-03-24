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
          localci = pkgs.buildGoModule {
            pname = "localci";
            version = "0.1.0";
            src = ./.;
            vendorHash = "sha256-0rbdfZLARlCeyUXRGWUZ/g36S1YV9tAyCm6eupGloEE=";
            subPackages = [ "cmd/localci" ];
            meta.description = "Local CI tool — run commands on Nix platforms with GitHub status reporting";
          };
          testFiles = pkgs.runCommand "localci-test-files" { } ''
            mkdir -p $out
            cp ${./test/run.sh} $out/run.sh
            cp ${./test/test_single_step.sh} $out/test_single_step.sh
            cp ${./test/test_github_status.sh} $out/test_github_status.sh
            cp ${./test/test_sha_pinning.sh} $out/test_sha_pinning.sh
            cp ${./test/test_multi_step.sh} $out/test_multi_step.sh
          '';
        in
        {
          # Wrapped binary with runtime deps in PATH
          packages.default = localci.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
            postInstall = ''
              wrapProgram $out/bin/localci \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.gh pkgs.nix pkgs.openssh pkgs.process-compose ]}
            '';
          });

          # Test runner (uses unwrapped binary so mock gh takes precedence in PATH)
          packages.test = pkgs.writeShellApplication {
            name = "localci-test";
            runtimeInputs = [ pkgs.git pkgs.nix pkgs.process-compose ];
            text = ''
              export LOCALCI="${localci}/bin/localci"
              exec bash ${testFiles}/run.sh "$@"
            '';
          };
        };
    };
}
