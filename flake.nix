{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    haskell-flake.url = "github:srid/haskell-flake";
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-root.url = "github:srid/flake-root";
  };
  outputs =
    inputs@{
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;
      imports = [
        inputs.haskell-flake.flakeModule
        inputs.treefmt-nix.flakeModule
        inputs.pre-commit-hooks.flakeModule
        inputs.flake-root.flakeModule
      ];

      perSystem =
        {
          self',
          config,
          pkgs,
          ...
        }:
        let
          basePackages = pkgs.haskellPackages;
        in
        {
          # Typically, you just want a single project named "default". But
          # multiple projects are also possible, each using different GHC version.
          haskellProjects.default = {
            # The base package set representing a specific GHC version.
            # By default, this is pkgs.haskellPackages.
            # You may also create your own. See https://community.flake.parts/haskell-flake/package-set
            inherit basePackages;

            settings = {
              clipsync = {
                # This module can take `{self, super, ...}` args, optionally.
                # Disable running tests
                # check = false;

                # Disable building haddock (documentation)
                # haddock = false;

                # Ignore Cabal version constraints
                # jailbreak = true;

                # Extra non-Haskell dependencies
                extraBuildDepends = with pkgs; [
                  clipnotify
                  xclip
                  wl-clipboard
                ];

                # Source patches
                # patches = [ ./patches/ema-bug-fix.patch ];

                # Enable/disable Cabal flags
                # cabalFlags.with-generics = true;

                # Allow building a package marked as "broken"
                # broken = false;
              };
            };

            # Extra package information. See https://community.flake.parts/haskell-flake/dependency
            #
            # Note that local packages are automatically included in `packages`
            # (defined by `defaults.packages` option).
            #
            packages = { };

            devShell = {
              tools =
                _hspkgs:
                {
                  treefmt = config.treefmt.build.wrapper;
                }
                // config.treefmt.build.programs;
              hlsCheck.enable = false;
            };
            autoWire = [
              "packages"
              "apps"
              "checks"
            ]; # Wire all but the devShell
          };

          # https://flake.parts/options/treefmt-nix.html
          # Example: https://github.com/nix-community/buildbot-nix/blob/main/nix/treefmt/flake-module.nix
          treefmt.projectRootFile = "flake.nix";
          treefmt.settings.global.excludes = [ ];

          treefmt.programs = {
            cabal-gild = {
              enable = true;
              package = basePackages.cabal-gild;
            };
            deadnix.enable = true;
            fourmolu = {
              enable = true;
              package = basePackages.fourmolu;
            };
            just.enable = true;
            hlint = {
              enable = true;
              package = basePackages.hlint;
            };
            nixfmt.enable = true;
            shfmt.enable = true;
            statix.enable = true;
          };

          # https://flake.parts/options/git-hooks-nix.html
          # Example: https://github.com/cachix/git-hooks.nix/blob/master/template/flake.nix
          pre-commit.settings.excludes = [ ];
          pre-commit.settings.hooks = {
            commitizen.enable = true;
            eclint.enable = true;
            treefmt.enable = true;
          };

          packages.default = self'.packages.clipsync;
          apps.default = self'.apps.clipsync;

          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.haskellProjects.default.outputs.devShell
              config.treefmt.build.devShell
              config.pre-commit.devShell
              config.flake-root.devShell
            ];
            packages = with pkgs; [
              xclip
              wl-clipboard
              clipnotify
            ];
          };
        };
    };
}
