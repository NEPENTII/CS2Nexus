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
readonly PANEL_VERSION="1.2.0"
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
#9/fb93ue7/l/7ELuPX7mzJkzM2dmrtzT6b/+xwv8CfTyQr9e9r/o2dvfJ8DHz9vXzw+mB8LihP9/f2hOTlbaQpoJwslsNFpKKvet
#/P9L/8g9SZPpv4wDaP39/b9//b29/AJ9/t/6/5/4g9cfwMCiVf630OA/X3/vwADv/7f+/yf+iNZfTWZolUaD3GRI/Tf7gAsc4OdX
#zPqDtQ6wXX8/b58AJ8Lr3xxEcX/+f77+o7vGdaji3MAZPFaJ7tiuO/jdA//+UB782/2qroKTU3Wn6HZtErLmPplXIS/+z7qHBkWf
#qyI93LLcmEGTFsVEta8/ZkVr7bHr8ZPCjv3YZob7ZI/cZzsvb6hd9NO0sGku0/sclS87Pf1rWLUx43bcbR57vePfb1/JYl8ZOs3O
#PLnzwfzcEaVe3tF7ZU33eVQ9xW9f8vJz79se2rXxUPsPVZOqmubWaTruYtHOXSf//sd6OrPpx1lh6lOf50x7/drrpx+r1T/Tps6O
#0q///vDoSbW1VZes/7FmjtEUZNwzzaVx8LWMAG9DTLRfe5+kwqoV7gSVM72V608vkn/0HHqpS5Oh+9fXaRrnU/HaJNUfwc3CWzlX
#SBlU7vnzd6erjOj2pG6FYfvX12yf0tZnyq4Okfu0l2qEtBzcyxCYec3rzcKKvumvb5qeVPad3P3S1uZHRh8csuec27oyb7oOPl4+
#81mpmLZXfPe+dRp5J2WmazOvvfPmT6vXpaah8tnWs2sNzqZb/mT9UFtHf2wc1HAWOefe9iPtlT9MuV1tT/urKU1zMhdkxOTPWN/n
#Rt2GE0qvG31x5ImbJyyGxt4Hp/0RkVJmyxqnnMDM32THjxurTYhVPT+9KP3Wa+nkE/Hv3vd+7eveqtHYS2WbBm3Zu6XCuak1F2Qo
#qsWvyZ632XnSkRPXRsbM99y7ftbhnIHvLp16tfnBhOt5Y2avNgxRhhxvdnnG3HdLA3Lruf3j3zMrLbRSYXbW170FEfq8aUV3PG5J
#On3IdhnUPtOkG6k6d/NW/kxVj0dpS1u2Vg8bGd69QlJj09l218eVP5P2/sYd50kZlnKz1rRfV6H+0nEzFjuVv3+/curuoIgg7cEk
#T4M1p/BIrVm3X/81c/PtjXPDvHo30HYrdWlEpk9i4tEh+89U17Vc2eLwr+WOt3SirRv2e+SHmIIaDFf9rLp0tV56Oa+sCo9SPpVr
#OGFEDdWlmx4D9o6SDR45p3HnIpe6N6an+1U54jX13oEni5avfNyidmvj80d7Q8NL3TTNdXrZ32dWVV/riWmlVeot596CpFF1febd
#O/HgRnenLXTjg1VrNXvftVXDta19Tlx9//lG3pcq5Z4fPTFiYKWqhyp6l34qDXv754P+8U5g3U/pzqXQw6Ujl6hn6nK96zf55xH9
#VTZ4e6Y2YGGpoIaS9pPSh2UWnV+Q3HJwm5F9b5r6OQ1r7N+9ye4Bpf8sO/JOgx3T/qnrfLPbpNKj9twqLNvscbNXnrVaG0+/Klpw
#p/tf166tcr5RMMgS/KtTz0mByeFly89o+0vM0YulF75t/azges0OwTpfd6nTgc6pqV/OdA/98VpoqeyXC+Ou5fywslvNcs618t5/
#2lfu1ZmtmV2key9VrHlmRfq5nyMWRAyqOvnW43WGpw3aJW0rPaH+uIOdntyoXH7Y3tXEyjJBxsluveTnV/Zq8mfbyBdnOhTETtBe
#X9z85NzwgqiYGneX/rlV37/mwMUpeyOll7ZW//D6qWTH8sOjTMN9qcKcf1oG/dbWf83MJ4PW0PTbASvPPXwwpGnryOTVcUktXrtI
#uy+dufRiv89vW3b62V2u1c0rvWtm7+Zjj6QlbT2Y8jQ5fdK+yRFd9kUs3710/fK4eSluZeJHWNNMn2fvf3xiQPkl3vd+GnZm1JO8
#LxWc68rHXL/xz4FePVbt6Wu+d7LctsktP5WV+eT/08Trh936a2MWtK96aNvG1JuPJj15XFQ+KKTfzMiC8D+uvh/7/PGbRgEVI15c
#TH7gEvizZ9JQj9M3CvWH5Mdn+1Z7X6lwy4M5qmTjeZdq/ar//n7jA489z7a/WTiga3XdvRuDvkb1/vnkpDnyRlcq/fKzx+kZE9/4
#h7x9cuh4ET352bBqN8eArqztkxoXVr8rnxusnGF6NWzVlZ57P1/fuX2mb1qLAQU9O8ya0tz06Z334RPrlYOcP1bNqfbqwcka16d6
#lB15Yc/f+RW8sy9Xvpv9Nb/wx2Cfr9eu5hvWV3T5aW7D+39HTuyff3pZYmbhtj5NnjeoSf80J8DwR879Pq3WDWrSQzrC41JazU8t
#/FZXmOHmWagdtqpXh/vH+6z50ig6Onpm0ED3FuN+Gnv3rioopH29JTNLZ0VQTeZL5tbzyVQfnz22dLlKff/5fXvmsx21Pnz++Ma1
#+YFVG6a2SJ9WeseY/r912Pay9kyf89V7tkqr9iRuXvDouKdXbt8uqGRSX2r2Jib1+fP0y2PW+LllPDpbe+eH1wUjR76+UE6V2GV2
#UONjM+RbPsZIR4Jmtm8PaRBgGCpP2j/Jt1fckd9yP7yWtR9fb8Qs31+u7LisLbW8x+C5xxdE5N9vmPfpiGRKctufLkfXPKh8v6F5
#Vd9Sd3sOTuhYo4Gf7njMHq/VV7d0qNqk/aE3+kvv9/oHNY0rOrqCWn1hX4teq54nbzOXC9ue2TZlZZd1qheRyzcNqlmz5vqsM6Wn
#ucX/uHPf75WOygu6dJ6+7+S1j6eXamlQeXPp0+0zj76e9UPFtS7aT9MHfSHn7Ervvdm8LelJrizh2OPxff6M/diwr3HUwQvHXm46
#suzUqv6fR/zV4EKZUqXOtry5Jmmnc1JI5rSnG6eUWd6nVF7+OfLAo81Thi9Qv0ueuTJ+fb/6a3rvSrjwU877gVP+2jz2bU2Xundf
#LAqLK9iwzOv9z6OnhA+7bH1MPhzz577Up+5BB5wnNe/cc02/jXFTfh65uNmVrZ/rSGo9v7bcZ+eAOmUfDNq58fzsV+v/erNavysv
#t+vLc128rR/cyWeq0btPLujwOXhz2YvrLpzZUXrS2KnqZQ1bmXs37Pzm854vn6s38Zw4i5zQ88DZJWt2151S9EfuzZzQOnNzKi97
#8eKfA6dvNb0+xsf/wPifAk8Plu1d1rnuIspvrRN1tLzi1pRlHX+W7yxKz1Qoyl6xPpjw9Gbv+6t/W53yyXNq0fs2LTbeaRyWM7xF
#lce3Ji6pqr0trzS7x+Cbk7qS+zv/HUbPDaPLV3l8sca0wU0bRUREkNRmVc/w3DeVn17edPC3xIC2YzXmmg1rNRw6i77fp9aXp1cG
#ttWY/OWfAkyv7seWrdBjr7zS6l+WL5fc9+w3bkDAwR6y8fd7Dr7dvBOR97nFWMn2znU82i3oHzb3Q634qtI1iteFFXXJp/94Ujh8
#eNnzv9YYF/F13cqk3xSaTqVKl36ZcmzL06wH8zLbHZq0p9rHdK9fYtdfajRSWW7e9oz9bz9XmHlifv7zm6WG7voypZH7lzJrF9Yv
#d3imd9OBn/Mln+gxhzaedj8/ZFtQoPHyDxM+L8q/uHTluXIbO4xL6/Xb4qO9km9+2Zl7uvTsrk7GJk3WjO03cXHUgVeGJuF5gw/+
#87hi+suGh9osqjF2hnuH8r6rn4+ueahbiF/v2n+rO68YWDMm4K+hUZ2PO0ec+DT+0cV7+zzL1Gp4cea28Ie+dZf0Xn976NTISgfa
#J/zmVFMS2+a9c+2o36aeuLHln8CggTHbpib1Ghbw+9MrWwIep6z4dK9XPf8c9/MT5lw/ke+V0Gl/+9jqFzb+XOT9+ePAkf6rew1p
#6jnN/VWzv73DV78u+GvmYl3zhR0T/Xst7Pq0MZF2QXdp0F+jTKGeB8c9jPdW3XQyTbvzwPvO6U3Zlc48Xr9+/Q/uST9mPrs6pEG3
#tRX9rAdjNu7bPX1eqPlWr/nPct7+cX/87f5bXz88V0m9pm+3ZaX99BciOz6vc+fSgkHOGREdsjVNWn8sRb9onZzwpfvh9vFNV/kO
#Mb/7qHx7vczijRGNtkzzTHR++3fLusHHs+e89UlVt3jcjTwYWG5WZO0yx4jgD3XOD3/Uc7DWVz3HP3/Fj751B/7TJmDg7mc5Y/tL
#Dsz0szY4P2JVrcHm7IcLo8atnRNYsfbEVo+G70i/MuhGi5x5V4sGHPPoOb5iu19OXS8z8ta9e9TL4FnhVMTnmfPehZftsHOSrN30
#+1LLgVpdbt9+3qeg9Z8Js7qecPbSHJ64eF8Xy7PLsyrtLr9O5Tw5u3Mb64A2tZ2ff/n4ta1pVJZP7rvfN8+OLTRFue67SI6dNfiP
#2ZsHdD4aNqNMD2nrresaL05v6rck78byukGXF3d4+2vhoK+7jqTVuhH1tl8V6a9Ota7H3Av4o56/uWxgvt8PT4vaT2wgy5l3stwG
#Kn6Xf8HtOTcnR0xsM3bGL9U2H07ttyGrW5Hb5m53V3qc8Hnzd1FB2wrV9p3pun/X7/806P1Pg0eV6Zd30w9XXLam8ZdXhSsWxo9+
#X+rz7pFT6i0k6vtSPnMGdDiwepo0vveaLO/XT65VuHB2TVSlabL367v2vjC57N3sG4/e1s1/POOJc+t79ZbHzh++t+3IOTuuF2p9
#xzUJbH+GbhQVS7Q833LGlc5NjgIyv7C5dPBvFzOPntQMGHb58JiKhVu3Bl7O/Kts824xpXxUh4kBH6rvjqknOU70XZL0serhOT8H
#ro0r6Ll/ZXyL0f2NRaumFzU0dgAHzukWo9RO8afHre96f9f2N0N/PzVuTlDFuV9nhuTOWNF02JjZ3RL7LusaU2pF9Jx6fsqgyxMy
#mtU62W13m6am+W3fmj8kvGjZaK9atfeMdLHTrI2qGuPfL4r1/PP1meAyFarVOB56kq5zfI7bo9PSn3pXfbbro3xa6xrlFv54X1Eh
#OWH08fqfvsy6nlvtc/nKpR+0ssjXGZ81nnqxY52lbyzrAsdIW5vWvZtS91a7M/NPzN5a/aWi1anRlevu3vpnbZ9hql5Ol1/8XLGy
#X/b4HeFzAnSDN7b2vZK1y2XgkV/GP446QTwasHJ4/WbbSw+/sKb5gC9P3n3O/OOALFlyY36tD8/bbvqwpUrQqRMLr4VkztzR/vrG
#AW1e1r00PanU8afvmja9sLf+wyu/7TY9OrEot6FLjkdQs7LmpqtLL03tP9m5dkTNnbsORLedf+RimOVdR1PKFkPasqPJzj6ukg0t
#94w83rC68tzBKpFbJm3sPqfRm65N5L0enFkyMjJlfr1yLx+MnHt4lVOtCvKDj3q43XpyuqL3ZonV2nNtX/nAbvdzFoP6Qz5/TH9/
#dtnW+RG5b8YVVXZNdUneVe30erpuYfBPrk3T/75atHX+7udvbwTl3P3hbrsvsabNLd+9X17Ds/aQqrs+vP5h2GpAXbYunTDj5MnM
#sP3rHhd0+OvsgbHvtH94DS/bo+Dq4V2NI7JMTWoeHF97V78aA+QvXl16obl8+PfhdVLv/HVmSWR07rL02XEv3jRrfuBDs20beya0
#/qX7kC2qucsUnW/4Xnc74devVExKZ+VI74iJ+65tP+tGTKzX6rKufj360ssvm06viaxYWPrS6MJDE73/GvllyqGPD17XfVOmIXXL
#OaX0nBad3yzenNazksfwpWd3KSXzw37x6lfqScxEQ1Kz5ebuf5YFCe4g4Tg44dY+6hYzus3mx9JnVdJ7FJYOGlzxzsGbH/55POXQ
#1yBdWXCID2ka0a9UQ6d7e9587Z9zrbFL7pMK1/+OBp0HjUreqvNOdPsauyIwcm9kwZ7JdY9I9j7LejQpYmpI5Zzsz0dOTRkXNCiw
#RpcpmzInnRvZ6O2zVqbemz4dW71UPbHHxw+dg8qEl2/kvOtB1S7Ddryc8kdV76+7fh418tTSI2OjyhF7FySFuR29vymvZqMjq+j1
#P3yMTVw72XC10OVJhaUX9nv23FF29mbN6KgGa0dPO3q35axuGwdvyJ09r9f8hU9/qTe25vKomiusLzJr1R24uP+i1ytm93r/lvS4
#W+P3rBdD7774PLDeiodP1t/MCx9TKeJFduMmm1oaWm07uLj0tFPUlfSdTVdM6pzrPGnatGZzq3QsGFO+cmOfWn2XKQz/HD6W+uN1
#MLbTq6XD/0hakpgxJn15vGLl+bTTXTcWKQdMqRtY0Xhwccd5u+Y5bTaF9g17dqDvii9Jp7OdnKr1gbqAql/uHFo/5dC5iuu3VQ7e
#bO4e9dLs+mHWAe86EbdejGxyc1/Sva8rkrp1Wfd6XEbnX67uzqzWdGS1qaHzNxy6bP3rh7Xrn59XPtneoNqyVpkP6h9skpOSPjfK
#8/S1d7US+prLUJ/DFtU6Ittza86MzX2eHp/j+1PsnM3VB5SLXtRrwa5Rvbf2fN5CO7r848XdgkcuX3z/9JDHZ+9GvWw1+HzyYe8u
#9a5UN36xzln6Li844l36u455H2Mraca3Ddzk4vmpWW913PygCVE9Lbsqrmo8rlNyQvlD3qZyXQfXaDuy9591x5pHHegbnX62fC+n
#clmv/6oxonJjafaO3bsjfs/o1SE5KXWY2+DINX3XX131ZL382u9NM1s7Bb0pcBs89HTF9ecD1k0LC8j41M70pBKovejJ+vrnlkc3
#7uL/um3a+bKHBoJOZnovaX8747XHkTuDGgY03LVr17o6/esehttiUozEeEGxZHC3N71vPFuaOpE6MaMRGZa7r29h6Zkj3AZXvHpV
#96732a5ZY5zLjPWf5Bt1a18U6dF3nNuUMkURtQcMPr2zQxedYvmi1K+7RpFNB/6o9u+1PLV3YGju/eDlT4s+f/K6vXxB+v3fKg11
#nxSztPOCxuamuelX31eqs0S3zew56JcvfZrcPTWxvDVt//T3gS2dp7aYUPf2oH5DZPGpO6YNG1ffd1HWix8jd6dsu9f6Qu2bSyaO
#2dHi08quV5a2/HPV3j9nfTrWDoqXqcsHdLV2ayXtupC4265nuazAJVk/Hf9QpcHeP6M7dqwe45K6fODnEYsvHj8yqumkHqXiFgQ3
#z1nbYE7tvHMvbnf9+PZp1NKa/pUG1dzwanX5cqP7A/Lljlp593zI6Rrtx7XscfdZ9cXty7/eKM+N6ZywtoX8U8jAGyMudZhISDbk
#DnHddyB166SuA49G//HHVXUFVcTe+hWrrHXJOTFXF+RcVDslXzVc86nzsqPTs8cfr3t8vn/NB6qACg2rXEt8VE7nvGrFzvT9OYfH
#P3GuXvdt7/OVF8/MpN8scps8ZYqramKrmi66N5k07Zutf/Dm6VDd4fGuh4ZNrlFj8cUBz1N++7nrm0tnm4+96T78QvXAQa5NL7Sp
#WKubU99Hh++ljjm1e8W4udvMQ17NbVKhiurksJGng7+0ohfffjA9pn/TV6nH7p/oWjqq1s1t9Tftv+v/aOn1bWmZ4DAsUgJeYOiF
#h2dWb9WEnt1yY2CPPz651Bo7acy4WjdeBOrO1yvKyjvd+XDl4PRP9TZ1urCmqOup47d6qQp97ldbNLO0rl8T2ex6cXNuVZ0XMuxV
#E7KnauLK8QYybPj0a7XOnNm6TnunvLRA4dw6/Xn88lGBo9Iu7Fh2ulXBq7lAQiVPPpl1ukHCw9+jN95ffBHwDc22rVzYtKtfx7y/
#n/RZ/FNoS+c/tyRVMH1Rvu4ScevNU41mdNy87WNmWFwqpSzat7O6pXy1JlHxBb9nVGt7Y2AEOBJvOTUfU2tG/rCETZr0vB7LxvT4
#rQ8Qu6qffaI5Wr6867p+5XofMyZuvX33yJ1JUyvX97l5aeXGxY3MI6rWV/XoENthYWHpd+/e3Z5Yc/nw39/9Ui9sQLODExuVmfDm
#r6KPIW+o4GtTe375MSq8VgzZvFtol7+PTA06Pr9V0utgj0VXmy4NA3zokraH4sAs1n++EV9QsKBrXjlCs3Jpj9buVTXP5l9bkby8
#TtBlF8V+9aKKhTLNm69Le9cgX8Y36KHqdI48taa+b7vffv6ta40TiQPLTAjQXPtl7YrnNTfdXt3mXcUea5zKPi33pmFQWSD0TL24
#4I8DtzY6Dykc+LRB0KPmBFEt40lRBU/Pc5+3/Zq0s+XVQ+8kXRaWT4h3G6Yebph3IGTxu3cfFEctT9/vTRpff+ODUc4RZ1bmJ/75
#Q8SiVQpv1WPPxN97v85Z2X1Zwb3pS+Iub342ePGBMYAhXvB1ctOzlUofGzIgZmHC2eVdJs7LrTZqduTdVisSFjVcvPjXwUsaH35d
#BIr/teji2sTAbr/GyHqc+DL80dGCAwcPzvYv0GQnFarq78jP29OtwsOzy/YvXnbseMCLv86uH/Zo+IKu1M5Qn4Ke7sktc+Y5a0/M
#2T3q54/xpWrdbV+z+65qL8dO6LNDM6THsib32llbdG2pcn4aklUWMmiNNuYVdV/9+zr6yalNszZ2W/LLu/rj+8YuSLj62vD3sEWR
#UuWTZ7u/Rj4NtkYdqiXv3q5e5rvTbUx3R07p13ezQZlxPPDEnFsvl3Xu6raqh9PtBcd+vvXwYUH3ZcdGTVhkzkkIu7WvYPfeydUG
#nPdWnNdsVEpHpL3f0Lyr7yr/If2pC1ffr2jc0DVn3qqWF9fWHhMxoXG5Qy+myePruF1cU/NywOgaNXZVbXR5YKXNSyqWI/YF6tQP
#nG4fepxg/bXPkvJBR6fvWTTt0+t49/6/l67fbnFmxZbPwEFSRVPqRGG3vn7aUcd+PqA/knk9u+7qC1G3H6/acXTTkoWnMv68/MPG
#fV9PRfx8ZkOfmppyJ6ROUdUD1vSqUK1xaPVGdx4+HJ1dqc6i7EqNg1KNl7ekTdz2qq7zgvX1pt2K6rZ9YhO3+Ft76yTsrDiw5pgG
#YVkpEY/Or/WcrVp77uHzexeT9x8KbJTx7GqpuMv137/SWJ6d6fxOd2DUxImARHWu69m6s0Zd7XnLNn8OKxi//mRk8q9AElqUNOfC
#4qjCoPuLpl6rv/H+wk7+r+61XDlO+arF+HWf3+pPN5id4OQ6KrtA7dt83R97y1Q4vbiPsuiYIW1e5o0To8o9Gf42fsvDze0eG/um
#bBy6LPbsULWyYoC+98RJC1sO7aOa4EMdU3z8dWfkV9kEv5YJa0Y93f62d62BH548bKzp8a7iiV+dVt49MafasZ6/zkjoMk3RfUTl
#BqOCCgK19UMtmn5BYZ1UubsWhdb5XLlz3CHXgDZFiW0a5Yyo2mTIiPHuuenS9cu6ff49cmuux5LscsSKwRde9kjrWmiqMVYpCyhY
#HPv2yfUqy0ateTBy4uf+b39puPN9Lf9e0c/qGY0t87vVV0pi2r15MrDOofnh+Z2eHx7d4825H+NqxEUHum7K8X9yffOx271/3+vW
#87eahi0/hh1x3vngy4znNZt/3vG8TYui7Rdc247I9Eo/W8u9z67uU56fa/9zeFpq9YH7tLdHL/AJ7HenvHW9buWmS1Pbj59ze8+t
#JZob66dqbrXo8Hz3uNuR8wOXhNwd+uX+yaTt5NdbTVdcXLho6cXTqVfWpLe9tTGjjp+1akrFJWcg09g+IaHW0elu1br4bltZtvnt
#QW+ym/sZLteSHTkSRN/3mzJlys2OY9Qv2m3O29XiN/1HSeMHfwdviWvRvNZmcmRfX/WpqOmr2sTUcJfU6TYz+tl8cqbXyffO01pR
#7Y88mu72vM/71i4topz7bFAduLlof/rzw00iT67fdrzF2sihXVptH/klaESpYSMI+r77lP4d1FTBHp/eGwc0n1tjeezKxRuuWHyK
#lqdWO9J/wZqiDb6ehzv+8sOgxdTqC+oljTaXlr3aqr9S8WjYX4fIoRs630rXuecUWFPnXLtcWLNmmdQDsh2tZxye3LTCLyfneiRM
#Xzfi49tnFTc/brp/f8G08OAXMW5W53cKRe1zG40X13r3/tjrcqX23VZpCk6F180xdytjDj6/oXzfVtszHg3+KdCwp+jMtm0fr559
#OKmKvPVq45WFN6qVmfXUmB/5eV6I96VCssyFDsPv7PmSv2/g/joNlznVqtP917xyQO6SDR+jOqrKNxYUFgZVbhJcFpxTQ9z2GMhN
#J2/+TTcMrjVs7KRrp6pd25ezOKpBJ4/u47/ExtQHwvvt020en/V+utZp2bFpba59qDJ81vU6i7pQe3dsqxeYUVnhd2EQEVsvPfLB
#/Vsboyr07lX5RsXDM8JCgjMfzrgfmXg33TWk1aOjtaPvPF3m9Ozrs0FPyuZVMT84OX6TV9pBS8z812PTKn6pNM6r/V9Fu482imjZ
#8fXaxHqnv+ZOk36ocf/4hp13Fa1bO7Wf2KjatvqBZPfZwxeU3d37VjVvTetBP9caWGrJixnzZ03odXPf0paRL1y3uJXu8duMn3zy
#dUPK7v6rQ0G/xOfJC889ND6M72cplzX1yplTtRedrpBd7u0C/4K5vyZvr7ptm7ZgpPrU30k/PL4c9e5Kx+fP/rhavgJRFPhX95ml
#C4e8Kh38z9JdO15Pb54WsHd67yU99dPcZY0b7EjZ9an/1HKvHox507Nptdq1KwD+ub3p1pQKY18FNPuo+/r4zoP7hh2/bpzW/97t
#u0enV/JPu1jj0a28153OP3xx51BXt6W/d50d5fzmctlzRwx3fzkh7Vf417EHcfOC917dVOOH1KGDnrZ8tiSlakB0vak173wuuyiw
#MLeJqvxk6/J28pjree8njV9btdfiL3vHP77QqE7RlSqPFpxrUmrbq5t1fG+d7zck1lpv/MgpP9459sOi0bL2ysL5boNV8qQd0ryV
#pS4Pkq6vcCa42avXSaPKdYruVLHCyDuRS49+GptSOPyVLvZdpYYTOrfeEOfzNcdPmlwu6Nd9nfsMWukU3f5Xp4YXb/bo89VYruO4
#iI7ra9w0za3X5uCsNcu/fOobGeMzZRDxVhrUUDJcNedI1tdeC3LDmrq73PILaZJYueohGblh3iTT/T9Tr3caHRMXU/+43z0ZKDtU
#NfvIm4WBCwIn1/z02jmk8fxSVQ+NzpKf67Lket51VffQENfGpN9tF1By8JGXTVuc2x+bVHO1c/qcebW3lh55p/LSerKvf6o6rtH0
#mXb37rvNT65UNwVdVh+u1CdgdNHvraMrdinvu/thA3jbNSv8VccRJ8av713PrZXLLtnH2Ap7bmkqtth4ZHQX956hk7rX/1t2pfXw
#ddMHp/a+NOSPWi9yIkcfiUteEtNiXN2O6qIyYwv6L5vRfsexuNNDNYFV4mYX1nAb2OXXcLOO7N+r9fN3zZZ2jfeN/ufKsovlYzsG
#HZgxbe6TiNP9JX61092DS/389+6kUh8+XSs7d9ytE5/Olg55cjnOxzl06ty1Kn1w3lDv5umj457NiF1+bnrZQwMOHy7KelHx07mf
#TJ7h9S9eWjPoyQVfy+UfhxW2M5QumpAeY1bkVXqzZ5W0/Jyat/75O/ypxevLvlp73w8YTfuVmfNPzZm1ApUnG8x5tHX52h+H792+
#Zk7c1v7Lhz2NkrVq+BP5+N4J1ZL1dX68U21v+7M9a0ibP2zgO/r+w3/KV3ujDlevLvWb1x/pQX6PN87KdfbNbuBb/9NP2j0TNg/e
#8bJw2+OiI+vXy+LLLtfv2Nutaot35xeS0ebF6UQ5/b6ql3bXmzGyAxlYOP50m7qlqx6K86qkhJe7g+ZvVEQ07FXl5LXtm9qMDH7S
#TfrR6Dx4//oGTWcFTo5uvyZu7Dxj1VlHXXLun/vptfV18HCfWPn+2GYTZFJqcsW7/TN67wpvLmu+r8GgXWul3apN2xYbVqZy+aTB
#3UY6/VIp+1KTxnuuj3rum/jY/PLEJtr17pzHptjUdrXm/LDkUv4EhTp/2knNuE6dFvt8PiUloy6c2/O1jJPT16/tYk6+c3JyKg+F
#7DJOcdslhT9du9oJ3tNHR8W1+zUyZei/ff8vsv8Aj/IB9L/dRcn2Hz7gf+8AG/sPX29o//f/7D/++3+kUhkRFk7kOkusNEXQFrNW
#aZGEOCuNBtpCNCPCCBpmq4xKq54yWOTpVsqcHU/pKKXFaJbSMnei2TcKtdHpQDm2RT2pNYDyzaSSpvBRAjJ0lIVIAGm5+e6EjjSk
#gkcJZZDgF5rJ0FPgwWDV6cAjaWJTLVo9ZYYviUnuBJ1GZYJHL3ciQ4ueYHG2XzOlsiopFUjVkxalJpZSaUmpRGoyU2rQggeT7aE3
#WrRGQzBTXCaRyVFxig5xdvb0JDz+138IDaUzgR6ZYVG0koVePAC9IVVKExERhAR0bKZMOlJJST0TW4SGu0qSPFPdCSUsKM0lJC0k
#weAfUm8KAXCShKI3nQW9hKOXVPziil7SrUb06ipxha9NfVuFSIj8RGWSjFsXCxiGNA2ADmMDARcFAjYhMS0JjigthNCqCSnIVhvN
#hBRXSiTdCUUSYVQTXRQDwGLLweKbtRQNislQbVpOm3Rai1SSKyHcCBL8leSDqQ0wag1ShSwEgNliNRsIOoTIZwdiMGbGw7GgcbQj
#LZQcpIA3TwKQBC/QAlxmtjCZagRlLTTGYILAqbDnWNKiAWuXJQXogJ7VOiNAWNg6aMwD1IFzJ9CkaCKUCPCSsaMBw7XATiWiAr4B
#XjZF9FqIpLkEQBdBDzQYKWwsX1Q7KMDPtrrGaDUXUx/3hVvAU1KxU+IL4SZhEaZVUCYsjPAmInD72RRtocwqMlsiI4JxEnxhelSh
#5jmoq6xmuFyUUgxJvU23IB/Njp2aHkzNWzgtq1xH0bREVEAMWqtcz45Bz0xRmKnBuRoRTPS4V7D1g9ltoieawyS5iVTFA/ptkfoA
#bPeSyMTTUusRXltod8KIEMoACEO0waKTQ8xKANSjvdEMdrgUkhpYRq7G77AcLAKqEi0R5vFbRWXhcA60jxrPJQBowdYyAPoHCCiY
#gt5osIBJSGiN0WwB73C1wauPh0qbqoUJAHusFkqQhEbO9EBm/w+6yKZIs6CAoD2NlWKpTKJcLmcpjSxJjumcVAo2shIBSEqC+fp6
#g32mlCs1pLmtUUW1sUjB9Inw8HBIXANlAPQAQ0Oc1VaDEpJLgjRo9VIA4Fy05iypzcsjXDK1BpUxUw4LUCwWhBAWczYoK8wDtQEN
#IJSQ2BLSZNBUPpHPd2AxkrRFqqdTZQLkpJhzBGUClCMouYXKsrQFYAF0CFJ6OpXFw+LHlAuq0ZZsHSU3mkil1gIh7x3CJVrMpIGG
#SAFPJfSig2jh4e/V3N1LJgkhlDoAdohJRitYKDgUuQWMhXlCm8rCZjNHrYMevcDs3QkfH7ijOTDlg8ELBwtWS2/MoKQUKCMCXi4B
#tkAqZaGDCQpgMW41mEgEq+WN/vcCxyM3+D4gxxdk4f+9YR7Y/iQ++OAQ3AmKpAGGAGQCD1QXq6WblVRhhMp3Julsg5Lg196klZrA
#VgUngVGVLVwfSJpzCSUAPVgOLamjIa6SesrDaAYIb5BAmo9XB9YkXADxshpUlFproFRwXYxyPWXRGCHpk3TtEp8AgG2UayhShY98
#cAoyS+2RkG2i4EEH2FedVolm4jmANkLyLOntEdcb5nnD/kADqK8wolN8lzg5jTaCVp2NRiDDEGf4BVCGzCS1gIZQACeZKRoRvYJn
#o4q0kCyLweAzk4RrmeVwAFI7rObJXS4BmW4rgIpZjp/ccRP5DqCsNJqyEwBySyGGYyDjTiH4DGSGNpUErJZcqdOaFEbSrCJatGBR
#REvHU0qrmULAQpWZITqoJs80awFd5DoS4KL9PBjGAc6Z4/zAagMMi9JR8A0cOaAREiTB3Wkh5RmkDlEimIwS8DZQ0jTsEq6zyUhr
#ESKqtVmUKoRFZS+w9lwfcK3kYKkpg0pqIXHLNGI2pWh5mNVgi1NZlLKtUa8nQXEJhKMELQpAM1KngyVBdWZjIQwQkB0d3YGyQK4I
#4SNuF886AwxWZ1SSungAPzKVkoPdF22h9NI0nqsBZTCCgBNZBY7gDBtc4M5tBF1hr/G41wy+V1FfNNsXLFIS2aQtRpMUNYL4ZHi4
#RZEAmRHNAscgZQYrAgHIs9EMmwcZaIBC8FduVKtl3BOEkZC9FnZHZQC2H1Bpd0JtEPRqstIaKRwz0yFHBmFPLtw6abQqQCgAf4l3
#DTjfIIsG2udKkCpVVAZ4iNECzsZAmaWSDC2tVWgBh5kNzipDKgU2fEmNs1PipgZk3jQZ/4g6BjhUQo+U2WyEbBuFe2F4VgANcFQg
#GowBiLoygKTUOBKKLgATJNGxHSQ4Wakz0oA7E71IJXIyQwKOWYMQGyHZtgJ6j6QPMoOEoqoblIAIwPOwTDBERqlJq3IHW1oPDoAc
#8O7rheCQEkqbSEA+dCRNh7mSGa4E2nJhrh4emuBmuYAxkMI68FwEDcjyQzw8ckB6Tr4pyzW8WS4QT6QMt8AWk0QABh4k6aUyxCAg
#5kBuMfYAG9LcFhwXYAGYYvnNckGjAPtTQrX6VII2K8NcPfEkPEHbBiXgLXp0jwab02Q0QHqBhiAfYEp1JUidJczVlVBRoBDoHowd
#EkTX8BSwkSSS/FBPOK/wFF5qMOtjAVTCIMsazjOJcCRwvMYYYyY7PF6y6tcPClUST1CCkVPgowluGoH41Z/0yPHyaJXsgUQwiYRj
#qzrHdekVh04iFZWsstIWHzC2duCXiI4GKAIS9Vq4YUFqLHrAiVoDEDkNRpAajZ9wssGaBkvGgR+cAHDAbALrBhK7MI84gzQotQBc
#IL0NfmKTrQotjVLhg8Qd0EKQDKpatKmwu574CZcG7IAWnPeSBPiLk5SANsAhtIW/OGkAYAxASifwgxNSQXEdSOkAf3GSyphqMWbC
#ttrhJ5CspJMBsdAqYXNd0ANO1FpIHeRio+Ev4gA46gFEcYslGyyiVC/kIuDeYlYXZODd5WLgJAqJhGUi0GokGpK4LDZBIGIY+GXt
#L1VReUo6jzTnqfR5qal56uw8UqvPo61mdV5aTp5CYzTl5VB5ZKZJluyJ1p1BEs9EiApAVNDqAEGTRhqNgJwaoKbAJM2E2JeZ6JVk
#syPciEw5DXgTSuotY+RfCSFB/BQHAFC/rVFnNNMIAMz0NWD6aJdyIOAPmMQUDa2Tgl2cT/j5A548qLksxZ1gEqUa0KmfF8Os5xOA
#YSW8YYkkEc0GnUamlgRxQMyR0sREA1AiDYRooCFChgbs8mDCxUXtjqlMMCFVw92vIJVpqWYjYO48tHq4H6xmHdhqsE3HdEAty5fI
#3NFWt6srgcBM0QEmkTR7AGxUwQ0g9fb1V1Gp7s1ylQD2+ejXOwmQcg8PMphJTMGMFauGMiPJUA9mpIMnH1heIUVX4Gki0HDwTglV
#aTNYWopaAE3raEDmFHJI4CIICQSBBJMojtTCbPSY7xoeqmCoqhDbZYCcKcJDPUHrgKLxqpDYLu2ikrv3hudyomd/sNMgGgIG2UqT
#OglYC5AIthRM1BgBBwnoC04kzSiRNOtpM8B1JjU1FaWmWg2pgJQziSo9blTPvOfgTnLYfLgbUAp8YNLgzkBp8IFJS8tBKWk57BAy
#cRHwy6RIweZKBpssWYbStaDHJMHu1wMc6KIGMilCRKQ2kcM0bjfj1xCHWErDvYdQUaicMme5E2lIO8UAUoZFwSwgJoLz1iATqiVg
#43KopEqzUUmgDKNFQ5nxdv2X1IBQ4WAFS2bL6OuMpCoG5EmVaPI8o+9YLJGwmnutd5DBE47fwXbCTbkREiSTSFgiapYbAfNj0ZiN
#mVD+THAguzDqWNgAIxwJ2FfYCMxBkhvU2HLw5CaBUnFNjqdiHxghQc70AX9Cii+l0sKpJ8iT4QM81XUWMyL9zZpJJYlQbvKAIEiS
#yDgu14A3tMFGKwBWXg7LA45UDqswPJ+dyMVOgpYK2HBGI43hJC1+JdjlpRmQyxyLgwIVNxYC/iXsAnw/oSDNgsMVHPKWBCwNcFsI
#Lh7snFHeplHZNFKE0ZyUq0GUkT1hUXm5jjKkWjREOFT8gTMmDPKYSPpiKSNswpXQqtgn0qwlPXSkgtJBWgiJH9hWQPiUs0AC4MmH
#3CZuHx6jSsy7Gk1o8EhsZOsqQVlQFLHUCHUg1cUDoFQM6WVoLJoL1HID+oqbCk9hD18JTMTVIBfJaCuZHUewExPQe5Mezwn8Aipu
#tViMHFttUrBZ4MGSbQJjxQWYuWtIGvCUVhM4NCiDlUmksgADq6JANTWpoyk4fzIDjECOGHnwi3l5wMfni3h4g55lzJkyMpYZDqUz
#UpEsE2nMCnP1IrwI7wDwvysQdXUA9AZADOCZZDamgQEqrWYz2A/oHGdTPTK1KosmzNWHS4DHrJIEA0cnsCgZgpFNDw+F6hECzCXW
#lwjQ+RPgPw9/V09wpoExgX8xOMIRaAlCDFadK2E2wnMSASc8lBS8aoGY60pozJQaSA56ip05gz8qktYgtYUEHaEkyAUwIVV6LRK/
#2Ge5lkYySLENo1I2baM0tl1W6CiuBY3FYqKDPQEFoEi90qjXWw1AJJWDJ0+T2QjATyFGB68ZKgSQmNHZhbkmKwCipgEoUGiVjCYo
#acKzDV5NmSmzzchQfXZkLCaKsc52lOzGNDLb0phqtFpsmsWJuF1muTBHwvIlYPHyCQqgKrs5SLbddCuQnTlogobsoElrUw0CcCK6
#jTS3pu6AYGsNYMIdE2JjIK8LKXEJ8rcSMNFpQJbAxJoSX1eYFAJBnBesm4KNyV9JmBQ8d23SMzpkkx6eU7ze0sWkl6PZwZ7BQhos
#gIDSUglcHFhSlG0xpqbqKCYTKQnBSKCWpo0FyKEAmCBPtOeZQkI9r8PxoOHqIS6j8bCjYGcogxMRjYTRHHDDbMZO/hujkSAaxB7V
#sFsHUOQwhNMgQt2vxBP860laLRpPpoA7OM1kcnTKsaoecMDyN7ghRKoRStqsbsMBHEiH60gmQhTrD3DMNYlfTxLBh4LKYrIzlc28
#KS1mHf9Ga7RqC/NKMu1itgVvPqSXcSGhFk8AJdgbBB28X6J7aS38IQ9Yne+tAKUcBDNE/BihDpSDXITD6iGoIJwZfBc31hRDH2ZC
#jSA80uSQ9Bo4JZOnhL9mAWeJmYLbpx2lJq06qB5lQA8eHFxLMNcqOqFCF4yQYcEis6NVzJCQIOsjYzCU0slAJTmtBGRHF22wGHuC
#M4jRXvnb3mcQxY0Ktozmnu/8DRUcp+oT0gAx0mrxXagEcgASxGchnarEkJWMktx57ELMBRgCxmiOc7XL5zkoMCEjXC/EzH1jrICn
#UmGNiGiYIBkPMIoGxyslKZYi8RSgRIL0HxACNRgszYwdjf5fYjkRTAQcJ1hSfGfCaFyKx1s3gksDnJIG7UuYCdhLMBWjOTuRaQKy
#esxjPNiGFOL2oHYZvyVJsX2IBEAb1RculC13D7DNTNGaWErEEfPiFU/agKwspmawF476mOHasBc4aE19vLxwGrrM4Z6Ycx9AARFC
#nBjCGq0gZg7IYUCy8YLmCXaGD5wSAtJMnkzbd+/nBfhyntbysiwi8cXIOUCIFoo5jIWN1A4UmJbh+aBCYLxYdLG5grCFNl4HBGl8
#KSHeUMxVFSYhCUZotOElsH4wMbctIrzhznOG8OnxNkKiLb7YZdBHLsQZAY5IMKsi4RU8gCNWUeYYmAo5F0DTKJrWIvkNzlFUqh1A
#VangwGSHwbTJjOQ7B6Kn7EbBte9ocA76ZRjW/4MQaAN7FA/FhT2CvtmxRKhmwe1Fmo2ZNCCaSBhn77ftKCqQpGi03d0xVv17FMyk
#BdKkVIFHQXiEExYwCwKq1kLAI0VAtRk4Ns0Z8K7MbDUQkO8G6fBOG2wZpQZIRTJkzYZaYs3V4EsCuuJn1HowAcldIDEDEpQMIhQc
#lJC6ZZBmqYeHMU0GSRtMbiVIziTNBpTBvCtIlUwibLSjRa/jTKfwGLgLSAmsKL4NgiUE90HKYHhdwwxNCp+gVB6qBQKANhxn5RN6
#mr95sdnjeoqkrWaqK7x44bV4AkLmwYAilPDx9xJYQ2HCxMGJr8FqIRTwriyMiDaotVCu4vR8ME+LjSe0oFU/8OPmxh+lkIk0UWZk
#0WNQsm0yJE6suoHEDfYfkRwGdWha8JcfBrS9Ya9GDEYPiNgUMoZgB4ZtzaBJG3h3t+8TzJx0dE/LGD+gRsL4+dkARqTx5MzavBmz
#NiSAozZknACjhGobAz5HtVCrxuIjt82VSMxCNn7mjHjGbpKtDm3kzBkl2+DhWgIzqx4mgf0YfhDZ4MEUeLaFFGPQhizLsEmbO1I7
#2WQ2x5mscZy7I9M0dNPhxVio8VZxQPZvlqvKVxHwpkQDZXkNTgNvIE2fr4dpKfgJqd8hQQn7X/8h4qO694zqTkR279ILPDoLeA8R
#uRNaLlrQdSJN6YJZY1ejCuIdqYOXbenBiHrSRjO8/DOBRzWZEYzxBDybKYp/ITPoYGTuBhlfGTSmpS24uk4Ln6DFLDz6KRVTB5vj
#4N2BrGNMpJmmpNgGAnLOoElIuhOTIAvAKlm1cMEBwwn7g9RaqpU5snnhrSagWYAyLZhlwHCvjEVBBnyGZsEilUAKSAzFdj8s6aKt
#ej1pzgbkSePNpmVoBEoHhdyitegorHHQeIeHmpDmA9RzDW9hUNCmkFBPE6BsuFmomBIqpSxGo452xeoqYTpNkWalBhJFg8lqQS2m
#sxo/Jo9A553GqAPNCtSdUB0A85Gq07FGlC0iRxlYJxqaplCFe4Z6wh+sh3EwJkbZCjGFZnU/8MrM5PrNOmqdxbaGQ4US0q+roaoy
#gxk9kOFoWqS95KahhsggViSV3CjA2+9qFZRzoJ+ym51KhScHt4mdrlalUvC5kRbDNxS2cK8ojFnF6GyLXUjQtmgZ0bHL9hoDM0Rz
#Q+VNeG7/96pyVSpOlcuCDUwyEdEpCTyC4C+yyQOigyQJKfrTsKJfvEZGk8V2WXCzWInPYE4GBHkau5vYGwCUiFlikyTfHsr4ik+A
#ROIbAV7hCUkC9yCYpY7MRspTYZqSNKtojFbMoxgMxeEJzBegSbNciWiXprEbWAL5aIq0SAO4MZK0VkVxkKcspFaHB8A+F9Mlzhbi
#pidqKtzhZAFLa2HQF9Oi2yMmY2pEMK9TmVeuC1hFjploEUJzTURBMzCHtbBxnqM67R2W58iMbXFPh8V5CszW4KYMuAdsZsnYSSng
#EvNU1UNrUBuFINVRKkU2LAdPIB9UED5z/aEGREeQD9hYtvk6cPjgbJM9FdOnot0D+Dwfd8LXnfBzJ/zdiQC8bbR425BmcJbqwNpp
#fG3bVrJ8rETOKPVBGfshCIqZ2KEAjGDatd8beJjMlGGeYNLw1XbORp14EqLh67Q2ldFgUF2QJe4cNATv69AyOVoyNZnOHGnwwW6l
#1On8SsFnrl9Q3GbM3wI63kE0wDfMhIjb4uGZzmAaU0oIe3FBkgc827btNSWeNpC5+LtbSGeidIyyEL1JZNAcCzbApeNXiUCVQmuM
#mQaOtxcqpdMgA29BVBJwmvglHSujWRMMC6JYrOET8ieQgne4RzDJhWwq1Anx1hwwmSmCdOZSF8wswlIs2wiOWykt16pkghLgrEdF
#5ICfyoYCdyi0ACGzmCLpMBNUYhSIEgKCE90dc2+8hQ02D7G1AtQalDor2NzSdJlMxhxnaPbIG0KB4MOcJAYJEBhI1JkcWeJS0LiC
#NFNSBb6CBfIDUxQebagweLArC4cBioIndlZAMmSfkdmklIS6aw9CgcCB1OH82kGU6IivDhDsAXDAcKEsg3SLwZ6eoBw45S2ezXJ5
#laqRtsAx5gPxHlfIx9eZSIwW2QfEQlonFV9V6JFZsFwuZ0UJFgngjsDLLJMl8XcWLDq4cOgAL0r0NA9uFhtkBIc6uCRuBHkGwoHY
#XAwmJjJCEDrGkFUOfJcBMQaMTo/tBpDxZ6IeiE1JMrxppYlpQM5Jkon4DAd8qJ49JdM4Bp1jRlmOghkvx1XoHLMR9vNgrI+hRwpr
#PhFK+ODLDttFaAu3shT6dQC5W7wWEO5w7eEWlgruieCGwaIcd/fD56HFwp2yrREs9RCLWcLTh9KbLNnsPNklZ4YegZcAXlDTVp2F
#dS+DKQZERgGi2dYAoDfbsuIKe+4bkmfQKmURMW7IXF3E+XNWwNzVNE+m8Bu+a3I0Tw57aZ4CcopmJQIwJDRg0Jxexxv6xPCkyJMp
#gRzD4OxB7gCos2A3qJSWhYjapfUAV+GdJjQBYGmjTDxuZgGQlICUjB5ww2pV+a5CNtOWFbaQCi0QSaCUwGCyFmEsU9OON6bZuzFI
#6ildvkABCC0ledNOTDSh4aQry+zbMCjgbGF5Q1ubRobisowW1h5C9aRUxEhgZoLlXWjOnAUkOexSCUQUC2NEyS0HNp4UDAPhDJOJ
#nAnBWgUzS4Yt04l8B0ygfXcK0gxlfRZCSKSCSlKlJb+5K1KLllBZbTQi1hmuPBwu/IV9oneRHlZttpNSkUs62kbiAxIqco0GzsAU
#rTcq60CItef9sQInF3kJQICgwzMfSQG3ZxZwm6tZ7gANYzDDDAcxeox9B25vgEYmFq5gEVtzGSGARVs135ZYont8luQhb0KBSxvD
#3hBy+COx9W+z9Wzz9sPubipKB/0lhX5yYFIidzpoM5sKGBk/dhPzbnB+PiV6wdkQbrMRutoi/KZZIosJM3+4O7IhRnK8EIqI7GIw
#CsCFaUiqGapYpdgsDBIxd5ABtio62myprVCZBVgDwS63QD0/qgiFPygUCLaOjT0ZzhC0za8p2rUoB1sDAHAFYBN4E8Mm8yMwQ71d
#GoOuJkyfEL2QI4cPlqSx2CskaeKdkqkxMnZyJmwmZ2Ks5Hz8GCs5lhLZWMaJJ2SSpwERmLadpwkIx4DiO0hHdx8idBYy6CIIEeFE
#gO0K6MFJiRQtgrVWyWEq6wktbMADNJDPo4DopOMYN+GFNS3H+AeJW6KAFXMxc+e+yFmCO3AgTTEkowAHmNemlWBMyeAMdONeLGBC
#XrYTQlk2a6N0RUSZbYIHIkMAuXkrMxiB1AEptFiErVhsYI5mz7LqbnY4plG52p4DKmb/2akJBCXSSspUlZSJdFq2J0kKNz6wYZkZ
#W6BoZmblJrRBTHK4L9FJ7AsymSs9pUWG/Bu4qiXX9OFr2lakTZSy2LqQOfdBRiX8u2AUenitKrEnc4g/bYdESscMKo2lRkZINKik
#WbDTLDHLIWJcZch5CsusIi4NoKqN3ZCtYwbmMew5L0AW9fB2KYURhogShSHsIZbPUFqHQ7FVTyJ7NEbbhx+/4/RVYTM2rHO7PXd6
#SYpU0mwpzqUEaZrMlu/1LeH5MAVSWIpwmGdEeT4N0BIqFa51BHNZzPFmOJ0rKqJLIjZIpBKGvrpI82LP4/mwFbilsKEyWngdAW3C
#mbpgWWFFlOJIlEALYrJZDZEcwekX7S8QbFZAaaGRKTLznmr8DvYHc+22lrn2I/T5xhDBPB2MkgG4g8GqmdHi9bUltywjLCS5Yv7Z
#E77wzLHAGam4Jnm6x7THo6MjswMJYjeCkVLGzsDAvsrtwVNhLZQMlTl6+jvGBC8VHcwRJsN5Bfh9uwmrCTos2zUC89EFtxRfjKP7
#fIDIgDdUIh0VmywTOXKJcKtZrohFdMTeYYc0qDUAT6zpH3iUwRy50WACGAZagGZ9UJAUWmwiqzUzstWMhJc4EMY66BbXHfvEo0zs
#ag9E665mo4kyW7KlEg8PUxb0mJZSMAIAKN8bzAwyDWoLvOs3y5HEA9Lk/jIg7Hr4+MD1AHVKbDJb1GQf1KTFaMItaihtqsbCN+nt
#xTeZ/12yACbRhByRFsCctPy2ROD1b0gEvkHfIREwIRGM+BrfFAwm6E7Q+EcBf/AkxSdqPNYQS9VaM23pbjWIz1ST4EwVRGvJQmw/
#jKiUxW5kaDPnjqxExOoXd3Ro2uwyL2aHCVGQYtXGtJUzPgVzkZuIUGiVmEvgF2QqAh9p/lHBxDARtKYyk5m8ohlaCAsPVf5WDs8e
#ccIAYJJ+VvhJQEgrBPYtqGPkwoayfSQIqsWXpcVlFSWVVQjLQs5b4B+O6iCvb0AKJLY5PjjHE2YxproCIMvspix45VsiIinGfEve
#shn2MxZthZIi17DrYeLXw8Cvh4K3gQFLwRrqOQ4pA+qUEFQG5AJZC8HcAKAp3BYs0gKU8vb2glgV4CiATFSWCfqdW01ABqSCMW7w
#2wYaIqGGoHsetG8FaY7tdaVC8RrbcInszpBSGZq6cI5rrGcX0kMLFKWMqyNvBmznsYCt1aFlDGvJ+c3ScCJm1sTMkTExYz4osXME
#FPO6jPiGLIjhwrMmxLi2WMvL3N5QDqLa2FYDeJ7HnsLci8CISmTqFQCDMwqYddZmnQUwgGcxemfepowdgYUuwbIZ1+GWDfQTwlIw
#zlCanUMI36cAVwRqcKSRMAL0ZW5IxKKHjHmwo5EAfRm1OrStBwvDKr2hBhQ2EsyZU7MQV1NCPwnAg2kz2MA37gCb4fjUCOvUlDDg
#B/8mlWCNFtTqOUjlnVTFvQuvakIcnCBsIr5IECUxshubxm45zs4Qw1GtVfFGlDhYYwoaU6JAv6yG6uWkFIbuGWDYEuxZkEsw7h3x
#yJg7GC0SspbMFx2SJsiZAQyBahxs980cFNwKaVUhyLtXpP7jLc+QqaHSkWMT5w3qTrgphWCEmIDu1UTgYLyQONmP96KA9mycCwW6
#3WIGykJHWQx0RMBRyuAwxd4xuYQCCKVp0KKUIgFNgV5TCkpDZmgBo8wFqwTMMGm1GBEPTeuNRosG253mC28FwUkCJyM4agXLz8wN
#bw8GwYvfHmhPM6W4KyPBlsFZeEfYoBREIduRqcmMeBKxq3hkvBMO1kTbUCt4y8hovJPw5YjwDg3sSh1GGRHv69jjD0tOnKe7gveJ
#4u8cFRxm6Bk8Q10RbF0O0RglhgNEY24IwVSyEBgVODgHAoyUPcZhy2p4TfZvTYEBrmgKajizRHUSdF1EDyGEQw9EfsSoVDHDTUeD
#xUaO3GChOYBwpMgxio0EJLpat2+U4QhVLH8JAxbKoFGwpV07kGbEPahUJTtVslUjLYZvejQahfPhK/FLIHZ6Qz6fov7tfT7RaFGg
#QrgiRgfCiVylApKJ0WT5pkzi8Z/fUvjayyQ+Jd5S4PmDSRkNjBuaLeZB72D2fh+UswvbK0FzgVfs0MwelZYj1XwXtdTxySfgF+y9
#3CB5KRHGbDRGowlKlGQqmqaUAz1LZMRLyju0iRk2Qf9tzGZjZjvohwfZENuMHiYJ7tjeL9HhYHBksZLngQfMUl8IuETH44kAJyBg
#wrxhnB4MYIYhCYYZoWFI+S7K8CC8QaYW/sqSRO58zHKLQzQjpCye+BgdEh+87sxUjSLqCQEPtyxHejJC7DoV4M53UFHBcY3JqFEm
#WOQYbKpoE8TDKHz/TvxwTJSMhnZGJQ8VbnEdOFuLe8HgLt71k1HYMO6fqBtsh8XYJNguiGDj2HixIosIhKNMpA6Ad9pUgxReAeY6
#9BAoxi0AUQWWwLPBGKGmvRlzSNkffgo4tm8cJRgiLFfFsaaccxcPdvs58ijH3CA7kG2UjnEU84MMkiodVURMuIgFDClhBIncdXoS
#JkXC63d8+c6mALJNAUDAxGCx94MK8tWY78EEpMReHJ13BnQ4i3pmuU+UKhNCVCw2Qp4aDYGzG+Nwze4EgA2KaDREVlv6SGBHd8Es
#7EkeXob/iIKicbpxrfLLI6BjLDf+rw/92xPSpZU0H64mGzDSbsDsvraJUVFsYAX2ZohT19hLIjb+3EL9IAzf5HB/mGFg1zShiQUs
#K3A1R86C376vQ06+jI0D9BuC5hv4TVTJxNSCnXBLakJrCkfdFSkppTrAK7S1ZEntSuFewFOwXQvujMWKCSouTTpstwIJHaJn9poT
#RyA2uRPgHx+8sP/RbSUTwx2KRuiaig9/wQXl/b6rxnwoEOJI1uxdj5ZSMZ61+WJTT6OhM1LoCJCH0S1nM858jvkvNHKGwjtkxTyx
#QSZupjgkZ48IwdFpD2NHMQzYigqdFfrxfgcmO2iamSLazrYLiWQSd8wxuPPRhR0Rf4HEivlXHVrlaMi/OhZ/eYAlClg0d55NZB+7
#w0sM7i2GUlskSbyBKwJNsQSEl96+m0HF3YUINDK6RLvvG0A7RZ2AR3RH1uUoACPkFz28ZdBOl9XWIApskMO9xTCpxXPPDHnFkVQc
#i6nupLucPwf+l9vrP99WcouGMjC6WEcbrJjpiaVWPFm1hFFsQpWHC6vJF/MCLF204wfYDDFPwM1UwBcINXQsP8lSgO8KJ4IIBMLY
#DBiWWSDQctXxTvservQbdex6xePkA0dg+DPacXhIokDQ0MnbneBSmdiJ/4JfbUyXDtFxtu60OGaBwWjRKimhS22bmK4dIZfbJrJt
#u6j2HTp26hwTG9e1W/f4hB49e/Xu09fH188/IDColcSx76mtnwmOblV8TDs+0hVjNtssF48JWTeYeMs/C0VQZjM2C2MM4EgdZeYs
#n5mZIMcQ4d1/qMYblECxGRi/Fc7DlR0iRaoERgW6kv2MdKk+rtBPhzc9pUw0Z/ILfXTwdblC2CLtzXoV2ZneokyVnVkUculx2Ciu
#4wMbLKY9H3F7Di3JCSUbhU9pUupVxZpY6IqzAil+gPxAfEuatW9xs0bOS3ZwV0F6SSiRl2QowiTGoki8dKyjHmgJPjoyVlHaO/7a
#O0DhdpkvQvDOTQLPJvgvtAODWudQLe8qzLaGnRjCXOF5AZ2oYfS9EGgEjY2TUFhe1jEa/gvlUmh9mmUBDVgtgICbYPRnbQ50WdWQ
#ZsC3UGaayTPqTZCChrkCWuZK0CYwbqWGUqZxnrbgqMNnW5hrUDHbT4fikbMmlUirwlg3F+PHZrMR9DQbthI9YXjiyDpsj4DRCnM1
#GXVaC+VqYz1kYyOmIfVYxY+bhAZENl4nWppUgMURrrbCYhBhJts2t7XVYiNSxNFQAvcxzu5E5DTG2c4ZsyhW3QclfjkOAIpWC2n5
#Mkg+fggqjLCDUQHgQFgcIN2JVGOkhf2WV6pRwoXrQJ+AItCHuCAAehgsWh3/CkN84NAGCiudLbx9En4uIJdIDia8EH8PzgyBTz2R
#RgH6xH7ZgM7W6yn4yTJS58x7LEH2GEV2JuziOrPfjIFLzOoOmI/A2Hw7Bop6COo4gD8hgVWQY5nS5prDalIJjl8EFTm7ujCoAanj
#rlPg15Aghye4BA0VAAnkQKAw32AQ1oM7MwCxYOL2Ebsl/AINGAz6/gz6JURfn6GtCr3W4g6jr9jd1Gh1+E7ULAQWiyvs94IsZptA
#/0mscSm6i4MnLc8FK2UyoWl4CINQrF5JqgAMKgMyBaeLohO1SdgiE95f2AsN4MSEbLcxDV2gs40mcgwwzZm8+At1o2DlkK8BhAqn
#/it2PGjXKRxwX3ijuNtcHbBQUrA3Iv8BhBjuVxRTNxethhQPj4OgFhvXMzy0zV5E9trsi1CmEoHW65ugZccDiwJcg0F1/GUMjBE9
#FcCUBSUjNTmC17eC30WSyjRwWCrxzYALO1bUczi2OHIkQbHj8YDjEWoxRRl2Ay3+ZgAJcIJuHbdTbHUsnn0TYMWLVoCOoa35LXia
#gGRD8dB0BBuEOtj4Dn/Rpx1jQsJcKYnSZdBiED7gD/VgTUQJ/aOpcPiv4D66g/WNMpFlGyRqUo46cZ9+QScAJwVbHF3FcV/vU1Ja
#MBeeOgptR1jjEU5+hDclxXdnSwD4DQJz0EkK8B/666Yh/oEG0wF0htkTdiSdicEXQrAfjWEPNuFXbmCeOztIkR29GlkdcB9ysiVF
#zHlrY4aAxsJMBda1HZ5tkHOWnQgRn7PFTAbb4NiHBHUwMiG9/gYxyWeWB28IryR2a3g52J7uRBBnbmR/sYo4FYngErU3vlj1aOVO
#gP89AsAZw9yoluDDFW1wYLNpY2jGbkWBytYGZMwpXfw5LtZGMeDHOFMMKhW7hIgJRubWPBJ/n6UZG5GX+UilEt0SIZ6CMSFx8CUq
#jJjsbjBQDEngbRFtY1rCDwiwHrTFoEqxyGGH4fypXiw4oHQNNTqs56ydEV8Iv6GNaQJnR3StzgRMZ1XHLCPBtGWH/ShUrp5i4xS7
#E4HCr/OhWkLQCGNw+rSSOYapGUYuZD1/EaPs5hZiU0ZrAMukVXHFkE4U8dThYfB4yeU57BARhy3ARjfC1wtFDRXMChYFu8yfpUfw
#L4Y0f2WBsZ+1m0CitOjuGG8WljrYqMElLmC7QkSTCBXdOpGiWxDtK5cAwl4wT/0dHxSOmFuGd3VAr0qkNiWYprkTPgz1sac9aBMR
#Gm935gnpU9zlSFFC6LTucijEf9sKPeA/tvgIsrf48A8ozriW+YjFv6Ria9cmvmNklzbd2wm+wUmR+kh0rGPnU6R9grZ7RjOFvqIj
#1LplIBmKYsLwGw1QzSV6kWcYLYLYhhkKJEqaxHdlLhnIPyvDwqidk+EdEwpriK+MbNwa0RWXnP/QqE28y4w0QvQJAaU8I02ebbQK
#tDYpfEOgUzhEVfGNqcTeu6g5VEXOfpEVKSKYhmj09VrwYqAoaL2ab9cr14/DKBVcv2z4K6MFOdxkWJCnv3AcaYwvDIFyUefQyYfr
#WxBHgbspduSebNEzHzgSR7uyaGz8LCEiCNRz0PEGIgX8bLTYd5j1jWE8ZllvYTR78cc2dNDtFu0MCVg0xv0NTgF9uk+ED2EsPqDC
#llSL2D3+P/Q3tvcuBjMTjsxgE/OAKcONN4UIpfThUj70FItislBPkJHCTsXEfKgC1bByjmcqvWApSeFnKKy2fvU2DkwaJAEig4xc
#IlNDAdQjYRBuJlnGYhz2bGLWAe47qcnmEyNpSH3MekkDTtuBb7SdFzTn0pRvq5nHkYyFxIHAQS6RRTeORKlPMFpIHXaU0XeBx4IX
#VhCJglOWHCZSFLiM0umMODwkXH+NFqrrkJZcCDBw2omVZ1hLa6PyB6+cv6Ue4J3W4GExmoID4CcSRV7RGqGnI+oAKgz5YFhCGMMc
#QXRdUQ05OOfsVcl2umNdhpLRV+K2bBR/xc7lW4OGjAzNj9qud5TPBFFEj9/fNf5MDrQEUMV/x0hwyRKGggFh0tHClv9FUCDfeKok
#YOiZsHvgl80VXfIwuVEong6Bdeh8D3phxAeTo2sNGCWAjURntnM1tm1Pg6MKiG83RJpgztWmK2M0zop/Yp+0GG0GxclAvKUgd3y7
#885iGMf5g9Moswmqo8QGe4yXWkle8JbvKgm93o3fLOnYx51l9qkSYh/pMsD2hhQQfuJPaoTHFBAVdKkS8Umgy9AK8cUo9GzmyAzv
#im1kXbHFIbh1OkBdjfJM0qy3muAJlskeX1y7XB5aYPzGBl3SgGkgJBXRC1Mx8Wy0qa7cvRYeB0PWsIMuF4MA9m20C+UAeiy2kriO
#IHCDwsE5hQpJ7E4j/saNX1gh62DXDlvIqObD/BgdhPkR9mH3LwcpcBiC/RpJQrQASCxaa4hBNJwhzwQrLSgUGRvdgQcXcuHLFxa1
#sEVFJWFBC3dwgkmXFMCFdnQCefvhr/TyPRnZntjwD0zIfb4fhodgA/FgrWRucbtCTMoY2GewzliigGAaObyxNvCIaTByzm4MdRPS
#WnMGbI5vigvIJQ40ggMwsdSeCbokupnlIwrYo8i3w0BxfpgST0KCVg6wzfu2EkL/ePxebIArET8liGRAMhED7GPzodhxtgYtMoFF
#y7cjKxXLfbFaCZHCUYTYIqKegekoEsZYkctOrmLsqSg1H+xeYHiEPWkz4IfWTVozBWMaQo946A9vI9cIFjZDQRpcbVYSSjJ0MvNx
#JoRTSKSCdpkwicUslKhAsxEoeHiZgItq5QgjUGWsqSlZPkPOrmjKxRGRFFaByB+CJdl+snKuQ1vNRE6kSxIepRmKYj0iMhT2WsTi
#v2EDW4ZSIXpAE4d2lm4ZvAMRzECqEKy3caDpQ0vCvMFvUWP/NARQ/IpDPXBSMFov+4bQB9SRtSeYN4V8OZFmiFWlOwr6UqyJq0mX
#yAp5Sfx3TaGRqwMrcksWtJxj7E/tTEyxBkmgUsL6e18vL/aaDjQgE5qywndOfhYhwX/P2Nqk+x+YJtuEG4A8u22UT8zbMewu/lgA
#TmLocyJUXYk4QAxa5GqB5QW7mP227Adm1mFpwpymdLXbm7TcDD/FJthuzXJhCgqagdViFlyG0ciKjuhMHRv+iRNjxUoRFaMS4VpK
#Aweysb02i1JJfcRBnrg2XYWjyzQaWJrBtZEJVkUUTVAk44mqA6S12NUHiQCV7eMRFh9RhwOiIwAizt5hBBMVmQ1hiAok0xRlcGDH
#BNUF9mXsoyR+/3iYzws5GA+MpAuQLBmrVCMIpm8+jaH2zJwEDYnHbNuOyvLNZnix/381NdIW0mw9wMqJ4zSynDw+1GhmAyH6iDYa
#nj18xAPHYiw3cjasqu3UYXtG9kaDaQg1wl1y/G/nWGw8HJXVjD5VCwYKyzi2icP1/x1oiwRxwWD0YAtbSB0X4Kp4alD8Xv4fb2JH
#u1dYVSWqCmNe8FXhW7H7nmMtxJQbnTsqG9KNg83wlFoYJIbmgsTQIBuUV6EgMfDc8ebpN6ePEUYqdhG0iNl82wo2FF9Q3jEvb8q0
#ZfhKYt1NeIOJdZm0eH844MxE7UMs5SZeDENoskdym5Zo9htodDENoNhfJbXARJASDx/OTAVvgiQGq54ya5US+LEfg0UDff3R/UGx
#TKxJ8FU2h51+O4YtDxfCE6EQjmXMHYjeMnGIW7GezMdVOBiTktsSAoHAcQeCyJYihBcHhOWjRAB5AjvCIMM0M2aUwH6VIFUJJrFM
#KtyMKBntUT4d7TuYjh8geIFwDOiM0SyOgY5oDGY2HG4xYXhMPS/EK+FNLCwSISwimDTo0h8IS3p4BQab4VVeiIGm4ZgEqT4w1YJS
#JQCv7GUoWzWhHvCyDmMQ2n2uRhChQs/eGiEll55RctF6cGY4IM56rcPwgnoc0R4G/EdP9tiqZ4iCMN6nIBue1nJ4SaDi5G5OM4rQ
#iOYpJn53sOkdjNessFHtUsjKndMkKBWutjtCSUOMh4AR6L20gjoW+zpwcT0I25pMRU8+yhzPGUAk4BgCESogIIqR4PaMDcjgFIED
#fqQF2yYF2+FQ2wSELQmQZGCuARxq6MRU2ZMIB+BKU5F4AoL+xePxxV9M0wvvhPTsnRDzBr2SaQuNPy9we/A0Sb4t4QLVVeR3jQjq
#EQD3j3Y/gBOONC+KuahHX9CwLcFRF7ZN+CElziabynD9v++rSpSF0/OL0jNdHWgzU2zIpzGThnZpUtJsRnf02JUS3toj1sCFNJt5
#LR7zjUih6lHhIw4djbW9+FZYZnMtbHsv7DCYNK10wAmKmnEYyFf/zUC++pIC+epLCuSrZ7/AUkxNfWpJ2foMU0nZQl23zayb5ULo
#Ow6ZbTE7ugC3AbipmGDYASUGw+Zvqr/3ohqqwZIp0qzLRrWswvnBPLv7aZUg0ux/HGybJSP2FUg9mUrZp4MVcFAaAf47rqvtDACx
#WxsSN6Qo8oLQFDBDDi+l+YAY+N0uFBlbD+TD22xsqoVCDOls2GZoQSlSdYm0dynMF6g9GfknQqfVay1h/i2MajXoIQxq0GEH0AfS
#4SeqCX6ENlG+XMyCyHLCIHNMVw5dakUh2ZiCIewk3cKE5h6iUGlmI/tZcwQApUarUwHqaidZMOABPIOljWoAqQQEGMJJKlFQarCc
#gFNgvl+Jv/bCMmwygfE73xbaeLxEI4z2Fkr4CwpG4TtYvigzoXDCi4eX6DsqtkZiyKPGdnZJjPU+nL3sv/DZgoD/4WcLBMCxDYck
#xH3GL9VZsDLfVG871m7LIYfqIJKVoCI45VA8KwOVZWFc2eO1CnCMprojlSvKTC0h4hPjvgu3ocAazAXVhc4FKhgkC6qA2sLV4beg
#7WW14y/As/vPE/IclAHaOPboHg0/7AR4BoNFqhDGsCh2K35j43GfisjljScFCnKxYpwDHMF/S764OcIikBGQqr7nEl6CxDnB1aaK
#44ihXel3toRC03MNidphg0TlM44GJQfyQksoE5LW4uOhQgBwmxjWwzDBcYqZ0MM4A56rXuhURQH2bKHrKEQqaElmg1l2fTI29g46
#lXiZsiTFR1gFNdwJXDgYV0cmqh1RimiHO4qu2taqQPoD1o2SN6p1NBJmxvlcUEbGL95haZiEDxs8FiZc83fORBytzC6CcrSh5JFz
#cGUcLvgwkg7ObXyBJDZZSeN2s9BGnF9EjDbYmTAEG3yzJvNMWAQHcVmh0bvdZ7a4exE+AEKJ8V8d0AiM3vxVmYzgrscJ2ziozLc+
#mGFBAq3R2gXJQkwdsoQTWcKz3/3BoxeY+4SILohCxEpH5jUBgYqbN29KhMKi2NlOo95hlG53At14fNtM2uc/PgcDHZhJOzoHOTNp
#sQEUs2f5BeYvwrByGZkOAZYAmSgyTB16Fl2a4bIhoiNUEFoD/s2QMw5P8MdRBAWYbhM+ASf9e4bd3dvEdQZ7uGtMmz5R3Ym20MKb
#wVbmpg3yAkBW/P/Y+xIAOapq0SiKEJ8SVJBNrEwImU66e3qfmZ4kECBAMGELSyAGUt1dvWS6uypVPRvt4AIIKCCiKIqIgMLjiaBs
#ivAUFMXvQ0BAn4gLD0F94Mric0H555x7b9W9VdXLJNH//v9vIDO13HvrLuee/ZwLgGTrkeBRPuOSIsiW9bdKoUKYztGOB07O8isI
#7HFmA+RKH5RNJ4066XygDHaJ/GVdRZFN1npmV4G60xaLdZnAHKpx+APiroEHnPNyQjsCRRv6NIotnkutpI/YLM61X3MoeqrCQlm2
#CXQO06x5gnwqoaWS+og2oqEmIRFL5rQESvTFml2sG1pxesVAEqTn4gxFrNsrBjLwdkmUfK0tdoK711gypaXjWS2V0lKJI1NnYDvy
#u2RiMhPP0tVwPDsZTyRFW+N0mLrcErSSnIyl9IyW4T3LxDJH5uR7LTOZ8nV1JJ5lfR12++q22UgOwyizWnYd9G+kHoMr8fmC3sSv
#h4wZ/0JDo0pD2XhOw3/JVHyEfol28MgZZRij2uhkWk9radZnqJXUUvEkDm80nj4p572KZeOjMWpJmoRRLZnUh7VhKpKMxYe19Lqs
#/AyeJmDCczSnI5PpddBePQmdcrtU0Svqeiehx+56J2PJJNQfjqfWZmDN6skYLNAq9hYKalRaWccG9lj5QkFX164Bg0uOxHKxnAb/
#qJTGvIeUBc5o6erw5DB2KF2PwUTRcDOTWR2gh3cOro5U7mOpk4a9ew3uq+4iTgBS9U1+EqFltM6VVO4LeFbFedOzMHb8x1qDf8kj
#kxwmZ8XuqRXRYYCf8B040DwF05aZu+otCSs9R+VbWPqKA9prDt04zgOiZ5kWzt32x69etf6Yo9djXPcSwONEtZZU7JqBfoZLdJCn
#DYpCB5xtL9k0Nh99ai0yX67gebpdpoRkIO4vEuGOIFQUb+hCsJdIYOU2gNvpNysP1eOJebxPi6csv0HnnF2h7kVKv1l+Mh+75XOE
#Ye79Si1XC0muwu5gijbMqMhXBsJBbXIJRUer2RYsc5LkuG6OulZRhHKUajrwbXylG2ZJr/OFDskUAr1lHBCtPR2BrtpTrOntO9FJ
#7aLPEmEVnY56W3eK8GiTuG7BDJcGKXOUgAyj3neCKA8oQoLajLokKPZkyUb8kbWpsCg0Wc0A7Qf7RroDfzIA7u6HQGnUw3O+xfF4
#mEgAJCUAC+O0OcnuJLEjFFidhXXi6dmsQ5/YxULqo8z7dxXn2cHQ4bK8byyykEEdk4R6vOdxL0sw5mUJe8RPCkdLPd4WdeqQm1aM
#O6fJ6EB5RdvVG6Q8KO/YGeoKyGZ6k9/gFR54xNK3mOhPx3CYP+UwgD1K/DVnneHGAVpuhkj0HGGpWCUnVBqnEhOI5FELHr9mFfwH
#aDG7ZsVE52h2Ij2QnsElWH+JqgonTzD2XNLIy8FwiMurmjg8hLv98QVYIZZASJnVAEaqhqvkcxlfFBmFDqQDCnp6ZIl4yYN8MYfF
#as3SlGxWReFLxA2DompccoJ1j2sLNqa0hA5fkr8Fc8AgNzDuoCQ9iQgTn/KNXqfBWTa55Lk+fZbqzNexmtOSPUesgONemJvveIjl
#U26DS22htcPdjTo4mFhBL6ieblTBE3EFoIltjXgEdlsEQGyZH8ZKlCNu40Ya51S9hDttM44J/ZhEuB5zTXKD99DbaHYzIPGNfHZ0
#t1ZYlB+/cy26vKLrYBhF1xUYuuQquEmct64DatjkSY6qh6EaJoqPCvKhaeqxqlacuF8RD8FbWk/P1hzmNuQa+WuuwxWvqTQtG6fU
#tt1j/urNcXHOX7XVspz80BCVKpqNxkQTKGQcrgRlcYZ83xrg9HXFwOmFuo5N2QbxtsgqGbaGB6aXDWBtbRdFUc0gjqJEguyVhKZ0
#X/AGwYze9Guw8TRAZF03LuEdZUrYYlzcomZWegWbb9MmWUENbcaZiEqac0TiEWqVpebauIS9FM3yO2zVe4GNRvyNko+516Totuug
#zZyOu8b4jrl1pA4Vme/jEvxLDu7k5APVW9zdnRdwg6NdL/hu4dki2oBFU8Poxhn7snCwyI8/ckPEvaHOSkPmwyybNgyfHdKkmWWQ
#KXhDQKAouyzKviRh6JUlsHHIVxynyzLsBlf0RbysUeMRdTF0OldxnC+GTl4R49Ddcf8qhGCSClErbIxtXagDhL2GeT7FDu4Wi27p
#gCUonMJuOSfXWtVB7A0dUq6XGmoYNnwFeedxuD+gTeeLsqMhRRDDklm+J2rqbqiH0OlOcS8epKFEiyskrl3DXcgkTDSDDqdFqqW6
#ortt4VxN9J4dOvGTxo61hOAwgfmaI+7Z7cwZawK9e2ZdrMC+PavJ3aF1ZZVlT6kJTwXXY3JICekloVK5GrGHZb7mgDYySrPAprhT
#1VIYBlYp3pKUy5bMeODZ4m4AmdVMhVW2woLDrDqV5WI4zfd47/k2rVaKTytImI7Z5PCmfJVvj94T1nGqPLwyt9maHN/GmcL4Gn+A
#cOgEVEwxfrePKwaS/rbonRIh3Gm8gY2tGlfGBdNORcnSjUa/BjpTr2CtsAwHuA/FDWbpA3TnhD7cOL4pokmHmHOnA53OfEYAYKbF
#hEDliCDJi76BmXGSmYz7BrgT13NQ8kltYNawTIbcUEW1nFupak7YnWrlRB0qiWN0HRNdSwqOhx2UJa4opT0fXJ5mhuJoGHjmhQZJ
#nPbYHxzpLghLcYmyAMFRIfkaOnJIqeKKWKkrrQrZXmFTpS2J0oIjBC30B6UxkdMgfoW8MXpv0WIVu0WLyKfIhQclYIJnOCGHSXcD
#AxwMNnrsXOWMZNj9bMsine05A2xR+hw/K+xHUnafM2ArM8Da6jgBtorBdIbC7LlMRC+sAV9rVoArZV9ltMqHOGErAq/PfC7HO2Ax
#BZ3Mp4Rgiu6uGp5eySoW+jrGd2SHnJjVS3OFne7p5lLpEsRZMd1IRDpfQdLfVFwvkYrpHo/jU9kozmB6l+8AJ6DEiup+OYD6734R
#istMEt8ZrkjAO+rTKvHbHn1VWvQ4CUVzxR/PpSWF0CqNeW/m0p4rHXS30IeHylKWpf+j8bE+laEg1JjBH50OvOtgEC2fhjB6LhEt
#ZnWQ5nl8TJ4+Pc8EId9a8MdoIui6FIqPo9MFrhk6VECb+UR1XjJX7BTnxzDlmyCztuPuAo5re6+jx6FiisB/1EL1OpeqxSPE+4Rg
#xuqp09Lf2DHs/h84bi7/V8O9BzG5iaTxqHqjr9ikpq7CBkODIbcpeVh2TID3RiiJZ2NSBVLjMrYD2YJlUN+NgocRy7djAWgO63ip
#CziXTAWUS2FYuuR+sGSiXr00IyXIOh2XjoZBCmUJvvUio2njgoH01Ih0CklbvnUZLfdMEzIyiacBhkzZ+8hA8Qp8B/nZFw/VlMJz
#y3Yz1ZAQMMSGs4RNQD9AWjJ5EG3fMCp6sg2QGkBiE10WHQV4Zdknuu9Y3wQoS79swoUOggDuEMC1jh4UeMVI+dHXNp/7DM5t7rir
#3iz6LmEOA2O6ReowXWPeoxpA0rpT+GhhlpBmFmY0kIo0PF2CElUDx+g+rJrA7Fl6xSAbhbZG0xvUEh5l5Vm63CPGcLpEx7zsc2Yw
#M6X/oEv3tG3poDQ52VTIoWd0zhkzqNU7NMOtYUErGC9NaNo764ybjhwEAjPuQkSUsrnkedIWMcAog0z0xmm7/kWkgBTl6Ya0r1bd
#E8xh0EwtCwvNrgJqVxgZ4B3UReJHJaWkNsu+So3lZUkXXejo6TqOXkgQJl+hjWnk7UEGp9TY6BGKTD1z/9mYxKMC+Ht4Sh446kMU
#wmcZTO0gh7hVh61bc7R27KqjV6/l7h/lRusQ5IfIIIwqgpS2dKmWRj3BYFMbErdysCx6xWpHHIIcnlcjhTUkPYJbN5VgFdZRBV+J
#ZCKVYa/fdsgSyZPEARo3jodCOFKyVZaxB565Ck4ldQ8bz8kwmDT6EuI5SNlclE4Qc9P4SLWj5LWNeW2hwMnQF+gQnjIr7QQyLVAV
#0hhPikMTNh/QHqxpS6myEkUchRdHQisp+Bd6ZlkSezYpErpDE1Q8E1Fa2RxRcpRKQX2ONS6SlKr+RQe0T0YN6pHwHE8qxe2zigJ/
#j0dRULgchbgGLbfM+kwFLeZ4VBZ8IhHFZtAg1hKnLGhMPTsozx5NVYcpgF4MsYbJsCta9jfpBgSGpdFchRtqUFp35sKyUOw15SZe
#I565WnNapj0jslyhZ68xyHOCockB01tHpJNavXSdY1IUIcvX2dILea3uHMGPcAciUcAmXI9mQEWTee4bwI+hRVRNArjD/B25iVnK
#64n4rcLycfsTfPLYa73ArVniQ2TpcB2h6dyajUu8PF/0Utyylwwfui/FbYSZvbjLL5s22zRbEfqosK84M7CgDfer7I61Wzcr4jle
#cjMQrQ214AC54oQCT9RYQW7E8CYSYX9JluXDmEtKU08xo4szwEj3J6U3VQbEyL2OmTjoXmTS0jslQJWDDGEgwssKrjEKilLO4fg8
#o1FXa5FbmSuY4EqYgpTzn+mhN0ue4g86aDQoB2ahFGMVRUAsRip20YPRSLCibg3IBneuXrF4UJpuLZGQHPBQ62t0hhCg2nJTyizu
#8N4BzEr53cl9nB5CHWCcy03p9GNxVITnq2QgL6V5p16ImhgJKJJgSeVpGQ+l3FWDFmwtZ5LqDQqhrh7vyDU4k3GPBcoHM1yxrkQx
#piSiMBCc2kN9uopyD1H8fbhpDyKHMxsNofuTcXPSFSlmFRctXhf5n7pfnQZ9wS3Otf6SvdSZRIMptcr3iWJO3Yi9Iw54ExlWNy6Z
#aHKbKrugXTrRFAZWfsWformVHpLdlRtexZA9eyvewoaFPoqTqXTM8ShPMJt7uFECKzgAQEU3SZg/YkUvrGfD8sWtdJYRTCiNSLJz
#AElHfzR3BmWJBufWczajRwz8B49af8zRIGPgyU+18sygsgjuEUhcoNItBW3JZT0DhPJUShHjS8vL8gDpzqRqInVYvgoZNemUsJe2
#uetK5ciWEMWq68/dSO6f6MIUTPg4hDdemshZ+nrzdHIKEvEHvdKnOoH0qfkeyVMdf/LU0NgExYfLabWo466/WDDplPSSML6Ue4rd
#l8t19wy5YIYmjdrnpz2HpyfVrTrrPi8lBbR3szvolq210A8HxdhuydpDoCDMxQ4YcjW3btNzBvJStMs512Uy2jXPutSoPV5Mee2i
#+xpvnMEQf0RRK6H1G3Jm9aEOYfC+wngaMh5U1IcfBHn5hSZt9cMBzzstwICchjknsHnWXXzVYmY1ZMu0jvkCbMKWWDPPthAhTxdQ
#xAP36DKfGXM6EhGDiGrUG7dxL+uZAH83j7V08FnH8fI2fClohS9Ep8N/ACMz3YYzCHSmaJxYiyjHUQAK60eT0xtL+8L8ZCQshxpS
#tq2tTOHrQ7JqugjTrDv+lDe6XUQEyY/kxPToW4XjLH8pH6woebYD/xxnJci5Pdz93VfIRU/EzLHPIdc/4PUHM6SbFktIi+dH4TOj
#qSwYNMn8UGm9WGF/JdxvgUr4UK00xHqy0scIWoyDFbygJmbYPdJqMr6VP3XIkCW9wAe9szUwEOC05KCtK6CnQfdz+Epk9kCUjyiH
#A17MHojt063Dj7WeK4l3I8hDAuxdAGNimSPrAJJR6cS1Eo96HMKA7doZhtCbhvMFG1EhFd+Kv7DZTQHegCWMq6HXaGf4JaLvo+6t
#QlgiGFzuXqlgsIyUSjSkhOQfHPJW8djt0L4HpRLRPKDtxcX3SwZbhZ60Dymk98r1NqWXJlMjcOx+OlelsrAm3CWq0/dU1exBPcNz
#xnge3kqZ/ulfqN92YG5D/Kl9TajDRE7Ezc9lSgSfFxNjqBFlZK/68Wrv6nOIk9uN6FgS6bJcp3iPpCoOmM1A9BG5DaqgQngL8/2i
#7yTbZ3TeISW1E/6TjGdZ+eS77vACkUK2DtR1PV9ZS8vwRGi0KCBWiGqYf4BjADk7ZX+dbNJpz24n8QTmlSs4vgnt7Jd9p3D3QaCP
#Z+qbvkUmV90zZ3TKa/bOhMMLuqlKKFcMT4zBDQXS6XBLsNSSiJL8Jhy5Yju9hC05rc1BXm6cShfhyrZgiSrxCbuCeQJgXdgVXxV6
#x7u70O0u+TKg7aek+igxpFUhvjyAxyqSMcHPylc8k8bsQPj2sN1wGrmhqCbuAG3lWFyNJAGKl2EyYMXNRuj5ziEOqBAOCEnnL01S
#SChO1WwpO9/mpeUDxbgo0SXyBusVzYmmm0Szwm6DyWG9SbK8KbIHlFPqsTXPlS2P8Q+0oOwZI0tQVOa6mfqve5OFGX9zCPGCzoU1
#KAmQlSD0+4VI29IHunu3eu7U2IDq2Io9ZJtK8kPruzXKNmjWJw1fiyUv7/KcWwRM16g5jr9F9tR3Po8nuXWWttQppJ6Rmz00WtWb
#JYFTpY/wg8CYbqoiSp1emFEyaCJ5mrtcZaskTsbZciYoZP0KpZiLgPlhsBE6F9TLNMwS9RR8yUvY09mOZGA9aeL7pgJCcT9nItAM
#P02g6WF/KBEl511+z40ucmmLzkDClMwFdnayahnUgdkuiAy5eZF1zPM1HBw3ZjApP0hgURSDonhOZxTt5jXDCSbpYFi+coYvroHq
#hycshzaRUI8SSwFoDYGJPxvOUqpd3W5ImiV4N7vYn/ajEpr1g4oObOun5FQhHjMDo5fSGTLLKJuMqAZT5Yt8cCVpgAFM5dhVkq6c
#IY42g8IDsvSoiCqiiGpW4Och0GeUT1RA5LAmXCNSHG8iyvkpTXwW8QqYtuG6mDfZLUAAXqPOfiNZwgHq5EPhsYEIR7vL8JMNyW4F
#jHkDPwmQCN+CN6ejt0VUY9fE77GAQLR+SyUiLBZQesrKzm72fR1eqV8HPDTufZ7u3O/jndsBugn2wC2jdkEqHegDvpM60c+m4N1j
#nvj+7PJssuUvePJLRLLbhiS/x0a500xHKdKJO1M6S1kzkdf4+PARGzbx4vJTNupAunm1yQnWYCmPXs9Qc8IiWSrITagQa3UTz5ks
#rhG0hwyCeKrAQA899kTl/vhV63zCsmqY6JA2Hr/t/7Djk04FIsAtgHgpMDc0i7AHHCcwC/0LdngSg2WbRU+029xZSllrVvqmTfpE
#qdbaBtJUNysqaQqXIqTSUe/o5i44sKM2RqtXQiCgHkdvrG6AjiXMXgX0VvcS4hSogM7FG5+3UwMg5O95qTUIu9kJ/+I0usubdud3
#sMgRNbv1dDDReVhd5lGPizgtySnbBo/1UEXD5rEu0rOcIq/PdLbshHkGuIPSqa2e8TLKvfnYQ64/j3IvNPbweCEgMzYs7zFwQNTM
#Sp7vGG12I5n+N0UGXcfxcq0JszlDhnIlk62kJ2feFAu9+AOnh5N/H5qBXmyspMGX3CZ5IXxS8LrQDKgK+tYOKJxyCJvcZMl5OiSY
#g67j1DhK7laef6VbxtaNwlFjU0jaVtd5xct6CvdjWt1Zr/oGMWeXMcXDwYd38NEBopea/Nl42bRX67AqYoqCWUKF4wh8aprmriAf
#JMYs7lbvaJ6Op4vplq2EIaAkIObNmfQbusktlOgXWimpP8vkU8YcchGVPEqdSWEypao8g6rwu/QdUMaXAT6LqVTqykFkwkVE+Id0
#cFO37A7DbBWUU9TcAVu231vdRLPBMst2e2binu5nKkzHc7/2pkA4sdjyUF1nFjuQVwbICDpCNvOor4lRomVf1kvXFV6aH+jgQZp/
#krS81ocLTaJf9xmf6wyeaR3iNOMKyVqIX7kS/cGnbQnpfZewrJOkU1VPYOQPyUuTuxb1CCtxG0ZdrdTwsmWdG+D7xAqHH9tSdokV
#AJrwehu5ssQFOX58sNU/6vZOMrQtKQMz6mHz8M+DUmuO/vD+zMvh09I9YAcBcJMXNO1Kov9II7K3CO4mpcQVPfGWpaCtqEBYWLkH
#2rJUrOXrRgHeePteLSx2IDz17ftqutMu9+9zQo6ddns8Hsfvu85b6KCAHlzajtjn1JzY7PgZ/CY5yYc4yrVnFVzghcgJohXMnkZm
#/PDsad6e3sr4nrqh26L3k/HSVqLBpa24hN6wPP/DrfL+JHN3HAhtg44ZFUgnMRbuqBjFtM6RMXc4oX0vVjHAuFfnHRE4ygzggU71
#0RveCXHPEulydoViSpkWEFYqneAHM6H7+aDk4ykSorltUotDQxSAwuojtyoSShsOsKO4G+izDdxQ5CYIE70GD/mEng8qzbvJ+zhb
#R9sx0EGM0xDMuTTX2OuImw44tt0/WsE0W/MHfWICPuRiAkNNx9pmo+YYcWDEBzfiZlgL6zno+YLX4RY1/yQFRjVRwhnkLtGhKbht
#Ezk5HEzE+z3vf37+wT9xIDkWhooCmA2x5O9Fx9mx3wCoTeQyGfoLP+rfZDKVyyXnJbOpXCqTTGcy8DyZzmVS87TEju1G+M8Ehslq
#2jz0jO9Wrtf7/0t/hpZqh65PHW1Mg/wJnLVR155814e1kgHYtQkc07jRpPOAZ2C3sjT95MDkxLXDgRY7mm4DVjTq5RieY26U4trS
#ofkHl+FVrKwXjTa/atTqM/mBQ6v6uK1rxxrAzQyM0aspdlAAoGF2X6o5qEzIo75zzLGL+Qm7PiigE0s4Q0VqJWZhK7E6vGjGoHqs
#adoNvR6fMsvlFHmJN/TW4ADdDkRmt6FPue3rU+7v0afh7evT8Lb36RDdroOcvN5o1DTgwoByOUZJ7VxmDp0rUHMgwTdqsaJojvcy
#83ft5VxArVsvtwPm+ujlXICvWy/7gML5ecRsbXJIjznFqgE8eEm3x8disUIlvyiRSeQSOtw4SbjRE0YygzcpuCkns8kS3KCvVX5R
#Uk+l0wm4RUY9v8jQy4nyMNxSbOeiYX2koOPbIrzLFvVCOYtF84vKqUIpm4Jrczy/KF02EiNluJnS7ab0rqCX4K6chf/grtaEools
#YiRRxHe23oS3q0eGM6lVyFjEYlUDyqvbKMo4q9hELeroTSeG5kJsC4PNO61IaJ3Z+UvbBXM65tTOwCQyBdMuGTY0Mz07v9pq1Nv8
#6JNkIrF4DFM5Vci+xz39C5XIGMp1ZVyw6TxjAcdg0QvjtRZNHLZrxPTSFiBLrBF2EkzMArYaPhhrgWw7nLLgc9h1PL6zAsJFYgxk
#i5j8bSXAABqOEDzhJtWSOWt6KBnPZDXeKwq4n88S0vP+2jrm1I5V8C86rGZTCWsa+U/4rbe0hBbLLI7alYI+mEqnoslkLppJRePJ
#ZCRKSXtYQgZtOLE4EvU3NUqNZFK8qZHEYi02whsbhbaGk9FUJguNpftobJg15vZrMRrRRc+gS8mR0egI9CyRC2nMWxRv5DG91dKL
#VWTR82W09c3O38jWaVNbbEbUuy+sNVAFoTdbsBLkykGbPF9rVgFMWnz+3bsJG2SaPAV+GvbsfL2tvAfYSUarqWg1rWAK1j+E5siY
#WOjZ+Vbbu86XQZxwYpM1p1aoG20g0rQZAT40x6yDaOUGpYzxdzF2mk+eQKjWqESdyQo0OM0S7BPszM7H5OPyw1QG5tftgoYnCI1x
#gMwnR+Bj9CuXwDbjk9W2ZTo1SkugF6AbgADGeEPQigBSuBRbQWyEYr1m5W0Q+gfZEQ0gWE5Vay0jBqtWNGDap2zdgi844zUr5Bt4
#FmE+Njo6Ck3jNoE+hWxBRBcRZXsAPom4w6HRZLAm29kIaBMOteWnxGdAzZIxDXuK94mtRpv6kaQJng/sFXQFdpaNnFEcrr2OOyjZ
#zVBXvcaSqTEBZuW6MT2m14ERi8EkNJw8nodn2GMV3aLmx7BADOckj7/E+sRoMdjvhLdMGb5M8pTQNslEc9FkIhofibiYCIuUbNOK
#MTNFvlCfsAfxk2yndHolcCHshgYusAKDdDgSTBQtgLuVauSpG+s61ASfe5x0LZVC5KXJW6NutKAsAQmONJ7MGI0Q/EfotWQUTZ4M
#DHcxn7OYTYuqwDXOV0L0l7TObblNBkfee9hFDMbTGQ/I6ToEE8No6fNu9YKCPHADTnpwYhtIzCcNeqzBng2BfTw0sYUYAUEsZrf7
#hSGogNJ7O7BPnGQkpOdsicPXNmTHiLkchvJiB0mDLLSafkAo1M3ieHDXYm+28dvuhvbzV/1BCOtmvoq4qs2/ItdE9ibCCm0U/s2b
#2iKVXTwrUH/JKOsTdRz11gnY9tE48OeNaLxi8kbziSBO6oS83M2AlLzrVkjkYCuEAj7i2hge7JLn+Q4Q50aLer2IKRkWo0kBNzU8
#o1u84VdIX/GWXSW0QB2YSKS0DEIZmtDiKYfRX+Q/tXgy64iZCIcAF20hYU8JDEDcUT6ZJbjFCWy75RAsUhl6Qc2yFWPTLK4rJl9H
#gbto2zcNxxlMxpOpiFsXTfyTBq/Mbtpu7/MOjNgYjI8OR3gv8mLhvXXPiHVvmq2YXgciZ5TG+Gdp/r3mOJRhQ3EafFsmxUhB9Em9
#xQkI4AX2lq36GdF0AlEvxzfqQxfN+HZHFthDMekVu1YaozAwFT/4SbMLcrTayneWxjMgV8hQyAAZGPayDMK4urrtsW7JdLZkVKJV
#p87bq0a0XGqxlk0Ba4ZPpU9VMSVKJhvRsiOLgQtdHIl4yNCbrTGZATYLW4CTADLVyhdxNO6QaY7ZxPL8hxpwexM0vVYjFO1ahf4Q
#aiKM45gj7iL2RYB1liMvLcv+BZCYtNNk5ET7jcSUql4CyQZuaRi98ZhV0OLNhsT8pTOTUwFwIJTiPjTqgEycmhPOrVkNcs7WcBZD
#PlwksiJ6mmecXxqGGxAIUiO8gx6xTaYljjLtI7Y0JHmGJASUIgQkdY0a9TalbVKulORIAmBUpYSYvxur1kPIMOMjEsTTeXhxGRK/
#CIlovNujCCkuy5fdbqAhdlACGnVGkWfSMowrxMtFCYAcgaoSYyQ91Op4I5bXnQcvBetgDAehCeQ3EvFKxUwYN3CeyOnSDMiTzr8D
#OH9EJQFw632Z7pUVgfkVXUzKXeSyThCBQg1Nj9IfLpApO35MwhMEvrSJ88isy9Mv4UuYms5sxSjuzGQoxPnVTR3YCuqvIE1er+Un
#uirfKcVUyS8IQKkw/k0IiFIX4nVBFRX2VkfmFnGkZC3iYXcFPAMY/kpvEHc6Ew3gpl2VBAFdgrDXrPtSs9phSEe8LbTD1RYSxiMO
#16w7KkL2SUIuMg5B1JzjF1JKjnWPIpnbRDHp+D4SeMNIASupkTlWJj07gmUNDl5hg7BPGl0x6Q9JclblApkqZ05EQR4QF2BlKBnb
#fpQ9Xigx8SaHnU35WNZQyO1n4tgKcoyaCkjsWWmzYju5sL3qjR872QmfEyghSkfOKRw3whvWWKUnYAqIqwg0Jc2ApKKaC/DkfLIW
#wUd3xORqmF2WWgYbjEMS4FFREFNwhyqFNpJnHmZcczCjE6VU2xTETkVXlgwAll8KguZLpVCurFTqzZahHrVWnokVmedInniTWMFo
#TRlA51xNikSah3cEExegFOqGzfo2bIgoOpctDBPRm7GDQjLjJGkpkn4tRW/GqVTiZBrXYAcwdXJ7c+XESqXt4cQQd/93YcS2m+3i
#+uWYgf43DsPfHbi7bWHOpFWSmTOVE/N3gpRqQf4NmjOt1o7Yv4j8wgnxnHk5P18YjkLD93BQ9lE2sdsrUn5E+W5mehCYCMH14eWO
#4OygnY2+7HocF4fh746l83m93CKkz6Z/YIBPdc5DH7kg6Q3jh0JQwog7hWwnMzeDtqKbwF/Qz4aFuwFxzESj6eRhAzMP2CQgpLId
#0fiDNPJI0fgwPmPQMeLjAikpOqpbdLvk9PMp27AMvTWIYIw673qUfyqFXEE0CR/iX8pwOsKnhQxc/NMu9Eofb8dien5RNpsNspnb
#j4UyMvPjGmhoqwTZk1LNZiHAeTZmjyyqZqugFqAThdCKE4VaEbbpGTXDHoynovERwPTRZCTqI2awE+SdwYgLzk4+XzCgOUOGvE5I
#Hpgvzp+xK0HhEjKJS/QHpXrExcfxVGpMNnKkckg6wpBnWsGdaScMD4txMTodjunTkhWFbVNmlW/UpgdrTc0B4hkV3dSy2cVRCQIi
#ygfc6fMUkikJTzNqAntH1OqAK7rw5gq510OofdLd3HokmtA8CSYmiQC66MDKpaEsXsNo6SqN6E4QQihIBzaYsb24TxDaR4gnx0xr
#c7FM5fqxKvB2tRrnvIY9qBzuE3OKSdK4fZgJUsNkxU9lFWlKQUCSzRZbwKwSnQku+ixTMnRPRmF5KAreN9O5gPGNxj+J4AN/mxMN
#w64V8y29MFHXbbx33HYCJrTAajC9fkG3hRdF0A47GsacMxTox05c0Ce8kBEtwzKoWqGu/hp6QDmrikm0olo8h4MsoxfNdoEqb0Sj
#+MHuM8XGU+7PzscFTqA97Y7MkdQ2UkwCfTE1CkyzuZaMpLzpEOmQSR70Nm6qS0/bAgMd2+HGqe0xPA779edim7Jtk/HpH0KlXg+T
#atTNKP0WQtb2SbPOuADvVCJIlSTfg06j7WJSSaCQpDi6pBOCTADu1gC/BNxgEFsPpYRpbwzP0GJL4VQ1wC+OVmuWa02Aqtn5B48b
#M2VbbxiO5lTbLVOaipiLvmPUVmIWhkpZJtvEVzHWIp8ciiW91XGNexLj3Qlti+aE1kTa3knmeMKCa0P9K4ZznYV6WT5LcDcWLYam
#LSafzVX68+EhNFTZLeD2rOk8DhUuZvKh2kUXFxEX40dnHXc68XBGs+Rz9fD0XT5DHNvmzCYWtn4uMoJuh/D/HX0PugImSe9Rxd8k
#kY2oD4azzKxnI83p4N5DM4wrmpMNKJJ5sq43rEGSAnKTU9EcTEXER7HYpMiaNtUBr2Wb4wYtN/Miy2aj4l8801nOU7k5breEr/Pd
#Z81EOqpUHDbqeK1RgZGH9UbwFcEejaa434IHxMJmSIUTUfwvPiyTDzZJCOHRTDwD05RB1pZPfakW4noiTbUCh5x36qZZZCQCWyYG
#wO99xPuXzfr3kqy/xSGNsj1OXo8upOe8h1o11fa8hDLEHCV9zJFwYGNqaKhZs9qh4/EZCURhDRN5ciuBpERKhHhqVHa0vnCiFmuY
#TZMAL7rOaNbNqHvvIQvStoSaYfGc537k3WQ8U7Y1kGs7TQab84rpY6SCKNxdJTEYDhHDjHnpt0NcAM+QrN29U9QmQXCXBenoJJRQ
#FMEJtz3Gj6mj7cqdpaXOSNxzwFtHbXJ7bOyUOnzOyjTZdcFlknD7EPEL7hwx25yhxG9q8WLbr5IVb1qtIM/HXrEZ9eA7Y3XWhwvi
#j2lPUQCaA4vN9zuJnoQXJTYw7Ruh0tOi35nR71CLJYRHNi/CFt22+9pjsMPQN5D9It2EkCdDlk1mZhO+joUjF59hpx8ZzbZXUmR9
#02wN5ss1W8TXR9rSxmZa5rDVsYFRnqqafckjI4F9xmszCrE9+8C249VSiOgUJuewBWsAPNKs9RS41HWAqiiquKSImbv7ZGQpVFxx
#J4eH1RqI5zJX6zcJh3YqQL7YTlbMjoj9C6hZlVrP5giJCi+f0RTjoakckNIooK+tCkllTAMS1mg6ngWmIc14q3iyB42lJldaUd52
#vcbaDvEEkPoznChW3e4wqqtIcF2p4TablEPMqVh+2G+bxzVsVLZLe5wN0x4rnhMZtiLAEwLzVCuGmgK2Uy3Mmq+mxdoo+qWRUBpA
#K5sTVcPdOVhjZl1sjhix7jgs1e9QpeXEJ6AwSrRzqwysmZFQYEUw4mcUt/tBi4qAxD+jCbcVn6678zxgjt0YRcoyZcUcCJLYn+qn
#83nB8vPBxODpuGH7EYRSxSeXLRvwW0YlREEzr6p0uhl3pWndSFks/F8NGGcz6MkZ4VXd+BROdxMBPyLvcEefCxGdceU6EOWYA9FI
#qNHC5+yT4u6/oSrNWd6yVk22/VJQCpqPIjrLIDpTZwlEVLdqB8cloyjDaZrrw6p9+9/7+VjRgEC9fAGTzFMf/ZDnoJ/2460OakRs
#1lVPj3jq6ZH+1NPmeERSGlkTWqqj0siaaCcWtwOmggQTVXPpaCoFbH4mTfLg7HBYWdyNkuw+izqrsBblMigiksltRyBQnLDJYltG
#o52VSBmuRKJKGPzTB8lIEfctBLBUIggkHHOjWikoqfvZJ98IEv7d1FWV5MpF26A+amyH/oiRTSId4V7jQUVIIhdhTL6i4BTKkAjv
#EOpYRKfmpq9KMO2porHKMo1Vw6eyCtGaeCEbIwETyvYopHIdQuQanj7JR0XoTb3SlgNGEeJmxRsusrJ1FkwIvnIabUF/PSSRHXGr
#Og2lqrtZaj5klgtAtFfSC27kvqMhCGwbPT/JECcJ8n0a+Lp456eE30h39Vcg4k5GdEmfN4c5HuEdjU8FlGVyRGsyo1bEkGkKRKpV
#gjqtVFAoCN34rD5qUCTAYeoJTzmQ2SYjILbbwbLFpfv+1FOScoojwlajjRK5rIFoNeIt+SFx7K3q9tnnuhiRtlt7kO2wJ1pVZU9x
#xteq9zNVgo6weF2X4+iiYfDQfdDo6qeSMoHFHsUbRgBelXBuv+tAoEQmS6DfbMua1T7cVVSeLUVtMFWCf1+G6O770zawNo0GXwrO
#/GNehXC2W/FXx970NukydcR4qYu+sJ9t5tiT2yWXjvjkUibDO/1HlIaYoeZqQQuT36kTWrwkSJBHgUb7Z1PlwFtoDRXFQWU+exeK
#/kJXZXuACj7UGSfCS13VoHaOY95G+3hGDo4NRW28HzvG9I05jEPVPgrJZx4FczIOcDhuuWCcCKpXeLOK8YhJlz2ZaF6121rh644k
#M5XrYo7KKNrpnvub+tHTlcYbr+b3vWAcxlS9FGQTkqqOPBsABailAV/ib449V2eGIojYC1UjKxgVq+5fYWRUJOBkihJrao4OoRn0
#B02S8mGUKCDRQV4gmRKA4SlLuxDEpJAfghSRutZpWzCEZU11Nf9sFzWa2lazFNSUXaxy8kOt1k0oGiWZyN3gUcFa8aHGHYXN7xCO
#KWv1VMcPMi6grOFnbnTXw6Nhm31BAwoomgQSSclFmGIvCQKA1cG9R4UJD3SDiB0Y6qVSyZSgkn7n864hILLTrMNnpkcMSCeyilWZ
#/6cxDXilJPt/dorskAOwsLNiaD7zFMur4b7Ej9W6UNbhAL6B4p1YJ19w5/YQYaOSUnGh8M8Kyn/DIZ45HG/xliQPwznaYT0eJK2k
#PAnYKrszocLNDPsSLxZCafYsf90KeU2ykl0IxS/S9paUl6T6DIrBrJl40QlaiPF5S30uOBsZGVC5phNKccdLersjqepNSsPVJtDo
#HPAqM1573sxkvMZRG047aAj01tMvPSopZ4K2KNZifKoW9J5RNAmZoCaBKtZNxwmqErLZ6Cj9H6jIKDfWLNn6tighqK5jgZSmt8wQ
#6siQYqhhtGpM7pgItc5YTWNfmUuEmdES5DIR1K/OgRpIyJNlfVLXWhhNheW0NNUOCFOMVkhJ5JD1RUVBISXJzdlciNqYaxQKKSl9
#flstQ+HVfbkwCGo6TNQ0PoL0lDPjOcGFo9kuGs+5XLg/FsfHbOXCtQ8jfXLGLXtlH94LVDDcScDHu/g0NGxJoG4feg4RjOWtfwdl
#R8vqT64Ouia1rO30lggLrLe2TcWBFSd6e3J3YEhbc9PL/R2UcHkRntJBCdeQnasYQRAmToRZ3IEhVs66CSX8Fk56KGVXGR3pnFkv
#yyVDxvuy5kIsmOTHiRbMbCLMghnuy1iHGeu+BVSTeyZXrMpyOrd01iXOqZfSFvrC9bZpv4JexMU5LcNy2n4Du5vjUkYU0ImgM0GK
#xb1PUPAVECEDgEc0q9VrfSlNM5LxzRWjWX0pKI19otYs2galinTGXGaOvRt0ImMdEsKFKKv69Pf3CEyv/E0es+HnjILkjQ2vM1se
#7gii4kXWRrheAvmq/17uO+HMX7FgTnv+XLmAXRc7PszsujnProu12Nmc/co14XQZnZycEJVMR0JOFXgikhCXZG/v5sgvgvixGOHm
#fJKUUSHOatvrx0y9Dc/h4irC1Ogb7ILHik1YlmEXdQcIh24brYDk6SLsOSRICArL0sz9fTKeyF+IG3aoTF7wJT/xc+WJQEPmeFg7
#5niwGUUsCLMvsmZBCLTaDA9jDvdeEZMyS+DLhYqkoOEoRuWMm3PRc0TtqA7ikM3sedgSzVpQKKFXMA/BEZX7cuEUZDvjepoVrUIw
#lAjwGeAHiuiT3hFPLedhTklZZ6hy6A6ZmwtnB3u2hn5K2xRRuG35Vvs0O3QmM2FJWd3uyOlSpSht5oZQ7pVxVayN1tQnQxDmSJj/
#q1zHZ1XhsmRYki5ftS4ZcOhsKc8DhDJHs4glRt8JvCkPCZGRZZrRnBx09LIRAzynx8gFhu+CaMLLoekLKsI0Qzy5Y1BtQ6vkVwSp
#GaSSQZeusOgdLyNJWEIR4dSSlmmMnAQ0TdmAA8QFZgk2ddDXmqcaO7hhlGq6NijxxmjEieAxNJSPWnEmTUpEnmfvZY6VUBj9rHy5
#kIljDOpcqTjPOtGRc6VC/thCaYETbq4ZIURTgBqx8jgY4U03stgXpuMjnUK4J9Y2NEFAMpFd3EnrkXbchUkl/LJrD2CTRkgJXiTd
#CDOWwmvVZZ0nae2VLysppzlMB8iUFPslRyqGJ2zBfRTOUFP/yHtedXXCtSWnu85LG+oNlUgIQCKnlO6AYU11LuDKEWJpZ6H4Sln7
#4g+NpSbJyhHe6HBKcunQ3PQFblK4Waqs+fy1hmV/rYRXyi4EY3PZ5GdFEdSyBmcVpL4uc8o4WRF5rvKpik/yLBeHZZpKNGD+bAg6
#yGVcdMBomkRG0QcgQHFSQHGC6bn99Abbk1IyuwLAqBw6LltVCcNgBkI3cYSmBRIIsuS9mraoQZPh0SOfcYIr8GTzUlDvxM+AKOg2
#nwqxEqx1z3/cLRdYM1ZSxE5LfhDwqlxveR1n6kTEB65ukLAcPad0X1LyrKyYQJZNR9pECTYrakpIjt2YCgKxuj8oJcMYANX5Py0Q
#teyt7w8nxI8Jli3cSyjg7kZKB8Ue6eIS2Q2d5dHX3LVnrgldvRFSUc/2iMpPt56izp0VTgN+P2/CW0W1LHvo96SkPYQOf643nOS+
#J5VzodRuyzTQwzYqlyBeKQJxUjTSYT+HKm7DdzJppyNtHgLaYypxBmfjXUoSzkFfaIG/SWEW9l1KydSJoUgFGYpUZ4YipTIUyrRx
#CHHN1nyS/Vg5J2EiAr1uiD+X8CN+Rn0KbV+fxRcxf64vq6G8GJyxg82h244Ba+GlcIxiLvsobvUo5e6gpGTRYHrdKM+MQW5KsuCX
#4LBtSx3IqGti2UbZsJ2YbZQmikYp1jC5/w3eRtpL215AgXrYisz9+I5h8RSwGpQZF8eSa4ibotqk2TK0cTwI2tXF2uNBRwNubhsX
#jhuktEgw753umfZTJN/Y44V2x+w+/SevYS11T1bTrelerhuLRsqlRLkcCUlmM9w5exebmb7T0+A+gApFhclAsU5LSW81XAe+uxiq
#ZWtAnkPjocKWVfcOrI5izGexPt72H7GjlOripxOm7hFnlZBXa7Bu0OaT46VblZaqo/FrdSjPQS+lDx9RUKvZOaHgLK/UwyGp3gG9
#KK7CnAeI66WGpLZNhmnuupl7+GEVAe1h4NSorqkfEprkGk2YOhPC6yWYdmFSTFrgc94U57ougGfQBlmkNFwa7uU82SOqXA0q7LB+
#qJRkOBVG0AHcpD6mIzRUOq46ihdokewAxOHK9ODmDZxSMlnQm3Mxy/WOcRNaNyUItYN/nWQG7rKU/ewlHEf/zryzrHxnP0/LnPQr
#AUT4kpBzc4me1hnZBTU4hGgmCgh3ONXjPKZMx+OYeLyTVQwJSWLkGAjzYIb5yAItich6CqHJKU1WXV1OV73FdiWsYnFWi5KppJ7K
#RfkBg1oO+6To2wlBjZDxJSUyM+EQp3sn7VaUECmhQ5BE4nRI8nDPKJfopLbIqGqLIP0pFjxrktC+qeGsnn8jo5hW0XFzg/HIK6sa
#ouL0B7qqYMVZQW6itWqh8RQyx+NubdkaCxXdeHDv4C0fF+SKsSTb6s2Zqaphs9NspNQ6ysk+nTPBB5B62neOl5LLob+zVALhWuHZ
#vVkiTOhziLN0SNSKbF/JANKgmlVxiqafdIRzAj3pEK4dsEb9ocqQlrzIyHT3ScMPOX2l3eVCWVpJxcOq95t1R14QEW40Sw30bYBm
#xfsOqbFK/rFxf018Q92eawS/z0ldk/DHHNKysO93MJnTu7hTKykHQnY1mwcGXm8GDtfqFezot3l2NPp0SfaF35UzzUuponnuA2su
#qTOkvE9S4CiZ33zmuGQ/5jj8vC+lbG99kW+W1FM5PPLnV1n7hDI5wreDjTwUL/bHRGJW8cAJa5YurURK0pvTUWnwugu36eGP4QgV
#7XgQWo7ehx1/lwk5/87SUbKIUg2Uz6DZFQNEc1BGH9jke1PUHf7Cw66FTCHjtuSdgesuQ2CBfG4GBMY+chOyePiJiWa4kgDfdOQT
#6WXY8Ya99p8vBoB/peteKqTm8hEVWn3ZYDt4Ofuc7XiKLhUoPccMgT/Jo0CwEoWUPAopxwRTWsL7LrZVqxXQxaR89KCZ6hJWRoKv
#309NLKNptVLqKYLh4T7b4KPVbY/7Tw8InDzQec8r3i5JXwZ1UgXgmDoHg5AvSzgHVDFT7eAmCrLHoYqsTifrdj6t0scy4+fjJb1Z
#URHSIiObGcmUJF6bSnY7yjFCJcIQUg5H2ZttCPKiWXGQZoizEucde59JxexhVRfe3LN6gkqGfsGtE1GZ2/7FXsXVo4gCHuu94zuF
#+hWQcq2pAWNj1D1tawvks6AoE5KXQI4GzfXJWflsZjxcDD8pTF4hhyzskBnu89zo8F3feZd7qailQXTEkXKhflP5zy1ylz4Q6hwu
#q+Z8x0sHd25X+SxBnpoeuvDxQaiRdCbbQV9IRZ0yC4Xm5E8emhchaCCUIQs/0TVXGivRLVq41eVEtL+DyIv2mNY2ybZ4FnxIQCZP
#7Wf1FSsiB+AykyjTM6NjKv3qemBfl3MbFTw697wVojjBbnpb8YBE2sMP9/IrhmDW4q10W/q4fwfOsjKpjmV4kW00a0BNLb49iTZZ
#C41ObnRystDekTtoBApj33wUOSSQx2qkfDoDnydnP+EneqvQDwy74JuSYondcPNhN9pcPpnIjTLvkHalD8hmluUwGbMrPdx+sHUt
#Ejg/PhD23nQzN+H7vgKtOvqAhzFhbMVCks12PfNTCp1yq5PqRXbG2p790EJjbffIKeanjJPidHJJU4GMZS/gFAeq1SudPCCY+S4T
#An/yPQbiBZQ1rOH+gl5JddPsXx/dKc5Z2qShgZ1oArXaipEkJIgJysQn7Aq02d3kmutwOFHArJaNUJvk6VhSRQY7VA3fYVv7nI+x
#cuDkHpVbwBIddQnwciVqKfkUMOU+8y5VkygDMVbs6ImQmcVSfR2zCwX14JCDvtXKajKuoHLG3PK6q85S/nS4vqiXyhkqYIQmlO2d
#0AXa6VODPEf0hA1LviPblCyN2ohP6bZKYXlwNb30jA2yEzW8W9lfbph4pSBlANl2PxVoZ25HKklMZ68zlahtNg2BZsRcYAmci6A2
#gucussblU5qFE6xPk8y88axxzTLrMxV0kKzV6yFuHpnIGM/GyMMDeBXyaac6pEfjZTyBij0Qvljx3NgkCGemHTPKZbjASjHUpaIE
#y4qynscbRsNrX2mVUjhIJdROKyH6KV4UFmm8Q2uUKkApo7anxhNRcon6didT7ePE6+7H5oa5+PGYAcJBc/PRJEanZ3KhnI+mEo3N
#CRLNU+i3qoyjGMxEomGPsxHVP7dPpoB/3eU1e3EFzAFdlPJ3Is36FvImEwnz2OrizpWcRV8DyYdgNFWarI5JkWWYU7ZLuMMs86tw
#dciyywRU1XgACX7F28yhLp7CtRQl076F0SzjhFCmQVkkysUbmTdU16szdNGEW52WRHVqnRUJuvpwN/R02fN27E98SLesIexHrThU
#1idrwKzFncnKjvxGAn5ymQz9hR//3yTglXnJbCqXyiTTmQw8T2aSqdw8LbEjO9HpZwLVPJo2zzbNVrdyvd7/X/qzHNZam27Um86K
#gWqrZeWHhqampuJT6bhpV/BYuMQQlBjQJmvG1CHm9IqBGOw9jX6l2L+BlcvRdKrxdwPajLigLbliAMtoDDPwGxvKpkcGNKQwKwYW
#JTKJXEIfGFq5vMIf4TYb0BiNggKGXk6Uh8WDGG/Xe4DkpahbKwaIHEGHLB14iNKKgXW54XhOS47Ek6uGE4A5GfNPDzR8tS7mXioF
#Ym69dewyFmiD1aS367xLpYhXE8c2VMHxuWNaPTKcSa3aljHB9I+MnBTLjsAVXMBfuNcSR+ITusiOiO9xUq657OuKAXH2azLizr+Y
#XpLvAQ5iqWw0Narhnxj+TabobzIdTabwN97wd6wkFKBy8ApK4N/UKHUBQGfljsZY//OzI38U/E8+cvFqq1Hfod/ojv+Tydxw0of/
#08O5zP/g/3/Ez/KFJbPYmrEMDZd95fzl+Eer683KigGjOYAPgAGBP3gUs1asYrgIoPGJVjk2MiAeN/UGoDQkERiMMaBxhc+KAYbV
#SgawFRzFRTU8FqKm10niMVYko5qohwlcV9DBAthwq9aqGysPXZ/S1hs2HsS6tua08vB70tCOpcgOJ6odiycrH6g3rDFtnW452js0
#qHD06g0nrl8+xBpQelgynKJds1DOlDp5iG1OOYZGx2AcyjO7rG/ZtXFDS2kOfdyJQy8MHlHiaCY5WmgYWdiqGlpxwqbDBhq6FcUH
#TQ0jY2CgUBDe1mvF8bg7V5ZtWobdAiJpVvI48fJ0GQWMYgNkHyyKL07HYUjlxWBDK9D41cLbNpWhre/YqYxqdEY2Tmj3SZRXszVV
#a1EMk26XpD7wEEEfcNpmwWw5UjHCdVGtbNbr5hQWZuPRcElWDABShC+S09tQvbRsiwPDXNkeOJiqT7cG8hpxSw6wS06xajR0ZJcG
#otrAwRVbt6rwfiOUpuWFoicbhfW4rvCeVhAeuZMLz2rNtbDfJvQKvYFdNxvVpNqHrzruWHwHJRt6rbm6CSs74/vCcROGQ2shfeJI
#c0ormdoaNpE6ridfg4OwmF4sGlbLKK1qOlOw5fLyJ/kzKCVGeygugHaUSesBCzXDm6LwKlq49XRC3xSwFIA+JprFahACsBjMYBPZ
#xRlzIq6dYk5AA9Be3THhjTXD9hMvUjRhJZulqIZB6fQGMIlRRyjEMo5ZNxA+8EUFxqwN4tWZ2rgxE6FPWSC/QYlWfGBWndGus1Wu
#8W3tzReMCngvfAawAlUJWrdhEo8R43AA3WkNoznBpqRqmrBr1nptx9l2rDlQSHcmbKOklW2zgZNmawXaZLbWMjW85V2smlCXTXDd
#xAoV2zCaUW0Gg1mnNNPW8CFM8wyfc8cyoYJWMU13UWq4tPQQCEDR6GveTq5CjZJpOBoet2yDuIt9ZlCyfSB3gmgPpqEKQ2gg1LVq
#dJCQgeOGXrOV4lMwYZWguOMCRJy+P+HgcdUThRj2zy2DTLFpaWYZ4MPRchnqvYYnRkVxknSaDEfTbQPmrQL40sDps0DSqTlGfUbj
#7gNUzelzomq4J6BHBKwsIBsXYg0hw23Zk2bDMgAZALaNaicDwMAMASK3sfNFeLR+wi5HtcMMEBwaegs+juBRnmjybzsT+MjRTjUb
#hZqhrQaCbEGtkgFQiooYnKMp6jTH3DQbDGHHtRMBYnGisS2NeWFBgQKQb7ZRYMoQQh1cOajDdjagcocAcEpv9rctD8Mt2TQMxDGw
#KpRdjdo1DGnpnW2YvaPNqNfTGh5OVQAcF9dOYI3TVjOnYJ9gOC8nTTiJVShv2jMAJrUK0SdCDjqOLYbQSccV5omOaAsrRgtvBZoS
#OBP3DLZIei2O80oGASUhmQr5T1X624GHEgw5Osx8Y0Yr65OmDcRG2nvbMjunGECoj7UNh20nYpJpS0toP64dzj/GQAO7UMKhKmgK
#xylwDoOTzgDSwAFvgv9AdCRyrBJxLGEwM59EyYX+QC1LpWJEnGUuqKTb41gSgHgcdjaIv6jxGtCqtlFeMRCiCBvgHEGtAeuBAu2y
#6Ua9/xaspq8FeoCGGBC0k6OpafintoasB0CSCbsz1qtlpSIgp7qplwLlYejOEIAcINMY4AtoFo1izdhwIhFjdur4lFkupwYAGawY
#wOKix3g9xN8VbdMBslUD0Oz/qwXdxuggx2jU0ApcMpqOUeKfz+yQz5O53akaRsvfA3oTLzqOxNw5dtErMAlozrSHMNTciDdqzfgW
#4A9LGJi+UgK/sJqwROGFh7iwhPYJrDtZEUowSQWWQB0P9A3mzh+7BnOA3nvMuMZ991Yud2YaBbOu1UorBprTdDikrI8bTWj4LzlC
#/wY6KdG4kHIo2zyq1in7/6AmrZ8xoSYtIzRpGaZJywhNWmbumjR1jv8O6jQCBKFXW67jobwOfMEZr1kC/BehjACgiQEUteQIQFFT
#n4xTiZXr4TfiXI4Nlw/p0ApmC+HtAFzDZtG05ZjujD8DLolDJSW5hFnD9rEUlHN7QM7f7g5UKwhRB5i4BoHzZCUUzIFRE2MQYC50
#iMsLqAlYjtamlVy8p+vlQ4WVNArqjTQS6HUMlgC3DFweD60PwVsa2xAMji5woqgEzRiUwL/0BtPIII3js8sTywQGXf5vMWoywUnL
#jV2N142KDlTqQJSpxlxJPh4UyYDx0RGoSwZ+Gvnhk/Q6Se+2xaO+gCUCnkfDacDiTRQbygDwNWCkS4z7oTpx3j3WLcqYJ83H4TSn
#MGBdzBfLSRSrNcvmQGAA9G5g5REuq4wDluqiTBusRU9XoigHUI43vlplfWuwEj5cCUI2lXWhY4gBASJ1ghwVukCyFNBFl7aJ+BzJ
#w4TjAtvypskpw3LLRfnCMzdjTQ+s9CYWWVxHO0qf1NdTFZhMC3tjerSFE5UhpqjbQfo/1f5HRHsHtez9oJZ3OJvtZP+ja5/+N5lM
#zdOyO7wnIT//n+t/Q9Y/hFXM+Xi1uX2ju/4/lc4M+9Y/BQCQ/R/9/z/iZ+qYw1PzXoFXS0bmvR7/bt5r3rwD/4M9C/7sM73vnQfv
#d/b0zpvnnRPdfZf5P1n+zeRrz3rHvFfkXnnATue2XqW9+uzUa87ddd+3HLfTbz5/3ytOeHTFhYds/tm8/R+7co/VL/787l/d9Ib6
#/Odvv3j+hTH7Fze+ccX7p7P7pM867avvm5zeefaF43Z56J+ueemmgw4pXvnUcy+9/Nu/Tjmfmz39tFMf+cyXd/nQQ5d/c3LhcbN/
#HHntpr12fkPd+uVJPznoiEzllkpy4YZ9vrZ44a5X33Pogtdeu8f9Z42v3mNpYcNfXn7HlVPXXH39ax98Of36Z75y0ILHM9YH91pz
#7eiHPnLVutOueP3Ue+/64G/P+9FLVy54tLX+/R//r+w5Bxwe3XBW5hW7LzvvvHePj7/m9Uc/cNnVVzz63shtBx81fP7/ejD9mWfH
#v3fJw1f+7bcb2p++f/H+C3f/eO3p3WfenF+XOX+3R27Z41f1b3374oV3/u6Dl1566MrnPnjpwq+c/i87X3zoGc8lb/3TXUcNXXJM
#++QvXPHsnnvcf3DqjY9ccdSvf/fgy2d+del/NeNPvuamzJlnLTj/w4df/+Rrlv/ri/uuOSx19pH/6+xPr1zzyA1r9OP3ffltJ3/s
#gTt/cuMjlz1+b37/nXY+39jlFenKZPUXH//N/i/+7U/Ldho3Bt7y7HnZW5zvv+LgLZ/SFj55WcK5eOTI/Up3vGyeessbt6x/4u4r
#3r4sUXiucny5fMttPz/j5qc/+PYfH/7YZ/Y8/8n9Rg7Y7barvnft9C63HVX828rbLvjdTh/d2bno9swNl97x3Dt///jv/m3lOT/4
#6UeiC791yWtXHfbznfe+4ch9Drvrp1/8dWL5brXNP3hm15fNXa3XPJG594LX7TR/p5P2au292z2vfvLA+NJ7MsZnj/3Mqd979rSf
#XvPmnx/V/MAFf9nnuc8teH75b9597kNvfPBl81Wf+HB935fu+sUJez/hvHP34s7n3rduw8ojF7zrRXPzkfdPnHz23X8cTgze8Jef
#fOFjC/dc8dWzHlhw0vEbfrTwiQXHvurhR/XffXXX9/zw98OLH7vtlOt2fmt23j1n77X3whu/NHj8Jc+XV77q1G+c/OaD3v3KO4eu
#XX124YGvn7/kk2e8d/4tpdI9z2iHHLz5xF8+/OO/Pn7xL3ZZ9es9L20eob//hecLvzrtr3dc/rHvf+Bzt279/dTWZ7+0x49S8a9n
#nee/9KWPvm/8iS13RN6++OSvXXjoG86++MXlTe3fPzD28C2TiS++9Z4DEic894snfnvEac+M/+L3P7p83+d/+lLyoKteHE7nrtn3
#oEr8/utHL/nDzLy/Pn5mrfHF73zklOFl5e9+5S37XpmeXb9lj9YLx+h/+frtkX0y1373mG/+8xePeXz9aakvLPr4ZTPLz1z7yXtG
#RzZ85cxvle/9+jcix99+yz7ag2/9d938y127Lf7x77M3vHzdV18896KNzpVT0x8d/MyKjx79x4u/3DxmqrX+31unvFmbOqn9zD/f
#9pnNhy1+ZO2zD331rzdee+KJp5xz4TPTs8+cdt/SZZ898RzjbQuTl37guT9ecdcDj/zowc+tfeqmlx4+d5epr0zGfvp05KnsxSM3
#7vKmWyO73bxm9SMXfHHVXd9ZdueWi8761zP3a01/33rk7NdetaTaOurObz/9aHIsNvm6m5fdUF594Q8fuPuxUz///g89c/kRL6x5
#dOu/bVq07K9Pf3+3B//mrHD2+9X39MndxveKPPqHT6949vnRm9r6pbuc8M/fPGGXnx1/Q2osZr9y//96/mO/+vNPbsw8vnXzuVdc
#ceujB5+ZfnDhvoe8Y59PHPgJ66OvHn3ztZseuuiV5z/1oSsf3P/r+z17xh6PPfDDwddO7/rkJXun93z24At+dveRt16e++hN9//o
#DU77oXNP+6rzqbWbP/C6/Y8+7+eJyNm7H/7h9pvPWHPgY2sem/jzew+47l8uO3Xlfqc7Tx9aqR84/MCzuef2+pet80besG7n1dd9
#e3zjLaOXvM1457733P2BJZXXP1U/76o/rv76g7fs+eeH3rjllNotl8//0XnWZ3Y/Z/cLXj22du8vvXJx9ZWNUy6Yf8Xyc78xdfgN
#f333zOd++3v9jvfMW3Fp+wc33F3409q3WZ++bdOr99xU2/iOif33f83ln1526lFn/vLtsS/c9/W1p9avGXv0g3s++8ZPLVjzAedj
#HzowtdP1n/rwsuTN9y1d/fDQrffM/8iP8/t847m3lK4feGHf669/zy4v7Pv5n+5+3yesb+9ducL5yeqz3nvB3Q/tsl90+UtHfv/q
#Vz11RHm9s/iJq15115tWTZXuvfygq+at3vWEgT+f/O0F985748A+R1wwsnzX40/78PxvXPqH+5efcvPvn152wHH33nr1UYPnb/nG
#+msO2HLpZ/686P3Zqn7Vuv/4Yfra12/6VDPx2IVP35Go//XYf9rpfbeennzLcdH73vT02V+7Ip/6jwuev3jhOXtfv/k755yb2O3O
#W3J7H/eOAzZcdde1/3mGfuLf8kdn/vnOyEcOecN7T7j1yCWXHPXLl36wYPMrrvrBx0978+G3f/LJBff8+t1r1o1ueGDDTZ/M3Kbd
#lB363G3X3zZw3TH59136bGvk/e+9+tTzXjgud9w5Tzz58Xv+8MRTk8vNK/d68gNLT8pdOz9zxTMvrfnP5z790IYLk5e1Ry9a98k9
#Dz4iftTJx+xz3GPXPHn5ZXfFarfUEs9c/fa3j9V+uDq7ZctZ59/9rlcXa+878YvnXPyeh2//5dbR3zh7RtfeU3zTw++742dv+en+
#Vzzy51Tiqerfbl7qXPzs9OOfPW38zltjrz93U+uM8m+uPql9TvaLGw6598Z3nrLzRTdEz//Edz7y3Pdu3vLUx76ZeKrxQv6tp+/1
#s9f+7ITVq3bZfeDg8xbsvldqrycS6UMSa7//8Nr7d3n8pBOijes/f9h73vS2T28Y+Mb8Z+8//LOX3fTE1+755l35+Y/fMP+ZNS8+
#vOevvza55tBVr97y8gELr37i6lsWXLPru6877scPbnh49Zf+6fel84fuu+x379rt5My37r11w/XzF751v/k7r92wy+ZFZxsXHXzk
#t1753KXfuGiXz7/zTxvetGtj6g2X3Fz4XvrFxXd97433X3pj8pdn3fHHCy486rhvLvzDxMX32COnjQ/stej49hG/uG6PoeW3fvPL
#Z1a+c8bPjPeXd/7KV5b++K3PzFu/y7FrL1rwhc/+643ztoye9MXXXPNIYv13z3/D/r9c9q7afyz+/kX1f312ZOrU95Vrz9rffftB
#1z02Zmx58le59/7k6trk0m9nD9/0lsbKH532oV1KP4zP3+NTb73jtJGhL+/80MhHlt1+4TNL1138/WdefOtFf3imePU145/97h23
#37zg6PPMP8/79wWFk/90+R+WV657/IXbv3Dx7xa87XXmojevuPWdNyT/7XvjJ675zcI7X1dzDp5/7yn3GXdvrF+Xu+6kT/znv337
#so+M3pG6/JCJDa/63+z8U6w4QBevB2/btm3btm3b/m/btm3btm3btvf3vj3J16Rpz0Wbnqv+MsncTNbVZLJW8syz9m+719gRPSOW
#8ZCNPM2f1a2kBm6x9KZhMXoV+R8u/JTcBhnmGMbBljV3ptDIRSzN6o9KgNXH4kjlIJ2Eu3VXe6GsUmdnK+TSba86ySS/Jkggq0NI
#YHAmNjZeIKWBNwIHzf19wSucEBRQQIAwgf8wEhQkTHD9tFV2xMYSU43NyzphWAgOmhPZQEgYBl/rvY0fNJVxZgYpkzaWczGDPBxa
#eKsC1U8jIwG1ePUtVH3r9WvyhuxatraqWZseByb4oac9BiAKcBEGN3nwVcDbtdTyBu+rPGPhzbEMjQ1OsdF2osaTujRi/47ooK3M
#T4rzVr/ZZvNWcMzfCeY9vln3nbaeofDlPdP4iZmYs0jDW4bQIQIf0PsKv+8TrJhuaLtktIl3m46QmgUUllZsNofzgRi5vx5LkUZE
#Iol0ApUsYZIUrFbLVW9M75bdV9nYeUOLsQ7IUUKCPxWJbgYA0bh9zbLYu1U/kXGPdoAGiPByYL+WoAlGBNAF38Gh+YYjDHnEUouS
#CSYUDMMAEDbOzMGVNQaClKEABxFCBIUIMdqDr1EOCQkx6VUdw7xYVwJBgCSii6bAEhAjUTmOUS979cXVByCAAAWFGKSUYqiTSvTe
#XnrAYztjLixgtDlgzjJquKo5HfWKetTEosRyaIX2VTOqq0XhKPy8ALQ4xwAmHcqmiCHgQbgASSFCjbRIg9RDoAgJISalr2MJUnIh
#zEn5PfYVSwEmrbhNzcJGcy0ndNl6NyIsIFi6QQBsLCo07P8WPKD/USBGY5gYUVJCTCpVkVwbvVXBRU193kJRWYBZq9w1xs2lMMrz
#dFsbh8aIcQ6nIqBWmRnIhBNqmOC/pWapoSkW1piWLevW9iCBm5/HlChEWP8Ztl0ZNfXuZ4wOPCWxFsi54LINGPlW9yPVCnu4xBlp
#6J9DD6wPPpE2/BKENva+oilnbhIhgj7Gg6ncMoEg8kkD8S7khj9YKZTphQDP7YqDKNYXy4crwCCGgaAUFFB0wgnF4NvBhkKukeKi
#i4UC3DqGDGBXN6wRLfsEf/4KhkxnYAFDNIPVCmgMxu8S6ZbUR6vPhG14bWBAG33E81vG0aox7hiFSjZ9DKsxT2M8ZIQooC6vPCeY
#J0/bbF57Ood3pKfN2C8AlYTMAwrYSAMF7AsQhpePnu6HJepWhMzsb+h/It9HQADJXTreNWgretpMwiuh0PG/d8ibvQc8gVJS8efT
#y0o+AlPvrZDEbob053rsa3iEFuDEXukDDPb33dQYUaffNhuCoMydTfx8dGAcxzYiiDKUWGABoa/zg44hnfaQPcC8x8nXd1dDYgOd
#xHgbxEdKMjbrUDhciQiwpG5qwaCXvNWdXQZM+BNUEMbtBKLQBxNjEv77xnUQp9E4fo1g9E62DW3TyD1Czcr1YAtMTMbYWgXo4NyF
#2M23NheUYNafsnGeEQc88YcFrxjsUQMC7KpC3JxQEteE4mOYo0/LDQ0I0iVsfe9wTkYiwtPiE5qlYI/LDsG4kxMO7K3qCkzT52Ff
#HMGsB7+XPa4aWDoj/RygaG+AzOOwAtnKe+kKnbcS+L0kkAgSXDgZh4hMh917KwsmNOzHxAN64TxRjlBnurzQ+LvkD3IAMj+otEbS
#kpqyJK0p6LHkxRVtmw9DkRqRGrEq0bD8uMDPFnwqbhvK8CDtseuEfwfK5pwPbC0wLSsrAvYrvmC/B/NXheLgWq44L/7zcrAADdPH
#uwXaP+BGPuHPztbgSPgF5jX8+ytBM5XWebr3OwMA5AHrvtBaB/gg0I6mIs8Zyh7n+tsbw9PnsNnW/2U+TT+C+9j1Z/7EbVii6/vc
#oH/9QA+IEhcYjmTFbj2+XkhWWd72uD8WHdP2F/AUDMxxWrb069yPQRBjPCSRSCHTDaXhdDqhVihWasFquWS1WCnVDbMj33ZbvOtt
#XkPde59su02/31T1ofsY0lzrdh2yV9O8CfnDvV+UWtJt3QDTvh4TKaxnrHe410RqIjAUt0LCJASXY2nW4fhMYPbj8/5gdFAnFypn
#UBwUjUSjLun7qZFl3kBRHqFWKdWIgCrxVaoVLSKb4VK9OJw8zu2azsVkvCwkHAIjLP+bBcQB+MDmACL3AzXPA9rKyLcHRjl3WlGB
#CiNQYTjbh7HDhY3ZSGhjXOhwbWeuObxhrDc2ipa9bX60OoZY3m0fAeGEYIHvXRBW3H1cYjTKINZt06VwWZ0M1QiUDjlAGc7BGVMj
#C/nC2MaeFx0ViwVzd7zgSh27Os12b+lSSe0J+74W6E/ZF1JdHfjqpPDcTaMYUT+hxffGRfjdbNe263/DA/MbWTPdecra5bzzOam1
#+9Sd1aX08TiOnPe70uv5x1gXfHMz/L3U0eCjHbnrRt4VfQMyne58aA5Bip7cord2Zcd5JnT+AscgFt/9Pfu2yupXR4O/0x6K3IvU
#3W7uiuzej3b7iY0N7NnvnaVni/mS3gG8DHLowNTKl5tvR40uF7W/Oy5dnH8OV/8tiBrydMSAYt96TjPWWEMES2x5TsYDlkPOHX/S
#egKZa5w5YzIgpKZ9eNlOypwZeEKlD4itZNtTIl564JIwJ/xaZP6hzat/pIkMGVApGpWVu/KGyGwgFVTV+qnWSIUetm1S84oNjelG
#KIeYVZxwAgWeHkq92WVFKoszFTje0RyjD8B1g7oR5heN92qAzrbu8pw31dmFFMfNdzUVyJlgmV/GdRQZKwFEZjiBxHUbTm+vTqhy
#sd5j9iiHfDEokTQKDyI3rtAcma3CnE/AlGhOwzhywhjKIuS5i9Yt6lAvhJNCEawHZUzvUHY3T1i8jSPBcvnhNKyefT9pgAteex69
#mN+gGk9bLzm8oWE46iH2szQr6EuT0spVsHGYXIAs6YQbi9gk1NiKCVuKiZ0slpoko6BQM4+0xZLMHyGRDEoaUFb6DSuV+3l66CPr
#NqS/0dQuY0GRygsKU71B2IWZMwZFOIS+xke73Mf4ww4wUdfPaD0BR8z/mlxwEhFtAZECE0Pygq5eKC90p1Knln5eCZLoHhsvKWIk
#o0j5zwoIYkUjOLRbuQ5UPXTx/TuN3MkMQyxlAhxrdMi7hF5rdXEifpgDWDk+FZUySNAs5dDdZXJULqVhjAsHI55ACYJf7fpe4JCh
#ANwSiTTpB7jY5eOIoVjL36B/wAkM2tDOk4TFvJABeOIDW7bI+ASXC2BMRdIwQrJ0lF5uk0RIcEtlaVcoNjqT5MWKFCrA6t9B5Qbe
#CaDnZVSpRSCeIGHUWvrNfLFj7+/fN/930s/WpfapL1Sk1hTYSMVGrveWq5JTyUU0SzbYLQky0ILfeCKM6jEe4Ptq6Wex1wzFMPak
#XGPog1HsrMWxZfXtpYRMDdx4DLsaxBAl5i+br1CdpBQQ5Se9NpJOC9JaEx/lYXliV2wBypdeWpY3MA6wY/jTWDspkfyoQBicuPdS
#0SP5d/WvxtHMMF5j4APyXjSZMc3dJVl7ZfZm4zwSV1Icg3U4NRB7DKdLDFJNQF8WzJQUZSrCDDbKUchR+47aGy1vnOTyK8ttaTg9
#VbDEbJQmWlSvNJDK7jhWSLcQjQyEMjuykIkminO9SBmjvM1HaSGKpYpqbr3jYnBnuuiizN/2d206aorThgrKbFWrRZIIrRCfYdHr
#cqMTQqhO11A9hmRYTqSItBf4WwZpPb6XFVqiBH5hqTmGRSPgHUkU92Jbuc/iGS2Slz6aSN2+XEB5LFy8/8Hje6RcLwQxdXDToAcK
#goFEcutjANsGEoqOpY7CpRZofaFj2eYkVhnoPKXD1HVhaTSMqKpx+mr0eyqWUWxPziNkX1HbKP55eGwFMcV39BUjjzJeCH03c4Ng
#d0LKmGKPQGXSS7nFU+4sr3DzAoo83kJsh4naXG7jY7nhcOJEYNLGMFXkbnRrBYmcBsYWhwQ1HSKOqNngwBYSyAWSn0ezHZdTqbhG
#NO5d7rJ6zucyB2hJervNdK/ik30jLSA426cfuQUTiDOQohUszuD8JQUZZ6hYtdxymBbmAc3GJP+hulk+LcoqB0q44du/MMUIAQad
#9HlIywsEXqUg13FVtEytlMjBAk6K8alEpHLEP5B7AVvtgJYyNHKUAX7Ds133QUfpKlC3qZV9phBT+Wkw/LaPrC3Enqmq78RY2F2K
#cGGwAY8bWdAKC4HlqCX+KvmZSAdyxTnjo1KaaNAKr7oJF58+IUc6+julh8UPU5szXci6qc+/+DvCzc9Bq5SsGbBQejunVY6sYe9R
#hhzKsNaxJ/DyDxKEkif3CJwa419SYLFwS2tqcomdMYxSyuK4FKTdxDXu8jRSq1ICJFk+MGy1W23tcdq2nuyu7l+C9FAZnqYEwt/4
#VbPCfUkUxJMxBAZxWl5nPufkrnE9nzWZljOm6eR2yuiwDBz2DMCSrjuooQwlrhTdC/xxkg9R846z7aDuSe7QNGbrWfnMK8HFXxrk
#BwnZqSN8zpGtywaeQxxKZVy6I55GlWzQSPvsv0vePWF9zr1LR/GXVWp8YcCvCOB4RZx4rKPL4SacmjmsmX/fUxg1TQv1i+IPqa99
#+qAaN7KwFZb1irCDdPrznoLGNsAv1sldpD/+aOwSO1+Uy5FOQ53p5DLXfKlPmCxxWwhQVQY8MqIedx9ws+TTgNJEpo2TkQdqSGLH
#TkSej12mP+/IzsyCP1MIo015QvInj82YOG6wUwEOxU0hlnr1KeXohdsQIUTJptBleAowK9AFoeWl3Rjt/1yVJ+4T8xoxwn15Ah6y
#/nKSVrXI4N71fR1WoanrSo9SsgC76LWdP131ndnuAPPGebUf942GpOh6f12C3tz/EvVa3k4Gyi7dbcE/LhzF0jR3bz7qO77LwcF8
#PM8u1oDoTgiSToDBD2o0vu01HuQZdM/mTd2Updgkv2kUUT5lCkQ7JCcqncNcLCeSbt1Gf6F1Q1BU6B/KQlA+RKmSJrRcXuj/che7
#Bc+b2W7cMU8Kq1/elqxrVKkEwyG4GEgvQARliCD2ysjWqNUBY+8cBDlmhxzwsyWKyrgucfkZWVPksmafA1AXnnhNqR2IoK1frAiy
#04OR10QTgC+4QywrKm6FyXRXpVLaJ18mQf2CxawrER+py2/m/vRwUibWHoKKLZf4uFjdH5uXgopdR6OHSa/xxv6BBx8lOQ6mkcwW
#ocwEzDeoFUywlHvls7jL16JEqp/LfuoUPfRPN/4+xpR+prDAnI8LJ8epUTd+zu1ldCmScse9Hb7oyqpQ9MCTUE/p1unA5aAFt11U
#YM2UdneDugAyHZ/K5hNuIpxEuzZaBof7Cgc1Gtee6ryMEzYJCxFHboI1VGeg9gCMlqwZsqKf3dpxb9rePpIdCWMVT9W6WyC4HZtb
#NTubQM5V3ZXME3UCnLQzzYRgRSyg6DAm16zZ33q05tZLwaAFejk8ybyiu+GD79cpU7CaCcgLhXRI3ckgBdHX9T7YMn9Zzp+Lo0P3
#xiUuwFXEEU/cAgN7+p65en3Cn6dGyYnrFZvcME1iQEFy4ahUJdEV9B2bWibT4+Jfvk8oVi7RSsl7N/GxVxMjFxfMTMg7Qt2kfCqP
#SxgXYLQA3wjzE7rIl0lOaYQvgLBmhBIIV4/MNe0h776rpJmuXPWZlXmzeQph5Zlc3MzmEswMy+xEFZGscBTqgTrHDTgA/ZUOY53P
#OpyxV5YoiVLRheAS5Bdg5JWyY7Zqt3bJ1O6Om20CLxwjdQKYnp6BL9g/woZe0/bfWORMOZwxkubCYcPc1Y9ddQTzydedTb68PsYa
#0cRlpanDmJZ0beycmPfleKjbbRntKfl+D2XQ7xeRQHMxa1v+LcZ0fC0xt06cM210hPwFMX46As0qDM1e35m/MeOELqyivqnNUz+n
#9/ZbcNlkL8liQiO2fmPn60bVzPikRC+kwwtuoRA9HEwAP3aRiORTXagoJdqbQehqZni4DfPo+wHc9GpLnbwAqa9VuhyLkGQRbG7b
#sMmzwuviQ+6t9Ko/vOw3O/R03u/LJIUFTFA/KSeVB6nwCBOxYBSkSHAWx79DBiIMQFREqXQUB9jET5fOKgmF1lM+OYWeZnqHCvRb
#M1cKx9ZZLsZncpV+2XvW4YsOGXAJRac/KoArJj6AZrTV6tvdYgf3BlksX/pNQWCmQ6wOeR6G0CN+4hZI3kG4IXexseaYFSgwQZDr
#J8PG0Ac5uNSoOpkZ5iY06yG7L6ep0gx5ekyxlzacxILHOqEFSwyBNJVtKNdpI3x++ZMVqE3VAVKijJb1TtsZDxxMZkgxMLNwR+0b
#P2XcebPqyoVAlTxGK0nq6t65CmeBAFZihhx1yrz8081U2uTpmVL4GsR0+kBN/6ipCSnrOwT7TnzseRAy/+fuy6avtmw8JCY3EKmH
#UIyE+tmGvSV6E2c35UqLiJ0Sger04fr+kP/mE8Rz5b8IKChpkUdDTlggmBpPvBVmAhl32TfA0m+IdXwbqqDfZE/hP9mzrRs4Fqas
#iFUgQ4AMxCmBXBKRhjlUKcLQoUEQAR0DEfVl920sqOEB4nHhmAhhuS3wryZFy7g9jag6tuKJdgajl+2azBmi1c1CjzCjTEwKDwMP
#NJeDJL1PYrDNErO0ptlltoK4vWVtcfQhu2uuJ9bmEEwP3A1/xxy2GoPiME72LcocixzqKqXyMocKDvvtn7rxyPcuJRVGj/l747/1
#RccyWmN5dT1lCOO0WM71w4axGlGV2Gme67jKFl3QlFukC3D5CaeOBhS69ZuV9swSTVY9WOB09NpxcnINny5SUvEUO4FEVw+uTyL1
#1/fGvkKXbru87vQf11V0GyiMAju9ftLAPcMVfnXju9d0jZk51p1n3X5otYPKq8mG93VquoE0gbqv0i8GdYb4SBGhVrlYfW1WCeSK
#FFFtO3qG77TkVmhT13+7rv9Ms6HtkT20rePKU9tOcD7NVsFte1/IyqAXoLCNn3TTEQGmJkLKGWjPUxYlRMjA+cb8qSOoEsJTq/75
#GSmdKVVg6bNWqiVKtT/S53jcrYwa3nx1rbrf2IMrOgjvNtmQTbN8/oxD4WuYoUZlMBxtjUH16jjcOdGMKORAJ+wLgkAfbX7swudc
#lmXIi8pMZMOX5UYXrNOU1TTTKZMHcka1TtrXzQJoweA3MDAqpxtPdihpbSbq57c+vs4YtjVnaimjYBb1ZyhU7ZCsB/eSCHc20wn2
#Nm78MjupejCNq/yTyn+6eMhZzRmT2brtj7JgYh2AydvUqlAR2UHYLbQ7h4xLvR8BYtQnssg+dbxxfBQGTUT9FdGaXO4G3ddEw3nV
#q9/afFvr7v0bHPZ74trhGimzC6uZ79h0qd7V8rt2XdOu0f55l9VA9p7DXkUznCCRFC6xnPf4fUowQJyz+PxTp3520/bt1mtUvejR
#1ATqbqFPnuQFFWtfhVa+NSNqa6jSrHBuYRbsik6zcGupX7Gdo9Ripq8/F9WVdQa8hxl5zahkx9d0PLH3l68KizjSDDowkZMzRac3
#djjPv5lKda3WfXJ5oUr73Y3BFmyzs6zV/SrKz9d5nANaEWAjkAM+WD5595AEDmkHoSwCJuEWqmruG846Em2/hwox8kSyQLbA1XrH
#SNZXcfm12snM25OWwbE+wB9s2bNj+CZJQ9r4XdPYwFhzIqe29p3wHhv8e1qstIr2c7261VLZSX/3hLf2P0tt3zl9gsxpE9F0ddWP
#xBgYLRq95VXWuaajiszBnDeDTz+zv4KZRkdD++ev/jJ/4AHpf4JIjdpF0Lqv/HrZtkm66c7I4yY0qGKYvbPKcZlLgJOaZHLaLDOJ
#3YIpsZNgpyk+jvNNJK7Fqqg00hEObC8SIGQHbMAgegDHJw+Ws4X2Ev1uuOtrFpX80E+63JrAxpLXVtO80zaQeOPX3MzmeSMPBx+O
#icJFcbr+rk9jcAiWoNUfd9SEtrqTm9KeFHhAPqHBfVNYEdjT2qCWfq3rHVnwsYpTgDDwPXNMVLYEtAYq9zTwoTYB/AUD8cN/0UZY
#dzEdL9/S2odfih54toKZuPDX/l2VbfZedqZaSCSmC4S6htn01xzUcrXnZDkNk35IP3m/C/qjiEaAvGZMGbGx1mXQEn60fo/kAAx4
#zStT/qB6rziP443gTZM3TNTrhBEYB3TKJRJYrwo/E4PgjcIyBR74Ck+SyKM2gaCppDsr9r+dJsiDuNsf2i/6NZsimDwkiLwXhoCt
#bQHmeqcwqC26jvyH33VEHo78PkkFgg868xgwznMi3BQUF2j2kU/OPuf10RYMFO0ERjGYvALBB5UZBH+MvIBQWC1yr9h/nXhxSSGU
#/uQVJSBXoUOTNl7ilKGRS1njB2N0NxmDwCdjpy3upfiLfoWG6ztUycqgQt4T+NZp7bOyeA1z+adi9eLkusFA+ItbT/Snge8tU8Rl
#iLbZsLMpyqTx3XHTabuiU2MwU7b/UtVTseea//lEeie4t7UCaDZ6n++v4HPuCMMJAYFrJBPDGdYjlPQ3sgsetsOHHIeB5ItQr5dn
#PP0BxmUH9l6v6yX4yQUgTwPKAfm5Xh2qw8DfJb2r6ozZsCdElzwzVJsA0FjSCbUzRmu/48nJseAJ2Ft03dgT9OvDnAYor02KPj13
#28h4EvQo+JAPKtFJjaMF/ig/djLu/Wr8JdhC/hFU2xpP7PRXf4QkwKa65vqmOKW9b9rXllvVG9rg5ER0kE/dcezZoVdNb+GaGIA2
#V5NCXPJzmSo2KYKrvDk6+oJJIs7aolAAjTQdYLzdJnZLwc6QJqxH3Jf2dfz1SPeR8431ttYZ2Guxi9jnyHahs1kxXWR0dlJcKb6y
#cRAaPSzyAfPU5uxsfKJF2QgFBOTL8+tTt8B+Ck8G3Af8fiG6ZNz9MOdSDX+Hj2ev3doXwAtDsG9pvLOHsbuwdxUQzRommXizSPPh
#lvoJ9GpMxxGQ7Rp9ZJJusZfOS5pOuakkKIB9MxmRtQiNpPCj0m/7awpjYw5mQUTlbT8QfnO2fpFjArA5Ua/Q/fbMiDVvNpN2n8eA
#NL1XnlcVaSCI+vFsIA/rxNVmxBnLn9NmcLBAJvsO8igO9hhLfD1KQ/BwchQyBg5zLlXu2wnWnX2mQYs5wYVFfsDHYIYN3yJA7H1c
#VrYPL3nZZ2BuAydeepiXwuXqF8ucxmh98zLKUI4+A338PezmYCCPM5Q8xfs48eT+ZpR+fZQOjD6TjbU5bl8Mc5CvRNZJ+dbnDLO+
#NOpX+SE+yfY03pRGhS3RGGKshUr+dch3KBJPnz5hKyjRLUg2awyrdyRqeqRX64y7f+hXu4uzzi0DsWdNFo/9F7IQlmninDWHd4F6
#buSvM0zRy+GqQkjhCKd6h2dXyYXr4pX9y71vTrcBxJEkTWD+Tnc0vOoehb+lIH5t5NAXDVMij+68pc8hDXuEaB2f2tbBw6ubaL4q
#dNzUJAbCWdA4rh3fpAv3DzrQqSn6jwQkcRZRikoluwdFjXc48Zm4yLc4r91TCF6NOkEYfFYxjrC5IKfL+48Rf9woZpYuksb8jLFK
#ZiACXvZUWahfECVUofghBhaGoxYHjtYE8J0n0ZTh8HrXAGaPP8iRsDUF8s9AKXh7AEWcb/iO+b439Zp9/mmcnXqh2EmOtshpTYb1
#U3fVWmlAGKpIJEEmUsVaiUQ1A41UZtuEQrlKKdiTVUpWsTQCL/Tiar67/YnnS9CCVrODqOag4zJDpXIp8LSc1kKXX24APldCEWk+
#0IiYt2Keq1a7OEKhdKZhCaXCMmiWphhVJjA5lhz0OblDSBO/47Eic7kKKG2eg4eXzTQ+y08MMy5LVqtgMauZKtU7wrOFR4KPkPqg
#xEZt3pQdtQvZ3iUQc87NdumjEI4AGCM7qM67Yt2QNFZDULYoeVU3dnL3cbS3X6ptaux31b33bDRH/B6nu8GJi/9dMSSvxmWZcReP
#x5H1jr6f3rdnpI8X090IuMlAUb7550i9Qtk6zELsxWgbuUowySzmcFg6/tyddrPZOgWFjkQ6Ar1YaolQt8yOt/P5ylUnNIxJlm1E
#SFl2yTw0o3QqkVa89otunPkysaa1gcDwg8ToC2X7z7EAAZgREboBEdwREf4hAQCSOHI9/6whfBia3hizSmMsNNwftyMIgpsS9n3a
#mwelQQFH5wMqBII4ugZZLvK+gz7baRPT/Ma9vx6RxK34FGNwnMS5JgpmjzguR1i5vk0rQXeQ0RidEzUV9FTTJoHUbIyvGci9MJyp
#kkMEV7bZMVo5+whJXbpiAWbOgDL8ALQ79CxYq0jJUbU45IGS8Qw87J64XVTdDg4STaaNSeTRtBwmCfEH5AsUPIrIVCKIiNhERH14
#ZWnoHQNxc8modNfqIbGbz97cIo3wdZdib8Bnd7TBccRJH41+AR3cmV937RuL2sQzHd4Mmr2RdDVXqo/RMO4tS+TVo0+5UPaVKQFD
#qBmbX6PeRmTuj7PidjLyIRfjIaKXZdsx3Mf/PVfGF/HDeXS+9x+aNGGotgT7KyHtdBb1pf3/OkLv/938n/Cf/7NPO6z/d0DQ/zn/
#ycrMyvJ/5D+ZGVn+P//D/5L87/ynugEA4n/3sWsAALXv/0v+M4ALu94GJ8LtvwAoGkQAAWQ2KiIEVGACQ8AVInQwyf8AQcNF/guC
#QoFHAMAEqGH7NICvs8Fm7t0AdEtt5wk2AbOew8FNQVW4mBE44OXHd8Yl7v/9VRczjf4GbMEXUqSkIEqQFUB8qDDoTEm8+jwXueY6
#611s2hpSp/YIdLt/Oy6ZhwikEUBuQMthbJ20y/jON/Pw8vJeiGBZNyoRJW559Hro7psjEWou40AXauDuVq9AgCtmguBdMSM1Exz0
#TYVZPGeLEGpS678L4pJztbZBReuaEa9KVurl+j3ePazxOeMnektQSKka/O1M0E36Pz1xmN/9kMheSgUQqWFTi2qJgO86NnKe5kRl
#bw6/TGMWcv786ST+WSdAkEgQ/DMCCeecIJcDgTdSs5KaMUd17KzB3ilf3960261opX7hf73P6pGfJ0ETZm7BBw36tmqMJIwqSbcZ
#wDku/lsTDuwCFABZ2+z4lMgngs6vBioKQ7CtbPqDTS4GKEaqvkHLN8Syrji/bmZLgaPv2aX0m3KbFLF3I9g0xKT0/6thtNX6pR//
#kF0PZBKOZ6VKmlBdT6j3yA32pCJY7+tcxKagIgAV+zDk5xYAh7O8QHgOWlRS1FesqhLjy222lHzKaUVdxxkFFhpiZInZ0dMS9I8d
#MpByEjgNAfdH8vnNqrrj64cJJwFGC+QpNAusGKReqJUzvMxzUtKT26XxdMu6xW/jB4B7+xrZI0J1Kljkmtk+lb8mYye2su39oiFH
#ExRmKmF6/Wv5Vl3peZN03+8iJJpIgwxiQ6KBWe0WDDULoXfGguxivfYvH3XJI5Cc8AHUQP5dfg2uYQiNrlm0zE/feooO6baAxW5f
#rcVONGyxxRJBADNiAWLJut682nnduSYIoLFgiKd8ENL63VWpev6xSwTiyNR1om3xCuWSjnmNlr+YxUC2RXLt+8O29WWXYacAhMVs
#JBQW0qKViC7QvJwHKAYUuIRichd9wJmr+8/I5tBMwBlqxrNmvSZuXh1TDcsOSR5D30MgSxZOx/3X90Nlu+PX5cZ+AOVIn2910DpE
#BVzpUyguv4bv6SNPe78Ht6B/m8MA817PYK3jCanif5yraAhKw4KHX3Tok984YbOkCF+qHSKKsTU2/2/FeUQiesCIVggJUqATYebC
#EmjHfARjbUnG7au3e/hqfex2h4ZQAmIAzBq8gYjpzcPnxViDuObHh6KTe9QsbkiVMikola3111jmh57yNOb5ZwVrpIFosh1YruOY
#HtVVDFQN8IyQP4zXuwtkHcSAshw5IwIgBGBTcj/JHTcTAElZWEuNQgbneD+gu1sh0oZCnk+lHIVqDfyyDNBqBcwVAwaWFQXLDoVl
#U2RYlh2xbSf0thOc9x7A84p2OcKlGDQBABWMM5+AIWlN4ThfmOgk/ET86RyASBD4cwhMEcPXVcGim5oeD1OAB/27aCdyHbjnhzYh
#MpR5gAiNG3xA2xT5s+MAusyGZIDaf19qoNBejhVRDgu+TIMNjQvKYks3sPKWqDkVAlZX+nfF3O0OveWN3O5iDLbW4MN7r2FcnDBS
#MRRcDNt/QcugGQqDFlyMGVAMmCBXDvcckcckAN1+YBhkBhkB9ivE1wAwFB0v9MC/tBxTrsV5nKGj2ve12RYxrvRFR0sSX2fxtAVT
#yygcJoFN5cbStgZQtQJlSuKJfZKyRnYvOZAnweLCJ2EbKWmgE+D4j/cmT819te6th21FXdjQve4Wf3XrxWqnktq1ITeSIyk2ANdh
#SrelhG1qtVJHL8oK7nZIUaLoeSDgshKN9aawlkrAEcrx1HYMx0pvQEdrClQJwodOifl2M1K92eEic/C56/h35OjOGq7FCfd3nDaA
#HmtYPKwv6e3JTG82RmeyiTNPGebT2ckXout4HGGi93r8aFDMq7vXmZWlGTyCgX/12OklnpV2Wv5Ld+idOK2KoMlO0LffE9rZ/bwt
#HrB/D3sxD8kX+kn+RP0eX/E3dD5zj8DlHNQaoqhGMo5w3t8PpA/pxv4eqbVb9izt9jtjKkvTb/r6bPFpBXBxIQ0tqnemhgAdBKMI
#hbcmFcbc47xz5HkOTWvuN+SjT9uyQptxslWBEh1TwkW7MXTtGPDbziPmX4bKHK6UU+oBA5oDLi5dzgtqQcs3kc+5IiShVIREhRx/
#GYYbYvLf961S3IldvDyEMsCdEIAoVyqghglGPaI8kCTJUVm6u0ccH77P2NCMoU/WKnnR3j+mYgkTdNroiFJZLTyPLhocR3+TlRbA
#mgXOv4rpD2fVVgFkD0Y7+O8vYPuGPzNBy3hwJ6GGeFgN8FdoA5tWHgfQgpCQbu43b8Oww359lnHAAcPU1mj+amSncQQqlnpcYBGB
#P0woXhGFx2QhVawCZDkBkHKP+fxXaRBpWBCnJF5pofCfXrfnH7jKOqw0nh+eteFH6DI+EnoDt2Ew6vmRrKAX8qWyI6u39zsqme9I
#eT7vtlN4sNGEd6nO9KvcHYxpxRxDfXsug9hlBl/334eBaG6ZWXG/5OsqIbT9P3mR6ftv6Lq+p5e2vZ9v6QZWJC1axWUSTcu2ltgK
#165I26gixSHHTGP5ooREmeQLlay5lJNGZAU6OooI9AQi1BHyMI1cJR7TyfrJFOPnlTiVFDEe2UzJFosBixWpSlnsCLebZC4XA1DY
#UUwjik2GIQoYdiTbZEWVUcw41gEQGEj+DxObgUDCwvpmptfPq5Mc99He386P160B972Y729plRmwR42MkprQik1H7Nci3WS8xVRE
#GRksv6LExxadeG9N1x3ATy714RwIbLEemlxnqO5n+hhl4RIra9S8lfWjafOOAnU20KIYTOU4EaXeSUap8JihzYwPGFdZC2oVbj0O
#cRuhgJI4lS/tY+i0lyqEDJYlx5Qc7YOdFmPjouIHxev+gLPcyAyELo9/J35pF2qH6wij9w/SaYTKqTYdyiZ7O8mU6oT5abu4zXdU
#K1bLlcp1BXHLTOrLC5RjeHbBCWQcB3cGAsEvZR45kq3x47CJRKDHUAlQgSoEFi8QWD2BKvaUX2qBsSnl6qS3iwW/JInyxfE6hEzc
#EnzpePLcpxwtcQmF7KRXu0L7gaFcLv9SJNSRQ0y6Q/XZKlEUep4IQYuH6QNFCqGwStyAO90KoRINnuMR62igRg7nHQr8WTJitXjX
#P4oZPE0wSNGBZEgvdvay6O/CXgeyx8L28vDyFHcvmEprKrpbVLLOvM+NUgzjhNctMohbL5x/Zr7TxY3r3jMsVEMk/r2xoZf/aGOe
#zj248VvFAhCZ2sRr0StPAmBnzGaPzoWK+KLAKs8oaX9kqdxWmMUsUOB9xrMXf/ew5a03IDL5t0wOA3k/Aly+1+6y/mw+qPjVVuZJ
#gn9pclaLGnDqQddzSHpDujZA+FEtxtrjLZN3+u05So73fKd0A//yGCmri0uT0diG9W5a6iRFqskzXTgNMGGsrUi9xaSyyr7avP38
#ELskBg9RuA07dE+tUuuRPyNUxm/irfLAs2GuYI1hkfehdpxFRp+sQrLrto867M102TtZ9GYQo10V3l8bUBtSPoZZn4dryiGYspSs
#K1gj0GcoxhrVh69IOFjsXYq0p3FQlRMWhGIhEbWwKAsLCckKckCgzQo4RuidjKPwWErw8Rdn4hxToHDbmWI1zOdshRfF0rgiJRPJ
#xjvUFIUbUVGW5go1CLDCTmFPSDIxU5DmOSpMKDASpRMEBaWRKJLYmZ+fq+lDSSSUokx3NKQHkhM214eWGY4nYs+dnRKWmxAmVxMk
#Ej80KMk4oha8vYFk8SFC/IoN2K/i5I1lSBQ81VXad8Z+0vhcGFR7uxfPv/U+51W4bMtRXLKGkh/cQ4ZTIbbN0ZWVoA+SCRVTLBiN
#SBuc7ScPtrnxdOrOMxTJIe3BSY3THPhbQRiPONEL+kSgTYJfA19DX4Nfw+MA4EDggOA0CvmKAHYWIIj+F5idesSc2agUhLVSDPNk
#yV/Q2m70WzBKkZ/ryG9Af4kIAgyXFu4f49Cn80haJIWy8N7QjLs9wggAR8N5RxDQoL7si7zaS0x3wYauHwBEl5Rgy1W33oC+IkLS
#JLulEQoXQSlEjOKIQk/ewZVervoQ+xDkYoqPoDEhLstsE/6gEGBHKYQYoRCsSPmIo9+L7fVagK8CWikXpL1UsIfNX8gUaGqRWfA8
#bkXdXMPEQd3uAxwUgBncv4z/wdCCy2Lg2YJgaMRpGR00ParIqccVb90vxx2KfVqnf7schvuZuTSwC0hULsPZ+RPTN/CHxAEhKF22
#QktnY0hLbak2li7xNFlQzqIvpHUfEOjksuc3RANVUoNwd7WBhhoo2GHSJ5WcWl3s5ytMgHT41d/qsz+2GxaOQ0i2JFTAw2JjhOqg
#SJmguR4Ws7JYmtJON2yV2CNxqmW5DqWxgAUPR+/hqn5ff0TmviB8yVV2GNehBMKN9yBuO/mbktr1OA6Vlms/tsbnsqm7YdOyrfgw
#w6rVLeqNn0RRlmXegWGeYdrCca5pnDDbuqlfAsT/WiQebga1BldoCnACvEJCsx3R4ka/KWwNQOCqRz8H2IeIFi9aCVvJ5ZIDEm49
#dW8dbspsM3q1UxCzkNc3aC1EVYjfZw178quG/p3uuh3d+oPJQ9D8PKTSN/yWvqg8ndu7RSNKqXtD/9CXHorUq5fnGUlchEIkFFTv
#LfZAPrhAY3tAKglIN3/PtUOjk0OvuPfIDI+UXO+coQWVE0FUYoJCHSL9uIUM9g8MiGtNQucbBzlMWoo6jA8Ge8hDTE9ciDA5O/jb
#3eQP1iMEPi8E/1qImvvZ27Ejet7276zsasLkZbSvb4HnHebdHhXv8CWo6Tbz/IPoHK716hE75xm368w1owEOTidqNJGQQJRMAo/Y
#bE6JRw87GoD62R5j54JfwdXM4yRfJGNVNuzICCQqeJ0QwYiQJNPfnYKirmncxLKuadoFw2aOLdt4V3m5f6Vt3VydsF83fWMev1pM
#wwOqgT9Upug/Vexoohcj5cYGxrTpieAYMCDychCSbJpftw1gJL8iFScGGtXWrHBUAcQdnVQSvsgbUOj3IHnDTkOqzwOv+4MMOtWE
#iw5AkvQPRInHhajnAaqpR5QwqFQPlnUjToI/huQfiNAPZa8oD7bWtBlEcV7ioJ1MgIHCAHFFWn2eKW+TNTCAQhHM2td0JVb6TqXt
#4ssWMBQ9TkP3JVXU2HtbAs5p+sAFcDVXBRRfDDrDuWXxf8BwY89NT0jq7axKmBsAw7fce3ZkuMbvRN2FHj/sgqhWLwU4qwkODKiN
#2LS289klM7CEmxi9FGGlrIpyLeKrjsOWWkDJg9KPo5ZBNYOQLFApR9YK0Tsovw/OI9kwWRyaNpGkLkO5mqOviaASYo3MGkN8DLn4
#sQxBM528PH7HJQCUhkudiv+DDxj5+2vBuF/Tj/J+c61jm9k5xv0x/Z1CEfDf8U/aBvpHsXUtdOsI7aSOt9LzMe+q334l3nepof81
#eobHeRlM3MsTk0zP8/S9+Y1cr8M+R1DGiAvbaR6FoFYwuD6sr0R3yzwgl1gi8dRT970fwzwScPev1xydguYOkVh27ubB4HhIj/yT
#P87nCp+9x21K3K7rLhb898WrdNB+VOd1UrKPHO/3OafnVbRfu8+DD8JLxm2EEBz3FRIuSNx/hJykoDS/2MjMwIQImU4rWKKhkAdx
#qChKRLdEap4uSb/TBrPxeFy9UqIB6a7qOdbddUk/x4oVa9mzctcAGIZlHGJGLHLp3A+eRyTDYYHUPMd9gJPbucX+Vdf6jjTezszo
#E5pqb7pDAHcVN06xN/qnCGnnttM9TLlOU8ZtpcXuLqWwTNg6Hq2juyqP62NxxCjyjxHPRz9gBXrcq6p69+dxGi1abxDm4iEje2TK
#s3+BKzWhIbUdoeRZC8EjsEpCgHyOygmBupUIXib246Bm0LUCkbB9GraL7mslEectVkBxogGbHKU2Tqt2MGVggZevfuKhhucSB78/
#Y5vDsQaNVZqYcPerotXsGCWIIdYd65mkJrBCgU8tCPL9CS3kuSqmUOV1zEftbTeRfefjRvdI1hOpt2/VxW1rG2nWTh8FM2YYsigf
#gTSrniUV594ZzUwijxhclhcGBtyIBVIIUJSo3HOV0ByFk4zP83BFqq3RLNBAvnnuMARptP8gSspCM4s1QuqwMtbfLpBsxHIEah4c
#NCrJrn2UVn7oUqOsuGE1axa1yjcNgifJGhyc6rrN8jMgBoT6A8fQ1LwMjzsh+48ed26qU57Q9qve9DDWU7GKoOvJJP2egqxGrQGM
#TaN1/xD2pQX7EiT4jKhjKPr4S7K+lXsHzMC1dfohBEFLDve4sbpZ7px2VwvZ1hhAfq+nFROE1k8so7CZxBETXrmeoHOCeqFEr81Q
#VCwxln6cJ43AXqypzIovMR3jgklQEYbptXqjYRnYtuOkBrGqzjZ7WeyUyvx3g09JcaACcJtNHWRCRigHLkGCz4nUdj4B5DKntB1B
#yPoRihtGoi+NvEBuMEi9ofOs6X5pqSw51klFceiyVX+nB5P5FaUll4tp+ba31G1JItJ4rMUec1bHzj6CKeK/2sK4hB+MkvyOC+bl
#OApu6l+ECRaG/ePMW/EUWzh4yBPDgPIUpClY5nzJuOBhW2miDVZ2BROHKV55VdzP5C5FqclIUahOPgskicl/9puAVe2K7UDAhRd+
#AuNkjbuZ938nhxFqLAmGybwuoEC8AUG9/UMCCP1IVAwolQ6ky/1olwxIWGNk8eHV41Z6O0+BmcfG7xLiH8lWcRuPW16t5BYfXryc
#FOuvuUVTtGXtrx0f066jh5Co+kCQpIkaSBWinnAsoDBRDwE90bX33VlGMd2jPFFF0uks/C05956agBhEvbnDnBkX0uBYZBD1Ztb0
#UzHOcGyHVmnUC+dfbZfVKZ8VJhZcwHycDiziAafrV3IJ7bKiXWsh/4AAOHySOrJFh07WpAFZMDoTCCafu8oPwV5ySg9TSaWM4n2S
#3Md1JHxDPd0h7d+j6crmhGuYEH1NSg8mLjdtSUZn1gy/8YInbtGRq4ufZ5owtm0asks7gGQ37X5wDstPxDRxg9t17t+Spk3cjuJA
#O27T6ZJq4Zdle8wzRR45kJkgKqjG6hBL+d3ytMQM0iGoo5OkkbV2JMTSP6EeyYoMKKknCGYzlmydHOCdM5fdVgBsIBZHDILLSajR
#rgKX6UJMog249iiVrXPlZPvuXSVcYMKoIEmLM7I2nI/qIZfA/CcZMw60IW5QodtZ3mn67lmxGsiaGQ3ySBVGK8nUaPhn6i3QaD1J
#LUNPfd9vRZLyr2PuB5Xr7wo0yDGGYweSL091P2mbivBiVv9hviwuv/1a36XXdMQxSZ16d0g73EU2ye8PJDkbV+gabzZKtCKu6tAN
#bgRolppJCRApdafD3+dHvJFYZSwlfcF0aD7hdo53/ARjoDF3hj5tRLEzmdtswGi2oOPFGuqDifvRSb3Fp2DlPH4EdjPEHNi3YVxs
#xjjmr8OenpxTmyCwjcJa1tV81pa42MOBNdGXM0roQW5mto1fD1SQrT3A0fKBwG0gzs6LyoEKsgjr0kDgRHqE0jlSQSRibmZM4qI7
#GIhknjOVBRBIL5/MIkI8iqhzwIKIFtYk2uFkpxifUJUF5mcW1KKBwAnzCq9xoILMwKhO8eEMu+m0z1oSnCOpwosG8y3AygEPxJ/P
#Kt5qSkYVjw6vmAOJmwYaWF/+dAtZ2LAl+Hd2hEHHaduh5LlUU/FVU/PZKvgOu72fu+G1va0fZN2MNRyOVRyOdRyOmWJ0VI3t8LiF
#bVx4qCw+VBcfqUqOeWF0xI358L59O8y+VnutM9PdYMIWOclPIZVEVFbtzBHP3MhrPjg23W6S88ILruPTQY8/+m8CmHDWv6KDsL0H
#9zvglovG0/YRJhfr2q+oq/uhCh3LrOuLIK84FsWbL+0uZx1KmUCZ+roJeyInbX/yVqphQHNa2BKhxWE8NV25ECRXmoZHRCGdbbmn
#hVRUUFWEqIxgkxmAWZmpips6Q9Oq/CJqTicQNVhIR4mo3gqvdAj5OUX7wo4EtFtdJLJwjk0FAbagqzQbsTqq/COK1NZMoplIFF9s
#Zb+WLWtFljTVduKaUidaTaC2nDPyodGixIsqDTk0kxnr7LVpS+u8tqi9dMsmyov9Ie4l7u3lZVRzzT1QQHI1o9W8lbtVjdXAF/Mk
#X32Xl0ifzHApb9hdysZB69KIseyUTFpVyEPMFZ+T3xHp2NOv9eyh06XiMt0AcOwwL3u9sr/Vn1TJjoyrXFMe29FIEBXtfo5x8noO
#TCkXiWRK9IwYrXRvomk96aX4LCSPFWlDXTaCAQ4vBAkEBRyrChsjHEUQ9RewTHyDSh0FI1BkZLhPQ/CEMMQAawJXiAUjcYoJnE7I
#p3PTtJR0Skg3FnNYQuElx99n/quKgAyBKiRhJItJQkDQZtwey3mAlhyELl535yIzBECEsfyl0WTpp3bxxjOCi3CCJlN2Ucsie8bM
#RcTBvSVMWwgQBisCL8fFvC9adV0u2YqOS6IAcKcnoEqarkJBZNxXkR6rHFRR92hSeLJCiVjYQG6N5Geypvh2m6c0HgKIxXgG5AdC
#g4GZTH+zB3QGkqCCWdmpyL9nSMQury+qlFzWxYbVPiQ0qdGnkJAsTG3aZfoc2kQxMjnJ5AN7tgnu0B2YNR92CZhzcFIDUKLZo7w+
#aq1wUkX/WSXAwayDlrBbqSL0XRgNxEk3bskf3L9GeDYFegFhlk+ESccYQW/DNsInL/L/KjZGYneQg5ecCIyMhSz3U6k3KxlfxS5g
#c/tlNgIvOi5GaRZcehsK3CqUk8iWrGSdSBKKoaieNI83HB64+8jsVp1vhLXWaou0TL3hAPAedzitdIRXJiYS11r4XuL0lMNbDkBd
#gRc5um6nrcJh2PjHym53iy2N66le3N/I7L9wLAhsocjo74QExAJBof7MWPT9kVSYZoF1YJStu0vb3q/Izgl9phoIxWKZKoinW0iT
#OhD9YE40Rc22lY+YOFYXaIu7j9SDS9BVZyKl6Sl/xK2DQsN+rjksCeJjLHGboo4oaoODm2QSV5O8SFjm4y9alAnGzeJPXq9Iue6w
#9Mqv0sgGeM0rGZOWE4mD0q7PX6YqGSHuooLyhO1b2EMpgq+zXVLWpoeuEL8WdZPYbYJka1OTt79G6Fn6HOcGvD3KR2yRHqAXPlJk
#qlTAG+wTbjHA7UrAsokcwy7HnUH0yxb/6foswPAmE0d7QytnjNFXiPSTJTr4JM4DSNtAPtNP3CfjuqcWyQYBV1jGLHYAVtSTB0BH
#XnFTtDu2+ntG6ZUK8VkumeuvDIeFN7LaSoRRG62EyDoavQn43j8Tw5APPkX0ynLvi96G8gDNU0C4+UHBJUdN1OPlBIWvc+MPgjCm
#WolY3l+Hf+SK4VMuhlbkBVgnpDKIrDJcLxMGdyX0LGVMLYER1xT9nwFzQmNbO0QsYOWKqb8LW0SkinHxkEgkTkxhoqYc9yztQ4Xb
#LYwjtv/cf2WFlz+5DaQDnlzqsx0v4ib5TM47g/8PhNx6626ovYTXAn/vmJyrTDXRldb4bUnpQeVYhVqUKgSz9yBX8UOGaAd7zczs
#31t6RvJ/Xrjelbscrg3SolvPN/ksktqDbLykRFZqruOL8W0MgsY4qADsXjd3C9/Tpt5QcJE4ePUZDyvTgb5FWvAW/1otxlcw37wz
#6JrMDLRX19Om8fod0+BPPjF9ejrQgnVP7WiX85lqVZt7BvVzsuJDDA/xEXm9Tx74+35sESfbaxatbgsySL7058PZPSlZUkFSrc7H
#6F74YSVgKBLCXx5h6avTaVVVIRiiNkwdGx/rag0ZU5PE3oMReH7qXTNzDo1BrtWeFrQoGC88Zznqy4oo0gkXJbUgXyO9yzDilYB3
#qJ6K0QYhnk4kpJURlJ8DyEBgkP61vLyriFhfenn0KlbX8noMAk9B+mQK0dk3tGOZKJo9z1+dsHhVLG/NXzL6I2OQ8MpHbN1cio3f
#KbmuKggeoDpSeXSo4gOC0If+ff7FNyyW+kvgYSc66jtae7iYyNGZZr8i43Awm+zapOo5F0cxBoPia87aNGMmmvagzEtRRdcozrlg
#YJ+PT0138P6VHMG7odnaGVcXOFf75q7qpnLAxkUd2aMLTCKDJ0Jh/fSVSi1mRohL0fZBogJFs4lpdpo3GxQpHuy826oPyHmEj3Zz
#i64NQP8xR8b5DhTagzrptolxrf718Ltn89bXsuU0SsYE8ZJKiLipqIMHuUsYR0Gw0ZX+G65Og6N5wuHzjEXohoO3ieBN6U5LmNy6
#WH7AEomiMe4bMd0mBGSiySDCEpo0ZTWwQRAkQddyMxN/TA3+Xs2Fkk4knKlaXFWh9wyNL9r+3QaJKYfNmxzpVXJSsaH4TZKNmb4b
#jMNwiEKVpJ6SirTZ1LGuKeEra7Zm3Tu/d1VwwVH9yZW9RuhZ6YzEvWG/0K60GQUhmAhLrFOoiN8iGoPZMXKLqPC/1dPPQpk3dpbz
#ADb4dlOJlKs7W83ceQHfSUNXY/N0EfPor10gkYc3x2zB6GZx1sK6wIog7Ui3Vl+iqtbWOsHg2HljIjJLTY4242HzI4RGK2SDq19/
#irMEhz1uiTECZr6IeJUFWfViioR2GqwWvzdlFKtlKpJw2OY+yTKexYMdnGgJP7BjhCQA20QJoq6HLrhgeD3yYHZvlbBSeEl2L5Ej
#UW43C3qgMUBjg/KZPUsORFJO59FEQa8wtHWEpfkN1drz+CKSzbTWLck2JTevEEgC3m7G7AVGShTxaCQ2IqoCYAGyRC+EahhBfv1L
#3WupC72Qi+osArdJU8UbTPfALkpXSWKff4xAmrWhpLGl397D6PrCEhSmej/DFYFgGA1Y6IgP65uvJyQQIkMExHLm5ESowMSMpH1T
#u7rNg0kRtNCQ1GpN+s8q1vJjGQLL/qZxP+XxVEL75ibXy5LQGUilgJSaPUKIrsbgDGVqGOl4hZLQOkPMXCKnSCeayFqjsTPqMKH2
#dDwCB37mLuFuR3+PJAphfUf0qdL5ix4YMqaYOEGPGJOfeSuu/oIj2VQTRhQyxYYLMqmdmJuyN0wXiGm8+OzWOmfbEUh4RPLkuhoV
#rbE2+Fsy2XTqhp82leR58i6xqVDY/IhjzBLIzqm8kCmil7LWhv5tzId2wQTNlbTIyC2OtbUUWNqgfpaqzHXVk+4HogWV6uGDngS1
#qIZc3GV/t/6CS1JRtFQz8e7r9+08YE6oB0x+LXFhGECgYDST3Nm+NjfqsrUp3dOCw33WBHtsu0azF8pI9DgfzcjFtsQcNTW3p3aL
#uSZbK1Q+SvVv1fl4w8+CYuQDTYnLPFUc3VyjUeT9yz7M1Ixeasg2WVaS/5qXZbwyIAXfHlpCJi3SGQeMGNuJ4Pb1oOj8MD8/TtTm
#QzmPcloTU9Phe5SRUf3CvPVTtEb5pDKdXF0NHoVNCBMVv/tPm7482F08B21FCI8QIhIi2l0ttJEm11C1Edt0Xk6AxZ7Ily3X/ox0
#np6TidR5WVxPuH3BUY+hqDnqhupmvSkXLJzpPF6vR7MDOi6S43NpcbNhmbEGmjyOgan4+MyUvMeGiMLmh0wfXe64ox4LEQ/0GOXa
#Fy2Z9Ka1kezcW9yiHvFRjbVFKdUuc4Rzb8iPeXJGfGZlivU6oO/+VUKHY3WsgS5ME0irN+N2a1isiIHu5IDmHMERJB26tNlU0JEb
#x2tgCVsuTbup9/GylMsOGD/pwkDIOUw4is6UH+IeDM+Bcb5QaSPJ2iRchUsFfWMBFnGPYeyFGpd7e7oa5V8mDyeIwB2YpAoeMx2H
#KoHxbfKeYr+C4bQ1o4aXpCrFutwte4qmNQ//MJt404wOPA+MtKU042tp9EetuovqtVCQZETFWLnCWrdCXETowSbRBUPM5BZn8hQ3
#oxj7hq+1le9ZffzqGUhzWB6DTWYh4QHGwgQOASZBEQWrU0fhjE5lgZ365RJVptXt12xvxiARK3xOeTpTBCZo6PHIpnVF/WOmeQrY
#7E/js1Dvl42BSNEPxbNW0EqnpKybT3z34vEKLrVW4xjoCGcXmfC4kjC9OZcw1h2ScR2ROUWzNfFQQmJQGACvV1IUG510HeVOtuVD
#I5vQu+cvoKfqwNub7McFyAaPyeq5wkOJsNvleZbInCcYv4dGJvwGHT53fHUQ7OVFqD8x/VnCOoQgWJ7H25g8qeVHyrbdXpfrNcAC
#4ytYWiw7qI+/BUaHe4oAC/ybNoQJE/3r4RrNHZYorsUemd+0g+3NLh7oJIT3fyu44gmerX0C8B7+R+ID4isJfM80yiabdljiQrzm
#KiJ1HThfsTc3Cgfs/7xgUV3kU4uvBa59pRd2DxG8lvWFbeVF3bRT+7Zs6naHeI8G4PNJrDXE6LMneEuZNCF2EQb4DuWPODQ1TVbT
#S6evzs81v8xS04dWNiaQDmYY+FugJ8/5EpsSbccT3OaHznDzuSkWs+RxBv4Jr1BdU5atechXmpnJ/KxL5vWJlA1EeykLo0gcM/HP
#DesSajTlDcXKHVK+HnyDfgXeRT2jKlNc9U+pGiWawIp5BCGLNtkMxP99+wgZWHfl9NL2C5Ze6BxEAMYQLtgIQAJC/9prwsRxYOkO
#QEEO8AT7G6qfobBVIfr7rZPgwtJRKRtFMn0sjsXG3E2q2R1dJOGdh6duIkE83+S2uPpo2hK45XTTWqyoSbGmrrU4ILPM0o/lPCd5
#t7aMIuiXWLcHv3MAUN38xgLvwp6tLjMeDFE2NgH+ZAkszYUDKYE/WY54pDr7ZLpgt/Lel6PQR1SZa7Ov8um3+bLycuXDadQ9DFG5
#SF8D1gOTOL8rMdrQnk7ckgU+HHEReZakoStR9GsZL/V2qQWguOtjEDODXo5h5t9+n6WVzSgrP3PCRd4/UOWlXxYppVn9J0qg6l+V
#3jrxvgQjoc8ndFws2A5o90F5V/6Zfv2BrOdQsbLlBQmZxMLMDbiwZciZFxhTujjOtetHTNiWYMykKevxm6frvllsU0G2jilIe6RV
#S4s7p1DWCyw8ccSc8Lvi4tLsArVlmS/nkzAWrCsx+KwYDJhl87/47V5FfPF3BXOXf9Ng33t043IVHpl5cr3job1kQDLDTqgXU66Z
#nl2juxIytb3jI0iGmPmds2emcGkDJg7trp1YVTG6nWHbDVG4wC0ruD4NJwAmr/ixv87d1E7alEUTl0pzQPvYAGYV1qSMNY2jZsqq
#aVWyTwAaqM4anDxpxW51pG5V4BC93hDAnmcrnj21Cwm6Kqvo4epBmxqWVmpKSKIbsRlflvNn8L0m0+7WLR92Rb0nYpxZpkuNjFr0
#AEy8WT3au7v6NxP2NIiLZtSWHIrv0ujt0P7PS649u/UKrNzmiRvFy2kZSwQwgunVjls0ncL/MPFpq7xoyxVDYk5+YlpmxVJ6BweD
#GGAME08DJJeqpzm4Nq9SPlk7AHVHFLySHn4gJQTb0f2xfrRk/W0FSF+jdqHNnz/JLqNuq+1nktXty3Gf2m4W6CmCTBopFSd33N/P
#TkfebCiH0Z8YYLSnj5BFXfA5/NLlkyPoHt1xSxkjjMLfvGMNNZbOvAsBDnNIFmvFcRdow/wa+WXuuX2r9x6J4YKYIhK8CuNnatv8
#F9M9IAlz/PBBz7e/lAqD7d6DiWC4EUOMDHMZ/GwPriB0oAnIxyw4FAOnzEoXpJgXTTwod+Z4WUNhUmAHNT3QnplISWKNNKzgBrw1
#ERu1Fp1U4ea10OmcXyfaAJAb9ajdVj6jpLwmryYBJeY6qhFuII/qQfydtHy0SRKfaUoUFQBEWMdQE58OS6AzWlQUJbUVdVkBDrfb
#nCfyhCuihp5lPWy9ygVwkysaJcQptDFtaEd2RloQ5EAJgCUz84R3M+LpP4wg/6o84+T103HjGhWK+bbctGFngeOl1swlSDA9yfzu
#1vipogFEWuIkx91JyHNblGMfhhU49qPPFWHJJhfyRtwtWNDQ9Kg8qg8rBM53gazBWr7MKDwCrlq5OnYTgqZTjc6vnja1CspaSJCs
#4m4ZELOEXKITZKSpZVKkjrxBwbSn3fWppF2RhkcR/JWDobeiiFILd4ZnZmig/JQPfdV4Wc0PxDOyL6TvibQ4V35yB6jkD+1sBQeY
#DwZXPK12Fv69oMNFWCoILyPC1QsdwVkl7TeYMkEPFC7cEv3Rhu3tCJiug92CB7K365WlHNXyV7hvXUGoSyuSbOtA7DDGlXVTY2EZ
#H1ji77mT9zwwi6NIqzGb9LCMQoy4JfhFSmIBxzEZ6VB7iVH8nrDnjdp0FAv65EyLtnC3aDWw69J03K1cxmjd+URw7FifhNzqJdO/
#DtunUl/q7g6OnqvIa1SsiTrqW/8rru7JxUNcERoHI9C9nkmj5jrshiIEQAfYb+jGVDq60dMZAspHEsIOTgG4dmTrAQfwAT8nJ+Vm
#DvqVAbcPe2eZQurFH8vDa/OT2WxCLLTz7OjMRXNFdWRAtJ6/q4xE2B210ES+paN3AV1rEtHQ8mzVrPzSJ4p9U0l/AawTIPqXj11b
#hKqOnnLu3YR3kvZoE7qYQzpjtxR8XeqgpyqSRjdfWubecZHL4gqyWySkol1uLVuaLBZd8CQ2rMHlMsjxYqlK9Gkr4wBFTLroEPO9
#siWc8VGJ/wYkE2TXdzo0hSn20zzGeR4JAEse6ahJzSuJY3mcf9AhY9jl7qtWGIFWQUcX6pCq7apL9iV0Yetzya3kW/dATgWM3ICG
#evwbahox9U30LwR/2MvotCich52/udZqtOhmNM29mAQvzO4dLlfKIbTFOAgP329YXsP1buydrdeydfgUGp5ROwpyr36oI/6+NRVF
#7GoGKZeTbw9ncE1Jh4JuJkrU5VOBRp4K8dXy5mOz69iuPRxVXbitwn7VICnbsEZO+ux7xAx9FYbbe0fBTIXZhCAtuDr0/AZFJrjm
#M7dqVk7UeM3mNZqFtv5TfOAzd0Ubuj7qkfRI+ngaq6xNDh8lKmbg0sEZ8lkFLXgKUl5asn1UQSDxM/By3AQlHFVwsNM7ll//4XLa
#O2wTgRxxzGtmp4FejiZiDd/g705WBmxfEsBk18PywOT33vtFGlpCRrYrSfdOjZDM6N/grAMBo8qvDsX98y6iotnFaFlQQVZXBcxV
#4OdD4eIjwpK23iGc6p/QtyTO59VXYOmoiaG8JuFtLe+VQ2WPI9IDPNdo8Jl4A8msdczu2uveL13MKBFNo2ngGJtirKMaBY6DCGw5
#GDGiefs+2Jaxs1MPe2DAF3ArjJWwMB6W3cFYWMSPfv1RpLaLSi5FpMDPs1hTpDCo9QWtIXcwAwAh8QxJim9Grnd3xa241HvD5BIC
#LZUdlZMhwichSCC/SWLVheRW5hVSxfSfSu6pRcYCYJ+15U1d7eVt9bIUsFZaF2vZ6ML82gqVr+f2L1HOhmnbRfmUEsQMghSKX+UL
#578OtiNrTeGkfZxqMP+cGBPHW+GkrG9fHwVwf7JAxSUGBlgoAywVetZKoDfnekAyo4jB3cpCiSGFdwNPVXXUDZiUKS+h1gO80CGn
#8DW3fAytpQHySYTPAYMfdqZuIltov112FjJEwvcQVoxQ1JV7yDoUmgpYlLXLghCa2+46RwzVoJEEAZbGjXqaEQq9N+KsnltyuFEC
#qYzfUB+I+ej3DMZQwgfk0AwhCw9+qHmCIOrpXsalHxSBlSj2W0H/GX4jDpoAjx+EzPAV2IcIomBfhvWRA8+mnV+WSMIxR8Dno0/5
#HQhwL2wh+mA6COD23ylsB3SeNdTyWnnJ2b6DM/SFcfjcVDyQfSxJ2LPRxEaJfKwTofLQ+K5z4xSA2Jy5WqEkK30UGb/dmzrEeyzx
#aJVmjN/a9oLSFzFf85mUnBPvYwmBrTI5QMrz0jkkQ0v0C8D97jy7dXxtId1/oshA5qfCRgu6J9p9vEixfNHZFsMfvWw/meTUh6e+
#Te5Ed7yQJV0a941wAHqfWYHFcyuPol+vjz50JaPXjZb8HwJdmI7p4S3KaW89A+drHEf4+nlkwALUl5InfWlMRdi/QAU4bLsjN8A9
#fXP206kdZz+1K96MdYIJujx/0LIjwEmqNAng+CRPeOkxjShBNLFt3wgqIO/wCyhW9Atr2le1BT8tPz2stydWKSXczYY3cClWtp1P
#Wqq3xMjThfu3JMEJEbKYVmB70W1ulktvqYsRDy+IubCEI8v0XBgWUc8KUsaxQlys0IMUwZwWhvLGFaSlKqmYlVGhj+WzDdanP0B5
#whjhmuWBp+MqlXyqI3bIL0V3UaJnbLRKmHXZmzkZ/tYM+Vdkjo8R5po21+Ku8xC365vMk9FV/Mir7JrzT5rj8lKLckz9E4yMHWOx
#U73A09tNoKbGYwAa8uBX/ERISxkmYb40Cyv78CBYUEjbK44YciKECRO4PmkkfXg18VNgoXskovzXx4ghCLWBDGb9st/wAMe2ndpt
#KhbUjH8HvFMNF3CkSi29/lWbCZNNxK+Hs6UajtrGhomTcQLdgYQJ0k9oBkRqedR965TUeuTqNxp+chSbbYYxXF3u72CSuxpWeCo6
#dUKS12gAnPK0fbNmghwwBeD3tSvj4YmTyOEzilsKBW0bVLAjsGjKsUedW7RoNSxZnZ3GVEUdMprMYwY6tEhdrGs5z32LI/g4mTmZ
#bGf3tI6nS9qrUItudpwtxOq+3mMXMubnGnK74ils1iGGXqWsfcVNDd3FK+e12fwkGyaEz3nqh8c/Nyx3sucnr+p/HfZDtd3Xu6Rr
#kgtd0lnj2TE66Cfrks+nccvtKys9EmaJ/0qeDPZ4Shrvlt4onRcgu9NBrvCYKzKC0fE5D2R5uyMcD7+x4WzLM3BvnKl+OjhH+QNv
#6JtUKFS5aTGn69Ifwv/xUO7dL//F9ArUs6LIv5QduYIOlPhFTLC72ytt0M+4kgUzVsDb+Yl943INoK87fK4sKdRdtL6QkoQOizgF
#o0B3DRfVFNTokrFswjrepjqU51Omn9dGjglgQmgT2Sz1IkVlLHWaNvaaZXJI86rH2teLVZOzeNwp/oOP0FHtVfdJO4LhXDrilT1w
#qOdM3/cVStD/z4WQ4ha57WKhEydSVTmuGQ2mmWLWrGXSB1Jl1C5Nb7unbnifO9Dr8Kg/sZdEs+/8F3N488y6sY7rSPqvqqj5cfC0
#OmHUqmhHz9iiQftabatc7avKLGbx+nxao3ZBozT934KdXsVhv7meWc6jdun7bwDtHxTOv8symQNxeXvkYnxupl5e7U7zryoh8xtn
#pw9s5ptA5DGYs1gNn/nlbJOMQX4mWpGUpQnb1e0F31p0iXuaxevt7xUJr9xm32PsqzatxAxm83fphqLYC7cs8mm7tIlrxyyyTNNp
#cV/Jvsxfaa3LsoqHsgqoOV8d4AMxiKfdB78PaYZAhH3i2GoWCuPLgDKZFyu1S2rvXWpKGogUhEcmXbScg15Bv8sASgdJGX34AozB
#Lq3DfI3v4YCMyG1p6uwJhFOhcalHu4PwW5m5cax/uiDa4saqJHJqzREX1ATTgfeuECUyPuVk0rynejtJviCTBCaA8ybxq8P9tbgR
#6dup/Kbtmbdnq9vCGxqoAIhc4dUjTLw8iic/fw81HG/DqcckPuwgyMeW+EcmN7ZS0tZUWFLJOjAMqgi+kAdTrbeeyABDLm/pw25L
#Mfiq47leNaKZTZ8KVRZAP2P5HWWBWLsl/n6JU16sJf9pvdWkg/nx1lpLobDeIjaMk4lpZw6wjKPeMJ9QiVsoIl4Aw30ZExCIShB8
#IQpw7sUuTYMrr2/gJ5q4zUsfu175iNN4HV3FrC6ndZNIOuy/IPL4bx7DdX7HMzK2ixdsj56wShE4tY+3x7YtRbwbzwDCvtJbf9iy
#QrzaHDrEh73RuEmvgMKcRcqEKQ5Ebz5I99Td+fKQUMz+Yv7iyzxeW9AqjLYKAk/ACy+806wps1iFYCEWoypGqvUObR69izz+EPmV
#h84neuOyU4XPjRgJPkHIeZRRPuXfgxPn7KivUYrtJaW3EunSKetva/JJ+8KQ9TrhKXaHCpQW3liHyZlR2sRrxtHzDNo1070eL4c6
#pL9Jm0cfzjLwpp96besEbXcrC4TSaOBNqKP/VehbrMnS3d2WU9jbUk7x4nr87XJbLtSO6Ke0MeR9UD94iX1c9s4C7D6k79WtfPa0
#7CcVl2J6qQ34yiSvW0gVMw4LPd8e2LGRBg7TWnjgKL48izkXQmD7K0Ad9H/fYE3TdQoG54UACAFf6CsebML/uPRrglqkYkJq/4V7
#cDsSRfsnCT6yCWATO2+JNw5CrQ6QNov2JxbqrffiaAuBb6uOVmPyjHCLm1jIdeDJYRoxUEqNa0S5reOW1a2UQWnzadWPe4rjsu2D
#uhCrqxV/Gdzi7Hg13iklDX3//GGoIF6FNSlu2cp8phN6xHYrvBlWeZO/RJX1JTXZehM398ccbTXp5zGef3W2JkUvOz5SrjwmRWgc
#RqRURlQ/LEcTFPtIbRyiyTJ08FsLdZiav02cVJZJICBcggIz66njIHcPOI5wt1o1idVj0PnfL7K1AfvPAZ4ns3pr3upu13vB9MDi
#Zhvdo8VnyBw7GAzNjH+bjhQNr5ZTzEgwJxZcMEqgcycgja9B3ZFiGhZ/+bslygentiAPZS3IHDKQ+LoYhdRTbW2kIjL3vjr/JDFt
#O112DrSFO+FlEGySheCcMiTdH4Xu8tpk7ywz7vuGKm53QQ+Nb8ACCMUFs/KRdbI98E/biTnKa/vP1I6GrE6Mf6McphEqAli3X2Os
#IryFhgdzPE2BJBUjkM1pKt0X+vn6nIgJ05cDXr5ds7BALFsDHajyd4mpgRA5k2sB7X8p8imj4Pw8tDitdfV9NwoqoUgCd3qpz/gZ
#WP66r/eiJ4xxbf5dRPfIZCbOeru4xSlj4RIobVAqJfM2He5Gw+W97ZxcpQIR9koUQ4MwIPo1SDRjoJ/snVfbwAmyCvC87TuGo5cT
#KzwtEsD80t2W2pDtPObSy8bJfLJMipRX21UD5mkgCAjzCilTaRHzFO1fPSzxMVYWX5RrR2rBmXV1CWcMJI+sdmY5YFjQx6m5vKiE
#AOAI0LkC5JPvBFuoqruLKnrB0PenRw2BjB5nMZ9wqqlSAqiXUrBNhT95b/L5+9xLBBmlsJZdv2BgK5sfacUJng9OvaK1AuwHzn/e
#gvlvyOb0sO5WIkyJG8OAE44e4/qqFMs0zX5xINdQs0g2LiBk3zu38cbcD4Bj0XCKAtYHD69NN1ywAkS79mukV4aGMbB9Bn3nTZiY
#9SBJhyZI4yYc6nnKZ+fGudYK0vJM4i/Ax92Pae0zPjh6bHuppGbUO6ENiu1EFzBzbKyIJubkkPDZkkYcwW5KAXp1dTkW5E9Er8U1
#KnkQ4fV5P6Ag/q2KDWiGyTW+8yCZJufzjWyKGB8KeotwqWl5ruEPBD2rrQ0+qJWmbXjSmWQvIVeROnnAqJn1OPiyYPNVsgAbBM9f
#zvt13y/X3nF2hHEOZa4slfh5LkPl+uxiosZx/5qdnJMvxXzKF1sVSDV4p0bnQ2xMarKQHRCYwFJSCGArmQQLo/X8VcVCOE84jBqi
#/xghvW+Mdk1W8ZUpMKjUJj7g4mVMJ9Gm/eNR6timTeo82VCK0yYjd38fWeotCg71tTj1FSdKiSRFqlMpTQu1++oqwevQoRp3yTAZ
#n7foJ0i5xM3k6zH3TpyBZFYDJTZGpdlZDg29zae4B5dkisbMzHpQ3rxCy3XMSL60r/zDRt4PjtQTlO4QyxNiAnHycTB0c5pf3bGG
#QqmFUq0zWy2VgdwK7bTVU6W0Z4T0b48IWmjZ4MVsXdcgaS9lI0Z+hcXh0Vop/5XakL0zZ7bQSIwf8cvIW1xfQaUTVLIv4zvWhOzv
#N45e/5dI4+iu4jIi1dM7ii5avJt2kQp2VUW0kHoZ6C0/o0hIvvqkrrZ6qM4hnBlSdDrIBcNtuNDxnBKzNTzhWlN8vhxC80hBia5L
#ukH25w1YyvkUIaNXfO1hCTRI+J856hRIAV6ALlgNIg8kP32DqS12sXVN8yaStU5FnQj0WWW7mPKdKMGijQO4r+M+8q5gBaOVdmvf
#SV49jPVfZKBQCJuKfhQIctWMwAVZgUWSiJ5OK8Xed50ov9ev8zNdhQI7SFZl4aXdHXQG0q8/j2bnxQXMYya7fVbKv/peXz8v7Z/e
#Jmd18bGBTwttL1p118kb6sKFFFPThZPIEaP4E5OTooks5swuVnOVEq3EIEGK4PhZ3uzsbxB3/LcI90uGtIRNmFTm0svD3eqFy8po
#M13bmFmbz5nFtcyYT6rMDJQXvo7tvCzat08TTqjib8PZ2ZSPH6cQ6y84JO2wxXSOsHhYg+YKgHVCmWAH+mCzX1tfTHgT4HgQ/Vym
#l8PkYuCIqgKAwbeDVDoQgXd7o24E//kxK7OBoe+gj5zS0WZGfmTTT1fU9MxX8GAk2ccnDJwciP3r55oPluQiiJMTSiihyO3ueCFF
#BcuCuaLZJOUmlI2mppOqRtSmxhltcpTfNJNg00ihL6I8ChlONWT49HAw86pu7RhMRzXE5T9bigkTkxp/V4kB4t2gFX7K75Pyesfs
#cCTvHZJQYWi6J3ko5Kw82a8NUlMPRrAC408gHx2yg+GY1t1kZrei9U1qUopQRZzzJ0ZXoYAhCrhXjHsMO4iXeguZwdnnM1AFfypg
#31Ld5/adE6Uq3WXRylI5cmUlCV8o7pOf82kfVO0/R+rd0SNrNzVZv8ad94cRllUQlzLfCOj9tBj4cwAEPy/6kXdraBVBD/BE9yaW
#QganscoN5K/DIykkjdg56jJ2WXgR86hjZRIecyJKOgY6LSob34CczFEp6ZRnSckF5zoxW3vkIN1UEh99aWOEDRmkhY0Xxw1herUO
#ReVjTs4zOhJ4ElEJEIFxkJF51nGSqc2oUDw7AbxbOxFFlTXs/KGzxQWfCNOZmNwR5NwR4FxRZuXdcMI/AXqszG1/nug+FNEEnwgX
#RLJ4ar1p2JdDT8ceD4jZkqKwxNVo7Z5UeU/a/yzdicjpaxmX3hUs9+bA+ahBTFiuhZEYQZW3UkYHuqAkjfUsg3seKHN4becK+uLY
#nT2JfcbnQgRsF6InbOD74w4I59XnX4Wgy7LjMknVXI55dcfcukMofdaF8IgKCahMRwWfej4NfJkha18veJV2FK4F35QQhHF2oF72
#F9so/JQTqPgWJjUj1urBTF9XraRRrepYV42tOnnsY2T2zY+yn6WNJcS//UEbMDaXftJ8zZUlA2532TNqbXn53tfwwTfY+80/S0XC
#+yMx74ejvxJtcZUzvIc1TvHPEz4OpvfFs5p8HFF3w5fDt9B2M9oRpK6YA5YOiThW9YOGmBXxztFtKGk0I7w2G6TBqu03l1UC25RZ
#XG0p7vpjO2zcjl2xoS1id8o/q6S+18anVw8O/i3aHWzMX2TA1Z1RwPDvNuyMuIWztH4qghy2NLmW3Df3QSBQXb2fsl4AsVXgY4QG
#PgG0fnuaKY/+OC8h9TIsVsFFGX3ckPpNz94zIM2mHwUIoitDGpRTwM6Ykdc10fJHrO3N4Jyk7c+O/xTQC7Ijv9er9hP8JUf/9KZn
#x/F416NU7lsjtzSu47XuOD0WAtS6Ye09I7nTEYcSPGbFULYj4vYJzXuSJYsHfYv8Vb9DndbTnMI+JGuoVRxhr9mto6eF7NTcifcW
#wosmqKw9D4hXT8+Uja+7L3oqi5nV6PREdLmqnM18HT7nzgKpJHceA6q4PT4HGlXJ50snJtUP+qdtm+QZC+4x4IGqcebFDXL1cHK0
#3Vylteowbf7vq/SmHuuCnOgBjmZhMamDU4qYV3kAEI4tV5tg2y0jgafpkI5uoQpiOS06zT7vL8FZLLz0IsgRGXmjyvr8uwsyL1ht
#1INd96nvE6Kjw2Z0kBaOQOeZElGCczF5QsA2ZQLTGNekO6v0kI7HJ2v3mu1Q1Zd9Ge912rNAfa9safKULoHDA4cg9o7Qlp5K7RjO
#2RAA5psa38fFubP2I9v35P0OnX9nRv9bHtqtixAAHALVKokCgroBsDzmuLvHPyMO7y3HLrdOLew6fslVy7Nk6dnU1HrDki0wzHvX
#cBTg46ACKQCxH3a3s5bbGTmvV06dVV8hNXBcNM8xaQsQCcufuEiNe7NitlYbiCScuS8J3AP7WiR4DseZFNYf4+CFbuGYsnzeDyQd
#i5KWi8g75gu3iyfaLEP+P1WU0ILYowFq91TiObS8sdJT9/Z4lX1jaSTO89z4imz2RMjAw5AyRiDdsYnNtqCPrw+h+q1SRXqt4Zca
#5pgfQ2cC+5GyQBUwI+4pwJ+aGE5VfBT7EsOP2bVJG1M5gSowIkvv1v+l/itRhpzD5wNXDGdEdoDee39pKkGTsFyLm2GUnlo/WfNx
#HBYD9ZXHjjKX2SWPWGKhvjFNWWRb2Bn8oQOxKOCz9Rl9z+DrV9zXad0gqNG0W1+ZQJ6fs1CDVCO251m8ROKgUCaDUluMBcRHIeQI
#psTPBOYoqYOpl8RtRjcPnFMafYtRm/SMggjmeKNuaIWN+JxqqkaTxpPJdV5oiqEkff9O+F6tX49CpkpvQIW6rmUvArqUaPnSdckP
#9kNnOXcbW8Uj1P/VlPHUybolmgYjYRtHUQzpW0C6q9+y4XVDEnw30/O5qMnTuLqJiHKBzAgtfWmQLBnusY6dCuHkmc1BRiSAV9N8
#NkvOYA/TDFvdBMKE4YjZp+qoK1KTvBYkDRMzocKK9a5ucC0qSj4s4Aum3NRIKgyq2Np+ekVBNdxndLf6iGzExCJaL2blsom+NUvS
#hJ0X26zfC4E6SQHK/oHWVDW8Z9gDASIIgM0Ey2yJRdVaxjX0t8sEdU3aolDCCnbsB8DTt8fSyILeegLi6mw0uqkfymgolx7kFHKG
#FsGQGAFwXp0imVn9ZWEGvXMY2j6GHwLeXolHwyW5JmWjcLP1XJTuP9W5LwIOIeNHzoc+Sv/3K2iN5tYEBw2cqJ/fRVePfS+4MuJA
#QT49DJhsFdOcLLZ+4TKY37cJgDz8r32ikq/uOvL15JmOWfvLgby8R6aMelFs2w+UGuqplM24MjHfQsGesLiY4EI4Q2gWQj3u4kir
#enU7SC+iekAqhqKRhWUtOr5xUSzxnM6LGKgMC7C3rw4ti20BsOSmfI6vVLcFxUwMEcFUsTOdQGT/g2U8s7eeTAv5A6Acabt0qN8P
#3FP5sg5Romp+AbhXEiCmlQo2TXc2UqLGU/D1raRBNYhJh/QN6FOvVz6YE58/V3r/yJ7/9/Tx/VT14+AbEHo7Apg/3GfzlVQ0ca4z
#zKYKoiAVKVNpqfmbdG0HyyyI+QfStCUBKZOiaorQXE/j6JVMAnoPnI0CJWI0rMCyv5WDV5iNaZYfc7bfDtgf9NSXJSr6qu6LTt/5
#YECgZBCMIJjYTAiPK30slqSW8K78ZKlp62qEJjOmSozpAEJzDjT0OA10eAMICFWfDsAztrmqiD1OMiJha3v7Gmmzrl+OcFexZyv/
#YFj3D3BOdKa5mn+qDJ4ez0y5DfysGwXoWj431wGvP9G0DgmF7dWnX/7nhQUs5GyMUahGpZ1kkVICdl5aMclw9sMCqH8H22NtmjJx
#kJmpLvoVuTncCfQJh1uwlNbmo/M8tsKKXE5qKu66uuoh0w7ixF0S1fJJY9WeoPpfmSKGh3TlCakwkL/KPvQbZhcD518WZH9IkhmK
#kFnfJ5M+f0MtwBSCXIA29OXTiWzB3cMApPIILsJcsnERLm+nV/YcCR3wTsNB73E9EkORmgRPt9ruJayDDOQSeO/OidMtZo594B1W
#4D0EgPxJ3Y2IkOhZvsRl6CzqAiCWhM0xMfccrMDRYlLt8d/nhGcPvvobTuDQVdrDZ0QGGQOl1vMEERIEVPcGcHIRkmRZyqISnbMh
#lD/Qv3iwf66+Q2nPYYT1sx1oyhSbR55UvE+1at/alS7alD90PvhjEnmUiKHeFlJscj5HeE5Tgpx7WioToNI0lSlgTAjagpyilNIf
#a9Q2ApQCc88uXuunVSMkgWGO12O0eUUOP9nsmUuAvMvAXhCwViZMfumopMdV7B9SEjmUMgufNPZflyO+Vx0Pk9cr8c27ioS2iOPF
#aZ/dh1lIKUgK9NWkBadgZcgOnw6ef5cfPztkYx0wMRY0ox/sW9uikyAyI6B3tddotYW/M9x3GjWRgZEUhe7uKPTlAi5z/44DqOmd
#xa7pWpKGshbsebXNxbPnv87E5+EYdJ4j6CFR1ETevUeFMcx8MRAaUZjOKt+Kq1eAUFncZJLFADlMKOvZ6ZD8fdy0gkmVqnzTdjiZ
#MiM2IqpBpXdfs7ZLeeI5x9Cyux3MQlllm54zjSy9K3NS9Ul44GABPfKT4qxj+pbsmOZknMtOteatnKVX9nK2O1ZpUndNE8DQDWpG
#JvLOzR2sIp4pMqEe6k7E0h/4xGd7IW43b3O7ckQcF9ewpa9p5az0NJ7WfPuQRzi2S0yUWHTyokqtgnpahKw9JxLgCanDWwe1hNYK
#IhTDvbUI99PsatBH3kI70jmzL5u3ZglM7Gg8/T0TtdpOvh1pS072Y7sSoaVzc/3L+Hl/Dtr6PL/fb1+GLn5f62XVnzYM/2T25lEY
#YSCwO8q2gqOcOPn2lAuSt62UZjcyWUZDt6jiz8kMxr70eKg3KjvMTa6mjZ06C8sa+xKtsHP4VDu6BF/QJd8KdkiHks1YnR1Jkc47
#efGyxTl95JEYEniP7K7aOwqMt0tstcUJ9GXFa1Y/CZ921+Ri8LJruQ91Lxvrhmz2ZtAvLQidpYuS1w4BHcvY7p9nttbKjnZmaiXU
#Hc/XeZWVX0NU2NZk5qet9g5xRPt37BgDu6XT1C7apawZ2o2FMGjv/UZ/owAtBJ9OaOC89OZaaB/07LCbPP4a+B9B8I0k0cdtgEX8
#GY03mj6iAYhkZrYJKPF/ekzyKFpSfaQqiFuW3duE9s36JgZZdObMIfbBMVd8HLvyr8EAzOdR6kU6HQeJvfHfMIgPHm7diq8EksWq
#PkiAwLC0LWXGPIfAxtE3jbWDgmu89mbNfWRT2MkXMUZz1qXpRiRPaJfvZRDwuJUaw3uUPfJteYjXcPcyti14hv2y5ZeYsmAVu0U6
#TVy4dyCOi1+jmYURoYbNl/TFfPEKjTZEhM4kD2tAyNEFwS/UQs281waerlFwmO0vfeSY3lDe8s7FnAd8sZmmm2SLWQIO5qWXkmm+
#P99mt+q3CU9wT9lcRxEnjDdDNHLKipOxRQlnhPgpc3e3yVQk/QkYnT0JGLo1lD2C6uOfM3+41Fs7DBTvCaB/WJhTa3vYnup6P8a1
#WUP+JTz6tmlOV/+WboIvOXQDblLJZAAjR1eoLX5HhswfDnIPf00kMqDpiTx9GHZpRa3Re75hwj/aK3kr9ryPYILFjcAPPkwfRnk/
#gcTs9rbH6gd3uuVEZyCMHSA0010T75fzsbGD+7PUVsQsy/pfg5oDrNY7oKpR5pWbUGMDkITjWbAVCMEr+Yo/0FyIE9p6/Cx63AV1
#pJr80EA3nrFsIeJpa0e06JdBW3tHB21FGRuGsYUZMdxs3q5ijBiJehi7fjDfA9HrbnG2tPgq6ZAqeDRy5pX4gA7Gw2jJmroSZ8W1
#1soXULDx+mBaXcqgWE+1NaTo9fE02jLmxdYesp+BKzM5eeSCGyH56flbObQDHWaakaF40bT06mTYYmwlyXxA/dTR/Z7R9rc2+dC/
#X4WfCfzoNFYn9B1Jv9/1pFKGY2znq5T48ICPSgpVX//itLelrjST29hzHSCoEXp7gSjtB083CzWGTrwK9GXFQ/DGfSAzQa21aQ3d
#WT06dfPdKJUlkflnsxc9o5ntW+2LUX1pwb58X5oEFLS+BQx5WXcklHFOwwO03/pzQ9YHPZsJtcOpN0nCmeDPJHZ+XU5x/UuyXGIY
#ruIF4mJ6iE5oWJNgCQmENTmvAqQafhbWwzglPlpambW2FymTETqlfr/LU5ui/dnKHAScHJ41OZjZbEOpLVJr2DPPqb/H2S3LW/92
#DSPq3MSNbUzXYbLCAgOMYRuvZG0raY6f2GPf4L+BOeD5xftauvN7mhqDt9fjzV6/8dX2JM9UrHNJPqW2DyZDJymWicmpCTayHOxl
#wPNx56+8JQIwJHMOF8DJWQ/uoLJwcZROiAI1c7/I+fNyhkxmBHZjeaGtNql9EbxG7GC6zmI9gHy8Me48gSewC/ZxJLnDWw5R9Kxg
#vey8NOvUsjqeKrLpaBHQVn5ncXKn/EnvVevrUG5+gEIDGfuiN7Ej/RFoGGTNCIKSOKu0D1z3HeqgC8PTjKqyj7LSmEjQXvMIeBOq
#Ex4kUrKb5xwIEswJGsCc34qgiN1mbeQutvutdShvcLlGi6IPF7jZSvhUqCniP+ts48M9iB+ln58JvqDFKBgqyfU4HAyMPaK9RQWD
#qLUb7hown17moMofTBKhaVGnxzBZWkFdlVJh+vVgr5Xx/PFpiH4/rpmiJtqYWIW9c+cg8GjyZyfwH2oLNh/Rduvt+/dLI98Sa5CY
#92GH6mjaAw38wBxIKFJLuG10Oanlw3Jc7+7nvk5X6qJe/2l8V1bMfCm34YwV8zwJsstRlLuNRO7Et7druUDa2mpk5AwQ936/k5U2
#N/m1CO1d5zil4fZQAJ7gqkWvCZUFXKPAMOJC+kJlH396o/XPMqvudInDRTwod8GSrp32+9SUjSpWhCoMwum7vu9NepoxzZaJeTCB
#R9bHt73rQeouXfdBvk5nLQEUJIzAby9fpw/BRoU2AwKLLboerhRs/59DI13vHKu+A905814H9jHXWGjVwvR0UiG6ISmb8938j5WX
#nr0NfNOPGgvLFTMPGDm2eJ91kLxrAJllzSr02R6/PHmNF5sgyS8Ih2Eendd8FyxkiWPfn8lxmHEnSS4KHA8+jsN9C2E/MjIe3v5g
#AWNJv8AW59Arm5IsmazWCVD6fFNfm/8L+m+5mdjeZW+4Yp6UId5mr/G2oOI9f4KR1OOhydElsR/liFJHjoxWeKzMQESwkvJHwAAp
#ziaBmUmsWp0Hi/qmlON4dxmhdxnnMaPTLmxXFvL1m6TRVv9vN3/DlkmazZo0dysxV2+jDK7tto8+MTrJegQXifBb0Sbyb6TTPWHe
#MMon899OKh1dGt6N5hU+RcAue5JgeS3XCgl5Ag6y0qylqFRHgvIu9jW3+b6qqevtsVLC2qjbTNkRrrfqxTDATr2ORt8unsPH2Qm+
#3x8138AvDVQRAZQQpWkf/8nJR/29WE4mDfJsE/6NKkCY98Mw8Z+q60c9nA/rD21le11drpyo46fHp0LyiCNWtPV4Mz8LRLPI4Lu7
#0X5LqJQcxeF47NQxzLi7Bd6C2xkpl6WhGy4SycUH9T4lPgkTzxEAwXCcnx9he+x95mr98GpyAb2vV1bwi343gJ6OHo+PR9jag1Zn
#JilgieaS+Y990R6BkqSimZQcKbK0A8+BS8l9s9quUYtOWWBCa+ctWy1z1+HXVGwhwGzQ07WH+7rp1QfJc0qC0ZuMNKnqy1ZGDf/J
#1NFZ9moQSzerFSl/28H1udr3GEiBCCfMcR+R8iiAbwrjENb+Q+/I4uieLjfFNjT27Bv7++XIh0sP9SJJtrV17mgsO3Oc/WimraJM
#prDEJ3engNELJ7iJjFp9lOAB31rSeEsNXuc8M70tW76omblTq9PkAk5IgztvhcZkfwotO2SmXWvSQ8WWUvQySikUenr4wHMk0EX+
#eaRrJHwhWbPVIZKO/gKmMQgC68/0ZkruZVUoQtIJQFjZPb/ftu1vfY9amr1CC1ZT0DsjYt42HAU+Ep3M0y+xppd73OZuRjTSQyIw
#wg83EGovhc+OTxR1MpYeHvnhoCs6sXaeTfqYrUWyD924qxD8AZATkO5B4GcZqSvffQm6NbwbaICOW5DJt981yNc1V5In2PvFzQ//
#Tthv7D+Ph+MGQut6AGQQgn6BsN4w0KQ14Rb5yceN4W+KH7iVSRZYfOydEmqOVpIyaOqeYECLht7SrDEvq7E4APt6+Htu0AQ/krx+
#8j0X+Mk+hpG1HMIJWsQTcPwLNYLjVwTOd4B2eknBP8X77wnlCa0c0uPfFM8HBM/0L9z5sUGvuBp33Wvf/Ccv39tAkbIme71N21u+
#gfS8irmek97TJx31vQsgjqCvRXo0yDk8715yeA12+4cOmpW76zfUvUOUuTvtWj73u4avgS+/Z/Tc3uTsNGX0ozvJhp9/JDvRP0a7
#vXZu/OLucd4BdMruoY9NdoZ8qEslsj9yA8oTz+9V8Cess3rJ6bFM6D5/jCYGF7Xtu8gb/Exe8kZ3V4uWn3bOr1jS/I7CnYjokgRm
#iWJKETkev08kfJhBuCoRF0nMZcRx0rpgyhT3yJMKYC3d+SxTQ7IrO7VjPvIvHJ3dBxuAXppUQPt93DwTIN+zZRqtZq6aOlirp4t7
#OJI1BbydylLXFwSgmhrr61z0GuhVW1vZuBubzizqI7kwkiTHPEYrIx8ZTcxa8VWj3V5gNZzNUWPitLt6eRfvyz8kry6JchX7WCkv
#Ucu7Zrat+MZXvRT3Po5iFOR7b+OoPDy1V6jOF0Jc9LcPElaBp1Lj2KUXZOOQLG71hhbu+PIBpHsBfOAuWu2j+GRT77CO7ffjT9kG
#LOARGDCqC/X6yjfdpIsqt5wcTVPY4Q04UfWUrODtNz5IWLAyK0X7/eAO8tcFoONXo0BCh8tAUgURyJYXQKGCR0C5IhFkA/31AwVY
#yYMLnBIxAZlW2N2BOwTWM6sLbvb7CmTyDTSqU1oXbDLurpssE7sFujcGg/k1LUjJw6JJhKU92pb7VkXfb1od66ROj3DLpZUo8SVj
#1L2UINWALbWH/6i1LGPKmkZfVimswWM4cK04ZHdqtrN1EjVU2cq9AmI0OiLhZkKt0KiZYCeseHy4wRsi+XYsFbbt5kloQstTV2Cq
#a2BnAoMyNXoSvIwQWrKu5J2+Npt4JAAFGz4G3CtvFI3rPohEKlFPOixce90HJRmNRiLcJy3Ns1MMNEYv6zL4z7rB0Gnr53x1u1PL
#qeNI9NJ0Vs8jTSiVSv5NkIOLNr1+aVydTC4R7kGDBpIfTGHnZwmJRuqyrisMFQ4gkAJSqKLhTqpi0BkEK4phWwYxwp3fxpSk1xmH
#vnXbVz+QYZSF5Xpe3KTAvzx00BsRROE8KgJYV5cUP4pujdo4KTPzf6CFSBn31xdZdRq6ef0EsHY3isdyv5bjBytmy5Ri3Dfo/xzI
#0yiZoXXNs0E2LaiXIh4pSpCTLKr7+WKanHCex9Nwcx7UE3OZbZ43+V0ywwheK2ZcI9tkl2pkhg5r83cqfJuHaJg0UWVYOg4+yLKv
#0DDPsFHqPn/+SyUcTTeKJV1dN5L3xXEMZRrDXZtOuQndqu2j5OFEIuxsu8C2uaGmh2Uu01+qWb2Uyb8rHFDs3t+Ob6zrasJ0y95a
#WN8Z6/V6mHX2ItrbMfKF9t8R48YIWmsWtxazx0Wxq2urQFN2t8er7vEOvc62/E+H8QIqTt8GhfPUApxGL0ktWc1WmWx1MO1FRAyS
#oQxSZCkmeSIBJbUqPnEqoMRQWEkBciOowKCgNB8dCCTIDCYFBgWVuZDkpXLTilKjJeguVMV2EaY/fWLqPvNbRmBmPBpLmzWiFtS2
#VxiFu2IFUxWBjbEZIxvqY+gGGbadW3vuWypn27st4g3B9I9hdU+Ipe0XHxwlooRWLygK4+bWmtrp2VE3KKhnNcyRibfF1kHlieF1
#Fxqp13+bqoYrqvCqai7/lWEVkyuKAd4D6gETARFXcZ+vvILQYCQFhnKf+cKhWpDw1Ow8AGiquKulDO+e50vpu4QyLVwaBqog6xFo
#FUGIFWPVB6xAUM585HwysZJ5ebLS0AL5WJxuX4IDkFO1LCdlRHPuMArB5R6+JXXOv0VWWZk4PacAzIkmRS5OXUcAHw+pmjvqx/aQ
#oycmwKPnf53I9/9m/k/8z8YWhtZOhrQOpi7GFv9PtM////zP/c9MzCzMLP8H/zMjM+P/53/+X5L/3f9MjgMA99/dgAMAgGzw/9L/
#7IHdZYIT7PFf/TMNIgTUrsgoFnSQ9//QPoe5/Ff7TAYeBomNp4i6NJNDsM4B8H0vG0wRGAOMsKgTW+jZZPD6FwZiN65gbeAnVEoi
#J5gla7wBLSIpJVVNQWop85Na1KzzsQpjN7X30I9pk/eWu1BzbuxQsUFddtAAiicQbWgXzTN8YxmQhlPQIO8UUdjyGVe9+8//GOAc
#2d9IvFzB58AfFWoCSoNCrXlNnMW8ySttShJEMh4lFnqARTBpXwl1mArPIicSqiIc2KeiHbRG0zfXfYm/s0kHc4uqYIbJAqBGsRdw
#ZAAYWBvzzhGfLjwfZKyatYUfibm0It22NaOUMShME5oJnEx3aprQ+xm8us3+zfkINKBMkhVZQ0AWhBHnPCNnd60DlU2cwZWj3hiF
#1VImpAG5U0oW+A9CmrFoMQtotDviQ1Cmi/YUjHGOv/lJV5009d2GLwVwq41vZW0DuJwBmmK4kJSSsw0mFhDgzU4wV+QbZtIFxvZk
#s2fHxXe14JLYOGQ/+frhV/f3r+6nasaX2/xE/h1EQXY5S0Cw3e/qksgkJns2B579SzaAXLlQO5eoQn6qrRZLA8MkgqlytHjy5E9l
#BdU8nO5nsdMaP3W5YZlWm4eM28G9/+DoqFqIEQ0UvfKYd1DJSCilkZvyc6CkmRavx4xoSVp71AYzlda3i/bt6/paa97raLna/jie
#eMZPuQ+27xrb8tq+j3A8MZSAiClcAzMwfP1vx5UbZ+mn7oshdFL3T8pfFoCZAI0GBgUm2vg8qljiN14Ac7bp2JNdVG/gMGg5Zuw9
#tM75YHEcFJ0wDbfBRKiIzKNqDp0NqHSiBc7xUrkY4LUH9IRUwC8/m2WAgSRfG5VMyL4uPH74D54F5TQXXxvSpOADTQev3XkkleCB
#VIAw4lkvmiONoBxVXuXQ0rziV0gBFIGFRBUMH5CEgipyS9kUoVzu+7mpDwY0NO8sDDGyBKbO6mWBXCV9JwQaRy86HuHcUxWGng/4
#I/rYtcLw0y4wTO/f+vmx3CKcuxds21/GjHZbK+3e4Iz2UUOt2wl1hmPohQGVxOj6u7Sm0UR6R7pPC8U6BqyyPprQIgmZL35a7yjp
#5iK8T4u/VN6znv06ac7AoC9hC79b45iXdwuvw3rYAu/ObmytonZIyRTtxd3Fm62Fqy1rnqM5CF9ZiOgKjUjxGVwhsFNC7PDclYIc
#MtYaZVhWX9Wzsa6TiTirkE090MOH/99Lk2zvU0ic1O1j69ow3Tn/Z6UWfNeerp0rcOmW7oXRTYpV5PfspWpEyE/e4qXNE+l0y5xb
#5HS8daINphxSkeE2fBzDdEC6iN8TL/5SPPtw0xn/eI0O4EeihZzzvgVImrzOzAXpQ3tuvL7drxJkN8i+um8KmYA3w79HOoDeErVL
#UBNQTr5NGyo7f69/anpV3YT2EjNSrCuPOtu481KLeHz4quyck6TvgclsM9FFplQxfyVmGe2FMUessdtLuRnuQgmqmUgePrjGPdtK
#Bdg7r+2AjJv9+vyxZink73mX+7O/bWvi6sBcczzMUff7s8rDsYhc9Y8Axir7r3IrM1yEgbrnROgMdqs+lACucAbmbmbmrusVwBw+
#by77nsZqpAmJuDyiZ8wrMtqq9qo9uq4uVcg8+PF/sb+TkcTGSCyL4x4ZAsjMKR1UPdWTqjLmryRfn0LF4q0D88LQrkn/FgCHFMpv
#hfZJSpXlnEQNv7hNGreF2vDJMUUhDsaA5yJyVBJQB1hZ3ExJhzCJzT/Iv3klzjpVbwj09oxnDVCPC5ZD6mMisjwema9z8TjP6H8G
#98b3s4NAXuR+Q08ANo0IdS740gvDyAiWj1OFD34r002qNJAfKhy07OPw56CdXSCRZxN5gCngPDQHsuuxzSTiSSoBY3RlnUCWsMht
#SrvTDBVgw56FF95sKVkDxlcYtszael65z+uJY7lOg5PkKoIgJXBCk6cDihQ4faVSywCcBlTokhOblYm4EmxEFKVYWkr82o3AxDSq
#UbJZMIsbj2Hj4akWXm9LOi/FStP4UKCSxRUAK+fjpF7KoIDLF/Mpb2DYsnukpMqhLIijgaLBIsFa60FGKwFRmZUTbJNbs5helSZ9
#pTg4SC/qjeOVUaqW6rmrGGCudKlaa1FUCpVqdByI+iKgYaeNyj2DDC7HUg8AFqQOXIEDV1Aa/rUTWtjsOjUSxgmMoQSoQJNn3QQZ
#bTk9Dbri9szWuxopcvSpjFVmY6/mq07xVOI5dogy5s489h8NQZL+xkx9qkqGEh53SiGkkVOq3kFpGJKqVchUCc5sfDRmDKTuoOWN
#DYclv6IGUaOT6uXOdE4mPqz2E+cbvJDNSPlMJow7DcvYgdM7tkUR9IOqp0rQnQbCe/ui4K3mQJaIVN2ym9JcSO1+q1SBWzqrhGlo
#+npTCtcWAVXDRWtcHMl7ZdcOoHbyq1akAeJw/bsrQatV/lM1/HUX45hui0BaCGVLXgplayYthR4hkXgrxpBYlvLiroh3Fi5RkipM
#hKosL46UqjwXGNuNkCQhlhpfkFxkk1KTAVbNcqP88iVcq5ZMAHoZZDMiJS4GEVcSJWtHavnJXZDLnt8t6eyUcT8YFixuhKJX/3UI
#6R1/lowvTGfBnJxYDI1uB6EsLBdD3pnLJRr4OCna581+J7T27O7BcF9KUilSHaBy3unQiiGySnpkCzeoX157pahloqgruV86bao8
#EYvl3lrTRTYU3L+ia3iI/+dACIFCA5bcqkcJIAuZgk+Bw3Y+5kbKMxXl/3YvcS5euIOqxZXLZzxhnbRwzDG2Dm3qZJvAjZdbZI2W
#mXwdXc0Z6TRehMZsFP6zKQAQaCp24HCNZVCpRdXctkV1jVS7dMofxqmZU3++XQ1NnoBGiT6s+xaPK2h55P5kuyG45mpcgyBN4DFl
#mTI49ICYWddUl2Xyz6gPfBGd1B/S38KIzGHSl0rKinxsrLH8ZEReyYxOpYCoWvwuI+sM4SFg4fSUPCNg3mgI5umQS1/XUey2PicR
#HJU8s0lFVezwI4XDsUDFmiDqnoNUGBSf1xqIs6uTRalDTC2VkZU2Dr/NvYuwJxM44hhCxwoqF4gTEk0YFlr4cD0pUfBnx5uoMjw8
#XDK+OJuISlJRkNF2PPwiW4ydV5nIsif3CHMCMPoYQMyJBtwZghhjcAGnkN7X/zJIFsLOOtEr49pKeWfIBX3aIQbL3cgNvOuEE2Ve
#kY5fLuKm89C3HGnLa+KHAfzg3MAJgghO+37LBqH5XYe+SE1+1H/jNk/auJ4Dxo0ksfnTO+oDOCusPqfkibMzFrNsszik+wvwUIv+
#fUupg6kEHrEoW9bHDbv1T8HmHFIQwO/fcay0xzO+hEFklOV3GxIbDsRyt8dTBWHv9zt0MaoovWily4bT8WRSXQ3ff0bm6eLJc/yF
#JbI9o/5n4phw8IhoEdYOU1tBFEMK2RdVMiIuNzJW/U2AyN1wVURdM4lRUkUJnhcS56Q3QhwCOFVVEVCU4fwBf9A1h+RPJOJDJZ54
#fxESQkxKCXGzjJxJQbpHJ9mEDjpbof8fO+8UM1zQtlk+tm3btm3btvU+tm3btm3btm1jvn+6M5N0evpgDnpO5qqDu7KTXZXaqZ1K
#JSsrTsSL/D//Fe2C+zqC4DR+KLHPLHyAgJUgYaRCNFJy4XUFq2pGUTuuIkxkOJGBCVZJhGTUItazI1MHbQjgp5ByJRPzoKc8Uwh6
#9wGw/vsA/4hqibsoEFJCsEkxC1KJi3RGoM0xAbqHqaHP/+lOVlSDk4QdYYDpa64wMaEt0iPPbnIpX/bHYMGo3980GTBgwIABCxAg
#QCgHW0yI+D/f7PCpzLJtll/0MDCSoINVhRm6N4lUDEnASBm1YVXDyT64Dhm4RRrmiTkRQYSSlJk36A/8MlYM6J1Or5xcaZ6aZvue
#IqMwiZaH80LR9hxgPpKYSiI+2LDeGidyUVGH4MUkrOQvLLfFu/AbyIiZUkrsRdqbUW2ZpjQnOuZ9yCycx2HCyDxaR/csrGwjlh1g
#DpFSflhcgaCC+OnUkLUUAWtU8B+wT3wOEbyHWnidYcAyRMkYYEAncRAAiAYwXgZGuFQPHqJ07asG4wQDiRTkCEeBWYFVQajOkssD
#a+szQX5F4o8p27BpCcFRq1oVZr9e16v5PCCf8c/ch1/CWMEle06V3JFVkxlY5qmhl21jAY4Bh4EHA/AHYkXKuFY6WUucc6XvDpjC
#1wb4+toCBpFhHt3z2115mot59RZJCBfI9lYWCdjz8CikQKCbnYoFAl+zQYyNJW24ieqPtwLhJEG/i+iD36DdQ6PGsG9L8DDQqE3x
#khUlOc+UfprOR4oRJnf5Vh8oHn5aUMCA28gjj09jnRDyz4W2yzO6jE3PB8efA04Kl8eonE5PBzG9lr8ryK179Sb44Gvj0/GXofRu
#r4e068EzbLuwttH1kgltVDuyCkrK+Zzcygs+lhuBs44Rt0nRAtSpHc2GQMxw8EuSYYQFRYGvhggQQmCBEexnwEasLm8UUe2/sVLl
#HfxhcDIAeE747fBpF7624fwLjy1niROd6ft+QkIsR58GzTYe7MAzK73HYoGUM2u+J8vmIY0O9Ky3I3x4/yNl+FwJNz9ugiDw80Aa
#Bx7oBwqDSK4+yXtDbgcyMCg1WBjl7I/kcdLNfQmIi4RINICYaRJSgOzep3OH5BKkJ4EeCslZuL0EXYiycLuVqkJNl0QQsu8ZysDL
#UHlHIMAShG9CzwZJm1qCWtBffKbvDwHoBGNo+Kn7rLsvc9wGGdX/6wT118/ze705Ap7Typ3Ah57bzs31DeadPK/xcQJB6Efct+IP
#Ax231hxKOVUtZaY3RxW/mzH72zoJBM/lMK7zceucvK7H6rKtX7Bl32lcMSaBpOTUhsPhdBx1JnYoO6BUqEcoaHYpFFliDnecxwvb
#/rcN36BkioSQGJ+YoLy0SHieIBOZoZncWKlQIdXC9dXj2q9rbus4S3qm+zrLvMfLPgv5hvMwKF+33TBPpM/TsqMOHf1vkWqqphVW
#NngQydjBJPl6XdmhZDEUGhvP2+PhdG7M1ZcoBBJ9gGJcoMIscmwsiUwX7cH9S3eqpDgROAiFYVyZZM+1ZHLGULl01KbFKPlrywst
#b7ni3yBli5yQQpsnAAbwI70BkMwXYrorOcMm4LIzAFS5RRk4IVCgAUajAVlHC7l1woCP6u7jB3QO9W5EyFwsZKxRz+mlhmuy/lSK
#l+S5BanRWKlFn16rS5ZphveJb8x8TMI9IiATevASJ2RGrElUJBJ+IOKspg0t0VaS97g3qTQj4MG4SGYWvO5KM7MGEvuisIWE4kTH
#rN29ELWRles2KRV0TNZShCKT51AgwBXSZ2E33Pmx5Xu9UtpQFLxSjmoKeC+TcctpQcWyjSqqMbZAgfAdhFcUd+5tIwCDdWboDsuK
#pkpqQNg4M2w9Avk8FrJ7StSq5Q7niGaXv6scl1IvCEs1EfHs/SWqB9evXL0fA0hFEZ95ZfRR7E9duWLAH2zBgzs2OuhXQayGiAZr
#ranqgROxLih9d2y+i41QFbaihivPLneeVVRoobyJnGPp5CwBaaDqWVZh1aQ+OcUul6iNDVpgYDk7sNVD85AsGJGUUnPtVX4BXbNJ
#QsjApQ5KhkFhyQJtseYX7T8d9VUOr2k150AfuRNoH5Z76dQcbf2RupQ+OvWBb9nPbwbj11i80Y6uiYsRGfbpCisqT60WpSOShGOu
#JJgIcDyqoThprGwKg90gzx/XpEhOOHrbxU9aCteWgCTdFc0eQxQV2pU6OSHHpUhomoJZbIo2wfPriFQVK9URZ9NvzABUtWvKGI8y
#7csGfQa5ZKjnIhWlI4C9/UPXMctIaxFoxk5oIp6x2U94pT6dlEi3pZVDmSOLseZPEeHIh5rFtbT++mcjaolUBiJjmr/y+WT2DF0L
#ycCs1VvE0qxeWunEnht65duyD20fJGIjMdcHKpD4OzNGA7sKg/040g/Jkep+Zp5Qj4jrxoJE0a80IHDNKyToTDCzGO45O2+eAkDG
#WrCuTcYIBnk8iDWIkD7RVBlnIVs0S+h/OHrHiJqW8Gm94zrZr52/brWdwGf/SC/tV5rmA614eljmsSzC+xKodX3smNY0nM5m3qEE
#I3nHIbwqamkUrd3fcydUJK80QMmoowfKp1ljAbUVjLFXnfXwLL0tw1C5G0VzonPTm6mjjOPCWx3xw8ziovbZoMEmc10uIciBUjSl
#1zTZqJzlwupWLbI+Kc04DXf7//Ro6DjtJf+dGNjnLFY4amShBzhhpuZ33wR6WWlpuOpNlAsKzvcJwkuGHDIHB2uZRdJz+FKipm5i
#dgbZcLlTxYG2gL4GPojFZ43nTp2Cg/SePJcaKMSfz6BE9N0ERl7IiDMpPQYICY+MYoGE6UQ0X2Ka9li1HBhNsKMOwPbhuetUBdXp
#5MR0TVKuACee9QWXbaei4YssLB1HzDKovjqdVoEeoiVn6xZJS5nA2uuwXq7uS3FQZ4rosmUeHcC9dpaxGyk9rdH0ZhL5sYDi+r0i
#35S9WgWy8F4GIPsMcDiCZjWqMkTakeGKGls2SByOVMgyDNfTOK9+eUqOVPLgENGs5812pcKvIcuuOcVcekzbbh/KRTkHNCl+ThXj
#nnljEPUP00kS0ZjvXoL9XAQZjebWULAcbq0XU56tfujkFst6FzLb24YOr3PW/GpkxVGDiVAzivlQzLR7YQ2v9a2+oXprRa9RxdjM
#gts+tbWT4iHf1Gw6wxgXYfJAtC3xnAecceJQH63ixjZIrnpsitiLI2hIjcSb0MX53ejMHqOQ051xDFCKuRzqOey46beWGDKt9hfZ
#wcbagliJ8dKsUuitlBiGm0u3TxCANczvW97pfKAtl1jMx5B0VNQedAOOvXvIc2DvrKuXKp+LlFImWle4pROS1D3I3/KwSdt2OifK
#Chtf2lt/sDt56RVPCskc8n0kLBLMZJ0F81bm0DH6QJrKzeNPERvFO5iFyUVeXkoQ46jRXVKD6a4ncfwo288L0DAbrOhRpQTlfrWP
#qtnskitKlAVHegmbjL7VxIkuOOgXbXbxHAb1wAtro5IDObYEYXVqjfgnnnUEOZ0IOdoNCW/+XnHcCRx4pDo+2T9HccV9VN3wJ/6t
#aO3B73XHfan/QV4X/UEf8fvQnUlPJAS6U0l6iNVIWqkCi7UgDk9ICyGm5O2pbl9n3MF9ZODlrfb/PcLvp/LR0MpS0aEVWcbq2We1
#rTHCRqyBkw+or/MFkIk5tQe3cHVAFXpDnRcpS0thmwKJ2TZq3Vk7KYd0u+yGGzIAR5mOYKOArZbWmyq+L5iNnOaJucundNaUexen
#VvnVqmynivJCPeXhgJKDISqMkvaZ/V5rdmo98BGAzWZ0CT5Euh8L0YBCB6Rndva/c6LxfPW5doFlTDxXth8v+lxvnLn+g3CGd7aM
#CF3JgHlMenUY//o5EPyrkF6722pKu9u82qqTbl6xGP0Su9QBD+CKTendaUARwL8inELKtTjoKE7V/PqhCVP+YdttR2eyVD6fpls9
#0jNwM6zTIPS1UcM7fWXeTA2/yfLQuJA7KftZ4PQbx4bFaEEr4JdMRI49xdj22kEUjHe9gV/sbyBGb/ybaxtgZnEvBz8l+5eqLpbm
#K1okwNDt7kxyA7wQFHbeTPM24X6sFTXvkyCRiHKwexwLAIx0UXbzPdOyzImRwAvBiDBJhrEMXJmAFR0/ZiABEPUQyqPgOxQM0AS1
#gHLnc4dC0qy1YSB/kjP7yJuT8hbKBBBDBI3pa43pBD7EnidIVzjuFronBgb5c3Tn5Kw+v0vwdMcp/zQ9mzCbYPaO87NhWOzeizL3
#vigojFBUHXHfIoVfeXxTnvILBxnJFUKkcLC9/EH6yx+cS9hMI16a7GaPfGD1CpxJgKWFR2AelhQ7t1x0NrhGVktdyR9dVjnIh+R6
#ZtKTpoSbfDsKY6++DUc5Hjx2cnpN/jz9ewGyk+au72lr5tyGngjJJug9f8X8MJFbk7tWnRFtXgv/C2C77qbaAfzOBbtwXhJgwqtc
#x0+5HztKX6kqVdKkHDgeQ6UY9VaCblfm8GSNgLVkbZ+N/UEcQUXGG4ZJHDdljYKTOZg0NqKhguWYlfWY/SLANLB4Bfz8GSQm8nNe
#fKHkQESRTuf6r6PEYKs8wSKyZbPlMFLoAmsiEw7nO0/z+dM3w4VMsKt5q0eZjqt6jfnl01gpYtmvTO6p563kX60e+AX6fR2kEa0k
#3cgUb/HMaH9AVDryIblDQQHGLw74Q1NNjqM+92w6T5NDk14fUGGW7K2/64NdNbWeQ6nFVZIPn2jV7UxvHLAbYF+48Cdzi1pRxQAD
#YCtkgal7R5n/lGgmlJSKRrrKsgXBBGu5K+8ZKtx1yH2/XsRXTVfWy317VorFQXpSVs4YlbeJW7Gd7gXu1gkc5DVu2x7sL3x8U9Oa
#NuFzbs61/IXPZ1nDLvGyLEdxr1LlklzYkZuxjcL4sfjB3gkkoT1IrtBb9ytLYugK1kXWBWdRUdQIqraTXju+3YRAMJQD8o6KU/+T
#ceyA1zmn1MpfyepgISbHcLnSPf3Qa0iJ2HbClG3FO7SqUWNsfXK4tpSpRym8gVbNrTB/h6oWygemcoWbBTe/VUWn5ELmOdRm9a9M
#haJCRxETKjh2QmnCOVczblVJ1cUtkiX28FXaEapdd7UN1q9OjjlDNeApZmbf+F4vBK5vKvxR3kXIi2/q5/b3LW/CyhV2LqKo80+1
#88v9zDbwHi4D7mf7X8lFFu+Ll4xuHXxv2NscjcSfGlVOhLx7+8pOEfnq88IOgbYHTHsU+ZR3UWOadO2cj9Qr1n54zG7Mu1iMinLt
#SjWyukplkiCBFZ3axVbJTQbmilYNilFnWr6fn4QhpV+xUaNAvbi/aPi6qfPVkvuRlgayJUL9i5LZaUPuzd0P+MD36oeaeBXwYYwf
#dkxSdNM8OGdfkl+KPfrzcXOUc5vlCR2II3QkJKVrupQYVrAQgpbFokjaeJ0QjFIRySVRS/5T96G3ObNrplRkukyPLfkWjjlCZGAk
#mirvkUCTeoUCnQAffCaQ3qkPIKJEUGLFU/JSxEl22twueyCJPjEK5MO5z0dVdDyUzw3fXS/puKe/Ar7QM7vTG9+bVk3rAuzJoGNI
#5BOqMDMUIabu+dHbtRLvdy+0cP9v8/zOc8JAmC/tQs/603zTOuyFRKjGbdJtFM8uPQSvPUvnKx/vabcalc8b/6EjvoPwjZxudWNw
#UosmsNDdwwQi2KaKK1jeXsqoeNo/cN2xxAHtxMIC8XRL5iGrJqshThbimFo5ySP80ydaH58SS2/07rHaE7yQ3yDNDZoCMocTvr1N
#WmBCsUFl+Wi6WDURfa9kgkezWvkz9qcPuXocuE5GasFdSkEEYlb2JajFRc94qvBypn8H0Df2lp6ZGcbTG7JHi5XMAoK0JRKQgtRL
#bHw4kufIm7zRwQ6gXYZiBwjf9WiDzDn3rAe7LQ7CiTW/MLaQaRVUisXuHVnbO8oLKhvd/8Y6GtRs08SmfpvBUBfuit0HkE9/f4G7
#kvBpNfG2qbuKj+MKWj9veYW9YGwqcsZ/NvVvArkM03/NB1IWp7whDUcmg+vvPIRyP7UDYxP8YJL7mnpPqp5C7iIMq7+BQ7vfNJjZ
#/WoVqqwdRnrBjKMTJ33EgkwO0OVq9idFKzWcnE1xqoMj6JRyGdphpCmR6gfaIiOtTJpQ+CnMJqwM3D0MSKbpkKlCwcyjNrRoIAqk
#NFu5CaChf6GAdjYaJ51P5eCvEfeJUVjWAqUD/uIc40pkfWUXx8yVFu++e7G57QPmIyIah9lhk0J2jHOq4cC4SOXKj4M/6gkSa26Q
#T1mDQ5sGP406pon2P8FflwyNo2jr9wbOnTlkBp5VobVsA76UR0P7UERFfr5d7egwQNhMoH9yrQGzSEQ7RJ2q2OVz87LoG7xJgWKN
#hboAnL837YogQ5brkuuBkG3DOECIuF/PnYh1FraKdBW3CLMPGDEipZNJUywOD8z/NHsDHnvUGV7ctbK7UpP+Mf7nFFvcl/lingHN
#RWgfuiL1Q/xNFBXn3ZuJtZSwoZOjoqyZQjw1GbAMTGr2uhgmiJ8MzAyWAqUb4GXbygn8pjGS+jse5ZUnlX8ChcJKZ8pqcP12ZepE
#1dyqZ/u97thttBzvGfRJK5gQHWzarbUdbqXb+LAjYLltv+aQgW7cwp15LZ2uZU0L7ppp4JPJ05jPjZkLY/vjZ4uGTHDMnQaGvcMq
#vdKSB2nFG+D/lvV2h1PO/Yrse2hBdlcACTN/MtHFFRFP47msGV6Nfz9aPHIwHdYgRUa/TCiMwLkweJeHTGWW1JyDxg1WOi5KsmDH
#XJckSu+9Xnt+fuHVRrmjZGVRCsWkzs6RczyzBlZ0cytkYibGZtOlHmqRtiLyEuc261EZeMbRxTScnUJziUgD66XBHzpSs2QBb940
#s4dByyjfXtv8LJx5GKvE1zLH5Xa1usxgvhjSfvtneMB+3augaprEW4SfuADp6/kiGsyHAIJf1nZ3qXPtMbv04M60ixqsAXxS20N4
#e7dz7yF2McW5zxzHWgU+nsUqy8bz6OqiVqEC76jOY6S0HlhfXYDX0V0yqdf11P31PMggOBwiXm4oqSH3zmcmaNFW3LXlPo99YzG6
#bNPFCzI2x5zklkdHVyoQVTZORtlbo6W4o8CgOqpt3kGw7FvbvV1jk7GbRYJWB9Y6uzcpGITGacbzTfl7JclavRzMudrb8OeIZLiR
#LWQDpMbBcsaeI+Q3GcZDOnZy5h0iTWYs7T03YfjpLozlx7beLTj8Moy7GRRKdEgvHVdBnBYBYgn7yz9LNIrwFPKGjDusCYTWQl01
#H1myOnn4ud7j2HO9k8A/3wYl3Jy8gW9myjbthm6InYywg6j7eownuuEEq47oflEIyKzkFS++WxWN+VS2ifla8TSwxgGjw3y4taQP
#0/ZYARnrYpGDThwJiL9SHe3YM+3Ll6Orq5eTORGV6KVlcFPrOXj1V8M/1cXD3Bm0wKbfhtVqACHbyVEsuVYcoZugx3p/fG6h0XYF
#Eo/Ufo3aB3gV328iy+hgiMwWllrPaNOwOpsaJ9akKzSMRJQuetbGViG2jqNVnSDUwUvzLpcExp1+NjkLkSUsvW5RkxMbkCPTFhxO
#KlKfzxzMgNFQcQBnLhAyU1AyKoVfbdfwr8Zg9ULWETpLOIq1cIhbaqlo6fv0A41t1jP5rT7qh9azqIPcH6g5xQrqv42H4+2p/F7P
#2bwcD7YTHp8CZIEpz4Z8jNukybZ1uq4zO3WbugN7ex0Ius+fskVz4mNLJ21tzts8O7jBgDqyJZL9svy6yql5wnrXi40mW3RL/L6/
#/u2ugbaNq4jSJWq80WvCAGZvr93ZPN4j+z79k16lqFs36rPPerFoUjz3GKKpM9/MGrApVb4E2Vjj3+lv/h0dkx19NWcLjFGHxO/L
#aqabxLyHP5z01x+ODYh3kbTmf0kJECsLmA57+VobuLHGtHUdrE4wvIlmxv70TPUoWIqmnqZ+UnoLPn5pvi3f70XoZX6YdPJS4x/m
#pcX0pWWmjb1k15jlsETUXyr9siwRv9dt0mKdYbhXyc0QKAVd1TMZnT71iBLBSVM3LbvzL1415Qu4O6b6EZA+cdOVDtum3nDCzVQy
#A+BR3rraLSQD7zz3wx9r7ow5cssVCTaS4L0fyFyFsD6rKeRdkdbCywD8BjfL8m1r4zWgJ4S6kjC/tvQxMc1GmqrBJ7DqOIEpzbk2
#KtAWHtuZ7KG/6Ef97JR3izTxkx8B4X5k4xTfc4rzz4LxAW4/S3yelucXvmW6bO+haeF9B1QmFBBID++0O++C9+Ef+ns7Wxw1+Izw
#tHoFHsmz2hbaeqa0mg+0fSis9L6YYhMNeQKHRsYaFzawA+Gnhn782YE8Kpj+ib+FhbJX2z1gy9GjW4KASRCy2G+ZCqkQnIahIXS2
#1DBm1azSm9pUfepcMBOyVg8Gh77yg0yVBpFX26illICYqBGJEBFn3HAoy+E1VFniQRJI8snbBf5xz7I8yeqTYbW5VIp8X3wKmsx8
#4wTF7cnDfjxE3pLa2CgMiDdHhv2fCQOIGu4gzWiHWaJ/1wR/vSsgX128upANYXLeQnLzNuWoxYaMgZuKmk9kMoAxYAGB9OTxmuj5
#kl9cN9hgBQ8HZJg8MHIjXh7NCCc1ZPTI+OzturQKUaZZ8AYNSdyETGPIcpK+ZB3bn8lbCAysm7rEnRXnhn5F9bfI0A7mwZBM7HMt
#sfGxOoHfEjJEWLQEXhIM8G7qvdVafgmfai3vJ6QjUC9i9mhHXxf5GsQ74SbDwdhyKV6s1y8+Qc9e8Kt7Aq+BDhk5hoWVPjWX8sO3
#KYgLqpwqCWRhAeuLncafy7NdtcLMkAYzClErjEkzW+k/FR8ecra/JhrVy06DGiVBegJO4dCEruJ4GqIfCf3sq8+0jyFq4odxs8FG
#EH3a7UIj93WQ0gwDCAxpNJLY8ZcHVoz0wmR8FiMA7/R9V5DDkxEImdNViMDdSYoLPMJEin8gI8IY46UA2xU8MA1SSDh4ZHExltAn
#0KYYYGZebWANlEjU8mAJLGLFRmwkEUAnjxiySUUCfElQaFSgNgVtapUiyQqCQna9AQj0FCKV8yaURzHJLKIPihctziD69sJAfAXl
#FfvtImCiHMvRJk+xYhfOYoabUzwNZM594YyIlahAisgu4RKC7B4Ef7k0rNoM9DDIj0LGC/XXUbomqqU/TGTmjYGCg6JSmsNI657v
#PEsp4SXnLBRiBkMm6y9WX4RadWsYxQDE7hx31UJdqBvGfPJ6kbLPuXGJZxvh7PI7Xv7SdF2HlQKCgUfqgWPqkReZV5Pb9f14Xhcs
#vRSsOJSTtP852l6hbbewNYclfBFvirJqgkfAKJmSJ5/bXFYLvxVOEfohIrYZdUqoUBuP4DuGIf29lVZMrJYr1K2LGjqb18qASVM+
#uKZW8hdAjiosLS6+r9pzY7ltY1quKSn0CWj09LxQ0gRIxFiMEKI4SASVSISdTJLuRRwWz9bNMfS9Y5iImZiK6knPItuALYH/mf1l
#ikUakcOJF6KTiHbXR5v1ASPlvPYFwXFeh9u2VqmKB8dETsghlsEq08xwmGS2cEjln5olAGWRQsRaEy0YyPx3dlWfJHL3N5qrWQaC
#V/+0Sma6WGY2WUYWxpnHcU5H8tbr+pfiTZrkEb2n3H3eocHSQBQi0Oj30rOmJQvDCHFKY2S9SB6+gZNRg5BxVGN0Qy+gdHkxgHRO
#KzpNOtecYjVhqH0xUiqZZ2zBk74d+a2KKumvbsrChbYbjbO5YJIlHdCLqUCcl3Sx6Fe1cJyNEf4TB3+V0GphPnCy0ECAUFnhGdJL
#ww3UOb1qiPoT3U+Tpc1xPt8XNCQoEItkJCiUXzfBB+R/H4L3/2n+J/ynkaGTjf0/WmdTW0taY3s7E1M7Z1OT/w6Csv2/AUH/1/wn
#Kwsr+//IfzIzsrL+//zn/4783/ynpjcA4n/VheL/9DH/H/nPAC7sBiCcCLf/AkDRIAIIILNRESGgAotFAj7JoINJ/hsIGi7yXyAo
#GngEAEyAGjZLB6lNltiMHXi+hLMPxozYuh24opIhTCzMMAY4A7Oc+OufOWkKIR0tnyyGjXlnUaCmakll4NeB3JtBRpEDg8Wlv0x2
#2t55SMpypA7y29XLNza/ATYxMTHmNNzJi6gyPJyO2iNg02XKJmqPGGVHQUES82xA2cM02btT1wH7zndSIYEKTxIqRuTEmNVz1hc/
#lDfSU23oF5QXlpzn0qy4DsgorfdytqfH78fPw59xrc8scE6+PTkGIXOAqg29L2XPXjlYm9/dr4evnd+sz11NJioHXtHoeIKt8qwU
#U7VF9ai9oj65fgMjVNG72Mv+31cJd93fjmz/GGdkKTfLYLsZi5wJ3Y8fv7/t3BcgFIsSuXAxp0nUCiNJkDGLi3Dk9AthzmofJiCW
#BNgGTYzJacRR/lE1O/YioMHSjevM37ZeELD3UzX4n3AOZQ4OCfKlHBPIuGNvsdtNvezc0+0ajYmy9CH3m1K+UE42V+Hua5w4a1z/
#U/uevbkX1d6P0abom1BBIjIsUoGRWtbTnR7EyX3l5dyV2V0d/VXasLXdQWuLs+aNSRERmK+RAglkkTUmfxFnbrXWd3Yu6UvwMp5i
#ANT+HpPuLBiEOmcN9B6Kqj+ZgMHX3wr5bxHdiaGUZkjZL9AGKFQ+zJrT4Kco5dk2wx6DdVYuDl4u20tAVxiOiD8GiSDtWAA5oYNG
#IIgEziEJumVzYqeJUsoem/VbVYXFZ5tc847aR07ESqVTT16G6govMM/ZN9EqoYmW2QlnDFYIUMx32xhs78Y/7r6i/PStp2hQYSaN
#aB/gtU3Xp0EnB+lAgnCDhb/Nu7HZQnlpAhWIlHiRahS4Zq+zsMALlxgRIU2vJn0U17zf5ajQJlaaKpAPHZ8ibJpC0MwpKC3llg++
#MsYQRBK0UUDKJ/tK068/GDEgNqApacHu8S7nww4LESk4Tb4y6ZQcbXX8v7+BvA+/UACwfSSMRC0xWggqgupnCYnHIZh8VACnt4Tt
#YWjOIEmZRbxUz+7imEXJWMZUSpQV1pKqT09007uzyZSfONPZ3S7xrfnbMpY2ZNRCOY7OaqGiojrSgzNTS2jma1xdU0pbS11Qzcp4
#jLWuyEJLFVS8GDEK+O8/58reL3EyUilBubVSvLkHN2AHSCmKHAF4JgZtuuXNXJv7O6v0u7IbnWcEESHM0kRYzZ9t7Ux2OZlY0jZR
#NrodgjSiSyJzE8JgsVrnb08v3ldmPggb2DqbjEylPnsdY7MgPcmr0oRwfzwi04QWPea/sXSzmaN/c88rHIHIKM9wHCC2d/EA2gBm
#gm7riPkIBkAgv3O6UWT+wzgEsGhMj6HfIUIHgwUSkgrYtgVwi/kwPgW/jwVIJQodhPMMQ/mIYsLGMkLbjuCOc7znfm8FYXhCd91B
#1wThBEj5gwTwFBDTCHYYToOSlLr992dnwpMCgWAuXf4U0T0cFCyzsmswVEHzuL4ldKD8d3ElePAr8gwxkoNy+CDmE4jTQ4onxVJI
#2UAQuyoGXU1LYRDy5QBmdjDNbylAmz5j+bTmQVJdgRP/rjivM2qjPgujPsWg7T0H5j6OiPBDKMQw4TDmwI8yDHiAo8kDHjAY8MAc
#133gDwjQOSSLXZ0PQV7AibFee7wCDN5RB+/9T1VZkC45mXBkmnZf3C5ElF2647CmLXy29iqXrdNZZKy0h15sVbciSRd4tHiLTPnI
#5MNaItVMxiM+WXeHkKylO7pnMofbxnlh7HxnQIyPl8MuyawDFTNzVfxegj/18K9ceWu+XLsyQ6AXLB9HuVpUbW9S7lQ6O1ZXoZyi
#QhFmGIuWrIRilDoaDCVSGEtsYSsBTHNTqs+FPTTaJu/hCDAbkLkJePAx0uLSvOIbS+hVo6Ug4hCAvnF9bpbePDLGPJ2k7U6lZk9M
#Yo8NKp/i7rk35cZ68clMjamaYGjuTa9+m/KfNuC/FMWhaMVdTaEgFqlfKaWfHdft/D8Hs1AQDJ77pvBiKhM0Svk/yuBh+c9dog/m
#dJVJdnqH9XDFz6fwv0cWOh4jqQGwYEQDPTLXKfGxQj8VEHRuXIG+8+XBX3uQfci+1ht6YyqMIRP0/f5l0wF4XlFhbIVzdO+6A3w8
#6Or1JigthYOuGFpBunb5yKjohr7eFVqYZKnPkx2f6CoC8GKJL8aaSU6Y9HtvFg+3YFG4B5Dhl412MNTA/ZP0IeZMlM4Uz6mJNLxx
#wEGUZPDYkdcSKgyLAEBhLBUZjzJ+XQ7LWYzhfUpsLMhLHq/0J6rZAXGiLMq1ey6gH8IY0Citp+5qukv3TSlWbvENSGwzLrYg1is2
#8JWJzi43ZwvfufXXESiBFiBsiP0H+FxU93fBQZ1Zad6/abCNHHJf8K99Q4QCS2puC0TAbBxWA/hLT8EwaJ21xVg/dj/E+y/K4aqs
#fkkED4FnurpPGU4txYQp2MopIOc5CMQF90kCSQQ7ANqEaj4rGwauPPizrdI4MXDK0Dtpe2zkTAKPz6Os9VpJ4gtf3LJMPwqGjt89
#V3iAwTF92UJsi3eXeMCuYxnBJSIL4fy+0TosM1Yw0H3FmCxEakxTniZGI39waMUEQTZQ0a0Pj94NtNTz7+PdlvsbDPA6aBjgsErx
#ql4sTXflOnULAjlzvqC8JTE9OLq5JTE7M5GMwBginAP8fR0RkHiNaH80meWp1wUfNPkbiAkQkHPqIp/hIFxCkYIxMeKMZSJBzp+a
#OG9B3m9RE++AQoXlxQgUgxSwYtFfRFOgwpu1Fkr4HoYVxvZ9VcswWNGiSLsqmh1wTWTgWCbxiNyXqxg1HBEnDFjE2P/Iyd+JVcAa
#DYba75tQycNi/pYSmxEWobo+I3lHj7uvnT9tIBWCVtdb36Wgo2XY6awKcvGTcWL8x5PPJewxKPbwdiIG5LHQ1wtcVixvFjjDr8d6
#I8DSmNbRtdHWTKDt1oJRE4uKlXNlnEmEyHJVk5EW6Te9/glqJa0icIDudKIGnPrglONaKEF6OWyxAgtiLUi4YcPQdywskfqmqWc4
#HJVcL1BEUmtqqGdLOq0AuWr3M3m0h9l0IpVYPfcbSLHBoLwbJJd3UKJIZvnYHAKBLoRcbiIhS6LZjRMB9JiUKIcBXE35ypKq50Qh
#EgmlQOSE3PFgRSpWgi9B6BEpgZNOs4UzVa0sNxE2yZqlggy5XYm6cwOVKEQqmKQKjRoyhaOcdEsISiIiz0no2THi3cmK5XFBJiIz
#GOQlOJpDuUBBp1IVBkoiKatolPW9YOD9miE4m5mBaqc3bzOLuppB+/W3f+QBaocjmia58naazbv6SwNxgUkTbHFRfvK8mtZxpeDy
#p2sJbROFlYzHs4tMjkhINVRFJETNYgnRiwdMYXByqX0nTTUDatJvxvrRkq6bYsdzn14/uZqugKnsXqk4KaTJqCIigTJNMT2XNsEK
#Vp9u8HKFstSUV1kAUsqjZF74DWuiVMdMIbyqgjCb0WFRA8cu/BObjxamcQq5nPV6CDT8/oz91v6fLWNVgTpux5+JJJrg2L2HcTbn
#1oGn+lYSbmi8K9zPS+/Op7y3b7r4zrMtEQk/bNUvEiXSaIAcbzfxbZgu1UwOqk7Wv6ht4w9z8QyV5Mo+BwLcC6ezl9Tdbd+CKGVa
#WR2nBV0KpFpwG7SPAisto1BVQatCk1cjXnxEHNKpKKQmoGn9jVkAkf3BaKhKyfLSzGAJWG1FWSEhV6F3YzBAsYZwvdwESY7CBB2a
#4kTIRwqUttHJilqhLSV/cdqOZan43/DOTrU0KxRFGdKRZUWKWo35AE8uJbFcEiZByg8UYVJeaREGsqASwggkxS5Mrc0TGtBiCWWo
#0pFoSQ7vnfg8jN1xUvopdIpk/x4RCiGyRJoHHSUZx3CFOO2BVfOQkmY2iYf3cvFWA69wJ8qqqxufPs9cQUpDUfqp4ihouSYn956c
#+LMzmLGDA2QE2d7NWH054bEM7H94PBnpH/cnY/r+EoxR0cRTKhh2z5f7/4o44gzC3uOINXgCkBVAwKyGD4jAOKA4sDjAONA44Djw
#OAA5LAW2AG/AmvHnDQXGACmBlcCLYcc1KJgHqwE3xgXpHuPjgOhrlxYhkSWvQlfyqDOfEYkBCj1wZkKrHJdRlWaO54MZfRZ8yMEc
#+kHhvSEIaNBe6Id/MCOky6YCgKTK9wFarKvX6+ncEhFrb93+/RsAzmUYgLF/S/i6mP1FBiqN2JCsRghzJyFAlJSA26rOp90s4OXK
#J1aKj2zmLrujMLb8YVvye5LhgTYhBu8YF+aD6q5/Jepuj0skT7sttSl4xFW1sSfACB7AQILbGa13eacTC44DKVpcYI5mzxN4GC5Z
#uZavWTt4wdlp7y1F/T5OD/9BRHG8phd/o8cIAKZz3xcGMGwwVVnXORhBZBa9JaGqzlDZqj8wwbZYq03JRhZDu/qlhUXkoAISvJ+/
#1cqHhgwUBRZnJLSY569Vq+TMRorjUZPIsPvcFFdaPRI21MdMVQbZmopRqVnZWDXLJFZiQNRk5Nq1NjS54eDLV+/Vbx+uHpFcA2KT
#H0FOrNBCSg9SuUXBINc9rhnb+RNuIpuJ5S7f5G/dKl9kgp5mEsoA+iFIqSjNsAvNMMuwje041bRNmmndMizzscHiFZPBZzXHYwGn
#UL9nOSqoybafKW5pZkMQ+moNfQ3IDedzUJmwNt58rjUgSMGMejM+6+GLymgC24ZiNYu+/ee0VMAslMfX3FP3GYFupx3ifB1So6nx
#ylsQtRF8t7oiyu/b1jR/cmZpfj0XFotvBbRjd5C46HA6qx6eju1YvK8CzM4XKCo87fWvrPVwUjueAkcaWdHRqFk2gOiBKDI+kRhd
#j4ZILpYYBOV51A4EYiwMZpi87GhCHwOrvI+YISY6FZy/wOjvvbEZCLvL18VV04Nyc/aXdhcN8fZOnR391NxIVd7DDdLuxLP2EGn2
#Sp7ZDleLC4L84+bOOtg4vs+LEPYKODidyGkiPp4okQwciTUjZR4trtFA8M75TW4FgpqZvkgPBcNHpH6QBpUn/y8iOGHYRNntrnGR
#qkpVy7jGdXXL4IhCMzMLI8O0yyuqphX1DrZLpYe9m+5nmnj+kwgrHzkrzNvpduR8MA6bF5PqLqjSMk7yeiLirRCzfAIiWlf5DS+o
#PrOeWRf/6F/jp1E2TLfkW21I9QLYWJcjZoCrvdxfpMBTDYBO6EgQQRRKfJ6V/wde6+JoJLacM5VNEtXxoE/DDS7Olrt7UqQVgxlE
#S8WpqLJOYWL8LrQnILsQnr2Yj1BMQAKrYyfkLv0/oo/mj46rIefJdHfbf7vyaCHZZp6Fzj2pYdaXARagZeZOFf1AfpiHyU994G+q
#//mKDeQ4gNi9CnNf3BixsEOD4gAXw2DVWZn5F5rBgWJrJLiEqnt5yAxZfRBH6wuJs6ZVSa5dt2zFFpHyHbXKDZ6r/Via8GzhMSZJ
#U8KTqpor5Qxc66gM2NQCxS+aRjXCAYQKMYcvFJq0V83VAmxCrbs5LzgC7L5bE8hr+if2gDLfjz99gHt/9g3Kb2tUPfwt5lq1rToA
#IBwgHFu68eRNkzUnhlMJ4E3D7llBdpyXfnc+LluO5DgPGjVkrFhrhBfScz0YnwSg3CPFx9T0S4umOQ06GCXFrcV2GiC1YLukQsUW
#ZbjOo9roSP/Zel64Ny4YW8o1VN788qhSQ/yAjQ9/eNwXacq77VfxXngWD/P2ecSB9GRdpy1NvWJAez2PcbwPBznyWEj9dso6//p9
#V+CODB0gHB4gJTkUFJQsRecSkDHVyW550j08J6XLCQaERB5UyQSrOSQPSaVW1TJjlYovC6JqOy3t/XU0G0+mHmRyCcGwTOoTIqMP
#a/r1/dYToNVZu84bqek6WFNzTHcc4+VG1nyWEQKy25wg8+UuhkepON4bKjVsN8EuX9YDclXGuHurRlr89qregelZufFu13jIwuOw
#5noV969AR2/7lHy/Tzi1Sv/wxCTk7YsR6VVh8lmThY1pH+QkLvHAQNXj40+sVOKVqtcDgRZwoZnVyXVGghECp1xKnTZu0CrcxvIz
#JFRHYg932st0daFiU2Ztt0zeDjYmhrbyz8aR1shtuLrjEf79SnhNdVoBG6XGZySSk4Cnaq3XC4L/9kg2vK98sVWarSvwvapxIHX+
#bCm3StbNLu3onlk4vjb8e60dL+Z3e3ZOEWKsGPNS2r+DiY7fXQOff9m/Z8q6wl8EkUESZLWFXcyvIHzYj5iqsbOdOVZibHPHpC/E
#cLrSk7BQ6Son2SgfBbb1Tx22FIywEGA0Wnul3HxeTsNRlcKyXgKvCmysQwzInpU6UvC3ZZVZerAOVFJ9Uaa6ERaSUC76q8/26hFs
#WH80XBq2fSlU6yLxeyZljy+f0ajOF7Ly3C2iHhaYWU5ERrCtktiMltCCpDI1tQ4u2DCEpRdhmRuYPU1J1ChfOnF53cRYbjdns/I/
#iCYaUokn0RTyQSHW+FKqETuzhJ4a4Oh/ZOpoQ0IhslruypMpt0meBQ9PpEYYXa12wcESfHsobROr5mviIRuU6Yr9SCnuM0hOAasn
#/lTiaidNXAIo3Q8Kb0UNL8hxL8ajE2lWqjGTwW9WIQzCC6jGOFvTzRtxq4HHuBxfB4wooP1zPWOysiEl1yLLYFS9sXwo8S92izZt
#IZcdOhlHjY4lzEBWCE813ztRgknb9cr5WViczJpPM3T3B2PtkKQkxkqGCAJME0hB7nVlZqBljQjfyU3Xrcs+FFl17b7ClIeDHZKO
#LBChjHbivahGkLh8mh4kISM/JdsOF5xPzGPoCsjGGf+mpt9bC0RjNsvDjk+FGJdAMSEFPCZBXE8EeUyEgUoEikyEkkps7ZKEHOxO
#rqrr0lNI9P6HqaLWCtWqldt3s6WdcfYXo3AKcmZmXZGVq+x94GDLgZpNJQc7NuDoiBEbdnS07Ij1vkyYqlh1a2xQKkS6prtSK8Wy
#+CB3LOYZbdGxOPkTs0jOICABTjI7da7Hl4Y9NuCvB3PssOe4TTvsm0GaZftN7TqP8Vnq/bsf7m7vcpeObBJo7MMmyVbEYi07nQMA
#EKtmyhdnszrDPhmsMdr/DFIAlFJBOXU1deWaGSEqETiw3OBsFtkRRpEiW0yX9Jm9m1dKiXsAPzPPzdbha8bmdaKZ20PAOOaCj2pM
#RhRhc6i1Nv9UtCzZ75QpyD3FIaWKOCknsQjGj60x+ujlR/NZnUWqO01XgW0n7kq4Uky8uMo8ednEA+PhYlVJTOUiJNlAHZhmwTI8
#5HBGlRcNdEAV0uy4C+HaUtyABMuOUX8o5AL5iBBejKLYBbWOEgUmUQAdxZWNdrHQfKcxkE88T4lKQjj19FtzheGauwpUi9hmMBYq
#S1NAQFy2kkTfQLMaTMcpwzQyWI6jtnLGi4HVnyihrh1Z5n63vou8v4KNB+ekcwMbwj5AiQRDsEhddsI+0+pJY53hxfbEs/h67Wyf
#NRPxb2Uy1bdkbkK0ltZZns6Zih1Dn51pZriRospEHobOKH2oVNE/N5zF2oq9d4XEB6Nkumq2z2TVazDBmjOXnwgMYvR2n/G6JM10
#V6PaRYsVUedm9NRZ4NkamjVHbbWSeNrX3XjazaNK/G71VGhXsoO5rQKY+RrpJLm5q51Pf+BBJN0ahHRTpSqg8RZzRhEvrpr9OgCZ
#NCYpY5cNhCf9Qhc8+9GitCzU37xpDB0PGOHpsjSfdB+Y3WcdeFTc7rOddB+57absk6N1blQkjx3E27CUnns/um762VW4n92sy172
#cLwPW9lnD+k+aOtWnAnJ12lpjhawr33H13TU7d6tTxEdyi2NMdSce+moCcSbd8qL4ImVe4KPfAKrL3ESlYl9MgP9pOvDxG0scCQH
#jUwzKrFbczuNLjU4quTASLNdo5dAK8GkRubRDDUZtToWalUE1Loo0BW68EVyNZREHrmzafpnK095ebCJAfSRXXIk5PDUrPun9E1G
#sPG9O+LzjrAZ0LCtC9SEL5/NfxrY+s+4/uJfvwN3+d/Aa5+gB4aa3z7FeDwyk5tYdyMOyxaaao9EfXMzy4fDgtueQCs5mIdb5kjl
#UU2WGqkJTc/IllEMF69g5MRS8HcnW2vSDfzS+hgKHAxzLxmfElnNcDOj5mBW+rIwalvUQDOxB6slK9gGl6nGYLRqk33TWZx5/cLj
#uRDKqQygPt3uuCODPRqy3iQQcaOIwjslmWdAfMYMiJEmo6pItHUYxZyJUMWZKdT0/AtQnFJEcjJoYaJK4W775w/h6q2KshkbqvT+
#CL2YXhrAlWV9ssyxCvmLZawwpeyUR4R3iqRtYkpBcq0paYJu5iqYJm3yookaqQBDPyeB+BV+uG2XEiyIezARQLr/Ja5b+08a+6Sj
#Mgde6onINdQS4ymddfGwnFUZaVV1OAQKpn6gvTJUug2fNWTswJhbJMGIjJY/oiAGIZHDDo+znEMICihiP97kBbX0tVbQRMA+pCTI
#Z3Q/J0fOFYhzNi1MeKAhNmRECR+ZVEURmftzCKe+YdZX2GRRIWPgCWTJMNFiPwpMSPCAze8eSQSIpv6kTDwaAyNIRCgGcFxnL5Jg
#QvR1zKWE1dzX4JQYtLpPcxoEypIHA6jjMGOF/Bv0HYf7GHYX8AaeQA09VRNcFAwziF6MjH5UXYERu020I0P9ogB6XSzr2ONY/mlR
#bjckoQWipEheMDdH8aPr5yPOguRFotOg/QgQXb1C7FVLkccwsKP3J0vQdTSSlWG4jVHcJTgZt6hXVwH3Xfzg+tt76MKOIOG7TrjT
#gDsIQz5EJHD6hYI2jEAN+VA0Qmwuvjm1wT7gaOE+hxAIQV/OIxNP6ASDRHPGNlsWqfh3AFA96WuFBeTdgtQ9IWTsh1NJZ5TEcjqs
#HFgfAoj7++bsunN0WLfD9Q4RYmEbKLPxHxUUMuL4ZRvja9KVWJOXBs7PIOG8WHGvktP2gz4OKc1p1df9I5BTNj0PAi8utGE1hZta
#NESb6yv4gKrdxSY7IhHzF79Dhq4JADHjMaWb/gJSHY9a5Tgkrq2wDk5BCOzfzFOZkEGuF6FowT4RQ7hg1DgSS4d49UBsX5VtuARh
#vzJITkRCt7yABY4Jszd/FBWiLww/ooojwD9GjvAgddpaInonjGfx4LPbKT6QwWcX48TUcCc2QwVwrIT0CTAbdAQvHwbtVHXfNQhj
#RokcuMQyIyyR2ymygs0P08LPYLl/vA7gKgS/mDEHAKEIxXAkrRf7rGnMVNX+DSb4qzPufNwBK1lGKeMT3gjIecdmJxokRlEPAkLS
#9Zi+6RWcTx/R2bPTBDi8aN9WGFF7nqrcpjm7kKSsEIj4N2qU4gadDUVFA5vYDjtSVm55ZTzyUDWMlCM3uhzL/iLS9ESFe7fb9lYH
#IovjkRDke1BLiwGvgbgdevkAbhOjZi59A0A8FuNscpLRdKtMVrEIFqnHGwk73Yihy8NwbcIrO+l6VlQLositY4hf30CVIXcOcYJd
#gTD9FJpyl4XUVtw6xP6SjWMqF6UEv9FJ+6uxyYfBqTqxgIrTUwuBCtncluKTf5aMLerOgdFFn9AuOPgzDk3ISGEEDF49zDbeulf2
#UEnRvU5UD9yMW5HfRgU0E/m4mJb+uWjdGoOPfO4aUXA7oMV+JQaixaPoxUVc3ihCMxG2GI16FWS7c2RSuZaqbit4vcaERRSyPump
#mQV8QIrKOpz2q2yee6WS3NiRdLMPI3zh8yZwNek59b8sik8fgdKKXxBVoHbRVK3pJipbHRPx0ZQ13QEFhd5k2yIRAuoKsycJKnI9
#u72yfIadViI97b67q22NSdo/qlEU/jh2ILq6AO5KNhUCMN1vvS8nzODAjvePGmVxPdZ2kXsOhIeDwao2G3Stmi/U11JvPxdHMhLQ
#XF93OgHvlj9ecop7tlVNv/P2l+NbDUMogRjjPPDOvmZnRj42S4G9bAleBUvfgLMy19GADDEpTPmsiH4f6nNraBdwJWLBXYqsAQNf
#S5CG95uHgz/q+uq/BSPDPc+vYtL5hdTUGcpXIuVxwyl0VjCgNVYZqRTKXdbAtVUc4+u8omD7TkRBe3DVNcd7Lbfk1lbjtkuLtBlI
#efc1uQrjV6Q4l3KoMCAedsjDL11eAHqHiZUzk+u7zF8yVqusNv42rvO5W6mTdZlz7xG6MhSlS/SxuuAvuOeXHp0G23dYpIhQGkcg
#F+BqeC2hzwxEt7qNDVSFP4qWvIVF5HCC9SewFoy92ypK2JlEbcNdp/nNndEqQefd2PLmhxrSDbNzWtQYpZqICE4ia/+ZdZZW+1jH
#JcvjGRir5uPKCbEhnH0spgAxGvOvNz/9A1zXzvxHfRm1j3BIkiOyXolc4xQ3cTVt37RUWOjwNxSciyA4TZKkyTo338uwPSo0y63K
#pyDI4kqJhHsdYEPt6sgP7q2jMOcCnjvPfDA9bgSDPRrqJrTYTKjGEnxb6pzgQffcersehjU+idsdKZ3L52sC1boLNeXUcSGIvt3l
#INUo8lpRMmzsHkrkTarqt+aVxNtGOpGrWHu6OepqTgmk4kfZtq2FXZwH6kx76HvCzDmQnLV8lgBHVswWu13aH05tIUJQTTw8gMTi
#4J+ggE9LW6APEkta/XYMkDRztpMNf8V4sDFOaIeZ/PXtOg51+YDKr19xYYQqa7u+aakyVzwLUsh7Z88h7UHauDfjyQTyePYrYLko
#FtqDIOeSjEWYv0CsZ2LjJByHQMdL5TMGluQOFjg6l6GanIIdxtoSgHAZHurGVmelP3nwtk/qB0qShAjcwhPNS/CXqg04vtpqO6NV
#dQQAMNoZZRtw96wNyuVQ/f5Fb8A9wFlIdeRP6awzOQ/oidFB08TRCXuxBiEEbWULskwyBHVPyJVTgUwjPnuYNmKWIyUdqZQ+KK9i
#TJrSsIT7c79PoQd5Q+zhet7880tPBBsIvcB3a9+Sa2yVi60Yag4o4cMx4937dAtCbWOHy3HLGb8n9VRAocfkE4c2oeIBLvoCKPFN
#BFhGygOn22GXNCJEkKSmt2UEtMchpa//7jJUH2aBo9d/rs+W075LdiGVIpzGOAVRQCFiM+zMI3hObRb48lmqaYxxXP7WX/YNSMAG
#rHDb//TJyiVhpdFxERTbjJ6j9E0r3jQOf6DjdWtQ0zQPesFpZgJMB+uw0eUD0SsjtVJOdz957ipXLbTlUwQlVFNQ2YEtIRMiy7FH
#0nVmWxJnk+9rqOryVb/Fq1G+zeaDjpRa9ArSKwpDbcK0+SJ8VmdxKHvMCekKpXFa4t/4I4Qf6zdSvHxPhPZLoZli5zVgYYtdEnxz
#eiCvaRyQPawE+TaB+Qr/xGMi7IhgD6i37fnwnHdi7JwipGhiInIgaHrKrwrs4ejaBqxSxJz24eyoqK9p2Ck0fyraagEnaxZyuRWh
#SiSXSTNvfUWns7jMlmKpTMDcqfTX+O0ISDuYktYP1vSyl6R4Zsb5e6hXI6pyqLrOWoYcZclR0gr5Tz5qW77FEP49mVxX4mAoDnHZ
#lDaoLXKS2cPy76vGEPnSuvKDE2CviRgoGNLVIRgz1TSV6L+jT4gSPYoQYMcZd5Kxy510a9xEfOTFaxHcPUUtxrWcv8yXJlBEsW25
#fsSTx/QfCKYdVMkroBMY6nXdY2EQVchf5Se5ltHjHoJUqBUplcyc+clDTrCMblfjLHXT42C9YNqJEAHKMsTCOXZsNorFYzEA3WZC
#smuj9VasD26FEfFt52yJTJUPYXY0uVzxzbpnVVrAExwUDK9Bnlb5aBmANvJ2lUeGvBooHzsMtmr0wRbHdK7KjQ5fZqxjValxyWtJ
#9wI10sCh6Gyo6gRS04NPTZskQBaMGoKo2wtvcaYUi31KJnbLsmc7h7kwNUZp+2G9+adu4LVPFZt9mLHDL6HKUZJXWqsNS9GgICJ4
#HI9KPSRaYoJ1jW8Ywcki1Ni1MhcoYyTdqlJ3jfFpA2umtMrUrYIRGV91BPdqJhkGkitOUlOrKXaVmgLZlB22NRZvWTSqzzhqFTLN
#KDVgphjR4puWXxQOVEYo3iicGJdgjZRNQ8l67bcOH6HOUkf+Ja6JKU4xXA00XXH2Q9miBNXRS8PGs4Nb8M4g5s/7+rkklbxSCDE+
#xAivBVzfXjHjL2nuFxPSMbH6rRkr58mfn0nduI7tbIRcMZ2w30hHaQL2a85v1LU9jLOD7Ev3uttueestvHmTyyEiI+zHa6XcSonw
#3DqYdugN3lUenu4yS1dw2x+f7FQPtIyWPmW+VnoAI3wzwaDClGfcYHZCJ1X5kSn7eCIEbTx8VGGY8oMWkQSipCNBX56zVxklugGZ
#ADnA+hv7AyRAZZC0w+lIXUA7jvAB4IV1nMNwJ5aCopgmheYdbJcmQtKZUgMQYpzaVFX+VGTsrLjRF8u37oXqnWPaWl/FWDvQRMSq
#XwOoA1rQDsCS7iauyvKDMVZPxIPtgwHs7GI3N29s6hWU17eWyOLJYzW1tpfnozcL0KBVmfQY2ikaUWmqG0mYMGjmIgoArKe8io3y
#rM7x3yW8P2ns8epMnd/Tzjc1F/l10dWDPjDe2RRGKSHITlZVTFbiR6+tD92Dzcx6lzi/RpNkfvf45dQ9lwqiS14dH2cMdrIA6Fvh
#5ZiBi/6oAUSukoBBxAL6tvxylyr5bN7/AUCcBhn0sANIJDXLSb1k2RI8+qvNTpqn8LQvZk9XQ+Dh/MA6dnV4Olq2hktSX67rF7tm
#VNvSxVyZu3AuZVHNpJUn1emrG637Y80bWxduIXhBK9dD8f2pvZaexbqBo+XuZSwYRblPM5ELn7o+RusZfWTvjQetLprBlgB5HAV+
#+sux1/71hla0fepmkG5YVvdL5cAimhxvJ4Nj8jZLTbUAQT0fItGFxCJInPCxgpptEelM8lbUi2S7Lxx3/mmlTeSmozWzXZ29kUU7
#fcpvINAZXfFPCB6wywjfaus6StPpu0n3LY0myImdYMdFlSbC1S7hhv/MkDtdbtIt2S920a7Swe/9CGuDvK1Saqdl3QkGX3kuPFPK
#GHGZirxlkaz7NuPPiFfCSdU2JgptaNAtSMSBvsEmGHz/9V9yb3lZVBI+PiI4BN3Cgm/yzPccvxa9lBmkOy9mEvvqBuUy9WhJzZgH
#caS1jCqnh8S+SmEqxo6Lo4DM7njTmZhcDZ6CQa9eJLbXx4JFcVYbYxfw7OoknF14KcJ2zuX7OexsEw35jPxby5Sx0PbAzLQaxIEG
#NOCGw7c8Zvb1GA8Pcf0B2AbK39uptUwOUDN4xr4xbkk1BqT5yh9znyUIVb3YBGyHFOja+1IpW1k8ORhDGgJkg2I3qWddASgKuPYi
#mn3jWb6p71xqiwny3MlXbPF0/WwTblPiFe4PwZp3Q+N3ZjEipTXNXXRLIjePzYZZSohlxxpwBni2viYt112665CTxq6GjdUrI3/B
#nVzQY0iBSAlBFz1Qr4zWWN5lYN45lSxKNTO3czzSuYErapVQbZ9Jgqns9hQuKbGUs9/8mW3WjxO6wwM4ZLfw7Gfrl8hT+slLHQ34
#oPsqj2sAl5Z6NcT3i+u+AkRpclCFYXHX5mWFZE63FOE9W7MLM/tVguJidrGrzdyg7a3cTWs9N3jUnlVefDlDUDtC979kyz1j1mZy
#1YZ/ypgYyPJkErB0d4pWwlLAiVGg+DwbK5nPyAn3uXaucHl+khIDp/1XAyd2cm7OtLFu7las/Oy36GCX4w5Q/dKVXomJCTUiEBqZ
#UbrhJM/HUJ5HpCqjjpCfakf7LiE31Y+kc/P5ZG2FuiwGi8W2+vr75xoUfQ3MyIMavgZLsmkEcH+MbTJS4B+6AQgA2AI/bLRd0ePE
#DKCXo0N2iaCnKWM9hByRe9mqBQAyKSo1cOt/axDpBoaJFR4qLdRYroIFOfGi+tMCo9+dMlIIGJ9FqTYZ4hVL0gbifjuZrb91709a
#+7klFFxT+VgnawAPoMnzppjwTgE1Id/Hrq8H5C9PjQY9OpyVR0dLyz8NFzZUa8A9BvGw8Mn7iRfs5BKQEojLLOfFgy5s9qQfZvZ+
#KhOly2GfKLZMMODxGzkS3tdGhndTxweLykQRHSTJFTJQdhJGNnJYZNe3oXi0S5eKQ2naf3RrtolpxrazlReeBRy3uPlt76f0yWS4
#qTq4GPt7omUEemjMxwnG9HyCQvBVeBpiYVMYmsETIPjxBY3P5LQZBD3MLef5ADkQi5oygkPsEnfMtVfQN004a37/SCzURdp0BRWa
#9kqoR4QX9TKMoJ82trSCUZHpw7Dnrk1zmt0ljGa+dlLg8sIU3vuRKq7WMwCyFI9SdLDKGyuJMwUbmMGfrUYjKWHwQXCNuRFViHp7
#Q3SwoAFaWe1kjx7pNizzx2yJiBYFKmCY8MV6URNxUzATce08+wjHo5AVawompDWNY6TyyjaMDc4leN10jtjWDeEPDFAPek7aoPxB
#D+jtDwAJwCaPNP4MgMIAoBWvTggpAmKnNBbyO9K4849FE4CEyrsP8GHn5GUjSvzMbDcXSdGo+gpb9cAvFjM+IenRM5NYIr+l0w1y
#SBt76CdqnSKZnpVrPhKXaCFWI2fkPE4XKWJN7RlxWYRKEfZq60SJnyblR1w3Nm2mDwyTUxp41VO/TmGdGgWR6ECH8JS4/4wnUbRy
#hsbHDChxf+1dCeZgiXIVCgE5DNXMtMjrmeTgcgz4Y+TBzBS3Arcno6558BjFowOwTFiAwmvmAkwMXijIpMnNub2KWmzII+PyuA0l
#XBfxTMlte66cLicd3gxGibgik6Id9CSzxOhiyEq994i7h51/ytfyiSD5R0HgjVkbTtgyT2LjlPSEOeOPnaIFXdyJxl/p60Vna20P
#pUF/GesDfwma/2Wo/oLM0O/KXnh3bghXfqH1lfJrVds5fXXLX4W2hTOVKOXH9UHDHhcJpykFlqBgNzSYwmfIGilCdhd9OJFaD4a5
#YNcywu5NM7I+92/3RZjiTMvpK8uVgeYnoupcqkJzQCXAafdO/2d1Ew/rsUshjf2pc/mJ6q32r1iBxKHXGFY30YNs4xBbT9ry8bhk
#PtVgoFhr5RKqWctbKWlkTUd2mSDgttIB/ZDcqjKr2lfG6ol1+PMSo/eACi0KEED/9EPm4dV/SfNgVC8X2zWf8PkI/ubDzy3ZBBTg
#GjRfY5+PqtKnd/lEh3C9gyn/KH+ed/6OPpkaaRbuTd6DJ2vDruvll+iM97mNk2P5xb2Za1cIfnnF88cVh/iY35lhac/9A1wI535l
#9GL3YAhDTbVHmEQHuUunQY2ES4sR570Gz91+4XASNTAHGW8PciE2BPhCX6I4An3Puy+nYSeu/d48G+1pLweMgycqL8eE74clyy3r
#KTt0z9PZ2hBx7CRC1n/XAnTnNKbBJwv6VmIYHh2lmr9lKSur/0GAS095T/eIPKzPeBUQqL87BukhEejW9Md4r2PEHvNbxNV4gxao
#W/45trUF5i0ea1GQNHbNOnOSW+zrKxIAcNAfIPGqRG1KfwrYH0BPwN/ow4/l88nqhPz8H3sQSdbjMcPSd5rXgc9sNuIppmz5pEoF
#SL/Dyo4WM44DmQ0Qs2HhmK5WApO1nApEAY5gSh2nXs7gzcYyzNQJNqvpQdFlxBwhWBO4onoYAUakmmU8nlOo3aEya1OdQ5fnwRmD
#sVHcJw48ZV/QXLXkoypXD6C4MzOncpuEtaOP4A14lPX7dHL2mkXGe+pQxjtZ2uy10aYV++RJRIxgcRqalLdwQXDQPeSSRL1Zk4xa
#kwdxsMJXNapKY/rtT9dZQkHMntC4Xji92l3MSo4heMQm2PXsOOz598qIqgppDh2ZAC+tu/R4qpB89OB7PPn550WA19upUJun8WYW
#ccauNi7J+wasAK1O/uq2b8y0i0Mk04t3/lzq6irYJsV24BZ8P9gCMVVvMfTVy2E+uupaVNiK+eXynYJunrcyd/YlVxPuC0sU+U0Q
#D27bHswTmCIF/jRLzh0axJ9ZYPdippYpagRpoUpD+iPhztWdvIC8c9/4aimvrmvkaA8P8hp7EUbQUzBvQRilm6tYS3HJXDrgPsou
#1XGuY4jYXTbiu+OyxVsa9t7jKLg8AFZwY1xB6Bhj1Z5Oao8rpT6Iv2D54UXMETPEPbEw7QRWDuNynHZac2VLTZRjFOaTBto/6ZYg
#YnMf5DWfEaO0SZtUak7OSeukm5S++KbD7sdZv5Lm21sAJq5NMztsXEvrtffPNfdm3Z2cqn/YTqyXOkHaeVWrtuliXAB/LS2KMhsT
#QCiGSg4mamkBfiVp0D+uEp6XFLQc7Uys/CIcy20oj28qh5qPXXFokTEubMmsRRY9K/kW+G+rb0J9sG+onTsNBsoV9JvY5h7EHjRq
#0FGqFlZ7VDR6nRalWFt39aZPDBjpt5kA8Ta+w/J/AvA46dyz9zXb1M72Xo9vF2+gawRYjUv08tB4nL5yeJWX84CoTdTUnda4mlIb
#nibB0x2gTGctRNuNITcXUMFCO6qavacwUINWou8hCyE1ooEZxLxMG/3zRoIHnbhW+P2wZIp/oN/CkVUIk2LIIyWQXnLPfpyzidia
#t3B+43taBTM/E3BRwwbiyrp+4jBJZzzCvfokPpqcwEyN1ja1nv8Ez7QqPKXMGibfsJKhM+TMxTYkCO462dO4QP2hEKKQcoopzd1+
#l1DMj/kQFYgv3lUrp05l2jh4a93GbHpGbmdDHJaUNWPY5tiPYLGqauR6TsHVz7+jy2QwkoF9CJN7e0do8WX1EiPpq2EeH2u23GQp
#WtS3GPVWMi1bHi87EeLQNy05z0u1pJCZuTJjQow43BMmPFwNMy4SQ7Bv1otR42ix6KhmNMqXc1i0oYaepl6JiR+e9xMSVltrbO/T
#6oDKXY4tN237KTReizmxA3/ywTQ/ysP8clATuwtMDVxsneSK3yR71T29wccyE8sbFjgDXzXfZORPOGfQmXZ4VQ8k9FmQ9TPzAlbB
#QnJLskQDw8jYLqvjQHE2bI0ApuukmOosr0qa5Q+qS67OX65eNSz4b3HovW5reJXkF5Mg4f3hrL86hwwT3RNjJHLqCMovBFPb6JVw
#CSsbe26/p6dstDG93IsEXBwki3Q22V0EKLyt6Qbc3vOZYMb93CTYwjZyNYV4NCceRfQNt5admX54EzSCyycfb1XiUyMSYk2GDLx4
#fqBvUSMOvU4sIEzp4dyxqJp4foaIRkIHYoQWSgvwWng4XSRIuNYVXw2Ed2nt6V44VSS1a/Mr7XZkI84m4MTbm2YOas/rZ1rTUrlS
#fjOxBCbbUmXrrNk4smM6X+6SzfzMYfA9GOugPgol3gdT2Xj0jo4ljN0OUmx9vPX+XoOsjwNjutBQUWFvN8lT94ZpQyZwQ8mzxLgS
#Y5ixrk0p/bf5oZhyG/Dtq6eH/208TzF/8ya4B5dPP9quJOPy93k75gllYtl9WgkTvWyLYoe4J54+cc5x+87I9c059tYyw/tF/It5
#k/LdNf42qk36wHoz7ARG2A9A0rq1iL7kFDdkGhmfbGsmAsKwCNBeoc2il35iPz69nZ1K1OCOu3HWsG2fstqI10Q0dCbUyD/N/V4e
#9xWh0fM6Tp+9H+q04YsyNWsI5nTH7XrXKlPg8SxMT2BTaiRcZzH8uIli/7SMoj4AHhyBffa0V7m8OLXBSJaJaRdb5eS1WFUC3+6D
#xFRd+cyJtJyKXO2DFgABoId3n5NMTfIEG4nshcDc3TUtUEYoRT2wXsi0OQiq8dZ7Ds5/D+x280TJsyjSmpsaAnAREntlatg/hR6Y
#Vvb8iaKnZ7+ww5mhzSTzymFr2opg0sUDP6MxOLMZdy7LRRWi+j6VctF3NNzSE2zlvjx8mDK6va6OLF9CHseOPVXSBuTQCZKS27w7
#vNP898bkNHZoNYzn8QV7fbCD/f4BPdtdoKjraRWj/HDJC3/0Pt5Q0/19swbvVTGnq1+zYz/VkDBCC1EoaM2RjaUyYlLJLm0xctqV
#sQE6asdWpq0Tn1OAPkS0sVMeoaflgjokqxrPR9GWpyz6pLOfRWwH4LrZtoutfGHHs2m6cMHka9gO5Jsd2DMU8v0OGZD1wOCm2d95
#hYitJMXscAauPGpanlh9+IagxqNs7qE/0wzJsdObZXSwNiiHzO7K+wUR/0WGL2ly/nxpUarK/IgKGC99fjJdPCf/adSuEM1PmF3D
#/YaCuuKLPySkgpUmLfLnLJ/D22IS7V0wTaraS6P+m+9i0KiEcA6qCaesTK21yiOwfCXH7vvbxZxsU2rWXVldFv3FDBphXtb/XpnZ
#Sfzsoc22QHpqMG+0+FauKaRPh4ajJe9PNz5eOxaNksk6XqJgncWAYy/UEJidbwOqF9cQo3AmrguuWwyoRByjA7EMySJjYW9v1RlG
#JiiVVhuOS+afBtV4BrTe3PcHHagseCsWnELUIMIJD+T+3GWZCrDL4UWXQFxLajD7ShtUHGvP1844eqll9SykSHDXM6QnAc0q7bjG
#SAgmitCyEtCGX+hk1gULnbajzdbwDUtjIpxpKdhBZdjRZdB70krVK8BORtn+njWDROX3KhMoWcd1q9u+T+Rqk0R50PuyJnVnFcvr
#o7BvLosYkSZdx0kslpeo76DmwpQy/KAyhbmwAfTbMXEQLtz0q3wm+mOupRRgclk8Qd3yUP+kdTF1aSwvG/E9PlBWl3mXquesdXIF
#Wc+kj8LRjuqfBmihvOgHHFWjoUK1PZpKxPW+HDTxK0MQZ8IrtIGu3fS6tqolmhkPBQ3puQ+WyFZoMs9vMf7EWyB2L5NzIMnaZCkO
#3dMP/AweX/rNuwTJMowNH+XJs4X1xB8N1iOTF3v4ZHmQk65XB2CWaCkB1OB6M1XSvy3a9JLR7M/akyZkaX9s2N/bUMkvvVE4GSBP
#H1Z0BiUwY+x2a6wMWOY8gpXwfePozzNixMaoGV0m0NR2OM9hMM+UiDK+S92fVA/L17E3VwROYQ4fd1kVq/fSb8J/DXpMIIAPIbZG
#j1G6BjYUtaAy43f0ZThXa2Fx9XjQXRvnN405+0MAyUbrZfkMNvbkmnEkq9I9BSLcMsUAILOEdBv3ptnmNIz0a8nYOZNyYvZnDbxk
#0Vi5NhUqr/3jicOe7M5DCnbEui/tbjdjIROWjsfh/Eg/HshbEP1ZS2UTOer8GCDO4DNFXLg4FiTmol/eyjvuIgdlBfhgrNqA5TnU
#YRLw62utOLOXZ9CycKHuCfMJRqxbceZ4mnE67Q5AkOLT8nC8rxBVFQxXLmLGpaB8NpiEhSOz+rxCTAh1ZABVQAAzZ9rwXcsG0C9q
#ZXwryuqkwtOSsxn/ZgO7SoM4v50C37sELTgpMYJ8vsDoOSdhCuTfmGRkcotxLg0P06bSquochPBjAAxdWAXXFaWSlCoIACfhD1wW
#fkSQwY2rYGNN4EzJ20SugdISGKJ4OljCZiLD0Ebc7y3WkwsSIr27WR+uT66Eo9BORo3pqOUr8lGMK1kvX1wW3AMPwAB4uyVHAR8I
#7oXPMNWKK70oC4WeDVBf0ZQE28TNTYuyPsY2kKyFdSJJYOrlgrxeWluLmvYtpqGSLOhjyZQxl/XjjX938ZC3Xet5ebCULebwyhc+
#YCOg5nS6vOwwqs6IZaF9mliRIhHYILWx7CwGBdo8TCyUSxviLYEgYivnUgFG9SWCDijE4hSWJ1gpXHCQF2n4tXMQhje9b6H+UodW
#q/anaLmIBpOyqqA3foiXebm36lo8EYqtWi60Ft9mpBMzjPBS6cg0bBCK4IoLMqBAWywmFNI7khskjCPXmuxkp+v42T0HxfQh6LoR
#kKT9TVWiX7Q6rmH1sjZiNYM0Scv2sU4sWJwspva4WzRuYlKRTJOUVLLwL891JctNVZk09+uPzHZWi08RU3dJJ9/Q1QVGxAGcjJKC
#veNGyI24xedHub1GpGlJHBRiKVUxmR9WozDuoxHpTsj0N3rkCbywqhJrdSHLvTreOd6hHXahm5Ex/wQnQVCl20pAQ6uPCsmzvEVg
#JJvR6bhvQu66qM/7g1a1tJvXwyPkVzT1V+cyt/urPrCfJdiAJbhEQ1bz35OBcQ66/Q7hARYvUBzR8kpi/aq1VCFZWplHVzB01nZ/
#sM/Bjf6Nqo394nSyxCX4lpAv4Zoaxch1jpBgTv77nkd7xT1wD4rzNJp0n8JbL3uPDGQPGj7NgwDfs+0jzXWFocucfIesSFiR0Ne+
#NO5MMdXmzoeREk7gIRXg39Ga2N/e111o3894pRPiNB67SgGYT7uadUyZtmRB9VFnnXMmiYoODtIEy29TDZtWRsnbcT4E0hq2djRp
#AVeKKK+eY7vGs6TS4M/9AezIyJlOZBDZpon1lWFh18u8CfRCVUKECzKb09XLaBC1cEFKhIYFJxlSBKq5kSZPAvF3P1Logm3oTGiN
#2HN97gSWcQPBLAe7eXZTWFPoVMkooYA/I5oye0TunAebKRP7Bs6pyqRNWxoEMVxWzPbK9WWxesG9pSrUdpmC9SxI7SKRkEvxP77o
#U5IFqPYwdUdCKgA2gW8faHgWizMf/XlOdAnAcbFaxnhriVcfA2rAyP0theIQsHTwFa3dBRzvqVCL6f05LvwhCnF1S2OC1pK8oEF8
#4XKJJdaYTW0OhpEFpO17N4kqWGyYTQWJqrUweYzH0CFKTREq9WnfDhXGuG1f907CusdSrIyQA+m1YzlZ8MdudvOXZVm+po/7laM1
#KSNxgpmPSAzAebaSDFqV6izocfpMkf01zUp2wAprfzlhGDNo5Rg+SOx9r4x95MhrTHOqPkGUaCkoXEfGwAE8OBlxIol5OQo8541j
#N6LwYMuUVAH5+AOki8kbNHpEk2fmQECh8gECI+VOTgbRi1ZCwRW6rLkwQ7661O7zaubvn+7XXjIf/Sw6/uyDJuEuDNbYrmeij+8O
#TGfqvs8xBT1YbFb+pTkFYAAmH2Mg/yezhP5P4cdq4zNwgq6sFNjQ5YZPY2zmDAsxtQ1bTlQJtiOV/ohf9UJGiqcXpNfDyZg3l6A3
#rMioK1DmSgVTagrzPzkdL+SRUY5EcStA1AGMFy7n0b/2bh1axH6qumE/es3taIv4Con6RUNrdKirPIhrjZ/h8HUzdawxFkb38eSx
#pDQKJ488orR/1E6cq8sh4yILE2Ci5Fe8nVEFUmxszOvH/Bs3AAOoNs3QISvyIG7bX8Ph6evDBjk47xaBVzi7IYPC/3la7UVA1MpO
#TIjGQkBWedE7NECHQhfR2NY6WBtO12R5HUsGljaB60bKQSXTYcnjkbAo6JbEPUd2H+tWoPAscj3ucwhwbS+kkXH9BIlFDDt8EpOR
#EcqjNsGiHiikV2mi5pkfMSDVRBTIU2obomRIE4B8CpH776zoIsBg7IGIl8SAlhWkJK76iu39mLcRycS0X9Uho2OTjdqw1nGgxYFT
#B1yd+uoArF1oV8KYgp7yP+1PzC9jwcygyMcOYObysr/WUpY1tybtGJf71wQd7H1/jXoOwHcjJ+dvqo6kCGuuNPM+MlN4mEvYjjDT
#X8mLwwlUpnsvlP3F7aD5LBfoLMLDnYgd7nN041vDabslX1mABVgbyA7bft5O9CTRw7x2OrbJxG0G1XGQZeH+gp4PTLl/+S4u3cwn
#252f8UQi+h3av2XKG/ijT5qm//wLXgPEShDb0oq2NSXs1/Gw6IPKueDeyJ+jDt97ZxnbobauHKBj+DevPlNW1gDzUhc7QCsq87qB
#KOzreThkMMpyGPPUWP3f6cUNrbbyERed7W1AkbdBEDRV7ZFvP+Bux+ofUrkIc4vVDFDdzopdUJm3kNiuD7Q7b4C4Tvmqa9eJYmpC
#5Q5Cb2wQ6peEKu7A0V4pMGuOzg/Bo/4Pue87XHIMlynOJYep1pPF6jHGjMYYTmE52OI0ehPZXluINJxkJXGNSy5B82pxdDpOEcI3
#hkHYXUkgbq8ZaJYPLeq1Tn6JYiCXAhtwH3AstpVXZYCpUhAnl2HzstHXbZ/X5nFophPmt5Tn59NmG/Cqf28LBzIJdS1bGYZ3Ve6F
#7NNrpTPWPXYtGwH/pk/rRKg1+KXyZpRzPM5nlKwAFMVTCbVLcFijKjret1efblPdH79Hwd/oqi7nHBEvEZsLoVdAV4dNyCCtm6HD
#gheKUuxylYlARt+v3sy5f+AcWdLrXXCX7OCRHeuls9GlqV0DAeDhO2QtKzVmgjHc+JkG2Op9680cpUdJ99eBl4zeFr7rjKUUVd/Z
#SLgPyhirTuci0AimTUV/fqiWEWF1BKn/ouFjpmj6P6Zb47NiXculWLcNC7rwA6hRZNx83OFOZ/92dA6eY+nghiDHmUmRfGCNo16t
#GfgPvJPeGTBnsWkEEbpPqKxttwMh0PUfCXuVb7vXQFgBbFpw0yogtv43kYcLECJUgWj3mTvyTDAeitM+xgwqLls8xQPoYvtw2S1u
#qeSzgWzkI0iG7ClgWVDDcwA18fb1gCvnU7UHuxlLxjCaBl3tjkDfNqDziRGRDD2S5HEadXKXK5XpVRoy6HUPrwEXby6LlLJqgKwN
#jkxlo9YZIColCpD9ctIA+jAT/wM41HzoapAujnJ+85MUkDTTyFQPn+l1yAIdjxRqsksISpysIZ1NU964X9+8sHy7o/bAbSgZwtHI
#flrvDaq4tEohKW2nHUYxmzARKw7zj2nuGShiao5UHZoyFQUEYWlEA1eUe5tBIw5k7VgWS2EijXxyHJE5omlJauOddm40RMAtCtDR
#clyb4crwjdR5ABRFB0ivXP3OY2Mz+WQQNKPJg0WNvNPCYYGoyZmAoeBkxp1PPCDgaaECA5khxzOkWSZH2gsDxR6iIuQ/Scp8UFL2
#p7WnlNsQhe4QLVs1/FbRz6ryoCxaw1EqsoCapfAxzMMS12tOmtDytTxkXCxf9P+sdSMdkyPb29mrmrdKFhyiKdBaQ/JegpZ/1Znn
#YeZcySSmZUjf/+9vPEfPw/fLok6NtNZ1vJcJhHXl+n0W3bAKzWdUPRZcEB1XtQRHCVDFKmGmCG9yugqEw0ocmY2q4SXg2KPZVsVg
#xC4LXurViJWgf746G6uCYN9x9wT/Q3dI2bPqAXLQYy0i6WIRxmYoAIKaaT16D7dQTkhpE5UZMzT6CM1xfFGiA2S/uKVpzHv/FO2w
#xc8ODP6pRAiApH5Y2r4iWdmKDBVNK2q80DBRMy6ubUCK/tAXyBdANRa6TRJ7v4nG0GO9ZjcboSni8fwTC+eMwr4Rgh6jti0wKMS0
#iMm+TtlSTdg0cEtQek1DvWNbXTXKoR1w7fvDAf2i0sEWzzD4VL55OFBROPnIDNQwaOSlCAXjFoGNszvkXAq6HVL6vvQr8yVNIdgl
#muD+OQolqwOhX8jJs2n47p8VsWGOQ8lOIvE+NvC8P7938f2vgt6d0EzO1B3zONozzqX0SWOsQgIA9qMmuafE2o6Qr5XYfWABJJ93
#MTEpd02QdjIdSp0zCqZA35wUMXpjyhB/9RL1G0Hm9B+c+KRUD2LwZY1MHBZnEZI/62rwQVqPpVYJe2rb5EV4EvQAuHVUdUiM5kxm
#AWfN1lQEq0JdwTJL7g6rMSfcjAqs7051lHuf4fu0LirGPPCudXwl0OIzRiRqQuXFlB4PMtudakU/ceKcEYdJG/f+Rxj4/f3E0NjA
#1INDwxjvLRZMhQhnnjMRmF/7SNwZTWsoBPWrfryYwmg9u5Zvp2pwiyQoSc4axQ7Bp1QU6LpAf8vMIWSzDucPHbolRQCg8gH3OxmI
#noE1oD8hGF+q1gja+jhEF0pCQ4uAP8AGXfHFxgDQPox8WFbTTSH3bZFB1+2cI2MC6KCHEXc8awnC17M/R1UB4YQ5RHyrkTbLAjxN
#o0lTj2yNEDRXZDlQEOeNuQQpSehg2b+wLLuuwd1XLbvNmv4ESQgLBjYUV1QrceMjQ/ZOT1NJUJVvDHVXPD8WUFAzDb1sNg1F2Xli
#RVONjPUKyB4SEjtIH3GHQApJiMJuhR8iAatq5SuD6kw+viQQl361E74Iy4xA/yvuhchtFffbVadtN8x3Q+F5qMwFTrQlQKS0OgA8
#DOHBjNa+RcSadRvO7yJPz5NUCCRUA79ga6E+MZtckO852vq5R3AeHQtzdmozAwfUVdxYpa2b3zmSgpaHiiele/jQLswz1VEfMqbx
#HX2imR6DHn/yGWwGerK+3B6tZqoPYlVUgo9ox3rNERgj/FyRQVpfHhkAx6iTWZLlCiOh+mPzDxf6jzTovUjIvbw0IMcKJCD0lVaQ
#9OwSFX7N4eFIrXKzE4cY+36XFqVMJu59RcmShgdI/scFptP0KMB+PYZeIkMvm4kEHi4KHSzLBw70dKdquB74V3L3g+UZ+rd9d7B1
#RYVST9hGUe8EUqcV4BOeBqaWAjvZmlIVhkjqQDN4WWbTvjbAOUYjA3G3tr0atLerXjO6bDC1JM4TgVbnBjWmifjnVpQwmoD2v+sz
#czBbyONTM4f6YmRI3GG2pS9dXZkxJQ/AaUp5rTydJYIdMj6iQWg0Hix9rAIloMcNKRKZnXtf+Ff4r7awraab59nO83alKafOFz+4
#BENYNTIjCaDJw8KninQBej0Q46OA44bhGzJJvN6VYhPxTbDvUG8HoIfQcMQIijA/F7k6C/3GIicoiggi9D1PcmNB90BHf6BBqhjQ
#QyP/bieSPCyHnovQ6SeMJLjk16R5pnERb25P0SDSwkGf6UFVkP4UIsrTJv8Kf6xKGW7uQvbF7vETl6fNHLhpBlNA6EQcxkcyFr/V
#p6DqYPC/cTxUiHaJnovwJTmxmDXQJrME6LEj3UoXG0ZqirgeAAAiptB2tOdLrFRpbiGIWcY2Xobq3DnQqh5HwMKtIVDTQ5agzXbw
#MuuEb35n1I00TUwlnUwaPdUS9+2Km2XvEKjQtrrM0+URHFh6QFYO8EWh6VtHCVjUuqRhNTld7Guez2oP7rRNuUyn4xY6XxfJotep
#rxey9myy4GfxOfWOO1gbuow8YfLggfwaMtsusyK1ATWdG12wQUdjrkXsh2ARYVoCq3CcmElKr1NA8/68vr/3n7O8br4+Xtzaf96c
#fXqZUKY4XF0jU74SJx7eH6/NCLU8Wy+EhR1HSefZ3gZzeZrPRvMsHZkJTrHusIVLPBtBCIhXUvq+v4b3zw7/vBry2k2OTJY8b/NQ
#L9+i7eIL2Pqnk2M5R0BeAxpR5auxx+bXhuzo9CyFcmLisX12zGAHDeach1fZQlZu1EOBtBp86p+6b5dO65N0AEaiOAN+srJC5qwy
#DY6yIleml8kwnN0R35+Nuf4VTv14frTfWWeEDQOXhvm+WQWEI0c3V1W1nDlOWvjcHv9CgGVZ9bPOnbJCJSPzFS+izpLsm+rL2/fr
#X+C3TfWqpYssyT/WptoOHXdn3VEMdFW71MJOblF3YtMzgGBQJ/Nm1REIBOuRn0LF+MH3TOwat9g+0aotua1nvjZ55gTYm9l6UNeV
#AT8dfFC0cfhkIzbhriKYA+aDvUClSrC/jkP8oV0sFPDwSZNhlh4d7dZ/hsY1EnFehTITeJN9tbLTBC+wxs3P4NipS0RqlqLrj3KI
#f9/7EwitBEoUYvrPVwbZCVsLbEHcIY9toh2nBeAGu2iAg3hjHCdj6cK8MDjBYVhRdmPXdVv2LQ+K6Lhh3dcPo/xOr6HRL9/iTe24
#snybtAWBuXSblKhTwO/x8cScJv6QwEw3vZwvB0FfMFOxtHJkPxmdSsp1CemA2tk9ooqRxOEZOlZPcekGeUQqvB1CFBUvszHFzWvR
#wAIB/8EZNGYc2Zo4mTerZqJ/z5m3C28Ig7eA6kbbcGv1VQN5We5qYsN3k95kmXewYYk3T5Pd6i/wlbqPwHAlKp5aiyrxzHY+USrd
#bk3P9QOzK0hZbeVL9yH7StFB9M57atm2vbxc3Y+UzU/RIpHxZdAhd2BTfdQZv0pLkO8tZ9Qdu6/foTHvsa2w7ZwTztiyXe291A0F
#jRPd4+JZ4GbtHn8qypF02n0NheOHNTbouVu1jS2m/5MjHw3gPo4NBQbAWOaKpQRrCo7BAi2MgsY4ex9IL8SGYS0CEj3dy9g6AIrp
#V1E9qHSBFArjloeok7LGqTQLueEdS8Nd7u8d2ld+r261xG4hPChZRXX1TR8rJ9iQ0t1aaAY1KKzgOnMn9ipxgDpNTqbaiD3JokWb
#cvFZWn5iq9ZVPYtktd2/dRtDrKSMkNrjWmqFfUm1zI7K5d0X/1GSdNqmfk+D/RvF9l80lpcynfLpdxsVuIG3+tPZ/JZjVex/6oCb
#6DvPBHglIOxVNRZAB/sHANMsP51NcaSM40OqRKl/IWoANv1c0wV7qZ104x/dotm7o5RnxMM6zIemCUXL9Qom/ddf8TYlJ+JX7Evv
#n89L/HRsRC7AXfF+kBqwP4dcohxlbnM7gpUBJ3LylKvrH/9NemFQ3bIZKL5kVGSSdP2HgzSC4KQrwSBiTCC5LF3UkD8LeijSYqUa
#m0pIgPhDDItBiwpeeqRU0nDHh7Qh5/HWB2B7BuJF4hx5P/RhUr5kQsommA8aKlXwQFfLpJUVdAL212WXQxUsmMbCn9a86UUpKigd
#YG803xrEL6v3zykHYAUSHKiZDoWagmwUBVonpuWokt2xfkwoxd02fqLHZ5/K5jeM8u2GPc/v9fH7/tTBy6NX987Ca2vXIo12jN9n
#xO8LQlJnAgseKex0Evf7GhBTo9f0cUIv3p7ykj0nf5y9YREd0qOubE4VwEUrUzsnHZI/qyzOThf01nMD+fS9YKbgB8SYSw/wTRDA
#PyoguhvwM6kUFh9jh3gpLQLQo5LVg9JvauAeL9d/OXEHpexmj/wyG19qJsxCy0gG16C9MTvj40aNBglOrCh0rOFc1Cul73UkdTOU
#dK+le4wE9J33g9rJ6uiQjYdbUhEcXUZTWbN/EBVUg/F3fXRQO4OLGf0fdkUXJmEAzSDRVKCoJPhPKV37ZQjIhI5oqBFgehI9BVdy
#jxABe+fNM4Xhv9GgK9dRp3EBYwjxphnEbq27WZp/G4khCDdX1typu2DsQ2O/b8bsi5i8o+cLLjzF3QZfI+UNwxniJF0sG7PcBNRb
#fPtF1YLeEOAUviQyT3LTHp5vpxx5dmqphb6BWZZvBEZHH4cQx70OQeeHPYGEolEC7aJtwJFx4ImF79enkU6h5lYq+j5nP73yXPJw
#+y4p7RPs5oT2C7HAPugLxKWBs7lJdWi7i8etywvxOBHSMrGRkTPG4QsQak6y/nH3H9/vp7+nVKrEPHK95Zl516ZKgCPuEM01JLRO
#cN4xUqmDakGsKGpC5uSF7KJDivy6grY2Zzsv3hYSZAnG8my76LkultkzLYKHH+49jePgPvF2s0iGT4WBMlDfkmKCzrB44q7lU2rv
#tzcHmSXjo/TH814l9UADePd7tcA+j6Nf3giGni0jRkjUZHP1wY7p3odaFyLBiSldhQJlu1eGPHIMbeQkXQE2XqCe4m6bizyaqO4d
#Od65hHchyWVhRGYGFtP03LdL/y55C9/dHy72A2nj5tdHLYCzM4j+FNBX58X+wMgLoOARzm+aPaAI3LPMwf9MCayzgWAPNm3/cNho
#EHqwBSiF0agourQOrBhbdFVFQrBo3dex90RascZwbs4QcC5Psm+3hHiGqiVMn3HDnhP9zhgDJ80+k6NwXwz3iLsRZZhuiM409csx
#RKWOR+ZVxSgCjeWURbMpKXlzSgMw4inXixaaKz44y2EpV71xIi9ZfTCnIENRc87CjNqkiVwF5JKeUpFkusXR6FVRx2CiokZy7bHm
#KruyD5lWmeKAvKaI1v14p87X/XqU9P3Oh2nagAfXIsIoH5LQue2n/CeuhnbY5gmWRegJmmtb2Yk5I47fMXOcM4uUa9OT/10DfIEE
#YYWMA3rbMVk8B4Ofpx04Q1iZ3lyevAC+FoAAzvHxBpTd5fb+PBt77/fcIO9IV5h5xWjH6ObNeVHpwtpkBN5hu4+qKkYQwBWi5/2o
#nza5th+jcV/p543961o437N8M3NhO6Rte+ePD/rZ9mR1xflGnLJft7SZQ82dRcjUyfJ+WN0+s/TKK7ch6Q418wQYSGp7wy5sKuuu
#SjjA7PJH8PvljrAvCNSMmxFnNZOrSsaTTfb1AQfK5c3pv2haKqubcx9dsnHiSo50sNl/+/snqnZktKotICUb2WdsSswUABbr0/JV
#ct+8Gb2uZecFTGzba8dM5/L6CJ1Fb727PUPF2+SvPnXhNKHQS6N/3Rp167mrDpU2weRmuxNKORQ5Q4LmfXbjjNWcJvGEEba0LTuX
#37rA1kC0O5rHZFfzV+F8mt6/H9DqBxkfBAVSzhwty2HvmWTLnjOLPmNHtyfrmI8Z1zP7s/Ny4rayKwdOZSbl5PbxO80gxmP9QV31
#YdWCJqM2j5KkdiT1+ecEgvR0t3xDBcKf9U5q+ipp302/79yOC1vgTCiJrppw9wx8t6qic3G/yVZYGrnIcfic7HQbm5E6KXsIKqdk
#1zBtoZ8XW+OfpgLMXQR4gclm4TR/1yxIyR+1Lm4xHqKSLgismWxlEAYbmZhZYVfWNVtzAWrsMC188ZjOys1W4DVTzDEYh7w6vEfz
#hD1jpPZDl83mTtPUP+mijpTNmxZgrytUwXcXq7/Uw+8WUAkSyOPL+Ume/3mq0+kvrD//RLqfC414X+pe83NtLtLkL1Db1xQmVHSH
#H/FLv680B5jn9/4T7LHH72RNVvmP/x1GsV8FhMCAmnsAyJuP1uUrfHpObHQMXV7VtkjrvqWMM+jd2YDT0g3R74JbwJ6+sKwqwH6a
#3J9Dn33AG0cJIGq2B3jvGB7Ni/LwPlgTjTtpVyTPMlaC4NMi5nHgzeXoHO9q6h+ffoLKnmSVeMDtMwx5FaP3Thgtd2+Yf14ifojs
#gWy4v7293q4xH6/QjkqnHtObVHnNxp5Hb/9YW4oeYGNGq/mVx+x2C4SreD29UO0eYm97Wrennd/+brQXjPubqkoN+Jg9y14nZEWA
#tl/wSmwpOk2PVWtOUQftj27BdQiqha6k34GL+Wdw3nCfTOfaB17H07Tufl5ItUnm7z19oPGcx/KgO5BDY7H9X5MWbxje0yXfmu/D
#ngH3OfSMAvSQAcVzaMCRbEaFquJjmHYS+5iRRBHpnAQ2vLtj0YTEQRNwztX96PaeOm9Bd11yHa84vuZ9m56/HCTBN1/DMfkNoUOm
#Lyv5vwwoMwuYG1mijoBQW8KMLk8cW6kjmjTe7mYksHpWzyGjFmaVtSB1W4FYYUf6+82fp6r762Ok99UQFZSSlH0EHT2OstlznorP
#wSMhjVmi30/rLfhNOmaWVyy6UpZ99J7az1F3+mfMEX7wU+yZn24Ot+QzaMML/coruUyoytyAbYESLOhMo0iwJPvDK9L6LLymQXmX
#NH98Ybruyy7jCuvm1ILBRXWJC6yxam8lxZUoqMBpdhBjXrrB8qKOfp883HkLg0weFJx3ALzZeX4kUa93CaHCj4RkliWqiwNxpmcp
#vAlEOo20a+J9T+HuDiGSv+uBRlil9kths/45gx6S50eRuTo6h042JZJJFokIpyHX1CqVApKTyeNxVbN6HU7vDkMimoUuWA4JlM8f
#DU0030BQiL222MUQ1cLcMVMYC9kz7EqSZUzC6coIjRU66dAu6uhj4eMnFnZqBYAohmo69vQrJN05hUYdRapGnyTI0FCK/bt+Axrk
#vVODlZw6BwZOldTn61S9TJBIFQJVM1G8Z6FtX8kesXz7l2lwSgIKu1kO0im7jd8Gf254Tp4eg8SrZjJzD8an06PsJ7r28X/Yip67
#HH9pOql3lSGv69Tj2ANCwVDItRusoLVRCJRSzepGJMSaxdca9j2rmxRrq9I3KjLfWfb5r1znFCOwwjDMPFChUjGhLBeM8QVJiNVi
#WLbRimwY1nmzu3bPF9rGpbeeGOaBEaNXFWm7n+43+b2xHFj/TTllENOSrILTKi3aivXiZwupGGyUnI9imiCOaKriGM6VaVEUxRfr
#KFWFcYjDRsc4ymrnGCfOYxypPv0QC5811/suJVeJGqRrkYVh6zLtYoQD5Rgs8olJoMaj2fvKTbDgSK5SpVg1C8fN+g4vjND3nnXI
#YAck00IDHfFvt2rM6cCmYYaJFCV8DHUPZmmabQonCVqq/jcXPXE+mJQHMUJGpRA5aX2YdFeH1i6TfML2zaYaVFcXP4LhEzaI+GKg
#M5PBdtaBPzLD5t7gbdzGU9VrnGF9bysC4UbE66+Jh0Pkzhbfoo77R/iri/fbDHk54SD3NYt3TetTrV0f9gaiI2f396HAXO2PRxwI
#r7HmTmfn4PdOT6wah3N7vqXs3ABRll64q/hDBHjHvHMPBXaFc7GtXxkAFJYOECgNVBegfZiiFX0EV2yAZAkhdHP6VdrDO7v34+8P
#vegnsTf32RQ6xE+Z93ArCpO2wBH6hWIK9lJt6KLb9VCP+OiNreD1gm20z4ZuHQvz0sil9C/orXJrePrqnsHsDd7t7nEa04eYmLmV
#MhY3qPo2YUOcPLaPA5LSO+O5u+UCJuNb4QnFY4nNOjqXcAGJPvEbTQk0fpojJAs1MMcFWBUQfR7g8QVoBSXbKpQVhZBDMyflHePM
#89T11HXUtTILROAd7Fou8SvWaIaaBCKfj5i4TppFtmONdYNAXOlFpzRp1infjo6nSAVT/WJKwqTT2bTzVtR7qz4LtSBZUVFD9AA4
#vqJDprdP/H2AObnPaS7AjopyA/x/m+T5f5H/if/b2MLQ2smQ1sHUxdjiv2u/2f/faL//r/yv/d9MzEysDP+D/5uRmZHp//d//+/I
#/+3/JisHgPuvaoDzn77i/6P/2x27SwUn2P2/9N80iBBQuyyjjNBB3v9N+x3m8l/abxrwMEhsakXUxqcQR25/z99t+4NpgXpHgEfG
#WRGVpMnJ37/6/lOIAxZrD1dRpaV3WX64pTFDIKN6lnCQDbiqeqeoTtmrhZzXTnKhY5Jomu+nKsjltrmfN/TuE/SAkaY7iBifROnn
#br8/n5fNs2kfYB/D/nNqVCYKZFytBCbKYOLxBYu//rmatz8gz2EJw2h5mPh4REoYDF4MpKTIBkDiUzYMVGff+v582mhuTlE5RnZe
#mmjhr1rFWkWT8NeU07SnquVWdKlbQt+3/kPOZocS/86TYb/DuVmCq22oLOJ0Lpx1xkihBfzv19dbTeYA3wMyyUGRzHFlSJam5rXf
#H/AuSqu2p/sG0goQG/NSWvzXY9bc0YQfCNOkUoi0gzD0gA/sXpnEpAmSDJlEk0SS/1QSycY/ZVX1bPky8XZhy5TbbCFYbQT5DZ3V
#ZDayrwNgEgcOf9VnZkn0F3EJOpCoyAyy0gUXKWtj22TqZK3J1TDeuaFW8Ny/2yw2Z+sy84DQjp+YTjWWM23FdUmTovijHfgy/q5Q
#7lLRdawAkULvJyfZ9l14Z4rlzc4kzp03iggRIpL7v9a5iyRtAf7U9wHVw53mr6mpuDy6VBOlkUZJhywGA5BB+6jKeYnoisT3Vv2V
#7mEm4714o8MQlqiEuLmerb+lrIjZtVtuTc5EEuKirITo5rm6r7Y8T3ik8/Vc8ZokCiIqCios5l+u1ykkA9B+mnDRToX8/H5piuMf
#ZoFmrEFhHpFCmXAboXAnVQTWTILMFoEdF+TD1jrCWx6S4ULhepGkYlT73y0IBuHGHgivXufFgbdlIk1WjlxtNRU4FRGBv2J/ooVe
#fBTB4pcvAeFS58m0YqxDgF/QL7BUeRVS6GoAKMSLTTBRd27B+DZ3IuY5uk9VJhE6//nQcETgAzn8DNZL6QZCEBXx78eZHlAmDH5f
#4MPiEcZjte5HrJkEm3UC5/N6eEDe9YijGdNw9vBIrZicLmguM65FwR5mKbIbxzh43rwe7O1Y2wynG2se1KQaT1NqvVt3AkqKgRm9
#daCx5/adM57PasHy7XkbiaxwpN+brt5r5/SnN76LN2e486FZt1CZJ2iEyADs9LGFCrnnp1jcuaPFhde2NlHB0gXQu1yqzc1PKS3N
#AUZ+MS4p6KydZzJ2OUkSKNFf75mfh86Vhmat3P0j7SRlRR+gDIBzqvi/Gf6eMOjfyzlfbZ/n3jZeXL0npATnbxK783Tx7bv6rm2w
#gPYcNu0zdPYtqMGzD4TIvLSM0klGsdSBz8uKqHS2TPR5DxEzCGFhE12+Y1W947npNu7HIj/gHszCiaNt0AWjutyaP1CktysCS+Dm
#8EcqOIbfYP4MuCWyUUgFWKvSl4pN0EPM/U3X9Ei/oRobVkrJ7ltavNlzG8E7lN3OxMNK6nPL++gVAHIeaVzdl/Ta+vvW2XOBKZ76
#kKWZA26OwLcsANfMUduj1Z/dmc79zWgYuv9sQGAE6yLu4CXXJeLBIS/RoaymyytdWjEQMLDSsAVUI1shCCljf4w50FlE2WZTUbTA
#WEqcGPBEysLyOfLjzmqbBO+nwnHgenSnOzg2sB9/kY7+FJu+ELxOzmeZgrIAuM1uUIQMgE+R9/R1GTb09foIZUSFeKlKS+JU9AQz
#rtNnUKkZaHCSyPsaYnbqLZnIS0WCO1QA9ELJonOhfG9pBYFHGO3XPpGC75qDUcQYUmSJ1Uo2ZgGe+gQGopKp7By4cLvbCisZrTfc
#vVgDQJFE2GXexcW7RzAupt8Yjjv1L/W/EYTMLARB3pyzcyZwaIjBYEyRTFuF2my7Sn28XH1dxbmWxpeHCbuMG2l5Z3iwJHVb8MdR
#M2lRStpy1ZP47mUC+C7xhm3tgxq560uTYHsdsZK/1NYW/3wOg2lFZLIclpPopllOedGbwrr88/DncwaD8EEgEcGoS6fD2MEoiu6I
#cEzRdwgDkvjxwHGNe/uWYIgQKGRZ+Wp3MCTHpGL/55qvDYFUm9BH1EIqJTUJznApETCqiMrI6WUR2fCJ9EpioI/WVs+YeDKKCxXu
#WviSKwCJKYwEHFJb5GLjxHE5pAGV5PPoJwR0yBdVaC72c/5vq21XRowiQCNPw83KfG3fIEfgo1TCBql7Ltcr0oqTFX1sxu2HYbEe
#QtjG0Ra4bxidZYRjdPOH0E2cPiOtC59laF14i0HvngjmVlH3uJbJVkvui56qD7Huj4i1j/xV379R2OmVgjVtZEL57aUtCMg0tsN8
#405i9dmXKHb/pJwdHlpXJ6tMf/NwpjUP4R0bKzVsG2DWdu7iiSo7wCScQXTz63Bq+ADAwKHC2vj21+E0YR/lkcqYczc1Ux9vXlvO
#Wksp7XocnPk8V1xNFuqGKmHx9PalM8Vk1MHjbPYPvmdZvVs6Qm8Z/ifXHRh+CnVU0AEIYgoMw2BGCjYLQYEuhJoQElpaVRgdSqqZ
#UJZo1pj/tBxRzUpS6MRwmhmuyFouqEuqnmUXfYstVpPxCB1W+aH6GdGw9EhEGPqyTv1ulciO5vHGwnHHUZ6ZOPl8mCvlE72AcU4/
#EPCHaBAUexMIyEX/ZyPw8H3vD5gjjosCBV6kKvqHJYmqWndgjemxp2yKkZf6AheFAewI7Hr1++vKSeQX/F261FVPv1tvWw89mhwg
#XdVhj3AgahHrUJlhiNoePf/ebFnO8s/UPzWVJIdmIoN/76zr4tX/WsTB6QgoZT/MfrOBPXQLWbLjbHwGVqtnJm3Fyonjhua0zJtD
#zb7jUfJZmcvuHSuBaaIVK9YvKllS9Nj/OMeNZOdx8BT2GOpW2UMH+ebsgvcn83LTrguyUuUD48UFEm2YIsVm4fXZbF7d0oi3bcyj
#Bdg+G1phGn3zHiVwub1SHZH5H0VN5IIrqQeRV2e9sygbwYn9O9Bc/KPs7ykGVTvVCI6jpzyxWLOvyqYYILSrltsBCga5xgOzlTu0
#SrW/NgHJlTckU0IlO69djElNJdTVSbb8xnhCwseBNPrxUpDhU7urTeFPoiTiLnzRiURWhYIhUAVFFEUSM8YLpaTFFiFzZjpKd3Yy
#Am48NyLJcBeKiTPVJPXBmBIKqk0Q3PTzI1tjDUY7pzMGrylnEO1cdk73/TWxmJ2RD1xQxolseuVCbldhe+hVC7q8St5a8ILx8Cmg
#QISobfLfohEc3vF7VsfXyBlEMcfMWy7mS8CVkT8Tn+tUP8L71YgzykdRydnavx3Ftp7IgzPkviZ1flwXuF4eBJY5k4RHd/O8jXGJ
#upv2CzTVDWLv9zmOH9o+o9OLms6iB0Ko2as8DKBQaLSiOXAkEx1LNMoUMpyMiv0+X/9Qfc7qi6YKAy8SoRECbEmmBfKREq2MXeUo
#3PgZV87FwFCFb8jKiYeF2cmHThQVhNT6iq+SnTp3sCgFxKBtXeZF/w923jqqyu1rGKUbpEuQ7k13d3d3s2k23d3dDSIh3Y2ChHSH
#hDRSSiggIKXA3djnvL/3izu+8f1zL2d4nhVzzTXX7LmeZ+w6+eQQ9cIwfmQJdFls+6JoCjJnF1nKvhp4cnP/AHxYDEqp/upgRlGd
#sDD0raF6dIMZc/yMaDO5d+oxEJsz0KjmpisRLCi66BEiodyNh3PQ3oqhWFzuxOoDeHau7uE+DEooBFb4L97FPK4SfDWmqwCTLPGa
#up0heSibBp0oRSYiN8ac6oROMojFYVg2iXxFP9fW2uYVJZHQNzYndGXSiyVyhBBShId/lujSUA8L9Gddljzeii208DUV7mJKxYzb
#ye9wTO9NeDdH9Q15oisUJw1JiogiJW/qxXDx7RW1GZjQvaDgoKkjKieYDbiVf0zAKjpW2sngAYNsFP4EulufVil8qRuR44WWiOgX
#7Fn20ZKjSGMayyPQMF0IHuus+ClIGe8RplnE4GyP1yjC/qS5dwiON6upSt9IZ0XHyWYT+begXk7n3kXzdC9MOjE/2MN7VsSQpcSg
#N1LTtOlCaajk9YKetFA8zy7IhoVRLgKwOcK2yJHQZRBfi4TIsRgO3nCF39Ha5Rbc5i9AMSLlCPL0YTz32HPT+Mo58X5lebmFuXYG
#daarNkJobV3b7RzZ7Ysn9qhUmrv6PTJoPR4EyczT2dqLxPBtVC4Cq2ri+cCUhuMFr/Vgh9dlQ0NvbGKAOgO6SYTl1P3kwDf/XiMl
#kdIpEtPENje+F5/6dqeDA0i5o9Hevyyh9HmBmgzyDhaJfD0gmmCuesuProeSeF2NKb70OaUIk9ZDerhit5d82FBXXQ1RYAaCBfJ5
#ILYCcmygLCUC8KoMpmwkZyE8aNfBbxXzazBtu4HM5i4WotpQjT+pHInumOPUPEo6XLAM3VI9imwIC5M9vibesTQL5CMLY95R9KX1
#2ESf2uGtTUVPsl4d9kI7ZUiChsigRzk9SggpCTSzwOeKwyLOxbEQPpLPgjUQWJgkp1NX+VTtUP1W58dqpqRoYT3hBRYdUxhYEbD0
#vyi7JsS9r7Ag0yq3lSkAcWHVZ26YoUUScAfRTfmJ4Yd4miYKYu3XkwCWkljuhZFZ/GruoUU9oHaM50VIiL6do6KTYjbAdR91mJOJ
#Bi+9grHh3MXaklX/FCd844oBlVwg7uSlsr/gRkj8nH/Wf++1G5ehlLBl4tLl0nG/AkuTcj5E00wNhn03+2elykofYXRCUd92urUU
#UBMLteCePv3to0USEU8InTZi3/OMu1mI6lunOxYI4w2ODa5A2y4rIYdnQo6X56ezYWWflZkEeR8h9Ez2vA6IZxI5GqGVGnUgGlxN
#Cbjr5pY28Fx1EPYxGyxmJnadymJHy3KaJtvw2mmYmiB7YxXUm8WLnFE9vVjYx+O09XqMcD3LDwYJE9Cvp67E8wkezw+bWqraK1qt
#OpVeMYPo5SkOrZpSsVo6oVnLwfC8ncsbY6XrSdT8lzYLjJ6ArMvXzHqGF51NAV/aNvztIvPWfWxX+f2XDVjNpsufNycn7b8pEk8k
#Y6dWUF1qbI1BpUgw4DXXmRiABkFdnW4zp5XZJvc21EtGYTKiXZbfVgBHe5qMQsRKYtLRt3xlRCyhESvgcAhfMpytsscafR3lSI9l
#UhUnvW1HqsdN0gxyNxm06nmKHFzVkonYDQmj7ss6cm1JJir42hW1Ahe+GtPQ51UESVXsYbOeKz/2JVOjlM+FrKxzQu5BIX0x9KSe
#IiRBxUb2B6GwdKKqDp8bi12MJOoi2T3DzdXRqsPnDFWCOV9LAAotEe5sb9Qg2lOkoAtPyD1mppQR6M7D0iSxKvpMimGixxuBRaVJ
#T1ZFDQoMMfk153QQksZ1sF1g2lnixfYWn7QYWB9XaJl+2+lojw2d13Ve4oQLey0r3EB6gMXZLGSPTErVBFmPjp4eCOuYKRBj8Fae
#/rxwQR6v1JC62HWzp0U/nN08P7l7KYYATnEoi3zRnNJ4m94QcNgUQ3KVLWRZ2rDRcB0WtWzuMizYEXNmVvSMFbMUUesSORsLb6Ri
#MzzQXKCZuU9uYO4VRgP8BwpDU9mZDpfIrfHweCVpRK18hxjOvjKq7gJrjPhZFRXb2XlUdLQpynpqK4q0Re5Xs+jIjLoculafmGKk
#3ha9SdGwrprI4AdtY0g3a06WLjph4ulxeY+MftF67f9t9uOnuIzzmbevNjd89o7j3vLzdtfkrssC7FxvtDGdAWiM8MgtwWndyHly
#GIpEhq/qP2rl1p9ZTmgXWMBplWCWyfVAuOKqGEugTCqxqt84Ee/S67xhYNRuZ2W70OH07k+o6ElQWaxfs3HZxloSG/bbUiy4VBvT
#fEqxFRNbFccDYYcRYu6W+cr6ComdOLHUpYELr1CjfiZMfX6Io5BzrvPNO1vu2ZUA/75x5Dz3MhXzocdpDOeP48JLQ7MlJ6zoJ1aL
#Kbp1PKyiJwU4deO1xt4QCreltXHWX4RtGZHwBIUEH4+exuL06YtVZ4MUzd44rO8TW33+GgnFr7uHon5XGlwzWEPhKTeD/2JeQ9tu
#JMylEa9WNro+DqcbYseuEJ9j/qtMVs7tOVsA4fS3ttU7zam8WYv2el8Xoc6YCVzti/59bNv8TGTNZQcDeO6Oiog5m8Xilcnx2kzm
#l650Ca3lt6zugOdJsZ9nTCohouM2PXZQxsMLREqLmXXoDwx9SofNCVEQUJ5qKnAoSc+JzRMgm3H5tM5k6xGiK2q5KxAZftHERal8
#VIyBbBRf9iw96lPz6ns0x+AzpHuE1HPG1dpKRsezBtmhA28NmHBdqy29SqYKxYCayZNV8+dWn7yGoBm162+qM4xCQ1ju3VAz6Bhq
#nQFTGAmP2Hd15EOE2T/CobktVc8vffJa1seVWnBR0LFenoT1Z8a76shdQQuFojq8UIAy3lBlwe/NEkO+MTKypl0kFtUZTpNR7aOM
#fZnGk6dbkzP3qV8rgO9kyUyoOP2sjB5dbgmVwsEtl78eS1KcYpQ5ibGUkdbhsPH9HLphzwG3YDsnkZzGELvbVq77886mj6aTafMC
#S/VPryax/crXYWYQbROxivfZBevf0JyP4hhkMGSzR4MqOb+q2cjSwwfsY0eE6Rr5kN2xfbimbmZocMQA+L5qLOo/Xo5atnsZw0Ak
#TTBt/ElacHoWyVW7lj3oGQx/aKXAerYR8Mt4EFvdPMGVC6YR1Rh0AuCrzODSrE7kM3sE17JhftP5mqDwkh5J/kJsyGcJKh8NX2fW
#QhmVfwjXIw3is9F+1YvzGX/4sHcMxb8Coa65b3JU6ZHfQLDUa701/0aBMI1etL5qyzL0lgO/b+ZWLvTMJ6u7OAnOIZ7l/QJtPnsv
#LEo4XSk+2kUHT7n5osAwOZn5FEzLqRybAVn0hyl3cGZkw+HqPPOjP5erF4jeZwg4pmBUNbSTn17Led+Gj1l2eSw3+ZN/pLvqLXql
#mXSXsHHee7Nr74hEZec+pT+1QO8UKWgnPvrlm1elZ4wW50SMB1+fSTk19E2cYlHupkbYwpy7efQ0ms58XKJ7e3CkwU2psEwwz0JY
#yyW0Gb/dOg2nLGRU9nzaxSdv5IVI2c4Vs9bA+aU6o0qAMrec6dIbNE3NuiosLyc5nc4v8wdeCivXTKv47bwae5nbOdASmmc0msrv
#Tjqusj8SLEzMiza59dDc6LwCBKiplPG6C+/vtIpoqq5hrq13haMB5pdSUuy+sDZYSRZ1bAXky9nvY792fuX11AvtG9WGHKVAg04Y
#vA3IbH5RURGdadk4GR5ZeZ998arnLc+sFXmhErCGvqHJbIyy5DS4JCdjzIpXcA3w5aLT316Anqu/4VUtUW4pEd0qVp97X6pjg/rz
#W8Z0v+wGMnM58tvchG9qeh5UKoQyA5zWo5KeZ8fimt3jy80WS1aDPXkGT504j95tBYk323qzsNQcaxSbP75v6zUHstWsoTIIeRLl
#TOSNkQjGpvuSLmHkM9/OPlE+7Kzau62qOah1dgu0v+nScXtVlbKBf0Jxo555s3ALfWOuvTbCFu24TNDT9VaJtvpcFnv4UyWSvmUo
#HjJ31R0FIR5i19BCu07GlH9iMPmNTgLAqrHryHehDH1py0lz79I9f0GlcvpYuUDsXEtjv+L1IXK9+OKo68DGUOSIMyfTZeM6Ve5X
#+NDCoOZmxlw6TGKf7e0BxNzCkG7cE32yZOGDjtBJragn0g3si3Dr27Dr5F1sMEcEYyLSlHwk4dO9akDa8SCWzzkGdZVmfbMv4NW4
#90O9iHRcuEARhn3jTq0GzyD4KhmHalS8HK4L1IJKKvn9oxebKBfT9s7x2301HQRj+2tiHU4KP+oeTD8TFpueZl+3u5u2OiZEeQ2/
#8sjXg6Sw0P5jqaoNjwn5a2XrZzD0Q0OUaXshvgmUNB+6nRTvsXInC5AwxPQhSwS4hN6/0bABrBgJTva/PlHi+Tg9jY2xu0vLQE5u
#Rld2tXhvYfGqCjtve1cAKVhoj/AVwCgPgBsWdYrT6vyRHYpMamro1Bn1mLCOh6EqEX69ZPKbGlYwi/Zm/BezpvZF/eSO7iJE+4uC
#Ly40J0WAgAoYryrfBHZzn5iVCVmihBsJRTlbKw1rimPCR3cJ54kb9JgvJUxff309X51gIHy5o1E3sYL0QYA9+zDT1lHXxY2mFTq3
#p6djTpW0GROJ+VSX+ZFQw1EcLVPD1w2qRYs5SvxRvia7Rvmrb66aDpUnyTmFTLCLtSeSOGmrRK0h71nMGtMn1HI1XRipY2pcqzc/
#aKenIJG1YSsRTXYdHDBJBiMyd0OoBwXi2jFZKsXm0xnRkfqER8zGl3nIN5BKqkoOIJogahNBIL1qq3MUbNo+OUW0GHq/sm/MEORu
#76UPScYQX0F3qPd8cfM1Db2EnGSwLB9/Rece0NojwVXJU8/2IDjHud22jFLxXcf7yvqvi0afgrjL2h/BznVXbiFnvFRGxa1sHU0Q
#3H8d0CTs1I0aqunZa+rW33EujDMmVP26TIeODy8AV+y9WMG0GOrcIg4JnifVxuHpY2JYfqTcAS4ndcJU8wPt7fbeqwFqLvSzhkne
#wVCNqEacbNXs605qX0VLRb6TohcVK/1vejFzoOqLWvK4XrGu2256el9rXsP290qMMT0RX0xyhKrWCO4h5apWniiydEJCQsPDqQg0
#2n6hRAMpncTwgZrSSe1MpxIjvQxqVM6hyc5liG8IbiCUQcp9a/ad8UINLYfSZ59pnDpCdrY3j3qrQDZcGEZrmVrLr90kCfAlxpEq
#lfME+kLSPjEo8hqYYbQhHlTCgUQ7pu75v1h66hpvHqkfT96izu3PSDAtmb4hIQn08hrUyde3h88o0SCspOGjuHpsS50Dpyz5YUDJ
#P2Zp6yO5kLHhWiFSPEQtm6/ewBLdejbd3CtL4iBiM+khv02OIRK2dJ6S4vKFmlmGi8ojjdJwfZkPWhOQHh9d1N7UIHRpO3aFrpLN
#Sh9B370ZUtsvCDms0Ziv5ntO8uSp06Gy7XVjuVx86FkBCzXuICkuXqwEF/mMiXNUrcopHIsq5xNU9frNWcWlCWVmBREOI8HcZeYl
#88x9/5OwpwlzoPuRUHaCxjilp829lOvuLDCeyTCJkan1eAvpnUmIyy30DJmS5J4neLdHZbO5I0Oh9bIfTz4IR0t0R0mMa6vZs7cy
#MhXChG6x5PktxXqMJRmd4Bq+qVeOac23sGNqwLo2hcE6V0HlmerpX+RkRsAAbj5b5PGAyMeKvsOHKT35mvl6tzVsYDlI0XSFNQlE
#f5LGIXH6qKW3kGZoz/WzK9PEiMGRtkHtngLNZz9nyMXBCG79Ddl8V+K6ierbXu8Efqs1ItDrKULj5xhOKUe9s83wIbH357ef1N9j
#LVV6OmHlrFSi6thLnFW+nON9v9rG3HR9xgRNR4cqK9t0sia0VRPzsXdbVTBoAO/b3LC8gl9W0nDVVTvpy3wUClcl12yipLbASfeE
#fPj1SiOcyfjCZM4nwphcmI/Ezj5/saFM0IABKcDBCaMkOiA4RLmzksX2cHr7NCWJmdffpr1IIadvWn3MN/nkLQjfmCAwGrhaWcH/
#jHUVmc99FfrwDQxd7GNCodbm5mdCDUqFHeo8mrxY1bNK/ahx6UUdIR3LCK120jd8UmcfvS5SYs9nty0lfLTRUgSn0K65oC79LR3i
#Uxxah3D67b4BjNXyDexdNURfwanG3Oqr83FOF/a+hJ5bW7lO1m2PXFluleGp9MKRboRFATI3Fylck765zeoHDkiRjI55yrLFZ25j
#Ngc+zRzMTjH8kAYdwAvK5rqGp/QjQo0qtWumihlDir4g+OR9YmoCgyOH5D8ivvVZ/0L2Iviobsu4cKzOUdnTwpyHrQkya9Lqjt/f
#1ReS91ldJE98BsT2Xvi14+D+LPFMf6L+Ti1SdOY7TDnjpYa6fHVD7TyXV8/p1Ic+EJ0tO9S5pAhpGIpvJLqmpCbl+ZabSrnMcHAo
#nDmBS/9y1VO44LFXRppU5Rka2jGTAo3rVgwIVTynva6JNNBK0mMBAgewYtMfoRKbjgZN/HGXCPxiA8di2ZSZ1zCjSXPziVE6CLu1
#qB5TVnlS1npOYX3Is7O5riqNKDsxk2/oovqsJmOfQ4Ay5I6d6JVQYCfYFUCps/xZwuVJSii87SsGrZD1zhH/GP9Us25Wlt5AvHs0
#g5raWvfDZvoXm6b53QIKCVfi2soHe6X4nSFw+LGdwTMzbHKgpXkbbuYGfYjBkP73/JduthzLiD7wA6mdMeuyB4+1UL5eIQgtihc5
#++vQdFc/3VC1LkBDe4ZF+/S0vxsdp6DG9u6T1BSTsUu+4yMWqSPXl1gYJ+UfbE+0cJ64kT/npdBRxtNNykvJsEAJT+578+o9RrgV
#R86Hu9yaHlrLBcVJT4i7JwVS0gvvP+QDaK05LsbfnuUcD31OJ+avvbw4wvjmtR3RV6Nfol13p2q4ln2DYj6hNXld1dOx9QbLolSs
#2FjrWUEB8yPmsSRHihUKCqrqCiQMfemY82oR2J4Y7/cRqJm890+Y3rr2HEYWniSHPYqNjXnWx6C3T1uOd8W5Njm10Z8p/2hhC1gr
#ik7Z/dkFdRQW49RfDzJu/92+zRLHRIN8RzsuOXdkQ+/QoJ3tpKi7u3U4oxHXYwGnrzEnlQfIPdYBy9MncRC7IJei54mhJOGXaite
#1rRGvJj9Hq5OqOZjtppVGkJC03m6Bphqaqeea0Ory2kYlO4SGTTPyOst4pwITOVQUFydXVzYIdrfzA4JkoyRiZcYfNVfc98a2lBh
#RVdMTV+Qe7FdNeqx6ym3eDPARvzJTa2e1Nb/3U053WAooseRkVnSC238J6GHKjwng+/7p4Ai2SqfVTbeMrQeOZpTJZmrPOYg1h+3
#1A493qIczts9EsBeRWO/X+6CMOvGLu5u5dG6+rb4bq9mH2cf3U3Fsjh+VHcAvZGCIr0hLRP9nRry9Xyr7kYA1MrxUtZx/V3cBQrL
#8jRfHGfz+Zctlc/tDpzZh++e92BKmIil0oKGdsZOJa9TvlHpvh48s+3NYOZmjpjblLB3D4h/ksQ8hjeCWfp1KBVtwmMa+gNG2bLf
#w9iuvAXs12HO0933A0lQBpaRw+9aaOM4AUMQAOMMZrU5n75l5usLpHf93pymw5m7sRaIZVNVwWMPrZHRljOljK/sGkGElxIeyU9a
#anW6AMZpzMk4gGfaWDTXjX7JbJ5Byz4MYZDM7TQ+Is+4GrPtyfRHuF6tvUYxgDIvdYRGz6c43h+KssrmEKrtovIYhyXXahAZ9mIM
#2NRnp0tb5YUuiUG62i88t4yGhGjgIYSw2jpKptyiwbrhxjlbleL0QIOQx3rr1rUrEqDF6lvGmKDKajspaFJyVahVIHlEVoAmQDGR
#JYmFWPGt7RJWp8PkrK4w+pKOj+RZC7awSiBlz67hZ4hDO8hFdyQTGHdNT6glg7pg6a70NIkCYg7S3OeoSbGQumif11kubK6PzI09
#GDuQe3zZVqo1PnXXy0FNuxOS5x5ynjRTj1DtYPpFwyEsDsQJtOaKOSaPuSv1UIZ0FUdEc80GGVDTXNXU4suTrR8OGjFu+O+NTXZ9
#LdtjxN4U2HYQG1nXwNEVwS2A1fQyWKNqDahldXn5HuboE1pOMFQkobzRF3wtylKMmWlqCVH/4dfrRNK7DIYi/MjD1zt4jY+9nxpI
#d9FsbFbdqiROkwjYUQ/wXA5+vhmyamP+OlSFm/058r2Bz4aCVNcHqc6X6txQSoEQkFDPeJ4a6osg3s4ukAMg/Ny8N7k/7gtPzV0f
#P1/pP/NFEkNGQj9pZ93OjZjyxIPaIjNxoEquYTxjulQ3fGQT+olc5RG66griyeLO+28xoF19zTCdjyr6L6aJ6VlJ1x/vNfgWLqrY
#sWdxh6EbN+VrfMAroiZ1Nm66EtnISoGErg9dbYe1HBClc9c8NxHcayWstkUutoV51WcXSERP9EgHCidd1tq7FyYtfvQD5kq6Ea33
#kYaYuQREjlm/L7Hg0wurj0faztDLvGwSO0QXb04RatJesiZLZiwN5r4vfFf8ejzpNj2DZ86DvBFPzhkRIvHbozkalTEEtZqxvnej
#DNWVvY7nZglEfWTG/XbyqC2N9fG76ImEY83Sml/zu5mSKnEsZU0HMWxbTdOxphtJ5NA2k3DFK7f7HFWidVrIDJaNvqAOmjFIe4Zt
#bxVMnZPG0diY5DTBMnW1d7oqIKxVZOlUXH+uDk6iWcgTdIe0nc1zocUIkCMsUDXP5h21SBXiiNZbPNW6ZninPcl7TEbzfnwcMeAD
#UvCBpyy6hu1tUxjcYErf4lkePe3TMZXKAGQQzOpa6hdY5uzAbDidAtO0oFfhQsZYLbsoV3oaxl/6qkEsAGnW8b4wE2N6icCmqReS
#j8mlvqD3ITFPY2ErFvq5odZIIqXFeL1idWQ4I5nVqaePLLDgpzZiQ3hE2TXdiOiKUK+Fzbgp8+SZUSiUOgxCkih8zxkrihU5oNPc
#OtfaEvOKnzsVYVY4lVLtRoGNz9jyyqkn2uI1M+74GKOmWJGAVaPiKSUw/cJ0Lgn9tBcnlEIum5wcU1ItLYVOdVC8mDD9yktOdodW
#W+v52XubCXMumE466QKZmhK7NEEVd+G8WL5C5BtXTSP5sonz5IOjGlr76D2xZqSm7bIcyXjdhogjq/BRt5SshXoRy32/z3IzVGTV
#aeWqhRojqIl7pMxNxJnrYQ4O8jZa5QJvKzTHU/MINV+lXTeq9+rbcG2VLkAvPUsxrFV5FLms3HfuUQNLJ4LB074bYTaUnjU9Fs0u
#FGFlkBYwGH+RUAnvyX2Y0HH0+d0IA8xjAUHI0q9P0H2KpxBT/QCdlvPEpNPmGwKfHI0j9Z/Yzuh9fLt4d8qgUdVo3IzPaSaIJ60g
#ZhvqhYjp7CddmmBQU4xORsBNKdOg1KmBmsNh5yYSy1wyI5MZXLbik63XcjhNLd9K9NLoBelU89jF4hh2+tJhZIv2xl0iMsGMWDMG
#sQTejPg5BnQ/eiGpFGsCoq2jGSG9Y2es7rg5hnyc6mLRNdSMaBartoNZ0LgEj+DNKQ5Snxk2gxIf1RvOt4q8n+KaEgg9R7Rl3Mzj
#eyX1dAekbhteTzdmThY2WVmVkUdKTCc4WPNMB6svVw/hGjYg50EhNzzCjeQZpJs07aeqdR47eNE0j7WxQj1qdTdMJAzgDe0jc7ni
#ZKtZPjjlRJADFkfafIoLgpFVC9v2aePkiiSlFJdZ7C8xgryt4JwvyX+VBZi9dxNnfEo1j5X21vlW2R3FgXO+4qtz706ZB+TESNhb
#+hS3EbsBPoh8detkYfY35IEORQtLcwI9TYY6+ck3j9KwM9U1q9U1XGBD0DfgOpKrGk/l7hRVjxpzCGe0maDK5PONKb5WS0b93/sg
#7v9jf//h+08zUxd7R09GV6CDDaO5I8gCCHIFWvz8EJTj/82HoP/j7z852TnZOP71/Sc7Kwfn///95/+Nvz/ff2prQGA8PIdXISC0
#jv/b7z+D+R7X6xBFezx8AIqLEEyK+BQHAwEpJBUm+KMYchjljw9BoyQePgTlg4+GQAnWeizXSGWv/QgEL3J5ekmcrcDtifQUfvN4
#THQwZJ9LeccDvWxrmOjbPZ2sOdEaU3dNZVBZ0DilvqZpZD3iDcSmgWCcQ4LTnEpR+HqhNzs7vxKVUWEYS91zLXz4c2cDz9qJ4TRY
#TmFmthsUSLoIQap6FZ4c/VRxLK3TLGTLxpOEJwAKzGhKQK2TEff6/Ti+YOfV4/XteLzuj5BaAYsWNMYuUMg+n21J+YXDyei1jjRv
#vXNmL+9uYxExSFE3CUN0EMxECTVwyxHpcWazNeZoD8ubYugcpGmkdr3u8m+ftU75Bw5ipIbRfBnMCcuSxk22WI8K21mwdO8vGiV4
#5naW2pG5c9SgAEVpammMS5DZwhxLGYZOmsSCk0RVoKnSbsgj/bXbrlnnq6ZBzQZo6EDPY7Hl03IMRtsackxlLIbAycvr25espKI1
#VNYhXWIhaVCd1ofKcePjeMlfxOxbbqvWhA1mPZpKe8dHR/jAEegJlNdmH5diOb5mvzql1IGT2ycOrMBvRmi3U5+8AnDFlkVCX88x
#4djNc+B/9OK+9T3snEeQqCRfWa79FPOtkxxJNjfmlhb969sMF1Wq6h5aYT9HbpEI1P1hhBvRkbauIg/Vqioptq/GLePrvvf349XV
#GRNQHEWD9aTvSpDoOJBdmDXnVJQZQ4vi2/qeRaFddj5Fndo2eG/YvgNx/ShpGQNB0I561YaTm1h4hdkKDYF76SNeYL4KPMeQSu/V
#wjDf0ualFZJmnFZIEVxBmr5hAP4wFuG5s7UL5Dd9UJ8cnAF38anFwZq/0xwcBT4qocPNRfva5FhdeDscxtJefVIQAc6lcNlx27fZ
#eOJkNqpCOAipc+pjo/incGlBUzR+sEpvRjc3cm3TuzYUZYLGmVgzmjKI5D/x7tvLqVpVxzJ5xN8HNHXcH0fsU1MViMphi9iKDAeH
#FQdH8eIQkrpDyDg4C0QeEk95R6F/sF5wkrEhfnsY15btKesh2rwfvl+KVzwCMwOEv9+oS/e4e3prlrnhgW6hQd8LUTmX6TB3UKiy
#sa9iJekYOV+EFJITD+2GFlXdd4oxGvHhutux7lMLFGI18pVBrnITmoij5KwIATV+a9HVbOQdUP3r0aNSKBp0wgrttyr93F0VKs+w
#7/Kib/xFXWxMRRHIwhCNLEcXdxsTTRV1fI9GKEfWQPeW249bV8RDYBDJMSXE0B3vPAkYieveZIiekAY/1QAsNMd5kNvUjxbtfwEY
#v/KIs2mhznL4FGcWD2dBCx0ndvrlExTMO2gIEbjPpKIQ6DBXpMGJa2sqmDJK8C+3SJtEaCWwsSngGuWD3wBFlk4LxaALX1cW+KCq
#pGJM0z4vYB0Ux1IQX3WGd54S3AuOnDZPLFTKQ38kwCJK2RMmicGCHiQRpzqcbfUBN3Q/IwUjvkAEEmLKnBTusTFhUAEMtzF/NUYR
#0e2MR8i88dvpreceMHa42Q3OEJSLX+o/VT1S0hMTZYGQOQekvFyCtJAoWoSpH/enBhkUtMxCfXF90+Zw3y3oCTqot0nOlIW3LyqL
#SCDhI4tRjXHRwIC40Oh58mhxG8IXxuQR/MfgJIgNfvEgMXSLioLk5L06fNXFVjRRkTYxfAyVeEEt4jHJN7Ir3G/ChcKFAqiGaqQp
#Dsnyl0JB4m3WeCwIcDPuxAzTA3uCFl2c0nI5e6L89BQEzU9qWDFb/Sx5TsMQ5/nEMWj6rZeqnuPnRYhBdA7X0MZ/C/6WxuhJhEK+
#QZ5PQUJ+TFpHwUzvReCdIGCal+FczXeK4AKxRLUtPGovtkA6dvI88ZIceV/86DRb1QJmX7v86Z7YMqmilqFFv5pg+TTBOSlXaJh1
#1Ko0ZqHGFmk4KkU+BgovhO03BDHmE/G74FdNfEUXZS/zcxPNat+7TL63SHivcmGxoiH+JIfihQxXtW0Tvfwp8TdkkhjpqdDl2d2Q
#5SabTx1Jj9hT4dOSDvuZqV/mjnOYDy45m60BlvLgiGOr4U4yNtz8pE4X3MMs1wmO997AlLduBB9UxmCH5lI891kn2lwOvksKoKvY
#5kriXlph0mi7SxCLV5I+f1qIt2nIPz0mW2pCTXVvQ3AP2RMnx3cGAElFrfpaQlwox96BdLRF7SuqJxtxsX3YxNkiM3fEhLBflO5+
#Omvy87nBYg/pGnGlTG0rl+LF5aKVCt5dxYi2kj/36nylaBuZP1fSP9CeopdJybEh/DxA3EUzT4irRTXeIx9JrCLGEBpB1bRHDP21
#BJY8+cvzYm5ofbjsIRRfFFvt+81qg32ij+Q616zsb8QDv+glrvTaapmMuPohQJS7A24diQwa3J1wq31TTTbN88I2clEGxFWTUJGC
#ABAK9Q49GiuzJdcYLeObqt7jOGEZ18G0UGJha9/8PlUukacjFTrM2aMsbGhBXQWSnsO8lsl8lF4esdyCtUFOGi0Gycv5MszNZGtN
#/ZSJXiI2t+uW422ARMPH+e6MAXmOJ8ReHbFnhUp6dFwTbdxnV8d5GGOr0Je6xiowbKCVgA7qxKNL6NNO3i3X7TH+1MGaM9mLz61l
#5GFhRvBwCT461oUduc36omZo3+4zZVC+ZTfZjlFpG7iPOcxRfFNRU2NjI3RBopeTI7T1Iaw1qMjKGvY6pRzclMnynqk/eY5JmiSX
#REqopUXPxWVbKFZozYrQwRMHU7HzZheLVkWkXIVsgTSULr2cWuV5hloeX7XPlzRCDhXrOZnnsliFlhRRcRxInMvWTIP4kYSOAjUj
#peg5tvRaHR5Qhu3T6JSk0ghEzjAzpfE9VJkstS9C2g/oFxjbyNjCaU2OsjktViEQPjz3GO/wwA3rvX4iDW2bdmNGm2e/aLPymRVp
#tyxB4ugrkaKbsiXimpPitUDo0XFm5EGdvVxAu3k2lDzDJwQJQ2TFDv4+wGujhjS7lC3Bb3r+m3CjLRQfvfeUaRVp4+nde4rSllSW
#0HP3WRCqyddilFnZoLWsxS5UK5DhQmEqbcIUqgPT2yyFYa5lk8rhIylH1IoVw+GBdCp77Eq3X07eYZaMplWpVMjhVOZi2hJ+xUtk
#XeBRbzlEguyt5kJ0i2DRlsFS46OMcsme6kl7+r6ybv8Ldwnkm3IVzFvZUoERzrcqj6PwJWJoM3VJi1uzUytu0aZtIF1nqNNxXaPH
#pqdXTvUw4kOUnF8oFWErMCQgspNi4kfnoieDGKAlcehzsrQoG9B1EAnF6AvtsmAwaXsxz8QZGJAWM7Uoyr2hkkS1719+2Wmgdq+0
#tsrGDrzokh6JB8R1SbKep1I6zpfPOeGzDGnmcEg0B+wg3NMlvDHfsNsKrCiSi8r3LmFPvSsIIbdEoFMS69eL4CqKqapgUZOi52JJ
#KZvtiPNykB3OmtME1dTP2aLqNMhmIIhq+ao2k8vkBp2S98ug4tS06Fn0IloYnJoPiHg5aFT0Gp29zMfJ3dc89RNfV66zWXjrb44c
#8iVppnB16ZNh/ldh4ay467cbKcovvDBpzeK63rxRmTxX4Wo/0nBaLlfN9/Pm5yBHhYA9dQQU3BGoPLVOLnhuYOamAUJVrnzzWNaa
#+oiWmaKx8ppCs17tSDpvYV79sYPWZ4aVKmZLvRM1iy8qQ7D5nybpXp83e7MUFHTCDpuqCvidk0uaLb7CwHcemcaSzyRwUgwPNXK7
#lv+G+dE9QPgCDqk1k/WJKUaDzBNY0WDkU1raHVfYulBDFyD9elprSuEHOA+RipHCIUu4cK0l6xZQA4i3Xdk0e7zRlmFCUtt4Kqu+
#5zmgXqxKgN3r6fzuW3RZVkYVcurNJ7OVJtPhgmHlGgOd2MKF5tlbSLHRMVK9+6qPBLlPKlmC3yoMHeL2PsYdzI2Urp9AUR9e7bV6
#XcQzI2asa0JmSRZ1aRT8fD1sodNnX2jIp7Nqozey1rlb4+5V3nQZKpYwy80g9OfRe2e9gjPouzCvO5xeaCRCDYWwvaeByqoFEvG4
#Dnw8L87xWSz6H9fqNBpxMwX2K19xdneTXQ2aMGRUEGqTFaNh2GC2VoPMG5JeHDBBUh68JpN1oQDCq0EWv7WQyW60GEtmUA5A6kvH
#zFejU68VK6Gfr6haQJ0orVzf2AuS+nQzhA4hon2owli8nGPw/oiemKNkSaS5RgcBITpKVia2ujtZXUXNtbCw5PkHH7sDktpkAiPA
#q+uT3UwIGCQzf5I3vVpUhen9hT9MLeP82XAS3cMtyelON7P18/qvcF8G3iVjptGr15Knl6vlEarJH7QfCHOn2QFm5qRcGcRZx50o
#RofvHmsmguzipnTiqobeZtlni7nbXn76lOIPDEyGtnm+to5lKBx2Qqxiz8q5zASACZPopyyen6aegWWdXyS80NoaXZf6ysWIvxkq
#jc+tr+fwDWygkhRIGJadfLiSUSqe/oVZZk7IQRIUTyXi74ivhHPJtqLLEAbtTeNo9GcqvMm0no8OW2IAWOLV8ZRy7YKjfNRcUl/g
#dMLBP6VCxmTcuOHbR5I4e2wllIrwWBSeQhqfLvkms5fnnlkvcP9k2gGvhf8oSbB1ySSdquss3HvQWsMBvZhzFtA0wfpW4Iyxfpo8
#tqZ1EO6xQ6N6LJcyRlMuoDwUF4KU6XltUTmJPMChOW5ZTs3a6rggD0IcfScrQ8Zg/EDZgkRmgG653R2J/5YGj1l/ugyKTGXcRmyw
#eikpKeYtsvrGBGTgXa0+glIHbfzZGoHsgLX6pNNReaeJW5T6K2B+8ouB7LOKgKAP0Qh0YFEw6hSHFcPMbtpjxZJibIl+FO9oEvRC
#xGZCUyq1aI4bf8EdR2w0kPRmr5Q/sNBsQ4mM0gB/TnWxv6cMgYyV07NLTOJ5zz0xZFT5i8+mOFSfDxojLO1j4aY54xVRF102791W
#RF7YiaypqWuG6ONyp89v82mdYG3UW5NOvHSw6GN52voFrUuWB3L0srpEVR5CxMUCwZSMhRQ7WD0q+1XKFubLPkiDUyZP5mZ4XKaR
#ojhfTZ0Ii5NQ75zrntVZRPbwfUu/wOHEgMZFTHnGplUkhhp6Lx5gcoHECJZdTZPRVJtD627hyRFKTH4QYZR1OEybJXvnjmi1mRYu
#HD1+R6i19CrHDdsXaTosQZzo6ChIatKnpSbY+CYuAKtnuZSpYS6BUck82dyZXbf8mM3o5yS5j+9WH0Esv068STIhxRtGgoAsx9iT
#roIYINB2a5hv5Xn6qknhTbae8Qqxnp7ZYL85O6McrA0rzkjSJgpUNtIcoeKTHnOAQp6iSUXyqVcx7R6AAZ6CfHhV4vbrmzq08NOj
#kd1zSVd644IgAQF/iJ3+bqtXCjpiEBAdF+/dkb8lYRtnreIlQJ0xjY9dQAgyAuBJ4CGuLpsh3i1jvwPNmJkkTXJgCHcGFMVD7Ij1
#54RJi0vOstF8uFg1TCqMy/rsozfZk83D/qEv3NWDKb0j0pfXLstwnK8LIsOQl8uDodZzchPNBFfKLTbCdTsu3wgfj+EkQvvgZTz3
#/XgAH4Oy8GuabzYQQgFfB0Qh3m3GHh66H2w2zp/Uey+e93QE7t55i0BAsELErMFeKQRgwnxmNUb0o9xYBGwn6Qd87uEPfPHpBVaC
#j22+h2/LWlacm9e+puJdAtPy6BON2ceg+hfRNEqelriiGyMqpm3wj6OBeMfN5pNXE9fDZJuqG/HZjfFd84TvKDgfXUk04T03vv2W
#P6Tkc5zWdsT38Zn0ke/H0G7y0G5Fz4nH3Tc0SFdTdiv2ifh8txWcmIu2EYceK8BECgkdKEwxMzUkPiaOZgF8N/PirYFEbhJIP8EP
#zHIvEJK3YOzSKFUf0RGllIwmMUvXCvhjH1ZkAsQ1aDVL5V7i0cezzLH0xWvaPRWZF7qOksY1cJ6HzTTwUDVpJ74gIjn+AOWHgpmq
#SvqZP4tSZLKmr0KbtLhEgZHYEVINKN+MXa317L6sTMOWIEtcf8XBC/NEaHvrK1K1kehWvdzr/UwrifSAS9O4ubOE/n47jPA9V0rp
#Qb1eQdFi7SDZkKoo0kuuWhlSLXtJOGvl7NUaxLclUughY5Rv3ZdWGCgbPaFGOaLdzOXbhen6t5PfLd5+DVZMYIr5trMHef4xHlOb
#42k8bYXZ4ldzRp8LGDi+mIa5aBoqZB9N1wk4Rq/z5LlrzW88TLeq+SHRbRUYz/m7BeO5KhLNNgMseGIm8EcasnwlcSPN5YU1SuQU
#Gp1zYYkmXuPbrPs+opRy4oHfxIzGhlX9XNDeCBVdqCAV9pymOiGixT00xabaBqdOgwOK65XZvnhLvFyzHiOMG+pcLE/NMJR/Us5i
#pWihvTfhXAK5HL6d9qwjDqy7NoI9F7IwUbP1eulIaABf7kf9QImFlqsMZMzLtlCH1mvUiqZPfRnR/AeSNSEJqTSg5eelbhUxYiqA
#PKgn7aLNr3T4IUU7ZE5ZqQO6trDbyxjgVBK1hvdi3gzZ733iW9fgKWy7Daak3YKR3ehshYZROxbJZnNEbN56lJJj0j5ymGdQ3Y6q
#aYYt7y1FlB6byirahGfL58LNqvcGhv5IRJRd/0DjCcWxxZg+hZaxPpMKOdZU2O7nPhxNHvegqjQc6UIlA373ijSi8ErHAi2U6smU
#F0Xn2a/WKzKCOCT2X3iEZB6HzAvm72sr56vdMdLgcOqsXVR13McT+I7mTOpZDLtduuNxJlwdlbfm6GfgZ6bjFdGT4sJYjMd+4JOS
#lQbllPWSaL3UWvC1KA2GRJR9BUyTI3gih/gSKJOLkF5lWVB9HiW2h2PRxVTTJzHIvnTmNoPmT68R4aLIVVRQ6J6B0H8p3/aGsoQG
#pPAigkvi7V2w2EJSC9nYdeuNBMNBMtnGzDt6sheyMKtUcCiY4SBMZClZiCcp6AopCAJUn1+LIJAhq520tn+A5fzsfUMr7Z60oOU/
#pvz2XY0QY/cGORF1Vn22+QgN9xR/WRmbe1kWnRE28kDulvjnkivVb3SQaQXNONb4KGTPodfWp9O79i50hrjb0JznIpJAymucXZJi
#kCiijnJbT6vPseBdZmEQzMs0tGCoKRbjCkGWvBuXji06GEZlsiKzGD1lUHDkrGSlWf3PUq1ZbQ5wCp3gJCS2HdkyKXiMT9tksKdN
#dKSekn5JVBmwnvPMiWGlVjUjbdbCj1UoP0H5coR5fj4CKPNmZ2zEuBsG9IUvp+O//zbxlmcZTSy4Nh+fk/FgqCnuBrXkDa+SFioH
#HVx79KHkJ2654FnzErfrJMnSaeeTMo0J+ueNk/aSa298NchljDJUCQwu6ZOux/pOh7rKCFUQa5LSFxdUuHFRP9efp7coSojSDyWL
#PmUvY0h+7ZlFkWx9SVC/TY6CeCIiF8KpmjHvIZtnQWnOImeoJ292cIM41NYftDLER840sTq+ABOJmSUEQfjUg/0pwutqnT4cq7am
#upkozuVs6HxJTnMo8wXAfY6phZZF5zJnrXR3O3xR/fRgH8mzxpeXKsTuPe/c2XFeNlddMTY9fxK/sDT4Usn6uFi5w7y1VOmC1XRM
#mw+2eaXnZYXJU8VVxZcewupxI7RIxaWMiDZo2F62fMRR0qNMWtA+b4Hu+C3jAyPK0hlXcVgfvJs3GCLsS0tmvnwseZzNnsHtr/VZ
#bFDU2j3H3CJndM0KWIdbMh9ikX2974iXtX+DukGyG2DRyM473LOG/1x2Kp6wQXnYl5L2HJYTbuSw08ZDCE4/G+mLFE4BhOKllap1
#9RQh5dNB+oMgS+zHVVahEszbG+s8sOSmNzxVjrESwlZfjoOzICcJF8lZh6/ZeLiwHrM5aLwhVbWtbkSzVnrZQE9ISR9fp3mF7/ul
#WVMxVqLmrEVJIcTHirNZhoMvMDepUHynRfemdDuqkNIwQjNwPcmPUMhZulyK8mZYIn654DBvZgao4FZnPvDNZPVm+kpCUWauH9Xn
#EbVk4siMudx5VjuSovzcef8ZCu3X8TihpqKpj3vsVjg5ueXe0fnXV5l3C7f5IbaFT477Yzm15t1pb6izwGrhZ3eMHFEvQAXRQwwB
#wVvP3zi1DQlxNgJxziVyBxucD0WBn9qFERiFLlogFxZ940WedmLfZ42Xzo5Bp34lBbcvp+CyX6O6XdRlACskNTj6zAfuqjpiOpI1
#yyDGdMvvap/rBbyEJSm5TfzcALKUCYqeKeMjG/W+hd60i2EL35hkSV7FrU63CZv0qs85XTEjm+ac2ZgjnneU52Neqnwva5bKSglp
#XSsApwM5GnK+3G7w0dsJ69HOIIdBn4u26ZniTSJbojxcy1hzox6BtxwmOEUr7iUdeTu1MuliMOZz2NSPa2qoFlE4EW9WtirGIxhz
#BS8dL9ozQU1rW82reB8ceg7SiFCHB6pu+fhHfGLDDyv7r8JfBMV25qdMTawM8YRnveyye69UZr5NcLcUvnU+JHvg8Fh52L0iVIWD
#A0czwJtbdSeqYAxiWZISJUuENhWBpyruGYYTej5kny4RY9LzneCGxum7bq0K4l4MIgM3krMQqrRhfBUC9Zg8JcoXLJHmnM+5rRGf
#ldpPklBFGO4hAF3wlPvp1oKe2Z5MyYZUQ8QHeC2NbbiJ22DCxZRvOPieVH5wGpbW/ZYlEpW54I+p8FQqGHsesWBMkD3cISfhfrx9
#z/ZTl8VOByn7Gl4a6dJH3EiWDYxggjCpLKe+gVA17cTCKQNTdzH/eVXCrKL8F/VRyaRRvAVt9EnTwkfc+xpjiKHVAnNRb0T0kJ02
#OufUzFre5THf0EcubGNjD4jtAPRLA0Uu8wqMGazfeTYMLXJSBmKfog5CfsBURFCLg0yyMWqB4gRwCIWr94kD9ulHq7YNQHJdsOH+
#Nnlc7+AchHXf0hX5UopuBuXM0jvLRbL2bAe9jWaPQhXDm2WjWpHsFU21oZVe3VJnZh7C8J1KY0CxNDJrOx+Ja07xqk2KzVIrItJj
#gjp8ZaMqlFkR0MKIj3IppLPXeKPTqGeVI6NjUp633XM2hvys/L1R8Rz6u1Vd/bVnOka9qukvFRQMrqonmPPHFYNp7odG4IZiIOfK
#sAcJSUXtFUY/0/TLktFrhNRrx9S5IgXZ1sFwQvq2mG7lpHSvSgwPa1gUpZARxYi+LKXlh+99Yw5VvI4InBJXgB5EUu4Is7dH1o77
#goJ9RwfBbi13PNxotco9A3uvTkyEJS+xkl0ZwXbN22kP/3L3eN95BOG9uUUtSzYLm25135I8VC9aQLYG+g6GqhpTFveCKyqpv4Fa
#RPMd3BKMaEGwmB/aYE/SWil2fNJdTKTIZpYRfTfrNGt4LymUc65QMXJjss+HWJgCWc1Pwx/J6qUOAkukVovKcL4BAq9g7+StAqR6
#4PinqV58PO5p3gx/9Zq3Pq33WQB8+oFBcY+oifzZeyln23QzWgHoKFbMmFI1q+b5vkgFvEc8budrw44oi0heigeVstlT6do6cv40
#DLiBeaLP90WRNxdtw1aleVtxffH8PgrOshtOJuqLWqAAlDxmOJrgI7E3b/ldSqmWUupYp9Cg3q2T5j3zVxgTHk7u/fYmWQ74xPow
#EFW4f+TGVqAsNqe3o7StHrFvtEPODC0tMIohsKIkkPSGH5laZc/odcgnInT3FF2apr7NhODPcuP8V1g1xzfMy7XR7cxcV8kInRuy
#SU6fOR87LzwRy+HV0ayEbjBiLkSP+5gYNg9s6cZLRg0ZEsc0xkhAcU2jLlgIR36iZTrRLRlLWFrjD0tTAIEogVIA4txPNEyFFCm6
#GD/vCtDowxtCcYh60kOteTYfgg6PhTNcNSeln+rX9A7q5rFY9fs1vcSs8XNNtonwCUI7sbJnAncBOOILkMFOJwuaQ/KOoxYpEXhX
#j0bq3uyby29+wME8KVM5Of8K6748OhDI9G53o/J1dPUGUqKOMY+8j/Xrj7ONNc61Nuef0li/DQh1JsiyU9CnvpRJEot82sWd9mWX
#V1BIBn2zXgc0apJjJ4VLDvuKnkwqMjygMDuyrErsadW7tghYiosBbKvW6FMTV3TR7aqrJr9gWifRsvJd/QDntcF3+2qCny0rQ49S
#nxwI1bcf5BP51Epbq87vENmFfZoDuLmqE4AWtknLxNHm30RGh8ErgdCXqFDXGURUcunyRsRteszO8T/D1Pt+sX4RYXUZbBta/srK
#ldqerIC3adcbIZ1vRc0LY7661ZaVodtMDnacS3Lv2YVemDANpbTjYWZ0s9jnVlS5iaIyVdmVEJ7RT9c4Yu+SoZaozCpmB6QOgIpj
#i+bGoHtlmy/l6v1LPa8eDwLdElgijl8dWM2PBZnM2rJqEfedOMm9dw+/WR9lKIWJ0teUzOsRqYdjCnPbpNW7itp5xN70umGTArNO
#zRVU/OxLLCgnXjK62AbtUBezJBXbXBJH76sdpnfLiBKglf5kzZi4rUqMJ03/Fk4rl0TgzObTFQXlue9zTnvZk3bWW8sV0DctfEls
#3eF6/BQ/SUKoEPVAGkjdkidBcsBe2+Pa5zT+d+u07IaS8jqaoVM2uJ3KnUYBkyl49HR6c2zVHWHVfthapBsMYxVvBoyQv5YfN0E9
#0xuVbeTrW8wSmNsLkORsabO3Z1zsUnB73CUlkuG0Ry6HyVqr+DJJPGRF2nxDQd+xBho3ionsKQaflgiOE4WiokrDLRl1r0znuOjL
#6yDJGnIN8Y0qUNXpfv4KpG5rfQdwWrVK7SOhkfNGstbi15g38qyTknvhYq8CIEzbDUAYsfDGA/vI256fIEyDtpxk2imJIuFG2KiZ
#GMJc3+xsJuniRvUuyQHIbWEHnD/nM9jRP3/RqUyMpx6XWgmJwmtHQa4dASnvTMmeE1A0Xh7PQPn0NdAubC+5MvdL6EumNNK3MN/o
#1Z+F0i6RRYXcnlg186RQ6z5rXM+OqKLzlV1WMVB7x/D686TXccCqnqUJdSGeYKDl9Ysqowl/NX+iBPdP/e+qqYadzuyMJdnDNeAy
#sgkLiMQVcE2kLWPTKtxfv1H6TGuVMm4sXj1WBhJRGYrjHDQN5QwKREKh7SZVRXrU2tSF53H7HFe5vjKDFdfXVHhd+AL6eXjQJSH7
#Uo/n4Cwm2iR2Nprm1RAC3vletvp7bzRO1RGbg5Et3lo7sa1mGDpRAoGqEcvI94LMUKuBDabVOc9Fz4zSzTBeKIyT7eSlbnVyXVYg
#qLHLzmmRzxtramK66GDSFLJiyOi9rU7xtfRQ90c91EW9naGnAermfWARBAmpwKt7PfHh/1J9KwNgVOOqScmOgCOX82uhV+7klmc1
#CQu+zhiWn34avHAQMHuJLXnsSkLVpkvDVvp2YJItwkLzmHoRn4+chUdb/0KEr1PKO1uI0n7GXbBCXIc5QCkROtDftwLf3tPG4/JR
#PJH+/IH7Okll2cpqXjxAj2Vjb+a5iya+0yl9fXiUtl37DW0WlqVmqeqW35ENIeWWUKj2rRgjASfd+/BX6hfEkF4HzfQXdmKutY4O
#Ja94eBU9aSfOvFCCOhCwkPb01ArCh5/IYUFpPplnKQmztPIwVKrXezy6TZRHqfeS6R4585bMxpnuncFITb4oGlUwJ5Ri/3wujVi7
#7+0C6iq51nxQ9E3enKLz1SANqRsa5rD+8PLTpup6QcHp4Iu7Z4aVJoxm146jtoyyF85c2GFy83Ye5QE7m4HupSkWJl/vDNlNxQu1
#XZ+VR+ASNOo8VoiaVYT6nD7wMQXxnJS4wu0UgJNAwBmeuKT31Rnk9LSgKvNV+cWjohLUPXua5wfjZkRat3JNdD2m9x8J00YGx+XP
#C2KRO6jvY4Lxbmv9sxXxqnXGv5ix0mDw4tyaWR25RCgj6FVSFJdronMIS4i4ilXCtVziyX0W+NBQkqSC+C5ZC9AKg2NkpHirqRqY
#RTgVmCkdGVpBvU3Y1CNtk1a+iGCSlc+gVOWyMFEqrefVrk0h7mid9g7qQoJTNYdAxtQKH5taMP3xEfaZMdoJ2eIccULAzaN37H1h
#kkEUoy04XHuctxs3lF3FF71H3dYfmu0ldbM086ET3+IpTAeeX3GQlwd4ZhreeqQv8bLqr46XPm7dWy2Yt6FLW34MM3LTjknsNcG9
#hH0fr61rMM48uBAXDnUmdZdUN8rSOixKTaLB9/HOeCfi3KloLzRSv8HQZhIyQO8Nrx+XkSs3LbXvGXrTAXfjtqDs/p2kJHPxpGBV
#ijJ0IOw7yqv0jjMsGQ2hc6ezPnU6YuwYLfmX6F1QZCtPUJaq7wo6Y766i1erwJlS+Ssy594uknamMr+Ch9yA3tHtGVKMQ7+67yO6
#3PRbxA8Rdd2EZT3FJC9FtS+mOL+Lh/sof0Ry2YsEcVfuoCxSbusLFdQtIam54oZwfPflG1Ov8zrNkAOKvKmFWgJzmArQNyNUABHC
#gT20MX/9Y7dV0s1ThQ+tKB5WTCI8iJupDv7EBLlcAUexNu+kIY7cVQJyU5F4jgQPESUE1k36X6JDwEHETkjrUDQ1Bn8cNrFbGRaB
#i1SB+ewn7d6/HxeWxxm+5v7BcG94qBBfTMvyLtyx6VXA2flxUUNZd/BrJCMy3d2mOk0n5A/vcKdLlHddPpzNI/IhfJifUuhv+cBZ
#nOfLtMLPvj0msJAteAmlw7b2eJLd+xXGCiaEfQ6F1VfSYkdeBAoIWlJAqApkENsGfwCaUhMOO4eJ1BkURMbCde+TS7tLMcXQ3apT
#TV3oPrPT1Bq1Cyij9PlTnBdFqaRxKmwapLy9hATDGla1RVrasQkKK6MiHtmdcM04OunfnHpYUXqyygaUxF88d/cqmLjYaLrroR1W
#EbFF0j3ek5xQSTdI0llXWzAxbj/ymEkTRG9eESNbYUS4dx7s3tf1Jwjf7CiEm5m9r2Hf5iodcIuOJ32r7YpBfdSzq2yJVBLNxOXj
#KgQILP4AQSp7FvdsVHuqUcHaqBudk1Re+FGTi85m9BQ6tN71nGKoK0kBpAnyFTHdB0+717u8A/bYJc7vNLeER3uRPlJpPZZtbR9n
#aqyJd+tYkTHX5zaxdzgR4zhy9nrOCcqM8yV+Muthg/Tk/gtBrIDYB6GD2ciLsSjmJGyjd+um7/C9DMgHMY7PeSac5y9S9waigbJS
#8mgiX4ZpInmeWtZV3cjtRBCEzgsLhpFOgDwBR874DSTH4a9wY9WBseoUpGekTXBQGI3akvRppXChXOaPFluWlBpkcWp1JnDJYJxk
#5z9r8NjWeYSZe/jSvi8PoLVsenwpOMOZZXN0ULfCp2QSJh4Y6FhJsR419qmGqw4SAtIkPgAEfFtt6avZrmSlh9gDt3zrlNfypprT
#zAjhnAovJ2cKNb6ZLyUeel7lUSlWFhcb8R4Fi2CS2wuUGt3Q7a6zWvRnt0wHsccqnYkvVsIKYgcPJvzXNMpmOVZC7ya/wE2Kscds
#vg/xfd0NUc3mTYFWZm+tV7I+QrhvSxs+LZLn1erVc7iaJPtt+8sucyTqQRTd/NvlVSGBpmRuJ0fJBkbM8+UuttiNfB7CJM1cDdFG
#Zy3tjt3TJcsnS496iEAj/LnVeJ1jtuwpn57VXfJy+8+EjVERb0zUPTf2hZIb9ogt99zYztfDQwagr+yB7RRen32komVFYurkUiCu
#0Ql5sjs1sWAYIT8xFT3XDhbD4s4UC7D0hIR16xt/2PNB1zB8DnQ5+c0ZPTRpruLngPGYMW28N5B58Lsv0jGuRIZSEFwAZM6Int6b
#ds3L0M3S0kX4oNdRiDh0QCwYS9Mw5HtuKWhBhHjMuCC+UgNpXKiiuT1760B7OOeYSTlHm5rs+sSBkqioNUJaTW/2YAlDR/9WYoiX
#qpKYGZRwHfhkbgUUREwvtRxYiyGGF6GpQwcL9dqz5j8qUnZgLu1DWMcTUrB2N1kku1EsvCVAIiSXq5XoTQDnFZN8GcyrUKaQEIWr
#+e4S26wDW59irx0t/ALUa25o+HInrVV5jVRCMiHQncyxbCfCQnWbNz9EjaDDkm4XVDZXEn7JoJgs+ErewSflncolkTjKezN2K6+R
#6IelDXvQC8t62eROp2oThDmVO2on4++7VSBxMXj98lHDsp1z5brjx36/vBEZCx8/g5ggUvRtP6LCi0pOrIasWZxY5hnrC0JdqtgX
#sToQJ3BlbzVW9LgCb+sSB9v3cukO2gsrZdTORwwUkNq/VKz2Xn/bomnff9c9czXKw/6Bi7G+uxKbdjSBqpM1xtB/hng9laQKGV6D
#857U59yOj0Iz0M42OoseNUqtonsqP0m+9Zn1xn70vM9bzzkpcoeWQ39E1Qb7eq7WNqayXmORkLavL4t8nj2TvVJ9byD8lllISKpI
#YbV/b2mdxiFGpgX9CvXtl8rgJ0emNSgK4RSji2otPhxSiw4xi+V6nRxcnYurvgoNew75REBgZ5e1Her5yl4w/eoeUJW44kDCip2C
#fFxEB0EEqPoxSKvNw0ZBBa7HDiJN3xyLcOMsFsUDEoIYHRPdA4Il3dUHCaIJapwhHVjhJY4RJofA+/4836ebVOjuivsF5Hs2wi+f
#ZAyrjcKiFv0RjdvhLtsitkIBxua92vz5jBLFfG3yNvkVWsoW8dg2USDNKqvlfKU3B2zRGq+OWcxs3+4vZIsr6F5qR0UJJlXaygZO
#4a1inzgiXrU9Lra5eokbkKO7feOiopLfRbzhHHtsRrNz9n4xMh/fukS48IxbKpUxezQzLQXRzD99s+fQC4J1WtnoUcNHhdj9hBai
#m8blgU9TERjiu26Cne5h8sIwhao4iwm9j605s5ehh4vqeQtrCdk0Q0/kjR+Lf32bBIPRSPyWilA4GFeO0bSivQR1XAndbILTKnMo
#wQLv24odb21+6w2z6lKdjqyN5UeSr4k78+IDsKGBDfP5plhj37IvlasWsCWB34hHrDXobxpzzTkn8OdVH99uBGul5rMNPrLm0NeL
#n3NOhRcIoA+/5k+df18DZ0HjmSAqROgd25e9tmygnnpxsZCdQZgkuMovY1a6K4/mq6o/QiP5ptPMbRku+kbkW9aZkg2gtpLw5lL+
#1rekm1rPQWs2xDxmwBOkFrCw83n/+ahUg1ezXkVsMxVrd3fX+tBpCw1Fu+1uuc4qlqptFf+BTpc1RZg9RKXb59BlmqPoIc0GxBYf
#QGlMB04Da4sPeasSO654CMQrFAhVTk6ugDeHiCB6Ec7pArY77S94EPz00l+iJuICp4sSxiraHae6yVKJBD47VJI52j7Loi9ZfjSY
#asM9tpF1jjGlUa96/haiv1cRDqcxdWQ43/jT7Zw4XCgvX6FW2SfJyNPnNi0+VWsL5x/cduy+5hNqczMJt3Lv8E4l8PUHTrFyxdDv
#vb6Za6NpldvBm7zPk4uWp5N7ZVH5/FTrVWwg1Mb948tFVt+5aoMJzW+0clbV5LYLIRfl0I+qu4N0et01czyi36VjiW8EslR8Bpo3
#5GSEPQ5WQSZDf2Qzz9pAWV/87kJ01y6eBoBxJS/tGyguru2Yqotx9rWitlJL2dfR0Tfdxlgzp0+fuODjPDlqGBsC5w1h1RAuR/JF
#0AdHhPgFm6leJQiO9oIU1Jr9cmGTylJyaLKSp2ZHH9GmYAuaTDJq76YkIVT7tYpD9i0UD1c6eGw99lAus8Vf05n1fUCAc+AJNAlJ
#ePOV5upKTAqh+j6uh6hk5crTP6LRyaXS9SIARlTvaMqWbMHDGGc1k8IiDOn4+pzG5GDVBT6EfMITOydKLdbt1pMoofj83IxLy2uP
#I57t0O1qq5SIHz1MB57kOfQNRVh6+IG8CiQZ+dPrE/ecpl33uaTYs8iFGVUf1aCsjXZ/KgPbi+Lwih4WjDnzUuMIa4MdeYQq0uZe
#9jeOp5e6mUfvw3OtKa+G3TR8EYNUTWeISZDEhHXDGuDiHie9hTenI8QTIwtbzUSuod98EirTkKcwWpEx5+7eLHbl9B4eZ/KEIODz
#QXenwUn8fnhU90ce9vXlwrf7IzIrsGk4UBZ3XGfbwiLFLPg8zPLMDPpaxqmV8OvcyBtXsXfLbXebz9rYa42fYpWiI7S+NxZGP/I8
#SGYr3pA4FGROhUiLQsCYkkPEVQzmQPBTB76U6jr8LL0yb0JBfpGm6ZrFAR8/GbKWH3UOsQgcoh+TH5Pie2eFriWyOzGM8ijvcQyh
#26Ru3b7bB0vY3VOTw8N2h4CywUXFTxxpGYRPbYvo2gORq8NO9KOgNiBf1dW97IreUpy4tZgT//DeNLBnwbapxnLipVbgdPVSQAZw
#qSWTmxhD8TBDSZzgFWnvHkFjOsCT/UW+EljR+potjomWdPm5LXxGCzbCY/INHZtCjGbnjfS5zaXYUvVEpCLbJlsdtmANNmSkjx+1
#anVzfD1qGMH8NKoELOJpCHMzxA7rnVUq2RNpZLRfumPLDf3WQhlVpxOezWVQIBjjt8O94zO5GtEWRAkx9KGY5FjktQ5vldMBK5Tv
#a0ahc4S80KfQJpkEH2+ik3UvXdYGS667FGjRx6VO/QJgXjthTUINaiKWFHnMA0r8Xrvkiq23RI71T6AzRUwz1q4LQ3yLQVh6P4Zp
#VfOJe6NLrA4o3sVMjHRD6H/yuKmutoqCwNFRGRtwOkQR+Uq7xn/0FQFOIwXnkR43SJ/ureNiJeXOQQ2y+5tnOIiwyYugx9qGT0pj
#kxMhVfoO9Y7h9q6OU3FPmCaonezOmPRC2ubzyGsWfMwd4sdUNb+E52/ho60QrYi10L/B1+ZwcF1u1c6ivbfhRh5On2XKo6vzujwV
#th14q71eVe13f4+ndPilTkCWHT7hVRFNoNcpfPK9zMqgXEcdSEqabb1h4XA5DH/vwEHNs5fRa9ZuSeWdfCSU/ss732BXsxZZ9ube
#GhXK1rbKeLs2esQpj1cfUNSegMTNmbGdHq8ZuV3AjEspT1f2EEihbgMsYbNnTgLRBJHfmromwskvfHRpWH3rvRBxEb2zelJG9UV6
#IePgqHJijjnqEapj4yfMsI9ld5NXFZ+iNx830W9gPmmx1ZHVQXu60HEnMJj8/hQFgaUWx/ypIXOD32NCEbw1H9OkRMLe0mOiMjJ5
#oNokxVB7w/DO82S9RLPiAI6pt3rEaC0RZ/43vQ41lkRNIDtt+mN93uKF1W7SKjUlexWTDOKMYUiRYUe7R92MZ8W3b0Okzz7t3Hrf
#2XNg2iPiXWVof848OJKZd+saW7A9J8lqLfTZOUprS2jfNSqaWRfmKtZAq8sq0WyLn1KlO9Y3X6n2sesIDv2GU+KO4x33amlkwe+k
#dWz25WvrJq4k2RJdGf9oSkWcyKe19+P9TxCL9qtneSv8lfNddtdTKquYDOvKr75ijuLcC0hoBlxOtqjzTdgpN1Fh3rAz758Ld/fo
#f36k3Pppi2Cho6O9F29iRTWt5lZpUhguOJB7sUrqrNzenWcRc/SS+e65/wCgpvpwUind7DYnTsrzuJGrpCxv90s2c5ZjYra/kb9z
#/tQ3BxkvRfzKagRtNedw+naSVJEXm0Yt+9lRWQuJ73jwcvml1dDks3Fdh/NriqKQPGwQ1Qa5uuQkrx0PR6qk1LB6u3yOKgKL42rQ
#T8n88l59IhlBO2bFrHQ/06TiyqVXkVzfHkkCmu33W8EscKKyUG6U5bK7LhJZ1HzRxSMDALMPbuAkv6qtwJ15vE7R5psxjF9fC3Yg
#eFLl9L5b25W1T23xmj0vdBymYAaFMNNUP9BXQ//L0WTUwdEuVG2H6FPYsIXDV73QX8yBQHNHdMkpJRoW1Q/lXrYj2qYUEM3hEv3P
#VF6iqbY9krh9NwtJkMw7TeH9xil8Tukga4wHmfE2S3u0RoZ6PbNGE0nYT0NIXScZyYCWvh27vAZwGcGEg5cHqr/SPLvZM9sBQYSh
#44rjR5wAEcYgHN2CesJRMzdKhJaycNPeOuhRZVolTn3Au3S8iSoyWhF8HiXsXynKRLIya5i10X2Y6lvprXx49VZ8VyfAeVZ7YMAR
#bg4igYSBmWmz22p2971ddKDXK8caqNovbUE7sqdxql9JiJF7Y7443GZrk89jSG7jpZ0SK6uzSe4UtFeYIcNtMI1WMNfJcD5le3Zp
#9hw2/+pm22V/c4RFvl8jc3urdRk9qev1UBV+oViokS9VPntTuFEv3ucr8q4gChYie7FrZpMXXLiwbLQh6ZX8QsFxrjT0ONII7+G5
#Sd5MucfW8eJ73hip3JBRmsV9CLq57/JtNQ5RcqdNt32TJE74Sa8RU4w1DDiyz26L5ZDnnrO2wPB2g75JzLrIsBzU+vWSZARe0o+s
#4wXeoS8p+tw+dJqRtOyAXlPr1js5Gf2e4pu1gIhrDjxTFehaG5Pl2wxCndWhIqzbJ8KhXGimdGHNzhHdG+Yi+I3ybmm89xXWQbm0
#1A6vSzTapU2jIL06IG5E7NAtIV5T4DNB7ZMJaHwhEdy0M2hadHFcDD9mD2KoEAoAsN03vZC6v82nhalVwMwKLhzZFUtZ6ekljcYQ
#R36tP/LpoKn8ecajo5dTNxXUoNfnKPKFgML7k1rYm0sgJ6qaOKXvJ+PSnTumhkT3D1eDWvFNRG81qy6Ze7Gvem+r0uv4s6iHrDUL
#GS+etlpF5i/PPO/EbkN0jSSGu+YZI+mea404rVu6NrBX92Cf/dzu8uUu/AWUfnNgy0F706JERnyfLvoT2bNIyKvHQRj0x+W9fGiJ
#cGaU+SjPJW0zdHpD+8Ji9Mmu+XGF3nxIpdKVlURME4SbMRZLmAW1B7PDMJmGBcE+Mt3JepalzC6H90xTtcGisi2iLc9jlkY+FzZ2
#ahCj4m0WJxI6xfTW+xlB3Fh7k8EWhVgbN7wQ+wuP9pFtt8Vt1jV/ucAWmrO0La1mtINvREqGrc5G4XvIw3xnlCVNKwPPV+KdVMhx
#/PU3nYdQnNWoe/S6qpD1tdl8ECH0EMQ4w84Rpuvi+gcPu89hb/byfESQj4eORfXQg4ZS5l1vw79OBVq9i/I3YkWK2xh/1bARLWmQ
#H0uNKUz+jOKug9lfcZzgy7W/wb7jaUAVN2mbf5eTU4AjS48j9IQhg6Iffbp/TtKIrXC6rHBN+ssptxL+7asbqGR5ZMiknqbnGnRh
#N1I7JeSQiX3HrLHCPhZr7KKhto+jOS2eVxvIE9l6RG/GGzo/qdEEPYJdyzjs6GRx5aZCzk6zK7LMJanFAWw59J84WflXd/latmf3
#QL9qhocgocKr6+Rcm59Fz1+PkkRfIEfu3fKlbikec9zvv/xqlmArFCz89gSBwuBFXM8F5LQl4m4q6tQNT5R/GVd+kEqoO82xejwk
#us7UBByEzsrCfObFAnzptep74u7nCt7O5uNbCFcL0Cwj4SPz7zFklT7mN232rim6obl8CEXNIImGrH+KuZIY4MMPMYbUz4Z71h29
#jRDZVVVR+jLY0J7uXHG0gT6Cet2M8asX3CjZKqtydhBxtci6okdHWLGAx1GEXF/MsyGWz8NROgIclEL6j2JZfXWeYvX3J+L3Bfd8
#XDoJPAhHmn/PZizs0fRir8PjLjA2xhHH0EDV+WOh9FAhHayYgznJV1JbKDitNjssSedtUEbwjPiaf+PjWfO1D/bvnfmzn0U01mOu
#yLINWMjnMOCtGG8FBH+BRA9ROZrxb/ia7eVtOk/HZNVufZz17fmhy+v6s+zigpN+5YnndfG6GhhyzFSaDIMIr5AotOKL8Gt7o0Wh
#iaetCBAMZC3uw3bgyyQXLF7l+7QMT72wJq6Yso7dPz9EUrei9mfLTiQtLrJCd7Fl9d630OFzVEtAJqA9f7Vep3HBgL39ddNZcuc2
#XTdADPTIZeveeGcNWg6YL9YgUnGgDaLfM8aNZlJC1njpUONP1nDKGH2VaF1yF/yqMbvzVtoPt8YZwzDRicVg2FpM3shkR6ZIrIU9
#GBZ11uxZIW+CjovhKwfBptRM/W1C4s8SKBPfJM0givPlMERuWXU2ZZgTIrVbdtLN+vq+koBsrWrSI8eB4bu78EcEMUDk0YHdXfnI
#hBinnv6POuUptWW3ZW1zq9PzSSgRVquTePpmvQWALBCKdCMqmSfpWVeS79tVAm/Mkack5M/3VXPXBjCwLN7tL34j0aTKnYoZiJML
#Lwp6R/1NrDXLtcambOvqACtK1DTB+oujbnvis3AnNHAFJQhxbvyUNDI1k0K2nWONqa6Le7u+SqtTZ0OhCvT4ldzL67e7jcJzKZXM
#WB2hbTt8s63p3N/mBMxD5tCTo9QeK1hZb36rE+OLu8Me2wmsqKKW4ndJM35Rfft4XXLaJtd9ftCEGqvVcqWLeo5zSmUgZF5/PXl0
#o2tlVawBrbnt+HjfZiOwoLPtmLRkr7crDmRYCXJQbxrX1c6cqK2B7iT4wml0FmfrLdeinP1GY55uJlcBWuozN9RrzXWy9Xmr01wz
#S9+vyyoDKIrCl3IL1qNZjIP2sTNmI4TuuQP24xyN5WXaDJrzhC30Rc8J44lK4so5R20Ph8b4v1x4Y7RjDZwIxC3GF8BCvCAbD3bi
#DqO+Q34FB1kOFZTpyk5zfGuwDjmJOxx+Ikk7KwuhwR1LjgPxuW23OiUn6AsCqYQKtNkhGruuqTR3kbSqua2LN1U1C6ccNIy0uF1X
#uRY9eD+2diNCzqtReD3DlcpbIys7h0dyGy8XPly96HIQoc3vZ619v5n68oroEU3JKCUHsWylhfcosD5PoviE21SLVI1vh7KK9+7S
#ki/URCUCa47gdfNge5FnKBEMOjWTZTi0uEFYdIXzS1eZ+hWb5PaIXgCnOhPqgWhD0K57TBX8eBYWuzT8k2Y77YZeixC0vVI99lJs
#h6L1t1pr07aOGjb8wskrb0qA+ylv3HR1zStq2m5PtOEmmBebMyiyWR3qdnmxvrJgv8TX8da1rB5FCPo4Jj+Q4RhRgN7bVnjaR5tI
#B1jFWI+xG0JGymhcoqgDDt4RxlrnhDfW9Q+UUNvqdCUxjPfgEefU1o4gkqx2vu7ItfWP3AAVVJevcCELswpk6R2l7qN8eIv3YXBw
#BLCeiwbLjuREjElUwoiC/40eToAplqKItViHsOHKvfLZhECdZZ5200RVw2YAf7ASFFwJ67vg/HiEDTOj4S1RGvUxzPFzXC0fZP3O
#Es6kqAHNsHCYbhT8VT6EVyWms1FKn6Rc6UxpWD6SoPQGvf7MKjCZAJ+MSvdeAqBEyk+pg8vCQxUx5N0USltKS+lEYfKuDv+J0fij
#ni1xSp79RU6TD6gA+xISX71G9PSuMJuusOuuYk1LjNhZGzRELViUyahN59cfSUdnWR9vZAazPPayV0LKep19NXEF+QKP2jGXQhhq
#daUjf/UI1LDCYJjytQSUvdLH6Pn1Cmd/1Oiw0vsO5x6pTutLKrs+dM+YEh4kC66VME9RydJaay3D+lLUkzuTIOL7+BPUnhG0weuR
#+9KN5ZWYi4OPG7kdzGGdOEfky5DoX2kNhT5u+46DuNxcv/jWhLu6+QnMEi2xM+AJ7eJsRp/sS/drJk0gTAtgBjNHZqFf7TZRQXYh
#C/MjVF2o7V3tlJwE5pzEYm0baieN8xc9dcY0B0FDnHw82C8IsB7E04EmgTGADOhQ2HJxNQ9UjkVQ0rCwnxijZcMb/txX14ArA18I
#ZwytSPJtbuXsEkgvTeY5Wr6+ysOjyiTALG3BRLHOYsUKlX14aFM4SefBtBYSuRQ/700gqTTzBM3EsxrBJXz1MbOt7w3UVYASV+95
#0Fyy4BhRg7+OsdIXpYG8R65zu2UuEkrO7bWd75UYSE5RlIOEx0eahLPycXDen90MKM5QUw/tb1s28sXt4+rvERiKrBdMQNMJFfvO
#3eWJt7d1yR/sPU2dvioO029ukXI457U4ZYuaYcbKoNvOFoR8r6ZHECNQC++wK6G8DjflztqhVOXVj9vHE92yq0CUxSuspXXJKC8k
#vypXnRmlpGfG+maNjEWSxH0pWR2gqnyPXX/F2+FKqBJHEEiZ5zt5m6/oKHJA8QTLkY641Fmi+rFLIJTHlod7PnY389qTULQYB7T8
#A5jGt0bcmROvexlryQzOWcVId2Wey8KJqac+nYkUHRywMFMK++Tu7s+X4zhoTII9tuj5NVjLIRdXMvFgcWCyB3LzRWLz9qHeDtMH
#PKDEyzwWjSKWEs262uHMXuE254Oyuiu8sPVx1tdoYuE5krQIDKzQYT4u659Zz173+L/lvxyKZHhha60pzHXZqsstqdwY+57ca/hr
#jeV5qjAZHMYepJ3R43i/3Dp8/zPLznbqZfFhyfzQ3NXaZBaIBKx0ib4oc0EIHrdvY3Ct+hvdhtxiH5/dZQg/A5KEYbg7YinSwc5/
#67bMglNb/hx9ov+CxFZUsl3LE9HrSnA73vmJjGvAK0ipy852svZY26UwFpLoTjhYYeIKHpVx5QU2jJjCTtODlL2SEQUPPjkLXOnV
#mkfmrduprvK4ENuFKQAK53uQLd9Ez0KeEnrHY5HjaNKe/SXEuk9lBO6GXTCFy1b5FpNzreJuoWbfaoUuv23NLHSIlKKjS81FRk55
#kABQydT4uNgoItYpLAgX6g6v+zL3CtIsCblK9VKv+kMX1j05JdczK8rvEaAAHNxuhnJdL1CRYCe9nyHbhA6iDrGeHNDeYPMpujcp
#VXchf5SgL7PVewOKYt2/UJt754Zz4iHRiVRNKrk1PHvABlxxsLLo6lKHEXv6AceRCca0Uy19VMYVZi5lq2hdIM3+7Tz802IF70Zy
#FGWWbYihsZLZKDcHUahHJTJ87/mzniaDpIw5G160fXwM0iMd56NES0Lq/RzQ5jt5uVKRWVa5dqkndI8r8KykpdWC1OFdaS3bsp0s
#YfWqqosjejMadxA7NhxE8KnHRNR4t6R25FOXabJeWd1nkrP1ty5vjkhLFkvxDC8u3ZQGg3atQkRKMxXvDk93JsMh7gm01jAF3cKw
#rd4cuL8LYWiSoA4dnqvmOVHJ2dEX1TEC2U+/MxVCxug5jyNw8CYQluYzTU55QXEMeVhXuSaBEUcMV/6iCmIau5TFZVmxyT12LGGg
#rUMS5RE7dyBMZEV72tvlS8FyheeL4u4vTNep89++sKOFfLQ1UHbV0SW0b/q0SwOhvJPx3MCPtUAE9IG7MAF1TF/BLpzNhtrGu4mJ
#goNmQm9PJwF6gKmmlJNFnh5hJ4HG8zTz8XTfFyamAn1tSePmkGjvfF0rukmHLm1rPIWlMG5jFedwD5s686TeAms1eARqWUrvd1Qm
#H3Zm+GPEkj2l19F1iRVeHmrm5NihiY3KsUv1Hu3L93+lhofEFG7C4bU27xkAWQd9W+SuZt5gxFizQfzK6eKcE4eEX2n3WsfJOIHn
#yruXOVLicK8/RmUfMl+SlBPQtb8vL1AaxSFRo3KRXTHsHEuvNHoKWM7o9A5u3ugW/tjz9bjz/ujb/rXz5dFJgjhau8PgrjNfzWOz
#O98M51xssmY5MXZray031o01uHEpK5eUC3dbAwTJBY2eGGgCgkQJf4v2rl6O2Apt1srQ0+bNl67VfFsSZ+aMEAr4HR9p3a1vPxOP
#Y/XpsVX73uhfeGUwapSpno2T7ZnyvNnHX4Wyt9JrW//GBANz5L4chgvD5uzq2SHE2aGIqXsGMsR24DqRjc7iERLa2353avMZESoB
#SMIwcGJtdErqRZW9wqDTUC/PaCaA+2zJwlK3mkMGwi/QJIj+zDUWIWu2i+YrpimzSae/nw8+6sZKO/BZ45FZYtmnfo+erKKnUYX5
#h+cDPerVRzwIVvQmHWLEyw4lRIaWakMyEmvcW0yu+h/MpiFAxizTW0JrNp/fcZOI3yNFm75FEAAANNWQKSj6aqUOX8vKKjiV+jB+
#VYFJ2I+77ljpPNmtR1zqRXjOz6aw3fzyCYdn6nudYhPcePkvlVlRNVt08zLLsRU8YWYixCvQMTaS+YFVT6YaCxCHYHkKaWw23krT
#s8E//YDBs1BHkbS/BxPFNEAypTRTJLR9xkq9/Jbx8SdzbfchBUR8B/Y3SLtJZG2IY1xycGz8R3SPP39pZA9Mq9adrzd6p1Tdt/dh
#udj4hZIgmYoIWp8WUCZtNc+LI/OK+9rgRQcXDUtrsNyI9xMVWNYwh8YopJyYNo9s21HJN3ly+2mM6MOULFbvy0UrYlEOIr5pFjZ4
#Jn922QssF5kP/gQVeFFbsezo8FH9WsBb3EKqkeyYhGIh5GuY9HAogdbk1y5Rw2Kjzjfk/cV5BUSFaeqtz0QyHvMWNTh+1Ho75NNG
#dy3w3j2baB7HZ3HCucUeN9ndXsksjexTSOl1c8RA6ieeNS6cmw/HMZt1pATeOPYnm6D3932Wn46uLxM5S4phmc+Hsb2w83UxSnbU
#LSOLei8VVzdCv05d5hvlJ3zNtdthtXEdkW+qhZ0PspMXGTi/q7yADvpilr5H1/4xc7d/a8TcyJjjcQ087mQtpZ/37Nr+81Hvm8ka
#pT6n5rmPCK3QBYmM/rYFAJqtC3dyyYu6MAjsxi9WEjB6kVnlndPUgtIXvQk1nEzQro4hn40y1a/BPPAS75J8nkpM3dbQD5n3Dp2t
#ccAsX7Yq4ibHjJ1kvD2deOQq66WMWY9QCaZ96bZHwGxNbrOVgYmDMwNjb/bR3eR4PlD06PNR333JoZ+yhmbcY9/+NFv+aahvgno1
#UQ2HjDdpFZINuxfRIOWMaA8P9JnXGgLmGLV+V8F6HE9dGbHE6akS18o61gKFOZmEfPPx6td9Y+rpVuV6cxWxAOHiq0JFFFME7xIr
#rDnst5MVB3N2cgIpUwmXFqI0/FaRdyBdhASTmnkGdh7PekOE4ydifZLhlta2O5/ND8m/2yzr/vqFOeD81nGKZKNbaJ2kra1KXf3T
#QsiuLhHPwjgKklrXteksuwoXxrxu6suZcrlxspIZ6bhR0ojRF6tTJOtCwk8vTi1VucOhcbD5nqylDF9MYSs3HMgWGQ6sto8SvMmC
#5ESnYB2ewW6RS5zR5XF47Fk8aUSuU47AgBfda8Hv2f31PLGUcgxZHxtj8ezVNEdfUuXhKCJrkPoh2qWYcmTMSMmlAy5L1OdseOPG
#U8wuifuqkS8TsEQeIcmLrjXZp7IhEx6bCTbxyfjYQVbdHQ5kb6adDAiK0lzwqbVkw/dOxXh5uCJFbPbu6e8+QDeXYl/kql2F5ycP
#G8QwW34wOZzqE8Q1wJM7UGmkzIWGjMen4CH3jqNGzEiN31E7xeHNfJYyFn5IzsVdJhVS7cmwM70fZPbcQ/OcUAWFUFyHfI1nCyMg
#3PfctHe7193h8abPab1h+GJPQZ7KM8sSL8yoOiptZNwY09OP4t1MFuzCiyM7E11sW+U7c2ahaYhivtIx0vvTe3718nKayktw2dwy
#Xqr+ztub3Z8HB/izhCFn+Vqv07Engl0O2i14u4VGZhmcXKdtuM/tP102DJmTyofH+SXcJhxLtthDF0REP+I12xF29whoMhfsy0hs
#n/HTGLmDYBtvii/muPFq0w21kF5Q/rQu0OLsVfXyy4RotOBX/C5o7JpIAW0VdMDBE0fcIEJMpgyvFwO8qN8ISFUxF4psm+Z21h2M
#qKEJFG0ECneCt++41clZ+BnbmDAnn+mGh7VWpdAXDA8fL3Ua0Qfcv9gwmvLMpVXxO6cOhMd8OTL6DDlYbrFp4wRJ/phTkvvAh4oK
#NtHvibs9SXbi3U0LczkzzHvX05dloedj9/FfWQeh9I2bC3f9nghpMu7fX2E/OnZ49CjfkwavSTkb2xT+nvpSyl5Z7ytpUIuCx6u4
#yiVH7CwJvusdZPTerDigtz4nyHdLfEx7e/vQ61Xsy+X9i3yU8fYuXWHzZysIOfXkqHlPdba9SCkuu06Z48P9q7OxmKDaUv21PTYY
#2aCtRlDYlMC+BBFphO9Zx6yWbvj7YkhZcmMjHJDFRWtLgbOGh1ugV0tgPHDqA0omXzmn76vMXILqeTa6/AMv/NIJ4/DcIUxnsqeN
#TV3T3c7+XPMQbYCvC/Scydoia/Y6C0srrrf3T+zuPJ9WpIJYpkGbh62JFEmPcfuxB5t6xiIgjYa6JBBt2pdHhg2Cs0tluEwa5VXo
#k7BsapW4q5pm4eTsOMhT7UH4mJJPCwVM3G0Jh8PoCv2H87iKLeCATzQ9N14WHZ8N4Ljs71sYbZaABFKC3rN0w63inXSkon80Iz9G
#xHJeNHhrG9xgVmIa1ZENw0PHqlM7/BK2r+zu09Vj7vTPeWFNxidTniU6hsltNSp8Qbl7Zp8Ant4sqqeK6UL3ebIXH4s18XbPHEe2
#dflUF0oDqsfNXEbKWZ/gohOYsXIqEirqHqa4anmWXcraxdBwPkc7F9hVaHh9yVdGqRTYMTc9Kyx4wIZgcU0j/G2dO3+jW2CNeMfS
#28f+iZ4Q45NPO07IQecGIvWo1cmHsYM4MEJSd7bvnukhCqGhxNnyZGtpPfLlHIWLw3fz3ltyjRhQdVwuLU/JQymqiA9CSNHB6S9R
#OaR6e8BrhFUnpPNJdSfbjepyZ0sneLUru77J1n+Mfb/yBTwU3nqXd52a5gvwpCaed6cjTy3e/tgL13fNzlvkUCSeUvvtIBB6/kfF
#wTNCeYiG9LARMbeV2dKaWvStVLSpLP4TsWdo1EG8BcHVvOKLfamXSdUdsedQ5Rp3rXJ0DOJK6erOSzarzRqiRJYe79i0JUsU8WHk
#ZI62cWw7an1jzp6eJLyXknCWegbFqP7GULU19/GgZxJV+5NYxKPo3OHwfPpC6pW1XXdd4VLnmT6qoszI+cYKmE7xQpLk60J7gkf6
#mYvARKpU0YV4mG77YGYykddrKzjI+2ePjp8cW3VxOva5Xq40cPTqRd+sH4aQDWxFOMViQI6eN9eHjH36NGHTVvrBHA+cJcORA5vL
#PvICJc4jELpeROu5kCfs+CVuycSNUMYxIl71vt3oFHp6seLf1CdS4cENWvf3nElb7B1RWzSQYcC2f85cYl3FJ1b6tqpiijGnz6PG
#4plUcAe+JZH10Hu23AkPMc6PvaRf8b92NfR/ft+YLTsblT8of76Qoi6wTuOd/V6aoT2cmLtFX8p2mU2MOiRCt3eZVASiOGcxgGTK
#ra6WgLD4ufAXwPo6TCRqotX72N5QjnT4M5dUIceG/Q+UXY9NJYMsOeGnIe5zr2WDVuhNUrhOvWGFWDMmdQUSk67UCxC0k5uRDVfh
#vLvEvhUHUF5d9i3Pd1C7ohZ9etR9RgejYdY/RHSwyAi7OPBalrssR0c6zcIsectP5NnH8/ewDgGDgbisrG+y+JGWJ6OE8iljNTdP
#1ivMDdI80M7f5qy4A3wez7bhp3PkvSl1lUsdvXSayltkdWGBVq0iFQ5/O+I7m3Cr+dj+0fVBypkzLYKFlXcFNlnUrrN3Uu66bl6l
#IF10sTfmSy65d8EfUjAQlphyK7ekNjwAZ+/l4QcKBlEPL7jYrYGPqrvrYG+Sn2iGDc7HUSuR80qpTdrIyXmTlvnpJj+pJNRldww0
#ZXky3ZgeeDtGEpB/+YKwXcxlJFw2Hy9RcK2OhrzJZyD+2tvo/NJWQjz1TcnlalWV4smTrx/YnIx5/fkYcZlf77/iYUKD5j4mk4pM
#7Ztzld27z0Aj4sI5mCleshjKWDzPGTCuIl8qVPFmR0FUEwA68htKD59U1N1DSb3Twkdjvt9HFPC/PP9U9sgvm9l7O34rrbee6dB9
#+xijopjWlZYXh9LhnVvddEbvrIt376ALux6+zeySxzZjquLnUocpS4Svk0KfQI6TKg7aIRMZ7FsdhCKYOYIAyzwEfaNjwmctu8sn
#YSqfU/wn39RcKZOjy2Gjk9VZcbCK5OVkbeKqOKuvrS88mquVLzk58FNXfjTU96k6uySriplL6UgrtCg9avOwKIsDL6I4UYIpKetO
#CLYo0fplE8PLZ32iI3ESQvRJX2J9sogkLV50AEPUuV82v8ss27QA4uZEAZnMzMgCTvtFLVhLPYc5Uth3TWhMD9NwoHiZCrGP4Uvd
#oUv2kgvOqALMY6Nn7R0+ySNamixME3r1xbTxJCnzK7bWm7bJ6Jfz8ZL5cgutHLDreZYFyjrQxG2SlMs+Z1za2RYZNOSWrm119yXc
#2AnPuLoME9JD8KmkgdqieaPRLgnaKs5lzGVAGmUTNt4wUUcXWb0/u77Xmym7uJdvVYb8xhzoFLgredWWiPXtFbM3fpQ1hBgMBETI
#/TdTIvWQzUhxY9AAcU6PgP+t2Ga3QS4T5OpQgTX2O/wIOraYJfjHY64oDji9xI6wvMG4BVYzO44RM3Mj2xd6kyNiQrcgIlAIC4kh
#4CMbAHvnvns8vz9BTvUOM8XTj1rhyFqix46PoC/UU3O3apt64yleluuddwCPMlCCHDfcxOLJhH9e3jyW1/vWPYGMoxKvGuheaMlB
#wX5ubp/pR566rDTF/MwD3Wofks+FTncFsXP5j6BncLMCMYlPzSgG7oGxChnn9qZjjmyYQ+yPeE+Hl7nZJ4sTkxQNmuJAU3XuJMhT
#yR/vdGZSJlyj/domIGd4mYREzxvOhgMxMXuf2tnzMtMqe+0+5VHXAXGqg2JGeCG9KX2S7DFlxaIllcwaos7uNfWzqksS4c1feQ/m
#crk4JeYe3dHEw6uvvpi/LKTV77Q1ahZu2/8gdIs5qh7pdSkh0bcf2sxLJ/TExzB0LJskb6CuuqHRQiDR5r0M1ra18oXv9tdkrITI
#1bOMZDpg8MBd9iv7VlYFEgxIUlMIaXhWaI8ktxHDl8pIS+o1ifcEChZ728Y1264N4tw3asNhLgoFRQTFgc/Yd+FiV2H9/IHDz/PL
#v7w6U7vBLLJmjcoTEpNCMtKlsKB7L4PcZzFrgS+uRRpt1qzTgzApcmHRU0YC2R2kwAbXv6NNIbHjW0TFDeiWQX40i37PQpUenG/L
#hGUhhXQ0Yh4E4Tkd15KFvlm2KAZhDKoSV4UgT8d/gQndoy2bABKHdO6IV5FweUyhfeiQtha3ogPX0oYoEc2CPYQg0oKRmWDpQfY8
#koFdIZ6AAmDNuVp+KaV+g6VLJRHs9jIlHb/UKHUmRsNahUIyVWqXnoOwVuyliRJOZZzGBrsPWYRiafwGA02aJkxulnbYrMbqEqo2
#36FyDM/A05QvOG2l3ALKVaYp9lwegUW2dYhKWfFoOPHq9iqqoFpV62jqFljVBXlKgn3JL13KaEOfvwosnLDrlpRm4VdoSOn2WcuE
#tuTgaGaup1xIv3LdYti6RDpjT+CHICLFx7V6qmZbxbbi9zo30aXL6LP6ZrNH9ykeqUpS0yTvcYhJpn3c6I144AyVZu3VGw/+MF8G
#sWLaGTMDd8WWQ7OlgehLvRANSlvOLm19MsV2agI+C9t1ZGF3ceBIBsVbVIo4Nj6UuDQ8pGukXrHCqbhNjgUvrLimNxL8ONcTNjlt
#7rXrN1kWMRXUh1X5d3Be20nBCTcDipPcQWZpPWpj1tb7BlOibQ4BfdIxbGnPodLL5fLkc5r333zI0T8iOMhgTVTwHpwXdDXSPZ2k
#2fh2ylzQE9J8NbZxV1i689qC3ZazSTMhW1GpR/KRGlsoSvKwaLpJx8eMjyzKTomdZt36crmOX9gzKBfExp3CWLjY/TNVkPLWeZNu
#v52ft3DKUVLFReE18FpmOz6DLaV5hRDaqWChKomnbn+xFcNc2O+zUz/tz82YstXqC6Ib086trXgN3wySuvXnXBjSNaeA9nljDSsu
#2CTdYG2lwM8xzQ194XHhgba3U0hWXefKcorqtMD8mMWyOZPX18LSIpGJFPY9wKncSYskhNUJ7v1ZbTY3S4I/VekTPiGFyMlhEUmo
#fOZP4ThDlLblxegqRdgvJIIxrzXIVdiI5SxFqUJkl+3okeZUSPFVyFVI0bFp8VXYSNFpnY7R9ug6DiiottEr2nL2Mk/heW8978TJ
#LctMOjKyF31ODLvqV92LX68qZ2ffqnBlT+I3mS9Kw2pkt6+Xt8U3bvm7Wo0rx6F4brK3v6UrdAGo3Up9u9rrUVHOsBo9zBf0zaAY
#ambJW2H3bb4f1PiqZ/15yKYsMZuOz9/wAn8NMgHnvcJMWMdsMwe7Yn9BxQmf30vWdz3NCrzvmvBZ6mQZxVgVRcI12ODGxjyUnZ+N
#BFJ/IPhGUJo4SBopuibtqsBa7RUxKIKsJLvPoJZt3oVDQOhDKXm/jc9IJI5sKV8WxfPhflGM0Pbz7Vo8nJvZRNcqYf/AHDSsWq/J
#TtWTso2jqZ5lOgvQR0SpR6m4KFD/13669//I3z9+/9kDCLJwdGH+P73Hw688c3Ny/je///yj/Y/ff2ZlZ+PkgiDl/D9NyH/6+//4
#7z//J/mbgmwcgEwONiAmW9f/E3v8j3//m4ONk5XzX/Ln5ODm+v9///v/xh8zPRIpPekPidu6knqwM7ExsT4M0ZrTkbKxsLGQyrnb
#25iCSKVNXUA2QJeHKTWgPdDUFWhB6g6yALqQulkDSRVlNUjtbcwffir+Nz5bVyZzRwdwlxkJiczSHWTuZuMIogUBgHS+5I5mtkBz
#N3JBQTdvJ6CjJSnQy8nRxc2Vmpr8AaelDQhoQU72a9LB0cLdHij848H0E1QQSEvHR/4L7R9MP1ZTU/94Mpk6WAj/aNIC6fhATN8p
#e1jrT+tmbeMK+E0XmCh3VyCpq5uLDZgwfg+wUoAEfd2dLEzdgHwgd3t7gBnQygb0o2nv6Ogk9qdrbm0KsgL+l4G/2+KODk72wF+o
#Htb/c8T8v8zzsQIsbFyA36njI//xo/vkAFN3N0cne1NvPjIWgBv4KPbgkylbWroC3fhY/AFAQV8LdxfT70tYgewAC+ADKAsAbNcS
#v5qmrjYgKz7yBwkqu7tJ2pu6gk2flhVAysRJRw5wcQQL4AGVm6A+uZuLKcjVHswAHXLAn47u3x09cMfFEew+gL8bOr9bur9bD2Cu
#5qb2wF9PnV8N3V+N7yB2QM+fD52fz4d5J6CLq9MDJzwe1juYgmXk9bvBbkFuCHAR9BVXV+fz9Qe4OrmAz+cKbvrz/xIuqemD2gHc
#6HxdgG7uLiBSRVM36wcHR/ujYer1XS3BAP6/lzj+0NSfC0BMNmC99FK2BGuRECPrHzD3f4GBvam9N+13IQLp/B+0yEbQ19TFhe+P
#AfyGFnVxMfVmsnH9/gSP+wPAZvGfAB1plb/bC5MTmJuOD4rO5Oao7vZwUCYw6+zBoADyHyDkYCxObtb/CYsNExg9uE9NDWKyNnVV
#9gSpuDiCWevmTUsOxmpqrwAEWblZP2Bw9bD6TxjAOEBgdwkyfzA0dS1pSXugAxDk5g+wATn9T+FlNBQVZEFODyr3c5WFo8N/XMUE
#crQAaoBP6ednwwQm5TtrwIb5H4DJXb9z4Y/5g/wBliDz/wT5X10FGPZB2f8DCR6ONhakLIKCgmAQkI39f+YmeC247+f3IOwfoNZA
#r/8AykxrRKHPwsgryihl6MvlT0nn9/cAO3iA2YbJDejq9v2cLlZm/wmHEXic+Q+Utet/IorZCDz+F5S5439DOpjQ76TbMIHR/myB
#l35fZAf0/rPot8mQ/RedcQMrEhnwP42SgyOqFdDNFezBBd3AXTBGSxdTB+CPgb/t0vyBqgcjAQoyG9DS6hvRGTLQGdAxg5088GGO
#/yfFQGGgPqshk6uTvY0bLdjy6cA260T7H47mZOriCpSydzT9zgA6Pn3DP6bq+sNUH7ZzE3zADnAUNKX9IUc3fRZDOmFWvocngIkV
#wMrCQgdw/2ua9WGahYXvofUbwPUvALbvAHwPjd/zln/Ns4PnH6bZ/0zbC353P67OLm607syOdAALQVdmWjb6v0bpHenoAE6CFgKs
#wvZ/jbMyWtBb0IG9uYcgK8D6+zStBb09oyUdsxMfoyWD/R8WW/1isZsgmIv0IGZwXOAD/WKs2/e13xGD4yotoxs9GA0dPa3Hj83M
#HV1pnejd6Bisf24OdpkPfTo+Wg/wmBsd/d9L7ekA323Gz4/14SEMjkGMbv6/RfiXS/kldBemn+5aH2TIb/PgXH9B81s6utD+IJsF
#YCrIws9PB55/wGtF68YgyMrMRUfnCx5hYDAVEmTlojNzAZra+QPtwSH8AfphpaOgGz3tAyA9+Mi/Dvz3joKOAEf/P/ph+R8dADU1
#LUiQ9UGYv4gH/jOMmANt7GlNaYEAViAjF4CVjh5E97AtWP2+u397gAVYgP86ORgjKzhYszLTghhZ6f4Iy+0f0YSVkZ0eyMBOD/pD
#o8s/AMDTjFx/T5v+dYR/rPsezQCOvyZpad1oH7r0IAaX742HFvgMD89/xbY/i8AYf60CQ7PRu/xC8bDwl5j/eA6AC8AUYPNdSCwC
#D37ATUCQlZoa3DalpjYFt3+wwlwQBPQk/W6y7Gy/IuGDLriBnYWLn58p+GFD90sbXMGydRUA8TMwuNKZ67uCRUjrSg+O7ADT377i
#P3gFN7AgXcCbgh82YK38l5I60j5IHkyuDd0/tMGFzvfXtjZgJXQFm5qlIFhe/K5gkiypqR/2FxB0+U6LDYMg8LvS2QvaMNC6MJrr
#MzK6GtIx04KBGFgNGR9g6cCEWgi609r/g1wLIUEmFhZW4b8TZDDAX5s/6LOpAAd4H9MfLLMBI/kB88Cnh9PY/LEbIKMgrePPaUYQ
#OLT8NkB/WhfAj72/c8BC+O/g8GNT8Nzvbd0BNgBz8Na07mAm2wgCGWjdGIF0zGzfocCYhViE3QRt+ICCNoDvdmBq5krrTicEtgJu
#amoGBnMBVhb+36e0edjcBmDD8ENW/v7+tHRg50VrL+j7kMGauvztG/57QYLAC8E89FUHr/lfW8HK+NuRgX44KxVZZjYwAQBxGxfz
#/y0cPz0vWPkflouZmtv9LxINthdasDUyft9WDJxgm//PiP8lAzC3BDn4QQK0tMAfscLJ0ZOWDcDICHbBYMfBzMr6h8WszL8hOADs
#YAhGbiZOLjZO+t/DtA/+gg0sQjZGEOA7MT+z/3/oAVjH/uX8wJL6NQIurMCkgCsF/h+++SGxfohmYPMRfPCB4NDG9j+yxH+ZHjho
#/HUsVhb67/6Q7k+weegzuvwOiiqyP+ceihiwkwWzgf6vOWaXB80C6JOruptagNMEcXczG3PwE9x1cfv+tAE9PCXBJSS5IROYy5Km
#5ta0/zy9xUNk+F8S7G/SwesYHvjpTwf4maiDUx5XWgu6/7DFr9D3sA2/vf73OkwWRM4A3hQI+NkH12XfB/4izO2/EuLyl4ICv4OA
#tfOBA4DfaP93EbkIMHEK/8QFdvBgVeH7jZsRPMDwoD1/NgCj/0n6/9YGtH/R+7DLwza0f3YFawAD6/d9wPy0/ys6Wv8QENjn2TCB
#k3wwL3+5PdBPdQT9ShFpyekeMjkXQQ99N0Nw/vA9mXT1tHEDywJMoDmYePIfiQA5308cP9JD/u9T5g+KIwb0sQG6/J53p3V6cNs/
#lroBnVz/mrF8mLEAWpq627v9GXX57un+mYm5uXj/4oWFo7n7QyHE5OwOdPFWB9qDFcfRRfR7OedvbvpA6m9d+wuNww8u/MmPQEz2
#3wu3BxN0sfqO0vXnkJAgm/DvMXDmyvfDkMEM0TcEZ78s/I4CbvyODAwPuZUjuFgj/ame7oIgfUdDfuCP6tIF4A5wBDwUjqZMTu6u
#1mA3/yuomP6hy/sfJZwL0MLdHPgv0/o9a+4IAh8QLEZwZQxOHoS9Hy5nwEkEQN/wrxLc7B81ywMoiA7sNMDLwFXf90IW7J2sftRg
#dIB/FJtK4ApSwcbVDTzz7xpU3NHe/setirA+uKR4uLX6VUTzgW3yr/0V/0W1q6MD8D8VHaAHx+j/10KvP2bu6/8nk/3BYCBYI8Hs
#dTP8Xdz8Wej5d4nygOX3Ypcfi930XcB+4t9FlwsduD5yMeQDgf/3O7P/g9Xuf4wV+APrz4IW3PwfY1P+h1R+1I/CtG6CzOAmuIYz
#sGAAGLjS6xtYGP5pPNR0Vj+KOqAg2GyFycHAprTkDA/lFAM5OGsm5wPy/apLhWldBB80yMneFKxCzEYUwrT6poyWYER0/7VByWwD
#+FvLfuROv1jLAGRwA//nwuAC9iWmgn/j8mXzp/vv2mCkP6h1oQP8IvV7aSkLcqM1fSgBwSUHmO5/jLL9x1H2X6PgM9Lx/Sqzhf9L
#QPiRfgkyg+d/cJHugXu0YPYxgflH9Y/OH24+6P7DEtP/6Zq/O3+vB7uBf52MhY6ZnYsFXP3+62zgcXDZCrAR/Nfpfo6bC5rqcxiC
#Y/sfh+36r2s3NwEWsM0+lG90ADch1oc24/e2ALhMEwYxcNHTAsGZJb0bn9v3QAR+sDGzgyd+DNOCO+C8hp6LD+T/I/F1pwMKugm6
#CNrwP1R+3xlpKWjzsNYGXIMxuIMZzuDOaEPvDq612ehtGC35gYKu4ATcEuDIwMrMDt75V/chgfnZZHyY+engfgmfjZMTXIo9iPah
#5fa75fK9Zc5ATkfu/+BAfvhX/r8k+sdwxP+67NBnYDQUNrCgN2AC/5+BVpjPgOlBfMLglj5Q0vDn9MMAlZ+Tl5+Tmx/Qwc8F/M8G
#5Gfu4Ofg4Af08jO39nMy9/Pw9POw9vNwAM94OJh6+VkArfxcTC38HsinE6b8c5fyj/oaLOk/lKn8w9H9Cq7C4FKX6cdVDgDIZGMB
#eLh1dDO1p+P7q0aU/ZePBAOLurm52Ji5uz3cuP8BlPilC2AyFGn13QDkYEIf7oe/Z2rfeW0IEH8oQf/UMj+qHxcmcXV1fbAhf78i
#IPvhp0x/g5n+LPZ/h1NzF6CpG/DnLSMtCHwEKyVTB+DDfQ6ICay74NGH8PBwDfqnBy7pfiEQ/nuc7zdaM0cLb373hwteIMhC3NrG
#3oIWrDWO4FjkbQ8Ep4GuNg/nFCQH10GO9u4P9+G/5jxtLNysBcE2wuDG/6PkBbeZHZkcv9/baz/MghGDpevoAfyFmP9HtWtO/9eN
#FvB3Zv2HJYKuANc/TBb7i8nA7xHjBwk/9M4FHDl+e9UHd+fz4EdFGfXAhaoVgJySlZGSjZwOLGQFR0+gizg40aF9cJo/cegDwcYN
#Fu/Dewvw8SzUHwbBavIg8l+RSMvU3h0Idpp+fuQs5L9jh/CD7E3BZPGZ/pXHaPxL6SwcHb7HdLCAbUBOP8I7uA2ysaf9oWR0f66D
#wbIDkwMOI6a/dI2c7w8GRVqwwoInv7+kAIc6h78n/xol+17PfOcZGNrcFZzRPdzlkgk+IBf+9Y7qp03/IVzywY6/J6E/cP6zXPvJ
#Labf24B5QQ52Lsy0Bp5gz/vjkpP+uwt+4C3QE1xGOPE/XIV9t1M3On46UyawWtA+mCgA+HCvyP872fpDhNSfWPfdSgAPVTrw10uW
#h6tMFgZaR1pTcFHx52UN+YNg/n6ZAk5cTIXJnbzI+cCgv1/kgKG+d7+/jQFz5sFQf3KBDuz+JX8KHayPfn7uv6X84M3/nBqcgYLT
#rx8HAdiAHe0/psBVpyDYIF2+a4YN+BB8Nn+OJvrnaD8z9h+q8jNt/0uqP7f+wQsXsIL9zN5d/+Tmvyzix8xf6vJz/odq/Tt3B31X
#dpa/+K30dw7FbERrQC/oZ8Ag6McoSPcPD0vm9s+axEVQ/HuQfsi5/2HKv+Luz8vq34b5/QaanJzuT7kCHni4nf5xeobflJsyODK4
#/DgW459Bxt+D9H8G6cGDf51F/a86ytzR/q86SvnnKZgNXMEZws/3CP8ussS/35YJPvhJV3ezh1ScBfCrBmF0+9mg+3PHDBR2YQDy
#ufzZX+Eflv/nbuV3PQ1k8mIEMXkB2OgY/hrzBo95g8f+Ciq2/74sAbtuR3CN7wqm78e1samAGxPI3cEM6KJsKesGdHDlNwWXO74/
#74cf1PhhFBxO+E2FHpITFwZBhR83ogCgoOOvMucv4p1/Wv/3UKfx57UZ3d8h8K9x2t+C/B2J/ulhfwrW3MbF3P6PXjoKggC/Lzbo
#ZWkdwdZJ/lOLXb67pZ+AbOBJsB8BkH+PMuR0DN8HAOTWQBsra7dfSx4u2X4vUaD19eKTfUiyAeRerOR0AO+HHoDcm/Xh3d+POfAM
#218z4Lb/T1ROjvbe/0D3IIQ/U1aOoN8zboLf0/1fMrEFqz2DAu0frv9LNIwPqeDvSRa6H+9Pf+ZRAMc/MpD52xiBfn6+/g/6yAS0
#9/P7j7do/4j7/D+CCBAcC362/poEe1+g4N8Df4q0B61/SEbA9D3c4VnYgKzE7W3AYGpgcdA+2PN3VnnYAD3FHL3Iv78++hH6H1Jj
#ph/yALiC6fwJ4udH6yjs+OvGghRcHeizAMB5N8D8t8v3BdrzuQB+wvO5AsD/wK6AmRUsl4dyHtzw5HMHWPOZAzy0wSPgLN1DBvxk
#N/zL2rV+5QR/vURw++uS77vjFmSh++muwEmFkCCrMPjBx8L/W6eB9t/D/IMcRd1+KrbLD/mYCoLFAQYA+wAwNx/44EL7cHgX2gd5
#2oCf4Ic52F2w8oH5wWzK5KH9wIXvXeuHrswfA3H6mUf8P+xc63bbRpL+v08B8cw4oARSl8STOZRhHUXO1ZGtxE48icebAxJNEkMQ
#YHARxUia99nX2Cfbr6r6Bor2zM7Omf0zPskR0Nfqquqqr6ob1HvixmhSWMIiJMOb/v5ENG3j1WxQs+nv19rEFzNvGx3/8UgnDJuk
#OIG92wxaGJEMw7UY7lBvMI9dv+sY+r8bp8ObV/ErTLBq5oydh96R+oiGPOgZRHRbVtksKxKSrWyAelQNl4kkp87cI59yvuAWpBzv
#IjntrkcmA3J3B+OqNajh0063kDdenA6YcrYJXQ6FBx73RxS7U7etCNoFbPbaQ9HfTnL8yYUzb/yj2q2jWTfarcQSYEaWjpqI+TNS
#Jnnl4MHolqDDiGAGpQDdjD918xhKXNV/Sh5PH3vDCvAFlz7DEXMZBqGdrYBOaj4YVGyc1+mJnBPt6ZsSfCZcxGgFVIugZySRkbLD
#gv/+JK7i0O4NL29FCV/jkXcwSWhxlzT2nC6NLAn2PIWDoGrIF3xorfoR++oIPJXiyLQy13+koXmL6VgsMY4bW37orgnBwd+/95B9
#wQT7kvnZl8xbyruqoT31t9mmhCKSik8QFuFuQ70MN2Hxvnn93Dqd7ntnsn5KCvVc/TdykO5CD2UlCslsApcVnIUElmCv4uewRaKU
#Gztt3ibv4oeEvi/nJ0Rhb4PlCTFgyALlNGB/tCMjCD8s6MXsD4YtVejODZt7Sk4pwil6+ATibWQZtwUYP0LItVaqqEc/IZhI3kXE
#lB0JvS894TmLL127K7Q82DovYrF7q668VHISX3FSkVC2bAaikw6AAFu294EVj2QkIGK9fPAMrWlDRpysTO6thbLbz4PTrpQQheyM
#brVsEGJixFg8EYnAbwmRZf+spIR5Cdd1EbZ01+PcpUOKITE4mlDfKfYcohuE88aq11Huj3L0bjSNUoySw15chDVd6Jjc3aXdvdzS
#5mzjKUDGcFqVy/h3YR6t6K0p8fwibKO8LwV0Y7XhWRXd1UMJ/sa6/CCRxdFfzYODxO5sastmMJ6H5jFKPG4lw6y+glOMxfqUruQ1
#L/3ros5S9erHL2NT7mCUMEd6XJR5SdaM4gtZkOWP14DEOuQrh5wGjJMouRfL+V18izBu9B6/5FIScYOdYqK6DzTvpKXIekUS3r+3
#ix7buqWdZ+XwP5Uf6DYUNcCHcIR7d5eYQINcv7TbfeZYHgB39cLeQXHQ6we9+370II2AYMS/OfWbdCQnvPOQsWOAbP7nKiRbExWS
#1tHKXEI1K0Js54gbGj7pAWx7Eb7C3ihJY1sYmZYw3Gtq0D/97u3kHTfNQKbz29HeUb/jr3/pWNwPmvYt1KAeniF6luZ1WLi8JG1E
#uS9iFvklBCFY/W1lvZuxrbd09w/owyDNkYwQ0b1gYMRxDi9rzGYV2cu0vIP0ddoKO1r2mLtX63YYXW0Q27XbQe2Zi4M+p773l+ed
#5+28Hdm99nu2XUCXdxOyxhZrWAvZnJn7rvqeKr1G7xUK4ZaDwnbHekYO4kSJRRzmNu3/alDmlYxoDJPFJWeO5sH/heJB4cTCUzkz
#yEbmG31T7Dlhlh8eXNJyu02RdlnvFj83EhIfXZ2aff4cbva0RPjY1io9C58zNAcESSKYt2ow6I8QrzTZZBGSmYRHvy/i5OnRWaV+
#bYFez1kJMeEXBJzoTFTnHvVhxI678SY9/eiRTVQnafr5NR7o/FMVqgoRk9bZOEOQsJHL6D3/2ruiNE5NSe03c1U806N8laWp4vsf
#aAMQPKET1HyLwALreb7T/Fhl/aW0Q/5oqQih/NEPYb9Pfz1Sirs7mu7Row/RdHe3FxoBPD0iCF7E7+Nfn+4ZOTEW7j7H3t4Ozs15
#ArctVbEjUr6916EyHaDDatKJGJ1+0Q0xSh+76aYOEq6BNsv18Ap+MKvp6EGtA/2yi28YyUG1YgiZZ/VcpbGKlLtUGF1H82gWbaJx
#dBmHaUyHx3ncELxYwwTmdMHq53BFD/P4T2GubSbwxyz+JZxH1/1oE38fzghUjONvom8ODqJFmEa3CM/G0YQOIipVUHTojGM9mus3
#EFyPZs5CbpxlEDO52baRG38znk7DS08yN/Zi5OXQfvVw2kvyRlUF5aT35DaSVxubbyKo6sy8jHqVukZArXr96HKon9N4zz1H1Yc1
#1vZxXXxT7R9/uxZnl57R8c/HLrAw0ZOXIH7SVpRYeg2DzZdESc9XSqX9B2dx0BEFUKEQaw3UloXvd47f/PDpCBjqcugExGkxHUAo
#z041QDd0YjB0koUWlxr0Q5kz6zih1Rn8/ekE3K8Rn2W7LsIWT9i23tOlm7u72l0woBvQxaAWaIq/ohLYKg5yHrpnws31i+RFOKUD
#jFrjU7zRzWiC2Dr/AQ2vBTZCxaGfc6nVuRRjnGexvu2ygZXePJmfbkzmd2xqbjod327eRWuUMFp1ZXd3R6djFAvcPfsxrHWskO/f
#RPVudNwfrQ/y/fBmsMZ2JM45xLt5egKbNZb7fLyIcLy/6h+uABeuJXwbCwZexKkRHvDNon87i1Mw2DL3Jdb18sni9CWtK3378h3b
#pQs0enlw/C66iq+pTDh6RYZydhBfnF0dXIyuDijfeC/3pcEnGvW7t5A/nMq7sLXI0CbkYGdaD+rRuafWZT7yi2eROji475z29m8v
#3xbvHj3C1lsldf16jrXOEC1QKfZ+59DSmEm3i1iRRVvyWA0unetOYz6luCTaZpWq6RJ+eqj26Q7CkVyst/vyCh3GyQSMfNLZfBHk
#4G9+OpPe7tN322pyqgaD0z5tzYrOHfm2QeDdUD9tnkxOG4hBmiCovw/TfoSlj9UsgeHqzM4HDboq3juKnoU9/ras1+cu+uOy93Wz
#1bqr/RaNuqd80/oIJrHT9dGjr0PwJUyfxvnWqHQICpdK6fCvKf2RPiWP+CQ/I3NlvmtL4HW77zS5KTBfssHMHhNF3udwRJMtgUn+
#Gmzpjzoj8aIeDORG19N5I5tmNHhnLaQJ0AFFxZrx6CTf8GHy4infXyWXTdJeJnCrxQwaKvzySryXwcBvfBaWcWa47uiIOmI5jjzH
#Fce+S3v0CJ4OqOlSY0S9ULNu4bLPhYdTERvc2/bu6mlU0UPYJ6CDrE8ImIU9R//uPd8FX/LwywTfAXcGp4V12U20213IL96ixoYZ
#W7x5INfOio93a9XDHe0XprH1+nSx2BdYLLPDEdK4AmlOvZ0dV9Y/0hZ3jbDPhUMAkM44pFZbaNS7u66gC0lsSWW/o0bAVl+HO/HC
#CFEzKN4JlOML1HSk5EfUkgOILqk7BRWdcDEDH0o6YoqzfvRZGGYHYTugDz0c5uCxVbfbZyFZV65jYfr64csXuIbbULy2o4lsaiNB
#4QTz0lOS4+i5uLvLPg3HAcG9E6o/7A139NTEg3OaEozPabEOMd6kINQ0pHs23dC6COkII7o0I+lO5mNbol8GALOt32qK7Zu4Nlnb
#sC5RNXyBB7JMiozBnYSGDUJD7/ueTqJDdaGcchrcyKGBS607PU5obo3zKkr7OpxH40jXtg9/Lh3u7ko7ri2q/Mj1vvHKzZMSOYbW
#oKA3SYSROX9F3ouMqsXH0YciOtIn1FdtwTv2Ob88lJLbtSysxobhwm6wTkXP2ffSAGBzfM7T4uE3epiUBQhsrm7iZ/S6oiznrvSS
#OVw7o5tGlL0tiPd3d4AW7/+y4dYmlDBSPmr4E9qvKMz3zwF/RcF+WNF9Sf5SQch7ltRzuQvWWa+s9VfvbG0rj0kfv5YLNUjRP6Ev
#p3pkDpQM2ySzmaq2F9j9jsOEsqRp1ujDqJmPzUnlBIOfzUPz2JdP1BPUzaosRRQMNb3JauiZYuhMl10mcW+aVTV94R+3CCF6E0hb
#VfI6jXuUH5WX3B6RAdnlZ/6dGEr3jzpfdAL4bzU5fiefQV6E+Rm9jeSyzQy0sD3AywGqUjrSWlKsQMHAjtyi/lJtIvigH9X8EGb0
#lc0JvCe/0lu0tzRXXKxGzjHm/El2OicgjlESE2bUZyEdWvAgo/b39IxYnUuPdSmHAVM4jCpsD+WE4yYeD+bSeB1fDrwWc91i4X05
#erN/c7DeX/dPezfE0RKULuLBTT/qbbx3xCFLsbaLvsB+/eq+3RrMEZZv4l0JtyV2OcZZxssPZN4ON/19Cu0j3xk3H+5WnhVPjs4G
#x/vFCHGzpWUz4PM9Y1pmJMJwNUj7h5tRih3kxU7YSvtLAuW8qQ6uZVeZgLm7obrfNXnaX3ibzDtRQjhN2TTvEDCyKf3n9gCxodx5
#46ELY8z56+aiC6GO7sung+NHj2xqsIyOnRmXzxuNZT6toU+TsKVvB08lml6AhDXnt9HJJHRi+3R3ZzLjtf4a0a0G7Y0/I9879TIp
#jXtGeTfZEJv7tmf56AXcQd6PJmzWJDux3VwITYml0/7phKKgVhQtlapV/H3YRh12y/GcjvYalwdeuaDPP+bzYkSh4YioMV678bx2
#Y7w2HeSwXpjDL3YAqihgIa/Z3SSAysvdMMvbf6J33Dbs82X1g+N+/6CgsaFN/98/5vIP/Ov8/k92/Mfin/7rT//I7z+dPMaff//+
#07/g30P5K/rZp7L4J87x4d9/Ovn045NPt+T/ydHjo3///tO/4t/tfwRB7xeY/94o6OVN1YuooEiuh/UiW1HhK/wNmjIAfG4UfT5r
#G2Qz4HVugqcAj7aKEOm4TKqUap/ZF9e1UcmSe9JDAOw8zei3gUx9Xs7KtqEG35azgB5dVVLM2mSmuNI8c+0UEoLnnNEpQND77/8K
#Ll6dvPj8Tz+8GgYXgAqAnwP6zZyFCk6CrA6SoKmSFPF5tQjKafBjkl8rNKxWpXiXYfB6jmZ11ihqXpRNkExBZoZgPw3WWTOXPkNv
#9mWZqppm/zJZqkDeXO1fSmHXV+WaGMqvrnaa/EqVX5x/J4VjeNYm53ViIUGtKoCqgC4RmPq6XYL6DbW4Xd0H5OsAu4KyIHccJJOq
#rOvgtr7Xfeth8BmC5GAFDxjcju+DZT00QxVlwTO9KE3jIKmUGaqiq6vgwBqcnKvJIqAMDF0sSLBGPjmzJKmkmsxZsvwUjDcBna8H
#ZRUAAnabQZZjlXuN9dSmFfFvmOTc4hx/dPEUrLpmViXXZQXx1F5NpXgdXyV1QM9BnZeNra/LCpCA6i9LYoQwrFPLAqJL2p1SIp16
#eSugYkc/3rapN6Oj+jC4BaC+357Q6MM3VhGkTAYyNXpc02BSrljiF/TXK5ssU1OMrQrFKFKvOlOmFk/D4ArhF7SaL4fQz7eRgmF/
#12WugvCvfcvPLp8DvlZ273QGmKvNm47eBHx3VdU0LOXIM8qPOT2b5JA0U0IPptrUquWq4cW9Bk16PGw9LiblZVo5rjT7xw68Tqpl
#y0J6I09Gh4gckR096FLaRZ7ydeSWqibJ8q3aQEp1o9QX7pUv1PSBqqSsxqJzqer2d91N+YKKnps3MZ+2D3+tjh70V5dNGhGrmLfX
#qqogqbqx1HD1w2L6AIgXRx8Cwdq5AZcQKtUc3BYwEPRiZrqWqV4H13Xw2pbmZS0mih66XJpn9NVcVa6lhX5yVUaTJ6KyAOOTpqu6
#3Ewr4VQroVfjjI1+4iq2GqmatrU4gmf60VXOS8qOiJ3Qj64S2lNXyYRrz/EcfE8vrn7WFjMyD2TkW/pZxKVfmy5lSsQJS6dwXPUb
#9/m5XI4zFXxeT5KV37FuqylLhP664vG8ZHX6jP664sVvrCc/+3SvueH5myu/MGN6zvHHFSLI4V3dFl5hia3F+viSH7giGcPzel5o
#24kaT4HoNaCIf8MGju+t+QNgp6fai7E7FuebZ3C3tA/J+ZLU2yJrNoFzdXBXr2DA53CW0IiNdW/OL0XBhL0RWQV2alAcftFnFORx
#Ii4kU0G2Dl4umCDsXpBzV4E+4w0omUu+fgVVCCoFx1HPAwojKWdKvw2wiYK6DDZlGyT5GkvEdJg3MTaqmScNr2rStNSaHjKLDHLH
#Qg2UBD0kWHaqnoyrp5Q1Y8J9U59bxsG4Ug5hXVYpr6YoA8FNgEkwgcGXCtCE1jagWJxHDeyQWTEgfQWrQCMzaLNi0w8xOwrrYzEV
#7HCI2xBK2VZdn8bNmKJztCC1ibgt2DwMfgJz/gIwHRQK8AjmeazMpobHsQOcaJNERDypV0kBeWBt8Z97iz/3nu7NVMNMOaSqp8Qq
#otvrnW65B/psLoO70Rz9wwDtsX2hp8yHiFRlE/AFKPi2hoVoqfF9aWDmtpN9LKR+TkovakWMJbZ5TZgeWntOvAW9G2JbuS4Ci4GF
#Ni5npadgq60j/luzSLTPtHRZ5/MTdfKJotUJxSmLVC8Vxtq0GDcPITn1w0bR/uNCP/PAw6GTDboITHjFT173cmEnTSYTtSKRBm9U
#jn0LFgss2DONp5lgyXNhGNR2QVtsonit6maVYX8BSxPhj4NlVrSAcKJAk4R+wk9jk6YsLW3wYMOsuE7yTCtA0sjoWV181ARcQRhz
#DtwnM4BAVjIjVgN1tN7wdiDDlQR0FwubpzNXoRqjaFBElWOyNk85CBiTiUjAUJoBNi+ZJRaHSOeKjgOpd1mK6UqahjAMFvkmyWiv
#yqJlO+4cIi8ni84Q66okA2cHsjPTuoDxa1+p/wba81hgZa9qOrmxOqffA1WkNIKxWzKj3mvEN1Yh7ZKHc5XnJUMw0QwOE6IOapzT
#J6MdFfN2h6HL6jsiBPpKmSI9t3H8qmG74pX+wEf8tfZCjzESTE9qm/JOc2vjN13FXoXHeEM7m228LtMt9Oa03c27qdaA6dsyST3A
#NAc8bjLD0I8wMukOh0zGcrmg6iuaGf5jDYl8ZAK4kRvIWOG/I0DrrAs+tGRUAWu+IwIBYyaaesC6kUF18yGYoAk3JeRAhU3yFNyu
#56qwQs2KLs6mhZqLAabNboReD+WciAAJA/taqcJUsX+TQB818maqEunENaVjq6knT8gbiDyiL1CpMmqog2Q47a6rq32xX/oS1wRb
#0oTqDm2ugZmGMwn4j9V8+rCHiJHhlwgUojR1LjRH+UY1pnwt25Vw+hvHMOEKFX5rCtMqWZtCHUysLP/or+ZPR6Yry8Fmm4MrCVKN
#MtSm1LMhPKp519WriSHt94QumBU8h663wR/BHUzHlTC1UFHYIFq5Vu6la/qFvhhro86a4GK7Yi+tXYzEjEWSB3xgZAfht9owRr/p
#OrrF5+wFXoIQNrZvqtc8m3X9+lUwpA/7h4s0YaAeHAbP8P+5HUDY9MZwZ2kl921p8jtLK7hn9NdQJhFbWXnhW1mZ2t1h5bITVi47
#YeVyyBRaytIlY4RnydKFRcPltcS0P15ZMozheDWxJo/ORae8iJAeNLeaIeky6QqDQ6PXDX0wYJi/ZNdSmpo5uG6q5n5FmmxMeUoo
#3KvaKPi4SjdwL1zbDpe629IUzKVkfj+HYXTFOdkrVMgP2x/rcgXpCBJ/Ba8GKcMTrym+EKe8nmeAltSEfo/bpBEk16QhF33urzNv
#fjR/sh3O0y0esVqTBaMIXd6uzG78YeX2jIRXEw3d6b6UQqRBntKLoraariRYB+TOJsHj68fBGAFpoMNlNqQcugzStmFgXwOzIti7
#zCqKjQiwfF1MVVWUkTjuelmWhAZQscJezeg+Kdw9KeKwM7UG/m+wWgCandSdCHVfkPE4uT6xm5p+SWpJJproGQbnwawsU+xpCAAG
#i102o/x5cq04xJtWGYALEzXNYATQyMDMzoQa4VPMvZOgj4WgVzlZgJRAfZUsV0IQ9WH+1C38HWDn86ypW8DI4MrkYacaj9SLDMTn
#eMESlJLQi2KRFcH3bEKZ4mvl5VH19J8IeS6bsJPIT4bWqZLlY7uKuB84FfAWIgPNxQLWiaNA9pQnnxx+CpFvjUrM1AAIbnuVrM0v
#5zX5ligfC13fqyZZKC16vZBdBD4WAl9XhB1J3TilXnFvhEFtw1fdAvJ77UoCIqI/bVWu4zrg7TygiHeZPJDhH4SYHXkV22ClhXxN
#W0Ni4imHpYLHcjowp1xCAsQ24bhWpu2kHUrJHsgCNQmcgfwf9t4FMM6rOhD+ZkYaSSO/JDt2XsRfJjiZsUej0cOyLVtOZFm2lciS
#kOQ8kMUwmhlJE83L3zcjyzGiCVAehZZHoX8LtBugpaVLW9hloVC6BRa2sEuf0JZ2ISWl3ZZt2S20W8q2G/Y87v2++z1mJIeEdv+t
#En9z389zzzn33HPPtTb3ilgfSrWXoJK2jxe8KjuwNup0PVAnSfLSNV3BGFgobGIo0RIGim01nlEoZffzysbCxS4+J8QElWq+bHrP
#QHD3Y++GqYwBap+RX7Z2vCQTvlefQU5OfzkOGMERTTptKzgZbjTcMjy14EEG0QLvuTAPrB3sGKJNHPsKig+ZJ8AmU/k2DlnOXPE9
#DbEOSzBBX/KKnIZcRZ/wTsS9atqMa7gqLPeQe5CMkLXwCF6lBZypl2G1eMYRk8mu43haO9lM0cRjs+o1OZbq6CRoWigmh5gBtccs
#GbzYqNFQx9D1cn0tfy2uDHuhpgxNv6vnwO7kLLm+XN0I0QRnNmTdqxZBAzIt24TkC5BVuc7d4/lRgBLQHIImMjz5DCBDmH6CZJpC
#FvUaOL/Kvg7FrmKwihXMANuDfDkBnB1sG6/i7h0DhZwNx8+s4pkbY3sb5vUMBRbxQpoyBgM8Bg/hvj5XwQMIQUOxgTy9/qAwwD2X
#JBe7ZMkckdaaOs4M7yjV7XNd7DnlRCWp+LqJXGh9qQert9KggLFSRYoAREIfGqTGwfbYzJNgMUMd4x2dkV/Be3s4FIKgAmVbytPN
#HMpmKp0elJ0uIGBC9SvWuSON4AQtonvVDBkXr5DQBUlOwCJnLJ7QkSImdIXwECmtl0XRkuQ5kG4C4Bj1OxEs0JQptcm7V03ql0zG
#GoRoxQmQDshaIGeSCQPkECtPdB1DAffS9gmY7bIK+kd5BM4i2JPkEdddNotrlArJ55U5M+9VM2Z4s5Gwa0URcH0JcEJSn+e8ljTP
#JazTgdUHvhvlwk6RrkMKO8zC1mYiKBKJOSWMlbJYpyu4iwa2S+nuEHd3jObWRH6ndE2XRyMq23evmod6+ggK2RiPUyNQ7UHZOBPK
#S+rWmSpNGdZgSzXlssY2yzXK89d44kqi8Xh0n8kJnn8UHSxY41hjDbWqiPWdhV9bngkRG0S+r2frxiZsoa7jJG/qD89Y8aXMBm/S
#N4jTkbteWR5t4eyIbBKFUhiBBtxlmL3/RuZNQDDs+GQ8CSWktAE9jr1yFvZ5tMHqPSsDrhZzYoMHbcY9He4ArW1c1toYAl0xMQpX
#GjpGgS+3zumySakYQVRZ0ZHIork4wNDMhpFLFix2EA8U7N5h2HqFZZIYjsPbC9seGZ/xzZWBkSrzQJXtsFKdy7lYr+Xt0JUMbXPO
#Z1bssHpZ5L9EDiVclnGJXUqMKOcSOUQ47MUqLAJcRsRfreOWv2RpokCCBlXVG1ZVb1AVD2pSGVaH8NJKULXYOIR74E5NVBchqDZt
#tMGJhWwucxWYGR113/UBi6cUKWg5IuJG04wVQMQFQkWomYKPrAF3aqE8aALK8jO840OHtXvEqBXY+JDA7zw6CI4FQ5VTNvSYMrNU
#52PZUXAgX0zYCFKvVwpZJZ11LmhvfVF72DUgfD4ghszMM+7FbtGSN63Gr6/x4AooxKGVDLAUndyrpK1asjPS5cZjQ4TjpDKEV1cr
#jKksebKo+Wqe9xklFDtUCe1RreX8htW6MpHtCaTKdMKG2xE6TKTCcQ74GgKzgoDuUIZr5ImxBAJTKCrtRlG5o6PUZBo5dFC5tAjt
#FDxqD0Ig949OFFz0Ib8BjUGwWuXdBfVfKQP9UhBlUCxQSFMnAmidu/FgYget4zNKyUFcqegzZhadVjMLiTC1lQ4BTOJ13Q1JAu7n
#TmPKnBvRQDJYn2UGKJqNdbVA51rDASqzMjPBqb5mZcCJ4csiDRojTgqErIik35uUFSYYD0t0klSJ9FKdmPgI6bbgG9c2Aze5JGLO
#GyRBmoFfIGM2MkK5lCKjiplxGYNSLSsKPUpcSchThTDMQolNFnvGZw0v5Vcz6wUpDqQ0HoygxFlre7YOew7IWHT0HRje5YJRchAH
#1xzJJDalaJBAJRsNktg0xJUgJwTgZ+1Duoy9G/TwEhnriEnynmIviW46wkepCG45+Jwa5s/msShzEnU9sYRxFN8Q0huWfFVCFpUQ
#2JvLN68Bz15CwQlMbNaWUSSVoxuHnlGmoQpRRiBV00apVgxXwxFcE3DR5YIlAc7gkQmNCkrxSKpSWZFR7kMGK3x52YoQThFjMWzs
#EKGKoB5tYuNqlAoUDulIJokiMxuFW/pchEV5/VpJGx1yCX7SSoeUFReffR6HvgKdNJh2Ydwd+pXD3VQ3kbb5E2eHBpXkCteHpgX5
#3EaNLws9IFQX1Ed7XmzH+cvhMUZlc9WmufhLO0rRzJRAvKycY1BtQplpBkW0CsL71Ef06zXXmR9AV5I5CuJ+2GXFENmQiIjB0MJS
#GO+PDjFm6ZoNrrCulq7ZUSjnsGQLVcd4GNbivohquEB7VmE1FeVJEyUomDi9hACE04pTxkasmaQdKUtCwQg7ccJV1KIUz+nOSo83
#pZnMVokEjs1cssMM1mK+CATTuGYHQ6Frorw1O9RCt3RUDDsrw+LIqHxUp5RjTx6cQJSP6deLSjvkWUQfbBeOwr8+S4fCTmNeZS3E
#OfjVr9dp41RTyuBzWD5L0K/nlBhb95RUmFUJJkaXK7AlycoxFzQYt50YjDwW8g9O+CwmcavEYgobsDGUdQVWK2oYE7vRrE2IMNxm
#A9jOhh1jgwAzp3RMGNn8p1ar/7/mz3v/QyrYm8/ZNZDm9z/wCsig+/3vgWNH/+X+x/fj77oe5cU5Xl4pwsY6qm9G/qnb9C9/378/
#sf6Zb6tee17qaLr++/tSx4Y89/8Ghv7l/tf35e+uO3vrptG7VMCLf+t6FbY7lfJAJBolde38Rt1ESQrvr4alkIBF08AjWcrFpGrL
#2q3qPskWk0sV10hkrgbcGB6vFQtLRsa4xqLi2AzVrA8kjx+JJ/X5qxWSJ6P9QnMYiP1hIZnXdT1m5mu4EzaTyPIl9Avz8zPIw+Pv
#XFwfdoh/jugA4IXew1REoUzGWop6rK//WDIF//UNW4XJyDSWisVQxmqxDn3tPYwHO8QWYuE0LpOF8prO0XoMpdIsVx+dmaCzOhzC
#SKFEErGVxwrVBOqmrkKfwVHKZOFbq1UFu4WHQNm1fA11go16Fn4fJTlgCdgzPEGA0azAvyv1fD2P+84EHkcZ+ZrJxw+ZoizAKu5K
#ETo/AA4T466RXAuYdzycSdCpVkKvG0VoTVKYToyQGC5rvY1n6qLtOYznWGpxtlJZQ4VrET1XQJssYxTIqUS5ZKVBpoIw8if4ge70
#FTMSGZ2ZSZ+dmNVHoG9kjAMvoSPPHZP+zJKJv7F0GiXf6XQ8HpmbH52fGHPlQ3lcTBSX0KPMzETjkbOj86N2UgDvglEhwyCxKF1E
#SM+MTo1PpjFZFPL1Vqq13qzZ30PA3pvL1DJQyNz4/PzE1Pm59LmJyXF3pbIGrFXCEU4dVn5mqxxUTTK3BIkjZ8fPjV6anJ+D5Hgj
#E5hbId4/njqegrSwPonpTxHUprC5DniFuP5jR1OYFKA2DQCIqYlNhrJyFbRCxCF6tFY009k8i+mk38oAXgNQYhr4+Q0MOpcpwrRx
#MWJpp8WRROORoGQ94iiNx0MUgRoz8rapa7wxiupXzvlpoUWt6mmXn5aCtGP92F1EPelaDdXlB6j/dLc07RgFPYqnqhVrBCpXyyxp
#WIgeGzo61Nd34vixoeN9x4/1DR6LLkKCMizqDav3wp+GxWSPyGYkMjZ9djw9OjlzYfTM+DzMXHT0zBhM5PkL9z8weXFq5kWzc/OX
#Hnzo4Ude3D8weHTo2PETUYDf8dGL6dmHIbWRJ4NGMJYxI/qSy7nrfcc2XwiwMDV6cTw9Njk+OuVOtHB5I5XqubzRt3x549jyIqSd
#nHhwPH1udnzuAqTtP6pbf3dJFWg6l6zU8eTELMMIr5IGu9AMshSuYddv4u5biIIiF0cfTp+ZPvsIlNqXBiKN/wBzgzdXyNZiEloR
#yiEMNVMR3ienxx4Ar4VpkrOTgJVi3EyE7E3d9XeXaEK6kNN7TtstxFr02BE9mq6ZspsNS58dnW9UeqGKxRIKQ6EIHefXUIWLMnmL
#FCWmJaRnUc8fy46WhAIeQhhhBgCeRYCBSC6/jPQwVjJX4sMEqIBuk2Yth2r8V/EoNRY9ZOqHzMvlqH5Ij7H2cc1YRgdEndMPzcPy
#0DF/3J1/uYiWM+JWNZlcWuKZmKhtpVhZAoo2Rx6fGcLgmnGNE+MfHVSjTCbmQG24SGBt5MuwoNBERrReW+45Ho0jWCzbuamWJOs1
#xK6vDevrpNGzlgAHEEJc7CShiC3HkwV81CcW1wvLOt0Wlo3a5FblN/AmiX4OgBt27+dQaDCOFxXtynBcnYiVZIckXwAChqY8dPFy
#F4KJUug4/ZC2iKnnXSVaBzmZnO4ofRimCScpz2XNLTAWXoRRBWwbs/zxkxjnRMBKIlcETt9des9z+acjCKL6SGRu7ML4xVFEPsBu
#jM2O41qYHz0DhGfinD41Pa+PPzwxB3QF2BfDjBFu1OfHH57XZ2YnLo7OPqI/MP5IgsWgFIxZpi5NTsrJ0u+5J8GSzzSde09MzY+f
#H5+10jFuRn3vNHOFIkECz9zW3WGUTi3HCiJEJALjJ5v1BBG+GSNNCW9HlA5aLbR7l1DQjdUAfi4y5+0Zs3zuYGtgUnYzJ6bOjj/s
#18w0t2d6SrSavM27J6icGatV1vJA7IBp3G4/G/dEXrryxgCGxFKa90W2ye6O1cpt9Ag3Amkrgz30ao/00Uvz0xNTUMrF8an5Bv3z
#TJ4SJ66leCPwpM8LWH69rCr9c7aZgpX6tyyHVPu8xcj83Kqt4IASI+wqOf3GzgHgtJxQt1LxqguueaVil7bdSWoyH3UIdU2f3Spx
#2m2vQbpm1gC30FWDdM1OzAFZJeRqAQ+VbT9f5rD9l6YmXnRpXB1/aF58G0ORFmcnMfb59nQrlEPRVlPWSOPH8uZY8cfyZ1j/xwqg
#EWDdDTtRab1quobDgXZRASOdqaVRB94KV+bR6o1ofLw5PJeq9rpwjso2Fr84l3kOIIpLgml2DbUMT6tjTqcE7pQcqqSj0eUzre3j
#UtYtaEQtceXfk5DHWOmla6JFMiCzTWQEvUqLXsCwy1EUdrlFG5qPPKo74NH9czH22xxPsbDdU0TD/GyIE0pVnu0cbG9w0qQUEsPv
#Dazuxn1RV5ko1LvIfLmaUu7KczFRqG/qJptWFxLypFBBlTb0I6raqAln4y7itQ0vH+jHFvn1M1PPFWrb7GjNDyYy2VrFaMzNZcTj
#0m40kBC2SVzcjm8T14G5bsIsL+f5up+3bZW1JuOSEOp9GdkE5Nh5Y5dbIo7BtaU7e4Z8FbyLupbPAQ+uSFnyG0An0pW1kXmjLrYr
#tBcXkr+k0JePCTGUMJWRRjXDNO93R4Rwo2AKvZ803VAawd08ywgr9dpI31FZeNKoXE0v0/BfUyqarVyVCfAZZLJLOzM7eh42JY9W
#6rQNQkXvkYdGJ6PxRinNa+XsqlEpV+rmyNT07EWftGbWKFRhe0X7HXtbi8OTXYUa7J6mKkOplGM3OD3HG0tSeItIwQNzZWy84ype
#fSKuja6U1ax7/2atUq2iAqCBlkMquCPIkDJfwSDmSl8ro3o4m8GKWPtrIQ2xN55qpy/NnEXYczCHOmzGmVcd0S+OPhxjfjahj02P
#To7PjY3HYLc+OT42r3B052anL/K+Tq/rD10Ynx3X62xZDcpwFM6hccklx+MiOfPGcwSoYsDdbT0LtUJbqS6rrZxb4u1T+r3RhB7D
#zS8JN0iwEY8n4luXSLsiUZzEOA2K03v040ODqRQWy6sGBl6uGPmSniuPSIhGp8pEpmLrQFRGhgad2WyJG2p/xVBEiBag1/FQAV/i
#pmdHqrH4wnB5URRZq6SxMiguNwIru1gZ6elLHT58Agh9YYRcogqC0XUhG1h3QGUM7VMQYCZ0ekWD3PFh2ayc2sZSZiNWrBACj60W
#Evq6MgxGCTn+WElUidOP7S+J9svmJ1HlzYjFrafGo5cvk9xbTD3mK8nniCFwoadvUW2CQbfmUQ75kkzPY6meE+nLPYtYAPwrweAM
#DS4+D5IOqQhGtwtiKFCr5cvyIIavZOWNOI0EnRKI9BIyqtCpuQWn6HrRKxQr1RRBPdAMEvfFqjYEF5YxzZ0julM2uCAEg4tOCZkt
#Y6vegFyNeH1ohypEcyRw102CSBQ8LWyQFG4DpWw5bGvB5LubMMsbCRIJ8uUxNZxPQgo5lD4CdMYXm9Yl+okwUvOVtNl9sbCsABz/
#ZkuhZmE9nyaLSzETNmXDNg61pL52yTg6GExNx+Tq/EjjSIAVAFnkFkh4vKif4iwsJncOuN9CI2E2N03Zgittw4E2caD9wE00xbTH
#Vh8ZQQsCrCXKwaQ3GPdtCq5bc4FTLHLvsM+uQYo4epzzL1V2TpbWhDgZUIWKogWpIcZeYH5bGCHQtcV7jRC6hmYBZk4SbwQjGIur
#YxozZCOw1XyByA4ia+TSzt6hHApgqZORyMzE2fTF0RmvcP8ueRosNfX5+IBoH7hjgoWLUwmNpPyj/XO+xwbuU4nr0RodTFFzE3SG
#hT+WWiWGbEQ37Zu8eCSOZlyAL7hSJ7NosHnD6ho2ZQ64Xt8zDFdThO3DAmnm5cvS/EsMYZJtBFC3rCOhvqMRPju1DjI2I2kYOuVg
#g/SMU0k6ZKzk8MBsic7IVh5jpzzjqBZy6cqy2PLbuBXPspPl/FXgTxgM5cFbnKhPmQ7w4klCfwAVYjei+MWpeNJczfQfHYonV/Mb
#ucIKPuUNJKVvSAFbOZc23Ar4WKguEsmDglWoq4qWZ/rNNM1DjPUFJGubSh4THQFOfNRcs6/cSlXlmpkvLuuxOda0pjIS+qWzM3G6
#tAmkfonefqFLMagULTOaNbwvrByr8c1HZPi5fVegvUvRyxvLy+q/eVHROB435vUXYX145Me5TOwjnfIn+ScmfKPn0hNT4/NSByA5
#B2OUPnt+dvSiOE9K0iEHdTomfn3OhTBZOVerxKB5sKCjlooEQAOpRMQdaNgENiK7HusblLy2wElFIHq5uH56RD/B2GlhcPjoImLB
#peho1In01Cr1I5D06PCJxS3q3mb9p/QhBEBR+51Y+0TUF+USwrcKgJKHLB+emwJxtQkjrrM0vWKOLxTFBl1I/FE8fuN3AWI4vSk8
#qC842442CTJVvCgbyy0Uhh/Fp2RpLQjGgA6riT8DzvMkNehRGJs+pYlHRvR+RA1QDGA7m+zKiwklIPlLlRoCDFQBAwpfLMJy9S+6
#qcT1qFBmh+bhuxOM5diL+aL2bQXkRFPWNQigtFhVXGBBiN7Y3II9cI87GecpOiCRdlrWuScuYHxRSRJZoapSFmYek8t1KNBWSZkn
#7DpTqRTHiaBVDNEgGA9vXAyanUYbddCZkeM8V2zRBXfWdqMcawX/iiYBh9mIIXCxYYL205GgL8NFxST47fTHgF+H8nGbTy9nFDOl
#pVxG3xhWkNmGdRqZwLbE415mEomtN5TmYCFKzNEI80u+aQjpSqo1jK4FYE2Ap1nEfIa38dhyaIm8K5NmtBcTmexKtjijpcHFc1ro
#q+tEliaCDtCL+XwV1p8CIb48pNV8B+6CUCcHKXklXzZScpE2YSWOxcsoyv5aTYCuAeIBYIu5GDhETc42WzwdnkITO4BYWxxuE3fF
#TRI7SGiATFaFhUHx2CBHdyplSbuJWXLzqkCOplH1zrpqQ/fRjTxwEkl9XKFn4johTlO9qsfWCxkilTZvE7dIG+CLBLMmiDfRWRPQ
#tSXbjEwyoHUGlpNUCD6+4mTzfZjhkzpSU+doqgQBj/rlnNb0Ky5VhkZDKP/Q6n2hXLcpxJZzg3/VopNuIFgNexZMFYfDpAszQAss
#FAvDBgzUiL3mYz2w1ungCOM2JOMs9/NxYJQGjy96F3q1KCnN9WiVDGcKJq66wFpShDsk5q/KclEHi83zQxAngyCun8KspkT5+IpD
#hZuIBZu9gkByLW7aI6OQv+tRahONn2wE7X/U/QyulBiZ9ry+GfdEXGkQ4d1NJHxRnNSycyHnqDDZrbSGQuJCotKgMCaZrtZioF9j
#rXDT5Zdae962WiSYeBwFYOKMtwgtuaqxdympxs3e8Gv2RoNmb7iavSGroOBUg0rEKS5UBA2XnkWl3aS6J0521VRZdzL/8gvltDRB
#SQhXbI0X7AiCdcsIpTORCKYkRgXNryD4FhvUJay0oURPjIK0NcNjMDSI5QDpJyvijDAEuZGYQlVJRCgTmycRJuFMrBtcM4gmYk60
#sKHSVYny6zUnzsc9nYLwx8hwrX7/3PSUHjuCeslxyyKT2FIrD00MsxUctJ4MnBKSATK2mdeX6oViTrGLY+F/ZIkUCawkajWgpPa+
#U5DU03pfMmVjLbpLKoRfuXqpagKCsO+EukmYoig6tyCchLkwMY3xJlKfasZA+4jmSCyaQNZ6GMW5cvNpVW03TWq21cyRWoKaNIKf
#hL7y2AiOFmljojGBGAcfjTuG3y7oeZCE4tVRU4/h+IsTIgxRrK/z4KBC5NQD6fmJ8VmUbyzE+hJ4MTNr1AuE3GIDCbQmUljnR3H1
#2JDt19maKdkHpLgTCTQWRG+iFCmgrz9B2HUlnylzcX1HE2TjYHlZV8JdKyfWdzyBlzxxaemO7P19SoH6xcyjFYPDBxNk1M7A4Onl
#5UI2LyKOJdAYSL5ey5dlIQOIPcYy1RqqOXsrHxigymXRA0PUq2IF74xTAHbzjFFYyeQK0L7zeOtA9HcQS7YCFnlsL46iAu9gin1j
#ly7iOEPC1KKs8i5dRi1MIrf88Iw8zK5V2Hy0sAc4GaE9ZdHeVMIAW5XApk2sXVmcJJ5W8T19i5DsaCoF32NH9cN6DArrgXySN0Yg
#SRfKy5XYRlUUtoGSG7GPQywGfkTdApaL68i99Ck7IQw5ZbcKkSZkgS2+1QpMgTtMRdMSQ2QxJEmEMSoTtBYBC2J/FTjFjTvy2JBr
#0Tp3wEAoRdYDVXs2kdejNIxIE9eLNhuBP+Aj00EbKILPkkVRaHSPo82k652ny784z2yiti+V4i0sZGIdBGi6X1ZP791JIs+6pVS1
#bBr+WK3DA6ATAK+QAiYb2qr39lKK+CbhHIA0tN1fJqO3inHcYVY9OjwILRVaRof7wc1vuACqK9cBuVyFaTkKRepoexY1ynthK2aa
#Oi5yuqeDwm2SbtXYxC4bNgGIRBXmzAYsihRd0kjPvWgShs2SJZeqSaFFNzZ9aWo+djiulxP63KWLMYihlsVRiVgEMC8Z13NWiGhy
#XM/ASDjWdxRTXJyYiuHhoC5Lo37a+airY6Nz4yi9nsIIp57USEqfx4iUiE+ySpkMhoFwhkMBrB2AoTBg45NQdN9RfXzqbDzOE+lt
#pFK/KOfU6ZQ+OnW2Qbl9XGyKStWv8lh4C5GNdCbPGe4mkCTfocAF46DfPz0xZVlaZR2vZCGHDbF03s7PTl+a0c88Yk1iFFXkySCa
#S4IsNOOvb25G0uMXZ+YfSSMsUKqyWGNrUole/GbEL60AdFyVCXAdpKT4mapLZ4pFycwUllVGA/kLSmLxFgMKa+F/6kGLs3LVdB5+
#SOAVZxlUo80oiDqsg7frhrWVgm6vMVNoLKwtMkJl3XjEdbA7iVLvqevUb+409Zi7G9+k9CQBwoZteuoVMhs3h2Wds6mtUwYuvYTG
#XxyyexJeKYPKDColwKYrs+dEYsJ+hU1UzNoCdoNYZzKDxs+yYvAaNLZXR1cOebP+OGMP8jI3v0yv+Iq0Lrpt7ThFtLrdtMqMivUt
#wjJRFl1K0+0YVqawq2xhBwOuclmA4KyiDApCTJdXRJwiN8CWyCZcmDwuARNtbaZRJOEYXuCHVXVTcUzF57B4EcW28sQPz1gGp/AN
#cGnMPyF2dKyRQ7IJi9FudEJKYhZSOitnSL5Ax6XiJoYT9gvLlpQLE8vz0tPqcalX/iErYeEF5bP2ob4SSFvYQEeh6LRUHKilVffx
#a0KVrQkTeOlq5hodiQsqQhZp0uuF/FXWY1KFfp6VXvc/3zysqtCIU00sXZxoUkXeM01r6Gp6fdj3EAH2RKZ/jYTApUYPat8k7o33
#CKUc3eTmONWCPM2iKbN0CpXGwTBHGe3wAsehTUMz3ABqHSp7MAPHWJd7nDIjqUIkGZe6Ii6y74dwhOKndZVxxNpeebAg7lbRhhrG
#zsPARy3TRXJLmPYRHblO6zcJ2xRytrR209qP2tDDkgYJn8ohYmY9jaZG1aGx1AWe+70d28nTY3Qnic43aI/AfbrH1FmeNcamg02S
#oZrxyOjkZPrc5Oj5OeK0DIP1b5Ebw38s1OAw4a5mANhVt75WLiznCWXrK5kVnewi6mitS2fjiWx1bSmDBu/wa+KtbvhULSPhaCsO
#PMTii9cJ0Jocqus4GRA0I5XL4n0W+qyQxbJVfRnFA6tor9asZ/DUFJiSXAn43A0yA46mxaWxcF00HW8SXMUPIGqh64+PPT6Wp5Px
#pQq+rgGtNrJ0tgANluq+PM7ZUg4cOXKLka+imhRpPgFrA0ENGBuCIoGY0jhXaRRXxFBrSNH3cvIdrAaEr6g31QSS0OVR/tneQZo4
#ByG4NrOZssImYX8slkWY36LHROj5IScPRUn5wAPYWU9ValEsmqKbtLhwiH0wYhtxWxNJSrXEdVtiLBZYWCnvwTKTKXLK+4/GOmsq
#WPSs2bFBdnmFToOpJvBEPVgaU0Ap9P6OfR4HoaTmF/ehcSW7fvIC9EGIMuGOq89UUtS5QtkWqLj7HHdQZzIDHKMynSeEGJQguVuc
#cRaMlYdiK+nzqmJXngdgvJxZIvNZdHrJUT5jLVJP5GAHVKhdIyW+uN8J4nJRmdtlnttl6oAo4lwxs+KcWpES0ljoyXu+WFqgZizY
#TViMEz8dXaYCh6FmvOOOpxBC11K2WbwUiNKZFP2P6pZDcXu6zOyWk8VmG0h3xzlv3hDPHLqOdbNiFrzHOxUaJzPL7Z7GRcBm5nL2
#gPlyTD4TVoHJEYuND8U4zO6zsa4ezjIJcyx8HFvr3js7UEht4OOa8N1Ucmyxy1BxgIp2xHbAwQQTnlmm1WeUALsLVvGkTsbQruJz
#IaJZ0USUzC4mbKHvdaDewwpImHj1hWECAGJzc9PihnF5qrjPxk2SptNTDwtyBBh5ydPN7SMbxxmlChFUrmUkcgHSOaEZl5C9HGQv
#CHJtwM0XafnYrcXZWbSPDq5vxj1VyFTkX6DMlvAMMZ5I7mVUcbBR55UGCY+jy9dizlaiPG59QXRhkQaH7njL5znXUWfZjDkl4HI2
#BYzReQoZ08Qf2ziExa+ZkpyKy0QFsby5xyo0+c6xa8Dk9FrdpRFmMqoMlmNIlZ2v2hHATYUSHz2JhwvtoeCTKNHwgikgJU2t22bD
#LX1Pb+NxNuh4aovm2l7RsPjzcdM8K3lOsj6jx3J53EsYLMlmY8lkAsd6X8Iy4pApm1elajZlTgPjxf2oXauKMRoh7XG+lYSa9Hwf
#iULxNhI4mu7s1D3WxNTc+Ow83sCZ5utU9gYcr0UleNBEXQmuKIGVJMTVg7j+4OjkpfG52L0J5b+4VG9VWs1ic1FUXLaam7ww3D+I
#GlR80Be3wHuN+m8q6iE1h/pNA9Vcj4BK7iW37Ja4YgEj4VXZJakj3eQaYQmkGILT9+rTs2fHZ1HaB7hucuLixLzen7KHAI8W+lNx
#X+kYqhtBc500zefiCzUJ77twA/pE8+galx47ZMbx0B4IAVNsJHWGOOp0yse2c8HE7r3o4SnaRWM/Bob4NomyHBeA6YcxRXS1wK5F
#aVGGw0xLH0La3KRg6Vmkc11hIxXChZtVKjZqolx0LbpkfRYppftxdMsqwftbvtEmL7PJe2zPdmFw+TUzwVXYS0RUI2rhSvwWRFwR
#QmzdTFgMqdSifRNnNcP3RWNl5xUc5W7J5at68nLP5YXLi7H4XffdeUReMUE4KMsrOQvDA/2L8mILBQrDsqIitI2RrhvFmNyX0eMz
#I7rYkQiDSKzggA+XZnJI0SgOnwSPEie7KlTTxXk87CkzRSwnqpaotHy058V8MSY5bN+MwWTQ3OMpJstoQ8uUWmF4ci2NMS0yr75g
#mWNajFuEQLTatkIUFy33bOdcfXm451zFgE1zLp/rmTEqtQrfR4hSK6JOHX0OHO7tjVLfqZ3cf3RjeFw/Qt15Ps62FVvaZOKdbi5H
#Zsdnpmfn07Pjo3PTU6StH/UxiK5Ht373AJ8Da/7igR51vYG+GXlwen48PT+PB1l9x1PsnRofPzt+FkIGLAE72puqLKerhVysqi5K
#S2FdjrHQVxck3IhVJTjLe6CVtDS6zFQGlQykwB4XGZ2i+gr0JLuHHLPNiq0pNqzyeLssylaz1Ue61TdgatKQMj60QQsqGWX+tCYv
#Fjq6i+0TekZ410UCFF0p5ktodgqBC6Vui2y1SC1ex3VO+JZdGeN3qTLyDQ6rsUSrqo7BqonTDTw44s54pOvqSIo0CEfI9d85sq2x
#pYepbWk+FlQpq68byybarfAIxZvNm2W6iCYJy8UrCkqhFAt0Ll1ZwyGvDkdh0QpoGoL/U6n4tirip6iwFn6BrqIvZ/B9Ose70xl9
#OX/Vflpxc9tcDTTUh6PpY5otcQGTbWneweJZkLwID5sBGOEL/042xpbgi3EWvMvxVMohNfe9EiAGBkUoiDhW2Hgeeu3NmjCi5sua
#8RH32Ym5+Ykp8MouxPWsXw9vpEtN+7IQzSq70kYcgLQlYZN+2b6Ew5SGZAUUKw+Su9yKX/ZTm1P2RYjH7NMDq0uKAqrFTwuUQnrU
#PODyKgSAkAg5pauIGTatiojUte+ImvgmrNhZHDLFayeWzXr9kPVSBD+KIsTy9LDoEmo146Pey/ioOtlys9kZu/HAFpU9W+I1C3wY
#0ZNpCJzqvHe7uJ31s970QMuy/NGA7/fCmLjK7eL+z47PjYktQJ+9A2h6IrbufyJWbrZODlvrwmmVQ7RemNHg06913ggkmsB9Ce9O
#+VbXt51axAhZ522yRp8TN5X7ck44nU5ZOaNiCTnO0yBWWLWno3NllXFWNQDLoMaiMpDQC8qLKoR70XV4LmaU00iPLCfHekSI3Apm
#2jKurzTJokoWxK6l6SBJ5UyAuf0+Myd8viVegbpxzuT/93zBuut9Jjd34CurEgOwZT3ifTNR1RK/IdWDKwnx4WZTtYTVeilTxn0P
#qq5jPMsrFRV22USR8pQ+sHWDalAc2uCwnwNDtkUoWuL22gkpImKEdOgUmpGQlaLapGxHAxS9ZZusF6oyRTyCuGa9kuF+I8efZVtf
#Uzm2/hvg2KRRNeTVWG0bMYbKsRWhEuNG2DTUMRxpyEjYBqYUQZuXZxA2oSTTkBDIKMGzsaXMzYc7kEHIBh3R5SZNmotqIBXya7nT
#+pOQpPkyN9QgGI4kKi8YlasKLyN5lGashoAKwGB0Cn0IWQpTefSN33WzHxMFZHHI7JXvLPs+XlcwWKtWPs6Zy5irSxV6w/MQ76HV
#1dCUX1GEJa5BZGmRNH9I3ZJj18Pv2/nN0JbcDw/893mTS9fbbFLiICGOtbBOhzzi1NGmI2woA88b+cjxxHPHoNl8x/Y5NeJNCAxv
#hCtrTJ8AMxGMImCSOUY5OBIf+jAHN0yaJM1D0wg4AGodPot1elafOD81PTv+PS3bdZ/F+twypW7bF06GlF9ZRBBDVXaFZVOHlxMN
#+4nLbWhBmbkECc5wjwJBdlMizkIb7obofJme95OnMSpXuq1NlOctSWtXxQ9nul73JDxkoyE3n6vMDqOeKD+Z6cY94i3LhAqVCQ/X
#rNyV3VZfvC9SHsILyDnU2JQ41Y1IPXUmkENXJrnhXhDVEOSTnOxQd4cmKjBU8Xrnc3RW5KbRadu6i2e/2AjrnGIgqyX8z38cBxo3
#AMpcugeWDWuvF/GW7jOhxoKiHLjYCE4VGsxWZ6WB/Hy5Ul9ZVWbZnmTDC6bPkwqgsDo3OjMRGR2bn5ieorN4EnzLZzjFeo2KNzfp
#wWM9aj2BzA5c3OLJTX74GCNkiHCh3Jzf3KQnkDFc+NmxKZtwcWLq0vw4i9+5Frpw1Tc4SNo39EJFKm5XGetLId/KKeJWNc5gq/Qt
#hftNnjn1kfw7BPmuh003HfoqfGLlw4WgIot1Zq9otag8CAZvSf4AZJcKuVweak7og6kByeP4sRc26Dq4jCHBiGVrHoE6t98pUMfH
#MMnY3HLFMnpmKxDY+q/ZmpS4q2AmtOSoEHArUQuQY1FmwXhLGcLnSlZjXiBXoTJInma/2yluoGZq3j2SPWzKNl8dBHEfRYxBA+2p
#RsmFnt3WggPP3h99roq2u42+VGaTkdb5SoIuTSnVWJtBgEB1NzhI62frGuaKlas6vr3KhfefoMKl6Vcf2JPH1wh5Dhix4UPiANyQ
#yJKcECRSEKQMK7X5RC+k5NU4cVLkRAXW+VjDw6OEZ2kLOTHfM6zZatx2R2IOzJmwESNiJ+UcoJmQSOXYvnfxjxfUUzZzKnpSdZhv
#s6p+1hKiXIVXGpBBRT7krFtBcUIrSZxO++poSfnZab5S2pcQ+AG1p5oerzQdJdqGXEGFcJjx1cLKKo6cqNeBF1wMXSZbk7ys3JhK
#7SKpIiN1jPjHAe94Ni7o7LZODpjHXboGo8PkwsU44CfejGUrNRBV28zZDd5O8e7YaUTkWPBTNDgkI2wbI8YXUOWBi1RpariFT+j9
#qZSDjMIQGHiTwqH6ecMk1JKhO2xuPUuFzO1QQaUhmNxHC/xGbc2w4Yjvq+EXr/owN8I2sSJ1l6qq7tL30RiM31Gg+qdc4INs0uNn
#RAaC+KYUBwo33QEUz5T7Srcd3Tt82PtkkXINSknrebwoxlcf+ZZjfPMGTNq47iUllOtMwgoJtOYKW1D7PhqQYUjZrumY75OZmG2a
#cXm+rcnIF+bFGnUwvPrdrM1tM8dxh9kYdmw20Ip2EFVbO5qDybPo0JImg1pRYBijwqyJpWGIsU6+yaGViICOd0li63EHuDvZMQnm
#m86tkeOBj4R+Bd9tXEH5NBr7GlaRuFf134PRMattbwJ9gEeLhTUMjB6Kkg0CoUMXWziUvnx5EcV2RvTy5ct47HwF1c4gHVMHI0co
#lhaXPjY9OYlihalpuhU/OjdGumvYSiLltAKFEpttNx2PtaNNaHKtUssUtycbVIkztWhy4oFx/V4dahidGdfvuXz5HhRiMrvmjUNC
#jgORoOFoIkJsLNnhGSIibt+6TFidTajPaz0XTbYVBICNYN2AgZQ+fe4cCnTuRY6CpqgZ3le6zOCgH4Yy/EVK4iqtchmrgRhIJl6w
#lXQXn+87uHZVzS7iehgan9b7XNZVCj+pLzmv6ypx/lTIV2PZQfUNP6pvNLrTazS902s47/T6o1QFEF1E0c5OkXyLzB0oVXEt6qmU
#RdRWhDYguo67wE0JpOsusgpPhHvZ/sHSArsWpdUDCFjLuawPQJj0qCbw5M1i9yxatIIQUHSYERGJiVeIJyMUHDULj6GPTB7ZFB2m
#34nCLTWv54Qrh7Gj03skKG62GnhWvAV00iWjtg/rTGWDKpoV5eczMd0VZNUtbf8o4JDDxJ9gxqZ7p8ZI8bCfmp36WAzdMiDJdswp
#7AbMZ+nbxW1c50wVJxJiv5Gj6kmlUogDr/DmywTKtVCTL1cs+mK4bLkm7IjIgwxaUFlx44qQhU8XpZr9jakaNtEutK28iHaIWxKo
#ZeiU9/O0rRiVetV1d84Hs63h1XS3ZN5QT21oGWCzVGyGd3q5BuIf1zx7thUn6q/5Y1DvWZazcDTUMiL1tQxLX0u1MeA9VWiAw5RU
#tkKXuPHh0uXy0wdTW7vFrknmV7C8PZxRMaMcLj0SZXtDxdgPq/MAwfYDZhyl+BebbTLsRtpc6gJfi2HItAJEJwTeRmtSiPJoQz/i
#GnWb+q8wWeB3KIChtPwJR78AGa0oXqHys+LouSO9VUExg7TWqYZOIOi4zaN4nMbHIbeQiq4sWCMAK1r1STINiZ13pxaiDgXc6KKj
#LDl8sjTLL8vz5o/7MyArVCavLnmJc1gdYjL3S8OGiNhZW1xNWIcpFClXbPAh3htRTJR2b0qBp0dUXV0/3mWlqclLNHpt1XKnrCWh
#o5yE4cAtubLpjbqT8qWVabQC/H0+DDK2q2tyUq9UPYcflarnOgWkEkCDQnOzUlwnGXeuYOJhS3Trw4OlTA4fKACgqKly4Rt6OMR9
#1uxHiqxTXt+HQ5TBpdvJTnwgu+jiRLbsm/V4NPds8PkTw+LfXWSFL5fPFuiQi2zam8JUJz01Jq/aLOEKrSnCb6e2kq+GjDhQl2Oq
#HKffq74+qfoyeMfA78pBM6WjBsr80Rz0LSoADpe7hDXBYQt4Ix2NmK3tT88o5ZVTt3hCtzdTTp5AIac+om0PWeaR6EFxQqXqKO4G
#ZNlKFTe4/C0LI4ogx8tG3ygjm0niTc0k37PMJJXbmklx3xJSMCeYSfKNy0Q9SVBLeRQlD+qantEnx8/Ns9E/+XTc9JR8N25EVGUz
#vpmk6x7A0VTUw8baFi4rKLFdEJZzxBsDKKDFQjnEbhbzETJo26yVoJQqNrC3huJIXNZUkHdvPbyYEFjjgHGwcHuu5W4+L5cdTX7o
#pVQpo2FlPTY2c0nv1WdHL6LlzYK5xiI7cfuEgIbRhn1mHpl7hFUmcCsZlWaKVgvE4uUQf+PDFkC+R4ZIels1KlmL9cpW62l8nj06
#LOytRasoeEazjVBsw1eKhN2jUr5EC0GskJy9B2hg/Cjai7X3iny+T5+RWVhSffV5E41El8CLlOXjdMMw131AEnPMv9PTetJ80wLs
#s8gwaj+jd4/5JM/zZDl5kfOaie9jVovWtTDxoIi5Wq8VitvoIWJOy54TNnmBrOsqJpGWkzim9EyEZXBqoW94UTkxAlydsGSQ6wsD
#aN43tr4wuChft1mP66f1QSHARlNw9ZLrZUEfW1FYLHEaXC4TdYQBvBT9yNyCDROLJ90BuIVTmsVVQTSWk7Q0F6gwOiWmOk5TwEIf
#YEFOSvJfhFJkxWGfnGTloWQKbRb3wU6T6oBfyoez2As7UCqrR5YVlzaiUGZgA+JJfr+vxFzRxXxpniQoeHABURlH1Og6rHM0khS1
#lB1MJfPc1UxVzW0uO+POGXklJ73umMPeMYwkcfGm62ZmJR+z3lX0QiDlsIgCFYIWv3R6ghCqQk9mfSXWKL9IHGP7R0pbGoMmvw5m
#AWe9KtYNW+BksFRAMiWJrrdyysqzfpc+NtePFhqzebScOcw6nnq0h5bNVNTSo7TtXfLKY6YF8Ibj4YVheZD77J/UEXgIFfxoMGFN
#ZyvlZZi7sfTY5APp+bEHojCr4kjClWBm9Px4em7ixeOYpAZ8ie41gkR4NKFXqzo/cOKH+eiIF+gmtB9qQJlZrmCIiXC/+yePoAu5
#ZMHMFVZw9BtY3fS8QOQ70YfM3myJMAwKoqokGzWWrIkH6ocD75rwpejlVDTuKVye8WAetEUQzZr9Ucl8YyjASYPGyllWAV39wzEq
#JIAfgZLy5Xopj0pPMSpzuKfPzzCWaBDlgAYTjMFKXIoeYQAg3EMF8GNX6niKliDAKyl8O0xJpaIbgmmTDvoNPtEAHnk55mZVHXFD
#ELE4ETFAapbhQXfxiIFls83qQh+0GNotff0+7W/UoJKrRYZpyvXvXvl9RD5xgXhKp/eOBbkAhoEVKqqkFpFVaIFrQCkX0QVcUafJ
#z2RBJQox7mwPRzP2p2WMRAAz9siMTN1T3s5XqwtVNorFhSWoRp90uISVsxJF2EcTvoDfRf8DfCVBnBmpqLR4nMXpxMVmEvNrmpvO
#quWrv+Ix6oQ+ge/E+bz/64UDFf5cT1rbOi+Sq7GmBwaiWrW3HZKzs7NwSmIMyfapOOxmDOd5a0Rlwp1FENe5aI9oTZyf0PC7R6la
#F+ME1NsKRTP2wAWUEABKGZz7Ug2TiWd3m53Vyz/ccq65CszVk3W8etGLLnGawoUCBeZCN119QfkQy4T9W41aBCRNMpMIZCTYYgs0
#fdyntDy9wR5QQJ11/EXncJsDfISVzKzJEJHOxHTmcqPeUj+t3LJfjj4lRCJRoBwFVxJkInBDwD3cIPvcFp+KkbgEBNuAVH9TYZPV
#1/i29Viex1o7DTbtXdDU6EBq2MF+W3m3+1QcZC4hc9LstbiBuNNK6jXY85aex80+P9Y60qTjp0eg5/aiFaG+L+hwYfSkKkCoJFCQ
#TTlEVgbwpNrxVHIQOVn3+DbACvaLkCQqReOWMXtpxMUus2LgwQCdByo4IO7QXbFjBZKhcxH7gZ7nYWstjNHBbrlcM2myWfqVphd/
#1JuGTbTJE2yTR5l0j065DTOOIfMXO06U1zPFQs5lUUdo+CqP09vt4JfMBF+/jZs/27zKhoPgEmKqh4BAnB12UwBah5qaGMHRQSAe
#ujE1X3lBmZsjhM14d+yhDImofIzK4J+fJTkqAYWfiOEsS3Jq3ygipcpqHXy68pprf8pFe7F0PJuWhujyME41wPuraDAqNjZ9djw9
#OjlzYfTM+HzcXdiQ68laX+a9ofVC7FYMv9bFRVbTVZ4UaGiDpYH9FfnnV2yzyyhx56VJ+bcE1a/58TfmFeAj8wPJiXItv2IUatdc
#fIo9uC6m2nlPbztwJC+2b3GLlIaUhJ0xR68VfSnd0l9xj2ccxaNj01PnJifG5uUDGWendQGACHpY2gj0vljHW7P8Sriv0Nw55va4
#+t4NzPIThPizMExCoCgJtylgYJjEmjXiMwA0B1LiJSeU20CCNEbBFl7SbIEEpWnOmPPK9Y1fRxLaNKeA6d82FrRL9Lt0LQ04OA4q
#q7zXs2/kqCqkC4v4QHi/+vClJNG2iKAqbWT739khI2xe1O/BAy5QlTaCPPpWVJ6fZpWC5asOFG/rV4spENF8T0mauB5oohJgKWM7
#C+BQh5FsepbQ0tJ2JhfB7vSNa7X1tp0FyXBvzaSB60nPoZy6h9JylqPNKhe64c6SKNBbraU07kwtguO0ElNsSmIoRYBSE5sCekJl
#xH4buwmpJlGmrcLtm5IUtBPidUjWpvbexEK9aasL/cfdb+K49aOVI2MZE/e+c2mnEuFxd7m2QrUXE4goq1knTpywdbCzTfJk3Zmc
#ddrKa9bL5fQEDR3PY4pGxmQs+zHIv8Ec2Qwd4Q/lwRkLiYgalFsladb9x0wLw0ODwL9bL36km7FaKoE5M35+YkqRm3mIfCNqpIgU
#VOspRBmIFAGsJLZLk2R2X7pkPxfmoFCnTt9zD78a5gjmF8TYNXVWkEVoi03erNbZJNMVSVqgDdduzHqcSLHnQj5cHoteZsM9hdvn
#olSSvy0FaR9e6tlQ/+ZDY8VijZ54Ov9szr+pN3mUQazR//ZT4uofayKQzoFQaqa3W3lEhykCuH9UwUqgHXhnSuTLrtJjfwWTlRhy
#TadAjI1ThRpHCnWtLQ0ElUXHCH1iTp+6NDnp1Eg4JaweJhz3l/w7KYh/Y7tvTZS6ffUg1GZhKzxNaGhGcivIdLREQKiNBaQuuseQ
#iasBfJLmuApVi7sGRtrH91k2Vxqo3VJyn/F9FnPcZEBtM3v61PS8avj7SkJfYEhelFefTZck1bNTeO7bJ8DOC2pqNWPTFy9OzEcb
#i6saU4PZ6cnJM6N8GmVkCqbLgKBzJyDeJhl2WZF3cffM0n6vrH2dMvkyMHXOAgyMexMg2WtIse39ACqaMcey6d4BVG+A+3edCVbV
#R3G2ye0vPlfkvqG9NJchI3ErQKH8MHAJpKrCJFiCTJMkBOuVkOxUgh/8TPCbV/6m07YhApBUuE5yhK1YVS/8cBtt3m6QTmRQS9En
#NfUkaut5OdM3b+a2mdFnxYBuozoeb8c+zJuIZ8NZkxcNo/E4o3KVDgy8yKvEq041MOd7ZNqcE8I/f+ibHZ+ZHB1Twc96A7YREG0L
#kACUSmxey7XxbbLh3WKju6197Fat2t7udrtbV1dhbFLe9f7UjTaptF511eTte5O9MTA1eFgtMKPjLeNoXOoG/ZNSLkmdnHasolHx
#vpYpVFxrlWoVmE9oP6qaWa/H4LE78prC1CFxpFV6e1CSc/H0NB0vW2/O0KmH9Uaq38mUfSzSl2qCyp3SKfnXaEcq/wA1kprVAiPY
#nHhTNW4/y5pzv8lKR2N6j5XW8f4q3352kb9FR7VWyTVT3GYv+jBHjV9A9pvi54h9Mhux6lsNI/4J7kKM1rDuZzTWaWth6342eiXG
#tSkQ1s70U7pl7sxRlNM+2w2fVXJG5azyeTgHY846s54BWm1GRh9Mn52Ylao44HsRuMnASfJF+EVVUbxWOHIU9SogfgZ2/xNTaHcM
#r7pT0Pz8ZHoa1UL7kXzj2zky9NzoBL6Q0a8EX5iem+dHSZl/r2VqhWwSGFlS0l0DBFpYhc0y3TLjJMjksnEXkYpCcQuP0ldAbhRu
#neCup/FJP8dBnMBAjtf+uOPitANF6MlHqytqKcoTrxZ+oiGhNyXIyAe/12w90oyPsSqDC0gGMFMBhc46qeby2yOVYs5CQ03OEMXl
#DTfP3IQfbXDjgnaiwDHqlTWh7s1Tv/0bC6hWTehGvgmNd365VDqij9kwwBrYlTWpeq3AAfPdMbq3IZLgaIg5KZiozxdzzl7cv/vq
#y242RPomdSBvO614KNFhtwlhP1mt19LQy0zB8e6bWL68LM7Vi0XfMnMFM5sxrHKFSjS+kJNGLF03inizvVRAcQyQmkq9NnLcAlDc
#ckOKYmEpKU49k7P8yxnF2z0j16OXAPB7RulyFVrDm+ufym/UzZ4ZtA7Y25dMRTcVGaWrSPCSChj47UaIX1IAMzx7NIO1wKjhqBoH
#eytyL9orpViprNWr7rUyKx4PYnBLUy8AuZmVcoaYvzgbAJ3jky9Udfd7zHwtfw2RxZyyN0tnqgV6BklecJKPPUnggLgm+ibITVsv
#6Zoxe4KsV46gfL70UEVjOvkc4pfeCWooDn7v+Xxthhb8XB2230Yhb/au9/fei2pRh8y7KWchZ44wEsdragnrRktfCv9cRKOKatex
#nDRnZlaB3uS5dx6LK2KH695CVItekiYmsFpcSC0KLpamYhkAmMvxRJXyuUKdeG4lSkwaM+k3TNIEuakW9OUMrPCcSxHHMT0bqLrt
#nQ8vFegVT7+bqMV470apONKHZYpT1H4e5GQuT6od4jFlvghUzGTVXqCeB5oYyWcMQLxG9BSPA67x06fuvLwwBtzO6OWFWPLwvfHL
#i5cXT5/qVVJAmRs0kD5FXKShbF6ISEPFWE0qu5tEvZo426goGe0sRT7dVUrSbc6YUJizXzyPo7EKR2RZiVTRXqMpVqZXTIeYYmI8
#yT4urwAxLfm4p3n2ilfobsVYszcFfoy6VNAhjL2SV/VjK6jcnTopEY1bxdiDDFSshOpdLmTmXmaQnKgY/CZJ1mEillXeRxOqxuVr
#MUTbVSCzeXTEk/g4Gh2eCJQFexrOu8o7gFVBzIg98pEZ46O6jtVBLR9kSPcTeGMG0g4YGdGXopc3lpcvb+SO42/Un6uulao8AgoB
#Jr4IIqK+OWyVYkiCJ4u2Lvly8qoBu5gYtsLbPJopMymWI+d2UX7/PDi7fTeMggQ7dsh0oSA/wGy8S2j4bCKzU6IwyW1V1hICrJ6F
#2ogoxD4CUng4OxCqkKA7YlmtsWJFTEK2TwY0kdtYWigsjlPKjzvYpAYMjwVITvXC52ELg7w/ATjhjFIeIOcaUnMHC7Id5bh6UyMh
#z+Jir2Do677aSg5U1MRuk63J1dwgUR6VsS+OPuxJEifRR8JW8itvfcxl2fiwjaFYVz1JkEK2sfjoo+Z68shptqTUuGulpBBTg0tK
#sC0nGqOsJgm3U2udssgq30wV8nGgZLCKSslCbqTKuyZsMPeommw4WXZD7Qe+F643N+rho+rvNekBc1Hhc5iCMN+Tz0pTT3FpE4m6
#krOtIomLrTwdwsaSz+uvBMzich5e6DMXrOqU61CiQwLa8U4k/MtZ97GsMktOIywGGeKFb71YS0MiMjYiDhINxYCe4svWXKYtqIwR
#HUXi0Iur+hEHki4qKYoVugFRbJIkZ2RIt9hOwmZAVFLeSEhkCbxIPcclTfNqnaMyPekXeKVrDW724CUjoO2KGok0tKsY76Qi7deL
#vNTW6pAT8rYyDcn6Qw6NCKErJMM2KExRBOII20Ciqv7DccLb1BqnogLEmRSoUHV91Mgsx9L9q2F6nCbmvJTX7CKfvOs3QiaU42JP
#2LSJtsYQrOfv2YhpA2ui27dtaqu0yRHZhsFTqzOyiW4g2/SYiHUBm6+VWFm9n5VYxX6O/LPVd51CMA4qNLsEwYDtsF2Hdpc42IEz
#bYZdxLFZTeWuUSxT8DHQm/a8bJ9gOWTcz/YmARM0mfY1C95K6QURrNP5oldakjcHYoFdOt7alO2VQ+5c3rBtFjZn6fa51+qsLNt6
#Fbi4QOC66LDWYh2Z2NqjxJk5IVsKFSRQ1xWgxs6QmVLbNKCVXBrFvR4tmFIPMFOI2yZHRQjvZQryGkt80237r+5v+w+Y7oKIxsvZ
#wu82DVhvYhpQNbcnTd1ZlnHZ4bhOIlwOE3u2sTzUXSGyR+qPBaK1VxNMjSgpFo90B925Ta8pIIU88jwgc2VmFXunvCMd0fvl64n0
#zgRdIqGUvJ8uKikHPCnZPLlIaea9t4aEn+gs7eaRipwWBQhTpkhgrbhTjjiirKJHzDLRLRwBWkIyWVlehmXU9P34ZuwdqR4pxkjA
#QxqBpaRUXwAnazA0YgFLST41l8wg/hK2RQcjWHSJE1ndf2sqwOi54SNtRli0XTV7cq9t4bSpZVPfYW5kL2XhebE7xwyEYXMPUl1D
#WngzpOU31sygYHa6iZfCEhgN+QHDxQwIbQiKEG6F/ho+RsQNX0JrNDQirqieG06T4byEMfyGWV0PQ64uITYOI2e3BNxKs6XT+AHa
#RtseBkUJmd43aEv2A5TNNqRYsf/7u6WmW2C5TJyGuUoNDXNVm9oilvdbyC3WtFzRYrIggHQoYCzXq3hKjPOQ0J1qDNsaKGvRCpSN
#BQnrnFS1taFVe+NjuYiWXMm1EF1rrdRgrZX81lrJf62V7LWmLq+SCplOIqkstVKjpVZyLDW/VVAifkYuBEd1zmIbK+kvXH/OHwdo
#Yv1fKNlwenY3461ZnYZSk6sBcw60M78M0JUxitfoGmqN3hdwqs/QlqsBc+7mzpR9h8K3V9luFCOQqpnOSJszcoPKJhmF7RDcv88R
#DJnpXMEQfLPHosiyy55IzrXpxFc8Ezo+EDpiHbiSUQfcli17pNwQKncIbC0wWeXHs+iInH/z7LiaX6oKobeRF8fXRvQlC6M9L870
#PJbqOZG+3LN45IVRfknUby9cry1glKwQ2eZl9fShsTUDeapfrz0fT67Va6vM+4kXl+gYT1BvYMBylauKnNF9K5uw/+zovFtAgae8
#GAwcUg0Kz8Aa5ILZLJcqh6Zzjys0slcWUnjMjvIKrnlYv5KsVqoIsE5Uj5zuFXpvh1pqYXzSsLVbIW+n1TyZsXFoQ+poKpVyThY9
#FIDgsLDmeDSAuqMoLNGDnriXWV/o6ZPNRuWPxWFOCw2PramvZ4s24hmPxW/n8vmSuI5aqIqBFndurRcBFl5iQdki6euyriElE494
#JetVWxFHdBHj42ghdMhLELf1lGJTgqneo0a356oxdWprq5Y1VrOw7dSebnqbc2t58/avSHOzlbZ6Dt5s8+TNimfxORZv7wJH7A2i
#uO3Cwfd6xey2kNk+Wais5cukecTXrcmPmgVmZjkfG+iP+zbHebtK3KzgrKsZc9W68CxfoZZKXgR6271DHcOiUNXCXM30Hx3i8mG3
#QCfQMN2r+Y1cYQXVOeLuV6rFdIqmpVfx7a0o2bLBZUOtcCwUmRtrkIY3RF4ccq7a+RQHBW3b5mQTFs5XKc4eSwHtjpeIb2RgaO15
#F4dURbGJLqkkWcfVzwP+x3PWSBYg1NRfVC+g8KmSXQOY4yfZ5qX9w4uFjQmAZEwtdr3JC/PzM6zHKq0gZvIlmBu2mYj8MWE6jAFu
#s3I1beRh2tKZXI4e81aihdZOmt8bQy08iB1i24W1oglM2YaQivPE3UVar/OTc3TtA8Z7Dd9sRlRPclaMFEUKA474aoue0U18FDBb
#LACjI9+CWypCd/VMFkkwmnekftj3SeimRgxfiEvIIhOiBNkRBSVhs81rJkBUlqWGaErKjfWUixqA9GNjlXI5T2Y6hRmkedZSEj7T
#LCbn5iaFT/AIbjQoVCq5x9RkVjki1QSDX+t1tBnoLJ8GR8TUX6DuGjF1fs8At4JzLNSzRBJ5r4Z3ASiMKtDzhZaCFulnsbACza0o
#KYQqYLmWN8p0yGNT66pRqVWylaKaHOvu7Uv2cTahvIVKlil7moC9QB0GmB9lSBhcVmDDWqvx5IkuIa/O4BRV6bKYHMwmHibEOPe7
#KsVlS7sMahXNcShQu9PhbYbaRvKqkammeVXF1GjLlIVZADqEi0EhQHUi50nunwKXMNXpEswgWldksFxGI0uHM3EX4xjhhcJrPF+s
#SrODWEjBM2T4Zqi4i2DU8QTPqGxcc9vp21gmkgQ9EEp6nOPhnnMV42rGgC0duvhGkZvV3li2sPLGsrRhmoiilUWp1bYwPHhUee5H
#0ACszgO8KgCUc2nUchOjUVl6NCGtN/cjUZH6hDTddn+Emgnpx+XqpaoZo5yAQeqwC8yY2UJhhMAzLlG40K5S5ogBC+qXqmziiQy/
#JNyMWHSMNXl75q9VySg5YK1iIUvvd/ZiY07iy4kGTPtI4+rcZU3myyu1VcEVIudHyijxplkz2dV8DxZgVNDMZ7Rc6UGDRnlvhdk6
#WjAROU3XU9eSOY6JaHEtbdhbJaZ0lW3HqsVS1FU8K3Oo1igz7mqRC5S9nX24Rx31nmnSoTG512a5sLzcdJRn88uAUvNGz0wFZuqa
#GCxDhDbNCivDyJQcNZ4dn3pkW5M6J7qpVCs2Uj2mkdXvwZz3nNQLpRXFT2A9fBKmpuxMZmZhibmCateKeTXvPfUyspc9BTp2gBTL
#1HikVAgapn5PuULhuI3tgcZZAQAJpR62NS0KiyoThgTYXqLKTJXtm5lerOICbuuW0MXRh9Nnps8+Qiq6DtoKOwcZOcy3chSTgoDY
#KhVgxI0VFcSNzFWJ0gyCOFIBLqtagkvR65u26N2lUwv5XcqXfLoFWTy7HYXu58QFTb9mAhoCdgA5S/jBW4NujJizRzZbqawVJB0g
#VeMm6sBoanKugLbPxuxs7jHHCNX2l6vu7ALWssgvZlDHUNMP1n9WGiC3eaGml6nkCU/U7gyx9C4IsYiAwvUzReAuRMsbUs0HW+zE
#EWjwzOqot1A6+4PtCHEEeaMm3vcVIah2zUeVMT/CSEmbk8IZZGkgJep6kNqkXBOCKJfytdVKzibKuUr6/Pi8u7FeRU7Wn2eNS2oB
#SrlcetYJEsDUKQrfl4O06StmrJ4ExsO45r0ej8VIvqyhfrWNq2gxq3ea+SkJT7n8LAKqmfeytRpP0T40tD9FlvpuhGT5JncTx2jK
#SuggPCfVaxT+jbfPXz1DkcVW5WLV+hJg6TReiI25lo7QvLZEhkIluje2kOo5kelZXrzeN7QZv4wiRxQfVj2jWGpwlW1m4ixvaAGV
#o/YB+i+OzhAk2trQvjqzkMFfN9bWhEj7a6ai8kOjmyzpeNxnhCiRfQkpbV1BStC231vNcwFuKEj2my5RlIh2C6Y3t5o5BGTWAHdN
#37ZnjqfKoRnRbK7wUWk+NMcuEP7zJkKiJJqlKIimE4ziRBGk4mDrs3Co0BzBRtkyhu3NR059NbfJXDV7e8Y7gw5lcxpvanOveyvC
#Q8lCumZDIx/gw6SNwcG/tazNQS3t8y1ZgTdupXwGnNT6RvzfBvcURMoSnqLsMye7JNeLtMr18tgVpj9XxLWZKNAu2uMPpuwL1TIR
#PaXI6VIimeMSty4Tmqy/RgWy8goZxd9mD+xXp+weOB9k3GZBbKTWUY7Dbu02i6HHXxylqC/d+BSiaKY8J/CNf83XkiJ9uKF15X5W
#qylmzPuR4X/SpYQz4tFtfx7RUOPWuIeq19Ky+mc2ZI0Jm9QK8yo+udAAHZyJ5d0vEUE/28I56oM2WJOnCeLYFvm0x7Q3djl35EYI
#5z85iProweAAKfT7+YTaGyWeyNz0RhtyZI7TdrQtNoT2VOmR1q1K5qvszcqeH52fGGOOr7pwHAseSg0eT6WoMAxQC4xFUVwBbYXe
#rkMZFQOKtux3eNcnndRT6t4CPh+QXK2VaEPQy3OIrhLtYhnzb6+dUUdZfvUSXljOrBeysP+Hjx9/6S1WZmDNAi/H+1xRGPm0whkD
#z51mCtW8ODOwDxhm87CA/R5YsDQNlIK2vGwGm1XH3Ue5FXVeM8M/etxnmx0Uz7SzfxMxkWu8GrxlpW6jZ6bntt5HV/330fS9wf0x
#X932kwaMVgs9D+Sv+YjERclkFGEhKi96L0ojYqulDNmKgObl0+LYkPQn1MQNLO7dGETVy6gBUjEKj+VzDdEf7mstQZklztuKKWZD
#9L3CirN/szym6bdZqLR2s1XBTnPP2yxc3ippWrJiau7Z7GFvCLX7wdbUw1HS7oj2QRH0d5eerZu1SkmceQzrWaNimj1moZYnEa0p
#Dz2xRXqh9j222vtKajNmCqFMIGgv2BaqEros8waukkhfRGgoRQvVYTQDXqgCwUpIi8WOFCvFyhK9X9aHHM2Q26r9s+uwZbQ/U4Pd
#R7VmWtb62VJ/koah/8SzXz8GsUykE2TbVqP1Eyf1iIYj85x0D21RkVIR7EOuGhW24rKK6J/UHHJJHc9P9DuhVax7VMYzdUbY9Faj
#Xs5fRTOrSV94wD9VpQP76klAj5YpYt2RQ+ZJfQZw8kjvSf1CrVadLhevndTnYNc7B3A9MpnZOKlfzGygoZCRQzkiRVR6Ygt1E3+5
#mHXkZQmP8SWyNbyjF4VaKcariN90nO1nVhP6Qiw6l6/1WHL27Fp8sSGHg6uGN8zMy4AXr++sFbJrvcQ+eYPpnk/Cue3lJ0ATPnvz
#f5ZCFccyhsbTShdgMyTW8g3WOYdqH7nK1fL3vkCdOE0MY6P2ACvCKRxPam9VqGuOGxW+vpamBGrZCUq0/RoIXJpUgPFbtB0YTKGu
#KGQqBG6OTL6iMgGWzOU3e4F8m4tNtGM7FKhSr/mQoBrZXGh4uOQ3pJDFH+9ubWkO/7ZpiU1VOvNXM2ugZHajbEkzRKVi5O3j41TU
#jd7+ue527BNYH7Wf740V2u5+Cnct/xw3VOoxF580Z5UBXXkM6fXKY4VqlMiWl1MdJd26nnGEUXqdQr3/SZWwKk52AYphjUcolPAC
#BCEOULRvfc8LlQ49lwo31BAfTRarSKtLCTECzdrxYMagfaBnOLbR9n8iBZ/vSUlHCkOE7mSlUkMNymICn7tMZ1byjgP5IvG9xWSR
#VcGsZ4PxD614Kdc5gDoX6bzRYeTQKj/umD9CIJBfFTd5CsK8aAAIX8LNV629hOuYE4vx1z7/npFZtoZs9QjsIkp5dMLCAUxiptHN
#9eK9CFw1KvBWsjXA0DBgqCisdpqKc0js8PpLLy88rosYTMdKyKxnWEfIb41gWAHvH/Wa6ytHNkpFN+fIpTKT7FxO2KCoCLKe7OPk
#bo0RU9zaQfEid9vGobXMCkTeEz200XNoI3oP2zRK4jMcqIiZLuMFOvKj8nBcwU5pIuvPCkGxGcemoxlVxs3uGEXgsDmDYOzsEAeY
#ets0sdyDp0A9F/k5G2RiaAyOwLz1AJpk5ISdE6MYb0S3LDw54JYreJHG+HwGkdkWNfmW0hCJbIFI7HVkBQlLiAgBclbtWaameGgH
#oRomUjR+UIRjgCkZ7Gq9er22aS+uT3kn2nsIwJXJ54LdrCY1bVimQogjCR6qrBJ6hL2LJ4+FzPVTen86lUqlPfeRlJRKN/HuEuxi
#hx1dxxNhvw2bkmYBhgavnpFRKS8kPEuq6gVpMRj/dxLPG10H2yC/rCBE1K8nY4kqBC2kIy/h5NKBWtN0Pb/UWij/TwjJtrwE4NT0
#V/T1lZtrpQxQXZECT23TpBNfXpHV5pbStKrYx+I4nbWAKMQyx+wg42j0UZybCGtuYgAgVSmzls8VoF9Slyi/UQDUUFlTVOdr8rqK
#uLgSq6HCZ23EsraYEJdUOA+jddFGm/pmcjmmvU1IZPJR2TS/fE5iickR+XN6H6m/y9TkQ6OzU2jnF9LpIg0bvuIRTjLbirdcxFOv
#ozMTiN1yBRP1mKTOqDJxfLMnFu3rP5ZMwX99UTpJkCnSJMbA69wuUOCCGHbtYiDnUoEvCeO7tjKvI48JwEtvu5Luo2UEurm+ZTPt
#VbrTIW7D0NLeqMXQOzM7PT89Nj2Znp+cS8+Nzz44Pht350yWCuVCqV5SbpdgVsjxIAegc70v3e/JSKCNrU0DDwMA6mh/wqks6txk
#0pgl7dtL8HXSRMcAmY0VZxvtF/H6U7ZSL+YInJYAc5Rp9ukRoZMkl0VD3NUitFvHuzSNjNE2llaQOQh6JK75NTm6ABlVLQtYl8ON
#tH07POLXvWF7P95o9bKx+CZLt+Gy7+dnup9FVvnC97PIKlcVXzpC0wP59abNp+ms4rUpvV7F/f9wby98DuXwpTN7hVuLF2LiLCIg
#GCIw9CxI3wWu7tBqlWrscFo9Im3QHwHK5mq9hkLUJh0xCyvUb/qJCd/cxPn58dmLCaqxebqJqXk1maxYHUbvkInXM8iiPWCYNGnE
#pdMk90unkU6l00Lex0Qrorn+kvLczx3xHP6h+dpjR4/SL/y5f8ndd7R/qH+wb2BwEML7+vr7Upp+9Hlsk/VXx0nUdQ13ws3SbRX/
#f+mfNf90f3GyUF577iHhxud/oG/gX+b/+/LnM/+CUUjWNp6jDuMEDw0ONpn/Idf8Hx042q/pqeem+uZ//4/Pf1+yL5nyUIV/+ft/
#5c9n/VuuZK5YfC7qaL7+h4558f/Ro0dT/7L+vx9/F1/8Ji0Evy3w77vf1bRfFuH3bSPv4/Bv18GP7dI+1PEbd/5yYPI37pynd5KM
#yooB2yNpZSKvG/UybaSm5/RSJZdP7twZeaEoY2Zc0yYDIW30DX/2D7Lcr2pRvTMAs78MnjCH/e4PwkeHf0+Sdw+5g9xuTbN/ITOF
#419Ie+kPYlL83/61frgPkGJa43JvD/l08hOatgN/XqVp89sYE+sP2teueNvBf0HxJ3ETD79fyot+LdvtVop4adIwjawm2gZtpI6u
#OtPdB/8njXyxkuW2YpuprKIn3Rl3Mz/0g/x7gbK0anvOatoHIGFgO330+bsjeB2ythyOBkOb5ICAoAwIioCQDAiJgBYZ0CICWmVA
#qwgIy4CwCGiTAW0ioF0GtIuADhlADmjb3lRQmxHtDB6g5sEPNipogKdKzQkavejEhgSjMOT3UY3Bg7upouAtVHzQ6MNEWHAwdkDT
#IodvNUYhBH4u8U+Gf16HP9CWiGyLdMRuAdCGRt2WCmsvD9B4dwWN+wNa1ViCT/CZ8EFIYN4MZWPSSBBCBjHkVvAciEHyIxh0Jwbd
#TkFBEXQUg15AQSERFMWgOyioRQQNYdBBCmoVQccwSMcKwyLkOIZEMQT6fiSUWI3dBZ6Xw9ptOdRz4O6Xg6/lmfApTAVhkUOPY0wM
#BuhI5W7wR47cEa7cA47O4PWdENNWiYFnMgaNC1fi4AxXYAQiPX/0VCScCIcrR8Dz5adCdz+lBXHotfuCsZsxaSd8YgkchGfCMays
#B9ttJrFhMFmRzf00D4AwIsYvw+Dd8sPQscCh/cEKzFLk3YcOiHKgo+F3H7pZ+GDywm+AJR14d6wfZxBct+Ma+B3t8D9ogiN6t5Zv
#C4SwtHPB6/up28G7D8cGOP3eVEDbxUutKzaIHe7WYkcx7lPBfTEY4UjiULByDH9fEKwcx67eFKycgN/zPTuCPBj7H30mdHj/YSgr
#rM0FEGdpXSasv3AkHNyEFC2hGExcuCdwONQZFgO4eZgGcxjcO0RnIFs4oQtPG35OYrW7lL7uT+0Mthm3BrVqTEfYo2nYGby+GwoL
#X8ciu1sqpzDXQkdXyyMiJ8xb+NHeiWBbd+vB5IHYCMR3txqPYSmnya2mw3yPxKCyI5DmrXaa2H04VVSrWl8HA4E5irBj/BGkd09N
#5QxF/XeICr8Ms8TGIECE/i8IbSf3y3dgFMzZkc04lv5MeBTBZBxrPQefu3F8W7QMo8+uULd2863cFc1oCclmai8/jxk6sfmaaEkX
#gt4Fjp2wY9VcLSKeOlm5n0ED6gtpALKAUaG+ygMIHGGaycRtwfD+GCyPMC+KMM9pZRLbuf/wS4LXuyG0ZycutXBPOBg7hHN3+DbA
#XUinYGl2Ge1YO/T5SAxKOHKoZ8fd3dozNwEo3hY+cjA2jaPjCOuMzSDQmS8SMDqLa/Kp1rv3dz6ltR3WAoIgXrigtSKsy7raGte1
#26eu3aKuOQi735wXdV3aqq6QVtcE/juwiX0P7t/cSwsaAXRzHzqvQz9aKg/iBBAGitJS3Hv3vmfCd9jYJ+rCPrsl9mk7QAMu0M3X
#VXSDc4Vtwh7f9iiv+9tSrdr/0oh+d4npCBzmNoR4trq1ykNY1P0mrObwIRG6eQCbxdMqEwZpSfW0UWeOBNo3YRW0RByFhSsP4zII
#0YLevBlhomXzTop/BKets+3m/rZw2+YtCL2hyotpyFvu3nekNbYA7p0dicFwR+UyjvrmrZi7o7JIntvY8xLy3M6eNHlegJ5Q5aXk
#OcieDHlgOFsIBR/WxFy9SVv+Oy0k4SIHIbA8u/ZH9ncaUYSNXTjgS4iLjvS0IwsCLeKG3zwQ6ajksNjIkW4RdstAuwjrbOfp+M9P
#RdoT4XYF+4fbzDwuI8bH+7QTFyU+btEuPSLbEtKQRkRwjmKw6sNP3RIJGmegReHKMgLKCn76MMLuC8xpu3bLYcof1iKANTsR354V
#+DZJYLd9hBo4bK4igG0fKPeGjz+CoM6Qubct2CVgk6GmS2D4SgFH5mZnoE039+9t37+3Y//eCES5wWFvZ1dn4o6uTgaIve3gImjY
#2wEuAoW9ERrlNoF3EbmKKtzYtYuJjAh5SYhCaBpV7LyK4e1qSA1DOtSQV2BIRA15C5dGIKiG/xSHPwqeB9Twn4Nw1yCtwfcNSzJJ
#BbjdSBev8eF3PPPd7z61oyucaOsSC53Yuh3GhxFkS8qYlckdvpvjaWRi9+Civl5BUL5exTFt2ZpG2dTokPFZrOSKPXK/jX4DW6tk
#+BJ1CLHLG/J26H/DpIj61cC/h0DHcLa3wCC1qCG3QggBiD0ghwwdAtvIvbc13NWqkMleJpPjbjKpjU7yOvkY/APcpv2NRjyJhmsO
#txQwdFoRIPgPA2KvIf7+Evy4HncG7fS4xmaDlE7g0UR78Dri9gTg0wOE5W9k6Rzp9q4bMeE9f+acbaAhWJ8ykxGayc7YC5EQtD0c
#MxFjtYvJBNIV7g0cDrelIm3hVGj/kZZbjgRu3inoTg2beMjJ9I5gM+vUTIyJ7UYKCTjmyHZgBXiRanf7gZuZB2lXUsW6kL9oN463
#SP4CRgxJIHNV7cxk+EPZqRYEKEyswsCkH2AgQIXdANWmBjzc4gK5ZQhwLHKdYFBAV/A69L3FqGGYAmfmBjbvmkas+xEnsAmG/cch
#y62CYafeAL8u+PJDN7cJxy1Q0WNy/dj8OtHts9rBLIMi7u+OIQwCvAHncR3J6QDytVpwc5B+b9rsp9+XcXCsm7g58sU2qVAsA9hA
#5OuxjJdjGSdEGcP0G9o8Sb8tm6dEmce5TE4W28tloi/2uFUm0F1tN9KaJxAWg537dxw53dZeeQXimHDllfAT6h3qOHgy+cKOg9Hk
#wY6Dl5O3dhyMJG/qOLgzuacj9ioE8nYg4D+IY9d+4OEd7W1Ekvo/Gq68Gkf5NVZdMOgo45B17di/88h5oLqvIEzGlR1M9Y50tcRe
#i6Xe0dVyUE/eDN9kshu+ieQO+PYkw/BND3TAD1faceDhnR3tXOkHlEo7uSGJYNth4+ZW2O8ibT4lee2D91RgExx5qg94xBcckFz3
#C1st/jlU+SGEiX00bLxTeD1m0A5Lmh2JaH0IILhH+p+4QYL/W/fremu7FnsDRO8J7WqJAe0O72kJGYNY8g9je9Z3tep/DdljsF0M
#i0bu70t3ByXzH1TY+KDC/Ac9zH9QYf4dudpEPLf7R3AKWoB1O7/rXR/4e20wcLgl9kZsf+jEC6DdoRg2YWfHLY+MtzGKxO0Bodmv
#w79vBfkfsLna8W8gHt0f4zmDiVhLPgTfUnL5+BdcMUvJFfiuJNePfxRjblZjrmLMyVdige/ESOOUHJ3hH8fA11DgjBX4sxhoUOCL
#rcAdgNqPL1Jgzgp8K6a8QIFFK3ASUw5QYM0KfBcG3kGBj1uBf4qBHRT4BivwPRj4t/AJXoehb2mpvAnBjrdNJ76M4WHc74eP/3YA
#Z4aCP6MEf9QO/kVwwo41covcsb7dArjWlthNvEO157G1lRGvI2yX2Nm12kB5/EG7igewivDBTlFF2Hi/VUVYVBFWigu3JkKtR4IH
#T3FNjihZU1ip6a80q6anwdndZnWmzfiEVVObqKlNKa7NWZMjStbUptT0Ciy+/WBELM5243et4ttF8e128iMPdncc3CHSdhh/YaXt
#EGk7lLSHuyMHO0XaiBEMy7QRkTZipxXk4FZIc7MgByEgBS1veFhF+SQnGcIGo8zlBcy3X4eyWh45uPEokPBgePMmWxo0BaUdsEqL
#vVkTcpugNiHlgOZe3GWiWC5ovgWx/U5y/ig6d9mhu8n5VnTuIefb0NlFVf0YFvte8/9Dsnjro7EfR8T4E/B5HPBFi/l2DN5feQcG
#7CBJJMoG1i3ZwDsRQYSFvCgXZnnR5TDLi+YdQgJ7B8ArRMoOfhKzxM3TyOwEN+9BTkVEbd5N3Mq9UmoW+ylEgoejUqwwFYwdpt0H
#Flf5VxT5Q4JX28W8GsogXGloDFu0czgfyNvtd+zb7c26kkUI9BQBHooMOlFkQDK8uw/fLySvN9OYPonVJE1AmOHH72KBLofNhniE
#IiEaof3PBFB8Ru35iphTZWMTetkBH6lR6DpWomxrQtdxc+3e1ISu3+oKrVHoba7QV1Do7a7QYhhDX+AKfYxC73CFvoVKOOgKfRWl
#vdOxQ7DGQfA7hwUcBa/jTDO1kcC0TwDTjuB1hAnGkkoBkl/ap/BLZwSvMyZ4m1HmbTg4tp95mzMWv2QVhuPfDxjxJmoLzG8LifhE
#g6QMM3j9CELUzSIFyjcBrhKYkKSD4e7AwZHbGV8EFLwVUKhzQMnsptMBhU4HjHeH7fzvUvNjI/wyfNbOYEvzwt3Bg4dv2YpjaNwm
#J+9wR5uVXxEYeudkvzIn58WcXBBzco7nhIPx+OGI8LnmBPdfSPsP0JykEOTfjdNxZAGyvUcjuXwfNhvlHm3XfxpC2q7/DH3fS9+f
#pe/PYfNTKEi5a4eSwTDacMfrlrVA0e9DzPXOp3bBCt8Pa+U2KWlDeQ72LHVOu+sw7Sd3aKs1EqGTzC0O8HMztbWfhWTItHeGE0cB
#sxwlzILfHUHgfsnffnDfqf+EckrafARfNoQ9/Hmo68SHsMhwYqqNA6//a8RA7Hw/NjWBU/QL4NrZHYr9Ijb33uD+QxHaHQQ7No9R
#cbRHCBEveOQrb0JacR0jdgZfhj/P3AQwfVvwJpELyvkAojFuS3dL5YPo+8rEd7/73b2tbcZbYayUthgfa8ONEg/ev7EG77anbtkb
#Dh58httBDegKx/4txD+11xkc+5DAATym57XX/pZ25DCJUXdp//0fWcY1xGlDsX/HiREejgHPdQuN8XEe42Ea4wNDF4KxD+N020cl
#B3srHyEkjvsdmmLzlxEvBa/jxif2UezHJ6Af5scQjn8FIXUEmf5wYi184CQPGAZUPo4p/wRStinitF+FwJd30qxSon+Phfyahqxr
#d0vsEzgnozQn2M5gV8vmvdR52mQBfbgFJ6VEvCJG7IWoe2lWdDkrtCtriX0KZxnm9DQ17UDybPA6Oiv/Aev7NH4QDva2Apv3i1zp
#AavS1s377Epbg7FbsdK/p45hBGx7X3afExSo0lYCBVHPZ8CpI1Pb262GvBlCBgZvO2AiXtkbBn7w7yzMEFYSCm6RcIX5H+Hz2I6n
#Hgrv793LaRKdIi0tMQ4fEeEjVvjeNoQe6tM+miP4OW31rKst9usIYtFmidpjnyUgQvkQyoH+Dv5BLu1Xec0yLwX/FuDfYxD2e0q4
#xvtp7Y8h7BvwD4iRJuDzBMHn5yR8hrSPQfytBJ+jDJ9jjAMGguYZZNTOEsTgt22zx3Lv2zxiuY1gO3ARCYbE+9sIJxs5CGu7jodD
#9tonQPtFG9BGBaCNU6fPCEC7Def8HgK0cQFo4845H2VAwznvbn3mJlgtga7WGCCmyI72yn+W0/tqaAEgic8jQb4DHL8BjlsG9nGb
#wf+buH6wF0dOKLnehLnaONedIm0bpcVTFw4g+kkdfmoXQECHIk3X97aLAXhnOwppPdiaS3gmPOZgECFfBwLDKEPBWWtAujoYG93q
#GyuRkoQRAFftCvw7FuD5l3/jCCsQdj7Aqg+HhboBprkCrh9Qwoe4aAcO+woUfhvByDmGkQsMI6OwvF/aRsQphsKmym/hHACh/W0b
#w2OOYPvmBDWaKCjs9m/HOf6hIM7xBFGYl03QFJ9GInWTyAXl/A6Ugzjkfq7E+CxBVa8TqlyY5JzAJPfbNbbS0daRr9xMNd4vMMn9
#Tqg6Z2OS7rCAqjBB1c4Oho822Np9C+GjheDjRAE3pC0EWDffd5k9vwue/aenwWNCgeG97V3tbZtIwrvazS8gxKUYeL+IBcK+LPZ7
#6Og4/pe4xeqI/T76Ors7jZYOqGcn1dPTRnz6kT3gZ0AUwvO9OyAhMt3duxwJ28CPCbt3x/4AiSKk2oXFdTFYR8CBbb41GdoPabti
#X8JK90CqOzDVXlele12VdkPCBCa8yZXwJlfCfV3txAN17eja3bWnq7trn/mHiP7/CJvWEfsv8DPcAeT6qW5YRDu7O57Zfy8y3bSQ
#utqfCZ93LhFaah2JcIe11PYLqBiC1nTt9yw1oO0HcNmcswCh64BC2+1gi7aP5ngdvRim7xn4fThI+14L1yIlejXEvTzoXF+4t0TY
#+pGgd329G8I+wDyAXF/n1fV1Zu7+MwGh/YNC1fXBZCo5kBroQykV7DRQpeilwJze9XJN+zz8XgaG/665moGXszAFLoTLHRB2aU57
#1VHWtbrr/KUJwBLaW8F/O5D8u84U8cBQ9iPw0IF3d3bgCd//Cgwg44u1GxrJSzVYFXQW3c/7HA2mifTObhNjgH1COoO6VthXzNsh
#2v4CqmGkk3sT1n69Pb4nrPV34PeNbTt279Ym9mB4oP1EJKzd0vHKHWGt3o7ffvpO0/fP6fvv2vD7VipBoxLe0xbfE9G+1XGoLazV
#wL1L+3zb4o6IdmrHayH8252H2iLa4cChtm5tc29h5y7tbV3f3rEf8MnfBcPa+6GcW7WbA7+6N6z9beAjnfu11wX+LhjR5nYNdYe1
#6+S+exeW/CfdH+kMa3fs/UhnRDu78+DusPbXO7Hel+zF8v93N35nduL39D5M/10NU36Cwt/ciSF/sAPL/9EA1ntTG5b2X9uw/bd1
#/j18hwP4/dTOH9oH5VCb3xvB7yZ9v7QH2/ONAObaQ3m/Gsae/vTeb+/Ypb0WvmGtFMCQf92F7n+9E0u+tX0HtPP6rvieP9f+ZBeO
#8EbwI52/pP35LoTf0XBhZ1gbhVzd2iVwv0b7swjOMUJ5RLs9jPVehvbfFUDlr7sCL96H4Q/v+UzwDm01/ArIG6HxGabx+eyuV3SF
#NTOMbfu1CH5fBv2Nal/ZeTvM6b8NoPt81+2RiPanrZj+UUozC+3Zpf3cLmzz39OIPd69uyuiTdyEtS/twW+S3F/bjd9fpPF8PY3n
#XBDT/8jO34T0b9/1GRjV3+v8SGdae9sO7Ol7d2Lsvp0/2RHW/qITa/mZHYs7urXPtmKv90Z+aF+3FtpX2NmtddH3ru6/gX3eAfje
#rYXCe/fu0j7W+m06zfgAaQMG6L892p907OwcsXzBHTs78VB8nxYK7NF2wRrchF3eCe2V4PtyEH1RbVgL3blH+wb57kIfxL1YQ9/d
#2mnyBcgX0+4j35vId0Q7Q74D5EtqZ8n3XvKltHPkQznrH8KKvEC+W4PoOw4rFX09IfSNapPku49857QpqOtXWz4VDmhGy2fg+56W
#z8L34Vb6Uvg/tPxn+P4+uW9vxe8pin19y2+G+7Tazt+Fb2jn74fv1L4Q+iP4vmXXn8D3vd3onun4S/j+bOjbkP4tESy/i2qZ2vcM
#fId24veRXQGYu5/obIXvp8KfDcNa7vwUfI934ffP9+D3p7rxmwzj99cofLwNv58PPQPf/7L3M+H92lc629uGtPcHu9v2a68PtsO3
#R9sPZf4rKvm/7zlkff98H9bC4Yeoxu/uwu+Tgbgrzb5gTxuGn4Zvlmr87Z1nRJqA9sUAjsax4Hlwf1ObVtI8ZJXz6QiWg6UFtC8H
#0pDyTDBH6Qvw/a+BaU/JcQj/T5rpKZNjT1P4VZF3BhGr9h/bu3e8MQDzJXx37EBYzJDv1e0fCh2C/XxB+D4R+uG2oGYI35XOS4GQ
#9pjwvbxzjxbSXil8f7XvUqBFe73wfXvfHmDb3yp8ZuiNgVbtncL3eCgAFOBnhO9tu98CLf0F4Xvf7h8D34eFL7/7jYE27d8L3+bu
#gNam/brw/SrEtWu/JXy/DXHt2peE78PQlg7tq8L3GWhLh/ZX7Lv5W7sA72gX7uS+/0D4UiCiTQvf4R3oe1D4PrILfYvC9zTF5cj3
#Xzs+3/EOwCNF4fuDjifBV2df4L+Enmzr1B7nfNoPwwju0PB0HH3vBN9O7RT53qz9/L73tu3SHhS+P+n8efC9lnxPaN3hD7Tt1v7i
#hez74r6PtnVpDx9i3193f6Jtr/Ym4evb9/m2m7SfO8SlXNv5pbYD2r672TfY8o3gAe3xuznlOwCTQtw97PufkS9DykSMU27u+Vrb
#LdovxzhOA9x6q/b3wndlF/ouJ4Qvgr7PJ9n30cjbQ7dqe3pFDfv+qu1WLdfLZf5W57fbbtd+W/jad/7vtju0+RSn/IdIsP2g9n7h
#+2awvV3XPjDIvpM792iHtL8dtGfsbm2CLpG9+ea/39XVfrdWO8opJ7WbwPd3wvdx7c72mPZd4fuPgZ72w9reIfbFAb8ntOPC90hw
#D/h+aMiuoUf7ySG7hh7tfY64D5Lvldrbgicg7rPCd0y7tz2pffCYnbJX+/gxjisF0fctR9w/iriq9vZQr3bvcTXuwnGO+x0Nfa8+
#oca96QTHPU75vuCI+7KIe5ryvXYYfU8HnthHcSfZ9zfhQfD91Uk7LqW97LQdl9LecNqO69OevM+O6yMtchkH3NtZOw55uYD26o5n
#/w1F8PuWkP19fCd+37ULucKX7JQhQe3H9qH7HR3o/lrE7eY0X9urib8AYFIM+XPK9dPd6P43llvWcmsbhv+rTtR0+SUU92m9O5E7
#5bp+o7NZjar7L5H51X7XaiH0q837DcEM7dC+ou2Ef7vg327416F9axdQOQ3n8hb4RrQ4fPfAqOP3BH1H6TtB3xfR9xH6ZihvAb43
#we4cv09QOa+j2DdTLIbfqn0SvvdohcC3dvUAzcd5/CjN39cDmP4a5YoHv7XrnPYT2qtbJ4EbYXfXrpdot5P7hfRN0HeQvhMi/Ut3
#/ZL2InI/Elzu/pR2imIzwYNtvweg8sVd/whr9IN7dwSuBD8a7ArMa7/Y+YLAteAT+w4Fngg+ALj+dcFf3BcPvJlKuAx5jwd+QpvZ
#dRq+f7ZzGr6Ik98XnNrxSOBp7QHASoHAe/YVAoHA+d2VwAeD+k0mfEdbDgW+qd0DZV4JfjW4Cd9fBrz+0eDnIm+EGh/r+NFAF/T0
#nfDVgWZ1BW5r+SX4vm3npUCO+p6jVn0y+JLIpcDngj/a8QuBIvXiSuC+nZ8N/GHwm51fDmCuPdofBsttX4a6fr97j3Zn4GLLX0D5
#b+j4RuCR4NvD/zuQCU7v3R18OljZc1fw68EvtG4GatSjmjYCI/D14JGW4eDLKORlFPIq7UngJV9FLXwVteGbwf/Q+aLgN7Vdex4M
#fif4+u7LwUBosGsYvl/bg9+3d+P3cHgY0oy24Te0ezj4Bhrnt9I4d4Qw/J1QywsCLwocpXH4re63BX+aejqvBW/6BrQ/EvnN4Lz2
#M51fgPD3hI4Hbgn9bOsfBW8JPdpxKfBO7e2Bp6GEXcE/C94Z+pHw1+F7pfsbQZypfaFXaR/Zc2vo/WKWv949GMoE8/teHPoQ1fhx
#banjeOCntRfse2Pg6cDltteEng6k9/0wfA90vj30ae1y2/vhiyGf1g50/kroCYLAjwY/3fWb4Mb5OhFa6fwCuJ9s/VLoOxrOyEeD
#/x74jhOhnr1fCH1Ta9/7dfiuhv46dGfoza3BltcFsztf2PLR4L6bjrTcGUp2BlseCc6F+lo+D/36BkDOXOQRmCOs5VX0/Th9P0/f
#n6Dv++g7EXpk93jL+7T6vsmWD1LIB7WP7phreR3N8ue1013fCNwZ+vXwi6FknLXvUJo/DFZbvxz4Ioz/x1q+TOP/pzR6f0qj96fa
#ZPCPW/5UWwl+Db4/GPxzSIOQ/3GttbOl9UOU8kOU8q+01+zqbv1bLQCQ/HTgv4XuAncBSvu49lBHSyvO4InWpwNf3DEKXxP2mox/
#HwkV9y1DbL212HonrKArrZnQe4LXWguhb+36AQj59t7Xwrez+42tT4TeE3pb6/u0rtA7Wv+R6moJYF2f1rCulgDW1RX8y72fbb0S
#ui30m61dwb9t/ZPWFwUQk3xaw3o/rZl7j0N6rPeTgQfb9oU/GXjr3jvCnwsM3/RC+L6/tQe+KzBfVwKv2WWGv0nlfxNKDmufC3wR
#ZvaLNGKfC3xp3xvC3wl8cRd+PwglfDI41/YWyPuBwBth9L616yfCXySY/E4Ax0rXTK2l4076HtJer72s7R5tQduIxLXr2hORpNap
#pYEG79VW4Xub9hr43qW9Cb5HtN+G74D2x/A9qf0VfMe078D3AQqfg+99VOYofce0rHZLZExb017TNk7fCSj/rZGXUmyGvllKk6XY
#LFDcTCRP7gKkfFfkcUrzBH1fCSlf0/aDFPs6iP2lyJMU/i76voe+P0Ox74PYX4l8gkI+Sd//QN/PQfjnIl8l99P0/Rp9vw7hT0W0
#ALoD9A3RtyNwXft2RCf3nfS9i75xCO/svI/co/Qdo+9L6Zul7+P0fSV9n6Tve+j7Cfp+lb5/GljTOjq0INUb/FHtO/B9vbYjolPI
#ffT9ZJDShChNaA3GSif3C0M/Crv1T4SyEDvagr3O0PcJ+r6Lvl9twRF7mtyBVvzeSd+Xtr5D292RIffj4D7Z8QS530XfT9L3afoG
#wj+qHYwEwq/XzkfuDFP6MM0IuZ8k9yfo+8kwtv+TkPJS5KsU8nQY4UprwzZobTSGbZhrlL4Z+j5OsU+Q+0lyv4vcn6Tv021YQqAd
#v3o79lRvf4dW6Mi0U0/p+ySFPwnhH+x4F6UMdGC43vFvcXY6MOSl5H6Svl+l70ktG3hF4PcDXwv8TSAePB9cCr4x+I7gN4OvCD0Z
#+kzoj0NtLaMtmZZiy3rLEy2vb/nLlgutf9E6EA4ix0HK9ud23N+uaZ8OTcH3FZ2z8P2Hffh9VQjDf2H3g/B9Yje6v0jfz1HsK8P4
#Te7A76/swu+fkfsfO17czmUHgPsJ0b9WcLfAF28dtoE7DN8g/OvQcE8GQAP/OsEdgW8Q/u0E9w74BuHfbg1vXu0G927gglAi0gXu
#LljPAa0bvnhr4Cb43gT7lqC2H3ikILhug+/N2gsgzS3w3aG9CbimHdpbYM3vBCoYh++PgXuX9uPg3qW9Hdy7tXeCe7f2U+DWtUuw
#ll4BHNKTQAf+VmsN7A/0Bt4b+LXA7cGB4L3Bq8HHg68Nfip4d6gauhr6mdCxlp9v+XTLF1s6W29vfV/rv2ltedx9q3JnpyYvNtDf
#z4Z/J8xcqKZdtZJ+huRAaroPhFlC5Mxb2OkNe0WXN+xX9/qk8+T9aPhhn7yfIo3MFpo95EtDMF8hmK0QzBXCTQjmKQRjGoKxDMEY
#tsPYRWC/U4J/L4N/r4d/b4d/7wOs+mH493HAq/9D+wHt3YHXaR8O/ID2x4F3aB3Bn4R/79CuBL+hTYf+B4UXgaa/LfRd7cOhH9C+
#A/9GWr6jXYF/r25JB5Ktrwz8Cvz7g9Z0oCOcDlyDf0/wreFTp7Pp9NmCiY/HjaG5t4FUOuUNHeTQE+n0YB+6zhXKBXOVzE+eXpKB
#k5VMDn39Q35FcOh0+Xy+NlbJ5TEh+OcL2bWJcjlvCL9Pc/p8m9PnqA/THE/jj6OCPlcFmKyOP+fq5exL+7SpepHedgTnxHi5Xsob
#wjdWKWfrhpEv115Uz9cpfoaMAEDEcmEF/PMZcw1+Rs1r5Sy6L9J7rWfqhWIub0DE+UwpP74OBQi7ZyLL6NVMoUY+WWGtgr4LGXN1
#Ll8D12TBxJ+JWr4E7Zh7IXWsWMlmiiaUmq9NlGsD/TADxbq5ejoHY9/vGAnwlU8fTeOvkb8iXNjpfu50v0bGrOfrVehov3a2QNaw
#M8Y18GCd/Ro+CgZ55vLl3GzmKlUx4KgCfNCHEpY9gLWY7MLcA9olaN/QoCP9IEUpYUfVNhyl2KMMXZB6yJF3SFvJ19KX5s8dxwTa
#qYuVXL2YP02hc2g4bOIsTFYdDVnhEctafm41Y1STozMTkH6akk2YFybnH9TSCEba+EY+q83R+4DJsUqxyMbAzeT5PIBIAaKg1zSn
#2mw+Ay4+t+GQUy7oPZ2DICcAQxCkmKGXGM8ZlRI3McedMPOGcM6R1W3wmKoHu62tVmqzebQrp10q089oLqfxazIPQFV5LmCcjblR
#fum+v1Iow0/6Uf6dFrA6g8Z1oRgEvEv0hDfG4EPPNVHYhGn7hZl9zFCtwlicqxglfM+EU85XapniLFopNqmPMj9MZ8HuJDhPyU6d
#Xkunz2SyazCI5wr5IsSI5nojuLne8Bm043XJKHpjhHk+v6Jy+Ix1EQ2SzeWzFWivN9GcePunYYKLhTJhOO6wTy2rmdqMkV8ubHjj
#RquFB/LXPOHnoU3avFEojZdxhi5mquiAKYYZKAGiIPis1/LSy5OgAbrl4aV18wD67jcrZduHpvYZA1GyhzJGqV6dgamAgLHxcq1Q
#uzYhnhcXSydTq5s4TJRV8Vogrl2oVNYuogNfD6BcZzNouJKcF/OmiW7MPSuswjrDyNy9DLKRqzaBiLxCpii5JFrRU4Au2Zupkhu7
#PFosUtsLefPMtbN5tASXN6yUvMrIO5XfqJ3D5+jl0p4FjFAA7wStXOxe/mImuwoLA1Z4zeE3VQ/jpWvVvIaWOrWHVvNGvgF+AfRh
#iMHMoou7lYfZvUZLThsz8lAyYJ2+dJoqgeIAb2q42ApAEQjlQHButAYlL8Gsa2fzS/WVFRwaO0zSKDtk1DTzpaXitflCTQ1GiJgx
#KtW8UbuGo6JmcA2CHTVPRvxo7NAEqrspeeMCvRzqrfwcdEGsP2/kRHmZ8AZSlmLDVLzg6wals6Nn88tzgKVq12YBLkylqUguxov5
#EhBV7J8SxUOa4XcdipkNcpneGmF4cvVszTu4wmSoXxtL1Uz5mtI6hiwKrxWWCkVYWnZs+gqyCwgDZ/PsHC/zL686JCYEY5gEFhq7
#1+k7my9V1hE+jQKg08cawh3kWccG43KumUl6SH6pvkw18JASWRBOy1SR8J/JmHmVlYHVTT+0oqB1mrSerF0s4ANhleVacnyjli/T
#oyPJycrKCkY611lSzDHGQApAP+Scr3CPkSYKl8I4asQejZkPFcqE4jkwLZCuNoeWI5WEZ/JQ8VT+KgcR+6OBe1VD+8DUfDbljJWN
#GkbmmvAWNIFMxzLF4hIgYxh6/CI11ebpAys2n1+zh4ppHXBrAv9OIsuWKWoz0IXafAXxPqAmzWkF6oECfKiljJjEUyPnAMI0pLBk
#65mHWRA0mibLMzYPrII2NjZHv8Q4aGQalWksjDalJwePPhESbiskm6pDbnzzWTsDlA9/T6VOp9MX6tB36GcpPweArJ038vmyAgR2
#J4SfqAzPJtUn3TaqliEX2WouUDoZAlOvrHwJI/OwsJKInJIStDl6NKumglUvmDFGwjZzRohtYqUMSBZGMVeoyaadzS9n6sWaOwoQ
#vGU+Vmk20A8yz+zXMh444PjQPZWvISoEfJ5VXouhKIN/0rAHqSGQIzaQ4IU9t7l+8uFT6lB0plSVNULZSSSP2kSZabSMgBm4gruO
#BzOGtWxGAWbRZLsGAGc02GlonFT6Tp2updNLwjOBixV+aW2wUw4Z4pVqpYjUhwsQuxRAQivA/ucNdeuCQGnBNEIxhTEMuUKBk0FQ
#M7R0jX5kcbipQXKnWeyyuhuiJSucacA5+MsMpMaPmhMIWIjRUGZ1lF6nVDdTWJjiI1Sg+JNZ/tJP3hBlPThjypk4W8gAQJm1QtZs
#hIG5ajMpZt6EGbtULmzQImNmUiPmX7gZMXs4UoGlveFEKpzMKW8UXGHUcgePSslcQT6Tl+alR3gQ5h6HupDNc4ENolz4XvIwVjyz
#C5ADOUZTu1RDwgh8G1aPi4JoOVVg+xBrEe/UcKCRxUpa1NXU+CFF02aFTXVhAXouQaXrWDRC37liZoXTngVObNWE1TGYTtdWC1au
#edumMUDjlvONveICEdlj8nItUyibGq8um0w2pZ3J0SWzZvALZ6bPXtQF7NNVO/RsJVtH9keGXVyvCvDCJ1S2BNd1TOTCRMkL/B4A
#FSPdGKG6BTcvg7aohwbf1OSaN+0tsYDZzIb0IimFrlesGIBbZFQFLJomlGFq9P7raE0DSM4bBNaUJo0hdhb0VsrZTE2l09r00qMw
#roBOcHhhd2OjdZVYK6H2+GhnAT9iZ6bpbXOg4pN52Aob05B8pVDTJP8GfkarwN0YZs324g4KNkfohLTCNWe5cGTHigVoBE2uYG2p
#57OVSk361YnnyWbJlJ8Yw5ZbwSDkTfytil/BHuKjF5I/JDfjf+mjNgk356gL14R5poIDKMffEAOo+FlMwW7a3LJzvoKgwKwPIFaq
#HYe1Uq9pF4Hlxd2bSpI1Mvwn5E8sVahlpypXgd3b0ErwT0C82Hxzb2zvXOaa3G/W8oT+NXwmjCGKtuWUQzjlGkY3bDaN/9Pe1YXG
#cV3hM7M/Mzu7Gu3ORo3dWmasxImMZWnl2I1xXYxjK41orDiW7NoEo66ktbTJerXeXdneGpPdB1PyEEoIhZpSqCEuTSEhgVLqh5C0
#YKihfig09MmUUvLQh9L2oZTQpul3zr2zf5LzA20o7Vxpd+899/zfc8/szNyd26DVyvzU+bU8f7Hn+nS5ELTkmKfOpvX39+B8qyfN
#AXipQUS7Vgi2UIX20wT+Jmk3PUrjlNOvScAZshetHF/SHnyGZqhAl2iNanSGKNtpPYmvsWV6jig5KZTMgR6eoSk6htcMzdE0/nxI
#8ekwzYJvh5aabx+mVZCXAVqEQjUg1WkFLb4FWKAqXZB3hq529fUz8uki6gv4rFBeuJVggk/baBn1Oniv0pJQllBbFpXHpFUUCUxX
#AmVDpNWkj+XjsAUM1lDBzgGHua1I3zjR/YuCM98nh058Rdo+8Jl3VeQwba8OfpdmZ1Grdtm43iLKr3e7T5fpJF3RXPPCawmt0S46
#xjkBnLF1Xi0K7mV48wrtYHvm5+4pnbHZ02XIqWtO/LkGHF98pHRXWL1yGoIL/puPgVOB8tLPUvLAZy405QvdAuDKEwXxXg02sqXL
#XR7Kax1WNPfAh+Cf7ZY7L/ZRsiZ+z/PjbxJl+cQIRSBz86IeOwWrwpaSjCw/lYR7Arp5GXmmXRY8+kIdvBfF/2fFhpL4nWOOEm1p
#yeekp8QcB5YEylqjNZjXsVWTqGcdF7XVlKhoi2ngWcCK4n/YkVlBi/HbNlisVUV/XgIG4853RSkNsIergPAo0WBHCttGme42zz+K
#iTaDvbOBrDXlycguMgZZA+ZZV1olC5Cpoo6lFfVsho8GquC9Jr3g8cCE6FpEImDua3oGTHRr+/zRdp39yv3soRUd0yrGLtNR4XRF
#vD0nkDmZAbukfli3+HNMIDPS7rXJF6srYr2yZJyM5LHOXBt8To+wmiN8i5ipKdvRN8CgRKfGnq7L2CwIL7KWJWooyZ7QMKlr+ADX
#21SZIJ8oTMjNBpAAx+/CUjwAGQogHSlBfDNUjUMXh/t7e9p8Hul4QM2rczryl7r8HIzDrCwyp+H1WWm/HqcrEvd54bEssX0Oc7PC
#8TBckRHg+VqGVvPi1XlS0UTbfTotulXvkS9lpp3wJdNxZi3pcdorWZpxla0qb7PGJYweZyLmynyUj1h+oStz7SCa9XHgKgu1ypH1
#nvzWyY416eO848uxKMh2HLF5ncGKKu9t6/fluqyxfVE0K0lvkGOXZCSKbc4UE9xtHP8V6VkUv6lj1AQ9C9lco+wpzIZDMt920VdB
#3UB0P4Hxm8NhGRzyQZ6v9I13vwYLglWV3LWoZ+K4zLuq+DMvsaPGpqSPcFWx+F7zvX2MTLRrSaapylyknZ0jIks9D8qCZL0NfLbj
#XjJqkiMrMhKrkul6/V+TLN0ABqQP9sYL5y11hBJPSja/xDwe6Oe6gUZEL//0O39/ufiT6R9U3/3N8PDf3qaobxg2jjZGDJVMhpsu
#v8W4PRyLD3lPG54tDTeOd6/5pvq461jmkLdmeA2vEfNNY8sm248Yruu1huwhr7UZKLfcnGEa0thKmdZwzGFg0PuSNF8KmreleTto
#XpPmtaB5R5p34jnDAC9utLbL+44E0ovXfA16ALf5ruk1zM1pA6q19gKz/YGerWRGQdKwBAh8n9iALMWVHVGfsvAHpZMAnDGTjgWz
#spQ14B4zRmYqlbKHMs3vGZnmr9ghWUr7Ee98ymtNd8DktY4C301QBNoddYe3xCz0tPhBGs0WepwEmabXOo1/lmWmrLjnew3XcTLN
#F9Bv275pgnXWYK/adsQxHNHH3WLDLncreadtx9AQmFKEY24OEL8HLRH5ghmPgDgStZRtPEwGOCcwbqyuaSbThqEd5Iozz6fSRsdp
#cYUmNq0FVLatwDYrb1viKC+dsKJe2na85nUGx4TkCr83r7tW1LbFwc0b+JdxvGGrIWjesHQPmBZN24biXvNV+Np13YeslDcqQ6ts
#dZkNV4Kos20b/JNdKCw8gfDM8qDCI60X3Ug8yz9+MiJELl72iJUAnd1F1MsUfoN4YCQ5OlrXTA6AARVZaYX6+bSpw8voDa+thuO0
#sTLiXEhp+xODYYudrusMeQVDVTE8mZxEx18sju70VkKUAsTeu8m9e0DUGjBcjnSuZAVhT4IVbL6Fpg3vN3/m2hFM3IgdJcOMwAkA
#RRJWjHvQxZM207rOMa+GESGkxpEw47dYSYQgbLcjeOv7j1OEXQa3QN0Y3NpIxoa8c0YSBiUjFsKTwPqGo0TcUB+v8rpozAzHMoLJ
#wbbsY9X3OVZEPI1/Bh5g4IGtVgTmxYDeMmJu0nbdTg1BMaiGrA1i8xk9S4N9ZE6nipGHL7IRvKKbLMv2ZAb/wXCV78EW/1DYTEsW
#gDcVX6BkJf6B6uRMk0clLcOrYJmcRVGXi0qGrw5bCMYUkl9CEIJPdqkENObDaxgdN8I5BXVXQG9KysSnYtO6KRPnLZ74rjvgG6IR
#eHmtjB3U7UBASiuDamaPEN60dUi4HUW5J9O65VuOjTTT/F2m+V6g2R9Rx79yQodiHxIUEBmBaZvvcUJy06gIq9sHrU22N5ppvr+e
#mzeWaX4g/++5innS1nW3LUmYvm85Jt4zBzpyD0jHB3EOs3RywI9J7s2a2Ug2ar9xcP75zLvOfvuXl7Mf3tl192n7tZuNfTvuvv51
#M26bcdOMu2Y8FYl7iHTvBF6nLZ3E7bjOUZzVg0kXj0sAm3EHqOfNeDIRDw4eAGxy4z0THiBm7afjfTEI4Gg0zjNXz2tLx4ylp2w0
#jqHjt0QiHgwWiB5kovcdg/TvMCkmS/L4uGviEJDiSopTthx4YRORg4ln8jHL5DTVvBqXipv04cYXcRj1mt8O6tdQj/Cj6wTFtDlt
#cHJ1fFNFB89iKMtTH1WWAL4xQ5kEfQJGt7qY3u6q30GdjyVew/F1EvXSkVGy8TLxcvFKRUehvm3onSq28g/65szPfa2ar8ysltv3
#meZWqqsXa4atXUEHDdo8PjM1xxewD1UqY/oO2ZcvTObGc+Dg3te+5a7XtfEd7QST+IziGpTo3I6klEHW8UKpkOenPnNjUrb64we4
#GRSbVNUoOz8mGuw06KHO3cm+W3w7e9aO0S6DRj8Ct3cZGD+Q4rGPwN5oNeHODdZNfVo+exSfdYutyFMej/JN4Khc5mP/RCUcDRWR
#eH/YkF/GR3lRR0xuqlr6VkJc3dKLqr1GBhQeiJk2achzeoUPRvYX0jOgBBp1c7Eu4KSAoceAuqEe3AyVcQrWZjGZ3b7Vy5zj+vqj
#9LSXgNF9Bg323+ehTQZlN7pRhLxCbt/tHho0yOm6GqrKN377yh0yjh5j1fnZIvddxWu5s26VQ4cXvfIPGE+j73RXH5d0b5OOzx6Z
#/e6XdqZm7z4/9faPvlmfeP3P08xjon6uMnF2YWLmyYnVhWcndMxOlAt1juqufZMqSws0+8Sh3Xu/SJrPrYOaD3Q9Sqe+te3Q76df
#+etjU6d+eLUj9+fBHjcblB9f7W7NY+odKZWO5os4Ja/xXaZCe7OmD7eDR79Jn7AYQrhJPWKhB8725zaAc+G9Y059n+gds9Pzjsk/
#wzyJE/x5vE/RcdSm6Smc5M7jc4YeV7vu0FvRP/1T8TF6eB7ULQ72LrZSjgjWSTlBflyfPE3jxIov7nF5UKj49DIvl11LXSe4qrwR
#9eW3d7OAV/WlsvWc/mEwTq79twensvzD0z3kAH5YTgfVyW8DFukLaigbXNmmA0ITyDgip4mLIrvSo9tGtDnk5w7tSX35qUMz2XXd
#PSeyXOBPty9AlOXiRkfD9TLGcfJZkmd74OAA2ieBsSxUbGUF9rGmy8TX/FWIHhEZT2l4UcsIdCx/IlnKj8fktH0JOHz58OP8mONz
#hj6afo9Mdvlin/jukFyqKoDzgr6Ic28aRfd/U5rqWSm//kw22wzLf1vZYP8/BZCd1v89Mj5u/89H96zb/++R3eH+n59Juez4/gjv
#Gj2y3x9px8DIGIP1RrDcI9uEKmheFiUJ+tSxqZm56Wl/wj88u1uIFcpSZzUa4+nFgjWfN7FuyO7shapfX/XrK4U2pX+xsODLrtb7
#/Uq1eCFfL/jblgt1Xh3BW14Xy2N+qXih4KtFU7UxqYBZTdaf+Pnykn9W1l8Wlny5VV+ojfvBKlzAKpCpRS80RHQpv1YGWnVcab2o
#FzxB5Wdky+zLHc9oRUbG1hmH7/5+vq3xarmwi9cQKY19UZ53kmdxbQP9UXwBvlgGcqnBbmisrvH2iIv4XrtjnEWs8bJyZr6tS26+
#VMS3TdHujH8FCp7RWrOFAu6Mn0zekTPOlY/d2XV84uTU8dnpp2b+gzH26ff/zT2Kr87h/P8MyuT47nD/37CEJSxhCUtYwhKWsIQl
#LGEJS1jCEpawhCUsYQlLWMISlrCE5X+k/AsaqB+IAKAFAA==
#__NEXUS_PAYLOAD_END__