#!/usr/bin/env bash
# ============================================================
# One-shot install untuk VPS baru (tanpa setting manual):
#   - auto-detect API key 9router dari DB / opencode config
#   - apply patch (UA rotation + retry 429)
#   - restart service 9router
#   - sinkronkan apiKey 9router ke ~/.config/opencode/opencode.jsonc
#   - verifikasi oc/deepseek-v4-flash-free
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ------------------------------------------------------------
# Auto-detect API key (prioritas: env > DB 9router > opencode config)
# ------------------------------------------------------------
detect_api_key() {
  if [ -n "${R9_API_KEY:-}" ]; then echo "$R9_API_KEY"; return; fi

  if [ -f "$HOME/.9router/db/data.sqlite" ]; then
    KEY=$(python3 - "$HOME/.9router/db/data.sqlite" <<'EOF'
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    r = c.execute("SELECT key FROM apiKeys WHERE isActive=1 ORDER BY createdAt LIMIT 1").fetchone()
    print(r[0] if r else "")
except Exception:
    print("")
EOF
    )
    [ -n "$KEY" ] && { echo "$KEY"; return; }
  fi

  if [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
    KEY=$(python3 - <<'EOF'
import json, os
try:
    d = json.load(open(os.path.expanduser("~/.config/opencode/opencode.jsonc")))
    pr = d.get("provider", {}).get("9router", {}).get("options", {})
    print(pr.get("apiKey", ""))
except Exception:
    print("")
EOF
    )
    [ -n "$KEY" ] && { echo "$KEY"; return; }
  fi

  echo ""
}

# ------------------------------------------------------------
# Auto-detect base URL
# ------------------------------------------------------------
detect_base_url() {
  if [ -n "${R9_BASE_URL:-}" ]; then echo "$R9_BASE_URL"; return; fi
  if [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
    URL=$(python3 - <<'EOF'
import json, os
try:
    d = json.load(open(os.path.expanduser("~/.config/opencode/opencode.jsonc")))
    u = d.get("provider", {}).get("9router", {}).get("options", {}).get("baseURL", "")
    print(u)
except Exception:
    print("")
EOF
    )
    [ -n "$URL" ] && { echo "$URL"; return; }
  fi
  echo "http://127.0.0.1:20128"
}

API_KEY=$(detect_api_key)
BASE_URL=$(detect_base_url)

echo "==> API key  : ${API_KEY:-<tidak ditemukan>}"
echo "==> Base URL : $BASE_URL"

if [ -z "$API_KEY" ]; then
  echo "WARN: API key tidak terdeteksi. Gunakan env R9_API_KEY."
  echo "      Verifikasi akan dilewati (patch tetap diterapkan)."
fi

echo "==> Apply patch 9router..."
bash patch-9router-ua.sh

echo "==> Restart 9router..."
systemctl restart 9router 2>/dev/null || sudo systemctl restart 9router 2>/dev/null || true
sleep 5
if systemctl is-active 9router >/dev/null 2>&1; then
  echo "9router aktif."
else
  echo "WARN: 9router.service tidak aktif. Start manual."
fi

# ------------------------------------------------------------
# Sinkronkan apiKey/baseURL 9router ke opencode.jsonc
# ------------------------------------------------------------
if [ -n "$API_KEY" ] && [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
  python3 - "$API_KEY" "$BASE_URL" <<'EOF'
import json, sys, os
cfg = os.path.expanduser("~/.config/opencode/opencode.jsonc")
key, url = sys.argv[1], sys.argv[2]
try:
    with open(cfg) as f:
        d = json.load(f)
    pr = d.setdefault("provider", {}).setdefault("9router", {})
    opts = pr.setdefault("options", {})
    changed = False
    if opts.get("apiKey") != key:
        opts["apiKey"] = key; changed = True
    if opts.get("baseURL") != url:
        opts["baseURL"] = url; changed = True
    if changed:
        with open(cfg, "w") as f:
            json.dump(d, f, indent=2)
            f.write("\n")
        print("[OK] opencode.jsonc disinkronkan (apiKey/baseURL 9router).")
    else:
        print("[SKIP] opencode.jsonc sudah sesuai.")
except Exception as e:
    print(f"[WARN] opencode.jsonc skip: {e}")
EOF
else
  echo "[SKIP] opencode.jsonc tidak ditemukan / apiKey kosong."
fi

# ------------------------------------------------------------
# Verifikasi
# ------------------------------------------------------------
if [ -n "$API_KEY" ]; then
  V1="${BASE_URL%/v1}"
  echo "==> Verifikasi oc/deepseek-v4-flash-free ..."
  RES=$(curl -s --max-time 30 "$V1/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"oc/deepseek-v4-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
    -w "\nHTTP:%{http_code}")
  echo "$RES" | tail -c 300
  echo
else
  echo "==> Verifikasi dilewati (tidak ada API key)."
fi

echo "==> Selesai."