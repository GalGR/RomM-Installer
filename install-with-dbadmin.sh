#!/usr/bin/env bash
# install-with-dbadmin.sh - run install.sh with the MariaDB admin login
# (DB_ADMIN_USER / DB_ADMIN_PASSWD) kept in a private file next to this script.
#
#   ./install-with-dbadmin.sh                      # same as ./install.sh, plus the admin login
#   ROMM_VERSION=5.5.0 ./install-with-dbadmin.sh   # any other variables/arguments pass through
#
# Where the login comes from, in order:
#   1. DB_ADMIN_USER and DB_ADMIN_PASSWD already set in the environment: used as
#      given, and saved to the file (created or updated) for next time.
#   2. .romm-dbadmin.env next to this script.
#   3. Neither (or the file is empty/unreadable): offers to create the file by
#      asking for the login (interactive terminals only).
#
# The file must belong to you and be readable by you only (mode 600 or 400);
# otherwise the script refuses to read it and stops. It holds two lines,
# single-quoted, so it can also be loaded with `set -a; . file`:
#   DB_ADMIN_USER='root'
#   DB_ADMIN_PASSWD='...'
# This is the MariaDB admin account (e.g. the root login of Ultra.cc's MariaDB),
# not a Linux account: nothing here needs Linux root or sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.romm-dbadmin.env"
INSTALLER="${SCRIPT_DIR}/install.sh"

