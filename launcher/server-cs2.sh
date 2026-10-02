#!/usr/bin/env bash
# =============================================================================
#  CS2NEXUS  -  CS2 SERVER MANAGER / LAUNCHER  -  /opt/server-cs2.sh
#  CS2NEXUS-LAUNCHER (marker used by the launcher self-update check)
#  Ubuntu 22.04 | Counter-Strike 2 dedicated servers | tmux | JSON registry
#
#  Base installation (never modified) : /opt/cs2
#  Managed servers                    : /opt/cs2-servers/<slug>
#  Registry                           : /opt/cs2-servers/servers.json  (ARRAY)
#  Shared plugins                     : /opt/cs2-servers/shared        (see below)
#
#  Large game files are shared through symlinks. Each server gets its own
#  real copies of: cfg, addons, logs, the cs2.sh launcher and the small
#  bin/linuxsteamrt64/cs2 launcher binary.
#
#  Shared plugins: ONE copy in /opt/cs2-servers/shared/addons, symlinked into
#  every server (game/csgo/addons/...). Only counterstrikesharp/plugins/<X>
#  and metamod/plugins/<X> can be shared - never any core files.
#
#  Usage:
#    server-cs2.sh                      interactive menu
#    server-cs2.sh help                 non-interactive commands (cron/systemd)
# =============================================================================

set -u
set -o pipefail
# resolve our own path BEFORE changing directory (relative invocations like ./server-cs2.sh)
SELF=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
readonly SELF
cd / || exit 1

# ------------------------------- Configuration -------------------------------
BASE="/opt/cs2"                       # may be changed by the setup wizard / config file
readonly SERVERS_DIR="/opt/cs2-servers"
readonly CONF_FILE="/etc/cs2nexus.conf"
readonly DB="$SERVERS_DIR/servers.json"
readonly CS2_USER="cs2"
readonly CS2_GROUP="cs2"
readonly CS2_HOME="/home/cs2"
readonly LOCK_FILE="/run/lock/server-cs2.lock"
readonly DEFAULT_MAP="de_dust2"
readonly MIN_PORT=1024
readonly MAX_PORT=65535
readonly MAX_CLIENTS=64
readonly STOP_TIMEOUT=20

# Shared plugins / extras
readonly SHARED_DIR="$SERVERS_DIR/shared"
readonly SHARED_ADDONS="$SHARED_DIR/addons"
readonly SHARED_DB="$SHARED_DIR/plugins.json"
readonly AUTOSTART_DB="$SHARED_DIR/autostart.json"
readonly BACKUP_DIR="$SHARED_DIR/backups"
readonly STATE_DIR="$SHARED_DIR/state"
readonly OPS_LOCK="/run/lock/server-cs2-ops.lock"
readonly BACKUP_KEEP=10
STEAMCMD="/usr/games/steamcmd"
readonly SETTINGS_DB="$SERVERS_DIR/shared/server-settings.json"
readonly PLUGIN_BACKUP_DIR="$SERVERS_DIR/shared/backups/plugins"
readonly PLUGIN_TIMER_UNIT="cs2nexus-plugin-update"
readonly PLUGIN_BACKUP_KEEP=5
# Online sources (overridable for testing through environment variables)
GH_API="${CS2NEXUS_API:-https://api.github.com}"
MM_DROP="${CS2NEXUS_MM_DROP:-https://mms.alliedmods.net/mmsdrop/2.0}"
# Config-file values (see load_conf)
NEXUS_REPO="NEPENTII/CS2Nexus"
NEXUS_BRANCH="main"
EXTRA_PLUGIN_REPOS="Ayrton09/AstraSkins"
GITHUB_TOKEN=""
AUTOUPDATE=0
UPDATE_ACTION="none"        # none | reload : what to do on running servers after a plugin update
readonly STEAM_APPID=730
readonly WATCHDOG_UNIT="cs2-watchdog"
readonly WATCHDOG_MAX_RESTARTS=3
readonly WATCHDOG_WINDOW=600
# Allowed shared-plugin locations, relative to <server>/game/csgo/addons.
# Metamod note: many Metamod plugins are loaded through a .vdf file placed in
# addons/metamod/ and keep binaries elsewhere. Test before sharing them.
readonly -a PLUGIN_PREFIXES=("counterstrikesharp/plugins" "metamod/plugins")

# ------------------------------- Colors / UI ---------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[1;34m'; CYAN=$'\033[1;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
fi

# Informational messages go to MSGFD (2 while producing --json output).
MSGFD=1
ok()       { printf '%s[OK]%s %s\n'      "$GREEN"  "$RESET" "$*" >&"$MSGFD"; }
err()      { printf '%s[ERROR]%s %s\n'   "$RED"    "$RESET" "$*" >&2; }
warn()     { printf '%s[WARN]%s %s\n'    "$YELLOW" "$RESET" "$*" >&"$MSGFD"; }
info()     { printf '%s[INFO]%s %s\n'    "$BLUE"   "$RESET" "$*" >&"$MSGFD"; }
msg_skip() { printf '%s[SKIP]%s %s\n'    "$YELLOW" "$RESET" "$*" >&"$MSGFD"; }
msg_dry()  { printf '%s[DRY-RUN]%s %s\n' "$CYAN"   "$RESET" "$*" >&"$MSGFD"; }

sep()   { printf '%s----------------------------------------%s\n' "$CYAN" "$RESET"; }
dsep()  { printf '%s========================================%s\n' "$CYAN" "$RESET"; }
pause() { echo; read -r -p "Press Enter to continue..." _ || exit 0; }

clear_screen() { clear 2>/dev/null || printf '\033c'; }

header() {
    clear_screen
    dsep
    printf '%s%s%s\n' "$BOLD" "$(printf '%*s' $(( (40 + ${#1}) / 2 )) "$1")" "$RESET"
    dsep
    echo
}

trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# normalize_map <input> -> MAP_NORM: "de_dust2" (normal map) or "workshop:<id>" (Workshop map).
# Accepts a map name, a bare Workshop ID, "workshop:ID" or a steamcommunity link with ?id=...
MAP_NORM=""
normalize_map() {
    local v re='[?&]id=([0-9]{5,12})([^0-9]|$)'
    MAP_NORM=""
    v=$(trim "$1")
    if [[ $v =~ ^workshop:([0-9]{5,12})$ ]]; then MAP_NORM="workshop:${BASH_REMATCH[1]}"
    elif [[ $v =~ ^[0-9]{5,12}$ ]]; then MAP_NORM="workshop:$v"
    elif [[ $v == *steamcommunity.com/* && $v =~ $re ]]; then MAP_NORM="workshop:${BASH_REMATCH[1]}"
    elif [[ $v =~ ^[A-Za-z0-9_]{1,64}$ ]]; then MAP_NORM=$v
    else return 1; fi
}
map_label() { if [[ $1 == workshop:* ]]; then printf 'Workshop map %s' "${1#workshop:}"; else printf '%s' "$1"; fi; }

# ask "Prompt" [default]  -> sets ANSWER ; returns 1 if user typed q (cancel)
ANSWER=""
ask() {
    local prompt=$1 def=${2:-} in
    if [[ -n $def ]]; then
        read -r -p "$prompt [$def]: " in || exit 0
        in=$(trim "$in"); in=${in:-$def}
    else
        read -r -p "$prompt: " in || exit 0
        in=$(trim "$in")
    fi
    if [[ $in == "q" || $in == "Q" ]]; then return 1; fi
    ANSWER=$in
    return 0
}

# confirm_yn "Prompt [Y/n]: " y|n   -> returns 0 for yes
confirm_yn() {
    local prompt=$1 def=$2 in
    read -r -p "$prompt" in || exit 0
    in=$(trim "${in,,}")
    [[ -z $in ]] && in=$def
    [[ $in == y || $in == yes ]]
}

restore_int_trap() { trap 'printf "\n"; exit 130' INT; }
restore_int_trap

# ------------------------------- Ops lock (re-entrant) -----------------------
# Serialises every read-modify-write of the JSON files and long operations
# (sync / update) between the menu, cron jobs and systemd timers.
# fd 8 is closed for tmux (see tmux_cs2) so it can never leak into servers.
OPS_DEPTH=0
lock_ops() {
    local t=${1:-30}
    if ((OPS_DEPTH == 0)); then
        exec 8>"$OPS_LOCK" || { err "Cannot open lock file $OPS_LOCK"; return 1; }
        if ((t == 0)); then
            flock -n 8 || { exec 8>&-; return 1; }
        elif ! flock -w "$t" 8; then
            exec 8>&-
            err "Another manager operation is in progress (lock busy). Try again shortly."
            return 1
        fi
    fi
    OPS_DEPTH=$((OPS_DEPTH + 1))
    return 0
}

unlock_ops() {
    if ((OPS_DEPTH > 0)); then OPS_DEPTH=$((OPS_DEPTH - 1)); fi
    if ((OPS_DEPTH == 0)); then exec 8>&-; fi
    return 0
}

# ------------------------------- Pre-flight ----------------------------------
SHARED_OK=1
AUTOSTART_OK=1

init_shared() {
    install -d -m 755 -- "$SHARED_DIR" "$BACKUP_DIR" "$STATE_DIR" \
        || { err "Cannot create $SHARED_DIR"; exit 1; }
    install -d -m 755 -o "$CS2_USER" -g "$CS2_GROUP" -- "$SHARED_ADDONS" \
        || { err "Cannot create $SHARED_ADDONS"; exit 1; }
    # drop folders: anything placed here becomes a shared plugin automatically
    local pre
    for pre in "${PLUGIN_PREFIXES[@]}"; do
        install -d -m 755 -o "$CS2_USER" -g "$CS2_GROUP" -- \
            "$SHARED_ADDONS/${pre%%/*}" "$SHARED_ADDONS/$pre" \
            || { err "Cannot create $SHARED_ADDONS/$pre"; exit 1; }
    done

    if [[ ! -e $SHARED_DB && ! -L $SHARED_DB ]]; then
        echo "[]" >"$SHARED_DB" || { err "Cannot create $SHARED_DB"; exit 1; }
        chmod 644 "$SHARED_DB"
    fi
    if ! jq -e 'type=="array"' "$SHARED_DB" >/dev/null 2>&1; then
        SHARED_OK=0
        warn "$SHARED_DB is not a valid JSON array. Shared plugin features are disabled until it is fixed."
    fi

    if [[ ! -e $AUTOSTART_DB && ! -L $AUTOSTART_DB ]]; then
        echo "[]" >"$AUTOSTART_DB" || { err "Cannot create $AUTOSTART_DB"; exit 1; }
        chmod 644 "$AUTOSTART_DB"
    fi
    if ! jq -e 'type=="array"' "$AUTOSTART_DB" >/dev/null 2>&1; then
        AUTOSTART_OK=0
        warn "$AUTOSTART_DB is not a valid JSON array. Autostart/watchdog features are disabled until it is fixed."
    fi
}

# preflight [menu|cli]  - the single-instance lock is only taken for the menu
preflight() {
    local mode=${1:-menu}
    if [[ $EUID -ne 0 ]]; then
        err "This manager must be run as root (use: sudo $0)."
        exit 1
    fi
    load_conf
    bootstrap_deps "$mode" || exit 1

    if [[ $mode == menu ]]; then
        exec 9>"$LOCK_FILE" || { err "Cannot open lock file $LOCK_FILE"; exit 1; }
        if ! flock -n 9; then
            err "Another instance of the manager is already running."
            exit 1
        fi
    fi

    if [[ ! -d $SERVERS_DIR ]]; then
        install -d -m 755 "$SERVERS_DIR" || { err "Cannot create $SERVERS_DIR"; exit 1; }
    fi
    if [[ ! -f $DB ]]; then
        echo "[]" >"$DB" || { err "Cannot create $DB"; exit 1; }
        chmod 644 "$DB"
    fi
    if ! jq -e 'type=="array"' "$DB" >/dev/null 2>&1; then
        err "$DB is not a valid JSON array. Fix or move it, then try again."
        exit 1
    fi

    # an existing installation (servers registered, CS2 files in place) skips the wizard
    if [[ $SETUP_DONE != 1 && $(jq 'length' "$DB") -gt 0 ]] && cs2_dir_ok "$BASE"; then
        info "Existing servers detected; marking the first-time setup as done."
        conf_set BASE "$BASE" && conf_set SETUP_DONE 1
    fi
    if [[ $SETUP_DONE != 1 && $mode != menu ]]; then
        err "CS2Nexus is not set up yet. Run the launcher once without arguments to start the setup wizard."
        exit 1
    fi

    if ! id "$CS2_USER" >/dev/null 2>&1; then
        if [[ $mode == menu && $SETUP_DONE != 1 ]]; then ensure_cs2_user || exit 1
        else err "Linux user '$CS2_USER' does not exist."; exit 1; fi
    fi
    init_shared
    init_settings

    if [[ $SETUP_DONE != 1 ]]; then
        run_setup_wizard || { err "Setup was not completed. Run the launcher again to retry."; exit 1; }
    elif ! cs2_dir_ok "$BASE"; then
        if [[ $mode == menu ]]; then
            warn "CS2 server files were not found in $BASE."
            run_setup_wizard || { err "Setup was not completed."; exit 1; }
        else
            err "CS2 server files not found in $BASE."; exit 1
        fi
    fi
}

# ------------------------------- JSON database -------------------------------
# Every JSON write: validate source -> rotating backup -> temp file in the same
# directory -> validate result -> atomic mv. Serialised by the ops lock.
backup_json() {
    local file=$1 base ts f n
    local -a all
    base=$(basename -- "$file")
    [[ -f $file ]] || return 0
    [[ -d $BACKUP_DIR ]] || mkdir -p -- "$BACKUP_DIR" 2>/dev/null || return 0
    ts=$(date +%Y%m%d-%H%M%S-%N)
    if ! cp -p -- "$file" "$BACKUP_DIR/$base.$ts" 2>/dev/null; then
        warn "Could not back up $file"
        return 0
    fi
    mapfile -t all < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$base.*" -print \
        | grep -E "/${base//./\\.}\.[0-9]{8}-[0-9]{6}-[0-9]+\$" | sort)
    n=${#all[@]}
    if ((n > BACKUP_KEEP)); then
        for f in "${all[@]:0:n-BACKUP_KEEP}"; do rm -f -- "$f"; done
    fi
    return 0
}

_json_update_locked() {
    local file=$1; shift
    local dir base tmp
    dir=$(dirname -- "$file"); base=$(basename -- "$file")
    if ! jq -e 'type=="array"' "$file" >/dev/null 2>&1; then
        err "$file is not a valid JSON array; refusing to modify it."
        return 1
    fi
    backup_json "$file"
    tmp=$(mktemp "$dir/.$base.XXXXXX") || { err "mktemp failed"; return 1; }
    if jq "$@" "$file" >"$tmp" && jq -e 'type=="array"' "$tmp" >/dev/null 2>&1; then
        chmod --reference="$file" -- "$tmp" 2>/dev/null || chmod 644 "$tmp"
        mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; err "Cannot write $file"; return 1; }
    else
        rm -f -- "$tmp"
        err "Failed to update $file."
        return 1
    fi
}

# json_update <file> <jq args...> '<filter>'
json_update() {
    local file=$1 rc; shift
    lock_ops || return 1
    _json_update_locked "$file" "$@"; rc=$?
    unlock_ops
    return $rc
}

# db_update <jq args...> '<filter>'   (atomic write, same interface as before)
db_update()        { json_update "$DB" "$@"; }
shared_update()    { json_update "$SHARED_DB" "$@"; }
autostart_update() { json_update "$AUTOSTART_DB" "$@"; }

db_count()   { jq 'length' "$DB"; }
db_next_id() { jq '([.[].id] | max // 0) + 1' "$DB"; }

db_port_registered() { jq -e --argjson p "$1" 'any(.[]; .port == $p)' "$DB" >/dev/null 2>&1; }
db_name_taken() {
    jq -e --arg n "${1,,}" --arg s "$2" \
        'any(.[]; ((.name | ascii_downcase) == $n) or (.slug == $s))' "$DB" >/dev/null 2>&1
}

S_ID=""; S_NAME=""; S_SLUG=""; S_PORT=""; S_MAX=""; S_MAP=""; S_PATH=""
load_server() {
    local row id=$((10#$1))
    row=$(jq -r --argjson id "$id" \
        '.[] | select(.id == $id) | [.id,.name,.slug,.port,.maxplayers,.map,.path] | @tsv' "$DB") || return 1
    [[ -n $row ]] || return 1
    IFS=$'\t' read -r S_ID S_NAME S_SLUG S_PORT S_MAX S_MAP S_PATH <<<"$row"
}

# ------------------------------- Per-server state ----------------------------
# "manual stop" marker: the watchdog never restarts a server the admin stopped.
manual_stop_file() { printf '%s/manual-stop-%s' "$STATE_DIR" "$1"; }
mark_manual_stop() {
    mkdir -p -- "$STATE_DIR" 2>/dev/null
    : >"$(manual_stop_file "$1")" 2>/dev/null
    return 0
}
clear_manual_stop() { rm -f -- "$(manual_stop_file "$1")"; }
clear_server_state() {
    local id=$1
    rm -f -- "$STATE_DIR/manual-stop-$id" "$STATE_DIR/restarts-$id"
    if ((AUTOSTART_OK)) && jq -e --argjson id "$id" 'index($id) != null' "$AUTOSTART_DB" >/dev/null 2>&1; then
        autostart_update --argjson id "$id" 'map(select(. != $id))' >/dev/null
    fi
}

# ------------------------------- tmux / status -------------------------------
run_as_cs2() {
    runuser -u "$CS2_USER" -- env -u TMUX HOME="$CS2_HOME" USER="$CS2_USER" \
        LOGNAME="$CS2_USER" TERM="${TERM:-xterm}" "$@"
}
# lock descriptors are closed so the tmux server never inherits them
tmux_cs2()     { run_as_cs2 tmux "$@" 7>&- 8>&- 9>&-; }
session_name() { printf 'cs2-%s' "$1"; }
is_running()   { tmux_cs2 has-session -t "=$(session_name "$1")" >/dev/null 2>&1; }
status_of()    { if is_running "$1"; then echo ONLINE; else echo OFFLINE; fi; }

status_colored() {
    if [[ $1 == ONLINE ]]; then printf '%s%-8s%s' "$GREEN" "$1" "$RESET"
    else printf '%s%-8s%s' "$RED" "$1" "$RESET"; fi
}

# ------------------------------- Port checks ---------------------------------
port_in_use() {
    ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${1}\$"
}

suggest_port() {
    local p
    for ((p = 27016; p <= 27200; p++)); do
        if ! db_port_registered "$p" && ! port_in_use "$p"; then echo "$p"; return; fi
    done
    echo 27016
}

# ------------------------------- Path safety ---------------------------------
# safe_server_path <path> <slug>
safe_server_path() {
    local p=$1 slug=$2
    [[ $slug =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]        || return 1
    [[ $p == "$SERVERS_DIR/$slug" ]]                || return 1
    [[ $p != "$BASE" && $p != "/" && $p != "$SERVERS_DIR" && $p != "$SHARED_DIR" ]] || return 1
    [[ ! -L $p ]]                                   || return 1
    if [[ -e $p ]]; then
        [[ $(realpath -m -- "$p") == "$p" ]]        || return 1
    fi
    return 0
}

# ------------------------------- Server tree ---------------------------------
GAMEREL=""; CSGOREL=""; BINREL=""; BINPARENT=""; HAS_BIN=0
REAL_DIRS=()

rel_join() { if [[ -z $1 ]]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi; }
rel_parent() { if [[ $1 == */* ]]; then printf '%s' "${1%/*}"; else printf ''; fi; }

detect_layout() {
    if   [[ -f $BASE/game/cs2.sh ]]; then GAMEREL="game"
    elif [[ -f $BASE/cs2.sh ]];      then GAMEREL=""
    else
        err "Could not find cs2.sh in $BASE/game or $BASE."
        return 1
    fi
    CSGOREL=$(rel_join "$GAMEREL" csgo)
    BINPARENT=$(rel_join "$GAMEREL" bin)
    BINREL=$(rel_join "$GAMEREL" bin/linuxsteamrt64)
    if [[ ! -d $BASE/$CSGOREL ]]; then
        err "Base game content directory not found: $BASE/$CSGOREL"
        return 1
    fi

    REAL_DIRS=("")
    [[ -n $GAMEREL ]] && REAL_DIRS+=("$GAMEREL")
    REAL_DIRS+=("$CSGOREL")
    if [[ -f $BASE/$BINREL/cs2 ]]; then
        HAS_BIN=1
        REAL_DIRS+=("$BINPARENT" "$BINREL")
    else
        HAS_BIN=0
        warn "Launcher binary $BASE/$BINREL/cs2 not found; it will be symlinked."
    fi
    return 0
}

need_layout() { [[ -n $CSGOREL ]] || detect_layout; }

# Names that must NOT be symlinked inside real directory $1 (relative to BASE)
excludes_for() {
    local d=$1 r
    for r in "${REAL_DIRS[@]}"; do
        [[ -z $r || $r == "$d" ]] && continue
        [[ "$(rel_parent "$r")" == "$d" ]] && printf '%s\n' "${r##*/}"
    done
    [[ $d == "$GAMEREL" ]] && echo "cs2.sh"
    if [[ $d == "$CSGOREL" ]]; then printf '%s\n' cfg addons logs; fi
    if ((HAS_BIN)) && [[ $d == "$BINREL" ]]; then echo "cs2"; fi
    return 0
}

# link_missing <src> <dst> [excluded names...]
link_missing() {
    local src=$1 dst=$2; shift 2
    local e name x skip
    # drop dangling symlinks left over from removed base files
    find "$dst" -mindepth 1 -maxdepth 1 -xtype l -delete 2>/dev/null
    while IFS= read -r -d '' e; do
        name=${e##*/}
        skip=0
        for x in "$@"; do
            if [[ $x == "$name" ]]; then skip=1; break; fi
        done
        ((skip)) && continue
        if [[ -e $dst/$name || -L $dst/$name ]]; then continue; fi
        ln -s -- "$e" "$dst/$name" || { err "Failed to link $e"; return 1; }
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0)
}

# Copy launcher files (kept as real files so the engine resolves the SERVER's
# directory, not the base one). Refreshed automatically after base updates.
refresh_launchers() {
    local srv=$1 rel
    local files=("$(rel_join "$GAMEREL" cs2.sh)")
    ((HAS_BIN)) && files+=("$BINREL/cs2")
    for rel in "${files[@]}"; do
        if [[ ! -f $BASE/$rel ]]; then err "Missing base file: $BASE/$rel"; return 1; fi
        if [[ -L $srv/$rel ]] || [[ ! -f $srv/$rel ]] || ! cmp -s "$BASE/$rel" "$srv/$rel"; then
            rm -f -- "${srv:?}/$rel"
            cp -p -- "$BASE/$rel" "$srv/$rel" || { err "Failed to copy $rel"; return 1; }
        fi
        chmod +x "$srv/$rel"
    done
}

# Idempotent: builds/refreshes the symlink tree of a server directory
sync_server_tree() {
    local srv=$1 d src dst
    local -a ex
    detect_layout || return 1
    for d in "${REAL_DIRS[@]}"; do
        src="$BASE${d:+/$d}"
        dst="$srv${d:+/$d}"
        mkdir -p -- "$dst" || { err "Cannot create $dst"; return 1; }
        mapfile -t ex < <(excludes_for "$d")
        link_missing "$src" "$dst" "${ex[@]}" || return 1
    done
    refresh_launchers "$srv" || return 1
    chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$srv" || { err "chown failed on $srv"; return 1; }
    return 0
}

# Independent per-server content (only on creation)
seed_independent() {
    local srv=$1
    local csgo_base="$BASE/$CSGOREL" csgo_srv="$srv/$CSGOREL"

    if [[ -d $csgo_base/cfg ]]; then
        cp -a -- "$csgo_base/cfg" "$csgo_srv/cfg" || { err "Failed to copy cfg"; return 1; }
    else
        warn "Base cfg directory not found; creating an empty one."
        mkdir -p -- "$csgo_srv/cfg" || return 1
    fi

    if [[ -d $csgo_base/addons ]]; then
        cp -a -- "$csgo_base/addons" "$csgo_srv/addons" || { err "Failed to copy addons"; return 1; }
    else
        warn "Base addons directory not found; plugins will not be available."
        mkdir -p -- "$csgo_srv/addons" || return 1
    fi

    mkdir -p -- "$csgo_srv/logs" "$srv/logs" || return 1
}

write_server_cfg() {
    local srv=$1 name=$2 maxp=$3 port=$4 id=${5:-} gslt="" cfg
    need_layout || return 1
    cfg="$srv/$CSGOREL/cfg/server.cfg"
    [[ -L $cfg ]] && rm -f -- "$cfg"
    touch -- "$cfg" || { err "Cannot write $cfg"; return 1; }

    sed -i '/^\/\/ BEGIN CS2-MANAGER$/,/^\/\/ END CS2-MANAGER$/d' "$cfg" || return 1
    sed -i -E '/^[[:space:]]*hostname[[:space:]]/d' "$cfg" || return 1
    [[ -n $id ]] && gslt=$(launch_value "$id" gslt "")

    {
        echo '// BEGIN CS2-MANAGER'
        echo "hostname \"$name\""
        echo "sv_visiblemaxplayers $maxp"
        echo "tv_port $((port + 5))"
        echo "log on"
        echo "sv_logfile 1"
        [[ -n $gslt ]] && echo "sv_setsteamaccount \"$gslt\""
        [[ -n $id ]] && settings_cfg_lines "$id"
        echo '// END CS2-MANAGER'
    } >>"$cfg" || { err "Cannot append to $cfg"; return 1; }
    chown "$CS2_USER:$CS2_GROUP" -- "$cfg" || return 1
    [[ -n $gslt ]] && chmod 640 -- "$cfg"

    if sed '/^\/\/ BEGIN CS2-MANAGER$/,/^\/\/ END CS2-MANAGER$/d' "$cfg" | grep -Eq '^[[:space:]]*sv_setsteamaccount'; then
        warn "server.cfg contains a Steam GSLT token (sv_setsteamaccount) outside the managed block."
        warn "Each server needs its own token - edit: $cfg"
    fi
}

