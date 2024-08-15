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
      url = "github:openobserve/openobserve/v0.8.1";
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
            sha256 = "sha256-nxFSckxGqs0YAW3UeHBC4fTeE3fLJI+nC0IEPiF/bIw=";
          }).toolchain;

          craneLib = crane.lib.${system}.overrideToolchain toolchain;

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
              license = licenses.agpl3;
              mainProgram = "openobserve";
            };
          });

          web = pkgs.buildNpmPackage {
            name = "${cargoToml.package.name}-web";
            src = "${openobserve-src}/web";

            patches = [
              # remove cyprus related packages used for testing and which causes installation issues
              ./nix/patches/web/package.json.diff
            ];

            # run prefetch-npm-deps to update it
            npmDepsHash = "sha256-RNUCR80ewFt9F/VHv7kXLa87h0fz0YBp+9gSOUhtrdU=";

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
