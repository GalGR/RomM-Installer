#!/usr/bin/env bash
# RomM bare-metal installer - no Docker, no Podman, no sudo.
#
# Safe to re-run: the same command installs, repairs, and upgrades.
#   ./install.sh                                           # install / repair
#   DB_ADMIN_USER=root DB_ADMIN_PASSWD=... ./install.sh    # first run: also creates the DB + user
#   ROMM_VERSION=5.5.0 ./install.sh                        # upgrade to another release tag
#
# Uses the server's existing nginx (front proxy) and MariaDB. Runs its own Valkey,
# gunicorn, RQ workers and a small internal nginx (RomM needs mod_zip + njs).
set -euo pipefail

# ---------------------------------------------------------------- settings ---
ROMM_VERSION="${ROMM_VERSION:-5.4.1}"
ROMM_HOME="${ROMM_HOME:-${HOME}/opt/romm}"
ROMM_URL_PREFIX="${ROMM_URL_PREFIX-/romm}"           # public path; empty = served at the domain root
ROMS_DIR="${ROMS_DIR:-${HOME}/games}"                 # your ROMs, linked into the library
PROXY_D_DIR="${PROXY_D_DIR:-${HOME}/.apps/nginx/proxy.d}"
PORT_MIN="${PORT_MIN:-37715}"                         # free range for self-hosted apps
PORT_MAX="${PORT_MAX:-37749}"
INSTALL_EMULATORS="${INSTALL_EMULATORS:-1}"
INSTALL_ROM_CONVERTO="${INSTALL_ROM_CONVERTO:-1}"
BUILD_RAHASHER="${BUILD_RAHASHER:-0}"
USE_BREW="${USE_BREW:-auto}"
SETUP_SYSTEMD="${SETUP_SYSTEMD:-auto}"
NODE_MAJOR=24
NPM_VERSION="${NPM_VERSION:-11.20.0}"              # pinned, run directly by Node 24 (see npm_run)
NJS_VERSION="${NJS_VERSION:-1.0.2}"

# Used only when romm.env is first generated (edit romm.env afterwards):
DEFAULT_DB_HOST="${DEFAULT_DB_HOST:-127.0.0.1}"
DEFAULT_DB_PORT="${DEFAULT_DB_PORT:-12715}"
DEFAULT_BASE_URL="${DEFAULT_BASE_URL:-https://DOMAIN_NAME${ROMM_URL_PREFIX}}"

# Keep the install itself gentle on a small server, including its thread count.
# The server has 128 CPUs and caps virtual memory at ~10 GB per process; tools
# that size their thread pools by CPU count (Rolldown via rayon, 7-Zip, Node's
# own pools) reserve too much address space at once and crash with
# "Resource temporarily unavailable" (EAGAIN) when creating threads.
export MAKEFLAGS="-j2" UV_CONCURRENT_BUILDS=2 UV_CONCURRENT_INSTALLS=2 UV_CONCURRENT_DOWNLOADS=2
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-2}"   # Rust data-parallel pools (Rolldown, Lightning CSS)
# Each new thread may get its own glibc malloc arena, which reserves 64 MiB of
# address space; with 128 CPUs glibc allows 1024 of them, and the server caps
# virtual memory at ~10 GB per process. Two arenas keep that reservation tiny.
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
export TOKIO_WORKER_THREADS="${TOKIO_WORKER_THREADS:-2}"
export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-2}" # libuv (Node) worker pool, default 4
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=1024 --v8-pool-size=2}"
# ------------------------------------------------------------------------------

