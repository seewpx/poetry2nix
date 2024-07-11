{
  description = "Poetry2nix flake";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    nix-github-actions = {
      url = "github:nix-community/nix-github-actions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    nix-github-actions,
    treefmt-nix,
    systems,
  }: let
    eachSystem = f: nixpkgs.lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system});
    treefmtEval = eachSystem (pkgs: treefmt-nix.lib.evalModule pkgs ./dev/treefmt.nix);
  in
    {
      overlays.default = nixpkgs.lib.composeManyExtensions [(import ./overlay.nix)];
      lib.mkPoetry2Nix = {pkgs}: import ./default.nix {inherit pkgs;};

      githubActions = let
        mkPkgs = system:
          import nixpkgs {
            config = {
              allowAliases = false;
              allowInsecurePredicate = _: true;
            };
            overlays = [self.overlays.default];
            inherit system;
          };
      in
        nix-github-actions.lib.mkGithubMatrix {
          platforms = {
            "x86_64-linux" = "ubuntu-22.04";
            "x86_64-darwin" = "macos-13";
            "aarch64-darwin" = "macos-14";
          };
          checks = let
            splitList = x: list: let
              length = builtins.length list;
              divisor = nixpkgs.lib.trivial.min x length;
              chunkSize = length / divisor;
              indices = builtins.genList (i: i * chunkSize) divisor;
              lastChunk = nixpkgs.lib.lists.last indices;
            in
              builtins.map (i:
                nixpkgs.lib.lists.sublist i
                (
                  if (i == lastChunk)
                  then length
                  else chunkSize
                )
                list)
              indices;
            # Aggregate all tests into a small number of  derivations so that only a small number of GHA runners is scheduled for all darwin jobs
            # (a single one runs >4h hours)

            mkDarwinTests = pkgs: let
              inherit (pkgs) lib;
              tests = import ./tests {inherit pkgs;};
              all_tests = lib.attrValues (lib.filterAttrs (_: v: lib.isDerivation v) tests);
              split_count = 8;
              split_tests = splitList split_count all_tests; # that's the number of jobs we split this into.
              split_test_derivations = map (sub_tests:
                pkgs.runCommand "darwin-aggregate"
                {
                  env.TEST_INPUTS = lib.concatStringsSep " " sub_tests;
                } "touch $out")
              split_tests;
            in
              builtins.listToAttrs (map (ii: {
                name = "darwin-aggregate" + (builtins.toString ii);
                value = builtins.elemAt split_test_derivations ii;
              }) (lib.lists.range 0 (split_count - 1)));
          in {
            x86_64-linux = let
              pkgs = mkPkgs "x86_64-linux";
            in
              import ./tests {inherit pkgs;}
              // {
                formatting = treefmtEval.x86_64-linux.config.build.check self;
              };

            x86_64-darwin = mkDarwinTests (mkPkgs "x86_64-darwin");

            aarch64-darwin = mkDarwinTests (mkPkgs "aarch64-darwin");
          };
        };

      templates = {
        app = {
          path = ./templates/app;
          description = "An example of a NixOS container";
        };
        default = self.templates.app;
      };
    }
    // (flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {
        inherit system;
        config.allowAliases = false;
      };

      poetry2nix = import ./default.nix {inherit pkgs;};
      p2nix-tools = pkgs.callPackage ./tools {inherit poetry2nix;};
    in rec {
      formatter = treefmtEval.${system}.config.build.wrapper;

      packages = {
        poetry2nix = poetry2nix.cli;
        default = poetry2nix.cli;
      };

      devShells = {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            p2nix-tools.env
            p2nix-tools.flamegraph
            nixpkgs-fmt
            poetry
            niv
            jq
            nix-prefetch-git
            nix-eval-jobs
            nix-build-uncached
          ];
        };
      };

      apps = {
        poetry = {
          # https://wiki.nixos.org/wiki/Flakes
          type = "app";
          program = pkgs.poetry;
        };
        poetry2nix = flake-utils.lib.mkApp {drv = packages.poetry2nix;};
        default = apps.poetry2nix;
      };
    }));
}
