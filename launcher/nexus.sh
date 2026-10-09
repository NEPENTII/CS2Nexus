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
readonly PANEL_VERSION="1.1.1"
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
              servers_file:($dir+"/data/servers-public.json"), maps_dir:($dir+"/maps"), title:"CS2Nexus", session_hours:720, code_ttl:300}' >"$PANEL_SETTINGS"
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

panel_maps_import() {   # zip file or folder with map pictures
    local src n=0 dst="$PANEL_DIR/maps"
    ask "Path of a .zip file or a folder with map pictures (empty = cancel)"; src=$(trim "$ANSWER")
    [[ -n $src ]] || return 0
    install -d -m 755 -o "$CS2_USER" -g "$CS2_GROUP" -- "$dst"
    if [[ -d $src ]]; then
        local f b
        while IFS= read -r -d '' f; do
            b=${f##*/}; [[ $b =~ ^[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp|JPG|JPEG|PNG|WEBP)$ ]] || continue
            [[ -L $f ]] && continue
            install -m 644 -o "$CS2_USER" -g "$CS2_GROUP" -- "$f" "$dst/$b" && n=$((n+1))
        done < <(find "$src" -maxdepth 2 -type f -print0 2>/dev/null)
    elif [[ -f $src ]]; then
        n=$(python3 - "$src" "$dst" <<'PY'
import sys, zipfile, os, re
z, d = sys.argv[1], sys.argv[2]; n = 0; tot = 0
rx = re.compile(r"^[A-Za-z0-9_\-]+\.(jpg|jpeg|png|webp)$", re.I)
try:
    with zipfile.ZipFile(z) as zf:
        for i in zf.infolist():
            b = os.path.basename(i.filename)
            if i.is_dir() or not rx.match(b) or i.file_size > 5_000_000: continue
            tot += i.file_size
            if tot > 400_000_000: break
            with zf.open(i) as s, open(os.path.join(d, b), "wb") as o: o.write(s.read())
            n += 1
except Exception as e:
    sys.stderr.write(str(e) + "\n")
print(n)
PY
)
        n=${n:-0}
        chown -R "$CS2_USER:$CS2_GROUP" "$dst" 2>/dev/null; find "$dst" -type f -exec chmod 644 {} + 2>/dev/null
    else
        err "Not found: $src"; return 1
    fi
    ok "$n map picture(s) imported into $dst. They show up on the site at once."
}

panel_maps_help() {
    panel_maps_import_menu
}

panel_maps_import_menu() {
    local n; n=$(find "$PANEL_DIR/maps" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | wc -l)
    echo
    echo "  Map pictures folder : $PANEL_DIR/maps   ($n picture(s) now)"
    echo "  The site shows the picture of the map each server is playing right now, and it follows map changes."
    echo "  Name each file like the map: de_dust2.jpg, de_mirage.png, ze_maze.jpg ... (jpg, png or webp)."
    echo "  Workshop maps use the last part of the name. Maps without a picture show a coloured card."
    echo
    echo "   1) Import pictures from a .zip file or a folder"
    echo "   2) Back"
    ask "Choose"
    [[ $ANSWER == 1 ]] && panel_maps_import
    return 0
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
#H4sIAAAAAAAAA+y9B3gT19IwbHowPXRCWWxAErblXnAFgwGDbYpNNcZeSStLWM1ayd1003sLvRN6QseEDqH3EsD0Fggt1NDLd8pW
#STbkvbnf87/P//neoN3Tz5w5c2bmzMzKPZ3+639e4C/Qywv9etn/omdvf58AH+8Afy9fH5AeGOjl7UT4//eH5uRkpS2kmSCczEaj
#paRyX8v/X/on9yRNpv8yDqD19/f/9vX39vIL9P1/6/9/4w+vP4CBRav8b6HBP19/78AAn/+3/v83/kTrryYztEqjQW4ypP6bfcAF
#DvDzK2b9wVoH2K6/n7dPoBPh9W8Oori//5+v/+iucR2qODdwBo9Voju26w5+98D/visP/u1+VVfByam6U3S7NglZcx/Pq5AX/3vd
#Q4Oiz1WRHm5ZbsygSYtiotrXH7OitfbY9fhJYce+bzPDfbJH7tOdlzfULvphWti0ptP7HJUvOz39S1i1MeN23G0ee73jX29eymJf
#GjrNzjy58/783BGlXtzRe2VN93lYPcVvX/Lyc+/aHtq18VD791WTqprm1nEdd7Fo566Tf/1tPZ3p+mFWmPrUpznTXr3y+uH7avXP
#tKmzo/Srv94/fFxtbdUl67+vmWM0BRn3TGvaOPhaRoC3ISbar71PUmHVCneCypneyPWnF8k/eA691KXJ0P3r67jG+VS8Nkn1W3Cz
#8FbOFVIGlXv27O3pKiO6Pa5bYdj+9TXbp7T1mbKrQ+Q+7aUaIS0H9zIEZl7zer2wom/6q5umx5V9J3e/tLX5kdEHh+w557auzOuu
#g4+Xz3xaKqbtFd+9b5xG3kmZ6dLMa++8+dPqdalpqHy29exag7Pplj9Y39fW0R8aBzWcRc75Y/uR9srvptyutqf91RTXnMwFGTH5
#M9b3uVG34YTS60ZfHHni5gmLobH3wWm/RaSU2bLGKScw8xfZ8ePGahNiVc9OL0q/9Uo6+UT823e9X/m6t2o09lJZ16Ate7dUODe1
#5oIMRbX4NdnzNjtPOnLi2siY+Z571886nDPw7aVTLzffn3A9b8zs1YYhypDjzS7PmPt2aUBuPbe//XtmpYVWKszO+rK3IEKfN63o
#jsctSaf32U0Htc806Uaqzt28lT9T1eNh2tKWrdXDRoZ3r5DU2HS23fVx5c+kvbtxx3lShqXcrDXt11Wov3TcjMVO5e/dq5y6Oygi
#SHswydNgzSk8UmvW7Vd/ztx8e+PcMK/eDbTdSl0akemTmHh0yP4z1XUtV7Y4/HO54y2daOuG/R75IaagBsNVP6ouXa2XXs4rq8LD
#lI/lGk4YUUN16abHgL2jZINHzmncuahp3RvT0/2qHPGa+seBx4uWr3zUonZr47OHe0PDS900zXV60d9nVlVf64lppVXqLefegKRR
#dX3m/XHi/o3uTlvoxger1mr2rmurhmtb+5y4+u7TjbzPVco9O3pixMBKVQ9V9C79RBr25vf7/eOdwLqf0p1LoYdLRy5Rz9Tletdv
#8vdD+ots8PZMbcDCUkENJe0npQ/LLDq/ILnl4DYj+9409XMa1ti/e5PdA0r/XnbknQY7pv1d1/lmt0mlR+25VVi22aNmLz1rtTae
#flm04E73P69dW+V8o2CQJfhnp56TApPDy5af0fanmKMXSy980/ppwfWaHYJ1vu5SpwOdU1M/n+ke+v210FLZLxbGXcv5bmW3muWc
#a+W9+7iv3MszWzO7SPdeqljzzIr0cz9GLIgYVHXyrUfrDE8atEvaVnpC/XEHOz2+Ubn8sL2riZVlgoyT3XrJz6/s1eT3tpHPz3Qo
#iJ2gvb64+cm54QVRMTXuLv19q75/zYGLU/ZGSi9trf7+1RPJjuWHR5mG+1KFOX+3DPqlrf+amY8HraHpNwNWnntwf4hr68jk1XFJ
#LV41lXZfOnPpxX6f3rTs9KO7XKubV3rXzN7Nxx5JS9p6MOVJcvqkfZMjuuyLWL576frlcfNS3MrEj7CmmT7N3v/oxIDyS7z/+GHY
#mVGP8z5XcK4rH3P9xt8HevVYtaev+Y+T5bZNbvmxrMwn/+8mXt/t1l8bs6B91UPbNqbefDjp8aOi8kEh/WZGFoT/dvXd2GePXjcK
#qBjx/GLy/aaBP3omDfU4faNQf0h+fLZvtXeVCrfcn6NKNp5vWq1f9V/fbbzvsefp9tcLB3StrvvjxqAvUb1/PDlpjrzRlUo//ehx
#esbE1/4hbx4fOl5ET346rNrNMaAra/ukxoXV78rnBitnmF4OW3Wl595P13dun+mb1mJAQc8Os6Y0N3186334xHrlIOcPVXOqvbx/
#ssb1qR5lR17Y81d+Be/sy5XvZn/JL/w+2OfLtav5hvUVm/4wt+G9vyIn9s8/vSwxs3BbnybPGtSkf5gTYPgt516fVusGNekhHeFx
#Ka3mxxZ+qyvMcPMs1A5b1avDveN91nxuFB0dPTNooHuLcT+MvXtXFRTSvt6SmaWzIqgm8yVz6/lkqo/PHlu6XKW+f/+6PfPpjlrv
#P3147dL8wKoNU1ukTyu9Y0z/Xzpse1F7ps/56j1bpVV7HDcveHTckyu3bxdUMqkvNXsdk/rsWfrlMWv83DIenq298/2rgpEjX10o
#p0rsMjuo8bEZ8i0fYqQjQTPbt4c0CDAMlSftn+TbK+7IL7nvX8naj683YpbvT1d2XNaWWt5j8NzjCyLy7zXM+3hEMiW57Q+Xo2se
#VL7b0Lyqb6m7PQcndKzRwE93PGaP1+qrWzpUbdL+0Gv9pXd7/YNc44qOrqBWX9jXoteqZ8nbzOXCtme2TVnZZZ3qeeTyTYNq1qy5
#PutM6Wlu8d/v3PdrpaPygi6dp+87ee3D6aVaGlTeXPp0+8yjr2Z9V3FtU+3H6YM+k3N2pffebN6W9DhXlnDs0fg+v8d+aNjXOOrg
#hWMvNh1ZdmpV/08j/mxwoUypUmdb3lyTtNM5KSRz2pONU8os71MqL/8ceeDh5inDF6jfJs9cGb++X/01vXclXPgh593AKX9uHvum
#ZtO6d58vCosr2LDM692Po6eED7tsfUQ+GPP7vtQn7kEHnCc179xzTb+NcVN+HLm42ZWtn+pIaj27ttxn54A6Ze8P2rnx/OyX6/98
#vVq/Ky+364tzXbyt793Jp6rRu08u6PApeHPZi+sunNlRetLYqeplDVuZezfs/PrTns+fqjfxnDiLnNDzwNkla3bXnVL0W+7NnNA6
#c3MqL3v+/O8Dp2+5Xh/j439g/A+BpwfL9i7rXHcR5bfWiTpaXnFryrKOP8p3FqVnKhRlr1jvT3hys/e91b+sTvnoObXoXZsWG+80
#DssZ3qLKo1sTl1TV3pZXmt1j8M1JXcn9nf8Ko+eG0eWrPLpYY9pg10YREREktVnVMzz3deUnlzcd/CUxoO1Yjblmw1oNh86i7/Wp
#9fnJlYFtNSZ/+ccA08t7sWUr9Ngrr7T6p+XLJfc8+40bEHCwh2z8vZ6DbzfvROR9ajFWsr1zHY92C/qHzX1fK76qdI3iVWFFXfLp
#3x4XDh9e9vzPNcZFfFm3MukXhaZTqdKlX6Qc2/Ik6/68zHaHJu2p9iHd66fY9ZcajVSWm7c9Y/+bTxVmnpif/+xmqaG7Pk9p5P65
#zNqF9csdnuntOvBTvuQjPebQxtPu54dsCwo0Xv5uwqdF+ReXrjxXbmOHcWm9fll8tFfyzc87c0+Xnt3VydikyZqx/SYujjrw0tAk
#PG/wwb8fVUx/0fBQm0U1xs5w71Ded/Wz0TUPdQvx6137L3XnFQNrxgT8OTSq83HniBMfxz+8+Mc+zzK1Gl6cuS38gW/dJb3X3x46
#NbLSgfYJvzjVlMS2eedcO+qXqSdubPk7MGhgzLapSb2GBfz65MqWgEcpKz7+0auef477+Qlzrp/I90rotL99bPULG38s8v70YeBI
#/9W9hrh6TnN/2ewv7/DVrwr+nLlY13xhx0T/Xgu7PmlMpF3QXRr05yhTqOfBcQ/ivVU3nUzT7tz3vnN6U3alM4/Wr1//nXvS95lP
#rw5p0G1tRT/rwZiN+3ZPnxdqvtVr/tOcN7/dG3+7/9ZXD85VUq/p221ZaT/9hciOz+rcubRgkHNGRIdsTZPWH0rRz1snJ3zufrh9
#vOsq3yHmtx+Ub66XWbwxotGWaZ6Jzm/+alk3+Hj2nDc+qeoWj7qRBwPLzYqsXeYYEfy+zvnhD3sO1vqq5/jnr/jet+7Av9sEDNz9
#NGdsf8mBmX7WBudHrKo12Jz9YGHUuLVzAivWntjq4fAd6VcG3WiRM+9q0YBjHj3HV2z306nrZUbe+uMP6kXwrHAq4tPMeW/Dy3bY
#OUnWbvo9qeVArS63bz/rU9D694RZXU84e2kOT1y8r4vl6eVZlXaXX6dynpzduY11QJvazs8+f/jS1jQqyyf37a+bZ8cWmqJc9l0k
#x84a/NvszQM6Hw2bUaaHtPXWdY0Xp7v6Lcm7sbxu0OXFHd78XDjoy64jabVuRL3pV0X6s1Ot6zF/BPxWz99cNjDf77snRe0nNpDl
#zDtZbgMVv8u/4Pacm5MjJrYZO+OnapsPp/bbkNWtyG1zt7srPU74vP6rqKBthWr7znTdv+vXvxv0/rvBw8r0i7vphysuW9P488vC
#FQvjR78r9Wn3yCn1FhL1fSmfOQM6HFg9TRrfe02W96vH1ypcOLsmqtI02bv1XXtfmFz2bvaNh2/q5j+a8di59R/1lsfOH7637cg5
#O64Xan3HNQlsf4ZuFBVLtDzfcsaVzk2OAjK/sLl08C8XM4+e1AwYdvnwmIqFW7cGXs78s2zzbjGlfFSHiQHvq++OqSc5TvRdkvSh
#6uE5PwaujSvouX9lfIvR/Y1Fq6YXNTR2AAfO6Raj1E7xp8et73pv1/bXQ389NW5OUMW5X2aG5M5Y4TpszOxuiX2XdY0ptSJ6Tj0/
#ZdDlCRnNap3struNq2l+2zfm9wnPWzbaq1btPSNd7DRro6rG+HeLYj1/f3UmuEyFajWOh56k6xyf4/bwtPSH3lWf7vogn9a6RrmF
#399TVEhOGH28/sfPs67nVvtUvnLp+60s8nXGp42nXuxYZ+lry7rAMdLWpnVvp9S91e7M/BOzt1Z/oWh1anTluru3/l7bZ5iql9Pl
#5z9WrOyXPX5H+JwA3eCNrX2vZO1qOvDIT+MfRZ0gHg5YObx+s+2lh19Y03zA58dvP2X+dkCWLLkxv9b7Z203vd9SJejUiYXXQjJn
#7mh/feOANi/qXpqeVOr4k7eurhf21n9w5ZfdpocnFuU2bJrjEdSsrNl1demlqf0nO9eOqLlz14HotvOPXAyzvO1oStliSFt2NNnZ
#x0WyoeWekccbVleeO1glcsukjd3nNHrdtYm81/0zS0ZGpsyvV+7F/ZFzD69yqlVBfvBhD7dbj09X9N4ssVp7ru0rH9jtXs5iUH/I
#pw/p784u2zo/Ivf1uKLKLqlNk3dVO72erlsY/IOLa/pfV4u2zt/97M2NoJy7391t9znWtLnl23fLa3jWHlJ11/tX3w1bDajL1qUT
#Zpw8mRm2f92jgg5/nj0w9q32N6/hZXsUXD28q3FElqlJzYPja+/qV2OA/PnLS881lw//OrxO6p0/zyyJjM5dlj477vnrZs0PvG+2
#bWPPhNY/dR+yRTV3maLzDd/rbif8+pWKSemsHOkdMXHfte1n3YiJ9Vpd1tWvR1968XnT6TWRFQtLXxpdeGii958jP0859OH+q7qv
#yzSkbjmnlJ7TovPrxZvTelbyGL707C6lZH7YT179Sj2OmWhIarbc3P33siDBHSQcByfc2ofdYka32fxI+rRKeo/C0kGDK945ePP9
#34+mHPoSpCsLDvEhrhH9SjV0+mPP6y/9c641bpr7uML1v6JB50GjkrfqvBPdvsSuCIzcG1mwZ3LdI5K9T7MeToqYGlI5J/vTkVNT
#xgUNCqzRZcqmzEnnRjZ687SVqfemj8dWL1VP7PHhfeegMuHlGznvul+1y7AdL6b8VtX7y64fR408tfTI2KhyxN4FSWFuR+9tyqvZ
#6Mgqev13H2IT1042XC1s+rjC0gv7PXvuKDt7s2Z0VIO1o6cdvdtyVreNgzfkzp7Xa/7CJz/VG1tzeVTNFdbnmbXqDlzcf9GrFbN7
#vXtDetyt8WvW86F3n38aWG/Fg8frb+aFj6kU8Ty7cZNNLQ2tth1cXHraKepK+k7XFZM65zpPmjat2dwqHQvGlK/c2KdW32UKw9+H
#j6V+fx2M7fRq6fDfkpYkZoxJXx6vWHk+7XTXjUXKAVPqBlY0Hlzccd6ueU6bTaF9w54e6Lvic9LpbCenan2gLqDq5zuH1k85dK7i
#+m2Vgzebu0e9MLu8n3XAu07Erecjm9zcl/THlxVJ3bqsezUuo/NPV3dnVnMdWW1q6PwNhy5b//xu7fpn55WPtzeotqxV5v36B5vk
#pKTPjfI8fe1trYS+5jLUp7BFtY7I9tyaM2NznyfH5/j+EDtnc/UB5aIX9Vqwa1TvrT2ftdCOLv9ocbfgkcsX3zs95NHZu1EvWg0+
#n3zYu0u9K9WNn61zlr7NC454m/62Y96H2Eqa8W0DNzX1/NistzpuftCEqJ6WXRVXNR7XKTmh/CFvU7mug2u0Hdn797pjzaMO9I1O
#P1u+l1O5rFd/1hhRubE0e8fu3RG/ZvTqkJyUOsxtcOSavuuvrnq8Xn7tV9fM1k5BrwvcBg89XXH9+YB108ICMj62Mz2uBGovery+
#/rnl0Y27+L9qm3a+7KGBoJOZ3kva38545XHkzqCGAQ137dq1rk7/uofhtpgUIzFeUCwZ3O117xtPl6ZOpE7MaESG5e7rW1h65gi3
#wRWvXtW97X22a9YY5zJj/Sf5Rt3aF0V69B3nNqVMUUTtAYNP7+zQRadYvij1y65RpOvA79X+vZan9g4Mzb0XvPxJ0aePXreXL0i/
#90uloe6TYpZ2XtDY7JqbfvVdpTpLdNvMnoN++tynyd1TE8tb0/ZPfxfY0nlqiwl1bw/qN0QWn7pj2rBx9X0XZT3/PnJ3yrY/Wl+o
#fXPJxDE7Wnxc2fXK0pa/r9r7+6yPx9pB8TJ1+YCu1m6tpF0XEnfb9SyXFbgk64fj76s02Pt7dMeO1WOapi4f+GnE4ovHj4xyndSj
#VNyC4OY5axvMqZ137vntrh/ePIlaWtO/0qCaG16uLl9udH9AvtxRK2+fDTldo/24lj3uPq2+uH35VxvluTGdE9a2kH8MGXhjxKUO
#EwnJhtwhLvsOpG6d1HXg0ejffruqrqCK2Fu/YpW1TXNOzNUFORfVTslXDdd87Lzs6PTs8cfrHp/vX/O+KqBCwyrXEh+W0zmvWrEz
#fX/O4fGPnavXfdP7fOXFMzPp14vcJk+Z4qKa2KpmU93rTJr2zdbff/1kqO7weJdDwybXqLH44oBnKb/82PX1pbPNx950H36heuAg
#F9cLbSrW6ubU9+HhP1LHnNq9YtzcbeYhL+c2qVBFdXLYyNPBn1vRi2/fnx7T3/Vl6rF7J7qWjqp1c1v9Tfvv+j9cen1bWiY4DIuU
#gBcYeuHBmdVbNaFnt9wY2OO3j01rjZ00ZlytG88DdefrFWXlne58uHJw+sd6mzpdWFPU9dTxW71UhT73qi2aWVrXr4lsdr24Obeq
#zgsZ9rIJ2VM1ceV4Axk2fPq1WmfObF2nvVNeWqBwbp3+LH75qMBRaRd2LDvdquDlXCChkicfzzrdIOHBr9Eb7y2+CPiGZttWLnTt
#6tcx76/HfRb/ENrS+fctSRVMn5WvukTcev1EoxkdN2/7mBmWppVSFu3bWd1SvlqTqPiCXzOqtb0xMAIcibecmo+pNSN/WMImTXpe
#j2VjevzSB4hd1c8+1hwtX95lXb9yvY8ZE7fevnvkzqSplev73Ly0cuPiRuYRVeurenSI7bCwsPTbt29vT6y5fPivb3+qFzag2cGJ
#jcpMeP1n0YeQ11Twtak9P38fFV4rhmzeLbTLX0emBh2f3yrpVbDHoquuS8MAH7qk7aE4MIv1n27EFxQs6JpXjtCsXNqjtXtVzdP5
#11YkL68TdLmpYr96UcVCmeb1l6W9a5Av4hv0UHU6R55aU9+33S8//tK1xonEgWUmBGiu/bR2xbOam26vbvO2Yo81TmWflHvdMKgs
#EHqmXlzw24FbG52HFA580iDoYXOCqJbxuKiCp+e5T9t+TtrZ8uqht5IuC8snxLsNUw83zDsQsvjt2/eKo5Yn7/Ymja+/8f4o54gz
#K/MTf/8uYtEqhbfqkWfir71f5azsvqzgj+lL4i5vfjp48YExgCFe8GWy69lKpY8NGRCzMOHs8i4T5+VWGzU78m6rFQmLGi5e/PPg
#JY0PvyoCxf9cdHFtYmC3n2NkPU58Hv7waMGBgwdn+xdospMKVfV35Oft6Vbhwdll+xcvO3Y84PmfZ9cPezh8QVdqZ6hPQU/35JY5
#85y1J+bsHvXjh/hSte62r9l9V7UXYyf02aEZ0mNZkz/aWVt0balyfhKSVRYyaI025hV1X/3rOvrxqU2zNnZb8tPb+uP7xi5IuPrK
#8NewRZFS5eOnu79EPgm2Rh2qJe/erl7m29NtTHdHTunXd7NBmXE88MScWy+Wde7qtqqH0+0Fx3689eBBQfdlx0ZNWGTOSQi7ta9g
#997J1Qac91ac12xUSkekvdvQvKvvKv8h/akLV9+taNzQJWfeqpYX19YeEzGhcblDz6fJ4+u4XVxT83LA6Bo1dlVtdHlgpc1LKpYj
#9gXq1Pedbh96lGD9uc+S8kFHp+9ZNO3jq3j3/r+Wrt9ucWbFlk/BQVJFU+pEYbe+ftpRx348oD+SeT277uoLUbcfrdpxdNOShacy
#fr/83cZ9X05F/HhmQ5+amnInpE5R1QPW9KpQrXFo9UZ3HjwYnV2pzqLsSo2DUo2Xt6RN3PayrvOC9fWm3Yrqtn1iE7f4W3vrJOys
#OLDmmAZhWSkRD8+v9ZytWnvuwbM/LibvPxTYKOPp1VJxl+u/e6mxPD3T+a3uwKiJEwGJ6lzXs3Vnjbras5Ztfh9WMH79ycjkn4Ek
#tChpzoXFUYVB9xZNvVZ/472Fnfxf/tFy5Tjlyxbj1316oz/dYHaCk8uo7AK1b/N1v+0tU+H04j7KomOGtHmZN06MKvd4+Jv4LQ82
#t3tk7Juyceiy2LND1cqKAfreEyctbDm0j2qCD3VM8eHnnZFfZBP8WiasGfVk+5vetQa+f/ygsabH24onfnZaeffEnGrHev48I6HL
#NEX3EZUbjAoqCNTWD7Vo+gWFdVLl7loUWudT5c5xh1wC2hQltmmUM6JqkyEjxrvnpkvXL+v26dfIrbkeS7LLESsGX3jRI61roanG
#WKUsoGBx7JvH16ssG7Xm/siJn/q/+anhzne1/HtFP61nNLbM71ZfKYlp9/rxwDqH5ofnd3p2eHSP1+e+j6sRFx3osinH//H1zcdu
#9/51r1vPX2oatnwfdsR55/3PM57VbP5px7M2LYq2X3BpOyLTK/1sLfc+u7pPeXau/Y/haanVB+7T3h69wCew353y1vW6lZsuTW0/
#fs7tPbeWaG6sn6q51aLDs93jbkfOD1wScnfo53snk7aTX265rri4cNHSi6dTr6xJb3trY0YdP2vVlIpLzkCmsX1CQq2j092qdfHd
#trJs89uDXmc39zNcriU7ciSIvuc3ZcqUmx3HqJ+325y3q8Uv+g+Sxvf/Ct4S16J5rc3kyL6+6lNR01e1ianhLqnTbWb00/nkTK+T
#75yntaLaH3k43e1Zn3etm7aIcu6zQXXg5qL96c8ON4k8uX7b8RZrI4d2abV95OegEaWGjSDoe+5T+ndQUwV7fHpvHNB8bo3lsSsX
#b7hi8SlanlrtSP8Fa4o2+Hoe7vjTd4MWU6svqJc02lxa9nKr/krFo2F/HiKHbuh8K13nnlNgTZ1z7XJhzZplUg/IdrSecXiya4Wf
#Ts71SJi+bsSHN08rbn7kun9/wbTw4OcxblbntwpF7XMbjRfXevf+0OtypfbdVmkKToXXzTF3K2MOPr+hfN9W2zMeDv4h0LCn6My2
#bR+unn0wqYq89WrjlYU3qpWZ9cSYH/lpXoj3pUKyzIUOw+/s+Zy/b+D+Og2XOdWq0/3nvHJA7pINH6M6qso3FhQWBlVuElwWnFND
#3PYYyE0nb/5FNwyuNWzspGunql3bl7M4qkEnj+7jP8fG1AfC++3TbR6d9X6y1mnZsWltrr2vMnzW9TqLulB7d2yrF5hRWeF3YRAR
#Wy898v69WxujKvTuVflGxcMzwkKCMx/MuBeZeDfdJaTVw6O1o+88Web09MvTQY/L5lUx3z85fpNX2kFLzPxXY9Mqfq40zqv9n0W7
#jzaKaNnx1drEeqe/5E6Tvq9x7/iGnXcVrVs7tZ/YqNq2+oFk99nDF5Td3ftWNW9N60E/1hpYasnzGfNnTeh1c9/SlpHPXba4le7x
#y4wffPJ1Q8ru/rNDQb/EZ8kLzz0wPojvZymXNfXKmVO1F52ukF3uzQL/grk/J2+vum2btmCk+tRfSd89uhz19krHZ09/u1q+AlEU
#+Gf3maULh7wsHfz30l07Xk1vnhawd3rvJT3109xljRvsSNn1sf/Uci/vj3nd07Va7doVAP/c3nRrSoWxLwOafdB9eXTn/j3Djp83
#Tuv/x+27R6dX8k+7WOPhrbxXnc4/eH7nUFe3pb92nR3l/Ppy2XNHDHd/OiHtV/jnsftx84L3Xt1U47vUoYOetHy6JKVqQHS9qTXv
#fCq7KLAwt4mq/GTr8nbymOt57yaNX1u11+LPe8c/utCoTtGVKg8XnGtSatvLm3V8b53vNyTWWm/8yCnf3zn23aLRsvbKwvlug1Xy
#pB3SvJWlLg+Srq9wJrjZy1dJo8p1iu5UscLIO5FLj34cm1I4/KUu9m2lhhM6t94Q5/Mlx0+aXC7o532d+wxa6RTd/menhhdv9ujz
#xViu47iIjutr3DTNrdfm4Kw1yz9/7BsZ4zNlEPFGGtRQMlw150jWl14LcsNc3Zve8gtpkli56iEZuWHeJNO931OvdxodExdT/7jf
#HzJQdqhq9pHXCwMXBE6u+fGVc0jj+aWqHhqdJT/XZcn1vOuq7qEhLo1Jv9tNQcnBR164tji3Pzap5mrn9Dnzam8tPfJO5aX1ZF9+
#V3Vco+kz7e7dt5sfX6luCrqsPlypT8Dool9bR1fsUt5394MG8LZrVvjLjiNOjF/fu55bq6a7ZB9iK+y5panYYuOR0V3ce4ZO6l7/
#L9mV1sPXTR+c2vvSkN9qPc+JHH0kLnlJTItxdTuqi8qMLei/bEb7HcfiTg/VBFaJm11Yw21gl5/DzTqyf6/Wz942W9o13jf67yvL
#LpaP7Rh0YMa0uY8jTveX+NVOdw8u9eNfu5NKvf94rezccbdOfDxbOuTx5Tgf59Cpc9eq9MF5Q72bp4+Oezojdvm56WUPDTh8uCjr
#ecWP534weYbXv3hpzaDHF3wtl78fVtjOULpoQnqMWZFX6fWeVdLyc2re+vuv8CcWr8/7au19N2A07Vdmzt81Z9YKVJ5sMOfh1uVr
#vx++d/uaOXFb+y8f9iRK1qrhD+SjP06olqyv8/2danvbn+1ZQ9r8QQPf0fce/F2+2mt1uHp1qV+8fksP8nu0cVaus292A9/6H3/Q
#7pmwefCOF4XbHhUdWb9eFl92uX7H3m5VW7w9v5CMNi9OJ8rp91W9tLvejJEdyMDC8afb1C1d9VCcVyUlvNwdNH+jIqJhryonr23f
#1GZk8ONu0g9G58H71zdwnRU4Obr9mrix84xVZx1tmnPv3A+vrK+Ch/vEyvfHNpsgk1KTK97tn9F7V3hzWfN9DQbtWivtVm3attiw
#MpXLJw3uNtLpp0rZl5o03nN91DPfxEfmFyc20S535zwyxaa2qzXnuyWX8ico1PnTTmrGdeq02OfTKSkZdeHcni9lnJy+fGkXc/Kt
#k5NTeShkl3GK2y4p/OHa1U7wnj46Kq7dz5EpQ//t+3+R/Qd4lA+g/+0uSrb/8PYO8Lez//D19vb+f/Yf/zf+pFIZERZO5DpLrDRF
#0BazVmmRhDgrjQbaQjQjwggaZquMSqueMljk6VbKnB1P6SilxWiW0jJ3otlXCrXR6UA5tkU9qTWA8s2kElf4KAEZOspCJIC03Hx3
#QkcaUsGjhDJI8AvNZOgp8GCw6nTgkTSxqRatnjLDl8Qkd4JOozLBo5c7kaFFT7A426+ZUlmVlAqk6kmLUhNLqbSkVCI1mSk1aMGD
#yfbQGy1aoyGYKS6TyOSoOEWHODt7ehIe//EfoaF0JtAjMyyKVrLQiwegN6RKaSIigpCAjs2USUcqKalnYovQcBdJkmeqO6GEBaW5
#hKSFJBj8Q+pNIQBOklD0prOgl3D0kopfXNBLutWIXl0kLvDV1bdViITIT1Qmybh1sYBhSNMA6DA2EHBRIGATEtOS4IjSQgitmpCC
#bLXRTEhxpUTSnVAkEUY10UUxACy2HCy+WUvRoJgM1abltEmntUgluRLCjSDBf5J8MLUBRq1BqpCFADBbrGYDQYcQ+exADMbMeDgW
#NI52pIWSgxTw5kl4A2IBWoDLzBYmU42grIXGGEwQOBX2HEtaNGDtsqQAHdCzWmcECAtbB415gDpw7gSaFE2EEgFeMnY0YLgW2KlE
#VMA3wMumiF4LkTSXAOgi6IEGI4WN5YtqBwX42VbXGK3mYurjvnALeEoqdkp8IdwkLMK0CsqEhRHeRARuP5uiLZRZRWZLZEQwToIv
#TI8q1DwHdZXVDJeLUoohqbfpFuSj2bFT04OpeQunZZXrKJqWiAqIQWuV69kx6JkpCjM1OFcjgoke9wq2fjC7TfREc5gkN5GqeEC/
#LVIfgO1eEpl4Wmo9wmsL7U4YEUIZAGGINlh0cohZCYB6tDeawQ6XQlIDy8jV+B2Wg0VAVaIlwjx+q6gsHM6B9lHjuQQALdhaBkD/
#AAEFU9AbDRYwCQmtMZot4B2uNnj18VBpU7UwAWCP1UIJktDImR7I7P9BF9kUaRYUELSnsVIslUmUy+UspZElyTGdk0rBRlYiAElJ
#MF9fb7DPlHKlhjS3NaqoNhYpmD4RHh4OiWugDIAeYGiIs9pqUEJySZAGrV4KAJyL1pwltXl5RNNMrUFlzJTDAhSLBSGExZwNygrz
#QG1AAwglJLaENBk0lU/k8x1YjCRtkerpVJkAOSnmHEGZAOUISm6hsixtAVgAHYKUnk5l8bD4MeWCarQlW0fJjSZSqbVAyHuHcIkW
#M2mgIVLAUwm96CBaePh7NXf3kklCCKUOgB1iktEKFgoORW4BY2Ge0KaysNnMUeugRy8we3fCxwfuaA5M+WDwwsGC1dIbMygpBcqI
#gJdLgC2QSlnoYIICWIxbDSYSwWp5o/97geORG3wfkOMLsvD/vWEe2P4kPvjgENwJiqQBhgBkAg9UF6ulm5VUYYTKdybpbIOS4Nfe
#pJWawFYFJ4FRlS1cH0iacwklAD1YDi2poyGuknrKw2gGCG+QQJqPVwfWJJoC4mU1qCi11kCp4LoY5XrKojFC0ifp2iU+AQDbKNdQ
#pAof+eAUZJbaIyHbRMGDDrCvOq0SzcRzAG2E5FnS2yOuN8zzhv2BBlBfYUSn+C5xchptBK06G41AhiHO8AugDJlJagENoQBOMlM0
#InoFz0YVaSFZFoPBZyYJ1zLL4QCkdljNk7tcAjLdVgAVsxw/ueMm8h1AWWk0ZScA5JZCDMdAxp1C8BnIDG0qCVgtuVKnNSmMpFlF
#tGjBooiWjqeUVjOFgIUqM0N0UE2eadYCush1JMBF+3kwjAOcM8f5gdUGGBalo+AbOHJAIyRIgrvTQsozSB2iRDAZJeBtoKRp2CVc
#Z5OR1iJEVGuzKFUIi8peYO25PuBaycFSUwaV1ELilmnEbErR8jCrwRansihlW6NeT4LiEghHCVoUgGakTgdLgurMxkIYICA7OroD
#ZYFcEcJH3C6edQYYrM6oJHXxAH5kKiUHuy/aQumlaTxXA8pgBAEnsgocwRk2uMCd2wi6wl7jca8ZfK+ivmi2L1ikJLJJW4wmKWoE
#8cnwcIsiATIjmgWOQcoMVgQCkGejGTYPMtAAheCv3KhWy7gnCCMhey3sjsoAbD+g0u6E2iDo1WSlNVI4ZqZDjgzCnppy66TRqgCh
#APwl3jXgfIMsGmifK0GqVFEZ4CFGCzgbA2WWSjK0tFahBRxmNjirDKkU2PAlNc5OiZsakHnTZPwj6hjgUAk9UmazEbJtFO6F4VkB
#NMBRgWgwBiDqygCSUuNIKLoATJBEx3aQ4GSlzkgD7kz0IpXIyQwJOGYNQmyEZNsK6D2SPsgMEoqqblACIgDPwzLBEBmlJq3KHWxp
#PTgAcsC7rxeCQ0oobSIB+dCRNB3mQma4EGjLhbl4eGiCm+UCxkAK68BzETQgyw/x8MgB6Tn5piyX8Ga5QDyRMtwCW0wSARh4kKSX
#yhCDgJgDucXYA2xIc1twXIAFYIrlN8sFjQLsTwnV6lMJ2qwMc/HEk/AEbRuUgLfo0T0abE6T0QDpBRqCfIAp1YUgdZYwFxdCRYFC
#oHswdkgQXcJTwEaSSPJDPeG8wlN4qcGsjwVQCYMsazjPJMKRwPEaY4yZ7PB4yapfPyhUSTxBCUZOgY8muGkE4ld/0iPHy6NVsgcS
#wSQSjq3qHNelVxw6iVRUsspKW3zA2NqBXyI6GqAISNRr4YYFqbHoASdqDUDkNBhBajR+wskGaxosGQd+cALAAbMJrBtI7MI84gzS
#oNQCcIH0NviJTbYqtDRKhQ8Sd0ALQTKoatGmwu564idcGrADWnDeSxLgL05SAtoAh9AW/uKkAYAxACmdwA9OSAXFdSClA/zFSSpj
#qsWYCdtqh59AspJOBsRCq4TNdUEPOFFrIXWQi42Gv4gD4KgHEMUtlmywiFK9kIuAe4tZXZCBd1dTAydRSCQsE4FWI9GQxGWxCQIR
#w8Ava3+pispT0nmkOU+lz0tNzVNn55FafR5tNavz0nLyFBqjKS+HyiMzTbJkT7TuDJJ4JkJUAKKCVgcImjTSaATk1AA1BSZpJsS+
#zESvJJsd4UZkymnAm1BSbxkj/0oICeKnOACA+m2NOqOZRgBgpq8B00e7lAMBf8AkpmhonRTs4nzCzx/w5EHNZSnuBJMo1YBO/bwY
#Zj2fAAwr4Q1LJIloNug0MrUkiANijpQmJhqAEmkgRAMNETI0YJcHE02bqt0xlQkmpGq4+xWkMi3VbATMnYdWD/eD1awDWw226ZgO
#qGX5Epk72up2dSUQmCk6wCSSZg+AjSq4AaTevv4qKtW9Wa4SwD4f/XonAVLu4UEGM4kpmLFi1VBmJBnqwYx08OQDyyuk6Ao8TQQa
#Dt4poSptBktLUQugaR0NyJxCDglcBCGBIJBgEsWRWpiNHvNdwkMVDFUVYrsMkDNFeKgnaB1QNF4VEtulXVRy997wXE707A92GkRD
#wCBbaVInAWsBEsGWgokaI+AgAX3BiaQZJZJmPW0GuM6kpqai1FSrIRWQciZRpceN6pn3HNxJDpsPdwNKgQ9MGtwZKA0+MGlpOSgl
#LYcdQiYuAn6ZFCnYXMlgkyXLULoW9Jgk2P16gANd1EAmRYiI1CZymMbtZvwa4hBLabj3ECoKlVPmLHciDWmnGEDKsCiYBcREcN4a
#ZEK1BGxcDpVUaTYqCZRhtGgoM96u/5IaECocrGDJbBl9nZFUxYA8qRJNnmf0HYslElZzr/UOMnjC8TvYTrgpN0KCZBIJS0TNciNg
#fiwaszETyp8JDmQXRh0LG2CEIwH7ChuBOUhygxpbDp7cJFAqrsnxVOwDIyTImT7gT0jxpVRaOPUEeTJ8gKe6zmJGpL9ZM6kkEcpN
#HhAESRIZx+Ua8IY22GgFwMrLYXnAkcphFYbnsxO52EnQUgEbzmikMZykxa8Eu7w0A3KZY3FQoOLGQsC/hF2A7ycUpFlwuIJD3pKA
#pQFuC8HFg50zyts0KptGijCak3I1iDKyJywqL9dRhlSLhgiHij9wxoRBHhNJXyxlhE24EFoV+0SataSHjlRQOkgLIfED2woIn3IW
#SAA8+ZDbxO3DY1SJeVejCQ0eiY1sXSUoC4oilhqhDqS6eACUiiG9DI1Fc4FabkBfcVPhKezhK4GJuBrkIhltJbPjCHZiAnpv0uM5
#gV9Axa0Wi5Fjq00KNgs8WLJNYKy4ADN3DUkDntJqAocGZbAyiVQWYGBVFKimJnU0BedPZoARyBEjD34xLw/4+HwRD2/Qs4w5U0bG
#MsOhdEYqkmUijVlhLl6EF+EdAP7vAkRdHQC9ARADeCaZjWlggEqr2Qz2AzrH2VSPTK3Koglz8eES4DGrJMHA0QksSoZgZNPDQ6F6
#hABzifUlAnT+BPifh7+LJzjTwJjAvxgc4Qi0BCEGq86FMBvhOYmAEx5KCl61QMx1ITRmSg0kBz3FzpzBHxVJa5DaQoKOULL4uhqL
#xUQHe4ItSpF6pVGvtxqAzCgHT54msxHAh0KcCAYqKgSwjFGqhbkkKwAmpYFhUgiMRhMUBeHhA++OzJTZZlioPjckBlXEaGE7Snbn
#GJl9Y0w1Wi02zeJE3C4DT8wysIwDgG4+QQFcYrGXZNtNtwLhloMjaEhrsB2zNtUAb+PwoFFbWLVq6g4oqtYAJtwxITYGMqOQVJYg
#ICsBl5sGmH1MTSnxfYJJIZCUecnXFewc/s7ApODZX5OeUfKa9PAg4RWLTU16OZod7BkspMECKBwtlcDFgSVF2RZjaqqOYjKRFg+M
#BKpR2liAoAiACfJEm5IpJFTEOhwPGq4eyvFoPOwo2BnK4EREI2FEe26YzdjJf2U0EkQk2LMUdusAihyGcCo+qJyVeIJ/PUmrRePJ
#FHAHxw0Q3uExxOpiwAnIX7GGEKlGKAqzygcHcCAdriOZCFGsP8AxlyR+PUkEHwpqc8nOVDbzprSYdfwbrdGqLcwrybSL+Qq8+ZDi
#pCkJ1WwCKMHeIOjgBRDdS2vhT2HAi3xrBSiGIJgh6sRIXaAcPOYdVg9BBeHM4Lu4MVcMfZgJVXbwzJFD2mjgtECeEv4eBBB7MwW3
#TztKTVp1UH/JgB48OLg3YO49dEKNKxghwyNFZkermCEhSdNHxmAopZOBSnJaCciOLtpgMfYEhwSjXvK3vXAgihsVbBnNPd/5Kzoy
#ThcnpAFipNXiy0oJPKIliBFCSk+JISsZJbnz2IVOfzAEjNEca2mXz7M4YEJGuF6I2/rKWAHTo8IqC9EwQTIeYBQNzj9KUixF4ilA
#iQTpHxACNRgszYwdjf5f4gkRTAQsIVhSfKnBqESKx1s3gksDrIwG7UuYCfg/MBWjOTuRaQLyYsxjPNiGFGLHoPoXvyVJsQGHBEAb
#1RculC37DbDNTNGaWErEsvLyD0/agDArpmawF476mOHasDcsaE19vLxwGrpt4Z6Ycx9AARFCnBjCWpUgbgsISkD08IL2A3aWCZyW
#ANJMnkzbd+/nBRhnntbywiYi8cUIIkDKFcohjAmM1A4UmJbh+aBCYLxYtrC5I7CFNl4HBGl8ayDeUMxdEiYhCUZoVeElME8wMdch
#IrzhznOG8OnxNkKyJ755ZdBHLsQZAY5IMKsi4TUwgGVVUeYYmAo5F0DTKJrWIgELzlFUqh1AVangwGSHwbTJjOQbB6Kn7EbBte9o
#cKJ+m7J0/6vdSITKB9xeJBDPaUCpkIjK3vrakTEgX9Boj7njpfz3yIZJC2QsqQKPgvAIJyxgFgRUOIWAR4qAyiRwVpkz4A2S2Wog
#ILML0uFNL8BTpQbICjJk44VaYo244EsCuvhmlF0wAUkjIDED7uIMIhScTpCkZJBmqYeHMU0G6QlMbiVIziTNBpTBvCtIlUwibLSj
#Ra/jDIrwGLhrOQmsKL4jgSUEtyTKYHiJwQxNCp+grBqqBVy3Nhxn5RN6mr+PsNlYeoqkrWaqK7yO4HVbAurhwYAilPDx9xLYCGFq
#wMGJr8HK5gp4gxRGRBvUWijMcNovmKfFJgVa0Kof+HFz488vyLmZKDOyczEo2TYZuiJWaECKAvuPSA6DmiUt+I8fBrRIYS8MDEYP
#iNgUMhFgB4YtsKChF3h3t+8TzJx0dHvJmASgRsL4+dkARqQH5Iy9vBljLySWojZknNSghMoMAz68tFDXxOIjt6+VSLZBlm/mjHjG
#mpCtDi3HzBklW6bhWgLjox4mgVUVfhBZpsEUeKCEFGPmheytsKGXO1LG2GQ2x5msyZi7I4MtpP/3Yuy2eFuxCCKlWa4qX0XA+wMN
#1LVrcBp4A2n6fD1MS8FPSCkNCUrYf/xHxEd17xnVnYjs3qUXeHQWHPgicie057OgSzaa0gWzJqBGFcQ7UgevoNKDEfWkjWZ4JWYC
#j2oyIxjjCXg2UxT/QmbQwcgIDHKbMmhiSltwdZ0WPkE7UnjeUiqmDjZSwbsD2YyYSDNNSbFlAGRXQZOQdCcmwXOXVT1q4YIDLg/2
#B6m1VCtzZAnC2xLAy3JlWjDL9eBemXv2DPgMjWVFcngKSAzF1jAs6aKtej1pzgbkSePNpmVoBJK+Qm7RWnQUFvM13uGhJqRuAPVc
#wlsYFLQpJNTTBCgbbhaqa4SqGovRqKNdsBJHmE5TpFmpgUTRYLJaUIvprB6MySPQeacx6kCzAiUglMFhPlIAOtYTskXkKANrCkPT
#FKpwz1BP+IOVHw7GxKggIabQrMIFXiSZXL5aR62z2NZwqMVBWmc1VOBlMKMHghNNi3R63DTUEBnE2puSGwV4+02tgnIOlEJ2s1Op
#8OTgNrHTYKpUCj430mL4ihoT7hWFMasYTWaxCwnaFi0jOnbZXmNghmhuqLwJz+1/r4JTpeIUnCzYwCQTEZ2SwCMI/iJLNcCvS5KQ
#+jsNq7/Fa2Q0WWyXBTeLVdsM5mRAkKexu4nVi6NEzP+aJPn2UMYXXwIkEuvJeS0jJAncg2CWOjIbaSyFaUrSrKIxWjGPYjAUhycw
#X4AmzXIlol2axm5gCeSjKdIiDeDGSNJaFcVBngIiuA4PgH0upkucLcRNT9RUuMPJApbWwqAvpkW3R0zG1IhgXqcyr1wXsIocM9Ei
#hOaaiILGUQ5rYZM1R3XaOyzPkRnb4p4Oi/MUmK3BTRlwD9j4kLEeUsAl5qmqh9agNgpBqqNUimxYDp5APqggfOb6Qw2IjiAfsLFs
#83Xg8MHZJnsqpk9FuwfweT7uhK874edO+LsTAXjbaPG2Ic3gLNWBtdP42ratZPlYiZzRpIMy9kMQFDOxQwEYwbRrvzfwMJkpwzzB
#pOGr7ZyNOvEkRMPXaW0qo8GguiBL3DloCN5ioWVytGRqMp050uCD3Uqp0/mVgs9cv6C4zZi/BnS8g2iAb5gJEbfFwzOdwTSmlBD2
#4oIkD3i2bdvLOzxtIHPxN5qQzkTpGA0depPIoJESbIBLx68Sgf6C1hgzDRxvL9QEp0EG3oKoJOA08Us61gCzhgkWRLFYcyBkZS8F
#73CPYJIL2VSoiOFtHGAyUwQpqqVNMbMIS7FsIzhupbRcq5IJSoCzHhWRA34qGwrcodAugsxiiqTDTFCJ0dpJCAhOdKPKvfF2J9ho
#wtY2TmtQ6qxgc0vTZTIZc5yh2SMfAQWCD3OSGCRAYCBRZ3Jkn0pBkwPSTEkV+GISyA9MUXi0ocLgwa4sHAYoCp7YWQHJkH1GxoRS
#EiqMPQgFAgfSQfNrB1GiI9bXI9gD4IDhQlkGKfSCPT1BOXDKWzyb5fJ6TCNtgWPMB+I9rpCPLQuRGC26NY+FtE4qvh/QI2NZuVzO
#ihIsEsAdgZdZJkviLwpYdGjKoQO8ndDTPLhZbJARHOrgkrgR5C8HB2JzG5eYyAhB6BhDtirwXQbEGDA6Pb5NRyaRiXogNiXJ8KaV
#JqYBOSdJJuIzHPChevaUTOMYdI4ZZTkKZrwcV6FzzEbYz4OxyYV+GqxRQSjhg28YbBehLdzKUujtAORu8VpAuMO1h1tYKricgRsG
#i3LchQufhxYLd8q2RrDUQyxmCU8fSm+yZLPzZJecGXoEXgJ4K0xbdRbW6QqmGBAZBYhmWwOA3mzLiivsuW9InkGrlEXEuCEjbhHn
#z9nGcvfBPJnCb/iCx9E8OeyleQrIaXeVCMCQ0IBBc3odb+gpwpMiT6YEcpeCswe5A6DOgt2gUloWImqX1gNchReJ8N6dpY0y8biZ
#BUBSAlIyesANq1XluwjZTFtW2EIqtEAkgVICg8lahLFMTTvemGYvpCCpp3T5AgUgtB/kDR4x0YTmhC4ss2/DoICzheUNbS39GIrL
#MlpYewjVk1IRI4GZCZZ3oTkjD5DksEslEFEsjGkhtxzYpFAwDIQzTCZysQNrFcwsGbbXJvIdMIH23SlIM5T1WQghkQoqSZWW/OYu
#SC1aQmW10YhYZ7jycLjwF/aJ3kV6WLXZTkpFjtpoG4kPSKjINRo4s0u03qisAyHWnvfHCpxcZDsPAYIOz3wkBdyeWcBtrma5A/CW
#5awqEKPHGFXg9gZoZGLhChbhjCpElut2phtgc9oSS3R5zpI85GMncPRi2BtCDn8ktl5ftv5e3n7YCUxF6aAXodB7DExK5GQGLUlT
#ASPjx25i3jnMz6dE3zAbwm02QgdUhN80S2QxYeYPd0eWtUiOF0IRkV0MRgG4MA1JNUMVqxQbS0Ei5g4ywFZFR5sttRUqswBrINjl
#FqjnRxWh8AeFAsHWsbGywhmCtvk1RbsW5eAreACuAGwYbmLYZH4EZrOLGOMzNUbGCsyEjcBMjA2Yjx9jA8ZSFBu7L/HATPI0IMrS
#tuM1ASEXUG4H6egOQ4SWQkZbNFMinAiwhaQenHhIYSJYM5UcprJ+vsIGPEAD+fxSik4sjgET3vbScoxHkEglCliqpmbu/Ba5AnAH
#B6QNhmTkvo95ZloJxpQMzjI37sUCJuRlOyGUZbM2ShdEXNkmeCAyhIybtzKDESwdkDSLRdiKxQbmaPYsy+1miyuERuViS89VzD6y
#E/cFJdJKylSVlIl0U7YnQgo3PrDxmBlboIhlZuUfhOgmOdxf6ET1BZnM1ZzSIkPW+1zVkmv68DVtK9ImSllsXchk+yCLDP5dMAo9
#vB6V2JMrxGe2Q6KhY0aTxtIfI+wZVNIs2GmWmHUQMaAy5BqEZU8RtwVQ1cboxtbtAPMK9hwUIG96eEuUwgg1RIlCDfZ/ymcopsOh
#2KoZkTEXo7XDj99wiqqwDRjWnd2eO70khShpthTnMIE0RmbLt3pO8PyUAikeRTjMM5Q8vwVoCZUK1zqCufTleCyczhUV0SUROyNS
#7UJPVKRBsefVfNgK3FLYUBktvFaAFs9MXbCssCJKcSQSoAUx2ayGSB7g9IT2FwE2K6C00MjQlnlPNX4DG4O5b1uzVvsR+nxliGCe
#DkbJANzBYNXMaPH62pJblqEVklwxH+wJX3gmV+BqU1yTPN1j2uPR0ZH5gASxDcFIuWJnKGBf5fbgqbAWSoZKGT39DWOCl4MO5giT
#4bwC/L7ehNUE3XHtGoH56KJaii+40b08QGTA4ymRrolNlonclES41SxXxOo5YtOwuxWU/sETazcHHmUwR240mACGgRagTRwUCIXm
#jsjky4wMHSPhZQyEsQ46fXXHHt8oEzuSAxG5q9loosyWbKnEw8OUBf2BpRT0bwfle4OZQaZBbYF39mY5klxAmtxfBoRWDx8fuB6g
#TolNZoua7IOatBhNuEUNpU3VWPgmvb34JvO/iafHJJqQI9ICmJOWX+fsvf4Nzt436Bs4e8bh34iv403BYILuBI1/FPAHT1J8osZj
#Ta9UrTXTlu5Wg/hMNQnOVEEskizEvsN4QVnsRoYGZ+7I2kOsRnFHh6bNLvNidpgQBSlW/UtbOctNMBe5iQiFJn25BH5BJh/wkeYf
#FUyEDkFrKjOZySuMoXmt8FDlb9fw7BEnDAAm6WeFEc8grRDYqaCOkYMWyvaRIKgWX5YWl1WUVFYhLAs5b4H3M6qDfJoBKZDY5vjg
#HE+Yxdi5CoAss5uy4JVviYikGDMsectm2ItWtBVKisvCroeJXw8Dvx4K3pYFLAVrcOc4YAqoU0LIFJALZC0EcwOApnBbsEgLUMrb
#2wtiVYCj8ChRWSboVW01qUgY0gfhBr9toEERagg6n0HjUJDm2NhVKhSTsS2WyH4MKYehyQrnloVbN7P2W47MYxnbPImd75mYAWVk
#KmQTC1eDNYrFtcUqVOZqhHIQSMW2GkC+PPZo5F4EFkoiO6oAGA9QwEGzVtjsrAFPX4xSlzfYYkdgoUuw1cV1OFiCfkJYssKZ/rJz
#COH7FCygQMeMxH0jwCnm+kEsD8iYBzvCBXCK0VlDa3GwMKxGGaoXYSPBnIEwC3E1JbT8B4yRNoONteIOUAyODxQBUFJTwhgT/JtU
#gtVFUGXmIJX3ixT3LrwHCXFA1tlErKUXJTECFZvG7gPOiA/DUa1V8RaKOD5gChpTokB5q4a626QUhhgZYKQMbCufSzAOC/HIPDkY
#LRIyRcwXnVwmyC4BDIG6FWzJzFBvboW0qhDkUCrSrfFmXciOT+nIVYdzQHQn3JRCMEJMQJdWInAwfjWcQMb7BUBjMc4pAF0dMQNl
#oaMsBjoi4ChlcJhif49cQgEkxTRorkmRgNpAPyAFpSEztIB75eIjAg6VtFqMiLGl9UajRYONOvOFV26AvMPJCM4/wfIzc8Pbg0Hw
#4rcH2tNMKe4+RrBlcBbeETYoBVHIdmRqMiOeRDwkHhnvVoLVvDbUCl7hMerkJHzzILygArtSh1FGxJA69mHD4gznXK3gvXz4Cz0F
#hxl6Bs9QVwRbl0M0RrPgANGY6zcwlSwERgWOB4EAI2XPVtiyGt5B/VtTYIArmoIazixRnQSd8dBDCOHQp44fMSpVzHDT0WCxBSE3
#WHjXLhwpcvVhg8+I7q3tG2XYNBXL9MEYeTJocWtp1w6kGXEPKlXJboJs1UiL4as+ekbhfPhK/BKI3biQF6Oof3svRjRaFBsProjR
#gcQgV6mAuGA0Wb4qKHj88ysAX3tBwafEKwA8fzApo4FxrLLFPOjvyl6eg3J2kWIlaC7w/hrasKPScnSV10UtdXzyCfgFe78tSF5K
#hDEbANBogmIemYqmKeVAzxIZ8ZLyLlrYYQ7aCdv038ZsNma2g55lkA2xzehhkuCO7T3tHA4GB7MqeR54wCz1hYBLdDyeCHACAibM
#G4aGwQBmGJJgmBEahjTiogwPwhtkauGvLEnkoMYstzgqMELK4omP0SHxwevOTNUoop4Q8HDLcqQnI8SuUwHufAMVFRzXmIwaZYJF
#jsF2gDZxI4zC92/ED8dEyWhoZ1TyUOEW14H7sLgXDO7inRkZLQrj0Ii6wUZOzIW/7YIINo6NXyYyN0A4ygSHAHinTTVI4f1arkPz
#+2Js7hFVYAk8G/8Pqr+bMYeU/eGngGP7ylGCIcJyVRxrynlO8WC3nyOPcsz1rAPZRukYRzE/yCCp0lFFxISLWMCQEkaQyN1VJ2FS
#JLzbxjfbbAog2xQABEwMFrsWqCBfjfkeTEBK7MXReWdAh7OoZ5b7RKkyIUTFYiPkqdEQOKMsDtfsTgDYoIhGQ2S1pY8Edt0WzMKe
#5OFl+EcUFI3TjWuVXx4BHWO5cX6b2AQxKNbznr394FQS9oy9jcNvia2Z3Anwjw+e4j+6fGICTkOmGt068KEAuAii33ZzlJ/CBrHl
#VPdaSsX4WeaLLfCMhs5IFSCAE6MqzGZ8rByf3GjkDG1weIh7Yjs53Exxy80SFwHRtdVrOPbnZisqdFboXvkNi+agaWaKCIdtFxJx
#s+74rHHnQ6E6IhsCWQdzPjq0ytGQ83EsOPEASxQc7u48g8E+doc6ae4thlJbJEm83SECTbFbief7v5m1wd2FCGR5XaJdMHZoPqYT
#cBfuyOgXRYuDnIaHtwyaT7JyPtq7BjkU2xn2pni+i6EpOKqEYwHHnXSX8xTkP9xe/3xbyS0aysB4qjvaYMVMTyzv4MmqJYxKDArL
#TVnFrPgUYeVsu5OEzRCfJtxMBSeKULfDciIsBfim0AqIQCCMzYAxZAWiEFcd77Rv4We+UseuVzxO3okew5/RuMLjAkWthb637gSX
#ygR6+xfcHWO6dIiOs/VyxE7iBqNFq6SEno5tYrp2hPxRm8i27aLad+jYqXNMbFzXbt3jE3r07NW7T18fXz//gMCgVhLHLoG25v84
#0k/xAbj4qD+MNWOzXDwmdFlt4g2yLBRBmc3YyocxtSR1lJkzSGVmguz1hVe5oRpvUAJ56jPuBJzjITtEilQJ7oh1Jbt/6FJ9XKD7
#BG8RSJlozhITuk7g20+FsEXam3X2sLOIRJkqOysX5GnhsFFcxwc2WEx7PuL2HBr4Eko2ZJjSpNSrir0x1xV3qV/8APmB+JY0a9/i
#Zo18SuzgroL0klAi57VQhEmMgYh46Vj/KdASfHRke6C098e090vB7TLh63mfE4HDCfwXmvVAfWWolvfgZFvDtuVhLvC8gL6tMFRY
#CLRNxbYmKIYo668K/4USDTQKzLKABqwWQMBNMFStNgd6EmpIM+BbKDPN5Bn1JkhBw1wALXMhaBMYt1JDKdM4B0hw1OGzLcwlqJjt
#p0PBk1kLOSSPM0anxbgX2WwEPc3G2ENPGJ44ygjbI2C0wlxMRh0Q5V1sjEFsTH40pB4rh3GT0B7ExhlAS5MKsDjC1VZYDCLMZNvm
#trZabBOIOBpK4NXDmRGIfHk4UyhjFsUqiqCsKMfRCtFqIf0QECa5gwQVRtjBCI84KBAHSHci1QhEc0YXmGqUcFEU0PdqCPTVIAiA
#HgaLVse/JnDxKhRWOlt4byGMbZ5LJAcTXkjSBWeGwNWZSKMAfWLDsNPZej0Fv69E6px5RxLIHqMwtIRdEFr2AxdwiVmpk/lihc2H
#LqDQg6COo40TElgF+fsobRTkVpNKcPwiqMjZ1YW+5qSOU8TDT7dADk9wfRYqABLIgUBhAsYL68GdGYBYMHH7iN0Sfi4DDAZ9LAP9
#EqJPZdBWhV5rcYdBMex0/Fodvk0zC4HF4gr7cROL2SYqeRJrK4huceBJy3PBSplMaLEbwiAUq5GQKgCDyoBMwWkx6ERtEjawg5pv
#e6EBnJiQ7TamSXCIUdxoIscA05wFg79QqwZWDpmAQ6hwiqNix4N2ncIB94U3iruN0pmFkoLVpf8DCDHcrygAaC5aDSkeHgdBLbZ5
#Znhom72IzG/ZF6FMJQKt11dBy44HFgW4BmOd+MsYGCN6KoApC0pGanIEr68FAosklWngsFRinXJTdqyo53BsQOJIgmLH4wHHI9R/
#iTLsBlq8ThkJcIJuHbdTbHUsnn0VYMWLVoCOoa35NXiagGRD8dB0BBuEOtiWCn9+pB1jfMBcRojSZdAADD7gr4pgTUQJ/aOpcPiv
#4L4QgjVVMpGhEiRqUo46cd+pQCcAJwVbHF3icJ8aU1JaMBeeOgqtDlizA05+hDr24ruzJQD8BoE56CQF+A/dKNMQ/0CD6QA6w+wJ
#O5LOxCMLIdgvXLAHm/CTHDDPnR2kyCxaje6rua/O2JIi5ry1ucBGY2GmAuvaDs82IjPLToSIz9liJoOtN+zDIzoYmZBef4WY5DPL
#gzeEVxK7NbwcbE93IogzVLG/kkOcikRw/dYbX8l5tHInwP89AsAZw9zFleBaE21wYIJnYzfEbkWBdtIGZMwpXfw5LtZGMeDHOFMM
#KhW7hIgJRtazPBJ/m40SG52U+aKeEt0vIJ6CMT5w8NkcjJjsbjBQDEngTcts4/vBaOesY2MxqFIscthhOH+qFwsOKF1DjQ7r0MgE
#V+fjGobwG9qYJvBBQxeyTHRnJK7gDY66ZNqyw34UNlRPsTFb3YlA4afEsH+ZADTCeIQ+rWSOYWqGAeVYh0zEKLu5hdiU0RrAMmlV
#XDGkE0U8dXgYPF5yeQ47RMRhC7DRjfD1QhEUBbOCRcEu82fpEfwPQ5rXzmPsZ2/ckSgtunXEm4WlDjZqcElTsF0hokmEim6dSNEt
#CMKUSwBhL5in/o4PCkfMLcO7OqBXJVKbEoya3AkfhvrY0x60iQiNtzvzhPQp7nKkKCF0Wnc5FOK/blQc8I9tBYLsbQX8A4qzlWQi
#7v9LKrZ2beI7RnZp072d4IOBFKmPRMc69glE2ido9WU0U+iTH5gUOHI/tOiZz3qIo9lYNDb+V7BFgZ4HGuTD1uHHUsW+gazNPONJ
#x3oDou0iDjGvg+54CMQSsP9ZtxgHPoGgX2E9g43HMVOGay2FCKX04VI+8Is822iFkrgs1BNk2Him2rgOaBCzjm5dc4lMDQUWloSx
#Y5lkGes2jH0KPDk/HHZ0aUi/x3olAlbIgS+indch50KQb6s6xWE3BTpTHD6NMdbEEdz0CUYLqcOG6foucN96YQleFNSt5PBqooA/
#lE5nxGHVoH5Eo4X6FKTGFIIJkCOxdgOr0Wx0suCV82/Sg32rNXhYjKbgAPjBLZEXokboWYQ6gBodPoiMEMYwRxCVUlRDDgiRva7P
#Trmny1AyCiXclo1mpti5fG3Q8KSh+VHb9Y7ymeBj6PHbu8YfXYDuAar4bxgJLlnCUDAgTDpa2PK/CArmU9IljEDPhKsCv2yuSAvP
#5EahOBQEVnLyPeiFntImR3pn6JXLRnAy27n22banwV68YvWzSFXHmbZ3ZexBWf5c7AMSo82gOCaVNwICp4fRAO8U3HnnDIzjPC9h
#lNkEo1BiWxzGK6Qkr1PLN5WEXqbGr5Z07FPKcmNUCTFDdBlge0MKCD8YJTVC8g94OV2qREzDdRlaIb4YhZ6EHJnhXR+NrOujOHSt
#Tgeoq1GeSZr1VhM8RjIFhwhul8tDC4zf2GAlGjANhKQiemEqJg6ENtWFu3jA42DIGnaI43x+Yd9GO9dp0GOxlcR1BI7SCgenEyok
#sT+DuCsRfmGFR7JdO2who5oPj2F0EB5D2Ifdvw4hBTGGhjPiuRKlBYXsYb2nefAgF5l8YVELW1RUEha0cAclmGRJgQ5oRyeOtx/+
#xiPfk5HtiXWvZkJT8/0wnAIbsAKriXKL2wVi0sXAOoP1qxAFztHI4RWigUdEg5HzW2GomZC2mjNgc3xTXOAasSM/DlTCUncmOIno
#qoz32LVHia+HS+H8nCSehAStnCyf2LeVEPqf4vdiA8EIsEnkKUwyHrn2MaxQjCVbCwOZwMTg6xFIiuW2WDHR3jEexiq3i4KFaThz
#rOFgujiJWZdEKEOIKD0fBYrhC+xi2jq+eoSlXexWCJJqMy0OuMCurIrMhjH7UYFkmqIMDu5CIR9rX8Y+AM63j4cJLu9gPDBIGoBP
#MhbLIgimbz6NQX1mToKGxGO2bUdl+WozPGf6H02NtIU0Ww9QH3EIHvawwXubZtYebW6EI3j28BEPHHNa3MjZiFm2U4ftGVmtCNMQ
#aoRTlPyncyzWRRoItejbXGCgsIzje3Vc/9+BtohXFAxGL7dA2YaLecAFj9Gx8UG4FBdhe5lGA3vZrJcDAZ4WRXsSyRIuYoRGjkJM
#RfBGU8VXVYmqQjdIvip8o+1DTAk/XmVHdLoivLChOtj/mCcyQr9hmvMbpkE2KK9CfsOQYnvzpIcTGYRB6JoKWsQnk20FG2IlKO/4
#+DFluvyD08aEN5hYyKbF+8MBByJqH2IpN3FZcf3YIblNSzT7VQ26mAZQOIiSWmCCCoiHD2emgtokicGqp8xapQTGcTdYNNDTTAPd
#c5j5OeqS/86Hw06/Hp6MhwvhiVAIh6kDu6k9/NK81Fsmjl4mFuV8XISDMSm5LSHwtnbcgSDYkQjhxbG+eB9FM0VjY1p0uW3GN29g
#v0oQN49JLJMKNyNKRnuUT0f7DqbjBwhewM8BOmM0i8NbIhqDgjboHW4xYcQkPc93KqE2FxaJEBYRTBp06e8FFhfQfNQML5XBUSlp
#OCZBqg9MtaBUCcArURCnFAapRJKs3mzMdBiWxi4SucA/Uo9C/7FymJ6Rw2g9ODMcEGe91vG3enGwUhjLFT3ZY6ueIQrCEFCCbHha
#y6EeS8WxipzwjtCI5ikmfnew6R2M16yw0T5QyFKOY36VChfbHaGkIcZDwAhEM62gjsW+DlxcD8K2JlPRkw88wnMGEAk4hkCECgiI
#YiS4PWMDMlpB4IDxt/H9ZrAdDrVNQNiSAEkG5hrAoYZOTJU9iXAArjQViScg6F88Hl/8MQy9UG2pZ9WWzBv0iaEtNI4ce3vwNMBa
#2xAuUF1FftOIwL6HcVTQ7gdwwkFERWF49Cg4sm0JjrqwbcIY+ZxdF5Xh8r8vYD5l4VRRovRMFwcCd4oN+TRm0vBuW0qazUjP707g
#GHq0ErEGTUmzmRc8mc//CKVlhY84KiBWSOALAZnNjYDtlYDDOIG00gEnKGrGYWw3/Vdju+lLiu2mLym2m54Nrl1MTX1qSdn6DFNJ
#2UJ1jM2sm+VC6DuOhmgxO777EJUxFRMfMaDE+Ij8Nci33ILA0jBGUDJFmnXZqJZVOD+Yh6dntQkT9j+Nv8iSEfsKJPzivX06WAEH
#pRHgv+FGxc6IAJvGI3FDivz+hOYEGXJ4b8K7Y+J3u0AYbD2QDy9c8HUvcnDX2bDN0ApDGEhHbA6QwnzRz5ORfyJ0Wr3WEubfwqhW
#gx7CoNIHdgD9KBx+8o/gR2gTY6KpWRDXRBjihOnKoVuOKCAIUzCEnaRbmPCmTxSow2xkPxOJAKDUaHUqQF3tJAsGPIBnsLRRDSCV
#gABDOEklCkoNlhNwCsyniXAgb5ZhkwkM6Pi20MbjJRphrJFQwl9QMApfE/BFmQmFE148vEQhsm0vmpFVru3skhgLQDh72X8hIm3A
#/zAirQA4ts74QtxnfFucBStTgidgSYEU5JBDdRBHQVARnHIomoKBymK/3xqvVYBjNBUCDi2Kwubrs+J4A4wLENyGEgGSo7rQQFEF
#QzRAFVBbuDr8FrS9T3H8RU12/3lCnoMyQDuJHt2jYcx+wDMYLFKF0IOy2K34lY3HRQHO5Q0wKBRqR2wYKhqviuC/zVncHGERyAhI
#Vd9yTyRB4pxAG6/iOGJom/KNLaFopVxDonbYEAX5jLFiyWEk0BLKhKS1+BBZEADcJob1MExw6DomGh3OgOeqFzpVUXgXW+g6ipoF
#WpLZYJZdn4ydnoNOJV6mLEnxQbdADXcCFw7G1ZGZS0eUItrhjgJutbUqkP6AdcXgDXMcjYSZcT4XEojxrXNYGibhwwaPhYng940z
#EcfKsAuqF20oeeQcXBmjTT6IkYNzG9tzim9V07jdLLQz4xcRow37hVdkNMaa3Tn41je78mkOvqDAqfR5J8oSo485oBHCD+TCDS0j
#uBsdwjYKFxP+mRkWJNAarV2IBsTUIWMNkTUdG9JdEMwK30iHiO42QsRKR9EHcLl587fdyLXazv4K9Q4DN7oTyPTh66ZWPv/4HAx0
#YGrl6BzkTK3Ed/TMnuUXmL/DwcpldLsNWAJkRcMwdehZdN+Dy4aIjlCBey78L0POGE3DH0demDDdxgUTJzHGYf/C92sVRqPFWWqz
#dWAis3UwwnYFLIuWRh9PkSZy3xjnv/LIfJRcgkKtuHNfIQcTScKGeI72HPtxa+d8Gf+v0//H/uRgm5o8IapqlZ6YFipp+t/tA1p3
#Bvj5oV/wZ/MbEODr7efk7e8T4OMd4O/l6+Pk5e0b4BfgRHj9u8Nw/GdFn4ognMwAJ0oq97X8/6V/ni2JtvE+cVSWlQYEz0DpiNuD
#pwFqBK2XAVuWRhnQzS78vB8+tRADSMuJ9oDs0gRphl9/1qk94E00pZITLT2dW6tBlocaSDO5zJNeq8sOdmmrIdPMJNEVfl7YJQRl
#ZeJzE2x9/K7S0pDPCqYzSVMIbVYGW806KYudsATtqUSteJhgKx6AimoNHqC6hwF+XFgnzwRnt4+MQJ8atkhd0KuLLP9/MKaA/2xM
#Af+NMQX+Z2MK/J+PKZI064zwW1d6LQEOXMCl0JRKPDi/fzA4BWrOgwbNeSjZ5phR+v1XR/lPUK2kUf4HOPcNo/wnyFfSKL8BC52D
#IWXDHz/xoMExDpgmFWlOC/HwUKQGu3r5eQV4keCF9gYvpBfl7QdffMCL2tvfWwVeIBcY7OpN+vj6eoFXyJMFu1Kk2ksdGIK/txDs
#GkgGKUiYqwR5/kpSofaHRYNd1T4Klb9PCPy+e7Crr5ryClKH4K+6C/IUpAq8qf3B/8Cb1gCKevl7BXkpYR7gpv4Pe18C3kS1Bcwm
#QhEpKsgmTgPVBpI0e9N0oeyLIKtQQJBJMk1DkyZk0o1YFGVVQERRUFEBEXkiiiyK8BAUxedDQcAFcUEUF+rCoj53/nvunZncWVJa
#ynvf+///VWmTmTt37j337Ofcc9Hd/q4su7U3iF2jEc4vVpCRga9C/ClkLAsYeKR9IWhFA9AX1NlOtiKaz1Sn9Ih7wpVGPjAdlC1P
#OOrjoqibyuqU4lgoGBcsAYvZnJ7jYb0lfuwQF/zIHr8+B5lW0SJYsEo3Ufdz0KJ7SgIxDDjolzOyvqlILJFOiGFkjLA+KH2OU7ey
#rBH0Ohh6nCR0uc05IbTa9Ltl+XSwfQvjExApY3FGKjMtJruDEUaFOsIKCzXeKOsLsEGjH/6CwY8UzEgl7NNAv9kYY2aM9nRD1O9h
#M6w2q8FicRrsVoPJYtEbsHYLR/shZTPLnK43KLvKxp3YrUJXLnM6Y3QJnWWjvrIsBqvdgTqz1aGzLNKZNK50CECKI0NDsriyDS40
#MrNTo7PEoiRmbmRjMdZbDA4ZdxGEhqtTJpJ1mhQXiRECJ2mBEGRbsaUxtBI4mIGJ3B0oLUZoEhPgL30ri/Loq1DQpDqFjcvuI9yx
#GIqthmKbjFOQ8QE263PEha5OicQTn914s4ixPMAHPEEujoQ0JkaEHwwfDgZ8jJSFmSPcMxLj1o1RKBDyG/hyP+qwkoR6MO5Up5iQ
#TkhftNoRfKUh4CoIOQJCui0u9DL8y2mGPk3lxfFImA9gw4T1oGEgBpAjdIR6EZEUfRRJQSQE2PDpjsI2TYhVof/0ORXFgRhnxBtv
#EdgromwEvYEvCUQ03gGuebcxOzsbdQ1kgsakQYLALvQy8kD8RC9NB8/GDk8SygZEK+NxX0pJPN2IK1MimhLGRFYjjsdhwQBOQeoV
#GgqirChoRnBUQGLgPNg6VXioic4s1hwRzYqCXGUOG0SKmBGXY3SDe5iL5vjZCO4+BxoYASZu+CWujxEvBvltTiyTXVgmGiSYTOwG
#p8FiNphceokTQRNfNBwxEmeXG5fIglcSSkl2S+SFiBpCsMAyHMS+AgQovAASKQWwD8FY61TNAuwB6IzVCsyLoUkjyMVQW4wkMFOT
#xc6FNPgfZq8+zhsWjGagYgFmxiheVBleA7zM4ngZiKrE6T4JHiXuIyoiOG6zJ5Acf9bgxGi2+PXS4x4Z8wACLE/gSZQDYV7O4ctw
#YI4G7kMMIQYcAVDMGI3XFYfQA2DbxlV0wlv0GiMnS6y9thoUI8IyC7UXKYiapCdWqkQEXIZETbUwmgt8t0TQSv2qbhhChukuBl4V
#F95CP4mPkyKNJopbZSfFRZ+PySGyfh/Z945aTiuDzdZQ/yVkMPnDQqdus5onJWNeEjGAJK+VFMxORAqaiA+81ghBeiSUglX+cCnw
#XIOXDXrhYM90qCcARI2u4a/wRfgE8hW+kk9mRvUMAiRIWoKhhE0wJitP5C/on4zJ4uBFSGhjgMS2QLBbRQ6AtSO3xYHxFgAYl9oB
#Wljt+AbulqwYAbP42R8W1lHkXZjsSzmez7CYLFa99CwpUyg8TL7EpdG7eTi/OMOUnaUXRuEWFz6x7nZx3UvDMSMbREKO8+UIr8Xw
#T3QnYBl0ZMKTj9OiGCQIW87GBAGC+AK5S1Z9usFmBtYr8Bv5RYnNKKjDgdRDEej+aMCXg5PY5fxBKZollMOrLXtPD5Md2RU0FhJE
#Rgp7EY3CsLpsNKG6WWwOH+c3FPNBob9iPeO0pjMOK1LN4Cr1qmKIxNgdesbhSkdaaLpen2CGCWjl0ApwGBeuRWIq5vbCbKQpYxgT
#wEaiYbQmHIO0vTIM3khIk+1GPHVjqGYtjaOevAurLyJaOwTmxTjIPxUToyiNZk6Y3rCZUsz6kGWDvuJpnJ+PRTyMqTREKX82e3mF
#Ch0wS5EuckHETPgAr62tRUImHIECKGq82IvFijhSN9H8bGi6KoPA6hIGmBC2FhulUdoUwhZPiYYQxYCsmAFRQ8OdJogyGkYmNpdh
#cZkRjsolIRowfjSoIYaJHmHGOl2CL/YE4afHJpow7GzAFEnlczQYabA6SCGNHKKgMzF2ohXCx26w215kVeYcbD0EgvBFXF4JDolY
#RYYRJsGIzM+lT7QyhtG8keYJmi6GAA104T2I57vkIgB9TbwZf5etCIKvOEQLPUTB1lEzUPQEwxrwH8Egk1F8DsUnMPpiInaDsk6D
#n+KXCDTJ1YpsoEyLJsYp3U1J1Ao8XlE0JUZNX2Hl9p2smdzyUyOQVUt/Ew1EagimoCgVZeotC8ot8EgqlkJicYwHQuLoL3UHeKdw
#1pVonWKkM2PuVS3dZCJxLaYj3vXEtd0WFMfDGm44yMsZssISkpixBqMWNH7RSnGS4SHJ5C2OY4lpYSwMMXi1RAFpSerQ0aLnYqis
#6snL1CAYE4M/EesPRLJDrgUSV069hAI9IcGApbEkp+Esu8TjI+aNEwZrVaismphbF8CRFRQ4qlVlsTsoYoV+nFq0mpg/DDIZP8eo
#BCwdNCdt3ojukM7850VMEeP8IpuiIEC5qOqDPE6FrYXxo3bGJHmYJZWaRhvI4RbRwy9jTGoKlTWaSBfqF+pvTlJzJ69kS6oQS2kF
#oe59Pk2tzOc7v1oGftRAURU4xiFJwI11E6OHi1VwSM5JnhRKNGddDCVOJSnkBOtQEKyGKVofEkaAOL9ihxrRihPlpbAovRTnV5zg
#iBcspmENLoJSR/dXX03M52uIJga8+79FEWuw2iX4l424cBBP+HcS7e5ClDNqlWjlTK6JKQeBnWpq/Q11F47ELgb9AvPTFsT11uWU
#eqE2C9WmYbXtIyNiaVTY+WEQqJn4QRAgRK0PPl4MzQ71M1F21I3Ei7X4d9LWbjdbFMNMn4BfpxNA7UywD6da9GrpQxoswSWBkFAy
#STOIy3wT8AuNMxQBagAeUxYq5d0hKFQB5wlYEEMqiuoZ4YINdCSDKQuuEexwKbRAyPYALxw+p6Qur4pyEY6NZQAag887aBBeZQWt
#wGBBLxLeZBfkiAAWHOASXi1hL/XyuNHIurs5HA61mtlwLmSnlR8pQINJRa2e+AJRUtTFTeacEIvysJXaC5BMQjBeSHNEZDo9wEUz
#TFaDyYU4vcGiNyiEGaIEmjKIcAHouN0kA57GvGRMHilfgn5GPokSzkyLOHPdsJTVS/zYZLXm0EEOqxNEhxbztMl4p43X4sPivIic
#1ub0NiqKQsiUROVDgcqMQCnDI+FpEIfJOBzpBgoD9LIXSOBLOCStFJ8m0gTRjvhUEl5Ri24uE/eshrS3SMTN6g1mJmHBGCkTgBUH
#kN9DU8ULcTFWLiNqFwgaEiSJGkzUXqATwHYX1snhKJf6RKacdYkqCP0yAUHzykpgZVYdOacIJEaIDxNDKgtH8a0OmTUlY0BUzBZ6
#QF3WInA9LFp+KNGRsFHwE2JsCt5pc6qCb3j+5YA+6K+ws9sdYz1lQTYK33mpH1UITbUaxK/vYaNiFoU6DputpZwTFqjkTlStG6Nd
#7Bktg9wrVGu+BqtyzsrNJHKEvMkJkyyCLJoGoarQCYO3itYOKTKforrF+QSDE8meeFLliOobJCZGfRE0MpwmsKaCpELXGtYhsTzw
#XVNYvvSYLGAPU1w7ONWQwGOW0n8ukikhG7vC/6Bp9SY4KYOHacC/RSOrYdYsXyKit9WslkpU7kGy2dYSUjGDkSRLdLGZRTGBeDeD
#+IsqDQa4daZVDO3lQK45WQq+mEH8Bc5cKAqUIqyqTiko4aqKomyI4xm+OB4LU6AwSuzbiPsyV6Op4np0caxXEdXCbck0WhKrIwX3
#KMU7GdsWuxO9JnQpK5J4Qg7w0syvyHImN+pp+8wspLEwRghtEfusvtafgg9BoCoaQ9pepNINU0Ufqtya3kWJF2EtRsnOklI61uG4
#Up8i1SPh71IE4giZk5iY1vpJzAgNW0P/T5p7UCtiYuvdIMs3MTv08gtZDhLWi4LMSZLegyEsFMxM2O1UeDLIhiIZ2ApwllcYnAgU
#eoXEIkChPW3yBDy8ox0vN8kiczgM4j+TPbmdJ9fmhLglertAfZEqfVKXCk9mbQqE/GjmWqMR9Qr1iLKtQt5CAonFmCFubDbAf6Ys
#WnwQIAGGG+wmOwKTHVRbAfS+gEbqCQVqGR4KulNtnkUiIqBnrAAos4+E8TkcSlqi/bcwpWxC4zjrUcJ0Z+IiU2yNJ7KE7Fg5siiU
#IzGBjbih0ZOBSFxzPooggdgYVyYXogSUE8mskanhv9j+wrKAMRQuDWPEMwzjSoNhg/Q9wSywt0UzDMt6Y3Wydy0me1GUQXZtMmAQ
#mPvDCkVKzcKlVRInI2BEFlFe6jogwQC3Y1u79kHhPjEG17IgSZOEzDJHsFnqj+hj8tnWqp3ZqMFQ2rMqW0feZUNi7Hijab2daXTq
#gqQkAflg4aemHBHagkKJy12bvHGlS1a8E4updT5yi0A0gd/2SHJ/uCj88U5bZADVQ8UW6B2bnpgvUmqgTTFD2Ui9ymRGZUIttBAz
#soUmZNGj0TrRGKIwyA0kv7BvQrQnNZaNVmbNioFpMxdFYKcuNlo0mg/8GfKVMtx4v6AR7+vXxynCJl5mrdWJIkW5ojhcJ3vEpaIz
#4WkiIRpCB9GoqdinYTpp2TlkwaAwAIbaeQ0u+TqgR8FUkUQRCXfXUZHFlQJk6eToYnEAmee0VqsMCWsOSiW+CCXLwo7A/T3gWaV6
#dzgxExWzfLKtRIfG7ZAoNSD2NU0mUonSAILVYDM5kNJgI7qVyXIeGYu7zI8YhL7hEALoWyMTgBpPltlbLA2HSF2ZBVerNLzgkLJG
#OBXaZylj87CGIX+DvMcOLe+xLHPCTlYE6YRIeQp4NUMBDXQLk+6LbeLayPxLLk0ZgFfWKT6qnc5BOgsHReIwYtUdpiXPO5TLcqwn
#gDGKZec0GlntLk1kBTQiRh8frwtblBlIwmsYMW1F4etODgcojGLEO2WJs6IeAkmkT/mr3W5R5RcmY0RXS7iokkHIHlHYZT11ysgo
#xSgw5OUundqCuxRYJ0K8b5LyrargrB0yOfXCo9L+FEHumlV5RHAaJz7YS5lChHfPSwlETpJA5NIMWiiSfaxC+q+mS7Na6JkptsSV
#VpAVdW8AdmYHdiaHEjJRpUeTJC5xXhpPbYI/rLjO+fdKPVbsQGS9wgJaSKY+5CHXwz+t5FtJ3IjQreSediXc0666uafDJXrKaRQp
#Y6xJnUaRsrg5Pa4KFZiJqeq0GaxWpObbbdgerM7SagvUSNnu1eCz0uqRbgMmIg65XQwGCgAr98ZpNprciWQXnEj4Idj8UweRYcXa
#t2iAWc1qJBE4N7iV1Ja6Un1SzMCspKZaXUmSXXQB7qNQA/xHRGxi0aGdNa52hJideqLkyxycojNELwwIfCzioOrnrzIT76nMY+Ug
#HquQwmWl4TVJbNlwqUIoDXFIOZNskQsl/EkKKYLvBP1xesMoYFy1eEcwWck6i0oI3OJDcVH+JpiEwyU9yodkj0rEElAwM6cKoxMt
#E5sbhdxRDQZ2gZmfOBBHGfJ1DPDVkp1vFfNGand/qXbc0YzOosjmCJfohYGaKlTOMnpHq8UufxC2TOONSAG/2qdlVRsFmoRPngcP
#CoU4xD2RcA7YLygICP0miWwJ1n3d3FOUc0pghLFQnKrViT0QsZApRl/EGnusuGHxuVqCSA32HjiS0ESsWEZTguIbCdYFVKIcIft1
#JY2jFg9Dgt2rg65KKUkLWBiRKcSp8FW2nVuZOqBqYXdg1C+N057VOqSryHU2K+6DuBKUdKnhu6+bt4H0yYWEpRCUf6iroK12y/LV
#YTTnD+kSd0SJrxZ/YV3IjI+WN8gudSnsUmLD83XfUaoRhqpvBE3LfseDYEw+UQQlJFB23dVUeuMt6g0cxWpnPrmnyf40V6UhSIVe
#lJwnopus3IOafB/zBcbH7fTmWE3WJozj4oS+4SAgTbePTOSTjIJ6BQcEPI5JaGxWu1eEbmXBI2JdnleJFh6tba3gdlKRaXXWEo6y
#y7zT56VvPI7zptIk5ssocy+IhlER9KnVBIvcR+5QoQJ6ikF6ibI7cl0OGbyDiNyQe2RFRSUSVK4wKCoUchJHSaSingmhdsgHtWDn
#QzaWgFgOCg0sVhExEs7SWgSiRbQf1BIRDy0ZWRCGFamoNfzTIGlUcaFhKfQknWLlpC8ygdqMomxsE0kEbhBVK2GqJl6m5ifZjkl7
#9eSJHzi4ALaGUrlhpQwPqKtbF2wAA4WhUMJCpQjjvZcYA5CqA7SHG2M+UBtGXMStXnIpaRWlpDL5vNYtIHTSLC9A5jx7QJKJVXh0
#ouL8DDH/M9nODnoDFgxWnJoiPEXqakg34WWBWiRrlorfoObJVCfF5s6GCGHOb5XzQjE/S23/ZWlk5gh8S+iJyjCsZxw2oYPYZCVP
#VLHK2pVQMc0MxmLyejRldrVwO6ZxG9tKUY8mf6HIm3JeYten2gwm3Zi8vDpCDNdj8uuiZkMzA9yulNeUuCU+Np5UVJ1flGq7TVCn
#9eCrJHidyGbGwWuYNcfH1YHAxHoqrUdZyRl1LIr0CKd2qQwsmSfBrvYk4AfhoCC1K8HhMGTj/1UPEskNT8IJQhfghMDPSocOqTGM
#MEXNwGgxV35xdqgl52oMeUt9dphxMVFcmtX+1XpIA4p5kqpP8rUWg6Zi5NRXEVcZU0RWUEXkQPUFR4HHStnNDqeG21jwKHisbjiW
#i4T34/I2eHt1nVIYRGmahaWpyQXyVFDGnaIWDmE7g8kpaeHKvTgKZcup7X1w1VEzjkXz65C9gBtqJwkodBeFh4YsCXq2Dn4OcTNW
#Yv2TODtikbrZ1erUpFikgdkSWhvrIxfm4oAHy86fyZ1EIY3Vzy/3b3DCucXtKUmccCE6uYoIBDHECTgLFKgR5SQndCoinPgiVV0l
#25W8sp5DsAyJ7ku604hg4jxOiGA6zFoRTO1cxiCCWO0kIA+5253eYtpOFyKdQUpzOp/TFo1F8NvalA56cV8cH+MifFwZYJdqXNKM
#Ag1CnUxgJfvey/DmK3wmjZsXu2WCgTo5Te1U8E0yo8nz1KY08opAqTeKz+5w8zmSMkfuZfD6nCQF4TScVXXM908ImPPVb0ooG0rN
#SC3eyPSSq+XaiSByvkj60PZLgF7135W+o638eT3hykQ+l1MV14WBZ5G4rjMR14WnmCDr4bR0ZU27RlsuQ5ITr+GSSSrI8QNCIRKN
#lOQE7TpxXgTWx4yYN7st2BmlkazW0DxmPFrtGi6SI0y++waGkFDFyiIRLupleSQ42CgXU1meEsOuR4EEtbFMQe7fU/GEfoOJi2ra
#5B5F8ROlVm5WdRQu0eonXKLuRmYWaMUXSbfICIzECR+GGu7n2zFJqwSKWqggCkK8LKhsl2ouJhJRk7qDBMwm8TzoCUNNbZTgWwgO
#6hkV1SmFUxTbdinTzBvxqLcSIX6G+APe0Ufdwzo1XYfZSlWdwQ9rUkj9UjiTxLMZyFO6oB2FF1ZvtY5hh+RiRqsoqzQculwqtUub
#pCEUna/iqrg2TClbrsEwXVr5r/QziqiKYEtqFelSPFZLBRx8gFUiAwRXjiY7loh8x+iN65BgMQKHapVn8GwRZ0R8jjXiFBiBCgzm
#RA1NxaYiKDMkFHdUu23wKikdQfIKUhZ1SpfW7p1ERRKtgiJiUouNljF0EVAbrgasEi4ISoio1bnWQqmxghDnC7BMBqUbQxBHD4e0
#4HrUsmRSCyXkheq9JLESNYY8K0UtZKwxqn2uuLlQdSKp5oobKfcWUgtslmrNiEY03qCGVXmYjJhN50pXbNNRiE7RuMeqrWaBAIvZ
#kZ7M62HjpYWxmpW263mQjZohLvBC+UZIsBTdlqesC0Vaz1cvy0KXObSpxBS194veqahdsAXoSFuhxuPD2fPyVCdYW5x0l3xpNbOh
#zGYRkXBSSu2IEalI3kCyI8SlrUbN82nvi3JrLO4SRzm0O82yUikdjFS+QCoKV40fZhT5Wll0vpY50SrqUe/NJcB3iE3Ay6qGKrL6
#aoEp0WTFnedyPVWWk1wtmMO0TMUyIKVagx047RI7IDKNEqOQA6CSOFYkcdTluZXyBvqjSjJLBkA2vXWcjqpiDgMVCKXCEQyjKiBI
#ivcyTLcQBkZCHimCE4IDjw4vqf1OwhkQHjYqgEJcCdJ7In9caqdaM9JS3DtN5UGgW0XBWGLgxJ0I/EDyDWIuh6/jcl9U8SyHCEBS
#TYciIjOBirwkpMDdiAsCuLpyU4qdKADy5H+byKjpbH3ldkJ4maiyaWcJqdLdsNNBFo+UeAmdhk7q6DPS2pPUhFqzEayGROwRnJ/S
#czJ3brWYNKDM88Z8yytvSy4qMykxDUHCn5QNR6XvUe0kLI3GaRmY4DZyLUG8JTOILWInSehZ03GrTcnYO62PC1tAzwNKgGC1qZaW
#mOdALrTIv7HDTOu9uCRTMoXCqlYorMkVCqtcoZCBTcAQKWwtAFnJlZ0UJ8KoVxvjd5qVjJ9IH09cMWbxjVA/V1HVkF4MQbFDxMFG
#eQ6tRaKEowFq2RuA1A24dgcuSmZQl9c1CJUxcJoSbfiZBdyOUgOwy9ckEuWKuChvFA43NYbCQv4NfNXHe8QTGwrkh63Q2o/iGJbq
#/7qz9f5v+JGd/1fElgeQbWlC4vJivqP28//MFovdpjj/z26xZv3v/L//xE8uWmumMhQs5fN0xbFYxJ2ZWVFRYaqwmcJRP5SFMWei
#FjqmPMBV9AlX5umMSElh8C8r+afLzwVRywj3dEyV+AGTfp4O2ggn5ApfoqitzaVjIPM0TyecMabLzM/1C5eAtHUM2fmAGpDDxMQL
#RqHfxAWwKb1sJE+HjQs0IDjYgvHl6YY5s0xOZPaaLL2zzEyWUJkMX2Dg1jCj9FHWwCg9N4x8NKr6IE/iu8MSH2VNEk/C3DL9MD9p
#TuTAsguZEwK/yzXW6HChT+gD+ou+M+ZBcAV/cLjE9wlnezCSQZenE2u/WfQS/EXwYqGA8MBodRis2Qz8McJfixX/tdgMFiv8hi/C
#PdISNcDt0C3UAv5as/EQEOrk/48t/zf/yPg/NtRNcI7dRX1H7fzfYnFmWZTnv2Y5Hf/j//+Jn9w0X9gbq4pwDCx7fkou/GHgTKg8
#HVeqgwsc60N/oBQjgyxkpC4iNl4WKzK6dOJlOGA7TwciApQxHSP4p/N0hKv5OKRWCCzOwMC2UDjDDzOiPIuBEZ+DBO48vLEQOo4F
#YkEuv+9oKzOaHDswNMDH3Ayc3M3gM7qjvIEZAZUVr2NDkRwGzpVmbsWH2fYvvGl0bibpQDZCZLh4o4EIaI/UIPvg8wwYvA22rxDZ
#HR2LBko4xiqcecCb0Cg4JkLey5CTzxnwLMSKOcZbFsWbDUNsxAAXShnQjNFEUUN0NxjwlpgkWEWi4QgXjSEhGfa7AfA0uDgPWLGI
#2aubwo1bYBpUe3Gymg/g+csbXxgoNXu/uKA0MLhGJgC0diDSqxmrCMSwDcNGfdQYBBeBAjmjYU84xlPNMK8zMEVhOJwJGpP5MLAk
#eTrEFNEbsQWSGfT1nMqjaebHdQX48cqYzs1gbYlH6hI+M5UFdUlnYHQF/igbKUb3J6LWeHlR03GcZzSsK7qPVxBdkoCLrgVK4TDx
#MtaP7yCqqzYw1NMDeo8cAfdQyxAbKO1fila2SvGGkWUcj9eCesUgZHP6wsxgAkgW1lNYg17QjPV6uUiM8/Uu5SsQybnpVwrXUCtx
#tn1hAZghYbweaKGqxNNAcGFSWLjRuEJPBVIpEPsoK/UWqzEAmiEIloK6WBUuMzHjw2WoA9RfkA+jO5EqQk9CE28YrWSpz8DgquNw
#B3ESLghYCG34cJAD/IAbfjRnJgM+zWBKuCo9flWE5WOoRcykq5ZDtFZoFQUEsk7AC80K6V5wDQ7y4mMYWy8AiMPFefCI3ZFTpzBI
#isNhRDVDE32bCDkGeNSI5cuQXcwURcMhAFri/JVYmIGvwhDhAG4BwMEwPOCPclypgakCZ1YFE44ycBGBuUqAOR8JowcYfzgsLUoA
#lhZfRALAy9UJbuOK0RO+MMczUG4xysbgOC2WYEnDUG6M2B8CQzGaQgiwLhbAhQQ4mDecdkzASUBQFvGh5ryEECb8/jIeylWWeYww
#PqkNKMXhCBMuQvjBM047Hj0DFSMMACQWA4Ocbx7l/IhfcgC+CLJ0AjwXrGKEoCt+jK8joAJAE2hEGFmJQxYWYjBmhhdCk+FQhEPM
#AM6qY8YhhEEQQow8CoP3okujy6JFBqYfhwyHEBtDLwf0KCorFd7Nl8ElnpkQDnkCHNMfCeQIesrHISwFlxLAqAIPWuDcGBqEYZuY
#mxDGAqChL4bUyUYNPEh8E0JBIAMM5WHl0DOEshEr5zECVrCldSPLfkCSpRwHPAatCiklDP1yHLX0/AVA78awITHSABSn8CAeZ2LG
#kM4xqYUrEJ2AO08QTQDEYtQ+HK1CaBLwY/mEmQMLczMCduJyRW4sR5g0PxeDryKbEnkm0Az0iAOjAs/zcRgpMZOBVL8I4vl1AlFf
#jEM8iyAfqmKK2PJwFAkbivYuBDrjOSSoR8A5LmTgoCRjkqbYvokZILyMoAYMwQdTlbEpmKfIc4TTIJMiSAgmPAn9h0xHLI7lQhxa
#cCT7hZLkov9A3paUTicHmlON4WhzaImQuARRNjJ/weOlY4qjXFGeTsMRphM0gkAIrQcYtD0rQ8G69xApVfSAL4DLHBnalmxrJfon
#7w1UD4RJYUSdxvP1LHsQMadgmPWp2ofhlHgvPg3dGIHT0IXD4bMUh8PrEDPI00FzccTwOVO4542GeZ6cOFL3t9Z2Nr39orweZyXx
#xRwXU44A3zF5eZ5S7vioN9GgHLG5cDQTXM2cKRQoNU1F+qEPHNP5FPppPYmWSLtxpmAswU4QeLbcLzrBKBeYGXw8aGwIdsoAOoIB
#bFkgudzChoX8XL4q5AkHmYAvT1daiYtD0f64bDMD/ywu/E+XzIkmGCl9CfHIvU6O/wc9aXWZE3jS7KInzU48aXbRk2avvydNDuN/
#gzsNI4LoV8tloSgfj94Ah4+L6N8NbASEmmyMNQYsLoRFpWw5Pp5clz8a/QaeK3DD3EwW9QLRQqEfhNeIWBgmF9KdhGtISxKwEie5
#IqhB/9AKtZNGgMPsEgXKHxBNHaTEhTA6l/s10RwpauIcRDQXfYi5HvAE5EJOWL5g3uPPuZmefDwLPBpqJvgUbB0mGfRxFOo9E93F
#c8tEk8MfAFC4BYYYagF/8R0II4OME6ArBJZVky76r5g1XKKXG4ZqCnJ+Fkmp68CmypEseZPaJEOKDwtI7ePg1aAPj2WD2HqPRoRc
#OKQSIZ2HATBA81IwG4oQwgeQIu0j2g9+xiQMjwwLZ8xR8BiAYYomzIrwIjkJxkBpUVinmgC+p8sfKKnKMGHqWbBp1U/hq/lgyiEs
#hy+Kp4rYaeqH4GI+MrJxWwk7MgkSAFPHmCPHLmRZitiFP0bDwM9BPJTxErLlloYFyZAbkVi+mF9uj1Tq8hOABRWXZ4aw5exo/AgC
#ZgRGE07IFkGoZBJH3UXy/8njf1hoX6SeEz/g5c1yOJLF//Bnhf/XYrE1YhwXfSQaP/+f+3811l9DVXQqdLX6vaN2/7/VZs9SrL8V
#IYDzf/7//8RPxfAB1kaN4dP1rkaXw98pHRo1uu4zck3906my8/aCLrMqm09pNNvQtkXKJ7mvW1rdeWujxs4m3ZvOjTVjLpllvXRu
#y87XjGz6/XN7G485nLewz5TPG3U98li7/j99uevbZ68IppzdujhloTH61YYr8+6udHSy3Tn55bvKK5tX/ziyxYHLVv/xbK8+3se+
#OPPHuR/+rOCfqb5l8oRDa15qcd+Bh18vTxtZ/Yur1aQOza8IRr4e+0mvgXb/Jr8lrbDTK+lpLVft7pva6sl2++4s6d+uh6fw93O3
#PlaxetW6VvvP2S4/ubNX6lF75N4Og5/Mvu+BlcMmr7i8Ys6Oe3+Y99Efj6Uejo2++6F/OWZ3H2AovNPeuG3PefNmlpRcevmNby9b
#teLwHP2WgiFZ8/+x37ampuTdJQcf++uHwvgT+9K7prV9KHCibdXV7mH2+W0ObWr3bfCNNxenbT9179KlffPP3Ls0bectf2u+uO/0
#M5bNv+4YkrlkeHzcxhU17dvtK7BeeWjFkO9O7T834+Ue/yo1Hb/0WfuMO1Pn3z9g3fFLc//+U+fB/ayzBv1j1hP5gw+tH8yO6nzu
#hnHL397+yYZDy47ucXdt2nw+16KxzV9e/NVD33f96a9fezYt4XTX1MxzbOLfa1ww9XEm7fgyM7/YNaiLb9u58IRNV04dfWzXipt7
#mj1n/KOKijZt+XL68yfuvfnjAUfWtJ9/vIure5stK999srLFliHev/K3LDjV9MHm/KKt9vVLt5257fTRU//Mn/3Bpw8Y0t5Y0qp3
#vy+bd1w/qFO/HZ++8J05t01gygcnW54Lt4xcesy+Z0HrpilNx3aIdWyz+5Lj15l67LZzT49YM+Hdmsmfrr76yyGl9yz4vdOZZ1LP
#5n4/c+6BK/efCzd75P5g5z92fDWm4zH+trbe5nP3DivMH5R6+0/hKYP2lY2bteuXLHPG+t8/2bg8rX3ey3e+nTp2VOFHacdSRzQ7
#eJg99XLLOz48nZV+ZMv4tc2vdTTaPatDx7QNL2aMWnK2KL/ZhNfGXd1rZpPtmU/2n+V5+9X51z86fU7KJp9v90mmT8GUm74++PGf
#Rxd/1aL3d+2Xlg5k7/7xrOfbyX9ue3j5e/c8s3na6YppNS+2+8hqetXBn33xxQfvKjk2dZv+5vRxryzse8WsxT/lljLv35NzcFO5
#+YVrd3c3jznz1bEfBk4+WfLV6Y8e7nz20z8svVb+lGVzru7cy2/aty57yc9Vjf48OiMQeuGtB8Zn9Sx6Z+c1nR+zVY+e2i7243D2
#91e36jvZn3xn+OtPvTD86OjJ1o3dHlpWlTtj6KO7s12FO2e8UbTn1df0o7Zu6sTsv/Z9Nvz7jjbpH592rD+39uWf5i6ayD9WUflg
#xpq8B2/8ZfFLpcMrYqPfj42/mqkYGz/51JY1U/qlHxpac+DlPzc8edNN42cvPFlZfXLy3h49n75pNndDmmXpPWd+WbHj7UMf7X9m
#6BfP/nFwbouKneXGT0/ov3Asdm1ocdVmfZvnB/c/tOCF3jve6rl96qI7/z6jS6zyvcihWa1WXl8cG7L9zROHLTnG8tbP91xf1H/h
#h2/vOjLhubvvO/nwwB8HH572z0ndev554r02+//i8/gu377Llrcp6aA//PMTeTVns5+Ns0tbjHnq9TEtPh+13ppjjDbp+q+zy7/9
#7ZMN9qPTpsxdsWLz4YIZtv1pnfvc2umR6x6JPHhJ9tVPTjqwqMn8L+57bH/XV7vUTG935O0PM1pVtjy+pKOtfU3Bgs93Ddr8sPPB
#Z/d9dAUfPzB38sv840On3NO6643zvjTrZ7UdcH/86umDrzsy+EjZb3O6r/3bsgn5XW7hT/T1B6/LervGeabD36Y1cl0xrHn/tW+W
#TNyUveQG7rbOu3fdc73/8i+C81b+0v/V/Zva/3bgyqnjA5seTvloXmRN29ltF1ySM7Tji03Si5uExi9IWZE797WKAev/nFn1zA+n
#2W13NMpbGv9g/S7Pr0NviDyxZdIl7ScFJt5a1rXrpQ8/0XPCkBlf32zcuPfVoROCq3MO39u+5srHUwffwy+/7zpr03WP39/T8vze
#Hv0PZm7enfLAx+5Or525xrdO92PndevuaPFj5+c+bbv3kcibHf0r+E/63zlnwa4DLboYcv8Y9N6qZl8MLBrNpx9b2WzHVb0rfHse
#7rWyUf+WY3S/jXszdU+jK3WdBi5w5bYcNfn+lNeW/rwvd/zzp0/07D5yz+ZVQzLmT31t9OruU5eu+a3b3Y5iduWwzz60PXn5pMdL
#zUcWnthmDv454rKmd22+xXLNSMPeq07MemWF2/rZgrOL02Z3XDflrdlzzW22b3J2HHlr98KVO578Zjp701/uG+1Pbdc/0OeKOWM2
#D7p+yZCv//ggdUrjlR88NPnqAVsfPZ66+7uZg4dlF75d+Oyj9i3Ms47MZ7as26JbO9x919KamOvuOasmzPtxpHPk7GPHH9r987Ev
#ynPDj3U4fk+Psc4nU+wrTv4x+JszTxwoXGhZFs9eNOzR9gUDTUPGDe808sjq4w8v22EMbAqYT666+eacwIf9HVOn3jl/1+2XeAN3
#3fTC7MV3HNz69bTs7/n2hqG7vVcdvGvb59d82nXFod+s5i+K/3q+B7+4pvLo05NLtm82Xj53Umx60ferxsZnO14o7LNnw23jmy9a
#b5j/yFsPnHn3+alfLH/d/EXoR/e1t3T4vNXnY/r3btFWVzAvtW0Ha4djZlsf89D3Dg7d1+Lo2DGG0Lrn+t1x1Q1PFOpeS6nZN+Dp
#Zc8ee2X36zvcKUfXp5wc/NPB9t+9Uj64b+9Lpp7rnrbq2KpNqatbzlw78uP9hQf7v3jZad/8zL3LTt3eZpz9jT2bC9elpF3bJaX5
#0MIWU7rN4hYVDHqjyZmlry1q8dxtvxZe1TJUccWS5z3v2n5K3/HulfuWbrB8fee2XxYsHDLy9bSfyxbvjroml+g6dBsVH/jV2naZ
#uZtff2mG/63pn3N3FzXfubPHx9eebDS6xYihi1I3Pv33DY2mZo994dLVh8yj35l/Rdeve94e+Cz9vUXBv9e4KibcVRSoib5zc6+1
#R3K4qce/dc75ZFWgvMebjgGTrgnlfzT5vha+D00p7R6/dttkV+ZLzQ+4Hui5deHJHsMWv3fyp2sX/XzSu2p1ydPvbNv6fOqN88K/
#NXo/1TPu14d/zvWvPfrj1o2LT6Xe0Drc7eq8zbett/zz3ZKbBn+ftr11gC9I2TN+L7drYnCtc+3YR77555vLHsjeZn24T1lhs/er
#PtrpnXb18kWW487rH7zdUb7mmcsPPvndxoML3ruy6po2/7zxyHUd93b47GhJzkN9XvtmkeG9P8fMnPrrwdf+9oppUEXJ9hdXDRv1
#0ktbWx76fue47m/2Gt/sDkdk9h2zHurcuesd+im3proMp06t/PnyPilNZs7sy9y+54qUlpfNem7f1EfmHzlkfSb40wdpc2d3aR+9
#bvfsuR3yt54K3taqh/eh5enWiZ34J8zDL28/b+uIHn8+b2F6Dlz/fcpzW7/9+f4jw95/ZOJNRS9MdnW89Pj0cIfGVzVd3SHn+lk1
#M//17ZDDR/J+Hm5Z9d0XQw3BLk94PlpSeHbcDW13fdz/ldDQP5fyR3cVfbj56KyF5050PHVt0Y4fJk5m+548ZX3jRNEAvt/Gfy3v
#czw1v8kv7/aacbb1gElzXhy8wHfrCzf3GVuc0mnCokdc/GcDrr99sn114fwl3W+4t8ewtPuGtJ6wpWbnwp1HS39fu/frjVu8Nzf7
#/N57b+/RfdLyRro3ws8cHvDL1F06798nzixs1vfwHbsm9PZ1mN/km/zPjvuPTLvs+vmHtozydUy5zLy7Secub31WU9IhdQhb4NKl
#zs/o16396RmeFd27d0uvedZ8YMD2e5mZg9vGxhccamLRPdXFszNr/Tc1vzZuVJCRMaDlkJFzomMWfPrpsplnXrQ82rrxAn/jFYfb
#zbvJb+r57ri7/3Fw0OE56ybWbG5XVrzq9TYHCloNdO3uaLrqw35s48/mFXRflfrMDf02Djl9R7/uaR31M6atueL+VZedeOpU5xr7
#yo7GgcFn3jmyeUN2q7Uf7GjbunHzZVNmtl7UrlVr/NO1CelgYeGebm0HDxow5IGR10+8euuI2NhxB4pHji6wTXiqbGF5bNXd07/8
#aGIXg8eyv8u6mRtG25r4slP2MNDV2z1bZbzzvvVw4Nn3P23ZdPOPe0dl9HNUsS/UeDbtPLb89d1n73OsvDF2jXO3Z8b6XVds6FsZ
#u8dTeMvXrXZ/8MrZ9I1/MXOe3/lz+9EPfahre8mZxc3HfG9t1jb/hiZ57zw67/TUEWsnz266/5OBzUY+98TweSMuazu32VUrV2a8
#dHmfhdeWtp7T8v30a64eMKfR99Nm7+68fuP7usPVs377q/fsfcs7NW2xufmGgsJXFn+im7TmuQXj3pp7JH6kQyvPr4t7Be4xjrV8
#7JkzeNOve8ba9nU4vXz2iHaH3/3xXv/9+4Iffjudn7dt2YNvhd9psmb2gcYFwRuazDxWkDbvqde/PDZ3yaR1s986duSW3648Nb9F
#kxtPTvth48SR/4edd4oVB+b/NI9t27Zt27Zt27Zt27Zt2/4d22ff/0yym2x252I2O1fzSZPetL1qm36Tp4+XzRS8Egod/3unvNl7
#4BMoJRV/Ab2s5CMw9f4qSdxW6ECex4GGR1ghTtw/fYChgf6bWiPqjNsWQxCU+fPJn49OjJO4JgRRhlILLCD0DX7QcaSzXrIHmPd4
#+YaeGkhsoNNYH4OEKEnGFh0Kh38iAixpW1ow6KVv9edXgZMBBJWE8btBKPQhxJiEnt+4DuI0GievkYw+KbZh7Rp5x6jZeR5sQUkp
#GNtrAJ2cexB7BdbmghLM+tM2zrPigKcBsOCVQ71qQIDd1Yhbk0rimlB8DPP06XlhgcG6hG3vnc4pSER4WnxCcxTs8TmhGHdywkF9
#1d1B6fo87EujmA3g97In1YPL56SfgxQdjZD5HFYg2/kv3WELVgK/VwQSwYKLpxMQURmw+2/lIYSGA5h4QC+cp8qR6kxXlxp/V/zB
#DkDmh1XWSFpS05aktYW9lry4ou0L4ShSo1KjVqUalh+X+DmCTyXtw5kepL12XfDvQDmcC0Fthabl5cXA/iWX7PdgAapQHFwrlRcl
#f94OFqDh+ni3QAeH3Min/Dk5GhyJv8C8hn9/pWim0jpP9/7nAIA8YD2XWhsAHwTaMVTkucM5E1x/++N4+hw2O/q/zGcZx3AfewHM
#n7iNy3T9n5v0rx/ogdHiAiNRrNhtJ9eLKSorOx73J6Lj2gECXoJBuU4rlv5dB7EIYoxHJBKpZLphNJxOp9QKJUqtWK1XrBarZbrh
#duQ7bkt3fS3rqPvvU+23Gfdbqr50H8Oa6z2uw/Zqmjehf7j3S1LLum2bYNrX4yJFDYwNDveaSM0EhuJWSJiE4HIsLTocn4nM/nw+
#H4wO6uRCFQyKQ6JRaNSl/T+1ssybKMqj1CplGpFQpX5KdaLFZLNcqpdHUyd53TN5mIxXRYTDYIQVf3OAOAAf2BxA5P6g5vlA25kF
#9sAoF06rKlDhBCoM5wcwdriwsZuJ7YyLna4dzLVHN4wNxkYxsrctj1YnECt7HaMgnBAs8H2Lwop7j8uMRpnEuu26FC5rU2EaQdKh
#hygjuTjjamShXxg72AuiY2JxYO6Ol1xp4//Octxbu1XSesO/rwUGUg+EVNcGv7oovPbSKUbVT2nxfXARfrc6tO0G3vDA/EfXTXef
#svc473xP6+w+ded0KX09TqIW/P/p9Xoy1ofc3Ix8L3c2+mpH7bmRd8fcgMxkOB+ZQ5Cip7Tqrf+z4zwXuniBYxBL6Pmee1tj9a+n
#wd/tCEPuQ+rpMHdFdh9Au/3Exgb2GvDJ1rPFfMnoBF4BOXJgauPLK7CjRpeLPtibkC4puIBr+BZEDX06ZkCxb7ugGW+qJYIltrwg
#4wHLJedOOG07hcwzzpo1GRRS0z666iBlzgo6pdIHxFay7S0VLzt0SZwXfi02/9Dm1T/WRIYMrBKNzs5bfUNkNpAKrm77VGuiQg/f
#Mal9xYbGdCOUQ8wuSTyFAs8Io97qtiKVxZkOmuhsidUH4LpB3Qz3j8F7NUBn23B5zp/u6kaK5+b7Nx3EmWhZUM51HBUnAURmOInE
#dRtBb69OqHK50Wv2KId8OSSRPAYPIjeh0BKVo8JcQMCUZE7DOHrKGMYi5LWH1iPq0CCEk0oRogdlTO9QfrdAWLKDI8Fy9eE0op5z
#P2WAC153EbNU0KiaQNsgObKpYTjmIfazPCfoR5PaxlW4eZRSiCzphBuH2CzU1IYJW4aJnSKWliyjoFC7gLTNksIfKZECShpYXvYN
#K5X3eXbkK+s2rL/Z3CFjQZHGCwpTs0nYjZk7DkU4jL7OR7vSz/jDDjBZP8BoPQlHzP+aUngaGWMBkQoTS/KCrl4kL3SnUq+WcVEF
#kuQelyApYiSjSOlpBQSxqhES1qNcD6oetvT+nU7uZIYhljoJjjU27FNKr7W2NJkwwgGsnJCGShksaJZ65O4yNSaX2jjOhYORQKAE
#wa92fS9wxFAIbolEmvwDXOLyccxQohVgMDDoBAZtaOdFwmJexAA8+YEtW2x8issFMK4iaRgpWTZGL7dFIiS4rbK8JxQXk0XyYkUK
#FWjleVi1iXcK6HUVXWYRhCdIGL2ecbNQ4tj3+/fN/538s32lfeYHFaU1DTZauZnns+2q5FR6GcOSA3ZLggy06D+RBKN6ggf4vlb2
#WeI9SzGCPSXXFPZgFDdncWJZc3slIVMLNxHLrgYxTIn5y+YnVC8pBUT5Sa+NpNOKtN7MR3lUkdQdV4jypZee7QOMA+wY8TTeQUok
#PyYQDifus1z8SP5d86txPDuC1xT0gLwfQ2ZMc3dF1lGVs9W0gMSVHM9gHUENxB7L6RKLVBvYnw0zLUWZhjCLjXIcetyxq/ZGyxsv
#ufLKclsWQU8VIjEXrYkW3ScNpLI3gRXaI0QjA6HMjixkooni3CBSzihv81FWhGKpoprX4LgU0pUhuiTzt/Ndl4Ga6rSpgjJX3WaR
#LEIrxGdY/LrS5IQQptM93IAhGZ4bJSLtDf6WSdqA722FliSBX1RmjmHRBHhHEs291F7hu3ROi+StjyZSfyAXWBEHlxBw+PgeJdcH
#QUwd0jzkgYJgIJHS9hjItomEomOpo3ClBdpQ5Fi+NYVVDrpA6TB9XVQWAyOqapyxFvOehmUU15v7CNlf3D6GfxERV0lM8R3zj5FH
#GS+Uvoe5UbAnMXVcsVegKvmlwuIpb45XuGURRR5vMa7TRG0+r+mxwnAkaTIoeXOEKmovpq2SRE4DY5tDgpoOEUfUbGhwGwnkEsnf
#o8WOy6lMXCMG9y5vRT33c4UDtDSjw2amT/HJvokWEJzt05/cggnEGUjRChZnaOGKgowzTKxGbiVcC/OQZnOK/0jdrIAWZY0DJcLw
#zTNcMVKAQSdjAdLyEoFXKdh1QhUtSys1aqiQk2JiOgmpAvEP5F7AVjuwtRyNHGWQ3/B8z33IUboa1G169YAp1FR+Bgy//SN7G7F3
#uvo7KQ52jyJCGGzQ40YWtNJCYCV6mb9afjbKgVxx3vi4jCYGtNK7ftLFt1/IkY7+Tulh6cPU5lwXsn768y/hjnDrc8gqNXsWLIze
#zmmNI3vEZ4whlzK8bfwJvOKDBKH0yT0Sp9b4lxRYLMLSmppcYncco4yyJD4VaS9pnbsindSqjABJlg8MW+1WW3uCtr03p7vnlyAj
#TIanOZHwN2HNrOhAEgXxdByBQZyW15nPOaV7Qs93Xab1nGkmpYMyJjwThz0TsLT7Dmo4U4krVfcSf4LkQ9S883wnuGeKOyyd2XpO
#Puuf4NIvDfKDhOz0MT7n6PZVI88RDqUyLt0xT5NKDmiUfc7fFe++sD7n/pWj+MsaNb4w4FckcIIiTgLW8dVIM07tPNas5/c0Rm3z
#YsOS+EPaa78+qMaNLGylZYMi7BCd/oKXoLEN8It1SjfpTwAau8TuF+VKlNNwVwa5zDVf2hMmS/w2AlS1AY+MqMfdB9wc+QygNJFp
#01TUoRqS2IkTkddjt+nPO7Izs+DPNMJYc76Q/OljCyaOG+x0oENJc6ilXkNqBXrRDkQoUYopdDmeAswqdGFYRVkPRoenq/LkfVJ+
#E0aEH0/gQ/ZfbvKaFhncu76fwxo0dX3ZcWo2YDe9tvOnq74z2x1g/gSv9uOB0bAUXd+vS/Cb+1+SXuvb6WD5lbst+Melo1i65t7N
#R0PndwU4mK/X+eU6EN0pQfIpMPhhrca3vcaDPIPu+YKpm7IUm+Q3jSLKp0yhaKfkZJVzuIvlZPKt29gvtG4oigr9Q3koyocoVfKk
#lssL/V/eUo/gRQvbjTvmaVHNy9uyda0qlWAEBBcD6SWIoAwRxH452Tq1OmDcnYMgx9ywA36ORHE51xUuPyNrqlz23HMg6uITrym1
#AxG09YsVQU5GCPK6aCLwJXeoZWXlrTCZ7ppUasfUyxSof4iYdRXiI3XFzfyfHk7q5PpDcInlMh8Xq/tjy3JwietYzAjpNd64J3jI
#cbLjUDrJXDHKbOBCo1rhJEuFdwGLu3wdSpT6heynTvHDwEzT72Ns2WcqC8zFhHBKvBp10+f8fma3Iil3/NvRi66sCkUvPAn1tG69
#DlwuWkj7ZSXWbFlPD6gLINPJmWwB4RbCaYxrk2VIhJ9wcJNx3ZnOywRhs7AQcdQWWGNNJmovwFjpuiEr+vmtHfeW7e0j2bEwVsl0
#nbsFgtuJuVWLswnkfPVd6QJRF8BpB9NsKFbkIooOY0rtuv2tR1tegxQMWpC3w5PMK7obPvhBvTIFq5mAvFBop9SdDFIwfX3fgy3z
#l+XChTg6dF980iJcZTzx5C0wsJffuav3J/xFWrScuF6JyQ3TFAYUJBeOSnUyXWH/iallCj0u/tX7pGLVMq2UvE8zH3sNMXJJ4eyk
#vCPUTeqn8oSEcSFGK/CNMD+hi3y55LRGxCIIa2YYgXDN6HzzPvLeu0q66eq/frNyHzYvIax8k8ubuTyC2RGZ3ehiklWOIj1Q5/hB
#B6C/shGsizmHc/aqUiVRKrpQXIKCQoz8MnbMNu22bpm6vQmzLeDFE6QuANOzc/BF+0fYsGvagRuL3GmHc0bSPDhsmLuG8X+dIXzy
#9edTL6+PcUY08dnp6jCmpd2bu6fm/bke6nbbRvtKft/DmfQHxSTQXMzaln9LsZ1fy8xtkxdMm52hf8GMn45AcwrDc9d35m/MOGGL
#a6hvagvUzxl9AxZcNjnLspjQiG3f2AW60bWzvqkxixnwgtsoRA+Hk8CP3SQiBVSXKkpJ9mYQupqZHm4jPPr+ADd92lKnL0Dq61Uu
#JyIk2QRbOzZs8qzwuviQ+6t96g8vBy0OvV33BzLJ4YGT1E/KyRXBKjzCRCwYhakSnCUJ75BBCIMQldEqnSWBNgkzZXNKQmENlE9O
#YWdZPmECA9bMVcJx9ZZLCVlcZV/2XvX4osMGXEIxGY8K4IpJD6CZ7XX6drfYIX3BFitX/tMQmBkQa8NeR6H0iJ+4hZJ3EG7I3Wys
#uWaFCkwQ5PopsLH0wQ4utapOZoZ5iS16yO4r6ao0w14e0+xljadx4HFOaCESwyDN5ZvK9doIn18BZIVq0/WAlChj5X0zdsaDh1OZ
#UgzMLNzRB8ZPmXc+rLpyoVCljzFKkrq6d67C2SCAVZihx10yL566WUpbPL3TCl9DmE4fqBkftbWh5f1HYN9Jj70PQuae7n5s+mor
#xsNicoNRegglSKif7djbojfxdtOutIjYqZGoTh+u7w8Fb77BPP8ClgAFJS3yacgJCwXTEoi3w00g46/6B1kGDLFObsMU9JvtKQKm
#end0g8bDlRWxCmUIkIE4JZBLI9Mxh6tEGDo1CCKhYyGiv+y+jQU1PEA8Lh2TICx3BDxrU7WMO9KJauIqn2hnMfrYrsmcIdrcLPQI
#M8vFpPAw8EDzOEgy+iWG2i0xy2pbXOYqiTta15fGHnK653vjbI7A9MDd8HfNYWswKI7iZd+izbHIof6lVl3lUsFhv3mqG49+71FS
#YfSavzd5biw5ltMay6vrKUMYp8dxbhw1jteKqsTN8FzHV7XqgqbeIl2Cy086dTai0G3crHZklWqy6sECZ6DXTZCTa/h2k5KKp9oJ
#JLl6cH0Sqb++N/UXufTY5fdk/LiuodtAYRTa6Q2QBu0brvKrG9+9ZmjMzrPuPusOQKsdVv2banzfoKYbTBeo/yr7YlBnSIgSEWqT
#i9PXZpVArkwV1bajZ/hOT2mDNnX13HP1NM2Btkf20LaOr0hrP8X5NFsDt+17ISuHXoTCNn7SzUAEmJ4MrWCgvUhdkhAhA+cbD6CO
#pEqMSKv29DdSOleqxNJnrVJLkup4pM/1uFsdM7z56l5zv7EHV3QQ3mu2IZth+fyZgMLXMEONzmQ43h6H6tNxuHOiGVXIhU48EASB
#Pt762IPPvSrPlBeVmcyBL8+LKdygKa9toVMmD+KMbpuyr58D0ILBb2RgVM4wnupU0tpK0i9oe3ydNWxvydJSRsEsHshUqN4l2Qjp
#IxHuaqET7Gva/GV2UvVgmlDxlCp4unzIXcsdl9m+HYi2YGIdhMnf0qpUEdlF2Cuyu4CMT7sfBWLUJ7LIOXO8cXwUBk1C/RXRmlrp
#AT3QRMN51WvY3npb7+n7Gxrxf+La5RottwuvXejccqnZ0/K/dl3XrtX+eZfVQPaZx15DM5wkkRQutVzw+H1KNECct/j8U6d+dtP2
#69FrUr3s1dQE6mmlT5niBRXrWINWvjUjam+s1qx0bmUW7I5Jt3BrbVi1nafUYqZvuBDVlXUGvIcZfc2sYsfXdDy1D5CvDo881gw+
#NJGTM0WnN3a4KLiZTnOt0X1yeaFK/92LxRZst7Os0/0qLijQeZwHWhVgI5ADPlw5ffeQBA7tAKEsBibhFqpu6R/JPhbtuIcKNfJC
#skC2wNV6x0jRV3H5tdrNyt+XlsGxPsQfat23Y/gmSUfa/F3X2MRYdyKntvab9Bkf+ntaqrKK8Xf9d6ulspvx7gVvHXCe1rF79gSZ
#2y6i6eqqH4UxOFY8dsurrHNNRxWVi7lgBp9xbv8PZgYdDc0zQP1l4dADMuAUkRq1m6DtQPn1qn2LdMudkcdNaEjFMGd3jeMqjwAn
#LdnkrEVmCrsVU2I30U5TfALnm0hci1VRabQzAtheJFDIDtiAQfQQjk8eLHcb7SXm3XDPzyw65WGAdKUtkY0lv722Zbd9MOnGv6WF
#zetGHg4+AhOFi+Js412fxuAILFFrIP64GW1tNy+1IznokHxSg/umqDKot61RLeNa1yeq8GMNpxBh8Hv2hKh8GWgdVO5p8ENtEvgL
#BuKH/7KdsP5yJkG+ta0fvww96HwVM2nxr+O7OsfsvfxctYhITBcIdR2z+a8luPXfvpPlDEzGEf3U/R7ojyIaAfK6MWXk5nq3QWvE
#8cY9kgMw4DWvTMWD6r3iAo4Pgg9N/ghRnxNGUDzQGZdIUIMq/Gwsgg8KyzR40Cs8SRKP2iSCppLunNh/G02QD3F3MHxQ/Gs2TTB1
#RBB1LwwBW9cKzPVOYVBXfB3lid99TB6B/D5FBYIPOvsYOMFzKtwcHB9k9lFAzj7v/dEeAhTjBEYxlLIKwQeVFQx/gryIUFQjcq84
#cJ10eUUhlPHkHS0gV6lDkz5R6pSpkUdZ6w9jdDcVi8AnY6ct7q34i/4PDddvuIqVQYW8N+ity9p3deka5upPxerFyXWTgfAXt4Ho
#TwPfR6aYyxBtq3F3S5RJ47vzpst2VafWYLb84KW6t3LfteDzifROcH97FdBs7L4gQMH3whGGEwIC10gmljO8Vyj5b3QPPHyXDzke
#A8kPoUEv33jmA4zLDuy9Qddb8JMLQJ4GlAPyc6MmTIeBv1t6T9UZs3FfiC5ldrguEaCptAtqd5zWfteLk2PRC7Cv+LqpN/jXlzkd
#UF6bFH1m/raJ8TT4UfChAFSiixpHC/xRfvx0wufV+EuwlfwjuK4tgdjpr+EYSYBNdd31TXFa+8C0vz2vui+s0cmJ6LCAuvPEq1Ov
#ht7CNSkQbb42lbj05ypNbEoEV3lrbOwFk0SctVWhEBppJtB4p13sloKdIV1Yj7g//evk65HuI/cb6229K6jPYg+x35HtUmercqbY
#6Py0pEp8dfMwLGZE5APmqd3Z2fhUi7IJCgjIj+fXt36R/QyeDLgf+P1SdNm452HepQb+Dh/PXrutP5AXhuDA0nh3H2Nvcf9fYAxr
#uGTSzRLNh1vaJ9CrMR1HYI5rzLFJhsV+Bi9pBuWWkqAA9s1UZPYSNJLCj8qA7a8pjI05mAURlY/9YMTN+cZlrgnA1mSDQs/bMyPW
#gtls+n0+A9LMfkV+dZSBIOrHs4E8rBNXuxFnHH9uu8HhIpnsO8ijONhjHPH1GA3Bw+lx6Dg4zIVUhV8XWE/OuQYt5iQXFvkhH4MZ
#NnyrALHPSXn5AbzkVb+BuQ2ceNlRfiqXq38cczqj9c3LGEMF+iz0yfeIm4OBPM5wyjTv4+ST+5tRxvVxBjD6bA7W1oR9CcxhgRJZ
#F+VbvzPMxvKYf9WH+BTb00RzOhW2RFOosRYq+dcR35FIAn3GpK2gRI8g2ZwxrN6xqOmxXp0z7sGRf90ezga3DMS+NVkC9l/oYniW
#iXP2PN4l6oVRgM4IRR+HqwohhSOc6h2eXRUXrot3zi/3gTndJhBHsjSB+Tvd8ciaezT+toL4tZFDfwxMqTy687Y+hzTsMaJ1Qlp7
#Jw+vbpL5mtBJc7MYCGdh04R2QrMunCd0kFNzzB8JSNIcohSVSk4vihrvSNIzcbFfSX6HlxC8GnWiMPicYjxhS2Fut88fI/6EUewc
#XRSN+TljtcxgJLzsmbLQgCBKmELJQywsDEcdDhytCeA7T5Ipw9H1ngHMPn+wI2FbKuSfgVLIziCKON/IHfN9X9o1+8LTBDv1YomT
#HG2x07oM66fumrXSoDBUsUiiTJSKtRKJaiYaqcyOCYVytVKIF6uUrGJZJF7Y5b+Fno4nni9BC1rNTqLaw86rTJWq5aCzCloLXX65
#Qfg8CUWkhSAjYt7KBa467ZJIhbLZxmWUSsvgOZoSVJmglDhy0OeUTiFN/M7HyqyVaqD0BQ4eXjbThGx/Mcz4bFmtwqXsFqo0n0iv
#Vh4JPkLqw1IbtQVTdtRuZHuXIMx5N9vljyI4AmCMnOB6n8oNQ9I4DUHZ4pQ13bipvcexvgGp9unx3zX3vvOxXPF7nJ5GJy7+d8XQ
#/FqXFcY9PB5H1jv6AXq/3tF+Xkx3I+BmA0X5lp9j9Upl63ALsRejHeRqwWSz2KMR6YQLd9qtFutUFDoS6Uj0EqllQt1yO96u53+u
#OmHhTLJso0LKssvmYZll00m04nVfdBPMV0m1bY0Ehh8kRl8oO3+OhQjAjIjQjYjgjojwD4kAkMRRGwXnjREj0PTGmNUa42ERAbid
#wRDclLDvMz48KI0KODofUKEQxDG1yHJR9530OU5bmOY37gMNiCRuJWcYQxMkzrXRMPvE8bnCyg3tWom6Q4zG6JyoaaBnmjaJpGbj
#fC1A7kURTFUcIriyLY4xyjnHSOrSlYsw8waUEYegPWHnIVrFSo6qJaEPlIzn4OH3xB2i6nZwkGgy7Uwij6YVMMmIPyBfoODRRKYS
#wUTEJiLqI6vLw+8YiFvLRmV7Vg9JPXz25hbphK97FPuDvntjjY6jTvpo9Ivo4M78uuvfWNQmXhnwZtDsTaRreVL9jIbxb9kirx79
#ykWyr0yJGEIt2PwaDTYi83+clbdTUQ95GA+RfSw7jhG+Ae95Mn6IH85jC32eaNKEYdoS7K+EtDPZ1Ff2/+sIvf9/8//Af/6PPu2w
#/s+AoP9j/pOVmZXl/85/MjOy/G//w/+S/F/8p7oBAOJ/9ePXAABq3/+v/GcgF3aDDU6k238BoGgQgQSQOaiIEFBBiQyB/xChQ0j+
#OwgaIfJfICgUeCQATKAatm8j+AYbbNb+DUCP1E6+YDMw6wUc3DRUpYsZgQNeQUJXfNLB319NCdPYb+A2fBFFaiqiBFkhxIcKg860
#xKvvc7FrnrPe5ZatIXVar0CP+7fjsnmoQDoB5Ca0HMb2aYeM30ILDy8v76UIlnWTElHStkefh+6BORKh5goOdJEG7l7NKgS4YhYI
#3j9mpBaCw/7pcIvnHBFCTWr9d0Fccq62dqgYXTPiNckqvTz/x7uHdT5n/CQfCQopVYO/3Um6qYCnJw7zux8S2SupQCI1bGpRLRHw
#PccmzrPc6JytkZcZzCLOnz+dpD/rRAgSCQJPI5AIzklyORB4IzUrqVlzVMeuWuzdio2dLbu9yjbqF/7X++xe+QUSNGHmVnzQ4G+r
#pijC6NIMm0Gck5K/deGgbkABkPWtzk+JAiLoghqg4nAE26rmP9iUEoASpJobtAJDLOvKi+sWtlQ4+t49Sv9ptykRezeCLUNMyoC/
#WkZbrV/6iQ/ZjSAm4QRWquRJ1Y3EBo+8EC8qgo3+riVsCioCULEPQ35uAXA4y0uE5+AlJUV9xepqMb68FkvJp9w21A2cMWChYUaW
#2F09LcGAuGEDKSeBs1DwACTf3+zqO74BmAgSYLQgniKzoMoh6sU6OcOrfCclPbk9Gi+37Fv8dn4AuLev0X0iVKfCJa7ZnTP5azJ2
#Yivbvi8acjRBYaZSpte/1m/V1d43SfeDbkKiyXTIYDYkGpi1HsEws1B6ZyzIbtbrgIoxl3wCyUlfQA3k35XXkFqGsJjaJcuCjO2n
#mNAeC1jsjrU67CTDVlssEQQwIxYgluzrrX+7r7vXBIE0FgwJlA9CWr97KtXPP3ZJQBxZuk60rd5hXNKxrzHyl3MYyLZIrv1/2LZ+
#7DLsFICwmE2EwkJatBIxhZpXCwAlgAJXUEzuog848/X/KdkcWgg4w8x41q3Xxc1rYmtg2SHJY+l7CWTJIui4//p/qGx3/bvd2A+h
#HOkLrA7bhqmAq3yLxOXX8b185Wnv9+EW9W9zGWDeGxisdbwgVQJO8hQNQWlY8PCLj3wLmiZtlhXhy7RDRTG2xxc8V51HJWIGjWiF
#kCAFuhBmLy2Bds1HMdaXZdy++npG/m2M3+7SEEpADIJZgzcSMb15+L4YaxDX/vhSdHGPmcUPq1ImB6extf0ay/zQU57FPv+sYo02
#Ek11AMt1ntCjuoqBqgGeE/KH8/p0g2yAGFBWIGdGAoQCbEkeJLvjZgEgKQtrqVHI4JwcBPb0KETZUMjzqVSgUK2DX5UDWq2CuWLA
#wLKiYNmhsGyJjMiyI7bvht12gfPeA3j9o12JdCkBTQRABeMsIGBIXlc4KRAmOo04FX+6ACASBP4cBlPE8HNVsOihpsfDFOBB/y7e
#jdoA7v2hTYwKYx4kQuMGH9Q2Rf7sPIQutyEZpA44kBosspdjRZTDgi/XYEPjgrLY1g2quiVqSYOA1ZX+XTV3u0NvfSO3uxyHrTP4
#8NlvnBAnjFIMAxfDDljUMmiBwqAFF2MGFAMmyJPDvUDkMQlEtx8cAZlFRoD9CvUzAAxDxws7DCirwJRrdZ5g6Kzxe22xRYwve9HR
#ksTXWTprxdQyioBJZFO5sbStBVStRJmWeGKfoqyV3U8J4km0uPRN3EFKHuwCOPnjvclXc1+rf+tlW1UXNnSvv8Vf236x2q2idm3M
#i+JIjgvEdZjWbS1lm16r0tGLtoK7HVaUKH4eDLyqQmO9KaqjEnCEcjyzHcex0hvU0ZoGVYLwpVNivt2KUm9xuMwaeu4++R09vrOG
#a3XC/Z2gDaTHGhEP709+ezLTm4vVmWrmzFeG+XR28oPoPplAmOy7njgeEvPu6XNmZWkBj2TgXztxeklgpZ2R/9IdfidOryZothP0
#G/CCdna/aE8AHNjHXspH8oN+kj9Vv8dX/A1byNoncLkAtYYorpWMJ1wI8AfpR7qxv0dq65E9T7/9zpzO1vSfuT5feloFXFpMR4vu
#m60lQAfBKEbhrU2DMfe46Bp9nkfTmv8N/ejXtqzUZpxqU6BEx5Rw0W4KWz8B/LbziPXMVJnHlXJKO2RAc8DFpct9QS1s/SbyvVCE
#JJSKlKiU4y/HcENM+fu+VYo/tUuQh1AGuBMCEOVKA9QwwWhAlAeSJDkuz3D3iOfD9x0fnjX0zV4jL973ZCqRMEGnjYksk9XC8+im
#wXEMMFltBaxd5PyrnPlwVm0TQPZgtIP//gK2b/wzE7RMAHcSakyA1QB/hTawaeNxAC0MDe3hfvMxDD8a0GeZABw0TGuL4a9BdppA
#oGJpwAUWEfjDhOIVUXhMEVLFKkSWEwCp8FgoeJUGkYYFcUrmlRaK+Olze/6Bq6rHSuf54VkfeYQu5yOhN3AbAaNeGM0OfiFfLj+2
#enu/o5L5jpLn82k/gwcbS3yX6sr4l7eLMaOYa6hvz2UQt8Lg5/77MBjDLTMn7p9yXS2EdvAnLzJz/w1d3//00r7/8y3dyIqkRau4
#QqJp2d4aV+naHWUbXaw47JhlLF+cmCSTcqmSPZ962oSsQEdHEYmeSIQ6Sh6ukafEYzrVMJVq/Lwar5IqxiObJdlqMWixKlUlix3p
#dpPC5WIACjuGaUSxxTBMAcOOZJuiqDKGGc86CAIDyf9hYjMYRFjU0ML0+vnvNNd9rO+36+N1e9B9P/b7W1plFuxRI7O0NqxyyxH7
#tVg3BW8pDVFGBsu/OOmxVSfBR9N1F/CTS30kFwJbrJcmzxmq55k+Vlm41MoaNX9143jGvLNQnQ20OBZTOV5EqW+KUSoidngr8wPG
#VdaCWoVbj0PcRiiwNF7lS/sEOv2lGiGTZdkxNVf7cLfV2Li45EHxeiDwPC8qE6Hbw/PUP/1S7WgDYez+QTqdUDnNplPZZH83hVKd
#sCB9D7fljmrVaqVKub4wfoVJfWWRchzPLiSRjOPwzkAg5KXcI1eyLWECNokI9AQqESpIhcDiBQKrN0jFnvJLLSgutUKd9Hap8Jck
#Sb4kQYeQiVuCLwNPnvuMozU+sYid9N+e0EFQGJeLZ6qEOnKoSU+YPlsVikLvEyFoyQh9kEgRFFapG3CXWxFUksFzAmI9DdTo0YJD
#YQBLZpwW78ZHCYOXCQYpOpAM6eXufjb9XfjrYM54+H4+Xr7i3iVTWW1lT6tK9rnPhVGqYbzwhkUmcdul88/sd4a4cf17poVqqITn
#Gxt6xY825tn8gxu/VRwAkalNgha98hQAduZczth8mIgfCqzyrJL2R7bKbaVZ7CIF3mcCe8l3L1v+RiMiU0Dr1AiQzyPA1XvdHuvP
#1oOKf11VviT4lyZnjagBpx50A4ekD6RrI4Q/1VKcPd4KeZf/vqPkRO93ag/wL4+Rsrq4NBmNbXjflqVOcpSaPNOl0yATxvqq1Fts
#Gqvsq83bzw+xS1LIMIXbiEPP9Bq1HvkzQlXCFt4aDzwb5irWOBZ5P2rneVTM6Roku27HmMP+bLe9k0VfJjHav6L7awNqQ8rHcOuL
#CE05BFOW0g0FawT6TMU4o4aIVQkHi/0rkY50DqoKwsIwLCSiVhZlYSEhWUEOCLQ5AcdIvdMJFB5LCT7+kiycEwoUbjtTrMaF3O2I
#4jgaV6QUItkEh9riCCMqyrI8oUYBVthp7ElJJmYK0nxHhUkFRqIMguDgdBJFEjvziws1fSiJxDKUmc7GjCBywpaGsHLDiSTs+fMz
#wgoTwpQagiTih0YlGUfUwrc3kGw+RIhfsUH7NZz88UyJwqf6KvuuuE8a30uDGh/3koW3vuf8SpcdOYor1jDyw3vICCrE9nm68lL0
#ITKhEopFo1Fpg/ODlKF2N54u3QWGYjmkfTipCZrDACsI41EnekHfSLQp8Gvga+hr8Gt4HAAcCBwQnCYhPxHArkIE0f8CZqcfMWc3
#qwRhrRTDvVgKFrV2mvwXjVLl5zsLGtFfIoMBI6SFB8Y59Ok8kpdIoSx8NjXjb48xAsHRcN4RBDSor/qj/u0nZbhgQzcMAqJLSrDl
#qVtvQv8jQtIku6URihBBKUKM5ohGT9nFlV6p/hD7EORiSoikMSEuz2oX/qAQYEcpghilEKxM/Yin34/r816ErwZarRCkvVKwhy1Y
#zBJobpVZ9DppQ91ax8RB3ekHHBKAGTq4SvjB0ILLZuDZhmBowmkdGzI9rsxtwBVvO6jAHY572qB/uxqB+5m9MrALTFIux9n9E9M3
#CIDEASEoW7FCy2BjSE9rrTGWLvUyWVTOpi+idR8U6OKy5zdEA1VSg3B3tYGGGizcZdInlZxeWxrgK0qEdPjV3+63P7EbEY5HSLEk
#VMDDYmOE6qRInaS5HhGzslie1s4wbJPYJ3GqY7kOo7GABY9A7+Wqed94ROa+JHzJU3aY0KEEwk3wIG4//ZuW2vM4CZOW6zixxuey
#qb9h07Kt/DDDqtMt7kuYQlGWZd6FYZ5l2sZxrm2aNNu+aVgGxP9aIh5pAbUGV2gOdAL8h4RmO6rFjX5T1BaIwNWAfgFwABEjXrwa
#vprHJQck3Hbm3jbSnNVu9GqnIGYhr2/QVoSqkHDAGv7kXwP9O9N9O7b9B5OPoPl5RKVv+C19WXU2v3+LRpRa/4b+oS89HKXXIM8z
#mrQEhUgoqN5X4oF8eInG9oBUGphh/p5nh0Ynh15575EVESW50TVLCyongqjEBIU6TPpxCxkSEBQY35aMzjcBcpS8HH2UEAL2kI+Y
#kbQYaXJ++Le3xR+iRwh8UQT+tRg9/7O/a0f0vBPQVdXdjMnLaN/QCs87wrszJt7pR1DbY+b1B9E1UufdK3bBM2HXlWdGAxySQdRk
#IiGBKJkMHrnVkpqAHn48CPWzM87OBb+Kq5nPSb5Exqps2JkZRFT4OimCESlJpr83DUVd27SFZV3bvAeGzRxXvvmu8nL/Stu2tTZp
#v2H6xjzxbykdD6gW/kiZYuBMsbOZXoyUGxsY06Y3kmPQgMjbQUiyeWHDNpCR/B+pODHQmLZmpaMKIO7YlJLwZf6gwoAHyRt2OlJD
#Pnj9H2TwmSZcTCCSZEAQSgIuRAMPUG0DooRBlXqIrBtxMvwJJP9gpH4Ye2VFiLWmzRCK8zIH7VQiDBQGiCvS2vNsRbusgQEUimD2
#gaYrsdJ3Gm03X46AoehJOrofqaLG/tsycG7zBy6Aq7kqoPhS8DnOLUvAA4Ybe15GYnJfV3Xi/CAYvuX+syPDNX4X6h70xFE3RI16
#GcB5bUhQYF3klrWd7x6ZgSXc5NiVCCtldbRrMV9NPLbUIko+lH48tQyqGYRkoUoFslao3mHFfUg+yabJ0vCMiSR1Ocq/efraSCoh
#1qjsccTH0Msfy1A006mrk3dcAkBpuLTphD/4wNG/v1aM+3X9aJ8313q22d0T3B/T32kUgYDdgOQdIE+K7WuhW0doJ3W81d6PBVf9
#jn/i/Vca+l9j53icVyHEfTyxKfQ8T99b38gNOuzzBOWMuLBd5tEIaoVDGyP6SnS3zINySaUST7313wexzKOBd5595ugUNHeIxLLz
#Nw8GJ8N65J/88b7/8Nl73abF7brv4sB/X7zLhuzHdF6nJPvJ8X6fc3tfRQe0+z34ILxl3EYJwXFfIeGCxQNGyUkKywpKjMwMTIiQ
#6bRCJBqLeBCHi6NFdEulFuiS9btsMJtOJtSrJBqR7qqf49xdl/VzrVixVryq9gyAYVgmIGbFopYv/OF5RDIdFknNc90HObmdW+1f
#da3vSBPszIw+oan2ZzoFcNdw4xX7Yn6KkXZvu9zDles1ZdxWW+3uUovKha0T0Dp7qvO5PpZGjaL+GPF89QNXoSe8q2v2fh5n0GL0
#hmAuHzJzRqe9Bha50hIb0zoQSp+1EDyCqiUEyOepnBCo24jgZeI+DmuHXCsRCTtmYLvpvlaTcN7iBBQnG7HJUeriteqGUgcXefka
#Jh9qea5w8Acydzgca9FYpYkJ974q28xOUIIZ4tyxnklqgyoV+NSCId+f0EKfq2OLVF7HfdXe9pLYdz9udI9lvZD6+tdc3LZ3kObs
#9FEwY0cgiwsQSLMbWNJw7p3RzCTyicFleWFgwI1YIIUARYkqvNYIzVE4yfi8jlal2pvMggzkW+aPQpHGBg6jpSw0s1kjpY6q4gLs
#gshGLUehFsBBo5PtOsZo5YevNMpLGtey51Cr/dIheJKtwcGprtstPwNjQag/cAxNzcvxuBNz/uhx56e75AltvxpMj+K8FKsJup9M
#Mu4pyGrVGsHYNNoOjmBfWrGvQELOiTqHY06+JBvauHfBDFzbZh5CEbTkcE+aalrkLmj3tJBtjQHk93vbMEFo/cUyi1pIHDHhlRsI
#uiapF0v12g1FxZLi6Cd40gnsxZrLrfiSMjAumQQVYZheazYbV4BtO09rEavrbXNWxM6ozH83+ZQUBysBd9jUQSZlhHLhEiX4nEht
#FxJBrnLLOhCErB+huGEk+tPJC+WGgtUbu86b75eXy1PinFQUh6/a9Hd7MZlfUVrzuJhWbvvK3JYloozHW+0x53Ts7COZIv9LWxif
#+INRWtB5ybwST8FN/YswycJwcJJ1K55qCwcPeWoYWJGKNA3LXCAZHzJiK020ycquYOIwzSuvivuZ0q0oNRUlCtXFZ4EkMeVpvwVY
#3aHYAQRcdOkvMEHWtJd1/3d6FKnGkmiYwusCCsQbGNw3MCyAMIBExYBS5UC6MoB2xYCENU6WEFEzYaW3+xSUdWL8LiH+kWIVv/m4
#7d1GbvHhzctJsfGaVzxNW97x2vkx4zp2BImqDwRJmqSBVCnqBccCChP9ENgbU3ffk20U2zPGE10sncHC35p776UJiEHUlzfCmXkp
#DY5FBtFgZk0/HesMx3ZklU69ePHVflWT+llpYsEFzMfpwCIeeLbxTy6xQ1a0ez3UEwiAwze5M0d0+HRdGpAFoyuRYOq5u+II7CW3
#7CiNVMoowTfZfUJHwi/Myx3S/j2GrnxeuJYJ0c+k7HDyasuWZGx23fAbL2TyFh25puR5thljx6Yxp6wTSHbL7gfnqOJUTBM3pEPn
#/i15xsTtOB608zaDLrkOfkW21zxL5JEDmQmikmq8HrGM3y1fS8wgA4I6JlkaWWtXQizjE+qRrNiAknqSYC5z2dbJAd45a8VtFcAG
#YmnUIKSChBrtX9AKXahJjAHXPqWydZ6cbP+9q4QLTDgVJGlJZvam83ED5DJYwBRj5qE2xA0qdAfLO03/PStWI1kLo0E+qcJYFZka
#Df9sgwUarRepZdiZ3/utSHLBdez9kHLDXaEGOcZI3GDK1ZnuJ21zMV7smifmy9LK26/1XUZtZzyT1JlPp7TDXVSz/MFgsrNxpa7x
#VpNEG+KaDt3QZqBmmZmUAJFSTwb8fUHkG4lV5nLyF0yn5hNu10TnTwgGGnNX2NNmNDuTuc0mjGYrOl6coT6YuD+d1FtCKlbu40dQ
#D0PsoX07xuVWrGPBBuzZ6QW1CQLbGKxlfe1nXamLPRxYM30Fo4Qe5FZW+8T1YCXZ+gMcLR8I3Cbi3IKoHKggi7AuDQROlEcYnSMV
#RBLmVuYULrqDgUjWBVN5IIH0yukcIsSjiDoHLIhoUW2SHU5OqvEpVXlQQVZhHRoInDCv8DoHKsgsjOo0H86Im07HnCXBBZIqvGgI
#3yKsHPBgwsWc4q2mZHTJ2MiqOZC4aZCB9dVPj5CFDVtiQFdnOHS8th1KvksNFV8NNZ+tgt+I2/uFG17728Zh9s1449F45dF459G4
#KUZn9fguj1v45qWHytJDTcmxquS4N0Zn/Lgv79u3w9xrjfcGM90NJmyxk/w0UmlkVfXuPPHsjbzmg2Pz7RY5L7zgBj4d9MRjwBaA
#CWfDKzoI23vIgANuhWgCbT9hSomu/aq6uj+q0InMhr4I8qpjcYL58t5K9pGUCZSpn5uwF3LyzidvlRoGNKeFLRFaPMZT8z8XgpQq
#04jIaKTzbff00MpKqspQlVFsMgMwKzNVcVNnaFqVX0TNmUSiRgvpaBHVW+HVTiF/pxg/2NHADqvLJBbO8elgwFZ0lRYjVkcVT6Io
#bc1kmskk8aU29mvZ8jZkSVNtJ65pdaK1RGrLeSNfGi1KvOiy0CMzmfGuPpv29K5ri7ortxyi/Lgf4j7ivj5eRjXXvEMFJFczWs1b
#uVvVOA18MS/ytXd5iYypTJeKxr3lHBy0bo1Yyy7J5DWFfMQ88Xn5XZHOff06r146XSou000Ax07z8td/9rf6Uyo5UfFV68rjuxqJ
#oqI9z7FO3s9BqRUiUUxJXpFjVe7NNG2nfRSfReRxIu2oK0YwwBFFIEGggOPV4eOEYwiiAQKWSW9QaWNgBIqMDPfpCF4QhhhgzeAK
#cWAkTrFBM4kFdG6alpJOiRnGYg7LKLzk+AfMf9WRkKFQRSSMZLHJCAjajDvjuQ/QkkPQJRvuXGSGAIgwlr80miwD1C4+eEZwkU7Q
#ZMouatlkz5h5iDi4t4Tpi4HCYMXgFbiY98Vrriul2zHxyRQA7vQEVMkz1SiIjAcq0uNVQyrqHs0KT1YokYubyG1R/EzWFN9uC5TG
#wwBxGM+A/EBoMDBTGW/2gM5AElQwq7uVBfcMSdgVDcVVkiu62LDaR4QmtfoUEpJFac17TJ/DWyhGJqdZfGDPNiGduoNz5iMugfMO
#TmoASjT7lNfHbZVOqug/awQ4mPXQEnar1YR+i2NBOBnGrQVDB9cIz6ZALyDM8kkwGRij6O3YRvjkxQFfJcZI7A5y8JKTQVFxkBX+
#Kg1mpRNr2IVsbr/MRuDFJyUoLYLLb8NB20VyEjmSVayTyUKxFDVT5gmGI4N3H1k9qgtNsNZa7VGWaTccAD4TDmdVjvDKxETiWovf
#y5xecngrgair8CLH1x201TgMm56s7Ha32NK4XuolA03MAYsngsAWiowBTkhALBAU6s+Mxd8fyUXpFliHRjm6e7QdA4rsnNDnqkFQ
#LJZpgni6RTRpgzEP5kTT1GzbBYhJ4/VBtrgHSL24BN31JlKaXvLH3DooNOwXmiOSIL7GErep6oiiNji4ySbxtSlLhOW+AaLFWWDc
#LAHkDYqUGw7Lr/wqTWyA17ySsem5UTgoHfr85aqSkeIuKihP2H5FvZQi+Do7peXteugKCevRN0k9Jki2NrX5B+uEXmXP8W7AO2N8
#xBYZgXoRo8WmSoW8Ib4RFoPcrgQsW8ix7HLcmUS/bAmfrs8CDG8y8bQ3tHLGGP1FSD/ZokNP4jyAtI3kswPE/TKu+2pRbBBwReXM
#Yodgxb35AHTklTfFe+Nrv+eU3mkQnxWSeQHKcFh4o2ttRBh1MUqIrGMxW4DvA7OxDAXg00SvLPd+6O0oD9A8hYRbHxRcctREvd5O
#UPg6NwEgCOOqVYgVA/X4x64YvhViaMXegPVCKkPIKiMNMuFw/4SepYypJTDim2P+U2BOauxoh4oFrv5jGujGFhGpZlw6IhKJF1OY
#rK3APU//UOF2C+eIG7gIWF3l5U9pB+mEJ5f67MCLvEk5l/PJ5P8DIbfevhvuKOW1wN8/IecqV01ypTV+W1Z6UDlRoRalCsXsO8xT
#/JAh2sVeNzPzfMvITPnPDde3epfLtUlafOv1Jp9NUneYg5ecxErNdXI5sYNB0BQPFYjd5+Zu4XfW3BcGLhIPrz7rYWU62L9EC94a
#UKfF+Arml38OXZuVifbqetY80bBrGvLJJ6ZPTwdauOGlHeNyMVujanPPoH5BVnKE4SE+Kq/3yQN/P4At4mR7zaLVY0EGyZfxfDS3
#LyVLKkiq1fUY0wc/ogQMRUL4yyMs/e9sRlVVCIaoHVPHxte6RkPG1CSp73AUnp96z8ycQ2OIa623FS0axhvPWY76qjKadNJFSS3Y
#z0jvKpx4NfAdqrdyrFGIpwsJaXUU5ecQMggYZGA9P/9fZJwfvTx6NatrRQMGgZcgfQqF6Nwb2olMNM2+169OeIIqlo/mLxn9sTFI
#RNUjtm4exebvtFx3NQQPUD2pPDpUySFB2MPAAf/SGxZLwxXwiBMd9R2tPVxs1Nhsi3+xcQSYTU5dcs28i6MYg0HJNWddujETTUdw
#1pWooms053wIsO/Hp6Y7+MBqruDd8FzdrKsLnKt9S3dNcwVg05KO7PElJpHBE6GwfsZqlRYzI8SVaMcQUaGi2eQMO82bDYoUD3b+
#bfUH5ALCR4e5RfcmYMC4I+NCJwrtYb10++SE1sBGxN2zedtr+Uo6JWOieGkVRPx09OGD3BWMoyDY2OrADVeXwfEC4chF5hJ04+Hb
#ZMiWdJclTF59HD9gqUTxOPeNmG4zAjLRVDBhKU26shrYEAiSoGuFmUkApgZ/n+ZiaRcSznQdrqrQe6bGF+3AXqPEtMPWTa70Gjmp
#2HDCFsnmbP8NxlEERJFKcm9pZfpc2nj3tPA/a7YW3Tv/d1VwwTH9qdX9Jug56cyk/RH/sO70WQUhmEhLrDOoyN9iGoO5cXKL6Ii/
#tbPPIpk3dpaLQDb4DlOJ1H93tpp5CwJ+U4auxuYZIuYxX3tAIg9vjjmCMS3irEX1QZXB2lFubX5E1W1t9YIhcQvGRGSWmhztxiPm
#xwhNVsgG/34DKM4THfa5JcYJmPkiE1QWZdVLKBI7aLBa/d+UUaxWqEgiYFv6Jct5lg53cWIk/MFOEJIBbJMkiLofuuFC4PXIQ9h9
#VMLL4CXZvUWORbndLOiBxgGNDSpm9y05EEk5nceSBL3D0TYQlhc2VesuEopJttLbtiXbldy8QyEJeHsYcxYZKVHEY5DYiKgKgQXI
#krwRamAE+fWvdK+lLvVCL2uyCdymTBVvMN2DuildJYl9PRmBNOvCSOPKvn1G0PWFJShM9X5GKoPAMBqx0BEfNrZeT0kgRIYJiOXM
#yYlQgYkZSfun93RbhpIjaaEhqdWa9Z9VrOXHMwVWAkzjfyoSqIQOzE2uVyShM5HKACk1e4UQXY3BGcrVMDLwiiShdYaZuUTOkE41
#kbXG4mbVYcLs6XgEDv3NXSLcjv8eSRTC+4/p06QLljwwZEwxcYIfMaY+81ddAwRHc6gmjShkSgwXZdK6MLdkb5guEdN58dmtdc53
#IpHwiOTJdTUq2+Js8LdlcujUDT9tqsjz5V3i0qCw+RHHmSWQndN4IVNFr2StDQPamY/sQghaqmiRkVsd6+oosLRB/S1VmetrptwP
#RQur1COGvAjqUA25uMv/bgMEl6WiaalmE9w37jt4wJxQD5n8W+PDMYBAwWimuHP8bG7UZetSe2YER/qtCfbZ9ozmLpWR6HE+WpBL
#bIk5amtvz+yW8ky2V6l8lRreagrwRp4FxcgHm5NWeKo5erjGoskHVnyZqRm91ZBtsq0kPVtWZLwzIQXfHlpDpywyGAeNGDuI4A70
#oOj8MT8/TtUWwjiPc9uS0jLge5WRUf3DffRTtcb4pLKcXF0NHoVNCJMUvwfOmr882F28hmxFCI8RIhMjO1wttJGm1lG1Edt1Xk6B
#xZ7IVyzX/4x0np5TiNR5WVxPuf3AUU+gqDnqh+vnfCgXLZzpPF6vx3ICOy9TEvJocXNgmbEGmz1OgKn4+MyUfMaHicIXhk0fXe64
#ox+LEA/1GOU6liyZ9Ga0kezcW92iH/FRjbVFKdWucoXzbshPeHJHfedkSvQ6oe88q6AjsDrXQRdnCKTVW3B7NCxWxUB3c0Fzj+EI
#ko9c2m0q6ciNEzSwhC2XZ9zU+3lZKmQHjZ90YSDkHCYdRWcrjnAPR+bBOF+otJFkbRL/RUgFf2MBFnOPY+yHGVf4eLkaFVyljCSK
#wB2apAmeMJ2EKYHxbfGeYb+C4bS3oEaUpinFudyteImmt4z8MJv40IwNPg+Otqe24GtpDESvuYvqtVKQZEbHWrnCWrdBXEbqwSbT
#hUDM5pVk8ZS0oBj7Ray3V+xbffzqGUhzWJ6ATWUj4QHGwQQNAyZDEYWoU0fjjE1ng5355xFVpdcf1O5sxSIRK3xOezlTBCVq6PHI
#pndHezLTPAVuDaTzWagPyMZCpOqH4VkraGVQUtYvJL1783iHlFmrcQx2RrCLTHr8kzC9uZAw1h2WcR2VOUOzNfFQQmJQGARvUFIU
#G5tyHeNOseVDI5vUu+cvpKfqxNufGsAFyAGPze79h4cSabfH8yyRtUAwcQ+NTPgNOnLh+Oog2MeL0HBq+rOMdQRBsLKAtzl1WseP
#lGO7syHXZ4AFxle4vFR+2JBwC4wO9xQJFvQ3YwgTLvrXyzWWNyJRUoc9urBlB9uXUzLYRQgf8Fb4jydkru4JwGfEk8QXxE8S+J5p
#jE02/ajUhXjdVUTqOmihcn9+DA444HnRoqbYtw5fC1z7n174PUTIevYXtpU3dfNu3duKqdsd4j0agO8nsdYwo+++4C1l8qTYZTjg
#O1QA4vD0DFltH52+Oj/XwgpLbT9a+bhABphh0G+hnjznS1xqjB1PSLs/OsPN55ZY7LLHOfgnvEJNbXmO5hFfWVYW87MumfcnUg4Q
#7ZUsjCJx7KSnG9YV1FjqG4qVO6R8A/gm/Sq8i3pmdZa46p9SDUoMgRXzKEI2bYoZSMD7zjEysO7q2ZXtFyy90AWIAIwhXIgRgASE
#/rX3pInj4PIdgIIc4Cn2N9QAQ1GbQsz3WxfBpaWjUg6KZMZ4PIuNuZtUizu6SOI7D0/9ZKJ4gcltSc3xjCVw69mWtVhxs2JtfVtJ
#YFa5pT/LRW7KXl05RfAvsW4vftcgoLr5jQXepT1bfVYCGKJsXCL86TJYugsHUiJ/ihzxaE3O6UzhXtW9H0eRr6gy11Z/1dNvy1XV
#1eqH05h7OKJysb4GrAcmcUF3UoyhPZ24JQt8BOIS8hxJY3eS6NcKXtrtcitASffHEGYmvRzDrOdBv6WVzRgrP3PiZb4nqPLyL4uU
#0pz+EyVQza9KX714f6KR0OcTOi4WbCe0+5C8K//sgP5g9nOYWPnKooRMUlHWJlz4CuTsC4wpXTzn+vUjJmxrCGbytPXEzdN1/xy2
#qSBb5zSkPdKapcWdUxjrJRaeOGJuxF1JSVlOodqKzJfzaTgL1j8x+OxYDJgV87+EnT5FfPF3BXMXzxmw7326CblKj6x8ub6JsD4y
#IJkRJ9TLadcsr+6xPQmZur6JUSRDzIKuuXNTuPRBE4cO1y6s6ljdrvCdxmhc4NZVXN/GUwCTV/y4X+ceaidtyuLJK6V5oANsALNK
#a1LG2qYxM2XV9GrZJwANVGcNTp70Erd6UrdqcIg+Hwhgr/NVr966xURdlTX0CPXgLQ1LKzUlJNHNuMwvy4Vz+D6TGXfr1g+74r5T
#Mc5s0+UmRi16ACbe7F7tvT39m0l7GsQlM2pLDsV3afQO6IDnZdfevQYFVm7zpM2SlfTMZQIYwYwax22aLmFPTHzaam/aCsXQ2NOf
#2NY5sdS+oaFgBhjDpLNAyeWaGQ6urX+pn6ydgLqjCt7JDz+QEoId6AFYP1qyAbYCpK/Re9Dmz59kV9G3NfazKer2FbhP7TeL9BTB
#Jk2UilO77u/nZ6NvNpQj6E8MMNozx8iiLvgc/hnyKZF0j+64ZYyRRhFvPnGGGsvnPkUAR7kkS3XiuIu04f5N/DL33H41+4/EcMFM
#kYneRQmzde0BSxkekIS5/vigFztfSkUhdu8hRDDciKFGhnkM/raH/yB0oAnIxy04FIOmzcoWpZiXTDwod+d5WcNgUmGHND3QnplI
#SeKMNKzgBn00EZu0lpxU4Ra00OmcXyfbAZCb9KjdVj+jpbyn/k0BSsx31iDcQB43gAQ4aflqkyQ905QqKgCIsI6jJj0dlUJntqoo
#Smor6rICHO20O0/mC1dGDz/Leth6VwjgplQ2SYhTaGPa0I7ujrYiyIESAEtm5QvvZSbQfxhB/lV7xcvrZ+DGNymU8G27acPOASdI
#rZtLkGB6kfnfrfNTxQCItMZLTriTkOe1Ksc9jChwHMRcKMKSTS3mj7pbsKCh6VF51BxVClzsAVmDtX6ZUXgE/mvj6txLDJ5JM7r4
#97SlVVjeSoJkFX/LgJgt5BKTKCNNLZMqdewDCqY9465PJe2KNDKGEKAcAr0dTZRWtDsyO0sD5a985KfGy2p+KJ6Zcyl9T6TFufqT
#N0glf2RnKzjIfDi06mW1u+j5gg4XaakgvIII1yB0DGeVfNBoygQ9WLR4S/RHG76/K2C6AXYLHsTeoVeeelzHX+m+/Q9CXVqRZEcH
#YpcxvryHGgvL+NASf9+dvPeBWRxFWo3ZpJdlDGLULdE/ShILOJ7JSIfaW4zi95Q9f8yms0TQN3dGtJW7VauRXZem8271KlbrzjeS
#Y9f6NPRWL4X+dcQ+jfpKd29o7EJFXqNyXdRR39qzpKY3Dw9xVWgCjED3ejadmuuoB4oQAB3goLEHU+n4Rk9nGKgASQg7JBXg2pGt
#FxzAF/yCnJSbOfhXBtw+/J1lGqkPfzwfr91fZqsZscjOq7MrD80V1ZEB0XrhrioKYW/MQhP5lo7eBXS9WURDy6tNs+pLnyjuTSXj
#BbBegMizALuuGFUdPfXCpxnvNP3RJmwpl3TWbjnkusxBT1UknW6hrNy98zKPxRVkr1hIRbvCWrYsRSym8ElsRIPLZYjjxVKV6NNW
#xgGKmHTJIfZ7dVs486MK/w1IJtiu/2x4GlPsp2Wc8yIKAJY8ylGTmlcSx/Kk4LBTxrDb3U+tKBKtko4uzCFN21WX7Evo0tb3ilvJ
#r/6BnAoYuREN9eQ3zDRy+pvIMxR/xNvorDiCh52/pc5qrPhmLN29hAQv3O4dLk/KIazVOBgP339EXsP1bvydrc+ybeQMGp5ROxpy
#v2G4M+G+LQ1F7N8sUh4n3z7O0LqSDgXdbLSoy6cCjTwV4qvlzcdW94ldRwSqunB7pf2aQXKOYa2c9Pn3qBn6Ggy3z66CmQqzCUF6
#SE3YxQ2KTEjtZ171nJyo8brNawwLbcOn+OBn3qo2dEP0I+mx9MkMVnm7HD5KdOzglYMz5LMKWsg0pLy0ZMeYgkDSZ9DVhAlKBKrg
#UJdPHL/+w9WMT/gWAjniuPfsbiO9HE3kOr7B352sDNiBJIDJnoflocnvvc+LNLSEjGx3su6dGiGZkefQnAMBo8qvDsX98x6iotnl
#WHlwYXZ3Jcy/oM+HoqVHhGVtvSM41T+hb0mcz39fQWVjJobymoS3dbz/HKp6HZEe4LnGQs7FG0nmrGP31l/3f+lix4homkyDxtkU
#4xzVKHAcRGArwIgRzTsOwLaNnZ162YMCv4DbYKyEhfGw7A7HwyN/9BuOo7RdVPIoogR+nsWao4RBrS9pDblDGAAIiWdJUv0y83x6
#Km/Fpd4bp5YRaKnsqJwMET4JQYL4TZKqLyW3s/4hVc78qeSdWWQuAvZbW97U113d1qxIAWuld7OWjy0urK9S+Xnt/BLlbpq2X1ZM
#K0HMIkih+Fe9cHp2sh1bawonH+DUgAXkxpo43gonZ3/7+SqAB5AFKS4zMMBCGWCp0LNWAb05NwCSGUUO7VUVSQwrvBt4qaqjbsKk
#TnsLtR3ihQ07Ray7FWBoLQ+STyF8Dhr8sDP1ENlC+++xs5AhEr6HsmKEoa7eQ9aj0FTCoqxfFYbS3PbUO2KoBo8mCrA0bTbQjFLo
#vRFn996Sw40RSGX+hvlCLMS8ZzKGET4gh2UKWXjwQy0QBFPP9DEu/6AIrEaz3woGzPIbcdAEevwgZEWswj5EEoX4MWyMHno17/6y
#RBGOOwI+H3/K70KAe2ML0YfQQQB3/E5jO6DzrKNW1MlLzvUfnqMvTsDnpeGBHGBJwp6PJTVJFGCdClWEJXRfGKcCxOXO1wklW+mj
#yPjv3dQj3mOJx6i0YPzWdRSWvYj5mc+m5p76nEgIbJfLAVJelM0jGVqiXwIe9OTbbeBrC+l6iiIDmZ8JGy3qnmr38yLF8cXkWIx8
#9LH9ZJFTH535NbsT3fFClnZr3DfBAeh9ZgeVzK8+in69PvrSlY5dN1nyfwh0YzpmRLQqp7/1Dl6scxzj6+eTAQtQX0me9qczFWP/
#AhXisO2N3gD39s/bz6R1nv/Urfow1gsm6vL8QcuOAier0iSC45M84WXENqEE08S1fyOogLzDL6JY0S+ua/+rK/xp/ellvT21Si3l
#bjG8gUu1su160lK9JUaeKTq4JQlJjJTFtALbj2l3s1x+S1uKfHhBzIMlHF2h58KwiH5WkDKOE+JihR6iCOG0MJQ3riQtU0nDrIoO
#e6yYa7Q++wHKF8aI0KwIOptQqeJTHbVDfim+ixY9Z6NVwqzP2crNDLBmKPhH5vgYaa5pcy3uugBxu7HFPBVTzY+8xq658KQ5IS+1
#JMc0MMnI2DkeN90HPLPTDGpqPA6gIQ/+j58IaTnTJNyPZnH1AB4ECwppZ9URQ06EMHES1zedpB+vNmEaLGyfRJT/+gQxFKEuiMFs
#QPYbHuDEtku7XcWCmvHvkHe68RKOVKm1L6B6K3Gqmfj1aK5Mw1Hb2DBpKl6gJ4gwUfoJzYBILZ+6f4OSWo9c/UbDX45iq90wlqvb
#/R1Mck/DCk9Fp15I8hoNgFOetn/OTJADphD8vm51IiJpCjliVnFbobB9kwp2FBZNOe64a5sWrZYlu6vLmKq4U0aTedxAhxapm3U9
#97l/aRQfJys3i+38ntbxbFl7DWrJzY6zlVjdz2f8Usb8QkNuTzyVzTrU0LuMtb+kubGnZPWiLoefZNOE8Dlf/ejk54blTvbi9FX9
#r9N+uK7neo90XXKxWzp7IidWB/10Q/L5LH6lY3W1V8IsybP0yWCfp7TpbvmN0nkRsicD5B8ec2VmCDo+56Esb0+k49E3NpxtRSbu
#jTPVTyfnGH/QDX2zCoUqNy3mTH3GQ4QnD+X+/cpfbJ9AAyuK/Ev5sSvoYKl/5CS7u73SJv2sK1kIYyW8nb/YNy7XIPqGw+fqskL9
#ZdsLKUnYiIhTCAp090hxbWGtLhnLFqzjbZpDRQFlxkVd1LgAJoQ2kc1yH1J05nKXaVOfWRaHNK96nH2DWA05i8edoid8pI5qn7pv
#+jEM5/Ixr+yhQwNnxoGfUKL+fzaEFLfIbTcLnTiRqspJ7VgIzTSzZh2TPpAqo3ZZRvs9deP7/KFep0fDqb0kmn2XZ+zRzTPr5gau
#I6lndXHL49BZTeKYVfGunrFFo/a12naF2le1WezS9cWMRt2iRlmG56KdXuXRgLmeWe6jdtn7byDtHxSO51W5zKG4vD1yCT43Ux+v
#dpf5V7WQ+Y2z0wc2800Q8jjMeZyG78JKjknmED8TrUjq8qTt2s6iXx26xD3N0vXO96qEd16L3wn2v3atpExm83fpxuK4S7ds8hm7
#9Mlrx2yyLNMZcT/J/qxfaa2r8sqH8kqoeT8d4EMxiKe9B/8PaYYghAPiuBoWCuOrwHKZFyu1K2qfPWpKGohUhEcmXbTcwz5B/6tA
#SgdJGX34Qoyhbq2jAo3vkcDMqB1p6pxJhDOhCalHu8OIW5n5CSxPXRBtcWNVEjm1lshLaoKZoHtXiFIZ3woyad4zvd1kP5ApAhPA
#BZOEtZGBOtzIjJ00ftOOrNvztR3hTQ1UAESuiJpRJl4exdOfv4dajreRtBMSX3YQ5BNL/GOTG1spaWsqLKkUHRgGVQQ/yMPptlsv
#ZIBhl7eMEbflWHzViTzvWtGs5k+Fagugn/GCzvIgrL3SAP+kaW/W0v88vdWkQ/jx1tvKoLDeIjeNU4hpZw+xjKPfMJ9QiVspIl8A
#I/wYExGIShH8IApx7sWuTEOqrm/gJ5u5zcseu1/5iNN5HV3FrK5mdJNJOu2/IPL5bx4jdH4nMjN3ShZtj5+wyhA4tU92xncsRXya
#zgHCvzLaftiyQ73bHTrFR3zQuEn/AYU7i5QLUxyK3nyQ7qu78+UjoZj9xf4llHu8tqJVGm0XBp2CF136pFtTZrMKwUIsRVeO1ugd
#2Tz6FHv8IfIrD19M9sXnpAlfGDESfIKQ8yijfMq/hyTN21Ffo5TYS0pvJ9FlUDbc1haQ9ocj63XBU+wNFyotvrGOkDOjtIvXTqDn
#G3RoZng/Xg13Sn+Ttow9nGfizTz12dYL2u5VFQql08CbUMd4VupbrMvS3d1WUNjbUk7z4nr87XFbLtaN6qe2M+R/UD94i31c9c0B
#7D1k7Nevfva2HiSXlGF6qw36yaRsWEiVMI4IPd8e2rGRBo3QWnjgKL48izkXQWAHKEAdDnzfYM3QdQmG5IcCCAFf6isebsH/uAxo
#glqkYUJq/0V4cDsSxQQkCz6yCWATO2+LNw1BrQ2StogOJBXpbfThaAuB76iO1WDyjHKLm1jIdeLJYRoxUEpNaES7beCW16+WQ2nz
#aTVMeInjsh2AuhCrq5V8Gdzi7Ho33SklD3///GGoIP4Lb1bctpX5zCD0iOtReDOs9iF/iS7vT2629SFuGYg93m7Wz2e8+OpqS45Z
#cXykXH1MjtQ4ikytiqx5WIkhKPGV2jxCk2Xo5LcW6jQ1f5s8rSqXQEC4AgVm1lPHQe4ZdBzlbrNqFmvAoAu4X2JrBw6YB7xIYfXR
#vNXdafCG6YXFzTG6R0vIlDlxMBienfg2HS0eWaugmJVgTiq8ZJRA505EmliHuiPFNCz5CnBLkg9Ja0Uezl6UOWIg8XMxCm2g2t5M
#Q2Tue3X+SWbacbrqGmyPcMLLJNgiC8U5Y0i+Pw7b47XJ2V1hPPALU9zphh6e2IQFEIoPYeUj62J74J+xE3OU1w6YrRsLXZuc+EY5
#SidUBLDuuMZYQ3gLiwjheJoGSS5BIJvXVLov8vfzPRUTpq8AvHq7ZmGBWLEGOlTl7xZTAyFyJtcCOvhS5FNGwfl5aHVa7+7/bhJU
#QpEE7vJWn/U3sPx13+hDTxzn2vq7jOmVyUqa83Fxi1fGwiVQ2qRUSuFtPtqLgct/2z39lwZE2CdRAg3CgOjfKNGCgX66f1FjAyfI
#KsDzduAYgV5BrPC0RADzS3dbZkO2+5hHLxsv88kyJVJRY1cDmK+BICDMK6RMpUXMU3zw72GZj7Gq5LJCO0oLzqy7WzhzMGV0rSvb
#AcOCPl7N5UUlFABHgM4VoIB8N8RCVd1dVNEbhn4gI3oYZOwkm/mUU02VEkC9jIJtOuLJZ4svwPdeItgolbX8+gUDW9n8WCte8GJo
#+hWtDeAgaOHzFixgUza3l3WvCmFa3BgGnHDsBNdPpUSmee6LA7mWmkWyaREh5965nTf2fhAci4ZTFLAhZGR9pvGSFSDGdUAjoyos
#nIHtM/g7f9LErBdJOixRGjfxSM9LPicv3rVOkJZnCn8RPv5+XOuA8cHRY8dbJS2zwQltSGw3ppCZY3NVNCk3l4TPljTyGHZLCtC7
#u9uxsGAyZj2+ScmDCK/f5wEF8W9NbFAzXK7pnQfJNKWAb3RLxPhI0EeES03Lax1/MPhZbX3oQa0sfdOLziRnGbma1MkDRs2s18GP
#BZuvigXYIGThasG/536l7o6zM5xzOGt1udTfawUqz3cPEzWe+9fs9IJ8OfZTvsSqUKrRJy2mAGJzSpOF7JDABJaSQgBbySREGK33
#rzoOwnnSYcwQ/ccI6X1zrHuqmq9cgUGlLukBFy9zJpk23ZNHqXOHNrnrdFMpXpuM3P19dLmvOCTMz+LMT5woNYoUqV6lLD3M7qu7
#FK9Th2rCJdNkYsFigCD1CjeLr9fcJ2kWklkNlNgYlWZ3JSzstoDiHlySKQYzK/tBeesfWp5jZsqVfdUfNvJBSJSeoHSnWL4QE4iT
#r4Ohm9PC2q41FEodlGq92VqZDOR2WJetniqlPSNkQEdk8GLrJi9m24YGSUcZGzHyKywOj9Zqxa/UpuydObOFRlLCqH9m/tLGKiqd
#oJJ9Od+JJuTAgHHMhmcSjaO7isuoVG/fGLpoyV76ZRrYv2qixbSrIB/5WUVC8rUndbW1I3UO4azQ4rMhLhhuw8XO59TY7ZFJ19qS
#i5VQmkcKSnRd0k2yPx/AMs6nSBm9kmsPS6Ahwv/UUWdACvACdCFqEPkgBRmbTO1xS23rmjdRrPUq6kSgzyo7JZTvRIkW7RzA/Z33
#UXeFqxhttNsHTvLq4ayeUUFCoWwq+tEgyNWzApdkhRbJIno6bRT73/Wi/N6/zs90lQrsINlVRVd2d9CZSL8BPJpdl5cwj1ns9tmp
#ng19fv7e2j99zc7q4uODnxba3rTqrlM31EWLqaami6dRo0YJpyanxZPZzFndrOYqpVpJwYIUIQlzvDk53yDu+G+R7lcM6YlbMGnM
#ZVdHezWLV1UxZrq2sXM2n7NL61mxn1RZmSgvfJ07+dm0b58mnFAl34Zzc6kfP06h1l9wSNrhSxkc4QmwBi2VABuEMiEO9CFmv7Z+
#mPAmwAkg+nlML0cpJcCR1YUAQ2+HaXQgAu/2Rj0IAQvjVmaDw9/BH7llYy2M/Mimn66oGVmv4CFIso9PGDi5EAfXz7UfLCnFEKen
#lFBCUTs9CUKKCpaF88VzycrNKJvNzafVTajNTbPa5Ci/6SYhplFCX0T5FDKcasjwGRFg5tU92rGYjmqIK3+2FJMmJrUBrhKDxHvB
#q/yU36cVDY45EUg+uyRhwtB0T/JQyNn5sl+bpKYejGCFxp9AvjpkhyOxbXspzG7FG1vUpBRhijgXT4yuQoHDFHCvGPcYdhAvDRYy
#Q3PP56AKAVTAfmW6zx27p0rVuiuiVWVy5MpKEn5Q3Kc/FzO+qNp/jtR7Y8fWbmqy/k277w+jLGsgLuV+kdAH6bHwFwAI/t70o+/W
#0CqCHuBJ7s0sRQxO41WbyF9Hx1JIGnHz1OXssvAi5tEnyiQ85kSUdAx0WlQ2foG5WWNS0qnPkpKLzvVitvbIwbppJL760sYImzJI
#i5svjpvC9GqdisonnJzndCTwJKISIAITIKMLrBMk01vRYXh2Ani3diKKKuvYBcPnS4u+kaazsXmjyHmjwHmizMp7EYR/AvRYWTsB
#PDH9KKKJvpEuiGQJ1HozsC9HXo69HhBzpcXhSWsx2r1p8l60/2m6k1Ez1zIufatY7i1BC9FDmLBci6OxgipvZYwOdMHJGhvZBvc8
#UObw2s6V9CVxu/sSB4zPRQjYLkRP2MD3J50QzmvPvwrBV+Un5ZKqeRwL6o559UdQ+qyLEZGVElBZjgq+DXwa+DLD1n7e8CodKFyL
#fqmhCBPsQH3sL7bR+KmnUAmtTGpGrDVDWX6uWsljWjVxrhrb9fLYJ8jsWx/lP8uby4h/B0M2YGwuA6QFmqvLBtzusufU2vLyfa8R
#Q2+w91t/loqE98diPg/Hf6Xa4irneA/rnOKfp3wcTO9L57UFOKLuhi9Hb2EdZrSjSN2xhyydEvGs6oeNsaviXWM7UNJoRnjtNkhD
#1TtvLmsEtqlzuNpS3A0ndti4nXtiw9vE7pR/Vsn9r01Prx4c/Nu0u9iYv8iAa7tjgBHf7diZ8Yvn6QNUBLls6XKteW/uQ0Cguno/
#5X0AYmvAJwiNfAJoA/Y00x4D8d5C6uVYrIJLMvq4oQ1bXn3nQJrNPwoQRP8MaVDOALtiR1/XRSsesXa2QnKTdz47/7OAXrAd+b1e
#jb/gLzn6pw89O47Hux6lcv86uaVxPa9159mJEKDWDWvfOcmdjjiU4AkrhrIdEbdvWP6TLFkC6FvUr/od6oye5jT2EVljneIoe+1e
#PT0tZJfmboKPEF4MQVXdRWCCekaWbEL9ffFTeeycRpcXosu/qrms15EL7myQKnLncaDK25MLoDGVAr4MYlL9YE9t22SvOHCPQQ9U
#jXNvbpB/D6fHOy3VWmsOM+aeX2U3DViX5EQPcDSLS8mdnFLEvMqDgHBsedoEO26ZiTzNR3R0i9UQK+kx6fb5f4nOYhFll8GOyMib
#1dYX392Q+SFqYx7suk/9nxCdnTZjQ7RwBDrPlIgSnEspkwK2qZOYxrgmPdllR3Q8vtl712xHqn7sK3ivM16F6vvly1NndIkcHjgE
#cXeEtvRUaidwzoYAMN/U+L4uzl11Hzl+p+936Py7s/rf8tBu3YQA4BCoVskUENSNgBWxJz29AZnxeG+5dnn1auHXCcuuWl6ly8+m
#ptablmxB4T57hmMAH4eVSIGIA7B7XXXczsj5fXLqrPoKaUETovmOyduASFgBxMVq3FuVc3XaQCQRzP3J4B7Y1yIh8zjOpLABGIcv
#dIsnlBUL/iAZWJS0XEQ+sV+43TwxZpny/1lFCS2YPQagbl8lgUPLBysjbX+fV9kvjkbiIt+Nr9hmX4QMPBwpcxTSHZvYbBv65PoI
#asAqTaTPGn65cZ75MWw2aAApG1QBM/KeAvypmeFMxVexPynihF2btCmNE6gSI6rsbsMzzbNUGXIenw9cMYIR2QF6//2luRRNwnI9
#fpZRenrjdN3XcUQM1E8eO9pcZo88cpmF+sY0dYltcXfohw7EopDP1nfsPZNvQPFAp22ToFbTbmN1Enlh3kINUo3YnmfpComDQpkM
#Sm0pDhAfhZAjhBI/C5ijtB6mQRK3Bd08aF5p7C1WbcorGiKE4426sQ028nO6uQZNGk8mz3mxOZaS9P078XutYSMamSqjERXquo69
#GOhKovVL16UgxB+d5cJtfA2PUP9XU8ZLJ/uWaAaMhG0CRTG0fxHprmHbhtcNSfDdTM/3sjZf499NZLQLZGZY2UujZOlIr3XcdCgn
#z1wuMiIBvJrms1lKJnu4ZvjaFhAmDEfsAVVnfbGa5LUgabiYCRVWnE9No2txccpRIV8I5ZZGclFw5fbO0ysKquEBo7vVR1QTJhbR
#Rgkrl03MrVmyJuyC2FbDfijUaSpQzg+0pqrhPcM+CBBBIGwWWFZrHKrWCq5hgF0WqGvyNoUSVojjAACevj2WRjb09hMQV1eT0U3D
#cGZjhfQQp5AztAiGxCiA89o0yezaLwsz6J3D8M4J/DDwzmoCGi7JNSkbhZut15L0wJnOfTFwKBk/cgH0cYbnr6A1mlszHDRwkn5B
#N10D9r3g6qgDBfnMCGCKVWxLitjGpctQQf8WAPKIZ8dkFV/9ddTr6TMds/aXA3lFr0w59ZLYjj8oNdRTGZtxVVKBhYI9YUkJwaVw
#ptAchHr85bFWzdpOsF5kzaBULEUTC8t6TELTkljSBZ03MVA5FmBffz1aNtsiYOlNxTxfmW4ripkYIoKpYlcGgcjBB8tEVl8DmRby
#B0AF0k7Z8IA/uJfyVT2iRPXCInCfJEBsGxVsuu5clEStl+DrW2mjajCTDukb0Kden3wIJz5/nvTBsT3/79nj+5nqx+E3IPROJDB/
#hO/WK6lo0nxXuE01RGEaUpbScss36foullkw8w+kaWsiUhZF9TShuZ7G8SuZBPQ+OBsFSuRYeKHlQBsHrzAb0xw/5tyAHXAA6Jkf
#S3TMv/ovOn3nw0GB0iEwghBiMyE8rozxOJI6wruK0+Xm7X+jNFmx1WJMhxCa86BhJ+mgI5tAQKj6dABecS3VxezxkpGJ2zs710hb
#9QNyhHuKvdsFhyO6f4DzorMtNfzT5fD0eGbK7eDnPShA1/J5eQ54A0mm9UgobK++A/I/LyxgoefjjEK1Kh0kS5QSsAvSismGcx8W
#QAO72B7rM5RJQ8xM9TGvyC0RTqBPONyCZbQ2H10XcZVW5HJS0/HXNdUPWXYQp+6SqJZPGmv2BDWe5YoYHtJVp6TCQAEqB9BvmN0M
#nH/ZkAOhyWYoQmb9n0z6/I11ANMIcoHa0FdPp7KFdw+DkMqjuAjzKcbFuLxd3jnzJHTAu42HfScNSAzFahI8PWp7V7AOMpDL4H27
#p063mLn2QXdYQfcQAPKn9TciQqLnBRJXYXOoi4BYEjYnxNzzsALHS8l1J3+fk169+OpvOEHD/9IfPiMzyRgotZ4niZAgoHo2gVOK
#kSTLU5eU6JwNoQKAPBPAPF39htOfwwkb5jrRlCm2jr2oeJ/q1L61q1y0KX/ofPHHJfIpEcN8LKTY5HyP8ZymBTn3tVQmQaVpqlLB
#mBC0BTlFKaU/1qltBCgF5p9dvDfOqkdJgsIdr8dp84sdfnLYs5YBeVeAvSFgrUyY/DNQSU+q2T+kJHIpZRY/aey/rkb9/nU+TF2v
#JrTsKRLaIk6UpH/2HGUjpSIp0NeQFp6BlSM7fDp4/V19/OySjXfCxFrQjH2wb++IToHIjILe1V2j1RX9znLfadRGBUVRFLm7o9BX
#CLjMe54EUtM7i13TtSYPZy/a82qbi+csfJ2LL8Ax6DxH0kOiqIm8+4wJY5j5YSA0oTCdV72V1KwCobK4yaSIAXKYUDaw0yEF+Lpp
#hZAqVful73IyZUVuRtaASu+9Zu+U8SRwjqPl9DiYhbHKNj9nGVn6VOWm6ZPwwMECehQkx1vH9i/bMc3LOJefaS1YOUuv7ufudK7R
#pO2ZJoKhG9SOTuZfmDtYRT5TZEE91J+KZTzwic/1Qdxu3eZ154o4Lq1jS1/TylnpaTyt+/Ujj3LslJoosejkR5dZBfe2Cll7TSbC
#E1JHtA1pCa0XRipG+GgRHqTb1aKPvoV1ZnDmXLVszxGY2NF4BXglabWffjvSlp4exHUnQUvn5QWU8/P+HLb3e32/374MX/6+Nsiq
#P20a/snsL6AwwkBgd5Zvh0Q7cfLtKxem7FgpzW1msYyFbVMlXJAZjH/p8VBvVnWam/ybMXbqKipv6k+yws7lU+3sFnxBl3wr3CUd
#TjFjdXYkRbro4sXLEef0lUdiSOQ9tvvX0VlovFNqqy1OoC8rXrv2Sfi0ty4Xi5dTx32ke9VUP2yzP4t+ZUHoLF2csn4E6FjOdv88
#u71efrw7Wyeh7nixwaus/BqqwrYuszBjtX+EIzqwa8cY1COdrnbZIWXN0GEshEF77z/2Gw1oIfh0SgPnrTffSvugZ4fd7PHXyP8I
#gm8kiT5hAywSwGi82fwRA0AkM7tDQIn/02uST9Ga5itVSdy64t4udGDWPznEojNvDnEAjrnq69hdcA0GYL6A0iDS5ThE7IP/hkF8
#+HDrVvJPIEWs+oMECAxL21Jm3GsYbAJ9y1g7OKTWe3/O3Fc2lZ18CWMsd0OablTylHblXgYBj1upKaJX2aPAlod4HXc/c8eCZ8Q/
#R36ZKRtWsUeky8SFexfipOQ1hlkYEWrEfFlfzA+vyGhTROhc8qgWhBxdEPxSLczMZ33w6RoFh9n+yleO6Q3lLf9CzHnQD5tpplm2
#hCXwcEF6OYXm+/Ntbrthh/AU94zNdQxx0ngrVCO3vCQFW5RwVoifMm9vh0xFMoCA0dmLgKFHQ9kjuCHhOeuHS72t00DxngD6h4U5
#ra6X7am+72NCmzXUM/HRr11zpua3bAt82aEHcItKJhMYOaZSbek7KnThaIh75GsyiQFNT+Tpw7BbK3qd3usNE/7RXslHsfd9FBMs
#fhR+6GHmKNrnCSR2r68jTj+kyy03JhNh/BChhe6a+KCCj40dPIClrjJ2RTbgGtQcYK3BAVWNMr/ChBobgCQCz4KtUAheyU/8geZS
#nNDW42fJ4y64M83khwa66ZxlGxFPWzuyVb8c2tonJng72tgwnC3ciOFm63YNY9RI1MPY9YP5Hohed5uztdVPSYdUwaOJM7/UF3Qo
#AUZL1tSVODu+rU6+kIKN1xfT6koGxXq6vTFVr5+nyZYxP67uiP0cXJnJySMP3AjJXy/AyqED6CjLjAzFm6a1TyfTFmM7WeYD6qee
#7vecdqCt2Zf+/V/EucCPTlNNYv+x9PtdbxplBMZOgUqpLw/4mKRQzfUvTkd72moLuY091yGCGqGPN4jSQchMi1BT2OSrQH92AgRv
#/AcyE9R6u9bwndWjUw/fjVJ5MllADnvxM5rZgdWBGNWXFuzL95VJYGHbW+Cwt3VnYjnnDDxAx20AN2RD8LOZUAecerMknAn+bFLX
#19U0l2ey5TLDSDUvEBfTQ0xi47oES2gQrMlFNSDVyLOwHsYZ8fHy6py1vUi5jNAZ9ftdvto07c921hDg1MicyeHsVjtKXbFa4755
#bsM9zl55/sa3azhR1xZuXFOGDpMVFhhgLNtEFWt7aUvC5D77Jv8NzCHPL97X8p3/0/Q4vL0eb87GjZ+2F3mWYr1Lyhm1fQgZOkmJ
#TGxubYiR5VAfA56vO3/VLRGAIZlzhABO7kZIJ5WFi6N0YjSomftl7p+3M2QKI7AbywttjUndi+A1YifTdTbrIeTjjXHXKTyBXYiv
#I8kd3kqoolcl61XXlVmXltXJdLFNZ6uAtvI7i5M75U9Gn1p/p3LLAxQayPgXvYkd6Y9A4xBrZjCUxHmVfdCG33AnXTieZnS1fbSV
#xmSi9rpH4JtQvfAQkZLdAudgsGBu8CDmwnYkRdwOaxN3id1vnUNFo8s1WjR9hMDNduKnQm0x/3lXOx/uYcIY/cJsyCUtRuFwaZ7H
#0VBQ3DHtLSoYRJ3dSPeg+cwKB1XBULIITas6PYbJ8irqmpQK068He52M149vY8z7Se00NdHm5BrsnTsHgUdzADtBwHB7iPmotltf
#v+cvjXxrnEFS/ocdqqNpLzTwA3MQoUgd4Y7R1ZSWL8tJg7u/+wZdmYt6w6fxXXkJ85XcpjNW7PMUyB5Hcd4OErkT3/6e5SJpW5uR
#kTNA/Pv9bnb6/NTXErRPveO0httDIXiiqxa9JlQ2cK0Cw6gL6QuVfcLZjZanZXb92TKHi3hw3qIlXQft95kpG1WcCFU4hNN3Q/+b
#9Axjui0T81Aij6yvX0f3g9Rdhu6DfL3OeiIoSDiB/36BTj+CjQptJgQWW0wDXBnYgadDE13fPKu+A90F834n9gnXeFj14sxMchG6
#ISmb893Cj5W3nr0NfPOPGgvLP2YeMHJs8X7rYHnXQDLL2jXo831+efJabzZBkl8QDsN8Ou+FbljIUsf+P5OTcOMukjwUOB58HIf7
#VsIBZGQ8vIOhQsbSAYFtzuFXNiVZMlmtU6CMheb+9oAX9N8KM7H9q74IxXwpQ7ytPuMdQcV7/kQjqccjk+MrYn/KUaXOXBmtiDiZ
#wcgQJeWPwEFSnC0CM5M4tXoPFvUtKceJnnJCn3LOE0anPdjubOTrN0mj7YHfHv7GbZN0m3Vp7jZirr4mGVzbHV99YnSSjUguEuG3
#4i3k3yine8L8EZRP5r/dNDq6dLwbzX/4FIF77MmCFXVcqyTkiTjISnOWolKdicp72Nfc5geqpq63J0qJ62Nus+XHuD6qlyMAuw06
#Gv17eA4f56f4/n/UfIO/NFDFBFBClKb9/KenHw33YrlZNMhzzfg3qgDhPg8jxH+qrh8NcL6sP7RVHfX1eXKijp8enwopo45YMdYT
#LfwsEC0iQ+/uRgetYVJyFEcTcdMnMBPuFniLbuekXJaGbrhIJJcf1AeU+CRMPMcABCPx/v6EHXH3WWsNI2sphfR+3tkhL/o9AHo6
#ejy+HuHrD1pdWaSApZrL5j/2xfsESpKKZlJypMjSDjyHLqX3LWp7Rq065UGJbV23bHXM3Udf03FFAHPBT9ce7hum/z5InlMTjd5k
#pElVX7Yza/lPp4/Pc9aCWXpYrUj52w+vL9S+x0EKRThhTvqJlMcA/FIZh7EOHvpGl8b2dbkpdqCx597Y369GP1x6qZdIcqyt88bi
#2Jnj7ceybBVlsoQlPrm7BIxeOMFNZNQaogUP+daTJ1pr8boWmOlt2QpEzcyd2pymFnFCG915KzWmBlJp2SGz7NqSHyq3lWJWUMqg
#0DMiBp+jgC4LLqJco+CLyFqsjpB09BcxjUEQWH9mtlLzrqrDEJJPAcLL7/n9d2x/G3rV0u0VWrGag98ZEfN34Cjwkehknn6JNb3d
#47f2MmOQHpKAEX64gVD7KHx3faOpU7D08MiPhlzRibXzbTLGbS1SfOkmXIXgD4GcgHQPgz7LSV357kvRreHdQAN13IJNvv2vQb6u
#uZK9wN4vb374d8N/4zw9Hk4aCa0bAJBBCAYEwvvCQZPXhVvlpx43R74pfuBWp1hg8bF3S6k52kjKoal7QwAtGvvKsse9rcbjAewb
#4O+5QRP9SfIHyPdd4Kf6GUbXcwknaRFPwfEv1QhOXhE43wE66CUF/xTvvyeVJ7VySU9+U70eELwyvnAXxoe842vdda/9Cp68/W6D
#RMqb7fW2bG/5BjPyK+d7T/vOnnTU9y+BOIK/lujRIOfxfPrI4TXY7R86aVbvrt9Q949Q5u+06/jc7xq/Br/8n9Hz+lJy0pXRj+8k
#G388SXZjfoz2+uzc+MXd430C6ZTdwx6b7Qz5UJdLZX/kBpUnn9+r4U9Z5/RSMuKY0H3/GE0MLus69pA3+Zm85Y3u/i1Zfto5v2JJ
#8zsKdyGiSxKYJYkpReZ6/D6R8GEG46pEXiYzlxPHS+uCKVPcI08pgLX2FLBMD8uu7taN+8q/cHT1HG4CemtSAR30c/NMgnzPlWu0
#mblq6mCtnS3t40jWFvJ2KUtdXxKAampsbHDRa6BXb2/n4G5uObOoj+bBSJKc8Bitjn5kNjNrJVSP9XiD1XK2RI+L0+7p5V++r/yQ
#vLokyVUeYKW+RK/smdm24Rv/66O493UUoyDff5tA5eGp+4fqfCnERX/7IGEVdCY1gV12STYByeLWYGjhji8fSLofyAfuotUxhk82
#/Q7r2HE/8ZRjwAIeiQGjutigr3zTQ7qkcsvJ0TyNHdGIE91AyQreceOLhAUrs1p8MADuIH9dCDrxbwxI6GgFSKowEtnyEihM8Bgo
#TySSbHCgYbAQK2VokVMiNjDLCrsnaJfAenZt0c3+QIFMvpFGdVrrkk3G3XWLZXKvUPfGYKigthUpZUQ0mbCsV9vywKr4+02rc4PU
#6RFupawKJaF0nLqPEqQGsLXuyJNayzK2vHnsZY3CGjyWA9eKQ3a3didHJ0lDla3COzBWozMKbjbMCo2aCXbSiseXG7wxim/XUmHH
#boGEJqwibRWmphZ2Nig4S6M30dsIoTX7n7zT11YzjwSgYOPHoHvVjaJx/QeRSBXqaaeFa5/7kCSj0Wik+5SleU6qgcbYVX0m/3kP
#GDptw7yfbk9aBXU8iV66ztpFlAmlUqnnJDm4aPPrl8a/06llwn1o0CDyw2nsgmwh0Shd1g2F4aJBBFJAClU03ClVDDqDEEUxbMtg
#RriL29jSjHrjsLce+5oHMozy8Dyvy5tU+JeHTnojgmicR0UA65rSkkfR7TEbJ2Vm/g+0UCnjgYZiqy5DN++fQNaeJvE47tcK/BDF
#HJkyjPtG/Z9DeRolM7TuBTbI5kX1MsRjRQlykiV1fz9Mk1POiwQabs7DBmIus62LZv8rZhjBa8XMa2SbnDKNrLARbf4uhW/zUA2T
#ZqpMS8ehB1n2VRrmWTZK3edPzzTCsQyjONK1DSN5PxzHMKZx3PWZ1Juw7bp+Sh5OJMKu9ktsmxtqeljmcv3l2rUrmYK7okHFnoOd
#hKb67mZMt5ztxY3d8T7vhzlnb6L9XSM/6IBdMW6M4PUWcWsxe1wUu/r2SjRld3u8ml6fsOscy/+8MF5AxenboXCeWoHT6SWpJWvY
#qlKsDme8iYhBMpVBii3FJE8loKTWxCfPBJQYiqooQG4EFRgUlBZigoAEmcGkwKCgshaTvVVu2lBqtQTdharZLsP1Z05N3Wd/ywnM
#jMfiaLNH1YLb94uicVetYKojsTG2YmXDfA3dIMN38uou/MrkbPt2RHwgmDwZ1vaFWNp/8cFRIktp9YKjMW5uramdnh11g4N718Id
#mXhbbR1Unhhe96CR+gJ2qGq5oov+Vc8XvDKsYXJFM8B7QD1gIiDiKh7wVVQSGoymwlAeMF861AgSnpldBAJNl3S3luPd83wpfZdS
#pkdIw0AVZj8CrSEIsWKs+YIVCsqZj15MJVUxr0xVGVogn4jTHUhwAHKqluemjmrOH0UjuNzDt6bNB7TKKisTZ+QWgjnRpMrFq+sI
#4OMh1XBH/9gecfTGBnr0/q8T+f5P5v/B/2xsYWjtZEjrYOpibPH/Rfv8f+Z/7H9mYmZhZvm/+Z8ZmRn/t//5f0n+L/8zOQ4A3H/1
#BhwAAGRD/6/+Zw/sbhOcEI//0j/TIEJA7YmMYUEH+/x37XO4y39pn8nAwyGx8RRRl2dzCTY4AL7vZUMogmKBEZZ04oq8mg1e/8JB
#7CYUrA38hcpI5ASzZY03oUUkpaRqKEgtZX7Silt0PtZg7Kb3HwYwbfLf8hZrL4wdKjepyw8bQfEEYgztYnhGbiwD03EKG+WdIota
#P+Nr9jwDTgAukAOMxCsUfA8DUKEmoTQo1FrWxVnMm73TpyVBJBNQ4qAHWQSTD5RQR6jwLHKjoCojgH0rO0BrNf3y3Jf5u5p1MLep
#CmeZLABqFfsARweBgbUx7xzx6SIKQMZrWFv5kZjLKjNs2zLLGIPDNaGZwMl0p2cIfZ7Ba9rt35yPQQPLJVmRNQRkQRhxLjJz99Y7
#UdnEGVw5GoxRWC1lQhuRu6Rkgf8gpBmLl7KBxnoiPwRlumnPwBjn+VuedNVJ095t+FIBt9v5Vtc3gSsYoClGikgpOdth4gAB3uwE
#80S+YaZcYGxPt3p3XfzWCq+IjUMPUq4ffnV//+p/qmf9uM1P5d9BFGRXsgUEO/z/XRGZxObM5cKzf8kGkisXaecRVcpPt9dhaWCY
#RDJVjZVMnf6prKKaR9D9LHVZ46etNK7QavOQcTu4DxweH9cIMaKBoled8A4pGQmlNnFTfg6WttDi9ZoRLUtrj9lgptH6ddO+fV1f
#ay14H6/U2J8kEM/6K/fD9l9jW17b9xNOJIUREDFFaGAGRWz87bpy4yz/1H8xhE3p/kkFyAIwE6DRwKDAxBhfRJdI/CYIYM41n3ix
#i+oNHgWvxI6/h9U7Hy5NgKITpuM2mggVk3lUz6OzAZVNtsI5XimXALz2gp6SCvgX5LAMMpAUaKOSCdnXRySM/MGzoJzl4WtDmhR+
#oOngdTiPphE8kAoQRj7rxXCkE1SgyqscWZpX/gopgCKwkKiC4QOSUFBFbSubIlTIfT8398OAhuWfhyNGlcLUW70skqtk7IZC4+jF
#JCBceKnC0PMBf8ScuFYaftoFhet5blycyC3BuXvDtv9lzmq3t9HuD81qHzfWuZ1SZzqGXRpQSYxtvEtrGk1mdGb4tlJsYMAq66MJ
#LZGQ+eGn942Rbi3B+7YGSOU/69lvkOYODvkRtvK7NY17+7TyOmyEL/Lu7sXVKWqHlk7TXt5dvtlauNqy5juag/CVh4qu0oiUnMMV
#ATslxo3M/1OQQ8ZapwzP7q9+NtZ1MhFnFbJpAHr4CPh7aZbtewqNl7p9bFsfobvg/6zSgu/e17VzBS7b1r00ukm1ivqeu1KNDP3J
#X7qyeSKdaZ13i5pJsE6ywZRDKjbcgY9nmAnMEPF/4sVfTmAfaT7nn6jVAfxIspBzPrAASZfXmb0kfejIS9C3+1WC7AE5UPdLJRPw
#YfB8pAPoK1W7AjUB5eTbsqGyC/D2VNOr7iG0l5iVYl191NnBXZBawuPDV2XnnCJ9D0phm40pNqWK/Ss1y+woij1mjdtZzst0F0pU
#zULy8MU17t1RKsTefe0AZNwa0OePM0slf8+/Opj7bV8XVwfmmudhjr4/mFMeiUPkangEMFY5eJVbneUiDNK9IEJnsFvzpQRwhTMw
#dzMzd92oBObwfXM58DJWI01MwuURPWdeldFWtVft1XV1qUbmwU/4i/udiiI2RmJZmvDIFEBmTu2k6q2ZUpUxfyX5+hQqEW8bXBCG
#dk32XAQcVqi4FTogKVOWcxI1/OI2adoRascnxxSFOBwHno/MVUlEHWRlcTMlHcYkNv8g/+aVOO9SvSHQ2zeeM0A9KVwJbYiNzPZ4
#ZL7Ow+M8p/8Z2p84yAkGeZH7DTsF2DIi1LnkyygKJyNYOUkTPvytyjCp1kB+qHTQso/Hn4d2doFEnkviAaaA89AczGnANpNIIKkC
#jNWVdQJZxiK3KetJN1SADX8WXnyzpWQNnFhl2DZr733lvmggjuM6C0mWqwyGlMAJS5kJLFbg9JNKKwdwGlShS0lqUSbiSrQRUZRi
#aS317zACE9OoQclhwSxpOoFNgKdafL0t7boSK0vnQ4FKEVcArFqIl3ophwKuWCqgvIFhy+mVkqqAsiCOAYoBiwJrawAZqwJEZVZO
#tE1py2Z6VZryk+LgIL1sME5QRqlebuCuZoD5p0vVVoeiUqRUq+NA1B8JDTtjVOEVbHA1nnYIsCh16AoctIrS6NlBaGGz59REGC8w
#jhKoAk2efRNstO30NOSK2zvX4GqkyNGvMl6Vg71WoDrNU4Xn2CnKmDf7OHA8DEn6Gzv9qSoZRnjSJYWQTk6pegelYUiqVilTLTi7
#+dGUOZi2i5Y/PhKe8ooaTI1Oqpc32zWV9LA2QFxg8EI2K+U7lTjhNCJjB07v2B5NMACqniZBdxYE7+OHgreWC1kqUn3LbkpzKbX3
#rVINbumsEq6h6edDKVxXDFQDF6NxeSzvnVM3iNrFr1qZDojD5XlXilan/Kdq+OsuxjHTHom0GMaWshzG1kJaBj1KIvFWgiGxIuXN
#XZngLFyqJFWUBFVVURIlVXUhML4XKUlCLDWxKLnEJqUmA6ya7Ub55Ue4XiOZCPQyxGZESlwCIq4kStaB1PqTtyiXs7BX2tUl4344
#IljSBEWv/usQ2jfxLJlQlMGCOTW5FBbTAUJZVCGGvDufRzT4cVp8wJvzTmjt1dOL4b6crFKsOkjlvNupFUtklfzIFmHQsLL+SlHH
#RFFfer981lx1KhbHvb2ui2woePCPrvEhwdOBEAKFBiylTY8SQBYyFZ8Ch+1i3I2UZzo64O1e4kK8aBdViyuPz3jSOnnxhGN8A9rU
#yTaRGy+v2BotK+U6poYzymmiGI3ZKOJnSwAgyFTs0OEay6BKi6qlfZvqGqlu+Yw/nFMzt+FipwaaPBGNEn1E9y0BV9Dy2P3JdlNw
#3dW4FkGawGPaMnVo+AExq765PtvE06gffAmdNAAywMKIzGHKj0rKinx8vKnidFReyYxOpZCoRvwuM/sc4SFw8eyMPDNwwWgY5umI
#S1/XUey2ITcJHJU8q1lFVezoI5XDsVDFmiD6noNUGBSf1xqIs7uLRalTTC2NkZU2Hr/dvZuwNws48gRCxwoqD4gTEk0YFlr4aCM5
#SfBn14eoKiIiQjKhJIeISlJRkNF2IuIyR4ydV5nIsjfvGHMSMOYEQMyJBtwZghhjaBGniN4v4CpYFsLOOsk789pKeXfYBX3GIRbL
#3cgNvPuUE2VBkY5fLvKm68ivAmnbe/KHAfzwwsAJgghO+37bBqHlXYe+WE1+LGDzNl/auIEDxo0kqeXTJ/oDODu8Ibf0ibMrDrN8
#qyS05wvwSIv+fVupk6kUHrE4R9bXDbvtT8HmAlIQwN/zJE7a4xlfwiAq2vK7HYkNB2Klx+OpkrDv+x26BFWUXrTKZdPpZCq5vpbv
#PyXzTMnUBf7iMtm+0cAzcWwEeGSMCGunqa0giiGF7IsqGRGXGxmr/hZA1F6EKqKumcQYqaIEzwuJc/IbIQ4BnKqqCCjKSMFgAOi6
#Q8onEvGREk9CgAgJISalhLhZZu6UIN2jk2xiJ52tULyIN/l/zhXtoscGguAMfhix7xx8oICVIGGUQgxSStF1JatqZnEHriJMVASR
#gQlWaaRk9BLWsyNTJ20o4KeQchUT85CXPFMoes8hsP77IP+oaqmHKBBSYohJCQtSqYt0ZpDNCQG6p6mh739zJyuqwUnCjjLA9LdU
#mpjQFuuR5zS7VKwEYLBgNBxsmQwaMGDAgAUKECBUgC0lRv63mZ2+Vdm2LfJLngZGEnSwqjDD9yZRiqGJGKljNqxqODmH16GDt0gj
#PLGnIohQkjILBgNBX8aKgX0zGVVTqy3TM2zf02QUJjHycN4o2l6DzMcS08nEh5vW2xNELirqELyYhFX8RRW2eJf+g5mx00pJfUj7
#s6qtM5TmRCe8D1lFCzhMGFnHG+heRVXtxLKDzKFSyg9LqxBUED9dGrKWImBNCgGD9knPoYL3UIuvswxYhiiZgwzoJA4CADEAxivA
#CFfqIcOUrv01YJxgIFGCHBEoMKuwKgg12XL5YO39JsivSPyx5Zs2raE4atVrwuzXG3q1n4fkswFZB/DLGKu4ZM9pkruyajKDKzy1
#9LLtLMCx4DDwYAABQKxImddKp+tJ8670PYHT+NoAX1/bwCAyzGP7/nurT/Oxrz4iiRECOT7KIoH7np5FFAh0c9NxQODrNohxcaSN
#N9EDCVYgnCTod5H98Ju0+2jUGPbtiZ4GGnWp3rKiJBdZ0k8zBUixwuQu3+qDJSNPiwoYcJv55AnprJNCAXnQdvlGV3EZBeD488DJ
#EfIYVTMZGSCm1/J3hXn1rz4EH3ztfDoBMpQ+HQ2Qdr14hu2X1ja63jJhTWrHVsHJuZ9T2/khJ3KjcNax4japWoA6dWM5EIiZDv7J
#MoywoCjwNRCBQggsMIIDDNiINRVNIqoDN1aqvEM/DE4GAM+Jv52+HcLXNpx/EXEVLPGis/3fT0iIFegzoDnGQ514ZmX3WCyQcmYt
#92Q5PKQxQV4NdoQP73+kDJ+rEeYnzRAE/p5IE8CDA0DhECk1p/lvyB1ABgZlBotjnANRPE66eS+B8VEQSQYQs81CCpA9B3QekFyC
#9CTQw6G5i7dXoIvRFm63UtWoGZIIQva9w5l4mSrvCARYgvDN6Dkg6dPLUIv6S8/0A6EAXWAMjT/1n/X35Y47IGP6f12gAfr5/q83
#x8DzWnmT+NDzO3l5fiG8Uxe1vk4g/wc77xQzXNC2WT62bdu2bdu29T62bdu2bdu2bWO+P92ZTjo9fTAHPSdzVXbuSiW7Knunkkol
#KwuhH3Hfij8MdNxacyjlVLWUmd4cVfxuxuxv6yQQPJfDuM7HrXPyuh6ry7Z+wZZ9p3HFmASSklMbDofTcdSZ2KHsgFKhHqGg2aVQ
#ZIk53HEeL2z73zZ8g5IpEkJifGKC8tIi4XmCTGSGZnJjpUKFVAvXV49rv665reMs6Znu6yzzHi/7LOQbzsOgfN12wzyRPk/Ljjp0
#9L9FqqmaVljZ4EEkYweT5Ot1ZYeSxVBobDxvj4fTuTFXX6IQSPQBinGBCrPIsbEkMl20B/cv3amS4kTgIBSGcWWSPdeSyRlD5dJR
#mxaj5K8tL7S85Yp/g5QtckIKbZ4AGMCP9AZAMl+I6a7kDJuAy84AUOUWZeCEQIEGGI0GZB0t5NYJAz6qu48f0DnUuxEhc7GQsUY9
#p5carsn6UylekucWpEZjpRZ9eq0uWaYZ3ie+MfMxCfeIgEzowUuckBmxJlGRSPiBiLOaNrREW0ne496k0oyAB+MimVnwuivNzBpI
#7IvCFhKKEx2zdvdC1EZWrtukVNAxWUsRikyeQ4EAV0ifhd1w58eW7/VKaUNR8Eo5qingvUzGLacFFcs2qqjG2AIFwncQXlHcubeN
#AAzWmaE7LCuaKqkBYePMsPUI5PNYyO4pUauWO5wjml3+rnJcSr0gLNVExLP3l6geXL9y9X4MIBVFfOaV0UexP3XligF/sAUP7tjo
#oF8FsRoiGqy1pqoHTsS6oPTdsfkuNkJV2Ioarjy73HlWUaGF8iZyjqWTswSkgapnWYVVk/rkFLtcojY2aIGB5ezAVg/NQ7JgRFJK
#zbVX+QV0zSYJIQOXOigZBoUlC7TFml+0/3TUVzm8ptWcA33kTqB9WO6lU3O09UfqUvro1Ae+ZT+/GYxfY/FGO7omLkZk2KcrrKg8
#tVqUjkgSjrmSYCLA8aiG4qSxsikMdoM8f1yTIjnh6G0XP2kpXFsCknRXNHsMUVRoV+rkhByXIqFpCmaxKdoEz68jUlWsVEecTb8x
#A1DVriljPMq0Lxv0GeSSoZ6LVJSOAPb2D13HLCOtRaAZO6GJeMZmP+GV+nRSIt2WVg5ljizGmj9FhCMfahbX0vrrn42oJVIZiIxp
#/srnk9kzdC0kA7NWbxFLs3pppRN7buiVb8s+tH2QiI3EXB+oQOLvzBgN7CoM9uNIPyRHqvuZeUI9Iq4bCxJFv9KAwDWvkKAzwcxi
#uOfsvHkKABlrwbo2GSMY5PEg1iBC+kRTZZyFbNEsof/h6B0jalrCp/WO62S/dv661XYCn/0jvbRfaZoPtOLpYZnHsgjvS6DW9bFj
#WtNwOpt5hxKM5B2H8KqopVG0dn/PnVCRvNIAJaOOHiifZo0F1FYwxl511sOz9LYMQ+VuFM2Jzk1vpo4yjgtvdcQPM4uL2meDBpvM
#dbmEIAdK0ZRe02SjcpYLq1u1yPqkNOM03O3/06Oh47SX/HdiYJ+zWOGokYUe4ISZmt99E+hlpaXhqjdRLig43ycILxlyyBwcrGUW
#Sc/hS4mauonZGWTD5U4VB9oC+hr4IBafNZ47dQoO0nvyXGqgEH8+gxLRdxMYeSEjzqT0GCAkPDKKBRKmE9F8iWnaY9VyYDTBjjoA
#24fnrlMVVKeTE9M1SbkCnHjWF1y2nYqGL7KwdBwxy6D66nRaBXqIlpytWyQtZQJrr8N6ubovxUGdKaLLlnl0APfaWcZupPS0RtOb
#SeTHAorr94p8U/ZqFcjCexmA7DPA4Qia1ajKEGlHhitqbNkgcThSIcswXE/jvPrlKTlSyYNDRLOeN9uVCr+GLLvmFHPpMW27fSgX
#5RzQpPg5VYx75o1B1D9MJ0lEY757CfZzEWQ0mltDwXK4tV5Mebb6oZNbLOtdyGxvGzq8zlnzq5EVRw0mQs0o5kMx0+6FNbzWt/qG
#6q0VvUYVYzMLbvvU1k6Kh3xTs+kMY1yEyQPRtsRzHnDGiUN9tIob2yC56rEpYi+OoCE1Em9CF+d3ozN7jEJOd8YxQCnmcqjnsOOm
#31piyLTaX2QHG2sLYiXGS7NKobdSYhhuLt0+QQDWML9veafzgbZcYjEfQ9JRUXvQDTj27iHPgb2zrl6qfC5SSploXeGWTkhS9yB/
#y8MmbdvpnCgrbHxpb/3B7uSlVzwpJHPI95GwSDCTdRbMW5lDx+gDaSo3jz9FbBTvYBYmF3l5KUGMo0Z3SQ2mu57E8aNsPy9Aw2yw
#okeVEpT71T6qZrNLrihRFhzpJWwy+lYTJ7rgoF+02cVzGNQDL6yNSg7k2BKE1ak14p941hHkdCLkaDckvPl7xXEncOCR6vhk/xzF
#FfdRdcOf+LeitQe/1x33pf4HeV30B33E70N3Jj2REOhOJekhViNppQos1oI4PCEthJiSt6e6fZ1xB/eRgZe32v/3CL+fykdDK0tF
#h1ZkGatnn9W2xggbsQZOPqC+zhdAJubUHtzC1QFV6A11XqQsLYVtCiRm26h1Z+2kHNLtshtuyAAcZTqCjQK2Wlpvqvi+YDZymifm
#Lp/SWVPuXZxa5Versp0qygv1lIcDSg6GqDBK2mf2e63ZqfXARwA2m9El+BDpfixEAwodkJ7Z2f/Oicbz1efaBZYx8VzZfrzoc71x
#5voPwhne2TIidCUD5jHp1WH86+dA8K9Ceu1uqyntbvNqq066ecVi9EvsUgc8gCs2pXenAUUA/4pwCinX4qCjOFXz64cmTPmHbbcd
#nclS+XyabvVIz8DNsE6D0NdGDe/0lXkzNfwmy0PjQu6k7GeB028cGxajBa2AXzIROfYUY9trB1Ew3vUGfrG/gRi98W+ubYCZxb0c
#/JTsX6q6WJqvaJEAQ7e7M8kN8EJQ2HkzzduE+7FW1LxPgkQiysHucSwAMNJF2c33TMsyJ0YCLwQjwiQZxjJwZQJWdPyYgQRA1EMo
#j4LvUDBAE9QCyp3PHQpJs9aGgfxJzuwjb07KWygTQAwRNKavNaYT+BB7niBd4bhb6J4YGOTP0Z2Ts/r8LsHTHaf80/RswmyC2TvO
#z4ZhsXsvytz7oqAwQlF1xH2LFH7l8U15yi8cZCRXCJHCwfbyB+kvf3AuYTONeGmymz3ygdUrcCYBlhYegXlYUuzcctHZ4BpZLXUl
#f3RZ5SAfkuuZSU+aEm7y7SiMvfo2HOV48NjJ6TX58/TvBchOmru+p62Zcxt6IiSboPf8FfPDRG5N7lp1RrR5LfwvgO26m2oH8DsX
#7MJ5SYAJr3IdP+V+7Ch9papUSZNy4HgMlWLUWwm6XZnDkzUC1pK1fTb2B3EEFRlvGCZx3JQ1Ck7mYNLYiIYKlmNW1mP2iwDTwOIV
#8PNnkJjIz3nxhZIDEUU6neu/jhKDrfIEi8iWzZbDSKELrIlMOJzvPM3nT98MFzLBruatHmU6ruo15pdPY6WIZb8yuaeet5J/tXrg
#F+j3dZBGtJJ0I1O8xTOj/QFR6ciH5A4FBRi/OOAPTTU5jvrcs+k8TQ5Nen1AhVmyt/6uD3bV1HoOpRZXST58olW3M71xwG6AfeHC
#n8wtakUVAwyArZAFpu4dZf5ToplQUioa6SrLFgQTrOWuvGeocNch9/16EV81XVkv9+1ZKRYH6UlZOWNU3iZuxXa6F7hbJ3CQ17ht
#e7C/8PFNTWvahM+5OdfyFz6fZQ27xMuyHMW9SpVLcmFHbsY2CuPH4gd7J5CE9iC5Qm/dryyJoStYF1kXnEVFUSOo2k567fh2EwLB
#UA7IOypO/U/GsQNe55xSK38lq4OFmBzD5Ur39EOvISVi2wlTthXv0KpGjbH1yeHaUqYepfAGWjW3wvwdqlooH5jKFW4W3PxWFZ2S
#C5nnUJvVvzIVigodRUyo4NgJpQnnXM24VSVVF7dIltjDV2lHqHbd1TZYvzo55gzVgKeYmX3je70QuL6p8Ed5FyEvvqmf29+3vAkr
#V9i5iKLOP9XOL/cz28B7uAy4n+1/JRdZvC9eMrp18L1hb3M0En9qVDkR8u7tKztF5KvPCzsE2h4w7VHkU95FjWnStXM+Uq9Y++Ex
#uzHvYjEqyrUr1cjqKpVJggRWdGoXWyU3GZgrWjUoRp1p+X5+EoaUfsVGjQL14v6i4eumzldL7kdaGsiWCPUvSmanDbk3dz/gA9+r
#H2riVcCHMX7YMUnRTfPgnH1Jfin26M/HzVHObZYndCCO0JGQlK7pUmJYwUIIWhaLImnjdUIwSkUkl0Qt+U/dh97mzK6ZUpHpMj22
#5Fs45giRgZFoqrxHAk3qFQp0AnzwmUB6pz6AiBJBiRVPyUsRJ9lpc7vsgST6xCiQD+c+H1XR8VA+N3x3vaTjnv4K+ELP7E5vfG9a
#Na0LsCeDjiGRT6jCzFCEmLrnR2/XSrzfvdDC/b/N8zvPCQNhvrQLPetP803rsBcSoRq3SbdRPLv0ELz2LJ2vfLyn3WpUPm/8h474
#DsI3crrVjcFJLZrAQncPE4hgmyquYHl7KaPiaf/AdccSB7QTCwvE0y2Zh6yarIY4WYhjauUkj/BPn2h9fEosvdG7x2pP8EJ+gzQ3
#aArIHE749jZpgQnFBpXlo+li1UT0vZIJHs1q5c/Ynz7k6nHgOhmpBXcpBRGIWdmXoBYXPeOpwsuZ/h1A39hbemZmGE9vyB4tVjIL
#CNKWSEAKUi+x8eFIniNv8kYHO4B2GYodIHzXow0y59yzHuy2OAgn1vzC2EKmVVApFrt3ZG3vKC+obHT/G+toULNNE5v6bQZDXbgr
#dh9APv39Be5KwqfVxNum7io+jito/bzlFfaCsanIGf/Z1L8J5DJM/zUfSFmc8oY0HJkMrr/zEMr91A6MTfCDSe5r6j2pegq5izCs
#/gYO7X7TYGb3q1WosnYY6QUzjk6c9BELMjlAl6vZnxSt1HByNsWpDo6gU8plaIeRpkSqH2iLjLQyaULhpzCbsDJw9zAgmaZDpgoF
#M4/a0KKBKJDSbOUmgIb+hQLa2WicdD6Vg79G3CdGYVkLlA74i3OMK5H1lV0cM1davPvuxea2D5iPiGgcZodNCtkxzqmGA+MilSs/
#Dv6oJ0isuUE+ZQ0ObRr8NOqYJtr/BH9dMjSOoq3fGzh35pAZeFaF1rIN+FIeDe1DERX5+Xa1o8MAYTOB/sm1BswiEe0Qdapil8/N
#y6Jv8CYFijUW6gJw/t60K4IMWa5LrgdCtg3jACHifj13ItZZ2CrSVdwizD5gxIiUTiZNsTg8MP/T7A147FFneHHXyu5KTfrH+J9T
#bHFf5ot5BjQXoX3oitQP8TdRVJx3bybWUsKGTo6KsmYK8dRkwDIwqdnrYpggfjIwM1gKlG6Al20rJ/Cbxkjq73iUV55U/gkUCiud
#KavB9duVqRNVc6ue7fe6Y7fRcrxn0CetYEJ0sGm31na4lW7jw46A5bb9mkMGunELd+a1dLqWNS24a6aBTyZPYz43Zi6M7Y+fLRoy
#wTF3Ghj2Dqv0SksepBVvgP9b1tsdTjn3K7LvoQXZXQEkzPzJRBdXRDyN57JmeDX+/WjxyMF0WIMUGf0yoTAC58LgXR4ylVlScw4a
#N1jpuCjJgh1zXZIovfd67fn5hVcb5Y6SlUUpFJM6O0fO8cwaWNHNrZCJmRibTZd6qEXaishLnNusR2XgGUcX03B2Cs0lIg2slwZ/
#6EjNkgW8edPMHgYto3x7bfOzcOZhrBJfyxyX29XqMoP5Ykj77Z/hAft1r4KqaRJvEX7iAqSv54toMB8CCH5Z292lzrXH7NKDO9Mu
#arAG8EltD+Ht3c69h9jFFOc+cxxrFfh4FqssG8+jq4tahQq8ozqPkdJ6YH11AV5Hd8mkXtdT99fzIIPgcIh4uaGkhtw7n5mgRVtx
#15b7PPaNxeiyTRcvyNgcc5JbHh1dqUBU2TgZZW+NluKOAoPqqLZ5B8Gyb233do1Nxm4WCVodWOvs3qRgEBqnGc835e+VJGv1cjDn
#am/DnyOS4Ua2kA2QGgfLGXuOkN9kGA/p2MmZd4g0mbG099yE4ae7MJYf23q34PDLMO5mUCjRIb10XAVxWgSIJewv/yzRKMJTyBsy
#7rAmEFoLddV8ZMnq5OHneo9jz/VOAv98G5Rwc/IGvpkp27QbuiF2MsIOou7rMZ7ohhOsOqL7RSEgs5JXvPhuVTTmU9km5mvF08Aa
#B4wO8+HWkj5M22MFZKyLRQ46cSQg/kp1tGPPtC9fjq6uXk7mRFSil5bBTa3n4NVfDf9UFw9zZ9ACm34bVqsBhGwnR7HkWnGEboIe
#6/3xuYVG2xVIPFL7NWof4FV8v4kso4MhMltYaj2jTcPqbGqcWJOu0DASUbroWRtbhdg6jlZ1glAHL827XBIYd/rZ5CxElrD0ukVN
#TmxAjkxbcDipSH0+czADRkPFAZy5QMhMQcmoFH61XcO/GoPVC1lH6CzhKNbCIW6ppaKl79MPNLZZz+S3+qgfWs+iDnJ/oOYUK6j/
#Nh+Ot6fyez1n83I82E54fAqQBaY8G/IxbpMm29bpus7s1G3qDuztdSDoPn/KFs2Jjy2dtLU5b/Ps4AYD6siWSPbL8usqp+YJ610v
#Npps0S3x+/76t7sG2jauIkqXqPFGrwkDmL29dmfzeI/s+/RPepWibt2ozz7rxaJJ8dxjiKbOfDNrwKZU+RJkY41/p7/5d3RMdvTV
#nC0wRh0Svy+rmW4S8x7+cNJffzg2IN5F0pr/JSVArCxgOuzla23gxhrT1nWwOsHwJpoZ+9Mz1aNgKZp6mvpJ6S34+KX5tny/F6GX
#+WHSyUuNf5iXFtOXlpk29pJdY5bDElF/qfTLskT8XrdJi3WG4V4lN0OgFHRVz2R0+tQjSgQnTd207M6/eNWUL+DumOpHQPrETVc6
#bJt6wwk3U8kMgEd562q3kAy889wPf6y5M+bILVck2EiC934gcxXC+qymkHdFWgsvA/Ab3CzLt62N14CeEOpKwvza0sfENBtpqgaf
#wKrjBKY059qoQFt4bGeyh/6iH/WzU94t0sRPfgSE+5GNU3zPKc4/C8YHuP0s8Xlanl/4lumyvYemhfcdUJlQQCA9vNPuvAveh3/o
#7+1scdTgM8LT6hV4JM9qW2jrmdJqPtD2obDS+2KKTTTkCRwaGWtc2MAOhJ8a+vFnB/KoYPon/hYWyl5t94AtR49uCQImQchiv2Uq
#pEJwGoaG0NlSw5hVs0pvalP1qXPBTMhaPRgc+soPMlUaRF5to5ZSAmKiRiRCRJxxw6Esh9dQZYkHSSDJJ28X+Mc9y/Ikq0+G1eZS
#KfJ98SloMvONExS3Jw/78RB5S2pjozAg3hwZ9n8mDCBquIM0ox1mif5dE/z1roB8dfHqQjaEyXkLyc3blKMWGzIGbipqPpHJAMaA
#BQTSk8droudLfnHdYIMVPByQYfLAyI14eTQjnNSQ0SPjs7fr0ipEmWbBGzQkcRMyjSHLSfqSdWx/Jm8hMLBu6hJ3Vpwb+hXV3yJD
#O5gHQzKxz7XExsfqBH5LyBBh0RJ4STDAu6n3Vmv5JXyqtbyfkI5AvYjZox19XeRrEO+EmwwHY8uleLFev/gEPXvBr+4JvAY6ZOQY
#Flb61FzKD9+mIC6ocqokkIUFrC92Gn8uz3bVCjNDGswoRK0wJs1spf9UfHjI2f6aaFQvOw1qlATpCTiFQxO6iuNpiH4k9LOvPtM+
#hqiJH8bNBhtB9Gm3C43c10FKMwwgMKTRSGLHXx5YMdILk/FZjAC80/ddQQ5PRiBkTlchAncnKS7wCBMp/oGMCGOMlwJsV/DANEgh
#4eCRxcVYQp9Am2KAmXm1gTVQIlHLgyWwiBUbsZFEAJ08YsgmFQnwJUGhUYHaFLSpVYokKwgK2fUGINBTiFTOm1AexSSziD4oXrQ4
#g+jbCwPxFZRX7LeLgIlyLEebPMWKXTiLGW5O8TSQOfeFMyJWogIpIruESwiyexD85dKwajPQwyA/Chkv1F9H6Zqolv4wkZk3BgoO
#ikppDiOte77zLKWEl5yzUIgZDJmsv1h9EWrVrWEUAxC7c9xVC3WhbhjzyetFyj7nxiWebYSzy+94+UvTdR1WCggGHqkHjqlHXmRe
#TW7X9+N5XbD0UrDiUE7S/udoe4W23cLWHJbwRbwpyqoJHgGjZEqefG5zWS38VjhF6IeI2GbUKaFCbTyC7xiG9PdWWjGxWq5Qty5q
#6GxeKwMmTfngmlrJXwA5qrC0uPi+as+N5baNabmmpNAnoNHT80JJEyARYzFCiOIgEVQiEXYySboXcVg8WzfH0PeOYSJmYiqqJz2L
#bAO2BP5n9pcpFmlEDideiE4i2l0fbdYHjJTz2hcEx3kdbttapSoeHBM5IYdYBqtMM8NhktnCIZV/apYAlEUKEWtNtGAg89/ZVX2S
#yN3faK5mGQhe/dMqmelimdlkGVkYZx7HOR3JW6/rX4o3aZJH9J5y93mHBksDUYhAo99Lz5qWLAwjxCmNkfUiefgGTkYNQsZRjdEN
#vYDS5cUA0jmt6DTpXHOK1YSh9sVIqWSesQVP+nbktyqqpL+6KQsX2m40zuaCSZZ0QC+mAnFe0sWiX9XCcTZG+E8c/FVCq4X5wMlC
#AwFCZYVnSC8NN1Dn9Koh6k90P02WNsf5fF/QkKBALJKRoFB+3QQfkP9zCN7/p/lf8J9Ghk429v9onU1tLWmN7e1MTO2cTU3+OwjK
#9v8GBP3f85+sLKzs/zP/yczIyvb/85//J/I/+E9NbwDE/6oLxf/pY/4/8p8BXNgNQDgRbv8FgKJBBBBAZqMiQkAFFosEfJJBB5P8
#NxA0XOS/QFA08AgAmAA1bJYOUpsssRk78HwJZx+MGbF1O3BFJUOYWJhhDHAGZjnx1z9z0hRCOlo+WQwb886iQE3VksrArwO5N4OM
#IgcGi0t/mey0vfOQlOVIHeS3q5dvbH4DbGJiYsxpuJMXUWV4OB21R8Cmy5RN1B4xyo6CgiTm2YCyh2myd6euA/ad76RCAhWeJFSM
#yIkxq+esL34ob6Sn2tAvKC8sOc+lWXEdkFFa7+VsT4/fj5+HP+Nan1ngnHx7cgxC5gBVG3pfyp69crA2v7tfD187v1mfu5pMVA68
#otHxBFvlWSmmaovqUXtFfXL9Bkaoonexl/2/rxLuur8d2f4xzshSbpbBdjMWORO6Hz9+f9u5L0AoFiVy4WJOk6gVRpIgYxYX4cjp
#F8Kc1T5MQCwJsA2aGJPTiKP8o2p27EVAg6Ub15m/bb0gYO+navA/4RzKHBwS5Es5JpBxx95it5t62bmn2zUaE2XpQ+43pXyhnGyu
#wt3XOHHWuP6n9j17cy+qvR+jTdE3oYJEZFikAiO1rKc7PYiT+8rLuSuzuzr6q7Rha7uD1hZnzRuTIiIwXyMFEsgia0z+Is7caq3v
#7FzSl+BlPMUAqP09Jt1ZMAh1zhroPRRVfzIBg6+/FfLfIroTQynNkLJfoA1QqHyYNafBT1HKs22GPQbrrFwcvFy2l4CuMBwRfwwS
#QdqxAHJCB41AEAmcQxJ0y+bEThOllD0267eqCovPNrnmHbWPnIiVSqeevAzVFV5gnrNvolVCEy2zE84YrBCgmO+2MdjejX/cfUX5
#6VtP0aDCTBrRPsBrm65Pg04O0oEE4QYLf5t3Y7OF8tIEKhAp8SLVKHDNXmdhgRcuMSJCml5N+iiueb/LUaFNrDRVIB86PkXYNIWg
#mVNQWsotH3xljCGIJGijgJRP9pWmX38wYkBsQFPSgt3jXc6HHRYiUnCafGXSKTna6vh/fwN5H36hAGD7SBiJWmK0EFQE1c8SEo9D
#MPmoAE5vCdvD0JxBkjKLeKme3cUxi5KxjKmUKCusJVWfnuimd2eTKT9xprO7XeJb87dlLG3IqIVyHJ3VQkVFdaQHZ6aW0MzXuLqm
#lLaWuqCalfEYa12RhZYqqHgxYhTw33/Olb1f4mSkUoJya6V4cw9uwA6QUhQ5AvBMDNp0y5u5Nvd3Vul3ZTc6zwgiQpilibCaP9va
#mexyMrGkbaJsdDsEaUSXROYmhMFitc7fnl68r8x8EDawdTYZmUp99jrGZkF6klelCeH+eESmCS16zH9j6WYzR//mnlc4ApFRnuE4
#QGzv4gG0AcwE3dYR8xEMgEB+53SjyPyHcQhg0ZgeQ79DhA4GCyQkFbBtC+AW82F8Cn4fC5BKFDoI5xmG8hHFhI1lhLYdwR3neM/9
#3grC8ITuuoOuCcIJkPIHCeApIKYR7DCcBiUpdfvvz86EJwUCwVy6/CmiezgoWGZl12CoguZxfUvoQPnv4krw4FfkGWIkB+XwQcwn
#EKeHFE+KpZCygSB2VQy6mpbCIOTLAczsYJrfUoA2fcbyac2DpLoCJ/5dcV5n1EZ9FkZ9ikHbew7MfRwR4YdQiGHCYcyBH2UY8ABH
#kwc8YDDggTmu+8AfEKBzSBa7Oh+CvIATY732eAUYvKMO3vufqrIgXXIy4cg07b64XYgou3THYU1b+GztVS5bp7PIWGkPvdiqbkWS
#LvBo8RaZ8pHJh7VEqpmMR3yy7g4hWUt3dM9kDreN88LY+c6AGB8vh12SWQcqZuaq+L0Ef+rhX7ny1ny5dmWGQC9YPo5ytaja3qTc
#qXR2rK5COUWFIswwFi1ZCcUodTQYSqQwltjCVgKY5qZUnwt7aLRN3sMRYDYgcxPw4GOkxaV5xTeW0KtGS0HEIQB94/rcLL15ZIx5
#OknbnUrNnpjEHhtUPsXdc2/KjfXik5kaUzXB0NybXv025T9twH8pikPRiruaQkEsUr9SSj87rtv5fw5moSAYPPdN4cVUJmiU8n+U
#wcPyn7tEH8zpKpPs9A7r4YqfT+F/jyx0PEZSA2DBiAZ6ZK5T4mOFfiog6Ny4An3ny4O/9iD7kH2tN/TGVBhDJuj7/cumA/C8osLY
#Cufo3nUH+HjQ1etNUFoKB10xtIJ07fKRUdENfb0rtDDJUp8nOz7RVQTgxRJfjDWTnDDp994sHm7BonAPIMMvG+1gqIH7J+lDzJko
#nSmeUxNpeOOAgyjJ4LEjryVUGBYBgMJYKjIeZfy6HJazGMP7lNhYkJc8XulPVLMD4kRZlGv3XEA/hDGgUVpP3dV0l+6bUqzc4huQ
#2GZcbEGsV2zgKxOdXW7OFr5z668jUAItQNgQ+w/wuaju74KDOrPSvH/TYBs55L7gX/uGCAWW1NwWiIDZOKwG8JeegmHQOmuLsX7s
#foj3X5TDVVn9kggeAs90dZ8ynFqKCVOwlVNAznMQiAvukwSSCHYAtAnVfFY2DFx58GdbpXFi4JShd9L22MiZBB6fR1nrtZLEF764
#ZZl+FAwdv3uu8ACDY/qyhdgW7y7xgF3HMoJLRBbC+X2jdVhmrGCg+4oxWYjUmKY8TYxG/uDQigmCbKCiWx8evRtoqeffx7st9zcY
#4HXQMMBhleJVvVia7sp16hYEcuZ8QXlLYnpwdHNLYnZmIhmBMUQ4B/j7OiIg8RrR/mgyy1OvCz5o8jcQEyAg59RFPsNBuIQiBWNi
#xBnLRIKcPzVx3oK836Im3gGFCsuLESgGKWDFor+IpkCFN2stlPA9DCuM7fuqlmGwokWRdlU0O+CayMCxTOIRuS9XMWo4Ik4YsIix
#/5GTvxOrgDUaDLXfN6GSh8X8LSU2IyxCdX1G8o4ed187f9pAKgStrre+S0FHy7DTWRXk4ifjxPiPJ59L2GNQ7OHtRAzIY6GvF7is
#WN4scIZfj/VGgKUxraNro62ZQNutBaMmFhUr58o4kwiR5aomIy3Sb3r9E9RKWkXgAN3pRA049cEpx7VQgvRy2GIFFsRakHDDhqHv
#WFgi9U1Tz3A4KrleoIik1tRQz5Z0WgFy1e5n8mgPs+lEKrF67jeQYoNBeTdILu+gRJHM8rE5BAJdCLncREKWRLMbJwLoMSlRDgO4
#mvKVJVXPiUIkEkqByAm548GKVKwEX4LQI1ICJ51mC2eqWlluImySNUsFGXK7EnXnBipRiFQwSRUaNWQKRznplhCURESek9CzY8S7
#kxXL44JMRGYwyEtwNIdygYJOpSoMlERSVtEo63vBwPs1Q3A2MwPVTm/eZhZ1NYP262//yAPUDkc0TXLl7TSbd/WXBuICkybY4qL8
#5Hk1reNKweVP1xLaJgorGY9nF5kckZBqqIpIiJrFEqIXD5jC4ORS+06aagbUpN+M9aMlXTfFjuc+vX5yNV0BU9m9UnFSSJNRRUQC
#ZZpiei5tghWsPt3g5QplqSmvsgCklEfJvPAb1kSpjplCeFUFYTajw6IGjl34JzYfLUzjFHI56/UQaPj9Gfut/T9bxqoCddyOPxNJ
#NMGxew/jbM6tA0/1rSTc0HhXuJ+X3p1PeW/fdPGdZ1siEn7Yql8kSqTRADnebuLbMF2qmRxUnax/UdvGH+biGSrJlX0OBLgXTmcv
#qbvbvgVRyrSyOk4LuhRIteA2aB8FVlpGoaqCVoUmr0a8+Ig4pFNRSE1A0/obswAi+4PRUJWS5aWZwRKw2oqyQkKuQu/GYIBiDeF6
#uQmSHIUJOjTFiZCPFChto5MVtUJbSv7itB3LUvG/4Z2damlWKIoypCPLihS1GvMBnlxKYrkkTIKUHyjCpLzSIgxkQSWEEUiKXZha
#myc0oMUSylClI9GSHN478XkYu+Ok9FPoFMn+PSIUQmSJNA86SjKO4Qpx2gOr5iElzWwSD+/l4q0GXuFOlFVXNz59nrmClIai9FPF
#UdByTU7uPTnxZ2cwYwcHyAiyvZux+nLCYxnY//B4MtI/7k/G9P0lGKOiiadUMOyeL/f/FXHEGYS9xxFr8AQgK4CAWQ0fEIFxQHFg
#cYBxoHHAceBxAHJYCmwB3oA1488bCowBUgIrgRfDjmtQMA9WA26MC9I9xscB0dcuLUIiS16FruRRZz4jEgMUeuDMhFY5LqMqzRzP
#BzP6LPiQgzn0g8J7QxDQoL3QD/9gRkiXTQUASZXvA7RYV6/X07klItbeuv37NwCcyzAAY/+W8HUx+4sMVBqxIVmNEOZOQoAoKQG3
#VZ1Pu1nAy5VPrBQf2cxddkdhbPnDtuT3JMMDbUIM3jEuzAfVXf9K1N0el0iedltqU/CIq2pjT4ARPICBBLczWu/yTicWHAdStLjA
#HM2eJ/AwXLJyLV+zdvCCs9PeW4r6fZwe/oOI4nhNL/5GjxEATOe+Lwxg2GCqsq5zMILILHpLQlWdobJVf2CCbbFWm5KNLIZ29UsL
#i8hBBSR4P3+rlQ8NGSgKLM5IaDHPX6tWyZmNFMejJpFh97kprrR6JGyoj5mqDLI1FaNSs7KxapZJrMSAqMnItWttaHLDwZev3qvf
#Plw9IrkGxCY/gpxYoYWUHqRyi4JBrntcM7bzJ9xENhPLXb7J37pVvsgEPc0klAH0Q5BSUZphF5phlmEb23GqaZs007plWOZjg8Ur
#JoPPao7HAk6hfs9yVFCTbT9T3NLMhiD01Rr6GpAbzuegMmFtvPlca0CQghn1ZnzWwxeV0QS2DcVqFn37z2mpgFkoj6+5p+4zAt1O
#O8T5OqRGU+OVtyBqI/hudUWU37etaf7kzNL8ei4sFt8KaMfuIHHR4XRWPTwd27F4XwWYnS9QVHja619Z6+GkdjwFjjSyoqNRs2wA
#0QNRZHwiMboeDZFcLDEIyvOoHQjEWBjMMHnZ0YQ+BlZ5HzFDTHQqOH+B0d97YzMQdpevi6umB+Xm7C/tLhri7Z06O/qpuZGqvIcb
#pN2JZ+0h0uyVPLMdrhYXBPnHzZ11sHF8nxch7BVwcDqR00R8PFEiGTgSa0bKPFpco4HgnfOb3AoENTN9kR4Kho9I/SANKk/+X0Rw
#wrCJsttd4yJVlaqWcY3r6pbBEYVmZhZGhmmXV1RNK+odbJdKD3s33c808fwnEVY+claYt9PtyPlgHDYvJtVdUKVlnOT1RMRbIWb5
#BES0rvIbXlB9Zj2zLv7Rv8ZPo2yYbsm32pDqBbCxLkfMAFd7ub9IgacaAJ3QkSCCKJT4PCv/D7zWxdFIbDlnKpskquNBn4YbXJwt
#d/ekSCsGM4iWilNRZZ3CxPhdaE9AdiE8ezEfoZiABFbHTshd+n9EH80fHVdDzpPp7rb/duXRQrLNPAude1LDrC8DLEDLzJ0q+oH8
#MA+Tn/rA31T/8xcbyHEAsXsV5r64MWJhhwbFAS6GwaqzMvMvNIMDxdZIcAlV9/KQGbL6II7WFxJnTauSXLtu2YotIuU7apUbPFf7
#sTTh2cJjTJKmhCdVNVfKGbjWURmwqQWKXzSNaoQDCBViDl8oNGmvmqsF2IRad3NecATYfbcmkNf0T+wBZb4ff/oA9/7sG5Tf1qh6
#+FvMtWpbdQBAOEA4tnTjyZsma04MpxLAm4bds4LsOC/97nxcthzJcR40ashYsdYIL6TnejA+CUC5R4qPqemXFk1zGnQwSopbi+00
#QGrBdkmFii3KcJ1HtdGR/rP1vHBvXDC2lGuovPnlUaWG+AEbH/7wuC/SlHfbr+K98Cwe5u3ziAPpybpOW5p6xYD2eh7jeB8OcuSx
#kPrtlHX+9fuuwB0ZOkA4PEBKcigoKFmKziUgY6qT3fKke3hOSpcTDAiJPKiSCVZzSB6SSq2qZcYqFV8WRNV2Wtr762g2nkw9yOQS
#gmGZ1CdERh/W9Ov7rSdAq7N2nTdS03WwpuaY7jjGy42s+SwjBGS3OUHmy10Mj1JxvDdUathugl2+rAfkqoxx91aNtPjtVb0D07Ny
#492u8ZCFx2HN9SruX4GO3vYp+X6fcGqV/uGJScjbFyPSq8LksyYLG9M+yElc4oGBqsfHn1ipxCtVrwcCLeBCM6uT64wEIwROuZQ6
#bdygVbiN5WdIqI7EHu60l+nqQsWmzNpumbwdbEwMbeWfjSOtkdtwdccj/PuV8JrqtAI2So3PSCQnAU/VWq8XBP/tkWx4X/liqzRb
#V+B7VeNA6vzZUm6VrJtd2tE9s3B8bfj3WjtezO/27JwixFgx5qW0fwcTHb+7Bj7/sn/PlHWFvwgigyTIagu7mF9B+LAfMVVjZztz
#rMTY5o5JX4jhdKUnYaHSVU6yUT4KbOufOmwpGGEhwGi09kq5+bychqMqhWW9BF4V2FiHGJA9K3Wk4G/LKrP0YB2opPqiTHUjLCSh
#XPRXn+3VI9iw/mi4NGz7UqjWReL3TMoeXz6jUZ0vZOW5W0Q9LDCznIiMYFslsRktoQVJZWpqHVywYQhLL8IyNzB7mpKoUb504vK6
#ibHcbs5m5X8QTTSkEk+iKeSDQqzxpVQjdmYJPTXA0f/I1NGGhEJktdyVJ1NukzwLHp5IjTC6Wu2CgyX49lDaJlbN18RDNijTFfuR
#UtxnkJwCVk/8qcTVTpq4BFC6HxTeihpekONejEcn0qxUYyaD36xCGIQXUI1xtqabN+JWA49xOb4OGFFA++d6xmRlQ0quRZbBqHpj
#+VDiX+wWbdpCLjt0Mo4aHUuYgawQnmq+d6IEk7brlfOzsDiZNZ9m6O4PxtohSUmMlQwRBJgmkILc68rMQMsaEb6Tm65bl30osura
#fYUpDwc7JB1ZIEIZ7cR7UY0gcfk0PUhCRn5Kth0uOJ+Yx9AVkI0z/k1Nv7cWiMZslocdnwoxLoFiQgp4TIK4ngjymAgDlQgUmQgl
#ldjaJQk52J1cVdelp5Do/Q9TRa0VqlUrt+9mSzvj7C9G4RTkzMy6IitX2fvAwZYDNZtKDnZswNERIzbs6GjZEet9mTBVserW2KBU
#iHRNd6VWimXxQe5YzDPaomNx8idmkZxBQAKcZHbqXI8vDXtswF8P5thhz3Gbdtg3gzTL9pvadR7js9T7dz/c3d7lLh3ZJNDYh02S
#rYjFWnY6BwAgVs2UL85mdYZ9MlhjtP8ZpAAopYJy6mrqyjUzQlQicGC5wdkssiOMIkW2mC7pM3s3r5QS9wB+Zp6brcPXjM3rRDO3
#h4BxzAUf1ZiMKMLmUGtt/qloWbLfKVOQe4pDShVxUk5iEYwfW2P00cuP5rM6i1R3mq4C207clXClmHhxlXnysokHxsPFqpKYykVI
#soE6MM2CZXjI4YwqLxrogCqk2XEXwrWluAEJlh2j/lDIBfIRIbwYRbELah0lCkyiADqKKxvtYqH5TmMgn3ieEpWEcOrpt+YKwzV3
#FagWsc1gLFSWpoCAuGwlib6BZjWYjlOGaWSwHEdt5YwXA6s/UUJdO7LM/W59F3l/BRsPzknnBjaEfYASCYZgkbrshH2m1ZPGOsOL
#7Yln8fXa2T5rJuLfymSqb8nchGgtrbM8nTMVO4Y+O9PMcCNFlYk8DJ1R+lCpon9uOIu1FXvvCokPRsl01WyfyarXYII1Zy4/ERjE
#6O0+43VJmumuRrWLFiuizs3oqbPAszU0a47aaiXxtK+78bSbR5X43eqp0K5kB3NbBTDzNdJJcnNXO5/+wINIujUI6aZKVUDjLeaM
#Il5cNft1ADJpTFLGLhsIT/qFLnj2o0VpWai/edMYOh4wwtNlaT7pPjC7zzrwqLjdZzvpPnLbTdknR+vcqEgeO4i3YSk993503fSz
#q3A/u1mXvezheB+2ss8e0n3Q1q04E5Kv09IcLWBf+46v6ajbvVufIjqUWxpjqDn30lETiDfvlBfBEyv3BB/5BFZf4iQqE/tkBvpJ
#14eJ21jgSA4amWZUYrfmdhpdanBUyYGRZrtGL4FWgkmNzKMZajJqdSzUqgiodVGgK3Thi+RqKIk8cmfT9M9WnvLyYBMD6CO75EjI
#4alZ90/pm4xg43t3xOcdYTOgYVsXqAlfPpv/NLD1n3H9xb9+B+7yv4HXPkEPDDW/fYrxeGQmN7HuRhyWLTTVHon65maWD4cFtz2B
#VnIwD7fMkcqjmiw1UhOanpEtoxguXsHIiaXg70621qQb+KX1MRQ4GOZeMj4lsprhZkbNwaz0ZWHUtqiBZmIPVktWsA0uU43BaNUm
#+6azOPP6hcdzIZRTGUB9ut1xRwZ7NGS9SSDiRhGFd0oyz4D4jBkQI01GVZFo6zCKOROhijNTqOn5F6A4pYjkZNDCRJXC3fbPH8LV
#WxVlMzZU6f0RejG9NIAry/pkmWMV8hfLWGFK2SmPCO8USdvElILkWlPSBN3MVTBN2uRFEzVSAYZ+TgLxK/xw2y4lWBD3YCKAdP9L
#XLf2nzT2SUdlDrzUE5FrqCXGUzrr4mE5qzLSqupwCBRM/UB7Zah0Gz5ryNiBMbdIghEZLX9EQQxCIocdHmc5hxAUUMR+vMkLaulr
#raCJgH1ISZDP6H5OjpwrEOdsWpjwQENsyIgSPjKpiiIy9+cQTn3DrK+wyaJCxsATyJJhosV+FJiQ4AGb3z2SCBBN/UmZeDQGRpCI
#UAzguM5eJMGE6OuYSwmrua/BKTFodZ/mNAiUJQ8GUMdhxgr5N+g7Dvcx7C7gDTyBGnqqJrgoGGYQvRgZ/ai6AiN2m2hHhvpFAfS6
#WNaxx7H806LcbkhCC0RJkbxgbo7iR9fPR5wFyYtEp0H7ESC6eoXYq5Yij2FgR+9PlqDraCQrw3Abo7hLcDJuUa+uAu67+MH1t/fQ
#hR1BwnedcKcBdxCGfIhI4PQLBW0YgRryoWiE2Fx8c2qDfcDRwn0OIRCCvpxHJp7QCQaJ5oxttixS8e8AoHrS1woLyLsFqXtCyNgP
#p5LOKInldFg5sD4EEPf3zdl15+iwbofrHSLEwjZQZuM/KihkxPHLNsbXpCuxJi8NnJ9Bwnmx4l4lp+0HfRxSmtOqr/tHIKdseh4E
#Xlxow2oKN7VoiDbXV/ABVbuLTXZEIuYvfocMXRMAYsZjSjf9BaQ6HrXKcUhcW2EdnIIQ2L+ZpzIhg1wvQtGCfSKGcMGocSSWDvHq
#gdi+KttwCcJ+ZZCciIRueQELHBNmb/4oKkRfGH5EFUeAf4wc4UHqtLVE9E4Yz+LBZ7dTfCCDzy7GianhTmyGCuBYCekTYDboCF4+
#DNqp6r5rEMaMEjlwiWVGWCK3U2QFmx+mhZ/Bcv94HcBVCH4xYw4AQhGK4UhaL/ZZ05ipqv0bTPBXZ9z5uANWsoxSxie8EZDzjs1O
#NEiMoh4EhKTrMX3TKzifPqKzZ6cJcHjRvq0wovY8VblNc3YhSVkhEPFv1CjFDTobiooGNrEddqSs3PLKeOShahgpR250OZb9RaTp
#iQr3brftrQ5EFscjIcj3oJYWA14DcTv08gHcJkbNXPoGgHgsxtnkJKPpVpmsYhEsUo83Ena6EUOXh+HahFd20vWsqBZEkVvHEL++
#gSpD7hziBLsCYfopNOUuC6mtuHWI/SUbx1QuSgl+o5P2V2OTD4NTdWIBFaenFgIVsrktxSf/LBlb1J0Do4s+oV1w8GccmpCRwggY
#vHqYbbx1r+yhkqJ7nageuBm3Ir+NCmgm8nExLf1z0bo1Bh/53DWi4HZAi/1KDESLR9GLi7i8UYRmImwxGvUqyHbnyKRyLVXdVvB6
#jQmLKGR90lMzC/iAFJV1OO1X2Tz3SiW5sSPpZh9G+MLnTeBq0nPqf1kUnz4CpRW/IKpA7aKpWtNNVLY6JuKjKWu6AwoKvcm2RSIE
#1BVmTxJU5Hp2e2X5DDutRHrafXdX2xqTtH9Uoyj8cexAdHUB3JVsKgRgut96X06YwYEd7x81yuJ6rO0i9xwIDweDVW026Fo1X6iv
#pd5+Lo5kJKC5vu50At4tf7zkFPdsq5p+5+0vx7cahlACMcZ54J19zc6MfGyWAnvZErwKlr4BZ2WuowEZYlKY8lkR/T7U59bQLuBK
#xIK7FFkDBr6WIA3vNw8Hf9T11X8LRoZ7nl/FpPMLqakzlK9EyuOGU+isYEBrrDJSKZS7rIFrqzjG13lFwfadiIL24Kprjvdabsmt
#rcZtlxZpM5Dy7mtyFcavSHEu5VBhQDzskIdfurwA9A4TK2cm13eZv2SsVllt/G1c53O3UifrMufeI3RlKEqX6GN1wV9wzy89Og22
#77BIEaE0jkAuwNXwWkKfGYhudRsbqAp/FC15C4vI4QTrT2AtGHu3VZSwM4nahrtO85s7o1WCzrux5c0PNaQbZue0qDFKNRERnETW
#/rPqLK32sY5LlsczMFbNx5UTYkM4+1hMAWI05l9vfvoHuK6d+Y/6Mmof4ZAkR2S9ErnGKW7iatq+aamw0OFvKDgXQXCaJEmTdW6+
#l2F7VGiWW5VPQZDFlRIJ9zrAhtrVkR/cW0dhzgU8d575YHrcCAZ7NNRNaLGZUI0l+LbUOcGD7rn1dj0Ma3wStztSOpfP1wSqdRdq
#yqnjQhB9u8tBqlHktaJk2Ng9lMibVNVvzSuJt410Ilex9nRz1NWcEkjFj7JtWwu7OA/UmfbQ94SZcyA5a/ksAY6smC12u7Q/nNpC
#hKCaeHgAicXBP0EBn5a2QB8klrT67RggaeZsJxv+ivFgY5zQDjP569t1HOryAZVfv+LCCFXWdn3TUmWueBakkPfOnkPag7Rxb8aT
#CeTx7FfAclEstAdBziUZizB/gVjPxMZJOA6BjpfKZwwsyR0scHQuQzU5BTuMtSUA4TI81I2tzkp/8uBtn9QPlCQJEbiFJ5qX4C9V
#G3B8tdV2RqvqCABgtDPKNuDuWRuUy6H6/YvegHuAs5DqyJ/SWWdyHtATo4OmiaMT9mINQgjayhZkmWQI6p6QK6cCmUZ89jBtxCxH
#SjpSKX1QXsWYNKVhCffnfp9CD/KG2MP1vPnnl54INhB6ge/WviXX2CoXWzHUHFDCh2PGu/fpFoTaxg6X45Yzfk/qqYBCj8knDm1C
#xQNc9AVQ4psIsIyUB063wy5pRIggSU1vywhoj0NKX//dZag+zAJHr/9cny2nfZfsQipFOI1xCqKAQsRm2JlH8JzaLPDls1TTGOO4
#/K2/7BuQgA1Y4bb/6ZOVS8JKo+MiKLYZPUfpm1a8aRz+QMfr1qCmaR70gtPMBJgO1mGjyweiV0ZqpZzufvLcVa5aaMunCEqopqCy
#A1tCJkSWY4+k68y2JM4m39dQ1eWrfotXo3ybzQcdKbXoFaRXFIbahGnzRfiszuJQ9pgT0hVK47TEv/FHCD/Wb6R4+Z4I7ZdCM8XO
#a8DCFrsk+Ob0QF7TOCB7WAnybQLzFf6Jx0TYEcEeUG/b8+E578TYOUVI0cRE5EDQ9JRfFdjD0bUNWKWIOe3D2VFRX9OwU2j+VLTV
#Ak7WLORyK0KVSC6TZt76ik5ncZktxVKZgLlT6a/x2xGQdjAlrR+s6WUvSfHMjPP3UK9GVOVQdZ21DDnKkqOkFfKffNS2fIsh/Hsy
#ua7EwVAc4rIpbVBb5CSzh+XfV40h8qV15QcnwF4TMVAwpKtDMGaqaSrRf0efECV6FCHAjjPuJGOXO+nWuIn4yIvXIrh7ilqMazl/
#mS9NoIhi23L9iCeP6T8QTDuokldAJzDU67rHwiCqkL/KT3Ito8c9BKlQK1IqmTnzk4ecYBndrsZZ6qbHwXrBtBMhApRliIVz7Nhs
#FIvHYgC6zYRk10brrVgf3Aoj4tvO2RKZKh/C7GhyueKbdc+qtIAnOCgYXoM8rfLRMgBt5O0qjwx5NVA+dhhs1eiDLY7pXJUbHb7M
#WMeqUuOS15LuBWqkgUPR2VDVCaSmB5+aNkmALBg1BFG3F97iTCkW+5RM7JZlz3YOc2FqjNL2w3rzT93Aa58qNvswY4dfQpWjJK+0
#VhuWokFBRPA4HpV6SLTEBOsa3zCCk0WosWtlLlDGSLpVpe4a49MG1kxplalbBSMyvuoI7tVMMgwkV5ykplZT7Co1BbIpO2xrLN6y
#aFSfcdQqZJpRasBMMaLFNy2/KByojFC8UTgxLsEaKZuGkvXabx0+Qp2ljvxLXBNTnGK4Gmi64uyHskUJqqOXho1nB7fgnUHMn/f1
#c0kqeaUQYnyIEV4LuL69YsZf0twvJqRjYvVbM1bOkz8/k7pxHdvZCLliOmG/kY7SBOzXnN+oa3sYZwfZl+51t93y1lt48yaXQ0RG
#2I/XSrmVEuG5dTDt0Bu8qzw83WWWruC2Pz7ZqR5oGS19ynyt9ABG+GaCQYUpz7jB7IROqvIjU/bxRAjaePiowjDlBy0iCURJR4K+
#PGevMkp0AzIBcoD1N/YHSIDKIGmH05G6gHYc4QPAC+s4h+FOLAVFMU0KzTvYLk2EpDOlBiDEOLWpqvypyNhZcaMvlm/dC9U7x7S1
#voqxdqCJiFW/BlAHtKAdgCXdTVyV5QdjrJ6IB9sHA9jZxW5u3tjUKyivby2RxZPHamptL89HbxagQasy6TG0UzSi0lQ3kjBh0MxF
#FABYT3kVG+VZneO/S3h/0tjj1Zk6v6edb2ou8uuiqwd9YLyzKYxSQpCdrKqYrMSPXlsfugebmfUucX6NJsn87vHLqXsuFUSXvDo+
#zhjsZAHQt8LLMQMX/VEDiFwlAYOIBfRt+eUuVfLZvP8DgDgNMuhhB5BIapaTesmyJXj0V5udNE/haV/Mnq6GwMP5gXXs6vB0tGwN
#l6S+XNcvds2otqWLuTJ34VzKoppJK0+q01c3WvfHmje2LtxC8IJWrofi+1N7LT2LdQNHy93LWDCKcp9mIhc+dX2M1jP6yN4bD1pd
#NIMtAfI4Cvz0l2Ov/esNrWj71M0g3bCs7pfKgUU0Od5OBsfkbZaaagGCej5EoguJRZA44WMFNdsi0pnkragXyXZfOO7800qbyE1H
#a2a7Onsji3b6lN9AoDO64p8QPGCXEb7V1nWUptN3k+5bGk2QEzvBjosqTYSrXcIN/5khd7rcpFuyX+yiXaWD3/sR1gZ5W6XUTsu6
#Ewy+8lx4ppQx4jIVecsiWfdtxp8Rr4STqm1MFNrQoFuQiAN9g00w+P7rv+Te8rKoJHx8RHAIuoUF3+SZ7zl+LXopM0h3Xswk9tUN
#ymXq0ZKaMQ/iSGsZVU4PiX2VwlSMHRdHAZnd8aYzMbkaPAWDXr1IbK+PBYvirDbGLuDZ1Uk4u/BShO2cy/dz2NkmGvIZ+beWKWOh
#7YGZaTWIAw1owA2Hb3nM7OsxHh7i+gOwDZS/t1NrmRygZvCMfWPckmoMSPOVP+Y+SxCqerEJ2A4p0LX3pVK2snhyMIY0BMgGxW5S
#z7oCUBRw7UU0+8azfFPfudQWE+S5k6/Y4un62SbcpsQr3B+CNe+Gxu/MYkRKa5q76JZEbh6bDbOUEMuONeAM8Gx9TVquu3TXISeN
#XQ0bq1dG/oI7uaDHkAKREoIueqBeGa2xvMvAvHMqWZRqZm7neKRzA1fUKqHaPpMEU9ntKVxSYilnv/kz26wfJ3SHB3DIbuHZz9Yv
#kaf0k5c6GvBB91Ue1wAuLfVqiO8X130FiNLkoArD4q7NywrJnG4pwnu2Zhdm9qsExcXsYlebuUHbW7mb1npu8Kg9q7z4coagdoTu
#f8mWe8aszeSqDf+UMTGQ5ckkYOnuFK2EpYATo0DxeTZWMp+RE+5z7Vzh8vwkJQZO+68GTuzk3JxpY93crVj52W/RwS7HHaD6pSu9
#EhMTakQgNDKjdMNJno+hPI9IVUYdIT/VjvZdQm6qH0nn5vPJ2gp1WQwWi2319ffPNSj6GpiRBzV8DZZk0wjg/hjbZKTAP3QDEACw
#BX7YaLuix4kZQC9Hh+wSQU9TxnoIOSL3slULAGRSVGrg1v/WININDBMrPFRaqLFcBQty4kX1pwVGvztlpBAwPotSbTLEK5akDcT9
#djJbf+ven7T2c0souKbysU7WAB5Ak+dNMeGdAmpCvo9dXw/IX54aDXp0OCuPjpaWfxoubKjWgHsM4mHhk/cTL9jJJSAlEJdZzosH
#XdjsST/M7P1UJkqXwz5RbJlgwOM3ciS8r40M76aODxaViSI6SJIrZKDsJIxs5LDIrm9D8WiXLhWH0rT/6NZsE9OMbWcrLzwLOG5x
#89veT+mTyXBTdXAx9vdEywj00JiPE4zp+QSF4KvwNMTCpjA0gydA8OMLGp/JaTMIephbzvMBciAWNWUEh9gl7phrr6BvmnDW/P6R
#WKiLtOkKKjTtlVCPCC/qZRhBP21saQWjItOHYc9dm+Y0u0sYzXztpMDlhSm89yNVXK1nAGQpHqXoYJU3VhJnCjYwgz9bjUZSwuCD
#4BpzI6oQ9faG6GBBA7Sy2skePdJtWOaP2RIRLQpUwDDhi/WiJuKmYCbi2nn2EY5HISvWFExIaxrHSOWVbRgbnEvwuukcsa0bwh8Y
#oB70nLRB+YMe0NsfABKATR5p/BkAhQFAK16dEFIExE5pLOR3pHHnH4smAAmVdx/gw87Jy0aU+JnZbi6SolH1FbbqgV8sZnxC0qNn
#JrFEfkunG+SQNvbQT9Q6RTI9K9d8JC7RQqxGzsh5nC5SxJraM+KyCJUi7NXWiRI/TcqPuG5s2kwfGCanNPCqp36dwjo1CiLRgQ7h
#KXH/GU+iaOUMjY8ZUOL+2rsSzMES5SoUAnIYqplpkdczycHlGPDHyIOZKW4Fbk9GXfPgMYpHB2CZsACF18wFmBi8UJBJk5tzexW1
#2JBHxuVxG0q4LuKZktv2XDldTjq8GYwScUUmRTvoSWaJ0cWQlXrvEXcPO/+Ur+UTQfKPgsAbszacsGWexMYp6Qlzxh87RQu6uBON
#v9LXi87W2h5Kg/4y1gf+EjT/y1D9BZmh35W98O7cEK78Qusr5deqtnP66pa/Cm0LZypRyo/rg4Y9LhJOUwosQcFuaDCFz5A1UoTs
#LvpwIrUeDHPBrmWE3ZtmZH3u3+6LMMWZltNXlisDzU9E1blUheaASoDT7p3+z+omHtZjl0Ia+1Pn8hPVW+1fsQKJQ68xrG6iB9nG
#IbaetOXjccl8qsFAsdbKJVSzlrdS0siajuwyQcBtpQP6IblVZVa1r4zVE+vw5yVG7wEVWhQggP7ph8zDq/+S5sGoXi62az7h8xH8
#zYefW7IJKMA1aL7GPh9VpU/v8okO4XoHU/5R/jzv/B19MjXSLNybvAdP1oZd18sv0Rnvcxsnx/KLezPXrhD88ornjysO8TG/M8PS
#nvsHuBDO/croxe7BEIaaao8wiQ5yl06DGgmXFiPOew2eu/3C4SRqYA4y3h7kQmwI8IW+RHEE+p53X07DTlz7vXk22tNeDhgHT1Re
#jgnfD0uWW9ZTduiep7O1IeLYSYSs/64F6M5pTINPFvStxDA8Oko1f8tSVlb/gwCXnvKe7hF5WJ/xKiBQf3cM0kMi0K3pj/Fex4g9
#5reIq/EGLVC3/HNsawvMWzzWoiBp7Jp15iS32NdXJADgoD9A4lWJ2pT+FLA/gJ6Av9GHH8vnk9UJ+fk/9iCSrMdjhqXvNK8Dn9ls
#xFNM2fJJlQqQfoeVHS1mHAcyGyBmw8IxXa0EJms5FYgCHMGUOk69nMGbjWWYqRNsVtODosuIOUKwJnBF9TACjEg1y3g8p1C7Q2XW
#pjqHLs+DMwZjo7hPHHjKvqC5aslHVa4eQHFnZk7lNglrRx/BG/Ao6/fp5Ow1i4z31KGMd7K02WujTSv2yZOIGMHiNDQpb+GC4KB7
#yCWJerMmGbUmD+Jgha9qVJXG9NufrrOEgpg9oXG9cHq1u5iVHEPwiE2w69lx2PPvlRFVFdIcOjIBXlp36fFUIfnowfd48vPPiwCv
#t1OhNk/jzSzijF1tXJL3DVgBWp381W3fmGkXh0imF+/8udTVVbBNiu3ALfh+sAViqt5i6KuXw3x01bWosBXzy+U7Bd08b2Xu7Euu
#JtwXlijymyAe3LY9mCcwRQr8aZacOzSIP7PA7sVMLVPUCNJClYb0R8Kdqzt5AXnnvvHVUl5d18jRHh7kNfYijKCnYN6CMEo3V7GW
#4pK5dMB9lF2q41zHELG7bMR3x2WLtzTsvcdRcHkArODGuILQMcaqPZ3UHldKfRB/wfLDi5gjZoh7YmHaCawcxuU47bTmypaaKMco
#zCcNtH/SLUHE5j7Iaz4jRmmTNqnUnJyT1kk3KX3xTYfdj7N+Jc23twBMXJtmdti4ltZr759r7s26OzlV/7CdWC91grTzqlZt08W4
#AP5aWhRlNiaAUAyVHEzU0gL8StKgf1wlPC8paDnamVj5RTiW21Ae31QONR+74tAiY1zYklmLLHpW8i3w31bfhPpg31A7dxoMlCvo
#N7HNPYg9aNSgo1QtrPaoaPQ6LUqxtu7qTZ8YMNJvMwHibXyH5f8E4HHSuWfva7apne29Ht8u3kDXCLAal+jlofE4feXwKi/nAVGb
#qKk7rXE1pTY8TYKnO0CZzlqIthtDbi6ggoV2VDV7T2GgBq1E30MWQmpEAzOIeZk2+ueNBA86ca3w+2HJFP9Av4UjqxAmxZBHSiC9
#5J79OGcTsTVv4fzG97QKZn4m4KKGDcSVdf3EYZLOeIR79Ul8NDmBmRqtbWo9/wmeaVV4Spk1TL5hJUNnyJmLbUgQ3HWyp3GB+kMh
#RCHlFFOau/0uoZgf8yEqEF+8q1ZOncq0cfDWuo3Z9IzczoY4LClrxrDNsR/BYlXVyPWcgquff0eXyWAkA/sQJvf2jtDiy+olRtJX
#wzw+1my5yVK0qG8x6q1kWrY8XnYixKFvWnKel2pJITNzZcaEGHG4J0x4uBpmXCSGYN+sF6PG0WLRUc1olC/nsGhDDT1NvRITPzzv
#JySsttbY3qfVAZW7HFtu2vZTaLwWc2IH/uSDaX6Uh/nloCZ2F5gauNg6yRW/Sfaqe3qDj2UmljcscAa+ar7JyJ9wzqAz7fCqHkjo
#syDrZ+YFrIKF5JZkiQaGkbFdVseB4mzYGgFM10kx1VlelTTLH1SXXJ2/XL1qWPDf4tB73dbwKskvJkHC+8NZf3UOGSa6J8ZI5NQR
#lF8IprbRK+ESVjb23H5PT9loY3q5Fwm4OEgW6WyyuwhQeFvTDbi95zPBjPu5SbCFbeRqCvFoTjyK6BtuLTsz/fAmaASXTz7eqsSn
#RiTEmgwZePH8QN+iRhx6nVhAmNLDuWNRNfH8DBGNhA7ECC2UFuC18HC6SJBwrSu+Ggjv0trTvXCqSGrX5lfa7chGnE3Aibc3zRzU
#ntfPtKalcqX8ZmIJTLalytZZs3Fkx3S+3CWb+ZnD4Hsw1kF9FEq8D6ay8egdHUsYux2k2Pp46/29BlkfB8Z0oaGiwt5ukqfuDdOG
#TOCGkmeJcSXGMGNdm1L6b/NDMeU24NtXTw//23ieYv7mTXAPLp9+tF1JxuXv83bME8rEsvu0EiZ62RbFDnFPPH3inOP2nZHrm3Ps
#rWWG94v4F/Mm5btr/G1Um/SB9WbYCYywH4CkdWsRfckpbsg0Mj7Z1kwEhGERoL1Cm0Uv/cR+fHo7O5WowR1346xh2z5ltRGviWjo
#TKiRf5r7vTzuK0Kj53WcPns/1GnDF2Vq1hDM6Y7b9a5VpsDjWZiewKbUSLjOYvhxE8X+aRlFfQA8OAL77GmvcnlxaoORLBPTLrbK
#yWuxqgS+3QeJqbrymRNpORW52gctAAJAD+8+J5ma5Ak2EtkLgbm7a1qgjFCKemC9kGlzEFTjrfccnP8e2O3miZJnUaQ1NzUE4CIk
#9srUsH8KPTCt7PkTRU/PfmGHM0ObSeaVw9a0FcGkiwd+RmNwZjPuXJaLKkT1fSrlou9ouKUn2Mp9efgwZXR7XR1ZvoQ8jh17qqQN
#yKETJCW3eXd4p/nvjclp7NBqGM/jC/b6YAf7/QN6trtAUdfTKkb54ZIX/uh9vKGm+/tmDd6rYk5Xv2bHfqohYYQWolDQmiMbS2XE
#pJJd2mLktCtjA3TUjq1MWyc+pwB9iGhjpzxCT8sFdUhWNZ6Poi1PWfRJZz+L2A7AdbNtF1v5wo5n03ThgsnXsB3INzuwZyjk+x0y
#IOuBwU2zv/MKEVtJitnhDFx51LQ8sfrwDUGNR9ncQ3+mGZJjpzfL6GBtUA6Z3ZX3CyL+iwxf0uT8+dKiVJX5ERUwXvr8ZLp4Tv7T
#qF0hmp8wu4b7DQV1xRd/SEgFK01a5M9ZPoe3xSTau2CaVLWXRv0338WgUQnhHFQTTlmZWmuVR2D5So7d97eLOdmm1Ky7sros+osZ
#NMK8rP+9MrOT+NlDm22B9NRg3mjxrVxTSJ8ODUdL3p9ufLx2LBolk3W8RME6iwHHXqghMDvfBlQvriFG4UxcF1y3GFCJOEYHYhmS
#RcbC3t6qM4xMUCqtNhyXzD8NqvEMaL257w86UFnwViw4hahBhBMeyP25yzIVYJfDiy6BuJbUYPaVNqg41p6vnXH0UsvqWUiR4K5n
#SE8CmlXacY2REEwUoWUloA2/0MmsCxY6bUebreEblsZEONNSsIPKsKPLoPeklapXgJ2Msv09awaJyu9VJlCyjutWt32fyNUmifKg
#92VN6s4qltdHYd9cFjEiTbqOk1gsL1HfQc2FKWX4QWUKc2ED6Ldj4iBcuOlX+Uz0x1xLKcDksniCuuWh/knrYurSWF424nt8oKwu
#8y5Vz1nr5AqynkkfhaMd1T8N0EJ50Q84qkZDhWp7NJWI6305aOJXhiDOhFdoA1276XVtVUs0Mx4KGtJzHyyRrdBknt9i/Im3QOxe
#JudAkrXJUhy6px/4GTy+9Jt3CZJlGBs+ypNnC+uJPxqsRyYv9vDJ8iAnXa8OwCzRUgKowfVmqqR/W7TpJaPZn7UnTcjS/tiwv7eh
#kl96o3AyQJ4+rOgMSmDG2O3WWBmwzHkEK+H7xtGfZ8SIjVEzukygqe1wnsNgnikRZXyXuj+pHpavY2+uCJzCHD7usipW76XfhP8a
#9JhAAB9CbI0eo3QNbChqQWXG7+jLcK7WwuLq8aC7Ns5vGnP2hwCSjdbL8hls7Mk140hWpXsKRLhligFAZgnpNu5Ns81pGOnXkrFz
#JuXE7M8aeMmisXJtKlRe+8cThz3ZnYcU7Ih1X9rdbsZCJiwdj8P5kX48kLcg+rOWyiZy1PkxQJzBZ4q4cHEsSMxFv7yVd9xFDsoK
#8MFYtQHLc6jDJODX11pxZi/PoGXhQt0T5hOMWLfizPE043TaHYAgxafl4XhfIaoqGK5cxIxLQflsMAkLR2b1eYWYEOrIAKqAAGbO
#tOG7lg2gX9TK+FaU1UmFpyVnM/7NBnaVBnF+OwW+dwlacFJiBPl8gdFzTsIUyL8xycjkFuNcGh6mTaVV1TkI4ccAGLqwCq4rSiUp
#VRAATsIfuCz8iCCDG1fBxprAmZK3iVwDpSUwRPF0sITNRIahjbjfW6wnFyREenezPlyfXAlHoZ2MGtNRy1fkoxhXsl6+uCy4Bx6A
#AfB2S44CPhDcC59hqhVXelEWCj0boL6iKQm2iZubFmV9jG0gWQvrRJLA1MsFeb20thY17VtMQyVZ0MeSKWMu68cb/+7iIW+71vPy
#YClbzOGVL3zARkDN6XR52WFUnRHLQvs0sSJFIrBBamPZWQwKtHmYWCiXNsRbAkHEVs6lAozqSwQdUIjFKSxPsFK44CAv0vBr5yAM
#b3rfQv2lDq1W7U/RchENJmVVQW/8EC/zcm/VtXgiFFu1XGgtvs1IJ2YY4aXSkWnYIBTBFRdkQIG2WEwopHckN0gYR6412clO1/Gz
#ew6K6UPQdSMgSfubqkS/aHVcw+plbcRqBmmSlu1jnViwOFlM7XG3aNzEpCKZJimpZOFfnutKlpuqMmnu1x+Z7awWnyKm7pJOvqGr
#C4yIAzgZJQV7x42QG3GLz49ye41I05I4KMRSqmIyP6xGYdxHI9KdkOlv9MgTeGFVJdbqQpZ7dbxzvEM77EI3I2P+CU6CoEq3lYCG
#Vh8Vkmd5i8BINqPTcd+E3HVRn/cHrWppN6+HR8ivaOqvzmVu91d9YD9LsAFLcImGrOa/JwPjHHT7HcIDLF6gOKLllcT6VWupQrK0
#Mo+uYOis7f5gn4Mb/RtVG/vF6WSJS/AtIV/CNTWKkescIcGc/Pc9j/aKe+AeFOdpNOk+hbde9h4ZyB40fJoHAb5n20ea6wpDlzn5
#DlmRsCKhr31p3Jliqs2dDyMlnMBDKsC/ozWxv72vu9C+n/FKJ8RpPHaVAjCfdjXrmDJtyYLqo84650wSFR0cpAmW36YaNq2Mkrfj
#fAikNWztaNICrhRRXj3Hdo1nSaXBn/sD2JGRM53IILJNE+srw8Kul3kT6IWqhAgXZDanq5fRIGrhgpQIDQtOMqQIVHMjTZ4E4u9+
#pNAF29CZ0Bqx5/rcCSzjBoJZDnbz7KawptCpklFCAX9GNGX2iNw5DzZTJvYNnFOVSZu2NAhiuKyY7ZXry2L1gntLVajtMgXrWZDa
#RSIhl+J/fNGnJAtQ7WHqjoRUAGwC3z7Q8CwWZz7685zoEoDjYrWM8dYSrz4G1ICR+1sKxSFg6eArWrsLON5ToRbT+3Nc+EMU4uqW
#xgStJXlBg/jC5RJLrDGb2hwMIwtI2/duElWw2DCbChJVa2HyGI+hQ5SaIlTq074dKoxx277unYR1j6VYGSEH0mvHcrLgj93s5i/L
#snxNH/crR2tSRuIEMx+RGIDzbCUZtCrVWdDj9Jki+2ualeyAFdb+csIwZtDKMXyQ2PteGfvIkdeY5lR9gijRUlC4joyBA3hwMuJE
#EvNyFHjOG8duROHBlimpAvLxB0gXkzdo9Igmz8yBgELlAwRGyp2cDKIXrYSCK3RZc2GGfHWp3efVzN8/3a+9ZD76WXT82QdNwl0Y
#rLFdz0Qf3x2YztR9n2MKerDYrPxLcwrAAEw+xkD+T2YJ/Z/Cj9XGZ+AEXVkpsKHLDZ/G2MwZFmJqG7acqBJsRyr9Eb/qhYwUTy9I
#r4eTMW8uQW9YkVFXoMyVCqbUFOZ/cjpeyCOjHIniVoCoAxgvXM6jf+3dOrSI/VR1w370mtvRFvEVEvWLhtboUFd5ENcaP8Ph62bq
#WGMsjO7jyWNJaRROHnlEaf+onThXl0PGRRYmwETJr3g7owqk2NiY14/5N24ABlBtmqFDVuRB3La/hsPT14cNcnDeLQKvcHZDBoX/
#M1rtRUDUyk5MiMZCQFZ50Ts0QIdCF9HY1jpYG07XZHkdSwaWNoHrRspBJdNhyeORsCjolsQ9R3Yf61ag8CxyPe5zCHBtL6SRcf0E
#iUUMO3wSk5ERyqM2waIeKKRXaaLmmR8xINVEFMhTahuiZEgTgHwKkfvvrOgiwGDsgYiXxICWFaQkrvqK7f2YtxHJxLRf1SGjY5ON
#2rDWcaDFgVMHXJ366gCsXWhXwpiCnvI/7U/ML2PBzKDIxw5g5vKyv9ZSljW3Ju0Yl/vXBB3sfX+Neg7AdyMn52+qjqQIa6408z4y
#U3iYS9iOMNNfyYvDCVSmey+U/cXtoPksF+gswsOdiB3uc3TjW8NpuyVfWYAFWBvIDtt+3k70JNHDvHY6tsnEbQbVcZBl4f6Cng9M
#uX/5Li7dzCfbnZ/xRCL6Hdq/Zcob+KNPmqb//AteA8RKENvSirY1JezX8bDog8q54N7In6MO33tnGduhtq4coGP4N68+U1bWAPNS
#FztAKyrzuoEo7Ot5OGQwynIY89RY/d/pxQ2ttvIRF53tbUCRt0EQNFXtkW8/4G7H6h9SuQhzi9UMUN3Oil1QmbeQ2K4PtDtvgLhO
#+apr14liakLlDkJvbBDql4Qq7sDRXikwa47OD8Gj/g+57ztccgyXKc4lh6nWk8XqMcaMxhhOYTnY4jR6E9leW4g0nGQlcY1LLkHz
#anF0Ok4RwjeGQdhdSSBurxlolg8t6rVOfoliIJcCG3AfcCy2lVdlgKlSECeXYfOy0ddtn9fmcWimE+a3lOfn02Yb8Kp/bwsHMgl1
#LVsZhndV7oXs02ulM9Y9di0bAf+mT+tEqDX4pfJmlHM8zmeUrAAUxVMJtUtwWKMqOt63V59uU90fv0fB3+iqLuccES8RmwuhV0BX
#h03IIK2bocOCF4pS7HKViUBG36/ezLl/4BxZ0utdcJfs4JEd66Wz0aWpXQMB4OE7ZC0rNWaCMdz4mQbY6n3rzRylR0n314GXjN4W
#vuuMpRRV39lIuA/KGKtO5yLQCKZNRX9+qJYRYXUEqf+i4WOmaPo/plvjs2Jdy6VYtw0LuvADqFFk3Hzc4U5n/3Z0Dp5j6eCGIMeZ
#SZF8YI2jXq0Z+A+8k94ZMGexaQQRuk+orG23AyHQ9R8Je5Vvu9dAWAFsWnDTKiC2/jeRhwsQIlSBaPeZO/JMMB6K0z7GDCouWzzF
#A+hi+3DZLW6p5LOBbOQjSIbsKWBZUMNzADXx9vWAK+dTtQe7GUvGMJoGXe2OQN82oPOJEZEMPZLkcRp1cpcrlelVGjLodQ+vARdv
#LouUsmqArA2OTGWj1hkgKiUKkP1y0gD6MBP/AzjUfOhqkC6Ocn7zkxSQNNPIVA+f6XXIAh2PFGqySwhKnKwhnU1T3rhf37ywfLuj
#9sBtKBnC0ch+Wu8Nqri0SiEpbacdRjGbMBErDvOPae4ZKGJqjlQdmjIVBQRhaUQDV5R7m0EjDmTtWBZLYSKNfHIckTmiaUlq4512
#bjREwC0K0NFyXJvhyvCN1HkAFEUHSK9c/c5jYzP5ZBA0o8mDRY2808JhgajJmYCh4GTGnU88IOBpoQIDmSHHM6RZJkfaCwPFHqIi
#5D9JynxQUvantaeU2xCF7hAtWzX8VtHPqvKgLFrDUSqygJql8DHMwxLXa06a0PK1PGRcLF/0/3zrRjomR7a3s1c1b5UsOERToLWG
#5L0ELf+qM8/DzLmSSUzLkL7/3994jp6H75dFnRppret4LxMI68r1+yy6YRWaz6h6LLggOq5qCY4SoIpVwkwR3uR0FQiHlTgyG1XD
#S8CxR7OtisGIXRa81KsRK0H/fHU2VgXBvuPuCf6H7pCyZ9UD5KDHWkTSxSKMzVAABDXTevQebqGckNImKjNmaPQRmuP4okQHyH5x
#S9OY9/4p2mGLnx0Y/FOJEABJ/bC0fUWyshUZKppW1HihYaJmXFzbgBT9oS+QL4BqLHSbJPZ+E42hx3rNbjZCU8Tj+ScWzhmFfSME
#PUZtW2BQiGkRk32dsqWasGnglqD0moZ6x7a6apRDO+Da94cD+kWlgy2eYfCpfPNwoKJw8pEZqGHQyEsRCsYtAhtnd8i5FHQ7pPR9
#6VfmS5pCsEs0wf1zFEpWB0K/kJNn0/DdPytiwxyHkp1E4n1s4Hl/fu/i+18FvTuhmZypO+ZxtGecS+mTxliFBADsR01yT4m1HSFf
#K7H7wAJIPu9iYlLumiDtZDqUOmcUTIG+OSli9MaUIf7qJeo3gszpPzjxSakexODLGpk4LM4iJH/W1eCDtB5LrRL21LbJi/Ak6AFw
#66jqkBjNmcwCzpqtqQhWhbqCZZbcHVZjTrgZFVjfneoo9z7D92ldVIx54F3r+EqgxWeMSNSEyospPR5ktjvVin7ixDkjDpM27v2P
#MPD7+4mhsYGpB4eGMd5bLJgKEc48ZyIwv/aRuDOa1lAI6lf9eDGF0Xp2Ld9O1eAWSVCSnDWKHYJPqSjQdYH+lplDyGYdzh86dEuK
#AEDlA+53MhA9A2tAf0IwvlStEbT1cYgulISGFgF/gA264ouNAaB9GPmwrKabQu7bIoOu2zlHxgTQQQ8j7njWEoSvZ3+OqgLCCXOI
#+FYjbZYFeJpGk6Ye2RohaK7IcqAgzhtzCVKS0MGyf2FZdl2Du69adps1/QmSEBYMbCiuqFbixkeG7J2eppKgKt8Y6q54fiygoGYa
#etlsGoqy88SKphoZ6xWQPSQkdpA+4g6BFJIQhd0KP0QCVtXKVwbVmXx8SSAu/WonfBGWGYH+V9wLkdsq7rerTttumO+GwvNQmQuc
#aEuASGl1AHgYwoMZrX2LiDXrNpzfRZ6eJ6kQSKgGfsHWQn1iNrkg33O09XOP4Dw6Fubs1GYGDqiruLFKWze/cyQFLQ8VT0r38KFd
#mGeqoz5kTOM7+kQzPQY9/uQz2Az0ZH25PVrNVB/EqqgEH9GO9ZojMEb4uSKDtL48MgCOUSezJMsVRkL1x+YfLvQfadB7kZB7eWlA
#jhVIQOgrrSDp2SUq/JrDw5Fa5WYnDjH2/S4tSplM3PuKkiUND5D8jwtMp+lRgP16DL1Ehl42Ewk8XBQ6WJYPHOjpTtVwPfCv5O4H
#yzP0b/vuYOuKCqWesI2i3gmkTivAJzwNTC0FdrI1pSoMkdSBZvCyzKZ9bYBzjEYG4m5tezVob1e9ZnTZYGpJnCcCrc4NakwT8c+t
#KGE0Ae1/12fmYLaQx6dmDvXFyJC4w2xLX7q6MmNKHoDTlPJaeTpLBDtkfESD0Gg8WPpYBUpAjxtSJDI7977wr/BfbWFbTTfPs53n
#7UpTTp0vfnAJhrBqZEYSQJOHhU8V6QL0eiDGRwHHDcM3ZJJ4vSvFJuKbYN+h3g5AD6HhiBEUYX4ucnUW+o1FTlAUEUToe57kxoLu
#gY7+QINUMaCHRv7dTiR5WA49F6HTTxhJcMmvSfNM4yLe3J6iQaSFgz7Tg6og/SlElKdN/hX+WJUy3NyF7Ivd4ycuT5s5cNMMpoDQ
#iTiMj2QsfqtPQdXB4H/jeKgQ7RI9F+FLcmIxa6BNZgnQY0e6lS42jNQUcT0AAERMoe1oz5dYqdLcQhCzjG28DNW5c6BVPY6AhVtD
#oKaHLEGb7eBl1gnf/M6oG2mamEo6mTR6qiXu2xU3y94hUKFtdZmnyyM4sPSArBzgi0LTt44SsKh1ScNqcrrY1zyf1R7caZtymU7H
#LXS+LpJFr1NfL2Tt2WTBz+Jz6h13sDZ0GXnC5MED+TVktl1mRWoDajo3umCDjsZci9gPwSLCtARW4Tgxk5Rep4Dm/Xl9f+8/Z3nd
#fH28uLX/vDn79DKhTHG4ukamfCVOPLw/XpsRanm2XggLO46SzrO9DebyNJ+N5lk6MhOcYt1hC5d4NoIQEK+k9H1/De+fHf55NeS1
#mxyZLHne5qFevkXbxRew9U8nx3KOgLwGNKLKV2OPza8N2dHpWQrlxMRj++yYwQ4azDkPr7KFrNyohwJpNfjUP3XfLp3WJ+kAjERx
#BvxkZYXMWWUaHGVFrkwvk2E4uyO+Pxtz/Suc+vH8aL+zzggbBi4N832zCghHjm6uqmo5c5y08Lk9/oUAy7LqZ507ZYVKRuYrXkSd
#Jdk31Ze379e/wG+b6lVLF1mSf6xNtR067s66oxjoqnaphZ3cou7EpmcAwaBO5s2qIxAI1iM/hYrxg++Z2DVusX2iVVtyW898bfLM
#CbA3s/WgrisDfjr4oGjj8MlGbMJdRTAHzAd7gUqVYH8dh/hDu1go4OGTJsMsPTrarf8MjWsk4rwKZSbwJvtqZacJXmCNm5/BsVOX
#iNQsRdcf5RD/vvcnEFoJlCjE9J+vDLITthbYgrhDHttEO04LwA120QAH8cY4TsbShXlhcILDsKLsxq7rtuxbHhTRccO6rx9G+Z1e
#Q6NfvsWb2nFl+TZpCwJz6TYpUaeA3+PjiTlN/CGBmW56OV8Ogr5gpmJp5ch+MjqVlOsS0gG1s3tEFSOJwzN0rJ7i0g3yiFR4O4Qo
#Kl5mY4qb16KBBQL+gzNozDiyNXEyb1bNRP+eM28X3hAGbwHVjbbh1uqrBvKy3NXEhu8mvcky72DDEm+eJrvVX+ArdR+B4UpUPLUW
#VeKZ7XyiVLrdmp7rB2ZXkLLaypfuQ/aVooPonffUsm17ebm6Hymbn6JFIuPLoEPuwKb6qDN+lZYg31vOqDt2X79DY95jW2HbOSec
#sWW72nupGwoaJ7rHxbPAzdo9/lSUI+m0+xoKxw9rbNBzt2obW0z/J0c+GsB9HBsKDICxzBVLCdYUHIMFWhgFjXH2PpBeiA3DWgQk
#erqXsXUAFNOvonpQ6QIpFMYtD1EnZY1TaRZywzuWhrvc3zu0r/xe3WqJ3UJ4ULKK6uqbPlZOsCGlu7XQDGpQWMF15k7sVeIAdZqc
#TLURe5JFizbl4rO0/MRWrat6Fslqu3/rNoZYSRkhtce11Ar7kmqZHZXLuy/+oyTptE39ngb7N4rtv2gsL2U65dPvNipwA2/1p7P5
#Lceq2P/UATfRd54J8EpA2KtqLIAO9g8Apll+OpviSBnHh1SJUv9C1ABs+rmmC/ZSO+nGP7pFs3dHKc+Ih3WYD00TipbrFUz6r7/i
#bUpOxK/Yl94/n5f46diIXIC74v0gNWB/DrlEOcrc5nYEKwNO5OQpV9c//pv0wqC6ZTNQfMmoyCTp+g8HaQTBSVeCQcSYQHJZuqgh
#fxb0UKTFSjU2lZAA8YcYFoMWFbz0SKmk4Y4PaUPO460PwPYMxIvEOfJ+6MOkfMmElE0wHzRUquCBrpZJKyvoBOyvyy6HKlgwjYU/
#rXnTi1JUUDrA3mi+NYhfVu+fUw7ACiQ4UDMdCjUF2SgKtE5My1Elu2P9mFCKu238RI/PPpXNbxjl2w17nt/r4/f9qYOXR6/unYXX
#1q5FGu0Yv8+I3xeEpM4EFjxS2Okk7vc1IKZGr+njhF68PeUle07+OHvDIjqkR13ZnCqAi1amdk46JH9WWZydLuit5wby6XvBTMEP
#iDGXHuCbIIB/VEB0N+BnUiksPsYO8VJaBKBHJasHpd/UwD1erv9y4g5K2c0e+WU2vtRMmIWWkQyuQXtjdsbHjRoNEpxYUehYw7mo
#V0rf60jqZijpXkv3GAnoO+8HtZPV0SEbD7ekIji6jKayZv8gKqgG4+/66KB2Bhcz+j/sii5MwgCaQaKpQFFJ8J9SuvbLEJAJHdFQ
#I8D0JHoKruQeIQL2zptnCsN/o0FXrqNO4wLGEOJNM4jdWnezNP82EkMQbq6suVN3wdiHxn7fjNkXMXlHzxdceIq7Db5GyhuGM8RJ
#ulg2ZrkJqLf49ouqBb0hwCl8SWSe5KY9PN9OOfLs1FILfQOzLN8IjI4+DiGOex2Czg97AglFowTaRduAI+PAEwvfr08jnULNrVT0
#fc5+euW55OH2XVLaJ9jNCe0XYoF90BeISwNnc5Pq0HYXj1uXF+JxIqRlYiMjZ4zDFyDUnGT94+4/vt9Pf0+pVIl55HrLM/OuTZUA
#R9whmmtIaJ3gvGOkUgfVglhR1ITMyQvZRYcU+XUFbW3Odl68LSTIEozl2XbRc10ss2daBA8/3Hsax8F94u1mkQyfCgNloL4lxQSd
#YfHEXcun1N5vbw4yS8ZH6Y/nvUrqgQbw7vdqgX0eR7+8EQw9W0aMkKjJ5uqDHdO9D7UuRIITU7oKBcp2rwx55BjayEm6Amy8QD3F
#3TYXeTRR3TtyvHMJ70KSy8KIzAwspum5b5f+XfIWvrs/XOwH0sbNr49aAGdnEP0poK/Oi/2BkRdAwSOc3zR7QBG4Z5mD/5kSWGcD
#wR5s2v7hsNEg9GALUAqjUVF0aR1YMbboqoqEYNG6r2PvibRijeHcnCHgXJ5k324J8QxVS5g+44Y9J/qdMQZOmn0mR+G+GO4RdyPK
#MN0QnWnql2OISh2PzKuKUQQayymLZlNS8uaUBmDEU64XLTRXfHCWw1KueuNEXrL6YE5BhqLmnIUZtUkTuQrIJT2lIsl0i6PRq6KO
#wURFjeTaY81VdmUfMq0yxQF5TRGt+/FOna/79Sjp+50P07QBD65FhFE+JKFz20/5T1wN7bDNEyyL0BM017ayE3NGHL9j5jhnFinX
#pif/uwb4AgnCChkH9LZjsngOBj9PO3CGsDK9uTx5AXwtAAGc4+MNKLvL7f15Nvbe77lB3pGuMPOK0Y7RzZvzotKFtckIvMN2H1VV
#jCCAK0TP+1E/bXJtP0bjvtLPG/vXtXC+Z/lm5sJ2SNv2zh8f9LPtyeqK8404Zb9uaTOHmjuLkKmT5f2wun1m6ZVXbkPSHWrmCTCQ
#1PaGXdhU1l2VcIDZ5Y/g98sdYV8QqBk3I85qJleVjCeb7OsDDpTLm9N/0bRUVjfnPrpk48SVHOlgs//2909U7choVVtASjayz9iU
#mCkALNan5avkvnkzel3LzguY2LbXjpnO5fUROoveend7hoq3yV996sJpQqGXRv+6NerWc1cdKm2Cyc12J5RyKHKGBM377MYZqzlN
#4gkjbGlbdi6/dYGtgWh3NI/Jruavwvk0vX8/oNUPMj4ICqScOVqWw94zyZY9ZxZ9xo5uT9YxHzOuZ/Zn5+XEbWVXDpzKTMrJ7eN3
#mkGMx/qDuurDqgVNRm0eJUntSOrzzwkE6elu+YYKhD/rndT0VdK+m37fuR0XtsCZUBJdNeHuGfhuVUXn4n6TrbA0cpHj8DnZ6TY2
#I3VS9hBUTsmuYdpCPy+2xj9NBZi7CPACk83Caf6uWZCSP2pd3GI8RCVdEFgz2cogDDYyMbPCrqxrtuYC1NhhWvjiMZ2Vm63Aa6aY
#YzAOeXV4j+YJe8ZI7Ycum82dpql/0kUdKZs3LcBeV6iC7y5Wf6mH3y2gEiSQx5fzkzz/81Sn019Yf/6JdD8XGvG+1L3m59pcpMlf
#oLavKUyo6A4/4pd+X2kOMM/v/SfYY4/fyZqs8h//O4xivwoIgQE19wCQNx+ty1f49JzY6Bi6vKptkdZ9Sxln0LuzAaelG6LfBbeA
#PX1hWVWA/TS5P4c++4A3jhJA1GwP8N4xPJoX5eF9sCYad9KuSJ5lrATBp0XM48Cby9E53tXUPz79BJU9ySrxgNtnGPIqRu+dMFru
#3jD/vET8ENkD2XB/e3u9XWM+XqEdlU49pjep8pqNPY/e/rG2FD3AxoxW8yuP2e0WCFfxenqh2j3E3va0bk87v/3daC8Y9zdVlRrw
#MXuWvU7IigBtv+CV2FJ0mh6r1pyiDtof3YLrEFQLXUm/Axfzz+C84T6ZzrUPvI6nad39vJBqk8zfe/pA4zmP5UF3IIfGYvu/Ji3e
#MLynS74134c9A+5z6BkF6CEDiufQgCPZjApVxccw7ST2MSOJItI5CWx4d8eiCYmDJuCcq/vR7T113oLuuuQ6XnF8zfs2PX85SIJv
#voZj8htCh0xfVvJ/GVBmFjA3skQdAaG2hBldnji2Ukc0abzdzUhg9ayeQ0YtzCprQeq2ArHCjvT3mz9PVffXx0jvqyEqKCUp+wg6
#ehxls+c8FZ+DR0Ias0S/n9Zb8Jt0zCyvWHSlLPvoPbWfo+70z5gj/OCn2DM/3RxuyWfQhhf6lVdymVCVuQHbAiVY0JlGkWBJ9odX
#pPVZeE2D8i5p/vjCdN2XXcYV1s2pBYOL6hIXWGPV3kqKK1FQgdPsIMa8dIPlRR39Pnm48xYGmTwoOO8AeLPz/EiiXu8SQoUfCcks
#S1QXB+JMz1J4E4h0GmnXxPuewt0dQiR/1wONsErtl8Jm/XMGPSTPjyJzdXQOnWxKJJMsEhFOQ66pVSoFJCeTx+OqZvU6nN4dhkQ0
#C12wHBIonz8ammi+gaAQe22xiyGqhbljpjAWsmfYlSTLmITTlREaK3TSoV3U0cfCx08s7NQKAFEM1XTs6VdIunMKjTqKVI0+SZCh
#oRT7d/0GNMh7pwYrOXUODJwqqc/XqXqZIJEqBKpmonjPQtu+kj1i+fYv0+CUBBR2sxykU3Ybvw3+3PCcPD0GiVfNZOYejE+nR9lP
#dO3j/7AVPXc5/tJ0Uu8qQ17XqcexB4SCoZBrN1hBa6MQKKWa1Y1IiDWLrzXse1Y3KdZWpW9UZL6z7PNfuc4pRmCFYZh5oEKlYkJZ
#LhjjC5IQq8WwbKMV2TCs82Z37Z4vtI1Lbz0xzAMjRq8q0nY/3W/ye2M5sP6bcsogpiVZBadVWrQV68XPFlIx2Cg5H8U0QRzRVMUx
#nCvToiiKL9ZRqgrjEIeNjnGU1c4xTpzHOFJ9+iEWPmuu911KrhI1SNciC8PWZdrFCAfKMVjkE5NAjUez95WbYMGRXKVKsWoWjpv1
#HV4Yoe8965DBDkimhQY64t9u1ZjTgU3DDBMpSvgY6h7M0jTbFE4StFT9by564nwwKQ9ihIxKIXLS+jDprg6tXSb5hO2bTTWori5+
#BMMnbBDxxUBnJoPtrAN/ZIbNvcHbuI2nqtc4w/reVgTCjYjXXxMPh8idLb5FHfeP8FcX77cZ8nLCQe5rFu+a1qdauz7sDURHzu7v
#Q4G52h+POBBeY82dzs7B752eWDUO5/Z8S9m5AaIsvXBX8YcI8I555x4K7ArnYlu/MgAoLB0gUBqoLkD7MEUr+giu2ADJEkLo5vSr
#tId3du/H3x960U9ib+6zKXSInzLv4VYUJm2BI/QLxRTspdrQRbfroR7x0RtbwesF22ifDd06FualkUvpX9Bb5dbw9NU9g9kbvNvd
#4zSmDzExcytlLG5Q9W3Chjh5bB8HJKV3xnN3ywVMxrfCE4rHEpt1dC7hAhJ94jeaEmj8NEdIFmpgjguwKiD6PMDjC9AKSrZVKCsK
#IYdmTso7xpnnqeup66hrZRaIwDvYtVziV6zRDDUJRD4fMXGdNItsxxrrBoG40otOadKsU74dHU+RCqb6xZSESaezaeetqPdWfRZq
#QbKiooboAXB8RYdMb5/4+wBzcp/TXIAdFeUG+P8xyfP/Jv8L/7exhaG1kyGtg6mLscV/136z/7/Rfv/f+d/7v5mYmVgZ/if/NyMz
#I/P/7//+P5H/4f8mKweA+69qgPOfvuL/o//bHbtLBSfY/b/03zSIEFC7LKOM0EHe/037HebyX9pvGvAwSGxqRdTGpxBHbn/P3237
#g2mBekeAR8ZZEZWkycnfv/r+U4gDFmsPV1GlpXdZfrilMUMgo3qWcJANuKp6p6hO2auFnNdOcqFjkmia76cqyOW2uZ839O4T9ICR
#pjuIGJ9E6eduvz+fl82zaR9gH8P+c2pUJgpkXK0EJspg4vEFi7/+uZq3PyDPYQnDaHmY+HhEShgMXgykpMgGQOJTNgxUZ9/6/nza
#aG5OUTlGdl6aaOGvWsVaRZPw15TTtKeq5VZ0qVtC37f+Q85mhxL/zpNhv8O5WYKrbags4nQunHXGSKEF/O/X11tN5gDfAzLJQZHM
#cWVIlqbmtd8f8C5Kq7an+wbSChAb81Ja/Ndj1tzRhB8I06RSiLSDMPSAD+xemcSkCZIMmUSTRJL/VBLJxj9lVfVs+TLxdmHLlNts
#IVhtBPkNndVkNrKvA2ASBw5/1WdmSfQXcQk6kKjIDLLSBRcpa2PbZOpkrcnVMN65oVbw3L/bLDZn6zLzgNCOn5hONZYzbcV1SZOi
#+KMd+DL+rlDuUtF1rACRQu8nJ9n2XXhniuXNziTOnTeKCBEikvu/1rmLJG0B/tT3AdXDneavqam4PLpUE6WRRkmHLAYDkEH7qMp5
#ieiKxPdW/ZXuYSbjvXijwxCWqIS4uZ6tv6WsiNm1W25NzkQS4qKshOjmubqvtjxPeKTz9VzxmiQKIioKKizmX67XKSQD0H6acNFO
#hfz8fmmK4x9mgWasQWEekUKZcBuhcCdVBNZMgswWgR0X5MPWOsJbHpLhQuF6kaRiVPvfLQgG4cYeCK9e58WBt2UiTVaOXG01FTgV
#EYG/Yn+ihV58FMHily8B4VLnybRirEOAX9AvsFR5FVLoagAoxItNMFF3bsH4Nnci5jm6T1UmETr/+dBwROADOfwM1kvpBkIQFfHv
#x5keUCYMfl/gw+IRxmO17kesmQSbdQLn83p4QN71iKMZ03D28EitmJwuaC4zrkXBHmYpshvHOHjevB7s7VjbDKcbax7UpBpPU2q9
#W3cCSoqBGb11oLHn9p0zns9qwfLteRuJrHCk35uu3mvn9Kc3vos3Z7jzoVm3UJknaITIAOz0sYUKueenWNy5o8WF17Y2UcHSBdC7
#XKrNzU8pLc0BRn4xLinorJ1nMnY5SRIo0V/vmZ+HzpWGZq3c/SPtJGVFH6AMgHOq+L8Z/p4w6N/LOV9tn+feNl5cvSekBOdvErvz
#dPHtu/qubbCA9hw27TN09i2owbMPhMi8tIzSSUax1IHPy4qodLZM9HkPETMIYWETXb5jVb3juek27sciP+AezMKJo23QBaO63Jo/
#UKS3KwJL4ObwRyo4ht9g/gy4JbJRSAVYq9KXik3QQ8z9Tdf0SL+hGhtWSsnuW1q82XMbwTuU3c7Ew0rqc8v76BUAch5pXN2X9Nr6
#+9bZc4EpnvqQpZkDbo7AtywA18xR26PVn92Zzv3NaBi6/2xAYATrIu7gJdcl4sEhL9GhrKbLK11aMRAwsNKwBVQjWyEIKWN/jDnQ
#WUTZZlNRtMBYSpwY8ETKwvI58uPOapsE76fCceB6dKc7ODawH3+Rjv4Um74QvE7OZ5mCsgC4zW5QhAyAT5H39HUZNvT1+ghlRIV4
#qUpL4lT0BDOu02dQqRlocJLI+xpiduotmchLRYI7VAD0Qsmic6F8b2kFgUcY7dc+kYLvmoNRxBhSZInVSjZmAZ76BAaikqnsHLhw
#u9sKKxmtN9y9WANAkUTYZd7FxbtHMC6m3xiOO/Uv9b8RhMwsBEHenLNzJnBoiMFgTJFMW4XabLtKfbxcfV3FuZbGl4cJu4wbaXln
#eLAkdVvwx1EzaVFK2nLVk/juZQL4LvGGbe2DGrnrS5Ngex2xkr/U1hb/fA6DaUVkshyWk+imWU550ZvCuvzz8OdzBoPwQSARwahL
#p8PYwSiK7ohwTNF3CAOS+PHAcY17+5ZgiBAoZFn5ancwJMekYv/nmq8NgVSb0EfUQiolNQnOcCkRMKqIysjpZRHZ8In0SmKgj9ZW
#z5h4MooLFe5a+JIrAIkpjAQcUlvkYuPEcTmkAZXk8+gnBHTIF1VoLvZz/m+rbVdGjCJAI0/Dzcp8bd8gR+CjVMIGqXsu1yvSipMV
#fWzG7YdhsR5C2MbRFrhvGJ1lhGN084fQTZw+I60Ln2VoXXiLQe+eCOZWUfe4lslWS+6LnqoPse6PiLWP/FXfv1HY6ZWCNW1kQvnt
#pS0IyDS2w3zjTmL12Zcodv+knB0eWlcnq0x/83CmNQ/hHRsrNWwbYNZ27uKJKjvAJJxBdPPrcGr4AMDAocLa+PbX4TRhH+WRyphz
#NzVTH29eW85aSyntehyc+TxXXE0W6oYqYfH09qUzxWTUweNs9g++Z1m9WzpCbxn+J9cdGH4KdVTQAQhiCgzDYEYKNgtBgS6EmhAS
#WlpVGB1KqplQlmjWmP+0HFHNSlLoxHCaGa7IWi6oS6qeZRd9iy1Wk/EIHVb5ofoZ0bD0SEQY+rJO/W6VyI7m8cbCccdRnpk4+XyY
#K+UTvYBxTj8Q8IdoEBR7EwjIRf9nI/Dwfe8PmCOOiwIFXqQq+ocliapad2CN6bGnbIqRl/oCF4UB7AjsevX768pJ5Bf8XbrUVU+/
#W29bDz2aHCBd1WGPcCBqEetQmWGI2h49/95sWc7yz9Q/NZUkh2Yig3/vrOvi1f9axMHpCChlP8x+s4E9dAtZsuNsfAZWq2cmbcXK
#ieOG5rTMm0PNvuNR8lmZy+4dK4FpohUr1i8qWVL02P84x41k53HwFPYY6lbZQwf55uyC9yfzctOuC7JS5QPjxQUSbZgixWbh9dls
#Xt3SiLdtzKMF2D4bWmEaffMeJXC5vVIdkfkfRU3kgiupB5FXZ72zKBvBif070Fz8o+zvKQZVO9UIjqOnPLFYs6/KphggtKuW2wEK
#BrnGA7OVO7RKtb82AcmVNyRTQiU7r12MSU0l1NVJtvzGeELCx4E0+vFSkOFTu6tN4U+iJOIufNGJRFaFgiFQBUUURRIzxgulpMUW
#IXNmOkp3djICbjw3IslwF4qJM9Uk9cGYEgqqTRDc9PMjW2MNRjunMwavKWcQ7Vx2Tvf9NbGYnZEPXFDGiWx65UJuV2F76FULurxK
#3lrwgvHwKaBAhKht8t+iERze8XtWx9fIGUQxx8xbLuZLwJWRPxOf61Q/wvvViDPKR1HJ2dq/HcW2nsiDM+S+JnV+XBe4Xh4EljmT
#hEd387yNcYm6m/YLNNUNYu/3OY4f2j6j04uazqIHQqjZqzwMoFBotKI5cCQTHUs0yhQynIyK/T5f/1B9zuqLpgoDLxKhEQJsSaYF
#8pESrYxd5Sjc+BlXzsXAUIVvyMqJh4XZyYdOFBWE1PqKr5KdOnewKAXEoG1d5kXrpBMClQuCuaFFECRRbAojiAkdnSRJhmrAiYx9
#fDFAEUnEhqsDaAU1goMRDsfqEXQWjDFSI4yk9pUjAQ4WgGGNDbdCGWA0EUIFgtgbr5aBPWSDkNlccZVH0K2dXUM8qeVgMM0x2vcj
#sat4u6c0ZUASRAbIOqkTxjLIEXASJUKzIo1J7ylF/RlsxyXjiba0s6wsLLtJcPi+mRwQ5AleN4ggAgkg/usxQxAH+q8XtJecNtzW
#hFZbuJoKTpDEIqetpY9Z5s9nPJrDh8b+IcgUx4+JCghCJRxoRbJxnRe26RhQthOzkNfhlGMu+f5IY2MyCk6V9lC7gUDrheAB92lT
#yIVs9EGytKsJCL6gLDFPltyG6ZOb3dqNUwaiMy4JP9rJo8MjGYWOLvW7T0JczBp7BKJ6MBoqDE30VHTdHzQRffsPsjoOrhunuCNR
#CnmDXv0xQgZuxPkvis1TpPAlwxLV8/6jAOLIfSUc54d59UVhCT4kgkKQgBwQCJRi0B39ZAv5pbDOyv/JWwWihcrk5RhCLHI7d1H5
#Yp053drcbKGvXYBd6K0N5dvZVXd5hnZ5+YcyKZbsqvwHbbcbYwdIz9HTOghF/T0pFYpcNVM0Mqdi/8ppMdrl/tbQMBgV56tMjWAQ
#ajb3Nzvy7TOoJydQOodvGNfmwtV+M3QyH+BLwB4Bd9pRQuLZDptg5xEgEDYwIhhrrPjDjaAFE/dRjSS88ZBYiEThJj5ecTJINK6r
#qawEybMAwABY5IciAx3lJ0kCYfpeBlI2kbka4n9i672N9BVA0akjcXCCDKk0VuNDIIWvOWU/twKTAhYgQblRDyMZyEBng6GKfifO
#AAhvos85ibCxGxXnWTt+eCD7j3BQg7nAWh4QsyHMHz6zXw4iMZZ8ybRIdlzAsTgKwFM0N0AFgoFOdD5pm0vRGtZ7e2WqZk6MAvQf
#OM+6fSI1IwSy9ou8c2z0aYUJoVq5lUS+HRtyfdqeEVwYJrs/5Zy3EEbgP8M4XuSLenyajXiGP35oBu+aP2BBN6Bj/RUBfJzvZ1gE
#AqQGsL7bLmNCwYCNbhBL1hPkQ0nlm2j+T2dEoIR8YQd3hYtVFyzcIu4ln/MBFzZdMX6zuI23jbthGYYm+TyApoUaRJs+5ge5ykpP
#fgQsQa9Oyp1EuyYGMt5zbaof+HV8gX8AGm24Xs+pv0sA1T//Fzt/HRbl9jYMw5RIiXSJSjPA0N0N0t0lMTQzMAwlXUqHtIiEdDcK
#Ckg3KCGNhEooIiClwHcNWPt37/t+nuf7nuP95/3Yx/Zavc519nmudYzrGReKxRLfkkCgY6udhMsTCdjh/u54WNFXDQ5x4etY7SPt
#rwJiOaS2+0EKAy7UPfMPA87aBBVNveZdJO9Z9eRz3nQfTefFT3cdo13yXqsZHaZ9YxfUkS6Mm1o+Np3bKeS68mqQajHdDwOHCNxl
#rKMu9PkquR8Jk0K5d6R2eRKrWir1811SkLZ6vnYKlVXDZt+kE/yNhfrxyLXs5w5T7F7g9MNXnMZmBy/rAr41Lfk7PchavOc4L+o/
#a8ptNVb8tD4xYeNNnmw8LS+TqtZMbWPUNfo4U2Frw+FudCja0e4qZ3KRY2JHTbV8BBE7/mHxaQlkoL3OPESmICqFYMX3jpQtOnYJ
#JinVc7a9ed5o8+8DfCnRHFqyNKfNONVkCXpBHnd77Nof4waXNaRht6Fi6Phy9x/b0kqLv3K/VkJ2tZzI7N6L+7fLorfqjd1FSQ45
#ahXuHSgpucVlbuay5qOPGKuhUpYsZXyUCEuhLmu5d2LznjCBKU9p3Wx5fqBs6ylbmfij7wVg1Yb7HjxvtFGaHyqg5+7Qeb4e1cBi
#2Q9Llicu6bybjxE5VAvJK0y4NS9tmmNGJKo3YYiVMGRIAsdo5oqVWZ++1WBq/6VE3/LHWktzdOikkdsMP2bYKyXJGppNYv56CWdc
#GsY61GoCgpTAK7A0sSjTtyqs+7lTKuSFZkz57svtDSbhvNbZiW0zUZSYar3pdNPWDBarrGbgrbqo20cZEraFNUs1x2ERs9bwPvGW
#qD2rvCfcRIXY+oe4GcTk/SXL4YHWYvWcncrdEy8Ia65+pDezVHrdAn+wMhQeq66IrZ/tEsXfWcTYlmNPGDuuqek4PnmNAH+UoZrJ
#jj55WvDFOAEuuxGfkd1njiiFt3lvHuralw2nikJXCRXr9UYKp12JyI0FfPoHvum/8v8x/ulzTOr+67cvlpfurX+JeSsq3FaRuagE
#dnI/MSByA+OzX8VtCE5uw81SJlSjNntR/Uk/s3rPdtggxwZTv4CoSLkdxZ1M00IOb0SdW+fE9eZ7VsM3bOwGzdw8B4b8Pl1xJe1x
#mtPVCw7wVeIZmT6/FbWcQ+1Bvcf0K1HRZTFCKE6EIdaItBf2Rzi8N+ML4TUC5Lm61a/DdCZ7+XL5J16+eecoOD4X4N85hJvlUaRp
#3XsjmW3/Rkx4YWiG/LAd6/B8Pn2boadd5IgYv1Gs/uAbKsmm5Cb+6oOwFfPbQkEhwV8GdqNJO01kyjOgalZvXBY3btp9/f4ATdRo
#HU/nrDC4oqeC3kv5NcWzSV0Dp/4weC15pVJkdQxpG8qaUy4F3+T3O+mPTvd5AqjGfjTNn+mNZo3bNFf7wiVeRg2TGRx0bZA4Zqfh
#6s26mF4VbCm5P+EwnT83MlSZxvncnSWusfiU2wP8NCH66+u7pSiRMcuea3hD4TlShfmchqybZvcK+6yp8LDwHuup8qkrTshMUuJa
#CdxrfJ1hTEWgpu+hSm32TY8Mr/R6PiGueWzRk5SIz/XzH/BhwXs451hJ++zzlaXssL0apd5NH12McCO7FeNSjhK1gIqRnXnrp3af
#vXvR2Q2qT8pTzUNDuM4R11JZ2CrdwKOEcdd53xuqhEjyfsLER8yUT8589p41IVOYgqsa2s+OXPHnJD9qyZzDD0Vj3DpQRbNY0uKi
#6EiXwT0xN7cHTd+UNuxLvqPVyRD9PFkoy6ji0cTnLv0AkZ0ZK4n8lL0iVgLlmWv0LohM0WpieVn6Ac4E9kJ2kMtW7YcJArP2TUHx
#Zn5qZd1eXsRKpsfTl3WfLEeSJ8Vmqh8fjZD4FS9ivMZ2jCfO3+AVr37DvD9AaprKlsEbCS3l/67toMR6NWCD5H6Ykfk92jOej8dM
#9Ww1MEKw74vavK4vsxGzTs+j2KgVKccsPiuKj43juBtU8gY9wRANLRVbzDCHfBsK4qmapDyCE5kzDqLHgb/f6ZkZN3zwxBnLvahP
#1HKyIii8oF1eNJcE9Umc5iezV2mVaObFH8ONaYJEHAxedJB+pejb6hjE8y/BqqrvHBlQv+7XHazwynjBv1YsTLcDv7PctoigYdPv
#h7UdnJVzZ/49aZxbiFdxl1jTvfVnNgX87vSfnCKDRxG+eBgcrlb3csaUNb9YQbhM+hjWSF8rhWNWeWVHfi3WyZE+TxWDPSQsq2mm
#2z1W9jkNH7Rt9Zyt86f7xHLUkfdCL+Esbmm/4+S9MwyH0clj1GR0itX1gbiT7MC3H96lXlH6/MNRniKdd4uZ0E9i1PIyl3XDpiY8
#rCPH8A0nY+I9moMfmJ4USt4JFpoKazhEtxJ1WmTmV0KNyJhMPvjsgzv1QOnlnFVj4ORMlXkpWENQ2XLmDb6eXlUZsbersuHLb5Ob
#3qpzxxzzFM3Cuutpq4/Q5fT2mPU03u20HGV8opwanpSuQ7Qznxi+AAdoaxYJe0hurDVK6WktEC0stobjgydnHj50+sZdYyef17IS
#kK3svEHyyu2F92Nv/B+MS8oMYjWGYVcdoFaT02pqBByzFolXcTU2eKeP2t8KjdvR5apDKlhr6qwGGQp2gwsepQ7aCYsvgL8dvPR3
#FmMV6Kp5UUmdWUjNMk/c6dGZBKvReXrKnuKXUUNrrUx3mhn3Q9vYk1GT6k43v/2AvNfeF1m9tqHZepsZu572LNPHrvzb71aCZOsd
#fbi4Kr7o5lvfOG/qsIbwVCxcY5Pwon40nDV4Wzw6xZdmhjCb83T8lsbWy7L107KKzUo3RKDzSash4kXZwyWKHfoTnbSTqVP0E2uD
#hX6eSNgsZXvrW3VQ+b4SSd/nUhwT21ByXMGyM3oqcuzW3qlmw9RR//hguhPDOLBdbeu271QRwcyKq976oUf2lGbp2BeNHJl9fd2N
#kldbuNWy0wPu3Uu9D/rd+DkOaxcZM79fDc0Nqq9nz2QhunlvdbUbOzM3pI1sx4Q2UXKzJXREP+KWYg3vNObi6pVFulYejG3KQSlF
#BpHb4WMd2hDQUBDX10emVaVWnePPrmoLboR6UxvCBaD3zTqHXBtNn6CIlLL3Vmh6uxznaAcVlIr6R07XMUwnr+9TNPvquYhHd1VE
#u+zkfjLaHHsiKTM2xrvodDZm94UK79XVueu+nrdzc50/FWo5CN2le6Vh/wSDtbeXIXk9xDeOgfljm6vaOXHmSA4OoYwJaoGYgMSH
#N7oO4Dlz8ZGuVzvqQp/GxkgI378HsdHRWbEUHU2f29i8KCPJWn0vhhMssU71AmyeBSYLi9glbXT7xItGqzDau+t27QtVlRBbWfzV
#xYKRH9rEwVwGy7HfrOqap00SW9rysJ0Pcr7BmXfywAElGN5lvnG81vei5oaVqONO5NSUHe107em/UF0/i9uPX2Ilei5n+er7q8ny
#OFPJwzXdquE5nI9ivBlbaY4wIziCuRE9s729ZUKLpp4Ih3PXiPO6RM12DIij5vsS47TNBAPFgEidU63K0Q93PZfSncRHuRxXpit3
#5EmT56kbQz5wWdWmDGtn6sHZmaIq3MuXPxqkPMShbSJRpx5p3dzkkA/G5mxD0QkKJHPisFWPzmYxZ6G5F35/PLbIU6WGRl5Lvhv7
#LrYBNQrOi6YqmHjd6s4utk3vh7kNC7YgD2dvE1RattgSli3jp9PLr5hZ5ZTlg5VEREterkPsPePc1b2MHTeDH7k1OxYxqL1r+VBa
#/X3a/HOQYFHz9SsTbaUruKnPNa6RlTYOxIlvvAqok3Rtuxaq59Vhiehq2ZckHZQof1VkyCJCHkAm80EmZ0zm2sQ06W1yL8alrd0b
#N6+I4mR2C7jqUCVZbxqsNnccdTMJEOzVjAj3hOpG1JJmaGUcv2TyVbNVE9nJe1Yy1/Wmg+gRWnVeQ5bAC+5Fx2Uvn2O94ytdHXKD
#HLdkpxNgaOW6we00AuUaw3m2rjg4+OSkJYHmq8/UmVEVE9g+MjG4au8ZlhKmFKENKLvUOcF7RXoxu0PZFDxWxt9ZTFWA+NS/3hsj
#raLi5XlzvaMM6iBAaL6Qpj/7CiFPSSE3hFOqkSXWGZL8mU1N2NSKsAl7sxQTKt0yei76zdbLyGJ5W+fLyOm1iY3Xchwzlm9u3w70
#9u4xzDZxvppaoEtVyixCf3TDkekRpob8x251/6iZlU90EhZmC7k4sSiVPL7G3TMsixksEy9sbwbdtFLs9Vvm673NkyJUkF88VTHO
#dlC6rVsYbnLno/4wqucnuPabCqxWA1hr6DztuOI2+tmbXu2NnJCtCt3JcpGnt289dt3ScDyuLVaODd3L4WIi66EhI4+WE6B7fdct
#olJzF5NLi//WNZ3q5XG1mWENTlUpPnPxzFnOGeu0Df+dsMdxE9Dz/lBeytoY9cf1HQyLHlwYXokY8Q+SqsmnUl4mYM82sLKlydN5
#7ZCfbheNZ/b3hlYrfdr5KBkp1xYhN2Sg7czbyM6RixG6wpXlNxPtOZhgvkNm9qZaI6ox28aJo4b42BKDeF/zmtBoe9c0PycWIWT5
#ybSQJ0o2ceQZBUbhzve0V+8bw7png9Qs57gToKw7yXxyu9cbOnKZe9fdv7pzDPebbhuYVq6rMn/1c0Od7rkvaLKklO1+s2q4/LTD
#J07UboEa+mqUyuIpoevD7Y7x+qsh0ef7p591PhDPlHq5Ej+aK71m6Cy3V/p8QvjDfBNn3fEeBzoLyzUlpbqdBYmViqhPHata4kHd
#5D8m+lRU/dIT+sqOmmmeZ+PRu6u7Z1AnNAWOeMRlX10sNScdic1N5L8lSSRAdF1m7+s3B4Y4XQyoKiamJF68C5ZLhAc3bXQ7v8+9
#ugQZ6+rT5GcP6Vjr5m+IjNx6C6WwoAyMhMyXlog+4Z7HFfGYR996g8ESfYNKorG+/olEjXpui46QnjBx+bh617WYlLyWkJZZrEYn
#xRMRhb1P3gcPo/fHV23l7hngPxQfxT8WQDv0t3WJfejS2Eva5fQDbKGdbersriv9AlMr6tRER4R/LLfjOfrEwtxxolHzg7nZxjtC
#pd6kirVX8CCc9XmqxzRvTtO7IN0KtwcGvZR4YtNWieoDH6f1ZDw0+5iMHiAMzRA4vsrgR30totCpnjFqECfygPKzz47lXQxSZRz/
#ftmVryYHSgfB21UrFrmDVTANLxtrIZ461PQRuzNRf3dfVOEnVQ+EYlNRVtfDj2E9G+M3X3fFm6xV4kSmvSNStpipqcrWMTPIgr94
#yqLT+5F6b9alCv5QQtdMdine/WFSQpZvsaUC/DUfn+qeKxD6F2vtYgYPvjDXYyxO1TWIGhGrXbRjwyoT2u1wj2dGV1ccDBDbvCIz
#9gktvm67564/2QylX3TgYDSPBucCUSRNZvZNvBaqNn3GGwxlXgyVXqPEH7OcHI7LCu8X7Vip1LQyftW+4/yIEq/XgyTeOy7HSbw1
#gMFw9qsc/NbD0KuOL9j0QxZf9vtH+SdZtXFzdQSSn+ObVlRWemzVsz5btsxuE1ONO5I10NhcL6R4GYJJEf0y+PVrHmXozKSDIGeN
#CUpPSNcH0UOEI98s9r2r3UkvoxaVNm/o430/wpKYls1z8zdkbit/vKRln4OP/4QY9Hi3q42ANKfC8eyzwiiHBTwbdp1LYdv9OTHh
#TvFHxx190lsIuqfC9IYa5EYJWQ9TbfDCEzvfvPhAGG7H9+jjWWZFO8h2Sm3EC+XsVo6C4tSHj9lgkD3fwdDbvUdfer+m3BStPDzY
#JvzhvXq/s8KkwKDqTMtsIeMEz3pYf+S4rL1l5Q2xTaFMvoX+k5wczuucgwkw+jl6esbyEhxCE8Wo/XKpK+1RPh/uX0sTPr/F8da9
#fetB7k5i2PXo6KgnnWzGG6Bi8iP+hZHRpa40letTK5BKaQKGtq/wawNXCHf9jVFjNt5tOMzwDdeotDST0Qk+qOno7XFyHJH28LAP
#ZzcXuCHm+j1qp3QTt90+YHZsJwblPRSe9zQ+9Hb4ofactz3IXJioy9Pd9Zr1oKNema6ExFiWkSmRtvau10Lv/GwyIYOHXCrzE7pq
#mxhXSktlPDx3NzicF6X5zXiv+O1BWtkC0+8mCx4rvUua3ARqSSlTys9WywY833spT59089z8jNCupnH0f3dSzNITiu25bW6V8MyA
#4lbolqbQTs+HrlGIVIbmV82lt2yN2zBrxgRrzRt8N02GbA1Cv6ww9GW93xYjmcfnPZ9tRbFqI8lvaxTSP/ox/W69YoN0gwChaZsf
#O2DUTVBLT59Sk5xG8E4b93iy0WgpAG3uy0z6l+qzmAM8rtkxkRj++v1vK5pfm134M7bePW0nkrsrkwSC9q4N7sofP/zBaPSqZ8+x
#I5VTkPP+xLKcs0dA7K0EzkHyfqLC771J+MOeY+gfCYtm/ZBt71Vsrnzv4999/6E7Ac3U9kHfuwZQDD+4FwVskcqpPXGvc5bz+ADn
#XZcPv2Vf2vtoG+yi0bLgQWSpf6BhTz31O69uENWhnGfirYZKw1awRTJnIin4iQEx83GtXyKPV9DsPbYwVM5m5ntSTwRqM5xpTfoF
#Xiy8wjNFsy6EoRNk03/Z6I2wy+CTqGxl9By6QqdfI9XnzR6wbMLLkjwvjF4QhXO0kbtvG4mKUiNEhWK3sp3IsMJMfCJIujevwO+J
#j6JC/BbR+l4qQJ/bt4g9TovbcUT8bsFRrn6O/DZtDr4Y/XC6PDF2yY+mwyuGLXf3qnIjD1lEbj9pIJHUDGRof2/2FWXLCXXaA+cu
#hoeeF9qMaVWwYmtKslzOTT6azKfXEqJRjfC/LnIdOBxvW1t4srfgtvvyzJXrfm6rVkYb86Ciy9zi36ln6mdcI/KLxMSa7o4Ra8yU
#gSUOeqi3M4S05t+PFBgPMmViPqqopFChXdzqMWdf8l8fHGn9XrTOTrIstuoi07+oS2okRZZzRc/bdIGxMaCSG/78A8b2Z/xHwWgP
#qFTMv1HoMxQSvh5jkpP273u1SK34ns1MShS373iNvPaGz2NTxVbmpeWyU834sdtiTkzdQoc9X0967Zo4v/eWkWV8ffDB9N6SqkLr
#R4WXz3UE0dQDUVDRngg9NjORwj4dn6IDo/ghfJYFP21Ijk4cf3k617XniyODi0Ow08y9mnl/1IscbYX2rgtjYgX7Hsehjtl1h9DP
#dJrXCbTmsHem1z78iIK+N9ELM/ykafJs7CYrN83ijfUa39xpTSfedMEwAou6bN2P5HlMNG4WdUdSS+kPUdGrQ+ebr9h2S7N46O3f
#FV9vpCp3xM13xHjR6RRIzUp93RCNNEXJ3qcDIzl24CPRXIo5yGdbV8ZaDuWRVZfvTfHHB3aftg3c0GeFeeTWqA/e7GJVJD/nTpRP
#nenJ/JD7Lv/VUMJpSqrQhCddLbmyGzZK/I/rE8yag1jaFYOd7wbYyks7YPtWcdSdtBZdTirXGmqrY98TxFMN1ivqfc9u40goJbVV
#suwhdGy0TCEeq72tjL+cQCZbutoJ04w0bKA1nTX/dq3Hik3RK2x1JWd0nyaG2eHuo7orHK3NL91VsRZK0g1Ljr+WBycwT2WJe6A6
#jmfBQYQBylQ5WtYZwgM2SRJ8kcbTu/rHbO8MRoS/0DJ/GBrCDviIE7zppUSg63haF4bZ87Bzei+LFfR4ULM0ABeKMb+Q9O0KZ0Zg
#BqZhjmVy0ItwCQvihvd4R8a6Ft86y6FcYEXuoc6wuxascoF1o8/kb9ApfCPoxOEcIyZRy/VDXKuQx0mO8n7BDWPbuz1uWM36IMdG
#lMmcB+s6Q+tYLbY7VrU+CfvynVtPzEPRdDCwEqSvtu9x49nRgV9a22fa2xIdiQomYY1LJjFon6jyiFjYHrm2R9q84iQbGmTXk8kT
#s6tV22WApBxYTiQQ7HaQhtIrZ9DREclrJz9k0eqRzadKOfJWVloDGeg/3fvgMGwtgPGSRTHnTkWBU7K4podkVrRILu6Ju565StHw
#fuLmdgXIOXJdph6nbrXokXysUc39bbvwAcTD9KlqKdsNv6/Krxlpy5OLtXJ1+6/Fr9Nw1t1MWwxzcVFx0C8We1uiN5SURaX3Ivm4
#VqfDxEFgpXAKfebJQ7NKzesPZjU69z0rrrBIEQo1v79v1ZuSPjYYyStx3840OaAn9iCu9KqX4FZcy/bXd/1sGDfExFELv98iuJc/
#ip3kB35pO3mTZsx6SewzzOKByS3H18af3k6f7bLpltVa1FPwW4mTK6rKOIZ6YxO5+SkWxplW5BPQUgoy3KlRf6l77RGfE0IqmrPg
#9Z204KK5exnGDVtjTCqN1M/Nn9GM1g8eTA+SpMxsPWgwWDqLx6V8LVNPeFOO/LXsPiF6F0EujQJ3HLYjzIqKFfYy2mjImlAlRms6
#7xjttXQ6t4GLVdCQnJD4yS4pTqcVCZu6COMb/rdqwp9j6uKovPoN7iCsYzvkjY26FU5rXo3Vpo3k1tnZFdE9kBuLc7EXGgvWmS3v
#JTOrwc1Cw625TvZAqIdlxLKLsdJtcPNZ3STx0hzTgN1ZH7UkWDi0kxZ+xM9TMbu5y4+lDMl/4PA5JghDSTts9V4Tv8ADGgbZO9Nd
#BeaopyX8kwXZL9LB4+cIWfbHjJPEyW/dTjU88Fz4J0u+u3WsFXmiDveHvWV9iOh36hZBydaxT5TkfUMX6JI3NTMh1l5nZpideHI9
#mSRNR69cRxd+JYRgCbMlsax2V/lMTWu79hHVawMOtCKVbAv67+XyEf/PPYj7f9nfv7z/tLKEO8O82N0hLg7s1jCoDQTqDrH5+RCU
#7/+bh6D/8/tPfl5+Hr7/eP/Jy80n8P9///n/xN+f958GuiiEyG/fPAqK/pf/9v1nsMiNakPqSE/kA1AyrGAa7MekhFg4IUkYwZ9k
#cMMYLh+CRsghH4KKXI1EwQvWv6Fcy+hscB16Vepw9/BmhqqgF87jq8tfBqV7QjYENNY8CYpW+qh/nLMoWVMvcLRVlAYVBQ0xmOhZ
#PqjGPkFZNhWPcYlzndDMC1/M9eHlFVVnNM8N46p6qk9xdd/N1KtyuC/5Cr8kJ88JHirLfXHGak2hRyZJssT6u+m4trU7cbfA9ESR
#DOBKV3PBxfMhCvGXRzcWV2PJ2z6h6gdM2zBbwNFw7311pBGVDKdl1d/WO/V5NH54dhqNTUhzbZkqxBDLSppKl6wYm5V0PEN3ArRV
#XBfF4qLIrPDe+yz79EnjqH9gD2FSGPO3nkdh6YpkiTaLEWFrU7YeXXkDlE8Qe0ktaWvbNapoDJa2FmSUaQ2c0QxhBDQJXKQJjDl6
#ms1mQorf25zqDb/rmVYsQXs3jT2nGz7PRhE2LeBGlUYTiu08Pz59zk0jXcFoH9IqE5KM9tJ+SyNmaIg88ZuMc8Np2YKk6bhnXWHH
#0EC/CGCBbqF5L3cKqBVT6HXpMChsuiI+8xEH/jDHPx397B1AJjMrFfpqgoPUaZKP4pO34Knv1stJLLlSurnZys9RP17S4ShlRp2C
#CL6/TYVrMZa3gyT9YIJS969t9GGdSPc3teZ5apWVKfB8t2gYWvQ9Px8qL08dRuPL66mmeVeAw8KHC+fUm9DUYA/Ni23qfBKBf/jy
#8bXRVdMPZs1rKMfXE2YJscSdmOYd+AVvSs5x2uFjCc58Ig/M1rzK16vZcTTVJzKzfGiHoxejH5KHmZNsYhZA0UdMte9mD0f9YQLt
#VMY0Fczftdlc8HedwKSnuEblcnLQvDAyWBXejEk4s16dEERJeihZ9KXpx3jszUQexlxMFIV9pi/msY8xk4NGmf2uqL8ZWF7KdExp
#XVK7EzTEwZ1al0qt8ll4w1lZy648msMz9jygruX8y/0NJsYcaWUSKUepvuCw/OAIYVIqGg+UOy5uYg+2bo76RBB8tJ9yveNw8+1W
#TFOGl5KndP1G+EYheX4/xmvI1fOlqhTPs8enVmlLngQ2uqwdKKUTaS4Tm7maSxuadvKwB5N5OCGPYtER+BHlnbuEA/c/HrfBqj43
#oGGX4x6ZZmrU4UvB5MelKJkoGvOOxh+cQXS+b18vRGMmoCoxeKvZJdhaovmE5Cwr8sRfGu5gKY1FG4Ztbjsw/b423lLN0He7n6F/
#AXpuu3qjcU42BAObjkhOhgB25kXJfrPqTar0Dk3wY13wVH2MJ51D9UDexjewxQvPGIcGpnSXzzFWsZg2IPQYmd1vn9Ew3qGjSGF+
#pZFGIcA4ogmOX1jQJLqjfvX5Ck2dFEiOhIQes1Yl+A1EamY3VwY991Vpzr1rmkmEY6CnOdw9ssSqsvNuV91GxdeDH4xZx+eqZxFc
#F+OSZmgPkyfkIgiSi9Hqy7D7SBa6kfqQMDZHChVl1JoG84YFVVAOhqCFaDlhHvXpa8+QSYu3YytPPTGcyDJq3FAYpr9Vfy67rm4s
#I82Fcmcf/PD5DKqNXN40RvWQPxPUNKdhHO2b+5sml/M2cS/oZrVDYprSVee8ovtxt0Voo7Si4LqEKAe67beuT6+i+GLcvX71U3AC
#ypKobJAMgU1JTmLiehWF1nQjvrRUkwwFoWasuP7NQfk3SnOCb8IlwiUCGHsrFOm3aLNnQqGyTfbkXFiYrz1uso11r4vbtPIrKj9a
#lxZlpaesv1XBTdToZyu0G4Y9KSJLyNxlP1P2lCLrvgzKy74KUOyP4B/J7F7UeHRLdNn0t+m+0FTRc7J6U/rEiVlmpbqVi+xiwVFm
#GFclB5xlpmgGd57GH9Lhbshu72Zo2WBsGBQ/XpeZpVHTN7Pp0hYvHqPcpxEIDbOPmFckytVdoQm/Rp9NiCeM4vgDS4ZzR/Ys+EWd
#SN5B0fPszHiryg/wkQ82cR80D2zmdGVvPaJ/dkeg3LGOVWX35g/c21GKo6Gz4+9DZuscPrckXOdNupqcsNXFyfQ8c4jPumfGzWoB
#PJOFeTO6HHMndQnhp7A75RFmu0j5Zf0NRnHjUvBmaRRJaCb903uL1MuzwWcJASwlqwIJgjNzHLpNZ3EyseqK+49zyZfNRMcGlQrv
#MjGeO1Ceo7bHKIvsgaEKEfO+tigHGtFnUEMDaeeS8pFaMpJ7PLI8D9LWZCRInhW+/7xX53fvhJg3pLXfnSGpqVhBmEwApBD8fp4w
#0k5l3/vlCzXHB9kTBV3dzQ+N0xj4liSfBsjC9bIkBBq0Yj2zcWRKoszQsbQs22UIXskRq9A9388XRDfBzOjF88VzNDhfLjfdoP5E
#Z3jMzftGNvCbcfxch6P+3X53PyyUYg/wKYzatMbDlazcN+nusnVW2FImXresVsI1nCAwimq1S7vu3HjBMWHD0LKWzxBpWOpxMAhN
#Jmzhh9/n0hm6FJxclwlnvKklfbSjQJp9jFd30q6nFN+fbSBeoqOJlEEV5n8ehri7sqCzy8EqF53Zesr3NkCu5tNkW2q3Ct+tm94t
#0Xu56sYsAsNNgntHX7IIB+fRD40sNDF4oHMBLUzx24fouy+FV9xXB0WTeir2lA6+NhbRhYWZX8WMu2don9uSWW8ibYX/4zztDt6P
#jDrHQUYDU49Blwn6H5ra2jw8VHAcVmVlKsd7VJWmJenpfd67DD3Ld9J9XlfvPCWiSVBOoKHS12cVEHDMlcm158ZqEYrBKFl7854Y
#pClVrEk7RRPKklLMpPk0VTtLpPzet2QqPk37iTtPlYhzbekjYvhw+GftOXooHlDBxCr6CwkeObLqt3iimTWPETDQKGJRu2G8Loxt
#Z0zjqnwW0rzJOsXeRMsTDrq7ncFvM4+C9fGp51CLJ1lYx/EtRXTH5BMrUJbztMPcV26c90VxctvfqdUQGrbYC65qx2Kh21/SHmxW
#OSsHNFtnoKmwfcaSM8NVaxHtBL8yr0l2ergi/sPYfxlzoIH+k8+6BkgNFMvq0Z6XPKM5Q5C5wYVVTrcQpcHNg65vL3OgVYKLGYpR
#6hCmWh6Y0mQriXGslFB89QFDv3a+WvhVCIvmOq/66bedd0QFA8llmiXKpKWZRI5U38njuaeEdBq2cFA7ygWwEfe5DO4Qa4swRMAz
#RtuTH38ordr4JliA+qZYk+hUqVCsn/+t5o0ICrkoUJoRTX5jRlLJKf6YA6r7a6YUMvfIwbGxuV1jwtgQdbdn6nkkqmxx2Lw0RBSR
#mQSJUDZ0eVLWR+n6DDUEhthUMqy5TukYRKAOoj1ZNjac6TR9+mIftARpg/Pn39ZqmDxK7e0ySAIPWhX7Y8ExrfLc+0kMsMniCVcK
#rl69R3xy9QFrWOcscW+sl5xWAkvylCOyfQp4k85yQuhssVjUZbqM7wvkRZWVcGkrsApwPSwab4nxdlHqS5/Qg1ZUTzheM6xRSsWS
#1vfVqqe7kxm0S9d15xppRYOxTQe2jemudbeUt4tuSYf53vNs0swNvV0/2UWNKoept/7WuCHfEl7nzs98Nsv+LimZHnP8dumhxjNv
#IpBVTOubN5oj+5oCzdu6rrPFWtl+PqJ8dNdQruzCwDlnlJqP7RNznppaIXSh1zRK39xQsmfaBnHS15Ye0+tVa28rZk1N6txw0f/K
#NlfGaWu8o23zTbP3SvbnEZZX+/U+XDk5L6/0WWqJ+e3TyVtNvyCkcOsfI1ZJo3RVCw81Rxyr/CD65BEgeYCJ05jGfcuSsObOrSvS
#wbi7INCa+5WqUDM4hHUxufFh7kdMT6mS/txeW8xw/Rn7BmgNVLhZwzJjqNaRbVjewGI0vbr9KbhapkyM1/vx5Pu3BErc7Jp0TMu3
#xkvvjoWLhxXrdr8kkcy1zljBiY6MUujY0LouLrhTyhX8VrV3i6zjBllP5gPF6mE8nb75DrtXeUKvZSyM7tLa0kYcmgc/XQybenlv
#Q6L33suypY4HlW5tumcvssaKrhFLcp30oH8dOHczztlDPwvzPiPtQMeh0lUNW38cqKGVIxdL5iIi9Gyfgsum60alYa25IEdgl8YR
#f1sb7VHPXbbUEioD2nx8QgeixnKodU3Cs00OVIbNV7RKcHrIVW3U/Lc2dzJqbQYT2TQCcDpTiLK1WXQqZQpYJ0vKpq4NF5YuLq0H
#KXw+6SVAkTLY0mTPn31k+mGb9SZfwYxUfYUhFlZkhNKd6PK2RB1Nbffc3IKnH+85bd6uTKQ0B7843nmfhoKBY+V/+02HPmNuSlfu
#pail7j/pS2BBZkl219o47Z9Wf8f81v0ukSiZVaeSLqVYO4tKW2WzeVNSMNkJ/HpCwZ1NlnvIlX6g7+yGXjzUKWbUMKas9226c4aM
#h+Ph588P/SGBiegOTxcWic0kw3Zuajpz889ygDHC5LoY8ifHmF5f4Z6cpjrQXxlYVPguwE6xHKpIIWhi7PIDEFB5ehxC25ciZPIR
#ml7+uelWrrhBcvSP5WLPbh5JZtKuRBZh9ThbxjCbvC7xodV/OtBnSwjmitUhV890Co64pw1Pekb6EvPqY0ZcIvalE5ENHLm9G3YS
#SVg3pK/SK1KwJJ6kdQidcxoHbuyMuZA3iG4niDfO3E1hbN0L9+mx13UhyOcfB9cNc78V22OvHqOLrmjswbzhUqsTLaBBWJcJLg4l
#Q6HheFqZV3xbBexSHzOrrG1v9yUnC0WWYC099Y7p0KaGze073SyzzR44oqfM5JwmY0VotJpDDjI95TMJCVFvcXWWhlEDzypNsNRb
#QLF7C5RK3fY6I67bxS/vIiJ0XkCyE591Z+yVBAR9jMRiAUjBbpgflo8xvuxMHE1DuCL9SbalTtwbm4QDX73Qpj5m6JlgzE3z7oQ3
#64WigblWS+q0DKYUE1rTXe1FWLTc/F6tMnJP289vokYUP/tqScr4dbP2vq1zNOYYf6zatWn48jliTuqZk9SCto5eiAmZYMrkqoj+
#DvFStT3N8HMXm06ux43f8FuVhFAHDssLtFRQpOA2WJa0XDQkwToRGS8erhA970Q13eXw4qy/SsbRnxfjq2d432Yn1OfRcfv8ODZv
#+IatX2BffEDtNJEKe908DlsFq7cQJDFHrp/YqaLOfLTJpfF97s42XlR2EFWEfThGky3vyzXpcit9MkxWipZQe8V5vhOeb4osxOKk
#kZERqEw0jwvvklDchYPtnmQyJIXBAyMShTIE01pPRYnqCfZvZ944m7+OMvsq/iThLg15Hw4KajHhumIZSjelAaJmslHo8Ys61TcZ
#xhZzN42NrXq6rHnZla84cJP2JyzjoWXgTFCp3Wq3Bqtmqd0tSdz1zgetg9mu0tP1zcudfn9ThR++u93/fl/endUiJ0hMzB9lravN
#7oWqoQwKSsvBBw/cHwkkFunz5HFoexxDgwco4uzgq7evohwd1qO8myV5B31tdTdhhI9Q8mVAXizKmkzXozBFWflxHuaPB/NmCbkx
#6V/vGY+0ZwjxfuwMd/fkSGl54CvslG42JNKKkmomLODJVuk1sox/l0wBEX3ffTUm25yCnG3nvsHm81jB86EAETYNyVfMPxxQJAK+
#d0ujvFuO3try2Fyundyp9pneb28JfH/mI4WCwo0StXDlSDWACOMrtwW2H8PSNHg1wSTga7to4LPPz4jj7jlme/o2LKTHILw39NTO
#4jhmB27pjt+AVj+LZFb3siWTXurXtGy6eiMSQv6l3nrkaPi4j3ZZayk2oza2dZLqHT3/9SO5OvKnFqc/snvV731JbtoW+fREcdv3
#U2gbXWibmtfwjbYTZpyjUac553gKkdMSfqJpx/tbnnOQeHo5QzQiGSttHBEOvnoxCoR1/kp3vOBtVD/xj5zKz7ASVzCckhm0rrNQ
#PywYSOBUrBTzJ9kqSQPL6oL0CpWfk7PGck1wdcbqOT2WmpQ4jlAkM3WbvJJm6ql1t/nmAfXtLx/R/PCIkrRovoqmM0iNVHSWGNDk
#F6iy34ShakNU6knK9Z+cFxXpOlKmy5rMuXgT7UisrnzHKTeXXqlWfrWRZieXEnBoGTOxF9fV5UQYvu7OoNhj3CEunW8QpBRSFkFz
#KFB5h0bfWR7TXiNjvgL7bYECQcggw1uPmTk2hlovtAG+SIS1SrMkS9dq4rvp0+/BanEcUT/W1lH3P8USGfA9jgWVWE1/t2a/d4CB
#KRJVMxHJzIh7T899GJPdez9x4ljvhxDHqVZ2SGRTCeFT0TbxWIGSeKvlABuhqGGK/pp0X3myB9YqkroFyqq1bplXqIdfUTgs+l5n
#UHAVurpMFElyRetrTnMtWmSuqkLYU+byuPsNHqEPHcodSKt0+dAEXlhtyDbEKtcbs2Mgrk1EC1X0ofknPJoulc519qGaiKNTpnAy
#GIeRXvEwwHIWwJWkrrdfLOwPDRDJ/GQSKDfVcJSKS3TYFOrSeHytpO5zZ2qk6KZ8RUhcEjN09mkhoiRKRhOchXarWbr+haEoqnTL
#nV1upoDWFZLmIjZMzXj9vvWoN73O659FFnWFcptOgxlAKxhKSy8b0TG0v0hl8MCw61euP3x0t7l/K8u0vPmanhWJio8CdUp0Erd0
#HbmjCFyQ2/gNBuu2lDSvyabuLfovNoMm9PoWJhyadMSjYe+/dpLqCXkElSWTKuaqm4p6lCRTh5fCcvTxykcePsvbz3ixWJIaxCe3
#8cwzJO1LyKR49oaBRrb2GTszKb/hwkFZy3kspe/AoxFjmz7EoQc5f9zRdnHjI5NUirQU8jxWGjIMm6HojyIKSorQR0Udt/Wf60/5
#2hQGo2IrvYAkK1PeUsZ+DrmTiZVSZptTvh8hs05q08pR0SnXwzuzh3iN78+qex+uJpCXk+uRitV1qNL0hqGAGar67L6A3NuzYJmp
#hAbawePGEzm2zUTapdfvWGmfKWHMM2LiEYVDiXAVlFBuPSRQfYglxvj1lRQWLa72TmPzxyv8X31OQIoeCVP6/oMab99VSLC3LdFR
#M6VXZ1j3MwuOihYV8XgUpbOYk+B2Z67Ifi040vrBgpqcU09qT4FH+xR9YXEspXX9wLBXsAnfbeJ+AlRjgb9VXgYVTxqmvPK4fJ/4
#KnwcA8u6SFcfg4l+OiYXaiu8dAhrMCQ0L1KSGidsL0LDpOOmLUzvepJkz+2wSZrriikntwrjSaMXsthtukMydtdQ4THNt3jNbvsJ
#r0dR3ExaVjT1+hTRqsU7eN+2ifb3+8FFPrzstYRnfeDO8NkUig8/ht8KzeLLBFdmU/Czb/bWxZxcK3gjrK5/jY8FszlyS/6zoHLw
#uHUB4jhBvnDMbadId5j1ae2Is/zCG19dujvmqVqUpoesCceDnbu9rUVUmtgVCSnTU5qCZNe+Vu+nNKjJSbP2Jko/5i1iS3zllU6f
#aH9IWb1Kh4e9I6Ucwq+VOumplGXDYM2lbGasYrV5gt3b1BU01ytCxzE8PzSF8YAoXQKF6rEn72OsV+WGnaR2TXVVryP4ZzPQs+X5
#rdGsp8Dnjyxt9G1ezvJXKrY1X82rHuvpvP2k9vmh5k2P9ncevKTP68uO2Oue3oqdmul5rm7/JV+jxbqxUP2A23LQQORK/Vz785K7
#j9Xm1Z57SurE9INw8gvZsR3wSbwdRW5GKA5w6KPfewvxoGgY6u7XUEw9iiH+6FO/xHbfubDg9bdPBTcyeFMF/fW/yvRI23s8srZ5
#NLBgB6kiK5gMsck43oCRp2+cXFu6/T7AppZXuK99geKp0mgsVY1Gny8DaP8KP2b/1ksHTwlMkwycbwqkOShqh3Za9uWjVAyPe1g3
#g2xJbpTZhcpxri4tCl2hszwRKoNFy0naffsSnI46QjVNx913zCMkQHyDx0X3DY2WY3ktvr368xpWKgbW2Cq9Iwrfb/V6atFyFXsN
#6qoh9+z46+/wiQRmJuTKrjUYnRSuRuQymN3XC1xM8KOScFMsVmA46ZOLnc3Zynr9GqKKqLLu/nF3/mTsSE7tzkTXtXvXmeTj+19b
#K++nN+OoqUzsd+3hgb4PxUjU5Y1+Wue1I32UWewTmX18lHY2dZod4ph760tXNL/+pAfohCkdYAs/py+496vFGFHab6KgCFeL1o6u
#oqLs9aPsC0idXQnORqOnSGolDIwgkM5RDos88aZL3nHutCdP4SVk0TlSwNxQVoVvVGit5rWaXpFQ6Bl4cg/zqPz+2APudNMoyxW/
#ow2BZ1flbGnoHGInunEV7uIZW7Jfd9DpnOpIPuiz8Y1KlBdWW3mJGHZIKfv6qDWqf9maP4Oo3+uMYX/QW0vkecVMUSEVyL0EvNv9
#SFfZVxBxNXI1bjHSDerSc++gaex1/jK1I3UWmW20tXm72Fu+u6R5cx4FLVlrlXdSZDCsJ0iYblRUME7j8WOfzK2UDN1nzxQ/hB00
#p0HrFlbq58k/urRvJlNf6+suOxUR7b8XHb5V2nUU/iwo+mX2w9HhuV6h8PTnrU4f1IusVynPZsJX9nuVNl1uaPR5lIRq8vGR6gX4
#CGqtReQMoszKM+ClS4GSsITKYp4QuhJko3YaUbMnPF0LrqkdO2vTL7nZQUhtiri9F8KY3EehSakTlaXO8IzrgTX/U0F77CeFziO3
#Ge+brWNB4OQaXSwLQU8cd0aVQspRYgO8ZwaXELIORJhRxUsuvjulH137FI1+pEtFpE35E6k+VggmmcTOGRTnDXd5FHc+1Lzu+LnV
#Zq2FhneBPJlm5hPZA64lwmDKMIV0187uUG2D+NxRU0sPGf9JLar0vOxn1RGJNBHCOU2sCWOS24IbuoPYoeViExFvpIxxXZdeTmhb
#NbzL4jxhfTC1SkLSLbMGNikMlDrMyrFgs3/nVdM7zc8QSLJ7rQf1I5EalnYMaoKDeQMaP5hPIlynUxa8wTpQtmoKVW69Eu7vkCXw
#DtNF0ugtS54vg/Ry0KNxVjflB9ztq0FvI3kjrsmQj/Mwzsl3SCc5gBTnV3Q4OXsJfUeT2fBsza2a9vtj6h96VyZEp2vnURtzoG29
#cNCSSCsJaGCnwDuUMFyvPTGsNbZ7dMfwbnHWavveIO6T4g/m+RME7+aNTBaeGJp3aKU8V1U1PSof5sweUgtmPu/tx+yNQp0oIumh
#opF2Vh34ytylRMuqG1JtEFXljhPkWIXBj+rbYLny6GHbvFxfn65N3kNa6ijp54Ug0asdb6zR8hexIaOyqug9OBotYc7OuAYx3/BI
#zlhQeO2Vv/TV2s0Lvr5yrnOTmlhFbi6j9D7PsfBL56vP33/ZcOvH+mBtU8mVwcVjVN45o4LWgR+QoUuwRqilzZEuOOV+jcbfVPt+
#/RnmDIZ0TrCMH35Pe8JCIUlswlnUA6nldHPWNu4x7vAOGjS3TIl83NrEex+jMXKU9D73faKtVtgMLFCYzysi/QEOPLpypmIXoNCO
#KTrG+OzTl/b65fAXr4SrkzueBFxN2TTNb5e+q7L3QcHNMcUKJIYewU0UVahtVz/Z+UCV/LoQYn+hD4Y3jeOttlmqlDGaYmCo7M/M
#RhaYJf10Qxp3edoxbF5RuJHMl9zvk/g4r9lIvIm0DR5Y3fM1X93VByTLp6LwQsaZh1Xco/ho7xZpsp74qw5K9iV2/HiTqAy5Zb8V
#eE2yq//EUawo+lFHS2FTNXbnQIuyFX5yYARbYElBIM2JKC6T5rr5q5DP1AQeD42Y6zqX44K/Kg+JHhFXfDnhnK2MbOYUOErEermk
#lOD6lf+G29QtmUfChnql6DXmnLkEMZ/iwyYhDW3kiddCemWJLAjj8NyTmXKmwnFv6VsOt8lHUxVW+F9hzkHBlsPLgfJvxJsloUrl
#HQzttwbodpL34rlE3Gpn0tubDCG4SkzaVzahYJLkV/cO7eSGTPmHBeP49KF9PZ7h8GEqJ5miJ2JnAaSyU6jBrjtTer0qsAGbh/fJ
#j673V73ZsFZZ/khKtFOkubP//YrH7EB3IMe790ulryLLl3DiDS2EVO7Zv/o0XlvhVumw/zmZ+0e3xMs4JV561qTndxJkHjxuFUz+
#9l5YXOIOwXK1IXTg7iMnBTK6Ky9YaRUehAfkZjwoKpN5XPau6f4V+oNuErvGyN277gTSq2VHdX7BIFfpouL3JgFuCz3vNrTFv9qW
#hm4n3dqUqG7ezKa+V6lorzW5Ru0U9nkCjHDXoYROrdIUyeJPvnkQGXZVHUoww3htkU1KM5Mlq1/Wod1qn+IrRrXvN/tn9+0Ogx1D
#i1/YuTM50+YI1733wUoRmdP2Jpwsb3TkZmuzUr4yJCC//uTAOEySmUERtpUWWS/ztfGa8nBekZbSXIjQwOdjUpl3iWgzjFYl490K
#mxC1wWlrC+i5hsO3Yp2umfYXN3ogiDiu+19ebNpNDgbdHXfk1r/ZueOq/MEj/GRxgK0QI8JETz6rXaoakyMMsQwyPopYu85b96pm
#mZ6oStsdmv/kWzT0Uax8ZL4D/pYRUUESibU8qfF3JyKfhn51cCPrzoLFzaYyGaFkk1NM/czbYnsOn4/oGfZ9n/I7K+00c5/azkF/
#6FPIkxj1VVM89JOnQgvRCWRGNSq4FaQM6XD8UvmU2f9sEcRrJq9iqBc66kD2UuOlecDIQ3JWFuMJnvKWsHI/En2aJbbBkjfd5rjf
#i7/UoT0xHlCqFemcThebWA+Q529ocnZmn25VRdxoVZBKdV2nUybirlR7niAbMqdovaRqAqtAJ4vgoH1MKKIvRepKr6amWXNKy9Rx
#5+WQ9PPjIPkKOl3ZpTJo2e5G9hyqUWN1C2RMq0z7E5W521Ki/vT3qDcq3CPy6+EyLwJQLJtNoYTRVy26N3BXvT6jWAatuN5pZqB+
#gNnPw8TBFub+Zm05wYgsomNGGUzneKXb7Ws2mxPr02cvNW6S68QklaLiCTvR0xncR1VxY+B9FJA3VBzLxvD4FcQpbD2xNPNb6HOO
#ZJq3GD9YdZ6EgmZoI0JOd+zqhR4yGT2pXcy4X8biqzSraar9ju3V1xHvLwHzxrZ3mXLJxQNtj5+VmQ/7a/tTx3l87npXztjnuudk
#Ic8brouZmkGVQy2rSnZX0TY6ucTj1Rv1ryC7h0MWsuWDRVApzd4Y/h7LUP6gQBw8UBuNFs71xrpWcs/Tp2Qa1aWp3GS+lpKLkgfo
#T8ODDql4Z9q9esaJ8EdIMvD1jnqxyPfXM3Q++ODza/U7bPavCFc6yazUY7BIU4qV9ds++CDOiTYfWGNZ/uip9J55ihXhM9Uh2rWs
#pJWXAoclWNq8ShP6dJMWenpEcEMi5lxuwjvGb8sf+tp66vhf2zK6dvqalRlilPWRSxwqoXlVx/vWPdFv5ad3wOzaAhUPM+5j0in7
#NbBqvBRU4b4bFnyc2qcy9jh4ajNg/JBE/ov7bcYmI2aewrfdIzz3bfS+ME1TiNBxCRmYHEiJvFTwyZBgcH7tIV4ia8gZoB6PHujv
#W0Lh7OXgeXg9ltpkctNj8XZp0dx8VizYmGtp/fVTuB6F6y5rdXiEgVPzCSid2FavUGvFb9uBimFFItTgVIadkp/lQ/gLnYObqN6b
#9awHTjLulTCXghdCwmpeoOE9b7ygFixinHVj7ZzwvlvKxGh6tya5CsJs7TzN1KuNbwysUmcxGD/nOMdNO6V1cGN5Z9pfkS2NzxjM
#j6bWNZnJLNPsezp1bZ5OfzIo8iRrQs3tqIeZBoFP1GfSN/u4rrxaXHws+ODsiVnpXXarY9iAI7vSgZsASZjypJNnccDacqBH4UOb
#u9/PzHgtZXMN3J8U3yejrDW8oRoxrob2NaX700PsfZqbJYhdMGkcJX94/Izxdzeo6+OcsrQXxQfX8wqurTszP90csqLWP1WuY2m3
#PP9EldzfM6SynxON28J0HhVMflrpn6FGXm449M2Km5lQmPTUym4bfl8Dy7iUPr9Yj4BPUk7KXaYUs+GQXPmr2MeaggRN7HeJ+uBG
#DFJzc7VTPa3AdKrRwDTFB6ElTKtUde2KDsnF01h307PZ1MvgU8OFisbezQb0sjD75HdoB3L8Wo8o71jaUZAwiafc2CbZs8DfoZ2e
#uBkXcHL9HW9nmHwQ/UADqcA6/+nSCUNr/kHHdpv9x3pneaN0vWz0+LfkqmOB+0d8dMUBXmlmp54pM8LcJvNDhTca1+dzJh1Ykmdv
#YPSfNBPd9B4WnCE5jzUwMh3i7JmKCUfbUzhLqBrgauyTZrqtK/LpzGLt/r5r3nroA5MaM4cR1ADjN8J+AubugiAm3z2Cuk3B2lVx
#pY0zeXnO/BHxsoca6IFX3jEcpbTsEd/Rldh33evUYblJEqWv8pygFY127hbeTPlZzsuo7x6y5ZqYloz+apyZp9M0L5M4X1xFXUJf
#M2rvVYshODrvpD5c9pumCJF2X77CvUtEV3jNOZ9+/ywW85PK9u3DDhyUs2IXDaliR1+0oDY5eb05BNaXs28/ODrcFpl7XfBULG20
#4zjDNCG+qaFi2CguvKG12Yuf2uwSTh6rfmzE87TjkBLCXk5y8b9JmSkQsB3t8E4RZdtDMyAzCUdoW3wLW05s8W7XcwIUTJToYUVD
#+rra4E99d53m+qQwH2hifPVT9OjaiAnL4g9f8Phott7Xm0sho297Fg6rexGwt/8lr6aoLfgVjjmt0fu6Kj1X3I/vyMYKNN7DP+5N
#YotgfZwcVe1q+Mifn+XLMSfKuzooNpUhfohmyLNwY4TX5wXhHBGK8yN6u+80+TBhLHoUEA04VBM1iGdJNABfvY6Ul++uwh4aSurU
#ccetQ6dDGbXQ92W7ekbonVa7SRXaB2jmKZO7pM/ykmhiNHl0aYQ7qCj7dO0q8/QNouNU5wakPDNeYtaTGqb8cG3nxmtPL+pWl332
#1MM7Z/hgqe6sHdSnKeWIY/RlXX5YM8U0wXBRe+quRfO25+tkcYL6ORnaOXasc7eetg0jf8rw5ZZczNfj5xW8qwKF3YjIWJq3Bu6E
#TNvt7zVscQoiOQTuuUuAA/M/otAo7cU8GTAYrVW1N28j4KdRkbxeBzdcjhwlQDc+nlALdb+dg3oX9+gmy0cvp1fvhbudSQrc3umt
#SA504Hxi1L+h1Ng8xFFbEYtombtjbSJ419llR4Zv2837KT80Lcb35q1xTwecW+ffKKPFZD5KbI4/OBiM4EwgMX+3aPmOwtuUrofw
#y77QsNvkQdJ6dyRESUEFX+pbH/MDoce2VWUnymv3KUMnJcXDaIahXuBtN4qa21/CX5BF60Cidehp9mjqMNEIaw3kWZMLMUMFrK9P
#N8yo1yiRVhoOk9FiuCpNftUVcqzyDLP29AV9KA4A2dbdOBR/zZ/usL1ZNSeifjdMNjAQVkq/GDH4uUKgChUF9W5sABTyttzWV69Z
#3c4Yux1z9tQ1q+FNOb+VOdY+I/mjR6PXYutFHsaiT2peLyROF+C5uU7PJZ6AeIZXYRS62rpXSfDklGMz+ovmy/hnc2E50T2bw/4L
#ukXjfHOhZyPfMEdkeKOWP4T4vmpDKefxoccvcrY3Lljsp9pwBIWPSWV5N3q3b80nKP1Y/fae88G1zQiWybez8xJidYmCrjD5Gnai
#/dlWnuilbCGqBL1MXelaN32Dlve7M7a3Zq63U0P7RTPLyV8OOvI+/Pyk6lBY0P912CDjzaXhqqcWvmjKfZ7RxV5Lq9nG5Lhggrl1
#QE6vmvD2lzTMyY3uHIrF1LrijrQlxef0YWXHJxFkOl0htDmzJAbP3LrNvfJDNOxpj3sYBR+Bssrya2N8RYH8p+ChqEED8jeoWVff
#P0shPJLqfYgFB9O6YXv5LDvVz6LXKyrmUUBfRWCTskCIMWwtw3DPBRXQxbFiiWKCRApNFcnQ8ibWne0DnTHdokaUYQ4VGdXx3QUR
#EQtUID0f3mA5M5h/402U51ryRKkMmC0UtIgcemqO5/ou3PkofdPoTKE9ucbN6ZOf1BhaiGY2UOxjqei52+psEhH0U28pcajolCvl
#OuIAv2JEJJVzHs0SFSV3PttDbpW7e+Vz9DHMxi9Ap+KEWSRzxF5L2FwzJA2FwNWa2HE4LNSofvljRD/BFZrVnNL6UqpvqfQjOd/p
#WkQUfJIE5OIHhE8GT1V04/2IDa5sdlzhPqzzYNFyCCIazRxwuuPvu5Ijd9Bz/Px6zayTW+ki7FOXX1b/HZt7fqZRQTQEq37UuQel
#/MQ16eOk0Zyv7Q+ojBijn0UbouxgFr3VnTMWCDytiu9pXs9k2WzOLb2jvd9vqorT/K1kvuP4xwpz88a7ttdHA0K8HwXYq9tKSUAD
#cYwvuaPM/F/fXEy6XYZ7VZf/nObevpMIvV6gk2NkOuu1CO2SttHsBJXGJ/ZLG5GT9956TSjQuTRs+WNr1ThXCzQ2cRR1WEiFNH1/
#nnfvyROlI60PppJvOSUkFPJU57vWZxaZXaLuNBAcXXv7rTT41rZlBZ5qOP3AtHbDPT6FaZeo6WLjl3wCL6fnfVVr1l2yqSGQl632
#Ttf259aDWefXIVo3Szbl7Hjp6YakDLGkIFqfgvSbPB1UNTHbnVCSTayJqZb2ovE8UVFuEhAReKJwpbjfw0GpQxtiS4GUeMsShilj
#CX/Yz77XRiNxdiT4DPUDD9W3z3fMys3DIqb9sS2aMQ+b7q+Egi2sOwxEs9nl8kWaVByyS/Q1bGJJHCKgemV2s9nqbzZ5InVffOGy
#cny7MZUhq2p0aBARIZ5Q6qgUOEo+T7IDwz5qupHvcPScLOCR0eoJXFMzu/Xmklv0Fyvmtb0P0w+yKewLJHP3BBWS2DMG0pIfYlv5
#pyy3b3mjcI9pmF+v+aQavRHXQH1SO9v9efQ+oex7hPhLjzAVSYxcLdLpuI4b9vwZs+h9edXCuZVUPHqhOyoWN2S/v03AIKy9+ZaR
#SjKYTJndsqS54NqQOoHVML9dWm+cDfmPOSfhyuzGE06tmSpDJQfbT7e/x69NynZfCQ2smcy2JB78kXGoUTZFIg/5cbPfXpf1pDbT
#mn+YYlLrxulSsH5SNk/PdXs+E+PYCbekq2IBrOHHokmTHyowbZi94qQlqHyiOzMWZk11kg4OpjJSqRLE50XvWBW+V8H31TLpZ5Z/
#89IKMYsZeSL1I31P3QFcWUp1cqhy6lvQxmTsoj8eYh3V7QXVDpha+7rxdEChxrveuCS6npG7ra11sXe3gZm+2fF9seE8sZZjmeim
#Yas9fZgzSinia+gs83Zkr14NdsM9cGFUC2kNd8M9ukZ1XjLZEJQXeCha/PwCAW+2sKGsUvxjOTxnBt/IUURZFb9FDMcEjuXFDZY0
#w0bbaJOoxb66lNLCHJ+ksxbMXu9JchAcXErfJxzVrdbaf4vS1aGGSVqb1N+XbfH5dEIWM1RYJFe/6LP8g92nDg33yham9j8i1py+
#Z1MZCHJINgquCY/GiXQFjnILRLGuvzqZaGJuVF4jHznPUo5UYVF+YVP6dFf/RXQg2tL5jcNpbt+JctNhvR8gZbtyOsepkINi9Ovl
#bUGGHR56jzwj36UQyy4FcpV8hVjXPEoNuxGsiUtLcN1hkruGoTr/3YH0e6dYZjDhkYqib6CsrAEsyYhw73tJZam+hi8M5pviYKH3
#qNPkZs6nSbprYTxY/CdUZb1kfIkHQR9hWLFTDqMd6ih8zTkPr1VsFEveLS2kQ6cteGy1/Ql/9EpO3d3UyrNReRStLv38kA0bta25
#FiFHz3W8wwzZVyxWnR+xMF2EAu+GxL35znx0JKOAVX4e005dMHfk5X+/1hVe6n4QgCFtvD3qSDvlaUE6n0ZvE4bz5Xif+e7mPPxq
#CN2wF8mjCO1oxKkXdVz+/r6VgL73Ol8szxbiaKWQWpQgzPDq7afoJ/RhKeGbKpqotHSPj3c8HtW995hIiN57MPVa655WUPpSsz+j
#qeNBfnhJOxfhhHWhxX170zUVrDKa+g7eN7DdQ6O07Q/hmfYMR30IXV/sIC3L1zdv48hIGoXVYMbcSHh71ZqFilyGNmw+DbeCdflW
#6J2aLNWBktQJD496mSPXD1dJR3YoA75utr003YndCI9o+yTEuzib+3aj/87clWRSNJszgb1VSal8LgohThVONhN9i6TSq4uCuEtH
#0WezTWfLT5p4Ky0eExcSYDV+sJAk2PbaTOTJX5LbEudMQkmOwCIcVcYmUwvmw/LTgTxXaN36qjg3eZee7iBZzz2d72rsSMhCdsQ+
#yjSkl3VQZVBB5J0dgb7U++E+vOtZN6KoECNGVRuIj7ZX3u/e3dpqdgko6plW+8yXnEr12DGPpTkQtzxsxyQCbQn1RVXV89bIFbXh
#U5sJ2Y8fLAPbpxzrKmyHn+sHjpXPBKRCZhrSBG8Sqm2lqstSvqDpWKesTQF78T7LVgcYrbPe5gv1jJGooM29gZyl8KhsM1hdiPn4
#pLmJoLUCT5KxlMKDppFGl5Urpkt3FL9cb9Rv4/u+XdNP9HlAHZInVBOGMCMJ6xhXL1iXqmV3njnjyQz90cAQUWUYniFgmiMe5bcm
#uHZvZP5+UxADSu/H/NtfpF4ZCpe5bnKj+b5il9jHygp9jH43jfLTSWSi0SF8oafguFUVRDCksOsXgPHKlXgErUcPuyDPcxJc4PcK
#nimz2PBgsGuYgOP+GHvloiTKjyismQ+DRHYVnwWXWmWqILKtnDdxTqj8d27UVVWW0VPCYBok4N1e+gcvDCr8B15QktbS828bC0JN
#WN7CpksZ1jYrcD3ePCHFvpI4Db1hYHarMDoxHlWzc8v4C+b60Zcksh2OYSZXpz0O45CmySy6iql71i6xg1p638KzVyjw56jnZBpY
#31AY8Lm4zzYapIPOHQRx+1LGObJYqrwPdyUdu98aLJaV+52fk6tvfasSU+K9GvcijznQe/dq4vmduR7lliqogiLPYs3U1mwYxfqm
#i7ZXB7v3uNOM5juVB2gmz898g92tGpR46zsqNBkam0pjnZpYsUc9X3zE074FlbXmJHG9sWCOOMAYUtAYK22nVLi2Cra9kvF6JxBf
#HPetpXs8psrUJ3jN/FufqfsHkWvzO0WM3xSnUje3S4cnOCOuX4PVfiYK+1R0NnJU8jly+UYd6xLRrQZHQyVD/MdTLWdiPYkfdvGw
#uCpJrR+bcdb43aCSIl+4Z5kQT9VR+IW6iFYFoj1C39tc07f2NNE43io/gG/0rfFN/Ib7e/4nHS4VttR1UCcD1i8mwvlT8200Zdrq
#zpp3U2+m9qFK9cGcrrex7+Wfvg1R3Pu8dupz5sxH5IxNfpRq8DVtc/vOJKJ1cMpx/3Z6Y+69te3kprjm9+Z5rxclBfJ18avSC/Sa
#Yke1WL6YWM+V33NqCQ79QVrgQeoT82Kmf8pvp3Fw/Pkr+zqBBKUCozv+kQxqpA8eV54Pdd3CztsoHxcu8dfIhr9ffFhaxmFWVXz0
#nWiA9FxMTi/gcKRBR2TYSaOOkeiEl3NjX7Kt3eTrdY3GzyuUUy0tzR3kw3NayRWn6iOSmMGBgtNlCnvFzh5C00QDh5xnT/27wRXl
#WyPqKVanj2IUvL7UChQUZb3/lsGZDovP8Df3d8se/eFyx1uNorQcy0DbLZy1+XaS1LNl84aNjIj0qfh3QuSZoora+CoZZO592RV5
#ETieDtjaPQKtyvLHsK3+MgVt4o7We9slgfkxFQS7tH5ZLz7f7sf/wk1U6rGnxyiQyaopv7janwCx2uiyw5jiv8bFsFSUyes+TW1T
#8c2InBYMydg8wZT/rj2Huef56qGByGuz2MWFYBfKW2WuH9oM3Lk7taePebNChzByXuNRpVmaBPrqmnzbHonY3H6PVtki/fhK2NTW
#iw70b9YQiDWMQH5UnZlL62Oxt2O/gSU9Sn24XNcTzef4Wk3X5U7fjaNSJgqP0fu8cQ2fUN9MHxTCZT9NNxiouMO0mFahhyPppyuh
#Y5iIYwpibSYprgAf3ucgJc+CVh/p7Z2sW61BUcIIyGQp7u9AsAZRYIig9vBraUsFEjPpZMlvXYwZ0+ziRz+SH8JOIvLM58SfRkj6
#l0pz3J4bN0tfattK8i310dg6eiv73jDAbdyguxuGOYESd5uNk2O5zW78/QenyEDvF7AKtMpvTUFrSrsxWt9v38TtiPrmcpphQDdJ
#KL9Knrx7U0OHR34tp7nEChdziWOghLPqDv9jnieHVk+vZB+drMI3lvu5VLp001ZXGmcJElpf9ZZR5MqEmvsyZvPWhZt3kH89omsN
#oueidpY55rz7TIDsCg8oJKVUVCI4xp2ZlVQR68NVwdtvRj2iq4QpvE7MNU9oGaxiPgadnLf6NlqEqHuAUhzfJMhSfTauJZLhDoP0
#b/A6ErtkeTxamGJ7u8RaJ2OfZ1YMbfx+eLv/qrwfbcsz8i1fGoKJDfRkc0WlbuO6xpV3yndM2vNPFgLuH/ORW2qiVzrcnT1NpTKc
#780jPr0lGSqAb8kSVu92v23JWoqiVgWRLHxeYh+UCWJyeVWg26xoGYHq3YJyIuVEYIvyip6CA22DVkz3223xZSfTumk4bDr8C28Q
#W4lEAJjnvO6ZwvlpNgijUpUoPTi3/73Mw7n2DppIQlncVyb9nzfrip+mXt9+PnpSwgR9tY+nkgvOPd+pvHJyCOG/pi3L4PvZonDt
#jKMm3uPjUY9+bB31W72yQ84OkqOO07KUKtF0pl57vVz2g8eNdg+yZ18/fUnShO3+4CbmsdDg7baJxvu7VTPHps46nrzjX5vh387C
#n6GZ1Ac2bDbXTculxnYaEdxS2nuAenQjiJD1S3GHCH48phVDNt5TecdUw47QzrAoE9pjUTKJNx+TGI2U5LGTxTFfW8jEjUObg3kx
#OCzDgq5ct1xLf5KuwatM/kRPq8amtOl+U5bnOLNK5pXo0R7Ckrfp/DgE9GMrH16Lk0U73+1pUI12QJCHOB94NvevIqZXuRf8lQMb
#mPeSV/Tr8Td/UKubNbqZh6/j9onsMRTUzXU/nYt11aQj9TdZduvFc9NmajduLcM1MeC5h41ijCXDH7aPNVYV09Wz1bZ/5WQ9654U
#7pfeL9LGBEG9DyfdT8O/jwbavYvwN+fGiVkaelGzFClvmh3NRCRJ94T+rIXTX22I8tuxv+kGbDegTJCmyb/V1TUAxtUOQx82Y1Pz
#Y03xf5TQ7yiZoiRZkfJ8FFEgunp0gpaogoua0F73VJcl7ERhrYAONb7zC3e05D2bBV7pUMcbkfw2T8tNVagdPSOXY83cblXoQa9f
#WUjdannJ5S7IiJuR7JRnm3m7khS84tK142rnX97qa9uc0Y7+ov4qym1G8qqX/AuT4wTZixHyBFN0uB0rvkwN+YOwja7D71ZxjhLB
#km93sOhNn8W0H6CO2WK/T7o2eiIU4V8kkB2kGerB/EUnFpXAcHQYE8Vwbmoy7WDqauGx1oebbU9Vfdysh1awjqbQufrD+yc/ECqp
#f8quW+5YUEPgwz+GXku9HYla/ZhoLj7gnijKIE4XD9leW+Qq1oPWspLC58Fmziz7agM1rPeZFq3Yv3tjDtDOc2tkBN0sl1pU82wJ
#yxfz3L6v3Bn1pJfra1+EoRgfg4TJ9WhuX8PHxF1d8RSdwe2fZnYCN8NxJj/wWEh61j1bb/E8C4yOgpGamWq5fcpV7M1luSLjYn37
#O40jGqZ+kxOxvNsqNDX4teyCf+2NceuFj84f3EQzntyvrSaaU+LptlF5xEY+Z7ESEPwNlSBEc/u1f833DG8fy0kWDrtm+y/pP55u
#wV9V72Xk5+x0aQw/rYo10iVU5mTUY+vBeoFDrx+bR1HZESmNfnPMjhLLVMnmPGztapH8lM2L7HsNfaPP7G+WjNpHb+xv4ejYMfnz
#ZMTT5OfZEcAduX02bAxFYNpxuJSg/ReLVboHbCSr35fd5NdOU4wCZKDX4SvnFmsL6MqQbJkaqZJNAyjrugVZJIc6ru5zlwp/2ppd
#9sijePuCs+AXtRkvTxX9yCrcCM3iXblM++xlVMzvrt3Jk2ngDb5ybdzqSa5wnCHc7IWLeF1Smskq1c2vcnjDP+StUPKzlQmlTrkN
#l+9wxj0waFhLsers/H4b6mhXkfJgCBL+/v3VbcooCO5A9/v3Kg/iolzbuz4ZFj+sLDotapqYH5tMwLtvNz9CbmLVkQNOh+Ip1l6j
#9aLZa03wfTtP6UPU//g23dMNrcyFbkJim3cb0z9u6zFmjkZ1xyiH5wW9Y/oh05juXuFQtHK0SRwhbRln/w1m1Bz/JNwVH4igxFH2
#LR7TPEhKo1dq5lvgqGoVXK0u039puKRaBr3xQvn58dv3tZITD0s5iVtCm9ZExhtTBH9MiFmHTBAkRmjfULWzX/5RJSMSc0YyuBZY
#UsakIApPtnhWfnpjUX7MIdNjsucuE3Gj7Vwr0wT/qGZ3yKTJYuLAUuvcvEwNfn3Tly8bDkuBOS+bvtAUrHe0xkDNSqEuOnVDRgZp
#w5UV6C8pv/Gb78U4+ig3aGS80Z1keZ2piq7wVRDtld4i7eKk3W6mla3v91nNbjw1yUPlKfuBdPYe5+jXVv1UHpndzkN8tcVFBmx6
#k1QNrHlPqWKpC2KK+Qcct3oHRb8d+BA2E3fviMVMx+ZcQXlGOxTsKhjGdIb7AhO1GC0ozZ2X+cup6SLqCFlf+I48aFwJRVcwmo4U
#5WvT+/KHj4K+YdHIaaJbbeHzGlkqCuYpalk7wn0Yy7n4ldExFGWdWov1WYH9eJrNqfiPBq4am82VnprbOblcV156PvXx6FmrixQo
#u4u78sNy0vMj6uvMBQMMfDeVSm18BiDVWXL5O4KW+jTaImsMZcJnh7YioXc17xNPUL6q72nO8wqlxiBg4rANR5c1DYsscXvufqd6
#ziGx+X4HmF+H49qmdE3Qe4+osqtD6cS8ildv1TsZ1HTYhOCvFxrzFpK45C2+1V8Yc4TpOohKJs69KYBsPHyDMDKyLqloOt0xwBzm
#nK5Ppc/gdql6L0z8nYvkOYWhj5Ft+QBW0KdBle5U2P0cgo6m3N1OUDwLeJ5wMcqpFxcntXaGvgrSc0YVbf8ovLaqq7uAydGwNYFt
#qJ385qPKyn7s2/MvX7VkOvo/WILmlBfPCeBKcoulG28nbeB9fEv+saenH7yYiX+FF8f1JhF1ATsexQ9WTDGOaPo87nxDqpojj9In
#w2JVtlkGdcNlNcsBosHqaJgF3O+Cs2OxlqzM+1akmXUGiYb2yfTv4Zq8LOBPiOjWCwvHaMOjmBfBelFgOR6h/lnBncWSmevTbbyO
#oFdfucVG4q4mXmP5IAdWpxFlMCTjEmK83+tTFwoqBDG40t99V0Vxy3zoevuKLIPQxjT/3Y/XwM4Ft32NawlSWsMcWsOOW/P1bAmj
#xx3wsfWv4I1ELLu9+kQzMM59YyktmOuGt7M6TvqrjKPhI9Rn5EywTHpJtPm5luz5bWjNHJvZw+8F0Iy5Tnav70ekGwPmW6U+Z6Tn
#OFX635J4TdDbB9XJUbnI7CSF8gpmFhor2RZnIm6d3Q26eR67c629H7/nuP+8cGl2Lupg89NSZgtn2EvSbbpZVILvIDOJT6u+Q1AB
#hPs334pwd4Sf2Dj1DC8bucR70uXInQ3FLr2EYawxMaJgzgfpBEfv6xhRW3ElRbHKDrTXj9YKdgIf7UQTr5oZJAyJ5j12I7KGoqPs
#fNrcyAmw7yE3RL+NYYoa0KK6Ane3DtSIxlLXtXEeHgTxkPd97ayqIbtzNRfTAl3t9o+Jub1DCKsirddA8eK8kJAWhxinog0H/SKX
#HTdaxtaWQ+4IiyfHQsiDmdhJH0p59de38O96lWPBw+dvcDr6nqAdBagLdOwHTSSKD1LX+BtaqH9T78667j7xvggup+7WXPnygzrb
#7V08jSDJof46yfRsUtIPeyfdaq+ZmHo3Vm1rRWI2yEzWKc2kFnOG0Vkk8n0nzrJkm5taVTbXHyeNHeWHmdQ3KLjsC9vs8kS85iRO
#ZVnNEEf9oG1MGSVWedXlvZzGIuaoB3eLepl3F1mnUGTDe1XqdGFJff1DdhUJlXnl8rQIdWMr7jcLtFzytz1mEnXAWhrnJNVHwi3u
#VJoxlIEMWb4jp9lqMKlN+lvEMJabhW5y5TfggWieK54e2SRtnAu3QvGjXPCzNzFq35oLpg2/6mCvpDXd55aheX/nqRKmjE7S49cP
#pHu6bazUwz57ePiLPIL1WNwmGZz2+h6s75JJJh+/Od090o66/Cy+fnXLeI3jIzlE7nkWl24eV4FeVWVfWodkk9tmUdURedjiEPcr
#fJnwR/IgLDZu9LB78MWv3Huv2v3fih72PmB75mivJylw2GgkKK9RG/2Bzrvve4XtfpIkLSbhOqqT+Y1Yv8wqCv8925fNTLOyffLZ
#oZnzlYlcKHHEKXKdEdbiKEKIH4OYjSZLbWaCMp+enKVKPoHcDiP0gBGrsVyZ/NFmm46pPfs1csfk2W1HaflmfS9s7yPx1Vi3W3fc
#A16gKhy+bKZtjnacCeO6HfkS84rkzRIhzSGNKR7CqNyXlpsP1wv6VT1FlG3IFOcrrls3ria5q5ChrOY+BNO7nUMdRYbbp7LUCVpu
#SH2JpGnfmMGu+lxE6WHWipE7a5dtMzLRKIsItfpRKXH4Y+X1VItUIQGBwsSDB6Oet8HXaLVFBHjo7y/S21BNVW0dd6at5yTbUgkU
#GicddYVOLXrxyy+mlRSfY6GB+QQRZsqtz67hXBnxeYLrENpzrZd7ZxN0QiKi5lGnXt6K+0mOtcjR+A00gnvjQHviHYJ0x1PuJU45
#jfxK3/gmD2TOxc6mtVUHQ+bxR1IYB4blS+2UgTvuGBMPV/IWxZKd305efZyv6lNLh6fBtYrSO1gwHoFwkUa7XnBH5INo+uNEqIIF
#f82zpk83oMY0QyIM+Ak4HV8DmnxHDudK0opKFw6NJc7JxJ4UNDTa0Li8K6zkmXVSoiqf14LDCOrxBYN4STBRgnc9hyOG2uQNHjyG
#j9F2KBk9kR+vPoW/2aYpmC4kNzs4RKj3BL23C5EqTFM729pdGwlHOafUXyASR4SR2L3Z9HgXwlYnxxTaN1EutKP5aM1E2tAc6jz2
#zlICl7B9P4bSxYdSUlHEMvHhM/ovqFtVpQtyhDE3MYuflaGMkRRywWfV6jyiB+O6m1rk8a7zCgZiPChpTn47eyherPp0WtbjmeUi
#U/bbZ04g1Osr3UVHLa0SG5aPW3Wxil+y75v6cedIQT8K5sZdGzRRdQrncWBy8KnjoOdjHjZeN4xD7+aoKOTnUmHFWotj9tpNuzHW
#+Y2DI8fEQN6iPiTSJ9vIjmXEpdXAnlx1JkzQQtMt3NOhyjqhI8de+yoWkxKDzzvGux/XXotGySR6KS4SGN1Ufb6l9+iRE77MgDKv
#Qsf2hkrXd6arqESSdaTC9tbt3VD7oB/TguWcS+yECw7Y3/nhbo9icChKnV4ZulrECR35dHA+kNta74rS3EDNlqfhB7dubKiIFUbw
#yVVoHmSU9LlFs6oP7IJnU1/6BNcvtUl+av/+5eX59o+NY7fD7Z04Wfxml573biIVN6zOfFPdMklo65VleO3t9RHcSwuYQwp28IcH
#Ho6mWPJTuu1R6JSU8XL+Ns2tHXzRJQbcpaG79cvP3ctFVuT2rNlRVClaPoE87E+/3hwi7jTmKfc9MTnwTmXXLdLaG6JdtxR6s0Ex
#j+ZsZ9y0+IMDA2PbYzaMDIPHzd2rRYK/RY3IaA9qRuIisKMUmS4kIbG++m7X4Ss2WhzkNlv3jr35Lo03Y8Ycm2FNtQq7lRjZkxkb
#W6NyvjsofoF3g1j33KOx0sdbmb8TWXLefenvd4/i2tJcM+RJ7bZVfNHnLs/29LzHEbnZW/vd7Trl20JYdqx3W2RuzroUUJvZavfe
#kVsQXOFwN/loNYYCteAaW5FYcPj6TvC27DlOpOVbLDEwWE8bl56+s1Jh65WSkqpr4T3275oYcRsxxy1zL3feV2PPdGA9FeVRXa1/
#fovPK+mDYf5dsliVb6XpERUrLJN3ZqNLhMKspG7OoUc5yGcHlt0arc3B7r0ilMvssPRWkZXn6uOPhEJTVfQJG+sYERzdt0fVX+dJ
#rO5xM82+Zb/x2drAo1cVm8KF9w3O+wTaJuxBAWVMHtFtlhtfv9XyBiaXG01Wm79TL+9c/zibb/FMXZxWUwq/Ux9yJ3k+y5sv7Ujw
#2PRZiwAzV2Owcr/PLc0r3GEutRE4j6KaPDMcB+TfZClvJLMT9DFw2X0oli6Jxtu8/0Mvt8Yr8St8PbBYajL4M1rgQWXJLMzlk86x
#mI+sjUIt7Zfb9FMh38MU+0Ip9Ue+t0qb5Zu/fEPXlZ+VQ52brNP4RCr1hnBeDeyT/tvee00sx2IfPDKoJ0nvTQ+7NTiTJXo4q1sl
#034OKTyuv9+d9FloQYD05OOXqOUqGkofUuedZeiH807bz9vHh/H8BflXOPf7SLxJso0IC9Z0bB/kdRyqzS+Ffh89zDbPjvue6bTG
#7eDer1JXeWUyyElFqnv/rPQAPeibVco6S/OntPddK/3W5hZ8Nyquko1UMvj5jC9sPB3wORmpUO90rZ/4hNWInhPP7u+YA2ZeOfCg
#kz+oCkMhqf1mJ4dh/CC9+OUYk7jiQUdcBT8Hujss5Kt5ms4xgANv2Vb5p0k3mZpqulCz3hHw1HZbZSuV3T95ZMV7e6g55Wb/Ufrz
#O1btEgVEzoWrngHjFZn1dqZ3XdzY2Dsyts9GhrIh0ttftzvPC7b8NHT1Ym74diU7io6h/RA3roio2WI/SS6Rr3l/EAnVSI309CR4
#/UpXzJqw0u8o2JjvsTs7sSwrY/xCUctCoCQ/h4RvNnn1om9UNcu8ckemGjE4XHZeIo9+lPJdfIk9n/NqolrPo7VHgQxJVDNTEbp+
#87hrqHAJ8YR6oe61G+M+KOEU8cSf7wgqGjjtj2eHZJ8tF7V9/8YZsH8KG7291CaxeLupqUxH5/NUyHsjaqGpITwc7dZjy3FeTQHC
#SaOk56+LlYdoC14rxgzQ3B94Nj96e1FC8vHBrq2WYDg6KYnIrYWHfQejJBo1m0p5Zt3zzQOUb9JR+QnouftekzQox782EnK54ZU/
#Yk5nWIzFRh7ZYSPq1fZ9P76QYRDXhIRweu/FGF9nQunWADZ3kM4W/qGMxoOo/oJDFzKuiK8ZVy1qd4la5c7L+r8NX6H2DEmcdq/I
#2FUKGfZcjnOITaQgCbJra3GhfTPmakqZlwynYNJXCl/flREWEngg5bB+znr2Eb2+kOQgU/soPDuxzzSK0/bj3a3RTnEyU3LlTc1a
#hkx01FgKeiE6nxgm7NSk2DXtXVLhtCcPB8O36AQEixRCyr3Y1sY2gqyeeurtU2niUcka0i0IrRAGhPvuW3asdni43Fi+t1ttFj7d
#npOl+cS2wJsooorRAJcsynL3k2wbhw2v5HT/2nArz0rx2oRVaDK2jK9ilOLG2LpftYqynsYMZobgHW8tf7fV5bavPd2i6ZKo4yKN
#xykkw8HwzWYb4TaJ/nE2V/cxB8F958+HNb3WNCrhMX5xp3Ff5Buc0XPuR14XtlqT9PAMqLMW70yNb37tp9t/hsIzVBebz3fi3WQU
#aqM4pfF5UazBzbvs+bdh6Ujx7xSt6CQVD8QMNAnAm7dgZEFURByp3s+6ha/9oKTRIprKc6ybWFt0MWdCp1RzEMtdC149E9Sh4xJl
#b+IgGnliFB7WWPaQNaev78vMS3PWgPNnS+ajXpkgTb99psCrRM/7B57gBitP1y3t4Kh84ZcX3LzHyHgl3u+Wh/PtjPizkwbOYk6M
#D+67z4tC9wfPY79z96CZWNTnvve7JaHHvnF+RHL9i8v169lezOR1GhkkllfPmQ4VnDWMv9MENah6vogpnYGRpMuJHK/hEnSkx0B8
#TPihviuygwarq1veL6Kfz24cZOMNNbcaSVo/mcN6VE13Leux4ao3Df1h6y5nbLh/eQYxB1pTkr+B5xI7D7pdPx6POqBLsHH6RZ60
#jOsbhX/IR1WiszAnhdocNDbkuOl6IgK9GwJjIaMf8dJEivl9X6RlUpZP8rBkb3pTFA5bhGf2ErnRPq6tax1rc/MXmERpAn+fYuVP
#NJBacDacmplzPz2/5XTm9bgkCco1Bl3eaoynT7hB1kXSU9c+eB/VvLdVDtuheba/zzQ4o/COwN1aFU3WBGKHSnXBsrpxTGUnProk
#ZygFkfzjXLG7Ho5UfWEsuf59WQL5NpiQW3peS8/zvux1k8I3NmzMlwugYg+DPnC1Yc6T77QkEXyyovuCTew2bfrWMbjGqsAyoiUD
#Q4iF27Cy7/mVzqKzz0c3BFO+ZoXVWeyMehUYmiU2VWiKBGWuW30Ge/lwae2qpUicZykdfMrXI3+/B+tfNRLRmioMKB+ygvcXc98i
#I6C04uZXo1Iz2nroru9VdKjkFMXM/xR/X+y9as2rQ5EiBvXAlomxcUnxTR4sm2NmyR+LgtlLbWILN9dsfe453zKWYL/1ec0VN2jf
#VKr6WnniVnQPKYaEwpnjuyfG2BL4eDGOQhn6+td9+QcwYygQPusz7ve7tWCzhcUPs/DySmKDsB4aknYVaG4xvt0UNieukjD8rLWW
#gWA8XFsxDJ5vzaiuc/Qf5N0ofXYVjXyx1adKW+8Z0KlH7vMSJlRJvjH4zP1dvdsKHdptL4WNZiiUIPuTWs8elQpKTUpYvwxibryw
#opJgJQl/NF10R+YJPlOQcE5wubDsdGfSYUJ5S/Q+WrHuWaMyC5useoqO24zDfL2uNLWt5zseA/kCNQoM5Tvbq6SOLZW+UXuPd+I+
#KMi5KTxBY9d5Y6bVmHmjxyuBsflWNPZ2ZGZfeDZrLtPcwnsPI8lCt9edjHlpDyZrSzBeyubeTjzOdaa8bpI2DYlnTJKeisVocw7m
#pJV6tTBHiruxd/3LrS92rfywTvfDuRq+DuPIk8WtENrulfuu0YSoA/v11SGDnz8POzQVfrQmB7xkTDpIfdEnYYjc/n2s1meRxnC6
#uDW/+JU7Mf0MMezYRx1vl15KPD6Y86/rlCrxFIQu+nu9Tp7u6NeeNr3DRuL8lLPAvkxEpvBtWcko+6NOzwqbJwrBLRS21Pa9H3gy
#hz1l+D910Hyn+N5a0/X1Q22G0nhEdo/K/tRDHbFFZp+MD4pszeE3BRtMFBxneWSYQu4bdczSSKHkP5oOuD2KqKqkpMp/KvkNvLiI
#8eBavN2H6I5QvpSre/AkCVjNxkeG1huW8kG2/FfHUM4zj5WC5ljvPhTY9bkiwZ06YiQWn3Ckk4NlkFiPazaP6dMq8yM/gOHosHN2
#soXJ/Vre5+tteywYulZdvdSb0+xXprtfKQkWPTJUTLaxSlzxk3ryaf/DFZeAnkAybu436aI4syMREtkM0XrLO4sl1qbJnvj7bx/N
#eYDv3Rhvokjhy3pT6K6cNHDoOpo1zQ3nQtcqo5EMf9vvOx53qnfD+frx5sM9NxCWjZ1PCQltxHs3n4TMRaOsUnGWyHwfoucCyu+C
#Pz4kxJrhyCxdUVjyBO99ULnandNzbetAgNcecr28rerKSeItvbCeyRgmdTphBe0RB2VlH5oiP6PEW6VURrywQEuuW2O1KYGng7cD
#sg+fUTXLwPvDlbLJ48UXqpjp6u51xx77mO8fOsrJJr0pOJwvK1PbufX9I4+rhbC/CDsZ56uNF0Ic+OiCX2gVHiR1TrgrrZ+n4lML
#kG6+zp+x6U2d3n/UbVFGN5Or6cOLh60tBoGJmin27ZRUnaMpvNOnwOc838AW8z/c/1x03S+D02c1diW5o5pjy2P1C2FJPsgdJEzK
#4PIOUTWW2jEO9+nogfMaUziMz3iusiepfS10GbXF+j4i8RkKG9F0MQgZTuVdaaGSInokDrbNwjIx/0L1pOH97E6Y5teH/iNvKo40
#6AiUSQhoq+z4uKWyHqUvk2m66SwsTl2fqFQp2Nn009G43tv5uTyjIL2MU0B9Wz80LyVieSsvnY/8fn68HEdC+pnElbx4++d1bM+f
#dEr3x8hJsCZ8i76XTi1v86wFEqIj+Lz+XVrRsg2E7FEEhMPKijZgt0vahrvQq4/vIe/7u8yWW8mkaMIcuSRfrhZ6oBesJ+bsMQZY
#R0eOO7t8VsG2vTs1RuXdGdUklKAhqtZYbdl0x6RYRJjWV1BibpPX2KsoUMmFOWb5drHSU/aZtVWpHjNBxcpGD1+qpbXw1KPDMAlj
#rHulzGgrzG90m+WhK/mZ7JlsOAM8khZLd3UIpObP947PjV8XHZyrNGqg/uAMdA18L3/UFE/84wWnD0WEPYoMBgpKyPkPS2qdkOUH
#shbQ7puP2sX8T2WW20wzOVDne3PsSd5R3GfhiZq5emPQHc+FtOMm7IpwMFmO3es12P3XE/2rB8Yj/TISp1BqaAjXbTPwJx4wydp5
#21B2V5yy1hnRQy8/JtVte7l2JxHKzlAvvfdlq0xLj8nT3c98AoQ0IHJ0ZOF3bW4N+2dlTRJ7f2hcF0vdLvCuQO9Al+8R7xIUvDd2
#3cuImzlflLO7Tftj4r7E7ntxkkzRbfTXZOmBRDd3rei7zyHRqqn7zpaDMB6iXt7rwrt9s4K8I/nxCWqmdTHQ0SqP27ijiZ/ODF8/
#HHaP9GsaRn0tzCEhvV+z1xdIRNTx2MlZmBOk4f3+sZCOIZRfBxrVL4zqw3AvwZlISSZSXt2qJmLvXM8kvbwg/qr1C5+eTAG4a3zm
#9hlz7FWd+WeTh7kgk5eO5vWSTRsfJU6JBnQeeB/KyXVuhNYLs0jcumcWOphxO6u7qrym1kYs3uHDHeJVe40D39XvicRxD+b3UhNZ
#IMHdZxkvnBu5VW8TotJYoihe5Ub3TED0mz3XwJnRqYg/p1S1WV+1qFh1r5EVPNHuC4Or5uRR5gc+4X2PGT1/xc8f0vc0u/jbiz3t
#E6I8e+6ILAkZBRxzI3oblg93cDttxm0oZPVpIq3qDduxRqQObNqLbqO2BanyYHatGdDLrfnmMQqC2+7gXh8nOOdiTAnOduQgtlHA
#2e63DkLxGotpSCdYLpqWQbGAlslqodClUDwjQm83UIqDyqK6tcRqysFv0BtsuSQvxMwZYjY0YctFcpH0Ykk1EKbF2XrSPn3Axqsa
#S0kPtuefLz5U0DkhNmKUC0Y8f5hCUWie9DpK116TXj5J4T0rH1WlzPO76qSlMbpLvPdo76sVxi6xMSfrYWSmG4SN687PXDMQ2dKI
#Eup+/PAbaVOhoJhGmeVDZwHPwDzHKmz19Fh80lgdZ00taKWWfSRTwxWtKRUGyg35b60a+L1fv4tN7fAaFRSmU5ToKhh12t8JbXhE
#qpe2+PBA8YX7CtvKIc4eb5woCjUNBZndY23HMp45v1eZ8fBW8686y/WebbvkNJoJdSPCX0LupjnHDJzIBr5m1Ks8euMpGubLJpMP
#em1l6qHWsGU10x15aByiy+DI32pgQqvWzEQpYuO4iCvpIQvpT6V/e40+hkcELyaZHOcYp0MmdzRmmW/Kmzim7o2cKOnxsMOjJo/K
#xZN0m6gSpq2y7DNM79WE4LiTbrURwSCr5HbtQXv7DdNR6SaXgE7FKJ7kp2gpxcpZKo/qN958fGSyTbmZyh2v6tMzKe5ubrQ7wrz0
#Y5czpz2k/mhw6Sy3cO2VDa8jf51eXIaaerv8dW2eULzEPumUuy2fUj9xabjGv7RqM1HOhH3jTWWYkhlyDeMS4PVP08TJWhROOP2x
#v9/Ar8zAGBNBXiNsmwF7cqWQ+QVW6EtVGy15ch3ng5Uoztyue2vVY/6C7A9XGn2hLIMGmZUlr67WQxVO/fmneo2s6dHvvbG/Iite
#p1hjb6cqyjcmiH7geeCJv76WS1te5c61e811ivMGl219mrCvja1NPAfNlQ9g12JX/dsh3K6YH/YqMwS54vwZC2+JSKg+GOmTkkfL
#5vwcTtrL4FicT6CZR/JMLpjoWJdOk+emsq00Y4jSrBMrzoQmDYUmnSYNAQmIQpOHhgDk+gV/naVlk55xlaCk6dF62u5V4VOvM1k6
#26K7LakZ0/d2zFqr5z3yX81rZGScagpkjFDUWU8rXtHNaF4sboqtXfF3txvSiMHzWuZtfsuSCwdrnyr8OFpv19RItRvYyhb3TaXv
#refKmuP1rT/v0f1ubP+116EoPoNFxN/sgGIBNY70g+rrsJbxej5eta6ckh0Rv+fc79rrVYXf1VFwVSmxy3CrSYXr8mAODnpquD3p
#D2T6SPmDsjC+h+aB9IKiuyp3uff9HilcdaUNNu0M61ZSSqp7DPLnqxTs1LK4tipFEUIfz6dlqBy/ni7EYiKshlvnqbq6J9CvaHfc
#XSu7VbS0Pdo+y2ID/YStcD2JDA/t/7Gf7v2/8veP33/2hEBtYHDO/9t7IH/lWZCf/7/5/efL8j9+/5mbl4dfEIWG//82IP/29//y
#33/+N/pbQh1cIBwuDlAOR/f/G3v8z7//zcfDz83/H/Tn5xMU/P///vf/E3+crDg0rDSXFHd0p/Hk5eDh4EY2gaxZaHi4eLholD2c
#HSyhNIqWcKgDBI7s0oY4QyzdITY0HlAbCJwGYQ+hUVPSpXF2sEb+VPzv9RzdOaxhLkCVEweH1tYDao1wgEFBUDCExZcOZuUIsUbQ
#iYsjfFwhMFsaiLcrDI5wZ2KiQ65p6wCF2NDR/up0gdl4OEMkLz8cP4eKQ0AsInS/lv2z0uVsJqbLL4eli43kZREEYRGBclxAhpzr
#D0LYO7iDf8MFAOXhDqFxR8AdAMBEPQGmgIr7erjaWCIgIlAPZ2ewFcTOAXpZdIbBXGX+VK3tLaF2kP/S8HdZFubi6gz5tRRy/j9b
#rP9Lvwg32MYBDrmAToTu8kf36cCWHgiYq7OljwgtFxgBHMUZOJmGra07BCHC5Q+GiPvaeMAtL6ZwQ3jBNhDkUC4wINdyv4qW7g5Q
#OxE6JAU1PBDyzpbugOiDuME0HPwsdGA4DCAAcimEuAkdAm4JdXcGEGBIB/5TMfq7YgxU4DBAfUB+Fwx/l4x+l5DD3K0tnSG/voa/
#Cka/ChdDnCBePz+GP7/IflcI3N0ViQlP5HwXS4BG3r8LvDZ0ZmC4uK+sjo6Irz/Y3RUOnM8dKPqL/iIujSWS7cAIFl84BOEBh9Ko
#WSLskQoOdFmw9L5gS2CA/+8psEtO/TkByuEA8KW3hi3ARRLs3H+GefzHMECbOvuALogIYfFHcpGDuK8lHC7yRwB+j5aGwy19OBzc
#L75Auz8YEIt/GwgDaVzIC4crgE0YktE5EDAdBPKgHADqnIGhYLrLIXTAKq4I+39bxYEDWB6oMzFBOewt3TW8oJpwGIBahA+IDljV
#0lkVArVD2CNXcPe0+7cVgDWggLqEWiMFTUdfUd4Z4gKBIvzBDlDX/+X4O7pqqkpQVyTL/ZxlA3P511kcUJgNRBc4pZ+fAwcAygVq
#AMH8l8F07hdY+CP+UH+wLdT630b+V1UBjEUy+7+A4AlzsKHhEhcXB4ZAHZz/HZvAXKDu54ck9uVQe4j3vwzlBJnTm3CxC0uzK5j5
#CvgzsPj93cALNHA6cCAg7oiLc8LtrP5tDXOgnfPPKHv3fwOK0xxo/2uUNey/AR0A9AJ0Bw5g2Z8lYOrFJCeIz59Jv0WG9r/wDAJg
#JFrIv7XSARbVDoJwBzS4OAKoAivawi1dIJcNf8ulNRIqpJBAxDlNQSATcxYzNhZTFk5AyUOQfaI/IYZIQky4zTjcXZ0dECBA8lkA
#mXUF/cvRXC3h7hAFZ5jlBQJYREzM/oiq+6WoIrdDiCNXB8PELUGXdESYcJmxSHKLIL9gDm4wNxcXC9jjr25uZDcXlwiy9HuA+18D
#eC4GiCALv/tt/+rnBfqR3bx/up3FL9SPuxscAfLghLGAbcTdOUE8rH+1ssJYWMCu4jZi3JLOf7Vzs9uw2rAA2txTnBtsf9ENsmF1
#Zrdl4XQVYbdlc/6DYrtfKEaIA1hkhXICdkEE+guxiIu5FwsDdhXEjmAFlmFhBXlebmYNcwe5siJY2Ox/bg6oTGSdRQTkCbQhWFj/
#nurMAr6QGT8/buRHErBB7Aj/3yT8S6X8Ijqc46e6NoGaiTogleuv0aK2MDjoEmwusKU4l6goC9CPXNcOhGAT5+YUYGHxBVrY2Cwl
#xLkFWKzgEEsnf4gzYMKRo5EzYeIIVhByICtw5F8H/ntHcRgY5v+HP2z/VQEwMYGg4txIYv4CHvJPM2INcXAGWYIgYG4IuwCYm4UV
#yoLcFmC/C/XvDLYBCPgfJwdW5AaMNTcnCMrOzfKHWIh/WBNudl5WCBsvK/QPjPB/DAC62QX+7rb86wj/mHdhzcCwX50gEAKErLJC
#2eAXBWQJOAPy+x+27c8kYMVfs4DRPKzwX0sgJ/4i8x/NAYaDLcEOF0TiEkPqAYSYODcTE1C2ZGKyBMqXqLAWh0K8aC5ElpfnlyVE
#8gICUBZwPz9L4OPA8osb3AHauotBRdnY3FmsTdwBEoLcWQHLDrb8rSv+RSsgAELCgU2BjwPAlf/BpDAQkvIAuA4s/+AGOIvvr20d
#ACZ0B0TNVhygl6g7AJItExNyfzFx+AUsDmzikAumcxZ3YAPB2a1N2NndzVg4QcAgNm4zduRYFgBQG3EPkPM/wLWREOfg4uKW/NtB
#Bgb8tTmSny3F+IB9LC9R5gAscjkGiSfkaRz+yA2EXRwE+9nNDgVMy28B9AfBwZd7X2DARvJv43C5KdD3e1sPsAPYGtga5AEg2UEc
#wgZCsENYOHkuRgErS3BJIsQdRCDiDuALObC0cgd5sEgAUiDIxMTGZi3GzSX6+5QOyM0dwA5sl7Ty9/cHsQDKC+Qs7ov0YC3hf+uG
#/56QUGAigENfHWDO/94Mbvbfigx6qaw0lTh5AADAsg5w6/+jNX5qXoD5kdNlLK2d/jeBBuQFBEgj+8W2MoCDbf2/Av4XDQBsifOJ
#QsVAIMilrXCFeYF4wOzsgAoGFAcnN/cfFHNz/h7BB+YFRrALcvAL8PCz/m4GIfUFD0BCHnYo+AKYn97/P/gA4LH/UH4ApX61AIEV
#AAoQKYhe6makY420ZoD4iCN1IGDaeP4nSfwP0QOMxl/H4uZivdCHLH+MDbLODv9tFDWVfvYhgxhAyQJoYP2rjxOO5CywCZ2Wh6UN
#4CbIelg5WANfoApHXHwdoMivPBBC0plxAFiWt7S2B/3z9DZIy/C/RdjfoAPz2JD49GcB/3TUAZfHHWTD8i9b/DJ9yG1EnU0u4jAl
#KB0bsCkE/LMOxGUXDX8BhvivgMD/YlDIxRCAO5EYAP9e9v90IbgYB7/kz7UABQ+wisjvtdmBBjYk9/zZAFj+J+j/RxuA/oIXuQty
#G9CfXQEOYOO+2AfAp/Nf1tH+kkCAznPgAJx8AJe/1B70JztCf7mIIDoWpCcHF/c0QZgB/sOFM+nu5YAAaAEAaA0AT3fpCNCJ/Fzj
#0j0UveiyRjKODOSeAwT+u98D5IpU25dTERBX9796bJE9NhBbSw9nxJ9W+IWm+6cnhoD7/MKFDczaAxkIcbh5QOA+OhBngHFgcOmL
#cM7f2hIJ6m9e+2sZl0ss/PGPoBzOF4EbUgThdhdLuv9skhDnkfzdBniuIpeCDCDExAzwfrlEYWIIURgbG9K3ggHBGs1P9vQQh5rA
#zEQhl9ElHOwBhoGRgaMlh6uHuz2g5n8ZFcs/cPn8I4SDQ2w8rCH/IVq/e61hUOCAABmByBhwHiR9kMkZwIkAm5j9FYJb/SNmQQ6F
#sgBKA5gGRH0XgSygnewuYzAW8D+CTXUgglR1cEcAPf8Zg8rCnJ0vsyqSJkBIgcxa/QqiRQCZ/Gt/tf+A2h3mAvm3oAOKVIz+f030
#/iPmvv5/PNlLBEMAjgTQizD7Hdz8mej1d4iCXOX3ZPjlZIQJHNAT/xl0wVmA+AhuJgIF/vnt2f9Z1el/XhVyuerPgBYo/s+rafyD
#KpfxoyQIIc4JFIEYztSGDWzqzmpiamP2p4CM6ewugzqIOCC2knTAYEsQHRsynGKjA7xmOhGIyK+4VBIEF0dykKuzJcBCnOb0kiAT
#S3ZbYCGW/1pg4HQA/81ll77TL9SyQdgQwH9wNjigSyzF/17Ll8ef5b8rA4teQgtnAf8C9SK0VIIiQJbIEBAIOQC4/9HK86+tvL9a
#gTOyiPwKsyX/i0G4dL/EOYH+SyyyILEHAtDHAeCP8R+VP9hE8j5yiuX/cs7flb/nA2rgP07GxcLJK8AFRL//cTagHQhbwQ7i/3G6
#n+3W4pYmfGaAbf+jsN3/I+2GEOMCZBYZvrGAERLcyDL7RVkMCNMkoWwCrCAI4FmyIkQQF4YI+PBw8gIdl80goAL4NawCIlD/S8fX
#gwUijhCHizuIIiO/C0Taijsg5zoAMRibB4BwNg92B1YPINbmYXVgtxWFiLsDDrgtGMbGzckL7PyrinRgfhbZkT0/Fdwv4vPw8wOh
#GJK0yBLidwl+UbJmo2Oh80cqkEv9KvoXRf8IjuxfyQ4TNnYzSVMbVlMO4F82kKSIKQeSfJJAyQQib/azG9nA6Ofq7eeK8IO4+MGB
#/x2gftYufi4ufhBvP2t7P1drP08vP097P08XoMfTxdLbzwZi5we3tPFDgs8iyfAnl/KP+Bqg9B/INP+h6H4ZV0kg1OW4TOWAIRwO
#NmBk1hFh6cwi8leMqPQfOhIYLI1AwB2sPBDIjPufgXK/eAEAQw1kggDTAYAi88MXntoFrs3AssgQ9E8scxn9wDlkdXRMAEG+SBHQ
#Xuopy9/DLH8G+7/NqTUcYomA/MwygqDAEezULV0gyHwOlAPgXaAVaR6QadA/NSCk+7WA5N/tIr+XtYLZ+Ih6IBO8EKiNrL2Dsw0I
#4BoYYIt8nCGAG+jugDynOB0QB8GcPZD58F99Xg42CHtxQEbYEKKXIS9Q5oRxwC7y9gbIXmBhgLowT8ivhUUvo11r1r8yWpDfnvUf
#lIi7g93/IFnmLyRDLizGJQiXfAcHLMdvrYpUd/eQelSa3RgIVO3AdAzc7Aw8dCwAkVVhXhC4LODogJBK8+caJhBAuAHyIu8tgOPZ
#6CAbATZBkvyXJdK3dPaAAErTz4+Oi+637ZBE0t4SAEvE8i8/Rvc/mM4G5nJh0wECO0BdL807UIY6OIMumYzlTzoYoB0ADmBGLH/x
#Gp3InxXUQADDAp0XlxSAqXP5u/OvVtqLeOYCZ8Boa3fAo0PmcmnFkYtL/rqj+inTfwCXR8rxhRN6ueY/w7Wf2OL4vQ2ACzpAuXCC
#TL0AzXuZ5GS9UMFI3EK8gDDCVRSZCruQUwSLKIslB8AWIKSIgiHIvKLob2frDxAKf2zdhZSAkVE65NclCzKVycUGgoEsgaDiz2UN
#HZIwf1+mAI6LpSSdqzedCDD090UOMOqienEbA2AGKag/scACqH/5n0QH+NHPz+M3lZHa/M+pAQ8UcL8uDwJ2ABTtP7qAqFMcEEj4
#BWc4AIcQcfhzNOk/R/vpsV+yyk+3/S+q/tz6EhdwgMF+eu/uf3zzXxJx2fMXu/zsv2St//TdoRfMzvUXvtX/9qE4zUGmrOJ+pmzi
#fuziLP/QsLSIf8YkcHHZCyON9Ln/Icq/7O7PZPVvwbzIQNPRsfwJV4AGZHb68vRsvyG3ZIOxwS+Pxf6nkf13I+ufRlag8a+z6PwV
#R1nDnP+KozR+noLT1B3wEH7eI/xnkCV7kS0TR+pJdw8rpCvOBf4Vg7AjfhZY/uSYIZJwNogI/M/+qv+Q/D+5ld/xNITDmx3K4Q3m
#YWH7q80HaPMB2v4yKo7/mSwBVDcMiPHdAfgu08aWYggOqIeLFQSuYauEgLi4i1oC4Y7vz/wwko2RrYA5EbWUQDoncDZx1cuMKBgi
#DvsV5vwFvNtP6b8wdbp/rs1Y/jaBf7WDfhPytyX6p4b9SVhrB7i18x++hIlDwb8TG6xKIBggnXQ/uRh+oZZ+DuQBOgE9Aqa7sDJ0
#LGwXDWA6e4iDnT3i1xRkku33FFWQr7eIEtLJBtN5c9OxgH2QNTCdDzfy7u+yD+jh+asHKPv/XMoV5uzzj+WQRPjTZQeD/u5BiF+4
#+79o4giwPZsq6A/W/4M07EhX8HcnF8vl/elPPwoM+0ODO38LI8TPz9cfyY8cEGc/v3/Nov3D7oteGhEIYAt+lv7qBLQvRPzvhj9B
#GpLrkc4IAB8yh2fjALWTdXYAhmkD5AAh5fkCVZ4OEC8ZmDfdxfXRpelHusYcl/QAuwNw/hzi5weCScJ+ZSxogOjAhAsM+N1g698q
#3xfiLAIH/xwv4g4G/gdUASc3QBdkOA8UvEQ8wPYi1mBPA6AF8NI97wBfXrO/pF3/l0/w1yUC4q8k34XiFudi+amuAKdCQpxbEviI
#cIn+5mmI84WZR9JRGvGTseGX9LEUB8gBDAB0AIBNJB7gIOTh4SAkPR2AL/CxBtQFtwiAD05LDk8DJBYuqvbI6p0/AuL604/4KRPe
#vzgJBAM0giWHNwur9SWn+fzV4wP0+LCwuv9U8VC7v8SIW4jrZ8IQYQnlAfSdD7sHoEQcgOU8gOU4fwrYX+hi+Iei/9/20wFrDhfX
#ATZwRdhf+M4cf12piyCXZKP75RH5wuAOdg5QSyRtLwXAXQTO4WJ5mZyS/FO8uOVUvxiBZA4z8OVtt7vIrwyInx+gXH9yEOLitvPP
#QQz+itMBN0XSB/Qnh3KxsBWLCDJ2R077jwj6T8D2+9kDlOU/kxyGf8IZg7+vav/javbPar6XsQSADAcbEQT4Aj8ikF/Jqz/ugYgv
#0nUQQboZyBTgnx2N/pnHgFyaKvPLPN7Pa29AC1w8cGG5cEd+PYYBQrvfHQBP/sTDL6/4l/ES5bm8J6L9+VLi4k4YKg6MArxaIOgR
#uYyMIL+XBfD/9yZ/Ojh/y8ZfeStkwveXRf4XJF3C8ueRBu0fXhL5DcLv+5SLIAjOcfHAB3nWn0VArrgAnF42g3+N+vX853Lgr5o4
#8lrM8pfhBkSe488zIcDA+/+3l+xOFwD/TRnjvyljgsy7Qjh+3/r/zjZZIiMS+MUNghPo3xW1C8gHBP3v9v07t4683f/rTvbvlBTQ
#f9H9v8hB/nnQg8xKQC8zm4BfBr3IQgK+xIVV+TuHfUlRZG5MFGFiaSb+XwH973J+l0ABsg2g3BKJAI4Lgl6kAVlE/iUjCNjhS+/l
#l3xcuC1w0J97Q4Q/MjkFQfopP5e3BMiLuDyGLxRAvAgQcnlBIFB3ESMgmLA0AyOR8i8JPcW/iPdH419O/ecJf+PgP+6LLsj+16nh
#f6WSLcU1L5KKSC/7UhiQcCIvgAC35T/l4Dd5LjMSAIl/Hh/AGTAaKZDgi2Slpf9vDfVb/P5yp/+0Ij2KS8n4Z/elgCCRCL7wxS0v
#KQLYrUsgYSySMGTCHAaYLlmQB/Kth/SfdAiUA4lgsDVyri0gc0B0A4Tzv7S6O9j571W4zERswTbAKs6AvpAFuSMfdFj7+dn8U5Y9
#kMLpIW4LOBkctnCYizgDyBnsiqwhYEBZHeQBdma5bEC+WEVc7ApBvtUDWoCv+M92NsvLwyG/P3HAZvlbspFjL9SguD3oVxFs+Re2
#LDkc3DUBoyh+qX1gf1p0L46uBHV3sIHo6CuK/2r/40ZdIudyhizMGYbUZsj44vJAv/Hz1wAkWTkunhxepAHFLcGW/peaU0vcFwjj
#RP4bu/QnJSGOACTlV1T3Pwz/R1oKqb3Al+H9fzvl59q/zdK/3pUD9gf+d6CLQEYNgA25iHD9/Cx/BRpI03857t/vHGFsgN9FB6Jj
#g7LRsdDQ+bOA/0saAQhG/n45de9yItII/+sl4z8U0O/8jyYIqWvA0Mu0zk9mhgGsCUd6bNJA3IC4uOkB3DZ1kA4gGzAkx3oASsYD
#6cPpIgewiGqZWJtdDHUAwPxjt8G0XCz/sNcW/9C4/6Nq/w+vAfJf7xD/0jS6IOifvCRSEC/fi/w6pCJAiEtf3QT+27r90q2+yLd/
#gPfxy9MUuVwBjHwXDPiIVs6Alf2lNuHg349pLyTo53NaOCDRlzL2513tHwlDPm241F3/bqBofz0c/BtT2n8f76/7vH99HfnPZ7+S
#/9mAfLxridTGv32N3xoSIfnrvevPd6rIKvi/JQrSb2GD/p4OnEfkj4sDtvztcfx6Tft/tOgFri5X/KWYfvslkn9gZv//BWJ26B+y
#XGz1Rw1eKBnlny/FVJA+i95/eaT1R9ogSO76bd3EVX5R6NJGw0V/ybkKYGZFYUD46OEOsZEEqVy45oALYgkG1BucnZ1FBIhXEA7W
#TiCkmgQsuj9U3FKCSxIOcfMAvFfpCyYENlRAOk7IO9GfuceflxH/8jb+V3qaiel3otrSxkbeEygg7z8hUAgcBMSk7g5WDkCQ4HP5
#GJ3u72fvEGQaxx2Z1Dawh0Dlfq5yx8HGBnLx/gMYAzjB1sgbVOf/ABAKnEflX9XPb2a1gP1eUv83FCCA+cF6IBYW5PcvUKB+fsjt
#mJj+J5j8/GhBvwggwYV0waHi/x3+WJDvjP6QEfrnPQct7b9gzv5igz9iCYH+S6Ts6/8zVEZeoANaE3kjhrz9Qr4QQ6aP/2xn+8cl
#/P+wd63LbRvJ+r+eYsxT65AWSF18SUoyrVIkJ1Fs2dpIiTfJplQgMCSxBAEaF1GMrLzPeY3zZKe/7pnBgFK8p7Zykj/WXgjMtaen
#p/vrnhl4SWgzXw7OyA4mJbYe9FKZl/v4Ri01UC0b0Jwn5VTHQx3o5lBhcBVMg0mwCkbB6bAbD7F5nA4rwIslqcAUB6x+6i7wMB3+
#o5sanUn4YzK87E6Dq16wGn7XnQBUjIbfBt9ubgazbhzckHs2CiJsRBQ6g3fYKMdyb2reiOByb9JoyFWjGURNrtZ15MpfjPvj7qk3
#M9fuYOTpwN162O+EaaWLDDHpB3Iaycsd2jsRyDqwL3udQl+RQ607veB0YJ7j4YPmOSg+LrGuTlPFV9X+9ndT4uDUUzr+/tgRDUzk
#5C0RH9UFAksXpLD5kCjkfKF13LuzF0cyoglUaPK1+npNw/da22+++7RNGOp00EwQh8WMA6E9PVURusGOwaCZWZLi3IB+EubEGU6S
#6oTs/X5E3C/JP0vuOwibPWfdeotDNx8+lM0BA5yAzvqlQFP6FZGgpdJAzq3mGbi5fBO+6Y6xgVEafEpvOBkNiG3iHyThpcBGEnGS
#z6nkmliKVc6ToTntsiItvXo+3V/ZyO/I5ly3Kv68+iVYUgqj1Sbtw4ft/RElC9w9+KFbGl8hfXQdlPej497ecjN91L3uL2k5gnMN
#4l292CWdNZLzfDyI7ujRore1ILhwJe7bSDDwbBjbySN8M+vdTIYxMdgx9y2N6+3z2f5bjCv++e0vrJeOqNDbzZ1fgrPhFdKEo2dQ
#lJPN4dHB2ebR3tkm4o23cl6a+IRW//4zzT8ZlV+6tUOGLiBHeqb2oB72PY0s85bfcBLozc3b1m5v7+b05+yXhw9p6S3CsryY0lgn
#5C0gldZ+a9PSqslmFbEgi7SkQ90/bUx3PORdilPQNil0iUP48ZZ+hDMI23Kw3q3LM6owCiNi5PPW4gtoHvzFjz3p9Tq9ZllF+7rf
#3+9haRbYd+TTBso7ob5fPY/2K5oGKUJO/W037gU09JGehKS4Wr3zRoPJGj7YDo67Hb5b1ulxFXO57PequWxT1d1FQ/WYT1pvk0ps
#VX348KRLfOnGL4bpWqvYBCWTinD4CcIf8QtYxOfpAdSVvdcWktVtv6Nzm2BvspGa3QFF3nU40ORSSCWfEFt6e62WeFB3GmpaN915
#LdtiaLw1FkgCyYBGsmE8VZI7fNR59oLPr8JkY7bnIZnVbEISKvzyUryXft8vfNDNh4nlekNH0JqWncAzXMOhb9IePiRLR6jp1GBE
#M1A7buGyz4W7XYENzdv66uoYVNEht09AB7RPl2AWrTn83Xq2i2zJ3ZsJvgFuNY6BtdkN2t0q5BdvUCPLjDXe3JnX1oh37pequyva
#T4yHzurjYLE/YUPpnQwh2hVIs++t7GHh7COWeFOI1rlwiABkoxxiJy1o9cOH9kRnEtiSzF5LjAhbnXTvxQt75DUTxfcC5eER5bRm
#yfeoJQYQnKI6nIqWu5gQH3JsMQ2TXvBlt5tsdus+Lno0mIPb1u1qX3ahXTmPJ9OXD39+CddwGfhr9xSRRW1nUDjBvPSEZCd4Jebu
#tIfm2CG4bSbVb/aaK3pi4sE5Qwm1z2GxFjFep0SoLYhzNm3XOutiCyM4tS2ZSvayLeiXBojZzm5V2fpJXBesrViWkE22wANZNkTG
#4E5cw4pcQ+9+TyvQodtQTjcSXMmmQRNab+Q4RN8G5xUI+zY4D+1I1bpH9lwqfPiQu3ZdUuF7rreVl26ftMxj1ykUqo0ZYWTOt8g7
#gRW14U7wMY8O8kT5RZ3xin3FL3dnqVm1PFmVc8OF3cQ6Hbxi24sGiM3DQ+6WHn7FQ5RnRGB1dj08xusCUc77wkt2c+0AJ40Qvc3A
#+w8fCFr8/s2GGxdQopbSvYqv0H4DN9/fB3xPCY+6Bc5L8k0FIe84LKdyFqw1Xhnre29vbS2Oicuv+Uz3Y6of4uZUB+pAS7NVOJno
#Yn2A7Xsc1pWFpDmlT0rNXjaHyAkGP5h27WNPrqiHlDcpkpi8YBLT66QkOdMMnXHYJRp2xklR4ob/sCYXohPRbOtCXsfDDuKj8pK6
#LTJCdumBfyYG4f691o1OAv5rRXZ+kWuQR930AG97cthmQrSwPqCXTcqKsaU1h68AZ+Ce2KK5qRYJPugFJT90E9yy2SXrya94Cx7M
#7REXJ5FTanP6PNmfAohTK6F1M8qDLjYtuJG9+m94Jl+dU3dMKrsBYzIYRbfekh2O6+GoP5XCy+Fp3ysxNSVm3s3R60fXm8tHy95+
#5xoczYnS2bB/3Qs6K++d/JC5aNtZT2C/eW3ubvWn5JavhvcF3Oa0yqmd+XD+kcjb1qr3CK594Bvj6uPV8oPs+fZBf+dRtkd+s6Nl
#1ef9PataJpjC7qIf97ZWezGtIM93oqX0aA5Qzotq80pWlXWY2wuqfa/Jk/7MW2TejhK504imeZuAgQvpv3IbiBVi55WHLqwy59vN
#WRtCbd/mL/o7Dx+60GAe7DRqXK43Ws28X5I8Rd0adwf3xZueEQlLjm9TJRvQGbqnDx9sZLw0txGb0VB5a89ge8deJKVqnim9HWwY
#2vO2B+neGzIHaS+IWK1JdGK9uBAag6Xj3n4EL6gWQYslazH8rlsHLXbL9pzx9qomDrxonD5/m8/zEYWGbVBjrXblWe3KWm1s5LBc
#2M0vNgA6y0hDXrG5CQkqz++HWd76E7njst0eH1bf3On1NjO0TdL0V3/M5T/4a33/J9n5IvvDv/70n3z/affpk51P33/6M/7uzr/G
#Z5/y7A/s4+Pff9rd3nmy/v2nJ9tPtj99/+nP+LvZUKpzSeq/s6c6aVV0AiRk4dWgnCULJJ7Tr6pyRfC50rg+6wokE8LrXISeFD26
#LCDSUR4WMXKP3UtTtdLhnGviQRF2Hif4NpDNT/NJXlco8DqfKDw2WWE2qcOJ5kz7zLljmiGynBPsAqjO//y3OjrfffPyH9+fD9QR
#QQWCn318M2em1a5KShWqqghj8s+LmcrH6ocwvdJUsFjkYl0G6mJKxcqk0iie5ZUKx0RmQs5+rJZJNZU6A6/3eR7rEr1/Hc61krcm
#91+5sOubfAmG8muTOw7fI/Orw79L4ogsa5XyOGkgqtQFgSqFQwQ2v6znRP0KJW4Wtwq2jmCXyjOYYxVGRV6W6qa8NXXLgfqSnGS1
#IAuobka3al4ObFNZnnFPb3JbWIWFtk0VOLpKHFgSJ6c6milEYHCwIKQx8s6ZI0mHRTTlmeUnNVop7K+rvFAEAdvFaC5HOvUKm65t
#KfBvEKZc4pB+TPKYWHXFrAqv8oKmp/RyCs3j+CYsFZ5VmeaVyy/zgiAB8k9zMEIY1srlCcIh7VYqSEctbwRIbuint3XqbeuUvaVu
#CFDfrndo5eFbJwiSJg3ZHNOuLRDlC57xI/x6adE8tsm0VEkwstjLTrTNpaeBOiP3i6SaD4fg820QMFrfZZ5q1f2t5/jZ5rPiY2W3
#jcwQ5qrTqiU3is+u6hLNIkaeID7WyFmU0kwzJXiw2TZXzxcVD+6CaDLt0dLjZAgv08p+pV0/ruFlWMxrnqR38mRlCOTI3OHBpGIV
#ecLXmrdYV2GSruUqSTWFYn9yz/xJje+ISsxiLDIX63b9prpNnyHplX0T9enq8G11qoFfkxZVMq2i3i50UdBMlZWjhrPvJuMCEA8O
#F4FI2zUNzmlSkbN5k5GCwIvt6Uq6ulBXpbpwqWleiorCQ5tL0wS35op8KSXMU5NlJTkSkSUwHlVt0eViRgjHRgi9nEbZmCfOYq0R
#63FdiiE4No9N5jRHdET0hHlsMkl6yiKMOPeQntV3eGnyJ3U2gXqAkq/xWcS5nxvPpUvyE+aNwHHWr1znp3w+SrR6WUbhwq9Y1sWY
#ZwS/TfJomrM4fYnfJnn2K8vJTz7dSy54+O7MT0yYnkP6aRLJyeFVXWdeYk5Li+XxLT9wRjgiy+tZoXUjai0Fea8KHv+KFRyfW/Mb
#oJUeGyvG5liMb5qQucU6hPHFrNdZUq1UY+rIXJ2TAp+SsSSJWDnz1tilQEVsjaAV2KiR4PCL2aOAxQk4EaoCuo6snIrI7Z7BuGtl
#9ngVgrmw9QsSBVVoMhzlVMGNRMwU3wZYBarM1SqvVZguaYjUHfUbWh1VTcOKRxVVNUrjIXHIIG1YaICSoIeQhh3r56PiBaJmTLiv
#6lPHOFKuiCEs8yLm0WS5EtxEMIlUoPpaEzTB2PrwxblV5ZpMsj7klVhFNDKDVgtW/TTNDYXljqgKNjjgNk1KXhdtm8bFmKJDKgGx
#CbgssXmgfiTm/IvAtMo0wSNSzyNtFzVZHNfArlFJIOJ5uQgzmg8a2/Cfndk/Oy8eTHTFTNlC1guwCnR7teM184BrcwmZG8PRZ30q
#T8uX5JT5EEBUVooPQJFtq3gSHTW+LVW2b9fZYyH1JYRexAqMBdu8IkwPxp6Ct0TvCmzLl5lyGFho43QWejhbdRnwb8lTYmymo8sZ
#nx9RyScKoxOKY55SM1RS1rbEqLoLyVGPFoqxH0fmmRseDJq5oSoCE875yauez1ynYRTpBaZUvdMprVtiscCCB7bwOBEseSgMI7Gd
#YYlFmseqrxcJrS/C0iD8qZonWU0QTgQoCvEJP4NNqjx3tJEFGyTZVZgmRgDCSlpPyuyzSnEGMOaUcJ/0QASykNlptVDHyA0vByiu
#UOEsFi2eVl+ZrqygkSDqlDqr05idgBFUREgMRQ+k88JJ6HCIVC6wHYjaeS6qK6wqYBga5LswwVqVQctyvLeJNI9mrSaWRQ4F5xpy
#PWNchPFLX6j/DdrzWODmXpfYuXEyZ96VzmK0YPWW9GjWGvjGImRM8mCq0zRnCCaSwW5C0EKNU1wZbYmYtzosXU7eyUPALWV4es3C
#8bMG9YJH+j1v8ZfGCj2llkj1xK4or7RmbPxmstiqcBvvsLJZx5s0U8IsTlfdvttsA5he52HsAaYpweMqsQz9jFqG7LDLZDVX41R9
#g57JfixpRj6zDtxe05DVwv8HB601LrKhOaMK0ub3eCDEmMhQT7Buz6K66YCYYAi3KTCgwiZ5UjfLqc7cpCZZG2djoPZggC1zP0Iv
#B7JPBEDCwL7UOrNZbN/E0accebNZoVTinLxhq82HJeQFBIvoT6hkWTE0TjIZ7bapK/1pP/Vn3BDsSBOqW7Q1BWw3HEmg/7KYj+/W
#kGlk+CUTSlNp8xrXnNJXurLpS1muwOnvGoYJV5D42ibGRbi0icaZWDj+4dfwpzWnC8fBap2DC3FSrTCUNtXTIdyqfTfZi8iS9jeg
#C2YF92HynfMHuEPdcSapWhJR0kEYuRHueVP0K3Mw1nmdJeBivWArbUyM+IxZmCreMHKN8FtpGWPeTB5O8TX6gl5Ul3Rsz2YvuTdn
#+s2rYEgf9g9mcchAXW2pY/rfoWtA2PTOcmfuZu51buM7czdxx/i1lInHlhee+5YXNvd+t3LecivnLbdyPmAKHWXxnDHCcThv3KLB
#/Ep82h/OHBlWcZxHTuVhX3TMg+jiwXCrGkCWISsMDq1cV7gwYJk/Z9OS25wpcd1mTf2MOFzZ9Bgo3MtaabJxhSnQvHBuPZibanOb
#MJWU6e2UFGOTnEJfUYZ82H7HpGuaHUHi52TVaJbJEi/hX4hRXk4TgpYogu9x2zCCxJoM5MJ1fxN587353XV3Hqd4RGtFM0YRJr1e
#2NX4/aJZM+JeRQa647yUJk8DltLzotaKLsRZJ8idROrp1VM1IodUGXeZFSm7Lv24rhjYl4RZydk7TQr4RgAsJ9lYF1keiOEu53kO
#NEAZC1qrCc6TkrmHIA5aXRvg/45GS4DmXup2hbqvoDx2r3bdosaXpOZQ0aBnoA7VJM9jWtM0AaSw2GQzyp+GV5pdvHGREHBhosYJ
#KQEqZGFmq0OD8OFz30vQYyHoPIUGiAHqi3C+EIJQh/lT1mTvCHa+SqqyJhipzmwcdmzwSDlLiPiUXmgIWovrBV9kAfieRIgUX2kv
#jmq6fyLkNdGEe4l8MnBGFZqP9Sr5/YRTCd7SlBHN2Yy0E3uBbCl3n2x9TlO+1iqYaQAQme1FuLRfzqvStal8KnR9p6twps3Um4Hc
#R+BTIfCiAHaEuHFIveDa5AbVFR91U7B79UIcItAf1zo1fh3h7VTB452Hd+bwmRBzT1zFFViYSb7C0hCfeMxuqeCxFBvmiCWEhNgi
#9mul21bYIZfogQzQkMARSOfce2F9arVZgl7ZHVnwfuzAOep8PVBxJHm0Up7GQKPkxHChERKNW409Cq/tXVnZaNx48bEJE+QLnZV3
#90Dg/TTeMLfxmOkr9Nh5vBwTPlBnQHLqNzCM5Ygnnd0KKQZHYz2G5zf8REQ0EZ8LdWjtYGBQm+B9jvChYAKQzO03OmQcvr93N8Rt
#lqDAzuC9nYY4Vyd3J+LALxuusSuXuIf1QUITaxEOLnkBh3VGq+UOH1HMDh38dJ5smJbYNlusLC997gQ8LZwTQzPg9JiLwRtHjVnd
#xdNvaqZXPY/tSeWxZndt5AR3YhfXt6sbEs1y1kjWgd8EM+StpQnmi5RVVsvwZH48oSQ1B9EE4NEhKUOafpZknkIJ9RaYX8+vQ9jV
#MCvNUYHcA50FhOzIbVzCe0eiibOBf+UCe26i7RuZVyEnpriQ5vHgsfDgHfz6OMcGhLGhIFCm935ReCwjtyYXQ3IxR9jaUmFmxKP0
#3efa+Jx2ogbcfF0ChdajPrp3ZRBgzBewCGQk1LMnTBy5x6XmwGLIAxOPrtAT3NsDK4xBJcs20nwzh6uV3qCf2EEnEEzqfuL2HZmD
#J7yIDvwK4RpWCJQxyQEtctHigYJFDJRneNiU1plp2pq8ltINSI5xvhNigU+ZMk13fdWB+r4UrcGK1uwAKVLWRjlzTJgkh6E823Wk
#ku5l94nAduaL/lPhwDHEniOPWHdRhDXKjWjtzVl54FcMxdkIml4RAq5HpBMG6kLqumjeWrBOEdQn3I24cDuk24rC7kmw9WMhKA6J
#tSOMeWbW6QReNMEub7jPZLhHPLcl8M58pezWiA/7Dvw6PNIfEWQTPc5E4NiD5zizyhsot6fKU4YemqimXdag2a5Rmb/fn7j5oLNx
#+1cfcvj097t/d8//2AMW5R92DOjj539wBOjJ+r//9vjzZ5/O//wZfzfk3mayzTGhBTztqNuNv5qmT39/3p9Z/+LVLFb/L318dP3v
#7Dx9tr1+/m/38bPHn9b/n/H3Xw+26rLYGiU4+HmlFqtqmmePNzod3q7X1zW54Hokm2B7xhk20IS8VLe5zFutsrsp+COQGK6DSXaL
#c2PjvCL8APcqTUZFWKwEKnTPuGf1ePDFZo/g1zJnPIHvV5R7hGQeGWSmlOqWusKRlXKAfwgyUN9cXJzBe8DveU/tMRghojnMsKlI
#wBP8K5fURJLxZb1UdXd2Px9s03929lxjNvMSraIZrrhIaxrr1iMA+xhDRuPMl9dJNlOSrbqAnoKrDs9O2FcDCzeSORpTk1+TRYC9
#ySmNmR7mYUT/X1WImYNbcAKima6wJ1zUEf3C9BLTCEgCQRI3c/rf+1rXxOYCToOOCl2VAj/D1Dbgmnuf0uAf00OJvFUJkFtojlAG
#7NUEqi5SomZgPp2xwd5b5P5thFIZ2mPkSy5THOX5DBvuJvs8wZ28I06UUqZdvqVjS1EavwfyD7Rdvi83Ng7Pzi6PT75TQxobX8bC
#JQRsFXbtezgq8du9vMTp0MvLXm/j/OLw4uRorR4c/a5pLlAdATOd3sbx4cVhU5TEOylyvhjW7fBBlMuzwzcvX1+iWIfqbeWLaisq
#d/ss7FvkuYXUyPnLi4uTN1+fX3518vrleqe2B/Rq5QhTh86//Hc1uJtBPKLCG8cvvzr8/vXFORXHiVxsiBDfyC5/sf3FNpWl9ckB
#6G2W2m2Q25JXytv9/Ok2ipLUXpIAojT7AAgg57iFKimqU6XlZaS5jnv/X/a+BTqu4zps3tvFAlgAJAFI/On3uBTIt8BiufjxAxKU
#QBIkIYEABYASJRBaLbELcsX9ad+CBAVBofxLZFuJ5U9qy44rK05sOXEcJap/R2ktR7Xr1KmjNkptR1akxrGturbrOo1/KdV778x7
#b95nl6AsJe5pVuJgfm/mzsyde+/M3LljfQDBMpDEZKlcXMSog6kcDBsvRkxtGg1Iqt4TlK1bLKV4f4gicMfU1DZ29TcmUf3SPg9N
#tIhVPZ0nJfF4AHfpd/Ric5H0JCsVVJfoo/aTbnHS0QtaBFfVRdED4eVweP/EgZHk8NjRw8P7Rqah0yPD+/bDGBw6fNPNY0fGj94y
#OTV97Nbbjt9+R29f/8D2HTt3RQD1RoaPJCePQ+5yhu6iQjfo5cidJ9JLPTuWr4dhHB8+MpLcPzYyPO7ONHNiMZHoPrHYM39iccf8
#LOQdG711JHlwcmTqMOTtHdCs32bz9JqWlMUF3O0wCtA5p0n5QGzqWmflsNA1cC1enJ/H5XX4yPDx5L6JA7dDqT1J4K/4D4guBNPZ
#uYpuIhoiKMThoSKi6tjE/pshaBGJ+OQYEBSdg4lIuay5fpsFCMlsWuvea0OItWh6lxZJVgyzmVVLnxyerlZ6toTFEvXBfRPaiang
#7jt95C1SlJg0kXQOVTSw7EhenJ0gctCkHtRmZgEHwunMPLIyPW+cig4SjgGljBuVNGpgnMNVsB7pMLQO40QhonVoOj84rpTn0QNJ
#B7WOacBsDb+Pur+fz+Glp6hVTSqdNEmELmo7lSueBGY0RQGfEcLoSvk8z4w/2mPAbUPdQZUQvwHJMwWYC3i7KbJQme/eGYkiWszb
#X1Mtcb4lpS+dGdTO0mbsmRh4gIfhPKWDLn0+Gs+iPWY9qmXnNVL0NoFa5lBlFlEJSDsIyD1erBzEs9MR1DG1K8N+ddJEUoCYJ6Mt
#wExxl0gYXUc0kQodoT+00WdoGVeJc6kCFoODrjlKH4RhwkHK8LKmZjgBnYVeBUKpW+Hobkxz0k4pkysBh2+z1v1a/jREQdz5C0/t
#PzxyZBiJD0gK+ydHcC5MD+8DnjF6UBufmNZGjo9OAUsAyaNs6ETWtOmR49Pa0cnRI8OTt2s3j9we49r1FI2fjB8bGzMHS9u6NcaV
#DZKoVKGNjk+PHBqZtPJxsopH9Uku0IkMMdx4POuOo3xyOVYUESIRGd1dqyVIqw2dNrm8DZEaaEFoty4mkRsLAP7SR9rbMi6tuaOt
#jknYYI6OHxg57gdmksMzMS6gpmDt5gkGZeiV4pkM8CmQ91bazuotMfXlvClAIbGU2m0xYbKbY0G5ghahDJ+0PrC7Xm6RNnxsemJ0
#HEo5MjI+XaV9nsGT0oRGkTcBtQi8iOXXypLUPifMFC3Vf8ly6FTGW4z5PYfqUnhAmRF3pS/9+s6B4DSd8FhMCsoTrnalYoG10kGq
#MR4LEOsaPhsqulSfkeYgaQhWoS2kJZKs2Jl5xJwUcy6Ll3DtMNfDscPHxkdvOTYi9z+AF11BVyTFwa3OQ74tvRTJoWQLFDzFlyCj
#A3QpjCoVRsWOoB5Ikx6NnSl/tmS4usNBdo1MoZJMVZKovmDFS+NotUYAH62Nz/mSPS+cvbKCyZ86C5yqBueZz3C1J2+/Fs/UoL0x
#PE8Djp0yqReyPy4lpU/S9HPJRwf2UaiIOnlnMrB4MKTVRmYROj1ZPDM0XV4QvJ8EW7ECjotzQ10sx8SVgaQBg5zkwuMQX+JoWaOY
#o4t/SdLUGELRmK+VQQYf6hkwC4+Xi+eS8yl8q/G8VNFk8ZyZAZ+DIfscRyeHDwGHvxsWLChT4IHX0G3DY5FotZzG+cLcaVikFheM
#ofGJySM+eY25crYEsgoJD7aMiN0zdxpqsFuaKG5PJByi1cQUl9LoOkHYlOI5ieOXGM6hCgiRQFKtqVj6z0alWCrh8VoZb1AUkb2m
#SCUhWyZKpZ0p4DEZvw4YtoRVsbSwpTi50ceOHkDcc1BaDSRbTviHNFjK6Jw5xLT9E8NjI1P7R3QQfcdG9k9L5PHg5MQRLiRpC9pt
#h0cmR7QFfsMUynAUzmOjJsuJRkV2zmimCFFFh7thPQC1AqxUlwUr/9rk0Hu0G0AK11GSpJUCrRKi0Vj00iWSiCGKM0WBKsVp3drO
#7f2w0o2aawvoeHPGmBbFXd+IjHj5rkBsST8LdG5oe7/zM3v5inqrOi6c0RLOWdxcwxeJyPxiSY/ODBZmRZGVYhIrg+LSQzCzc8Wh
#7p5EZ+eumHY6O0Q+UQXh6FkhaJ91YKWOevqEmDGNrAmSPzpogpWWYcynFvVcEbfGCvrpLCxdpG4o55F96nlRJQ4/wp8X8Jvgx1ED
#oqxHrSeXIidO0P6PGHr8Lm8+ywKRM909szIIZdIexkX9nanuexPdu5InumexAPiXh87Z3j/7OiwbzJN0OmXVcXVayRTMDUmumpIp
#R6knaLdM5DcxowSNgvWNYwtn1rvCzFekDatTmQqtnfWSjcGwIIQ8m4Y050J7RqyyZ53LTXvBWrqMRSoxToBDXpE6MrjrplU9ruJm
#FmlJu4hL1jTCmjXM11/1xRitr7kSjRzPdwSzaVzKA3ZGZ2vWJdqJOFLxXbbabbGorEAcf7DNHYLs2UySbp7pBkg4gzYNtbZQ7JKx
#dzCaQMfs8viYl8SAKgCxSM/QTsystod/wvecnB3uN9FoZ4iDJsmzEmzY0QZ2tB+6CVAMu2+1oSHUpCbYRDQWGIn6goLz1pjhOWZ5
#67DNrk4KO1qc9i/VbJxZWg3mVIYqZBItWA1JhILy25K9INeWZDpE5BrAAsocJ9kIelCPyn2ql00gEGquSGFHkVUm875xRxp3M6iR
#4fDR0QPJI8NHvTtlm81TEXEwI/biiPeBXxciXJRKqLZlNtw75bsH597iW4pUaIOWwI3RXi7+sa6UYMxiZNnWaMSjIbzOAnIBPXGt
#4aYKVlcVlClYovhuCLpAEXfAUc+GRABxDUZHnOS60tQsa3+1ZyDMzxCsXcHlcBK6TtolpAtCiThtthfTuHF8knaOT93LveaGYSmb
#Thbnhfxs01Y804kXMudAPuFoaG5AR4n7FGgjOxon8ofPavJBksLidChunE71DmyP4lPI6ewpfNIIWErPdgltzbG08Vbgx0xpllge
#FCxjXUlAnuo1kjQOOj83M0XbRHyHaAhI4sPGGVv10LyCXzEyuXlNnwI5di7DxxJWZgeORkl5DVj9SbKBiXt6dDXD/NCooN6ktEfN
#NcBQ4Ofw3QPwnoycWJyfl/9Ni4pGCqdwVG/B+nD/nH9lYBvptCvO/+giNHwwOTo+Mm2ehcWnoI+SBw5NDh8Rm7Nx2jGkRuvir88m
#K2YrpCtFHcCDCR2xjgoBG+hoMOogwwaIEXNn9Z5+U9YWNCkHTC8d1fYOabs4dZrpHxyYRSp4MjIccRI9uUqtC7IODO6avUTdK6x/
#j7YdEVDUvglrH434klwi+FYBUPJ2K4SHEMBcbcaI8yxJrzmhpVa930XE78a9bG4fTcfhTeCBVdYJO+pm87d09fRMdvBufFKD5oIQ
#DOjQhuQzfAuTALob+qZHArFrSOtF0gDFALWz2S4nSCCMAcs/WawgwkAV0KHgYhGWr3fWzSWWOHUbRPDQ/h6ncjyI31nUbpAk0UTM
#0g/vpqqiggpC8uLyJcQDd7/TJaWcAxNppWUdIuAERsuyJpMVR7YFcd09Pr8ABdpHs9NEXY8Wi7kRYmjFsgAI+sObpgPYSbyrC40Z
#2snHit9swZW1DZRjruAvZxByGNUEApcYJng/7a/7ClxUTIy/IXUvyOtQPi7zyYJgLpU/mU5pi4MSMVu0tvZjCEs06hUmkdl6Y2kM
#ZiIkHA1xeck3DxFdk2sNom8GRBOQaWbxu7IXeIQcIBk0eRYne7r4yK7kEgce1Ll46AFtdR1v0EDQaVQukynB/JMwxFeGtMB30C6I
#dUqQpqzkK0aaUqTNWEli8QqKZnstEKBpQHgA2XSXAIekyQmzJdPhkQ6JA0i1xUkRSVccJLGCBADMbCWYGJSOADmaUyyYvJuEJbes
#CuxoAlVQzBUWbYTgPsdCKa6NSPzM4KwMh2mhpOlnsylilbZsE7VYG9CLGBdNkG6ityKw65JiMwrJQNY5suymQtAIpVPM9xGGd2vI
#TZ29KTMEPDczx7Si3eM6F6zWheYPrX9lCws2h7jk2OCvlHPyDUSrQc+EKWF34IWDDPICi8RCt4EANWTPeb0b5jrtwmLaoik4m+v5
#KAhK/TtnvRO9lDM5zVKkRAYEhBBXmuHaAkQ7TMpfMstFXQRupgyieDaI4vVTnAVKhO8F81jhJ2bBr/9BJPlml+2ekdjfUoRgov4z
#gaD1j7yewZmik4mDpeWoJ+GeKgne1UTMl8SZ2iYu4hwRposkaCgmKnZUqhTGWaYLWoz0A9aKN1xhU3vFC6vFgknGkRAmyukWkSVX
#NfYqJVEd7EU/sBergL3oAnvRrIKiE1UqEUciUBEAbgZmJbhJhUUck8i55tzZ/MvPFpLmVXwiuGJpPGMnEK5bl/GdmUQ0ZSkX8RoK
#om+uSl3itiru6IleMO/c8D7Y3o/lAOsna0qcYAh2Y1IKWTUHsUwsnkSciWdi3uCcQTKhO8nCosxXTZK/UHHSfFzTSQR/Pxnw0G6a
#mhjX9C7Uz4taN9PEkloyuDfIbwOhFRmQlJANkNGBjHZyIZtLS/eDLPqPIpG0A2sytQpwUnvdKVjqXq0nnrCpFkJqbn6lF/IlAwiE
#bQDCzcIkhampGeElyoWZqY+XkfuUUmW8J24M6ZEYitaDuJ1rLj6tqm3QTDWRijFUiRFIQ+jEtFP3DmFvkWoT3iXRefRA1NH9dkGv
#w06o0LnM4BtnBo3xaUBfXNxjaxAeU5tHnAEgYmE0xy1O8WO0o22OC3JEU79LvL4sL/Clli1FyBaOODOKkGU1VCsb5cZpxHIgHuHC
#P+0cDckb7zYcnEpHLXSxBVD/zamC/+bU/olj49N6Z1Sb8x4lUBuGbtCGxw9Yxwp7+bGCOBdHhMRTInnHaiYyF3Gw7AKuYrf7Lhqr
#dYdlt4aDI5RMyWoQt4Aznzln38lernU8xEvAYyF6NqLHp22UkLCbJUkgrpVqb8K1PCBlFFTB4WqMQq82Dl2BxrkdaoJRd2HbXctx
#z9LI3aLR8amRyWk8G52QdGHEXhA/eZaO5i2tkKh26/DYsZEp/YaY+C9ahTeKn1+x4qRGmgdmPfiMjubeWsDfSaj+jCNWrFjMM8/R
#QiVzqpytnHcpf9md6xIaSV6/LDyyrSP5I4ncpZKilNlqW/1JUqhw92cUj8f3T4wfHBvdPy0mvnZgQhMIiKiHpQ1B63MLaA+pYBr9
#8/a8s8/tfnW2E5fUQncVQvhnZrBvVuvSIt0RcCmib5DoOGm24mkXabcKNTVL6XU2GjU3JgURNBUxHYSQlhS1MCCGckcP/J/o7Nxu
#kUX8DhZ8iRVTQbvEZR+6Zm6VWEsCS/iXgHJIUTOzuPnZKwv1glpLOwol82AHPvAl5GW95CX9HjrgQlXTgJIlpJs2i6k8v4WDROVL
#DhJvLyTEEIhkiuRdD//3VZFL8WetOpwF8FirBBw8Erms5Ygzu4h2569eq1Bp8RRkxntrNu3COPPzWJ6bzof7+ScDtSoXiydnSRTp
#rdYyT+XMLaKjNBMTyO26gNsRolSETInThfb/vYPoZtVYXyJqbQn65qTVS0xIvnxB4Zl2tHSwmtC709UJHhHe/tJKiXpleDuXiI+6
#y7WXHl5KIJIssHbt2hV1LkSqfDPn/shZp71Ws3Zl6TgSylu2ZR2fE06MmgH6QycaMEa2QEf0w56ANhERNdikxSBezT+iY/lBLXU2
#iRfIdSNZS9SSGcy+kUOj45JSiIfJV+NG/lqAMeIMpqpfbKU8yVJf9ONL+4enRlAqGtccHGrP3q1btWlPtDYyBtm5b/yArXZoszcL
#OptluhItI22+P77Aw1Gzt1J4CKfHrFfYcA/hyqUomeVTz0oM34I0Jikq+8hSr4b71+4ah2q0J92yCVP1J/GXmLwfVaH/7W1S+beZ
#FqSkumUab8R1Ke/RQUoA6R9N/HCjrY6cKJdx8z9ZQ6h31RyCmppbIJR7RXRZxYoiLJTes5cWJBVqqdVq/0YK5u+zDOrhqx8nRF4w
#pNN6D1gIhQcEaV3kf4JQDTP91JBtKiAU0BzIGPUBgCs6QaRgZXzyODsGBTWicV4AcUcYFvx8bRO5IaJ10p4Zz+7Tv69ijGt0KO9x
#WoSjGujouKZ3GFHcibwnps1wTEahV4DjXGl4VgqvPXwC7byoJlezf+LIkdFpiQFUP9Bzfzo5MTa2b3j/zZHoblgxZo1MlZWAS4Ln
#YusvKr4v0Ee+QsoC/wSEFLegb4rQkGPFMv/JlLCJImR+ScovXYaE7zomLMnaWiuU6Gup9lwWS59bcGsCiZk9MamNHhqfmBzhc9zU
#ubfnNXRcDDmnUJOPkXZ8TIhXMVNkinGt9xhXdveypBUu801Ou0B7BZcSR734w2G05bd+IA9cZ9MnN7UE89J6zp2/NpgrFjhflZC5
#gup4fzvWWt5MwgSooyYvqQXcQA1wOgn0Eqg8n3WQB5k95Mt6GemlpR38+WPf5MjRseH9MvqZGv1VkWhFiASolOeXClyL2xqL2kss
#Zle0Vr0UVCtbwa50eeoqjNs4deTaftkg4Y0OZxnettdY/4LgAkhlrm4dF0CAQPKjnl8O7lTOpEp4zGqdoUzJ5+Xm/QBDWAAzt6GM
#QS5PiqsCJHWSZQiLZfNrBPwSgXWLmM5OzMMUXzUUW/uhJ1GDlFd8VTuqrTrNH5DGHG4Lz3ACa+rQ8h1gHoUTmFRwpauyFVnfdq+k
#bivrp1rsz0ftBUuuGHzVChB4AfNnbtWG+DUSkYxq4viluhF/QroQvTVoL+ylc1unksCl2/nqLmZU5HOBlerecKyX1G9eD9V+bvKS
#6+qGh28VNitIsQZCt4CfTH/Eb0EXFbWM7L2ZoQHU+IP0o7CMHx0/hBslpGUCUdPTY8kJ1LDtRR7dtz2RMGMPDo+OYbwUfXhiigxP
#CGmKm8/AAz6Uq1JngEpmT6fpRQTTuoL1XIuZi2JxLS4eiaN4SynpbJLMeMgnauYxrcOCx638Shfvji4Nli2lU3IpfOdGKgUIBHUJ
#GrkVr7agqQB6yoVwa6shDHjyzuWXmrJk6C+fNegSOky7Ys4+uK1xGCgOo92CcQ2hs4o+ubg4R/fkCG/F0DvXq/Jxlluf3NIeN9Wz
#yjMRUSrqaGm6jQOYdQapuVAwl/CAC9c6XagXWbA3xJhkDdRQ0p2jF/VvvrkExWluY6RvVgeFtvNyFSeqQ069JV5aqCShlalsRU4W
#05dPi4MLuZxvmemsgVYNzQ85IiXRjE0SSfFCOYdGi/JZSRl6p4WguHZ22siJT/K//MPTmVQadSWXIscA8buHT+HjiJLZku6jZNak
#J56ILEubja4iIUj3Y0jZ2ATCVE5GolT2LMRA/oSqdQIc1VlhAUX+WXum5IrFMwsl91yZFLcQOLolqRXiLiZJeFGuUTrFj7BQ54Xf
#gSRtMGuGnMmgeoKpqeG0thJ1XbUykQPSamiQOu76GLo9QBH0GYPb0BITv7tXQlWvTBrpy7ZRAhQ7f9uhTIVb3Z6iJxGzGWPb2d5t
#N6CeSIexhb7Mpo0hTsRRfcS8Pkt7+omEW8QivTU9bSqjGCVgKkKpxaNRJJax7nVCKeflW6ZCfm4mMStEVRqKeUBgXo4nKZ9JZxdI
#sJaSxKBxSfyyWZpgN6WsNp+CGZ526ZY6hgd1hX3Gw8sFtok3PI1tHca2GxbzuaEeUjnjuNTLO7mGirdVY56bzuEvuunlyB7eDzjH
#9+7ZdGJmP979PTGjxztviJ6YPTG7d882KQeUuRjlpoQ9RRyhrqxdiMhDxTg0LxzlUatGD1Qrykx2lmLeAcrHT8FKE8RWEhnzthIt
#jLFecCQWpESZ7NU0kWLIT6qKISbpssPSIjZPqTNRD3j2jJf4LmmFm5K/nzRuatoQxT5l6briD3jckJbYbV36HnJeNPAQA5kqoT6r
#i5i5pxlkJy4Gf+O0oWEglbUxNcKZXKpwXtdNK2ToidIrgObTpBG6mpPm357mYv5pwcxIPPLZ/MXbe47ZQZD3c0z327nGD+iYf8i+
#9JLeiX8j/qJzJV/iPSAxYJKLICHi+4V93xKy4BHhSfOCpTYvLBohFP567kXDuhFLX7s4v/83OLo9l02ChDjWYbhIkB9iVl8KVNt6
#dxguiJnSVvFMTKDVq9D/EIXYZzmSDGdHQhUm6g5ZF9atVJESM+EzI2pszljqJHzPTSo/6hCTqgg8FiLZi+VEvP/1MGqEsj8hONGM
#fAYw5zzd3JVFkJVouS34i8yd8i3/FYvJ+BMC/cKl7zyhdWv/2iWVrKljR3RraHGlDOjTbZ7mGJk5WCuj2QJ3lijtb8Rsbb3Cpc+r
#Dk1OHDuq7btduvo4MXlgZBKjaLfkANQgzjAqlj0Q3gepXE7qg3z1puXjYi9aE4/6JCu2Fy1RluJE2wla54ZjSbtpYnTceqWFGxmJ
#Z9NDpbhlc4W3qBSvOlg2oOYdiyFtZkk62xjEtYkdnJV05KVryc48pLognoDj+smUPmfwFQ4pcdBhrPX6G6TTi1izMcvOoMGjC5HZ
#ZeIHdCEJO1Jcmy9WUiglGgt5vNljVjdrX/AQDRLYjhc28CIackNLQ4HKpNGRpXyD5A18WjkJmRB280SwLOmMS6G5inytCFd8WMaQ
#hvve0IpzeFNOItI5KUeuSC8e5WpkEc9Qpe0s4rqtxMqr7QRZu1qkZ+PaMht0M3PcP+OKAt4ttEGvipb4Cnm7pA8yJK7ASldLqEj7
#loCX21oNcmKe80qG6xa8pQjkUG0QSj9m3CLFSRo9PMFWxpf1eHiaqYNfayNa0uXhH0lYISvtyIlzPFXc9ChkFiu68zJerQt84jqS
#uMQfFWvCmiDaqj8zr8G1G0vDy3EWflm3cUzdNLNHanexszEmiG4kW/ZcYHIhm+8dJrN6vztMs8seoGw9XOcmmHPD3tZPJJHB2eXm
#atfs7QWpt22VGZ4ghWdNQmk+dwjJtnFAO9n+2A7O+qiCCUucRDvhW+vZQ/M9Z+mig2VHOmK/xLgUoS/FzR+im6QIx18jPBfj5Iyy
#YvFIuNCfXsaG0yt0Ffs0w6KvwkIcstC5iiAOSIxoSTOk9ZL6Lb4kjC9j03UCyskXZDkpZ58n5xzxZZETryq65Q4RJkJNy0EkQ3tF
#AdwgBFFoK22PI41Is2gR57l4XcWUGsXWVnF+3shU5Nug3o3KGvIBKaHEJREoHyfdsHzcPOTW0I5Bmnt8ZQjzsUVTmsC/NF3Rw2co
#+kwLav5rG4FGr40gYktSAnYSpoDdHBmd1iD14EGU+m+oeWzq380euUYM8Yy45lfmlDSm1ZZxhJrYpaQczoHKNvsxD/V5kSKACfz8
#nqK51039JJ5SrspQyi5uYj2iCQnCLxHwss+9ybIvpS5LlNoFlq2EDJnMANVNUxjjL1tW8kh08hRKZyqwKDVHN++8SO2ZOnkuOPhM
#nWpyM0dFEzNNxTRbQM5L1v1qrGiwYi9BIZBqrqHMacLBMO3W5H3t1uCvVG1R5LjpQH4xp80ZLQYrJqwgcuuHwuqhx9rhSjrKmrSC
#ZJP5RJy4pnFGc0Ukt8YzE8VEzLsmomuu5avMtbzfXMv7z7W8Pdfk6ZWXMdPJJKWplq821fKOqeY3CxA17IngqM5ZbHV17Zml1+E+
#tD2VS86pLFQxeH7uryWccaULyk2+KtId8E5YfSczqXLuPN2GrNBVbKeSBcnsVaQ7txQlCa6S4FcyLGviZN4+dRbIR+pkzlIZ5eZT
#lrhgl+aG2CxD+D5G2LDkeSy5aMSRn0M2Pe1atfC340CIl+y1kck6lOvnPdukEGuKmKSNF4mX8NVZccbK/2a451zmZEnsmpYz4vyz
#HLlzZrj7DtvcXdf1kBdh8FtMLVRmMMmsEI/35+Xta9MMpU1iXIbS+O3d13qPKrVQOc1lv1Qlkyye4edAgnuDAJYunpM2qty3d4n6
#W6bnbdjxmBCjZVMIVDCZrpeNIfCN83uoZ++ZSeA5LS54ec2D2j1ofgER1knqUdK9h+wIEaQWxSc9TBsK855SxfMxAgffawOJRMI5
#WGT9HdFh5ozDEjw1R1JrwYlDRiDPoilEATZqD8wO8rxoN+KMj+ENPCSw5O10JpMXFxOzJdHR4valZFHRwjLToiJqpPFn8YQRyoUS
#qSGFpSZiehSNG233MsSVbDpWOafv9DHOiSZc3ZdOqVE1eXWZrhzxc3pxqZO2N2rd67v0huXKL8tysCVYPSc3ZYu01Sqe779i8fYq
#cMheIMYka/LuWwCmsrXrMIFMpZPqCr94y02nL5RzRmo+o/f1+ttOdd6z8Vhdt66+ir62rKgT6q30Nq3uNMnGy7cuzTsstFkVVvgl
#MzGczhdLZqNC6YagcEwU82uswbKlw7/FLudV20tTRCmK8qL7ZSG4YYuorj1ouy8FtosO5Hc1LqdjuJ2HahYRbbTjOi2yRaHXmv7j
#QV14Dp8+125ZyFp248TbZ9OmLcIj2cXRguN5pji9LMWvD/E+TacyeRgbbr8Q5WOidJiSwrdsk+UMDFsylU7Tc5tSslD7SJLiShLV
#uNDQWj+nVPguT2VRbKvygdtMupHTY1N0OQD6+0wGfCV60Fm8JiqKFMYU+XuymoEv6s7lsvhKvXgz42SuiO9OzyELRpNi1A771gHp
#8+to6C9mFhkTJZgNkUgSgo2PnQBHT2YL80U9OtMz66Z6kjo/EH19v/WErzD2O83VXETIMHLxqakxERIygpsMCp083mICmeus0Nl2
#mY4QnTCTEbcMGQnmQ3+YmlvW5fHdB9IKjrHQ7xFZzNsXfBWAm1FZMmRlafiQgo8wSnjekHMIXTLzubEhiVuXysVKca6Yk7Nj3dt6
#4j3CdgjvFtTSS9jDBOIFHoLD+EhdwtHlFCxYKxU+eNaLYhGBThG3NSfUYYfPsgaNEaa5jBFiKaZ6kmQxscd1qi3nQ533ymL8XDlV
#SppGGaVky6iBkQU+ZFtqp2IWiJ3HefskvIShTuZhBGExINByPg8ldaaiLsExzCcKn+OZHB6QWoVkPV0GzReqS/JDVy40W5wnlgQt
#EFpe/Ivj3QeL5XOpMizp0MfvnbhF7cV5iyovzptmpGORKGrvWAa0+wc8pgepOg/yyghQSCdRTUr0RvHk3fQcQ2XBGOpFpmIqpNFw
#S4beuJ6CZE+GvgQKsgCrwJQxl81yE/iWQRjTNLM9RhyxoH5TF0rnFftl4WDokf1cFbQbrXuTJmkJumKOLOxvQ2B24wPIZRj2oerV
#ucsayxROVU4LqZCsP6E2Q7Tmp2iFphsLKBdzZL622I1vEma8Fc4toC0L8aUhSXGycKyLZHF5adBbJeZ0lW2nysVS0jk8bHHoZkgj
#7oLIhcrexh7vlnu9e4KUMLjR3qJRyM7P1+zlycw8kNRMuftoEUbqvOissoit+SnMjHIq76jxwMj47Ssa1CnRTKlasZDqNspz2lb8
#cutuLZs/JYUJrQd3w9AUnNn4+wjOqMr5XEb+dutCAcXL7iwdO0COeQIeOZVBBp62FooUj8vYbgDOigBMyHfz59pFYRFpwJAB21NU
#GqmCfX/PS1VcyG3dJbFeckMdTwdvhZWDmTjI725IhvOBsBWLIIiXT8koXk6dM0lamTCOdEgLsprZycjSsr317lLKhO9d2ntc1xM+
#8ax2JL6fFtf4/MAEMgTiAEqW8AfvlrkpYtruWf7qpKB8pKtaQ590DrdYpHcpffscE2QrUK6652awltn4WQSYGoaqYjD/58TRi91T
#ta/cmCc8EbsxJNK7MMRiApLUzzkCb0KksGjqiSDEThqBpq+shnoLJfsQaB3MfPhxlt+qnLGefpzlJu78GCM32F6TFR5FkYZbeOd6
#d+acEEw5n6mcLqZtppwuJg+NTLuB9WoCcgVsrrJHEOAul0tRN0YbMAuUZL8uqi/EySqn96I0FmPKZVUVdG1aRZNZvvm6jCp+/Z5y
#S9R4/mIs2S3xFO3DQ3uhoN2Xx7J8s7uZYyRhZXQwnt2yHr4/8Pb5q6cryJxbWnfY03P2g1DdtbYMhU7tNn0m0b0r1T0/u9SzfTl6
#Arcccfuw5OnFfJULT5bFcyDlSahE2DsnTLTVaX2VLuEDf+VK+yg96a/aiDZoq12FSEajPj1EmexbLEnrDkuMlv3eal4LdKNnU32A
#EUWJZPfG9HLNIjN++Gsa08MaiDxVNc9AWauD5H+NnGsUUHt7vCUjN/JoFa6wP9OyWdBfGBp3V22z1BN+ybqsOkaY6hRejQEho+j3
#cCJPO87igkNvYjZKi+lebmpgIBH15OdH4OIDM798udaNd16K4ejTbfqJdFd0xbTilwBFfQ6QsYMkIvV6Yq31wmqkGt1w6MgT7dgW
#qUrKHMdUaJ5lO5qko9enLlUyv0RYq2zrIW8seCcWvD3RvzORoMIwQi5Qj6CcD7BCa89CGcUyFG1dj/bOTzriotzb6BWC+OlKnjjp
#Nj6G6KNXYlYAXcRRgl9tRA3mU2ezcyAug+NHjr3Fmh/wgzgvg7g83Kw+9OYrW/vKuE17NGu9tWXvx01mYNqKV7ec4pV5MCcVdEnl
#fpDtHHdNTMnNqdaPP3oUbIUNFOZ4eXgZ6Y+rvzxiuLQ7JKTOoxNTlxY7S/5iJ7mXKU7yq3J+wvNwKdt9c+a8zw6SKJkuoc5Yr8jM
#mpZZ6J0ZNL6bAqlf7LLTcaOcuYqposvDqIUCHpgWy9l7M+mqRE8YKxabfebq17dFsohMFny3CfOX/mB5bPqusFDThMClCnbayVxh
#4aYWb82SJfs9r0bkuyyC7odb48cjdBga6YEi6LdZm4MVXTEvtggHtbly0TC6jWwlQzsahnlGgBBp2covCDVaBBI7vxzuqkQTuxax
#TJBlL9pmSyZ2WddJXSXR8ao40I9kS4NoPzULy8KdMdPUoyMHf1M0goYXE5TjtZgqlrXjVKWCDyAZlpljbuI4Tt3Qu+vVz58yCUp0
#hG4brKH5E6XTxKo985o0Dw180Bl81tDOlYv81vxpJP90KpiOa7jdqG0CqPhRfQGPoDjBxr3TlFbInEP7dHFffMCffALqeVUFf3N4
#00zaBRnqMHZrR4EmD23brR2uVEr4hsdubSqVz0wBXg+NpRZ3a0dSi3gxe4i/f8APKmOXOJ31X0ZaO8TWXgsIDwBTFwAFtVKKV2+1
#Zj+TcRW6GxvTZvTIVKbSbW1LzZ2Jzq5k0hQXKj6zpkLX8qpuH/k1ED7xR5VLWxzB3wotcsjHyv4HyVWOkS+XktbqWxmJVo5CiYh7
#RH5ZBTR7j9XnYO8Xo94rFQFR0PpllAHljSy+lzwndeipe5HE4PMGEVpBeJnrMJ2ed4+IR0wtewfuw7a5GXw3kHQaoFBapkAUvSto
#n/v57ghKDXotj9QIEJ+zKqtIq0kx0QO14Lg1VSbR1dMdv7xHeL/QMZy5fhPaEcViBXUkcjF8Ay6ZOpVxbLnniFXn4jl+2Gs9K4w/
#NPQgKWwCx8/RjqLDDo5VftQxfkRA4Ht5XewpCL/FO+JFfFKwZIk/ro1MLKbKu6u/KDGbq6AkMASCTz6DXpg4QEmMJPp5vaj5iLNG
#Rt7iXAUoNHQYqgLJjabiHFsLqOC6jU88Xhet9R0zIXU2xU8B/eYIxmVRw3ibcfZU1yIs6t2W4KlUzted0wkBioioCD/pKojs7jMh
#Q+jl4j4Ib7ZNQyupU5C4NdKx2N2xGNnKr73H0eQyqlokC6giT2FUD4pK1ClJbP1VEShu6admb0akfrMbRgnYbc4o6Ds7xoGmXphG
#57tRJaH7CDddjkIM9UEXjFs3kElOnLBxohej1fiWRSf73EshL9EYmU4hMbtETb6lVCUilyAk9jyyooSxHMQAc1TtUSZQPLxDeqiW
#+g+KcHQwZQNB3Ku5Y1t/4PVFypb5B+9uJa+Mrzp0j6hJoA2auZwv/mAkLJ0831jEXNuj9SYTiUTSo3Es5ZSaidrJIHgPOpqOhif9
#NnClPDPQNahcTnYHvJjwKrmqF6VFZ/y/yTwvdx6sgP3yI0Dift0pa3UleCHtzQsvLx24NQ3X68uthXrfqNiMM9X8nLp8kkaepJue
#TwHXFTnweClJWm+FU2a16ZNJmlU8xHcQNH7ORzGWxT4HG0e7QGKrVxj8EB0AufKpM5l0FtplnhZmFrNAGopnJOU4+3FsrpqqV1Cl
#ozJkGeSJCTVU/g0n6wJGm/um0mnOe2uwyPjdJmh+3zmZJWZH4m/p37s3Kl3WiG4bnhxHU3CQTxN5uG0E3sNxLrbSs2v8Wa/ho6NI
#3dJZA08qTa0QaeC47q7zbeQpvFLPcyStx2BdqMALEo+7WcXAlyez/BrQlPSQrOMbA5CX3vEi7QbLTmBtjYpa+imktSn0XWlqL1Z0
#DB6dnJie2D8xlpwem0pOjUzeOjIZdX8Zz2cL2fxCXtIfxU/hi1t5BHrP9iR7PR8SaiO0SZBhAEEd8Mec6iDORSb1WdzWTwbXyRMd
#HWRUV42ptl5EBee54kKOv016EihHgUafDMbvpq0ktNVYygHcGmrLVrNXVn23gi580oMgtRXh6YpDRL47aF3/Kift+19hv+YN2uvx
#arOX2xOtMXWrTnvx+POr+NScGlw3GG8IZs7WhIHGpITazdpCCRfxg9u2gdORxqcp7GlqzUBIifJ1PiEC4ZJnVvnOUnmZVSmW9M6k
#fDRTpT0CH43TC5V08VyhRkOM7ClqN/3RRWhq9ND0yOSRGNVYO9/o+LSczaxY7kZvlwlTyGS5FMhEku6TJpO0eZdMIrNJJsWmHec8
#YfbP94ubRxuvYx1oEW3HwAD9hZ/7L/l7Bnq39/ZsH0j09bJET09vTw/TBl5HmKzfAuKLpjFcOdfKd6n0/0d/1vjTjYaxbOHMa48J
#lz/+ffDfv4z/P8XPZ/yFYBGvLL5GDcYB3t7fX2P8t7vGf6BvoI9pidem+tq//8/Hvwf4d+8/JwP6l98/689n/lu+eDqXey3qqD3/
#t/vQ/4GB/t5/mf//FL8jd7yDBeBvEP698gpjnxbxN67g2wvwb9V1n13Fnmz8802fVsb+fNM0md4vF0+VYTll3jvNaOWFAi28Jqa0
#fDGdibe0hK8XZRwdYWxMCbB/+Id9D5jlvsgiWpMCo38cAiEeFzkLjiYqZWwN+VUON2P2X/Y5Ho+/ALvrzZgV/7f/Wn/o9xcLjE2I
#xlwd8Gnko4w14zeQb3oFfWL9AL4GKdgA4cNSOI6Lfvir3yraddyGWyrirnjZKM8xARvASA29w5nvRvg/Xs7kinMcVoSZyrrTk2+f
#G8zgWf73MH1Sx9K7Gfv9XYwpK2qk93etugSfBjsjamCZPBChmhGqiAiYEQERETQjgiKizoyoExEhMyIkIurNiHoR0WBGNIiIRjOC
#PABbe0JlRwWc6joCD/4gUGoZAiUCRy1vQy8CokagK2+kGtXrVlNF6gYqXi33YCYsWNXXMRbu3Fgehhj4c4z/SfE/D+IfgCVswmJ6
#9A2A2gDUVYkQu1+h/m5VyzcprFQ+CY56MXQdZDDWQ9mYNaxCTAJjNkJgnQ7ZuzBqE0ZdTVGqiOrBqGsoKiCiIhh1LUUFRVQvRl1H
#UXUiqg+jNKwwJGL6MSaCMdD2rkDstL4ZAveDE+zoXrflfkgKXgztxFwwn8MdFzBFhw7qKm6BcLjr2lBxK3ia1KUWSKkv6hAY0wG4
#UDEK3lAReiDc/fUXwqFYKFTsgsDzLwS2vMBU7Hp2o6qvx6xN4Ogx7ISLIR0r60a4jTgCBoMVXr6SxgG6J1z+NHTehoegrUrHWrUI
#fRF+rGOdKAcaGnqsY70IweCF3g5TX3lM78URBN/VOAeeZZ0/Z0Iieoxl6pUAlnZQXbqSmq1u6dT7eP72hMJW8anWqvdjg9uYPoBp
#n1ev0LeDJ9ahFnfg32vU4k5s6pVqESZX+FB3s8o7Y+3dFwOdazuhrBCbUpBmsVZjEEALh9TlDqgxoEP1oW6lM9AUEh24vJU6E3KF
#m0Vj4LNQTBOBenR2Y7WrpLauTbSo9eWNKivpGuIeDUOLurQaCgstYZFtweIe/GqmsTV4u/gSxi1097ZRtb6t7rr4On0I0tvqyvdi
#KXvJL+fD727XobIuyPNuO49+Iw4V1SrX18iRwBhG3Cl/HfK7h6a4j5K+D0mh+/ATfT9EiNifQWwD+e9vxiQYs67lLVj6xdBuRJMR
#rPUgOFuwf4Msxclna6CNrd/Im8LKwYAJJrv/EH7QhOAzAUkrot5hnjpqp8pfBUU6NbJ4E0cNqC/AAGWBokJ9xZsROUI0krGr1NBa
#HcAM8UkR4mNaHEM413beqS5BncHuFpxqoe6Qqnfg2HVeBbQL+RRMzdZyA9YObe7SoYSuju7mLW3s4pWAileFuq7TJ7B3HHFN+lFE
#OuMWgaOTOCdfqNuytukFVt/JFMEQDx9mdYjrZl311eta7VPXalHXFMTdZEyLuo5dqq4AA9bK6d+6ZWy7una5jSY0IuhyO3qXoB3B
#4q04AESBNtFUbN9yxcXQtTb12eSiPqtN6lO/jjpckJuXZXKDY4UwYYuvupvP+6sSdexnjPh3qxgOpZPDEOCj1caKt2FRNxkw3UMd
#InZ5LYLFh9XMqNKU6q6nxnQpDctAc4NhR2Gh4nGcBgGa0MvrECeCyxql347D1lS/vrc+VL+8HrE3ULyDujy45YquOn0G/C2Nsf5Q
#Y/EE9vryBvy6sThLgY08cCcFruKBJAWuxkCgeBcFruWBFAUAzCCR4E4mxuodbP4fWMDEizTEwPRsXRte21SOIG6swg4/ibSoq7sB
#RRCAiAO+vi/cWExjseGuNhG3oa9BxDU18OH4jy+EG2KhBon6h+qNDE4jTo+vYLuOmPQ4yI7dbsISYMgjwjhGOtCR0Asbwmp5H0AU
#Ks4jopxCpxsT7LbAmDawDVH6PsTCQDWbkN7uFfS2i9Bu5QRV6TROI4KtHCnbQztvR1TnmNler7YK3ORY0yoofDGLPbPeGWnzzbXt
#DWvbG9e2hyHJjQ7tTa1NsWtbmzhCtDeAj7ChvRF8hArtYerlekF3kbiKKtzUtZUzGRFzZ4BiaBhl6nwa4xvkmArGNMoxb8CYsBzz
#Tl4aoaAc/0EefzcEbpbjPwrxrk46A+7bZ80sRVirhlv5HB98/8VXXnmhuTUUq28VE53EuubyJxFl81KfFcgf2sLTqWf0rTipl4qI
#yksl7NPgpXmUzY06yv8BK7nH7rm/wHAZoZU++Co1CKnL2++yY/87ZkXSL0f+BCId3dkQhE4KyjEbIYYQxO6QjrIGkfXkb68LtdZJ
#bDLG2eQNbjbJhsf4PPks/ANJhf2IkUzCcM7hkgK6juUAg7+miLWG+H0XwjgfW1Q7P86xSZXyCToaa1CXkLbHgJ6uIyp/OVOnq807
#b8SAd/+dc7SBh2B90kiGaSSb9OuREdQf1w2kWA1iMIF1hbYpnaH6RLg+lAis7Qpu6FLWtwi+U0EQr3cKvbsQzAUCE1P01cghgcZ0
#rQRXQBYptTWsW89lkAYpl96K8kVDeWfQlC+gx5AFcqmqgQsZ/li2J4gIhZllHBjzQwxEqJAboerliONBF8rNQ4RjkmuEgwK71CVo
#e7BcwTgJz4xFBO88I9G9y4lsQmB/L3yyUQjs1BqQ14Vc3rG+Xng2QEX3mvPHlteJbx9g181xVMT13Q7EQcA3kDyWkJ3GUa5l6vI2
#+nvlcjf9vY9H620kzVFIX6ZCsQwQA1GuxzLuxzL6RRkD9DewvJ3+Bpd3iDL7eJk8m97Oy8SQfkGUGWLwDVuN64RrOK9ZugLSb79u
#8W5AOzW0fIW9gllfx0rrRIcEHtMfwCJ+phrtKAzh6lE13oBAtZD3jehdZceuJu+b0LuGinwzfv67xltwyDberf8qjsevgXMBGF/Q
#eBCj1xbfihHNtEpGuXWXJbe+DSdOSKxltob4Wua6EF/LrHMIsBJ3gvWtkFrB00keIdYC/6T5j3JtJy2AUS4Hzop7Mq1i0pryny30
#idWgtPpDebMJ5U1aAG7pvEks29dRo9+OjY4bAG3oQoTvBvC4yQBvQjhATVh7UeFrryD7hqBjElMM3LfWZ8URWMI6JJYYWELBzM0Q
#A0sbXLEVit3oin0DxV7lit1eh7FXu2IPUOw1rth3UgnXumLHKa/m4C5WN0hzpVWaK0MCz/cKvN7D8ZpH61dwvB6y5opVGvZfL9D/
#NqLzUHqQlnf6Q8xa9ZAArePIrxc5cG0L0yCKGWllGGpTrhu6mpNERVpgKdKyTJE+di/QFGmBppRzdfb3vy5/j0D4ffBO+wN7JRdq
#U6/r3MBhUiWYVAkmtQZMqlSFWv6OVYUqLRbtQTHHpF0ak31iTPaLMRnmY8Kj9Sv5mOyz6ReuXaIwFlfQWHTzxQYSv6ZQbABmVoJm
#FrrNasO64xRuuO6KPX+G6z0i4up9PYjgvwHF7XoSp0QoNl7PI5fegZORex/GhsWwue9EOaktoL8LicIN6tqOMFFZtXG5l4ojWhtQ
#dZhNXd94B+6XLGFCi3of/rl4JUyJq9QrxVdQzntwRnNY2oLF38TQN0ZfeeWV9rr68p4Q8DgblvLJEDIcLvD/K2YK/Fe9sKE9pF53
#kcNBALSG9PdC+gvtzmj9fWI+4FqDAeX/ta+wrigtR1ex7/8jXyts53kD+iM8M8o1O0CuuZL6uI/38QD18brth1X9/ZCt3t5yum5b
#8QPYb0vIN2hZYvwWzlF1CRmI/kFsx2loh/GvEScexVHfiUudUOxMaN1u3mEYUfwQ5nwr5KyXliWPoXDSRKNKmX4bC/kwMmXoPf13
#cEyGaUwQTrU1uDxIjSdmxTcvu76RV7AOTGiHpEEalavNUSHuFtQ/gqMMY7qLQFsXP6Auobf4UazvcXTeSZJAWx1HhGF1nVVp3fJu
#u1K+Y9T1jZ9QwzABxIf7djtRgSqtI1QQ9XwMvNrfA6Db2uSYhyGmr/+qdQbO0fZQW6j8wZA5y0JSRi5YhWjeGb8Hzr3NL9wWWrut
#neeJNYm8JD3y+J0ifqcVD3InYA+16QoaI/izy2pZa73++4hikVqZGvSPExKhnI3y9D/Avy/Cvz+Bdqw396bhHyzl2L0Q95wUz7hc
#wv4G4r4H/4DIMoGf/YSff2DiZ4B9FtLXEn7u4fi5l9OAPtXYg5LEDYQx6NYvd1r+K5Z1y1/+GHTkcpRj4k31RN/KzfWAfUu4yWbP
#fUK0d9mItkcg2o3U6CGBaBtwzLcSot0oEO1G55jv4YiGY95Wd/FKPIRordM/wVBOL/6hObxxgACIxBPIxq8Fzx+BZ0PfFRxmCP8x
#zh9sRdcu6aud+FU9/2qTyFtPeXH3ikcQL6IGv7AKMKBR2pXQ2htEBxyox8WuZ4eBl3AxNGQKKPqTiApaeyMiwx6OBTdYHdLayKnR
#Rt9UkyiZOPIF+AeSMduh8PE3fyOIKxB3SOFHSFFxbIN57gHfr0jx23nREg0LsH5IX0c4MsxxZD/HkWGY3nfVL+FuiI5Ce/Hf4BgA
#0/qkTeHxC7Vh+QABTdxIVfWNOMYv0bw+QBzmvgM0xHtw8Xil+ArK+RSUgzRkhFdSLhFWxRxYZXGUPURIhjlHGbHrA44CYlPXCxV1
#aYSzkxEnPg1L7ARGIigqe6Se1i3uEQSWUYejMWzVAMhnsww7mo8O5xdnWfHvmGbyi5/WKya/2Cf39b6pm/Yp4kQNFypn++OJeF+i
#rwcFbZC08ZB9JzDszbDa+DD8fRQEgM1TlTIqSGOOA4DOnwNiv/nYFAsm+Pnl5kPHRqFz2RUQfi+sDTfvy+EmnEk/lNvWPdbUiLtm
#P1P6kBBg7Wf42ojw5hDHC5Tz2aeQ1jDCBcI3xB+kOXh+ic3Eb6EK2oS7imrYEeatCbH2hk+tCrH7yf3r0CMtq9l/XYXxR+pvbQyx
#TMPpphB7uh7d+8l9P7l9FK+Q/8V6/HaMSvhB6FOrwmx1YyUUYp8D/yq2vn5fU5htalq7OsyeD1dCYfZzVgm1sRdbNzavYm1rnm9a
#y76oLKoh9hMoZyN7mWltIaB+HwmH2Q+bH18DJUNqmD3TjGUea/1IOMQebsXUnzd9vCXEfr0Za3y6FUsukVvfjO6H2jD/XzDM2Ufx
#D4Qx5qmmj4TXsjuoxmwIS+sl+K8P3786xJqU+wHOmwjOP21E9xFy71yNkPyxgvnT9FU/ta6+7fmmVey7rc9DP+xVMEZfg/7bmrHM
#+fpHAMINLZ9a1cbeU7exOcTaFPQ/Dv43sh814sl1l4LjUqrDWr6yphJarXw7CCtN5U/aMP5bq8bUa9lTdX3w7V8z7IevUj/Mt7wC
#0H6xDiF5vhHdFLQrwpaad8GonVPQ/8zqXYBAO+sw/69Snv8D8avYwRaE8EvUMz9a8x5o70PtWPv/XIVumfz3kH8T9dsS9dtFGpEb
#mofXQJktY9B7nw1/JJxk9+LhHvvzMJb81qZ9TW3samppovF7bW1svm1jcxurkPuba+bXtLG3gruF3Vb3ltZVbFXd802EjXRurtB/
#a9grDWvDQ1bo2+G1Ydw+voIFlDXsTphZ52E6DLA3QmhOxdAmWJsHNq1hFQpFMARpIPBBqIMNUug9FNLZHgodoFAX20shnDnPsm52
#I4XwVPlZ1sf2UegTKob2wBcY+jyFhtlBgGxr8MN1Cns+8BFwW4IfA/fz3A1gfCb4cXBvpDxvIfd3KfV/B/6wrod1ND8J7neaPl23
#iQ0FngI30fIMuBta0f+Bhj+HnJ9oxJKXqPwn2r4G7vea0P1x8/N1IfZg+EVw14Y+Bu6bwh8G99+uRjdPbmsrum+oQ3fPGnTfHUJ3
#e+Br4O5t+0jdWvb58N/WbWd96vfA36b+LbgK+yGkVlYzGO0d7Vjyb1At5+vQ/1ALuqeUYMiZ5xNUcqG5QcQr7BEF2/sdpQX8n2dX
#huw811jfvtSI32IJCntM6YCcP1I6Kf82cH9fkb/iJQch/vfYLk+ZPHWI4ofFt0eRabIvNPw4/JCisOMiFGhCjEpR6C0N1wY6FJVl
#RagzcFtIZWURSoWPKQF2rwgVwmtYgL1RhPa0H1OC7G0idKh9DYhX7xah/64+pNSxD4jQj4G117HfEaHNq04ApB8XoR2r7oLQJ0Xo
#Ry0PKfXs34pQ0yqF1bMvitDNqx5SGthXROhOSGtgXxWhKwGWRvaiCF0PsDSy/8FD6y8A5Qmzw5t42/9L3TElzCZEaHUThm4VoWMt
#GJoVoS9QWppC32p8uSEDFCAnQn/fcDeEFnhIGQncHWpiF/h3wC1vCzUz3A3GUDuEWtgeCj3MWtpLoVXsVhH6ItCTVezXKPQAm6+7
#N7Safed6Huprf2OolR3v4KG51reG2tk7ROjdbb8ZupJ9tIOX0tn8WGgdu2ILD30w8F11Hbuwhef8NNBASNvKQ4Hw70LOmM5zNq3+
#eGgD+7TO0xqBKm5kPxGh1S0YOhHjoV9vxNCX4zz0V43vDWxka7bx0MW2T4Y2srQI/a+mNcBnf3eb3fPXsL+j0MPr39LydOgatibB
#c2rs30PomAj9Kns2dB27U4TernwjtImdEqGvKyG2mV0QoaC6BkJfTNg1XM++nrBruJ59y5H2fQq9kV2tvgxpwR4eagL+3MG+12Pn
#3MJ+ItLuYO8NbGG7e+W0A7087Y8Yht7QJ6e9vY+n3U3f/QWFXlK+2YZp1w/w0KFQP4T6B+y0reyZHXbaVvaXO+w0nX1nl52ms5/s
#stOibHq3nYZyj8L+c8Ord7VGdBsDttvTjO4NLShBXdlsxqjsp23o/3YD+n/Y6PbzPAfbmPgpQNkwZkc7+j8drvWt7C+rVFq7Ga+w
#20JeN8BwTj8H4/gcyKHPgSz4HMz4Cy0Ka2U4KhvADUPvXGhZw3rI3UXuMLmj5N5C7u3kpujbLLhXwvoE3QeonAcp9WFKxfiN7Glw
#t7KUcqGlmz1OI/I4jcTXFMx/nr5S1AstB9n72P8MjgG35v5PNN8JMwP915MbI7ef3E0i/8XmT7Ao+XvUr635PHBb9O9SC6HngO+W
#W/6RQXltzcqoeqPaqkyzD4avUW5Rv9nWodyuPgJUNKW2tkeVLJVwAr7dqbyPfb95L7hvbJ4AF6ndA2pf0+3K19gIzPefslD7aeWn
#7LmWvPKgmm6/B9zfA27wMnsrlDmqnlKXwG0OHVMeVr/V+BDU+IWGh5VGaOkj4EaBGzQqbw58AtyDzceUNLU9TVC9T11qPKZ8SP2b
#ht9TctSKrPLjpi8oT6h/Ff66gl+tYU+onw19HeoabV3DNiifCnwLyv9qw3eVHvX7dT9Xdql/1Nqifkb9P6s2qU+rW+uWlAq1qMIe
#bW1WnlbfE9ip3kcx91HMm9gtIGu9iSB8E8HwJfUPwhPqy+wDq6bVZ9WLa+5Qv6Z+dvVOcLPktrSie3/dTsjzjhC6D7fsVN9O/fxu
#6ueXVIz/ANRyjTKqPFiH/bCv9V3qh6ml02yy/bsA/9bGL6vT7D3hZyF+Y2Cn8kP158Gvqj9UP9lwTPkAYMrfQAl/qfyt+lP1v9V9
#G9xvrvmuiiPVFngTG1q9PvD7YpRPtPYGdqn/oe144Emq8Sn2Bw07Fair7SHlWeWjoTcHnlU+3/Y2cLXwewPPsI+GPgYuxjzDtPBn
#Ag+opcbboQ8RtjeR+xS57yP3cXJbA99u+WLgcfbVtv8UeIJinmAfbHoucJ76/4cU06M+p/5j4An168GvAwyrwh3BJ6kVT1Irvsw6
#WvqCf8nOAJ48q0wHDoD/y9D/T7HfbugIYv/cEXxW+UzTSXD/qjXEnqXZsSnwlbZfhdS/CT4U/CngzzuD0UCn+kiwJ3Ch5VGIuaPt
#cXDvX/OHwdHAxsAng4+zd6lPBZ+nur5JdT3DsK5vUl0vK+NtLwd3BX5L/UHwZeVwXaBuVMF5+gzDep9hf9W6E/JjvU8oj4UG6p5Q
#ftx6Q91nlPvbR8BldePgvgnw86fqVaHpuqzS0VKqe0nBWl5Svgwwa8xgT9ZvIreDvY0dDG1lM+x/NUTZEvt5Qxyozur6OGuHFV0c
#VpE7wN3MbgS3i10At4/9Bri72QfA3c8eB/dmip8C90Yqc5jc/WyOfalhP6xlbwmNkDsK5a9qvItSU+TOUZ45Sp0DHvPXDRnyZyHn
#VY0XKM8D5L4Rct4SejOlPgip0cZHKf5D5P42ub9DqY9D6kDj5yjmaXL/lNwvQfz+xhfJ/xK5f0vuyxB/vJEp6FfIDZDbqCyxexo1
#8m8idzO5UYh/c+ON5B8mdz+5d5E7R+4Fch8l93PkvkjuN5Uz7DP1TKW61HexxxsU9W3sqQaNYm4k90Mq5nkJ3C81sADGaOReH3gX
#+2bD5wJzkLopiC0dJjdF7gPkfojcp8l9MYg9ptShfxO5w+TeVfd+9u/qU+S/AP7v1j9A/pfIZSGqkdxNIYRwU+ht7CsNN1LMcAix
#5S7yXwhh+RfI/0CIaif3aXJfIpfVEwz16NfIv4n8w/VUTj225a7697MNDSmKeZpSX6T4FyE+1fASxSgNmKo1/DH2M7mpBox/lPwf
#otQXyb+bzSkXlL8ETP+hslUdUe9SH1Lfp/5AvRD4YOBPA88Hvh34YUANNgezwca6mToVuG2Adku6mn4GvDceuAhuOazWM3ZzO7o/
#VzF+96oQ+FevQv9JcnVK/a916LY3oXt7C7p/Rv4NjeF6XrYCnD9A/+rAHwQXdbfrwQ+dA/564Oso6TeCvxFmngLQNIG/CXi+Ary/
#BfwtbDVD/dXV4F8NEgCullvB3wpzVGFt4KLu1ZUoz4A0rMKqeQO462Duqmw9SKgKhK+Bci+AxBBmb4B53AQUNAruW8DfzH4N/M3s
#reBvYW8Hfwv7dfBr7BjMjzeAdPAo+zL7e1anrFW2KR9W/kTZqPaoQ+qCer/6FvVz6vWBQmAh8NuBWHAo+GfB/xIMXnDrpK8NM1Mt
#jH4P1nWEuAzF2Dkr6xjtDcj53il2DZzfbmz2xr2y2huntXnj+jzfvr/uOZ9vD1NckEYNZbEAjFMARikAY4T4EoC+C0Cf1UNfNbId
#LA//7oN/b4N/j8C/x4EyfhL+PQW08QfsV9ijyoPsSeVX2DeU97N69bfg3/tZUf0eOxL4AcXfHfgpe1fgFfYk/P0f8K8+GFUmgkeU
#5+HfT8DfWRdVzsK/+3ETcM/eXclkfyKZYHsOZgtZ4zSZ69l70owcK6bSGOodwNDeuWTyQNbA92L3o92N3l1+sX0UO1E4lKnsL6Yz
#+DmEp7NzZ0YLhUxZhA/mFozTe9NQUY+jmh7fajB2ZxL/OMrF6AX8c3ChMHdXDxtfyJGpe/COjhQW8pmyCO0vFuYWyuVMoXILvsGG
#6UfpBhQkzGdPQXg6ZZyBP8PG+cIc+o/Q8xX7FrK5dKYMCYdS+czIWShAGIkQnwyfS2UrFDIrrBQxNJY1KhhZyeSh9qnrCfxccS6V
#MyC2UOnrZXumMoX0ZOocdUKvoxMgVNg7kMS/5cw9woct7eUt7WVk7m96oQSt62UHsmQvMFU+DwGs0llaH9uD73piMX1YoMF9xwCM
#7f2OnP0cIcA34IgfYKcyleSx6YM7MQPbc6SYXshl9lLsFNpGGD0AXbyA1/xxB/tMZup0qlyKDx8dhfwTlG3UODw2fStL4vCyqfMG
#ABTfX8zluKlDI34oA7iRhSToFBoENplJgY/viPOYPS6s2puGKCdiQRTkOEovGh8sF/McujSHlAwJQsCQA9hMdrpYmcygqQx2rEB/
#htP8mxFukoI+Mf03FbMF+JO8m/+dEEh0FE2EwZeIEcfoqSFMwQdpKpm06AM7nCxn0BoCfkBvuB4slvNoSJbnnC5WUrlJeu+Z2mJ+
#D8Oe5f5jBnRXGpGIt2PvmWRyX2ruDHTWwWwmBykCXG8CB9cbTy/bHSvnvCnCyIhfUWl8bieHFhmmMnNFgNebaUoYXa6a4cj/be96
#YuO4zvs3Q3J3uKRG3KXVSqmkjhzZlWBqSSpUnBhpDIqkLNYixZArKY4hbIfLETn2cnc9MytxKwheHlwgQH3wwUBy8MGHoBAKF0GA
#AMnBbXww0ADJLQnQgw899FD0UPgQoAHapr/ve292Zpek1QBtgrbzyJ15f773ve/73vd9773Z2ff8hvgdxfAhrey40Vrg3fP3DpbN
#t/yXvc6B/JdAE1UCf3epwT204rY4gl5FD+zCggnuTglSLOllTv1J2GwkKd4aVDkBAbvjBrvt1hqEjoyFpUbkR51lfeCRtgM+G40F
#IlVTyZ7S0vVm8/UVjvBup1JrUc69luiKOvZOaq/rXaz682R7zjgr8W+0zN6yKVvnKExinqvwWCrptiTOLM/X60K774VXO4seb3rh
#BT1IZTeSXPX2IjndKzbWdZi3j+Sy2CKz5624tR2YAGw26kuH6YTyVJ2WR3d2vMA7wk/AFwRajnyONymOPBKjogU50RWuY7ZaFeTA
#BZdGbE4+nLE4Dz7zdT4C2s02iha9zfb2NoskyYuHhyRnPgy93c16p+JH6WzWhLWg2fKCqMPSSFcYYD4pqsg+JSIz3qppkBQvuO5v
#bXmNg41fAwvawg4WLjfuiWdg/14/EkqZdDsQuKR43bu3AT8UddahD2GKVB44lureLsYz5i9VpETqqv1n6+6exMKDLUI8W+1adFC4
#emujw2jcbbmNToo6pVGSH/mbfh0mlZSq01Jhw1BTFV1qqLuyNh4WRLcYBAam4nJyF/jebd5nvQx8OMw/U1WUjMST62jvN886zSeC
#pqcFMFO5iWmgOYq3baMVnzdTb96Lykt7kdeQ3Y7LN5rb21zYbzBl3WlcAgj4EYlWmooFHq50LDUDI5lqLIR3/IZ4ZZVZ1X6SNni3
#mxTgVQ8Nr3oPVJZMrQjxHeKNyYR8tYcc+aT934Jbr2/CYUJ4cvUl2lnzvNcTsaihCLMcPUbd4KmOW6f+34q/7OMiZCj3oTcwvgZ9
#UJLTw4pIvpdYqGBgpoWFDbnLME2yzZIa6SBAgZeIEqiiBhCr7V26ikHHcxv0lZmvVqvX22CJ+GDZDWgYvRR4XiPVmQm9Oi1uX/WK
#NBLHE98Z56yobbcwyMQ56MKUScZ9XYHGl9lrlGOdU8XztTQUzFHPd5RXTOY/4nGWtxtwfRDflh/FpC2qMxEHi+Bxe/tPpciGQ5f9
#3Q6jjKp8TDerHxterAfMSzK3lRSf7BvXXvWiMo89mLKqATAugDTf4Fn1bTfoqfI81Ir3bzxiEg33HVWrmzqxzNaCuyinisa88vDQ
#atbZnyvEesoNs97GtNoL0vNwVqGe3vFehZKnOn8gF6M/60hA1UhuMTqeq/MAQr2pZHpqzwYaR6swer6rSRe1pAXpu56rCVLdMS9H
#aaRXBowslSrX1FVuXqDr3l4LYzEv+i56Poz8WnjUwKmaCsu6Q0N0x62GvyfWoCZcJBNhHVee8MCsTbvFg/nibPsncGr+PJAnlPfN
#4wRsIOuQzqoqGxE/hL5m0fo1TyE8omjAwcazgF65GnD5VG8wFNKtiIcWzHi4edZ1GQ2lgSTFjkWmHkcKmmco5d74FCaTxzBtLWsB
#H5/l32eUrGXX6u62gl3EHGYnhBXMVavRjt+rVUk2PIPWPbGfmRuFkB1vSMp4kmHoM8em8vxmGAXqKNPwkGXYgC7rg10ld7FZa/N8
#Ic5bud96sk7ex/Rt0JeUr6vtPYWHOM4F6Xh8KLfOekI7IumQYkMOkzWgVkx3L07yWgIMN3slUE6ez2mFC0PgCElOoJmPsHLHjF90
#V2CqnJNU4WSzUXMjQq83okqTkdNNOeEUPoKFisk/prI1NSSmR8lUbiIfWoTTY2ZuyplqFE9rbgbaN2KOEIRRkuQFBdYKHAWsjm30
#YizJBTlcWrpQz/iE0/VmM4rT6e5VDkI9KzlsnZ48SQHTXsj3lr7rSRbvWRvPsiSunHicEpp0XNVo69hyeLXJAovlHWiBpdLqmB0V
#l1Wdilaa3PVqtgFvKa3rc+ZpBTNBXsykB0SSfTj08xe1nI5qq80HmDTtKaJ6K07FSZLccDvEW/ordZHFp4DoKHPm+o2Q41hoBR1q
#tqrLDWizy9NbNTKp1aOet8brjD7ntMbHsBLRpR0CsdSiF2gaf7N0mZ6nMs3ozyzyOecKUjP8EPT4q7RKHu1Rm0K6SzSZpG5g8tfg
#twHHZnXty0R/tEpLtIbPKlVoGX8OWnFogTZQmtSl7t8uUBPVG8iqgaAQQBHtIMVfAHkU0H25cm4zVTaIyKEHiG/i3iJXsNXBgkPn
#aBvxCLibtCU164htC8lTkvKlBa5XR82OtBZKGbePwQYQTKHK2wUMY9uRsjLR79cEpjrQDt16SdIO4Bl3IO1w3X4anBRl9xALUjwe
#5Ijcg2J36CHdpkcaqyu4tpC6kKrHMLcAM3VAqr7APoQ0H9FF5qdaObJ1hmZJN9BOpDHxvQ0YR2SkaFdQ/e10BBb4T60Bk0eulHMr
#LuAZCy05Um8T+UoSnkgvBI/M6XZKQq6mYUdjj2UI/JPpdqvCH42FIneXf2462pA7emgIbZ6q6b5TeQF4qUvP8q8AuSSuV5We57rb
#Akd/EAF3TeR/T3ioi9xZ52i019rY61JSZ4zHtiSXqUbquKt1KxStZxprmmsabWmO6dhryPNF/uCjuIMUw/d4yDNVLX3fAwTDVlNa
#SsdYwgFyuJfoeNIK80bFdJrtj0aEmuP91kD5tpLk0CUyjjMFjDNSVI15aFNpHbfma2uGjI4FwN2WUuD4/LTQ6sMRMPa2toDpNLVv
#rvTiLFcuZwntaJ1WOvaQVgTTI5F2RXIqYgGXJL6gU3yfkpxVSffz5AjXLeFecVIm48xB+3pBt/hIetAVarell3ahZS3m7ExLcLHm
#NYCrKjxUScmFnnHoFZFDcITli87ccsRm2UfUtVVeEX/DsG2hUHkglkEdXLBNMVbG4wo+bt9L2eBFog0HLrghtZW1R32Wmth5KGVs
#QY541dhuWfautkVfWfAzNWm3LjTGvmBLPITfq0cjwtU57qeWlNREKsqXTtNrwMwxmvw6em1e9OISvYzaHTLGrqPnKhg+gMGN/VHa
#Dx1GwaZABWJjNa0xZdGPQKTlipUryde1Jw6Yn3NH6WXPl4/2YmNcJxCdoecSz82tvoGanljnIR7h4lFthGLLLZEz80GfH8w5BBtR
#/dndx6e+d2nxrX/+9jeO/2D6VRp2DMOCRzNGECkWOWnzZYTTZ0ZyJ0pfM0qWJOwcrqXuB+r280LePFF6wyi1S+0RxzROn7ScIcO2
#S/uGdaK0PwKQD+0ZwzQkcZaK+6MjBc6MS9+W5Ntx8iNJfhQn35Xku3HyY0l+nJsxDODixH5RridGiU6Uuo9BB2C7PzVLbfPUhAHS
#9s8BsndDyVkyh1GlnZdMwDvEDExSTvEx7NAk5EETY8i4a44V8mBrkiYNiMccIXN8fNw6Uex+2yh2f8wCmaQJZ6i0O17av5JkU2n/
#y4C3R2kI1H3ZPnN6OG8UeR+v4iPkF0bJNEv7S/jnlszxfK50utS2C4Vi9y2UW5ZjmkA8abBMLWuoYBSEGvu0Ba7ss1R6xSoYOgeM
#3IJYvn+M+BqnRtBg9y0zN4TKQ2hdOONOMoB5FL3GxJrm2IRhaPHYIsq74xNGIrKcAhOO3LiWZalsi4m38iKm0sRofrg0YRVK3fc4
#e0Sq+Hztvmfnhy1LxNt9H//Si+9bqgO67+d1CZD6pmWB8FL3O5C0bdvP5sdL56VjFa82o+FIrHOWZQH/WAqEGx+Fck5yl0Ii+x17
#KDdJ+BhDRDY+1tP5UdSzUpX6kUJuaB4QY6wb+2+Z3P3HlF5NKNDPTZhauYx+5TprFAo9qKIIF6305InOsIRP2y6cKHmGirJy8M5n
#xe4/5Vm3J84SdBRZLL3vc+kUS/xXhs16zpFJAZgaZQK7P0RyKA8VIaO4/80CWybu6vZ2IW/EesmIZrjeTCE/JGwKp+B5jIvmuGju
#ZD5vlUTF/8GwFXnoDvwDnzkhZoIGbW6ZQSZFRQBamDFNJnxCJKDyihfyNGxzUN7iO2fy6K9xIPylAMR3G3RIn0Nl3oHfsYfY6BC3
#Jetd8Sm4KzT774luvc+2YdvHHEMoAq5S99+tOG7FDYxrYhAtTknF9ywtNTshlEuK+4+dfMGCJXb/vtj9JKbsHxHHvxJCUmMGNgxA
#BuC63U/YZu0JRATVB+gMkHrlqXzOKp0vdj9V1RQWqfBpvmDiWpxLcM5Z332x+mbx54UXrJ88nPz1Ty998jXrgx92vnTxk7/+UzNn
#mTnTzNlmbnwoV7LwuYXPK3ntpqyctkP2W7FimbkCYHbN3NhoLvaLyDhp5/q0GVmM8/RwjjVQ62ded2xeq95wDvLlyy9Hc7FEUcnB
#5zxX/LRgkP7tC43IKy88gphwZ+McGWf3I0MIaCcqQO9M9r4mm1x3PycRe8yBTL6JAaHUfSeOv4s4apgKxLTYBNhRFBxTdaPNVm3E
#4B+mqn6Uin+MOHu/UrvgaLMvTQxdIAsfEx8bn/HhCyDSMvRumWf5RxYV8/fuBG5rtdnoPdqu7ATNB6FhaYbpRYNOlVeXKvwobr7V
#mtIP5f/4/uxMeQYY7Kd6X7/pF0j4261RruIwiG3QaPLtBo0blF/36p7LO09xYlZONuANOQwamVXRYRbxiFDwnEHPJt99DHyr8Fzf
#Ky10yaALnwHb/+4H/5jz6mdAH/bizXOHvA3xm+L5gsJz4BUKKimJD/P3R8PyuIPlMyxKZyi9w3XMkF1/JAd99HfSR8dUVSMya5Fk
#y3tXjPGY+lYt/iZFJB6/U8HVrN6XQ4w5p5+oSEnvbQ16yqDjg8+e6aRBk4c9vMZwQvbAI2g6blAh9UAnDnPj+39FxsoaE8+/ldxq
#43MneZOL1WCS1O+vH6PscaqMw0R/ktY3FjdmfvaHJ76x/OZLf37hSuFzH/3NB4xjOtptTd/bnF69Md3cfG1a6990w4tYQ1P7MLe2
#Nmnj+vzlK18kjecvr2k8TGvlVxffeeqrvxj+1t5fbP9rO2m3FO+Ze0iI931VoQozWqzXV1y/QbshP/v2eps///oZ4BhkKQv/J4Mh
#HX0y3mU5lc/6OnNIPgfeO/jrKPlRav/iH5lzuN6mDSyrb8OK1hFbpptYqlZxX6Vratdl+nD4X/5D4TH6cL6oU+xoBrZFlt9fGsDK
#y9xreqG1jEUYP2zicF5q8TLSlceA9dRCVoXvDjvyi5kN5Af60c1BTP9mMMxM728OS1b+YdQcFZDPj0F39SK3A470Ax6EQ5600lek
#TtzGoiw8a9J2q4+2w+rOYGxM6t7Wj0OSOrOp58Az0pYN+OXeY4SGPKJIKDzYRhkL1br8Dh0DM+reAMS21GIuW+CPKd0mfgatXMqi
#tHFT5/u6jZjGxn+pLSXHNVmebwGGH2c9SY4zvMIYqDMokdmULL4kspuXR3ceMG/qRzFH11H1/t+EltqT4PwXf9eEZOF3EQ45/0Fl
#yMl8/z1tPOn8l+fnDpz/8IXL2fkvv5XwsOA4T/MBZXysc08Hnp7ibH0QEJfIMTEq15VXWQR8aW1ptbK87Ew7CxuXpbIC2UpePmI4
#/RpY6PB5aR1Hn+IeNeXYx7im88DbdOQAtRecVuDfdyPPObftRfz1O5+u5jemnLp/n8+JlK/vpyQCZKG81iDnL96T1+a8LUe+G/bC
#shO/DYm8FtrUTW92pOm6224ALCgrqmv6tRmQ/KqczvYwkYwmhI+/HGAO6y7H7VHM5xzzmyiKYkeI55MHubkeg84FLFkeNABc77AY
#Os22nKWMlcjFMjfR5td6Gfm5VLtu3cfqQKi76zwCgXc11cyhZCf9J8b79N3Coyee7FOevr20vrF8c/V/UMd+8/OfZp6/8nxm/7+N
#MFvGX3b+UxaykIUsZCELWchCFrKQhSxkIQtZyEIWspCFLGQhC1nIQhaykIUsZCELWcjC/9rwn+OyuTIAiAQA
#__NEXUS_PAYLOAD_END__