ROMM_URL_PREFIX="${ROMM_URL_PREFIX%/}"
export ROMM_URL_PREFIX
APP="${ROMM_HOME}/app"
BUILD="${ROMM_HOME}/build"
DL="${BUILD}/downloads"
TOOLS="${ROMM_HOME}/tools/bin"
LIBDIR="${ROMM_HOME}/lib"
WWW="${ROMM_HOME}/www"
NGX="${ROMM_HOME}/nginx"
ENV_FILE="${ROMM_HOME}/romm.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mWARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ ${EUID} -ne 0 ]] || die "run this as your normal user, not root"
[[ -z ${ROMM_URL_PREFIX} || ${ROMM_URL_PREFIX} == /* ]] || die "ROMM_URL_PREFIX must start with /"
mkdir -p "${ROMM_HOME}" "${BUILD}" "${DL}" "${TOOLS}" "${LIBDIR}" "${ROMM_HOME}/bin" "${ROMM_HOME}/run"

# ------------------------------------------------------------ dependencies ---
BREW=""
if [[ ${USE_BREW} != 0 ]] && have brew; then BREW="$(brew --prefix)"; fi

brew_add_path() { # put a (possibly keg-only) formula's bin dir first on PATH
	local p
	p="$(brew --prefix "$1" 2>/dev/null)" || return 0
	[[ -d ${p}/bin ]] && export PATH="${p}/bin:${PATH}"
	[[ -d ${p}/sbin ]] && export PATH="${p}/sbin:${PATH}"
	return 0
}

need() { # need <command> <brew formula>
	local cmd=$1 formula=$2
	if [[ -n ${BREW} ]]; then brew_add_path "${formula}"; fi
	have "${cmd}" && return 0
	if [[ -n ${BREW} ]]; then
		log "installing ${formula} with brew (for ${cmd})"
		brew install "${formula}"
		brew_add_path "${formula}"
	fi
	have "${cmd}" || die "'${cmd}' not found. Install it (brew formula: ${formula}) and re-run."
}

log "checking dependencies"
need git git
need curl curl
need make make
have cc || have gcc || need gcc gcc
# uv: pipx first (that's how you install Python tools), brew as fallback
export PATH="${HOME}/.local/bin:${PATH}"
if ! have uv && have pipx; then log "installing uv with pipx"; pipx install uv; fi
need uv uv
# RomM's frontend pins Node 24 (engine-strict). node@24 is keg-only in brew, so it
# sits next to your Node 26 without replacing it.
if [[ -n ${BREW} ]]; then
	brew list --versions "node@${NODE_MAJOR}" >/dev/null || brew install "node@${NODE_MAJOR}"
	brew_add_path "node@${NODE_MAJOR}"
fi
need node "node@${NODE_MAJOR}"
NODE_BIN="$(readlink -f "$(command -v node)")"
[[ "$("${NODE_BIN}" -p 'process.versions.node.split(".")[0]')" == "${NODE_MAJOR}" ]] ||
	die "RomM needs Node ${NODE_MAJOR}, found $("${NODE_BIN}" -v) first on PATH"
need mariadb_config mariadb-connector-c   # to build the Python MariaDB driver
need valkey-server valkey
need 7zz sevenzip
need bsdtar libarchive
if [[ -n ${BREW} ]]; then
	for f in pcre2 zlib libmagic; do brew list --versions "${f}" >/dev/null || brew install "${f}"; done
fi

# Pin runtime binaries into tools/bin so services don't depend on your login PATH
for cmd in node 7zz bsdtar valkey-server valkey-cli uv; do
	have "${cmd}" && ln -sfn "$(command -v "${cmd}")" "${TOOLS}/${cmd}"
done
export PATH="${TOOLS}:${PATH}"

# ------------------------------------------------------------ config file ---
port_busy() { (echo >"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }
pick_port() { # first free port in range, skipping ones already picked
	local p
	for ((p = PORT_MIN; p <= PORT_MAX; p++)); do
		[[ " ${PICKED:-} " == *" ${p} "* ]] && continue
		port_busy "${p}" && continue
		PICKED="${PICKED:-} ${p}"
		echo "${p}"
		return
	done
	die "no free port left in ${PORT_MIN}-${PORT_MAX}"
}

if [[ ! -f ${ENV_FILE} ]]; then
	PICKED=""
	ROMM_PORT_NEW="$(pick_port)"; PICKED+=" ${ROMM_PORT_NEW}"
	DEV_PORT_NEW="$(pick_port)"; PICKED+=" ${DEV_PORT_NEW}"
	REDIS_PORT_NEW="$(pick_port)"
	log "writing ${ENV_FILE} (ports ${ROMM_PORT_NEW}/${DEV_PORT_NEW}/${REDIS_PORT_NEW})"
	umask 077
	cat >"${ENV_FILE}" <<EOF
# RomM bare-metal config. Plain KEY=value, no inline comments (sourced by bash).
# After editing: re-run install.sh (regenerates nginx/valkey configs and restarts)

# Public URL including the subpath (used in password reset / invite links)
ROMM_BASE_URL=${DEFAULT_BASE_URL}
ROMM_SESSION_SECURE_COOKIE=true
TZ=Asia/Jerusalem

ROMM_BASE_PATH=${ROMM_HOME}/data
ROMM_TMP_PATH=${ROMM_HOME}/tmp

# Ports from the ${PORT_MIN}-${PORT_MAX} range, all bound to 127.0.0.1.
# They were free at install time; make sure none collides with a stopped app of yours.
ROMM_PORT=${ROMM_PORT_NEW}
DEV_PORT=${DEV_PORT_NEW}
REDIS_PORT=${REDIS_PORT_NEW}

# The server's MariaDB
ROMM_DB_DRIVER=mariadb
DB_HOST=${DEFAULT_DB_HOST}
DB_PORT=${DEFAULT_DB_PORT}
DB_NAME=romm
DB_USER=romm
DB_PASSWD=$(rand_hex 24)

# Valkey (run by this setup)
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=$(rand_hex 24)
REDIS_DB=0

ROMM_AUTH_SECRET_KEY=$(rand_hex 32)

# Small-server tuning
WEB_SERVER_CONCURRENCY=1
SCAN_WORKERS=2
ROM_PATCHER_MAX_CONCURRENCY=1
ROM_PATCHER_MAX_FILE_SIZE_BYTES=402653184
ROM_CONVERTO_MAX_CONCURRENCY=1
LOGLEVEL=INFO
OTEL_SDK_DISABLED=true

# Metadata providers (fill in what you have)
IGDB_CLIENT_ID=
IGDB_CLIENT_SECRET=
SCREENSCRAPER_USER=
SCREENSCRAPER_PASSWORD=
STEAMGRIDDB_API_KEY=
RETROACHIEVEMENTS_API_KEY=
HASHEOUS_API_ENABLED=false
LAUNCHBOX_API_ENABLED=false

# Optional features
ENABLE_RESCAN_ON_FILESYSTEM_CHANGE=false
ROM_CONVERTO_ENABLED=false
EOF
	umask 022
fi
chmod 600 "${ENV_FILE}"
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

# ----------------------------------------------------------- data/library ---
mkdir -p "${ROMM_BASE_PATH}"/{resources,assets,config} "${ROMM_TMP_PATH}"
[[ -f ${ROMM_BASE_PATH}/config/config.yml ]] || : >"${ROMM_BASE_PATH}/config/config.yml"
LIB="${ROMM_BASE_PATH}/library"
if [[ ! -e ${LIB} ]]; then
	if [[ -d ${ROMS_DIR}/roms ]]; then
		ln -s "${ROMS_DIR}" "${LIB}"                         # ROMS_DIR already has a roms/ folder
	else
		mkdir -p "${LIB}" && ln -s "${ROMS_DIR}" "${LIB}/roms" # ROMS_DIR holds the platform folders
	fi
	log "library: ${LIB} -> $(readlink -f "${LIB}/roms" 2>/dev/null || echo "${ROMS_DIR}")"
fi
[[ -d ${ROMS_DIR} ]] || warn "${ROMS_DIR} doesn't exist yet"

# ------------------------------------------------------------- app source ---
log "fetching RomM ${ROMM_VERSION}"
if [[ ! -d ${APP}/.git ]]; then
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${ROMM_VERSION}" https://github.com/rommapp/romm.git "${APP}"
else
	git -C "${APP}" fetch --quiet --depth 1 origin "refs/tags/${ROMM_VERSION}:refs/tags/${ROMM_VERSION}"
	git -C "${APP}" -c advice.detachedHead=false checkout --quiet --force "${ROMM_VERSION}"
fi
DOCKERFILE="${APP}/docker/Dockerfile"

# Pinned values straight from this release's Dockerfile, so versions and checksums
# match what the official image ships.
darg() {
	local v
	v="$(grep -m1 -E "^ARG $1=" "${DOCKERFILE}" | cut -d= -f2-)"
	[[ -n ${v} ]] || die "could not read ARG $1 from the Dockerfile (layout changed?)"
	echo "${v}"
}

# ---------------------------------------------------------------- backend ---
log "installing backend Python environment (uv sync)"
sync_args=(--frozen --no-dev)
# psycopg-c needs pg_config to build and is only used with PostgreSQL
[[ ${ROMM_DB_DRIVER} == postgresql ]] || sync_args+=(--no-install-package psycopg-c)
# Bake an rpath into the MariaDB driver so it finds brew's libmariadb at runtime
rpaths=""
for d in $(mariadb_config --libs | tr ' ' '\n' | sed -n 's/^-L//p'); do rpaths+=" -Wl,-rpath,${d}"; done
[[ -n ${BREW} ]] && rpaths+=" -Wl,-rpath,${BREW}/lib"
(cd "${APP}" && LDFLAGS="${LDFLAGS:-}${rpaths}" uv sync "${sync_args[@]}")
PY="${APP}/.venv/bin/python"

log "patching container-specific paths"
"${PY}" - "${APP}/backend" "${WWW}" "${ROMM_VERSION}" "${ROMM_URL_PREFIX}" <<'PY'
import pathlib, sys
backend, www, version, prefix = pathlib.Path(sys.argv[1]), *sys.argv[2:5]
def patch(rel, old, new):
    p = backend / rel
    s = p.read_text()
    if old == new or new in s:
        return
    if old not in s:
        sys.exit(f"patch failed: {old!r} not found in {rel} (upstream changed it)")
    p.write_text(s.replace(old, new, 1))
patch("utils/archives.py", 'SEVEN_ZIP_PATH = "/usr/bin/7zz"',
      'SEVEN_ZIP_PATH = __import__("shutil").which("7zz") or "/usr/bin/7zz"')
patch("utils/archives.py", 'BSDTAR_PATH = "/usr/bin/bsdtar"',
      'BSDTAR_PATH = __import__("shutil").which("bsdtar") or "/usr/bin/bsdtar"')
patch("handler/easyrpg/__init__.py", 'f"/var/www/html{RTP_WEB_PATH}"', f'f"{www}{{RTP_WEB_PATH}}"')
patch("__version__.py", '__version__ = "<version>"', f'__version__ = "{version}"')
# Cover/screenshot URLs, also pushed over the websocket during scans
patch("config/__init__.py", 'FRONTEND_RESOURCES_PATH: Final[str] = "/assets/romm/resources"',
      f'FRONTEND_RESOURCES_PATH: Final[str] = "{prefix}/assets/romm/resources"')
PY

# python-magic dlopens libmagic.so.1; expose brew's copy if the system has none
if ! "${PY}" -c 'import magic; magic.from_buffer(b"x")' 2>/dev/null; then
	found=""
	[[ -n ${BREW} ]] && found="$(find "${BREW}/lib" "$(brew --prefix libmagic)/lib" -maxdepth 1 -name 'libmagic.so.1' 2>/dev/null | head -1)"
	[[ -n ${found} ]] || die "libmagic.so.1 not found (brew install libmagic)"
	ln -sfn "${found}" "${LIBDIR}/libmagic.so.1"
fi
LD_LIBRARY_PATH="${LIBDIR}" "${PY}" -c 'import magic, mariadb; magic.from_buffer(b"x")' ||
	die "backend libraries don't load, see the error above"

# npm is run as "<node 24> npm-cli.js", never via npm/npx on PATH: npm's script
# shell resolves `node` through every node_modules/.bin up to /, so a stray
# `node` there (or another Node first on PATH) would silently run npm, and with
# it the engine check, under the wrong version.
NPM_DIR="${ROMM_HOME}/tools/npm-${NPM_VERSION}"
if [[ ! -f ${NPM_DIR}/bin/npm-cli.js ]]; then
	log "fetching npm ${NPM_VERSION}"
	curl -fsSL -o "${DL}/npm-${NPM_VERSION}.tgz" "https://registry.npmjs.org/npm/-/npm-${NPM_VERSION}.tgz"
	"${PY}" - "${DL}/npm-${NPM_VERSION}.tgz" "${NPM_VERSION}" <<'PY' || die "npm tarball failed its integrity check"
import base64, hashlib, json, sys, urllib.request
path, version = sys.argv[1:3]
meta = json.load(urllib.request.urlopen(f"https://registry.npmjs.org/npm/{version}"))
algo, want = meta["dist"]["integrity"].split("-", 1)
got = base64.b64encode(hashlib.new(algo, open(path, "rb").read()).digest()).decode()
sys.exit(0 if got == want else f"integrity mismatch for npm {version}")
PY
	rm -rf "${NPM_DIR}" && mkdir -p "${NPM_DIR}"
	tar -xzf "${DL}/npm-${NPM_VERSION}.tgz" -C "${NPM_DIR}" --strip-components=1
fi
npm_run() { "${NODE_BIN}" "${NPM_DIR}/bin/npm-cli.js" --no-update-notifier "$@"; }

log "installing RomPatcher.js"
(cd "${APP}/backend/utils/rom_patcher" &&
	npm_run ci --ignore-scripts --no-audit --no-fund --loglevel=error &&
	rm -rf rom-patcher-js &&
	cp -r node_modules/rom-patcher/rom-patcher-js ./rom-patcher-js)

# --------------------------------------------------------------- frontend ---
log "building frontend"
build_args=()
if [[ -n ${ROMM_URL_PREFIX} ]]; then
	"${PY}" "${SCRIPT_DIR}/subpath.py" src "${APP}/frontend" "${ROMM_URL_PREFIX}"
	build_args=("--base=${ROMM_URL_PREFIX}/")
fi
(cd "${APP}/frontend" &&
	rm -rf dist &&
	npm_run ci --ignore-scripts --no-audit --no-fund --loglevel=error &&
	# what `npm run build` would run, minus the PATH lookup of `node`
	"${NODE_BIN}" node_modules/vite/bin/vite.js build ${build_args[@]+"${build_args[@]}"} >"${BUILD}/frontend-build.log" 2>&1) ||
	{ tail -30 "${BUILD}/frontend-build.log"; die "frontend build failed"; }
[[ -z ${ROMM_URL_PREFIX} ]] || "${PY}" "${SCRIPT_DIR}/subpath.py" dist "${APP}/frontend/dist" "${ROMM_URL_PREFIX}"

# Assemble the web root the way the Dockerfile does
rm -rf "${WWW}.new"
cp -r "${APP}/frontend/dist" "${WWW}.new"
cp -r "${APP}/frontend/assets/." "${WWW}.new/assets/"
mkdir -p "${WWW}.new/assets/romm"
ln -sfn "${ROMM_BASE_PATH}/resources" "${WWW}.new/assets/romm/resources"

fetch() { # fetch <url> <sha256> <dest>
	local url=$1 sum=$2 dest=$3
	if [[ ! -f ${dest} ]] || ! echo "${sum}  ${dest}" | sha256sum -c --status -; then
		curl -fsSL --retry 3 -o "${dest}.part" "${url}" || return 1
		echo "${sum}  ${dest}.part" | sha256sum -c --status - || { rm -f "${dest}.part"; warn "checksum mismatch: ${url}"; return 1; }
		mv "${dest}.part" "${dest}"
	fi
}

if [[ ${INSTALL_EMULATORS} == 1 ]]; then
	log "fetching in-browser emulators"
	A="${WWW}.new/assets"
	v="$(darg EMULATORJS_VERSION)"
	if fetch "https://github.com/EmulatorJS/EmulatorJS/releases/download/v${v}/${v}.7z" \
		"$(darg EMULATORJS_SHA256)" "${DL}/emulatorjs-${v}.7z"; then
		7zz x -y -mmt2 -bso0 -bsp0 "${DL}/emulatorjs-${v}.7z" -o"${A}/emulatorjs"
	else warn "EmulatorJS skipped"; fi

	v="$(darg RUFFLE_VERSION)"
	if fetch "https://github.com/ruffle-rs/ruffle/releases/download/${v}/$(darg RUFFLE_FILE)" \
		"$(darg RUFFLE_SHA256)" "${DL}/$(darg RUFFLE_FILE)"; then
		mkdir -p "${A}/ruffle" && bsdtar -xf "${DL}/$(darg RUFFLE_FILE)" -C "${A}/ruffle"
	else warn "Ruffle skipped"; fi

	v="$(darg JSDOS_VERSION)"
	if fetch "https://github.com/caiiiycuk/js-dos/releases/download/v${v}/release.zip" \
		"$(darg JSDOS_SHA256)" "${DL}/jsdos-${v}.zip"; then
		rm -rf "${BUILD}/jsdos" && mkdir -p "${BUILD}/jsdos" && bsdtar -xf "${DL}/jsdos-${v}.zip" -C "${BUILD}/jsdos"
		rm -rf "${BUILD}/jsdos/dist/index.html" "${BUILD}/jsdos/dist/emulators/types"
		find "${BUILD}/jsdos/dist" \( -name '*.map' -o -name '*.symbols' \) -delete
		cp -r "${BUILD}/jsdos/dist" "${A}/jsdos"
	else warn "js-dos skipped"; fi

	c="$(darg FAKE08_P3A_COMMIT)"
	mkdir -p "${A}/pico8"
	fetch "https://raw.githubusercontent.com/fabkury/p3a/${c}/webui/pico8/fake08.js" "$(darg FAKE08_JS_SHA256)" "${DL}/fake08-${c}.js" &&
		fetch "https://raw.githubusercontent.com/fabkury/p3a/${c}/webui/pico8/fake08.wasm" "$(darg FAKE08_WASM_SHA256)" "${DL}/fake08-${c}.wasm" &&
		cp "${DL}/fake08-${c}.js" "${A}/pico8/fake08.js" && cp "${DL}/fake08-${c}.wasm" "${A}/pico8/fake08.wasm" ||
		warn "FAKE-08 skipped"

	v="$(darg EASYRPG_VERSION)"
	c="$(darg EASYRPG_RTP_COMMIT)"
	if fetch "https://easyrpg.org/downloads/player/${v}/easyrpg-player-${v}-js.tar.gz" \
		"$(darg EASYRPG_SHA256)" "${DL}/easyrpg-${v}.tar.gz" &&
		fetch "https://github.com/EasyRPG/RTP/archive/${c}.tar.gz" "$(darg EASYRPG_RTP_SHA256)" "${DL}/easyrpg-rtp-${c}.tar.gz"; then
		mkdir -p "${A}/easyrpg/rtp"
		tar -xzf "${DL}/easyrpg-${v}.tar.gz" -C "${A}/easyrpg" --strip-components=1
		rm -rf "${A}/easyrpg/games"
		tar -xzf "${DL}/easyrpg-rtp-${c}.tar.gz" -C "${A}/easyrpg/rtp" --strip-components=1
		find "${A}/easyrpg/rtp" \( -name '.git*' -o -name Makefile \) -exec rm -f {} +
	else warn "EasyRPG skipped"; fi
fi

rm -rf "${WWW}.old"
[[ -d ${WWW} ]] && mv "${WWW}" "${WWW}.old"
mv "${WWW}.new" "${WWW}"
rm -rf "${WWW}.old"

# ------------------------------------------------------------ extra tools ---
case "$(uname -m)" in
x86_64) arch=amd64 rc_arch=linux-x64-musl ;;
aarch64 | arm64) arch=arm64 rc_arch=linux-arm64-musl ;;
*) arch=other rc_arch="" ;;
esac

if [[ ${INSTALL_ROM_CONVERTO} == 1 && -n ${rc_arch} ]]; then
	v="$(grep -m1 -oE 'ROM_CONVERTO_VERSION=v[0-9.]+' "${DOCKERFILE}" | cut -d= -f2)"
	sum="$(grep -m1 -oE "${arch}\) rc=\"${rc_arch}\"; sum=\"[0-9a-f]{64}\"" "${DOCKERFILE}" | grep -oE '[0-9a-f]{64}')"
	if [[ -n ${v} && -n ${sum} ]] && fetch "https://github.com/DevYukine/rom-converto/releases/download/${v}/rom-converto-cli-${rc_arch}" \
		"${sum}" "${DL}/rom-converto-${v}"; then
		install -m 755 "${DL}/rom-converto-${v}" "${TOOLS}/rom-converto"
	else warn "rom-converto skipped"; fi
fi

if [[ ${BUILD_RAHASHER} == 1 && ! -x ${TOOLS}/RAHasher ]]; then
	log "building RAHasher"
	have g++ || die "RAHasher needs g++"
	rm -rf "${BUILD}/RALibretro"
	git clone --quiet --filter=blob:none https://github.com/RetroAchievements/RALibretro.git "${BUILD}/RALibretro"
	(cd "${BUILD}/RALibretro" &&
		git -c advice.detachedHead=false checkout --quiet "$(darg RALIBRETRO_COMMIT)" &&
		git submodule update --quiet --init --recursive &&
		sed -i '22a #include <ctime>' ./src/Util.h &&
		sed -i '6a #include <unistd.h>' ./src/libchdr/deps/zlib-1.3.1/gzlib.c \
			./src/libchdr/deps/zlib-1.3.1/gzread.c ./src/libchdr/deps/zlib-1.3.1/gzwrite.c &&
		make -s HAVE_CHD=1 -f ./Makefile.RAHasher &&
		install -m 755 ./bin64/RAHasher "${TOOLS}/RAHasher")
fi

# ------------------------------------------------------ internal nginx ---
NGINX_VERSION="$(darg NGINX_VERSION)"
MOD_ZIP_COMMIT="$(darg NGINX_MOD_ZIP_COMMIT)"
NGX_MODULES="--with-http_gzip_static_module --with-http_sub_module"
NGINX_STAMP="${NGINX_VERSION}-${MOD_ZIP_COMMIT}-${NJS_VERSION}-${NGX_MODULES}"
if [[ "$(cat "${NGX}/.stamp" 2>/dev/null)" != "${NGINX_STAMP}" ]]; then
	log "building nginx ${NGINX_VERSION} with njs ${NJS_VERSION} + mod_zip"
	rm -rf "${BUILD}/nginx" "${BUILD}/njs" "${BUILD}/mod_zip"
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "release-${NGINX_VERSION}" https://github.com/nginx/nginx.git "${BUILD}/nginx"
	git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${NJS_VERSION}" https://github.com/nginx/njs.git "${BUILD}/njs"
	git clone --quiet https://github.com/evanmiller/mod_zip.git "${BUILD}/mod_zip"
	git -C "${BUILD}/mod_zip" -c advice.detachedHead=false checkout --quiet "${MOD_ZIP_COMMIT}"
	cc_opt="" ld_opt=""
	if [[ -n ${BREW} ]]; then cc_opt="-I${BREW}/include" ld_opt="-L${BREW}/lib -Wl,-rpath,${BREW}/lib"; fi
	# shellcheck disable=SC2086
	(cd "${BUILD}/nginx" &&
		NJS_OPENSSL=NO NJS_LIBXSLT=NO NJS_ZLIB=NO NJS_QUICKJS=NO ./auto/configure \
			--prefix="${NGX}" --with-cc-opt="${cc_opt}" --with-ld-opt="${ld_opt}" ${NGX_MODULES} \
			--add-module=../njs/nginx --add-module=../mod_zip >"${BUILD}/nginx-configure.log" 2>&1 ||
		{ tail -30 "${BUILD}/nginx-configure.log"; die "nginx configure failed"; }
		make >"${BUILD}/nginx-make.log" 2>&1 || { tail -30 "${BUILD}/nginx-make.log"; die "nginx build failed"; }
		make install >/dev/null)
	echo "${NGINX_STAMP}" >"${NGX}/.stamp"
fi

log "writing nginx configs"
mkdir -p "${NGX}/conf/conf.d" "${NGX}/conf/js" "${NGX}/tmp"
cp "${APP}/docker/nginx/js/decode.js" "${NGX}/conf/js/decode.js"
"${PY}" - "${APP}" "${NGX}" "${WWW}" <<'PY'
import os, pathlib, re, sys
app, ngx, www = (pathlib.Path(a) for a in sys.argv[1:4])
env = os.environ
prefix = env.get("ROMM_URL_PREFIX", "")

main = (app / "docker/nginx/default.conf").read_text()
main = re.sub(r"^load_module .*\n", "", main, flags=re.M)              # modules are built in
main = main.replace("worker_processes auto;", "worker_processes 1;")
main = main.replace("worker_connections 2048;", "worker_connections 512;")
main = re.sub(r"^\s*ssl_[a-z_]+ .*\n", "", main, flags=re.M)          # no TLS here, the front proxy does it
main = main.replace("pid /tmp/nginx.pid;", f"pid {ngx}/logs/nginx.pid;")
main = re.sub(r"(_temp_path) /tmp/", rf"\1 {ngx}/tmp/", main)
main = main.replace("include /etc/nginx/mime.types;", f"include {ngx}/conf/mime.types;")
main = main.replace("js_import /etc/nginx/js/decode.js;", f"js_import {ngx}/conf/js/decode.js;")
main = main.replace("include /etc/nginx/conf.d/*.conf;", f"include {ngx}/conf/conf.d/*.conf;")
# /dev/stdout can't be opened when stdout is the journald socket; the front proxy logs requests anyway
main = re.sub(r"access_log /dev/stdout[^;]*;", "access_log off;", main)
main = main.replace("error_log /dev/stderr;", "error_log stderr;")
for needle in (" /etc/nginx", " /tmp/", " /dev/std"):
    if needle in main:
        sys.exit(f"nginx.conf still references {needle} - upstream config changed, check it")
(ngx / "conf/nginx.conf").write_text(main)

tpl = (app / "docker/nginx/templates/default.conf.template").read_text()
values = {
    "DEV_PORT": env["DEV_PORT"],
    "ROMM_PORT": env["ROMM_PORT"],
    "IPV6_LISTEN": "",
    "NGINX_ACCESS_LOG": "",
    "ROMM_BASE_PATH": env["ROMM_BASE_PATH"],
    "ROMM_CACHE_BASE_PATH": f'{env.get("ROMM_TMP_PATH") or "/tmp/romm"}/cache',
}
out = re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: values[m.group(1)], tpl)
out = out.replace("root /var/www/html;", f"root {www};\n    absolute_redirect off;")
out = re.sub(r"listen (\d+);", r"listen 127.0.0.1:\1;", out)

if prefix:
    # The front proxy strips the prefix, so this nginx still sees /api, /assets...
    # API JSON carries root-absolute paths (covers, save/state downloads, music
    # streams). Two audiences want them differently:
    #  - RomM's own web page uses them as-is in the browser, so it needs them
    #    WITH the prefix (covers already come prefixed from the patched backend,
    #    which also covers the websocket; the rest is added here).
    #  - Companion apps (Playnite, Argosy, RomMix, Tender, ...) append them to
    #    the server URL they were given, which already ends in the prefix, so
    #    they need RomM's stock paths (prefixed covers would become
    #    /romm/romm/...; RomMix even refuses image paths not starting /assets/).
    # The browser marks the page's own requests Sec-Fetch-Site: same-origin
    # (older browsers without it: a Referer under the prefix). Apps send neither.
    api_old = "    location /api {\n        proxy_pass http://wsgi_server;\n"
    if api_old not in out:
        sys.exit("nginx template: /api location changed upstream, check it")
    headers = "".join(
        f"        {l.strip()}\n"
        for l in out.splitlines()
        if l.strip().startswith("proxy_set_header") and l.startswith("    proxy_set_header")
    )
    never2, never3 = '"/__romm_no_match_2__/', '"/__romm_no_match_3__/'  # distinct: no duplicate search strings
    maps = f"""# Web page vs companion app, see install.sh
map "$http_sec_fetch_site#$http_referer" $romm_web_ui {{
    "~^same-origin#" 1;
    "~^#https?://[^/]+{prefix}/" 1;
    default 0;
}}
map $romm_web_ui $romm_sf1_from {{ 1 '"/api/'; default '"{prefix}/assets/'; }}
map $romm_web_ui $romm_sf1_to {{ 1 '"{prefix}/api/'; default '"/assets/'; }}
map $romm_web_ui $romm_sf2_from {{ 1 '"/assets/'; default '{never2}'; }}
map $romm_web_ui $romm_sf2_to {{ 1 '"{prefix}/assets/'; default '{never2}'; }}
map $romm_web_ui $romm_sf3_from {{ 1 "'/openapi.json'"; default '{never3}'; }}
map $romm_web_ui $romm_sf3_to {{ 1 "'{prefix}/openapi.json'"; default '{never3}'; }}

"""
    out = maps + out.replace(api_old, api_old + headers + """        proxy_set_header Accept-Encoding "";
        sub_filter_types application/json;
        sub_filter_once off;
        sub_filter $romm_sf1_from $romm_sf1_to;
        sub_filter $romm_sf2_from $romm_sf2_to;
        sub_filter $romm_sf3_from $romm_sf3_to;
""", 1)
(ngx / "conf/conf.d/default.conf").write_text(out)

# Location blocks for the server's nginx (included inside its server block)
if prefix:
    port = env["ROMM_PORT"]
    common = f"""        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
"""
    ws = """        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
"""
    (ngx / "romm-proxy.conf").write_text(f"""# RomM - generated by install.sh, symlinked into the server nginx's proxy.d
location = {prefix} {{
    absolute_redirect off;
    return 301 {prefix}/;
}}
location ^~ {prefix}/ws/ {{
        proxy_pass http://127.0.0.1:{port}/ws/;
{common}{ws}}}
location ^~ {prefix}/netplay/ {{
        proxy_pass http://127.0.0.1:{port}/netplay/;
{common}{ws}}}
location ^~ {prefix}/ {{
        proxy_pass http://127.0.0.1:{port}/;
{common}        client_max_body_size 0;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_redirect default;
        proxy_redirect ~^/(.*)$ {prefix}/$1;
}}
""")
PY
"${NGX}/sbin/nginx" -p "${NGX}" -c conf/nginx.conf -t 2>&1 | grep -v '^$' || die "nginx config test failed"
install -m 755 "${SCRIPT_DIR}/romm-run" "${ROMM_HOME}/bin/romm-run"

if [[ -n ${ROMM_URL_PREFIX} ]]; then
	mkdir -p "${PROXY_D_DIR}"
	ln -sfn "${NGX}/romm-proxy.conf" "${PROXY_D_DIR}/romm.conf"
	log "front-proxy config linked: ${PROXY_D_DIR}/romm.conf (reload the server's nginx to apply)"
fi

# --------------------------------------------------------------- MariaDB ---
log "checking database ${DB_NAME} on ${DB_HOST}:${DB_PORT}"
"${PY}" - <<'PY' || die "database setup failed (see above)"
import os, re, sys, mariadb
e = os.environ
db, user, pw = e["DB_NAME"], e["DB_USER"], e["DB_PASSWD"]
admin = e.get("DB_ADMIN_USER")
def conn(u, p, **kw):
    return mariadb.connect(host=e["DB_HOST"], port=int(e["DB_PORT"]), user=u, password=p, **kw)
if admin:
    c = conn(admin, e.get("DB_ADMIN_PASSWD", ""))
    cur = c.cursor()
    # The address MariaDB sees us connecting from. Not always 127.0.0.1: a MariaDB
    # running in Docker sees host connections from the bridge gateway (172.17.0.1).
    cur.execute("SELECT SUBSTRING_INDEX(USER(), '@', -1)")
    seen = cur.fetchone()[0]
    hosts = list(dict.fromkeys(["localhost", "127.0.0.1", seen]))
    cur.execute(f"CREATE DATABASE IF NOT EXISTS `{db}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
    for host in hosts:
        cur.execute(f"CREATE USER IF NOT EXISTS '{user}'@'{host}' IDENTIFIED BY ?", (pw,))
        cur.execute(f"ALTER USER '{user}'@'{host}' IDENTIFIED BY ?", (pw,))
        cur.execute(f"GRANT ALL PRIVILEGES ON `{db}`.* TO '{user}'@'{host}'")
    cur.execute("FLUSH PRIVILEGES")
    c.close()
    print(f"  created/updated database '{db}' and user '{user}' for hosts: {', '.join(hosts)}")
try:
    conn(user, pw, database=db).close()
    print(f"  user '{user}' can connect to '{db}'")
except mariadb.Error as ex:
    m = re.search(r"'[^']*'@'([^']*)'", str(ex))
    host = m.group(1) if m else "127.0.0.1"
    sys.exit(f"""  can't connect as '{user}': {ex}
  Either re-run with DB_ADMIN_USER=... DB_ADMIN_PASSWD=... (e.g. your MariaDB root login),
  or run this yourself as a MariaDB admin:
    CREATE DATABASE IF NOT EXISTS `{db}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER '{user}'@'{host}' IDENTIFIED BY '<DB_PASSWD from romm.env>';
    GRANT ALL PRIVILEGES ON `{db}`.* TO '{user}'@'{host}';""")
PY

# ----------------------------------------------------- stop running RomM ---
# A running (or crash-looping) backend runs migrations on every start; two
# migration runs at once can leave the database half-migrated. Stop everything
# before touching the schema. The services are started again at the end.
USER_MANAGER=0
systemctl --user show-environment >/dev/null 2>&1 && USER_MANAGER=1
if [[ ${USER_MANAGER} == 1 ]]; then
	if systemctl --user list-units --all --plain --no-legend 'romm*' 2>/dev/null | grep -q .; then
		log "stopping RomM services"
		systemctl --user stop romm.target 'romm-*.service' || true
	fi
fi
# Also catches components started by hand with romm-run
running="$(pgrep -u "$(id -u)" -af "${ROMM_HOME}/(bin/romm-run|app/\.venv/bin/)" || true)"
if [[ -n ${running} ]]; then
	printf '%s\n' "${running}" >&2
	die "RomM processes are still running (above); stop them and re-run"
fi

# ------------------------------------------------------------- migrations ---
# Run RomM's migrations here rather than leaving them to the first service start:
# some create triggers, which MariaDB refuses while binary logging is on unless
# log_bin_trust_function_creators=1 or the user holds SUPER (error 1419). With the
# admin login available, flip the setting on just for this run and restore it.
db_admin() { # db_admin <sql>  -> prints the first row, tab-separated
	"${PY}" - "$1" <<'PY'
import os, sys, mariadb
e = os.environ
c = mariadb.connect(host=e["DB_HOST"], port=int(e["DB_PORT"]), user=e["DB_ADMIN_USER"], password=e.get("DB_ADMIN_PASSWD", ""))
cur = c.cursor(); cur.execute(sys.argv[1])
if cur.description: print("\t".join(str(v) for v in cur.fetchone()))
c.close()
PY
}
restore_trust=""
if [[ -n ${DB_ADMIN_USER:-} ]]; then
	read -r log_bin trust < <(db_admin "SELECT @@log_bin, @@log_bin_trust_function_creators")
	if [[ ${log_bin} == 1 && ${trust} == 0 ]]; then
		log "binary logging is on: allowing trigger creation for the duration of the migrations"
		db_admin "SET GLOBAL log_bin_trust_function_creators = 1"
		restore_trust=1
		trap 'db_admin "SET GLOBAL log_bin_trust_function_creators = 0" || true' EXIT
	fi
fi
log "running database migrations"
if ! (cd "${APP}/backend" && PYTHONPATH="${APP}/backend" LD_LIBRARY_PATH="${LIBDIR}" \
	"${APP}/.venv/bin/alembic" upgrade head) >"${BUILD}/migrations.log" 2>&1; then
	tail -15 "${BUILD}/migrations.log"
	grep -q "1419\|not allowed to create triggers" "${BUILD}/migrations.log" &&
		die "migrations need to create triggers; re-run with DB_ADMIN_USER=... DB_ADMIN_PASSWD=..."
	die "database migrations failed (full log: ${BUILD}/migrations.log)"
fi
if [[ -n ${restore_trust} ]]; then
	db_admin "SET GLOBAL log_bin_trust_function_creators = 0"
	trap - EXIT
fi

# ---------------------------------------------------------------- Valkey ---
mkdir -p "${ROMM_HOME}/valkey/data"
umask 077
cat >"${ROMM_HOME}/valkey/valkey.conf" <<EOF
bind 127.0.0.1
port ${REDIS_PORT}
requirepass ${REDIS_PASSWORD}
dir ${ROMM_HOME}/valkey/data
save 3600 1
daemonize no
io-threads 1
# stay under the 1 GiB service limit; refuse writes rather than silently evicting sessions
maxmemory 768mb
maxmemory-policy noeviction
EOF
umask 022

# ---------------------------------------------------------------- systemd ---
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
[[ ${SETUP_SYSTEMD} == auto ]] && SETUP_SYSTEMD=1

unit() { # unit <name> <component> <description> <memory max> <after...>
	local name=$1 comp=$2 desc=$3 mem=$4
	shift 4
	cat >"${UNIT_DIR}/${name}.service" <<EOF
[Unit]
Description=RomM ${desc}
PartOf=romm.target
After=$*

[Service]
Type=simple
Environment=ROMM_HOME=${ROMM_HOME}
ExecStart=${ROMM_HOME}/bin/romm-run ${comp}
Restart=on-failure
RestartSec=5
TimeoutStartSec=600
TimeoutStopSec=60
MemoryMax=${mem}
CPUQuota=200%

[Install]
WantedBy=romm.target
EOF
}

if [[ ${SETUP_SYSTEMD} == 1 ]]; then
	log "installing systemd user units"
	mkdir -p "${UNIT_DIR}"
	rm -f "${UNIT_DIR}/romm-mariadb.service"
	cat >"${UNIT_DIR}/romm.target" <<EOF
[Unit]
Description=RomM (all services)
Wants=romm-valkey.service romm-backend.service romm-worker.service romm-scan-worker.service romm-cron.service romm-nginx.service

[Install]
WantedBy=default.target
EOF
	unit romm-valkey valkey "Valkey" 1G
	unit romm-backend backend "backend (gunicorn)" 1G romm-valkey.service
	unit romm-worker worker "task worker" 1G romm-backend.service
	unit romm-scan-worker scan-worker "scan worker" 1G romm-backend.service
	unit romm-cron cron "task scheduler" 512M romm-backend.service
	unit romm-nginx nginx "internal nginx" 256M romm-backend.service
	unit romm-watcher watcher "library watcher (optional)" 512M romm-backend.service
	unit romm-streaming-worker streaming-worker "streaming worker (optional)" 1G romm-backend.service

	if [[ ${USER_MANAGER} == 0 ]]; then
		warn "systemd --user isn't reachable from this shell; units written to ${UNIT_DIR} but not started"
	else
	systemctl --user daemon-reload
	systemctl --user enable romm.target >/dev/null
	systemctl --user restart romm.target
	log "started. Status: systemctl --user list-units 'romm*'"
	fi
	if [[ ${USER_MANAGER} == 1 ]] && ! loginctl show-user "${USER}" -p Linger 2>/dev/null | grep -q yes; then
		warn "lingering is off for ${USER}: services stop when you log out ('loginctl enable-linger' needs the admin)"
	fi
else
	log "SETUP_SYSTEMD=0: start components with ${ROMM_HOME}/bin/romm-run <component>"
fi

log "done. Internal: http://127.0.0.1:${ROMM_PORT}  Public: ${ROMM_BASE_URL}"
