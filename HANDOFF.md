# RomM on a no-root, no-container, subpath-only server - handoff document

This document is the full context for maintaining a custom RomM installation. Assume nothing beyond what is written here. It covers the goal, the server and its quirks, every design decision and why it was made, how the RomM source is patched and how to redo that for new RomM versions, what was tested, what was not, and the problems already hit and solved.

Files in this bundle (keep them together in one folder, e.g. `~/romm-installer/`):

| File | Role |
|---|---|
| `install.sh` | Installs, repairs and upgrades everything. Idempotent. The single source of truth for the setup. |
| `romm-run` | Launcher for every runtime component; every systemd unit calls it. Copied to `~/opt/romm/bin/romm-run` by the installer. |
| `subpath.py` | Makes RomM's frontend work under a URL prefix (`/romm`). Called by `install.sh`. |
| `install-with-dbadmin.sh` | Wrapper: runs `install.sh` (passing all arguments and environment) with `DB_ADMIN_USER`/`DB_ADMIN_PASSWD` taken from the environment (then saved) or from `.romm-dbadmin.env` next to it; prompts to create that file if missing/empty/incomplete; refuses a file that is a symlink, not owned by the user, or readable/writable by group/others. The file is parsed, never executed, and written mode 600 with single-quoted values (also loadable with `set -a; . file`). The credentials are deliberately never stored in `romm.env`, which every RomM service loads. |
| `dbcheck.py` | Diagnostic: shows which MariaDB instance a `host:port` reaches and how it sees the client. |
| `threadprobe.py` | Diagnostic: finds what limits thread creation (count cap vs memory cap). |
| `README.md` | Short user-facing guide (install, operations, settings, providers, companion apps, troubleshooting). Refreshed 2026-10-30; this document stays the authoritative technical reference. |

---

## 1. Goal

