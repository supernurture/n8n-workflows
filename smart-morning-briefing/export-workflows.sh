#!/usr/bin/env bash
# Export the live n8n workflows into this folder as commit-safe JSON.
#
#   ./export-workflows.sh
#
# What it does:
#   1. Exports each workflow from the running `n8n` container via the n8n CLI.
#   2. Removes instance/owner data that must not be published. `n8n export:workflow`
#      adds a `shared` block containing the owner's project name, which is the
#      n8n account name + email.
#   3. Scans the result for personal data and secrets (emails, Telegram bot tokens,
#      private keys, plus any extra patterns listed in .export-denylist) and aborts
#      WITHOUT touching the existing files if anything is found.
#   4. Only then replaces the JSON files in this folder.
#
# Add more workflows by extending WORKFLOWS ("<workflow id>:<file name>").
# Optional: put one extended-regex per line in .export-denylist (gitignored) for values
# that are private to you, e.g. your Telegram chat ID.
set -euo pipefail

cd "$(dirname "$0")"

CONTAINER="${CONTAINER:-n8n}"
WORKFLOWS=(
  "gDERYkGL9F978Jz2:smart-morning-briefing.json"
  "ee61BHBuxOdl5UOD:error-catcher.json"
)
# Top-level keys removed from every exported workflow.
STRIP_KEYS="${STRIP_KEYS-shared}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; docker exec "$CONTAINER" rm -rf /tmp/n8n-safe-export >/dev/null 2>&1 || true' EXIT

docker exec "$CONTAINER" sh -c 'rm -rf /tmp/n8n-safe-export && mkdir -p /tmp/n8n-safe-export' >/dev/null

echo "[1/4] Exporting ${#WORKFLOWS[@]} workflow(s) from container '$CONTAINER'..."
for entry in "${WORKFLOWS[@]}"; do
  id="${entry%%:*}"; file="${entry#*:}"
  docker exec "$CONTAINER" n8n export:workflow --id="$id" --pretty \
    --output="/tmp/n8n-safe-export/$file" >/dev/null 2>&1 \
    || { echo "  ERROR: export of workflow $id failed (does it exist?)" >&2; exit 1; }
  docker cp "$CONTAINER:/tmp/n8n-safe-export/$file" "$STAGE/$file" >/dev/null
  echo "  exported $id -> $file"
done

echo "[2/4] Stripping instance/owner data (keys: $STRIP_KEYS)..."
python3 -I - "$STAGE" "$STRIP_KEYS" <<'PY'
import json, pathlib, sys
stage, keys = pathlib.Path(sys.argv[1]), sys.argv[2].split()
for p in sorted(stage.glob('*.json')):
    data = json.loads(p.read_text())
    items = data if isinstance(data, list) else [data]
    removed = sorted({k for w in items if isinstance(w, dict) for k in keys if w.pop(k, None) is not None})
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')
    print(f"  {p.name}: removed {removed or 'nothing'}")
PY

echo "[3/4] Scanning for personal data and secrets..."
PATTERNS=(
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'   # any email address
  '[0-9]{8,10}:[A-Za-z0-9_-]{35}'                     # Telegram bot token
  'BEGIN [A-Z ]*PRIVATE KEY'                          # private keys
)
if [ -f .export-denylist ]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] || PATTERNS+=("$line")
  done < .export-denylist
fi
FOUND=0
for pat in "${PATTERNS[@]}"; do
  # Ignore safe, public email shapes (GitHub noreply, example domains, n8n.io docs).
  hits="$(grep -nEo -- "$pat" "$STAGE"/*.json \
          | grep -vE 'users\.noreply\.github\.com|@example\.(com|org)|@n8n\.io' || true)"
  if [ -n "$hits" ]; then
    FOUND=1
    echo "  BLOCKED by pattern: $pat" >&2
    # Show file:line only, never the matched value itself.
    echo "$hits" | cut -d: -f1,2 | sed 's|.*/||; s/^/    at /' >&2
  fi
done
if [ "$FOUND" -ne 0 ]; then
  echo "Aborted: sensitive data found. Existing files were NOT changed." >&2
  exit 2
fi
echo "  clean"

echo "[4/4] Writing files..."
for entry in "${WORKFLOWS[@]}"; do
  file="${entry#*:}"
  if [ -f "$file" ] && cmp -s "$STAGE/$file" "$file"; then
    echo "  $file: unchanged"
  else
    cp "$STAGE/$file" "$file"
    echo "  $file: updated"
  fi
done
echo "Done. Review with: git diff -- $(printf '%s ' "${WORKFLOWS[@]#*:}")"
