#!/usr/bin/env bash
# Extract one version's Markdown section from CHANGELOG.md.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1#v}"
changelog="$repo_root/CHANGELOG.md"

awk -v ver="$version" '
  $0 ~ "^## \\[" ver "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
  END { if (!found) exit 3 }
' "$changelog"