Run [RomM](https://github.com/rommapp/romm) (a self-hosted retro game library manager with in-browser emulation) on the user's shared seedbox, under these hard constraints:

1. **No root / no sudo.** Everything runs as the normal user.
2. **No Docker or Podman** for the user. RomM officially ships only as a Docker image; running it from source ("bare metal") is undocumented upstream (RomM's FAQ says it is undocumented but should work).
3. **No subdomains.** RomM must be served under a path: `https://<user>.<host>.<tld>/romm/`. RomM has **no base-path setting** and hardcodes root-absolute paths everywhere, so this required patching.
4. **Low resources**: about 1 GiB RAM or less per service and at most 2 CPU threads per service, on a box that crashes thread-hungry programs.
5. Use what the server already provides (its nginx and its MariaDB) and stay inside the allowed port range.

Status as of 2026-10-24: **working in production** on the user's server. RomM 5.4.1 is installed under `~/opt/romm`, reachable at `https://<user>.<host>.<tld>/romm/`, running as systemd user services. IGDB and RetroAchievements metadata work, RAHasher is built. ScreenScraper is not working yet (needs the user's own developer credentials, see section 11).

---

## 2. The user and how to work with them

- Name: Gal. Software developer (Windows C++/C# by trade), comfortable with Linux, communicates casually.
- Strongly prefers **accuracy over speculation** and **empirical verification** over documentation-only answers. Reproduce problems and test fixes before claiming they work; clearly label anything unverified.
- Prefers **complete working solutions**, not sketches.
- Uses speech-to-text; ignore stray odd words in messages.
- Formatting preference: **plain hyphens, never em dashes or en dashes**.
- Redacts hostnames, usernames and IPs when pasting output (placeholders like `USER_NAME`, `HOSTNAME`, `DOMAIN.TLD`).

---

## 3. The server (facts gathered during the project)

| Fact | Value / detail | How known |
|---|---|---|
| Provider | Ultra.cc shared seedbox | user |
| Privileges | No sudo; no Docker/Podman for the user | user |
| Package tools | Homebrew (Linuxbrew) and pipx, as the user. No system Python and no uv initially (Python only via brew). | user |
| Node | Node 26.12.1 installed via brew, unused by other apps (OK to add other versions) | user |
| CPUs | 128 (`nproc`) | `threadprobe.py` |
| Virtual memory limit | `ulimit -v` = 10000000 KiB (about 10 GB) **per process**. This is the limit that breaks thread-heavy programs (see 9.2). | `ulimit -a`, `threadprobe.py` |
| Process limit | `ulimit -u` = 2000; user slice `pids.max` 1360971; not a practical constraint | user's checks |
| Stack limit | 8 MiB default thread stacks | `ulimit -a` |
| Front nginx | Provided by Ultra.cc, listens on port **12740**. Per-app `location` blocks go into (or are symlinked into) **`~/.apps/nginx/proxy.d/`**, which is included inside its `server` block. The user reloads it the usual Ultra.cc way after changes. | user |
| MariaDB | Installed via Ultra.cc's app installer. Port **12715**. Version `11.4.4-MariaDB-log` (**binary logging is on**). Runs in a **Docker container on the same machine** (provider-managed): connections from the host arrive as `172.17.0.1` (Docker bridge), server hostname looks like `HOSTNAME-USER_NAME`. The user has its root login. | install errors, `dbcheck.py` |
| Hostnames | `HOSTNAME.DOMAIN.TLD` (main/SSH) and `HOSTNAME-direct.DOMAIN.TLD` (shown by Ultra.cc's panel for MariaDB) are **two public IPs of the same machine**; `127.0.0.1:12715` and `HOSTNAME-direct.DOMAIN.TLD:12715` reach the **same** MariaDB instance (identical server_id, hostname, uptime). | `getent hosts`, `hostname -I`, `dbcheck.py` |
| Port range | Self-built apps must use ports **37715-37749** | user |
| ROMs | `~/games` (platform folders directly inside, e.g. `~/games/gba/`) | user |
| App location convention | Custom apps live under `~/opt/<app>` | user |
| Other apps on the box | copyparty (pipx, systemd user service, behind the front nginx at `/copyparty`), Jellyfin (HTTPS-proxied, JellyEmu plugin), aria2 + AriaNg | user |
| systemd | User services work (copyparty already runs as one), so lingering is effectively available | copyparty setup, RomM units running |
| User's `~/.bashrc` workarounds | `HOMEBREW_MAKE_JOBS=2`, `HOMEBREW_DOWNLOAD_CONCURRENCY=2` (brew had crashed from too many threads) | user |

---

## 4. Architecture

```
Browser ──HTTPS──> Ultra.cc edge ──> front nginx :12740 (provided)
                                      │  ~/.apps/nginx/proxy.d/romm.conf  (symlink, generated)
                                      │  strips "/romm", proxies to 127.0.0.1:ROMM_PORT
                                      ▼
                     internal nginx 127.0.0.1:ROMM_PORT   (built by us: nginx + njs + mod_zip)
                       │ static frontend (~/opt/romm/www), X-Accel internal file serving,
                       │ mod_zip multi-file downloads, sub_filter on /api JSON
                       ▼
                     gunicorn (uvicorn worker) 127.0.0.1:DEV_PORT   <- RomM backend (FastAPI)
                       │
         ┌─────────────┼──────────────────────────────┐
         ▼             ▼                              ▼
   Valkey :REDIS_PORT  MariaDB 127.0.0.1:12715       RQ workers (default/high/low, scans) + rq cron
   (ours, password)    (provided, Docker container)  (ours)
```

Runtime components and why each exists:

| Component | Why |
|---|---|
| Internal nginx (custom build) | RomM's backend relies on nginx features: `X-Accel-Redirect` to internal `/library/` etc. locations for file serving, **mod_zip** for on-the-fly multi-file zip downloads (multi-disc games), **njs** (`decode.js`) to build `.m3u` playlists inside those zips. The provided nginx can't load these modules, so we build our own, statically, into `~/opt/romm/nginx`. |
| gunicorn backend | RomM's API, same flags as the official container's init script. |
| RQ `worker` (queues `high default low`) and `scan-worker` (queue `scans`) | Background tasks and library scans, as in the official container. Scans only run if a worker listens on `scans`. |
| `rq cron` | RomM's scheduled tasks (`tasks.cron_config`). |
| Valkey | Required by RQ and RomM caching; not provided by the server. Password-protected, local only. |
| MariaDB | Provided by the server; we only create a database and user in it. |
| Optional: `romm-watcher` | Rescan on filesystem change (off by default). |
| Optional: `romm-streaming-worker` | Only for RomM's streaming feature; its tasks are only registered when streaming is configured. |

---

## 5. Directory layout (`ROMM_HOME`, default `~/opt/romm`)

| Path | Contents |
|---|---|
| `romm.env` | **All configuration and secrets** (mode 600). Generated once, never overwritten. Sourced by bash (`set -a`), so plain `KEY=value`, no inline comments. |
| `app/` | Shallow git clone of RomM at the release tag, plus `app/.venv` (Python 3.14 via uv). Source patches are applied here on every install run (after `git checkout --force` resets them). |
| `www/` | Built frontend + `frontend/assets` + emulators. Replaced atomically (`www.new` -> `www`). |
| `data/` | `ROMM_BASE_PATH`: `library/` (contains `roms -> ~/games` symlink), `resources/` (covers etc.), `assets/` (saves, states, ...), `config/config.yml`. |
| `tmp/` | `ROMM_TMP_PATH` (also nginx cache path `tmp/cache`). |
| `nginx/` | Our nginx build (`sbin/nginx`), `conf/nginx.conf`, `conf/conf.d/default.conf`, `conf/js/decode.js`, `romm-proxy.conf` (the front-proxy snippet), `.stamp` (build fingerprint). |
| `valkey/` | `valkey.conf` (mode 600, holds the password), `data/`. |
| `tools/bin/` | Symlinks to the exact binaries services use (`node` -> brew `node@24`, `7zz`, `bsdtar`, `valkey-server`, `valkey-cli`, `uv`) plus installed `rom-converto` and `RAHasher`. |
| `tools/npm-<ver>/` | Pinned npm, run directly by Node 24. |
| `lib/` | Only libraries the loader can't find (e.g. brew's `libmagic.so.1` if needed). |
| `bin/romm-run` | Launcher. |
| `build/` | Build trees, downloads cache (`build/downloads`), logs: `frontend-build.log`, `nginx-*.log`, `migrations.log`. |
| `run/` | gunicorn pid, generated gunicorn logging config. |

Outside `ROMM_HOME`: systemd units in `~/.config/systemd/user/romm*.{service,target}`; the symlink `~/.apps/nginx/proxy.d/romm.conf`.

---

## 6. `install.sh` walkthrough with rationale

Run as the normal user. Typical commands:

```bash
# first install (DOMAIN placeholder: use the real public URL incl. /romm)
DEFAULT_BASE_URL=https://USER.HOST.TLD/romm DB_ADMIN_USER=root DB_ADMIN_PASSWD='...' ./install.sh
# repair / re-apply (always pass the admin login if migrations might be pending)
DB_ADMIN_USER=root DB_ADMIN_PASSWD='...' ./install.sh
# upgrade
ROMM_VERSION=X.Y.Z DB_ADMIN_USER=root DB_ADMIN_PASSWD='...' ./install.sh
# same, with the admin login kept in ./.romm-dbadmin.env (created on first use)
ROMM_VERSION=X.Y.Z ./install-with-dbadmin.sh
# add RAHasher (built once; later runs skip it while the binary exists)
BUILD_RAHASHER=1 ./install.sh
```

### 6.1 Settings (top of the script, all overridable by environment)

| Variable | Default | Why |
|---|---|---|
| `ROMM_VERSION` | `5.4.1` | Release tag to install (latest at the time; tagged 2026-10-22/23). |
| `ROMM_HOME` | `~/opt/romm` | User's convention. |
| `ROMM_URL_PREFIX` | `/romm` | Public subpath. Empty would mean domain root (skips all subpath work). |
| `ROMS_DIR` | `~/games` | Linked into the library. |
| `PROXY_D_DIR` | `~/.apps/nginx/proxy.d` | Where the provided nginx reads location blocks. |
| `PORT_MIN`/`PORT_MAX` | `37715`/`37749` | Allowed range. |
| `INSTALL_EMULATORS` | `1` | EmulatorJS (~297 MB), Ruffle (~27 MB), js-dos (~18 MB), FAKE-08 (<1 MB), EasyRPG. Needed for in-browser play. |
| `INSTALL_ROM_CONVERTO` | `1` | 30 MB static binary; inert unless `ROM_CONVERTO_ENABLED=true`. |
| `BUILD_RAHASHER` | `0` | Needed only for automatic RetroAchievements matching (see 11). |
| `USE_BREW` | `auto` | Install missing deps with brew if present. |
| `SETUP_SYSTEMD` | `auto` | Write units; start them if the user manager is reachable. |
| `NODE_MAJOR` | `24` | RomM's frontend `package.json` engines require `node: 24`, `npm: >=11.10` with engine-strict. |
| `NPM_VERSION` | `11.20.0` | Pinned npm (published 2026-09-22), see 9.1. |
| `NJS_VERSION` | `1.0.2` | **Our own pin** (latest njs tag on 2026-10-23); the Dockerfile does not pin njs for us. |
| `DEFAULT_DB_HOST`/`DEFAULT_DB_PORT` | `127.0.0.1`/`12715` | The provided MariaDB, reached locally. |
| `DEFAULT_BASE_URL` | `https://DOMAIN_NAME/romm` | Placeholder; only used when generating `romm.env`. |

Install-time resource caps (exported at the top; values respect pre-set environment):

| Setting | Why |
|---|---|
| `MAKEFLAGS=-j2` | nginx and RAHasher builds use at most 2 compiler processes (verified). |
| `UV_CONCURRENT_BUILDS/INSTALLS/DOWNLOADS=2` | Keep uv gentle. |
| `RAYON_NUM_THREADS=2` | **Critical.** Rolldown (Vite's bundler, native Rust) sizes its rayon pool by CPU count (128) and panics with `ThreadPoolBuildError ... WouldBlock (os error 11)` on this server. Verified it honors this variable. |
| `MALLOC_ARENA_MAX=2` | **Critical.** See 9.2: each thread can get a glibc malloc arena reserving 64 MiB of address space; with 128 CPUs glibc allows 1024 arenas, which exhausts the 10 GB virtual memory limit. |
| `UV_THREADPOOL_SIZE=2`, `NODE_OPTIONS=--max-old-space-size=1024 --v8-pool-size=2` | Shrink Node's own pools (default 4 each). The heap cap does **not** reduce the frontend build's peak (it's native memory). |
| `TOKIO_WORKER_THREADS=2` | Harmless; measured no effect on the frontend build. Kept for other Rust tools. |
| `7zz x -mmt2` | 7-Zip also sizes threads by CPU count. |

### 6.2 Dependencies

`need <cmd> <brew formula>` checks for a command and installs the formula with brew if missing; keg-only formulae get their `bin` prepended to PATH. Required: `git`, `curl`, `make`, a C compiler, `uv` (installed with **pipx** first, brew as fallback), brew `node@24` (keg-only, so it coexists with the user's Node 26), `mariadb_config` (`mariadb-connector-c`, needed to compile the Python `mariadb` driver), `valkey-server` (`valkey`), `7zz` (`sevenzip`), `bsdtar` (`libarchive`), and brew `pcre2`, `zlib`, `libmagic`. The resolved Node binary is stored as `NODE_BIN` (realpath) and must be major 24. Runtime binaries are symlinked into `tools/bin` so services never depend on the login PATH.

### 6.3 `romm.env` generation (first run only)

Picks the first three free ports in the range (in order: `ROMM_PORT` internal nginx, `DEV_PORT` gunicorn, `REDIS_PORT` Valkey). A port held by a *stopped* app can't be detected; the user should check. Generates random hex secrets (`DB_PASSWD`, `REDIS_PASSWORD`, `ROMM_AUTH_SECRET_KEY`); hex means no URL-encoding issues. Sets small-server tuning: `WEB_SERVER_CONCURRENCY=1` (one gunicorn worker), `SCAN_WORKERS=2`, `ROM_PATCHER_MAX_CONCURRENCY=1`, `ROM_PATCHER_MAX_FILE_SIZE_BYTES=402653184` (384 MiB, RomPatcher loads the ROM into memory), `ROM_CONVERTO_MAX_CONCURRENCY=1`, `OTEL_SDK_DISABLED=true`, `ROMM_SESSION_SECURE_COOKIE=true`, `TZ=Asia/Jerusalem`. Metadata keys start empty. **The file is never overwritten** on later runs.

### 6.4 Library

Creates `data/{resources,assets,config}`, an empty `config.yml`, and links the ROMs: if `~/games/roms` exists, `data/library -> ~/games`; otherwise `data/library/roms -> ~/games` (the user's case). RomM expects platform folders it recognizes (`gba`, `snes`, `psx`, ...) or mappings in `config.yml`. nginx follows the symlinks for downloads.

### 6.5 Source and backend

- Shallow clone of the tag (later runs: fetch tag, `git checkout --force`, which also **reverts previous patches** so they are re-applied cleanly; the subpath source rules are not idempotent, so this reset matters).
- `darg NAME` reads `ARG NAME=value` from the release's `docker/Dockerfile`, so emulator/nginx/mod_zip/RAHasher versions and SHA-256 checksums always match the official image of that release.
- `uv sync --frozen --no-dev --no-install-package psycopg-c`: psycopg-c needs `pg_config` to build and is only used with PostgreSQL (verified nothing imports psycopg with the MariaDB driver). `LDFLAGS` gets `-Wl,-rpath` for every `-L` dir from `mariadb_config --libs` (plus brew's lib) so the compiled driver finds brew's `libmariadb` at runtime without `LD_LIBRARY_PATH`. uv provides the Python version pinned in `.python-version` (3.14 for 5.4.1), downloading a managed CPython if needed, so no system Python is required.
- **Backend patches** (exact-string replacements; each aborts the install if the original text isn't found, so upstream changes can't slip by silently):

| File | Change | Why |
|---|---|---|
| `utils/archives.py` | `SEVEN_ZIP_PATH`/`BSDTAR_PATH` from hardcoded `/usr/bin/...` to `shutil.which(...) or ...` | Binaries live in `tools/bin` (brew), not `/usr/bin`. Without this, 7z/RAR archive reading fails. |
| `handler/easyrpg/__init__.py` | `f"/var/www/html{RTP_WEB_PATH}"` -> `f"<WWW>{RTP_WEB_PATH}"` | Container web root path. |
| `__version__.py` | `<version>` -> the tag | Official CI does this; otherwise the UI shows "development". |
| `config/__init__.py` | `FRONTEND_RESOURCES_PATH = "/assets/romm/resources"` -> `"/romm/assets/romm/resources"` | Cover/screenshot URLs, which are also pushed over the websocket during scans (nginx `sub_filter` can't touch websocket frames). |

- `python-magic` must load `libmagic.so.1`; if it can't, brew's copy is symlinked into `lib/` (`romm-run` then sets `LD_LIBRARY_PATH` to that directory only). The script then verifies `import magic, mariadb` works.
- **RomPatcher.js** (server-side ROM patching): `npm ci` in `backend/utils/rom_patcher`, then copy `node_modules/rom-patcher/rom-patcher-js` next to it, like the Dockerfile.

### 6.6 Frontend

1. `subpath.py src` patches the source (section 7).
2. `npm ci` via `npm_run` (pinned npm run as `NODE_BIN npm-cli.js`), then `NODE_BIN node_modules/vite/bin/vite.js build --base=/romm/` (equivalent to `npm run build`, whose script is `vite build`, but without npm's PATH lookup of `node`; see 9.1).
3. `subpath.py dist` rewrites the built bundle and regenerates `.gz` siblings (nginx serves precompressed files with `gzip_static`).
4. Web root assembled like the Dockerfile: `dist` + `frontend/assets` merged into `assets/`, `assets/romm/resources -> data/resources` symlink, emulators unpacked into `assets/{emulatorjs,ruffle,jsdos,pico8,easyrpg}` (each download SHA-256-verified against the Dockerfile's values; a failure only warns and skips that emulator).

Measured: the frontend build peaks at **about 1.75 GB RSS** for roughly 15-40 s. This is the heaviest step of the whole install and is not reduced by the Node heap cap.

### 6.7 Extra tools

- `rom-converto`: static musl binary from GitHub releases; version and per-arch checksum parsed from the Dockerfile.
- `RAHasher` (only with `BUILD_RAHASHER=1`, only if missing): clones RALibretro at `RALIBRETRO_COMMIT`, applies the same two `sed` include fixes as the Dockerfile, `make HAVE_CHD=1 -f Makefile.RAHasher`. Needs `g++`. Measured: at most 2 compilers in parallel, largest about 200 MB RSS; verified under `ulimit -v 10000000`; works on the real server.
- Not replicated from the Dockerfile (optional upstream features): `sigil` (title-ID extraction, no-ops when absent) and `gme` (chiptune WASM, built with emscripten).

### 6.8 Internal nginx

- Built from `nginx/nginx` tag `release-<NGINX_VERSION from Dockerfile>` with njs (`NJS_OPENSSL=NO NJS_LIBXSLT=NO NJS_ZLIB=NO NJS_QUICKJS=NO`, only core JS is needed for `decode.js`'s `Buffer.from`), mod_zip at `NGINX_MOD_ZIP_COMMIT`, `--with-http_gzip_static_module --with-http_sub_module`, no TLS. Rebuilt only when `.stamp` (versions + module list) changes.
- `nginx.conf` derived from upstream `docker/nginx/default.conf`: `load_module` lines removed (modules are static), `worker_processes 1`, `worker_connections 512`, `ssl_*` directives removed (no TLS module; front proxy does HTTPS), pid/temp/mime/js/include paths moved into `ROMM_HOME`, `access_log off` (opening `/dev/stdout` fails when stdout is the journald socket; the front proxy logs anyway), `error_log stderr`. A sanity check aborts if any container path remains.
- `conf.d/default.conf` from upstream `templates/default.conf.template` with variables substituted, `root` -> our `www`, **`absolute_redirect off`** (otherwise nginx's own redirects would leak `127.0.0.1:port`), `listen 127.0.0.1:<port>` (local only).
- With a prefix, the `/api` location gets: the server-level `proxy_set_header` lines repeated (nginx drops inherited `proxy_set_header`s once a location defines any), `Accept-Encoding ""` (so responses are uncompressed and filterable), and **audience-dependent** `sub_filter` rules on `application/json` (plus nginx's default `text/html`). API JSON contains root-absolute paths (covers, save/state `download_path`, music streams), and two audiences need them differently (see section 16):
  - **RomM's own web page** uses them directly in the browser, so it needs them prefixed: `"/api/` -> `"/romm/api/`, `"/assets/` -> `"/romm/assets/`, `'/openapi.json'` -> prefixed. Covers already arrive prefixed from the patched backend.
  - **Companion apps** append them to the server URL they were configured with (which already ends in `/romm`), so they need RomM's stock paths: the backend's prefixed covers are stripped back, `"/romm/assets/` -> `"/assets/`, and nothing else changes.
  - Detection, via `map`s at the top of `conf.d/default.conf` feeding variables into the `sub_filter` search/replace strings: the request is from the web page if `Sec-Fetch-Site: same-origin` (sent by browsers for the page's own fetches), or, when that header is absent (older browsers), if `Referer` is under `https?://<host>/romm/`. Apps send neither; Electron renderers calling a remote server send `Sec-Fetch-Site: cross-site`. The unused rule slots for apps get distinct never-matching strings (`"/__romm_no_match_2__/`, `_3_`).
- **Front-proxy snippet** `nginx/romm-proxy.conf`, symlinked to `~/.apps/nginx/proxy.d/romm.conf`:
  - `location = /romm { absolute_redirect off; return 301 /romm/; }` (relative Location; an absolute one would leak `:12740`).
  - `location ^~ /romm/ws/` and `^~ /romm/netplay/` with WebSocket `Upgrade`/`Connection "upgrade"` headers (we can't define a `map` for `$connection_upgrade` inside a `server` block, so the upgrade locations are separate).
  - `location ^~ /romm/` -> `proxy_pass http://127.0.0.1:ROMM_PORT/;` (trailing slash strips the prefix), `client_max_body_size 0`, request/response buffering off, 600 s timeouts, `proxy_redirect default` plus `proxy_redirect ~^/(.*)$ /romm/$1` for relative Locations from the backend.
  - `^~` is essential: it stops regex locations in the provider's server block (e.g. a static-file cache rule for `\.(js|css|png)$`) from hijacking RomM's assets. Tested with exactly such a hostile regex location.
  - `X-Forwarded-Proto https` is hardcoded (the provided nginx sees plain HTTP from Ultra.cc's edge, but the public URL is HTTPS).
- The user must reload the provided nginx after the first install.

### 6.9 Database

Python (with the venv's `mariadb` driver; no `mariadb` CLI needed):

- With `DB_ADMIN_USER`/`DB_ADMIN_PASSWD`: asks MariaDB how it sees the connection (`SELECT SUBSTRING_INDEX(USER(), '@', -1)`, which is `172.17.0.1` on this server because MariaDB is in Docker), then creates the database (`utf8mb4_unicode_ci`) and the `romm` user for `localhost`, `127.0.0.1` **and that observed host**, with `ALTER USER` so the password always matches `romm.env`, and `GRANT ALL` on the database only.
- Always verifies `romm` can connect; on failure prints the exact SQL, using the host from the error message.
- If the provider ever renumbers its Docker network, RomM will get "access denied"; re-running with the admin login fixes it.

### 6.10 Stop running RomM, then migrate

- Before touching the schema: if the systemd user manager is reachable and RomM units exist, `systemctl --user stop romm.target 'romm-*.service'`. Then refuse to continue if any process matching `ROMM_HOME/(bin/romm-run|app/.venv/bin/)` still runs (catches hand-started components). Reason: the backend runs `alembic upgrade head` on every start (and crash-loops with `Restart=on-failure`), and two concurrent migration runs can leave the DB half-migrated.
- **Migrations run in the installer** (`alembic upgrade head`, log in `build/migrations.log`). Reason: MariaDB 11.4 here has binary logging on, and some RomM migrations create triggers, which MariaDB refuses (error 1419) for users without SUPER unless `log_bin_trust_function_creators=1`. With the admin login, the installer sets that global to 1 only while migrating and restores 0 afterwards (also via an `EXIT` trap on failure). Granting SUPER or permanently changing the provider-managed container's config was rejected as broader than necessary / not possible. Triggers only need the setting at creation time; afterwards they work with it back at 0 (verified). Without the admin login, a 1419 failure aborts with instructions. Migrations do not need Valkey (verified).
- RomM's `alembic/env.py` probes trigger permission before running pending revisions (plus a backstop for denials the probe misses), so a refused run is normally stopped before any revision is applied.

### 6.11 Valkey

`valkey.conf`: `bind 127.0.0.1`, generated port, `requirepass` (password in a 600-mode file, never on the command line), `save 3600 1`, `io-threads 1`, `maxmemory 768mb` with `maxmemory-policy noeviction` (stay under the 1 GiB service cap; refuse writes rather than silently evicting sessions or queue data).

### 6.12 systemd user units

Written to `~/.config/systemd/user/`: `romm.target` (wants valkey, backend, worker, scan-worker, cron, nginx; `WantedBy=default.target`) and one `.service` per component, each `PartOf=romm.target`, `ExecStart=~/opt/romm/bin/romm-run <component>`, `Restart=on-failure`, `RestartSec=5`, `TimeoutStartSec=600` (migrations after upgrades), `CPUQuota=200%`, `MemoryMax` 1G (valkey, backend, workers, streaming worker), 512M (cron, watcher), 256M (nginx). Optional units `romm-watcher` and `romm-streaming-worker` are written but not wanted by the target; enable with `systemctl --user enable --now romm-watcher`. Then `daemon-reload`, `enable romm.target`, `restart romm.target`. Warns if lingering is off.

Caveat: `MemoryMax`/`CPUQuota` are only enforced if the memory/cpu cgroup controllers are delegated to the user manager (check `cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers`). Not verified on the server. The app-level caps work regardless.

---

## 7. `subpath.py` - serving RomM under `/romm`

RomM's frontend uses root-absolute paths (`/api`, `/assets`, `/ws`, `/netplay`, `/openapi.json`) in hundreds of places, and its Vue router base is effectively `/` (`createWebHistory(process.env.BASE_URL)` while Vite defines `process.env` as `{}`). The front proxy strips `/romm`, so the **backend and internal nginx keep working at root**; only URLs generated *in the browser* (and absolute links in API responses, see 6.5 and 6.8) need the prefix.

Approach: Vite's `--base=/romm/` handles bundle imports, CSS `url()`s of bundled assets, `index.html` references and the PWA manifest base. Everything else is handled in two passes.

### 7.1 `src` pass (before the build) - targeted source edits

Needed because a bundle-wide rewrite can't tell **router paths** (must NOT be prefixed when passed to the router, which adds the base itself) from **document-level navigations/links** (must be prefixed).

| Rule | Where | Change | Required | 5.4.1 count |
|---|---|---|---|---|
| router base | `src/plugins/router.ts` | `createWebHistory(process.env.BASE_URL)` -> `createWebHistory(import.meta.env.BASE_URL)` | yes | 1 |
| origin template links | all `.ts`/`.vue` | `${window.location.origin}/` -> `${window.location.origin}/romm/` (pair/invite/share links, EmulatorJS background image) | no | 6 |
| origin + router path | all | ``window.location.origin + `/`` -> ``window.location.origin + `/romm/`` (share link in game actions) | no | 1 |
| player exit | `usePlayerExit/index.ts` | `window.location.replace(path);` -> `window.location.replace(router.resolve(path).href);` (full-document navigation out of the cross-origin-isolated player) | yes | 1 |
| 401 handler pathname | `services/api/index.ts` | strip the prefix from `window.location.pathname` before using it as a router path (`/^\/romm(?=\/|$)/`) | yes | 1 |
| 401 handler resolve | `services/api/index.ts` | `router.resolve(window.location.pathname)` -> `router.resolve(pathname)` | yes | 1 |
| template href to routes | all `.vue` | `href="/x` / `:href="` + backtick `/x` -> prefixed, unless `x` is a server path (`/login`, `/rom/${id}`, `/platform/${id}` anchors) | no | 5 |

`${window.location.origin}${expr}` is deliberately left alone: `expr` is a server path (e.g. download URLs) that the dist pass prefixes. Prefixing both would double it. Test files and `__generated__` are skipped. Replacements use lambdas to avoid regex-escape processing (an earlier version produced invalid JS this way).

### 7.2 `dist` pass (after the build) - bundle rewrite

- In `.js .mjs .css .html .json .webmanifest` files: any `"`, `'`, backtick, or CSS `url(` immediately followed by `/(api|assets|ws|netplay|openapi.json)` and a boundary (`/ " ' backtick ? # ) whitespace end`) gets the prefix. The `(` context is limited to `url(` because `(/api/` in JS could be a regex literal.
- `.html`: any remaining `href="/` or `src="/` not already prefixed (e.g. `safari-pinned-tab.svg`, which Vite left alone).
- `.webmanifest`: all `"/` paths (PWA icon paths).
- Regenerates `.gz` siblings of changed files (gzip level 9).
- Aborts if nothing matched or if `index.html` doesn't load its bundle from `/romm/assets/`.
- Note: RomM 5.4.1 configures its PWA service worker with `injectRegister: null` and never registers it, so no service-worker scope issues.

### 7.3 What was verified through the prefix (headless Chromium via the test front nginx)

`/romm` -> `/romm/` relative redirect; unauthenticated `/romm/` -> `/romm/setup` (router base works); admin creation; login through the UI (redirect after login takes about 4 s due to an animation); websocket at `/romm/ws/socket.io`; scan triggered from the UI's Scan button; ROM and platform pages; single-file, `.7z` and multi-disc zip downloads (zip contained both discs byte-identical plus a correct `.m3u`, proving mod_zip + njs); logged-out deep link `/romm/rom/2` -> `/romm/login?next=/rom/2` -> back to `/romm/rom/2` (401 patch); EmulatorJS player page loads `loader.js`, core and CSS from `/romm/assets/emulatorjs/` with COOP/COEP headers present. **Zero requests left the `/romm` prefix** in every run.

### 7.4 Re-doing the subpath work for a new RomM version

1. Run the install with the new `ROMM_VERSION` in a test environment first (section 10). If a required rule matched nothing, the install stops and names it: open that file in the new version and adapt the pattern.
2. Even if the install passes, audit for **new** cases:
   ```bash
   cd app/frontend/src
   # document-level navigation / absolute links built in the browser
   grep -rn "window.location\|document.location\|location.href\|location.assign\|location.replace\|window.open(" --include=*.ts --include=*.vue . | grep -v test
   # anchors to routes
   grep -rnE 'href="/|:href="`/' --include=*.vue .
   # new root-level server prefixes (anything besides api/assets/ws/netplay/openapi.json?)
   grep -rn "process.env.BASE_URL\|import.meta.env.BASE_URL" --include=*.ts .
   ```
   After a build, list the remaining root-absolute string literals in the bundle and classify each as router path (fine), axios-relative API path like `/roms` (fine, axios `baseURL` is the rewritten `"/romm/api"`), or a new server path (add it to `SERVER_PATHS`):
   ```bash
   cd app/frontend/dist
   grep -rhoE "[\"'\`(]/[a-zA-Z][a-zA-Z0-9._-]*" --include=*.js --include=*.css --include=*.html --include=*.json --include=*.webmanifest . \
     | sed -E 's/^.//' | sort | uniq -c | sort -rn | head -80
   ```
3. Backend: look for new root-absolute URLs in API responses or websocket emits: `grep -rnE "f?\"/api/|\"/assets/" backend --include=*.py | grep -v tests`. JSON responses are covered by the web-page `sub_filter` rules; websocket payloads are not (handle like `FRONTEND_RESOURCES_PATH`). Remember apps must keep receiving stock paths: a new prefixed value emitted by the backend needs a matching strip rule for apps.
4. Check `docker/nginx/templates/default.conf.template` still contains the exact `/api` location opening (`    location /api {\n        proxy_pass http://wsgi_server;\n`) that the `sub_filter` injection anchors on.
5. Re-run the browser checks from 7.3.

---

## 8. `romm-run` (runtime launcher)

Sources `romm.env`, sets a **minimal PATH** (`tools/bin`, the venv, system dirs), `PYTHONPATH=backend`, `MALLOC_ARENA_MAX=2`, `RAYON_NUM_THREADS=2`, `TOKIO_WORKER_THREADS=2`, `UV_THREADPOOL_SIZE=2`, `NODE_OPTIONS=--v8-pool-size=2`, and `RQ_REDIS_URL` (password via environment, not argv, so other users can't see it in `ps`). Components:

| Component | Command (mirrors the official `docker/init_scripts/init`) |
|---|---|
| `valkey` | `valkey-server valkey/valkey.conf` |
| `backend` | waits for Valkey and MariaDB ports; `alembic upgrade head` (normally a no-op since the installer migrated); `python3 startup.py`; `gunicorn --bind=127.0.0.1:$DEV_PORT --worker-class uvicorn_worker.UvicornWorker --workers $WEB_SERVER_CONCURRENCY ... main:app` with RomM's logging config |
| `worker` | `rq worker --worker-class handler.rq_worker.RomMWorker --connection-class handler.redis_handler.RomMRedis --with-scheduler high default low` |
| `scan-worker` | same, queue `scans` |
| `streaming-worker` | `PreloadingWorker`, queue `streaming` (optional) |
| `cron` | `rq cron ... tasks.cron_config` |
| `nginx` | waits for gunicorn; `nginx -p nginx -c conf/nginx.conf -g 'daemon off;'` |
| `watcher` | `watchfiles --target-type command "python3 watcher.py" data/library` (optional) |

Manual debugging: `~/opt/romm/bin/romm-run backend` in the foreground.

---

## 9. Problems hit on the real server and their fixes (chronological)

### 9.1 `npm error EBADENGINE ... Actual: {"node":"v26.12.1"}`
The installer's own check found Node 24, yet npm ran under Node 26. Mechanism (reproduced): when run via `npx`, npm executes commands through a shell whose PATH first lists every `node_modules/.bin` from the current directory up to `/`, then the inherited PATH, and npm's launcher resolves `node` from that PATH. A `node` in e.g. `~/node_modules/.bin` (or a shell config resetting PATH) wins. The exact trigger on the server was never confirmed. **Fix**: never let npm look up `node`: pinned npm tarball (integrity-checked against the registry's `dist.integrity`) run as `NODE_BIN npm-cli.js`, and the Vite build invoked as `NODE_BIN node_modules/vite/bin/vite.js build` directly. All `npm ci` calls use `--ignore-scripts`, so npm spawns no shells.

### 9.2 Rolldown panic: `ThreadPoolBuildError { kind: IOError(Os { code: 11, kind: WouldBlock ... }) }`
Same class of failure that had broken copyparty and brew on this server. Investigation with `threadprobe.py`: 134 threads with default stacks, 313 with 256 KiB stacks, so a **memory-type** limit, not a thread count limit (count limits were far away). Cause: `ulimit -v` 10 GB per process; each thread reserves its stack (8 MiB) and, on a 128-CPU box, usually its own glibc malloc arena (64 MiB of address space; glibc allows 8 per CPU = 1024). 134 x ~72 MB is about 9.6 GB. Reproduced in a sandbox with `ulimit -v 10000000` and `MALLOC_ARENA_MAX=1024`: 138 threads; with `MALLOC_ARENA_MAX=2`: 1207. The frontend build with rayon at 128 threads aborted under those limits; with the caps it builds (also with 1024 arenas). **Fix**: `RAYON_NUM_THREADS=2` (decisive), `MALLOC_ARENA_MAX=2`, Node pool caps, `7zz -mmt2` (install) and the same caps in `romm-run` (runtime). General advice given to the user: `export MALLOC_ARENA_MAX=2` in `~/.bashrc` and `Environment=MALLOC_ARENA_MAX=2` for copyparty's unit (not tested for copyparty).

### 9.3 `Access denied for user 'romm'@'172.17.0.1'`
MariaDB is in a Docker container; host connections arrive from the bridge address. The user had been created for `localhost`/`127.0.0.1` only (root worked because it allows `%`). **Fix**: create the user also for the host MariaDB reports via `USER()` (6.9). Reproduced and verified by making the test MariaDB see a non-loopback address.

### 9.4 Backend: `FAILED: The database user is not allowed to create triggers ... (error 1419)`
Binary logging on. **Fix**: installer-run migrations with `log_bin_trust_function_creators` temporarily 1 (6.10). Reproduced with a binlog-enabled test MariaDB from an empty database; verified triggers created, setting restored to 0, services start, browser checks pass.

### 9.5 Risk of concurrent migrations
The crash-looping backend would keep running migrations while the installer migrates. **Fix**: installer stops RomM units and refuses to migrate while any RomM process runs (6.10). Verified the refusal path; the systemd stop path itself could not be tested in the sandbox.

### 9.6 Metadata providers
- **IGDB**: works.
- **RetroAchievements**: works (an initial "API key invalid" was a wrongly pasted key). RomM validates via `API_GetAchievementOfTheWeek.php?y=<key>`; any failure (bad key, network) shows "invalid", the real reason is logged as `Error checking RetroAchievements API` in the backend journal.
- **ScreenScraper**: "API key invalid" plus a banner about missing developer credentials. RomM needs `SCREENSCRAPER_DEV_ID`/`SCREENSCRAPER_DEV_PASSWORD` in addition to the user's `SCREENSCRAPER_USER`/`SCREENSCRAPER_PASSWORD`. Official images get the dev credentials injected by RomM's CI as Docker build args (the Dockerfile says they are kept out of the source tree); source builds have none. **Open item**: the user needs their own ScreenScraper developer credentials (request process not verified). Do not extract the official image's credentials.
- Keyless sources are off by default upstream and here: `HASHEOUS_`, `LAUNCHBOX_`, `PLAYMATCH_`, `TGDB_`, `STEAM_` (PC only), `FLASHPOINT_`, `HLTB_`, `DEMOZOO_`, `POUET_`, `CSDB_` + `API_ENABLED=true`. Key-based: `MOBYGAMES_API_KEY`, `STEAMGRIDDB_API_KEY`. Each adds outbound requests per scan. **LaunchBox** imports its whole `Metadata.zip` into Valkey (size not measured) and Valkey is capped at 768 MB with `noeviction`; check `valkey-cli -p $REDIS_PORT -a $REDIS_PASSWORD info memory` after enabling.

### 9.7 Companion-app covers broken by the server-side prefixing (found by code review, fixed 2026-10-30)
Originally the internal nginx prefixed `"/api/` and `"/assets/` in API JSON for every client, and the backend patch prefixes cover paths. Reading the clients' source showed they all append API paths to their configured server URL, so covers became `/romm/romm/assets/...`, and RomMix refuses image paths that don't start with `/assets/`. **Fix**: audience-dependent rewriting (6.8). Verified: apps get `/assets/...` and `/api/...`, the web page (via `Sec-Fetch-Site` or `Referer`) gets `/romm/...`; each client's joining logic emulated against the server returns the cover (200, image/png) and Freegosy's save download (200); the web page still loads covers and save downloads with zero requests outside `/romm`.

### 9.8 Issues found and fixed in the sandbox before the user ran anything
`/dev/stdout` access log under journald; `ssl_*` directives in a TLS-less build; `/romm` redirect leaking the port (absolute redirect); duplicate `sub_filter_types text/html` warning; regex-location hijacking (solved with `^~`); `/romm/` vs `/romm` handling; `.gz` siblings stale after bundle rewrite.

---

## 10. Testing approach (how to verify changes before giving them to the user)

The work was verified in an Ubuntu 24.04 sandbox (1 CPU, 3 GB) emulating the server:

- A non-root user `gal` doing the whole install; apt packages standing in for brew (`mariadb` client libs, `valkey-server`, `7zip` with a `7zz` symlink, `libarchive-tools`, `libpcre2-dev`, `zlib1g-dev`), Node 24 from the npm registry package `node-linux-x64@24`, uv via pip then via **pipx** (the server's path).
- "Provided" MariaDB run by another user on port 12715 with a root password, **binary logging on** (`--log-bin --server-id=1`), bound to a non-loopback address and `DB_HOST` pointed at it so connections arrive from a non-loopback IP (emulates `172.17.0.1`), `root@'%'`.
- "Provided" stock nginx on port 12740 whose `server` block includes `~/.apps/nginx/proxy.d/*.conf`, plus a hostile `location ~* \.(js|css|png|svg)$ { return 418; }`.
- A foreign process occupying port 37715 (port picker must skip it).
- Limits: `ulimit -v 10000000`, `MALLOC_ARENA_MAX=1024` (emulates 128 CPUs' arena allowance), `RAYON_NUM_THREADS=128` (emulates 128 CPUs for rayon), and thread-count caps via `ulimit -u`.
- Browser end-to-end: `puppeteer-core@23` + `@sparticuz/chromium@131` (both from the npm registry; Chromium binary ships inside the package). Scripts logged every response >= 400, every request outside `/romm`, and websocket URLs. Limitation: that Chromium runs `--single-process`, so it can't open extra browser contexts and reports `crossOriginIsolated=false` regardless of headers.
- systemd user units could only be checked with `systemd-analyze verify` (no user manager in the sandbox). They do run on the real server.

---

## 11. Feature notes and recommendations

- **RetroAchievements**: enabled by `RETROACHIEVEMENTS_API_KEY`. Automatic matching is **only** by RAHasher file hash during scans (`BUILD_RAHASHER=1`, built on the server). Alternatives: filename tag `(ra-12345)` or setting the RA ID manually. After adding RAHasher, run a scan mode that refreshes existing ROMs.
- **`ENABLE_RESCAN_ON_FILESYSTEM_CHANGE`** (off, upstream default): needs the `romm-watcher` unit too; a download writing into `~/games` (aria2) could trigger scans of partial files (5-minute debounce, `RESCAN_ON_FILESYSTEM_CHANGE_DELAY`). Cheaper alternative: `ENABLE_SCHEDULED_RESCAN=true` (runs from the existing cron service, `SCHEDULED_RESCAN_CRON` default `0 3 * * *`). Watcher untested.
- **`ROM_CONVERTO_ENABLED`** (off, upstream default): enables format conversion (CHD/CSO/RVZ/3DS), header title-ID reading, on-the-fly download conversion and a "Convert library" task that converts ROMs **in place** (inside `~/games`). CPU/RAM heavy. Untested.
- Changing API keys or feature flags: edit `romm.env`, `systemctl --user restart romm.target`. Changing ports/DB/Valkey settings: re-run `install.sh` (they are baked into generated nginx/Valkey configs). Check provider status: `curl -s http://127.0.0.1:$ROMM_PORT/api/heartbeat` (the `METADATA_SOURCES` section has `..._API_ENABLED` flags).
- A re-run keeps `romm.env`, the database, `data/` and enabled optional units; it regenerates `app/` patches, `www/`, nginx configs and the proxy.d link, `valkey.conf` and unit files (hand edits there are lost).

---

## 12. Measurements (sandbox, RomM 5.4.1)

| What | Value |
|---|---|
| Frontend build peak RSS | ~1.75 GB (largest single step) |
| Full install | ~2-3 minutes (with RAHasher about 3 min); slower first run (downloads, nginx build) |
| RAHasher compile | <= 2 compilers, largest ~200 MB RSS |
| Runtime RSS after a scan | gunicorn ~270 MB, each RQ worker ~145 MB (incl. scheduler child), rq cron ~80 MB, Valkey ~25 MB, nginx ~10 MB; ~680 MB total |
| Runtime threads | ~17-21 total for all RomM processes |
| Peak threads of the capped frontend build | ~25 |

---

## 13. Not verified / known limitations

- Netplay (`/romm/netplay/` is proxied with WebSocket upgrade, but never exercised).
- Companion apps were not run; their URL handling was read from source and emulated (section 16).
- Argosy save/state/screenshot downloads behind `/romm` (Argosy bug, section 16).
- Gameflow Deck's internal forwarder drops the `/romm` path (Gameflow bug, section 16).
- OIDC login and its redirects.
- External clients that use absolute feed URLs (Tinfoil, WebRcade, RetroArch sync): the backend builds some URLs from the request, which no longer contains `/romm` after the front proxy strips it.
- FastAPI's own trailing-slash redirects use absolute URLs with the public host; `proxy_redirect` only rewrites relative ones and the internal `127.0.0.1` form.
- Swagger docs at `/romm/api/docs`.
- Whether multi-threaded emulator cores get cross-origin isolation through the provider's edge (headers verified, isolation not observable in the test browser).
- `romm-watcher`, `romm-streaming-worker`, rom-converto at runtime.
- EasyRPG download (unreachable from the sandbox; should work on the server).
- Whether cgroup `MemoryMax`/`CPUQuota` are enforced for the user's units.
- The precise trigger of 9.1 on the server.

---

## 14. Upgrade procedure for a new RomM release

1. Read RomM's release notes for the target version (breaking changes, new required env vars, Node/Python version changes).
2. In a full (non-shallow) clone, diff the parts this setup mirrors:
   ```bash
   git diff 5.4.1 <NEW> --stat -- docker/ env.template frontend/package.json pyproject.toml .python-version
   git diff 5.4.1 <NEW> -- docker/Dockerfile docker/init_scripts/init docker/nginx/ env.template
   ```
   Check: ARG names `darg` reads (`EMULATORJS_VERSION/_SHA256`, `RUFFLE_VERSION/_FILE/_SHA256`, `JSDOS_VERSION/_SHA256`, `FAKE08_P3A_COMMIT/_JS_SHA256/_WASM_SHA256`, `EASYRPG_VERSION/_SHA256/_RTP_COMMIT/_RTP_SHA256`, `NGINX_VERSION`, `NGINX_MOD_ZIP_COMMIT`, `RALIBRETRO_COMMIT`), the `ROM_CONVERTO_VERSION=` and `amd64) rc="..."; sum="..."` line formats, new runtime binaries or assets in the production stage, changed process list or flags in `init` (update `romm-run`), new nginx modules or directives (update the nginx build/rewrites), Node major in `frontend/package.json` `engines` (update `NODE_MAJOR` and possibly `NPM_VERSION`), Python version.
3. Re-check the hardcoded container paths: `grep -rnE '"/(usr/bin|var/www|romm|backend|redis-data)[^"]*"' backend --include=*.py | grep -v tests` and update the backend patch list (6.5).
4. Do the subpath audit (7.4).
5. Test in the sandbox setup (section 10), including binlog-on MariaDB, non-loopback DB source address, thread/memory limits and the browser checks.
6. On the server: `ROMM_VERSION=<NEW> DB_ADMIN_USER=root DB_ADMIN_PASSWD=... ./install.sh` (the admin login matters for trigger migrations). Expect the ~1.75 GB build peak.
7. Verify: `systemctl --user list-units 'romm*'`, `journalctl --user -u romm-backend -n 50`, open `/romm/`, run a scan, try a download and a game.

---

## 15. Day-to-day operations

```bash
systemctl --user status romm.target 'romm-*'
systemctl --user restart romm.target
systemctl --user stop romm.target
journalctl --user -u romm-backend -f          # also romm-worker, romm-scan-worker, romm-cron, romm-nginx, romm-valkey
~/opt/romm/bin/romm-run backend               # foreground debugging (stop the unit first)
cat ~/opt/romm/romm.env                        # ports, secrets, settings
~/opt/romm/app/.venv/bin/python dbcheck.py 127.0.0.1:12715   # which MariaDB, seen as which host
python3 threadprobe.py                         # what limits thread creation
```

Logs of install steps: `~/opt/romm/build/{frontend-build,nginx-configure,nginx-make,migrations}.log`.

---

## 16. Companion apps behind `/romm`

Source review on 2026-10-30 (default branches) of the clients relevant to the user (Linux/SteamOS, Windows, Android). **All of them keep a path in the configured server URL for their API calls**, so none needs a subdomain:

| Client | Platforms | API URL building | Covers (API `path_cover_*`) |
|---|---|---|---|
| Playnite plugin (rommapp, C#) | Windows | `{host}/api/...` string joins | `{host}{path}` |
| Argosy (rommapp, Kotlin) | Android 8+, gamepad-first | Retrofit, relative endpoints, base ends in `/`; socket.io path gets the base path | `base/` + path |
| RomMix (Electron) | Linux x86_64/arm64, Steam Deck | joins; keeps a pasted path on purpose | only paths starting `/assets/`, then `base+path` |
| Tender (Decky plugin, Python) | Steam Deck Game Mode, Linux HTPC | `romm_url.rstrip('/') + path` | same |
| Gameflow Deck (Bun) | Linux, Windows, Steam Deck | generated client, joins | image route joins |
| romm-client (Electron) | Linux AppImage, Windows | axios `baseURL` (joins) | `${baseUrl}${path}` |
| RomMate (Tauri) | desktop (README lists Windows) | `format!("{}{}")` | `${serverURL}/${src}` |
| Freegosy (Flutter) | repo has Android, Linux, Windows targets | Dio `baseUrl` (Dio 5.9.2 joins strings, verified in its source) | base + path |

Hence the server serves stock paths to apps and prefixed paths only to the web page (6.8). Results of emulating each client's joining logic against the test server: covers 200 for all eight (RomMate's `//` is merged by nginx), Freegosy save download 200.

Known client bugs behind any subpath, not fixable server-side without claiming root paths:
- **Argosy**: save/state/screenshot downloads pass the API's `download_path` (`/api/...`) to Retrofit `@Url`, which resolves it against the host root and drops `/romm` (emulated: request lands on the provider's `/` and gets 401). Upstream fix: resolve relative to the base URL.
- **Gameflow Deck**: its catch-all forwarder (`src/bun/api/clients.ts`) replaces scheme/host/port with the RomM address but keeps the incoming path, dropping `/romm` (affects assets routed through it, e.g. RomM's logo). Upstream fix: prepend the RomM address's path.

Recommendations given to the user: Steam Deck/Linux: RomMix or Tender; Windows: Playnite; Android with touch: Freegosy is the candidate (Argosy describes itself as gamepad-first); not verified hands-on.