# =============================================================================
#  SHARED PLUGINS
# =============================================================================
DRY_RUN=0
SYNC_SKIPS=0
UNLINKED=0
CUR_PLUG=""
PLG_LOCALS=()
PLUGIN_REL=""
OPT_LOCAL_CSV="-"
OPT_EXCL_CSV="-"
OPT_INCL_CSV="-"

shared_db_ok() {
    ((SHARED_OK)) && return 0
    err "Shared plugin registry ($SHARED_DB) is not a valid JSON array."
    err "Fix or restore it (backups: $BACKUP_DIR), then try again."
    return 1
}

valid_simple_name() { [[ $1 =~ ^[A-Za-z0-9._+@-]+$ && $1 != . && $1 != .. ]]; }

# validate_plugin_rel <path> [quiet]  -> sets PLUGIN_REL
# Accepts ONLY <allowed-prefix>/<PLUGIN> (exactly one extra component).
validate_plugin_rel() {
    local p=$1 quiet=${2:-0} pre rest comp
    local -a comps
    PLUGIN_REL=""
    p=${p%/}
    if [[ -z $p ]]; then ((quiet)) || err "Path cannot be empty."; return 1; fi
    if [[ $p == /* ]]; then ((quiet)) || err "Absolute paths are not allowed."; return 1; fi
    if [[ ! $p =~ ^[A-Za-z0-9._+@-]+(/[A-Za-z0-9._+@-]+)*$ ]]; then
        ((quiet)) || err "Invalid characters in path (allowed: letters, digits, . _ + @ - and /)."
        return 1
    fi
    IFS=/ read -ra comps <<<"$p"
    for comp in "${comps[@]}"; do
        if [[ $comp == . || $comp == .. ]]; then
            ((quiet)) || err "'.' and '..' are not allowed in the path."
            return 1
        fi
    done
    for pre in "${PLUGIN_PREFIXES[@]}"; do
        if [[ $p == "$pre"/* ]]; then
            rest=${p#"$pre"/}
            if [[ -n $rest && $rest != */* ]]; then PLUGIN_REL=$p; return 0; fi
        fi
    done
    if ! ((quiet)); then
        err "Only single plugins can be shared: <prefix>/<PLUGIN> with prefix one of:"
        for pre in "${PLUGIN_PREFIXES[@]}"; do echo "    $pre"; done
    fi
    return 1
}

plugin_src_path() { printf '%s/%s' "$SHARED_ADDONS" "$1"; }

# shared_path_ok <path>: strictly inside shared/addons, no symlink components
shared_path_ok() {
    local p=$1 rp
    [[ $p == "$SHARED_ADDONS"/* ]] || return 1
    rp=$(realpath -m -- "$p") || return 1
    [[ $rp == "$p" ]] || return 1
    return 0
}

# ensure_chain <base> <target>: create missing directories below <base> down
# to <target>. Refuses to pass through symlinks. New dirs are owned by cs2.
ensure_chain() {
    local base=$1 target=$2 cur part
    local -a parts
    [[ $target == "$base" ]] && return 0
    [[ $target == "$base"/* ]] || return 1
    [[ -d $base && ! -L $base ]] || return 1
    cur=$base
    IFS=/ read -ra parts <<<"${target#"$base"/}"
    for part in "${parts[@]}"; do
        cur="$cur/$part"
        if [[ -L $cur ]]; then return 1; fi
        if [[ ! -d $cur ]]; then
            if [[ -e $cur ]]; then return 1; fi
            mkdir -- "$cur" || return 1
            chown "$CS2_USER:$CS2_GROUP" -- "$cur" || return 1
        fi
    done
    return 0
}

# paths_identical <shared-source> <local-copy>
paths_identical() {
    local a=$1 b=$2
    [[ -L $b ]] && return 1
    if [[ -f $a && -f $b ]]; then cmp -s -- "$a" "$b"; return; fi
    if [[ -d $a && -d $b ]]; then
        # a local copy that contains symlinks is never treated as identical
        [[ -z $(find "$b" -type l -print -quit 2>/dev/null) ]] || return 1
        diff -rq -- "$a" "$b" >/dev/null 2>&1
        return
    fi
    return 1
}

# Replace an identical real dir/file by a symlink (rename first, delete after).
replace_with_link() {
    local dst=$1 src=$2 old
    old="$dst.mgr-old.$$"
    [[ $old == "$SERVERS_DIR"/*/* ]] || return 1
    mv -T -- "$dst" "$old" || return 1
    if ! ln -s -- "$src" "$dst"; then
        mv -T -- "$old" "$dst"
        return 1
    fi
    chown -h "$CS2_USER:$CS2_GROUP" -- "$dst"
    rm -rf --one-file-system -- "$old"
    return 0
}

# drop_link <link> <target> <keep-copy 0|1>
# Removes a symlink after verifying it really is a symlink into shared/addons.
# keep=1 turns it into a real copy first, so the server keeps the plugin.
drop_link() {
    local link=$1 target=$2 keep=$3 tmp
    [[ -L $link ]] || return 1
    [[ $target == "$SHARED_ADDONS"/* ]] || return 1
    ((DRY_RUN)) && return 0
    if ((keep)) && [[ -e $link ]]; then
        tmp="$link.mgr-copy.$$"
        [[ $tmp == "$SERVERS_DIR"/*/* ]] || return 1
        if ! cp -a -- "$target" "$tmp"; then
            rm -rf --one-file-system -- "$tmp"
            return 1
        fi
        rm -f -- "$link" || { rm -rf --one-file-system -- "$tmp"; return 1; }
        mv -T -- "$tmp" "$link" || return 1
        chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$link"
    else
        rm -f -- "$link" || return 1
    fi
    return 0
}

