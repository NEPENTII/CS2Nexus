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

# ---- AstraSkins runtime requirements (the two things that made skins silently do nothing) ----
#  1) addons/counterstrikesharp/gamedata/astra_skins.json  (signature of CAttributeList::SetOrAddAttributeValueByName)
#  2) core.json "FollowCS2ServerGuidelines": false  (otherwise CounterStrikeSharp blocks writing item attributes, no error)
ASTRA_GAMEDATA_URL="https://raw.githubusercontent.com/Ayrton09/AstraSkins/main/gamedata/astra_skins.json"
astra_gamedata_default() {
    cat <<'JSON'
{
  "AstraSkins_CAttributeList_SetOrAddAttributeValueByName": {
    "signatures": {
      "library": "server",
      "windows": "48 89 4C 24 ? 53 41 55 41 56",
      "linux": "55 48 89 E5 41 57 41 56 41 55 49 89 FD 41 54 53 48 89 F3 48 83 EC ? F3 0F 11 85"
    }
  }
}
JSON
}
# <refresh 0|1>: with 1 the file is re-downloaded (needed after a CS2 update that moved the signature)
astra_runtime_server() {
    local refresh=${1:-0} base gdir gf cf tmp rel src fetched=0
    ((SHARED_OK)) || return 0
    ((DRY_RUN)) && return 0
    rel=$(astra_rel); [[ -n $rel ]] || return 0
    safe_server_path "$S_PATH" "$S_SLUG" || return 0
    base="$S_PATH/$CSGOREL"
    [[ -d $base && ! -L $base ]] || return 0
    gdir="$base/addons/counterstrikesharp/gamedata"; gf="$gdir/astra_skins.json"
    cf="$base/addons/counterstrikesharp/configs/core.json"
    # 1) gamedata
    if [[ ! -s $gf ]] || ((refresh)); then
        ensure_chain "$base" "$gdir" || { warn "$S_NAME: cannot create $gdir"; return 0; }
        tmp=$(mktemp) || return 0
        src=$(plugin_src_path "$rel")
        if ((refresh)) && curl -fsSL -m 30 -o "$tmp" "$ASTRA_GAMEDATA_URL" 2>/dev/null && jq -e 'has("AstraSkins_CAttributeList_SetOrAddAttributeValueByName")' "$tmp" >/dev/null 2>&1; then fetched=1
        elif [[ -s $src/gamedata/astra_skins.json ]] && jq -e . "$src/gamedata/astra_skins.json" >/dev/null 2>&1; then cp -- "$src/gamedata/astra_skins.json" "$tmp"
        else astra_gamedata_default >"$tmp"; fi
        if install -m 644 -o "$CS2_USER" -g "$CS2_GROUP" -- "$tmp" "$gf"; then
            ok "$S_NAME: AstraSkins gamedata $( ((fetched)) && echo updated from GitHub || echo installed )."
            ASTRA_NEEDS_RESTART=1
        else warn "$S_NAME: could not write $gf"; fi
        rm -f -- "$tmp"
    fi
    # 2) core.json
    if [[ -f $cf ]]; then
        if jq -e '.FollowCS2ServerGuidelines == true' "$cf" >/dev/null 2>&1; then
            tmp=$(mktemp) || return 0
            if jq '.FollowCS2ServerGuidelines = false' "$cf" >"$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1 \
               && cat -- "$tmp" >"$cf"; then
                ok "$S_NAME: core.json FollowCS2ServerGuidelines set to false (required by AstraSkins)."
                warn "Note: this CounterStrikeSharp setting lets plugins change item attributes (skins); Valve's server guidelines forbid that on public servers (GSLT risk)."
                ASTRA_NEEDS_RESTART=1
            else warn "$S_NAME: could not update $cf"; fi
            rm -f -- "$tmp"
        fi
    else
        info "$S_NAME: core.json does not exist yet (start the server once); it is fixed on the next sync."
    fi
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
    astra_runtime_server
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
readonly PANEL_VERSION="1.1.3"
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
    if [[ $(panel_get nginx) == true ]]; then
        [[ $(panel_get nginx_ssl) == true ]] && scheme=https
        printf '%s://%s' "$scheme" "$(panel_host)"; return
    fi
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

# ---- nginx in front of the panel: http://domain (port 80) / https://domain (443) with no :8080 ----
panel_nginx_setup() {
    local d p conf=/etc/nginx/conf.d/cs2nexus-panel.conf
    d=$(panel_get domain)
    [[ -n $d ]] || { err "Set the domain first (option 1)."; return 1; }
    if ! command -v nginx >/dev/null 2>&1; then
        confirm_yn "nginx is not installed. Install it now (apt)? [Y/n]: " y || return 1
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >/dev/null 2>&1 || { err "Could not install nginx."; return 1; }
    fi
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$' && ! ss -ltnpH 2>/dev/null | grep -E '[:.]80[[:space:]]' | grep -q nginx; then
        err "Port 80 is used by another program (not nginx). Stop it first, then retry."; return 1
    fi
    p=$(panel_get port)
    if [[ $p == 80 || $p == 443 || -z $p ]]; then p=8080; panel_set port 8080; fi
    cat >"$conf" <<'NGX'
# CS2Nexus web panel (managed by the launcher)
server {
    listen 80;
@V6@    server_name @DOMAIN@;
    client_max_body_size 2m;
    location / {
        proxy_pass http://127.0.0.1:@PORT@;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
}
NGX
    if [[ -e /proc/net/if_inet6 ]]; then sed -i 's/^@V6@/    listen [::]:80;\n/' "$conf"; else sed -i 's/^@V6@//' "$conf"; fi
    sed -i "s/@DOMAIN@/$d/; s/@PORT@/$p/" "$conf"
    if ! nginx -t >/dev/null 2>&1; then
        err "nginx rejected the configuration:"; nginx -t 2>&1 | sed 's/^/    /'; rm -f -- "$conf"; return 1
    fi
    # the panel now only listens locally and trusts nginx's headers; TLS (if any) is handled by nginx
    panel_set bind '"127.0.0.1"'; panel_set trust_proxy true; panel_set tls_cert '""'; panel_set tls_key '""'
    panel_set nginx true; panel_set nginx_ssl false
    systemctl enable --now nginx >/dev/null 2>&1; systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx
    panel_running && systemctl restart "$PANEL_UNIT.service"
    panel_firewall_hint 80
    ok "nginx is serving the panel. Open: $(panel_url)"
    info "The old address with :$p no longer works from outside (the panel listens on 127.0.0.1 only)."
    info "Next: option 7 gives you free HTTPS."
    return 0
}

panel_nginx_ssl() {
    local d email
    [[ $(panel_get nginx) == true ]] || { err "Set up nginx first (option 6)."; return 1; }
    d=$(panel_get domain)
    read -r -p "Email for Let's Encrypt notices: " email || exit 0; email=$(trim "$email")
    [[ $email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { err "That email looks wrong."; return 1; }
    if ! command -v certbot >/dev/null 2>&1 || ! dpkg -s python3-certbot-nginx >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx >/dev/null 2>&1 || { err "Could not install certbot."; return 1; }
    fi
    panel_firewall_hint 80; panel_firewall_hint 443
    if certbot --nginx -d "$d" --non-interactive --agree-tos -m "$email" --redirect; then
        panel_set nginx_ssl true
        ok "HTTPS is on and renews itself (certbot timer). Open: $(panel_url)"
    else
        err "Let's Encrypt refused. $d must point to this server and ports 80/443 must be reachable from the internet."; return 1
    fi
}

panel_nginx_off() {
    rm -f -- /etc/nginx/conf.d/cs2nexus-panel.conf
    command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
    panel_set nginx false; panel_set nginx_ssl false; panel_set bind '"0.0.0.0"'; panel_set trust_proxy false
    panel_running && systemctl restart "$PANEL_UNIT.service"
    ok "nginx no longer serves the panel. Direct address: $(panel_url)"
    info "If certbot changed the nginx file earlier, that certificate is still in /etc/letsencrypt."
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
        echo "  6) Use nginx: open the site on http://domain (no :port)  [recommended]"
        echo "  7) nginx: get free HTTPS (Let's Encrypt)"
        echo "  8) Turn nginx off (back to the direct port)"
        echo "  9) Back"
        echo
        read -r -p "Select: " c || exit 0
        case "$(trim "$c")" in
            1) read -r -p "Domain (example: play.example.com, empty = remove): " d || exit 0; d=$(trim "${d,,}")
               if [[ -z $d || $d =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]]; then panel_set domain "\"$d\"" && ok "Saved."
                   [[ -n $d ]] && info "Point the DNS A record of $d to this server's IP, then choose option 2 for SSL."
               else err "That is not a valid domain name."; fi; pause ;;
            2) d=$(panel_get domain)
               [[ $(panel_get nginx) == true ]] && { err "nginx is on: use option 7 for HTTPS instead."; pause; continue; }
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
            6) panel_nginx_setup; pause ;;
            7) panel_nginx_ssl; pause ;;
            8) panel_nginx_off; pause ;;
            9|q|Q) return ;;
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
  astra-fix [--refresh]     fix AstraSkins on every server (gamedata file + core.json); --refresh re-downloads the signature
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

cli_astra_fix() {   # [--refresh]
    local refresh=0 id rc=0 a
    for a in "$@"; do case $a in --refresh) refresh=1 ;; *) err "Usage: $SELF astra-fix [--refresh]"; return 2 ;; esac; done
    DRY_RUN=0
    ((SHARED_OK)) || { err "Shared plugins are not set up."; return 1; }
    [[ -n $(astra_rel) ]] || { err "AstraSkins is not registered as a shared plugin. Install it from the Plugin Browser first."; return 1; }
    need_layout || return 1
    while IFS= read -r id; do
        load_server "$id" || continue
        astra_runtime_server "$refresh"
    done < <(jq -r '.[].id' "$DB")
    if ((ASTRA_NEEDS_RESTART)); then warn "Restart the servers so AstraSkins picks this up (e.g. nexus restart ID)."; ASTRA_NEEDS_RESTART=0
    else ok "AstraSkins gamedata and core.json are already correct on every server."; fi
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
        astra-fix) preflight cli; cli_astra_fix "$@" ;;
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
#STbkvbnf87/P//neoN3Tz5w5c2bmzMzKPZ3+639e4C/Qywv9etn/omdvf58AHx9fX59AX5AeGOjl50T4//eH5uRkpS2kmSCczEaj
#paRyX8v/X/on9yRNpv8yDqD19/f/9vX39vILDPh/6/9/4w+vP4CBRav8b6HBP19/78AA//+3/v83/kTrryYztEqjQW4ypP6bfcAF
#DvDzK2b9wVoH2K6/n7evjxPh9W8Oori//5+v/+iucR2qODdwBo9Voju26w5+98D/visP/u1+VVfByam6U3S7NglZcx/Pq5AX/3vd
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
#k5NTeShkl3GK2y4p/OHa1U7wnj46Kq7dz5EpQ//t+3+R/Qd4lA+g/+0uSrb/8PYO8Lez//D19vb7f/Yf/zf+pFIZERZO5DpLrDRF
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
#Bvj5oV/wZ/MbEODr7efk7e8T4OPj6+sT6Ovk5e0b4O/tRHj9u8Nw/GdFn4ognMwAJ0oq97X8/6V/ni2JtvE+cVSWlQYEz0DpiNuD
#pwFqBK2XAVuWRhnQzS78vB8+tRADSMuJ9oDs0gRphl9/1qk94E00pZITLT2dW6tBlocaSDO5zJNeq8sOdmmrIdPMJNEVfl7YJQRl
#ZeJzE2x9/K7S0pDPCqYzSVMIbVYGW806KYudsATtqUSteJhgKx6AimoNHqC6hwF+XFgnzwRnt4+MQJ8atkhd0KuLLP9/MKaA/2xM
#Af+NMQX+Z2MK/J+PKZI064zwW1d6LQEOXMCl0JRKPDi/fzA4BWrOgwbNeSjZ5phR+v1XR/lPUK2kUf4HOPcNo/wnyFfSKL8BC52D
#IWXDHz/xoMExDpgmFWlOC/HwUKQGu3r5eQV4keCF9gYvpBfl7QdffMCL2tvfWwVeIBcY7OpNAurtBV4hTxbsSpFqL3VgCP7eQrBr
#IBmkIGGuEuT5K0mF2h8WDXZV+yhU/j4h8Pvuwa6+asorSB2Cv+ouyFOQKvCm9gf/A29aAyjq5e8V5KWEeYCbArlR/4e9LwFvotoC
#ZhOhiBQVZBOngWoDSZq9abpQ9kWQVSggyCSZpqFJEzLpRiyKsiogoiioqICIPBFFFkV4CIri86Eg4IK4IIoLdWFRnzv/PffOTO4s
#KS3lve/9//+qtMnMnTv3nnv2c+65riy7tTeIXaMRzi9WkJGBr0L8KWQsCxh4pH0haEUD0BfU2U62IprPVKf0iHvClUY+MB2ULU84
#6uOiqJvK6pTiWCgYFywBi9mcnuNhvSV+7BAX/Mgevz4HmVbRIliwSjdR93PQontKAjEMOOiXM7K+qUgskU6IYWSMsD4ofY5Tt7Ks
#EfQ6GHqcJHS5zTkhtNr0u2X5dLB9C+MTECljcUYqMy0mu4MRRoU6wgoLNd4o6wuwQaMf/oLBjxTMSCXs00C/2RhjZoz2dEPU72Ez
#rDarwWJxGuxWg8li0RuwdgtH+yFlM8ucrjcou8rGnditQlcuczpjdAmdZaO+siwGq92BOrPVobMs0pk0rnQIQIojQ0OyuLINLjQy
#s1Ojs8SiJGZuZGMx1lsMDhl3EYSGq1MmknWaFBeJEQInaYEQZFuxpTG0EjiYgYncHSgtRmgSE+AvfSuL8uirUNCkOoWNy+4j3LEY
#iq2GYpuMU5DxATbrc8SFrk6JxBOf3XiziLE8wAc8QS6OhDQmRoQfDB8OBnyMlIWZI9wzEuPWjVEoEPIb+HI/6rCShHow7lSnmJBO
#SF+02hF8pSHgKgg5AkK6LS70MvzLaYY+TeXF8UiYD2DDhPWgYSAGkCN0hHoRkRR9FElBJATY8OmOwjZNiFWh//Q5FcWBGGfEG28R
#2CuibAS9gS8JRDTeAa55tzE7Oxt1DWSCxqRBgsAu9DLyQPxEL00Hz8YOTxLKBkQr43FfSkk83YgrUyKaEsZEViOOx2HBAE5B6hUa
#CqKsKGhGcFRAYuA82DpVeKiJzizWHBHNioJcZQ4bRIqYEZdjdIN7mIvm+NkI7j4HGhgBJm74Ja6PES8G+W1OLJNdWCYaJJhM7Aan
#wWI2mFx6iRNBE180HDESZ5cbl8iCVxJKSXZL5IWIGkKwwDIcxL4CBCi8ABIpBbAPwVjrVM0C7AHojNUKzIuhSSPIxVBbjCQwU5PF
#zoU0+B9mrz7OGxaMZqBiAWbGKF5UGV4DvMzieBmIqsTpPgkeJe4jKiI4brMnkBx/1uDEaLb49dLjHhnzAAIsT+BJlANhXs7hy3Bg
#jgbuQwwhBhwBUMwYjdcVh9ADYNvGVXTCW/QaIydLrL22GhQjwjILtRcpiJqkJ1aqRARchkRNtTCaC3y3RNBK/apuGEKG6S4GXhUX
#3kI/iY+TIo0miltlJ8VFn4/JIbJ+H9n3jlpOK4PN1lD/JWQw+cNCp26zmiclY14SMYAkr5UUzE5ECpqID7zWCEF6JJSCVf5wKfBc
#g5cNeuFgz3SoJwBEja7hr/BF+ATyFb6ST2ZG9QwCJEhagqGETTAmK0/kL+ifjMni4EVIaGOAxLZAsFtFDoC1I7fFgfEWABiX2gFa
#WO34Bu6WrBgBs/jZHxbWUeRdmOxLOZ7PsJgsVr30LClTKDxMvsSl0bt5OL84w5SdpRdG4RYXPrHudnHdS8MxIxtEQo7z5QivxfBP
#dCdgGXRkwpOP06IYJAhbzsYEAYL4ArlLVn26wWYG1ivwG/lFic0oqMOB1EMR6P5owJeDk9jl/EEpmiWUw6ste08Pkx3ZFTQWEkRG
#CnsRjcKwumw0obpZbA4f5zcU80Ghv2I947SmMw4rUs3gKvWqYojE2B16xuFKR1poul6fYIYJaOXQCnAYF65FYirm9sJspCljGBPA
#RqJhtCYcg7S9MgzeSEiT7UY8dWOoZi2No568C6svIlo7BObFOMg/FROjKI1mTpjesJlSzPqQZYO+4mmcn49FPIypNEQpfzZ7eYUK
#HTBLkS5yQcRM+ACvra1FQiYcgQIoarzYi8WKOFI30fxsaLoqg8DqEgaYELYWG6VR2hTCFk+JhhDFgKyYAVFDw50miDIaRiY2l2Fx
#mRGOyiUhGjB+NKghhokeYcY6XYIv9gThp8cmmjDsbMAUSeVzNBhpsDpIIY0coqAzMXaiFcLHbrDbXmRV5hxsPQSC8EVcXgkOiVhF
#hhEmwYjMz6VPtDKG0byR5gmaLoYADXThPYjnu+QiAH1NvBl/l60Igq84RAs9RMHWUTNQ9ATDGvAfwSCTUXwOxScw+mIidoOyToOf
#4pcINMnVimygTIsmxindTUnUCjxeUTQlRk1fYeX2nayZ3PJTI5BVS38TDURqCKagKBVl6i0Lyi3wSCqWQmJxjAdC4ugvdQd4p3DW
#lWidYqQzY+5VLd1kInEtpiPe9cS13RYUx8MabjjIyxmywhKSmLEGoxY0ftFKcZLhIcnkLY5jiWlhLAwxeLVEAWlJ6tDRoudiqKzq
#ycvUIBgTgz8R6w9EskOuBRJXTr2EAj0hwYClsSSn4Sy7xOMj5o0TBmtVqKyamFsXwJEVFDiqVWWxOyhihX6cWrSamD8MMhk/x6gE
#LB00J23eiO6QzvznRUwR4/wim6IgQLmo6oM8ToWthfGjdsYkeZgllZpGG8jhFtHDL2NMagqVNZpIF+oX6m9OUnMnr2RLqhBLaQWh
#7n0+Ta3M5zu/WgZ+1EBRFTjGIUnAjXUTo4eLVXBIzkmeFEo0Z10MJU4lKeQE61AQrIYpWh8SRoA4v2KHGtGKE+WlsCi9FOdXnOCI
#FyymYQ0uglJH91dfTczna4gmBrz7v0URa7DaJfiXjbhwEE/4dxLt7kKUM2qVaOVMrokpB4Gdamr9DXUXjsQuBv0C89MWxPXW5ZR6
#oTYL1aZhte0jI2JpVNj5YRComfhBECBErQ8+XgzNDvUzUXbUjcSLtfh30tZuN1sUw0yfgF+nE0DtTLAPp1r0aulDGizBJYGQUDJJ
#M4jLfBPwC40zFAFqAB5TFirl3SEoVAHnCVgQQyqK6hnhgg10JIMpC64R7HAptEDI9gAvHD6npC6vinIRjo1lABqDzztoEF5lBa3A
#YEEvEt5kF+SIABYc4BJeLWEv9fK40ci6uzkcDrWa2XAuZKeVHylAg0lFrZ74AlFS1MVN5pwQi/KwldoLkExCMF5Ic0RkOj3ARTNM
#VoPJhTi9waI3KIQZogSaMohwAei43SQDnsa8ZEweKV+CfkY+iRLOTIs4c92wlNVL/NhktebQQQ6rE0SHFvO0yXinjdfiw+K8iJzW
#5vQ2KopCyJRE5UOByoxAKcMj4WkQh8k4HOkGCgP0shdI4Es4JK0UnybSBNGO+FQSXlGLbi4T96yGtLdIxM3qDWYmYcEYKROAFQeQ
#30NTxQtxMVYuI2oXCBoSJIkaTNReoBPAdhfWyeEol/pEppx1iSoI/TIBQfPKSmBlVh05pwgkRogPE0MqC0fxrQ6ZNSVjQFTMFnpA
#XdYicD0sWn4o0ZGwUfATYmwK3mlzqoJveP7lgD7or7Cz2x1jPWVBNgrfeakfVQhNtRrEr+9ho2IWhToOm62lnBMWqOROVK0bo13s
#GS2D3CtUa74Gq3LOys0kcoS8yQmTLIIsmgahqtAJg7eK1g4pMp+iusX5BIMTyZ54UuWI6hskJkZ9ETQynCawpoKkQtca1iGxPPBd
#U1i+9JgsYA9TXDs41ZDAY5bSfy6SKSEbu8L/oGn1Jjgpg4dpwL9FI6th1ixfIqK31ayWSlTuQbLZ1hJSMYORJEt0sZlFMYF4N4P4
#iyoNBrh1plUM7eVArjlZCr6YQfwFzlwoCpQirKpOKSjhqoqibIjjGb44HgtToDBK7NuI+zJXo6nienRxrFcR1cJtyTRaEqsjBfco
#xTsZ2xa7E70mdCkrknhCDvDSzK/IciY36mn7zCyksTBGCG0R+6y+1p+CD0GgKhpD2l6k0g1TRR+q3JreRYkXYS1Gyc6SUjrW4bhS
#nyLVI+HvUgTiCJmTmJjW+knMCA1bQ/9PmntQK2Ji690gyzcxO/TyC1kOEtaLgsxJkt6DISwUzEzY7VR4MsiGIhnYCnCWVxicCBR6
#hcQiQKE9bfIEPLyjHS83ySJzOAziP5M9uZ0n1+aEuCV6u0B9kSp9UpcKT2ZtCoT8aOZaoxH1CvWIsq1C3kICicWYIW5sNsB/pixa
#fBAgAYYb7CY7ApMdVFsB9L6ARuoJBWoZHgq6U22eRSIioGesACizj4TxORxKWqL9tzClbELjOOtRwnRn4iJTbI0nsoTsWDmyKJQj
#MYGNuKHRk4FIXHM+iiCB2BhXJheiBJQTyayRqeG/2P7CsoAxFC4NY8QzDONKg2GD9D3BLLC3RTMMy3pjdbJ3LSZ7UZRBdm0yYBCY
#+8MKRUrNwqVVEicjYEQWUV7qOiDBALdjW7v2QeE+MQbXsiBJk4TMMkewWeqP6GPy2daqndmowVDasypbR95lQ2LseKNpvZ1pdOqC
#pCQB+WDhp6YcEdqCQonLXZu8caVLVrwTi6l1PnKLQDSB3/ZIcn+4KPzxTltkANVDxRboHZuemC9SaqBNMUPZSL3KZEZlQi20EDOy
#hSZk0aPROtEYojDIDSS/sG9CtCc1lo1WZs2KgWkzF0Vgpy42WjSaD/wZ8pUy3Hi/oBHv69fHKcImXmat1YkiRbmiOFwne8SlojPh
#aSIhGkIH0aip2KdhOmnZOWTBoDAAhtp5DS75OqBHwVSRRBEJd9dRkcWVAmTp5OhicQCZ57RWqwwJaw5KJb4IJcvCjsD9PeBZpXp3
#ODETFbN8sq1Eh8btkCg1IPY1TSZSidIAgtVgMzmQ0mAjupXJch4Zi7vMjxiEvuEQAuhbIxOAGk+W2VssDYdIXZkFV6s0vOCQskY4
#FdpnKWPzsIYhf4O8xw4t77Esc8JOVgTphEh5Cng1QwENdAuT7ott4trI/EsuTRmAV9YpPqqdzkE6CwdF4jBi1R2mJc87lMtyrCeA
#MYpl5zQaWe0uTWQFNCJGHx+vC1uUGUjCaxgxbUXh604OByiMYsQ7ZYmzoh4CSaRP+avdblHlFyZjRFdLuKiSQcgeUdhlPXXKyCjF
#KDDk5S6d2oK7FFgnQrxvkvKtquCsHTI59cKj0v4UQe6aVXlEcBonPthLmUKEd89LCUROkkDk0gxaKJJ9rEL6r6ZLs1romSm2xJVW
#kBV1bwB2Zgd2JocSMlGlR5MkLnFeGk9tgj+suM7590o9VuxAZL3CAlpIpj7kIdfDP63kW0nciNCt5J52JdzTrrq5p8MlesppFClj
#rEmdRpGyuDk9rgoVmImp6rQZrFak5ttt2B6sztJqC9RI2e7V4LPS6pFuAyYiDrldDAYKACv3xmk2mtyJZBecSPgh2PxTB5Fhxdq3
#aIBZzWokETg3uJXUlrpSfVLMwKykplpdSZJddAHuo1AD/EdEbGLRoZ01rnaEmJ16ouTLHJyiM0QvDAh8LOKg6uevMhPvqcxj5SAe
#q5DCZaXhNUls2XCpQigNcUg5k2yRCyX8SQopgu8E/XF6wyhgXLV4RzBZyTqLSgjc4kNxUf4mmITDJT3Kh2SPSsQSUDAzpwqjEy0T
#mxuF3FENBnaBmZ84EEcZ8nUM8NWSnW8V80Zqd3+pdtzRjM6iyOYIl+iFgZoqVM4yekerxS5/ELZM441IAb/ap2VVGwWahE+eBw8K
#hTjEPZFwDtgvKAgI/SaJbAnWfd3cU5RzSmCEsVCcqtWJPRCxkClGX8Qae6y4YfG5WoJIDfYeOJLQRKxYRlOC4hsJ1gVUohwh+3Ul
#jaMWD0OC3auDrkopSQtYGJEpxKnwVbadW5k6oGphd2DUL43TntU6pKvIdTYr7oO4EpR0qeG7r5u3gfTJhYSlEJR/qKugrXbL8tVh
#NOcP6RJ3RImvFn9hXciMj5Y3yC51KexSYsPzdd9RqhGGqm8ETct+x4NgTD5RBCUkUHbd1VR64y3qDRzFamc+uafJ/jRXpSFIhV6U
#nCeim6zcg5p8H/MFxsft9OZYTdYmjOPihL7hICBNt49M5JOMgnoFBwQ8jklobFa7V4RuZcEjYl2eV4kWHq1treB2UpFpddYSjrLL
#vNPnpW88jvOm0iTmyyhzL4iGURH0qdUEi9xH7lChAnqKQXqJsjtyXQ4ZvIOI3JB7ZEVFJRJUrjAoKhRyEkdJpKKeCaF2yAe1YOdD
#NpaAWA4KDSxWETESztJaBKJFtB/UEhEPLRlZEIYVqag1/NMgaVRxoWEp9CSdYuWkLzKB2oyibGwTSQRuEFUrYaomXqbmJ9mOSXv1
#5IkfOLgAtoZSuWGlDA+oq1sXbAADhaFQwkKlCOO9lxgDkKoDtIcbYz5QG0ZcxK1ecilpFaWkMvm81i0gdNIsL0DmPHtAkolVeHSi
#4vwMMf8z2c4OegMWDFacmiI8RepqSDfhZYFaJGuWit+g5slUJ8XmzoYIYc5vlfNCMT9Lbf9laWTmCHxL6InKMKxnHDahg9hkJU9U
#scralVAxzQzGYvJ6NGV2tXA7pnEb20pRjyZ/ocibcl5i16faDCbdmLy8OkIM12Py66JmQzMD3K6U15S4JT42nlRUnV+UartNUKf1
#4KskeJ3IZsbBa5g1x8fVgcDEeiqtR1nJGXUsivQIp3apDCyZJ8Gu9iTgB+GgILUrweEwZOP/VQ8SyQ1PwglCF+CEwM9Khw6pMYww
#Rc3AaDFXfnF2qCXnagx5S312mHExUVya1f7VekgDinmSqk/ytRaDpmLk1FcRVxlTRFZQReRA9QVHgcdK2c0Op4bbWPAoeKxuOJaL
#hPfj8jZ4e3WdUhhEaZqFpanJBfJUUMadohYOYTuDySlp4cq9OAply6ntfXDVUTOORfPrkL2AG2onCSh0F4WHhiwJerYOfg5xM1Zi
#/ZM4O2KRutnV6tSkWKSB2RJaG+sjF+bigAfLzp/JnUQhjdXPL/dvcMK5xe0pSZxwITq5iggEMcQJOAsUqBHlJCd0KiKc+CJVXSXb
#lbyynkOwDInuS7rTiGDiPE6IYDrMWhFM7VzGIIJY7SQgD7nbnd5i2k4XIp1BSnM6n9MWjUXw29qUDnpxXxwf4yJ8XBlgl2pc0owC
#DUKdTGAl+97L8OYrfCaNmxe7ZYKBOjlN7VTwTTKjyfPUpjTyikCpN4rP7nDzOZIyR+5l8PqcJAXhNJxVdcz3TwiY89VvSigbSs1I
#Ld7I9JKr5dqJIHK+SPrQ9kuAXvXflb6jrfx5PeHKRD6XUxXXhYFnkbiuMxHXhaeYIOvhtHRlTbtGWy5DkhOv4ZJJKsjxA0IhEo2U
#5ATtOnFeBNbHjJg3uy3YGaWRrNbQPGY8Wu0aLpIjTL77BoaQUMXKIhEu6mV5JDjYKBdTWZ4Sw65HgQS1sUxB7t9T8YR+g4mLatrk
#HkXxE6VWblZ1FC7R6idcou5GZhZoxRdJt8gIjMQJH4Ya7ufbMUmrBIpaqCAKQrwsqGyXai4mElGTuoMEzCbxPOgJQ01tlOBbCA7q
#GRXVKYVTFNt2KdPMG/GotxIhfob4A97RR93DOjVdh9lKVZ3BD2tSSP1SOJPEsxnIU7qgHYUXVm+1jmGH5GJGqyirNBy6XCq1S5uk
#IRSdr+KquDZMKVuuwTBdWvmv9DOKqIpgS2oV6VI8VksFHHyAVSIDBFeOJjuWiHzH6I3rkGAxAodqlWfwbBFnRHyONeIUGIEKDOZE
#DU3FpiIoMyQUd1S7bfAqKR1B8gpSFnVKl9bunURFEq2CImJSi42WMXQRUBuuBqwSLghKiKjVudZCqbGCEOcLsEwGpRtDEEcPh7Tg
#etSyZFILJeSF6r0ksRI1hjwrRS1krDGqfa64uVB1Iqnmihsp9xZSC2yWas2IRjTeoIZVeZiMmE3nSlds01GITtG4x6qtZoEAi9mR
#nszrYeOlhbGalbbreZCNmiEu8EL5RkiwFN2Wp6wLRVrPVy/LQpc5tKnEFLX3i96pqF2wBehIW6HG48PZ8/JUJ1hbnHSXfGk1s6HM
#ZhGRcFJK7YgRqUjeQLIjxKWtRs3zae+Lcmss7hJHObQ7zbJSKR2MVL5AKgpXjR9mFPlaWXS+ljnRKupR780lwHeITcDLqoYqsvpq
#gSnRZMWd53I9VZaTXC2Yw7RMxTIgpVqDHTjtEjsgMo0So5ADoJI4ViRx1OW5lfIG+qNKMksGQDa9dZyOqmIOAxUIpcIRDKMqIEiK
#9zJMtxAGRkIeKYITggOPDi+p/U7CGRAeNiqAQlwJ0nsif1xqp1oz0lLcO03lQaBbRcFYYuDEnQj8QPINYi6Hr+NyX1TxLIcIQFJN
#hyIiM4GKvCSkwN2ICwK4unJTip0oAPLkf5vIqOlsfeV2QniZqLJpZwmp0t2w00EWj5R4CZ2GTuroM9Lak9SEWrMRrIZE7BGcn9Jz
#MndutZg0oMzzxnzLK29LLiozKTENQcKflA1Hpe9R7SQsjcZpGZjgNnItQbwlM4gtYidJ6FnTcatNydg7rY8LW0DPA0qAYLWplpaY
#50AutMi/scNM6724JFMyhcKqViisyRUKq1yhkIFNwBApbC0AWcmVnRQnwqhXG+N3mpWMn0gfT1wxZvGNUD9XUdWQXgxBsUPEwUZ5
#Dq1FooSjAWrZG4DUDbh2By5KZlCX1zUIlTFwmhJt+JkF3I5SA7DL1yQS5Yq4KG8UDjc1hsJC/g181cd7xBMbCuSHrdDaj+IYlur/
#urP1/m/4kZ3/V8SWB5BtaULi8mK+o/bz/8wWi92mOP/PbrFZ/3f+33/iJxetNVMZCpbyebriWCzizsysqKgwVdhM4agfysKYM1EL
#HVMe4Cr6hCvzdEakpDD4l5X80+XngqhlhHs6pkr8gEk/TwdthBNyhS9R1Nbm0jGQeZqnE84Y02Xm5/qFS0DaOobsfEANyGFi4gWj
#0G/iAtiUXjaSp8PGBRoQHGzB+PJ0w5xZJicye02W3llmJkuoTIYvMHBrmFH6KGtglJ4bRj4aVX2QJ/HdYYmPsiaJJ2FumX6YnzQn
#cmDZhcwJgd/lGmt0uNAn9AH9Rd8Z8yC4gj84XOL7hLM9GMmgy9OJtd8segn+InixUEB4YLQ6DNZsBv4Y4a/Fiv9abAaLFX7DF+Ee
#aYka4HboFmoBf63ZeAgIdfL/x5b/m39k/B8b6iY4x+6ivqN2/m+xOLMsyvNfs7LM/+P//4mf3DRf2BurinAMLHt+Si78YeBMqDwd
#V6qDCxzrQ3+gFCODLGSkLiI2XhYrMrp04mU4YDtPByIClDEdI/in83SEq/k4pFYILM7AwLZQOMMPM6I8i4ERn4ME7jy8sRA6jgVi
#QS6/72grM5ocOzA0wMfcDJzczeAzuqO8gRkBlRWvY0ORHAbOlWZuxYfZ9i+8aXRuJulANkJkuHijgQhoj9Qg++DzDBi8DbavENkd
#HYsGSjjGKpx5wJvQKDgmQt7LkJPPGfAsxIo5xlsWxZsNQ2zEABdKGdCM0URRQ3Q3GPCWmCRYRaLhCBeNISEZ9rsB8DS4OA9YsYjZ
#q5vCjVtgGlR7cbKaD+D5yxtfGCg1e7+4oDQwuEYmALR2INKrGasIxLANw0Z91BgEF4ECOaNhTzjGU80wrzMwRWE4nAkak/kwsCR5
#OsQU0RuxBZIZ9PWcyqNp5sd1BfjxypjOzWBtiUfqEj4zlQV1SWdgdAX+KBspRvcnotZ4eVHTcZxnNKwruo9XEF2SgIuuBUrhMPEy
#1o/vIKqrNjDU0wN6jxwB91DLEBso7V+KVrZK8YaRZRyP14J6xSBkc/rCzGACSBbWU1iDXtCM9Xq5SIzz9S7lKxDJuelXCtdQK3G2
#fWEBmCFhvB5ooarE00BwYVJYuNG4Qk8FUikQ+ygr9RarMQCaIQiWgrpYFS4zMePDZagD1F+QD6M7kSpCT0ITbxitZKnPwOCq43AH
#cRIuCFgIbfhwkAP8gBt+NGcmAz7NYEq4Kj1+VYTlY6hFzKSrlkO0VmgVBQSyTsALzQrpXnANDvLiYxhbLwCIw8V58IjdkVOnMEiK
#w2FENUMTfZsIOQZ41Ijly5BdzBRFwyEAWuL8lViYga/CEOEAbgHAwTA84I9yXKmBqQJnVgUTjjJwEYG5SoA5HwmjBxh/OCwtSgCW
#Fl9EAsDL1Qlu44rRE74wxzNQbjHKxuA4LZZgScNQbozYHwJDMZpCCLAuFsCFBDiYN5x2TMBJQFAW8aHmvIQQJvz+Mh7KVZZ5jDA+
#qQ0oxeEIEy5C+MEzTjsePQMVIwwAJBYDg5xvHuX8iF9yAL4IsnQCPBesYoSgK36MryOgAkATaEQYWYlDFhZiMGaGF0KT4VCEQ8wA
#zqpjxiGEQRBCjDwKg/eiS6PLokUGph+HDIcQG0MvB/QoKisV3s2XwSWemRAOeQIc0x8J5Ah6yschLAWXEsCoAg9a4NwYGoRhm5ib
#EMYCoKEvhtTJRg08SHwTQkEgAwzlYeXQM4SyESvnMQJWsKV1I8t+QJKlHAc8Bq0KKSUM/XIctfT8BUDvxrAhMdIAFKfwIB5nYsaQ
#zjGphSsQnYA7TxBNAMRi1D4crUJoEvBj+YSZAwtzMwJ24nJFbixHmDQ/F4OvIpsSeSbQDPSIA6MCz/NxGCkxk4FUvwji+XUCUV+M
#QzyLIB+qYorY8nAUCRuK9i4EOuM5JKhHwDkuZOCgJGOSpti+iRkgvIygBgzBB1OVsSmYp8hzhNMgkyJICCY8Cf2HTEcsjuVCHFpw
#JPuFkuSi/0DelpROJweaU43haHNoiZC4BFE2Mn/B46VjiqNcUZ5OwxGmEzSCQAitBxi0PStDwbr3EClV9IAvgMscGdqWbGsl+ifv
#DVQPhElhRJ3G8/UsexAxp2CY9anah+GUeC8+Dd0YgdPQhcPhsxSHw+sQM8jTQXNxxPA5U7jnjYZ5npw4Uve31nY2vf2ivB5nJfHF
#HBdTjgDfMXl5nlLu+Kg30aAcsblwNBNczZwpFCg1TUX6oQ8c0/kU+mk9iZZIu3GmYCzBThB4ttwvOsEoF5gZfDxobAh2ygA6ggFs
#WSC53MKGhfxcvirkCQeZgC9PV1qJi0PR/rhsMwP/LC78T5fMiSYYKX0J8ci9To7/Bz1pdZkTeNLsoifNTjxpdtGTZq+/J00O43+D
#Ow0jguhXy2WhKB+P3gCHj4vo3w1sBISabIw1BiwuhEWlbDk+nlyXPxr9Bp4rcMPcTBb1AtFCoR+E14hYGCYX0p2Ea0hLErASJ7ki
#qEH/0Aq1k0aAw+wSBcofEE0dpMSFMDqX+zXRHClq4hxENBd9iLke8ATkQk5YvmDe48+5mZ58PAs8Gmom+BRsHSYZ9HEU6j0T3cVz
#y0STwx8AULgFhhhqAX/xHQgjg4wToCsEllWTLvqvmDVcopcbhmoKcn4WSanrwKbKkSx5k9okQ4oPC0jt4+DVoA+PZYPYeo9GhFw4
#pBIhnYcBMEDzUjAbihDCB5Ai7SPaD37GJAyPDAtnzFHwGIBhiibMivAiOQnGQGlRWKeaAL6nyx8oqcowYepZsGnVT+Gr+WDKISyH
#L4qnithp6ofgYj4ysnFbCTsyCRIAU8eYI8cuZFmK2IU/RsPAz0E8lPESsuWWhgXJkBuRWL6YX26PVOryE4AFFZdnhrDl7Gj8CAJm
#BEYTTsgWQahkEkfdRfL/yeN/WGhfpJ4TP+DlzXI4ksX/8GeF/9dicTZiHBd9JBo//5/7fzXWX0NVdCp0tfq9o3b/v9Vmz1Ksv9Vi
#s1r+5///T/xUDB9gbdQYPl3vanQ5/J3SoVGj6z4j19Q/nSo7by/oMquy+ZRGsw1tW6R8kvu6pdWdtzZq7GzSvencWDPmklnWS+e2
#7HzNyKbfP7e38ZjDeQv7TPm8Udcjj7Xr/9OXu7599opgytmti1MWGqNfbbgy7+5KRyfbnZNfvqu8snn1jyNbHLhs9R/P9urjfeyL
#M3+c++HPCv6Z6lsmTzi05qUW9x14+PXytJHVv7haTerQ/Ipg5Ouxn/QaaPdv8lvSCju9kp7WctXuvqmtnmy3786S/u16eAp/P3fr
#YxWrV61rtf+c7fKTO3ulHrVH7u0w+Mns+x5YOWzyissr5uy494d5H/3xWOrh2Oi7H/qXY3b3AYbCO+2N2/acN29mScmll9/49rJV
#Kw7P0W8pGJI1/x/7bWtqSt5dcvCxv34ojD+xL71rWtuHAifaVl3tHmaf3+bQpnbfBt94c3Ha9lP3Ll3aN//MvUvTdt7yt+aL+04/
#Y9n8644hmUuGx8dtXFHTvt2+AuuVh1YM+e7U/nMzXu7xr1LT8Uuftc+4M3X+/QPWHb809+8/dR7czzpr0D9mPZE/+ND6weyozudu
#GLf87e2fbDi07Oged9emzedzLRrb/OXFXz30fdef/vq1Z9MSTndNzTzHJv69xgVTH2fSji8z84tdg7r4tp0LT9h05dTRx3atuLmn
#2XPGP6qoaNOWL6c/f+Lemz8ecGRN+/nHu7i6t9my8t0nK1tsGeL9K3/LglNNH2zOL9pqX79025nbTh899c/82R98+oAh7Y0lrXr3
#+7J5x/WDOvXb8ekL35lz2wSmfHCy5blwy8ilx+x7FrRumtJ0bIdYxza7Lzl+nanHbjv39Ig1E96tmfzp6qu/HFJ6z4LfO515JvVs
#7vcz5x64cv+5cLNH7g92/mPHV2M6HuNva+ttPnfvsML8Qam3/xSeMmhf2bhZu37JMmes//2TjcvT2ue9fOfbqWNHFX6Udix1RLOD
#h9lTL7e848PTWelHtoxf2/xaR6Pdszp0TNvwYsaoJWeL8ptNeG3c1b1mNtme+WT/WZ63X51//aPT56Rs8vl2n2T6FEy56euDH/95
#dPFXLXp/135p6UD27h/Per6d/Oe2h5e/d88zm6edrphW82K7j6ymVx382RdffPCukmNTt+lvTh/3ysK+V8xa/FNuKfP+PTkHN5Wb
#X7h2d3fzmDNfHfth4OSTJV+d/ujhzmc//cPSa+VPWTbn6s69/KZ967KX/FzV6M+jMwKhF956YHxWz6J3dl7T+TFb9eip7WI/Dmd/
#f3WrvpP9yXeGv/7UC8OPjp5s3djtoWVVuTOGPro721W4c8YbRXtefU0/auumTsz+a99nw7/vaJP+8WnH+nNrX/5p7qKJ/GMVlQ9m
#rMl78MZfFr9UOrwiNvr92PirmYqx8ZNPbVkzpV/6oaE1B17+c8OTN900fvbCk5XVJyfv7dHz6ZtmczekWZbec+aXFTvePvTR/meG
#fvHsHwfntqjYWW789IT+C8di14YWV23Wt3l+cP9DC17oveOtntunLrrz7zO6xCrfixya1Wrl9cWxIdvfPHHYkmMsb/18z/VF/Rd+
#+PauIxOeu/u+kw8P/HHw4Wn/nNSt558n3muz/y8+j+/y7btseZuSDvrDPz+RV3M2+9k4u7TFmKdeH9Pi81HrrTnGaJOu/zq7/Nvf
#PtlgPzptytwVKzYfLphh25/Wuc+tnR657pHIg5dkX/3kpAOLmsz/4r7H9nd9tUvN9HZH3v4wo1Vly+NLOtra1xQs+HzXoM0POx98
#dt9HV/DxA3Mnv8w/PnTKPa273jjvS7N+VtsB98evnj74uiODj5T9Nqf72r8tm5Df5Rb+RF9/8Lqst2ucZzr8bVoj1xXDmvdf+2bJ
#xE3ZS27gbuu8e9c91/sv/yI4b+Uv/V/dv6n9bweunDo+sOnhlI/mRda0nd12wSU5Qzu+2CS9uElo/IKUFblzX6sYsP7PmVXP/HCa
#3XZHo7yl8Q/W7/L8OvSGyBNbJl3SflJg4q1lXbte+vATPScMmfH1zcaNe18dOiG4Oufwve1rrnw8dfA9/PL7rrM2Xff4/T0tz+/t
#0f9g5ubdKQ987O702plrfOt0P3Zet+6OFj92fu7TtnsfibzZ0b+C/6T/nXMW7DrQoosh949B761q9sXAotF8+rGVzXZc1bvCt+fh
#Xisb9W85RvfbuDdT9zS6Utdp4AJXbstRk+9PeW3pz/tyxz9/+kTP7iP3bF41JGP+1NdGr+4+dema37rd7ShmVw777EPbk5dPerzU
#fGThiW3m4J8jLmt61+ZbLNeMNOy96sSsV1a4rZ8tOLs4bXbHdVPemj3X3Gb7JmfHkbd2L1y548lvprM3/eW+0f7Udv0Dfa6YM2bz
#oOuXDPn6jw9SpzRe+cFDk68esPXR46m7v5s5eFh24duFzz5q38I868h8Zsu6Lbq1w913La2Jue6es2rCvB9HOkfOPnb8od0/H/ui
#PDf8WIfj9/QY63wyxb7i5B+DvznzxIHChZZl8exFwx5tXzDQNGTc8E4jj6w+/vCyHcbApoD55Kqbb84JfNjfMXXqnfN33X6JN3DX
#TS/MXnzHwa1fT8v+nm9vGLrbe9XBu7Z9fs2nXVcc+s1q/qL4r+d78ItrKo8+Pblk+2bj5XMnxaYXfb9qbHy244XCPns23Da++aL1
#hvmPvPXAmXefn/rF8tfNX4R+dF97S4fPW30+pn/vFm11BfNS23awdjhmtvUxD33v4NB9LY6OHWMIrXuu3x1X3fBEoe61lJp9A55e
#9uyxV3a/vsOdcnR9ysnBPx1s/90r5YP79r5k6rnuaauOrdqUurrlzLUjP95feLD/i5ed9s3P3Lvs1O1txtnf2LO5cF1K2rVdUpoP
#LWwxpdssblHBoDeanFn62qIWz932a+FVLUMVVyx53vOu7af0He9euW/pBsvXd277ZcHCISNfT/u5bPHuqGtyia5Dt1HxgV+tbZeZ
#u/n1l2b435r+OXd3UfOdO3t8fO3JRqNbjBi6KHXj03/f0Ghq9tgXLl19yDz6nflXdP265+2Bz9LfWxT8e42rYsJdRYGa6Ds391p7
#JIebevxb55xPVgXKe7zpGDDpmlD+R5Pva+H70JTS7vFrt012Zb7U/IDrgZ5bF57sMWzxeyd/unbRzye9q1aXPP3Otq3Pp944L/xb
#o/dTPeN+ffjnXP/aoz9u3bj4VOoNrcPdrs7bfNt6yz/fLblp8Pdp21sH+IKUPeP3crsmBtc614595Jt/vrnsgext1of7lBU2e7/q
#o53eaVcvX2Q57rz+wdsd5Wueufzgk99tPLjgvSurrmnzzxuPXNdxb4fPjpbkPNTntW8WGd77c8zMqb8efO1vr5gGVZRsf3HVsFEv
#vbS15aHvd47r/mav8c3ucERm3zHroc6du96hn3Jrqstw6tTKny/vk9Jk5sy+zO17rkhpedms5/ZNfWT+kUPWZ4I/fZA2d3aX9tHr
#ds+e2yF/66ngba16eB9anm6d2Il/wjz88vbzto7o8efzFqbnwPXfpzy39duf7z8y7P1HJt5U9MJkV8dLj08Pd2h8VdPVHXKun1Uz
#81/fDjl8JO/n4ZZV330x1BDs8oTnoyWFZ8fd0HbXx/1fCQ39cyl/dFfRh5uPzlp47kTHU9cW7fhh4mS278lT1jdOFA3g+2381/I+
#x1Pzm/zybq8ZZ1sPmDTnxcELfLe+cHOfscUpnSYsesTFfzbg+tsn21cXzl/S/YZ7ewxLu29I6wlbanYu3Hm09Pe1e7/euMV7c7PP
#77339h7dJy1vpHsj/MzhAb9M3aXz/n3izMJmfQ/fsWtCb1+H+U2+yf/suP/ItMuun39oyyhfx5TLzLubdO7y1mc1JR1Sh7AFLl3q
#/Ix+3dqfnuFZ0b17t/SaZ80HBmy/l5k5uG1sfMGhJhbdU108O7PWf1Pza+NGBRkZA1oOGTknOmbBp58um3nmRcujrRsv8Ddecbjd
#vJv8pp7vjrv7HwcHHZ6zbmLN5nZlxateb3OgoNVA1+6Opqs+7Mc2/mxeQfdVqc/c0G/jkNN39Oue1lE/Y9qaK+5fddmJp051rrGv
#7GgcGHzmnSObN2S3WvvBjratGzdfNmVm60XtWrXGP12bkA4WFu7p1nbwoAFDHhh5/cSrt46IjR13oHjk6ALbhKfKFpbHVt09/cuP
#JnYxeCz7u6ybuWG0rYkvO2UPA1293bNVxjvvWw8Hnn3/05ZNN/+4d1RGP0cV+0KNZ9POY8tf3332PsfKG2PXOHd7ZqzfdcWGvpWx
#ezyFt3zdavcHr5xN3/gXM+f5nT+3H/3Qh7q2l5xZ3HzM99ZmbfNvaJL3zqPzTk8dsXby7Kb7PxnYbORzTwyfN+KytnObXbVyZcZL
#l/dZeG1p6zkt30+/5uoBcxp9P2327s7rN76vO1w967e/es/et7xT0xabm28oKHxl8Se6SWueWzDurblH4kc6tPL8urhX4B7jWMvH
#njmDN/26Z6xtX4fTy2ePaHf43R/v9d+/L/jht9P5eduWPfhW+J0ma2YfaFwQvKHJzGMFafOeev3LY3OXTFo3+61jR2757cpT81s0
#ufHktB82Thz5f9h5p1hxYP5P89i2bdu2bdu2bdu2bdu27d+xffb9zyS7yWZ3LmazczWfNOlN26u26Td5+njZTMErodDxv3fKm70H
#PoFSUvEX0MtKPgJT76+SxG2FDuR5HGh4hBXixP3TBxga6L+pNaLOuG0xBEGZP5/8+ejEOIlrQhBlKLXAAkLf4AcdRzrrJXuAeY+X
#b+ipgcQGOo31MUiIkmRs0aFw+CciwJK2pQWDXvpWf34VOBlAUEkYvxuEQh9CjEno+Y3rIE6jcfIayeiTYhvWrpF3jJqd58EWlJSC
#sb0G0Mm5B7FXYG0uKMGsP23jPCsOeBoAC1451KsGBNhdjbg1qSSuCcXHME+fnhcWGKxL2Pbe6ZyCRISnxSc0R8EenxOKcScnHNRX
#3R2Urs/DvjSK2QB+L3tSPbh8Tvo5SNHRCJnPYQWynf/SHbZgJfB7RSARLLh4OgERlQG7/1YeQmg4gIkH9MJ5qhypznR1qfF3xR/s
#AGR+WGWNpCU1bUlaW9hryYsr2r4QjiI1KjVqVaph+XGJnyP4VNI+nOlB2mvXBf8OlMO5ENRWaFpeXgzsX3LJfg8WoArFwbVSeVHy
#5+1gARquj3cLdHDIjXzKn5OjwZH4C8xr+PdXimYqrfN0738OAMgD1nOptQHwQaAdQ0WeO5wzwfW3P46nz2Gzo//LfJZxDPexF8D8
#idu4TNf/uUn/+oEeGC0uMBLFit12cr2YorKy43F/IjquHSDgJRiU67Ri6d91EIsgxnhEIpFKphtGw+l0Sq1QotSK1XrFarFaphtu
#R77jtnTX17KOuv8+1X6bcb+l6kv3May53uM6bK+meRP6h3u/JLWs27YJpn09LlLUwNjgcK+J1ExgKG6FhEkILsfSosPxmcjsz+fz
#weigTi5UwaA4JBqFRl3a/1Mry7yJojxKrVKmEQlV6qdUJ1pMNsulenk0dZLXPZOHyXhVRDgMRljxNweIA/CBzQFE7g9qng+0nVlg
#D4xy4bSqAhVOoMJwfgBjhwsbu5nYzrjY6drBXHt0w9hgbBQje9vyaHUCsbLXMQrCCcEC37corLj3uMxolEms265L4bI2FaYRJB16
#iDKSizOuRhb6hbGDvSA6JhYH5u54yZU2/u8sx721WyWtN/z7WmAg9UBIdW3wq4vCay+dYlT9lBbfBxfhd6tD227gDQ/Mf3TddPcp
#e4/zzve0zu5Td06X0tfjJGrB/59erydjfcjNzcj3cmejr3bUnht5d8wNyEyG85E5BCl6Sqve+j87znOhixc4BrGEnu+5tzVW/3oa
#/N2OMOQ+pJ4Oc1dk9wG0209sbGCvAZ9sPVvMl4xO4BWQIwemNr68AjtqdLnog70J6ZKCC7iGb0HU0KdjBhT7tgua8aZaIlhiywsy
#HrBccu6E07ZTyDzjrFmTQSE17aOrDlLmrKBTKn1AbCXb3lLxskOXxHnh12LzD21e/WNNZMjAKtHo7LzVN0RmA6ng6rZPtSYq9PAd
#k9pXbGhMN0I5xOySxFMo8Iww6q1uK1JZnOmgic6WWH0ArhvUzXD/GLxXA3S2DZfn/OmubqR4br5/00GciZYF5VzHUXESQGSGk0hc
#txH09uqEKpcbvWaPcsiXQxLJY/AgchMKLVE5KswFBExJ5jSMo6eMYSxCXntoPaIODUI4qRQhelDG9A7ldwuEJTs4EixXH04j6jn3
#Uwa44HUXMUsFjaoJtA2SI5sahmMeYj/Lc4J+NKltXIWbRymFyJJOuHGIzUJNbZiwZZjYKWJpyTIKCrULSNssKfyREimgpIHlZd+w
#UnmfZ0e+sm7D+pvNHTIWFGm8oDA1m4TdmLnjUITD6Ot8tCv9jD/sAJP1A4zWk3DE/K8phaeRMRYQqTCxJC/o6kXyQncq9WoZF1Ug
#Se5xCZIiRjKKlJ5WQBCrGiFhPcr1oOphS+/f6eROZhhiqZPgWGPDPqX0WmtLkwkjHMDKCWmolMGCZqlH7i5TY3KpjeNcOBgJBEoQ
#/GrX9wJHDIXglkikyT/AJS4fxwwlWgEGA4NOYNCGdl4kLOZFDMCTH9iyxcanuFwA4yqShpGSZWP0clskQoLbKst7QnExWSQvVqRQ
#gVaeh1WbeKeAXlfRZRZBeIKE0esZNwsljn2/f9/838k/21faZ35QUVrTYKOVm3k+265KTqWXMSw5YLckyECL/hNJMKoneIDva2Wf
#Jd6zFCPYU3JNYQ9GcXMWJ5Y1t1cSMrVwE7HsahDDlJi/bH5C9ZJSQJSf9NpIOq1I6818lEcVSd1xhShfeunZPsA4wI4RT+MdpETy
#YwLhcOI+y8WP5N81vxrHsyN4TUEPyPsxZMY0d1dkHVU5W00LSFzJ8QzWEdRA7LGcLrFItYH92TDTUpRpCLPYKMehxx27am+0vPGS
#K68st2UR9FQhEnPRmmjRfdJAKnsTWKE9QjQyEMrsyEImmijODSLljPI2H2VFKJYqqnkNjkshXRmiSzJ/O991GaipTpsqKHPVbRbJ
#IrRCfIbFrytNTghhOt3DDRiS4blRItLe4G+ZpA343lZoSRL4RWXmGBZNgHck0dxL7RW+S+e0SN76aCL1B3KBFXFwCQGHj+9Rcn0Q
#xNQhzUMeKAgGEiltj4Fsm0goOpY6CldaoA1FjuVbU1jloAuUDtPXRWUxMKKqxhlrMe9pWEZxvbmPkP3F7WP4FxFxlcQU3zH/GHmU
#8ULpe5gbBXsSU8cVewWqkl8qLJ7y5niFWxZR5PEW4zpN1Obzmh4rDEeSJoOSN0eoovZi2ipJ5DQwtjkkqOkQcUTNhga3kUAukfw9
#Wuy4nMrENWJw7/JW1HM/VzhASzM6bGb6FJ/sm2gBwdk+/cktmECcgRStYHGGFq4oyDjDxGrkVsK1MA9pNqf4j9TNCmhR1jhQIgzf
#PMMVIwUYdDIWIC0vEXiVgl0nVNGytFKjhgo5KSamk5AqEP9A7gVstQNby9HIUQb5Dc/33IccpatB3aZXD5hCTeVnwPDbP7K3EXun
#q7+T4mD3KCKEwQY9bmRBKy0EVqKX+avlZ6McyBXnjY/LaGJAK73rJ118+4Uc6ejvlB6WPkxtznUh66c//xLuCLc+h6xSs2fBwujt
#nNY4skd8xhhyKcPbxp/AKz5IEEqf3CNxao1/SYHFIiytqckldscxyihL4lOR9pLWuSvSSa3KCJBk+cCw1W61tSdo23tzunt+CTLC
#ZHiaEwl/E9bMig4kURBPxxEYxGl5nfmcU7on9HzXZVrPmWZSOihjwjNx2DMBS7vvoIYzlbhSdS/xJ0g+RM07z3eCe6a4w9KZrefk
#s/4JLv3SID9IyE4f43OObl818hzhUCrj0h3zNKnkgEbZ5/xd8e4L63PuXzmKv6xR4wsDfkUCJyjiJGAdX40049TOY816fk9j1DYv
#NiyJP6S99uuDatzIwlZaNijCDtHpL3gJGtsAv1indJP+BKCxS+x+Ua5EOQ13ZZDLXPOlPWGyxG8jQFUb8MiIetx9wM2RzwBKE5k2
#TUUdqiGJnTgReT12m/68IzszC/5MI4w15wvJnz62YOK4wU4HOpQ0h1rqNaRWoBftQIQSpZhCl+MpwKxCF4ZVlPVgdHi6Kk/eJ+U3
#YUT48QQ+ZP/lJq9pkcG96/s5rEFT15cdp2YDdtNrO3+66juz3QHmT/BqPx4YDUvR9f26BL+5/yXptb6dDpZfuduCf1w6iqVr7t18
#NHR+V4CD+XqdX64D0Z0SJJ8Cgx/WanzbazzIM+ieL5i6KUuxSX7TKKJ8yhSKdkpOVjmHu1hOJt+6jf1C64aiqNA/lIeifIhSJU9q
#ubzQ/+Ut9QhetLDduGOeFtW8vC1b16pSCUZAcDGQXoIIyhBB7JeTrVOrA8bdOQhyzA074OdIFJdzXeHyM7KmymXPPQeiLj7xmlI7
#EEFbv1gR5GSEIK+LJgJfcodaVlbeCpPprkmldky9TIH6h4hZVyE+UlfczP/p4aROrj8El1gu83Gxuj+2LAeXuI7FjJBe4417gocc
#JzsOpZPMFaPMBi40qhVOslR4F7C4y9ehRKlfyH7qFD8MzDT9PsaWfaaywFxMCKfEq1E3fc7vZ3YrknLHvx296MqqUPTCk1BP69br
#wOWihbRfVmLNlvX0gLoAMp2cyRYQbiGcxrg2WYZE+AkHNxnXnem8TBA2CwsRR22BNdZkovYCjJWuG7Kin9/acW/Z3j6SHQtjlUzX
#uVsguJ2YW7U4m0DOV9+VLhB1AZx2MM2GYkUuougwptSu2996tOU1SMGgBXk7PMm8orvhgx/UK1OwmgnIC4V2St3JIAXT1/c92DJ/
#WS5ciKND98UnLcJVxhNP3gIDe/mdu3p/wl+kRcuJ65WY3DBNYUBBcuGoVCfTFfafmFqm0OPiX71PKlYt00rJ+zTzsdcQI5cUzk7K
#O0LdpH4qT0gYF2K0At8I8xO6yJdLTmtELIKwZoYRCNeMzjfvI++9q6Sbrv7rNyv3YfMSwso3ubyZyyOYHZHZjS4mWeUo0gN1jh90
#APorG8G6mHM4Z68qVRKlogvFJSgoxMgvY8ds027rlqnbmzDbAl48QeoCMD07B1+0f4QNu6YduLHInXY4ZyTNg8OGuWsY/9cZwidf
#fz718voYZ0QTn52uDmNa2r25e2ren+uhbrdttK/k9z2cSX9QTALNxaxt+bcU2/m1zNw2ecG02Rn6F8z46Qg0pzA8d31n/saME7a4
#hvqmtkD9nNE3YMFlk7MsiwmN2PaNXaAbXTvrmxqzmAEvuI1C9HA4CfzYTSJSQHWpopRkbwahq5np4TbCo+8PcNOnLXX6AqS+XuVy
#IkKSTbC1Y8Mmzwqviw+5v9qn/vBy0OLQ23V/IJMcHjhJ/aScXBGswiNMxIJRmCrBWZLwDhmEMAhRGa3SWRJokzBTNqckFNZA+eQU
#dpblEyYwYM1cJRxXb7mUkMVV9mXvVY8vOmzAJRST8agArpj0AJrZXqdvd4sd0hdssXLlPw2BmQGxNux1FEqP+IlbKHkH4Ybczcaa
#a1aowARBrp8CG0sf7OBSq+pkZpiX2KKH7L6Srkoz7OUxzV7WeBoHHueEFiIxDNJcvqlcr43w+RVAVqg2XQ9IiTJW3jdjZzx4OJUp
#xcDMwh19YPyUeefDqisXClX6GKMkqat75yqcDQJYhRl63CXz4qmbpbTF0zut8DWE6fSBmvFRWxta3n8E9p302PsgZO7p7semr7Zi
#PCwmNxilh1CChPrZjr0tehNvN+1Ki4idGonq9OH6/lDw5hvM8y9gCVBQ0iKfhpywUDAtgXg73AQy/qp/kGXAEOvkNkxBv9meImCq
#d0c3aDxcWRGrUIYAGYhTArk0Mh1zuEqEoVODIBI6FiL6y+7bWFDDA8Tj0jEJwnJHwLM2Vcu4I52oJq7yiXYWo4/tmswZos3NQo8w
#s1xMCg8DDzSPgySjX2Ko3RKzrLbFZa6SuKN1fWnsIad7vjfO5ghMD9wNf9cctgaD4ihe9i3aHIsc6l9q1VUuFRz2m6e68ej3HiUV
#Rq/5e5PnxpJjOa2xvLqeMoRxehznxlHjeK2oStwMz3V8VasuaOot0iW4/KRTZyMK3cbNakdWqSarHixwBnrdBDm5hm83Kal4qp1A
#kqsH1yeR+ut7U3+RS49dfk/Gj+saug0URqGd3gBp0L7hKr+68d1rhsbsPOvus+4AtNph1b+pxvcNarrBdIH6r7IvBnWGhCgRoTa5
#OH1tVgnkylRRbTt6hu/0lDZoU1fPPVdP0xxoe2QPbev4irT2U5xPszVw274XsnLoRShs4yfdDESA6cnQCgbai9QlCREycL7xAOpI
#qsSItGpPfyOlc6VKLH3WKrUkqY5H+lyPu9Uxw5uv7jX3G3twRQfhvWYbshmWz58JKHwNM9ToTIbj7XGoPh2HOyeaUYVc6MQDQRDo
#462PPfjcq/JMeVGZyRz48ryYwg2a8toWOmXyIM7otin7+jkALRj8RgZG5QzjqU4lra0k/YK2x9dZw/aWLC1lFMzigUyF6l2SjZA+
#EuGuFjrBvqbNX2YnVQ+mCRVPqYKny4fctdxxme3bgWgLJtZBmPwtrUoVkV2EvSK7C8j4tPtRIEZ9IoucM8cbx0dh0CTUXxGtqZUe
#0ANNNJxXvYbtrbf1nr6/oRH/J65drtFyu/Dahc4tl5o9Lf9r13XtWu2fd1kNZJ957DU0w0kSSeFSywWP36dEA8R5i88/depnN22/
#Hr0m1cteTU2gnlb6lCleULGONWjlWzOi9sZqzUrnVmbB7ph0C7fWhlXbeUotZvqGC1FdWWfAe5jR18wqdnxNx1P7APnq8MhjzeBD
#Ezk5U3R6Y4eLgpvpNNca3SeXF6r0371YbMF2O8s63a/iggKdx3mgVQE2Ajngw5XTdw9J4NAOEMpiYBJuoeqW/pHsY9GOe6hQIy8k
#C2QLXK13jBR9FZdfq92s/H1pGRzrQ/yh1n07hm+SdKTN33WNTYx1J3Jqa79Jn/Ghv6elKqsYf9d/t1oquxnvXvDWAedpHbtnT5C5
#7SKarq76URiDY8Vjt7zKOtd0VFG5mAtm8Bnn9v9gZtDR0DwD1F8WDj0gA04RqVG7CdoOlF+v2rdIt9wZedyEhlQMc3bXOK7yCHDS
#kk3OWmSmsFsxJXYT7TTFJ3C+icS1WBWVRjsjgO1FAoXsgA0YRA/h+OTBcrfRXmLeDff8zKJTHgZIV9oS2Vjy22tbdtsHk278W1rY
#vG7k4eAjMFG4KM423vVpDI7AErUG4o+b0dZ281I7koMOySc1uG+KKoN62xrVMq51faIKP9ZwChEGv2dPiMqXgdZB5Z4GP9Qmgb9g
#IH74L9sJ6y9nEuRb2/rxy9CDzlcxkxb/Or6rc8zey89Vi4jEdIFQ1zGb/1qCW//tO1nOwGQc0U/d74H+KKIRIK8bU0ZurncbtEYc
#b9wjOQADXvPKVDyo3isu4Pgg+NDkjxD1OWEExQOdcYkENajCz8Yi+KCwTIMHvcKTJPGoTSJoKunOif230QT5EHcHwwfFv2bTBFNH
#BFH3whCwda3AXO8UBnXF11Ge+N3H5BHI71NUIPigs4+BEzynws3B8UFmHwXk7PPeH+0hQDFOYBRDKasQfFBZwfAnyIsIRTUi94oD
#10mXVxRCGU/e0QJylTo06ROlTpkaeZS1/jBGd1OxCHwydtri3oq/6P/QcP2Gq1gZVMh7g966rH1Xl65hrv5UrF6cXDcZCH9xG4j+
#NPB9ZIq5DNG2Gne3RJk0vjtvumxXdWoNZssPXqp7K/ddCz6fSO8E97dXAc3G7gsCFHwvHGE4ISBwjWRiOcN7hZL/RvfAw3f5kOMx
#kPwQGvTyjWc+wLjswN4bdL0FP7kA5GlAOSA/N2rCdBj4u6X3VJ0xG/eF6FJmh+sSAZpKu6B2x2ntd704ORa9APuKr5t6g399mdMB
#5bVJ0Wfmb5sYT4MfBR8KQCW6qHG0wB/lx08nfF6NvwRbyT+C69oSiJ3+Go6RBNhU113fFKe1D0z72/Oq+8IanZyIDguoO0+8OvVq
#6C1ckwLR5mtTiUt/rtLEpkRwlbfGxl4wScRZWxUKoZFmAo132sVuKdgZ0oX1iPvTv06+Huk+cr+x3ta7gvos9hD7HdkudbYqZ4qN
#zk9LqsRXNw/DYkZEPmCe2p2djU+1KJuggID8eH596xfZz+DJgPuB3y9Fl417HuZdauDv8PHstdv6A3lhCA4sjXf3MfYW9/8FxrCG
#SybdLNF8uKV9Ar0a03EE5rjGHJtkWOxn8JJmUG4pCQpg30xFZi9BIyn8qAzY/prC2JiDWRBR+dgPRtycb1zmmgBsTTYo9Lw9M2It
#mM2m3+czIM3sV+RXRxkIon48G8jDOnG1G3HG8ee2Gxwuksm+gzyKgz3GEV+P0RA8nB6HjoPDXEhV+HWB9eSca9BiTnJhkR/yMZhh
#w7cKEPuclJcfwEte9RuY28CJlx3lp3K5+scxpzNa37yMMVSgz0KffI+4ORjI4wynTPM+Tj65vxllXB9nAKPP5mBtTdiXwBwWKJF1
#Ub71O8NsLI/5V32IT7E9TTSnU2FLNIUaa6GSfx3xHYkk0GdM2gpK9AiSzRnD6h2Lmh7r1TnjHhz51+3hbHDLQOxbkyVg/4UuhmeZ
#OGfP412iXhgF6IxQ9HG4qhBSOMKp3uHZVXHhunjn/HIfmNNtAnEkSxOYv9Mdj6y5R+NvK4hfGzn0x8CUyqM7b+tzSMMeI1onpLV3
#8vDqJpmvCZ00N4uBcBY2TWgnNOvCeUIHOTXH/JGAJM0hSlGp5PSiqPGOJD0TF/uV5Hd4CcGrUScKg88pxhO2FOZ2+/wx4k8Yxc7R
#RdGYnzNWywxGwsueKQsNCKKEKZQ8xMLCcNThwNGaAL7zJJkyHF3vGcDs8wc7EralQv4ZKIXsDKKI843cMd/3pV2zLzxNsFMvljjJ
#0RY7rcuwfuquWSsNCkMViyTKRKlYK5GoZqKRyuyYUChXK4V4sUrJKpZF4oVd/lvo6Xji+RK0oNXsJKo97LzKVKlaDjqroLXQ5Zcb
#hM+TUERaCDIi5q1c4KrTLolUKJttXEaptAyeoylBlQlKiSMHfU7pFNLE73yszFqpBkpf4ODhZTNNyPYXw4zPltUqXMpuoUrzifRq
#5ZHgI6Q+LLVRWzBlR+1GtncJwpx3s13+KIIjAMbICa73qdwwJI3TEJQtTlnTjZvaexzrG5Bqnx7/XXPvOx/LFb/H6Wl04uJ/VwzN
#r3VZYdzD43FkvaMfoPfrHe3nxXQ3Am42UJRv+TlWr1S2DrcQezHaQa4WTDaLPRqRTrhwp91qsU5FoSORjkQvkVom1C234+16/ueq
#ExbOJMs2KqQsu2wellk2nUQrXvdFN8F8lVTb1khg+EFi9IWy8+dYiADMiAjdiAjuiAj/kAgASRy1UXDeGDECTW+MWa0xHhYRgNsZ
#DMFNCfs+48OD0qiAo/MBFQpBHFOLLBd130mf47SFaX7jPtCASOJWcoYxNEHiXBsNs08cnyus3NCulag7xGiMzomaBnqmaZNIajbO
#1wLkXhTBVMUhgivb4hijnHOMpC5duQgzb0AZcQjaE3YeolWs5KhaEvpAyXgOHn5P3CGqbgcHiSbTziTyaFoBk4z4A/IFCh5NZCoR
#TERsIqI+sro8/I6BuLVsVLZn9ZDUw2dvbpFO+LpHsT/ouzfW6DjqpI9Gv4gO7syvu/6NRW3ilQFvBs3eRLqWJ9XPaBj/li3y6tGv
#XCT7ypSIIdSCza/RYCMy/8dZeTsV9ZCH8RDZx7LjGOEb8J4n44f44Ty20OeJJk0Ypi3B/kpIO5NNfWX/v47Q+/83/w/85//o0w7r
#/wwI+j/mP1mZWVn+7/wnMyPr//Y//C/J/8V/qhsAIP5XP34NAKD2/f/KfwZyYTfY4ES6/RcAigYRSACZg4oIARWUyBD4DxE6hOS/
#g6ARIv8FgkKBRwLABKph+zaCb7DBZu3fAPRI7eQLNgOzXsDBTUNVupgROOAVJHTFJx38/dWUMI39Bm7DF1GkpiJKkBVCfKgw6ExL
#vPo+F7vmOetdbtkaUqf1CvS4fzsum4cKpBNAbkLLYWyfdsj4LbTw8PLyXopgWTcpESVte/R56B6YIxFqruBAF2ng7tWsQoArZoHg
#/WNGaiE47J8Ot3jOESHUpNZ/F8Ql52prh4rRNSNek6zSy/N/vHtY53PGT/KRoJBSNfjbnaSbCnh64jC/+yGRvZIKJFLDphbVEgHf
#c2ziPMuNztkaeZnBLOL8+dNJ+rNOhCCRIPA0AongnCSXA4E3UrOSmjVHdeyqxd6t2NjZsturbKN+4X+9z+6VXyBBE2ZuxQcN/rZq
#iiKMLs2wGcQ5KflbFw7qBhQAWd/q/JQoIIIuqAEqDkewrWr+g00pAShBqrlBKzDEsq68uG5hS4Wj792j9J92mxKxdyPYMsSkDPir
#ZbTV+qWf+JDdCGISTmClSp5U3Uhs8MgL8aIi2OjvWsKmoCIAFfsw5OcWAIezvER4Dl5SUtRXrK4W48trsZR8ym1D3cAZAxYaZmSJ
#3dXTEgyIGzaQchI4CwUPQPL9za6+4xuAiSABRgviKTILqhyiXqyTM7zKd1LSk9uj8XLLvsVv5weAe/sa3SdCdSpc4prdOZO/JmMn
#trLt+6IhRxMUZiplev1r/VZd7X2TdD/oJiSaTIcMZkOigVnrEQwzC6V3xoLsZr0OqBhzySeQnPQF1ED+XXkNqWUIi6ldsizI2H6K
#Ce2xgMXuWKvDTjJstcUSQQAzYgFiyb7e+rf7untNEEhjwZBA+SCk9bunUv38Y5cExJGl60Tb6h3GJR37GiN/OYeBbIvk2v+HbevH
#LsNOAQiL2UQoLKRFKxFTqHm1AFACKHAFxeQu+oAzX/+fks2hhYAzzIxn3Xpd3LwmtgaWHZI8lr6XQJYsgo77r/+HynbXv9uN/RDK
#kb7A6rBtmAq4yrdIXH4d38tXnvZ+H25R/zaXAea9gcFaxwtSJeAkT9EQlIYFD7/4yLegadJmWRG+TDtUFGN7fMFz1XlUImbQiFYI
#CVKgC2H20hJo13wUY31Zxu2rr2fk38b47S4NoQTEIJg1eCMR05uH74uxBnHtjy9FF/eYWfywKmVycBpb26+xzA895Vns888q1mgj
#0VQHsFznCT2qqxioGuA5IX84r083yAaIAWUFcmYkQCjAluRBsjtuFgCSsrCWGoUMzslBYE+PQpQNhTyfSgUK1Tr4VTmg1SqYKwYM
#LCsKlh0Ky5bIiCw7Yvtu2G0XOO89gNc/2pVIlxLQRABUMM4CAobkdYWTAmGi04hT8acLACJB4M9hMEUMP1cFix5qejxMAR707+Ld
#qA3g3h/axKgw5kEiNG7wQW1T5M/OQ+hyG5JB6oADqcEiezlWRDks+HINNjQuKItt3aCqW6KWNAhYXenfVXO3O/TWN3K7y3HYOoMP
#n/3GCXHCKMUwcDHsgEUtgxYoDFpwMWZAMWCCPDncC0Qek0B0+8ERkFlkBNivUD8DwDB0vLDDgLIKTLlW5wmGzhq/1xZbxPiyFx0t
#SXydpbNWTC2jCJhENpUbS9taQNVKlGmJJ/YpylrZ/ZQgnkSLS9/EHaTkwS6Akz/em3w197X6t162VXVhQ/f6W/y17Rer3Spq18a8
#KI7kuEBch2nd1lK26bUqHb1oK7jbYUWJ4ufBwKsqNNabojoqAUcoxzPbcRwrvUEdrWlQJQhfOiXm260o9RaHy6yh5+6T39HjO2u4
#Vifc3wnaQHqsEfHw/uS3JzO9uVidqWbOfGWYT2cnP4jukwmEyb7rieMhMe+ePmdWlhbwSAb+tROnlwRW2hn5L93hd+L0aoJmO0G/
#AS9oZ/eL9gTAgX3spXwkP+gn+VP1e3zF37CFrH0ClwtQa4jiWsl4woUAf5B+pBv7e6S2Htnz9NvvzOlsTf+Z6/Olp1XApcV0tOi+
#2VoCdBCMYhTe2jQYc4+LrtHneTSt+d/Qj35ty0ptxqk2BUp0TAkX7aaw9RPAbzuPWM9MlXlcKae0QwY0B1xcutwX1MLWbyLfC0VI
#QqlIiUo5/nIMN8SUv+9bpfhTuwR5CGWAOyEAUa40QA0TjAZEeSBJkuPyDHePeD583/HhWUPf7DXy4n1PphIJE3TamMgyWS08j24a
#HMcAk9VWwNpFzr/KmQ9n1TYBZA9GO/jvL2D7xj8zQcsEcCehxgRYDfBXaAObNh4H0MLQ0B7uNx/D8KMBfZYJwEHDtLYY/hpkpwkE
#KpYGXGARgT9MKF4RhccUIVWsQmQ5AZAKj4WCV2kQaVgQp2ReaaGInz635x+4qnqsdJ4fnvWRR+hyPhJ6A7cRMOqF0ezgF/Ll8mOr
#t/c7KpnvKHk+n/YzeLCxxHeprox/ebsYM4q5hvr2XAZxKwx+7r8PgzHcMnPi/inX1UJoB3/yIjP339D1/U8v7fs/39KNrEhatIor
#JJqW7a1xla7dUbbRxYrDjlnG8sWJSTIplyrZ86mnTcgKdHQUkeiJRKij5OEaeUo8plMNU6nGz6vxKqliPLJZkq0WgxarUlWy2JFu
#NylcLgagsGOYRhRbDMMUMOxItimKKmOY8ayDIDCQ/B8mNoNBhEUNLUyvn/9Oc93H+n67Pl63B933Y7+/pVVmwR41Mktrwyq3HLFf
#i3VT8JbSEGVksPyLkx5bdRJ8NF13AT+51EdyIbDFemnynKF6nuljlYVLraxR81c3jmfMOwvV2UCLYzGV40WU+qYYpSJih7cyP2Bc
#ZS2oVbj1OMRthAJL41W+tE+g01+qETJZlh1Tc7UPd1uNjYtLHhSvBwLP86IyEbo9PE/90y/VjjYQxu4fpNMJldNsOpVN9ndTKNUJ
#C9L3cFvuqFatVqqU6wvjV5jUVxYpx/HsQhLJOA7vDARCXso9ciXbEiZgk4hAT6ASoYJUCCxeILB6g1TsKb/UguJSK9RJb5cKf0mS
#5EsSdAiZuCX4MvDkuc84WuMTi9hJ/+0JHQSFcbl4pkqoI4ea9ITps1WhKPQ+EYKWjNAHiRRBYZW6AXe5FUElGTwnINbTQI0eLTgU
#BrBkxmnxbnyUMHiZYJCiA8mQXu7uZ9Pfhb8O5oyH7+fj5SvuXTKV1Vb2tKpkn/tcGKUaxgtvWGQSt106/8x+Z4gb179nWqiGSni+
#saFX/Ghjns0/uPFbxQEQmdokaNErTwFgZ87ljM2HifihwCrPKml/ZKvcVprFLlLgfSawl3z3suVvNCIyBbROjQD5PAJcvdftsf5s
#Paj411XlS4J/aXLWiBpw6kE3cEj6QLo2QvhTLcXZ462Qd/nvO0pO9H6n9gD/8hgpq4tLk9HYhvdtWeokR6nJM106DTJhrK9KvcWm
#scq+2rz9/BC7JIUMU7iNOPRMr1HrkT8jVCVs4a3xwLNhrmKNY5H3o3aeR8WcrkGy63aMOezPdts7WfRlEqP9K7q/NqA2pHwMt76I
#0JRDMGUp3VCwRqDPVIwzaohYlXCw2L8S6UjnoKogLAzDQiJqZVEWFhKSFeSAQJsTcIzUO51A4bGU4OMvycI5oUDhtjPFalzI3Y4o
#jqNxRUohkk1wqC2OMKKiLMsTahRghZ3GnpRkYqYgzXdUmFRgJMogCA5OJ1EksTO/uFDTh5JILEOZ6WzMCCInbGkIKzecSMKePz8j
#rDAhTKkhSCJ+aFSScUQtfHsDyeZDhPgVG7Rfw8kfz5QofKqvsu+K+6TxvTSo8XEvWXjre86vdNmRo7hiDSM/vIeMoEJsn6crL0Uf
#IhMqoVg0GpU2OD9IGWp34+nSXWAolkPah5OaoDkMsIIwHnWiF/SNRJsCvwa+hr4Gv4bHAcCBwAHBaRLyEwHsKkQQ/S9gdvoRc3az
#ShDWSjHci6VgUWunyX/RKFV+vrOgEf0lMhgwQlp4YJxDn84jeYkUysJnUzP+9hgjEBwN5x1BQIP6qj/q335Shgs2dMMgILqkBFue
#uvUm9D8iJE2yWxqhCBGUIsRojmj0lF1c6ZXqD7EPQS6mhEgaE+LyrHbhDwoBdpQiiFEKwcrUj3j6/bg+70X4aqDVCkHaKwV72ILF
#LIHmVplFr5M21K11TBzUnX7AIQGYoYOrhB8MLbhsBp5tCIYmnNaxIdPjytwGXPG2gwrc4binDfq3qxG4n9krA7vAJOVynN0/MX2D
#AEgcEIKyFSu0DDaG9LTWGmPpUi+TReVs+iJa90GBLi57fkM0UCU1CHdXG2iowcJdJn1Syem1pQG+okRIh1/97X77E7sR4XiEFEtC
#BTwsNkaoTorUSZrrETEri+Vp7QzDNol9Eqc6luswGgtY8Aj0Xq6a941HZO5Lwpc8ZYcJHUog3AQP4vbTv2mpPY+TMGm5jhNrfC6b
#+hs2LdvKDzOsOt3ivoQpFGVZ5l0Y5lmmbRzn2qZJs+2bhmVA/K8l4pEWUGtwheZAJ8B/SGi2o1rc6DdFbYEIXA3oFwAHEDHixavh
#q3lcckDCbWfubSPNWe1Gr3YKYhby+gZtRagKCQes4U/+NdC/M923Y9t/MPkImp9HVPqG39KXVWfz+7doRKn1b+gf+tLDUXoN8jyj
#SUtQiISC6n0lHsiHl2hsD0ilgRnm73l2aHRy6JX3HlkRUZIbXbO0oHIiiEpMUKjDpB+3kCEBQYHxbcnofBMgR8nL0UcJIWAP+YgZ
#SYuRJueHf3tb/CF6hMAXReBfi9HzP/u7dkTPOwFdVd3NmLyM9g2t8LwjvDtj4p1+BLU9Zl5/EF0jdd69Yhc8E3ZdeWY0wCEZRE0m
#EhKIksngkVstqQno4ceDUD874+xc8Ku4mvmc5EtkrMqGnZlBRIWvkyIYkZJk+nvTUNS1TVtY1rXNe2DYzHHlm+8qL/evtG1ba5P2
#G6ZvzBP/ltLxgGrhj5QpBs4UO5vpxUi5sYExbXojOQYNiLwdhCSbFzZsAxnJ/5GKEwONaWtWOqoA4o5NKQlf5g8qDHiQvGGnIzXk
#g9f/QQafacLFBCJJBgShJOBCNPAA1TYgShhUqYfIuhEnw59A8g9G6oexV1aEWGvaDKE4L3PQTiXCQGGAuCKtPc9WtMsaGEChCGYf
#aLoSK32n0Xbz5QgYip6ko/uRKmrsvy0D5zZ/4AK4mqsCii8Fn+PcsgQ8YLix52UkJvd1VSfOD4LhW+4/OzJc43eh7kFPHHVD1KiX
#AZzXhgQF1kVuWdv57pEZWMJNjl2JsFJWR7sW89XEY0stouRD6cdTy6CaQUgWqlQga4XqHVbch+STbJosDc+YSFKXo/ybp6+NpBJi
#jcoeR3wMvfyxDEUznbo6ecclAJSGS5tO+IMPHP37a8W4X9eP9nlzrWeb3T3B/TH9nUYRCNgNSN4B8qTYvha6dYR2Usdb7f1YcNXv
#+Cfef6Wh/zV2jsd5FULcxxObQs/z9L31jdygwz5PUM6IC9tlHo2gVji0MaKvRHfLPCiXVCrx1Fv/fRDLPBp459lnjk5Bc4dILDt/
#82BwMqxH/skf7/sPn73XbVrcrvsuDvz3xbtsyH5M53VKsp8c7/c5t/dVdEC734MPwlvGbZQQHPcVEi5YPGCUnKSwrKDEyMzAhAiZ
#TitEorGIB3G4OFpEt1RqgS5Zv8sGs+lkQr1KohHprvo5zt11WT/XihVrxatqzwAYhmUCYlYsavnCH55HJNNhkdQ8132Qk9u51f5V
#1/qONMHOzOgTmmp/plMAdw03XrEv5qcYafe2yz1cuV5Txm211e4utahc2DoBrbOnOp/rY2nUKOqPEc9XP3AVesK7umbv53EGLUZv
#CObyITNndNprYJErLbExrQOh9FkLwSOoWkKAfJ7KCYG6jQheJu7jsHbItRKRsGMGtpvuazUJ5y1OQHGyEZscpS5eq24odXCRl69h
#8qGW5woHfyBzh8OxFo1Vmphw76uyzewEJZghzh3rmaQ2qFKBTy0Y8v0JLfS5OrZI5XXcV+1tL4l99+NG91jWC6mvf83FbXsHac5O
#HwUzdgSyuACBNLuBJQ3n3hnNTCKfGFyWFwYG3IgFUghQlKjCa43QHIWTjM/raFWqvcksyEC+Zf4oFGls4DBaykIzmzVS6qgqLsAu
#iGzUchRqARw0OtmuY4xWfvhKo7ykcS17DrXaLx2CJ9kaHJzqut3yMzAWhPoDx9DUvByPOzHnjx53frpLntD2q8H0KM5LsZqg+8kk
#456CrFatEYxNo+3gCPalFfsKJOScqHM45uRLsqGNexfMwLVt5iEUQUsO96SppkXugnZPC9nWGEB+v7cNE4TWXyyzqIXEERNeuYGg
#a5J6sVSv3VBULCmOfoInncBerLncii8pA+OSSVARhum1ZrNxBdi287QWsbreNmdF7IzK/HeTT0lxsBJwh00dZFJGKBcuUYLPidR2
#IRHkKresA0HI+hGKG0aiP528UG4oWL2x67z5fnm5PCXOSUVx+KpNf7cXk/kVpTWPi2nltq/MbVkiyni81R5zTsfOPpIp8r+0hfGJ
#PxilBZ2XzCvxFNzUvwiTLAwHJ1m34qm2cPCQp4aBFalI07DMBZLxISO20kSbrOwKJg7TvPKquJ8p3YpSU1GiUF18FkgSU572W4DV
#HYodQMBFl/4CE2RNe1n3f6dHkWosiYYpvC6gQLyBwX0DwwIIA0hUDChVDqQrA2hXDEhY42QJETUTVnq7T0FZJ8bvEuIfKVbxm4/b
#3m3kFh/evJwUG695xdO05R2vnR8zrmNHkKj6QJCkSRpIlaJecCygMNEPgb0xdfc92UaxPWM80cXSGSz8rbn3XpqAGER9eSOcmZfS
#4FhkEA1m1vTTsc5wbEdW6dSLF1/tVzWpn5UmFlzAfJwOLOKBZxv/5BI7ZEW710M9gQA4fJM7c0SHT9elAVkwuhIJpp67K47AXnLL
#jtJIpYwSfJPdJ3Qk/MK83CHt32PoyueFa5kQ/UzKDievtmxJxmbXDb/xQiZv0ZFrSp5nmzF2bBpzyjqBZLfsfnCOKk7FNHFDOnTu
#35JnTNyO40E7bzPokuvgV2R7zbNEHjmQmSAqqcbrEcv43fK1xAwyIKhjkqWRtXYlxDI+oR7Jig0oqScJ5jKXbZ0c4J2zVtxWAWwg
#lkYNQipIqNH+Ba3QhZrEGHDtUypb58nJ9t+7SrjAhFNBkpZkZm86HzdALoMFTDFmHmpD3KBCd7C80/Tfs2I1krUwGuSTKoxVkanR
#8M82WKDRepFahp35vd+KJBdcx94PKTfcFWqQY4zEDaZcnel+0jYX48WueWK+LK28/VrfZdR2xjNJnfl0SjvcRTXLHwwmOxtX6hpv
#NUm0Ia7p0A1tBmqWmUkJECn1ZMDfF0S+kVhlLid/wXRqPuF2TXT+hGCgMXeFPW1GszOZ22zCaLai48UZ6oOJ+9NJvSWkYuU+fgT1
#MMQe2rdjXG7FOhZswJ6dXlCbILCNwVrW137WlbrYw4E101cwSuhBbmW1T1wPVpKtP8DR8oHAbSLOLYjKgQqyCOvSQOBEeYTROVJB
#JGFuZU7hojsYiGRdMJUHEkivnM4hQjyKqHPAgogW1SbZ4eSkGp9SlQcVZBXWoYHACfMKr3OggszCqE7z4Yy46XTMWRJcIKnCi4bw
#LcLKAQ8mXMwp3mpKRpeMjayaA4mbBhlYX/30CFnYsCUGdHWGQ8dr26Hku9RQ8dVQ89kq+I24vV+44bW/bRxm34w3Ho1XHo13Ho2b
#YnRWj+/yuIVvXnqoLD3UlByrSo57Y3TGj/vyvn07zL3WeG8w091gwhY7yU8jlUZWVe/OE8/eyGs+ODbfbpHzwgtu4NNBTzwGbAGY
#cDa8ooOwvYcMOOBWiCbQ9hOmlOjar6qr+6MKnchs6IsgrzoWJ5gv761kH0mZQJn6uQl7ISfvfPJWqWFAc1rYEqHFYzw1/3MhSKky
#jYiMRjrfdk8PraykqgxVGcUmMwCzMlMVN3WGplX5RdScSSRqtJCOFlG9FV7tFPJ3ivGDHQ3ssLpMYuEcnw4GbEVXaTFidVTxJIrS
#1kymmUwSX2pjv5Ytb0OWNNV24ppWJ1pLpLacN/Kl0aLEiy4LPTKTGe/qs2lP77q2qLtyyyHKj/sh7iPu6+NlVHPNO1RAcjWj1byV
#u1WN08AX8yJfe5eXyJjKdKlo3FvOwUHr1oi17JJMXlPIR8wTn5ffFenc16/z6qXTpeIy3QRw7DQvf/1nf6s/pZITFV+1rjy+q5Eo
#KtrzHOvk/RyUWiESxZTkFTlW5d5M03baR/FZRB4n0o66YgQDHFEEEgQKOF4dPk44hiAaIGCZ9AaVNgZGoMjIcJ+O4AVhiAHWDK4Q
#B0biFBs0k1hA56ZpKemUmGEs5rCMwkuOf8D8Vx0JGQpVRMJIFpuMgKDNuDOe+wAtOQRdsuHORWYIgAhj+UujyTJA7eKDZwQX6QRN
#puyilk32jJmHiIN7S5i+GCgMVgxegYt5X7zmulK6HROfTAHgTk9AlTxTjYLIeKAiPV41pKLu0azwZIUSubiJ3BbFz2RN8e22QGk8
#DBCH8QzID4QGAzOV8WYP6AwkQQWzultZcM+QhF3RUFwluaKLDat9RGhSq08hIVmU1rzH9Dm8hWJkcprFB/ZsE9KpOzhnPuISOO/g
#pAagRLNPeX3cVumkiv6zRoCDWQ8tYbdaTei3OBaEk2HcWjB0cI3wbAr0AsIsnwSTgTGK3o5thE9eHPBVYozE7iAHLzkZFBUHWeGv
#0mBWOrGGXcjm9stsBF58UoLSIrj8Nhy0XSQnkSNZxTqZLBRLUTNlnmA4Mnj3kdWjutAEa63VHmWZdsMB4DPhcFblCK9MTCSutfi9
#zOklh7cSiLoKL3J83UFbjcOw6cnKbneLLY3rpV4y0MQcsHgiCGyhyBjghATEAkGh/sxY/P2RXJRugXVolKO7R9sxoMjOCX2uGgTF
#YpkmiKdbRJM2GPNgTjRNzbZdgJg0Xh9ki3uA1ItL0F1vIqXpJX/MrYNCw36hOSIJ4msscZuqjihqg4ObbBJfm7JEWO4bIFqcBcbN
#EkDeoEi54bD8yq/SxAZ4zSsZm54bhYPSoc9frioZKe6igvKE7VfUSymCr7NTWt6uh66QsB59k9RjgmRrU5t/sE7oVfYc7wa8M8ZH
#bJERqBcxWmyqVMgb4hthMcjtSsCyhRzLLsedSfTLlvDp+izA8CYTT3tDK2eM0V+E9JMtOvQkzgNI20g+O0DcL+O6rxbFBgFXVM4s
#dghW3JsPQEdeeVO8N772e07pnQbxWSGZF6AMh4U3utZGhFEXo4TIOhazBfg+MBvLUAA+TfTKcu+H3o7yAM1TSLj1QcElR03U6+0E
#ha9zEwCCMK5ahVgxUI9/7IrhWyGGVuwNWC+kMoSsMtIgEw73T+hZyphaAiO+OeY/Beakxo52qFjg6j+mgW5sEZFqxqUjIpF4MYXJ
#2grc8/QPFW63cI64gYuA1VVe/pR2kE54cqnPDrzIm5RzOZ9M/j8Qcuvtu+GOUl4L/P0Tcq5y1SRXWuO3ZaUHlRMValGqUMy+wzzF
#DxmiXex1MzPPt4zMlP/ccH2rd7lcm6TFt15v8tkkdYc5eMlJrNRcJ5cTOxgETfFQgdh9bu4WfmfNfWHgIvHw6rMeVqaD/Uu04K0B
#dVqMr2B++efQtVmZaK+uZ80TDbumIZ98Yvr0dKCFG17aMS4XszWqNvcM6hdkJUcYHuKj8nqfPPD3A9giTrbXLFo9FmSQfBnPR3P7
#UrKkgqRaXY8xffAjSsBQJIS/PMLS/85mVFWFYIjaMXVsfK1rNGRMTZL6Dkfh+an3zMw5NIa41npb0aJhvPGc5aivKqNJJ12U1IL9
#jPSuwolXA9+heivHGoV4upCQVkdRfg4hg4BBBtbz8/9FxvnRy6NXs7pWNGAQeAnSp1CIzr2hnchE0+x7/eqEJ6hi+Wj+ktEfG4NE
#VD1i6+ZRbP5Oy3VXQ/AA1ZPKo0OVHBKEPQwc8C+9YbE0XAGPONFR39Haw8VGjc22+BcbR4DZ5NQl18y7OIoxGJRcc9alGzPRdARn
#XYkqukZzzocA+358arqDD6zmCt4Nz9XNurrAudq3dNc0VwA2LenIHl9iEhk8EQrrZ6xWaTEzQlyJdgwRFSqaTc6w07zZoEjxYOff
#Vn9ALiB8dJhbdG8CBow7Mi50otAe1ku3T05oDWxE3D2bt72Wr6RTMiaKl1ZBxE9HHz7IXcE4CoKNrQ7ccHUZHC8QjlxkLkE3Hr5N
#hmxJd1nC5NXH8QOWShSPc9+I6TYjIBNNBROW0qQrq4ENgSAJulaYmQRgavD3aS6WdiHhTNfhqgq9Z2p80Q7sNUpMO2zd5EqvkZOK
#DSdskWzO9t9gHEVAFKkk95ZWps+ljXdPC/+zZmvRvfN/VwUXHNOfWt1vgp6TzkzaH/EP606fVRCCibTEOoOK/C2mMZgbJ7eIjvhb
#O/ssknljZ7kIZIPvMJVI/Xdnq5m3IOA3ZehqbJ4hYh7ztQck8vDmmCMY0yLOWlQfVBmsHeXW5kdU3dZWLxgSt2BMRGapydFuPGJ+
#jNBkhWzw7zeA4jzRYZ9bYpyAmS8yQWVRVr2EIrGDBqvV/00ZxWqFiiQCtqVfspxn6XAXJ0bCH+wEIRnANkmCqPuhGy4EXo88hN1H
#JbwMXpLdW+RYlNvNgh5oHNDYoGJ235IDkZTTeSxJ0DscbQNheWFTte4ioZhkK71tW7Jdyc07FJKAt4cxZ5GREkU8BomNiKoQWIAs
#yRuhBkaQX/9K91rqUi/0siabwG3KVPEG0z2om9JVktjXkxFIsy6MNK7s22cEXV9YgsJU72ekMggMoxELHfFhY+v1lARCZJiAWM6c
#nAgVmJiRtH96T7dlKDmSFhqSWq1Z/1nFWn48U2AlwDT+pyKBSujA3OR6RRI6E6kMkFKzVwjR1RicoVwNIwOvSBJaZ5iZS+QM6VQT
#WWssblYdJsyejkfg0N/cJcLt+O+RRCG8/5g+TbpgyQNDxhQTJ/gRY+ozf9U1QHA0h2rSiEKmxHBRJq0Lc0v2hukSMZ0Xn91a53wn
#EgmPSJ5cV6OyLc4Gf1smh07d8NOmijxf3iUuDQqbH3GcWQLZOY0XMlX0StbaMKCd+cguhKClihYZudWxro4CSxvU31KVub5myv1Q
#tLBKPWLIi6AO1ZCLu/zvNkBwWSqalmo2wX3jvoMHzAn1kMm/NT4cAwgUjGaKO8fP5kZdti61Z0ZwpN+aYJ9tz2juUhmJHuejBbnE
#lpijtvb2zG4pz2R7lcpXqeGtpgBv5FlQjHywOWmFp5qjh2ssmnxgxZeZmtFbDdkm20rSs2VFxjsTUvDtoTV0yiKDcdCIsYMI7kAP
#is4f8/PjVG0hjPM4ty0pLQO+VxkZ1T/cRz9Va4xPKsvJ1dXgUdiEMEnxe+Cs+cuD3cVryFaE8BghMjGyw9VCG2lqHVUbsV3n5RRY
#7Il8xXL9z0jn6TmFSJ2XxfWU2w8c9QSKmqN+uH7Oh3LRwpnO4/V6LCew8zIlIY8WNweWGWuw2eMEmIqPz0zJZ3yYKHxh2PTR5Y47
#+rEI8VCPUa5jyZJJb0Ybyc691S36ER/VWFuUUu0qVzjvhvyEJ3fUd06mRK8T+s6zCjoCq3MddHGGQFq9BbdHw2JVDHQ3FzT3GI4g
#+cil3aaSjtw4QQNL2HJ5xk29n5elQnbQ+EkXBkLOYdJRdLbiCPdwZB6M84VKG0nWJvFfhFTwNxZgMfc4xn6YcYWPl6tRwVXKSKII
#3KFJmuAJ00mYEhjfFu8Z9isYTnsLakRpmlKcy92Kl2h6y8gPs4kPzdjg8+Boe2oLvpbGQPSau6heKwVJZnSslSusdRvEZaQebDJd
#CMRsXkkWT0kLirFfxHp7xb7Vx6+egTSH5QnYVDYSHmAcTNAwYDIUUYg6dTTO2HQ22Jl/HlFVev1B7c5WLBKxwue0lzNFUKKGHo9s
#ene0JzPNU+DWQDqfhfqAbCxEqn4YnrWCVgYlZf1C0rs3j3dImbUax2BnBLvIpMc/CdObCwlj3WEZ11GZMzRbEw8lJAaFQfAGJUWx
#sSnXMe4UWz40skm9e/5CeqpOvP2pAVyAHPDY7N5/eCiRdns8zxJZCwQT99DIhN+gIxeOrw6CfbwIDaemP8tYRxAEKwt4m1OndfxI
#ObY7G3J9BlhgfIXLS+WHDQm3wOhwT5FgQX8zhjDhon+9XGN5IxIlddijC1t2sH05JYNdhPABb4X/eELm6p4AfEY8SXxB/CSB75nG
#2GTTj0pdiNddRaSugxYq9+fH4IADnhctaop96/C1wLX/6YXfQ4SsZ39hW3lTN+/Wva2Yut0h3qMB+H4Saw0z+u4L3lImT4pdhgO+
#QwUgDk/PkNX20emr83MtrLDU9qOVjwtkgBkG/RbqyXO+xKXG2PGEtPujM9x8bonFLnucg3/CK9TUludoHvGVZWUxP+uSeX8i5QDR
#XsnCKBLHTnq6YV1BjaW+oVi5Q8o3gG/Sr8K7qGdWZ4mr/inVoMQQWDGPImTTppiBBLzvHCMD666eXdl+wdILXYAIwBjChRgBSEDo
#X3tPmjgOLt8BKMgBnmJ/Qw0wFLUpxHy/dRFcWjoq5aBIZozHs9iYu0m1uKOLJL7z8NRPJooXmNyW1BzPWAK3nm1ZixU3K9bWt5UE
#ZpVb+rNc5Kbs1ZVTBP8S6/bidw0CqpvfWOBd2rPVZyWAIcrGJcKfLoOlu3AgJfKnyBGP1uSczhTuVd37cRT5iipzbfVXPf22XFVd
#rX44jbmHIyoX62vAemASF3QnxRja04lbssBHIC4hz5E0dieJfq3gpd0utwKUdH8MYWbSyzHMeh70W1rZjLHyMyde5nuCKi//skgp
#zek/UQLV/Kr01Yv3JxoJfT6h42LBdkK7D8m78s8O6A9mP4eJla8sSsgkFWVtwoWvQM6+wJjSxXOuXz9iwraGYCZPW0/cPF33z2Gb
#CrJ1TkPaI61ZWtw5hbFeYuGJI+ZG3JWUlOUUqq3IfDmfhrNg/RODz47FgFkx/0vY6VPEF39XMHfxnAH73qebkKv0yMqX65sI6yMD
#khlxQr2cds3y6h7bk5Cp65sYRTLELOiaOzeFSx80cehw7cKqjtXtCt9pjMYFbl3F9W08BTB5xY/7de6hdtKmLJ68UpoHOsAGMKu0
#JmWsbRozU1ZNr5Z9AtBAddbg5EkvcasndasGh+jzgQD2Ol/16q1bTNRVWUOPUA/e0rC0UlNCEt2My/yyXDiH7zOZcbdu/bAr7jsV
#48w2XW5i1KIHYOLN7tXe29O/mbSnQVwyo7bkUHyXRu+ADnhedu3da1Bg5TZP2ixZSc9cJoARzKhx3KbpEvbExKet9qatUAyNPf2J
#bZ0TS+0bGgpmgDFMOguUXK6Z4eDa+pf6ydoJqDuq4J388AMpIdiBHoD1oyUbYCtA+hq9B23+/El2FX1bYz+bom5fgfvUfrNITxFs
#0kSpOLXr/n5+NvpmQzmC/sQAoz1zjCzqgs/hnyGfEkn36I5bxhhpFPHmE2eosXzuUwRwlEuyVCeOu0gb7t/EL3PP7Vez/0gMF8wU
#mehdlDBb1x6wlOEBSZjrjw96sfOlVBRi9x5CBMONGGpkmMfgb3v4D0IHmoB83IJDMWjarGxRinnJxINyd56XNQwmFXZI0wPtmYmU
#JM5Iwwpu0EcTsUlryUkVbkELnc75dbIdALlJj9pt9TNaynvq3xSgxHxnDcIN5HEDSICTlq82SdIzTamiAoAI6zhq0tNRKXRmq4qi
#pLaiLivA0U6782S+cGX08LOsh613hQBuSmWThDiFNqYN7ejuaCuCHCgBsGRWvvBeZgL9hxHkX7VXvLx+Bm58k0IJ37abNuwccILU
#urkECaYXmf/dOj9VDIBIa7zkhDsJeV6rctzDiALHQcyFIizZ1GL+qLsFCxqaHpVHzVGlwMUekDVY65cZhUfgvzauzr3E4Jk0o4t/
#T1taheWtJEhW8bcMiNlCLjGJMtLUMqlSxz6gYNoz7vpU0q5II2MIAcoh0NvRRGlFuyOzszRQ/spHfmq8rOaH4pk5l9L3RFqcqz95
#g1TyR3a2goPMh0OrXla7i54v6HCRlgrCK4hwDULHcFbJB42mTNCDRYu3RH+04fu7AqYbYLfgQewdeuWpx3X8le7b/yDUpRVJdnQg
#dhnjy3uosbCMDy3x993Jex+YxVGk1ZhNelnGIEbdEv2jJLGA45mMdKi9xSh+T9nzx2w6SwR9c2dEW7lbtRrZdWk671avYrXufCM5
#dq1PQ2/1UuhfR+zTqK9094bGLlTkNSrXRR31rT1Lanrz8BBXhSbACHSvZ9OpuY56oAgB0AEOGnswlY5v9HSGgQqQhLBDUgGuHdl6
#wQF8wS/ISbmZg39lwO3D31mmkfrwx/Px2v1ltpoRi+y8Orvy0FxRHRkQrRfuqqIQ9sYsNJFv6ehdQNebRTS0vNo0q770ieLeVDJe
#AOsFiDwLsOuKUdXRUy98mvFO0x9twpZySWftlkOuyxz0VEXS6RbKyt07L/NYXEH2ioVUtCusZctSxGIKn8RGNLhchjheLFWJPm1l
#HKCISZccYr9Xt4UzP6rw34Bkgu36z4anMcV+WsY5L6IAYMmjHDWpeSVxLE8KDjtlDLvd/dSKItEq6ejCHNK0XXXJvoQubX2vuJX8
#6h/IqYCRG9FQT37DTCOnv4k8Q/FHvI3OiiN42Plb6qzGim/G0t1LSPDC7d7h8qQcwlqNg/Hw/UfkNVzvxt/Z+izbRs6g4Rm1oyH3
#G4Y7E+7b0lDE/s0i5XHy7eMMrSvpUNDNRou6fCrQyFMhvlrefGx1n9h1RKCqC7dX2q8ZJOcY1spJn3+PmqGvwXD77CqYqTCbEKSH
#1IRd3KDIhNR+5lXPyYkar9u8xrDQNnyKD37mrWpDN0Q/kh5Ln8xglbfL4aNExw5eOThDPqughUxDyktLdowpCCR9Bl1NmKBEoAoO
#dfnE8es/XM34hG8hkCOOe8/uNtLL0USu4xv83cnKgB1IApjseVgemvze+7xIQ0vIyHYn696pEZIZeQ7NORAwqvzqUNw/7yEqml2O
#lQcXZndXwvwL+nwoWnpEWNbWO4JT/RP6lsT5/PcVVDZmYiivSXhbx/vPoarXEekBnmss5Fy8kWTOOnZv/XX/ly52jIimyTRonE0x
#zlGNAsdBBLYCjBjRvOMAbNvY2amXPSjwC7gNxkpYGA/L7nA8PPJHv+E4SttFJY8iSuDnWaw5ShjU+pLWkDuEAYCQeJYk1S8zz6en
#8lZc6r1xahmBlsqOyskQ4ZMQJIjfJKn6UnI76x9S5cyfSt6ZReYiYL+15U193dVtzYoUsFZ6N2v52OLC+iqVn9fOL1Hupmn7ZcW0
#EsQsghSKf9ULp2cn27G1pnDyAU4NWEBurInjrXBy9refrwJ4AFmQ4jIDAyyUAZYKPWsV0JtzAyCZUeTQXlWRxLDCu4GXqjrqJkzq
#tLdQ2yFe2LBTxLpbAYbW8iD5FMLnoMEPO1MPkS20/x47Cxki4XsoK0YY6uo9ZD0KTSUsyvpVYSjNbU+9I4Zq8GiiAEvTZgPNKIXe
#G3F27y053BiBVOZvmC/EQsx7JmMY4QNyWKaQhQc/1AJBMPVMH+PyD4rAajT7rWDALL8RB02gxw9CVsQq7EMkUYgfw8booVfz7i9L
#FOG4I+Dz8af8LgS4N7YQfQgdBHDH7zS2AzrPOmpFnbzkXP/hOfriBHxeGh7IAZYk7PlYUpNEAdapUEVYQveFcSpAXO58nVCylT6K
#jP/eTT3iPZZ4jEoLxm9dR2HZi5if+Wxq7qnPiYTAdrkcIOVF2TySoSX6JeBBT77dBr62kK6nKDKQ+Zmw0aLuqXY/L1IcX0yOxchH
#H9tPFjn10ZlfszvRHS9kabfGfRMcgN5ndlDJ/Oqj6Nfroy9d6dh1kyX/h0A3pmNGRKty+lvv4MU6xzG+fj4ZsAD1leRpfzpTMfYv
#UCEO297oDXBv/7z9TFrn+U/dqg9jvWCiLs8ftOwocLIqTSI4PskTXkZsE0owTVz7N4IKyDv8IooV/eK69r+6wp/Wn17W21Or1FLu
#FsMbuFQr264nLdVbYuSZooNbkpDESFlMK7D9mHY3y+W3tKXIhxfEPFjC0RV6LgyL6GcFKeM4IS5W6CGKEE4LQ3njStIylTTMquiw
#x4q5RuuzH6B8YYwIzYqgswmVKj7VUTvkl+K7aNFzNlolzPqcrdzMAGuGgn9kjo+R5po21+KuCxC3G1vMUzHV/Mhr7JoLT5oT8lJL
#ckwDk4yMneNx033AMzvNoKbG4wAa8uD/+ImQljNNwv1oFlcP4EGwoJB2Vh0x5EQIEydxfdNJ+vFqE6bBwvZJRPmvTxBDEeqCGMwG
#ZL/hAU5su7TbVSyoGf8OeacbL+FIlVr7Aqq3EqeaiV+P5so0HLWNDZOm4gV6gggTpZ/QDIjU8qn7Nyip9cjVbzT85Si22g1jubrd
#38Ek9zSs8FR06oUkr9EAOOVp++fMBDlgCsHv61YnIpKmkCNmFbcVCts3qWBHYdGU4467tmnRalmyu7qMqYo7ZTSZxw10aJG6Wddz
#n/uXRvFxsnKz2M7vaR3PlrXXoJbc7DhbidX9fMYvZcwvNOT2xFPZrEMNvctY+0uaG3tKVi/qcvhJNk0In/PVj05+bljuZC9OX9X/
#Ou2H63qu90jXJRe7pbMncmJ10E83JJ/P4lc6Vld7JcySPEufDPZ5Spvult8onRchezJA/uExV2aGoONzHsry9kQ6Hn1jw9lWZOLe
#OFP9dHKO8Qfd0DerUKhy02LO1Gc8RHjyUO7fr/zF9gk0sKLIv5Qfu4IOlvpHTrK72ytt0s+6koUwVsLb+Yt943INom84fK4uK9Rf
#tr2QkoSNiDiFoEB3jxTXFtbqkrFswTrepjlUFFBmXNRFjQtgQmgT2Sz3IUVnLneZNvWZZXFI86rH2TeI1ZCzeNwpesJH6qj2qfum
#H8NwLh/zyh46NHBmHPgJJer/Z0NIcYvcdrPQiROpqpzUjoXQTDNr1jHpA6kyapdltN9TN77PH+p1ejSc2kui2Xd5xh7dPLNubuA6
#knpWF7c8Dp3VJI5ZFe/qGVs0al+rbVeofVWbxS5dX8xo1C1qlGV4LtrpVR4NmOuZ5T5ql73/BtL+QeF4XpXLHIrL2yOX4HMz9fFq
#d5l/VQuZ3zg7fWAz3wQhj8Ocx2n4LqzkmGQO8TPRiqQuT9qu7Sz61aFL3NMsXe98r0p457X4nWD/a9dKymQ2f5duLI67dMsmn7FL
#n7x2zCbLMp0R95Psz/qV1roqr3wor4Sa99MBPhSDeNp78P+QZghCOCCOq2GhML4KLJd5sVK7ovbZo6akgUhFeGTSRcs97BP0vwqk
#dJCU0YcvxBjq1joq0PgeCcyM2pGmzplEOBOakHq0O4y4lZmfwPLUBdEWN1YlkVNribykJpgJuneFKJXxrSCT5j3T2032A5kiMAFc
#MElYGxmow43M2EnjN+3Iuj1f2xHe1EAFQOSKqBll4uVRPP35e6jleBtJOyHxZQdBPrHEPza5sZWStqbCkkrRgWFQRfCDPJxuu/VC
#Bhh2ecsYcVuOxVedyPOuFc1q/lSotgD6GS/oLA/C2isN8E+a9mYt/c/TW006hB9vva0MCustctM4hZh29hDLOPoN8wmVuJUi8gUw
#wo8xEYGoFMEPohDnXuzKNKTq+gZ+spnbvOyx+5WPOJ3X0VXM6mpGN5mk0/4LIp//5jFC53ciM3OnZNH2+AmrDIFT+2RnfMdSxKfp
#HCD8K6Pthy071LvdoVN8xAeNm/QfULizSLkwxaHozQfpvro7Xz4Sitlf7F9CucdrK1ql0XZh0Cl40aVPujVlNqsQLMRSdOVojd6R
#zaNPsccfIr/y8MVkX3xOmvCFESPBJwg5jzLKp/x7SNK8HfU1Som9pPR2El0GZcNtbQFpfziyXhc8xd5wodLiG+sIOTNKu3jtBHq+
#QYdmhvfj1XCn9Ddpy9jDeSbezFOfbb2g7V5VoVA6DbwJdYxnpb7Fuizd3W0Fhb0t5TQvrsffHrflYt2ofmo7Q/4H9YO32MdV3xzA
#3kPGfv3qZ2/rQXJJGaa32qCfTMqGhVQJ44jQ8+2hHRtp0AithQeO4suzmHMRBHaAAtThwPcN1gxdl2BIfiiAEPClvuLhFvyPy4Am
#qEUaJqT2X4QHtyNRTECy4CObADax87Z40xDU2iBpi+hAUpHeRh+OthD4jupYDSbPKLe4iYVcJ54cphEDpdSERrTbBm55/Wo5lDaf
#VsOElzgu2wGoC7G6WsmXwS3OrnfTnVLy8PfPH4YK4r/wZsVtW5nPDEKPuB6FN8NqH/KX6PL+5GZbH+KWgdjj7Wb9fMaLr6625JgV
#x0fK1cfkSI2jyNSqyJqHlRiCEl+pzSM0WYZOfmuhTlPzt8nTqnIJBIQrUGBmPXUc5J5Bx1HuNqtmsQYMuoD7JbZ24IB5wIsUVh/N
#W92dBm+YXljcHKN7tIRMmRMHg+HZiW/T0eKRtQqKWQnmpMJLRgl07kSkiXWoO1JMw5KvALck+ZC0VuTh7EWZIwYSPxej0Aaq7c00
#ROa+V+efZKYdp6uuwfYIJ7xMgi2yUJwzhuT747A9Xpuc3RXGA78wxZ1u6OGJTVgAofgQVj6yLrYH/hk7MUd57YDZurHQtcmJb5Sj
#dEJFAOuOa4w1hLewiBCOp2mQ5BIEsnlNpfsifz/fUzFh+grAq7drFhaIFWugQ1X+bjE1ECJnci2ggy9FPmUUnJ+HVqf17v7vJkEl
#FEngLm/1WX8Dy1/3jT70xHGurb/LmF6ZrKQ5Hxe3eGUsXAKlTUqlFN7mo70YuPy33dN/aUCEfRIl0CAMiP6NEi0Y6Kf7FzU2cIKs
#AjxvB44R6BXECk9LBDC/dLdlNmS7j3n0svEynyxTIhU1djWA+RoIAsK8QspUWsQ8xQf/Hpb5GKtKLiu0o7TgzLq7hTMHU0bXurId
#MCzo49VcXlRCAXAE6FwBCsh3QyxU1d1FFb1h6AcyoodBxk6ymU851VQpAdTLKNimI558tvgCfO8lgo1SWcuvXzCwlc2PteIFL4am
#X9HaAA6CFj5vwQI2ZXN7WfeqEKbFjWHACcdOcP1USmSa5744kGupWSSbFhFy7p3beWPvB8GxaDhFARtCRtZnGi9ZAWJcBzQyqsLC
#Gdg+g7/zJ03MepGkwxKlcROP9Lzkc/LiXesEaXmm8Bfh4+/HtQ4YHxw9drxV0jIbnNCGxHZjCpk5NldFk3JzSfhsSSOPYbekAL27
#ux0LCyZj1uOblDyI8Pp9HlAQ/9bEBjXD5ZreeZBMUwr4RrdEjI8EfUS41LS81vEHg5/V1oce1MrSN73oTHKWkatJnTxg1Mx6HfxY
#sPmqWIANQhauFvx77lfq7jg7wzmHs1aXS/29VqDyfPcwUeO5f81OL8iXYz/lS6wKpRp90mIKIDanNFnIDglMYCkpBLCVTEKE0Xr/
#quMgnCcdxgzRf4yQ3jfHuqeq+coVGFTqkh5w8TJnkmnTPXmUOndok7tON5XitcnI3d9Hl/uKQ8L8LM78xIlSo0iR6lXK0sPsvrpL
#8Tp1qCZcMk0mFiwGCFKvcLP4es19kmYhmdVAiY1RaXZXwsJuCyjuwSWZYjCzsh+Ut/6h5TlmplzZV/1hIx+EROkJSneK5QsxgTj5
#Ohi6OS2s7VpDodRBqdabrZXJQG6HddnqqVLaM0IGdEQGL7Zu8mK2bWiQdJSxESO/wuLwaK1W/Eptyt6ZM1toJCWM+mfmL22sotIJ
#KtmX851oQg4MGMdseCbROLqruIxK9faNoYuW7KVfpoH9qyZaTLsK8pGfVSQkX3tSV1s7UucQzgotPhviguE2XOx8To3dHpl0rS25
#WAmleaSgRNcl3ST78wEs43yKlNErufawBBoi/E8ddQakAC9AF6IGkQ9SkLHJ1B631LaueRPFWq+iTgT6rLJTQvlOlGjRzgHc33kf
#dVe4itFGu33gJK8ezuoZFSQUyqaiHw2CXD0rcElWaJEsoqfTRrH/XS/K7/3r/ExXqcAOkl1VdGV3B52J9BvAo9l1eQnzmMVun53q
#2dDn5++t/dPX7KwuPj74aaHtTavuOnVDXbSYamq6eBo1apRwanJaPJnNnNXNaq5SqpUULEgRkjDHm5PzDeKO/xbpfsWQnrgFk8Zc
#dnW0V7N4VRVjpmsbO2fzObu0nhX7SZWVifLC17mTn0379mnCCVXybTg3l/rx4xRq/QWHpB2+lMERngBr0FIJsEEoE+JAH2L2a+uH
#CW8CnACin8f0cpRSAhxZXQgw9HaYRgci8G5v1IMQsDBuZTY4/B38kVs21sLIj2z66YqakfUKHoIk+/iEgZMLcXD9XPvBklIMcXpK
#CSUUtdOTIKSoYFk4XzyXrNyMstncfFrdhNrcNKtNjvKbbhJiGiX0RZRPIcOphgyfEQFmXt2jHYvpqIa48mdLMWliUhvgKjFIvBe8
#yk/5fVrR4JgTgeSzSxImDE33JA+FnJ0v+7VJaurBCFZo/Ankq0N2OBLbtpfC7Fa8sUVNShGmiHPxxOgqFDhMAfeKcY9hB/HSYCEz
#NPd8DqoQQAXsV6b73LF7qlStuyJaVSZHrqwk4QfFffpzMeOLqv3nSL03dmztpibr37T7/jDKsgbiUu4XCX2QHgt/AYDg700/+m4N
#rSLoAZ7k3sxSxOA0XrWJ/HV0LIWkETdPXc4uCy9iHn2iTMJjTkRJx0CnRWXjF5ibNSYlnfosKbnoXC9ma48crJtG4qsvbYywKYO0
#uPniuClMr9apqHzCyXlORwJPIioBIjABMrrAOkEyvRUdhmcngHdrJ6Koso5dMHy+tOgbaTobmzeKnDcKnCfKrLwXQfgnQI+VtRPA
#E9OPIproG+mCSJZArTcD+3Lk5djrATFXWhyetBaj3Zsm70X7n6Y7GTVzLePSt4rl3hK0ED2ECcu1OBorqPJWxuhAF5yssZFtcM8D
#ZQ6v7VxJXxK3uy9xwPhchIDtQvSEDXx/0gnhvPb8qxB8VX5SLqmax7Gg7phXfwSlz7oYEVkpAZXlqODbwKeBLzNs7ecNr9KBwrXo
#lxqKMMEO1Mf+YhuNn3oKldDKpGbEWjOU5eeqlTymVRPnqrFdL499gsy+9VH+s7y5jPh3MGQDxuYyQFqgubpswO0ue06tLS/f9xox
#9AZ7v/VnqUh4fyzm83D8V6otrnKO97DOKf55ysfB9L50XluAI+pu+HL0FtZhRjuK1B17yNIpEc+qftgYuyreNbYDJY1mhNdugzRU
#vfPmskZgmzqHqy3F3XBih43buSc2vE3sTvlnldz/2vT06sHBv027i435iwy4tjsGGPHdjp0Zv3iePkBFkMuWLtea9+Y+BASqq/dT
#3gcgtgZ8gtDIJ4A2YE8z7TEQ7y2kXo7FKrgko48b2rDl1XcOpNn8owBB9M+QBuUMsCt29HVdtOIRa2crJDd557PzPwvoBduR3+vV
#+Av+kqN/+tCz43i861Eq96+TWxrX81p3np0IAWrdsPadk9zpiEMJnrBiKNsRcfuG5T/JkiWAvkX9qt+hzuhpTmMfkTXWKY6y1+7V
#09NCdmnuJvgI4cUQVNVdBCaoZ2TJJtTfFz+Vx85pdHkhuvyrmst6HbngzgapInceB6q8PbkAGlMp4MsgJtUP9tS2TfaKA/cY9EDV
#OPfmBvn3cHq801KtteYwY+75VXbTgHVJTvQAR7O4lNzJKUXMqzwICMeWp02w45aZyNN8REe3WA2xkh6Tbp//l+gsFlF2GeyIjLxZ
#bX3x3Q2ZH6I25sGu+9T/CdHZaTM2RAtHoPNMiSjBuZQyKWCbOolpjGvSk112RMfjm713zXak6se+gvc641Wovl++PHVGl8jhgUMQ
#d0doS0+ldgLnbAgA802N7+vi3FX3keN3+n6Hzr87q/8tD+3WTQgADoFqlUwBQd0IWBF70tMbkBmP95Zrl1evFn6dsOyq5VW6/Gxq
#ar1pyRYU7rNnOAbwcViJFIg4ALvXVcftjJzfJ6fOqq+QFjQhmu+YvA2IhBVAXKzGvVU5V6cNRBLB3J8M7oF9LRIyj+NMChuAcfhC
#t3hCWbHgD5KBRUnLReQT+4XbzRNjlin/n1WU0ILZYwDq9lUSOLR8sDLS9vd5lf3iaCQu8t34im32RcjAw5EyRyHdsYnNtqFPro+g
#BqzSRPqs4Zcb55kfw2aDBpCyQRUwI+8pwJ+aGc5UfBX7kyJO2LVJm9I4gSoxosruNjzTPEuVIefx+cAVIxiRHaD331+aS9EkLNfj
#ZxmlpzdO130dR8RA/eSxo81l9sgjl1mob0xTl9gWd4d+6EAsCvlsfcfeM/kGFA902jYJajXtNlYnkRfmLdQg1YjteZaukDgolMmg
#1JbiAPFRCDlCKPGzgDlK62EaJHFb0M2D5pXG3mLVpryiIUI43qgb22AjP6eba9Ck8WTynBebYylJ378Tv9caNqKRqTIaUaGu69iL
#ga4kWr90XQpC/NFZLtzG1/AI9X81Zbx0sm+JZsBI2CZQFEP7F5HuGrZteN2QBN/N9Hwva/M1/t1ERrtAZoaVvTRKlo70WsdNh3Ly
#zOUiIxLAq2k+m6Vksodrhq9tAWHCcMQeUHXWF6tJXguShouZUGHF+dQ0uhYXpxwV8oVQbmkkFwVXbu88vaKgGh4wult9RDVhYhFt
#lLBy2cTcmiVrwi6IbTXsh0KdpgLl/EBrqhreM+yDABEEwmaBZbXGoWqt4BoG2GWBuiZvUyhhhTgOAODp22NpZENvPwFxdTUZ3TQM
#ZzZWSA9xCjlDi2BIjAI4r02TzK79sjCD3jkM75zADwPvrCag4ZJck7JRuNl6LUkPnOncFwOHkvEjF0AfZ3j+ClqjuTXDQQMn6Rd0
#0zVg3wuujjpQkM+MAKZYxbakiG1cugwV9G8BII94dkxW8dVfR72ePtMxa385kFf0ypRTL4nt+INSQz2VsRlXJRVYKNgTlpQQXApn
#Cs1BqMdfHmvVrO0E60XWDErFUjSxsKzHJDQtiSVd0HkTA5VjAfb116Nlsy0Clt5UzPOV6baimIkhIpgqdmUQiBx8sExk9TWQaSF/
#AFQg7ZQND/iDeylf1SNKVC8sAvdJAsS2UcGm685FSdR6Cb6+lTaqBjPpkL4Bfer1yYdw4vPnSR8c2/P/nj2+n6l+HH4DQu9EAvNH
#+G69koomzXeF21RDFKYhZSktt3yTru9imQUz/0CatiYiZVFUTxOa62kcv5JJQO+Ds1GgRI6FF1oOtHHwCrMxzfFjzg3YAQeAnvmx
#RMf8q/+i03c+HBQoHQIjCCE2E8LjyhiPI6kjvKs4XW7e/jdKkxVbLcZ0CKE5Dxp2kg46sgkEhKpPB+AV11JdzB4vGZm4vbNzjbRV
#PyBHuKfYu11wOKL7BzgvOttSwz9dDk+PZ6bcDn7egwJ0LZ+X54A3kGRaj4TC9uo7IP/zwgIWej7OKFSr0kGyRCkBuyCtmGw492EB
#NLCL7bE+Q5k0xMxUH/OK3BLhBPqEwy1YRmvz0XURV2lFLic1HX9dU/2QZQdx6i6JavmksWZPUONZrojhIV11SioMFKByAP2G2c3A
#+ZcNORCabIYiZNb/yaTP31gHMI0gF6gNffV0Klt49zAIqTyKizCfYlyMy9vlnTNPQge823jYd9KAxFCsJsHTo7Z3BesgA7kM3rd7
#6nSLmWsfdIcVdA8BIH9afyMiJHpeIHEVNoe6CIglYXNCzD0PK3C8lFx38vc56dWLr/6GEzT8L/3hMzKTjIFS63mSCAkCqmcTOKUY
#SbI8dUmJztkQKgDIMwHM09VvOP05nLBhrhNNmWLr2IuK96lO7Vu7ykWb8ofOF39cIp8SMczHQopNzvcYz2lakHNfS2USVJqmKhWM
#CUFbkFOUUvpjndpGgFJg/tnFe+OsepQkKNzxepw2v9jhJ4c9axmQdwXYGwLWyoTJPwOV9KSa/UNKIpdSZvGTxv7ratTvX+fD1PVq
#QsueIqEt4kRJ+mfPUTZSKpICfQ1p4RlYObLDp4PX39XHzy7ZeCdMrAXN2Af79o7oFIjMKOhd3TVaXdHvLPedRm1UUBRFkbs7Cn2F
#gMu850kgNb2z2DVda/Jw9qI9r7a5eM7C17n4AhyDznMkPSSKmsi7z5gwhpkfBkITCtN51VtJzSoQKoubTIoYIIcJZQM7HVKAr5tW
#CKlStV/6LidTVuRmZA2o9N5r9k4ZTwLnOFpOj4NZGKts83OWkaVPVW6aPgkPHCygR0FyvHVs/7Id07yMc/mZ1oKVs/Tqfu5O5xpN
#2p5pIhi6Qe3oZP6FuYNV5DNFFtRD/alYxgOf+FwfxO3WbV53rojj0jq29DWtnJWextO6Xz/yKMdOqYkSi05+dJlVcG+rkLXXZCI8
#IXVE25CW0HphpGKEjxbhQbpdLfroW1hnBmfOVcv2HIGJHY1XgFeSVvvptyNt6elBXHcStHReXkA5P+/PYXu/1/f77cvw5e9rg6z6
#06bhn8z+AgojDAR2Z/l2SLQTJ9++cmHKjpXS3GYWy1jYNlXCBZnB+JceD/VmVae5yb8ZY6euovKm/iQr7Fw+1c5uwRd0ybfCXdLh
#FDNWZ0dSpIsuXrwccU5feSSGRN5ju38dnYXGO6W22uIE+rLitWufhE9763KxeDl13Ee6V031wzb7s+hXFoTO0sUp60eAjuVs98+z
#2+vlx7uzdRLqjhcbvMrKr6EqbOsyCzNW+0c4ogO7doxBPdLpapcdUtYMHcZCGLT3/mO/0YAWgk+nNHDeevOttA96dtjNHn+N/I8g
#+EaS6BM2wCIBjMabzR8xAEQyszsElPg/vSb5FK1pvlKVxK0r7u1CB2b9k0MsOvPmEAfgmKu+jt0F12AA5gsoDSJdjkPEPvhvGMSH
#D7duJf8EUsSqP0iAwLC0LWXGvYbBJtC3jLWDQ2q99+fMfWVT2cmXMMZyN6TpRiVPaVfuZRDwuJWaInqVPQpseYjXcfczdyx4Rvxz
#5JeZsmEVe0S6TFy4dyFOSl5jmIURoUbMl/XF/PCKjDZFhM4lj2pByNEFwS/Vwsx81gefrlFwmO2vfOWY3lDe8i/EnAf9sJlmmmVL
#WAIPF6SXU2i+P9/mtht2CE9xz9hcxxAnjbdCNXLLS1KwRQlnhfgp8/Z2yFQkAwgYnb0IGHo0lD2CGxKes3641Ns6DRTvCaB/WJjT
#6nrZnur7Pia0WUM9Ex/92jVnan7LtsCXHXoAt6hkMoGRYyrVlr6jQheOhrhHviaTGND0RJ4+DLu1otfpvd4w4R/tlXwUe99HMcHi
#R+GHHmaOon2eQGL3+jri9EO63HJjMhHGDxFa6K6JDyr42NjBA1jqKmNXZAOuQc0B1hocUNUo8ytMqLEBSCLwLNgKheCV/MQfaC7F
#CW09fpY87oI700x+aKCbzlm2EfG0tSNb9cuhrX1igrejjQ3D2cKNGG62btcwRo1EPYxdP5jvgeh1tzlbW/2UdEgVPJo480t9QYcS
#YLRkTV2Js+Pb6uQLKdh4fTGtrmRQrKfbG1P1+nmabBnz4+qO2M/BlZmcPPLAjZD89QKsHDqAjrLMyFC8aVr7dDJtMbaTZT6gfurp
#fs9pB9qafenf/0WcC/zoNNUk9h9Lv9/1plFGYOwUqJT68oCPSQrVXP/idLSnrbaQ29hzHSKoEfp4gygdhMy0CDWFTb4K9GcnQPDG
#fyAzQa23aw3fWT069fDdKJUnkwXksBc/o5kdWB2IUX1pwb58X5kEFra9BQ57W3cmlnPOwAN03AZwQzYEP5sJdcCpN0vCmeDPJnV9
#XU1zeSZbLjOMVPMCcTE9xCQ2rkuwhAbBmlxUA1KNPAvrYZwRHy+vzlnbi5TLCJ1Rv9/lq03T/mxnDQFOjcyZHM5utaPUFas17pvn
#Ntzj7JXnb3y7hhN1beHGNWXoMFlhgQHGsk1UsbaXtiRM7rNv8t/AHPL84n0t3/k/TY/D2+vx5mzc+Gl7kWcp1ruknFHbh5Chk5TI
#xObWhhhZDvUx4Pm681fdEgEYkjlHCODkboR0Ulm4OEonRoOauV/m/nk7Q6YwAruxvNDWmNS9CF4jdjJdZ7MeQj7eGHedwhPYhfg6
#ktzhrYQqelWyXnVdmXVpWZ1MF9t0tgpoK7+zOLlT/mT0qfV3Krc8QKGBjH/Rm9iR/gg0DrFmBkNJnFfZB234DXfSheNpRlfbR1tp
#TCZqr3sEvgnVCw8RKdktcA4GC+YGD2IubEdSxO2wNnGX2P3WOVQ0ulyjRdNHCNxsJ34q1Bbzn3e18+EeJozRL8yGXNJiFA6X5nkc
#DQXFHdPeooJB1NmNdA+az6xwUBUMJYvQtKrTY5gsr6KuSakw/Xqw18l4/fg2xryf1E5TE21OrsHeuXMQeDQHsBMEDLeHmI9qu/X1
#e/7SyLfGGSTlf9ihOpr2QgM/MAcRitQR7hhdTWn5spw0uPu7b9CVuag3fBrflZcwX8ltOmPFPk+B7HEU5+0gkTvx7e9ZLpK2tRkZ
#OQPEv9/vZqfPT30tQfvUO05ruD0Ugie6atFrQmUD1yowjLqQvlDZJ5zdaHlaZtefLXO4iAfnLVrSddB+n5myUcWJUIVDOH039L9J
#zzCm2zIxDyXyyPr6dXQ/SN1l6D7I1+usJ4KChBP47xfo9CPYqNBmQmCxxTTAlYEdeDo00fXNs+o70F0w73din3CNh1UvzswkF6Eb
#krI53y38WHnr2dvAN/+osbD8Y+YBI8cW77cOlncNJLOsXYM+3+eXJ6/1ZhMk+QXhMMyn817ohoUsdez/MzkJN+4iyUOB48HHcbhv
#JRxARsbDOxgqZCwdENjmHH5lU5Ilk9U6BcpYaO5vD3hB/60wE9u/6otQzJcyxNvqM94RVLznTzSSejwyOb4i9qccVerMldGKiJMZ
#jAxRUv4IHCTF2SIwM4lTq/dgUd+ScpzoKSf0Kec8YXTag+3ORr5+kzTaHvjt4W/cNkm3WZfmbiPm6muSwbXd8dUnRifZiOQiEX4r
#3kL+jXK6J8wfQflk/ttNo6NLx7vR/IdPEbjHnixYUce1SkKeiIOsNGcpKtWZqLyHfc1tfqBq6np7opS4PuY2W36M66N6OQKw26Cj
#0b+H5/Bxforv/0fNN/hLA1VMACVEadrPf3r60XAvlptFgzzXjH+jChDu8zBC/Kfq+tEA58v6Q1vVUV+fJyfq+OnxqZAy6ogVYz3R
#ws8C0SIy9O5udNAaJiVHcTQRN30CM+Fugbfodk7KZWnohotEcvlBfUCJT8LEcwxAMBLv70/YEXeftdYwspZSSO/nnR3yot8DoKej
#x+PrEb7+oNWVRQpYqrls/mNfvE+gJKloJiVHiiztwHPoUnrforZn1KpTHpTY1nXLVsfcffQ1HVcEMBf8dO3hvmH674PkOTXR6E1G
#mlT1ZTuzlv90+vg8Zy2YpYfVipS//fD6Qu17HKRQhBPmpJ9IeQzAL5VxGOvgoW90aWxfl5tiBxp77o39/Wr0w6WXeokkx9o6byyO
#nTnefizLVlEmS1jik7tLwOiFE9xERq0hWvCQbz15orUWr2uBmd6WrUDUzNypzWlqESe00Z23UmNqIJWWHTLLri35oXJbKWYFpQwK
#PSNi8DkK6LLgIso1Cr6IrMXqCElHfxHTGASB9WdmKzXvqjoMIfkUILz8nt9/x/a3oVct3V6hFas5+J0RMX8HjgIfiU7m6ZdY09s9
#fmsvMwbpIQkY4YcbCLWPwnfXN5o6BUsPj/xoyBWdWDvfJmPc1iLFl27CVQj+EMgJSPcw6LOc1JXvvhTdGt4NNFDHLdjk2/8a5Oua
#K9kL7P3y5od/N/w3ztPj4aSR0LoBABmEYEAgvC8cNHlduFV+6nFz5JviB251igUWH3u3lJqjjaQcmro3BNCisa8se9zbajwewL4B
#/p4bNNGfJH+AfN8FfqqfYXQ9l3CSFvEUHP9SjeDkFYHzHaCDXlLwT/H+e1J5UiuX9OQ31esBwSvjC3dhfMg7vtZd99qv4Mnb7zZI
#pLzZXm/L9pZvMCO/cr73tO/sSUd9/xKII/hriR4Nch7Pp48cXoPd/qGTZvXu+g11/whl/k67js/9rvFr8Mv/GT2vLyUnXRn9+E6y
#8ceTZDfmx2ivz86NX9w93ieQTtk97LHZzpAPdblU9kduUHny+b0a/pR1Ti8lI44J3feP0cTgsq5jD3mTn8lb3uju35Llp53zK5Y0
#v6NwFyK6JIFZkphSZK7H7xMJH2YwrkrkZTJzOXG8tC6YMsU98pQCWGtPAcv0sOzqbt24r/wLR1fP4SagtyYV0EE/N88kyPdcuUab
#maumDtba2dI+jmRtIW+XstT1JQGopsbGBhe9Bnr19nYO7uaWM4v6aB6MJMkJj9Hq6EdmM7NWQvVYjzdYLWdL9Lg47Z5e/uX7yg/J
#q0uSXOUBVupL9MqemW0bvvG/Pop7X0cxCvL9twlUHp66f6jOl0Jc9LcPElZBZ1IT2GWXZBOQLG4Nhhbu+PKBpPuBfOAuWh1j+GTT
#77COHfcTTzkGLOCRGDCqiw36yjc9pEsqt5wczdPYEY040Q2UrOAdN75IWLAyq8UHA+AO8teFoBP/xoCEjlaApAojkS0vgcIEj4Hy
#RCLJBgcaBguxUoYWOSViA7OssHuCdgmsZ9cW3ewPFMjkG2lUp7Uu2WTcXbdYJvcKdW8MhgpqW5FSRkSTCct6tS0PrIq/37Q6N0id
#HuFWyqpQEkrHqfsoQWoAW+uOPKm1LGPLm8de1iiswWM5cK04ZHdrd3J0kjRU2Sq8A2M1OqPgZsOs0KiZYCeteHy5wRuj+HYtFXbs
#FkhowirSVmFqamFng4KzNHoTvY0QWrP/yTt9bTXzSAAKNn4MulfdKBrXfxCJVKGedlq49rkPSTIajUa6T1ma56QaaIxd1Wfyn/eA
#odM2zPvp9qRVUMeT6KXrrF1EmVAqlXpOkoOLNr9+afw7nVom3IcGDSI/nMYuyBYSjdJl3VAYLhpEIAWkUEXDnVLFoDMIURTDtgxm
#hLu4jS3NqDcOe+uxr3kgwygPz/O6vEmFf3nopDciiMZ5VASwrikteRTdHrNxUmbm/0ALlTIeaCi26jJ08/4JZO1pEo/jfq3AD1HM
#kSnDuG/U/zmUp1EyQ+teYINsXlQvQzxWlCAnWVL398M0OeW8SKDh5jxsIOYy27po9r9ihhG8Vsy8RrbJKdPIChvR5u9S+DYP1TBp
#psq0dBx6kGVfpWGeZaPUff70TCMcyzCKI13bMJL3w3EMYxrHXZ9JvQnbruun5OFEIuxqv8S2uaGmh2Uu11+uXbuSKbgrGlTsOdhJ
#aKrvbsZ0y9le3Ngd7/N+mHP2JtrfNfKDDtgV48YIXm8Rtxazx0Wxq2+vRFN2t8er6fUJu86x/M8L4wVUnL4dCuepFTidXpJasoat
#KsXqcMabiBgkUxmk2FJM8lQCSmpNfPJMQImhqIoC5EZQgUFBaSEmCEiQGUwKDAoqazHZW+WmDaVWS9BdqJrtMlx/5tTUffa3nMDM
#eCyONntULbh9vygad9UKpjoSG2MrVjbM19ANMnwnr+7Cr0zOtm9HxAeCyZNhbV+Ipf0XHxwlspRWLzga4+bWmtrp2VE3OLh3LdyR
#ibfV1kHlieF1DxqpL2CHqpYruuhf9XzBK8MaJlc0A7wH1AMmAiKu4gFfRSWhwWgqDOUB86VDjSDhmdlFINB0SXdrOd49z5fSdyll
#eoQ0DFRh9iPQGoIQK8aaL1ihoJz56MVUUhXzylSVoQXyiTjdgQQHIKdqeW7qqOb8UTSCyz18a9p8QKussjJxRm4hmBNNqly8uo4A
#Ph5SDXf0j+0RR29soEfv/zqR7/9k/h/8z8YWhtZOhrQOpi7GFv9ftM//Z/7H/mcmZhZmlv+b/5mRmel/+5//l+T/8j+T4wDA/Vdv
#wAEAQDb0/+p/9sDuNsEJ8fgv/TMNIgTUnsgYFnSwz3/XPoe7/Jf2mQw8HBIbTxF1eTaXYIMD4PteNoQiKBYYYUknrsir2eD1LxzE
#bkLB2sBfqIxETjBb1ngTWkRSSqqGgtRS5ietuEXnYw3Gbnr/YQDTJv8tb7H2wtihcpO6/LARFE8gxtAuhmfkxjIwHaewUd4psqj1
#M75mzzPgBOACOcBIvELB9zAAFWoSSoNCrWVdnMW82Tt9WhJEMgElDnqQRTD5QAl1hArPIjcKqjIC2LeyA7RW0y/PfZm/q1kHc5uq
#cJbJAqBWsQ9wdBAYWBvzzhGfLqIAZLyGtZUfibmsMsO2LbOMMThcE5oJnEx3eobQ5xm8pt3+zfkYNLBckhVZQ0AWhBHnIjN3b70T
#lU2cwZWjwRiF1VImtBG5S0oW+A9CmrF4KRtorCfyQ1Cmm/YMjHGev+VJV5007d2GLxVwu51vdX0TuIIBmmKkiJSSsx0mDhDgzU4w
#T+QbZsoFxvZ0q3fXxW+t8IrYOPQg5frhV/f3r/6netaP2/xU/h1EQXYlW0Cww//fFZFJbM5cLjz7l2wguXKRdh5Rpfx0ex2WBoZJ
#JFPVWMnU6Z/KKqp5BN3PUpc1ftpK4wqtNg8Zt4P7wOHxcY0QIxooetUJ75CSkVBqEzfl52BpCy1erxnRsrT2mA1mGq1fN+3b1/W1
#1oL38UqN/UkC8ay/cj9s/zW25bV9P+FEUhgBEVOEBmZQxMbfris3zvJP/RdD2JTun1SALAAzARoNDApMjPFFdInEb4IA5lzziRe7
#qN7gUfBK7Ph7WL3z4dIEKDphOm6jiVAxmUf1PDobUNlkK5zjlXIJwGsv6CmpgH9BDssgA0mBNiqZkH19RMLIHzwLylkevjakSeEH
#mg5eh/NoGsEDqQBh5LNeDEc6QQWqvMqRpXnlr5ACKAILiSoYPiAJBVXUtrIpQoXc93NzPwxoWP55OGJUKUy91csiuUrGbig0jl5M
#AsKFlyoMPR/wR8yJa6Xhp11QuJ7nxsWJ3BKcuzds+1/mrHZ7G+3+0Kz2cWOd2yl1pmPYpQGVxNjGu7Sm0WRGZ4ZvK8UGBqyyPprQ
#EgmZH3563xjp1hK8b2uAVP6znv0Gae7gkB9hK79b07i3Tyuvw0b4Iu/uXlydonZo6TTt5d3lm62Fqy1rvqM5CF95qOgqjUjJOVwR
#sFNi3Mj8PwU5ZKx1yvDs/upnY10nE3FWIZsGoIePgL+XZtm+p9B4qdvHtvURugv+zyot+O59XTtX4LJt3Uujm1SrqO+5K9XI0J/8
#pSubJ9KZ1nm3qJkE6yQbTDmkYsMd+HiGmcAMEf8nXvzlBPaR5nP+iVodwI8kCznnAwuQdHmd2UvSh468BH27XyXIHpADdb9UMgEf
#Bs9HOoC+UrUrUBNQTr4tGyq7AG9PNb3qHkJ7iVkp1tVHnR3cBaklPD58VXbOKdL3oBS22ZhiU6rYv1KzzI6i2GPWuJ3lvEx3oUTV
#LCQPX1zj3h2lQuzd1w5Axq0Bff44s1Ty9/yrg7nf9nVxdWCueR7m6PuDOeWROESuhkcAY5WDV7nVWS7CIN0LInQGuzVfSgBXOANz
#NzNz141KYA7fN5cDL2M10sQkXB7Rc+ZVGW1Ve9VeXVeXamQe/IS/uN+pKGJjJJalCY9MAWTm1E6q3popVRnzV5KvT6ES8bbBBWFo
#12TPRcBhhYpboQOSMmU5J1HDL26Tph2hdnxyTFGIw3Hg+chclUTUQVYWN1PSYUxi8w/yb16J8y7VGwK9feM5A9STwpXQhtjIbI9H
#5us8PM5z+p+h/YmDnGCQF7nfsFOALSNCnUu+jKJwMoKVkzThw9+qDJNqDeSHSgct+3j8eWhnF0jkuSQeYAo4D83BnAZsM4kEkirA
#WF1ZJ5BlLHKbsp50QwXY8GfhxTdbStbAiVWGbbP23lfuiwbiOK6zkGS5ymBICZywlJnAYgVOP6m0cgCnQRW6lKQWZSKuRBsRRSmW
#1lL/DiMwMY0alBwWzJKmE9gEeKrF19vSriuxsnQ+FKgUcQXAqoV4qZdyKOCKpQLKGxi2nF4pqQooC+IYoBiwKLC2BpCxKkBUZuVE
#25S2bKZXpSk/KQ4O0ssG4wRllOrlBu5qBph/ulRtdSgqRUq1Og5E/ZHQsDNGFV7BBlfjaYcAi1KHrsBBqyiNnh2EFjZ7Tk2E8QLj
#KIEq0OTZN8FG205PQ664vXMNrkaKHP0q41U52GsFqtM8VXiOnaKMebOPA8fDkKS/sdOfqpJhhCddUgjp5JSqd1AahqRqlTLVgrOb
#H02Zg2m7aPnjI+Epr6jB1OikenmzXVNJD2sDxAUGL2SzUr5TiRNOIzJ24PSO7dEEA6DqaRJ0Z0HwPn4oeGu5kKUi1bfspjSXUnvf
#KtXgls4q4Rqafj6UwnXFQDVwMRqXx/LeOXWDqF38qpXpgDhcnnelaHXKf6qGv+5iHDPtkUiLYWwpy2FsLaRl0KMkEm8lGBIrUt7c
#lQnOwqVKUkVJUFUVJVFSVRcC43uRkiTEUhOLkktsUmoywKrZbpRffoTrNZKJQC9DbEakxCUg4kqiZB1IrT95i3I5C3ulXV0y7ocj
#giVNUPTqvw6hfRPPkglFGSyYU5NLYTEdIJRFFWLIu/N5RIMfp8UHvDnvhNZePb0Y7svJKsWqg1TOu51asURWyY9sEQYNK+uvFHVM
#FPWl98tnzVWnYnHc2+u6yIaCB//oGh8SPB0IIVBowFLa9CgBZCFT8Slw2C7G3Uh5pqMD3u4lLsSLdlG1uPL4jCetkxdPOMY3oE2d
#bBO58fKKrdGyUq5jajijnCaK0ZiNIn62BACCTMUOHa6xDKq0qFrat6mukeqWz/jDOTVzGy52aqDJE9Eo0Ud03xJwBS2P3Z9sNwXX
#XY1rEaQJPKYtU4eGHxCz6pvrs008jfrBl9BJAyADLIzIHKb8qKSsyMfHmypOR+WVzOhUColqxO8ys88RHgIXz87IMwMXjIZhno64
#9HUdxW4bcpPAUcmzmlVUxY4+UjkcC1WsCaLvOUiFQfF5rYE4u7tYlDrF1NIYWWnj8dvduwl7s4AjTyB0rKDygDgh0YRhoYWPNpKT
#BH92fYiqIiIiJBNKcoioJBUFGW0nIi5zxNh5lYkse/OOMScBY04AxJxowJ0hiDGGFnGK6P0CroJlIeysk7wzr62Ud4dd0GccYrHc
#jdzAu085URYU6fjlIm+6jvwqkLa9J38YwA8vDJwgiOC077dtEFredeiL1eTHAjZv86WNGzhg3EiSWj59oj+As8MbckufOLviMMu3
#SkJ7vgCPtOjft5U6mUrhEYtzZH3dsNv+FGwuIAUB/D1P4qQ9nvElDKKiLb/bkdhwIFZ6PJ4qCfu+36FLUEXpRatcNp1OppLra/n+
#UzLPlExd4C8uk+0bDTwTx0aAR8aIsHaa2gqiGFLIvqiSEXG5kbHqbwFE7UWoIuqaSYyRKkrwvJA4J78R4hDAqaqKgKKMFAwGgK47
#pHwiER8p8SQEiJAQYlJKiJtl5k4J0j06ySZ20tkKxYt4k//nXNEuemwgCM7ghxH7zsEHClgJEkYpxCClFF1XsqpmFnfgKsJERRAZ
#mGCVRkpGL2E9OzJ10oYCfgopVzExD3nJM4Wi9xwC678P8o+qlnqIAiElhpiUsCCVukhnBtmcEKB7mhr6/jd3sqIanCTsKANMf0ul
#iQltsR55TrNLxUoABgtGw8GWyaABAwYMWKAAAUIF2FJi5H+b2elblW3bIr/kaWAkQQerCjN8bxKlGJqIkTpmw6qGk3N4HTp4izTC
#E3sqggglKbNgMBD0ZawY2DeTUTW12jI9w/Y9TUZhEiMP542i7TXIfCwxnUx8uGm9PUHkoqIOwYtJWMVfVGGLd+k/mBk7rZTUh7Q/
#q9o6Q2lOdML7kFW0gMOEkXW8ge5VVNVOLDvIHCql/LC0CkEF8dOlIWspAtakEDBon/QcKngPtfg6y4BliJI5yIBO4iAAEANgvAKM
#cKUeMkzp2l8DxgkGEiXIEYECswqrglCTLZcP1t5vgvyKxB9bvmnTGoqjVr0mzH69oVf7eUg+G5B1AL+MsYpL9pwmuSurJjO4wlNL
#L9vOAhwLDgMPBhAAxIqUea10up4070rfEziNrw3w9bUNDCLDPLbvv7f6NB/76iOSGCGQ46MsErjv6VlEgUA3Nx0HBL5ugxgXR9p4
#Ez2QYAXCSYJ+F9kPv0m7j0aNYd+e6GmgUZfqLStKcpEl/TRTgBQrTO7yrT5YMvK0qIABt5lPnpDOOikUkAdtl290FZdRAI4/D5wc
#IY9RNZORAWJ6LX9XmFf/6kPwwdfOpxMgQ+nT0QBp14tn2H5pbaPrLRPWpHZsFZyc+zm1nR9yIjcKZx0rbpOqBahTN5YDgZjp4J8s
#wwgLigJfAxEohMACIzjAgI1YU9EkojpwY6XKO/TD4GQA8Jz42+nbIXxtw/kXEVfBEi862//9hIRYgT4DmmM81IlnVnaPxQIpZ9Zy
#T5bDQxoT5NVgR/jw/kfK8LkaYX7SDEHg74k0ATw4ABQOkVJzmv+G3AFkYFBmsDjGORDF46Sb9xIYHwWRZAAx2yykANlzQOcBySVI
#TwI9HJq7eHsFuhht4XYrVY2aIYkgZN87nImXqfKOQIAlCN+MngOSPr0Mtai/9Ew/EArQBcbQ+FP/WX9f7rgDMqb/1wUaoJ/v/3pz
#DDyvlTeJDz2/k5fnF8I7dVHr6wTyf7DzTjHDBW2b5WPbtm3btm1b72Pbtm3btm3bNub7053ppNPTB3PQczJXZeeuVLKrsncqqVSy
#shD6Efet+MNAx601h1JOVUuZ6c1Rxe9mzP62TgLBczmM63zcOiev67G6bOsXbNl3GleMSSApObXhcDgdR52JHcoOKBXqEQqaXQpF
#lpjDHefxwrb/bcM3KJkiISTGJyYoLy0SnifIRGZoJjdWKlRItXB99bj265rbOs6Snum+zjLv8bLPQr7hPAzK1203zBPp87TsqENH
#/1ukmqpphZUNHkQydjBJvl5XdihZDIXGxvP2eDidG3P1JQqBRB+gGBeoMIscG0si00V7cP/SnSopTgQOQmEYVybZcy2ZnDFULh21
#aTFK/tryQstbrvg3SNkiJ6TQ5gmAAfxIbwAk84WY7krOsAm47AwAVW5RBk4IFGiA0WhA1tFCbp0w4KO6+/gBnUO9GxEyFwsZa9Rz
#eqnhmqw/leIleW5BajRWatGn1+qSZZrhfeIbMx+TcI8IyIQevMQJmRFrEhWJhB+IOKtpQ0u0leQ97k0qzQh4MC6SmQWvu9LMrIHE
#vihsIaE40TFrdy9EbWTluk1KBR2TtRShyOQ5FAhwhfRZ2A13fmz5Xq+UNhQFr5SjmgLey2TcclpQsWyjimqMLVAgfAfhFcWde9sI
#wGCdGbrDsqKpkhoQNs4MW49APo+F7J4StWq5wzmi2eXvKsel1AvCUk1EPHt/ierB9StX78cAUlHEZ14ZfRT7U1euGPAHW/Dgjo0O
#+lUQqyGiwVprqnrgRKwLSt8dm+9iI1SFrajhyrPLnWcVFVoobyLnWDo5S0AaqHqWVVg1qU9OscslamODFhhYzg5s9dA8JAtGJKXU
#XHuVX0DXbJIQMnCpg5JhUFiyQFus+UX7T0d9lcNrWs050EfuBNqH5V46NUdbf6QupY9OfeBb9vObwfg1Fm+0o2viYkSGfbrCispT
#q0XpiCThmCsJJgIcj2ooThorm8JgN8jzxzUpkhOO3nbxk5bCtSUgSXdFs8cQRYV2pU5OyHEpEpqmYBabok3w/DoiVcVKdcTZ9Bsz
#AFXtmjLGo0z7skGfQS4Z6rlIRekIYG//0HXMMtJaBJqxE5qIZ2z2E16pTycl0m1p5VDmyGKs+VNEOPKhZnEtrb/+2YhaIpWByJjm
#r3w+mT1D10IyMGv1FrE0q5dWOrHnhl75tuxD2weJ2EjM9YEKJP7OjNHArsJgP470Q3Kkup+ZJ9Qj4rqxIFH0Kw0IXPMKCToTzCyG
#e87Om6cAkLEWrGuTMYJBHg9iDSKkTzRVxlnIFs0S+h+O3jGipiV8Wu+4TvZr569bbSfw2T/SS/uVpvlAK54elnksi/C+BGpdHzum
#NQ2ns5l3KMFI3nEIr4paGkVr9/fcCRXJKw1QMurogfJp1lhAbQVj7FVnPTxLb8swVO5G0Zzo3PRm6ijjuPBWR/wws7iofTZosMlc
#l0sIcqAUTek1TTYqZ7mwulWLrE9KM07D3f4/PRo6TnvJfycG9jmLFY4aWegBTpip+d03gV5WWhquehPlgoLzfYLwkiGHzMHBWmaR
#9By+lKipm5idQTZc7lRxoC2gr4EPYvFZ47lTp+AgvSfPpQYK8eczKBF9N4GRFzLiTEqPAULCI6NYIGE6Ec2XmKY9Vi0HRhPsqAOw
#fXjuOlVBdTo5MV2TlCvAiWd9wWXbqWj4IgtLxxGzDKqvTqdVoIdoydm6RdJSJrD2OqyXq/tSHNSZIrpsmUcHcK+dZexGSk9rNL2Z
#RH4soLh+r8g3Za9WgSy8lwHIPgMcjqBZjaoMkXZkuKLGlg0ShyMVsgzD9TTOq1+ekiOVPDhENOt5s12p8GvIsmtOMZce07bbh3JR
#zgFNip9Txbhn3hhE/cN0kkQ05ruXYD8XQUajuTUULIdb68WUZ6sfOrnFst6FzPa2ocPrnDW/Gllx1GAi1IxiPhQz7V5Yw2t9q2+o
#3lrRa1QxNrPgtk9t7aR4yDc1m84wxkWYPBBtSzznAWecONRHq7ixDZKrHpsi9uIIGlIj8SZ0cX43OrPHKOR0ZxwDlGIuh3oOO276
#rSWGTKv9RXawsbYgVmK8NKsUeislhuHm0u0TBGAN8/uWdzofaMslFvMxJB0VtQfdgGPvHvIc2Dvr6qXK5yKllInWFW7phCR1D/K3
#PGzStp3OibLCxpf21h/sTl56xZNCMod8HwmLBDNZZ8G8lTl0jD6QpnLz+FPERvEOZmFykZeXEsQ4anSX1GC660kcP8r28wI0zAYr
#elQpQblf7aNqNrvkihJlwZFewiajbzVxogsO+kWbXTyHQT3wwtqo5ECOLUFYnVoj/olnHUFOJ0KOdkPCm79XHHcCBx6pjk/2z1Fc
#cR9VN/yJfytae/B73XFf6n+Q10V/0Ef8PnRn0hMJge5Ukh5iNZJWqsBiLYjDE9JCiCl5e6rb1xl3cB8ZeHmr/X+P8PupfDS0slR0
#aEWWsXr2WW1rjLARa+DkA+rrfAFkYk7twS1cHVCF3lDnRcrSUtimQGK2jVp31k7KId0uu+GGDMBRpiPYKGCrpfWmiu8LZiOneWLu
#8imdNeXexalVfrUq26mivFBPeTig5GCICqOkfWa/15qdWg98BGCzGV2CD5Hux0I0oNAB6Zmd/e+caDxffa5dYBkTz5Xtx4s+1xtn
#rv8gnOGdLSNCVzJgHpNeHca/fg4E/yqk1+62mtLuNq+26qSbVyxGv8QudcADuGJTencaUATwrwinkHItDjqKUzW/fmjClH/YdtvR
#mSyVz6fpVo/0DNwM6zQIfW3U8E5fmTdTw2+yPDQu5E7KfhY4/caxYTFa0Ar4JRORY08xtr12EAXjXW/gF/sbiNEb/+baBphZ3MvB
#T8n+paqLpfmKFgkwdLs7k9wALwSFnTfTvE24H2tFzfskSCSiHOwexwIAI12U3XzPtCxzYiTwQjAiTJJhLANXJmBFx48ZSABEPYTy
#KPgOBQM0QS2g3PncoZA0a20YyJ/kzD7y5qS8hTIBxBBBY/paYzqBD7HnCdIVjruF7omBQf4c3Tk5q8/vEjzdcco/Tc8mzCaYveP8
#bBgWu/eizL0vCgojFFVH3LdI4Vce35Sn/MJBRnKFECkcbC9/kP7yB+cSNtOIlya72SMfWL0CZxJgaeERmIclxc4tF50NrpHVUlfy
#R5dVDvIhuZ6Z9KQp4SbfjsLYq2/DUY4Hj52cXpM/T/9egOykuet72po5t6EnQrIJes9fMT9M5NbkrlVnRJvXwv8C2K67qXYAv3PB
#LpyXBJjwKtfxU+7HjtJXqkqVNCkHjsdQKUa9laDblTk8WSNgLVnbZ2N/EEdQkfGGYRLHTVmj4GQOJo2NaKhgOWZlPWa/CDANLF4B
#P38GiYn8nBdfKDkQUaTTuf7rKDHYKk+wiGzZbDmMFLrAmsiEw/nO03z+9M1wIRPsat7qUabjql5jfvk0VopY9iuTe+p5K/lXqwd+
#gX5fB2lEK0k3MsVbPDPaHxCVjnxI7lBQgPGLA/7QVJPjqM89m87T5NCk1wdUmCV76+/6YFdNredQanGV5MMnWnU70xsH7AbYFy78
#ydyiVlQxwADYCllg6t5R5j8lmgklpaKRrrJsQTDBWu7Ke4YKdx1y368X8VXTlfVy356VYnGQnpSVM0blbeJWbKd7gbt1Agd5jdu2
#B/sLH9/UtKZN+Jybcy1/4fNZ1rBLvCzLUdyrVLkkF3bkZmyjMH4sfrB3AkloD5Ir9Nb9ypIYuoJ1kXXBWVQUNYKq7aTXjm83IRAM
#5YC8o+LU/2QcO+B1zim18leyOliIyTFcrnRPP/QaUiK2nTBlW/EOrWrUGFufHK4tZepRCm+gVXMrzN+hqoXygalc4WbBzW9V0Sm5
#kHkOtVn9K1OhqNBRxIQKjp1QmnDO1YxbVVJ1cYtkiT18lXaEatddbYP1q5NjzlANeIqZ2Te+1wuB65sKf5R3EfLim/q5/X3Lm7By
#hZ2LKOr8U+38cj+zDbyHy4D72f5XcpHF++Ilo1sH3xv2Nkcj8adGlRMh796+slNEvvq8sEOg7QHTHkU+5V3UmCZdO+cj9Yq1Hx6z
#G/MuFqOiXLtSjayuUpkkSGBFp3axVXKTgbmiVYNi1JmW7+cnYUjpV2zUKFAv7i8avm7qfLXkfqSlgWyJUP+iZHbakHtz9wM+8L36
#oSZeBXwY44cdkxTdNA/O2Zfkl2KP/nzcHOXcZnlCB+IIHQlJ6ZouJYYVLISgZbEokjZeJwSjVERySdSS/9R96G3O7JopFZku02NL
#voVjjhAZGImmynsk0KReoUAnwAefCaR36gOIKBGUWPGUvBRxkp02t8seSKJPjAL5cO7zURUdD+Vzw3fXSzru6a+AL/TM7vTG96ZV
#07oAezLoGBL5hCrMDEWIqXt+9HatxPvdCy3c/9s8v/OcMBDmS7vQs/4037QOeyERqnGbdBvFs0sPwWvP0vnKx3varUbl88Z/6Ijv
#IHwjp1vdGJzUogksdPcwgQi2qeIKlreXMiqe9g9cdyxxQDuxsEA83ZJ5yKrJaoiThTimVk7yCP/0idbHp8TSG717rPYEL+Q3SHOD
#poDM4YRvb5MWmFBsUFk+mi5WTUTfK5ng0axW/oz96UOuHgeuk5FacJdSEIGYlX0JanHRM54qvJzp3wH0jb2lZ2aG8fSG7NFiJbOA
#IG2JBKQg9RIbH47kOfImb3SwA2iXodgBwnc92iBzzj3rwW6Lg3BizS+MLWRaBZVisXtH1vaO8oLKRve/sY4GNds0sanfZjDUhbti
#9wHk099f4K4kfFpNvG3qruLjuILWz1teYS8Ym4qc8Z9N/ZtALsP0X/OBlMUpb0jDkcng+jsPodxP7cDYBD+Y5L6m3pOqp5C7CMPq
#b+DQ7jcNZna/WoUqa4eRXjDj6MRJH7EgkwN0uZr9SdFKDSdnU5zq4Ag6pVyGdhhpSqT6gbbISCuTJhR+CrMJKwN3DwOSaTpkqlAw
#86gNLRqIAinNVm4CaOhfKKCdjcZJ51M5+GvEfWIUlrVA6YC/OMe4Ellf2cUxc6XFu+9ebG77gPmIiMZhdtikkB3jnGo4MC5SufLj
#4I96gsSaG+RT1uDQpsFPo45pov1P8NclQ+Mo2vq9gXNnDpmBZ1VoLduAL+XR0D4UUZGfb1c7OgwQNhPon1xrwCwS0Q5Rpyp2+dy8
#LPoGb1KgWGOhLgDn7027IsiQ5brkeiBk2zAOECLu13MnYp2FrSJdxS3C7ANGjEjpZNIUi8MD8z/N3oDHHnWGF3et7K7UpH+M/znF
#FvdlvphnQHMR2oeuSP0QfxNFxXn3ZmItJWzo5Kgoa6YQT00GLAOTmr0uhgniJwMzg6VA6QZ42bZyAr9pjKT+jkd55Unln0ChsNKZ
#shpcv12ZOlE1t+rZfq87dhstx3sGfdIKJkQHm3ZrbYdb6TY+7AhYbtuvOWSgG7dwZ15Lp2tZ04K7Zhr4ZPI05nNj5sLY/vjZoiET
#HHOngWHvsEqvtORBWvEG+L9lvd3hlHO/IvseWpDdFUDCzJ9MdHFFxNN4LmuGV+PfjxaPHEyHNUiR0S8TCiNwLgze5SFTmSU156Bx
#g5WOi5Is2DHXJYnSe6/Xnp9feLVR7ihZWZRCMamzc+Qcz6yBFd3cCpmYibHZdKmHWqStiLzEuc16VAaecXQxDWen0Fwi0sB6afCH
#jtQsWcCbN83sYdAyyrfXNj8LZx7GKvG1zHG5Xa0uM5gvhrTf/hkesF/3KqiaJvEW4ScuQPp6vogG8yGA4Je13V3qXHvMLj24M+2i
#BmsAn9T2EN7e7dx7iF1Mce4zx7FWgY9nscqy8Ty6uqhVqMA7qvMYKa0H1lcX4HV0l0zqdT11fz0PMggOh4iXG0pqyL3zmQlatBV3
#bbnPY99YjC7bdPGCjM0xJ7nl0dGVCkSVjZNR9tZoKe4oMKiOapt3ECz71nZv19hk7GaRoNWBtc7uTQoGoXGa8XxT/l5JslYvB3Ou
#9jb8OSIZbmQL2QCpcbCcsecI+U2G8ZCOnZx5h0iTGUt7z00YfroLY/mxrXcLDr8M424GhRId0kvHVRCnRYBYwv7yzxKNIjyFvCHj
#DmsCobVQV81HlqxOHn6u9zj2XO8k8M+3QQk3J2/gm5myTbuhG2InI+wg6r4e44luOMGqI7pfFAIyK3nFi+9WRWM+lW1ivlY8Daxx
#wOgwH24t6cO0PVZAxrpY5KATRwLir1RHO/ZM+/Ll6Orq5WRORCV6aRnc1HoOXv3V8E918TB3Bi2w6bdhtRpAyHZyFEuuFUfoJuix
#3h+fW2i0XYHEI7Vfo/YBXsX3m8gyOhgis4Wl1jPaNKzOpsaJNekKDSMRpYuetbFViK3jaFUnCHXw0rzLJYFxp59NzkJkCUuvW9Tk
#xAbkyLQFh5OK1OczBzNgNFQcwJkLhMwUlIxK4VfbNfyrMVi9kHWEzhKOYi0c4pZaKlr6Pv1AY5v1TH6rj/qh9SzqIPcHak6xgvpv
#8+F4eyq/13M2L8eD7YTHpwBZYMqzIR/jNmmybZ2u68xO3abuwN5eB4Lu86ds0Zz42NJJW5vzNs8ObjCgjmyJZL8sv65yap6w3vVi
#o8kW3RK/769/u2ugbeMqonSJGm/0mjCA2dtrdzaP98i+T/+kVynq1o367LNeLJoUzz2GaOrMN7MGbEqVL0E21vh3+pt/R8dkR1/N
#2QJj1CHx+7Ka6SYx7+EPJ/31h2MD4l0krflfUgLEygKmw16+1gZurDFtXQerEwxvopmxPz1TPQqWoqmnqZ+U3oKPX5pvy/d7EXqZ
#HyadvNT4h3lpMX1pmWljL9k1ZjksEfWXSr8sS8TvdZu0WGcY7lVyMwRKQVf1TEanTz2iRHDS1E3L7vyLV035Au6OqX4EpE/cdKXD
#tqk3nHAzlcwAeJS3rnYLycA7z/3wx5o7Y47cckWCjSR47wcyVyGsz2oKeVektfAyAL/BzbJ829p4DegJoa4kzK8tfUxMs5GmavAJ
#rDpOYEpzro0KtIXHdiZ76C/6UT875d0iTfzkR0C4H9k4xfec4vyzYHyA288Sn6fl+YVvmS7be2haeN8BlQkFBNLDO+3Ou+B9+If+
#3s4WRw0+IzytXoFH8qy2hbaeKa3mA20fCiu9L6bYREOewKGRscaFDexA+KmhH392II8Kpn/ib2Gh7NV2D9hy9OiWIGAShCz2W6ZC
#KgSnYWgInS01jFk1q/SmNlWfOhfMhKzVg8Ghr/wgU6VB5NU2aiklICZqRCJExBk3HMpyeA1VlniQBJJ88naBf9yzLE+y+mRYbS6V
#It8Xn4ImM984QXF78rAfD5G3pDY2CgPizZFh/2fCAKKGO0gz2mGW6N81wV/vCshXF68uZEOYnLeQ3LxNOWqxIWPgpqLmE5kMYAxY
#QCA9ebwmer7kF9cNNljBwwEZJg+M3IiXRzPCSQ0ZPTI+e7surUKUaRa8QUMSNyHTGLKcpC9Zx/Zn8hYCA+umLnFnxbmhX1H9LTK0
#g3kwJBP7XEtsfKxO4LeEDBEWLYGXBAO8m3pvtZZfwqday/sJ6QjUi5g92tHXRb4G8U64yXAwtlyKF+v1i0/Qsxf86p7Aa6BDRo5h
#YaVPzaX88G0K4oIqp0oCWVjA+mKn8efybFetMDOkwYxC1Apj0sxW+k/Fh4ec7a+JRvWy06BGSZCegFM4NKGrOJ6G6EdCP/vqM+1j
#iJr4YdxssBFEn3a70Mh9HaQ0wwACQxqNJHb85YEVI70wGZ/FCMA7fd8V5PBkBELmdBUicHeS4gKPMJHiH8iIMMZ4KcB2BQ9MgxQS
#Dh5ZXIwl9Am0KQaYmVcbWAMlErU8WAKLWLERG0kE0MkjhmxSkQBfEhQaFahNQZtapUiygqCQXW8AAj2FSOW8CeVRTDKL6IPiRYsz
#iL69MBBfQXnFfrsImCjHcrTJU6zYhbOY4eYUTwOZc184I2IlKpAisku4hCC7B8FfLg2rNgM9DPKjkPFC/XWUrolq6Q8TmXljoOCg
#qJTmMNK65zvPUkp4yTkLhZjBkMn6i9UXoVbdGkYxALE7x121UBfqhjGfvF6k7HNuXOLZRji7/I6XvzRd12GlgGDgkXrgmHrkRebV
#5HZ9P57XBUsvBSsO5STtf462V2jbLWzNYQlfxJuirJrgETBKpuTJ5zaX1cJvhVOEfoiIbUadEirUxiP4jmFIf2+lFROr5Qp166KG
#zua1MmDSlA+uqZX8BZCjCkuLi++r9txYbtuYlmtKCn0CGj09L5Q0ARIxFiOEKA4SQSUSYSeTpHsRh8WzdXMMfe8YJmImpqJ60rPI
#NmBL4H9mf5likUbkcOKF6CSi3fXRZn3ASDmvfUFwnNfhtq1VquLBMZETcohlsMo0MxwmmS0cUvmnZglAWaQQsdZECwYy/51d1SeJ
#3P2N5mqWgeDVP62SmS6WmU2WkYVx5nGc05G89br+pXiTJnlE7yl3n3dosDQQhQg0+r30rGnJwjBCnNIYWS+Sh2/gZNQgZBzVGN3Q
#CyhdXgwgndOKTpPONadYTRhqX4yUSuYZW/Ckb0d+q6JK+qubsnCh7UbjbC6YZEkH9GIqEOclXSz6VS0cZ2OE/8TBXyW0WpgPnCw0
#ECBUVniG9NJwA3VOrxqi/kT302Rpc5zP9wUNCQrEIhkJCuXXTfAB+T+H4P1/mv8F/2lk6GRj/4/W2dTWktbY3s7E1M7Z1OS/g6Bs
#/29A0P89/8nKwsr+P/OfzIxsjP8///l/Iv+D/9T0BkD8r7pQ/J8+5v8j/xnAhd0AhBPh9l8AKBpEAAFkNioiBFRgsUjAJxl0MMl/
#A0HDRf4LBEUDjwCACVDDZukgtckSm7EDz5dw9sGYEVu3A1dUMoSJhRnGAGdglhN//TMnTSGko+WTxbAx7ywK1FQtqQz8OpB7M8go
#cmCwuPSXyU7bOw9JWY7UQX67evnG5jfAJiYmxpyGO3kRVYaH01F7BGy6TNlE7RGj7CgoSGKeDSh7mCZ7d+o6YN/5TiokUOFJQsWI
#nBizes764ofyRnqqDf2C8sKS81yaFdcBGaX1Xs729Pj9+Hn4M671mQXOybcnxyBkDlC1ofel7NkrB2vzu/v18LXzm/W5q8lE5cAr
#Gh1PsFWelWKqtqgetVfUJ9dvYIQqehd72f/7KuGu+9uR7R/jjCzlZhlsN2ORM6H78eP3t537AoRiUSIXLuY0iVphJAkyZnERjpx+
#IcxZ7cMExJIA26CJMTmNOMo/qmbHXgQ0WLpxnfnb1gsC9n6qBv8TzqHMwSFBvpRjAhl37C12u6mXnXu6XaMxUZY+5H5TyhfKyeYq
#3H2NE2eN639q37M396La+zHaFH0TKkhEhkUqMFLLerrTgzi5r7ycuzK7q6O/Shu2tjtobXHWvDEpIgLzNVIggSyyxuQv4syt1vrO
#ziV9CV7GUwyA2t9j0p0Fg1DnrIHeQ1H1JxMw+PpbIf8tojsxlNIMKfsF2gCFyodZcxr8FKU822bYY7DOysXBy2V7CegKwxHxxyAR
#pB0LICd00AgEkcA5JEG3bE7sNFFK2WOzfquqsPhsk2veUfvIiVipdOrJy1Bd4QXmOfsmWiU00TI74YzBCgGK+W4bg+3d+MfdV5Sf
#vvUUDSrMpBHtA7y26fo06OQgHUgQbrDwt3k3NlsoL02gApESL1KNAtfsdRYWeOESIyKk6dWkj+Ka97scFdrESlMF8qHjU4RNUwia
#OQWlpdzywVfGGIJIgjYKSPlkX2n69QcjBsQGNCUt2D3e5XzYYSEiBafJVyadkqOtjv/3N5D34RcKALaPhJGoJUYLQUVQ/Swh8TgE
#k48K4PSWsD0MzRkkKbOIl+rZXRyzKBnLmEqJssJaUvXpiW56dzaZ8hNnOrvbJb41f1vG0oaMWijH0VktVFRUR3pwZmoJzXyNq2tK
#aWupC6pZGY+x1hVZaKmCihcjRgH//edc2fslTkYqJSi3Voo39+AG7AApRZEjAM/EoE23vJlrc39nlX5XdqPzjCAihFmaCKv5s62d
#yS4nE0vaJspGt0OQRnRJZG5CGCxW6/zt6cX7yswHYQNbZ5ORqdRnr2NsFqQneVWaEO6PR2Sa0KLH/DeWbjZz9G/ueYUjEBnlGY4D
#xPYuHkAbwEzQbR0xH8EACOR3TjeKzH8YhwAWjekx9DtE6GCwQEJSAdu2AG4xH8an4PexAKlEoYNwnmEoH1FM2FhGaNsR3HGO99zv
#rSAMT+iuO+iaIJwAKX+QAJ4CYhrBDsNpUJJSt//+7Ex4UiAQzKXLnyK6h4OCZVZ2DYYqaB7Xt4QOlP8urgQPfkWeIUZyUA4fxHwC
#cXpI8aRYCikbCGJXxaCraSkMQr4cwMwOpvktBWjTZyyf1jxIqitw4t8V53VGbdRnYdSnGLS958DcxxERfgiFGCYcxhz4UYYBD3A0
#ecADBgMemOO6D/wBATqHZLGr8yHICzgx1muPV4DBO+rgvf+pKgvSJScTjkzT7ovbhYiyS3cc1rSFz9Ze5bJ1OouMlfbQi63qViTp
#Ao8Wb5EpH5l8WEukmsl4xCfr7hCStXRH90zmcNs4L4yd7wyI8fFy2CWZdaBiZq6K30vwpx7+lStvzZdrV2YI9ILl4yhXi6rtTcqd
#SmfH6iqUU1Qowgxj0ZKVUIxSR4OhRApjiS1sJYBpbkr1ubCHRtvkPRwBZgMyNwEPPkZaXJpXfGMJvWq0FEQcAtA3rs/N0ptHxpin
#k7TdqdTsiUnssUHlU9w996bcWC8+makxVRMMzb3p1W9T/tMG/JeiOBStuKspFMQi9Sul9LPjup3/52AWCoLBc98UXkxlgkYp/0cZ
#PCz/uUv0wZyuMslO77Aervj5FP73yELHYyQ1ABaMaKBH5jolPlbopwKCzo0r0He+PPhrD7IP2dd6Q29MhTFkgr7fv2w6AM8rKoyt
#cI7uXXeAjwddvd4EpaVw0BVDK0jXLh8ZFd3Q17tCC5Ms9Xmy4xNdRQBeLPHFWDPJCZN+783i4RYsCvcAMvyy0Q6GGrh/kj7EnInS
#meI5NZGGNw44iJIMHjvyWkKFYREAKIylIuNRxq/LYTmLMbxPiY0Fecnjlf5ENTsgTpRFuXbPBfRDGAMapfXUXU136b4pxcotvgGJ
#bcbFFsR6xQa+MtHZ5eZs4Tu3/joCJdAChA2x/wCfi+r+LjioMyvN+zcNtpFD7gv+tW+IUGBJzW2BCJiNw2oAf+kpGAats7YY68fu
#h3j/RTlcldUvieAh8ExX9ynDqaWYMAVbOQXkPAeBuOA+SSCJYAdAm1DNZ2XDwJUHf7ZVGicGThl6J22PjZxJ4PF5lLVeK0l84Ytb
#lulHwdDxu+cKDzA4pi9biG3x7hIP2HUsI7hEZCGc3zdah2XGCga6rxiThUiNacrTxGjkDw6tmCDIBiq69eHRu4GWev59vNtyf4MB
#XgcNAxxWKV7Vi6XprlynbkEgZ84XlLckpgdHN7ckZmcmkhEYQ4RzgL+vIwISrxHtjyazPPW64IMmfwMxAQJyTl3kMxyESyhSMCZG
#nLFMJMj5UxPnLcj7LWriHVCosLwYgWKQAlYs+otoClR4s9ZCCd/DsMLYvq9qGQYrWhRpV0WzA66JDBzLJB6R+3IVo4Yj4oQBixj7
#Hzn5O7EKWKPBUPt9Eyp5WMzfUmIzwiJU12ck7+hx97Xzpw2kQtDqeuu7FHS0DDudVUEufjJOjP948rmEPQbFHt5OxIA8Fvp6gcuK
#5c0CZ/j1WG8EWBrTOro22poJtN1aMGpiUbFyrowziRBZrmoy0iL9ptc/Qa2kVQQO0J1O1IBTH5xyXAslSC+HLVZgQawFCTdsGPqO
#hSVS3zT1DIejkusFikhqTQ31bEmnFSBX7X4mj/Ywm06kEqvnfgMpNhiUd4Pk8g5KFMksH5tDINCFkMtNJGRJNLtxIoAekxLlMICr
#KV9ZUvWcKEQioRSInJA7HqxIxUrwJQg9IiVw0mm2cKaqleUmwiZZs1SQIbcrUXduoBKFSAWTVKFRQ6ZwlJNuCUFJROQ5CT07Rrw7
#WbE8LshEZAaDvARHcygXKOhUqsJASSRlFY2yvhcMvF8zBGczM1Dt9OZtZlFXM2i//vaPPEDtcETTJFfeTrN5V39pIC4waYItLspP
#nlfTOq4UXP50LaFtorCS8Xh2kckRCamGqoiEqFksIXrxgCkMTi6176SpZkBN+s1YP1rSdVPseO7T6ydX0xUwld0rFSeFNBlVRCRQ
#pimm59ImWMHq0w1erlCWmvIqC0BKeZTMC79hTZTqmCmEV1UQZjM6LGrg2IV/YvPRwjROIZezXg+Bht+fsd/a/7NlrCpQx+34M5FE
#Exy79zDO5tw68FTfSsINjXeF+3np3fmU9/ZNF995tiUi4Yet+kWiRBoNkOPtJr4N06WayUHVyfoXtW38YS6eoZJc2edAgHvhdPaS
#urvtWxClTCur47SgS4FUC26D9lFgpWUUqipoVWjyasSLj4hDOhWF1AQ0rb8xCyCyPxgNVSlZXpoZLAGrrSgrJOQq9G4MBijWEK6X
#myDJUZigQ1OcCPlIgdI2OllRK7Sl5C9O27EsFf8b3tmplmaFoihDOrKsSFGrMR/gyaUklkvCJEj5gSJMyistwkAWVEIYgaTYham1
#eUIDWiyhDFU6Ei3J4b0Tn4exO05KP4VOkezfI0IhRJZI86CjJOMYrhCnPbBqHlLSzCbx8F4u3mrgFe5EWXV149PnmStIaShKP1Uc
#BS3X5OTekxN/dgYzdnCAjCDbuxmrLyc8loH9D48nI/3j/mRM31+CMSqaeEoFw+75cv9fEUecQdh7HLEGTwCyAgiY1fABERgHFAcW
#BxgHGgccBx4HIIelwBbgDVgz/ryhwBggJbASeDHsuAYF82A14Ma4IN1jfBwQfe3SIiSy5FXoSh515jMiMUChB85MaJXjMqrSzPF8
#MKPPgg85mEM/KLw3BAEN2gv98A9mhHTZVACQVPk+QIt19Xo9nVsiYu2t279/A8C5DAMw9m8JXxezv8hApREbktUIYe4kBIiSEnBb
#1fm0mwW8XPnESvGRzdxldxTGlj9sS35PMjzQJsTgHePCfFDd9a9E3e1xieRpt6U2BY+4qjb2BBjBAxhIcDuj9S7vdGLBcSBFiwvM
#0ex5Ag/DJSvX8jVrBy84O+29pajfx+nhP4gojtf04m/0GAHAdO77wgCGDaYq6zoHI4jMorckVNUZKlv1BybYFmu1KdnIYmhXv7Sw
#iBxUQIL387da+dCQgaLA4oyEFvP8tWqVnNlIcTxqEhl2n5viSqtHwob6mKnKIFtTMSo1KxurZpnESgyImoxcu9aGJjccfPnqvfrt
#w9UjkmtAbPIjyIkVWkjpQSq3KBjkusc1Yzt/wk1kM7Hc5Zv8rVvli0zQ00xCGUA/BCkVpRl2oRlmGbaxHaeatkkzrVuGZT42WLxi
#Mvis5ngs4BTq9yxHBTXZ9jPFLc1sCEJfraGvAbnhfA4qE9bGm8+1BgQpmFFvxmc9fFEZTWDbUKxm0bf/nJYKmIXy+Jp76j4j0O20
#Q5yvQ2o0NV55C6I2gu9WV0T5fdua5k/OLM2v58Ji8a2AduwOEhcdTmfVw9OxHYv3VYDZ+QJFhae9/pW1Hk5qx1PgSCMrOho1ywYQ
#PRBFxicSo+vREMnFEoOgPI/agUCMhcEMk5cdTehjYJX3ETPERKeC8xcY/b03NgNhd/m6uGp6UG7O/tLuoiHe3qmzo5+aG6nKe7hB
#2p141h4izV7JM9vhanFBkH/c3FkHG8f3eRHCXgEHpxM5TcTHEyWSgSOxZqTMo8U1GgjeOb/JrUBQM9MX6aFg+IjUD9Kg8uT/RQQn
#DJsou901LlJVqWoZ17iubhkcUWhmZmFkmHZ5RdW0ot7Bdqn0sHfT/UwTz38SYeUjZ4V5O92OnA/GYfNiUt0FVVrGSV5PRLwVYpZP
#QETrKr/hBdVn1jPr4h/9a/w0yobplnyrDaleABvrcsQMcLWX+4sUeKoB0AkdCSKIQonPs/L/wGtdHI3ElnOmskmiOh70abjBxdly
#d0+KtGIwg2ipOBVV1ilMjN+F9gRkF8KzF/MRiglIYHXshNyl/0f00fzRcTXkPJnubvtvVx4tJNvMs9C5JzXM+jLAArTM3KmiH8gP
#8zD5qQ/8TfU/f7GBHAcQu1dh7osbIxZ2aFAc4GIYrDorM/9CMzhQbI0El1B1Lw+ZIasP4mh9IXHWtCrJteuWrdgiUr6jVrnBc7Uf
#SxOeLTzGJGlKeFJVc6WcgWsdlQGbWqD4RdOoRjiAUCHm8IVCk/aquVqATah1N+cFR4Ddd2sCeU3/xB5Q5vvxpw9w78++QfltjaqH
#v8Vcq7ZVBwCEA4RjSzeevGmy5sRwKgG8adg9K8iO89Lvzsdly5Ec50GjhowVa43wQnquB+OTAJR7pPiYmn5p0TSnQQejpLi12E4D
#pBZsl1So2KIM13lUGx3pP1vPC/fGBWNLuYbKm18eVWqIH7Dx4Q+P+yJNebf9Kt4Lz+Jh3j6POJCerOu0palXDGiv5zGO9+EgRx4L
#qd9OWedfv+8K3JGhA4TDA6Qkh4KCkqXoXAIypjrZLU+6h+ekdDnBgJDIgyqZYDWH5CGp1KpaZqxS8WVBVG2npb2/jmbjydSDTC4h
#GJZJfUJk9GFNv77fegK0OmvXeSM1XQdrao7pjmO83MiazzJCQHabE2S+3MXwKBXHe0Olhu0m2OXLekCuyhh3b9VIi99e1TswPSs3
#3u0aD1l4HNZcr+L+FejobZ+S7/cJp1bpH56YhLx9MSK9Kkw+a7KwMe2DnMQlHhioenz8iZVKvFL1eiDQAi40szq5zkgwQuCUS6nT
#xg1ahdtYfoaE6kjs4U57ma4uVGzKrO2WydvBxsTQVv7ZONIauQ1XdzzCv18Jr6lOK2Cj1PiMRHIS8FSt9XpB8N8eyYb3lS+2SrN1
#Bb5XNQ6kzp8t5VbJutmlHd0zC8fXhn+vtePF/G7PzilCjBVjXkr7dzDR8btr4PMv+/dMWVf4iyAySIKstrCL+RWED/sRUzV2tjPH
#Soxt7pj0hRhOV3oSFipd5SQb5aPAtv6pw5aCERYCjEZrr5Sbz8tpOKpSWNZL4FWBjXWIAdmzUkcK/rasMksP1oFKqi/KVDfCQhLK
#RX/12V49gg3rj4ZLw7YvhWpdJH7PpOzx5TMa1flCVp67RdTDAjPLicgItlUSm9ESWpBUpqbWwQUbhrD0IixzA7OnKYka5UsnLq+b
#GMvt5mxW/gfRREMq8SSaQj4oxBpfSjViZ5bQUwMc/Y9MHW1IKERWy115MuU2ybPg4YnUCKOr1S44WIJvD6VtYtV8TTxkgzJdsR8p
#xX0GySlg9cSfSlztpIlLAKX7QeGtqOEFOe7FeHQizUo1ZjL4zSqEQXgB1Rhna7p5I2418BiX4+uAEQW0f65nTFY2pORaZBmMqjeW
#DyX+xW7Rpi3kskMn46jRsYQZyArhqeZ7J0owabteOT8Li5NZ82mG7v5grB2SlMRYyRBBgGkCKci9rswMtKwR4Tu56bp12Yciq67d
#V5jycLBD0pEFIpTRTrwX1QgSl0/TgyRk5Kdk2+GC84l5DF0B2Tjj39T0e2uBaMxmedjxqRDjEigmpIDHJIjriSCPiTBQiUCRiVBS
#ia1dkpCD3clVdV16Cone/zBV1FqhWrVy+262tDPO/mIUTkHOzKwrsnKVvQ8cbDlQs6nkYMcGHB0xYsOOjpYdsd6XCVMVq26NDUqF
#SNd0V2qlWBYf5I7FPKMtOhYnf2IWyRkEJMBJZqfO9fjSsMcG/PVgjh32HLdph30zSLNsv6ld5zE+S71/98Pd7V3u0pFNAo192CTZ
#ilisZadzAABi1Uz54mxWZ9gngzVG+59BCoBSKiinrqauXDMjRCUCB5YbnM0iO8IoUmSL6ZI+s3fzSilxD+Bn5rnZOnzN2LxONHN7
#CBjHXPBRjcmIImwOtdbmn4qWJfudMgW5pzikVBEn5SQWwfixNUYfvfxoPquzSHWn6Sqw7cRdCVeKiRdXmScvm3hgPFysKompXIQk
#G6gD0yxYhocczqjyooEOqEKaHXchXFuKG5Bg2THqD4VcIB8RwotRFLug1lGiwCQKoKO4stEuFprvNAbyiecpUUkIp55+a64wXHNX
#gWoR2wzGQmVpCgiIy1aS6BtoVoPpOGWYRgbLcdRWzngxsPoTJdS1I8vc79Z3kfdXsPHgnHRuYEPYByiRYAgWqctO2GdaPWmsM7zY
#nngWX6+d7bNmIv6tTKb6lsxNiNbSOsvTOVOxY+izM80MN1JUmcjD0BmlD5Uq+ueGs1hbsfeukPhglExXzfaZrHoNJlhz5vITgUGM
#3u4zXpekme5qVLtosSLq3IyeOgs8W0Oz5qitVhJP+7obT7t5VInfrZ4K7Up2MLdVADNfI50kN3e18+kPPIikW4OQbqpUBTTeYs4o
#4sVVs18HIJPGJGXssoHwpF/ogmc/WpSWhfqbN42h4wEjPF2W5pPuA7P7rAOPitt9tpPuI7fdlH1ytM6NiuSxg3gbltJz70fXTT+7
#Cvezm3XZyx6O92Er++wh3Qdt3YozIfk6Lc3RAva17/iajrrdu/UpokO5pTGGmnMvHTWBePNOeRE8sXJP8JFPYPUlTqIysU9moJ90
#fZi4jQWO5KCRaUYldmtup9GlBkeVHBhptmv0EmglmNTIPJqhJqNWx0KtioBaFwW6Qhe+SK6GksgjdzZN/2zlKS8PNjGAPrJLjoQc
#npp1/5S+yQg2vndHfN4RNgMatnWBmvDls/lPA1v/Gddf/Ot34C7/G3jtE/TAUPPbpxiPR2ZyE+tuxGHZQlPtkahvbmb5cFhw2xNo
#JQfzcMscqTyqyVIjNaHpGdkyiuHiFYycWAr+7mRrTbqBX1ofQ4GDYe4l41MiqxluZtQczEpfFkZtixpoJvZgtWQF2+Ay1RiMVm2y
#bzqLM69feDwXQjmVAdSn2x13ZLBHQ9abBCJuFFF4pyTzDIjPmAEx0mRUFYm2DqOYMxGqODOFmp5/AYpTikhOBi1MVCncbf/8IVy9
#VVE2Y0OV3h+hF9NLA7iyrE+WOVYhf7GMFaaUnfKI8E6RtE1MKUiuNSVN0M1cBdOkTV40USMVYOjnJBC/wg+37VKCBXEPJgJI97/E
#dWv/SWOfdFTmwEs9EbmGWmI8pbMuHpazKiOtqg6HQMHUD7RXhkq34bOGjB0Yc4skGJHR8kcUxCAkctjhcZZzCEEBRezHm7yglr7W
#CpoI2IeUBPmM7ufkyLkCcc6mhQkPNMSGjCjhI5OqKCJzfw7h1DfM+gqbLCpkDDyBLBkmWuxHgQkJHrD53SOJANHUn5SJR2NgBIkI
#xQCO6+xFEkyIvo65lLCa+xqcEoNW92lOg0BZ8mAAdRxmrJB/g77jcB/D7gLewBOooadqgouCYQbRi5HRj6orMGK3iXZkqF8UQK+L
#ZR17HMs/LcrthiS0QJQUyQvm5ih+dP18xFmQvEh0GrQfAaKrV4i9ainyGAZ29P5kCbqORrIyDLcxirsEJ+MW9eoq4L6LH1x/ew9d
#2BEkfNcJdxpwB2HIh4gETr9Q0IYRqCEfikaIzcU3pzbYBxwt3OcQAiHoy3lk4gmdYJBozthmyyIV/w4Aqid9rbCAvFuQuieEjP1w
#KumMklhOh5UD60MAcX/fnF13jg7rdrjeIUIsbANlNv6jgkJGHL9sY3xNuhJr8tLA+RkknBcr7lVy2n7QxyGlOa36un8Ecsqm50Hg
#xYU2rKZwU4uGaHN9BR9QtbvYZEckYv7id8jQNQEgZjymdNNfQKrjUasch8S1FdbBKQiB/Zt5KhMyyPUiFC3YJ2IIF4waR2LpEK8e
#iO2rsg2XIOxXBsmJSOiWF7DAMWH25o+iQvSF4UdUcQT4x8gRHqROW0tE74TxLB58djvFBzL47GKcmBruxGaoAI6VkD4BZoOO4OXD
#oJ2q7rsGYcwokQOXWGaEJXI7RVaw+WFa+Bks94/XAVyF4Bcz5gAgFKEYjqT1Yp81jZmq2r/BBH91xp2PO2AlyyhlfMIbATnv2OxE
#g8Qo6kFASLoe0ze9gvPpIzp7dpoAhxft2wojas9Tlds0ZxeSlBUCEf9GjVLcoLOhqGhgE9thR8rKLa+MRx6qhpFy5EaXY9lfRJqe
#qHDvdtve6kBkcTwSgnwPamkx4DUQt0MvH8BtYtTMpW8AiMdinE1OMppulckqFsEi9XgjYacbMXR5GK5NeGUnXc+KakEUuXUM8esb
#qDLkziFOsCsQpp9CU+6ykNqKW4fYX7JxTOWilOA3Oml/NTb5MDhVJxZQcXpqIVAhm9tSfPLPkrFF3TkwuugT2gUHf8ahCRkpjIDB
#q4fZxlv3yh4qKbrXieqBm3Er8tuogGYiHxfT0j8XrVtj8JHPXSMKbge02K/EQLR4FL24iMsbRWgmwhajUa+CbHeOTCrXUtVtBa/X
#mLCIQtYnPTWzgA9IUVmH036VzXOvVJIbO5Ju9mGEL3zeBK4mPaf+l0Xx6SNQWvELogrULpqqNd1EZatjIj6asqY7oKDQm2xbJEJA
#XWH2JEFFrme3V5bPsNNKpKfdd3e1rTFJ+0c1isIfxw5EVxfAXcmmQgCm+6335YQZHNjx/lGjLK7H2i5yz4HwcDBY1WaDrlXzhfpa
#6u3n4khGAprr604n4N3yx0tOcc+2qul33v5yfKthCCUQY5wH3tnX7MzIx2YpsJctwatg6RtwVuY6GpAhJoUpnxXR70N9bg3tAq5E
#LLhLkTVg4GsJ0vB+83DwR11f/bdgZLjn+VVMOr+QmjpD+UqkPG44hc4KBrTGKiOVQrnLGri2imN8nVcUbN+JKGgPrrrmeK/lltza
#atx2aZE2AynvviZXYfyKFOdSDhUGxMMOefilywtA7zCxcmZyfZf5S8ZqldXG38Z1PncrdbIuc+49QleGonSJPlYX/AX3/NKj02D7
#DosUEUrjCOQCXA2vJfSZgehWt7GBqvBH0ZK3sIgcTrD+BNaCsXdbRQk7k6htuOs0v7kzWiXovBtb3vxQQ7phdk6LGqNUExHBSWTt
#P6vO0mof67hkeTwDY9V8XDkhNoSzj8UUIEZj/vXmp3+A69qZ/6gvo/YRDklyRNYrkWuc4iaupu2blgoLHf6GgnMRBKdJkjRZ5+Z7
#GbZHhWa5VfkUBFlcKZFwrwNsqF0d+cG9dRTmXMBz55kPpseNYLBHQ92EFpsJ1ViCb0udEzzonltv18OwxidxuyOlc/l8TaBad6Gm
#nDouBNG3uxykGkVeK0qGjd1DibxJVf3WvJJ420gnchVrTzdHXc0pgVT8KNu2tbCL80CdaQ99T5g5B5Kzls8S4MiK2WK3S/vDqS1E
#CKqJhweQWBz8ExTwaWkL9EFiSavfjgGSZs52suGvGA82xgntMJO/vl3HoS4fUPn1Ky6MUGVt1zctVeaKZ0EKee/sOaQ9SBv3ZjyZ
#QB7PfgUsF8VCexDkXJKxCPMXiPVMbJyE4xDoeKl8xsCS3MECR+cyVJNTsMNYWwIQLsND3djqrPQnD972Sf1ASZIQgVt4onkJ/lK1
#AcdXW21ntKqOAABGO6NsA+6etUG5HKrfv+gNuAc4C6mO/CmddSbnAT0xOmiaODphL9YghKCtbEGWSYag7gm5ciqQacRnD9NGzHKk
#pCOV0gflVYxJUxqWcH/u9yn0IG+IPVzPm39+6YlgA6EX+G7tW3KNrXKxFUPNASV8OGa8e59uQaht7HA5bjnj96SeCij0mHzi0CZU
#PMBFXwAlvokAy0h54HQ77JJGhAiS1PS2jID2OKT09d9dhurDLHD0+s/12XLad8kupFKE0xinIAooRGyGnXkEz6nNAl8+SzWNMY7L
#3/rLvgEJ2IAVbvufPlm5JKw0Oi6CYpvRc5S+acWbxuEPdLxuDWqa5kEvOM1MgOlgHTa6fCB6ZaRWyunuJ89d5aqFtnyKoIRqCio7
#sCVkQmQ59ki6zmxL4mzyfQ1VXb7qt3g1yrfZfNCRUoteQXpFYahNmDZfhM/qLA5ljzkhXaE0Tkv8G3+E8GP9RoqX74nQfik0U+y8
#BixssUuCb04P5DWNA7KHlSDfJjBf4Z94TIQdEewB9bY9H57zToydU4QUTUxEDgRNT/lVgT0cXduAVYqY0z6cHRX1NQ07heZPRVst
#4GTNQi63IlSJ5DJp5q2v6HQWl9lSLJUJmDuV/hq/HQFpB1PS+sGaXvaSFM/MOH8P9WpEVQ5V11nLkKMsOUpaIf/JR23LtxjCvyeT
#60ocDMUhLpvSBrVFTjJ7WP591RgiX1pXfnAC7DURAwVDujoEY6aaphL9d/QJUaJHEQLsOONOMna5k26Nm4iPvHgtgrunqMW4lvOX
#+dIEiii2LdePePKY/gPBtIMqeQV0AkO9rnssDKIK+av8JNcyetxDkAq1IqWSmTM/ecgJltHtapylbnocrBdMOxEiQFmGWDjHjs1G
#sXgsBqDbTEh2bbTeivXBrTAivu2cLZGp8iHMjiaXK75Z96xKC3iCg4LhNcjTKh8tA9BG3q7yyJBXA+Vjh8FWjT7Y4pjOVbnR4cuM
#dawqNS55LeleoEYaOBSdDVWdQGp68KlpkwTIglFDEHV74S3OlGKxT8nEbln2bOcwF6bGKG0/rDf/1A289qlisw8zdvglVDlK8kpr
#tWEpGhREBI/jUamHREtMsK7xDSM4WYQau1bmAmWMpFtV6q4xPm1gzZRWmbpVMCLjq47gXs0kw0ByxUlqajXFrlJTIJuyw7bG4i2L
#RvUZR61CphmlBswUI1p80/KLwoHKCMUbhRPjEqyRsmkoWa/91uEj1FnqyL/ENTHFKYargaYrzn4oW5SgOnpp2Hh2cAveGcT8eV8/
#l6SSVwohxocY4bWA69srZvwlzf1iQjomVr81Y+U8+fMzqRvXsZ2NkCumE/Yb6ShNwH7N+Y26todxdpB96V532y1vvYU3b3I5RGSE
#/XitlFspEZ5bB9MOvcG7ysPTXWbpCm7745Od6oGW0dKnzNdKD2CEbyYYVJjyjBvMTuikKj8yZR9PhKCNh48qDFN+0CKSQJR0JOjL
#c/Yqo0Q3IBMgB1h/Y3+ABKgMknY4HakLaMcRPgC8sI5zGO7EUlAU06TQvIPt0kRIOlNqAEKMU5uqyp+KjJ0VN/pi+da9UL1zTFvr
#qxhrB5qIWPVrAHVAC9oBWNLdxFVZfjDG6ol4sH0wgJ1d7ObmjU29gvL61hJZPHmsptb28nz0ZgEatCqTHkM7RSMqTXUjCRMGzVxE
#AYD1lFexUZ7VOf67hPcnjT1enanze9r5puYivy66etAHxjubwiglBNnJqorJSvzotfWhe7CZWe8S59dokszvHr+cuudSQXTJq+Pj
#jMFOFgB9K7wcM3DRHzWAyFUSMIhYQN+WX+5SJZ/N+z8AiNMggx52AImkZjmplyxbgkd/tdlJ8xSe9sXs6WoIPJwfWMeuDk9Hy9Zw
#SerLdf1i14xqW7qYK3MXzqUsqpm08qQ6fXWjdX+seWPrwi0EL2jleii+P7XX0rNYN3C03L2MBaMo92kmcuFT18doPaOP7L3xoNVF
#M9gSII+jwE9/Ofbav97QirZP3QzSDcvqfqkcWEST4+1kcEzeZqmpFiCo50MkupBYBIkTPlZQsy0inUneinqRbPeF484/rbSJ3HS0
#ZrarszeyaKdP+Q0EOqMr/gnBA3YZ4VttXUdpOn036b6l0QQ5sRPsuKjSRLjaJdzwnxlyp8tNuiX7xS7aVTr4vR9hbZC3VUrttKw7
#weArz4VnShkjLlORtyySdd9m/BnxSjip2sZEoQ0NugWJONA32ASD77/+S+4tL4tKwsdHBIegW1jwTZ75nuPXopcyg3TnxUxiX92g
#XKYeLakZ8yCOtJZR5fSQ2FcpTMXYcXEUkNkdbzoTk6vBUzDo1YvE9vpYsCjOamPsAp5dnYSzCy9F2M65fD+HnW2iIZ+Rf2uZMhba
#HpiZVoM40IAG3HD4lsfMvh7j4SGuPwDbQPl7O7WWyQFqBs/YN8YtqcaANF/5Y+6zBKGqF5uA7ZACXXtfKmUriycHY0hDgGxQ7Cb1
#rCsARQHXXkSzbzzLN/WdS20xQZ47+Yotnq6fbcJtSrzC/SFY825o/M4sRqS0prmLbknk5rHZMEsJsexYA84Az9bXpOW6S3cdctLY
#1bCxemXkL7iTC3oMKRApIeiiB+qV0RrLuwzMO6eSRalm5naORzo3cEWtEqrtM0kwld2ewiUllnL2mz+zzfpxQnd4AIfsFp79bP0S
#eUo/eamjAR90X+VxDeDSUq+G+H5x3VeAKE0OqjAs7tq8rJDM6ZYivGdrdmFmv0pQXMwudrWZG7S9lbtprecGj9qzyosvZwhqR+j+
#l2y5Z8zaTK7a8E8ZEwNZnkwClu5O0UpYCjgxChSfZ2Ml8xk54T7XzhUuz09SYuC0/2rgxE7OzZk21s3dipWf/RYd7HLcAapfutIr
#MTGhRgRCIzNKN5zk+RjK84hUZdQR8lPtaN8l5Kb6kXRuPp+srVCXxWCx2FZff/9cg6KvgRl5UMPXYEk2jQDuj7FNRgr8QzcAAQBb
#4IeNtit6nJgB9HJ0yC4R9DRlrIeQI3IvW7UAQCZFpQZu/W8NIt3AMLHCQ6WFGstVsCAnXlR/WmD0u1NGCgHjsyjVJkO8YknaQNxv
#J7P1t+79SWs/t4SCayof62QN4AE0ed4UE94poCbk+9j19YD85anRoEeHs/LoaGn5p+HChmoNuMcgHhY+eT/xgp1cAlICcZnlvHjQ
#hc2e9MPM3k9lonQ57BPFlgkGPH4jR8L72sjwbur4YFGZKKKDJLlCBspOwshGDovs+jYUj3bpUnEoTfuPbs02Mc3YdrbywrOA4xY3
#v+39lD6ZDDdVBxdjf0+0jEAPjfk4wZieT1AIvgpPQyxsCkMzeAIEP76g8ZmcNoOgh7nlPB8gB2JRU0ZwiF3ijrn2CvqmCWfN7x+J
#hbpIm66gQtNeCfWI8KJehhH008aWVjAqMn0Y9ty1aU6zu4TRzNdOClxemMJ7P1LF1XoGQJbiUYoOVnljJXGmYAMz+LPVaCQlDD4I
#rjE3ogpRb2+IDhY0QCurnezRI92GZf6YLRHRokAFDBO+WC9qIm4KZiKunWcf4XgUsmJNwYS0pnGMVF7ZhrHBuQSvm84R27oh/IEB
#6kHPSRuUP+gBvf0BIAHY5JHGnwFQGAC04tUJIUVA7JTGQn5HGnf+sWgCkFB59wE+7Jy8bESJn5nt5iIpGlVfYase+MVixickPXpm
#Ekvkt3S6QQ5pYw/9RK1TJNOzcs1H4hItxGrkjJzH6SJFrKk9Iy6LUCnCXm2dKPHTpPyI68amzfSBYXJKA6966tcprFOjIBId6BCe
#Evef8SSKVs7Q+JgBJe6vvSvBHCxRrkIhIIehmpkWeT2THFyOAX+MPJiZ4lbg9mTUNQ8eo3h0AJYJC1B4zVyAicELBZk0uTm3V1GL
#DXlkXB63oYTrIp4puW3PldPlpMObwSgRV2RStIOeZJYYXQxZqfcecfew80/5Wj4RJP8oCLwxa8MJW+ZJbJySnjBn/LFTtKCLO9H4
#K3296Gyt7aE06C9jfeAvQfO/DNVfkBn6XdkL784N4covtL5Sfq1qO6evbvmr0LZwphKl/Lg+aNjjIuE0pcASFOyGBlP4DFkjRcju
#og8nUuvBMBfsWkbYvWlG1uf+7b4IU5xpOX1luTLQ/ERUnUtVaA6oBDjt3un/rG7iYT12KaSxP3UuP1G91f4VK5A49BrD6iZ6kG0c
#YutJWz4el8ynGgwUa61cQjVreSsljazpyC4TBNxWOqAfkltVZlX7ylg9sQ5/XmL0HlChRQEC6J9+yDy8+i9pHozq5WK75hM+H8Hf
#fPi5JZuAAlyD5mvs81FV+vQun+gQrncw5R/lz/PO39EnUyPNwr3Je/Bkbdh1vfwSnfE+t3FyLL+4N3PtCsEvr3j+uOIQH/M7Myzt
#uX+AC+Hcr4xe7B4MYaip9giT6CB36TSokXBpMeK81+C52y8cTqIG5iDj7UEuxIYAX+hLFEeg73n35TTsxLXfm2ejPe3lgHHwROXl
#mPD9sGS5ZT1lh+55OlsbIo6dRMj671qA7pzGNPhkQd9KDMOjo1TztyxlZfU/CHDpKe/pHpGH9RmvAgL1d8cgPSQC3Zr+GO91jNhj
#fou4Gm/QAnXLP8e2tsC8xWMtCpLGrllnTnKLfX1FAgAO+gMkXpWoTelPAfsD6An4G334sXw+WZ2Qn/9jDyLJejxmWPpO8zrwmc1G
#PMWULZ9UqQDpd1jZ0WLGcSCzAWI2LBzT1UpgspZTgSjAEUyp49TLGbzZWIaZOsFmNT0ouoyYIwRrAldUDyPAiFSzjMdzCrU7VGZt
#qnPo8jw4YzA2ivvEgafsC5qrlnxU5eoBFHdm5lRuk7B29BG8AY+yfp9Ozl6zyHhPHcp4J0ubvTbatGKfPImIESxOQ5PyFi4IDrqH
#XJKoN2uSUWvyIA5W+KpGVWlMv/3pOksoiNkTGtcLp1e7i1nJMQSP2AS7nh2HPf9eGVFVIc2hIxPgpXWXHk8Vko8efI8nP/+8CPB6
#OxVq8zTezCLO2NXGJXnfgBWg1clf3faNmXZxiGR68c6fS11dBduk2A7cgu8HWyCm6i2Gvno5zEdXXYsKWzG/XL5T0M3zVubOvuRq
#wn1hiSK/CeLBbduDeQJTpMCfZsm5Q4P4MwvsXszUMkWNIC1UaUh/JNy5upMXkHfuG18t5dV1jRzt4UFeYy/CCHoK5i0Io3RzFWsp
#LplLB9xH2aU6znUMEbvLRnx3XLZ4S8PeexwFlwfACm6MKwgdY6za00ntcaXUB/EXLD+8iDlihrgnFqadwMphXI7TTmuubKmJcozC
#fNJA+yfdEkRs7oO85jNilDZpk0rNyTlpnXST0hffdNj9OOtX0nx7C8DEtWlmh41rab32/rnm3qy7k1P1D9uJ9VInSDuvatU2XYwL
#4K+lRVFmYwIIxVDJwUQtLcCvJA36x1XC85KClqOdiZVfhGO5DeXxTeVQ87ErDi0yxoUtmbXIomcl3wL/bfVNqA/2DbVzp8FAuYJ+
#E9vcg9iDRg06StXCao+KRq/TohRr667e9IkBI/02EyDexndY/k8AHiede/a+Zpva2d7r8e3iDXSNAKtxiV4eGo/TVw6v8nIeELWJ
#mrrTGldTasPTJHi6A5TprIVouzHk5gIqWGhHVbP3FAZq0Er0PWQhpEY0MIOYl2mjf95I8KAT1wq/H5ZM8Q/0WziyCmFSDHmkBNJL
#7tmPczYRW/MWzm98T6tg5mcCLmrYQFxZ108cJumMR7hXn8RHkxOYqdHaptbzn+CZVoWnlFnD5BtWMnSGnLnYhgTBXSd7GheoPxRC
#FFJOMaW52+8SivkxH6IC8cW7auXUqUwbB2+t25hNz8jtbIjDkrJmDNsc+xEsVlWNXM8puPr5d3SZDEYysA9hcm/vCC2+rF5iJH01
#zONjzZabLEWL+haj3kqmZcvjZSdCHPqmJed5qZYUMjNXZkyIEYd7woSHq2HGRWII9s16MWocLRYd1YxG+XIOizbU0NPUKzHxw/N+
#QsJqa43tfVodULnLseWmbT+FxmsxJ3bgTz6Y5kd5mF8OamJ3gamBi62TXPGbZK+6pzf4WGZiecMCZ+Cr5puM/AnnDDrTDq/qgYQ+
#C7J+Zl7AKlhIbkmWaGAYGdtldRwozoatEcB0nRRTneVVSbP8QXXJ1fnL1auGBf8tDr3XbQ2vkvxiEiS8P5z1V+eQYaJ7YoxETh1B
#+YVgahu9Ei5hZWPP7ff0lI02ppd7kYCLg2SRzia7iwCFtzXdgNt7PhPMuJ+bBFvYRq6mEI/mxKOIvuHWsjPTD2+CRnD55OOtSnxq
#REKsyZCBF88P9C1qxKHXiQWEKT2cOxZVE8/PENFI6ECM0EJpAV4LD6eLBAnXuuKrgfAurT3dC6eKpHZtfqXdjmzE2QSceHvTzEHt
#ef1Ma1oqV8pvJpbAZFuqbJ01G0d2TOfLXbKZnzkMvgdjHdRHocT7YCobj97RsYSx20GKrY+33t9rkPVxYEwXGioq7O0meereMG3I
#BG4oeZYYV2IMM9a1KaX/Nj8UU24Dvn319PC/jecp5m/eBPfg8ulH25VkXP4+b8c8oUwsu08rYaKXbVHsEPfE0yfOOW7fGbm+Ocfe
#WmZ4v4h/MW9SvrvG30a1SR9Yb4adwAj7AUhatxbRl5zihkwj45NtzURAGBYB2iu0WfTST+zHp7ezU4ka3HE3zhq27VNWG/GaiIbO
#hBr5p7nfy+O+IjR6Xsfps/dDnTZ8UaZmDcGc7rhd71plCjyehekJbEqNhOsshh83UeyfllHUB8CDI7DPnvYqlxenNhjJMjHtYquc
#vBarSuDbfZCYqiufOZGWU5GrfdACIAD08O5zkqlJnmAjkb0QmLu7pgXKCKWoB9YLmTYHQTXees/B+e+B3W6eKHkWRVpzU0MALkJi
#r0wN+6fQA9PKnj9R9PTsF3Y4M7SZZF45bE1bEUy6eOBnNAZnNuPOZbmoQlTfp1Iu+o6GW3qCrdyXhw9TRrfX1ZHlS8jj2LGnStqA
#HDpBUnKbd4d3mv/emJzGDq2G8Ty+YK8PdrDfP6BnuwsUdT2tYpQfLnnhj97HG2q6v2/W4L0q5nT1a3bspxoSRmghCgWtObKxVEZM
#KtmlLUZOuzI2QEft2Mq0deJzCtCHiDZ2yiP0tFxQh2RV4/ko2vKURZ909rOI7QBcN9t2sZUv7Hg2TRcumHwN24F8swN7hkK+3yED
#sh4Y3DT7O68QsZWkmB3OwJVHTcsTqw/fENR4lM099GeaITl2erOMDtYG5ZDZXXm/IOK/yPAlTc6fLy1KVZkfUQHjpc9Ppovn5D+N
#2hWi+Qmza7jfUFBXfPGHhFSw0qRF/pzlc3hbTKK9C6ZJVXtp1H/zXQwalRDOQTXhlJWptVZ5BJav5Nh9f7uYk21Kzborq8uiv5hB
#I8zL+t8rMzuJnz202RZITw3mjRbfyjWF9OnQcLTk/enGx2vHolEyWcdLFKyzGHDshRoCs/NtQPXiGmIUzsR1wXWLAZWIY3QgliFZ
#ZCzs7a06w8gEpdJqw3HJ/NOgGs+A1pv7/qADlQVvxYJTiBpEOOGB3J+7LFMBdjm86BKIa0kNZl9pg4pj7fnaGUcvtayehRQJ7nqG
#9CSgWaUd1xgJwUQRWlYC2vALncy6YKHTdrTZGr5haUyEMy0FO6gMO7oMek9aqXoF2Mko29+zZpCo/F5lAiXruG512/eJXG2SKA96
#X9ak7qxieX0U9s1lESPSpOs4icXyEvUd1FyYUoYfVKYwFzaAfjsmDsKFm36Vz0R/zLWUAkwuiyeoWx7qn7Qupi6N5WUjvscHyuoy
#71L1nLVOriDrmfRRONpR/dMALZQX/YCjajRUqLZHU4m43peDJn5lCOJMeIU20LWbXtdWtUQz46GgIT33wRLZCk3m+S3Gn3gLxO5l
#cg4kWZssxaF7+oGfweNLv3mXIFmGseGjPHm2sJ74o8F6ZPJiD58sD3LS9eoAzBItJYAaXG+mSvq3RZteMpr9WXvShCztjw37exsq
#+aU3CicD5OnDis6gBGaM3W6NlQHLnEewEr5vHP15RozYGDWjywSa2g7nOQzmmRJRxnep+5PqYfk69uaKwCnM4eMuq2L1XvpN+K9B
#jwkE8CHE1ugxStfAhqIWVGb8jr4M52otLK4eD7pr4/ymMWd/CCDZaL0sn8HGnlwzjmRVuqdAhFumGABklpBu494025yGkX4tGTtn
#Uk7M/qyBlywaK9emQuW1fzxx2JPdeUjBjlj3pd3tZixkwtLxOJwf6ccDeQuiP2upbCJHnR8DxBl8pogLF8eCxFz0y1t5x13koKwA
#H4xVG7A8hzpMAn59rRVn9vIMWhYu1D1hPsGIdSvOHE8zTqfdAQhSfFoejvcVoqqC4cpFzLgUlM8Gk7BwZFafV4gJoY4MoAoIYOZM
#G75r2QD6Ra2Mb0VZnVR4WnI2499sYFdpEOe3U+B7l6AFJyVGkM8XGD3nJEyB/BuTjExuMc6l4WHaVFpVnYMQfgyAoQur4LqiVJJS
#BQHgJPyBy8KPCDK4cRVsrAmcKXmbyDVQWgJDFE8HS9hMZBjaiPu9xXpyQUKkdzfrw/XJlXAU2smoMR21fEU+inEl6+WLy4J74AEY
#AG+35CjgA8G98BmmWnGlF2Wh0LMB6iuakmCbuLlpUdbH2AaStbBOJAlMvVyQ10tra1HTvsU0VJIFfSyZMuayfrzx7y4e8rZrPS8P
#lrLFHF75wgdsBNScTpeXHUbVGbEstE8TK1IkAhukNpadxaBAm4eJhXJpQ7wlEERs5VwqwKi+RNABhVicwvIEK4ULDvIiDb92DsLw
#pvct1F/q0GrV/hQtF9FgUlYV9MYP8TIv91ZdiydCsVXLhdbi24x0YoYRXiodmYYNQhFccUEGFGiLxYRCekdyg4Rx5FqTnex0HT+7
#56CYPgRdNwKStL+pSvSLVsc1rF7WRqxmkCZp2T7WiQWLk8XUHneLxk1MKpJpkpJKFv7lua5kuakqk+Z+/ZHZzmrxKWLqLunkG7q6
#wIg4gJNRUrB33Ai5Ebf4/Ci314g0LYmDQiylKibzw2oUxn00It0Jmf5GjzyBF1ZVYq0uZLlXxzvHO7TDLnQzMuaf4CQIqnRbCWho
#9VEheZa3CIxkMzod903IXRf1eX/QqpZ283p4hPyKpv7qXOZ2f9UH9rMEG7AEl2jIav57MjDOQbffITzA4gWKI1peSaxftZYqJEsr
#8+gKhs7a7g/2ObjRv1G1sV+cTpa4BN8S8iVcU6MYuc4REszJf9/zaK+4B+5BcZ5Gk+5TeOtl75GB7EHDp3kQ4Hu2faS5rjB0mZPv
#kBUJKxL62pfGnSmm2tz5MFLCCTykAvw7WhP72/u6C+37Ga90QpzGY1cpAPNpV7OOKdOWLKg+6qxzziRR0cFBmmD5baph08ooeTvO
#h0Baw9aOJi3gShHl1XNs13iWVBr8uT+AHRk504kMIts0sb4yLOx6mTeBXqhKiHBBZnO6ehkNohYuSInQsOAkQ4pANTfS5Ekg/u5H
#Cl2wDZ0JrRF7rs+dwDJuIJjlYDfPbgprCp0qGSUU8GdEU2aPyJ3zYDNlYt/AOVWZtGlLgyCGy4rZXrm+LFYvuLdUhdouU7CeBald
#JBJyKf7HF31KsgDVHqbuSEgFwCbw7QMNz2Jx5qM/z4kuATguVssYby3x6mNADRi5v6VQHAKWDr6itbuA4z0VajG9P8eFP0Qhrm5p
#TNBakhc0iC9cLrHEGrOpzcEwsoC0fe8mUQWLDbOpIFG1FiaP8Rg6RKkpQqU+7duhwhi37eveSVj3WIqVEXIgvXYsJwv+2M1u/rIs
#y9f0cb9ytCZlJE4w8xGJATjPVpJBq1KdBT1Onymyv6ZZyQ5YYe0vJwxjBq0cwweJve+VsY8ceY1pTtUniBItBYXryBg4gAcnI04k
#MS9Hgee8cexGFB5smZIqIB9/gHQxeYNGj2jyzBwIKFQ+QGCk3MnJIHrRSii4Qpc1F2bIV5fafV7N/P3T/dpL5qOfRceffdAk3IXB
#Gtv1TPTx3YHpTN33OaagB4vNyr80pwAMwORjDOT/ZJbQ/yn8WG18Bk7QlZUCG7rc8GmMzZxhIaa2YcuJKsF2pNIf8ateyEjx9IL0
#ejgZ8+YS9IYVGXUFylypYEpNYf4np+OFPDLKkShuBYg6gPHC5Tz6196tQ4vYT1U37EevuR1tEV8hUb9oaI0OdZUHca3xMxy+bqaO
#NcbC6D6ePJaURuHkkUeU9o/aiXN1OWRcZGECTJT8irczqkCKjY15/Zh/4wZgANWmGTpkRR7EbftrODx9fdggB+fdIvAKZzdkUPg/
#o9VeBESt7MSEaCwEZJUXvUMDdCh0EY1trYO14XRNltexZGBpE7hupBxUMh2WPB4Ji4JuSdxzZPexbgUKzyLX4z6HANf2QhoZ10+Q
#WMSwwycxGRmhPGoTLOqBQnqVJmqe+REDUk1EgTyltiFKhjQByKcQuf/Oii4CDMYeiHhJDGhZQUriqq/Y3o95G5FMTPtVHTI6Ntmo
#DWsdB1ocOHXA1amvDsDahXYljCnoKf/T/sT8MhbMDIp87ABmLi/7ay1lWXNr0o5xuX9N0MHe99eo5wB8N3Jy/qbqSIqw5koz7yMz
#hYe5hO0IM/2VvDicQGW690LZX9wOms9ygc4iPNyJ2OE+Rze+NZy2W/KVBViAtYHssO3n7URPEj3Ma6djm0zcZlAdB1kW7i/o+cCU
#+5fv4tLNfLLd+RlPJKLfof1bpryBP/qkafrPv+A1QKwEsS2taFtTwn4dD4s+qJwL7o38OerwvXeWsR1q68oBOoZ/8+ozZWUNMC91
#sQO0ojKvG4jCvp6HQwajLIcxT43V/51e3NBqKx9x0dneBhR5GwRBU9Ue+fYD7nas/iGVizC3WM0A1e2s2AWVeQuJ7fpAu/MGiOuU
#r7p2nSimJlTuIPTGBqF+SajiDhztlQKz5uj8EDzq/5D7vsMlx3CZ4lxymGo9WaweY8xojOEUloMtTqM3ke21hUjDSVYS17jkEjSv
#Fken4xQhfGMYhN2VBOL2moFm+dCiXuvklygGcimwAfcBx2JbeVUGmCoFcXIZNi8bfd32eW0eh2Y6YX5LeX4+bbYBr/r3tnAgk1DX
#spVheFflXsg+vVY6Y91j17IR8G/6tE6EWoNfKm9GOcfjfEbJCkBRPJVQuwSHNaqi43179ek21f3xexT8ja7qcs4R8RKxuRB6BXR1
#2IQM0roZOix4oSjFLleZCGT0/erNnPsHzpElvd4Fd8kOHtmxXjobXZraNRAAHr5D1rJSYyYYw42faYCt3rfezFF6lHR/HXjJ6G3h
#u85YSlH1nY2E+6CMsep0LgKNYNpU9OeHahkRVkeQ+i8aPmaKpv9jujU+K9a1XIp127CgCz+AGkXGzccd7nT2b0fn4DmWDm4IcpyZ
#FMkH1jjq1ZqB/8A76Z0BcxabRhCh+4TK2nY7EAJd/5GwV/m2ew2EFcCmBTetAmLrfxN5uAAhQhWIdp+5I88E46E47WPMoOKyxVM8
#gC62D5fd4pZKPhvIRj6CZMieApYFNTwHUBNvXw+4cj5Ve7CbsWQMo2nQ1e4I9G0DOp8YEcnQI0kep1End7lSmV6lIYNe9/AacPHm
#skgpqwbI2uDIVDZqnQGiUqIA2S8nDaAPM/E/gEPNh64G6eIo5zc/SQFJM41M9fCZXocs0PFIoSa7hKDEyRrS2TTljfv1zQvLtztq
#D9yGkiEcjeyn9d6gikurFJLSdtphFLMJE7HiMP+Y5p6BIqbmSNWhKVNRQBCWRjRwRbm3GTTiQNaOZbEUJtLIJ8cRmSOalqQ23mnn
#RkME3KIAHS3HtRmuDN9InQdAUXSA9MrV7zw2NpNPBkEzmjxY1Mg7LRwWiJqcCRgKTmbc+cQDAp4WKjCQGXI8Q5plcqS9MFDsISpC
#/pOkzAclZX9ae0q5DVHoDtGyVcNvFf2sKg/KojUcpSILqFkKH8M8LHG95qQJLV/LQ8bF8kX/z7dupGNyZHs7e1XzVsmCQzQFWmtI
#3kvQ8q868zzMnCuZxLQM6fv//Y3n6Hn4flnUqZHWuo73MoGwrly/z6IbVqH5jKrHggui46qW4CgBqlglzBThTU5XgXBYiSOzUTW8
#BBx7NNuqGIzYZcFLvRqxEvTPV2djVRDsO+6e4H/oDil7Vj1ADnqsRSRdLMLYDAVAUDOtR+/hFsoJKW2iMmOGRh+hOY4vSnSA7Be3
#NI1575+iHbb42YHBP5UIAZDUD0vbVyQrW5GhomlFjRcaJmrGxbUNSNEf+gL5AqjGQrdJYu830Rh6rNfsZiM0RTyef2LhnFHYN0LQ
#Y9S2BQaFmBYx2dcpW6oJmwZuCUqvaah3bKurRjm0A659fzigX1Q62OIZBp/KNw8HKgonH5mBGgaNvBShYNwisHF2h5xLQbdDSt+X
#fmW+pCkEu0QT3D9HoWR1IPQLOXk2Dd/9syI2zHEo2Ukk3scGnvfn9y6+/1XQuxOayZm6Yx5He8a5lD5pjFVIAMB+1CT3lFjbEfK1
#ErsPLIDk8y4mJuWuCdJOpkOpc0bBFOibkyJGb0wZ4q9eon4jyJz+gxOflOpBDL6skYnD4ixC8mddDT5I67HUKmFPbZu8CE+CHgC3
#jqoOidGcySzgrNmaimBVqCtYZsndYTXmhJtRgfXdqY5y7zN8n9ZFxZgH3rWOrwRafMaIRE2ovJjS40Fmu1Ot6CdOnDPiMGnj3v8I
#A7+/nxgaG5h6cGgY473FgqkQ4cxzJgLzax+JO6NpDYWgftWPF1MYrWfX8u1UDW6RBCXJWaPYIfiUigJdF+hvmTmEbNbh/KFDt6QI
#AFQ+4H4nA9EzsAb0JwTjS9UaQVsfh+hCSWhoEfAH2KArvtgYANqHkQ/Larop5L4tMui6nXNkTAAd9DDijmctQfh69ueoKiCcMIeI
#bzXSZlmAp2k0aeqRrRGC5oosBwrivDGXICUJHSz7F5Zl1zW4+6plt1nTnyAJYcHAhuKKaiVufGTI3ulpKgmq8o2h7ornxwIKaqah
#l82moSg7T6xoqpGxXgHZQ0JiB+kj7hBIIQlR2K3wQyRgVa18ZVCdyceXBOLSr3bCF2GZEeh/xb0Qua3ifrvqtO2G+W4oPA+VucCJ
#tgSIlFYHgIchPJjR2reIWLNuw/ld5Ol5kgqBhGrgF2wt1CdmkwvyPUdbP/cIzqNjYc5ObWbggLqKG6u0dfM7R1LQ8lDxpHQPH9qF
#eaY66kPGNL6jTzTTY9DjTz6DzUBP1pfbo9VM9UGsikrwEe1YrzkCY4SfKzJI68sjA+AYdTJLslxhJFR/bP7hQv+RBr0XCbmXlwbk
#WIEEhL7SCpKeXaLCrzk8HKlVbnbiEGPf79KilMnEva8oWdLwAMn/uMB0mh4F2K/H0Etk6GUzkcDDRaGDZfnAgZ7uVA3XA/9K7n6w
#PEP/tu8Otq6oUOoJ2yjqnUDqtAJ8wtPA1FJgJ1tTqsIQSR1oBi/LbNrXBjjHaGQg7ta2V4P2dtVrRpcNppbEeSLQ6tygxjQR/9yK
#EkYT0P53fWYOZgt5fGrmUF+MDIk7zLb0pasrM6bkAThNKa+Vp7NEsEPGRzQIjcaDpY9VoAT0uCFFIrNz7wv/Cv/VFrbVdPM823ne
#rjTl1PniB5dgCKtGZiQBNHlY+FSRLkCvB2J8FHDcMHxDJonXu1JsIr4J9h3q7QD0EBqOGEER5uciV2eh31jkBEURQYS+50luLOge
#6OgPNEgVA3po5N/tRJKH5dBzETr9hJEEl/yaNM80LuLN7SkaRFo46DM9qArSn0JEedrkX+GPVSnDzV3Ivtg9fuLytJkDN81gCgid
#iMP4SMbit/oUVB0M/jeOhwrRLtFzEb4kJxazBtpklgA9dqRb6WLDSE0R1wMAQMQU2o72fImVKs0tBDHL2MbLUJ07B1rV4whYuDUE
#anrIErTZDl5mnfDN74y6kaaJqaSTSaOnWuK+XXGz7B0CFdpWl3m6PIIDSw/IygG+KDR96ygBi1qXNKwmp4t9zfNZ7cGdtimX6XTc
#QufrIln0OvX1QtaeTRb8LD6n3nEHa0OXkSdMHjyQX0Nm22VWpDagpnOjCzboaMy1iP0QLCJMS2AVjhMzSel1Cmjen9f39/5zltfN
#18eLW/vPm7NPLxPKFIera2TKV+LEw/vjtRmhlmfrhbCw4yjpPNvbYC5P89lonqUjM8Ep1h22cIlnIwgB8UpK3/fX8P7Z4Z9XQ167
#yZHJkudtHurlW7RdfAFb/3RyLOcIyGtAI6p8NfbY/NqQHZ2epVBOTDy2z44Z7KDBnPPwKlvIyo16KJBWg0/9U/ft0ml9kg7ASBRn
#wE9WVsicVabBUVbkyvQyGYazO+L7szHXv8KpH8+P9jvrjLBh4NIw3zergHDk6OaqqpYzx0kLn9vjXwiwLKt+1rlTVqhkZL7iRdRZ
#kn1TfXn7fv0L/LapXrV0kSX5x9pU26Hj7qw7ioGuapda2Mkt6k5segYQDOpk3qw6AoFgPfJTqBg/+J6JXeMW2ydatSW39czXJs+c
#AHszWw/qujLgp4MPijYOn2zEJtxVBHPAfLAXqFQJ9tdxiD+0i4UCHj5pMszSo6Pd+s/QuEYizqtQZgJvsq9WdprgBda4+RkcO3WJ
#SM1SdP1RDvHve38CoZVAiUJM//nKIDtha4EtiDvksU2047QA3GAXDXAQb4zjZCxdmBcGJzgMK8pu7Lpuy77lQREdN6z7+mGU3+k1
#NPrlW7ypHVeWb5O2IDCXbpMSdQr4PT6emNPEHxKY6aaX8+Ug6AtmKpZWjuwno1NJuS4hHVA7u0dUMZI4PEPH6iku3SCPSIW3Q4ii
#4mU2prh5LRpYIOA/OIPGjCNbEyfzZtVM9O8583bhDWHwFlDdaBturb5qIC/LXU1s+G7SmyzzDjYs8eZpslv9Bb5S9xEYrkTFU2tR
#JZ7ZzidKpdut6bl+YHYFKautfOk+ZF8pOojeeU8t27aXl6v7kbL5KVokMr4MOuQObKqPOuNXaQnyveWMumP39Ts05j22Fbadc8IZ
#W7arvZe6oaBxontcPAvcrN3jT0U5kk67r6Fw/LDGBj13q7axxfR/cuSjAdzHsaHAABjLXLGUYE3BMVighVHQGGfvA+mF2DCsRUCi
#p3sZWwdAMf0qqgeVLpBCYdzyEHVS1jiVZiE3vGNpuMv9vUP7yu/VrZbYLYQHJauorr7pY+UEG1K6WwvNoAaFFVxn7sReJQ5Qp8nJ
#VBuxJ1m0aFMuPkvLT2zVuqpnkay2+7duY4iVlBFSe1xLrbAvqZbZUbm8++I/SpJO29TvabB/o9j+i8byUqZTPv1uowI38FZ/Opvf
#cqyK/U8dcBN955kArwSEvarGAuhg/wBgmuWnsymOlHF8SJUo9S9EDcCmn2u6YC+1k278o1s0e3eU8ox4WIf50DShaLlewaT/+ive
#puRE/Ip96f3zeYmfjo3IBbgr3g9SA/bnkEuUo8xtbkewMuBETp5ydf3jv0kvDKpbNgPFl4yKTJKu/3CQRhCcdCUYRIwJJJelixry
#Z0EPRVqsVGNTCQkQf4hhMWhRwUuPlEoa7viQNuQ83voAbM9AvEicI++HPkzKl0xI2QTzQUOlCh7oapm0soJOwP667HKoggXTWPjT
#mje9KEUFpQPsjeZbg/hl9f455QCsQIIDNdOhUFOQjaJA68S0HFWyO9aPCaW428ZP9PjsU9n8hlG+3bDn+b0+ft+fOnh59OreWXht
#7Vqk0Y7x+4z4fUFI6kxgwSOFnU7ifl8DYmr0mj5O6MXbU16y5+SPszcsokN61JXNqQK4aGVq56RD8meVxdnpgt56biCfvhfMFPyA
#GHPpAb4JAvhHBUR3A34mlcLiY+wQL6VFAHpUsnpQ+k0N3OPl+i8n7qCU3eyRX2bjS82EWWgZyeAatDdmZ3zcqNEgwYkVhY41nIt6
#pfS9jqRuhpLutXSPkYC+835QO1kdHbLxcEsqgqPLaCpr9g+igmow/q6PDmpncDGj/8Ou6MIkDKAZJJoKFJUE/ymla78MAZnQEQ01
#AkxPoqfgSu4RImDvvHmmMPw3GnTlOuo0LmAMId40g9itdTdL828jMQTh5sqaO3UXjH1o7PfNmH0Rk3f0fMGFp7jb4GukvGE4Q5yk
#i2VjlpuAeotvv6ha0BsCnMKXROZJbtrD8+2UI89OLbXQNzDL8o3A6OjjEOK41yHo/LAnkFA0SqBdtA04Mg48sfD9+jTSKdTcSkXf
#5+ynV55LHm7fJaV9gt2c0H4hFtgHfYG4NHA2N6kObXfxuHV5IR4nQlomNjJyxjh8AULNSdY/7v7j+/3095RKlZhHrrc8M+/aVAlw
#xB2iuYaE1gnOO0YqdVAtiBVFTcicvJBddEiRX1fQ1uZs58XbQoIswViebRc918Uye6ZF8PDDvadxHNwn3m4WyfCpMFAG6ltSTNAZ
#Fk/ctXxK7f325iCzZHyU/njeq6QeaADvfq8W2Odx9MsbwdCzZcQIiZpsrj7YMd37UOtCJDgxpatQoGz3ypBHjqGNnKQrwMYL1FPc
#bXORRxPVvSPHO5fwLiS5LIzIzMBimp77dunfJW/hu/vDxX4gbdz8+qgFcHYG0Z8C+uq82B8YeQEUPML5TbMHFIF7ljn4nymBdTYQ
#7MGm7R8OGw1CD7YApTAaFUWX1oEVY4uuqkgIFq37OvaeSCvWGM7NGQLO5Un27ZYQz1C1hOkzbthzot8ZY+Ck2WdyFO6L4R5xN6IM
#0w3RmaZ+OYao1PHIvKoYRaCxnLJoNiUlb05pAEY85XrRQnPFB2c5LOWqN07kJasP5hRkKGrOWZhRmzSRq4Bc0lMqkky3OBq9KuoY
#TFTUSK491lxlV/Yh0ypTHJDXFNG6H+/U+bpfj5K+3/kwTRvw4FpEGOVDEjq3/ZT/xNXQDts8wbIIPUFzbSs7MWfE8TtmjnNmkXJt
#evK/a4AvkCCskHFAbzsmi+dg8PO0A2cIK9Oby5MXwNcCEMA5Pt6Asrvc3p9nY+/9nhvkHekKM68Y7RjdvDkvKl1Ym4zAO2z3UVXF
#CAK4QvS8H/XTJtf2YzTuK/28sX9dC+d7lm9mLmyHtG3v/PFBP9uerK4434hT9uuWNnOoubMImTpZ3g+r22eWXnnlNiTdoWaeAANJ
#bW/YhU1l3VUJB5hd/gh+v9wR9gWBmnEz4qxmclXJeLLJvj7gQLm8Of0XTUtldXPuo0s2TlzJkQ42+29//0TVjoxWtQWkZCP7jE2J
#mQLAYn1avkrumzej17XsvICJbXvtmOlcXh+hs+itd7dnqHib/NWnLpwmFHpp9K9bo249d9Wh0iaY3Gx3QimHImdI0LzPbpyxmtMk
#njDClrZl5/JbF9gaiHZH85jsav4qnE/T+/cDWv0g44OgQMqZo2U57D2TbNlzZtFn7Oj2ZB3zMeN6Zn92Xk7cVnblwKnMpJzcPn6n
#GcR4rD+oqz6sWtBk1OZRktSOpD7/nECQnu6Wb6hA+LPeSU1fJe276fed23FhC5wJJdFVE+6ege9WVXQu7jfZCksjFzkOn5OdbmMz
#UidlD0HllOwapi3082Jr/NNUgLmLAC8w2Syc5u+aBSn5o9bFLcZDVNIFgTWTrQzCYCMTMyvsyrpmay5AjR2mhS8e01m52Qq8Zoo5
#BuOQV4f3aJ6wZ4zUfuiy2dxpmvonXdSRsnnTAux1hSr47mL1l3r43QIqQQJ5fDk/yfM/T3U6/YX1559I93OhEe9L3Wt+rs1FmvwF
#avuawoSK7vAjfun3leYA8/zef4I99vidrMkq//G/wyj2q4AQGFBzDwB589G6fIVPz4mNjqHLq9oWad23lHEGvTsbcFq6IfpdcAvY
#0xeWVQXYT5P7c+izD3jjKAFEzfYA7x3Do3lRHt4Ha6JxJ+2K5FnGShB8WsQ8Dry5HJ3jXU3949NPUNmTrBIPuH2GIa9i9N4Jo+Xu
#DfPPS8QPkT2QDfe3t9fbNebjFdpR6dRjepMqr9nY8+jtH2tL0QNszGg1v/KY3W6BcBWvpxeq3UPsbU/r9rTz29+N9oJxf1NVqQEf
#s2fZ64SsCND2C16JLUWn6bFqzSnqoP3RLbgOQbXQlfQ7cDH/DM4b7pPpXPvA63ia1t3PC6k2yfy9pw80nvNYHnQHcmgstv9r0uIN
#w3u65Fvzfdgz4D6HnlGAHjKgeA4NOJLNqFBVfAzTTmIfM5IoIp2TwIZ3dyyakDhoAs65uh/d3lPnLeiuS67jFcfXvG/T85eDJPjm
#azgmvyF0yPRlJf+XAWVmAXMjS9QREGpLmNHliWMrdUSTxtvdjARWz+o5ZNTCrLIWpG4rECvsSH+/+fNUdX99jPS+GqKCUpKyj6Cj
#x1E2e85T8Tl4JKQxS/T7ab0Fv0nHzPKKRVfKso/eU/s56k7/jDnCD36KPfPTzeGWfAZteKFfeSWXCVWZG7AtUIIFnWkUCZZkf3hF
#Wp+F1zQo75Lmjy9M133ZZVxh3ZxaMLioLnGBNVbtraS4EgUVOM0OYsxLN1he1NHvk4c7b2GQyYOC8w6ANzvPjyTq9S4hVPiRkMyy
#RHVxIM70LIU3gUinkXZNvO8p3N0hRPJ3PdAIq9R+KWzWP2fQQ/L8KDJXR+fQyaZEMskiEeE05JpapVJAcjJ5PK5qVq/D6d1hSESz
#0AXLIYHy+aOhieYbCAqx1xa7GKJamDtmCmMhe4ZdSbKMSThdGaGxQicd2kUdfSx8/MTCTq0AEMVQTceefoWkO6fQqKNI1eiTBBka
#SrF/129Ag7x3arCSU+fAwKmS+nydqpcJEqlCoGomivcstO0r2SOWb/8yDU5JQGE3y0E6Zbfx2+DPDc/J02OQeNVMZu7B+HR6lP1E
#1z7+D1vRc5fjL00n9a4y5HWdehx7QCgYCrl2gxW0NgqBUqpZ3YiEWLP4WsO+Z3WTYm1V+kZF5jvLPv+V65xiBFYYhpkHKlQqJpTl
#gjG+IAmxWgzLNlqRDcM6b3bX7vlC27j01hPDPDBi9KoibffT/Sa/N5YD678ppwxiWpJVcFqlRVuxXvxsIRWDjZLzUUwTxBFNVRzD
#uTItiqL4Yh2lqjAOcdjoGEdZ7RzjxHmMI9WnH2Lhs+Z636XkKlGDdC2yMGxdpl2McKAcg0U+MQnUeDR7X7kJFhzJVaoUq2bhuFnf
#4YUR+t6zDhnsgGRaaKAj/u1WjTkd2DTMMJGihI+h7sEsTbNN4SRBS9X/5qInzgeT8iBGyKgUIietD5Pu6tDaZZJP2L7ZVIPq6uJH
#MHzCBhFfDHRmMtjOOvBHZtjcG7yN23iqeo0zrO9tRSDciHj9NfFwiNzZ4lvUcf8If3XxfpshLycc5L5m8a5pfaq168PeQHTk7P4+
#FJir/fGIA+E11tzp7Bz83umJVeNwbs+3lJ0bIMrSC3cVf4gA75h37qHArnAutvUrA4DC0gECpYHqArQPU7Sij+CKDZAsIYRuTr9K
#e3hn9378/aEX/ST25j6bQof4KfMebkVh0hY4Qr9QTMFeqg1ddLse6hEfvbEVvF6wjfbZ0K1jYV4auZT+Bb1Vbg1PX90zmL3Bu909
#TmP6EBMzt1LG4gZV3yZsiJPH9nFAUnpnPHe3XMBkfCs8oXgssVlH5xIuINEnfqMpgcZPc4RkoQbmuACrAqLPAzy+AK2gZFuFsqIQ
#cmjmpLxjnHmeup66jrpWZoEIvINdyyV+xRrNUJNA5PMRE9dJs8h2rLFuEIgrveiUJs065dvR8RSpYKpfTEmYdDqbdt6Kem/VZ6EW
#JCsqaogeAMdXdMj09om/DzAn9znNBdhRUW6A/x+TPP9v8r/wfxtbGFo7GdI6mLoYW/x37Tf7/xvt9/+d/73/m4mZiZXhf/J/MzIz
#sv3//u//E/kf/m+ycgC4/6oGOP/pK/4/+r/dsbtUcILd/0v/TYMIAbXLMsoIHeT937TfYS7/pf2mAQ+DxKZWRG18CnHk9vf83bY/
#mBaodwR4ZJwVUUmanPz9q+8/hThgsfZwFVVaepflh1saMwQyqmcJB9mAq6p3iuqUvVrIee0kFzomiab5fqqCXG6b+3lD7z5BDxhp
#uoOI8UmUfu72+/N52Tyb9gH2Mew/p0ZlokDG1UpgogwmHl+w+Oufq3n7A/IcljCMloeJj0ekhMHgxUBKimwAJD5lw0B19q3vz6eN
#5uYUlWNk56WJFv6qVaxVNAl/TTlNe6pabkWXuiX0fes/5Gx2KPHvPBn2O5ybJbjahsoiTufCWWeMFFrA/359vdVkDvA9IJMcFMkc
#V4ZkaWpe+/0B76K0anu6byCtALExL6XFfz1mzR1N+IEwTSqFSDsIQw/4wO6VSUyaIMmQSTRJJPlPJZFs/FNWVc+WLxNvF7ZMuc0W
#gtVGkN/QWU1mI/s6ACZx4PBXfWaWRH8Rl6ADiYrMICtdcJGyNrZNpk7WmlwN450bagXP/bvNYnO2LjMPCO34ielUYznTVlyXNCmK
#P9qBL+PvCuUuFV3HChAp9H5ykm3fhXemWN7sTOLceaOIECEiuf9rnbtI0hbgT30fUD3caf6amorLo0s1URpplHTIYjAAGbSPqpyX
#iK5IfG/VX+keZjLeizc6DGGJSoib69n6W8qKmF275dbkTCQhLspKiG6eq/tqy/OERzpfzxWvSaIgoqKgwmL+5XqdQjIA7acJF+1U
#yM/vl6Y4/mEWaMYaFOYRKZQJtxEKd1JFYM0kyGwR2HFBPmytI7zlIRkuFK4XSSpGtf/dgmAQbuyB8Op1Xhx4WybSZOXI1VZTgVMR
#Efgr9ida6MVHESx++RIQLnWeTCvGOgT4Bf0CS5VXIYWuBoBCvNgEE3XnFoxvcydinqP7VGUSofOfDw1HBD6Qw89gvZRuIARREf9+
#nOkBZcLg9wU+LB5hPFbrfsSaSbBZJ3A+r4cH5F2POJoxDWcPj9SKyemC5jLjWhTsYZYiu3GMg+fN68HejrXNcLqx5kFNqvE0pda7
#dSegpBiY0VsHGntu3znj+awWLN+et5HICkf6venqvXZOf3rju3hzhjsfmnULlXmCRogMwE4fW6iQe36KxZ07Wlx4bWsTFSxdAL3L
#pdrc/JTS0hxg5BfjkoLO2nkmY5eTJIES/fWe+XnoXGlo1srdP9JOUlb0AcoAOKeK/5vh7wmD/r2c89X2ee5t48XVe0JKcP4msTtP
#F9++q+/aBgtoz2HTPkNn34IaPPtAiMxLyyidZBRLHfi8rIhKZ8tEn/cQMYMQFjbR5TtW1Tuem27jfizyA+7BLJw42gZdMKrLrfkD
#RXq7IrAEbg5/pIJj+A3mz4BbIhuFVIC1Kn2p2AQ9xNzfdE2P9BuqsWGllOy+pcWbPbcRvEPZ7Uw8rKQ+t7yPXgEg55HG1X1Jr62/
#b509F5jiqQ9Zmjng5gh8ywJwzRy1PVr92Z3p3N+MhqH7zwYERrAu4g5ecl0iHhzyEh3Karq80qUVAwEDKw1bQDWyFYKQMvbHmAOd
#RZRtNhVFC4ylxIkBT6QsLJ8jP+6stknwfiocB65Hd7qDYwP78Rfp6E+x6QvB6+R8likoC4Db7AZFyAD4FHlPX5dhQ1+vj1BGVIiX
#qrQkTkVPMOM6fQaVmoEGJ4m8ryFmp96SibxUJLhDBUAvlCw6F8r3llYQeITRfu0TKfiuORhFjCFFllitZGMW4KlPYCAqmcrOgQu3
#u62wktF6w92LNQAUSYRd5l1cvHsE42L6jeG4U/9S/xtByMxCEOTNOTtnAoeGGAzGFMm0VajNtqvUx8vV11Wca2l8eZiwy7iRlneG
#B0tStwV/HDWTFqWkLVc9ie9eJoDvEm/Y1j6okbu+NAm21xEr+UttbfHP5zCYVkQmy2E5iW6a5ZQXvSmsyz8Pfz5nMAgfBBIRjLp0
#OowdjKLojgjHFH2HMCCJHw8c17i3bwmGCIFClpWvdgdDckwq9n+u+doQSLUJfUQtpFJSk+AMlxIBo4qojJxeFpENn0ivJAb6aG31
#jIkno7hQ4a6FL7kCkJjCSMAhtUUuNk4cl0MaUEk+j35CQId8UYXmYj/n/7badmXEKAI08jTcrMzX9g1yBD5KJWyQuudyvSKtOFnR
#x2bcfhgW6yGEbRxtgfuG0VlGOEY3fwjdxOkz0rrwWYbWhbcY9O6JYG4VdY9rmWy15L7oqfoQ6/6IWPvIX/X9G4WdXilY00YmlN9e
#2oKATGM7zDfuJFaffYli90/K2eGhdXWyyvQ3D2da8xDesbFSw7YBZm3nLp6osgNMwhlEN78Op4YPAAwcKqyNb38dThP2UR6pjDl3
#UzP18ea15ay1lNKux8GZz3PF1WShbqgSFk9vXzpTTEYdPM5m/+B7ltW7pSP0luF/ct2B4adQRwUdgCCmwDAMZqRgsxAU6EKoCSGh
#pVWF0aGkmglliWaN+U/LEdWsJIVODKeZ4Yqs5YK6pOpZdtG32GI1GY/QYZUfqp8RDUuPRIShL+vU71aJ7GgebywcdxzlmYmTz4e5
#Uj7RCxjn9AMBf4gGQbE3gYBc9H82Ag/f9/6AOeK4KFDgRaqif1iSqKp1B9aYHnvKphh5qS9wURjAjsCuV7+/rpxEfsHfpUtd9fS7
#9bb10KPJAdJVHfYIB6IWsQ6VGYao7dHz782W5Sz/TP1TU0lyaCYy+PfOui5e/a9FHJyOgFL2w+w3G9hDt5AlO87GZ2C1embSVqyc
#OG5oTsu8OdTsOx4ln5W57N6xEpgmWrFi/aKSJUWP/Y9z3Eh2HgdPYY+hbpU9dJBvzi54fzIvN+26ICtVPjBeXCDRhilSbBZen83m
#1S2NeNvGPFqA7bOhFabRN+9RApfbK9URmf9R1EQuuJJ6EHl11juLshGc2L8DzcU/yv6eYlC1U43gOHrKE4s1+6psigFCu2q5HaBg
#kGs8MFu5Q6tU+2sTkFx5QzIlVLLz2sWY1FRCXZ1ky2+MJyR8HEijHy8FGT61u9oU/iRKIu7CF51IZFUoGAJVUERRJDFjvFBKWmwR
#Mmemo3RnJyPgxnMjkgx3oZg4U01SH4wpoaDaBMFNPz+yNdZgtHM6Y/CacgbRzmXndN9fE4vZGfnABWWcyKZXLuR2FbaHXrWgy6vk
#rQUvGA+fAgpEiNom/y0aweEdv2d1fI2cQRRzzLzlYr4EXBn5M/G5TvUjvF+NOKN8FJWcrf3bUWzriTw4Q+5rUufHdYHr5UFgmTNJ
#eHQ3z9sYl6i7ab9AU90g9n6f4/ih7TM6vajpLHoghJq9ysMACoVGK5oDRzLRsUSjTCHDyajY7/P1D9XnrL5oqjDwIhEaIcCWZFog
#HynRythVjsKNn3HlXAwMVfiGrJx4WJidfOhEUUFIra/4KtmpcweLUkAM2tZlXrROOiFQuSCYG1oEQRLFpjCCmNDRSZJkqAacyNjH
#FwMUkURsuDqAVlAjOBjhcKweQWfBGCM1wkhqXzkS4GABGNbYcCuUAUYTIVQgiL3xahnYQzYImc0VV3kE3drZNcSTWg4G0xyjfT8S
#u4q3e0pTBiRBZICskzphLIMcASdRIjQr0pj0nlLUn8F2XDKeaEs7y8rCspsEh++byQFBnuB1gwgikADivx4zBHGg/3pBe8lpw21N
#aLWFq6ngBEksctpa+phl/nzGozl8aOwfgkxx/JiogCBUwoFWJBvXeWGbjgFlOzELeR1OOeaS7480Niaj4FRpD7UbCLReCB5wnzaF
#XMhGHyRLu5qA4AvKEvNkyW2YPrnZrd04ZSA645Lwo508OjySUejoUr/7JMTFrLFHIKoHo6HC0ERPRdf9QRPRt/8gq+PgunGKOxKl
#kDfo1R8jZOBGnP+i2DxFCl8yLFE97z8KII7cV8JxfphXXxSW4EMiKAQJyAGBQCkG3dFPtpBfCuus/J+8VSBaqExejiHEIrdzF5Uv
#1pnTrc3NFvraBdiF3tpQvp1ddZdnaJeXfyiTYsmuyn/QdrsxdoD0HD2tg1DU35NSochVM0Ujcyr2r5wWo13ubw0Ng1FxvsrUCAah
#ZnN/syPfPoN6cgKlc/iGcW0uXO03QyfzAb4E7BFwpx0lJJ7tsAl2HgECYQMjgrHGij/cCFowcR/VSMIbD4mFSBRu4uMVJ4NE47qa
#ykqQPAsADIBFfigy0FF+kiQQpu9lIGUTmash/ie23ttIXwEUnToSByfIkEpjNT4EUviaU/ZzKzApYAESlBv1MJKBDHQ2GKrod+IM
#gPAm+pyTCBu7UXGeteOHB7L/CAc1mAus5QExG8L84TP75SASY8mXTItkxwUci6MAPEVzA1QgGOhE55O2uRStYb23V6Zq5sQoQP+B
#86zbJ1IzQiBrv8g7x0afVpgQqpVbSeTbsSHXp+0ZwYVhsvtTznkLYQT+M4zjRb6ox6fZiGf444dm8K75AxZ0AzrWXxHAx/l+hkUg
#QGoA67vtMiYUDNjoBrFkPUE+lFS+ieb/dEYESsgXdnBXuFh1wcIt4l7yOR9wYdMV4zeL23jbuBuWYWiSzwNoWqhBtOljfpCrrPTk
#R8AS9Oqk3Em0a2Ig4z3XpvqBX8cX+Aeg0Ybr9Zz6uwRQ/fN/sfPXYVFub8MwTImUSJeoNAMM3d0g3V0SQzMDw1DSpXRIi0hId6Og
#gHSDEtJIqIQiAlIKfNeAtX/3vu/neb7vOd5/3o99bK/V61xnn+dax7iecaFYLPEtCQQ6ttpJuDyRgB3u746HFX3V4BAXvo7VPtL+
#KiCWQ2q7H6Qw4ELdM/8w4KxNUNHUa95F8p5VTz7nTffRdF78dNcx2iXvtZrRYdo3dkEd6cK4qeVj07mdQq4rrwapFtP9MHCIwF3G
#OupCn6+S+5EwKZR7R2qXJ7GqpVI/3yUFaavna6dQWTVs9k06wd9YqB+PXMt+7jDF7gVOP3zFaWx28LIu4FvTkr/Tg6zFe47zov6z
#ptxWY8VP6xMTNt7kycbT8jKpas3UNkZdo48zFbY2HO5Gh6Id7a5yJhc5JnbUVMtHELHjHxaflkAG2uvMQ2QKolIIVnzvSNmiY5dg
#klI9Z9ub5402/z7AlxLNoSVLc9qMU02WoBfkcbfHrv0xbnBZQxp2GyqGji93/7EtrbT4K/drJWRXy4nM7r24f7sseqve2F2U5JCj
#VuHegZKSW1zmZi5rPvqIsRoqZclSxkeJsBTqspZ7JzbvCROY8pTWzZbnB8q2nrKViT/6XgBWbbjvwfNGG6X5oQJ67g6d5+tRDSyW
#/bBkeeKSzrv5GJFDtZC8woRb89KmOWZEonoThlgJQ4YkcIxmrliZ9elbDab2X0r0LX+stTRHh04auc3wY4a9UpKsodkk5q+XcMal
#YaxDrSYgSAm8AksTizJ9q8K6nzulQl5oxpTvvtzeYBLOa52d2DYTRYmp1ptON23NYLHKagbeqou6fZQhYVtYs1RzHBYxaw3vE2+J
#2rPKe8JNVIitf4ibQUzeX7IcHmgtVs/Zqdw98YKw5upHejNLpdct8AcrQ+Gx6orY+tkuUfydRYxtOfaEseOamo7jk9cI8EcZqpns
#6JOnBV+ME+CyG/EZ2X3miFJ4m/fmoa592XCqKHSVULFeb6Rw2pWI3FjAp3/gm/4r/x/jnz7HpO6/fvtieene+peYt6LCbRWZi0pg
#J/cTAyI3MD77VdyG4OQ23CxlQjVqsxfVn/Qzq/dshw1ybDD1C4iKlNtR3Mk0LeTwRtS5dU5cb75nNXzDxm7QzM1zYMjv0xVX0h6n
#OV294ABfJZ6R6fNbUcs51B7Ue0y/EhVdFiOE4kQYYo1Ie2F/hMN7M74QXiNAnqtb/TpMZ7KXL5d/4uWbd46C43MB/p1DuFkeRZrW
#vTeS2fZvxIQXhmbID9uxDs/n07cZetpFjojxG8XqD76hkmxKbuKvPghbMb8tFBQS/GVgN5q000SmPAOqZvXGZXHjpt3X7w/QRI3W
#8XTOCoMreirovZRfUzyb1DVw6g+D15JXKkVWx5C2oaw55VLwTX6/k/7odJ8ngGrsR9P8md5o1rhNc7UvXOJl1DCZwUHXBoljdhqu
#3qyL6VXBlpL7Ew7T+XMjQ5VpnM/dWeIai0+5PcBPE6K/vr5bihIZs+y5hjcUniNVmM9pyLppdq+wz5oKDwvvsZ4qn7rihMwkJa6V
#wL3G1xnGVARq+h6q1Gbf9MjwSq/nE+KaxxY9SYn4XD//AR8WvIdzjpW0zz5fWcoO26tR6t300cUIN7JbMS7lKFELqBjZmbd+avfZ
#uxed3aD6pDzVPDSE6xxxLZWFrdINPEoYd533vaFKiCTvJ0x8xEz55Mxn71kTMoUpuKqh/ezIFX9O8qOWzDn8UDTGrQNVNIslLS6K
#jnQZ3BNzc3vQ9E1pw77kO1qdDNHPk4WyjCoeTXzu0g8Q2ZmxkshP2StiJVCeuUbvgsgUrSaWl6Uf4ExgL2QHuWzVfpggMGvfFBRv
#5qdW1u3lRaxkejx9WffJciR5Umym+vHRCIlf8SLGa2zHeOL8DV7x6jfM+wOkpqlsGbyR0FL+79oOSqxXAzZI7ocZmd+jPeP5eMxU
#z1YDIwT7vqjN6/oyGzHr9DyKjVqRcszis6L42DiOu0Elb9ATDNHQUrHFDHPIt6EgnqpJyiM4kTnjIHoc+PudnplxwwdPnLHci/pE
#LScrgsIL2uVFc0lQn8RpfjJ7lVaJZl78MdyYJkjEweBFB+lXir6tjkE8/xKsqvrOkQH1637dwQqvjBf8a8XCdDvwO8ttiwgaNv1+
#WNvBWTl35t+TxrmFeBV3iTXdW39mU8DvTv/JKTJ4FOGLh8HhanUvZ0xZ84sVhMukj2GN9LVSOGaVV3bk12KdHOnzVDHYQ8Kymma6
#3WNln9PwQdtWz9k6f7pPLEcdeS/0Es7ilvY7Tt47w3AYnTxGTUanWF0fiDvJDnz74V3qFaXPPxzlKdJ5t5gJ/SRGLS9zWTdsasLD
#OnIM33AyJt6jOfiB6Umh5J1goamwhkN0K1GnRWZ+JdSIjMnkg88+uFMPlF7OWTUGTs5UmZeCNQSVLWfe4OvpVZURe7sqG778Nrnp
#rTp3zDFP0Sysu562+ghdTm+PWU/j3U7LUcYnyqnhSek6RDvzieELcIC2ZpGwh+TGWqOUntYC0cJiazg+eHLm4UOnb9w1dvJ5LSsB
#2crOGySv3F54P/bG/8G4pMwgVmMYdtUBajU5raZGwDFrkXgVV2ODd/qo/a3QuB1drjqkgrWmzmqQoWA3uOBR6qCdsPgC+NvBS39n
#MVaBrpoXldSZhdQs88SdHp1JsBqdp6fsKX4ZNbTWynSnmXE/tI09GTWp7nTz2w/Ie+19kdVrG5qtt5mx62nPMn3syr/9biVItt7R
#h4ur4otuvvWN86YOawhPxcI1Ngkv6kfDWYO3xaNTfGlmCLM5T8dvaWy9LFs/LavYrHRDBDqftBoiXpQ9XKLYoT/RSTuZOkU/sTZY
#6OeJhM1Stre+VQeV7yuR9H0uxTGxDSXHFSw7o6cix27tnWo2TB31jw+mOzGMA9vVtm77ThURzKy46q0femRPaZaOfdHIkdnX190o
#ebWFWy07PeDevdT7oN+Nn+OwdpEx8/vV0Nyg+nr2TBaim/dWV7uxM3ND2sh2TGgTJTdbQkf0I24p1vBOYy6uXlmka+XB2KYclFJk
#ELkdPtahDQENBXF9fWRaVWrVOf7sqrbgRqg3tSFcAHrfrHPItdH0CYpIKXtvhaa3y3GOdlBBqah/5HQdw3Ty+j5Fs6+ei3h0V0W0
#y07uJ6PNsSeSMmNjvItOZ2N2X6jwXl2du+7reTs31/lToZaD0F26Vxr2TzBYe3sZktdDfOMYmD+2uaqdE2eO5OAQypigFogJSHx4
#o+sAnjMXH+l6taMu9GlsjITw/XsQGx2dFUvR0fS5jc2LMpKs1fdiOMES61QvwOZZYLKwiF3SRrdPvGi0CqO9u27XvlBVCbGVxV9d
#LBj5oU0czGWwHPvNqq552iSxpS0P2/kg5xuceScPHFCC4V3mG8drfS9qbliJOu5ETk3Z0U7Xnv4L1fWzuP34JVai53KWr76/miyP
#M5U8XNOtGp7D+SjGm7GV5ggzgiOYG9Ez29tbJrRo6olwOHeNOK9L1GzHgDhqvi8xTttMMFAMiNQ51aoc/XDXcyndSXyUy3FlunJH
#njR5nrox5AOXVW3KsHamHpydKarCvXz5o0HKQxzaJhJ16pHWzU0O+WBszjYUnaBAMicOW/XobBZzFpp74ffHY4s8VWpo5LXku7Hv
#YhtQo+C8aKqCidet7uxi2/R+mNuwYAvycPY2QaVliy1h2TJ+Or38iplVTlk+WElEtOTlOsTeM85d3cvYcTP4kVuzYxGD2ruWD6XV
#36fNPwcJFjVfvzLRVrqCm/pc4xpZaeNAnPjGq4A6Sde2a6F6Xh2WiK6WfUnSQYnyV0WGLCLkAWQyH2RyxmSuTUyT3ib3Ylza2r1x
#84ooTma3gKsOVZL1psFqc8dRN5MAwV7NiHBPqG5ELWmGVsbxSyZfNVs1kZ28ZyVzXW86iB6hVec1ZAm84F50XPbyOdY7vtLVITfI
#cUt2OgGGVq4b3E4jUK4xnGfrioODT05aEmi++kydGVUxge0jE4Or9p5hKWFKEdqAskudE7xXpBezO5RNwWNl/J3FVAWIT/3rvTHS
#KipenjfXO8qgDgKE5gtp+rOvEPKUFHJDOKUaWWKdIcmf2dSETa0Im7A3SzGh0i2j56LfbL2MLJa3db6MnF6b2HgtxzFj+eb27UBv
#7x7DbBPnq6kFulSlzCL0RzccmR5hash/7Fb3j5pZ+UQnYWG2kIsTi1LJ42vcPcOymMEy8cL2ZtBNK8Vev2W+3ts8KUIF+cVTFeNs
#B6XbuoXhJnc+6g+jen6Ca7+pwGo1gLWGztOOK26jn73p1d7ICdmq0J0sF3l6+9Zj1y0Nx+PaYuXY0L0cLiayHhoy8mg5AbrXd90i
#KjV3Mbm0+G9d06leHlebGdbgVJXiMxfPnOWcsU7b8N8Jexw3AT3vD+WlrI1Rf1zfwbDowYXhlYgR/yCpmnwq5WUC9mwDK1uaPJ3X
#DvnpdtF4Zn9vaLXSp52PkpFybRFyQwbazryN7By5GKErXFl+M9GegwnmO2Rmb6o1ohqzbZw4aoiPLTGI9zWvCY22d03zc2IRQpaf
#TAt5omQTR55RYBTufE979b4xrHs2SM1yjjsByrqTzCe3e72hI5e5d939qzvHcL/ptoFp5boq81c/N9TpnvuCJktK2e43q4bLTzt8
#4kTtFqihr0apLJ4Suj7c7hivvxoSfb5/+lnnA/FMqZcr8aO50muGznJ7pc8nhD/MN3HWHe9xoLOwXFNSqttZkFipiPrUsaolHtRN
#/mOiT0XVLz2hr+yomeZ5Nh69u7p7BnVCU+CIR1z21cVSc9KR2NxE/luSRAJE12X2vn5zYIjTxYCqYmJK4sW7YLlEeHDTRrfz+9yr
#S5Cxrj5NfvaQjrVu/obIyK23UAoLysBIyHxpiegT7nlcEY959K03GCzRN6gkGuvrn0jUqOe26AjpCROXj6t3XYtJyWsJaZnFanRS
#PBFR2PvkffAwen981VbungH+Q/FR/GMBtEN/W5fYhy6NvaRdTj/AFtrZps7uutIvMLWiTk10RPjHcjueo08szB0nGjU/mJttvCNU
#6k2qWHsFD8JZn6d6TPPmNL0L0q1we2DQS4knNm2VqD7wcVpPxkOzj8noAcLQDIHjqwx+1NciCp3qGaMGcSIPKD/77FjexSBVxvHv
#l135anKgdBC8XbVikTtYBdPwsrEW4qlDTR+xOxP1d/dFFX5S9UAoNhVldT38GNazMX7zdVe8yVolTmTaOyJli5maqmwdM4Ms+Iun
#LDq9H6n3Zl2q4A8ldM1kl+LdHyYlZPkWWyrAX/Pxqe65AqF/sdYuZvDgC3M9xuJUXYOoEbHaRTs2rDKh3Q73eGZ0dcXBALHNKzJj
#n9Di67Z77vqTzVD6RQcORvNocC4QRdJkZt/Ea6Fq02e8wVDmxVDpNUr8McvJ4bis8H7RjpVKTSvjV+07zo8o8Xo9SOK943KcxFsD
#GAxnv8rBbz0Mver4gk0/ZPFlv3+Uf5JVGzdXRyD5Ob5pRWWlx1Y967Nly+w2MdW4I1kDjc31QoqXIZgU0S+DX7/mUYbOTDoIctaY
#oPSEdH0QPUQ48s1i37vanfQyalFp84Y+3vcjLIlp2Tw3f0PmtvLHS1r2Ofj4T4hBj3e72ghIcyoczz4rjHJYwLNh17kUtt2fExPu
#FH903NEnvYWgeypMb6hBbpSQ9TDVBi88sfPNiw+E4XZ8jz6eZVa0g2yn1Ea8UM5u5SgoTn34mA0G2fMdDL3de/Sl92vKTdHKw4Nt
#wh/eq/c7K0wKDKrOtMwWMk7wrIf1R47L2ltW3hDbFMrkW+g/ycnhvM45mACjn6OnZywvwSE0UYzaL5e60h7l8+H+tTTh81scb93b
#tx7k7iSGXY+OjnrSyWa8ASomP+JfGBld6kpTuT61AqmUJmBo+wq/NnCFcNffGDVm492GwwzfcI1KSzMZneCDmo7eHifHEWkPD/tw
#dnOBG2Ku36N2Sjdx2+0DZsd2YlDeQ+F5T+NDb4cfas9524PMhYm6PN1dr1kPOuqV6UpIjGUZmRJpa+96LfTOzyYTMnjIpTI/oau2
#iXGltFTGw3N3g8N5UZrfjPeK3x6klS0w/W6y4LHSu6TJTaCWlDKl/Gy1bMDzvZfy9Ek3z83PCO1qGkf/dyfFLD2h2J7b5lYJzwwo
#boVuaQrt9HzoGoVIZWh+1Vx6y9a4DbNmTLDWvMF302TI1iD0ywpDX9b7bTGSeXze89lWFKs2kvy2RiH9ox/T79YrNkg3CBCatvmx
#A0bdBLX09Ck1yWkE77RxjycbjZYC0Oa+zKR/qT6LOcDjmh0TieGv3/+2ovm12YU/Y+vd03YiubsySSBo79rgrvzxwx+MRq969hw7
#UjkFOe9PLMs5ewTE3krgHCTvJyr83puEP+w5hv6RsGjWD9n2XsXmyvc+/t33H7oT0ExtH/S9awDF8IN7UcAWqZzaE/c6ZzmPD3De
#dfnwW/alvY+2wS4aLQseRJb6Bxr21FO/8+oGUR3KeSbeaqg0bAVbJHMmkoKfGBAzH9f6JfJ4Bc3eYwtD5Wxmvif1RKA2w5nWpF/g
#xcIrPFM060IYOkE2/ZeN3gi7DD6JylZGz6ErdPo1Un3e7AHLJrwsyfPC6AVROEcbufu2kagoNUJUKHYr24kMK8zEJ4Kke/MK/J74
#KCrEbxGt76UC9Ll9i9jjtLgdR8TvFhzl6ufIb9Pm4IvRD6fLE2OX/Gg6vGLYcnevKjfykEXk9pMGEknNQIb292ZfUbacUKc9cO5i
#eOh5oc2YVgUrtqYky+Xc5KPJfHotIRrVCP/rIteBw/G2tYUnewtuuy/PXLnu57ZqZbQxDyq6zC3+nXqmfsY1Ir9ITKzp7hixxkwZ
#WOKgh3o7Q0hr/v1IgfEgUybmo4pKChXaxa0ec/Yl//XBkdbvRevsJMtiqy4y/Yu6pEZSZDlX9LxNFxgbAyq54c8/YGx/xn8UjPaA
#SsX8G4U+QyHh6zEmOWn/vleL1Irv2cykRHH7jtfIa2/4PDZVbGVeWi471Ywfuy3mxNQtdNjz9aTXronze28ZWcbXBx9M7y2pKrR+
#VHj5XEcQTT0QBRXtidBjMxMp7NPxKTowih/CZ1nw04bk6MTxl6dzXXu+ODK4OAQ7zdyrmfdHvcjRVmjvujAmVrDvcRzqmF13CP1M
#p3mdQGsOe2d67cOPKOh7E70ww0+aJs/GbrJy0yzeWK/xzZ3WdOJNFwwjsKjL1v1InsdE42ZRdyS1lP4QFb06dL75im23NIuH3v5d
#8fVGqnJH3HxHjBedToHUrNTXDdFIU5TsfTowkmMHPhLNpZiDfLZ1ZazlUB5ZdfneFH98YPdp28ANfVaYR26N+uDNLlZF8nPuRPnU
#mZ7MD7nv8l8NJZympApNeNLVkiu7YaPE/7g+waw5iKVdMdj5boCtvLQDtm8VR91Ja9HlpHKtobY69j1BPNVgvaLe9+w2joRSUlsl
#yx5Cx0bLFOKx2tvK+MsJZLKlq50wzUjDBlrTWfNv13qs2BS9wlZXckb3aWKYHe4+qrvC0dr80l0Va6Ek3bDk+Gt5cALzVJa4B6rj
#eBYcRBigTJWjZZ0hPGCTJMEXaTy9q3/M9s5gRPgLLfOHoSHsgI84wZteSgS6jqd1YZg9Dzun97JYQY8HNUsDcKEY8wtJ365wZgRm
#YBrmWCYHvQiXsCBueI93ZKxr8a2zHMoFVuQe6gy7a8EqF1g3+kz+Bp3CN4JOHM4xYhK1XD/EtQp5nOQo7xfcMLa92+OG1awPcmxE
#mcx5sK4ztI7VYrtjVeuTsC/fufXEPBRNBwMrQfpq+x43nh0d+KW1faa9LdGRqGAS1rhkEoP2iSqPiIXtkWt7pM0rTrKhQXY9mTwx
#u1q1XQZIyoHlRALBbgdpKL1yBh0dkbx28kMWrR7ZfKqUI29lpTWQgf7TvQ8Ow9YCGC9ZFHPuVBQ4JYtrekhmRYvk4p6465mrFA3v
#J25uV4CcI9dl6nHqVoseycca1dzftgsfQDxMn6qWst3w+6r8mpG2PLlYK1e3/1r8Og1n3c20xTAXFxUH/WKxtyV6Q0lZVHovko9r
#dTpMHARWCqfQZ548NKvUvP5gVqNz37PiCosUoVDz+/tWvSnpY4ORvBL37UyTA3piD+JKr3oJbsW1bH9918+GcUNMHLXw+y2Ce/mj
#2El+4Je2kzdpxqyXxD7DLB6Y3HJ8bfzp7fTZLptuWa1FPQW/lTi5oqqMY6g3NpGbn2JhnGlFPgEtpSDDnRr1l7rXHvE5IaSiOQte
#30kLLpq7l2HcsDXGpNJI/dz8Gc1o/eDB9CBJyszWgwaDpbN4XMrXMvWEN+XIX8vuE6J3EeTSKHDHYTvCrKhYYS+jjYasCVVitKbz
#jtFeS6dzG7hYBQ3JCYmf7JLidFqRsKmLML7hf6sm/DmmLo7Kq9/gDsI6tkPe2Khb4bTm1Vht2khunZ1dEd0DubE4F3uhsWCd2fJe
#MrMa3Cw03JrrZA+EelhGLLsYK90GN5/VTRIvzTEN2J31UUuChUM7aeFH/DwVs5u7/FjKkPwHDp9jgjCUtMNW7zXxCzygYZC9M91V
#YI56WsI/WZD9Ih08fo6QZX/MOEmc/NbtVMMDz4V/suS7W8dakSfqcH/YW9aHiH6nbhGUbB37REneN3SBLnlTMxNi7XVmhtmJJ9eT
#SdJ09Mp1dOFXQgiWMFsSy2p3lc/UtLZrH1G9NuBAK1LJtqD/Xi4f8f/cg7j/l/39y/tPK0u4M8yL3R3i4sBuDYPaQKDuEJufD0H5
#/r95CPo/v//k5+Xn4fuP95+83Pzc///3n/9P/P15/2mgi0KI/PbNo6Dof/lv338Gi9yoNqSO9EQ+ACXDCqbBfkxKiIUTkoQR/EkG
#N4zh8iFohBzyIajI1UgUvGD9G8q1jM4G16FXpQ53D29mqAp64Ty+uvxlULonZENAY82ToGilj/rHOYuSNfUCR1tFaVBR0BCDiZ7l
#g2rsE5RlU/EYlzjXCc288MVcH15eUXVG89wwrqqn+hRX991MvSqH+5Kv8Ety8pzgobLcF2es1hR6ZJIkS6y/m45rW7sTdwtMTxTJ
#AK50NRdcPB+iEH95dGNxNZa87ROqfsC0DbMFHA333ldHGlHJcFpW/W29U59H44dnp9HYhDTXlqlCDLGspKl0yYqxWUnHM3QnQFvF
#dVEsLorMCu+9z7JPnzSO+gf2ECaFMX/reRSWrkiWaLMYEbY2ZevRlTdA+QSxl9SStrZdo4rGYGlrQUaZ1sAZzRBGQJPARZrAmKOn
#2WwmpPi9zane8LueacUStHfT2HO64fNsFGHTAm5UaTSh2M7z49Pn3DTSFYz2Ia0yIcloL+23NGKGhsgTv8k4N5yWLUiajnvWFXYM
#DfSLABboFpr3cqeAWjGFXpcOg8KmK+IzH3HgD3P809HP3gFkMrNSoa8mOEidJvkoPnkLnvpuvZzEkiulm5ut/Bz14yUdjlJm1CmI
#4PvbVLgWY3k7SNIPJih1/9pGH9aJdH9Ta56nVlmZAs93i4ahRd/z86Hy8tRhNL68nmqadwU4LHy4cE69CU0N9tC82KbOJxH4hy8f
#XxtdNf1g1ryGcnw9YZYQS9yJad6BX/Cm5BynHT6W4Mwn8sBszat8vZodR1N9IjPLh3Y4ejH6IXmYOckmZgEUfcRU+272cNQfJtBO
#ZUxTwfxdm80Ff9cJTHqKa1QuJwfNCyODVeHNmIQz69UJQZSkh5JFX5p+jMfeTORhzMVEUdhn+mIe+xgzOWiU2e+K+puB5aVMx5TW
#JbU7QUMc3Kl1qdQqn4U3nJW17MqjOTxjzwPqWs6/3N9gYsyRViaRcpTqCw7LD44QJqWi8UC54+Im9mDr5qhPBMFH+ynXOw43327F
#NGV4KXlK12+EbxSS5/djvIZcPV+qSvE8e3xqlbbkSWCjy9qBUjqR5jKxmau5tKFpJw97MJmHE/IoFh2BH1HeuUs4cP/jcRus6nMD
#GnY57pFppkYdvhRMflyKkomiMe9o/MEZROf79vVCNGYCqhKDt5pdgq0lmk9IzrIiT/yl4Q6W0li0YdjmtgPT72vjLdUMfbf7GfoX
#oOe2qzca52RDMLDpiORkCGBnXpTsN6vepErv0AQ/1gVP1cd40jlUD+RtfANbvPCMcWhgSnf5HGMVi2kDQo+R2f32GQ3jHTqKFOZX
#GmkUAowjmuD4hQVNojvqV5+v0NRJgeRISOgxa1WC30CkZnZzZdBzX5Xm3LummUQ4Bnqaw90jS6wqO+921W1UfD34wZh1fK56FsF1
#MS5phvYweUIugiC5GK2+DLuPZKEbqQ8JY3OkUFFGrWkwb1hQBeVgCFqIlhPmUZ++9gyZtHg7tvLUE8OJLKPGDYVh+lv157Lr6sYy
#0lwod/bBD5/PoNrI5U1jVA/5M0FNcxrG0b65v2lyOW8T94JuVjskpilddc4ruh93W4Q2SisKrkuIcqDbfuv69CqKL8bd61c/BSeg
#LInKBskQ2JTkJCauV1FoTTfiS0s1yVAQasaK698clH+jNCf4JlwiXCKAsbdCkX6LNnsmFCrbZE/OhYX52uMm21j3urhNK7+i8qN1
#aVFWesr6WxXcRI1+tkK7YdiTIrKEzF32M2VPKbLuy6C87KsAxf4I/pHM7kWNR7dEl01/m+4LTRU9J6s3pU+cmGVWqlu5yC4WHGWG
#cVVywFlmimZw52n8IR3uhuz2boaWDcaGQfHjdZlZGjV9M5subfHiMcp9GoHQMPuIeUWiXN0VmvBr9NmEeMIojj+wZDh3ZM+CX9SJ
#5B0UPc/OjLeq/AAf+WAT90HzwGZOV/bWI/pndwTKHetYVXZv/sC9HaU4Gjo7/j5kts7hc0vCdd6kq8kJW12cTM8zh/ise2bcrBbA
#M1mYN6PLMXdSlxB+CrtTHmG2i5Rf1t9gFDcuBW+WRpGEZtI/vbdIvTwbfJYQwFKyKpAgODPHodt0FicTq664/ziXfNlMdGxQqfAu
#E+O5A+U5anuMssgeGKoQMe9ri3KgEX0GNTSQdi4pH6klI7nHI8vzIG1NRoLkWeH7z3t1fvdOiHlDWvvdGZKaihWEyQRACsHv5wkj
#7VT2vV++UHN8kD1R0NXd/NA4jYFvSfJpgCxcL0tCoEEr1jMbR6YkygwdS8uyXYbglRyxCt3z/XxBdBPMjF48XzxHg/PlctMN6k90
#hsfcvG9kA78Zx891OOrf7Xf3w0Ip9gCfwqhNazxcycp9k+4uW2eFLWXidctqJVzDCQKjqFa7tOvOjRccEzYMLWv5DJGGpR4Hg9Bk
#whZ++H0unaFLwcl1mXDGm1rSRzsKpNnHeHUn7XpK8f3ZBuIlOppIGVRh/udhiLsrCzq7HKxy0Zmtp3xvA+RqPk22pXar8N266d0S
#vZerbswiMNwkuHf0JYtwcB790MhCE4MHOhfQwhS/fYi++1J4xX11UDSpp2JP6eBrYxFdWJj5Vcy4e4b2uS2Z9SbSVvg/ztPu4P3I
#qHMcZDQw9Rh0maD/oamtzcNDBcdhVVamcrxHVWlakp7e573L0LN8J93ndfXOUyKaBOUEGip9fVYBAcdcmVx7bqwWoRiMkrU374lB
#mlLFmrRTNKEsKcVMmk9TtbNEyu99S6bi07SfuPNUiTjXlj4ihg+Hf9aeo4fiARVMrKK/kOCRI6t+iyeaWfMYAQONIha1G8brwth2
#xjSuymchzZusU+xNtDzhoLvbGfw28yhYH596DrV4koV1HN9SRHdMPrECZTlPO8x95cZ5XxQnt/2dWg2hYYu94Kp2LBa6/SXtwWaV
#s3JAs3UGmgrbZyw5M1y1FtFO8CvzmmSnhyviP4z9lzEHGug/+axrgNRAsawe7XnJM5ozBJkbXFjldAtRGtw86Pr2MgdaJbiYoRil
#DmGq5YEpTbaSGMdKCcVXHzD0a+erhV+FsGiu86qfftt5R1QwkFymWaJMWppJ5Ej1nTyee0pIp2ELB7WjXAAbcZ/L4A6xtghDBDxj
#tD358YfSqo1vggWob4o1iU6VCsX6+d9q3oigkIsCpRnR5DdmJJWc4o85oLq/Zkohc48cHBub2zUmjA1Rd3umnkeiyhaHzUtDRBGZ
#SZAIZUOXJ2V9lK7PUENgiE0lw5rrlI5BBOog2pNlY8OZTtOnL/ZBS5A2OH/+ba2GyaPU3i6DJPCgVbE/FhzTKs+9n8QAmyyecKXg
#6tV7xCdXH7CGdc4S98Z6yWklsCRPOSLbp4A36SwnhM4Wi0Vdpsv4vkBeVFkJl7YCqwDXw6LxlhhvF6W+9Ak9aEX1hOM1wxqlVCxp
#fV+tero7mUG7dF13rpFWNBjbdGDbmO5ad0t5u+iWdJjvPc8mzdzQ2/WTXdSocph662+NG/It4XXu/Mxns+zvkpLpMcdvlx5qPPMm
#AlnFtL55ozmyrynQvK3rOlusle3nI8pHdw3lyi4MnHNGqfnYPjHnqakVQhd6TaP0zQ0le6ZtECd9bekxvV619rZi1tSkzg0X/a9s
#c2WctsY72jbfNHuvZH8eYXm1X+/DlZPz8kqfpZaY3z6dvNX0C0IKt/4xYpU0Sle18FBzxLHKD6JPHgGSB5g4jWnctywJa+7cuiId
#jLsLAq25X6kKNYNDWBeTGx/mfsT0lCrpz+21xQzXn7FvgNZAhZs1LDOGah3ZhuUNLEbTq9ufgqtlysR4vR9Pvn9LoMTNrknHtHxr
#vPTuWLh4WLFu90sSyVzrjBWc6MgohY4NrevigjulXMFvVXu3yDpukPVkPlCsHsbT6ZvvsHuVJ/RaxsLoLq0tbcShefDTxbCpl/c2
#JHrvvSxb6nhQ6dame/Yia6zoGrEk10kP+teBczfjnD30szDvM9IOdBwqXdWw9ceBGlo5crFkLiJCz/YpuGy6blQa1poLcgR2aRzx
#t7XRHvXcZUstoTKgzccndCBqLIda1yQ82+RAZdh8RasEp4dc1UbNf2tzJ6PWZjCRTSMApzOFKFubRadSpoB1sqRs6tpwYeni0nqQ
#wueTXgIUKYMtTfb82UemH7ZZb/IVzEjVVxhiYUVGKN2JLm9L1NHUds/NLXj68Z7T5u3KREpz8IvjnfdpKBg4Vv6333ToM+amdOVe
#ilrq/pO+BBZklmR3rY3T/mn1d8xv3e8SiZJZdSrpUoq1s6i0VTabNyUFk53ArycU3NlkuYdc6Qf6zm7oxUOdYkYNY8p636Y7Z8h4
#OB5+/vzQHxKYiO7wdGGR2EwybOempjM3/ywHGCNMroshf3KM6fUV7slpqgP9lYFFhe8C7BTLoYoUgibGLj8AAZWnxyG0fSlCJh+h
#6eWfm27lihskR/9YLvbs5pFkJu1KZBFWj7NlDLPJ6xIfWv2nA322hGCuWB1y9Uyn4Ih72vCkZ6QvMa8+ZsQlYl86EdnAkdu7YSeR
#hHVD+iq9IgVL4klah9A5p3Hgxs6YC3mD6HaCeOPM3RTG1r1wnx57XReCfP5xcN0w91uxPfbqMbroisYezBsutTrRAhqEdZng4lAy
#FBqOp5V5xbdVwC71MbPK2vZ2X3KyUGQJ1tJT75gObWrY3L7TzTLb7IEjespMzmkyVoRGqznkINNTPpOQEPUWV2dpGDXwrNIES70F
#FLu3QKnUba8z4rpd/PIuIkLnBSQ78Vl3xl5JQNDHSCwWgBTshvlh+Rjjy87E0TSEK9KfZFvqxL2xSTjw1Qtt6mOGngnG3DTvTniz
#XigamGu1pE7LYEoxoTXd1V6ERcvN79UqI/e0/fwmakTxs6+WpIxfN2vv2zpHY47xx6pdm4YvnyPmpJ45SS1o6+iFmJAJpkyuiujv
#EC9V29MMP3ex6eR63PgNv1VJCHXgsLxASwVFCm6DZUnLRUMSrBOR8eLhCtHzTlTTXQ4vzvqrZBz9eTG+eob3bXZCfR4dt8+PY/OG
#b9j6BfbFB9ROE6mw183jsFWwegtBEnPk+omdKurMR5tcGt/n7mzjRWUHUUXYh2M02fK+XJMut9Inw2SlaAm1V5znO+H5pshCLE4a
#GRmBykTzuPAuCcVdONjuSSZDUhg8MCJRKEMwrfVUlKieYP925o2z+esos6/iTxLu0pD34aCgFhOuK5ahdFMaIGomG4Uev6hTfZNh
#bDF309jYqqfLmpdd+YoDN2l/wjIeWgbOBJXarXZrsGqW2t2SxF3vfNA6mO0qPV3fvNzp9zdV+OG72/3v9+XdWS1ygsTE/FHWutrs
#XqgayqCgtBx88MD9kUBikT5PHoe2xzE0eIAizg6+evsqytFhPcq7WZJ30NdWdxNG+AglXwbkxaKsyXQ9ClOUlR/nYf54MG+WkBuT
#/vWe8Uh7hhDvx85wd0+OlJYHvsJO6WZDIq0oqWbCAp5slV4jy/h3yRQQ0ffdV2OyzSnI2XbuG2w+jxU8HwoQYdOQfMX8wwFFIuB7
#tzTKu+XorS2PzeXayZ1qn+n99pbA92c+Uigo3ChRC1eOVAOIML5yW2D7MSxNg1cTTAK+tosGPvv8jDjunmO2p2/DQnoMwntDT+0s
#jmN24Jbu+A1o9bNIZnUvWzLppX5Ny6arNyIh5F/qrUeOho/7aJe1lmIzamNbJ6ne0fNfP5KrI39qcfoju1f93pfkpm2RT08Ut30/
#hbbRhbapeQ3faDthxjkadZpzjqcQOS3hJ5p2vL/lOQeJp5czRCOSsdLGEeHgqxejQFjnr3THC95G9RP/yKn8DCtxBcMpmUHrOgv1
#w4KBBE7FSjF/kq2SNLCsLkivUPk5OWss1wRXZ6ye02OpSYnjCEUyU7fJK2mmnlp3m28eUN/+8hHND48oSYvmq2g6g9RIRWeJAU1+
#gSr7TRiqNkSlnqRc/8l5UZGuI2W6rMmcizfRjsTqyneccnPplWrlVxtpdnIpAYeWMRN7cV1dToTh6+4Mij3GHeLS+QZBSiFlETSH
#ApV3aPSd5THtNTLmK7DfFigQhAwyvPWYmWNjqPVCG+CLRFirNEuydK0mvps+/R6sFscR9WNtHXX/UyyRAd/jWFCJ1fR3a/Z7BxiY
#IlE1E5HMjLj39NyHMdm99xMnjvV+CHGcamWHRDaVED4VbROPFSiJt1oOsBGKGqbor0n3lSd7YK0iqVugrFrrlnmFevgVhcOi73UG
#BVehq8tEkSRXtL7mNNeiReaqKoQ9ZS6Pu9/gEfrQodyBtEqXD03ghdWGbEOscr0xOwbi2kS0UEUfmn/Co+lS6VxnH6qJODplCieD
#cRjpFQ8DLGcBXEnqevvFwv7QAJHMTyaBclMNR6m4RIdNoS6Nx9dK6j53pkaKbspXhMQlMUNnnxYiSqJkNMFZaLeapetfGIqiSrfc
#2eVmCmhdIWkuYsPUjNfvW4960+u8/llkUVcot+k0mAG0gqG09LIRHUP7i1QGDwy7fuX6w0d3m/u3skzLm6/pWZGo+ChQp0QncUvX
#kTuKwAW5jd9gsG5LSfOabOreov9iM2hCr29hwqFJRzwa9v5rJ6mekEdQWTKpYq66qahHSTJ1eCksRx+vfOThs7z9jBeLJalBfHIb
#zzxD0r6ETIpnbxhoZGufsTOT8hsuHJS1nMdS+g48GjG26UMcepDzxx1tFzc+MkmlSEshz2OlIcOwGYr+KKKgpAh9VNRxW/+5/pSv
#TWEwKrbSC0iyMuUtZeznkDuZWClltjnl+xEy66Q2rRwVnXI9vDN7iNf4/qy69+FqAnk5uR6pWF2HKk1vGAqYoarP7gvIvT0LlplK
#aKAdPG48kWPbTKRdev2OlfaZEsY8IyYeUTiUCFdBCeXWQwLVh1hijF9fSWHR4mrvNDZ/vML/1ecEpOiRMKXvP6jx9l2FBHvbEh01
#U3p1hnU/s+CoaFERj0dROos5CW535ors14IjrR8sqMk59aT2FHi0T9EXFsdSWtcPDHsFm/DdJu4nQDUW+FvlZVDxpGHKK4/L94mv
#wscxsKyLdPUxmOinY3KhtsJLh7AGQ0LzIiWpccL2IjRMOm7awvSuJ0n23A6bpLmumHJyqzCeNHohi92mOyRjdw0VHtN8i9fstp/w
#ehTFzaRlRVOvTxGtWryD922baH+/H1zkw8teS3jWB+4Mn02h+PBj+K3QLL5McGU2BT/7Zm9dzMm1gjfC6vrX+FgwmyO35D8LKgeP
#WxcgjhPkC8fcdop0h1mf1o44yy+88dWlu2OeqkVpesiacDzYudvbWkSliV2RkDI9pSlIdu1r9X5Kg5qcNGtvovRj3iK2xFde6fSJ
#9oeU1at0eNg7Usoh/Fqpk55KWTYM1lzKZsYqVpsn2L1NXUFzvSJ0HMPzQ1MYD4jSJVCoHnvyPsZ6VW7YSWrXVFf1OoJ/NgM9W57f
#Gs16Cnz+yNJG3+blLH+lYlvz1bzqsZ7O209qnx9q3vRof+fBS/q8vuyIve7prdipmZ7n6vZf8jVarBsL1Q+4LQcNRK7Uz7U/L7n7
#WG1e7bmnpE5MPwgnv5Ad2wGfxNtR5GaE4gCHPvq9txAPioah7n4NxdSjGOKPPvVLbPedCwtef/tUcCODN1XQX/+rTI+0vccja5tH
#Awt2kCqygskQm4zjDRh5+sbJtaXb7wNsanmF+9oXKJ4qjcZS1Wj0+TKA9q/wY/ZvvXTwlMA0ycD5pkCag6J2aKdlXz5KxfC4h3Uz
#yJbkRpldqBzn6tKi0BU6yxOhMli0nKTdty/B6agjVNN03H3HPEICxDd4XHTf0Gg5ltfi26s/r2GlYmCNrdI7ovD9Vq+nFi1Xsdeg
#rhpyz46//g6fSGBmQq7sWoPRSeFqRC6D2X29wMUEPyoJN8ViBYaTPrnY2ZytrNevIaqIKuvuH3fnT8aO5NTuTHRdu3edST6+/7W1
#8n56M46aysR+1x4e6PtQjERd3uindV470keZxT6R2cdHaWdTp9khjrm3vnRF8+tPeoBOmNIBtvBz+oJ7v1qMEaX9JgqKcLVo7egq
#KspeP8q+gNTZleBsNHqKpFbCwAgC6RzlsMgTb7rkHedOe/IUXkIWnSMFzA1lVfhGhdZqXqvpFQmFnoEn9zCPyu+PPeBON42yXPE7
#2hB4dlXOlobOIXaiG1fhLp6xJft1B53OqY7kgz4b36hEeWG1lZeIYYeUsq+PWqP6l635M4j6vc4Y9ge9tUSeV8wUFVKB3EvAu92P
#dJV9BRFXI1fjFiPdoC499w6axl7nL1M7UmeR2UZbm7eLveW7S5o351HQkrVWeSdFBsN6goTpRkUF4zQeP/bJ3ErJ0H32TPFD2EFz
#GrRuYaV+nvyjS/tmMvW1vu6yUxHR/nvR4VulXUfhz4KiX2Y/HB2e6xUKT3/e6vRBvch6lfJsJnxlv1dp0+WGRp9HSagmHx+pXoCP
#oNZaRM4gyqw8A166FCgJS6gs5gmhK0E2aqcRNXvC07Xgmtqxszb9kpsdhNSmiNt7IYzJfRSalDpRWeoMz7geWPM/FbTHflLoPHKb
#8b7ZOhYETq7RxbIQ9MRxZ1QppBwlNsB7ZnAJIetAhBlVvOTiu1P60bVP0ehHulRE2pQ/kepjhWCSSeycQXHecJdHcedDzeuOn1tt
#1lpoeBfIk2lmPpE94FoiDKYMU0h37ewO1TaIzx01tfSQ8Z/UokrPy35WHZFIEyGc08SaMCa5LbihO4gdWi42EfFGyhjXdenlhLZV
#w7sszhPWB1OrJCTdMmtgk8JAqcOsHAs2+3deNb3T/AyBJLvXelA/EqlhacegJjiYN6Dxg/kkwnU6ZcEbrANlq6ZQ5dYr4f4OWQLv
#MF0kjd6y5PkySC8HPRpndVN+wN2+GvQ2kjfimgz5OA/jnHyHdJIDSHF+RYeTs5fQdzSZDc/W3Kppvz+m/qF3ZUJ0unYetTEH2tYL
#By2JtJKABnYKvEMJw/XaE8NaY7tHdwzvFmettu8N4j4p/mCeP0Hwbt7IZOGJoXmHVspzVVXTo/JhzuwhtWDm895+zN4o1Ikikh4q
#Gmln1YGvzF1KtKy6IdUGUVXuOEGOVRj8qL4NliuPHrbNy/X16drkPaSljpJ+XggSvdrxxhotfxEbMiqrit6Do9ES5uyMaxDzDY/k
#jAWF1175S1+t3bzg6yvnOjepiVXk5jJK7/McC790vvr8/ZcNt36sD9Y2lVwZXDxG5Z0zKmgd+AEZugRrhFraHOmCU+7XaPxNte/X
#n2HOYEjnBMv44fe0JywUksQmnEU9kFpON2dt4x7jDu+gQXPLlMjHrU289zEaI0dJ73PfJ9pqhc3AAoX5vCLSH+DAoytnKnYBCu2Y
#omOMzz59aa9fDn/xSrg6ueNJwNWUTdP8dum7KnsfFNwcU6xAYugR3ERRhdp29ZOdD1TJrwsh9hf6YHjTON5qm6VKGaMpBobK/sxs
#ZIFZ0k83pHGXpx3D5hWFG8l8yf0+iY/zmo3Em0jb4IHVPV/z1V19QLJ8KgovZJx5WMU9io/2bpEm64m/6qBkX2LHjzeJypBb9luB
#1yS7+k8cxYqiH3W0FDZVY3cOtChb4ScHRrAFlhQE0pyI4jJprpu/CvlMTeDx0Ii5rnM5Lvir8pDoEXHFlxPO2crIZk6Bo0Ssl0tK
#Ca5f+W+4Td2SeSRsqFeKXmPOmUsQ8yk+bBLS0EaeeC2kV5bIgjAOzz2ZKWcqHPeWvuVwm3w0VWGF/xXmHBRsObwcKP9GvFkSqlTe
#wdB+a4BuJ3kvnkvErXYmvb3JEIKrxKR9ZRMKJkl+de/QTm7IlH9YMI5PH9rX4xkOH6Zykil6InYWQCo7hRrsujOl16sCG7B5eJ/8
#6Hp/1ZsNa5Xlj6REO0WaO/vfr3jMDnQHcrx7v1T6KrJ8CSfe0EJI5Z79q0/jtRVulQ77n5O5f3RLvIxT4qVnTXp+J0HmweNWweRv
#74XFJe4QLFcbQgfuPnJSIKO78oKVVuFBeEBuxoOiMpnHZe+a7l+hP+gmsWuM3L3rTiC9WnZU5xcMcpUuKn5vEuC20PNuQ1v8q21p
#6HbSrU2J6ubNbOp7lYr2WpNr1E5hnyfACHcdSujUKk2RLP7kmweRYVfVoQQzjNcW2aQ0M1my+mUd2q32Kb5iVPt+s3923+4w2DG0
#+IWdO5MzbY5w3XsfrBSROW1vwsnyRkdutjYr5StDAvLrTw6MwySZGRRhW2mR9TJfG68pD+cVaSnNhQgNfD4mlXmXiDbDaFUy3q2w
#CVEbnLa2gJ5rOHwr1umaaX9xoweCiOO6/+XFpt3kYNDdcUdu/ZudO67KHzzCTxYH2AoxIkz05LPapaoxOcIQyyDjo4i167x1r2qW
#6YmqtN2h+U++RUMfxcpH5jvgbxkRFSSRWMuTGn93IvJp6FcHN7LuLFjcbCqTEUo2OcXUz7wttufw+YieYd/3Kb+z0k4z96ntHPSH
#PoU8iVFfNcVDP3kqtBCdQGZUo4JbQcqQDscvlU+Z/c8WQbxm8iqGeqGjDmQvNV6aB4w8JGdlMZ7gKW8JK/cj0adZYhssedNtjvu9
#+Esd2hPjAaVakc7pdLGJ9QB5/oYmZ2f26VZVxI1WBalU13U6ZSLuSrXnCbIhc4rWS6omsAp0sggO2seEIvpSpK70amqaNae0TB13
#Xg5JPz8Okq+g05VdKoOW7W5kz6EaNVa3QMa0yrQ/UZm7LSXqT3+PeqPCPSK/Hi7zIgDFstkUShh91aJ7A3fV6zOKZdCK651mBuoH
#mP08TBxsYe5v1pYTjMgiOmaUwXSOV7rdvmazObE+ffZS4ya5TkxSKSqesBM9ncF9VBU3Bt5HAXlDxbFsDI9fQZzC1hNLM7+FPudI
#pnmL8YNV50koaIY2IuR0x65e6CGT0ZPaxYz7ZSy+SrOaptrv2F59HfH+EjBvbHuXKZdcPND2+FmZ+bC/tj91nMfnrnfljH2ue04W
#8rzhupipGVQ51LKqZHcVbaOTSzxevVH/CrJ7OGQhWz5YBJXS7I3h77EM5Q8KxMEDtdFo4VxvrGsl9zx9SqZRXZrKTeZrKbkoeYD+
#NDzokIp3pt2rZ5wIf4QkA1/vqBeLfH89Q+eDDz6/Vr/DZv+KcKWTzEo9Bos0pVhZv+2DD+KcaPOBNZblj55K75mnWBE+Ux2iXctK
#WnkpcFiCpc2rNKFPN2mhp0cENyRizuUmvGP8tvyhr62njv+1LaNrp69ZmSFGWR+5xKESmld1vG/dE/1WfnoHzK4tUPEw4z4mnbJf
#A6vGS0EV7rthwcepfSpjj4OnNgPGD0nkv7jfZmwyYuYpfNs9wnPfRu8L0zSFCB2XkIHJgZTISwWfDAkG59ce4iWyhpwB6vHogf6+
#JRTOXg6eh9djqU0mNz0Wb5cWzc1nxYKNuZbWXz+F61G47rJWh0cYODWfgNKJbfUKtVb8th2oGFYkQg1OZdgp+Vk+hL/QObiJ6r1Z
#z3rgJONeCXMpeCEkrOYFGt7zxgtqwSLGWTfWzgnvu6VMjKZ3a5KrIMzWztNMvdr4xsAqdRaD8XOOc9y0U1oHN5Z3pv0V2dL4jMH8
#aGpdk5nMMs2+p1PX5un0J4MiT7Im1NyOephpEPhEfSZ9s4/ryqvFxceCD86emJXeZbc6hg04sisduAmQhClPOnkWB6wtB3oUPrS5
#+/3MjNdSNtfA/UnxfTLKWsMbqhHjamhfU7o/PcTep7lZgtgFk8ZR8ofHzxh/d4O6Ps4pS3tRfHA9r+DaujPz080hK2r9U+U6lnbL
#809Uyf09Qyr7OdG4LUznUcHkp5X+GWrk5YZD36y4mQmFSU+t7Lbh9zWwjEvp84v1CPgk5aTcZUoxGw7Jlb+KfawpSNDEfpeoD27E
#IDU3VzvV0wpMpxoNTFN8EFrCtEpV167okFw8jXU3PZtNvQw+NVyoaOzdbEAvC7NPfod2IMev9YjyjqUdBQmTeMqNbZI9C/wd2umJ
#m3EBJ9ff8XaGyQfRDzSQCqzzny6dMLTmH3Rst9l/rHeWN0rXy0aPf0uuOha4f8RHVxzglWZ26pkyI8xtMj9UeKNxfT5n0oElefYG
#Rv9JM9FN72HBGZLzWAMj0yHOnqmYcLQ9hbOEqgGuxj5pptu6Ip/OLNbu77vmrYc+MKkxcxhBDTB+I+wnYO4uCGLy3SOo2xSsXRVX
#2jiTl+fMHxEve6iBHnjlHcNRSsse8R1diX3XvU4dlpskUfoqzwla0WjnbuHNlJ/lvIz67iFbrolpyeivxpl5Ok3zMonzxVXUJfQ1
#o/ZetRiCo/NO6sNlv2mKEGn35Svcu0R0hdec8+n3z2IxP6ls3z7swEE5K3bRkCp29EULapOT15tDYH05+/aDo8NtkbnXBU/F0kY7
#jjNME+KbGiqGjeLCG1qbvfipzS7h5LHqx0Y8TzsOKSHs5SQX/5uUmQIB29EO7xRRtj00AzKTcIS2xbew5cQW73Y9J0DBRIkeVjSk
#r6sN/tR312muTwrzgSbGVz9Fj66NmLAs/vAFj49m6329uRQy+rZn4bC6FwF7+1/yaoragl/hmNMava+r0nPF/fiObKxA4z38494k
#tgjWx8lR1a6Gj/z5Wb4cc6K8q4NiUxnih2iGPAs3Rnh9XhDOEaE4P6K3+06TDxPGokcB0YBDNVGDeJZEA/DV60h5+e4q7KGhpE4d
#d9w6dDqUUQt9X7arZ4TeabWbVKF9gGaeMrlL+iwviSZGk0eXRriDirJP164yT98gOk51bkDKM+MlZj2pYcoP13ZuvPb0om512WdP
#Pbxzhg+W6s7aQX2aUo44Rl/W5Yc1U0wTDBe1p+5aNG97vk4WJ6ifk6GdY8c6d+tp2zDypwxfbsnFfD1+XsG7KlDYjYiMpXlr4E7I
#tN3+XsMWpyCSQ+CeuwQ4MP8jCo3SXsyTAYPRWlV78zYCfhoVyet1cMPlyFECdOPjCbVQ99s5qHdxj26yfPRyevVeuNuZpMDtnd6K
#5EAHzidG/RtKjc1DHLUVsYiWuTvWJoJ3nV12ZPi23byf8kPTYnxv3hr3dMC5df6NMlpM5qPE5viDg8EIzgQS83eLlu8ovE3pegi/
#7AsNu00eJK13R0KUFFTwpb71MT8QemxbVXaivHafMnRSUjyMZhjqBd52o6i5/SX8BVm0DiRah55mj6YOE42w1kCeNbkQM1TA+vp0
#w4x6jRJppeEwGS2Gq9LkV10hxyrPMGtPX9CH4gCQbd2NQ/HX/OkO25tVcyLqd8NkAwNhpfSLEYOfKwSqUFFQ78YGQCFvy2199ZrV
#7Yyx2zFnT12zGt6U81uZY+0zkj96NHottl7kYSz6pOb1QuJ0AZ6b6/Rc4gmIZ3gVRqGrrXuVBE9OOTajv2i+jH82F5YT3bM57L+g
#WzTONxd6NvINc0SGN2r5Q4jvqzaUch4fevwiZ3vjgsV+qg1HUPiYVJZ3o3f71nyC0o/Vb+85H1zbjGCZfDs7LyFWlyjoCpOvYSfa
#n23liV7KFqJK0MvUla510zdoeb87Y3tr5no7NbRfNLOc/OWgI+/Dz0+qDoUF/V+HDTLeXBquemrhi6bc5xld7LW0mm1MjgsmmFsH
#5PSqCW9/ScOc3OjOoVhMrSvuSFtSfE4fVnZ8EkGm0xVCmzNLYvDMrdvcKz9Ew572uIdR8BEoqyy/NsZXFMh/Ch6KGjQgf4OadfX9
#sxTCI6neh1hwMK0btpfPslP9LHq9omIeBfRVBDYpC4QYw9YyDPdcUAFdHCuWKCZIpNBUkQwtb2Ld2T7QGdMtakQZ5lCRUR3fXRAR
#sUAF0vPhDZYzg/k33kR5riVPlMqA2UJBi8ihp+Z4ru/CnY/SN43OFNqTa9ycPvlJjaGFaGYDxT6Wip67rc4mEUE/9ZYSh4pOuVKu
#Iw7wK0ZEUjnn0SxRUXLnsz3kVrm7Vz5HH8Ns/AJ0Kk6YRTJH7LWEzTVD0lAIXK2JHYfDQo3qlz9G9BNcoVnNKa0vpfqWSj+S852u
#RUTBJ0lALn5A+GTwVEU33o/Y4MpmxxXuwzoPFi2HIKLRzAGnO/6+KzlyBz3Hz6/XzDq5lS7CPnX5ZfXfsbnnZxoVREOw6kede1DK
#T1yTPk4azfna/oDKiDH6WbQhyg5m0VvdOWOBwNOq+J7m9UyWzebc0jva+/2mqjjN30rmO45/rDA3b7xre300IMT7UYC9uq2UBDQQ
#x/iSO8rM//XNxaTbZbhXdfnPae7tO4nQ6wU6OUams16L0C5pG81OUGl8Yr+0ETl5763XhAKdS8OWP7ZWjXO1QGMTR1GHhVRI0/fn
#efeePFE60vpgKvmWU0JCIU91vmt9ZpHZJepOA8HRtbffSoNvbVtW4KmG0w9Mazfc41OYdomaLjZ+ySfwcnreV7Vm3SWbGgJ52Wrv
#dG1/bj2YdX4donWzZFPOjpeebkjKEEsKovUpSL/J00FVE7PdCSXZxJqYamkvGs8TFeUmARGBJwpXivs9HJQ6tCG2FEiJtyxhmDKW
#8If97HttNBJnR4LPUD/wUH37fMes3DwsYtof26IZ87Dp/koo2MK6w0A0m10uX6RJxSG7RF/DJpbEIQKqV2Y3m63+ZpMnUvfFFy4r
#x7cbUxmyqkaHBhER4gmljkqBo+TzJDsw7KOmG/kOR8/JAh4ZrZ7ANTWzW28uuUV/sWJe2/sw/SCbwr5AMndPUCGJPWMgLfkhtpV/
#ynL7ljcK95iG+fWaT6rRG3EN1Ce1s92fR+8Tyr5HiL/0CFORxMjVIp2O67hhz58xi96XVy2cW0nFoxe6o2JxQ/b72wQMwtqbbxmp
#JIPJlNktS5oLrg2pE1gN89ul9cbZkP+YcxKuzG484dSaqTJUcrD9dPt7/NqkbPeV0MCayWxL4sEfGYcaZVMk8pAfN/vtdVlPajOt
#+YcpJrVunC4F6ydl8/Rct+czMY6dcEu6KhbAGn4smjT5oQLThtkrTlqCyie6M2Nh1lQn6eBgKiOVKkF8XvSOVeF7FXxfLZN+Zvk3
#L60Qs5iRJ1I/0vfUHcCVpVQnhyqnvgVtTMYu+uMh1lHdXlDtgKm1rxtPBxRqvOuNS6LrGbnb2loXe3cbmOmbHd8XG84TazmWiW4a
#ttrThzmjlCK+hs4yb0f26tVgN9wDF0a1kNZwN9yja1TnJZMNQXmBh6LFzy8Q8GYLG8oqxT+Ww3Nm8I0cRZRV8VvEcEzgWF7cYEkz
#bLSNNola7KtLKS3M8Uk6a8Hs9Z4kB8HBpfR9wlHdaq39tyhdHWqYpLVJ/X3ZFp9PJ2QxQ4VFcvWLPss/2H3q0HCvbGFq/yNizel7
#NpWBIIdko+Ca8GicSFfgKLdAFOv6q5OJJuZG5TXykfMs5UgVFuUXNqVPd/VfRAeiLZ3fOJzm9p0oNx3W+wFStiunc5wKOShGv17e
#FmTY4aH3yDPyXQqx7FIgV8lXiHXNo9SwG8GauLQE1x0muWsYqvPfHUi/d4plBhMeqSj6BsrKGsCSjAj3vpdUlupr+MJgvikOFnqP
#Ok1u5nyapLsWxoPFf0JV1kvGl3gQ9BGGFTvlMNqhjsLXnPPwWsVGseTd0kI6dNqCx1bbn/BHr+TU3U2tPBuVR9Hq0s8P2bBR25pr
#EXL0XMc7zJB9xWLV+REL00Uo8G5I3JvvzEdHMgpY5ecx7dQFc0de/vdrXeGl7gcBGNLG26OOtFOeFqTzafQ2YThfjveZ727Ow6+G
#0A17kTyK0I5GnHpRx+Xv71sJ6Huv88XybCGOVgqpRQnCDK/efop+Qh+WEr6poolKS/f4eMfjUd17j4mE6L0HU6+17mkFpS81+zOa
#Oh7kh5e0cxFOWBda3Lc3XVPBKqOp7+B9A9s9NErb/hCeac9w1IfQ9cUO0rJ8ffM2joykUVgNZsyNhLdXrVmoyGVow+bTcCtYl2+F
#3qnJUh0oSZ3w8KiXOXL9cJV0ZIcy4Otm20vTndiN8Ii2T0K8i7O5bzf678xdSSZFszkT2FuVlMrnohDiVOFkM9G3SCq9uiiIu3QU
#fTbbdLb8pIm30uIxcSEBVuMHC0mCba/NRJ78Jbktcc4klOQILMJRZWwytWA+LD8dyHOF1q2vinOTd+npDpL13NP5rsaOhCxkR+yj
#TEN6WQdVBhVE3tkR6Eu9H+7Du551I4oKMWJUtYH4aHvl/e7dra1ml4Cinmm1z3zJqVSPHfNYmgNxy8N2TCLQllBfVFU9b41cURs+
#tZmQ/fjBMrB9yrGuwnb4uX7gWPlMQCpkpiFN8Cah2laquizlC5qOdcraFLAX77NsdYDROuttvlDPGIkK2twbyFkKj8o2g9WFmI9P
#mpsIWivwJBlLKTxoGml0WbliunRH8cv1Rv02vu/bNf1EnwfUIXlCNWEIM5KwjnH1gnWpWnbnmTOezNAfDQwRVYbhGQKmOeJRfmuC
#a/dG5u83BTGg9H7Mv/1F6pWhcJnrJjea7yt2iX2srNDH6HfTKD+dRCYaHcIXegqOW1VBBEMKu34BGK9ciUfQevSwC/I8J8EFfq/g
#mTKLDQ8Gu4YJOO6PsVcuSqL8iMKa+TBIZFfxWXCpVaYKItvKeRPnhMp/50ZdVWUZPSUMpkEC3u2lf/DCoMJ/4AUlaS09/7axINSE
#5S1supRhbbMC1+PNE1LsK4nT0BsGZrcKoxPjUTU7t4y/YK4ffUki2+EYZnJ12uMwDmmazKKrmLpn7RI7qKX3LTx7hQJ/jnpOpoH1
#DYUBn4v7bKNBOujcQRC3L2WcI4ulyvtwV9Kx+63BYlm53/k5ufrWtyoxJd6rcS/ymAO9d68mnt+Z61FuqYIqKPIs1kxtzYZRrG+6
#aHt1sHuPO81ovlN5gGby/Mw32N2qQYm3vqNCk6GxqTTWqYkVe9TzxUc87VtQWWtOEtcbC+aIA4whBY2x0nZKhWurYNsrGa93AvHF
#cd9ausdjqkx9gtfMv/WZun8QuTa/U8T4TXEqdXO7dHiCM+L6NVjtZ6KwT0VnI0clnyOXb9SxLhHdanA0VDLEfzzVcibWk/hhFw+L
#q5LU+rEZZ43fDSop8oV7lgnxVB2FX6iLaFUg2iP0vc01fWtPE43jrfID+EbfGt/Eb7i/53/S4VJhS10HdTJg/WIinD8130ZTpq3u
#rHk39WZqH6pUH8zpehv7Xv7p2xDFvc9rpz5nznxEztjkR6kGX9M2t+9MIloHpxz3b6c35t5b205uimt+b573elFSIF8Xvyq9QK8p
#dlSL5YuJ9Vz5PaeW4NAfpAUepD4xL2b6p/x2GgfHn7+yrxNIUCowuuMfyaBG+uBx5flQ1y3svI3yceESf41s+PvFh6VlHGZVxUff
#iQZIz8Xk9AIORxp0RIadNOoYiU54OTf2JdvaTb5e12j8vEI51dLS3EE+PKeVXHGqPiKJGRwoOF2msFfs7CE0TTRwyHn21L8bXFG+
#NaKeYnX6KEbB60utQEFR1vtvGZzpsPgMf3N/t+zRHy53vNUoSsuxDLTdwlmbbydJPVs2b9jIiEifin8nRJ4pqqiNr5JB5t6XXZEX
#gePpgK3dI9CqLH8M2+ovU9Am7mi9t10SmB9TQbBL65f14vPtfvwv3ESlHnt6jAKZrJryi6v9CRCrjS47jCn+a1wMS0WZvO7T1DYV
#34zIacGQjM0TTPnv2nOYe56vHhqIvDaLXVwIdqG8Veb6oc3AnbtTe/qYNyt0CCPnNR5VmqVJoK+uybftkYjN7fdolS3Sj6+ETW29
#6ED/Zg2BWMMI5EfVmbm0PhZ7O/YbWNKj1IfLdT3RfI6v1XRd7vTdOCplovAYvc8b1/AJ9c30QSFc9tN0g4GKO0yLaRV6OJJ+uhI6
#hok4piDWZpLiCvDhfQ5S8ixo9ZHe3sm61RoUJYyATJbi/g4EaxAFhghqD7+WtlQgMZNOlvzWxZgxzS5+9CP5IewkIs98TvxphKR/
#qTTH7blxs/Sltq0k31Ifja2jt7LvDQPcxg26u2GYEyhxt9k4OZbb7Mbff3CKDPR+AatAq/zWFLSmtBuj9f32TdyOqG8upxkGdJOE
#8qvkybs3NXR45NdymkuscDGXOAZKOKvu8D/meXJo9fRK9tHJKnxjuZ9LpUs3bXWlcZYgofVVbxlFrkyouS9jNm9duHkH+dcjutYg
#ei5qZ5ljzrvPBMiu8IBCUkpFJYJj3JlZSRWxPlwVvP1m1CO6SpjC68Rc84SWwSrmY9DJeatvo0WIugcoxfFNgizVZ+NaIhnuMEj/
#Bq8jsUuWx6OFKba3S6x1MvZ5ZsXQxu+Ht/uvyvvRtjwj3/KlIZjYQE82V1TqNq5rXHmnfMekPf9kIeD+MR+5pSZ6pcPd2dNUKsP5
#3jzi01uSoQL4lixh9W7325aspShqVRDJwucl9kGZICaXVwW6zYqWEajeLSgnUk4Etiiv6Ck40DZoxXS/3RZfdjKtm4bDpsO/8Aax
#lUgEgHnO654pnJ9mgzAqVYnSg3P738s8nGvvoIkklMV9ZdL/ebOu+Gnq9e3noyclTNBX+3gqueDc853KKyeHEP5r2rIMvp8tCtfO
#OGriPT4e9ejH1lG/1Ss75OwgOeo4LUupEk1n6rXXy2U/eNxo9yB79vXTlyRN2O4PbmIeCw3ebptovL9bNXNs6qzjyTv+tRn+7Sz8
#GZpJfWDDZnPdtFxqbKcRwS2lvQeoRzeCCFm/FHeI4MdjWjFk4z2Vd0w17AjtDIsyoT0WJZN48zGJ0UhJHjtZHPO1hUzcOLQ5mBeD
#wzIs6Mp1y7X0J+kavMrkT/S0amxKm+43ZXmOM6tkXoke7SEseZvOj0NAP7by4bU4WbTz3Z4G1WgHBHmI84Fnc/8qYnqVe8FfObCB
#eS95Rb8ef/MHtbpZo5t5+Dpun8geQ0HdXPfTuVhXTTpSf5Nlt148N22mduPWMlwTA5572CjGWDL8YftYY1UxXT1bbftXTtaz7knh
#fun9Im1MENT7cNL9NPz7aKDduwh/c26cmKWhFzVLkfKm2dFMRJJ0T+jPWjj91YYovx37m27AdgPKBGma/FtdXQNgXO0w9GEzNjU/
#1hT/Rwn9jpIpSpIVKc9HEQWiq0cnaIkquKgJ7XVPdVnCThTWCuhQ4zu/cEdL3rNZ4JUOdbwRyW/ztNxUhdrRM3I51sztVoUe9PqV
#hdStlpdc7oKMuBnJTnm2mbcrScErLl07rnb+5a2+ts0Z7egv6q+i3GYkr3rJvzA5TpC9GCFPMEWH27Hiy9SQPwjb6Dr8bhXnKBEs
#+XYHi970WUz7AeqYLfb7pGujJ0IR/kUC2UGaoR7MX3RiUQkMR4cxUQznpibTDqauFh5rfbjZ9lTVx816aAXraAqdqz+8f/IDoZL6
#p+y65Y4FNQQ+/GPotdTbkajVj4nm4gPuiaIM4nTxkO21Ra5iPWgtKyl8HmzmzLKvNlDDep9p0Yr9uzfmAO08t0ZG0M1yqUU1z5aw
#fDHP7fvKnVFPerm+9kUYivExSJhcj+b2NXxM3NUVT9EZ3P5pZidwMxxn8gOPhaRn3bP1Fs+zwOgoGKmZqZbbp1zF3lyWKzIu1re/
#0ziiYeo3ORHLu61CU4Nfyy74194Yt1746PzBTTTjyf3aaqI5JZ5uG5VHbORzFisBwd9QCUI0t1/713zP8PaxnGThsGu2/5L+4+kW
#/FX1XkZ+zk6XxvDTqlgjXUJlTkY9th6sFzj0+rF5FJUdkdLoN8fsKLFMlWzOw9auFslP2bzIvtfQN/rM/mbJqH30xv4Wjo4dkz9P
#RjxNfp4dAdyR22fDxlAEph2HSwnaf7FYpXvARrL6fdlNfu00xShABnodvnJusbaArgzJlqmRKtk0gLKuW5BFcqjj6j53qfCnrdll
#jzyKty84C35Rm/HyVNGPrMKN0Czelcu0z15Gxfzu2p08mQbe4CvXxq2e5ArHGcLNXriI1yWlmaxS3fwqhzf8Q94KJT9bmVDqlNtw
#+Q5n3AODhrUUq87O77ehjnYVKQ+GIOHv31/dpoyC4A50v3+v8iAuyrW965Nh8cPKotOipon5sckEvPt28yPkJlYdOeB0KJ5i7TVa
#L5q91gTft/OUPkT9j2/TPd3QylzoJiS2ebcx/eO2HmPmaFR3jHJ4XtA7ph8yjenuFQ5FK0ebxBHSlnH232BGzfFPwl3xgQhKHGXf
#4jHNg6Q0eqVmvgWOqlbB1eoy/ZeGS6pl0BsvlJ8fv31fKznxsJSTuCW0aU1kvDFF8MeEmHXIBEFihPYNVTv75R9VMiIxZySDa4El
#ZUwKovBki2flpzcW5cccMj0me+4yETfazrUyTfCPanaHTJosJg4stc7Ny9Tg1zd9+bLhsBSY87LpC03BekdrDNSsFOqiUzdkZJA2
#XFmB/pLyG7/5Xoyjj3KDRsYb3UmW15mq6ApfBdFe6S3SLk7a7WZa2fp+n9XsxlOTPFSesh9IZ+9xjn5t1U/lkdntPMRXW1xkwKY3
#SdXAmveUKpa6IKaYf8Bxq3dQ9NuBD2EzcfeOWMx0bM4VlGe0Q8GugmFMZ7gvMFGL0YLS3HmZv5yaLqKOkPWF78iDxpVQdAWj6UhR
#vja9L3/4KOgbFo2cJrrVFj6vkaWiYJ6ilrUj3IexnItfGR1DUdaptVifFdiPp9mciv9o4Kqx2Vzpqbmdk8t15aXnUx+PnrW6SIGy
#u7grPywnPT+ivs5cMMDAd1Op1MZnAFKdJZe/I2ipT6MtssZQJnx2aCsSelfzPvEE5av6nuY8r1BqDAImDttwdFnTsMgSt+fud6rn
#HBKb73eA+XU4rm1K1wS994gquzqUTsyrePVWvZNBTYdNCP56oTFvIYlL3uJb/YUxR5iug6hk4tybAsjGwzcIIyPrkoqm0x0DzGHO
#6fpU+gxul6r3wsTfuUieUxj6GNmWD2AFfRpU6U6F3c8h6GjK3e0ExbOA5wkXo5x6cXFSa2foqyA9Z1TR9o/Ca6u6uguYHA1bE9iG
#2slvPqqs7Me+Pf/yVUumo/+DJWhOefGcAK4kt1i68XbSBt7Ht+Qfe3r6wYuZ+Fd4cVxvElEXsONR/GDFFOOIps/jzjekqjnyKH0y
#LFZlm2VQN1xWsxwgGqyOhlnA/S44OxZrycq8b0WaWWeQaGifTP8ersnLAv6EiG69sHCMNjyKeRGsFwWW4xHqnxXcWSyZuT7dxusI
#evWVW2wk7mriNZYPcmB1GlEGQzIuIcb7vT51oaBCEIMr/d13VRS3zIeut6/IMghtTPPf/XgN7Fxw29e4liClNcyhNey4NV/PljB6
#3AEfW/8K3kjEsturTzQD49w3ltKCuW54O6vjpL/KOBo+Qn1GzgTLpJdEm59ryZ7fhtbMsZk9/F4AzZjrZPf6fkS6MWC+VepzRnqO
#U6X/LYnXBL19UJ0clYvMTlIor2BmobGSbXEm4tbZ3aCb57E719r78XuO+88Ll2bnog42Py1ltnCGvSTdpptFJfgOMpP4tOo7BBVA
#uH/zrQh3R/iJjVPP8LKRS7wnXY7c2VDs0ksYxhoTIwrmfJBOcPS+jhG1FVdSFKvsQHv9aK1gJ/DRTjTxqplBwpBo3mM3ImsoOsrO
#p82NnAD7HnJD9NsYpqgBLaorcHfrQI1oLHVdG+fhQRAPed/XzqoasjtXczEt0NVu/5iY2zuEsCrSeg0UL84LCWlxiHEq2nDQL3LZ
#caNlbG055I6weHIshDyYiZ30oZRXf30L/65XORY8fP4Gp6PvCdpRgLpAx37QRKL4IHWNv6GF+jf17qzr7hPvi+By6m7NlS8/qLPd
#3sXTCJIc6q+TTM8mJf2wd9Kt9pqJqXdj1bZWJGaDzGSd0kxqMWcYnUUi33fiLEu2ualVZXP9cdLYUX6YSX2Dgsu+sM0uT8RrTuJU
#ltUMcdQP2saUUWKVV13ey2ksYo56cLeol3l3kXUKRTa8V6VOF5bU1z9kV5FQmVcuT4tQN7bifrNAyyV/22MmUQespXFOUn0k3OJO
#pRlDGciQ5Ttymq0Gk9qkv0UMY7lZ6CZXfgMeiOa54umRTdLGuXArFD/KBT97E6P2rblg2vCrDvZKWtN9bhma93eeKmHK6CQ9fv1A
#uqfbxko97LOHh7/II1iPxW2SwWmv78H6Lplk8vGb090j7ajLz+LrV7eM1zg+kkPknmdx6eZxFehVVfaldUg2uW0WVR2Rhy0Ocb/C
#lwl/JA/CYuNGD7sHX/zKvfeq3f+t6GHvA7ZnjvZ6kgKHjUaC8hq10R/ovPu+V9juJ0nSYhKuozqZ34j1y6yi8N+zfdnMNCvbJ58d
#mjlfmciFEkecItcZYS2OIoT4MYjZaLLUZiYo8+nJWarkE8jtMEIPGLEay5XJH2226Zjas18jd0ye3XaUlm/W98L2PhJfjXW7dcc9
#4AWqwuHLZtrmaMeZMK7bkS8xr0jeLBHSHNKY4iGMyn1puflwvaBf1VNE2YZMcb7iunXjapK7ChnKau5DML3bOdRRZLh9KkudoOWG
#1JdImvaNGeyqz0WUHmatGLmzdtk2IxONsohQqx+VEoc/Vl5PtUgVEhAoTDx4MOp5G3yNVltEgIf+/iK9DdVU1dZxZ9p6TrItlUCh
#cdJRV+jUohe//GJaSfE5FhqYTxBhptz67BrOlRGfJ7gOoT3Xerl3NkEnJCJqHnXq5a24n+RYixyN30AjuDcOtCfeIUh3POVe4pTT
#yK/0jW/yQOZc7GxaW3UwZB5/JIVxYFi+1E4ZuOOOMfFwJW9RLNn57eTVx/mqPrV0eBpcqyi9gwXjEQgXabTrBXdEPoimP06EKljw
#1zxr+nQDakwzJMKAn4DT8TWgyXfkcK4krah04dBY4pxM7ElBQ6MNjcu7wkqeWSclqvJ5LTiMoB5fMIiXBBMleNdzOGKoTd7gwWP4
#GG2HktET+fHqU/ibbZqC6UJys4NDhHpP0Hu7EKnCNLWzrd21kXCUc0r9BSJxRBiJ3ZtNj3chbHVyTKF9E+VCO5qP1kykDc2hzmPv
#LCVwCdv3YyhdfCglFUUsEx8+o/+CulVVuiBHGHMTs/hZGcoYSSEXfFatziN6MK67qUUe7zqvYCDGg5Lm5Lezh+LFqk+nZT2eWS4y
#Zb995gRCvb7SXXTU0iqxYfm4VRer+CX7vqkfd44U9KNgbty1QRNVp3AeByYHnzoOej7mYeN1wzj0bo6KQn4uFVastThmr920G2Od
#3zg4ckwM5C3qQyJ9so3sWEZcWg3syVVnwgQtNN3CPR2qrBM6cuy1r2IxKTH4vGO8+3HttWiUTKKX4iKB0U3V51t6jx454csMKPMq
#dGxvqHR9Z7qKSiRZRypsb93eDbUP+jEtWM65xE644ID9nR/u9igGh6LU6ZWhq0Wc0JFPB+cDua31rijNDdRseRp+cOvGhopYYQSf
#XIXmQUZJn1s0q/rALng29aVPcP1Sm+Sn9u9fXp5v/9g4djvc3omTxW926XnvJlJxw+rMN9Utk4S2XlmG195eH8G9tIA5pGAHf3jg
#4WiKJT+l2x6FTkkZL+dv09zawRddYsBdGrpbv/zcvVxkRW7Pmh1FlaLlE8jD/vTrzSHiTmOect8TkwPvVHbdIq29Idp1S6E3GxTz
#aM52xk2LPzgwMLY9ZsPIMHjc3L1aJPhb1IiM9qBmJC4CO0qR6UISEuur73YdvmKjxUFus3Xv2Jvv0ngzZsyxGdZUq7BbiZE9mbGx
#NSrnu4PiF3g3iHXPPRorfbyV+TuRJefdl/5+9yiuLc01Q57UblvFF33u8mxPz3sckZu9td/drlO+LYRlx3q3RebmrEsBtZmtdu8d
#uQXBFQ53k49WYyhQC66xFYkFh6/vBG/LnuNEWr7FEgOD9bRx6ek7KxW2XikpqboW3mP/rokRtxFz3DL3cud9NfZMB9ZTUR7V1frn
#t/i8kj4Y5t8li1X5VpoeUbHCMnlnNrpEKMxK6uYcepSDfHZg2a3R2hzs3itCucwOS28VWXmuPv5IKDRVRZ+wsY4RwdF9e1T9dZ7E
#6h430+xb9hufrQ08elWxKVx43+C8T6Btwh4UUMbkEd1mufH1Wy1vYHK50WS1+Tv18s71j7P5Fs/UxWk1pfA79SF3kuezvPnSjgSP
#TZ+1CDBzNQYr9/vc0rzCHeZSG4HzKKrJM8NxQP5NlvJGMjtBHwOX3Ydi6ZJovM37P/Rya7wSv8LXA4ulJoM/owUeVJbMwlw+6RyL
#+cjaKNTSfrlNPxXyPUyxL5RSf+R7q7RZvvnLN3Rd+Vk51LnJOo1PpFJvCOfVwD7pv+2918RyLPbBI4N6kvTe9LBbgzNZooezulUy
#7eeQwuP6+91Jn4UWBEhPPn6JWq6iofQhdd5Zhn4477T9vH18GM9fkH+Fc7+PxJsk24iwYE3H9kFex6Ha/FLo99HDbPPsuO+ZTmvc
#Du79KnWVVyaDnFSkuvfPSg/Qg75ZpayzNH9Ke9+10m9tbsF3o+Iq2Uglg5/P+MLG0wGfk5EK9U7X+olPWI3oOfHs/o45YOaVAw86
#+YOqMBSS2m92chjGD9KLX44xiSsedMRV8HOgu8NCvpqn6RwDOPCWbZV/mnSTqammCzXrHQFPbbdVtlLZ/ZNHVry3h5pTbvYfpT+/
#Y9UuUUDkXLjqGTBekVlvZ3rXxY2NvSNj+2xkKBsivf11u/O8YMtPQ1cv5oZvV7Kj6BjaD3HjioiaLfaT5BL5mvcHkVCN1EhPT4LX
#r3TFrAkr/Y6Cjfkeu7MTy7Iyxi8UtSwESvJzSPhmk1cv+kZVs8wrd2SqEYPDZecl8uhHKd/Fl9jzOa8mqvU8WnsUyJBENTMVoes3
#j7uGCpcQT6gX6l67Me6DEk4RT/z5jqCigdP+eHZI9tlyUdv3b5wB+6ew0dtLbRKLt5uaynR0Pk+FvDeiFpoawsPRbj22HOfVFCCc
#NEp6/rpYeYi24LVizADN/YFn86O3FyUkHx/s2moJhqOTkojcWnjYdzBKolGzqZRn1j3fPED5Jh2Vn4Ceu+81SYNy/GsjIZcbXvkj
#5nSGxVhs5JEdNqJebd/34wsZBnFNSAin916M8XUmlG4NYHMH6WzhH8poPIjqLzh0IeOK+Jpx1aJ2l6hV7rys/9vwFWrPkMRp94qM
#XaWQYc/lOIfYRAqSILu2FhfaN2OuppR5yXAKJn2l8PVdGWEhgQdSDuvnrGcf0esLSQ4ytY/CsxP7TKM4bT/e3RrtFCczJVfe1Kxl
#yERHjaWgF6LziWHCTk2KXdPeJRVOe/JwMHyLTkCwSCGk3IttbWwjyOqpp94+lSYelawh3YLQCmFAuO++Zcdqh4fLjeV7u9Vm4dPt
#OVmaT2wLvIkiqhgNcMmiLHc/ybZx2PBKTvevDbfyrBSvTViFJmPL+CpGKW6MrftVqyjracxgZgje8dbyd1tdbvva0y2aLok6LtJ4
#nEIyHAzfbLYRbpPoH2dzdR9zENx3/nxY02tNoxIe4xd3GvdFvsEZPed+5HVhqzVJD8+AOmvxztT45td+uv1nKDxDdbH5fCfeTUah
#NopTGp8XxRrcvMuefxuWjhT/TtGKTlLxQMxAkwC8eQtGFkRFxJHq/axb+NoPShotoqk8x7qJtUUXcyZ0SjUHsdy14NUzQR06LlH2
#Jg6ikSdG4WGNZQ9Zc/r6vsy8NGcNOH+2ZD7qlQnS9NtnCrxK9Lx/4AlusPJ03dIOjsoXfnnBzXuMjFfi/W55ON/OiD87aeAs5sT4
#4L77vCh0f/A89jt3D5qJRX3ue79bEnrsG+dHJNe/uFy/nu3FTF6nkUFiefWc6VDBWcP4O01Qg6rni5jSGRhJupzI8RouQUd6DMTH
#hB/quyI7aLC6uuX9Ivr57MZBNt5Qc6uRpPWTOaxH1XTXsh4brnrT0B+27nLGhvuXZxBzoDUl+Rt4LrHzoNv14/GoA7oEG6df5EnL
#uL5R+Id8VCU6C3NSqM1BY0OOm64nItC7ITAWMvoRL02kmN/3RVomZfkkD0v2pjdF4bBFeGYvkRvt49q61rE2N3+BSZQm8PcpVv5E
#A6kFZ8OpmTn30/NbTmdej0uSoFxj0OWtxnj6hBtkXSQ9de2D91HNe1vlsB2aZ/v7TIMzCu8I3K1V0WRNIHaoVBcsqxvHVHbio0ty
#hlIQyT/OFbvr4UjVF8aS69+XJZBvgwm5pee19Dzvy143KXxjw8Z8uQAq9jDoA1cb5jz5TksSwScrui/YxG7Tpm8dg2usCiwjWjIw
#hFi4DSv7nl/pLDr7fHRDMOVrVlidxc6oV4GhWWJThaZIUOa61Wewlw+X1q5aisR5ltLBp3w98vd7sP5VIxGtqcKA8iEreH8x9y0y
#Akorbn41KjWjrYfu+l5Fh0pOUcz8T/H3xd6r1rw6FCliUA9smRgblxTf5MGyOWaW/LEomL3UJrZwc83W557zLWMJ9luf11xxg/ZN
#paqvlSduRfeQYkgonDm+e2KMLYGPF+MolKGvf92XfwAzhgLhsz7jfr9bCzZbWPwwCy+vJDYI66EhaVeB5hbj201hc+IqCcPPWmsZ
#CMbDtRXD4PnWjOo6R/9B3o3SZ1fRyBdbfaq09Z4BnXrkPi9hQpXkG4PP3N/Vu63Qod32UthohkIJsj+p9exRqaDUpIT1yyDmxgsr
#KglWkvBH00V3ZJ7gMwUJ5wSXC8tOdyYdJpS3RO+jFeueNSqzsMmqp+i4zTjM1+tKU9t6vuMxkC9Qo8BQvrO9SurYUukbtfd4J+6D
#gpybwhM0dp03ZlqNmTd6vBIYm29FY29HZvaFZ7PmMs0tvPcwkix0e93JmJf2YLK2BOOlbO7txONcZ8rrJmnTkHjGJOmpWIw252BO
#WqlXC3OkuBt717/c+mLXyg/rdD+cq+HrMI48WdwKoe1eue8aTYg6sF9fHTL4+fOwQ1PhR2tywEvGpIPUF30Shsjt38dqfRZpDKeL
#W/OLX7kT088Qw4591PF26aXE44M5/7pOqRJPQeiiv9fr5OmOfu1p0ztsJM5POQvsy0RkCt+WlYyyP+r0rLB5ohDcQmFLbd/7gSdz
#2FOG/1MHzXeK7601XV8/1GYojUdk96jsTz3UEVtk9sn4oMjWHH5TsMFEwXGWR4Yp5L5RxyyNFEr+o+mA26OIqkpKqvynkt/Ai4sY
#D67F232I7gjlS7m6B0+SgNVsfGRovWEpH2TLf3UM5TzzWClojvXuQ4FdnysS3KkjRmLxCUc6OVgGifW4ZvOYPq0yP/IDGI4OO2cn
#W5jcr+V9vt62x4Kha9XVS705zX5luvuVkmDRI0PFZBurxBU/qSef9j9ccQnoCSTj5n6TLoozOxIhkc0Qrbe8s1hibZrsib//9tGc
#B/jejfEmihS+rDeF7spJA4euo1nT3HAudK0yGsnwt/2+43Gnejecrx9vPtxzA2HZ2PmUkNBGvHfzSchcNMoqFWeJzPchei6g/C74
#40NCrBmOzNIVhSVP8N4HlavdOT3Xtg4EeO0h18vbqq6cJN7SC+uZjGFSpxNW0B5xUFb2oSnyM0q8VUplxAsLtOS6NVabEng6eDsg
#+/AZVbMMvD9cKZs8Xnyhipmu7l537LGP+f6ho5xs0puCw/myMrWdW98/8rhaCPuLsJNxvtp4IcSBjy74hVbhQVLnhLvS+nkqPrUA
#6ebr/Bmb3tTp/UfdFmV0M7maPrx42NpiEJiomWLfTknVOZrCO30KfM7zDWwx/8P9z0XX/TI4fVZjV5I7qjm2PFa/EJbkg9xBwqQM
#Lu8QVWOpHeNwn44eOK8xhcP4jOcqe5La10KXUVus7yMSn6GwEU0Xg5DhVN6VFiopokfiYNssLBPzL1RPGt7P7oRpfn3oP/Km4kiD
#jkCZhIC2yo6PWyrrUfoymaabzsLi1PWJSpWCnU0/HY3rvZ2fyzMK0ss4BdS39UPzUiKWt/LS+cjv58fLcSSkn0lcyYu3f17H9vxJ
#p3R/jJwEa8K36Hvp1PI2z1ogITqCz+vfpRUt20DIHkVAOKysaAN2u6RtuAu9+vge8r6/y2y5lUyKJsyRS/LlaqEHesF6Ys4eY4B1
#dOS4s8tnFWzbu1NjVN6dUU1CCRqiao3Vlk13TIpFhGl9BSXmNnmNvYoClVyYY5ZvFys9ZZ9ZW5XqMRNUrGz08KVaWgtPPToMkzDG
#ulfKjLbC/Ea3WR66kp/JnsmGM8AjabF0V4dAav587/jc+HXRwblKowbqD85A18D38kdN8cQ/XnD6UETYo8hgoKCEnP+wpNYJWX4g
#awHtvvmoXcz/VGa5zTSTA3W+N8ee5B3FfRaeqJmrNwbd8VxIO27CrggHk+XYvV6D3X890b96YDzSLyNxCqWGhnDdNgN/4gGTrJ23
#DWV3xSlrnRE99PJjUt22l2t3EqHsDPXSe1+2yrT0mDzd/cwnQEgDIkdHFn7X5tawf1bWJLH3h8Z1sdTtAu8K9A50+R7xLkHBe2PX
#vYy4mfNFObvbtD8m7kvsvhcnyRTdRn9Nlh5IdHPXir77HBKtmrrvbDkI4yHq5b0uvNs3K8g7kh+foGZaFwMdrfK4jTua+OnM8PXD
#YfdIv6Zh1NfCHBLS+zV7fYFERB2PnZyFOUEa3u8fC+kYQvl1oFH9wqg+DPcSnImUZCLl1a1qIvbO9UzSywvir1q/8OnJFIC7xmdu
#nzHHXtWZfzZ5mAsyeeloXi/ZtPFR4pRoQOeB96GcXOdGaL0wi8Ste2ahgxm3s7qrymtqbcTiHT7cIV611zjwXf2eSBz3YH4vNZEF
#Etx9lvHCuZFb9TYhKo0liuJVbnTPBES/2XMNnBmdivhzSlWb9VWLilX3GlnBE+2+MLhqTh5lfuAT3veY0fNX/PwhfU+zi7+92NM+
#Icqz547IkpBRwDE3ordh+XAHt9Nm3IZCVp8m0qresB1rROrApr3oNmpbkCoPZteaAb3cmm8eoyC47Q7u9XGCcy7GlOBsRw5iGwWc
#7X7rIBSvsZiGdILlomkZFAtomawWCl0KxTMi9HYDpTioLKpbS6ymHPwGvcGWS/JCzJwhZkMTtlwkF0kvllQDYVqcrSft0wdsvKqx
#lPRge/754kMFnRNiI0a5YMTzhykUheZJr6N07TXp5ZMU3rPyUVXKPL+rTloao7vEe4/2vlph7BIbc7IeRma6Qdi47vzMNQORLY0o
#oe7HD7+RNhUKimmUWT50FvAMzHOswlZPj8UnjdVx1tSCVmrZRzI1XNGaUmGg3JD/1qqB3/v1u9jUDq9RQWE6RYmuglGn/Z3Qhkek
#emmLDw8UX7ivsK0c4uzxxomiUNNQkNk91nYs45nze5UZD281/6qzXO/ZtktOo5lQNyL8JeRumnPMwIls4GtGvcqjN56iYb5sMvmg
#11amHmoNW1Yz3ZGHxiG6DI78rQYmtGrNTJQiNo6LuJIespD+VPq31+hjeETwYpLJcY5xOmRyR2OW+aa8iWPq3siJkh4POzxq8qhc
#PEm3iSph2irLPsP0Xk0IjjvpVhsRDLJKbtcetLffMB2VbnIJ6FSM4kl+ipZSrJyl8qh+483HRybblJup3PGqPj2T4u7mRrsjzEs/
#djlz2kPqjwaXznIL117Z8Dry1+nFZaipt8tf1+YJxUvsk0652/Ip9ROXhmv8S6s2E+VM2DfeVIYpmSHXMC4BXv80TZysReGE0x/7
#+w38ygyMMRHkNcK2GbAnVwqZX2CFvlS10ZIn13E+WInizO26t1Y95i/I/nCl0RfKMmiQWVny6mo9VOHUn3+q18iaHv3eG/srsuJ1
#ijX2dqqifGOC6AeeB57462u5tOVV7ly711ynOG9w2danCfva2NrEc9Bc+QB2LXbVvx3C7Yr5Ya8yQ5Arzp+x8JaIhOqDkT4pebRs
#zs/hpL0MjsX5BJp5JM/kgomOdek0eW4q20ozhijNOrHiTGjSUGjSadIQkIAoNHloCECuX/DXWVo26RlXCUqaHq2n7V4VPvU6k6Wz
#LbrbkpoxfW/HrLV63iP/1bxGRsappkDGCEWd9bTiFd2M5sXiptjaFX93uyGNGDyvZd7mtyy5cLD2qcKPo/V2TY1Uu4GtbHHfVPre
#eq6sOV7f+vMe3e/G9l97HYriM1hE/M0OKBZQ40g/qL4Oaxmv5+NV68op2RHxe879rr1eVfhdHQVXlRK7DLeaVLguD+bgoKeG25P+
#QKaPlD8oC+N7aB5ILyi6q3KXe9/vkcJVV9pg086wbiWlpLrHIH++SsFOLYtrq1IUIfTxfFqGyvHr6UIsJsJquHWeqqt7Av2Kdsfd
#tbJbRUvbo+2zLDbQT9gK15PI8ND+H/vp3v8rf//4/WdPCNQGBuf8v70H8leeBfn5/5vff74s/+P3n7l5gQoKDf//bUD+7e//5b//
#/G/0t4Q6uEA4XBygHI7u/zf2+J9//5uPh5+b/z/oz8/PxfP///3v/yf+OFlxaFhpLinu6E7jycvBw8GNbAJZs9DwcPFw0Sh7ODtY
#QmkULeFQBwgc2aUNcYZYukNsaDygNhA4DcIeQqOmpEvj7GCN/Kn43+s5unNYw1yAKicODq2tB9Qa4QCDgqBgCIsvHczKEWKNoBMX
#R/i4QmC2NBBvVxgc4c7ERIdc09YBCrGho/3V6QKz8XCGSF5+OH4OFYeAWETofi37Z6XL2UxMl18OSxcbycsiCMIiAuW4gAw51x+E
#sHdwB/+GCwDKwx1C446AOwCAiXoCTAEV9/VwtbFEQESgHs7OYCuInQP0sugMg7nK/Kla21tC7SD/peHvsizMxdUZ8msp5Px/tlj/
#l34RbrCNAxxyAZ0I3eWP7tOBLT0QMFdnSx8RWi4wAjiKM3AyDVtbdwhChMsfDBH3tfGAW15M4Ybwgm0gyKFcYECu5X4VLd0doHYi
#dEgKangg5J0t3QHRB3GDaTj4WejAcBhAAORSCHETOgTcEuruDCDAkA78p2L0d8UYqMBhgPqA/C4Y/i4Z/S4hh7lbWzpDfn0NfxWM
#fhUuhjhBvH5+DH9+kf2uELi7KxITnsj5LpYAjbx/F3ht6MzAcHFfWR0dEV9/sLsrHDifO1D0F/1FXBpLJNuBESy+cAjCAw6lUbNE
#2CMVHOiyYOl9wZbAAP/fU2CXnPpzApTDAeBLbw1bgIsk2Ln/DPP4j2GANnX2AV0QEcLij+QiB3FfSzhc5I8A/B4tDYdb+nA4uF98
#gXZ/MCAW/zYQBtK4kBcOVwCbMCSjcyBgOgjkQTkA1DkDQ8F0l0PogFVcEfb/tooDB7A8UGdignLYW7preEE14TAAtQgfEB2wqqWz
#KgRqh7BHruDuafdvKwBrQAF1CbVGCpqOvqK8M8QFAkX4gx2grv/L8Xd01VSVoK5Ilvs5ywbm8q+zOKAwG4gucEo/PwcOAJQL1ACC
#+S+D6dwvsPBH/KH+YFuo9b+N/K+qAhiLZPZ/AcET5mBDwyUuLg4MgTo4/zs2gblA3c8PSezLofYQ738ZygkypzfhYheWZlcw8xXw
#Z2Dx+7uBF2jgdOBAQNwRF+eE21n92xrmQDvnn1H27v8GFKc50P7XKGvYfwM6AOgF6A4cwLI/S8DUi0lOEJ8/k36LDO1/4RkEwEi0
#kH9rpQMsqh0E4Q5ocHEEUAVWtIVbukAuG/6WS2skVEghgYhzmoJAJuYsZmwspiycgJKHIPtEf0IMkYSYcJtxuLs6OyBAgOSzADLr
#CvqXo7lawt0hCs4wywsEsIiYmP0RVfdLUUVuhxBHrg6GiVuCLumIMOEyY5HkFkF+wRzcYG4uLhawx1/d3MhuLi4RZOn3APe/BvBc
#DBBBFn732/7Vzwv0I7t5/3Q7i1+oH3c3OALkwQljAduIu3OCeFj/amWFsbCAXcVtxLglnf9q52a3YbVhAbS5pzg32P6iG2TD6sxu
#y8LpKsJuy+b8B8V2v1CMEAewyArlBOyCCPQXYhEXcy8WBuwqiB3BCizDwgryvNzMGuYOcmVFsLDZ/9wcUJnIOosIyBNoQ7Cw/j3V
#mQV8ITN+ftzIjyRgg9gR/r9J+JdK+UV0OMdPdW0CNRN1QCrXX6NFbWFw0CXYXGBLcS5RURagH7muHQjBJs7NKcDC4gu0sLFZSohz
#C7BYwSGWTv4QZ8CEI0cjZ8LEEawg5EBW4Mi/Dvz3juIwMMz/D3/Y/qsCYGICQcW5kcT8BTzkn2bEGuLgDLIEQcDcEHYBMDcLK5QF
#uS3Afhfq3xlsAxDwP04OrMgNGGtuThCUnZvlD7EQ/7Am3Oy8rBA2XlboHxjh/xgAdLML/N1t+dcR/jHvwpqBYb86QSAECFllhbLB
#LwrIEnAG5Pc/bNufScCKv2YBo3lY4b+WQE78ReY/mgMMB1uCHS6IxCWG1AMIMXFuJiagbMnEZAmUL1FhLQ6FeNFciCwvzy9LiOQF
#BKAs4H5+lsDHgeUXN7gDtHUXg4qysbmzWJu4AyQEubMClh1s+VtX/ItWQACEhAObAh8HgCv/g0lhICTlAXAdWP7BDXAW31/bOgBM
#6A6Imq04QC9RdwAkWyYm5P5i4vALWBzYxCEXTOcs7sAGgrNbm7Czu5uxcIKAQWzcZuzIsSwAoDbiHiDnf4BrIyHOwcXFLfm3gwwM
#+GtzJD9bivEB+1heoswBWORyDBJPyNM4/JEbCLs4CPazmx0KmJbfAugPgoMv977AgI3k38bhclOg7/e2HmAHsDWwNcgDQLKDOIQN
#hGCHsHDyXIwCVpbgkkSIO4hAxB3AF3JgaeUO8mCRAKRAkImJjc1ajJtL9PcpHZCbO4Ad2C5p5e/vD2IBlBfIWdwX6cFawv/WDf89
#IaHARACHvjrAnP+9GdzsvxUZ9FJZaSpx8gAAgGUd4Nb/R2v81LwA8yOny1haO/1vAg3ICwiQRvaLbWUAB9v6fwX8LxoA2BLnE4WK
#gUCQS1vhCvMC8YDZ2QEVDCgOTm7uPyjm5vw9gg/MC4xgF+TgF+DhZ/3dDELqCx6AhDzsUPAFMD+9/3/wAcBj/6H8AEr9agECKwAU
#IFIQvdTNSMcaac0A8RFH6kDAtPH8T5L4H6IHGI2/jsXNxXqhD1n+GBtknR3+2yhqKv3sQwYxgJIF0MD6Vx8nHMlZYBM6LQ9LG8BN
#kPWwcrAGvkAVjrj4OkCRX3kghKQz4wCwLG9pbQ/65+ltkJbhf4uwv0EH5rEh8enPAv7pqAMujzvIhuVftvhl+pDbiDqbXMRhSlA6
#NmBTCPhnHYjLLhr+AgzxXwGB/8WgkIshAHciMQD+vez/6UJwMQ5+yZ9rAQoeYBWR32uzAw1sSO75swGw/E/Q/482AP0FL3IX5Dag
#P7sCHMDGfbEPgE/nv6yj/SWBAJ3nwAE4+QAuf6k96E92hP5yEUF0LEhPDi7uaYIwA/yHC2fS3csBAdACANAaAJ7u0hGgE/m5xqV7
#KHrRZY1kHBnIPQcI/He/B8gVqbYvpyIgru5/9dgie2wgtpYezog/rfALTfdPTwwB9/mFCxuYtQcyEOJw84DAfXQgzgDjwODSF+Gc
#v7UlEtTfvPbXMi6XWPjjH0E5nC8CN6QIwu0ulnT/2SQhziP5uw3wXEUuBRlAiIkZ4P1yicLEEKIwNjakbwUDgjWan+zpIQ41gZmJ
#Qi6jSzjYAwwDIwNHSw5XD3d7QM3/MiqWf+Dy+UcIB4fYeFhD/kO0fvdaw6DAAQEyApEx4DxI+iCTM4ATATYx+ysEt/pHzIIcCmUB
#lAYwDYj6LgJZQDvZXcZgLOB/BJvqQASp6uCOAHr+MwaVhTk7X2ZVJE2AkAKZtfoVRIsAMvnX/mr/AbU7zAXyb0EHFKkY/f+a6P1H
#zH39/3iylwiGABwJoBdh9ju4+TPR6+8QBbnK78nwy8kIEzigJ/4z6IKzAPER3EwECvzz27P/s6rT/7wq5HLVnwEtUPyfV9P4B1Uu
#40dJEEKcEygCMZypDRvY1J3VxNTG7E8BGdPZXQZ1EHFAbCXpgMGWIDo2ZDjFRgd4zXQiEJFfcakkCC6O5CBXZ0uAhTjN6SVBJpbs
#tsBCLP+1wMDpAP6byy59p1+oZYOwIYD/4GxwQJdYiv+9li+PP8t/VwYWvYQWzgL+BepFaKkERYAskSEgEHIAcP+jledfW3l/tQJn
#ZBH5FWZL/heDcOl+iXMC/ZdYZEFiDwSgjwPAH+M/Kn+wieR95BTL/+Wcvyt/zwfUwH+cjIuFk1eAC4h+/+NsQDsQtoIdxP/jdD/b
#rcUtTfjMANv+R2G7/0faDSHGBcgsMnxjASMkuJFl9ouyGBCmSULZBFhBEMCzZEWIIC4MEfDh4eQFOi6bQUAF8GtYBUSg/peOrwcL
#RBwhDhd3EEVGfheItBV3QM51AGIwNg8A4Wwe7A6sHkCszcPqwG4rChF3BxxwWzCMjZuTF9j5VxXpwPwssiN7fiq4X8Tn4ecHQjEk
#aZElxO8S/KJkzUbHQuePVCCX+lX0L4r+ERzZv5IdJmzsZpKmNqymHMC/bCBJEVMOJPkkgZIJRN7sZzeygdHP1dvPFeEHcfGDA/87
#QP2sXfxcXPwg3n7W9n6u1n6eXn6e9n6eLkCPp4ult58NxM4PbmnjhwSfRZLhTy7lH/E1QOk/kGn+Q9H9Mq6SQKjLcZnKAUM4HGzA
#yKwjwtKZReSvGFHpP3QkMFgagYA7WHkgkBn3PwPlfvECAIYayAQBpgMAReaHLzy1C1ybgWWRIeifWOYy+oFzyOromACCfJEioL3U
#U5a/h1n+DPZ/m1NrOMQSAfmZZQRBgSPYqVu6QJD5HCgHwLtAK9I8INOgf2pASPdrAcm/20V+L2sFs/ER9UAmeCFQG1l7B2cbEMA1
#MMAW+ThDADfQ3QF5TnE6IA6COXsg8+G/+rwcbBD24oCMsCFEL0NeoMwJ44Bd5O0NkL3AwgB1YZ6QXwuLXka71qx/ZbQgvz3rPygR
#dwe7/0GyzF9IhlxYjEsQLvkODliO31oVqe7uIfWoNLsxEKjagekYuNkZeOhYACKrwrwgcFnA0QEhlebPNUwggHAD5EXeWwDHs9FB
#NgJsgiT5L0ukb+nsAQGUpp8fHRfdb9shiaS9JQCWiOVffozufzCdDczlwqYDBHaAul6ad6AMdXAGXTIZy590MEA7ABzAjFj+4jU6
#kT8rqIEAhgU6Ly4pAFPn8nfnX620F/HMBc6A0dbugEeHzOXSiiMXl/x1R/VTpv8ALo+U4wsn9HLNf4ZrP7HF8XsbABd0gHLhBJl6
#AZr3MsnJeqGCkbiFeAFhhKsoMhV2IacIFlEWSw6ALUBIEQVDkHlF0d/O1h8gFP7YugspASOjdMivSxZkKpOLDQQDWQJBxZ/LGjok
#Yf6+TAEcF0tJOldvOhFg6O+LHGDURfXiNgbADFJQf2KBBVD/8j+JDvCjn5/HbyojtfmfUwMeKOB+XR4E7AAo2n90AVGnOCCQ8AvO
#cAAOIeLw52jSf47202O/ZJWfbvtfVP259SUu4ACD/fTe3f/45r8k4rLnL3b52X/JWv/pu0MvmJ3rL3yr/+1DcZqDTFnF/UzZxP3Y
#xVn+oWFpEf+MSeDishdGGulz/0OUf9ndn8nq34J5kYGmo2P5E64ADcjs9OXp2X5DbskGY4NfHov9TyP770bWP42sQONfZ9H5K46y
#hjn/FUdp/DwFp6k74CH8vEf4zyBL9iJbJo7Uk+4eVkhXnAv8KwZhR/wssPzJMUMk4WwQEfif/VX/Ifl/ciu/42kIhzc7lMMbzMPC
#9lebD9DmA7T9ZVQc/zNZAqhuGBDjuwPwXaaNLcUQHFAPFysIXMNWCQFxcRe1BMId35/5YSQbI1sBcyJqKYF0TuBs4qqXGVEwRBz2
#K8z5C3i3n9J/Yep0/1ybsfxtAv9qB/0m5G9L9E8N+5Ow1g5wa+c/fAkTh4J/JzZYlUAwQDrpfnIx/EIt/RzIA3QCegRMd2Fl6FjY
#LhrAdPYQBzt7xK8pyCTb7ymqIF9vESWkkw2m8+amYwH7IGtgOh9u5N3fZR/Qw/NXD1D2/7mUK8zZ5x/LIYnwp8sOBv3dgxC/cPd/
#0cQRYHs2VdAfrP8HadiRruDvTi6Wy/vTn34UGPaHBnf+FkaIn5+vP5IfOSDOfn7/mkX7h90XvTQiEMAW/Cz91QloX4j43w1/gjQk
#1yOdEQA+ZA7PxgFqJ+vsAAzTBsgBQsrzBao8HSBeMjBvuovro0vTj3SNOS7pAXYH4Pw5xM8PBJOE/cpY0ADRgQkXGPC7wda/Vb4v
#xFkEDv45XsQdDPwPqAJOboAuyHAeKHiJeIDtRazBngZAC+Cle94Bvrxmf0m7/i+f4K9LBMRfSb4LxS3OxfJTXQFOhYQ4tyTwEeES
#/c3TEOcLM4+kozTiJ2PDL+ljKQ6QAxgA6AAAm0g8wEHIw8NBSHo6AF/gYw2oC24RAB+clhyeBkgsXFTtkdU7fwTE9acf8VMmvH9x
#EggGaARLDm8WVutLTvP5q8cH6PFhYXX/qeKhdn+JEbcQ18+EIcISygPoOx92D0CJOADLeQDLcf4UsL/QxfAPRf+/7acD1hwurgNs
#4Iqwv/CdOf66UhdBLslG98sj8oXBHewcoJZI2l4KgLsInMPF8jI5JfmneHHLqX4xAskcZuDL2253kV8ZED8/QLn+5CDExW3nn4MY
#/BWnA26KpA/oTw7lYmErFhFk7I6c9h8R9J+A7fezByjLfyY5DP+EMwZ/X9X+x9Xsn9V8L2MJABkONiII8AV+RCC/kld/3AMRX6Tr
#IIJ0M5ApwD87Gv0zjwG5NFXml3m8n9fegBa4eODCcuGO/HoMA4R2vzsAnvyJh19e8S/jJcpzeU9E+/OlxMWdMFQcGAV4tUDQI3IZ
#GUF+Lwvg/+9N/nRw/paNv/JWyITvL4v8L0i6hOXPIw3aP7wk8huE3/cpF0EQnOPigQ/yrD+LgFxxATi9bAb/GvXr+c/lwF81ceS1
#mOUvww2IPMefZ0KAgff/by/ZnS4A/psyxn9TxgSZd4Vw/L71/51tskRGJPCLGwQn0L8raheQDwj63+37d24debv/153s3ykpoP+i
#+3+Rg/zzoAeZlYBeZjYBvwx6kYUEfIkLq/J3DvuSosjcmCjCxNJM/L8C+t/l/C6BAmQbQLklEgEcFwS9SAOyiPxLRhCww5feyy/5
#uHBb4KA/94YIf2RyCoL0U34ubwmQF3F5DF8ogHgRIOTygkCg7iJGQDBhaQZGIuVfEnqKfxHvj8a/nPrPE/7GwX/cF12Q/a9Tw/9K
#JVuKa14kFZFe9qUwIOFEXgABbst/ysFv8lxmJAAS/zw+gDNgNFIgwRfJSkv/3xrqt/j95U7/aUV6FJeS8c/uSwFBIhF84YtbXlIE
#sFuXQMJYJGHIhDkMMF2yIA/kWw/pP+kQKAcSwWBr5FxbQOaA6AYI539pdXew89+rcJmJ2IJtgFWcAX0hC3JHPuiw9vOz+acseyCF
#00PcFnAyOGzhMBdxBpAz2BVZQ8CAsjrIA+zMctmAfLGKuNgVgnyrB7QAX/Gf7WyWl4dDfn/igM3yt2Qjx16oQXF70K8i2PIvbFly
#OLhrAkZR/FL7wP606F4cXQnq7mAD0dFXFP/V/seNukTO5QxZmDMMqc2Q8cXlgX7j568BSLJyXDw5vEgDiluCLf0vNaeWuC8Qxon8
#N3bpT0pCHAFIyq+o7n8Y/o+0FFJ7gS/D+/92ys+1f5ulf70rB+wP/O9AF4GMGgAbchHh+vlZ/go0kKb/cty/3znC2AC/iw5ExwZl
#o2OhofNnAf+XNAIQjPz9cure5USkEf7XS8Z/KKDf+R9NEFLXgKGXaZ2fzAwDWBOO9NikgbgBcXHTA7ht6iAdQDZgSI71AJSMB9KH
#00UOYBHVMrE2uxjqAID5x26DablY/mGvLf6hcf9H1f4fXgPkv94h/qVpdEHQP3lJpCBevhf5dUhFgBCXvroJ/Ld1+6VbfZFv/wDv
#45enKXK5Ahj5LhjwEa2cASv7S23Cwb8f015I0M/ntHBAoi9l7M+72j8ShnzacKm7/t1A0f56OPg3prT/Pt5f93n/+jryn89+Jf+z
#Afl41xKpjX/7Gr81JELy13vXn+9UkVXwf0sUpN/CBv09HTiPyB8XB2z52+P49Zr2/2jRC1xdrvhLMf32SyT/wMz+/wvE7NA/ZLnY
#6o8avFAyyj9fiqkgfRa9//JI64+0QZDc9du6iav8otCljYaL/pJzFcDMisKA8NHDHWIjCVK5cM0BF8QSDKg3ODs7iwgQryAcrJ1A
#SDUJWHR/qLilBJckHOLmAXiv0hdMCGyogHSckHeiP3OPPy8j/uVt/K/0NBPT70S1pY2NvCdQQN5/QqAQOAiISd0drByAIMHn8jE6
#3d/P3iHINI47MqltYA+Byv1c5Y6DjQ3k4v0HMAZwgq2RN6jO/wEgFDiPyr+qn9/MagH7vaT+byhAAPOD9UAsLMjvX6BA/fyQ2zEx
#/U8w+fnRgn4RQIIL6YJDxf87/LEg3xn9ISP0z3sOWtp/wZz9xQZ/xBIC/ZdI2df/Z6iMvEAHtCbyRgx5+4V8IYZMH//ZzvaPS+gF
#eJv/H/audbltI1n/11OMeWod0gKpi2UnJZlWKbKTOLZsbaTEm2RTKhAYkliCAI2LKEZS3ue8xnmy01/3zGBAKd5TWznJH2svBOba
#09PT/XXPDJwvB6dkB5MSWw96qczLfXyjlhqolg1ozpNyquOhDnRzqDC4DKbBJFgFo+Bk2I2H2DxOhxXgxZJUYIoDVj91F3iYDv/R
#TY3OJPwxGV50p8FlL1gNv+tOACpGw2+Dbzc3g1k3Dq7JPRsFETYiCp3BO2yUY7k/NW9EcLk/aTTkqtEMoiZX6zpy5S/Gg3H3xJuZ
#K3cw8mTgbj0cdMK00kWGmPQDOY3k5Q7tnQhkHdqX/U6hL8mh1p1ecDIwz/HwQfMcFB+XWFenqeKran/7uylxeOIpHX9/7JgGJnLy
#joiP6gKBpXNS2HxIFHK+0Dru3dmLIxnRBCo0+Vp9vabhe63tN9992iYMdTJoJojDYsaB0J6eqgjdYMdg0MwsSXFuQD8Jc+IMJ0l1
#Qvb+ICLul+SfJfcdhM2esW69xaGbm5uyOWCAE9BZvxRoSr8iErRUGsi51TwDN5dvw7fdMTYwSoNP6Q0nowGxTfyDJLwU2EgiTvI5
#lVwTS7HKeTI0p11WpKVXz6YHKxv5Hdmcq1bFn1e/BEtKYbTapN3cbB+MKFng7uEP3dL4Cumjq6C8Hx339peb6aPuVX9JyxGcaxDv
#6vku6ayRnOfjQXRHjxa9rQXBhUtx30aCgWfD2E4e4ZtZ73oyjInBjrnvaFzvns0O3mFc8c/vfmG9dEyF3m3u/BKcDi+RJhw9haKc
#bA6PD083j/dPNxFvvJXz0sQntPr3n2n+yaj80q0dMnQBOdIztQf1sO9pZJm3/IaTQG9u3rZ2e3vXJz9nvzx8SEtvEZbl+ZTGOiFv
#Aam09lubllZNNquIBVmkJR3q/kljuuMh71KcgLZJoUscwo+39COcQdiWg/VuXZ5ShVEYESOftRZfQPPgL37sSa/X6TXLKjrQ/f5B
#D0uzwL4jnzZQ3gn1g+pZdFDRNEgRcupvu3EvoKGP9CQkxdXqnTcaTNbwwXbwotvhu2WdHlcxl8t+r5rLNlXdXTRUj/mk9TapxFbV
#hw9fdYkv3fj5MF1rFZugZFIRDn+F8Ef8HBbxWXoIdWXvtYVkddvv6Nwm2JtspGZ3QJF3HQ40uRRSya+ILb39Vks8qDsNNa2b7ryW
#bTE03hoLJIFkQCPZMJ4qyR0+6jx7zudXYbIx2/OQzGo2IQkVfnkp3ku/7xc+7ObDxHK9oSNoTctO4Bmu4dA3aQ8fkqUj1HRiMKIZ
#qB23cNnnwt2uwIbmbX11dQyq6JDbJ6AD2qdLMIvWHP5uPdtFtuTuzQTfALcax8Da7AbtbhXyizeokWXGGm/uzGtrxDv3S9XdFe0n
#xkNn9XGw2J+wofROhhDtCqQ58Fb2sHD2EUu8KUTrXDhEALJRDrGTFrR6c9Oe6EwCW5LZa4kRYatX3Xvxwj55zUTxvUB5eEw5rVny
#PWqJAQQnqA6nouUuJsSHHFtMw6QXfNntJpvduo+LHg3m4LZ1u9qXXWhXzuPJ9OXDn1/CNVwG/to9RWRR2xkUTjAvPSHZCV6LuTvp
#oTl2CG6bSfWbveKKnph4cM5QQu1zWKxFjNcpEWoL4pxN27XOutjCCE5sS6aSvWwL+qUBYrazW1W2fhLXBWsrliVkky3wQJYNkTG4
#E9ewItfQu9/TCnToNpTTjQRXsmnQhNYbOQ7Rt8F5BcK+Dc5DO1K17pE9lwo3N7lr1yUVvud6W3np9knLPHadQqHamBFG5nyLvBNY
#URvuBB/z6CBPlF/UGa/Y1/xyd5aaVcuTVTk3XNhNrNPBa7a9aIDYPDzibunhVzxEeUYEVqdXwxd4XSDKeV94yW6uHeKkEaK3GXh/
#c0PQ4vdvNly7gBK1lO5XfIX2G7j5/j7gB0p41C1wXpJvKgh5L8JyKmfBWuOVsX7w9tbW4pi4/JrPdD+m+iFuTnWgDrQ0W4WTiS7W
#B9i+x2FdWUiaU/qk1Oxlc4icYPDDadc+9uSKekh5kyKJyQsmMb1KSpIzzdAZh12iYWecFCVu+A9rciE6Ec22LuR1POwgPiovqdsi
#I2SXHvpnYhDu32/d6CTgv1Zk5xe5BnncTQ/xti+HbSZEC+sDetmkrBhbWnP4CnAG7oktmptqkeCDXlDyQzfBLZtdsp78irfgwdwe
#cXESOaU2p8+SgymAOLUSWjejPOxi04Ib2a//hmfy1Tl1x6SyGzAmg1F06y3Z4bgajvpTKbwcnvS9ElNTYubdHL16dLW5fLTsHXSu
#wNGcKJ0N+1e9oLPy3skPmYu2nfUE9pvX5u5Wf0pu+Wp4X8BtTquc2pkP5x+JvG2teo/g2ge+Ma4+Xi0/zJ5tH/Z3HmX75Dc7WlZ9
#3t+zqmWCKewu+nFva7Uf0wryfCdaSo/mAOW8qDYvZVVZh7m9oNr3mjzpz7xF5u0okTuNaJq3CRi4kP5rt4FYIXZeeejCKnO+3Zy1
#IdT2bf68v/PwoQsN5sFOo8bleqPVzAclyVPUrXF38EC86RmRsOT4NlWyAZ2he7q5sZHx0txGbEZD5a09g+0de5GUqnmm9HawYWjP
#2x6m+2/JHKS9IGK1JtGJ9eJCaAyWjnsHEbygWgQtlqzF8LtuHbTYLdtzxturmjjwonH6/G0+z0cUGrZBjbXalWe1K2u1sZHDcmE3
#v9gA6CwjDXnJ5iYkqDy/H2Z560/kjst2e3xYfXOn19vM0DZJ01/9MZf/4K/1/Z9k54vsD//603/y/afdJ3t7n77/9Gf83Z1/jc8+
#5dkf2MfHv/+0u72zt/79p73tvcefvv/0Z/xdbyjVuSD139lXnbQqOgESsvByUM6SBRLP6FdVuSL4XGlcn3UFkgnhdS5CT4oeXRYQ
#6SgPixi5L9xLU7XS4Zxr4kERdh4n+DaQzU/zSV5XKPAmnyg8NllhNqnDieZM+8y5Y5ohspwT7AKozv/8tzo+23378h/fnw3UMUEF
#gp99fDNnptWuSkoVqqoIY/LPi5nKx+qHML3UVLBY5GJdBup8SsXKpNIonuWVCsdEZkLOfqyWSTWVOgOv93ke6xK9fx3OtZK3Jvdf
#ubDrm3wJhvJrkzsOPyDzq6O/S+KILGuV8jhpIKrUBYEqhUMENr+s50T9CiWuF7cKto5gl8ozmGMVRkVeluq6vDV1y4H6kpxktSAL
#qK5Ht2peDmxTWZ5xT29zW1iFhbZNFTi6ShxYEienOpopRGBwsCCkMfLOmSNJh0U05ZnlJzVaKeyvq7xQBAHbxWguRzr1CpuubSnw
#bxCmXOKIfkzymFh1yawKL/OCpqf0cgrN4/gmLBWeVZnmlcsv84IgAfJPcjBCGNbK5QnCIe1WKkhHLW8ESG7op7d16m3rlL2lrglQ
#3653aOXhWycIkiYN2RzTri0Q5Que8WP8emnRPLbJtFRJMLLYy060zaWngTol94ukmg+H4PNtEDBa32WeatX9ref42eaz4mNlt43M
#EOaq06olN4rPruoSzSJGniA+1shZlNJMMyV4sNk2V88XFQ/unGgy7dHS42QIL9PKfqVdP67hZVjMa56k9/JkZQjkyNzhwaRiFXnC
#15q3WFdhkq7lKkk1hWJ/ck/9SY3viErMYiwyF+t2/aa6TZ8h6bV9E/Xp6vBtdaqBX5MWVTKtot7OdVHQTJWVo4az7ybjAhAPDheB
#SNs1Dc5pUpGzeZ2RgsCL7elSujpXl6U6d6lpXoqKwkObS9MEt+aKfCklzFOTZSU5EpElMB5VbdHlYkYIx0YIvZxG2ZgnzmKtEetx
#XYoheGEem8xpjuiI6Anz2GSS9JRFGHHuET2r7/DS5E/qbAL1ACVf47OIcz83nkuX5CfMG4HjrF+5zk/5fJRo9bKMwoVfsayLMc8I
#fpvk0TRncfoSv03y7FeWk598updc8Oj9qZ+YMD1H9NMkkpPDq7rOvMSclhbL4zt+4IxwRJbXs0LrRtRaCvJeFTz+FSs4PrfmN0Ar
#PTZWjM2xGN80IXOLdQjji1mvs6RaqcbUkbk6IwU+JWNJErFy5q2xS4GK2BpBK7BRI8HhF7NHAYsTcCJUBXQdWTkVkds9g3HXyuzx
#KgRzYesXJAqq0GQ4yqmCG4mYKb4NsApUmatVXqswXdIQqTvqN7Q6qpqGFY8qqmqUxkPikEHasNAAJUEPIQ071s9GxXNEzZhwX9Wn
#jnGkXBFDWOZFzKPJciW4iWASqUD1tSZogrH14Ytzq8o1mWR9yCuximhkBq0WrPppmhsKyx1RFWxwwG2alLwu2jaNizFFR1QCYhNw
#WWLzQP1IzPkXgWmVaYJHpJ5H2i5qsjiugV2jkkDEs3IRZjQfNLbhPzuzf3aeP5joipmyhaznYBXo9mrHa+YB1+YSMjeGo0/7VJ6W
#L8kp8yGAqKwUH4Ai21bxJDpqfFuqbN+us8dC6ksIvYgVGAu2eUWYHow9BW+J3hXYli8z5TCw0MbpLPRwtuoy4N+Sp8TYTEeXMz4/
#opJPFEYnFMc8pWaopKxtiVF1F5KjHi0UYz+OzTM3PBg0c0NVBCac8ZNXPZ+5TsMo0gtMqXqvU1q3xGKBBQ9s4XEiWPJIGEZiO8MS
#izSPVV8tElpfhKVB+BM1T7KaIJwIUBTiE34Gm1R57mgjCzZIssswTYwAhJW0npTZZ5XiDGDMKeE+6YEIZCGz02qhjpEbXg5QXKHC
#WSxaPK2+Ml1ZQSNB1Cl1VqcxOwEjqIiQGIoeSOeFk9DhEKlcYDsQtfNcVFdYVcAwNMj3YYK1KoOW5XhvE2kezVpNLIscCs415HrG
#uAjjl75Q/xu057HAzb0usXPjZM68K53FaMHqLenRrDXwjUXImOTBVKdpzhBMJIPdhKCFGqe4MtoSMW91WLqcvJOHgFvK8PSaheNn
#DeoFj/R73uIvjRV6Qi2R6oldUV5pzdj4zWSxVeE23mNls443aaaEWZyuun232QYwvcnD2ANMU4LHVWIZ+hm1DNlhl8lqrsap+gY9
#k/1Y0ox8Zh24/aYhq4X/Dw5aa1xkQ3NGFaTN7/FAiDGRoZ5g3b5FddMBMcEQblNgQIVN8qSul1OduUlNsjbOxkDtwQBb5n6EXg5k
#nwiAhIF9qXVms9i+iaNPOfJms0KpxDl5w1abD0vICwgW0Z9QybJiaJxkMtptU1f6037iz7gh2JEmVLdoawrYbjiSQP9lMR/frSHT
#yPBLJpSm0uY1rjmlr3Rl05eyXIHT3zcME64g8Y1NjItwaRONM7Fw/MOv4U9rTheOg9U6BxfipFphKG2qp0O4VftusheRJe1vQBfM
#Cu7D5DvnD3CHuuNMUrUkoqSDMHIj3POm6FfmYKzzOkvAxXrBVtqYGPEZszBVvGHkGuG30jLGvJk8nOJr9AW9qC7p2J7NXnJvzvSb
#V8GQPuwfzOKQgbraUi/of0euAWHTe8uduZu5N7mN78zdxL3Ar6VMPLa88Ny3vLC597uV85ZbOW+5lfMBU+goi+eMEV6E88YtGswv
#xaf94dSRYRXHWeRUHvZFxzyILh4Mt6oBZBmywuDQynWFCwOW+XM2LbnNmRLXbdbUz4jDlU2PgcK9rJUmG1eYAs0L59aDuak2twlT
#SZneTkkxNskp9BVlyIftd0y6ptkRJH5GVo1mmSzxEv6FGOXlNCFoiSL4HrcNI0isyUAuXPc3kTffm99dd+dxike0VjRjFGHS64Vd
#jd8vmjUj7lVkoDvOS2nyNGApPS9qrehCnHWC3Emknlw+USNySJVxl1mRsuvSj+uKgX1JmJWcvZOkgG8EwPIqG+siywMx3OU8z4EG
#KGNBazXBeVIy9xDEQatrA/zf02gJ0NxL3a5Q9xWUx+7lrlvU+JLUHCoa9AzUkZrkeUxrmiaAFBabbEb50/BSs4s3LhICLkzUOCEl
#QIUszGx1aBA+fO57CXosBJ2l0AAxQH0RzhdCEOowf8qa7B3BztdJVdYEI9WpjcOODR4pZwkRn9ILDUFrcb3giywA35MIkeJL7cVR
#Tfd7Ql4TTbiXyL2BM6rQfKxXye8nnErwlqaMaM5mpJ3YC2RLubu39TlN+VqrYKYBQGS2F+HSfjmvStem8onQ9Z2uwpk2U28Gch+B
#T4TA8wLYEeLGIfWCa5MbVFd81E3B7tULcYhAf1zr1Ph1hLdTBY93Ht6Zw6dCzD1xFVdgYSb5EktDfOIxu6WCx1JsmCOWEBJii9iv
#lW5bYYdcogcyQEMCRyCdc++F9anVZgl6ZXdkwfuxA+eo8/VAxZHk0Up5GgONkhPDhUZING419ii8tndlZaNx48XHJkyQL3RW3t0D
#gffTeMPcxmOmr9Bj5/FyTPhQnQLJqd/AMJYjnnR2K6QYHI31GJ7f8J6IaCI+F+rQ2sHAoDbB+xzhQ8EEIJnbb3TIOPxw726I2yxB
#gZ3BBzsNca5e3Z2IQ79suMauXOIe1gcJTaxFOLjkBRzWGa2WO3xEMTt08NN5smFaYttssbK89LkT8LRwTgzNgNNjLgZvHDVmdRdP
#v6mZXvU8tieVx5rdtZET3IldXN+ubkg0y1kjWYd+E8yQd5YmmC9SVlktw5P58YSS1BxEE4BHh6QMafpZknkKJdRbYH49vw5hV8Os
#NEcFcg90FhCyI7dxCe8diSbOBv6VC+y5ibZvZF6FnJjiQprHg8fCg/fw6+McGxDGhoJAmd77ReGxjNyaXAzJxRxha0uFmRGP0nef
#a+Nz2okacPN1CRRaj/ro3pVBgDFfwCKQkVBP95g4co9LzYHFkAcmHl2hJ7i3B1YYg0qWbaT5Zg5XK71B79lBJxBM6n7i9h2Zg694
#ER36FcI1rBAoY5IDWuSixQMFixgoz/CwKa0z07Q1eS2lG5Ac43wnxAKfMmWa7vqqA/V9KVqDFa3ZAVKkrI1y5pgwSQ5DebbrSCXd
#y+4Tge3MF/0nwoEXEHuOPGLdRRHWKDeitTdn5aFfMRRnI2h6RQi4HpFOGKhzqeuieWvBOkVQn3A34sLtkG4rCrsvwdaPhaA4JNaO
#MOaZWacTeNEEu7zhPpXhHvPclsA785WyWyM+7Dv06/BIf0SQTfQ4E4FjD57jzCpvoNyeKk8ZemiimnZZg2a7RmX+fn/i5oPOxu1f
#fcjh09/v/t09/2MPWJR/2DGgj5//wRGgvfV//21ve+fT+Z8/4++a3NtMtjkmtICnHXW78VfT9Onvz/sz61+8msXq/6WPj67/nZ0n
#T7fXz//tPn769NP6/zP+/uvBVl0WW6MEBz8v1WJVTfPs8Uanw9v1+qomF1yPZBNs3zjDBpqQl+o2l3mrVXY3BX8EEsN1MMlucW5s
#nFWEH+BepcmoCIuVQIXuKfesHg++2OwR/FrmjCfw/Ypyn5DMI4PMlFLdUlc4slIO8A9BBuqb8/NTeA/4PeupfQYjRDSHGTYVCXiC
#f+WSmkgyvqyXqu7O7ueDbfrPzr5rzGZeoFU0wxUXaU1j3XoEYB9jyGic+fImyWZKslUX0FNw1dHpK/bVwMKNZI7G1OTXZBFgb3JK
#Y6aHeRjR/1cVYubgFpyAaKYr7AkXdUS/ML3ENAKSQJDEzZz+96HWNbG5gNOgo0JXpcDPMLUNuOY+pDT4x/RQIm9VAuQWmiOUAXs1
#gaqLlKgZmE9nbLD3Frl/G6FUhvYY+ZLLFEd5PsOGu8k+S3An75gTpZRpl2/p2FKUxu+B/ANtFx/KjY2j09OLF6++U0MaG1/GwiUE
#bBV27Xs4KvHbvbjA6dCLi15v4+z86PzV8Vo9OPpd01ygOgJmOr2NF0fnR01REu+kyPliWLfDB1EuTo/evnxzgWIdqreVL6qtqNzt
#s7BvkecWUiNnL8/PX739+uziq1dvXq53antAr1aOMHXo/Mt/V4O7GcQjKrzx4uVXR9+/OT+j4jiRiw0R4hvZ5S+2v9imsrQ+OQC9
#zVK7DXJb8kp5u58/2UZRktoLEkCUZh8AAeQct1AlRXWqtLyINNdx764Cvf4ve98CHddxHTbv7WIBLACSAMSvfo9LgXwLLBZ/fkCC
#EkiCJCQQoABQIgVCqyV2Qa64P+1bkKAgKJR/iWwrsfxJbdlxZcWJLSeOo0T17yit5ah2nTp11Eap7ciK1Di2Vdd2XafxL6V67515
#78377BKUpcQ9zUoczO/N3Jm5c++dmTt3SkASE8VSYRGjDiazMGy8GDG1aTQgqXJPULZOsZTi/SGKwB1TU9vY1d+YRPVL+zw00SJW
#9XSelMDjAdyl39GLzUXSkyiXUV2ij9pPusUJRy9oEVxVF0QPhJfD4f0TB0YSw2NHDw/vG5mGTo8M79sPY3Do8M23jB0ZP3rr5NT0
#sdtuP37ijt6+/oHtO3buigDqjQwfSUweh9ylNN1FhW7QS5E7T6aWenYs3wDDOD58ZCSxf2xkeNydaebkYnd358nFnvmTizvmZyHv
#2OhtI4mDkyNThyFv74Bm/baYp9e0pCws4G6HkYfOOUPKB2JT1zorh4WugWvxwvw8Lq/DR4aPJ/ZNHDgBpfYkgL/iPyC6EExl5sq6
#iWiIoBCHh4qIqmMT+2+BoEUk4pNjQFB0DiYi5bLm+m0RICQyKa1zrw0h1qLpHVokUTbMZlYsfXJ4ulLpmSIWS9QH901oJ6aMu+/0
#kbdIUWLCRNI5VNHAsiM5cXaCyEGTelCbmQUcCKfS88jK9JxxOjpIOAaUMm6UU6iBcR5XwXqkzdDajJP5iNam6fzguFyaRw8kHdTa
#pgGzNfw+6v5+PouXnqJWNclUwiQRuqjtdLZwCpjRFAV8Rgijy6ULPDP+aI8Btw11B1VC/AYkT+dhLuDtpshCeb5zZySKaDFvf021
#xPmWlL50dlA7R5uxZ2PgAR6G85QOuvT5aDyD9pj1qJaZ10jR2wRqmUOVXkQlIO0gIPd4oXwQz05HUMfUrgz71UkTSQFinoy2ADPF
#XSJhdB3RRCp0hP7QRp+hpV0lziXzWAwOuuYofRCGCQcpzcuamuEEdBZ6FQilboWjuzHNSTulTK4EHL4tWudr+dMQBXHnLzy1//DI
#kWEkPiAp7J8cwbkwPbwPeMboQW18YlobOT46BSwBJI+SoRNZ06ZHjk9rRydHjwxPntBuGTkR49r1FI2fjB8bGzMHS9u2LcaVDRKo
#VKGNjk+PHBqZtPJxsopH9Qku0IkMMdx4POeOo3xyOVYUESIRGd1drSVIqw2dNrm8DZEaaEFoty4mkRsLAP7SR8rbMi6tuaOtjum2
#wRwdPzBy3A/MBIdnYlxATcHqzRMMytDLhbNp4FMg7620nZVbYurLeVOAQmIp1dtiwmQ3x4JyBS1CGT5hfWB3vdwibfjY9MToOJRy
#ZGR8ukL7PIMnpQmNIm8CahF4EcuvlUWpfU6YKVqq/7Ll0KmMtxjzew7V5fCAMiPuSl/69Z0DwWk64bGYFJQnXPVKxQJrpYNUZTwW
#INY1fDZUdKk+Lc1B0hCsQFtISyRRtjPziDkp5nwGL+HaYa6HY4ePjY/eemxE7n8AL7qCrkiIg1udh3xbejmSQ8kWKHiKL0FGB+hS
#GFUqjLIdQT2QIj0aO1PuXNFwdYeD7BrpfDmRLCdQfcGKl8bRao0APlodn3NFe144e2UFkz95DjhVFc4zn+ZqT95+LZytQntjeJ4G
#HDtpUi9kf1xKSp2i6eeSjw7so1ABdfLOpmHxYEirjfQidHqicHZourQgeD8JtmIFHBfnhrpYjokrAwkDBjnBhcchvsTRMkYhSxf/
#EqSpMYSiMV8rgww+1DNgFh4vFc4n5pP4VuMFqaLJwnkzAz4HQ/Y5jk4OHwIOfzcsWFCmwAOvoduHxyLRSjmNC/m5M7BILSwYQ+MT
#k0d88hpzpUwRZBUSHmwZEbtn7gzUYLe0u7C9u9shWk1McSmNrhOETSmekzh+ieE8qoAQCSTVmrKl/2yUC8UiHq+V8AZFAdlrklQS
#MiWiVNrZPB6T8euAYUtYFUsLW4qTG33s6AHEPQel1UCy5YR/SIOljM6ZQ0zbPzE8NjK1f0QH0XdsZP+0RB4PTk4c4UKStqDdfnhk
#ckRb4DdMoQxH4Tw2arKcaFRk54xmihBVdLgb1gNQK8BKdVmw8q9NDr1HuxGkcB0lSVop0CohGo1FL18iiRiiOFMUqFCc1qnt3N4P
#K92oubaAjjdnjGlR3PWNyIiX7/LElvRzQOeGtvc7P7OXr6i3quPCGS3hnMPNNXyRiMwvFvXozGB+VhRZLiSwMiguNQQzO1sY6uzp
#bm/fFdPOZIbIJ6ogHD0nBO1zDqzUUU+fEDOmkTVB8kcHTbBSMoy55KKeLeDWWF4/k4Gli9QNpRyyTz0nqsThR/hzAn4T/DhqQJT0
#qPXkUuTkSdr/EUOP3+XMZ1kgcqazZ1YGoUTaw7iovzPZeW93567Eyc5ZLAD+5aBztvfPvg7LBvMknU5ZdVydltN5c0OSq6akS1Hq
#CdotE/lNzChCo2B949jCmfWuMHNlacPqdLpMa2e9aGMwLAghz+YhzbnQnhGr7FnnctNesBavYJFKjBPgkFekjgzuumlVj6u4mUVa
#0i7ikjWFsGYM8/VXfTFG62uuRCPH8x3BTAqX8oCd0dmqdYl2Io6UfZetdlssKisQxx9sc4cgcy6doJtnugESzqBNQ60tFLtk7B2M
#JtAxuzw+5iUxoApALFIztBMzq+3hn/A9J2eH+0002hnioEnyrAQbdrSBHe2HbgIUw+5bbWgINakJNhGNBUaivqDgvDVmeI5Z3jps
#s6uTwo4Wp/xLNRtnllaFOZWgCplEC1ZDEqGg/LZkL8i1JZkOEbkGsIAyx0k2gh7Uo3Kf6iUTCISaK1LYUWSVybxv3JbC3QxqZDh8
#dPRA4sjwUe9O2RbzVEQczIi9OOJ94NeFCBelEiptmQ33Tvnuwbm3+JYiZdqgJXBjtJeLf6wrJRizGFm2NRrxaAivs4BcQE9ca7ip
#gtVVBGUKlii+G4IuUMQdcNSzIRFAXIPRESe5rjQ1y9pf7RkI8zMEa1dwOZyArpN2CemCUHecNtsLKdw4PkU7x6fv5V5zw7CYSSUK
#80J+tmkrnunE8+nzIJ9wNDQ3oKPEffK0kR2NE/nDZzX5IElhcToUN84kewe2R/Ep5FTmND5pBCylZ7uEtuZY2ngr8GOmOEssDwqW
#sa4oIE/2GgkaB52fm5mibXd8h2gISOLDxllb9dC8gl820tl5TZ8COXYuzccSVmYHjkZJeQ1Y/SmygYl7enQ1w/zQKKPepLRHzTXA
#UODn8N0D8J6KnFycn5f/TYuKRvKncVRvxfpw/5x/ZWAb6bQrzv/oIjR8MDE6PjJtnoXFp6CPEgcOTQ4fEZuzcdoxpEbr4q/PJitm
#y6fKBR3AgwkdsY4KARvoaDDqIMMGiBFz5/SeflPWFjQpC0wvFdX2Dmm7OHWa6R8cmEUqeCoyHHESPblKrQOyDgzumr1M3Susf4+2
#HRFQ1L4Zax+N+JJcIvhWAVDydiuEhxDAXG3GiPMsQa85oaVWvd9FxO/GvWxuH03H4e3GA6uME3bUzeZv6eqpmczg3fikBs0FIRjQ
#oQ3JZ/gWJgF0N/RNjwRix5DWi6QBigFqZ7NdTpBAGAOWf6pQRoSBKqBDwcUiLF/vrJtLLHHqNojgof09TuV4EL+zqN0gSaLdMUs/
#vJOqigoqCMmLy5cRD9z9TpeUsg5MpJWWdYiAExgty5pMVhzZ5sV19/j8AhRoH81OE3U9WihkR4ihFUoCIOgPb5oOYCfwri40Zmgn
#Hyt+swVX1jZQjrmCv6xByGFUEghcYpjg/bS/7itwUTEx/obUvSCvQ/m4zCcLgtlk7lQqqS0OSsRs0drajyEs0ahXmERm642lMZiJ
#kHA0xOUl3zxEdE2uNYi+GRBNQKaZxe9KXuARcoBk0ORZnOzp4iO7kssceFDn4qEHtNV1vEEDQadR2XS6CPNPwhBfGdIC30G7INYp
#QZqykq8YaUqRNmMlicUrKJrttUCApgHhAWTTXQIckiYnzJZMh0c6JA4g1RYnRSRdcZDEChIAMLMVYWJQOgLkaE4hb/JuEpbcsiqw
#owlUQTFXWLQRgvscC8W4NiLxM4OzMhymhaKmn8skiVXask3UYm1AL2JcNEG6id6ywK7Lis0oJANZ58iymwpBI5ROMd9HGN6tITd1
#9qbMEPDczBzTsnaP61ywUheaP7T+lckv2BzismODv2LWyTcQrQY9E6aI3YEXDtLICywSC90GAtSQPef1TpjrtAuLaYum4Gyu56Mg
#KPXvnPVO9GLW5DRLkSIZEBBCXHGGawsQ7TApf9EsF3URuJkyiOLZIIrXT3EWKBG+F8xjhZ+YBb/+B5Hkm122e0Zif0sRgon6zwSC
#1j/yegZnik4mDpaWo56EeyokeFcTMV8SZ2qbuIhzRJgukqChmKjYUalQGGeZLmgx0g9YK95whU3tFS+sFgsmGUdCmCinW0SWXNXY
#q5TuymAv+oG9WAHsRRfYi2YVFN1doRJxJAIVAeBmYFaCm1RYxDGJnGvOnc2//Ew+YV7FJ4IrlsYzdgLhunUZ35lJRFOWUgGvoSD6
#ZivUJW6r4o6e6AXzzg3vg+39WA6wfrKmxAmGYDcmpZBVcxDLxOJJxJl4JuYNzhkkE7qTLCzKfNUk+QtlJ83HNZ1E8PeTAQ/t5qmJ
#cU3vQP28qHUzTSypJYN7g/w2EFqRAUkJ2QAZHUhrpxYy2ZR0P8ii/ygSSTuwJlMrAye1152Cpe7VeuLdNtVCSM3Nr9RCrmgAgbAN
#QLhZmKQwNTUjvES5MDP18TJyn2KyhPfEjSE9EkPRehC3c83Fp1W1DZqpJlI2hsoxAmkInZh2+t4h7C1SbcK7JDqPHog6ut8u6HXY
#CRU6l2l848ygMT4D6IuLe2wNwmNq84gzAEQsjOa4xSl+jHa0zXFBjmjqd4nXl+UFvtSypQjZwhFnRhGyrIZqZaPcOI1YDsQjXPin
#naMheePdhoNT6aiFLrYA6r85lfffnNo/cWx8Wm+PanPeowRqw9CN2vD4AetYYS8/VhDn4oiQeEok71jNROYiDpadx1Xsdt9FY6Xu
#sOzWcHCEkilZDeIWcObT5+072cvVjod4CXgsRM9G9Pi0jRK67WZJEohrpdrb7VoekDIKquBwNUahVxuHrkDj3A41wai7sO2u5bhn
#aeRu0ej41MjkNJ6NTki6MGIviJ88S0fzllZIVLtteOzYyJR+Y0z8F63AG8XPr1hxUiPNA7MefEZHc28t4O8UVH/WEStWLOaZ52i+
#nD5dypQvuJS/7M51CY0kr18RHtnWkfyRRO5SSVHKbLWt/iQpVLj7M4rH4/snxg+Oje6fFhNfOzChCQRE1MPShqD12QW0h5Q3jf55
#e97Z53a/OtuJS2qhuwoh/DMz2DerdWiRzgi4FNE3SHScNFvxtIu0W4WamqX0OhuNmhuTggiaipgOQkhLimoYEEO5owf+725v326R
#RfwOFnzdK6aCdonLPnTN3CqxlgSW8C8B5ZCiZmZx87NXFuoFtZZ2FIrmwQ584EvIS3rRS/o9dMCFqqYBJUtIN20WU3l+CweJyhcd
#JN5eSIghEMkUybse/u+rIJfiz1p1OAvgsVYJOHgkclnLEWd2Ee3OX7lWodLiKciM99Zs2oVx5uexPDedD/fzTwaqVS4WT86SKNJb
#rWWeyplbREdpJnYjt+sAbkeIUhYyJU4X2v/3DqKbVWN93VFrS9A3J61eYkLy5QsKz7SjpYPVhN6drk7wiPD2l1ZK1CvD27lEfNRd
#rr308FICkWSBtWvXrqhzIVLhmzn3R8467bWatStLx5FQ3rIt6/iccGLUDNAfOtGAMbIFOqIf9gS0iYiowSYtBvFq/hEdyw9qyXMJ
#vECuG4lqopbMYPaNHBodl5RCPEy+Ejfy1wKMEWcwVf1iK+VJlvqiH1/aPzw1glLRuObgUHv2btumTXuitZExyM594wdstUObvVnQ
#2SzTlWgZafP98QUejpq9lcJDOD1mvcKGewhXLkXJLJ96VmL4FqQxSVHZR5Z6Ndy/etc4VKM96ZZNmIo/ib/E5P2oMv1vb5PKvy20
#ICXVLdN4I65LeY8OUgJI/2jihxttdeREuYyb/8kYQr2r6hBU1dwCodwrossqVhRhofSevbQgKVNLrVb7N1Iwf59lUA9f/Tgh8oIh
#ndZ7wEIoPCBI6yL/E4RKmOmnhmxTAaGA5kDGqA8AXNEJIgUr45PH2TEoqBGN8wKIO8Kw4Odrm8iNEa2d9sx4dp/+fRVjXKVDeY/T
#IhzVQEfHNb3NiOJO5D0xbYZjMgq9AhznSsOzUnjt4RNo50U1uZr9E0eOjE5LDKDygZ7708mJsbF9w/tviUR3w4oxY6QrrARcEjwX
#W39R8X2BPvIVUhb4JyCkuAV9U4SGHCuW+U8lhU0UIfNLUn7xCiR81zFhUdbWWqFEX02154pY+tyCWxNIzOyJSW300PjE5Aif46bO
#vT2voeNiyDmFmnyMtONjQryKmSJTjGu9x7iyu5clrXCZb3LaBdoruJw46sUfDqMtv/UDeeA6mz65qSWYl9Zz7vzVwVyxwPmqhMwV
#VMf727HW8mYSJkAdNXlJLeAGaoDTSaCXQOX4rIM8yOwhX8bLSC8v7eDPH/smR46ODe+X0c/U6K+IRCtCJEClHL9U4FrcVlnUXmYx
#u6K16uWgWtkKdqXLU1dh3MapI9f2KwYJb3Q4y/C2vcr6FwQXQCpzdeu4AAIEkh/1/HJwp1I6WcRjVusMZUo+LzfvBxjCApi5DWUM
#cnlSXBUgqZMsQ1gsm18j4JcIrFvEdHZiHqb4qqHY2g893VVIedlXtaPSqtP8AWnM4rbwDCewpg4t3wHmUTiBSQVXuipblvVt90rq
#trJ+qsX+fNResOSywVetAIEXMH/mVmmIXyMRyagkjl+uG/EnpAvRW4P2wl46t3UqCVy+na/uYkZZPhdYqe4Nx3pJ/eb1UO3nJi+5
#rm54+DZhs4IUayB0K/jJ9Ef8VnRRUcvI3JseGkCNP0g/Csv40fFDuFFCWiYQNT09lphADdte5NF927u7zdiDw6NjGC9FH56YIsMT
#Qpri5jPwgA/lquRZoJKZMyl6EcG0rmA912Lmolhci4tH4ijeUko6lyAzHvKJmnlM67DgcRu/0sW7o0ODZUvxtFwK37mRSgECQV2C
#Rm7Fqy1oKoCeciHc2mYIA568c/mlpgwZ+stlDLqEDtOukLUPbqscBorDaLdgXEXorKBPLi7O0T05wlsx9M71qnyc5dYnt7THTfWs
#0kxElIo6Wppu4wBmnUFqLhTMJTzgwrVOF+pFFuwNMSYZAzWUdOfoRf2bby5BcZrbGOmb1UGh7bxcxYnqkFNvjRcXygloZTJTlpPF
#9OXT4uBCNutbZipjoFVD80OOSAk0Y5NAUrxQyqLRolxGUobeaSEorp2dNnLik/wv//BMOplCXcmlyDFA/M7h0/g4omS2pPMomTXp
#iXdHlqXNRleREKT7MaRsbAJhKicjUSp5FmIgf0LVOgGO6qywgCL/rD1TsoXC2YWie65MilsIHN0S1ApxF5MkvCjXKJ3iR1io88Lv
#QJI2mDVDzqZRPcHU1HBaW4m6rlqZyAFpVTRIHXd9DN0eoAj6jMEutMTE7+4VUdUrnUL60jVKgGLndx1Kl7nV7Sl6EjGTNrrO9Xbd
#iHoibcZW+jKTMoY4EUf1EfP6LO3pd3e7RSzSW9NTpjKKUQSmIpRaPBpFYhnrXicUs16+ZSrkZ2e6Z4WoSkMxDwjMy/Ek5dKpzAIJ
#1lKSGDQuiV8xSxPsppjR5pMww1Mu3VLH8KCusM94eLlAl3jD0+hqM7puXMxlh3pI5YzjUi/v5Coq3laNOW46h7/oppcie3g/4Bzf
#u2fzyZn9ePf35Iweb78xenL25OzePV1SDihzMcpNCXuKOEJdWb0QkYeKcWheOMqjVo0eqFSUmewsxbwDlIufhpUmiK0kMuZsJVoY
#Yz3vSMxLiTLZq2oixZCfVBVDTNJlm6VFbJ5Sp6Me8OwZL/Fd0go3JX8/adzUtCGKfdrSdcUf8LghrXu3del7yHnRwEMMZKqE+qwu
#YuaeZpCduBj8jdOGhoFU1sbUCGdyyfwFXTetkKEnSq8Amk+TRuhqTop/e4aL+WcEMyPxyGfzF2/vOWYHQd7PMd1v5xo/oGP+IfvS
#S2on/o34i87lXJH3gMSASS6ChIjvF/Z9S8iCR4SnzAuW2rywaIRQ+Ou5FwzrRix97eL8/t/g6PZcMQkS4lib4SJBfohZeSlQaevd
#YbggZkpbhbMxgVavQv9DFGKf5UgynB0JVZioO2RdWLdSRUrMhM+MqLI5Y6mT8D03qfyoQ0yqIPBYiGQvlrvj/a+HUSOU/QnBiWbk
#0oA5F+jmriyCrETLbcFfZG6Xb/mvWEzGnxDoFy5/5wmtW/vXLqlkTR07oltDiytlQJ9O8zTHSM/BWhnNFrizRGl/I2Zr6+Uvf151
#aHLi2FFt3wnp6uPE5IGRSYyi3ZIDUIM4wyhb9kB4HySzWakPcpWblouLvWhNPOqTKNtetERZjBNtJ2idG45F7eaJ0XHrlRZuZCSe
#SQ0V45bNFd6iYrziYNmAmncshrSZJelsYxDXJnZwVtKRl64lO/OQ6oJ4Ao7rJ1P6nMFXOKTEQYex1utvkE4vYs3GLDuDBo/OR2aX
#iR/QhSTsSHFtvlBOopRoLOTwZo9Z3ax9wUM0SGA7XtjAi2jIDS0NBSqTRkeW8g2SN/Bp5QRkQtjNE8GSpDMuhebK8rUiXPFhGUMa
#7ntDK87jTTmJSGelHNkCvXiUrZJFPEOVsrOI67YSK6+0E2TtapGejWvLbNDNzHH/jCsKeLfQBr0qWuIr5O2SPsiQuAIrXS2hIu1b
#Al5uazXIiXnOKxmuW/CWIpBDtUEo/ZhxixQnafTwBFsZX9bj4WmmDn61jWhJl4d/JGGFrLQjJ87xVHHTI59eLOvOy3jVLvCJ60ji
#En9UrAmrgmir/sy8BtduLA0vx1n4Fd3GMXXTzB6p3sXOxpggupFs2XOByYVsvneYzOr97jDNLnuAsvVwnZtgzg17Wz+RRAZnl5ur
#XbO3F6TetlVmeIIUnjUJpfncISTbxgHtZPtjOzjrowomLHES7YRvrWcPzfecpYsOlh3piP0S41KEvhQ3f4hukiIcf43wfIyTM8qK
#xSPhQn9qGRtOr9CV7dMMi74KC3HIQufKgjggMaIlzZDWS+q3+JIwvoxN1wkoJ1+QZaWcfZ6cc8SXRU68quiWO0SYCDUtB5EM7RUF
#cIMQRKGttD2ONCLNokWc5+J1FVNqFFtbhfl5I12Wb4N6NyqryAekhBKXRKBcnHTDcnHzkFtDOwYp7vGVIczHFk1pAv/SdEUPn6Ho
#My2o+a9tBBq9NoKILUkJ2EmYAnZzZHRag9SDB1Hqv7Hqsal/N3vkGjHEM+KaX4lT0phWXcYRamKXk3I4ByrZ7Mc81OdFigAm8PN7
#iuZeN/WTeEqpIkMpubiJ9YgmJAi/RMBLPvcmS76UuiRRahdYthIyZDIDVDdNYYy/YlnJI9HJUyiVLsOi1BzdnPMitWfq5Ljg4DN1
#KsnNHBVNzDQV02wBOSdZ96uyosGKvQSFQKq6hjKnCQfDtFuT87Vbg79ipUWR46YD+cWcNme0GKyYsILIrR8Kq4cea4cr6Shr0gqS
#TeYTceKaxhnNFZHcGs9MFBMx55qIrrmWqzDXcn5zLec/13L2XJOnV07GTCeTlKZartJUyzmmmt8sQNSwJ4KjOmexldW1Z5Zeh/vQ
#9lQuOqeyUMXg+bm/mnDGlS4oN/kqSHfAO2H1nUgnS9kLdBuyTFexnUoWJLNXkO7cUpQkuEqCX9GwrImTefvkOSAfyVNZS2WUm09Z
#4oJdihtiswzh+xhhw5LnseSCEUd+Dtn0lGvVwt+OAyFestdGJutQrp/3bJNCrClikjZeJF7EV2fFGSv/m+ae8+lTRbFrWkqL889S
#5M6Z4c47bHN3HTdAXoTBbzG1UJ7BJLNCPN6fl7evTTOUNolxGUrjt3df6z2q5EL5DJf9kuV0onCWnwMJ7g0CWKpwXtqoct/eJepv
#mZ63YcdjQoyWTSFQwWS6XjaGwDfO76GevWemG89pccHLax7U7kHzC4iwTlKPku49ZEeIILUoPulh2lCY95TKno8ROPheG+ju7nYO
#Fll/R3SYOeuwBE/NkdRacOKQEchzaApRgI3aA7ODPC/ajTjrY3gDDwkseTuVTufExcRMUXS0uH0pWVS0sMy0qIgaafxZPGGEcqFI
#akhhqYmYHkXjRtu9DHElm44VzunbfYxzoglX96VTalRVXl2iK0f8nF5c6qTtjWr3+i6/Ybnyy7IcbAlWz8lNySJt1Yrn+69YvL0K
#HLIXiDHJmrz7FoCpbO06TCBT6aS6wi/ectPpC6WskZxP6329/rZTnfdsPFbXrauvoq8tK+qEeiu9Tas7TbLx8q1L8w4LbVaFZX7J
#TAyn88WS2ahQuiEoHBPF/BprsGzp8G+xy3nV9tIUUYqivOh+RQhu2CKqaw/a7kuB7aID+V2NK+kYbuehkkVEG+24TotsUei1pv94
#UBeew6fPtVsXMpbdOPH22bRpi/BIZnE073ieKU4vS/HrQ7xPU8l0DsaG2y9E+ZgoHaYk8S3bRCkNw5ZIplL03KaULNQ+EqS4kkA1
#LjS01s8pFb7LU14U26p84LaQbuT02BRdDoD+PpsGX5EedBaviYoihTFF/p6sZuCLunPZDL5SL97MOJUt4LvTc8iC0aQYtcO+dUD6
#/Doa+ouZRcZECWZDJJKEYONjJ8DRE5n8fEGPzvTMuqmepM4PRF/fbz3hK4z9TnM1FxEyjGx8ampMhISM4CaDQiePt5hA5jordLZd
#oiNEJ8xkxC1NRoL50B+m5pZ0eXz3gbSCYyz0e0QW8/YFXwXgZlSGDFlZGj6k4COMEl4w5BxCl8x8bmxI4tbFUqFcmCtk5exYd1dP
#vEfYDuHdglp63fYwgXiBh+AwPlKXcHQ5DQvWcpkPnvWiWESgU8RtzQl12OGzjEFjhGkuY4RYiqmeJFlM7HGdasv5UOe9vBg/X0oW
#E6ZRRinZMmpgZIAP2ZbaqZgFYudx3j4JL2GoEzkYQVgMCLScz0FJ7cmoS3AM84nC53g6iwekViEZT5dB84XqkvzQlQvNFueJJUEL
#hJYX/+J458FC6XyyBEs69PF7J25Re3HeosqL86YZ6Vgkito7lgHt/gGP6UGqzoO8MgLkUwlUkxK9UTh1Nz3HUF4whnqRqZgKaTTc
#kqE3rqcg2ZOhL4GCLMAqMGnMZTLcBL5lEMY0zWyPEUcsqN/UhdJ5xX5ZOBh6ZD9XBe1E696kSVqErpgjC/tdCMxufAC5BMM+VLk6
#d1lj6fzp8hkhFZL1J9RmiFb9FK3QdGIBpUKWzNcWOvFNwrS3wrkFtGUhvjQkKU4WjnWRLC4vDXqrxJyusu1UuVhKOo+HLQ7dDGnE
#XRC5UNnb2OOdcq93TpASBjfaWzDymfn5qr08mZ4HkpoudR4twEhdEJ1VErFVP4WZUUrmHDUeGBk/saJBnRLNlKoVC6lOozSnbcMv
#t+3WMrnTUpjQenA3DE3emY2/j+CMKl/IpuVvty3kUbzszNCxA+SYJ+CRUxlk4GlbvkDxuIztBOCsCMCEXCd/rl0UFpEGDBmwPUWl
#kcrb9/e8VMWF3NZdEuslN9TxdPBWWDmYiYP87oZkOB8IW6EAgnjptIzipeR5k6SVCONIhzQvq5mdiiwt21vvLqVM+N6lvcd1PeET
#z2pH4vspcY3PD0wgQyAOoGQJf/BumZsipuye5a9OCspHuqpV9EnncItFepfSt88xQbYC5ap7bgZrmY2fQ4CpYagqBvN/Thy92D1V
#/cqNecITsRtDIr0LQywmIEn9nCPwJkTyi6aeCELspBFo+spqqLdQsg+B1sHMhx9n+a3KGevpx1lu4s6PMXKD7VVZ4VEUabiFd653
#Z84JwZRz6fKZQspmyqlC4tDItBtYryYgV8DmKnsEAe5yuRR1Y7QBs0BJ9uui+kKcrHJ6L0pjMaZcVlFB16ZVNJnlm6/LqOLX7ym3
#SI3nL8aS3RJP0T48tBcK2n1lLMs3u5s5RrqtjA7Gs1vWw/cH3j5/9XQFmXNL6Q57es5+EKq71pah0Knt0me6O3clO+dnl3q2L0dP
#4pYjbh8WPb2Yq3DhybJ4DqQ8AZUIe+eEibY6ra/SJXzgr1xpH6Un/FUb0QZtpasQiWjUp4cok32LJWHdYYnRst9bzWuBbvRsqg8w
#oiiR7N6YXq5aZNoPf01jelgDkaeK5hkoa2WQ/K+Rc40Cam+Pt2TkRh6twhX2Z0o2C/oLQ+Puqi5LPeGXrMsqY4SpTuHVGBAyin4P
#J/K04ywuOPR2z0ZpMd3LTQ0MdEc9+fkRuPjAzC9frnXjnZdiOPq0Sz+Z6oiumFb8EqCozwEydpBEpF5PrLVeWI1UohsOHXmiHV2R
#iqTMcUyF5lm2o0k6en3qciXzS4TVyrYe8saCd2LB27v7d3Z3U2EYIReoR1DOB1ihteegjEIJirauR3vnJx1xUe4ueoUgfqacI07a
#xccQffRKzAqgizhK8KuNqMF88lxmDsRlcPzIsbdY8wN+EOdlEFeGm5WH3nxla18Jt2mPZqy3tuz9uMk0TFvx6pZTvDIP5qSCLqvc
#D7Kd466JKbk51frxR4+CrbCBwhwvDy8j/XH1l0cMl3aHhNR5dGLq8mJn0V/sJPcKxUl+Vc5PeB4uZjpvSV/w2UESJdMl1BnrFZlZ
#0zILvTODxneTIPWLXXY6bpQzVzBVdGUYtZDHA9NCKXNvOlWR6AljxWKzz1z9+rZIFpHJgm+XMH/pD5bHpu8KCzVNCFyuYKedzBUW
#bmrxVi1Zst/zakS+KyLofrg1fjxCh6GRHiiCflu0OVjRFXJii3BQmysVDKPTyJTTtKNhmGcECJGWKf+CUKNFILHzy+GuSDSxaxHL
#BFn2om2maGKXdZ3UVRIdr4oD/UimOIj2UzOwLNwZM009OnLwN0UjaHixm3K8FlPFsnacLJfxASTDMnPMTRzHqRt6d736+VMiQYmO
#0G2DNTR/onSaWLFnXpPmoYEPOoPPGNr5UoHfmj+D5J9OBVNxDbcbtc0AFT+qz+MRFCfYuHea1PLp82ifLu6LD/iTT0A9r6rgbw5v
#mkm7IENtxm7tKNDkoa7d2uFyuYhveOzWppK59BTg9dBYcnG3diS5iBezh/j7B/ygMnaZ01n/ZaS1Q2zttYDwADB1AFBQK6V49Var
#9jMZV6G7sTFtRo9Mpcud1rbU3Nno7EomTWGh7DNrynQtr+L2kV8D4RN/VLm8xRH8rdAih3ys7H+QXOEY+UopabW+lZFo5SjUHXGP
#yC+rgGbvsfoc7P1i1HulIiAKWr+MMqC8kcX3kuekDj19L5IYfN4gQisIL3MdptPzzhHxiKll78B92DY3g+8Gkk4DFErLFIiidwXt
#cz/fHUGpQa/lkRoB4nNWZRVpNSkmeqAaHLclSyS6errjl/cI7xc6hjPXb0I7olAoo45ENoZvwCWSp9OOLfcssepsPMsPe61nhfGH
#hh4khU3g+FnaUXTYwbHKjzrGjwgIfC+viz0F4bd4R7yATwoWLfHHtZGJxVR4d/UXJWZzZZQEhkDwyaXRCxMHKImRQD+vFzUfcdbI
#yFuYKwOFhg5DVSC50VScY2sBFVy7+MTjddFa3zETkueS/BTQb45gXAY1jLuMc6c7FmFR77YET6Vyvu6cTghQRERF+ElXXmR3nwkZ
#Qi8X90F4s20aWk6ehsRtkbbFzrbFyDZ+7T2OJpdR1SKRRxV5CqN6UFSiTgli66+KQHFLP1V7MyL1m90wSsBuc0ZB39kxDjT1wjQ6
#34kqCZ1HuOlyFGKoDzpg3DqBTHLihI0TvRitxLcsOtnnXgp5icbIdBKJ2WVq8i2lIhG5DCGx55EVJYzlIAaYo2qPMoHi4R3SQ7XU
#f1CEo4MpGwjiXs0d2/oDry9Sssw/eHcreWV81aF7RE0CbdDM5XzxByNh6eT5xiLm2h6tN9Hd3Z3waBxLOaVmonYyCN6Djqaj4Um/
#DVwpzwx0DSqXk90BLya8Sq7qRWnRGf9vMs8rnQcrYL/8CJC4X2fSWl0JXkh788LLSwduTcP1+nJrod43KjbjTDU/py6fpJEn6abn
#ksB1RQ48XkqQ1lv+tFlt6lSCZhUP8R0EjZ/zUYxlsc/BxtEukNjqFQY/RAdArlzybDqVgXaZp4XpxQyQhsJZSTnOfhybq6bqZVTp
#KA9ZBnliQg2Vf8PJuoDR5r7JVIrz3iosMn63CZrfd05midmR+Fv69+6NSpc1otuHJ8fRFBzk00QebhuB93Cci6307Bp/1mv46ChS
#t1TGwJNKUytEGjiuu+t8G3kKr9TzHAnrMVgXKvCCxONuVjHw5akMvwY0JT0k6/jGAOSld7xIu8GyE1hdo6KafgppbQp9V5rai2Ud
#g0cnJ6Yn9k+MJabHphJTI5O3jUxG3V/Gc5l8JreQk/RH8VP44jYegd5zPYlez4eE2ghtAmQYQFAH/DGnOohzkUl9Frf1k8F18kRH
#BxmVVWMqrRdRwXmusJDlb5OeAsqRp9Eng/G7aSsJbTUWswC3htqyleyVVd6toAuf9CBIdUV4uuIQke8OWte/Sgn7/lfYr3mD9nq8
#0uzl9kSrTN2K0148/vwqPjWnBtcNxhuC6XNVYaAxKaJ2s7ZQxEX8YFcXOG0pfJrCnqbWDISUKF/nEyIQLnlmle8slZdZ5UJRb0/I
#RzMV2iPw0TizUE4VzuerNMTInKZ20x9dhKZGD02PTB6JUY3V842OT8vZzIrlbvR2mTCFTJZLgUwk6D5pIkGbd4kEMptEQmzacc4T
#Zv98v7h5tPE61oEW0XYMDNBf+Ln/kr9noHd7b29fX++OPtbd09Pb08+0gdcRJuu3gPiiaQxXztXyXS79/9GfNf50o2Eskz/72mPC
#lY9/X0/fv4z/P8nPZ/yFYBEvL75GDcYB3t7fX2X8t7vGf6BvYDvTul+b6qv//j8f/x7g373/nAzoX37/rD+f+W/54qls9rWoo/r8
#3+5D/wcG+gf+Zf7/U/yO3PEOFoC/Qfj3yiuMfVrE37SCby/Cv1XXf3YVe7L+zzd/Whn7883TZHq/VDhdguWUee80rZUW8rTwmpjS
#coVUOt7UFL5BlHF0hLExJcD+4R/2PWCW+yKLaA0KjP5xCIR4XOQcOJqolLE15Fc53IzZf9nneDz+AuyuN2NW/N/+a/2h318sMDYh
#GnNNwKeRjzLWiN9AvukV9In1A/jqpGAdhA9L4Tgu+uGvfpto13EbbqmIu+IlozTHBGwAIzX0Dme+m+D/eCmdLcxxWBFmKutOT759
#bjCD5/jfw/RJDUvtZuz3dzGmrKiR3t916hJ8GmyPqIFl8kCEakaoIiJgRgRERNCMCIqIGjOiRkSEzIiQiKg1I2pFRJ0ZUSci6s0I
#8gBsrd0qOyrgVNcTePAHgVJLECgSOGqpC70IiBqBrryJalSvX00VqRupeLXUg5mwYFVfz1i4fVNpGGLgzzH+J8n/PIh/AJawCYvp
#0TcCagNQV3eH2P0K9XezWrpZYcXSKXDUS6HrIYOxAcrGrGEVYroxZhME1uuQvQOjNmPUNRSliqgejLqWogIiKoJR11FUUET1YtT1
#FFUjovowSsMKQyKmH2MiGANt7wjEzuhbIHA/OMG2zvVb74ek4KXQTswF8zncdhFTdOigjsJWCIc7rgsVtoGnQV1qgpTagg6BMR2A
#CxWi4A0VoAfCnV9/IRyKhUKFDgg8/0Jg6wtMxa5nN6n6BszaAI4ew064FNKxsk6E24gjYDBY4eW1NA7QPeHSp6HzNj4EbVXa1qkF
#6IvwY23rRTnQ0NBjbRtECAYv9HaY+spjei+OIPiuwTnwLGv/ORMS0WMsXasEsLSD6tJaara6tV3v4/lbuxW2ik+1Zr0fG9zC9AFM
#+7x6lb4dPLE2tbAD/16rFnZiU9eqBZhc4UOdjSrvjHV3Xwq0r2uHskJsSkGaxZqNQQAtHFKX26DGgA7VhzqV9kBDSHTg8jbqTMgV
#bhSNgc9CMU0EatHZjdWuktq6rrtJrS1tUllR1xD3aBia1KXVUFhoCYtsCRb24Fcz9c3BE+JLGLfQ3V2jam1LzfXx9foQpLfUlO7F
#UvaSX86H353QobIOyPNuO49+Ew4V1SrXV8+RwBhG3Cl9HfK7h6awj5K+D0mh+/ATfT9EiNifQWwd+e9vxCQYs47lrVj6pdBuRJMR
#rPUgOFuxf4Msyclnc6CFbdjEm8JKwYAJJrv/EH7QgOAzAUkzot5hnjpqp8pfBUU6NbJwM0cNqC/AAGWBokJ9hVsQOUI0krGr1dA6
#HcAM8UkR4mNaGEM417XfqS5BncHOJpxqoc6Qqrfh2LVfDbQL+RRMzeZSHdYObe7QoYSOts7GrS3s0lpAxatDHdfrE9g7jrgG/Sgi
#nXGrwNFJnJMv1Gxd1/ACq21nimCIhw+zGsR1s67aynWt9qlrtahrCuJuNqZFXccuV1eAAWvl9G/9MrZdXbfcQhMaEXS5Fb1L0I5g
#4TYcAKJAm2kqtm696lLoOpv6bHZRn9Um9aldTx0uyM3LMrnBsUKYsMVX383n/dXdNexnjPh3sxgOpZ3DEOCj1cIKt2NRNxsw3UNt
#InZ5HYLFh9XMqNKU6qylxnQodctAc4NhR2GhwnGcBgGa0MvrESeCyxqln8Bha6jd0Fsbql3egNgbKNxBXR7celVHjT4D/qb6WH+o
#vnASe315I35dX5ilwCYeuJMCV/NAggLXYCBQuIsC1/FAkgIAZpBIcDsTY/UONv8PLGDiRQpiYHo2rwuvayhFEDdWYYefQlrU0VmH
#IghAxAHf0BeuL6Sw2HBHi4jb2Fcn4hrq+HD8xxfCdbFQnUT9Q7VGGqcRp8dXsV1HTHocZMdOmLAEGPKIMI6RDnQk9MLGsFraBxCF
#CvOIKKfR6cQEuy0wpnVsY5S+D7EwUM0GpLd7Bb3tILRbOUFV2o0ziGArR8rW0M4TiOocM1tr1WaBmxxrmgWFL2SwZzY4I22+ua61
#bl1r/brWMCS50aG1obkhdl1zA0eI1jrwETa01oOPUKE1TL1cK+guEldRhZu6NnMmI2LuDFAMDaNMnc9gfJ0cU8aYejnmDRgTlmPe
#yUsjFJTjP8jj74bALXL8RyHe1UlnwX37rJmlAGvVcDOf44Pvv/TKKy80Noditc1iopNY11j6JKJsTuqzPPlDW3k69Yy+DSf1UgFR
#eamIfRq8PI+yuVFb6T9gJffYPfcXGC4htNIHX6UGIXV5+1127H/HrEj65cifQKSjO+uC0ElBOWYTxBCC2B3SVtIgspb8rTWh5hqJ
#TcY4m7zRzSbZ8BifJ5+FfyCpsB8xkkkYzjlcUkDXsSxg8NcUsdYQv+9CGOdjk2rnxzk2qVI+QUdjdeoS0vYY0NP1ROWvZOp0tHjn
#jRjwzr9zjjbwEKxPGskwjWSDfgMygtrjuoEUq04MJrCuUJfSHqrtDteGugPrOoIbO5QNTYLvlBHEG5xC7y4Ec4HAxBR9NXJIoDEd
#K8EVkEWKLXXrN3AZpE7KpTejfFFX2hk05QvoMWSBXKqq40KGP5btCSJCYWYZB8b8EAMRKuRGqFo54njQhXLzEOGY5BrhoMAudQna
#HiyVMU7CM2MRwbvASHTvcCKbENjfC59sEgI7tQbkdSGXt22oFZ6NUNG95vyx5XXi2wfY9XMcFXF9twNxEPANJI8lZKdxlGuZutxF
#f9cud9Lf+3i03kLSHIX0ZSoUywAxEOV6LON+LKNflDFAfwPL2+lvcHmHKLOPl8mz6a28TAzpF0WZIQbfsNW4TriW85qlqyD9xPWL
#dwPaqaHlq+wVzIYaVlwvOiTwmP4AFvEz1WhFYQhXj6rxBgSqibxvRO8qO3Y1ed+E3jVU5Jvx89813oJDtulu/VdxPH4NnIvA+ILG
#gxi9rvBWjGikVTLKrbssufVtOHFCYi2zLcTXMteH+FpmvUOAlbgTrG+F1AqedvIIsRb4J81/lGvbaQGMcjlwVtyTaRaT1pT/bKFP
#rAal1R/Kmw0ob9ICcGv7zWLZvp4a/XZsdNwAaEMXI3w3gMdNBngTwgFqwrpLCl97Bdk3BB2TmGLgvnU+K47AEtYhscTAEgpmboYY
#WNroii1T7CZX7Bso9mpX7PYajL3GFXuAYq91xb6TSrjOFTtOeTUHd7G6QZorzdJcGRJ4vlfg9R6O1zxav4rj9ZA1V6zSsP96gf63
#EJ2H0oO0vNMfYtaqhwRoHUd+g8iBa1uYBlHMSCvDUIty/dA1nCQq0gJLkZZlivSxe4GmSAs0pZStsb//dfl7BMLvg3faH9gruVCL
#en37Rg6TKsGkSjCpVWBSpSrU0nesKlRpsWgPijkmrdKY7BNjsl+MyTAfEx6tr+Vjss+mX7h2icJYXEVj0ckXG0j8GkKxAZhZ3TSz
#0G1U69Yfp3Dd9Vft+TNc7xERV+/rQQT/DShu15M4JUKx8VoeufQOnIzc+zA2LIbNfSfKSS0B/V1IFG5U17WFicqq9cu9VBzR2oCq
#w2zq+MY7cL9kCROa1Pvwz6W1MCWuVteKr6Cc9+CM5rC0BAu/iaFvjL7yyiutNbWlPSHgcTYspVMhZDhc4P9XzBT4r35hY2tIvf4S
#h4MAaA7p74X0F1qd0fr7xHzAtQYDyv9rX2EdUVqOrmLf/0e+VtjO8wb0R3hmlGt2gFyzlvq4j/fxAPXx+u2HVf39kK3W3nK6vqvw
#Aey3JeQbtCwxfgvnqLqEDET/ILbjDLTD+NeIE4/iqO/EpU4odja0fjfvMIwofAhzvhVy1krLksdQOGmgUaVMv42FfBiZMvSe/js4
#JsM0Jgin2hxcHqTGE7Pim5cd38gpWAcmtELSII3KNeaoEHcL6h/BUYYx3UWgrY8fUJfQW/go1vc4Ou8kSaClhiPCsLreqrRmebdd
#Kd8x6vjGT6hhmADiw327nahAldYQKoh6PgZe7e8B0K4WOeZhiOnrv3q9gXO0NdQSKn0wZM6ykJSRC1YhmnfG74Fzb+MLt4fWdbXy
#PLEGkZekRx6/U8TvtOJB7gTsoTZdRWMEf3ZZLWuu1X8fUSxSLVOd/nFCIpSzUZ7+B/j3Rfj3J9CODebeNPyDpRy7F+Kek+IZl0vY
#30Dc9+AfEFkm8LOf8PMPTPwMsM9C+jrCzz0cP/dyGtCnGntQkriRMAbd2uV2y3/Vsm75Sx+DjlyOcky8uZboW6mxFrBvCTfZ7LlP
#iPYuG9H2CES7iRo9JBBtI475NkK0mwSi3eQc8z0c0XDMW2ourcVDiOYa/RMM5fTCH5rDGwcIgEg8gWz8OvD8EXg29l3FYYbwH+P8
#wVZ07JK+2olf1fKvNou8tZQXd694BPEiavALqwAD6qVdCa21TnTAgVpc7Hp2GHgJl0JDpoCiP4mooLXWIzLs4Vhwo9UhzfWcGm3y
#TTWJkokjX4B/IBmzHQoff/M3grgCcYcUfoQUFcc2mOce8P2KFL+dFy3RsADrh/T1hCPDHEf2cxwZhul9V+0S7oboKLQX/g2OATCt
#T9oUHr9Q65YPENDEjVRV34Rj/BLN6wPEYe47QEO8BxePa8VXUM6noBykISO8klKRsCrmwCqLo+whQjLMOcqIXR9wFBCbOl4oq0sj
#nJ2MOPFpWGInMBJBUdkjtbRucY8gsIwaHI1hqwZAPptl2NF8dDi/OMcKf8c0k1/8tFYx+cU+ua/3Td28TxEnarhQOdcf7473dff1
#oKANkjYesu8Ehr0FVhsfhr+PggCwZapcQgVpzHEA0PlzQOy3HJtiwW5+frnl0LFR6Fx2FYTfC2vDLfuyuAln0g/l9vWPNdTjrtnP
#lD4kBFj7Wb42Irw5xPEC5Xz2KaQ1jHCB8A3xB2kOnl9iM/FbqII24a6mGnaEeWtCrLXuU6tC7H5y/zr0SNNq9l9XYfyR2tvqQyxd
#d6YhxJ6uRfd+ct9Pbh/FK+R/sRa/HaMSfhD61KowW11fDoXY58C/im2o3dcQZpsb1q0Os+fD5VCY/ZyVQy3sxeZNjatYy5rnG9ax
#LyqLaoj9BMrZxF5mWksIqN9HwmH2w8bH10DJkBpmzzRimceaPxIOsYebMfXnDR9vCrFfb8Qan27Gkovk1jai+6EWzP8XDHP2UfwD
#YYx5quEj4XXsDqoxE8LSegn+G8L3rw6xBuV+gPNmgvNP69F9hNw7VyMkf6xg/hR91U+tq215vmEV+27z89APexWM0deg//ZGLHO+
#9hGAcGPTp1a1sPfUbGoMsRYF/Y+D/43sR/V4ct2h4LgUa7CWr6wph1Yr3w7CSlP5kxaM/9aqMfU69lRNH3z71wz74avUD/NNrwC0
#X6xBSJ6vRzcJ7YqwpcZdMGrnFfQ/s3oXINDOGsz/q5Tn/0D8KnawCSH8EvXMj9a8B9r7UCvW/j9XoVsi/z3k30z9tkT9dolG5MbG
#4TVQZtMY9N5nwx8JJ9i9eLjH/jyMJb+1YV9DC7uGWtpd/72WFjbfsqmxhZXJ/c0182ta2FvB3cpur3lL8yq2qub5BsJGOjdX6L81
#7JW6deEhK/Tt8Lowbh9fxQLKGnYnzKwLMB0G2BshNKdiaDOszQOb17AyhSIYgjQQ+CDUxgYp9B4K6WwPhQ5QqIPtpRDOnGdZJ7uJ
#Qniq/CzrY/so9AkVQ3vgCwx9nkLD7CBAti344RqFPR/4CLhNwY+B+3nuBjA+Hfw4uDdRnreQ+7uU+r8Df1jTw9oanwT3Ow2frtnM
#hgJPgdvd9Ay4G5vR/4G6P4ecn6jHkpeo/Cdavgbu9xrQ/XHj8zUh9mD4RXDXhT4G7pvCHwb3365GN0duczO6b6hBd88adN8dQnd7
#4Gvg7m35SM069vnw39ZsZ33q98Dfov4tuAr7IaSWVzMY7R2tWPJvUC0XatD/UBO6p5VgyJnnE1RyvrFOxCvsEQXb+x2lCfyfZ2tD
#dp5rrW9fqsdvsQSFPaa0Qc4fKe2Uvwvc31fkr3jJQYj/PbbLUyZPHaL4YfHtUWSa7At1Pw4/pCjsuAgFGhCjkhR6S911gTZFZRkR
#ag/cHlJZSYSS4WNKgN0rQvnwGhZgbxShPa3HlCB7mwgdal0D4tW7Rei/qw8pNewDIvRjYO017HdEaMuqkwDpx0Vox6q7IPRJEfpR
#00NKLfu3ItSwSmG17IsidMuqh5Q69hURuhPS6thXRWgtwFLPXhShGwCWevY/eGjDRaA8YXZ4M2/7f6k5poTZhAitbsDQbSJ0rAlD
#syL0BUpLUehb9S/XpYECZEXo7+vuhtACDykjgbtDDewi/w645e2hRoa7wRhqhVAT20Ohh1lTazG0it0mQl8EerKK/RqFHmDzNfeG
#VrPv3MBDfa1vDDWz4208NNf81lAre4cIvbvlN0Nr2UfbeCntjY+F1rOrtvLQBwPfVdezi1t5zk8DDYS0bTwUCP8u5IzpPGfD6o+H
#NrJP6zytHqjiJvYTEVrdhKGTMR769XoMfTnOQ39V/97AJrami4cutXwytImlROh/NawBPvu7XXbPX8v+jkIPb3hL09Oha9mabp5T
#Y/8eQsdE6FfZs6Hr2Z0i9HblG6HN7LQIfV0JsS3soggF1TUQ+mK3XcMN7Ovddg03sG850r5PoTeya9SXIS3Yw0MNwJ/b2Pd67Jxb
#2U9E2h3svYGtbHevnHagl6f9EcPQG/rktLf38bS76bu/oNBLyjdbMO2GAR46FOqHUP+AnbaNPbPDTtvG/nKHnaaz7+yy03T2k112
#WpRN77bTUO5R2H+ue/WuVo9ufcB2exrRvbEJJai1jWaMyn7agv5v16H/h/VuP89zsIWJnwKUDWN2tKL/0+Fq38r+kkqltZrxCrs9
#5HUDDOf0czCOz4Ec+hzIgs/BjL/YpLBmhqOyEdww9M7FpjWsh9xd5A6TO0rureSeIDdJ32bAXQvrE3QfoHIepNSHKRXjN7Gnwd3G
#ksrFpk72OI3I4zQSX1Mw/wX6SlEvNh1k72P/MzgG3Jr7P9F4J8wM9N9AbozcfnI3i/yXGj/BouTvUb+25vPAbdG/S82HngO+W2r6
#RwbltTQqo+pNarMyzT4Yvla5Vf1mS5tyQn0EqGhSbW6NKhkq4SR8u1N5H/t+415w39g4AS5SuwfUvoYTytfYCMz3n7JQ6xnlp+y5
#ppzyoJpqvQfc3wNu8DJ7K5Q5qp5Wl8BtDB1THla/Vf8Q1PiFuoeVemjpI+BGgRvUK28OfALcg43HlBS1PUVQvU9dqj+mfEj9m7rf
#U7LUiozy44YvKE+ofxX+uoJfrWFPqJ8NfR3qGm1ewzYqnwp8C8r/at13lR71+zU/V3apf9TcpH5G/T+rNqtPq9tqlpQytajMHm1u
#VJ5W3xPYqd5HMfdRzJvYrSBrvYkgfBPB8CX1D8IT6svsA6um1WfVS2vuUL+mfnb1TnAz5DY1o3t/zU7I844Qug837VTfTv38burn
#l1SM/wDUcq0yqjxYg/2wr/ld6oeppdNssvW7AP+2+i+r0+w94WchflNgp/JD9efBr6o/VD9Zd0z5AGDK30AJf6n8rfpT9b/VfBvc
#b675rooj1RJ4ExtavSHw+2KUTzb3Bnap/6HleOBJqvEp9gd1OxWoq+Uh5Vnlo6E3B55VPt/yNnC18HsDz7CPhj4GLsY8w7TwZwIP
#qMX6E9CHCNubyH2K3PeR+zi5zYFvN30x8Dj7ast/CjxBMU+wDzY8F7hA/f9DiulRn1P/MfCE+vXg1wGGVeG24JPUiiepFV9mbU19
#wb9kZwFPnlWmAwfA/2Xo/6fYb9e1BbF/7gg+q3ym4RS4f9UcYs/S7Ngc+ErLr0Lq3wQfCv4U8OedwWigXX0k2BO42PQoxNzR8ji4
#96/5w+BoYFPgk8HH2bvUp4LPU13fpLqeYVjXN6mul5XxlpeDuwK/pf4g+LJyuCZQM6rgPH2GYb3PsL9q3gn5sd4nlMdCAzVPKD9u
#vrHmM8r9rSPgsppxcN8E+PlT9erQdE1GaWsq1rykYC0vKV8GmDVmsCdrN5Pbxt7GDoa2sRn2v+qibIn9vC4OVGd1bZy1woouDqvI
#HeBuYTeB28EugtvHfgPc3ewD4O5nj4N7C8VPgXsTlTlM7n42x75Utx/WsreGRsgdhfJX1d9FqUly5yjPHKXOAY/567o0+TOQ8+r6
#i5TnAXLfCDlvDb2ZUh+E1Gj9oxT/IXJ/m9zfodTHIXWg/nMU8zS5f0rulyB+f/2L5H+J3L8l92WIP17PFPQr5AbIrVeW2D31Gvk3
#k7uF3CjEv7n+JvIPk7uf3LvInSP3IrmPkvs5cl8k95vKWfaZWqZSXeq72ON1ivo29lSdRjE3kfshFfO8BO6X6lgAYzRybwi8i32z
#7nOBOUjdHMSWDpObJPcBcj9E7tPkvhjEHlNq0L+Z3GFy76p5P/t3tUnyXwT/d2sfIP9L5LIQ1Uju5hBCuDn0NvaVupsoZjiE2HIX
#+S+GsPyL5H8gRLWT+zS5L5HLagmGWvRr5N9M/uFaKqcW23JX7fvZxrokxTxNqS9S/IsQn6x7iWKUOkzV6v4Y+5ncZB3GP0r+D1Hq
#i+TfzeaUi8pfAqb/UNmmjqh3qQ+p71N/oF4MfDDwp4HnA98O/DCgBhuDmWB9zUyNCtw2QLslHQ0/A94bD1wCtxRWaxm7pRXdn6sY
#v3tVCPyrV6H/FLk6pf7XGnRbG9A90YTun5F/Y324lpetAOcP0L8a8AfBRd3tWvBD54C/Fvg6Svr14K+HmacANA3gbwCerwDvbwJ/
#E1vNUH91NfhXgwSAq+Vm8DfDHFVYC7ioe7UW5RmQhlVYNW8Edz3MXZVtAAlVgfC1UO5FkBjC7A0wjxuAgkbBfQv4G9mvgb+RvRX8
#Tezt4G9ivw5+jR2D+fEGkA4eZV9mf89qlHVKl/Jh5U+UTWqPOqQuqPerb1E/p94QyAcWAr8diAWHgn8W/C/B4EW3Tvq6MDPVwuj3
#YE1biMtQjJ23so7R3oCc751i18D57aZGb9wrq71xWos3rs/z7ftrnvP59jDFBWnUUBYLwDgFYJQCMEaILwHouwD0WS30VT3bwXLw
#7z749zb49wj8exwo4yfh31NAG3/AfoU9qjzInlR+hX1DeT+rVX8L/r2fFdTvsSOBH1D83YGfsncFXmFPwt//Af9qg1FlInhEeR7+
#/QT87TVR5Rz8ux83Affs3ZVI9Hcnutmeg5l8xjhD5nr2njIjxwrJFIZ6BzC0dy6ROJAx8L3Y/Wh3o3eXX2wfxU7kD6XL+wupNH4O
#4enM3NnRfD5dEuGD2QXjzN4UVNTjqKbHtxqM3ZnAP45yMXoB/xxcyM/d1cPGF7Jk6h68oyP5hVy6JEL7C/m5hVIpnS/fim+wYfpR
#ugEFCfOZ0xCeThpn4c+wcSE/h/4j9HzFvoVMNpUuQcKhZC49cg4KEEYixCfD55OZMoXMCssFDI1ljDJGltM5qH3qBgI/W5hLZg2I
#zZf7etmeqXQ+NZk8T53Q6+gECOX3DiTwbyl9j/BhS3t5S3sZmfubXihC63rZgQzZC0yWLkAAq3SW1sf24LueWEwfFmhw3zEAY3u/
#I2c/RwjwDTjiB9jpdDlxbPrgTszA9hwppBay6b0UO4W2EUYPQBcv4DV/3ME+m546kywV48NHRyH/BGUbNQ6PTd/GEji8bOqCAQDF
#9xeyWW7q0IgfSgNuZCAJOoUGgU2mk+DjO+I8Zo8Lq/amIMqJWBAFOY7Si8YHS4Uchy7FISVDghAw5AA2k50plCfTaCqDHcvTn+EU
#/2aEm6SgT0z/zYVMHv4k7uZ/JwQSHUUTYfAlYsQxemoIU/BBmnI6JfrADidKabSGgB/QG64HC6UcGpLlOacL5WR2kt57praY38Ow
#Z7j/mAHdlUIk4u3YezaR2JecOwuddTCTzkKKANebwMH1xtPLdsdKWW+KMDLiV1QKn9vJokWGqfRcAeD1ZpoSRpcrZjiS+b/tXU9s
#HNd5/2ZI7g6X1Ii7tFopldSRI7sSTC1JmbITI41BkZTFWqQYciXFMYTtcDkix17urmdmJW4FwcuDCwSoDz4YSA4++BAUQuEiCBAg
#ObiNDwZaoLk1BXrwoYceih4KHwI0QNv0933vzc7skrQaoE3Qdh65M+/P9773fd/7vu+9Nzv7XkP8jmL4kFZ23Ggt8O75ewfL5lv+
#q17nQP4roIkqgb+71OAeWnFbHEGvogd2YcEEd6cEKZb0Kqf+IGw2khRvDaqcgIDdcYPddmsNQkfGwlIj8qPOsj7wSNsBn43GApGq
#qWRPael6s/nmCkd4t1OptSjnXkt0RR17J7XX9S5W/XmyPWeclfg3WmZv2ZStcxQmMc9VeCyVdFsSZ5bn63Wh3ffCq51Fjze98IIe
#pLIbSa56e5Gc7hUb6zrM20dyWWyR2fNW3NoOTAA2G/Wlw3RCeapOy6M7O17gHeEn4AsCLUc+x5sURx6JUdGCnOgK1zFbrQpy4IJL
#IzYnH85YnAef+TofAe1mG0WL3mZ7e5tFkuTFw0OSMx+G3u5mvVPxo3Q2a8Ja0Gx5QdRhaaQrDDCfFFVknxKRGW/VNEiKF1z3t7a8
#xsHGr4EFbWEHC5cb98QzsH+vHwmlTLodCFxSvO7d24Afijrr0IcwRSoPHEt1bxfjGfOXKlIiddX+s3V3T2LhwRYhnq12LTooXL21
#0WE07rbcRidFndIoyY/8Tb8Ok0pK1WmpsGGoqYouNdRdWRsPC6JbDAIDU3E5uQt87zbvs14GPhzmH6kqSkbiyXW095tnneYTQdPT
#Apip3MQ00BzF27bRis+bqTfvReWlvchryG7H5RvN7W0u7DeYsu40LgEE/IhEK03FAg9XOpaagZFMNRbCO35DvLLKrGo/SRu8200K
#8KqHhle9BypLplaE+A7xxmRCvtpDjnzS/m/Brdc34TAhPLn6Eu2sed6biVjUUIRZjh6jbvBUx61T/2/FX/VxETKU+9AbGF+DPijJ
#6WFFJN9LLFQwMNPCwobcZZgm2WZJjXQQoMBLRAlUUQOI1fYuXcWg47kN+trM16vV622wRHyw7AY0jF4JPK+R6syEXp0Wt696RRqJ
#44nvjHNW1LZbGGTiHHRhyiTjvq5A48vsNcqxzqni+VoaCuao5zvKKybzH/E4y9sNuD6Ib8uPYtIW1ZmIg0XwuL39p1Jkw6HL/m6H
#UUZVPqab1Y8NL9YD5iWZ20qKT/aNa696UZnHHkxZ1QAYF0Cab/Gs+rYb9FR5HmrF+zceMYmG+46q1U2dWGZrwV2UU0VjXnl4aDXr
#7M8VYj3lhllvY1rtBel5OKtQT+94r0LJU50/kIvRn3UkoGoktxgdz9V5AKHeVDI9tWcDjaNVGD3f1aSLWtKC9F3P1QSp7piXozTS
#KwNGlkqVa+oqNy/QdW+vhbGYF30XPR9Gfi08auBUTYVl3aEhuuNWw98Ta1ATLpKJsI4rT3hg1qbd4sF8cbb9Ezg1fx7IE8r75nEC
#NpB1SGdVlY2IH0Jfs2j9mqcQHlE04GDjWUCvXA24fKo3GArpVsRDC2Y83DzruoyG0kCSYsciU48jBc0zlHJvfAqTyWOYtpa1gI/P
#8u8zStaya3V3W8EuYg6zE8IK5qrVaMfv1aokG55B657Yz8yNQsiONyRlPMkw9IVjU3l+M4wCdZRpeMgybECX9cGukrvYrLV5vhDn
#rdxvPVkn72P6NuhLytfV9p7CQxzngnQ8PpRbZz2hHZF0SLEhh8kaUCumuxcneS0Bhpu9Eignz+e0woUhcIQkJ9DMR1i5Y8Yvuisw
#Vc5JqnCy2ai5EaHXG1GlycjpppxwCh/BQsXkH1PZmhoS06NkKjeRDy3C6TEzN+VMNYqnNTcD7RsxRwjCKEnyggJrBY4CVsc2ejGW
#5IIcLi1dqGd8wul6sxnF6XT3KgehnpUctk5PnqSAaS/ke0vf9SSL96yNZ1kSV048TglNOq5qtHVsObzaZIHF8g60wFJpdcyOisuq
#TkUrTe56NduAt5TW9TnztIKZIC9m0gMiyT4c+vmLWk5HtdXmA0ya9hRRvRWn4iRJbrgd4i39lbrI4lNAdJQ5c/1GyHEstIIONVvV
#5Qa02eXprRqZ1OpRz1vjdUafc1rjY1iJ6NIOgVhq0Us0jb9ZukwvUplm9GcW+ZxzBakZfgh6/HVaJY/2qE0h3SWaTFI3MPlr8NuA
#Y7O69mWi31ulJVrDZ5UqtIw/B604tEAbKE3qUvcvF6iJ6g1k1UBQCKCIdpDiL4A8Cui+XDm3mSobROTQA8Q3cW+RK9jqYMGhc7SN
#eATcTdqSmnXEtoXkKUn50gLXq6NmR1oLpYzbx2ADCKZQ5e0ChrHtSFmZ6LdrAlMdaIduvSJpB/CMO5B2uG4/DU6KsnuIBSkeD3JE
#7kGxO/SQbtMjjdUVXFtIXUjVY5hbgJk6IFVfYB9Cmo/oIvNTrRzZOkOzpBtoJ9KY+N4GjCMyUrQrqP52OgIL/KfWgMkjV8q5FRfw
#jIWWHKm3iXwlCU+kF4JH5nQ7JSFX07CjsccyBP7JdLtV4Y/GQpG7yz83HW3IHT00hDZP1XTfqbwAvNSlZ/lXgFwS16tKz3PdbYGj
#34mAuybyvyc81EXurHM02mtt7E0pqTPGY1uSy1QjddzVuhWK1jONNc01jbY0x3TsDeT5In/wUdxBiuF7POSZqpa+7wGCYaspLaVj
#LOEAOdxLdDxphXmjYjrN9kcjQs3xfmugfFtJcugSGceZAsYZKarGPLSptI5b87U1Q0bHAuBuSylwfHlaaPXhCBh7W1vAdJrat1d6
#cZYrl7OEdrROKx17SCuC6ZFIuyI5FbGASxJf0Cm+T0nOqqT7eXKE65Zwrzgpk3HmoH29pFt8JD3oCrXb0ku70LIWc3amJbhY8xrA
#VRUeqqTkQs849JrIITjC8kVnbjlis+wj6toqr4i/Ydi2UKg8EMugDi7Yphgr43EFH7fvpWzwItGGAxfckNrK2qM+S03sPJQytiBH
#vGpstyx7V9uiryz4mZq0WxcaY1+wJR7C79WjEeHqHPdTS0pqIhXlS6fpDWDmGE1+E702L3pxiV5F7Q4ZY9fRcxUMH8Dgxv4o7YcO
#o2BToAKxsZrWmLLoRyDScsXKleTr2hMHzM+5o/Sy58tHe7ExrhOIztBziefmVt9CTU+s8xCPcPGoNkKx5ZbImfmgLw/mHIKNqP7s
#7uNTP7i0+M4/f/dbx380/ToNO4ZhwaMZI4gUi5y0+TLC6TMjuROlbxglSxJ2DtdS9yN1+1khb54ovWWU2qX2iGMap09azpBh26V9
#wzpR2h8ByMf2jGEakjhLxf3RkQJnxqXvSvLdOPmJJD+Jk+9L8v04+akkP83NGAZwcWK/KNcTo0QnSt3HoAOw3Z+apbZ5asIAafvn
#ANm7oeQsmcOo0s5LJuAdYgYmKaf4GHZoEvKgiTFk3DXHCnmwNUmTBsRjjpA5Pj5unSh2v2sUu3/NApmkCWeotDte2r+SZFNp/6uA
#t0dpCNR91T5zejhvFHkfr+Ij5BdGyTRL+0v455bM8XyudLrUtguFYvcdlFuWY5pAPGmwTC1rqGAUhBr7tAWu7LNUes0qGDoHjNyC
#WH54jPgap0bQYPcdMzeEykNoXTjjTjKAeRS9xsSa5tiEYWjx2CLKu+MTRiKynAITjty4lmWpbIuJt/IiptLEaH64NGEVSt0POHtE
#qvh87X5g54ctS8Tb/RD/0osfWqoDuh/mdQmQ+qZlgfBS93uQtG3bz+bHS+elYxWvNqPhSKxzlmUB/1gKhBsfhXJOcpdCIvsdeyg3
#SfgYQ0Q2PtbT+VHUs1KV+pFCbmgeEGOsG/vvmNz9x5ReTSjQL02YWrmMfuU6axQKPaiiCBet9OSJzrCET9sunCh5hoqycvDOZ8Xu
#P+VZtyfOEnQUWSy9H3LpFEv8F4bNes6RSQGYGmUCuz9GcigPFSGjuP/tAlsm7ur2biFvxHrJiGa43kwhPyRsCqfgeYyL5rho7mQ+
#b5VExf/BsBV56A78A585IWaCBm1umUEmRUUAWpgxTSZ8QiSg8ooX8jRsc1De4ntn8uivcSD8uQDEdxt0SJ9DZd6D37GH2OgQtyXr
#ffEpuCs0+x+Ibn3ItmHbxxxDKAKuUvffrThuxQ2Ma2IQLU5JxQ8sLTU7IZRLivuPnXzBgiV2/77Y/Sym7B8Rx78SQlJjBjYMQAbg
#ut3P2GbtCUQE1UfoDJB65al8ziqdL3Y/V9UUFqnweb5g4lqcS3DOWd9/ufp28WeFl6y/eTj5y59e+uwb1kc/7nzl4md//odmzjJz
#ppmzzdz4UK5k4XMLn9fy2k1ZOW2H7LdixTJzBcDsmrmx0VzsF5Fx0s71aTOyGOfp4RxroNbPvO7YvFa94Rzky5efj+ZiiaKSg895
#rvh5wSD92xcakVdeeAQx4c7GOTLO7keGENBOVIDemex9TTa57n5OIvaYA5l8GwNCqfteHH8fcdQwFYhpsQmwoyg4pupGm63aiME/
#TlX9JBX/FHH2fqV2wdFmX5oYukAWPiY+Nj7jwxdApGXo3TLP8o8sKuZv3Qnc1mqz0Xu0XdkJmg9Cw9IM08sGnSqvLlX4Udx8qzWl
#H8r//v3ZmfIMMNhP9b5+0y+Q8Ldbo1zFYRDboNHk2w0aNyi/7tU9l3ee4sSsnGzAG3IYNDKrosMs4hGh4DmDnk2++xj4VuG5vlda
#6JJBF74Atv/dD/4x59UvgD7sxZvnDnkb4lfF87zCc+AVCiopiQ/z90fD8riD5TMsSmcovcN1zJBdfyQHffRX0kfHVFUjMmuRZMt7
#V4zxmPpWLf4mRSQev1PB1azel0OMOaefqEhJ720Nesqg44PPnumkQZOHPbzGcEL2wCNoOm5QIfVAJw5z4/t/RsbKGhPPv5XcauNz
#J3mTi9VgktTvrx+j7HGqjMNEf5LWNxY3Zv72d098a/ntV/74wpXClz75i48Yx3S025q+tzm9emO6ufnGtNa/6YYXsYam9mFubW3S
#xvX5y1deII3nT69pPExr5RcX33vq6383/J29P9n+13bSbineM/eQEO/7qkIVZrRYr6+4foN2Q3727fU2f/7lM8AxyFIW/k8GQzr6
#ZLzLciqf9XXmkHwOvHfwN1Hyk9T+xT8x53C9TRtYVt+GFa0jtkw3sVSt4r5K19Suy/Tx8L/8h8Jj9OF8WafY0Qxsiyy/vzSAlZe5
#1/RCaxmLMH7YxOG81OJlpCuPAeuphawK3x925BczG8gP9KObg5j+zWCYmd7fHJas/MOoOSognx+D7upFbgcc6Qc8CIc8aaWvSZ24
#jUVZeNak7VYfbYfVncHYmNS9rR+HJHVmU8+BZ6QtG/DLvccIDXlEkVB4sI0yFqp1+R06BmbUvQGIbanFXLbAH1O6TfwMWrmURWnj
#ps73dRsxjY3/UltKjmuyPN8CDD/OepIcZ3iFMVBnUCKzKVl8RWQ3L4/uPGDe1I9ijq6j6v2/CS21J8H5F37ThGThNxEOOf9BZcjJ
#fP89bTzp/JcX5w6c//D85ez8l19LeFhwnKf5gDI+1rmnA09PcbY+CIhL5JgYlevKqywCvrS2tFpZXnamnYWNy1JZgWwlLx8xnH4N
#LHT4vLSOo09xj5py7GNc03ngbTpygNpLTivw77uR55zb9iL++p1PV/MbU07dv8/nRMrX91MSAbJQXmuQ8xfvyWtz3pYj3w17YdmJ
#34ZEXgtt6qY3O9J03W03ABaUFdU1/doMSH5dTmd7mEhGE8LHXw4wh3WX4/Yo5nOO+U0URbEjxPPJg9xcj0HnApYsDxoArndYDJ1m
#W85SxkrkYpmbaPNrvYz8XKpdt+5jdSDU3XUegcC7mmrmULKT/hPjffpu4dETT/YpT99eWt9Yvrn6P6hjv/r5TzMvvnA5s/9fR5gt
#z5afz85/ykIWspCFLGQhC1nIQhaykIUsZCELWchCFrKQhSxkIQtZyEIWspCFLGQhC1n4Xxv+E7fpB9EAiAQA
#__NEXUS_PAYLOAD_END__