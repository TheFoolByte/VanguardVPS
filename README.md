# VanguardVPS — Cloud AI Workspace (Hermes Agent + 9router)

Ubuntu 24.04 SSH VPS di [Railway](https://railway.com) lengkap dengan:
- **[Hermes Agent](https://github.com/NousResearch/hermes-agent)**: AI Autonomous Agent (CLI, Web Dashboard port 8686, & Messaging Gateway untuk Telegram / Discord / WhatsApp).
- **[9router](https://github.com/decolua/9router)**: AI Proxy & Web Routing Dashboard (port 20128).
- **Dual GitHub Auto-Backup**: Otomatis backup & restore ke 2 private repository terpisah (1 untuk 9router & data sistem, 1 khusus untuk database session, memory, skills, dan config Hermes Agent).

---

## Fitur & Spesifikasi

| Komponen | Spesifikasi & Port |
|---|---|
| **OS** | Ubuntu 24.04 LTS (Akses Root) |
| **SSH** | TCP Proxy Port **22** (Akses terminal dari Termius, JuiceSSH, laptop) |
| **Hermes Agent** | CLI (`hermes`), Web Dashboard Port **8686**, Gateway Bot background |
| **9router** | Dashboard Port **20128** (Multi-provider AI Router) |
| **Runtime** | Python 3, `uv`, Node.js LTS, git, build-essential, tmux |
| **Sistem Backup** | Dual Auto-Backup ke 2 Private Repo GitHub via Personal Access Token |

---

## Panduan Deploy ke Railway (Aman & Tanpa Bocor Kredensial)

Repo ini dirancang agar **kredensial rahasia kamu TIDAK di-commit ke GitHub**, melainkan diinput langsung via **Railway Variables**.

### Langkah 1: Deploy dari GitHub
1. Buat project baru di Railway: [railway.com/new](https://railway.com/new).
2. Pilih **Deploy from GitHub repo**.
3. Pilih repo ini (`TheFoolByte/Railway-Ubuntu-Docker` atau repo fork kamu).
4. Klik **Deploy**.

### Langkah 2: Atur Variabel Rahasia di Railway
Buka Service kamu di Railway → Masuk ke tab **Variables** → Tambahkan variabel berikut:

| Variable | Wajib/Opsional | Deskripsi |
|---|---|---|
| `ROOT_PASSWORD` | **Wajib** | Password untuk login root SSH dan dashboard 9router. |
| `GITHUB_TOKEN` | Disarankan | GitHub Personal Access Token (scope `repo`) untuk mengaktifkan fitur dual auto-backup. |
| `AUTHORIZED_KEYS` | Opsional | SSH Public Key (ed25519 / rsa) agar bisa login SSH tanpa ketik password. |
| `HERMES_ENABLED` | Opsional | `true` (default) untuk mengaktifkan Hermes Agent. |
| `HERMES_DASHBOARD_PORT` | Opsional | Port web dashboard Hermes (default `8686`). |
| `HERMES_GITHUB_REPO` | Opsional | Nama private repo backup Hermes. Jika dikosongkan, otomatis membuat `vanguard-vps-hermes-<project-id>`. |
| `GITHUB_REPO` | Opsional | Nama private repo backup 9router. Jika dikosongkan, otomatis membuat `vanguard-vps-src-<project-id>`. |

> **Keamanan:** Railway Variables memiliki prioritas tertinggi dan secara otomatis menimpa file `config.json`. Kode di GitHub tetap aman dan bersih tanpa ada token/password yang terekspos.

### Langkah 3: Setup Networking Railway
Buka Service kamu → Masuk ke tab **Settings** → **Networking**:
1. **TCP Proxy**: Buat proxy mengarah ke port **22** (untuk akses SSH publik).
2. **Public Domain 1**: Generate Domain mengarah ke port **20128** (Dashboard 9router).
3. **Public Domain 2**: Generate Domain mengarah ke port **8686** (Web Dashboard Hermes Agent).

---

## Cara Akses

### 1. Masuk via SSH
Gunakan host dan port yang diberikan oleh TCP Proxy Railway:
```bash
ssh root@<TCP_HOST> -p <TCP_PORT>
```
*Contoh:*
```bash
ssh root@mainline.proxy.rlwy.net -p 39381
```

### 2. Menggunakan Hermes Agent

- **Lewat CLI (didalam SSH):**
  ```bash
  hermes chat -q "Halo Hermes!"    # single query
  hermes                          # sesi interaktif
  hermes gateway status           # cek status bot
  ```

- **Lewat Web Dashboard:**
  Buka Public Domain Railway port **8686** di browser perangkat apa pun (HP / tablet / PC).

- **Lewat Bot Messaging (Telegram / Discord / WhatsApp):**
  Hermes Gateway sudah otomatis berjalan di background. Kamu bisa mengonfigurasi bot via CLI:
  ```bash
  hermes gateway setup
  ```
  Atau via Web Dashboard. Begitu token bot diisi, kamu bisa langsung chatting dengan Hermes dari Telegram / Discord / WhatsApp kapan saja tanpa perlu menyalakan laptop!

### 3. Dashboard 9router
Buka Public Domain Railway port **20128** di browser.
- Login password = nilai `ROOT_PASSWORD` yang kamu atur.

---

## Dual Auto-Backup System

Setiap kali Railway melakukan rebuild atau pindah container baru, data kamu tidak akan hilang:

1. **Repo 1 (`vanguard-vps-src-...`)**: Mem-backup database 9router dan file `/root`.
2. **Repo 2 (`vanguard-vps-hermes-...`)**: Mem-backup seluruh direktori `~/.hermes/` (riwayat percakapan SQLite `state.db`, memori persisten, custom skills, dan konfigurasi API keys).

Saat container pertama kali menyala (*booting*), kedua repositori ini otomatis di-*pull* dan di-*restore*, lalu *watcher background* akan otomatis melakukan sinkronisasi berkala ke GitHub setiap 180 detik.

**Perintah Cek Status Backup (di dalam SSH):**
```bash
src-sync --status       # Cek status backup 9router
hermes-sync --status    # Cek status backup Hermes Agent
src-sync backup         # Trigger backup instan 9router
hermes-sync backup      # Trigger backup instan Hermes
usage                   # Pantau pemakaian kredit & sisa jam Railway
```

---

## Lisensi
MIT License.
