# RomM without Docker, without root, under `/romm`

Scripts that install [RomM](https://github.com/rommapp/romm) (a self-hosted retro game library with in-browser play) on a shared Linux server where you have no root, no Docker/Podman, and can't use a subdomain. Built for an Ultra.cc seedbox; RomM ends up at `https://<user>.<host>.<tld>/romm/`.

For the full design, the rationale behind every choice, the source patches and how to redo them for new RomM versions, see **`HANDOFF.md`**. This README is the short practical guide.

## Files

Keep them together in one folder (e.g. `~/romm-installer/`):

| File | Purpose |
|---|---|
| `install.sh` | Installs, repairs and upgrades. Safe to re-run. |
| `install-with-dbadmin.sh` | Runs `install.sh` with your MariaDB admin login, kept in a private `.romm-dbadmin.env` next to it. Use this instead of calling `install.sh` directly. |
| `romm-run` | Starts one RomM component; the systemd units call it. |
| `subpath.py` | Makes RomM's web interface work under `/romm`. Used by `install.sh`. |
| `dbcheck.py` | Diagnostic: which MariaDB a `host:port` reaches, and from which address it sees you. |
| `threadprobe.py` | Diagnostic: what limits thread creation on the server. |
| `HANDOFF.md` | Complete technical documentation. |

"MariaDB admin login" always means the admin account *inside* MariaDB (on Ultra.cc, the root login of the MariaDB you installed from their panel). Nothing here needs Linux root or sudo.

## What it uses

- **From the server:** its nginx (port 12740, per-app files in `~/.apps/nginx/proxy.d/`) and its MariaDB (port 12715).
- **Its own, under `~/opt/romm`:** RomM's backend, background workers, Valkey, and a small internal nginx (RomM needs two nginx modules the server's nginx doesn't have).
- **Tools** (installed with Homebrew/pipx if missing): `uv`, Node 24 (alongside any other Node you have), `valkey`, `sevenzip`, `libarchive`, `mariadb-connector-c`, `pcre2`, `zlib`, `libmagic`.
- **Ports:** three free ones from 37715-37749, picked on the first run and stored in `~/opt/romm/romm.env`. Everything listens on 127.0.0.1 only.
- **Your ROMs:** `~/games` is linked into the library; it should contain platform folders RomM knows (`gba`, `snes`, `psx`, ...).

## First install

```bash
cd ~/romm-installer
chmod +x install.sh install-with-dbadmin.sh romm-run
DEFAULT_BASE_URL=https://USER.HOST.TLD/romm ./install-with-dbadmin.sh
```

The first run asks for the MariaDB admin login and saves it (mode 600) for next time, then:

- creates the `romm` database and a limited `romm` user (the admin login is only used for that and for migrations, never stored in `romm.env`),
- builds everything, runs the database migrations, and starts the services,
- links `~/.apps/nginx/proxy.d/romm.conf`.

Then:

1. Restart the server's nginx so it picks up `romm.conf`: `app-nginx restart` (or "Restart Webserver" in Ultra.cc's control panel).
2. Open `https://USER.HOST.TLD/romm/` and create your admin account.
3. Check the ports in `~/opt/romm/romm.env`: they were free during the install, but a port used by one of your apps that happened to be stopped can't be detected.

The frontend build needs about **1.75 GB of RAM for under a minute**; run installs and upgrades when the server has that free.

## Day to day

```bash
systemctl --user status romm.target 'romm-*'
systemctl --user restart romm.target
journalctl --user -u romm-backend -f        # also romm-worker, romm-scan-worker, romm-cron, romm-nginx, romm-valkey
```

