# 9Router OpenCode Free Fix

Patch untuk 9Router agar model `oc/*-free` (OpenCode Free / `opencode.ai/zen`) tidak kena **429 FreeUsageLimitError**.

## Masalah

9router mengirim request ke `opencode.ai/zen/v1` dengan `User-Agent` bawaan Node (`node` / `9Router/...`),
padahal zen free tier **hanya menerima request dengan `User-Agent: opencode/*`**.
Akibatnya `oc/deepseek-v4-flash-free`, `oc/hy3-free`, `oc/mimo-v2.5-free` dkk selalu gagal 429
(bukan karena proxy, bukan karena akun, murni filter User-Agent).

Bukti: request ke zen dengan `User-Agent: opencode/1.18.18` → `200`; tanpa/UA lain → `429`.

## Perbaikan

Patch satu file `.../9router/app/.next-cli-build/server/chunks/318.js`:

1. **Rotasi User-Agent** — `buildHeaders()` memilih UA `opencode/*` acak dari 5 versi
   (`1.18.18`, `1.19.2`, `1.17.6`, `2.0.0`, `1.16.9`).
2. **Auto-retry saat 429** — `shouldRetry()` di-override: jika zen balas 429, request diulang
   otomatis (maks 3 percobaan), setiap percobaan pakai UA baru.
3. **Hapus strategi proxy** untuk provider `opencode` di DB 9router (free public proxy lambat/gagal;
   direct sudah cukup setelah UA fix).

## Cara pakai

### Di VPS baru (setelah install 9router)

```bash
git clone https://github.com/ikiimel007-oss/9router-opencode-fix.git
cd 9router-opencode-fix
bash install.sh
```

`install.sh` = apply patch + restart service + verifikasi `oc/deepseek-v4-flash-free`.

### Manual

```bash
bash patch-9router-ua.sh
systemctl restart 9router
```

Script **idempotent**:
- Fresh install (`v0`, tanpa UA) → diterapkan
- Sudah ter-patch sebagian (`v1`, UA fixed tanpa retry) → di-upgrade
- Sudah ter-patch penuh → skip

Backup file asli otomatis dibuat di `318.js.orig.bak` di samping chunk.

## Verifikasi cepat

```bash
curl -s http://127.0.0.1:20128/v1/chat/completions \
  -H "Authorization: Bearer <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"oc/deepseek-v4-flash-free","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
```

Harapannya `HTTP 200` dalam ~1–2 detik.

## Catatan

- Patch ada di file npm 9router (`node_modules/...`) → **hilang saat package 9router di-update**.
  Jalankan ulang `bash patch-9router-ua.sh` setelah update.
- File `chunks/318.js.orig.bak` di repo ini adalah backup original untuk restore jika anchor berubah
  di versi 9router yang lebih baru.
- Script ini tidak mengandung API key/token. API key 9router diambil dari env
  `R9_API_KEY` (default contoh di `install.sh`).