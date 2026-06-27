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
        {
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

          # Validate every skill (SKILL.md frontmatter + agents/openai.yaml)
          # against the JSON Schemas. Runs as part of `nix flake check`
          # (offline, sandbox-safe). New/untracked files must be `git add`ed
          # first to be visible to the flake source.
          checks.skills =
            pkgs.runCommand "check-skills"
              {
                nativeBuildInputs = with pkgs; [
                  check-jsonschema
                  yq-go
                ];
                env.SKILLS_SCHEMA_DIR = "${./schema}";
              }
              ''
                bash ${./scripts/validate-skills.sh} ${./.}
                touch "$out"
              '';
        };
    };
}