**Changing settings** (`~/opt/romm/romm.env`):
- API keys and feature switches: edit, then `systemctl --user restart romm.target`.
- Ports, database or Valkey settings: edit, then re-run `./install-with-dbadmin.sh` (they're also written into generated configs).

The file is loaded by bash: plain `KEY=value` lines, no comments after a value, and no Windows line endings.

**Upgrading RomM:**
```bash
ROMM_VERSION=X.Y.Z ./install-with-dbadmin.sh
```
The installer stops RomM before touching the database and starts it again at the end. If an upgrade changes code the `/romm` patches depend on, it stops with an error naming the patch instead of installing something half-broken; `HANDOFF.md` section 7.4 explains how to update the patches.

A re-run keeps `romm.env`, the database, your covers/saves/states, and any optional units you enabled. It regenerates the app code, the web files, the nginx and Valkey configs and the systemd units, so don't hand-edit those.

## Optional features

| Setting | Default | Notes |
|---|---|---|
| `INSTALL_EMULATORS` (installer) | `1` | In-browser play: EmulatorJS, Ruffle, js-dos, FAKE-08 (about 340 MB of disk together) and EasyRPG (size not measured). |
| `INSTALL_ROM_CONVERTO` (installer) | `1` | Downloads the converter binary; does nothing unless `ROM_CONVERTO_ENABLED=true`. |
| `BUILD_RAHASHER` (installer) | `0` | Builds RAHasher (needs `g++`). Only needed for RetroAchievements, see below. Built once. |
| `ROM_CONVERTO_ENABLED` (`romm.env`) | `false` | Format conversion (CHD, CSO, RVZ, 3DS). Its "Convert library" task converts files **in place inside `~/games`**, and compression is CPU/RAM heavy. |
| `ENABLE_RESCAN_ON_FILESYSTEM_CHANGE` (`romm.env`) | `false` | Also needs `systemctl --user enable --now romm-watcher`. Downloads written straight into `~/games` can trigger scans of unfinished files. `ENABLE_SCHEDULED_RESCAN=true` (nightly at 03:00 by default) is a lighter alternative. |

Installer settings are given on the command line, e.g. `BUILD_RAHASHER=1 ./install-with-dbadmin.sh`.

## Metadata providers

Set keys in `romm.env`, restart, then run a scan that refreshes existing games (a quick scan only picks up new files).

- **IGDB:** `IGDB_CLIENT_ID` / `IGDB_CLIENT_SECRET`.
- **RetroAchievements:** `RETROACHIEVEMENTS_API_KEY` (the *Web API Key* from your RetroAchievements settings). Games are matched automatically only by file hash, which needs `BUILD_RAHASHER=1`; otherwise use a filename tag like `(ra-12345)` or set the ID by editing the game.
- **ScreenScraper:** needs your account (`SCREENSCRAPER_USER` / `SCREENSCRAPER_PASSWORD`) **and** developer credentials (`SCREENSCRAPER_DEV_ID` / `SCREENSCRAPER_DEV_PASSWORD`). Official RomM images have RomM's own developer credentials built in; a source install like this one doesn't, so you need your own from ScreenScraper.
- **No key needed, off by default:** `HASHEOUS_`, `LAUNCHBOX_`, `PLAYMATCH_`, `TGDB_`, `STEAM_` (PC only), `FLASHPOINT_`, `HLTB_`, `DEMOZOO_`, `POUET_`, `CSDB_` + `API_ENABLED=true`. Each adds requests to every scan. LaunchBox loads its whole database into Valkey, which is capped at 768 MB here, so check Valkey's memory after enabling it.
- **Other keys:** `MOBYGAMES_API_KEY`, `STEAMGRIDDB_API_KEY`.

## Companion apps

Enter the server address **with** the path, e.g. `https://USER.HOST.TLD/romm`. Clients reviewed (by reading their code; none were run): Playnite (Windows), Argosy (Android), RomMix (Linux, Steam Deck), Tender (Steam Deck), Gameflow Deck, romm-client, RomMate, Freegosy. All keep the path for their API calls, and covers work: the server gives apps RomM's standard paths and adds `/romm` only for its own web page.

Two known app-side bugs behind any subpath:

- **Argosy:** downloading saves/states fails, because it drops `/romm` for those downloads. Fix needed in Argosy.
- **Gameflow Deck:** a few assets it forwards lose `/romm`. Fix needed in Gameflow Deck.

## Resource limits

The server allows about 10 GB of virtual memory per process and has 128 CPUs. Programs that start one thread per CPU hit that limit and crash with "Resource temporarily unavailable". The installer and services cap thread pools and memory pools to stay well inside it.

Every service also runs with `CPUQuota=200%` and a `MemoryMax` (1 GB for the backend, workers and Valkey; less for the rest), plus app-level caps:
- 1 web worker, 2 scan workers, 1 nginx worker
- Valkey capped at 768 MB
- ROM patching limited to 384 MB files

Measured idle use after a scan is about 680 MB in total.

systemd only enforces `MemoryMax`/`CPUQuota` if your user is allowed to use those cgroup controllers. Check with:
```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
```
If `memory`/`cpu` are missing, the app-level caps still apply.

## Troubleshooting

- **Install logs:** `~/opt/romm/build/` (`frontend-build.log`, `migrations.log`, `nginx-*.log`).
- **Run a component in the foreground:** stop its unit first, then `~/opt/romm/bin/romm-run backend`.
- **Database:** `~/opt/romm/app/.venv/bin/python dbcheck.py 127.0.0.1:12715` shows which MariaDB you reach and the address it sees you from. On Ultra.cc that's `172.17.0.1`, because MariaDB runs in a Docker container. If the provider ever changes that and RomM starts getting "access denied", re-run `./install-with-dbadmin.sh`.
- **Provider status:** `curl -s http://127.0.0.1:<ROMM_PORT>/api/heartbeat`; the `METADATA_SOURCES` part shows which providers are enabled.
- **"API key invalid" on the Metadata Sources page:** the real reason is in `journalctl --user -u romm-backend`. It can also mean the provider couldn't be reached.

## Known limitations

Untested: netplay, OIDC login, feed-based clients (Tinfoil, WebRcade, RetroArch sync), multi-threaded emulator cores' cross-origin isolation, the filesystem watcher, rom-converto conversions. Details and the full list are in `HANDOFF.md` section 13.
