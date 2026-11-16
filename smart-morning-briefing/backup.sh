#!/usr/bin/env bash
# Back up n8n: workflow JSON export (human-readable) + full data volume snapshot (DB, config, encryption key file).
# Usage: ./backup.sh            -> writes to ./backups/<timestamp>/
#        KEEP=14 ./backup.sh    -> also keeps only the newest 14 backups (default 14)
# Restore volume: docker compose down && docker run --rm -v n8n_data:/data -v "$PWD/backups/<ts>":/b alpine \
#                   sh -c 'rm -rf /data/* && tar xzf /b/n8n_data.tar.gz -C /data' && docker compose up -d
set -euo pipefail

cd "$(dirname "$0")"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="backups/$TS"
KEEP="${KEEP:-14}"
mkdir -p "$DEST"

echo "[1/3] Exporting workflows..."
docker exec n8n sh -c 'rm -rf /tmp/n8n-export && mkdir -p /tmp/n8n-export && n8n export:workflow --all --separate --pretty --output=/tmp/n8n-export/' >/dev/null
docker cp n8n:/tmp/n8n-export "$DEST/workflows"
docker exec n8n rm -rf /tmp/n8n-export

echo "[2/3] Snapshotting n8n_data volume..."
docker run --rm --user "$(id -u):$(id -g)" -v n8n_data:/data:ro -v "$PWD/$DEST":/backup alpine \
  tar czf /backup/n8n_data.tar.gz -C /data .

echo "[3/3] Pruning old backups (keeping $KEEP)..."
ls -1d backups/*/ 2>/dev/null | sort | head -n -"$KEEP" | xargs -r rm -rf

chmod -R go-rwx "$DEST"
echo "Backup written to $DEST"
ls -la "$DEST" "$DEST/workflows"
