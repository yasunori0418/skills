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
            # Markdown / YAML / JSON formatter for skill sources and schema.
            programs.prettier.enable = true;
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
