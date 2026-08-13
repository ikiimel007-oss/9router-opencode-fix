#!/usr/bin/env bash
# ============================================================
# Backup konfigurasi 9router saat ini agar bisa di-restore
# di VPS baru setelah install (langsung terpakai).
#
# Isi: DB 9router (apiKeys, model oc/*-free, settings),
#      machine-id, jwt-secret, auth/cli-secret, opencode config.
#
# Hasil: backup/9router-config-<timestamp>.tar.gz (jangan di-commit,
#        berisi API key instance). Pindahkan file ini ke VPS baru,
#        taruh di folder repo, lalu jalankan install.sh.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$SCRIPT_DIR/backup/9router-config-$STAMP.tar.gz"

mkdir -p "$SCRIPT_DIR/backup"

tar -czf "$OUT" -C "$HOME" \
  .9router/db/data.sqlite \
  .9router/machine-id \
  .9router/jwt-secret \
  .9router/auth/cli-secret \
  .config/opencode/opencode.jsonc

echo "Backup dibuat: $OUT"
echo "Transfer ke VPS baru: scp $OUT <vps>:~/9router-opencode-fix/backup/"
echo "Lalu di VPS baru: bash install.sh (otomatis restore)"