# Official agentskills.io reference validator (`skills-ref`).
# Exposes `bin/skills-ref` (`skills-ref validate <skill-dir>`).
#
# skills-ref is a small uv-managed Python project (deps: click, strictyaml) that
# lives in a subdirectory of the agentskills/agentskills repo. Both deps exist in
# nixpkgs, so we build it with the standard buildPythonApplication rather than
# uv2nix — fewer moving parts, no extra flake inputs, no import-from-derivation.
{
  lib,
  python3Packages,
  fetchFromGitHub,
}:
python3Packages.buildPythonApplication rec {
  pname = "skills-ref";
  version = "0.1.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "agentskills";
    repo = "agentskills";
    # pinned commit (2026-06, no upstream tag for skills-ref)
    rev = "5d4c1fda3f786fff826c7f56b6cb3341e7f3a911";
    hash = "sha256-pU5bVarvjeb/s2yJBQz+6UiUpXDQ3Widr7sZ5H2M5MA=";
  };
  # skills-ref is a subdirectory of the repo.
  sourceRoot = "${src.name}/skills-ref";

  # Claude Code 拡張の frontmatter フィールドを許可する。
  # upstream の ALLOWED_FIELDS は agentskills.io 標準のみで、Claude Code の
  # 拡張（argument-hint / disable-model-invocation / user-invocable）を弾く。
  # 本リポジトリのスキルは Claude Code での利用が主目的のためパッチで緩和する。
  # upstream の rev を上げる際はこのパッチが当たるか要確認。
  postPatch = ''
    substituteInPlace src/skills_ref/validator.py \
      --replace-fail '"compatibility",' \
        '"compatibility",
        "argument-hint",
        "disable-model-invocation",
        "user-invocable",'
  '';

  build-system = [ python3Packages.hatchling ];
  dependencies = with python3Packages; [
    click
    strictyaml
  ];

  nativeCheckInputs = [ python3Packages.pytestCheckHook ];
  pythonImportsCheck = [ "skills_ref" ];

  meta = {
    description = "Reference validator for the Agent Skills (agentskills.io) format";
    homepage = "https://github.com/agentskills/agentskills/tree/main/skills-ref";
    license = lib.licenses.asl20;
    mainProgram = "skills-ref";
  };
}
