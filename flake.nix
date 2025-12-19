{
  description = "git-fuse - FUSE filesystem for mounting Git repositories";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Filter source to only include files needed for building
        gitFuseSrc = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let
              baseName = baseNameOf path;
            in
              baseName == "git_fuse.d" ||
              baseName == "dub.sdl";
        };

        git-fuse = pkgs.buildDubPackage {
          pname = "git-fuse";
          version = "0.1.0";

          src = gitFuseSrc;

          dubLock = ./dub-lock.json;

          buildInputs = with pkgs; [
            fuse
          ];

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          installPhase = ''
            runHook preInstall
            install -Dm755 git-fuse -t $out/bin
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "FUSE filesystem for mounting Git repositories";
            license = licenses.mpl20;
            platforms = platforms.linux;
            mainProgram = "git-fuse";
          };
        };
      in
      {
        packages = {
          default = git-fuse;
          git-fuse = git-fuse;
        };

        apps.default = {
          type = "app";
          program = "${git-fuse}/bin/git-fuse";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            dmd
            dub
            fuse
            pkg-config
          ];
        };

        # Integration tests (only on Linux, requires VM)
        checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          integration = import ./ci/tests/nixos-test.nix {
            inherit (pkgs) lib;
            inherit pkgs;
            inherit git-fuse;
          };
        };
      }
    );
}
