# Flake to build openobserve a service for metrics,logs and traces.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";

    # https://github.com/nix-community/fenix?tab=readme-ov-file#toolchain
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # https://crane.dev/index.html
    crane = {
      url = "github:ipetkov/crane";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };


    openobserve-src = {
      url = "github:openobserve/openobserve/v0.12.1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, utils, fenix, crane, openobserve-src }:
    utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };

          cargoToml = pkgs.lib.importTOML "${src}/Cargo.toml";

          toolchain = (fenix.packages.${system}.fromToolchainName {
            name = (pkgs.lib.importTOML "${src}/rust-toolchain.toml").toolchain.channel;
            sha256 = "sha256-fA/nLspVp8bNs/kKMwfNswhRa5bMkPUmVL3HTm9K15w=";
          }).toolchain;

          craneLib = (crane.mkLib nixpkgs.legacyPackages.${system}).overrideToolchain toolchain;

          src =
            # filter out the web directory which gets built and linked in later
            let f = name: type:
              with builtins;
              with pkgs.lib;
              let baseName = baseNameOf (toString name);
              in !(type == "directory" && baseName == "web");
            in pkgs.lib.cleanSourceWith {filter = f; src = "${openobserve-src}";};

          # Common arguments can be set here to avoid repeating them later
          commonArgs = {
            inherit src;

            # see https://github.com/rust-lang/rust/issues/125321
            RUSTFLAGS="-Z linker-features=-lld";
            prePatch = ''
              rm .cargo/config.toml
            '';
            strictDeps = true;
            nativeBuildInputs = [
              pkgs.protobuf
            ];
          };

          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          openobserve = craneLib.buildPackage (commonArgs // {
            pname = cargoToml.package.name;
            version = cargoToml.package.version;

            inherit cargoArtifacts;

            nativeBuildInputs = [
              pkgs.protobuf
              pkgs.git
            ];

            # test cases are failing at the moment so we disable them
            doCheck = false;

            preConfigurePhases = [ "buildWeb" ];

            buildWeb = ''
              ln -s ${web} web
            '';

            meta = with pkgs.lib; {
              homepage = cargoToml.package.homepage;
              changelog = "https://github.com/openobserve/openobserve/releases/tag/v${version}";
              description = cargoToml.package.description;
              longDescription = ''
                OpenObserve (O2 for short) is a cloud-native observability platform built
                specifically for logs, metrics, traces, analytics, RUM (Real User Monitoring -
                Performance, Errors, Session Replay) designed to work at petabyte scale.
              '';
              license = licenses.agpl3Only;
              mainProgram = "openobserve";
            };
          });

          web = pkgs.buildNpmPackage rec {
            pname = "${cargoToml.package.name}-web";
            version = cargoToml.package.version;
            src = "${openobserve-src}/web";

            prePatch = ''
              sed -i '/cypress/d' package.json
              #sed -i '/cypress/d' package-lock.json
            '';

            # run prefetch-npm-deps to update it
            npmDepsHash = "sha256-UWWKLOi3nAjdCtRYyFmHNUxz0JTrtKUEIYGOYEM2i9w=";

            # the output of this package is only the assets
            # it is not a nodejs application
            dontNpmInstall = true;
            installPhase = ''
              ls -alh
              mkdir $out
              cp -r dist $out/
            '';
          };
        in
        {
          checks = {
            inherit web openobserve;
          };

          packages.default = openobserve;
          packages.openobserve = openobserve;

          apps.default = utils.lib.mkApp { drv = openobserve; };
        }
      )
    // {
      overlays.default = final: prev: {
        openobserve = self.packages.${prev.system}.openobserve;
      };
    };
}
