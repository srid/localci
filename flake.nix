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
          localci = pkgs.ocamlPackages.buildDunePackage {
            pname = "localci";
            version = "0.1.0";
            src = ./.;
            buildInputs = with pkgs.ocamlPackages; [ cmdliner yojson ];
            meta.description = "Local CI tool — run commands on Nix platforms with GitHub status reporting";
          };
        in
        {
          # Wrapped binary with runtime deps in PATH
          packages.default = pkgs.symlinkJoin {
            name = "localci";
            paths = [ localci ];
            buildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram $out/bin/localci \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.gh pkgs.nix pkgs.openssh pkgs.process-compose ]}
            '';
          };

          # Test runner (unwrapped binary so mock gh takes precedence in PATH)
          packages.test =
            let
              tested = localci.overrideAttrs (old: {
                doCheck = true;
                nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                  pkgs.git
                  pkgs.process-compose
                  pkgs.nix
                ];
                preCheck = ''
                  export HOME=$(mktemp -d)
                '';
              });
            in
            pkgs.writeShellApplication {
              name = "localci-test";
              text = ''echo "All tests passed (${tested})"'';
            };
        };
    };
}