# unlink_managed <dst> <shared-src> <keep>
# Removes ONLY symlinks that belong to <shared-src>. Real local files/dirs and
# foreign symlinks are never touched. Sets UNLINKED. Returns 1 on a failed check.
unlink_managed() {
    local dst=$1 src=$2 keep=${3:-0} t child
    UNLINKED=0
    if [[ -L $dst ]]; then
        t=$(readlink -- "$dst")
        if [[ $t == "$src" || $t == "$src"/* ]]; then
            if drop_link "$dst" "$t" "$keep"; then UNLINKED=1; else return 1; fi
        fi
        return 0
    fi
    [[ -d $dst ]] || return 0
    while IFS= read -r -d '' child; do
        t=$(readlink -- "$child")
        if [[ $t == "$src"/* ]]; then
            if drop_link "$child" "$t" "$keep"; then UNLINKED=$((UNLINKED + 1)); else return 1; fi
        fi
    done < <(find "$dst" -mindepth 1 -type l -print0)
    # tidy up only directories we just emptied by removing our own links;
    # directories that still hold real (per-server) files are never removed
    if ((!DRY_RUN && UNLINKED > 0)); then find "$dst" -depth -type d -empty -delete 2>/dev/null; fi
    return 0
}

# preport <ok|info|dry|warn|skip> [detail]  ->  "[LEVEL] SERVER -> PLUGIN (detail)"
preport() {
    local level=$1; shift
    local m="$S_NAME -> $CUR_PLUG${*:+ ($*)}"
    case $level in
        ok)   ok "$m" ;;
        info) info "$m" ;;
        dry)  msg_dry "$m" ;;
        warn) warn "$m" ;;
        skip) msg_skip "$m"; SYNC_SKIPS=$((SYNC_SKIPS + 1)) ;;
    esac
}

# --- whole-folder mode: one symlink for the plugin directory/file ---
sync_whole() {
    local src=$1 dst=$2 base=$3 t
    if [[ -L $dst ]]; then
        t=$(readlink -- "$dst")
        if [[ $t == "$src" ]]; then preport ok "already linked"; return 0; fi
        if [[ ! -e $dst || $t == "$SHARED_ADDONS"/* ]]; then
            if ((DRY_RUN)); then preport dry "would repair symlink"; return 0; fi
            if ln -sfT -- "$src" "$dst" && chown -h "$CS2_USER:$CS2_GROUP" -- "$dst"; then
                preport ok "repaired symlink"
            else
                preport skip "could not repair symlink"
            fi
            return 0
        fi
        warn "Symlink on $S_NAME points elsewhere: $t"
        preport skip "foreign symlink left untouched"
        return 0
    fi
    if [[ -e $dst ]]; then
        if paths_identical "$src" "$dst"; then
            if ((DRY_RUN)); then preport dry "would replace identical local copy with a symlink"; return 0; fi
            if replace_with_link "$dst" "$src"; then
                preport ok "identical local copy replaced by symlink"
            else
                preport skip "could not convert local copy"
            fi
            return 0
        fi
        warn "Existing local plugin differs on $S_NAME"
        preport skip "Not replacing local plugin"
        return 0
    fi
    if ((DRY_RUN)); then preport dry "would create symlink"; return 0; fi
    if ensure_chain "$base" "$(dirname -- "$dst")" \
        && ln -s -- "$src" "$dst" \
        && chown -h "$CS2_USER:$CS2_GROUP" -- "$dst"; then
        preport ok "linked"
    else
        preport skip "could not create symlink (parent path problem?)"
    fi
}

# --- split mode: REAL plugin directory whose children are symlinked into the
#     shared copy, except the per-server items in PLG_LOCALS (paths relative to
#     the plugin folder, e.g. "data/astra_skins.sqlite"). A directory that
#     contains such an item stays real and its other children are linked below it.
SPLIT_NEW=0; SPLIT_OK=0; SPLIT_FIX=0; SPLIT_BAD=0
local_exact()  { local l; for l in "${PLG_LOCALS[@]}"; do [[ $l == "$1" ]] && return 0; done; return 1; }
local_below()  { local l; for l in "${PLG_LOCALS[@]}"; do [[ $l == "$1"/* ]] && return 0; done; return 1; }

split_dir() {   # <src dir> <dst dir> <rel prefix> <dst exists 0|1> <base>
    local src=$1 dst=$2 pre=$3 have=$4 base=$5 child name rp cdst t
    while IFS= read -r -d '' child; do
        name=${child##*/}
        rp=${pre:+$pre/}$name
        local_exact "$rp" && continue
        cdst="$dst/$name"
        if [[ -d $child ]] && local_below "$rp"; then
            if ((!have)); then split_dir "$child" "$cdst" "$rp" 0 "$base"; continue; fi
            if [[ -L $cdst ]]; then
                t=$(readlink -- "$cdst")
                if [[ ! -e $cdst || $t == "$SHARED_ADDONS"/* ]]; then
                    if ((DRY_RUN)); then SPLIT_FIX=$((SPLIT_FIX + 1)); split_dir "$child" "$cdst" "$rp" 0 "$base"; continue; fi
                    rm -f -- "$cdst" || { SPLIT_BAD=$((SPLIT_BAD + 1)); continue; }
                else
                    warn "Foreign symlink on $S_NAME: $rp"; SPLIT_BAD=$((SPLIT_BAD + 1)); continue
                fi
            fi
            if [[ -e $cdst && ! -d $cdst ]]; then warn "A file blocks $rp on $S_NAME"; SPLIT_BAD=$((SPLIT_BAD + 1)); continue; fi
            if [[ ! -d $cdst ]]; then
                if ((DRY_RUN)); then split_dir "$child" "$cdst" "$rp" 0 "$base"; continue; fi
                ensure_chain "$base" "$cdst" || { SPLIT_BAD=$((SPLIT_BAD + 1)); continue; }
            fi
            split_dir "$child" "$cdst" "$rp" 1 "$base"
            continue
        fi
        if ((!have)); then SPLIT_NEW=$((SPLIT_NEW + 1)); continue; fi
        if [[ -L $cdst ]]; then
            t=$(readlink -- "$cdst")
            if [[ $t == "$child" ]]; then
                SPLIT_OK=$((SPLIT_OK + 1))
            elif [[ ! -e $cdst || $t == "$SHARED_ADDONS"/* ]]; then
                if ((DRY_RUN)); then SPLIT_FIX=$((SPLIT_FIX + 1))
                elif ln -sfT -- "$child" "$cdst" && chown -h "$CS2_USER:$CS2_GROUP" -- "$cdst"; then SPLIT_FIX=$((SPLIT_FIX + 1))
                else SPLIT_BAD=$((SPLIT_BAD + 1)); fi
            else
                warn "Foreign symlink on $S_NAME: $rp"; SPLIT_BAD=$((SPLIT_BAD + 1))
            fi
        elif [[ -e $cdst ]]; then
            if paths_identical "$child" "$cdst"; then
                if ((DRY_RUN)); then SPLIT_FIX=$((SPLIT_FIX + 1))
                elif replace_with_link "$cdst" "$child"; then SPLIT_FIX=$((SPLIT_FIX + 1))
                else SPLIT_BAD=$((SPLIT_BAD + 1)); fi
            else
                warn "Existing local item differs on $S_NAME: $rp"; SPLIT_BAD=$((SPLIT_BAD + 1))
            fi
        else
            if ((DRY_RUN)); then SPLIT_NEW=$((SPLIT_NEW + 1))
            elif ln -s -- "$child" "$cdst" && chown -h "$CS2_USER:$CS2_GROUP" -- "$cdst"; then SPLIT_NEW=$((SPLIT_NEW + 1))
            else SPLIT_BAD=$((SPLIT_BAD + 1)); fi
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0)
}

sync_split() {
    local src=$1 dst=$2 base=$3 t child lc have_dir=1
    SPLIT_NEW=0; SPLIT_OK=0; SPLIT_FIX=0; SPLIT_BAD=0

    if [[ -L $dst ]]; then
        t=$(readlink -- "$dst")
        if [[ ! -e $dst || $t == "$SHARED_ADDONS"/* ]]; then
            have_dir=0
            warn "Converting whole-folder link to per-item links on $S_NAME (data written through the old link stays in shared storage)."
            if ! ((DRY_RUN)); then
                rm -f -- "$dst" || { preport skip "cannot replace symlink with a directory"; return 0; }
            fi
        else
            warn "Symlink on $S_NAME points elsewhere: $t"
            preport skip "foreign symlink left untouched"
            return 0
        fi
    elif [[ -e $dst && ! -d $dst ]]; then
        warn "A file blocks the plugin directory on $S_NAME"
        preport skip "not a directory"
        return 0
    elif [[ ! -d $dst ]]; then
        have_dir=0
    fi
    if ((!have_dir && !DRY_RUN)); then
        ensure_chain "$base" "$dst" || { preport skip "cannot create plugin directory"; return 0; }
        have_dir=1
    fi

    split_dir "$src" "$dst" "" "$have_dir" "$base"

    # remove dangling links that used to point into this shared plugin
    if ((have_dir)) && [[ -d $dst ]]; then
        while IFS= read -r -d '' child; do
            t=$(readlink -- "$child")
            if [[ $t == "$src"/* && ! -e $child ]]; then
                if ((DRY_RUN)); then SPLIT_FIX=$((SPLIT_FIX + 1))
                elif rm -f -- "$child"; then SPLIT_FIX=$((SPLIT_FIX + 1)); fi
            fi
        done < <(find "$dst" -mindepth 1 -type l -print0)
    fi

    lc=$(IFS=,; printf '%s' "${PLG_LOCALS[*]}")
    if ((SPLIT_BAD > 0)); then preport skip "$SPLIT_BAD item(s) not replaced (differ locally / foreign)"; fi
    if ((DRY_RUN)); then
        preport dry "would link $SPLIT_NEW new, fix $SPLIT_FIX; per-server kept: $lc"
    else
        preport ok "linked $SPLIT_NEW, fixed $SPLIT_FIX, unchanged $SPLIT_OK; per-server kept: $lc"
    fi
}

_sync_plugin_inner() {
    local pname=$1 rel=$2 lcsv=$3 xcsv=$4 icsv=${5:--}
    local src dst base l excluded=0
    CUR_PLUG=$pname
    PLG_LOCALS=()
    if [[ $lcsv != "-" ]]; then IFS=, read -ra PLG_LOCALS <<<"$lcsv"; fi
    for l in "${PLG_LOCALS[@]}"; do
        if ! valid_local_path "$l"; then preport skip "invalid per-server path in registry: $l"; return 0; fi
    done
    [[ ,$xcsv, == *",$S_ID,"* ]] && excluded=1
    if [[ $icsv != "-" && ,$icsv, != *",$S_ID,"* ]]; then excluded=1; fi

    src=$(plugin_src_path "$rel")
    base="$S_PATH/$CSGOREL"
    dst="$base/addons/$rel"

    if ! safe_server_path "$S_PATH" "$S_SLUG"; then
        preport skip "unsafe or inconsistent server path in database"; return 0
    fi
    if [[ ! -d $base || -L $base ]]; then
        preport skip "server directory $CSGOREL is missing"; return 0
    fi
    if ! shared_path_ok "$src"; then
        preport skip "unsafe shared path"; return 0
    fi

    if ((excluded)); then
        if ! unlink_managed "$dst" "$src" 0; then
            preport skip "not assigned, but removing the managed link failed"; return 0
        fi
        if ((UNLINKED)); then
            if ((DRY_RUN)); then preport dry "not assigned: would remove managed link"
            else preport ok "not assigned to this server: managed link removed"; fi
        else
            preport info "not assigned to this server"
        fi
        return 0
    fi

    if [[ ! -e $src && ! -L $src ]]; then
        preport skip "shared source is missing ($src)"; return 0
    fi

    if ((${#PLG_LOCALS[@]})) && [[ -d $src ]]; then
        sync_split "$src" "$dst" "$base"
    else
        sync_whole "$src" "$dst" "$base"
    fi
}

# sync_plugin_on_server <name> <rel> <local-csv|-> <exclude-csv|->
# Uses the loaded S_* server. Returns 1 if anything was skipped.
sync_plugin_on_server() {
    local before=$SYNC_SKIPS
    _sync_plugin_inner "$@"
    [[ $SYNC_SKIPS -eq $before ]]
}

# name<TAB>path<TAB>local-csv|-<TAB>exclude-csv|-
plugins_rows() {
    jq -r '.[] | select(type=="object") | [
        ((.name // "-") | tostring),
        ((.path // "-") | tostring),
        ((.local // []) | if type=="array" and length>0 then map(tostring)|join(",") else "-" end),
        ((.exclude // []) | if type=="array" and length>0 then map(tostring)|join(",") else "-" end),
        ((.include // []) | if type=="array" and length>0 then map(tostring)|join(",") else "-" end)
    ] | @tsv' "$SHARED_DB"
}

# Sync ALL shared plugins to the currently loaded server (S_*)
sync_shared_current() {
    local P_NAME P_PATH P_LOCAL P_EXCL P_INCL rc=0
    ((SHARED_OK)) || return 1
    need_layout || return 1
    lock_ops 30 || return 1
    while IFS=$'\t' read -r P_NAME P_PATH P_LOCAL P_EXCL P_INCL; do
        if ! validate_plugin_rel "$P_PATH" 1; then
            warn "Ignoring invalid shared plugin path in registry: $P_PATH"
            rc=1; continue
        fi
        sync_plugin_on_server "$P_NAME" "$PLUGIN_REL" "$P_LOCAL" "$P_EXCL" "$P_INCL" || rc=1
    done < <(plugins_rows)
    unlock_ops
    return $rc
}

# discover_shared_plugins: everything the admin drops into the shared folders
#   shared/addons/counterstrikesharp/plugins/<X>   and   shared/addons/metamod/plugins/<X>
# is registered automatically; the normal sync then links it into every server.
DISCOVERED=0
discover_shared_plugins() {
    local pre dir item name rel
    DISCOVERED=0
    ((SHARED_OK)) || return 0
    for pre in "${PLUGIN_PREFIXES[@]}"; do
        dir="$SHARED_ADDONS/$pre"
        [[ -d $dir && ! -L $dir ]] || continue
        while IFS= read -r -d '' item; do
            name=${item##*/}
            [[ $name == .* ]] && continue
            if [[ -L $item ]]; then warn "Ignoring symlink in the shared folder: $item"; continue; fi
            if ! valid_simple_name "$name"; then
                warn "Ignoring '$name' in the shared folder (unsupported characters)."; continue
            fi
            rel="$pre/$name"
            if jq -e --arg p "$rel" 'any(.[]; type=="object" and .path == $p)' "$SHARED_DB" >/dev/null 2>&1; then
                continue
            fi
            if [[ -n $(find "$item" -newermt '10 seconds ago' -print -quit 2>/dev/null) ]]; then
                info "'$name' was modified a moment ago (still being copied?); it is picked up on the next sync."
                continue
            fi
            if [[ -n $(find "$item" -type l -print -quit 2>/dev/null) ]]; then
                warn "'$name' contains symlinks; not registered."; continue
            fi
            if ((DRY_RUN)); then
                msg_dry "would register new shared plugin '$name' ($rel)"
                DISCOVERED=$((DISCOVERED + 1)); continue
            fi
            chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$item" 2>/dev/null
            if shared_update --arg n "$name" --arg p "$rel" '. += [{name:$n, path:$p}]'; then
                ok "New shared plugin registered: $name ($rel)"
                DISCOVERED=$((DISCOVERED + 1))
                if [[ -d $item && -n $(find "$item" -maxdepth 2 \( -iname 'data' -o -iname '*.sqlite' -o -iname '*.db' \) -print -quit 2>/dev/null) ]]; then
                    warn "'$name' seems to keep data inside its folder; that data would be SHARED by all servers."
                    warn "Use Shared Plugins -> Add Shared Plugin with '$rel' to mark per-server items (e.g. data)."
                fi
            fi
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
    done
    return 0
}

sync_shared_all() {
    local id rc=0 total
    local -a ids
    shared_db_ok || return 1
    need_layout || return 1
    lock_ops 30 || return 1
    discover_shared_plugins
    total=$(jq 'length' "$SHARED_DB")
    if ((total == 0)); then
        info "No shared plugins registered. Drop plugin folders into $SHARED_ADDONS/<prefix>/ to share them."
        unlock_ops; return 0
    fi
    mapfile -t ids < <(jq -r '.[].id' "$DB")
    for id in "${ids[@]}"; do
        if ! load_server "$id"; then warn "Server ID $id could not be loaded."; rc=1; continue; fi
        if ((DRY_RUN && DISCOVERED > 0)); then
            info "(dry-run) newly found plugins are not linked yet; sync for real to link them."
            DISCOVERED=0
        fi
        sync_shared_current || rc=1
    done
    unlock_ops
    return $rc
}

# --- option prompts (per-server data / excluded servers) ---
json_from_csv() {   # <csv|-> <strings|numbers>
    jq -nc --arg s "$1" --arg k "$2" \
        'if $s=="-" then [] elif $k=="numbers" then ($s|split(",")|map(tonumber)) else ($s|split(",")) end'
}

# import_plugin <server-plugin-path> <shared-src> <local-csv|->
# Copies (never moves) a plugin from a server into shared storage.
import_plugin() {
    local d=$1 src=$2 lcsv=$3 l
    local -a locs=()
    if [[ $lcsv != "-" ]]; then IFS=, read -ra locs <<<"$lcsv"; fi
    if [[ -n $(find "$d" -type l -print -quit 2>/dev/null) ]]; then
        err "The plugin contains symlinks; refusing to import it into shared storage."
        return 1
    fi
    ensure_chain "$SHARED_ADDONS" "$(dirname -- "$src")" || { err "Cannot create shared directories."; return 1; }
    cp -a -- "$d" "$src" || { err "Copy failed: $d"; rm -rf --one-file-system -- "$src"; return 1; }
    # per-server items stay on the server they came from and are not shared
    if [[ -d $src ]]; then
        for l in "${locs[@]}"; do
            if valid_local_path "$l" && shared_path_ok "$src/$l"; then rm -rf --one-file-system -- "${src:?}/$l"; fi
        done
    fi
    chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$src" || warn "chown failed on $src"
    return 0
}

# ------------------------------- Shared plugin UI ----------------------------
shared_add_ui() {
    header "ADD SHARED PLUGIN"
    shared_db_ok || return
    need_layout || return

    local pre rel pname src id cand_path n_cand=0 pick from_path created=0
    local -a cand_ids=() cand_paths=() cand_names=()
    local P_NAME P_PATH P_LOCAL P_EXCL P_INCL P_LOCAL_CUR="-" found=0

    echo "Enter the plugin path relative to a server's addons directory. Allowed:"
    for pre in "${PLUGIN_PREFIXES[@]}"; do echo "    $pre/<PLUGIN>"; done
    echo "Example: counterstrikesharp/plugins/MyPlugin"
    echo "(enter q to cancel)"; echo
    ask "Plugin path" || { info "Cancelled."; return; }
    validate_plugin_rel "$ANSWER" || return
    rel=$PLUGIN_REL; pname=${rel##*/}
    src=$(plugin_src_path "$rel")
    shared_path_ok "$src" || { err "Refusing unsafe shared path: $src"; return; }

    # already registered? -> only offer to change its options
    while IFS=$'\t' read -r P_NAME P_PATH P_LOCAL P_EXCL P_INCL; do
        if [[ $P_PATH == "$rel" ]]; then found=1; P_LOCAL_CUR=$P_LOCAL; fi
    done < <(plugins_rows)
    if ((found)); then
        info "'$pname' is already a plugin (per-server: $P_LOCAL_CUR)."
        confirm_yn "Change its options / assignment? [y/N]: " n || { info "Nothing changed."; return; }
        plugin_edit_registry "$rel"
        return
    fi

    lock_ops 30 || return
    if [[ -e $src || -L $src ]]; then
        if [[ -L $src ]]; then err "$src is a symlink; refusing."; unlock_ops; return; fi
        info "A shared copy already exists at $src; it will be registered as is."
        prompt_plugin_options "$(plugin_profile_local "$pname")" "-" "-" || { info "Cancelled."; unlock_ops; return; }
    else
        # find servers holding a REAL copy that can be imported
        while IFS= read -r id; do
            load_server "$id" || continue
            safe_server_path "$S_PATH" "$S_SLUG" || continue
            cand_path="$S_PATH/$CSGOREL/addons/$rel"
            if [[ -e $cand_path && ! -L $cand_path ]]; then
                cand_ids+=("$id"); cand_paths+=("$cand_path"); cand_names+=("$S_NAME")
            fi
        done < <(jq -r '.[].id' "$DB")
        n_cand=${#cand_ids[@]}
        if ((n_cand == 0)); then
            err "No shared copy exists and no server has a real copy of '$rel'."
            echo "Install the plugin on one server first (or place it in $src), then retry."
            unlock_ops; return
        fi
        echo
        echo "Import the plugin files from which server? (they are COPIED, nothing is moved)"
        for ((pick = 0; pick < n_cand; pick++)); do
            echo "  ${cand_ids[pick]}) ${cand_names[pick]}"
        done
        ask "Server ID" "${cand_ids[0]}" || { info "Cancelled."; unlock_ops; return; }
        from_path=""
        for ((pick = 0; pick < n_cand; pick++)); do
            [[ $ANSWER == "${cand_ids[pick]}" ]] && from_path=${cand_paths[pick]}
        done
        if [[ -z $from_path ]]; then err "Invalid server selection."; unlock_ops; return; fi
        prompt_plugin_options "$(plugin_profile_local "$pname")" "-" "-" || { info "Cancelled."; unlock_ops; return; }
        info "Copying plugin into shared storage..."
        import_plugin "$from_path" "$src" "$OPT_LOCAL_CSV" || { unlock_ops; return; }
        created=1
        ok "Copied to $src"
    fi

    if ! shared_update --arg n "$pname" --arg p "$rel" \
        --argjson l "$(json_from_csv "$OPT_LOCAL_CSV" strings)" \
        --argjson x "$(json_from_csv "$OPT_EXCL_CSV" numbers)" \
        --argjson i "$(json_from_csv "$OPT_INCL_CSV" numbers)" \
        '. += [{name:$n, path:$p}
               + (if ($l|length) > 0 then {local:$l} else {} end)
               + (if ($x|length) > 0 then {exclude:$x} else {} end)
               + (if ($i|length) > 0 then {include:$i} else {} end)]'; then
        err "Could not register the plugin."
        if ((created)) && shared_path_ok "$src"; then rm -rf --one-file-system -- "$src"; fi
        unlock_ops; return
    fi
    ok "Shared plugin '$pname' registered."
    echo
    info "Syncing all servers..."
    DRY_RUN=0
    if sync_shared_all; then ok "All servers are in sync."; else warn "Finished with skipped items (see above). Nothing was overwritten."; fi
    unlock_ops
}

shared_remove_ui() {
    header "REMOVE SHARED PLUGIN"
    shared_db_ok || return
    need_layout || return
    local total; total=$(jq 'length' "$SHARED_DB")
    if ((total == 0)); then warn "No shared plugins registered."; return; fi

    local i=0 idx rel src pname keep=0 fail=0 id dst
    local -a paths=()
    local P_NAME P_PATH P_LOCAL P_EXCL P_INCL
    while IFS=$'\t' read -r P_NAME P_PATH P_LOCAL P_EXCL P_INCL; do
        i=$((i + 1)); paths[i]=$P_PATH
        printf '%s) %s  (%s)\n' "$i" "$P_NAME" "$P_PATH"
    done < <(plugins_rows)
    echo
    ask "Plugin number to remove (q = cancel)" || { info "Cancelled."; return; }
    if ! [[ $ANSWER =~ ^[0-9]+$ ]] || ((10#$ANSWER < 1 || 10#$ANSWER > i)); then err "Invalid selection."; return; fi
    idx=$((10#$ANSWER))
    validate_plugin_rel "${paths[idx]}" || { err "Registry path is invalid; refusing to continue."; return; }
    rel=$PLUGIN_REL; pname=${rel##*/}
    src=$(plugin_src_path "$rel")
    shared_path_ok "$src" || { err "Unsafe shared path: $src"; return; }

    echo; sep
    echo "  Plugin : $pname ($rel)"
    echo "  Shared : $src"
    sep
    info "Only symlinks pointing into $SHARED_ADDONS are removed from servers."
    info "Real server-local plugin directories are never touched."
    if confirm_yn "Keep a real LOCAL copy of the plugin on each server (so they keep it)? [y/N]: " n; then keep=1; fi
    local in
    read -r -p "Type REMOVE to confirm: " in || exit 0
    if [[ $in != REMOVE ]]; then info "Cancelled."; return; fi

    lock_ops 30 || return
    DRY_RUN=0
    while IFS= read -r id; do
        load_server "$id" || continue
        if ! safe_server_path "$S_PATH" "$S_SLUG"; then
            warn "Unsafe path for $S_NAME; skipped."; fail=1; continue
        fi
        dst="$S_PATH/$CSGOREL/addons/$rel"
        if unlink_managed "$dst" "$src" "$keep"; then
            ((UNLINKED > 0)) && ok "$S_NAME: removed $UNLINKED link(s)$( ((keep)) && printf ', local copy kept')"
        else
            warn "Safety check failed on $S_NAME ($dst)."; fail=1
        fi
    done < <(jq -r '.[].id' "$DB")

    if ((fail)); then
        warn "Aborted: registry entry and shared source were NOT removed."
        unlock_ops; return
    fi
    if ! shared_update --arg p "$rel" 'map(select(.path != $p))'; then
        err "Could not update the registry; shared source kept."
        unlock_ops; return
    fi
    if [[ -e $src || -L $src ]]; then
        if shared_path_ok "$src"; then
            rm -rf --one-file-system -- "$src" && ok "Shared source removed." || err "Could not remove $src"
        else
            warn "Shared source path failed the safety check; not deleted: $src"
        fi
    fi
    ok "Shared plugin '$pname' removed."
    unlock_ops
}

# state of a plugin on the loaded server, for the list view
plugin_state() {   # <rel> <src> <has-local 0|1> <excluded 0|1>
    local rel=$1 src=$2 haslocal=$3 excl=$4 dst t
    dst="$S_PATH/$CSGOREL/addons/$rel"
    if ((excl)); then echo excluded; return; fi
    if [[ -L $dst ]]; then
        t=$(readlink -- "$dst")
        if [[ $t == "$src" ]]; then echo linked
        elif [[ ! -e $dst ]]; then echo broken-link
        else echo foreign-link; fi
    elif [[ -d $dst ]]; then
        if ((haslocal)) && [[ -n $(find "$dst" -type l -lname "$src/*" -print -quit 2>/dev/null) ]]; then
            echo linked+per-server
        else
            echo local-copy
        fi
    elif [[ -e $dst ]]; then echo local-file
    else echo missing; fi
}

shared_list_ui() {
    header "SHARED PLUGINS"
    shared_db_ok || return
    need_layout || return
    local total; total=$(jq 'length' "$SHARED_DB")
    if ((total == 0)); then warn "No shared plugins registered."; return; fi
    local -a ids
    mapfile -t ids < <(jq -r '.[].id' "$DB")
    local P_NAME P_PATH P_LOCAL P_EXCL P_INCL i=0 id line src excl haslocal
    while IFS=$'\t' read -r P_NAME P_PATH P_LOCAL P_EXCL P_INCL; do
        i=$((i + 1))
        printf '%s%s) %s%s\n' "$BOLD" "$i" "$P_NAME" "$RESET"
        if ! validate_plugin_rel "$P_PATH" 1; then
            printf '   %sInvalid path in registry: %s%s\n' "$RED" "$P_PATH" "$RESET"; continue
        fi
        src=$(plugin_src_path "$PLUGIN_REL")
        printf '   Path         : %s\n' "$PLUGIN_REL"
        if [[ -e $src ]]; then printf '   Shared source: present\n'
        else printf '   Shared source: %sMISSING%s\n' "$RED" "$RESET"; fi
        printf '   Per-server   : %s\n' "$([[ $P_LOCAL == - ]] && echo none || echo "$P_LOCAL")"
        printf '   Only on IDs  : %s\n' "$([[ $P_INCL == - ]] && echo 'all servers' || echo "$P_INCL")"
        printf '   Excluded IDs : %s\n' "$([[ $P_EXCL == - ]] && echo none || echo "$P_EXCL")"
        printf '   Source       : %s\n' "$(jq -r --arg p "$P_PATH" '[.[] | select(type=="object" and .path == $p) | ((.source // "manual") + (if .version then " @ " + .version else "" end))][0] // "manual"' "$SHARED_DB")"
        line=""
        haslocal=0; [[ $P_LOCAL != - ]] && haslocal=1
        for id in "${ids[@]}"; do
            load_server "$id" || continue
            excl=0; [[ ,$P_EXCL, == *",$S_ID,"* ]] && excl=1
            if [[ $P_INCL != - && ,$P_INCL, != *",$S_ID,"* ]]; then excl=1; fi
            line+="$S_NAME: $(plugin_state "$PLUGIN_REL" "$src" "$haslocal" "$excl");  "
        done
        printf '   Servers      : %s\n\n' "$line"
    done < <(plugins_rows)
}

shared_sync_ui() {   # $1 = 1 for dry-run
    local dry=${1:-0}
    if ((dry)); then header "SYNC ALL SERVERS (DRY-RUN)"; else header "SYNC ALL SERVERS"; fi
    shared_db_ok || return
    DRY_RUN=$dry
    if sync_shared_all; then
        if ((dry)); then info "Dry-run finished. Nothing was changed."; else ok "All servers are in sync."; fi
    else
        warn "Finished with skipped items (see above). Nothing was overwritten."
    fi
    DRY_RUN=0
}

# ------------------------------- Server list UI ------------------------------
print_choices() {
    local id name port
    while IFS=$'\t' read -r id name port; do
        printf '%s) %s | Port: %s | ' "$id" "$name" "$port"
        status_colored "$(status_of "$id")"; echo
    done < <(jq -r '.[] | [.id,.name,.port] | @tsv' "$DB")
}

# pick_server "Prompt"  -> sets PICK_ID
PICK_ID=""
pick_server() {
    local in
    if [[ $(db_count) -eq 0 ]]; then warn "No servers registered."; return 1; fi
    print_choices; echo
    read -r -p "$1" in || exit 0
    in=$(trim "$in")
    [[ -z $in || $in == q || $in == Q ]] && { info "Cancelled."; return 1; }
    if ! [[ $in =~ ^[0-9]+$ ]]; then err "Invalid ID."; return 1; fi
    in=$((10#$in))
    if ! load_server "$in"; then err "Server ID $in not found."; return 1; fi
    PICK_ID=$in
    return 0
}

# ------------------------------- Start / Stop --------------------------------
start_server() {
    local id=$1 sess gdir cmd logf maparg
    load_server "$id" || { err "Server ID $id not found."; return 1; }
    sess=$(session_name "$id")

    if is_running "$id"; then
        warn "'$S_NAME' is already running (tmux session: $sess)."
        return 0
    fi
    if ! safe_server_path "$S_PATH" "$S_SLUG"; then
        err "Unsafe or inconsistent server path in database: $S_PATH"
        return 1
    fi
    [[ -d $S_PATH ]] || { err "Server directory missing: $S_PATH"; return 1; }
    if port_in_use "$S_PORT"; then
        err "Port $S_PORT is already in use by another process."
        return 1
    fi

    info "Syncing server files with base installation..."
    sync_server_tree "$S_PATH" || return 1
    write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$id" || return 1

    # shared plugins: never blocks the start and never deletes anything
    if ((SHARED_OK)); then
        DRY_RUN=0
        discover_shared_plugins
        sync_shared_current || warn "Some shared plugins could not be synchronised safely (see above). Existing files were left untouched."
    else
        warn "Shared plugin registry is invalid; skipping shared plugin sync."
    fi

    gdir="$S_PATH${GAMEREL:+/$GAMEREL}"
    [[ -x $gdir/cs2.sh ]] || { err "Launcher not executable: $gdir/cs2.sh"; return 1; }

    # Workshop maps are started with +host_workshop_map <id>, normal maps with +map <name>
    if [[ $S_MAP == workshop:* ]]; then printf -v maparg '+host_workshop_map %q' "${S_MAP#workshop:}"
    else printf -v maparg '+map %q' "$S_MAP"; fi
    printf -v cmd 'cd %q && exec ./cs2.sh -dedicated -console -usercon -port %q +game_type %q +game_mode %q -maxplayers %q %s' \
        "$gdir" "$S_PORT" "$(launch_value "$id" game_type 0)" "$(launch_value "$id" game_mode 1)" "$S_MAX" "$maparg"

    clear_manual_stop "$id"
    info "Starting '$S_NAME' in tmux session $sess ..."
    if ! tmux_cs2 new-session -d -s "$sess" -c "$gdir" "$cmd"; then
        err "Failed to create tmux session $sess."
        return 1
    fi

    logf="$S_PATH/logs/console.log"
    printf -v cmd 'cat >> %q' "$logf"
    tmux_cs2 pipe-pane -o -t "=$sess:" "$cmd" 2>/dev/null || warn "Could not attach console logging."

    sleep 3
    if ! is_running "$id"; then
        err "Server exited right after start. Run its launcher manually to see the error:"
        echo "  runuser -u $CS2_USER -- bash -c 'cd $gdir && ./cs2.sh -dedicated -console -port $S_PORT $maparg'"
        return 1
    fi
    ok "'$S_NAME' started (port $S_PORT, session $sess)."
    echo "   Attach : runuser -u $CS2_USER -- tmux attach -t $sess   (detach: Ctrl+B then D)"
}

# Gracefully stop ONLY this server's tmux session
stop_session() {
    local id=$1 sess i
    sess=$(session_name "$id")
    mark_manual_stop "$id"      # the watchdog must not restart an intentional stop
    is_running "$id" || return 0

    tmux_cs2 send-keys -t "=$sess:" "quit" Enter 2>/dev/null
    for ((i = 0; i < STOP_TIMEOUT; i++)); do
        is_running "$id" || return 0
        sleep 1
    done
    warn "Server did not quit gracefully; closing tmux session $sess."
    tmux_cs2 kill-session -t "=$sess" 2>/dev/null
    sleep 1
    if is_running "$id"; then err "Could not stop session $sess."; return 1; fi
    return 0
}

stop_server_ui() {
    header "STOP SERVER"
    pick_server "Server ID to stop (q = cancel): " || return
    if ! is_running "$PICK_ID"; then warn "'$S_NAME' is not running."; return; fi
    confirm_yn "Stop '$S_NAME' (port $S_PORT)? [y/N]: " n || { info "Cancelled."; return; }
    info "Stopping '$S_NAME'..."
    if stop_session "$PICK_ID"; then ok "'$S_NAME' stopped."; else err "Stop failed."; fi
}

start_server_ui() {
    header "START SERVER"
    pick_server "Server ID to start (q = cancel): " || return
    start_server "$PICK_ID"
}

restart_server_ui() {
    header "RESTART SERVER"
    pick_server "Server ID to restart (q = cancel): " || return
    local id=$PICK_ID name=$S_NAME
    if is_running "$id"; then
        confirm_yn "'$name' is running; players will be disconnected. Restart? [y/N]: " n \
            || { info "Cancelled."; return; }
        info "Stopping '$name'..."
        stop_session "$id" || { err "Restart aborted: could not stop server."; return; }
        ok "Stopped."
    fi
    start_server "$id"
}

# ------------------------------- Create Server -------------------------------
create_server_ui() {
    header "CREATE SERVER"
    echo "(enter q at any prompt to cancel)"; echo

    local name slug maxp port map gslt="" id srv name_re='^[A-Za-z0-9][A-Za-z0-9 _.()-]{0,62}$'

    while :; do
        ask "Server name" || { info "Cancelled."; return; }
        name=$ANSWER
        if [[ -z $name ]]; then err "Name cannot be empty."; continue; fi
        if ! [[ $name =~ $name_re ]]; then
            err "Use 1-63 chars: letters, digits, space, _ . ( ) -  (must start with a letter/digit)."
            continue
        fi
        slug=$(printf '%s' "${name,,}" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
        if [[ -z $slug ]]; then err "Name produces an empty directory name."; continue; fi
        if db_name_taken "$name" "$slug"; then err "A server with this name already exists."; continue; fi
        if [[ -e $SERVERS_DIR/$slug || -L $SERVERS_DIR/$slug ]]; then
            err "Directory $SERVERS_DIR/$slug already exists."; continue
        fi
        break
    done

    while :; do
        ask "Client limit" "$(launch_value 0 maxplayers 13)" || { info "Cancelled."; return; }
        maxp=$ANSWER
        if [[ $maxp =~ ^[0-9]+$ ]] && ((10#$maxp >= 1 && 10#$maxp <= MAX_CLIENTS)); then
            maxp=$((10#$maxp)); break
        fi
        err "Client limit must be a number between 1 and $MAX_CLIENTS."
    done

    local defport; defport=$(suggest_port)
    while :; do
        ask "Server port" "$defport" || { info "Cancelled."; return; }
        port=$ANSWER
        if ! [[ $port =~ ^[0-9]+$ ]] || ((10#$port < MIN_PORT || 10#$port > MAX_PORT)); then
            err "Port must be a number between $MIN_PORT and $MAX_PORT."; continue
        fi
        port=$((10#$port))
        if db_port_registered "$port"; then err "Port $port is already registered. Choose another."; continue; fi
        if port_in_use "$port"; then err "Port $port is currently in use on this system. Choose another."; continue; fi
        break
    done

    echo
    info "Map: type a map name (e.g. de_dust2) or a Steam Workshop map ID / link (started with host_workshop_map)."
    while :; do
        ask "Map" "$(launch_value 0 map "$DEFAULT_MAP")" || { info "Cancelled."; return; }
        if normalize_map "$ANSWER"; then map=$MAP_NORM; break; fi
        err "Invalid map. Use a map name (letters, digits, _) or a Workshop ID / link."
    done

    echo
    info "Every CS2 server needs its own Steam Game Server Login Token (GSLT)."
    info "Create one at https://steamcommunity.com/dev/managegameservers (App ID 730)."
    info "It is optional now; you can add or change it later in Server Settings -> Basics."
    while :; do
        ask "GSLT token (press Enter to skip)" "none" || { info "Cancelled."; return; }
        gslt=$ANSWER; [[ ${gslt,,} == none ]] && gslt=""
        if [[ -z $gslt ]] || valid_gslt "$gslt"; then break; fi
        err "That does not look like a GSLT token (16-64 letters/digits)."
    done

    echo; sep
    echo "  Name      : $name"
    echo "  Directory : $SERVERS_DIR/$slug"
    echo "  Port      : $port"
    echo "  Clients   : $maxp"
    echo "  Map       : $(map_label "$map")"
    echo "  GSLT      : $([[ -n $gslt ]] && echo '(set)' || echo '(not set)')"
    echo "  Settings  : the DEFAULT settings are applied"
    sep; echo

    create_server_core "$name" "$slug" "$maxp" "$port" "$map" || return
    id=$CREATED_ID
    if [[ -n $gslt ]]; then
        if server_set_gslt "$id" "$gslt"; then ok "GSLT token saved in server.cfg (sv_setsteamaccount)."
        else info "Token not saved. Set it later in Server Settings -> Basics."; fi
    fi
    echo
    if confirm_yn "Start server now? [Y/n]: " y; then
        start_server "$id"
    fi
}

# ------------------------------- List / Status -------------------------------
print_server_table() {
    if [[ $(db_count) -eq 0 ]]; then warn "No servers registered."; return; fi
    printf '%s%-4s %-28s %-7s %-8s %s%s\n' "$BOLD" ID Name Port Status "Client Limit" "$RESET"
    sep
    local id name port max
    while IFS=$'\t' read -r id name port max; do
        printf '%-4s %-28.28s %-7s ' "$id" "$name" "$port"
        status_colored "$(status_of "$id")"
        printf ' %s\n' "$max"
    done < <(jq -r '.[] | [.id,.name,.port,.maxplayers] | @tsv' "$DB")
    sep
}

list_servers_ui() {
    header "SERVER LIST"
    print_server_table
}

print_server_status() {
    local st; st=$(status_of "$S_ID")
    echo; sep
    printf '  %-14s %s\n' "Name:"         "$S_NAME"
    printf '  %-14s %s\n' "Port:"         "$S_PORT"
    printf '  %-14s %s\n' "Map:"          "$(map_label "$S_MAP")"
    printf '  %-14s %s\n' "Client limit:" "$S_MAX"
    printf '  %-14s %s\n' "Path:"         "$S_PATH"
    printf '  %-14s ' "Status:"; status_colored "$st"; echo
    printf '  %-14s %s\n' "TMUX session:" "$(session_name "$S_ID")"
    if [[ $st == ONLINE ]] && query_players "$S_ID"; then
        printf '  %-14s %s / %s\n' "Players:" "$P_HUMANS" "$S_MAX"
    fi
    sep
}

status_ui() {
    header "SERVER STATUS"
    pick_server "Server ID (q = cancel): " || return
    print_server_status
}

# ------------------------------- Players / History ---------------------------
P_HUMANS=0; P_BOTS=0; P_ROWS=()

# query_players <id> : sends "status" to the server console via tmux and parses it
query_players() {
    local id=$1 sess out line block
    local re="^[[:space:]]*([0-9]+)[[:space:]]+([0-9:]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([a-z]+)[[:space:]]+([0-9]+)[[:space:]]+([^[:space:]]+)[[:space:]]+'(.*)'[[:space:]]*\$"
    P_HUMANS=0; P_BOTS=0; P_ROWS=()
    is_running "$id" || return 1
    sess=$(session_name "$id")

    tmux_cs2 send-keys -t "=$sess:" "status" Enter || return 1
    sleep 2
    out=$(tmux_cs2 capture-pane -p -J -t "=$sess:" -S -300) || return 1

    line=$(grep -E '^players *:' <<<"$out" | tail -n 1)
    if [[ $line =~ ([0-9]+)[[:space:]]+humans?,[[:space:]]+([0-9]+)[[:space:]]+bots? ]]; then
        P_HUMANS=${BASH_REMATCH[1]}; P_BOTS=${BASH_REMATCH[2]}
    else
        return 1
    fi

    block=$(awk '/^ *id +time +ping/ {buf=""; found=1; next} found {buf = buf $0 "\n"} END {printf "%s", buf}' <<<"$out")
    while IFS= read -r line; do
        if [[ $line =~ $re ]]; then
            [[ ${BASH_REMATCH[7]} == "BOT" ]] && continue
            P_ROWS+=("${BASH_REMATCH[8]}"$'\t'"${BASH_REMATCH[2]}"$'\t'"${BASH_REMATCH[3]}"$'\t'"${BASH_REMATCH[5]}")
        fi
    done <<<"$block"
    return 0
}

# show_history <server path> <count>  (reads the server's own game logs)
show_history() {
    local path=$1 n=$2 logdir="$1/$CSGOREL/logs" lines d t typ nm sid c
    local -a files
    mapfile -t files < <(find "$logdir" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -n 10 | cut -d' ' -f2-)
    if ((${#files[@]} == 0)); then
        warn "No game logs yet. Logging is enabled automatically; restart the server once."
        return
    fi
    lines=$(cat -- "${files[@]}" | sed -nE \
        -e 's|^L ([0-9]{2}/[0-9]{2}/[0-9]{4}) - ([0-9:]{8}): "(.*)<[0-9]+><(\[U:[0-9]+:[0-9]+\])><[^>]*>" entered the game.*|\1\t\2\tJOIN\t\3\t\4|p' \
        -e 's|^L ([0-9]{2}/[0-9]{2}/[0-9]{4}) - ([0-9:]{8}): "(.*)<[0-9]+><(\[U:[0-9]+:[0-9]+\])><[^>]*>" disconnected.*|\1\t\2\tLEAVE\t\3\t\4|p' \
        | tail -n "$n")
    if [[ -z $lines ]]; then warn "No join/leave events recorded yet."; return; fi
    printf '%s%-10s %-8s %-6s %-24s %s%s\n' "$BOLD" Date Time Event Player SteamID "$RESET"
    sep
    while IFS=$'\t' read -r d t typ nm sid; do
        if [[ $typ == JOIN ]]; then c=$GREEN; else c=$RED; fi
        printf '%-10s %-8s %s%-6s%s %-24.24s %s\n' "$d" "$t" "$c" "$typ" "$RESET" "$nm" "$sid"
    done <<<"$lines"
}

players_ui() {
    header "PLAYERS & HISTORY"
    pick_server "Server ID (q = cancel): " || return
    local id=$PICK_ID path=$S_PATH name=$S_NAME max=$S_MAX n row pname ptime pping pstate i=0
    detect_layout || return

    echo; sep
    printf '%sLive players - %s%s\n' "$BOLD" "$name" "$RESET"
    sep
    if ! is_running "$id"; then
        warn "Server is OFFLINE."
    else
        info "Querying server console..."
        if query_players "$id"; then
            printf 'Players: %s%s%s / %s   (bots: %s)\n\n' "$GREEN" "$P_HUMANS" "$RESET" "$max" "$P_BOTS"
            if ((${#P_ROWS[@]})); then
                printf '%s%-4s %-30s %-10s %-6s %s%s\n' "$BOLD" "#" Name Connected Ping State "$RESET"
                for row in "${P_ROWS[@]}"; do
                    IFS=$'\t' read -r pname ptime pping pstate <<<"$row"
                    i=$((i + 1))
                    printf '%-4s %-30.30s %-10s %-6s %s\n' "$i" "$pname" "$ptime" "$pping" "$pstate"
                done
            else
                echo "  (no human players connected)"
            fi
        else
            warn "Could not read the status output (server may still be loading)."
        fi
    fi

    echo; sep
    printf '%sJoin / leave history%s\n' "$BOLD" "$RESET"
    sep
    ask "Show last N events" 30 || return
    n=$ANSWER
    [[ $n =~ ^[0-9]+$ ]] && ((10#$n > 0)) || n=30
    show_history "$path" "$((10#$n))"
}

# ------------------------------- Delete Server -------------------------------
delete_server_ui() {
    header "DELETE SERVER"
    pick_server "Server ID to delete (q = cancel): " || return
    local id=$PICK_ID

    if ! safe_server_path "$S_PATH" "$S_SLUG"; then
        err "Refusing to delete: unsafe or inconsistent path in database ($S_PATH)."
        return
    fi
    if jq -e --argjson id "$id" --arg p "$S_PATH" 'any(.[]; .id != $id and .path == $p)' "$DB" >/dev/null 2>&1; then
        err "Refusing to delete: another registered server uses the same path."
        return
    fi

    echo; sep
    echo "  Name : $S_NAME"
    echo "  Port : $S_PORT"
    echo "  Path : $S_PATH"
    sep
    warn "This removes the server directory, its cfg/addons copies and its registry entry."
    info "The base installation ($BASE) and shared plugins are NOT touched; only symlinks are removed."
    echo
    local in
    read -r -p "Type DELETE to confirm: " in || exit 0
    if [[ $in != "DELETE" ]]; then info "Cancelled."; return; fi

    if is_running "$id"; then
        info "Stopping running server..."
        stop_session "$id" || { err "Cannot stop server; deletion aborted."; return; }
        ok "Server stopped."
    fi

    if [[ -e $S_PATH || -L $S_PATH ]]; then
        # re-validate right before the destructive command
        safe_server_path "$S_PATH" "$S_SLUG" || { err "Path check failed; deletion aborted."; return; }
        if ! rm -rf --one-file-system -- "$S_PATH"; then
            err "Failed to remove $S_PATH. Registry entry kept."
            return
        fi
    fi
    if [[ -d $BASE/game || -d $BASE ]]; then :; else err "Base installation missing after delete!"; fi

    if db_update --argjson id "$id" 'map(select(.id != $id))'; then
        clear_server_state "$id"
        ok "Server '$S_NAME' deleted."
    else
        err "Directory removed but registry entry could not be deleted. Edit $DB manually."
    fi
}

# =============================================================================
#  SERVER CONSOLE
# =============================================================================
# console_send <id> <command>: types a command into the real CS2 console
console_send() {
    local id=$1 cmd=$2 sess first
    if [[ -z $cmd ]]; then err "Command cannot be empty."; return 1; fi
    if [[ $cmd =~ [[:cntrl:]] ]]; then err "Control characters / newlines are not allowed."; return 1; fi
    if ((${#cmd} > 400)); then err "Command is too long (max 400 characters)."; return 1; fi
    is_running "$id" || { err "Server is not running."; return 1; }
    sess=$(session_name "$id")
    tmux_cs2 send-keys -t "=$sess:" -l -- "$cmd" || return 1
    tmux_cs2 send-keys -t "=$sess:" Enter || return 1
    first=${cmd%%[[:space:]]*}
    case ${first,,} in quit|exit) mark_manual_stop "$id" ;; esac
    return 0
}

# broadcast_cmd <command>: to every RUNNING server
broadcast_cmd() {
    local cmd=$1 id rc=0
    local -a ids
    mapfile -t ids < <(jq -r '.[].id' "$DB")
    for id in "${ids[@]}"; do
        load_server "$id" || continue
        if ! is_running "$id"; then msg_skip "$S_NAME is offline"; continue; fi
        if console_send "$id" "$cmd"; then ok "$S_NAME: command sent"; else err "$S_NAME: could not send command"; rc=1; fi
    done
    return $rc
}

console_attach_ui() {   # $1 = 1 for read-only
    local ro=${1:-0} id name sess in
    local -a flags=()
    if ((ro)); then header "SERVER CONSOLE (READ-ONLY)"; else header "SERVER CONSOLE"; fi
    pick_server "Server ID (q = cancel): " || return
    id=$PICK_ID; name=$S_NAME
    sess=$(session_name "$id")
    if ! is_running "$id"; then
        err "$name is offline."
        echo "Start it first."
        return
    fi
    ((ro)) && flags=(-r)
    echo
    if ((ro)); then info "Attaching to $name console in READ-ONLY mode (you can watch, not type)."
    else info "Attached to $name console. You have full access; type normal CS2 commands."; fi
    info "To return to manager without stopping the server:"
    info "Ctrl+B, then D"
    if [[ -n ${TMUX:-} ]]; then
        warn "The manager is running inside tmux: press Ctrl+B twice, then D to detach the console."
    fi
    echo
    read -r -p "Press Enter to attach..." in || exit 0
    trap ':' INT
    tmux_cs2 attach-session "${flags[@]}" -t "=$sess"
    restore_int_trap
    echo
    if is_running "$id"; then ok "Back in the manager. $name is still running."
    else warn "$name is no longer running."; fi
}

console_send_ui() {
    header "SEND CONSOLE COMMAND"
    pick_server "Server ID (q = cancel): " || return
    local id=$PICK_ID
    if ! is_running "$id"; then err "$S_NAME is offline."; echo "Start it first."; return; fi
    warn "To stop a server on purpose use 'Stop Server' (a 'quit' typed here may be restarted by the watchdog)."
    ask "Command (e.g. status, say Hello, changelevel de_dust2)" || { info "Cancelled."; return; }
    if console_send "$id" "$ANSWER"; then ok "Command sent to $S_NAME."; fi
}

console_broadcast_ui() {
    header "BROADCAST COMMAND"
    info "The command is sent to every RUNNING server (example: say Server restarts soon)."
    ask "Command" || { info "Cancelled."; return; }
    confirm_yn "Send '$ANSWER' to all running servers? [y/N]: " n || { info "Cancelled."; return; }
    broadcast_cmd "$ANSWER"
}

console_menu() {
    local c
    while :; do
        clear_screen
        dsep
        printf '%s             SERVER CONSOLE%s\n' "$BOLD" "$RESET"
        dsep
        echo
        echo "1) Attach (full interactive)"
        echo "2) Attach read-only (view only)"
        echo "3) Send one command (no attach)"
        echo "4) Broadcast command to all running servers"
        echo "5) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) console_attach_ui 0; pause ;;
            2) console_attach_ui 1; pause ;;
            3) console_send_ui;     pause ;;
            4) console_broadcast_ui; pause ;;
            5|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  LOG VIEWER
# =============================================================================
logs_ui() {
    header "LOG VIEWER"
    pick_server "Server ID (q = cancel): " || return
    need_layout || return
    local choice n file
    echo
    echo "1) Game log (newest file in $CSGOREL/logs)"
    echo "2) Console output log (logs/console.log)"
    echo
    read -r -p "Select: " choice || exit 0
    case "$(trim "$choice")" in
        1) file=$(find "$S_PATH/$CSGOREL/logs" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null \
                  | sort -n | tail -n 1 | cut -d' ' -f2-) ;;
        2) file="$S_PATH/logs/console.log" ;;
        *) info "Cancelled."; return ;;
    esac
    if [[ -z $file || ! -f $file ]]; then warn "No log file found yet."; return; fi
    ask "Number of lines (1-1000)" 50 || { info "Cancelled."; return; }
    n=$ANSWER
    if ! [[ $n =~ ^[0-9]+$ ]] || ((10#$n < 1 || 10#$n > 1000)); then err "Enter a number between 1 and 1000."; return; fi
    n=$((10#$n))
    echo; sep
    echo "$file"
    sep
    # control characters are stripped so log content cannot drive the terminal
    tail -n "$n" -- "$file" | tr -d '\000-\010\013-\037\177'
    sep
    if confirm_yn "Follow live? (Ctrl+C returns to the menu) [y/N]: " n; then
        trap ':' INT
        tail -n 0 -f -- "$file" | tr -d '\000-\010\013-\037\177'
        restore_int_trap
        echo
    fi
}

# =============================================================================
#  MAINTENANCE: update, scheduled restart, watchdog, backups
# =============================================================================
broadcast_countdown() {
    local secs=$1
    ((secs > 0)) || return 0
    broadcast_cmd "say [Server] Maintenance update in ${secs} seconds. The server will restart."
    if ((secs > 10)); then
        sleep $((secs - 10))
        broadcast_cmd "say [Server] Restarting for the update in 10 seconds."
        sleep 10
    else
        sleep "$secs"
    fi
}

restart_ids() {
    local id rc=0
    for id in "$@"; do
        load_server "$id" || continue
        start_server "$id" || rc=1
    done
    return $rc
}

update_cs2_ui() {
    header "UPDATE CS2 (SteamCMD)"
    if [[ ! -x $STEAMCMD ]]; then err "SteamCMD not found or not executable: $STEAMCMD"; return; fi
    local -a ids running=()
    local id secs=0 validate=0 rc stop_fail=0
    local -a cmd
    mapfile -t ids < <(jq -r '.[].id' "$DB")
    for id in "${ids[@]}"; do is_running "$id" && running+=("$id"); done

    echo "Running servers: ${#running[@]}"
    for id in "${running[@]}"; do load_server "$id" && echo "  - $S_NAME (port $S_PORT)"; done
    echo
    warn "The shared base installation ($BASE) is updated for ALL servers."
    warn "Running servers are stopped, then started again after the update."
    info "Metamod / CounterStrikeSharp are NOT touched. Check plugin compatibility afterwards."
    echo
    if ((${#running[@]})); then
        ask "Countdown before stopping, in seconds (0-600)" 60 || { info "Cancelled."; return; }
        if ! [[ $ANSWER =~ ^[0-9]+$ ]] || ((10#$ANSWER > 600)); then err "Enter a number between 0 and 600."; return; fi
        secs=$((10#$ANSWER))
    fi
    confirm_yn "Start the update? [y/N]: " n || { info "Cancelled."; return; }
    confirm_yn "Validate all game files (much slower)? [y/N]: " n && validate=1

    lock_ops 10 || return
    if ((${#running[@]})); then
        broadcast_countdown "$secs"
        for id in "${running[@]}"; do
            load_server "$id" || continue
            info "Stopping '$S_NAME'..."
            stop_session "$id" || { err "Could not stop '$S_NAME'."; stop_fail=1; }
        done
        if ((stop_fail)); then
            err "Update aborted; restarting the servers that were stopped."
            restart_ids "${running[@]}"
            unlock_ops; return
        fi
    fi

    cmd=("$STEAMCMD" +force_install_dir "$BASE" +login anonymous +app_update "$STEAM_APPID")
    ((validate)) && cmd+=(validate)
    cmd+=(+quit)
    info "Running SteamCMD as $CS2_USER ..."
    run_as_cs2 "${cmd[@]}" 7>&- 8>&- 9>&-
    rc=$?
    if ((rc == 0)); then
        ok "SteamCMD finished."
        patch_gameinfo
    else
        err "SteamCMD failed (exit code $rc)."
    fi

    if ((${#running[@]})); then
        if ((rc == 0)) || confirm_yn "Update failed. Start the stopped servers anyway? [Y/n]: " y; then
            info "Starting servers that were running before..."
            restart_ids "${running[@]}"
        fi
    fi
    unlock_ops
    ((rc == 0)) && info "Reminder: verify that your Metamod / CounterStrikeSharp versions still match the new game build."
}

# ----- scheduled restart (systemd transient timers) -----
sched_unit() {   # <unit> <delay-seconds> <manager args...>
    local unit=$1 delay=$2; shift 2
    systemd-run --quiet --unit="$unit" --description="CS2 scheduled action ($unit)" \
        --timer-property=AccuracySec=1s --on-active="${delay}s" "$SELF" "$@"
}

sched_add_ui() {
    header "SCHEDULE RESTART"
    command -v systemd-run >/dev/null 2>&1 || { err "systemd-run is not available."; return; }
    pick_server "Server ID to restart (q = cancel): " || return
    local id=$PICK_ID name=$S_NAME now target delay hh mm base
    now=$(date +%s)
    echo
    echo "When should '$name' restart?"
    echo "  HH:MM  = next occurrence of that time (24h, server time)"
    echo "  +N     = in N minutes (example: +30)"
    ask "When" || { info "Cancelled."; return; }
    if [[ $ANSWER =~ ^\+([0-9]{1,4})$ ]]; then
        target=$((now + 10#${BASH_REMATCH[1]} * 60))
    elif [[ $ANSWER =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
        hh=${BASH_REMATCH[1]}; mm=${BASH_REMATCH[2]}
        target=$(date -d "$hh:$mm" +%s) || { err "Invalid time."; return; }
        if ((target <= now + 60)); then target=$(date -d "tomorrow $hh:$mm" +%s) || { err "Invalid time."; return; }; fi
    else
        err "Use HH:MM or +N (minutes)."; return
    fi
    delay=$((target - now))
    if ((delay < 60)); then err "Choose a time at least 1 minute ahead."; return; fi

    echo
    info "'$name' will restart at $(date -d "@$target" '+%F %H:%M:%S'). Players get warnings 5 and 1 minute before."
    warn "Scheduled restarts do not survive a machine reboot."
    confirm_yn "Schedule it? [Y/n]: " y || { info "Cancelled."; return; }

    base="cs2-restart-$id-$target"
    if ! {
        { ((delay <= 300)) || sched_unit "$base-w5" $((delay - 300)) say "$id" "Server restarting in 5 minutes."; } \
        && { ((delay <= 60)) || sched_unit "$base-w1" $((delay - 60)) say "$id" "Server restarting in 1 minute."; } \
        && sched_unit "$base-go" "$delay" restart "$id"
    }; then
        err "Could not create the timers; removing any that were created."
        systemctl stop "$base-w5.timer" "$base-w1.timer" "$base-go.timer" >/dev/null 2>&1
        return
    fi
    ok "Restart of '$name' scheduled."
}

sched_list_ui() {
    header "SCHEDULED RESTARTS"
    command -v systemctl >/dev/null 2>&1 || { err "systemctl is not available."; return; }
    if [[ -z $(systemctl list-units --type=timer --no-legend --plain 'cs2-restart-*' 2>/dev/null) ]]; then
        info "No scheduled restarts."; return
    fi
    systemctl list-timers --no-pager 'cs2-restart-*'
}

sched_cancel_ui() {
    header "CANCEL SCHEDULED RESTART"
    command -v systemctl >/dev/null 2>&1 || { err "systemctl is not available."; return; }
    local -a units=() bases=()
    local u i=0 sid sepoch
    mapfile -t units < <(systemctl list-units --type=timer --no-legend --plain 'cs2-restart-*-go.timer' 2>/dev/null | awk '{print $1}')
    if ((${#units[@]} == 0)); then info "No scheduled restarts."; return; fi
    for u in "${units[@]}"; do
        if [[ $u =~ ^cs2-restart-([0-9]+)-([0-9]+)-go\.timer$ ]]; then
            sid=${BASH_REMATCH[1]}; sepoch=${BASH_REMATCH[2]}
            i=$((i + 1)); bases[i]="cs2-restart-$sid-$sepoch"
            printf '%s) server ID %s at %s\n' "$i" "$sid" "$(date -d "@$sepoch" '+%F %H:%M')"
        fi
    done
    ((i > 0)) || { info "No scheduled restarts."; return; }
    echo
    ask "Number to cancel (q = cancel)" || { info "Cancelled."; return; }
    if ! [[ $ANSWER =~ ^[0-9]+$ ]] || ((10#$ANSWER < 1 || 10#$ANSWER > i)); then err "Invalid selection."; return; fi
    u=${bases[$((10#$ANSWER))]}
    systemctl stop "$u-w5.timer" "$u-w1.timer" "$u-go.timer" >/dev/null 2>&1
    ok "Scheduled restart cancelled."
}

sched_menu() {
    local c
    while :; do
        clear_screen
        dsep
        printf '%s           SCHEDULED RESTART%s\n' "$BOLD" "$RESET"
        dsep
        echo
        echo "1) Schedule a restart"
        echo "2) List scheduled restarts"
        echo "3) Cancel a scheduled restart"
        echo "4) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) sched_add_ui;    pause ;;
            2) sched_list_ui;   pause ;;
            3) sched_cancel_ui; pause ;;
            4|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ----- watchdog / autostart -----
watchdog_run() {
    local id ts now recent cnt f
    local -a ids
    local rc=0
    if ! lock_ops 0; then info "Manager busy; watchdog run skipped."; return 0; fi
    if ! jq -e 'type=="array"' "$AUTOSTART_DB" >/dev/null 2>&1; then
        err "$AUTOSTART_DB is not a valid JSON array; watchdog does nothing."
        unlock_ops; return 1
    fi
    mapfile -t ids < <(jq -r '.[] | select(type=="number") | floor' "$AUTOSTART_DB")
    now=$(date +%s)
    for id in "${ids[@]}"; do
        if ! load_server "$id"; then warn "Autostart ID $id is not registered; ignoring."; continue; fi
        is_running "$id" && continue
        [[ -e $(manual_stop_file "$id") ]] && continue   # stopped on purpose
        f="$STATE_DIR/restarts-$id"
        recent=""
        if [[ -f $f ]]; then
            recent=$(awk -v now="$now" -v w="$WATCHDOG_WINDOW" '$1 ~ /^[0-9]+$/ && now-$1 < w' "$f" 2>/dev/null)
        fi
        cnt=$(printf '%s' "$recent" | grep -c . || true)
        if ((cnt >= WATCHDOG_MAX_RESTARTS)); then
            warn "'$S_NAME' is offline but hit the restart limit ($WATCHDOG_MAX_RESTARTS per $((WATCHDOG_WINDOW / 60)) min); skipping."
            continue
        fi
        { [[ -n $recent ]] && printf '%s\n' "$recent"; printf '%s\n' "$now"; } >"$f"
        info "Watchdog: '$S_NAME' is offline; starting it."
        start_server "$id" || rc=1
    done
    unlock_ops
    return $rc
}

watchdog_install() {
    command -v systemctl >/dev/null 2>&1 || { err "systemctl is not available."; return; }
    local svc="/etc/systemd/system/$WATCHDOG_UNIT.service" tim="/etc/systemd/system/$WATCHDOG_UNIT.timer"
    cat >"$svc" <<EOF
[Unit]
Description=CS2 server watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF watchdog
EOF
    cat >"$tim" <<EOF
[Unit]
Description=Run the CS2 watchdog every minute

[Timer]
OnActiveSec=30
OnUnitActiveSec=60
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    if systemctl daemon-reload && systemctl enable --now "$WATCHDOG_UNIT.timer" >/dev/null 2>&1; then
        ok "Watchdog installed and enabled (checks every minute)."
        info "It only restarts servers marked for autostart and never those you stopped from the manager."
    else
        err "Could not enable the watchdog timer."
    fi
}

watchdog_remove() {
    command -v systemctl >/dev/null 2>&1 || { err "systemctl is not available."; return; }
    systemctl disable --now "$WATCHDOG_UNIT.timer" >/dev/null 2>&1
    rm -f -- "/etc/systemd/system/$WATCHDOG_UNIT.service" "/etc/systemd/system/$WATCHDOG_UNIT.timer"
    systemctl daemon-reload
    ok "Watchdog removed."
}

watchdog_status() {
    local id name
    if command -v systemctl >/dev/null 2>&1; then
        printf 'Timer enabled : %s\n' "$(systemctl is-enabled "$WATCHDOG_UNIT.timer" 2>/dev/null || echo no)"
        printf 'Timer active  : %s\n' "$(systemctl is-active "$WATCHDOG_UNIT.timer" 2>/dev/null || echo no)"
    fi
    echo "Autostart servers:"
    if ((AUTOSTART_OK)) && [[ $(jq 'length' "$AUTOSTART_DB") -gt 0 ]]; then
        while IFS= read -r id; do
            name=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .name' "$DB")
            printf '  - ID %s  %s%s\n' "$id" "${name:-<not registered>}" \
                "$([[ -e $(manual_stop_file "$id") ]] && echo '  (stopped manually: watchdog will not restart it)')"
        done < <(jq -r '.[] | select(type=="number") | floor' "$AUTOSTART_DB")
    else
        echo "  (none)"
    fi
}

autostart_toggle_ui() {
    ((AUTOSTART_OK)) || { err "$AUTOSTART_DB is invalid; fix it first."; return; }
    pick_server "Server ID to toggle autostart (q = cancel): " || return
    local id=$PICK_ID
    if jq -e --argjson id "$id" 'index($id) != null' "$AUTOSTART_DB" >/dev/null 2>&1; then
        autostart_update --argjson id "$id" 'map(select(. != $id))' && ok "Autostart DISABLED for '$S_NAME'."
    else
        autostart_update --argjson id "$id" '. + [$id] | unique' && ok "Autostart ENABLED for '$S_NAME'."
    fi
}

watchdog_menu() {
    local c
    while :; do
        clear_screen
        dsep
        printf '%s          WATCHDOG / AUTOSTART%s\n' "$BOLD" "$RESET"
        dsep
        echo
        echo "1) Install watchdog (systemd timer)"
        echo "2) Remove watchdog"
        echo "3) Status"
        echo "4) Toggle autostart for a server"
        echo "5) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) watchdog_install;     pause ;;
            2) confirm_yn "Remove the watchdog? [y/N]: " n && watchdog_remove; pause ;;
            3) watchdog_status;      pause ;;
            4) autostart_toggle_ui;  pause ;;
            5|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ----- JSON backups (view only) -----
backups_ui() {
    header "JSON BACKUPS"
    local base f
    printf 'Directory: %s  (newest %s kept per file)\n\n' "$BACKUP_DIR" "$BACKUP_KEEP"
    for base in servers.json plugins.json autostart.json server-settings.json; do
        printf '%s%s%s\n' "$BOLD" "$base" "$RESET"
        if ! find "$BACKUP_DIR" -maxdepth 1 -type f -name "$base.*" -print -quit 2>/dev/null | grep -q .; then
            echo "  (none yet)"; continue
        fi
        while IFS= read -r f; do
            printf '  %s\n' "$f"
        done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$base.*" -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
    done
    echo
    info "Backups are never restored automatically. To restore one (with the manager closed):"
    echo "  cp -a $BACKUP_DIR/<backup-file> $SERVERS_DIR/<servers.json|shared/plugins.json>"
    echo "  jq -e 'type==\"array\"' <restored-file>"
}

maintenance_menu() {
    local c
    while :; do
        clear_screen
        dsep
        printf '%s              MAINTENANCE%s\n' "$BOLD" "$RESET"
        dsep
        echo
        echo "1) Update CS2 (SteamCMD, safe)"
        echo "2) Scheduled restart"
        echo "3) Watchdog / autostart"
        echo "4) JSON backups"
        echo "5) Update launcher"
        echo "6) Launcher settings"
        echo "7) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) update_cs2_ui; pause ;;
            2) sched_menu ;;
            3) watchdog_menu ;;
            4) backups_ui; pause ;;
            5) update_launcher_ui; pause ;;
            6) launcher_settings_ui ;;
            7|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ------------------------------- Main menu -----------------------------------
main_menu() {
    local choice
    while :; do
        clear_screen
        dsep
        printf '%s                CS2NEXUS%s\n' "$BOLD" "$RESET"
        printf '            Server Manager & Launcher\n'
        dsep
        echo
        echo " 1) Create Server"
        echo " 2) Start Server"
        echo " 3) Stop Server"
        echo " 4) Restart Server"
        echo " 5) List Servers"
        echo " 6) Server Status"
        echo " 7) Delete Server"
        echo " 8) Players & History"
        echo " 9) Plugins"
        echo "10) Server Settings"
        echo "11) Server Console"
        echo "12) Log Viewer"
        echo "13) Maintenance"
        echo "14) Exit"
        echo
        read -r -p "Select: " choice || exit 0
        case "$(trim "$choice")" in
            1) create_server_ui;  pause ;;
            2) start_server_ui;   pause ;;
            3) stop_server_ui;    pause ;;
            4) restart_server_ui; pause ;;
            5) list_servers_ui;   pause ;;
            6) status_ui;         pause ;;
            7) delete_server_ui;  pause ;;
            8) players_ui;        pause ;;
            9) plugins_menu ;;
            10) settings_menu ;;
            11) console_menu ;;
            12) logs_ui;          pause ;;
            13) maintenance_menu ;;
            14) clear_screen; echo "Goodbye."; exit 0 ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  CONFIG FILE  (/etc/cs2nexus.conf): plain KEY=VALUE lines, never sourced
# =============================================================================
SETUP_DONE=0
REQUIRED_CMDS=(jq tmux ss runuser flock find cmp diff mktemp awk sed curl unzip tar)

conf_valid_key() {
    case $1 in
        BASE|SETUP_DONE|NEXUS_REPO|NEXUS_BRANCH|EXTRA_PLUGIN_REPOS|GITHUB_TOKEN|AUTOUPDATE|UPDATE_ACTION|STEAMCMD) return 0 ;;
    esac
    return 1
}

conf_valid_value() {   # <key> <value>
    local k=$1 v=$2
    [[ $v =~ ^[A-Za-z0-9_./:@,\ -]*$ ]] || return 1
    case $k in
        BASE|STEAMCMD)  [[ $v =~ ^/[A-Za-z0-9_./-]+$ ]] ;;
        SETUP_DONE|AUTOUPDATE) [[ $v == 0 || $v == 1 ]] ;;
        UPDATE_ACTION)  [[ $v == none || $v == reload ]] ;;
        NEXUS_REPO)     [[ $v =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ;;
        NEXUS_BRANCH)   [[ $v =~ ^[A-Za-z0-9_./-]+$ ]] ;;
        EXTRA_PLUGIN_REPOS) [[ -z $v || $v =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)*$ ]] ;;
        GITHUB_TOKEN)   [[ -z $v || $v =~ ^[A-Za-z0-9_]+$ ]] ;;
        *) return 1 ;;
    esac
}

load_conf() {
    local line k v
    [[ -f $CONF_FILE ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[A-Z_]+= ]] || continue
        k=${line%%=*}; v=${line#*=}
        conf_valid_key "$k" || continue
        conf_valid_value "$k" "$v" || continue
        printf -v "$k" '%s' "$v"
    done <"$CONF_FILE"
}

conf_set() {   # <KEY> <value>
    local k=$1 v=$2 tmp
    conf_valid_key "$k" || { err "Unknown setting: $k"; return 1; }
    conf_valid_value "$k" "$v" || { err "Invalid value for $k."; return 1; }
    tmp=$(mktemp "$CONF_FILE.XXXXXX") || { err "Cannot write $CONF_FILE"; return 1; }
    { [[ -f $CONF_FILE ]] && grep -v "^$k=" "$CONF_FILE"; printf '%s=%s\n' "$k" "$v"; } >"$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$CONF_FILE" || { rm -f -- "$tmp"; err "Cannot write $CONF_FILE"; return 1; }
    printf -v "$k" '%s' "$v"
}

# =============================================================================
#  GITHUB HELPERS
# =============================================================================
gh_curl() {   # <url> [curl args...]
    local url=$1; shift
    local -a h=(-H "Accept: application/vnd.github+json" -H "User-Agent: CS2Nexus")
    [[ -n $GITHUB_TOKEN ]] && h+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL -m 120 "${h[@]}" "$@" "$url"
}
gh_api() { gh_curl "$GH_API$1"; }
gh_hint() {
    warn "GitHub could not be reached or refused the request (offline, private repo or rate limit)."
    warn "If the repo is private or the rate limit is hit, set a GitHub token: Maintenance -> Launcher settings."
}

# =============================================================================
#  SETUP HELPERS (packages, user, SteamCMD, CS2 files, Metamod, CounterStrikeSharp)
# =============================================================================
bootstrap_deps() {   # <menu|cli>
    local mode=${1:-menu} c pk
    local -a missing=() pkgs=()
    for c in "${REQUIRED_CMDS[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    ((${#missing[@]})) || return 0
    for c in "${missing[@]}"; do
        case $c in
            ss) pk=iproute2 ;; runuser|flock) pk=util-linux ;; find) pk=findutils ;;
            cmp|diff) pk=diffutils ;; awk) pk=gawk ;; mktemp) pk=coreutils ;; *) pk=$c ;;
        esac
        pkgs+=("$pk")
    done
    mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
    if [[ $mode != menu ]]; then
        err "Missing required tools: ${missing[*]} (install: apt install -y ${pkgs[*]})"
        return 1
    fi
    warn "Missing required tools: ${missing[*]}"
    if ! command -v apt-get >/dev/null 2>&1; then
        err "apt-get not found. Install manually: ${pkgs[*]}"; return 1
    fi
    confirm_yn "Install them now (${pkgs[*]})? [Y/n]: " y || return 1
    info "Installing packages..."
    if ! { DEBIAN_FRONTEND=noninteractive apt-get update -qq \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"; }; then
        err "Package installation failed."; return 1
    fi
    for c in "${missing[@]}"; do
        command -v "$c" >/dev/null 2>&1 || { err "'$c' is still missing."; return 1; }
    done
    ok "Packages installed."
}

ensure_cs2_user() {
    id "$CS2_USER" >/dev/null 2>&1 && return 0
    info "Creating Linux user '$CS2_USER'..."
    useradd -m -s /bin/bash -d "$CS2_HOME" "$CS2_USER" || { err "Could not create user '$CS2_USER'."; return 1; }
    ok "User '$CS2_USER' created."
}

cs2_dir_ok() { [[ -d $1 && ( -f $1/game/cs2.sh || -f $1/cs2.sh ) ]]; }

free_gb() {   # <path>  -> free GB of the nearest existing parent
    local p=$1
    while [[ -n $p && ! -d $p ]]; do p=$(dirname -- "$p"); done
    df -BG --output=avail -- "${p:-/}" 2>/dev/null | tail -n 1 | tr -dc '0-9'
}

install_steamcmd() {
    local p tmp
    if [[ -x $STEAMCMD ]]; then ok "SteamCMD found: $STEAMCMD"; return 0; fi
    p=$(command -v steamcmd 2>/dev/null || true)
    if [[ -n $p && -x $p ]]; then STEAMCMD=$p; ok "SteamCMD found: $STEAMCMD"; return 0; fi
    if ! command -v apt-get >/dev/null 2>&1; then err "apt-get not found; install SteamCMD manually."; return 1; fi

    info "Installing SteamCMD and its 32-bit libraries..."
    export DEBIAN_FRONTEND=noninteractive
    dpkg --add-architecture i386 2>/dev/null
    if ! command -v add-apt-repository >/dev/null 2>&1; then apt-get install -y -qq software-properties-common >/dev/null 2>&1; fi
    command -v add-apt-repository >/dev/null 2>&1 && add-apt-repository -y multiverse >/dev/null 2>&1
    echo 'steamcmd steam/question select I AGREE' | debconf-set-selections 2>/dev/null
    echo 'steamcmd steam/license note' | debconf-set-selections 2>/dev/null
    if apt-get update -qq && apt-get install -y -qq steamcmd lib32gcc-s1 lib32stdc++6 ca-certificates \
        && [[ -x /usr/games/steamcmd ]]; then
        STEAMCMD=/usr/games/steamcmd
        ok "SteamCMD installed ($STEAMCMD)."
        return 0
    fi

    warn "Package install failed; falling back to the official SteamCMD tarball."
    tmp=$(mktemp -d /tmp/cs2nexus.XXXXXX) || return 1
    if curl -fsSL -m 120 -o "$tmp/steamcmd.tgz" "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
        && install -d -o "$CS2_USER" -g "$CS2_GROUP" -- "$CS2_HOME/steamcmd" \
        && tar -xzf "$tmp/steamcmd.tgz" -C "$CS2_HOME/steamcmd" \
        && chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$CS2_HOME/steamcmd" \
        && [[ -x $CS2_HOME/steamcmd/steamcmd.sh ]]; then
        STEAMCMD="$CS2_HOME/steamcmd/steamcmd.sh"
        rm -rf -- "$tmp"
        ok "SteamCMD installed ($STEAMCMD)."
        return 0
    fi
    rm -rf -- "$tmp"
    err "Could not install SteamCMD."
    return 1
}

link_steamclient() {   # CS2 needs ~/.steam/sdk64/steamclient.so for the cs2 user
    local sc
    sc=$(find "$CS2_HOME" -maxdepth 6 -name steamclient.so -path '*linux64*' -print -quit 2>/dev/null)
    [[ -n $sc ]] || return 0
    run_as_cs2 bash -c 'mkdir -p "$HOME/.steam/sdk64" && ln -sf "$1" "$HOME/.steam/sdk64/steamclient.so"' _ "$sc" 7>&- 8>&- 9>&-
}

install_cs2_files() {   # <dir>
    local dir=$1 try rc
    install -d -m 755 -o "$CS2_USER" -g "$CS2_GROUP" -- "$dir" || { err "Cannot create $dir"; return 1; }
    for try in 1 2 3; do
        info "Downloading CS2 dedicated server files (attempt $try/3). This is large (60+ GB) and can take a long time..."
        run_as_cs2 "$STEAMCMD" +force_install_dir "$dir" +login anonymous +app_update "$STEAM_APPID" validate +quit 7>&- 8>&- 9>&-
        rc=$?
        if ((rc == 0)) && cs2_dir_ok "$dir"; then
            link_steamclient
            ok "CS2 server files installed in $dir"
            return 0
        fi
        warn "SteamCMD exited with code $rc (common on the first run); trying again..."
        sleep 3
    done
    err "CS2 files could not be installed. Check the disk space and internet connection, then run the launcher again."
    return 1
}

# Metamod needs one line in gameinfo.gi; game updates overwrite it, so this is
# re-applied after every update (idempotent).
patch_gameinfo() {
    local gi
    need_layout || return 1
    gi="$BASE/$CSGOREL/gameinfo.gi"
    [[ -f $gi ]] || return 0
    [[ -d $BASE/$CSGOREL/addons/metamod ]] || return 0
    if grep -q 'csgo/addons/metamod' "$gi"; then return 0; fi
    if sed -i '0,/^[[:space:]]*Game[[:space:]]\+csgo[[:space:]]*$/s//\t\t\tGame\tcsgo\/addons\/metamod\n&/' "$gi" \
        && grep -q 'csgo/addons/metamod' "$gi"; then
        chown "$CS2_USER:$CS2_GROUP" -- "$gi" 2>/dev/null
        ok "gameinfo.gi patched so Metamod loads."
    else
        warn "Could not patch $gi; add the line 'Game csgo/addons/metamod' above 'Game csgo' manually."
        return 1
    fi
}

css_asset_url() {
    gh_api "/repos/roflmuffin/CounterStrikeSharp/releases/latest" \
        | jq -r '[.assets[] | select(.name | test("with-runtime.*linux|linux.*with-runtime"; "i"))][0].browser_download_url // empty'
}

install_metamod_css() {
    local csgo tmp name url
    need_layout || return 1
    csgo="$BASE/$CSGOREL"
    tmp=$(mktemp -d /tmp/cs2nexus.XXXXXX) || return 1
    info "Installing Metamod:Source..."
    name=$(curl -fsSL -m 30 "$MM_DROP/mmsource-latest-linux" 2>/dev/null) && name=$(trim "$name")
    if [[ ! $name =~ ^mmsource-[A-Za-z0-9._-]+\.tar\.gz$ ]] \
        || ! curl -fsSL -m 300 -o "$tmp/mm.tgz" "$MM_DROP/$name" \
        || ! tar -xzf "$tmp/mm.tgz" -C "$csgo" --no-same-owner; then
        err "Metamod:Source could not be installed."; rm -rf -- "$tmp"; return 1
    fi
    ok "Metamod:Source installed ($name)."

    info "Installing CounterStrikeSharp (with runtime)..."
    url=$(css_asset_url)
    if [[ -z $url ]] \
        || ! gh_curl "$url" -o "$tmp/css.zip" \
        || ! unzip -qo "$tmp/css.zip" -d "$csgo"; then
        gh_hint; err "CounterStrikeSharp could not be installed."; rm -rf -- "$tmp"; return 1
    fi
    chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$csgo/addons" 2>/dev/null
    rm -rf -- "$tmp"
    ok "CounterStrikeSharp installed."
    patch_gameinfo
}

# =============================================================================
#  FIRST-TIME SETUP WIZARD
# =============================================================================
wizard_step() { echo; printf '%s== Step %s: %s ==%s\n' "$BOLD" "$1" "$2" "$RESET"; }

run_setup_wizard() {
    local have=0 def dir name="" slug maxp=13 port=27015 map=$DEFAULT_MAP gslt=""
    local want_mm=1 want_plug=1 want_wd=1 free id
    local name_re='^[A-Za-z0-9][A-Za-z0-9 _.()-]{0,62}$' need_server=0 d_maxp d_map

    header "CS2NEXUS - FIRST-TIME SETUP"
    echo "Welcome to CS2Nexus. This one-time setup prepares this machine:"
    echo "  - finds your CS2 server files, or installs SteamCMD and downloads them"
    echo "  - creates your first server with the default settings"
    echo "(enter q at any question to cancel)"
    echo

    wizard_step "1/5" "System"
    ensure_cs2_user || return 1
    ok "System user '$CS2_USER' is ready."

    wizard_step "2/5" "CS2 server files"
    def=n; cs2_dir_ok "$BASE" && def=y
    if confirm_yn "Do you already have the CS2 dedicated server files on this machine? [$([[ $def == y ]] && echo 'Y/n' || echo 'y/N')]: " "$def"; then
        have=1
        while :; do
            ask "Folder that contains the CS2 server files" "$BASE" || { info "Setup cancelled."; return 1; }
            dir=$ANSWER
            if [[ $dir =~ ^/[A-Za-z0-9_./-]+$ ]] && cs2_dir_ok "$dir"; then BASE=${dir%/}; break; fi
            err "No CS2 server files found there (cs2.sh is missing). Enter the folder that contains 'game/cs2.sh'."
        done
        ok "Using CS2 files in $BASE"
    else
        while :; do
            ask "Where should the CS2 files be installed" "$BASE" || { info "Setup cancelled."; return 1; }
            dir=${ANSWER%/}
            if ! [[ $dir =~ ^/[A-Za-z0-9_./-]+$ ]]; then err "Use an absolute path (letters, digits, / . _ -)."; continue; fi
            if [[ -e $dir && -n $(ls -A -- "$dir" 2>/dev/null) ]] && ! cs2_dir_ok "$dir"; then
                err "$dir exists and is not empty."; continue
            fi
            free=$(free_gb "$dir")
            if [[ -n $free ]] && ((free < 65)); then
                warn "Only ${free} GB free there; CS2 needs about 65 GB."
                confirm_yn "Continue anyway? [y/N]: " n || continue
            fi
            BASE=$dir; break
        done
        ok "CS2 will be installed in $BASE"
    fi

    wizard_step "3/5" "SteamCMD"
    if ((have)); then
        if [[ -x $STEAMCMD ]] || command -v steamcmd >/dev/null 2>&1; then install_steamcmd
        elif confirm_yn "SteamCMD is not installed (needed for game updates). Install it now? [Y/n]: " y; then install_steamcmd || warn "Continuing without SteamCMD; 'Update CS2' will not work."
        fi
    else
        install_steamcmd || { err "SteamCMD is required to download CS2. Setup stopped."; return 1; }
    fi

    wizard_step "4/5" "Your first server"
    if [[ $(jq 'length' "$DB") -eq 0 ]]; then
        need_server=1
        d_maxp=$(jq -r '.[]|select(.id==0)|.launch.maxplayers // empty' "$SETTINGS_DB" 2>/dev/null)
        d_map=$(jq -r '.[]|select(.id==0)|.launch.map // empty' "$SETTINGS_DB" 2>/dev/null)
        [[ -n $d_maxp ]] && maxp=$d_maxp
        [[ -n $d_map ]] && map=$d_map
        while :; do
            ask "Server name" "CS2Nexus Server" || { info "Setup cancelled."; return 1; }
            name=$ANSWER
            [[ $name =~ $name_re ]] && break
            err "Use 1-63 chars: letters, digits, space, _ . ( ) -  (must start with a letter/digit)."
        done
        slug=$(printf '%s' "${name,,}" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
        [[ -z $slug || $slug == shared ]] && slug="server-1"
        while :; do
            ask "Client limit (max players)" "$maxp" || { info "Setup cancelled."; return 1; }
            if [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= MAX_CLIENTS)); then maxp=$((10#$ANSWER)); break; fi
            err "Enter a number between 1 and $MAX_CLIENTS."
        done
        while :; do
            ask "Server port" "$port" || { info "Setup cancelled."; return 1; }
            if [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= MIN_PORT && 10#$ANSWER <= MAX_PORT)); then
                port=$((10#$ANSWER))
                if port_in_use "$port"; then err "Port $port is already in use."; continue; fi
                break
            fi
            err "Port must be between $MIN_PORT and $MAX_PORT."
        done
        while :; do
            ask "Start map (name, or a Workshop ID / link)" "$map" || { info "Setup cancelled."; return 1; }
            if normalize_map "$ANSWER"; then map=$MAP_NORM; break; fi
            err "Invalid map. Use a map name or a Workshop ID / link."
        done
        while :; do
            ask "GSLT token (create at steamcommunity.com/dev/managegameservers, App ID 730; Enter to skip)" "none" || { info "Setup cancelled."; return 1; }
            gslt=$ANSWER; [[ ${gslt,,} == none ]] && gslt=""
            if [[ -z $gslt ]] || valid_gslt "$gslt"; then break; fi
            err "That does not look like a GSLT token."
        done
    else
        info "Servers are already registered; skipping server creation."
    fi
    confirm_yn "Install Metamod:Source + CounterStrikeSharp (needed for plugins)? [Y/n]: " y || want_mm=0
    ((want_mm)) && confirm_yn "Install the default plugins from CS2Nexus (ServerCommands, MapVote, Parachute, AstraSkins)? [Y/n]: " y || want_plug=0
    ((need_server)) && { confirm_yn "Enable the watchdog (auto-start the server after a crash or reboot)? [Y/n]: " y || want_wd=0; } || want_wd=0

    echo; sep
    echo "  CS2 files : $BASE $( ((have)) && echo '(existing)' || echo '(will be downloaded)')"
    ((need_server)) && echo "  Server    : $name | port $port | $maxp clients | map $map"
    echo "  Metamod + CounterStrikeSharp : $( ((want_mm)) && echo yes || echo no)"
    echo "  Default plugins              : $( ((want_plug)) && echo yes || echo no)"
    sep
    confirm_yn "Start the installation now? [Y/n]: " y || { info "Setup cancelled."; return 1; }

    wizard_step "5/5" "Installing"
    conf_set BASE "$BASE" || return 1
    if ! ((have)); then install_cs2_files "$BASE" || return 1; fi
    detect_layout || return 1
    ((want_mm)) && { install_metamod_css || warn "Metamod/CounterStrikeSharp were not installed. Retry later from Maintenance."; }
    if ((need_server)); then
        info "Creating server '$name'..."
        if create_server_core "$name" "$slug" "$maxp" "$port" "$map"; then
            id=$CREATED_ID
            [[ -n $gslt ]] && server_set_gslt "$id" "$gslt"
            ok "Server '$name' created (ID $id)."
            ((want_plug)) && install_default_plugins
            if ((want_wd)); then
                autostart_update --argjson id "$id" '. + [$id] | unique' >/dev/null && watchdog_install
            fi
        else
            err "Server creation failed."; return 1
        fi
    elif ((want_plug)); then
        install_default_plugins
    fi
    conf_set SETUP_DONE 1
    echo; dsep
    ok "CS2Nexus setup finished."
    dsep
    if ((need_server)) && confirm_yn "Start '$name' now? [Y/n]: " y; then start_server "$id"; fi
    pause
    return 0
}

# =============================================================================
#  SERVER SETTINGS  (defaults + per-server cfg, launch options, quick options)
#  Stored in shared/server-settings.json (top-level array). Entry id 0 holds the
#  DEFAULT settings that are copied into every newly created server.
#  servers.json is never given new fields; only name/port/maxplayers/map change.
# =============================================================================
SETTINGS_OK=1
declare -A CAT_TYPE=() CAT_CAT=() CAT_HINT=() CAT_DESC=()
declare -A FT_LABEL=() FT_KIND=() FT_ON=() FT_OFF=()
CAT_KEYS=(); CAT_CATS=(); FT_KEYS=()
CATALOG_LOADED=0

# key|category|type|hint|description    (type: b=0/1, i=integer, f=decimal, s=text, e:a,b,c=choice)
catalog_rows() { cat <<'EOF'
hostname|General|s|server name|Name shown in the server browser (empty = launcher name)
sv_password|General|s|join password|Password players need to join
rcon_password|General|s|rcon password|Remote console password
sv_cheats|General|b|0|Allow cheat commands
sv_lan|General|b|0|LAN-only server (not listed on the internet)
sv_region|General|i|255|Region code (0 US East, 1 US West, 2 S.America, 3 Europe, 4 Asia, 5 Australia, 6 Middle East, 7 Africa, 255 World)
sv_tags|General|s|tag1,tag2|Server tags
sv_hibernate_when_empty|General|b|1|Sleep when no players are connected
sv_pausable|General|b|0|Players may pause the game
sv_alltalk|Voice & Chat|b|0|Everyone hears everyone (alive players)
sv_full_alltalk|Voice & Chat|b|0|Dead and living players hear each other
sv_talk_enemy_dead|Voice & Chat|b|0|Dead players can talk to enemy team
sv_talk_enemy_living|Voice & Chat|b|0|Living players can talk to enemy team
sv_deadtalk|Voice & Chat|b|0|Dead players can talk to living players
sv_voiceenable|Voice & Chat|b|1|Enable voice chat
sv_allow_votes|Voice & Chat|b|1|Allow player votes
sv_vote_issue_kick_allowed|Voice & Chat|b|1|Allow vote-kick
sv_vote_issue_changelevel_allowed|Voice & Chat|b|1|Allow vote to change map
sv_vote_issue_restart_game_allowed|Voice & Chat|b|0|Allow vote to restart the game
sv_vote_issue_scramble_teams_allowed|Voice & Chat|b|0|Allow vote to scramble teams
mp_roundtime|Rounds & Match|f|1.92|Minutes per round
mp_roundtime_defuse|Rounds & Match|f|1.92|Minutes per round on defuse maps
mp_roundtime_hostage|Rounds & Match|f|1.92|Minutes per round on hostage maps
mp_freezetime|Rounds & Match|i|15|Freeze time at round start (seconds)
mp_buytime|Rounds & Match|i|20|Buy time (seconds)
mp_buy_anywhere|Rounds & Match|e:0,1,2,3|0|Buy anywhere (0 off, 1 both, 2 T, 3 CT)
mp_maxrounds|Rounds & Match|i|24|Rounds per match (0 = unlimited)
mp_timelimit|Rounds & Match|i|0|Map time limit in minutes (0 = none)
mp_halftime|Rounds & Match|b|1|Switch sides at halftime
mp_match_can_clinch|Rounds & Match|b|1|End match early when a team clinches
mp_do_warmup_period|Rounds & Match|b|1|Enable warmup
mp_warmuptime|Rounds & Match|i|30|Warmup length (seconds)
mp_warmup_pausetimer|Rounds & Match|b|0|Pause the warmup timer
mp_startmoney|Rounds & Match|i|800|Starting money
mp_maxmoney|Rounds & Match|i|16000|Maximum money
mp_afterroundmoney|Rounds & Match|i|0|Money given to everyone after a round
mp_c4timer|Rounds & Match|i|40|Bomb timer (seconds)
mp_round_restart_delay|Rounds & Match|i|7|Delay before the next round (seconds)
mp_win_panel_display_time|Rounds & Match|i|3|Win panel display time (seconds)
mp_ignore_round_win_conditions|Rounds & Match|b|0|Rounds never end by win conditions
mp_overtime_enable|Rounds & Match|b|0|Enable overtime
mp_overtime_maxrounds|Rounds & Match|i|6|Overtime rounds
mp_overtime_startmoney|Rounds & Match|i|10000|Overtime starting money
mp_respawn_on_death_t|Rounds & Match|b|0|Terrorists respawn after death
mp_respawn_on_death_ct|Rounds & Match|b|0|Counter-terrorists respawn after death
mp_free_armor|Rounds & Match|e:0,1,2|0|Free armor (1 kevlar, 2 kevlar+helmet)
mp_defuser_allocation|Rounds & Match|e:0,1,2|0|Free defuse kits (1 random CT, 2 all CT)
mp_death_drop_gun|Rounds & Match|e:0,1,2|1|Drop weapon on death (0 none, 1 best, 2 current)
mp_death_drop_grenade|Rounds & Match|e:0,1,2,3|2|Drop grenades on death (0 none, 1 best, 2 current, 3 all)
mp_weapons_allow_map_placed|Rounds & Match|b|1|Allow map placed weapons
mp_playercashawards|Rounds & Match|b|1|Cash awards for player actions
mp_teamcashawards|Rounds & Match|b|1|Cash awards for team results
mp_autoteambalance|Teams & Players|b|1|Automatic team balancing
mp_limitteams|Teams & Players|i|2|Max team size difference (0 = no limit)
mp_force_pick_time|Teams & Players|i|15|Seconds a player has to pick a team
mp_forcecamera|Teams & Players|e:0,1,2|1|Spectator camera (0 free, 1 team only, 2 first person)
mp_autokick|Teams & Players|b|1|Kick idle players and team killers
mp_friendlyfire|Teams & Players|b|0|Friendly fire
mp_solid_teammates|Teams & Players|e:0,1,2|1|Teammates are solid (0 no, 1 yes, 2 only after round)
mp_tkpunish|Teams & Players|b|0|Punish team killers next round
mp_spectators_max|Teams & Players|i|2|Maximum spectators
mp_teamname_1|Teams & Players|s|team name|Counter-terrorist team name
mp_teamname_2|Teams & Players|s|team name|Terrorist team name
sv_gravity|Movement & Weapons|i|800|Gravity
sv_airaccelerate|Movement & Weapons|f|12|Air acceleration
sv_accelerate|Movement & Weapons|f|5.5|Ground acceleration
sv_friction|Movement & Weapons|f|5.2|Friction
sv_maxspeed|Movement & Weapons|f|320|Maximum speed
sv_stopspeed|Movement & Weapons|f|80|Stop speed
sv_enablebunnyhopping|Movement & Weapons|b|0|Allow bunny hopping speed gain
sv_autobunnyhopping|Movement & Weapons|b|0|Hold jump to keep hopping
sv_staminamax|Movement & Weapons|f|80|Maximum stamina
sv_staminajumpcost|Movement & Weapons|f|0.08|Stamina cost of a jump
sv_staminalandcost|Movement & Weapons|f|0.05|Stamina cost of landing
sv_staminarecoveryrate|Movement & Weapons|f|60|Stamina recovery rate
sv_air_max_wishspeed|Movement & Weapons|f|30|Maximum air wish speed
sv_falldamage_scale|Movement & Weapons|f|1|Fall damage multiplier
sv_infinite_ammo|Movement & Weapons|e:0,1,2|0|Infinite ammo (1 clip, 2 reserve)
weapon_recoil_scale|Movement & Weapons|f|2|Weapon recoil multiplier
sv_maxrate|Clients & Network|i|0|Maximum bandwidth per client (0 = unlimited)
sv_minrate|Clients & Network|i|64000|Minimum bandwidth per client
sv_timeout|Clients & Network|i|65|Seconds before a silent client is dropped
sv_maxusrcmdprocessticks|Clients & Network|i|16|Max client command ticks per frame
sv_clockcorrection_msecs|Clients & Network|i|15|Clock correction (ms)
sv_kick_ban_duration|Clients & Network|i|15|Ban minutes after a vote-kick
sv_kick_players_with_cooldown|Clients & Network|e:0,1,2|1|Kick players with a cooldown (0 none, 1 untrusted, 2 all)
sv_max_queries_sec|Clients & Network|i|3|Max queries per second per IP
sv_visiblemaxplayers|Clients & Network|i|13|Player limit shown in the browser
tv_enable|GOTV|b|0|Enable GOTV
tv_port|GOTV|i|27020|GOTV port (default: game port + 5)
tv_delay|GOTV|i|105|GOTV delay (seconds)
tv_maxclients|GOTV|i|128|GOTV maximum spectators
tv_autorecord|GOTV|b|0|Record demos automatically
tv_name|GOTV|s|GOTV|GOTV name
tv_title|GOTV|s|title|GOTV title
tv_password|GOTV|s|password|GOTV password
tv_advertise_watchable|GOTV|b|0|List GOTV in the server browser
bot_quota|Bots|i|0|Number of bots
bot_quota_mode|Bots|e:normal,fill,match|normal|How bots fill the server
bot_difficulty|Bots|e:0,1,2,3|1|Bot difficulty (0 easy ... 3 expert)
bot_join_after_player|Bots|b|0|Bots only join after a human
bot_chatter|Bots|e:off,radio,minimal,normal|normal|Bot chatter
bot_knives_only|Bots|b|0|Bots use knives only
bot_pistols_only|Bots|b|0|Bots use pistols only
bot_zombie|Bots|b|0|Bots stand still
bot_defer_to_human_goals|Bots|b|0|Bots leave objectives to humans
bot_defer_to_human_items|Bots|b|0|Bots leave items to humans
mp_logdetail|Logging|e:0,1,2,3|0|Log damage detail (0 off ... 3 all)
sv_logecho|Logging|b|1|Echo log lines to the console
EOF
}

# name|label|kind|on commands|off commands    (commands separated by ;)
feature_rows() { cat <<'EOF'
team_balance|Auto team balance (mp_autoteambalance + mp_limitteams)|persist|mp_autoteambalance 1;mp_limitteams 2|mp_autoteambalance 0;mp_limitteams 0
force_pick_time|Team pick timer (mp_force_pick_time)|persist|mp_force_pick_time 15|mp_force_pick_time 0
force_camera|Forced spectator camera (mp_forcecamera)|persist|mp_forcecamera 1|mp_forcecamera 0
auto_kick|Auto-kick idle players / team killers (mp_autokick)|persist|mp_autokick 1|mp_autokick 0
bunnyhop|Bunny hop|persist|sv_enablebunnyhopping 1;sv_autobunnyhopping 1|sv_enablebunnyhopping 0;sv_autobunnyhopping 0
infinite_ammo|Infinite ammo|persist|sv_infinite_ammo 1|sv_infinite_ammo 0
infinite_money|Infinite money|persist|mp_startmoney 16000;mp_maxmoney 16000;mp_afterroundmoney 16000|mp_startmoney 800;mp_maxmoney 16000;mp_afterroundmoney 0
buy_anywhere|Buy anywhere|persist|mp_buy_anywhere 1|mp_buy_anywhere 0
friendly_fire|Friendly fire|persist|mp_friendlyfire 1|mp_friendlyfire 0
alltalk|All talk (voice)|persist|sv_alltalk 1;sv_full_alltalk 1|sv_alltalk 0;sv_full_alltalk 0
respawn|Respawn on death|persist|mp_respawn_on_death_t 1;mp_respawn_on_death_ct 1|mp_respawn_on_death_t 0;mp_respawn_on_death_ct 0
warmup|Warmup period|persist|mp_do_warmup_period 1|mp_do_warmup_period 0
cheats|Cheats (sv_cheats)|persist|sv_cheats 1|sv_cheats 0
gotv|GOTV (tv_enable)|persist|tv_enable 1|tv_enable 0
swap_teams|Swap teams|oneshot|mp_swapteams 1|mp_swapteams 0
scramble_teams|Scramble teams|oneshot|mp_scrambleteams 1|mp_scrambleteams 0
EOF
}

catalog_load() {
    ((CATALOG_LOADED)) && return 0
    local k c t h d n l on off
    while IFS='|' read -r k c t h d; do
        [[ -n $k ]] || continue
        CAT_KEYS+=("$k"); CAT_TYPE[$k]=$t; CAT_CAT[$k]=$c; CAT_HINT[$k]=$h; CAT_DESC[$k]=$d
        [[ " ${CAT_CATS[*]} " == *" ${c// /_} "* ]] || CAT_CATS+=("${c// /_}")
    done < <(catalog_rows)
    while IFS='|' read -r n l t on off; do
        [[ -n $n ]] || continue
        FT_KEYS+=("$n"); FT_LABEL[$n]=$l; FT_KIND[$n]=$t; FT_ON[$n]=$on; FT_OFF[$n]=$off
    done < <(feature_rows)
    CATALOG_LOADED=1
}

# st_valid <type> <value>  (prints the reason on failure)
st_valid() {
    local t=$1 v=$2 list x
    case ${t%%:*} in
        b) [[ $v == 0 || $v == 1 ]] || { err "Enter 0 or 1."; return 1; } ;;
        i) [[ $v =~ ^-?[0-9]{1,9}$ ]] || { err "Enter a whole number."; return 1; } ;;
        f) [[ $v =~ ^-?[0-9]{1,6}(\.[0-9]{1,4})?$ ]] || { err "Enter a number (e.g. 1.92)."; return 1; } ;;
        s)
            if [[ -z $v || ${#v} -gt 100 || $v =~ [[:cntrl:]] || $v == *\"* || $v == *\;* || $v == *\\* ]]; then
                err "Text must be 1-100 characters without quotes, semicolons or backslashes."; return 1
            fi ;;
        e)
            list=${t#e:}
            for x in ${list//,/ }; do [[ $x == "$v" ]] && return 0; done
            err "Choose one of: ${list//,/, }"; return 1 ;;
        *) err "Unknown type."; return 1 ;;
    esac
    return 0
}

# ---------- storage helpers ----------
settings_update() { json_update "$SETTINGS_DB" "$@"; }
st_exists() { jq -e --argjson id "$1" 'any(.[]; .id == $id)' "$SETTINGS_DB" >/dev/null 2>&1; }
st_get()    { jq -c --argjson id "$1" 'first(.[] | select(.id == $id)) // empty' "$SETTINGS_DB" 2>/dev/null; }
# st_update <id> '<jq expression applied to the entry>' [jq --arg/--argjson args...]
st_update() {
    local id=$1 expr=$2; shift 2
    ((SETTINGS_OK)) || { err "Settings file is invalid; fix $SETTINGS_DB first."; return 1; }
    settings_update --argjson id "$id" "$@" \
        '(if any(.[]; .id == $id) then . else . + [{id:$id,cvars:{},features:{},launch:{},custom:[]}] end) | map(if .id == $id then ('"$expr"') else . end)'
}
# copy DEFAULT settings into <id> (keeps the server's own GSLT token)
settings_clone_default() {
    ((SETTINGS_OK)) || return 1
    settings_update --argjson id "$1" '
        (first(.[] | select(.id == 0))) as $d
        | ((first(.[] | select(.id == $id))) // {}) as $old
        | map(select(.id != $id)) + [ ($d | del(.plugins) | .id = $id
            | .launch = ((($d.launch // {}) | del(.maxplayers, .map)) + (if $old.launch.gslt then {gslt: $old.launch.gslt} else {} end))) ]'
}

init_settings() {
    if [[ ! -e $SETTINGS_DB && ! -L $SETTINGS_DB ]]; then
        cat >"$SETTINGS_DB" <<'EOF'
[{"id":0,"cvars":{},"features":{"team_balance":"off","force_pick_time":"off"},"launch":{"maxplayers":13,"map":"de_dust2","game_type":0,"game_mode":1},"custom":[],"plugins":{"mode":"all","local":[]}}]
EOF
        chmod 600 "$SETTINGS_DB"
    fi
    if ! jq -e 'type=="array"' "$SETTINGS_DB" >/dev/null 2>&1; then
        SETTINGS_OK=0
        warn "$SETTINGS_DB is not a valid JSON array. Server settings are disabled until it is fixed."
    fi
}

# lines for the managed block of server.cfg (id 0 is never written to a cfg)
settings_cvar_keys() { st_get "$1" | jq -r '.cvars // {} | keys[]' 2>/dev/null; }

settings_cfg_lines() {
    local id=$1 entry k v t st cmd
    local -a parts
    ((SETTINGS_OK)) || return 0
    entry=$(st_get "$id"); [[ -n $entry ]] || return 0
    catalog_load
    # order matters (later lines win): quick options, then raw cvars, then custom lines
    for k in "${FT_KEYS[@]}"; do
        st=$(jq -r --arg k "$k" '.features[$k] // empty' <<<"$entry")
        case $st in
            on)  [[ ${FT_KIND[$k]} == persist ]] || continue; cmd=${FT_ON[$k]} ;;
            off) cmd=${FT_OFF[$k]} ;;
            *) continue ;;
        esac
        IFS=';' read -ra parts <<<"$cmd"
        printf '%s\n' "${parts[@]}"
    done
    while IFS=$'\t' read -r k v; do
        [[ -n $k ]] || continue
        t=${CAT_TYPE[$k]:-s}
        if [[ ${t%%:*} == s ]]; then printf '%s "%s"\n' "$k" "$v"; else printf '%s %s\n' "$k" "$v"; fi
    done < <(jq -r '.cvars // {} | to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$entry")
    jq -r '.custom // [] | .[]' <<<"$entry"
}

launch_value() {   # <id> <key> <default>
    local v
    v=$(st_get "$1" | jq -r --arg k "$2" '.launch[$k] // empty' 2>/dev/null)
    printf '%s' "${v:-$3}"
}

# ---------- GSLT token ----------
valid_gslt() { [[ $1 =~ ^[A-Za-z0-9]{16,64}$ ]]; }
gslt_in_use() { jq -e --argjson id "$1" --arg t "$2" 'any(.[]; .id != $id and .launch.gslt == $t)' "$SETTINGS_DB" >/dev/null 2>&1; }
# server_set_gslt <id> <token|''>: saves the token and rewrites server.cfg (sv_setsteamaccount "TOKEN")
server_set_gslt() {
    local id=$1 t=$2
    if [[ -z $t ]]; then
        st_update "$id" 'del(.launch.gslt)' >/dev/null || return 1
    else
        valid_gslt "$t" || { err "That does not look like a GSLT token (16-64 letters/digits)."; return 1; }
        if gslt_in_use "$id" "$t"; then
            warn "This token is already used by another server. Each CS2 server needs its OWN token."
            confirm_yn "Use it anyway? [y/N]: " n || return 1
        fi
        st_update "$id" '.launch.gslt = $v' --arg v "$t" >/dev/null || return 1
    fi
    if load_server "$id"; then write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$id" >/dev/null 2>&1; fi
    return 0
}

# ---------- create a server (shared by the menu and the setup wizard) ----------
CREATED_ID=""
create_server_core() {   # <name> <slug> <maxplayers> <port> <map>
    local name=$1 slug=$2 maxp=$3 port=$4 map=$5 id srv
    CREATED_ID=""
    id=$(db_next_id) || { err "Cannot read database."; return 1; }
    while is_running "$id"; do id=$((id + 1)); done
    srv="$SERVERS_DIR/$slug"
    safe_server_path "$srv" "$slug" || { err "Refusing unsafe path: $srv"; return 1; }
    [[ -e $srv || -L $srv ]] && { err "Directory $srv already exists."; return 1; }

    info "Creating server directory (symlinks for game files)..."
    mkdir -- "$srv" || { err "Cannot create $srv"; return 1; }
    if ! { sync_server_tree "$srv" \
        && seed_independent "$srv" \
        && write_server_cfg "$srv" "$name" "$maxp" "$port" \
        && chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$srv"; }; then
        err "Server creation failed. Cleaning up $srv"
        if safe_server_path "$srv" "$slug"; then rm -rf --one-file-system -- "$srv"; fi
        return 1
    fi
    if ! db_update --argjson id "$id" --arg name "$name" --arg slug "$slug" \
            --argjson port "$port" --argjson max "$maxp" --arg map "$map" --arg path "$srv" \
            '. += [{id:$id, name:$name, slug:$slug, port:$port, maxplayers:$max, map:$map, path:$path}]'; then
        err "Could not register server. Cleaning up $srv"
        if safe_server_path "$srv" "$slug"; then rm -rf --one-file-system -- "$srv"; fi
        return 1
    fi
    CREATED_ID=$id
    # new servers start with the DEFAULT settings
    if ((SETTINGS_OK)); then
        settings_clone_default "$id" && write_server_cfg "$srv" "$name" "$maxp" "$port" "$id"
    fi
    ok "Server '$name' registered (ID $id, $(du -sh --apparent-size -x "$srv" 2>/dev/null | cut -f1) incl. links)."
    if ((SHARED_OK)) && load_server "$id"; then
        info "Linking plugins..."
        DRY_RUN=0
        discover_shared_plugins
        sync_shared_current || warn "Some plugins were skipped (see above)."
    fi
    return 0
}

# ---------- UI ----------
st_entry_summary() { st_get "$1" | jq -r '[(.cvars|length), ([.features[]?|select(.=="on" or .=="off")]|length), (.custom|length)] | "\(.[0]) cvars, \(.[1]) quick options, \(.[2]) custom lines"' 2>/dev/null; }

settings_target_title() {
    if (($1 == 0)); then echo "DEFAULT SETTINGS (new servers)"; else load_server "$1" && echo "SETTINGS - $S_NAME (ID $1)"; fi
}

st_basics_ui() {   # <id>
    local id=$1 c v gt
    while :; do
        header "BASICS - $( ((id == 0)) && echo 'DEFAULT' || echo "$S_NAME")"
        if ((id == 0)); then
            printf '  1) Default client limit : %s\n' "$(launch_value 0 maxplayers 13)"
            printf '  2) Default start map    : %s\n' "$(map_label "$(launch_value 0 map de_dust2)")"
            echo   "  3) Back"
        else
            load_server "$id" || return
            printf '  1) Name         : %s\n' "$S_NAME"
            printf '  2) Port         : %s   (GOTV port defaults to %s)\n' "$S_PORT" "$((S_PORT + 5))"
            printf '  3) Client limit : %s\n' "$S_MAX"
            printf '  4) Start map    : %s\n' "$(map_label "$S_MAP")"
            printf '  5) GSLT token   : %s\n' "$([[ -n $(launch_value "$id" gslt "") ]] && echo '(set)' || echo '(not set)')"
            echo   "  6) Back"
            is_running "$id" && warn "Server is running: name/port/client/map/token changes apply after a restart."
        fi
        echo
        read -r -p "Select: " c || exit 0
        c=$(trim "$c")
        if ((id == 0)); then
            case $c in
                1) ask "Default client limit (1-$MAX_CLIENTS)" "$(launch_value 0 maxplayers 13)" || continue
                   [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= MAX_CLIENTS)) || { err "Invalid number."; sleep 1; continue; }
                   st_update 0 '.launch.maxplayers = ($v|tonumber)' --arg v "$((10#$ANSWER))" >/dev/null && ok "Saved." ;;
                2) ask "Default start map (name, or Workshop ID / link)" "$(launch_value 0 map de_dust2)" || continue
                   normalize_map "$ANSWER" || { err "Invalid map. Use a map name or a Workshop ID / link."; sleep 1; continue; }
                   st_update 0 '.launch.map = $v' --arg v "$MAP_NORM" >/dev/null && ok "Saved." ;;
                3|q|Q) return ;;
                *) err "Invalid option."; sleep 1; continue ;;
            esac
            sleep 1; continue
        fi
        case $c in
            1) ask "New server name" "$S_NAME" || continue
               v=$ANSWER
               [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9\ _.()-]{0,62}$ ]] || { err "Use 1-63 chars: letters, digits, space, _ . ( ) -"; sleep 1; continue; }
               if jq -e --argjson id "$id" --arg n "${v,,}" 'any(.[]; .id != $id and ((.name|ascii_downcase) == $n))' "$DB" >/dev/null; then
                   err "Another server already uses this name."; sleep 1; continue
               fi
               db_update --argjson id "$id" --arg v "$v" 'map(if .id == $id then .name = $v else . end)' && ok "Name changed (the folder stays the same)." ;;
            2) ask "New port ($MIN_PORT-$MAX_PORT)" "$S_PORT" || continue
               [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= MIN_PORT && 10#$ANSWER <= MAX_PORT)) || { err "Invalid port."; sleep 1; continue; }
               v=$((10#$ANSWER))
               if jq -e --argjson id "$id" --argjson p "$v" 'any(.[]; .id != $id and .port == $p)' "$DB" >/dev/null; then
                   err "Port $v is used by another server."; sleep 1; continue
               fi
               if ((v != S_PORT)) && port_in_use "$v"; then err "Port $v is in use on this machine."; sleep 1; continue; fi
               db_update --argjson id "$id" --argjson v "$v" 'map(if .id == $id then .port = $v else . end)' && ok "Port changed." ;;
            3) ask "New client limit (1-$MAX_CLIENTS)" "$S_MAX" || continue
               [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= MAX_CLIENTS)) || { err "Invalid number."; sleep 1; continue; }
               db_update --argjson id "$id" --argjson v "$((10#$ANSWER))" 'map(if .id == $id then .maxplayers = $v else . end)' && ok "Client limit changed." ;;
            4) ask "New start map (name, or Workshop ID / link)" "$S_MAP" || continue
               normalize_map "$ANSWER" || { err "Invalid map. Use a map name or a Workshop ID / link."; sleep 1; continue; }
               db_update --argjson id "$id" --arg v "$MAP_NORM" 'map(if .id == $id then .map = $v else . end)' && ok "Start map changed." ;;
            5) ask "GSLT token (type 'none' to remove)" || continue
               v=$ANSWER
               if [[ ${v,,} == none ]]; then server_set_gslt "$id" "" && ok "Token removed."
               else server_set_gslt "$id" "$v" && ok "Token saved in server.cfg (sv_setsteamaccount)."; fi ;;
            6|q|Q) return ;;
            *) err "Invalid option."; sleep 1; continue ;;
        esac
        load_server "$id" && write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$id" >/dev/null 2>&1
        sleep 1
    done
}

st_mode_ui() {   # <id>: game mode + round time
    local id=$1 c gt gm v
    local -a presets=("Casual|0|0" "Competitive|0|1" "Wingman|0|2" "Arms Race|1|0" "Demolition|1|1" "Deathmatch|1|2")
    while :; do
        header "GAME MODE & ROUND TIME"
        gt=$(launch_value "$id" game_type 0); gm=$(launch_value "$id" game_mode 1)
        printf '  Game mode  : game_type %s / game_mode %s\n' "$gt" "$gm"
        printf '  Round time : %s minutes (mp_roundtime)\n\n' "$(st_get "$id" | jq -r '.cvars.mp_roundtime // "game default"')"
        echo "  1) Game mode (applies after a restart)"
        echo "  2) Round time (minutes per round)"
        echo "  3) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1)
                local i=0 p
                for p in "${presets[@]}"; do i=$((i + 1)); printf '   %s) %s\n' "$i" "${p%%|*}"; done
                ask "Game mode number" || continue
                [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= ${#presets[@]})) || { err "Invalid choice."; sleep 1; continue; }
                p=${presets[$((10#$ANSWER - 1))]}; IFS='|' read -r _ gt gm <<<"$p"
                st_update "$id" '.launch.game_type = ($t|tonumber) | .launch.game_mode = ($m|tonumber)' --arg t "$gt" --arg m "$gm" >/dev/null && ok "Game mode saved."
                sleep 1 ;;
            2)
                ask "Minutes per round (0.5 - 60)" "1.92" || continue
                v=$ANSWER
                st_valid f "$v" || { sleep 1; continue; }
                if ! awk -v x="$v" 'BEGIN{exit !(x >= 0.5 && x <= 60)}'; then err "Choose between 0.5 and 60."; sleep 1; continue; fi
                st_update "$id" '.cvars.mp_roundtime = $v | .cvars.mp_roundtime_defuse = $v | .cvars.mp_roundtime_hostage = $v' --arg v "$v" >/dev/null \
                    && ok "Round time set to $v minutes (normal, defuse and hostage maps)."
                sleep 1 ;;
            3|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

st_quick_ui() {   # <id>
    local id=$1 c i k st label entry
    catalog_load
    while :; do
        header "QUICK OPTIONS - $( ((id == 0)) && echo 'DEFAULT' || echo "$S_NAME")"
        entry=$(st_get "$id")
        i=0
        for k in "${FT_KEYS[@]}"; do
            i=$((i + 1))
            if [[ ${FT_KIND[$k]} == oneshot ]]; then
                printf '  %2s) %-58s %s\n' "$i" "${FT_LABEL[$k]}" "[run once]"
                continue
            fi
            st=$(jq -r --arg k "$k" '.features[$k] // "--"' <<<"${entry:-{\}}")
            case $st in on) label="${GREEN}ON${RESET}" ;; off) label="${RED}OFF${RESET}" ;; *) label="--" ;; esac
            printf '  %2s) %-58s %s\n' "$i" "${FT_LABEL[$k]}" "$label"
        done
        echo "  ON/OFF write the commands into the server cfg. '--' leaves the game default."
        echo "  b) Back"
        echo
        read -r -p "Select: " c || exit 0
        c=$(trim "$c")
        [[ $c == b || $c == B || $c == q || $c == Q ]] && return
        if ! [[ $c =~ ^[0-9]+$ ]] || ((10#$c < 1 || 10#$c > ${#FT_KEYS[@]})); then err "Invalid option."; sleep 1; continue; fi
        k=${FT_KEYS[$((10#$c - 1))]}
        if [[ ${FT_KIND[$k]} == oneshot ]]; then
            if ((id == 0)); then warn "'${FT_LABEL[$k]}' is a one-time action and cannot be a default."; sleep 2; continue; fi
            if ! is_running "$id"; then warn "Start the server first; this runs a command once."; sleep 2; continue; fi
            confirm_yn "Run '${FT_ON[$k]}' on $S_NAME now? [y/N]: " n && console_send "$id" "${FT_ON[$k]}" && ok "Command sent."
            sleep 1; continue
        fi
        echo "  1) ON   2) OFF   3) Not set (game default)"
        read -r -p "  Choice: " c || exit 0
        case "$(trim "$c")" in
            1) st_update "$id" '.features[$k] = "on"'  --arg k "$k" >/dev/null ;;
            2) st_update "$id" '.features[$k] = "off"' --arg k "$k" >/dev/null ;;
            3) st_update "$id" 'del(.features[$k])'    --arg k "$k" >/dev/null ;;
            *) continue ;;
        esac
        if ((id > 0)) && load_server "$id"; then write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$id" >/dev/null 2>&1; fi
    done
}

st_cvars_ui() {   # <id>: all cvars by category
    local id=$1 c i k cat n entry v sel
    local -a list
    local -A CUR
    catalog_load
    while :; do
        header "CFG SETTINGS - $( ((id == 0)) && echo 'DEFAULT' || echo "$S_NAME")"
        i=0
        for cat in "${CAT_CATS[@]}"; do
            i=$((i + 1)); printf '  %2s) %s\n' "$i" "${cat//_/ }"
        done
        echo "   b) Back"
        echo
        read -r -p "Category: " c || exit 0
        c=$(trim "$c")
        [[ $c == b || $c == B || $c == q || $c == Q ]] && return
        if ! [[ $c =~ ^[0-9]+$ ]] || ((10#$c < 1 || 10#$c > ${#CAT_CATS[@]})); then err "Invalid option."; sleep 1; continue; fi
        cat=${CAT_CATS[$((10#$c - 1))]}
        while :; do
            header "${cat//_/ } - $( ((id == 0)) && echo 'DEFAULT' || echo "$S_NAME")"
            CUR=(); list=()
            while IFS=$'\t' read -r k v; do CUR[$k]=$v; done < <(st_get "$id" | jq -r '.cvars // {} | to_entries[] | [.key,(.value|tostring)] | @tsv' 2>/dev/null)
            n=0
            for k in "${CAT_KEYS[@]}"; do
                [[ ${CAT_CAT[$k]// /_} == "$cat" ]] || continue
                n=$((n + 1)); list+=("$k")
                printf '  %2s) %-36s %-14s %s\n' "$n" "$k" "${CUR[$k]:-(game default)}" "${CAT_DESC[$k]}"
            done
            echo "   b) Back        (raw cvars here override the Quick options)"
            echo
            read -r -p "Setting number: " sel || exit 0
            sel=$(trim "$sel")
            [[ $sel == b || $sel == B || $sel == q || $sel == Q ]] && break
            if ! [[ $sel =~ ^[0-9]+$ ]] || ((10#$sel < 1 || 10#$sel > n)); then err "Invalid option."; sleep 1; continue; fi
            k=${list[$((10#$sel - 1))]}
            echo
            echo "  $k: ${CAT_DESC[$k]}"
            case ${CAT_TYPE[$k]%%:*} in
                b) echo "  Values: 0 = off, 1 = on" ;;
                e) echo "  Values: ${CAT_TYPE[$k]#e:}" ;;
                *) echo "  Example/default: ${CAT_HINT[$k]}" ;;
            esac
            echo "  Enter a value, or 'unset' to go back to the game default."
            read -r -p "  Value: " v || exit 0
            v=$(trim "$v")
            [[ -z $v ]] && continue
            if [[ ${v,,} == unset ]]; then
                st_update "$id" 'del(.cvars[$k])' --arg k "$k" >/dev/null && ok "$k reset to the game default."
            else
                st_valid "${CAT_TYPE[$k]}" "$v" || { sleep 2; continue; }
                st_update "$id" '.cvars[$k] = $v' --arg k "$k" --arg v "$v" >/dev/null && ok "$k = $v"
            fi
            if ((id > 0)) && load_server "$id"; then write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$id" >/dev/null 2>&1; fi
            sleep 1
        done
    done
}

st_custom_ui() {   # <id>
    local id=$1 c i line
    while :; do
        header "CUSTOM CFG LINES - $( ((id == 0)) && echo 'DEFAULT' || echo "$S_NAME")"
        i=0
        while IFS= read -r line; do i=$((i + 1)); printf '  %2s) %s\n' "$i" "$line"; done < <(st_get "$id" | jq -r '.custom // [] | .[]' 2>/dev/null)
        ((i == 0)) && echo "  (none)"
        echo
        echo "  a) Add a line     r) Remove a line     b) Back"
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            a|A)
                ask "Line (any console command, e.g. mp_maxrounds 16)" || continue
                line=$ANSWER
                if [[ $line =~ [[:cntrl:]] || ${#line} -gt 200 ]]; then err "No control characters; max 200 characters."; sleep 1; continue; fi
                st_update "$id" '.custom = ((.custom // []) + [$l])' --arg l "$line" >/dev/null && ok "Line added." ;;
            r|R)
                ask "Line number to remove" || continue
                [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= i)) || { err "Invalid number."; sleep 1; continue; }
                st_update "$id" '.custom |= (to_entries | map(select(.key != $n)) | map(.value))' --argjson n "$((10#$ANSWER - 1))" >/dev/null && ok "Line removed." ;;
            b|B|q|Q) return ;;
            *) err "Invalid option."; sleep 1; continue ;;
        esac
        if ((id > 0)) && load_server "$id"; then write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$id" >/dev/null 2>&1; fi
        sleep 1
    done
}

st_view_ui() {   # <id>
    local id=$1
    header "GENERATED CFG - $( ((id == 0)) && echo 'DEFAULT' || echo "$S_NAME")"
    echo "These lines go into the CS2NEXUS block of server.cfg:"; sep
    if (($1 > 0)) && load_server "$1"; then
        echo "hostname \"$S_NAME\"   (unless overridden)"
        echo "sv_visiblemaxplayers $S_MAX   (unless overridden)"
        echo "tv_port $((S_PORT + 5))   (unless overridden)"
        echo "log on"; echo "sv_logfile 1"
    fi
    settings_cfg_lines "$1"
    sep
    printf 'Launch: game_type %s, game_mode %s\n' "$(launch_value "$1" game_type 0)" "$(launch_value "$1" game_mode 1)"
}

st_apply_ui() {   # <id>
    local id=$1 sid n=0
    if ((id == 0)); then
        warn "This REPLACES the settings of ALL existing servers with the DEFAULT settings (GSLT tokens are kept)."
        warn "Ports, names, client limits and maps are not touched."
        confirm_yn "Apply the defaults to every existing server? [y/N]: " n || { info "Cancelled."; return; }
        while IFS= read -r sid; do
            settings_clone_default "$sid" || continue
            load_server "$sid" && write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$sid" >/dev/null 2>&1
            n=$((n + 1))
        done < <(jq -r '.[].id' "$DB")
        ok "Defaults applied to $n server(s). Running servers pick them up with 'Apply now' or at the next map/restart."
        return
    fi
    load_server "$id" || return
    write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$id" || { err "Could not write server.cfg."; return; }
    ok "server.cfg updated."
    if is_running "$id"; then
        confirm_yn "Apply now on the running server (exec server.cfg)? [Y/n]: " y && console_send "$id" "exec server.cfg" && ok "Applied."
    fi
}

st_reset_ui() {   # <id>
    confirm_yn "Reset ALL settings of this server to the DEFAULT settings? [y/N]: " n || { info "Cancelled."; return; }
    settings_clone_default "$1" && load_server "$1" && write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$1" >/dev/null 2>&1 \
        && ok "Settings reset to the defaults."
}

settings_target_menu() {   # <id>
    local id=$1 c
    while :; do
        clear_screen; dsep
        printf '%s%s%s\n' "$BOLD" "  $(settings_target_title "$id")" "$RESET"
        dsep; echo
        ((id > 0)) && [[ -z $(st_get "$id") ]] && info "This server has no saved settings yet (its cfg is untouched until you change something)."
        echo "  Saved: $(st_entry_summary "$id" 2>/dev/null)"
        echo
        echo "  1) Basics (name, port, client limit, start map$( ((id > 0)) && echo ', GSLT'))"
        echo "  2) Game mode & round time"
        echo "  3) Quick options (bunny hop, team rules, all talk, ...)"
        echo "  4) CFG settings (every cvar, by category)"
        echo "  5) Custom cfg lines"
        echo "  6) View generated cfg"
        if ((id == 0)); then echo "  7) Apply the defaults to ALL existing servers"
        else echo "  7) Apply now (write cfg / exec on the running server)"; echo "  8) Reset this server to the defaults"; fi
        echo "  b) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) st_basics_ui "$id" ;;
            2) st_mode_ui "$id" ;;
            3) st_quick_ui "$id" ;;
            4) st_cvars_ui "$id" ;;
            5) st_custom_ui "$id" ;;
            6) st_view_ui "$id"; pause ;;
            7) st_apply_ui "$id"; pause ;;
            8) ((id > 0)) && { st_reset_ui "$id"; pause; } ;;
            b|B|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

settings_menu() {
    local c
    ((SETTINGS_OK)) || { err "Settings file is invalid: $SETTINGS_DB"; pause; return; }
    while :; do
        header "SERVER SETTINGS"
        echo "  0) DEFAULT - applied to every newly created server"
        if [[ $(db_count) -gt 0 ]]; then print_choices; fi
        echo; echo "  b) Back"
        echo
        read -r -p "Select a server (or 0 for the defaults): " c || exit 0
        c=$(trim "$c")
        [[ $c == b || $c == B || $c == q || $c == Q || -z $c ]] && return
        if [[ $c == 0 ]]; then settings_target_menu 0; continue; fi
        if ! [[ $c =~ ^[0-9]+$ ]] || ! load_server "$((10#$c))"; then err "Invalid server."; sleep 1; continue; fi
        settings_target_menu "$((10#$c))"
    done
}

# =============================================================================
#  PLUGINS: CS2Nexus browser, installer, auto-updater
# =============================================================================
declare -A NX_LABEL=() NX_KIND=() NX_URL=() NX_VER=()
NX_KEYS=()
NX_NOTE=""
STAGED_NAME=""
IDS_CSV="-"
DEFER_SYNC=0
PLUGIN_ARCHIVE_MAX_MB=400

valid_local_path() {
    local p=$1 c
    local -a comps
    [[ $p =~ ^[A-Za-z0-9._+@-]+(/[A-Za-z0-9._+@-]+)*$ ]] || return 1
    IFS=/ read -ra comps <<<"$p"
    for c in "${comps[@]}"; do [[ $c == . || $c == .. ]] && return 1; done
    return 0
}

# Plugin data that must stay per-server. AstraSkins keeps its sqlite database
# inside data/ next to static json catalogs, so only that file is per-server.
plugin_profile_local() {   # <name> -> csv | -
    local d
    case $1 in
        AstraSkins) echo "data/astra_skins.sqlite"; return ;;
    esac
    d=$(st_get 0 | jq -r '(.plugins.local // []) | join(",")' 2>/dev/null)
    echo "${d:--}"
}

# ---------- catalog ----------
nexus_catalog_load() {
    local json name type url sha base ext repo tag key
    NX_KEYS=(); NX_LABEL=(); NX_KIND=(); NX_URL=(); NX_VER=(); NX_NOTE=""
    json=$(gh_api "/repos/$NEXUS_REPO/contents/plugins?ref=$NEXUS_BRANCH" 2>/dev/null) || json=""
    if [[ -n $json ]] && jq -e 'type=="array"' <<<"$json" >/dev/null 2>&1; then
        while IFS=$'\t' read -r name type url sha; do
            [[ -n $name ]] || continue
            case $type in
                file)
                    case ${name,,} in
                        *.zip) ext=zip ;;
                        *.dll) ext=dll ;;
                        *) continue ;;
                    esac
                    base=${name%.*} ;;
                dir) ext=dir; base=$name ;;
                *) continue ;;
            esac
            valid_simple_name "$base" || continue
            key="nexus:$base"
            NX_KEYS+=("$key"); NX_LABEL[$key]=$base; NX_KIND[$key]=$ext; NX_URL[$key]=$url; NX_VER[$key]=$sha
        done < <(jq -r '.[] | [.name, .type, (.download_url // .url // ""), (.sha // "")] | @tsv' <<<"$json")
    else
        NX_NOTE="The plugins folder of github.com/$NEXUS_REPO could not be read (folder missing, private repo, offline or rate limit)."
    fi
    for repo in ${EXTRA_PLUGIN_REPOS//,/ }; do
        json=$(gh_api "/repos/$repo/releases/latest" 2>/dev/null) || continue
        IFS=$'\t' read -r tag _ url < <(jq -r '[ (.tag_name // ""), ((.assets // []) | map(select(.name | test("\\.zip$"; "i"))) | .[0] | (.name // ""), (.browser_download_url // "")) ] | @tsv' <<<"$json")
        [[ -n $tag && -n $url ]] || continue
        base=${repo#*/}
        valid_simple_name "$base" || continue
        key="release:$repo"
        NX_KEYS+=("$key"); NX_LABEL[$key]=$base; NX_KIND[$key]=zip; NX_URL[$key]=$url; NX_VER[$key]=$tag
    done
    ((${#NX_KEYS[@]} > 0))
}

nexus_download_dir() {   # <contents-api-url> <dest> <depth>
    local url=$1 dest=$2 depth=${3:-0} json name type dl
    ((depth <= 6)) || { err "Plugin folder is nested too deeply."; return 1; }
    json=$(gh_curl "$url") || return 1
    jq -e 'type=="array"' <<<"$json" >/dev/null 2>&1 || return 1
    mkdir -p -- "$dest"
    while IFS=$'\t' read -r name type dl; do
        if ! valid_simple_name "$name"; then warn "Skipping '$name' (unsupported file name)."; continue; fi
        case $type in
            file) gh_curl "$dl" -o "$dest/$name" || return 1 ;;
            dir)  nexus_download_dir "$dl" "$dest/$name" $((depth + 1)) || return 1 ;;
        esac
    done < <(jq -r '.[] | [.name, .type, (.download_url // .url // "")] | @tsv' <<<"$json")
}

# Turn an extracted package into <stage>/plugin/<Name>/ (+ <stage>/extras/counterstrikesharp/...)
nexus_normalise() {   # <extracted-dir> <stage> <label>
    local x=$1 stage=$2 label=$3 pdir="" d b
    local -a names top
    rm -rf --one-file-system -- "$stage/plugin" "$stage/extras"
    mkdir -p -- "$stage/plugin" "$stage/extras"
    rm -rf --one-file-system -- "$x/__MACOSX"
    for d in "$x/addons/counterstrikesharp/plugins" "$x/counterstrikesharp/plugins"; do
        [[ -d $d ]] && { pdir=$d; break; }
    done
    if [[ -n $pdir ]]; then
        mapfile -t names < <(find "$pdir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
        if ((${#names[@]} != 1)); then err "The package must contain exactly one plugin folder (found ${#names[@]})."; return 1; fi
        STAGED_NAME=${names[0]}
        mv -- "$pdir/$STAGED_NAME" "$stage/plugin/$STAGED_NAME" || return 1
        for d in gamedata configs shared; do
            for b in "$x/addons/counterstrikesharp/$d" "$x/counterstrikesharp/$d"; do
                if [[ -d $b ]]; then
                    mkdir -p -- "$stage/extras/counterstrikesharp"
                    cp -a -- "$b" "$stage/extras/counterstrikesharp/$d" || return 1
                fi
            done
        done
        return 0
    fi
    mapfile -t top < <(find "$x" -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -v '^\.')
    if ((${#top[@]} == 1)) && [[ -d $x/${top[0]} ]]; then
        STAGED_NAME=${top[0]}
        mv -- "$x/$STAGED_NAME" "$stage/plugin/$STAGED_NAME" || return 1
    elif ((${#top[@]} >= 1)); then
        STAGED_NAME=$label
        mkdir -p -- "$stage/plugin/$label"
        cp -a -- "$x"/. "$stage/plugin/$label/" || return 1
    else
        err "The package is empty."; return 1
    fi
    return 0
}

nexus_fetch_stage() {   # <key> <stage>
    local key=$1 stage=$2 kind url label raw mb
    kind=${NX_KIND[$key]}; url=${NX_URL[$key]}; label=${NX_LABEL[$key]}
    raw="$stage/raw"
    rm -rf --one-file-system -- "$raw"; mkdir -p -- "$raw"
    STAGED_NAME=""
    case $kind in
        dll)
            gh_curl "$url" -o "$raw/$label.dll" || { gh_hint; return 1; }
            rm -rf --one-file-system -- "$stage/plugin" "$stage/extras"
            mkdir -p -- "$stage/plugin/$label" "$stage/extras"
            mv -- "$raw/$label.dll" "$stage/plugin/$label/$label.dll" || return 1
            STAGED_NAME=$label ;;
        zip)
            gh_curl "$url" -o "$raw/pkg.zip" || { gh_hint; return 1; }
            mkdir -p -- "$raw/x"
            unzip -qo "$raw/pkg.zip" -d "$raw/x" || { err "The archive could not be extracted."; return 1; }
            nexus_normalise "$raw/x" "$stage" "$label" || return 1 ;;
        dir)
            nexus_download_dir "$url" "$raw/x" 0 || { gh_hint; return 1; }
            nexus_normalise "$raw/x" "$stage" "$label" || return 1 ;;
        *) err "Unknown package type '$kind'."; return 1 ;;
    esac
    valid_simple_name "$STAGED_NAME" || { err "Unsupported plugin folder name '$STAGED_NAME'."; return 1; }
    if [[ -n $(find "$stage/plugin" "$stage/extras" -type l -print -quit 2>/dev/null) ]]; then
        err "The package contains symlinks; refusing to install it."; return 1
    fi
    mb=$(du -sm "$stage/plugin" "$stage/extras" 2>/dev/null | awk '{s+=$1} END{print s+0}')
    if ((mb > PLUGIN_ARCHIVE_MAX_MB)); then err "The package is larger than ${PLUGIN_ARCHIVE_MAX_MB} MB; refusing."; return 1; fi
    return 0
}

# per-server copies of plugin-provided configs/gamedata: only files that do not exist yet
seed_extras() {   # <stage>
    local stage=$1 f rel id dst base n=0
    [[ -d $stage/extras ]] || return 0
    need_layout || return 1
    while IFS= read -r -d '' f; do
        rel=${f#"$stage/extras/"}
        [[ $rel =~ ^counterstrikesharp/(gamedata|configs|shared)/ ]] || continue
        [[ $rel =~ ^[A-Za-z0-9._+@/-]+$ && $rel != *..* ]] || continue
        while IFS= read -r id; do
            load_server "$id" || continue
            safe_server_path "$S_PATH" "$S_SLUG" || continue
            base="$S_PATH/$CSGOREL"
            [[ -d $base && ! -L $base ]] || continue
            dst="$base/addons/$rel"
            [[ -e $dst || -L $dst ]] && continue
            ensure_chain "$base" "$(dirname -- "$dst")" || continue
            if cp -- "$f" "$dst"; then chown -h "$CS2_USER:$CS2_GROUP" -- "$dst"; n=$((n + 1)); fi
        done < <(jq -r '.[].id' "$DB")
    done < <(find "$stage/extras" -type f -print0)
    ((n > 0)) && info "Seeded $n plugin config/gamedata file(s) on the servers (existing files were kept)."
    return 0
}

# ---------- options prompts ----------
prompt_server_ids() {   # <prompt> <default csv|-> <required 0|1>  -> IDS_CSV
    local prompt=$1 def=$2 req=$3 in x bad
    local -a arr clean
    [[ $def == "-" ]] && def=""
    echo; print_choices; echo
    while :; do
        ask "$prompt (server IDs, comma separated)" "$def" || return 1
        in=${ANSWER//[[:space:]]/}
        IFS=, read -ra arr <<<"$in"
        clean=(); bad=0
        for x in "${arr[@]}"; do
            [[ -z $x ]] && continue
            if [[ $x =~ ^[0-9]+$ ]] && jq -e --argjson i "$((10#$x))" 'any(.[]; .id == $i)' "$DB" >/dev/null 2>&1; then
                clean+=("$((10#$x))")
            else
                err "Unknown server ID: $x"; bad=1
            fi
        done
        ((bad)) && continue
        if ((req && ${#clean[@]} == 0)); then err "Select at least one server."; continue; fi
        IDS_CSV=$(printf '%s\n' "${clean[@]}" | awk 'NF && !s[$0]++' | paste -sd, -)
        [[ -z $IDS_CSV ]] && IDS_CSV="-"
        return 0
    done
}

# prompt_plugin_options <def-local|-> <def-exclude|-> <def-include|->
#   -> OPT_LOCAL_CSV / OPT_EXCL_CSV / OPT_INCL_CSV
prompt_plugin_options() {
    local defl=$1 defx=$2 defi=$3 in x bad cur
    local -a arr clean
    [[ $defl == "-" ]] && defl=""
    echo
    info "Per-server items: files/folders inside the plugin that must stay REAL per-server files"
    info "(e.g. a database like data/astra_skins.sqlite). Everything else is shared. Enter 'none' for nothing."
    while :; do
        ask "Per-server items (comma separated)" "$defl" || return 1
        in=${ANSWER//[[:space:]]/}
        [[ ${in,,} == none ]] && in=""
        IFS=, read -ra arr <<<"$in"
        clean=(); bad=0
        for x in "${arr[@]}"; do
            [[ -z $x ]] && continue
            if valid_local_path "$x"; then clean+=("$x"); else err "Invalid path: $x"; bad=1; fi
        done
        ((bad)) && continue
        OPT_LOCAL_CSV=$(printf '%s\n' "${clean[@]}" | awk 'NF && !s[$0]++' | paste -sd, -)
        [[ -z $OPT_LOCAL_CSV ]] && OPT_LOCAL_CSV="-"
        break
    done
    OPT_EXCL_CSV="-"; OPT_INCL_CSV="-"
    cur=1; [[ $defi != "-" ]] && cur=2; [[ $defx != "-" ]] && cur=3
    echo
    echo "  Install this plugin on:"
    echo "    1) Default - all servers (including servers created later)"
    echo "    2) Selected servers only"
    echo "    3) All servers except some"
    while :; do
        ask "Choice" "$cur" || return 1
        case $ANSWER in
            1) return 0 ;;
            2) prompt_server_ids "Servers that get this plugin" "$defi" 1 || return 1; OPT_INCL_CSV=$IDS_CSV; return 0 ;;
            3) prompt_server_ids "Servers that must NOT get it" "$defx" 1 || return 1; OPT_EXCL_CSV=$IDS_CSV; return 0 ;;
            *) err "Enter 1, 2 or 3." ;;
        esac
    done
}

# ---------- install / update ----------
plugin_backup_old() {   # <name> <src>
    local name=$1 src=$2 ts f
    local -a all
    install -d -m 755 -- "$PLUGIN_BACKUP_DIR" || return 1
    ts=$(date +%Y%m%d-%H%M%S)
    tar -czf "$PLUGIN_BACKUP_DIR/$name-$ts.tar.gz" -C "$(dirname -- "$src")" "$name" 2>/dev/null || return 1
    mapfile -t all < <(find "$PLUGIN_BACKUP_DIR" -maxdepth 1 -type f -name "$name-*.tar.gz" | sort)
    if ((${#all[@]} > PLUGIN_BACKUP_KEEP)); then
        for f in "${all[@]:0:${#all[@]}-PLUGIN_BACKUP_KEEP}"; do rm -f -- "$f"; done
    fi
    return 0
}

# plugin_install_staged <key> <stage> <interactive 0|1>   (uses STAGED_NAME)
plugin_install_staged() {
    local key=$1 stage=$2 inter=${3:-1} name rel src new old existing=0 ver prof mode
    name=$STAGED_NAME; ver=${NX_VER[$key]:-}
    rel="counterstrikesharp/plugins/$name"; src=$(plugin_src_path "$rel")
    shared_path_ok "$src" || { err "Unsafe shared path for '$name'."; return 1; }
    shared_db_ok || return 1
    need_layout || return 1
    lock_ops 30 || return 1
    if jq -e --arg p "$rel" 'any(.[]; type=="object" and .path == $p)' "$SHARED_DB" >/dev/null 2>&1; then existing=1; fi

    if ((existing)); then
        plugin_backup_old "$name" "$src" || warn "Could not back up the old version of $name."
        new="$src.mgr-new.$$"; old="$src.mgr-old.$$"
        if ! { cp -a -- "$stage/plugin/$name" "$new" && chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$new"; }; then
            err "Copy failed."; rm -rf --one-file-system -- "$new"; unlock_ops; return 1
        fi
        if [[ -e $src ]] && ! mv -T -- "$src" "$old"; then
            err "Could not replace $name."; rm -rf --one-file-system -- "$new"; unlock_ops; return 1
        fi
        if ! mv -T -- "$new" "$src"; then
            err "Could not put the new version in place; restoring the old one."
            [[ -e $old ]] && mv -T -- "$old" "$src"
            unlock_ops; return 1
        fi
        if [[ -e $old ]] && shared_path_ok "$old"; then rm -rf --one-file-system -- "$old"; fi
        shared_update --arg p "$rel" --arg s "$key" --arg v "$ver" \
            'map(if .path == $p then .source = $s | .version = $v else . end)' >/dev/null
        ok "$name updated (version $ver)."
    else
        if [[ -e $src || -L $src ]]; then
            err "A folder named '$name' already exists in the shared folder but is not registered. Remove or rename it first."
            unlock_ops; return 1
        fi
        prof=$(plugin_profile_local "$name")
        mode=$(st_get 0 | jq -r '.plugins.mode // "ask"' 2>/dev/null)
        OPT_LOCAL_CSV=$prof; OPT_EXCL_CSV="-"; OPT_INCL_CSV="-"
        if ((inter)) && [[ $mode != all ]]; then
            info "Where should '$name' be installed?"
            prompt_plugin_options "$prof" "-" "-" || { info "Cancelled."; unlock_ops; return 1; }
        fi
        if ! { ensure_chain "$SHARED_ADDONS" "$(dirname -- "$src")" \
            && cp -a -- "$stage/plugin/$name" "$src" \
            && chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$src"; }; then
            err "Could not copy '$name' into shared storage."
            shared_path_ok "$src" && rm -rf --one-file-system -- "$src"
            unlock_ops; return 1
        fi
        if ! shared_update --arg n "$name" --arg p "$rel" --arg s "$key" --arg v "$ver" \
            --argjson l "$(json_from_csv "$OPT_LOCAL_CSV" strings)" \
            --argjson x "$(json_from_csv "$OPT_EXCL_CSV" numbers)" \
            --argjson i "$(json_from_csv "$OPT_INCL_CSV" numbers)" \
            '. += [{name:$n, path:$p, source:$s, version:$v}
                   + (if ($l|length) > 0 then {local:$l} else {} end)
                   + (if ($x|length) > 0 then {exclude:$x} else {} end)
                   + (if ($i|length) > 0 then {include:$i} else {} end)]'; then
            err "Could not register '$name'."
            shared_path_ok "$src" && rm -rf --one-file-system -- "$src"
            unlock_ops; return 1
        fi
        ok "Plugin '$name' installed."
    fi
    seed_extras "$stage"
    if ! ((DEFER_SYNC)); then
        DRY_RUN=0
        sync_shared_all || warn "Some servers were skipped (see above); nothing was overwritten."
    fi
    unlock_ops
    return 0
}

plugin_install_key() {   # <key> <interactive>
    local key=$1 inter=${2:-1} stage rc=1
    stage=$(mktemp -d /tmp/cs2nexus.XXXXXX) || return 1
    info "Downloading ${NX_LABEL[$key]} ..."
    if nexus_fetch_stage "$key" "$stage"; then
        plugin_install_staged "$key" "$stage" "$inter"; rc=$?
    fi
    rm -rf --one-file-system -- "$stage"
    return $rc
}

install_default_plugins() {
    local want key found n=0
    info "Loading the plugin list from github.com/$NEXUS_REPO ..."
    if ! nexus_catalog_load; then warn "${NX_NOTE:-No plugins available.} Install them later from Plugins -> Plugin Browser."; return 0; fi
    for want in ServerCommands MapVote Parachute AstraSkins; do
        found=""
        for key in "${NX_KEYS[@]}"; do [[ ${NX_LABEL[$key],,} == "${want,,}" ]] && { found=$key; break; }; done
        if [[ -z $found ]]; then warn "$want is not available in the plugin catalog yet."; continue; fi
        plugin_install_key "$found" 0 && n=$((n + 1))
    done
    info "$n default plugin(s) installed."
}

plugin_post_update_action() {   # <names...>
    local id n
    [[ $UPDATE_ACTION == reload ]] || { info "Updated plugins are used after the next map change / restart of each server."; return 0; }
    while IFS= read -r id; do
        load_server "$id" || continue
        is_running "$id" || continue
        for n in "$@"; do console_send "$id" "css_plugins reload $n" && ok "$S_NAME: reload requested for $n (best effort)."; done
    done < <(jq -r '.[].id' "$DB")
}

plugins_update_run() {   # <quiet 0|1>
    local path source ver key name stage checked=0 updated=0 failed=0
    local -a names=()
    shared_db_ok || return 1
    if ! lock_ops 0; then info "Manager busy; plugin update skipped."; return 0; fi
    if ! nexus_catalog_load; then
        ((${1:-0})) || warn "${NX_NOTE:-No plugin sources reachable.}"
        unlock_ops; return 1
    fi
    DEFER_SYNC=1
    while IFS=$'\t' read -r path source ver; do
        key=$source
        name=${path##*/}
        if [[ -z ${NX_VER[$key]+x} ]]; then warn "$name: no longer available from its source; skipped."; continue; fi
        checked=$((checked + 1))
        [[ ${NX_VER[$key]} == "$ver" ]] && continue
        info "Updating $name ..."
        stage=$(mktemp -d /tmp/cs2nexus.XXXXXX) || { failed=$((failed + 1)); continue; }
        if nexus_fetch_stage "$key" "$stage" && [[ $STAGED_NAME == "$name" ]] && plugin_install_staged "$key" "$stage" 0; then
            updated=$((updated + 1)); names+=("$name")
        else
            [[ $STAGED_NAME != "$name" && -n $STAGED_NAME ]] && err "$name: the new package contains '$STAGED_NAME' instead; not installed."
            failed=$((failed + 1))
        fi
        rm -rf --one-file-system -- "$stage"
    done < <(jq -r '.[] | select(type=="object" and ((.source // "") != "")) | [.path, .source, (.version // "")] | @tsv' "$SHARED_DB")
    DEFER_SYNC=0
    if ((updated > 0)); then
        DRY_RUN=0
        sync_shared_all || warn "Some servers were skipped (see above); nothing was overwritten."
        plugin_post_update_action "${names[@]}"
    fi
    if ((${1:-0} == 0 || updated > 0 || failed > 0)); then
        info "Plugin update finished: $checked checked, $updated updated, $failed failed."
    fi
    unlock_ops
    ((failed == 0))
}

# ---------- auto-update timer ----------
plugin_autoupdate_enable() {
    command -v systemctl >/dev/null 2>&1 || { err "systemctl is not available."; return 1; }
    cat >"/etc/systemd/system/$PLUGIN_TIMER_UNIT.service" <<EOF
[Unit]
Description=CS2Nexus plugin auto-update
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF plugin-update
EOF
    cat >"/etc/systemd/system/$PLUGIN_TIMER_UNIT.timer" <<EOF
[Unit]
Description=Check for CS2Nexus plugin updates every 30 minutes

[Timer]
OnActiveSec=2min
OnUnitActiveSec=30min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
    if systemctl daemon-reload && systemctl enable --now "$PLUGIN_TIMER_UNIT.timer" >/dev/null 2>&1; then
        conf_set AUTOUPDATE 1
        ok "Plugin auto-update enabled (checks every 30 minutes)."
    else
        err "Could not enable the auto-update timer."; return 1
    fi
}

plugin_autoupdate_disable() {
    command -v systemctl >/dev/null 2>&1 && systemctl disable --now "$PLUGIN_TIMER_UNIT.timer" >/dev/null 2>&1
    rm -f -- "/etc/systemd/system/$PLUGIN_TIMER_UNIT.service" "/etc/systemd/system/$PLUGIN_TIMER_UNIT.timer"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    conf_set AUTOUPDATE 0
    ok "Plugin auto-update disabled."
}

plugin_autoupdate_ui() {
    local c
    while :; do
        header "PLUGIN AUTO-UPDATE"
        printf '  Auto-update      : %s\n' "$( ((AUTOUPDATE)) && echo "${GREEN}ENABLED${RESET} (every 30 minutes)" || echo "${RED}disabled${RESET}")"
        printf '  After an update  : %s\n\n' "$([[ $UPDATE_ACTION == reload ]] && echo 'ask running servers to reload the plugin (css_plugins reload, best effort)' || echo 'files only; used after the next map change / restart')"
        echo "  Plugins installed from the Plugin Browser are updated automatically when the"
        echo "  file or release in the GitHub source changes (old versions are backed up)."
        echo
        echo "  1) $( ((AUTOUPDATE)) && echo Disable || echo Enable) auto-update"
        echo "  2) Change the action after an update"
        echo "  3) Check for updates now"
        echo "  4) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) if ((AUTOUPDATE)); then plugin_autoupdate_disable; else plugin_autoupdate_enable; fi; pause ;;
            2) if [[ $UPDATE_ACTION == reload ]]; then conf_set UPDATE_ACTION none; else conf_set UPDATE_ACTION reload; fi ;;
            3) plugins_update_run 0; pause ;;
            4|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ---------- browser ----------
plugin_browser_ui() {
    header "PLUGIN BROWSER"
    shared_db_ok || return
    info "Loading plugins from github.com/$NEXUS_REPO ..."
    if ! nexus_catalog_load; then warn "${NX_NOTE:-No plugins found.}"; gh_hint; return; fi
    local -a sel=()
    local c i key state iv tok n s found
    while :; do
        header "PLUGIN BROWSER"
        i=0
        for key in "${NX_KEYS[@]}"; do
            i=$((i + 1))
            iv=$(jq -r --arg s "$key" '[.[] | select(type=="object" and .source == $s) | .version][0] // empty' "$SHARED_DB" 2>/dev/null)
            if [[ -z $iv ]]; then state="not installed"
            elif [[ $iv == "${NX_VER[$key]}" ]]; then state="${GREEN}installed${RESET}"
            else state="${YELLOW}update available${RESET}"; fi
            s=" "; for n in "${sel[@]}"; do [[ $n == "$key" ]] && s="x"; done
            printf '  [%s] %2s) %-26s %-7s %s\n' "$s" "$i" "${NX_LABEL[$key]}" "${NX_KIND[$key]}" "$state"
        done
        echo
        echo "  Type numbers (e.g. 1 3) to select/unselect, a = all, c = clear,"
        echo "  i = INSTALL / update the selected plugins, b = back"
        read -r -p "Select: " c || exit 0
        c=$(trim "$c")
        case $c in
            b|B|q|Q) return ;;
            a|A) sel=("${NX_KEYS[@]}"); continue ;;
            c|C) sel=(); continue ;;
            i|I)
                if ((${#sel[@]} == 0)); then err "Nothing selected."; sleep 1; continue; fi
                for key in "${sel[@]}"; do
                    echo; sep
                    plugin_install_key "$key" 1 || warn "${NX_LABEL[$key]} was not installed."
                done
                echo; info "Back in the Plugins section. Use 'Change plugin assignment' to move a plugin between Default and single servers."
                return ;;
        esac
        for tok in $c; do
            if [[ $tok =~ ^[0-9]+$ ]] && ((10#$tok >= 1 && 10#$tok <= ${#NX_KEYS[@]})); then
                key=${NX_KEYS[$((10#$tok - 1))]}; found=0; local -a ns=()
                for n in "${sel[@]}"; do if [[ $n == "$key" ]]; then found=1; else ns+=("$n"); fi; done
                if ((found)); then sel=("${ns[@]}"); else sel+=("$key"); fi
            fi
        done
    done
}

plugin_edit_registry() {   # <rel>
    local rel=$1 P_NAME P_PATH P_LOCAL P_EXCL P_INCL found=0 cl="-" cx="-" ci="-"
    while IFS=$'\t' read -r P_NAME P_PATH P_LOCAL P_EXCL P_INCL; do
        if [[ $P_PATH == "$rel" ]]; then found=1; cl=$P_LOCAL; cx=$P_EXCL; ci=$P_INCL; fi
    done < <(plugins_rows)
    ((found)) || { err "That plugin is not registered."; return 1; }
    prompt_plugin_options "$cl" "$cx" "$ci" || { info "Cancelled."; return 1; }
    warn "If per-server items changed, data already inside the shared copy is NOT moved automatically."
    lock_ops 30 || return 1
    if shared_update --arg p "$rel" \
        --argjson l "$(json_from_csv "$OPT_LOCAL_CSV" strings)" \
        --argjson x "$(json_from_csv "$OPT_EXCL_CSV" numbers)" \
        --argjson i "$(json_from_csv "$OPT_INCL_CSV" numbers)" \
        'map(if .path == $p then (del(.local, .exclude, .include)
             + (if ($l|length) > 0 then {local:$l} else {} end)
             + (if ($x|length) > 0 then {exclude:$x} else {} end)
             + (if ($i|length) > 0 then {include:$i} else {} end)) else . end)'; then
        ok "Plugin settings saved."
        DRY_RUN=0; sync_shared_all
    fi
    unlock_ops
}

plugin_assign_ui() {
    header "CHANGE PLUGIN ASSIGNMENT"
    shared_db_ok || return
    local total i=0 idx P_NAME P_PATH P_LOCAL P_EXCL P_INCL
    local -a paths=()
    total=$(jq 'length' "$SHARED_DB")
    if ((total == 0)); then warn "No plugins installed."; return; fi
    while IFS=$'\t' read -r P_NAME P_PATH P_LOCAL P_EXCL P_INCL; do
        i=$((i + 1)); paths[i]=$P_PATH
        printf '%s) %-22s servers: %s\n' "$i" "$P_NAME" \
            "$([[ $P_INCL != - ]] && echo "only $P_INCL" || { [[ $P_EXCL != - ]] && echo "all except $P_EXCL" || echo 'all (default)'; })"
    done < <(plugins_rows)
    echo
    ask "Plugin number (q = cancel)" || { info "Cancelled."; return; }
    [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= i)) || { err "Invalid selection."; return; }
    idx=$((10#$ANSWER))
    validate_plugin_rel "${paths[idx]}" || return
    plugin_edit_registry "$PLUGIN_REL"
}

plugin_defaults_ui() {
    local c mode loc
    while :; do
        header "DEFAULT PLUGIN OPTIONS"
        mode=$(st_get 0 | jq -r '.plugins.mode // "ask"' 2>/dev/null)
        loc=$(st_get 0 | jq -r '(.plugins.local // []) | join(",")' 2>/dev/null)
        printf '  Newly installed plugins : %s\n' "$([[ $mode == all ]] && echo 'go to ALL servers automatically (Default)' || echo 'ask where to install each time')"
        printf '  Default per-server items: %s\n\n' "${loc:-none}"
        echo "  1) Switch between 'install to all servers' and 'ask every time'"
        echo "  2) Set the default per-server items (used when a plugin has no built-in profile)"
        echo "  3) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) if [[ $mode == all ]]; then st_update 0 '.plugins.mode = "ask"' >/dev/null; else st_update 0 '.plugins.mode = "all"' >/dev/null; fi ;;
            2) local in x bad=0 out
               local -a arr clean=()
               ask "Per-server items (comma separated, 'none' for nothing)" "${loc:-none}" || continue
               in=${ANSWER//[[:space:]]/}; [[ ${in,,} == none ]] && in=""
               IFS=, read -ra arr <<<"$in"
               for x in "${arr[@]}"; do
                   [[ -z $x ]] && continue
                   if valid_local_path "$x"; then clean+=("$x"); else err "Invalid path: $x"; bad=1; fi
               done
               ((bad)) && { sleep 1; continue; }
               out=$(printf '%s\n' "${clean[@]}" | awk 'NF && !s[$0]++' | paste -sd, -)
               st_update 0 '.plugins.local = (if $s == "" then [] else ($s | split(",")) end)' --arg s "$out" >/dev/null && ok "Saved." ;;
            3|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

plugins_menu() {
    local c pre
    while :; do
        clear_screen
        dsep
        printf '%s                PLUGINS%s\n' "$BOLD" "$RESET"
        dsep
        echo
        echo "Drop folders (plugins placed here are installed on the servers automatically):"
        for pre in "${PLUGIN_PREFIXES[@]}"; do echo "  $SHARED_ADDONS/$pre/"; done
        echo
        echo " 1) Plugin Browser (CS2Nexus)"
        echo " 2) Installed plugins"
        echo " 3) Change plugin assignment (Default / single servers)"
        echo " 4) Add plugin manually"
        echo " 5) Remove plugin"
        echo " 6) Update plugins now"
        echo " 7) Auto-update"
        echo " 8) Sync all servers (also registers plugins from the drop folders)"
        echo " 9) Sync all servers (dry-run)"
        echo "10) Default plugin options"
        echo "11) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) plugin_browser_ui;     pause ;;
            2) shared_list_ui;        pause ;;
            3) plugin_assign_ui;      pause ;;
            4) shared_add_ui;         pause ;;
            5) shared_remove_ui;      pause ;;
            6) header "UPDATE PLUGINS"; plugins_update_run 0; pause ;;
            7) plugin_autoupdate_ui ;;
            8) shared_sync_ui 0;      pause ;;
            9) shared_sync_ui 1;      pause ;;
            10) plugin_defaults_ui ;;
            11|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  LAUNCHER SELF-UPDATE, LAUNCHER SETTINGS
# =============================================================================
LAUNCHER_FILE=""; LAUNCHER_URL=""

launcher_remote() {
    local json row
    json=$(gh_api "/repos/$NEXUS_REPO/contents/launcher?ref=$NEXUS_BRANCH" 2>/dev/null) || return 1
    jq -e 'type=="array"' <<<"$json" >/dev/null 2>&1 || return 1
    row=$(jq -r '[.[] | select(.type == "file")] as $f
        | (($f | map(select(.name == "server-cs2.sh"))[0]) // ($f | map(select(.name == "cs2nexus.sh"))[0]) // ($f | map(select(.name | test("\\.sh$")))[0]))
        | select(. != null) | [.name, (.download_url // ""), (.sha // "")] | @tsv' <<<"$json")
    [[ -n $row ]] || return 1
    IFS=$'\t' read -r LAUNCHER_FILE LAUNCHER_URL _ <<<"$row"
    [[ -n $LAUNCHER_URL ]]
}

update_launcher_ui() {
    header "UPDATE LAUNCHER"
    local tmp new id secs=0 ts f stop_fail=0
    local -a running=() ids baks
    info "Checking github.com/$NEXUS_REPO (launcher folder)..."
    if ! launcher_remote; then
        warn "No launcher script was found in the 'launcher' folder of $NEXUS_REPO (folder missing, private repo, offline or rate limit)."
        gh_hint; return
    fi
    tmp=$(mktemp -d /tmp/cs2nexus.XXXXXX) || { err "mktemp failed"; return; }
    new="$tmp/launcher.sh"
    if ! gh_curl "$LAUNCHER_URL" -o "$new"; then gh_hint; rm -rf --one-file-system -- "$tmp"; return; fi
    if [[ $(head -c 2 "$new") != '#!' ]] || ! grep -q 'CS2NEXUS-LAUNCHER' "$new" \
        || [[ $(wc -c <"$new") -lt 10000 ]] || ! bash -n "$new" 2>/dev/null; then
        err "The downloaded file is not a valid CS2Nexus launcher (marker/syntax check failed). Nothing was changed."
        rm -rf --one-file-system -- "$tmp"; return
    fi
    if cmp -s "$new" "$SELF"; then
        ok "The launcher is already up to date ($LAUNCHER_FILE)."
        rm -rf --one-file-system -- "$tmp"; return
    fi
    echo
    printf '  Current launcher : %s lines\n' "$(wc -l <"$SELF")"
    printf '  New launcher     : %s lines (%s)\n\n' "$(wc -l <"$new")" "$LAUNCHER_FILE"
    mapfile -t ids < <(jq -r '.[].id' "$DB")
    for id in "${ids[@]}"; do is_running "$id" && running+=("$id"); done
    warn "The launcher will close and open again. ${#running[@]} running server(s) are stopped and started again (full restart)."
    warn "The script is downloaded from GitHub and runs as root: only use a repository you control."
    if ((${#running[@]})); then
        ask "Warn players and wait how many seconds before stopping (0-600)" 60 || { info "Cancelled."; rm -rf --one-file-system -- "$tmp"; return; }
        if ! [[ $ANSWER =~ ^[0-9]+$ ]] || ((10#$ANSWER > 600)); then err "Enter 0-600."; rm -rf --one-file-system -- "$tmp"; return; fi
        secs=$((10#$ANSWER))
    fi
    confirm_yn "Update the launcher now? [y/N]: " n || { info "Cancelled."; rm -rf --one-file-system -- "$tmp"; return; }

    lock_ops 30 || { rm -rf --one-file-system -- "$tmp"; return; }
    ((${#running[@]})) && broadcast_countdown "$secs"
    : >"$STATE_DIR/post-update-restart"
    for id in "${running[@]}"; do
        load_server "$id" || continue
        info "Stopping '$S_NAME'..."
        if stop_session "$id"; then echo "$id" >>"$STATE_DIR/post-update-restart"; else err "Could not stop '$S_NAME'."; stop_fail=1; fi
    done
    if ((stop_fail)); then
        err "Update aborted; restarting the servers that were stopped."
        while IFS= read -r id; do load_server "$id" && start_server "$id"; done <"$STATE_DIR/post-update-restart"
        rm -f -- "$STATE_DIR/post-update-restart"
        unlock_ops; rm -rf --one-file-system -- "$tmp"; return
    fi

    ts=$(date +%Y%m%d-%H%M%S)
    cp -p -- "$SELF" "$SELF.backup-$ts" || warn "Could not back up the current launcher."
    mapfile -t baks < <(ls -1 "$SELF".backup-* 2>/dev/null | sort)
    if ((${#baks[@]} > 5)); then for f in "${baks[@]:0:${#baks[@]}-5}"; do rm -f -- "$f"; done; fi
    if ! { cp -- "$new" "$SELF.new.$$" && chmod 755 "$SELF.new.$$" && mv -f -- "$SELF.new.$$" "$SELF"; }; then
        err "Could not install the new launcher. Restarting the servers."
        rm -f -- "$SELF.new.$$"
        while IFS= read -r id; do load_server "$id" && start_server "$id"; done <"$STATE_DIR/post-update-restart"
        rm -f -- "$STATE_DIR/post-update-restart"
        unlock_ops; rm -rf --one-file-system -- "$tmp"; return
    fi
    rm -rf --one-file-system -- "$tmp"
    unlock_ops
    ok "Launcher updated. Restarting the launcher..."
    sleep 1
    exec 7>&- 8>&- 9>&-
    exec "$SELF" --post-update
}

post_update_restart() {
    local f="$STATE_DIR/post-update-restart" id
    [[ -f $f ]] || return 0
    info "Launcher updated. Starting the servers that were running before the update..."
    while IFS= read -r id; do
        [[ $id =~ ^[0-9]+$ ]] || continue
        load_server "$id" && start_server "$id"
    done <"$f"
    rm -f -- "$f"
}

launcher_settings_ui() {
    local c t
    while :; do
        header "LAUNCHER SETTINGS"
        printf '  1) GitHub repository    : %s (branch %s)\n' "$NEXUS_REPO" "$NEXUS_BRANCH"
        printf '  2) GitHub token         : %s\n' "$([[ -n $GITHUB_TOKEN ]] && echo '(set)' || echo '(not set - needed only for a private repo or rate limits)')"
        printf '  3) Extra plugin sources : %s\n' "${EXTRA_PLUGIN_REPOS:-none}"
        printf '  4) CS2 files folder     : %s\n' "$BASE"
        echo   "  5) Run the setup wizard again"
        echo   "  6) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) ask "Repository (owner/name)" "$NEXUS_REPO" || continue
               conf_set NEXUS_REPO "$ANSWER" || continue
               ask "Branch" "$NEXUS_BRANCH" || continue
               conf_set NEXUS_BRANCH "$ANSWER" && ok "Saved." ; sleep 1 ;;
            2) read -r -s -p "Token (hidden; empty = remove): " t || exit 0; echo
               t=$(trim "$t")
               conf_set GITHUB_TOKEN "$t" && ok "Saved."; sleep 1 ;;
            3) ask "GitHub release sources (owner/repo, comma separated, 'none' for nothing)" "${EXTRA_PLUGIN_REPOS:-none}" || continue
               t=${ANSWER//[[:space:]]/}; [[ ${t,,} == none ]] && t=""
               conf_set EXTRA_PLUGIN_REPOS "$t" && ok "Saved."; sleep 1 ;;
            4) info "To change the CS2 folder run the setup wizard again (option 5)."; sleep 2 ;;
            5) confirm_yn "Run the setup wizard again? Existing servers are kept. [y/N]: " n && { run_setup_wizard; } ;;
            6|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  NON-INTERACTIVE COMMAND LINE (cron / systemd / web panel)
# =============================================================================
usage() {
    cat <<EOF
CS2 Server Manager

Usage: $SELF [command]

  (no command)              interactive menu
  list [--json]             list servers and their state
  status [ID] [--json]      status (with player counts); --json is machine readable
  start ID                  start one server
  stop ID                   stop one server
  restart ID                restart one server
  sync [--dry-run]          register plugins dropped in the shared folders and sync all servers
  say ID MESSAGE...         send "say MESSAGE" to one running server
  broadcast MESSAGE...      send "say MESSAGE" to every running server
  watchdog                  start offline autostart servers (used by the timer)
  plugin-update             update plugins installed from the Plugin Browser (used by the timer)
  --install                 install the 'cs2' shortcut command
  help                      this text

Exit codes: 0 = ok, 1 = error or skipped items, 2 = usage error.
With --json, JSON goes to stdout and human messages go to stderr.
EOF
}

cli_json_servers() {   # <with-players 0|1> [single-id]
    local with_players=$1 id st humans bots
    local -a ids
    if [[ -n ${2:-} ]]; then ids=("$2"); else mapfile -t ids < <(jq -r '.[].id' "$DB"); fi
    for id in "${ids[@]}"; do
        load_server "$id" || continue
        st=$(status_of "$id"); humans=null; bots=null
        if ((with_players)) && [[ $st == ONLINE ]] && query_players "$id"; then
            humans=$P_HUMANS; bots=$P_BOTS
        fi
        jq -n -c --argjson id "$S_ID" --arg name "$S_NAME" --arg slug "$S_SLUG" \
            --argjson port "$S_PORT" --argjson max "$S_MAX" --arg map "$S_MAP" --arg path "$S_PATH" \
            --arg status "$st" --arg session "$(session_name "$id")" \
            --argjson humans "$humans" --argjson bots "$bots" \
            '{id:$id,name:$name,slug:$slug,port:$port,maxplayers:$max,map:$map,path:$path,status:$status,session:$session,players:$humans,bots:$bots}'
    done | jq -s '.'
}

cli_list() {
    local json=0 a
    for a in "$@"; do
        case $a in
            --json) json=1 ;;
            *) err "Unknown option: $a"; return 2 ;;
        esac
    done
    if ((json)); then MSGFD=2; cli_json_servers 0; else print_server_table; fi
}

cli_status() {
    local json=0 a id=""
    for a in "$@"; do
        case $a in
            --json) json=1 ;;
            *[!0-9]*) err "Unknown argument: $a"; return 2 ;;
            *) id=$((10#$a)) ;;
        esac
    done
    if [[ -n $id ]] && ! load_server "$id"; then err "Server ID $id not found."; return 1; fi
    if ((json)); then
        MSGFD=2
        cli_json_servers 1 "$id"
    elif [[ -n $id ]]; then
        print_server_status
    else
        print_server_table
    fi
}

cli_id_cmd() {   # start|stop|restart ID
    local action=$1 id=${2:-} rc=0
    if ! [[ $id =~ ^[0-9]+$ ]]; then err "Usage: $SELF $action ID"; return 2; fi
    id=$((10#$id))
    load_server "$id" || { err "Server ID $id not found."; return 1; }
    lock_ops 30 || return 1
    case $action in
        start) start_server "$id"; rc=$? ;;
        stop)
            if is_running "$id"; then
                if stop_session "$id"; then ok "'$S_NAME' stopped."; else err "Stop failed."; rc=1; fi
            else
                mark_manual_stop "$id"
                info "'$S_NAME' is not running."
            fi ;;
        restart)
            if is_running "$id"; then
                stop_session "$id" || { err "Could not stop '$S_NAME'."; unlock_ops; return 1; }
            fi
            start_server "$id"; rc=$? ;;
    esac
    unlock_ops
    return $rc
}

cli_sync() {
    local a rc=0
    DRY_RUN=0
    for a in "$@"; do
        case $a in
            --dry-run) DRY_RUN=1 ;;
            *) err "Unknown option: $a"; return 2 ;;
        esac
    done
    sync_shared_all || rc=1
    return $rc
}

cli_say() {
    local id=${1:-}
    if ! [[ $id =~ ^[0-9]+$ ]] || (($# < 2)); then err "Usage: $SELF say ID MESSAGE..."; return 2; fi
    shift
    id=$((10#$id))
    load_server "$id" || { err "Server ID $id not found."; return 1; }
    console_send "$id" "say $*" && ok "Sent to '$S_NAME'."
}

cli_broadcast() {
    if (($# < 1)); then err "Usage: $SELF broadcast MESSAGE..."; return 2; fi
    broadcast_cmd "say $*"
}

cli_main() {
    local subcmd=$1 a; shift
    # with --json, stdout carries ONLY json: every human message goes to stderr
    for a in "$@"; do [[ $a == --json ]] && MSGFD=2; done
    case $subcmd in
        help|-h|--help) usage ;;
        list)      preflight cli; cli_list "$@" ;;
        status)    preflight cli; cli_status "$@" ;;
        start|stop|restart) preflight cli; cli_id_cmd "$subcmd" "$@" ;;
        sync)      preflight cli; cli_sync "$@" ;;
        say)       preflight cli; cli_say "$@" ;;
        broadcast) preflight cli; cli_broadcast "$@" ;;
        watchdog)  preflight cli; watchdog_run ;;
        plugin-update) preflight cli; plugins_update_run 1 ;;
        *) err "Unknown command: $subcmd"; usage >&2; return 2 ;;
    esac
}

# ------------------------------- "cs2" shortcut ------------------------------
install_command() {
    local link="/usr/local/bin/cs2" me
    me=$SELF
    if [[ -e $link || -L $link ]]; then
        if [[ -L $link && $(readlink -f -- "$link") == "$me" ]]; then
            ok "Command 'cs2' is already installed."; return 0
        fi
        err "$link already exists and is not this manager. Remove/rename it first."
        return 1
    fi
    ln -s -- "$me" "$link" || { err "Cannot create $link"; return 1; }
    ok "Installed. Type 'cs2' in any terminal to open the manager."
}

# Non-root users: re-run through sudo automatically
if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    exec sudo -- "$SELF" "$@"
fi

if [[ ${1:-} == "--install" ]]; then
    [[ $EUID -eq 0 ]] || { err "Run with sudo: sudo $0 --install"; exit 1; }
    install_command
    exit $?
fi

POST_UPDATE=0
if [[ ${1:-} == "--post-update" ]]; then POST_UPDATE=1; shift; fi

if (($# > 0)); then
    cli_main "$@"
    exit $?
fi

preflight menu
((POST_UPDATE)) && post_update_restart
main_menu
