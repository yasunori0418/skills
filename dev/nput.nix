# nput（project mode）の配置 config をまとめる flake-parts module。
# dev/flake.nix の imports が読む。root = projectRoot（git toplevel）なので
# 配置先は repo root 配下（.claude/skills/<name>）。配置物は .gitignore 済みの ephemeral。
#
# - skills: mattpocock/skills をこのリポジトリ（skill 管理そのものが目的）に合わせて
#   厳選したサブセットのみ .claude/skills/<name> へ配置する。issue tracker 前提・DDD 的
#   大規模コードベース前提のスキル（tdd / triage / to-tickets / domain-modeling 等）は
#   このリポジトリの実態（Issue 運用なし、SKILL.md 中心）に合わないため対象外。
{ inputs, ... }:
let
  nputLib = inputs.nput.lib;

  # 展開する skill を明示列挙する（mattpocock/skills の skills/ 配下の相対パス）。
  skillSubpaths = [
    "productivity/writing-great-skills" # SKILL.md 執筆の語彙・原則リファレンス
    "productivity/grilling" # 曖昧な設計判断を1問ずつ・推奨案付きで詰める
    "productivity/handoff" # 長時間セッションを次セッションへの引き継ぎ文書に圧縮
  ];

  # skill ごとに { ".claude/skills/<name>" = entry; } を組む。
  # target = .claude/skills/<skill 名>、配置元は skills/<category>/<name> の subpath。
  skillEntries = builtins.listToAttrs (
    map (p: {
      name = ".claude/skills/${baseNameOf p}";
      value = {
        src = inputs.matt-skills;
        subpath = "skills/${p}";
      };
    }) skillSubpaths
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
