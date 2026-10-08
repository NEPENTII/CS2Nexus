#!/usr/bin/env bash
# =============================================================================
#  CS2NEXUS  -  CS2 SERVER MANAGER / LAUNCHER  -  /opt/nexus.sh
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
#    nexus                              interactive menu (nexus.sh)
#    nexus help                         non-interactive commands (cron/systemd)
# =============================================================================

set -u
set -o pipefail
# resolve our own path BEFORE changing directory (relative invocations like ./nexus.sh)
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
SETTINGS_DEFAULT_JSON='[{"id":0,"cvars":{},"features":{"team_balance":"off","force_pick_time":"off"},"launch":{"maxplayers":13,"map":"de_dust2","game_type":0,"game_mode":1},"custom":[],"plugins":{"mode":"all","local":[]}}]'
PREFLIGHT_MODE=menu
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

# repair_json_array <file> <label> <empty-json>
# Offers to repair a damaged registry (menu mode only). The damaged file is always
# kept as <file>.broken-<time>; servers.json is never touched by this helper.
repair_json_array() {
    local f=$1 label=$2 empty=$3 cand="" ts tmp head
    [[ $PREFLIGHT_MODE == menu ]] || return 1
    [[ -f $f ]] || return 1
    echo
    warn "The $label is damaged (it is not a JSON array): $f"
    head=$(head -c 160 -- "$f" 2>/dev/null | tr -d '\000-\010\013-\037' | tr '\n' ' ')
    info "Start of the file: ${head:-<empty>}"
    if [[ -z $(tr -d '[:space:]' <"$f" 2>/dev/null) ]]; then
        info "The file is empty."
    elif jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
        cand=$(jq -c '[.[] | select(type=="array")] | if length == 1 then .[0] else empty end' "$f" 2>/dev/null)
        [[ -n $cand ]] && info "It is an object that wraps a list (for example {\"plugins\": [...]}); the list inside can be kept."
    fi
    if [[ -z $cand ]]; then
        cand=$empty
        info "It will be replaced by a fresh, empty registry."
    fi
    confirm_yn "Repair it now? A copy of the damaged file is kept next to it (.broken-...). [Y/n]: " y || return 1
    ts=$(date +%Y%m%d-%H%M%S)
    cp -p -- "$f" "$f.broken-$ts" || { err "Could not keep a copy of the damaged file."; return 1; }
    tmp=$(mktemp "$f.XXXXXX") || return 1
    printf '%s\n' "$cand" >"$tmp"
    if ! jq -e 'type=="array"' "$tmp" >/dev/null 2>&1; then rm -f -- "$tmp"; err "Repair failed."; return 1; fi
    chmod --reference="$f" -- "$tmp" 2>/dev/null
    mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; err "Repair failed."; return 1; }
    ok "Repaired. The damaged file was kept as $f.broken-$ts"
    return 0
}

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
        if ! repair_json_array "$SHARED_DB" "plugin registry" "[]"; then
            SHARED_OK=0
            warn "$SHARED_DB is not a valid JSON array. Plugin features are disabled until it is fixed."
        fi
    fi

    if [[ ! -e $AUTOSTART_DB && ! -L $AUTOSTART_DB ]]; then
        echo "[]" >"$AUTOSTART_DB" || { err "Cannot create $AUTOSTART_DB"; exit 1; }
        chmod 644 "$AUTOSTART_DB"
    fi
    if ! jq -e 'type=="array"' "$AUTOSTART_DB" >/dev/null 2>&1; then
        if ! repair_json_array "$AUTOSTART_DB" "autostart list" "[]"; then
            AUTOSTART_OK=0
            warn "$AUTOSTART_DB is not a valid JSON array. Autostart/watchdog features are disabled until it is fixed."
        fi
    fi
}

