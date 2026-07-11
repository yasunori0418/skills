{
  description = "skills development environment";

  inputs = {
    root.url = "path:../";
    nixpkgs.follows = "root/nixpkgs";
    flake-parts.follows = "root/flake-parts";
    # NG: treefmt-nix is intentionally NOT added here.
    # OK: reuse root's treefmt formatter via inputs'.root.formatter.

    # Places mattpocock/skills under .claude/skills/ (project mode, dev-only concern).
    nput = {
      url = "github:yasunori0418/nput";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Claude Code 用スキル集（mattpocock/skills）。nput の project mode で
    # .claude/skills/ へ配置するため flake=false。flake.lock が rev を pin する。
    matt-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      imports = [
        inputs.nput.flakeModules.default
        ./nput.nix
      ];
      perSystem =
        { inputs', pkgs, ... }:
        {
          devShells = {
            # Local development: full LSP / linter / formatter / validators.
            default = pkgs.mkShell {
              packages = with pkgs; [
                # Nix
                statix # Nix linter
                nixd # Nix language server
                inputs'.root.formatter # root's treefmt (nixfmt + prettier)

                # Skill validation & lint
                inputs'.root.packages.skills-ref # official agentskills.io validator
                check-jsonschema # JSON Schema validation for agents/openai.yaml
                yamllint # YAML lint
                markdownlint-cli2 # Markdown lint for SKILL.md

                # Data wrangling
                yq-go # YAML/JSON query & edit (`yq`)
                jq # JSON query

                # Markdown link checking
                lychee

                # Search
                ripgrep
                fd

                # mattpocock/skills を .claude/skills/ へ配置する nput（project mode 用に pin）
                inputs'.nput.packages.nput
              ];
              shellHook = ''
                export REPO_ROOT=$(git rev-parse --show-superproject-working-tree --show-toplevel)
                nput apply skills -f "$REPO_ROOT/dev" --no-wait
              '';
            };

            # CI: minimal validators + dumb terminal.
            ci = pkgs.mkShell {
              packages = [
                inputs'.root.packages.skills-ref
                pkgs.check-jsonschema
                pkgs.yamllint
                pkgs.markdownlint-cli2
              ];
              env = {
                TERM = "dumb";
              };
              shellHook = ''
                export REPO_ROOT=$(git rev-parse --show-superproject-working-tree --show-toplevel)
              '';
            };
          };
        };
    };
}
