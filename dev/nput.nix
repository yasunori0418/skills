# nput（project mode）の配置 config をまとめる flake-parts module。
# dev/flake.nix の imports が読む。root = projectRoot（git toplevel）なので
# 配置先は repo root 配下（.claude/skills/<name>）。配置物は .gitignore 済みの ephemeral。
#
# 複数の外部スキルリポジトリから、このリポジトリ（skill 管理そのものが目的）に合う
# ものだけを厳選して .claude/skills/<name> へ配置する。issue tracker / apm / waxa
# といった外部エコシステム前提のスキル（tdd / triage / skill-finder 等）は、
# このリポジトリの実態（Issue 運用なし、SKILL.md 中心、apm・waxa 未導入）に合わない
# ため対象外。
{ inputs, ... }:
let
  nputLib = inputs.nput.lib;

  # { src, subpath } を明示列挙する。リポジトリごとにツリー構造が異なるため
  # （mattpocock/skills・anthropics/skills は skills/<name>、mizchi/skills は
  # <category>/<name>）、subpath は各リポジトリの実際のパスをそのまま書く。
  skillSources = [
    # mattpocock/skills
    {
      src = inputs.matt-skills;
      subpath = "skills/productivity/writing-great-skills"; # SKILL.md 執筆の語彙・原則リファレンス
    }
    {
      src = inputs.matt-skills;
      subpath = "skills/productivity/grilling"; # 曖昧な設計判断を1問ずつ・推奨案付きで詰める
    }
    {
      src = inputs.matt-skills;
      subpath = "skills/productivity/handoff"; # 長時間セッションを次セッションへの引き継ぎ文書に圧縮
    }

    # mizchi/skills（apm/waxa 依存の強い skill-finder 系は対象外）
    {
      src = inputs.mizchi-skills;
      subpath = "meta/empirical-prompt-tuning"; # サブエージェントに実際に読ませて検証する実証的チューニング
    }
    {
      src = inputs.mizchi-skills;
      subpath = "meta/optimizing-descriptions"; # SKILL.md の description フィールド監査チェックリスト
    }
    {
      src = inputs.mizchi-skills;
      subpath = "meta/retrospective-codify"; # 失敗/成功ペアを skill・CLAUDE.md ルールとして明文化
    }

    # anthropics/skills
    {
      src = inputs.anthropic-skills;
      subpath = "skills/skill-creator"; # 公式スキル作成・改善・評価フロー
    }
  ];

  # target = .claude/skills/<skill 名>（各 subpath の basename）。
  skillEntries = builtins.listToAttrs (
    map (s: {
      name = ".claude/skills/${baseNameOf s.subpath}";
      value = s;
    }) skillSources
  );
in
{
  perSystem =
    { pkgs, ... }:
    {
      # perSystem.nput.skills → flake.nput.<system>.skills へ自動転置される（nput flakeModule）。
      nput.skills = nputLib.mkManifest {
        inherit pkgs;
        root = nputLib.projectRoot;
        entries = skillEntries;
      };
    };
}
