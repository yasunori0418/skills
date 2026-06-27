#!/usr/bin/env bash
#
# Validate every skill in the repository:
#   1. SKILL.md via the official agentskills.io reference validator
#      (`skills-ref validate <dir>` — checks frontmatter, naming, name==dirname).
#   2. Each agents/openai.yaml via openai-agent.schema.json
#      (repo convention for Codex; no official schema exists).
#
# Requires: skills-ref, check-jsonschema, find.
# Usage: validate-skills.sh [ROOT]   (ROOT defaults to the current directory)

set -euo pipefail

ROOT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="${SKILLS_SCHEMA_DIR:-$SCRIPT_DIR/../schema}"

status=0

# --- SKILL.md (official validator) ------------------------------------------
while IFS= read -r -d '' skill; do
  dir="$(dirname "$skill")"
  if ! skills-ref validate "$dir"; then
    echo "ERROR: $dir: skills-ref validation failed"
    status=1
  fi
done < <(find "$ROOT" -type f -name SKILL.md \
  -not -path '*/node_modules/*' -not -path '*/apm_modules/*' -print0)

# --- agents/openai.yaml (repo convention) -----------------------------------
while IFS= read -r -d '' agent; do
  if ! check-jsonschema --schemafile "$SCHEMA_DIR/openai-agent.schema.json" "$agent"; then
    echo "ERROR: $agent: failed schema validation"
    status=1
  fi
done < <(find "$ROOT" -type f -path '*/agents/openai.yaml' \
  -not -path '*/node_modules/*' -not -path '*/apm_modules/*' -print0)

if [ "$status" -eq 0 ]; then
  echo "All skills valid."
fi
exit "$status"