# preflight [menu|cli]  - the single-instance lock is only taken for the menu
preflight() {
    local mode=${1:-menu}
    PREFLIGHT_MODE=$mode
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

# The CS2 game-mode configs (gamemode_competitive.cfg, gamemode_casual.cfg, ...) set
# mp_roundtime, mp_warmuptime, mp_freezetime, ... AFTER server.cfg has run, so those values
# would silently win. The same settings are therefore also written to the per-server
# gamemode_<mode>_server.cfg override files (our own files; no stock file is replaced) and to
# cs2nexus_settings.cfg, which "Apply now" executes on a running server.
GM_FILES=(casual competitive competitive2v2 deathmatch armsrace demolition workshop custom)
write_gamemode_overrides() {   # <server dir> <id>
    local srv=$1 id=$2 dir lines g f
    dir="$srv/$CSGOREL/cfg"
    [[ -d $dir && ! -L $dir ]] || return 0
    lines=$(settings_cfg_lines "$id" 2>/dev/null)
    f="$dir/cs2nexus_settings.cfg"
    [[ -L $f ]] && rm -f -- "$f"
    { echo '// Written by CS2Nexus. Do not edit: use Server Settings.'; [[ -n $lines ]] && printf '%s\n' "$lines"; } >"$f"
    chown "$CS2_USER:$CS2_GROUP" -- "$f" 2>/dev/null
    for g in "${GM_FILES[@]}"; do
        f="$dir/gamemode_${g}_server.cfg"
        [[ -L $f ]] && continue
        if [[ -f $f ]]; then sed -i '/^\/\/ BEGIN CS2NEXUS-GAMEMODE$/,/^\/\/ END CS2NEXUS-GAMEMODE$/d' "$f"; fi
        if [[ -n $lines ]]; then
            { echo '// BEGIN CS2NEXUS-GAMEMODE'; printf '%s\n' "$lines"; echo '// END CS2NEXUS-GAMEMODE'; } >>"$f"
            chown "$CS2_USER:$CS2_GROUP" -- "$f" 2>/dev/null
        elif [[ -f $f && ! -s $f ]]; then
            rm -f -- "$f"
        fi
    done
    return 0
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
    [[ -n $id ]] && write_gamemode_overrides "$srv" "$id"

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
    if repair_json_array "$SHARED_DB" "plugin registry" "[]"; then SHARED_OK=1; return 0; fi
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

# =============================================================================
#  ASTRASKINS: ONE plugin, ONE config, ONE database for EVERY server
#  - the plugin folder is the shared one (no per-server data folder)
#  - configs/plugins/AstraSkins on every server is a link to shared/configs/AstraSkins
#  - DatabaseMode is forced to "sqlite" (SQLite ships inside the plugin; nothing to install)
#  Runs automatically with every plugin sync. Old per-server folders are moved to
#  <server>/nexus-backup/ and never deleted.
# =============================================================================
readonly ASTRA_NAME="AstraSkins"
readonly ASTRA_CFG_SHARED="$SHARED_DIR/configs/$ASTRA_NAME"
ASTRA_NEEDS_RESTART=0

astra_rel() { jq -r --arg n "$ASTRA_NAME" '[.[] | select(type=="object" and .name == $n)][0].path // empty' "$SHARED_DB" 2>/dev/null; }

# registry: no per-server split, no include/exclude -> every server uses the one shared copy
astra_prepare_registry() {
    ((SHARED_OK)) || return 0
    jq -e --arg n "$ASTRA_NAME" 'any(.[]; type=="object" and .name == $n and (((.local // []) | length) > 0 or ((.exclude // []) | length) > 0 or ((.include // []) | length) > 0))' "$SHARED_DB" >/dev/null 2>&1 || return 0
    ((DRY_RUN)) && return 0
    if shared_update --arg n "$ASTRA_NAME" 'map(if type=="object" and .name == $n then del(.local, .exclude, .include) else . end)' >/dev/null; then
        info "$ASTRA_NAME is now shared by ALL servers (per-server data / exclusions removed)."
    fi
    return 0
}

# patch the one shared config: DatabaseMode=sqlite and a Sqlite.Path (keys matched case-insensitively)
astra_patch_config() {
    local f="$ASTRA_CFG_SHARED/$ASTRA_NAME.json" new tmp
    [[ -f $f ]] || return 1
    new=$(jq 'def ci($n): ((keys_unsorted | map(select(ascii_downcase == ($n | ascii_downcase))) | .[0]) // $n);
        if type != "object" then error("not an object") else . end
        | ci("DatabaseMode") as $dk | .[$dk] = "sqlite"
        | ci("Sqlite") as $sk
        | .[$sk] = ((if (.[$sk] | type) == "object" then .[$sk] else {} end)
            | ci("Path") as $pk
            | .[$pk] = (if ((.[$pk] // "") | tostring) == "" then "data/astra_skins.sqlite" else .[$pk] end))' "$f" 2>/dev/null) \
        || { warn "$ASTRA_NAME.json is not valid JSON; not touched: $f"; return 1; }
    if [[ $(jq -S . "$f" 2>/dev/null) == "$(jq -S . <<<"$new")" ]]; then return 0; fi
    ((DRY_RUN)) && return 0
    tmp="$f.tmp.$$"
    printf '%s\n' "$new" >"$tmp" && chown "$CS2_USER:$CS2_GROUP" -- "$tmp" && mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
    ok "$ASTRA_NAME config set to DatabaseMode=sqlite (shared by all servers)."
    ASTRA_NEEDS_RESTART=1
    return 0
}

# per loaded server (S_*): plugin folder + config folder
astra_share_server() {
    local rel base src plug cfgroot cfgd bk ts t
    ((SHARED_OK)) || return 0
    ((DRY_RUN)) && return 0
    rel=$(astra_rel); [[ -n $rel ]] || return 0
    validate_plugin_rel "$rel" 1 || return 0
    safe_server_path "$S_PATH" "$S_SLUG" || return 0
    base="$S_PATH/$CSGOREL"
    [[ -d $base && ! -L $base ]] || return 0
    src=$(plugin_src_path "$rel"); plug="$base/addons/$rel"
    ts=$(date +%Y%m%d-%H%M%S)
    bk="$S_PATH/nexus-backup/$ASTRA_NAME-$ts"

    # 1) a real (local / split) plugin folder is replaced by the link to the shared one
    if [[ -d $plug && ! -L $plug && -d $src ]] && ! paths_identical "$src" "$plug"; then
        mkdir -p -- "$bk" && chown "$CS2_USER:$CS2_GROUP" -- "$S_PATH/nexus-backup" "$bk" 2>/dev/null
        if mv -T -- "$plug" "$bk/plugin"; then
            info "$S_NAME: its own $ASTRA_NAME folder was moved to $bk/plugin (the shared one is used now)."
            ASTRA_NEEDS_RESTART=1
        else
            warn "$S_NAME: could not move the local $ASTRA_NAME folder; it stays per-server."
        fi
    fi

    # 2) shared config folder
    cfgroot="$base/addons/counterstrikesharp/configs/plugins"
    cfgd="$cfgroot/$ASTRA_NAME"
    install -d -m 755 -o "$CS2_USER" -g "$CS2_GROUP" -- "$SHARED_DIR/configs" "$ASTRA_CFG_SHARED" || return 0
    if [[ -L $cfgd ]]; then
        t=$(readlink -- "$cfgd")
        [[ $t == "$ASTRA_CFG_SHARED" ]] && return 0
        if [[ $t == "$SHARED_DIR"/* || ! -e $cfgd ]]; then ln -sfT -- "$ASTRA_CFG_SHARED" "$cfgd" && chown -h "$CS2_USER:$CS2_GROUP" -- "$cfgd"; return 0; fi
        warn "$S_NAME: $ASTRA_NAME config folder is a link to somewhere else ($t); left alone."; return 0
    fi
    if [[ -e $cfgd && ! -d $cfgd ]]; then warn "$S_NAME: a file blocks the $ASTRA_NAME config folder."; return 0; fi
    if [[ -d $cfgd ]]; then
        # the first config found becomes the shared one
        if [[ -f $cfgd/$ASTRA_NAME.json && ! -f $ASTRA_CFG_SHARED/$ASTRA_NAME.json ]]; then
            cp -p -- "$cfgd/$ASTRA_NAME.json" "$ASTRA_CFG_SHARED/$ASTRA_NAME.json" && chown "$CS2_USER:$CS2_GROUP" -- "$ASTRA_CFG_SHARED/$ASTRA_NAME.json"
        fi
        mkdir -p -- "$bk" && chown "$CS2_USER:$CS2_GROUP" -- "$S_PATH/nexus-backup" "$bk" 2>/dev/null
        mv -T -- "$cfgd" "$bk/config" || { warn "$S_NAME: could not move the local $ASTRA_NAME config folder."; return 0; }
        ASTRA_NEEDS_RESTART=1
    fi
    if ensure_chain "$base" "$cfgroot" && ln -s -- "$ASTRA_CFG_SHARED" "$cfgd" && chown -h "$CS2_USER:$CS2_GROUP" -- "$cfgd"; then
        info "$S_NAME: $ASTRA_NAME config is the shared one."
    else
        warn "$S_NAME: could not link the shared $ASTRA_NAME config."
    fi
    return 0
}

# the config does not exist before the plugin runs once: when it appears, patch it and reload the plugin
astra_config_watch() {   # <server id>
    local id=$1 f="$ASTRA_CFG_SHARED/$ASTRA_NAME.json"
    [[ -n $(astra_rel) ]] || return 0
    [[ -f $f ]] && { astra_patch_config; return 0; }
    (
        local i
        for ((i = 0; i < 40; i++)); do
            sleep 3
            [[ -f $f ]] || continue
            sleep 1
            ASTRA_NEEDS_RESTART=0
            astra_patch_config >/dev/null 2>&1 && ((ASTRA_NEEDS_RESTART)) && is_running "$id" && console_send "$id" "css_plugins reload $ASTRA_NAME" >/dev/null 2>&1
            exit 0
        done
    ) </dev/null >/dev/null 2>&1 7>&- 8>&- 9>&- &
    disown 2>/dev/null
    return 0
}

astra_report_restart() {
    ((ASTRA_NEEDS_RESTART)) || return 0
    warn "$ASTRA_NAME was switched to the shared folder/config: RESTART the running servers once (Restart Server) so they use it."
    ASTRA_NEEDS_RESTART=0
}

# Sync ALL shared plugins to the currently loaded server (S_*)
sync_shared_current() {
    local P_NAME P_PATH P_LOCAL P_EXCL P_INCL rc=0
    ((SHARED_OK)) || return 1
    need_layout || return 1
    lock_ops 30 || return 1
    astra_prepare_registry
    astra_share_server
    panel_write_plugin_config_current
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
    ((DRY_RUN)) || { aliases_deploy quiet; admins_deploy_defaults quiet; astra_patch_config || true; astra_report_restart; }
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
        printf '   Source       : %s\n' "$(jq -r --arg p "$P_PATH" '[.[] | select(type=="object" and .path == $p) | ((.source // "manual") + (if (.dllver // "") != "" then "  (v" + .dllver + ")" else "" end))][0] // "manual"' "$SHARED_DB")"
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
        astra_config_watch "$id"; ASTRA_NEEDS_RESTART=0
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
        echo "4) JSON backups (small registry copies)"
        echo "5) Data backups (AstraSkins, bans, admins, settings, panel)"
        echo "6) Resource alerts (CPU / RAM / disk limits)"
        echo "7) Update launcher"
        echo "8) Launcher settings"
        echo "9) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) update_cs2_ui; pause ;;
            2) sched_menu ;;
            3) watchdog_menu ;;
            4) backups_ui; pause ;;
            5) backups_full_menu ;;
            6) alerts_menu ;;
            7) update_launcher_ui; pause ;;
            8) launcher_settings_ui ;;
            9|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  EXTRA FEATURE SETTINGS  (own file: values may contain ? = & and so on)
# =============================================================================
readonly FX_FILE="$SHARED_DIR/nexus-features.conf"
fx_get() {   # <KEY> [default]
    local v
    v=$(grep -m1 "^$1=" "$FX_FILE" 2>/dev/null | cut -d= -f2-)
    printf '%s' "${v:-${2:-}}"
}
fx_set() {   # <KEY> <value>
    local k=$1 v=$2 tmp
    [[ $k =~ ^[A-Z0-9_]+$ ]] || return 1
    [[ $v != *$'\n'* && $v != *$'\r'* ]] || { err "No line breaks allowed."; return 1; }
    install -d -m 755 -- "$(dirname -- "$FX_FILE")" 2>/dev/null
    tmp=$(mktemp "$FX_FILE.XXXXXX") || return 1
    { [[ -f $FX_FILE ]] && grep -v "^$k=" "$FX_FILE"; printf '%s=%s\n' "$k" "$v"; } >"$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$FX_FILE" || { rm -f -- "$tmp"; return 1; }
}
fx_num() {   # <KEY> <default> <min> <max> -> value (falls back to default when invalid)
    local v; v=$(fx_get "$1" "$2")
    [[ $v =~ ^[0-9]+$ ]] && ((10#$v >= $3 && 10#$v <= $4)) || v=$2
    printf '%s' "$((10#$v))"
}
ask_num() {   # <prompt> <current> <min> <max>  -> ANSWER
    local a
    while :; do
        read -r -p "$1 [$2]: " a || exit 0
        a=$(trim "$a"); [[ -z $a ]] && a=$2
        if [[ $a =~ ^[0-9]+$ ]] && ((10#$a >= $3 && 10#$a <= $4)); then ANSWER=$((10#$a)); return 0; fi
        err "Enter a number from $3 to $4."
    done
}

# =============================================================================
#  DATA BACKUPS  (rotating .tar.gz: AstraSkins, bans, admins, settings, panel data)
# =============================================================================
readonly BK_ROOT="/opt/cs2-backups"
readonly BK_UNIT="cs2nexus-backup"
readonly PANEL_DIR="/opt/cs2-panel"

bk_keep() { fx_num BACKUP_KEEP 14 1 365; }

# every path (file or folder) that holds data worth keeping; only existing ones are printed
bk_collect() {
    local p id row spath rel
    local -a list=("$DB" "$FX_FILE" "$CONF_FILE" "$SHARED_DIR/configs" "$PANEL_DIR/data")
    for p in "$SHARED_DIR"/*.json; do list+=("$p"); done
    rel=$(astra_rel 2>/dev/null)
    [[ -n $rel ]] && list+=("$SHARED_ADDONS/$rel/data/astra_skins.sqlite")
    while IFS=$'\t' read -r id spath; do
        [[ -n $spath ]] || continue
        local b="$spath/$CSGOREL"
        list+=("$b/addons/counterstrikesharp/configs/admins.json" "$b/addons/counterstrikesharp/configs/ServerCommandsAdmins.json"
               "$b/addons/counterstrikesharp/plugins/ServerCommands/data" "$b/addons/counterstrikesharp/plugins/FakeBan/data"
               "$b/addons/counterstrikesharp/configs/plugins/NexusLink" "$b/cfg/server.cfg" "$b/cfg/cs2nexus_settings.cfg")
    done < <(jq -r '.[] | [.id, .path] | @tsv' "$DB" 2>/dev/null)
    for p in "${list[@]}"; do [[ -e $p ]] && printf '%s\n' "$p"; done
}

bk_sqlite_copy() {   # <src> <dst>: consistent copy of a database that may be in use
    local s=$1 d=$2
    if command -v python3 >/dev/null 2>&1 && python3 -c '
import sqlite3, sys, urllib.parse as u
src = sqlite3.connect("file:" + u.quote(sys.argv[1]) + "?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()' "$s" "$d" 2>/dev/null; then return 0; fi
    cp -a -- "$s" "$d"
}

# backup_run [label]  -> creates $BK_ROOT/cs2nexus-<label>-<time>.tar.gz and rotates the old ones
backup_run() {
    local label=${1:-auto} stage out tmp p dst n=0 keep
    install -d -m 700 -- "$BK_ROOT" || { err "Cannot create $BK_ROOT"; return 1; }
    stage=$(mktemp -d "$BK_ROOT/.stage.XXXXXX") || return 1
    while IFS= read -r p; do
        dst="$stage$p"
        mkdir -p -- "$(dirname -- "$dst")"
        case $p in
            *.sqlite|*.sqlite3|*.db) bk_sqlite_copy "$p" "$dst" ;;
            *) cp -a -- "$p" "$dst" ;;
        esac && n=$((n + 1))
        # databases inside folders (panel.db) are copied consistently as well
        if [[ -d $p ]]; then
            while IFS= read -r -d '' f; do bk_sqlite_copy "$f" "$stage$f"; done < <(find "$p" -type f \( -name '*.db' -o -name '*.sqlite' \) -print0 2>/dev/null)
            find "$stage$p" -type f \( -name '*-wal' -o -name '*-shm' -o -name '*-journal' \) -delete 2>/dev/null
        fi
    done < <(bk_collect)
    out="$BK_ROOT/cs2nexus-$label-$(date +%Y%m%d-%H%M%S).tar.gz"
    tmp="$out.part"
    if tar -C "$stage" -czpf "$tmp" . 2>/dev/null && mv -f -- "$tmp" "$out"; then
        chmod 600 "$out"
        ok "Backup created: $out ($(du -h -- "$out" | cut -f1), $n item(s))"
    else
        rm -f -- "$tmp"; rm -rf --one-file-system -- "$stage"; err "Backup failed."; return 1
    fi
    rm -rf --one-file-system -- "$stage"
    # rotation: automatic/manual backups use the setting; pre-restore safety copies keep the last 5
    keep=$(bk_keep)
    ls -1t -- "$BK_ROOT"/cs2nexus-auto-*.tar.gz "$BK_ROOT"/cs2nexus-manual-*.tar.gz 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r p; do rm -f -- "$p"; done
    ls -1t -- "$BK_ROOT"/cs2nexus-prerestore-*.tar.gz 2>/dev/null | tail -n +6 | while IFS= read -r p; do rm -f -- "$p"; done
    return 0
}

bk_list() {   # prints "file<TAB>size<TAB>date", newest first
    local f
    ls -1t -- "$BK_ROOT"/cs2nexus-*.tar.gz 2>/dev/null | while IFS= read -r f; do
        printf '%s\t%s\t%s\n' "$f" "$(du -h -- "$f" | cut -f1)" "$(date -d "@$(stat -c %Y -- "$f")" '+%Y-%m-%d %H:%M')"
    done
}

# scope filter for a restore: prints a grep -E pattern matching the paths (inside the archive, "./abs/path")
bk_scope_pattern() {
    case $1 in
        all)      echo '.' ;;
        astra)    echo '(AstraSkins|astra_skins)' ;;
        bans)     echo '/(ServerCommands|FakeBan)/data/' ;;
        admins)   echo '/configs/(admins\.json|ServerCommandsAdmins\.json)$' ;;
        settings) echo "^\\./($(printf '%s' "${DB#/}" | sed 's/[.]/\\./g')|${SHARED_DIR#/}/[^/]*\\.json|${SHARED_DIR#/}/nexus-features\\.conf|etc/cs2nexus\\.conf)|/cfg/(server|cs2nexus_settings)\\.cfg\$" ;;
        panel)    echo "^\\./${PANEL_DIR#/}/data|/configs/plugins/NexusLink/" ;;
    esac
}

backup_restore_ui() {
    local -a files=() lines=() sel
    local n c f scope pat tmp cnt=0 rows run
    mapfile -t lines < <(bk_list)
    if ((${#lines[@]} == 0)); then warn "No backups yet (folder: $BK_ROOT)."; return; fi
    header "RESTORE A BACKUP"
    n=0
    for c in "${lines[@]}"; do
        n=$((n + 1)); IFS=$'\t' read -r f sz dt <<<"$c"; files+=("$f")
        printf '  %2d) %s   %s   %s\n' "$n" "$dt" "$sz" "${f##*/}"
        ((n >= 30)) && break
    done
    echo "   b) Back"; echo
    read -r -p "Backup to restore: " c || exit 0
    c=$(trim "$c"); [[ $c == b || $c == B || -z $c ]] && return
    if ! [[ $c =~ ^[0-9]+$ ]] || ((10#$c < 1 || 10#$c > ${#files[@]})); then err "Invalid option."; return; fi
    f=${files[$((10#$c - 1))]}
    echo
    echo "  What do you want to restore?"
    echo "   1) Everything"
    echo "   2) AstraSkins (database + config)"
    echo "   3) Bans & punishments (ServerCommands / FakeBan data)"
    echo "   4) Admin files"
    echo "   5) Server list, settings, registries and server.cfg"
    echo "   6) Web panel data"
    echo "   b) Back"; echo
    read -r -p "Select: " c || exit 0
    case "$(trim "$c")" in
        1) scope=all ;; 2) scope=astra ;; 3) scope=bans ;; 4) scope=admins ;; 5) scope=settings ;; 6) scope=panel ;;
        *) return ;;
    esac
    run=$(jq -r '.[].id' "$DB" 2>/dev/null | while read -r i; do is_running "$i" && printf '%s ' "$i"; done)
    if [[ -n $run ]]; then
        err "These servers are running: $run"
        echo "  Stop them first (Stop Server), then restore. Restoring under a running server does not work reliably."
        return
    fi
    pat=$(bk_scope_pattern "$scope")
    tmp=$(mktemp -d "$BK_ROOT/.restore.XXXXXX") || return
    if ! tar -C "$tmp" -xzpf "$f" 2>/dev/null; then err "The archive could not be read."; rm -rf --one-file-system -- "$tmp"; return; fi
    mapfile -t sel < <(cd "$tmp" && find . -type f -print | grep -E -- "$pat")
    if ((${#sel[@]} == 0)); then warn "This backup holds nothing for that choice."; rm -rf --one-file-system -- "$tmp"; return; fi
    echo "  ${#sel[@]} file(s) will be restored (existing files with the same path are replaced)."
    confirm_yn "Continue? A safety backup of the current state is made first. [y/N]: " n || { rm -rf --one-file-system -- "$tmp"; return; }
    backup_run prerestore || { err "Safety backup failed; nothing restored."; rm -rf --one-file-system -- "$tmp"; return; }
    for c in "${sel[@]}"; do
        c=${c#.}
        [[ $c == /* && $c != *..* ]] || continue
        mkdir -p -- "$(dirname -- "$c")"
        if cp -a -- "$tmp$c" "$c"; then cnt=$((cnt + 1)); fi
    done
    rm -rf --one-file-system -- "$tmp"
    ok "Restored $cnt file(s). Start your servers again."
    [[ $scope == all || $scope == settings ]] && info "Run 'Plugins -> Sync' once so every server picks up its files."
}

backup_timer_install() {
    command -v systemctl >/dev/null 2>&1 || { err "systemctl is not available."; return 1; }
    local hour; hour=$(fx_num BACKUP_HOUR 4 0 23)
    cat >"/etc/systemd/system/$BK_UNIT.service" <<EOF
[Unit]
Description=CS2Nexus data backup

[Service]
Type=oneshot
ExecStart=$SELF backup
EOF
    cat >"/etc/systemd/system/$BK_UNIT.timer" <<EOF
[Unit]
Description=Daily CS2Nexus data backup

[Timer]
OnCalendar=*-*-* $(printf '%02d' "$hour"):30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    if systemctl daemon-reload && systemctl enable --now "$BK_UNIT.timer" >/dev/null 2>&1; then
        fx_set BACKUP_AUTO 1; ok "Automatic backup enabled (every day at $(printf '%02d' "$hour"):30)."
    else err "Could not enable the backup timer."; return 1; fi
}
backup_timer_remove() {
    command -v systemctl >/dev/null 2>&1 && systemctl disable --now "$BK_UNIT.timer" >/dev/null 2>&1
    rm -f -- "/etc/systemd/system/$BK_UNIT.service" "/etc/systemd/system/$BK_UNIT.timer"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    fx_set BACKUP_AUTO 0; ok "Automatic backup disabled."
}

backups_full_menu() {
    local c n a
    while :; do
        clear_screen; dsep
        printf '%s              DATA BACKUPS%s\n' "$BOLD" "$RESET"; dsep; echo
        a=$(systemctl is-active "$BK_UNIT.timer" 2>/dev/null || echo no)
        n=$(bk_list | wc -l)
        printf '  Folder        : %s\n  Backups       : %s (keeps the newest %s)\n  Automatic     : %s (daily %02d:30)\n\n' \
            "$BK_ROOT" "$n" "$(bk_keep)" "$([[ $a == active ]] && echo ON || echo OFF)" "$(fx_num BACKUP_HOUR 4 0 23)"
        echo "  Saved: AstraSkins database/config, bans & punishments, admin files, server list,"
        echo "         settings, plugin registries, server.cfg and the web panel data."
        echo
        echo "  1) Back up now"
        echo "  2) Turn automatic daily backup ON / OFF"
        echo "  3) Change time and how many to keep"
        echo "  4) List backups"
        echo "  5) Restore a backup"
        echo "  6) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) backup_run manual; pause ;;
            2) if [[ $a == active ]]; then backup_timer_remove; else backup_timer_install; fi; pause ;;
            3) ask_num "Hour of the day (0-23)" "$(fx_num BACKUP_HOUR 4 0 23)" 0 23; fx_set BACKUP_HOUR "$ANSWER"
               ask_num "How many backups to keep" "$(bk_keep)" 1 365; fx_set BACKUP_KEEP "$ANSWER"
               [[ $a == active ]] && backup_timer_install; pause ;;
            4) bk_list | awk -F'\t' '{printf "  %s  %6s  %s\n", $3, $2, $1}'; pause ;;
            5) backup_restore_ui; pause ;;
            6|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  RESOURCE ALERTS  (timer every minute; log + optional Discord-style webhook / Telegram)
# =============================================================================
readonly AL_UNIT="cs2nexus-alerts"
readonly AL_LOG="/var/log/cs2nexus-alerts.log"
readonly AL_STATE="$STATE_DIR/alerts.state"

alert_send() {   # <text>   (never fails the caller)
    local msg=$1 url tok chat
    printf '%s %s\n' "$(date '+%F %T')" "$msg" >>"$AL_LOG" 2>/dev/null
    if [[ -f $AL_LOG ]] && (($(stat -c %s "$AL_LOG" 2>/dev/null || echo 0) > 1048576)); then tail -n 2000 "$AL_LOG" >"$AL_LOG.tmp" && mv -f "$AL_LOG.tmp" "$AL_LOG"; fi
    command -v logger >/dev/null 2>&1 && logger -t cs2nexus-alert -- "$msg"
    msg="[$(hostname)] $msg"
    url=$(fx_get ALERT_WEBHOOK)
    if [[ -n $url ]]; then
        curl -fsS -m 10 -H 'Content-Type: application/json' -d "$(jq -nc --arg c "$msg" '{content:$c, text:$c}')" "$url" >/dev/null 2>&1 || true
    fi
    tok=$(fx_get ALERT_TG_TOKEN); chat=$(fx_get ALERT_TG_CHAT)
    if [[ -n $tok && -n $chat ]]; then
        curl -fsS -m 10 "https://api.telegram.org/bot$tok/sendMessage" --data-urlencode "chat_id=$chat" --data-urlencode "text=$msg" >/dev/null 2>&1 || true
    fi
    return 0
}

# one check (called every minute by the timer). A value must stay over its limit for ALERT_SUSTAIN
# checks in a row before an alert is sent; the same alert repeats at most every ALERT_COOLDOWN minutes.
alert_check() {
    [[ $(fx_get ALERT_ENABLED 0) == 1 ]] || return 0
    local lim_cpu lim_ram lim_disk sustain cool now
    lim_cpu=$(fx_num ALERT_CPU 90 1 100); lim_ram=$(fx_num ALERT_RAM 90 1 100); lim_disk=$(fx_num ALERT_DISK 90 1 100)
    sustain=$(fx_num ALERT_SUSTAIN 3 1 60); cool=$(fx_num ALERT_COOLDOWN 30 1 1440); now=$(date +%s)
    local -A st_streak=() st_last=() st_on=() prev=() cur=() val=() lim=() label=()
    local line k a b c
    if [[ -f $AL_STATE ]]; then
        while read -r k line; do
            case $k in
                P:*) prev[${k#P:}]="$line" ;;
                S:*) read -r a b c <<<"$line"; st_streak[${k#S:}]=$a; st_last[${k#S:}]=$b; st_on[${k#S:}]=$c ;;
            esac
        done <"$AL_STATE"
    fi
    local tick cores memtot memavail dfp tot idle t0
    tick=$(getconf CLK_TCK 2>/dev/null || echo 100); cores=$(nproc 2>/dev/null || echo 1)
    memtot=$(awk '/^MemTotal:/{print $2}' /proc/meminfo); memavail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    read -r tot idle < <(awk '/^cpu /{ t = 0; for (i = 2; i <= NF; i++) t += $i; print t, $5 + $6 }' /proc/stat)
    # system CPU since the previous check
    cur[sys]="$tot $idle $now"
    if [[ -n ${prev[sys]:-} ]]; then
        read -r pt pi pn <<<"${prev[sys]}"
        if ((tot > pt)); then val[cpu]=$(( 100 * ((tot - pt) - (idle - pi)) / (tot - pt) )); fi
    fi
    val[ram]=$(( (memtot - memavail) * 100 / (memtot > 0 ? memtot : 1) ))
    dfp=$(df -P "$SERVERS_DIR" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'); [[ $dfp =~ ^[0-9]+$ ]] && val[disk]=$dfp
    lim[cpu]=$lim_cpu; lim[ram]=$lim_ram; lim[disk]=$lim_disk
    label[cpu]="CPU of the machine"; label[ram]="RAM of the machine"; label[disk]="Disk ($SERVERS_DIR)"
    # every running server: its share of the machine
    local snap id name pid ticks pages ramp cpup
    snap=$(mktemp) && mon_snapshot >"$snap"
    while IFS=$'\t' read -r id name; do
        pid=$(tmux_cs2 list-panes -t "=$(session_name "$id"):" -F '#{pane_pid}' 2>/dev/null | head -n 1)
        [[ -n $pid ]] || continue
        read -r ticks pages < <(mon_sum "$snap" "$pid")
        ramp=$(( pages * $(getconf PAGESIZE 2>/dev/null || echo 4096) / 1024 * 100 / (memtot > 0 ? memtot : 1) ))
        val[s${id}ram]=$ramp; lim[s${id}ram]=$lim_ram; label[s${id}ram]="Server '$name' RAM (share of the machine)"
        cur[s$id]="$ticks $now"
        if [[ -n ${prev[s$id]:-} ]]; then
            read -r pt pn <<<"${prev[s$id]}"
            if ((now > pn)); then
                cpup=$(awk -v d="$((ticks - pt))" -v tk="$tick" -v s="$((now - pn))" -v c="$cores" 'BEGIN{ v = d / tk / s * 100 / c; if (v < 0) v = 0; printf "%d", v }')
                val[s${id}cpu]=$cpup; lim[s${id}cpu]=$lim_cpu; label[s${id}cpu]="Server '$name' CPU (share of the machine)"
            fi
        fi
    done < <(jq -r '.[] | [.id, .name] | @tsv' "$DB" 2>/dev/null)
    rm -f -- "$snap"
    for k in "${!val[@]}"; do
        if ((val[$k] >= lim[$k])); then
            st_streak[$k]=$(( ${st_streak[$k]:-0} + 1 ))
            if ((st_streak[$k] >= sustain)) && ((now - ${st_last[$k]:-0} >= cool * 60)); then
                alert_send "ALERT: ${label[$k]} is at ${val[$k]}% (limit ${lim[$k]}%, for ${st_streak[$k]} min)."
                st_last[$k]=$now; st_on[$k]=1
            fi
        else
            if [[ ${st_on[$k]:-0} == 1 ]]; then alert_send "OK again: ${label[$k]} is back to ${val[$k]}%."; fi
            st_streak[$k]=0; st_on[$k]=0
        fi
    done
    for k in "${!st_streak[@]}"; do   # a value that is no longer measured (server stopped) is forgotten silently
        [[ -n ${val[$k]+x} ]] || { st_streak[$k]=0; st_on[$k]=0; }
    done
    {
        for k in "${!cur[@]}"; do printf 'P:%s %s\n' "$k" "${cur[$k]}"; done
        for k in "${!st_streak[@]}"; do printf 'S:%s %s %s %s\n' "$k" "${st_streak[$k]}" "${st_last[$k]:-0}" "${st_on[$k]:-0}"; done
    } >"$AL_STATE.tmp" && mv -f -- "$AL_STATE.tmp" "$AL_STATE"
    return 0
}

alert_timer_install() {
    command -v systemctl >/dev/null 2>&1 || { err "systemctl is not available."; return 1; }
    cat >"/etc/systemd/system/$AL_UNIT.service" <<EOF
[Unit]
Description=CS2Nexus resource alert check

[Service]
Type=oneshot
ExecStart=$SELF alert-check
EOF
    cat >"/etc/systemd/system/$AL_UNIT.timer" <<EOF
[Unit]
Description=CS2Nexus resource alert check every minute

[Timer]
OnActiveSec=30
OnUnitActiveSec=60
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
    if systemctl daemon-reload && systemctl enable --now "$AL_UNIT.timer" >/dev/null 2>&1; then
        fx_set ALERT_ENABLED 1; ok "Resource alerts are ON (checked every minute)."
    else err "Could not enable the alert timer."; return 1; fi
}
alert_timer_remove() {
    command -v systemctl >/dev/null 2>&1 && systemctl disable --now "$AL_UNIT.timer" >/dev/null 2>&1
    rm -f -- "/etc/systemd/system/$AL_UNIT.service" "/etc/systemd/system/$AL_UNIT.timer" "$AL_STATE"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
    fx_set ALERT_ENABLED 0; ok "Resource alerts are OFF."
}

alerts_menu() {
    local c v
    while :; do
        clear_screen; dsep
        printf '%s              RESOURCE ALERTS%s\n' "$BOLD" "$RESET"; dsep; echo
        printf '  State          : %s\n' "$([[ $(fx_get ALERT_ENABLED 0) == 1 ]] && echo "${GREEN}ON${RESET}" || echo "${RED}OFF${RESET}")"
        printf '  Limits         : CPU %s%%   RAM %s%%   Disk %s%%\n' "$(fx_num ALERT_CPU 90 1 100)" "$(fx_num ALERT_RAM 90 1 100)" "$(fx_num ALERT_DISK 90 1 100)"
        printf '  Alert when     : over the limit for %s minute(s) in a row; the same alert repeats at most every %s min\n' "$(fx_num ALERT_SUSTAIN 3 1 60)" "$(fx_num ALERT_COOLDOWN 30 1 1440)"
        printf '  Also checks    : every running server (its share of the machine, same CPU/RAM limits)\n'
        printf '  Log file       : %s\n' "$AL_LOG"
        v=$(fx_get ALERT_WEBHOOK); printf '  Webhook        : %s\n' "${v:+set}${v:-not set}"
        v=$(fx_get ALERT_TG_TOKEN); printf '  Telegram       : %s\n\n' "$([[ -n $v && -n $(fx_get ALERT_TG_CHAT) ]] && echo set || echo 'not set')"
        echo "  1) Turn alerts ON / OFF"
        echo "  2) Change the limits (CPU, RAM, disk)"
        echo "  3) Change how long / how often"
        echo "  4) Set the webhook (Discord or any URL that accepts JSON)"
        echo "  5) Set Telegram (bot token + chat id)"
        echo "  6) Send a test alert"
        echo "  7) Show the alert log"
        echo "  8) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) if [[ $(fx_get ALERT_ENABLED 0) == 1 ]]; then alert_timer_remove; else alert_timer_install; fi; pause ;;
            2) ask_num "CPU limit %" "$(fx_num ALERT_CPU 90 1 100)" 1 100; fx_set ALERT_CPU "$ANSWER"
               ask_num "RAM limit %" "$(fx_num ALERT_RAM 90 1 100)" 1 100; fx_set ALERT_RAM "$ANSWER"
               ask_num "Disk limit %" "$(fx_num ALERT_DISK 90 1 100)" 1 100; fx_set ALERT_DISK "$ANSWER"; ok "Saved."; pause ;;
            3) ask_num "Minutes over the limit before an alert" "$(fx_num ALERT_SUSTAIN 3 1 60)" 1 60; fx_set ALERT_SUSTAIN "$ANSWER"
               ask_num "Repeat the same alert at most every (minutes)" "$(fx_num ALERT_COOLDOWN 30 1 1440)" 1 1440; fx_set ALERT_COOLDOWN "$ANSWER"; ok "Saved."; pause ;;
            4) read -r -p "Webhook URL (empty = remove): " v || exit 0; v=$(trim "$v")
               if [[ -z $v || $v =~ ^https?://[^[:space:]]+$ ]]; then fx_set ALERT_WEBHOOK "$v"; ok "Saved."; else err "That is not an http(s) URL."; fi; pause ;;
            5) read -r -p "Telegram bot token (empty = remove): " v || exit 0; v=$(trim "$v")
               if [[ -z $v ]]; then fx_set ALERT_TG_TOKEN ""; fx_set ALERT_TG_CHAT ""; ok "Removed."
               elif [[ $v =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
                   fx_set ALERT_TG_TOKEN "$v"; read -r -p "Chat id: " v || exit 0; v=$(trim "$v")
                   [[ $v =~ ^-?[0-9]+$ ]] && { fx_set ALERT_TG_CHAT "$v"; ok "Saved."; } || err "The chat id is a number."
               else err "That does not look like a bot token."; fi; pause ;;
            6) alert_send "TEST: this is a test alert from CS2Nexus."; ok "Sent (log, journal$([[ -n $(fx_get ALERT_WEBHOOK) ]] && echo ', webhook')$([[ -n $(fx_get ALERT_TG_TOKEN) ]] && echo ', Telegram'))."; pause ;;
            7) if [[ -s $AL_LOG ]]; then tail -n 30 "$AL_LOG"; else info "The log is empty."; fi; pause ;;
            8|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# =============================================================================
#  WEB PANEL  (players' website: login with !getcode, live servers, history, matches)
#  The panel files and the NexusLink plugin are built into this launcher.
# =============================================================================
readonly PANEL_UNIT="cs2nexus-panel"
readonly PANEL_VERSION="1.0.0"
readonly PANEL_SETTINGS="$PANEL_DIR/data/settings.json"

panel_installed() { [[ -f $PANEL_DIR/app/server.py && -f $PANEL_SETTINGS ]]; }
panel_get() { jq -r --arg k "$1" '.[$k] // empty' "$PANEL_SETTINGS" 2>/dev/null; }
panel_set() {   # <key> <json value>
    local tmp
    tmp=$(mktemp "$PANEL_SETTINGS.XXXXXX") || return 1
    if jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$PANEL_SETTINGS" >"$tmp" 2>/dev/null; then
        chown "root:$CS2_GROUP" "$tmp"; chmod 640 "$tmp"; mv -f -- "$tmp" "$PANEL_SETTINGS"
    else rm -f -- "$tmp"; return 1; fi
}
panel_running() { systemctl is-active --quiet "$PANEL_UNIT.service" 2>/dev/null; }
panel_host() {
    local h; h=$(panel_get domain)
    [[ -n $h ]] || h=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "${h:-your-server-ip}"
}
panel_url() {
    local scheme=http port; port=$(panel_get port)
    [[ -n $(panel_get tls_cert) ]] && scheme=https
    if [[ ($scheme == http && $port == 80) || ($scheme == https && $port == 443) ]]; then printf '%s://%s' "$scheme" "$(panel_host)"
    else printf '%s://%s:%s' "$scheme" "$(panel_host)" "$port"; fi
}

# the list of servers the website shows (written for the panel user, nothing secret in it)
panel_export_servers() {
    [[ -d $PANEL_DIR/data ]] || return 0
    local tmp="$PANEL_DIR/data/servers-public.json.tmp"
    jq '[.[] | {id:.id, name:.name, port:.port, maxplayers:.maxplayers, map:.map}]' "$DB" >"$tmp" 2>/dev/null \
        && chown "$CS2_USER:$CS2_GROUP" "$tmp" && chmod 644 "$tmp" && mv -f -- "$tmp" "$PANEL_DIR/data/servers-public.json"
    return 0
}

# per-server NexusLink config (server id + panel address + key). Uses the loaded server (S_*).
panel_write_plugin_config_current() {   # [disabled]
    panel_installed || return 0
    local base="$S_PATH/$CSGOREL" dir f key ip en=true
    [[ ${1:-} == disabled ]] && en=false
    [[ -d $base && ! -L $base ]] || return 0
    dir="$base/addons/counterstrikesharp/configs/plugins/NexusLink"
    ensure_chain "$base" "$dir" || return 0
    f="$dir/NexusLink.json"; key=$(panel_get api_key); ip=$(panel_get internal_port)
    local new
    new=$(jq -n --argjson en "$en" --arg url "http://127.0.0.1:${ip:-27500}" --arg key "$key" --argjson id "$S_ID" \
        '{ConfigVersion:1, Enabled:$en, PanelUrl:$url, ApiKey:$key, ServerId:$id, SnapshotSeconds:5, CodeCooldownSeconds:15, MinMatchRounds:3, ChatPrefix:"[Nexus]"}')
    if [[ -f $f && $(jq -S . "$f" 2>/dev/null) == "$(jq -S . <<<"$new")" ]]; then return 0; fi
    printf '%s\n' "$new" >"$f" && chown "$CS2_USER:$CS2_GROUP" "$f" && chmod 640 "$f"
    PANEL_CFG_CHANGED=1
    return 0
}
PANEL_CFG_CHANGED=0
panel_write_all_plugin_configs() {   # [disabled]
    local id; PANEL_CFG_CHANGED=0
    while IFS= read -r id; do load_server "$id" && panel_write_plugin_config_current "${1:-}"; done < <(jq -r '.[].id' "$DB")
}

panel_payload_extract() {   # <dest>
    awk '/^#__NEXUS_PAYLOAD_END__$/{f=0} f{sub(/^#/,""); print} /^#__NEXUS_PAYLOAD_BEGIN__$/{f=1}' "$SELF" | base64 -d 2>/dev/null | tar -xz -C "$1" 2>/dev/null
}

panel_unit_write() {
    command -v systemctl >/dev/null 2>&1 || { err "systemd is not available on this machine."; return 1; }
    cat >"/etc/systemd/system/$PANEL_UNIT.service" <<EOF
[Unit]
Description=CS2Nexus web panel
After=network.target

[Service]
User=$CS2_USER
Group=$CS2_GROUP
Environment=NEXUS_PANEL_DATA=$PANEL_DIR/data
ExecStartPre=-+$SELF panel-export
ExecStart=/usr/bin/env python3 $PANEL_DIR/app/server.py
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$PANEL_DIR/data

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

panel_firewall_hint() {   # <port>
    command -v ufw >/dev/null 2>&1 || return 0
    ufw status 2>/dev/null | grep -q "^Status: active" || return 0
    ufw status 2>/dev/null | grep -qE "^$1(/tcp)?[[:space:]]+ALLOW" && return 0
    if confirm_yn "The firewall (ufw) is active. Open port $1/tcp for the panel? [Y/n]: " y; then ufw allow "$1/tcp" >/dev/null && ok "Port $1/tcp opened."; fi
}

panel_install() {
    local tmp key first=0
    [[ -d $SHARED_ADDONS ]] || { err "The shared plugin folder does not exist yet (finish the launcher setup first)."; return 1; }
    if ! command -v python3 >/dev/null 2>&1; then
        confirm_yn "Python 3 is needed for the panel. Install it now (apt)? [Y/n]: " y || return 1
        apt-get install -y python3 >/dev/null 2>&1 || { err "Could not install python3."; return 1; }
    fi
    python3 -c 'import sys,sqlite3; sys.exit(0 if sys.version_info >= (3,8) else 1)' 2>/dev/null || { err "Python 3.8 or newer with sqlite3 is required."; return 1; }
    tmp=$(mktemp -d /tmp/cs2nexus-panel.XXXXXX) || return 1
    if ! panel_payload_extract "$tmp" || [[ ! -f $tmp/app/server.py || ! -f $tmp/plugin/NexusLink/NexusLink.dll ]]; then
        err "This launcher file has no panel inside (damaged copy?). Use 'Maintenance -> Update launcher'."
        rm -rf --one-file-system -- "$tmp"; return 1
    fi
    panel_installed || first=1
    install -d -m 755 -- "$PANEL_DIR" "$PANEL_DIR/maps" "$PANEL_DIR/tls"
    install -d -m 750 -o "$CS2_USER" -g "$CS2_GROUP" -- "$PANEL_DIR/data"
    chown -R "$CS2_USER:$CS2_GROUP" "$PANEL_DIR/maps" "$PANEL_DIR/tls"
    rm -rf --one-file-system -- "$PANEL_DIR/app"
    mv -- "$tmp/app" "$PANEL_DIR/app" && chown -R root:root "$PANEL_DIR/app" && chmod -R go-w "$PANEL_DIR/app"
    printf '%s\n' "$PANEL_VERSION" >"$PANEL_DIR/VERSION"
    if [[ ! -f $PANEL_SETTINGS ]]; then
        key=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)
        jq -n --arg key "$key" --arg dir "$PANEL_DIR" \
            '{port:8080, bind:"0.0.0.0", internal_port:27500, api_key:$key, domain:"", tls_cert:"", tls_key:"", trust_proxy:false,
              servers_file:($dir+"/data/servers-public.json"), maps_dir:($dir+"/maps"), title:"CS2Nexus", session_hours:720, code_ttl:600}' >"$PANEL_SETTINGS"
        chown "root:$CS2_GROUP" "$PANEL_SETTINGS"; chmod 640 "$PANEL_SETTINGS"
    fi
    # NexusLink plugin: one shared copy for every server
    local pdst="$SHARED_ADDONS/counterstrikesharp/plugins/NexusLink"
    install -d -m 755 -o "$CS2_USER" -g "$CS2_GROUP" -- "$SHARED_ADDONS/counterstrikesharp/plugins"
    rm -rf --one-file-system -- "$pdst"; cp -a -- "$tmp/plugin/NexusLink" "$pdst" && chown -R "$CS2_USER:$CS2_GROUP" "$pdst"
    rm -rf --one-file-system -- "$tmp"
    shared_update --arg n NexusLink --arg p "counterstrikesharp/plugins/NexusLink" \
        'if any(.[]; type=="object" and .path == $p) then . else . += [{name:$n, path:$p}] end' >/dev/null
    panel_export_servers
    panel_unit_write || return 1
    lock_ops 30 && { DRY_RUN=0; sync_shared_all || true; unlock_ops; }
    panel_write_all_plugin_configs
    systemctl enable "$PANEL_UNIT.service" >/dev/null 2>&1
    systemctl restart "$PANEL_UNIT.service"; sleep 1
    if panel_running; then ok "Web panel installed and running: $(panel_url)"; else err "The panel did not start. See: journalctl -u $PANEL_UNIT -n 30"; fi
    panel_firewall_hint "$(panel_get port)"
    ok "NexusLink plugin installed for every server (one shared copy)."
    if ((first || PANEL_CFG_CHANGED)); then
        warn "Restart your servers once (Restart Server) so they load NexusLink and connect to the panel."
    fi
}

panel_ctl() {   # start|stop|restart
    panel_installed || { err "The panel is not installed yet."; return 1; }
    systemctl "$1" "$PANEL_UNIT.service" && sleep 1
    if [[ $1 != stop ]]; then panel_running && ok "Panel is running: $(panel_url)" || err "The panel is not running. See the log (option 9)."
    else ok "Panel stopped."; fi
}

panel_set_port() {
    ask_num "Public port of the website (80 and 443 work too)" "$(panel_get port)" 1 65535 || return
    local p=$ANSWER
    [[ $p == "$(panel_get internal_port)" ]] && { err "That port is used by the internal plugin link."; return; }
    panel_set port "$p" && ok "Port set to $p." && panel_firewall_hint "$p"
    panel_running && systemctl restart "$PANEL_UNIT.service" && ok "Panel restarted: $(panel_url)"
}

panel_domain_menu() {
    local c d email tmpd crt key host
    while :; do
        clear_screen; dsep
        printf '%s              DOMAIN AND SSL%s\n' "$BOLD" "$RESET"; dsep; echo
        d=$(panel_get domain)
        printf '  Domain    : %s\n  SSL       : %s\n  Address   : %s\n  Proxy     : %s\n\n' "${d:-none (using the server IP)}" \
            "$([[ -n $(panel_get tls_cert) ]] && echo "ON ($(panel_get tls_cert))" || echo OFF)" "$(panel_url)" \
            "$([[ $(panel_get trust_proxy) == true ]] && echo 'trusting X-Forwarded headers' || echo 'direct')"
        echo "  1) Set the domain name"
        echo "  2) Get a free SSL certificate (Let's Encrypt)"
        echo "  3) Use my own certificate files"
        echo "  4) Turn SSL off"
        echo "  5) I use a reverse proxy / Cloudflare in front (trust forwarded IP) ON / OFF"
        echo "  6) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) read -r -p "Domain (example: play.example.com, empty = remove): " d || exit 0; d=$(trim "${d,,}")
               if [[ -z $d || $d =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]; then panel_set domain "\"$d\"" && ok "Saved."
                   [[ -n $d ]] && info "Point the DNS A record of $d to this server's IP, then choose option 2 for SSL."
               else err "That is not a valid domain name."; fi; pause ;;
            2) d=$(panel_get domain)
               [[ -n $d ]] || { err "Set the domain first (option 1)."; pause; continue; }
               echo "  Needs: the domain already points to this server, and port 80 is free during the check."
               if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then err "Port 80 is in use by another program. Stop it first, then retry."; pause; continue; fi
               read -r -p "Email for Let's Encrypt notices: " email || exit 0; email=$(trim "$email")
               [[ $email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "That email looks wrong."; pause; continue; }
               if ! command -v certbot >/dev/null 2>&1; then
                   confirm_yn "certbot is needed. Install it now (apt)? [Y/n]: " y || continue
                   apt-get install -y certbot >/dev/null 2>&1 || { err "Could not install certbot."; pause; continue; }
               fi
               panel_firewall_hint 80
               install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
               cat >/etc/letsencrypt/renewal-hooks/deploy/cs2nexus-panel.sh <<EOF
#!/bin/sh
# copies the renewed certificate for the CS2Nexus panel and restarts it
[ "\${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/$d" ] || exit 0
cp -L /etc/letsencrypt/live/$d/fullchain.pem $PANEL_DIR/tls/fullchain.pem
cp -L /etc/letsencrypt/live/$d/privkey.pem $PANEL_DIR/tls/privkey.pem
chown $CS2_USER:$CS2_GROUP $PANEL_DIR/tls/fullchain.pem $PANEL_DIR/tls/privkey.pem
chmod 640 $PANEL_DIR/tls/privkey.pem
systemctl restart $PANEL_UNIT.service
EOF
               chmod 755 /etc/letsencrypt/renewal-hooks/deploy/cs2nexus-panel.sh
               if certbot certonly --standalone -d "$d" --non-interactive --agree-tos -m "$email" --keep-until-expiring; then
                   RENEWED_LINEAGE="/etc/letsencrypt/live/$d" /etc/letsencrypt/renewal-hooks/deploy/cs2nexus-panel.sh 2>/dev/null
                   cp -L "/etc/letsencrypt/live/$d/fullchain.pem" "$PANEL_DIR/tls/fullchain.pem" && cp -L "/etc/letsencrypt/live/$d/privkey.pem" "$PANEL_DIR/tls/privkey.pem" \
                       && chown "$CS2_USER:$CS2_GROUP" "$PANEL_DIR/tls/"*.pem && chmod 640 "$PANEL_DIR/tls/privkey.pem"
                   panel_set tls_cert "\"$PANEL_DIR/tls/fullchain.pem\""; panel_set tls_key "\"$PANEL_DIR/tls/privkey.pem\""
                   ok "Certificate installed. It renews itself (certbot timer) and the panel restarts after each renewal."
                   if [[ $(panel_get port) != 443 ]] && confirm_yn "Use the normal HTTPS port 443 for the website? [Y/n]: " y; then panel_set port 443; panel_firewall_hint 443; fi
                   panel_running && systemctl restart "$PANEL_UNIT.service"
                   ok "Open: $(panel_url)"
               else err "Let's Encrypt refused. Check that $d points to this server and port 80 is reachable from outside."; fi
               pause ;;
            3) read -r -p "Path of the certificate file (fullchain / .crt): " crt || exit 0; read -r -p "Path of the private key file: " key || exit 0
               crt=$(trim "$crt"); key=$(trim "$key")
               if [[ -f $crt && -f $key ]] && openssl x509 -in "$crt" -noout 2>/dev/null; then
                   cp -L -- "$crt" "$PANEL_DIR/tls/fullchain.pem" && cp -L -- "$key" "$PANEL_DIR/tls/privkey.pem" \
                       && chown "$CS2_USER:$CS2_GROUP" "$PANEL_DIR/tls/"*.pem && chmod 640 "$PANEL_DIR/tls/privkey.pem"
                   panel_set tls_cert "\"$PANEL_DIR/tls/fullchain.pem\""; panel_set tls_key "\"$PANEL_DIR/tls/privkey.pem\""
                   ok "Certificate copied. Renew it yourself by repeating this option."
                   panel_running && systemctl restart "$PANEL_UNIT.service"
               else err "Could not read a valid certificate and key at those paths."; fi; pause ;;
            4) panel_set tls_cert '""'; panel_set tls_key '""'; ok "SSL is off (plain http)."; panel_running && systemctl restart "$PANEL_UNIT.service"; pause ;;
            5) if [[ $(panel_get trust_proxy) == true ]]; then panel_set trust_proxy false; ok "Direct connections only."
               else panel_set trust_proxy true; ok "X-Forwarded-For / -Proto are trusted. Only turn this on if ALL traffic comes through your proxy."; fi
               panel_running && systemctl restart "$PANEL_UNIT.service"; pause ;;
            6|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

panel_maps_help() {
    local n; n=$(find "$PANEL_DIR/maps" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | wc -l)
    echo
    echo "  Map pictures folder : $PANEL_DIR/maps   ($n picture(s) now)"
    echo "  Name each file like the map: de_dust2.jpg, de_mirage.png, de_inferno.webp, cs_office.jpg ..."
    echo "  (jpg, png or webp, about 640x360 looks best). Workshop maps use the last part of the name."
    echo "  Maps without a picture show a coloured card with the map name. New files show up at once."
}

panel_menu() {
    local c st
    while :; do
        clear_screen; dsep
        printf '%s              WEB PANEL%s\n' "$BOLD" "$RESET"; dsep; echo
        if panel_installed; then
            panel_running && st="${GREEN}RUNNING${RESET}" || st="${RED}STOPPED${RESET}"
            printf '  Status  : %s   (panel %s, built into this launcher: %s)\n' "$st" "$(cat "$PANEL_DIR/VERSION" 2>/dev/null || echo ?)" "$PANEL_VERSION"
            printf '  Address : %s\n' "$(panel_url)"
            printf '  Plugin  : NexusLink (one shared copy; each server reports to http://127.0.0.1:%s)\n\n' "$(panel_get internal_port)"
        else
            echo "  Not installed yet. Players log in with !getcode in the game, then see their servers,"
            echo "  play time and matches on a website that runs on this machine."
            echo
        fi
        echo "  1) Install / update the panel (also installs the NexusLink plugin on all servers)"
        echo "  2) Start"
        echo "  3) Stop"
        echo "  4) Restart"
        echo "  5) Change the port"
        echo "  6) Domain and SSL"
        echo "  7) Map pictures"
        echo "  8) Re-write the plugin settings of all servers (after changing ports)"
        echo "  9) Show the panel log"
        echo " 10) Remove the panel (data and pictures are kept)"
        echo " 11) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) panel_install; pause ;;
            2) panel_ctl start; pause ;;
            3) panel_ctl stop; pause ;;
            4) panel_ctl restart; pause ;;
            5) panel_installed && panel_set_port || err "Install the panel first."; pause ;;
            6) panel_installed && panel_domain_menu || { err "Install the panel first."; pause; } ;;
            7) panel_maps_help; pause ;;
            8) panel_installed && { panel_write_all_plugin_configs; ok "Done."; ((PANEL_CFG_CHANGED)) && warn "Restart the servers (or run 'css_plugins reload NexusLink' in their console)."; } || err "Install the panel first."; pause ;;
            9) journalctl -u "$PANEL_UNIT" -n 40 --no-pager 2>/dev/null || err "No log available."; pause ;;
            10) if confirm_yn "Stop and remove the panel program? Players' history in $PANEL_DIR/data stays. [y/N]: " n; then
                    systemctl disable --now "$PANEL_UNIT.service" >/dev/null 2>&1
                    rm -f -- "/etc/systemd/system/$PANEL_UNIT.service"; systemctl daemon-reload
                    rm -rf --one-file-system -- "$PANEL_DIR/app"
                    panel_write_all_plugin_configs disabled 2>/dev/null
                    ok "Panel removed. NexusLink is switched off in every server's settings (remove it in Plugins if you like)."
                fi; pause ;;
            11|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

# ------------------------------- Main menu -----------------------------------
# ---------- admins (launcher view across all servers) ----------
# In-game /addadmin makes an admin for THAT server only. Here the owner can make an admin a default
# admin (every server, also servers created later), limit him to chosen servers, edit permissions and tag.
readonly ADMIN_DEF_DB="$SHARED_DIR/default-admins.json"
readonly -a ADMIN_PERMS=(
    "rr|Restart Round" "start|Start Match" "end|End Match" "endwarmup|End Warmup" "startwarmup|Start Warmup"
    "pausewarmup|Pause Warmup" "pause|Force Pause" "kniferound|Knife Round"
    "gag|Gag" "ungag|Ungag" "mute|Mute" "unmute|Unmute" "kick|Kick" "ban|Ban (this server only)" "unban|Unban"
    "slay|Slay" "slap|Slap" "respawn|Respawn" "move|Move Team" "rename|Rename Player" "spectate|Spectate" "plist|Player List"
    "addcash|Add Cash" "cash|Set Cash" "give|Give Weapons" "bh|BunnyHop" "ff|Friendly Fire" "t|All Talk" "hs|Headshot Only"
    "casual|Casual" "comp|Competitive" "dm|Deathmatch" "mix|Mix" "aim|Aim" "prac|Practice" "retakes|Retakes" "warmup|Warmup"
    "map|Change Map" "wmap|Workshop Map" "maxrounds|Max Rounds" "freezetime|Freeze Time" "bot|Bots" "lock|Lock Teams"
    "rcon|RCON" "asay|Admin Say" "votekick|Vote Kick" "admincmd|Admin Command Menu" "addadmin|Add Admin" "adminsp|Admin Permissions"
)
readonly ADMIN_NEW_DEFAULT_PERMS="plist kick gag ungag mute unmute map spectate slap slay respawn move admincmd votekick"
readonly ADMIN_OWNER_DEFAULT="76561198768187147"

admin_cfgdir() { printf '%s/%s/addons/counterstrikesharp/configs' "$S_PATH" "$CSGOREL"; }

admin_def_ok() {
    [[ -f $ADMIN_DEF_DB ]] || printf '[]\n' >"$ADMIN_DEF_DB" 2>/dev/null || return 1
    jq -e 'type=="array"' "$ADMIN_DEF_DB" >/dev/null 2>&1 || { err "$ADMIN_DEF_DB is not a valid JSON array."; return 1; }
}

admin_owner_ids() {   # first server's plugin config, else the built-in owner
    local id f oids=""
    while IFS= read -r id; do
        load_server "$id" || continue
        f="$(admin_cfgdir)/plugins/ServerCommands/ServerCommands.json"
        [[ -f $f ]] && oids=$(jq -r '(.OwnerSteamIds // [])[]' "$f" 2>/dev/null)
        [[ -n $oids ]] && break
    done < <(jq -r '.[].id' "$DB")
    printf '%s\n' "${oids:-$ADMIN_OWNER_DEFAULT}"
}

# admin_write_server <server id> <identity> <name> <immunity> <tag> <enabled true|false> <flags json array>
admin_write_server() {
    local sid=$1 ident=$2 name=$3 im=$4 tag=$5 en=$6 fl=$7 dir meta adm tmp
    load_server "$sid" || return 1
    safe_server_path "$S_PATH" "$S_SLUG" || return 1
    dir=$(admin_cfgdir)
    [[ -L $dir ]] && return 1
    mkdir -p -- "$dir" || return 1
    meta="$dir/ServerCommandsAdmins.json"; adm="$dir/admins.json"
    [[ -L $meta || -L $adm ]] && return 1
    [[ -f $meta ]] || printf '[]\n' >"$meta"
    [[ -f $adm ]] || printf '{}\n' >"$adm"
    jq -e 'type=="array"' "$meta" >/dev/null 2>&1 || { warn "$S_NAME: ServerCommandsAdmins.json is not valid; skipped."; return 1; }
    jq -e 'type=="object"' "$adm" >/dev/null 2>&1 || { warn "$S_NAME: admins.json is not valid; skipped."; return 1; }
    tmp=$(mktemp "$dir/.adm.XXXXXX") || return 1
    jq --arg id "$ident" --arg n "$name" --argjson im "$im" --arg tag "$tag" --argjson en "$en" --argjson fl "$fl" \
        '(if any(.[]; .Identity == $id) then map(if .Identity == $id then .Name=$n | .Immunity=$im | .Tag=$tag | .Enabled=$en | .Flags=$fl else . end)
          else . + [{Identity:$id, Name:$n, Immunity:$im, Flags:$fl, Tag:$tag, Enabled:$en}] end)' "$meta" >"$tmp" \
        && mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
    tmp=$(mktemp "$dir/.adm.XXXXXX") || return 1
    jq --arg id "$ident" --arg n "$name" --argjson im "$im" --argjson en "$en" --argjson fl "$fl" \
        'with_entries(select((.value.identity // "") != $id))
         | if $en then (. + {((if has($n) then ($n + "_" + $id[-4:]) else $n end)): {identity:$id, immunity:$im, flags:$fl}}) else . end' "$adm" >"$tmp" \
        && mv -f -- "$tmp" "$adm" || { rm -f -- "$tmp"; return 1; }
    chown "$CS2_USER:$CS2_GROUP" -- "$meta" "$adm" 2>/dev/null
    is_running "$sid" && console_send "$sid" "css_sc_reload" >/dev/null 2>&1
    return 0
}

admin_remove_server() {   # <server id> <identity>
    local sid=$1 ident=$2 dir meta adm tmp
    load_server "$sid" || return 0
    dir=$(admin_cfgdir); meta="$dir/ServerCommandsAdmins.json"; adm="$dir/admins.json"
    if [[ -f $meta && ! -L $meta ]] && jq -e 'type=="array"' "$meta" >/dev/null 2>&1; then
        tmp=$(mktemp "$dir/.adm.XXXXXX") && jq --arg id "$ident" 'map(select(.Identity != $id))' "$meta" >"$tmp" && mv -f -- "$tmp" "$meta" || rm -f -- "$tmp"
    fi
    if [[ -f $adm && ! -L $adm ]] && jq -e 'type=="object"' "$adm" >/dev/null 2>&1; then
        tmp=$(mktemp "$dir/.adm.XXXXXX") && jq --arg id "$ident" 'with_entries(select((.value.identity // "") != $id))' "$adm" >"$tmp" && mv -f -- "$tmp" "$adm" || rm -f -- "$tmp"
    fi
    chown "$CS2_USER:$CS2_GROUP" -- "$meta" "$adm" 2>/dev/null
    is_running "$sid" && console_send "$sid" "css_sc_reload" >/dev/null 2>&1
    return 0
}

# Pushes every default admin to every server (or just <sid>), so new servers get them too.
admins_deploy_defaults() {   # [quiet] [only server id]
    local quiet=${1:-} only=${2:-} sid row n=0
    [[ -f $ADMIN_DEF_DB ]] && jq -e 'type=="array" and length > 0' "$ADMIN_DEF_DB" >/dev/null 2>&1 || return 0
    while IFS= read -r sid; do
        [[ -n $only && $sid != "$only" ]] && continue
        while IFS= read -r row; do
            admin_write_server "$sid" "$(jq -r .identity <<<"$row")" "$(jq -r .name <<<"$row")" "$(jq -r '.immunity // 50' <<<"$row")" \
                "$(jq -r '.tag // "ADMIN"' <<<"$row")" "$(jq -r '(.enabled // true)' <<<"$row")" "$(jq -c '.flags // []' <<<"$row")" && n=$((n + 1))
        done < <(jq -c '.[]' "$ADMIN_DEF_DB")
    done < <(jq -r '.[].id' "$DB")
    [[ $quiet == quiet ]] || info "Default admins written ($n entries)."
    return 0
}

# Fills A_IDS[] and A_NAME/A_TAG/A_EN/A_IM/A_FL (from the first server that has him) and A_SRV (server ids, comma separated)
declare -A A_NAME=() A_TAG=() A_EN=() A_IM=() A_FL=() A_SRV=() A_DEF=()
declare -a A_IDS=()
admins_scan() {
    local sid f ident
    A_IDS=(); A_NAME=(); A_TAG=(); A_EN=(); A_IM=(); A_FL=(); A_SRV=(); A_DEF=()
    while IFS= read -r sid; do
        load_server "$sid" || continue
        f="$(admin_cfgdir)/ServerCommandsAdmins.json"
        [[ -f $f ]] || continue
        while IFS=$'\t' read -r ident name tag en im fl; do
            [[ -n $ident ]] || continue
            if [[ -z ${A_NAME[$ident]+x} ]]; then
                A_IDS+=("$ident"); A_NAME[$ident]=$name; A_TAG[$ident]=$tag; A_EN[$ident]=$en; A_IM[$ident]=$im; A_FL[$ident]=$fl
            fi
            A_SRV[$ident]+="${A_SRV[$ident]:+,}$sid"
        done < <(jq -r '.[] | [.Identity, (.Name // ""), (.Tag // ""), ((.Enabled // true) | tostring), ((.Immunity // 0) | tostring), ((.Flags // []) | tostring)] | @tsv' "$f" 2>/dev/null)
    done < <(jq -r '.[].id' "$DB")
    if [[ -f $ADMIN_DEF_DB ]]; then
        while IFS= read -r ident; do A_DEF[$ident]=1; done < <(jq -r '.[].identity' "$ADMIN_DEF_DB" 2>/dev/null)
    fi
}

admin_scope_arg() { if [[ -n ${A_DEF[$1]+x} ]]; then printf ALL; else printf '%s' "${A_SRV[$1]:-}"; fi; }

admin_scope_text() {   # <identity>
    local ident=$1 total
    total=$(jq 'length' "$DB")
    if [[ -n ${A_DEF[$ident]+x} ]]; then printf 'ALL servers (default admin)'
    elif [[ -n ${A_SRV[$ident]+x} ]]; then
        if [[ $(tr ',' '\n' <<<"${A_SRV[$ident]}" | wc -l) -ge $total ]]; then printf 'all servers (set per server)'
        else printf 'server ID %s only' "${A_SRV[$ident]}"; fi
    else printf '-'; fi
}

# keep the default-admin registry in step with a changed admin
admin_def_set() {   # <identity> <name> <immunity> <tag> <enabled> <flags json>
    admin_def_ok || return 1
    json_update "$ADMIN_DEF_DB" --arg id "$1" --arg n "$2" --argjson im "$3" --arg tag "$4" --argjson en "$5" --argjson fl "$6" \
        '(map(select(.identity != $id))) + [{identity:$id, name:$n, immunity:$im, tag:$tag, enabled:$en, flags:$fl}]' >/dev/null
}
admin_def_del() { admin_def_ok && json_update "$ADMIN_DEF_DB" --arg id "$1" 'map(select(.identity != $id))' >/dev/null; }

# apply the stored values of <identity> to all servers that should have him
admin_push() {   # <identity> <csv of server ids | ALL>
    local ident=$1 scope=$2 sid
    local -a ids=()
    if [[ $scope == ALL ]]; then mapfile -t ids < <(jq -r '.[].id' "$DB"); else IFS=, read -ra ids <<<"$scope"; fi
    for sid in "${ids[@]}"; do
        admin_write_server "$sid" "$ident" "${A_NAME[$ident]}" "${A_IM[$ident]}" "${A_TAG[$ident]}" "${A_EN[$ident]}" "${A_FL[$ident]}" \
            || warn "Server $sid: could not write the admin."
    done
    if [[ -n ${A_DEF[$ident]+x} ]]; then admin_def_set "$ident" "${A_NAME[$ident]}" "${A_IM[$ident]}" "${A_TAG[$ident]}" "${A_EN[$ident]}" "${A_FL[$ident]}"; fi
}

admin_perm_ui() {   # <identity>
    local ident=$1 c i p label has
    while :; do
        header "PERMISSIONS: ${A_NAME[$ident]}"
        i=0
        for p in "${ADMIN_PERMS[@]}"; do
            i=$((i + 1)); label=${p#*|}
            has=" "; jq -e --arg f "@nepentii/${p%%|*}" 'index($f) != null' <<<"${A_FL[$ident]}" >/dev/null 2>&1 && has="x"
            printf '  [%s] %2d) %s\n' "$has" "$i" "$label"
        done
        echo
        echo "  Type numbers to toggle (e.g. 1 5 9), a = all, n = none, s = save, b = cancel"
        read -r -p "Select: " c || exit 0
        c=$(trim "$c")
        case $c in
            b|B|q|Q) return 1 ;;
            s|S) return 0 ;;
            a|A) A_FL[$ident]=$(printf '%s\n' "${ADMIN_PERMS[@]}" | jq -R '"@nepentii/" + split("|")[0]' | jq -sc .) ;;
            n|N) A_FL[$ident]='[]' ;;
            *)
                for i in $c; do
                    [[ $i =~ ^[0-9]+$ ]] && ((10#$i >= 1 && 10#$i <= ${#ADMIN_PERMS[@]})) || continue
                    p=${ADMIN_PERMS[10#$i - 1]}
                    A_FL[$ident]=$(jq -c --arg f "@nepentii/${p%%|*}" 'if index($f) != null then map(select(. != $f)) else . + [$f] end' <<<"${A_FL[$ident]}")
                done ;;
        esac
    done
}

admin_detail_ui() {   # <identity>
    local ident=$1 c owners sid
    owners=$(admin_owner_ids)
    while :; do
        admins_scan
        [[ -n ${A_NAME[$ident]+x} || -n ${A_DEF[$ident]+x} ]] || { warn "That admin no longer exists."; return; }
        [[ -n ${A_NAME[$ident]+x} ]] || { A_NAME[$ident]=$(jq -r --arg i "$ident" '.[]|select(.identity==$i)|.name' "$ADMIN_DEF_DB"); }
        header "ADMIN: ${A_NAME[$ident]}"
        printf '  SteamID64   : %s\n' "$ident"
        printf '  Tag         : %s\n' "${A_TAG[$ident]:-(none)}"
        printf '  Enabled     : %s\n' "${A_EN[$ident]:-true}"
        printf '  Servers     : %s\n' "$(admin_scope_text "$ident")"
        printf '  Permissions : %s\n' "$(jq -r 'length' <<<"${A_FL[$ident]:-[]}") of ${#ADMIN_PERMS[@]}"
        grep -qx "$ident" <<<"$owners" && printf '  %sOwner: always has every permission and cannot be removed here.%s\n' "$YELLOW" "$RESET"
        echo
        echo "  1) Make DEFAULT admin (all servers, also new servers)"
        echo "  2) Admin only on selected servers"
        echo "  3) Edit permissions"
        echo "  4) Change tag"
        echo "  5) Enable / disable"
        echo "  6) Remove this admin from all servers"
        echo "  7) Back"
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) A_DEF[$ident]=1
               admin_push "$ident" ALL; ok "${A_NAME[$ident]} is now an admin on every server."; pause ;;
            2) prompt_server_ids "Servers where he is admin" "${A_SRV[$ident]:--}" 1 || continue
               admin_def_del "$ident"
               for sid in $(jq -r '.[].id' "$DB"); do
                   [[ ,$IDS_CSV, == *",$sid,"* ]] || admin_remove_server "$sid" "$ident"
               done
               unset 'A_DEF[$ident]'
               admin_push "$ident" "$IDS_CSV"; ok "Done: admin only on server(s) $IDS_CSV."; pause ;;
            3) if grep -qx "$ident" <<<"$owners"; then warn "Owners always have everything."; sleep 1; continue; fi
               if admin_perm_ui "$ident"; then
                   admin_push "$ident" "$(admin_scope_arg "$ident")"; ok "Permissions saved."; pause
               fi ;;
            4) ask "New tag (max 16 characters, empty = none)" "${A_TAG[$ident]}" || continue
               A_TAG[$ident]=$(printf '%s' "$ANSWER" | tr -d '[]|' | cut -c1-16)
               admin_push "$ident" "$(admin_scope_arg "$ident")"; ok "Tag saved."; pause ;;
            5) if grep -qx "$ident" <<<"$owners"; then warn "Owners cannot be disabled."; sleep 1; continue; fi
               if [[ ${A_EN[$ident]:-true} == true ]]; then A_EN[$ident]=false; else A_EN[$ident]=true; fi
               admin_push "$ident" "$(admin_scope_arg "$ident")"; ok "Updated."; pause ;;
            6) if grep -qx "$ident" <<<"$owners"; then warn "Owners cannot be removed."; sleep 1; continue; fi
               confirm_yn "Remove ${A_NAME[$ident]} from ALL servers? [y/N]: " n || continue
               admin_def_del "$ident"
               for sid in $(jq -r '.[].id' "$DB"); do admin_remove_server "$sid" "$ident"; done
               ok "Removed."; pause; return ;;
            7|b|B|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

admin_add_ui() {
    local ident name tag="ADMIN" fl
    ask "SteamID64 of the new admin (q = cancel)" || return
    ident=$ANSWER
    [[ $ident =~ ^7656[0-9]{13}$ ]] || { err "That is not a SteamID64 (17 digits starting with 7656)."; return; }
    ask "Name (for the lists)" "Admin_${ident: -4}" || return
    name=$(printf '%s' "$ANSWER" | tr -d '"\\' | cut -c1-32)
    echo
    echo "  1) Default admin: ALL servers (also servers created later)"
    echo "  2) Selected servers only"
    ask "Choice" "2" || return
    fl=$(printf '%s\n' $ADMIN_NEW_DEFAULT_PERMS | jq -R '"@nepentii/" + .' | jq -sc .)
    admins_scan
    A_NAME[$ident]=$name; A_TAG[$ident]=$tag; A_EN[$ident]=true; A_IM[$ident]=50; A_FL[$ident]=$fl
    if [[ $ANSWER == 1 ]]; then
        A_DEF[$ident]=1
        admin_push "$ident" ALL
        ok "$name is a default admin on every server (basic permissions; change them in the next screen)."
    else
        prompt_server_ids "Servers where he is admin" "-" 1 || return
        admin_push "$ident" "$IDS_CSV"
        ok "$name is admin on server(s) $IDS_CSV."
    fi
    pause
    admin_detail_ui "$ident"
}

admins_menu() {
    local c i idx ident
    local -a order=()
    admin_def_ok || { pause; return; }
    while :; do
        header "ADMINS"
        admins_scan
        for ident in $(jq -r '.[].identity' "$ADMIN_DEF_DB" 2>/dev/null); do
            [[ -n ${A_NAME[$ident]+x} ]] || { A_IDS+=("$ident"); A_NAME[$ident]=$(jq -r --arg i "$ident" '.[]|select(.identity==$i)|.name' "$ADMIN_DEF_DB"); A_TAG[$ident]=$(jq -r --arg i "$ident" '.[]|select(.identity==$i)|.tag' "$ADMIN_DEF_DB"); }
        done
        order=(); i=0
        if ((${#A_IDS[@]} == 0)); then echo "  No admins yet."; fi
        for ident in "${A_IDS[@]}"; do
            i=$((i + 1)); order[i]=$ident
            printf '  %2d) %-22s %-10s %s\n' "$i" "${A_NAME[$ident]}" "${A_TAG[$ident]:+| ${A_TAG[$ident]} |}" "$(admin_scope_text "$ident")"
        done
        echo
        echo "  Admins added in-game with /addadmin belong to that server only."
        echo "  Choose a number to make him a default admin (all servers), limit him to chosen servers or edit permissions."
        echo
        echo "  a) Add an admin by SteamID64     r) Refresh     b) Back"
        read -r -p "Select: " c || exit 0
        c=$(trim "$c")
        case $c in
            a|A) admin_add_ui ;;
            r|R) continue ;;
            b|B|q|Q) return ;;
            *) [[ $c =~ ^[0-9]+$ ]] && ((10#$c >= 1 && 10#$c <= i)) || { err "Invalid option."; sleep 1; continue; }
               idx=$((10#$c)); admin_detail_ui "${order[idx]}" ;;
        esac
    done
}

# ------------------------------- Live resource monitor -----------------------
# One screen, every server at once: CPU, RAM, disk. Refreshes by itself.
mon_snapshot() {   # prints: pid ppid ticks rss_pages  (every process, one awk pass)
    awk '{ i = index($0, ") "); if (i == 0) next; r = substr($0, i + 2); split(r, a, " ");
           printf "%s %s %d %s\n", $1, a[2], a[12] + a[13], a[22] }' /proc/[0-9]*/stat 2>/dev/null
}

# mon_sum <snapshot file> <root pid>  -> "ticks rss_pages" of the root and all its descendants
mon_sum() {
    awk -v root="$2" '{ par[$1] = $2; t[$1] = $3; r[$1] = $4 }
        END { for (p in par) { q = p; n = 0; while (q != "" && q != 0 && n++ < 64) { if (q == root) { T += t[p]; R += r[p]; break } q = par[q] } }
              printf "%d %d\n", T, R }' "$1"
}

mon_bar() {   # <percent 0-100> <width>
    local pct=$1 w=$2 n i out=""
    n=$(awk -v p="$pct" -v w="$w" 'BEGIN{ if (p > 100) p = 100; if (p < 0) p = 0; printf "%d", p * w / 100 + 0.5 }')
    for ((i = 0; i < w; i++)); do ((i < n)) && out+="#" || out+="."; done
    printf '%s' "$out"
}

mon_color() {   # <percent> -> colour escape
    awk -v p="$1" -v r="$RED" -v y="$YELLOW" -v g="$GREEN" 'BEGIN{ printf "%s", (p >= 85 ? r : (p >= 60 ? y : g)) }'
}

monitor_ui() {
    local interval=2 tick page cores snap now prev_now="" key i
    local id name path pid sess t r cpu ramkb ramp
    local -A prev_ticks=() disk_mb=() disk_at=()
    local cpu_a cpu_b tot_a idle_a tot_b idle_b sys_cpu="0"
    tick=$(getconf CLK_TCK 2>/dev/null || echo 100); page=$(getconf PAGESIZE 2>/dev/null || echo 4096)
    cores=$(nproc 2>/dev/null || echo 1)
    snap=$(mktemp) || return
    local -a rows=()
    mapfile -t rows < <(jq -r '.[] | [.id, .name, .path] | @tsv' "$DB" 2>/dev/null)
    if ((${#rows[@]} == 0)); then warn "No servers yet."; rm -f "$snap"; return; fi
    printf '\033[?25l'
    clear_screen
    read -r tot_a idle_a < <(awk '/^cpu /{ tot = 0; for (i = 2; i <= NF; i++) tot += $i; print tot, $5 + $6 }' /proc/stat)
    while :; do
        now=${EPOCHREALTIME/[.,]/}   # microseconds
        mon_snapshot >"$snap"
        local memtot memavail memused memp load dfline dfp
        memtot=$(awk '/^MemTotal:/{print $2}' /proc/meminfo); memavail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
        memused=$((memtot - memavail)); memp=$((memused * 100 / (memtot > 0 ? memtot : 1)))
        read -r tot_b idle_b < <(awk '/^cpu /{ tot = 0; for (i = 2; i <= NF; i++) tot += $i; print tot, $5 + $6 }' /proc/stat)
        if ((tot_b > tot_a)); then sys_cpu=$(( (100 * ((tot_b - tot_a) - (idle_b - idle_a))) / (tot_b - tot_a) )); fi
        tot_a=$tot_b; idle_a=$idle_b
        load=$(cut -d' ' -f1-3 /proc/loadavg)
        dfline=$(df -P -BM "$SERVERS_DIR" 2>/dev/null | awk 'NR==2{gsub("M","",$2); gsub("M","",$3); gsub("M","",$4); gsub("%","",$5); print $2, $3, $4, $5}')
        printf '\033[H'
        printf '%s  CS2NEXUS - LIVE RESOURCE MONITOR%s   (refresh %ss - press q or Enter to go back)\033[K\n' "$BOLD" "$RESET" "$interval"
        sep
        printf '  SYSTEM  CPU %s%3d%%%s [%s]  (%s cores)   load %s\033[K\n' "$(mon_color "$sys_cpu")" "$sys_cpu" "$RESET" "$(mon_bar "$sys_cpu" 20)" "$cores" "$load"
        printf '          RAM %s%3d%%%s [%s]  %s / %s MB\033[K\n' "$(mon_color "$memp")" "$memp" "$RESET" "$(mon_bar "$memp" 20)" "$((memused / 1024))" "$((memtot / 1024))"
        if [[ -n $dfline ]]; then
            read -r dtot dused dfree dfp <<<"$dfline"
            printf '          DISK%s%3d%%%s [%s]  %s used, %s free (of %s MB)\033[K\n' "$(mon_color "$dfp")" " $dfp" "$RESET" "$(mon_bar "$dfp" 20)" "${dused}M" "${dfree}M" "$dtot"
        fi
        sep
        printf '  %-3s %-18s %-8s %9s  %-22s %-9s %s\033[K\n' "ID" "NAME" "STATUS" "CPU(1 core=100%)" "RAM" "DISK" ""
        local tc=0 tr=0 td=0 online=0
        for i in "${!rows[@]}"; do
            IFS=$'\t' read -r id name path <<<"${rows[i]}"
            sess=$(session_name "$id")
            # disk: du is slow, so measure on first sight and then every 60 s
            if [[ -z ${disk_mb[$id]:-} || $(( (${now%??????} ) - ${disk_at[$id]:-0} )) -ge 60 ]]; then
                disk_mb[$id]=$(du -sm -- "$path" 2>/dev/null | cut -f1); disk_at[$id]=${now%??????}
            fi
            td=$((td + ${disk_mb[$id]:-0}))
            pid=$(tmux_cs2 list-panes -t "=$sess:" -F '#{pane_pid}' 2>/dev/null | head -n 1)
            if [[ -z $pid ]]; then
                printf '  %-3s %-18.18s %s%-8s%s %9s  %-22s %-9s\033[K\n' "$id" "$name" "$RED" "OFFLINE" "$RESET" "-" "-" "$(mon_fmt_mb "${disk_mb[$id]:-0}")"
                unset 'prev_ticks[$id]'
                continue
            fi
            online=$((online + 1))
            read -r t r < <(mon_sum "$snap" "$pid")
            cpu=0
            if [[ -n ${prev_ticks[$id]:-} && -n $prev_now ]] && ((now > prev_now)); then
                cpu=$(awk -v d="$((t - ${prev_ticks[$id]%% *}))" -v tk="$tick" -v us="$((now - prev_now))" 'BEGIN{ v = d / tk / (us / 1000000) * 100; if (v < 0) v = 0; printf "%.0f", v }')
            fi
            prev_ticks[$id]="$t"
            ramkb=$((r * page / 1024)); ramp=$((ramkb * 100 / (memtot > 0 ? memtot : 1)))
            tc=$((tc + cpu)); tr=$((tr + ramkb))
            printf '  %-3s %-18.18s %s%-8s%s %s%8s%%%s  %s%-8s%s [%s] %-9s\033[K\n' "$id" "$name" "$GREEN" "ONLINE" "$RESET" \
                "$(mon_color "$((cpu / cores))")" "$cpu" "$RESET" "$(mon_color "$ramp")" "$(mon_fmt_mb "$((ramkb / 1024))")" "$RESET" "$(mon_bar "$ramp" 10)" "$(mon_fmt_mb "${disk_mb[$id]:-0}")"
        done
        sep
        printf '  %s online | total CPU %s%% of 1 core (%s%% of the machine) | total RAM %s | server files %s\033[K\n' "$online" "$tc" "$((tc / cores))" "$(mon_fmt_mb "$((tr / 1024))")" "$(mon_fmt_mb "$td")"
        printf '  Disk = size of each server folder (shared plugin/base files are links and are not counted).\033[K\n'
        printf '\033[J'
        prev_now=$now
        if read -r -s -n1 -t "$interval" key; then
            [[ $key == q || $key == Q || -z $key ]] && break
        fi
    done
    rm -f "$snap"
    printf '\033[?25h'
}

mon_fmt_mb() {   # <MB> -> 812M / 3.4G
    awk -v m="${1:-0}" 'BEGIN{ if (m >= 1024) printf "%.1fG", m / 1024; else printf "%dM", m }'
}

main_menu() {
    local choice
    while :; do
        panel_installed && panel_export_servers
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
        echo "14) Admins"
        echo "15) Resource Monitor (CPU / RAM / disk, live)"
        echo "16) Web Panel (players' website)"
        echo "17) Exit"
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
            14) admins_menu ;;
            15) monitor_ui ;;
            16) panel_menu ;;
            17) clear_screen; echo "Goodbye."; exit 0 ;;
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
sv_allow_votes|Votes|b|1|Allow player votes
sv_vote_issue_kick_allowed|Votes|b|1|Allow vote-kick
sv_vote_issue_changelevel_allowed|Votes|b|1|Allow vote to change map
sv_vote_issue_restart_game_allowed|Votes|b|0|Allow vote to restart the game
sv_vote_issue_scramble_teams_allowed|Votes|b|0|Allow vote to scramble teams
mp_roundtime|Rounds & Match|f|1.92|Minutes per round
mp_roundtime_defuse|Rounds & Match|f|1.92|Minutes per round on defuse maps
mp_roundtime_hostage|Rounds & Match|f|1.92|Minutes per round on hostage maps
mp_freezetime|Rounds & Match|i|15|Freeze time at round start (seconds)
mp_buytime|Buy & Shop|i|20|Buy time (seconds)
mp_buy_anywhere|Buy & Shop|e:0,1,2,3|0|Buy anywhere (0 off, 1 both, 2 T, 3 CT)
mp_maxrounds|Rounds & Match|i|24|Rounds per match (0 = unlimited)
mp_timelimit|Rounds & Match|i|0|Map time limit in minutes (0 = none)
mp_halftime|Rounds & Match|b|1|Switch sides at halftime
mp_match_can_clinch|Rounds & Match|b|1|End match early when a team clinches
mp_do_warmup_period|Warmup|b|1|Enable warmup
mp_warmuptime|Warmup|i|30|Warmup length (seconds)
mp_warmup_pausetimer|Warmup|b|0|Pause the warmup timer
mp_startmoney|Economy & Armor|i|800|Starting money
mp_maxmoney|Economy & Armor|i|16000|Maximum money
mp_afterroundmoney|Economy & Armor|i|0|Money given to everyone after a round
mp_c4timer|Drops & C4|i|40|Bomb timer (seconds)
mp_round_restart_delay|Rounds & Match|i|7|Delay before the next round (seconds)
mp_win_panel_display_time|Rounds & Match|i|3|Win panel display time (seconds)
mp_ignore_round_win_conditions|Rounds & Match|b|0|Rounds never end by win conditions
mp_overtime_enable|Rounds & Match|b|0|Enable overtime
mp_overtime_maxrounds|Rounds & Match|i|6|Overtime rounds
mp_overtime_startmoney|Rounds & Match|i|10000|Overtime starting money
mp_respawn_on_death_t|Respawn & Spawns|b|0|Terrorists respawn after death
mp_respawn_on_death_ct|Respawn & Spawns|b|0|Counter-terrorists respawn after death
mp_free_armor|Economy & Armor|e:0,1,2|0|Free armor (1 kevlar, 2 kevlar+helmet)
mp_defuser_allocation|Economy & Armor|e:0,1,2|0|Free defuse kits (1 random CT, 2 all CT)
mp_death_drop_gun|Drops & C4|e:0,1,2|1|Drop weapon on death (0 none, 1 best, 2 current)
mp_death_drop_grenade|Drops & C4|e:0,1,2,3|2|Drop grenades on death (0 none, 1 best, 2 current, 3 all)
mp_weapons_allow_map_placed|Weapon Restrictions|b|1|Allow map placed weapons
mp_playercashawards|Economy & Armor|b|1|Cash awards for player actions
mp_teamcashawards|Economy & Armor|b|1|Cash awards for team results
mp_autoteambalance|Teams & Players|b|1|Automatic team balancing
mp_limitteams|Teams & Players|i|2|Max team size difference (0 = no limit)
mp_force_pick_time|Teams & Players|i|15|Seconds a player has to pick a team
mp_forcecamera|Teams & Players|e:0,1,2|1|Spectator camera (0 free, 1 team only, 2 first person)
mp_autokick|Teams & Players|b|1|Kick idle players and team killers
mp_friendlyfire|Teams & Players|b|0|Friendly fire
mp_solid_teammates|Teams & Players|e:0,1,2|1|Teammates are solid (0 no, 1 yes, 2 only after round)
mp_tkpunish|Teams & Players|b|0|Punish team killers next round
mp_spectators_max|Spectator|i|2|Maximum spectators
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
sv_human_autojoin_team|Teams & Players|i|0|Automatic team for human players (0 = they choose)
mp_humanteam|Teams & Players|e:any,CT,T|any|Restrict human players to one team
mp_teammates_are_enemies|Teams & Players|b|0|Teammates count as enemies (everyone is a valid target)
sv_spec_hear|Spectator|e:0,1,2,3,4|1|Who spectators hear (0 spectators, 1 all, 2 spectated team, 3 self, 4 nobody)
sv_talk_after_dying_time|Spectator|f|0|Seconds a player can still talk after dying
sv_auto_full_alltalk_during_warmup_half_end|Spectator|b|1|Full all-talk during warmup / halftime / match end
sv_chat_proximity|Voice & Chat|b|0|Proximity chat (where supported)
sv_voice_proximity|Voice & Chat|b|0|Proximity voice (where supported)
sv_vote_issue_timeout_allowed|Votes|b|1|Allow the Timeout vote
sv_vote_issue_nextlevel_allowed|Votes|b|1|Allow the Next Level vote
sv_vote_issue_nextlevel_allowextend|Votes|b|1|Allow extending the map through the next-level vote
sv_vote_issue_swap_teams_allowed|Votes|b|0|Allow the Swap Teams vote
sv_vote_issue_surrrender_allowed|Votes|b|1|Allow the Surrender vote (the ConVar really is spelled surrrender)
sv_vote_issue_pause_match_allowed|Votes|b|1|Allow the Pause / Unpause vote
sv_vote_issue_matchready_allowed|Votes|b|1|Allow the Match Ready / Unready vote
sv_vote_issue_loadbackup_allowed|Votes|b|1|Allow the Load Backup vote
sv_vote_issue_pause_match_spec_only|Votes|b|0|Restrict pause voting to spectators
sv_vote_quorum_ratio|Votes|f|0.501|Share of players needed for a vote to resolve
sv_vote_creation_timer|Votes|i|120|Seconds between votes
sv_vote_allow_spectators|Votes|b|0|Spectators may take part in votes
sv_vote_count_spectator_votes|Votes|b|0|Spectator votes count
mp_team_timeout_max|Timeouts|i|1|Team timeouts per match (0 = none)
mp_team_timeout_time|Timeouts|i|30|Length of a team timeout (seconds)
mp_technical_timeout_per_team|Timeouts|i|2|Technical timeouts per team (0 = none)
mp_technical_timeout_duration_s|Timeouts|i|600|Technical timeout length (seconds)
mp_buy_during_immunity|Buy & Shop|b|0|Players can buy during spawn immunity
mp_buy_allow_guns|Buy & Shop|i|63|Gun categories that can be bought (bitmask: 1 pistols, 2 SMGs, 4 rifles, 8 shotguns, 16 snipers, 32 heavy MG; 0 none, 63 all)
mp_buy_allow_grenades|Buy & Shop|b|1|Grenades can be bought
sv_buy_status_override|Buy & Shop|e:0,1,2,3|0|Who can buy (0 everyone, 1 CT only, 2 T only, 3 nobody)
mp_weapons_allow_pistols|Weapon Restrictions|e:-1,0,2,3|-1|Pistols allowed for (-1 both teams, 0 nobody, 2 T, 3 CT)
mp_weapons_allow_smgs|Weapon Restrictions|e:-1,0,2,3|-1|SMGs allowed for (-1 both, 0 nobody, 2 T, 3 CT)
mp_weapons_allow_rifles|Weapon Restrictions|e:-1,0,2,3|-1|Rifles allowed for (-1 both, 0 nobody, 2 T, 3 CT)
mp_weapons_allow_heavy|Weapon Restrictions|e:-1,0,2,3|-1|Heavy weapons allowed for (-1 both, 0 nobody, 2 T, 3 CT)
mp_weapons_allow_zeus|Weapon Restrictions|i|1|Zeus purchases per round (0 none, -1 unlimited)
mp_weapons_allow_typecount|Weapon Restrictions|i|5|Purchases per weapon type per player and round (0 none, -1 unlimited)
mp_weapons_max_gun_purchases_per_weapon_per_match|Weapon Restrictions|i|-1|Purchases of any one weapon per match (-1 = no limit)
mp_weapons_allow_heavyassaultsuit|Weapon Restrictions|b|0|Heavy assault suit can be used
mp_heavyassaultsuit_cooldown|Weapon Restrictions|i|0|Heavy assault suit purchase cooldown
mp_items_prohibited|Weapon Restrictions|s|9,40|Comma-separated weapon definition indices that are banned (verify the index first)
mp_death_drop_c4|Drops & C4|b|1|Drop the C4 on death
mp_death_drop_defuser|Drops & C4|b|1|Drop the defuse kit on death
mp_death_drop_taser|Drops & C4|b|1|Drop the Zeus on death
mp_death_drop_breachcharge|Drops & C4|b|1|Drop the breach charge on death
mp_death_drop_healthshot|Drops & C4|b|1|Drop the healthshot on death
mp_warmup_items_drop_policy|Drops & C4|i|247|Warmup item drops (bitfield: 1 gun, 2 C4, 4 grenade, 8 defuser, 16 taser, 32 healthshot)
mp_anyone_can_pickup_c4|Drops & C4|b|0|Anyone can pick up the C4
mp_c4_cannot_be_defused|Drops & C4|b|0|The planted C4 cannot be defused
mp_max_armor|Economy & Armor|e:0,1,2|2|Highest armor level that can be bought (0 none, 1 kevlar, 2 kevlar+helmet)
mp_economy_reset_rounds|Economy & Armor|i|0|Reset all money every N rounds (0 = never)
mp_equipment_reset_rounds|Economy & Armor|i|0|Reset equipment every N rounds (0 = never)
mp_damage_headshot_only|Damage & Health|b|0|Only headshots deal damage
mp_damage_scale_t_head|Damage & Health|f|1.0|Head damage multiplier against Terrorists
mp_weapon_self_inflict_amount|Damage & Health|f|0|Self damage for missed shots
mp_damage_vampiric_amount|Damage & Health|f|0|Share of dealt damage returned as health
mp_global_damage_per_second|Damage & Health|f|0|Non-lethal damage to everyone every second
ff_damage_decoy_explosion|Damage & Health|f|0|Team damage from decoy explosions
mp_winlimit|Rounds & Match|i|0|Win limit (0 = off)
mp_match_restart_delay|Rounds & Match|i|15|Seconds before the match restarts
mp_join_grace_time|Rounds & Match|i|0|Seconds after round start during which players may join
mp_warmup_online_enabled|Warmup|b|1|Warmup on online servers (needed for warmup to run on a dedicated server)
mp_warmup_offline_enabled|Warmup|b|0|Warmup in offline/bot games
mp_warmup_items_nocost|Warmup|b|0|Free weapons during warmup
mp_warmup_items_nocount_policy|Warmup|i|42|Warmup unlimited-item bitfield
mp_warmup_jointeam_cooldown|Warmup|i|2|Team join cooldown during warmup (seconds)
mp_warmuptime_all_players_connected|Warmup|i|15|Warmup length once all players are connected (the game modes shorten warmup to this)
mp_use_respawn_waves|Respawn & Spawns|e:0,1,2|0|Respawn waves (1 in waves, 2 when the whole team is dead)
mp_respawnwavetime_ct|Respawn & Spawns|i|10|CT respawn wave interval (seconds)
mp_respawnwavetime_t|Respawn & Spawns|i|10|T respawn wave interval (seconds)
mp_respawn_immunitytime|Respawn & Spawns|f|0|Spawn immunity (seconds)
mp_randomspawn|Respawn & Spawns|e:0,1,2,3|0|Random spawns (1 both, 2 T, 3 CT)
mp_randomspawn_los|Respawn & Spawns|b|0|Line-of-sight check for random spawns
mp_randomspawn_dist|Respawn & Spawns|i|0|Distance check for random spawns
ammo_grenade_limit_flashbang|Grenades & Ammo|i|2|Flashbang limit
ammo_grenade_limit_total|Grenades & Ammo|i|4|Total grenade limit
sv_grenade_trajectory_prac_trailtime|Grenades & Ammo|f|0|Practice grenade trail time (seconds)
sv_grenade_trajectory_prac_pipreview|Grenades & Ammo|b|0|Practice grenade trajectory preview
sv_falldamage_to_below_player_ratio|Movement & Weapons|f|0|Damage ratio when landing on another player's head
sv_falldamage_to_below_player_multiplier|Movement & Weapons|f|0|Multiplier for the damage players below take
bot_allow_pistols|Bots|b|1|Bots may use pistols
bot_allow_shotguns|Bots|b|1|Bots may use shotguns
bot_allow_sub_machine_guns|Bots|b|1|Bots may use SMGs
bot_allow_rifles|Bots|b|1|Bots may use rifles
bot_allow_machine_guns|Bots|b|1|Bots may use machine guns
bot_allow_grenades|Bots|b|1|Bots may use grenades
bot_allow_snipers|Bots|b|1|Bots may use sniper rifles
bot_join_team|Bots|e:any,T,CT|any|Team the bots join
mp_endmatch_votenextmap|Map Voting|b|1|End-of-match next-map vote
mp_endmatch_votenextmap_keepcurrent|Map Voting|b|1|Keep the current map as an option in that vote
mp_endmatch_votenextleveltime|Map Voting|i|20|Length of the end-of-match vote (seconds)
nextlevel|Map Voting|s|de_dust2|Next map
mapcyclefile|Map Voting|s|mapcycle.txt|Map cycle file
mp_backup_round_auto|Backup & Pause|b|1|Keep in-memory round backups
mp_backup_round_file|Backup & Pause|s|backup|Round backup file name
mp_backup_round_file_pattern|Backup & Pause|s|pattern|Round backup file name pattern
mp_backup_restore_load_autopause|Backup & Pause|b|1|Pause automatically after restoring a backup
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
shop_open|Shop: whole shop (sv_buy_status_override)|persist|sv_buy_status_override 0|sv_buy_status_override 3
shop_guns|Shop: buying guns (mp_buy_allow_guns)|persist|mp_buy_allow_guns 255|mp_buy_allow_guns 0
shop_grenades|Shop: buying grenades (mp_buy_allow_grenades)|persist|mp_buy_allow_grenades 1|mp_buy_allow_grenades 0
shop_pistols|Weapons allowed: pistols|persist|mp_weapons_allow_pistols -1|mp_weapons_allow_pistols 0
shop_smgs|Weapons allowed: SMGs|persist|mp_weapons_allow_smgs -1|mp_weapons_allow_smgs 0
shop_rifles|Weapons allowed: rifles|persist|mp_weapons_allow_rifles -1|mp_weapons_allow_rifles 0
shop_heavy|Weapons allowed: heavy (shotguns, machine guns)|persist|mp_weapons_allow_heavy -1|mp_weapons_allow_heavy 0
shop_zeus|Weapons allowed: Zeus|persist|mp_weapons_allow_zeus 1|mp_weapons_allow_zeus 0
swap_teams|Swap teams|oneshot|mp_swapteams 1|mp_swapteams 0
scramble_teams|Scramble teams|oneshot|mp_scrambleteams 1|mp_scrambleteams 0
EOF
}

catalog_load() {
    ((CATALOG_LOADED)) && return 0
    local k c t h d n l on off
    while IFS='|' read -r k c t h d; do
        [[ -n $k ]] || continue
        [[ -n ${CAT_TYPE[$k]+x} ]] && continue
        CAT_KEYS+=("$k"); CAT_TYPE[$k]=$t; CAT_CAT[$k]=$c; CAT_HINT[$k]=$h; CAT_DESC[$k]=$d
        [[ " ${CAT_CATS[*]} " == *" ${c// /_} "* ]] || CAT_CATS+=("${c// /_}")
    done < <(catalog_rows)
    # fixed, sensible category order (unknown categories stay at the end)
    local o; local -a ordered=()
    for o in General Teams_\&_Players Rounds_\&_Match Warmup Buy_\&_Shop Economy_\&_Armor Weapon_Restrictions Drops_\&_C4 Damage_\&_Health \
             Respawn_\&_Spawns Grenades_\&_Ammo Movement_\&_Weapons Voice_\&_Chat Votes Spectator Timeouts Bots Map_Voting Backup_\&_Pause \
             Clients_\&_Network GOTV Logging; do
        [[ " ${CAT_CATS[*]} " == *" $o "* ]] && ordered+=("$o")
    done
    for o in "${CAT_CATS[@]}"; do [[ " ${ordered[*]} " == *" $o "* ]] || ordered+=("$o"); done
    CAT_CATS=("${ordered[@]}")
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
        printf '%s\n' "$SETTINGS_DEFAULT_JSON" >"$SETTINGS_DB"
        chmod 600 "$SETTINGS_DB"
    fi
    if ! jq -e 'type=="array"' "$SETTINGS_DB" >/dev/null 2>&1; then
        if ! repair_json_array "$SETTINGS_DB" "server settings file" "$SETTINGS_DEFAULT_JSON"; then
            SETTINGS_OK=0
            warn "$SETTINGS_DB is not a valid JSON array. Server settings are disabled until it is fixed."
        fi
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
    admins_deploy_defaults quiet "$id"
    aliases_deploy quiet
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

st_cfg_refresh() { if (($1 > 0)) && load_server "$1"; then write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$1" >/dev/null 2>&1; fi; return 0; }

st_mode_ui() {   # <id>: game mode + round time + warmup
    local id=$1 c gt gm v
    local -a presets=("Casual|0|0" "Competitive|0|1" "Wingman|0|2" "Arms Race|1|0" "Demolition|1|1" "Deathmatch|1|2")
    while :; do
        header "GAME MODE, ROUND TIME & WARMUP"
        gt=$(launch_value "$id" game_type 0); gm=$(launch_value "$id" game_mode 1)
        printf '  Game mode  : game_type %s / game_mode %s\n' "$gt" "$gm"
        printf '  Round time : %s minutes (mp_roundtime)\n' "$(st_get "$id" | jq -r '.cvars.mp_roundtime // "game default"')"
        printf '  Warmup     : %s\n\n' "$(st_get "$id" | jq -r 'if .cvars.mp_do_warmup_period == "0" then "disabled" elif .cvars.mp_warmuptime then (.cvars.mp_warmuptime + " seconds") else "game default" end')"
        echo "  1) Game mode (applies after a restart)"
        echo "  2) Round time (minutes per round)"
        echo "  3) Warmup time (seconds before the match starts, 0 = no warmup)"
        echo "  4) Back"
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
                st_cfg_refresh "$id"
                sleep 1 ;;
            3)
                ask "Warmup time in seconds (0 = no warmup, max 3600)" "30" || continue
                if ! [[ $ANSWER =~ ^[0-9]{1,4}$ ]] || ((10#$ANSWER > 3600)); then err "Enter a whole number between 0 and 3600."; sleep 1; continue; fi
                v=$((10#$ANSWER))
                if ((v == 0)); then
                    st_update "$id" '.cvars.mp_do_warmup_period = "0" | .cvars.mp_warmuptime = "0" | .cvars.mp_warmuptime_all_players_connected = "0"' >/dev/null && ok "Warmup disabled."
                else
                    # the game modes also shorten warmup once everyone is connected, and online warmup must be enabled
                    st_update "$id" '.cvars.mp_do_warmup_period = "1" | .cvars.mp_warmup_online_enabled = "1" | .cvars.mp_warmuptime = $v | .cvars.mp_warmuptime_all_players_connected = $v' --arg v "$v" >/dev/null && ok "Warmup time set to $v seconds."
                fi
                st_cfg_refresh "$id"
                ((id > 0)) && is_running "$id" && info "Use 'Apply now' in the settings menu to push it to the running server."
                sleep 1 ;;
            4|q|Q) return ;;
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
        confirm_yn "Apply now on the running server (exec cs2nexus_settings.cfg)? [Y/n]: " y && console_send "$id" "exec cs2nexus_settings.cfg" && ok "Applied."
    fi
}

st_reset_ui() {   # <id>
    confirm_yn "Reset ALL settings of this server to the DEFAULT settings? [y/N]: " n || { info "Cancelled."; return; }
    settings_clone_default "$1" && load_server "$1" && write_server_cfg "$S_PATH" "$S_NAME" "$S_MAX" "$S_PORT" "$1" >/dev/null 2>&1 \
        && ok "Settings reset to the defaults."
}

# name|label|settings ("cvar value;cvar value;...")
preset_rows() { cat <<'EOF'
free_server|Free server base (no balancing, no votes, no timeouts, all talk)|mp_autoteambalance 0;mp_limitteams 0;mp_force_pick_time 0;mp_forcecamera 0;mp_autokick 0;mp_solid_teammates 0;sv_human_autojoin_team 0;sv_allow_votes 0;sv_vote_issue_kick_allowed 0;sv_vote_issue_timeout_allowed 0;sv_vote_issue_changelevel_allowed 0;sv_vote_issue_nextlevel_allowed 0;sv_vote_issue_nextlevel_allowextend 0;sv_vote_issue_restart_game_allowed 0;sv_vote_issue_scramble_teams_allowed 0;sv_vote_issue_swap_teams_allowed 0;sv_vote_issue_surrrender_allowed 0;sv_vote_issue_pause_match_allowed 0;sv_vote_issue_matchready_allowed 0;sv_vote_issue_loadbackup_allowed 0;mp_team_timeout_max 0;mp_technical_timeout_per_team 0;sv_full_alltalk 1;sv_deadtalk 1;sv_voiceenable 1
no_votes|Disable every player vote|sv_allow_votes 0;sv_vote_issue_kick_allowed 0;sv_vote_issue_timeout_allowed 0;sv_vote_issue_changelevel_allowed 0;sv_vote_issue_nextlevel_allowed 0;sv_vote_issue_nextlevel_allowextend 0;sv_vote_issue_restart_game_allowed 0;sv_vote_issue_scramble_teams_allowed 0;sv_vote_issue_swap_teams_allowed 0;sv_vote_issue_surrrender_allowed 0;sv_vote_issue_pause_match_allowed 0;sv_vote_issue_matchready_allowed 0;sv_vote_issue_loadbackup_allowed 0
no_timeouts|No team or technical timeouts|mp_team_timeout_max 0;mp_technical_timeout_per_team 0;sv_vote_issue_timeout_allowed 0
no_shop|Disable the whole shop|sv_buy_status_override 3
no_gun_shop|Block gun purchases only|mp_buy_allow_guns 0
no_grenade_shop|Block grenade purchases only|mp_buy_allow_grenades 0
no_drops|No weapon / C4 / kit drops on death|mp_death_drop_gun 0;mp_death_drop_c4 0;mp_death_drop_defuser 0;mp_death_drop_taser 0;mp_death_drop_breachcharge 0;mp_death_drop_healthshot 0
anyone_c4|Anyone can pick up the C4|mp_anyone_can_pickup_c4 1
no_defuse|The planted C4 cannot be defused|mp_c4_cannot_be_defused 1
pass_teammates|Players walk through teammates|mp_solid_teammates 0
headshot_only|Only headshots deal damage|mp_damage_headshot_only 1
EOF
}

st_presets_ui() {   # <id>
    local id=$1 c i n label pairs obj cnt pr
    local -a labels=() defs=()
    while IFS='|' read -r n label pairs; do labels+=("$label"); defs+=("$pairs"); done < <(preset_rows)
    while :; do
        header "PRESETS - $( ((id == 0)) && echo 'DEFAULT' || echo "$S_NAME")"
        echo "  A preset writes a group of CFG settings at once. You can still change each one later."
        echo
        i=0
        for label in "${labels[@]}"; do i=$((i + 1)); printf '  %2s) %s\n' "$i" "$label"; done
        echo "   b) Back"
        echo
        read -r -p "Preset: " c || exit 0
        c=$(trim "$c")
        [[ $c == b || $c == B || $c == q || $c == Q ]] && return
        if ! [[ $c =~ ^[0-9]+$ ]] || ((10#$c < 1 || 10#$c > ${#defs[@]})); then err "Invalid option."; sleep 1; continue; fi
        pairs=${defs[$((10#$c - 1))]}
        echo; echo "  '${labels[$((10#$c - 1))]}' writes:"
        IFS=';' read -ra pr <<<"$pairs"
        printf '    %s\n' "${pr[@]}"
        echo
        confirm_yn "Apply this preset? [y/N]: " n || continue
        obj=$(jq -nc --arg s "$pairs" '$s | split(";") | map(split(" ") | {(.[0]): .[1]}) | add')
        cnt=${#pr[@]}
        st_update "$id" '.cvars += $o' --argjson o "$obj" >/dev/null && ok "Preset applied ($cnt settings)."
        st_cfg_refresh "$id"
        sleep 1
    done
}

st_live_ui() {   # <id>  (running server only)
    local id=$1 c
    local -a labels=("End warmup now" "Pause the match" "Resume the match" "Restart the game (all scores reset)" "Swap teams" "Scramble teams" "Re-apply the CS2Nexus settings (exec cs2nexus_settings.cfg)" "Reload server.cfg (exec server.cfg)" "SHOP: restore everything to the game defaults" "SHOP: check what the server really uses")
    local -a cmds=("mp_warmup_end" "mp_pause_match" "mp_unpause_match" "mp_restartgame 1" "mp_swapteams 1" "mp_scrambleteams 1" "exec cs2nexus_settings.cfg" "exec server.cfg" "$SHOP_RESTORE_CMDS" "@shopcheck")
    local -a ask_first=(0 0 0 1 1 1 0 0 1 0)
    local i
    if ! is_running "$id"; then warn "$S_NAME is offline. Start it first."; return; fi
    while :; do
        header "LIVE ACTIONS - $S_NAME"
        i=0
        for c in "${labels[@]}"; do i=$((i + 1)); printf '  %s) %s\n' "$i" "$c"; done
        echo "  b) Back"
        echo
        read -r -p "Select: " c || exit 0
        c=$(trim "$c")
        [[ $c == b || $c == B || $c == q || $c == Q ]] && return
        if ! [[ $c =~ ^[0-9]+$ ]] || ((10#$c < 1 || 10#$c > ${#cmds[@]})); then err "Invalid option."; sleep 1; continue; fi
        i=$((10#$c - 1))
        if ((ask_first[i])); then confirm_yn "${labels[i]} on $S_NAME now? [y/N]: " n || continue; fi
        if [[ ${cmds[i]} == @shopcheck ]]; then st_shop_check "$id"; pause; continue; fi
        if [[ ${cmds[i]} == *";"* ]]; then
            local one
            while IFS= read -r one; do [[ -n $one ]] && console_send "$id" "$one" >/dev/null; done < <(tr ';' '\n' <<<"${cmds[i]}")
            ok "Sent the game-default shop values."
            info "Note: the saved Quick options/Presets still apply after a map change. Set them to '--' (default) to stop that."
        else
            console_send "$id" "${cmds[i]}" && ok "Sent: ${cmds[i]}"
        fi
        sleep 1
    done
}

# explicit game-default shop values (cvars keep their value even after a cfg line is removed, so they must be sent)
SHOP_RESTORE_CMDS="sv_buy_status_override 0;mp_buytime 20;mp_buy_allow_guns 255;mp_buy_allow_grenades 1;mp_startmoney 800;mp_maxmoney 16000;mp_buy_anywhere 0;mp_weapons_allow_pistols -1;mp_weapons_allow_smgs -1;mp_weapons_allow_rifles -1;mp_weapons_allow_heavy -1;mp_weapons_allow_zeus 1"

st_shop_check() {   # <id>: ask the running server about every shop-related cvar
    local id=$1 k out line got def flag
    local -a pairs=("sv_buy_status_override:0" "mp_buytime:20" "mp_buy_allow_guns:255" "mp_buy_allow_grenades:1" "mp_startmoney:800" "mp_maxmoney:16000" "mp_buy_anywhere:0" "mp_weapons_allow_pistols:-1" "mp_weapons_allow_smgs:-1" "mp_weapons_allow_rifles:-1" "mp_weapons_allow_heavy:-1" "mp_weapons_allow_zeus:1")
    is_running "$id" || { warn "$S_NAME is offline. Start it first."; return; }
    info "Asking $S_NAME about the shop settings..."
    for k in "${pairs[@]}"; do console_send "$id" "${k%%:*}" >/dev/null; sleep 0.15; done
    sleep 1
    out=$(tmux_cs2 capture-pane -p -J -t "=$(session_name "$id"):" -S -1500 2>/dev/null)
    echo; sep
    for k in "${pairs[@]}"; do
        def=${k##*:}; k=${k%%:*}
        line=$(grep -E "(^|[^A-Za-z0-9_])${k}[\" ]*=" <<<"$out" | tail -n 1 | cut -c1-100)
        got=$(sed -nE 's/.*=[[:space:]]*"?([^" ]+)"?.*/\1/p' <<<"$line" | head -n 1)
        flag=""
        if [[ -n $got ]]; then
            case $k in
                mp_buy_allow_guns) [[ $got == 0 ]] && flag="${RED}SHOP BLOCKED${RESET}" || flag="${GREEN}OK${RESET}" ;;
                sv_buy_status_override) [[ $got == 0 ]] && flag="${GREEN}OK${RESET}" || flag="${RED}SHOP BLOCKED${RESET}" ;;
                mp_buytime) awk -v a="$got" 'BEGIN{exit !(a+0 < 5)}' && flag="${RED}TOO SHORT${RESET}" || flag="${GREEN}OK${RESET}" ;;
                mp_startmoney|mp_maxmoney) awk -v a="$got" 'BEGIN{exit !(a+0 == 0)}' && flag="${RED}ZERO${RESET}" || flag="${GREEN}OK${RESET}" ;;
                *) if awk -v a="$got" -v b="$def" 'BEGIN{exit !(a+0 == b+0)}'; then flag="${GREEN}OK${RESET}"; else flag="${YELLOW}not default${RESET}"; fi ;;
            esac
        fi
        printf '%-30s game default %-7s server says: %-20s %s\n' "$k" "$def" "${got:-(no answer found)}" "$flag"
    done
    sep
    info "Red = the shop is blocked by this value. Fix: Live actions -> 'SHOP: restore everything to the game defaults'."
    info "If it goes red again after a map change, a saved Quick option/Preset (e.g. 'no shop') or a plugin is resetting it."
}

st_check_ui() {   # <id>: ask the running server what it really uses
    local id=$1 k want line out got flag
    local -a keys
    if ! is_running "$id"; then warn "$S_NAME is offline. Start it first."; return; fi
    mapfile -t keys < <(st_get "$id" | jq -r '.cvars // {} | keys[]' 2>/dev/null)
    if ((${#keys[@]} == 0)); then info "No raw CFG settings are saved for this server (round time and warmup are CFG settings too)."; return; fi
    if ((${#keys[@]} > 40)); then warn "Checking the first 40 of ${#keys[@]} settings."; keys=("${keys[@]:0:40}"); fi
    info "Asking $S_NAME for the current value of ${#keys[@]} setting(s)..."
    for k in "${keys[@]}"; do
        [[ $k =~ ^[A-Za-z0-9_]+$ ]] || continue
        console_send "$id" "$k" >/dev/null; sleep 0.15
    done
    sleep 1
    out=$(tmux_cs2 capture-pane -p -J -t "=$(session_name "$id"):" -S -1500 2>/dev/null)
    echo; sep
    for k in "${keys[@]}"; do
        [[ $k =~ ^[A-Za-z0-9_]+$ ]] || continue
        want=$(st_get "$id" | jq -r --arg k "$k" '.cvars[$k]')
        line=$(grep -E "(^|[^A-Za-z0-9_])${k}[\" ]*=" <<<"$out" | tail -n 1 | cut -c1-100)
        got=$(sed -nE 's/.*=[[:space:]]*"?([^" ]+)"?.*/\1/p' <<<"$line" | head -n 1)
        flag=""
        if [[ -n $got ]]; then
            if awk -v a="$got" -v b="$want" 'BEGIN{exit !((a == b) || (a+0 == b+0 && a ~ /^-?[0-9.]+$/ && b ~ /^-?[0-9.]+$/))}'; then flag="${GREEN}OK${RESET}"; else flag="${RED}DIFFERENT${RESET}"; fi
        fi
        printf '%-36s wanted %-9s server says: %-34s %s\n' "$k" "$want" "${got:-(no answer found)}" "$flag"
    done
    sep
    info "If a value differs: use 'Live actions' -> Re-apply, and see whether it changes again after a map change."
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
        echo "   1) Basics (name, port, client limit, start map$( ((id > 0)) && echo ', GSLT'))"
        echo "   2) Game mode, round time & warmup"
        echo "   3) Quick options (bunny hop, team rules, all talk, ...)"
        echo "   4) Presets (free server, no votes, no shop, ...)"
        echo "   5) CFG settings (every cvar, by category)"
        echo "   6) Custom cfg lines"
        echo "   7) View generated cfg"
        if ((id == 0)); then echo "   8) Apply the defaults to ALL existing servers"
        else
            echo "   8) Apply now (write cfg / exec on the running server)"
            echo "   9) Reset this server to the defaults"
            echo "  10) Live actions (end warmup, pause, restart, swap teams, ...)"
            echo "  11) Check what the running server really uses"
        fi
        echo "   b) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) st_basics_ui "$id" ;;
            2) st_mode_ui "$id" ;;
            3) st_quick_ui "$id" ;;
            4) st_presets_ui "$id" ;;
            5) st_cvars_ui "$id" ;;
            6) st_custom_ui "$id" ;;
            7) st_view_ui "$id"; pause ;;
            8) st_apply_ui "$id"; pause ;;
            9) ((id > 0)) && { st_reset_ui "$id"; pause; } ;;
            10) ((id > 0)) && { load_server "$id"; st_live_ui "$id"; } ;;
            11) ((id > 0)) && { load_server "$id"; st_check_ui "$id"; pause; } ;;
            b|B|q|Q) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

settings_menu() {
    local c
    if ! ((SETTINGS_OK)); then
        if repair_json_array "$SETTINGS_DB" "server settings file" "$SETTINGS_DEFAULT_JSON"; then SETTINGS_OK=1
        else err "Settings file is invalid: $SETTINGS_DB"; pause; return; fi
    fi
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

# Plugin data that must stay per-server (AstraSkins is deliberately fully shared, see astra_* below).
plugin_profile_local() {   # <name> -> csv | -
    local d
    case $1 in
        AstraSkins) echo "-"; return ;;   # one shared database for every server
        FakeBan|ServerCommands) echo "data"; return ;;
    esac
    d=$(st_get 0 | jq -r '(.plugins.local // []) | join(",")' 2>/dev/null)
    echo "${d:--}"
}

# Version written inside a plugin: version.txt / VERSION, otherwise the first x.y.z string in its DLL
# (CounterStrikeSharp's ModuleVersion). Display only; updates are detected by the GitHub file fingerprint.
plugin_embedded_version() {   # <plugin dir> -> version | (empty)
    local d=$1 name f v
    name=${d##*/}
    for f in "$d/version.txt" "$d/VERSION"; do
        if [[ -f $f ]]; then
            v=$(head -n 1 -- "$f" 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -n 1)
            [[ -n $v ]] && { printf '%s' "$v"; return 0; }
        fi
    done
    f="$d/$name.dll"
    [[ -f $f ]] || f=$(find "$d" -maxdepth 1 -type f -name '*.dll' 2>/dev/null | head -n 1)
    [[ -n $f && -f $f ]] || return 0
    v=$(tr -d '\000' <"$f" 2>/dev/null | LC_ALL=C grep -aoP '(?<![0-9.v])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?(?![0-9.])' 2>/dev/null \
        | awk '$0 !~ /^0\.0\.0/ && $0 !~ /^127\./ && $0 !~ /^255\./' | head -n 1)
    printf '%s' "$v"
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
            if [[ -n ${NX_KIND[$key]+x} ]]; then
                # same plugin as .dll and .zip/folder: keep the package, drop the bare dll
                [[ $ext == dll ]] && continue
            else
                NX_KEYS+=("$key")
            fi
            NX_LABEL[$key]=$base; NX_KIND[$key]=$ext; NX_URL[$key]=$url; NX_VER[$key]=$sha
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
    local dm=2
    [[ -n $defl ]] && dm=3
    [[ $defl == "data" ]] && dm=1
    echo
    echo "  Plugin data mode (databases, history, settings stored inside the plugin folder):"
    echo "    1) Independent - every server keeps its own data (folder 'data')"
    echo "    2) Shared      - all servers use the same data from the one central plugin copy"
    echo "    3) Custom      - choose exactly which files/folders are per-server (the rest is shared)"
    warn "Changing the mode later does not move existing data; a differing real data folder is left untouched."
    while :; do
        ask "Data mode" "$dm" || return 1
        case $ANSWER in
            1) OPT_LOCAL_CSV="data"; break ;;
            2) OPT_LOCAL_CSV="-"; break ;;
            3)
                info "Per-server items: files/folders inside the plugin that stay REAL per-server (e.g. data/astra_skins.sqlite)."
                info "Everything else is shared. Enter 'none' for nothing."
                [[ -z $defl || $defl == "data" ]] && defl="data"
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
                break ;;
            *) err "Enter 1, 2 or 3." ;;
        esac
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
    local key=$1 stage=$2 inter=${3:-1} name rel src new old existing=0 ver prof mode dv
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
        dv=$(plugin_embedded_version "$src")
        shared_update --arg p "$rel" --arg s "$key" --arg v "$ver" --arg dv "$dv" \
            'map(if .path == $p then .source = $s | .version = $v | .dllver = $dv else . end)' >/dev/null
        ok "$name updated${dv:+ to v$dv} (package $(printf '%s' "$ver" | cut -c1-7))."
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
        dv=$(plugin_embedded_version "$src")
        if ! shared_update --arg n "$name" --arg p "$rel" --arg s "$key" --arg v "$ver" --arg dv "$dv" \
            --argjson l "$(json_from_csv "$OPT_LOCAL_CSV" strings)" \
            --argjson x "$(json_from_csv "$OPT_EXCL_CSV" numbers)" \
            --argjson i "$(json_from_csv "$OPT_INCL_CSV" numbers)" \
            '. += [{name:$n, path:$p, source:$s, version:$v, dllver:$dv}
                   + (if ($l|length) > 0 then {local:$l} else {} end)
                   + (if ($x|length) > 0 then {exclude:$x} else {} end)
                   + (if ($i|length) > 0 then {include:$i} else {} end)]'; then
            err "Could not register '$name'."
            shared_path_ok "$src" && rm -rf --one-file-system -- "$src"
            unlock_ops; return 1
        fi
        ok "Plugin '$name' installed${dv:+ (v$dv)}."
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

# Plugins that were added by hand / dropped into the folder have no source. When a plugin with the same
# name exists in the CS2Nexus catalog it is linked to it, so it can be updated too.
plugins_adopt_untracked() {   # <quiet 0|1>
    local path name key k adopted=0 rel
    while IFS=$'\t' read -r path name; do
        [[ -n $path ]] || continue
        key=""
        for k in "${NX_KEYS[@]}"; do [[ ${NX_LABEL[$k],,} == "${name,,}" || ${NX_LABEL[$k],,} == "${path##*/}" ]] && { key=$k; break; }; done
        [[ -n $key ]] || continue
        if ((${1:-0})); then
            info "$name has no update source; it exists in CS2Nexus. Run 'Update plugins now' once to link it."
            continue
        fi
        if confirm_yn "'$name' was added manually but exists in CS2Nexus. Link it to CS2Nexus and update it to the GitHub version? [Y/n]: " y; then
            rel=$path
            shared_update --arg p "$rel" --arg s "$key" \
                'map(if .path == $p then .source = $s | .version = "" else . end)' >/dev/null && adopted=$((adopted + 1))
        fi
    done < <(jq -r '.[] | select(type=="object" and ((.source // "") == "")) | [.path, (.name // "")] | @tsv' "$SHARED_DB")
    return 0
}

plugins_update_run() {   # <quiet 0|1>
    local path source ver key name stage checked=0 updated=0 failed=0 olddv newdv src
    local -a names=()
    shared_db_ok || return 1
    if ! lock_ops 0; then info "Manager busy; plugin update skipped."; return 0; fi
    if ! nexus_catalog_load; then
        ((${1:-0})) || warn "${NX_NOTE:-No plugin sources reachable.}"
        ((${1:-0})) || gh_hint
        unlock_ops; return 1
    fi
    plugins_adopt_untracked "${1:-0}"
    DEFER_SYNC=1
    while IFS=$'\t' read -r path source ver olddv; do
        key=$source
        name=${path##*/}
        [[ $ver == "-" ]] && ver=""
        [[ $olddv == "-" ]] && olddv=""
        if [[ -z ${NX_VER[$key]+x} ]]; then warn "$name: no longer available from its source; skipped."; continue; fi
        checked=$((checked + 1))
        if [[ ${NX_VER[$key]} == "$ver" ]]; then
            ((${1:-0})) || ok "$name${olddv:+  v$olddv}: up to date."
            continue
        fi
        info "$name: a new package was found on GitHub (installed ${ver:0:7}, GitHub ${NX_VER[$key]:0:7}). Updating ..."
        stage=$(mktemp -d /tmp/cs2nexus.XXXXXX) || { failed=$((failed + 1)); continue; }
        if nexus_fetch_stage "$key" "$stage" && [[ ${STAGED_NAME,,} == "${name,,}" ]] && plugin_install_staged "$key" "$stage" 0; then
            updated=$((updated + 1)); names+=("$name")
            src=$(plugin_src_path "counterstrikesharp/plugins/$name")
            newdv=$(plugin_embedded_version "$src")
            [[ -n $olddv || -n $newdv ]] && info "$name: ${olddv:-?} -> ${newdv:-?}"
        else
            [[ -n $STAGED_NAME && ${STAGED_NAME,,} != "${name,,}" ]] && err "$name: the new package contains '$STAGED_NAME' instead; not installed."
            failed=$((failed + 1))
        fi
        rm -rf --one-file-system -- "$stage"
    done < <(jq -r '.[] | select(type=="object" and ((.source // "") != "")) | [.path, .source, (if (.version // "") == "" then "-" else .version end), (if (.dllver // "") == "" then "-" else .dllver end)] | @tsv' "$SHARED_DB")
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
            elif [[ $iv == "${NX_VER[$key]}" ]]; then state="${GREEN}installed${RESET}$(jq -r --arg s "$key" '[.[] | select(type=="object" and .source == $s) | (.dllver // "")][0] // "" | if . != "" then "  v" + . else "" end' "$SHARED_DB" 2>/dev/null)"
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

# ---------- plugin settings: info + commands + aliases ----------
readonly ALIAS_DB="$SHARED_DIR/command-aliases.json"
readonly ALIAS_PLUGIN="NexusCommands"

# plugin.json (optional, shipped inside the plugin folder): name, version, author, description, commands[], configs[]
plugin_manifest() {   # <plugin dir> <jq filter>
    local f="$1/plugin.json"
    [[ -f $f ]] || return 0
    jq -r "$2" "$f" 2>/dev/null
}

# commands of a plugin: from plugin.json, otherwise every css_* word found in its DLLs
plugin_commands() {   # <plugin dir> -> lines "name<TAB>description"
    local d=$1 f out=""
    if [[ -f $d/plugin.json ]] && jq -e '(.commands // []) | length > 0' "$d/plugin.json" >/dev/null 2>&1; then
        jq -r '.commands[] | [ (.name | sub("^css_";"")), (.description // "") ] | @tsv' "$d/plugin.json" 2>/dev/null
        return 0
    fi
    while IFS= read -r f; do
        out+=$(
            { LC_ALL=C grep -aoE 'css_[a-z0-9_]{2,32}' -- "$f" 2>/dev/null
              tr -d '\000' <"$f" 2>/dev/null | LC_ALL=C grep -aoE 'css_[a-z0-9_]{2,32}' 2>/dev/null; } | sort -u
        )$'\n'
    done < <(find "$d" -maxdepth 1 -type f -name '*.dll' 2>/dev/null)
    printf '%s\n' "$out" | awk 'NF && !s[$0]++' | sort | while IFS= read -r f; do printf '%s\t\n' "${f#css_}"; done
}

alias_db_ok() {
    [[ -f $ALIAS_DB ]] || { printf '{}\n' >"$ALIAS_DB" 2>/dev/null || return 1; }
    jq -e 'type=="object"' "$ALIAS_DB" >/dev/null 2>&1 || { err "$ALIAS_DB is not a valid JSON object; fix or delete it."; return 1; }
}

alias_valid_name() { [[ $1 =~ ^[a-z0-9_]{1,32}$ ]]; }

# Writes the alias table of ALL plugins into every server's NexusCommands config and asks running servers to reload it.
aliases_deploy() {   # [quiet]
    local id table cfgdir cfg cur tmp n=0 reloaded=0
    [[ -f $ALIAS_DB ]] && jq -e 'type=="object"' "$ALIAS_DB" >/dev/null 2>&1 || return 0
    table=$(jq -c '{
        Aliases: ([ .[]? | .[]? | select((.alias // "") != "" and (.command // "") != "") | {key: .alias, value: .command} ] | from_entries),
        DisabledOriginals: ([ .[]? | .[]? | select(.disable == true) | .command ] | unique)
    }' "$ALIAS_DB" 2>/dev/null) || return 1
    while IFS= read -r id; do
        load_server "$id" || continue
        safe_server_path "$S_PATH" "$S_SLUG" || continue
        cfgdir="$S_PATH/$CSGOREL/addons/counterstrikesharp/configs/plugins/$ALIAS_PLUGIN"
        cfg="$cfgdir/$ALIAS_PLUGIN.json"
        [[ -L $cfg || -L $cfgdir ]] && continue
        mkdir -p -- "$cfgdir" || continue
        cur='{}'; [[ -f $cfg ]] && cur=$(jq -c 'if type=="object" then . else {} end' "$cfg" 2>/dev/null || echo '{}')
        tmp=$(mktemp "$cfgdir/.alias.XXXXXX") || continue
        if jq -n --argjson cur "$cur" --argjson t "$table" '($cur + {ConfigVersion: ($cur.ConfigVersion // 1)}) + $t' >"$tmp" 2>/dev/null; then
            mv -f -- "$tmp" "$cfg" && chown -R -P -h "$CS2_USER:$CS2_GROUP" -- "$cfgdir" 2>/dev/null
            n=$((n + 1))
            if is_running "$id" && console_send "$id" "css_nexus_reload" >/dev/null 2>&1; then reloaded=$((reloaded + 1)); fi
        else
            rm -f -- "$tmp"
        fi
    done < <(jq -r '.[].id' "$DB")
    [[ ${1:-} == quiet ]] || info "Command aliases written for $n server(s); $reloaded running server(s) asked to reload."
    return 0
}

plugin_has_nexuscommands() {
    jq -e --arg n "$ALIAS_PLUGIN" 'any(.[]; type=="object" and ((.name // "") == $n))' "$SHARED_DB" >/dev/null 2>&1
}

plugin_commands_ui() {   # <plugin name> <plugin dir>
    local pname=$1 pdir=$2 c cmd al i n
    local -a cmds=()
    alias_db_ok || return
    while :; do
        header "COMMANDS: $pname"
        plugin_has_nexuscommands || {
            warn "The '$ALIAS_PLUGIN' plugin is not installed, so renamed commands will not work yet."
            warn "Install it from Plugins -> Plugin Browser (add NexusCommands.zip to the plugins folder of your GitHub repo)."
            echo
        }
        cmds=()
        i=0
        while IFS=$'\t' read -r cmd _; do
            [[ -n $cmd ]] || continue
            i=$((i + 1)); cmds[i]=$cmd
            al=$(jq -r --arg p "$pname" --arg c "$cmd" '[ (.[$p] // [])[] | select(.command == $c) | (.alias + (if .disable == true then " (original disabled)" else "" end)) ] | join(", ")' "$ALIAS_DB" 2>/dev/null)
            printf '  %2d) !%-18s %s\n' "$i" "$cmd" "${al:+ also: !${al//, /, !}}"
        done < <(plugin_commands "$pdir")
        ((i == 0)) && echo "  (no commands found in this plugin)"
        echo
        echo "  Type a command number to give it another name (alias)."
        echo "  r = remove an alias   d = disable/enable the original name of a command"
        echo "  n = add an alias for a command that is not listed   b = back"
        read -r -p "Select: " c || exit 0
        c=$(trim "$c")
        case $c in
            b|B|q|Q) return ;;
            n|N)
                ask "Command name (without ! or css_)" "" || continue
                cmd=${ANSWER,,}; cmd=${cmd#!}; cmd=${cmd#css_}
                alias_valid_name "$cmd" || { err "Use letters, digits and _ only."; sleep 1; continue; }
                ask "New name (without !)" "" || continue
                al=${ANSWER,,}; al=${al#!}; al=${al#css_}
                alias_valid_name "$al" || { err "Use letters, digits and _ only."; sleep 1; continue; }
                [[ $al != "$cmd" ]] || { err "The new name must be different."; sleep 1; continue; }
                alias_add "$pname" "$cmd" "$al" ;;
            r|R)
                ask "Alias to remove (without !)" "" || continue
                al=${ANSWER,,}; al=${al#!}
                alias_remove "$pname" "$al" ;;
            d|D)
                ask "Command number" "" || continue
                [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= i)) || { err "Invalid number."; sleep 1; continue; }
                alias_toggle_disable "$pname" "${cmds[10#$ANSWER]}" ;;
            *)
                [[ $c =~ ^[0-9]+$ ]] && ((10#$c >= 1 && 10#$c <= i)) || { err "Invalid option."; sleep 1; continue; }
                cmd=${cmds[10#$c]}
                ask "New name for !$cmd (without !)" "" || continue
                al=${ANSWER,,}; al=${al#!}; al=${al#css_}
                alias_valid_name "$al" || { err "Use letters, digits and _ only."; sleep 1; continue; }
                [[ $al != "$cmd" ]] || { err "The new name must be different."; sleep 1; continue; }
                alias_add "$pname" "$cmd" "$al"
                if confirm_yn "Disable the original name !$cmd (best effort)? [y/N]: " n; then alias_toggle_disable "$pname" "$cmd" force; fi ;;
        esac
    done
}

alias_add() {   # <plugin> <command> <alias>
    local p=$1 cmd=$2 al=$3
    if jq -e --arg a "$al" 'any(.[]?[]?; .alias == $a)' "$ALIAS_DB" >/dev/null 2>&1; then
        err "The name !$al is already used as an alias."; sleep 1; return 1
    fi
    lock_ops 30 || return 1
    json_update "$ALIAS_DB" --arg p "$p" --arg c "$cmd" --arg a "$al" \
        '.[$p] = ((.[$p] // []) + [{command:$c, alias:$a, disable:false}])' >/dev/null || { unlock_ops; return 1; }
    unlock_ops
    ok "!$al now runs !$cmd."
    aliases_deploy
}

alias_remove() {   # <plugin> <alias>
    local p=$1 al=$2
    jq -e --arg p "$p" --arg a "$al" 'any((.[$p] // [])[]; .alias == $a)' "$ALIAS_DB" >/dev/null 2>&1 || { err "No such alias."; sleep 1; return 1; }
    lock_ops 30 || return 1
    json_update "$ALIAS_DB" --arg p "$p" --arg a "$al" \
        '.[$p] = [ (.[$p] // [])[] | select(.alias != $a) ] | if (.[$p] | length) == 0 then del(.[$p]) else . end' >/dev/null || { unlock_ops; return 1; }
    unlock_ops
    ok "Alias !$al removed."
    aliases_deploy
}

alias_toggle_disable() {   # <plugin> <command> [force-on]
    local p=$1 cmd=$2 force=${3:-}
    jq -e --arg p "$p" --arg c "$cmd" 'any((.[$p] // [])[]; .command == $c)' "$ALIAS_DB" >/dev/null 2>&1 \
        || { err "Give !$cmd an alias first (the original can only be disabled when another name exists)."; sleep 2; return 1; }
    lock_ops 30 || return 1
    json_update "$ALIAS_DB" --arg p "$p" --arg c "$cmd" --arg f "$force" \
        '.[$p] = [ (.[$p] // [])[] | if .command == $c then .disable = (if $f == "force" then true else ((.disable // false) | not) end) else . end ]' >/dev/null || { unlock_ops; return 1; }
    unlock_ops
    ok "Original name of !$cmd updated."
    aliases_deploy
}

plugin_info_screen() {   # <registry path> <name>
    local rel=$1 name=$2 src c ver source files desc author cfgs line f
    validate_plugin_rel "$rel" || return
    src=$(plugin_src_path "$PLUGIN_REL")
    while :; do
        header "PLUGIN: $name"
        ver=$(jq -r --arg p "$rel" '[.[] | select(type=="object" and .path == $p) | (.dllver // "")][0] // ""' "$SHARED_DB")
        source=$(jq -r --arg p "$rel" '[.[] | select(type=="object" and .path == $p) | (.source // "manual")][0] // "manual"' "$SHARED_DB")
        [[ -n $(plugin_manifest "$src" '.version // empty') ]] && ver=$(plugin_manifest "$src" '.version // empty')
        desc=$(plugin_manifest "$src" '.description // empty')
        author=$(plugin_manifest "$src" '.author // empty')
        files=$(find "$src" -type f 2>/dev/null | wc -l)
        printf '  Name        : %s\n' "$name"
        printf '  Version     : %s\n' "${ver:-unknown}"
        [[ -n $author ]] && printf '  Author      : %s\n' "$author"
        [[ -n $desc ]] && printf '  About       : %s\n' "$desc"
        printf '  Source      : %s\n' "$source"
        printf '  Files       : %s (%s)\n' "$files" "$(du -sh -- "$src" 2>/dev/null | cut -f1)"
        printf '  Shared copy : %s\n' "$src"
        printf '  Servers     : %s\n' "$(jq -r --arg p "$rel" '[.[] | select(type=="object" and .path == $p)][0] | if ((.include // []) | length) > 0 then "only IDs " + (.include | map(tostring) | join(",")) elif ((.exclude // []) | length) > 0 then "all except IDs " + (.exclude | map(tostring) | join(",")) else "all servers" end' "$SHARED_DB")"
        printf '  Per-server  : %s\n' "$(jq -r --arg p "$rel" '[.[] | select(type=="object" and .path == $p)][0] | ((.local // []) | if length > 0 then join(", ") else "none (data shared)" end)' "$SHARED_DB")"
        echo
        echo "  Commands:"
        local any=0
        while IFS=$'\t' read -r c line; do
            [[ -n $c ]] || continue
            any=1
            f=$(jq -r --arg p "$name" --arg c "$c" '[ (.[$p] // [])[]? | select(.command == $c) | .alias ] | join(", !")' "$ALIAS_DB" 2>/dev/null)
            printf '    !%-16s %s%s\n' "$c" "$line" "${f:+  [also: !$f]}"
        done < <(plugin_commands "$src")
        ((any)) || echo "    (none found)"
        echo
        cfgs=$(plugin_manifest "$src" '(.configs // [])[]')
        [[ -n $cfgs ]] && { echo "  Config files (inside each server's addons/counterstrikesharp):"; while IFS= read -r f; do echo "    $f"; done <<<"$cfgs"; echo; }
        echo "  1) Commands: rename / add names"
        echo "  2) Edit this plugin's config file"
        echo "  3) Assignment and data mode (servers, per-server data)"
        echo "  4) Back"
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) alias_db_ok && plugin_commands_ui "$name" "$src" ;;
            2) plugin_edit_config "$name" ;;
            3) plugin_edit_registry "$PLUGIN_REL"; pause ;;
            4|q|Q|b|B) return ;;
            *) err "Invalid option."; sleep 1 ;;
        esac
    done
}

plugin_edit_config() {   # <plugin name>
    local name=$1 id dir f n=0 ed
    local -a files=() ids=()
    echo
    while IFS= read -r id; do
        load_server "$id" || continue
        dir="$S_PATH/$CSGOREL/addons/counterstrikesharp/configs/plugins/$name"
        [[ -d $dir ]] || continue
        while IFS= read -r f; do
            n=$((n + 1)); files[n]=$f
            printf '  %2d) [%s] %s\n' "$n" "$S_NAME" "${f#"$S_PATH/$CSGOREL/addons/counterstrikesharp/configs/"}"
        done < <(find "$dir" -maxdepth 2 -type f \( -name '*.json' -o -name '*.cfg' -o -name '*.ini' -o -name '*.txt' \) 2>/dev/null | sort)
    done < <(jq -r '.[].id' "$DB")
    if ((n == 0)); then
        warn "No config files yet. A plugin creates its config the first time it loads (start a server with it)."
        return
    fi
    ask "File number (q = cancel)" || return
    [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= n)) || { err "Invalid selection."; sleep 1; return; }
    f=${files[10#$ANSWER]}
    [[ -L $f ]] && { err "Refusing to edit a symlink."; return; }
    ed=${EDITOR:-}; [[ -n $ed ]] || { command -v nano >/dev/null 2>&1 && ed="nano" || ed="vi"; }
    cp -a -- "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    "$ed" -- "$f"
    chown "$CS2_USER:$CS2_GROUP" -- "$f" 2>/dev/null
    info "Saved. Restart the server (or reload the plugin) for config changes to apply."
}

plugin_settings_ui() {
    local total i=0 idx P_NAME P_PATH P_LOCAL P_EXCL P_INCL dv
    local -a paths=() names=()
    header "PLUGIN SETTINGS"
    shared_db_ok || return
    total=$(jq 'length' "$SHARED_DB")
    if ((total == 0)); then warn "No plugins installed."; return; fi
    while IFS=$'\t' read -r P_NAME P_PATH P_LOCAL P_EXCL P_INCL; do
        i=$((i + 1)); paths[i]=$P_PATH; names[i]=$P_NAME
        dv=$(jq -r --arg p "$P_PATH" '[.[] | select(type=="object" and .path == $p) | (.dllver // "")][0] // ""' "$SHARED_DB")
        printf '%2s) %-24s %s\n' "$i" "$P_NAME" "${dv:+v$dv}"
    done < <(plugins_rows)
    echo
    ask "Plugin number (q = cancel)" || { info "Cancelled."; return; }
    [[ $ANSWER =~ ^[0-9]+$ ]] && ((10#$ANSWER >= 1 && 10#$ANSWER <= i)) || { err "Invalid selection."; return; }
    idx=$((10#$ANSWER))
    plugin_info_screen "${paths[idx]}" "${names[idx]}"
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
        echo "11) Plugin settings & commands (info, rename commands, config)"
        echo "12) Back"
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
            11) plugin_settings_ui ;;
            12|q|Q) return ;;
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
        | (($f | map(select(.name == "nexus.sh"))[0]) // ($f | map(select(.name == "server-cs2.sh"))[0]) // ($f | map(select(.name == "cs2nexus.sh"))[0]) // ($f | map(select(.name | test("\\.sh$")))[0]))
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
  backup                    make a data backup now (used by the timer)
  panel-export              refresh the server list shown on the web panel (used by the panel service)
  alert-check               check CPU / RAM / disk against the alert limits (used by the timer)
  --install                 install the 'nexus' command (also 'cs2')
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
        backup)    preflight cli; backup_run auto ;;
        alert-check) preflight cli; alert_check ;;
        panel-export) preflight cli; panel_export_servers ;;
        *) err "Unknown command: $subcmd"; usage >&2; return 2 ;;
    esac
}

# ------------------------------- "cs2" shortcut ------------------------------
install_command() {   # [quiet]  -> /usr/local/bin/nexus (+ cs2) point to this launcher
    local quiet=${1:-} me=$SELF name link cur made=0 fail=0
    for name in nexus cs2; do
        link="/usr/local/bin/$name"
        if [[ -L $link ]]; then
            cur=$(readlink -f -- "$link" 2>/dev/null || true)
            [[ $cur == "$me" ]] && continue
            # an older copy of this launcher: repoint it; anything else is left alone
            if [[ $(basename -- "$cur") == server-cs2.sh || $(basename -- "$cur") == nexus.sh || $(basename -- "$cur") == cs2nexus* ]] || [[ ! -e $cur ]]; then
                ln -sfn -- "$me" "$link" && made=1 || fail=1
            else
                [[ $quiet == quiet ]] || warn "$link points to something else; left unchanged."
                fail=1
            fi
        elif [[ -e $link ]]; then
            [[ $quiet == quiet ]] || warn "$link exists and is not a link; left unchanged."
            fail=1
        else
            ln -s -- "$me" "$link" && made=1 || fail=1
        fi
    done
    if [[ $quiet != quiet ]]; then
        if [[ -L /usr/local/bin/nexus && $(readlink -f -- /usr/local/bin/nexus) == "$me" ]]; then
            ok "Installed. Type 'nexus' in any terminal to open CS2Nexus."
        else
            err "Could not install the 'nexus' command."; return 1
        fi
    elif ((made)); then
        info "Command installed: type 'nexus' in any terminal to open CS2Nexus."
    fi
    return 0
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
[[ $SELF == /usr/local/bin/* ]] || install_command quiet || true
((POST_UPDATE)) && post_update_restart
main_menu
exit $?
#__NEXUS_PAYLOAD_BEGIN__
#H4sIAAAAAAAAA+w8a3PcNpL57F8BpZyQ3MxQM5L8iHSyy4/snfdiO7Xy7qZOq5UxJGZIiyS4JEYjRZr/ft0NgAQ5HMnZdbbq6lZV
#8ZBAo9HobvQLYMLdr37zvwn8PZlM6Hey+UvP00d7j6dPJtMnj6bQ/uTJ5OAr9ui3J+2rr5a14hVjX1VSqrvg7uv/P/oX7vKy/I11
#gOT/6NHny386OXjy+N/y/1f8afkDD1Qa/VZq8OvlP33y+NG/5f+v+OvIHx7DT/UXnwMF/PjgYIv8D57s7T3uyX9/OoX9P/nilAz8
#/T+Xv+8H7PgZu3ngLWvBalWlkfKOHkSyqBUDfWDHLJbRMheFChdC/ZAJfHx5/Sb2Pej2Agv7MI0BFv95tnVEGgN4JhT7AKA36xHL
#eLGAR08U3ojlAh6LZZbBIy/rF5c8zQycSnNR1fByembn++937//yDrtZLM5jkOLeIfNewy978waQQWOeVnwhoPUtPejGtJiLqpDQ
#+kY/6eZieYGQ7+BHN8hLUZW8rqHxvXnUHbyIUlgPtL/QT97oAdMdy1laUzs+aGgYqtIFTvdn/aSbVcXTAho/4K9uiniUIAmv8Fc3
#fVpWHFr+AD+6YQHgGbT8J/7qplgulFwhrtf6iciJ6nM5n6cRInxPDwANjani2TWuHX+hiVfnM75YaDa91E+6uU5A33E1J/SgG0sp
#s/OYI4af4JG95tceWx89eLC7y8b/5B9LRFaCkB/Ml0WkUlkwkfmKL0asrGRZj1gYhhdpXAegq7BA0oHC1c6oElwJo244EnSNsbms
#mK+hTy9G7PKMyTl7P/skIhUCXJWK2qcJ2O0tqFqg0TOWzpl/yY61QmIfvhyzOc9qEeD0Ki2W4qiBvaBuL8pQUQJWhPT0jpNSX2o4
#AWNdYCWuFMHiwytACQQNQYdoolT9l1QlvicLL8AxPI5/uIQBP6Y1jBMVgmUgaH8vgGUGwzPW6joTNGUt1AsFy58tlfBNe29cDwi5
#R1hUtRTsOfM8dmgGrLuMjpDHKKtwnnHlA7lIQsR2DDe//ZbhS8NNWExZiiL2o7CQsfhwXSL+CND3hPsB+PQOIPwTIKpY+FEQ0PyV
#UMuqYMXRg7WxDshH/0JcA828qo2JYwxtD5qRD6fQd8aeP2fwixhI3AT5OQpDkAFhqsNKlBmPxIss870bj33HLuA/b91w0xBXA3HW
#dkWZAJ9zjPoLdLFVkmaC+UU4T6tavYK3GJlSiRysEL12+45Yg4nP6tfAGMClakRWiBV7U6gsxNYPYDV/L6scZICGdoS2EppPUNiw
#hXMRp8vc09bVNsK+rxRs6iCc65GIEZH5MMHv2BQcNvK82aR8IaHH3ZTIlbdcJWHOr/zJSD/PMykrH/GAiFfgc3YJFRsD3VqGKIGa
#/Qd7PAksy5TvIWk4wuvA7D+ebELlZElvGNhCZ8oaZkKU6w6Cp48PBjAkclltQaFnXLsCtaPAHm4ZZGbBUeuWY/ESekXksiy3LDNj
#RaSpHrGk25PrdruUHJYydZcBuMNMoAWyIMkQiMOqvLuonH0DE8DuM5DIEgudgF8+tBDrALanA6QhzFqNdQYFessxgshRNc2ezdGY
#el4QKvmjXInqFa+FH9hd5O/+9a+7oKneLkDUZZbCFPhYytIFOv0bH/8yGX9/Pj4jaM9VyRLWoq5hZj/vOwtDEnRY/uwUDXM8zzZS
#bHFanDVdtsE1Ni01f/NjcRvVt7y6jfPbxeJ2fn3L0/y2Xlbz24tfbmeJLIPzXaLTLGr3FEmHTZZmCmz3S/CmghcB7JnSXyG3VqeT
#M2DRn8AwGhaBVVkZEz8NgvCTTAvfY15XuWD8i0r58DNiYCwrvpUDvCQeoEVEJZscdSx4glYPWINdoEO/Y/tTmD9Kwijh1SswwS+U
#D4aAPXv2DIYCHgRMQDVgoxw1E4LXgmbw416cXpKGkFcEM4M9aCt9ItKoxIjV2gp9nPHoYlHJZREfZmkBxnIMoU+M0ZY/3X8Ui8Uo
#qTP/4U2yZvsHMOnkm8C0ALHfsYNHgSZlzQ4m37Dp02+C4CNbj4xvGyRnXCZoCoGeQ1eDgE2g1EG7pjna6uM2QjVagWqDXTZ+0MBp
#vjAMgCeasa4imG8Xh+8iA0QRATf/9Mc3r2ReygJXSGgg3sowyIRBmYSlFwt4yfgvGHAZJw0oN6MAT1SVxN2o43qE0X7ED8wwWKv1
#t9DrNP59KarrE5GBpwNT44WGKaCyKJUwTkF1+TWG6wUQ6n0+ETe/Er13ZNa4brcbQKOi8/q6iFjrfcrUL8E8jpgsu15IAiLjtUHE
#6aLwQdqViIHMFKIO9HQQm41llS7AvIFuEAYTBFqBynAm42sKVUAVxRxUMbYClmEuVCIx6fF+en/yAYiWYSJ4rBOVG4jkdUQ3xnjG
#QyUrYetHHAnf/VRLNKrez+N3P2PfFONoZuY7Zn84ef8urMlgpvNrQ0fDEr1CDCD4iqegkkJFieVDs6vB1XOTUB1BzHatvT9vRlUh
#EuFjNMGAKtjy/jkszuE5aKviagnMqkL9NNIo1h2bE8nyGiMzHzePZg8yr+CX6YKDrCEUTsuZ5FWMkd8qLWK5CtP6RETLShCTcJg1
#q5ujwlWV6thPz9DuRVoN7i5s5xAi6i1mQplS1ikSeDhPr0R8JEseper6cEI7CMaGlzxbUugEo4/aWBN5bXeI4hq0Jr31aW7DSwsu
#rkQEmzfnAO4hLzxiKSgLzzKEhOF2Cx65Kv1TJfO0FtBZy4x6Xa7WSpYfKO2FTXRjMmAMyn6ABNGnCBICPVHBIpBEJ0FmDhYBCei1
#n4Pg5oWDplzWCYQZymKwVQDtEpulJWkMGwZiYq0m4P8xWHPxQ/Sn9c44w1b8mdSqHmJ/gXkQbiN8Aa8ChkJW16dmECYT5vEE1Exg
#YuEhifrtzNdFAbSFNJ68sMSchFj2RbJPDJCXkP32LQwa3x855hpgpvXqSP6Oke9vRM+W09Lp02KbkdfoIFGgXehZk47sr0J5ETCV
#VHKlfSujekl/15raCSIiw+Bu4gYZ9hLjscTSbLJmUdRqzUojdvtgcunQzIQ/R3fBxSmy4kN4jg/o0jNVeZ0RHR9AGdMpGpQxcurM
#Cxr1NolRPzOGbCREeNDcEIcERybg7AkN+pclLvCnNLoAfzQstwy0sOGrv12CVjVqI6rAisDBhXyuW5cDWWXtI/4OEBgRAHmYgp1A
#nK7QaTyE7sVCYcS+Z0Vlh2Nvs/eROYDL2ig0gOC8UqnDdLJqhyyywQyScRqdjZi2YSKGPsrjSazrwMYFiFFveGYy87Z908NDHFjo
#WhGx3toP3PXZCQgX+IXlgzdK5L5XXJ3TgokGbXZBdJrjjS66XXZ32zig66C+0JbXztrJG3haqP+iRqMxWlQSIoSXCgTfsmdnJyfu
#EMAqkZ0+3UX5GWxxC4KlIMx6OgqNyS2aRop/v5gtq8GmiwqYuKoZZv4YPTL4YV8XEiIjCJsMyNeB42+o5Y+QnHfiKEjim3weEo4a
#s3okFxL7/T3XFcNOq7cE+9SH0Q6vUj7WjMKgBwtJNpyl5APDllQnIynsApgKHr77LtDYXX1P3QkQFnwaRI/oA8GZzMmDeN3AvU5j
#sYXAurocY7d3V44QQTqimhShDmWBqYlOlTXzLAmhLqKYDLuhDMvaV/huWOg993QaTZSO9CLbMgXkvJXqphNRjuHmR3gpYCezhzeN
#k01krVCT1ocPb/TI9UfX9MzMymdLpYydaNdVYgFDQZQKbw2AXma7NjOpFzT5x2zILECEe9EE/k1kCISD6ieiaAKN2YZpbycqUxFj
#EAX2AyMgsAWfNczQR4HK9NFkQubDGjeQrtWfWT+3QMZAfpFGVAPtqAVlBiapRsFBWu1FS5hlu56gMuXcJBXbAFBWji6REVgbpNvR
#1stZg7UueVeOsVSUUTua6cFm11shcLCz7vgNffbb9JeWHKCytozWcFiEdtVDzue6mTzKqGF6N6glE3tCI2p/Jq9G5J2MvcGQFhvb
#2gx2GqeIwSv0uTag7Cw/B48Ru3prDF8o8lJda7qOrFcl6RN261SpeupM4JrDYCjGQL8FLDLROaUE7qmViScwQfV24V/K+DF2wPgF
#uWpyzX72xb5cPIur71NdwdpE9aPu9F3Gw7odYwmc2GYrtfSs3cYjY0cmtYhsIGL0NJn2hhPAWKUqE0Pi0h2kr2xTykDqoJCpvR1k
#ibapYCLSRaIOp4/LK21rUc2c5VZiDlkY1rA64cxgkN+K1LIiCEmCxkhhsuJEdhUmvRWJPRjQf90TGlSoE6dn2j4Rd5sQSauaDZoM
#vdigMzwspk9Gtv0LpkUY/Dzoqw82+hBLpDbhG1IhUVVGhboihHZ4ryQJhmdCHze049KiXNqyIT33vFUsxlSQTmPz2jovOlAjN6uN
#BjR9jyHqUskIMi8ILxAKTJVtBCkqnqW/YDNWNjnExxWGKnUpsixKRHQBPRQMN/ELhOJRlc5EPLv2DAV6SZTAJjIDDkH7z/A3xn/s
#6gAopDPyZoiz3VSx3UFjJ/w3Lqs055Xjq8Ed5KnqbAeUTGjam0MPZOKAr7bMdZUdI7BLPMenMRSOd6vQbg3+xfh/JuPvbQXe1KZB
#C59a9W+R4LGmTW+esQPwMpct/AElwmP0Xrb1AL0LHYS6qoFHUoZP+Njh0jwVWdx4x4zPREb9AOjoSZdR1KqtBtE6QiGNkNk2Js0H
#+NawXdsKcdmyT1yG4DwR/LWY82WmNrPEHnO3srObG1reYSr/FD0OatNGKKRXRcVX6/a6Lo/h2rDUymeZQF3EEPyIGrcgmy1rwrI5
#n2cqwG1afZethO2W7BJKkgrW2A5ResiRdRNSGpNJNrG1m1QPuemavreUHi4koNeRVKUTx85i2QDZm9iJXzbIcVlYCLWS1YWVRcdR
#3y+AdvQw63WKfRfv7T5ut8F2b9t6SGkK2jSnNtKw3TbtsO5qNoWBpISE6m1NgGs8eG/vOH66gZRZ19crUdYNKRokS53YoBeDtguH
#gVMdsv1DY/f+ibH7nRAWTYAew7tcTgtMcxLQRjzO2TQteIJlMLU2eC6jZf0Fi5YxrxMqkW+Gec0mcXL5oX1JRYnB8MUJXnTxn4pG
#e5NJu3WcTQSs43jcqm9x6caj5tiZrMx6K9KDyTRor385h6ymDAXsalMISqYxMC/12pwkrh+rlpVcUU5UhrnOh3LR5EOt2m6kUmWb
#AJc6N3Nx+IgSBJ2L8FouPXJeQT/NGsb7iW5bKAx9zM0NQIsnuSIOHBUCzLqRRq8gbz6kixYNLG7Tu2e6aFbw8eFNGV6kWVav2S7D
#l1hwldTrjzo9dtIzlOFLeeVHWW3oHLGmeFFHshKuOiXGFSf7d2wtRNKE5f2cEzE2t4Ke2xsCZqJD+26rKjYR7FR1ticquBg6Y4bV
#YFigzw0sMpv3lb28z1WvzuUigNlMZd8BHIXxJn4fymTb80gQq06emwRXdus7QLmpChp8p5MzN36AyHXLYjGmtbFPste1bXSDRr0v
#dN7RKQXcl0YTQc8NEnz5Cdmj1VKTqGFok4wcTaVG/OecGKo1tqEGcxaD6ddQs7GWMAEZeEFb5ukU9u/LXrvZGA5q5OjkYczVDmCz
#KVnorrZI357LRji3bGqB5oYH6VkZklKiydvH/f5ZkHifT6pEVPcBY2y4h7bVed93VHD7bYxCrsac8rCm2CWp8rOlgJVwqpXeUQRD
#jGkxlz3vPwR2oSuGWsQyXPEqX5aN0ulXD5VHhmlxnlMIZnvT4i2+e61u2erUPdU0nLhTg5OfU4PDUViD27wnotn1K4dvFI5tybgV
#s7Z5pnIse5VjG1xYS4gn7MMCpr5ump2ll4I0qmEqaM6O5b+1UFFbf9Nn8fZc3HgKL6L8k1iPbSFWYEewB0Z6gucwAdnzc9gWOrBs
#r/up+5D3cBNqtYl6EzPtl3uQyy5yGuLZvTZyEPbKjgNSpY0DG2ikp+p51TmP8AImJKQjfTgHZmY5uzd4wWFtDVk5Np1wtbWu2Ljf
#FreJ9+ucZ5nrb6Gnie97RJIt/D1MSXWp7X4s1/6JNEZAVLDh1xxu6QgaV6/5jI+1vsiKjLYREPZg23ktRIHt4D+6bTYY76PSuU6A
#nw5oZ0MNsHoHddveGgmHkDtwaDK64z1vKy1cr0o2xqkxRYeOR7eJ/CaNtNIeiXTRCpDuSNydg1gcKi2G7UTi9Q+zVrQw+Ao48Eaq
#0zJMxDaURhMIa6ik4k4kZxq2raqFd3srAZvaRL7AuXCVFqBnGT5msq5R6WJ8iSu+qu0B2pA2Y4RxnzY7p5v8yp/SVwYOm/E6Jp0M
#1NAEQ2JzWdkB2XaAMJiPZPTBxB1xe5EPnAoNg6oWlK4UNxTe6ZhnvNprrErqFsk/rtJYJYcPbxp27JnL23QRs50AsgjkG10GD4L1
#Nx/bXHuQ0Fwo3ovhLPNAmjXIq3F8bQsKFvKqEWuTrUb3cad1E6N6I9ZE39hJtJlRVHM5+e0JXdJLlciBxtMz0EZwJYc648TLgKJ4
#E5tKCDPf5uDpjHPPmG7yvgSd6lwzBpVGk9h6ve+aF2Wv5kVqhXUeibG1A7lLTcRXUOpHk8ZPQitu/xbSeVOBQdec0T99OnJUeg+9
#8aqTygzGdLiYO8+/CWIM+tOoz6zbT6GAVaZ5Jq5Al2DqNZuyyUcr/8Yy2LW0hzY9dAPYpvTFwH04VdBVyOGFzDO+2DxM1QhzJ043
#1gmVJ6RT5NwadXNsP6jzVaPwDq69e3D1jFgl6mWm6Py8wsqKkV6lP+VZYZXPwYfviMl0o6ns9FODA4DmswNADdZUaxJLESm8i+l1
#L/3FsKHT7AMWMv14RFWDEWtrBp2SE95BOWbxfUkOVY+atBhHNdGbvRhqKkOm9iC4jXVV5ZQfVNLLfWkhkcwMAabaD1b+1MOsw4vp
#XIee6Ia2l19iCuqRKnln5AEukNi7sdN3P5sROV3mpdUgnrLBU7nK0lSW4F9bRqJ6Uybm6hycVnaNvQv0mpvFKxU7NLnVqu7otmql
#tQE6NytXQwipcrStU1eStvXixeta1R1/1EfAc74Q2xCALLYi18WjdbDNsm25fKGUrQmNBktUG/Co5eNVxcvGWFBTR+f0oTS+46Ol
#F8Vvmun69vA9AiUXi0y8pi3lwz7SB4h4QLpqL9O+PQm1R6LNkocpXkNnTqu55q1jHI2CrtGteh/60QmmuAJzFVNhxZxt9k5O7riv
#qeM9Fmob0L+yWXQ/NrgTDxB32iHn+GusE3+9cQ+0/7HitjXQlC5PkE+fxQS6iNZenEdnehKS0z9FHM0HHjvE9ruK6bsmyqBrvySn
#geI6zVANltHbS2ym69BIFqeH2bt0oWVt6+o7MdYGWgbsNKrSlqm6CgIN+vGuoNVIGrW/Z/j38TLUQP4fbEDuIZM3kvm+wyPe0Y3R
#TkSlSexWNtxKBt6T3np4jmrWnpg3AD0dcA75TXm+dYu0kro1uvYTq8+7DZbbKthwL+AYqCblzbUretpqnHK3mpSbAPnzoJvsM8Qr
#HXEv2KaVU9jfhOa5eTfBtbnh1YbAd7DgIu7G/4RdN96wC0RNTsbmdeRTRozjS+tC7sxqcoiV9PdkeajDJiqT2URTT+3EUxaqKR2j
#kbjvNuNdlrrvhIauE9K6SRVghB2+/WoZ2RF9uoCpyUtV4P0esGStW7CvuOkpkzEfgGw6hqHPhobs1vMszVN1vDf5Vs7ngPwYmWqx
#25Bs+3nhDt373zG2q320VYKOKSJyFpQudaGMHddz0qcqEK8BYEArQ2bAEHi3VRB9LnnUZcrAdcL+On71lcK28NW9VYjcRXqs28p7
#tQDXsJkCgpaoc2vcrIxS1sFLe685Xvjaet2qkKuXzVmYezFAmzp9IaY9Q1k114PM1RqsvbQI4u5JPvV268foqdwBA6WO3gjiwvYR
#tpDUHaP5dPflKAQasPFDYiNQ/K6a+H6o/18GG8s6Ef/L3rV3t20r+f/9KVB6e2qlokxRT0txzjqJc5vbJM0mbm+7ba8PJVEWa0lU
#ScqOq+PvvvMbACT4kOw0uenZ07gPkQCIx8xgXgAG4zIg86trd+5nzBwWSrfWACtu5JCIq1c0p3GiP6ZuGW6WD+lZ6rTjnmnE7N47
#6eq9kwontVRh0otmMjxLCkn44LDhRm3dThdM9YD1munQdD6nYx6aTrwMdikkcgcuCn7RYf4sx1BuprzvVs/wMjttZWw2SvdjfQEX
#6SZ3QE/tRNL7m9LNSNluyUQditUOrq+Ku5HVwsUlL8Ok3uPd+uauDajlzacZmvKbTvPtq02qBzs2oe6UJR+pT1iqz/qh2eVdItqU
#nBlVp+JTxhupFQe1tbzE455Qm2w7/5k9tnzYKSoxfXkEiikzR2oaMil1ZzMOh/SKxy7Ns0jyfOdKHgjkrT/6KGbDPH9pnLeUpdKN
#PKYkygyPlfQoKfKv5QtL8k+FsG78Pk1/ZWpVhZ3rDP3UvtxOF9nuTLUIDsZ+1Ui86MJPGuN5SPOR5qb3M7Zy/fvYOoT9qTvLltkX
#VBwu7G/9G/06TqK58RrPgmmi3j1VtRzm+WjuLS+/4oIeomEZViga5NPvWWwfdewQZys2lXtJwWaq62F0QJCp89VliKzCVcznaeuS
#tqisPpsmT7fdNbmMQ2H6GCN9+9JfrkEhC5Mhq+ehyLew2wxXbtz0a7YO6b/7Y1my5wr07vMZPUA13+2sz3KL2vt0N3OdyP2r+rAg
#wfYueBYlz7bNsqHa/K52y6KdHFdVZnC2c+6O4bGQSuUTA3fvoMB3RmGYKLZTOKCZO9t5UTzbyeZqep64dAI347kFmZod5K5l//+r
#o+L9ff5y8R9lJI5x/JFDQO6O/+i2u+X4j136+Rz/8RP8DTAuTHbbVgF39pt9t+lOhpQSeUHsU8LUHbWO0gR3sO/2Wt22hxQoqYP9
#Vrvd7nhDrobtjH3/yPenbZRgK3qwf9TzuiOuZBIsBvvdad856skvxgnevf7UGfKbTcVdr+31WnhHZS2v2xrzC/K6o/ak2Zbfkrgb
#7Pfa495Rl7sTku2z7/d73e6U24q868G+54264678gPdgD/an00mr5+mkZTKwHnuzZTyeRSTLrbr19PkrcYKlqiWJTHp/E47CJBRP
#QuL+y9ifUNJb/yL0xffPxQ8QDaO5L+BbMjKsenxDrH9hr4O6jegvvi0T6rG3jG1SdYMp9JgHm1H4zo6DPxDlZxRGpOfYlHK7N0sW
#840RC+mKrH6Np9rtHsTCZkGijmDgDBfB0ta2muNczYbbPhyOw3kYqTQZUYUh0HYcgRNyh81GR8hcpNeG9rU/usSSKb3Z8YIIZoae
#ehxKJ/AIGrd7P0tR8+tGxfEZwPf2RbDAUWQqeLvnbWSzwXJG46aEWbM+c+uzVn1Vn8zrk0k9nNfX82w8K5KfaMa53Rsw0uyrIA4I
#zBuSGEx2ZJGKOJwHk7S3VKo2VNm29GCh1FABFTGkCPmt1Tuo7g9UBADx4HCvMfKitOtYbR7SyC6WttwfMPYRJ2X4G/GKYHpjj+VR
#jUG8IrXVHvnJtU+6zoW34gOGacebbeofr8FTap1k5/gA5/SuroUtmk7bWb2rHbqk5KQYT5JwMWgWBsVWYBmXPBOJBhqjiBSSO7vO
#naMWh8C3PcEWGzYTGE1DiVgcg2s23E7kL2TKtaSmnuOoEkmE8BiDsZ4EQ7L+qXYbgMCIG07TX+g+ifjqYiP3lLgAi6JNfjYpcJzw
#MDxCDwrcbyguUMiBScrzQzKpKjKXkN4G4hyNmIikZ9Gnd54lKf02Rsky7WzA1ro9Ih3p8o5m7t9d3f4RVdTsl8i4W+hSDmldQlol
#rsfrKKZ2VmEAaMphDGYId2tCct+dtp3OkczWJw/LoB6nQLULKFXD2XemJE5a+XoqmuuPRuNpVxb7WR+S+nWjYzY1urrfE2kLAfnB
#8tKsg0enQO/koMkSqJaHVR4MOVSXAYfgXxFvcOSc9FWzmJakRuqQGloJl5RNWvkmDUkV+XOq+sqX6TZI6V5DMdj1NqzvGBkxpOF9
#plefx4OOwYNALPmdLSdyq311PcQIp/PweqCMPIZJmujP58EqDuLh9YzqZdbg04Cwgp4NdjDwpgnDSXJSyxrKBnoZo+ilBD8wZ5FC
#pqI6+ZUjIApciTviPTGObZFmwx6FNuIF1gSnE9D9nw5sKqkwYpNhuc7Q4o2oKWpgyKyIYJ+EqwFzbmLcX4qvBUFxxxR+D/7SL/AX
#CAsW4XJETRfM+g+bjHn/3aAjxdUKWyUgrPBgYEUKk6GWnHy0Oa3c7aN2NNE10X8RBRPGdavLyM55izemQPggeeB06GPZsVTAteVs
#Idm7qZil2bA63fGMCnJ6RUnKkmcWN6nAdTUgFayxywWTM4eNZKs0Lc80CXcsweLwBEBPv+VZXJoSOU7abrnt3pC3sGFi33IlCJyY
#Sg8pNjQynS+HmR735TDkkFL2NEgI0FfMsmXoxAqyDZZgR872SY4E219OUvJg6nCUJLkHhk3KcJg0JNCii5F34HY6df1fo9OpSdaA
#4yIEGlIuMUEFl3Tq+IeUDaBxvE42iPZnw2dJjGt+cxEuDxzh1HnWOfVsBtqM3xq2SH5Zd/hHIckMegREKUfypkTwGC0IProq5NH/
#COuLFZgExNl6sYwHzRYT1TSSs2qbPgJZvI2qUkWWhThBwKkQ5EUKMrT5Xld3WDD5KTpBx4alIhx6ZpMxEieHaUcVYrZuorL5PrO8
#zNnvKRNU6/F6dC8tr1/QFA05LvvdOIpY35yEGir9DCZlhalDs6mEJLJGa7nJSZU1wmVZ1yFLs6YHEEz8PPFo00COARMMA5BY4cBR
#f5qlcvIVLEz6Xa4XJPPHg8QbreekMdN7PGRNRHMMao/jSOUBjM64LCJSmdHlSQ92AAQOGItFA0dzC12pCCpZVicDetPNT4T9Vqvd
#7owKiGgyXFSVjWmlXsmAW90YcGv0DX6TVwa2qU7p1CtqRX9Cw5OYmHqLYH5jWAHo5HatD5xJHigBT+InQ3C3TbntwlwEkxFOWUq7
#yuDhqmbNHDUd3Z+aQL84lF/BFYE4nGy05bqvtBVAuUAbtlQMYv21mAcbnRUsxxFHfxzEw3uw05YjuWnWpjn3eS3EaGUwGPmkyvmp
#nqhaPSArP9cYLyDlGYiyPA2G4N6TI9xLm6uGt8mU5CBGeaoofUgFOXJJGSNSCedMeeKrSlsym+3IdlWEnI2hTmyTTGqERT/KNnt4
#iyHSg9+IR31IgiTnOSrqg65LpMozLFPT1wguM/ZiNfWYHjQSc64UJbjV+KRPaLPF+tQuIsXT/Sg/O+EmrOU8Zo0OgIfpmgZVGAi2
#ArCzhmcv/d5HY6Ba5c0HnWlUE+lbj94Yr84d6DAthIJYZZWXj+pW6KDGaNy2BJUqLPJaa1FbNAvy0d4diuWuwOx9B4HZWb1rkg7Y
#rrdIC2zWiin9bq2mmsTeyIrGWG1nh4c0w5TvQ1oP3Sojpp0OF6eJN4XJqH0R4+nkyO+qgiUVqPc+do4pckl5UnVCsSm2xaSUmShd
#7cspc+B2yg1TB6Pih3xMYtbaFGd7qbs5ob/bXZlppY7oZoxRgbmSJaieNMYJOrPT72OKcbndd8snhS+yD0J8UGn1IarHvVR3pbRL
#zb0AYikrRsR2WOoXXX3VBiQzrZUX+XBocz8aRER3CBCuJDdm6adWNYjGinj1B2jUqpLf7hAP/b4UD6q4miQ7Fcsq6zw1LNrgmCbL
#5rlKDZDGtAUku3wgrrNzYsh6xczNTdn2+2g+4O28u4yZOT/dh4oif+V7yQFoCDZ4XTH0Zpf6WicSq0muzqadK3uKusUkuUteS3zI
#wpPcuNziuLq7NDpVg+Dj3gUFvcgJzUrbTpWb1LSmYxkuZSKdTth4t01NQdp7CUdALpuYbeWjqpycqnrRWC429wNK2UuR1pEs7kH4
#hVbSj3F4dsMDk+MZNA/tplYvt7sA3CLhtypFe9ZGyc4y/UFbjCX5NTYqlXt4L84gPV28F06F5pERJXANxUpOGpW91afC+fec/BVO
#D9RwX97eAb/IqKnRNJSt5pGDudloaxrb7bsB0zGUZYOlgXNvNy5z65l5n3yFy6dggBraWl9yDQy9vDJS9qs50mm2YD5u+IMAkWGh
#SlawDGcQ0hbe6k+7fvB9puTsJKgP8xLhXEmZzOSo0oPIeR+HGnqrXbLy2hX+tW0z1axf3O2m2sm1P8irY5CQk1saaGWmWLa6lvW5
#EY+T6oW6Su9OanIbFVR8v+1z6RzKTlTnAWbQRK9f7bvJfS1wjnrDzrhmPqMRbSpUDZws2kqLO6FbrKx6tQrHijbvg9HclDJQ1mhX
#60poACe3c4NgR6OQeTBUy5arzsXullwuEtJccKut0DF0gAp/Kp9x2uTWp/Qy0hbDRc04rJdVOkxu9/jYbM4rkVoDc28V+wP9cDf6
#qLJZSRWoGGkJyyVnoh5iW+r9qHjAcWHsMa5arCcT83VTkA1UPDPtOsp0KKM5iXDAm4puZzpUBOe7UahyjiRJiQ5Nv35fLe5WuIOS
#hOy1TdEqE0hPNiXTC1vfN3qmk/o1zWzQ9CD0RvNS+90AgpVUh//GXZKeOMhcmz34l2vYWMYrLdVS/KirvIFqLHaUOpFv1ZemiDsy
#tpEwBZUWSeQ30j9f0oKq+8D6AfqQd+HzsKs4vmk3ywVH3Vvpd9/FZakQnEhbzVVdgj08pnfqyFFtsH60G5iGueuo7pnCxFWeNJHb
#Meaktd8X4FAxJEihtzQPWxL6LLhN0LsEelk5mLW5O8xoUioquc9ULjFgM7llNImLYDThrSJ/SvaKHfmT9dif2ItQ7XixZY6/HPuS
#GkfJss5bNepyfYFteumAyqanNNcFMfK4nj2aDZYoXUi/xG5XxK3IzPUSfUq9soUrAD7d/s/c/t+pdxUQ3Tbiq4uP2cbu/b+O0262
#C/t/282W+3n/76f4e0i4Fu8W82V8bM2SZDU4PLy+vm5ctxphdHHoEnYOqYQlrgIfp/aOLfC9lkv/Wo8eRriFhmfBsUUJQrIG+RxR
#2a6F6zLnx9Z+03NbLcc6fPQQa/xicmy97ArXJY1CdOdN7Dv9Q5cFa7BgdYaXPn0pNwbrBFu15jY6aRL0C8TFPbZ47qKRcRCN574Y
#Ux+a1InxDf32qU/4MOuU3FaM8hjjo7/lqYPc/OfdRg3sOv6obdwx/92W2yzu/yem+nn+f4q/h7jtESenBdD+aO8hfvhquGPLX1pI
#8L0J/cCzJHBHBqICWOtkavctnYy1lGMLLALbvS2hdJ9jS87WiU9iRU1d3LQQYN+4HY+9uX/cRCW86ezRk7fuK//dOn54KN/3HkJM
#i8inuQqxZHG49WOrQlpZfPibiiGaECbz18TSrFwNvKwdz3w/KdaTnnrBB4dquNhbrwbvR/JM9bFF5jGVEeKhl6Zgp3NaoSWCiU57
#xJy1gm0K4xY0FfLmvbnieB1hEeIJVJMya+x+MGvUFkHKGx/CMhfpXY3pIDOcoQAV9hg+k+DKgJlU6xlylCevIWRIgcwsXVC+ZMEK
#jq0X6uJFSx3XR1/4Y1VThoX8DSkpPni7hESKvsXPMgex9K7klgrr0YvwgihT9T8/gutZKOvgB9UVFeb3oYw2YBTF9ta0ODco8e3F
#q3C1XimMi0LkIz5LaCkwG5VhZqW14QpB61EKatl02pN8j3lja/rlS37RUMz3GVMkhZE8vFgFJMqRUKKHtO2Hh9Sqgph+VA9yJvkR
#eIQXLLkBEjUpuleMWInu4IpoehWS6cDjQ3n6DNfsrBLcmJ3NVcRN+C1mIHAu2lFT9VAysL+aof4/+8vLf1x3+vHbgJDvdTpb9X88
#5+W/2yF1QXQ+flfKf39z+V/Gv7/k+20/Yht36H+d8vnPttP5bP99kj/4RCxc2GwNhDVPIgsRZpR0pxQt32VyJi8pS0rMXAZkhMrB
#Y5alBTky9TPn5m79Q7a6jiGfi7MCWZNkcZKy5Mm7o6ZRuBDJzBcXCHyZhCL2fQQGjnxxE655/bqOp4ivPudbcPlNBwTKN8RRndDS
#qzBdAveoKtJ5xXolbvxEfZC7CxMffCefcpnySkzOVY9mtgr1h+zN8laEU4Gdobf6hpKqsvJiWfXFIRfPFVN3oDLiwtWN0BfFjuX1
#9IWyuGZVFcWTBER2t1MZ4AxiQN0sy3c1oew/Sc8U8GHTSABhHZKnWNhF4TNYHF9c+AkjkT4ECsm6SBqCIHnDuLsmVZTRyXm4BK1Y
#VQtVncItm5YRQH1DPE8ELt+K+V5h0qQXwXKd+PnO8Eh4/IUR8bVbRRLPrkPjb3A1ICimkasSHkRkP6ZfSYwmNRdvZ8v3vm+nNxBW
#kHajXIe6YIzBSaVIKfTn9OV6PsFlXmLkk+GDWJGThjiLboR3QWqVqkaGAMOXb/QWRyMjvV8FBX4iTGAKFK+OrijO17EUSYEGEKfz
#TuF0Fl5jOvEsBW0FuH6aY4tn/ctum5FcQ8Xm8ifoxUZ24lZsEAP81hhVdrWMmsa8L4LnvgwsTxVk05jjLGVjxYe4K9toIS0n78VA
#qX/JJ52h7iBBDj+AmldReBH5cZwWorErYKZJ8ionpMonNZY0X221kxQqN1ufMeIREDFfigtty+T7LJi1ynDOPEAisVkYxnwxOAdf
#Tr8x7kbAR8/wgFm4LJTI5ABQI98KJTxZBReoIp3sTgLuP3AkUVwooXh1CmE/LhSQmGW+eH1LE39ZF5v5LXUKV/psJrcC66LF7rFF
#zTRChEokUQWBbJRnsyAW9C8LD84rjLkoCnJzSvMBUE9ONhljLcbE14IBp94NnJpR8FlmA7oF0jEA9pMh7Ir5GRd6FiyDmDiFLpmf
#onxWkznRNFh6c8G+hEapNqwdMp3hWxmzNd+wjlPOYAiXZiqWtSXHjRMzHYhD+lP8GulpaHKJQUVfBiEbEUw1INWbkX858TjzEjej
#gU7o/95trn0Z/ZWHlW6JMgtkocU1A0kJPM1nFv1tMZXp9WkxlTt0Uiq7uODSHC27mLm4Yrb08ofXxRzexZX2PQdvfyqph34FBwnP
#QVfHpk8pCCmyBKarFh5Y68zonHMWEr2ANz3icgYjc0ZV6dxZIW/i3eisSZY1WUeFKrN01KbzZqhws6gokWZnyXNfEhuf8hHN7Bsp
#VxHwiIEWLnyOdCGucTHndRTicRbMfY6JBOkv3vhJdGPqAbkgfxn45LvgWLsNodQqlshauVr610rJ2fvL1v/Y/tPKevzRzMC71v8c
#t7j+12k7n+P/fJK/jYCbnxXRiznJAOuTrj5//vur/9T8V2bmzX+kjd3zv9dyOiX/X6vb+jz/P8Xf/heH6zg6HAVw/F2J1U0yC5et
#PctKXT8k/UbSuBwo34Q60Tq6ISFmp04BdS2f0k9lyGId47Oe+lv29t4mZAxiY/k8GEUeGaYhDP6D19yyaDX6X9fIYL0O+Z5NxE2M
#ByRYH4jVejQPxkKIg9hPYMXEDaw21sU3Z2evYdHg9y1fYEOaKnWa1GZchcIRFR9wFbz1GhrsQdPtNRz6pzlIK9OZ56gV1fCHq/ma
#xnr4QKxjUo9pyKic4fICS4syWxwsfX8Sc97J6+fi0r+pAYR7Mv6VmHnxjEZbF7OFN6b/J8lK6fF1ASFL4CEVCEuYuFEvRoxZhEce
#R36Ci3eDC+oW/YbjS0pQ38W/Y7mkRQ8x8m5wn8mMDH7oJXU2ePfYgYBdlTK2B9kvsjsT//e1yuWujMPwMvDT7Lf0O/efcKIstY7m
#1P3GCou/uhSl8TshGj/nv8d7eyevX58/ff4G10rGHIC2MQkiLGEd6HdvFOP34Px8SnrU+Xmttvf27OTs+ZPCdzCJD1R1dWFJ/cSq
#7T09OTvJihLFBqSVIRjlgfXq9Mfv356/Pnl1+uIcxSz67jBcJYfj2LWZfg+xqkWVvD09O3v+6h9vz589f3FabFS3gFY1aQBHaPzx
#XV9wM43JiArvPT19dvL9izO+Z4xXyKyVdN71nb5DZWnKsZrpMCE66G6OBCnP7XUQcdgiQjwnmkJpS0YAtyYhVslkCmnQ8/h87EvX
#oH5PPxBYcsTtaFH4DknP+IozWY2arYwNytoOCS5myzmo4KGqWHirWDuQC/BGFrev/Yk5dzI3z3rxORR1qOQ9F8MFNzlPkjkldGn8
#iPT75Lunp+cnL15/c/L49Iwgap08fkIA/sc3//z2xctXr//nzduz73/4148//a/bane6vf6RRXR1evLy/M2PiC3tE40vVjTGg8j6
#9y+TTbN3+1+Eo1cnL0/Pn7w4PXlVLPTzL+8cx/7lXXP6y7ve9Fcq++L5D6fnz96cvv2Gyrodkf7ta98Va/LhGjGG4yWNfMZOOJxf
#T10fgg+wx8KLhfIO7708+fH88XdPf6Jam+ckDvEfMUlc7RKMkwNNRaA+SoOzAnT44rsn3yKsq57xjTcviDscyG6C4m5F4W9fdeE8
#mAj7UdZDtCIOvhbWeRLrYW6t/c3J2bbagxWqZdbCbj9iQDRrF6uYPypXqWr8P/a+BTqupDqw+qPXUutjS7Ilf4bxc3tkv5ZabcmS
#PbZseUa2ZVszsmQkecaDpqenrW7Zbas/069ly6PR7AAJvzAJEGBZYFkySzJAYEk2LHA4JIewHNjP4QAnZ89CMnjJyUkCZMluDtnA
#kl3P3nur6r16n27JM4bD2dAzfnp1X31uVd26n6pbVWlJgXStDeYdK4gZISQFGrF4Px/QQDSbW0TRYxTMy/ERIiBge0mzClZcJXmj
#AuzQiPWYeo/5eDGm9+gG2ZVmtbKIL/DptN4zF8MD7CF93J1+cQkvmohbxWSyaTn+DVHa5aXSJRAesxTw6SEEgzk4EpWtQqYd3sRh
#OFgO1KsCwyJXBELPo6MN96aJI1ks2qmplORyOYunWK1eG9Gv02z2tQS8gMzBQUi2qrEY5/daGHE8APkafpRIrXGscisLuXJVPw3E
#PVWqnsaJkHE0VO3CsF2dDI9mfBcxagKEH5rB4uw1JBMl03H6g9YtoJ9z5biQKWI22Om6I/cR6CbspBzPa3aec0e80ghPfbfC8aP4
#zckYlUiuD9h9e171iezO49mRBHErYnT25Nnxc2PIfECyn5wZx7EwN3YCBMLEaX1qek4fvzgxC/weNIWKaZi0aXtu/OKcfn5m4tzY
#zGP6w+OPJchXioMxydSFyUnZWXTquX3rrT4xNTd+ZnzGisd5pnJHrYiQwJuDrrth1o2wHhAxIgGMH61XE2TEpkGLEd6KKBW0MLRr
#l1DYjYUAKDRAy1lvzbh25QZbDTNgozkxdWr8oh+aaY7P9JTA2hRXCtapnpxpNaqlazkQQqClbbSetWuSWynn8TYi7xfgkJhL/bpI
#nOzqWFhuoEaoc6etBHbTqzXSxy7MTU9MQS7nxqfmatTP03nKN7Fc4f1Ak4kewvKrZVmpnxNnk98maZW/bj7IXn2ykek5VuvRAUVG
#2lVS+rWdg8BpOOHZcEpQHXD1CxUG0UY7qU5/LAPU1X02VrTzJKeMQZqCrMFb5HXqVmTrwlkLciNfLNrsIyEm1e3whamJ114YV9sf
#0ItvoCnSYo2b38PhX9P1WA59tlDhN1daQXFXpRWWV4tJALWAuI/SikQ3UDqbw8F2zVyxms5U09CqNlzpR6s2Avl4fXoulO1x4WwV
#OfhR9nAVJXuJaN+lnJw6QaESrppdy4Fabip6fG4FapwuXRudwwsAKCJplcKWlP4DhjB0gM3hMnfahBZOc81tlBsPet4sLdHJWeml
#3PXc0ijqpdzqBAV4dPCgzDxZKd1I44JaqXJTKWimdENGyK3kFvAGgNj5mbEzIF6vgimAAr0AXHz00bHJWLxWTLy34AqYf6Vlc3Rq
#euacT1zuJGhwyW0raNg8C1egBLumAyUwNRx6zfQsV5HAvjXNqFShxe3U1SuZqn4DF8eI/+DyG1n/fBEe72spwyjDdXO6gwJeq/g9
#XyE2oV8rlm7gvVV4cFbU0hSFXm+rUGqlL5w/hVTjYHM6qJWc647qYEcYnDMn9JPTY5PjsyfHDdA7J8dPzim86fTM9DmuoejL+qNn
#x2fG9eUkp7lRZ+YcGpf8Ph4X0TmXn6XRJxrcjespKBVwpbIsXHlqKR6P6Q+ACmygGkdqOqno8Xgivn6OJN9FdlIO18hO79cPHxoG
#GzIuFXtoeDlixMUy7jQiIt6xViSZYFwHJjN6aNiZzLYd0WHEQDsbTA3jOs5ExWJxvNgFaM+Iz48UUyLLaimNhUF22VEwbpZKo/2D
#A729R/A6slF6E0UQjV4XWu51B1Ua6DlDhJnQH8ksLfP3+IhEK6viiIchLJVwdqloXMmD3aA0Q6WAsssoiCKx+xH/gsBfog8Wxg28
#v0Pe0mPEHn+cZlZE1xf4Zee47c9A4Hz/YEpFAaxqbB6wqJ/I9D890H8k/Xh/CjOAfwVonEPDqZ+Bzi59t3AKUTfQNKzminL2bimz
#DIwjV4lTS9A8lIgvKQMvUgLjwjE5kvKad4WqMhV0OVclw9Uo2xQM1lgBbwLSnVbuvDBxU05bz7YWy3dgIZLUAjxUc9ARwV02mdRo
#Qs2vkD25gvZiFnHNg5UH+kIRenklQcZtnBx3VDifa8tn0Y4G6oyn6pYl6ok0UvW1Ge26WFxWEI4/2tI8z1/PpekaGcME9WLE5qHW
#/IWdM7YOggl1jK72T5ZqSFwBmEV2nqZBUvoxnoRP+Dgb3G+g0bQMR01RJhXcsKFNbGg/chOomHbb6qOjuOROuAkw7QSI+6KC49ac
#5zFSvHZYZ1cjRR01zvrnKisnc6sjnPDyN5VFC1FD6pjg/LZaLdi1pRaOErsGtIAzJxfxKAVoQSOutqlRkUgg1hXC2gblQA2R3qJ6
#TxanEqiSvBP4PKW7nUE1SZArE91UiK9VUeS63YOdAV0yj72TOkqZ4P1OTnKq1eiibHnh4ypmMoJZJnRenRHehWqXEBv2VC9hTSKL
#yBQSM7HuX8xySbpUKi0ZlBpYPoSNLGa/uhbnmSCQCjRdYTnb7MnZ9l1dAnblys5yYIVGjsc5yVF3DdTIDcSUH1IrLqRWZMYEHhBT
#W7VGfW6lWsHL3uav8Vkz7F2aHKUpMpyUIq/DXDFlUwB0MgAp5ciGehXr5hyS6/Rzdt0+truY69R2L6LS7t+CohXLdgFqF7q7K+vX
#TQnZDVlX88t2xoqZgJhxLXdzdClTuJTN6Csj+gofEo6RC1F/BjJdLLXRjXgmjfIrwBJguKI+aOAmIDkpLLRZHFMI5hUyuXMY6WaS
#FSIVyGUC7sYm7CwPQ1yNla5ZSyfCywcXNCaK1zN40glvzGSM36RJPHBUVSFtPHjXC1sE721D0VOHzRb92ezJ6QtTc0ZvXF/wKsVU
#h9EH9LGpU5aCfJwryGJ6pQqyDu0dlffOxxZiKZWyi/rxUf2Qr8Sp1RxzpRIoncWbAp0KrgZAkdmk/ijdcKcv5m7Yvthr9QwdngMa
#ODg3ODroUzf6MGBXS7EdcDincTBXMsXLOePAgEty0pwmzuTypS6x1gpGYSkPWo5jtSnuzuxw3KlgOXRCvxpNTM2Oz8zh/MC0MqUq
#ZgT4BIYyw2NNLsb1R8YmL4zPGg8kxH/xGvxY/PyyFTaHMg5kOTEc9FVXXfB3CYq/5oAKrU1a7xPFau4y6NQ3XWsIduMWq9DHOZsX
#A5ncGR3Z/ur+RKI2qTLfLmttz6Ir83Lu9ozjLMvJ6anTkxMn58TA109N64IAkfRoYzPUfmkZ/fZo6Pr2gLP0qt2uznoSB+frmxDC
#P/Mjwym9T4/1x+BJgOGRFK6Y0uqnWOSw1kNTcbkMJlifXMVzsD9SVer1ewKX1gbhfzA5D1nMENOB2juwYd5n57jmw82EeCFVy5Kw
#ZRxFClIOiQ5iaH5k8MDhlEMrJkltGyBlaZhAAl/2XTHKXobvGf0uApX7ayzJzRNzvaw8L4KpuC3IFd5edjB27DyeVnSB+ExA3vTw
#/1ANnQ1/MZq49GTAoVYO2HnDWBqf1/REF2B3/NqlivlQT0YS7i1Zuhc743Moj03zG8M8ycF6hZfByvXkREBvsdbGCWdsAY7T+BtA
#GdcHMo4IpSp0GBwutMTs7US3gMbyBmyN2TcmKVkJ/dCwrT15hh3pUVYVDhx2NUIsX0wXxPYR0tLtlNYXoilr+4krloDH3fmKqXw/
#lOQnC60jR45Y3ZleqJNmwZ3IWaatZoq3BPcqgPzW6urqCJoH/oMTBdhHthpH/MMegDYTESXUM1BVeXFi/MzElDJb6ZHZtYSL/9pQ
#ghi9XABKbFTEWItafmLm5NjsOCo5U7pD4Bw7vm+fPucB6+OTEJ2/TZ2yF6NsaWVhZ0tA10drV4/vj6xz6g5pdMsQ0n3Kqzu4+2bj
#SpEqwallFfltYZpQlq99VKNXIszrN41jwdzz3drJVPOnCI6ErjRilf5HO9Kre+3h2+ZwTUHuGSiDdchbdIQ+gDKPu3ISOurZjpio
#ZvGtr3lTrDvU7YK6SwqgY3s1bnXunwAWSR87TvZFlWpq1dq/kkKq+1g1g9yYcWLkRUOZRvKghVh4UFDMHC9V1qNMv8VpmwuIlREH
#McZ9EOAz8AAUMooPHmfDoAZGHM+L4FNoqSSEqRJ7IKb3kh3Po/u07yvo4zoNylucbGpcqZyY0o0eM46zFU8l9HlOyajDCnSchoNH
#8b/7+Amy85KaWszJ6XPnJuYUAVB7ItqddGZ6cvLE2MmHY/GjOp3XWUOxd6nmXB99tXr5MiXy1T6WeRLQPtwavNSNIcaGlflLGbH5
#TyjzivpevgPV3bWMUFaXETaoqt81kb6w7J6iFiN7ekafODM1PTPOx7j0xLDHNTRcAiWncJ5IkM9EQuhNCakLJbgvRIK7QHhF0gat
#dilpl8n0X0/P9NIPx9FWzIaBPfDFRJ/YVBOMS4aaO359NDesSb4i7XEDxfH2dhhR3khil6ejJC+rBdpA1wRyx/UyqAIfdbhVMIMn
#ad3IewXp+toO/vypb2b8/OTYSZX8pJ9HTSLaECEBKRW4q4nLaq1jra5jpW7ICF0Pq42Zphu1O12Z8T2xjliH7hgl9PNx5uGtex3D
#FhQXICpptjrcgoBB8sWPXwzpVMllyriez3OMxeSBK9yjRTquAP647mx5iZsjXJ8UPiykddL+Hktkc/8W7t1i+ZaTWwV6LGFZfOcs
#4mLXhntoL+VyZWNwoA4rd04tyV8tc1L+gDUu4SzvPGewcnE3Lhd7EnpWrgqpDtRVdSH4uLIOrC6cWuLPuQBu5Vyl5UTCwIuYv3Cr
#1cV3SUUya6nj6zUj/oR2IVprxLbY562WSNlTfRur5yvzGKqq0/zruKDjj9zQOdUrPud3f3kKbVjyFadhVsily5mb5I6hrihtZMFn
#2X/Bp1d13XKYROoCiHstXfQdaYO+M/DkuWDB8PJc39KV1YnZC+cMy8EMqQwEU7+0hMzcAtAZ+qK5o8SJNyTshavi+rbemZnpC+f1
#E48p7q/TM6fGZxBEnOYUlCD0/6rlYcnbILO0pLRBoXbVCkmhx6Efk1DxrNcFNGj5/WuErVNYl/WHpiemrEMzuNtmEoZgOWl5sfIa
#lZM1O8tGVHotwThaVeyCEXR7sIMpxWtA8TVxxqH5PL4tSawj0PcFHKa4qIvfaSKjLM/Kge90pEgqYW3LMjm4GEutEWOr0BoYNKTw
#hSoBd8MZu+UCup/I4lK2N4WokKB2XEfHTTPwb8BaEaA8qXdUU8Wk/Vjm8lI1DZEQd2lNYzWE1qmGFqpyDVpQPOUBZjM/buSG3jeq
#DyrrUUoMcfTIUp0o4hSSrB2FL8rLDVnWYPbhopZEoMlnl7hxDkkhe/gkm1f8jHjXLUSqTPGmou+R8xCRrKWj8iwtTu0zCWJVyEl5
#TicVl2uTNTvumBYUM+EStkIwZZqbf7AAKXVym38TwVQ9JU6Z4OaJFKpQZ7LVjwv8q3CvKOZWqobh8KOp5QdE4o87OgjPLKg79nxd
#PVOZD5+3lhyUeUC5TlS2qdte23BMFlkrQgDlryl14Qeg4j2lrMrIatdvRyfGEkU3Ja0ppFRCc9NwUVRCd7qFGP0rdvHoJMIrLb1J
#wcpf8yBlrztb6qu9DEfLq7IRl5VGtKeK+QclnJJMTp7iBJ/trVL2ZzuxHUz5rG2IfYnE91THHP5ib5O1hoqZECfq0FlMqzFKKbxw
#iOfRyk6eGO2NBGdFFBWzR6aD79k1rDgduFO1tXiLN4r9Mij+FqpiYCMjIR+YUf3ACM49AnJ0DBh5xVBMikdMTsYc8sRcIJkqYpq5
#EY/OIMLEZMnZFVnIcZEB99Aj7mp9O+b4RmxV1IjLS/TXlWvpS/lCHhDgF3CrLp5eT8Q6sp0mX5OK+lJI0poIwMTkDrzy+Z1a8r8g
#zpGSmgD+pVGIL3zg4ZvcTxKrxxLujhJha0ECd1KEQFSAFanD19On0Tx4oO50gX8ze3QS0cXzwpmtwrlgQq+vn5jySL36GgqXHhVb
#dMjJLJ6lCOAHPm9FYP7qZmqKPKjUFAYVlySwzgeDD+Jd4cuK1mEx4IovA64oDNiFlr2qDpFkgMqmIYzwO9ZzPNqYOoT4iWWydwtO
#72jP0Clwoe8zdGrpvJwUJWXKBRlbuS0oe53qWCNYsJehEEp17R85TDga0pG44OtIjL9yLYPG4bBD72JMyxEtOish9oTxvWBiD5hn
#79dGGsoatIJl02YyHLhyq5q0ZtTaeEaiGIgF10B0jbVCjbFW8BtrBf+xVrDHmjq8Cipl+jkdLDhiuYdawTHU/EYBkoY9EBzFObOt
#7X+wYX3rThQreyiXnUNZTEHy+Py9ns7FJxspNr3VUNr44XxpfjjfCA2a8rx7cpH07fWVtrJpHaBAx3VkrgOPwAvdFNd4OteBAlm+
#/cU62MNn6wvmvIg5l8wkCm2IZmRdZgVumsc9h+ouGdoohIr3omdKHqBSPaSlpliyXLyMi0LJq2X5N8dfbuQuoXsz7QgQ50/iwR7z
#Y/2vszcZ9d0HcREHP2tnuTqPn2SBOHe1yBUd5+Y/m4+4tqf8bHycM8vVK1zBy1Rz6dI1dLa2RDRoWdnSDWUmSdm1ZrN467QNG3dc
#P0YwqEFVcYYDz5hO6zCU+TQ+R/sUtexT8wMpUNjQIuUlj+hPJculMlKlk5+jOvtUHL2FCVOLrdMio42F9K6rehIjcpBePzgwMODs
#LMt1X7rxi8MvqDrKnC2ODtp6dx03oAm0hw4NDKRGeFxA3LgmjDa1H3E+2lKqs7lcQTjR5suioYWnsLKPzaIyuY8Nl1somtz6t1ym
#OfaoUkX8HsetYIe9Um8js4I1dtv0+myJxI2zbgdpqlRdgVwhRzloNdA1hAMyzT94fVDXn0fcuDs3R1bB0MpDevFXLMZWL3s+LYrZ
#2wbeqG37JZRjM9yOLdJ/gKss9hoEngmBVpBwDednRCxXlszMYs4YOuC/T9XpOuY5XsJyzhYtbB0XQQS3UX9vQ5wnljSvZA4cPMTz
#T9JmQRzNySu5lWz+cg5MqbhVYJU7RIredJ67lIoDHeFgISwcw0OmxhKsDW48LTY5L9q2OpGQCOQl8jsia9PWPl1Tw3ZbChoXDcjd
#j+6kYWjE1dx9ZpMd331GFqvY5ne3uT4ewhala3H01y7ncZOictJbck4emXQuvzJRdJwel6Qj77hHHG/TbCZXgL7hm/VR9SX+hl9A
#kSzdSFdy0G3pTDaLp5Orn8VWjTQ8l3NpvEIWvh4a5vwJTxerrojZTt5xe2i5b25ylvxdoL2v5eANGbwpj/MXWYozn/D8OjwHC7DQ
#F5byeKKuOByIrrjXMwsoePEAJqqH7UhDLioG3kWbkFkmRA6yIgpLQrTxVCeQ42m8VNSIzw+m3LxO8VABVm+c5MceAJWJjdVz/BwD
#ETLNpeTs7KQICc3A7VIulpl4jQllfn5/jzmi91ToOConziBdYfTThmze9WepuhVD7d8ToKNgH8/wjEUU6VDEFXycZ8Klr1H7eLXz
#eAoBn4eAtlBjcKB1DuKoIqPLlVK1tFBaUqNj2fsHk4M8mTjeAc8/G7C7CZSK5TL1j9IknFwugy1arfLOsw48jAlyiqnSWHQOJsub
#1Ef4zdnElIto4iQdJkXoOFaO3fHQjaO6ksRri9N8VBnqZ2vbDZ5vrZyKQdkskxBP8vopdAldnS5AD4KeL8hysQA59WbiLnUxygcK
#H+O5JcjOtDLJe5oMqj8rnDCU4/pcZLaySCIJasBv1xLT1xf7T5cqNzJ4uwG+cVcqt4K9smhx5ZVFuWU/EYsDJdqHFQwftEeLlAFY
#nId4VQIoZtO4/Vy0RunSVTp3prpsjh5AoSJQpUNClPrgYqncuJ5dLpRNg1ICB1kGAy9jLuTz/LiRuGThchu83UecsKB8wKoMUgJ6
#hAr2i8LRMGIn+e2E/XiSQoxOV4SmWKDTTPYjMketaw5rF+fOazJXvFy9InRB2mQJlVP9jnyS4r72fsygUlqK0RxvPx6WmvMWuLCM
#u61ESlPR3VSV2BCfhT/eiLdIjOnK2/6qZkufbuAaiDhWj2qj9rgLIxcpeyt7sV9t9f5pWq03ea3NYn5xsW4rz+AVzpVcpf98CXrq
#pmisioDWTQojowL2v1riqfGpxzbUqbOimkqxwnzqNysL+j5Mue+oni9cVsJE1iNHdbpVUoXvWy6i6tifp9UCSLdIiKEUwm439X14
#IwXA0TDth4ItAPRyoT9DAkpkFlM6A4WrPfyUXija7qZejuEiXMv1yTqOsk8fdNoIYAvIjyPc1Ug5gASYVqkESnblskq+lcwNya4q
#RE2Iq1HkFhtXqS7FVtfsGXPHQRamAemT2Zxj6JONBUk89osi07PC69QPTWAxeCMSaI3wB10h3dwua7csPxdXcDWcRVIa1+ttipMm
#ysm5vm2OH9Q9yK6yF+axlFTyOiJMFcP9HTC2F8SKid1S9T3E5MJMzK4MqesuCrEYvKLRc27PqxArrkjXDMTYOf5x47VVUW+mtE8J
#TA3raNoUdwKetw6nTVFnGn5Cjx98UVfMnUd1hZ+UQRdXm3JMCIGLdzeUsrbAzZbSZ8bn3Mh6uhG9b+TRxrwtcN7K2VvlBE2pLNMn
#+/xjYzkJSkXlptevH7OROpd3MkoVs7YsVR211xL68MCwJ98yVZ6OqbZXHmvlZsdwH46hHNCLvUOvqbV6pdG5vrWLEp/dM431s4Ti
#PS1j7eTHEog6a24moai1UfJ3eufrwNS6g96ckRl5/Lg22HtZ9dyLV42Nu6n2W4vKv2BNVpsi5CK4d51XiCjjKT7GaQpR7Co4MJCK
#k510gG+MODgQ98TnC5cigYyvugK76a7AZ/OsWWNXm+43Hs/2xXHuuOzphMIvWnsTifos+2EDFZKXKyWwXAbd7u93l2qtU4JjtbgU
#X2k3cQLIiBHv2B+L+7QDagiGY90BN5Mdwv3wQ9bhfLUzFnfY1MnaOmge8z2M+fpkytce9tMZZ/liNreSxHuFKSgu/II3OjRpA8XE
#HDn4lUajWt5kDg8/turNVr363K917ozGanehPHTuBN4mXjyft46es6dMZnIw/MQhdE4pKVdMlIzWddQFEc2nTMhR1xbAfKpEjU5n
#5G2wguLMYx5eQz7iai+PNqUY8EJ5OD89u772UPbXHuh5h1oBaEg1TP2xcr7/4dxNHyNf5EznIsxbtwak5H4wvH2CzrjPgPImJkJp
#HUiNXGOD5J1R1HIRV7JKlfzTuWxN5oV7dizzwDJifGukSD9xIYc4Q8MfLc/BQBvMVG5cWC9j57EbG8xc+j/WzVnZNbhx6foKGbMf
#bU1djNEqVQyvdKXfHn0BFHO8KoRijugLlZJp9tPlKmiYmnIaFzHS89VXiTXuQxSTcxzvmkwTmxapTLBlL9nmy5K6cGqr1kCRK62x
#fHkED2HJg3Z/OCFPjnDE4EfsxvAchwGKcTeGinVkUqZaxfsYTeusJH5OUpKa4cCRVz5+KqTw0NqmvU2Oxk+cFnxqtsxdqR5uK+KX
#/JriCj1o1ivI/mnhBi+nddwFrFwUStNb/Ga8UlE0hJse8KcuUmFdPREWruFktm3MjvaYR/XzwJNH9x/Vz4LxiHcOH9VnwdqeBboe
#ncysHNXPZVb6xy7nRvnJbHwtKbHOAppvW9qTeJbJDMoD4NQHSEGp9MXrNVi3nWlLF+rFQIjzRmw2V+23ZhcWrsVTGxk0dFu3p1io
#pyQqv1kAvwpCEn9SWX+fE/42uA9IXfnzX+ursdJ3p5y0XtuqRLRxEhqIuXvkF1VBs6fKfNZeXh333qgKiIrWL6IOaKviYi2yVKri
#iuQSHre/ks5czjkmwZaI6y4ll/jSinVgMv4Wl5eWFKcoYN5LdCuW4/olK3+l0oIzY3rV+PFkhGnjIMxKeJ1w2ZJkMl7epHpgNjVO
#lH21dLmAl5mhcSrvNUteBqIw0/jOy0XvIpzLVVdfSgtVGGzQYLjw7lwXhHQOcw+dyPZzq5+XRWabYykncz3Dz3/3W+Sh67bQVW8/
#2FB9K2Cfuc8Io1w5i3auByFCMQGKyZNEeXT3LK19pDPWGf0dL/ke4iyWwrgcdy/EONe3Dqh0u+7iFqH181rA4hOLNBz6M5bkFIOD
#5k/EK2+mYqmfzna+g/WuV7BmJVbXJ4ShJVfZnUvpyoK44hCGN6xJB0nXhVCcK8gbGChkk3omm+WEXocek1flNUp+6ZyUidHR0rcc
#ytwGnk1MxEEfHZuZmpg6gz6juojDd+Mp9y8d5dcV8DNV8c5CUM+yeRNnauWiiNIo3C3FiFnXJsYSPtcygTrpamZxFCC/udHKBlLS
#5XephH3vE6R1pDGBMOgQVZrcj8ma119QqLc8Qw4JwpWDiH6lamDw/Mz03PTJ6cn03ORsenZ85pHxmbg7JV5BnS8sFxTXCEwKKR7h
#AHy9Ppg+4ElIZIPYpoFhADU58E84V0OcwpnftGe73sDTKZEdDWTWXhmqJWfRd2ehtLyUJXK6BKOySL1Px/scJRUcjwAoL+El1egI
#olzXZV/jxr2TjCqu/FVH+T7rhHBD4g4VnG0b9RNKSuJeIugGnrteNyOqAr9tY7mMusLI/v3w6MniuVs2Vdv3fPZk41ydoHajpvcQ
#oS9Rq+te1VLZ6E2rM0A16iO6z7yyXM2WbhTrVITf7pnkfwwRmp04Mzc+cy5BJdaPN8HvcJLRZMFqM3qbTJzzgEtmURhVado0kE6T
#jZBOI99Lp4VtwJngL++E/v/0l5TTUz/DMuiW54MHa9//PuC+/3nwwOAw0w/+DHGyfv/E73+2+t+60/juU8Kd9//Q4NAv+//n8vPp
#f6HkJKsrd6nC9e9/p6+u/j84dPDQL+9//3n8BlE5+qV0/yf78xn/1lsyu7R0N8qoP/4P+fD/gweHD/5y/P88fude9w4Wgr9h+Pfy
#y4x9TsAf3EDa5+Bf267Pt7FPN31t9+cCk1/bPXclb+JGgsuVTMHa3pHTK8tFupR6elbHax2Tra3R+0Qe58cZmwyEWPVP3vxxme93
#WUxvDkDvX4SAxmGx6/DQRaGMbab3IMebMfsv+yKH4y/EnvxVjIr/23+tP/T7xjJj06Iy94R8KvlhxlowDcSb20CbWD/Ar1EJNkL4
#rBJO4gQE/DUeEfW6aOOtZPFksmJWFpjADXCkir7OGe9B+D9ZyS2VFjiuiDPl9YQn3gk3muHr/O9ZStLAskcZ+8QRxgIbqqT3d29w
#FZKGe2PB0Bq9ACAoAUEBCElASADCEhAWgAYJaBAATQI0AYhIQEQAGiWgUQCaJIBeALfOgSA7L/AMdhN68AeRClYgUCZ0gpX9+IqI
#BGPQlA9SicFdm6ig4HbKPlgZxEiYcdDoZizau6MyBhD4c4H/yfA/b8U/gEtU4iJfjO1A2oDUzgGNPRug9m4PVh4KsHLlEjyCt7Vd
#EMHcBnlj1GgQIAMI2QGBbgOi9yFoN4LuIVBQgAYR9BoChQQohqB7CRQWoAMI2kWgBgEaQpCOBWoCMoyQGEKg7n2hxBVjDwSehUe4
#p79777PwKXxbO4yxYDxHe57DLwY0UF9pL4SjffdqpX3w0hxcbYUvkZIBgUkDkNNKcXjVStAC0f4/vRXVEppW6oPAS7dCe2+xIDY9
#ezBobMOozfAwEtgItzUDC+tHvM0kIgadFV3bSv0AzROtfA4ab/vzUNdAT1ewBG0RfaGnW+QDFdVe6NkmQtB52tth6AdeMA5gD8Lb
#PTgGvsl6/5EJjegFlosEQpjb6eDqVqp2cG+vMcTjdw4EWBsfau3GMFa4gxkH8duXgluMQ/CS6AmW7se/rwmWDmNVtwZLMLiiZ/pb
#grwxuq7eDvV29UJeGpsNIM9i7eYIoBbVgms9UGLIgOK1/kBvqFkTDbi2jxoTYkVbRGUgmZbQRSCCj6NYbJtS166B1mCksiPIyoaO
#tEfd0Bpc3QSZaauYZUe4dAxTzTe1hx8TKaHftKv7J4KRjoZdyW5jFL53NFSexlyO07saD9M9ZkBhfRDn3XYc40HsKipVLa+JE4E5
#hrRT+VOI7+6a0gn69LfwSXsGkxgnASCgPwVoI70/24KfoM/61vZi7re1o0gm41jqaXjsxfYNswxnn+2hDrZtB68Kq4RDEk327BlM
#0IzoM4FJO5LeWf51wv6qpgqL71TJ0kOcNKC8EAOSBY4K5ZUeRuLQqCcTO4NalwFoanxQaLxPS5OIZ1fvE8FVKDPc34pDTevXgkYP
#9l3vTuBdKKdgaLZXGrF0qHOfATn09fS37O1gt7cCKe7U+nYZ09g6DlizcR6JznytoNEZHJO3GvZ2Nd9ikV4WEALx7FnWgLQuy4rU
#LmuTT1mbRFmzAHvInBNlXVivrBAD0cr5X/ca1j3YtdZBAxoJdK0TX1ehHuHSI9gBxIF201Ds3LvltnavzX12u7jPJsl9It3U4ILd
#fF9lN9hXiBPWeOdVPu53DjSwnzKS3+2iOwK9HIcQ760OVnoUs3rIhOGu9QjoWheixbtVRgzSkOqPUGX6Ao1rwHPDUUdmWukiDoMQ
#Dei1bqSJ8JpO3x/DbmuObDsQ0SJr25B6Q6XXUZOH927pazDm4b21KTGsNZUex1Zf246pm0opCuzggScosJMH0hS4BwOh0pMUuJcH
#MhQANMPEgnuZ6Kt3sMV/YCFJF1mAwPBs74p2NVdiSBtt2OCXkBf19TeiCgIYccS3DUWbSlnMNtrXIWDbhxoFrLmRd8d/vhVtTGiN
#CvfXImYOhxHnx1vYkXOSH4fZhcckLiGGMiKKfWQAH9FubY8GKycAI620iIRyGR/9+MGuC/RpI9sep/QaiwLXbEZ+e1zw2z4iu40z
#1ECveQUJbONE2akdfgxJnVNmZyTYLmiTU0274PClPLbMNifQlptdnY1dnU1dnVH45CaHzub25sS97c2cIDob4Y2oobMJ3ogUOqPU
#yhHBd5G5iiLc3LWdCxkBeSJEEOpGlTtfQXijCqkipEmFvAEhURXyLp4bkaAK/xCHX4XAwyr8owB3NdI1eL49JaOUwFaNtvMxPvKB
#2y+/fKulXUtE2sVAJ7WupfIZJNmC0mZFetf28u/UMsY+HNSrJSTl1TK2aXh9GWVLo57Kf8BCnrJb7hsYriC2SoJvUYWQu7z9SRv6
#A4yKrF8F/gSAjuZsDEMjhVXIDoAQgdgN0lPRARih984Grb1BEZMJLiYfcItJNjbJx8nn4R9oKuxHjHQShmMOTQpoOrYEFPztgLA1
#xO9vIIzjsTVox8cxNhOkeIKPJhqDq8jbE8BPu4nL38nQ6evwjhvR4f1/6extkCFYntKTUerJZuM+FASRi4aJHKtRdCaILm1/oFeL
#DEQj2kCoqy+8vS+wrVXInSqieJ9T6T2CaC4TmvjF2IQSEnhM30ZoBXSRckdj9zaugzQqsYx21C8aK4fDUr+AFkMRyLWqRq5k+FPZ
#sTASFEZWaWDSjzCQoDQ3QUVUwMWwi+QWAeAY5DrRoKCu4CrUPVypIkyhM3MF0bvJSHXvcxKbUNjfB0l2CIWdagP6utDLe7ZFxMt2
#KOhpOX5sfZ3k9im2a4GTItp39yMNAr2B5rGK4jSJei0Lru2nv1vX+unvMxxsdJA2RyFjjTLFPEANRL0e83gW8xgWeRykv6G1Q/Q3
#vHa/yHOI58mjGZ08TwwZz4k8NQZp2Ca0E17DZc3qFvj+2K6Vq0B2QW1ti23BbGtg5W7RIKEXjNdjFj8Nmp2oDKH1GDTfgEi10usb
#8bXNhm6i11/B182U5a9i8t8x34RdtuOq8Wbsj7fA4zkQfGHzrQjuKr0NAS1kJaPeesTSW38NB44mbJl9Grdldmnclul2KLCKdAL7
#Vmit8NJLL0KtBflJ4x/12l4ygFEvB8mKczLtYtBK/c9W+oQ1qFh/qG82o75JBuDe3oeE2d5NlX47VjppArbaczE+G8BhMyFehWiI
#qtB1O8BtrzD7juBjilAMPdPlY3GEVrEMRSSGVlExcwvE0Op2F7RK0B0u6BsIutMFPdSA0Htc0FMEfY0L+i7K4V4XdIri6g7pYjWD
#MlbalbEyKuj8uKDrY5yuOdjYwul61BorVm7YfgeA/3cQn4fcw2TeGc8zy+ohBdrAnt8mYqBtC8MgjhHJMtQ6AruO38NZYkAxsAKK
#WRZQErsNtIBioAUqSw12+l9X0yMSfgneZSewLTmtI7irdzvHKajgFFRwCtbBKagUEaz8wCoiqBiLdqfIPulU+uSE6JOTok/GeJ9w
#sLGV98kJm3+h7RKHvthCfdHPjQ1kfs1a4iCMrAEaWfhsCTZ2X6Rw464tx/4T2nvExIPPDCKB/wZkd+TTOCS0xFSEA1ffgYORv74T
#K5bA6r4L9aSOkPGbyBQeCHb1RInLBpvWDlB2xGtDQQNGU9933oHzJav4oTX4DP65vRWGxM7gVpEK8nkPjmiOS0e49F4MfWfi5Zdf
#7myIVI5rIONsXCpZDQUOV/j/OZMK/85b2zu14K7bHA9CoF0z3gffb3U6wca/EOMBbQ0GnP8tX2d9cTJH29jf/h9uKxzicUPG+3lk
#1GvuB71mK7XxEG/jg9TG3YfOBo0PQLSIPeW0a3/pg9huqyg3yCwx/yWO0eAqChDjQ1iPq1AP818hTXwYe/0wmjpa4prWfZQ3GAJK
#v4Ux3w4xI4pZ8gIqJ83UqxTpX2MmH0GhDK1n/Db2yRj1CeIZbA+vjVDlSVjxycu+7xQCWAZ+6IRPI9Qr98heIekWNl7EXoY+PUKo
#dSdPBVfxtfRRLO9j+HgXaQIdDZwQxoLdVqENa0ftQvmMUd93fkIVww+gPjxz1EkKVGgDkYIo5+Pwqv89ILq/Q4W8EyBDwzu7TRyj
#nVqHVvmwJkeZpkTkipVG4878XXg83XLrUa1rfyePk2gWcUl75PDDAn7YgoPeCdRDddpCfQR/jlg1a48Yn0ASi9WL1Gh8kogI9WzU
#p/8B/n0V/v0h1GObnJuGf2DKsacB9l8UOON6CftvAPsh/AMmywR9DhN9/htJnyH2efjeRfR5jNPncc4DhoLmMdQkHiCKwWdkrdd6
#37JmWO+VT0BDrsU5JT4UIf5WaYsA9a3iJJs99onQftMmtGOC0B6kSo8KQtuOfb6PCO1BQWgPOvv8GCc07POOhttbcRGivcH4FEM9
#vfR7snsHAANgEr+PYvxeePm38LJ9aAvHGcJ/gOMHa9F3REk1gqkiPNVuETdCcXH2igNIFlGFb7UBBTQpsxJ6Z6NogNMRNHY9Mww8
#h9vaqFRQjE8jKeidTUgMxzgVPGA1SHsT50Y7fL9KpiRp5CvwDzRjdn+A97/8jSOtAOxMgC8hxcWyDcZ5Ct7+mQI/xLNWeFiIDcP3
#bqKRMU4jJzmNjMHwfjKyirMhBirtpX+HfQBC6zM2h8cUwca1U4Q0SaNg0NiBffznNK5PkYR55hR18TE0HreKVJDPZyEf5CHjvJBK
#hagq4aAqS6IcI0YyxiXKuF0eSBRQm/puVYOr41ycjDvpaUwRJ9ATYVHYByNkt7h7EERGA/bGmFUCEJ8tMmww7x0uL66z0l8yXcqL
#/x0JSHlxQm3rE7MPnQiIFTU0VK4PJweSQwNDg6hog6aNi+yHQWDvAWvjI/D3w6AA7JmtVtBZG2OcAnL+IjD7PRdmWXiAr1/uOXNh
#AhqXbYHw+8A23HNiCSfhJP8IPNr9QnMTzpr9NDCEjABLv8ZtI6KbM5wuUM9nn0Vew4gWiN6QfpDn4PolVhPTQhE0CbeTSrg/ymuj
#sc7Gz7Zp7Fl6/pn2/tZN7L+2Ifxc5JEmjeUarzRr7I8j+HyWnh+g5xDBA/T+3QimnaQc/of22bYo29RU1TT2RXhvY9siJ5qjbHdz
#16Yoeyla1aLsH1lV62Dfbd/R0sY6Nr/U3MW+GlgJauwnkM8O9n2md2jA/V6MRtnftXxsM+QMX6Psyy2Y54X2F6Mae2c7fv3H5k+2
#auzXW7DEP27HnMv0jLTg87c6MP43GMYcIvjrowj5QvOL0S72Oioxr2FuBwj/+6LPbtJYc+BZwPMhwvPfN+Hz/fR8YhNi8gcBjJ+l
#VMNUu0jHS81t7G/aX4J2OB5AiLEZ3x9twTwXI+8HDLe3fratg72nYUeLxjoC+P4xeH8j+1ETrlz3BbBfyg1Yytc3V7VNgb8Og6UZ
#+MMOhP9V22TwXvaFhiFI+2cM2+Fb1A6LrS8Dtl9tQExeasJnBuoVY6stR6DXbgTw/cubjgABHW7A+G+mOP8X4G3sdCti+B+pZX60
#+T1Q3+c7sfT/2YbPCr0/Re+7qd1Wqd1uU4880DK2GfJsnYTW+3z0xWiaPY2Le+xrUcz5bc0nmjvYPVTTgaYfdnSwxY4dLR2sSs/3
#bl7c3MHeBs+97NGGN7W3sbaGl5qJGmndPED/bWYvN3ZFR63QX0e7ojh9vIWFApvZEzCybsJwOMjeCKGFIIZ2g20e2r2ZVSkUwxB8
#A4UPQj1shELvoZDBjlHoFIX62HEK4cj5JutnD1IIV5W/yYbYCQp9KoihY5ACQ1+i0Bg7DZjtC3+kIcBeCr0Iz9bwx+H5Jf4MITwX
#/iQ8H6Q4b6Ln79DX/xX6vYZB1tPyaXh+r/lzDbvZaOgL8Bxo/TI8t7fj+wcbvwYxP9WEOa9S/r/f8W14/rAZnz9uealBY2+Nfhee
#XdrH4fkr0Y/A84824bNAz/Z2fL6hAZ/HNuPz3Ro+D4W+Dc/jHS82dLEvRf+i4RAbCv4Q3juCfwHPAPs7+FrdxKC37+/EnH+DSrnZ
#gO/Pt+LzciCsOeN8inIutjQKeIC9P4D1/V6gFd6/xLZqdpzXWGn/vAnTYg4B9kKgB2L+KNBL8ffD8xMBNRXPOQzw32VHPHnyr6ME
#HxNpz6PQZF9p/HH0+UCAXRShUDNSVIZCb2q8N9QTCLK8CPWGHtWCrCJCmeiFQIg9LULF6GYWYm8UoWOdFwJh9msidKZzM6hX7xah
#HwSfDzSwD4rQj0G0N7DfFqE9bY8Dpp8UofvbnoTQZ0ToR63PByLsj0SouS3AIuyrIvRw2/OBRvZ1EXoCvjWyb4nQVsCliX1XhO4D
#XJrYf+ehbc8B54mys7t53f+k4UIgyqZFaFMzhh4RoQutGEqJ0FfoW5ZCf9X0/cYccIAlEfr7xqsQWuahwHjoqtbMnuPpQFo+qrUw
#nA3GUCeEWtkxCr2TtXaWtTb2iAh9FfhJG3sLhV7PFhue1jax793HQ0Odb9Ta2cUeHlpof5vWyd4hQu/ueK+2lX20h+fS2/KC1s22
#7OWhD/2/9p4FOq7iujvz9vN2pV1pVzHYDiYrsLEV7NXHMrbBGGR9sIIly9bKxhCyflo9Sw+vdpf92FYdYEWA1AHSEso54ZeDm6+b
#EkJKaMiBBieQhBynqRtMAw0nuCEhPiShzmlOcEmg9955bz+SDE1Pm5y2O/a7786dO3fu3Jm5M+/p7Yz2qjwTiucpzq+gD8S0pSqm
#+T+DnMuXKc66hgc9C+Ary1SaD73iQnjdjjUEKPb+5Sr2UR/FjkRV7Dnfx7WF0NiqYm+GH/UshDE79qu6RpxnP9Natvwi+AnH7ph/
#S+CwZxE0tinOCDyNsRE79mE46nkPfMCO3SZe9DTDuB17QXjgXCjaMZdsxNi32solLIYX2solLIafVqX9kmMfgrPkCUxztatYHc7P
#S+AX7WXO8+B1O+1K+Lh2HlzUUZnW06HSvgQUu3FlZdptK1XaNZzvHzh2XLwcprTFq1TsMk8nxjpXldOWwlOry2lL4dnV5bRl8LO1
#5bRl8PracloLxC4qp9G6R8A/6v91GPER9Gll2F5P8JIAraDm1TsUCafChL+iE37SNxNXPH1hsINAz0aU1U2Ef8X/dnkr8axkaU0O
#XcB2z2yoAY3pY9iOx3AdegzXgsdwxBcDAkJArbIAoR+tUww0QjvDtQy7GPYz3MJwB0OD81oI5+HzCcFplnOAU+/gVKIvhMMIl4Ih
#ioEVcIhb5BC3xPOC+Kc4l5DFQB/cDf/q2oSztcIfqv8AjgzCFzNczrCTYbPN/2b9Q9DCeLt8vvHrONsSvlamPMdw3s0GfgsoL1wv
#+uWlMiRi8An/IrFFvhxeInbIe9CLGjLU1CIslvB+zLtG3A2/rF+P8EP1mxGSt5uWK+t2iOehF8f7KfA0TYhTcCwwKQ7IsaZrEX4e
#Z4MT8BGU2S/H5X6E9Z4RcYf8qe92LPGb+h3ChzW9B2ELzgY+cbP2EMK++hExxnUfY63ulvt9I+Kg/JH+eZHkWljiN3XfFA/L5/wv
#CMrVCA/Lr3pewLL6Q42wQPyt9lOU/wP9VdEuf+l+Q6yVXwoF5GPyd8FmeVgude8Xea5RHh4I1YvD8i5tjfwgUz7IlJtgC661bmIN
#b2IdnpFf8G+WJ+C+YEwelW82Ximfl19tWIPQYhgIEbzevQZ5/txD8I7AGnkb2/kv2M7HJdHvw1IWiX5xwE122BC6U36KaxqDrU2v
#ov5LfUdkDO7yH0X6Qm2NOCnfcP1AnpSP6iPiPuwpP0IJz4ofy1PyX9yvIHy58VVJLRXWboKLG+Zrf2238vtDHdpa+e3wFdojXOLj
#8AV9jcCywreLo+Jznpu1o+Lr4VsRRvwf156Cz3n+CiFRnoKI/zFtWmZ8O9CGpNtNDB9neDfDQwxD2iuBb2mH4Afhv9ceZsrD8Im6
#Y9oU2/8kU9rlMflb7WH5gusF1CHoX+J6hGvxCNfiCCwJrHQ9C7uxnxwVMa0H8SNo/8fhk/oSF9nnStdR8VjdKMLnQh44yqOjWfte
#+MOY+iPX7a5T2H8+5mrR3ivvcbVrxcADSLkyfAjh9Y1fdPVrC7VHXYfgTvm464dc1stc1lNAZb3MZZ0Qg+ETrrXa/fI11wmx0a25
#+wWN06eAyn0KngutQX4q92Hxl55V7ofFb0KXuB8T1zf1IgT3IMKbsH+eku/2xNyWWBLIuI8LKuW4OII6RyAHj3ibGS6BW6HPsxSu
#gl/pLbAf3tCj6HUavFFowie6KD5FrkZ4LlyK8HwoIlwJf4bwIrgPYTccQng504cRXsoyuxh2QwKe0bvxWXaLp5dhP8oP+nZyqsEw
#wTwJTk3gHPPPusm4hZzv9hWZZ5rhh5Bzi+dmTj2AqS2+B5h+kOEnGX6aUw9h6irfk0w5zPAbDJ9BerfvJcaPM/wxwxNIv8IHgnDB
#UGPoE/vhWl+E8WaG5zJsQfrNvksZ72LYzXAnwwTDIsMHGD7J8CWGL4vd8JgXJJcl74RDupC3wuN6hCmXMjwoiec4wmd00IgSYbhY
#uxNe1p/UEpja7KKadjE0GE4zPMjwMMOXXGQx4Sa8mWEXw53ue+FrXoPxIuKveqcZP84QPFwiw2YPadjsuRW+p1/KlC4P9ZadjBc9
#JL/I+LSHS2d4mOFxhuBlHbyERxhvZrzLy3K8VJed3nthgW4w5TCnvsT0l5Bu6MeZInRKjeh/Q3ZmaOhEf4Dxg5z6EuMXQUIUxbPY
#00+KpbJX7pS3y7vla7KofUL7hvZD7RXtpCZd9S7L5XNf5ZY422r8tuT8un/HuTeqvYkw65degMubCL4hiX5R0IN4Q5DwUYbLOPWf
#3ASb6gjuCBD8DuMLfH6vki1w5tf4ciPuQkjfbnsRR+Mg7sV5nVb6PsR9OPIEalOHeB3O+QLn/gDiAWgA+n61AfEGXAHQ03II8RCO
#UQFhhPTt1Txaz+BqWOJT8wKEZ+LYlTAfV6gC44tQbhFXDH64EcdxHXrQFoS3IF4Pf4p4PXwE8QDchngAPop4BEZwfNyIq4MH4Aj8
#G7jFGaJVfEo8IRbKdnmxLMjr5S3ySblYS2kF7ZPactfFru+4vu9yFWd+k36GH5zPwjgccC/xqDUUwN4S6yZ+N1DJ9zH7rUF13oX1
#s2lvNcymRcKzaStn5b3XfWyOvBuZ5uJWo7WYhu2kYStp2EbUXzS0nYY286KtfLAaJvH6IF634nUPXofQMz6K1+PoG1+DG+ABcQAe
#ETfAi+Je8Mr78boX0vIXMKC9xvRrtFNwp/YWPIL3n+PldbWIza4B8UO8Xkf8ve4WsQev6+kl4Lr1a+PxzrZ4G6zrs1JWbmKAtqJb
#P+oQN6WNMYp1rKLY+kQ83mPl6MS1btpfo2PtXNSVTN2cuszMd6fHTMqO8ZiV2N1PJ27b8b5kITexfgwLaq8qpn3OYoi6Jk63KrlE
#LtCtr5BK7GyHwUKStx1GtL83VZg0s3asO51KFLJZM5XfQkedUPoQ/wIKE3ZZ4xiPGbndeOvKTaUShA/wTtIbClZyzMxiwmXGpNm7
#BwXYG1bYWbr2GlaeY06B+TTFNlm5PBHz5iSWPryY1U+mE0Yyh9RUfmUHrBs2U2Nbjb1shI4qI2AstX5VnO5Z81obo5p2qJp2AG/Z
#FCtksHYd0GPxnk9GdgojVGS1tJWwjg7NIjErSWBOYSOoxgWdVZydqkMgtqqKvgrGzXx8JNa3hhhg3UB6rJA01zN1mPZh6+9BExdo
#DwV6g73bHJ4wsplo11A/8m9mtv7cxk2xbRCn5oXhqRwqFO1OJ5Nqu6pc9DIT+4aFSWgUbgTYahqIqTfiirJuRq9aP4ak6o6FJOQY
#4jMB+7LpSaXdmNKUN4PCSK4yQtWEiXR+q0nbdsBIim9dYypPr9oeg7M4+Pv4iGaIq6OaYbPdiYZobyDMST1ihHf9pxTaGz5vjtk2
#KMfjWTPDhypDFx+Q1pfOTtJmgIozRmcGb+UTE7kuTn5sdkvhIzk01xh1IlWP9bvj8Q1GYjcaq88yk5hiqzs7Qak7m84HyIxkk7NT
#7A1P5hI1RjvfJ2m7i2F1FPxspmF748zTMgxYKfY7qsJzlDJh5Iey5i5r3+y0rox1uTk1i34Z6gSxrDXZm6IWGjAyhGCrYgtM4ggG
#dHfKkDySLqfY+3LpVDlG27spJ8Bs2/l48iE0OhK6e1N5Kz/Vb589YI8DOoKEDMJZK6KlTgsb0+ndA4TQjnWcq4dPjmR0QJ0uw7m3
#2hs/VdN4izWHVPZv0E/eMs3b+ChJPDwH0WOpqJFhnKrclUyy7paZ2zDVY9KOIma2xKnGDUcHzX15PkTDGaxbcXhbGO3nsUjVMweM
#xAQOARyz+ap4rjKiPNVUxoTtE2bWPI2fQF+Qte1IJ2GCqpEJPKigmw9OQ9fRHo+zcJSFLg1oOFnojNl50NFqXXkUO1rApB5ztDA+
#TiYp05zpoUzpyuXMydHkVIz2vy+TqScMZdMZM5ufImtUZphR+XJSjDeBYZvtTWd3z1TFzG60xsbM1OzC+7AK9gibndif2sWegfx7
#8rRcakgXssxXTt5q7hpGP5Sf2or9IVehKk0cvUlzEuczql9FkjKpofYQTBr7GMvNLhHNM1ZI5Gcb195maS4dJzNGaqpCO9WjmJ63
#Rq0kDqlyqjqUDMcwdlOF9qbUXY02mha4bxELDjCF8yEaWO/J9B7ql1kLHeafqCzKRuzJbbT0m2c7TgdvVS4LcJjyjYcGFoca4MAl
#ZMCiDXHTu/LR3n15M8U7VkY3pcfHKbF6wETtRqMU5EA/wmgsrapA05WNVazAgJca3bntVoq9siLGbT8Jw7SVUAXjBhMLHjT3KhIv
#rQDxCaCN/1h9tdMbWGD7v24jmRxFh4nGY2gxOjVkmrvLZlFTEa5y7DlqEy11jCRU/1b8cgsBq6Hch70JZR/2B2U5e1phy5ci3TGc
#mKG7e5jvPE0Db+mqZjo0IPMzogyqtEGOwcIkbMBJxzRSsK5tfTy+sYBVAjq/bRh7GFyWNc1URWOW9bXj7PZVq3AhDl72nQ5lQG0B
#hpOMQ8EmrBiSTlvH6Bxb8hpRp8+p5K5EJRcOR3u9o7xief3DHqd/PIWuD803ZuUd1XrU0UMzk9Djlrb6qlAbHTrvNTeXZhCn0zCp
#+9HAc/oB1aW8tuUYHaDn5B4081Gae3DJqiZAJwGteS2tqrcZ2VJX7sJuhY2SPc0iGt13Ph4ftSP9NFrwzp1ToU5daXrIpJPkz5Vg
#e8mNw3ocl9VmtnIdTl2o1O9oT0KmqcafQcXZn/pIFuJ5vjniaK1OEwiUlpKVS3saoA4ax0FPd7XoAnX0NLddydVkK5qji7dDr3wy
#IGEVsWhCQb6ZWTvvtqGcY+Yey8CWz+WtRO50E6cqKhe1GzSHzTGSsvbxaFALLuCFsI0rTzhr1Wa7xdl0drbVCzi1fp5BY82r1nHM
#NoM0R2PF1RhhP4RtTaa1EqYSeJqkGQ7WWQWU0tWES4dn0vmzMJKnqQVXPFQ89XWeDbmAcowcCy89TmtoWqFES/NTrrx4zFWOlqEs
#HWVi7SGR1Mv6ksa44u3hQ8VxFHTG4/kJq5QrVt5NDnvdO7Yz1UYJJMebAzV4ytPQ285N0a7RXD6rThXLzfEYNqMv2+enMbUnnSjQ
#esGhDezJvHOf3IPLt5m+JLpRbePJdXBwSqjEnbMvbdI7lMOWzoEzkHPlZ0C7Yxr7nCg9S2CF06UU7Jy0nrM7nDrgHfgUga48Prnj
#ip/7LvPEiVLOQtF0KmHkAVs9lY+lSThs5sPG0EeQUXHxj0vZhJoSK2fJCmrZPtCDTo8qs5nPtwFnWbM5a/tGXCNkc/lylB4o8FmB
#UOS1seESRpbs5jMcuQntFR/XdGs6nXfilc2rHIR6VzLXc3r5TQpWmk+lB/t0emeRRTvLOqssxpUTd2Ksk42rHAUb689tSJPBHHtn
#bYNVxNVRCQrnpzqFxtLU9Gq1gd6SS7ePc4UBXAnSw0zlhAi8D4f9/kU9TucTg+m9uGjap5QqPXGqmpSjw8YU0Ib6qrvwwyez2CjV
#zLBSOcLxQSs7BelMvD+Fvdmg5a2amdTTo71udZ4zqpzTEJ2IBgArJgCVhQxcCK34rx06YDVEoc2+2pFOlFUYa6OXoA1XwSCYsA8K
#kIOrAZrKsU24+EvR14B17aXcsHQQemEIr0GIQT/+i2ApEeiGYZRbzgvFr3VDGrOnkJRAhXLIlIcJjNEfgEzIwh6GRE1XpM0UFIG9
#iI/iPQMGS0tiFSLQDOOI51F2GsY4ZxKxcVZ5OccsLoHyJTHnFJeW4zQqHycb5CANFW0SeUjaBKdFAc5MME98RjkwchnHI8hPsrNc
#DuWt1iFSodkuxLIVdZxdIzBmmz0C+2EbXGdLNVjWGMaWVeQjnhHkWT7Lqhbz7kdrXgctVJ947LSlEzdZOoXl5G1JdC8gT4RtpHRX
#XNXlTDEvyl8whJJMMDidSjGQn6RAb4TzjSJdWcJk6+WwjlTT8QoLGbYOE7Z0x4Yov6my3DjXD+pybHeDfm7qS/EdW0jDMhck7LZT
#tCzWJcktS78CpBQnX5xbnvKOMx+8O4+yE2z/XVyHJNud+hz4SqXV7eaUJEkMjDGVtMZYg2H3rRz3etIxYdcafBm7xhC4BmkW2x/r
#EZrAGPGX6uAlrTL2fR9yEG+8opdCgCycRQq1EjSUS6G6QagyTuMP3KxNQ/VoAG9BWVJbAaKBNCCZeaVVnYllql5HpVn2aEYbBbIo
#u8CpKOPcVtbVQkdA0gv2CGit1PaGgRJOdqV0stCE3adVH9sPAyzpOrZ2jCkxHgErGO+2Y3RfzpRBjlfXKcK1znDtVU2iIBbNHl8X
#2iVexy1osLbj3EqT2MsyVLNFGZZFPS+FsuJchzgou8CSCOxgO2RPM/K5z2yP8JglH5G0R2U7OlPyOMRdYB2VDyIrJLEeNKpILkky
#WCJpYFaMwhaA4Qg64RTnVuM9XzVWyyM9x2k0hiLsV52RS9Y37NFoqTG8JMHlJllLxxuMsY+wSvnAzfVqppbKcEqC7aK8aStcg5IJ
#g6YrsN26uGesgMsx9xSIuo3YdjGcQFCC4XikSk80lwajzJXlUZaw+0yUe0iWrWXwOFe2T9q+OEv1aT5dzyx5c18Jq6M8We41cH7Z
#d1Op12JOk8fnHD6h5XRl5Hg0Z9jOVA84dyZlDml1+q233f/97b0HOxbtf+K1q/8OXBEhdPRowo1IKETRIAE3xRe5PfPCW0RY50jQ
#gzBcfFDdjvm9cl74WhEuhAvuiBRnzdcjmggGw9NCnxeediPLE8E2IQVHzobQtM/tJ6KTejtHb3eihzl62InexdG7nOjTHH3a0yYE
#yqLIdIjhPB/AvHDxEOqBvMXvynBBLmgUqNp0M3KWbphyNkgXZil4mYj8EaAKNIFH1cMVgSa0BzTWIeFqWef3YrWaoEmgeaQbZH19
#vT4vVLxbhIrPkEGaoDGihSfrw9OrymQIT69F/qAPNNRubXDRWS6vCNE+XqHrkO73gZTh6V78TyXJeq8nfFa4EPT7Q8WbMV3XI1Ki
#4CZBNtV1zS/8rE3wLB1rFTwbwjt0v7ApWJERNMuXA0DQibmxwOLN0qNhZg1L55pRIwmU7MNWI2WlrGsUwjZPkE15dX2jKJvMo9i4
#RoaTS9cVWSfldS+bKdzo87rCjbo/XLyfyG7OYhEs3h/0unSdzVs8iP+5FQ/qqgGKB712Cgq1pK6j4uHip9HSwWDwPG99eDE3rKpr
#kMQQ4vQ5XddRfl0FCxXuw87ZRE2KFpmeCmqeJsBLaABBvPRzvD7Mp1dkqhaKdsPikaOO+sb0zZKaP6D6VaNiXdgo7c4lqjvX2cLv
#L3GF2LhYSsme2Bg61zMY9M8Lm0Kh1Dlo57NQ8YSX+nbj2YB9FElkvS9T6nKy+CkRpH5OSBMzLPeRgsXHMKp5sYuACE0f8NPIxLu6
#3e73CqdfkqA2ytfm92pcTa4p1rmOkjopqXO+16uHuYsfF0GlHjYH/kd5spGHCRYYpJKJpYm7CLL626QkxRvZAooWWuYFV5CC8haf
#XuTF9qpHgb9mBuceRD24zbHL3IF+J6jRoEM8yKS72KfgXYmZvp/71kEaG8FgICJYI5QVLv5Od3DdKaDeVgbR0HLOeL9uWy1YVpRS
#QtOHIl6/jiOx+Hyo+KKj2U8Qx//KCOUcbTiGkZEYKG/xRRqzwUZEWNSD2Bio6qp3eT16eHGoeFJlU1I4w0mvXyIMdZZldupfvCR+
#Q+iY/0L9yP6mt7674sUt+oOPTa1pefELO6VHlx4pPUHpqdc8YR2vEbx2eG03pXvscUh+y+lY0uNHnknpqfN5HL+IhPlBT1VvRhLJ
#PMvloR5o90+v3bBeu+u5PGhfAr/2eRyLYqYIXosp40m/APu3L+DmT15oBpHozuoJqSf3w1MI6g7gx34nyftKGnLFaQ8jwboI2uQA
#Tgjh4h0OfhfimEMqFqnTECBH4Y9I1YxBGtXCYX+iIuvhCvxpxMn7hQv+iD3sw43aMtDxkngF8ap3LUMldWHvlnk2/cgiJs/YnjUy
#g+lU6dV2bCKb3psTul1huETAguhgb4xexXVlMsvtl/IX72lvi7ahhOC7Sn9+sz8gob9u+ShLhFiCAnzlv25AvQDvVjNpGrTzFEXa
#+dgI2pBDgLtdoS4ysZs1OF/AeeW/fcz4q8L5VZ+0wAoBy96Gt/rbD/ox54a34Z7rw5vz5/ga4veVs1LJmfUJBYSVxV309yMXv+4g
#+7i40wnV7xDWCd71hynYRt/mNgqorCIvE3km83dXJDGg/qrm/CWFLe58U0HZ9NIfh0iyx36jwimlrzXgXQIaZr57hvkCmuZ6eY3T
#CQRnvIKGBgH+ihc6Tvhs82ePgBgYIuXpt5JjBby2l7/kom7QBOr314cw7VBFGoXG6ihsHe4ZnnrpzLU/e2h3z0ff8/2NP89fvoVk
#tOYnM627RlsHN7WmR69ptftfa8rMUw+t2Ic5MzYKwxu7OlZdALacWNCWg7pumnxhYq058bsznr3lPv/rhXK5YWfP3DmCs++rCnEc
#Rj3J5IBhpWAyR+++zdLmz28tQRkzq1QL/yeD4Iae7+yyXEGn/to2B50C7R18BaY8WbF/8ZOyE+E2GMbH6m04irYi1g+b8UE1jvdB
#6FO7LsMTrtfeVHJElcxL7Bg5mhnbIvPvLwVKpYfcPvsxqx8fwehlE4XFnIseIg1+DZiseIxV4YuuCP9iZhjpWfvVzWxJvxXE01b6
#14kPrPTDqE7wI51eg07aj7hTWCP7BQ+GOd60wjrO45TRw4+dCS47U6XbXHnbcG4s591mvw4p52mveA/cxmUFkb+/9BIhxa8oyhrO
#LiOKj6lJ/h06TsyYdxNyjHMuqmUG60eajgO9g1YupYfL2GzTLbsMR8fUf6osZcchfjgfQx56nfVOdmyjJ4wZeWZapL3CFmvYdl38
#6s5EyaP2i5jT51H5/t+EjNqTYPEFf2xFauGPEeY4/0ER+JTA/54y3un8l9Wds85/WNlRO//lDxL2+yORc+j0NzrPtdQHzllOZPsg
#IEppV4c+EtXgT1mYvXeodzDW3x9pjXQPd3BmxTJW/viI+OzPwHIROoxuyjncO5/mIyidnJG95miET6e7MJLJWnuMfMWh4HzE+/JI
#0tpDZ1byn++XM1I+JJrOgtzFn82ZYxH+27CZi0acryGRlsEy7aJHp7jopFFIIVs2qrRO2J/NoMpX8dF3+8uWsRWhozhnVA6fuyJG
#SeN0ylxBX6IojdXB53SKORVXqmBkGT6y7E0hc3KKzDCVLvARsvgk0hKlIgr0WS8Jb64o10ha+HTA2l0duQ4VvNrWmmrI5HL78eA9
#52r/de94sk+0dVvv1uH+zYP/g33s9z//qW31BR218f+HCLXzn2qhFmqhFmqhFmqhFmqhFmqhFmqhFmqhFmqhFmqhFmqhFmqhFmqh
#FmqhFmqhFmqhFmqhFmqhFmqhFmqhFv53hf8AcjmhJgC4AQA=
#__NEXUS_PAYLOAD_END__