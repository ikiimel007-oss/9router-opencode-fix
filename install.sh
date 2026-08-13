#!/usr/bin/env bash
# ============================================================
# One-shot install untuk VPS baru:
#   - clone repo ini
#   - apply patch 9router
#   - restart service & verifikasi
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Apply patch..."
bash patch-9router-ua.sh

echo "==> Restart 9router..."
if systemctl list-unit-files 2>/dev/null | grep -q '^9router.service'; then
  systemctl restart 9router 2>/dev/null || sudo systemctl restart 9router
  sleep 5
else
  echo "Service 9router tidak ditemukan di systemd. Start manual."
fi

echo "==> Verifikasi (oc/deepseek-v4-flash-free)..."
BASE_URL="${R9_BASE_URL:-http://127.0.0.1:20128}"
API_KEY="${R9_API_KEY:-sk-c60b5b633b8ba408-e8xm8m-f08be238}"
curl -s --max-time 30 "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"oc/deepseek-v4-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
  -w "\nHTTP:%{http_code}\n" || echo "Gagal konek ke 9router"

echo "==> Selesai."