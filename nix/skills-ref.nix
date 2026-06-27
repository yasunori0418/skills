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