info() { printf '\033[0;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f ${INSTALLER} ]] || die "install.sh not found next to this script (${SCRIPT_DIR})"

# --- file checks ----------------------------------------------------------------
# Refuses (and exits) if the file exists but isn't private to the current user.
check_file_rights() {
	[[ -e ${ENV_FILE} || -L ${ENV_FILE} ]] || return 0
	if [[ -L ${ENV_FILE} ]]; then
		die "${ENV_FILE} is a symlink. Refusing to use it; replace it with a regular file."
	fi
	[[ -f ${ENV_FILE} ]] || die "${ENV_FILE} exists but is not a regular file."
	local mode owner
	mode="$(stat -c '%a' -- "${ENV_FILE}")"
	owner="$(stat -c '%u' -- "${ENV_FILE}")"
	if [[ ${owner} != "$(id -u)" ]]; then
		die "${ENV_FILE} is owned by uid ${owner}, not by you ($(id -u)).
       It holds your MariaDB admin password, so it must be yours alone. Refusing to read it."
	fi
	if (((8#${mode} & 8#077) != 0)); then
		die "${ENV_FILE} has mode ${mode}, so other users on this server can read or change it.
       It holds your MariaDB admin password. Refusing to read it. Fix it with:
         chmod 600 '${ENV_FILE}'
       (and consider changing the password, since it may already have been read)."
	fi
	if [[ ! -r ${ENV_FILE} ]]; then
		die "${ENV_FILE} is not readable by you (mode ${mode}). Fix it with: chmod 600 '${ENV_FILE}'"
	fi
}

# Parses the file without executing it. Accepts KEY='single quoted' (as written
# by this script), KEY="double quoted" (no escapes) or KEY=raw value, with an
# optional leading "export ". Sets FILE_USER, FILE_PASSWD and FILE_HAS_PASSWD.
read_file() {
	FILE_USER="" FILE_PASSWD="" FILE_HAS_PASSWD=0
	local line key value
	while IFS= read -r line || [[ -n ${line} ]]; do
		line="${line%$'\r'}"
		[[ ${line} =~ ^[[:space:]]*(#|$) ]] && continue
		[[ ${line} =~ ^[[:space:]]*(export[[:space:]]+)?(DB_ADMIN_USER|DB_ADMIN_PASSWD)=(.*)$ ]] || continue
		key="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
		if [[ ${#value} -ge 2 && ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
			value="${value:1:${#value}-2}"
			value="${value//\'\\\'\'/\'}" # undo '\'' escaping
		elif [[ ${#value} -ge 2 && ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
			value="${value:1:${#value}-2}"
		fi
		if [[ ${key} == DB_ADMIN_USER ]]; then
			FILE_USER="${value}"
		else
			FILE_PASSWD="${value}" FILE_HAS_PASSWD=1
		fi
	done <"${ENV_FILE}"
}

sq() { # single-quote a value for the env file
	local v=${1//\'/\'\\\'\'}
	printf "'%s'" "${v}"
}

# Writes the file atomically, private from the first byte (umask 077 + chmod 600).
write_file() {
	local user=$1 passwd=$2 tmp
	tmp="$(umask 077 && mktemp "${SCRIPT_DIR}/.romm-dbadmin.env.XXXXXX")"
	{
		printf '# MariaDB admin login for install-with-dbadmin.sh. Keep it mode 600.\n'
		printf 'DB_ADMIN_USER=%s\n' "$(sq "${user}")"
		printf 'DB_ADMIN_PASSWD=%s\n' "$(sq "${passwd}")"
	} >"${tmp}"
	chmod 600 "${tmp}"
	mv -f "${tmp}" "${ENV_FILE}"
}

prompt_and_create() {
	local why=$1 answer user pass1 pass2 tries=0
	if [[ ! -t 0 ]]; then
		die "${why}, and this isn't an interactive terminal, so I can't ask for the login.
       Either set DB_ADMIN_USER and DB_ADMIN_PASSWD in the environment (they'll be saved),
       or run this script from a terminal."
	fi
	printf '%s.\n' "${why}"
	read -r -p "Create ${ENV_FILE} now? [Y/n] " answer
	[[ -z ${answer} || ${answer} =~ ^[Yy] ]] || die "not created; nothing was run."
	read -r -p "MariaDB admin user [root]: " user
	user="${user:-root}"
	while :; do
		read -r -s -p "Password for MariaDB user '${user}': " pass1; echo
		read -r -s -p "Repeat the password: " pass2; echo
		[[ ${pass1} == "${pass2}" ]] && break
		((++tries < 3)) || die "passwords didn't match 3 times; nothing was saved."
		echo "The passwords don't match, try again."
	done
	write_file "${user}" "${pass1}"
	info "saved the login to ${ENV_FILE} (mode 600)"
	DB_ADMIN_USER="${user}" DB_ADMIN_PASSWD="${pass1}"
}

# --- main -----------------------------------------------------------------------
check_file_rights

env_user_set=0 env_pass_set=0
[[ -n ${DB_ADMIN_USER:-} ]] && env_user_set=1
[[ -n ${DB_ADMIN_PASSWD+x} ]] && env_pass_set=1

if ((env_user_set || env_pass_set)); then
	((env_user_set && env_pass_set)) ||
		die "only one of DB_ADMIN_USER / DB_ADMIN_PASSWD is set in the environment; set both (or neither, to use ${ENV_FILE})."
	[[ ${DB_ADMIN_USER} != *$'\n'* && ${DB_ADMIN_PASSWD} != *$'\n'* ]] || die "the login can't contain line breaks."
	info "using DB_ADMIN_USER / DB_ADMIN_PASSWD from the environment (user '${DB_ADMIN_USER}')"
	if [[ -f ${ENV_FILE} ]]; then
		read_file
		if [[ ${FILE_USER} != "${DB_ADMIN_USER}" || ${FILE_HAS_PASSWD} != 1 || ${FILE_PASSWD} != "${DB_ADMIN_PASSWD}" ]]; then
			write_file "${DB_ADMIN_USER}" "${DB_ADMIN_PASSWD}"
			info "updated ${ENV_FILE} with it"
		fi
	else
		write_file "${DB_ADMIN_USER}" "${DB_ADMIN_PASSWD}"
		info "saved it to ${ENV_FILE} (mode 600) for next time"
	fi
elif [[ ! -f ${ENV_FILE} ]]; then
	prompt_and_create "No ${ENV_FILE} found"
elif [[ ! -s ${ENV_FILE} ]]; then
	prompt_and_create "${ENV_FILE} is empty"
else
	read_file
	if [[ -z ${FILE_USER} || ${FILE_HAS_PASSWD} != 1 ]]; then
		prompt_and_create "${ENV_FILE} doesn't contain both DB_ADMIN_USER and DB_ADMIN_PASSWD (it will be replaced)"
	else
		DB_ADMIN_USER="${FILE_USER}" DB_ADMIN_PASSWD="${FILE_PASSWD}"
		info "using the MariaDB admin login from ${ENV_FILE} (user '${DB_ADMIN_USER}')"
	fi
fi

export DB_ADMIN_USER DB_ADMIN_PASSWD
exec bash "${INSTALLER}" "$@"
