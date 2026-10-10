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
readonly PANEL_VERSION="1.2.1"
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
    jq --arg rel "${CSGOREL:-game/csgo}" '[.[] | {id:.id, name:.name, port:.port, maxplayers:.maxplayers, map:.map, cfg:((.path // "") + "/" + $rel + "/addons/counterstrikesharp/configs")}]' "$DB" >"$tmp" 2>/dev/null \
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
#H4sIAAAAAAAAA+y9BXhTWfMwXnwpvjiL3BZJQtvUhSoUChTaIi1aSnuT3DShseYm9eLF3RZ3Ft/FKYvD4i4LFHcWW3Rx+R+5mqSF
#9/fb93ue7/l/7ELuPX7mzJkzM2dmrtzT6b/+xwv8CfTyQr9e9r/o2dvfJ8DHzzvQz8sXpAcGgh/C/78/NCcnK20hzQThZDYaLSWV
#+1b+/6V/5J6kyfRfxgG0/v7+37/+3l5+gf7/b/3/T/zB6w9gYNEq/1to8J+vv3dggN//W///E39E668mM7RKo0FuMqT+m33ABQ7w
#8ytm/cFaB9iuv5+3r7cT4fVvDqK4P/8/X//RXeM6VHFu4Aweq0R3bNcd/O6Bf38oD/7tflVXwcmpulN0uzYJWXOfzKuQF/9n3UOD
#os9VkR5uWW7MoEmLYqLa1x+zorX22PX4SWHHfmwzw32yR+6znZc31C76aVrYNJfpfY7Kl52e/jWs2phxO+42j73e8e+3r2Sxrwyd
#Zmee3Plgfu6IUi/v6L2ypvs8qp7ity95+bn3bQ/t2nio/YeqSVVNc+s0HXexaOeuk3//Yz2d2fTjrDD1qc9zpr1+7fXTj9Xqn2lT
#Z0fp139/ePSk2tqqS9b/WDPHaAoy7pnm0jj4WkaAtyEm2q+9T1Jh1Qp3gsqZ3sr1pxfJP3oOvdSlydD96+s0jfOpeG2S6o/gZuGt
#nCukDCr3/Pm701VGdHtSt8Kw/etrtk9p6zNlV4fIfdpLNUJaDu5lCMy85vVmYUXf9Nc3TU8q+07ufmlr8yOjDw7Zc85tXZk3XQcf
#L5/5rFRM2yu+e986jbyTMtO1mdfeefOn1etS01D5bOvZtQZn0y1/sn6oraM/Ng5qOIucc2/7kfbKH6bcrran/dWUpjmZCzJi8mes
#73OjbsMJpdeNvjjyxM0TFkNj74PT/ohIKbNljVNOYOZvsuPHjdUmxKqen16Ufuu1dPKJ+Hfve7/2dW/VaOylsk2DtuzdUuHc1JoL
#MhTV4tdkz9vsPOnIiWsjY+Z77l0/63DOwHeXTr3a/GDC9bwxs1cbhihDjje7PGPuu6UBufXc/vHvmZUWWqkwO+vr3oIIfd60ojse
#tySdPmS7DGqfadKNVJ27eSt/pqrHo7SlLVurh40M714hqbHpbLvr48qfSXt/447zpAxLuVlr2q+rUH/puBmLncrfv185dXdQRJD2
#YJKnwZpTeKTWrNuv/5q5+fbGuWFevRtou5W6NCLTJzHx6JD9Z6rrWq5scfjXcsdbOtHWDfs98kNMQQ2Gq35WXbpaL72cV1aFRymf
#yjWcMKKG6tJNjwF7R8kGj5zTuHORS90b09P9qhzxmnrvwJNFy1c+blG7tfH5o72h4aVumuY6vezvM6uqr/XEtNIq9ZZzb0HSqLo+
#8+6deHCju9MWuvHBqrWave/aquHa1j4nrr7/fCPvS5Vyz4+eGDGwUtVDFb1LP5WGvf3zQf94J7Dup3TnUujh0pFL1DN1ud71m/zz
#iP4qG7w9UxuwsFRQQ0n7SenDMovOL0huObjNyL43Tf2chjX2795k94DSf5YdeafBjmn/1HW+2W1S6VF7bhWWbfa42SvPWq2Np18V
#LbjT/a9r11Y53ygYZAn+1annpMDk8LLlZ7T9JeboxdIL37Z+VnC9Zodgna+71OlA59TUL2e6h/54LbRU9suFcddyfljZrWY551p5
#7z/tK/fqzNbMLtK9lyrWPLMi/dzPEQsiBlWdfOvxOsPTBu2StpWeUH/cwU5PblQuP2zvamJlmSDjZLde8vMrezX5s23kizMdCmIn
#aK8vbn5ybnhBVEyNu0v/3KrvX3Pg4pS9kdJLW6t/eP1UsmP54VGm4b5UYc4/LYN+a+u/ZuaTQWto+u2AlecePhjStHVk8uq4pBav
#XaTdl85cerHf57ctO/3sLtfq5pXeNbN387FH0pK2Hkx5mpw+ad/kiC77IpbvXrp+edy8FLcy8SOsaabPs/c/PjGg/BLvez8NOzPq
#Sd6XCs515WOu3/jnQK8eq/b0Nd87WW7b5Jafysp88v9p4vXDbv21MQvaVz20bWPqzUeTnjwuKh8U0m9mZEH4H1ffj33++E2jgIoR
#Ly4mP3AJ/NkzaajH6RuF+kPy47N9q72vVLjlwRxVsvG8S7V+1X9/v/GBx55n298sHNC1uu7ejUFfo3r/fHLSHHmjK5V++dnj9IyJ
#b/xD3j45dLyInvxsWLWbY0BX1vZJjQur35XPDVbOML0atupKz72fr+/cPtM3rcWAgp4dZk1pbvr0zvvwifXKQc4fq+ZUe/XgZI3r
#Uz3Kjryw5+/8Ct7Zlyvfzf6aX/hjsM/Xa1fzDesruvw0t+H9vyMn9s8/vSwxs3BbnybPG9Skf5oTYPgj536fVusGNekhHeFxKa3m
#pxZ+qyvMcPMs1A5b1avD/eN91nxpFB0dPTNooHuLcT+NvXtXFRTSvt6SmaWzIqgm8yVz6/lkqo/PHlu6XKW+//y+PfPZjlofPn98
#49r8wKoNU1ukTyu9Y0z/3zpse1l7ps/56j1bpVV7EjcveHTc0yu3bxdUMqkvNXsTk/r8efrlMWv83DIena2988PrgpEjX18op0rs
#Mjuo8bEZ8i0fY6QjQTPbt4c0CDAMlSftn+TbK+7Ib7kfXsvaj683YpbvL1d2XNaWWt5j8NzjCyLy7zfM+3REMiW57U+Xo2seVL7f
#0Lyqb6m7PQcndKzRwE93PGaP1+qrWzpUbdL+0Bv9pfd7/YOaxhUdXUGtvrCvRa9Vz5O3mcuFbc9sm7KyyzrVi8jlmwbVrFlzfdaZ
#0tPc4n/cue/3SkflBV06T9938trH00u1NKi8ufTp9plHX8/6oeJaF+2n6YO+kHN2pffebN6W9CRXlnDs8fg+f8Z+bNjXOOrghWMv
#Nx1ZdmpV/88j/mpwoUypUmdb3lyTtNM5KSRz2tONU8os71MqL/8ceeDR5inDF6jfJc9cGb++X/01vXclXPgp5/3AKX9tHvu2pkvd
#uy8WhcUVbFjm9f7n0VPCh122PiYfjvlzX+pT96ADzpOad+65pt/GuCk/j1zc7MrWz3UktZ5fW+6zc0Cdsg8G7dx4fvar9X+9Wa3f
#lZfb9eW5Lt7WD+7kM9Xo3ScXdPgcvLnsxXUXzuwoPWnsVPWyhq3MvRt2fvN5z5fP1Zt4TpxFTuh54OySNbvrTin6I/dmTmiduTmV
#l7148c+B07eaXh/j439g/E+BpwfL9i7rXHcR5bfWiTpaXnFryrKOP8t3FqVnKhRlr1gfTHh6s/f91b+tTvnkObXofZsWG+80DssZ
#3qLK41sTl1TV3pZXmt1j8M1JXcn9nf8Oo+eG0eWrPL5YY9rgpo0iIiJIarOqZ3jum8pPL286+FtiQNuxGnPNhrUaDp1F3+9T68vT
#KwPbakz+8k8Bplf3Y8tW6LFXXmn1L8uXS+579hs3IOBgD9n4+z0H327eicj73GKsZHvnOh7tFvQPm/uhVnxV6RrF68KKuuTTfzwp
#HD687Plfa4yL+LpuZdJvCk2nUqVLv0w5tuVp1oN5me0OTdpT7WO61y+x6y81GqksN297xv63nyvMPDE///nNUkN3fZnSyP1LmbUL
#65c7PNO76cDP+ZJP9JhDG0+7nx+yLSjQePmHCZ8X5V9cuvJcuY0dxqX1+m3x0V7JN7/szD1denZXJ2OTJmvG9pu4OOrAK0OT8LzB
#B/95XDH9ZcNDbRbVGDvDvUN539XPR9c81C3Er3ftv9WdVwysGRPw19CozsedI058Gv/o4r19nmVqNbw4c1v4Q9+6S3qvvz10amSl
#A+0TfnOqKYlt8965dtRvU0/c2PJPYNDAmG1Tk3oNC/j96ZUtAY9TVny616uef477+Qlzrp/I90rotL99bPULG38u8v78ceBI/9W9
#hjT1nOb+qtnf3uGrXxf8NXOxrvnCjon+vRZ2fdqYSLuguzTor1GmUM+D4x7Ge6tuOpmm3Xngfef0puxKZx6vX7/+B/ekHzOfXR3S
#oNvain7WgzEb9+2ePi/UfKvX/Gc5b/+4P/52/62vH56rpF7Tt9uy0n76C5Edn9e5c2nBIOeMiA7ZmiatP5aiX7ROTvjS/XD7+Kar
#fIeY331Uvr1eZvHGiEZbpnkmOr/9u2Xd4OPZc976pKpbPO5GHgwsNyuydpljRPCHOueHP+o5WOurnuOfv+JH37oD/2kTMHD3s5yx
#/SUHZvpZG5wfsarWYHP2w4VR49bOCaxYe2KrR8N3pF8ZdKNFzryrRQOOefQcX7HdL6eulxl569496mXwrHAq4vPMee/Cy3bYOUnW
#bvp9qeVArS63bz/vU9D6z4RZXU84e2kOT1y8r4vl2eVZlXaXX6dynpzduY11QJvazs+/fPza1jQqyyf33e+bZ8cWmqJc910kx84a
#/MfszQM6Hw2bUaaHtPXWdY0Xpzf1W5J3Y3ndoMuLO7z9tXDQ111H0mrdiHrbr4r0V6da12PuBfxRz99cNjDf74enRe0nNpDlzDtZ
#bgMVv8u/4Pacm5MjJrYZO+OXapsPp/bbkNWtyG1zt7srPU74vPm7qKBthWr7znTdv+v3fxr0/qfBo8r0y7vphysuW9P4y6vCFQvj
#R78v9Xn3yCn1FhL1fSmfOQM6HFg9TRrfe02W9+sn1ypcOLsmqtI02fv1XXtfmFz2bvaNR2/r5j+e8cS59b16y2PnD9/bduScHdcL
#tb7jmgS2P0M3ioolWp5vOeNK5yZHAZlf2Fw6+LeLmUdPagYMu3x4TMXCrVsDL2f+VbZ5t5hSPqrDxIAP1XfH1JMcJ/ouSfpY9fCc
#nwPXxhX03L8yvsXo/saiVdOLGho7gAPndItRaqf40+PWd72/a/ubob+fGjcnqOLcrzNDcmesaDpszOxuiX2XdY0ptSJ6Tj0/ZdDl
#CRnNap3strtNU9P8tm/NHxJetGy0V63ae0a62GnWRlWN8e8XxXr++fpMcJkK1WocDz1J1zk+x+3RaelPvas+2/VRPq11jXILf7yv
#qJCcMPp4/U9fZl3Prfa5fOXSD1pZ5OuMzxpPvdixztI3lnWBY6StTeveTal7q92Z+Sdmb63+UtHq1OjKdXdv/bO2zzBVL6fLL36u
#WNkve/yO8DkBusEbW/teydrlMvDIL+MfR50gHg1YObx+s+2lh19Y03zAlyfvPmf+cUCWLLkxv9aH5203fdhSJejUiYXXQjJn7mh/
#feOANi/rXpqeVOr403dNm17YW//hld92mx6dWJTb0CXHI6hZWXPT1aWXpvaf7Fw7oubOXQei284/cjHM8q6jKWWLIW3Z0WRnH1fJ
#hpZ7Rh5vWF157mCVyC2TNnaf0+hN1ybyXg/OLBkZmTK/XrmXD0bOPbzKqVYF+cFHPdxuPTld0XuzxGrtubavfGC3+zmLQf0hnz+m
#vz+7bOv8iNw344oqu6a6JO+qdno9Xbcw+CfXpul/Xy3aOn/387c3gnLu/nC33ZdY0+aW794vr+FZe0jVXR9e/zBsNaAuW5dOmHHy
#ZGbY/nWPCzr8dfbA2HfaP7yGl+1RcPXwrsYRWaYmNQ+Or72rX40B8hevLr3QXD78+/A6qXf+OrMkMjp3WfrsuBdvmjU/8KHZto09
#E1r/0n3IFtXcZYrON3yvu53w61cqJqWzcqR3xMR917afdSMm1mt1WVe/Hn3p5ZdNp9dEViwsfWl04aGJ3n+N/DLl0McHr+u+KdOQ
#uuWcUnpOi85vFm9O61nJY/jSs7uUkvlhv3j1K/UkZqIhqdlyc/c/y4IEd5BwHJxwax91ixndZvNj6bMq6T0KSwcNrnjn4M0P/zye
#cuhrkK4sOMSHNI3oV6qh0709b772z7nW2CX3SYXrf0eDzoNGJW/VeSe6fY1dERi5N7Jgz+S6RyR7n2U9mhQxNaRyTvbnI6emjAsa
#FFijy5RNmZPOjWz09lkrU+9Nn46tXqqe2OPjh85BZcLLN3Le9aBql2E7Xk75o6r3110/jxp5aumRsVHliL0LksLcjt7flFez0ZFV
#9PofPsYmrp1suFro8qTC0gv7PXvuKDt7s2Z0VIO1o6cdvdtyVreNgzfkzp7Xa/7Cp7/UG1tzeVTNFdYXmbXqDlzcf9HrFbN7vX9L
#etyt8XvWi6F3X3weWG/Fwyfrb+aFj6kU8SK7cZNNLQ2tth1cXHraKepK+s6mKyZ1znWeNG1as7lVOhaMKV+5sU+tvssUhn8OH0v9
#8ToY2+nV0uF/JC1JzBiTvjxesfJ82umuG4uUA6bUDaxoPLi447xd85w2m0L7hj070HfFl6TT2U5O1fpAXUDVL3cOrZ9y6FzF9dsq
#B282d496aXb9MOuAd52IWy9GNrm5L+ne1xVJ3bqsez0uo/MvV3dnVms6strU0PkbDl22/vXD2vXPzyufbG9QbVmrzAf1DzbJSUmf
#G+V5+tq7Wgl9zWWoz2GLah2R7bk1Z8bmPk+Pz/H9KXbO5uoDykUv6rVg16jeW3s+b6EdXf7x4m7BI5cvvn96yOOzd6Nethp8Pvmw
#d5d6V6obv1jnLH2XFxzxLv1dx7yPsZU049sGbnLx/NSstzpuftCEqJ6WXRVXNR7XKTmh/CFvU7mug2u0Hdn7z7pjzaMO9I1OP1u+
#l1O5rNd/1RhRubE0e8fu3RG/Z/TqkJyUOsxtcOSavuuvrnqyXn7t96aZrZ2C3hS4DR56uuL68wHrpoUFZHxqZ3pSCdRe9GR9/XPL
#oxt38X/dNu182UMDQSczvZe0v53x2uPInUENAxru2rVrXZ3+dQ/DbTEpRmK8oFgyuNub3jeeLU2dSJ2Y0YgMy93Xt7D0zBFugyte
#vap71/ts16wxzmXG+k/yjbq1L4r06DvObUqZoojaAwaf3tmhi06xfFHq112jyKYDf1T791qe2jswNPd+8PKnRZ8/ed1eviD9/m+V
#hrpPilnaeUFjc9Pc9KvvK9VZottm9hz0y5c+Te6emljemrZ/+vvAls5TW0yoe3tQvyGy+NQd04aNq++7KOvFj5G7U7bda32h9s0l
#E8fsaPFpZdcrS1v+uWrvn7M+HWsHxcvU5QO6Wru1knZdSNxt17NcVuCSrJ+Of6jSYO+f0R07Vo9xSV0+8POIxRePHxnVdFKPUnEL
#gpvnrG0wp3beuRe3u358+zRqaU3/SoNqbni1uny50f0B+XJHrbx7PuR0jfbjWva4+6z64vblX2+U58Z0TljbQv4pZOCNEZc6TCQk
#G3KHuO47kLp1UteBR6P/+OOquoIqYm/9ilXWuuScmKsLci6qnZKvGq751HnZ0enZ44/XPT7fv+YDVUCFhlWuJT4qp3NetWJn+v6c
#w+OfOFev+7b3+cqLZ2bSbxa5TZ4yxVU1sVVNF92bTJr2zdY/ePN0qO7weNdDwybXqLH44oDnKb/93PXNpbPNx950H36heuAg16YX
#2lSs1c2p76PD91LHnNq9YtzcbeYhr+Y2qVBFdXLYyNPBX1rRi28/mB7Tv+mr1GP3T3QtHVXr5rb6m/bf9X+09Pq2tExwGBYpAS8w
#9MLDM6u3akLPbrkxsMcfn1xqjZ00ZlytGy8CdefrFWXlne58uHJw+qd6mzpdWFPU9dTxW71UhT73qy2aWVrXr4lsdr24ObeqzgsZ
#9qoJ2VM1ceV4Axk2fPq1WmfObF2nvVNeWqBwbp3+PH75qMBRaRd2LDvdquDVXCChkiefzDrdIOHh79Eb7y++CPiGZttWLmza1a9j
#3t9P+iz+KbSl859bkiqYvihfd4m49eapRjM6bt72MTMsLpVSFu3bWd1SvlqTqPiC3zOqtb0xMAIcibecmo+pNSN/WMImTXpej2Vj
#evzWB4hd1c8+0RwtX951Xb9yvY8ZE7fevnvkzqSplev73Ly0cuPiRuYRVeurenSI7bCwsPS7d+9uT6y5fPjv736pFzag2cGJjcpM
#ePNX0ceQN1Twtak9v/wYFV4rhmzeLbTL30emBh2f3yrpdbDHoqtNl4YBPnRJ20NxYBbrP9+ILyhY0DWvHKFZubRHa/eqmmfzr61I
#Xl4n6LKLYr96UcVCmebN16W9a5Av4xv0UHU6R55aU9+33W8//9a1xonEgWUmBGiu/bJ2xfOam26vbvOuYo81TmWflnvTMKgsEHqm
#Xlzwx4FbG52HFA582iDoUXOCqJbxpKiCp+e5z9t+TdrZ8uqhd5IuC8snxLsNUw83zDsQsvjduw+Ko5an7/cmja+/8cEo54gzK/MT
#//whYtEqhbfqsWfi771f56zsvqzg3vQlcZc3Pxu8+MAYwBAv+Dq56dlKpY8NGRCzMOHs8i4T5+VWGzU78m6rFQmLGi5e/OvgJY0P
#vy4Cxf9adHFtYmC3X2NkPU58Gf7oaMGBgwdn+xdospMKVfV35Oft6Vbh4dll+xcvO3Y84MVfZ9cPezR8QVdqZ6hPQU/35JY585y1
#J+bsHvXzx/hSte62r9l9V7WXYyf02aEZ0mNZk3vtrC26tlQ5Pw3JKgsZtEYb84q6r/59Hf3k1KZZG7st+eVd/fF9YxckXH1t+HvY
#okip8smz3V8jnwZbow7VkndvVy/z3ek2prsjp/Tru9mgzDgeeGLOrZfLOnd1W9XD6faCYz/feviwoPuyY6MmLDLnJITd2lewe+/k
#agPOeyvOazYqpSPS3m9o3tV3lf+Q/tSFq+9XNG7omjNvVcuLa2uPiZjQuNyhF9Pk8XXcLq6peTlgdI0au6o2ujyw0uYlFcsR+wJ1
#6gdOtw89TrD+2mdJ+aCj0/csmvbpdbx7/99L12+3OLNiy2fgIKmiKXWisFtfP+2oYz8f0B/JvJ5dd/WFqNuPV+04umnJwlMZf17+
#YeO+r6cifj6zoU9NTbkTUqeo6gFrelWo1ji0eqM7Dx+Ozq5UZ1F2pcZBqcbLW9ImbntV13nB+nrTbkV12z6xiVv8rb11EnZWHFhz
#TIOwrJSIR+fXes5WrT338Pm9i8n7DwU2ynh2tVTc5frvX2ksz850fqc7MGriRECiOtf1bN1Zo672vGWbP4cVjF9/MjL5VyAJLUqa
#c2FxVGHQ/UVTr9XfeH9hJ/9X91quHKd81WL8us9v9acbzE5wch2VXaD2bb7uj71lKpxe3EdZdMyQNi/zxolR5Z4Mfxu/5eHmdo+N
#fVM2Dl0We3aoWlkxQN974qSFLYf2UU3woY4pPv66M/KrbIJfy4Q1o55uf9u71sAPTx421vR4V/HEr04r756YU+1Yz19nJHSZpug+
#onKDUUEFgdr6oRZNv6CwTqrcXYtC63yu3DnukGtAm6LENo1yRlRtMmTEePfcdOn6Zd0+/x65NddjSXY5YsXgCy97pHUtNNUYq5QF
#FCyOffvkepVlo9Y8GDnxc/+3vzTc+b6Wf6/oZ/WMxpb53eorJTHt3jwZWOfQ/PD8Ts8Pj+7x5tyPcTXiogNdN+X4P7m++djt3r/v
#dev5W03Dlh/DjjjvfPBlxvOazT/veN6mRdH2C65tR2R6pZ+t5d5nV/cpz8+1/zk8LbX6wH3a26MX+AT2u1Peul63ctOlqe3Hz7m9
#59YSzY31UzW3WnR4vnvc7cj5gUtC7g79cv9k0nby662mKy4uXLT04unUK2vS297amFHHz1o1peKSM5BpbJ+QUOvodLdqXXy3rSzb
#/PagN9nN/QyXa8mOHAmi7/tNmTLlZscx6hftNuftavGb/qOk8YO/g7fEtWheazM5sq+v+lTU9FVtYmq4S+p0mxn9bD450+vke+dp
#raj2Rx5Nd3ve531rlxZRzn02qA7cXLQ//fnhJpEn12873mJt5NAurbaP/BI0otSwEQR9331K/w5qqmCPT++NA5rPrbE8duXiDVcs
#PkXLU6sd6b9gTdEGX8/DHX/5YdBiavUF9ZJGm0vLXm3VX6l4NOyvQ+TQDZ1vpevccwqsqXOuXS6sWbNM6gHZjtYzDk9uWuGXk3M9
#EqavG/Hx7bOKmx833b+/YFp48IsYN6vzO4Wi9rmNxotrvXt/7HW5UvtuqzQFp8Lr5pi7lTEHn99Qvm+r7RmPBv8UaNhTdGbbto9X
#zz6cVEXeerXxysIb1crMemrMj/w8L8T7UiFZ5kKH4Xf2fMnfN3B/nYbLnGrV6f5rXjkgd8mGj1EdVeUbCwoLgyo3CS4LzqkhbnsM
#5KaTN/+mGwbXGjZ20rVT1a7ty1kc1aCTR/fxX2Jj6gPh/fbpNo/Pej9d67Ts2LQ21z5UGT7rep1FXai9O7bVC8yorPC7MIiIrZce
#+eD+rY1RFXr3qnyj4uEZYSHBmQ9n3I9MvJvuGtLq0dHa0XeeLnN69vXZoCdl86qYH5wcv8kr7aAlZv7rsWkVv1Qa59X+r6LdRxtF
#tOz4em1ivdNfc6dJP9S4f3zDzruK1q2d2k9sVG1b/UCy++zhC8ru7n2rmrem9aCfaw0steTFjPmzJvS6uW9py8gXrlvcSvf4bcZP
#Pvm6IWV3/9WhoF/i8+SF5x4aH8b3s5TLmnrlzKnai05XyC73doF/wdxfk7dX3bZNWzBSfervpB8eX456d6Xj82d/XC1fgSgK/Kv7
#zNKFQ16VDv5n6a4dr6c3TwvYO733kp76ae6yxg12pOz61H9quVcPxrzp2bRa7doVAP/c3nRrSoWxrwKafdR9fXznwX3Djl83Tut/
#7/bdo9Mr+addrPHoVt7rTucfvrhzqKvb0t+7zo5yfnO57Lkjhru/nJD2K/zr2IO4ecF7r26q8UPq0EFPWz5bklI1ILre1Jp3Ppdd
#FFiY20RVfrJ1eTt5zPW895PGr63aa/GXveMfX2hUp+hKlUcLzjUpte3VzTq+t873GxJrrTd+5JQf7xz7YdFoWXtl4Xy3wSp50g5p
#3spSlwdJ11c4E9zs1eukUeU6RXeqWGHkncilRz+NTSkc/koX+65SwwmdW2+I8/ma4ydNLhf0677OfQatdIpu/6tTw4s3e/T5aizX
#cVxEx/U1bprm1mtzcNaa5V8+9Y2M8ZkyiHgrDWooGa6acyTra68FuWFN3V1u+YU0Saxc9ZCM3DBvkun+n6nXO42OiYupf9zvngyU
#HaqafeTNwsAFgZNrfnrtHNJ4fqmqh0Znyc91WXI977qqe2iIa2PS77YLKDn4yMumLc7tj02qudo5fc682ltLj7xTeWk92dc/VR3X
#aPpMu3v33eYnV6qbgi6rD1fqEzC66PfW0RW7lPfd/bABvO2aFf6q44gT49f3rufWymWX7GNshT23NBVbbDwyuot7z9BJ3ev/LbvS
#evi66YNTe18a8ketFzmRo4/EJS+JaTGubkd1UZmxBf2XzWi/41jc6aGawCpxswtruA3s8mu4WUf279X6+btmS7vG+0b/c2XZxfKx
#HYMOzJg290nE6f4Sv9rp7sGlfv57d1KpD5+ulZ077taJT2dLhzy5HOfjHDp17lqVPjhvqHfz9NFxz2bELj83veyhAYcPF2W9qPjp
#3E8mz/D6Fy+tGfTkgq/l8o/DCtsZShdNSI8xK/IqvdmzSlp+Ts1b//wd/tTi9WVfrb3vB4ym/crM+afmzFqBypMN5jzaunztj8P3
#bl8zJ25r/+XDnkbJWjX8iXx874Rqyfo6P96ptrf92Z41pM0fNvAdff/hP+WrvVGHq1eX+s3rj/Qgv8cbZ+U6+2Y38K3/6Sftngmb
#B+94WbjtcdGR9etl8WWX63fs7Va1xbvzC8lo8+J0opx+X9VLu+vNGNmBDCwcf7pN3dJVD8V5VVLCy91B8zcqIhr2qnLy2vZNbUYG
#P+km/Wh0Hrx/fYOmswInR7dfEzd2nrHqrKMuOffP/fTa+jp4uE+sfH9sswkyKTW54t3+Gb13hTeXNd/XYNCutdJu1aZtiw0rU7l8
#0uBuI51+qZR9qUnjPddHPfdNfGx+eWIT7Xp3zmNTbGq7WnN+WHIpf4JCnT/tpGZcp06LfT6fkpJRF87t+VrGyenr13YxJ985OTmV
#h0J2Gae47ZLCn65d7QTv6aOj4tr9Gpky9N++/xfZf4BH+QD63+6iZPsPH/C/d4CN/YevN7T/+3/2H//9P1KpjAgLJ3KdJVaaImiL
#Wau0SEKclUYDbSGaEWEEDbNVRqVVTxks8nQrZc6Op3SU0mI0S2mZO9HsG4Xa6HSgHNuintQaQPlmUklT+CgBGTrKQiSAtNx8d0JH
#GlLBo4QySPALzWToKfBgsOp04JE0sakWrZ4yw5fEJHeCTqMywaOXO5GhRU+wONuvmVJZlZQKpOpJi1ITS6m0pFQiNZkpNWjBg8n2
#0BstWqMhmCkuk8jkqDhFhzg7e3oSHv/rP4SG0plAj8ywKFrJQi8egN6QKqWJiAhCAjo2UyYdqaSknoktQsNdJUmeqe6EEhaU5hKS
#FpJg8A+pN4UAOElC0ZvOgl7C0UsqfnFFL+lWI3p1lbjC16a+rUIkRH6iMknGrYsFDEOaBkCHsYGAiwIBm5CYlgRHlBZCaNWEFGSr
#jWZCiislku6EIokwqokuigFgseVg8c1aigbFZKg2LadNOq1FKsmVEG4ECf5K8sHUBhi1BqlCFgLAbLGaDQQdQuSzAzEYM+PhWNA4
#2pEWSg5SwJsn4Q2IBWgBLjNbmEw1grIWGmMwQeBU2HMsadGAtcuSAnRAz2qdESAsbB005gHqwLkTaFI0EUoEeMnY0YDhWmCnElEB
#3wAvmyJ6LUTSXAKgi6AHGowUNpYvqh0U4GdbXWO0moupj/vCLeApqdgp8YVwk7AI0yooExZGeBMRuP1sirZQZhWZLZERwTgJvjA9
#qlDzHNRVVjNcLkophqTepluQj2bHTk0PpuYtnJZVrqNoWiIqIAatVa5nx6BnpijM1OBcjQgmetwr2PrB7DbRE81hktxEquIB/bZI
#fQC2e0lk4mmp9QivLbQ7YUQIZQCEIdpg0ckhZiUA6tHeaAY7XApJDSwjV+N3WA4WAVWJlgjz+K2isnA4B9pHjecSALRgaxkA/QME
#FExBbzRYwCQktMZotoB3uNrg1cdDpU3VwgSAPVYLJUhCI2d6ILP/B11kU6RZUEDQnsZKsVQmUS6Xs5RGliTHdE4qBRtZiQAkJcF8
#fb3BPlPKlRrS3NaootpYpGD6RHh4OCSugTIAeoChIc5qq0EJySVBGrR6KQBwLlpzltTm5REumVqDypgphwUoFgtCCIs5G5QV5oHa
#gAYQSkhsCWkyaCqfyOc7sBhJ2iLV06kyAXJSzDmCMgHKEZTcQmVZ2gKwADoEKT2dyuJh8WPKBdVoS7aOkhtNpFJrgZD3DuESLWbS
#QEOkgKcSetFBtPDw92ru7iWThBBKHQA7xCSjFSwUHIrcAsbCPKFNZWGzmaPWQY9eYPbuhI8P3NEcmPLB4IWDBaulN2ZQUgqUEQEv
#lwBbIJWy0MEEBbAYtxpMJILV8kb/e4HjkRt8H5DjC7Lw/94wD2x/Eh98cAjuBEXSAEMAMoEHqovV0s1KqjBC5TuTdLZBSfBrb9JK
#TWCrgpPAqMoWrg8kzbmEEoAeLIeW1NEQV0k95WE0A4Q3SCDNx6sDaxIugHhZDSpKrTVQKrguRrmesmiMkPRJunaJTwDANso1FKnC
#Rz44BZml9kjINlHwoAPsq06rRDPxHEAbIXmW9PaI6w3zvGF/oAHUVxjRKb5LnJxGG0GrzkYjkGGIM/wCKENmklpAQyiAk8wUjYhe
#wbNRRVpIlsVg8JlJwrXMcjgAqR1W8+Qul4BMtxVAxSzHT+64iXwHUFYaTdkJALmlEMMxkHGnEHwGMkObSgJWS67UaU0KI2lWES1a
#sCiipeMppdVMIWChyswQHVSTZ5q1gC5yHQlw0X4eDOMA58xxfmC1AYZF6Sj4Bo4c0AgJkuDutJDyDFKHKBFMRgl4GyhpGnYJ19lk
#pLUIEdXaLEoVwqKyF1h7rg+4VnKw1JRBJbWQuGUaMZtStDzMarDFqSxK2dao15OguATCUYIWBaAZqdPBkqA6s7EQBgjIjo7uQFkg
#V4TwEbeLZ50BBqszKkldPIAfmUrJwe6LtlB6aRrP1YAyGEHAiawCR3CGDS5w5zaCrrDXeNxrBt+rqC+a7QsWKYls0hajSYoaQXwy
#PNyiSIDMiGaBY5AygxWBAOTZaIbNgww0QCH4Kzeq1TLuCcJIyF4Lu6MyANsPqLQ7oTYIejVZaY0UjpnpkCODsCcXbp00WhUgFIC/
#xLsGnG+QRQPtcyVIlSoqAzzEaAFnY6DMUkmGltYqtIDDzAZnlSGVAhu+pMbZKXFTAzJvmox/RB0DHCqhR8psNkK2jcK9MDwrgAY4
#KhANxgBEXRlAUmocCUUXgAmS6NgOEpys1BlpwJ2JXqQSOZkhAcesQYiNkGxbAb1H0geZQUJR1Q1KQATgeVgmGCKj1KRVuYMtrQcH
#QA549/VCcEgJpU0kIB86kqbDXMkMVwJtuTBXDw9NcLNcwBhIYR14LoIGZPkhHh45ID0n35TlGt4sF4gnUoZbYItJIgADD5L0Uhli
#EBBzILcYe4ANaW4LjguwAEyx/Ga5oFGA/SmhWn0qQZuVYa6eeBKeoG2DEvAWPbpHg81pMhogvUBDkA8wpboSpM4S5upKqChQCHQP
#xg4Jomt4CthIEkl+qCecV3gKLzWY9bEAKmGQZQ3nmUQ4EjheY4wxkx0eL1n16weFKoknKMHIKfDRBDeNQPzqT3rkeHm0SvZAIphE
#wrFVneO69IpDJ5GKSlZZaYsPGFs78EtERwMUAYl6LdywIDUWPeBErQGInAYjSI3GTzjZYE2DJePAD04AOGA2gXUDiV2YR5xBGpRa
#AC6Q3gY/sclWhZZGqfBB4g5oIUgGVS3aVNhdT/yESwN2QAvOe0kC/MVJSkAb4BDawl+cNAAwBiClE/jBCamguA6kdIC/OEllTLUY
#M2Fb7fATSFbSyYBYaJWwuS7oASdqLaQOcrHR8BdxABz1AKK4xZINFlGqF3IRcG8xqwsy8O5yMXAShUTCMhFoNRINSVwWmyAQMQz8
#svaXqqg8JZ1HmvNU+rzU1Dx1dh6p1efRVrM6Ly0nT6ExmvJyqDwy0yRL9kTrziCJZyJEBSAqaHWAoEkjjUZATg1QU2CSZkLsy0z0
#SrLZEW5EppwGvAkl9ZYx8q+EkCB+igMAqN/WqDOaaQQAZvoaMH20SzkQ8AdMYoqG1knBLs4n/PwBTx7UXJbiTjCJUg3o1M+LYdbz
#CcCwEt6wRJKIZoNOI1NLgjgg5khpYqIBKJEGQjTQECFDA3Z5MOHionbHVCaYkKrh7leQyrRUsxEwdx5aPdwPVrMObDXYpmM6oJbl
#S2TuaKvb1ZVAYKboAJNImj0ANqrgBpB6+/qrqFT3ZrlKAPt89OudBEi5hwcZzCSmYMaKVUOZkWSoBzPSwZMPLK+QoivwNBFoOHin
#hKq0GSwtRS2ApnU0IHMKOSRwEYQEgkCCSRRHamE2esx3DQ9VMFRViO0yQM4U4aGeoHVA0XhVSGyXdlHJ3XvDcznRsz/YaRANAYNs
#pUmdBKwFSARbCiZqjICDBPQFJ5JmlEia9bQZ4DqTmpqKUlOthlRAyplElR43qmfec3AnOWw+3A0oBT4waXBnoDT4wKSl5aCUtBx2
#CJm4CPhlUqRgcyWDTZYsQ+la0GOSYPfrAQ50UQOZFCEiUpvIYRq3m/FriEMspeHeQ6goVE6Zs9yJNKSdYgApw6JgFhATwXlrkAnV
#ErBxOVRSpdmoJFCG0aKhzHi7/ktqQKhwsIIls2X0dUZSFQPypEo0eZ7RdyyWSFjNvdY7yOAJx+9gO+Gm3AgJkkkkLBE1y42A+bFo
#zMZMKH8mOJBdGHUsbIARjgTsK2wE5iDJDWpsOXhyk0CpuCbHU7EPjJAgZ/qAPyHFl1Jp4dQT5MnwAZ7qOosZkf5mzaSSRCg3eUAQ
#JElkHJdrwBvaYKMVACsvh+UBRyqHVRiez07kYidBSwVsOKORxnCSFr8S7PLSDMhljsVBgYobCwH/EnYBvp9QkGbB4QoOeUsClga4
#LQQXD3bOKG/TqGwaKcJoTsrVIMrInrCovFxHGVItGiIcKv7AGRMGeUwkfbGUETbhSmhV7BNp1pIeOlJB6SAthMQPbCsgfMpZIAHw
#5ENuE7cPj1El5l2NJjR4JDaydZWgLCiKWGqEOpDq4gFQKob0MjQWzQVquQF9xU2Fp7CHrwQm4mqQi2S0lcyOI9iJCei9SY/nBH4B
#FbdaLEaOrTYp2CzwYMk2gbHiAszcNSQNeEqrCRwalMHKJFJZgIFVUaCamtTRFJw/mQFGIEeMPPjFvDzg4/NFPLxBzzLmTBkZywyH
#0hmpSJaJNGaFuXoRXoR3APjfFYi6OgB6AyAG8EwyG9PAAJVWsxnsB3SOs6kemVqVRRPm6sMlwGNWSYKBoxNYlAzByKaHh0L1CAHm
#EutLBOj8CfCfh7+rJzjTwJjAvxgc4Qi0BCEGq86VMBvhOYmAEx5KCl61QMx1JTRmSg0kBz3FzpzBHxVJa5DaQoKOUBLkApiQKr0W
#iV/ss1xLIxmk2IZRKZu2URrbLit0FNeCxmIx0cGegAJQpF5p1OutBiCSysGTp8lsBOCnEKOD1wwVAkjM6OzCXJMVAFHTABQotEpG
#E5Q04dkGr6bMlNlmZKg+OzIWE8VYZztKdmMamW1pTDVaLTbN4kTcLrNcmCNh+RKwePkEBVCV3Rwk2266FcjOHDRBQ3bQpLWpBgE4
#Ed1GmltTd0CwtQYw4Y4JsTGQ14WUuAT5WwmY6DQgS2BiTYmvK0wKgSDOC9ZNwcbkryRMCp67NukZHbJJD88pXm/pYtLL0exgz2Ah
#DRZAQGmpBC4OLCnKthhTU3UUk4mUhGAkUEvTxgLkUABMkCfa80whoZ7X4XjQcPUQl9F42FGwM5TBiYhGwmgOuGE2Yyf/jdFIEA1i
#j2rYrQMochjCaRCh7lfiCf71JK0WjSdTwB2cZjI5OuVYVQ84YPkb3BAi1QglbVa34QAOpMN1JBMhivUHOOaaxK8nieBDQWUx2ZnK
#Zt6UFrOOf6M1WrWFeSWZdjHbgjcf0su4kFCLJ4AS7A2CDt4v0b20Fv6QB6zO91aAUg6CGSJ+jFAHykEuwmH1EFQQzgy+ixtriqEP
#M6FGEB5pckh6DZySyVPCX7OAs8RMwe3TjlKTVh1UjzKgBw8OriWYaxWdUKELRsiwYJHZ0SpmSEiQ9ZExGErpZKCSnFYCsqOLNliM
#PcEZxGiv/G3vM4jiRgVbRnPPd/6GCo5T9QlpgBhptfguVAI5AAnis5BOVWLISkZJ7jx2IeYCDAFjNMe52uXzHBSYkBGuF2LmvjFW
#wFOpsEZENEyQjAcYRYPjlZIUS5F4ClAiQfoPCIEaDJZmxo5G/y+xnAgmAo4TLCm+M2E0LsXjrRvBpQFOSYP2JcwE7CWYitGcncg0
#AVk95jEebEMKcXtQu4zfkqTYPkQCoI3qCxfKlrsH2GamaE0sJeKIefGKJ21AVhZTM9gLR33McG3YCxy0pj5eXjgNXeZwT8y5D6CA
#CCFODGGNVhAzB+QwINl4QfMEO8MHTgkBaSZPpu279/MCfDlPa3lZFpH4YuQcIEQLxRzGwkZqBwpMy/B8UCEwXiy62FxB2EIbrwOC
#NL6UEG8o5qoKk5AEIzTa8BJYP5iY2xYR3nDnOUP49HgbIdEWX+wy6CMX4owARySYVZHwCh7AEasocwxMhZwLoGkUTWuR/AbnKCrV
#DqCqVHBgssNg2mRG8p0D0VN2o+DadzQ4B/0yDOv/QQi0gT2Kh+LCHkHf7FgiVLPg9iLNxkwaEE0kjLP323YUFUhSNNru7hir/j0K
#ZtICaVKqwKMgPMIJC5gFAVVrIeCRIqDaDByb5gx4V2a2GgjId4N0eKcNtoxSA6QiGbJmQy2x5mrwJQFd8TNqPZiA5C6QmAEJSgYR
#Cg5KSN0ySLPUw8OYJoOkDSa3EiRnkmYDymDeFaRKJhE22tGi13GmU3gM3AWkBFYU3wbBEoL7IGUwvK5hhiaFT1AqD9UCAUAbjrPy
#CT3N37zY7HE9RdJWM9UVXrzwWjwBIfNgQBFK+Ph7CayhMGHi4MTXYLUQCnhXFkZEG9RaKFdxej6Yp8XGE1rQqh/4cXPjj1LIRJoo
#M7LoMSjZNhkSJ1bdQOIG+49IDoM6NC34yw8D2t6wVyMGowdEbAoZQ7ADw7Zm0KQNvLvb9wlmTjq6p2WMH1AjYfz8bAAj0nhyZm3e
#jFkbEsBRGzJOgFFCtY0Bn6NaqFVj8ZHb5kokZiEbP3NGPGM3yVaHNnLmjJJt8HAtgZlVD5PAfgw/iGzwYAo820KKMWhDlmXYpM0d
#qZ1sMpvjTNY4zt2RaRq66fBiLNR4qzgg+zfLVeWrCHhTooGyvAangTeQps/Xw7QU/ITU75CghP2v/xDxUd17RnUnIrt36QUenQW8
#h4jcCS0XLeg6kaZ0wayxq1EF8Y7Uwcu29GBEPWmjGV7+mcCjmswIxngCns0Uxb+QGXQwMneDjK8MGtPSFlxdp4VP0GIWHv2UiqmD
#zXHw7kDWMSbSTFNSbAMBOWfQJCTdiUmQBWCVrFq44IDhhP1Bai3VyhzZvPBWE9AsQJkWzDJguFfGoiADPkOzYJFKIAUkhmK7H5Z0
#0Va9njRnA/Kk8WbTMjQCpYNCbtFadBTWOGi8w0NNSPMB6rmGtzAoaFNIqKcJUDbcLFRMCZVSFqNRR7tidZUwnaZIs1IDiaLBZLWg
#FtNZjR+TR6DzTmPUgWYF6k6oDoD5SNXpWCPKFpGjDKwTDU1TqMI9Qz3hD9bDOBgTo2yFmEKzuh94ZWZy/WYdtc5iW8OhQgnp19VQ
#VZnBjB7IcDQt0l5y01BDZBArkkpuFODtd7UKyjnQT9nNTqXCk4PbxE5Xq1Ip+NxIi+EbClu4VxTGrGJ0tsUuJGhbtIzo2GV7jYEZ
#ormh8iY8t/97VbkqFafKZcEGJpmI6JQEHkHwF9nkAdFBkoQU/WlY0S9eI6PJYrssuFmsxGcwJwOCPI3dTewNAErELLFJkm8PZXzF
#J0Ai8Y0Ar/CEJIF7EMxSR2Yj5akwTUmaVTRGK+ZRDIbi8ATmC9CkWa5EtEvT2A0sgXw0RVqkAdwYSVqrojjIUxZSq8MDYJ+L6RJn
#C3HTEzUV7nCygKW1MOiLadHtEZMxNSKY16nMK9cFrCLHTLQIobkmoqAZmMNa2DjPUZ32DstzZMa2uKfD4jwFZmtwUwbcAzazZOyk
#FHCJearqoTWojUKQ6iiVIhuWgyeQDyoIn7n+UAOiI8gHbCzbfB04fHC2yZ6K6VPR7gF8no874etO+LkT/u5EAN42WrxtSDM4S3Vg
#7TS+tm0rWT5WImeU+qCM/RAExUzsUABGMO3a7w08TGbKME8wafhqO2ejTjwJ0fB1WpvKaDCoLsgSdw4agvd1aJkcLZmaTGeONPhg
#t1LqdH6l4DPXLyhuM+ZvAR3vIBrgG2ZCxG3x8ExnMI0pJYS9uCDJA55t2/aaEk8byFz83S2kM1E6RlmI3iQyaI4FG+DS8atEoEqh
#NcZMA8fbC5XSaZCBtyAqCThN/JKOldGsCYYFUSzW8An5E0jBO9wjmORCNhXqhHhrDpjMFEE6c6kLZhZhKZZtBMetlJZrVTJBCXDW
#oyJywE9lQ4E7FFqAkFlMkXSYCSoxCkQJAcGJ7o65N97CBpuH2FoBag1KnRVsbmm6TCZjjjM0e+QNoUDwYU4SgwQIDCTqTI4scSlo
#XEGaKakCX8EC+YEpCo82VBg82JWFwwBFwRM7KyAZss/IbFJKQt21B6FA4EDqcH7tIEp0xFcHCPYAOGC4UJZBusVgT09QDpzyFs9m
#ubxK1Uhb4BjzgXiPK+Tj60wkRovsA2IhrZOKryr0yCxYLpezogSLBHBH4GWWyZL4OwsWHVw4dIAXJXqaBzeLDTKCQx1cEjeCPAPh
#QGwuBhMTGSEIHWPIKge+y4AYA0anx3YDyPgzUQ/EpiQZ3rTSxDQg5yTJRHyGAz5Uz56SaRyDzjGjLEfBjJfjKnSO2Qj7eTDWx9Aj
#hTWfCCV88GWH7SK0hVtZCv06gNwtXgsId7j2cAtLBfdEcMNgUY67++Hz0GLhTtnWCJZ6iMUs4elD6U2WbHae7JIzQ4/ASwAvqGmr
#zsK6l8EUAyKjANFsawDQm21ZcYU99w3JM2iVsogYN2SuLuL8OStg7mqaJ1P4Dd81OZonh700TwE5RbMSARgSGjBoTq/jDX1ieFLk
#yZRAjmFw9iB3ANRZsBtUSstCRO3SeoCr8E4TmgCwtFEmHjezAEhKQEpGD7hhtap8VyGbacsKW0iFFogkUEpgMFmLMJapaccb0+zd
#GCT1lC5foACElpK8aScmmtBw0pVl9m0YFHC2sLyhrU0jQ3FZRgtrD6F6UipiJDAzwfIuNGfOApIcdqkEIoqFMaLklgMbTwqGgXCG
#yUTOhGCtgpklw5bpRL4DJtC+OwVphrI+CyEkUkElqdKS39wVqUVLqKw2GhHrDFceDhf+wj7Ru0gPqzbbSanIJR1tI/EBCRW5RgNn
#YIrWG5V1IMTa8/5YgZOLvAQgQNDhmY+kgNszC7jN1Sx3gIYxmGGGgxg9xr4DtzdAIxMLV7CIrbmMEMCirZpvSyzRPT5L8pA3ocCl
#jWFvCDn8kdj6t9l6tnn7YXc3FaWD/pJCPzkwKZE7HbSZTQWMjB+7iXk3OD+fEr3gbAi32QhdbRF+0yyRxYSZP9wd2RAjOV4IRUR2
#MRgF4MI0JNUMVaxSbBYGiZg7yABbFR1tttRWqMwCrIFgl1ugnh9VhMIfFAoEW8fGngxnCNrm1xTtWpSDrQEAuAKwCbyJYZP5EZih
#3i6NQVcTpk+IXsiRwwdL0ljsFZI08U7J1BgZOzkTNpMzMVZyPn6MlRxLiWws48QTMsnTgAhM287TBIRjQPEdpKO7DxE6Cxl0EYSI
#cCLAdgX04KREihbBWqvkMJX1hBY24AEayOdRQHTScYyb8MKalmP8g8QtUcCKuZi5c1/kLMEdOJCmGJJRgAPMa9NKMKZkcAa6cS8W
#MCEv2wmhLJu1Uboiosw2wQORIYDcvJUZjEDqgBRaLMJWLDYwR7NnWXU3OxzTqFxtzwEVs//s1ASCEmklZapKykQ6LduTJIUbH9iw
#zIwtUDQzs3IT2iAmOdyX6CT2BZnMlZ7SIkP+DVzVkmv68DVtK9ImSllsXcic+yCjEv5dMAo9vFaV2JM5xJ+2QyKlYwaVxlIjIyQa
#VNIs2GmWmOUQMa4y5DyFZVYRlwZQ1cZuyNYxA/MY9pwXIIt6eLuUwghDRInCEPYQy2corcOh2KonkT0ao+3Dj99x+qqwGRvWud2e
#O70kRSppthTnUoI0TWbL9/qW8HyYAiksRTjMM6I8nwZoCZUK1zqCuSzmeDOczhUV0SURGyRSCUNfXaR5sefxfNgK3FLYUBktvI6A
#NuFMXbCssCJKcSRKoAUx2ayGSI7g9Iv2Fwg2K6C00MgUmXlPNX4H+4O5dlvLXPsR+nxjiGCeDkbJANzBYNXMaPH62pJblhEWklwx
#/+wJX3jmWOCMVFyTPN1j2uPR0ZHZgQSxG8FIKWNnYGBf5fbgqbAWSobKHD39HWOCl4oO5giT4bwC/L7dhNUEHZbtGoH56IJbii/G
#0X0+QGTAGyqRjopNlokcuUS41SxXxCI6Yu+wQxrUGoAn1vQPPMpgjtxoMAEMAy1Asz4oSAotNpHVmhnZakbCSxwIYx10i+uOfeJR
#Jna1B6J1V7PRRJkt2VKJh4cpC3pMSykYAQCU7w1mBpkGtQXe9ZvlSOIBaXJ/GRB2PXx84HqAOiU2mS1qsg9q0mI04RY1lDZVY+Gb
#9Pbim8z/LlkAk2hCjkgLYE5aflsi8Po3JALfoO+QCJiQCEZ8jW8KBhN0J2j8o4A/eJLiEzUea4ilaq2ZtnS3GsRnqklwpgqitWQh
#th9GVMpiNzK0mXNHViJi9Ys7OjRtdpkXs8OEKEixamPayhmfgrnITUQotErMJfALMhWBjzT/qGBimAhaU5nJTF7RDC2EhYcqfyuH
#Z484YQAwST8r/CQgpBUC+xbUMXJhQ9k+EgTV4svS4rKKksoqhGUh5y3wD0d1kNc3IAUS2xwfnOMJsxhTXQGQZXZTFrzyLRGRFGO+
#JW/ZDPsZi7ZCSZFr2PUw8eth4NdDwdvAgKVgDfUch5QBdUoIKgNygayFYG4A0BRuCxZpAUp5e3tBrApwFEAmKssE/c6tJiADUsEY
#N/htAw2RUEPQPQ/at4I0x/a6UqF4jW24RHZnSKkMTV04xzXWswvpoQWKUsbVkTcDtvNYwNbq0DKGteT8Zmk4ETNrYubImJgxH5TY
#OQKKeV1GfEMWxHDhWRNiXFus5WVubygHUW1sqwE8z2NPYe5FYEQlMvUKgMEZBcw6a7POAhjAsxi9M29Txo7AQpdg2YzrcMsG+glh
#KRhnKM3OIYTvU4ArAjU40kgYAfoyNyRi0UPGPNjRSIC+jFod2taDhWGV3lADChsJ5sypWYirKaGfBODBtBls4Bt3gM1wfGqEdWpK
#GPCDf5NKsEYLavUcpPJOquLehVc1IQ5OEDYRXySIkhjZjU1jtxxnZ4jhqNaqeCNKHKwxBY0pUaBfVkP1clIKQ/cMMGwJ9izIJRj3
#jnhkzB2MFglZS+aLDkkT5MwAhkA1Drb7Zg4KboW0qhDk3StS//GWZ8jUUOnIsYnzBnUn3JRCMEJMQPdqInAwXkic7Md7UUB7Ns6F
#At1uMQNloaMsBjoi4ChlcJhi75hcQgGE0jRoUUqRgKZArykFpSEztIBR5oJVAmaYtFqMiIem9UajRYPtTvOFt4LgJIGTERy1guVn
#5oa3B4PgxW8PtKeZUtyVkWDL4Cy8I2xQCqKQ7cjUZEY8idhVPDLeCQdrom2oFbxlZDTeSfhyRHiHBnalDqOMiPd17PGHJSfO013B
#+0Txd44KDjP0DJ6hrgi2LodojBLDAaIxN4RgKlkIjAocnAMBRsoe47BlNbwm+7emwABXNAU1nFmiOgm6LqKHEMKhByI/YlSqmOGm
#o8FiI0dusNAcQDhS5BjFRgISXa3bN8pwhCqWv4QBC2XQKNjSrh1IM+IeVKqSnSrZqpEWwzc9Go3C+fCV+CUQO70hn09R//Y+n2i0
#KFAhXBGjA+FErlIBycRosnxTJvH4z28pfO1lEp8Sbynw/MGkjAbGDc0W86B3MHu/D8rZhe2VoLnAK3ZoZo9Ky5Fqvota6vjkE/AL
#9l5ukLyUCGM2GqPRBCVKMhVNU8qBniUy4iXlHdrEDJug/zZmszGzHfTDg2yIbUYPkwR3bO+X6HAwOLJYyfPAA2apLwRcouPxRIAT
#EDBh3jBODwYww5AEw4zQMKR8F2V4EN4gUwt/ZUkidz5mucUhmhFSFk98jA6JD153ZqpGEfWEgIdbliM9GSF2nQpw5zuoqOC4xmTU
#KBMscgw2VbQJ4mEUvn8nfjgmSkZDO6OShwq3uA6crcW9YHAX7/rJKGwY90/UDbbDYmwSbBdEsHFsvFiRRQTCUSZSB8A7bapBCq8A
#cx16CBTjFoCoAkvg2WCMUNPejDmk7A8/BRzbN44SDBGWq+JYU865iwe7/Rx5lGNukB3INkrHOIr5QQZJlY4qIiZcxAKGlDCCRO46
#PQmTIuH1O758Z1MA2aYAIGBisNj7QQX5asz3YAJSYi+OzjsDOpxFPbPcJ0qVCSEqFhshT42GwNmNcbhmdwLABkU0GiKrLX0ksKO7
#YBb2JA8vw39EQdE43bhW+eUR0DGWG//Xh/7tCenSSpoPV5MNGGk3YHZf28SoKDawAnszxKlr7CURG39uoX4Qhm9yuD/MMLBrmtDE
#ApYVuJojZ8Fv39chJ1/GxgH6DUHzDfwmqmRiasFOuCU1oTWFo+6KlJRSHeAV2lqypHalcC/gKdiuBXfGYsUEFZcmHbZbgYQO0TN7
#zYkjEJvcCfCPD17Y/+i2konhDkUjdE3Fh7/ggvJ+31VjPhQIcSRr9q5HS6kYz9p8samn0dAZKXQEyMPolrMZZz7H/BcaOUPhHbJi
#ntggEzdTHJKzR4Tg6LSHsaMYBmxFhc4K/Xi/A5MdNM1MEW1n24VEMok75hjc+ejCjoi/QGLF/KsOrXI05F8di788wBIFLJo7zyay
#j93hJQb3FkOpLZIk3sAVgaZYAsJLb9/NoOLuQgQaGV2i3fcNoJ2iTsAjuiPrchSAEfKLHt4yaKfLamsQBTbI4d5imNTiuWeGvOJI
#Ko7FVHfSXc6fA//L7fWfbyu5RUMZGF2sow1WzPTEUiuerFrCKDahysOF1eSLeQGWLtrxA2yGmCfgZirgC4QaOpafZCnAd4UTQQQC
#YWwGDMssEGi56ninfQ9X+o06dr3icfKBIzD8Ge04PCRRIGjo5O1OcKlM7MR/wa82pkuH6Dhbd1ocs8BgtGiVlNCltk1M146Qy20T
#2bZdVPsOHTt1jomN69qte3xCj569evfp6+Pr5x8QGNRK4tj31NbPBEe3Kj6mHR/pijGbbZaLx4SsG0y85Z+FIiizGZuFMQZwpI4y
#c5bPzEyQY4jw7j9U4w1KoNgMjN8K5+HKDpEiVQKjAl3Jfka6VB9X6KfDm55SJpoz+YU+Ovi6XCFskfZmvYrsTG9RpsrOLAq59Dhs
#FNfxgQ0W056PuD2HluSEko3CpzQp9apiTSx0xVmBFD9AfiC+Jc3at7hZI+clO7irIL0klMhLMhRhEmNRJF461lEPtAQfHRmrKO0d
#f+0doHC7zBcheOcmgWcT/BfagUGtc6iWdxVmW8NODGGu8LyATtQw+l4INILGxkkoLC/rGA3/hXIptD7NsoAGrBZAwE0w+rM2B7qs
#akgz4FsoM83kGfUmSEHDXAEtcyVoExi3UkMp0zhPW3DU4bMtzDWomO2nQ/HIWZNKpFVhrJuL8WOz2Qh6mg1biZ4wPHFkHbZHwGiF
#uZqMOq2FcrWxHrKxEdOQeqzix01CAyIbrxMtTSrA4ghXW2ExiDCTbZvb2mqxESniaCiB+xhndyJyGuNs54xZFKvugxK/HAcARauF
#tHwZJB8/BBVG2MGoAHAgLA6Q7kSqMdLCfssr1SjhwnWgT0AR6ENcEAA9DBatjn+FIT5waAOFlc4W3j4JPxeQSyQHE16IvwdnhsCn
#nkijAH1iv2xAZ+v1FPxkGalz5j2WIHuMIjsTdnGd2W/GwCVmdQfMR2Bsvh0DRT0EdRzAn5DAKsixTGlzzWE1qQTHL4KKnF1dGNSA
#1HHXKfBrSJDDE1yChgqABHIgUJhvMAjrwZ0ZgFgwcfuI3RJ+gQYMBn1/Bv0Soq/P0FaFXmtxh9FX7G5qtDp8J2oWAovFFfZ7QRaz
#TaD/JNa4FN3FwZOW54KVMpnQNDyEQShWryRVAAaVAZmC00XRidokbJEJ7y/shQZwYkK225iGLtDZRhM5BpjmTF78hbpRsHLI1wBC
#hVP/FTsetOsUDrgvvFHcba4OWCgp2BuR/wBCDPcriqmbi1ZDiofHQVCLjesZHtpmLyJ7bfZFKFOJQOv1TdCy44FFAa7BoDr+MgbG
#iJ4KYMqCkpGaHMHrW8HvIkllGjgslfhmwIUdK+o5HFscOZKg2PF4wPEItZiiDLuBFn8zgAQ4QbeO2ym2OhbPvgmw4kUrQMfQ1vwW
#PE1AsqF4aDqCDUIdbHyHv+jTjjEhYa6UROkyaDEIH/CHerAmooT+0VQ4/FdwH93B+kaZyLINEjUpR524T7+gE4CTgi2OruK4r/cp
#KS2YC08dhbYjrPEIJz/Cm5Liu7MlAPwGgTnoJAX4D/110xD/QIPpADrD7Ak7ks7E4Ash2I/GsAeb8Cs3MM+dHaTIjl6NrA64DznZ
#kiLmvLUxQ0BjYaYC69oOzzbIOctOhIjP2WImg21w7EOCOhiZkF5/g5jkM8uDN4RXErs1vBxsT3ciiDM3sr9YRZyKRHCJ2htfrHq0
#cifA/x4B4IxhblRL8OGKNjiw2bQxNGO3okBlawMy5pQu/hwXa6MY8GOcKQaVil1CxAQjc2seib/P0oyNyMt8pFKJbokQT8GYkDj4
#EhVGTHY3GCiGJPC2iLYxLeEHBFgP2mJQpVjksMNw/lQvFhxQuoYaHdZz1s6IL4Tf0MY0gbMjulZnAqazqmOWkWDassN+FCpXT7Fx
#it2JQOHX+VAtIWiEMTh9Wskcw9QMIxeynr+IUXZzC7EpozWAZdKquGJIJ4p46vAweLzk8hx2iIjDFmCjG+HrhaKGCmYFi4Jd5s/S
#I/gXQ5q/ssDYz9pNIFFadHeMNwtLHWzU4BIXsF0hokmEim6dSNEtiPaVSwBhL5in/o4PCkfMLcO7OqBXJVKbEkzT3AkfhvrY0x60
#iQiNtzvzhPQp7nKkKCF0Wnc5FOK/bYUe8B9bfATZW3z4BxRnXMt8xOJfUrG1axPfMbJLm+7tBN/gpEh9JDrWsfMp0j5B2z2jmUJf
#0RFq3TKQDEUxYfiNBqjmEr3IM4wWQWzDDAUSJU3iuzKXDOSflWFh1M7J8I4JhTXEV0Y2bo3oikvOf2jUJt5lRhoh+oSAUp6RJs82
#WgVamxS+IdApHKKq+MZUYu9d1ByqIme/yIoUEUxDNPp6LXgxUBS0Xs2365Xrx2GUCq5fNvyV0YIcbjIsyNNfOI40xheGQLmoc+jk
#w/UtiKPA3RQ7ck+26JkPHImjXVk0Nn6WEBEE6jnoeAORAn42Wuw7zPrGMB6zrLcwmr34Yxs66HaLdoYELBrj/gangD7dJ8KHMBYf
#UGFLqkXsHv8f+hvbexeDmQlHZrCJecCU4cabQoRS+nApH3qKRTFZqCfISGGnYmI+VIFqWDnHM5VesJSk8DMUVlu/ehsHJg2SAJFB
#Ri6RqaEA6pEwCDeTLGMxDns2MesA953UZPOJkTSkPma9pAGn7cA32s4LmnNpyrfVzONIxkLiQOAgl8iiG0ei1CcYLaQOO8rou8Bj
#wQsriETBKUsOEykKXEbpdEYcHhKuv0YL1XVISy4EGDjtxMozrKW1UfmDV87fUg/wTmvwsBhNwQHwE4kir2iN0NMRdQAVhnwwLCGM
#YY4guq6ohhycc/aqZDvdsS5DyegrcVs2ir9i5/KtQUNGhuZHbdc7ymeCKKLH7+8afyYHWgKo4r9jJLhkCUPBgDDpaGHL/yIokG88
#VRIw9EzYPfDL5ooueZjcKBRPh8A6dL4HvTDig8nRtQaMEsBGojPbuRrbtqfBUQXEtxsiTTDnatOVMRpnxT+xT1qMNoPiZCDeUpA7
#vt15ZzGM4/zBaZTZBNVRYoM9xkutJC94y3eVhF7vxm+WdOzjzjL7VAmxj3QZYHtDCgg/8Sc1wmMKiAq6VIn4JNBlaIX4YhR6NnNk
#hnfFNrKu2OIQ3DodoK5GeSZp1ltN8ATLZI8vrl0uDy0wfmODLmnANBCSiuiFqZh4NtpUV+5eC4+DIWvYQZeLQQD7NtqFcgA9FltJ
#XEcQuEHh4JxChSR2pxF/48YvrJB1sGuHLWRU82F+jA7C/Aj7sPuXgxQ4DMF+jSQhWgAkFq01xCAazpBngpUWFIqMje7Agwu58OUL
#i1rYoqKSsKCFOzjBpEsK4EI7OoG8/fBXevmejGxPbPgHJuQ+3w/DQ7CBeLBWMre4XSEmZQzsM1hnLFFAMI0c3lgbeMQ0GDlnN4a6
#CWmtOQM2xzfFBeQSBxrBAZhYas8EXRLdzPIRBexR5NthoDg/TIknIUErB9jmfVsJoX88fi82wJWInxJEMiCZiAH2sflQ7DhbgxaZ
#wKLl25GViuW+WK2ESOEoQmwRUc/AdBQJY6zIZSdXMfZUlJoPdi8wPMKetBnwQ+smrZmCMQ2hRzz0h7eRawQLm6EgDa42KwklGTqZ
#+TgTwikkUkG7TJjEYhZKVKDZCBQ8vEzARbVyhBGoMtbUlCyfIWdXNOXiiEgKq0DkD8GSbD9ZOdehrWYiJ9IlCY/SDEWxHhEZCnst
#YvHfsIEtQ6kQPaCJQztLtwzegQhmIFUI1ts40PShJWHe4LeosX8aAih+xaEeOCkYrZd9Q+gD6sjaE8ybQr6cSDPEqtIdBX0p1sTV
#pEtkhbwk/rum0MjVgRW5JQtazjH2p3YmpliDJFApYf29r5cXe00HGpAJTVnhOyc/i5Dgv2dsbdL9D0yTbcINQJ7dNson5u0Ydhd/
#LAAnMfQ5EaquRBwgBi1ytcDygl3Mflv2AzPrsDRhTlO62u1NWm6Gn2ITbLdmuTAFBc3AajELLsNoZEVHdKaODf/EibFipYiKUYlw
#LaWBA9nYXptFqaQ+4iBPXJuuwtFlGg0szeDayASrIoomKJLxRNUB0lrs6oNEgMr28QiLj6jDAdERABFn7zCCiYrMhjBEBZJpijI4
#sGOC6gL7MvZREr9/PMznhRyMB0bSBUiWjFWqEQTTN5/GUHtmToKGxGO2bUdl+WYzvNj/v5oaaQtpth5g5cRxGllOHh9qNLOBEH1E
#Gw3PHj7igWMxlhs5G1bVduqwPSN7o8E0hBrhLjn+t3MsNh6OympGn6oFA4VlHNvE4fr/DrRFgrhgMHqwhS2kjgtwVTw1KH4v/483
#saPdK6yqElWFMS/4qvCt2H3PsRZiyo3OHZUN6cbBZnhKLQwSQ3NBYmiQDcqrUJAYeO548/Sb08cIIxW7CFrEbL5tBRuKLyjvmJc3
#ZdoyfCWx7ia8wcS6TFq8PxxwZqL2IZZyEy+GITTZI7lNSzT7DTS6mAZQ7K+SWmAiSImHD2emgjdBEoNVT5m1Sgn82I/BooG+/uj+
#oFgm1iT4KpvDTr8dw5aHC+GJUAjHMuYORG+ZOMStWE/m4yocjEnJbQmBQOC4A0FkSxHCiwPC8lEigDyBHWGQYZoZM0pgv0qQqgST
#WCYVbkaUjPYon472HUzHDxC8QDgGdMZoFsdARzQGMxsOt5gwPKaeF+KV8CYWFokQFhFMGnTpD4QlPbwCg83wKi/EQNNwTIJUH5hq
#QakSgFf2MpStmlAPeFmHMQjtPlcjiFChZ2+NkJJLzyi5aD04MxwQZ73WYXhBPY5oDwP+oyd7bNUzREEY71OQDU9rObwkUHFyN6cZ
#RWhE8xQTvzvY9A7Ga1bYqHYpZOXOaRKUClfbHaGkIcZDwAj0XlpBHYt9Hbi4HoRtTaaiJx9ljucMIBJwDIEIFRAQxUhwe8YGZHCK
#wAE/0oJtk4LtcKhtAsKWBEgyMNcADjV0YqrsSYQDcKWpSDwBQf/i8fjiL6bphXdCevZOiHmDXsm0hcafF7g9eJok35Zwgeoq8rtG
#BPUIgPtHux/ACUeaF8Vc1KMvaNiW4KgL2yb8kBJnk01luP7f91UlysLp+UXpma4OtJkpNuTTmElDuzQpaTajO3rsSglv7RFr4EKa
#zbwWj/lGpFD1qPARh47G2l58KyyzuRa2vRd2GEyaVjrgBEXNOAzkq/9mIF99SYF89SUF8tWzX2AppqY+taRsfYappGyhrttm1s1y
#IfQdh8y2mB1dgNsA3FRMMOyAEoNh8zfV33tRDdVgyRRp1mWjWlbh/GCe3f20ShBp9j8Ots2SEfsKpJ5MpezTwQo4KI0A/x3X1XYG
#gNitDYkbUhR5QWgKmCGHl9J8QAz8bheKjK0H8uFtNjbVQiGGdDZsM7SgFKm6RNq7FOYL1J6M/BOh0+q1ljD/Fka1GvQQBjXosAPo
#A+nwE9UEP0KbKF8uZkFkOWGQOaYrhy61opBsTMEQdpJuYUJzD1GoNLOR/aw5AoBSo9WpAHW1kywY8ACewdJGNYBUAgIM4SSVKCg1
#WE7AKTDfr8Rfe2EZNpnA+J1vC208XqIRRnsLJfwFBaPwHSxflJlQOOHFw0v0HRVbIzHkUWM7uyTGeh/OXvZf+GxBwP/wswUC4NiG
#QxLiPuOX6ixYmW+qtx1rt+WQQ3UQyUpQEZxyKJ6VgcqyMK7s8VoFOEZT3ZHKFWWmlhDxiXHfhdtQYA3mgupC5wIVDJIFVUBt4erw
#W9D2strxF+DZ/ecJeQ7KAG0ce3SPhh92AjyDwSJVCGNYFLsVv7HxuE9F5PLGkwIFuVgxzgGO4L8lX9wcYRHICEhV33MJL0HinOBq
#U8VxxNCu9DtbQqHpuYZE7bBBovIZR4OSA3mhJZQJSWvx8VAhALhNDOthmOA4xUzoYZwBz1UvdKqiAHu20HUUIhW0JLPBLLs+GRt7
#B51KvExZkuIjrIIa7gQuHIyrIxPVjihFtMMdRVdta1Ug/QHrRskb1ToaCTPjfC4oI+MX77A0TMKHDR4LE675O2cijlZmF0E52lDy
#yDm4Mg4XfBhJB+c2vkASm6ykcbtZaCPOLyJGG+xMGIINvlmTeSYsgoO4rNDo3e4zW9y9CB8AocT4rw5oBEZv/qpMRnDX44RtHFTm
#Wx/MsCCB1mjtgmQhpg5Zwoks4dnv/uDRC8x9QkQXRCFipSPzmoBAxc2bNyVCYVHsbKdR7zBKtzuBbjy+bSbt8x+fg4EOzKQdnYOc
#mbTYAIrZs/wC8xdhWLmMTIcAS4BMFBmmDj2LLs1w2RDRESoIrQH/ZsgZhyf44yiCAky3CZ+Ak/49w+7ubeI6gz3cNaZNn6juRFto
#4c1gK3PT9v+x9yUAclTVolEUIT4lqCCbWJkQMp109/Q+Mz1JWAMEE7awBGIg1d3VS6a7q1LVs6UdXAABBUQURRERUHg8EZRNEZ6C
#ovh9CAjoE3HhIagPXFl8Lij/nHPvrbq3qnqZJPrf//8NZKaWe2/d5dyzn3ORFwBZEQDJ1iPBo3zGJUWQLetvlUKFMJ2jHQ+cnOVX
#ENjjzAbIlT4om04addL5QBnsEvnLuooim6z1zK4CdactFusygTlU4/AHxF0DDzjn5YR2BIo29GkUWzyXWkkfsUmca7/6MPRUhYWy
#bBPoHKZZ8wT5VEJLJfURbURDTUIilsxpCZToizW7WDe04vSKgSRIz8UZili3Vwxk4O2SKPlaW+wEd6+xZEpLx7NaKqWlEkeltmI7
#8rtkYjITz9LVcDw7GU8kRVvjdJi63BK0kpyMpfSMluE9y8QyR+Xkey0zmfJ1dSSeZX0ddvvqttlIDsMos1p2LfRvpB6DK/H5gt7E
#r4eMGf9CQ6NKQ9l4TsN/yVR8hH6JdvDIGWUYo9roZFpPa2nWZ6iV1FLxJA5vNJ4+Oee9imXjozFqSZqEUS2Z1Ie1YSqSjMWHtfTa
#rPwMniZgwnM0pyOT6bXQXj0JnXK7VNEr6nonocfueidjySTUH46n1mRgzerJGCzQIewtFNSotLKODeyx8oWCrq5dAwaXHInlYjkN
#/lEpjXkPKQuc0dLV4clh7FC6HoOJouFmJrM6QA/vHFwdpdzHUicPe/ca3FfdRZwApOqb/CRCy2idK6ncF/CsivOmZ2Hs+I+1Bv+S
#RyU5TM6K3VMrosMAP+E7cKB5CqYtM3fVWxJWeo7Kt7D0FQe0Vx+2YZwHRM8yLZy77U9Ydci6Y49Zh3HdSwCPE9VaUrFrBvoZLtFB
#njYoCh1wtr1k49h89Km1yHy5gufpdpkSkoG4v0iEO4JQUbyhC8FeIoGV2wBup9+sPFSPJ+bxPi2esvwGnXN2hboXKf1m+cl87JbP
#EYa59yu1XC0kuQq7gynaMKMiXxkIB7XJJRQdrWZbsMxJkuO6OepaRRHKUarpwLfxlW6YJb3OFzokUwj0lnFAtPZ0BLpqT7Gmt+9E
#J7WLPkuEVXQ66m3dKcKjTeK6BTNcGqTMUQIyjHrfCaI8oAgJajPqkqDYkyUb8UfWpsKi0GQ1A7Qf7BvpDvzJALi7HwKlUQ/P+RbH
#42EiAZCUACyM0+Yku5PEjlBgdRbWiadnsw59YhcLqY8y799VnGcHQ4fL8r6xyEIGdUwS6vGex70swZiXJewRPykcLfV4W9SpQ25a
#Me6cJqMD5RVtV2+Q8qC8Y2eoKyCb6U1+g1d44BFL32KiPx3DYf6UwwD2KPHXnLWGGwdouRki0XOEpWKVnFBpnEpMIJJHLXj8mlXw
#H6DF7JoVE52j2Yn0QHoGl2D9JaoqnDzB2HNJIy8HwyEur2ri8BDu9scXYIVYAiFlVgMYqRquks9lfFFkFDqQDijo6ZEl4iUP8sUc
#Fqs1S1OyWRWFLxE3DIqqcckJ1j2uLdiY0hI6fEn+FswBg9zAuIOS9CQiTHzKN3qdBmfZ5JLn+vRZqjNfx2pOS/YcsQKOe2FuvuMh
#lk+5DS61hdYOdzfq4GBiBb2gerpRBU/EFYAmtjXiEdhtEQCxZX4YK1GOuA0baJxT9RLutE04JvRjEuF6zDXJDd5Db6PZTYDEN/DZ
#0d1aYVF+/M616PKKroNhFF1XYOiSq+BGcd66Dqhhoyc5qh6GapgoPirIh6apx6paceJ+RTwEb2kdPVt9uNuQa+SvuQ5XvKbStGyc
#Utt2j/mrN8fFOX/VVsty8kNDVKpoNhoTTaCQcbgSlMUZ8n1rgNPXFQNnFOo6NmUbxNsiq2TYGh6YXjaAtbVdFEU1gziKEgmyVxKa
#0n3BGwQzetOvwcbTAJF13bCEd5QpYYtxcYuaWekVbL6NG2UFNbQZZyIqac4RiUeoVZaaa8MS9lI0y++wVe8FNhrxN0o+5l6Totuu
#gzZzOu4a4zvm1pE6VGS+j0vwLzm4k5MPVG9xd3dewA2Odr3gu4Vni2gDFk0Noxtn7MvCwSI//sgNEfeGOisNmQ+zbNowfHZIk2aW
#QabgDQGBouyyKPuShKFXlsDGIV9xnC7LsBtc0RfxskaNR9TF0OlcxXG+GDp5RYxDd8f9qxCCSSpErbAxtnWhDhD2Gub5FDu4Wyy6
#pQOWoHAKu+WcUmtVB7E3dEi5XmqoYdjwFeSdx+H+gDadL8qOhhRBDEtm+Z6oqbuhHkKnO8W9eJCGEi2ukLh2DXchkzDRDDqcFqmW
#6orutoVzNdF7dujETxo71hKCwwTma464Z7czZ6wJ9O6ZdbEC+/asJneH1pVVlj2lJjwVXI/JISWkl4RK5WrEHpb5mgPayCjNApvi
#TlVLYRhYpXhLUi5bMuOBZ4u7AWRWMxVW2QoLDrPqVJaL4TTf473n27RaKT6tIGE6ZpPDm/JVvj16T1jHqfLwytxma3J8G2cK42v8
#AcKhE1AxxfjdPq4YSPrbondKhHCn8QY2tmpcGRdMOxUlSzca/RroTL2CtcIyHOA+FDeYpQ/QnRP6cMP4xogmHWLOnQ50OvMZAYCZ
#FhMClSOCJC/6BmbGSWYy7hvgTlzPQckntYFZwzIZckMV1XJupao5YXeqlRN1qCSO0XVMdC0pOB52UJa4opT2fHB5mhmKo2HgmRca
#JHHaY39wpLsgLMUlygIER4Xka+jIIaWKK2KlrrQqZHuFTZW2JEoLjhC00B+UxkROg/gV8sbovUWLVewWLSKfIhcelIAJnuGEHCbd
#DQxwMNjosXOVM5Jh97Mti3S25wywRelz/KywH0nZfc6ArcwAa6vjBNgqBtMZCrPnMhG9sAZ8rVkBrpR9ldEqH+KErQi8PvO5HO+A
#xRR0Mp8Sgim6u2p4eiWrWOjrGN+RHXJiVi/NFXa6p5tLpUsQZ8V0IxHpfAVJf1NxvUQqpns8jk9loziD6V2+A5yAEiuq++UA6r/7
#RSguM0l8Z7giAe+oT6vEb3v0VWnR4yQUzRV/PJeWFEKrNOa9mUt7rnTQ3UIfHipLWZb+j8bH+lSGglBjBn90OvCug0G0fBrC6LlE
#tJjVQZrn8TF5+vQ8E4R8a8Efo4mg61IoPo5OF7hm6FABbeYT1XnJXLFTnB/DlG+CzNqOuws4ru29jh6HiikC/1EL1etcqhaPEO8T
#ghmrp05Lf2PHsPt/4Li5/F8N9x7E5CaSxqPqjb5ik5q6ChsMDYbcpuRh2TEB3hugJJ6NSRVIjcvYDmQLlkF9NwoeRizfjgWgOazj
#pS7gXDIVUC6FYemS+8GSiXr10oyUIOsMXDoaBimUJfjWi4ymjQsG0lMj0ikkbfnWZbTcM03IyCSeBhgyZe8jA8Ur8B3kZ188VFMK
#zy3bzVRDQsAQG84SNgH9AGnJ5EG0fcOo6Mk2QGoAiU10WXQU4JVln+i+Y30ToCz9sgkXOggCuEMA1zp6UOAVI+VHX9t87jM4t7nj
#rnqz6LuEOQyM6Rapw3SNeY9qAElrT+WjhVlCmlmY0UAq0vB0CUpUDRyj+7BqArNn6RWDbBTaak1vUEt4lJVn6XKPGMPpEh3zss+Z
#wcyU/oMu3dO2pYPS5GRTIYee0TlnzKBW79AMt4YFrWC8NKFp76wzbjpyEAjMuAsRUcrmkudJW8QAowwy0Run7foXkQJSlKcb0r5a
#dU8wh0EztSwsNLsKqF1hZIB3UBeJH5WUktos+yo1lpclXXSho6drOXohQZh8hTakkbcHGZxSY6NHKDL1zP1nQxKPCuDv4Sl54KgP
#UQifZTC1gxziDjl87epjtOMOOWbVGu7+UW60DkV+iAzCqCJIaUuXamnUEww2tSFxKwfLolesduShyOF5NVJYQ9IjuHVTCVZhLVXw
#lUgmUhn2+m2HLpE8SRygceN4KIQjJVtlGXvgmavgVFL3sPGcAoNJoy8hnoOUzUXpBDE3jY9UO0pe25jXFgqcAn2BDuEps9JOINMC
#VSGN8aQ4NGHTAe3BmraUKitRxFF4cRS0koJ/oWeWJbFnkyKhOzRBxTMRpZVNESVHqRTU51jjIkmp6l90QPsU1KAeBc/xpFLcPodQ
#4O8JKAoKl6MQ16DlllmfqaDFHI/Kgk8kotgMGsRa4pQFjalnB+XZo6nqMAXQiyHWMBl2Rcv+Jt2AwLA0mofghhqU1p25sCwUe025
#ideIZ67WnJZpz4gsV+jZawzynGBocsD01hHppFYvXeeYFEXI8nW29EJeqztH8iPcgUgUsAnXoxlQ0WSe+wbwY2gRVZMA7jB/R25i
#lvJ6In6rsHzc/gSfPPZaL3BrlvgQWTpcR2g6t2bDEi/PF70Ut+wlw4fuS3EbYWYv7vLLps02zVaEPirsK84MLGjD/Sq7Y+3WzYp4
#jpfcDERrQy04QK44ocATNVaQGzG8iUTYX5Jl+TDmktLUU8zo4gww0v1J6U2VATFyr2MmDroXmbT0TglQ5SBDGIjwsoJrjIKilHM4
#Ps9o1NVa5FbmCia4EqYg5fxneujNkqf4gw4aDcqBWSjFWEUREIuRil30YDQSrKhbA7LBnatXLB6UpltLJCQHPNS6Gp0hBKi23JQy
#izu8dwCzUn53ch+nh1AHGOdyUzr9WBwV4fkqGchLad6pF6ImRgKKJFhSeVrGwyh31aAFW8uZpHqDQqirxztyDc5k3GOB8sEMV6wr
#UYwpiSgMBKf2UJ+uotxDFH8fYdqDyOHMRkPo/mTcnHRFilnFRYvXRf6n7lenQV9wi3Otv2QvdSbRYEqt8n2imFM3YO+IA95IhtUN
#Syaa3KbKLmiXTjSFgZVf8adobqWHZHflhlcxZM/eirewYaGP4mQqHXM8yhPM5h5ulMAKDgBQ0U0S5o9Y0Qvr2LB8cSudZQQTSiOS
#7BxA0tEfzZ1BWaLBufWczegRA//Bo9cdewzIGHjyU608M6gsgnsEEheodEtBW3JZzwChPJVSxPjS8rI8QLozqZpIHZavQkZNOiXs
#pW3uulI5siVEser6czeS+ye6MAUTPg7hjZcmcpa+3jyDnIJE/EGv9KlOIH1qvkfyVMefPDU0NkHx4XJaLeq46y8WTDolvSSML+We
#Yvflct09Qy6YoUmj9vlpz+HpSXWrzrrPS0kB7d3sDrplay30w0Extluy9hAoCHOxA4Zcza3b9JyBvBTtcs51mYx2zbMuNWqPF1Ne
#u+i+xhtnMMQfUdRKaP2GnFl9qEMYvK8wnoaMBxX14QdBXn6hSVv9cMDzTgswIKdhzglsmnUXX7WYWQ3ZMq1jvgCbsCXWzLMtRMjT
#BRTxwD26zGfGnI5ExCCiGvXGbdzLeibA381jLR181nG8vA1fClrhC9Hp8B/AyEy34QwCnSkaJ9UiynEUgML60eT0xtK+MD8ZCcuh
#hpRtawtT+PqQrJouwjTrjj/ljW4XEUHyIzkxPfoW4TjLX8oHK0qe7cA/x1kJcm4Pd3/3FXLREzFz7HPI9Q94/cEM6abFEtLi+VH4
#zGgqCwZNMj9UWi9W2F8J91ugEj5UKw2xnqz0MYIW42AFL6iJGXaPtJqMb+FPHTJkSS/wQe9sDQwEOC05aMsK6GnQ/Ry+Epk9EOUj
#yuGAF7MHYvt06/BjredK4t0I8pAAexfAmFjmyDqAZFQ6ca3Eox6HMGC7ttUQetNwvmADKqTiW/AXNrsxwBuwhHE19BrtDL9E9H3U
#vVUISwSDy90rFQyWkVKJhpSQ/IND3ioeux3a96BUIpoHtL24+H7JYKvQk/YhhfReud6m9NJkagSO3c/gqlQW1oS7RHX6nqqaPahn
#eM4Yz8NbKdM//Qv12w7MbYg/ta8JdZjIibj5uUyJ4PNiYgw1oozsVT9e7V19DnFyuxEdSyJdlusU75FUxQGzGYg+IrdBFVQIb2G+
#X/SdZPuMzjukpHbCf5LxLCuffNcdXiBSyNaBuq7nK2tpGZ4IjRYFxApRDfMPcAwgZ6fsr5NNOu3Z7SSewLxyBcc3oZ39su8U7j4I
#9AlMfdO3yOSqe+aMTnnN3plweEE3VQnliuGJMbihQDodbgmWWhJRkt+EI1dsp5ewJae1OcjLjVPpIlzZFixRJT5hVzBPAKwLu+Kr
#Qu94dxe63SVfBrT9lFQfJYa0KsSXB/BYRTIm+Fn5imfSmB0I3x62G04jNxTVxB2grRyLq5EkQPEyTAasuNkIPd85xAEVwgEh6fyl
#SQoJxamaLWXn27y0fKAYFyW6RN5gvaI50XSTaFbYbTA5rDdJljdF9oBySj225rmy5TH+gRaUPWNkCYrKXDdT/3VvsjDjbw4hXtC5
#sAYlAbIShH6/EGlb+kB371bPnRobUB1bsYdsU0l+aH23RtkGzfqk4Wux5OVdnnOLgOkaNcfxt8ie+s7n8SS3ztKWOoXUM3Kzh0ar
#erMkcKr0EX4QGNNNVUSpMwozSgZNJE9zl6tslcTJOFvOBIWsX6EUcxEwPww2QueCepmGWaKegi95CXs625EMrCNNfN9UQCju50wE
#muGnCTQ97A8louS8y++50UUubdEZSJiSucDOTlYtgzow2wWRITcvso55voaD48YMJuUHCSyKYlAUz+mMot28ZjjBJB0My1e2+uIa
#qH54wnJoEwn1KLEUgNYQmPiz4Syl2tXthqRZgnezi/1pPyqhWT+o6MC2fkpOFeIxMzB6KZ0hs4yyyYhqMFW+yAdXkgYYwFSOXSXp
#ylZxtBkUHpClR0VUEUVUswI/D4E+o3yiAiKHNeEakeJ4E1HOT2nis4hXwLQN18W8yW4BAvAadfYbyBIOUCcfCo8NRDjaXYafbEh2
#K2DMG/hJgET4Frw5A70tohq7Jn6PBQSi9VsqEWGxgNJTVnZ2k+/r8Er9OuChce/zdOd+H+/cDtBNsAduGbULUulAH/Cd1Il+NgXv
#HvPE92eXZ5Mtf8GTXyKS3TYk+T02yp1mOkqRTtyZ0lnKmom8xseHj9iwiReXn7JRB9LNq01OsAZLefR6hpoTFslSQW5ChVirm3jO
#ZHGNoD1kEMRTBQZ62HEnKfcnHLLWJyyrhokOaePx2/4POz7pVCAC3AKIlwJzQ7MIe8BxArPQv2CHJzFYtln0RLtNnaWUNWalb9qk
#T5RqrW0gTXWzopKmcClCKh31jm7uggM7amO0eiUEAupx9MbqBuhYwuxVQG91LyFOgQroXLzxeTs1AEL+npdag7CbnfAvTqO7vGl3
#fgeLHFGzW08HE52H1WUe9biI05Kcsm3wWA9VNGwa6yI9yyny+kxny06YZ4A7KJ3a6hkvo9ybjz3k+vMo90JjD08QAjJjw/IeAwdE
#zazk+Y7RZjeQ6X9jZNB1HC/XmjCbM2QoVzLZSnpy5k2x0Is/cHo4+fehGejFxkoafMltkhfCJwWvC82AqqBv7YDCKYewyU2WnKdD
#gjnoOk6No+Ru5flXumVs3SAcNTaGpG11nVe8rKdwP6bVnXWqbxBzdhlTPBx8eAcfHSB6qcmfjZdNe5UOqyKmKJglVDiOwKemae4K
#8kFizOJu9Y7m6Xi6mG7ZShgCSgJi3pxJv6Gb3EKJfqGVkvqzTD5lzCEXUcmj1JkUJlOqyjOoCr9L3wFlfBngs5hKpa4cRCZcRIR/
#SAc3dcvuMMxWQTlFzR2wZfu91U00GyyzbLdnJu7pfqbCdDz3a28KhBOLLQ/VdWaxA3llgIygI2Qzj/qaGCVa9mW9dF3hpfmBDh6k
#+SdJy2t9uNAk+nWf8bnO4JnWIU4zrpCshfiVK9EffNqWkN53Ccs6STpV9QRG/pC8NLlrUY+wErdh1NVKDS9b1rkBvk+scPixLWWX
#WAGgCa+3gStLXJDjxwdb/aNu7yRD25IyMKMeNg//PCi15ugP78+8HD4t3QN2EAA3ekHTriT6jzQie4vgblJKXNETb1kK2ooKhIWV
#e6AtS8Vavm4U4I2379XCYgfCU9++r6Y77XL/Pifk2Gm3x+Nx/L7rvIUOCujBpe2IfU7Nic2On8FvkpN8iKNce1bBBV6InCBawexp
#ZMYPz57m7ektjO+pG7otej8ZL20hGlzagkvoDcvzP9wi708yd8eB0DbomFGBdBJj4Y6KUUzrHBlzhxPa92IVA4x7dd4RgaPMAB7o
#VB+94Z0Q9yyRLmdXKKaUaQFhpdIJfjATup8PSj6eIiGa2ya1ODREASisPnKrIqG04QA7iruBPtvADUVugjDRq/GQT+j5oNK8m7yP
#s3W0HQMdxDgNwZxLc429jrjpgGPb/aMVTLM1f9AnJuBDLiYw1HScbTZqjhEHRnxwA26GNbCeg54veB1uUfNPUmBUEyWcQe4SHZqC
#2zaRk8PBRLzf8/7n5x/8EweSY2GoKIDZEEv+XnScHfsNgNpELpOhv/Cj/k0mU7lccl4ym8qlMsnhTCI9L5FM5zLZeVpix3Yj/GcC
#w2Q1bR56xncr1+v9/6U/Q0u1w9aljjGmQf4Eztqoa0++68NayQDs2gSOadxo0nnAM7BbWZp+cmBy4toRQIsdTbcBKxr1cgzPMTdK
#cW3p0PyDy/AqVtaLRptfNWr1mfzAYVV93Na14wzgZgbG6NUUOygA0DC7L9UcVCbkUd855tjF/IRdHxTQiSWcoSK1ErOwlVgdXjRj
#UD3WNO2GXo9PmeVyirzEG3prcIBuByKz29Cn3Pb1Kff36NPw9vVpeNv7dKhu10FOXmc0ahpwYUC5HKOkdi4zh84VqDmQ4Bu1WFE0
#x3uZ+bv2ci6g1q2X2wFzffRyLsDXrZd9QOH8PGK2Njmkx5xi1QAevKTb42OxWKGSX5TIJHIJHW6cJNzoCSOZwZsU3JST2WQJbtDX
#Kr8oqafS6QTcIqOeX2To5UR5GG4ptnPRsD5S0PFtEd5li3qhnMWi+UXlVKGUTcG1OZ5flC4biZEy3EzpdlN6V9BLcFfOwn9wV2tC
#0UQ2MZIo4jtbb8LbVSPDmdQhyFjEYlUDyqvbKMo4q9hELeroTSeG5kJsC4PNO61IaJ3Z+UvbBXM65tS2YhKZgmmXDBuamZ6dX201
#6m1+9EkykVg8hqmcKmTf457+hUpkDOW6Mi7YdJ6xgGOw6IXxWosmDts1YnppM5Al1gg7CSZmAVsNH4y1QLYdTlnwOew6Ht9ZAeEi
#MQayRUz+thJgAA1HCJ5wk2rJnDU9lIxnshrvFQXcz2cJ6Xl/bR1zascq+BcdVrOphDWN/Cf81ltaQotlFkftSkEfTKVT0WQyF82k
#ovFkMhKlpD0sIYM2nFgcifqbGqVGMine1EhisRYb4Y2NQlvDyWgqk4XG0n00Nswac/u1GI3oomfQpeTIaHQEepbIhTTmLYo38pje
#aunFKrLo+TLa+mbnb2DrtLEtNiPq3RfWGqiC0JstWAly5aBNnq81qwAmLT7/7t2EDTJNngI/DXt2vt5W3gPsJKPVVLSaVjAF6x9C
#c2RMLPTsfKvtXefLIE44scmaUyvUjTYQadqMAB+aY9ZBtHKDUsb4uxg7zSdPIFRrVKLOZAUanGYJ9gl2Zudj8nH5YSoD8+t2QcMT
#hMY4QOaTI/Ax+pVLYJvxyWrbMp0apSXQC9ANQABjvCFoRQApXIqtIDZCsV6z8jYI/YPsiAYQLKeqtZYRg1UrGjDtU7ZuwRec8ZoV
#8g08izAfGx0dhaZxm0CfQrYgoouIsj0An0Tc4dBoMliT7WwEtAmH2vJT4q1Qs2RMw57ifWKr0aZ+JGmC5wN7BV2BnWUjZxSHa6/j
#Dkp2M9RVr7FkakyAWbluTI/pdWDEYjAJDSeP5+EZ9lhFt6j5MSwQwznJ4y+xPjFaDPY74S1Thi+TPCW0TTLRXDSZiMZHIi4mwiIl
#27RizEyRL9Qn7EH8JNspnV4JXAi7oYELrMAgHY4EE0UL4G6lGnnqxroONcHnHiddS6UQeWny1qgbLShLQIIjjSczRiME/xF6LRlF
#kycDw13M5yxm06IqcI3zlRD9Ja1zW26TwZH3HnYRg/F0xgNyug7BxDBa+rxbvaAgD9yAkx6c2AYS80mDHmuwZ0NgHw9NbCFGQBCL
#2e1+YQgqoPTeDuwTJxkJ6Tlb4vC1DdkxYi6HobzYQdIgC62mHxAKdbM4Hty12Jtt/La7of38VX8QwrqZryKuavOvyDWRvYmwQhuE
#f/PGtkhlF88K1F8yyvpEHUe9ZQK2fTQO/HkjGq+YvNF8IoiTOiEvdzMgJe+6FRI52AqhgI+4NoYHu+R5vgPEudGiXi9iSobFaFLA
#TQ3P6BZv+BXSV7xlVwktUAcmEiktg1CGJrR4ymH0F/lPLZ7MOmImwiHARVtI2FMCAxB3lE9mCW5xAttuOQSLVIZeULNsxdg0i+uK
#yddR4C7a9k3DcQaT8WQq4tZFE/+kwSuzm7bb+7wDIzYG46PDEd6LvFh4b90zYt2bZium14HIGaUx/lmaf685DmXYUJwG35ZJMVIQ
#fVJvcQICeIG9Zau+NZpOIOrl+EZ96KIZ3+7IAnsoJr1i10pjFAam4gc/aXZBjlZb+c7SeAbkChkKGSADw16WQRhXV7c91i2ZzpaM
#SrTq1Hl71YiWSy3WsilgzfCp9KkqpkTJZCNadmQxcKGLIxEPGXqzNSYzwGZhM3ASQKZa+SKOxh0yzTGbWJ7/UANub4Km12qEol2r
#0B9CTYRxHHPEXcS+CLDOcuSlZdm/ABKTdpqMnGi/kZhS1Usg2cAtDaM3HrMKWrzZkJi/dGZyKgAOhFLch0YdkIlTc8K5NatBztka
#zmLIh4tEVkRP84zzS8NwAwJBaoR30CO2ybTEUaZ9xJaGJM+QhIBShICkrlGj3qa0TcqVkhxJAIyqlBDzd2PVeggZZnxEgng6Dy8u
#Q+IXIRGNd3sUIcVl+bLbDTTEDkpAo84o8kxahnGFeLkoAZAjUFVijKSHWh1vxPK68+ClYB2M4SA0gfxGIl6pmAnjBs4TOV2aAXnS
#+XcA54+oJABuvS/TvbIiML+ii0m5i1zWCSJQqKHpUfrDBTJlx49JeILAlzZxHpl1efolfAlT05mtGMWdmQyFOL+6qQNbQf0VpMnr
#tfxEV+U7pZgq+QUBKBXGvwkBUepCvC6oosLe6sjcIo6UrEU87K6AZwDDX+kN4k5nogHctKuSIKBLEPaadV9qVjsM6Yi3hXa42kLC
#eMThmnVHRcg+SchFxiGImnP8QkrJse5RJHObKCYd30cCbxgpYCU1MsfKpGdHsKzBwStsEPZJoysm/SFJzqpcIFPlzIkoyAPiAqwM
#JWPbj7LHCyUm3uSwsykfyxoKuf1MHFtBjlFTAYk9K21WbCcXtle98WMnO+FzAiVE6cg5heNGeMMaq/QETAFxFYGmpBmQVFRzAZ6c
#T9Yi+OiOmFwNs8tSy2CDcUgCPCoKYgruUKXQBvLMw4xrDmZ0opRqG4PYqejKkgHA8ktB0HypFMqVlUq92TLUo9bKM7Ei8xzJE28S
#KxitKQPonKtJkUjz8I5g4gKUQt2wWd+GDRFF57KFYSJ6M3ZQSGacJC1F0q+l6M04lUqcTOMa7ACmTm5vrpxYqbQ9nBji7v8ujNh2
#s11cvxwz0P/GYfi7A3e3LcyZtEoyc6ZyYv5OkFItyL9Bc6bV2hH7F5FfOCGeMy/n5wvDUWj4Hg7KPsomdntFyo8o381MDwITIbg+
#vNwRnB20s8GXXY/j4jD83bF0Pq+XW4T02fQPDPCpznnoIxckvWH8UAhKGHGnkO1k5mbQVnQT+Av62bBwNyCOmWg0nTxsYOYBmwSE
#VLYjGn+QRh4pGh/GZww6RnxcICVFR3WLbpecfj5lG5ahtwYRjFHnXY/yT6WQK4gm4UP8SxlOR/i0kIGLf9qFXunj7VhMzy/KZrNB
#NnP7sVBGZn5cAw1tlSB7UqrZLAQ4z8bskUXVbBXUAnSiEFpxolArwjbdWjPswXgqGh8BTB9NRqI+YgY7Qd4ZjLjg7OTzBQOaM2TI
#64Tkgfni/Bm7EhQuIZO4RH9QqkdcfBxPpcZkI0cqh6QjDHmmFdyZdsLwsBgXo9PhmD4tWVHYNmVW+UZterDW1BwgnlHRTS2bXRyV
#ICCifMCdPk8hmZLwNKMmsHdErQ64ogtvrpB7PYTaJ93NrUeiCc2TYGKSCKCLDqxcGsriNYyWrtKI7gQhhIJ0YIMZ24v7BKF9hHhy
#zLQ2F8tUrh+rAm9Xq3HOa9iDyuE+MaeYJI3bh5kgNUxW/FRWkaYUBCTZbLEFzCrRmeCizzIlQ/dkFJaHouB9M50LGN9o/JMIPvC3
#OdEw7Fox39ILE3XdxnvHbSdgQgusBtPrF3RbeFEE7bCjYcw5Q4F+7MQFfcILGdEyLIOqFerqr6EHlLOqmEQrqsVzOMgyetFsF6jy
#RjSKH+w+U2w85f7sfFzgBNrT7sgcSW0jxSTQF1OjwDSba8lIypsOkQ6Z5EFv46a69LQtMNCxHW6c2h7D47Bffy62Kds2GZ/+IVTq
#9TCpRt2M0m8hZG2fNOuMC/BOJYJUSfI96DTaLiaVBApJiqNLOiHIBOBuDfBLwA0GsfVQSpj2xvAMLbYUTlUD/OJotWa51gSomp1/
#8LgxU7b1huFoTrXdMqWpiLnoO0ZtJWZhqJRlsk18FWMt8smhWNJbHde4JzHendC2aE5oTaTtnWSOJyy4NtS/YjjXWaiX5bMEd2PR
#YmjaYvLZXKU/Hx5CQ5XdAm7Pms7jUOFiJh+qXXRxEXExfnTWcacTD2c0Sz5XD0/f5TPEsW3ObGJh6+ciI+h2CP/f0fegK2CS9B5V
#/E0S2Yj6YDjLzHo20pwO7j00w7iiOdmAIpkn63rDGiQpIDc5Fc3BVER8FItNiqxpUx3wWrY5btByMy+ybDYq/sUzneU8lZvjdkv4
#Ot991kyko0rFYaOO1xoVGHlYbwRfEezRaIr7LXhALGyGVDgRxf/iwzL5YJOEEB7NxDMwTRlkbfnUl2ohrifSVCtwyHmnbppFRiKw
#ZWIA/N5HvH/ZrH8vyfpbHNIo2+Pk9ehCes57qFVTbc9LKEPMUdLHHAkHNqaGhpo1qx06Hp+RQBTWMJEntxJISqREiKdGZUfrCydq
#sYbZNAnwomuNZt2MuvcesiBtS6gZFs957kfeTcYzZVsDubbTZLA5r5g+RiqIwt1VEoPhEDHMmJd+O8QF8AzJ2t07RW0SBHdZkI5O
#QglFEZxw22P8mDrartxZWuqMxD0HvHXUJrfHxk6pw+esTJNdF1wmCbcPEb/gzhGzzRlK/KYWL7b9KlnxptUK8nzsFZtRD74zVmd9
#uCD+mPYUBaA5sNh8v5PoSXhRYgPTvhEqPS36nRn9DrVYQnhk8yJs0W27rz0GOwx9A9kv0k0IeTJk2WRmNuHrWDhy8Rl2+pHRbHsl
#RdY3zdZgvlyzRXx9pC1tbKZlDlsdGxjlqarZlzwyEthnvDajENuzD2w7Xi2FiE5hcg5bsAbAI81aT4FLXQeoiqKKS4qYubtPRpZC
#xRV3cnhYrYF4LnO1fpNwaKcC5IvtZMXsiNi/gJpVqfVsjpCo8PIZTTEemsoBKY0C+tqikFTGNCBhjabjWWAa0oy3iid70FhqcqUV
#5W3Xa6ztEE8AqT/DiWLV7Q6juooE15UabrNJOcSciuWH/bZ5XMNGZbu0x9kw7bHiOZFhKwI8ITBPtWKoKWA71cKs+WparI2iXxoJ
#pQG0sjlRNdydgzVm1sXmiBHrjsNS/Q5VWk58AgqjRDu3yMCaGQkFVgQjfkZxux+0qAhI/DOacFvx6bo7zwPm2I1RpCxTVsyBIIn9
#qX46nxcsPx9MDJ6OG7YfQShVfHLZsgG/ZVRCFDTzqkqnm3FXmtYNlMXC/9WAcTaDnpwRXtWNT+F0NxHwI/IOd/S5ENEZV64DUY45
#EI2EGi18zj4p7v4bqtKc5S1r1WTbLwWloPkoorMMojN1lkBEdat2cFwyijKcprk+rNq3/72fjxUNCNTLFzDJPPXRD3kO+mk/3uqg
#RsRmXfX0iKeeHulPPW2ORySlkTWhpToqjayJdmJxO2AqSDBRNZeOplLA5mfSJA/ODoeVxd0oye6zqLMKa1EugyIimdx2BALFCZss
#tmU02lmJlOFKJKqEwT99kIwUcd9CAEslgkDCMTeqlYKSup998o0g4d9NXVVJrly0DeqjxnbojxjZJNIR7jUeVIQkchHG5CsKTqEM
#ifAOoY5FdGpu+qoE054qGqss01g1fCqrEK2JF7IxEjChbI9CKtchRK7h6ZN8VITe1CttOWAUIW5WvOEiK1tnwYTgK6fRFvTXQxLZ
#Ebeq01Cqupul5kNmuQBEeyW94EbuOxqCwLbR85MMcZIg36eBr4t3fkr4jXRXfwUi7mREl/R5c5jjEd7R+FRAWSZHtCYzakUMmaZA
#pFolqNNKBYWC0I3P6qMGRQIcpp7wlAOZbTICYrsdLFtcuu9PPSUppzgibDXaKJHLGohWI96SHxLH3qpun32uixFpu7UH2Q57olVV
#9hRnfK16P1Ml6AiL13U5ji4aBg/dB42ufiopE1jsUbxhBOBVCef2uw4ESmSyBPrNtqxZ7cNdReXZUtQGUyX492WI7r4/bQNr02jw
#peDMP+ZVCGe7FX917E1vky5TR4yXuugL+9lmjj25XXLpiE8uZTK8039EaYgZaq4WtDD5nTqhxUuCBHkUaLR/NlUOvIXWUFEcVOaz
#d6HoL3RVtgeo4EOdcSK81FUNauc45m20j2fk4NhQ1Mb7sWNM35jDOFTto5B85lEwJ+MAh+OWC8aJoHqFN6sYj5h02ZOJ5lW7rRW+
#7kgyU7ku5qiMop3uub+pHz1dabzxan7fC8ZhTNVLQTYhqerIswFQgFoa8CX+5thzdWYogoi9UDWyglGx6v4VRkZFAk6mKLGm5ugQ
#mkF/0CQpH0aJAhId5AWSKQEYnrK0C0FMCvkhSBGpa522BUNY1lRX8892UaOpbTVLQU3ZxSonP9Rq3YSiUZKJ3A0eFawVH2rcUdj8
#DuGYslZPdfwg4wLKGn7mRnc9PBq22Rc0oICiSSCRlFyEKfaSIABYHdx7VJjwQDeI2IGhXiqVTAkq6Xc+7xoCIjvNOnxmesSAdCKr
#WJX5fxrTgFdKsv9np8gOOQALOyuG5jNPsbwa7kv8WK0LZR0O4Bso3ol18gV3bg8RNiopFRcK/6yg/Dcc4pnD8RZvSfIwnKMd1uNB
#0krKk4CtsjsTKtzMsC/xYiGUZs/y162Q1yQr2YVQ/CJtb0l5SarPoBjMmokXnaCFGJ+31OeCs5GRAZVrOqEUd7yktzuSqt6kNFxt
#Ao3OAa8y47XnzUzGaxy14bSDhkBvPf3So5JyJmiLYi3Gp2pB7xlFk5AJahKoYt10nKAqIZuNjtL/gYqMcmPNkq1vixKC6joWSGl6
#ywyhjgwphhpGq8bkjolQ64zVNPaVuUSYGS1BLhNB/eocqIGEPFnWJ3WthdFUWE5LU+2AMMVohZREDllfVBQUUpLcnM2FqI25RqGQ
#ktLnt9UyFF7dlwuDoKbDRE3jI0hPOTOeE1w4mu2i8ZzLhftjcXzMVi5c+zDSJ2fcslf24b1ABcOdBHy8i09Dw5YE6vah5xDBWN76
#d1B2tKz+5Oqga1LL2k5vibDAemvbVBxYcaK3J3cHhrQ1N73c30EJlxfhKR2UcA3ZuYoRBGHiRJjFHRhi5aybUMJv4aSHUnaV0ZHO
#mfWyXDJkvC9rLsSCSX6caMHMJsIsmOG+jHWYse5bQDW5Z3LFqiync0tnXeKceiltoS9cb5v2K+hFXJzTMiyn7TewuzkuZUQBnQg6
#E6RY3PsEBV8BETIAeESzWr3Wl9I0IxnfXDGa1ZeC0tgnas2ibVCqSGfMZebYu0EnMtYhIVyIsqpPf3+PwPTK3+QxG37OKEje2PA6
#s+XhjiAqXmRthOslkK/67+W+E878FQvmtOfPlQvYdbHjw8yum/PsuliLnc3Zr1wTTpfRyckJUcl0JORUgSciCXFJ9vZujvwiiB+L
#EW7OJ0kZFeKstr1+zNTb8BwuriJMjb7BLnis2IRlGXZRd4Bw6LbRCkieLsKeQ4KEoLAszdzfJ+OJ/IW4YYfK5AVf8hM/V54INGSO
#h7VjjgebUcSCMPsiaxaEQKvN8DDmcO8VMSmzBL5cqEgKGo5iVM64ORc9R9SO6iAO2cyehy3RrAWFEnoF8xAcUbkvF05BtjOup1nR
#KgRDiQCfAX6giD7pHfHUch7mlJR1hiqH7pC5uXB2sGdr6Ke0TRGF25ZvtU+zQ2cyE5aU1e2OnC5VitJmbgjlXhlXxdpoTX0yBGGO
#hPm/ynV8VhUuS4Yl6fJV65IBh86W8jxAKHM0i1hi9J3Am/KQEBlZphnNyUFHLxsxwHN6jFxg+C6IJrwcmr6gIkwzxJM7BtU2tEp+
#RZCaQSoZdOkKi97xMpKEJRQRTi1pmcbISUDTlA04QFxglmBTB32teaqxgxtGqaZrgxJvjEacCB5DQ/moFWfSpETkefZe5lgJhdHP
#ypcLmTjGoM6VivOsEx05Vyrkjy2UFjjh5poRQjQFqBErj4MR3nQji31hOj7SKYR7Ym1DEwQkE9nFnbQeacddmFTCL7v2ADZphJTg
#RdKNMGMpvFZd1nmS1l75spJymsN0gExJsV9ypGJ4whbcR+EMNfWPvOdVVydcW3K667y0od5QiYQAJHJK6Q4Y1lTnAq4cIZZ2Foqv
#lLUv/tBYapKsHOGNDqcklw7NTV/gJoWbpcqaz19rWPbXSnil7EIwNpdNflYUQS1rcFZB6usyp4yTFZHnKp+q+CTPcnFYpqlEA+bP
#hqCDXMZFB4ymSWQUfQACFCcFFCeYnttPb7A9KSWzKwCMyqHjslWVMAxmIHQTR2haIIEgS96raYsaNBkePfIZJ7gCTzYvBfVO/AyI
#gm7zqRArwVr3/MfdcoE1YyVF7LTkBwGvyvWW13GmTkR84OoGCcvRc0r3JSXPyooJZNl0pE2UYLOipoTk2I2pIBCr+4NSMowBUJ3/
#0wJRy976/nBC/Jhg2cK9hALubqR0UOyRLi6R3dBZHn3NXXvmmtDVGyEV9WyPqPx06ynq3FnhNOD38ya8VVTLsod+T0raQ+jw53rD
#Se57UjkXSu22TAM9bKNyCeKVIhAnRSMd9nOo4jZ8J5N2OtLmIaA9phJncDbepSThHPSFFvibFGZh36WUTJ0YilSQoUh1ZihSKkOh
#TBuHENdszSfZj5VzEiYi0OuG+HMJP+Jn1KfQ9vVZfBHz5/qyGsqLwRk72By67RiwFl4Kxyjmso/iVo9S7g5KShYNpteN8swY5KYk
#C34JDtu21IGMuiaWbZQN24nZRmmiaJRiDZP73+BtpL207QUUqIetyNyP7xgWTwGrQZlxcSy5hrgpqk2aLUMbx4OgXV2sPR50NODm
#tnHhuEFKiwTz3umeaT9F8o09Xmh3zO7Tf/Ia1lL3ZDXdmu7lurFopFxKlMuRkGQ2w52zd7GZ6Ts9De4DqFBUmAwU67SU9FbDdeC7
#i6FatgbkOTQeKmxZde/A6ijGfBbr423/ETtKqS5+OmHqHnFWCXm1BusGbT45XrpVaak6Gr9Wh/Ic9FL68BEFtZqdEwrO8ko9HJLq
#HdCL4irMeYC4XmpIattkmOaum7mHH1YR0B4GTo3qmvohoUmu0YSpMyG8XoJpFybFpAU+501xrusCeAZtkEVKw6XhXs6TPaLK1aDC
#DuuHSkmGU2EEHcBN6mM6QkOl46qjeIEWyQ5AHK5MD27ewCklkwW9ORezXO8YN6F1U4JQO/jXSWbgLkvZz17CcfTvzDvLynf287TM
#Sb8SQIQvCTk3l+hpnZFdUINDiGaigHCHUz3OY8p0PI6JxztZxZCQJEaOgTAPZpiPLNCSiKynEJqc0mTV1eV01VtsV8IqFme1KJlK
#6qlclB8wqOWwT4q+nRDUCBlfUiIzEw5xunfSbkUJkRI6BEkkTockD/eMcolOaouMqrYI0p9iwbMmCe2bGs7q+TcyimkVHTc3GI+8
#sqohKk5/oKsKVpwV5CZaqxYaTyFzPO7Wlq2xUNGNB/cO3vJxQa4YS7Kt3pyZqho2O81GSq2jnOzTORN8AKmnfed4Kbkc+jtLJRCu
#FZ7dmyXChD6HOEuHRK3I9pUMIA2qWRWnaPpJRzgn0JMO4doBa9QfqgxpyYuMTHefNPyQ01faXS6UpZVUPKx6v1l35AUR4Uaz1EDf
#BmhWvO+QGqvkHxv318Q31O25RvD7nNQ1CX/MIS0L+34Hkzm9izu1knIgZFezeWDg9WbgcK1ewY5+m2dHo0+XZF/4XTnTvJQqmuc+
#sOaSOkPK+yQFjpL5zWeOS/ZjjsPP+1LK9tYX+WZJPZXDI39+lbVPKJMjfDvYyEPxYn9MJGYVD5ywZunSSqQkvTkdlQavu3CbHv4Y
#jlDRjgeh5eh92PF3mZDz7ywdJYso1UD5DJpdMUA0B2X0gY2+N0Xd4S887FrIFDJuS94ZuO4yBBbI52ZAYOwjNyGLh5+YaIYrCfBN
#Rz6RXoYdb9hr//liAPhXuu6lQmouH1Gh1ZcNtoOXs8/ZjqfoUoHSc8wQ+JM8CgQrUUjJo5ByTDClJbzvYlu1WgFdTMpHD5qpLmFl
#JPj6/dTEMppWK6WeIhge7rMNPlrd9rj/9IDAyQOd97zi7ZL0ZVAnVQCOqXMwCPmyhHNAFTPVDm6iIHscqsjqdLJu59MqfSwzfj5e
#0psVFSEtMrKZkUxJ4rWpZLejHCNUIgwh5XCUvdmGIC+aFQdphjgrcd6x95lUzB5WdeHNPasnqGToF9w6EZW57V/sVVw9iijgsd47
#vlOoXwEp15oaMDZG3dO2tkA+C4oyIXkJ5GjQXJ+clc9mxsPF8JPC5BVyyMIOmeE+z40O3/Wdd7mXiloaREccKRfqN5X/3CJ36QOh
#zuGyas53vHRw53aVzxLkqemhCx8fhBpJZ7Id9IVU1CmzUGhO/uSheRGCBkIZsvATXXOlsRLdooVbXU5E+zuIvGiPaW2TbItnwYcE
#ZPLUflZfsSJyAC4ziTI9Mzqm0q+uB/Z1ObdRwaNzz1shihPsprcVD0ikPfxwL79iCGYt3kq3pY/7d+AsK5PqWIYX2UazBtTU4tuT
#aJO10OjkRicnC+0duYNGoDD2zUeRQwJ5rEbKpzPweXL2E36itwr9wLALvikpltgNNx92o83lk4ncKPMOaVf6gGxmWQ6TMbvSw+0H
#W9cigfPjA2HvTTdzE77vK9Cqow94GBPGViwk2WzXMz+l0Cm3OqleZGes7dkPLTTWdo+cYn7KOClOJ5c0FchY9gJOcaBavdLJA4KZ
#7zIh8CffYyBeQFnDGu4v6JVUN83+9dGd4pylTRoa2IkmUKutGElCgpigTHzCrkCb3U2uuQ6HEwXMatkItUmejiVVZLBD1fAdtrXP
#+RgrB07uUbkFLNFRlwAvV6KWkk8BU+4z71I1iTIQY8WOngiZWSzV1zG7UFAPDjnoW62sJuMKKlvnltdddZbyp8P1Rb1UtqqAEZpQ
#tndCF2inTw3yHNETNiz5jmxTsjRqIz6l2yqF5cHV9NIzNshO1PBuZX+5YeKVgpQBZNv9VKCduR2pJDGdvc5UorbZNASaEXOBJXAu
#gtoInrvIGpdPaRZOsD5NMvPGs8Y1y6zPVNBBslavh7h5ZCJjPBsjDw/gVcinneqQHo2X8QQq9kD4YsVzY5MgnJl2zCiX4QIrxVCX
#ihIsK8p6Hm8YDa99pVVK4SCVUDuthOineFFYpPEOrVGqAKWM2p4aT0TJJerbnUy1jxOvux+bG+bix2MGCAfNzUeTGJ2eyYVyPppK
#NDYnSDRPod+qMo5iMBOJhj3ORlT/3D6ZAv51l9fsxRUwB3RRyt+JNOtbyJtMJMxjq4s7V3IWfQ0kH4LRVGmyOiZFlmFO2S7hDrPM
#r8LVIcsuE1BV4wEk+BVvM4e6eArXUpRM+xZGs4wTQpkGZZEoF29k3lBdr87QRRNudVoS1al1ViTo6sPd0NNlz9uxP/Eh3bKGsB+1
#4lBZn6wBsxZ3Jis78hsJ+MllMvQXfvx/k4BX5iWzqVwqkxzOJNLzEslMMp2cpyV2ZCc6/UygmkfT5tmm2epWrtf7/0t/lsNaa9ON
#etNZMVBttaz80NDU1FR8Kh037QoeC5cYghID2mTNmDrUnF4xEIO9p9GvFPs3sHI5mk41/m5AmxEXtCVXDGAZjWEGfmND2fTIgIYU
#ZsXAokQmkUvoA0Mrl1f4I9xmAxqjUVDA0MuJ8rB4EOPteg+QvBR1a8UAkSPokKUDD1FaMbA2NxzPacmRePKQ4QRgTsb80wMNX62N
#uZdKgZhbby27jAXaYDXp7VrvUini1cSxDVVwfO6YVo0MZ1KHbMuYYPpHRk6OZUfgCi7gL9xriaPwCV1kR8T3OCnXXPZ1xYA4+zUZ
#cedfTC/J9wAHsVQ2mhrV8E8M/yZT9DeZjiZT+Btv+DtWEgpQOXgFJfBvapS6AKCzckdjrP/52ZE/Cv4nH7l4tdWo79BvdMf/yWRu
#OOnD/+nh3PD/4P9/xM/yhSWz2JqxDA2XfeX85fhHq+vNyooBozmAD4ABgT94FLNWrGK4CKDxiVY5NjIgHjf1BqA0JBEYjDGgcYXP
#igGG1UoGsBUcxUU1PBaiptdJ4jFWJKOaqIcJXFfQwQLYcKvWqhsrD1uX0tYZNh7EuqbmtPLwe9LQjqPIDieqHYcnKx+oN6wxba1u
#Odo7NKhwzKr1J61bPsQaUHpYMpyiXbNQzpQ6eahtTjmGRsdgHMYzu6xr2bVxQ0tpDn3ciUMvDB5R4mgmOVpoGFnYqhpaccKmwwYa
#uhXFB00NI2NgoFAQ3tZrxfG4O1eWbVqG3QIiaVbyOPHydBkFjGIDZB8sii/OwGFI5cVgQyvQ+NXC2zaVoa3v2KmManRGNk5o90mU
#V7M1VWtRDJNul6Q+8BBBH3DaZsFsOVIxwnVRrWzW6+YUFmbj0XBJVgwAUoQvktPbUL20bLMDw1zZHjiYqk+3BvIacUsOsEtOsWo0
#dGSXBqLawMEVW7eq8H4DlKblhaKnGIV1uK7wnlYQHrmTC89qzTWw3yb0Cr2BXTcb1aTaRxxy/HH4Dko29FpzVRNWdsb3heMnDIfW
#QvrEUeaUVjK11WwidVxPvgYHYTG9WDSsllE6pOlMwZbLy5/kz6CUGO1huADa0SatByzUDG+Kwqto4dbRCX1TwFIA+phoFqtBCMBi
#MINNZBdnzIm4dqo5AQ1Ae3XHhDfWDNtPvEjRhJVslqIaBqXTG8AkRh2hEMs4Zt1A+MAXFRizNohXZ2rjxkyEPmWB/AYlWvGBWXVG
#u85Wuca3tTdfMCrgvfAZwApUJWjdhkk8VozDAXSnNYzmBJuSqmnCrlnjtR1n27HmQCHdmbCNkla2zQZOmq0VaJPZWsvU8JZ3sWpC
#XTbBdRMrVGzDaEa1GQxmndJMW8OHMM0zfM4dy4QKWsU03UWp4dLSQyAARaOveTulCjVKpuFoeNyyDeIu9plByfaB3ImiPZiGKgyh
#gVDXqtFBQgaOG3rNVopPwYRVguKOCxBx+v6Eg8dVTxRi2D+3DDLFpqWZZYAPR8tlqPcanhgVxUnSaTIcTbcNmLcK4EsDp88CSafm
#GPUZjbsPUDWnz4mq4Z6AHhGwsoBsXIjVhAy3ZU+aDcsAZADYNqqdAgADMwSI3MbOF+HRugm7HNUON0BwaOgt+DiCR3miyb/tTOAj
#RzvNbBRqhrYKCLIFtUoGQCkqYnCOpqjTHHPTbDCEHddOAojFica2NOaFBQUKQL7ZRoEpQwh1cOWgDtvZgModAsApvdnftjwct2TT
#MBDHwKpQdjVq1zCkpXe2YfaOMaNeT2t4OFUBcFxcO5E1TlvNnIJ9guG8nDThJFahvGnPAJjUKkSfCDnoOLYYQicdV5gnOqItrBgt
#vBVoSuBM3DPYIum1OM4rGQSUhGQq5D9V6W8HHkYw5Ogw840ZraxPmjYQG2nvbcvsnGoAoT7ONhy2nYhJpi0tof24dgT/GAMN7EIJ
#h6qgKRynwDkMTjoDSAMHvBH+A9GRyLFKxLGEwcx8EiUX+gO1LJWKEXGWuaCSbo9jSQDicdjZIP6ixmtAq9pGecVAiCJsgHMEtQas
#Bwq0y6Yb9f5bsJq+FugBGmJA0E6Opqbhn9oash4ASSbszlivlpWKgJzqpl4KlIehO0MAcoBMY4AvoFk0ijVjw4lEjNmp41NmuZwa
#AGSwYgCLix7j9RB/V7RNB8hWDUCz/68WdBujgxyjUUMrcMloOkaJfz6zQz5P5nanahgtfw/oTbzoOBJz59hFr8AkoDnTHsJQcyPe
#qDXjm4E/LGFg+koJ/MJqwhKFFx7iwhLaJ7DuZEUowSQVWAJ1PNA3mDt/7BrMAXrvMeMa991budyZaRTMulYrrRhoTtPhkLI+bjSh
#4b/kCP0b6KRE40LKYWzzqFqn7P+DmrR+xoSatIzQpGWYJi0jNGmZuWvS1Dn+O6jTCBCEXm25jofyOvAFZ7xmCfBfhDICgCYGUNSS
#IwBFTX0yTiVWroPfiHM5Nlw+pEMrmC2EtwNwDZtF05ZjujP+DLgkDpWU5BJmDdvHUlDO7QE5f7s7UK0gRB1g4hoEzpOVUDAHRk2M
#QYC50CEuL6AmYDlam1Zy8Z6ulw8VVtIoqDfSSKDXMVgC3DJweQK0PgRvaWxDMDi6wImiEjRjUAL/0htMI4M0js8uTywTGHT5v8Wo
#yQQnLTd2NV43KjpQqQNRphpzJfl4UCQDxkdHoC4Z+Gnkh0/W6yS92xaP+gKWCHgeDacBizdRbCgDwNeAkS4x7ofqxHn3WLcoY540
#H0fQnMKAdTFfLCdRrNYsmwOBAdC7gZVHuqwyDliqizJtsBY9XYmiHEA53vhqlfUtwUr4cCUI2VTWhY4hBgSI1AlyVOgCyVJAF13a
#JuJzJA8Tjgtsy5smpwzLLRflC8/cjDU9sNKbWGRxHe1ofVJfR1VgMi3sjenRFk5Uhpiibgfp/1T7HxHtHdSy94Na3uFstpP9j659
#+t9kMjtPy+7wnoT8/H+u/w1Z/xBWMefj1eb2je76/1Q6M+xb/1QynUr8j/7/H/EzdewRqXmvwKslI/Nej3837TVv3oH/wZ4Ff/aZ
#3vfOg/c7e3rnTfPOie6+y/yfLP9m8rVnvWPeK3KvPGCnc1uv0l59duo15+6671uO3+k3n7/vFSc+uuLCQzf9bN7+j125x6oXf373
#r256Q33+87dfPP/CmP2LG9+44v3T2X3SZ53+1fdNTu88+8Lxuzz0T9e8dNNBhxavfOq5l17+7V+nnM/NnnH6aY985su7fOihy785
#ufD42T+OvHbjXju/oW798uSfHHRkpnJLJblw/T5fW7xw16vvOWzBa6/d4/6zxlftsbSw/i8vv+PKqWuuvv61D76cfv0zXzloweMZ
#64N7rb529EMfuWrt6Ve8fuq9d33wt+f96KUrFzzaWvf+j/9X9pwDjoiuPyvzit2XnXfeu8fHX/P6Yx647OorHn1v5LaDjx4+/389
#mP7Ms+Pfu+ThK//22/XtT9+/eP+Fu3+89vTuM2/Or82cv9sjt+zxq/q3vn3xwjt/98FLLz1s5XMfvHThV874l50vPmzrc8lb/3TX
#0UOXHNs+5QtXPLvnHvcfnHrjI1cc/evfPfjymV9d+l/N+JOvuSlz5lkLzv/wEdc/+Zrl//rivqsPT5191P86+9MrVz9yw2r9hH1f
#ftspH3vgzp/c+Mhlj9+b33+nnc83dnlFujJZ/cXHf7P/i3/707Kdxo2Btzx7XvYW5/uvOHjzp7SFT16WcC4eOWq/0h0vm6fd8sbN
#6564+4q3L0sUnqucUC7fctvPt9789Aff/uMjHvvMnuc/ud/IAbvddtX3rp3e5baji39bedsFv9vpozs7F92eueHSO5575+8f/92/
#rTznBz/9SHThty557SGH/3znvW84ap/D7/rpF3+dWL5bbdMPntn1ZXNX6zVPZO694HU7zd/p5L1ae+92z6ufPDC+9J6M8dnjPnPa
#9549/afXvPnnRzc/cMFf9nnucwueX/6bd5/70BsffNl81Sc+XN/3pbt+ceLeTzjv3L2487n3rV2/8qgF73rR3HTU/ROnnH33H4cT
#gzf85Sdf+NjCPVd89awHFpx8wvofLXxiwXGvevhR/Xdf3fU9P/z98OLHbjv1up3fmp13z9l77b3wxi8NnnDJ8+WVrzrtG6e8+aB3
#v/LOoWtXnV144OvnL/nk1vfOv6VUuucZ7dCDN530y4d//NfHL/7FLof8es9Lm0fq73/h+cKvTv/rHZd/7Psf+NytW34/teXZL+3x
#o1T861nn+S996aPvG39i8x2Rty8+5WsXHvaGsy9+cXlT+/cPjD18y2Tii2+954DEic/94onfHnn6M+O/+P2PLt/3+Z++lDzoqheH
#07lr9j2oEr//+tFL/jAz76+Pn1lrfPE7Hzl1eFn5u195y75XpmfXbd6j9cKx+l++fntkn8y13z32m//8xWMfX3d66guLPn7ZzPIz
#13zyntGR9V8581vle7/+jcgJt9+yj/bgW/9dN/9y126Lf/z77A0vX/fVF8+9aINz5dT0Rwc/s+Kjx/zx4i83j51qrfv31qlv1qZO
#bj/zz7d9ZtPhix9Z8+xDX/3rjdeedNKp51z4zPTsM6fft3TZZ086x3jbwuSlH3juj1fc9cAjP3rwc2ueuumlh8/dZeork7GfPh15
#KnvxyI27vOnWyG43r171yAVfPOSu7yy7c/NFZ/3rmfu1pr9vPXL2a69aUm0dfee3n340ORabfN3Ny24or7rwhw/c/dhpn3//h565
#/MgXVj+65d82Llr216e/v9uDf3NWOPv96nv65G7je0Ue/cOnVzz7/OhNbf3SXU7852+euMvPTrghNRazX7n/fz3/sV/9+Sc3Zh7f
#suncK6649dGDz0w/uHDfQ9+xzycO/IT10VePvvnajQ9d9Mrzn/rQlQ/u//X9nt26x2MP/HDwtdO7PnnJ3uk9nz34gp/dfdStl+c+
#etP9P3qD037o3NO/6nxqzaYPvG7/Y877eSJy9u5HfLj95q2rD3xs9WMTf37vAdf9y2WnrdzvDOfpwyr1A4cfeDb33F7/smXeyBvW
#7rzqum+Pb7hl9JK3Ge/c9567P7Ck8vqn6udd9cdVX3/wlj3//NAbN59au+Xy+T86z/rM7ufsfsGrx9bs/aVXLq6+snHqBfOvWH7u
#N6aOuOGv75753G9/r9/xnnkrLm3/4Ia7C39a8zbr07dtfPWeG2sb3jGx//6vufzTy047+sxfvj32hfu+vua0+jVjj35wz2ff+KkF
#qz/gfOxDB6Z2uv5TH16WvPm+paseHrr1nvkf+XF+n28895bS9QMv7Hv99e/Z5YV9P//T3e/7hPXtvStXOD9ZddZ7L7j7oV32iy5/
#6ajvX/2qp44sr3MWP3HVq+560yFTpXsvP+iqeat2PXHgz6d8e8G98944sM+RF4ws3/WE0z88/xuX/uH+5afe/Punlx1w/L23Xn30
#4Pmbv7HumgM2X/qZPy96f7aqX7X2P36Yvvb1Gz/VTDx24dN3JOp/Pe6fdnrfrWck33J89L43PX32167Ip/7jgucvXnjO3tdv+s45
#5yZ2u/OW3N7Hv+OA9Vfdde1/btVP+lv+mMw/3xn5yKFveO+Jtx615JKjf/nSDxZsesVVP/j46W8+4vZPPrngnl+/e/Xa0fUPrL/p
#k5nbtJuyQ5+77frbBq47Nv++S59tjbz/vVefdt4Lx+eOP+eJJz9+zx+eeGpyuXnlXk9+YOnJuWvnZ6545qXV//ncpx9af2Hysvbo
#RWs/uefBR8aPPuXYfY5/7JonL7/srljtllrimavf/vax2g9XZTdvPuv8u9/16mLtfSd98ZyL3/Pw7b/cMvobZ8/omnuKb3r4fXf8
#7C0/3f+KR/6cSjxV/dvNS52Ln51+/LOnj995a+z1525sbS3/5uqT2+dkv7j+0HtvfOepO190Q/T8T3znI8997+bNT33sm4mnGi/k
#33rGXj977c9OXHXILrsPHHzegt33Su31RCJ9aGLN9x9ec/8uj598YrRx/ecPf8+b3vbp9QPfmP/s/Ud89rKbnvjaPd+8Kz//8Rvm
#P7P6xYf3/PXXJlcfdsirN798wMKrn7j6lgXX7Pru647/8YPrH171pX/6fen8ofsu+927djsl8617b11//fyFb91v/s5r1u+yadHZ
#xkUHH/WtVz536Tcu2uXz7/zT+jft2ph6wyU3F76XfnHxXd974/2X3pj85Vl3/PGCC48+/psL/zBx8T32yOnjA3stOqF95C+u22No
#+a3f/PKZle9s/Znx/vLOX/nK0h+/9Zl563Y5bs1FC77w2X+9cd7m0ZO/+JprHkms++75b9j/l8veVfuPxd+/qP6vz45Mnfa+cu1Z
#+7tvP+i6x8aMzU/+Kvfen1xdm1z67ewRG9/SWPmj0z+0S+mH8fl7fOqtd5w+MvTlnR8a+ciy2y98Zunai7//zItvvegPzxSvvmb8
#s9+94/abFxxznvnnef++oHDKny7/w/LKdY+/cPsXLv7dgre9zlz05hW3vvOG5L99b/yk1b9ZeOfras7B8+899T7j7g3163LXnfyJ
#//y3b1/2kf/Nzj/FigN08Xrwtm3btm3btu3/tm3btm3btm17f+/bk3xNmvZctOm56i+TzM1kXU0mayXPPJwdTFlCrhoga/+2e40d
#0TNiGQ/ZyNP8Wd1KauAWS28aFqNXkf/hwk/JbZBhjmEcbFlzZwqNXMTSrP6oBFh9LI5UDtJJuFt3tRfKKnV2tkIu3faqk0zya4IE
#sjqEBAZnYmPjBVIaeCNw0NzfF7zCCUEBBQQIE/gPI0FBwgTXT1tlR2wsMdXYvKwThoXgoDmRDYSEYfC13tv4QVMZZ2aQMmljORcz
#yMOhhbcqUP00MhJQi1ffQtW3Xr8mb8iuZWurmrXpcWCCH3raYwCiABdhcJMHXwW8XUstb/C+yjMW3hzL0NjgFBttJ2o8qUsj9u+I
#DtrK/KQ4b/WbbTZvBcf8nWDe45t132nrGQpf3jONn5iJOYs0vGUIHSLwAb2v8Ps+wYrphrZLRpt4t+kIqVlAYWnFZnM4H4iR++ux
#FGlEJJJIJ1DJEiZJwWq1XPXG9G7ZfZWNnTe0GOuAHCUk+FOR6GYAEI3b1yyLvVv1Exn3aAdogAgvB/ZrCZpgRABd8B0cmm84wpBH
#LLUomWBCwTAMAGHjzBxcWWMgSBkKcBAhRFCIEKM9+BrlkJAQk17VMcyLdSUQBEgiumgKLAExEpXjGPWyV19cfQACCFBQiEFKKYY6
#qUTv7aUHPLYz5sICRpsD5iyjhqua01GvqEdNLEosh1ZoXzWjuloUjsLPC0CLcwxg0qFsihgCHoQLkBQi1EiLNEg9BIqQEGJS+jqW
#ICUXwpyU32NfsRRg0orb1CxsNNdyQpetdyPCAoKlGwTAxqJCw/5vwQP6HwViNIaJESUlxKRSFcm10VsVXNTU5y0UlQWYtcpdY9xc
#CqM8T7e1cWiMGOdwKgJqlZmBTDihhgn+W2qWGppiYY1p2bJubQ8SuPl5TIlChPWfYduVUVPvfsbowFMSa4GcCy7bgJFvdT9SrbCH
#S5yRhv459MD64BNpwy9BaGPvK5py5iYRIuhjPJjKLRMIIp80EO9CbviDlUKZXgjw3K44iGJ9sXy4AgxiGAhKQQFFJ5xQDL4dbCjk
#GikuulgowK1jyAB2dcMa0bJP8OevYMh0BhYwRDNYrYDGYPwukW5JfbT6TNiG1wYGtNFHPL9lHK0a445RqGTTx7Aa8zTGQ0aIAury
#ynOCefK0zea1p3N4R3rajP0CUEnIPKCAjTRQwL4AYXj56Ol+WKJuRcjM/ob+J/J9BASQ3KXjXYO2oqfNJLwSCh3/e4e82XvAEygl
#FX8+vazkIzD13gpJ7GZIf67HvoZHaAFO7JU+wGB/302NEXX6bbMhCMrc2cTPRwfGcWwjgihDiQUWEPo6P+gY0mkP2QPMe5x8fXc1
#JDbQSYy3QXykJGOzDoXDlYgAS+qmFgx6yVvd2WXAhD9BBWHcTiAKfTAxJuG/b1wHcRqN49cIRu9k29A2jdwj1KxcD7bAxGSMrVWA
#Ds5diN18a3NBCWb9KRvnGXHAE39Y8IrBHjUgwK4qxM0JJXFNKD6GOfq03NCAIF3C1vcO52QkIjwtPqFZCva47BCMOznhwN6qrsA0
#fR72xRHMevB72eOqgaUz0s8BivYGyDwOK5CtvJeu0Hkrgd9LAokgwYWTcYjIdNi9t7JgQsN+TDygF84T5Qh1pssLjb9L/iAHIPOD
#SmskLakpS9Kagh5LXlzRtvkwFKkRqRGrEg3Ljwv8bMGn4rahDA/SHrtO+HegbM75wNYC07KyImC/4gv2ezB/VSgOruWK8+I/LwcL
#0DB9vFug/QNu5BP+7GwNjoRfYF7Dv78SNFNpnad7vzMAQB6w7gutdYAPAu1oKvKcoexxrr+9MTx9Dptt/V/m0/QjuI9df+ZP3IYl
#ur7PDfrXD/SAKHGB4UhW7Nbj64VkleVtj/tj0TFtfwFPwcAcp2VLv879GAQxxkMSiRQy3VAaTqcTaoVipRaslktWi5VS3TA78m23
#xbve5jXUvffJttv0+01VH7qPIc21btchezXNm5A/3PtFqSXd1g0w7esxkcJ6xnqHe02kJgJDcSskTEJwOZZmHY7PBGY/Pu8PRgd1
#cqFyBsVB0Ug06pK+nxpZ5g0U5RFqlVKNCKgSX6Va0SKyGS7Vi8PJ49yu6VxMxstCwiEwwvK/WUAcgA9sDiByP1DzPKCtjHx7YJRz
#pxUVqDACFYazfRg7XNiYjYQ2xoUO13bmmsMbxnpjo2jZ2+ZHq2OI5d32ERBOCBb43gVhxd3HJUajDGLdNl0Kl9XJUI1A6ZADlOEc
#nDE1spAvjG3sedFRsVgwd8cLrtSxq9Ns95YuldSesO9rgf6UfSHV1YGvTgrP3TSKEfUTWnxvXITfzXZtu/43PDC/kTXTnaesXc47
#n5Nau0/dWV1KH4/jyHm/K72ef4x1wTc3w99LHQ0+2pG7buRd0Tcg0+nOh+YQpOjJLXprV3acZ0LnL3AMYvHd37Nvq6x+dTT4O+2h
#yL1I3e3mrsju/Wi3n9jYwJ793ll6tpgv6R3AyyCHDkytfLn5dtToclH7u+PSxfnncPXfgqghT0cMKPat5zRjjTVEsMSW52Q8YDnk
#3PEnrSeQucaZMyYDQmrah5ftpMyZgSdU+oDYSrY9JeKlBy4Jc8KvReYf2rz6R5rIkAGVolFZuStviMwGUkFVrZ9qjVToYdsmNa/Y
#0JhuhHKIWcUJJ1Dg6aHUm11WpLI4U4HjHc0x+gBcN6gbYX7ReK8G6GzrLs95U51dSHHcfFdTgZwJlvllXEeRsRJAZIYTSFy34fT2
#6oQqF+s9Zo9yyBeDEkmj8CBy4wrNkdkqzPkETInmNIwjJ4yhLEKeu2jdog71QjgpFMF6UMb0DmV384TF2zgSLJcfTsPq2feTBrjg
#tefRi/kNqvG09ZLDGxqGox5iP0uzgr40Ka1cBRuHyQXIkk64sYhNQo2tmLClmNjJYqlJMgoKNfNIWyzJ/BESyaCkAWWl37BSuZ+n
#hz6ybkP6G03tMhYUqbygMNUbhF2YOWNQhEPoa3y0y32MP+wAE3X9jNYTcMT8r8kFJxHRFhApMDEkL+jqhfJCdyp1aunnlSCJ7rHx
#kiJGMoqU/6yAIFY0gkO7letA1UMX37/TyJ3MMMRSJsCxRoe8S+i1Vhcn4oc5gJXjU1EpgwTNUg7dXSZH5VIaxrhwMOIJlCD41a7v
#BQ4ZCsAtkUiTfoCLXT6OGIq1/A36B5zAoA3tPElYzAsZgCc+sGWLjE9wuQDGVCQNIyRLR+nlNkmEBLdUlnaFYqMzSV6sSKECrP4d
#VG7gnQB6XkaVWgTiCRJGraXfzBc79v7+ffN/J/1sXWqf+kJFak2BjVRs5HpvuSo5lVxEs2SD3ZIgAy34jSfCqB7jAb6vln4We81Q
#DGNPyjWGPhjFzlocW1bfXkrI1MCNx7CrQQxRYv6y+QrVSUoBUX7SayPptCCtNfFRHpYndsUWoHzppWV5A+MAO4Y/jbWTEsmPCoTB
#iXsvFT2Sf1f/ahzNDOM1Bj4g70WTGdPcXZK1V2ZvNs4jcSXFMViHUwOxx3C6xCDVBPRlwUxJUaYizGCjHIUcte+ovdHyxkkuv7Lc
#lobTUwVLzEZpokX1SgOp7I5jhXQL0chAKLMjC5loojjXi5Qxytt8lBaiWKqo5tY7LgZ3posuyvxtf9emo6Y4baigzFa1WiSJ0Arx
#GRa9Ljc6IYTqdA3VY0iG5USKSHuBv2WQ1uN7WaElSuAXlppjWDQC3pFEcS+2lfssntEieemjidTtywWUx8LF+x88vkfK9UIQUwc3
#DXqgIBhIJLc+BrBtIKHoWOooXGqB1hc6lm1OYpWBzlM6TF0XlkbDiKoap69Gv6diGcX25DxC9hW1jeKfh8dWEFN8R18x8ijjhdB3
#MzcIdiekjCn2CFQmvZRbPOXO8go3L6DI4y3EdpiozeU2PpYbDidOBCZtDFNF7ka3VpDIaWBscUhQ0yHiiJoNDmwhgVwg+Xk023E5
#lYprROPe5S6r53wuc4CWpLfbTPcqPtk30gKCs336kVswgTgDKVrB4gzOX1KQcYaKVcsth2lhHtBsTPIfqpvl06KscqCEG779C1OM
#EGDQSZ+HtLxA4FUKch1XRcvUSokcLOCkGJ9KRCpH/AO5F7DVDmgpQyNHGeA3PNt1H3SUrgJ1m1rZZwoxlZ8Gw2/7yNpC7Jmq+k6M
#hd2lCBcGG/C4kQWtsBBYjlrir5KfiXQgV5wzPiqliQat8KqbcPHpE3Kko79Telj8MLU504Wsm/r8i78j3PwctErJmgELpbdzWuXI
#GvYeZcihDGsdewIv/yBBKHlyj8CpMf4lBRYLt7SmJpfYGcMopSyOS0HaTVzjLk8jtSolQJLlA8NWu9XWHqdt68nu6v4lSA+V4WlK
#IPyNXzUr3JdEQTwZQ2AQp+V15nNO7hrX81mTaTljmk5up4wOy8BhzwAs6bqDGspQ4krRvcAfJ/kQNe842w7qnuQOTWO2npXPvBJc
#/KVBfpCQnTrC5xzZumzgOcShVMalO+JpVMkGjbTP/rvk3RPW59y7dBR/WaXGFwb8igCOV8SJxzq6HG7CqZnDmvn3PYVR07RQvyj+
#kPrapw+qcSMLW2FZrwg7SKc/7ylobAP8Yp3cRfrjj8YusfNFuRzpNNSZTi5zzZf6hMkSt4UAVWXAIyPqcfcBN0s+DShNZNo4GXmg
#hiR27ETk+dhl+vOO7Mws+DOFMNqUJyR/8tiMieMGOxXgUNwUYqlXn1KOXrgNEUKUbApdhqcAswJdEFpe2o3R/s9VeeI+Ma8RI9yX
#J+Ah6y8naVWLDO5d39dhFZq6rvQoJQuwi17b+dNV35ntDjBvnFf7cd9oSIqu99cl6M39L1Gv5e1koOzS3Rb848JRLE1z9+ajvuO7
#HBzMx/PsYg2I7oQg6QQY/KBG49te40GeQfds3tRNWYpN8ptGEeVTpkC0Q3Ki0jnMxXIi6dZt9BdaNwRFhf6hLATlQ5QqaULL5YX+
#L3exW/C8me3GHfOksPrlbcm6RpVKMByCi4H0AkRQhghir4xsjVodMPbOQZBjdsgBP1uiqIzrEpefkTVFLmv2OQB14YnXlNqBCNr6
#xYogOz0YeU00AfiCO8SyouJWmEx3VSqlffJlEtQvWMy6EvGRuvxm7k8PJ2Vi7SGo2HKJj4vV/bF5KajYdTR6mPQab+wfePBRkuNg
#GslsEcpMwHyDWsEES7lXPou7fC1KpPq57KdO0UP/dOPvY0zpZwoLzPm4cHKcGnXj59xeRpciKXfc2+GLrqwKRQ88CfWUbp0OXA5a
#cNtFBdZMaXc3qAsg0/GpbD7hJsJJtGujZXC4r3BQo3Htqc7LOGGTsBBx5CZYQ3UGag/AaMmaISv62a0d96bt7SPZkTBW8VStuwWC
#27G5VbOzCeRc1V3JPFEnwEk700wIVsQCig5jcs2a/a1Ha269FAxaoJfDk8wruhs++H6dMgWrmYC8UEiH1J0MUhB9Xe+DLfOX5fy5
#ODp0b1ziAlxFHPHELTCwp++Zq9cn/HlqlJy4XrHJDdMkBhQkF45KVRJdQd+xqWUyPS7+5fuEYuUSrZS8dxMfezUxcnHBzIS8I9RN
#yqfyuIRxAUYL8I0wP6GLfJnklEb4AghrRiiBcPXIXNMe8u67SprpylWfWZk3m6cQVp7Jxc1sLsHMsMxOVBHJCkehHqhz3IAD0F/p
#MNb5rMMZe2WJkigVXQguQX4BRl4pO2ardmuXTO3uuNkm8MIxUieA6ekZ+IL9I2zoNW3/jUXOlMMZI2kuHDbMXf3YVUcwn3zd2eTL
#62OsEU1cVpo6jGlJ18bOiXlfjoe63ZbRnpLv91AG/X4RCTQXs7bl32JMx9cSc+vEOdNGR8hfEOOnI9CswtDs9Z35GzNO6MIq6pva
#PPVzem+/BZdN9pIsJjRi6zd2vm5UzYxPSvRCOrzgFgrRw8EE8GMXiUg+1YWKUqK9GYSuZoaH2zCPvh/ATa+21MkLkPpapcuxCEkW
#wea2DZs8K7wuPuTeSq/6w8t+s0NP5/2+TFJYwAT1k3JSeZAKjzARC0ZBigRncfw7ZCDCAERFlEpHcYBN/HTprJJQaD3lk1PoaaZ3
#qEC/NXOlcGyd5WJ8Jlfpl71nHb7okAGXUHT6owK4YuIDaEZbrb7dLXZwb5DF8qXfFARmOsTqkOdhCD3iJ26B5B2EG3IXG2uOWYEC
#EwS5fjJsDH2Qg0uNqpOZYW5Csx6y+3KaKs2Qp8cUe2nDSSx4rBNasMQQSFPZhnKdNsLnlz9ZgdpUHSAlymhZ77Sd8cDBZIYUAzML
#d9S+8VPGnTerrlwIVMljtJKkru6dq3AWCGAlZshRp8zLP91MpU2enimFr0FMpw/U9I+ampCyvkOw78THngch83/uvmz6asvGQ2Jy
#A5F6CMVIqJ9t2FuiN3F2U660iNgpEahOH67vD/lvPkE8V/6LgIKSFnk05IQFgqnxxFthJpBxl30DLP2GWMe3oQr6TfYU/pM927qB
#Y2HKilgFMgTIQJwSyCURaZhDlSIMHRoEEdAxEFFfdt/GghoeIB4XjokQltsC/2pStIzb04iqYyueaGcwetmuyZwhWt0s9AgzysSk
#8DDwQHM5SNL7JAbbLDFLa5pdZiuI21vWFkcfsrvmemJtDsH0wN3wd8xhqzEoDuNk36LMscihrlIqL3Oo4LDf/qkbj3zvUlJh9Ji/
#N/5bX3QsozWWV9dThjBOi+VcP2wYqxFViZ3muY6rbNEFTblFugCXn3DqaEChW79Zac8s0WTVgwVOR68dJyfX8OkiJRVPsRNIdPXg
#+iRSf31v7Ct06bbL607/cV1Ft4HCKLDT6ycN3DNc4Vc3vntN15iZY9151u2HVjuovJpseF+nphtIE6j7Kv1iUGeIjxQRapWL1ddm
#lUCuSBHVtqNn+E5LboU2df236/rPNBvaHtlD2zquPLXtBOfTbBXctveFrAx6AQrb+Ek3HRFgaiKknIH2PGVRQoQMnG/MnzqCKiE8
#teqfn5HSmVIFlj5rpVqiVPsjfY7H3cqo4c1X16r7jT24ooPwbpMN2TTL5884FL6GGWpUBsPR1hhUr47DnRPNiEIOdMK+IAj00ebH
#LnzOZVmGvKjMRDZ8WW50wTpNWU0znTJ5IGdU66R93SyAFgx+AwOjcrrxZIeS1maifn7r4+uMYVtzppYyCmZRf4ZC1Q7JenAviXBn
#M51gb+PGL7OTqgfTuMo/qfyni4ec1Zwxma3b/igLJtYBmLxNrQoVkR2E3UK7c8i41PsRIEZ9IovsU8cbx0dh0ETUXxGtyeVu0H1N
#NJxXvfqtzbe17t6/wWG/J64drpEyu7Ca+Y5Nl+pdLb9r1zXtGu2fd1kNZO857FU0wwkSSeESy3mP36cEA8Q5i88/depnN23fbr1G
#1YseTU2g7hb65EleULH2VWjlWzOitoYqzQrnFmbBrug0C7eW+hXbOUotZvr6c1FdWWfAe5iR14xKdnxNxxN7f/mqsIgjzaADEzk5
#U3R6Y4fz/JupVNdq3SeXF6q0390YbME2O8ta3a+i/HydxzmgFQE2Ajngg+WTdw9J4JB2EMoiYBJuoarmvuGsI9H2e6gQI08kC2QL
#XK13jGR9FZdfq53MvD1pGRzrA/zBlj07hm+SNKSN3zWNDYw1J3Jqa98J77HBv6fFSqtoP9erWy2VnfR3T3hr/7PU9p3TJ8icNhFN
#V1f9SIyB0aLRW15lnWs6qsgczHkz+PQz+yuYaXQ0tH/+6i/zBx6Q/ieI1KhdBK37yq+XbZukm+6MPG5CgyqG2TurHJe5BDipSSan
#zTKT2C2YEjsJdpri4zjfROJarIpKIx3hwPYiAUJ2wAYMogdwfPJgOVtoL9Hvhru+ZlHJD/2ky60JbCx5bTXNO20DiTd+zc1snjfy
#cPDhmChcFKfr7/o0BodgCVr9cUdNaKs7uSntSYEH5BMa3DeFFYE9rQ1q6de63pEFH6s4BQgD3zPHRGVLQGugck8DH2oTwF8wED/8
#F22EdRfT8fItrX34peiBZyuYiQt/7d9V2WbvZWeqhURiukCoa5hNf81BLVd7TpbTMOmH9JP3u6A/imgEyGvGlBEba10GLeFH6/dI
#DsCA17wy5Q+q94rzON4I3jR5w0S9ThiBcUCnXCKB9arwMzEI3igsU+CBr/AkiTxqEwiaSrqzYv/baYI8iLv9of2iX7MpgslDgsh7
#YQjY2hZgrncKg9qi68h/+F1H5OHI75NUIPigM48B4zwnwk1BcYFmH/nk7HNeH23BQNFOYBSDySsQfFCZQfDHyAsIhdUi94r914kX
#lxRC6U9eUQJyFTo0aeMlThkauZQ1fjBGd5MxCHwydtriXoq/6FdouL5DlawMKuQ9gW+d1j4ri9cwl38qVi9OrhsMhL+49UR/Gvje
#MkVchmibDTubokwa3x03nbYrOjUGM2X7L1U9FXuu+Z9PpHeCe1srgGaj9/n+Cj7njjCcEBC4RjIxnGE9Qkl/I7vgYTt8yHEYSL4I
#9Xp5xtMfYFx2YO/1ul6Cn1wA8jSgHJCf69WhOgz8XdK7qs6YDXtCdMkzQ7UJAI0lnVA7Y7T2O56cHAuegL1F1409Qb8+zGmA8tqk
#6NNzt42MJ0GPgg/5oBKd1Dha4I/yYyfj3q/GX4It5B9Bta3xxE5/9UdIAmyqa65vilPa+6Z9bblVvaENTk5EB/nUHceeHXrV9Bau
#iQFoczUpxCU/l6likyK4ypujoy+YJOKsLQoF0EjTAcbbbWK3FOwMacJ6xH1pX8dfj3QfOd9Yb2udgb0Wu4h9jmwXOpsV00VGZyfF
#leIrGweh0cMiHzBPbc7OxidalI1QQEC+PL8+dQvsp/BkwH3A7xeiS8bdD3Mu1fB3+Hj22q19AbwwBPuWxjt7GLsLe1cB0axhkok3
#izQfbqmfQK/GdBwB2a7RRybpFnvpvKTplJtKggLYN5MRWYvQSAo/Kv22v6YwNuZgFkRU3vYD4Tdn6xc5JgCbE/UK3W/PjFjzZjNp
#93kMSNN75XlVkQaCqB/PBvKwTlxtRpyx/DltBgcLZLLvII/iYI+xxNejNAQPJ0chY+Aw51Llvp1g3dlnGrSYE1xY5Ad8DGbY8C0C
#xN7HZWX78JKXfQbmNnDipYd5KVyufrHMaYzWNy+jDOXoM9DH38NuDgbyOEPJU7yPE0/ub0bp10fpwOgz2Vib4/bFMAf5SmSdlG99
#zjDrS6N+lR/ik2xP401pVNgSjSHGWqjkX4d8hyLx9OkTtoIS3YJks8awekeipkd6tc64+4d+tbs469wyEHvWZPHYfyELYZkmzllz
#eBeo50b+OsMUvRyuKoQUjnCqd3h2lVy4Ll7Zv9z75nQbQBxJ0gTm73RHw6vuUfhbCuLXRg590TAl8ujOW/oc0rBHiNbxqW0dPLy6
#iearQsdNTWIgnAWN49rxTbpw/6ADnZqi/0hAEmcRpahUsntQ1HiHE5+Ji3yL89o9heDVqBOEwWcV4wibC3K6vP8Y8ceNYmbpImnM
#zxirZAYi4GVPlYX6BVFCFYofYmBhOGpx4GhNAN95Ek0ZDq93DWD2+IMcCVtTIP8MlIK3B1DE+YbvmO97U6/Z55/G2akXip3kaIuc
#1mRYP3VXrZUGhKGKRBJkIlWslUhUM9BIZbZNKJSrlII9WaVkFUsj8EIvrua72594vgQtaDU7iGoOOi4zVCqXAk/LaS10+eUG4HMl
#FJHmA42IeSvmuWq1iyMUSmcallAqLINmaYpRZQKTY8lBn5M7hDTxOx4rMpergNLmOXh42Uzjs/zEMOOyZLUKFrOaqVK9IzxbeCT4
#CKkPSmzU5k3ZUbuQ7V0CMefcbJc+CuEIgDGyg+q8K9YNSWM1BGWLkld1Yyd3H0d7+6XapsZ+V917z0ZzxO9xuhucuPjfFUPyalyW
#GXfxeBxZ7+j76X17Rvp4Md2NgJsMFOWbf47UK5StwyzEXoy2kasEk8xiDoel48/daTebrVNQ6EikI9CLpZYIdcvseDufr1x1QsOY
#ZNlGhJRll8xDM0qnEmnFa7/oxpkvE2taGwgMP0iMvlC2/xwLEIAZEaEbEMEdEeEfEgAgiSPX888awoeh6Y0xqzTGQsP9cTuCILgp
#Yd+nvXlQGhRwdD6gQiCIo2uQ5SLvO+iznTYxzW/c++sRSdyKTzEGx0mca6Jg9ojjcoSV69u0EnQHGY3ROVFTQU81bRJIzcb4moHc
#C8OZKjlEcGWbHaOVs4+Q1KUrFmDmDCjDD0C7Q8+CtYqUHFWLQx4oGc/Aw+6J20XV7eAg0WTamEQeTcthkhB/QL5AwaOITCWCiIhN
#RNSHV5aG3jEQN5eMSnetHhK7+ezNLdIIX3cp9gZ8dkcbHEec9NHoF9DBnfl1176xqE080+HNoNkbSVdzpfoYDePeskRePfqUC2Vf
#mRIwhJqx+TXqbUTm/jgrbicjH3IxHiJ6WbYdw33833NlfBE/nEfne/+hSROGakuwvxLSTmdRX9r/ryP0/t/N/wn/+T/7tMP6fwcE
#/Z/zn6zMrCz/R/6TmZHl//M//C/J/85/qhsAIP53H7sGAFD7/r/kPwO4sOttcCLc/guAokEEEEBmoyJCQAUmMARcIUIHk/wPEDRc
#5L8gKBR4BABMgBq2TwP4Ohts5t4NQLfUdp5gEzDrORzcFFSFixmBA15+fGdc4v7fX3Ux0+hvwBZ8IUVKCqIEWQHEhwqDzpTEq89z
#kWuus97Fpq0hdWqPQLf7t+OSeYhAGgHkBrQcxtZJu4zvfDMPLy/vhQiWdaMSUeKWR6+H7r45EqHmMg50oQbubvUKBLhiJgjeFTNS
#M8FB31SYxXO2CKEmtf67IC45V2sbVLSuGfGqZKVert/j3cManzN+orcEhZSqwd/OBN2k/9MTh/ndD4nspVQAkRo2taiWCPiuYyPn
#aU5U9ubwyzRmIefPn07in3UCBIkEwT8jkHDOCXI5EHgjNSupGXNUx84a7J3y9e1Nu92KVuoX/tf7rB75eRI0YeYWfNCgb6vGSMKo
#knSbAZzj4r814cAuQAGQtc2OT4l8Iuj8aqCiMATbyqY/2ORigGKk6hu0fEMs64rz62a2FDj6nl1Kvym3SRF7N4JNQ0xK/78aRlut
#X/rxD9n1QCbheFaqpAnV9YR6j9xgTyqC9b7ORWwKKgJQsQ9Dfm4BcDjLC4TnoEUlRX3FqioxvtxmS8mnnFbUdZxRYKEhRpaYHT0t
#Qf/YIQMpJ4HTEHB/JJ/frKo7vn6YcBJgtECeQrPAikHqhVo5w8s8JyU9uV0aT7esW/w2fgC4t6+RPSJUp4JFrpntU/lrMnZiK9ve
#LxpyNEFhphKm17+Wb9WVnjdJ9/0uQqKJNMggNiQamNVuwVCzEHpnLMgu1mv/8lGXPALJCR9ADeTf5dfgGobQ6JpFy/z0rafokG4L
#WOz21VrsRMMWWywRBDAjFiCWrOvNq53XnWuCABoLhnjKByGt312Vqucfu0QgjkxdJ9oWr1Au6ZjXaPmLWQxkWyTXvj9sW192GXYK
#QFjMRkJhIS1aiegCzct5gGJAgUsoJnfRB5y5uv+MbA7NBJyhZjxr1mvi5tUx1bDskOQx9D0EsmThdNx/fT9Utjt+XW7sB1CO9PlW
#B61DVMCVPoXi8mv4nj7ytPd7cAv6tzkMMO/1DNY6npAq/se5ioagNCx4+EWHPvmNEzZLivCl2iGiGFtj8/9WnEckogeMaIWQIAU6
#EWYuLIF2zEcw1pZk3L56u4ev1sdud2gIJSAGwKzBG4iY3jx8Xow1iGt+fCg6uUfN4oZUKZOCUtlaf41lfugpT2Oef1awRhqIJtuB
#5TqO6VFdxUDVAM8I+cN4vbtA1kEMKMuRMyIAQgA2JfeT3HEzAZCUhbXUKGRwjvcDursVIm0o5PlUylGo1sAvywCtVsBcMWBgWVGw
#7FBYNkWGZdkR23ZCbzvBee8BPK9olyNcikETAFDBOPMJGJLWFI7zhYlOwk/En84BiASBP4fAFDF8XRUsuqnp8TAFeNC/i3Yi14F7
#fmgTIkOZB4jQuMEHtE2RPzsOoMtsSAao/felBgrt5VgR5bDgyzTY0LigLLZ0AytviZpTIWB1pX9XzN3u0FveyO0uxmBrDT689xrG
#xQkjFUPBxbD9F7QMmqEwaMHFmAHFgAly5XDPEXlMAtDtB4ZBZpARYL9CfA0AQ9HxQg/8S8sx5Vqcxxk6qn1fm20R40pfdLQk8XUW
#T1swtYzCYRLYVG4sbWsAVStQpiSe2Ccpa2T3kgN5EiwufBK2kZIGOgGO/3hv8tTcV+veethW1IUN3etu8Ve3Xqx2KqldG3IjOZJi
#A3AdpnRbStimVit19KKs4G6HFCWKngcCLivRWG8Ka6kEHKEcT23HcKz0BnS0pkCVIHzolJhvNyPVmx0uMgefu45/R47urOFanHB/
#x2kD6LGGxcP6kt6ezPRmY3QmmzjzlGE+nZ18IbqOxxEmeq/HjwbFvLp7nVlZmsEjGPhXj51e4llpp+W/dIfeidOqCJrsBH37PaGd
#3c/b4gH797AX85B8oZ/kT9Tv8RV/Q+cz9whczkGtIYpqJOMI5/39QPqQbuzvkVq7Zc/Sbr8zprI0/aavzxafVgAXF9LQonpnagjQ
#QTCKUHhrUmHMPc47R57n0LTmfkM++rQtK7QZJ1sVKNExJVy0G0PXjgG/7Txi/mWozOFKOaUeMKA54OLS5bygFrR8E/mcK0ISSkVI
#VMjxl2G4ISb/fd8qxZ3YxctDKAPcCQGIcqUCaphg1CPKA0mSHJWlu3vE8eH7jA3NGPpkrZIX7f1jKpYwQaeNjiiV1cLz6KLBcfQ3
#WWkBrFng/KuY/nBWbRVA9mC0g//+ArZv+DMTtIwHdxJqiIfVAH+FNrBp5XEALQgJ6eZ+8zYMO+zXZxkHHDBMbY3mr0Z2GkegYqnH
#BRYR+MOE4hVReEwWUsUqQJYTACn3mM9/lQaRhgVxSuKVFgr/6XV7/oGrrMNK4/nhWRt+hC7jI6E3cBsGo54fyQp6IV8qO7J6e7+j
#kvmOlOfzbjuFBxtNeJfqTL/K3cGYVswx1LfnMohdZvB1/30YiOaWmRX3S76uEkLb/5MXmb7/hq7re3pp2/v5lm5gRdKiVVwm0bRs
#a4mtcO2KtI0qUhxyzDSWL0pIlEm+UMmaSzlpRFago6OIQE8gQh0hD9PIVeIxnayfTDF+XolTSRHjkc2UbLEYsFiRqpTFjnC7SeZy
#MQCFHcU0othkGKKAYUeyTVZUGcWMYx0AgYHk/zCxGQgkLKxvZnr9vDrJcR/t/e38eN0acN+L+f6WVpkBe9TIKKkJrdh0xH4t0k3G
#W0xFlJHB8itKfGzRiffWdN0B/ORSH86BwBbrocl1hup+po9RFi6xskbNW1k/mjbvKFBnAy2KwVSOE1HqnWSUCo8Z2sz4gHGVtaBW
#4dbjELcRCiiJU/nSPoZOe6lCyGBZckzJ0T7YaTE2Lip+ULzuDzjLjcxA6PL4d+KXdqF2uI4wev8gnUaonGrToWyyt5NMqU6Yn7aL
#23xHtWK1XKlcVxC3zKS+vEA5hmcXnEDGcXBnIBD8UuaRI9kaPw6bSAR6DJUAFahCYPECgdUTqGJP+aUWGJtSrk56u1jwS5IoXxyv
#Q8jELcGXjifPfcrREpdQyE56tSu0HxjK5fIvRUIdOcSkO1SfrRJFoeeJELR4mD5QpBAKq8QNuNOtECrR4DkesY4GauRw3qHAnyUj
#Vot3/aOYwdMEgxQdSIb0Ymcvi/4u7HUgeyxsLw8vT3H3gqm0pqK7RSXrzPvcKMUwTnjdIoO49cL5Z+Y7Xdy47j3DQjVE4t8bG3r5
#jzbm6dyDG79VLACRqU28Fr3yJAB2xmz26FyoiC8KrPKMkvZHlspthVnMAgXeZzx78XcPW956AyKTf8vkMJD3I8Dle+0u68/mg4pf
#bWWeJPiXJme1qAGnHnQ9h6Q3pGsDhB/VYqw93jJ5p9+eo+R4z3dKN/Avj5Gyurg0GY1tWO+mpU5SpJo804XTABPG2orUW0wqq+yr
#zdvPD7FLYvAQhduwQ/fUKrUe+TNCZfwm3ioPPBvmCtYYFnkfasdZZPTJKiS7bvuow95Ml72TRW8GMdpV4f21AbUh5WOY9Xm4phyC
#KUvJuoI1An2GYqxRffiKhIPF3qVIexoHVTlhQSgWElELi7KwkJCsIAcE2qyAY4TeyTgKj6UEH39xJs4xBQq3nSlWw3zOVnhRLI0r
#UjKRbLxDTVG4ERVlaa5QgwAr7BT2hCQTMwVpnqPChAIjUTpBUFAaiSKJnfn5uZo+lERCKcp0R0N6IDlhc31omeF4Ivbc2SlhuQlh
#cjVBIvFDg5KMI2rB2xtIFh8ixK/YgP0qTt5YhkTBU12lfWfsJ43PhUG1t3vx/Fvvc16Fy7YcxSVrKPnBPWQ4FWLbHF1ZCfogmVAx
#xYLRiLTB2X7yYJsbT6fuPEORHNIenNQ4zYG/FYTxiBO9oE8E2iT4NfA19DX4NTwOAA4EDghOo5CvCGBnAYLof4HZqUfMmY1KQVgr
#xTBPlvwFre1GvwWjFPm5jvwG9JeIIMBwaeH+MQ59Oo+kRVIoC+8NzbjbI4wAcDScdwQBDerLvsirvcR0F2zo+gFAdEkJtlx16w3o
#KyIkTbJbGqFwEZRCxCiOKPTkHVzp5aoPsQ9BLqb4CBoT4rLMNuEPCgF2lEKIEQrBipSPOPq92F6vBfgqoJVyQdpLBXvY/IVMgaYW
#mQXP41bUzTVMHNTtPsBBAZjB/cv4HwwtuCwGni0IhkacltFB06OKnHpc8db9ctyh2Kd1+rfLYbifmUsDu4BE5TKcnT8xfQN/SBwQ
#gtJlK7R0Noa01JZqY+kST5MF5Sz6Qlr3AYFOLnt+QzRQJTUId1cbaKiBgh0mfVLJqdXFfr7CBEiHX/2tPvtju2HhOIRkS0IFPCw2
#RqgOipQJmuthMSuLpSntdMNWiT0Sp1qW61AaC1jwcPQerur39Udk7gvCl1xlh3EdSiDceA/itpO/Kaldj+NQabn2Y2t8Lpu6GzYt
#24oPM6xa3aLe+EkUZVnmHRjmGaYtHOeaxgmzrZv6JUD8r0Xi4WZQa3CFpgAnwCskNNsRLW70m8LWAASuevRzgH2IaPGilbCVXC45
#IOHWU/fW4abMNqNXOwUxC3l9g9ZCVIX4fdawJ79q6N/prtvRrT+YPATNz0MqfcNv6YvK07m9WzSilLo39A996aFIvXp5npHERShE
#QkH13mIP5IMLNLYHpJKAdPP3XDs0Ojn0inuPzPBIyfXOGVpQORFEJSYo1CHSj1vIYP/AgLjWJHS+cZDDpKWow/hgsIc8xPTEhQiT
#s4O/3U3+YD1C4PNC8K+FqLmfvR07oudt/87KriZMXkb7+hZ43mHe7VHxDl+Cmm4zzz+IzuFarx6xc55xu85cMxrg4HSiRhMJCUTJ
#JPCIzeaUePSwowGon+0xdi74FVzNPE7yRTJWZcOOjECigtcJEYwISTL93Sko6prGTSzrmqZdMGzm2LKNd5WX+1fa1s3VCft10zfm
#8avFNDygGvhDZYr+U8WOJnoxUm5sYEybngiOAQMiLwchyab5ddsARvIrUnFioFFtzQpHFUDc0Ukl4Yu8AYV+D5I37DSk+jzwuj/I
#oFNNuOgAJEn/QJR4XIh6HqCaekQJg0r1YFk34iT4Y0j+gQj9UPaK8mBrTZtBFOclDtrJBBgoDBBXpNXnmfI2WQMDKBTBrH1NV2Kl
#71TaLr5sAUPR4zR0X1JFjb23JeCcpg9cAFdzVUDxxaAznFsW/wcMN/bc9ISk3s6qhLkBMHzLvWdHhmv8TtRd6PHDLohq9VKAs5rg
#wIDaiE1rO59dMgNLuInRSxFWyqoo1yK+6jhsqQWUPCj9OGoZVDMIyQKVcmStEL2D8vvgPJINk8WhaRNJ6jKUqzn6mggqIdbIrDHE
#x5CLH8sQNNPJy+N3XAJAabjUqfg/+ICRv78WjPs1/SjvN9c6tpmdY9wf098pFAH/Hf+kbaB/FFvXQreO0E7qeCs9H/Ou+u1X4n2X
#Gvpfo2d4nJfBxL08Mcn0PE/fm9/I9TrscwRljLiwneZRCGoFg+vD+kp0t8wDcoklEk89dd/7McwjAXf/es3RKWjuEIll524eDI6H
#9Mg/+eN8rvDZe9ymxO267mLBf1+8SgftR3VeJyX7yPF+n3N6XkX7tfs8+CC8ZNxGCMFxXyHhgsT9R8hJCkrzi43MDEyIkOm0giUa
#CnkQh4qiRHRLpObpkvQ7bTAbj8fVKyUakO6qnmPdXZf0c6xYsZY9K3cNgGFYxiFmxCKXzv3geUQyHBZIzXPcBzi5nVvsX3Wt70jj
#7cyMPqGp9qY7BHBXceMUe6N/ipB2bjvdw5TrNGXcVlrs7lIKy4St49E6uqvyuD4WR4wi/xjxfPQDVqDHvaqqd38ep9Gi9QZhLh4y
#skemPPsXuFITGlLbEUqetRA8AqskBMjnqJwQqFuJ4GViPw5qBl0rEAnbp2G76L5WEnHeYgUUJxqwyVFq47RqB1MGFnj56iceangu
#cfD7M7Y5HGvQWKWJCXe/KlrNjlGCGGLdsZ5JagIrFPjUgiDfn9BCnqtiClVex3zU3nYT2Xc+bnSPZD2RevtWXdy2tpFm7fRRMGOG
#IYvyEUiz6llSce6d0cwk8ojBZXlhYMCNWCCFAEWJyj1XCc1ROMn4PA9XpNoazQIN5JvnDkOQRvsPoqQsNLNYI6QOK2P97QLJRixH
#oObBQaOS7NpHaeWHLjXKihtWs2ZRq3zTIHiSrMHBqa7bLD8DYkCoP3AMTc3L8LgTsv/oceemOuUJbb/qTQ9jPRWrCLqeTNLvKchq
#1BrA2DRa9w9hX1qwL0GCz4g6hqKPvyTrW7l3wAxcW6cfQhC05HCPG6ub5c5pd7WQbY0B5Pd6WjFBaP3EMgqbSRwx4ZXrCTonqBdK
#9NoMRcUSY+nHedII7MWayqz4EtMxLpgEFWGYXqs3GpaBbTtOahCr6myzl8VOqcx/N/iUFAcqALfZ1EEmZIRy4BIk+JxIbecTQC5z
#StsRhKwfobhhJPrSyAvkBoPUGzrPmu6XlsqSY51UFIcuW/V3ejCZX1FacrmYlm97S92WJCKNx1rsMWd17OwjmCL+qy2MS/jBKMnv
#uGBejqPgpv5FmGBh2D/OvBVPsYWDhzwxDChPQZqCZc6XjAsetpUm2mBlVzBxmOKVV8X9TO5SlJqMFIXq5LNAkpj8Z78JWNWu2A4E
#XHjhJzBO1ribef93chihxpJgmMzrAgrEGxDU2z8kgNCPRMWAUulAutyPdsmAhDVGFh9ePW6lt/MUmHls/C4h/pFsFbfxuOXVSm7x
#4cXLSbH+mls0RVvW/trxMe06egiJqg8ESZqogVQh6gnHAgoT9RDQE117351lFNM9yhNVJJ3Owt+Sc++pCYhB1Js7zJlxIQ2ORQZR
#b2ZNPxXjDMd2aJVGvXD+1XZZnfJZYWLBBczH6cAiHnC6fiWX0C4r2rUW8g8IgMMnqSNbdOhkTRqQBaMzgWDyuav8EOwlp/QwlVTK
#KN4nyX1cR8I31NMd0v49mq5sTriGCdHXpPRg4nLTlmR0Zs3wGy944hYdubr4eaYJY9umIbu0A0h20+4H57D8REwTN7hd5/4tadrE
#7SgOtOM2nS6pFn5Ztsc8U+SRA5kJooJqrA6xlN8tT0vMIB2COjpJGllrR0Is/RPqkazIgJJ6gmA2Y8nWyQHeOXPZbQXABmJxxCC4
#nIQa7SpwmS7EJNqAa49S2TpXTrbv3lXCBSaMCpK0OCNrw/moHnIJzH+SMeNAG+IGFbqd5Z2m754Vq4GsmdEgj1RhtJJMjYZ/pt4C
#jdaT1DL01Pf9ViQp/zrmflC5/q5AgxxjOHYg+fJU95O2qQgvZvUf5svi8tuv9V16TUcck9Spd4e0w11kk/z+QJKzcYWu8WajRCvi
#qg7d4EaAZqmZlACRUnc6/H1+xBuJVcZS0hdMh+YTbud4x08wBhpzZ+jTRhQ7k7nNBoxmCzperKE+mLgfndRbfApWzuNHYDdDzIF9
#G8bFZoxj/jrs6ck5tQkC2yisZV3NZ22Jiz0cWBN9OaOEHuRmZtv49UAF2doDHC0fCNwG4uy8qByoIIuwLg0ETqRHKJ0jFUQi5mbG
#JC66g4FI5jlTWQCB9PLJLCLEo4g6ByyIaGFNoh1OdorxCVVZYH5mQS0aCJwwr/AaByrIDIzqFB/OsJtO+6wlwTmSKrxoMN8CrBzw
#QPz5rOKtpmRU8ejwijmQuGmggfXlT7eQhQ1bgn9nRxh0nLYdSp5LNRVfNTWfrYLvsNv7uRte29v6QdbNWMPhWMXhWMfhmClGR9XY
#Do9b2MaFh8riQ3XxkarkmBdGR9yYD+/bt8Psa7XXOjPdDSZskZP8FFJJRGXVzhzxzI285oNj0+0mOS+84Do+HfT4o/8mgAln/Ss6
#CNt7cL8DbrloPG0fYXKxrv2KurofqtCxzLq+CPKKY1G8+dLuctahlAmUqa+bsCdy0vYnb6UaBjSnhS0RWhzGU9OVC0FypWl4RBTS
#2ZZ7WkhFBVVFiMoINpkBmJWZqripMzStyi+i5nQCUYOFdJSI6q3wSoeQn1O0L+xIQLvVRSIL59hUEGALukqzEaujyj+iSG3NJJqJ
#RPHFVvZr2bJWZElTbSeuKXWi1QRqyzkjHxotSryo0pBDM5mxzl6btrTOa4vaS7dsorzYH+Je4t5eXkY119wDBSRXM1rNW7lb1VgN
#fDFP8tV3eYn0yQyX8obdpWwctC6NGMtOyaRVhTzEXPE5+R2Rjj39Ws8eOl0qLtMNAMcO87LXK/tb/UmV7Mi4yjXlsR2NBFHR7ucY
#J6/nwJRykUimRM+I0Ur3JprWk16Kz0LyWJE21GUjGODwQpBAUMCxqrAxwlEEUX8By8Q3qNRRMAJFRob7NARPCEMMsCZwhVgwEqeY
#wOmEfDo3TUtJp4R0YzGHJRRecvx95r+qCMgQqEISRrKYJAQEbcbtsZwHaMlB6OJ1dy4yQwBEGMtfGk2WfmoXbzwjuAgnaDJlF7Us
#smfMXEQc3FvCtIUAYbAi8HJczPuiVdflkq3ouCQKAHd6Aqqk6SoURMZ9FemxykEVdY8mhScrlIiFDeTWSH4ma4pvt3lK4yGAWIxn
#QH4gNBiYyfQ3e0BnIAkqmJWdivx7hkTs8vqiSsllXWxY7UNCkxp9CgnJwtSmXabPoU0UI5OTTD6wZ5vgDt2BWfNhl4A5Byc1ACWa
#Pcrro9YKJ1X0n1UCHMw6aAm7lSpC34XRQJx045b8wf1rhGdToBcQZvlEmHSMEfQ2bCN88iL/r2JjJHYHOXjJicDIWMhyP5V6s5Lx
#VewCNrdfZiPwouNilGbBpbehwK1COYlsyUrWiSShGIrqSfN4w+GBu4/MbtX5RlhrrbZIy9QbDgDvcYfTSkd4ZWIica2F7yVOTzm8
#5QDUFXiRo+t22iocho1/rOx2t9jSuJ7qxf2NzP4Lx4LAFoqM/k5IQCwQFOrPjEXfH0mFaRZYB0bZuru07f2K7JzQZ6qBUCyWqYJ4
#uoU0qQPRD+ZEU9RsW/mIiWN1gba4+0g9uARddSZSmp7yR9w6KDTs55rDkiA+xhK3KeqIojY4uEkmcTXJi4RlPv6iRZlg3Cz+5PWK
#lOsOS6/8Ko1sgNe8kjFpOZE4KO36/GWqkhHiLiooT9i+hT2UIvg62yVlbXroCvFrUTeJ3SZItjY1eftrhJ6lz3FuwNujfMQW6QF6
#4SNFpkoFvME+4RYD3K4ELJvIMexy3BlEv2zxn67PAgxvMnG0N7Ryxhh9hUg/WaKDT+I8gLQN5DP9xH0yrntqkWwQcIVlzGIHYEU9
#eQB05BU3Rbtjq79nlF6pEJ/lkrn+ynBYeCOrrUQYtdFKiKyj0ZuA7/0zMQz54FNEryz3vuhtKA/QPAWEmx8UXHLURD1eTlD4Ojf+
#IAhjqpWI5f11+EeuGD7lYmhFXoB1QiqDyCrD9TJhcFdCz1LG1BIYcU3R/xkwJzS2tUPEAlaumPq7sEVEqhgXD4lE4sQUJmrKcc/S
#PlS43cI4YvvP/VdWePmT20A64MmlPtvxIm6Sz+S8M/j/QMitt+6G2kt4LfD3jsm5ylQTXWmN35aUHlSOVahFqUIwew9yFT9kiHaw
#18zM/r2lZyT/54XrXbnL4dogLbr1fJPPIqk9yMZLSmSl5jq+GN/GIGiMgwrA7nVzt/A9beoNBReJg1ef8bAyHehbpAVv8a/VYnwF
#8807g67JzEB7dT1tGq/fMQ3+5BPTp6cDLVj31I52OZ+pVrW5Z1A/Jys+xPAQH5HX++SBv+/HFnGyvWbR6rYgg+RLfz6c3ZOSJRUk
#1ep8jO6FH1YChiIh/OURlr46nVZVFYIhasPUsfGxrtaQMTVJ7D0Ygeen3jUz59AY5FrtaUGLgvHCc5ajvqyIIp1wUVIL8jXSuwwj
#Xgl4h+qpGG0Q4ulEQloZQfk5gAwEBulfy8u7ioj1pZdHr2J1La/HIPAUpE+mEJ19QzuWiaLZ8/zVCYtXxfLW/CWjPzIGCa98xNbN
#pdj4nZLrqoLgAaojlUeHKj4gCH3o3+dffMNiqb8EHnaio76jtYeLiRydafYrMg4Hs8muTaqec3EUYzAovuasTTNmomkPyrwUVXSN
#4pwLBvb5+NR0B+9fyRG8G5qtnXF1gXO1b+6qbioHbFzUkT26wCQyeCIU1k9fqdRiZoS4FG0fJCpQNJuYZqd5s0GR4sHOu636gJxH
#+Gg3t+jaAPQfc2Sc70ChPaiTbpsY1+pfD797Nm99LVtOo2RMEC+phIibijp4kLuEcRQEG13pv+HqNDiaJxw+z1iEbjh4mwjelO60
#hMmti+UHLJEoGuO+EdNtQkAmmgwiLKFJU1YDGwRBEnQtNzPxx9Tg79VcKOlEwpmqxVUVes/Q+KLt322QmHLYvMmRXiUnFRuK3yTZ
#mOm7wTgMhyhUSeopqUibTR3rmhK+smZr1r3ze1cFFxzVn1zZa4Selc5I3Bv2C+1Km1EQgomwxDqFivgtojGYHSO3iAr/Wz39LJR5
#Y2c5D2CDbzeVSLm6s9XMnRfwnTR0NTZPFzGP/toFEnl4c8wWjG4WZy2sC6wI0o50a/UlqmptrRMMjp03JiKz1ORoMx42P0JotEI2
#uPr1pzhLcNjjlhgjYOaLiFdZkFUvpkhop8Fq8XtTRrFapiIJh23ukyzjWTzYwYmW8AM7RkgCsE2UIOp66IILhtcjD2b3VgkrhZdk
#9xI5EuV2s6AHGgM0Niif2bPkQCTldB5NFPQKQ1tHWJrfUK09jy8i2Uxr3ZJsU3LzCoEk4O1mzF5gpEQRj0ZiI6IqABYgS/RCqIYR
#5Ne/1L2WutALuajOInCbNFW8wXQP7KJ0lST2+ccIpFkbShpb+u09jK4vLEFhqvczXBEIhtGAhY74sL75ekICITJEQCxnTk6ECkzM
#SNo3tavbPJgUQQsNSa3WpP+sYi0/liGw7G8a91MeTyW0b25yvSwJnYFUCkip2SOE6GoMzlCmhpGOVygJrTPEzCVyinSiiaw1Gjuj
#DhNqT8cjcOBn7hLudvT3SKIQ1ndEnyqdv+iBIWOKiRP0iDH5mbfi6i84kk01YUQhU2y4IJPaibkpe8N0gZjGi89urXO2HYGERyRP
#rqtR0Rprg78lk02nbvhpU0meJ+8SmwqFzY84xiyB7JzKC5kieilrbejfxnxoF0zQXEmLjNziWFtLgaUN6mepylxXPel+IFpQqR4+
#6ElQi2rIxV32d+svuCQVRUs1E+++ft/OA+aEesDk1xIXhgEECkYzyZ3ta3OjLlub0j0tONxnTbDHtms0e6GMRI/z0YxcbEvMUVNz
#e2q3mGuytULlo1T/Vp2PN/wsKEY+0JS4zFPF0c01GkXev+zDTM3opYZsk2Ul+a95WcYrA1Lw7aElZNIinXHAiLGdCG5fD4rOD/Pz
#40RtPpTzKKc1MTUdvkcZGdUvzFs/RWuUTyrTydXV4FHYhDBR8bv/tOnLg93Fc9BWhPAIISIhot3VQhtpcg1VG7FN5+UEWOyJfNly
#7c9I5+k5mUidl8X1hNsXHPUYipqjbqhu1ptywcKZzuP1ejQ7oOMiOT6XFjcblhlroMnjGJiKj89MyXtsiChsfsj00eWOO+qxEPFA
#j1GufdGSSW9aG8nOvcUt6hEf1VhblFLtMkc494b8mCdnxGdWplivA/ruXyV0OFbHGujCNIG0ejNut4bFihjoTg5ozhEcQdKhS5tN
#BR25cbwGlrDl0rSbeh8vS7nsgPGTLgyEnMOEo+hM+SHuwfAcGOcLlTaSrE3CVbhU0DcWYBH3GMZeqHG5t6erUf5l8nCCCNyBSarg
#MdNxqBIY3ybvKfYrGE5bM2p4SapSrMvdsqdoWvPwD7OJN83owPPASFtKM76WRn/UqruoXgsFSUZUjJUrrHUrxEWEHmwSXTDETG5x
#Jk9xM4qxb/haW/me1cevnoE0h+Ux2GQWEh5gLEzgEGASFFGwOnUUzuhUFtipXy5RZVrdfs32ZgwSscLnlKczRWCChh6PbFpX1D9m
#mqeAzf40Pgv1ftkYiBT9UDxrBa10Ssq6+cR3Lx6v4FJrNY6BjnB2kQmPKwnTm3MJY90hGdcRmVM0WxMPJSQGhQHweiVFsdFJ11Hu
#ZFs+NLIJvXv+AnqqDry9yX5cgGzwmKyeKzyUCLtdnmeJzHmC8XtoZMJv0OFzx1cHwV5ehPoT058lrEMIguV5vI3Jk1p+pGzb7XW5
#XgMsML6CpcWyg/r4W2B0uKcIsMC/aUOYMNG/Hq7R3GGJ4lrskflNO9je7OKBTkJ4/7eCK57g2donAO/hfyQ+IL6SwPdMo2yyaYcl
#LsRrriJS14HzFXtzo3DA/s8LFtVFPrX4WuDaV3ph9xDBa1lf2FZe1E07tW/Lpm53iPdoAD6fxFpDjD57greUSRNiF2GA71D+iENT
#02Q1vXT66vxc88ssNX1oZWMC6WCGgb8FevKcL7Ep0XY8wW1+6Aw3n5tiMUseZ+Cf8ArVNWXZmod8pZmZzM+6ZF6fSNlAtJeyMIrE
#MRP/3LAuoUZT3lCs3CHl68E36FfgXdQzqjLFVf+UqlGiCayYRxCyaJPNQPzft4+QgXVXTi9tv2Dphc5BBGAM4YKNACQg9K+9Jkwc
#B5buABTkAE+wv6H6GQpbFaK/3zoJLiwdlbJRJNPH4lhszN2kmt3RRRLeeXjqJhLE801ui6uPpi2BW043rcWKmhRr6lqLAzLLLP1Y
#znOSd2vLKIJ+iXV78DsHANXNbyzwLuzZ6jLjwRBlYxPgT5bA0lw4kBL4k+WIR6qzT6YLdivvfTkKfUSVuTb7Kp9+my8rL1c+nEbd
#wxCVi/Q1YD0wifO7EqMN7enELVngwxEXkWdJGroSRb+W8VJvl1oAirs+BjEz6OUYZv7t91la2Yyy8jMnXOT9A1Ve+mWRUprVf6IE
#qv5V6a0T70swEvp8QsfFgu2Adh+Ud+Wf6dcfyHoOFStbXpCQSSzM3IALW4aceYExpYvjXLt+xIRtCcZMmrIev3m67pvFNhVk65iC
#tEdatbS4cwplvcDCE0fMCb8rLi7NLlBblvlyPgljwboSg8+KwYBZNv+L3+5VxBd/VzB3+TcN9r1HNy5X4ZGZJ9c7HtpLBiQz7IR6
#MeWa6dk1uishU9s7PoJkiJnfOXtmCpc2YOLQ7tqJVRWj2xm23RCFC9yyguvTcAJg8oof++vcTe2kTVk0cak0B7SPDWBWYU3KWNM4
#aqasmlYl+wSggeqswcmTVuxWR+pWBQ7R6w0B7Hm24tlTu5Cgq7KKHq4etKlhaaWmhCS6EZvxZTl/Bt9rMu1u3fJhV9R7IsaZZbrU
#yKhFD8DEm9WjvburfzNhT4O4aEZtyaH4Lo3eDu3/vOTas1uvwMptnrhRvJyWsUQAI5he7bhF0yn8DxOftsqLtlwxJObkJ6ZlViyl
#d3AwiAHGMPE0QHKpepqDa/Mq5ZO1A1B3RMEr6eEHUkKwHd0f60dL1t9WgPQ1ahfa/PmT7DLqttp+Jlndvhz3qe1mgZ4iyKSRUnFy
#x/397HTkzYZyGP2JAUZ7+ghZ1AWfwy9dPjmC7tEdt5Qxwij8zTvWUGPpzLsQ4DCHZLFWHHeBNsyvkV/mntu3eu+RGC6IKSLBqzB+
#prbNfzHdA5Iwxw8f9Hz7S6kw2O49mAiGGzHEyDCXwc/24ApCB5qAfMyCQzFwyqx0QYp50cSDcmeOlzUUJgV2UNMD7ZmJlCTWSMMK
#bsBbE7FRa9FJFW5eC53O+XWiDQC5UY/abeUzSspr8moSUGKuoxrhBvKoHsTfSctHmyTxmaZEUQFAhHUMNfHpsAQ6o0VFUVJbUZcV
#4HC7zXkiT7giauhZ1sPWq1wAN7miUUKcQhvThnZkZ6QFQQ6UAFgyM094NyOe/sMI8q/KM05ePx03rlGhmG/LTRt2Fjheas1cggTT
#k8zvbo2fKhpApCVOctydhDy3RTn2YViBYz/6XBGWbHIhb8TdggUNTY/Ko/qwQuB8F8garOXLjMIj4KqVq2M3IWg61ej86mlTq6Cs
#hQTJKu6WATFLyCU6QUaaWiZF6sgbFEx72l2fStoVaXgUwV85GHoriii1cGd4ZoYGyk/50FeNl9X8QDwj+0L6nkiLc+Und4BK/tDO
#VnCA+WBwxdNqZ+HfCzpchKWC8DIiXL3QEZxV0n6DKRP0QOHCLdEfbdjejoDpOtgteCB7u15ZylEtf4X71hWEurQiybYOxA5jXFk3
#NRaW8YEl/p47ec8DsziKtBqzSQ/LKMSIW4JfpCQWcByTkQ61lxjF7wl73qhNR7GgT860aAt3i1YDuy5Nx93KZYzWnU8Ex471Scit
#XjL967B9KvWl7u7g6LmKvEbFmqijvvW/4uqeXDzEFaFxMALd65k0aq7DbihCAHSA/YZuTKWjGz2dIaB8JCHs4BSAa0e2HnAAH/Bz
#clJu5qBfGXD7sHeWKaRe/LE8vDY/mc0mxEI7z47OXDRXVEcGROv5u8pIhN1RC03kWzp6F9C1JhENLc9WzcovfaLYN5X0F8A6AaJ/
#+di1Rajq6Cnn3k14J2mPNqGLOaQzdkvB16UOeqoiaXTzpWXuHRe5LK4gu0VCKtrl1rKlyWLRBU9iwxpcLoMcL5aqRJ+2Mg5QxKSL
#DjHfK1vCGR+V+G9AMkF2fadDU5hiP81jnOeRALDkkY6a1LySOJbH+QcdMoZd7r5qhRFoFXR0oQ6p2q66ZF9CF7Y+l9xKvnUP5FTA
#yA1oqMe/oaYRU99E/0Lwh72MTovCedj5m2utRotuRtPci0nwwuze4XKlHEJbjIPw8P2G5TVc78be2XotW4dPoeEZtaMg9+qHOuLv
#W1NRxK5mkHI5+fZwBteUdCjoZqJEXT4VaOSpEF8tbz42u47t2sNR1YXbKuxXDZKyDWvkpM++R8zQV2G4vXcUzFSYTQjSgqtDz29Q
#ZIJrPnOrZuVEjddsXqNZaOs/xQc+c1e0oeujHkmPpI+nscra5PBRomIGLh2cIZ9V0IKnIOWlJdtHFQQSPwMvx01QwlEFBzu9Y/n1
#Hy6nvcM2EcgRx7xmdhro5Wgi1vAN/u5kZcD2JQFMdj0sD0x+771fpKElZGS7knTv1AjJjP4NzjoQMKr86lDcP+8iKppdjJYFFWR1
#VcBcBX4+FC4+Iixp6x3Cqf4JfUvifF59BZaOmhjKaxLe1vJeOVT2OCI9wHONBp+JN5DMWsfsrr3u/dLFjBLRNJoGjrEpxjqqUeA4
#iMCWgxEjmrfvg20ZOzv1sAcGfAG3wlgJC+Nh2R2MhUX86NcfRWq7qORSRAr8PIs1RQqDWl/QGnIHMwAQEs+QpPhm5Hp3V9yKS703
#TC4h0FLZUTkZInwSggTymyRWXUhuZV4hVUz/qeSeWmQsAPZZW97U1V7eVi9LAWuldbGWjS7Mr61Q+Xpu/xLlbJi2XZRPKUHMIEih
#+FW+cP7rYDuy1hRO2sepBvPPiTFxvBVOyvr29VEA9ycLVFxiYICFMsBSoWetBHpzrgckM4oY3K0slBhSeDfwVFVH3YBJmfISaj3A
#Cx1yCl9zy8fQWhogn0T4HDD4YWfqJrKF9ttlZyFDJHwPYcUIRV25h6xDoamARVm7LAihue2uc8RQDRpJEGBp3KinGaHQeyPO6rkl
#hxslkMr4DfWBmI9+z2AMJXxADs0QsvDgh5onCKKe7mVc+kERWIlivxX0n+E34qAJ8PhByAxfgX2IIAr2ZVgfOfBs2vlliSQccwR8
#PvqU34EA98IWog+mgwBu/53CdkDnWUMtr5WXnO07OENfGIfPTcUD2ceShD0bTWyUyMc6ESoPje86N04BiM2ZqxVKstJHkfHbvalD
#vMcSj1ZpxvitbS8ofRHzNZ9JyTnxPpYQ2CqTA6Q8L51DMrREvwDc786zW8fXFtL9J4oMZH4qbLSge6Ldx4sUyxedbTH80cv2k0lO
#fXjq2+ROdMcLWdKlcd8IB6D3mRVYPLfyKPr1+uhDVzJ63WjJ/yHQhemYHt6inPbWM3C+xnGEr59HBixAfSl50pfGVIT9C1SAw7Y7
#cgPc0zdnP53acfZTu+LNWCeYoMvzBy07ApykSpMAjk/yhJce04gSRBPb9o2gAvIOv4BiRb+wpn1VW/DT8tPDentilVLC3Wx4A5di
#Zdv5pKV6S4w8Xbh/SxKcECGLaQW2F93mZrn0lroY8fCCmAtLOLJMz4VhEfWsIGUcK8TFCj1IEcxpYShvXEFaqpKKWRkV+lg+22B9
#+gOUJ4wRrlkeeDquUsmnOmKH/FJ0FyV6xkarhFmXvZmT4W/NkH9F5vgYYa5pcy3uOg9xu77JPBldxY+8yq45/6Q5Li+1KMfUP8HI
#2DEWO9ULPL3dBGpqPAagIQ9+xU+EtJRhEuZLs7CyDw+CBYW0veKIISdCmDCB65NG0odXEz8FFrpHIsp/fYwYglAbyGDWL/sND3Bs
#26ndpmJBzfh3wDvVcAFHqtTS61+1mTDZRPx6OFuq4ahtbJg4GSfQHUiYIP2EZkCklkfdt05JrUeufqPhJ0ex2WYYw9Xl/g4muath
#haeiUyckeY0GwClP2zdrJsgBUwB+X7syHp44iRw+o7ilUNC2QQU7AoumHHvUuUWLVsOS1dlpTFXUIaPJPGagQ4vUxbqW89y3OIKP
#k5mTyXZ2T+t4uqS9CrXoZsfZQqzu6z12IWN+riG3K57CZh1i6FXK2lfc1NBdvHJem81PsmFC+Jynfnj8c8NyJ3t+8qr+12E/VNt9
#vUu6JrnQJZ01nh2jg36yLvl8GrfcvrLSI2GW+K/kyWCPp6TxbumN0nkBsjsd5AqPuSIjGB2f80CWtzvC8fAbG862PAP3xpnqp4Nz
#lD/whr5JhUKVmxZzui79IfwfD+Xe/fJfTK9APSuK/EvZkSvoQIlfxAS7u73SBv2MK1kwYwW8nZ/YNy7XAPq6w+fKkkLdResLKUno
#sIhTMAp013BRTUGNLhnLJqzjbapDeT5l+nlt5JgAJoQ2kc1SL1JUxlKnaWOvWSaHNK96rH29WDU5i8ed4j/4CB3VXnWftCMYzqUj
#XtkDh3rO9H1foQT9/1wIKW6R2y4WOnEiVZXjmtFgmilmzVomfSBVRu3S9LZ76ob3uQO9Do/6E3tJNPvOfzGHN8+sG+u4jqT/qoqa
#HwdPqxNGrYp29IwtGrSv1bbK1b6qzGIWr8+nNWoXNErT/y3Y6VUc9pvrmeU8ape+/wbQ/kHh/LsskzkQl7dHLsbnZurl1e40/6oS
#Mr9xdvrAZr4JRB6DOYvV8JlfzjbJGORnohVJWZqwXd1e8K1Fl7inWbze/l6R8Mpt9j3GvmrTSsxgNn+XbiiKvXDLIp+2S5u4dswi
#yzSdFveV7Mv8lda6LKt4KKuAmvPVAT4Qg3jaffD7kGYIRNgnjq1moTC+DCiTebFSu6T23qWmpIFIQXhk0kXLOegV9LsMoHSQlNGH
#L8AY7NI6zNf4Hg7IiNyWps6eQDgVGpd6tDsIv5WZG8f6pwuiLW6sSiKn1hxxQU0wHXjvClEi41NOJs17qreT5AsySWACOG8Svzrc
#X4sbkb6dym/annl7trotvKGBCoDIFV49wsTLo3jy8/dQw/E2nHpM4sMOgnxsiX9kcmMrJW1NhSWVrAPDoIrgC3kw1XrriQww5PKW
#Puy2FIOvOp7rVSOa2fSpUGUB9DOW31EWiLVb4u+XOOXFWvKf1ltNOpgfb621FArrLWLDOJmYduYAyzjqDfMJlbiFIuIFMNyXMQGB
#qATBF6IA517s0jS48voGfqKJ27z0seuVjziN19FVzOpyWjeJpMP+CyKP/+YxXOd3PCNju3jB9ugJqxSBU/t4e2zbUsS78Qwg7Cu9
#9YctK8SrzaFDfNgbjZv0CijMWaRMmOJA9OaDdE/dnS8PCcXsL+YvvszjtQWtwmirIPAEvPDCO82aMotVCBZiMapipFrv0ObRu8jj
#D5Ffeeh8ojcuO1X43IiR4BOEnEcZ5VP+PThxzo76GqXYXlJ6K5EunbL+tiaftC8MWa8TnmJ3qEBp4Y11mJwZpU28Zhw9z6BdM93r
#8XKoQ/qbtHn04SwDb/qp17ZO0Ha3skAojQbehDr6X4W+xZos3d1tOYW9LeUUL67H3y635ULtiH5KG0PeB/WDl9jHZe8swO5D+l7d
#ymdPy35ScSmml9qAr0zyuoVUMeOw0PPtgR0baeAwrYUHjuLLs5hzIQS2vwLUQf/3DdY0XadgcF4IgBDwhb7iwSb8j0u/JqhFKiak
#9l+4B7cjUbR/kuAjmwA2sfOWeOMg1OoAabNof2Kh3novjrYQ+LbqaDUmzwi3uImFXAeeHKYRA6XUuEaU2zpuWd1KGZQ2n1b9uKc4
#Lts+qAuxulrxl8Etzo5X451S0tD3zx+GCuJVWJPilq3MZzqhR2y3wpthlTf5S1RZX1KTrTdxc3/M0VaTfh7j+Vdna1L0suMj5cpj
#UoTGYURKZUT1w3I0QbGP1MYhmixDB7+1UIep+dvESWWZBALCJSgws546DnL3gOMId6tVk1g9Bp3//SJbG7D/HOB5Mqu35q3udr0X
#TA8sbrbRPVp8hsyxg8HQzPi36UjR8Go5xYwEc2LBBaMEOncC0vga1B0ppmHxl79bonxwagvyUNaCzCEDia+LUUg91dZGKiJz76vz
#TxLTttNl50BbuBNeBsEmWQjOKUPS/VHoLq9N9s4y475vqOJ2F/TQ+AYsgFBcMCsfWSfbA/+0nZijvLb/TO1oyOrE+DfKYRqhIoB1
#+zXGKsJbaHgwx9MUSFIxAtmcptJ9oZ+vz4mYMH054OXbNQsLxLI10IEqf5eYGgiRM7kW0P6XIp8yCs7PQ4vTWlffd6OgEookcKeX
#+oyfgeWv+3ovesIY1+bfRXSPTGbirLeLW5wyFi6B0galUjJv0+FuNFze287JVSoQYa9EMTQIA6Jfg0QzBvrJ3nm1DZwgqwDP275j
#OHo5scLTIgHML91tqQ3ZzmMuvWyczCfLpEh5tV01YJ4GgoAwr5AylRYxT9H+1cMSH2Nl8UW5dqQWnFlXl3DGQPLIameWA4YFfZya
#y4tKCACOAJ0rQD75TrCFqrq7qKIXDH1/etQQyOhxFvMJp5oqJYB6KQXbVPiT9yafv8+9RJBRCmvZ9QsGtrL5kVac4Png1CtaK8B+
#4PznLZj/hmxOD+tuJcKUuDEMOOHoMa6vSrFM0+wXB3INNYtk4wJC9r1zG2/M/QA4Fg2nKGB98PDadMMFK0C0a79GemVoGAPbZ9B3
#3oSJWQ+SdGiCNG7CoZ6nfHZunGutIC3PJP4CfNz9mNY+44Ojx7aXSmpGvRPaoNhOdAEzx8aKaGJODgmfLWnEEeymFKBXV5djQf5E
#9Fpco5IHEV6f9wMK4t+q2IBmmFzjOw+SaXI+38imiPGhoLcIl5qW5xr+QNCz2trgg1pp2oYnnUn2EnIVqZMHjJpZj4MvCzZfJQuw
#QfD85bxf9/1y7R1nRxjnUObKUomf5zJUrs8uJmoc96/ZyTn5UsynfLFVgVSDd2p0PsTGpCYL2QGBCSwlhQC2kkmwMFrPX1UshPOE
#w6gh+o8R0vvGaNdkFV+ZAoNKbeIDLl7GdBJt2j8epY5t2qTOkw2lOG0ycvf3kaXeouBQX4tTX3GilEhSpDqV0rRQu6+uErwOHapx
#lwyT8XmLfoKUS9xMvh5z78QZSGY1UGJjVJqd5dDQ23yKe3BJpmjMzKwH5c0rtFzHjORL+8o/bOT94Eg9QekOsTwhJhAnHwdDN6f5
#1R1rKJRaKNU6s9VSGcit0E5bPVVKe0ZI//aIoIWWDV7M1nUNkvZSNmLkV1gcHq2V8l+pDdk7c2YLjcT4Eb+MvMX1FVQ6QSX7Mr5j
#Tcj+fuPo9X+JNI7uKi4jUj29o+iixbtpF6lgV1VEC6mXgd7yM4qE5KtP6mqrh+ocwpkhRaeDXDDchgsdzykxW8MTrjXF58shNI8U
#lOi6pBtkf96ApZxPETJ6xdcelkCDhP+Zo06BFOAF6ILVIPJA8tM3mNpiF1vXNG8iWetU1IlAn1W2iynfiRIs2jiA+zruI+8KVjBa
#abf2neTVw1j/RQYKhbCp6EeBIFfNCFyQFVgkiejptFLsfdeJ8nv9Oj/TVSiwg2RVFl7a3UFnIP3682h2XlzAPGay22el/Kvv9fXz
#0v7pbXJWFx8b+LTQ9qJVd528oS5cSDE1XTiJHDGKPzE5KZrIYs7sYjVXKdFKDBKkCI6f5c3O/gZxx3+LcL9kSEvYhEllLr083K1e
#uKyMNtO1jZm1+ZxZXMuM+aTKzEB54evYzsuiffs04YQq/jacnU35+HEKsf6CQ9IOW0znCIuHNWiuAFgnlAl2oA82+7X1xYQ3AY4H
#0c9lejlMLgaOqCoAGHw7SKUDEXi3N+pG8J8fszIbGPoO+sgpHW1m5Ec2/XRFTc98BQ9Gkn18wsDJgdi/fq75YEkugjg5oYQSitzu
#jhdSVLAsmCuaTVJuQtloajqpakRtapzRJkf5TTMJNo0U+iLKo5DhVEOGTw8HM6/q1o7BdFRDXP6zpZgwManxd5UYIN4NWuGn/D4p
#r3fMDkfy3iEJFYame5KHQs7Kk/3aIDX1YAQrMP4E8tEhOxiOad1NZnYrWt+kJqUIVcQ5f2J0FQoYooB7xbjHsIN4qbeQGZx9PgNV
#8KcC9i3VfW7fOVGq0l0WrSyVI1dWkvCF4j75OZ/2QdX+c6TeHT2ydlOT9WvceX8YYVkFcSnzjYDeT4uBPwdA8POiH3m3hlYR9ABP
#dG9iKWRwGqvcQP46PJJC0oidoy5jl4UXMY86VibhMSeipGOg06Ky8Q3IyRyVkk55lpRccK4Ts7VHDtJNJfHRlzZG2JBBWth4cdwQ
#plfrUFQ+5uQ8oyOBJxGVABEYBxmZZx0nmdqMCsWzE8C7tRNRVFnDzh86W1zwiTCdickdQc4dAc4VZVbeDSf8E6DHytz254nuQxFN
#8IlwQSSLp9abhn059HTs8YCYLSkKS1yN1u5Jlfek/c/SnYicvpZx6V3Bcm8OnI8axITlWhiJEVR5K2V0oAtK0ljPMrjngTKH13au
#oC+O3dmT2Gd8LkTAdiF6wga+P+6AcF59/lUIuiw7LpNUzeWYV3fMrTuE0mddCI+okIDKdFTwqefTwJcZsvb1gldpR+Fa8E0JQRhn
#B+plf7GNwk85gYpvYVIzYq0ezPR11Uoa1aqOddXYqpPHPkZm3/wo+1naWEL82x+0AWNz6SfN11xZMuB2lz2j1paX730NH3yDvd/8
#s1QkvD8S8344+ivRFlc5w3tY4xT/POHjYHpfPKvJxxF1N3w5fAttN6MdQeqKOWDpkIhjVT9oiFkR7xzdhpJGM8Jrs0EarNp+c1kl
#sE2ZxdWW4q4/tsPG7dgVG9oidqf8s0rqe218evXg4N+i3cHG/EUGXN0ZBQz/bsPOiFs4S+unIshhS5NryX1zHwQC1dX7KesFEFsF
#PkZo4BNA67enmfLoj/MSUi/DYhVclNHHDanf9Ow9A9Js+lGAILoypEE5BeyMGXldEy1/xNreDM5J2v7s+E8BvSA78nu9aj/BX3L0
#T296dhyPdz1K5b41ckvjOl7rjtNjIUCtG9beM5I7HXEowWNWDGU7Im6f0LwnWbJ40LfIX/U71Gk9zSnsQ7KGWsUR9prdOnpayE7N
#nXhvIbxogsra84B49fRM2fi6+6KnsphZjU5PRJerytnM1+Fz7iyQSnLnMaCK2+NzoFGVfL50YlL9oH/atkmeseAeAx6oGmde3CBX
#DydH281VWqsO0+b/vkpv6rEuyIke4GgWFpM6OKWIeZUHAOHYcrUJtt0yEniaDunoFqogltOi0+zz/hKcxcJLL4IckZE3qqzPv7sg
#84LVRj3YdZ/6PiE6OmxGB2nhCHSeKRElOBeTJwRsUyYwjXFNurNKD+l4fLJ2r9kOVX3Zl/Fepz0L1PfKliZP6RI4PHAIYu8Ibemp
#1I7hnA0BYL6p8X1cnDtrP7J9T97v0Pl3ZvS/5aHduggBwCFQrZIoIKgbAMtjjrt7/DPi8N5y7HLr1MKu45dctTxLlp5NTa03LNkC
#w7x3DUcBPg4qkAIQ+2F3O2u5nZHzeuXUWfUVUgPHRfMck7YAkbD8iYvUuDcrZmu1gUjCmfuSwD2wr0WC53CcSWH9MQ5e6BaOKcvn
#/UDSsShpuYi8Y75wu3iizTLk/1NFCS2IPRqgdk8lnkPLGys9dW+PV9k3lkbiPM+Nr8hmT4QMPAwpYwTSHZvYbAv6+PoQqt8qVaTX
#Gn6pYY75MXQmsB8pC1QBM+KeAvypieFUxUexLzH8mF2btDGVE6gCI7L0bv1f6r8SZcg5fD5wxXBGZAfovfeXphI0Ccu1uBlG6an1
#kzUfx2ExUF957ChzmV3yiCUW6hvTlEW2hZ3BHzoQiwI+W5/R9wy+fsV9ndYNghpNu/WVCeT5OQs1SDVie57FSyQOCmUyKLXFWEB8
#FEKOYEr8TGCOkjqYekncZnTzwDml0bcYtUnPKIhgjjfqhlbYiM+ppmo0aTyZXOeFphhK0vfvhO/V+vUoZKr0BlSo61r2IqBLiZYv
#XZf8YD90lnO3sVU8Qv1fTRlPnaxbomkwErZxFMWQvgWku/otG143JMF3Mz2fi5o8jaubiCgXyIzQ0pcGyZLhHuvYqRBOntkcZEQC
#eDXNZ7PkDPYwzbDVTSBMGI6YfaqOuiI1yWtB0jAxEyqsWO/qBteiouTDAr5gyk2NpMKgiq3tp1cUVMN9Rnerj8hGTCyi9WJWLpvo
#W7MkTdh5sc36vRCokxSg7B9oTVXDe4Y9ECCCANhMsMyWWFStZVxDf7tMUNekLQolrGDHfgA8fXssjSzorScgrs5Go5v6oYyGculB
#TiFnaBEMiREA59UpkpnVXxZm0DuHoe1j+CHg7ZV4NFySa1I2Cjdbz0Xp/lOd+yLgEDJ+5Hzoo/R/v4LWaG5NcNDAifr5XXT12PeC
#KyMOFOTTw4DJVjHNyWLrFy6D+X2bAMjD/9onKvnqriNfT57pmLW/HMjLe2TKqBfFtv1AqaGeStmMKxPzLRTsCYuLCS6EM4RmIdTj
#Lo60qle3g/QiqgekYigaWVjWouMbF8USz+m8iIHKsAB7++rQstgWAEtuyuf4SnVbUMzEEBFMFTvTCUT2P1jGM3vrybSQPwDKkbZL
#h/r9wD2VL+sQJarmF4B7JQFiWqlg03RnIyVqPAVf30oaVIOYdEjfgD71euWDOfH5c6X3j+z5f08f309VPw6+AaG3I4D5w302X0lF
#E+c6w2yqIApSkTKVlpq/Sdd2sMyCmH8gTVsSkDIpqqYIzfU0jl7JJKD3wNkoUCJGwwos+1s5eIXZmGb5MWf77YD9QU99WaKir+q+
#6PSdDwYESgbBCIKJzYTwuNLHYklqCe/KT5aatq5GaDJjqsSYDiA050BDj9NAhzeAgFD16QA8Y5uritjjJCMStra3r5E26/rlCHcV
#e7byD4Z1/wDnRGeaq/mnyuDp8cyU28DPulGAruVzcx3w+hNN65BQ2F59+uV/XljAQs7GGIVqVNpJFiklYOelFZMMZz8sgPp3sD3W
#pikTB5mZ6qJfkZvDnUCfcLgFS2ltPjrPYyusyOWkpuKuq6seMu0gTtwlUS2fNFbtCar/lSlieEhXnpAKA/mr7EO/YXYxcP5lQfaH
#JJmhCJn1fTLp8zfUAkwhyAVoQ18+ncgW3D0MQCqP4CLMJRsX4fJ2emXPkdAB7zQc9B7XIzEUqUnwdKvtXsI6yEAugffunDjdYubY
#B95hBd5DAMif1N2ICIme5Utchs6iLgBiSdgcE3PPwQocLSbVHv99Tnj24Ku/4QQOXaU9fEZkkDFQaj1PECFBQHVvACcXIUmWpSwq
#0TkbQvkD/YsH++fqO5T2HEZYP9uBpkyxeeRJxftUq/atXemiTflD54M/JpFHiRjqbSHFJudzhOc0Jci5p6UyASpNU5kCxoSgLcgp
#Sin9sUZtI0ApMPfs4rV+WjVCEhjmeD1Gm1fk8JPNnrkEyLsM7AUBa2XC5JeOSnpcxf4hJZFDKbPwSWP/dTnie9XxMHm9Et+8q0ho
#izhenPbZfZiFlIKkQF9NWnAKVobs8Ong+Xf58bNDNtYBE2NBM/rBvrUtOgkiMwJ6V3uNVlv4O8N9p1ETGRhJUejujkJfLuAy9+84
#gJreWeyariVpKGvBnlfbXDx7/utMfB6OQec5gh4SRU3k3XtUGMPMFwOhEYXprPKtuHoFCJXFTSZZDJDDhLKenQ7J38dNK5hUqco3
#bYeTKTNiI6IaVHr3NWu7lCeecwwtu9vBLJRVtuk508jSuzInVZ+EBw4W0CM/Kc46pm/JjmlOxrnsVGveyll6ZS9nu2OVJnXXNAEM
#3aBmZCLv3NzBKuKZIhPqoe5ELP2BT3y2F+J28za3K0fEcXENW/qaVs5KT+NpzbcPeYRju8REiUUnL6rUKqinRcjacyIBnpA6vHVQ
#S2itIEIx3FuLcD/NrgZ95C20I50z+7J5a5bAxI7G098zUavt5NuRtuRkP7YrEVo6N9e/jJ/356Ctz/P7/fZl6OL3tV5W/WnD8E9m
#bx6FEQYCu6NsKzjKiZNvT7kgedtKaXYjk2U0dIsq/pzMYOxLj4d6o7LD3ORq2tips7CssS/RCjuHT7WjS/AFXfKtYId0KNmM1dmR
#FOm8kxcvW5zTRx6JIYH3yO6qvaPAeLvEVlucQF9WvGb1k/Bpd00uBi+7lvtQ97Kxbshmbwb90oLQWbooee0Q0LGM7f55Zmut7Ghn
#plZC3fF8nVdZ+TVEhW1NZn7aau8QR7R/x44xsFs6Te2iXcqaod1YCIP23m/0NwrQQvDphAbOS2+uhfZBzw67yeOvgf8RBN9IEn3c
#BljEn9F4o+kjGoBIZmabgBL/p8ckj6Il1Ueqgrhl2b1NaN+sb2KQRWfOHGIfHHPFx7Er/xoMwHwepV6k03GQ2Bv/DYP44OHWrfhK
#IFms6oMECAxL21JmzHMIbBx901g7KLjGa2/W3Ec2hZ18EWM0Z12abkTyhHb5XgYBj1upMbxH2SPflod4DXcvY9uCZ9gvW36JKQtW
#sVuk08SFewfiuPg1mlkYEWrYfElfzBev0GhDROhM8rAGhBxdEPxCLdTMe23g6RoFh9n+0keO6Q3lLe9czHnAF5tpukm2mCXgYF56
#KZnm+/Ntdqt+m/AE95TNdRRxwngzRCOnrDgZW5RwRoifMnd3m0xF0p+A0dmTgKFbQ9kjqD7+OfOHS721w0DxngD6h4U5tbaH7amu
#92NcmzXkX8Kjb5vmdPVv6Sb4kkM34CaVTAYwcnSF2uJ3ZMj84SD38NdEIgOansjTh2GXVtQavecbJvyjvZK3Ys/7CCZY3Aj84MP0
#YZT3E0jMbm97rH5wp1tOdAbC2AFCM9018X45Hxs7uD9LbUXMsqz/Nag5wGq9A6oaZV65CTU2AEk4ngVbgRC8kq/4A82FOKGtx8+i
#x11QR6rJDw104xnLFiKetnZEi34ZtLV3dNBWlLFhGFuYEcPN5u0qxoiRqIex6wfzPRC97hZnS4uvkg6pgkcjZ16JD+hgPIyWrKkr
#cVZca618AQUbrw+m1aUMivVUW0OKXh9Poy1jXmztIfsZuDKTk0cuuBGSn56/lUM70GGmGRmKF01Lr06GLcZWkswH1E8d3e8ZbX9r
#kw/9+1X4mcCPTmN1Qt+R9PtdTyplOMZ2vkqJDw/4qKRQ9fUvTntb6kozuY091wGCGqG3F4jSfvB0s1Bj6MSrQF9WPARv3AcyE9Ra
#m9bQndWjUzffjVJZEpl/NnvRM5rZvtW+GNWXFuzL96VJQEHrW8CQl3VHQhnnNDxA+60/N2R90LOZUDucepMknAn+TGLn1+UU178k
#yyWG4SpeIC6mh+iEhjUJlpBAWJPzKkCq4WdhPYxT4qOllVlre5EyGaFT6ve7PLUp2p+tzEHAyeFZk4OZzTaU2iK1hj3znPp7nN2y
#vPVv1zCizk3c2MZ0HSYrLDDAGLbxSta2kub4iT32Df4bmAOeX7yvpTu/p6kxeHs93uz1G19tT/JMxTqX5FNq+2AydJJimZicmmAj
#y8FeBjwfd/7KWyIAQzLncAGcnPXgDioLF0fphChQM/eLnD8vZ8hkRmA3lhfaapPaF8FrxA6m6yzWA8jHG+POE3gCu2AfR5I7vOUQ
#Rc8K1svOS7NOLavjqSKbjhYBbeV3Fid3yp/0XrW+DuXmByg0kLEvehM70h+BhkHWjCAoibNK+8B136EOujA8zagq+ygrjYkE7TWP
#gDehOuFBIiW7ec6BIMGcoAHM+a0Iitht1kbuYrvfWofyBpdrtCj6cIGbrYRPhZoi/rPONj7cg/hR+vmZ4AtajIKhklyPw8HA2CPa
#W1QwiFq74a4B8+llDqr8wSQRmhZ1egyTpRXUVSkVpl8P9loZzx+fhuj345opaqKNiVXYO3cOAo8mf3YC/6G2YPMRbbfevn+/NPIt
#sQaJeR92qI6mPdDAD8yBhCK1hNtGl5NaPizH9e5+7ut0pS7q9Z/Gd2XFzJdyG85YMc+TILscRbnbSOROfHu7lgukra1GRs4Ace/3
#O1lpc5Nfi9DedY5TGm4PBeAJrlr0mlBZwDUKDCMupC9U9vGnN1r/LLPqTpc4XMSDchcs6dppv09N2ahiRajCIJy+6/vepKcZ02yZ
#mAcTeGR9fNu7HqTu0nUf5Ot01hJAQcII/PbydfoQbFRoMyCw2KLr4UrB9v85NNL1zrHqO9CdM+91YB9zjYVWLUxPJxWiG5KyOd/N
#/1h56dnbwDf9qLGwXDHzgJFji/dZB8m7BpBZ1qxCn+3xy5PXeLEJkvyCcBjm0XnNd8FCljj2/Zkchxl3kuSiwPHg4zjctxD2IyPj
#4e0PFjCW9AtscQ69sinJkslqnQClzzf1tfm/oP+Wm4ntXfaGK+ZJGeJt9hpvCyre8ycYST0emhxdEvtRjih15MhohcfKDEQEKyl/
#BAyQ4mwSmJnEqtV5sKhvSjmOd5cRepdxHjM67cJ2ZSFfv0kabfX/dvM3bJmk2axJc7cSc/U2yuDabvvoE6OTrEdwkQi/FW0i/0Y6
#3RPmDaN8Mv/tpNLRpeHdaF7hUwTssicJltdyrZCQJ+AgK81aikp1JCjvYl9zm++rmrreHislrI26zZQd4XqrXgwD7NTraPTt4jl8
#nJ3g+/1R8w380kAVEUAJUZr28Z+cfNTfi+Vk0iDPNuHfqAKEeT8ME/+pun7Uw/mw/tBWttfV5cqJOn56fCokjzhiRVuPN/OzQDSL
#DL67G+23hErJURyOx04dw4y7W+AtuJ2RclkauuEikVx8UO9T4pMw8RwBEAzH+fkRtsfeZ67WD68mF9D7emUFv+h3A+jp6PH4eISt
#PWh1ZpIClmgumf/YF+0RKEkqmknJkSJLO/AcuJTcN6vtGrXolAUmtHbestUydx1+TcUWAswGPV17uK+bXn2QPKckGL3JSJOqvmxl
#1PCfTB2dZa8GsXSzWpHytx1cn6t9j4EUiHDCHPcRKY8C+KYwDmHtP/SOLI7u6XJTbENjz76xv1+OfLj0UC+SZFtb547GsjPH2Y9m
#2irKZApLfHJ3Chi9cIKbyKjVRwke8K0ljbfU4HXOM9PbsuWLmpk7tTpNLuCENLjzVmhM9qfQskNm2rUmPVRsKUUvo5RCoaeHDzxH
#Al3kn0e6RsIXkjVbHSLp6C9gGoMgsP5Mb6bkXlaFIiSdAISV3fP7bdv+1veopdkrtGA1Bb0zIuZtw1HgI9HJPP0Sa3q5x23uZkQj
#PSQCI/xwA6H2Uvjs+ERRJ2Pp4ZEfDrqiE2vn2aSP2Vok+9CNuwrBHwA5AekeBH6Wkbry3ZegW8O7gQbouAWZfPtdg3xdcyV5gr1f
#3Pzw74T9xv7zeDhuILSuB0AGIegXCOsNA01aE26Rn3zcGP6m+IFbmWSBxcfeKaHmaCUpg6buCQa0aOgtzRrzshqLA7Cvh7/nBk3w
#I8nrJ99zgZ/sYxhZyyGcoEU8Ace/UCM4fkXgfAdop5cU/FO8/55QntDKIT3+TfF8QPBM/8KdHxv0iqtx1732zX/y8r0NFClrstfb
#tL3lG0jPq5jrOek9fdJR37sA4gj6WqRHg5zD8+4lh9dgt3/ooFm5u35D3TtEmbvTruVzv2v4Gvjye0bP7U3OTlNGP7qTbPj5R7IT
#/WO022vnxi/uHucdQKfsHvrYZGfIh7pUIvsjN6A88fxeBX/COquXnB7LhO7zx2hicFHbvou8wc/kJW90d7Vo+Wnn/Iolze8o3ImI
#LklgliimFJHj8ftEwocZhKsScZHEXEYcJ60LpkxxjzypANbSnc8yNSS7slM75iP/wtHZfbAB6KVJBbTfx80zAfI9W6bRauaqqYO1
#erq4hyNZU8DbqSx1fUEAqqmxvs5Fr4FetbWVjbux6cyiPpILI0lyzGO0MvKR0cSsFV812u0FVsPZHDUmTrurl3fxvvxD8uqSKFex
#j5XyErW8a2bbim981Utx7+MoRkG+9zaOysNTe4XqfCHERX/7IGEVeCo1jl16QTYOyeJWb2jhji8fQLoXwAfuotU+ik829Q7r2H4/
#/pRtwAIegQGjulCvr3zTTbqocsvJ0TSFHd6AE1VPyQrefuODhAUrs1K03w/uIH9dADp+NQokdLgMJFUQgWx5ARQqeASUKxJBNtBf
#P1CAlTy4wCkRE5Bphd0duENgPbO64Ga/r0Am30CjOqV1wSbj7rrJMrFboHtjMJhf04KUPCyaRFjao225b1X0/abVsU7q9Ai3XFqJ
#El8yRt1LCVIN2FJ7+I9ayzKmrGn0ZZXCGjyGA9eKQ3anZjtbJ1FDla3cKyBGoyMSbibUCo2aCXbCiseHG7whkm/HUmHbbp6EJrQ8
#dQWmugZ2JjAoU6MnwcsIoSXrSt7pa7OJRwJQsOFjwL3yRtG47oNIpBL1pMPCtdd9UJLRaCTCfdLSPDvFQGP0si6D/6wbDJ22fs5X
#tzu1nDqORC9NZ/U80oRSqeTfBDm4aNPrl8bVyeQS4R40aCD5wRR2fpaQaKQu67rCUOEAAikghSoa7qQqBp1BsKIYtmUQI9z5bUxJ
#ep1x6Fu3ffUDGUZZWK7nxU0K/MtDB70RQRTOoyKAdXVJ8aPo1qiNkzIz/wdaiJRxf32RVaehm9dPAGt3o3gs92s5frBitkwpxn2D
#/s+BPI2SGVrXPBtk04J6KeKRogQ5yaK6ny+myQnneTwNN+dBPTGX2eZ5k98lM4zgtWLGNbJNdqlGZuiwNn+nwrd5iIZJE1WGpePg
#gyz7Cg3zDBul7vPnv1TC0XSjWNLVdSN5XxzHUKYx3LXplJvQrdo+Sh5OJMLOtgtsmxtqeljmMv2lmtVLmfy7wgHF7v3t+Ma6riZM
#t+ythfWdsV6vh1lnL6K9HSNfaP8dMW6MoLVmcWsxe1wUu7q2CjRld3u86h7v0Otsy/90GC+g4vRtUDhPLcBp9JLUktVslclWB9Ne
#RMQgGcogRZZikicSUFKr4hOnAkoMhZUUIDeCCgwKSvPRgUCCzGBSYFBQmQtJXio3rSg1WoLuQlVsF2H60yem7jO/ZQRmxqOxtFkj
#akFte4VRuCtWMFUR2BibMbKhPoZukGHbubXnvqVytr3bIt4QTP8YVveEWNp+8cFRIkpo9YKiMG5uramdnh11g4J6VsMcmXhbbB1U
#nhhed6GRev23qWq4ogqvqubyXxlWMbmiGOA9oB4wERBxFff5yisIDUZSYCj3mS8cqgUJT83OA4CmirtayvDueb6Uvkso08KlYaAK
#sh6BVhGEWDFWfcAKBOXMR84nEyuZlycrDS2Qj8Xp9iU4ADlVy3JSRjTnDqMQXO7hW1Ln/FtklZWJ03MKwJxoUuTi1HUE8PGQqrmj
#fmwPOXpiAjx6/teJfP9v5v/E/2xsYWjtZEjrYOpibPH/RPv8/8//3P/MxMzCzPJ/8D8zMjP+f/7n/yX53/3P5DgAcP/dDTgAAMgG
#/y/9zx7YXSY4wR7/1T/TIEJA7YqMYkEHef8P7XOYy3+1z2TgYZDYeIqoSzM5BOscAN/3ssEUgTHACIs6sYWeTQavf2EgduMK1gZ+
#QqUkcoJZssYb0CKSUlLVFKSWMj+pRc06H6swdlN7D/2YNnlvuQs158YOFRvUZQcNoHgC0YZ20TzDN5YBaTgFDfJOEYUtn3HVu//8
#jwHOkf2NxMsVfA78UaEmoDQo1JrXxFnMm7zSpiRBJONRYqEHWAST9pVQh6nwLHIioSrCgX0q2kFrNH1z3Zf4O5t0MLeoCmaYLABq
#FHsBRwaAgbUx7xzx6cLzQcaqWVv4kZhLK9JtWzNKGYPCNKGZwMl0p6YJvZ/Bq9vs35yPQAPKJFmRNQRkQRhxzjNydtc6UNnEGVw5
#6o1RWC1lQhqQO6Vkgf8gpBmLFrOARrsjPgRlumhPwRjn+JufdNVJU99t+FIAt9r4VtY2gMsZoCmGC0kpOdtgYgEB3uwEc0W+YSZd
#YGxPNnt2XHxXCy6JjUP2k68ffnV//+p+qmZ8uc1P5N9BFGSXswQE2/2uLolMYrJnc+DZv2QDyJULtXOJKuSn2mqxNDBMIpgqR4sn
#T/5UVlDNw+l+Fjut8VOXG5ZptXnIuB3c+w+OjqqFGNFA0SuPeQeVjIRSGrkpPwdKmmnxesyIlqS1R20wU2l9u2jfvq6vtea9jpar
#7Y/jiWf8lPtg+66xLa/t+wjHE0MJiJjCNTADw9f/dly5cZZ+6r4YQid1/6T8ZQGYCdBoYFBgoo3Po4olfuMFMGebjj3ZRfUGDoOW
#Y8beQ+ucDxbHQdEJ03AbTISKyDyq5tDZgEonWuAcL5WLAV57QE9IBfzys1kGGEjytVHJhOzrwuOH/+BZUE5z8bUhTQo+0HTw2p1H
#UgkeSAUII571ojnSCMpR5VUOLc0rfoUUQBFYSFTB8AFJKKgit5RNEcrlvp+b+mBAQ/POwhAjS2DqrF4WyFXSd0KgcfSi4xHOPVVh
#6PmAP6KPXSsMP+0Cw/T+rZ8fyy3CuXvBtv1lzGi3tdLuDc5oHzXUup1QZziGXhhQSYyuv0trGk2kd6T7tFCsY8Aq66MJLZKQ+eKn
#9Y6Sbi7C+7T4S+U969mvk+YMDPoStvC7NY55ebfwOqyHLfDu7MbWKmqHlEzRXtxdvNlauNqy5jmag/CVhYiu0IgUn8EVAjslxA7P
#XSnIIWOtUYZl9VU9G+s6mYizCtnUAz18+P+9NMn2PoXESd0+tq4N053zf1ZqwXft6dq5Apdu6V4Y3aRYRX7PXqpGhPzkLV7aPJFO
#t8y5RU7HWyfaYMohFRluw8cxTAeki/g98eIvxbMPN53xj9foAH4kWsg571uApMnrzFyQPrTnxuvb/SpBdoPsq/umkAl4M/x7pAPo
#LVG7BDUB5eTbtKGy8/f6p6ZX1U1oLzEjxbryqLONOy+1iMeHr8rOOUn6HpjMNhNdZEoV81diltFeGHPEGru9lJvhLpSgmonk4YNr
#3LOtVIC989oOyLjZr88fa5ZC/p53uT/727Ymrg7MNcfDHHW/P6s8HIvIVf8IYKyy/yq3MsNFGKh7ToTOYLfqQwngCmdg7mZm7rpe
#Aczh8+ay72msRpqQiMsjesa8IqOtaq/ao+vqUoXMgx//F/s7GUlsjMSyOO6RIYDMnNJB1VM9qSpj/kry9SlULN46MC8M7Zr0bwFw
#SKH8VmifpFRZzknU8IvbpHFbqA2fHFMU4mAMeC4iRyUBdYCVxc2UdAiT2PyD/JtX4qxT9YZAb8941gD1uGA5pD4mIsvjkfk6F4/z
#jP5ncG98PzsI5EXuN/QEYNOIUOeCL70wjIxg+ThV+OC3Mt2kSgP5ocJByz4Ofw7a2QUSeTaRB5gCzkNzILse20winqQSMEZX1glk
#CYvcprQ7zVABNuxZeOHNlpI1YHyFYcusreeV+7yeOJbrNDhJriIIUgInNHk6oEiB01cqtQzAaUCFLjmxWZmIK8FGRFGKpaXEr90I
#TEyjGiWbBbO48Rg2Hp5q4fW2pPNSrDSNDwUqWVwBsHI+TuqlDAq4fDGf8gaGLbtHSqocyoI4GigaLBKstR5ktBIQlVk5wTa5NYvp
#VWnSV4qDg/Si3jheGaVqqZ67igHmSpeqtRZFpVCpRseBqC8CGnbaqNwzyOByLPUAYEHqwBU4cAWl4V87oYXNrlMjYZzAGEqACjR5
#1k2Q0ZbT06Arbs9svauRIkefylhlNvZqvuoUTyWeY4coY+7MY//RECTpb8zUp6pkKOFxpxRCGjml6h2UhiGpWoVMleDMxkdjxkDq
#Dlre2HBY8itqEDU6qV7uTOdk4sNqP3G+wQvZjJTPZMK407CMHTi9Y1sUQT+oeqoE3WkgvLcvCt5qDmSJSNUtuynNhdTut0oVuKWz
#SpiGpq83pXBtEVA1XLTGxZG8V3btAGonv2pFGiAO17+7ErRa5T9Vw193MY7ptgikhVC25KVQtmbSUugREom3YgyJZSkv7op4Z+ES
#JanCRKjK8uJIqcpzgbHdCEkSYqnxBclFNik1GWDVLDfKL1/CtWrJBKCXQTYjUuJiEHElUbJ2pJaf3AW57Pndks5OGfeDYcHiRih6
#9V+HkN7xZ8n4wnQWzMmJxdDodhDKwnIx5J25XKKBj5Oifd7sd0Jrz+4eDPelJJUi1QEq550OrRgiq6RHtnCD+uW1V4paJoq6kvul
#06bKE7FY7q01XWRDwf0ruoaH+H8OhBAoNGDJrXqUALKQKfgUOGznY26kPFNR/m/3EufihTuoWly5fMYT1kkLxxxj69CmTrYJ3Hi5
#RdZomcnX0dWckU7jRWjMRuE/mwIAgaZiBw7XWAaVWlTNbVtU10i1S6f8YZyaOfXn29XQ5AlolOjDum/xuIKWR+5PthuCa67GNQjS
#BB5TlimDQw+ImXVNdVkm/4z6wBfRSf0h/S2MyBwmfamkrMjHxhrLT0bklczoVAqIqsXvMrLOEB4CFk5PyTMC5o2GYJ4OufR1HcVu
#63MSwVHJM5tUVMUOP1I4HAtUrAmi7jlIhUHxea2BOLs6WZQ6xNRSGVlp4/Db3LsIezKBI44hdKygcoE4IdGEYaGFD9eTEgV/dryJ
#KsPDwyXji7OJqCQVBRltx8MvssXYeZWJLHtyjzAnAKOPAcScaMCdIYgxBhdwCul9/S+DZCHsrBO9Mq6tlHeGXNCnHWKw3I3cwLtO
#OFHmFen45SJuOg99y5G2vCZ+GMAPzg2cIIjgtO+3bBCa33Xoi9TkR/03bvOkjes5YNxIEps/vaM+gLPC6nNKnjg7YzHLNotDur8A
#D7Xo37eUOphK4BGLsmV93LBb/xRsziEFAfz+HcdKezzjSxhERll+tyGx4UAsd3s8VRD2fr9DF6OK0otWumw4HU8m1dXw/Wdkni6e
#PMdfWCLbM+p/Jo4JB4+IFmHtMLUVRDGkkH1RJSPiciNj1d8EiNwNV0XUNZMYJVWU4HkhcU56I8QhgFNVFQFFGc4f8Addc0j+RCI+
#VOKJ9xchIcSklBA3y8iZFKT7/7HzTjHDBW2b5WPbtm3btm1b72Pbtm3btm3bNub7pzszSaenD+ag52SuOrgrO9lVqZ3aqVSysh6d
#ZBM66GyF4kS8yP/zX9EuuK8jCE7jhxL7zMIHCFgJEkYqRCMlF15XsKpmFLXjKsJEhhMZmGCVREhGLWI9OzJ10IYAfgopVzIxD3rK
#M4Wgdx8A678P8I+olriLAiElBJsUsyCVuEhnBNocE6B7mBr6/J/uZEU1OEnYEQaYvuYKExPaIj3y7CaX8mV/DBaM+v1NkwEDBgwY
#sAABAoRysMWEiP/zzQ6fyizbZvlFDwMjCTpYVZihe5NIxZAEjJRRG1Y1nOyD65CBW6RhnpgTEUQoSZl5g/7AL2PFgN7p9MrJleap
#abbvKTIKk2h5OC8Ubc8B5iOJqSTigw3rrXEiFxV1CF5Mwkr+wnJbvAu/gYyYKaXEXqS9GdWWaUpzomPeh8zCeRwmjMyjdXTPwso2
#YtkB5hAp5YfFFQgqiJ9ODVlLEbBGBf8B+8TnEMF7qIXXGQYsQ5SMAQZ0EgcBgGgA42VghEv14CFK175qME4wkEhBjnAUmBVYFYTq
#LLk8sLY+E+RXJP6Ysg2blhActapVYfbrdb2azwPyGf/MffgljBVcsudUyR1ZNZmBZZ4aetk2FuAYcBh4MAB/IFakjGulk7XEOVf6
#7oApfG2Ar68tYBAZ5tE9v92Vp7mYV2+RhHCBbG9lkYA9D49CCgS62alYIPA1G8TYWNKGm6j+eCsQThL0u4g++A3aPTRqDPu2BA8D
#jdoUL1lRkvNM6afpfKQYYXKXb/WB4uGnBQUMuI088vg01gkh/1xouzyjy9j0fHD8OeCkcHmMyun0dBDTa/m7gty6V2+CD742Ph1/
#GUrv9npIux48w7YLaxtdL5nQRrUjq6CknM/JrbzgY7kROOsYcZsULUCd2tFsCMQMB78kGUZYUBT4aogAIQQWGMF+BmzE6vJGEdX+
#GytV3sEfBicDgOeE3w6fduFrG86/8NhyljjRmb7vJyTEcvRp0GzjwQ48s9J7LBZIObPme7JsHtLoQM96O8KH9z9Shs+VcPPjJggC
#Pw+kceCBfqAwiOTqk7w35HYgA4NSg4VRzv5IHifd3JeAuEiIRAOImSYhBcjufTp3SC5BehLooZCchdtL0IUoC7dbqSrUdEkEIfue
#oQy8DJV3BAIsQfgm9GyQtKklqAX9xWf6/hCATjCGhp+6z7r7MsdtkFH9v05Qf/08v9ebI+A5rdwJfOi57dxc32DeyfMaHycQhH7E
#fSv+MNBxa82hlFPVUmZ6c1Txuxmzv62TQPBcDuM6H7fOyet6rC7b+gVb9p3GFWMSSEpObTgcTsdRZ2KHsgNKhXqEgmaXQpEl5nDH
#ebyw7X/b8A1KpkgIifGJCcpLi4TnCTKRGZrJjZUKFVItXF89rv265raOs6Rnuq+zzHu87LOQbzgPg/J12w3zRPo8LTvq0NH/Fqmm
#alphZYMHkYwdTJKv15UdShZDobHxvD0eTufGXH2JQiDRByjGBSrMIsfGksh00R7cv3SnSooTgYNQGMaVSfZcSyZnDJVLR21ajJK/
#trzQ8pYr/g1StsgJKbR5AmAAP9IbAMl8Iaa7kjNsAi47A0CVW5SBEwIFGmA0GpB1tJBbJwz4qO4+fkDnUO9GhMzFQsYa9Zxeargm
#60+leEmeW5AajZVa9Om1umSZZnif+MbMxyTcIwIyoQcvcUJmxJpERSLhByLOatrQEm0leY97k0ozAh6Mi2RmweuuNDNrILEvCltI
#KE50zNrdC1EbWbluk1JBx2QtRSgyeQ4FAlwhfRZ2w50fW77XK6UNRcEr5aimgPcyGbecFlQs26iiGmMLFAjfQXhFcefeNgIwWGeG
#7rCsaKqkBoSNM8PWI5DPYyG7p0StWu5wjmh2+bvKcSn1grBUExHP3l+ienD9ytX7MYBUFPGZV0Yfxf7UlSsG/MEWPLhjo4N+FcRq
#iGiw1pqqHjgR64LSd8fmu9gIVWErarjy7HLnWUWFFsqbyDmWTs4SkAaqnmUVVk3qk1Pscona2KAFBpazA1s9NA/JghFJKTXXXuUX
#0DWbJIQMXOqgZBgUlizQFmt+0f7TUV/l8JpWcw70kTuB9mG5l07N0dYfqUvpo1Mf+Jb9/GYwfo3FG+3omrgYkWGfrrCi8tRqUToi
#STjmSoKJAMejGoqTxsqmMNgN8vxxTYrkhKO3XfykpXBtCUjSXdHsMURRoV2pkxNyXIqEpimYxaZoEzy/jkhVsVIdcTb9xgxAVbum
#jPEo075s0GeQS4Z6LlJROgLY2z90HbOMtBaBZuyEJuIZm/2EV+rTSYl0W1o5lDmyGGv+FBGOfKhZXEvrr382opZIZSAypvkrn09m
#z9C1kAzMWr1FLM3qpZVO7LmhV74t+9D2QSI2EnN9oAKJvzNjNLCrMNiPI/2QHKnuZ+YJ9Yi4bixIFP1KAwLXvEKCzgQzi+Ges/Pm
#KQBkrAXr2mSMYJDHg1iDCOkTTZVxFrJFs4T+h6N3jKhpCZ/WO66T/dr561bbCXz2j/TSfqVpPtCKp4dlHssivC+BWtfHjmlNw+ls
#5h1KMJJ3HMKropZG0dr9PXdCRfJKA5SMOnqgfJo1FlBbwRh71VkPz9LbMgyVu1E0Jzo3vZk6yjguvNURP8wsLmqfDRpsMtflEoIc
#KEVTek2TjcpZLqxu1SLrk9KM03C3/0+Pho7TXvLfiYF9zmKFo0YWeoATZmp+902gl5WWhqveRLmg4HyfILxkyCFzcLCWWSQ9hy8l
#auomZmeQDZc7VRxoC+hr4INYfNZ47tQpOEjvyXOpgUL8+QxKRN9NYOSFjDiT0mOAkPDIKBZImE5E8yWmaY9Vy4HRBDvqAGwfnrtO
#VVCdTk5M1yTlCnDiWV9w2XYqGr7IwtJxxCyD6qvTaRXoIVpytm6RtJQJrL0O6+XqvhQHdaaILlvm0QHca2cZu5HS0xpNbyaRHwso
#rt8r8k3Zq1UgC+9lALLPAIcjaFajKkOkHRmuqLFlg8ThSIUsw3A9jfPql6fkSCUPDhHNet5sVyr8GrLsmlPMpce07fahXJRzQJPi
#51Qx7pk3BlH/MJ0kEY357iXYz0WQ0WhuDQXL4dZ6MeXZ6odObrGsdyGzvW3o8Dpnza9GVhw1mAg1o5gPxUy7F9bwWt/qG6q3VvQa
#VYzNLLjtU1s7KR7yTc2mM4xxESYPRNsSz3nAGScO9dEqbmyD5KrHpoi9OIKG1Ei8CV2c343O7DEKOd0ZxwClmMuhnsOOm35riSHT
#an+RHWysLYiVGC/NKoXeSolhuLl0+wQBWMP8vuWdzgfaconFfAxJR0XtQTfg2LuHPAf2zrp6qfK5SCllonWFWzohSd2D/C0Pm7Rt
#p3OirLDxpb31B7uTl17xpJDMId9HwiLBTNZZMG9lDh2jD6Sp3Dz+FLFRvINZmFzk5aUEMY4a3SU1mO56EsePsv28AA2zwYoeVUpQ
#7lf7qJrNLrmiRFlwpJewyehbTZzogoN+0WYXz2FQD7ywNio5kGNLEFan1oh/4llHkNOJkKPdkPDm7xXHncCBR6rjk/1zFFfcR9UN
#f+LfitYe/F533Jf6H+R10R/0Eb8P3Zn0REKgO5Wkh1iNpJUqsFgL4vCEtBBiSt6e6vZ1xh3cRwZe3mr/3yP8fiofDa0sFR1akWWs
#nn1W2xojbMQaOPmA+jpfAJmYU3twC1cHVKE31HmRsrQUtimQmG2j1p21k3JIt8tuuCEDcJTpCDYK2Gppvani+4LZyGmemLt8SmdN
#uXdxapVfrcp2qigv1FMeDig5GKLCKGmf2e+1ZqfWAx8B2GxGl+BDpPuxEA0odEB6Zmf/Oycaz1efaxdYxsRzZfvxos/1xpnrPwhn
#eGfLiNCVDJjHpFeH8a+fA8G/Cum1u62mtLvNq6066eYVi9EvsUsd8ACu2JTenQYUAfwrwimkXIuDjuJUza8fmjDlH7bddnQmS+Xz
#abrVIz0DN8M6DUJfGzW801fmzdTwmywPjQu5k7KfBU6/cWxYjBa0An7JROTYU4xtrx1EwXjXG/jF/gZi9Ma/ubYBZhb3cvBTsn+p
#6mJpvqJFAgzd7s4kN8ALQWHnzTRvE+7HWlHzPgkSiSgHu8exAMBIF2U33zMty5wYCbwQjAiTZBjLwJUJWNHxYwYSAFEPoTwKvkPB
#AE1QCyh3PncoJM1aGwbyJzmzj7w5KW+hTAAxRNCYvtaYTuBD7HmCdIXjbqF7YmCQP0d3Ts7q87sET3ec8k/TswmzCWbvOD8bhsXu
#vShz74uCwghF1RH3LVL4lcc35Sm/cJCRXCFECgfbyx+kv/zBuYTNNOKlyW72yAdWr8CZBFhaeATmYUmxc8tFZ4NrZLXUlfzRZZWD
#fEiuZyY9aUq4ybejMPbq23CU48FjJ6fX5M/TvxcgO2nu+p62Zs5t6ImQbILe81fMDxO5Nblr1RnR5rXwvwC2626qHcDvXLAL5yUB
#JrzKdfyU+7Gj9JWqUiVNyoHjMVSKUW8l6HZlDk/WCFhL1vbZ2B/EEVRkvGGYxHFT1ig4mYNJYyMaKliOWVmP2S8CTAOLV8DPn0Fi
#Ij/nxRdKDkQU6XSu/zpKDLbKEywiWzZbDiOFLrAmMuFwvvM0nz99M1zIBLuat3qU6biq15hfPo2VIpb9yuSeet5K/tXqgV+g39dB
#GtFK0o1M8RbPjPYHRKUjH5I7FBRg/OKAPzTV5Djqc8+m8zQ5NOn1ARVmyd76uz7YVVPrOZRaXCX58IlW3c70xgG7AfaFC38yt6gV
#VQwwALZCFpi6d5T5T4lmQkmpaKSrLFsQTLCWu/KeocJdh9z360V81XRlvdy3Z6VYHKQnZeWMUXmbuBXb6V7gbp3AQV7jtu3B/sLH
#NzWtaRM+5+Zcy1/4fJY17BIvy3IU9ypVLsmFHbkZ2yiMH4sf7J1AEtqD5Aq9db+yJIauYF1kXXAWFUWNoGo76bXj200IBEM5IO+o
#OPU/GccOeJ1zSq38lawOFmJyDJcr3dMPvYaUiG0nTNlWvEOrGjXG1ieHa0uZepTCG2jV3Arzd6hqoXxgKle4WXDzW1V0Si5knkNt
#Vv/KVCgqdBQxoYJjJ5QmnHM141aVVF3cIlliD1+lHaHadVfbYP3q5JgzVAOeYmb2je/1QuD6psIf5V2EvPimfm5/3/ImrFxh5yKK
#Ov9UO7/cz2wD7+Ey4H62/5VcZPG+eMno1sH3hr3N0Uj8qVHlRMi7t6/sFJGvPi/sEGh7wLRHkU95FzWmSdfO+Ui9Yu2Hx+zGvIvF
#qCjXrlQjq6tUJgkSWNGpXWyV3GRgrmjVoBh1puX7+UkYUvoVGzUK1Iv7i4avmzpfLbkfaWkgWyLUvyiZnTbk3tz9gA98r36oiVcB
#H8b4YcckRTfNg3P2Jfml2KM/HzdHObdZntCBOEJHQlK6pkuJYQULIWhZLIqkjdcJwSgVkVwSteQ/dR96mzO7ZkpFpsv02JJv4Zgj
#RAZGoqnyHgk0qVco0AnwwWcC6Z36ACJKBCVWPCUvRZxkp83tsgeS6BOjQD6c+3xURcdD+dzw3fWSjnv6K+ALPbM7vfG9adW0LsCe
#DDqGRD6hCjNDEWLqnh+9XSvxfvdCC/f/Ns/vPCcMhPnSLvSsP803rcNeSIRq3CbdRvHs0kPw2rN0vvLxnnarUfm88R864jsI38jp
#VjcGJ7VoAgvdPUwggm2quILl7aWMiqf9A9cdSxzQTiwsEE+3ZB6yarIa4mQhjqmVkzzCP32i9fEpsfRG7x6rPcEL+Q3S3KApIHM4
#4dvbpAUmFBtUlo+mi1UT0fdKJng0q5U/Y3/6kKvHgetkpBbcpRREIGZlX4JaXPSMpwovZ/p3AH1jb+mZmWE8vSF7tFjJLCBIWyIB
#KUi9xMaHI3mOvMkbHewA2mUodoDwXY82yJxzz3qw2+IgnFjzC2MLmVZBpVjs3pG1vaO8oLLR/W+so0HNNk1s6rcZDHXhrth9APn0
#9xe4KwmfVhNvm7qr+DiuoPXzllfYC8amImf8Z1P/JpDLMP3XfCBlccob0nBkMrj+zkMo91M7MDbBDya5r6n3pOop5C7CsPobOLT7
#TYOZ3a9WocraYaQXzDg6cdJHLMjkAF2uZn9StFLDydkUpzo4gk4pl6EdRpoSqX6gLTLSyqQJhZ/CbMLKwN3DgGSaDpkqFMw8akOL
#BqJASrOVmwAa+hcKaGejcdL5VA7+GnGfGIVlLVA64C/OMa5E1ld2ccxcafHuuxeb2z5gPiKicZgdNilkxzinGg6Mi1Su/Dj4o54g
#seYG+ZQ1OLRp8NOoY5po/xP8dcnQOIq2fm/g3JlDZuBZFVrLNuBLeTS0D0VU5Ofb1Y4OA4TNBPon1xowi0S0Q9Spil0+Ny+LvsGb
#FCjWWKgLwPl7064IMmS5LrkeCNk2jAOEiPv13IlYZ2GrSFdxizD7gBEjUjqZNMXi8MD8T7M34LFHneHFXSu7KzXpH+N/TrHFfZkv
#5hnQXIT2oStSP8TfRFFx3r2ZWEsJGzo5KsqaKcRTkwHLwKRmr4thgvjJwMxgKVC6AV62rZzAbxojqb/jUV55UvknUCisdKasBtdv
#V6ZOVM2terbf647dRsvxnkGftIIJ0cGm3Vrb4Va6jQ87Apbb9msOGejGLdyZ19LpWta04K6ZBj6ZPI353Ji5MLY/frZoyATH3Glg
#2Dus0isteZBWvAH+b1lvdzjl3K/IvocWZHcFkDDzJxNdXBHxNJ7LmuHV+PejxSMH02ENUmT0y4TCCJwLg3d5yFRmSc05aNxgpeOi
#JAt2zHVJovTe67Xn5xdebZQ7SlYWpVBM6uwcOccza2BFN7dCJmZibDZd6qEWaSsiL3Fusx6VgWccXUzD2Sk0l4g0sF4a/KEjNUsW
#8OZNM3sYtIzy7bXNz8KZh7FKfC1zXG5Xq8sM5osh7bd/hgfs170KqqZJvEX4iQuQvp4vosF8CCD4ZW13lzrXHrNLD+5Mu6jBGsAn
#tT2Et3c79x5iF1Oc+8xxrFXg41mssmw8j64uahUq8I7qPEZK64H11QV4Hd0lk3pdT91fz4MMgsMh4uWGkhpy73xmghZtxV1b7vPY
#NxajyzZdvCBjc8xJbnl0dKUCUWXjZJS9NVqKOwoMqqPa5h0Ey7613ds1Nhm7WSRodWCts3uTgkFonGY835S/V5Ks1cvBnKu9DX+O
#SIYb2UI2QGocLGfsOUJ+k2E8pGMnZ94h0mTG0t5zE4af7sJYfmzr3YLDL8O4m0GhRIf00nEVxGkRIJawv/yzRKMITyFvyLjDmkBo
#LdRV85Elq5OHn+s9jj3XOwn8821Qws3JG/hmpmzTbuiG2MkIO4i6r8d4ohtOsOqI7heFgMxKXvHiu1XRmE9lm5ivFU8DaxwwOsyH
#W0v6MG2PFZCxLhY56MSRgPgr1dGOPdO+fDm6uno5mRNRiV5aBje1noNXfzX8U108zJ1BC2z6bVitBhCynRzFkmvFEboJeqz3x+cW
#Gm1XIPFI7deofYBX8f0msowOhshsYan1jDYNq7OpcWJNukLDSETpomdtbBVi6zha1QlCHbw073JJYNzpZ5OzEFnC0usWNTmxATky
#bcHhpCL1+czBDBgNFQdw5gIhMwUlo1L41XYN/2oMVi9kHaGzhKNYC4e4pZaKlr5PP9DYZj2T3+qjfmg9izrI/YGaU6yg/tt4ON6e
#yu/1nM3L8WA74fEpQBaY8mzIx7hNmmxbp+s6s1O3qTuwt9eBoPv8KVs0Jz62dNLW5rzNs4MbDKgjWyLZL8uvq5yaJ6x3vdhoskW3
#xO/769/uGmjbuIooXaLGG70mDGD29tqdzeM9su/TP+lVirp1oz77rBeLJsVzjyGaOvPNrAGbUuVLkI01/p3+5t/RMdnRV3O2wBh1
#SPy+rGa6Scx7+MNJf/3h2IB4F0lr/peUALGygOmwl6+1gRtrTFvXweoEw5toZuxPz1SPgqVo6mnqJ6W34OOX5tvy/V6EXuaHSScv
#Nf5hXlpMX1pm2thLdo1ZDktE/aXSL8sS8XvdJi3WGYZ7ldwMgVLQVT2T0elTjygRnDR107I7/+JVU76Au2OqHwHpEzdd6bBt6g0n
#3EwlMwAe5a2r3UIy8M5zP/yx5s6YI7dckWAjCd77gcxVCOuzmkLeFWktvAzAb3CzLN+2Nl4DekKoKwnza0sfE9NspKkafAKrjhOY
#0pxrowJt4bGdyR76i37Uz055t0gTP/kREO5HNk7xPac4/ywYH+D2s8TnaXl+4Vumy/Yemhbed0BlQgGB9PBOu/MueB/+ob+3s8VR
#g88IT6tX4JE8q22hrWdKq/lA24fCSu+LKTbRkCdwaGSscWEDOxB+aujHnx3Io4Lpn/hbWCh7td0Dthw9uiUImAQhi/2WqZAKwWkY
#GkJnSw1jVs0qvalN1afOBTMha/VgcOgrP8hUaRB5tY1aSgmIiRqRCBFxxg2HshxeQ5UlHiSBJJ+8XeAf9yzLk6w+GVabS6XI98Wn
#oMnMN05Q3J487MdD5C2pjY3CgHhzZNj/mTCAqOEO0ox2mCX6d03w17sC8tXFqwvZECbnLSQ3b1OOWmzIGLipqPlEJgMYAxYQSE8e
#r4meL/nFdYMNVvBwQIbJAyM34uXRjHBSQ0aPjM/erkurEGWaBW/QkMRNyDSGLCfpS9ax/Zm8hcDAuqlL3FlxbuhXVH+LDO1gHgzJ
#xD7XEhsfqxP4LSFDhEVL4CXBAO+m3lut5ZfwqdbyfkI6AvUiZo929HWRr0G8E24yHIwtl+LFev3iE/TsBb+6J/Aa6JCRY1hY6VNz
#KT98m4K4oMqpkkAWFrC+2Gn8uTzbVSvMDGkwoxC1wpg0s5X+U/HhIWf7a6JRvew0qFESpCfgFA5N6CqOpyH6kdDPvvpM+xiiJn4Y
#NxtsBNGn3S40cl8HKc0wgMCQRiOJHX95YMVIL0zGZzEC8E7fdwU5PBmBkDldhQjcnaS4wCNMpPgHMiKMMV4KsF3BA9MghYSDRxYX
#Ywl9Am2KAWbm1QbWQIlELQ+WwCJWbMRGEgF08oghm1QkwJcEhUYFalPQplYpkqwgKGTXG4BATyFSOW9CeRSTzCL6oHjR4gyiby8M
#xFdQXrHfLgImyrEcbfIUK3bhLGa4OcXTQObcF86IWIkKpIjsEi4hyO5B8JdLw6rNQA+D/ChkvFB/HaVrolr6w0Rm3hgoOCgqpTmM
#tO75zrOUEl5yzkIhZjBksv5i9UWoVbeGUQxA7M5xVy3UhbphzCevFyn7nBuXeLYRzi6/4+UvTdd1WCkgGHikHjimHnmReTW5Xd+P
#53XB0kvBikM5Sfufo+0V2nYLW3NYwhfxpiirJngEjJIpefK5zWW18FvhFKEfImKbUaeECrXxCL5jGNLfW2nFxGq5Qt26qKGzea0M
#mDTlg2tqJX8B5KjC0uLi+6o9N5bbNqblmpJCn4BGT88LJU2ARIzFCCGKg0RQiUTYySTpXsRh8WzdHEPfO4aJmImpqJ70LLIN2BL4
#n9lfplikETmceCE6iWh3fbRZHzBSzmtfEBzndbhta5WqeHBM5IQcYhmsMs0Mh0lmC4dU/qlZAlAWKUSsNdGCgcx/Z1f1SSJ3f6O5
#mmUgePVPq2Smi2Vmk2VkYZx5HOd0JG+9rn8p3qRJHtF7yt3nHRosDUQhAo1+Lz1rWrIwjBCnNEbWi+ThGzgZNQgZRzVGN/QCSpcX
#A0jntKLTpHPNKVYThtoXI6WSecYWPOnbkd+qqJL+6qYsXGi70TibCyZZ0gG9mArEeUkXi35VC8fZGOE/cfBXCa0W5gMnCw0ECJUV
#niG9NNxAndOrhqg/0f00Wdoc5/N9QUOCArFIRoJC+XUTfED+9yF4/5/mf8J/Ghk62dj/o3U2tbWkNba3MzG1czY1+e8gKNv/GxD0
#f81/srKwsv+P/CczIxvD/89//u/I/81/anoDIP5XXSj+Tx/z/5H/DODCbgDCiXD7LwAUDSKAADIbFRECKrBYJOCTDDqY5L+BoOEi
#/wWCooFHAMAEqGGzdJDaZInN2IHnSzj7YMyIrduBKyoZwsTCDGOAMzDLib/+mZOmENLR8sli2Jh3FgVqqpZUBn4dyL0ZZBQ5MFhc
#+stkp+2dh6QsR+ogv129fGPzG2ATExNjTsOdvIgqw8PpqD0CNl2mbKL2iFF2FBQkMc8GlD1Mk707dR2w73wnFRKo8CShYkROjFk9
#Z33xQ3kjPdWGfkF5Ycl5Ls2K64CM0novZ3t6/H78PPwZ1/rMAufk25NjEDIHqNrQ+1L27JWDtfnd/Xr42vnN+tzVZKJy4BWNjifY
#Ks9KMVVbVI/aK+qT6zcwQhW9i73s/32VcNf97cj2j3FGlnKzDLabsciZ0P348fvbzn0BQrEokQsXc5pErTCSBBmzuAhHTr8Q5qz2
#YQJiSYBt0MSYnEYc5R9Vs2MvAhos3bjO/G3rBQF7P1WD/wnnUObgkCBfyjGBjDv2Frvd1MvOPd2u0ZgoSx9yvynlC+VkcxXuvsaJ
#s8b1P7Xv2Zt7Ue39GG2KvgkVJCLDIhUYqWU93elBnNxXXs5dmd3V0V+lDVvbHbS2OGvemBQRgfkaKZBAFllj8hdx5lZrfWfnkr4E
#L+MpBkDt7zHpzoJBqHPWQO+hqPqTCRh8/a2Q/xbRnRhKaYaU/QJtgELlw6w5DX6KUp5tM+wxWGfl4uDlsr0EdIXhiPhjkAjSjgWQ
#EzpoBIJI4BySoFs2J3aaKKXssVm/VVVYfLbJNe+ofeRErFQ69eRlqK7wAvOcfROtEppomZ1wxmCFAMV8t43B9m784+4ryk/feooG
#FWbSiPYBXtt0fRp0cpAOJAg3WPjbvBubLZSXJlCBSIkXqUaBa/Y6Cwu8cIkREdL0atJHcc37XY4KbWKlqQL50PEpwqYpBM2cgtJS
#bvngK2MMQSRBGwWkfLKvNP36gxEDYgOakhbsHu9yPuywEJGC0+Qrk07J0VbH//sbyPvwCwUA20fCSNQSo4WgIqh+lpB4HILJRwVw
#ekvYHobmDJKUWcRL9ewujlmUjGVMpURZYS2p+vREN707m0z5iTOd3e0S35q/LWNpQ0YtlOPorBYqKqojPTgztYRmvsbVNaW0tdQF
#1ayMx1jriiy0VEHFixGjgP/+c67s/RInI5USlFsrxZt7cAN2gJSiyBGAZ2LQplvezLW5v7NKvyu70XlGEBHCLE2E1fzZ1s5kl5OJ
#JW0TZaPbIUgjuiQyNyEMFqt1/vb04n1l5oOwga2zychU6rPXMTYL0pO8Kk0I98cjMk1o0WP+G0s3mzn6N/e8whGIjPIMxwFiexcP
#oA1gJui2jpiPYAAE8junG0XmP4xDAIvG9Bj6HSJ0MFggIamAbVsAt5gP41Pw+1iAVKLQQTjPMJSPKCZsLCO07QjuOMd77vdWEIYn
#dNcddE0QToCUP0gATwExjWCH4TQoSanbf392JjwpEAjm0uVPEd3DQcEyK7sGQxU0j+tbQgfKfxdXgge/Is8QIzkohw9iPoE4PaR4
#UiyFlA0Esati0NW0FAYhXw5gZgfT/JYCtOkzlk9rHiTVFTjx74rzOqM26rMw6lMM2t5zYO7jiAg/hEIMEw5jDvwow4AHOJo84AGD
#AQ/Mcd0H/oAAnUOy2NX5EOQFnBjrtccrwOAddfDe/1SVBemSkwlHpmn3xe1CRNmlOw5r2sJna69y2TqdRcZKe+jFVnUrknSBR4u3
#yJSPTD6sJVLNZDzik3V3CMlauqN7JnO4bZwXxs53BsT4eDnsksw6UDEzV8XvJfhTD//Klbfmy7UrMwR6wfJxlKtF1fYm5U6ls2N1
#FcopKhRhhrFoyUooRqmjwVAihbHEFrYSwDQ3pfpc2EOjbfIejgCzAZmbgAcfIy0uzSu+sYReNVoKIg4B6BvX52bpzSNjzNNJ2u5U
#avbEJPbYoPIp7p57U26sF5/M1JiqCYbm3vTqtyn/aQP+S1Ecilbc1RQKYpH6lVL62XHdzv9zMAsFweC5bwovpjJBo5T/owwelv/c
#JfpgTleZZKd3WA9X/HwK/3tkoeMxkhoAC0Y00CNznRIfK/RTAUHnxhXoO18e/LUH2Yfsa72hN6bCGDJB3+9fNh2A5xUVxlY4R/eu
#O8DHg65eb4LSUjjoiqEVpGuXj4yKbujrXaGFSZb6PNnxia4iAC+W+GKsmeSESb/3ZvFwCxaFewAZftloB0MN3D9JH2LOROlM8Zya
#SMMbBxxESQaPHXktocKwCAAUxlKR8Sjj1+WwnMUY3qfExoK85PFKf6KaHRAnyqJcu+cC+iGMAY3Seuquprt035Ri5RbfgMQ242IL
#Yr1iA1+Z6Oxyc7bwnVt/HYESaAHChth/gM9FdX8XHNSZleb9mwbbyCH3Bf/aN0QosKTmtkAEzMZhNYC/9BQMg9ZZW4z1Y/dDvP+i
#HK7K6pdE8BB4pqv7lOHUUkyYgq2cAnKeg0BccJ8kkESwA6BNqOazsmHgyoM/2yqNEwOnDL2TtsdGziTw+DzKWq+VJL7wxS3L9KNg
#6Pjdc4UHGBzTly3Etnh3iQfsOpYRXCKyEM7vG63DMmMFA91XjMlCpMY05WliNPIHh1ZMEGQDFd368OjdQEs9/z7ebbm/wQCvg4YB
#DqsUr+rF0nRXrlO3IJAz5wvKWxLTg6ObWxKzMxPJCIwhwjnA39cRAYnXiPZHk1meel3wQZO/gZgAATmnLvIZDsIlFCkYEyPOWCYS
#5PypifMW5P0WNfEOKFRYXoxAMUgBKxb9RTQFKrxZa6GE72FYYWzfV7UMgxUtirSrotkB10QGjmUSj8h9uYpRwxFxwoBFjP2PnPyd
#WAWs0WCo/b4JlTws5m8psRlhEarrM5J39Lj72vnTBlIhaHW99V0KOlqGnc6qIBc/GSfGfzz5XMIeg2IPbydiQB4Lfb3AZcXyZoEz
#/HqsNwIsjWkdXRttzQTabi0YNbGoWDlXxplEiCxXNRlpkX7T65+gVtIqAgfoTidqwKkPTjmuhRKkl8MWK7Ag1oKEGzYMfcfCEqlv
#mnqGw1HJ9QJFJLWmhnq2pNMKkKt2P5NHe5hNJ1KJ1XO/gRQbDMq7QXJ5ByWKZJaPzSEQ6ELI5SYSsiSa3TgRQI9JiXIYwNWUryyp
#ek4UIpFQCkROyB0PVqRiJfgShB6REjjpNFs4U9XKchNhk6xZKsiQ25WoOzdQiUKkgkmq0KghUzjKSbeEoCQi8pyEnh0j3p2sWB4X
#ZCIyg0FegqM5lAsUdCpVYaAkkrKKRlnfCwberxmCs5kZqHZ68zazqKsZtF9/+0ceoHY4ommSK2+n2byrvzQQF5g0wRYX5SfPq2kd
#Vwouf7qW0DZRWMl4PLvI5IiEVENVRELULJYQvXjAFAYnl9p30lQzoCb9ZqwfLem6KXY89+n1k6vpCpjK7pWKk0KajCoiEijTFNNz
#aROsYPXpBi9XKEtNeZUFIKU8SuaF37AmSnXMFMKrKgizGR0WNXDswj+x+WhhGqeQy1mvh0DD78/Yb+3/2TJWFajjdvyZSKIJjt17
#GGdzbh14qm8l4YbGu8L9vPTufMp7+6aL7zzbEpHww1b9IlEijQbI8XYT34bpUs3koOpk/YvaNv4wF89QSa7scyDAvXA6e0nd3fYt
#iFKmldVxWtClQKoFt0H7KLDSMgpVFbQqNHk14sVHxCGdikJqAprW35gFENkfjIaqlCwvzQyWgNVWlBUSchV6NwYDFGsI18tNkOQo
#TNChKU6EfKRAaRudrKgV2lLyF6ftWJaK/w3v7FRLs0JRlCEdWVakqNWYD/DkUhLLJWESpPxAESbllRZhIAsqIYxAUuzC1No8oQEt
#llCGKh2JluTw3onPw9gdJ6WfQqdI9u8RoRAiS6R50FGScQxXiNMeWDUPKWlmk3h4LxdvNfAKd6Ksurrx6fPMFaQ0FKWfKo6Clmty
#cu/JiT87gxk7OEBGkO3djNWXEx7LwP6Hx5OR/nF/MqbvL8EYFU08pYJh93y5/6+II84g7D2OWIMnAFkBBMxq+IAIjAOKA4sDjAON
#A44DjwOQw1JgC/AGrBl/3lBgDJASWAm8GHZcg4J5sBpwY1yQ7jE+Doi+dmkRElnyKnQljzrzGZEYoNADZya0ynEZVWnmeD6Y0WfB
#hxzMoR8U3huCgAbthX74BzNCumwqAEiqfB+gxbp6vZ7OLRGx9tbt378B4FyGARj7t4Svi9lfZKDSiA3JaoQwdxICREkJuK3qfNrN
#Al6ufGKl+Mhm7rI7CmPLH7YlvycZHmgTYvCOcWE+qO76V6Lu9rhE8rTbUpuCR1xVG3sCjOABDCS4ndF6l3c6seA4kKLFBeZo9jyB
#h+GSlWv5mrWDF5yd9t5S1O/j9PAfRBTHa3rxN3qMAGA6931hAMMGU5V1nYMRRGbRWxKq6gyVrfoDE2yLtdqUbGQxtKtfWlhEDiog
#wfv5W618aMhAUWBxRkKLef5atUrObKQ4HjWJDLvPTXGl1SNhQ33MVGWQrakYlZqVjVWzTGIlBkRNRq5da0OTGw6+fPVe/fbh6hHJ
#NSA2+RHkxAotpPQglVsUDHLd45qxnT/hJrKZWO7yTf7WrfJFJuhpJqEMoB+ClIrSDLvQDLMM29iOU03bpJnWLcMyHxssXjEZfFZz
#PBZwCvV7lqOCmmz7meKWZjYEoa/W0NeA3HA+B5UJa+PN51oDghTMqDfjsx6+qIwmsG0oVrPo239OSwXMQnl8zT11nxHodtohztch
#NZoar7wFURvBd6srovy+bU3zJ2eW5tdzYbH4VkA7dgeJiw6ns+rh6diOxfsqwOx8gaLC017/yloPJ7XjKXCkkRUdjZplA4geiCLj
#E4nR9WiI5GKJQVCeR+1AIMbCYIbJy44m9DGwyvuIGWKiU8H5C4z+3hubgbC7fF1cNT0oN2d/aXfREG/v1NnRT82NVOU93CDtTjxr
#D5Fmr+SZ7XC1uCDIP27urION4/u8CGGvgIPTiZwm4uOJEsnAkVgzUubR4hoNBO+c3+RWIKiZ6Yv0UDB8ROoHaVB58v8ighOGTZTd
#7hoXqapUtYxrXFe3DI4oNDOzMDJMu7yialpR72C7VHrYu+l+ponnP4mw8pGzwrydbkfOB+OweTGp7oIqLeMkryci3goxyycgonWV
#3/CC6jPrmXXxj/41fhplw3RLvtWGVC+AjXU5Yga42sv9RQo81QDohI4EEUShxOdZ+X/gtS6ORmLLOVPZJFEdD/o03ODibLm7J0Va
#MZhBtFSciirrFCbG70J7ArIL4dmL+QjFBCSwOnZC7tL/I/po/ui4GnKeTHe3/bcrjxaSbeZZ6NyTGmZ9GWABWmbuVNEP5Id5mPzU
#B/6m+p+v2ECOA4jdqzD3xY0RCzs0KA5wMQxWnZWZf6EZHCi2RoJLqLqXh8yQ1QdxtL6QOGtaleTadctWbBEp31Gr3OC52o+lCc8W
#HmOSNCU8qaq5Us7AtY7KgE0tUPyiaVQjHECoEHP4QqFJe9VcLcAm1Lqb84IjwO67NYG8pn9iDyjz/fjTB7j3Z9+g/LZG1cPfYq5V
#26oDAMIBwrGlG0/eNFlzYjiVAN407J4VZMd56Xfn47LlSI7zoFFDxoq1RnghPdeD8UkAyj1SfExNv7RomtOgg1FS3FpspwFSC7ZL
#KlRsUYbrPKqNjvSfreeFe+OCsaVcQ+XNL48qNcQP2Pjwh8d9kaa8234V74Vn8TBvn0ccSE/WddrS1CsGtNfzGMf7cJAjj4XUb6es
#86/fdwXuyNABwuEBUpJDQUHJUnQuARlTneyWJ93Dc1K6nGBASORBlUywmkPykFRqVS0zVqn4siCqttPS3l9Hs/Fk6kEmlxAMy6Q+
#ITL6sKZf3289AVqdteu8kZqugzU1x3THMV5uZM1nGSEgu80JMl/uYniUiuO9oVLDdhPs8mU9IFdljLu3aqTFb6/qHZielRvvdo2H
#LDwOa65Xcf8KdPS2T8n3+4RTq/QPT0xC3r4YkV4VJp81WdiY9kFO4hIPDFQ9Pv7ESiVeqXo9EGgBF5pZnVxnJBghcMql1GnjBq3C
#bSw/Q0J1JPZwp71MVxcqNmXWdsvk7WBjYmgr/2wcaY3chqs7HuHfr4TXVKcVsFFqfEYiOQl4qtZ6vSD4b49kw/vKF1ul2boC36sa
#B1Lnz5Zyq2Td7NKO7pmF42vDv9fa8WJ+t2fnFCHGijEvpf07mOj43TXw+Zf9e6asK/xFEBkkQVZb2MX8CsKH/YipGjvbmWMlxjZ3
#TPpCDKcrPQkLla5yko3yUWBb/9RhS8EICwFGo7VXys3n5TQcVSks6yXwqsDGOsSA7FmpIwV/W1aZpQfrQCXVF2WqG2EhCeWiv/ps
#rx7BhvVHw6Vh25dCtS4Sv2dS9vjyGY3qfCErz90i6mGBmeVEZATbKonNaAktSCpTU+vggg1DWHoRlrmB2dOURI3ypROX102M5XZz
#Niv/g2iiIZV4Ek0hHxRijS+lGrEzS+ipAY7+R6aONiQUIqvlrjyZcpvkWfDwRGqE0dVqFxwswbeH0jaxar4mHrJBma7Yj5TiPoPk
#FLB64k8lrnbSxCWA0v2g8FbU8IIc92I8OpFmpRozGfxmFcIgvIBqjLM13bwRtxp4jMvxdcCIAto/1zMmKxtSci2yDEbVG8uHEv9i
#t2jTFnLZoZNx1OhYwgxkhfBU870TJZi0Xa+cn4XFyaz5NEN3fzDWDklKYqxkiCDANIEU5F5XZgZa1ojwndx03brsQ5FV1+4rTHk4
#2CHpyAIRymgn3otqBInLp+lBEjLyU7LtcMH5xDyGroBsnPFvavq9tUA0ZrM87PhUiHEJFBNSwGMSxPVEkMdEGKhEoMhEKKnE1i5J
#yMHu5Kq6Lj2FRO9/mCpqrVCtWrl9N1vaGWd/MQqnIGdm1hVZucreBw62HKjZVHKwYwOOjhixYUdHy45Y78uEqYpVt8YGpUKka7or
#tVIsiw9yx2Ke0RYdi5M/MYvkDAIS4CSzU+d6fGnYYwP+ejDHDnuO27TDvhmkWbbf1K7zGJ+l3r/74e72LnfpyCaBxj5skmxFLNay
#0zkAALFqpnxxNqsz7JPBGqP9zyAFQCkVlFNXU1eumRGiEoEDyw3OZpEdYRQpssV0SZ/Zu3mllLgH8DPz3GwdvmZsXieauT0EjGMu
#+KjGZEQRNodaa/NPRcuS/U6ZgtxTHFKqiJNyEotg/Ngao49efjSf1VmkutN0Fdh24q6EK8XEi6vMk5dNPDAeLlaVxFQuQpIN1IFp
#FizDQw5nVHnRQAdUIc2OuxCuLcUNSLDsGPWHQi6QjwjhxSiKXVDrKFFgEgXQUVzZaBcLzXcaA/nE85SoJIRTT781VxiuuatAtYht
#BmOhsjQFBMRlK0n0DTSrwXScMkwjg+U4aitnvBhY/YkS6tqRZe5367vI+yvYeHBOOjewIewDlEgwBIvUZSfsM62eNNYZXmxPPIuv
#1872WTMR/1YmU31L5iZEa2md5emcqdgx9NmZZoYbKapM5GHojNKHShX9c8NZrK3Ye1dIfDBKpqtm+0xWvQYTrDlz+YnAIEZv9xmv
#S9JMdzWqXbRYEXVuRk+dBZ6toVlz1FYriad93Y2n3TyqxO9WT4V2JTuY2yqAma+RTpKbu9r59AceRNKtQUg3VaoCGm8xZxTx4qrZ
#rwOQSWOSMnbZQHjSL3TBsx8tSstC/c2bxtDxgBGeLkvzSfeB2X3WgUfF7T7bSfeR227KPjla50ZF8thBvA1L6bn3o+umn12F+9nN
#uuxlD8f7sJV99pDug7ZuxZmQfJ2W5mgB+9p3fE1H3e7d+hTRodzSGEPNuZeOmkC8eae8CJ5YuSf4yCew+hInUZnYJzPQT7o+TNzG
#Akdy0Mg0oxK7NbfT6FKDo0oOjDTbNXoJtBJMamQezVCTUatjoVZFQK2LAl2hC18kV0NJ5JE7m6Z/tvKUlwebGEAf2SVHQg5Pzbp/
#St9kBBvfuyM+7wibAQ3bukBN+PLZ/KeBrf+M6y/+9Ttwl/8NvPYJemCo+e1TjMcjM7mJdTfisGyhqfZI1Dc3s3w4LLjtCbSSg3m4
#ZY5UHtVkqZGa0PSMbBnFcPEKRk4sBX93srUm3cAvrY+hwMEw95LxKZHVDDczag5mpS8Lo7ZFDTQTe7BasoJtcJlqDEarNtk3ncWZ
#1y88nguhnMoA6tPtjjsy2KMh600CETeKKLxTknkGxGfMgBhpMqqKRFuHUcyZCFWcmUJNz78AxSlFJCeDFiaqFO62f/4Qrt6qKJux
#oUrvj9CL6aUBXFnWJ8scq5C/WMYKU8pOeUR4p0jaJqYUJNeakiboZq6CadImL5qokQow9HMSiF/hh9t2KcGCuAcTAaT7X+K6tf+k
#sU86KnPgpZ6IXEMtMZ7SWRcPy1mVkVZVh0OgYOoH2itDpdvwWUPGDoy5RRKMyGj5IwpiEBI57PA4yzmEoIAi9uNNXlBLX2sFTQTs
#Q0qCfEb3c3LkXIE4Z9PChAcaYkNGlPCRSVUUkbk/h3DqG2Z9hU0WFTIGnkCWDBMt9qPAhAQP2PzukUSAaOpPysSjMTCCRIRiAMd1
#9iIJJkRfx1xKWM19DU6JQav7NKdBoCx5MIA6DjNWyL9B33G4j2F3AW/gCdTQUzXBRcEwg+jFyOhH1RUYsdtEOzLULwqg18Wyjj2O
#5Z8W5XZDElogSorkBXNzFD+6fj7iLEheJDoN2o8A0dUrxF61FHkMAzt6f7IEXUcjWRmG2xjFXYKTcYt6dRVw38UPrr+9hy7sCBK+
#64Q7DbiDMORDRAKnXyhowwjUkA9FI8Tm4ptTG+wDjhbucwiBEPTlPDLxhE4wSDRnbLNlkYp/BwDVk75WWEDeLUjdE0LGfjiVdEZJ
#LKfDyoH1IYC4v2/OrjtHh3U7XO8QIRa2gTIb/1FBISOOX7YxviZdiTV5aeD8DBLOixX3KjltP+jjkNKcVn3dPwI5ZdPzIPDiQhtW
#U7ipRUO0ub6CD6jaXWyyIxIxf/E7ZOiaABAzHlO66S8g1fGoVY5D4toK6+AUhMD+zTyVCRnkehGKFuwTMYQLRo0jsXSIVw/E9lXZ
#hksQ9iuD5EQkdMsLWOCYMHvzR1Eh+sLwI6o4Avxj5AgPUqetJaJ3wngWDz67neIDGXx2MU5MDXdiM1QAx0pInwCzQUfw8mHQTlX3
#XYMwZpTIgUssM8ISuZ0iK9j8MC38DJb7x+sArkLwixlzABCKUAxH0nqxz5rGTFXt32CCvzrjzscdsJJllDI+4Y2AnHdsdqJBYhT1
#ICAkXY/pm17B+fQRnT07TYDDi/ZthRG156nKbZqzC0nKCoGIf6NGKW7Q2VBUNLCJ7bAjZeWWV8YjD1XDSDlyo8ux7C8iTU9UuHe7
#bW91ILI4HglBvge1tBjwGojboZcP4DYxaubSNwDEYzHOJicZTbfKZBWLYJF6vJGw040YujwM1ya8spOuZ0W1IIrcOob49Q1UGXLn
#ECfYFQjTT6Epd1lIbcWtQ+wv2TimclFK8BudtL8am3wYnKoTC6g4PbUQqJDNbSk++WfJ2KLuHBhd9AntgoM/49CEjBRGwODVw2zj
#rXtlD5UU3etE9cDNuBX5bVRAM5GPi2npn4vWrTH4yOeuEQW3A1rsV2IgWjyKXlzE5Y0iNBNhi9GoV0G2O0cmlWup6raC12tMWEQh
#65OemlnAB6SorMNpv8rmuVcqyY0dSTf7MMIXPm8CV5OeU//Lovj0ESit+AVRBWoXTdWabqKy1TERH01Z0x1QUOhNti0SIaCuMHuS
#oCLXs9sry2fYaSXS0+67u9rWmKT9oxpF4Y9jB6KrC+CuZFMhANP91vtywgwO7Hj/qFEW12NtF7nnQHg4GKxqs0HXqvlCfS319nNx
#JCMBzfV1pxPwbvnjJae4Z1vV9Dtvfzm+1TCEEogxzgPv7Gt2ZuRjsxTYy5bgVbD0DTgrcx0NyBCTwpTPiuj3oT63hnYBVyIW3KXI
#GjDwtQRpeL95OPijrq/+WzAy3PP8KiadX0hNnaF8JVIeN5xCZwUDWmOVkUqh3GUNXFvFMb7OKwq270QUtAdXXXO813JLbm01bru0
#SJuBlHdfk6swfkWKcymHCgPiYYc8/NLlBaB3mFg5M7m+y/wlY7XKauNv4zqfu5U6WZc59x6hK0NRukQfqwv+gnt+6dFpsH2HRYoI
#pXEEcgGuhtcS+sxAdKvb2EBV+KNoyVtYRA4nWH8Ca8HYu62ihJ1J1DbcdZrf3BmtEnTejS1vfqgh3TA7p0WNUaqJiOAksvafWWdp
#tY91XLI8noGxaj6unBAbwtnHYgoQozH/evPTP8B17cx/1JdR+wiHJDki65XINU5xE1fT9k1LhYUOf0PBuQiC0yRJmqxz870M26NC
#s9yqfAqCLK6USLjXATbUro784N46CnMu4LnzzAfT40Yw2KOhbkKLzYRqLMG3pc4JHnTPrbfrYVjjk7jdkdK5fL4mUK27UFNOHReC
#6NtdDlKNIq8VJcPG7qFE3qSqfmteSbxtpBO5irWnm6Ou5pRAKn6Ubdta2MV5oM60h74nzJwDyVnLZwlwZMVssdul/eHUFiIE1cTD
#A0gsDv4JCvi0tAX6ILGk1W/HAEkzZzvZ8FeMBxvjhHaYyV/fruNQlw+o/PoVF0aosrbrm5Yqc8WzIIW8d/Yc0h6kjXsznkwgj2e/
#ApaLYqE9CHIuyViE+QvEeiY2TsJxCHS8VD5jYEnuYIGjcxmqySnYYawtAQiX4aFubHVW+pMHb/ukfqAkSYjALTzRvAR/qdqA46ut
#tjNaVUcAAKOdUbYBd8/aoFwO1e9f9AbcA5yFVEf+lM46k/OAnhgdNE0cnbAXaxBC0Fa2IMskQ1D3hFw5Fcg04rOHaSNmOVLSkUrp
#g/IqxqQpDUu4P/f7FHqQN8QerufNP7/0RLCB0At8t/YtucZWudiKoeaAEj4cM969T7cg1DZ2uBy3nPF7Uk8FFHpMPnFoEyoe4KIv
#gBLfRIBlpDxwuh12SSNCBElqeltGQHscUvr67y5D9WEWOHr95/psOe27ZBdSKcJpjFMQBRQiNsPOPILn1GaBL5+lmsYYx+Vv/WXf
#gARswAq3/U+frFwSVhodF0Gxzeg5St+04k3j8Ac6XrcGNU3zoBecZibAdLAOG10+EL0yUivldPeT565y1UJbPkVQQjUFlR3YEjIh
#shx7JF1ntiVxNvm+hqouX/VbvBrl22w+6EipRa8gvaIw1CZMmy/CZ3UWh7LHnJCuUBqnJf6NP0L4sX4jxcv3RGi/FJopdl4DFrbY
#JcE3pwfymsYB2cNKkG8TmK/wTzwmwo4I9oB6254Pz3knxs4pQoomJiIHgqan/KrAHo6ubcAqRcxpH86Oivqahp1C86eirRZwsmYh
#l1sRqkRymTTz1ld0OovLbCmWygTMnUp/jd+OgLSDKWn9YE0ve0mKZ2acv4d6NaIqh6rrrGXIUZYcJa2Q/+SjtuVbDOHfk8l1JQ6G
#4hCXTWmD2iInmT0s/75qDJEvrSs/OAH2moiBgiFdHYIxU01Tif47+oQo0aMIAXaccScZu9xJt8ZNxEdevBbB3VPUYlzL+ct8aQJF
#FNuW60c8eUz/gWDaQZW8AjqBoV7XPRYGUYX8VX6Saxk97iFIhVqRUsnMmZ885ATL6HY1zlI3PQ7WC6adCBGgLEMsnGPHZqNYPBYD
#0G0mJLs2Wm/F+uBWGBHfds6WyFT5EGZHk8sV36x7VqUFPMFBwfAa5GmVj5YBaCNvV3lkyKuB8rHDYKtGH2xxTOeq3OjwZcY6VpUa
#l7yWdC9QIw0cis6Gqk4gNT341LRJAmTBqCGIur3wFmdKsdinZGK3LHu2c5gLU2OUth/Wm3/qBl77VLHZhxk7/BKqHCV5pbXasBQN
#CiKCx/Go1EOiJSZY1/iGEZwsQo1dK3OBMkbSrSp11xifNrBmSqtM3SoYkfFVR3CvZpJhILniJDW1mmJXqSmQTdlhW2PxlkWj+oyj
#ViHTjFIDZooRLb5p+UXhQGWE4o3CiXEJ1kjZNJSs137r8BHqLHXkX+KamOIUw9VA0xVnP5QtSlAdvTRsPDu4Be8MYv68r59LUskr
#hRDjQ4zwWsD17RUz/pLmfjEhHROr35qxcp78+ZnUjevYzkbIFdMJ+410lCZgv+b8Rl3bwzg7yL50r7vtlrfewps3uRwiMsJ+vFbK
#rZQIz62DaYfe4F3l4ekus3QFt/3xyU71QMto6VPma6UHMMI3EwwqTHnGDWYndFKVH5myjydC0MbDRxWGKT9oEUkgSjoS9OU5e5VR
#ohuQCZADrL+xP0ACVAZJO5yO1AW04wgfAF5YxzkMd2IpKIppUmjewXZpIiSdKTUAIcapTVXlT0XGzoobfbF8616o3jmmrfVVjLUD
#TUSs+jWAOqAF7QAs6W7iqiw/GGP1RDzYPhjAzi52c/PGpl5BeX1riSyePFZTa3t5PnqzAA1alUmPoZ2iEZWmupGECYNmLqIAwHrK
#q9goz+oc/13C+5PGHq/O1Pk97XxTc5FfF1096APjnU1hlBKC7GRVxWQlfvTa+tA92Mysd4nzazRJ5nePX07dc6kguuTV8XHGYCcL
#gL4VXo4ZuOiPGkDkKgkYRCygb8svd6mSz+b9HwDEaZBBDzuARFKznNRLli3Bo7/a7KR5Ck/7YvZ0NQQezg+sY1eHp6Nla7gk9eW6
#frFrRrUtXcyVuQvnUhbVTFp5Up2+utG6P9a8sXXhFoIXtHI9FN+f2mvpWawbOFruXsaCUZT7NBO58KnrY7Se0Uf23njQ6qIZbAmQ
#x1Hgp78ce+1fb2hF26duBumGZXW/VA4sosnxdjI4Jm+z1FQLENTzIRJdSCyCxAkfK6jZFpHOJG9FvUi2+8Jx559W2kRuOloz29XZ
#G1m006f8BgKd0RX/hOABu4zwrbauozSdvpt039JogpzYCXZcVGkiXO0SbvjPDLnT5Sbdkv1iF+0qHfzej7A2yNsqpXZa1p1g8JXn
#wjOljBGXqchbFsm6bzP+jHglnFRtY6LQhgbdgkQc6BtsgsH3X/8l95aXRSXh4yOCQ9AtLPgmz3zP8WvRS5lBuvNiJrGvblAuU4+W
#1Ix5EEday6hyekjsqxSmYuy4OArI7I43nYnJ1eApGPTqRWJ7fSxYFGe1MXYBz65OwtmFlyJs51y+n8PONtGQz8i/tUwZC20PzEyr
#QRxoQANuOHzLY2Zfj/HwENcfgG2g/L2dWsvkADWDZ+wb45ZUY0Car/wx91mCUNWLTcB2SIGuvS+VspXFk4MxpCFANih2k3rWFYCi
#gGsvotk3nuWb+s6ltpggz518xRZP18824TYlXuH+EKx5NzR+ZxYjUlrT3EW3JHLz2GyYpYRYdqwBZ4Bn62vSct2luw45aexq2Fi9
#MvIX3MkFPYYUiJQQdNED9cpojeVdBuadU8miVDNzO8cjnRu4olYJ1faZJJjKbk/hkhJLOfvNn9lm/TihOzyAQ3YLz362fok8pZ+8
#1NGAD7qv8rgGcGmpV0N8v7juK0CUJgdVGBZ3bV5WSOZ0SxHeszW7MLNfJSguZhe72swN2t7K3bTWc4NH7VnlxZczBLUjdP9Lttwz
#Zm0mV234p4yJgSxPJgFLd6doJSwFnBgFis+zsZL5jJxwn2vnCpfnJykxcNp/NXBiJ+fmTBvr5m7Fys9+iw52Oe4A1S9d6ZWYmFAj
#AqGRGaUbTvJ8DOV5RKoy6gj5qXa07xJyU/1IOjefT9ZWqMtisFhsq6+/f65B0dfAjDyo4WuwJJtGAPfH2CYjBf6hG4AAgC3ww0bb
#FT1OzAB6OTpklwh6mjLWQ8gRuZetWgAgk6JSA7f+twaRbmCYWOGh0kKN5SpYkBMvqj8tMPrdKSOFgPFZlGqTIV6xJG0g7reT2fpb
#9/6ktZ9bQsE1lY91sgbwAJo8b4oJ7xRQE/J97Pp6QP7y1GjQo8NZeXS0tPzTcGFDtQbcYxAPC5+8n3jBTi4BKYG4zHJePOjCZk/6
#YWbvpzJRuhz2iWLLBAMev5Ej4X1tZHg3dXywqEwU0UGSXCEDZSdhZCOHRXZ9G4pHu3SpOJSm/Ue3ZpuYZmw7W3nhWcBxi5vf9n5K
#n0yGm6qDi7G/J1pGoIfGfJxgTM8nKARfhachFjaFoRk8AYIfX9D4TE6bQdDD3HKeD5ADsagpIzjELnHHXHsFfdOEs+b3j8RCXaRN
#V1Chaa+EekR4US/DCPppY0srGBWZPgx77to0p9ldwmjmaycFLi9M4b0fqeJqPQMgS/EoRQervLGSOFOwgRn82Wo0khIGHwTXmBtR
#hai3N0QHCxqgldVO9uiRbsMyf8yWiGhRoAKGCV+sFzURNwUzEdfOs49wPApZsaZgQlrTOEYqr2zD2OBcgtdN54ht3RD+wAD1oOek
#Dcof9IDe/gCQAGzySOPPACgMAFrx6oSQIiB2SmMhvyONO/9YNAFIqLz7AB92Tl42osTPzHZzkRSNqq+wVQ/8YjHjE5IePTOJJfJb
#Ot0gh7Sxh36i1imS6Vm55iNxiRZiNXJGzuN0kSLW1J4Rl0WoFGGvtk6U+GlSfsR1Y9Nm+sAwOaWBVz316xTWqVEQiQ50CE+J+894
#EkUrZ2h8zIAS99felWAOlihXoRCQw1DNTIu8nkkOLseAP0YezExxK3B7MuqaB49RPDoAy4QFKLxmLsDE4IWCTJrcnNurqMWGPDIu
#j9tQwnURz5TctufK6XLS4c1glIgrMinaQU8yS4wuhqzUe4+4e9j5p3wtnwiSfxQE3pi14YQt8yQ2TklPmDP+2Cla0MWdaPyVvl50
#ttb2UBr0l7E+8Jeg+V+G6i/IDP2u7IV354Zw5RdaXym/VrWd01e3/FVoWzhTiVJ+XB807HGRcJpSYAkKdkODKXyGrJEiZHfRhxOp
#9WCYC3YtI+zeNCPrc/92X4QpzrScvrJcGWh+IqrOpSo0B1QCnHbv9H9WN/GwHrsU0tifOpefqN5q/4oVSBx6jWF1Ez3INg6x9aQt
#H49L5lMNBoq1Vi6hmrW8lZJG1nRklwkCbisd0A/JrSqzqn1lrJ5Yhz8vMXoPqNCiAAH0Tz9kHl79lzQPRvVysV3zCZ+P4G8+/NyS
#TUABrkHzNfb5qCp9epdPdAjXO5jyj/Lneefv6JOpkWbh3uQ9eLI27LpefonOeJ/bODmWX9ybuXaF4JdXPH9ccYiP+Z0ZlvbcP8CF
#cO5XRi92D4Yw1FR7hEl0kLt0GtRIuLQYcd5r8NztFw4nUQNzkPH2IBdiQ4Av9CWKI9D3vPtyGnbi2u/Ns9Ge9nLAOHii8nJM+H5Y
#styynrJD9zydrQ0Rx04iZP13LUB3TmMafLKgbyWG4dFRqvlblrKy+h8EuPSU93SPyMP6jFcBgfq7Y5AeEoFuTX+M9zpG7DG/RVyN
#N2iBuuWfY1tbYN7isRYFSWPXrDMnucW+viIBAAf9ARKvStSm9KeA/QH0BPyNPvxYPp+sTsjP/7EHkWQ9HjMsfad5HfjMZiOeYsqW
#T6pUgPQ7rOxoMeM4kNkAMRsWjulqJTBZy6lAFOAIptRx6uUM3mwsw0ydYLOaHhRdRswRgjWBK6qHEWBEqlnG4zmF2h0qszbVOXR5
#HpwxGBvFfeLAU/YFzVVLPqpy9QCKOzNzKrdJWDv6CN6AR1m/Tydnr1lkvKcOZbyTpc1eG21asU+eRMQIFqehSXkLFwQH3UMuSdSb
#NcmoNXkQByt8VaOqNKbf/nSdJRTE7AmN64XTq93FrOQYgkdsgl3PjsOef6+MqKqQ5tCRCfDSukuPpwrJRw++x5Off14EeL2dCrV5
#Gm9mEWfsauOSvG/ACtDq5K9u+8ZMuzhEMr1458+lrq6CbVJsB27B94MtEFP1FkNfvRzmo6uuRYWtmF8u3yno5nkrc2dfcjXhvrBE
#kd8E8eC27cE8gSlS4E+z5NyhQfyZBXYvZmqZokaQFqo0pD8S7lzdyQvIO/eNr5by6rpGjvbwIK+xF2EEPQXzFoRRurmKtRSXzKUD
#7qPsUh3nOoaI3WUjvjsuW7ylYe89joLLA2AFN8YVhI4xVu3ppPa4UuqD+AuWH17EHDFD3BML005g5TAux2mnNVe21EQ5RmE+aaD9
#k24JIjb3QV7zGTFKm7RJpebknLROuknpi2867H6c9Stpvr0FYOLaNLPDxrW0Xnv/XHNv1t3JqfqH7cR6qROknVe1apsuxgXw19Ki
#KLMxAYRiqORgopYW4FeSBv3jKuF5SUHL0c7Eyi/CsdyG8vimcqj52BWHFhnjwpbMWmTRs5Jvgf+2+ibUB/uG2rnTYKBcQb+Jbe5B
#7EGjBh2lamG1R0Wj12lRirV1V2/6xICRfpsJEG/jOyz/JwCPk849e1+zTe1s7/X4dvEGukaA1bhELw+Nx+krh1d5OQ+I2kRN3WmN
#qym14WkSPN0BynTWQrTdGHJzARUstKOq2XsKAzVoJfoeshBSIxqYQczLtNE/byR40Ilrhd8PS6b4B/otHFmFMCmGPFIC6SX37Mc5
#m4iteQvnN76nVTDzMwEXNWwgrqzrJw6TdMYj3KtP4qPJCczUaG1T6/lP8EyrwlPKrGHyDSsZOkPOXGxDguCukz2NC9QfCiEKKaeY
#0tztdwnF/JgPUYH44l21cupUpo2Dt9ZtzKZn5HY2xGFJWTOGbY79CBarqkau5xRc/fw7ukwGIxnYhzC5t3eEFl9WLzGSvhrm8bFm
#y02WokV9i1FvJdOy5fGyEyEOfdOS87xUSwqZmSszJsSIwz1hwsPVMOMiMQT7Zr0YNY4Wi45qRqN8OYdFG2roaeqVmPjheT8hYbW1
#xvY+rQ6o3OXYctO2n0LjtZgTO/AnH0zzozzMLwc1sbvA1MDF1kmu+E2yV93TG3wsM7G8YYEz8FXzTUb+hHMGnWmHV/VAQp8FWT8z
#L2AVLCS3JEs0MIyM7bI6DhRnw9YIYLpOiqnO8qqkWf6guuTq/OXqVcOC/xaH3uu2hldJfjEJEt4fzvqrc8gw0T0xRiKnjqD8QjC1
#jV4Jl7Cysef2e3rKRhvTy71IwMVBskhnk91FgMLbmm7A7T2fCWbcz02CLWwjV1OIR3PiUUTfcGvZmemHN0EjuHzy8VYlPjUiIdZk
#yMCL5wf6FjXi0OvEAsKUHs4di6qJ52eIaCR0IEZoobQAr4WH00WChGtd8dVAeJfWnu6FU0VSuza/0m5HNuJsAk68vWnmoPa8fqY1
#LZUr5TcTS2CyLVW2zpqNIzum8+Uu2czPHAbfg7EO6qNQ4n0wlY1H7+hYwtjtIMXWx1vv7zXI+jgwpgsNFRX2dpM8dW+YNmQCN5Q8
#S4wrMYYZ69qU0n+bH4optwHfvnp6+N/G8xTzN2+Ce3D59KPtSjIuf5+3Y55QJpbdp5Uw0cu2KHaIe+LpE+cct++MXN+cY28tM7xf
#xL+YNynfXeNvo9qkD6w3w05ghP0AJK1bi+hLTnFDppHxybZmIiAMiwDtFdoseukn9uPT29mpRA3uuBtnDdv2KauNeE1EQ2dCjfzT
#3O/lcV8RGj2v4/TZ+6FOG74oU7OGYE533K53rTIFHs/C9AQ2pUbCdRbDj5so9k/LKOoD4MER2GdPe5XLi1MbjGSZmHaxVU5ei1Ul
#8O0+SEzVlc+cSMupyNU+aAEQAHp49znJ1CRPsJHIXgjM3V3TAmWEUtQD64VMm4OgGm+95+D898BuN0+UPIsirbmpIQAXIbFXpob9
#U+iBaWXPnyh6evYLO5wZ2kwyrxy2pq0IJl088DMagzObceeyXFQhqu9TKRd9R8MtPcFW7svDhymj2+vqyPIl5HHs2FMlbUAOnSAp
#uc27wzvNf29MTmOHVsN4Hl+w1wc72O8f0LPdBYq6nlYxyg+XvPBH7+MNNd3fN2vwXhVzuvo1O/ZTDQkjtBCFgtYc2VgqIyaV7NIW
#I6ddGRugo3ZsZdo68TkF6ENEGzvlEXpaLqhDsqrxfBRtecqiTzr7WcR2AK6bbbvYyhd2PJumCxdMvobtQL7ZgT1DId/vkAFZDwxu
#mv2dV4jYSlLMDmfgyqOm5YnVh28IajzK5h76M82QHDu9WUYHa4NyyOyuvF8Q8V9k+JIm58+XFqWqzI+ogPHS5yfTxXPyn0btCtH8
#hNk13G8oqCu++ENCKlhp0iJ/zvI5vC0m0d4F06SqvTTqv/kuBo1KCOegmnDKytRaqzwCy1dy7L6/XczJNqVm3ZXVZdFfzKAR5mX9
#75WZncTPHtpsC6SnBvNGi2/lmkL6dGg4WvL+dOPjtWPRKJms4yUK1lkMOPZCDYHZ+TagenENMQpn4rrgusWASsQxOhDLkCwyFvb2
#Vp1hZIJSabXhuGT+aVCNZ0DrzX1/0IHKgrdiwSlEDSKc8EDuz12WqQC7HF50CcS1pAazr7RBxbH2fO2Mo5daVs9CigR3PUN6EtCs
#0o5rjIRgoggtKwFt+IVOZl2w0Gk72mwN37A0JsKZloIdVIYdXQa9J61UvQLsZJTt71kzSFR+rzKBknVct7rt+0SuNkmUB70va1J3
#VrG8Pgr75rKIEWnSdZzEYnmJ+g5qLkwpww8qU5gLG0C/HRMH4cJNv8pnoj/mWkoBJpfFE9QtD/VPWhdTl8byshHf4wNldZl3qXrO
#WidXkPVM+igc7aj+aYAWyot+wFE1GipU26OpRFzvy0ETvzIEcSa8Qhvo2k2va6taopnxUNCQnvtgiWyFJvP8FuNPvAVi9zI5B5Ks
#TZbi0D39wM/g8aXfvEuQLMPY8FGePFtYT/zRYD0yebGHT5YHOel6dQBmiZYSQA2uN1Ml/duiTS8Zzf6sPWlClvbHhv29DZX80huF
#kwHy9GFFZ1ACM8Zut8bKgGXOI1gJ3zeO/jwjRmyMmtFlAk1th/McBvNMiSjju9T9SfWwfB17c0XgFObwcZdVsXov/Sb816DHBAL4
#EGJr9Bila2BDUQsqM35HX4ZztRYWV48H3bVxftOYsz8EkGy0XpbPYGNPrhlHsirdUyDCLVMMADJLSLdxb5ptTsNIv5aMnTMpJ2Z/
#1sBLFo2Va1Oh8to/njjsye48pGBHrPvS7nYzFjJh6Xgczo/044G8BdGftVQ2kaPOjwHiDD5TxIWLY0FiLvrlrbzjLnJQVoAPxqoN
#WJ5DHSYBv77WijN7eQYtCxfqnjCfYMS6FWeOpxmn0+4ABCk+LQ/H+wpRVcFw5SJmXArKZ4NJWDgyq88rxIRQRwZQBQQwc6YN37Vs
#AP2iVsa3oqxOKjwtOZvxbzawqzSI89sp8L1L0IKTEiPI5wuMnnMSpkD+jUlGJrcY59LwMG0qrarOQQg/BsDQhVVwXVEqSamCAHAS
#/sBl4UcEGdy4CjbWBM6UvE3kGigtgSGKp4MlbCYyDG3E/d5iPbkgIdK7m/Xh+uRKOArtZNSYjlq+Ih/FuJL18sVlwT3wAAyAt1ty
#FPCB4F74DFOtuNKLslDo2QD1FU1JsE3c3LQo62NsA8laWCeSBKZeLsjrpbW1qGnfYhoqyYI+lkwZc1k/3vh3Fw9527WelwdL2WIO
#r3zhAzYCak6ny8sOo+qMWBbap4kVKRKBDVIby85iUKDNw8RCubQh3hIIIrZyLhVgVF8i6IBCLE5heYKVwgUHeZGGXzsHYXjT+xbq
#L3VotWp/ipaLaDApqwp644d4mZd7q67FE6HYquVCa/FtRjoxwwgvlY5MwwahCK64IAMKtMViQiG9I7lBwjhyrclOdrqOn91zUEwf
#gq4bAUna31Ql+kWr4xpWL2sjVjNIk7RsH+vEgsXJYmqPu0XjJiYVyTRJSSUL//JcV7LcVJVJc7/+yGxntfgUMXWXdPINXV1gRBzA
#ySgp2DtuhNyIW3x+lNtrRJqWxEEhllIVk/lhNQrjPhqR7oRMf6NHnsALqyqxVhey3KvjneMd2mEXuhkZ809wEgRVuq0ENLT6qJA8
#y1sERrIZnY77JuSui/q8P2hVS7t5PTxCfkVTf3Uuc7u/6gP7WYINWIJLNGQ1/z0ZGOeg2+8QHmDxAsURLa8k1q9aSxWSpZV5dAVD
#Z233B/sc3OjfqNrYL04nS1yCbwn5Eq6pUYxc5wgJ5uS/73m0V9wD96A4T6NJ9ym89bL3yED2oOHTPAjwPds+0lxXGLrMyXfIioQV
#CX3tS+POFFNt7nwYKeEEHlIB/h2tif3tfd2F9v2MVzohTuOxqxSA+bSrWceUaUsWVB911jlnkqjo4CBNsPw21bBpZZS8HedDIK1h
#a0eTFnCliPLqObZrPEsqDf7cH8COjJzpRAaRbZpYXxkWdr3Mm0AvVCVEuCCzOV29jAZRCxekRGhYcJIhRaCaG2nyJBB/9yOFLtiG
#zoTWiD3X505gGTcQzHKwm2c3hTWFTpWMEgr4M6Ips0fkznmwmTKxb+CcqkzatKVBEMNlxWyvXF8WqxfcW6pCbZcpWM+C1C4SCbkU
#/+OLPiVZgGoPU3ckpAJgE/j2gYZnsTjz0Z/nRJcAHBerZYy3lnj1MaAGjNzfUigOAUsHX9HaXcDxngq1mN6f48IfohBXtzQmaC3J
#CxrEFy6XWGKN2dTmYBhZQNq+d5OogsWG2VSQqFoLk8d4DB2i1BShUp/27VBhjNv2de8krHssxcoIOZBeO5aTBX/sZjd/WZbla/q4
#XzlakzISJ5j5iMQAnGcryaBVqc6CHqfPFNlf06xkB6yw9pcThjGDVo7hg8Te98rYR468xjSn6hNEiZaCwnVkDBzAg5MRJ5KYl6PA
#c944diMKD7ZMSRWQjz9Aupi8QaNHNHlmDgQUKh8gMFLu5GQQvWglFFyhy5oLM+SrS+0+r2b+/ul+7SXz0c+i488+aBLuwmCN7Xom
#+vjuwHSm7vscU9CDxWblX5pTAAZg8jEG8n8yS+j/FH6sNj4DJ+jKSoENXW74NMZmzrAQU9uw5USVYDtS6Y/4VS9kpHh6QXo9nIx5
#cwl6w4qMugJlrlQwpaYw/5PT8UIeGeVIFLcCRB3AeOFyHv1r79ahReynqhv2o9fcjraIr5CoXzS0Roe6yoO41vgZDl83U8caY2F0
#H08eS0qjcPLII0r7R+3EubocMi6yMAEmSn7F2xlVIMXGxrx+zL9xAzCAatMMHbIiD+K2/TUcnr4+bJCD824ReIWzGzIo/J+n1V4E
#RK3sxIRoLARklRe9QwN0KHQRjW2tg7XhdE2W17FkYGkTuG6kHFQyHZY8HgmLgm5J3HNk97FuBQrPItfjPocA1/ZCGhnXT5BYxLDD
#JzEZGaE8ahMs6oFCepUmap75EQNSTUSBPKW2IUqGNAHIpxC5/86KLgIMxh6IeEkMaFlBSuKqr9jej3kbkUxM+1UdMjo22agNax0H
#Whw4dcDVqa8OwNqFdiWMKegp/9P+xPwyFswMinzsAGYuL/trLWVZc2vSjnG5f03Qwd7316jnAHw3cnL+pupIirDmSjPvIzOFh7mE
#7Qgz/ZW8OJxAZbr3Qtlf3A6az3KBziI83InY4T5HN741nLZb8pUFWIC1geyw7eftRE8SPcxrp2ObTNxmUB0HWRbuL+j5wJT7l+/i
#0s18st35GU8kot+h/VumvIE/+qRp+s+/4DVArASxLa1oW1PCfh0Piz6onAvujfw56vC9d5axHWrrygE6hn/z6jNlZQ0wL3WxA7Si
#Mq8biMK+nodDBqMshzFPjdX/nV7c0GorH3HR2d4GFHkbBEFT1R759gPudqz+IZWLMLdYzQDV7azYBZV5C4nt+kC78waI65Svunad
#KKYmVO4g9MYGoX5JqOIOHO2VArPm6PwQPOr/kPu+wyXHcJniXHKYaj1ZrB5jzGiM4RSWgy1OozeR7bWFSMNJVhLXuOQSNK8WR6fj
#FCF8YxiE3ZUE4vaagWb50KJe6+SXKAZyKbAB9wHHYlt5VQaYKgVxchk2Lxt93fZ5bR6HZjphfkt5fj5ttgGv+ve2cCCTUNeylWF4
#V+VeyD69Vjpj3WPXshHwb/q0ToRag18qb0Y5x+N8RskKQFE8lVC7BIc1qqLjfXv16TbV/fF7FPyNrupyzhHxErG5EHoFdHXYhAzS
#uhk6LHihKMUuV5kIZPT96s2c+wfOkSW93gV3yQ4e2bFeOhtdmto1EAAevkPWslJjJhjDjZ9pgK3et97MUXqUdH8deMnobeG7zlhK
#UfWdjYT7oIyx6nQuAo1g2lT054dqGRFWR5D6Lxo+Zoqm/2O6NT4r1rVcinXbsKALP4AaRcbNxx3udPZvR+fgOZYObghynJkUyQfW
#OOrVmoH/wDvpnQFzFptGEKH7hMradjsQAl3/kbBX+bZ7DYQVwKYFN60CYut/E3m4ACFCFYh2n7kjzwTjoTjtY8yg4rLFUzyALrYP
#l93ilko+G8hGPoJkyJ4ClgU1PAdQE29fD7hyPlV7sJuxZAyjadDV7gj0bQM6nxgRydAjSR6nUSd3uVKZXqUhg1738Bpw8eaySCmr
#Bsja4MhUNmqdAaJSogDZLycNoA8z8T+AQ82Hrgbp4ijnNz9JAUkzjUz18JlehyzQ8UihJruEoMTJGtLZNOWN+/XNC8u3O2oP3IaS
#IRyN7Kf13qCKS6sUktJ22mEUswkTseIw/5jmnoEipuZI1aEpU1FAEJZGNHBFubcZNOJA1o5lsRQm0sgnxxGZI5qWpDbeaedGQwTc
#ogAdLce1Ga4M30idB0BRdID0ytXvPDY2k08GQTOaPFjUyDstHBaImpwJGApOZtz5xAMCnhYqMJAZcjxDmmVypL0wUOwhKkL+k6TM
#ByVlf1p7SrkNUegO0bJVw28V/awqD8qiNRylIguoWQofwzwscb3mpAktX8tDxsXyRf/PWjfSMTmyvZ29qnmrZMEhmgKtNSTvJWj5
#V515HmbOlUxiWob0/f/+xnP0PHy/LOrUSGtdx3uZQFhXrt9n0Q2r0HxG1WPBBdFxVUtwlABVrBJmivAmp6tAOKzEkdmoGl4Cjj2a
#bVUMRuyy4KVejVgJ+uers7EqCPYdd0/wP3SHlD2rHiAHPdYiki4WYWyGAiComdaj93AL5YSUNlGZMUOjj9AcxxclOkD2i1uaxrz3
#T9EOW/zswOCfSoQASOqHpe0rkpWtyFDRtKLGCw0TNePi2gak6A99gXwBVGOh2ySx95toDD3Wa3azEZoiHs8/sXDOKOwbIegxatsC
#g0JMi5js65Qt1YRNA7cEpdc01Du21VWjHNoB174/HNAvKh1s8QyDT+WbhwMVhZOPzEANg0ZeilAwbhHYOLtDzqWg2yGl70u/Ml/S
#FIJdognun6NQsjoQ+oWcPJuG7/5ZERvmOJTsJBLvYwPP+/N7F9//KujdCc3kTN0xj6M941xKnzTGKiQAYD9qkntKrO0I+VqJ3QcW
#QPJ5FxOTctcEaSfTodQ5o2AK9M1JEaM3pgzxVy9RvxFkTv/BiU9K9SAGX9bIxGFxFiH5s64GH6T1WGqVsKe2TV6EJ0EPgFtHVYfE
#aM5kFnDWbE1FsCrUFSyz5O6wGnPCzajA+u5UR7n3Gb5P66JizAPvWsdXAi0+Y0SiJlReTOnxILPdqVb0EyfOGXGYtHHvf4SB399P
#DI0NTD04NIzx3mLBVIhw5jkTgfm1j8Sd0bSGQlC/6seLKYzWs2v5dqoGt0iCkuSsUewQfEpFga4L9LfMHEI263D+0KFbUgQAKh9w
#v5OB6BlYA/oTgvGlao2grY9DdKEkNLQI+ANs0BVfbAwA7cPIh2U13RRy3xYZdN3OOTImgA56GHHHs5YgfD37c1QVEE6YQ8S3Gmmz
#LMDTNJo09cjWCEFzRZYDBXHemEuQkoQOlv0Ly7LrGtx91bLbrOlPkISwYGBDcUW1Ejc+MmTv9DSVBFX5xlB3xfNjAQU109DLZtNQ
#lJ0nVjTVyFivgOwhIbGD9BF3CKSQhCjsVvghErCqVr4yqM7k40sCcelXO+GLsMwI9L/iXojcVnG/XXXadsN8NxSeh8pc4ERbAkRK
#qwPAwxAezGjtW0SsWbfh/C7y9DxJhUBCNfALthbqE7PJBfmeo62fewTn0bEwZ6c2M3BAXcWNVdq6+Z0jKWh5qHhSuocP7cI8Ux31
#IWMa39Enmukx6PEnn8FmoCfry+3Raqb6IFZFJfiIdqzXHIExws8VGaT15ZEBcIw6mSVZrjASqj82/3Ch/0iD3ouE3MtLA3KsQAJC
#X2kFSc8uUeHXHB6O1Co3O3GIse93aVHKZOLeV5QsaXiA5H9cYDpNjwLs12PoJTL0splI4OGi0MGyfOBAT3eqhuuBfyV3P1ieoX/b
#dwdbV1Qo9YRtFPVOIHVaAT7haWBqKbCTrSlVYYikDjSDl2U27WsDnGM0MhB3a9urQXu76jWjywZTS+I8EWh1blBjmoh/bkUJowlo
#/7s+MwezhTw+NXOoL0aGxB1mW/rS1ZUZU/IAnKaU18rTWSLYIeMjGoRG48HSxypQAnrckCKR2bn3hX+F/2oL22q6eZ7tPG9XmnLq
#fPGDSzCEVSMzkgCaPCx8qkgXoNcDMT4KOG4YviGTxOtdKTYR3wT7DvV2AHoIDUeMoAjzc5Grs9BvLHKCooggQt/zJDcWdA909Aca
#pIoBPTTy73YiycNy6LkInX7CSIJLfk2aZxoX8eb2FA0iLRz0mR5UBelPIaI8bfKv8MeqlOHmLmRf7B4/cXnazIGbZjAFhE7EYXwk
#Y/FbfQqqDgb/G8dDhWiX6LkIX5ITi1kDbTJLgB470q10sWGkpojrAQAgYgptR3u+xEqV5haCmGVs42Wozp0DrepxBCzcGgI1PWQJ
#2mwHL7NO+OZ3Rt1I08RU0smk0VMtcd+uuFn2DoEKbavLPF0ewYGlB2TlAF8Umr51lIBFrUsaVpPTxb7m+az24E7blMt0Om6h83WR
#LHqd+noha88mC34Wn1PvuIO1ocvIEyYPHsivIbPtMitSG1DTudEFG3Q05lrEfggWEaYlsArHiZmk9DoFNO/P6/t7/znL6+br48Wt
#/efN2aeXCWWKw9U1MuUrceLh/fHajFDLs/VCWNhxlHSe7W0wl6f5bDTP0pGZ4BTrDlu4xLMRhIB4JaXv+2t4/+zwz6shr93kyGTJ
#8zYP9fIt2i6+gK1/OjmWcwTkNaARVb4ae2x+bciOTs9SKCcmHttnxwx20GDOeXiVLWTlRj0USKvBp/6p+3bptD5JB2AkijPgJysr
#ZM4q0+AoK3JlepkMw9kd8f3ZmOtf4dSP50f7nXVG2DBwaZjvm1VAOHJ0c1VVy5njpIXP7fEvBFiWVT/r3CkrVDIyX/Ei6izJvqm+
#vH2//gV+21SvWrrIkvxjbart0HF31h3FQFe1Sy3s5BZ1JzY9AwgGdTJvVh2BQLAe+SlUjB98z8SucYvtE63aktt65muTZ06AvZmt
#B3VdGfDTwQdFG4dPNmIT7iqCOWA+2AtUqgT76zjEH9rFQgEPnzQZZunR0W79Z2hcIxHnVSgzgTfZVys7TfACa9z8DI6dukSkZim6
#/iiH+Pe9P4HQSqBEIab/fGWQnbC1wBbEHfLYJtpxWgBusIsGOIg3xnEyli7MC4MTHIYVZTd2Xbdl3/KgiI4b1n39MMrv9Boa/fIt
#3tSOK8u3SVsQmEu3SYk6BfweH0/MaeIPCcx008v5chD0BTMVSytH9pPRqaRcl5AOqJ3dI6oYSRyeoWP1FJdukEekwtshRFHxMhtT
#3LwWDSwQ8B+cQWPGka2Jk3mzaib695x5u/CGMHgLqG60DbdWXzWQl+WuJjZ8N+lNlnkHG5Z48zTZrf4CX6n7CAxXouKptagSz2zn
#E6XS7db0XD8wu4KU1Va+dB+yrxQdRO+8p5Zt28vL1f1I2fwULRIZXwYdcgc21Ued8au0BPneckbdsfv6HRrzHtsK28454Ywt29Xe
#S91Q0DjRPS6eBW7W7vGnohxJp93XUDh+WGODnrtV29hi+j858tEA7uPYUGAAjGWuWEqwpuAYLNDCKGiMs/eB9EJsGNYiINHTvYyt
#A6CYfhXVg0oXSKEwbnmIOilrnEqzkBvesTTc5f7eoX3l9+pWS+wWwoOSVVRX3/SxcoINKd2thWZQg8IKrjN3Yq8SB6jT5GSqjdiT
#LFq0KRefpeUntmpd1bNIVtv9W7cxxErKCKk9rqVW2JdUy+yoXN598R8lSadt6vc02L9RbP9FY3kp0ymffrdRgRt4qz+dzW85VsX+
#pw64ib7zTIBXAsJeVWMBdLB/ADDN8tPZFEfKOD6kSpT6F6IGYNPPNV2wl9pJN/7RLZq9O0p5Rjysw3xomlC0XK9g0n/9FW9TciJ+
#xb70/vm8xE/HRuQC3BXvB6kB+3PIJcpR5ja3I1gZcCInT7m6/vHfpBcG1S2bgeJLRkUmSdd/OEgjCE66EgwixgSSy9JFDfmzoIci
#LVaqsamEBIg/xLAYtKjgpUdKJQ13fEgbch5vfQC2ZyBeJM6R90MfJuVLJqRsgvmgoVIFD3S1TFpZQSdgf112OVTBgmks/GnNm16U
#ooLSAfZG861B/LJ6/5xyAFYgwYGa6VCoKchGUaB1YlqOKtkd68eEUtxt4yd6fPapbH7DKN9u2PP8Xh+/708dvDx6de8svLZ2LdJo
#x/h9Rvy+ICR1JrDgkcJOJ3G/rwExNXpNHyf04u0pL9lz8sfZGxbRIT3qyuZUAVy0MrVz0iH5s8ri7HRBbz03kE/fC2YKfkCMufQA
#3wQB/KMCorsBP5NKYfExdoiX0iIAPSpZPSj9pgbu8XL9lxN3UMpu9sgvs/GlZsIstIxkcA3aG7MzPm7UaJDgxIpCxxrORb1S+l5H
#UjdDSfdausdIQN95P6idrI4O2Xi4JRXB0WU0lTX7B1FBNRh/10cHtTO4mNH/YVd0YRIG0AwSTQWKSoL/lNK1X4aATOiIhhoBpifR
#U3Al9wgRsHfePFMY/hsNunIddRoXMIYQb5pB7Na6m6X5t5EYgnBzZc2dugvGPjT2+2bMvojJO3q+4MJT3G3wNVLeMJwhTtLFsjHL
#TUC9xbdfVC3oDQFO4Usi8yQ37eH5dsqRZ6eWWugbmGX5RmB09HEIcdzrEHR+2BNIKBol0C7aBhwZB55Y+H59GukUam6lou9z9tMr
#zyUPt++S0j7Bbk5ovxAL7IO+QFwaOJubVIe2u3jcurwQjxMhLRMbGTljHL4AoeYk6x93//H9fvp7SqVKzCPXW56Zd22qBDjiDtFc
#Q0LrBOcdI5U6qBbEiqImZE5eyC46pMivK2hrc7bz4m0hQZZgLM+2i57rYpk90yJ4+OHe0zgO7hNvN4tk+FQYKAP1LSkm6AyLJ+5a
#PqX2fntzkFkyPkp/PO9VUg80gHe/Vwvs8zj65Y1g6NkyYoRETTZXH+yY7n2odSESnJjSVShQtntlyCPH0EZO0hVg4wXqKe62ucij
#ierekeOdS3gXklwWRmRmYDFNz3279O+St/Dd/eFiP5A2bn591AI4O4PoTwF9dV7sD4y8AAoe4fym2QOKwD3LHPzPlMA6Gwj2YNP2
#D4eNBqEHW4BSGI2KokvrwIqxRVdVJASL1n0de0+kFWsM5+YMAefyJPt2S4hnqFrC9Bk37DnR74wxcNLsMzkK98Vwj7gbUYbphuhM
#U78cQ1TqeGReVYwi0FhOWTSbkpI3pzQAI55yvWihueKDsxyWctUbJ/KS1QdzCjIUNecszKhNmshVQC7pKRVJplscjV4VdQwmKmok
#1x5rrrIr+5BplSkOyGuKaN2Pd+p83a9HSd/vfJimDXhwLSKM8iEJndt+yn/iamiHbZ5gWYSeoLm2lZ2YM+L4HTPHObNIuTY9+d81
#wBdIEFbIOKC3HZPFczD4edqBM4SV6c3lyQvgawEI4Bwfb0DZXW7vz7Ox937PDfKOdIWZV4x2jG7enBeVLqxNRuAdtvuoqmIEAVwh
#et6P+mmTa/sxGveVft7Yv66F8z3LNzMXtkPatnf++KCfbU9WV5xvxCn7dUubOdTcWYRMnSzvh9XtM0uvvHIbku5QM0+AgaS2N+zC
#prLuqoQDzC5/BL9f7gj7gkDNuBlxVjO5qmQ82WRfH3CgXN6c/oumpbK6OffRJRsnruRIB5v9t79/ompHRqvaAlKykX3GpsRMAWCx
#Pi1fJffNm9HrWnZewMS2vXbMdC6vj9BZ9Na72zNUvE3+6lMXThMKvTT6161Rt5676lBpE0xutjuhlEORMyRo3mc3zljNaRJPGGFL
#27Jz+a0LbA1Eu6N5THY1fxXOp+n9+wGtfpDxQVAg5czRshz2nkm27Dmz6DN2dHuyjvmYcT2zPzsvJ24ru3LgVGZSTm4fv9MMYjzW
#H9RVH1YtaDJq8yhJakdSn39OIEhPd8s3VCD8We+kpq+S9t30+87tuLAFzoSS6KoJd8/Ad6sqOhf3m2yFpZGLHIfPyU63sRmpk7KH
#oHJKdg3TFvp5sTX+aSrA3EWAF5hsFk7zd82ClPxR6+IW4yEq6YLAmslWBmGwkYmZFXZlXbM1F6DGDtPCF4/prNxsBV4zxRyDccir
#w3s0T9gzRmo/dNls7jRN/ZMu6kjZvGkB9rpCFXx3sfpLPfxuAZUggTy+nJ/k+Z+nOp3+wvrzT6T7udCI96XuNT/X5iJN/gK1fU1h
#QkV3+BG/9PtKc4B5fu8/wR57/E7WZJX/+N9hFPtVQAgMqLkHgLz5aF2+wqfnxEbH0OVVbYu07lvKOIPenQ04Ld0Q/S64BezpC8uq
#Auynyf059NkHvHGUAKJme4D3juHRvCgP74M10biTdkXyLGMlCD4tYh4H3lyOzvGupv7x6Seo7ElWiQfcPsOQVzF674TRcveG+ecl
#4ofIHsiG+9vb6+0a8/EK7ah06jG9SZXXbOx59PaPtaXoATZmtJpfecxut0C4itfTC9XuIfa2p3V72vnt70Z7wbi/qarUgI/Zs+x1
#QlYEaPsFr8SWotP0WLXmFHXQ/ugWXIegWuhK+h24mH8G5w33yXSufeB1PE3r7ueFVJtk/t7TBxrPeSwPugM5NBbb/zVp8YbhPV3y
#rfk+7Blwn0PPKEAPGVA8hwYcyWZUqCo+hmknsY8ZSRSRzklgw7s7Fk1IHDQB51zdj27vqfMWdNcl1/GK42vet+n5y0ESfPM1HJPf
#EDpk+rKS/8uAMrOAuZEl6ggItSXM6PLEsZU6oknj7W5GAqtn9RwyamFWWQtStxWIFXakv9/8eaq6vz5Gel8NUUEpSdlH0NHjKJs9
#56n4HDwS0pgl+v203oLfpGNmecWiK2XZR++p/Rx1p3/GHOEHP8We+enmcEs+gza80K+8ksuEqswN2BYowYLONIoES7I/vCKtz8Jr
#GpR3SfPHF6brvuwyrrBuTi0YXFSXuMAaq/ZWUlyJggqcZgcx5qUbLC/q6PfJw523MMjkQcF5B8CbnedHEvV6lxAq/EhIZlmiujgQ
#Z3qWwptApNNIuybe9xTu7hAi+bseaIRVar8UNuufM+gheX4Umaujc+hkUyKZZJGIcBpyTa1SKSA5mTweVzWr1+H07jAkolnoguWQ
#QPn80dBE8w0Ehdhri10MUS3MHTOFsZA9w64kWcYknK6M0Fihkw7too4+Fj5+YmGnVgCIYqimY0+/QtKdU2jUUaRq9EmCDA2l2L/r
#N6BB3js1WMmpc2DgVEl9vk7VywSJVCFQNRPFexba9pXsEcu3f5kGpySgsJvlIJ2y2/ht8OeG5+TpMUi8aiYz92B8Oj3KfqJrH/+H
#rei5y/GXppN6Vxnyuk49jj0gFAyFXLvBClobhUAp1axuREKsWXytYd+zukmxtip9oyLznWWf/8p1TjECKwzDzAMVKhUTynLBGF+Q
#hFgthmUbrciGYZ03u2v3fKFtXHrriWEeGDF6VZG2++l+k98by4H135RTBjEtySo4rdKirVgvfraQisFGyfkopgniiKYqjuFcmRZF
#UXyxjlJVGIc4bHSMo6x2jnHiPMaR6tMPsfBZc73vUnKVqEG6FlkYti7TLkY4UI7BIp+YBGo8mr2v3AQLjuQqVYpVs3DcrO/wwgh9
#71mHDHZAMi000BH/dqvGnA5sGmaYSFHCx1D3YJam2aZwkqCl6n9z0RPng0l5ECNkVAqRk9aHSXd1aO0yySds32yqQXV18SMYPmGD
#iC8GOjMZbGcd+CMzbO4N3sZtPFW9xhnW97YiEG5EvP6aeDhE7mzxLeq4f4S/uni/zZCXEw5yX7N417Q+1dr1YW8gOnJ2fx8KzNX+
#eMSB8Bpr7nR2Dn7v9MSqcTi351vKzg0QZemFu4o/RIB3zDv3UGBXOBfb+pUBQGHpAIHSQHUB2ocpWtFHcMUGSJYQQjenX6U9vLN7
#P/7+0It+Entzn02hQ/yUeQ+3ojBpCxyhXyimYC/Vhi66XQ/1iI/e2ApeL9hG+2zo1rEwL41cSv+C3iq3hqev7hnM3uDd7h6nMX2I
#iZlbKWNxg6pvEzbEyWP7OCApvTOeu1suYDK+FZ5QPJbYrKNzCReQ6BO/0ZRA46c5QrJQA3NcgFUB0ecBHl+AVlCyrUJZUQg5NHNS
#3jHOPE9dT11HXSuzQATewa7lEr9ijWaoSSDy+YiJ66RZZDvWWDcIxJVedEqTZp3y7eh4ilQw1S+mJEw6nU07b0W9t+qzUAuSFRU1
#RA+A4ys6ZHr7xN8HmJP7nOYC7KgoN8D/t0me/xf5n/i/jS0MrZ0MaR1MXYwt/rv2m/3/jfb7/8r/2v/NxMzEyvA/+L8ZmRlZ/3//
#9/+O/N/+b7JyALj/qgY4/+kr/j/6v92xu1Rwgt3/S/9NgwgBtcsyyggd5P3ftN9hLv+l/aYBD4PEplZEbXwKceT29/zdtj+YFqh3
#BHhknBVRSZqc/P2r7z+FOGCx9nAVVVp6l+WHWxozBDKqZwkH2YCrqneK6pS9Wsh57SQXOiaJpvl+qoJcbpv7eUPvPkEPGGm6g4jx
#SZR+7vb783nZPJv2AfYx7D+nRmWiQMbVSmCiDCYeX7D465+refsD8hyWMIyWh4mPR6SEweDFQEqKbAAkPmXDQHX2re/Pp43m5hSV
#Y2TnpYkW/qpVrFU0CX9NOU17qlpuRZe6JfR96z/kbHYo8e88GfY7nJsluNqGyiJO58JZZ4wUWsD/fn291WQO8D0gkxwUyRxXhmRp
#al77/QHvorRqe7pvIK0AsTEvpcV/PWbNHU34gTBNKoVIOwhDD/jA7pVJTJogyZBJNEkk+U8lkWz8U1ZVz5YvE28Xtky5zRaC1UaQ
#39BZTWYj+zoAJnHg8Fd9ZpZEfxGXoAOJiswgK11wkbI2tk2mTtaaXA3jnRtqBc/9u81ic7YuMw8I7fiJ6VRjOdNWXJc0KYo/2oEv
#4+8K5S4VXccKECn0fnKSbd+Fd6ZY3uxM4tx5o4gQISK5/2udu0jSFuBPfR9QPdxp/pqaisujSzVRGmmUdMhiMAAZtI+qnJeIrkh8
#b9Vf6R5mMt6LNzoMYYlKiJvr2fpbyoqYXbvl1uRMJCEuykqIbp6r+2rL84RHOl/PFa9JoiCioqDCYv7lep1CMgDtpwkX7VTIz++X
#pjj+YRZoxhoU5hEplAm3EQp3UkVgzSTIbBHYcUE+bK0jvOUhGS4UrhdJKka1/92CYBBu7IHw6nVeHHhbJtJk5cjVVlOBUxER+Cv2
#J1roxUcRLH75EhAudZ5MK8Y6BPgF/QJLlVchha4GgEK82AQTdecWjG9zJ2Keo/tUZRKh858PDUcEPpDDz2C9lG4gBFER/36c6QFl
#wuD3BT4sHmE8Vut+xJpJsFkncD6vhwfkXY84mjENZw+P1IrJ6YLmMuNaFOxhliK7cYyD583rwd6Otc1wurHmQU2q8TSl1rt1J6Ck
#GJjRWwcae27fOeP5rBYs3563kcgKR/q96eq9dk5/euO7eHOGOx+adQuVeYJGiAzATh9bqJB7forFnTtaXHhtaxMVLF0Avcul2tz8
#lNLSHGDkF+OSgs7aeSZjl5MkgRL99Z75eehcaWjWyt0/0k5SVvQBygA4p4r/m+HvCYP+vZzz1fZ57m3jxdV7Qkpw/iaxO08X376r
#79oGC2jPYdM+Q2ffgho8+0CIzEvLKJ1kFEsd+LysiEpny0Sf9xAxgxAWNtHlO1bVO56bbuN+LPID7sEsnDjaBl0wqsut+QNFersi
#sARuDn+kgmP4DebPgFsiG4VUgLUqfanYBD3E3N90TY/0G6qxYaWU7L6lxZs9txG8Q9ntTDyspD63vI9eASDnkcbVfUmvrb9vnT0X
#mOKpD1maOeDmCHzLAnDNHLU9Wv3Znenc34yGofvPBgRGsC7iDl5yXSIeHPISHcpqurzSpRUDAQMrDVtANbIVgpAy9seYA51FlG02
#FUULjKXEiQFPpCwsnyM/7qy2SfB+KhwHrkd3uoNjA/vxF+noT7HpC8Hr5HyWKSgLgNvsBkXIAPgUeU9fl2FDX6+PUEZUiJeqtCRO
#RU8w4zp9BpWagQYnibyvIWan3pKJvFQkuEMFQC+ULDoXyveWVhB4hNF+7RMp+K45GEWMIUWWWK1kYxbgqU9gICqZys6BC7e7rbCS
#0XrD3Ys1ABRJhF3mXVy8ewTjYvqN4bhT/1L/G0HIzEIQ5M05O2cCh4YYDMYUybRVqM22q9THy9XXVZxraXx5mLDLuJGWd4YHS1K3
#BX8cNZMWpaQtVz2J714mgO8Sb9jWPqiRu740CbbXESv5S21t8c/nMJhWRCbLYTmJbprllBe9KazLPw9/PmcwCB8EEhGMunQ6jB2M
#ouiOCMcUfYcwIIkfDxzXuLdvCYYIgUKWla92B0NyTCr2f6752hBItQl9RC2kUlKT4AyXEgGjiqiMnF4WkQ2fSK8kBvpobfWMiSej
#uFDhroUvuQKQmMJIwCG1RS42ThyXQxpQST6PfkJAh3xRheZiP+f/ttp2ZcQoAjTyNNyszNf2DXIEPkolbJC653K9Iq04WdHHZtx+
#GBbrIYRtHG2B+4bRWUY4Rjd/CN3E6TPSuvBZhtaFtxj07olgbhV1j2uZbLXkvuip+hDr/ohY+8hf9f0bhZ1eKVjTRiaU317agoBM
#YzvMN+4kVp99iWL3T8rZ4aF1dbLK9DcPZ1rzEN6xsVLDtgFmbecunqiyA0zCGUQ3vw6nhg8ADBwqrI1vfx1OE/ZRHqmMOXdTM/Xx
#5rXlrLWU0q7HwZnPc8XVZKFuqBIWT29fOlNMRh08zmb/4HuW1bulI/SW4X9y3YHhp1BHBR2AIKbAMAxmpGCzEBToQqgJIaGlVYXR
#oaSaCWWJZo35T8sR1awkhU4Mp5nhiqzlgrqk6ll20bfYYjUZj9BhlR+qnxENS49EhKEv69TvVonsaB5vLBx3HOWZiZPPh7lSPtEL
#GOf0AwF/iAZBsTeBgFz0fzYCD9/3/oA54rgoUOBFqqJ/WJKoqnUH1pgee8qmGHmpL3BRGMCOwK5Xv7+unER+wd+lS1319Lv1tvXQ
#o8kB0lUd9ggHohaxDpUZhqjt0fPvzZblLP9M/VNTSXJoJjL49866Ll79r0UcnI6AUvbD7Dcb2EO3kCU7zsZnYLV6ZtJWrJw4bmhO
#y7w51Ow7HiWflbns3rESmCZasWL9opIlRY/9j3PcSHYeB09hj6FulT10kG/OLnh/Mi837bogK1U+MF5cINGGKVJsFl6fzebVLY14
#28Y8WoDts6EVptE371ECl9sr1RGZ/1HURC64knoQeXXWO4uyEZzYvwPNxT/K/p5iULVTjeA4esoTizX7qmyKAUK7arkdoGCQazww
#W7lDq1T7axOQXHlDMiVUsvPaxZjUVEJdnWTLb4wnJHwcSKMfLwUZPrW72hT+JEoi7sIXnUhkVSgYAlVQRFEkMWO8UEpabBEyZ6aj
#dGcnI+DGcyOSDHehmDhTTVIfjCmhoNoEwU0/P7I11mC0czpj8JpyBtHOZed0318Ti9kZ+cAFZZzIplcu5HYVtodetaDLq+StBS8Y
#D58CCkSI2ib/LRrB4R2/Z3V8jZxBFHPMvOVivgRcGfkz8blO9SO8X404o3wUlZyt/dtRbOuJPDhD7mtS58d1gevlQWCZM0l4dDfP
#2xiXqLtpv0BT3SD2fp/j+KHtMzq9qOkseiCEmr3KwwAKhUYrmgNHMtGxRKNMIcPJqNjv8/UP1eesvmiqMPAiERohwJZkWiAfKdHK
#2FWOwo2fceVcDAxV+IasnHhYmJ186ERRQUitr/gq2alzB+v/YOcto+JcmkZR3CG4BYL74O7u7u4MzuDu7u4QggR3J4EgwV2CBCdY
#giRAgGAJcIf43t/7HbnrrPPnXvbKfvrpqq6uLq+eWUMnIoXs4DYtWSefHKJeGMaPLIEui21fFE1B5uwiS9lXA09u7h+AD4tBKdVf
#HcwoqhMWhr41VI9uMGOOnxFtJvdOPQZicwYa1dx0JYIFRRc9QiSUu/FwDtpbMRSLy51YfQDPztU93IdBCYXACv/Fu5jHVYKvxnQV
#YJIlXlO3MyQPZdOgE6XIROTGmFOd0EkGsTgMyyaRr+jn2lrbvKIkEvrG5oSuTHqxRI4QQorw8M8SXRrqYYH+rMuSx1uxhRa+psJd
#TKmYcTv5HY7pvQnv5qi+IU90heKkIUkRUaTkTb0YLr69ojYDE7oXFBw0dUTlBLMBt/KPCVhFx0o7GTxgkI3Cn0B369MqhS91I3K8
#0BIR/YI9yz5achRpTGN5BBqmC8FjnRU/BSnjPcI0ixic7fEaRdifNPcOwfFmNVXpG+ms6DjZbCL/FtTL6dy7aJ7uhUkn5gd7eM+K
#GLKUGPRGapo2XSgNlbxe0JMWiufZBdmwMMpFADZH2BY5EroM4muREDkWw8EbrvA7Wrvcgtv8BShGpBxBnj6M5x57bhpfOSferywv
#tzDXzqDOdNVGCK2ta7udI7t98cQelUpzV79HBq3HgyCZeTpbe5EYvo3KRWBVTTwfmNJwvOC1Huzwumxo6I1NDFBnQDeJsJy6nxz4
#5t9rpCRSOkVimtjmxvfiU9/udHAAKXc02vuXJZQ+L1CTQd7BIpGvB0QTzFVv+dH1UBKvqzHFlz6nFGHSekgPV+z2kg8b6qqrIQrM
#QLBAPg/EVkCODZSlRABelcGUjeQshAftOvitYn4Npm03kNncxUJUG6rxJ5Uj0R1znJpHSYcLlqFbqkeRDWFhssfXxDuWZoF8ZGHM
#O4q+tB6b6FM7vLWp6EnWq8NeaKcMSdAQGfQop0cJISWBZhb4XHFYxLk4FsJH8lmwBgILk+R06iqfqh2q3+r8WM2UFC2sJ7zAomMK
#AysClv4XZdeEuPcVFmRa5bYyBSAurPrMDTO0SALuILopPzH8EE/TREGs/XoSwFISy70wMotfzT20qAfUjvG8CAnRt3NUdFLMBrju
#ow5zMtHgpVcwNpy7WFuy6p/ihG9cMaCSC8SdvFT2F9wIiZ/zz/rvvXbjMpQStkxculw67ldgaVLOh2iaqcGw72b/rFRZ6SOMTijq
#2063lgJqYqEW3NOnv320SCLiCaHTRux7nnE3C1F963THAmG8wbHBFWjbZSXk8EzI8fL8dDas7LMykyDvI4SeyZ7XAfFMIkcjtFKj
#DkSDqykBd93c0gaeqw7CPmaDxczErlNZ7GhZTtNkG147DVMTZG+sgnqzeJEzqqcXC/t4nLZejxGuZ/nBIGEC+vXUlXg+weP5YVNL
#VXtFq1Wn0itmEL08xaFVUypWSyc0azkYnrdzeWOsdD2Jmv/SZoHRE5B1+ZpZz/CisyngS9uGv11k3rqP7Sq//7IBq9l0+fPm5KT9
#N0XiiWTs1AqqS42tMagUCQa85joTA9AgqKvTbea0Mtvk3oZ6yShMRrTL8tsK4GhPk1GIWElMOvqWr4yIJTRiBRwO4UuGs1X2WKOv
#oxzpsUyq4qS37Uj1uEmaQe4mg1Y9T5GDq1oyEbshYdR9WUeuLclEBV+7olbgwldjGvq8iiCpij1s1nPlx75kapTyuZCVdU7IPSik
#L4ae1FOEJKjYyP4gFJZOVNXhc2Oxi5FEXSS7Z7i5Olp1+JyhSjDnawlAoSXCne2NGkR7ihR04Qm5x8yUMgLdeViaJFZFn0kxTPR4
#I7CoNOnJqqhBgSEmv+acDkLSuA62C0w7S7zY3uKTFgPr4wot0287He2xofO6zkuccGGvZYUbSA+wOJuF7JFJqZog69HR0wNhHTMF
#YgzeytOfFy7I45UaUhe7bva06Iezm+cndy/FEMApDmWRL5pTGm/TGwIOm2JIrrKFLEsbNhquw6KWzV2GBTtizsyKnrFiliJqXSJn
#Y+GNVGyGB5oLNDP3yQ3MvcJogP9AYWgqO9PhErk1Hh6vJI2ole8Qw9lXRtVdYI0RP6uiYjs7j4qONkVZT21FkbbI/WoWHZlRl0PX
#6hNTjNTbojcpGtZVExn8oG0M6WbNydJFJ0w8PS7vkdEvWq/9v81+/BSXcT7z9tXmhs/ecdxbft7umtx1WYCd6402pjMAjREeuSU4
#rRs5Tw5DkcjwVf1Hrdz6M8sJ7QILOK0SzDK5HghXXBVjCZRJJVb1GyfiXXqdNwyM2u2sbBc6nN79CRU9CSqL9Ws2LttYS2LDfluK
#BZdqY5pPKbZiYqvieCDsMELM3TJfWV8hsRMnlro0cOEVatTPhKnPD3EUcs51vnlnyz27EuDfN46c516mYj70OI3h/HFceGlotuSE
#Ff3EajFFt46HVfSkAKduvNbYG0LhtrQ2zvqLsC0jEp6gkODj0dNYnD59sepskKLZG4f1fWKrz18jofh191DU70qDawZrKDzlZvBf
#zGto242EuTTi1cpG18fhdEPs2BXic8x/lcnKuT1nCyCc/ta2eqc5lTdr0V7v6yLUGTOBq33Rv49tm5+JrLnsYADP3VERMWezWLwy
#OV6byfzSlS6htfyW1R3wPCn284xJJUR03KbHDsp4eIFIaTGzDv2BoU/psDkhCgLKU00FDiXpObF5AmQzLp/WmWw9QnRFLXcFIsMv
#mrgolY+KMZCN4suepUd9al59j+YYfIZ0j5B6zrhaW8noeNYgO3TgrQETrmu1pVfJVKEYUDN5smr+3OqT1xA0o3b9TXWGUWgIy70b
#agYdQ60zYAoj4RH7ro58iDD7Rzg0t6Xq+aVPXsv6uFILLgo61suTsP7MeFcduStooVBUhxcKUMYbqiz4vVliyDdGRta0i8SiOsNp
#Mqp9lLEv03jydGty5j71awXwnSyZCRWnn5XRo8stoVI4uOXy12NJilOMMicxljLSOhw2vp9DN+w54BZs5ySS0xhid9vKdX/e2fTR
#dDJtXmCp/unVJLZf+TrMDKJtIlbxPrtg/Rua81EcgwyGbPZoUCXnVzUbWXr4gH3siDBdIx+yO7YP19TNDA2OGADfV41F/cfLUct2
#L2MYiKQJpo0/SQtOzyK5ateyBz2D4Q+tFFjPNgJ+GQ9iq5snuHLBNKIag04AfJUZXJrViXxmj+BaNsxvOl8TFF7SI8lfiA35LEHl
#o+HrzFooo/IP4XqkQXw22q96cT7jDx/2jqH4VyDUNfdNjio98hsIlnqtt+bfKBCm0YvWV21Zht5y4PfN3MqFnvlkdRcnwTnEs7xf
#oM1n74VFCacrxUe76OApN18UGCYnM5+CaTmVYzMgi/4w5Q7OjGw4XJ1nfvTncvUC0fsMAccUjKqGdvLTaznv2/Axyy6P5SZ/8o90
#V71FrzST7hI2zntvdu0dkajs3Kf0pxbonSIF7cRHv3zzqvSM0eKciPHg6zMpp4a+iVMsyt3UCFuYczePnkbTmY9LdG8PjjS4KRWW
#CeZZCGu5hDbjt1un4ZSFjMqeT7v45I28ECnbuWLWGji/VGdUCVDmljNdeoOmqVlXheXlJKfT+WX+wEth5ZppFb+dV2MvczsHWkLz
#jEZT+d1Jx1X2R4KFiXnRJrcemhudV4AANZUyXnfh/Z1WEU3VNcy19a5wNMD8UkqK3RfWBivJoo6tgHw5+33s186vvJ56oX2j2pCj
#FGjQCYO3AZnNLyoqojMtGyfDIyvvsy9e9bzlmbUiL1QC1tA3NJmNUZacBpfkZIxZ8QquAb5cdPrbC9Bz9Te8qiXKLSWiW8Xqc+9L
#dWxQf37LmO6X3UBmLkd+m5vwTU3Pg0qFUGaA03pU0vPsWFyze3y52WLJarAnz+CpE+fRu60g8WZbbxaWmmONYvPH92295kC2mjVU
#BiFPopyJvDESwdh0X9IljHzm29knyoedVXu3VTUHtc5ugfY3XTpur6pSNvBPKG7UM28WbqFvzLXXRtiiHZcJerreKtFWn8tiD3+q
#RNK3DMVD5q66oyDEQ+waWmjXyZjyTwwmv9FJAFg1dh35LpShL205ae5duucvqFROHysXiJ1raexXvD5ErhdfHHUd2BiKHHHmZLps
#XKfK/QofWhjU3MyYS4dJ7LO9PYCYWxjSjXuiT5YsfNAROqkV9US6gX0Rbn0bdp28iw3miGBMRJqSjyR8ulcNSDsexPI5x6Cu0qxv
#9gW8Gvd+qBeRjgsXKMKwb9yp1eAZBF8l41CNipfDdYFaUEklv3/0YhPlYtreOX67r6aDYGx/TazDSeFH3YPpZ8Ji09Ps63Z301bH
#hCiv4Vce+XqQFBbafyxVteExIX+tbP0Mhn5oiDJtL8Q3gZLmQ7eT4j1W7mQBEoaYPmSJAJfQ+zcaNoAVI8HJ/tcnSjwfp6exMXZ3
#aRnIyc3oyq4W7y0sXlVh523vCiAFC+0RvgIY5QFww6JOcVqdP7JDkUlNDZ06ox4T1vEwVCXCr5dMflPDCmbR3oz/YtbUvqif3NFd
#hGh/UfDFheakCBBQAeNV5ZvAbu4TszIhS5RwI6EoZ2ulYU1xTPjoLuE8cYMe86WE6euvr+erEwyEL3c06iZWkD4IsGcfZto66rq4
#0bRC5/b0dMypkjZjIjGf6jI/Emo4iqNlavi6QbVoMUeJP8rXZNcof/XNVdOh8iQ5p5AJdrH2RBInbZWoNeQ9i1lj+oRarqYLI3VM
#jWv15gft9BQksjZsJaLJroMDJslgROZuCPWgQFw7Jkul2Hw6IzpSn/CI2fgyD/kGUklVyQFEE0RtIgikV211joJN2yeniBZD71f2
#jRmC3O299CHJGOIr6A71ni9uvqahl5CTDJbl46/o3ANaeyS4Knnq2R4E5zi325ZRKr7reF9Z/3XR6FMQd1n7I9i57sot5IyXyqi4
#la2jCYL7rwOahJ26UUM1PXtN3fo7zoVxxoSqX5fp0PHhBeCKvRcrmBZDnVvEIcHzpNo4PH1MDMuPlDvA5aROmGp+oL3d3ns1QM2F
#ftYwyTsYqhHViJOtmn3dSe2raKnId1L0omKl/00vZg5UfVFLHtcr1nXbTU/va81r2P5eiTGmJ+KLSY5Q1RrBPaRc1coTRZZOSEho
#eDgVgUbbL5RoIKWTGD5QUzqpnelUYqSXQY3KOTTZuQzxDcENhDJIuW/NvjNeqKHlUPrsM41TR8jO9uZRbxXIhgvDaC1Ta/m1myQB
#vsQ4UqVynkBfSNonBkVeAzOMNsSDSjiQaMfUPf8XS09d480j9ePJW9S5/RkJpiXTNyQkgV5egzr5+vbwGSUahJU0fBRXj22pc+CU
#JT8MKPnHLG19JBcyNlwrRIqHqGXz1RtYolvPppt7ZUkcRGwmPeS3yTFEwpbOU1JcvlAzy3BReaRRGq4v80FrAtLjo4vamxqELm3H
#rtBVslnpI+i7N0Nq+wUhhzUa89V8z0mePHU6VLa9biyXiw89K2Chxh0kxcWLleAinzFxjqpVOYVjUeV8gqpevzmruDShzKwgwmEk
#mLvMvGSeue9/EvY0YQ50PxLKTtAYp/S0uZdy3Z0FxjMZJjEytR5vIb0zCXG5hZ4hU5Lc8wTv9qhsNndkKLRe9uPJB+Foie4oiXFt
#NXv2VkamQpjQLZY8v6VYj7EkoxNcwzf1yjGt+RZ2TA1Y16YwWOcqqDxTPf2LnMwIGMDNZ4s8HhD5WNF3+DClJ18zX++2hg0sByma
#rrAmgehP0jgkTh+19BbSDO25fnZlmhgxONI2qN1ToPns5wy5OBjBrb8hm+9KXDdRfdvrncBvtUYEej1FaPwcwynlqHe2GT4k9v78
#9pP6e6ylSk8nrJyVSlQde4mzypdzvO9X25ibrs+YoOnoUGVlm07WhLZqYj72bqsKBg3gfZsbllfwy0oarrpqJ32Zj0LhquSaTZTU
#FjjpnpAPv15phDMZX5jM+UQYkwvzkdjZ5y82lAkaMCAFODhhlEQHBIcod1ay2B5Ob5+mJDHz+tu0Fynk9E2rj/kmn7wF4RsTBEYD
#Vysr+J+xriLzua9CH76BoYt9TCjU2tz8TKhBqbBDnUeTF6t6VqkfNS69qCOkYxmh1U76hk/q7KPXRUrs+ey2pYSPNlqK4BTaNRfU
#pb+lQ3yKQ+sQTr/dN4CxWr6BvauG6Cs41ZhbfXU+zunC3pfQc2sr18m67ZEry60yPJVeONKNsChA5uYihWvSN7dZ/cABKZLRMU9Z
#tvjMbczmwKeZg9kphh/SoAN4Qdlc1/CUfkSoUaV2zVQxY0jRFwSfvE9MTWBw5JD8R8S3PutfyF4EH9VtGReO1Tkqe1qY87A1QWZN
#Wt3x+7v6QvI+q4vkic+A2N4Lv3Yc3J8lnulP1N+pRYrOfIcpZ7zUUJevbqid5/LqOZ360Aeis2WHOpcUIQ1D8Y1E15TUpDzfclMp
#lxkODoUzJ3DrX656Chc89spIk6o8Q0M7ZlKgcd2KAaGK57TXNZEGWkl6LEDgAFZs+iNUYtPRoIk/7hKBX2zgWCybMvMaZjRpbj4x
#SgdhtxbVY8oqT8pazymsD3l2NtdVpRFlJ2byDV1Un9Vk7HMIUIbcsRO9EgrsBLsCKHWWP0u4PEkJhbd9xaAVst454h/jn2rWzcrS
#G4h3j2ZQU1vrfthM/2LTNL9bQCHhSlxb+WCvFL8zBA4/tjN4ZoZNDrQ0b8PN3KAPMRjS/57/0s2WYxnRB34gtTNmXfbgsRbK1ysE
#oUXxImd/HZru6qcbqtYFaGjPsGifnvZ3o+MU1NjefZKaYjJ2yXd8xCJ15PoSC+Ok/IPtiRbOEzfy57wUOsp4ukl5KRkWKOHJfW9e
#vccIt+LI+XCXW9NDa7mgOOkJcfekQEp64f2HfACtNcfF+NuznOOhz+nE/LWXF0cY37y2I/pq9Eu06+5UDdeyb1DMJ7Qmr6t6Orbe
#YFmUihUbaz0rKGB+xDyW5EixQkFBVV2BhKEvHXNeLQLbE+P9PgI1k/f+CdNb157DyMKT5LBHsbExz/oY9PZpy/GuONcmpzb6M+Uf
#LWwBa0XRKbs/u6COwmKc+utBxu2/27dZ4phokO9oxyXnjmzoHRq0s50UdXe3Dmc04nos4PQ15qTyALnHOmB5+iQOYhfkUvQ8MZQk
#/FJtxcua1ogXs9/D1QnVfMxWs0pDSGg6T9cAU03t1HNtaHU5DYPSXSKD5hl5vUWcE4GpHAqKq7OLCztE+5vZIUGSMTLxEoOv+mvu
#W0MbKqzoiqnpC3IvtqtGPXY95RZvBtiIP7mp1ZPa+r+7KacbDEX0ODIyS3qhjf8k9FCF52Twff8UUCRb5bPKxluG1iNHc6okc5XH
#HMT645baocdblMN5u0cC2Kto7PfLXRBm3djF3a08WlffFt/t1ezj7KO7qVgWx4/qDqA3UlCkN6Rlor9TQ76eb9XdCIBaOV7KOq6/
#i7tAYVme5ovjbD7/sqXyud2BM/vw3fMeTAkTsVRa0NDO2Knkdco3Kt3Xg2e2vRnM3MwRc5sS9u4B8U+SmMfwRjBLvw6lok14TEN/
#wChb9nuY25W3gP06zHm6+34gCcrAMnL4XQttHCdgCAJgnMGsNufTt8x8fYH0rt+b03Q4czfWArFsqip47GE0MtpyppTxlV0jiPBS
#wiP5SUutThfAOI05GQfwTBuL5rrRL5nNM2jZhyEMkrmdxkfkGVdjtj2Z/gjXq7XXKAZQ5qWO0Oj5FMf7Q1FW2RxCtV1UHuOw5FoN
#IsNejAGb+ux0aau80CUxSFf7heeW0ZAQDTyEEFZbR8mUWzRYN9w4Z6tSnB5oEPJYb926dkUCtFh9yxgTVFltJwVNSq4KtQokj8gK
#0AQoJrIksRArvrVdwup0mJzVFUZf0vGRPGvBFlYJpOzZNfwMcWgHueiOZALjrukJtWRQFyzdlZ4mUUDMQZr7HDUpFlIX7fM6y4XN
#9ZG5sQdjB3KPL9tKtcan7no5qGl3QvLcQ86TZuoRqh1Mv2g4hMWBOIHWXDHH5DF3pR7KkK7iiGiu2SADapqrmlp8ebL1w0Ejxg3/
#vbHJrq9le4zYmwLbDmIj6xo4uiK4BbCaXgZrVK0BtawuL9/DHH1CywmGiiSUN/qCr0VZijEzTS0h6j/8ep1IepfBUIQfefh6B6/x
#sfdTA+kumo3NqluVxGkSATvqAZ7Lwc83Q1ZtzF+HqnCzP0e+N/DZUJDq+iDV+VKdG0opEAIS6hnPU0N9EcTb2QVyAISfm/cm98d9
#4am56+PnK/1nvkhiyEjoJ+2s27kRU554UFtkJg5UyTWMZ0yX6oaPbEI/kas8QlddQTxZ3Hn/LQa0q68ZpvNRRf/FNDE9K+n6470G
#38JFFTv2LO4wdOOmfI0PeEXUpM7GTVciG1kpkND1oavtsJYDonTumucmgnuthNW2yMW2MK/67AKJ6Ike6UDhpMtae/fCpMWPfsBc
#STei9T7SEDOXgMgx6/clFnx6YfXxSNsZepmXTWKH6OLNKUJN2kvWZMmMpcHc94Xvil+PJ92mZ/DMeZA34sk5I0Ikfns0R6MyhqBW
#M9b3bpShurLX8dwsgaiPzLjfTh61pbE+fhc9kXCsWVrza343U1IljqWs6SCGbatpOtZ0I4kc2mYSrnjldp+jSrROC5nBstEX1EEz
#BmnPsO2tgqlz0jgaG5OcJlimrvZOVwWEtYosnYrrz9XBSTQLeYLukLazeS60GAFyhAWq5tm8oxapQhzReounWtcM77QneY/JaN6P
#jyMGfEAKPvCURdewvW0KgxtM6Vs8y6OnfTqmUhmADIJZXUv9AsucHZgNp1Ngmhb0KlzIGKtlF+VKT8P4S181iAUgzTreF2ZiTC8R
#2DT1QvIxudQX9D4k5mksbMVCPzfUGkmktBivV6yODGckszr19JEFFvzURmwIjyi7phsRXRHqtbAZN2WePDMKhVKHQUgShe85Y0Wx
#Igd0mlvnWltiXvFzpyLMCqdSqt0osPEZW1459URbvGbGHR9j1BQrErBqVDylBKZfmM4loZ/24oRSyGWTk2NKqqWl0KkOihcTpl95
#ycnu0GprPT97bzNhzgXTSSddIFNTYpcmqOIunBfLV4h846ppJF82cZ58cFRDax+9J9aM1LRdliMZr9sQcWQVPuqWkrVQL2K57/dZ
#boaKrDqtXLVQYwQ1cY+UuYk4cz3MwUHeRqtc4G2F5nhqHqHmq7TrRvVefRuurdIF6KVnKYa1Ko8il5X7zj1qYOlEMHjadyPMhtKz
#psei2YUirAzSAgbjLxIq4T25DxM6jj6/G2GAeSwgCFn69Qm6T/EUYqofoNNynph02nxD4JOjcaT+E9sZvY9vF+9OGTSqGo2b8TnN
#BPGkFcRsQ70QMZ39pEsTDGqK0ckIuCllGpQ6NVBzOOzcRGKZS2ZkMoPLVnyy9VoOp6nlW4leGr0gnWoeu1gcw05fOoxs0d64S0Qm
#mBFrxiCWwJsRP8eA7kcvJJViTUC0dTQjpHfsjNUdN8eQj1NdLLqGmhHNYtV2MAsal+ARvDnFQeozw2ZQ4qN6w/lWkfdTXFMCoeeI
#toybeXyvpJ7ugNRtw+vpxszJwiYrqzLySInpBAdrnulg9eXqIVzDBuQ8KOSGR7iRPIN0k6b9VLXOYwcvmuaxNlaoR63uhomEAbyh
#fWQuV5xsNcsHp5wIcsDiSJtPcUEwsmph2z5tnFyRpJTiMov9JUaQtxWc8yX5r7IAs/du4oxPqeax0t463yq7ozhwzld8de7dKfOA
#nBgJe0uf4jZiN8AHka9unSzM/oY80KFoYWlOoKfJUCc/+eZRGnamuma1uoYLbAj6BlxHclXjqdydoupRYw7hjDYTVJl8vjHF12rJ
#qP97X4j7/9jff/j+p5mpi72jJ6Mr0MGG0dwRZAEEuQItfn4RlOP/zRdB/8ff/+Rk52Tj+Nf3P9lZOVn+/+9//t/4+/P9T20NCIyH
#5/AqBITW8X/7/c9gvsf1OkTRHg9fAMVFCCZFfIqDgYAUkgoT/FEMOYzyxxdBoyQevgjKBx8NgRKs9Viukcpe+xEIXuTy9JI4W4Hb
#E+kp/ObxmOhgyD6X8o4HetnWMNG3ezpZc6I1pu6ayqCyoHFKfU3TyHrEG4hNA8E4hwSnOZWi8PVCb3Z2fiUqo8IwlrrnWvjw584G
#nrUTw2mwnMLMbDcokHQRglT1Kjw5+qniWFqnWciWjScJTwAUmNGUgFonI+71+3F8wc6rx+vb8XjdHyG1AhYtaIxdoJB9PtuS8guH
#k9FrHWneeufMXt7dxiJikKJuEoboIJiJEmrgliPS48xma8zRHpY3xdA5SNNI7Xrd5d8+a53yDxzESA2j+TKYE5YljZtssR4VtrNg
#6d5fNErwzO0stSNz56hBAYrS1NIYlyCzhTmWMgydNIkFJ4mqQFOl3ZBH+mu3XbPOV02Dmg3Q0IGex2LLp+UYjLY15JjKWAyBk5fX
#ty9ZSUVrqKxDusRC0qA6rQ+V48bH8ZK/iNm33FatCRvMejSV9o6PjvCBM9ATKK/NPi7FcnzNfnVKqQMnt08cWIHfjNBupz55BeCK
#LYuEvp5jwrGb58D/6MV963vYOY8gUUm+slz7KeZbJzmSbG7MLS3617cZLqpU1T20wn6O3CIRqPvDCDeiI21dRR6qVVVSbF+NW8bX
#fe/vx6urMyagOIoG60nflSDRcSC7MGvOqSgzhhbFt/U9i0K77HyKOrVt8N6wfQfi+lHSMgaCoB31qg0nN7HwCrMVGgL30ke8wHwV
#eI4hld6rhWG+pc1LKyTNOK2QIriCNH3DAPxhLMJzZ2sXyG/6oD45OAPu4lOLgzV/pzk4CnxUQoebi/a1ybG68HY4jKW9+qQgApxL
#4bLjtm+z8cTJbFSFcBBS59THRvFP4dKCpmj8YJXejG5u5Nqmd20oygSNM7FmNGUQyX/i3beXU7WqjmXyiL8PaOq4P47Yp6YqEJXD
#FrEVGQ4OKw6O4sUhJHWHkHFwFog8JJ7yjkL/YL3gJGND/PYwri3bU9ZDtHk/fL8Ur3gEZgYIf79Rl+5x9/TWLHPDA91Cg74XonIu
#02HuoFBlY1/FStIxcr4IKSQnHtoNLaq67xRjNOLDdbdj3acWKMRq5CuDXOUmNBFHyVkRAmr81qKr2cg7oPrXo0elUDTohBXab1X6
#ubsqVJ5h3+VF3/iLutiYiiKQhSEaWY4u7jYmmirq+B6NUI6sge4ttx+3roiHwCCSY0qIoTveeRIwEte9yRA9IQ1+qgFYaI7zILep
#Hy3a/wIwfuURZ9NCneXwKc4sHs6CFjpO7PTLJyiYd9AQInCfSUUh0GGuSIMT19ZUMGWU4F9ukTaJ0EpgY1PANcoHvwGKLJ0WikEX
#vq4s8EFVScWYpn1ewDoojqUgvuoM7zwluBccOW2eWKiUh/5IgEWUsidMEoMFPUgiTnU42+oDbuh+RgpGfIEIJMSUOSncY2PCoAIY
#bmP+aowiotsZj5B547fTW889YOxwsxucISgXv9R/qnqkpCcmygIhcw5IebkEaSFRtAhTP+5PDTIoaJmF+uL6ps3hvlvQE3RQb5Oc
#KQtvX1QWkUDCRxajGuOigQFxodHz5NHiNoQvjMkj+I/BSRAb/OJBYugWFQXJyXt1+KqLrWiiIm1i+Bgq8YJaxGOSb2RXuN+EC4UL
#BVAN1UhTHJLlL4WCxNus8VgQ4GbciRmmB/YELbo4peVy9kT56SkImp/UsGK2+lnynIYhzvOJY9D0Wy9VPcfPixCD6ByuoY3/Fvwt
#jdGTCIV8gzyfgoT8mLSOgpnei8A7QcA0L8O5mu8UwQViiWpbeNRebIF07OR54iU58r740Wm2qgXMvnb50z2xZVJFLUOLfjXB8mmC
#c1Ku0DDrqFVpzEKNLdJwVIp8DBReCNtvCGLMJ+J3wa+a+Iouyl7m5yaa1b53mXxvkfBe5cJiRUP8SQ7FCxmuatsmevlT4m/IJDHS
#U6HLs7shy002nzqSHrGnwqclHfYzU7/MHecwH1xyNlsDLOXBEcdWw51kbLj5SZ0uuIdZrhMc772BKW/dCD6ojMEOzaV47rNOtLkc
#fJcUQFexzZXEvbTCpNF2lyAWryR9/rQQb9OQf3pMttSEmurehuAesidOju8MAJKKWvW1hLhQjr0D6WiL2ldUTzbiYvuwibNFZu6I
#CWG/KN39dNbk53ODxR7SNeJKmdpWLsWLy0UrFby7ihFtJX/u1flK0TYyf66kf6A9RS+TkmND+HmAuItmnhBXi2q8Rz6SWEWMITSC
#qmmPGPprCSx58pfnxdzQ+nDZQyi+KLba95vVBvtEH8l1rlnZ34gHftFLXOm11TIZcfVDgCh3B9w6Ehk0uDvhVvummmya54Vt5KIM
#iKsmoSIFASAU6h16NFZmS64xWsY3Vb3HccIyroNpocTC1r75fapcIk9HKnSYs0dZ2NCCugokPYd5LZP5KL08YrkFa4OcNFoMkpfz
#ZZibydaa+ikTvURsbtctx9sAiYaP890ZA/IcT4i9OmLPCpX06Lgm2rjPro7zMMZWoS91jVVg2EArAR3UiUeX0KedvFuu22P8qYM1
#Z7IXn1vLyMPCjODhEnx0rAs7cpv1Rc3Qvt1nyqB8y26yHaPSNnAfc5ij+KaipsbGRuiCRC8nR2jrQ1hrUJGVNex1Sjm4KZPlPVN/
#8hyTNEkuiZRQS4uei8u2UKzQmhWhgycOpmLnzS4WrYpIuQrZAmkoXXo5tcrzDLU8vmqfL2mEHCrWczLPZbEKLSmi4jiQOJetmQbx
#IwkdBWpGStFzbOm1OjygDNun0SlJpRGInGFmSuN7qDJZal+EtB/QLzC2kbGF05ocZXNarEIgfHjuMd7hgRvWe/1EGto27caMNs9+
#0WblMyvSblmCxNFXIkU3ZUvENSfFa4HQo+PMyIM6e7mAdvNsKHmGTwgShsiKHfx9gNdGDWl2KVuC3/T8N+FGWyg+eu8p0yrSxtO7
#9xSlLaksoefusyBUk6/FKLOyQWtZi12oViDDhcJU2oQpVAemt1kKw1zLJpXDR1KOqBUrhsMD6VT22JVuv5y8wywZTatSqZDDqczF
#tCX8ipfIusCj3nKIBNlbzYXoFsGiLYOlxkcZ5ZI91ZP29H1l3f4X7hLIN+UqmLeypQIjnG9VHkfhS8TQZuqSFrdmp1bcok3bQLrO
#UKfjukaPTU+vnOphxIcoOb9QKsJWYEhAZCfFxI/ORU8GMUBL4tDnZGlRNqDrIBKK0RfaZcFg0vZinokzMCAtZmpRlHtDJYlq37/8
#stNA7V5pbZWNHXjRJT0SD4jrkmQ9T6V0nC+fc8JnGdLM4ZBoDthBuKdLeGO+YbcVWFEkF5XvXcKeelcQQm6JQKck1q8XwVUUU1XB
#oiZFz8WSUjbbEeflIDucNacJqqmfs0XVaZDNQBDV8lVtJpfJDTol75dBxalp0bPoRbQwODUfEPFy0KjoNTp7mY+Tu6956ie+rlxn
#s/DW3xw55EvSTOHq0ifD/K/Cwllx1283UpRfeGHSmsV1vXmjMnmuwtV+pOG0XK6a7+fNz0GOCgF76ggouCNQeWqdXPDcwMxNA4Sq
#XPnmsaw19REtM0Vj5TWFZr3akXTewrz6YwetzwwrVcyWeidqFl9UhmDzP03SvT5v9mYpKOiEHTZVFfA7J5c0W3yFge88Mo0ln0ng
#pBgeauR2Lf8N86N7gPAFHFJrJusTU4wGmSewosHIp7S0O66wdaGGLkD69bTWlMIPcB4iFSOFQ5Zw4VpL1i2gBhBvu7Jp9nijLcOE
#pLbxVFZ9z3NAvViVALvX0/ndt+iyrIwq5NSbT2YrTabDBcPKNQY6sYULzbO3kGKjY6R691UfCXKfVLIEv1UYOsTtfYw7mBspXT+B
#oj682mv1uohnRsxY14TMkizq0ij4+XrYQqfPvtCQT2fVRm9krXO3xt2rvOkyVCxhlptB6M+j9856BWfQd2Fedzi90EiEGgphe08D
#lVULJOJxHfh4Xpzjs1j0P67VaTTiZgrsV77i7O4muxo0YcioINQmK0bDsMFsrQaZNyS9OGCCpDx4TSbrQgGEV4Msfmshk91oMZbM
#oByA1JeOma9Gp14rVkI/X1G1gDpRWrm+sRck9elmCB1CRPtQhbF4Ocfg/RE9MUfJkkhzjQ4CQnSUrExsdXeyuoqaa2FhyfMPPnYH
#JLXJBEaAV9cnu5kQMEhm/iRverWoCtP7C3+4Wsb5s+EkuodbktOdbmbr5/Vf4b4MvEvGTKNXryVPL1fLI1STP2g/EOZOswPMzEm5
#MoizjjtRjA7fPdZMBNnFTenEVQ29zbLPFnO3vfz0KcUfGJgMbfN8bR3LUDjshFjFnpVzmQkAEybRT1k8P009A8s6v0h4obU1ui71
#lYsRfzNUGp9bX8/hG9hBJSmQMCw7+XAlo1Q8/QuzzJyQgyQonkrE3xFfCeeSbUWXIQzam8bR6M9UeJNpPR8dtsQAsMSr4ynl2gVH
#+ai5pL7A6YSDf0qFjMm4ccO3jyRx9thKKBXhsSg8hTQ+XfJNZi/PPbNe4P7JtANeC/9RkmDrkkk6VddZuPegtYYDejHnLKBpgvWt
#wBlj/TR5bE3rINxjh0b1WC5ljKZcQHkoLgQp0/PaonISeYBDc9yynJq11XFBHoQ4+k5WhozB+IGyBYnMAN1yuzsS/y0NHrP+dBkU
#mcq4jdhg9VJSUsxbZPWNCcjAu1p9BKUO2vizNQLZAWv1Saej8k4Ttyj1V8D85BcD2WcVAUEfohHowKpg1CkOK4aZ3bTHiiXF2BL9
#KN7RJOiFiM2EplRq0Rw3/oI7jthoIOnNXil/YKHZhhIZpQH+nOpif08ZAhkrp2eXmMTznntiyKjyF59Ncag+HzRGWNrHwk1zxiui
#Lrps3rutiLywE1lTU9cM0cflTp/f5tM6wdqotyadeOlg0cfytPULWpcsD+ToZXWJqjyEiIsFgikZCyl2sHpU9quULcyXfZAGp0ye
#zM3wuEwjRXG+mjoRFieh3jnXPauziOzh+5Z+gcOJAY2LmPKMTatIDDX0XjzA5AKJESy7miajqTaH1t3CkyOUmPwgwijrcJg2S/bO
#HdFqMy1cOHr8jlBr6VWOG7Yv0nRYgjjR0VGQ1KRPS02w8U1cAFbPcilTw1wCo5J5srkzu275MZvRz0lyH9+tPoJYfp14k2RCijeM
#BAFZjrEnXQUxQKDt1jDfyvP0VZPCm2w94xViPT2zwX5zdkY5WBtWnJGkTRSobKQ5QsUnPeYAhTxFk4rkU69i2j0AAzwF+fCqxO3X
#N3Vo4adHI7vnkq70xgVBAgL+EDv93VavFHTEICA6Lt67I39LwjbOWsVLgDpjGh+7gBBkBMCTwENcXTZDvFvGfgeaMTNJmuTAEO4M
#KIqH2BHrzwmTFpecZaP5cLFqmFQYl/XZR2+yJ5uH/UNfuKsHU3pHpC+vXZbhOF8XRIYhL5cHQ63n5CaaCa6UW2yE63ZcvhE+HsNJ
#hPbBy3ju+/EAPgZl4dc032wghAK+DohCvNuMPTx0P9hsnD+p91487+kI3L3zFoGAYIWIWYO9UgjAhPnMaozoR7mxCNhO0g/43MMf
#+OLTC6wEH9t8D9+Wtaw4N699TcW7BKbl0Scas49B9S+iaZQ8LXFFN0ZUTNvgH0cD8Y6bzSevJq6HyTZVN+KzG+O75gnfUXA+upJo
#wntufPstf0jJ5zit7Yjv4zPpI9+Pod3kod2KnhOPu29okK6m7FbsE/H5bis4MRdtIw49VoCJFBI6UJhiZmpIfEwczQL4bubFWwOJ
#3CSQfoIfmOVeICRvwdilUao+oiNKKRlNYpauFfDHPqzIBIhr0GqWyr3Eo49nmWPpi9e0eyoyL3QdJY1r4DwPm2ngoWrSTnxBRHL8
#AcoPBTNVlfQzfxalyGRNX4U2aXGJAiOxI6QaUL4Zu1rr2X1ZmYYtQZa4/oqDF+aJ0PbWV6RqI9GternX+5lWEukBl6Zxc2cJ/f12
#GOF7rpTSg3q9gqLF2kGyIVVRpJdctTKkWvaScNbK2as1iG9LpNBDxijfui+tMFA2ekKNckS7mcu3C9P1bye/W7z9GqyYwBTzbWcP
#8vxjPKY2x9N42gqzxa/mjD4XMHB8MQ1z0TRUyD6arhNwjF7nyXPXmt94mG5V80Oi2yownvN3C8ZzVSSabQZY8MRM4I80ZPlK4kaa
#ywtrlMgpNDrnwhJNvMa3Wfd9RCnlxAO/iRmNDav6uaC9ESq6UEEq7DlNdUJEi3toik21DU6dBgcU1yuzffGWeLlmPUYYN9S5WJ6a
#YSj/pJzFStFCe2/CuQRyOXw77VlHHFh3bQR7LmRhombr9dKR0AC+3I/6gRILLVcZyJiXbaEOrdeoFU2f+jKi+Q8ka0ISUmlAy89L
#3SpixFQAeVBP2kWbX+nwQ4p2yJyyUgd0bWG3lzHAqSRqDe/FvBmy3/vEt67BU9h2G0xJuwUju9HZCg2jdiySzeaI2Lz1KCXHpH3k
#MM+guh1V0wxb3luKKD02lVW0Cc+Wz4WbVe8NDP2RiCi7/oHGE4pjizF9Ci1jfSYVcqypsN3PfTiaPO5BVWk40oVKBvzuFWlE4ZWO
#BVoo1ZMpL4rOs1+tV2QEcUjsv/AIyTwOmRfM39dWzle7Y6TB4dRZu6jquI8n8B3NmdSzGHa7dMfjTLg6Km/N0c/Az0zHK6InxYWx
#GI/9wCclKw3KKesl0XqpteBrURoMiSj7CpgmR/BEDvElUCYXIb3KsqD6PEpsD8eii6mmT2KQfenMbQbNn14jwkWRq6ig0D0Dof9S
#vu0NZQkNSOFFBJfE27tgsYWkFrKx69YbCYaDZLKNmXf0ZC9kYVap4FAww0GYyFKyEE9S0BVSEASoPr8WQSBDVjtpbf8Ay/nZ+4ZW
#2j1pQct/TPntuxohxu4NciLqrPps8xEa7in+sjI297IsOiNs5IHcLfHPJVeq3+gg0wqacazxUcieQ6+tT6d37V3oDHG3oTnPRSSB
#lNc4uyTFIFFEHeW2nlafY8G7zMIgmJdpaMFQUyzGFYIseTcuHVt0MIzKZEVmMXrKoODIWclKs/qfpVqz2hzgFDrBSUhsO7JlUvAY
#n7bJYE+b6Eg9Jf2SqDJgPeeZE8NKrWpG2qyFH6tQfoLy5Qjz/HwEUObNztiIcTcM6AtfTsd//23iLc8ymlhwbT4+J+PBUFPcDWrJ
#G14lLVQOOrj26EPJT9xywbPmJW7XSZKl084nZRoT9M8bJ+0l1974apDLGGWoEhhc0iddj/WdDnWVEaog1iSlLy6ocOOifq4/T29R
#lBClH0oWfcpexpD82jOLItn6kqB+mxwF8URELoRTNWPeQzbPgtKcRc5QT97s4AZxqK0/aGWIj5xpYnV8ASYSM0sIgvCpB/tThNfV
#On04Vm1NdTNRnMvZ0PmSnOZQ5guA+xxTCy2LzmXOWunudvii+unBPpJnjS8vVYjde965s+O8bK66Ymx6/iR+YWnwpZL1cbFyh3lr
#qdIFq+mYNh9s80rPywqTp4qrii89hNXjRmiRiksZEW3QsL1s+YijpEeZtKB93gLd8VvGB0aUpTOu4rA+eDdvMETYl5bMfPlY8jib
#PYPbX+uz2KCotXuOuUXO6JoVsA63ZD7EIvt63xEva/8GdYNkN8CikZ13uGcN/7nsVDxhg/KwLyXtOSwn3Mhhp42HEJx+NtIXKZwC
#CMVLK1Xr6ilCyqeD9AdBltiPq6xCJZi3N9Z5YMlNb3iqHGMlhK2+HAdnQU4SLpKzDl+z8XBhPWZz0HhDqmpb3YhmrfSygZ6Qkj6+
#TvMK3/dLs6ZirETNWYuSQoiPFWezDAdfYG5SofhOi+5N6XZUIaVhhGbgepIfoZCzdLkU5c2wRPxywWHezAxQwa3OfOCbyerN9JWE
#osxcP6rPI2rJxJEZc7nzrHYkRfm58/4zFNqv43FCTUVTH/fYrXBycsu9o/OvrzLvFm7zQ2wLnxz3x3JqzbvT3lBngc3Cz+4YOaJe
#gAqihxgCgreev3FqGxLibATinEvkDjY4H4oCP7ULIzAKXbRALiz6xos87cS+zxovnR2DTv1KCm5fTsFlv0Z1u6jLAFZIanD0mQ/c
#VXXEdCRrlkGM6Zbf1T7XC3gJS1Jym/i5AWQpExQ9U8ZHNup9C71pF8MWvjHJkryKW51uEzbpVZ9zumJGNs05szFHPO8oz8e8VPle
#1iyVlRLSulYATgdyNOR8ud3go7cT1qOdQQ6DPhdt0zPFm0S2RHm4lrHmRj0CbzlMcIpW3Es68nZqZdLFYMznsKkf19RQLaJwIt6s
#bFWMRzDmCl46XrRngprWtppX8T449BykEaEOD1Td8vGP+MSGH1b2X4W/CIrtzE+ZmlgZ4gnPetll916pzHyb4G4pfOt8SPbA4bHy
#sHtFqAoHB45mgDe36k5UwRjEsiQlSpYIbSoCT1XcMwwn9HzIPl0ixqTnO8ENjdN33VoVxL0YRAZuJGchVGnD+CoE6jF5SpQvWCLN
#OZ9zWyM+K7WfJKGKMNxDALrgKffTrQU9sz2Zkg2phogP8Foa23ATt8GEiynfcPA9qfzgNCyt+y1LJCpzwR9T4alUMPY8YsGYIHu4
#Q07C/Xj7nu2nLoudDlL2Nbw00qWPuJEsGxjBBGFSWU59A6Fq2omFUwam7mL+86qEWUX5L+qjkkmjeAva6JOmhY+49zXGEEOrBeai
#3ojoITttdM6pmbW8y2O+oY9c2MbGHhDbAeiXBopc5hUYM1i/82wYWuSkDMQ+RR2E/ICpiKAWB5lkY9QCxQngEApX7xMH7NOPVm0b
#gOS6YMP9bfK43sE5COu+pSvypRTdDMqZpXeWi2Tt2Q56G80ehSqGN8tGtSLZK5pqQyu9uqXOzDyE4TuVxoBiaWTWdj4S15ziVZsU
#m6VWRKTHBHX4ykZVKLMioIURH+VSSGev8UanUc8qR0bHpDxvu+dsDPlZ+Xuj4jn0d6u6+mvPdIx6VdNfKigYXFVPMOePKwbT3A+N
#wA3FQM6VYQ8SkoraK4x+pumXJaPXCKnXjqlzRQqyrYPhhPRtMd3KSelelRge1rAoSiEjihF9WUrLD9/7xhyqeB0ROCWuAD2IpNwR
#Zm+PrB33BQX7jg6C3VrueLjRapV7BvZenZgIS15iJbsygu2at9Me/uXu8b7zCMJ7c4talmwWNt3qviV5qF60gGwN9B0MVTWmLO4F
#V1RSfwO1iOY7uCUY0YJgMT+0wZ6ktVLs+KS7mEiRzSwj+m7WadbwXlIo51yhYuTGZJ8PsTAFspqfhj+S1UsdBJZIrRaV4XwDBF7B
#3slbBUj1wPFPU734eNzTvBn+6jVvfVrvswD49AOD4h5RE/mz91LOtulmtALQUayYMaVqVs3zfZEKeI943M7Xhh1RFpG8FA8qZbOn
#0rV15PxpGHAD80Sf74siby7ahq1K87bi+uL5fRScZTecTNQXtUABKHnMcDTBR2Jv3vK7lFItpdSxTqFBvVsnzXvmrzAmPJzc++1N
#shzwifVhIKpw/8iNrUBZbE5vR2lbPWLfaIecGVpaYBRDYEVJIOkNPzK1yp7R65BPROjuKbo0TX2bCcGf5cb5r7Bqjm+Yl2uj25m5
#rpIROjdkk5w+cz52XngilsOro1kJ3WDEXIge9zExbB7Y0o2XjBoyJI5pjJGA4ppGXbAQjvxEy3SiWzKWsLTGH5amAAJRAqUAxLmf
#aJgKKVJ0MX7eFaDRhzeE4hD1pIda82w+BB0eC2e4ak5KP9Wv6R3UzWOx6vdreolZ4+eabBPhE4R2YmXPBO4CcMQXIIOdThY0h+Qd
#Ry1SIvCuHo3Uvdk3l9/8gIN5UqZycv4V1n15dCCQ6d3uRuXr6OoNpEQdYx55H+vXH2cba5xrbc4/pbF+GxDqTJBlp6BPfSmTJBb5
#tIs77csur6CQDPpmvQ5o1CTHTgqXHPYVPZlUZHhAYXZkWZXY06p3bRGwFBcD2Fat0acmruii21VXTX7BtE6iZeW7+gHOa4Pv9tUE
#P1tWhh6lPjkQqm8/yCfyqZW2Vp3fIbIL+zQHcHNVJwAtbJOWiaPNv4mMDoNXAqEvUaGuM4io5NLljYjb9Jid43+Gqff9Yv0iwuoy
#2Da0/JWVK7U9WQFv0643QjrfipoXxnx1qy0rQ7eZHOw4l+Teswu9MGEaSmnHw8zoZrHPrahyE0VlqrIrITyjn65xxN4lQy1RmVXM
#DkgdABXHFs2NQffKNl/K1fuXel49HgS6JbBEHL86sJofCzKZtWXVIu47cZJ77x5+sz7KUAoTpa8pmdcjUg/HFOa2Sat3FbXziL3p
#dcMmBWadmiuo+NmXWFBOvGR0sQ3aoS5mSSq2uSSO3lc7TO+WESVAK/3JmjFxW5UYT5r+LZxWLonAmc2nKwrKc9/nnPayJ+2st5Yr
#oG9a+JLYusP1+Cl+koRQIeqBNJC6JU+C5IC9tse1z2n879Zp2Q0l5XU0Q6dscDuVO40CJlPw6On05tiqO8Kq/bC1SDcYxireDBgh
#fy0/boJ6pjcq28jXt5glMLcXIMnZ0mZvz7jYpeD2uEtKJMNpj1wOk7VW8WWSeMiKtPmGgr5jDTRuFBPZUww+LREcJwpFRZWGWzLq
#XpnOcdGX10GSNeQa4htVoKrT/fwVSN3W+g7gtGqV2kdCI+eNZK3FrzFv5FknJffCxV4FQJi2G4AwYuGNB/aRtz0/QZgGbTnJtFMS
#RcKNsFEzMYS5vtnZTNLFjepdkgOQ28IOOH/OZ7Cjf/6iU5kYTz0utRIShdeOglw7AlLemZI9J6BovDyegfLpa6Bd2F5yZe6X0JdM
#aaRvYb7Rqz8LpV0iiwq5PbFq5kmh1n3WuJ4dUUXnK7usYqD2juH150mv44BVPUsT6kI8wUDL6xdVRhP+av5ECe6f+t9VUw07ndkZ
#S7KHa8BlZBMWEIkr4JpIW8amVbi/fqP0mdYqZdxYvHqsDCSiMhTHOWgayhkUiIRC202qivSotakLz+P2Oa5yfWUGK66vqfC68AX0
#8/CgS0L2pR7PwVlMtEnsbDTNqyEEvPO9bPX33micqiM2ByNbvLV2YlvNMHSiBAJVI5aR7wWZoVYDG0yrc56Lnhmlm2G8UBgn28lL
#3erkuqxAUGOXndMinzfW1MR00cGkKWTFkNF7W53ia+mh7o96qIt6O0NPA9TN+8AiCBJSgVf3euLD/6X6VgbAqMZVk5IdAUcu59dC
#r9zJLc9qEhZ8nTEsP/00eOEgYPYSW/LYlYSqTZeGrfTtwCRbhIXmMfUiPh85C4+2/oUIX6eUd7YQpf2Mu2CFuA5zgFIidKC/bwW+
#vaeNx+WjeCL9+QP3dZLKspXVvHiAHsvG3sxzF018p1P6+vAobbv2G9osLEvNUtUtvyMbQsotoVDtWzFGAk669+Gv1C+IIb0Omukv
#7MRcax0dSl7x8Cp60k6ceaEEdSBgIe3pqRWEDz+Rw4LSfDLPUhJmaeVhqFSv93h0myiPUu8l0z1y5i2ZjTPdO4ORmnxRNKpgTijF
#/vlcGrF239sF1FVyrfmg6Ju8OUXnq0EaUjc0zGH94eWnTdX1goLTwRd3zwwrTRjNrh1HbRllL5y5sMPk5u08ygN2NgPdS1MsTL7e
#GbKbihdquz4rj8AlaNR5rBA1qwj1OX3gYwriOSlxhdspACeBgDM8cUnvqzPI6WlBVear8otHRSWoe/Y0zw/GzYi0buWa6HpM7z8S
#po0MjsufF8Qid1DfxwTj3db6ZyviVeuMfzFjpcHgxbk1szpyiVBG0KukKC7XROcQlhBxFauEa7nEk/ss8KGhJEkF8V2yFqAVBsfI
#SPFWUzUwi3AqMFM6MrSCepuwqUfaJq18EcEkK59BqcplYaJUWs+rXZtC3NE67R3UhQSnag6BjKkVPja1YPrjI+wzY7QTssU54oSA
#m0fv2PvCJIMoRltwuPY4bzduKLuKL3qPuq0/NNtL6mZp5kMnvsVTmA48v+IgLw/wzDS89Uhf4mXVXx0vfdy6t1owb0OXtvwYZuSm
#HZPYa4J7Cfs+XlvXYJx5cCEuHOpM6i6pbpSldViUmkSD7+Od8U7EuVPRXmikfoOhzSRkgN4bXj8uI1duWmrfM/SmA+7GbUHZ/TtJ
#SebiScGqFGXoQNh3lFfpHWdYMhpC505nfep0xNgxWvIv0bugyFaeoCxV3xV0xnx1F69WgTOl8ldkzr1dJO1MZX4FD7kBvaPbM6QY
#h35130d0uem3iB8i6roJy3qKSV6Kal9McX4XD/dR/ojkshcJ4q7cQVmk3NYXKqhbQlJzxQ3h+O7LN6Ze53WaIQcUeVMLtQTmMBWg
#b0aoACKEA3toY/76x26rpJunCh9aUTysmER4EDdTHfyJCXK5Ao5ibd5JQxy5qwTkpiLxHAkeIkoIrJv0v0SHgIOInZDWoWhqDP44
#bGK3MiwCF6kC89lP2r1/Py4sjzN8zf2D4d7wUCG+mJblXbhj06uAs/Pjooay7uDXSEZkurtNdZpOyB/e4U6XKO+6fDibR+RD+DA/
#pdDf8oGzOM+XaYWffXtMYCFb8BJKh23t8SS79yuMFUwI+xwKq6+kxY68CBQQtKSAUBXIILYN/gA0pSYcdg4TqTMoiIyF694nl3aX
#Yoqhu1WnmrrQfWanqTVqF1BG6fOnOC+KUknjVNg0SHl7CQmGNaxqi7S0YxMUVkZFPLI74ZpxdNK/OfWwovRklQ0oib947u5VMHGx
#0XTXQzusImKLpHu8Jzmhkm6QpLOutmBi3H7kMZMmiN68Ika2wohw7zzYva/rTxC+2VEINzN7X8O+zVU64BYdT/pW2xWD+qhnV9kS
#qSSaicvHVQgQWPwBglT2LO7ZqPZUo4K1UTc6J6m88KMmF53N6Cl0aL3rOcVQV5ICSBPkK2K6D552r3d5B+yxS5zfaW4Jj/YifaTS
#eizb2j7O1FgT79axImOuz21i73AixnHk7PWcE5QZ50v8ZNbDBunJ/ReCWAGxD0IHs5EXY1HMSdhG79ZN3+F7GZAPYhyf80w4z1+k
#7g1EA2Wl5NFEvgzTRPI8tayrupHbiSAInRcWDCOdAHkCjpzxG0iOw1/hxqoDY9UpSM9Im+CgMBq1JenTSuFCucwfLbYsKTXI4tTq
#TOCSwTjJzn/W4LGt8wgz9/ClfV8eQGvZ9PhScIYzy+booG6FT8kkTDww0LGSYj1q7FMNVx0kBKRJfAAI+Lba0lezXclKD7EHbvnW
#Ka/lTTWnmRHCORVeTs4UanwzX0o89LzKo1KsLC424j0KFsEktxcoNbqh211ntejPbpkOYo9VOhNfrIQVxA4eTPivaZTNcqyE3k1+
#gZsUY4/ZfB/i+7oboprNmwKtzN5ar2R9hHDfljZ8WiTPq9Wr53A1Sfbb9pdd5kjUgyi6+bfLq0ICTcncTo6SDYyY58tdbLEb+TyE
#SZq5GqKNzlraHbunS5ZPlh71EIFG+HOr8TrHbNlTPj2ru+Tl9p8JG6Mi3pioe27sCyU37BFb7rmxna+HhwxAX9kD+ym8PvtIRcuK
#xNTJpUBcoxPyZHdqYsEwQn5iKnquHSyGxZ0pFmDpCQnr1jf+sOeDrmH4HOhy8pszemjSXMXPAeMxY9p4byDz4HdfpGNciQylILgA
#yJwRPb037ZqXoZulpYvwQa+jEHHogFgwlqZhyPfcUtCCCPGYcUF8pQbSuFBFc3v21oH2cM4xk3KONjXZ9YkDJVFRa4S0mt7swRKG
#jv6txBAvVSUxMyjhOvDJ3AooiJheajmwFkMML0JThw4W6rVnzX9UpOzAXNqHsI4npGDtbrJIdqNYeEuAREguVyvRmwCuKyb5MphX
#oUwhIQpX890ltlkHtj7FXjta+AWo19zQ8OVOWqvyGqmEZEKgO5lj2U6Eheo2b36IGkGHJd0uqGyuJPySQTFZ8JW8g0/KO5VLInGU
#92bsVl4j0Q9LG/agF5b1ssmdTtUmCHMqd9ROxt93q0DiYvD65aOGZTvnynXHj/1+eSMyFj5+BjFBpOjbfkSFF5WcWA1ZszixzDPW
#F4S6VLEvYnUgTuDK3mqs6HEF3tYlDrbv5dIdtBdWyqidjxgoILV/qVjtvf62RdO+/6575mqUh/0DF2N9dyU27WgCVSdrjKH/DPF6
#KkkVMrwG5z2pz7kdH4VmoJ1tdBY9apRaRfdUfpJ86zPrjf3oeZ+3nnNS5A4th/6Iqg329VytbUxlvcYiIW1fXxb5PHsme6X63kD4
#LbOQkFSRwmr/3tI6jUOMTAv6FerbL5XBT45Ma1AUwilGF9VafDikFh1iFsv1Ojm4OhdXfRUa9hzyiYDAzi5rO9Tzlb1g+tU9oCpx
#xYGEFTsF+biIDoIIUPVjkFabh42CClyPHUSavjkW4cZZLIoHJAQxOia6BwRLuqsPEkQT1DhDOrDCSxwjTA6B9/15vk83qdDdFfcL
#yPdshF8+yRhWG4VFLfojGrfDXbZFbIUCjM17tfnzGSWK+drkbfIrtJQt4rFtokCaVVbL+UpvDtiiNV4ds5jZvt1fyBZX0L3UjooS
#TKq0lQ2cwlvFPnFEvGp7XGxz9RI3IEd3+8ZFRSW/i3jDOfbYjGbn7P1iZD6+dYlw4Rm3VCpj9mhmWgqimX/6Zs+hFwTrtLLRo4aP
#CrH7CS1EN43LA5+mIjDEd90EO93D5IVhClVxFhN6H1tzZi9DDxfV8xbWErJphp7IGz8W//o2CQajkfgtFaFwMK4co2lFewnquBK6
#2QSnVeZQggXetxU73tr81htm1aU6HVkby48kXxN35sUHYEMDG+bzTbHGvmVfKlctYEsCvxGPWGvQ3zTmmnNO4M+rPr7dCNZKzWcb
#fGTNoa8XP+ecCi8QQB9+zZ86/74GzoLGM0FUiNA7ti97bdlAPfXiYiE7gzBJcJVfxqx0Vx7NV1V/hEbyTaeZ2zJc9I3It6wzJRtA
#bSXhzaX8rW9JN7Weg9ZsiHnMgCdILWBh5/P+81GpBq9mvYrYZirW7u6u9aHTFhqKdtvdcp1VLFXbKv4DnS5rijB7iEq3z6HLNEfR
#Q5oNiC0+gNKYDpwG1hYf8lYldlzxEIhXKBCqnJxcAW8OEUH0IpzTBWx32l/wIPjppb9ETcQFThcljFW0O051k6USCXx2qCRztH2W
#RV+y/Ggw1YZ7bCPrHGNKo171/C1Ef68iHE5j6shwvvGn2zlxuFBevkKtsk+SkafPbVp8qtYWzj+47dh9zSfU5mYSbuXe4Z1K4OsP
#nGLliqHfe30z10bTKreDN3mfJxctTyf3yqLy+anWq9hAqI37x5eLrL5z1QYTmt9o5ayqyW0XQi7KoR9Vdwfp9Lpr5nhEv0vHEt8I
#ZKn4DDRvyMkIexysgkyG/shmnrWBsr743YXorl08DQDjSl7aN1BcXNsxVRfj7GtFbaWWsq+jo2+6jbFmTp8+ccHHeXLUMDYEzhvC
#qiFcjuSLoA+OCPELNlO9ShAc7QUpqDX75cImlaXk0GQlT82OPqJNwRY0mWTU3k1JQqj2axWH7FsoHq508Nh67KFcZou/pjPr+4AA
#58ATaBKS8OYrzdWVmBRC9X1cD1HJypWnf0Sjk0ul60UAjKje0ZQt2YKHMc5qJoVFGNLx9TmNycGqC3wI+YQndk6UWqzbrSdRQvH5
#uRmXltceRzzbodvVVikRP3qYDjzJc+gbirD08AN5FUgy8qfXJ+45Tbvuc0mxZ5ELM6o+qkFZG+3+VAa2F8XhFT0sGHPmpcYR1gY7
#8ghVpM297G8cTy91M4/eh+daU14Nu2n4Igapms4QkyCJCeuGNcDFPU56C29OR4gnRha2molcQ7/5JFSmIU9htCJjzt29WezK6T08
#zuQJQcDng+5Og5P4/fCo7o887OvLhW/3R2RWYNNwoCzuuM62hUWKWfB5mOWZGfS1jFMr4de5kTeuYu+W2+42n7Wx1xo/xSpFR2h9
#byyMfuR5kMxWvCFxKMicCpEWhYAxJYeIqxjMgeCnDnwp1XX4WXpl3oSC/CJN0zWLAz5+MmQtP+ocYhE4RD8mPybF984KXUtkd2IY
#5VHe4xhCt0ndun23D5awu6cmh4ftDgFlg4uKnzjSMgif2hbRtQciV4ed6EdBbUC+qqt72RW9pThxazEn/uG9aWDPgm1TjeXES63A
#6eqlgAzgUksmNzGG4mGGkjjBK9LePYLGdIAn+4t8JbCh9TVbHBMt6fJzW/iMFmyEx+QbOjaFGM3OG+lzm0uxpeqJSEW2TbY6bMEa
#bMhIHz9q1erm+HrUMIL5aVQJWMTTEOZmiB3WO6tUsifSyGi/dMeWG/qthTKqTic8m8ugQDDGb4d7x2dyNaItiBJi6EMxybHIax3e
#KqcDVijf14xC5wh5oU+hTTIJPt5EJ+teuqwNllx3KdCij0ud+gXAvHbCmoQa1EQsKfKYB5T4vXbJFVtviRzrn0BniphmrF0XhvgW
#g7D0fgzTquYT90aXWB1QvIuZGOmG0P/kcVNdbRUFgaOjMjbgdIgi8pV2jf/oKwKcRgrOIz1ukD7dW8fFSsqdgxpk9zfPcBBhkxdB
#j7UNn5TGJidCqvQd6h3D7V0dp+KeME1QO9mdMemFtM3nkdcs+Jg7xI+pan4Jz9/CR1shWhFroX+Dr83h4Lrcqp1Fe2/DjTycPsuU
#R1fndXkqbDvwVnu9qtrv/h5P6fBLnYAsO3zCqyKaQK9T+OR7mZVBuY46kJQ023rDwuFyGP7egYOaZy+j16zdkso7+Ugo/Zd3vsGu
#Zi2y7M29NSqUrW2V8XZt9IhTHq8+oKg9AYmbM2M7PV4zcruAGZdSnq7sIZBC3QZYwmbPnASiCSK/NXVNhJNf+OjSsPrWeyHiInpn
#9aSM6ov0QsbBUeXEHHPUI1THxk+YYR/L7iavKj5Fbz5uot/AfNJiqyOrg/Z0oeNOYDD5/SkKAkstjvlTQ+YGv8eEInhrPqZJiYS9
#pcdEZWTyQLVJiqH2huGd58l6iWbFARxTb/WI0Voizvxveh1qLImaQHba9Mf6vMULq92kVWpK9iomGcQZw5Aiw452j7oZz4pv34ZI
#n33aufW+s+fAtEfEu8rQ/px5cCQz79Y1tmB7TpLVWuizc5TWltC+a1Q0sy7MVayBVpdVotkWP6VKd6xvvlLtY9cRHPoNp8Qdxzvu
#1dLIgt9J69jsy9fWTVxJsiW6Mv7RlIo4kU9r78f7nyAW7VfP8lb4K+e77K6nVFYxGdaVX33FHMW5F5DQDLicbFHnm7BTbqLCvGFn
#3j8X7u7R//xIufXTFsFCR0d7L97Eimpaza3SpDBccCD3YpXUWbm9O88i5ugl891z/wFATfXhpFK62W1OnJTncSNXSVne7pds5izH
#xGx/I3/n/KlvDjJeiviV1Qjaas7h9O0kqSIvNo1a9rOjshYS3/Hg5fJLq6HJZ+O6DufXFEUhedggqg1ydclJXjsejlRJqWH1dvkc
#VQQWx9Wgn5L55b36RDKCdsyKWel+pknFlUuvIrm+PZIENNvvt4JZ4ERlodwoy2V3XSSyqPmii0cGAGYf3MBJflVbgTvzeJ2izTdj
#GL++FuxA8KTK6X23titrn9riNXte6DhMwQwKYaapfqCvhv6Xo8mog6NdqNoO0aewYQuHr3qhv5gDgeaO6JJTSjQsqh/KvWxHtE0p
#IJrDJfqfqbxEU217JHH7bhaSIJl3msL7jVP4nNJB1hgPMuNtlvZojQz1emaNJpKwn4aQuk4ykgEtfTt2eQ3gMoIJBy8PVH+leXaz
#Z7YDgghDxxXHjzgBIoxBOLoF9YSjZm6UCC1l4aa9ddCjyrRKnPqAd+l4E1VktCL4PErYv1KUiWRl1jBro/sw1bfSW/nw6q34rk6A
#86z2wIAj3BxEAgkDM9Nmt9Xs7nu76ECvV441ULVf2oJ2ZE/jVL+SECP3xnxxuM3WJp/HkNzGSzslVlZnk9wpaK8wQ4bbYBqtYK6T
#4XzK9uzS7Dls/tXNtsv+5giLfL9G5vZW6zJ6UtfroSr8QrFQI1+qfPamcKNevM9X5F1BFCxE9mLXzCYvuHBh2WhD0iv5hYLjXGno
#caQR3sNzk7yZco+t48X3vDFSuSGjNIv7EHRz3+Xbahyi5E6bbvsmSZzwk14jphhrGHBkn90WyyHPPWdtgeHtBn2TmHWRYTmo9esl
#yQi8pB9Zxwu8Q19S9Ll96DQjadkBvabWrXdyMvo9xTdrARHXHHimKtC1NibLtxmEOqtDRVi3T4RDudBM6cKanSO6N8xF8Bvl3dJ4
#7yusg3JpqR1el2i0S5tGQXp1QNyI2KFbQrymwGeC2icT0PhCIrhpZ9C06OK4GH7MHsRQIRQAYLtveiF1f5tPC1OrgJkVXDiyK5ay
#0tNLGo0hjvxaf+TTQVP584xHRy+nbiqoQa/PUeQLAYX3J7WwN5dATlQ1cUrfT8alO3dMDYnuH64GteKbiN5qVl0y92Jf9d5Wpdfx
#Z1EPWWsWMl48bbWKzF+eed6J3YboGkkMd80zRtI91xpxWrd0bWCv7sE++7nd5ctd+Aso/ebAloP2pkWJjPg+XfQnsmeRkFePgzDo
#j8t7+dAS4cwo81GeS9pm6PSG9oXF6JNd8+MKvfmQSqUrK4mYJgg3YyyWMAtqD2aHYTINC4J9ZLqT9SxLmV0O75mmaoNFZVtEW57H
#LI18Lmzs1CBGxdssTiR0iumt9zOCuLH2JoMtCrE2bngh9hce7SPbbovbrGv+coEtNGdpW1rNaAffiJQMW52NwveQh/nOKEuaVgae
#r8Q7qZDj+OtvOg+hOKtR9+h1VSHra7P5IELoIYhxhp0jTNfF9Q8edp/D3uzl+YggHw8di+qhBw2lzLvehn+dCrR6F+VvxIoUtzH+
#qmEjWtIgP5YaU5j8GcVdB7O/4jjBl2t/g33H04AqbtI2/y4npwBHlh5H6AlDBkU/+nT/nKQRW+F0WeGa9JdTbiX821c3UMnyyJBJ
#PU3PNejCbqR2SsghE/uOWWOFfSzW2EVDbR9Hc1o8rzaQJ7L1iN6MN3R+UqMJegS7lnHY0cniyk2FnJ1mV2SZS1KLA9hy6D9xsvKv
#7vK1bM/ugX7VDA9BQoVX18m5Nj+Lnr8eJYm+QI7cu+VL3VI85rjff/nVLMFWKFj47QkChcGLuJ4LyGlLxN1U1Kkbnij/Mq78IJVQ
#d5pj9XhIdJ2pCTgInZWF+cyLBfjSa9X3xN3PFbydzce3EK4WoFlGwkfm32PIKn3Mb9rsXVN0Q3P5EIqaQRINWf8UcyUxwIcfYgyp
#nw33rDt6GyGyq6qi9GWwoT3dueJoA30E9boZ41cvuFGyVVbl7CDiapF1RY+OsGIBj6MIub6YZ0Msn4ejdAQ4KIX0H8Wy+uo8xerv
#T8TvC+75uHQSeBCONP+ezVjYo+nFXofHXWBsjCOOoYGq88dC6aFCOlgxB3OSr6S2UHBabXZYks7boIzgGfE1/8bHs+ZrH+zfO/Nn
#P4torMdckWUbsJDPYcBbMd4KCP4CiR6icjTj3/A128vbdJ6Oyard+jjr2/NDl9f1Z9nFBSf9yhPP6+J1NTDkmKk0GQYRXiFRaMUX
#4df2RotCE09bESAYyFrch+3Al0kuWLzK92kZnnphTVwxZR27f36IpG5F7c+WnUhaXGSF7mLL6r1vocPnqJaATEB7/mq9TuOCAXv7
#66az5M5tum6AGOiRy9a98c4atBwwX6xBpOJAG0S/Z4wbzaSErPHSocafrOGUMfoq0brkLvhVY3bnrbQfbo0zhmGiE4vBsLWYvJHJ
#jkyRWAt7MCzqrNmzQt4EHRfDVw6CTamZ+tuExJ8lUCa+SZpBFOfLYYjcsupsyjAnRGq37KSb9fV9JQHZWtWkR44Dw3d34Y8IYoDI
#owO7u/KRCTFOPf0fdcpTastuy9rmVqfnk1AirFYn8fTNegsAWSAU6UZUMk/Ss64k37erBN6YI09JyJ/vq+auDWBgWbzbX/xGokmV
#OxUzECcXXhT0jvqbWGuWa41N2dbVAVaUqGmC9RdH3fbEZ+FOaOAOShDi3PgpaWRqJoVsO8caU10X93Z9lVanzoZCFejxK7mX1293
#G4XnUiqZsTpC23b4ZlvTub/NCZiHzKEnR6k9VrCy3vxWJ8YXd4c9thNYUUUtxe+SZvyi+vbxuuS0Ta77/KAJNVar5UoX9RznlMpA
#yLz+evLoRtfKqlgDWnPb8fG+zUZgQWfbMWnJXm9XHMiwEuSg3jSuq505UVsD3UnwhdPoLM7WW65FOfuNxjzdTK4CtNRnbqjXmutk
#6/NWp7lmlr5fl1UGUBSFL+UWrEezGAftY2fMRgjdcwfsxzkay8u0GTTnCVvoi54TxhOVxJVzjtoeDo3xf7nwxmjHGjgRiFuML4CF
#eEE2HuzEHUZ9h/wKDrIcKijTlZ3m+NZgHXISdzj8RJJ2VhZCgzuWHAfic9tudUpO0BcEUgkVaLNDNHZdU2nuImlVc1sXb6pqFk45
#aBhpcbuuci168H5s7UaEnFej8HqGK5W3RlZ2Do/kNl4ufLh60eUgQpvfz1r7fjP15RXRI5qSUUoOYtlKC+9RYH2eRPEJt6kWqRrf
#DmUV792lJV+oiUoE1hzB6+bB9iLPUCIYdGomy3BocYOw6Arnl64y9Ss2ye0RvQBOdSbUA9GGoF33mCr48Swsdmn4J8122g29FiFo
#e6V67KXYDkXrb7XWpm0dNWz4hZNX3pQA91PeuOnqmlfUtN2eaMNNMC82Z1BkszrU7fJifWXBfomv461rWT2KEPRxTH4gwzGiAL23
#rfC0jzaRDrCKsR5jN4SMlNG4RFEHHLwjjLXOCW+s6x8oobbV6UpiGO/BI86prR1BJFntfN2Ra+sfuQEqqC5f4UIWZhXI0jtK3Uf5
#8Bbvw+DgCGA9Fw2WHcmJGJOohBEF/xs9nABTLEURa7EOYcOVe+WzCYE6yzztpomqhs0A/mAlKLgS1nfB+fEIG2ZGw1uiNOpjmOPn
#uFo+yPqdJZxJUQOaYeEw3Sj4q3wIr0pMZ6OUPkm50pnSsHwkQekNev2ZVWAyAT4Zle69BECJlJ9SB5eFhypiyLsplLaUltKJwuRd
#Hf4To/FHPVvilDz7i5wmH1AB9iUkvnqN6OldYTZdYdddxZqWGLGzNmiIWrAok1Gbzq8/ko7Osj7eyAxmeexlr4SU9Tr7auIK8gUe
#tWMuhTDU6kpH/uoRqGGFwTDlawkoe6WP0fPrFc7+qNFhpfcdzj1SndaXVHZ96J4xJTxIFlwrYZ6ikqW11lqG9aWoJ3cmQcT38Seo
#PSNog9cj96UbyysxFwcfN3I7mMM6cY7IlyHRv9IaCn3c9h0Hcbm5fvGtCXd18xOYJVpiZ8AT2sXZjD7Zl+7XTJpAmBbADGaOzEK/
#2m2iguxCFuZHqLpQ27vaKTkJzDmJxdo21E4a5y966oxpDoKGOPl4sF8QYD2IpwNNAmMAGdChsOXiah6oHIugpGFhPzFGy4Y3/Lmv
#rgFXBr4QzhhakeTb3MrZJZBemsxztHx9lYdHlUmAWdqCiWKdxYoVKvvw0KZwks6DaS0kcil+3ptAUmnmCZqJZzWCS/jqY2Zb3xuo
#qwAlrt7zoLlkwTGiBn8dY6UvSgN5j1zndstcJJSc22s73ysxkJyiKAcJj480CWfl4+C8P7sZUJyhph7a37Zs5Ivbx9XfIzAUWS+Y
#gKYTKvadu8sTb2/rkj/Ye5o6fVUcpt/cIuVwzmtxyhY1w4yVQbedLQj5Xk2PIEagFt5hV0J5HW7KnbVDqcqrH7ePJ7plV4Eoi1dY
#S+uSUV5IflWuOjNKSc+M9c0aGYskiftSsjpAVfkeu/6Kt8OVUCWOIJAyz3fyNl/RUeSA4gmWIx1xqbNE9WOXQCiPLQ/3fOxu5rUn
#oWgxDmj5BzCNb424Myde9zLWkhmcs4qR7so8l4UTU099OhMpOjhgYaYU9snd3Z8vx3HQmAR7bNHza7CWQy6uZOLB4sBkD+Tmi8Tm
#7UO9HaYPeECJl3ksGkUsJZp1tcOZvcJtzgdldVd4YevjrK/RxMJzJGkRGFihw3xc1j+znr3u8X/LfzkUyfDC1lpTmOuyVZdbUrkx
#9j251/DXGsvzVGEyOIw9SDujx/F+uXX4/meWne3Uy+LDkvmhuau1ySwQCVjpEn1R5oIQPG7fxuBa9Te6DbnFPj67yxB+BiQJw3B3
#xFKkg53/1m2ZBae2/Dn6RP8Fia2oZLuWJ6LXleB2vPMTGdeAV5BSl53tZO2xtkthLCTRnXCwwsQVPCrjygtsGDGFnaYHKXslIwoe
#fHIWuNKrNY/MW7dTXeVxIbYLUwAUzvcgW76JnoU8JfSOxyLH0aQ9+0uIdZ/KCNwNu2AKl63yLSbnWsXdQs2+1QpdftuaWegQKUVH
#l5qLjJzyIAGgkqnxcbFRRKxTWBAu1B1e92XuFaRZEnKV6qVe9YcurHtySq5nVpTfI0ABOLjdDOW6XqAiwU56P0O2CR1EHWI9OaC9
#weZTdG9Squ5C/ihBX2ar9wYUxbp/oTb3zg3nxEOiE6maVHJrePaADbjiYGXR1aUOI/b0A44jE4xpp1r6qIwrzFzKVtG6QJr923n4
#p8UK3o3kKMos2xBDYyWzUW4OolCPSmT43vNnPU0GSRlzNrxo+/gYpEc6zkeJloTU+zmgzXfycqUis6xy7VJP6B5X4FlJS6sFqcO7
#0lq2ZTtZwupVVRdH9GY07iB2bDiI4FOPiajxbkntyKcu02S9srrPJGfrb13eHJGWLJbiGV5cuikNBu1ahYiUZireHZ7uTIZD3BNo
#rWEKuoVhW705cH8XwtAkQR06PFfNc6KSs6MvqmMEsp9+ZyqEjNFzHkfg4E0gLM1nmpzyguIY8rCuck0CI44YrvxFFcQ0dimLy7Ji
#k3vsWMJAW4ckyiN27kCYyIr2tLfLl4LlCs8Xxd1fmK5T5799YUcL+WhroOyqo0to3/RplwZCeSfjuYEfa4EI6AN3YQLqmL6CXTib
#DbWNdxMTBQfNhN6eTgL0AFNNKSeLPD3CTgKN52nm4+m+L0xMBfraksbNIdHe+bpWdJMOXdrWeApLYdzGKs7hHjZ15km9BdZq8AjU
#spTe76hMPuzM8MeIJXtKr6PrEiu8PNTMybFDExuVY5fqPdqX7/9KDQ+JKdyEw2tt3jMAsg76tshdzbzBiLFmg/iV08U5Jw4Jv9Lu
#tY6TcQLPlXcvc6TE4V5/jMo+ZL4kKSega39fXqA0ikOiRuUiu2LYOZZeafQUsJzR6R3cvNEt/LHn63Hn/dG3/Wvny6OTBHG0dofB
#XWe+msdmd74ZzrnYZM1yYuzW1lpurBtrcONSVi4pF+62BgiSCxo9MdAEBIkS/hbtXb0csRXarJWhp82bL12r+bYkzswZIRTwOz7S
#ulvffiYex+rTY6v2vdG/8Mpg1ChTPRsn2zPlebOPvwplb6XXtv6NCQbmyH05DBeGzdnVs0OIs0MRU/cMZIjtwHUiG53FIyS0t/3u
#1OYzIlQCkIRh4MTa6JTUiyp7hUGnoV6e0UwA99mShaVuNYcMhF+gSRD9mWssQtZsF81XTFNmk05/Px981I2VduCzxiOzxLJP/R49
#WUVPowrzD88HetSrj3gQrOhNOsSIlx1KiAwt1YZkJNa4t5hc9T+YTUOAjFmmt4TWbD6/4yYRv0eKNn2LIAAAaKohU1D01UodvpaV
#VXAq9WH8qgKTsB933bHSebJbj7jUi/Ccn01hu/nlEw7P1Pc6xSa48fJfKrOiarbo5mWWYyt4wsxEiFegY2wk8wOrnkw1FiAOwfIU
#0thsvJWmZ4N/+gGDZ6GOIml/DyaKaYBkSmmmSGj7jJV6+S3j40/m2u5DCoj4DuxvkHaTyNoQx7jk4Nj4j+gef/7SyB6YVq07X2/0
#Tqm6b+/DcrHxCyVBMhURtD4toEzaap4XR+YV97XBiw4uGpbWYLkR7ycqsKxhDo1RSDkxbR7ZtqOSb/Lk9tMY0YcpWazel4tWxKIc
#RHzTLGzwTP7sshdYLjIf/Akq8KK2YtnR4aP6tYC3uIVUI9kxCcVCyNcw6eFQAq3Jr12ihsVGnW/I+4vzCogK09Rbn4lkPOYtanD8
#qPV2yKeN7lrgvXs20TyOz+KEc4s9brK7vZJZGtmnkNLr5oiB1E88a1w4Nx+OYzbrSAm8cexPNkHv7/ssPx1dXyZylhTDMp8PY3th
#5+tilOyoW0YW9V4qrm6Efp26zDfKT/iaa7fDauM6It9UCzsfZCcvMnB+V3kBHfTFLH2Prv1j5m7/1oi5kTHH4xp43MlaSj/v2bX9
#56PeN5M1Sn1OzXMfEVqhCxIZ/W0LADRbF+7kkhd1YRDYjV+sJGD0IrPKO6epBaUvehNqOJmgXR1DPhtlql+DZeAl3iX5PJWYuq2h
#HzLvHTpb44BZvmxVxE2OGTvJeHs68chV1ksZsx6hEkz70m2PgNma3GYrAxMHZwbG3uyju8nxfKDo0eejvvuSQz9lDc24x779abb8
#01DfBPVqohoOGW/SKiQbdi+iQcoZ0R4e6DOvNQTMMWr9roL1OJ66MmKJ01MlrpV1rAUKczIJ+ebj1a/7xtTTrcr15ipiAcLFV4WK
#KKYI3iVWWHPYbycrDubs5ARSphIuLURp+K0i70C6CAkmNfMM7Dye9YYIx0/E+iTDLa1tdz6bH5J/t1nW/fULc8D5reMUyUa30DpJ
#W1uVuvqnhZBdXSKehXEUJLWua9NZdhUujHnd1Jcz5XLjZCUz0nGjpBGjL1anSNaFhJ9enFqqcodD42DzPVlLGb6YwlZuOJAtMhxY
#bR8leJMFyYlOwTo8g90ilzijy+Pw2LN40ohcpxyBAS+614Lfs/vreWIp5RiyPjbG4tmraY6+pMrDUUTWIPVDtEsx5ciYkZJLB1yW
#qM/Z8MaNp5hdEvdVI18mYIk8QpIXXWuyT2VDJjw2E2zik/Gxg6y6OxzI3kw7GRAUpbngU2vJhu+divHycEWK2Ozd0999gG4uxb7I
#VbsKz08eNohhtvxgcjjVJ4hrgCd3oNJImQsNGY9PwUPuHUeNmJEav6N2isOb+SxlLPyQnIu7TCqk2pNhZ3o/yOy5h+Y5oQoKobgO
#+RrPFkZAuO+5ae92r7vD402f03rD8MWegjyVZ5YlXphRdVTayLgxpqcfxbuZLNiFF0d2JrrYtsp35sxC0xDFfKVjpPen9/zq5eU0
#lZfgsrllvFT9nbc3uz8PDvBnCUPO8rVep2NPBLsctFvwdguNzDI4uU7bcJ/bf7psGDInlQ+P80u4TTiWbLGHLoiIfsRrtiPs7hHQ
#ZC7Yl5HYPuOnMXIHwTbeFF/McePVphtqIb2g/GldoMXZq+rllwnRaMGv+F3Q2DWRAtoq6ICDJ464QYSYTBleLwZ4Ub8RkKpiLhTZ
#Ns3trDsYUUMTKNoIFO4Eb99xq5Oz8DO2MWFOPtMND2utSqEvGB4+Xuo0og+4f7FhNOWZS6vid04dCI/5cmT0GXKw3GLTxgmS/DGn
#JPeBDxUVbKLfE3d7kuzEu5sW5nJmmPeupy/LQs/H7uO/sg5C6Rs3F+76PRHSZNy/v8J+dOzw6FG+Jw1ek3I2tin8PfWllL2y3lfS
#oBYFj1dxlUuO2FkSfNc7yOi9WXFAb31OkO+W+Jj29vah16vYl8v7F/ko4+1dusLmz1YQcurJUfOe6mx7kVJcdp0yx4f7V2djMUG1
#pfpre2wwskFbjaCwKYFjCSLSCN+zjlkt3fD3xZCy5MZGOCCLi9aWAmcND7dAr5bAeODUB5RMvnJO31eZuQTV82x0+Qde+KUTxuG5
#Q5jOZE8bm7qmu539ueYh2gBfF+g5k7VF1ux1FpZWXG/vn9jdeT6tSAWxTIM2D1sTKZIe4/ZjDzb1jEVAGg11SSDatC+PDBsEZ5fK
#cJk0yqvQJ2HZ1CpxVzXNwsnZcZCn2oPwMSWfFgqYuNsSDofRFfoP53EVW8ABn2h6brwsOj4bwHHZ37cw2iwBCaQEvWfphlvFO+lI
#Rf9oRn6MiOW8aPDWNrjBrMQ0qiMbhoeOVad2+CVsX9ndp6vH3Omf88KajE+mPEt0DJPbalT4gnL3zD4BPL1ZVE8V04Xu82QvPhZr
#4u2eOY5s6/KpLpQGVI+buYyUsz7BRScwY+VUJFTUPUxx1fIsu5S1i6HhfI52LrCr0PD6kq+MUimwY256VljwgA3B4ppG+Ns6d/5G
#t8Aa8Y6lt4/9Ez0hxiefdpyQg84NROpRq5MPYwdxYISk7mzfPdNDFEJDibPlydbSeuTLOQoXh+/mvbfkGjGg6rhcWp6Sh1JUER+E
#kKKD01+ickj19oDXCKtOSOeT6k62G9XlzpZO8GpXdn2Trf8Y+37lC3govPUu7zo1zRdgoCaed6cjTy3e/tgL13fNzlvkUCSeUvvt
#IBB6/kfFwTNCeYiG9LARMbeV2dKaWvStVLSpLP4TsWdo1EG8BcHVvOKLfamXSdUdsedQ5Rp3rXJ0DOJK6erOSzarzRqiRJYe79i0
#JUsU8WHkZI62cWw7an1jzp6eJLyXknCWegbFqP7GULU19/GgZxJV+5NYxKPo3OHwfPpC6pW1XXdd4VLnmT6qoszI+cYKmE7xQpLk
#60J7gkf6mYvARKpU0YV4mG77YGYykddrKzjI+2ePjp8cW3VxOva5Xq40cPTqRd+sH4aQDWxFOMViQI6eN9eHjH36NGHTVvrBHA9c
#JcORA5vLPvICJc4jELpeROu5kCfs+CVuycSNUMYxIl71vt3oFHp6seLf1CdS4cENWvf3nElb7B1RWzSQYcC2f85cYl3FJ1b6tqpi
#ijGnz6PG4plUcAe+JZH10Hu23AkPMc6PvaRf8b92NfR/ft+YLTsblT8of76Qoi6wTuOd/V6aoT2cmLtFX8p2mU2MOiRCt3eZVASi
#OGcxgGTKra6WgLD4ufAXwPo6TCRqotX72N5QjnT4M5dUIceG/Q+UXY9NJYMsOeGnIe5zr2WDVuhNUrhOvWGFWDMmdQUSk67UCxC0
#k5uRDVfhvLvEvhUHUF5d9i3Pd1C7ohZ9etR9RgejYdY/RHSwyAi7OPBalrssR0c6zcIsectP5NnH8/ewDgGDgbisrG+y+JGWJ6OE
#8iljNTdP1ivMDdI80M7f5qy4A3wez7bhp3PkvSl1lUsdvXSayltkdWGBVq0iFQ5/O+I7m3Cr+dj+0fVBypkzLYKFlXcFNlnUrrN3
#Uu66bl6lIF10sTfmSy65d8EfUjAQlphyK7ekNjwAZ+/l4QcKBlEPL7jYrYGPqrvrYG+Sn2iGDc7HUSuR80qpTdrIyXmTlvnpJj+p
#JNRldww0ZXky3ZgeeDtGEpB/+YKwXcxlJFw2Hy9RcK2OhrzJZyD+2tvo/NJWQjz1TcnlalWV4smTrx/YnIx5/fkYcZlf77/iYUKD
#5j4mk4pM7Ztzld27z0Aj4sI5mCleshjKWDzPGTCuIl8qVPFmR0FUEwA68htKD59U1N1DSb3Twkdjvt9HFPC/PP9U9sgvm9l7O34r
#rbee6dB9+xijopjWlZYXh9LhnVvddEbvrIt376ALux6+zeySxzZjquLnUocpS4Svk0KfQI6TKg7aIRMZ7FsdhCKYOYIAyzwEfaNj
#wmctu8snYSqfU/wn39RcKZOjy2Gjk9VZcbCK5OVkbeKqOKuvrS88mquVLzk58FNXfjTU96k6uySriplL6UgrtCg9avOwKIsDL6I4
#UYIpKetOCLYo0fplE8PLZ32iI3ESQvRJX2J9sogkLV50AEPUuV82v8ss27QA4uZEAZnMzMgCTvtFLVhLPYc5Uth3TWhMD9NwoHiZ
#CrGP4UvdoUv2kgvOqALMY6Nn7R0+ySNamixME3r1xbTxJCnzK7bWm7bJ6Jfz8ZL5cgutHLDreZYFyjrQxG2SlMs+Z1za2RYZNOSW
#rm119yXc2AnPuLoME9JD8KmkgdqieaPRLgnaKs5lzGVAGmUTNt4wUUcXWb0/u77Xmym7uJdvVYb8xhzoFLgredWWiPXtFbM3fpQ1
#hBgMBETI/TdTIvWQzUhxY9AAcU6PgP+t2Ga3QS4T5OpQgTX2O/wIOraYJfjHY64oDji9xI6wvMG4BVYzO44RM3Mj2xd6kyNiQrcg
#IlAIC4kh4CMbAHvnvns8vz9BTvUOM8XTj1rhyFqix46PoC/UU3O3apt64yleluuddwCPMlCCHDfcxOLJhH9e3jyW1/vWPYGMoxKv
#GuheaMlBwX5ubp/pR566rDTF/MwD3Wofks+FTncFsXP5j6BncLMCMYlPzSgG7oGxChnn9qZjjmyYQ+yPeE+Hl7nZJ4sTkxQNmuJA
#U3XuJMhTyR/vdGZSJlyj/domIGd4mYREzxvOhgMxMXuf2tnzMtMqe+0+5VHXAXGqg2JGeCG9KX2S7DFlxaIllcwaos7uNfWzqksS
#4c1feQ/mcrk4JeYe3dHEw6uvvpi/LKTV77Q1ahZu2/8gdIs5qh7pdSkh0bcf2sxLJ/TExzB0LJskb6CuuqHRQiDR5r0M1ra18oXv
#9tdkrITI1bOMZDpg8MBd9iv7VlYFEgxIUlMIaXhWaI8ktxHDl8pIS+o1ifcEChZ728Y1264N4tw3asNhLgoFRQTFgc/Yd+FiV2H9
#/IHDz/PLv7w6U7vBLLJmjcoTEpNCMtKlsKB7L4PcZzFrgS+uRRpt1qzTgzApcmHRU0YC2R2kwAbXv6NNIbHjW0TFDeiWQX40i37P
#QpUenG/LhGUhhXQ0Yh4E4Tkd15KFvlm2KAZhDKoSV4UgT8d/gQndoy2bABKHdO6IV5FweUyhfeiQtha3ogPX0oYoEc2CPYQg0oKR
#mWDpQfY8koFdIZ6AAmDNuVp+KaV+g6VLJRHs9jIlHb/UKHUmRsNahUIyVWqXnoOwVuyliRJOZZzGBrsPWYRiafwGA02aJkxulnbY
#rMbqEqo236FyDM/A05QvOG2l3ALKVaYp9lwegUW2dYhKWfFoOPHq9iqqoFpV62jqFljVBXlKgn3JL13KaEOfvwosnLDrlpRm4Vdo
#SOn2WcuEtuTgaGaup1xIv3LdYti6RDpjT+CHICLFx7V6qmZbxbbi9zo30aXL6LP6ZrNH9ykeqUpS0yTvcYhJpn3c6I144AyVZu3V
#Gw/+MF8GsWLaGTMDd8WWQ7OlgehLvRANSlvOLm19MsV2agI+C9t1ZGF3ceBIBsVbVIo4Nj6UuDQ8pGukXrHCqbhNjgUvrLimNxL8
#ONcTNjlt7rXrN1kWMRXUh1X5d3Be20nBCTcDipPcQWZpPWpj1tb7BlOibQ4BfdIxbGnPodLL5fLkc5r333zI0T8iOMhgTVTwHpwX
#dDXSPZ2k2fh2ylzQE9J8NbZxV1i689qC3ZazSTMhW1GpR/KRGlsoSvKwaLpJx8eMjyzKTomdZt36crmOX9gzKBfExp3CWLjY/TNV
#kPLWeZNuv52ft3DKUVLFReE18FpmOz6DLaV5hRDaqWChKomnbn+xFcNc2O+zUz/tz82YstXqC6Ib086trXgN3wySuvXnXBjSNaeA
#9nljDSsu2CTdYG2lwM8xzQ194XHhgba3U0hWXefKcorqtMD8mMWyOZPX18LSIpGJFPY9wKncSYskhNUJ7v1ZbTY3S4I/VekTPiGF
#yMlhEUmofOZP4ThDlLblxegqRdgvJIIxrzXIVdiI5SxFqUJkl+3okeZUSPFVyFVI0bFp8VXYSNFpnY7R9ug6DiiottEr2nL2Mk/h
#eW8978TJLctMOjKyF31ODLvqV92LX68qZ2ffqnBlT+I3mS9Kw2pkt6+Xt8U3bvm7Wo0rx6F4brK3v6UrdAGo3Up9u9rrUVHOsBo9
#zBf0zaAYambJW2H3bb4f1PiqZ/15yKYsMZuOz9/wAn8NMgHnvcJMWMdsMwe7Yn9BxQmf30vWdz3NCrzvmvBZ6mQZxVgVRcI12ODG
#xjyUnZ+NBFJ/IPhGUJo4SBopuibtqsBa7RUxKIKsJLvPoJZt3oVDQOhDKXm/jc9IJI5sKV8WxfPhflGM0Pbz7Vo8nJvZRNcqYf/A
#HDSsWq/JTtWTso2jqZ5lOgvQR0SpR6m4KFD/13669//I3z9+/9kDCLJwdGH+P73Hw688c3Ny/je///xj/I/ff2ZlZ+NihSDl/D/N
#yH/6+//47z//J/2bgmwcgEwONiAmW9f/E3v8j3//m4ONk5XzX/rn5GRh/f9///v/xh8zPRIpPekPjdu6knqwM7ExsT5M0ZrTkbKx
#sLGQyrnb25iCSKVNXUA2QJcHkBrQHmjqCrQgdQdZAF1I3ayBpIqyGqT2NuYPPxX/m56tK5O5owP4lRkJiczSHWTuZuMIogUBgHS+
#5I5mtkBzN3JBQTdvJ6CjJSnQy8nRxc2Vmpr8gaalDQhoQU72C+jgaOFuDxT+8WD6iSoIpKXjI/9F9g+lH6upqX88mUwdLIR/DGmB
#dHwgpu+cPaz1p3WztnEF/OYLzJS7K5DU1c3FBswYvwfYKECCvu5OFqZuQD6Qu709wAxoZQP6MbR3dHQS+/Nqbm0KsgL+l4m/x+KO
#Dk72wF+kHtb/c8b8v8D5WAEWNi7A79zxkf/40X1ygKm7m6OTvak3HxkLwA18FHvwyZQtLV2Bbnws/gCgoK+Fu4vp9yWsQHaABfAB
#lQUA9muJX0NTVxuQFR/5gwaV3d0k7U1dwa5PywogZeKkIwe4OIIV8EDKTVCf3M3FFORqDxaADjngz4vu3y964BcXR3D4AP4e6Pwe
#6f4ePaC5mpvaA389dX4NdH8NvqPYAT1/PnR+Ph/gTkAXV6cHSXg8rHcwBevI6/eA3YLcEOAi6Cuurs7n6w9wdXIBn88VPPTn/6Vc
#UtMHswO40fm6AN3cXUCkiqZu1g8BjvbHwNTru1mCEfx/L3H8Yak/F4CYbMB26aVsCbYiIUbWP2ju/0IDR1N7b9rvSgTS+T9YkY2g
#r6mLC98fB/iNLeriYurNZOP6/Qme9weA3eI/ITrSKn/3FyYnsDQdHwydyc1R3e3hoExg0dmDUQHkP1DIwVSc3Kz/ExUbJjB58Ds1
#NYjJ2tRV2ROk4uIIFq2bNy05mKqpvQIQZOVm/UDB1cPqP1EA0wCBwyXI/MHR1LWkJe2BDkCQmz/ABuT0P8WX0VBUkAU5PZjcz1UW
#jg7/cRUTyNECqAE+pZ+fDROYle+iATvmf0Amd/0uhT/uD/IHWILM/xPmfw0VYNwHY/8PLHg42liQsggKCoJRQDb2/1ma4LXgdz+/
#B2X/QLUGev0HVGZaIwp9FkZeUUYpQ18uf0o6v78n2METzDZMbkBXt+/ndLEy+080jMDzzH+wrF3/E1PMRuD5v7DMHf8b1sGMfmfd
#hglM9ucIvPT7Ijug959Fv12G7L/YjBvYkMiA/2mWHJxRrYBuruAILugGfgVTtHQxdQD+mPjbL80fuHpwEqAgswEtrb4RnSEDnQEd
#MzjIAx9g/D85BgoD9VkNmVyd7G3caMGeTwf2WSfa/3A0J1MXV6CUvaPpdwHQ8ekb/nFV1x+u+rCdm+ADdYCjoCntDz266bMY0gmz
#8j08AUysAFYWFjqA+19g1gcwCwvfw+g3gutfCGzfEfgeBr/hln/B2cHwBzD7H7C94Pfw4+rs4kbrzuxIB7AQdGWmZaP/a5bekY4O
#4CRoIcAqbP/XPCujBb0FHTiaewiyAqy/g2kt6O0ZLemYnfgYLRns/4jY6peI3QTBUqQHMYPzAh/ol2Ddvq/9ThicV2kZ3ejBZOjo
#aT1+bGbu6ErrRO9Gx2D9c3NwyHx4p+Oj9QDPudHR/73Ung7w3Wf8/FgfHsLgHMTo5v9bhX+FlF9Kd2H6Ga71QYb8Ng/B9Rc2v6Wj
#C+0PtlkApoIs/Px0YPgDXStaNwZBVmYuOjpf8AwDg6mQICsXnZkL0NTOH2gPTuEP2A8rHQXd6GkfEOnBR/514L93FHQEOPr/sQ/L
#/xgAqKlpQYKsD8r8xTzwn2nEHGhjT2tKCwSwAhm5AKx09CC6h23B5vc9/NsDLMAK/NfJwRRZwcmalZkWxMhK90dZbv/IJqyM7PRA
#BnZ60B8eXf6BAAYzcv0NNv3rCP9Y9z2bARx/AWlp3WgfXulBDC7fBw8j8Bkenv/KbX8WgSn+WgXGZqN3+UXiYeEvNf+JHAAXgCnA
#5ruSWAQe4oCbgCArNTV4bEpNbQoe/xCFuSAI6En63WXZ2X5lwgdbcAMHCxc/P1Pww4bulzW4gnXrKgDiZ2BwpTPXdwWrkNaVHpzZ
#Aaa/Y8V/iApuYEW6gDcFP2zAVvkvI3WkfdA8mF0bun9Ygwud769tbcBG6Ap2NUtBsL74XcEsWVJTP+wvIOjynRcbBkHgd6OzF7Rh
#oHVhNNdnZHQ1pGOmBSMxsBoyPuDSgRm1EHSntf8HuxZCgkwsLKzCfxfIYIS/Nn+wZ1MBDvA+pj9EZgMm8gPnQU4Pp7H54zdARkFa
#x59gRhA4tfx2QH9aF8CPvb9LwEL47+TwY1Mw7Pe27gAbgDl4a1p3sJBtBIEMtG6MQDpmtu9YYMpCLMJugjZ8QEEbwHc/MDVzpXWn
#EwJ7ATc1NQODuQArC//vU9o8bG4DsGH4oSt/f39aOnDworUX9H2oYE1d/o4N/70iQeCFYBn6qoPX/K+tYGX8HchAP4KViiwzG5gB
#gLiNi/n/Fo2fkRds/A/LxUzN7f4XmQb7Cy3YGxm/bysGLrDN/2fM/9IBWFqCHPwgAVpa4I9c4eToScsGYGQEh2Bw4GBmZf0jYlbm
#3xgcAHYwBiM3EycXGyf972nah3jBBlYhGyMI8J2Zn9X/P+wAbGP/Cn5gTf2aATdWYFbAnQL/j9j8UFg/ZDOw+wg+xEBwamP7H3ni
#v1wPnDT+OhYrC/33eEj3J9k8vDO6/E6KKrI/YQ9NDDjIgsVA/xeM2eXBsgD65KruphbgMkHc3czGHPwEv7q4fX/agB6ekuAWktyQ
#CSxlSVNza9p/nt7iITP8Lyn2N+vgdQwP8vSnA/ws1MEljyutBd1/2OJX6nvYht9e/3sfJgsiZwBvCgT8fAf3Zd8n/mLM7b8y4vKX
#gQK/o4Ct80ECgN9k/3cJuQgwcQr/pAUO8GBT4ftNmxE8wfBgPX82AJP/yfr/1ga0f/H7sMvDNrR/dgVbAAPr933A8rT/Kzta/1AQ
#OObZMIGLfLAsf4U90E9zBP0qEWnJ6R4qORdBD303Q3D98L2YdPW0cQPrAsygOZh58h+FADnfTxo/ykP+7yDzB8MRA/rYAF1+w91p
#nR7C9o+lbkAn178glg8QC6Clqbu9259Zl++R7p+VmJuL9y9ZWDiauz80QkzO7kAXb3WgPdhwHF1Ev7dz/uamD6z+trW/yDj8kMKf
#+gjEZP+9cXtwQRer7yRdf04JCbIJ/54DV658PxwZLBB9Q3D1y8LvKODG78jA8FBbOYKbNdKf5ukuCNJ3NOQH/uguXQDuAEfAQ+No
#yuTk7moNDvO/korpH768/9HCuQAt3M2B/3Kt31BzRxD4gGA1gjtjcPEg7P1wOQMuIgD6hn+14Gb/6FkeUEF04KABXgbu+r43suDo
#ZPWjB6MD/KPZVAJ3kAo2rm5gyL97UHFHe/sftyrC+uCW4uHW6lcTzQf2yb/2V/wX166ODsD/1HSAHgKj/18Lvf64ua//n0r2h4CB
#YIsEi9fN8Hdz82eh598tygOV34tdfix203cBx4l/N10udOD+yMWQDwT+3+/K/g9Vu/8xVeAPqj8bWvDwf0xN+R9a+dE/CtO6CTKD
#h+AezsCCAWDgSq9vYGH4Z/DQ01n9aOqAgmC3FSYHI5vSkjM8tFMM5OCqmZwPyPerLxWmdRF8sCAne1OwCTEbUQjT6psyWoIJ0f3X
#ASWzDeBvK/tRO/0SLQOQwQ38nwuDCziWmAr+TcuXzZ/uvxuDif7g1oUO8IvV762lLMiN1vShBQS3HGC+/zHL9h9n2X/Ngs9Ix/er
#zRb+LwnhR/klyAyG/5Ai3YP0aMHiYwLLj+ofL3+k+WD7D0tM/6dr/n75ez04DPzrZCx0zOxcLODu919nA8+D21aAjeC/Tvdz3lzQ
#VJ/DEJzb/wRs139du7kJsIB99qF9owO4CbE+jBm/jwXAbZowiIGLnhYIrizp3fjcvici8IONmR0M+DFNC34B1zX0XHwg/x+Frzsd
#UNBN0EXQhv+h8/suSEtBm4e1NuAejMEdLHAGd0Ybendwr81Gb8NoyQ8UdAUX4JYARwZWZnbwzr9eHwqYn0PGB8jPAPdL+WycnOBW
#7EG1DyO33yOX7yNzBnI6cv+HAPIjvvL/pdE/jiP+12WHPgOjobCBBb0BE/j/DLTCfAZMD+oTBo/0gZKGP8EPE1R+Tl5+Tm5+QAc/
#F/A/G5CfuYOfg4Mf0MvP3NrPydzPw9PPw9rPwwEM8XAw9fKzAFr5uZha+D2wTydM+ecu5R/9NVjTfzhT+Ueg+5VchcGtLtOPqxwA
#kMnGAvBw6+hmak/H91ePKPuvGAlGFnVzc7Exc3d7uHH/gyjxyxbAbCjS6rsByMGMPtwPf6/UvsvaECD+0IL+6WV+dD8uTOLq6vpg
#R/5+RUD2I06Z/kYz/dns/06n5i5AUzfgz1tGWhD4CFZKpg7Ah/scEBPYdsGzD+nh4Rr0zxu4pftFQPjveb7fZM0cLbz53R8ueIEg
#C3FrG3sLWrDVOIJzkbc9EFwGuto8nFOQHNwHOdq7P9yH/4J52li4WQuCfYTBjf9HywseMzsyOX6/t9d+gIIJg7Xr6AH8RZj/R7dr
#Tv/XjRbwd2X9RySCrgDXP0IW+0vIwO8Z4wcLP+zOBZw5fkfVh3Dn8xBHRRn1wI2qFYCckpWRko2cDqxkBUdPoIs4uNChfQiaP2no
#A8HODVbvw+cW4ONZqD9Mgs3kQeW/MpGWqb07EBw0/fzIWch/5w7hB92bgtniM/2rjtH4l9FZODp8z+lgBduAnH6kd/AYZGNP+8PI
#6P5cB4N1B2YHnEZMf9kaOd8fCoq0YIMFA79/SAFOdQ5/A/+aJfvez3yXGRjb3BVc0T3c5ZIJPhAX/vUZ1U+f/sO45IMffy9Cf9D8
#Z7v2U1pMv7cBy4IcHFyYaQ08wZH3xyUn/fcQ/CBboCe4jXDif7gK++6nbnT8dKZMYLOgfXBRAPDhXpH/d7H1hwmpP7nuu5cAHrp0
#4K8PWR6uMlkYaB1pTcFNxZ8Pa8gfFPP3hyngwsVUmNzJi5wPjPr7gxww1vfX75/GgCXz4Kg/pUAHDv+SP5UOtkc/P/ffWn6I5n9O
#Da5AweXXj4MAbMCB9h8gcNcpCHZIl++WYQM+BJ/Nn6OJ/jnaz4r9h6n8LNv/0urPrX/IwgVsYD+rd9c/tfkvj/gB+ctcfsJ/mNa/
#a3fQd2Nn+UveSn/XUMxGtAb0gn4GDIJ+jIJ0/4iwZG7/7ElcBMW/J+mHmvsfrvwr7/68rP7tmN9voMnJ6f60K+CJh9vpH6dn+M25
#KYMjg8uPYzH+mWT8PUn/Z5IePPnXWdT/6qPMHe3/6qOUf56C2cAVXCH8/Bzh302W+PfbMsGHOOnqbvZQirMAfvUgjG4/B3R/7piB
#wi4MQD6XP/sr/MPz/9yt/O6ngUxejCAmLwAbHcNfc97gOW/w3F9JxfbflyXg0O0I7vFdwfz9uDY2FXBjArk7mAFdlC1l3YAOrvym
#4HbH9+f98IMZP8yC0wm/qdBDceLCIKjw40YUABR0/NXm/MW880/v/57qNP58bEb3dwr8a572tyJ/Z6J/RtifijW3cTG3/2OXjoIg
#wO+LDXpZWkewd5L/tGKX72HpJyIbGAiOIwDy71mGnI7h+wSA3BpoY2Xt9mvJwyXb7yUKtL5efLIPRTaA3IuVnA7g/fAGIPdmffjs
#7wcMDGH7CwIe+/8k5eRo7/0Pcg9K+AOycgT9hrgJfi/3f+nEFmz2DAq0f6T+L9UwPpSCv4EsdD8+P/1ZRwEc/+hA5m9nBPr5+fo/
#2CMT0N7P7z/eov0j7/P/SCJAcC74OfoLCI6+QMG/J/40aQ9W/1CMgPl7uMOzsAFZidvbgNHUwOqgffDn76LysAF6ijl6kX//+OhH
#6n8ojZl+6APgCubzJ4qfH62jsOOvGwtScHegzwIA190A898h3xdoz+cC+InP5woA/wOHAmZWsF4e2nnwwJPPHWDNZw7w0AbPgKt0
#Dxnwk93wL2/X+lUT/PUhgttfl3zfA7cgC93PcAUuKoQEWYXBDz4W/t82DbT/nuYf9Cjq9tOwXX7ox1QQrA4wAjgGgKX5IAcX2ofD
#u9A+6NMG/AQ/zMHhgpUPLA9mUyYP7f+HnWvdbttI0v/3KSCeGQe0QOqSeDKHMqyjyEnsOLKV2Ikn8XhzQKJJYggCDC6iGEnzPvsa
#+2T7VVXfQNGe2dk5s3/GJzkC+lpdXZevqhskLvDrnF6fOQVZaRyhdeLaSFJYwiIkw+v+w4lI2sar2aBm039YaxNfzDw1OvrjoU4Y
#NklxDHu3GbQwIhmGazHcgVYwj12/6xj6vxunw5tX8WtMsGrmjJ2H3pH6iIbc7xlEdFNW2SwrEtpbUYB6VA2XiSSnTt0jn3K+5BYk
#HO8jOe2uRyYDcnsL46olqOHTTreQt16cDphyugldDoUHHvdHFLtTt60I2gVs9tpD0d9OcvzJhTNv/aParaNZN9qNxBJgRpaOmoj5
#M1ImeeXgweiGoMOIYAalAN2MP3XzGEpc1X9KHk8fe8MK8AWXPsMRcxkGoZ2tgExqPhhUbJzXybGcE+3pmxJ8JlzEaAVUi6BnJJGR
#ssOC//4kruLA6oaXt6KEr/HIO5gktLhLGntOlkaWBHuewkFQNeQLPrRW/Qi9OgRPpTgyrcz1H2lo3mI6FkuM44bKD901ITj4uw8e
#si+YYH9nfvZ35h3lXdXQnvrbbFNCEUnFJwiLcLehXoabsPjQvH5unU73vTNZPyWFeq7+GzlId6GHshKFZDaBywrOQgJLsFfxc9iy
#o5QbO2neJe/j+4R+KOcnREG3wfKEGDDkDeU0YH+0IyMIPyzoxegHw5YqdOeGzR0lpxThFD18gu1tZBk3BRg/Qsi1VqqoRz8hmEje
#R8SUHQm9r73NcxZfunZXaHmwdV7E2+6tuvJSyUl8yUlFQtmiDEQnHQABtmzrgd0eyUhgi/XywTO0JoWMOFmZ3FkLZdXPg9OulBCF
#aEa3WhSEmBgxFk9kR+C3hMiyf1pSwryE6zoPW7rrcebSIcWQGBxNqO8UOofoBuG8sep1lPujHL4fTaMUo+SwF+dhTRc6Jre3aVeX
#W1LONp4CZAynVbmMfxfm0YremhLPL8M2yvtSQDdWG55V0V09lOBvrMv3E1kc/dU82E+sZlNbNoPxPDSPUeJxKxlm9SWcYizWp3Ql
#b3jpz4s6S9XrH7+OTbmDUcIc6XFe5iVZM4ovZEGWP14D2tYhXznkNGCcRMmdWM7v4huEcaMP+CWXkogbaIqJ6j7SvJOWIusVSXj/
#wS56bOuWdp6Vw/9UfqDbUNQAH8IR7u1tYgINcv3SbveZY7kP3NULe/vFfq8f9O760b00AoIR/+bUb9KRnPDOQ8aOAbL5n8uQbE1U
#SFpHC3MJ0awIsZ0hbmj4pAew7WX4GrpRksS2MDItYbg31KB/8t27yXtumoFM57ejvcN+x1//0rG4HzXtW6hB3T9D9CzNm7BweUlS
#RLkvYhb5NTZCsPq7yno3Y1tv6O4f0IdBmiMZIaJ7wcCI4xxe1pjNKrKXaVmD9HXaChotOubu1ToNo6sNYrt2O6g9c3HQ59T3/vK8
#87ydtyO7135Ptwvo8m5C1thiDWshm1Nz31XfU6XX6IObQrhlv7DdsZ6RgzhRYhGHuU37vxqUeSUjGsNkccmpo3nwf6F4ULht4amc
#GWQj842+KfaCMMsP9y5pOW1TJF3Wu8UvzA6Jj65OjJ6/gJs9KRE+trVKT8MXDM0BQZII5q0aDPojxCtNNlmEZCbh0e+KOHlyeFqp
#X1ug1zMWQkz4FQEnOhPVuUd9GLHjbrxJTz94YBPVSZp+eYUHOv9UhapCxKR1Ns4QJGzkMnrPv/auKI1TU1L77VwVT/Uoz7I0VXz/
#A20Agid0gppvEVhgPS92mh8rrL+UdsgfLRUhhD/6Iez36a9HSnF7S9M9ePAxmm5v90KzAU8OCYIX8Yf416d7Rm4bC3efY29vB+fm
#PIFTS1XsiJRv7nSoTAfosJp0IkanX3RDjNLHbrqpg4RroM1yPbyEH8xqOnpQ60C/7OIbRnJQrRhiz7N6rtJYRcpdKoyuonk0izbR
#OLqIwzSmw+M8bgherGECc7pg9XO4ood5/Kcw1zYT+GMW/xLOo6t+tIm/D2cEKsbxN9E3+/vRIkyjG4Rn42hCBxGVKig6dMaxHs31
#GwiuRzNnITfOMoiZ3GzbyI2vjCfT8MLbmWt7MfJiaL96OOkleaOqgnLSe3IbyauNzTcRVHVqXka9Sl0hoFa9fnQx1M9pvOeeo+rj
#Emv7uC6+qfaPv12L0wvP6PjnY+dYmMjJKxA/aStKLL2BweZLoiTnK6XS/r2zOMiIAqhQiLUGasvC9zvHb374dAgMdTF0G8RpMR1A
#KM9ONUA3dGIwdDsLKS416IcwZ9ZxQqoz+PuTCbhfIz7Ldl2ELR6zbb2jSze3t7W7YEA3oItBLdAUf0UkoCoOch64Z8LN9cvkZTil
#A4xa41O80c1ogtg6/wEJrwU2QsQhn3Op1bkUY5xnsb7tsoGV3jyen2xM5ndsaq47Hd9t3kdrlDBadWW3t4cnYxQL3D39Max1rJA/
#vI7q3ei4P1rv5w/D68Ea6kicc4h38+QYNmss9/l4EeH44ap/sAJcuJLwbSwYeBGnZvOAbxb9m1mcgsGWua+wrlePFyevaF3pu1fv
#2S6do9Gr/aP30WV8RWXC0UsylLP9+Pz0cv98dLlP+cY7uS8NPtGo373D/sOpvA9biwxtQg52pvWgHp17alnmI794Fqn9/bvOaW//
#5uJd8f7BA6jeKqnrN3OsdYZogUqh+51DS2MmnRaxIIu05LEaXDjXncZ8SnFBtM0qVdMl/PRAPaQ7CIdysd7q5SU6jJMJGPm4o3wR
#9sFXfjqT3u7Td2o1OVGDwUmfVLOic0e+bRB4N9RPmseTkwbbIE0Q1N+FaT/C0sdqlsBwdWbngwZdFe8dRk/DHn9b1utzF/1x2Ye6
#2Wrd1X6LRt1Tvml9CJPY6frgwfMQfAnTJ3G+NSodgsKlUjr8OaU/0ifkER/np2SuzHdtCbxu950mNwXmSzaY2SOiyPscjmiyJTDJ
#z8GW/qgzEi/q3kBudD2dN7JpRoN31kKSABlQVKwZj07yDR8mL57w/VVy2bTbywRutZhBQoVfXon3Mhj4jU/DMs4M1x0dUWdbjiLP
#ccWx79IePICnA2q60BhRL9SsW7jsc+H+VMQG97atXT2NKnoI+wR0kPUJAbOgc/TvzvNd8CX3v0zwHXBncFpYl91Eu9VCfvEWNTbM
#2OLNvX3trPhot1Td12i/MI2t16eLxf6GxTI7HCGNK5DmxNPsuLL+kVTcNYKeC4cAIJ1xSK200Ki3t92NLiSxJZX9jhgBWz0Pd+KF
#EaJmULwTKMfnqOnskh9RSw4guqDuFFR0wsUMfCjpiCnO+tEXYZjth+2APvRwmIPHVt1uX4RkXbmON9OXD39/gWu4DcVrO5qIUpsd
#FE4wLz0hOYpeiLu76NNwHBDcuU31h73mjp6YeHBOU4LxOS3WIcabFISahnTPphtaFyEdYUQXZiTdyXxsS/TLAGC29VtNsX0T1yZr
#G5YlqoYv8ECWSZExuJPQsEFo6H3f00l0qC6UU06CGzk0cKl1J8cJza1xXkVpX4fzaBzp2vbhz6XD7W1px7VFlR+53jVeuXlSso+h
#NSjoTTvCyJy/Iu9FRtTio+hjER3JE+qrtmCNfcEv93fJaS1vVmPDcGE3WKeiF+x7aQCwOT7jafHwGz1MygIENpfX8VN6XVGWc1d6
#yRyundJNI8reFsT721tAiw9/2XBjE0oYKR81/AntMwrz/XPAX1HwMKzoviR/qSDkPU3qudwF66xX1vqrd7a2lcekj1/LhRqk6J/Q
#l1M9MgdKhm2S2UxV2wvsfsdhQlmSNGv0YdTMx+YkcoLBT+eheezLJ+oJ6mZVliIKhpheZzXkTDF0pssuk7g3zaqavvCPW4QQvQl2
#W1XyOo17lB+Vl9wekQHZ5af+nRhK9486X3QC+G81OXovn0Geh/kpvY3kss0MtLA9wMs+qlI60lpSrEDBwI7cov5SbSL4oB/V/BBm
#9JXNMbwnv9JbtLc0V1ysRM4x5vxxdjInII5REhNm1KchHVrwIKP29/SMWJ1Lj3QphwFTOIwqbA/khOM6Hg/m0ngdXwy8FnPdYuF9
#OXr98Hp//XDdP+ldE0dLULqIB9f9qLfx3hGHLMXaLvoC+/Wr+3ZrMEdYvol3JdyW0HKMs4yXH8m8HWz6Dym0j3xn3Hy8W3laPD48
#HRw9LEaImy0tmwGf7xnTMqMtDFeDtH+wGaXQIC92gio9XBIoZ6XavxKtMgFzV6G63zV50l94SuadKCGcpmyadwgY2ZT+C3uA2FDu
#vPHQhTHm/HVz0YVQh3flk8HRgwc2NVhGR86My+eNxjKf1JCnSdjSt4MnEk0vQMKa89voZBI6sX26vTWZ8Vp/jehWg/bGn5HvnXqZ
#lMY9o7ybbIjNfdvTfPQS7iDvRxM2a5Kd2G4uhKbE0mn/ZEJRUCuClkrVKv4+bKMOu+V4Tkd7jcsDr1zQ5x/zeTGi0HBI1Biv3Xhe
#uzFemw5yWC7M4Rc7AFUUsJBX7G4SQOXlbpjl6Z/IHbcN+3xZff+o398vaGxI0//3j7n8A/86v/+THf2x+Kf/+tM/8vtPx48++/Tf
#v//0r/h3f/8V/exTWfwT5/j47z8df/7p8edb+//Z4aNP//37T/+Kfzf/EQS9X2D+e6OglzdVL6KCIrka1otsRYWv8TdoygDwuVH0
#+axtkM2A17kJngI82ipCpOMyqVKqfWpfXNdGJUvuSQ8BsPM0o98GMvV5OSvbhhp8W84CenRVSTFrk5niSvPMtVPsEDznjE4Bgt5/
#/1dw/vr45Zd/+uH1MDgHVAD8HNBv5ixUcBxkdZAETZWkiM+rRVBOgx+T/EqhYbUqxbsMgzdzNKuzRlHzomyCZAoyMwT7abDOmrn0
#GXqzL8tU1TT718lSBfLmav9SCruelWtiKL+62mnyK1V+dfadFI7hWZuc14mFBLWqAKoCukRg6ut2Ceo31OJmdReQrwPsCsqC3HGQ
#TKqyroOb+k73rYfBFwiSgxU8YHAzvguW9dAMVZQFz/SyNI2DpFJmqIquroIDa3ByriaLgDIwdLEgwRr55MySpJJqMued5adgvAno
#fD0oqwAQsNsMezlWuddYT21aEf+GSc4tzvBHF0/BqitmVXJVVtie2qupFK/jWVIH9BzUednY+rqsAAmo/qIkRgjDOrW8QXRJu1NK
#pFMvbwVU7OjH2zb1ZnRUHwQ3ANR32xMaefjGCoKUyUCmRo9rGkzKFe/4Of31yibL1BRDVSEYRepVZ8rU4mkYXCL8glTz5RD6+TYS
#MOh3XeYqCP/at/zs8jnga2V3TmaAudq86chNwHdXVU3DUo48o/yYk7NJjp1mSujBVJtatVw1vLg3oEmPB9XjYhJeppXjSqM/duB1
#Ui1b3qS38mRkiMiRvaMHXUpa5AlfZ99S1SRZvlUbSKlulPqbe+lvanpPVFIWY5G5VHX7u+6mfEFFL8ybmE/bh79WRw/6q8smjWyr
#mLc3qqqwU3VjqeHq+8X0ARAvjj4EgrVzAy6xqVSzf1PAQNCLmelKpnoTXNXBG1ual7WYKHrocmme0VdzVbmWFvrJVRlJnojIAoxP
#mq7ocjMthFMthF6NMzb6iavYaqRq2tbiCJ7qR1c5Lyk7InZCP7pKSE9dJROuPcNz8D29uPpZW8zIPJCRb+lnEZd+bbqUKREnLJ3A
#cdVv3OfncjnOVPBlPUlWfse6raa8I/TXFY/nJYvTF/TXFS9+Yzn52ad7zQ3P3l76hRnTc4Y/rhBBDmt1W3iFJVSL5fEVP3BFMobn
#9bzQthM1ngLRa0AR/4YNHN9b8weApqfai7E7FuebZ3C3pIfkfGnX2yJrNoFzdXBXr2HA53CWkIiNdW/OL0XBhL0RWQV2ahAcftFn
#FORxIi4kU0G2Dl4umCDsXpBzV4E+4w0omUu+fgVRCCoFx1HPAwojKWdKvw2wiYK6DDZlGyT5GkvEdJg3MTaqmScNr2rStNSaHjKL
#DHLHQg2UBD0kWHaqHo+rJ5Q1Y8J9U59bxsG4Ug5hXVYpr6YoA8FNgEkwgcHXCtCE1jagWJxHDeyQWTEgeQWrQCMzaLNi049tdhTW
#R2Iq2OEQt7EpZVt1fRo3Y4rO0ILEJuK2YPMw+AnM+QvAdFAowCOY57EySg2PYwc41iaJiHhcr5IC+4G1xX/uLf7ce7I3Uw0z5YCq
#nhCriG6vd7rlHuizuQzuRnP0DwO0h/pCTpkPEYnKJuALUPBtDW+ipcb3pYGZ2072qZD6JQm9iBUxltjmNWF6aO058Rb0boht5boI
#LAYW2richZ6CrbaO+G/NW6J9pqXLOp+fqJNPFK1OKE55S/VSYaxNi3FzH5JTPyiK9h/n+pkHHg7d3qCLwITX/OR1Lxd20mQyUSva
#0uCtyqG3YLHAgj3TeJoJljwThkFsF6RiE8VrVderDPoFLE2EPwqWWdECwokATRL6CT+NTZqytLTBgw2z4irJMy0ASSOjZ3XxSRNw
#BWHMOXCfzAACWcjMthqoo+WG1YEMVxLQXSwoT2euQjVG0CCIKsdkbZ5yEDAmE5GAoTQDbF4ySywOkc4VHQdS77IU05U0DWEYLPJt
#kpGuyqJFHXcOkZeTRWeIdVWSgbMD2ZlpXcD4tS/UfwPteSywe69qOrmxMqffA1WkNIKxWzKj1jXiG4uQdsnDucrzkiGYSAaHCVEH
#Nc7pk9GOiHnaYeiy8o4Igb5SpkjPKY5fNWxXvNIf+Ii/1l7oEUaC6UltU9Y0tzZ+01XsVXiMt6TZbON1mW6hldN2N++mWgOmb8sk
#9QDTHPC4yQxDP8HIJDscMhnL5YKqZzQz/McaO/KJCeBGbiBjhf+OAK2zLvjQklEFrPmOCASMmWjqAetGBtXNh2CCJtyUkAMVNslT
#cLOeq8JualZ0cTYt1FwMMG12I/R6KOdEBEgY2NdKFaaK/ZsE+qiRN1OVSCeuKR1bTT15QlYg8oj+hkqVEUMdJMNpd11d7W/7hb/j
#mmBLmlDdoc01MNNwJgH/sZhP7/eQbWT4JRuKrTR1LjRH+UY1pnwt6ko4/a1jmHCFCr81hWmVrE2hDiZWln/0V/Ons6cry8Fmm4Mr
#CVKNMNSm1LMhPKp519WriSHt94QumBU8h663wR/BHUzHlTC1EFHYIFq5Fu6la/qVvhhro86a4GK7Yi+tXYzEjEWSB3xgZAfht9ow
#Rr/pOrrF5+wFXoIQNrZvqtc8m3X9+lUwpA/7h4s0YaAeHARP8f+ZHUDY9NZwZ2l37tvS5HeWduOe0l9DmURsZeWFb2VlaneHlctO
#WLnshJXLIVNoKUuXjBGeJksXFg2XVxLT/nhpyTCG4/XEmjw6F53yIkJ60NxqhiTLJCsMDo1cN/TBgGH+kl1LaWrm4LqpmvsVabIx
#5SmhcK9qo+DjKt3AvXBtO1zqbktTMJeS+d0chtEV52SvUCE/bH+kyxV2R5D4a3g17DI88ZriC3HK63kGaElN6Pe4TRpBck0actHn
#/jrz5kfzx9vhPN3iEas1WTCK0OXtymjjDyunMxJeTTR0p/tSCpEGeUovitpqupJgHZA7mwSPrh4FYwSkgQ6X2ZBy6DJI24aBfQ3M
#imDvIqsoNiLA8ryYqqooI3Hc9bIsCQ2gYgVdzeg+Kdw9CeKwM7UG/m+xWgCandQdC3VfkfE4vjq2Sk2/JLUkE030DIOzYFaWKXQa
#GwCDxS6bUf48uVIc4k2rDMCFiZpmMAJoZGBmZ0KN8Cnm3knQp0LQ65wsQEqgvkqWKyGI+jB/6hb+DrDzRdbULWBkcGnysFONR+pF
#BuJzvGAJSknoRbHIiuB7NqFM8ZXy8qh6+s+EPJdN2EnkZ0PrVMnysV1F3A+cCniLLQPNxQLWiaNA9pTHnx18ji3fGpWYqQEQ3PYq
#WZtfzmvyra18JHR9r5pkofTW64XsIvCREPimIuxI4sYp9Yp7IwxqG77qFpDfa1cSEBH9aatyHdcBb+cBRbzL5N4e/kGI2ZFXsQ1W
#epOvSDUkJp5yWCp4LKcDc8olJEBs/8PeuwDGeVUHwt/MSCNp5Jdkx86L+MsEJzP2aDR6WLFly4ksy7YSWRKSnAeyGEYzI2miefn7
#ZmQ5RjQByqPQ8ij0b4F2A7S0dGkLuywUSrfAwhZ2aUsLbWkXUgJ0KduyW2i3lG03/Odx7/fd7zEjOSS0/f8q8Tf3/Tz3nHPPPffc
#LO1ruVqH2KHC0gPuoGgCSSCtzb0i1odS7SWopO3jBa/KDqyNOl0P1EmSvHRVVzAGFgqbGEq0hIFiW41nFErZ/byysXCxi88JMUGl
#mi+b3jMQ3P3Yu2EqY4DaZ+SXrR0vyYTv0WeQk9NfigNGcESTTtsKToYbDbcMTy14kEG0wHsuzANrBzuGaBPHvoLiQ+YJsMlUvo1D
#ljOXfU9DrMMSTNCXvCynIVfRJ7wTcY+aNuMargrLPeQeJCNkLTyCV2gBZ+plWC2eccRksus4ntZONlM08diselWOpTo6CZoWiskh
#ZkDtMUsGLzZqNNQxdL1UX8tfjSvDXqgpQ9Pv6jmwOzlLri9XN0I0wZkNWfeoRdCATMs2IfkCZFWuc/d4fhSgBDSHoIkMTz4DyBCm
#nyCZppBFvQbOr7KvQ7GrGKxiBTPA9iBfTgBnB9vGK7h7x0AhZ8PxM6t45sbY3oZ5PUOBRbyQpozBAI/Bg7ivz1XwAELQUGwgT68/
#KAxwzyXJxS5ZMkektaaOM8M7SnX7XBd7TjlRSSq+biIXWl/qweqtNChgrFSRIgCR0IcGqXGwPTbzJFjMUMd4R2fkV/DeHg6FIKhA
#2ZbydDOHsplKpwdlpwsImFD9inXuSCM4QYvoHjVDxsUrJHRBkhOwyBmLJ3SkiAldITxESutlUbQkeQ6kmwA4Rv1OBAs0ZUpt8u5V
#k/pFk7EGIVpxAqQDshbImWTCADnEyhNdx1DAvbR9Ama7rIL+UR6BMwj2JHnEdZfN4hqlQvJ5Zc7Me9SMGd5sJOxaUQRcXwKckNTn
#Oa8lzXMJ63Rg9YHvRrmwU6TrkMIOs7C1mQiKRGJOCWOlLNbpCu6ige1SujvE3R2juTWR3yld1eXRiMr23aPmoZ4+jEI2xuPUCFR7
#UDbOhPKSunWmSlOGNdhSTbmssc1yjfL8NZ64kmg8Ht1ncoLnH0UHC9Y41lhDrSpifWfh15ZnQsQGke9r2bqxCVuoazjJm/pDM1Z8
#KbPBm/QN4nTkrleWR1s4OyKbRKEURqABdxlm77+ReRMQDDs+GU9CCSltQI9jr5yFfR5tsHrPyIArxZzY4EGbcU+HO0BrG5e1NoZA
#V0yMwpWGjlHgy61zumxSKkYQVVZ0JLJoLg4wNLNh5JIFix3E/QW7dxi2XmGZJIbj8PbCtkfGZ3xzZWCkyjxQZTusVOdyLtRreTt0
#JUPbnHOZFTusXhb5L5JDCZdlXGSXEiPKuUgOEQ57sQqLAJcR8VfruOUvWZookKBBVfWGVdUbVMWDmlSG1SG8tBJULTYO4R64UxPV
#RQiqTRttcGIhm8tcAWZGR913fcDiKUUKWo6IuNE0YwUQcYFQEWqm4CNrwJ1aKA+agLL8DO/40GHtHjFqBTY+JPA7hw6CY8FQ5ZQN
#PabMLNX5WHYUHMgXEzaC1OuVQlZJZ50L2ltf1B52DQifD4ghM/OMe7FbtORNq/Hrazy4AgpxaCUDLEUn9yhpq5bsjHS58dgQ4Tip
#DOGV1QpjKkueLGq+kud9RgnFDlVCe1RrOb9hta5MZHsCqTKdsOF2hA4TqXCcA76GwKwgoDuU4Rp5YiyBwBSKSrtRVO7oKDWZRg4d
#VC4tQjsFj9oDEMj9oxMFF33Ib0BjEKxWeXdB/VfKQL8URBkUCxTS1IkAWuduPJjYQev4jFJyEFcq+oyZRafVzEIiTG2lQwCTeF13
#Q5KA+7nTmDLnRjSQDNZnmQGKZmNdLdC51nCAyqzMTHCqr1kZcGL4skiDxoiTAiErIun3JmWFCcbDEp0kVSK9VCcmPkK6LfjGtc3A
#TS6JmPMGSZBm4BfImI2MUC6lyKhiZlzGoFTLikKPElcS8lQhDLNQYpPFnvFZw0v51cx6QYoDKY0HIyhx1tqercOeAzIWHX0Hhne5
#YJQcxME1RzKJTSkaJFDJRoMkNg1xJcgJAfgZ+5AuY+8GPbxExjpikryn2Euim47wUSqCWw4+p4b5s3ksypxEXU8sYRzFN4T0hiVf
#lZBFJQT25vLNq8Czl1BwAhObtWUUSeXoxqFnlGmoQpQRSNW0UaoVw9VwBNcEXHS5YEmAM3hkQqOCUjySqlRWZJT7kMEKX162IoRT
#xFgMGztEqCKoR5vYuBqlAoVDOpJJosjMRuGWPhdhUV6/VtJGh1yCn7TSIWXFxWefx6GvQCcNpl0Yd4d+5XA31U2kbf7EmaFBJbnC
#9aFpQT63UePLQg8I1QX10Z4X2nH+cniMUdlctWku/tKOUjQzJRAvK+cYVJtQZppBEa2C8D7xIf1azXXmB9CVZI6CuB92WTFENiQi
#YjC0sBTG+6NDjFm6aoMrrKulq3YUyjks2ULVMR6GtbgvoBou0J5VWE1FedJECQomTi8hAOG04pSxEWsmaUfKklAwwk6ccBW1KMVz
#ujPS401pJrNVIoFjMxftMIO1mC8AwTSu2sFQ6Joob80OtdAtHRXDzsqwODIqH9Up5diTBycQ5WP6taLSDnkW0QfbhaPwr8/SobDT
#mFdYC3EOfvVrddo41ZQy+ByWzxL0azklxtY9JRVmVYKJ0eUKbEmycswFDcZtJwYjj4X8gxM+i0ncKrGYwgZsDGVdgdWKGsbEbjRr
#EyIMt9kAtrNhx9ggwMwpHRNGNv+p1er/xfx5739IBXvzWbsG0vz+B14BGXS//z0I0f96/+OH8HdNj/LiHC+vFGFjHdU3I//UbfrX
#vx/en1j/zLdVrz4ndTRd//19fUeP9rvv/w0M/ev9rx/K3x2399ZNo3epgBf/1vUqbHcq5YFINErq2vmNuomSFN5fDUshAYumgUey
#lItJ1Za1W9V9ki0mlyqukchcDbgxPF4rFpaMjHGVRcWxGapZH0geOxJP6vNXKiRPRvuF5jAQ+8NCMq/reszM13AnbCaR5Uvo5+fn
#Z5CHx9+5uD7sEP8c0QHAC72HqYhCmYy1FPVYX//dyRT81zdsFSYj01gqFkMZq8U69LX3MB7sEFuIhdO4TBbKazpH6zGUSrNcfXRm
#gs7qcAgjhRJJxFYeLVQTqJu6Cn0GRymThW+tVhXsFh4CZdfyNdQJNupZ+H2E5IAlYM/wBAFGswL/Ltfz9TzuOxN4HGXkayYfP2SK
#sgCruMtF6PwAOEyMu0pyLWDe8XAmQadaCb1uFKE1SWE6MUJiuKz1Np6pi7bnMJ5jqcXZSmUNFa5F9FwBbbKMUSCnEuWSlQaZCsLI
#n+AHutOXzUhkdGYmfWZiVh+BvpExDryEjjx3TPozSyb+xtJplHyn0/F4ZG5+dH5izJUP5XExUVxCjzIzE41HzozOj9pJAbwLRoUM
#g8SidBEhPTM6NT6ZxmRRyNdbqdZ6s2Z/DwF7by5Ty0Ahc+Pz8xNT5+bSZycmx92VyhqwVglHOHVY+emtclA1ydwSJI6cGT87enFy
#fg6S441MYG6FeP9Y6lgK0sL6JKY/RVCbwuY64BXi+u8+msKkALVpAEBMTWwylJWroBUiDtGjtaKZzuZZTCf9VgbwGoAS08DPb2DQ
#2UwRpo2LEUs7LY4kGo8EJesRR2k8HqII1JiRt01d441RVL9yzk8LLWpVT7v8tBSk3d2P3UXUk67VUF1+gPpPd0vTjlHQo3iqWrFG
#oHKlzJKGhejdQ0eH+vqOH7t76Fjfsbv7Bu+OLkKCMizqDav3wp+GxaSEsWg7vVwvFtOoFE971HkDVmhkMxIZmz4znh6dnDk/enp8
#HmY1Onp6DCb53Pn77p+8MDXzgtm5+YsPPPjQwy/sHxg8OnT3seNRgO3x0Qvp2YcgtZEnY0cwzjEj+qJLuWt9d28+H+BkavTCeHps
#cnx0yp1o4dJGKtVzaaNv+dLG3cuLkHZy4oHx9NnZ8bnzkLb/qG793SHVo+nMslLHUxWzDKO/StrtQmvIUsaul1HGhepMJBuKXBh9
#KH16+szDUGpfGgg4/gOsDt5cIVuLSUjGFQBhqLWKa2Fyeux+8FpYKDk7CRgrxs1EqN/UXX93iCakCzm955TdQqxFjx3Ro+maKbvZ
#sPTZ0flGpReqWCyhNxSY0FF/DdW7KJO3SFFiWq6CLN4BwLKjJaGch9BHWAMAaxFgIJLLLyOtjJXMlfgwATGg4qRZy6GK/xU8Zo1F
#D5n6IfNSOaof0mOsmVwzltEBUWf1Q/OwdHTMH3fnXy6iVY24VU0ml5Y4KCZqWylWloDazZHHZ4YwuGZc5cT4R4fYKK+JOdAeLiBY
#N/kyLDY0nxGt15Z7jkXjCBbLdm6qJck6D7Fra8P6Omn7rCXAAUQSEQFJL2LL8WQBH/yJxfXCsk43iWWjNrlV+Q28ZaKfBeCGnf1Z
#FCiM4yVGuzIcVyfSJbkiyR6AuKGZD1286oVgohQ6Tj+kSWLqeVeJ1iFPJqc7Sh+GacJJynNZcwuMoRdhVAETxyx//ATGOZGzksgV
#gdN3h97zbP7pCIKoWhKZGzs/fmEUkQ+wImOz47gW5kdPA1GaOKtPTc/r4w9NzAHNAdbGMGOEN/X58Yfm9ZnZiQujsw/r948/nGAR
#KQVjlqmLk5NysvS77kqwVDRNZ+ITU/Pj58ZnrXSMt1EXPM0co0iQwPO4dXcYpVPLsYIIEYnA+IlmPUFiYMZIi8LbEaWDVgvt3iUU
#dGM1gJ+SzHl7xuygO9gamJTdzImpM+MP+TUzze2ZnhKtJm/z7gkKaMZqlbU8EEJgKLfbz8Y9kReyvDGAIbGU5n2RbbK7Y7VyGz3C
#TULaymAPvdojffTi/PTEFJRyYXxqvkH/PJOnxIkrK94IPAX0ApZfL6tK/5xtpmCl/i3LIbU/bzEyP7dqKzigxAi7Sk6/sXMAOC0n
#1LtUvOqCa16p2MFtd5KazEcdQl3TZ7dKnITba5CuoDXALXQNIV2zE3NAVgm5UsADZ9vPFz1s/8WpiRdcHFfHH5oX38ZQpMW5Sox9
#vj3dCuVQtNWUNdIGsrw5Vgqy/BnWDbICaARYr8NOVFqvmq7hcKBdVM5IZ2pp1I+3wpV5tHojGh9vDs+lqr0unKOyjcUvzmyeBYji
#kmCaXUMtw9PqmNMJgjslhyrpaHT5vGv7uJT1DhpRS1z5dyXkEVd66apokQzIbBMZQa/Sohcw7HIUhc1u0YbmI4+qEHis/2yM/TbH
#Uyxs9xTRMD8T4oQSl2c6B9sbnDQpjMTwex2ru3Ff1FUmCvUuMl+uppS7/GxMFOqiusmm1YWEPEVUUKUN/YiqNmrC2biLeKXDywf6
#sUV+/czUc4XaNjta84OJTLZWMRpzcxnx8LQbDSSE3RIXt+PbxHVgrpswy8t5vgrobVtlrcm4JITqX0Y2ATl23tjllohjcG3pzpwm
#XwXvqa7lc8CDKxKY/AbQiXRlbQSlEbxdob24kAomhS59TIiohBmNNKogpnm/OyKEHAVT6ASl6fbSCO7mWX5YqddG+o7KwpNG5Up6
#mYb/qlLRbOWKTIBPJJPN2pnZ0XOwKXmkUqdtECqBjzw4OhmNN0ppXi1nV41KuVI3R6amZy/4pDWzRqEK2yva79jbWhye7CrUYPc0
#VRlKpRy7wek53liSMlxECh6YK2PDHlfwWhRxbXTdrGbZBDBrlWoVlQMNtCpSwR1BhhT9CgYxV/paGVXH2URWxNpfC2mIvfFUO31x
#5gzCnoM51GEzzrzqiH5h9KEY87MJfWx6dHJ8bmw8Brv1yfGxeYWjOzs7fYH3dXpdf/D8+Oy4Xmera1CGo3AOjUsuOR4XyZk3niNA
#FQPubusZqBXaSnVZbeXcEm+f1O+JJvQYbn5JuEGCjXg8Ed+6RNoVieIkxmlQnN6jHxsaTKWwWF41MPByxchX9lx5REI0SFUmMhVb
#B6IyMjTozGZL3FAzLIbiQ7QOvY4HDvhKNz1JUo3FF4bLi6LIWiWNlUFxuRFY2cXKSE9f6vDh40DoCyPkElUQjK4L2cC6AypjaLuC
#ADOh0wsb5I4Py2bl1DaWMhuxYoUQeGy1kNDXlWEwSsjxx0qiSpx+bH9JtF82P4nqcEYsbj1DHr10iWTiYuoxX0k+VQyBCz19i2oT
#DLpRj3LIF2V6Hk31HE9f6lnEAuBfCQZnaHDxOZB0SCUxunkQQ4FaLV+WhzR8XStvxGkk6ARBpJeQUYVOzS04xdqLXqFYqaYI8YFm
#kLgvVrUhuLCMaW4f0Z2ywQUhGFx0SshsGVv1OuRqxOtDO1QhmiOBu24SRKLgaWGDpHAbKGXLYVsLJt/rhFneSJBIkC+WqeF8SlLI
#ofQRoDO+2LQu0U+EkZqvpM3ui4VlBeD4N1sKNQvr+TRZY4qZsCkbtnGoJfW1S8bRwWBqOiZX50caTgKsAMgit0DC40X9JGdhMblz
#wP0WGgmzuWnKFlxpGw60iQPtB26iKaY9tvrICFoXYA1SDiadwrhvU3DdmgucYpF7h312DVLE0eOcf6myc7K0JsTJgCpUFC1IDTH2
#AvPbwgiBri3ea4TQNTQLMHOSeCMYwVhcHdOYIRuBrebLRXYQWSqXNvgO5VAAS52MRGYmzqQvjM54hft3yJNiqcXPxwdE+8AdEyxc
#nEpoJOUf7Z/zPTZwn0pci9bo0Iqam6DzLfyxVC4xZCO6ad/yxeNyNPECfMHlOplMg80bVtewKXPA9fqeYbiaIuwiFkhrL1+WpmFi
#CJNsP4C6ZR0J9R2N8LmqdZCxGUnD0CkHG6SDnErSAWQlh4dpS3R+tvIoO+UZR7WQS1eWxZbfxq14zp0s568Af8JgKA/l4kR9ynS4
#F08S+gOoELsRxS9OzJPmaqb/6FA8uZrfyBVW8JlvICl9QwrYyrm04VbAx0J1kUgeFKxCXVW0PNNvpmkeYqxLIFnbVPJu0RHgxEfN
#Nfs6rlRjrpn54rIem2MtbCojoV88MxOnC51A6pfoXRi6MIMK0zKjWcO7xMqxGt+KRIaf23cZ2rsUvbSxvKz+mxcVjeNRZF5/AdaH
#R36cy8Q+kgZAkn9iwjd6Nj0xNT4v9QOSczBG6TPnZkcviPOkJB1yUKdj4tfnXAiTlXO1SgyaBws6aqlPADSQukTcgYZNYCOy67G+
#QclrC5xUBKKXi+unRvTjjJ0WBoePLiIWXIqORp1IT61SPwJJjw4fX9yi7m3Wf1IfQgAUtd+OtU9EfVEuIXyrACh5yPLhuSkQV5sw
#4jpL0wvn+HpRbNCFxB/B4zd+MyCG05vCQ/yCs+1oryBTxUu0sdxCYfgRfGaW1oJgDOggm/gz4DxPUIMegbHpU5p4ZETvR9QAxQC2
#s8muvLRQApK/VKkhwEAVMKDwxSIsV/+im0pciwpFd2gevknBWI69mC9q32RATjRlXZEASotVxQUWhOiNzS3YA/e4k+GeogMSaadl
#nXviAsbXliSRFWosZWECMrlchwJtdZV5wq4zlUpxnAhaxRANgvHwxsWg2Wm0XwedGTnGc8XWXnBnbTfKsVbwr2gScJiNGAIXGyZo
#Px0J+jJcVEyC31V/FPh1KB+3+fSqRjFTWspl9I1hBZltWKeRCWxLPO5lJpHYekNpDhaixByNML/km4aQrqRaw+haANYEeJpFzGd4
#G48th5bIezRpRnsxkcmuZIszWhpcPKeFvrpOZGki6AC9mM9XYf0pEOLLQ1rNd+AuCHVykJJX8mUjJRdpE1biWLyMouyv1QToGiAe
#ALaYi4FD1ORss8XT4Sk0sQOItcXhNnFX3CSxg4QGyGRVWBgUjw1ydKdSlrSbmCU3rwrkaBrV8qxrOHRX3cgDJ5HUxxV6Jq4a4jTV
#q3psvZAhUmnzNnGLtAG+SDBrgngTnTUBXVuyzcgkA1pnYDlBheDDLE4234cZPqEjNXWOpkoQ8KhfzmlNv+xSZWg0hPIPLeIXynWb
#Qmw5N/hXLTrpBoLVsGfBVHE4TLpMA7TAQrEwbMBAjdhrPtYDa50OjjBuQzLOcj8fB0Zp8Niid6FXi5LSXItWyaimYOKqC6xBRbhD
#Yv6qLBf1s9h0PwRxMgji+inMakqUj684VLiJWLBJLAgk1+KmPTIK+bsWpTbR+MlG0P5H3c/gSomR2c9rm3FPxOUGEd7dRMIXxUkN
#PBdyjgpz3kprKCQuJCoNCmOS6WotBvo11go3XX6p0edtq0WCicdRACbOeIvQkqsae5eSatzsDb9mbzRo9oar2RuyCgpONahEnOJC
#RdBw6VlU2k1qfeJkV02VdSfzL79QTkvzlIRwxdZ4wY4gWLcMVDoTiWBKYlTQNAuCb7FBXcKCG0r0xChIOzQ8BkODWA6QfrIwzghD
#kBuJKVR1RYQysXkSYRLOxLrBNYNoIuZECxsqXZUov15z4nzc0ykIf4yM2ur3zU1P6bEjqLMct6w1iS218gjFMFvIQcvKwCkhGSBD
#nHl9qV4o5hSbORb+R5ZIkcBKolYDSmrvOwVJPaX3JVM21qJ7pkL4lauXqiYgCPu+qJuEKUqkcwvCSZgLE9MYbyL1qWYMtJ1ojsSi
#CWSth1GcKzefVtV206RmW80cqSWoSSP4Segrj47gaJE2JhoaiHHw0bhj+O2CngNJKF4rNfUYjr84IcIQxTI7Dw4qRE7dn56fGJ9F
#+cZCrC+BlzazRr1AyC02kEBLI4V1fjBXjw3Zfp0tnZLtQIo7nkBDQvReSpEC+voThF1X8pkyF9d3NEH2D5aXdSXctXJifccSeAEU
#l5buyN7fpxSoX8g8UjE4fDBBBu8MDJ5eXi5k8yLi7gQaCsnXa/myLGQAscdYplpDFWhv5QMDVLksemCIelWs4H1yCsBunjYKK5lc
#Adp3Dm8kiP4OYslWwCKP7YVRVOAdTLFv7OIFHGdImFqUVd6hy6iFSeSWH5qRh9m1CpuWFrYCJyO0pyzam0oYYKsS2LSJtSuLk8TT
#Kr6nbxGSHU2l4Hv3Uf2wHoPCeiCf5I0RSNKF8nIltlEVhW2g5Ebs4xCLgR9Rt4Dl4jpyL33KTghDTtqtQqQJWWCLb7UCU+AOU9G0
#xBBZDEkSYYzKBK1FwILYXwVOceOOPDbkWrTOHTAQSpH1QNWeTeS1KA0j0sT1os1G4A/4yKzQBorgs2RtFBrd42gz6YHn6WIwzjOb
#r+1LpXgLC5lYBwGa7pfV03t3ksgzbilVLZuGP1br8ADoOMArpIDJhrbqvb2UIr5JOAcgDe36l8kgrmI4d5hVjw4PQkuFltHhfnDz
#+y6A6sp1QC5XYFqOQpE62qVFjfJe2IqZpo6LnO7woHCbpFs1Nr/LRk8AIlGFObMBiyJFFzjScy+YhGGzZMmlalJo0Y1NX5yajx2O
#6+WEPnfxQgxiqGVxVCIWAcxLxvWcFSKaHNczMBKO9R3FFBcmpmJ4OKjL0qifdj7q6tjo3DhKr6cwwqknNZLS5zEiJeKTrFImg2Eg
#nOFQAGsHYCgM2PgkFN13VB+fOhOP80R6G6nUL8o5eSqlj06daVBuHxebolL1KzwW3kJkI53Jc4a7CSTJdyhwwTjo901PTFlWWFnH
#K1nIYUMsnbdzs9MXZ/TTD1uTGEUVeTKW5pIgC834a5ubkfT4hZn5h9MIC5SqLNbYmlSiF78Z8UsrAB1XZAJcBykpfqbq0pliUTIz
#hWWV0UD+gpJYvMWAwlr4n3rQ4qxcMZ2HHxJ4xVkG1WgzCqIO6+DtmmFtpaDba8wUGgtri4xQWTcecR3sTqLUe+o69Zs7TT3m7sY3
#KT1JgLBhm556hczGzWFZ52xq65SBSy+hYRiH7J6EV8qgMoNKCbDpyuw5kZiwbWETFbO2gN0g1plMpPGTrRi8Bo3t1dGVQ96sP87Y
#g7zMzS/TC78irYtuWztOEa1uN60yo2J9i7BMlEWX0qw7hpUp7Apb38GAK1wWIDirKIOCENPlFRGnyA2wJbIJFyaPS8BEO5xpFEk4
#hhf4YVXdVBxT8TksXkSxLUDxozSWMSp8H1wa+k+IHR1r5JBswmK0G52QkpiFlM7KGZIv0HGpuInhhP3CsiXlwsTyvPSUelzqlX/I
#Slh4QfmsfaivBNIWNtBRKDotFQdqadV9/JpQZWvCPF66mrlKR+KCitDNrPR6IX+F9ZhUoZ9npdf9zzcPqyo04lQTSxcnmlSR90zT
#GrqaXh/2PUSAPZHpXyMhcKnRg9o3iXviPUIpRze5OU61IE+zaMosnUKlcTDMUUY7vMBxaNPQDDeAWofKHszAMdblHqfMSKoQScal
#roiL7PshHKH4aV1lHLG2Vx4siLtVtKGGsfMw8FHLrJHcEqZ9REeu0/pNwjaFnC2t3bT2ozb0sKRBwqdyiJhZT6MZUnVoLHWBZ39v
#xxcN9RjdSaLzDdojcJ/uMnWWZ42xWWGTZKhmPDI6OZk+Ozl6bo44LcNg/VvkxvAfCzU4TLirGQB21a2vlQvLeULZ+kpmRSebiTpa
#8tLZsCJbZFvKoDE8/Jp44xs+VcuAONqRAw+x+OLlArQ0h+o6TgYEr1PmsnifhT4rZM1sVV9G8cAq2rI16xk8NQWmJFcCPneDTISj
#2XFpSFwXTcebBFfwA4ha6PrjQ5CP5ulkfKmCL29Aq40snS1Ag6W6L49ztpQDR47cYuSrqCZFmk/A2kBQA8aGoEggpjTOVRrFFTHU
#GlL0vZx8B6sB4QvrTTWBJHR5lH+2d5AmzkEIrs1spqywSdgfi2URprnooRF6msjJQ1FSPvAAdtZTlVoUi6boli0uHGIfjNhG3NZE
#klItcRWXGIsFFlbKe7DMZIqc8v6jsc6aChY9a3ZskF1eodNgqgk8UQ+WxhRQCr3NY5/HQSip+cV9aFzJrp+8AH0Qoky441o0lRR1
#rlC2EyruRccd1JlMBMeoTOcJIQYlSO4WZ5wFY+Wh2Er6vKrYlecBGC9nlsi0Fp1ecpTPWIvUEznYARVqV0mJL+53grhcVOZ2med2
#mTogijhbzKw4p1akhDQWevKeL5YWqBkLdhMW48RPR5epwGGoGe+/4ymE0LWUbRavCKJ0JkX/o7rlUNyeLjO75WSxSQfS3XHOmzfE
#M4euY92smAXv8U6FxsnMcruncRGwCbqcPWC+HJPPhFVgcsRi40MxDrP7bKyrh7NMwhwLH8fWuhPPDhRSG/jwJnw3lRxb7DJUHKCi
#HbEdcDDBhGeWafUZJcDuglU8oZOhtCv4lIhoVjQRJZOMCVvoew2o97ACEiZefWGYAIDY3Ny0uGFcnirus3GTpOn0DMSCHAFGXvJ0
#c/vIxnFGqUIElWsZkFyAdE5oxiVkLwfZC4JcG3DzRVo+dmtxdhbto4Nrmy54QZmaTEZ1LlBup17BHUI6TKZWcjxM+NaEietTtayo
#x6gXwG0AR1nI5uN4CFvTvTYQRpaR4yb+33E3u1ZBXprPEvJGD9dEI8AmXB3Nus6hAlQBv4vE1ElNM69xBon2CH3mJQFEzC+q8zLs
#CHSo+0vAgsfy5asxZxNQLrm+INq3SECyrltvNpvJddTdNmPOkwAJ1WKt0bkSGRzFH9uAhsW3mpKtEJeqCgLN8cyrq8oX1l2AI8Hc
#6i5BWsQNMw7QUiQAakfEwGMNzDEg1pZjgVY1t5oMMRsp0b+CKRZWmrJss3/X22q/wcDW0rHfM+zHc3GPPys5erL7o8dyedypGXxO
#wGaqyfiQ9bKHZSIjUzavSMV3ypwGtpaHpXa1KoZ0hHTz+c4X3lPg214Uine9wNF036zuYCem5sZn5/F+0zRfVrPFG3jpLMHbZVFX
#gitKYCUJcbEjrj8wOnlxfC52T0L5Ly6Vh5VW86GEKCouW81NXhjuH0T9ND5GjVuLZo36byrKNzWHclMDxWeP+E/u1LfslrjAAiPh
#VYgmmS7dkxth+a4YglP36NOzZ8ZnUZYKlGRy4sLEvN6fsocAD276U3Ff2SMqc0FznRTA51oRNQlvE3ED+kTz6JKcHjtkxlElAsgs
#80PISBjiINkpfdzO9R2796KHJ0lGgf0YGOK7OsqiXIAtFYwpIsEFdi1KWz4cZlraJtLaKQVLzyKdmgvrtBAu3KywslET5aJr0SVJ
#tRgVun1Id9gSLD3g+4LyqqC8JfhMFwaXXzMTXIW9REQ1ohauxG9BxBURz9bNhMWQSi3a95xWM3wbN1Z2XnBSbu5cuqInL/VcWri0
#GIvfce/tR+QFHoSDsrzwtDA80L8orw1RoDDpKypCyyPpulGMyV0vPfszInGoMEXF6iP4ZGwmh3SS4vAx9ijtE1aF4r/QdoAde6aI
#5UTVEpWWj/a8kK8dJYfte0eYDJp7LMU8D1ovM6XOHeoFSDNYi7wTWrAMYS3GLXIgWm3bf4qLlns2y66+PNRztmJcyeDTlT0zRqVW
#4dseUWpF1HkDggOHe3uj1HdqJ/cf3Rge149Qd54LzQHFijkZ16d74ZHZ8Znp2fn07Pjo3PQU3YWI+pii16NbvziBD7E1f2tCj7pe
#n9+MPDA9P56en8djwr5jKfZOjY+fGT8DIQPW8QVa+qosp6uFXKyqLkrrOoAcY3EbQHAERqwqwVnesq2kpblrpjKowiGPQ3CR0Rm1
#r7hUMpG4H7EZvDXFUlge7+5F2V65+jy6+vpOTZqwxidOaEElo8z91+S1TUd3sX1CiwtvEkmAogvbfMXPTiFwodQckq0WqcW7xM4J
#37IrY/wiWEa+fmI1lmhV1TFYNXF2hMdy3BnP2YU6kiINwhHuqW4f2dbY0pPg9lkJFlQpq+9KyybarfAcOTSbN8swFE0SlosXQJRC
#KRboXLqyhkNeHY7CohXQNAT/p1LxbVXEj4BhLfz2X0VfzuDLgI4XvzP6cv6K/ajl5ra5GmioD0fTxzRb4gIm29J4hsWzIHkRHjay
#MMLmFJxsjH0+IsZZ8C7HUinHmYTvhQsxMGRGDxDHCpstRK+9FRYm6nxZM1YgODMxNz8xBV7Zhbie9evh9XSpaV8Wolllz9+IA5CW
#OmzSL9uXcBgqkayAYkNDcpdb8csekZGu68o2CvGYfTZjdUlR77X4aYFSSEudB1xeNAEQEiEndRUxw1ZYEUC79h1RE1/jFTuLQ6Z4
#Z8Z6LUA/ZL3Rwc/RiEMPetJ1CXXG8Tn1ZXzOnizl2eyM3Xhgi8qejfaaBT6M6MnwBk513ru73M76WW96XGjZVWnA93thTFyUd3H/
#Z8bnxsQWoM/eATQ9b1z3P28sN1snh6114bR5IlovjJTw2eI6bwQSTeC+hDfTfKvr204tYoSs00xZo895psp9OSeczv6snFGxhByn
#lRAr3hMgxQRllXFWNQDLoMaiqpXQusqLKoR70aWaIGaU00iPLCfHWlqI3Apm2nrWQGmSRZUsiF1L0zGdypkAc/tDZk749FC8v3X9
#nMn/5/mCddfLWG7uwFe0JQZgy3rEy3KiqiV+vasHVxLiw82mSh+r9VKmjPsevBiA8SwMVi4IyCaKlCf1ga0bVIPi0MKJ/RAbsi1C
#jRW3105IEREjpKGo0IyErBSVUmU7GqDoLdtkvQ2WKeIBz1XrfRL360T+LNv6msqx9V8HxyZN1iGvxkrxiDFUjq0IlRjXw6ahBudI
#Q0bCNt+lCNq8PIOwuCWZhoRARgmejS1lbj7cgQxCNuiILjdp0hhXA6mQX8udtrWEJM2XuaEGwXAkUTXEqFxReBnJozRjNQRUAAaj
#M/5DyFKYynN7/KKe/YwrIItDZq984dr32cCCwTrL8lnUXMZcXarQ66mHeA+troam/IoiLHENIkuLpHFJ6pYcux5+WdBvhrbkfnjg
#f8ibXLo8aJMSBwlxrIV1OkITZ7o2HWEzJHiaywe6x589Bs3mO7bPqRFvQmB4PVxZY/oEmIlgFAGTjF3KwZH40Ic5uG7SJGkeGp7A
#AVDr8Fms07P6xLmp6dnxH2jZrvss1meXKXVbFnEypPy+JYIYXhRQWDZ1eDnRsJ+43IYWlJlLkOAMdykQZDcl4iy04W6ITu/pYUV5
#GqNypdvaRHle8bR2VfxkqetdVcJDNhpy87nK7DDqifJjpW7cI14RTahQmfBwzcpN5G31xfsW6CG83p1DfViJU92I1FNnAjl0ZZIb
#7gVRyUM+hsoOdXdoonpIFS/PPktnRW4anbZt53j2i42wzkkGslrC//zHcaBxHaDMpXtg2bD2ehFv6T4TaiwoqpeLjeBUocFs01c+
#P5AvV+orq8os25NseMH0OVKwFDb9RmcmIqNj8xPTU3TCT4Jv+QCqWK9R8dopPTWtR63Hp9mBi1s8dspPTmOEDBEulJvza6f0+DSG
#Cz87NmUTLkxMXZwfZ/E710LX2foGB0m3id4GScXtKmN9KeRbOUXcqsYZbJW+pXC/yQOzPpJ/hyDf9aTspkMbiE+sfLgQVBOyjvgV
#nSGVB8HgLckfgOxSIZfLQ80JfTA1IHkcP/bCBl0HlzEkGLFszSNQ5/Y7BeqoLKOPUOssk3K2PoKtXZytSYm7CmZCB5EKAbcStQA5
#FmUWjLc0E3wuvDXmBXIVKoPkabZej7jfm6l590j2sCnbfHUQxG0fMQYNdNMaJReKH1sLDjx7f/S5KtruNvpimQ1yWucrCbqSplRj
#bQYBAtXd4CCtn61rmCtWruj46i0X3n+cCpeGdX1gTx5fI+Q5YMSGD4kDcEMiS3JCkEhBkDKs1OYTvZCSFw/FSZETFVjnYw0PjxKe
#pS3kxHyLs2YrydsdiTkwZ8JGjIidlHOAZkIilWP7wcU/XlBP2cyp6EnVYRzPqvoZS4hyFV5pQAYV+ZCzbgXFCd0kcTrtq/kl5Wen
#+MJuX0LgB9TJanq80nSUaBtyGdXtYcZXCyurOHKiXgdecDF0mWxN8rJyYyq1i6SKjNQx4h8HvOPZuKCz2zo5YB536SqMDpMLF+OA
#n3gzlq3UQFRtM2fXeffHu2OnEZFjwQ/94JCMsOWRGF/vlQcuUqWp4RY+ofenUg4yCkNg4D0Vh2LtdZNQS4busGj2DNVdt0MFlYZg
#ch8d++u15MNmOX6oZnW8ytncCNuAjdRdqqq6Sz9EUzt+R4Hqn3I9ErJJj5+JHgjie2gcKNx0w1I8EO8r3XZ07/Bh74NQyiUzJa3n
#aagYXyzlO6TxzeswGOS69ZVQLosJGy/Qmstsn+6HaJ6HIWW7hnl+SEZ4tmkk57m21YMYgTSfeY06GF79TlYAt5njuMMoDzs2G+ha
#O4iqrXPNweRZdOhek7myKDCMUWE0xtIwxFgn3+TQSkRAR4X62HrcAe5OdkyC+aZza+R4PiWhX8YXM1dQPo2m1IZVJO69WOHB6JjV
#tuaBPsCjxcIaBkYPRcnCg9Chiy0cSl+6tIhiOyN66dIlPHa+jGpnkI6pg5EjFEuLSx+bnpxEscLUNNkcGJ0bI901bCWRclqBQonN
#tkqPx9rRJjS5VqllituTDarEmVo0OXH/uH6PDjWMzozrd126dBcKMZld88YhIceBSNBwNBEhNpbs8AwREbfvtCaszibUx8uejSbb
#CgLARrBuwEBKnz57FgU69yBHQVPUDO8rXWZw0A9DGf4iJXFRWbnq1kAMJBMv2Eq6i8/1DWe7qmbXnD0MjU/rfa5CK4Wf0Jecl6GV
#OH8q5Kux7KD6hh/VNxrdmDaa3pg2nDem/VGqAoguomhnp0i+o+cOlKq4FvVUyiJqK0IbEF3HTeumBNJ101uFJ8K9bF1iaYFdi9Km
#BASs5Vy2HSBMelQDg/LetnsWLVpBCCg6zIiIxMQrxJMRCo6ahUfRRwalbIoO0+9E4Zaa17PClcPY0ek9EhQ3Ww08K94tOuGSUduH
#daayQRXNivLjpJjuMrLqlrZ/FHDIYeJPMGPTvVNjpHjYT81OfYqHbhmQZDvmFHYD5rP07eI2rnOmihMJsV8gUvWkUinEgZd582UC
#5VqoyXdBFn0xXLZcE1Za5EEGLaisuMdFyMKni1LN/vpUDZtoF9o2dEQ7xC0J1DJ0yvt52laMSr3qupnog9nW8OK/WzJvqKc2tAyw
#WSo2wxvTXAPxj2uePduKE/XX/DGo9yzLWTiawRmR+lqGpa+lWnDwnio0wGFKKluhS9z4cOly+emDqa3dYtck8ytY3h7OqJhRDpce
#ibK9oWLsh9V5gGD7eTiOUvyLzTYZdiNtLnWBr8UwZFoBohMCb6OtLkR5tKEfcY26Tf1XmCzwKx/AUFr+hKNfgIxWFK9Q+Vlx9NyR
#3qqgmEFa61RDJxB03OZRPE7T7pBbSEVXFqwRgBWt+iSZhsTOu1MLUYcCbnTRUZYcPlma5ZflefPH/RmQFSqTV5e8GjqsDjEZU6Zh
#Q0TsrC2uJqzDFIqUKzb4EO+NKCZKuzelwFMjqq6uH++y0tSgKJoUt2q5XdaS0FFOwnDgllzZ9EbdSfnSyjTaWP4hHwYZ29U1OaFX
#qp7Dj0rVc50CUgmgQaG5WSmuk4w7VzDxsCW69eHBUiaHzz8AUNRUufB1PcviPmv2I0XWKa/vsyzK4NKdZyc+kF10cSJb9s16mpt7
#NvjciWHx7w6ycZjLZwt0yEUvBpjiqjs95Cav2izhCq0pwm+ntpKvhow4UJdjqhyn36O+7an6MnjHwO/KQTOlowbK/NEc9C0qAA6X
#u4Q1wWELeCMdjZit7U+PVOWVU7d4Qrc3U06eQCGnPqJtD1nmkehBcUKl6ijuOmTZShXXufwt+y2KIMfLRl8vI5tJ4k3NJN+zzCSV
#25pJcd8SUjAnmEnyjctEPUlQS3kUJQ/qmp7RJ8fPzrNJRfkw3/SUfJVvRFRlM76ZpOsewNFU1MPG2vZDKyixXRB2icQLDiigxUI5
#xG4W8xEyaNuslaCUKjawt4biSFzWVJB3bz28mBBY44BxsHB7ruVuPieXHU1+RqdUKaPZaj02NnNR79VnRy+gXdOCucYiO3H7hICG
#0YZ9Zh6Ze5hVJnArGZVGoFYLxOLlEH/jsyFAvkeGSHpbNSpZi/XKVuvpqpFHwyqs5R6touAZjWJCsQ3fgBJWpUr5Ei0EsUJy9h6g
#gWmpaC/W3ivy+T4sR0Z3SfXV58U5El0CL1KWT/8Nw1z3AUnMMf9ODxdK41gLsM8is7P9jN49xqk8j7/l5EXOqya+PlotWtfCxHMt
#5mq9Vihuo4eIOS1rWdjkBbJdrBicWk7imNIjHJY5r4W+4UXlxAhwdcKSQa4vDKDx5Nj6wuCifDtoPa6f0geFABsN7dVLrncbfSxx
#YbHEaXC5TNQRBvBS9MNzCzZMLJ5wB+AWTmkWVwXRWE7S0lygwuiUmOo4RQELfYAFOSnJfxFKkRWHfXKSlYeSKbQI3Qc7TaoDfikf
#zmIv7ECprB5ZVlxa4EKZgQ2IJ/h1xBJzRRfypXmSoODBBURlHFGj67DO0QRV1FJ2MJXMc1cyVTW3ueyMO2vklZz0dmYOe8cwksTF
#m66bmZV8zHq10guBlMMiClQI2lPT6YFHqAo9mfWVWKP8InGMrUspbWkMmvz2mgWc9apYN2zflMFSAcmUJLreyikrz/od+thcP9q/
#RCskeXOYdTz1aA8tm6mopUdpWxPllcdMC+ANx7MWw/Ig95k/WCTwECr40WDCms5Wysswd2Ppscn70/Nj90dhVsWRhCvBzOi58fTc
#xAvHMUkN+BLda2KK8GhCr1Z1fj7GD/PRES/QTWg/1IAys1zBEBPhflVRHkEXcsmCmSus4Og3sGnqed/Jd6IPmb3ZEmEYFERVSTZq
#LFkTD9QPB9414UvRS6lo3FO4POPBPGiLIJo1+6OS+cZQgJMGjZWzrAK6+odjVEgAPwIl5cv1Uh6VnmJU5nBPn5/ZMdEgygENJhiD
#lbgUPcIAQLiHCuCnxNTxFC1BgFdS+HaYkkpFNwTTJh30G3yiATzycszNqjrihiBicSJigNQss47u4hEDy2ab1YU+aDG0W/r6fdrf
#qEElV4sM05Tr373y+4h84gLxlE6vSQtyAQwDK1RUSS0iq9AC14BSLqILuKJOkZ/JgkoUYtzZHo5m7E/LGIkAZuyRGZm6p7ydr1YX
#qmyqiwtLUI0+6XAJK2clirCPJnwBv4v+B/hKgjgzUlFpTzqL04mLzSTm1zQ3nVXLN5XFU98JfQJf4fN5XdkLByr8uR4Mt3VeJFdj
#TQ8MRLVqbzskZ2dn4ZTEGJJlWXHYzRjO85KLyoQ7iyCuc9Ee0Zo4P6Hhd49StS7GCai3FYqPBAAXUEIAKGVw7ks1TCYeNW52Vi//
#cMu55iowV0/W8epFL7rEaQoXChSYC9109QXlQywT9m81ahGQNMlMIpCRYIst0PRxn9Ly9AZ7QAF11vEXncNtDvARVjKzJkNEOhPT
#mcuNekv9tHLLfjn6lBCJRIFyFFxJkInADQH3cIOsn1t8KkbiEhBsA1L9TYVNVt863NZThB5b+DTYtHdBQ64DqWEH+23l3e5DfJC5
#hMxJs7f4BuJOG7RXYc9beg43+/wU7kiTjp8agZ7bi1aE+r5PxIXRg7UAoZJAQTblEFkZwBNqx1PJQeRk3ePbACvY722SqBRNh8bs
#pREXu8yKgQcDdB6o4IC4Q3fFjhVIhs5F7OePnoOttTBGB7vlcs2kyWbpV5reU1JvGjbRJk+wTR5l0j065TbMOIbMX+w4UV7PFAs5
#l0UdoeGbLeYzZSYudjv4nTjB12/j5s82r7LhILiEmOohIBBnh90UgNahpiZGcHQQiIeuT81XXlDm5ghhM94dezBDIiofozL452dJ
#jkpA4SdiOMuSnNo3ikipsloHn668ldufctFeLB3PpqUhujyMUw3wPtkejY1NnxlPj07OnB89PT4fdxc25HoQ2Jd5b2i9ELsVw691
#cZHVdJUHGxraYGlgf0X++RXb7DJK3HlpUv4tQfVrfvyNeRn4yPxAcqJcy68YhdpVF59iD66LqXbe09sOHMmL7VvcIqUhJWFnzNFr
#RV9Kt/RX3OMZR/Ho2PTU2cmJsXn5/MiZaV0AIIIeljYCvS/W8dYsv8HuKzR3jrk9rr53A7P8wCP+LAyTEChKwm0KGBgmsWaN+AwA
#zYGUeCcL5TaQII1RsIWXNFsgQWmaM+a8cn3915GENs1JYPq3jQXtEv0uXUsDDo6Dyirv9ewbOaoK6cIiPr/erz4rKkm0LSKoSgvk
#/nd2yAibF/V78IALVKWNII++FZXnp1mlYPmqA8Xb+tViCkQ031OSBsQHmqgEWMrYzgI41GGCnB59tLS0nclFsDt941ptvW1nQTLc
#WzNp4HrScyin7qG0nOVos8qFbrizJAr0VmspjTtTi+A4rcQUm5IYShGg1MSmgB6oGbFfHm9CqkmUaatw+6YkBe2EeHuTtam9N7FQ
#b9rqQv8x94tDbv1o5chYxsS9r4jaqUR43F2urVDtxQQiymrW8ePHbR3sbJM8WXcmZ5228pr1Ljw98EPH85iikTEZy34M8m8wRzZD
#R/hDec7HQiKiBuVWSZp1/zHTwvDQIPDv1nsq6WaslkpgTo+fm5hS5GYeIt+IGikiBdV6ClEGIkUAK4nt0iSZ3Zcu2Y+xOSjUyVN3
#3cVvsjmC+X02dk2dEWQR2mKTN6t1Nsl0RZIWaMO1G7OeflLsuZAPl8eil9lwT+H2uSiV5G9LQdqHl3om1L/50FixWKMnns4/m/Nv
#6k0eZRBr9L/9ULv6x5oIpHMglJrpZVwe0WGKAO4fVbASaF3emRL5siv0lGLBZCWGXNMpEGPjVKHGkUJda0sDQWXRMUKfmNOnLk5O
#OjUSTgqrhwnH/SX/Tgri39juWxOlbl89CLVZ2ApPExqakdwKMh0tERBqYwGpi+4xZOJqAJ+kOa5C1eKugZFW932WzeUGareU3Gd8
#n8EcNxlQ28yePjU9rxr+vpzQFxiSF+XVZ9MlSfXsFJ799gmw84KaWs3Y9IULE/PRxuKqxtRgdnpy8vQon0YZmYLpMiDo3AmIl1+G
#XVbkXdw9s7Q/KGtfp0y+DEydswAD494ESPYaUmx7P4CKZsyxbLp3ANXr4P5dZ4JV9cmhbXL7i88WuW9oL81lyEjcClAoPwxcAqmq
#MAmWINMkCcF6JSQ7leDnVBP8opi/6bRtiAAkFa6THGErVtULP9xGm7cbpBMZ1FL0SU09idp6Xs70zZu5bWb0GTGg26iOx9uxD/Mm
#4tlw1uRFw2g8zqhcoQMDL/Iq8apTDcz5Hpk254Twzx/6ZsdnJkfHVPCzXthtBETbAiQApRKb13JtfJtseLfY6G5rH7tVq7a3u93u
#1tVVGJuUd73udb1NKq1XXTV5+95kbwxMDR5WC8zoeCk6Kt+z+aelXJI6Oe1YRaPi9TJTqLjWKtUqMJ/QflQ1s16PwWN35DWFqUPi
#SKv0sqMk5+Jhbzpett6coVMP6wVav5Mp+1ikL9UElTulU/Kv0Y5U/gFqJDWrBUawOfFibdx+9DbnfvGWjsb0Hiut43Vbvv3sIn/O
#x7OskmumuM1e9GGOGr8v7TfFzxL7ZDZi1bcaRvwT3IUYrWHdz2is09bC1v1s9EqMa1MgrJ3pJ3XL3JmjKKd9tus+q+SMylnlc3AO
#xpx1Zj0DtNqMjD6QPjMxK1VxwPcCcJOBk+QL8IuqonitcOQo6lVA/Azs/iem0O4YXnWnoPn5yfQ0qoX2I/nGt3Nk6NnRCXwho18J
#Pj89N89PvjL/XsvUCtkkMLKkpLsGCLSwCptlumXGSZDJZeMuIhWF4hYepa+A3CjcOsFdT+ODiY6DOIGBHG8pcsfFaQeK0JOPVFfU
#UpQHdC38RENCb0qQkQ9+Ddt6AhufulUGF5AMYKYCCp11Us3lt0cqxZyFhpqcIYrLG26euQk/2uDGBe1EgWPUK2tC3Zunfvs3FlCt
#mtCNfHEb7/xyqXREH7NhgDWwK2tS9VqBA+a7Y3RvQyTB0RBzUjBRny/mnL24f/fV9+JsiPRN6kDedlrxDKXDbhPCfrJar6Whl5mC
#4102sXx5WZytF4u+ZeYKZjZjWOUKlWh8ISeNWLpuFPFme6mA4hggNZV6beSYBaC45YYUxcJSUpx6Jmf5lzOKt3tGrkUvAuD3jNLl
#KrSGN9c/ld+omz0zaB2wty+Zim4qMkpXkeAlFTDw240Qv6QAZnj2aAZrgVHDUTUO9lbkXrRXSrFSWatX3WtlVjwexOCWpl4AcjMr
#5Qwxf3E2ADrHJ1+o6u73VPxa/ioiizllb5bOVAv0DJK84CQfe5LAAXFN9E2Qm7beKTZj9gRZrxxB+XzpoYrGdPI5xC+9E9RQHPze
#c/naDC34uTpsv41C3uxd7++9B9WiDpl3Us5CzhxhJI7X1BLWjZa+FP65iEYV1a5jOWnOzKwCvclz7zwWV8QO172FqBa9JE1MYLW4
#kFoUXCxNBT4PyOV4okr5XKFOPLcSJSaNmfTrJmmC3FQL+nIGVnjOpYjjmJ4NVN32zoeXCqAGIz0jjlqM92yUiiN9WKY4Re3nQU7m
#8qTaIZ6q5otAxUxW7QXqeaCJkXzGAMRrRE/yOOAaP3Xy9ksLY8DtjF5aiCUP3xO/tHhp8dTJXiUFlLlBA+lTxAUayuaFiDRUjNWk
#srtJ1KuJM42KktHOUuTTXaUk3eaMCYU5+z35OBqrcESWlUgV7TWaYmV6xXSIKSbGk+zj8goQ05KPe5pnr3iF7laMNXtT4MeoSwUd
#wtgreVU/toLK3akTEtG4VYw9yEDFSqje5UJm7mUGyYmKwW+SZB0mYlnlfTShaly+GkO0XQUym0dHPImPo9HhiUBZsKfhvKu8A1gV
#xIzYIx+ZMT5Z7Fgd1PJBhnQ/gTdmIO2AkRF9KXppY3n50kbuGP5G/bnqWqnKI6AQYOKLICLqm8NWKYYkeLJo65IvJ68YsIuJYSu8
#zaOZMpNiOXJuF+X3z4Oz23fdKEiwY4dMFwryA8zGu4SGzyYyOyUKk9xWZS0hwOoZqI2IQuwjIIWHswOhCgm6I5bVGitWxCRk+2RA
#E7mNpYXC4jil/LiDTWrA8FiA5FQvfA62MMj7E4ATzijlAXKuIjV3sCDbUY6rNzUS8gwu9gqGvu6rreRARU3sNtmaXM0NEuVRGfvC
#6EOeJHESfSRsJb/y1sdclo0P2xiKddWTBClkG4uPPmquJ4+cZktKjbtWSgoxNbikBNtyojHKapJwO7XWKYus8s1UIR8HSgarqJQs
#5EaqvGvCBnOPqsmGk2U31H4+feFac6MePqr+XpMeMBcVPocpCPM9+aw09RSXNpGoKznbKpK42MrTIWws+bz+SsAsLufhhT5zwapO
#uQ4lOiSgHe9Ewr+cdR/LKrPkNMJikCFe+NaLtTQkImMj4iDRUAzoKb5szWXagsoY0VEkDr24oh9xIOmikqJYoRsQxSZJckaGdIvt
#JGwGRCXljYRElsCL1HNc0jSv1jkq05N+gVe61uBmD14yAtquqJFIQ7uK8U4q0n69yEttrQ45IW8r05CsP+TQiBC6QjJsg8IURSCO
#sA0kquo/HCe8Ta1xKipAnEmBClXXR43Mcizdvxqmx2lizkt5zS7yybt+I2RCOS72hE2baGsMwXr+gY2YNrAmun3bprZKmxyRbRg8
#tTojm+gGsk2PiVgXsPlaiZXV+1mJVeznyD9bfdcpBOOgQrNLEAzYDtt1aHeJgx0402bYRRyb1VTuGsUyBR8DvemEvSVmo5sJlkPG
#/WxvEjBBk2lfs+CtlF4QwTqdL3qlJXlzIBbYpeOtTdleOeTO5Q3bZmFzlm6fe63OyrKtV4GLCwSuiw5rLdaRia09SpyZE7KlUEEC
#dV0BauwMmSm1TQNayaVR3GvRgin1ADOFuG1yVITwXqYgr7HEN922/+r+tv+A6S6IaLycLfxu04D1JqYBVXN70tSdZRmXHY7rJMLl
#MLFnG8tD3RUie6T+WCBaeyXB1IiSYvFId9Cd2/SaAlLII88DMldmVrF3yjvSEb1fvp5I70zQJRJKyfvpopJywJOSzZOLlGbee2tI
#+InO0m4eqcgpUYAwZYoE1oo76Ygjyip6xCwT3cIRoCUkk5XlZVhGTd+Pb8bekeqRYowEPKQRWEpK9QVwsgZDIxawlORTc8kM4i9h
#W3QwgkWXOJHV/bemAoyeHT7SZoRF21WzJ/fYFk6bWjb1HeZG9lIWnhO7c8xAGDb3INU1pIU3Q1p+Y80MCmanm3gpLIHRkB8wXMyA
#0IagCOFW6K/hY0Tc8CW0RkMj4orqueE0Gc5LGMOvm9X1MOTqEmLjMHJ2S8CtNFs6jR+gbbTtYVCUkOl9g7ZkP0DZbEOKFfu/v1tq
#ugWWy8RpmKvU0DBXtaktYnm/hdxiTcsVLSYLAkiHAsZyvYqnxDgPCd2pxrCtgbIWrUDZWJCwzklVWxtatTc+lotoyZVcC9G11koN
#1lrJb62V/NdayV5r6vIqqZDpJJLKUis1Wmolx1LzWwUl4mfkQnBU5yy2sZL+wrVn/XGAJtb/hZINp2d3M96a1WkoNbkaMOdAO/PL
#AF0Zo3iVrqHW6H0Bp/oMbbkaMOdu7kzZdyh8e5XtRjECqZrpjLQ5IzeobJJR2A7B/fscwZCZzhUMwTd7LIosu+yJ5FybTnzFM6Hj
#A6Ej1oErGXXAbdmyR8oNoXKHwNYCk1V+PIuOyPk3z44r+aWqEHobeXF8bURftDDa88JMz6OpnuPpSz2LR54f5ZdE/fbC9doCRskK
#kW1eVk8fGlszkKf69dpz8eRavbbKvJ94cYmO8QT1BgYsV7miyBndt7IJ+8+OzrsFFHjKi8HAIdWg8AysQS6YzXKpcmg697hMI3t5
#IYXH7Civ4JqH9cvJaqWKAOtE9cjpXqb3dqilFsYnDVu7FfJ2Ws2TGRuHNqSOplIp52TRQwEIDgtrjkcDqDuKwhI96Il7mfWFnj7Z
#bFT+WBzmtNDw2Jr6erZoI57xWPx2Lp8vieuohaoYaHHn1noRYOFFFpQtkr4u6xpSMvGIV7JetRVxRBcxPo4WQoe8BHFbTyk2JZjq
#PWp0e64aU6e2tmpZYzUL207tqaa3ObeWN2//ijQ3W2mr5+DNNk/erHgWn2Px9i5wxN4gitsuHHyPV8xuC5ntk4XKWr5Mmkd83Zr8
#qFlgZpbzsYH+uG9znLerxM0KzrqaMVetC8/yFWqp5EWgt9071DEsClUtzNVM/9EhLh92C3QCDdO9mt/IFVZQnSPufqVaTKdoWnoV
#396Kki0bXDbUCsdCkbmxBml4Q+TFIeeqnU9xUNC2bU42YeF8leLssRTQ7niJ+HoGhtaed3FIVRSb6JJKknVc/RzgfzxnjWQBQk39
#BfUCCp8q2TWAOX6SbV7aP7xQ2JgASMbUYtebPD8/P8N6rNIKYiZfgrlhm4nIHxOmwxjgNitX0kYepi2dyeXoMW8lWmjtpPm9MdTC
#g9ghtl1YK5rAlG0IqThP3B2k9To/OUfXPmC81/DNZkT1JGfFSFGkMOCIr7boGd3ERwGzxQIwOvItuKUidFfPZJEEo3lH6od9n4Ru
#asTwhbiELDIhSpAdUVASNtu8agJEZVlqiKak3FhPuagBSD82VimX82SmU5hBmmctJeEzzWJybm5S+ASP4EaDQqWSe0xNZpUjUk0w
#+LVeR5uBzvJpcERM/XnqrhFT5/c0cCs4x0I9SySR92p4F4DCqAI9X2gpaJF+Fgsr0NyKkkKoApZreaNMhzw2ta4alVolWymqybHu
#3r5kH2cTyluoZJmypwnYC9RhgPlRhoTBZQU2rLUaT57oEvLqDE5RlS6LycFs4mFCjHO/q1JctrTLoFbRHIcCtTsd3maobSSvGJlq
#mldVTI22TFmYBaBDuBgUAlQncp7k/ilwCVOdLsEMonVFBstlNLJ0OBN3MY4RXii8xvPFqjQ7iIUUPEOGb4aKuwhGHU/wjMrGVbed
#vo1lIknQA6Gkxzke6jlbMa5kDNjSoYtvFLlZ7Y1lCytvLEsbpokoWlmUWm0Lw4NHled+BA3A6jzAqwJAOZdGLTcxGpWlRxLSenM/
#EhWpT0jTbfdHqJmQflyuXqqaMcoJGKQOu8CMmS0URgg84xKFC+0qZY4YsKB+qcomnsjwS8LNiEXHWJO3Z/5qlYySA9YqFrL0fmcv
#NuYEvpxowLSPNK7OXdZkvrxSWxVcIXJ+pIwSb5o1k13N92ABRgXNfEbLlR40aJT3VpitowUTkdN0PXUtmeOYiBbX0oa9VWJKV9l2
#rFosRV3BszKHao0y464WuUDZ29mHetRR75kmHRqTe22WC8vLTUd5Nr8MKDVv9MxUYKauisEyRGjTrLAyjEzJUeOZ8amHtzWpc6Kb
#SrViI9VjGln9Lsx51wm9UFpR/ATWwydgasrOZGYWlpgrqHa1mFfz3lUvI3vZU6BjB0ixTI1HSoWgYep3lSsUjtvYHmicFQCQUOph
#W9OisKgyYUiA7SWqzFTZvpnpxSou4LZuCV0YfSh9evrMw6Si66CtsHOQkcN8K0cxKQiIrVIBRtxYUUHcyFyRKM0giCMV4LKqJbgU
#vbZpi95dOrWQ36V8yadbkMWz21Hofk5c0PRrJqAhYAeQs4QfvDXoxog5e2SzlcpaQdIBUjVuog6MpibnCmj7bMzO5h5zjFBtf7nq
#zi5gLYv8YgZ1DDX9YP1npQFymxdqeplKnvBE7c4QS++CEIsIKFw/UwTuQrS8IdV8sMVOHIEGz6yOegulsz/YjhBHkDdq4n1fEYJq
#13xUGfMjjJS0OSmcQZYGUqKuB6lNyjUhiHIpX1ut5GyinKukz43PuxvrVeRk/XnWuKQWoJTLpWedIAFMnaLwfTlIm75sxupJYDyM
#q97r8ViM5Msa6lfbuIoWs3qnmZ+S8JTLzyKgmnkvW6vxFO1DQ/tTZKnvekiWb3I3cYymrIQOwnNCvUbh33j7/NUzFFlsVS5WrS8B
#lk7jhdiYa+kIzWtLZChUontjC6me45me5cVrfUOb8UsockTxYdUziqUGV9lmJs7whhZQOWofoP/C6AxBoq0N7aszCxn8dWNtTYi0
#v2YqKj80usmSjsd9RogS2ZeQ0tYVpARt+73VPBvghoJkv+kSRYlot2B6c6uZQ0BmDXDX9G175niqHJoRzeYKH5XmQ3PsAuE/byIk
#SqJZioJoOsEoThRBKg62PguHCs0RbJQtY9jefOTUV3ObzFWzt2e8M+hQNqfxpjb3urciPJQspGs2NPIBPkzaGBz8W8vaHNTSPt+S
#FXjjVspnwEmtb8T/bXBPQaQs4SnKPnOyS3K9SKtcL49dZvpzWVybiQLtoj3+YMq+UC0T0VOKnC4lkjkucesyocn6a1QgK6+QUfxt
#9sB+dcrugfNBxm0WxEZqHeU47NZusxh6/MVRivrSjU8himbKswLf+Nd8LSnSh+taV+5ntZpixrwfGf4nXUo4Ix7d9ucQDTVujXuo
#ei0tq39mQ9aYsEmtMK/ikwsN0MGZWN79EhH0sy2coz5ogzV5miCObZFPe0x7Y5dyR66HcP6Tg6iPHgwOkEK/n0uovV7iicxNb7Qh
#R+Y4bUfbYkNoT5Uead2qZL7K3qzs+dH5iTHm+KoLx7DgodTgsVSKCsMAtcBYFMUV0Fbo7TqUUTGgaMt+h3d90kk9pe4t4PMBydVa
#iTYEvTyH6CrRLpYx//baGXWU5Vcv4YXlzHohC/t/+Pjxl95iZQbWLPByvM8WhZFPK5w28NxpplDNizMD+4BhNg8L2O+BBUvTQClo
#y8tmsFl13H2UW1HnNTP8o8d9ttlB8Uw7+zcRE7nGq8FbVuo2emZ6but9dNV/H03f69wf89VtP2nAaLXQc3/+qo9IXJRMRhEWovKi
#96I0IrZaypCtCGhePi2ODUl/Qk3cwOLe9UFUvYwaIBWj8Gg+1xD94b7WEpRZ4rytmGI2RN8rrDj7N8tjmn6bhUprN1sV7DT3vM3C
#5a2SpiUrpuaeyR72ulC7H2xNPRQl7Y5oHxRBf3fo2bpZq5TEmcewnjUqptljFmp5EtGa8tATW6QXaj9gq72vpDZjphDKBIL2gm2h
#KqHLMm/gKon0RYSGUrRQHUYz4IUqEKyEtFjsSLFSrCzR+2V9yNEMua3aP7MOW0b7MzXYfVRrpmWtny31J2kY+o8/8/VjEMtEOkG2
#bTVaP3FSj2g4Ms9K99AWFSkVwT7kilFhKy6riP5JzSGX1PH8RL8dWsW6R2U8U2eETW816uX8FTSzmvSFB/xTVTqwr54E9GiZItYd
#OWSe0GcAJ4/0ntDP12rV6XLx6gl9Dna9cwDXI5OZjRP6hcwGGgoZOZQjUkSlJ7ZQN/GXi1lHXpbwGF8iW8M7elGolWK8ivhNx9l+
#ZjWhL8Sic/lajyVnz67FFxtyOLhqeMPMvAx48frOWiG71kvskzeY7vkknNtefgI04bM3/2cpVHEsY2g8rXQBNkNiLV9nnXOo9pGr
#XCn/4AvUidPEMDZqD7AinMLxpPZWhbrmuFHh62tpSqCWnaBE26+BwKVJBRi/RduBwRTqikKmQuDmyOQrKhNgyVx+sxfIt7nYRDu2
#Q4Eq9ZoPCaqRzYWGh0t+QwpZ/PHu1pbm8G+blthUpTN/NbMGSmbXy5Y0Q1QqRt4+Pk5F3ejtn+tuxz6B9VH7+cFYoe3up3DX8s9x
#Q6Uec/FJc1YZ0JVHkV6vPFqoRolseTnVUdKt6xlHGKXXKdT7n1QJq+JkF6AY1niEQgkvQBDiAEX71ve8UOnQs6lwQw3x0WSxirS6
#lBAj0KwdD2QM2gd6hmMbbf8nUvD5gZR0pDBE6E5WKjXUoCwm8LnLdGYl7ziQLxLfW0wWWRXMejYY/9CKl3KdA6hzkc4bHUYOrfLj
#jvkjBAL5VXGTpyDMiwaA8CXcfNXaS7iOObEYf+3zHxiZZWvIVo/ALqKURycsHMAkZhrdXC/ei8BVowJvJVsDDA0DhorCaqepOIfE
#Dq+/9PLC47qIwXSshMx6hnWE/NYIhhXw/lGvub5yZKNUdHOOXCozyc7lhA2KiiDryT5O7tYYMcWtHRQvcrdtHFrLrEDkXdFDGz2H
#NqJ3sU2jJD7DgYqY6TJeoCM/Kg/HFeyUJrL+jBAUm3FsOppRZdzsjlEEDpszCMbODnGAqbdNE8s9eArUc4Gfs0EmhsbgCMxbD6BJ
#Rk7YOTGK8UZ0y8KTA265ghdpjM9nEJltUZNvKQ2RyBaIxF5HVpCwhIgQIGfVnmVqiod2EKphIkXjB0U4BpiSwa7Wq9drm/bi+pR3
#or2HAFyZfC7YzWpS04ZlKoQ4kuChyiqhR9i7ePJYyFw/qfenU6lU2nMfSUmpdBPvLsEudtjRdTwR9tuwKWkWYGjw6hkZlfJCwjOk
#ql6QFoPxL5N4Xu862Ab5ZQUhon49GUtUIWghHXkJJ5cO1Jqm67ml1kL5f0JItuUlAKemv6Kvr9xcK2WA6ooUeGqbJp348oqsNreU
#plXFPhbH6awFRCGWOWYHGUejj+LcRFhzEwMAqUqZtXyuAP2SukT5jQKghsqaojpfk9dVxMWVWA0VPmsjlrXFhLikwnkYrYs22tQ3
#k8sx7W1CIpOPyKb55XMSS0yOyJ/T+0j9XaYmHxydnUI7v5BOF2nY8BWPcJLZVrzlIp56HZ2ZQOyWK5ioxyR1RpWJ45s9sWhf/93J
#FPzXF6WTBJkiTWIMvM7tAgUuiGHXLgZyLhX4kjC+ayvzOvKYALz0tivpPlpGoJvrWzbTXqU7HeI2DC3tjVoMvTOz0/PTY9OT6fnJ
#ufTc+OwD47Nxd85kqVAulOol5XYJZoUcD3AAOtf70v2ejATa2No08DAAoI72J5zKos5NJo1Z0r69BF8nTXQMkNlYcbbRfhGvP2Ur
#9WKOwGkJMEeZZp8eETpBclk0xF0tQrt1vEvTyBhtY2kFmYOgR+KaX5OjC5BR1bKAdTncSNu3wyN+3Ru29+ONVi8bi2+ydBsu+35+
#pvsZZJUvfD+DrHJV8aUjND2QX2/afJrOKl6b0utV3P8P9/bC51AOXzqzV7i1eCEmziICgiECQ8+C9F3g6g6tVqnGDqfVI9IG/RGg
#bK7WayhEbdIRs7BC/aafmPDNTZybH5+9kKAam6ebmJpXk8mK1WH0Dpl4PYMs2gOGSZNGXDpNcr90GulUOi3kfUy0Ito/y7+kPH18
#DutAI7p3Hz1Kv/Dn/iV339H+of7BvrsHUwNaqq+vv29A048+h22y/uoISrqu4X68Wbqt4v+F/lnzT7coJwvltWcfEq5//gf6Bv51
#/n8ofz7zL9iVZG3jWeowTvDQ4GCT+R9yzf/RAQAXPfXsVN/87//n89+X7Eum/pnSpn/9e+7/fNa/5UrmisVno47m63/obi/+P3r0
#6MC/rv8fxt+FF75BC8FvC/z7/vc17ddF+L3byPsY/Nt18CO7tA90/M7tvx6Y/J3b5+m1JqOyYsAmTdq6yOtGvUzbuek5vVTJ5ZM7
#d0aeL8qYGde0yUBIG33dn/+DLPcrWlTvDMDsL4MnzGF/8KPw0eHfE+TdQ+4gt1vT7F/ITOH4F9Je/KOYFP+3f60f7gOkmNa43FtD
#Pp38mKbtwJ9XaNr8NsbE+oP2tSvedvCfV/xJFCXA7xfzol/LdruVIl6cNEwjq4m2QRupo6vOdPfC/0kjX6xkua3YZiqr6El32t3M
#D/wo/56nLK3anjOa9j5IGNhOH33+bgteg6wth6PB0CY5ICAoA4IiICQDQiKgRQa0iIBWGdAqAsIyICwC2mRAmwholwHtIqBDBpAD
#2rY3FdRmRDuDB6h58IONChrgqVJzgkYvOrEhwSgM+b1UY/DgbqooeBMVHzT6MBEWHIwd0LTI4ZuNUQiBn4v8k+Gf1+APtCUi2yId
#sZsAtKFRt6TC2ksDNN5dQeO+gFY1luATfDp8EBKYN0LZmDQShJBBDLkZPAdikPwIBt2OQbdSUFAEHcWg51FQSARFMeg2CmoRQUMY
#dJCCWkXQ3RikY4VhEXIMQ6IYAn0/Ekqsxu4Az0th7bYc6jlw50vB1/J0+CSmgrDIoccwJgYDdKRyJ/gjR24LV+4CR2fw2k6IaavE
#wDMZg8aFK3FwhiswApGeP30yEk6Ew5Uj4PnSk6E7n9SCOPTavcHYjZi0Ez6xBA7C0+EYVtaD7TaT2DCYrMjmfpoHQBgR49dh8G76
#cehY4ND+YAVmKfLOQwdEOdDR8DsP3Sh8MHnh18GSDrwz1o8zCK5bcQ38vnb4HzTBEb1Ty7cFQlja2eC1/dTt4J2HYwOcfm8qoO3i
#pdYVG8QOd2uxoxj3ieC+GIxwJHEoWLkbf58XrBzDrt4QrByH33M9O4I8GPsfeTp0eP9hKCuszQUQZ2ldJqy/cCQc3IQULaEYTFy4
#J3A41BkWA7h5mAZzGNw7RGcgWzihC08bfk5gtbuUvu5P7Qy2GTcHtWpMR9ijadgZvLYbCgtfwyK7WyonMddCR1fLwyInzFv4kd6J
#YFt368HkgdgIxHe3Go9iKafIrabDfA/HoLIjkObNdprYvThVVKtaXwcDgTmKsGP8KaR3T03lNEX9T4gKvwSzxMYgQIT+HwhtJ/dL
#d2AUzNmRzTiW/nR4FMFkHGs9C587cXxbtAyjz65Qt3bjzdwVzWgJyWZqLz2HGTqx+ZpoSReC3nmOnbBj1VwtIp46WbmPQQPqC2kA
#soBRob7K/QgcYZrJxC3B8P4YLI8wL4owz2llEtu5//CLgte6IbRnJy61cE84GDuEc3f4FsBdSKdgaXYZ7Vg79PlIDEo4cqhnx53d
#2tM3ACjeEj5yMDaNo+MI64zNINCZLxAwOotr8snWO/d3Pqm1HdYCgiCeP6+1IqzLutoa17Xbp67doq45CLvPnBd1XdyqrpBW1wT+
#O7CJfQ/u39xLCxoBdHMfOq9BP1oqD+AEEAaK0lLce+e+p8O32dgn6sI+uyX2aTtAAy7QzTdVdINzhW3CHt/yCK/7W1Kt2v/RiH53
#iekIHOY2hHi2urXKg1jUfSas5vAhEbp5AJvF0yoTBmlJ9bRRZ44E2jdhFbREHIWFKw/hMgjRgt68EWGiZfN2in8Yp62z7cb+tnDb
#5k0IvaHKC2nIW+7cd6Q1tgDunR2JwXBH5RKO+ubNmLujskieW9jzIvLcyp40eZ6HnlDlxeQ5yJ4MeWA4WwgFH9bEXL1BW/47LSTh
#IgchsDy79kf2dxpRhI1dOOBLiIuO9LQjCwIt4obfOBDpqOSw2MiRbhF200C7COts5+n4r09G2hPhdgX7h9vMPC4jxsf7tOMXJD5u
#0S4+LNsS0pBGRHCOYrDqw0/eFAkap6FF4coyAsoKfvowwu4LzGm7dtNhyh/WIoA1OxHfnhH4Nklgt32EGjhsriKAbR8o94aPPYyg
#zpC5ty3YJWCToaZLYPhKAUfmRmegTTf3723fv7dj/94IRLnBYW9nV2fitq5OBoi97eAiaNjbAS4Chb0RGuU2gXcRuYoq3Ni1i4mM
#CHlRiEJoGlXsvIrh7WpIDUM61JCXYUhEDXkTl0YgqIb/HIc/Ap771fBfgnDXIK3B93VLMkkFuN1IF6/x4bc9/f3vP7mjK5xo6xIL
#ndi6HcYHEWRLypiVyR2+k+NpZGJ34aK+VkFQvlbFMW3ZmkbZ1OiQ8Wms5LI9cp9Dv4GtVTJ8kTqE2OV1eTv0f2BSRP1q4N9DoGM4
#21tgkFrUkJshhADEHpBDhg6BbeTe2xrualXIZC+TyXE3mdRGJ3mdfAT+AW7T/kYjnkTDNYdbChg6rQgQ/CcBsdcQf38JflyPO4N2
#elxjs0FKJ/Booj14DXF7AvDpAcLy17N0jnR7142Y8J4/d8420BCsT5nJCM1kZ+z5SAjaHoqZiLHaxWQC6Qr3Bg6H21KRtnAqtP9I
#y01HAjfuFHSnhk085GR6R7CZdWomxsR2I4UEHHNkO7ACvEi1u/3AjcyDtCupYl3IX7Qbx1okfwEjhiSQuap2ZjL8oexkCwIUJlZh
#YNIPMBCgwm6AalMDHmpxgdwyBDgWuU4wKKAreA363mLUMEyBM3MDm3dVI9b9iBPYBMP+05DlZsGwU2+AXxd8+aEb24TjJqjoUbl+
#bH6d6PYZ7WCWQRH3d3cjDAK8AedxDcnpAPK1WnBzkH5v2Oyn35dwcKybuDnyxTapUCwD2EDk67GMl2IZx0UZw/Qb2jxBvy2bJ0WZ
#x7hMThbby2WiL/aYVSbQXW030prHERaDnft3HDnV1l55GeKYcOXl8BPqHeo4eCL5/I6D0eTBjoOXkjd3HIwkb+g4uDO5pyP2CgTy
#diDgP4pj137goR3tbUSS+j8crrwSR/lVVl0w6CjjkHXt2L/zyDmgui8jTMaVHUz1jnS1xF6Npd7W1XJQT94I32SyG76J5A749iTD
#8E0PdMAPV9px4KGdHe1c6fuUSju5IYlg22HjxlbY7yJtPil57YN3VWATHHmyD3jE5x2QXPfzWy3+OVT5MYSJfTRsvFN4LWbQDkua
#HYlofQgguEf637hBgv9b9+t6a7sWex1E7wntaokB7Q7vaQkZg1jyj2N71ne16n8N2WOwXQyLRu7vS3cHJfMfVNj4oML8Bz3Mf1Bh
#/h252kQ8t/sncApagHU7t+sd7/t7bTBwuCX2emx/6PjzoN2hGDZhZ8dND4+3MYrE7QGh2W/Cv+8E+R+wudqxbyEe3R/jOYOJWEs+
#CN9ScvnY510xS8kV+K4k1499GGNuVGOuYMyJl2OBb8dI46QcneGfxsBXUeCMFfiLGGhQ4AutwB2A2o8tUmDOCnwzpjxPgUUrcBJT
#DlBgzQp8BwbeRoGPWYFfx8AOCnydFfguDPxb+ASvwdC3tFTegGDH26bjX8LwMO73w8c+F8CZoeBPKcEftoN/FZywY43cJHesb7UA
#rrUldgPvUO15bG1lxOsI2yV2dq02UB57wK7ifqwifLBTVBE23mtVERZVhJXiwq2JUOuR4MGTXJMjStYUVmr6K82q6SlwdrdZnWkz
#PmbV1CZqalOKa3PW5IiSNbUpNb0Mi28/GBGLs934A6v4dlF8u538yAPdHQd3iLQdxl9YaTtE2g4l7eHuyMFOkTZiBMMybUSkjdhp
#BTm4GdLcKMhBCEhBy+seUlE+yUmGsMEoc3ke8+3XoKyWhw9uPAIkPBjevMGWBk1BaQes0mJv1ITcJqhNSDmguRd3mSiWC5pvQmy/
#k5w/ic5dduhucr4ZnXvI+RZ0dlFVP4XFvtv8f5As3vxI7KcRMf4MfB4DfNFivhWD91fehgE7SBKJsoF1SzbwdkQQYSEvyoVZXnQp
#zPKieYeQwN4B8AqRsoOfxSxx8xQyO8HNu5BTEVGbdxK3co+UmsV+DpHg4agUK0wFY4dp94HFVf4NRf6Y4NV2Ma+GMghXGhrDFu0s
#zgfydvsd+3Z7s65kEQI9RYCHIoNOFBmQDO/Ow/cJyeuNNKZPYDVJExBm+LE7WKDLYbMhHqFIiEZo/9MBFJ9Re74s5lTZ2IRecsBH
#ahS6hpUo25rQNdxcuzc1oWs3u0JrFHqLK/RlFHqrK7QYxtDnuUIfpdDbXKFvohIOukJfQWlvd+wQrHEQ/M5hAUfBazjTTG0kMO0T
#wLQjeA1hgrGkUoDkl/Yp/NJpweuMCd5mlHkbDo7tZ97mtMUvWYXh+PcDRryB2gLz20IiPtEgKcMMXjuCEHWjSIHyTYCrBCYk6WC4
#O3Bw5FbGFwEFbwUU6hxQMrvpdECh0wHjnWE7/zvU/NgIvwyftjPY0rxwd/Dg4Zu24hgat8nJO9zWZuVXBIbeOdmvzMk5MSfnxZyc
#5TnhYDx+OCJ8rjnB/RfS/gM0JykE+XfidBxZgGzv0kgu34fNRrlH27Wfh5C2a79A33fT9xfp+0vY/BQKUu7YoWQwjDbc8bplLVD0
#exBzvf3JXbDC98NauUVK2lCegz1LndXuOEz7yR3aao1E6CRziwP83Eht7WchGTLtneHEUcAsRwmz4HdHELhf8rcf3Hfyv6CckjYf
#wZcMYQ9/Geo6/gEsMpyYauPAa/8WMRA734tNTeAU/Qq4dnaHYr+Kzb0nuP9QhHYHwY7Nu6k42iOEiBc88uU3IK24hhE7gy/Bn6dv
#AJi+JXiDyAXlvA/RGLelu6XyfvR9eeL73//+3tY2480wVkpbjI+04UaJB+/fWYN3y5M37Q0HDz7N7aAGdIVj/x7in9zrDI59QOAA
#HtNz2qt/TztymMSou7T/+Y8s4xritKHYf+DECA93A891E43xMR7jYRrjA0Png7EP4nTbRyUHeysfIiSO+x2aYvPXES8Fr+HGJ/Zh
#7MfHoB/mRxCOfwMhdQSZ/nBiLXzgBA8YBlQ+iim/CinbFHHab0LgSztpVinRf8RCfktD1rW7JfYxnJNRmhNsZ7CrZfMe6jxtsoA+
#3ISTUiJeESP2QtQ9NCu6nBXalbXEPoGzDHN6ipp2IHkmeA2dlf+E9X0SPwgHe1uBzftVrvSAVWnr5r12pa3B2M1Y6d9TxzACtr0v
#udcJClRpK4GCqOdT4NSRqe3tVkPeCCEDg7ccMBGv7A0DP/h3FmYIKwkFt0i4wvzP8Hl0x5MPhvf37uU0iU6RlpYYh4+I8BErfG8b
#Qg/1aR/NEfycsnrW1Rb7bQSxaLNE7bFPExChfAjlQH8H/yCX9pu8ZpmXgn8L8O9RCPtDJVzj/bT2ZxD2LfgHxEgT8Hmc4PMzEj5D
#2kcg/maCz1GGzzHGAQNB8zQyamcIYvDbttljufdtHrHcRrAduIgEQ+J9bYSTjRyEtV3DwyF77ROg/aoNaKMC0Map06cFoN2Cc34X
#Adq4ALRx55yPMqDhnHe3Pn0DrJZAV2sMEFNkR3vlv8rpfSW0AJDEZ5Eg3waO3wHHTQP7uM3g/11cP9iLI8eVXG/AXG2c63aRto3S
#4qkLBxD9pA4/uQsgoEORput728UAvL0dhbQebM0lPB0eczCIkK8DgWGUoeCMNSBdHYyNbvaNlUhJwgiAq3YZ/t0d4PmXf+MIKxB2
#LsCqD4eFugGmuQyuH1HCh7hoBw77MhR+C8HIWYaR8wwjo7C8X9xGxCmGwqbK7+EcAKH9nI3hMUewfXOCGk0UFHb7t+Ic/1gQ53iC
#KMxLJmiKTyGRukHkgnJ+H8pBHHIfV2J8mqCq1wlVLkxyVmCS++waW+lo68iXb6Qa7xOY5D4nVJ21MUl3WEBVmKBqZwfDRxts7b6D
#8NFC8HG8gBvSFgKsG++9xJ4/AM/+U9PgMaHA8N72rva2TSThXe3m5xHiUgy8X8ACYV8W+0N0dBz7S9xidcT+CH2d3Z1GSwfUs5Pq
#6WkjPv3IHvAzIArh+d4dkBCZ7u5djoRt4MeE3btjf4xEEVLtwuK6GKwj4MA235wM7Ye0XbEvYqV7INVtmGqvq9K9rkq7IWECE97g
#SniDK+G+rnbigbp2dO3u2tPV3bXP/BNE/3+KTeuI/Tf4Ge4Acv1kNyyind0dT++/B5luWkhd7U+HzzmXCC21jkS4w1pq+wVUDEFr
#uvZ7lhrQ9gO4bM5agNB1QKHtdrBF20dzvI5eCNP3NPw+FKR9r4VrkRK9EuJeGnSuL9xbImz9RNC7vt4JYe9jHkCur3Pq+jo9d9/p
#gND+QaHq+mAylRxIDfShlAp2GqhS9GJgTu94qaZ9Fn4vAcN/x1zNwCtimAIXwqUOCLs4p73iKOta3XHu4gRgCe3N4L8VSP4dp4t4
#YCj7EXjwwDs7O/CE7/8EBpDxxdoNjeSlGqwKOovu532OBtNEeme3iDHAPiGdQV0r7Cvm7RBtfx7VMNLJvQlrv90e3xPW+jvw+/q2
#Hbt3axN7MDzQfjwS1m7qePmOsFZvx28/fafp+w36/oc2/L6ZStCohHe1xfdEtO90HGoLazVw79I+27a4I6Kd3PFqCP9u56G2iHY4
#cKitW9vcW9i5S3tL13d37Ad88nfBsPZeKOdm7cbAb+4Na38b+FDnfu01gb8LRrS5XUPdYe0aue/chSV/tftDnWHttr0f6oxoZ3Ye
#3B3W/non1vuivVj+/+3G78xO/J7ah+m/r2HKj1H4Gzsx5I93YPk/GcB6b2jD0v57G7b/ls6/h+9wAL+f2Plj+6AcavO7I/jdpO8X
#92B7vhXAXHso71fC2NOf3/vdHbu0V8M3rJUCGPJvu9D9b3diyTe374B2XtsV3/MN7au7cIQ3gh/q/DXtG7sQfkfDhZ1hbRRydWsX
#wf0q7c8jOMcI5RHt1jDWewnaf0cAlb/uCLxwH4Y/tOdTwdu01fDLIG+ExmeYxufTu17WFdbMMLbttyL4fQn0N6p9eeetMKf/PoDu
#c123RiLa11sx/SOUZhbas0v7pV3Y5r+nEXuse3dXRJu4AWtf2oPfJLm/thu/v0rj+Voaz7kgpv+Jnb8L6d+661Mwqn/Y+aHOtPaW
#HdjTd+/E2H07f7YjrP1FJ9byCzsWd3Rrn27FXu+N/Ni+bi20r7CzW+ui7x3dfwP7vAPwvVMLhffu3aV9pPW7dJrxPtIGDNB/e7Sv
#duzsHLF8wR07O/FQfJ8WCuzRdsEa3IRd3nHt5eD7UhB9UW1YC92+R/sW+e5AH8S9UEPfndop8gXIF9PuJd8byHdEO02+A+RLamfI
#927ypbSz5EM565/AijxPvpuD6DsGKxV9PSH0jWqT5LuXfGe1KajrN1s+EQ5oRsun4Puulk/D96FW+lL4P7T8V/j+EblvbcXvSYp9
#bcvvhvu02s4/gG9o5x+Fb9c+H/pT+L5p11fh++5udM90/CV8fzH0XUj/pgiW30W1TO17Gr5DO/H78K4AzN3PdLbC9xPhT4dhLXd+
#Ar7HuvD7jT34/blu/CbD+P0tCh9vw+9nQ0/D97/t/VR4v/blzva2Ie29we62/dprg+3w7dH2Q5n/hkr+n3sOWd9v7MNaOPwQ1fj9
#Xfh9IhB3pdkX7GnD8FPwzVKNn9t5WqQJaF8I4GjcHTwH7m9r00qaB61yPhnBcrC0gPalQBpSng7mKH0Bvv89MO0pOQ7h/0UzPWVy
#7CkKvyLyziBi1f5ze/eO1wdgvoTvth0IixnyvbL9A6FDsJ8vCN/HQj/eFtQM4bvceTEQ0h4Vvpd27tFC2suF76/2XQy0aK8Vvu/u
#2wNs+5uFzwy9PtCqvV34HgsFgAL8gvC9ZfeboKW/Inzv2f1T4Pug8OV3vz7Qpv1H4dvcHdDatN8Wvt+EuHbt94TvcxDXrn1R+D4I
#benQviJ8n4K2dGh/xb4bv7ML8I52/nbu+4+ELwYi2rTwHd6BvgeE70O70LcofE9RXI58/73jsx1vAzxSFL4/7ngCfHX2Bf5b6Im2
#Tu0xzqf9OIzgDg1Px9H3dvDt1E6S743aL+97d9su7QHh+2rnL4Pv1eR7XOsOv69tt/YXz2ffF/Z9uK1Le+gQ+/66+2Nte7U3CF/f
#vs+23aD90iEu5erOL7Yd0Pbdyb7Blm8FD2iP3ckp3waYFOLuYt//jnwJUiZinHJzz9fabtJ+PcZxGuDWm7W/F77Lu9B3KSF8EfR9
#Nsm+D0feGrpZ29Mratj3V203a7leLvP3Or/bdqv2OeFr3/l/227T5lOc8h8iwfaD2nuF79vB9nZde98g+07s3KMd0v520J6xO7UJ
#ukT2xhv/fldX+51a7SinnNRuAN/fCd9HtdvbY9r3he8/B3raD2t7h9gXB/ye0I4J38PBPeD7sSG7hh7tZ4fsGnq09zji3k++l2tv
#CR6HuE8L393aPe1J7f132yl7tY/ezXGlIPq+44j7RxFX1d4a6tXuOabGnT/Gcb+voe+Vx9W4NxznuMco3+cdcV8ScU9RvlcPo++p
#wOP7KO4E+/4mPAi+vzphx6W0l5yy41La607ZcX3aE/facX2kRS7jgHs7Y8chLxfQXtnxzL+hCH7fFLK/j+3E7zt2IVf4op0yJKj9
#1D50v60D3V+LuN2c5mt7NfEXAEyKId+gXD/fje5/Z7llLTe3Yfi/6URNl19DcZ/WuxO5U67rdzqb1ai6/xKZX+0PrBZCv9q83xDM
#0A7ty9pO+LcL/u2Gfx3ad3YBldNwLm+Cb0SLw3cPjDp+j9N3lL4T9H0BfR+mb4byFuB7A+zO8fs4lfMain0jxWL4zdrH4XuXVgh8
#Z1cP0Hycxw/T/H0zgOmvUq548Du7zmo/o72ydRK4EXZ37XqRdiu5n0/fBH0H6Tsh0r94169pLyD3w8Hl7k9oJyk2EzzY9ocAKl/Y
#9Y+wRt+/d0fgcvDDwa7AvParnc8LXA0+vu9Q4PHg/YDrXxP81X3xwBuphEuQ91jgZ7SZXafg++c7p+GLOPk9wakdDwee0u4HrBQI
#vGtfIRAInNtdCbw/qN9gwne05VDg29pdUObl4FeCm/D9dcDrHw5+JvJ6qPHRjp8MdEFP3w5fHWhWV+CWll+D71t2XgzkqO85atXH
#gy+KXAx8JviTHb8SKFIvLgfu3fnpwJ8Ev935pQDm2qP9SbDc9iWo64+692i3By60/AWU/7qObwUeDr41/H8DmeD03t3Bp4KVPXcE
#vxn8fOtmoEY9qmkjMALfDB5pGQ6+hEJeQiGv0J4AXvIV1MJXUBu+HfxPnS8IflvbteeB4PeCr+2+FAyEBruG4fu1Pfh9azd+D4eH
#Ic1oG35Du4eDr6NxfjONc0cIw98OtTwv8ILAURqH3+t+S/DnqafzWvCGb0H7I5HfDc5rv9D5eQh/V+hY4KbQL7b+afCm0CMdFwNv
#194aeApK2BX88+DtoZ8IfxO+l7u/FcSZ2hd6hfahPTeH3itm+Zvdg6FMML/vhaEPUI0f1ZY6jgV+XnvevtcHngpcantV6KlAet+P
#w/dA51tDn9Qutb0XvhjySe1A52+EHicI/HDwk12/C26cr+Ohlc7Pg/uJ1i+GvqfhjHw4+B+B7zge6tn7+dC3tfa934TvauivQ7eH
#3tgabHlNMLvz+S0fDu674UjL7aFkZ7Dl4eBcqK/ls9CvbwHkzEUehjnCWl5B34/S97P0/Rn6voe+E6GHd4+3vEer75tseT+FvF/7
#8I65ltfQLH9WO9X1rcDtod8OvxBKxln7HqX5k2C19UuBL8D4f6TlSzT+X6fR+zqN3te1yeCftXxdWwl+Db4/GvwGpEHI/6jW2tnS
#+gFK+QFK+Vfaq3Z1t/6tFgBIfirwP0J3gLsApX1Ue7CjpRVn8HjrU4Ev7BiFrwl7Tca/D4eK+5Yhtt5abL0dVtDl1kzoXcGrrYXQ
#d3b9CIR8d++r4dvZ/frWx0PvCr2l9T1aV+htrf9IdbUEsK5PalhXSwDr6gr+5d5Pt14O3RL63dau4N+2frX1BQHEJJ/UsN5Paube
#Y5Ae6/144IG2feGPB96897bwZwLDNzwfvu9t7YHvCszX5cCrdpnhb1P534aSw9pnAl+Amf0CjdhnAl/c97rw9wJf2IXf90MJHw/O
#tb0J8r4v8HoYve/s+pnwFwgmvxfAsdI1U2vpuJ2+h7TXai9pu0tb0DYice2a9ngkqXVqaaDBe7VV+N6ivQq+d2hvgO8R7XPwHdD+
#DL4ntL+C75j2PfjeT+Fz8L2Xyhyl75iW1W6KjGlr2qvaxuk7AeW/OfJiis3QN0tpshSbBYqbieTJXYCU74g8Rmkep+/LIeWr2n6U
#Yl8Dsb8WeYLC30Hfd9H3Fyj2PRD7G5GPUcjH6fuf6PsZCP9M5Cvkfoq+X6PvNyH8yYgWQHeAviH6dgSuad+N6OS+nb530DcO4Z2d
#95J7lL5j9H0xfbP0fYy+L6fvE/R9F30/Rt+v0PfrgTWto0MLUr3Bn9S+B9/XajsiOoXcS9+PBylNiNKE1mCsdHI/P/STsFv/WCgL
#saMt2OsMfR+n7zvo+5UWHLGnyB1oxe/t9H1x69u03R0Zcj8G7hMdj5P7HfT9OH2fom8g/JPawUgg/FrtXOT2MKUP04yQ+wlyf4y+
#Hw9j+z8OKS9GvkIhT4URrrQ2bIPWRmPYhrlG6Zuh72MU+zi5nyD3O8j9cfo+1YYlBNrxq7djT/X2t2mFjkw79ZS+T1D4ExD+/o53
#UMpAB4brHf8eZ6cDQ15M7ifo+xX6ntCygZcF/ijwtcDfBOLBc8Gl4OuDbwt+O/iy0BOhT4X+LNTWMtqSaSm2rLc83vLalr9sOd/6
#F60D4SByHKRsf3bHfe2a9snQFHxf1jkL33/Yh99XhDD8V3Y/AN/Hd6P7C/T9DMW+PIzf5A78/sYu/P45uf+x44XtXHYAuJ8Q/WsF
#dwt88dZhG7jD8A3Cvw4N92QANPCvE9wR+Abh305w74BvEP7t1vDm1W5w7wYuCCUiXeDugvUc0Lrhi7cGboDvDbBvCWr7gUcKgusW
#+N6oPQ/S3ATfHdobgGvaob0J1vxOoIJx+P4UuHdpPw3uXdpbwb1bezu4d2s/B25duwhr6WXAIT0BdOBvtdbA/kBv4N2B3wrcGhwI
#3hO8Enws+OrgJ4J3hqqhK6FfCN3d8sstn2z5Qktn662t72n9d60tj7lvVe7s1OTFBvr7xfDvh5kL1bQrVtJPkRxITfe+MEuInHkL
#O71hL+vyhv3mXp90nrwfDj/kk/cTpJHZQrOHfGkI5isEsxWCuUK4CcE8hWBMQzCWIRjDdhi7COx3SvDvJfDvtfDvrfDvPYBVPwj/
#Pgp49X9pP6K9M/Aa7YOBH9H+LPA2rSP4s/Dvbdrl4Le06dD/ovAi0PS3hL6vfTD0I9r34N9Iy/e0y/DvlS3pQLL15YHfgH9/3JoO
#dITTgavw73G+NXzyVDadPlMw8Qm7MTQ6N5BKp7yhgxx6PJ0e7EPX2UK5YK6SEcxTSzJwspLJoa9/yK8IDp0un8vXxiq5PCYE/3wh
#uzZRLucN4fdpTp9vc/oc9WGaY2n8cVTQ56oAk9Xx52y9nH1xnzZVL9ILk+CcGC/XS3lD+MYq5WzdMPLl2gvq+TrFz5ARAIhYLqyA
#fz5jrsHPqHm1nEX3BXo19nS9UMzlDYg4lynlx9ehAGF9TWQZvZIp1MgnK6xV0Hc+Y67O5WvgmiyY+DNRy5egHXPPp44VK9lM0YRS
#87WJcm2gH2agWDdXT+Vg7PsdIwG+8qmjafw18peFCzvdz53u18ik9ny9Ch3t184UyCZ3xrgKHqyzX8OnySDPXL6cm81coSoGHFWA
#D/pQwrIHsBaTXZh7QLsI7RsadKQfpCgl7KjahqMUe5ShC1IPOfIOaSv5Wvri/NljmEA7eaGSqxfzpyh0Ds2XTZyByaqjOS08YlnL
#z61mjGpydGYC0k9Tsgnz/OT8A1oawUgb38hntTl6pTA5VikW2SS5mTyXBxApQBT0muZUm81nwMXnNhxy0gW9p3IQ5ARgCIIUM/Qe
#5FmjUuIm5rgTZt4Qzjmy/Q0eU/Vgt7XVSm02j9bttItl+hnN5TR+0+Z+qCrPBYyzSTnKL933VQpl+Ek/wr/TAlZn0MQvFIOAd5Ee
#EscYfG66JgqbMG2/MPaPGapVGIuzFaOEr6pwyvlKLVOcRVvJJvVR5ofpLNidBOdJ2alTa+n06Ux2DQbxbCFfhBjRXG8EN9cbPoPW
#xC4aRW+MMBLoV1QOH9Muolm0uXy2Au31JpoTLxA1THChUCYMxx32qWU1U5sx8suFDW/caLVwf/6qJ/wctEmbNwql8TLO0IVMFR0w
#xTADJUAUBJ/1Wl56eRI0QLc8vLRu7kfffWalbPvQ4D9jIEr2YMYo1aszMBUQMDZerhVqVyfEI+di6WRqdROHibIqXgvEtfOVytoF
#dOAbBpTrTAbNZ5LzQt400Y25Z4VtWmcYGd2XQTZy1SYQkVfIICaXRCt6CtAlezNVcmOXR4tFanshb56+eiaP9ujyhpWSVxl5p/Ib
#tbMGusTSngWMUADvBK1c7F7+Qia7CgsDVnjN4TdVD+Olq9W8hvZCtQdX80a+AX4B9GGIwcyii7uVh9m9SktOGzPyUDJgnb50miqB
#4gBvarjYCkARCOVAcG60BiUvwaxrZ/JL9ZUVHBo7TNIoO2TUNPOlpeLV+UJNDUaImDEq1bxRu4qjomZwDYIdNU+mBGns0BCruyl5
#4zy9X+qt/Cx0Qaw/b+REeZnwBlKWYsNUvODrBqWzo2fzy3OApWpXZwEuTKWpSC7Gi/kSEFXsnxLFQ5rh1yWKmQ1ymd4aYXhy9WzN
#O7jCcKlfG0vVTPmq0jqGLAqvFZYKRVhadmz6MrILCANn8uwcL/MvrzokJgRjmAQWGrvX6TubL1XWET6NAqDTRxvCHeRZxwbjcq6Z
#SXrOfqm+TDXwkBJZEE7LVJHwn86YeZWVgdVNP7SioHWatOGsXSjgM2WV5VpyfKOWL9PTJ8nJysoKRjrXWVLMMcZACkA/5JyvcI+R
#JgqXwjhqxB6NmQ8WyoTiOTAtkK42h/YrlYSn81DxVP4KBxH7o4F7VUMrxdR8NiiNlY0aRuaq8BY0gUzHMsXiEiBjGHr8IjXV5ukD
#KzafX7OHimkdcGsC/04iy5YpajPQhdp8BfE+oCbNaQXq/gJ8qKWMmMSDJ2cBwjSksGRxmodZEDSaJsszNg+sgjY2Nke/xDhoZKCV
#aSyMNqUnB48+ERJuKySbqkNufHlaOw2UD39Ppk6l0+fr0HfoZyk/B4CsnTPy+bICBHYnhJ+oDM8m1SfdNqqWIRfYdi9QOhkCU6+s
#fAkj87CwkoickhK0OXo0q6aCVS+YMUbCNnNGiG1ipQxIFkYxV6jJpp3JL2fqxZo7ChC8ZcRWaTbQDzIS7dcyHjjg+NA9la8hKgR8
#nlXerKEog3/SsAepIZAjNpDghT23uX7y4YPuUHSmVJU1QtlJJI/aRJlptIyAGbiMu44HMoa1bEYBZtFwvAYAZzTYaWicVPpOnqql
#00vCM4GLFX5pbbBTDhnilWqliNSHCxC7FEBCK8D+5w1164JAacE0QjGFMQy5QoGTQVAztHSNfmRxuKlBcqdZ7LK6G6IlK5xpwDn4
#ywykxk+rEwhYiNFQZnWU3shUN1NYmOIjVKD4k1n+0k/eEGU9MGPKmThTyABAmbVC1myEgblqMylm3oQZu1gubNAiY2ZSI+ZfuBkx
#ezhSgaW94UQqnMwpbxRcYdRyB49KyVxBPpOX5qVHeBDmHoe6kM1zgQ2iXPhe8jBWPLMLkAM5RlO7WEPCCHwbVo+Lgmg5VWD7EGsR
#79RwoJHFSlrU1dT4OUfTZoVNdWEBei5BpetYNELf2WJmhdOeAU5s1YTVMZhO11YLVq5527IyQOOW84294gIR2WPyci1TKJsary6b
#TDalncnRJbNm8Dtrps9e1AXs01U79EwlW0f2R4ZdWK8K8MKHXLYE13VM5MJEyfP8KgEVI90YoboFNy+DtqiHBt/U5Jo37S2xgNnM
#hvQiKYWuV6wYgFtkVAUsmiaUYWr0Cu1oTQNIzhsE1pQmjSF2FvRWytlMTaXT2vTSIzCugE5weGF3Y6N1lVgrofb4aGcAP2JnpumF
#daDik3nYChvTkHylUNMk/wZ+RqvA3RhmzfbiDgo2R+iEtMI1Z7lwZMeKBWgETa5gbanns5VKTfrViefJZsmUnxjDllvBIOTN/7e9
#qwuN47rCZ2Z/ZnZ2NdqdjRq7tczYiRMZy9LKkRPjuhjHVhrRSHEs2bUJRl1Ja2mT9e56d2V7a0R2H0zJQyghFGJKoYG4NIWEBEqp
#H0LSgqGG+qHQ0CdTSslDH0rbh1JCm6bfOffO/knOD7ShtHul3bn33PN3zz33zNyZu3P5WNZHfXnIW28E14eSV/E/KIlOOq8o1nRu
#uvpoiQ0Y2L+iDdhRVrcpVF4mtyo7X2JXUJc+CKwinc1aWqvRDC55efbWeUomefGfvv+k7irUlmZLl3C5d5nO46M9Xk++VWvaxbls
#PZhv1nIS/ok3K1MeJdNyodDZYAxzHpPNSp1K5YWpC2tZvrDn/HQxF5TknKdm0/r6PZhvdYU5AC/XiWjvKqEtVKaDNI6/CdpHj9AY
#ZfRnAnCG7Ecpw7e0B5+mWcrRZVqjKp0lSrdLT+AytkjPEsUnhJI50IOzNEXH8ZmleZrGnw8pPh2lOfBt01LjnaNUAnkRoCUoVAVS
#jVZR4keAOarQRflmaKmjrpeRT5eQX8SxTFnhVkATfNpBK8jXwLtEy0JZQG5FVB6VUl4kMF0BlHWRVpU6lo/TFjBYQwU7Dxzmtip1
#Y0T3LgnOQo8cOvlVKfvAZ94VkcO03Tr4HZqdQ67S0caNLaLsRrP7dIVO0brmmhVeyyiNdNAxzkngjG6wal5wr8Ca67Sb27Mwf1fp
#jM2WLkJOTXPi4xpwfLGR0l1hdcupCy74bz0OTjnKSj1LyQKfudCUL3SLgCtL5MR6VbSRW7rSYaGs1mFVcw9sCP7pTrkL0j6KV8Xu
#WX79TawoR/RQCDK3Lum+U7AK2lKQnuW3knBNQLcgPc+0K4JHX6qB95LY/5y0oSB2Z5+jWEta/FmpKTDHgWWBstYoDWa1b1XF61nH
#Jd1qipV1i2ngGcDyYn+0I7WKEuO32mCxVmV9vAwMxl3o8FIaYAtXAOFeosG2FG4bpTrLPP4oItoMdo8GstaUJUN7yRhkDZhnTWkV
#z0Gm8jqWltejGTYaqID3mtSCx33jomsegYC5r+kRMN6p7XMzrTzblevZQqvap5WPXaEZ4bQu1p4XyLyMgL2SP6pLfBwVyKyUu9vk
#S6vL0nrVkjEy4sfbY23wWd3DaozwI2KmpnRb3wCDYu0cW7omfbMovMhaEa+hOFtCwySv4QOcb1GlgniiMCE3HUACHL8DS/EAZCiA
#tKUE/s1Q1Q8dHO7trmnxeahtATWuzmvPX+6wc9APc7LInIY3RqWDup/Wxe+zwmNFfPs8xmaZ/WG4LD3A47UIrRbEqgukvIl2+XRG
#dKvcJV7KSDvpS6TjyFrQ/bRfojTjqraquM0aF9B7HImYK/NRNmL5uY7ItZtozseJqyjUKkbWuuJbOzpWpY7jji/noiDascdmdQTL
#q7i3o9eWG6LGriXRrCC1QYxdlp7ItzhTRHB3sP+XpWZJ7KbOUeP0DGRzjtKnMRqOyHjbS18DdR3e/Tj6bx6nZXDIBnG+3NPfvRos
#ClZFYteSHoljMu4qYs+s+I7qm4I+w1WkxXcb761zZKyVizNNRcYi7WmfEVnqBVDmJOptYrPdd5NRlRhZlp4oSaTrtn9VonQdGJA+
#2O0vHLfUGUosKdH8MvO4r5frJhoRvfTTl//+Uv4n0z+ovPeb4eG/vUNh3zBsnG2MCDKpFBdd/opweTgSHfKeMjxbCm4U317jLXW4
#41jmkLdmeHWvHvFNY9sW2w8Zrus1h+whr7kVKDfdjGEaUthOqeZwxGFgUPuiFF8MirekeCsoXpPitaB4W4q3oxnDAC8uNHfJ9+4Y
#wovXeB16ALfxnunVza1JA6o19wOzdUDNdjLDIKlbAgS+T9yANEVVO8I+pWEPSsYBOGvGHQvNSlPagHnMCJmJRMIeSjW+Z6Qav2KD
#pCnph7wLCa853QaT15wBvhujELSbcYe3RSzUNPlFGo0mapwYmabXPIN/lmUmrKjne3XXcVKN51Fv275pgnXaYKvadsgxHNHH3Waj
#Xe528s7YjqEhaEoehrkxQPwdlETk82Y0BOJQ2FJt424ywDmGfmN1TTOeNAxtIFeMeSGRNNpGiyo0adNaQGXbCmyz8rYlhvKSMSvs
#JW3Ha7zC4IiQrPN34xXXCtu2GLhxHf/Sj9dt1QWN65auAdO8adtQ3Gu8Blu7rvuAlfBGpGtVW11mw5nA62zbBv94BwoLj8E909yp
#sEjzBTcUTfOPn4wQkYuPvdOKgc7uIOpmCrtBPDDi7B3NayY7wIDyrKRC/WLS1O5ldLvXdsNxWlgpMS6ktOyJzrClna7rDHk5Q2XR
#PamMeMdfLPbu5HaClwLE1rvBtZMgag4YLns6Z9KCMBljBRtvo2jD+o2fuXYIAzdkh8kwQzACQKGYFeEaVPGgTTVfYZ9X3QgXUv1I
#GPHbrDhcEG23Q/jq+Y9SiE0Gs0DdCMxaj0eGvPNGHA2Khyy4J4H1dUeJuK4Or/G6aIwMxzKCwcFtOcCqH3CskFga/ww8xMBD260Q
#mhcBetOIuHHbdds5OMWg6rIWiJvP6Gka7CFz2ln0PGyRDuET3mJZticj+A+Gq2wPtviHwmZSogCsqfgCJS3+D1QnY5rcK0npXgVL
#ZSwKu5xUMHxt2IIzJhD8YoIQHNmk4tAYD6+jd9wQxxTkXQG9JSETR8WmeUMGzts88F13wDdEI/Dymik7yNuBgIRWBtnUpBDesLVL
#uG1FuSbVvOlbjo0w0/hdqvF+oNkfkce/MkKb4gACFBAZgWkb73NAcpPICKtbh60ttjeSanywkZs3mmp8KP/vu4p53NZ5tyVJmH5g
#OSa+U4facg9JxYdRdrNkfMCPSOxNm+lQOmy/eXjhudR7zkH7l1fSH93ee+cp+/Ub9QO777zxDTNqm1HTjLpmNBGKevB07yQ+Zywd
#xO2ojlEc1YNBF42KA5tRB6gXzGg8Fg1OHgBscaNdAx4gZu0noz0+COBIOMojV49rS/uMpYdsOIqu469YLBp0FojuZ6IPHIP07zAp
#Ikvy+Lxr4hSQ4EyCQ7aceNEmIgcDz+RzlslhqnE1Khk37sOML+A06jW+E+SvIR/iV9cJimlz2ODg6vim8g4exVCWhz6yLAF8I4Zq
#EvQJGN3sYHqrI38beT6XeHXH10HUS4ZGyMbHxMfFJxEegfq2oXeq2M4/6Js3v/D1SrY8Wyq2njPNr1ZKl6qGrU1Bhw3aOjY7Nc83
#sI+Uy6P6CdlXLk5kxjLg4N7TeuSu17XxE+0Yk/iM4hoUaz+OpIRB1olcIZfltz5zYUI2HOQXuBkUmVDZMBs/IhrsMeiB9tPJnkd8
#e7rWjtFeg0Y+Brd7GRi/kOLRj8HebDXhnk3WTX1WPpOKz4bFVuQpi4f5IXBYbvOxfcLijobySHw/aMgv48O8qCMiD1Ut/Sghqh7p
#hdVeIwMKD8RMGzfkPb3CBz37C6kZUAKNmrlUE3BcwNBjQD1QDx6GSj8Fa7OYzG496mXOUX3/UWpaS8DoHoMGe5/z0BaD0ps9KEJc
#IbfncQ8NGuR03A1V6Zu/ffU2GTPHWXV+t8g9V/FZaa9bZdfhRa/8A8YzqDvTUccp2V2kE3PH5r775T2JuTvPTb3zo2/Vxt/48zTz
#GK+dL4+fWxyffWK8tPjMuPbZ8WKuxl7dsW9SeXmR5h4/sm//w6T53Dys+UDXGTr97R1Hfj/96l8fnTr9w6ttuT8P9rjZJP34amdp
#AUPvWKEwk81jSl7lp0y51mZNH+0Cj94mfcpkCOEW9YqFLji3P7MJnBPvHXP6+0Tvmu2ad03+GeYpTPAX8D1FJ5CbpicxyV3AcZYe
#U7vu0NvhP/1T8TG6eB7WJXb2DraSjgnWKZkgP6YnT9OYWPHNPU73CxVPL7Ny27XQMcFV6c2wL7+9mwO8om+VbeT0D4NxMq2/SUxl
#+Yenk+QAflSmg2ryW0eL9A01pE3ubNMhoQlkHJNp4pLILnfpthltBvG5TXtK335q00x03HfPiCwX+NOtGxBFubnR1nCjjDFMPgvy
#bg+cHED7BDBWhIpbWUb7WNMV4nv+ykWPiYwnNTyvZQQ6Fj+VLGXH4zJtXwYO3z78JDtmeM7QQ9NrkYkOWxwQ2x2RW1U5cF7UN3Hu
#TqPo/m9SQ70r5defy2ab/fTfljbZ/08BZL/3f4+MT9r/85HJDfv/PbSvv//n55KuOL6/k/eu3nnQ39nygZ2jDNYbwXKNbBOqoFlZ
#lCToU8enZuenp/1x/+jcPiFWKMvt1WiMpxcLVn3eSrsue8TnKn6t5NdWcy1K/1Ju0Ze9tQ/65Ur+YraW83es5Gq8OoI33s4XR/1C
#/mLOV4umqqOSAbOqrD/xs8Vl/5ysv8wt+/KoPlcd84NVuICVIVOLXqyL6EJ2rQi0ypjSekkveILKT8vG3VfaltGK7Bzd0Dhc+/vZ
#lsalYm4vryFSGvuiPO9nz+JaDfRHcAF8qQjkQp3NUC+t8faIS7iu3T3GItZ4WTkz39EhN1vI42pTtDvrr0PBs1prbqGA2/0ng3fn
#WWf9E3d2HRs/NXVibvrJ2f+gj332/X8zjzw80R//n0eaGNs3NtHf/7ef+qmf+qmf+qmf+qmf+qmf+qmf+qmf+qmf+qmf+qmf+qmf
#+ul/Jv0LCultHgCgBQA=
#__NEXUS_PAYLOAD_END__