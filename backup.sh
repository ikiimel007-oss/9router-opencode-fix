#!/usr/bin/env bash
# ============================================================
# Backup konfigurasi 9router saat ini.
#
# Hasil: backup/9router-config.tar.gz  -> file tetap, siap di-commit
#        & di-push ke GitHub (supaya di VPS baru tinggal clone).
# Catatan: berisi API key + secrets 9router (repo harus private
#        atau kamu sadar resikonya bila repo public).
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/backup/9router-config.tar.gz"

mkdir -p "$SCRIPT_DIR/backup"

tar -czf "$OUT" -C "$HOME" \
  .9router/db/data.sqlite \
  .9router/machine-id \
  .9router/jwt-secret \
  .9router/auth/cli-secret \
  .config/opencode/opencode.jsonc

echo "Backup dibuat: $OUT"
echo "Commit & push agar di VPS baru tinggal clone:"
echo "  git add backup/9router-config.tar.gz && git commit -m 'update backup config' && git push"
echo "Lalu di VPS baru: bash install.sh (otomatis restore)"