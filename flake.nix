{
  description = "plutarch";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
    allow-import-from-derivation = "true";
    bash-prompt = "\\[\\e[0m\\][\\[\\e[0;2m\\]nix \\[\\e[0;1m\\]plutarch \\[\\e[0;93m\\]\\w\\[\\e[0m\\]]\\[\\e[0m\\]$ \\[\\e[0m\\]";
    cores = "1";
    max-jobs = "auto";
    auto-optimise-store = "true";
  };

  inputs = {
    nixpkgs.follows = "haskell-nix/nixpkgs-unstable";
    nixpkgs-latest.url = "github:NixOS/nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";

    haskell-nix.url = "github:input-output-hk/haskell.nix";
    iohk-nix.url = "github:input-output-hk/iohk-nix";
    iohk-nix.inputs.nixpkgs.follows = "nixpkgs";

    CHaP.url = "github:input-output-hk/cardano-haskell-packages?ref=repo";
    CHaP.flake = false;

    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    hercules-ci-effects.url = "github:hercules-ci/hercules-ci-effects";
  };

  outputs = inputs@{ flake-parts, nixpkgs, haskell-nix, iohk-nix, CHaP, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ./pre-commit.nix
        ./hercules-ci.nix
      ];
      systems = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" "aarch64-linux" ];

      perSystem = { config, system, ... }:
        let
          pkgs =
            import nixpkgs {
              inherit system;
              overlays = [
                haskell-nix.overlay
                iohk-nix.overlays.crypto
              ];
              inherit (haskell-nix) config;
            };
          project = pkgs.haskell-nix.cabalProject' {
            src = ./.;
            compiler-nix-name = "ghc963";
            index-state = "2023-11-26T21:52:49Z"; # NOTE(bladyjoker): Follow https://github.com/input-output-hk/plutus/blob/master/cabal.project
            inputMap = {
              "https://input-output-hk.github.io/cardano-haskell-packages" = CHaP;
            };
            shell = {
              withHoogle = true;
              exactDeps = false;
              # TODO(peter-mlabs): Use `apply-refact` for repo wide refactoring `find -name '*.hs' -not -path './dist-*/*' -exec hlint -j --refactor --refactor-options="--inplace" {} +``
              shellHook = config.pre-commit.installationScript;
              tools = {
                cabal = { };
                haskell-language-server = { };
                hlint = { };
                cabal-fmt = { };
                fourmolu = { };
                hspec-discover = { };
                markdown-unlit = { };
              };
            };
          };
          flake = project.flake { };
        in
        {
          inherit (flake) packages devShells;
          checks = flake.checks // {
            plutarch-test = pkgs.runCommand "plutarch-test"
              {
                nativeBuildInputs = [ flake.packages."plutarch-test:exe:plutarch-test" ];
              } ''
              plutarch-test
              touch $out
            '';
          };
        };
    };
}
