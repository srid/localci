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
          giton = pkgs.stdenv.mkDerivation {
            pname = "giton";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.nim2 ];
            buildPhase = ''
              HOME=$TMPDIR
              nim compile -d:release --opt:speed --outdir:$out/bin giton.nim
            '';
            installPhase = "true";
            meta.description = "Local CI tool — run commands on Nix platforms with GitHub status reporting";
          };
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
          # Wrapped binary with runtime deps in PATH
          packages.default = giton.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
            postInstall = ''
              wrapProgram $out/bin/giton \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.gh pkgs.nix pkgs.openssh pkgs.process-compose ]}
            '';
          });

          # Test runner (uses unwrapped binary so mock gh takes precedence in PATH)
          packages.test = pkgs.writeShellApplication {
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
