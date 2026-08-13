#!/usr/bin/env bash
# ============================================================
# One-shot bootstrap 9router + OpenCode Free fix (tanpa setting)
#
# 1. Install 9router bila belum ada (Node v22 nvm + npm -g)
# 2. Buat start script & systemd service (9router.service)
# 3. Start, inisialisasi DB (~/.9router), auto-detect API key
# 4. Apply patch (UA rotation + retry 429)
# 5. Sinkronkan apiKey/baseURL + model oc/*-free ke opencode config
# 6. Verifikasi oc/deepseek-v4-flash-free
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

NVM_BIN="$HOME/.nvm/versions/node/v22.23.1/bin"
NVM_NODE="$NVM_BIN/node"
NVM_NPM="$NVM_BIN/npm"
PKG_DIR="$HOME/.nvm/versions/node/v22.23.1/lib/node_modules/9router"
APP_DIR="$PKG_DIR/app"
DB="$HOME/.9router/db/data.sqlite"
START_SCRIPT="$HOME/start-9router.sh"
OC_CONFIG="$HOME/.config/opencode/opencode.jsonc"

# gunakan node v22 (nvm) jika ada, agar npm global terpasang di sana
[ -x "$NVM_NODE" ] && export PATH="$NVM_BIN:$PATH"
NODE_BIN=$(command -v node)

ensure_9router() {
  if [ -d "$APP_DIR" ]; then
    echo "==> 9router sudah terinstall: $PKG_DIR"
    return 0
  fi

  echo "==> 9router belum ada. Menginstall 9router..."
  if [ -z "$NODE_BIN" ]; then
    echo "ERROR: node tidak ditemukan. Install Node v22 dulu:"
    echo "  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
    echo "  . ~/.nvm/nvm.sh && nvm install 22"
    return 1
  fi
  NODE_MAJOR=$("$NODE_BIN" -v 2>/dev/null | tr -d 'v' | cut -d. -f1)
  if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -lt 18 ] 2>/dev/null; then
    echo "ERROR: node terlalu lama ($("$NODE_BIN" -v)). Butuh Node >=18 (pakai nvm v22)."
    return 1
  fi

  npm install -g 9router@0.5.50 || { echo "ERROR: gagal npm install -g 9router"; return 1; }
  [ -d "$APP_DIR" ] || { echo "ERROR: $APP_DIR tidak ada setelah install."; return 1; }

  # ---- start script ----
  cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash
set -e
PKG_DIR="$PKG_DIR"
APP_DIR="\$PKG_DIR/app"
RUNTIME_NM="\$HOME/.9router/runtime/node_modules"
BUNDLED_NM="\$PKG_DIR/app/node_modules"
export NODE_PATH="\$RUNTIME_NM:\$BUNDLED_NM"
export PORT="\${PORT:-20128}"
export HOSTNAME="0.0.0.0"
export NODE_ENV=production
cd "\$APP_DIR"
exec "$NVM_NODE" --dns-result-order=ipv4first --max-old-space-size=6144 "\$APP_DIR/custom-server.js"
EOF
  chmod +x "$START_SCRIPT"
  echo "   start script: $START_SCRIPT"

  # ---- systemd unit ----
  if [ -w /etc/systemd/system ]; then
    cat > /etc/systemd/system/9router.service <<EOF
[Unit]
Description=9Router Server (standalone)
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
ExecStart=/bin/bash $START_SCRIPT
Restart=always
RestartSec=3
Environment=HOME=$HOME

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable 9router >/dev/null 2>&1 || true
    echo "   systemd unit: /etc/systemd/system/9router.service"
  else
    echo "   WARN: /etc/systemd/system tidak writable (jalankan sebagai root/sudo). Start manual:"
    echo "         nohup bash $START_SCRIPT >/tmp/9router.log 2>&1 &"
    nohup bash "$START_SCRIPT" >/tmp/9router.log 2>&1 &
  fi

  echo "   Start 9router..."
  systemctl restart 9router 2>/dev/null || nohup bash "$START_SCRIPT" >/tmp/9router.log 2>&1 &
}

