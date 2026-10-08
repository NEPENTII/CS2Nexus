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
#H4sIAAAAAAAAA+w7a3PcuJH72b8C3vIuyeyImtHD9kpnu/zY3Dm3trciJ9k6RZExJGaGFkkwJEYjrTz//bobD4IcjuRNvKm6uqjK
#HhJoNBrdjX4BjHe/+s3/xvD3aDym3/HmLz1PDvceTh7tPzqYHEL7o0eTva/Y4W9P2ldfLRvFa8a+qqVUt8Hd1f9/9C/e5VX1G+sA
#yf/w8PPlPxkfjg/+Lf9/xZ+WP/BAZclvpQa/Xv6TR4/2/y3/f8VfR/7wGH9svvgcKOCHBwdb5H843j+c9OS/P4EfNv7ilAz8/T+X
#fxhG7MlTdnMvWDaCNarOEhUc30tk2SgG+sCesFQmy0KUKp4L9UMu8PHF9es0DKA7iCzsgywFWPzv6dYRWQrguVDsPYDerEcs5+Uc
#HgNRBiNWCHgsl3kOj7xqnl/yLDdwKitE3cDL6Zmd77/fvvvLW+xmqThPQYp7Ryx4Bb/s9WtABo1FVvO5gNY39KAbs3Im6lJC62v9
#pJvL5QVCvoUf3SAvRV3xpoHGd+ZRd/AyyWA90P5cPwWje0x3LKdZQ+34oKFhqMrmON2f9ZNuVjXPSmh8j7+6KeHJAkl4ib+66eOy
#5tDyB/jRDXMAz6HlP/FXN6VyruQKcb3ST0RO0pzL2SxLEOE7egBoaMwUz69x7fgLTbw+n/L5XLPphX7Szc0C9B1Xc0IPurGSMj9P
#OWL4CR7ZK34dsPXxvXu7u2znn/xjC5FXIOR7s2WZqEyWTOSh4vMRq2pZNSMWx/FFljYR6CoskHSg9LUzqQVXwqgbjgRdY2wmaxZq
#6NOLEbs8Y3LG3k0/ikTFAFdnoglpAvbpE6hapNEzls1YeMmeaIXEPnx5wmY8b0SE06usXIpjB3tB3UGSo6JErIzp6S0npb7UcALG
#+sBKXCmCxYeXgBIIGoKO0USp5i+ZWoSBLIMIx/A0/eESBvyYNTBO1AiWg6DDvQiWGQ3P2KjrXNCUjVDPFSx/ulQiNO29cT0g5B5h
#UfVSsGcsCNiRGbDuMjpBHqOs4lnOVQjkIgkJu2+4+e23DF8cN2ExVSXKNEziUqbi/XWF+BNA3xPue+DTW4AIT4Coch4mUUTz10It
#65KVx/fWxjogH8MLcQ0087oxJo4xtD1oRt6fQt8Ze/aMwS9iIHET5OcoDEFGhKmJa1HlPBHP8zwMbgL2HbuAf8HacdMQ1wBx1nYl
#uQCf8wT1F+hiq0WWCxaW8SyrG/US3lJkSi0KsEL02u07Zg4TnzavgDGASzWIrBQr9rpUeYyt78Fq/l7WBcgADe0IbSU0n6CwYQsX
#Is2WRaCtq22EfV8r2NRRPNMjESMiC2GC37EJOGzkudukfC6hx9+UyJU3XC3igl+F45F+nuVS1iHiARGvwOfsEiq2A3RrGaIEGvYf
#7OE4sixTYYCk4YigA7P/cLwJVZAlvWFgC70pG5gJUa47CB4/PBjAsJDLegsKPePaF6gdBfZwyyAzC45atxxLl9ArEp9lhWWZGSsS
#TfWILbo9hW63SylgKRN/GYA7zgVaIAuyGALxWFV0F1Wwb2AC2H0GEllioRfgl48sxDqC7ekBaQizVmOdQYHecIwgClRNs2cLNKZB
#EMVK/ihXon7JGxFGdheFu3/96y5oarALEE2VZzAFPlay8oFO/8Z3fhnvfH++c0bQga+SFaxFXcPMYdF3FoYk6LD8uV865gSBbaTY
#4rQ8c122wTc2LTV/C1PxKWk+8fpTWnyazz/Nrj/xrPjULOvZp4tfPk0XsorOd4lOs6jdUyQdNlmWK7DdL8CbCl5GsGeqcIXcWp2O
#z4BFfwLDaFgEVmVlTPwkiuKPMivDgAVd5eKXPAR/wIsRK8H3gNPPO5tzKq+ADeBZg6biWqzkqGDnw1CG5iuEIUZGYBrA4h4xa28R
#JXU9Q/nVWRFGQGbb0iHX23FIkHWsmo6smBs64InIaOoEiNgFKsDZ7SIhokzA1v/pj69fyqKSJXp1gwnsa/yxwnE8x0gsMJMxxLvp
#GYNc8hSATaiLTOi5XBA9tRo/BFjQyDrfZkQOEB1mg7Ce1yqEnxEDdDXfqm68IlzofnBHj4877nKBLgb0ELtgw/6O7U9gickiTha8
#fgk8eK5CsLrs6dOnMBTwIOAC9iFYpWM3IYQIhqVpdtmVLPSQZIlIJ9tGm/wPU55czGu5LNOjPCvBM+1AnJliaBtO9g9TMR8tmjx8
#cLNYs/0DmHT8TWRagNjv2MFhpElZs4PxN2zy+Jso+sDWIxNIDJKzUy0Cq1zedgU2Adejdk0zdIxP2nTAbEFUKuz6TJ3C4ds0itA4
#PYKMBFQFVB1ecv7L9V2KJepa1k6zEEY77TAyw2CtHaVyjX9fivr6ROQQVoBdD2LDFLAPKJU4zcBO8GtUzRIIDT6fiJtfiT4YUHSA
#RkXnzXWZsNa2VFlYgS8aMVl1Xb4ERCZEAhFn8zIEadciBTIzCPEwrADLsSPrbA6+BHSDMJiI2wpUxlOZXlNcCKooZqCKqRWwjAuh
#FhIzzOCndyfvgWgZLwRPdVZ4A2mT3ss7GDwGqGQV2NmEI+G7HxuJpi74eeftz9g3waSFmfmesD+cvHsbN2Thstm1ocOxRK8QozW+
#4hmopFDJwvLB7WqIq7jJXo8hQL7WoRZ3o+oYiQjRqjCgCrZ8eA6L83gO2qq4WgKz6lg/jTSKdcfmJLK6xjA4xM2j2YPMK/llNucg
#a8g7smoqeZ1imL3KylSu4qw5EcmyFsQkHGZ92OaoeFVnOtDWM7R7kVaDuwvbOcTjeouZuLGSTYYEHs2yK5Eey4onmbo+GtMOgrHx
#Jc+XFKfC6OM2sEde2x2iuAZtSG9Dmtvw0oKLK5HA5i04gAfIi4BYCsrC8xwhYbjdgse+Sv9UyyJrBHQ2Mqden6uNktV7qjHAJrox
#5QaMgH+AbDykcB2ialHDIpBErxrBPCwCsv3rsADBzUoPTbVsFhDTKYvBllx0/OGWtshS2DCQgGg1gWALI2MfP4TaWu9M5NGKP5da
#1WPsJy+N2whfwKuAoZD19akZhJmbeTwBNROYxQVIon47C3UFBm0hjaeQR2ICSCz7Iqk+ZiNLPhd9C4PG90eOiR2Yab06kr9n5Psb
#MbC1y2zyuNxm5DU6ihrQFFiTjuyvY3kRMbWo5Ur7VkbFqf6uNYUqRESGwd/EDhn2EuOxnuU2mVsUtVqz4sRuH0zhIjYz4c/xbXBp
#hqx4H5/jA7r0XNVBZ0THB1B6eooGZQc5dRZETr1NFtovQ0DqFyM8aG6MQ0xEtOEWoH9Z4QJ/ypIL8EfDcstBCx1fw+0StKrRGFFF
#VgQeLuRz07ocSOGbEPF3gMCIAMiDDOwE4vSFTuMhTyrnCtOjPSsqOxx73d5H5gAua6PQAILzyqQOnsmqHbHEBjNIxmlyNmLahokU
#+qhoQmJdRzYuQIx6wzNTBmnbNz08xIGlLswR6639wF2fn4BwgV9Yq3mtRBEG5dU5LZho0GYXRKc57nTR77K728YBXQf1hba8dtZe
#ksazUv0XNRqN0aKSECG8UCD4lj337xfEHQJYLWSnT3dRMtwLB6dW/DAE63DoKaabcT+NmFrxYv4EOb1JobD2QFlU0BQYMXfyJi1w
#A6KDahu8fjGuNeAwRA0SWjUMazgYmjL4YV+XEsIuiMkMyNeR58yo5Y9yFXaCtIJfucoMpI4N1meQ7PGI7e/5fh62cbMlk6A+DKV4
#nfEdLQWMqLAkaGNlymwwJsp0ppPBFoOp4OG77yKN3d9MmT8BwoLDhNAUHSx4qhm5p6CbFTRZKrYQ2NSXO9gd3JaAJJDrKJd/NLEs
#Me/RRQ/NPEtCrMthplbiKMMDiit8NyyE7FcXRIjSkV5km/7GFSDpKmdSYCz7AV5KMBPswY3z4AvZKNSo9dGDGz1y/eG4p9a4qOlS
#KVn21lVhKUpBCAxvDkAvs12bmTSIXHIzHbI5ED5fuKzChZ1AOCT6C1G6KKa/p/yJqkykuO/AOGF4BYbms4YZ+igKmhyOx2SbrOUE
#6Vr9mfYTF2QMJC9ZQtXsjlpQ2mEydhQc5OxBsoRZtusJKlPBTcayDQBl5ekSGYO1QbodbbOcOqwblZhUKkrXPc0MYLPrrRB52NmQ
#RfJGhW1uTUuOUFlbRms4PE7w1UPOZrqZ3NXIMb0bMZP9PqERTTiVVyNyfcbeYLyMjW2VDTuNx41MBcazAVVn+QW4o9TXW2P4YlFU
#6lrTdWxdNkmfsFuPTXVwbwLfHEZDAQw6RWCRCf0p3/DPH02wgtlvsAv/UzkBAxMMjpCrJpHtp3bsywXLuPo+1TWsTdQ/6s7QZzys
#2zOWbcVvQw+19KzdxsN/TyaNSGyUY/R0MekNJ4AdlalcDIlLd5C+sk0pA6mDQqb2dpAl2uaZC5HNF+po8rC60rYW1cxbbi1mkOJh
#gawTKw1mEK1ILSuimCRojBRmQl7YWGNGXZPYowH91z2xQYU6cXqm7RNx18VfWtVsRGboxQadPuKxyHhk279gzoWR1b2++mBjCLFE
#ZrPJIRUSdW1UqCtCaIf3WpJgeC70wVE7Liurpa1J0nPPW6Vih44WstS8ts6LjkbJzWqjAU3fY/y7VDKBtA7CC4QCU2UbQYqK59kv
#2IxlUw7Bd42hSlOJPE8WIrmAHoq0XfwCcX5SZ1ORTq8DQ4FeEmXHC5kDh6D9Z/jbwf/s6gAoptsOboi33VS53UFjJ/zbqeqs4LXn
#q8EdFJnqbAeUTGzaXTEdmTjgqy1zfWXHCOwSb2TQGIr1uwV6/zTl+c7/jHe+t2cp5pQBtPCxVf8WCR5Q29zpKTsAL3PZwh9Qlr2D
#3su2HqB3oSNtXzXwcNHwCR87XJplIk+dd8z5VOTUD4CennQZRa3aahCtIxTSCJltY9JigG+O7dpWiMuWfeIyBueJ4K/EjC9ztZmC
#9pi7lZ3dxNPyDusEj9HjoDZthEJ6VVTZtW6v6/IYrg3ruHyaC9RFDMGPqXELsumyISyb89ksqM3Zb7OVsN0Wu4SSpIIFvCOUHnJk
#7UJKYzLJJrZ2k4otN13T94Zyz7kE9DqSqnVW2lksGyB7EzvxywY5PgtLoVayvrCy6DjquwXQjh5mvc7fb+O93cftNtjubVsPKU21
#nObURhq226Yd1l1uUxhISkiomOcCXOPBe3vH89MOUuZdX69E1ThSNEieebFBLwZtFw4DJzpk+4fG7v0TY/c7ISyaAD2Gd7mclZjm
#LEAb8axo07Tg8ZjB1NrgmUyWzResiKa8WVD9fTPMc5vEy+WH9iVWOIbDFy940ScLVJHaG4/breNtIntaq+/j6cZjd4GArMx6K9KD
#8SRqL/J5x+WmxgXsalMISqYxMK/02rwkrh+rVrVcUU5UxYXOhwrh8qFWbTdSqUonb1jWqWxVp6IkrV/OcSNaN6wBO7OGSASoRiHi
#a7kMyN1FbWIW3UbKR7pqozBaMtd2AC8e44s08rQOUOtGGr2CVPuIbtk4WNzZ61tnunBL+PDgpoovsjxv1myX4UsquFo06w86o/Yy
#OmTOC3mFx/+GzhFz9Y4mkbXwNXBhvPdi/5bdiEhcJN9PUxGjuxL2zF4PMRMd2XdbiLG5Y6cQtD23wcXQmTdeZgDq9DmGRWZTxaqX
#Kvoa2blZ1j/5p+j/LcBR5G9C/qHktz0fBbHqfNvlxLJbEgLKlYYz+E7HZ37IAcHulsViGGzDpcVe1xzS9Sn1rtSpSqd6cFfmTQQ9
#M0jw5Sdkj1ZLTaKGMTXSVlOpEf87J4ZqjXXUYJpjMP0aajbWEi9ABkHUVoY6Bw13JbzdBA4HOTl6qRvztQPYbKocuqs9NGjPiROc
#W7ryobneQ3pWxaSUaCX3cb9/FiRe5pRqIeq7gDGc3ENz7L3veyq4/XZIKVc7nFI3Vx+TVCzaUvNacCqv3lI3Q4xZOZO9gGEI7EIX
#GbWIZbzidbGsnNLp1wCVR8ZZeV5Q1GZ7s/INvgetbtmC1h0FOJy4U7aTn1O2w1FYttu8t6LZ9SuHb9SabZW5FbO2eabYLHvFZhuP
#WEuIJ/7DAqa+bmaeZ5eCNMoxFTTnvuW/tVBJW7LTdwPsOb3xFEFCvpJYj20xFm1HsAdGeoJnMAHZ83PYFjoWbe96qruQ93ATarWJ
#ehMz7Zc7kMsuchoS2L028hD2KpUDUtUBRq1GeqqeV53xBG/fQg470oeFYGaW0zvjHRzWlp2VZ9MJV1seS437bXGbFKEpeJ77/hZ6
#XErQI5Js4e9hSiplbfdjhfZPpDECooINv+ZxSwfduHrNZ3xs9C1mZLSNgLAH284bIUpsB//RbbPxex+VTo8iOqUjZ0MNsHoPddve
#GgmPkFtwaDK644NgKy1cr0o64+RM0ZHn0W3uv0kjrbRHIl38AqT3Je7OQSwelRbDdiLxOopZK1oYfAUceB3ZaxkmYhtKowmENVZS
#cS+SMw3bVtXC+721gE1tIl/gXLzKStCzHB9z2TSodCm+pDVfNfbMbUibMcK4S5u9A1F+FU7oExOPzXgXlw4TGmiCIam5qe6BbDtz
#GExhcvpa5pa4vSwGDpKGQVULSvfJHYW3OuYpr/ecVcn8uvqHVZaqxdGDG8eOPXNzny6GthNAFoF8oy8Bomj9zYc7sp5CKN6L4Szz
#QJoNyMs5vrYFBQuJ1Yi12ZbTfdxp3cSo2Yg10Td2cnNmFNXcTH9zQpcGMyUKoPH0DLQRXMmRTlLxcqIoX6emeMLMh1l4oONdMqdr
#3C9Apzp3zEGl0SS2Xu8796LsVcFErbA0JDG29iB3qYn4Ckp9OHZ+Elpx+7eQ3puKDDp3rP/48chT6T30xqtOKjMY0+Fibj0yJ4gd
#0B+nPtNuP4UCVplmubgCXYKp12zCxh+s/J1lsGtpz3l66AawTehzkbtwql4aPryQWc7nm+ev5kaHF6cb64TKE9PBc2GNujnpH9T5
#2im8h2vvDlw9I1aLZpkrOnKvsRhjpFfr77hWWBj08OE7YjLdaCo7/dTgAaD57ABQgzXVmsRKJArvhgbdS4gpbOgsf4+1zzAdMV1S
#aWsGnSoVXlt5wtK7khwqOLm0GEe56M1eVDXFJFN7ENzGuqr2yg9q0ct9aSGJzA0B5oAArPxpgFlHkNJRED3RjfGguMQUNCBVCs7I
#A1wgsbdjp4++NiNyulxMq0E8lcNT+8riSkvwv60jUcEpFzN1Dk4rv8beOXrNzXqXSr3l/4ri1/CNpjtKYF2K2lKY1jDo3CyHmRk0
#mQ4l1aPc9ul16vrUtl68Xt6opuPl+gh4wediGwKQ8FbkuiS1jrbZyy23QJSylabRYOFrAx73zs6q5pUzQdTU0WR9Oo7v+GjpRaUy
#zXRJffhCg5LzeS5e0UYNQeb6JBNPalftleE3J7H2c7QFizjDy/bMazWX2XXkpFHQZcFV79tROkoVV6BEKZVrzCFr7wjnllupOopk
#sbYs/YupZfeTilvxAHGnHXKefI0F6683brv2v3/dtgaa0ucJ8umzmEA34trPA9BFn8QUSpwiDvcZy31i+21V/V0Tu9DlZpLTQJWf
#ZqgH6/ntbTrTdWQki9PD7F260F63Bf77KVYcWgbcd6rSFr+6CgIN+vG2UNhIGrW/50728VbWQFUh2oDcQyZvlAj6bpR4R/diO3Ga
#JrFbL/HrI3gbfOspPqpZe3TvAHo64N02MEX/1tnSSprWlNsPyT7vWlpha2vDvYBjoEZVuPtf9LTVOBV+jaowYffnQbucNsa7JWkv
#hKeVUzLhAv7CvJuQ3Vw1awPrW1hwkXazCsKuG2/YBaImJ2OzRfIp4AnxpXUht+ZKBURg+qu5ItbBGBXfbPqqp/aiNAvlCtJoJO66
#Vnmbpe47oaF7jbRuUgUYYYdvv+NGdkSfWWDC80KVeNEILFnrFuwrbnrKj8xnLpuOYejjqCG79SzPikw92Rt/K2czQP4EmWqx20Dv
#f9l71+C2sjQxDAQpUIL6YUndUj9mp29Do+4LEgABEHwIFNVNSVQ3uylKQ1L9GDYHAwKXJJoALvreC5JqDCeTtR3b8dhZj5N47XWc
#zcRJHGfz3ni3tipVTn4kqaRccSqVSuJkOs4P/4hTcX4k5XI2qZ58j3PuPfcBEOpW987WNiQC95734zvf63znO/03Ll+l0w2vCtzl
#PUrdgw8VUXP2SAjzpxJ4nOukAznABULCNPUMBwOywLvUrfAG6YJ/UCLsGoP9eGzbRk+d5jdvxNHF9kiy1QpoGFTEJtQSPKOKbbzo
#GQnCkdaDd6poedbX7qttHt3yzgsrFgqM6tgyx9uZOXLtlISND2p0vALqfpMCivVrpZFSqRkiFCiBHDQK/XNI9ZQ/D4/TYCstTBSB
#46OmjZLiUX0a9zK7xwh1a8OohQfSv2d3qmGlpwYRkowcsKBFCU9cJqI6OScyMzRLUd58mZa5qkBqmZyYwUacRWnEKeYk7TJMciuO
#Pf64I4maPbT8ETbk7jas7LDciV1QVdpunxdU1aA3du5I+I6VBLStC/4TKwts1Tmszal54J0pU6yeXMOwV+nwiu8YojCJkoZWrlWU
#Z7bpiKO/Um32etAsWmyHHNDmjquTHsxvDrKEDVvBetPkt3711y+sZfUB1rADackTahMaAHjtkOjyNBKtUk4Pql3yyS5s0sFO9U3P
#85jUhLXvzFdj7EtHuqwQ0ueDXgSZPlCTI+NCt7fi8Chi8HCp78QVPXX42CPZIMkDpzn1lKlyqpRTuRZFKiXyBI8O66kE+Kf9iRn8
#XSIsKx+m6tdVripgQk+j78qX/eHCMxMVW+uI2A9zTtXaM5xcrWnCeoS1Wd1Cm7LvL6amUP6UjSXJ7FVIjorxd41H8rXmWE3l1d5v
#7DrivSqK5m5WdprV9sHrlLCKDtYUKRQrpDP+nrsocbgSD3n0Io1aEc1El0PTgYRMnCIPj0jH7Nh0ajjDsAVp5Yk7PsN32uJSTqcp
#p/XuGe0uQkhLRcjieUHz1zBYDBfKYTc3SYfwN/wsM3qOmN6rdBIRR9XfbK/NbCv3OM31VCdsSCuPRMLYnjaeQcrTz2rXFFb4wmwX
#6/FhVSEGeyZ8p3SPiJRLn2hwk3oA7+yYpiPQTuAYqu8E617wBCuJq+6p6dA5Yw/nBmiqd1w97X3/QTta/CX9+Px/snOQmv2EXYAO
#9v9ZnM3nS0H/n7OluW/8f34dnzL2C1dmNit8AF0tzBcLxfoChFjVhm1AwG5xZ/q6G1AsXy3OwQxVMQQ5yvLV6VKpNFNdoGJIKLhq
#XDeM3RKmIJG3fPX6XHV2hwqpN1rlq7O78/nrc5yj5uB7dX43v0BvWUherJaqc9P4joVNV2ena/SCcbM7pXqhxHmBNpWvzpVqc9dn
#qTkmCCpXjfm52dldqsuqHpWvVqs7s7VZzkCW2+Wru7v16bmqDGo75dSt6n7bru1bQHhTmdSdlTVtCXer2kDf4H3d3DEdU7ttAqpu
#20YdgjaMPdPQHq5o7yEe32kaGiqClIhUxn4EeLqV7TYyWXRIY2Q5IGNX23YW+NLGLjIdEz0Q7LN241N0PLRjWsCUZCHkJLnvtJo9
#xT3TIYjocp7SJ0nE4b0W0CUYg/xCq9HOSsEqnz/cX+iXcaFmNk1LhLGTFxqBUj6v4bm6qUJuRuNYDE8vZI+MnQPcNYW3rN0CgNnH
#llbJu0+jCqNxktxiurDdE66Fyqgoe7XRwgPMkPAkWe1xtY32PvQbAvYLmf1iZn8608nUm5l6PWM2M92m158OEDusJn+SLNOkZQ8b
#dgOGuQfoncAOxEfNNpuNuttaSJVeENFZVjdhqgUxqOjWCiZ/unOMfPaEcEqgTUwlcztVy206bjgvQM/22lk2EagZ6Lpl4WPAFY3d
#R9kaH/Ao2x3gMbM7hnNkAGOyV+3QsUS34YUStI+24SE0A4SupuPpvsMjLasV8qV85zg9VQSOxJ1xxzFb5UKgUySyheeSViLAQG7H
#Au7h1KZT46DGBZzvbB2tbIinp2la4InFw3OFXHHGMloccsTQNJfPixSOhR47yjW5CBZAVIfSszgQ2ONcvmC0ZJs0+3Cvx2YlRRwW
#AZv0rEJgzaFuVGF6MMFwXSniFJKvlPD6YCQVBeY80v2G2Acj6kTCszYP77RKXPjN7Thtt7ENEq2zO8DQHJxSzfDNlfVfh4IK8yEw
#ng00yTdpQFSj57rWtWyop2M2cDS5G+V9dHesjuTV4m4pP3Odo+V5xfBQ19xBzQamVHTnan4XyMm0v5yI6uZ3dmq7s5xsSx6t2u5J
#N1K5WdnuOgsuOPmN9oFaBvVODH3eN5pEgdL+sfIPg2+qwwOH/sgssnGkGPdVophphkZokOhaaC4hGljonuslyzKaUPShweFZBKWh
#uqKg636zPqBngJAWhlle89QfbBiK+0OtSARPwHVZXvCl+cOjBRyJ3aZ5VBaSG42dG2g0m42O3bAXjvahMEIhBnQct8W9QSmXq7sO
#jSdj3FRqgSuY8xDKnLswyupqE5MuoJNz5TUkGUWeY8BRNh4KAw6I1AQldHWY1igcJsf4UM9CSjFzWZAWu970VXegKqhggVAWzJFj
#dsqE4QHBX9MmNRjtAUv9MfDQfAAPIVEhUs89KhQRqX+aBQndOC7PMFnroP0DEjV86HmzwkRnQVJYOjjtFl6cx9KxilkVTPasRp0m
#eHqWgMKnAu6phONL0Y38DGTmhrmEsMSrCmh0L2I1e92ama3tQ0IKj0gJUXwisucS5qIcSDHWaLyCi9g3G05fqhtekTzuuK+K5yxw
#6OE3vNpDS8KHcUvTxdLcAlm7IQI4oULQ56O7AJm8yMnMX1vw+L1rCyZ5w8ruNhwY6ENC7ez1MQJsG21EW/n+yAADska77oIHQUde
#UJwhZliFjDyBBg+atbdT1YszMxn5l5uZSTNqwJMlMDTAhOIC1ShlPoP/gCnBaax1nR46KsyiIhIQXPPRntnW81o+Q6sun/FWYJbm
#N43WlNcyefoRk6S6VMKJEtrhXgjgsbcI8NZhIA6+YNZbHUQSSPa6rbZdLkwTUO1avKr68S1Is/tBlcvwErGHEchHEPwgBClc/9ys
#bLBG4CfgBBu2EEpCjm16HiLJ+2Y6LxIR+lensvA4qzyM2YekCaJ2u7szNO3pQ++53bnrFvGldVOOyrw3JmHGagZWU2iSQGpN+xYn
#FJYz22GeCCTStOxAo274gUeKENwHXGDYAZ4Vckv1hVEqBR+iJAq/7W4LeINa2anudJvAWcO7vUAci8QYUB95qfIPMDam6KPkhVla
#9IgOcALLNItBQUhiC1mo1ohEWTPeoBeK/oVwdXq6VJrZCUxEgcZFFJnbjeQ/aeA6j5Rxy80r+MbPDPRjsdylF+SevgAnyDOxW201
#mo8UaQEb2Z87RMzEZ08QJ9GTQrhLKt0uoliJSEbLh6l0UQhGVNR+wQdN14eHJoRfPPIfgRVx4vAQZJY3c1mmQMjFaUM7ibItc2vN
#Rk9GNdo1ixxXlu2FIdDpdJ6xqVenuvZpg0OppVzeMYCVM1w+UdSq22l/ZbQr5EcgQkJVEEJxSIwwFDcXPd4qUuJO7PihIpQREpJf
#lPCMMLNOkXw4LIpbUqud4XqF/52ewk70o0yih0F9Sz+5uY/AMof6Jer1FBASn4YpyA8WiwCqtMI8Nr2LrmtqVVssPYIHOYk+lYsg
#3KJ/rDvq9ZFSpSpJ4HTD8q9OVCemfZq13AwOHi5X12VDWSMpAM1laPXC7zAcA5TKN2TM7FppzX2bgzea1/wp06FKCAGySiwvneqN
#4EGV3hRLPFQisebnWoPcopqQTgEPYCwH+ZSfz6NPeWLvCsADljLTwAVOz6SDQdfTaVElmaznxAnaXphZRKlFZRfnZEa0lIxoJfH7
#pFFh+U0oV1jsmI2SfkruOOGJ5V5gFUtlR223ft2YVRrtw79zjyMgqbQauC5RJnY/WBfBoCfbzEplURh1l1w06mowBSKloxj7070g
#mgg118ctDNaHeuxsXpv1MKoY5khcIlqSqznYmIGKJZX+s/FvnyyBHF4GEzNEiovobGQonl9w+8zyB4bYR2SCmsRouZNwXadqGagv
#p1bkAIROoTtUiK/HrAbHEtrD64UVSYByarkO8MpfgoHH5kMhH59CjebnmRqJ5GJpDeRjo5QBbutLiKBVCkErHCoABq3PUA5SuRTz
#A5cTl6vtF30LvfQ4jBaSErJQI9pBT8PAnmV0jKqjI+ShyJ8R9KMwC23NAGCmmYiQJFnklmLZWt05jT3g+eDEdV+/isF+zQ5iIEUJ
#Gh1ED8gDQfypFlrKR2lvVeHdZkcuddZxofFeP64Iwx6LFuPIecu5JFRivpWzAywIYitRvJZrt3rDDUpYKeKW4bSGAPxALW5mPNbb
#o45xf8qFqWxBcrP9NQ7FIOBPR3ISXh0hsU5VP/WRzTg3GjuFWzgUZmDFGtnTCadB7OsCL+zo8KIR0X1VOBQ/5OKP0LFgCcNShBnE
#Fx405QoKb1e4nse1mStJGBusKkKko/DmCkpDjN9flvVts/q3CiI0TAF5V2EO5xlrYNfDGzZhNV6edXQtwuOK+glHZCFQJLFlfoqD
#x1a+sKYJ83us0UCA+nJKKTybEgYz7pV7RNpPdEXXp0shobIUoc7rt1LV8rXTtWIDsfaXUiIpIORnG6Y9yc/b9PPanLNrTvT+YaQy
#yZXwlQIi8vfLzroo76y3f8AUmJibj1YV+XJreEK2R7q/gj8iZ/UiWA08ndQXFgeObrCw6M0xPJrUe5wZ9S0pZcpypWheCSvAM+W+
#TpBeU+M4lIvDgrKMRaMbXywGuLGIrfqOjsIDRKhv6ZxUz7cdJnet+og7YsXh9lykfuYkSUdvfUoQV4ZoVju2UZYPp08fFLYfYgUi
#ehqa5ZDuUnaxxPICFlwmjzXZGt4AmnHq6msvQBsguScQzgiRIzzNjoVHzyFpf6QDSfDkOSaKXCOOE4JDdRthXuw5R2ifHAekvF5Q
#ltMw3OmFBDY0n+/JlQ7s164nubqHqXsSl2aPy0hYgXV4E684rWq6p0mdQ3V2Gu3daGMnmopfnxXKR9GXrOXqrE9ETpXEXVesWwiC
#QnsynIe3A0JcUHQbiD/ANvh3DKjbgyRMlLZ5f1O2ltX8g7AsJEKdVV8hV6YghZKqDLueF3UQfzR4MBUhOS+apxKTolDcaT5Dtrxb
#+rADjiwGDynyLYWpaR59Itzq0Bdh6LlwRNaq0ZpSJTMqvmwiFhCwGjytVImXv0jA61jGLsgrWcuod2tGPdsyhSFOlmOMds1gaNxx
#2hmyIMnwdgbpAlht5S1PFvM1QOR2xntUKwxBusbajMEKjBPNE9dD8Ml85TTeZ5CrHlZ77h6Y4E7V/cXpSGO74WyeBHIMWFQNa4un
#Mj7R6nbGrGHeHvqUs1vSUq2k7AMEUNdckVEXXpSKu/JD7sMv+GQmxa5Go+EMbTSoKZDxKKN3I4Hov4RJjVPXUCEUFfUHbYP8zecP
#7uOz/9+tHjZgQeXsw70nWcdg+/98vlQI2v9DSP4b+/+v43MD5lo7bjXb9mJq33E65ampo6Oj3NF0zrT2poowO1OQIqUdNgw8YruY
#QgZjugj/UzdvWHh3FaHBxRQEaIwG+dmCtLMpvMG3uZi6WqgWp6fzqambN9B2R6svpu7NasUisO7abLOAduefyrRIWlKo3jEPDMjJ
#BwNkQFbUVszNuEFIJ9A19mKKSAxWUmtYtaah1aANBWhE7RH8zkObMKPXKD5WgOmxjzf/SOJB3/onK8Icnjp4onWcsv6L08VC8PzP
#3OzsN+v/6/jcwAto0c2BhtN+M3kDf+i2ysWU0U5hgFGtww+qcDW8WQddeKS6zm52PiWDkVdZTCGKwOMeKU0wZYspXq11A8iKWLp4
#P0sDz41k7Vq1aSwWsBAyJr15e6O4Zhx37RtT/J68gfywZhmwVpEspeiShsVUBLVKkacGSIauv3AxTwJKS/lKIHMVe98wnGA57qk3
#zDAluotna0TnDYsdICymdqoWpNG0G1U3BE86uAWmtEZdht0kzBqBNjXl7kThn+qxsWKta+Eu4W1kn8OocfZLo0Yperu48QZyopp7
#fazbSW/OMAEkrtL41BuHypix/EwjB3F8MyqNFIJZSibkF8+zyGJqVdwFmxK+NbAtlFmU5M2C/14ldz7IDIonRV4smlI70a4esqlU
#6uaquQeQKdrv7wFw41wGPYimCE/fN9g1iJIUzdbd5FQhz3fV7pidbkfMuBZwU0YHf1NimJXCcGW5peEtpqmb7lBz1W5L/C0mg3U3
#5z16kaPobzMuEXeM+KRx1CBBDI8SPLh135iCWsWIyUfxwCvJsBBHVBttqgBIjTvdHZpYnu7GIcB0xwQZnfqH6SEbXs7VcTTbqnlr
#FZ2cfGzTIFAs1iOW6hQjsD9ohPqH7OOn/3gD85OvA4n83MxMX/4fn/30vzgzU4xpM0++KeHPH3H6H55/o01Xbj/BOk7h/2Zmi7NB
#+S8/+43897V8UPmYwjvkU2Ut1XSsFLqDEtQdQiR952CPXkIUU0xfBNIIEYOPXpQk5BgpnynWd1coRosbWfyxeAbIqxIkTmCWqnzj
#3K5ltjRn39D2UF/mmJptGOgb3DK0R2aXDEUy+GRp5O8ez6XSm/Te5a+IXLBhTWuma2tShaKA59W6He2R4YgMvht0McN9fvJF8kW6
#FCse1WjhlxOje+0TzdzV0OL7RF5SFJWWr6MWOaYouS+ZuDmZJs7sPNLk9dI1s9XCCfWnxcuZRVJ84oHwboQLDzgNMY66mpZueMO0
#7wCfqeFmEfQER1j6zwomLmLiTZQ4Xt0zHJpEyIhTCNKFk9NgJB/R3B0BK0rTSXF4dWKwqGksahkVv24aDac+p604Gl7ZZ9Nt5MBJ
#txrtrmP4G0M9of4HekSX9QVB3LtEkfLghaIIMTlfkajoxuhb8MvAqEJz8E5Hf+vns+69pRGgnQuXIa4lpOGEVMAUGk3I2W3W8QpA
#bccAwQcdu9Zz2qb1SKvuAVslimF/fZhzXZouKxHuFUuY4EOYCVwCwQvnI5LTjUxBUIAO2O66E3O6bx7hcqJVirDVwEvr6XoBr33e
#hVOMNYQjPaOOrehxI060Hl4DcKL0yrtdSixjMkCitc93S0AB3jImp2heXzEjTKpag5uOr8bBVO/zk4wQ1xBhDD0gNHcsc88ybNtN
#BH0Xg+kG8W1uGMpPoi9uvLCEZQjlQxSbNPHovdSfihL1i6QrbQi1skd36iCA2L5p2vhcJf/rbh7lehTMdBcfcBW2Ayk8OoBTw2+B
#FFUughJEgY53LQm1H+eIpziQQuBqd4QNO5CAZ5bw4tEJLPx2Rus1T6BReKtXr36ioQFCsHkkUROMAKACSESNgNfLzf2GrcF/Ih4U
#F+hzkBT41pTEAwg9Ptqk9DV4LYYkDOj1QplT9SIMotk4ugHQUQbsQ4XYBeM9LHS30W7YgClkSv8SpTPYhIl2G+1qUyNdQi5UGm7S
#E5xhXnaw7K9YXlVAw2C21VC0H2GMaztqOE4cht/BXyXcvZ2AZ1DAlwLIirthOZDiTYk/qFcp8gAvR0Q4ge/qia9+dtVM3XJtD9UE
#3u0CEoG4AO7GE4p+NxhK8HonGEoNWgqlbe1RanJtH4xsHRJauvfeg2AMmUu6bfeNt7HL0AO/Gvn0942uvJ7ChSAM4RS4XCXxwE1Y
#D84ppsXTi+MNj3g/ixK5D0XJ2P1AXL36SEbVvah61woU6YVjaTJuHwvstSJSuNFecNNgYKPTe1rBy8N0Fb2T0aCZLYM83WhHeJ3v
#kWXi436jaZADM6T+2rrhWI9UPsDnkdMbPn7XyDF2ThNsFVFkyVy1jSPB5CS/zh3ZsPwnmXX7iYmBp+3/5YvB/b+ZUv4b/19fy6en
#oZqfGNG9JtCAlPaNPcAfpY9Y/0LMfPSV1DFw/Rfyxdm54PovTs99s//3tXyuvjrVta2pnQYq/g61ziNn32xPJ1MpV/UD1G+Hhcuy
#0E2Ik+o7j4CIZV2lgLiZU/Cn7F9cOuTNuPqWZHLDAWEQT3A0GztWFQRTEwV+/QHVrE3n5ifTILAemXTVLjo5tctAWCe0Tnen2ahp
#mqbbhoNSjJ3D3caM9vbm5gOUaPB3g+6wAk4VGg1sM95cRO5PJ6gIOuOAHKxeKM7l8vCvUHYLk5EVLBWLoYydZhf6OjWhdW1gj6HL
#WDiNyypuLXK0prcNo25T3NKDFe3AeJTGIUyy/zttv2rvQ28z2n6rWoNvx+kIPj6jIZGF4QEWCLcw8VJN+Puka+Btnhbe6GnULMPB
#K7gbe9A6+DVrBxAgstuf4K7JNDzYGPcI7yDaB7kf2ZMMyb0ZrWs1oXaQkqBY20mSXgGtmtmVD4g13Mo6xnMstbBmmgcNw43egN+m
#cZsCOZUot4N7wjIVhNE7zD/+VD6xk8mlBw8qd1bW8cJZm5xI5+oNC3e2dPle3bHxV69UdoG9qlTS6eTG5tLmyu1APpSUdVFcRksx
#25JKJ+8sbS55SQGQG8CsoUNZPbW2/MHDjcqDpbXl1QomS0G+KbPjTNXsYpbAego3u6CQjeXNzZW1tzYqd1dWl4OVyhqwVgkxOHVY
#+a3TclA1ufoOJE7eWb679HB1k24gpI2zVId1evP5+TykhZVI3Gee4DOPzfVBJsQV52bQa3gK4LMCoIapU+zFP1U3cfOMQ4CxbtqV
#msEaQ/nuZtBwJxLvTbTMYwy6S5cfcjFiEdNsQFT/kaBkWV6aYjxEEa1qx5Z65cB4YxTVL9WMPi0zVU/scgX5d+TU54rYXUQyFcdp
#QsAs9Z+uNKv4R+Ekmbx9/85yZWn1wdtLt5Y3YZhTS7duw6i/9fY7767eW3vw3fWNzYfvvf/Bh98rTpdmZufmr6cA2JaX7lXWP0Cn
#8QYAfqsDHdet1Pc/qvcKcyffgYlbW7q3XLm9ury0Fky09dFxPp/96Liw+9Hx3O42pF1deW+5cnd9eeNtSFuc0dzPVannIq7f7KLz
#cLsNw7FPCjv0YeGqSTRyYmFrVVsTmuTkvaUPKrfu3/kQSi1UgHbiHyBUvLOpUXN0CVoIkhCGig0EztX7t99Ff80SLeTWVwGF6NxM
#BMMTLfC5KppQadS17E2vhViLpk9qqYpjy272LX19abNf6Y0OFkv4hlSEgKVgKbc6NmUKFylKrEiwpPuqsOxUS2iPEBxoGeN1ngAD
#ybqxi2RKb9l76TJBFeDGnO2AxGfljizAmXrqmq1dsz9qp7Rrmk4yqO1Yu/gAUXe1a5spvJkC8qeD+XebeINM2q2mWq9IpKCL2vaa
#5g4Qmg16iZghDAbRsZyUo0JiIF6xo/vwEPTLgrVitAH6G2iUw5Y3aQSLXS831ZLrduroya53UNYOSfN9kIEHoE+4Mkmu1XfTfGGN
#nkbP5gcYKRt1wq0yjmtGx9HuAnCvmc5dVJoso1DrVYbj6seCpB3exaRAbUirKPw0IpgohS7TD0rC0HwjUGKt2sZicNI1X+llmCac
#JIPL2thilIl3leF1Du57egHj/NhSSRSIwOm7+qWvWvDfu4AgiOeDkxu3316+t4TIB7iA2+vLuBY2l24BlVi5q63d39SWP1jZACIA
#XIVl64TItM3lDza1B+sr95bWP9TeXf4wQ3ZVHIxZ1h6ursrJousMvEuytZW1zeW3ltfddIxIlSutRYIMXgl2GAxzL5AOBREiEoHp
#hUE9Qexs67RxEe6I0kG3hV7vMgq6cRsAXA/Acj3cM+bEgsHuwOS9Zq6s3Vn+IKqZFW7P/TXRalvcQDqge1IrqzvmgQGUCTi6YfvZ
#vyfGcaeB14yFYwBDYimD+yLb5HXHbeUQPUL+vOJm8IZe7ZG29HDz/soalHJveW2zT/9Ck6fEia2NcAQpHkOAFdXLjtI/f5vFlaZu
#/aeWg+g1ohiZn1t1GhxQYoRdJWfU2PkAnJYT+odUXtUFN7hSITwNO0kD5qMLoYHp81pFx8EMZQ2SurIPbhHXLXuJ3fup3ZCjRrvt
#oY+MUMB77w/XVr77cFkdf2heeoihqIj9cL5gJ7qnp6EcinabwlfSuq/iElr3Xd4ZKANoBMRFs24iulrWPxw+tGsbbadSdSowql64
#Mo9ub0Tj04PhudXx1oV/VIZY/NVDoFQDKM8uHiOOXLjmwQDcC/2EBpjtqsReSP6YS6rv0PIL8Ed3btGbiZt8BwaIC7YiXxjHMOgV
#82BxEy8XoYTE2AqZV5o76EIAA0yLu/IVGya5wszjIgs1WsM2m+TAr9I0Do3mIrLGLB0DD75YmJGF5yzzqIL7f6b1SKlo3TySCYxj
#o4a3i6QerC+9BRT+YxBRkKdoASFZfH9pNZXulxLvRNkHsdTs2otr99fvRaRlm0admQePR8Thqe1DDV5P8yaIQD7W6v4Gc2kgd9t2
#UnLxjOKAla462hHu5REKxN1CUlawzQDeBdWBycZtfrrfBh4djG9YhKm0g7Z5hHfiof++pMusCtHC4+LUTj98cAdhz4dpNeBsGfEv
#aiDK6EwcMtrt+0uryxu3l3VgfVeXb28q6PHu+v17zCRpXe39t5fXl7UuX2UNZfgK59C0JDnptEjOhGaDAFUMeLCtd6BWaCvV5baV
#c0sKfUN7A7hwHTlJkhRISkinM+nTSyQWQxQnWYE+xWlZbX62BLJtWsoWMPByxYhLq4J5REK8v7FNZEk/BDy3OFvyZ/PEV7Rv0VH+
#B2lHP0TFWSqVxkujAPb09Fa5vS2KdMwKVgbF1RdhZTfNxWwhPzFxHa86XKQnUQXB6KFgtA99UKmjoQ8BZkZ7r9rs8nO6LJtVV9uI
#TlKaJirD2vp+A0QXZRisFpJPvSWqxOnH9rdE+2XzQcg5wruB5A1geuqjj0jjI6a+RXc403FgHQO3soVttQkg2OPwgFD//Wr203z2
#euWj7DYWAH8tGJzZ0vZXIDZIUzPUeGo6SqeO0ZbKxma1C4jDsNI0EqQfE+klZOAlbSDf+JQ222EJs+UoKqo9wyHZWe94EAwCYQtv
#GdP8gvaWkLK3/eKmJ7B2HkNIJcIJ7VAlUl+CYN0k1aMUt3VMIu0xiqx1bGsDBE1gWdowy8cZkq/TZGekhrMOsFFHUR6gM709sC7R
#T4QRJ1Js9friYlkBONHNlhqCxqFRoSuqdBs4nLKHQ10Vilcyjg4GU9MxuTo/deohYQVAFvUt0sRsazc4C+uc/AMetdBIM8RNU/hZ
#pW040DYOdBS4iabY3thqi4toIUBtE8F0cCEd2RRct/YWp9jm3mGfA4OU9PW4Hl2q7JwsbQBxwoslVRQtSA1xhALze5y9QNcuZ7pI
#6BqaBZg5R7wRjKCeVsdUt2QjsNUWtdoLMoANkcat2rU6ajOokzwJrD8NjjOwJhmyvKJbUPHREVWeOj04GTAlWzg72wtUCN4d5wen
#foMu6paXyfawkDIWmdG4O2WeQnVKCA2HupdxldsiMb0JDXHwk3ItqHZMs6lTbkD58K7XsfjeSZoLwUCq0A68Sy14qGTP1LYJ6CpQ
#nGtvC4OcTjPI0XTl+5QGZCqqUceBRh3Lgik4L7Rr/Va9cexYeJHk1gEr7nB2ST9LWjrUi5GRpNHe9iAAJhkCKWd5qFnFvvmX5Cnz
#XD91jr0pZp7am0Vk2qNHUIxix6tAncLgdNWjpikjp6EeGH45ztgxGxqmHxiPFpvV1k69qh2XtWNeEr6VC0m/Apoudgbptk2bVvk+
#oARYrsgP6nhmSeqlBTeLawqDuUM227IRbyZRIUKB3Klgqzsh6oUQYi9lHrhbOsIoCTdIVtqHVfSAxIOZS/EtvYQDF1UW0msHT72Q
#RfBOSCQ9A9BsOxrN3r7/cG1Tn0hrtTBTTH1YfENbWrvjMsg3mUEWGh4HaB3KOyru3UrVUtsqZLe1m4vabCTF6Tccm6YJTGf7kWiO
#2CBFC6336fZMEIOPPNPxk0GCDpeAAg6qJxcLEX2jiLzXLUV2wOVcwcVsVdt7hl7MBygnqVVRmcxbcGJPGIRCswFcjm/DKx0sbD7t
#Z7B8PGFUj1bWNpbXN1HKv69odYVSgnUoipLJ1W+mtfeWVh8ub+hvZMS/dB98LD5RxQqZQ1kHsp4ULnon0Bf87ED1B75QwbVJ6X2l
#7Rh7wFM/CmxjeIPbdmCODQ8XA5g8Hhx55vXRQKIOqaLyl732FPmKajA4nmlU9Ny+v3Z3deX2plj42p37mgBABD06hw29b3bRzJCW
#buQM+Gt3vHH195MwOO+7whv+bJVL29qklsqm4JsCSuVt3MmlXVmxz+Lu026n5U6cQH1yI9GH/ohVGTTvGdQrFeA/iJyzLjLEfMD2
#5ofGfV6JJxHYTJAXYrVcCtvBVaQ0ykfRgQxtlQvF+W0fV0yU2hNAOlIwgQyR6NvSO2GEH1r9AQCVx4Fcys2ZmS/rbInX7bRHyBXc
#3vEhdpw8ziumQERTIA89/J/uw7PhJ0W601ABHOqWgJNXwtpYtRpKLoKD6fvXKlSyoYJkeLhmaQ3tT8+hnJr0GyXOMjOo8g5IuaGS
#KDBcrXvOw59aBKdp/eWRxk0CjSNAcQQPg8uFdrnDkxgk0Fhf3uOYI1MSk5XRZkse9xRadsRHuV0ozgcGIdVoV1ritAtx6V5ON4Zg
#yj0tE0glwtPBcsVuQlSTZJTbrOvXr7vTWakNyFMLZvLX6bGZ4inDhg1Q3slAXh2DtgD/oKIA58hj4wh/eAvQQyKiBoV5JwrNmUit
#VNaqh5WjKnTDrgxisFSycmv5rZU1RakZIu39aFD0LlaG6IHcqsoMS4nc7bcoanR7aWMZeaE1zUeXbtx8/XVtMxSsLa9Ccn5au+Nt
#m3lEzW2dRygDke5ZpcgPCfE0a1I2l2+4PLbDLEZwCofnnVRCTyOrkHm3pRlloz2Cg/oiNH/w0Pi29kPx7vmsvh+FvmQ0ZRAd+o/i
#ZphFu8qHAXHrQZ6E6IAQySNapgjg+fGsUUZDdtyXErkxPtDbsMX2xMApGLjzAKx4mDFXtwgowAXpGzdJDHGop26vozspiH+E8FNg
#mcffonAzFG1TqFnYilATFGkoDJWDIDNqG93DAmIDxQeM6YgGsKIeAgUp48XjHxhk1AjHhRv4CQo0GSHRpN5IaRMk7nPyiPH9AnM8
#YEB5xEn0xm3MlTVNv2anUanxSUbbYkhGVlc0xy9fhOSDJ98+AXZhUFOruX3/3r2VTYUA9NdXB7Ou319dvbV0+91UekEjb5x9+P8A
#B89s65dl37uUKZJJ6XIWYFKCjL5koSHF0Dz/TlUcaRQ8v8Lldx6Dww/sNnTU3YYhOfpBqunHIum1blCTLVb2/XVt5a21++vLvMal
#zYi3rmHgMkg5hZlHhqw7MoK9ykiWKcNWGxk21giTpCGFe0lpu6QhOI0dDcMPt9Hj30qAHnjPMSI19QTTkjwXTD+4mUMznF+IyRyi
#Oh5vn6wVTiTOrvpqCqNagA20YCDD4TCCavGqwwOQVfQPdtQIE9LTuR38REPf+vKD1aXbKvhJi5S+QDQUIAEotdgoJiDcDhBqTxFm
#h5JVT2vVcBLssOJpoDA+6etLNfvYTUKLJH8Z4b4PkH+BcQGgktKtz4AJECTvkfxyUCfLqHZw259LTKWkGxk2fJH2LdB+3J527dnt
#MvOTwtSFuE46teSSbDaDYSMY1wqerC/QsAnr4vPA2BavN2xL3jSMjl7ID0Dlfg2U/PSTOuUHUGMTlcFbjGDlHnBa7glltLrcPFJN
#vR11v/imsl2s7q+65M+/T+6W7NgstUILwg2LJm79pvgJsUh2P3b8tGHEj+AuxGiVPcF+yx2JbU8jOFw/v5hhkaPuBpxiLI8fMphn
#qFes478K0xRikYW5YHLpPXHKiiwI4O278EyH1XLfxW/0P4/O0hdn0DoN4h+AGL+y9hYqSmj3GoI2N1cr9/F8RxFp9PRsPi9D7y6t
#rGK4Evz2/Q06KiW4KT7whWdvkK+qHgCWbOzX0RNOSp4HQl9H3XbDeSRTUSjK4sIrKYXLnffqYYUOnqn7aHJb0Hfm7D02SeThmNRA
#bOnsqaWw5kYpBRAEDYlWhQJpL5a94TTE7WXW6wDuyuCyUV4DtcdAqW1buGkxm3UX1wzYAhRmUEHG+PHtIYThJ9l5EtyKqffLq+om
#VtAewrV+kFYq1lZKlIqWKpruwQAm3UJsLgwkFDhg5lqnAyEiCY6GmJOGjZYPun/20tHdlyIoLnMPIiOT+jC0l5ZNJ6gONfa7uU7X
#qUAvqw1HjRbLl5fF3W6zGVlmvWHXqpZbLgNSBQ9eVhAVd60mHqhtNRzPTnXeBVCUnf2nOnPr/MsZ2fWmvdhLPQTAzy7tGeyYSR60
#yz6gg3iFXD6l2iUEioRXsu+Cd68R4pdsu6yQIAb8J1StU8NhmRRAgKLnbW+lNE3zoNsJrpV1YUXD4FahXghbYuLw0uwOa4M3rgAU
#dLY3wO+0u0IODDTb1TcUAcw9H5gOmApK4IA4hXQHabTPVs3WvQkib+l2eQpPCbPtaQdND4064pepFWooDv7UWwb7sbI2uq1W1WoY
#9tRhceoNtEu4Zr9GORt1e5GROJorSPNv0unn80EWq9PELgqCDXilA0RFWGeEbFqEGBuUEzrNMN0SE9hpbuW3BatKU7ELAMzlhKLw
#zpEuMdZKlJg05sQfm6QJctNpaLtVWOH1wNEv3/QcwzhEzEeYCkx1LBPxhT11zZ5647jVXCyQ9QrDUpEHOYe3vNcBEbLtIpo0sgmp
#0osWH/20jaoFiNdK3eBxwDV+88arH23dRtv1j7b03MQb6Y+2P9pGf8heCijzmAYyooh7NJSDCxFpqBifvYWvPOrVyp1+RclofynS
#hq2Vw2tagG0llrHFWJmWGCD8ti+yrUSqaG/gET+eXjEdYoqJu7xmy5mWe9NGOtQ8b8UrdNe0DjzOP4obl/Y1hLH3XBs6/ACNW9Ty
#C+6hBcHX9EUGKlaCxEFkFlxmkJyoGPzmSKFhI5b1IDXFRK7afqTr8tw8PqRz+6bt0C6IQFkguHDefWbz9wUxI/YoQvmL1qe+1UEt
#LzGkR2muMcNWeXobLTl3Uh8d7+5+dFyfx99UNOvstDo8AgoBJr4IIlKROTx7YUiCW4Q70kBY2xUncrEV4ebRTNmuRTflDlD+6Dw4
#u4XHRkGCHbtmB1BQFGD2FwX6qd59B28yktsyDzICrL6A1YcoxNvLUXg4LxCqkKC76B64cGNFTEa2TwYMUM64RiSsc1PKT/vYpD4M
#jwtInrCcz5W+ikO5yPsTgBPOaBkAOY/I8lxlQYaxbetGs8wT6imVodlk/AiGvhtpbORDRZZ5ZEfXrhhibTy8p7tTi5IygE9W7ubY
#Rg1kZTx2E0ySJv1GxrPRa5++X/XW+v2HD7RbHyqHDe+v31lexyDSltyBGsQehuOeZ+MxqDabyhi0+netlRO6aDyyIdTU7mMNN+X4
#4npqrV/h2NHeub+y5roz5ENyuUZ9sZNzzwxyjzq5vpPlNVQe0FjUtnrK3kYZZRPvdVsxkFbM6v1pyHSBnUAIkymKr9ks4ZARB23G
#dqQXU4gnZ4/bGdczhs3B7dT2CdEDi8z9YCDFsQ/TqSKXaHdbaGkvq9v2DMdFhwS0o8kwuihAauhaKFCZNDsql28Tv2F3m04FEmHb
#5Y4gdkNoztW3miPNbQXEUxmLWoodQR5pkz4k3VRSCKeQzQFJhH/IupeE7Y9VUt5PE+RqtcjOJqAyKweJOerP2FAgrEIrh020RC6k
#7Yo9CJ6TIJB19excpKttiqDlbof8kOe3xw+c4nANgXymDcLoR4YdU5hi0cMRbsC2asfDceJ1e5AiWrHl4UwKVKhGO2pkjWOFJXnb
#OHZ03XdkoN+RB5Lu2aZbHEJJC5lwYBM9058tz3hO3d6WA6sYOKS8ZG4q17bLtwvuWsRBKD9uq4ZvECqetxWrNDkWgwfX3w3ZxCB4
#nSjwZeI+mh4As4zmN4vXs8de9Wgkz52Wp+nS6e2TUKM8u1u/+suvqvcsE4lZkOPaVcbVM4vhCOV9WyJD6YcXoj0HFl60l9l73Y4w
#9xLeYgg/qmcV+MHzaOQuKTsjfKKSN91einKKgwmEG8nYrUEI+SjDKIuSYvGInPC5foIdJ5epjrdj4eJQ4cUAyWTNEQgAEQ6JLYta
#sYx2FtA4cuRMBwUoJQtdTSXldChljWivSGkb5RBvId4JGZPIh6jmpiiADy0RFnbjbvjiCP2KHjFdxSOMkjMU6itzd9c2HPXUW1gZ
#OYAHIEOTnMLmtHJk/9XKyY1seOS97H58Qkt4ApYcA/7SwsQHXov4JE/5R8svAoyeDLPhcUui7cQwAUm5t7KpQezdu8jZvzFwazR6
#mEO8i5jiLXG+x2JsmdEG8zG2dIo+mJNhKmN5JEZu3HOR4gUjeI+egvkxiOcUumH1JRpWgGK4Hp4hQjwrqFrhTlycbEXiZEvByYFm
#eYbGkEi+UN20hDH8sfmhENemLiH2OS1nt+U/MBpaOi1mDiKWTj/emEFRQqY0PvOY4JbigWKA1IIVhxEKNWmgnCSXCTdDnq1sRZ6t
#xE+nn+DjO8NAz2JNyxUtJisjPHWwhw7hmSPkkWOYgXIXrUDZ5OIDF650ICKlHrU3oZUoFmIrsBADa63VZ621otZaK3qttby1pi6v
#lgqZfiKpLLVWv6XW8i21qFWAoOEtBF91/mL7m2Rv9YZkwR6H1/KWcse/lIW5Bafn50FsGBtWUGp66sPHsXv1CrtXL9Oi6WwFDSmI
#L+/Dx8ndS1+swtx1bNfXHblbrB4C4qjuNA3lCDG54KOXOrsJcB0zRrgIwJJ3sWTTziElh2R6PSCToH8z9M2iehMghwrIte+GlKAQ
#KtlIsrVL5TrtPVSv0w4q/xr8cGTsdIRO1BLXCqAPxq2l7Pc8ZwyT34G02IYoUanrbGGUrBA373dV5bR0kuIhl8Ax/q/mLGi16+wz
#11d1jIp5wLs8gm4D61U3jxQ1lOLdw8P7rmNEr+24CYjBwBs5wt0eF0yOFXVVTUlq8U9oZD/ZyuMuLIqzXHNZ+yTXMTsIqn4kjzzu
#J2k8VUktdXE9WVl6rZCnkJxQZmwc5Ndm8vm8f7LcI87yuLPwU0jdUYxWcMmQi5JDdNQhmo22AdtlTgsN1w8yyi6EaCNuAbicdt0w
#WuKwYaMjBlqcqFT8fbhQJv19oL0ZJZMuUrodMjJKKl3E+DS6zJgPk8JhVIp9duEnIlzHoIOh4EFS6tRAKm3RgSLehRcHNUl5ET6r
#d7oScvhjr9xYpYWh3RjLxWeDimedKhbvSX2LnkCYUTwcBi37pQF1YIOA3PeROQofoWV3fl2raVd3DX26GO3Px392JuQJ0D3EKkbY
#9exHADfsuVhduInO2fvV4swsl58jpyq4mnP7xnG9sYd7/Gm3QocPjonZ9PvN3U4LQxpqhW95yNxYg+sIhPPikHPVniiKgERBYSB/
#LLC2PZY0oFf2xlLAuBhAPn/xOANDK66vlw4P7NhOxd3D/AqwPm6+Jem2U+273QY6c1E8d+c2pXfbe43jlbbPKXiOPJnzkSAe03rV
#aMHcsFMz5IcJv2EMcJfmUcUyYNoq1XodL51So4UpR4WMUSpomgWxsyXGT+gd2jkWqlKeuKtk77i5ukEG/zDeBwY8IYK35S1tokjh
#nhf9kaPLYmiFVms28KIU4cd1pwnd1ao1JLzoK5f64Z0kIBt93TaauxlZZEaUIDuioCRsNjrgBTpeabR3TT29VdgO4jrFRB9QvX6b
#3cMBlAkHVJtsuiLebLuZ29hYFW+CMwgevRV2dtxjajLbodB+tUXbgv42A3XlLcKkmPq3qbuWrs7vLeBRcI6FzY5IIk9UMNePyifc
#pVz0rHbIaIeVEzAWagphHybd2y8qNLpjmY5ZM5tqcqx7qpArcDZh0YOWd3lvmoCpwI1tmB9lSBhc9kBAdRyePNePfUqAU0qlxmJy
#MFvDpjnCOP8QUynS5Ij8/lJzfKazwXRox+4c546saqfCq0pXo133BHhtkeI9kIrpEhHPcf8UuISprrRgBoH5F2C524KSJqrpALuY
#5IXCa9xo4qanW0gjNGTQfWGOpLpbD4DZ8S6RJOiBsNziHB9k75rWURUvrcMnPksSZLCPd12sfLwrXZtlUmm0yHGdupVmvNUiaQBW
#FwJeFQDa9QqaPonRMHc+JhehTtdeLCJRkUZmNN2KAxq2PSCjqXq31bF1ygkYpAtSX9WuNRrsljEtUbh0F+bNEQMW1C/tm3SuOCoJ
#N0NP3Wbzzix6nCPr0A4MRY28Pk5hYxbc2+v7Vxcsa9Vo7zn7ghckZzRooZAemBX9f2WxAMtspkjxm8U7MIxwhbUueqUQOW2Fd1NZ
#Yl1EiwNJ5XCVmDJQtherFktRR7iB4rO3UGY80KIAKIc7+0FWHfXsfTKssLnXdruxuztwlNeNXUCphpV9YMJMPRKDZYnQgVlhZVjV
#lq/GO8trHw41qRuim0q1QnzK2lZNex1zvr6gNVp7yjuBdXkBAOFR01DDX++2kXXMNmgLAfLtUsOQCuG029rreNEghKNgmoWK3QCY
#5Va2SgRKFJZSJgOJq7f8lFloe+ftwhgjALju2Q/35gC0yfTRTZAFZGSZz1oojhoBaZkmMNnWngq+VvVIoiuLoIlsPtuqWdhOqnfi
#qdEDRpSQP2Btx7aZkCUkvyg0vS6O3UU1E1AMXnQLXCP84FmwILareyPL95oIrEa2pQPsP2uoNFFuPokcc4xQfTUF6q5tYS3buUNs
#MHUMTbtgbdfENoo3UoOPyMjdmpTXGWLXAxDiIniFo2dsz11ItY+lXQe22L/+0UGV29FwoeTPAUQN92qRbT4FueVeLrJNk6lHET12
#EDiQzD1AdoU9CrKdnFwTguDilXxm3SO4dbPy1vJmsLFhyz02mGYTO2oB6q0ChrUZUql0Kcq7v0bv5oCpsB6FDzZjMZLn6mtQ6+Eh
#WszqSdUTNMkrhcrtUOfp9iFvO7JfaV6KoBNB5YIVnB163D7x1yYMWl1Vm7A0ndL53pP0R6ikQ4VbJ9TKVrjHch/YsyKNtDXsY8Sv
#5EpH9JfSymMYip3qpKtJnJ6NMm58EtNAF9b0nwMRHVTBngws0ogwrHRdwWENtGz7uhmgpP2bFH0cmnfNqb+FcMmIpUPWcUOOZ111
#nPilWxMcqil3C/6XbMj6Q4Q0GQjvigvarX/CyI90q8JQv5jfTpMAWeQj8zP5dCg9b/OKDDK9ekg0CHfhNe4bU1zrk+mh1/gvAYhG
#bJI2/Fjnq4Ra96abVD+84bP1JtwxleqL0XwbMuhmZBYdqoVRWbhgcWfrgKLdG9Sw3HksN6JQ3pSZIifZjXbdOM7tOy0SXKbEBdfw
#RF53h6gm5SshqjZa1bvVw0YN2EH4ikKr4WJlBvswGtE/Hoz1n0LptfyWhSrGBw3Xd7mnS1o3YPkJL+Z+9kFuJSkFnWpsDryL7+yD
#5Ez8Zub4ISfrQ3ZQ3NvD7yeIRwLjFWIzFc2G4Koe3N84na3qRLNV9P2Y7BIf3YpiDpc6jey7xqMI7YcomQ5FbrnX4W1LTyF42yLd
#01YFrlZoiGmDTE3cx3XO40FUt41bfKbV+NSo90Ve6M3BlZtc6S6yRwr1ExdQCieM0c0KeZYdslB5pP20gv1+G4csXFqVDixZ8Sfz
#RVi3x0LMUbC19kGKtu9SBSiCPle1GkgseAcmpSxrNcu07SxdJooSuy3129gireF8yVajhxqhteR290WaOLQIZQIth8G20ZHQ5R5v
#DJREG4JiCzrV6JTRi2cDxJ75jHQ96EvBd7Sk0BFgnlI8iaXi+tytOo7R6ji262yXHe3maBiK17/4+rGI4aFNX8+BCq2fNO2E9R2Z
#J9I9dDhBu8YNW1wZj+e1EP3TjlY9p6GqTHsVWsWby23vxkfU+/FN8GZbDESUSKPu3mFfQwlqePJJkfIXr9kL2gPAyYtTC9rbIFXf
#bzcfLWgb1ZaxAXC9uFo9XtDuVY/xoPAiu/bmTbbMKTuLkWPpaTddXQIwD9CmSWgU1EoxYRvLgeNMzj7orGZG29JTG4aTddUutYP0
#9jCLxuw6EavGoWNifdUjUR2ELNGgcroHDPwM6SFC3RKN3gTtswX6uJh00NiqQDQ8COVTwRn5ZWXQPB1ixKbUl8Pew7KAyGj9MvKA
#HisuNmlN08Gt2iZeGXdcqe4ZPu1gk7BuM9fkPSf3xh384BlyxVoMkHeTVD4+Fxtu+UqnBWbG/KrwEyoI86IqCCJso+NSsoCmCYvp
#cyXJl4XLGl7ejcKpvMc7twdAYVfwmetFsytUcqvbUmbNgcUGA4YWCWqnqTifuIfWdVMs9XNdJLb59riqh1W+QCxq94vukUbDximQ
#oSaPQT4LOpmmUhlF+zfKsEEpEZSSV1Fw8qD62jvji31G69CdyFuAxB4h0/HgDpV/46+owu2pu37UrK9rZ481rrQcslWXcorFQfoT
#8cjD1DazdDnQY2wEfoHNPGF2sCIELWl+4LcxUCwFFEs5vDpcWo4GLjVmrCCv8KM3cYMfq2QpxPUO1O++cHG4WAyAeumfVOxGXPnn
#XQPNJjO6g9tRzqJ7+D8jzGM4D68a0UZvOVbrdV6MA9ZM7mPZtKh8/tWDyVEb4VoDBoXQgOeD95fW19DtDKTTRBo+h6ncc7zAd/Lx
#xSFLD1aQhaw3bNQmyx0tZeLYpkhPFYpzdFV8IZWJuP4YWN4AKHBBDLteMZCTbp7fznj3K0NeXx4bgJduCqGdGdcn0eDdoEF7a2RN
#IuxwaGEeOzq+Pli/v3n/9v3VyubqRmVjef295fV0MGcOxIVGq9tS7FowK+R4jwPw8bBQKYYyEmhjayuA1ABAfe3P+Ley/AwEX3Pv
#2U3Bt59r8A2Q3X9brx8vgIZXNbPbrBM47QDmaNPsk3PaBRIT0C9Upwnt1tCKR/WN0medsJewAYukX0YJSWzig4b9xuHAgqgLfKVk
#t4P8THlqCr6u1dFrtAfVLsBCTJpZHho3GvoQEEYCtbpp6ZgdfaKiaqn69EdMn73fdermUXtAR+zGHvWbfnTxtrHy1uby+r0M1Tg4
#3QrflSyTyYrVYQwPmfBSSE7FYFVV6BhIpUJyTKWCuLlSEfILI+pk7Al8clJd8yQK6/NBryNzMzP0C5/gLz0XZoqzhbnpuVIB0hUK
#xWIxps18hW1yP12ceE2LIQs5KN1p8X9IP+78k4XhaqN98OQh4fHnf7pQ+mb+v5ZPxPwLgppzjp9Qh3GCZ0ulAfM/G5j/menZUkzL
#P5nqB3/+iM9/AQnxE6Ek33z+MH4i1r/7lKs3m0+ijsHrfzYC/8/MzEx/s/6/js+97/1abBR+x+DvF7+IxX5XhL85RN4fw98zr/ze
#M7HfPvd3Xv3dkdW/8+omube1zD2r2nLPgRia1cV7y7U79ze0llk3ck8/nfyOKOPBciy2OjIac/7bP/U3Zbl/P5bSzo/A7H8ALwkO
#Sx3ClyYqjcX+GD3Hud2xmPcb+9scjp/R2A/+JCbF/96v+0Ofv9uNxe6LznxrNKKTvxmLPYV5IN3mEGPifqB9Z5XXs/D+tvKeQ2EX
#fvX3RL8+8NqtFPGDnGVbtZhoG7SROvo9f7o34X/OMppmjduKbaayvh9KdyvYzLFD/n2bspyJ1Rdisd+6HouNDNXJ8Ofb8R5kHZtI
#xUdP6AEC4jIgLgJGZcCoCBiTAWMi4IwMOCMCEjIgIQLGZcC4CDgrA86KgHMygB6gbZfy8dgD0c74FWoe/GCj4ha8dKg5cWsKH7Eh
#8RQM5ZtUY/yVZ6mi+ItUfNwqYCIsOK5ficWSEy9ZSxACPw/5p8o/fwZ/oC1J2Rb5oL8IoA2NejmfiP1ohMb7Qtx6ZyTWsXbgK/55
#4hVIYL8AZWPSZBxC8hjyErxc0SH5JAa9ikHfoqC4CCpg0K9Q0KgISmHQtyloTAQVMegVCjojgqYxSMMKEyKkhCEpDIG+T45m9vWr
#8PIj+Bq7lr3y2o8gauzzxDymgvWcvPZjjNFhgCbN1+A9OfnthPk6PJyP956GmHFTh5dVHRqXMNPwmDBhBJLZv/dZMpFJJMxJePmf
#Pxt97bNYHIc+9mZcfwGTnocvPYOD8HlCx8qy2G47hw2DyUqePE/zAMOTtH4XBu/FPwd9Hbl2OW7CWCR/du2KKAc6mvjZtRfEG0xe
#4iew9Ed+phdxBuHpW7gG/pvYxP8bExzRz2LG+MgolnY33nueuh1/bUKf5vSX8iOxZ3ipXdBL2OGLMX0G4/7T+HP6LDxkrsXNOfz9
#lbg5j119Pm7C4kq+lX0qzoNx+ePPRycuT0BZidjGCOKs2AW7DE1LJuIn16DGUR2qT2RHJkbPJ8QAnrxOgwmpkk+JzkC2REYTL+P4
#tYDVPqP09XL+6fi49VI81tE1hD2ahqfjvWehsEQPi7w4Zt7AXFvnLox9KHLCvCU+nlqJj18880ruir4I8RfPWJ9iKTfpWU2H+T7U
#obJJSPPPe2n0N3GqqFa1vnMMBPYSwo719yB9cGrMWxT1jyAq8UPMot+GABH6+xB6lp5/9BRGwZxNnryGpX+eWEAwWcZa78LXazi+
#Y7Eqo88LoxdjL7zEXYlZY6OymbEfvYUZzmPzY6IlFxD03ubYFS9WzTUm4qmT5jsMGlDfaAxAFjAq1Ge+i8CRoJnMvBxPXNahmQle
#FAmeU3MV23l54vvxHtQ5ln0al1oim4jr13DuJl4G3IV0CpbmBess1g59ntShhMlr2adeuxj7/HkAxZcTk6/o93F0fGHn9QcIdPZ3
#BYyu45r87Mxrl89/FhufiI0Igvj227EzCOuyrvH+dT0bUdezoq4NCHvH3hR1PTytrtEYkFbGf1dOsO/xyycXaUEjgJ5cwsce9GPM
#fA8ngDDQq7QUL7323OeJb3vY59UA9nlWYp/xKzTgAt38byq6wbnCNmGPX/6Y1/3L+TOx348R/b4gpmNkgtswyrN1MWa+j0W9Y8Ny
#T1wToSeXsVk8rTJhnJZUdpw6Mzly9gRw7ljSV1jC/ACXwSgt6JMrCBNjJxrFf4jTdn78heJ4YvzkBYTeUfN7NORjrz03eUbfguen
#z2VKiXPmRzjqJy9i7nPmNr28xC/fp5eX+aVCL9/Cl1HzB/TybX6p0gs0c4xQ8ERMzNWvxXb/cWxUwkUdQmB5XricvHzeSiFsPIMD
#voO4aDJ7FlkQaBE3/IXp5DmzjsUmJy+KsBenz4qw82d5Ov6rz5JnM4mzCvZPjNsGLiPGx8/Frt+T+Hgs9vBD2ZbRGNKIJM6RDngk
#8dmLybh1C1qUMHcRUPbwK4sRXl9gTs/GXkxT/kQsCVjzPOLbmwLfThLYDY9QRybsfQSw4YHyUmL+QwR1hsxL4/ELAjYZai4IDG82
#cGRe8Ad6dPPypbOXL527fCkJUUFwuHT+wvnMty+cZ4C4dBaeCBounYMnAoVLSRrlcYF3EbmKKoLY9QITGRHy/VEKoWlUsfM+hp9V
#QxwMOaeG/CqGJNWQn3JpBIJq+F/j8I/h5V01/G9AeGCQDuD7J9syiQmyavICr/Hyb3z+i1989tSFRGb8gljoxNY9Zf0tBNmWMmZt
#ek68xvE0MvrruKh7JoJyr4NjOnY6jfKo0TXrv8BKPvFG7u/iu4WtVTL8D9QhxC4/+YEX+g8xKaJ+NfCfQKBvOM+OwSCNqSEvQQgB
#iDcg1ywNAsfp+dKZxIUzCpnMMJl8I0gmY0urvE5+D/6AU4n9XzHiSWK45lCkgKGLNQGC/8cRIWuIz/8O77gen4576XGNrccpncCj
#mbPxHuL2DODTK4TlH2fpTF4Mrxsx4dl/4J9toCFYnzKTSZrJ8/p3kBCMf6DbiLHOiskE0pWYGplIjOeT44n86OXJsRcnR154WtAd
#B5v4HT/Tex2b2aVmYoz+LFJIwDGTw8AK8CKdi2evvMA8yFkllX4B+Yuz1vyY5C9gxJAEMld1lpmMaCi7MYYAhYlVGFiNAgwEqEQQ
#oMbVgA/GAiC3CwG+Ra4RDAroiveg72OWg2EKnNnH2LxHMWLdJ/3AJhj2X4csLwmGnXoD/Lrgy6+9MC4eXoSKPpXrx+PXiW7fib1S
#Y1BE+W4OYRDgDTiPHpLTHPK1sfjJFP0+f5Kl3x9ysH6RuDl600+oUCwD2EDk67GMH2EZJVHGDP2OnszS79jJnChzmsvkZPolLhPf
#9B+LMhMxyBN7FuWEX2Fa03sO4j985fhjALt44uQ5T4J54Uysc0UMyOjP9H8ai/j9uH0JmSGUHuP2r2KjnqbHP46Pz3ihz9Ljn8DH
#P0ZF/knM/q/b/wxO2Usf638K5+NPw9ePgfCN2X8Ggy+b/ywGPEVSMvKt112+9c/iwkkIWeb1BMsyryRYlrniY2AV6gTyreBa4WGC
#HgRbC/ST1j/ytRMkACNfDpQVdTIXxKKV/J/H9AlpUJH+kN88j/wmCYCvTbwjxPYr1OmfYKdzNrQ28eMUawM4bH2Uu5AcpS5c/nyE
#Za+x2M8FHlOI4ugPL0dIHKM9rEMhiaM9ZMyCBHG092Ig1KHQlwKhv0qhLwdCZ89g6LcCoXco9FcCoT+lEr4dCF2jtJqPurjDoKyV
#C8paWRRwflPA9Q2Gaw7Wn2O4XnTXilsajl8R8P9FwvNQ+hiJd/qfi7lSDzHQOs78CyIFyrawDNKYkCTDxMWRV25+i1HiiCJgjShi
#2YiSOSigjSgC2ojVPOPl//NqfmxEVIafehk8SS5xMf7KxIvcprjSprjSpviANsWVKuLWP3SriCvCojcpck4uKXNyS8zJbTEnSzwn
#HKw/z3Nyy8NfKLukYS6eo7nIsrCByO98IjMDKytPKwu/n4qfvfIBvZ995bkb/yXKe4TE4z8sIID/c1Dc9d/GJZHIrI1zYO/XcDHy
#41/AjmWwuz9FPuniqP4XESm8Eb98LUlYNn7upEjFEa4djeuwmiZ//muoL+lhxNPxH+LP58/Dkng5/rzIBeX8C7iiuS0Xx8x/Ed9+
#vvKLX/zi0plx62YCaJzXFqueQILDDP9fikmG/+XPXryUiL/yObeDGnAhof86xH92yR+s/2WxHlDWiAHm/9P/dWwyTeLoM7F/9P+x
#rDDLaUf1v8KJka+ZA77meRrjaR7jGRrjK7Nvx/XfgGTjnsrplSnzr+K49ZBukFhi/0u4RuM9JCD6X8N+fAz9sP9lhInfxFmfR1En
#kTlIXFngAcMA81/BlD+BlOOKWPIzZE7O06xSon8VC/nrSJRh9PR/DedkieYE2xm/MHZSps4TsWLl5eTPWyNYB0Zcgqgyzcq35KwQ
#dRvT/w2cZZjT69S0K7k78R4+mn8D6/s38eunxAlcPMOAsBS/4lZ65mTBq5Q1RpM//yfUMYwA9uGHC35QoErPECiIev4mPGr/NzR0
#6qIa8hcgZLr08hUb1+ilxMWE9ZsJucoSSkJmrBK07ux/C74+feqz9xOXpy5xmsx5kZa4Rw6fF+HzbjjwnQA91KfnaI7g57rbswvj
#+m8hiKUGJTqr/9sERMhnIz/9j+HvP4e//xj68YLUTcMfiHKxTyHsv1PCY8yXxP4XCPs/4A+QbEzAZ4ng89+R8Dka+z2Iv0zweYPh
#8ybjgOm4fQM5iTcIYvB7/GTCfX7uRHefrd+CgTxJMyS+M074zXpmHKCvh0o2b+0ToP1FD9BuCEB7kzq9KADtRZzz1wnQ3hSA9qZ/
#zm8woOGcXzzz+fO4CXHhjP7vxpBPN/89Ob15aAEgiX8fyfi34eE/gIcXp5/jNsP7f4jrB3sxeV3JVcZc45zrVZF2nNKi9ooDiBZR
#hz97BiDgnKKV0C6dFQNwdxyF3ZCGgUv4PLEoGRT9txEUtEvnEBhuMBS84Q7IhXOMjV6KjJVIScLIfwZ/wBnH5kZ4/uVnGWEFwt4a
#4S2ktNi2wTSfwNM/pYTPctEKDhuNlSD+CsHIEsPIbYaRJVjePxjvoTZER6bd/I9wDoBo/S0Pw2OO+NmTO9RookbxuP4SzvH/Suv6
#DlGYH96hKb6BwuPzIheU8ztQDuKQZa7EsgiqMj6ocinKDUIkS0xRlr36gKIA2zT5mRPvLTM5WfbD05JCTmAmxkRlf3Wc5JbgDALJ
#OIOzseTWAMDnkQwvmGeH6cVhzPwHMU3Si/9nfETSi1vqWN/aeOfWiNhRQ0HlsJTL56bz0wVktIHTxk32eSDYV0Ha+Ovw+5vAAFzd
#cCw0DMYUdwCc/zYg+6sPN2Jjed6/vPrWwxUY3Nhz8P7rIBtevdVEJZzEHyPvX/nZ+XOoNfv9kWlEBFj7ActGBDdvMVwgnx/7HcQ1
#MYIFgjeEH8Q5uH+J3cS8UAUp4V6mGuaS3JtE7NLZ33kmEfsRff9Pib/y9LOx//4ZDL83/t65RMw4u38+EftPxvH7R/T9G/Q9TeEj
#9Pz3xzHvKpXwfyZ+55lk7P9v71mg4yquu/Pe7tu3bz/aXWFjO5iuwMI22LJk2dgGY5D1wQqWLFuSDSSwXq2epcWr3WU/thUHsgqf
#1IDTusQ94ZeD8yNOSggtpSHHpJg4ofSQpm5wCtSc2A0FXEKom+YAJYHee2fe7urj0Pb0c06rZ+999965c+fOnZk7896uZmq8BcOA
#pxAPwizPWp8Fdb6ZNRYctwqGBe9BwYjAifAcfxAioeO+mfCM2KUZ8A7qmQOnIBoxMPo9ZFlw2n8whJox1YIjftLZH37IMmBfmFLf
#8z0cMOCzfirxcJg0Zxl6/AQPREj+r4Ekm5k/ZhHnkO8hayZcyyUmDdK2lO2fZ91cY4BP3Ix2fpTt/J6X4L0Mr68hS/5EkPwg51rG
#tfNEjvuC8Eb4OPphjSDOghDhW/ykc5vnXrRwduDPghHY757jNyAiCD+I+C3wSy99c32RoHbJuqmUH4UKRo14zYVPmuLJCPFfDa7X
#zoVD7mbM+3dAfniB/bAt8AFa+4ybLDnuJRjHep0Hu/2rsNV2CsKP1KzCDrTSTfKfYZnfID8IHQGy8Fn2zC9D+7G+e2up9H8KEswx
#fiPjdey33ey397lFLve3hFBnYD167zvWQ1YMPkFf7sEPLdJ8h2+tLwLncE0bvW9GIrAtMscfgQLDPwxtC0XgDoQXwBb37eEgBN3H
#fdwb+Xtzwf9C8IE507qsTL1mzbTo9fFZoIsQXI8jaxSHw3K4BamERlQdPpvrdSEoMHUeUZiGCz6k6uESpvYztQBWM9XG1EWwhika
#OUdhMVzBFH2rfBSaYS1Tj2hErcYcRD3NVAt0oGXzXV92CziuP4Qw4Po6wqcl1Ilvux5GeAXL3M7wq5z6K/1b7iao9z+G8HXft911
#cJl+CGFj4AjC2WHC7zd/iJKPeEnzbtb/aORFhG/6CL7tP+42YI91AuFM4+sIb7W+jPC7NQRHGIbDBD/tJrg6RPBzBsGL9RcRrok8
#5J4JT1s/c18MzdqbiEe0nyEUcBpTCzWArb2iljT/Hpcy6iZ8b4DgkHAZ42UeYc1pv6n4Au4VVN/XRQDxp2GGUZGZW8570kt5SYOA
#L4p6lPyluJDllyD8I1GdS2p2If8bsGqSTpl6GfNbVN4emjThB+bb1l4h4GpF6T7qUXGmbjfP1euFBklFXahvMTTIKSpu9QsdPqGo
#tBUCHW5R1OrafuGCOxV1ZW0Il1efU9Q/anuFG+5X1Ns4tbvhK4o6P/hxtPRhRa0IbkXqcUX9MrBXeOC7ivIFBXjgGUVdFdwrTPiR
#oq7HNBNeUNQMtMULJxQ1D23xws8lNauEkceCdXWy7j929wsLNiiqxkfUZkX1B4i6TlE/4LRBpl71njJtjAApRf2LeQNSRUmJdv0G
#wwclmQ9nyy2GH+htMFG1SAVgNVP7IFCbNYKwWVHPYDwJwu8yNQbb3J8wauD1eZJqrr3FCMPV9ZJKhO8wauH3FfW5yB8aM+Br9VLL
#hf4vGmfDWRdI6gv6G9rZULpASn4bYyCmzZeUbn0VJRctkJK+moeN2fDtBTLNi1FxDryjqJoAUR9fJKnPeol6rkFSP/F+Xp8DoSWS
#ej/yuDEHBhX1z74QzrNfXVLx/Fz4B6b2zbo9cNiYC6FGKRmF7yPVr6jPwFHjd+B6Rd0lXjbqYEhRLwkDzoeSolxaCKlnGislzIOX
#GislzINXx6X9gqlb4BztFKa5miTlw/m5Ht5sqkheAO+otGvh8/oFcOnS6rS2pTLtj4GoTzdXp93VLNNu4Hx/zdRJ8UqE0uYtl9SV
#xjKkli2vpM2HIysqafPh+RWVtAXw+qpK2gJ4Z1UlbSH0XVpJo3WPgL8x//Mw6iXo1SuwyU/w8gCtoGb4HY4G70YIf80k/LR3Ii5l
#OiKgLoGRjTgragn/tvXb8lbjOY211Tp8AVuMyVAHGtPHsB2P4Tr0GK4Fj+GILwUEhIFaZTZCC71TCoSgieEqhi0MOxluZHgNwzjn
#TSKcgc8nBMdYzx5O3cepxJ8DhxHOh7goBRbDQW6Rg9wSLwqSH+VcQisFOuAe+CfXepytJf6I/3ocGYTPY7iI4TKGdUr+ff8jsJDx
#Ju3F0NM42xK+Sksbx3DezQV+Dagv4hed2hVaWPTBF6y5YqP2SqReXKPdi1E0roVrF4oka/g45l0p7oFf+NcgvMW/ASFFuzGt2XeN
#eBHacby/C0btsHgXjgVGxB5tsPZGhN/A2eAU3IE6O7UhbTdCv9Ev9mmvevdiiT8w9wkv1vRehAtxNvCK2/RHEHb4+8Ug132QrbpH
#2+3tFwe0n5rfECmuRVK87fuBeFT7ifWSoFwheFT7jvESltUZDsFs8Wf6q6j/BfMN0aT9wv2eWKX9cTigPaH9JlinHdbmu3eLAteo
#AA+G/eKwtl9fqX2SOZ9kzq2wEddat7KFt7INz2rftDZop+D+YJ92VHs/dK32ovadmpUIkwwDYYI3u1eizO8bBPcFVmp3sZ8/x34+
#qRH/fixlrugUe9zkh7Xhu7Uvc037YFPtG2j/fO9zWh/st44if46+UpzW3nO9oJ3WHjf7xf3YU36KGp4XP9Pe1f7e/RrCV0JvaNRS
#Ef1WuKxmlv5HqpU/Hl6qr9L+InK1/hiXeAi+aa4UWFZkrzgqvmbcph8VT0fuRBi1Pq8fga8ZX0dInCMQtZ7Qx7Ss9xr0Idl2K8ND
#DO9heJBhWH8t8Ix+EF6I/JX+KHMehS/4jumj7P/TzGnSjmm/1h/VXnK9hDYErXrXY1yLx7gWz0F9oNn1PGzHfnJU9OltiD+H/j8E
#XzLrXeSfa11HxRO+AYQ/CRtwlEdHnf6jyGcw9aeuva53sf/8gWuhfqF2r6tJLwUeRM61kYMIbw59y9Wpz9Efdx2Eu7VDruNc1itc
#1hGgsl7hsk6J7sgp1yr9Ae0t1ymxzq27OwWN0yNA5R6Bn4RXojyV+6j4orHc/ah4O3y5+wlxc207QnB3I7wV++e72keMPndS1Aey
#7pOCSjkpnkObo5CHxzx1DOvhTugw5sPH4J/NhbAb3jMbMOrUeBqgFp/oGvApcgXC8+EKhBdBCWEz/B7CS+F+hK1wEOFVzO9FeAXr
#bGHYCgl41mzFZ9mNRjvDTtQf9G7l1DjDBMskODWBc8zfmTbjSZT8iLfEMmMMb0HJjcZtnLoHUxd6H2T+AYZfYvgVTj2Iqcu9TzHn
#MMPvMXwW+a3eE4yfZPgzhqeQf7UXBOGCoc7QK3bDjd4o43UMz2e4EPm3ea9gvIVhK8OtDBMMSwwfZPgUwxMMXxHb4QkPaFyWdjcc
#NIV2Jxwyo8y5guEBjWROInzWBJ04UYbz9LvhFfMpPYGpdS6qaQvDOMMxhgcYHmZ4wkUeE27C6xi2MNzqvg/+3BNnvIT4G54xxk8y
#BINLZFhnkIV1xp3wI/MK5rQY1Fu2Ml4ySH+J8TGDS2d4mOFJhuBhGzyERxmvY7zFw3o8VJetnvtgthlnzmFOPcH8E8iPmyeZI0xK
#jZp/Qn5mGDeJ/yDjBzj1BOOXQkKUxPPY00+L+Vq7tlXbq92jvaWV9C/o39OP66/pp3XN5XclXV73x9wazrY6vy25yPevOPc26O8j
#zFmaB+CqWoLvacS/NGggXhMkfIDhAk79WzfBWh/BawIE/5Lx2V7LI3ULnPl1/rgRdyGk3257EEfnIO7BeZ1W+l7EvTjyBFrjQ9yH
#c77AuT+AeABqgH6/WoN4Da4A6Gk5jHgYx6iACEL67dUMWs/galjDp+bZCM/GsavBLFyhCqTnot4Srhgs+DSOYx9G0IUIb0fcD7+L
#uB/uQDwAdyEegM8iHoV+HB+fxtXBg/Ac/Au4xUyxRHxZPCnmaE3aZVpRu1m7XXtKm6en9aL+JX2R6zLXX7p+7HKVJv4mfaYFzs/C
#+NrjrjfkGgpgZ1l0Pb8bqJb7A/XWYHzeOf7JvA9qJvOikcm85kl573MfmyLvOua5uNVoLaZjO+nYSjq2EfUXHX2no8886CsvrIAR
#/HwSP3fi5178HMTI+Dh+DmFsfAs+BQ+KPfCY+BS8LO4Dj/YAfu6DjPYmdOlvMf8G/V24W/8AHsP7z/HjcS0UG1xd4jh+3kH8QvdC
#sQM/N9NLwNVrVsViyxpjjbC6I5lO5oe7aGu2NQMOc30mPkjU0uVErUnEYm3JPJ3X1kr7TSxdNRW3mbkb0lfahdbMoE3Zke5LJrZ3
#0rneiu5IFfPDawaxoKZxxTRNWQxxV8boNk4vsYt06yimE1uboLuY4m14Ee1sTxdH7JyiWjPpRDGXs9OFjXQmCqX38F9AYcK25BDS
#ffH8dry15EfTCcK7eMvptcVkatDOYcKV8RG7fQcqUJsjqCwtO+PJAlNOgYUMUeuT+QIxC/YIlt47j81PZRLxVB656ULzUljda6cH
#N8V3shOWjnMCUuk1y2N0z9k3KoxqulTWdCnwFkZ9xSzWbim0JXkPpHhuFAkqcry2ZlhNp2uRmmZSmJdYP5px8bJxkstkh0Bs+Tj+
#chiyC7H+vo6VJACruzKDxZS9hrm9tC9ZZxu6uEh/r09vsLfbvcPxXLahpacT5TewWGd+3fq+zRCj5oXe0Twa1NCaSaXk9k35hitt
#7BtJTEKncCPAJjuOmHwjLjmrJ/SqNYPIGt+xkIUSPXyiYEcuMyKtG5SW8uZISOSrCaomDGcKm2zaIgL603xrGZR52uVWDJzFwT/K
#Zz5DTJ79DBtUJ+qhvXIwJ/WIfj4egFJoE/mCPah8UKFjOTvLpzRDC5+k1pHJjdDmeFKyj04c3sTnLXJdnPzY7EmJ9+fRXYPUiWQ9
#1myPxdbGE9vRWR1JO4UpytzJCdLcyXw+aaY/l5qcojbXmErVIG2Rn6KtFXrlgfOThXrVRpJnFOhKpjnuyApPUcpwvNCTs7cld01O
#a8kmr7JHJ/GvRJugL5ccaU9TC3XFs4Rgq2ILjOAIBgx30pE8kq4i6qP5TLpC0XZnMgiw2BY+BL0HnY6M1vZ0IVkY7VSHFKhxQGeV
#kEM4axVZ7rSwLpPZ3kUI7eDGudr43ElGu+QxNJx7k9oIaTyPtxxzWJX4Bp0ULTO8ZYzUxMOzGyOWJONZxqnKLakU256082tH22za
#vcLOlSXluGGy295V4NM2nMG6CYd3EslOHotUPbsrnhjGIYBjtjCOzlcTMlKNZm3YMmzn7DPECYwFOeVHOkcTZI1s4EEFrXzCGoaO
#pliMlaMuDGlAwymJwZiDB53B1lJAtQNFTGqzB4pDQ+SSCs+ZHiqclnzeHhlIjfbRRvkVNvWEnlwma+cKo+SN6gwTKl9J6uMNR9hn
#tEXRRFPs3Lrk4KCdnlx4B1ZBjbDJiZ3pbRwZKL6nziglh3Qxx3KV5E32tl6MQ4XRTdgf8lWm0sTRnrJHcD6j+lUlSZfG5Z56qfgu
#xvKTS0T3DBYThcnOVVv6TGXjSDaeHq2yTvYo5heSA8kUDqlKqjy9DMcwdlOJtqflXY42mha4b5EIDjCJ82kbWO+RzA7ql7kkBsxP
#yCzSRxzJFVr+m2dF0wld1csCHKZ846GBxaEFOHAJ6UrSBrGZbYWG9l0FO807ODaszwwNUeL4AdOgGo1SUALjCKN9GVkFmq4UVrUC
#A15qtOa3JNMclSUzpuIk9NK2NVWCa20suNveKVm8tALEh4E25GLz5c5nkAQV/1rjqdQABkx0HsMko6M9tr294hY5FeEqR81R62mp
#E0/B+L8VvyqJgM2Q4UNtytiB/UF6Tk0r7Pky0dqHEzO0tvbynadp4C1O5UyHDmR5RqRDpTUo0V0cgbU46djxNKxuXBOLrStilYAO
#euvFHgZX5mw7XdWYFXsVzWFftgoX4uCV2OlwuuR2UzjJOBxswqoh6bR1Hx14S1GjwelzMrklUS2Fw1Gtd2RUrKx/OOJ0DqUx9KH7
#BpMFx7Q2eUbRxCSMuOVtparMxoDO+5pNZRnE6NhM6n408Jx+QHWprG2ZopP2nNzddqGB5h5cssoJ0ElAb95Iq+rN8Vy5K7dgt8JG
#yZ1hEY3huxCLDSiik0YL3rlzStSpK00P2UyK4rlUrJbcOKyHcFlt56rX4dSFyv2O9uhjnmz8CVyc/amP5CBW4JujjtbqNIFAeSlZ
#vbSnAeqgMRz0dJeLLpAHV3PblUNNrqo5Wnh78OonA1JWRTUkJOSbnVN5N/fkHTe3JePY8vlCMpE/08Qpi8o3qAbNY3P0p5O7eDTI
#BRfwQljhMhJOWrWpsDiZz8F2/AJOrp8n8Njyces4FpvAmqKxYnKMcBzCtibXJhO2VHiGpAkB1lkFlNPlhEunbNJBtdBfoKkFVzxU
#PPV1ng25gApFgYWXHmd0NK1QGsrzU76yeMxXj5aeHB3tkdxBKqmXdaTiQ1K2jY8kx1GwLBYrDCfLufoqO5dhr/vQdqbaSIUUePMg
#B09lGvqtc1NDy0C+kJPHj+WneAyb0JfVQWvMbcskirRecHhdO7If3id34PJtYixpWCe3teQ6ODglVOPOIZmK9SHlsKfz4AzkfOUZ
#UHXM+C6HpGcJrHCmnIKdk9ZzqsPJ4+GBd9VvKeCTO674ue+yTIw4lSxEZtKJeAGw1dOFvgwphw18KhnGCHIqLv5xKZuQU2L1LFnF
#rfgH2jDoUWU28Hkv4CxrNuRUbMQ1Qi5fqJD0QIHPCoSirMJ6yxh5spUPe+QmVCs+rummTKbg0NXNKwOEfFcy1XN65U0KVprPtAd1
#tr2zyKKdVp1VFuMyiDsU26RwmaOosM782gw5zPF3TjmsipZHB0icn+ok2pehpperDYyWXLo69xW6cCVIDzPVEyLwPhzq/Yt8nC4k
#ujM7cdG0SxpVfuKUNamQvfFRoA3mZXfhh08WUSjVLJ5M5wnHB63cKGSysc409uY4LW/lzCSfHtW61XnOGBeceujoNABYPAxoLGTh
#EliC/5pgKayABmhUnybkE2c5Uo30ErTmY9ANNuyCIuThOoDaCrUeF39p+jWgr6mcG+Z3Qzv04Kcb+qAT/0WxlCi0Qi/qreSF0p+3
#Qgazp5GVQIPyKFSAYaToCyAbcrCDIXEzVWkTFUVhJ+IDeM9CnLWlsApRqIMhxAuoOwODnDOF2BCbvIipJJdA+VKYc5RLy3MalY+T
#DUqQhZI3gjKkbZjTGgDOTrBMbEI50H8l01GUJ905LofyjrchWmXZNsRyVXWcXCOIT3Z7FHbDZrhJaY2zrkGkFlTlI5l+lFk0yatJ
#lt2N3rwJFlJ9Yn1nLJ2kydNpLKegNNG9iDJR9pG0XUqNL2eUZVH/7B7UZEOc06mUOMqTFmiPcr4B5EtP2Oy9PNaRajpU5aG4smFY
#aXd8iPprq8uNcf3Al2e/x+nPTb1pvmML6Vjm7IRqO8nLYV1S3LL0V4CU4uSLcctT3iGWg48UUHeC/b+N65Biv1OfA2+5NN92TkmR
#xsAgc8lqpGriqm/ludeTjQlVa/BmVY0hcAPykux/rEd4GCmSL9fBQ1Zl1X0XSpBsrKqXQoA8nEMOtRLUVEqhukG4mqbxB262pmb8
#aABPUXpSXwyihiwgnQVplc/GMmWvo9KSajSjjwI51F3kVNRx/hK2NYmBgLQX1QhYUm3tp7rKOPmV0slDw6pPyz62G7pY003s7T7m
#9PEIWMx4q6Lovog53UyPr1OUa53l2suaNICYO3l8XaJKvIlbMM7WDnErjWAvy1LN5mZZF/W8NOqKcR1iIP0C9VG4hv2QO8PI5z6z
#JcpjlmJESo3KJgymFHFIusg2yhhEXkhhPWhUkV7SFGeNZIFdNQoXAvRGMQinObcc74VxY7Uy0vOcRmMoynHVGbnk/bgajUk5husT
#XG6KrXSiwSDHiGQ5H7i5XnXUUllOSbBfZDRdAjegZsKg9mpstxbuGYvhKsw9CsK3DtuuDycQ1BB3IlJ1JJrKggGWyvEoS6g+08A9
#JMfeivM4l75PqVico/rUnalnlqO5t4z5KE+Oew1cVIndVOqNmNPm8TlFTFh4pjLyPJqz7GeqB5w/kTOFNp95510P/HhL+4Glc3c/
#+dZ13wVXVAgTI5pwIxIOExkk4CZ6rtuYEdkoIiYTQQNhpPSwvB2zPNqMyI0iUowU3VFNnDPLjOoiGIyMCXNGZMyNIk8GG4UmmDgX
#wmNet0VMJ3Uvk3sd8jCThx1yP5P7HfL7TH7faBQCdRExFmY4wwswI1I6iHagbOmHWqSozQ4JNG2sDiXLN0w5FzQXZil6mInyUaAK
#1IIh6+GKQi36A0I+ZFyn+SwPVqsWagW6R3OD5vf7zRnh0j0iXHqWHFILoageGfFHxpZX2BAZW4XyQS/oaN2q4NxzXB4Rpn28wjch
#3/KCpkXG2vE/laT5PUbknEgxaFnh0m2YbppRTUPFtYJ8apq6JSy2JniOibUKnguRa0xLKA5WpB/d8qcBIOhQbiywdJtm6JhZx9K5
#ZtRIAjV7sdXIWE3zhYRQ7gmyK6/zh0TFZYYU4xrFnVymKdkmGW962E2RkNfjioRMK1J6gNhuzpIkWHog6HGZJru3dAD/cyseMGUD
#lA54VAoqTWqmiYZHSl9BTweDwQs8/sg8blhZ1yCpIcTpc6Zpon5flQgV7sXOWUtNih4ZGw3qRi3gR+gAQfyY53m8mM+syjReKfoN
#i0cJH/WNsds0av6A7FchKTonpKnOJcZ3rnOFZZWlwuxcLKXsT2wMk+sZDFozIraQKHUO2vksXDrlob4dOhewjyKLvPenlLqIPP6u
#CFI/J6SWBRZ5ycDSE0jqHuwiIMJjeywamXiXt72WRzj9khQ1Ur5Gy6NzNbmmWGcfJS2jpGWzPB4zwl38pAhK87A58D/q00I8TLDA
#IJVMIrXcRVDUatQ0MjzEHpC88AIPuIJ0yWjxlbkebC8/KvwVCzj3INrBbY5dZh/GnaBOgw7xILP2c0zBu1Qz9gD3rQM0NoLBQFSw
#RagrUvqN6eCmU4BfGYNoeBFnfMBUXgtWDKWU8NjBqMcycSSWXgyXXnYs+wfE8b90QiVHI45hFCQBylt6mcZsMIQIq3oYGwNNXX6W
#xzAj88Kl0zKb1MIZTnssDWF4WUXnMvNbl8c+FT5mXWI+t7v2gx8ufnmj+fAToysXvvzNrZphaoamGUHN8OtGxMRPP36u8agwZRpq
#HFLccjqWZlgoM6IZPq/hxEVkzAoa43ozskjnOS6DeqDqnx7VsB7V9VwG+pfAr7yG41HMFMXPPMp42hKg/vYF3PyTF5pBNAxnfkL8
#FH54CkHbASzsdxpFX42GXGnMYCToi6JP9uCEECntc/D9iGMOTYpoJg0BChRWVJPNGKRRLRzxJ6uyHq7Cv484Rb9I0YqqYR8J6QvA
#xI+GnyB+/K4FaKQp1G6Z59IfWfRpM7fk4tnuTLr8artvOJfZmRemqjBcLmB2Q3d7H72Ka8lmF6mX8pftaGpsaEQNwbPKX7+pH5DQ
#t1teyhIlkaAAb+XbDfAL8GyyU3acdp4ioomPKKANOQS4myTqIhe72YKLBFxQ+e5jwrcKF437SQssFrDgt8iO/+0H/THn2t8iPdUP
#by6a4tcQ/1E9zVLPpJ9QQER63EXfH7n4dQf5x8WdTsh+h9AneNcf5mAb/QW3UUBmFQUtUWA2/+6KNAbkt2rONynscec3FZTNLH85
#RJoN9UaFU8q/1oCzBNRMfPcMswTUTvXyGqcTCE54BQ01AqyqFzrO9VDdQ8+B6Ooh4+lvJQeL+NlS+SUXdYNakH9/fRDTDlal0RUa
#T8Km3rbe0RNnr3r9ke1tn/2dH6/7eeGqjaRjSWEku2TbwJLu9UsyAzcsUf1vSdouUA+t2oc5OzgAvetali6/GJSevqDSg7auH3lp
#eJU9/JuZz99+v/VOsVJuxNkzd4rL2fdVXjEcRm2pVFc8mYaRPL37tsubP39QjzomVmn6+j95CW7oWc4uy1V86q+NU/Dpor2Dr8aU
#p6r2L35KW4ZwM/TiY/VmHEWbEOuEDfigGsN7N3TIXZfhSddb70s9YpzOyxVFgWbCtsj895cCtdJDbod6zOrERzB62UTXPM5FD5Fx
#fg2YqnqMlde3XFH+i5le5OfUq5vJmn4tSKax/G8ZPrDSH0YtAwv59Bp0RD3ijmKN1AsevKZ40wqrOY9TRhs/dia47Ow426bK24hz
#YyXvZvU6pJKnqeo9cCOXFUT5zvJLhDS/oqhYOLmMBnxMTfHfoePEjHnXo8QQ56JaZrF+ZOkQ0DtoGVLauIwNip9UZTg2pv9dZUk/
#9vDD+SDK0OusD/NjIz1hTMgz0SNNVb5Yyb5r4Vd3NmoeUC9izpxH5vt/c2XlngTzLv7fNmT6+t+4pjj/QTL4RLr/mjI+7PyXFcsm
#nf/Q3Dx9/sv/yLXbikbPo5PG6HzTch84bxGx1UFAlNIkDxgkrjzpnsXbe9q7+zo7o0uirb1LObMUGaz8+Ijk1M/A8lE6+GzUOey6
#kOHjDp2c0Z32QJRPQrskms0ld8QLVYdk85Hni6Kp5A46H5G/vl/ESOXQZDp3cBv/bM4ejPJ3w3a+Ier8GhJ5WSxTFT0wykWn4sU0
#iuUapNUJ9bMZNPljfMza7opnlCF07OOEyuFzVzRetjiTthfTL1GkxfIgcDrVm4orVzC6AB9ZdqZRODVKbhjNFPlIVXwSWdhARRTp
#Z72kvK6q3HgqiU8HbN110ZvQwOuU1VRDZlfajwfveddZN33oyT4NSza3b+rt3ND939jH/uPnPzWuWNE4Pf7/Jy4a2Eunz3+avqav
#6Wv6mr6mr+lr+pq+pq/pa/qavqav6Wv6mr6mr+lr+vo/d/0bdaECsAC4AQA=
#__NEXUS_PAYLOAD_END__