{
  description = "skills development environment";

  inputs = {
    root.url = "path:../";
    nixpkgs.follows = "root/nixpkgs";
    flake-parts.follows = "root/flake-parts";
    # NG: treefmt-nix is intentionally NOT added here.
    # OK: reuse root's treefmt formatter via inputs'.root.formatter.

    # Places curated external skills under .claude/skills/ (project mode, dev-only concern).
    layat = {
      url = "github:yasunori0418/layat";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Claude Code 用スキル集（mattpocock/skills）。layat の project mode で
    # .claude/skills/ へ配置するため flake=false。flake.lock が rev を pin する。
    matt-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };

    # mizchi/skills（スキル作成メタスキルの追加ソース）。同じく project mode 用に flake=false。
    mizchi-skills = {
      url = "github:mizchi/skills";
      flake = false;
    };

    # anthropics/skills（公式 skill-creator を明示管理するため）。同じく flake=false。
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };
    cclens.url = "github:lambdalisue/cclens";
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
        inputs.layat.flakeModules.default
        ./layat.nix
      ];
      perSystem =
        { inputs', pkgs, ... }:
        {
          devShells = {
            # Local development: full LSP / linter / formatter / validators.
            default = pkgs.mkShell {
              packages =
                with pkgs;
                let
                  cclens = inputs'.cclens.packages.default;
                  formatter = inputs'.root.formatter;
                  skills-ref = inputs'.root.packages.skills-ref;
                  layat = inputs'.layat.packages.layat;
                in
                [
                  # Nix
                  statix # Nix linter
                  nixd # Nix language server
                  formatter # root's treefmt (nixfmt + prettier)

                  # Skill validation & lint
                  skills-ref # official agentskills.io validator
                  check-jsonschema # JSON Schema validation for agents/openai.yaml
                  yamllint # YAML lint
                  markdownlint-cli2 # Markdown lint for SKILL.md

                  # Python 型検査(job-plan の pyright strict ゲートをローカルで回す)
                  pyright

                  # Data wrangling
                  yq-go # YAML/JSON query & edit (`yq`)
                  jq # JSON query

                  # Markdown link checking
                  lychee

                  # Search
                  ripgrep
                  fd

                  # 外部スキル（mattpocock/mizchi/anthropics）を .claude/skills/ へ配置する
                  # layat（project mode 用に pin）
                  layat

                  cclens
                ];
              shellHook = ''
                export REPO_ROOT=$(git rev-parse --show-superproject-working-tree --show-toplevel)
                layat apply skills -f "$REPO_ROOT/dev" --no-wait
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