# ------------------------------------------------------------
# Auto-detect API key (prioritas: env > DB > opencode config)
# ------------------------------------------------------------
detect_api_key() {
  if [ -n "${R9_API_KEY:-}" ]; then echo "$R9_API_KEY"; return; fi

  if [ -f "$DB" ]; then
    KEY=$(python3 - "$DB" <<'EOF'
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

  if [ -f "$OC_CONFIG" ]; then
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
  if [ -f "$OC_CONFIG" ]; then
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

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
ensure_9router || exit 1

# pastikan DB ada & punya API key (tunggu 9router generate)
for _ in $(seq 1 30); do
  KEY=$(detect_api_key)
  [ -n "$KEY" ] && break
  sleep 2
done

if [ -z "$KEY" ]; then
  echo "==> API key belum ada, membuat key baru di DB..."
  python3 - "$DB" <<'EOF'
import sqlite3, sys, secrets, uuid
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE IF NOT EXISTS apiKeys (
  id TEXT PRIMARY KEY, key TEXT NOT NULL, name TEXT,
  machineId TEXT, isActive INTEGER DEFAULT 1, createdAt TEXT NOT NULL)""")
r = c.execute("SELECT key FROM apiKeys WHERE isActive=1 LIMIT 1").fetchone()
if not r:
    c.execute("INSERT INTO apiKeys VALUES (?, ?, 'Default Key', ?, 1, ?)",
              (str(uuid.uuid4()), "sk-" + secrets.token_hex(16), "", str(int(__import__('time').time()*1000))))
    c.commit()
    print("[OK] API key dibuat.")
c.close()
EOF
fi

# pastikan model oc/*-free terdaftar di DB 9router
python3 - "$DB" <<'EOF'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS kv (scope TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (scope, key))")
mods = {
    "oc|deepseek-v4-flash-free|llm": {"providerAlias": "oc", "id": "deepseek-v4-flash-free", "type": "llm", "name": "deepseek-v4-flash-free"},
    "oc|hy3-free|llm":               {"providerAlias": "oc", "id": "hy3-free", "type": "llm", "name": "hy3-free"},
    "oc|mimo-v2.5-free|llm":         {"providerAlias": "oc", "id": "mimo-v2.5-free", "type": "llm", "name": "mimo-v2.5-free"},
}
for k, v in mods.items():
    c.execute("INSERT OR IGNORE INTO kv VALUES (?, ?, ?)", ("customModels", k, json.dumps(v)))
c.commit()
c.close()
print("[OK] model oc/*-free dipastikan ada di DB 9router.")
EOF

API_KEY=$(detect_api_key)
BASE_URL=$(detect_base_url)
echo "==> API key  : ${API_KEY:-<kosong>}"
echo "==> Base URL : $BASE_URL"

echo "==> Apply patch 9router..."
bash patch-9router-ua.sh

echo "==> Restart 9router..."
systemctl restart 9router 2>/dev/null || sudo systemctl restart 9router 2>/dev/null || true
sleep 5
systemctl is-active 9router >/dev/null 2>&1 && echo "9router aktif." || echo "WARN: 9router tidak aktif (cek /tmp/9router.log)."

# ------------------------------------------------------------
# Sinkronkan ke opencode config (buat bila belum ada)
# ------------------------------------------------------------
python3 - "$API_KEY" "$BASE_URL" "$OC_CONFIG" <<'EOF'
import json, os, sys
key, url, cfg = sys.argv[1], sys.argv[2], sys.argv[3]
oc_models = ["oc/deepseek-v4-flash-free", "oc/hy3-free", "oc/mimo-v2.5-free"]
if os.path.exists(cfg):
    with open(cfg) as f:
        d = json.load(f)
    created = False
else:
    d = {"$schema": "https://opencode.ai/config.json"}
    created = True
pr = d.setdefault("provider", {}).setdefault("9router", {})
pr["npm"] = "@ai-sdk/openai-compatible"
pr["name"] = "9Router"
opts = pr.setdefault("options", {})
if key: opts["apiKey"] = key
opts["baseURL"] = url
m = pr.setdefault("models", {})
for mm in oc_models:
    m.setdefault(mm, {})
if key and (created or opts.get("apiKey") != key or opts.get("baseURL") != url):
    with open(cfg, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"[OK] opencode config disinkronkan: {cfg} ({'dibuat' if created else 'diupdate'})")
else:
    print("[SKIP] opencode config sudah sesuai.")
EOF

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

echo "==> Selesai. Untuk opencode: pastikan ~/.config/opencode/opencode.jsonc memuat provider 9router."