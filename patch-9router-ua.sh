#!/usr/bin/env bash
# ============================================================
# Patch 9Router: OpenCode Free (oc/*-free) — fix UA + auto retry
# ============================================================
# Masalah: 9router kirim User-Agent default (node/9Router) ke
# opencode.ai/zen, padahal zen free HANYA menerima UA "opencode/*".
# Akibatnya oc/deepseek-v4-flash-free dkk kena 429 FreeUsageLimitError.
#
# Fix:
#   1. buildHeaders() -> User-Agent random opencode/* (rotasi)
#   2. shouldRetry()  -> auto retry saat 429, maks 3x, UA baru tiap attempt
#   3. Hapus strategi proxy pool untuk provider opencode (free proxies
#      lambat/gagal; direct sudah cukup setelah UA fix)
#
# Script IDEMPOTENT & portable:
#   - Bisa dijalankan di VPS baru (fresh install 9router) maupun yang
#     sudah ter-patch versi sebelumnya.
#   - Membuat backup file asli (.orig.bak) otomatis.
#
# Cara pakai:
#   bash patch-9router-ua.sh
#   systemctl restart 9router   (jika service sudah jalan)
# ============================================================
set -uo pipefail

APP_DIR=$(ls -d "$HOME"/.nvm/versions/node/v22.23.1/lib/node_modules/9router/app 2>/dev/null)
[ -z "$APP_DIR" ] && APP_DIR=$(ls -d "$(npm root -g 2>/dev/null)/9router/app" 2>/dev/null)
[ -z "$APP_DIR" ] && { echo "ERROR: tidak menemukan direktori 9router app"; exit 1; }

NVM_NODE="$HOME/.nvm/versions/node/v22.23.1/bin/node"
[ -x "$NVM_NODE" ] || NVM_NODE=$(command -v node)
[ -z "$NVM_NODE" ] && { echo "ERROR: node tidak ditemukan"; exit 1; }

CHUNK=""
for cand in "$APP_DIR"/.next-cli-build/server/chunks/318.js \
            "$APP_DIR"/.next-build/server/chunks/318.js \
            "$APP_DIR"/.next/server/chunks/318.js; do
  [ -f "$cand" ] && CHUNK="$cand" && break
done
[ -z "$CHUNK" ] && { echo "ERROR: chunk 318.js tidak ditemukan di $APP_DIR"; exit 1; }
echo "Chunk : $CHUNK"

BAK="${CHUNK}.orig.bak"
[ -f "$BAK" ] || cp "$CHUNK" "$BAK"
echo "Backup: $BAK"

echo "Apply patch..."
"$NVM_NODE" -e '
const fs = require("fs");
const f = process.argv[1];
let s = fs.readFileSync(f, "utf8");

// State FULL (sudah ter-patch, rotasi UA + retry): marker array UA
const MARKER = `"opencode/1.18.18","opencode/1.19.2"`;
if (s.includes(MARKER)) {
  console.log("[SKIP] patch UA/retry sudah diterapkan.");
  process.exit(0);
}

const FULL =
  `Authorization:"Bearer public","x-opencode-client":"desktop",` +
  `"User-Agent":["opencode/1.18.18","opencode/1.19.2","opencode/1.17.6","opencode/2.0.0","opencode/1.16.9"][Math.floor(Math.random()*5)],` +
  `Accept:"text/event-stream"}}shouldRetry(a,b){return a===429&&b<3}`;

// v1 anchor: UA fixed 1.18.18, tanpa retry
const v1 = `"User-Agent":"opencode/1.18.18",Accept:"text/event-stream"}}`;
// v0 anchor: original (tanpa User-Agent)
const v0 = `Authorization:"Bearer public","x-opencode-client":"desktop",Accept:"text/event-stream"}}`;

const apply = (anchor) => {
  const n = s.split(anchor).length - 1;
  if (n !== 1) {
    console.error(`ABORT: anchor tidak unik (${n}). Hentikan.`);
    process.exit(1);
  }
  const prefix = s.slice(0, s.indexOf(anchor));
  const prefix_head = prefix.slice(0, prefix.lastIndexOf("buildHeaders(){return{"));
  fs.writeFileSync(f, prefix_head + "buildHeaders(){return{" + FULL + s.slice(s.indexOf(anchor) + anchor.length));
  console.log("[OK] patch UA/retry diterapkan.");
  process.exit(0);
};

if (s.includes(v1)) apply(v1);
else if (s.includes(v0)) apply(v0);
else {
  console.error("ABORT: anchor v0/v1 tidak ditemukan. Versi 9router mungkin berbeda.");
  process.exit(1);
}
' "$CHUNK" || { echo "Patch gagal."; exit 1; }

# ------------------------------------------------------------
# Hapus strategi proxy untuk provider opencode (idempotent)
# ------------------------------------------------------------
DB="$HOME/.9router/db/data.sqlite"
if [ -f "$DB" ]; then
  python3 - "$DB" <<'EOF'
import sqlite3, json, sys
conn = sqlite3.connect(sys.argv[1])
try:
    row = conn.execute("SELECT data FROM settings WHERE id=1").fetchone()
    if row is None:
        print("[SKIP] settings kosong"); raise SystemExit
    d = json.loads(row[0])
    ps = d.get("providerStrategies", {})
    if "opencode" in ps:
        del ps["opencode"]
        d["providerStrategies"] = ps
        conn.execute("UPDATE settings SET data=? WHERE id=1", (json.dumps(d),))
        conn.commit()
        print("[OK] strategi proxy opencode dihapus.")
    else:
        print("[SKIP] tidak ada strategi proxy opencode.")
except Exception as e:
    print(f"[WARN] DB skip: {e}")
finally:
    conn.close()
EOF
else
  echo "[WARN] DB 9router tidak ditemukan: $DB"
fi

echo "Selesai. Restart: systemctl restart 9router"