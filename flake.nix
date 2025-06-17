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
    mission-control.url = "github:Platonic-Systems/mission-control";
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
        inputs.mission-control.flakeModule
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
            cabal-fmt = {
              enable = true;
              package = basePackages.cabal-fmt;
            };
            deadnix.enable = true;
            fourmolu = {
              enable = true;
              package = basePackages.fourmolu;
            };
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

          # Devshell scripts.
          mission-control.scripts = {
            docs = {
              description = "Start Hoogle server for project dependencies";
              exec = ''
                echo http://127.0.0.1:8888
                hoogle serve -p 8888 --local
              '';
              category = "Dev Tools";
            };
            repl = {
              description = "Start the cabal repl";
              exec = ''
                cabal repl "$@"
              '';
              category = "Dev Tools";
            };
            fmt = {
              description = "Format the source tree";
              exec = config.treefmt.build.wrapper;
              category = "Dev Tools";
            };
            run = {
              description = "Run the project with ghcid auto-recompile";
              exec = ''
                cabal exec -- ghcid -c "cabal repl exe:clipsync" --warnings -T :main
              '';
              category = "Primary";
            };
          };

          packages.default = self'.packages.clipsync;
          apps.default = self'.apps.clipsync;

          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.haskellProjects.default.outputs.devShell
              config.pre-commit.devShell
              config.flake-root.devShell
              config.mission-control.devShell
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
