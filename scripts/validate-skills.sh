#!/usr/bin/env bash
#
# Validate every skill in the repository:
#   1. SKILL.md must have YAML frontmatter that satisfies skill-frontmatter.schema.json
#   2. The frontmatter `name` must match the skill's directory name
#   3. Each agents/openai.yaml must satisfy openai-agent.schema.json
#
# Requires: check-jsonschema, yq (yq-go), awk, find.
# Usage: validate-skills.sh [ROOT]   (ROOT defaults to the current directory)

set -euo pipefail

ROOT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="${SKILLS_SCHEMA_DIR:-$SCRIPT_DIR/../schema}"

status=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- SKILL.md frontmatter ---------------------------------------------------
while IFS= read -r -d '' skill; do
  dir="$(dirname "$skill")"
  base="$(basename "$dir")"
  fm="$tmp/frontmatter.yaml"

  # Extract YAML between the first pair of `---` delimiters.
  if ! awk '
        NR==1 { if ($0 != "---") exit 3; c=1; next }
        /^---[[:space:]]*$/ { if (c==1) exit 0 }
        c==1 { print }
      ' "$skill" >"$fm"; then
    echo "ERROR: $skill: missing or malformed YAML frontmatter (must start with ---)"
    status=1
    continue
  fi

  if ! check-jsonschema --schemafile "$SCHEMA_DIR/skill-frontmatter.schema.json" "$fm"; then
    echo "ERROR: $skill: frontmatter failed schema validation"
    status=1
    continue
  fi

  name="$(yq -r '.name' "$fm")"
  if [ "$name" != "$base" ]; then
    echo "ERROR: $skill: frontmatter name '$name' does not match directory '$base'"
    status=1
  fi
done < <(find "$ROOT" -type f -name SKILL.md \
  -not -path '*/node_modules/*' -not -path '*/apm_modules/*' -print0)

# --- agents/openai.yaml -----------------------------------------------------
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
