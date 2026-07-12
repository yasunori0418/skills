{
  description = "AI agent skills (Claude Code / Codex) management repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      perSystem =
        { pkgs, ... }:
        let
          # Project-local packages (callPackage pattern; see pkgs/).
          skills-ref = pkgs.callPackage ./pkgs/skills-ref.nix { };
        in
        {
          packages.skills-ref = skills-ref;

          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt = {
              enable = true;
              package = pkgs.nixfmt;
            };
            # Format JSON / YAML (schema + Codex manifests) only.
            # Markdown is excluded: prettier reflows CJK (full/half-width)
            # tables inconsistently and produces churn on README.md / AGENTS.md
            # / SKILL.md. Prose markdown is left to the author.
            programs.prettier.enable = true;
            settings.formatter.prettier.excludes = [
              "*.md"
              "**/*.md"
            ];
          };

          # Validate every skill: SKILL.md via the official skills-ref validator,
          # agents/openai.yaml via the repo-local JSON Schema. Runs as part of
          # `nix flake check` (offline, sandbox-safe). New/untracked files must
          # be `git add`ed first to be visible to the flake source.
          checks.skills =
            pkgs.runCommand "check-skills"
              {
                nativeBuildInputs = [
                  skills-ref
                  pkgs.check-jsonschema
                ];
                env.SKILLS_SCHEMA_DIR = "${./schema}";
              }
              ''
                bash ${./scripts/validate-skills.sh} ${./.}
                touch "$out"
              '';

          # Run plugin hook unit tests (hooks/*/tests/*.test.sh).
          # Scripts use `#!/usr/bin/env bash`, which does not exist in the nix
          # sandbox — copy to a writable dir and patchShebangs first.
          checks.hooks =
            pkgs.runCommand "check-hooks"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.git
                ];
              }
              ''
                cp -r ${./hooks} hooks
                chmod -R +w hooks
                patchShebangs hooks
                fail=0
                for t in hooks/*/tests/*.test.sh; do
                  bash "$t" || fail=1
                done
                [ "$fail" -eq 0 ]
                touch "$out"
              '';
        };
    };
}
