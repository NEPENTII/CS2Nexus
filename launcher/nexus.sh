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
readonly PANEL_VERSION="1.1.0"
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
#H4sIAAAAAAAAA+y9B3gTR9M4bnowPXRCOduAJJBlS664gsFU2xSbaox9kk6WsJp1kiumm95b6J3QEzomdAi9lwCmt0BooYZe/lvu
#TneSbMj35v09z/f8P79v0N3e3u7s7MzszOzsnMzH7b/+5wv+gnx90a+v8y+6lgcoAhVyha/CLwiUBwUGBbkRAf990NzcbLSVtBCE
#m8VkshZX72vP/5f+yXxIs/m/TANo/gMCvn3+5b7+QfL/m///F394/gEOrDrVf4sM/vn8y4MCff9v/v9f/AnmX0Nm6FQmo8xsTP03
#+4ATHOjvX8T8g7kOdJx/f7kiwI3w/TeBKOrv/+fzP7pLXLtK7vXcwWWlDu3bdAO/e+B/35UF/3a7qi/n5lbVrUObVglZcx/PKzcg
#/vfahwZ1OFdJfLhZmTGDJi2KiW5bd8yKlrpj1+MnhR/7vtUM6WTv3Kc7L2+oWfjDtPBpHtN7H5UtOz39S3iVMeN23G0Se739X29e
#SmJfGjvOzjy58/783BElXtwx+GZNVzysmuK/L3n5uXetD+3aeKjt+8pJlc1za3mNu1i4c9fJv/62nc70+jArXHPq05xpr175/vB9
#lbpnWtXaUfLVX+8fPq6ytvKS9d9XzzGZg017pnk0DLmWESg3xnTwb6tIKqhc7k5wGfMbmeH0ItkHn6GXOjcaun99La84Rflrk9S/
#hTSOaOFeLmVQmWfP3p6uNKLr49rlhu1fX71tSmvFlF3tovbpLlULbTa4pzEo85rv64Xl/dJf3TQ/rug3udulrU2OjD44ZM+55utK
#ve4y+HjZzKclYlpf8dv7xm3knZSZno19986bP61O5+rGimdbzq4xOJtu9oPtfU09/aFhcP1Z5Jw/th9pq/puyu0qe9peTfHKyVyQ
#EZM3Y33vG7XrTyi5bvTFkSdunrAaG8oPTvstMqXUljVuOUGZv0iOHzdVmRCrfnZ6UfqtV+LJJ+Lfvuv1yk/aosHYS6W9grfs3VLu
#3NTqCzKUVeLXZM/b7D7pyIlrI2Pm++xdP+twzsC3l0693Hx/wvUBY2avNg5RhR5vfHnG3LdLA3PrNP87oEdWWliFguysL3vzIw0D
#phXe8b4l6vg+22NQ20yzfqT63M1beTPV3R+mLW3WUjNsZES3ckkNzWfbXB9X9kzauxt33CdlWMvMWtN2Xbm6S8fNWOxW9t69iqm7
#gyODdQeTfIy2nIIjNWbdfvXnzM23N84N9+1VT9e1xKURmYrExKND9p+pqm+2sunhn8scb+ZG2zbs984LNQfXG67+UX3pap30Mr5Z
#5R6mfCxTf8KIaupLN7377x0lGTxyTsNOhR61b0xP9690xHfqHwceL1q+8lHTmi1Nzx7uDYsocdM81+1FP8Wsyn62E9NKqjVbzr0B
#RaNqK+b9ceL+jW5uW+iGByvXaPyuS4v6a1sqTlx99+nGgM+Vyjw7emLEwAqVD5WXl3wiDn/z+/1+8W5g3k/pz6XQw8Ujl2hm6nPl
#dRv9/ZD+Ihm8PVMXuLBEcH1R20npwzILzy9Ibja41cg+N8193YY1DOjWaHf/kr+XHnmn3o5pf9d2v9l1UslRe24VlG78qPFLnxot
#TadfFi640+3Pa9dWud/IH2QN+dmtx6Sg5IjSZWe0/inm6MWSC9+0fJp/vXq7EL2fVOx2oFNq6ucz3cK+vxZWIvvFwrhrOd+t7Fq9
#jHuNAe8+7ivz8szWzM7ivZfKVz+zIv3cj5ELIgdVnnzr0Trjk3ptkraVnFB33MGOj29ULDts72piZalg0+TmPWXnV/Zs9HvrqOdn
#2uXHTtBdX9zk5NyI/OiYaneX/r7V0K/6wMUpe6PEl7ZWff/qiWjH8sOjzMP9qIKcv5sF/9I6YM3Mx4PW0PSb/ivPPbg/xKtlVPLq
#uKSmrzzE3ZbOXHqx76c3zTr+KJXp9PNK7prZq8nYI2lJWw+mPElOn7RvcmTnfZHLdy9dvzxuXkrzUvEjbGnmT7P3PzrRv+wS+R8/
#DDsz6vGAz+Xca8vGXL/x94Ge3Vft6WP542SZbZObfSwtUeT93cj3u92Ga2MWtK18aNvG1JsPJz1+VFg2OLTvzKj8iN+uvhv77NHr
#BoHlI59fTL7vEfSjT9JQ79M3CgyHZMdn+1V5V6Fgy/056mTTeY8qfav++m7jfe89T7e/Xti/S1X9HzcGfYnu9ePJSXNkDa5U+OlH
#79MzJr4OCH3z+NDxQnry02FVbo4BXdnaJjUsqHpXNjdENcP8ctiqKz32frq+c/tMv7Sm/fN7tJs1pYn541v54RPrVYPcP1TOqfLy
#/slq16d6lx55Yc9feeXk2Zcr3s3+klfwfYjiy7Wrecb15T1+mFv/3l9RE/vlnV6WmFmwrXejZ/Wq0z/MCTT+lnOvd4t1gxp1F4/w
#vpRW/WNT/9XlZjT3KdANW9Wz3b3jvdd8btChQ4eZwQOlTcf9MPbuXXVwaNs6S2aWzIqkGs0Xza2jyNQcnz22ZJkKff7+dXvm0x01
#3n/68NqzyYFVG6Y2TZ9WcseYfr+02/ai5kzF+ao9WqRVeRw3L2R03JMrt2/nVzBrLjV+HZP67Fn65TFr/JtnPDxbc+f7V/kjR766
#UEad2Hl2cMNjM2RbPsSIR4Jmtm8PrRdoHCpL2j/Jr2fckV9y37+StB1fZ8Qsv5+u7LisK7G8++C5xxdE5t2rP+DjEdGU5NY/XO5Q
#/aDq3YYmlf1K3O0xOKF9tXr++uMxe3xXX93SrnKjtodeGy692xsQ7BVXeHQFtfrCvqY9Vz1L3mYpE749s3XKys7r1M+jlm8aVL16
#9fVZZ0pOax7//c59v1Y4Ksvv3Gn6vpPXPpxeqqPBy5tLnm6befTVrO/Kr/XQfZw+6DM5Z1d6r82WbUmPcyUJxx6N7/177If6fUyj
#Dl449mLTkWWnVvX7NOLPehdKlShxttnNNUk73ZNCM6c92Til1PLeJQbknSMPPNw8ZfgCzdvkmSvj1/etu6bXroQLP+S8Gzjlz81j
#31T3qH33+aLwuPwNy3zf/Th6SsSwy7ZH5IMxv+9LfSINPuA+qUmnHmv6boyb8uPIxY2vbP1US1Tj2bXlip39a5W+P2jnxvOzX67/
#8/Vqw64BuV1enOsst72Xkk/Vo3efXNDuU8jm0hfXXTizo+SksVM1y+q3sPSq3+n1pz2fP1Vt5DNxFjmhx4GzS9bsrj2l8Lfcmzlh
#tebmVFz2/PnfB07f8ro+RhFwYPwPQacHS/Yu61R7EeW/1o06WlZ5a8qy9j/KdhamZyqVpa/Y7k94crPXvdW/rE756DO18F2rphvv
#NAzPGd600qNbE5dU1t2WVZjdffDNSV3I/Z3+CqfnhtNlKz26WG3aYK8GkZGRJLVZ3SMi93XFJ5c3HfwlMbD1WK2lev0a9YfOou/1
#rvH5yZWBrbXmANnHQPPLe7Gly3XfK6uw+qfly0X3fPqO6x94sLtk/L0eg2836UgM+NR0rGh7p1rebRb0C5/7vkZ8ZfEa5auC8vrk
#0789Lhg+vPT5n6uNi/yybmXSL0ptxxIlS75IObblSdb9eZltDk3aU+VDuu9PsesvNRipKjNve8b+N5/KzTwxP+/ZzRJDd32e0kD6
#udTahXXLHJ4p9xr4KU/0kR5zaONp6fkh24KDTJe/m/BpUd7FpSvPldnYblxaz18WH+2ZfPPzztzTJWd3cTM1arRmbN+Ji6MPvDQ2
#ihgw+ODfj8qnv6h/qNWiamNnSNuV9Vv9bHT1Q11D/XvV/EvTacXA6jGBfw6N7nTcPfLEx/EPL/6xz6dUjfoXZ26LeOBXe0mv9beH
#To2qcKBtwi9u1UWxrd6514z+ZeqJG1v+DgoeGLNtalLPYYG/PrmyJfBRyoqPf/SsE5AjPT9hzvUTeb4JHfe3ja16YeOPhfJPHwaO
#DFjdc4iXzzTpy8Z/ySNWv8r/c+ZifZOF7RMDei7s8qQhkXZBf2nQn6PMYT4Hxz2Il6tvupmn3bkvv3N6U3aFM4/Wr1//nTTp+8yn
#V4fU67q2vL/tYMzGfbunzwuz3Oo5/2nOm9/ujb/db+urB+cqaNb06bqspL/hQlT7Z7XuXFowyD0jsl22tlHLDyXo5y2TEz53O9w2
#3muV3xDL2w+qN9dLLd4Y2WDLNJ9E9zd/Nasdcjx7zhtFqqbpo67kwaAys6JqljpGhLyvdX74wx6DdX6aOQF5K773qz3w71aBA3c/
#zRnbT3Rgpr+t3vkRq2oMtmQ/WBg9bu2coPI1J7Z4OHxH+pVBN5rmzLta2P+Yd4/x5dv8dOp6qZG3/viDehEyK4KK/DRz3tuI0u12
#TpK0mX5PbD1Qo/Pt289657f8PWFWlxPuvtrDExfv62x9enlWhd1l16ndJ2d3amXr36qm+7PPH760No/KUuS+/XXz7NgCc7Tnvovk
#2FmDf5u9uX+no+EzSnUXt9y6ruHidC//JQNuLK8dfHlxuzc/Fwz6sutIWo0b0W/6VhL/7Fbjeswfgb/VCbCUDsrz/+5JYduJ9SQ5
#806W2UDF7wrIvz3n5uTIia3GzvipyubDqX03ZHUtbL65692V3icUr/8qzG9drsq+M1327/r173q9/q73sCL94m764fLL1jT8/LJg
#xcL40e9KfNo9ckqdhURdP0oxp3+7A6unieN7rcmSv3p8rdyFs2uiK0yTvFvfpdeFyaXvZt94+KZ23qMZj91b/lFneez84Xtbj5yz
#43qBzm9co6C2Z+gG0bFEs/PNZlzp1OgoEPMLm4gH/3Ix8+hJbf9hlw+PKV+wdWvQ5cw/SzfpGlNCoT5M9H9fdXdMHdFxos+SpA+V
#D8/5MWhtXH6P/Svjm47uZypcNb2wvqkdWHBONx2lcYs/PW59l3u7tr8e+uupcXOCy8/9MjM0d8YKr2FjZndN7LOsS0yJFR3m1PFX
#BV+ekNG4xsmuu1t5mee3fmN5n/C8WYO9GvXeM+LFbrM2qquNf7co1uf3V2dCSpWrUu142Em61vE5zR+eFv/Qq/LTXR9k01pWK7Pw
#+3vKcskJo4/X/fh51vXcKp/KVix5v4VVts70tOHUi+1rLX1tXRc0RtzSvO7tlNq32pyZf2L21qovlC1Oja5Ye/fW32sqhql7ul1+
#/mP5iv7Z43dEzAnUD97Y0u9K1i6PgUd+Gv8o+gTxsP/K4XUbby85/MKaJv0/P377KfO3A5Jk0Y35Nd4/a73p/ZZKwadOLLwWmjlz
#R9vrG/u3elH70vSkEsefvPXyurC37oMrv+w2PzyxKLe+R453cOPSFq/VJZem9pvsXjOy+s5dBzq0nn/kYrj1bXtzyhZj2rKjye4K
#T9GGZntGHq9fVXXuYKWoLZM2dpvT4HWXRrKe988sGRmVMr9OmRf3R849vMqtRjnZwYfdm996fLq8fLPIZuuxto9sYNd7OYvB+0M+
#fUh/d3bZ1vmRua/HFVb0TPVI3lXl9Hq6dkHID55e6X9dLdw6f/ezNzeCc+5+d7fN51jz5mZv3y2v5lNzSOVd7199N2w1kC5bl06Y
#cfJkZvj+dY/y2/159sDYt7rffIeX7p5/9fCuhpFZ5kbVD46vuatvtf6y5y8vPddePvzr8Fqpd/48sySqQ+6y9Nlxz183bnLgfeNt
#G3sktPyp25At6rnLlJ1u+F1vfsK/b4mYlE6qkfLIifuubT/bnJhYp8Vlfd069KUXnzedXhNVvqDkpdEFhybK/xz5ecqhD/df1X5d
#qj51yz2l5JymnV4v3pzWo4L38KVnd6lE88N/8u1b4nHMRGNS4+WWbr+XBgVSUHAcrHBrH3aNGd1q8yPx00rp3QtKBg8uf+fgzfd/
#P5py6EuwvjRYxId4RfYtUd/tjz2vv/TLudbQI/dxuet/dQCdB49K3qqXJzb/ErsiKGpvVP6eybWPiPY+zXo4KXJqaMWc7E9HTk0Z
#FzwoqFrnKZsyJ50b2eDN0xbmXps+Hlu9VDOx+4f3nYJLRZRt4L7rfuXOw3a8mPJbZfmXXT+OGnlq6ZGx0WWIvQuSwpsfvbdpQPUG
#R1bR67/7EJu4drLxaoHH43JLL+z36bGj9OzN2tHR9daOnnb0brNZXTcO3pA7e17P+Quf/FRnbPXl0dVX2J5n1qg9cHG/Ra9WzO75
#7g3pfbfar1nPh959/mlgnRUPHq+/OSBiTIXI59kNG21qZmyx7eDiktNOUVfSd3qtmNQp133StGmN51Zqnz+mbMWGihp9limNfx8+
#lvr9dQDb6dXi4b8lLUnMGJO+PF658nza6S4bC1X9p9QOKm86uLj9vF3z3Dabw/qEPz3QZ8XnpNPZbm5VekNfQOXPdw6tn3LoXPn1
#2yqGbLZ0i35h8Xw/64C8VuSt5yMb3dyX9MeXFUldO697NS6j009Xd2dW8RpZZWrY/A2HLtv+/G7t+mfnVY+316uyrEXm/boHG+Wk
#pM+N9jl97W2NhD6WUtSn8EU1jkj23JozY3PvJ8fn+P0QO2dz1f5lOizquWDXqF5bezxrqhtd9tHiriEjly++d3rIo7N3o1+0GHw+
#+bC8c50rVU2fbXOWvh0QEvk2/W37AR9iK2jHtw7a5OHzsXEvTdz84AnRPay7yq9qOK5jckLZQ3JzmS6Dq7Ue2ev32mMtow706ZB+
#tmxPtzJZr/6sNqJiQ3H2jt27I3/N6NkuOSl1WPPBUWv6rL+66vF62bVfvTJbugW/zm8+eOjp8uvPB66bFh6Y8bGN+XEF8Paix+vr
#nlveoWHngFet086XPjQQdDJTvqTt7YxX3kfuDKofWH/Xrl3ravWrfRiyxaQYkemCcsngrq973Xi6NHUidWJGAzI8d1+fgpIzRzQf
#XP7qVf3bXme7ZI1xLzU2YJJf9K190aR3n3HNp5QqjKzZf/Dpne0665XLF6V+2TWK9Br4vSag5/LUXkFhufdClj8p/PTR9/byBen3
#fqkwVDopZmmnBQ0tXrnpV99VqLVEv83iM+inz70b3T01sawtbf/0d0HN3Kc2nVD79qC+QyTxqTumDRtX129R1vPvo3anbPuj5YWa
#N5dMHLOj6ceVXa4sbfb7qr2/z/p4rA00L1OX9+9i69pC3GUhcbdNjzJZQUuyfjj+vlK9vb93aN++aoxH6vKBn0Ysvnj8yCivSd1L
#xC0IaZKztt6cmgPOPb/d5cObJ9FLqwdUGFR9w8vVZcuM7gfElxS18vbZkNPV2o5r1v3u06qL25Z9tVGWG9MpYW1T2cfQgTdGXGo3
#kRBtyB3iue9A6tZJXQYe7fDbb1c15dSRe+uWr7TWI+fEXH2we2HNlDz1cO3HTsuOTs8ef7z28fkB1e+rA8vVr3Qt8WEZvfuqFTvT
#9+ccHv/YvWrtN73OV1w8M5N+vaj55ClTPNUTW1T30L/OpGm/bMP910+G6g+P9zw0bHK1aosv9n+W8suPXV5fOttk7E3p8AtVgwZ5
#el1oVb5GV7c+Dw//kTrm1O4V4+Zuswx5ObdRuUrqk8NGng753IJefPv+9Jh+Xi9Tj9070aVkdI2b2+pu2n834OHS69vSMsFiWKgC
#usDQCw/OrN6qDTu75cbA7r999KgxdtKYcTVuPA/Sn69TmDXgdKfDFUPSP9bZ1PHCmsIup47f6qkuUNyrsmhmSX3fRpLZdeLm3Ko8
#L3TYy0ZkD/XEleONZPjw6ddqnDmzdZ3uTllxvtK9Zfqz+OWjgkalXdix7HSL/JdzgYVKnnw863S9hAe/dth4b/FFoDc03rZyoVcX
#//YD/nrce/EPYc3cf9+SVM78WfWqc+St10+02tFx87aPmWH1qJCyaN/OqtayVRpFx+f/mlGl9Y2BkWBJvOXWZEyNGXnDEjZp0wd0
#Xzam+y+9gdlV9exj7dGyZT3X9S3T65gpcevtu0fuTJpasa7i5qWVGxc3sIyoXFfdvV1su4UFJd++fXt7YvXlw399+1Od8P6ND05s
#UGrC6z8LP4S+pkKuTe3x+fvoiBoxZJOuYZ3/OjI1+Pj8FkmvQrwXXfVaGg700CWtD8WBUaz/dCM+P39BlwFlCO3Kpd1bSitrn86/
#tiJ5ea3gyx7K/ZpF5Qsk2tdflvaqRr6Ir9dd3fEceWpNXb82v/z4S5dqJxIHlpoQqL3209oVz6pvur261dvy3de4lX5S5nX94NLA
#6Jl6ccFvB25tdB9SMPBJveCHTQiiSsbjwnI+Puc+bfs5aWezq4feijovLJsQ33yYZrhx3oHQxW/fvlcetT55tzdpfN2N90e5R55Z
#mZf4+3eRi1Yp5epHPom/9nqVs7Lbsvw/pi+Ju7z56eDFB8YAhXjBl8leZyuUPDakf8zChLPLO0+cl1tl1Oyouy1WJCyqv3jxz4OX
#NDz8qhBU/3PRxbWJQV1/jpF0P/F5+MOj+QcOHpwdkK/NTipQ192RN2BP13IPzi7bv3jZseOBz/88u37Yw+ELulA7wxT5PaTJzXLm
#uetOzNk96scP8SVq3G1bvduuKi/GTui9Qzuk+7JGf7SxNe3STO3+JDSrNFTQGmwcUNht9a/r6MenNs3a2HXJT2/rju8TuyDh6ivj
#X8MWRYlVj5/u/hL1JMQWfaiGrFubOplvT7cy3x05pW+fzUZVxvGgE3NuvVjWqUvzVd3dbi849uOtBw/yuy07NmrCIktOQvitffm7
#906u0v+8XHleu1ElHpH2bkOTLn6rAob0oy5cfbeiYX3PnHmrml1cW3NM5ISGZQ49nyaLr9X84prqlwNHV6u2q3KDywMrbF5Svgyx
#L0ivue92+9CjBNvPvZeUDT46fc+iaR9fxUv7/VqybpvFmeWbPQULSSVtiRMFXfv460Yd+/GA4Ujm9ezaqy9E3360asfRTUsWnsr4
#/fJ3G/d9ORX545kNvatry5wQu0VXDVzTs1yVhmFVG9x58GB0doVai7IrNAxONV3ekjZx28va7gvW15l2K7rr9omNmsff2lsrYWf5
#gdXH1AvPSol8eH6tz2z12nMPnv1xMXn/oaAGGU+vloi7XPfdS6316ZlOb/UHRk2cCERUp9o+LTtpNVWeNWv1+7D88etPRiX/DCyh
#RUlzLiyOLgi+t2jqtbob7y3sGPDyj2Yrx6leNh2/7tMbw+l6sxPcPEdl52v8mqz7bW+pcqcX91YVHjOmzcu8cWJUmcfD38RvebC5
#zSNTn5SNQ5fFnh2qUZUPNPSaOGlhs6G91RMU1DHlh593Rn2RTPBvlrBm1JPtb3rVGPj+8YOG2u5vy5/42W3l3RNzqhzr8fOMhM7T
#lN1GVKw3Kjg/SFc3zKrtGxzeUZ27a1FYrU8VO8Ud8gxsVZjYqkHOiMqNhowYL81NF69f1vXTr1Fbc72XZJchVgy+8KJ7WpcCc7Wx
#Kklg/uLYN4+vV1o2as39kRM/9XvzU/2d72oE9OzwtI7J1Cyva12VKKbN68cDax2aH5HX8dnh0d1fn/s+rlpchyDPTTkBj69vPna7
#1697m/f4pbpxy/fhR9x33v8841n1Jp92PGvVtHD7Bc/WIzJ908/WkPbe1W3Ks3Ntf4xIS606cJ/u9ugFiqC+d8ra1utXbro0te34
#Obf33FqivbF+qvZW03bPdo+7HTU/aEno3aGf751M2k5+ueW14uLCRUsvnk69sia99a2NGbX8bZVTyi85A5XGtgkJNY5Ob16ls9+2
#laWb3B70OruJv/FyDcmRI8H0Pf8pU6bcbD9G87zN5gG7mv5i+CBqeP+vkC1xTZvU2EyO7OOnORU9fVWrmGpSUa2uMzs8nU/O9D35
#zn1aC6rtkYfTmz/r/a6lR9No994b1AduLtqf/uxwo6iT67cdb7o2amjnFttHfg4eUWLYCIK+J53Sr52Gyt+j6LWxf5O51ZbHrly8
#4YpVUbg8tcqRfgvWFG7w8znc/qfvBi2mVl/QLGmwuaTk5VbDlfJHw/88RA7d0OlWul6ak29LnXPtckH16qVSD0h2tJxxeLJXuZ9O
#zvVOmL5uxIc3T8tvfuS1f3/+tIiQ5zHNbe5vlcqa5zaaLq6V9/rQ83KFtl1XafNPRdTOsXQtZQk5v6FsnxbbMx4O/iHIuKfwzLZt
#H66efTCpkqzlatOVhTeqlJr1xJQX9WleqPxSAVnqQrvhd/Z8zts3cH+t+svcatTq9vOAMsDukgwfoz6qzjPlFxQEV2wUUhqsU0Oa
#7zGSm07e/IuuH1Jj2NhJ105VubYvZ3F0vY7e3cZ/jo2pC4z326dbPTorf7LWbdmxaa2uva80fNb1Wos6U3t3bKsTlFFR6X9hEBFb
#Jz3q/r1bG6PL9epZ8Ub5wzPCQ0MyH8y4F5V4N90ztMXDozU73HmyzO3pl6eDHpceUMly/+T4Tb5pB60x81+NTSv/ucI437Z/Fu4+
#2iCyWftXaxPrnP6SO038vtq94xt23lW2bOnWdmKDKtvqBpHdZg9fUHp3r1tV5NqWg36sMbDEkucz5s+a0PPmvqXNop57bmlesvsv
#M35Q5OmHlN79Z7v8vonPkheee2B6EN/XWiZr6pUzp2ouOl0uu8ybBQH5c39O3l552zZd/kjNqb+Svnt0OfrtlfbPnv52tWw5ojDo
#z24zSxYMeVky5O+lu3a8mt4kLXDv9F5LehimSSUN6+1I2fWx39QyL++Ped3Dq0rNmuWA/tzWfGtKubEvAxt/0H95dOf+PeOOnzdO
#6/fH7btHp1cISLtY7eGtAa86nn/w/M6hLs2X/tpldrT768ulzx0x3v3phLhvwZ/H7sfNC9l7dVO171KHDnrS7OmSlMqBHepMrX7n
#U+lFQQW5jdRlJ9uWt5HFXB/wbtL4tZV7Lv68d/yjCw1qFV6p9HDBuUYltr28Wcvv1vm+Q2JtdcaPnPL9nWPfLRotaasqmN98sFqW
#tEM8YGWJy4PE68udCWn88lXSqDIdO3QsX27knailRz+OTSkY/lIf+7ZC/QmdWm6IU3zJ8Rcnlwn+eV+n3oNWunVo+7Nb/Ys3u/f+
#YirTflxk+/XVbprn1ml1cNaa5Z8/9omKUUwZRLwRB9cXDVfPOZL1peeC3HAvqcct/9BGiRUrH5KQG+ZNMt/7PfV6x9ExcTF1j/v/
#IQF1h6pnH3m9MGhB0OTqH1+5hzacX6LyodFZsnOdl1wfcF3dLSzUsyHpf9sD1Bx85IVX03P7Y5Oqr3ZPnzOv5taSI+9UXFpH8uV3
#dfs12t7T7t59u/nxlarm4MuawxV6B44u/LVlh/Kdy/rtflAP7nbNinjZfsSJ8et71WnewmOX5ENsuT23tOWbbjwyurO0R9ikbnX/
#klxpOXzd9MGpvS4N+a3G85yo0UfikpfENB1Xu72msNTY/H7LZrTdcSzu9FBtUKW42QXVmg/s/HOERU/269ny2dvGS7vE+3X4+8qy
#i2Vj2wcfmDFt7uPI0/1E/jXTpSElfvxrd1KJ9x+vlZ477taJj2dLhj6+HKdwD5s6d63aEDJgqLxJ+ui4pzNil5+bXvpQ/8OHC7Oe
#l/947gezT0Tdi5fWDHp8wc96+fthBW2MJQsnpMdYlAMqvN6zSlx2TvVbf/8V8cTq+3lfjb3v+o+m/UvN+bv6zBpBqpP15jzcunzt
#98P3bl8zJ25rv+XDnkRLWtT/gXz0xwn1kvW1vr9TZW/bsz2qiZs8qOc3+t6Dv8tWea2J0Kwu8Yvvb+nB/o82zsp198uu51f34w+6
#PRM2D97xomDbo8Ij69dL4ksvN+zY27Vy07fnF5IdLIvTiTKGfZUv7a4zY2Q7Mqhg/OlWtUtWPhTnW0EFN3cHzd+ojKzfs9LJa9s3
#tRoZ8rir+IPJffD+9fW8ZgVN7tB2TdzYeabKs4565Nw798Mr26uQ4YpY2f7YxhMkYmpy+bv9MnrtimgiabKv3qBda8Vdq0zbFhte
#qmLZpMFdR7r9VCH7UqOGe66PeuaX+Mjy4sQm2vPunEfm2NQ2NeZ8t+RS3gSlJm/aSe24jh0XKz6dEpPRF87t+VLKze3LlzYxJ9+6
#ubmVhUZ2Kbe47aKCH65d7Qj36TtEx7X5OSpl6L+9/y+I/wCXsv70v91F8fEfcrnczy/AIf7DT+6r+L/4j/8Xf2KxhAiPIHLdRTaa
#ImirRaeyikLdVSYjbSUaE+EEDR+rTSqbgTJaZek2ypIdT+kpldVkEdMSKdH4K5Va6fWgHtuigdQZQf3GYpEXvBSBB3rKSiSAstw8
#KaEnjangUkQZRfiGZh4YKHBhtOn14JI0s6VWnYGywJvEJClBp1GZ4NJXSmTo0BWszvZrodQ2FaUGpQbSqtLGUmodKRaJzRZKA1rw
#Zh57G0xWnckYwlSXiCQyVJ2iQ93dfXwI7//4j9BSejPokQGLolUs9uIB6o2pYpqIjCREoGMLZdaTKkrsk9g0LMJTlOSTKiVUsKI4
#lxA1FYWAf0iDORTgSRSG7vRWdBOBblLxjSe6SbeZ0K2nyBPeevm1CBUReYmqJAk3L1YAhjgNoA5TAwEnBSI2ITEtCUKUFkroNIQY
#PNaYLIQYv5RISgllEmHSEJ2V/cFky8DkW3QUDapJ0Nu0jDbrdVaxKFdENCdI8J8oDwytv0lnFCsloQDNVpvFSNChRB4LiNGUGQ9h
#QXC0Ia2UDJSAOx9CDoQFaAFOM1uZTDWBulYaUzBB4FLYcyxp1YK5yxIDckDXGr0JECxsHTTmDd6BYyfQoGgijAj0lbDQAHCtsFOR
#oIJfoK9DFYMOEmkuAciF1wMNIIWN5QneDg70d3xda7JZingf94VbwENSs0OyV8JNwipMq6BOeDghJyJx+9kUbaUsajJbJCFCcBG8
#YXpUo+Y5rKttFjhdlEqISYNDt+A5Gh07NAMYmpw/LJtMT9G0SFBBiFqbzMDCYGCGyH+oxU+1ApwYcK+A9UNYNjEQTWCRzEyq44H8
#tooVgNp9RRLhsDQGRNdWWkqYEEEZgWDoYLTqZZCyEoD0aGuyAA4XQ1ED68g0+B7Wg1XAq0QzRHl2VlFbOZoD7aPGcwmAWsBaRiD/
#gAAFQzCYjFYwCBGtNVms4B7ONrhVeKt1qTpYAKjHZqV4RQhypgcy+3/QRTZFWngVeO1pbRQrZRJlMhkraSRJMiznxGLAyCqEIDEJ
#xusnB3ymkqm0pKW1SU21sorB8ImIiAgoXIMkAPWAQkPdNTajCopLgjTqDGKA4Fw056yoHTCA8MjUGdWmTBmsQLFUEEpYLdmgLv8Z
#eBvIAEIFhS0hTgZN5RF59g6sJpK2ig10qoRHnBSzjqCHgOQISmalsqytAVqAHIKSnk5l6bBomHLBa7Q1W0/JTGZSpbNCzMtDuUKr
#hTTSkCjgqoRu9JAsvAN8m0h9JaJQQqUHaIeUZLKBiYKgyKwAFuYKMZWVfcwstS569AWjlxIKBeRoDk15AHg+sGC2DKYMSkyBOgLk
#5RKABVIpKx1CUICKcashRCKYLTn6vy9YHjnge4MnfuAR/r8cPgPsT+KFD4IgJSiSBhQCiAlcUJ1t1q42Uo0JKs+dpLONKsI+92ad
#2AxYFawEJnU2f36gaM4lVAD1YDp0pJ6GtEoaKG+TBRC8UQRlPp4d+CbhAYSXzaimNDojpYbzYpIZKKvWBEWfqEvn+ASAbJNMS5Fq
#vOSDVZCZau+EbDMFFzqgvup1KjQSn/60CYpnUS/vuF7wmRz2BxpAfYUTHeM7x8loxAg6TTaCQIIxzugLoA6ZSeqADKEATTJDNCF5
#BddGNWklWRWDoWemCL9lkUEAxE5UbRd3uQRUum0AKxYZvpLiJvJcYFllMmcnAOIWQwrHSMadQvQZyQxdKglULZlKrzMrTaRFTTRt
#ypKIjo6nVDYLhZCFXmZAdPGaLNOiA3KR64hHi87jYBQHOGZO8wOzDSgsWk/BO7DkgEZIUAS500rKMkg9kkSwGBVgNlDRNOwSzrPZ
#ROsQIWp0WZQ6lCVlXzD3XB9wrmRgqimjWmwlccs0UjbFaHqY2WCrU1mUqrXJYCBBdRHEowhNCiAzUq+HNcHrDGMhCuCJHT3djrJC
#rQjRI24XjzoDAKs3qUh9PMAfmUrJAPd1sFIGcZpdqwF1MIGAFVkNluAMB1rg1m2EXX6v8bjXDHuvgr5oti9YpTixSVtNZjFqBOnJ
#cHGLJgExI5kFlkHKAmYEItCuRjNqHlSgAQnBX5lJo5FwVxBHfPWa3x2VAdR+IKWlhMbI69Vso7ViCDPTIScGYU8e3DxpdWogKIB+
#ibkGrG9QRQPtczVItTo6A1zE6IBmY6QsYlGGjtYpdUDDzAZrlTGVAgxfXOPskLihAZs3TWK/RB0DGiqmR8piMUG1jcK9MDorwAZY
#KpAMxghEXRlBUWocCU0XQAmiDrHtRLhYpTfRQDsT3IhFMjJDBJZZI58aodi2AXmPrA8yg4SmanNoARFA52GVYEiMYrNOLQUsbQAL
#QA649/NFeEgJo80kEB96kqbDPckMTwKxXLint7c2pHEuUAzE8B24LoIGJHmh3t45oDwnz5zlGdE4F5gnYkZbYKuJIoECD4oMYglS
#EJByILOaugOGtLQGywWYAKZaXuNc0Cig/pQwnSGVoC2qcE8fPAgf0LZRBXSL7t06AOY0m4xQXiAQZP3NqZ4EqbeGe3oSagpUAt0D
#2KFA9IxIAYwkEuWF+cBxRaTYrQaLIRZgJRyqrBF2JRFCAuE1xZgyWfDsllXfvtCoEvmAGoydAi/NkGl45lc/0jvH17tFsjcywUQi
#Tq3qFNe5ZxxaidRUstpGWxUAtjbgl+jQAZAIKDToIMOC0lh0gQt1RmByGk2gtAO+wsVGWxqsGQd+cAGgAYsZzBso7Mxc4gekUaUD
#6ALlrfAVW2xT6mhUCi9EUiALQTF41apLhd31wFe4NlAHdGC9FyXAX1ykArIBgtAa/uKi/kAxACUdwQ8uSAXV9aCkHfzFRWpTqtWU
#Cdtqg69AsYpOBsJCp4LNdUYXuFBnJfVQi+0Af5EGwEkPYIpbrdlgEsUGvhYBeYuZXfAAc5eHkbMoRCJWiUCzkWhM4h6xBTwTw2if
#1n5iNTVARQ8gLQPUhgGpqQM02QNInWEAbbNoBqTlDFBqTeYBOdQAMtMsSfZB884QiU8iJAVgKuj0QKCJo0wmIE6N0FNgFmdC6stM
#9E1y4IjmRKaMBroJJZZLGPtXRIiQPsUhALzf2qQ3WWiEAGb4WjB8xKUcCuwLTGKKltaLARfnEf4BQCcPbiJJkRJMoVgLOvX3ZZT1
#PAIorIQc1kgSyGzQaVRqcRgHwhw5Tcw0QCXyQAgADeUrNIDLQwgPD40US5kQQqyB3K8kVWmpFhNQ7rx1BsgPNosesBps07Uc0Ejy
#RBIpYnWnd0UQmSl6oCSSFm9AjWrIAGK5X4CaSpU2zlUB3OehX3kSEOXe3mQIU5iCFSvWDWVBlqEBjEgPVz4wvXyJrsTDRKjh8J0S
#ptZlsLIUtQCa1tNAzCllUMBFEiKIAhEWUZyohY/RZZ5nRJiSkap8apcAcaaMCPMBrQOJZneFxHZuE53crRdclxN9+gFOg2QIFGQb
#TepFYC5AIWApWKg1AQ0SyBdcSFpQIWkx0BZA60xpaioqTbUZU4EoZwrVBtyogbnPwZ3ksM8hN6ASeMGUQc5AZfCCKUvLQSVpOSwI
#mbgK+GVKxIC5kgGTJUtQuQ70mMTjfgOggc4aYJMiQkRuExks47gZ34a6pFIa8h4iRb5zypIlJdKQd4pBpASbglnATATrrVHCd0vA
#xmXQSZXm4JJAD0xWLWXB7PovuQGhw8EGpsxR0debSHUMeCZWocHbFX3XZomI9dzr5MFGHwi/C3bCTTUnRMgmEbFC1CIzAeXHqrWY
#MqH9meDCdmHcsbABxjjiqa+wEfgEWW7QY8vhkxsEKsVvcjoVe8EYCTKmD/gTWnQttQ4OPUGWDC/gqq63WpDob9xYLEqEdpM3REGS
#SMJpuUbM0EYHrwCYeRmsDzRSGXyF0fmcTC52ELSYp4YzHmmMJ3HRM8FOL82gXOLaHOS5uLER8C9RF9D7CSVp4S2uYJG3JmBrgGMh
#OHmwc8Z5m0Zl08gRRnNWrhZJRnaFRfVlesqYatUSEdDxB9aYcKhjIuuLlYywCU9Cp2avSIuO9NaTSkoPZSEUfoCtgPEpY5EE0JMH
#tU3cPlxGVVh3NZkR8MhsZN9VgbqgKlKpEelAqYsBoNSM6GVkLBoL9HID+YqbikhhF18RLMSvQS2S8VYyHEewA+PJe7MBjwn8Ailu
#s1pNnFptVrKPwIU12wxgxRWYsWtJGuiUNjNYNCijjSmksoACq6bAaxpST1Nw/GQGgECGFHnwi3V5oMfnCXR4o4FVzJk6ElYZDqMz
#UpEtE2XKCvf0JXwJeSD4vycwdfUA9UYgDOCaZDGlAQBVNosF8ANax9lS70yd2qoN91RwBXCZVZEAcLQCC4ohGtnyiDDoHiHAWGL9
#iEB9AAH+5x3g6QPWNAAT+BejIwKhliCEaNV7EhYTXCcRciLCSN6tDpi5noTWQmmA5WCg2JEz9KMmaS1yW4jQEkoW/a7WajXTIT6A
#RSnSoDIZDDYjsBll4MrHbDEB/FBIE8FIRZUAlTFOtXDPZCWgpDQAJoXQaDJDUxAuPnDvyEJZHMBC73MgMaQiJAtHKFnOMTF8Y0o1
#2awOzeJC3C6DT6wysIoDwG4eQQFaYqmXZNtNtwHjlsMjaEhndIRZl2qEu3EYaNQWdq2auwGJqjOCAbdPiI2ByigUlcUYyCqg5aYB
#ZR9LU0q4n2BW8ixlu+XrBTjHvmdgVtrVX7OBcfKaDXAhsTsWPcwGGRod7BlMpNEKJBwtFsHJgTUFj62m1FQ9xTxEXjwACXSjtLIC
#QxEgEzwTMCVTie+IdQkPAtcA7XgEDwsFO0IJHIgAEsa058BszA7+K9CIkJBg11LYrQsschTCufigc1bkA/71IW1WrQ9TQQqWG2C8
#w2WI9cWAFdC+xRpKpJqgKcw6H1zggXQ5j2QiJLF+gMY8k+zzSSL8UNCbS3aispk7ldWit9/RWp3GytySTLtYr8DMhxwnHiR0s/Gw
#BHuDqIMbQHRPndW+CgNd5FtfgGYIwhmSTozVBerBZd7l66GoIhwZvBc25oWxDx9Clx1cc2RQNho5L5CPyL4PAoS9hYLs04bSkDY9
#9F8yqAcXLvYNmH0PPd/jCiBkdKSo7A5qBiRkaSokDIVSegl4SUargNjRdzBaTT3AIsG4lwIcNxyIoqCCLaOx57l/xUfG+eL4MkBI
#tDq8WSmCS7QIKULI6SkyZiWjIqmdutDqD0DAFM2plk7P7SoOGJAJzhfStr4CK1B61NhlIQATFGMAo2mw/lGiIiWSXQIUK5D+gSDQ
#AGBpBnYE/b+kEyKc8FRCMKV4U4NxiRRNt80JrgyoMlrEl/Ah0P/AUEyW7ESmCaiLMZfxgA0ppI5B9y++SxLjAA4RwDZ6nz9Rjuo3
#oDYLRWtjKYHKard/7KINGLNCaQZ74aSPBc4Nu8OC5lTh64vL0G4Ld8Ws+wALSBDiwlA2qgRpW8BQAqaHL4wfcIpM4LwEUGbaxbRz
#9/6+QHG2y1q7sYlEfBGGCLBy+XYIEwIjdkIFlmV4PKgSgBfbFg57BI7YxvOAMI13DYQMxewlYRGSYIJRFb688AQzsx0ioBtuPWcE
#nwGzEbI98c4rQz4yPs3waESEVRWR3QMDVFY1ZYmBpVBzATKNomkdMrDgGAW12gBSFfMWTBYMpk0Gkm8ExEA5QcG17wo4Qb8erNz/
#ajcivvMBtxcFzHMaSCpkorK7vk5iDNgXNOIxKZ5KRmyE/8d/RHx0tx7R3Yiobp17gkt3Hn8KoOOH31iRTxwYVyFsxBYw7OD2rB56
#jNND0GBpkwV6sM3gUkNmhGDqB9cWirLfkBl0CIrZgIuDBEaE0Vb8ul4Hr2DYF2QPSs28g/eUMZOgLV4zaaEpMd7Ig6sLaBJiOjEJ
#sgnrKdBBqQGEMuwPIlesk7jauLVv/cG9LVVaCCukcK/MtlgGvIaxbQK1OQUUhuHNa1Yrp20GA2nJBiaPVs6WZWh5irlSZtVZ9RTW
#yrVyYGUh6wC85xnR1KikzaFhPmag/uNmoXXFt6ysJpOe9sQ2F7+cpkiLCnQTpjOabVbUYjprtjLPCESeWpMeNMuz2aHKDJ8je921
#Wc9WkaEH2LAPS1OqI3zCfOAPtlVcwMR4DCCl0Kx9BP2+Zs+vvqPRWx3fcGl0ISeRBtrbGQz0QM+haYEJzg1DA4lBaGwV3yig229q
#FdRzYcM5jU6txoODbOLkcFCrlfanUVbjV7wOkFeUpqwiHA9FTiRoWzCNyAvB9hoDHwjGhuqb8dj+9/oj1GrOH8GiDQwyEckpEQoo
#AcuqKAl5qdKwl0o4Nyaz1XE6cHPYA8VQTAZEdRrLRaz7ChXiZcosynPGLvZP84hH6M6yOwOgKOAueKPTk9nIscAvU5EWNY3JibkU
#Dr8o+oDPeeTROFck4M40lnFFcLmjSKs4kIORpHVqisM4MAt1egwAe11El/gxnyZ9UFMRLgerBeoLQ7ZYBt0eMRlLIYK5ncrccl3A
#V2RKtKYJCJlrIhrGMLh8C0eWuHqnrcv6nHhxrO7jsrpd8rJvcEOmKSZGiNnkV8IptktTb51RY+KjVE+pldmwHlx5FKgivOb6Qw0I
#lh4FYCjH53qw6ODHZmfpZUhFXCOXEgop4Scl/DHD6DDDAHtZp9KDWdP6ObaqgiSuQ3sVjKsL1HHunFfNzAIBaIFp15krMIDMYOEz
#3nDhreNoTfpiwNfrHF5GwKB3wSNh56Ah6GZGE+RqsjRkOrOIwQunOdKk2+cIXnP9guoOMBcNL+YaGtAYVjiErdgxmc5QF1OLj3Vh
#RdKOcrZtR786HnAK0EK5zQYoW6L1jPGM7kQSGD8AG+DK8a2IZ1rQWmCecwHhfCdNGgyutCLJCLRKfJOOnTPsnqEVSSl2px4FwIrB
#PeQLLGahSgptJPv2IyxmqiAfktgDK4awFqsigqVVTMt0agmvBljXURUZ0J2yYTRVGNyyJLOYKunwIXiJMahFBEQn2uzg7uxbwng/
#0zFsRWdU6W2AocXpEomEWbrQ6FH4rhLhh1k9jCJgipOoMxkKHaPgbiBpocRKvGcADHOmKlzOUGVw4VQXggGqgit2VN6gJnON4nzE
#JPTleBNKhA7kHrLPHSSJ9tiVhnAPkAPAhSEByNYO8fEB9cCKbvVpnGt3MZhoK4QxL6RxLn4hDwf9oP1dwYZWLJRvYqHrzoDi2GQy
#GWs2sEQAOQJPs0SSZPfhseTgwZEDdBwaaDu6WWqQEBzp4Jq4EXSUBQLi4ChPTGQMHrR0oW1keC8BJguAzoA3ulC0UqIBmEhJEsy0
#4sQ0YNMkSQS6hQud08CujGmcMs4pnqwWwcDLaRJ616qD8ziYcDkYQs3u94URCuz8c5yE1pCVxTAQGdifwrmAeIdzD1lYzPObQobB
#ZhvnC7U/Q5OFO2VbI1jpITSp+CsOZTBbs9lxslPOgB6JpwBu2NA2vZU9DwFLjEiAAkJzfAOg3uKodiudNW0omEGrlFWgrKH4SoGW
#z4WtcVs1djGF77Dv1dU4Oeql7RKQcIpTwTJDSphVCOVQ9IBh4GMwYJrlMKzbLpx8mBrobAPEB3jaH+72siwrpiWhgp5oA6Be1HIm
#aTHYzCxW8R3CKeSZZHReCiEQ2QtMDIwK6vUhGaRF7O2tskogtmgZrQIzkqyysioNaKLIl4TvcK9AvKJtO1Z+S4S4ZYgEWS2UJYOy
#eMNGdOo8T77666iiW0mlDphI0GphuE2HuIp500lnp1l/NlyOKH0eL8oShh/Z46XwJMFoJE/W+HAw2rU2g/I/iydiFg9eTJHLnlQw
#jFpoCcANGlZhLrpVnr7KbJlyuHfSTZluOT2P5nasQZFrsIABZ2XGxZErHguvS0R5zEN0XgjQcghD0jj4lMgrGhxed0rSAj0hLGqR
#wQlmDDBRXhNoXuiKe1ljMiEDA3IGBBf+wj7RvWDTXmNxsuHRqVMkeIQqBZx1k5Gbc0R9qK4LE9/ZQsLurVwUCAwRgtSNPGQr3Z6Z
#z4mjxrn9MY9yW8RIKWZ2iHF7/bUSoQkKq3A7xIIwXL7pKRBxeY6LDNoPZJcKdGyId3aFUQsJGfwROR5kcTzCIvfH51rUlB4ejOIf
#iAFDE5ybgcFxqUAB9GdFnf28i7+i2OMuDguexQTP1LW3GvRspBq7oNmVIlfBgsjXwcclWq4wMnnowpI21QLd6WIc/wGFv5RAkhCp
#BI6rFF92AJWKJ3msKhj5CF+EcgKaUTwGcggcwQ94bdtnFvEueoJ3FQG6AnGsq5kxL+wQWCyeQrrP1JqYwBYzjmsxM2EtCn8mrIUV
#NA6hLELAzLI0YPbTjvCaZWoKrG8uys1gOoXEyTdQBCMlIohAR0wawBqDnEq8OVPLYCl7dJHfgDdoIM8+lYKVnlNc+RtYtAzTERRV
#iTxV1MPC6T2C6GZuMRPzVlhka7ArKLIlmKURDMjXcUDokcPcqFwvwpw448atymBMcReCzWp1uSzzR8+aKs0daYXQqj0dpbqa4SMn
#1wivRlpxD9XFPYRk4eRCSeHgA4zHjNgKTVMLazciQjfLIH+hVd4PPBRxugwKSOZeLf5Nhf1NxxdpM6Uq8l1onCjQJrP9ngeFAe74
#iJzFFdLP2yCT2rWCTmOrmTGSjWpxFuw0S6jOCBR3CTrtgG12gZYKSNUhjqAoDdVRzwTizQAP+aUwxiBRrDGIj3TkMRLTJSiOLlkU
#n8J4OPHlN6ylahzWgv2Mt+dOL85pTFqs/6LOhlbRb9CvBJqJwIfNqHbIK+SgdinYFzh8OogKHdw/gZGYzLtgbuCLqMSVPYSwanZA
#qcAY4hyjzjseDmhUWWkUAMjcp5q+QSPBar1juJ0zhIqvgAjG6QJKRpq7AFbDQItny1FmsropX24KVVofeGPXV3nqehFNQkeNY3Nf
#0/yLagpMpsu2BKSmdEVnjXMFOpBQf/mKdoeZlZAh+gTLVLOv63i+/4aO5xf8T3Q8JDTjsRPUwbdk5olL3sl5GmlmJFqEmellwyOw
#W4W2GRycQ/Z9HdwR0ivMALq+NpgSB7kDoWMQ3SrgdrngmYO7wl4RKiK8823oBXRqDUyxyPGJAj/xgY9YNMCob43Ogvw2KJIFlLmO
#zOFwA1+xsIegXQXoYBalRU7R78L1glGBUFQOPKfPhuXgt4WeIsYDTLk4yu3wmp0y2ZguiDcSn74swg/F1giHPYSy2OaCgti2Q+3v
#87DFc3EhrdlkoMSM91O4rEqYCx5RcYo94zKDcWQAYaxDC3oOYCMhXOgQiwkNxY8JBKJJl8GewpaC+YTwgSpgxBqKf/rUficWYasL
#2p8uSu0nJoS9892woQ6sE8r3DyKaYosYlYQtY+mNCYBiUajRqe1hdzhpUAoCJ5HnktFAj0xSChOJZ4THZ3EAXS7BRDHGo5ilEDQ/
#kN8RtfEienUquJEghtYJDm9igi25ydGpQ9EpE4F1ag8eQWcVVK7id7lTCVKiuYqPQUgEyF0uQAcTbMupNPZgQRiSwkUKIqc1AyiL
#HVUR2BEgRyWBYAqDQHMJJdC10mDaEIoEXA2Dg5WUlszQmSxsFiR4gldE2qwmpNTQBpPJqhVhTPKd/UC2wMHYt2r408+MDXMGQ9tF
#cwZiTaYW5wnmcQt+hJnBgaQgCTlCpiEz4skMioPMHmuK3SUOAgRuHjBumSTsT+S7xgFD6jHJCI6Auw5sx7oEd+JKaQ/9tW8lKDnK
#MDB0hroi2Hc5QmN0cxeExjj+wVCyEBqV+JAoQgwKRWMHoYHe739rCAxyBUPQwJElapJghD66CCVcBtrbIUa1igA3HQGL45Q4YOEu
#Hx9SFP/LnkgX7Jg5N8qk11Ezu41w8wzaXADANm1AmQn3oFYXf3aAfTXKavxq4L6JPx77S/YpwCSJIBB7CHp2iiGGzYAawhRsIpla
#rS96Uk0uJ1VmMlu5KTUJqBLCCFHBTWlGqFOnMKUb08Y3UCdPDGLyNEl4SIzB0RwOh/RM/PtQBj0scwtRycVLu55sk7GNSWXHCk4L
#oXZ5VkPYC2qjmMhxMzA+YIItHD2OusHb1swWjuOEcOuaUxA82kBCEanMSTxAAbpUoxh6/nJdBk8WETGJhDLLOGyyFWiYN2aY31mo
#KCFsX2FRjBF2teJWey5M1Y525zHaSY5xH7tQ41SuaRSvswyRqly9iPQawdIaWgwEiZwvPQkH5PN979jzzpYAe4MCiICFIcLAUDXU
#V/B6IsYpp4rrxZUcMSKhJ+iZXdVRqYSPUaGGDHUVBAK3zc7RGnOOQUjogoMMkFhRrAOvkMDnZHijcBY+eBpwoizngyHQ8DKZu1iA
#HZeKzC2k90E4m3Ot2qfHvjJzWo6dTRxOjBV5zIn1y3D5c5wVJofTFcW2ZpYS4B8FHuI/cosx2f2gsoJcKfZzV1y6pm/zaeWlsBnD
#OH+EjlIzQe15wpgKk7ETsnp4eGISMWVD92aRZgCCnJENfIRwtOCDIx9wM0VNNytceELX0YRzfXiGfVGpt8FY9m+YNBdNM0NENOw4
#kUhLkOK1RmrPO+VKbPB0SCmhgzvsaJY7wC1f1wqpHWGJolYWiymzDZb6+Ka7mbvspkvVWrm7GEpjFSXZI0kQaopkJbs+xUOhvTcH
#1uV1F8qzkfSJTpkv4fa/3r5ZIZeiMC6UmkMOxJu3XAIDYlj7CfGuUQbNIUZpZ06FwfXFcX6xTMFH+FwrjlJSKrNLkP+Qvf45W8ms
#WsrIHAtyxWBFDE+oR+LBakSMxwAaIR749I7jKsLaL04rCftAuJpwI+WtKHybmdVEWAnwTefYkIBAFJsBE3bx7DHudcxp36LPfOUd
#p14xnPYTSxj/jMcILhcoRViAL4xG4UqZrBr/wmGVmM7tOsQ5nlHBJ3KMJqtORfHPqbSK6dIe6ketolq3iW7brn3HTjGxcV26dotP
#6N6jZ6/efRR+/gGBQcEtRK4PdDiGcuJj1UVnO7AfsWZiPxrnYpiQB95s3yq2UgRlseD9RyYwhdRTFi7EiBkJisDk+6fDtHJQAx2L
#YkJDuWMjLIgUqeY5vvXFB/HqUxWeMBTWHrFAmWkubgWGwWL3spLfIi1nA3edIjbQQ7XT/huKmnXZKH5HARssoj2FsD2XIVuEis3P
#oDKrDOoitwH0Re1UFA2gHRC/4kbtV9SoUXyw89EPKC8JFTp6EIYoidm6Ek4dGwUPWoKXrjZUVM6naZxjjHG7TK5QJn5YSgTwQojh
#v3DDEfqBwnT28zdsazhaMNwTrhfwZBLMyxAKY2fwLhhK2MSeNoL/QosGhitkWUEDNisQ4GaYF0yXA2O+tKQF6C2UhWaemQxmKEHD
#PYEs8yRoM4BbpaVUadzxFbDU4bUt3DO4CPbTo0x17N49XP3kTFBMEaHiDoxgoNmEJugK4xMf6WR7BIpWuKfZpNdZKU+HHS6HzUgt
#acBON9wk3ORyCO/U0aQSTA5/tpVWo4Ay2bY51tYIoxWQRkPx4rR58Tm86Gxuk9aURbFxs9BWlOHUMGi2UMQqMCa5hQRVRtTBGI/4
#BDaHSCmRagKmOeNjSTWJuHQyKDk4gVK0QwR0N1p1evttAsFmeFfa6Gy+P5ifSDKXSA4hfJGlC9YM3kE1Io0C8onNeUlnGwwUTGZP
#6t3tocGpbM4v54xfbDZhOMWs1cmkB3bIKgyNHoR1nNqREMFXUAS3ysHxaDOrecsvwoqMnV14UpDUcw5OmCcbani8c8VhPCSBJxAp
#THZO/nuQMwORCiZsH6lb/NzEABiUmRj9EoK8xLRNadBZAfejbABC36kOR31aLXxksbTCZpK2WhxSQCaxUQzIOw5XWrsWrJJI+LFE
#oQxBsR4JsRIoqAzKlJwXg07UJeGtf+hRdDYawIoJ1W5Tmgjnc8KNJnIKMBvHDCQbBI41X8DMoeA0iBXOcVQkPIjrlC60L8wo9uSj
#QiwpWR/lP8AQo/0Ksi3lotkQY/A4DOpwNBajQzvwItqTZG8E6Xz5qPX9KmpZeGBVQGs6QJwBEgbHSJ7ycMqikrGaXOHra1kXokhV
#GlgsVRQ2LlhYUc8R8AC+awuKhccbwsP3fwkeOAHq0raxG3C8bl23U+Tr2Dz7KsKKNq2AHEOs+TV8moFlQ9mx6Qo3iHTElD3Xcxtm
#n5XZRReUS2BaEXiBUzhjT0Qx/aOhcPSv5NIxY0+VRHByAwo1MSeduKTAaAXgrGAr3znO5yfE0CpKB8Zil478dAxsPgbOfgwLxwTj
#ujtHAWBnEPgEraSA/uHBmDSkP9BgOEDOMDzhJNKZ5A+hBJtOmF3Y+PmP4TMpC6Qg9kCD9gG5FN+OoohZbx02BhEszFDgu47gOaa/
#Y9WJUOE6W8Rg8Ia4cy4aF5Dx5fVXhEkeMz2YIXyTWNbwdcGeUiLYl42mcAoqwZqKiBc30gvHkni3kBLg/96BYI1hgkiKCfrtYHQR
#EuIQ98CyIs876YAyZpUueh0XeqMY9GOaKYKUipxCpASjeEY7EX9bOAabCor5fIkK7S8gnYLZ1HWRoxwTJssNRooRCRwinJKpwNSS
#7FGVIkilSOJwonD7ql4kOqB1DT067PEPJpOlPYlMqJ2hTWm8GHkUScSk0kPmCmZw1CXTlhP1oxxNBopNkCUlgvjfbeAd58Go4Sd/
#UbSQuMapBWbvYI+vIEW5efNQhzo6I5gmnZqrhnyiSKeOCIfLS65dww4VaNg8amxO+PmidDW8UcGqgMsCWHkE/8OYtnvnMfWzO5nI
#lBbsOmJmYaWDgxtc5AHYVYWizniObr3A0c1LoZFLAGMvxC79XS8UrpRbRnd1Ia+KlTbFBItICQUjfZxlD2IiQiuXMlfInyKVIUcJ
#oddJZdCI/3qQW+A/DnILdg5yCwh0EeQWnWU2sd/t+JdcbG1axbeP6tyqWxve11ko0hCFlnV8WgF5n2A0jclCofzKWBS4OhhhNTA5
#lIUnkaxah8hw2CLPzwMjKWHr8MtUwlMLbNAiE+PPnlNA7CLM56mHBwUQikWA/9mAXRenFUC//PeMDkekmDpcaylEGGWIENuP78uy
#TTZoiUvCfMADh5MzDrGZWqSso13XXCJTS4GJJWGiLqZYwh5rwmGbPlyoMAtdGvLvseclgCrk4pSE03kILoYzz9F1inMc8XymGUxq
#HxT/hvPvGBJMVlIP9xHAdWfIt77Yghek5Ck+OY4gbQOl15twUhzoH9HqoD8FuTH5aALiSOjdwG40B58suOVCsA2Ab3VGb6vJHBII
#v24gOB+h5YdLow6gR8eeEICPY/gEHhpDx8Mc3pABQeTs63Ny7ukzVIxDCbfl4JkpcixfAxquNLQdaqfe0XMmdQy6/PaucYZbGN2q
#jv8GSHDNYkDBiDDraX7L/yIqmO/2FQOBgUk6An7ZpwIvPPM0Gp0sJrCT096DgX+Gy+zK7wzPC7F5OCxOhw4c29Pi80VC97PAVceF
#5nZh4uxY/VwYuhyjy6Ac4pZhEBBYPUxGuKcgxQkkka8L0bhdlzBJHI4Xq3AsDhPUXNx5GOs31YTnX0xfren6tAurjVHFnALXZwD2
#hhIQZucXm6D4B7qcPlUklOH6DB2fXkz84xGcmLHH1ZvYuHq+FDBDx1jjXJP9OLQok7eI4Hb5R6W1/KPS6F5nREQqkBfmIs6p6lI9
#uY2Hr52sNv0PTlabnI9wKV2sTqiSyHkN4rZE7BPLX5Kd2mErmTT247smF8d3+X04/esSU5BiaDgiu1aisqIkDOy5Ljt60Fc98vhV
#rWxVQU1Y0cotlGCQxR3BpF2tOHJ//EEde08mtif24BeTB9DeD6MpsEdpsZsotyguEIouBtcZbKi6IBWCVga3EI12QjSauBB9Rprx
#ZaslAzZnb4pLRSA8YogPUrPSnTk8Ldgqsx9DciaJrx/n5g4viHwIEZo5SR6xbyvBP1SD74s8uc6jJsHxJ5I5ZuSclQRlzXCMMJDw
#Qgy+fkK6SG2LNRNdnD6Ba7NjXhMsw5llDadCxEXMvCRCG0Ig6XkHULBe4JSR0PXWI6zt6TRDUFRbaOFRUHZm1WQ2TJCKKiTTFGV0
#sRcK9VjnOs4H9L8dHiaTp6tzTBQ6wJGMzbJIgunbXsaQPjMmXkNCmB3bUVu/2oxdM/2PhkY6Ypp9D0gfYYoAdrHBvE0zc4+YG9EI
#Hj28xIBjTYuDnM2B4jh02J6J9YowDaFGOEfJfzpGuKvnmppsFvQhBAAorON6Xx2//+9gW6Ar8oAxyKzQtuGOZXLH2vXsyWWuxJPf
#XqaJ+zKwQQYMeFqQjUJgS3gKCRodwGBeBHc0VfSrasGraguZaX8V3tHOKTD4XwpwEjpdEF04SB2rSShkijr2BhRVk1GNjr1BiS23
#ix7OZOCnFfLgtYhXJscXHIQVr77r5cec6fkPVhszZjChkU0L+cOFBiJoH1IpN3BJUf04EblDSzSbwpguogF0xrW4FmBN+JFgAfhf
#/14wMz5XXdqTKrvs9OvpU+x4IXwQCeE0Q4Cb2sLPeorlEmF2FaEpp/DkA2NWcSyB9n5Qhs8iOuClYRAQvDALCe8jrxSNg2nR5rYF
#77xl6lD2NFEmFrFMKWRGVIx41F6O+A6W4wuIXqDPWeFnVYUJy5CMQadmDS5ZjJ/LwWDXO1XQmwurRPKr8AYNugzwRZ+TplAzdqsM
#QqWiIUy8UgUstaJSEaArQXqJFIaoBJaswWLKdHlg3imPLO/cmQElSmLtMANjh9EGsGa4EM4GnesPo+H0czA7H7pyplYDIxT4ySl4
#j+FqLYN+LDWnKnLGOyIj2i4x8b0LpncBr0Xp4H2gUKQcp/yqlJ6OHKGiIcVDxPBMMx3vHavzO3ByvQnHN5kXfewnu+2aASQCTiEQ
#kAJCopAIbs/YgIJWEDpgFlW8vxniREOtExC1JECRgbUGsKihFVPtLCJcoCtNTeIB8PoXwgO7SYE1eG5LA+u2ZO7gmRjaSuNcgLcH
#TwOqtYPgAq+ryW+CCPA9PMiOuB/gCaeFE+QWMKB0l441OOnCtgkzHHNxXVSG5/++dMeUlXNFCcozPV0Y3CkO4tOUScO9bTFpsSA/
#P/sBWhp/S96DtFjshqcIUpHQWlYqhPmKsEMCbwhIHHYEHLcEXGYwolUuNEFBMy6zzhi+mnXGUFzWGUNxWWcMbLrUIt40pBb32JBh
#Lu4x3x3jMOrGuRD7rvM0WS2u9z4EdcxFZG4KLDZzk30b5Ft2QWBtPaWxJlOkRZ+N3rLxxwef4eHZhAb1/zgzFCtGnF8g4edFncvB
#DLiojRD/DTsqTkEEODQemRtidO6PH06QIYP7JvbjmPjeKbcA+x54Djdc8HYvOjisd1CbYRQGPxmPMBwghfl8ig9j/0TqdQadNTyg
#qUmjAT2EQ6cP7ACeo3D5fRXCDqHD2X0PCy+FAz+bA9OVy2M5ghwLTMVQdpDNw/k7fYLcBxYT+00ehACVVqdXA+nqZFkw6AE6g7WV
#uj+pAgIY4kksUlIaMJ1AU2A+LIFTs7IKm4QXQGdvCzGe3aLhp28IIwJ4FaPxNoG9KjOgCDBrHL4ESU8dN5pRVK7j6JKYCEA4esl/
#IVde4P8wVx4POY6HnPm0z5xtcefNTDEnAYs7oC6DGqqL8+m8F8Eqh06pG6ks9mNZ8TolWEZTIeLQpCgdPvUlPMfNHAGCbCjiETl6
#FwYoquHRd+gCag1nx86Cjvsprj9fxPJfUd9vVfJPUBbJil9hPC4/Ya49AINC2UuEgaECeNWE/UNIRY0RVoGKgFj9LftEImTO8bzx
#ak4jhrEp39gSyqPGNSRoxyrhB+B87St/aAolfNGKM15AxPHZgkl7Zmdi+B7GCVJgZFoKxnoyD+C66otWVZQ2wxG7An5jYp9ASxIH
#ynLqk4nTc9GpyNecJQoVNMwXIOANKYErh+DXUZhLe1Qi4HBfFxze2qZE/gP2KIY9MMcVJMyI87hUK8zZOpe1YRFebDAsMJPRt49E
#IJwUTkmeOhiLh5zDKxO0aU8O42LdxvGcwl3VNI6b+XFm9knEZMN+TgsFjbFhdy4+rMjOfJqLnNicS99+iLLYREsuZAT/a2SQoSUE
#t6NDOCY2YhJTMmBBAa3VOaVoQEodCtYQRNOxKWd5+YHwjnSoYG8jVOh0FHxtjBu3fbcbHa12ir9CvcNEYlIChT58PdRK8Y/XwSAX
#oVau1kEu1Eq4R8/wrH2C7Xs42LmMdreBSoCiaBilDl0L9ntw3VDBEso7ngv/y5AxQdPwx9UpTFjucAQTF/17XzVXmkxWd7ED68BC
#hnUwwXYBKouORunwxYncBx3t3+hivgCJPh4ukfI/xJ2EA/Fc8Rz7JUH3PIn9X7f/+/vanwxIDjP77XIsnlU0/e/2AQNOA/390S/4
#c/gNDPQLUrjJAxSBCrnCV+EX5OYr9wsM8HUjfP9dMFz/2VB2bcLNAsi0uHpfe/6/9M+nGdE6XhFHZdloIIONlJ64PXgaEJAwoBpo
#immUEW02w+9G4YUU6aS0jGgLVgKaIC0U/NKfxhtujlNqGdHMx72lBjzy1gADK5e5Muj02SGerbVkmoUkulBAfnmGokeZeCkH0gjf
#q3U0VP1C6EzSHEpbVCE2i17MUiesQfuoUCveZtiKNxDsOqM3eN3baLIYSL0sE6gTCgmhgXdWsSe69ZTk/Q9gCvzPYAr8b8AU9J/B
#FPQ/hymKtOhN8IMqBh0BdACgONGUWgic/z8AToma86ZBc94qtjkGSv//KpT/hNSKg/I/oLlvgPKfEF9xUH4DFbqHQMmGM8V700Cz
#AHqcmrSkhXp7K1NDvHz9fQN9SXBDy8EN6UvJ/eGNAtxo5AFyNbiBimmIl5xU+Pn5gluoJoZ4UaTGVxMUipNTh3gFkcFKEj5VgWcB
#KlKpCYBVQ7w0CqU6QAGuTWkhXn4ayjdYA24ySYuR90xJqsGdJgD8D9zpjKCqb4BvsK8KPgMKHngaHRzkr2gFNQFvb/hBTAc2ktLZ
#QD4ZvG06KQ0UQoAtiw62BVPRFjUjLt/Jc2+WqzRledO6HKj/KU0WNWUBzWTluWutBn0uY5zIfX2bhCpJVVoq8tEzrm1lqiQUWHsW
#DZywrBBsgYSCSVem6awIcbBdyptU9wfLEm4E22reZlKtBh2iaLIghRl0B0HPxTFmIb6hBjDb/L4FIX7wRBmiJ8ikhDzQnOUjl/kH
#EAxUoCGkQ/HgtZBqHan3ToW/0AcBdF5zFjw6Av4lrYQv4e3fRGpJVZJihZ9CKpcHSv0VUplcLpEihRt+Pwrov0G+TSRSx6ZaoEb8
#FUxTwb5NCO9gprEWoK0guVThHwAa8/uGxoJwYxxcTeCeKAsZAEke3EIaDCDzDXTRmH1S7CP3Jq1WUqWFPqIQDdytznNPxPOUlMsy
#I9zL8dAZYAAYabSCmUD7K4jJQ3RGLSATK4N/7s5mocEtk2Mlz53MFTwHtCOXahVSrZ9AUmD4IDVLQtmJznM359qvQ9D5Fe8MHa1T
#6qlcsEgjZgT0QdAmvU5NcIGhocwzb2xvhyAS0hlSpXRGKmgwC+8+IdrJc5cBnZBfqPAH+OVAQIkZQhmCDJEHg87QP4G+sE1ZhjbX
#bKJ1yFYilQAMIABCmYZAKyyRgkuWFVhGgGdQQyzw5CjcPvOFOZQztTor5Y3OAgO0Z1pIM+iBTtOZXfQBdwtCvFu0aAGahmwCYHLB
#glBcSATsAeSJhBsOGo0/fBNzNiQ0G43aclyJc7zRV4IATzEw4dnIRXDIEYLdgXoFQAGcZYGaETDjeIDT0PzKRqDaG5MrQlky0+ip
#rFBSDxQxb4AEAx0CPdaUJTSVNKPmQ2EFb4iTEPgPOz/eaDLwv772afJnpomPEsQm/tJAqdxXKguWcJIIVlFbTGZv7H8LQVm7YJeY
#U4p6xMpCwA0GOMECGkTuC4AoNAEcK+mQW8O72KH6MriHSCcUCii8CD5r6CkrqIuIBI5UJvf//9j7Drimki5eREXEVbGjWC5RFCSE
#dAICYu+6dhRbIAECgcQkFI3YwV7X3rvrrl1sa1mxr2vvqGtnVVDXvupa3pR7k9tCUb/vfb/3lp9Ccu/M3LkzZ875nzJntIk8/A+x
#V4022kDq8XAVk2Pmb0KTyqBrOF5iqr8EdPRY6W1iOrLfB6sI07hMbidy9JmHE4O3RY+3VY9iMA+4AFPsdGLSQmGeokWX4ekCPLQP
#3RoWyBEgifmbrEWlIVABqttWzjoxS3x5eo6nmH9ueVYMNZaBoDy1gmgvGWVJYhMCyozCXbWwN1/4bNuCZuOrolEI7mZwHORVVvIp
#9Jro7A1cKJLavdvfSpmhRAqK9WvwVnxQcnAy3P8NU9IkCkWxBrLRYDGXJzliXrbFACV5gUtBrARLgZfwIa/1h3EDQCjph8QakiDP
#FUar9dHwrDhvmOIALmpwDX2FX8hPUL7Cr/iTmODUAQMJJS2mUMwmCJHUjOUvxJ+ESKIwUyPBTwE2tgUFu5TiAAgdBUsUiG7hAFpt
#5SBZSOXoBmoWzxgeZupzrIGcR4p3oWWfpDWbfSQiidTXVhdnTiQr4y9WW++DzfCQTB9RUKAv2YtgauLt8y6n5j3JYPFX64GQ02qa
#kI9F429vjqQy2JAIvbyVLoqhBFGnqC2kAAF8Ad/Fsz5UKBND1kvyG+ZFG5thrQ4FgIfUoMeadJomKK6eyR/YotlGcmi2Gc9pLJID
#vYJOhZiQAWCPoZMwnF21yQ7dJDKFRhsrjDPryfbifAml1JtQSAE0g1dpj4qDziG5wpdQqLwBCvX29bUzQ/toNaEDYAPKpQvElCU4
#Gr6N7ZXRGOOBNZoMYE60BEB7yWh4jYm8bNcYVTSGKuZDHMXkXQi+UGStIJkXocD/OUyMttLozAmtN6SmxKk1QLMBX9FrFM7HjFGE
#KCmRBv5k8pRUDjkglmK7qNUDZmLWmfnRmjFRhJxicBR5HhyNxArV02CM/GTgdTkKgVRFdtAubCUyGqKUsYQteiX6CNEYkBQxIFrX
#UKP2RWkyABVb6yNRiQGNMiUh6DCqqucRwxhHiBGms/NFPyj8fJGKRnY7CFKKDfIpvppoEBykEQ1zRCFmIuQYFcKP9WECAIpViZsg
#7UGnh1+o6bWNg9194uMPX4KgmJ/K117K3wDeGyBPiHTRCNAHnXwO4PkqpggAX+1PRt8ZMwLGl+qihN5FUtfhMlBQg1AL0R9SIWOs
#+CY0PoHIFy3iYAjW6cNP45dgaBzDiiC4MiW8FMc2NzmAFai/lGiy95p+Rc3U7xjFmJofl4CkfPiNUhBpXRDpKanIgLdqCG4hj6S5
#d7B7kIiCXnrwl3YH8k7yKBtKO0VEJ0bcK912kzBa+ZgOdTfKym+2oHE8hHANejOTIbM0IRsz5mHUJOKntBQl7h6QTNFxViQxJYSE
#wAovnyjAJXFqPLro+RaQlfvyDBgE+0SgT1j7gyJZwUSB2JRTLKFAfyFSgaVTSZOvZ9kJURqs3ihhZ6UsyMpLuUUZODyDJEeVcjR2
#BW2xwnaUfGvV/v6wk474OSIlyNIhcuLnjeAObiy2UMKkKC6WYlO0EaCZqIpDPEqWroXoo2DGZLMw2yA1nWxgWDlFHrEMxsRdoYxC
#kcyTyFFK0P5c7hRt0yU5hMXWgkDzGg0vKtNoCodl0I6qixkCDeMwbiEYYRP/KK0lVQvknM2SQhPNgd8CxHEkBXPBKlgLlkcVLc4S
#BgNROLADhejAiWalkLCtFIUDJ42GFNNwDr4BqKO3V1wkptF8DRKDvPt/BYh9Newi7cv+KJeRGfNvB+juS8AZbZbo4IyJxNidQEY1
#Ln4DzRmMlm+xfiHz4xfExcZybFzIz0L51zBX92EsYluvkPFDSK5mbAcBA0GhPvjxWyA70E4k65x6khfz8W+HpYOD1TEWxPTx8AsE
#5FAr7exDyRW9fHiIhyWobEOIVzIOM7AybBPwF+hnohGuBshjkhOTzMGJMHcGPOJAAhhSjMmXIC/IIEYSigLhNUwdKhYKhNEe0AqH
#jk4pyqNMWqNWbfGRCe3PBI2TrctJ2UHZe8XYBQIbt/r7q4PrKxQKLoz8ei4Dn8vFGRqdCSeMCcadZ7mduFq8Iw5PRMPISbDMhuq0
#Jh+RVChSAU4tlPgKWcIIUDKdsrFwgG9PyiN+jiajeQswOWLvc6IuzUeXRJiBkCB9c2pfQqHwFtJGwpd8gAPqLgBNMgSUmkc+SWzk
#qPYVigk75vangVY17IAlLjkxiotJqBURJGVACAyxsBGKdtVWnWR1tFvMnlIP5FmMDh0BBRrekCgV0p0/Yl9CpiDdpuCrRC6UioWi
#IKmv7eFElCOPmwRjb6ROqehmDZqdWsFx2uBXpONdphscbXVDiwH7chUKIfVfFOjAL4g6io5hphRJZIPka5jUym3zT2oI+GFgPITI
#IQZpDbnZi7DWbDqnTelANnIlacEDTSVqLWpmSwVLNx5x6ADTYwwvt/EegnQkY40rELn7pQrG+NO4lhz7gaIBsRQgkKPUYLHBrCJ2
#HQbVoHxX8FEyrnMO9S8FLlbwl9yMHmxRRyXrAUmC72ZbOxwXG+cFsd0/Sm2ioiy4ftogPvCOWSiL++GWCB3LSlRg/IaaY6xlqk1I
#NhIiJXypGBhV81WzTTZCoN2sBY8MnvqYovn9SAUUCEKrQ7BEaxuuaeSZoYaGQYV4bGlOU7JpHm0RayLorsjAnGok/uE2Kyu/s+pr
#HJGBbHu6ktLF0OqQs+wRvFqwXaQRqJtC9JtSur5OuzUnUOQsFYs5BE2LRXD0tgVwejHi9PTAF5mYEqdAMhIAqXHCYqAsDJBSrr4m
#+EBvFK8QRwA2Ao+FiNElAapKdwtP0A6JMakTtWbCHGe1GKx84s0ftSVOB6+KUuZZEc7CXDNYEuAvsc+OzdlHA+KOOB/VHGVFoWfb
#wigMnzHGG28RqHSs5NP1NTEZ1kL4Q1cX1teKqw1y+Q5AoI7BgwSOAgeqOVzXSBhpkzSsQA+7tYvlhisaGMGd/A8CDpFY4cu8EKjA
#Tj2TpRCoQWbw5MMZ0Xp1otEH6QDKlFShEgyF7zfEHXIHuAP0mUQd/FADP5PbHsBXLBgipfx9dBwSSGf1+BUhNQrlIjl4STkYC2rg
#NDqesBHaQDGoCIoCdlgTyyqI2TlsGQlnduQQ2T+Fgk33dNsrfKUgvB4RlLLRqdJ+kYiTWu0RPnKEVyQsvEIFn2ETMqipM1p534dl
#4KcKo0TnpIWfZgAS80RZxH5rW1+yzj/RkGRAZCPspE3SG4S27/aljiwl/AQWbSmSrioRyWNMBNBPHQ0GHvNYAwv0cNktHcTSKSIQ
#A42idsimPEsohdxhp1CbiIILmBCHAT5ihhFXbGsPYyfm2xaIpGS0ztCQLSfShtnk1/jH0b7VYhvC6GEHNkADlw8SVNyVQ402Cf5Q
#9mxRtJWFT9KpOxYLF5/hW3hE7fQtNzq2ZVOCGm3cBTpJMeAwud6REo74Ig2yyVhvyOhpNDsQkR0MC0tQ0dRkETzpJlOR1hhYYTCu
#D/9CfkISVPNNGx14ilkd42cuLKdMUfQnkykM8mcYa+QTjLYf+qM0Ab5W2sLGFmK+2TEBUJsaZyiS7qDirDOyNpYQX7MOTCZRnIZH
#zeHTSfCEwTwDaNQKVY6Y8wCqQrXCJoqwq7qIoBMlHmCEgoOLcTqgOtMRKNudy9spjvjCK5nhMoTcPwpaRWmtK5SIiVIROkFSjHdR
#OSBKhYB9DWaIVAwaoGAVykQKABpkGBmJJIXIWNRkmFFItg3PNIBt83jxaf0JFEfH2bqDpS5D2ypQGn6xO5jHFQrLB7L96nAOE2OL
#IbygWIbRznrKAiyFCJ1jBWZEPcjxjABMCMCTLprXjP8FJl96zD1uPk5GzQ3D5KPilQFoZpVUVf5QDNyYQU8tDn8EvOFrMWMGmbIc
#G7vEBBa8g+nEKlfxEiskI6ygma1FYYsM9YZ8DEGFnLDs3I7HAeZZ8Ue7XLFhoRgCiVqfzEcHB1OQn3wZf3A1QWtiMwhGFZZW5Sdg
#ezVpjAKNPNP8UpBjljaskdBX15/9VI5jVQ6jMH3Jqra9JaTcFXNigODhnuicMHb4D9qMbwv+UeLgHxWvn4IVqCMlQ3d5zY3pZMtE
#nMTK1oKkoHkhZGdyyM6YowQUTFtVB0FH2mg6ncpI21VckWPn2TiWaoBiveQESnCUPYwhLsauBzbfcmDyg80SOtKpr7I75VRFc8oZ
#EnxpBh5jMiF1aOAxJlvF3laO00SMVVWlTCiVyoUSuQzpg+mBfGXhaqRp3unQvsTXIr0MVBGRO+1bMFA4YCnRVjobdWzwkZMGH1QJ
#btwpgsiQIvRNKWBSMZdISM7NbwJiwyfWG4jZq6lAQ5BNL/oC40/iV1h/sNhEooM/4ptrCBErfTHIZxgjKWOIL9khaGOhOlVs95aC
#2hVI2ZsU2N6UyDI48VhN7G4s1Td1YykdmJMS7fYklhRBd/SxVvpmT0hx6dQdUmXF80yBEHjLnGil5K+dSShUtqrmREZV22LRsZiZ
#kkPR9pL2jYlk3CcPA/vCqE0Yq6qjKfJFYKDcsARGZL2Uivko2PzF2S1HZ3QSViSGAdnzYUdFqRxjGX03qkTOrAi3O6NNRLpYrk1L
#ylUKeBc+rg8tKDTCweYJu3FA/kUOOtiuAy8Uqd0XzTxFM06RjNCSaKWl/kQWCEuiyEK/aME+6K/0nDp2+Hy19UDhYE1Y4hhrigS+
#Rn1RhoqSI3ivrQ1xFGBhsLN7rkOULSXpAhb2SJSo5dArYys2O4iCU0KuQKSfZKVbVovgNWdiNilqA5sS2OuSJ76qaNYG3KY2kZwK
#EvzDnAj8sJsRaw57U7j7FZsjEjQF2AuLsszMppSv0ktVLL0U6/Dmou8G5XEiFdfbxae/o04QIg0lguwSKKjoMJW+aRa0Bg3FXGM+
#vsfL/nhn5WuICjzIMU8EN9VMC6rjPchf6MuW0ze28rI2sh/fxk0NzxXiNfswRD72/hfLOUDSscVGxmKueYVsluE8wtploSCarFrQ
#XMHbDkWmVFmAO0rOsE4Xur5RPwoNc7G/L8GOk8AII1Wv4cIECdNGruCQAqhFAFzCbg5fZ44M2v2DbzAtshRQMerZMwyBCo04saHE
#mFrMYE45jOWUIONDEJKASA6SBSRSijDsxtICBKKE0h+4EhF1zdGywAzLmFqg++erpFHql7qlQE16+JOSfpHQFaQUBSGdyLbAhRS0
#Il9VZGbAfAdbKelWPWaQBnIuQF2DDW7UtmgMmKa3KNQAFRSCRhISWngv2jeJKABAHbj2UGHEBwqiiG+4TYspJakIP07geIHbN+gB
#s2ZyZArZv+FIrMKqkazjOKhIWEe7Muibp2BnqVdjuadwTgzbTfgwXQGSNZDDb0BxR9CJtTHza4SwNlbK5IVULBVX/wvkiash+RbZ
#Ei0asJh+WDsGkTHSlXB8lQWDUCokDPZFFB3FK7PTydsWnttIVzJF8fIX2vKmGS+R6ZOrBuNmRNFmrocYXrcwr1PIhs4MULkkM6/E
#TdCorQ5FVeGilN9sAhotBl/Fzmt7XDdyXsO31pqtXEegfT7Z2iMjXQzXF4VbhIeAcRQshiVBzrUkoIrw3CGuKUGhEAahf5yKWHLD
#mvBAoi8wQqC6tjOMuBSGmSKvYzROm/Jtdpc55moEfkpxdodpLZS4FHPtq8WQBjTmiTM2MeeacppSnlNNqpWjTGFZQUsAB6EvNBRE
#SWl6s0LJYzYmLQpR0mB4yhd271uZZdDW6CKFMFDSNBBJU5EKylMSjCspFA7ddkKR0obC2ftoWGBLyW99UBURGVtMYUWIXkAF+YME
#WNiFZaHBUwLqFsHOQW2kss+/A2OHxVg0vZobmmQxfmW0BN+meOOXmThgxeTCo64dAFJL8exy/wEjXDC1UceBES6RHlyFBQLl4oQ0
#C1cgj5cTH/jJ8nCii7TMKEEqx1nxFKRmiLEvbo7Hg4niOKEHUyHm82DyxzLqwYgVvASYLne5MjqOrqeTnk49DTkVZrQFfSHttjK2
#gZ7aUGe2aI1mK9vBbstPSWcUoBPcYAIp3rOejPaOoiNugs1Us4ReVySjqZzmfLOp0bh+cDA+5cVKPUKXFG1CR4EEm5vYwBy+52P2
#beIgmRuPsaqIsfl2AVNY7iXGtimHqwSLN/x6jmE5fyAIky/iNvjtEhBX/W+F7/CDv+goQ5o9nkvJ8evCjgdiv67S7teFtQi9OkrL
#h5V59Rp+uQyDnMw8JhmHghxVIJOI8IQk29euEsVFIDzmj3hzsAQZo3iC1b42jhn1lj//is0QxtwpA7tgh2LJRqPWFK02A8GhNmkt
#HM3TxrCLkdyAqyzTRu4/k62E/gSR1sSrk0exEpewUbmY05Ahga8dQwK3GYZawOdfxM0CJdBoxXwY5l8vbIMgHRKw8phCUZBoZjiV
#5bZ8ifZAVIfmIPvWT7IlNGpcpQTdAuPAfaOYIoVwUmJbbos0izZGcbf9AH4G+APafUe7p6TtzEQXpLSMMagy7wopXginA382AeOU
#vmj335flSi2i28GxmOFLqGrrDj3VqZgmHVEYQkxh2VKpuSGS1Ck8DFPFF/9Kr8PyqpC6JF+CLVa1ArLXoPOw7BEgKOsz3m+E5Tsi
#b5RDBIkReEZXio9ZHaP1B3xO7Y9CYMhVIBTb818yt72jFEFkYkau2QbNEtsQxMz+JOGGdPHt3rFnE+FLBkIFtcjoMoaewFOGMvly
#hAsYJbCoubHWZJqw8EStRqcmfGgpoyXQi+NrJfMsFOgAkrJSK6Sn8zQYhNtzIwiUnJoRnSqhoQYylS+O1ASFYeAWKzEygqBcIy4q
#TqagcAiFUSH2xkIaxYhtiWcorRztV0O6AXwZKjxP5c3a98OSxZS1AGFl3iwKErHC25EZRWa2zbRUzFaGC6Fe2huibC9WZnoXdJsZ
#A09mbC0seZaEnvNQxpF7tM1k9I2L/Nlb4MLkR+iofygcnxk7BecWRfE5nlre8Cqc0QMSEopyKZgwjKmOC9gUE2pq00HxMLo5h70v
#FjWJ3Cb8jQZKaTEi2NNlEzlIVUSVCVYAWCA9AExsL2WK4m7MxYOvoIpAsy13VIEaWcCYYmhMbTtnAl9GkHM6qV/ThTQSKm587EAp
#t7EDLCRpchkGFXBEmBSIMG6ubrYAg+3R8jPbNIog+r5xupsWcRiYjpC0kaEr7GyCOJMvQdRPRINhF3AsbwdpEaT7q7iGLPJAiCi1
#iRwKaiZw6/aAdFs5zpzhktTGaVpgBbgVo7fYO47tk5Af2IyNiMuh6yj3Fy2TloIaQMzyaYtIjEeFmR+S5G7YpgG5OnuXixwjCuZu
#AhnFqOnh/+z9ifBhFAbkDzvixM8hKwbDwWnjJfS4dpxUn7DNPY51KJ50o+ox7MPpVBQCO3Ac8a1oZll8kR2aidYQjCC0hdfR4gFp
#5WxUarLSZaCd2zBhB3WLoWFLqEYcrGdeSzD/Skbm7kKAAuIkeNNpIWMNhzhdVEBJ1BSMvqYYPDLR8XUMnVDiCHFIuYhD6hhxSJmI
#gzGuJAnZHOXkLLDZtpLGqhBtFiQZlGK2ZMDiKcrK6jP1RJhtl5UDkT5bJJQEq0dtMmvBZNkTPgph5nsh5AVClNkDpTATcpPxCsm8
#GSgwiq5qikniN9E6IGfOidGkjdGazP7k6az+iQYy4gd+9bU2ttq3MDCPZqHDI9ahLen/Hg6Ifhjn/8WoU3RAPxUBCfktn1Hw+X9i
#iUQuY53/J5dIFf+e//ff+AkBc02kJeqTzKGCOIvFGBwQkJqaKkqViQymWJgGRhwASgiIFJ02tbkhLVTgD3AJgX5J8X9BWAiUrgR5
#T0AMoT6gxRwqgGXIQ3vJLyZQVqYSEDB6NVRAnjEmCAgLiSUvwcUqIPDuCVAAHyZGXfAn27VfgHpptNoYKkD6BOgQPNiC0IQKOikD
#RUqgOoskzQLFRCCZ5w1dIOCtTv62j4wC/rZ6nfBHf04buCa628n+kVHEXhO+W0AsfD/bO+EDy77kncDwq1S9/BUq8Al8AH/Bd0Lc
#Fl5BHxQq6nnk2R6ETYcLFeBMohKRxNc2/tTwIjYP6MBfqhBKgwj4xx/+lUjRX4lMKJHC3/ALeQ+XBAVQOXALlIB/pUGoC4B0wv5l
#tP/LPwz+j3RzETzH7ps+oxD+r5AoJOzzXwMVgf/y///GT4iXxhBtGWLUEnDaw9xC4B8CngkVKtAmCeAFrVoD/sDshQRQigEABGw8
#2RLjrxJQl+GZ36ECKCIgvBIQpI07VIC5mkYLYAXJ4oQE3FoKz/BDjChUIiSoejAIPBRtToQNW3QWvTYMnk3bKqJnd2IYAY8Rh2fV
#UscQQFdzSAAuxugH0EiiTTojRH20rjRHpxYQaMNsC9IH3N1i0iVoCapJs4jortUSUFeGp6DjI9cJaDKwxGmJ6GQT2paYqDYK4YUk
#AiJa8DqgILir10UniFgjYoGnaWKPD60nlLxjlkWlyAM4aYXhUZywJOhKAmHSAnYNERqQpwAThwp4gJuAgLMJiiWqY7WQAfsB6V70
#FoxJrBbQBajVAcEgCZKmgf/M1gD/0GuBzpwcHedfWMuMigDWw7O9OeUNRTy+VkCoQZ9gcarH8HMAeS/aZDCbcYbsoj+1OOfSftnj
#kSfOHKfVWtg9sB2+DUcJUzBhNkXbC6RokzQGUwA+nx4oS6J4s4DQQNUISlpUwUFNMEX8hQPIxQ2jH2FdgAVJIEKDbGKISUDfwNix
#bbxgDGCYHo5fIoP0wkLMQxKjDHpCB8BKUhpKiEDHj0EAvwTB0AT0X+AI9JHLrQVePEyUpPh/EPkV5Z0g8pNTyE+OkZ+cQn7y4iM/
#5hj/B+AfIgQKB4aoYSIaM3gCPCyTIv/6iWod4BkatUXtr5OoABUlqVPQcZqCsO7gN2ExUNwwJEANWoEGLbIdQNdgsRBECHTxkdcs
#BiNJlSiwA4wabB+WAuVsPUCWYNsKZFawyZw4QyIi55RYXjJPBuKEfAeKzCnMGxIFJVcI9IOGobbAZfg5JCAqDL0F6g3tTdCpjQK0
#ZMDHbqD1AHAXvVsAeDn0AQ4UKoFGDJSAf9EdaOkEEpEaXdL2yXnpmP+Jt4aX6NMNuyrSa2PVQEo1jDYYhzQhqL6IuJJaZybUkKg1
#WvhowhBD9FLrkUg3GUn/r4joEQeKwWGAxZMMFkIdAwhep7ZoNYC/gcWE6ojI7uFuIS8xbTxaozEFL6ymxgubzf11STEGAecF0D1B
#WBsgywn0Gb4wrS7ECtxa6GpYW0MqpHL4hVUrRj2YWwleDGvdrCsqa6OOAEwEkKkjymFSl9psoagLfTQZID+H4iHZbCO2kCQDKRlC
#jDaWT8VUyY1pgjD7wCZptRoz0V6dou6OqoDBNMLeGOyyhRQqARhY/t8Guv/+8P4w7X8IBH3zZ0AlL1ChcKT/oc8s/U8ikTgRim/e
#E56f/8/1P57554HeShb2Ld4zCtb/pTJ5IGv+pYAA5P/q//+Nn9QuraVOJeCnRiqnCvDvIA8np4Z38DXuT600zz3htcemuQxyyhBW
#cnW7GXJUUm7MMKcSSucGJcdZShGlx0rLjCvrWadryaebj5XocTF0SvNB95zq5iyt1ur1nwceb6qsd3u5Y7rbFH/Tg41VQielKWrJ
#xgz4dWJKmkv6q66uZ79b+WFT0+bRS++/+PD5r4+p5g3pAwf0vbD6F9cfzi48muLVNf2tqlx/D5fKeuPDXjebtpHHbouVeEXUOujt
#VXZFdgv3cmuqnRyT0Kpa46iIfz4PW5q6csW6cmc+yyrk7W/qfl1unOHRbk3QD3OWdxqwuEJq5t4Zf42/8WGp+0VL90kL/lZkNGgt
#jBgjL1HJb/z4UQkJZSp0Pj1vxeKLmb7bw9sHTvjtjGx1fsKlmeeXfvorwrrqpHddr0oLdLmVhtQI7iSfUPHCtmqP9cdPTPfa82zG
#7Nktwl7MmO21f+BPLtNbDH0hyXq3t33AzC7W3lsW51evdjJcWuXC4vZPnp35PPzXxn8nie6W2SQfPsZ9wqzW6+6WCdn32rNdS+nY
#tr+NXRXW7sL6dupunp879J5/es/NjRfmXT8cXLekywStawlZbErcgwVP677+9M6vZIJWUCd/vGKb+XKJ8PhlhNfdeWLzdFXb2prd
#nw19t1WJ7377wOJ+fuKoF7HdYmK2bf9z6NbcGf3+aJ2zuvqEu7VVDSpuX35pTZrr9vbRn8K2T35Wcq6LeeoO+frZu1+MeH792e9h
#GVdvzRF6HZ9ZrlnLP11qrm9bq+XeWzufiEMq6gZdzSv72VDWWOa2/PDk8iXdSvbysNSsmF36bkNR42y59ufvV/e9lD/g1soaf7ZP
#mjb5n1ovNri/DHk6atzZKmc+G0otmqX3/LD3QY+at80jKkW7jDvWKSKsrfvI14ZBbU8m9x574G2g2Gf9Pze3zPeqHvrrmNPuvbpF
#3PC67f59qfMX1c9+LTv62vNA75ztfda61FM4ZY/1qOm1cZdPt5kvY8JK9T3Su0bTUc57Ata0Ght1+tCERkuGZrpt02iy84jm4YN6
#Pjz/x8fr0x+4NntSfXZSG/WkVy+jHg/4uHvh/MvTNmQNfp46OH9XtRtS0SGF+eWuXXMnJtyO3+3bz7v3wSktKo+d/jokibgyrcn5
#bSninfWyG4h7vHhw+682A/ISHjy/sdDz5a0PkqbLXwfKlCs9m8aKTq4LmvlmiNPH68N1iTtPzekT6Bdzbn8dz6Wy9O7x1Syvuqj/
#ObTDt5Z8zbkuR3/c2eV69wHSLfUXzBsSMrzjkuwgVcT+4cdjDh864tttx7ZaxJl6V9SGf/ZW9P7juWL957W/vh43NdK8NDVtrs/q
#0Lmd307/JalLqqX7FUufGkRqL2vej9tXD2rpfaFj/tlfP25c07Nnn4wpeWnpeQOONfb7uWeGtoOXZPa0F28X7z194caZDR3vb/pw
#fpxr6v4U/1u5vvcV01UbXatm+Vbc2q7Vhck7m+095bcnfuqYfcNrW9IuGy+MLbe8UZyl/Z4TuRclTfxTym/1Wx/Tasq10wdy+m6e
#9EPewjav2l0c/Hv/+n4fcy9XPPPJHGqu/fiSOqVigofvxTerQvNfBm2yqme79vjxaA/Xe93WS5v4m5zr/v1y/uP3NzfKrw8eNG7x
#4qyL4cNlZ7w8mw+rtajhIuPc0kE11vQ/O9V5wv0flp6pe6h2/tBqOaev+ZRLK3t3Zk1Z9fzwyfcOtM1aqJy76eSNymbr2XEDfjUv
#6zhoWvm6ncf/KfYdW6n1LGuNoe0a5rTLSX6f2WDtT/P6htUeaM5tEatvGHg6X/nC46fBTqrKnVxarT2RELktaGYH7QjP7APTGsVW
#uK8fv/xtq0NntlV/f7ZKfB/dtoVuN8YbV1fKqDS5dJOONXc5e8c5J/aZ7LY4ZNyR1NbrP44asuGv5+rdo51CZ1uvrj8Q9a5jB+Oq
#7f1LV++vixyWXLdumYWr/Pq2H/6wn/+WY4c69tWvbHJxRvX8Ksvc200zz/+hobTkumWz/CRbjzVudT4gK9ttzh/BtY68qKNZJ3jl
#uW7daNdXnptvVTq2yHiiZuxi881WYzInHzjrWlsY8qHt5RWl7reJ6W72vr281N6qzVI1hxc2Xe7UqmwPwfveJ9wPO1UR1GozWRVS
#ttuAWW5HZr85GdJn6/NcvwZdD2etaO8zIf5I95UN4mevfl9/kiJOvbzTnWuyNRX6L0sS50zJ3S3Wf/z+u5ITswZK6nQVHquaO/bg
#4mDpnckvp3tl1Fw36FTGOHHFPduUNbsOaxCxfO+aR0PVPT8Fd5b/uMd3TvPKmT2y2jaa2f7hh6vug0osv7pgQI3WO5bcdc9+Mqpd
#p6CI0xGblsi3E5sUARu2r9suWNsleOLsfItqUuaKvuNfdVV2zbh9d0H2m9v3U0IMSz3uTmvcS7nGTb4470O7Ry9WnY2YIplnDZra
#aUn18Dai9r271Oqas/Luwnl7/XXbdOK8Ff36NdFda6WIjx8z4cDI0tG6iT13ZkwffX7Hw8FBT83VhR2zo6uen7j7Xp1bdRdfeC8V
#34/7tLWxeXp+2vWfByTsyfKvMK6/ZWjM0xW9rBmKnRHND28c0cdl6nrhhEWn5ry4tDX+/vyj4vuJr4LrDfS4V+5ej1bNXCsJwse7
#V/KQetwWy5qLO14+3/Gk6/VePYSJ6za3HF21w6oIwRG3/JOtf5636fbB7KN7g92ur3fLa/f6fPUnB1PatWhWOv5zA68Vt1dsc19Z
#dtTarn+ciTjfatd3zzUTAo7NezayYm/58cNZEevcvOrVdnPpGOE6qP5Y7dTwtsedX8w+MtV184h3EVXLJqZWnrk16pLstffeS1VO
#zt4oeThm99vJU9p3Per1Jnl6tkk1IEHgUb+btc2DtdUCQrKO/jI89tTQe9pJMS779zf+o16eU3fX7ztOdd/y876NTvFBvXaWWXlB
#3P3chMp1H/qN1N3xvjxVvy9fldp3Yowu33SuX9O1OU208XcfKzNvrtClND6haN2/TmLYjQE/uGquidyqLau3e4Aq4BeXs6o5fjum
#5DXuNP1y3ut6U9/kRa9YmfDzud07trp3Hm9473TFPar3u4VvQmLXXn+1Y8v0Z+4dyhvq1wjNGrFe8vulhJ7tnnrtKa8zh7sd7nNM
#eyBSv1a5tteiR7+fmDcnaLd0YfPkiFJXhtzYHz24xvypkrvKRnNHKlJWb6hwfs2TLecnX64ypE7F3zvnNKx5zOPO9YQmC5ofeTRV
#ePljj1Hx784f+emgqG1qwp5dKzp1++WXHWUvPN3fu8GJpn1KjVYYM0aPXeDpWXe076Bh7irhs2fL31Ro7uY8alQLYuThym5lvxu7
#+WT8ogk5F6Qb9K+veo3LqF3d1DA7Y5xH2I5n+hHlGkcvmO8tjaxlXiXuUqH6+B3fN/64VUL4tVn/1G3zjsdvZuV0urIosmfMzgGq
#mmXuDjV4lKhacqVHk0Zj80f9/bj9xZzQN10kK57c7yjU114VdWNmxMveHSod+KPVwcSOH2ebrx+IuZZ1feyUz7k1n9WL2ftX5AB1
#i7xn0uO5Ma3NLbf8Pb/5Xfcw57eXmg5/Wb51/8xd7SZrhu3s17xXnFutvlMXqcx3WjcaOUC+MmLCzAYdZjTu5PVD+/J9t+fvn7L/
#etI/a4893LI9ul+pezNmjGzcoP98J8Fxw4aLrd/GHxBE74scFVGqxcXRB/o203hMcH4UdudubM7g7xpNuLC9m6am23fibGfP2qfu
#5Cd4uLdXh6sE7hN8Wtav/nx41OIGDep7528Sn229ZwYxql0lS5/wC84SwY+1o/YHrn+U/66EU7iPT+uy7btmmnpMvnVr3qgXuyRL
#ypeYHFti8cVq43vGivwu9Z702/m2FzPXReZnVUuOW3G04tnwcm1U2TVFVa+1VJe4Mz68wQr3DR1abmn/fHTLBl41fYcPXl151orv
#cn985pkvX17Tv41+w7mcrI1B5dZe3VupfAmXeYNGlZ9arVx59FPXGTcwJeJw/Urt2rZuP6dro8gaO7639Op9Nq5r93BZ3x+Tp6RY
#Vkwa+ueNyNrCKMmZ2utGbewuc9YEuR0mYFOn/cr5nLsivajbdOVW2ZJZr45182mpGKLemR+1bf/t+UezX/6gWN7ZUkeZHTV8/YHK
#G1ukWaZFRQx8WC776sGX3ls+EZlb97+p3n3BNUGl0i+mu/R4Ki1VKayDc+i5JeOfx3+/dkBGyTM325TqunlVl/Hff1dpXKmqy5f7
#/FKh+ZR6SeUzy17xrlOjdabT08EZ2Z7rt1wRXEwf+/5Ts4yT82uVdM1y2RgecXD6TUH/1Zsn9z41Lsea41Eu6t30prpp/r0kf0Rl
#ttv27nAv2UmP5/Mzvq928dKrGbGzTuqvPR5qHr973txThnPOqzPOlgjXd3AedTvca/yPR/+8PW5m/3UZp27nDHxf5dkEV+fOeYP/
#2hLZdaj+RMVuVUVN3+7uEvN21MvSvo2bLgvo1O5FSb9blxpMvZZxYEna7Yi0zOW1p+YPdDp44NcnG6L85j3NUpeqeubBbx/f7fa4
#P3Wreyvx6rhazjWuNi19rPKf+xo+/+7ttC6b964v6+mcO2XYoOkT20my+vkY81uGy+dc6/tdjdV/b3qQN+q3kcQ6r2l/jK4aMLZ+
#Ta8hH+oY2wgj7r+ZIBk2KzFzZ8SSe9UWLklTjp45y+P6ZafdQTddby5LiG3WVjbwd735VJsSuSPLl1l3cF8v5xJ7fq507bdubfq4
#hYnPBMxdkjlqTH+vHW93m2dVFtTtG9b8tE/gtEUZHn91bjF6/897Rs8dGBJ4/kjNzWWedbr/c/aFB97vs312bSm7VBVf6vrS13sy
#z8aHf8oj2o5pdi73uOvEeeVv/b12rJf6QM26zq+DcrtP6C3NexTxOa/pGKNz7J2fEir3bf+7znvD8n260Dqtdp4dV7X9kfZH4ldH
#6N49qreo2ctVOw/NT/Pel/RLxbfOi4LOjt6xXLt27cqSI1Y9CnzmMrKnmyr44rqHqz5bjXGlxw2s+9T59p0mVXKbLloUoZrxqWSo
#+vPn1dW1Hfq9fDbigVOJEJe9j/pedXpHRE5u3GjxoUXHgz/fOlZ3oEp/Y+An2Z/z7lV4d3Ok7H2dLRdEv77PCXjzrsaoSW3CD09U
#eO64//jcrB4Xb6Q9u9/qWOTI8KHNRi82XdSN+OX2FPfWkrsN2s5u2D9TGGTK9ft+VbfttbbnKeIurek/LqnRjZTzf+3PulLt1tsT
#O5/Oe3atZ7ro3aE+V/YmHzL06vMk43OdZ+fbX+i/I8cl8vGxlis2SzYbn/WpvI1Qt4mvXNOrTGd5Vj/V+xmyEWHD3kmMvRs1/1Hc
#9WCridX9Vv/6cUMnWU7V7kf8eqyJmOC2eni3ja1WNjwV3PPR3RP3l+w5uaSmJG+F1yEXrx8/ny5R2+mdp8q50YjSsUudr89fZihZ
#9aHpUg+3cUQP8YPb3yXVKT8lZ8ZOybndybtkG+4+kWyOjprc6WnWi/j7rhdv7jpSKshVXnH/uRZdb764IImaX7//zv4+lssnMiNG
#d8i4U/Xw4trHejXM+MfjhufZVkdbT3VJHfwoeM6x/D8XpW7f02POvnEfHocfmH27ec/L2f/84jP05lyfI71z/esNq+P+6dquyKQD
#f9d1GXHkivaPlwtvBv2Vnrsx6X3/0/1909PuTzw7In/AviGSTWOfPDn84cLuLemRE2+mNNoz+Umpk/PMd2NdvWvM2j7gSn5S0IPm
#D19XELeevvfD6b8vK0ZsEtb7Y1dmlf2V9+6KTa6SeqD60/eeniWHHhi2cEBizdfzdpe8WOquUbojbMmyJL8anSfdvnm8w6plDyts
#/tCsWsbLe+Kqhh0Phce2bhCUr6972DDEZXGjJtNzd+SWXRK94JQmu3mvyLt5u7xlC0bnNh5YwrNb4r7Vbdbcscw40+LNyth3kaED
#7/WpUnbUT60mLVxy6e9KskHtx/y8432vrY1rjLuh2fDGs1zNFK/OlRaumpHrVmZept+1PfHenWr/Pvr47qwpA52Cn1TLGTdict03
#g2oor1peLf39lz2VpzUJy/99dNAM3bK1wfcmTm3r3FD9W+Xgp+MDDL29ejy6ui/mRecqjw62/eFoxVKdj3+fNXFRD9kyQjozVig5
#kivJlDcferP63lbGzc1rz/YZO+D/sPNOMcPA/JvmY9u2bdu2bdu2bdu2bdu2rfcx9vvPJLvJZncOZrNzNHea9KTtUdv0l1y9oIzp
#HcrvFwhLdnAkWK4+nEbUcx6mDHDB6y5ilgoaVRNoGyRHNjUMxzzEfpbnBP1oUtu4CjePUgqRJZ1w4xCbhZraMGHLMLFTxNKSZRQU
#aheQtllS+CMlUkBJA8vLvmGl8j7Pjnxl3Yb1N5s7ZCwo0nhBYWo2Cbsxc8ehCIfR1/loV/oZf9gBJusHGK0n4Yj5X1MKTyNjLCBS
#YWJJ/qGrF8kL3avUq2VcVIEkucclSIoYyShSeloBQaxqhIT1KNeDqoctvX+nkzuZYYilToJjjQ37lNJrrS1NJoxwACsnpKFSBgua
#pR65u0yNyaU2jnPhYCQQKEHwq908CBwxFIJbIpEm/wCXuHwcM5RoBRgMDDqBQRvaeZGwmBcxAE9+YMsWG5/icgGMq0gaRkqWjdHL
#bZEICW6rLO8JxcVkkfyzIoUKtPI8rNrEOwX0uoouswjCEySMXs+4XShx7Pv9++b/Tv7ZvtI+84OK0poGG63czPPZdlVyKr2MYckB
#uyNBBlr0n0iCUT3BA3xfK/ss8Z6lGMGekmsKezSKm7M4say5u5KQqYWbiGVXgximxPxl8xOql5QCovyk10bSaUVab+ajPKpI6o4r
#RPnSS8/2AcYBdox4Hu8gJZIfEwiHE/dZLn4i/6751TieHcFrCnpE3o8hM6a5vyLrqMrZalpA4kqOZ7COoAZij+V0iUWqDezPhpmW
#okxDmMVGOQ497thVe6PljZdceWW5K4ugpwqRmIvWRIvukwZS2ZvACu0RopGBUGZHFjLRRHFuEClnlLf5KCtCsVRRzWtwXArpyhBd
#kvnb+a7LQE112lRBmatus0gWoRXiMyx+XWlyQgjT6R5uwJAMz40SkfYGf8skbcD3tkJLksAvKjPHsGgCvCeJ5l5qr/BdOqdF8tZH
#E6k/kAusiINLCDh8eo+S64Mgpg5pHvJAQTCQSGl7CmTbRELRsdRRuNICbShyLN+awioHXaB0mL4pKouBEVU1zliLeU/DMorrzX2C
#7C9uH8O/iIirJKb4jrlm5FHGC6XvYW4U7ElMHVfsFahK/ldh8Zw3xyvcsogij7cY12miNp/X9FRhOJI0GZS8OUIVtRfTVkkip4Gx
#zSFBTYeII2o2NLiNBHKJ5O/RYsflVCauEYN7n7einvu5wgFamtFhM9On+GzfRAsIzvbpT27BBOIMpGgFizO0cEVBxhkmViO3Eq6F
#eUizOcV/pG5WQIuyxoESYfjmGa4YKcCgk7EAaXmJwKsU7DqhipallRo1VMhJMTGdhFSB+AfyIGCrHdhajkaOMshveL7nPuQoXQ3q
#Nr16wBRqKj8Dht/+kb2N2Dtd/Z0UB7tHESEMNuhxKwtaaSGwEr3MXy0/G+VArjhvfFxGEwNa6V0/6eLbL+RIR3+v9Lj0YWpzrgtZ
#P/35l3BPuPU5ZJWaPQsWRm/ntMaRPeIzxpBLGd42/gxe8UGCUPrsHolTa/xLCiwWYWlNTS6xO45RRlkSn4q0l7TOXZFOalVGgCTL
#B4atdqetPUHb3pvT3fNLkBEmw9OcSPibsGZWdCCJgng6jsAgTsvrzOec0j2h57su03rONJPSQRkTnonDnglY2n0PNZypxJWqe4k/
#QfIhat55vhPcM8Udls5sPSefdS249EuD/CghO32Mzzm6fdXIc4RDqYxLd8zTpJIDGmWf83fFuy+sz7l/5Sj+b40aXxjwKxI4QREn
#Aev4aqQZp3Yea9bzexqjtnmxYUn8Me21Xx9U41YWttKyQRF2iE5/wUvQ2Ab4n3VKN+lPABq7xO4X5UqU03BXBrnMDV/aMyZL/DYC
#VLUBj4yox/0H3Bz5DKA0kWnTVNShGpLYiROR11O36c87sjOz4M80wlhzvpD86VMLJo4b7HSgQ0lzqKVeQ2oFetEORChRiil0OZ4C
#zCp0YVhFWQ9Gh6er8uRDUn4TRoQfT+Bj9l9u8poWGdy7vp/DGjR1fdlxajZgN72286ervjPbPWD+BK/204HRsBRd369L8Jv7X5Je
#69vpYPmVuy34x6WjWLrm3u1HQ+d3BTiYr9f55ToQ3SlB8ikw+GGtxre9xqM8g+75gqmbshSb5DeNIsqnTKFop+RklXO4i+Vk8p3b
#2C+0biiKCv1jeSjKhyhV8qSWyz/6v7ylHsGLFrZbd8zTopp/b8vWtapUghEQXAyklyCCMkQQ++Vk69TqgHH3DoIcc8MO+DkSxeVc
#V7j8jKypctlzL4Goi8+8ptQORNDW/6wIcjJCkNdFE4EvuUMtKyvvhMl016RSO6b+TYH6h4hZVyE+UVfczv/p4aROrj8Gl1gu83Gx
#uj+1LAeXuI7FjJDe4I17goccJzsOpZPMFaPMBi40qhVOslR4F7C4y9ehRKlfyH7qFD8OzDT9PsWWfaaywFxMCKfEq1E3fc7vZ3Yr
#knLHvx3905VVoeiFJ6Ge1q3XgctFC2m/rMSaLevpAXUBZDo5ky0g3EI4jXFtsgyJ8BMObjKuO9P5N0HYLCxEHLUF1liTidoLMFa6
#bsiKfn5nx71le/dEdiyMVTJd526B4HZibtXibAI5X31fukDUBXDawTQbihW5iKLDmFK7bn/n0ZbXIAWDFuTt8Czziu6GD35Qr0zB
#aiYgLxTaKXUvgxRMX9/3aMv8ZblwIY4O3ReftAhXGU88eQcM7OV37ur9CX+RFi0nrldicss0hQEFyYWjUp1MV9h/YmqZQo+Lf/U+
#qVi1TCsl79PMx15DjFxSODsp7wh1m/qpPCFhXIjRCnwrzE/oIl8uOa0RsQjCmhlGIFwzOt+8j7z3rpJuunrdb1buw+YlhJVvcnk7
#l0cwOyKzG11MsspRpAfqHD/oAPRXNoJ1Medwzl5VqiRKRReKS1BQiJFfxo7Zpt3WLVO3N2G2Bbx4gtQFYHp2Dr5o/wQbdkM7cGuR
#O+1wzkiaB4cNc98wft0Zwidffz717/UpzogmPjtdHca0tHtz99S8P9dD3W7baF/J73s4k/6gmASai1nb8m8ptvNrmblt8oJpszP0
#L5jx0xFoTmF47ube/I0ZJ2xxDfVNbYH6JaNvwILLJmdZFhMase0bu0A3unbWNzVmMQNecBuF6PFwEvipm0SkgOpSRSnJ3gxCVzPT
#w22ER98f4LZPW+r0H5D6epXLiQhJNsHWjg2bPCu8Lj7k/mqf+uO/gxaH3q6HA5nk8MBJ6mfl5IpgFR5hIhaMwlQJzpKEd8gghEGI
#ymiVzpJAm4SZsjklobAGymensLMsnzCBAWvmKuG4esulhCyusi97r3p80WEDLqGYjCcFcMWkR9DM9jp9uzvskL5gi5Ur/2kIzAyI
#tWGvo1B6xE/cQsl7CDfkbjbWXLNCBSYIcv0U2Fj6YAeXWlUnM8O8xBY9ZPeVdFWaYS+PafayxtM48DgntBCJYZDm8k3lem2Ez68A
#skK16XpASpSx8r4ZO+PBw6lMKQZmFu7oA+PnzHsfVl25UKjSpxglSV3de1fhbBDAKszQ4y6Zf566WUpbPL3TCl9DmE4fqBkftbWh
#5f1HYN9JT72PQuae7n5s+morxsNicoNRegglSKif7djborfxdtOutIjYqZGoTh+u748Fb77BPNcBS4CCkhb5NOSEhYJpCcTb4SaQ
#8Vf9gywDhlgnd2EK+s32FAFTvTu6QePhyopYhTIEyECcEsilkemYw1UiDJ0aBJHQsRDRX3bfxoIaHiAel45JEJY7Ap61qVrGHelE
#NXGVz7SzGH1sN2TOEG1uFnqEmeViUngYeKB5HCQZ/RJD7ZaYZbUtLnOVxB2t60tjjznd871xNkdgeuBu+LvmsDUYFEfxsm/R5ljk
#UNepVVe5VHDYb57qxqPfe5RUGL3m702eG0uO5bTG8up6yhDG6XGcG0eN47WiKnEzPDfxVa26oKl3SJfg8pNOnY0odBu3qx1ZpZqs
#erDAGeh1E+TkGr7dpKTiqXYCSa4eXJ9E6q/vTf1FLj12+T0ZP65r6DZQGIV2egOkQfuGq/zqxvevGRqz86y7L7oD0GqHVddTje8b
#1HSD6QL1X2VfDOoMCVEiQm1ycfrarBLIlami2nb0DN/pKW3Qpq6ee66epjnQ9sge2tbxFWntpzifZmvgtn3/yMqhF6GwjZ91MxAB
#pidDKxhoL1KXJETIwPnGA6gjqRIj0qo9/Y2UzpUqsfRZq9SSpDqe6HM97lfHDG+/utfcb+3BFR2E95ptyGZYPn8moPA1zFCjMxmO
#t8eh+nQc7p1oRhVyoRMPBEGgj7c+9uBzr8oz5UVlJnPgy/NiCjdoymtb6JTJgzij26bs6+cAtGDwGxkYlTOMpzqVtLaS9Avanl5n
#DdtbsrSUUTCLBzIVqndJNkL6SIS7WugE+5o2f5mdVD2YJlQ8pQqeLx9z13LHZbbvBqItmFgHYfK3tCpVRHYR9orsLiDj0x5GgRj1
#iSxyzhxvHZ+EQZNQf0W0plZ6QA800XBe9Rq2t97We/r+hkb8n7l2uUbL7cJrFzq3XGr2tPxvXNe1a7V/3mU1kH3msdfQDCdJJIVL
#LRc8fp8TDRDnLT7/1Klf3LT9evSaVC97NTWBelrpU6Z4QcU61qCV78yI2hurNSudW5kFu2PSLdxaG1Zt5ym1mOkbLkR1ZZ0BH2BG
#XzOr2PE1HU/tA+SrwyOPNYMPTeTkTNHpjR0uCm6n01xrdJ9d/lGl/+7FYgu221nW6X4VFxToPM0DrQqwEcgBH66cvntIAod2gFAW
#A5NwC1W39I9kH4t2PECFGnkhWSBb4Gq9Y6Toq7j8Wu1m5e9Ly+BYH+IPte7bMXyTpCNt/q5rbGKsO5FTW/tN+owP/T0vVVnF+Lte
#32mp7Ga8e8FbB5yndeyePUPmtotourrqR2EMjhWP3fEq69zQUUXlYi6YwWec21/DzKCjoXkGqP9bOPSADDhFpEbtJmg7UH69at8i
#3XJn5HETGlIxzNld47jKI8BJSzY5a5GZwm7FlNhNtNMUn8D5JhLXYlVUGu2MALYXCRSyAzZgED2E45MHy91G+xfzbrjnZxad8jhA
#utKWyMaS317bsts+mHTr39LC5nUrDwcfgYnCRXG28a5PY3AElqg1EH/cjLa2m5fakRx0SD6pwX1bVBnU29aolnGj6xNV+LGGU4gw
#+D17QlS+DLQOKvc8+KE2CfwFA/HDf9lOWH85kyDf2taPX4YedL6KmbT41/FdnWP2Xn6uWkQkpguEuo7Z/NcS3Hq972Q5A5NxRD/1
#sAf6o4hGgLxuTBm5ud5t0BpxvPGA5AAMeMMrU/Go+qC4gOOD4EOTP0LU54QRFA90xiUS1KAKPxuL4IPCMg0e9ApPksSjNomgqaQ7
#J/bfRhPkQ9wfDB8U/5pNE0wdEUQ9CEPA1rUCc71TGNQV30R54ncfk0cgv09RgeCDzj4FTvCcCjcHxweZfRSQs897f7SHAMU4gVEM
#paxC8EFlBcOfIC8iFNWIPCgO3CRdXlEIZTx7RwvIVerQpE+UOmVq5FHW+sMY3U/FIvDJ2GmLeyv+ol+j4foNV7EyqJD3Br11Wfuu
#Lt3AXP2pWP1zct1kIPzFbSD608D3kSnmMkTbatzdEmXS+O687bJd1ak1mC0/+FfdW7nvWvD5THovuL+9Cmg29lAQoOB74QjDCQGB
#ayQTyxneK5T8N7oHHr7LhxyPgeSH0KCXbzzzAcZlB/beoOst+MkFIE8DygH5uVETpsPA3y29p+qM2bgvRJcyO1yXCNBU2gW1O05r
#v+vFybHoBdhXfNPUG/zry5wOKK9Nij4zf9fEeBr8JPhYACrRRY2jBf4kP3464fNq/CXYSv4RXNeWQOz013CMJMCmuu76pjitfWDa
#355X3RfW6OREdFhA3Xni1alXQ2/hmhSINl+bSlz6c5UmNiWCq7w1NvYPk0SctVWhEBppJtB4p13sjoKdIV1Yj7g//evk64nuI/cb
#6229K6jPYg+x35HtUmercqbY6Py0pEp8dfMwLGZE5APmud3Z2fhUi7IJCgjIj+fXt36R/QyeDLgf+P1SdNm453HepQb+Hh/PXrut
#P5AXhuDA0nh3H2Nvcf86MIY1XDLpdonmwy3tE+jVmI4jMMc15tgkw2I/g5c0g3JLSVAA+3YqMnsJGknhR2XA9tcUxsYczIKIysd+
#MOL2fOMy1wRga7JBoefthRFrwWw2/SGfAWlmvyK/OspAEPXjxUAe1omr3Ygzjj+33eBwkUz2HeRJHOwpjvhmjIbg8fQ4dBwc5kKq
#wq8LrCfnXIMWc5ILi/yQj8EMG75VgNjnpLz8AF7yqt/A3AZOvOwoP5XL1T+OOZ3R+vbfGEMF+iz0yfeIm4OBPM5wyjTv0+Sz+5tR
#xs1xBjD6bA7W1oR9CcxhgRJZF+VbvzPMxvKYf9WH+BTb80RzOhW2RFOosRYq+dcR35FIAn3GpK2gRI8g2ZwxrN6xqOmxXp0z7sGR
#f90ezga3DMS+NVkC9l/oYniWiXP2PN4l6oVRgM4IRR+HqwohhSOc6j2eXRUXrot3zi/3gTndJhBHsjSB+Tvd8ciaezT+toL4jZFD
#fwxMqTy687Y+hzTsMaJ1Qlp7Jw+vbpL5mtBJc7MYCGdh04R2QrMunCd0kFNzzB8JSNIcohSVSk4vihrvSNILcbFfSX6HlxC8GnWi
#MPicYjxhS2Fut88fI/6EUewcXRSN+TljtcxgJLzsmbLQgCBKmELJYywsDEcdDhytCeA7T5Ipw9HNngHMPn+wI2FbKuSfgVLIziCK
#ON/IPfNDX9oN+8LzBDv1YomTHG2x07oM66fumrXSoDBUsUiiTJSKtRKJaiYaqcyOCYVytVKIF6uUrGJZJF7Y5fVCT8czz5egBa1m
#J1HtYedVpkrVctBZBa2FLr/cIHyehCLSQpARMW/lAleddkmkQtls4zJKpWXwHE0JqkxQShw56EtKp5AmfudTZdZKNVD6AgcPL5tp
#Qra/GGZ8tqxW4VJ2C1WaT6RXK48EHyH1YamN2oIpO2o3sr1LEOa8m+3yRxEcATBGTnC9T+WGIWmchqBsccqabtzU3tNY34BU+/T4
#75p73/lYrvgDTk+jExf/u2Jofq3LCuMeHo8j6z39AL1f72g/L6a7EXCzgaJ8y8+xeqWydbiF2D+jHeRqwWSz2KMR6YQLd9qtFutU
#FDoS6Uj0EqllQt1yO96ul2tXnbBwJlm2USFl2WXzsMyy6SRa8bovugnmq6TatkYCww8Soy+UnT/HQgRgRkToRkRwR0T4x0QASOKo
#jYLzxogRaHpjzGqN8bCIANzOYAhuStj3GR8elEYFHJ0PqFAI4phaZLmoh076HKctTPNb94EGRBK3kjOMoQkS59pomH3i+Fxh5YZ2
#rUTdIUZjdE7UNNAzTZtEUrNxvhYg96IIpioOEVzZFscY5ZxjJHXpykWYeQPKiEPQnrDzEK1iJUfVktBHSsZz8PAH4g5RdTs4SDSZ
#diaRJ9MKmGTEH5AvUPBoIlOJYCJiExH1kdXl4XcMxK1lo7I9q8ekHj57c4t0wtc9iv1B372xRsdRJ300+kV0cGd+3fVvLGoTrwx4
#M2j2JtK1PKl+RsP4t2yRV49+5SLZV6ZEDKEWbH6NBhuR+T/OyrupqMc8jMfIPpYdxwjfgPc8GT/ED+exhT5PNGnCMG0J9ldC2pls
#6iv7/3WE3v+/+X/gP/9Hn6BY/2dA0P8x/8nKzMryf+c/mf9LCfC/+c//Bfm/+E91AwDE/+rHbwAA1L7/X/nPQC7sBhucSLf/AkDR
#IAIJIHNQESGgghIZAq8RoUNI/jsIGiHyXyAoFHgkAEygGrZvI/gGG2zW/i1Aj9ROvmAzMOsFHNw0VKWLGYEDXkFCV3zSwd9fTQnT
#2G/gNnwRRWoqogRZIcSHCoPOtMSr70uxa56z3uWWrSF1Wq9Aj/u347J5qEA6AeQmtBzG9mmHjN9CCw8vL++lCJZ1kxJR0rZHn4fu
#gTkSoeYKDnSRBu5ezSoEuGIWCN41M1ILwWH/dLjFS44IoSa1/rsgLjlXWztUjK4Z8ZpklV6e/9P94zqfM36SjwSFlKrB3+4k3VTA
#8zOH+f0PieyVVCCRGja1qJYI+J5jE+dZbnTO1si/Gcwizp8/naQ/60QIEgkCTyOQCM5JcjkQeCM1K6lZc1THrlrs3YqNnS27vco2
#6n/8rw/ZvfILJGjCzK34oMHfVk1RhNGlGTaDOCclf+vCQd2AAiDrW52fEgVE0AU1QMXhCLZVzX+wKSUAJUg1t2gFhljWlRc3LWyp
#cPS9e5T+025TIvZuBFuGmJQBf7WMtlq/9BMfshtBTMIJrFTJk6obiQ0eeSFeVAQb/V1L2BRUBKBiH4b83ALgcJaXCC/BS0qK+orV
#1WJ8eS2Wks+5bagbOGPAQsOMLLG7elqCAXHDBlJOAmeh4AFIvr/Z1fd8AzARJMBoQTxFZkGVQ9SLdXKGV/lOSnpyezRebtl3+O38
#AHBvX6P7RKhOhUtcsztn8jdk7MRWtn1fNORogsJMpUyvf63fqqu9b5LuB92ERJPpkMFsSDQwaz2CYWah9M5YkN2sNwEVYy75BJKT
#voAayL8rryG1DGExtUuWBRnbzzGhPRaw2B1rddhJhq22WCIIYEYsQCzZN1vXu6+7NwSBNBYMCZSPQlq/eyrVLz92SUAcWbpOtK3e
#YVzSsa8x8pdzGMi2SK79f9i2fuwy7BSAsJhNhMJCWrQSMYWaVwsAJYACV1BM7qKPOPP1/ynZHFoIOMPMeNat18XNa2JrYNkhyWPp
#ewlkySLouP/6f6hsd/273dgPoRzpC6wO24apgKt8i8Tl1/G9fOVpH/bhFvXvchlg3hsYrHW8IFUCTvIUDUFpWPDwi498C5ombZYV
#4cu0Q0UxtscXPFedRyViBo1ohZAgBboQZi8tgXbNRzHWl2Xcvvp6Rq43xu92aQglIAbBrMEbiZjePHz/GWsQ1/74UnRxj5nFD6tS
#JgensbX9Gsv80FOexb78rGKNNhJNdQDLdZ7Qo7qKgaoBnhPyh/P6dINsgBhQViBnRgKEAmxJHiS742YBICkLa6lRyOCcHAT29ChE
#2VDI86lUoFCtg1+VA1qtgrliwMCyomDZobBsiYzIsiO274bddYHzPgB4XdOuRLqUgCYCoIJxFhAwJK8rnBQIE51GnIo/XwAQCQJ/
#DoMpYvi5Klj0UNPjYQrwoH8X70ZtAPf+0CZGhTEPEqFxgw9qmyJ/dh5Cl9uQDFIHHEgNFtnLsSLKYcGXa7ChcUFZbOsGVd0RtaRB
#wOpK/66au92jt76R212Ow9YZfPjsN06IE0YphoGLYQcsahm0QGHQgosxA4oBE+TJ4V4g8pgEotsPjoDMIiPAfoX6GQCGoeOFHQaU
#VWDKtTpPMHTW+L222CLGl/3T0ZLE11k6a8XUMoqASWRTubW0rQVUrUSZlnhmn6Ksld1PCeJJtLj0TdxBSh7sAjj5473NV3Nfq3/r
#ZVtVFzZ0r7/DX9v+Z7VbRe3amBfFkRwXiOswrdtayja9VqWjF20FdzesKFH8Mhh4VYXGeltURyXgCOV4ZjuOY6U3qKM1DaoE4Uun
#xHy3FaXe4nCZNfTSffI7enxvDdfqhPs7QRtIjzUiHt6f/PZspjcXqzPVzJmvDPPp7OQH0X0ygTDZdzNxPCTm3dPnzMrSAh7JwL92
#4vQvgZV2Rv5Ld/idOL2aoNlO0G/AC9rZ/aI9AXBgH3spH8kP+ln+VP0BX/E3bCFrn8DlAtQaorhWMp5wIcAfpB/p1v4Bqa1H9jz9
#7jtzOlvTf+bmfOl5FXBpMR0tum+2lgAdBKMYhbc2Dcbc46Jr9GUeTWv+N/SjX9uyUptxqk2BEh1TwkW7KWz9BPDbziPWM1NlHlfK
#Ke2QAc0BF5cu9x9qYes3ke+FIiShVKREpRx/OYYbYsrf951S/KldgjyEMsC9EIAoVxqghglGA6I8kCTJcXmGu0c8H77v+PCsoW/2
#GnnxvidTiYQJOm1MZJmsFp5HNw2OY4DJaitg7SLnX+XMh7NqmwCyB6Md/PcXsH3jn5mgZQK4k1BjAqwG+Cu0gU0bjwNoYWhoD/eb
#j2H40YA+ywTgoGFaWwx/DbLTBAIVSwMusIjAHyYUr4jCU4qQKlYhspwASIXHQsGrNIg0LIhTMq+0UMRPn9vLD1xVPVY6zw/P+sgT
#dDkfCb2B2wgY9cJodvA/8uXyY6u393sqme8oeT6f9jN4sLHEd6mujOu8XYwZxVxDfXsug7gVBj/338fBGG6ZOXH/lJtqIbSDP3mR
#mYdv6Pr+53/t+z/f0o2sSFq0iiskmpbtrXGVrt1RttHFisOOWcbyxYlJMimXKtnzqadNyAp0dBSR6IlEqKPk4Rp5SjymUw1TqcYv
#q/EqqWI8slmSrRaDFqtSVbLYkW63KVwuBqCwY5hGFFsMwxQw7Ei2KYoqY5jxrIMgMJD8HyY2g0GERQ0tTK+f16e57mN9v10fr9uD
#7vux39/SKrNgTxqZpbVhlVuO2K/Fuil4S2mIMjJY/sVJT606CT6arruAn1zqI7kQ2GK9NHnOUD0v9LHKwqVW1qj5qxvHM+adheps
#oMWxmMrxIkp9U4xSEbHDW5kfMK6yFtQq3Hoc4jZCgaXxKl/aJ9Dp/6oRMlmWHVNztQ93W42Ni0seFW8GAs/zojIRuj08T/3TL9WO
#NhDGHh6l0wmV02w6lU32d1Mo1QkL0vdwW+6pVq1WqpTrC+NXmNRXFinH8exCEsk4Du8NBEL+lXvkSrYlTMAmEYGeQCVCBakQWPyD
#wOoNUrGn/FILikutUCe9Wyr8JUmSL0nQIWTiluDLwJPnPuNojU8sYie93hM6CArjcvFMlVBHDjXpCdNnq0JR6H0mBC0ZoQ8SKYLC
#KnUD7nIrgkoyeElArKeBGj1acCgMYMmM0+Ld+Chh8DLBIEUHkiG93N3Ppr8Pfx3MGQ/fz8fLV9y7ZCqrrexpVck+97kwSjWMF96w
#yCRuu3T+mf3OEDeuf8+0UA2V8HxjQ6/40cY8m39047eKAyAytUnQoleeAsDOnMsZmw8T8UOBVZ5V0v7IVrmrNItdpMD7TGAv+e5l
#y99oRGQKaJ0aAfJ5Arh6r9tj/dl6VPGvq8qXBP/S5KwRNeDUg27gkPSBdG2E8KdairPHWyHv8t93lJzo/U7tAf7lMVJWF5cmo7EN
#79uy1EmOUpNnunQaZMJYX5V6i01jlX21efv5IXZJChmmcBtx6Jleo9Yjf0GoStjCW+OBZ8NcxRrHIu9H7TyPijldg2TX7Rhz2J/t
#tney6MskRrsuergxoDakfAq3vojQlEMwZSndULBGoM9UjDNqiFiVcLDYvxLpSOegqiAsDMNCImplURYWEpIV5IBAmxNwjNQ7nUDh
#sZTg4y/JwjmhQOG2M8VqXMjdjiiOo3FFSiGSTXCoLY4woqIsyxNqFGCFncaelGRipiDNd1SYVGAkyiAIDk4nUSSxM7+4UNOHkkgs
#Q5npbMwIIidsaQgrN5xIwp4/PyOsMCFMqSFIIn5sVJJxRC18ewPJ5kOE+BUbtF/DyR/PlCh8rq+y74r7pPG9NKjxcS9ZeOt7ya90
#2ZGjuGINIz98gIygQmyfpysvRR8iEyqhWDQalTY4P0gZanfj6dJdYCiWQ9qHk5qgOQywgjAedaIX9I1EmwK/Ab6BvgG/gccBwIHA
#AcFpEvITAewqRBD9L2B2+glzdrNKENZKMdyLpWBRa6fJf9EoVX6+s6AR/V9kMGCEtPDAOIc+nUfyEimUhc+mZvzdMUYgOBrOO4KA
#BvVVf9T1flKGCzZ0wyAguqQEW5669Sb0NRGSJtkdjVCECEoRYjRHNHrKLq70SvWH2IcgF1NCJI0JcXlWu/AHhQA7ShHEKIVgZepH
#PP1+XJ/3Inw10GqFIO2Vgj1swWKWQHOrzKLXSRvq1jomDupOP+CQAMzQwVXCD4YWXDYDzzYEQxNO69iQ6XFlbgOueNtBBe5w3PMG
#/dvVCNzP7JWBXWCScjnO7p+YvkEAJA4IQdmKFVoGG0N6WmuNsXSpl8micjZ9Ea37oEAXlz2/IRqokhqEu6sNNNRg4S6TPqnk9NrS
#AF9RIqTDr/52v/2J3YhwPEKKJaECHhYbI1QnReokzc2ImJXF8rR2hmGbxD6JUx3LTRiNBSx4BHovV837xhMy9yXhvzxlhwkdSiDc
#BA/i9tO/aak9j5MwabmOE2t8Lpv6WzYt28oPM6w63eK+hCkUZVnmXRjmWaZtHOfapkmz7duGZUD8ryXikRZQa3CF5kAnwGskNNtR
#LW7026K2QASuBvQLgAOIGPHi1fDVPC45IOG2M/e2keasdqNXOwUxC3l9g7YiVIWEA9bwZ/8a6N+Z7rux7T+YfATNzyMqfcNv6cuq
#s/n9OzSi1Po39A996eEovQZ5ntGkJShEQkH1vhIP5MNLNLZHpNLADPP3PDs0Ojn0ygePrIgoyY2uWVpQORFEJSYo1GHSjzvIkICg
#wPi2ZHS+CZCj5OXoo4QQsMd8xIykxUiT88O/vS3+ED1C4Isi8K/F6Pmf/V07opedgK6q7mZMXkb7hlZ43hHenTHxTj+C2h4zrz+I
#rpE6716xC54Ju648MxrgkAyiJhMJCUTJZPDIrZbUBPTw40Gon51xdi74VVzNfE7yJTJWZcPOzCCiwtdJEYxISTL9vWko6tqmLSzr
#2uY9MGzmuPLNd5V/D6+0bVtrk/Ybpm/ME9dL6XhAtfBHyhQDZ4qdzfRipNzYwJg2vZEcgwZE3g5Cks0LG7aBjOTXpOLEQGPampWO
#KoC4Y1NKwpf5gwoDHiRv2OlIDfng9X+QwWeacDGBSJIBQSgJuBANPEC1DYgSBlXqIbJuxMnwJ5D8g5H6YeyVFSHWmjZDKM7LHLRT
#iTBQGCCuSGsvsxXtsgYGUCiC2QearsRK32m03Xw5AoaiJ+nofqSKGvtvy8C5zR+4AK7mqoDiS8HnOHcsAY8Ybux5GYnJfV3VifOD
#YPiW+y+ODDf4Xah70BNH3RA16mUA57UhQYF1kVvWdr57ZAaWcJNjVyKslNXRrsV8NfHYUoso+VD68dQyqGYQkoUqFchaoXqHFQ8h
#+SSbJkvDMyaS1OUo1/P0tZFUQqxR2eOIT6GXP5ahaKZTVyfvuASA0nBp0wl/8IGjf3+tGA/r+tE+b671bLO7J7g/pr/TKAIBuwHJ
#O0CeFNs3QneO0E7qeKu9Hwuu+h3X4v1XGvpfY+d4nFchxH08sSn0PM/fW9/IDTrs8wTljLiwXebRCGqFQxsj+kp0d8yDckmlEs+9
#9d8HscyjgfeefeboFDT3iMSy87ePBifDeuSf/PG+1/jsvW7T4nbd93Hgv/+8y4bsx3RepyT7yfF+X3J7X0UHtPs9+CC8ZdxGCcFx
#XyHhgsUDRslJCssKSozMDEyIkOm0QiQai3gQh4ujRXRLpRbokvW7bDCbTibUqyQake6rX+LcXZf1c61YsVa8qvYMgGFYJiBmxaKW
#L/zheUQyHRZJzXPdBzm5nVvtX3Wt70kT7MyMPqGp9mc6BXDXcOMV+2J+ipF277rcw5XrNWXcVlvt7lOLyoWtE9A6e6rzuT6WRo2i
#/hjxfPUDV6EnvKtr9n6eZtBi9IZgLh8zc0anvQYWudISG9M6EEpftBA8gqolBMjnqZwQqNuI4GXiPg5rh1wrEQk7ZmC76b5Wk3De
#4gQUJxuxyVHq4rXqhlIHF3n5GiYfa3mucPAHMnc4HGvRWKWJCfe+KtvMTlCCGeLcsV5IaoMqFfjUgiHfn9FCX6pji1Rex33V3vaS
#2Hc/bnWPZb2Q+vrXXNy2d5Dm7PRRMGNHIIsLEEizG1jScB6c0cwk8onBZXlhYMCNWCCFAEWJKrzWCM1ROMn4vI5WpdqbzIIM5Fvm
#j0KRxgYOo6UsNLNZI6WOquIC7ILIRi1HoRbAQaOT7TrGaOWHrzTKSxrXsudQq/3SIXiSrcHBqW7aLT8DY0GoP3AMTc3L8bgTc/7o
#ceenu+QJbb8aTI/ivBSrCbqfTTIeKMhq1RrB2DTaDo5g/7ViX4GEnBN1DsecfEk2tHHvghm4ts08hiJoyeGeNNW0yF3Q7mkh2xoD
#yO/3tmGC0PqLZRa1kDhiwis3EHRNUi+W6rUbioolxdFP8KQT2Is1l1vxJWVgXDIJKsIwvdZsNq4A23ae1iJW19vmrIidUZn/bvIp
#KQ5WAu6wqYNMygjlwiVK8DmR2i4kglzllnUgCFk/QXHDSPSnkxfKDQWrN3adNz8sL5enxDmpKA5ftenv9mIyv6K05nExrdz1lbkt
#S0QZj7faY87p2NlHMkWa0BDYxyf+YJQWdF4yr8RTcFP/IkyyMBycZN2Jp9rCwUOeGgZWpCJNwzIXSMaHjNhKE22ysiuYOEzzyqvi
#fqZ0K0pNRYlCdfFZIElMedpvAVZ3KHYAARdd+gtMkDXtZT38nR5FqrEkGqbwuoAC8QYG9w0MCyAMIFExoFQ5kK4MoF0xIGGNkyVE
#1ExY6e0+B2WdGL9LiH+kWMVvPm17t5FbfHjzclJsvOYVT9OWd7x2fsy4jh1BouoDQZImaSBVinrBsYDCRD8G9sbUPfRkG8X2jPFE
#F0tnsPC35j54aQJiEPXljXBmXkqDY5FBNJhZ00/HOsOxHVmlUy9efLVf1aR+VppYcAHzcTqwiAeebVzLJXbIinavh3oCAXD4Jnfm
#iA6frksDsmB0JRJMvXRXHIH9yy07SiOVMkrwTXaf0JHwC/Nyh7R/j6ErnxeuZUL0Myk7nLzasiUZm103/MYLmbxDR64peZltxtix
#acwp6wSS3bL7wTmqOBXTxA3p0Hl4S54xcTuOB+28y6BLroNfke01zxJ54kBmgqikGq9HLON3y9cSM8iAoI5JlkbW2pUQy/iEeiIr
#NqCkniSYy1y2dXKAd85acVsFsIFYGjUIqSChRrsOWqELNYkx4NqnVLbOk5Ptf3CVcIEJp4IkLcnM3nQ+boBcBguYYsw81Ia4RYXu
#YHmn6X9gxWoka2E0yCdVGKsiU6Phn22wQKP1IrUMO/N7vxNJLriJfRhSbrgv1CDHGIkbTLk60/2kbS7Gi13zxPy3tPL2a32fUdsZ
#zyR15tMp7XAf1Sx/MJjsbFypa7zVJNGGuKZDN7QZqFlmJiVApNSTAf9QEPlGYpW5nPwF06n5jNs10fkTgoHG3BX2vBnNzmRuswmj
#2YqOF2eoDybuTyf1lpCKlfv0EdTDEHto345xuRXrWLABe3Z6QW2CwDYGa1lf+1lX6mIPB9ZMX8EooQe5ldU+cTNYSbb+CEfLBwK3
#iTi3ICoHKsgirEsDgRPlEUbnSAWRhLmVOYWL7mAgknXBVB5IIL1yOocI8SSizgELIlpUm2SHk5NqfEpVHlSQVViHBgInzCu8zoEK
#MgujOs2HM+Km0zFnSXCBpAovGsK3CCsHPJhwMad4pykZXTI2smoOJG4aZGB99dMjZGHDlhjQ1RkOHa9th5LvUkPFV0PNZ6vgN+L2
#fuGG1/62cZh9O954NF55NN55NG6K0Vk9vsvjFr556aGy9FhTcqwqOe6N0Rk/7sv79u0w91rjvcFMd4sJW+wkP41UGllVvTtPPHsr
#r/no2Hy3Rc4LL7iBTwc98RSwBWDC2fCKDsL2HjLggFshmkDbT5hSomu/qq7ujyp0IrOhL4K86licYL68t5J9JGUCZernJuyFnLzz
#yVulhgHNaWFLhBaP8dx87UKQUmUaERmNdL7tnh5aWUlVGaoyik1mAGZlpipu6gxNq/KLqDmTSNRoIR0tononvNop5O8U4wc7Gthh
#dZnEwjk+HQzYiq7SYsTqqOJJFKWtmUwzmSS+1MZ+I1vehixpqu3ENa1OtJZIbTlv5EujRYkXXRZ6ZCYz3tVn057edWNRd+WWQ5Qf
#90PcR9zXx8uo5pp3qIDkakareSd3pxqngS/mRb72Li+RMZXpUtG4t5yDg9atEWvZJZm8ppCPmCc+L78r0rmvX+fVS6dLxWW6CeDY
#aV7+em1/pz+lkhMVX7WuPL6rkSgq2vMS6+T9EpRaIRLFlOQVOVbl3kzTdtpH8VlEHifSjrpiBAMcUQQSBAo4Xh0+TjiGIBogYJn0
#BpU2BkagyMjwkI7gBWGIAdYMrhAHRuIUGzSTWEDnpmkp6ZSYYSzmsIzCS45/wPxXHQkZClVEwkgWm4yAoM24M577CC05BF2y4c5F
#ZgiACGP5S6PJMkDt4oNnBBfpBE2m7KKWTfaCmYeIg3tHmL4YKAxWDF6Bi/lQvOa6UrodE59MAeBOT0CVPFONgsh4oCI9XjWkou7R
#rPBshRK5uIncFsXPZE3x7bZAaTwMEIfxAsgPhAYDM5XxZg/oDCRBBbO6W1nwwJCEXdFQXCW5oosNq31EaFKrTyEhWZTWvMf0ObyF
#YmRymsUH9mIT0qk7OGc+4hI47+CkBqBEs095c9xW6aSK/rNGgINZDy1ht1pN6Lc4FoSTYdxaMHRwg/BiCvQPhFk+CSYDYxS9HdsI
#n7w44KvEGIndQQ5ecjIoKg6ywl+lwax0Yg27kM3tl9kIvPikBKVFcPltOGi7SE4iR7KKdTJZKJaiZso8wXBk8P4jq0d1oQnWWqs9
#yjLtlgPAZ8LhrMoRXpmYSFxr8XuZ00sObyUQdRVe5Pimg7Yah2HTk5Xd7g5bGtdLvWSgiTlg8UQQ2EKRMcAJCYgFgkL9hbH4+yO5
#KN0C69AoR3ePtmNAkZ0T+lw1CIrFMk0QT7eIJm0w5tGcaJqabbsAMWm8PsgW9wCpF5egu95EStNL/phbB4WG/UJzRBLE11jiLlUd
#UdQGBzfZJL42ZYmw3DdAtDgLjJslgLxBkXLDYfmVX6WJDfCGVzI2PTcKB6VDn79cVTJS3EUF5Rnbr6iXUgRfZ6e0vF0PXSFhPfo2
#qccEydamNv9gndCr7CXeDXhnjI/YIiNQL2K02FSpkDfEN8JikNuVgGULOZZdjjuT6Jct4dP1RYDhTSae9pZWzhijvwjpJ1t06Fmc
#B5C2kXx2gLhfxnVfLYoNAq6onFnsEKy4Nx+AjrzytnhvfO33nNI7DeKzQjIvQBkOC290rY0Ioy5GCZF1LGYL8H1gNpahAHya6JXl
#wQ+9HeURmqeQcOuDgkuOmqjX2wkKX+c2AARhXLUKsWKgHv/YFcO3Qgyt2BuwXkhlCFllpEEmHO5a6EXKmFoCI7455j8F5qTGjnao
#WODqNdNAN7aISDXj0hGRSLyYwmRtBe55+ocKt1s4R9zARcDqKi9/SjtIJzy51GcHXuRtyrmcTyb/Hwi59fb9cEcprwX+/gk5V7lq
#kiut8duy0qPKiQq1KFUoZt9hnuKHDNEu9rqZmedbRmbKf264vtX7XK5N0uI7rzf5bJK6wxy85CRWaq6Ty4kdDIKmeKhA7D43dwu/
#s+a+MHCReHj1WQ8r08H+JVrw1oA6LcZXML/8c+jarEy0V9ez5omGXdOQTz4xfXo60MINL+0Yl4vZGlWbBwb1C7KSIwwP8VF5vU8e
#+IcBbBEn2xsWrR4LMki+jJejuX0pWVJBUq2up5g++BElYCgSwl8eYenrsxlVVSEYonZMHRtf6xoNGVOTpL7DUXh+6j0zcw6NIa61
#3la0aBhvPGc56qvKaNJJFyW1YD8jvatw4tXAd6jeyrFGIZ4uJKTVUZSfQ8ggYJCB9fz868g4P3p59GpW14oGDAIvQfoUCtG5N7QT
#mWiafa9fnfAEVSwfzV8y+mNjkIiqJ2zdPIrN32m57moIHqB6Unl0qJJDgrDHgQP+pTcsloYr4BEnOup7Wnu42Kix2Rb/YuMIMJuc
#uuSaeRdHMQaDkhvOunRjJpqO4KwrUUXXaM75EGDfj09Nd/CB1VzB++G5ullXFzhX+5bumuYKwKYlHdnjS0wig2dCYf2M1SotZkaI
#K9GOIaJCRbPJGXaaNxsUKR7s/LvqD8gFhI8Oc4vuTcCAcUfGhU4U2sN66fbJCa2BjYj7F/O21/KVdErGRPHSKoj46ejDR7krGEdB
#sLHVgVuuLoPjBcKRi8wl6MbDt8mQLekuS5i8+jh+wFKJ4nHuWzHdZgRkoqlgwlKadGU1sCEQJEHXCjOTAEwN/j7NxdIuJJzpOlxV
#ofdMjS/agb1GiWmHrdtc6TVyUrHhhC2Szdn+W4yjCIgileTe0sr0ubTx7mnha2u2Ft17/3dVcMEx/anV/SboOenMpP0R/7Du9FkF
#IZhIS6wzqMjfYhqDuXFyi+iIv7WzzyKZN3aWi0A2+A5TidTre1vNvAUBvylDV2PzDBHzmK89IJHHN8ccwZgWcdai+qDKYO0otzY/
#ouq2tnrBkLgFYyIyS02OduMR82OEJitkg+vfAIrzRId9bolxAma+yASVRVn1EorEDhqsVv83ZRSrFSqSCNiWfslynqXDXZwYCX+w
#E4RkANskCaLux264EHg98hB2H5XwMnhJdm+RY1FuNwt6oHFAY4OK2X1LDkRSTuexJEHvcLQNhOWFTdW6i4Rikq30tm3JdiU371BI
#At4expxFRkoU8RgkNiKqQmABsiRvhBoYQX79K90bqUu90MuabAK3KVPFW0z3oG5KV0liX09GIM26MNK4sm+fEXR9YQkKU72fkcog
#MIxGLHTEx42t11MSCJFhAmI5c3IiVGBiRtL+6T3dlqHkSFpoSGq1Zv0XFWv58UyBlQDT+J+KBCqhA3OTmxVJ6EykMkBKzV4hRFdj
#cIZyNYwMvCJJaJ1hZi6RM6RTTWStsbhZdZgwezoegUN/c5cIt+O/JxKF8P5j+jTpgiUPDBlTTJzgJ4ypz/xV1wDB0RyqSSMKmRLD
#RZm0Lswt2VumS8R0Xnx2a53znUgkPCJ5cl2NyrY4G/xtmRw6dcNPmyryfHmXuDQobH7EcWYJZOc0XshU0StZa8OAduYjuxCClipa
#ZORWx7o6CixtUH9LVeb6min3Q9HCKvWIIS+COlRDLu7yv7sAwWWpaFqq2QT3jYcOHjAn1EMm/9b4cAwgUDCaKe4cP5tbddm61J4Z
#wZF+a4J9tj2juUtlJHqcjxbkEltijtrauzO7pTyT7VUqX6WGt5oCvJEXQTHyweakFZ5qjh6usWjygRVfZmpGbzVkm2wrSc+WFRnv
#TEjBt8fW0CmLDMZBI8YOIrgDPSg6f8zPj1O1hTDO49y2pLQM+F5lZFT/cB/9VK0xPqksJ1dXgydhE8Ikxe+Bs+YvD3YXryFbEcJj
#hMjEyA5XC22kqXVUbcR2nX+nwGLP5CuW639GOs8vKUTqvCyup9x+4KgnUNQc9cP1cz6UixbOdB6vN2M5gZ2XKQl5tLg5sMxYg80e
#J8BUfHxmSj7jw0ThC8OmTy733NFPRYiHeoxyHUuWTHoz2kh27q1u0U/4qMbaopRqV7nCebfkJzy5o75zMiV6ndD3nlXQEVid66CL
#MwTS6i24PRoWq2Kgu7mgucdwBMlHLu02lXTkxgkaWMKWyzNu6v28LBWyg8bPujAQcg6TjqKzFUe4hyPzYJz/qLSRZG0SryOkgr+x
#AIu5xzH2w4wrfLxcjQquUkYSReAOTdIET5hOwpTA+LZ4z7BfwXDaW1AjStOU4lzuV7xE01tGfphNfGjGBl8GR9tTW/C1NAai19xF
#9VopSDKjY61cYa3bIC4j9WCT6UIgZvNKsnhKWlCM/SLW2yv2rT5+9QykOSxPwKaykfAA42CChgGToYhC1Kmjccams8HO/POIqtLr
#D2p3tmKRiBU+p72cKYISNfR4ZNO7oz2ZaZ4DtwbS+SzUB2RjIVL1w/CsFbQyKCnrF5LevXm8Q8qs1TgGOyPYRSY9riVMby8kjHWH
#ZVxHZc7QbE08lJAYFAbBG5QUxcamXMe4U2z50Mgm9R74C+mpOvH2pwZwAXLAY7N7r/FQIu32eF4kshYIJh6gkQm/QUcuHF8dBPt4
#ERpOTX+WsY4gCFYW8DanTuv4kXJsdzbk+gywwPgKl5fKDxsS7oDR4Z4jwYL+ZgxhwkX/ernG8kYkSuqwRxe27GD7ckoGuwjhA94K
#r3lC5uqeAXxGPEl8QfwkgR+Yxthk049KXYjXXUWkboIWKvfnx+CAA14WLWqKfevwtcC1r/XCHyBC1rO/sK28qZt3695WTN3uER/Q
#AHw/ibWGGX33Be8okyfFLsMB36ECEIenZ8hq++j01fm5FlZYavvRyscFMsAMg34L9eQ5/8WlxtjxhLT7ozPcfm6JxS57nIN/wivU
#1JbnaB7xlWVlMb/oknl/IuUA0V7JwigSx056umFdQY2lvqFYuUPKN4Bv0q/Cu6hnVmeJq/4p1aDEEFgxjyJk06aYgQS87xwjA+uu
#nl3ZfsHSC12ACMAYwoUYAUhA6N94T5o4Di7fAyjIAZ5if0MNMBS1KcR8v3URXFo6KuWgSGaMx7PYmLtJtbijiyS+8/DUTyaKF5jc
#ldQcz1gCt55tWYsVNyvW1reVBGaVW/qzXOSm7NWVUwT/Euv24ncNAqqb31rgXdqz1WclgCHKxiXCny6DpbtwICXyp8gRj9bknM4U
#7lU9+HEU+Yoqc231Vz3/tlxVXa1+OI25hyMqF+trwHpgEhd0J8UY2tOJW7LARyAuIc+RNHYniX6t4KXdLbcClHR/DGFm0ssxzHoe
#9Fta2Yyx8jMnXuZ7giov/7JIKc3pP1MC1fyq9NWL9ycaCX0+o+NiwXZCuw/Ju/LPDugPZr+EiZWvLErIJBVlbcKFr0DO/oMxpYvn
#XL95woRtDcFMnraeuH2+6Z/DNhVk65yGtEdas7S4dwpjvcTCE0fMjbgvKSnLKVRbkflyPg1nwboWg8+OxYBZMf9L2OlTxBd/VzB3
#8ZwB+96nm5Cr9MjKl+ubCOsjA5IZcUK9nHbN8uoe25OQqeubGEUyxCzomjs3hUsfNHHocO3Cqo7V7QrfaYzGBW5dxfVtPAUwecWP
#+3XuoXbSpiyevFKaBzrABjCrtCZlrG0aM1NWTa+WfQbQQHXW4ORJL3GrJ3WrBofo84EA9jpf9eqtW0zUVVlDj1AP3tKwtFJTQhLd
#jMv8slw4h+8zmXG3bv2wK+47FePMNl1uYtSiB2Dize7V3tvTv520p0FcMqO25FB8l0bvgA54WXbt3WtQYOU2T9osWUnPXCaAEcyo
#cdym6RL2xMSnrfamrVAMjT39iW2dE0vtGxoKZoAxTDoLlFyumeHg2rpO/WTtBNQdVfBOfvyBlBDsQA/A+tGSDbAVIH2N3oM2f/kk
#u4q+q7GfTVG3r8B9br9dpKcINmmiVJzadX8/Pxt9s6EcQX9mgNGeOUYWdcHn8M+QT4mke3LHLWOMNIp484kz1Fg+9ykCOMolWaoT
#x12kDfdv4pd54Par2X8ihgtmikz0LkqYrWsPWMrwgCTM9ccHvdj5UioKsXsPIYLhRgw1Msxj8Lc9vIbQgSYgH7fgUAyaNitblGJe
#MvGg3J3nZQ2DSYUd0vRAe2EiJYkz0rCCG/TRRGzSWnJShVvQQqdzfp1sB0Bu0qN2W/2MlvKeup4ClJjvrEG4hTxuAAlw0vLVJkl6
#oSlVVAAQYR1HTXo+KoXObFVRlNRW1GUFONppd57MF66MHn6R9bD1rhDATalskhCn0Ma0oR3dHW1FkAMlAJbMyhfey0yg/zCC/Kv2
#ipfXz8CNb1Io4dt204adA06QWjeXIMH0IvO/X+enigEQaY2XnHAnIc9rVY57HFHgOIi5UIQlm1rMH3W3YEFD06PyqDmqFLjYA7IG
#a/0yo/AIvG7j6txLDJ5JM7q4ft7SKixvJUGyir9jQMwWcolJlJGmlkmVOvYBBdOecdenknZFGhlDCFAOgd6OJkor2h2ZnaWB8lc+
#8lPjZTU/FM/MuZR+INLiXP3JG6SSP7KzFRxkPhxa9bLaXfT8hw4XaakgvIII1yB0DGeVfNBoygQ9WLR4R/RHG76/K2C6AXYHHsTe
#oVeeelzHX+m+fQ2hLq1IsqMDscsYX95DjYVlfGiJv+9O3vvILI4ircZs0ssyBjHqlugfJYkFHM9kpEPtLUbxe8qeP2bTWSLomzsj
#2srdqtXIrkvTeb96Fat17xvJsWt9Gnqnl0L/OmKfRn2luzc0dqEir1G5Luqob+1ZUtObh4e4KjQBRqB7M5tOzXXUA0UIgA5w0NiD
#qXR8q6czDFSAJIQdkgpw48jWCw7gC35BTsrNHPwrA24f/s4yjdSHP56P1+4vs9WMWGTn1dmVh+aK6siAaL1wXxWFsDdmoYl8R0fv
#ArreLKKh5dWmWfWlTxT3ppLxD7BegMizALuuGFUdPfXCpxnvNP3JJmwpl3TWbjnkpsxBT1UknW6hrNy98zKPxRVkr1hIRbvCWrYs
#RSym8FlsRIPLZYjjn6Uq0aetjAMUMemSQ+z36rZw5kcV/huQTLBd/9nwNKbYT8s450UUACx5lKMmNa8kjuVJwWGnjGG3u59aUSRa
#JR1dmEOatqsu2ZfQpa3vFbeSX/0jORUwciMa6slvmGnk9DeRZyj+iLfRWXEEDzt/S53VWPHtWLp7CQleuN07XJ6UQ1ircTAevv+I
#vIbr/fg7W59l28gZNDyjdjTkfsNwZ8JDWxqK2PUsUh4n3z7O0LqSDgXdbLSoy6cCjTwV4qvl7cdW94ldRwSqunB7pf2aQXKOYa2c
#9Pn3qBn6Ggy3z66CmQqzCUF6SE3YxS2KTEjtZ171nJyo8brNawwLbcOn+OBn3qo2dEP0E+mx9MkMVnm7HD5KdOzglYMz5IsKWsg0
#pLy0ZMeYgkDSZ9DVhAlKBKrgUJdPHL/+49WMT/gWAjniuPfsbiO9HE3kOr7B372sDNiBJIDJnoflocnvg88/aWgJGdnuZN17NUIy
#I8+hOQcCRpVfHYqHlz1ERbPLsfLgwuzuSpjroM/HoqUnhGVtvSM41T+hb0mcz+uvoLIxE0N5TcK7Ot5rh6peR6RHeK6xkHPxRpI5
#69i99df9X7rYMSKaJtOgcTbFOEc1ChwHEdgKMGJE844DsG1jZ6de9qDAL+A2GCthYTwsu8Px8Mgf/YbjKG0XlTyKKIGfF7HmKGFQ
#60taQ+4QBgBC4lmSVL/MPJ+eyjtxqffGqWUEWio7KidDhE9CkCB+k6TqS8ntrGukypk/lbwzi8xFwH5ry9v6uqu7mhUpYK30btby
#scWF9VUqP6+dX6LcTdP2y4ppJYhZBCkU/6p/nJ6dbMfWmsLJBzg1YAG5sSaOd8LJ2d9+vgrgAWRBissMDLBQBlgq9KxVQG/ODYBk
#RpFDe1VFEsMK7wZequqomzCp095CbYd4YcNOEetuBRhay4PkUwifgwY/7Ew9RLbQ/nvsLGSIhO+hrBhhqKsPkPUoNJWwKOtXhaE0
#dz31jhiqwaOJAixNmw00oxR6b8TZvXfkcGMEUpm/Yb4QCzHvmYxhhI/IYZlCFh78UAsEwdQzfYzLPygCq9Hsd4IBs/xGHDSBHj8I
#WRGrsI+RRCF+DBujh17Nu78sUYTjjoAvx5/yuxDg3thC9CF0EMAdv9PYDug866gVdfKSc/2H5+iLE/B5aXggB1iSsOdjSU0SBVin
#QhVhCd0XxqkAcbnzdULJVvooMv57t/WID1jiMSotGL91HYVl/8T8zGdTc099TiQEtsvlACkvyuaRDC3RLwEPevLtNvC1hXQ9RZGB
#zM+EjRZ1T7X7eZHi+GJyLEY++th+ssipj878mt2J7nkhS7s1HprgAPQ+s4NK5lefRL9en3zpSsdumiz5PwS6MR0zIlqV0996By/W
#OY7x9fPJgAWoryRP+9OZirF/gQpx2PZGb4F7++ftZ9I6z3/qVn0Y6wUTdXn+oGVHgZNVaRLB8Ume8TJim1CCaeLavxFUQN7hF1Gs
#6BfXta/rCn9af3pZ706tUku5Wwxv4VKtbLuetVTviJFnig7uSEISI2UxrcD2Y9rdLJff0pYiH/8h5sESjq7Qc2FYRL8oSBnHCXGx
#Qg9RhHBaGMobV5KWqaRhVkWHPVXMNVqf/QDlC2NEaFYEnU2oVPGpjtoh/yu+jxY9Z6NVwqzP2crNDLBmKLgmc3yKNNe0uRF3XYC4
#29hinoqp5kdeY9dceNackJdakmMamGRk7ByPm+4DntlpBjU1HgfQkAe/5idCWs40CfejWVw9gAfBgkLaWXXEkBMhTJzE9U0n6cer
#TZgGC9snEeW/OUEMRagLYjAbkP2GBzix7dJuV7GgZvw75J1uvIQjVWrtC6jeSpxqJn49mivTcNQ2NkyaihfoCSJMlH5GMyBSy6fu
#36Ck1iNXv9Xwl6PYajeM5ep2fweT3NOwwlPRqReSvEED4JSn7Z8zE+SAKQR/qFudiEiaQo6YVdxWKGzfpIIdhUVTjjvu2qZFq2XJ
#7uoypirulNFkHjfQoUXqZl3PfelfGsXHycrNYjt/oHU8W9Zeg1pys+NsJVb38xm/lDG/0JDbE09lsw419C5j7S9pbuwpWb2oy+En
#2TQhfMlXPzr5uWW5l704fVX/67Qfruu52SNdl1zsls6eyInVQT/dkHw5i1/pWF3tlTBL8ix9NtjnKW26X36jdF6E7MkAucZjrswM
#QcfnPJTl7Yl0PPrGhrOtyMS9dab66eQc4w+6pW9WoVDlpsWcqc94jPDkodx/WPmL7RNoYEWR/1d+7Ao6WOofOcnubq+0ST/rShbC
#WAlv5y/2jcs1iL7h8Lm6rFB/2faPlCRsRMQpBAW6e6S4trBWl4xlC9bxLs2hooAy46IualwAE0KbyGa5Dyk6c7nLtKnPLItDmlc9
#zr5BrIacxeNe0RM+Uke1T903/RiGc/mYV/bQoYEz48BPKFH/PxtCilvkrpuFTpxIVeWkdiyEZppZs45JH0iVUbsso/2BuvF9/lCv
#06Ph1F4Szb7LM/bo9oV1cwPXkdSzurjlaeisJnHMqnhXz9iiUftGbbtC7avaLHbp5mJGo25RoyzDc9FOr/JowFzPLPdJu+z9N5D2
#DwrH86pc5lBc3h65BJ+bqY9Xu8v8q1rI/NbZ6QOb+TYIeRzmPE7Dd2ElxyRziJ+JViR1edJ2bWfRrw5d4oFm6Wbne1XCO6/F7wT7
#ul0rKZPZ/F26sTju0i2bfMYuffLGMZssy3RG3E+yP+tXWuuqvPKxvBJq3k8H+FAM4nnv0f9DmiEI4YA4roaFwvgqsFzmn5XaFbXP
#HjUlDUQqwhOTLlruYZ+g/1UgpYOkjD58IcZQt9ZRgcb3SGBm1I40dc4kwpnQhNST3WHEncz8BJanLoi2uLEqiZxaS+QlNcFM0IMr
#RKmMbwWZNO+Z3m6yH8gUgQnggknC2shAHW5kxk4av2lH1t352o7wpgYqACJXRM0oEy+P4unP32Mtx9tI2gmJLzsI8okl/rHJra2U
#tDUVllSKDgyDKoIf5OF0250XMsCwy1vGiNtyLL7qRJ53rWhW86dCtQXQz3hBZ3kQ1l5pgH/StDdr6X+e3mrSIfx4621lUFhvkZvG
#KcS0s4dYxtFvmM+oxK0Ukf8AI/wYExGIShH8IApxHsSuTEOqbm7hJ5u5zcueul/5iNN5HV3FrK5mdJNJOu2/IPL5b58idH4nMjN3
#ShZtj5+xyhA4tU92xncsRXyazgHCvzLaftiyQ73bHTrFR3zQuEmvgcKdRcqFKQ5Fbz9I99Xd+fKRUMz+Yv8Syj1eW9EqjbYLg07B
#iy590q0ps1mFYCGWoitHa/SObJ58ij3+EPmVhy8m++Jz0oQvjBgJPkHIeZRRPuXfQ5Lm7ahvUErsJaW3k+gyKBvuagtI+8OR9brg
#KfaGC5UW31hHyJlR2sVrJ9DzDTo0M7yfroY7pb9JW8YezzPxZp77bOsFbfeqCoXSaeBNqGM8K/Ut1mXp7u8qKOxtKad5cT3+9rgt
#F+tG9VPbGfI/qB+9xT6u+uYA9h4z9utXP3tbD5JLyjC91Qb9ZFI2LKRKGEeEXu4O7dhIg0ZoLTxwFP+9iDkXQWAHKEAdDnzfYs3Q
#dQmG5IcCCAFf6isebsH/uAxoglqkYUJq/0V4cDsSxQQkCz6xCWATO2+LNw1BrQ2StogOJBXpbfThaAuB76iO1WDyjHKLm1jIdeLJ
#YRoxUEpNaES7beCW16+WQ2nzaTVMeInjsh2AuhCrq5V8Gdzh7Ho33SslD3///GGoIF6HNytu28p8ZhB6xPUovBlW+5D/iy7vT262
#9SFuGYg93m7Wz2e8+OpqS45ZcXyiXH1KjtQ4ikytiqx5XIkhKPGV2jxCk2Xo5LcW6jQ1f5s8rSqXQEC4AgVm1lPHQe4ZdBzlbrNq
#FmvAoAt4WGJrBw6YB7xIYfXRvNPdafCG6YXFzTF6QEvIlDlxMBienfg2HS0eWaugmJVgTiq8ZJRA505EmliHuifFNCz5CnBLkg9J
#a0Uezl6UOWIg8XMxCm2g2t5MQ2Tue3X+SWbacbrqGmyPcMLLJNgiC8U5Y0h+OA7b47XJ2V1hPPALU9zphh6e2IQFEIoPYeUj62J7
#5J+xE3OU1w6YrRsLXZuc+EY5SidUBLDuuMFYQ3gLiwjheJ4GSS5BIJvXVHoo8vfzPRUTpq8AvHq7YWGBWLEGOlTl7xZTAyFyJtcC
#OvhS5FNGwfl5bHVa7+7/bhJUQpEE7vJWn/U3sPx13+hDTxzn2vq7jOmVyUqa83Fxi1fGwiVQ2qRUSuFtPtqLgct/2z29TgMi7JMo
#gQZhQPRvlGjBQD/dv6ixgRNkFeB5O3CMQK8gVnheIoD5pbsrsyHbfcqjl42X+WSZEqmosasBzNdAEBDmFVKm0iLmKT64flzmY6wq
#uazQjtKCM+vuFs4cTBld68p2wLCgj1dz+acSCoAjQOcKUEC+G2Khqu4uqugNQz+QET0MMnaSzXzKqaZKCaBeRsE2HfHss8UX4Psg
#EWyUylp+8w8DW9n8WCte8GJo+hWtDeAgaOHzDixgUza3l3WvCmFa3BgGnHDsBNdPpUSmee6LA7mWmkWyaREh58G5nTf2YRAci4ZT
#FLAhZGR9pvGSFSDGdUAjoyosnIHtM/g7f9LErBdJOixRGjfxSM9LPicv3rVOkJZnCn8RPv5hXOuA8dHRY8dbJS2zwQltSGw3ppCZ
#Y3NVNCk3l4TPljTyGHZLCtC7u9uxsGAyZj2+ScmDCK/f5xEF8W9NbFAzXK7pnQfJNKWAb3RLxPhI0EeES03Lax1/MPhFbX3oUa0s
#fdOLziRnGbma1MkDRs2s18GPBZuvigXYIGThasG/52Gl7p6zM5xzOGt1udTfawUqz3cPEzWe+9fs9IJ8OfZTvsSqUKrRJy2mAGJz
#SpOF7JDABJaSQgBbySREGK33rzoOwnnSYcwQ/ccI6X1zrHuqmq9cgUGlLukRFy9zJpk23ZNHqXOHNrnrdFMpXpuM3P19dLmvOCTM
#z+LMT5woNYoUqV6lLD3M7qu7FK9Th2rCJdNkYsFigCD1CjeLr9fcJ2kWklkNlNgYlWZ3JSzsroDiAVySKQYzK/tReesaLc8xM+XK
#vuoPG/kgJEpPULpTLF+ICcTJ18HQzWlhbdcaCqUOSrXebK1MBnI7rMtWT5XSnhEyoCMyeLF1kxezbUODpKOMjRj5FRaHR2u14ldq
#U/benNlCIylh1D8zf2ljFZVOUMm+nO9EE3JgwDhmwzOJxtFdxWVUqrdvDF20ZC/9Mg3suppoMe0qyEd+VpGQfO1ZXW3tSJ1DOCu0
#+GyIC4bbcLHzJTV2e2TStbbkYiWU5omCEl2XdJPszwewjPM5Ukav5MbDEmiI8D911BmQArwAXYgaRD5IQcYmU3vcUtu65m0Ua72K
#OhHoi8pOCeU7UaJFOwdwf+dD1H3hKkYb7faBk7x6OKtnVJBQKJuKfjQIcvWswCVZoUWyiJ5OG8X+d70ov/ev8wtdpQI7SHZV0ZXd
#PXQm0m8Aj2bX5SXMUxa7fXaqZ0Ofn7+39k9fs7O6+Pjgp4W2N62669QtddFiqqnp4mnUqFHCqclp8WQ2c1Y3q7lKqVZSsCBFSMIc
#b07ON4g7/luk+xVDeuIWTBpz2dXRXs3iVVWMma5t7JzN5+zSelbsJ1VWJso/vs6d/Gzat08TTqiSb8O5udSPH6dQ6y84JO3wpQyO
#8ARYg5ZKgA1CmRAH+hCzX1s/THgT4AQQ/Tymf0cpJcCR1YUAQ2+HaXQgAu/2Rj0IAQvjVmaDw9/BH7llYy2M/Mimn66oGVmv4CFI
#sk/PGDi5EAc3L7UfLCnFEKenlFBCUTs9CUKKCpaF88VzycrNKJvNzafVTajNTbPa5Ci/6SYhplFCX0T5FDKcasjwGRFg5tU92rGY
#jmqIK3+2FJMmJrUBrhKDxHvBq/yU36cVDY45EUg+uyRhwtB0z/JQyNn5sl+bpKYejGCFxp9AvjpkhyOxbXspzG7FG1vUpBRhijgX
#z4yuQoHDFHCvGA8YdhD/GixkhuZezkEVAqiA/cp0Xzp2T5WqdVdEq8rkyJWVJPyguE9/LmZ8UbX/HKn3xo6t3dRk/Zt23x9HWdZA
#XMr9IqEP0mPhLwAQ/L3pR9+toVUEPcCT3JtZihicxqs2kb+OjqWQNOLmqcvZZeFFzKNPlEl4zIko6RjotKhs/AJzs8akpFNfJCUX
#nevFbO2Rg3XTSHz1pY0RNmWQFjf/OW4K06t1KiqfcHKe05HAk4hKgAhMgIwusE6QTG9Fh+HZCeDd2YkoqqxjFwyfLy36RprOxuaN
#IueNAueJMivvRRD+CdBjZe0E8MT0o4gm+ka6IJIlUOvNwP478nLs9YCYKy0OT1qL0e5Nk/ei/U/TnYyauZFx6VvFcm8JWogewoTl
#WhyNFVR5K2N0oAtO1tjINnjggTKH13aupC+J292XOGB8KULAdiF6xgZ+OOmEcF57+VUIvio/KZdUzeNYUHfMqz+C0mddjIislIDK
#clTwbeDTwJcZtvbzhlfpQOFa9EsNRZhgB+pj/2cbjZ96CpXQyqRmxFozlOXnqpU8plUT56qxXS+PfYLMvvVR/rO8uYz4dzBkA8bm
#MkBaoLm6bMDtLntOrS0v3/caMfQG+7D1Z6lI+HAs5vN4/FeqLa5yjve4zin+ecrHwfS+dF5bgCPqbvjv6C2sw4x2FKk79pClUyKe
#Vf2wMXZVvGtsB0oazQiv3QZpqHrnzWWNwDZ1DldbirvhxA4bt3NPbHib2J3yzyq5/7Xp+dWDg3+bdhcb8xcZcG13DDDiux07M37x
#PH2AiiCXLV2uNe/NfQgIVFfvp7wPQGwN+AShkU8AbcCeZtpjIN5bSL0ci1VwSUYfN7Rhy6vvHEiz+UcBgujakAblDLArdvR1XbTi
#CWtnKyQ3eeez8z8L6AXbkT/o1fgL/pKjf/rQs+N4vOtRKvevk1sa1/Nad56dCAFq3bL2nZPc64hDCZ6wYijbEXH7huU/y5IlgL5F
#/arfo87oaU5jH5E11imOstfu1dPTQnZp7ib4COHFEFTVXQQmqGdkySbUPxQ/l8fOaXR5IbpcV81lvY5ccGeDVJE7jwNV3p1cAI2p
#FPBlEJPqB3tq2yZ7xYF7DHqgapx7c4NcP54e77RUa605zJh7fpXdNmBdkhM9wtEsLiV3ckoR8yoPAsKx5WkT7LhlJvI0H9HRLVZD
#rKTHpNvn/yU6i0WUXQY7IiNvVltffHdD5oeojXmw6z73f0J0dtqMDdHCEei8UCJKcC6lTArYpk5iGuOa9GSXHdHx+Gbv3bAdqfqx
#r+C9zngVqu+XL0+d0SVyeOAQxN0T2tJTqZ3AORsCwHxT4/u6OHfVfeT4nb7fo/Pvzup/y0O7dRMCgEOgWiVTQFA3AlbEnvT0BmTG
#473l2uXVq4XfJCy7anmVLr+YmlpvWrIFhfvsGY4BfBxWIgUiDsDuddVxOyPn98mps+orpAVNiOY7Jm8DImEFEBercW9VztVpA5FE
#MPcng3tg34iEzOM4k8IGYBz+o1s8oaxY8AfJwKKk5SLyif3C7eaJMcuU/88qSmjB7DEAdfsqCRxaPlgZafv7vMp+cTQSF/lufMU2
#+yJk4OFImaOQ7tjEZtvQJzdHUANWaSJ91vDLjfPMT2GzQQNI2aAKmJEPFODPzQxnKr6K/UkRJ+zapE1pnECVGFFl9xueaZ6lypDz
#+HzgihGMyA7Q++//mkvRJCzX42cZpac3Ttd9HUfEQP3ksaPNZfbII5dZqG9NU5fYFneHfuhALAr5bH3H3jP5BhQPdNo2CWo17TZW
#J5EX5i3UINWI7XmWrpA4KJTJoNSW4gDxUQg5Qijxs4A5SuthGiRxW9DNg+aVxt5i1aa8oiFCON6oG9tgIz+nm2vQpPFk8pwXm2Mp
#Sd+/E7/XGjaikakyGlGhburYi4GuJFq/dF0KQvzRWS7cxtfwCPV/NWW8dLLviGbASNgmUBRD+xeR7hu2bXjdkATfzfR8L2vzNa5v
#I6NdIDPDyv41SpaO9FrHTYdy8szlIiMSwKtpvpilZLKHa4avbQFhwnDEHlB11herSd4IkoaLmVBhxfnUNLoWF6ccFfKFUG5pJBcF
#V27vPL+ioBoeMLpbfUQ1YWIRbZSwctnE3Jkla8IuiG017IdCnaYC5fxAa6oaPjDsgwARBMJmgWW1xqFqreAaBthlgbomb1MoYYU4
#DgDg6dtjaWRDbz8DcXU1Gd02DGc2VkgPcQo5Q4tgSIwCOK9Nk8yu/bIwg947DO+cwA8D76wmoOGS3JCyUbjZei1JD5zpPBQDh5Lx
#IxdAH2d4/gpao7k1w0EDJ+kXdNM1YD8Iro46UJDPjACmWMW2pIhtXLoMFfRvASCPeHZMVvHV30S9nr7QMWt/OZBX9MqUUy+J7fiD
#UkM9l7EZVyUVWCjYE5aUEFwKZwrNQajHXx5r1aztBOtF1gxKxVI0sbCsxyQ0LYklXdB5EwOVYwH29dejZbMtApbeVszzlem2opiJ
#ISKYKnZlEIgcfLBMZPU1kGkhfwBUIO2UDQ/4g3spX9UjSlQvLAL3SQLEtlHBpuvORUnUegm+vpU2qgYz6ZC+AX3q9cmHcOLz50kf
#HNvz/549vZ+pfhx+A0LvRALzR/huvZKKJs13hdtUQxSmIWUpLbd8k67vYpkFM/9AmrYmImVRVE8TmutpHL+SSUDvg7NRoESOhRda
#DrRx8AqzMc3xY84N2AEHgJ75sUTHXNd/0ek7Hw4KlA6BEYQQmwnhcWWMx5HUEd5XnC43b1+P0mTFVosxHUJozoOGnaSDjmwCAaHq
#0wF4xbVUF7PHS0Ymbu/s3CBt1Q/IEe4p9m4XHI7o/gHOi8621PBPl8PT45kpt4Of96AA3cjn5TngDSSZ1iOhsL36Dsj//GMBCz0f
#ZxSqVekgWaKUgF2QVkw2nPuwABrYxfZYn6FMGmJmqo95RW6JcAJ9xuEWLKO1+ei6iKu0IpeTmo6/qal+zLKDOHWXRLV81lizJ6jx
#LFfE8JCuOiUVBgpQOYB+w+xm4PzLhhwITTZDETLr/2TS52+sA5hGkAvUhr56PpUtvH8chFQexUWYTzEuxuXt8s6ZJ6ED3m087Dtp
#QGIoVpPg6VHbu4J1kIFcBu/bPXW6w8y1D7rHCnqAAJA/rb8VERI9L5C4CptDXQTEkrA5IeaehxU4XkquO/n7nPTqxVd/wwkavk5/
#/IzMJGOg1HqZJEKCgOrZBE4pRpIsT11SonM2hAoA8kwA83T1G05/CSdsmOtEU6bYOvai4n2uU/vWrnLRpvyh88Ufl8inRAzzsZBi
#k/M9xnOaFuTc11KZBJWmqUoFY0LQFuQUpZT+WKe2EaAUmH9x8d44qx4lCQp3vBmnzS92+Mlhz1oG5F0B9oaAtTJh8s9AJT2pZv+Q
#ksillFn8pLH/uhr1u+58nLpZTWjZUyS0RZwoSf/sOcpGSkVSoK8hLTwDK0d2+HTw+rv6+NklG++EibWgGftg394RnQKRGQW9r7tB
#qyv6neW+16iNCoqiKHJ3R6GvEHCZ9zwJpKZ3Fruha00ezl6059U2F89Z+DoXX4Bj0HmJpIdEURN59xkTxjDzw0BoQmE6r3orqVkF
#QmVxk0kRA+QwoWxgp0MK8HXTCiFVqvZL3+VkyorcjKwBld57zd4p40ngHEfL6XEwC2OVbX7JMrL0qcpN0yfhgYMF9ChIjreO7V+2
#Y5qXcS4/01qwcpZe3c/d6VyjSdszTQRDN6gdncy/MHewinyhyIJ6rD8Vy3jkE5/rg7jbusvrzhVxXFrHlr6hlbPS03he9+tHHuXY
#KTVRYtHJjy6zCu5tFbL2mkyEJ6SOaBvSElovjFSM8NEiPEi3q0UffQvrzODMuWrZniMwsaPxCvBK0mo//XakLT09iOtOgpbOywso
#5+f9OWzv9/p+v/s3fPn72iCr/rxp+Cezv4DCCAOB3Vm+HRLtxMm3r1yYsmOlNLeZxTIWtk2VcEFmMP6lx0O9WdVpbnI9Y+zUVVTe
#1J9khZ3Lp9rZLfgPXfKtcJd0OMWM1dmRFOmiixcvR5zTVx6JIZH32O66o7PQeKfUVlucQF9WvHbtk/B5b10uFi+njvtI96qpfthm
#fxb9yoLQWbo4Zf0I0LGc7eFldnu9/Hh3tk5C3fFig1dZ+TVUhW1dZmHGav8IR3Rg144xqEc6Xe2yQ8qaocNYCIP2wX/sNxrQQvD5
#lAbOW2++lfZRzw672eOvkf8JBN9IEn3CBlgkgNF4s/kjBoBIZnaHgBL/p9ckn6I1zVeqkrh1xb1d6MCsf3KIRWfeHOIAHHPV17G7
#4AYMwHwBpUGky3GI2Af/DYP48PHOreRaIEWs+oMECAxL21Jm3GsYbAJ9y1g7OKTWe3/O3Fc2lZ18CWMsd0OablTylHblQQYBj1up
#KaJX2aPAlod4HXc/c8eCZ8Q/R36ZKRtWsUeky8SFexfipOQ1hlkYEWrEfFlfzA+vyGhTROhc8qgWhBxdEPxSLczMZ33w+QYFh9n+
#yleO6Q3lLf9CzHnQD5tpplm2hCXwcEF6OYXm+/Ntbrthh/AU94zNdQxx0ngrVCO3vCQFW5RwVoifMm9vh0xFMoCA0dmLgKFHQ9kj
#uCHhJeuHS72t00DxgQD6h4U5ra6X7bm+72NCmzXUM/HJr11zpua3bAt82aEHcItKJhMYOaZSbek7KnThaIh75GsyiQFNT+T5w7Bb
#K3qd3usNE/7JXslHsfd9FBMsfhR+6HHmKNrnGSR2r68jTj+kyy03JhNh/BChhe6G+KCCj40dPIClrjJ2RTbgBtQcYK3BAVWNMr/C
#hBobgCQCz4KtUAheyU/8keZSnNDW42fJ4z64M83khwa66ZxlGxFPWzuyVb8c2tonJng72tgwnC3ciOF2624NY9RI1MPY9YP5AYhe
#d5uztdVPSYdUwaOJM7/UF3QoAUZL1tSVODu+rU6+kIKN1xfT6koGxXq6vTFVr5+nyZYxP67uiP0cXJnJySMP3AjJXy/AyqED6CjL
#jAzFm6a1TyfTFmM7WeYD6qee7vecdqCt2Zf+/TriXOBHp6kmsf9Y+v2+N40yAmOnQKXUlwd8TFKo5uYXp6M9bbWF3Mae6xBBjdDH
#G0TpIGSmRagpbPJVoD87AYI3/gOZCWq9XWv43urJqYfvVqk8mSwgh734Bc3swOpAjOpLC/bf95VJYGHbW+Cwt3VnYjnnDDxAx10A
#N2RD8IuZUAecerMknAn+bFLX19U0l2ey5TLDSDUvEBfTY0xi47oES2gQrMlFNSDVyIuwHsYZ8fHy6py1vUi5jNAZ9ft9vto07c92
#1hDg1MicyeHsVjtKXbFa4755bsMDzl55/sa3azhR1xZuXFOGDpMVFhhgLNtEFWt7aUvC5D77Jv8tzCHPL97X8r3/8/Q4vL0eb87G
#rZ+2F3mWYr1Lyhm1fQgZOkmJTGxubYiR5VAfA56vO3/VHRGAIZlzhABO7kZIJ5WFi6N0YjSomftl7p+3M2QKI7Abyz/aGpO6f4I3
#iJ1MN9msh5BPt8Zdp/AEdiG+jiT3eCuhil6VrFddV2ZdWlYn08U2na0C2srvLE7ulD8ZfWr9ncotj1BoIONf9CZ2pD8CjUOsmcFQ
#EudV9kEbfsOddOF4mtHV9tFWGpOJ2usegW9C9cJDREp2C5yDwYK5wYOYC9uRFHE7rE3cJXa/dQ4VjS43aNH0EQK324mfCrXF/Odd
#7Xy4hwlj9AuzIZe0GIXDpXkeR0NBcce0d6hgEHV2I92D5jMrHFQFQ8kiNK3q9Bgmy6uoa1IqTL8e7HUyXj++jTHvJ7XT1ESbk2uw
#9+4cBB7NAewEAcPtIeaj2m59/Z6/NPKtcQZJ+R92qI6mvdDAj8xBhCJ1hDtGV1NaviwnDe7+7ht0ZS7qDZ/G9+UlzFdym85YsS9T
#IHscxXk7SOROfPt7loukbW1GRs4A8e8Pu9np81NfS9A+9Y7TGm6PheCJrlr0mlDZwLUKDKMupP+o7BPObrU8LbPrz5Y5XMSD8xYt
#6Tpov89M2ajiRKjCIZy+G/rfpGcY022ZmIcSeWR9/Tq6H6XuM3Qf5et11hNBQcIJ/PcLdPoRbFRoMyGw2GIa4MrADjwdmuj65ln1
#HegumPc7sU+4xsOqF2dmkovQDUnZnO8Xfqy89ext4Jt/1FhYrpl5wMixxfutg+VdA8ksa9egz/f55clrvdkESX5BOAzz6bwXumEh
#Sx37/0xOwo27SPJQ4HjwcRweWgkHkJHx8A6GChlLBwS2OYdf2ZRkyWS1ToEyFpr72wP+of9WmIntX/VFKOZLGeJt9RnvCCo+8Cca
#ST0dmRxfEftTjip15spoRcTJDEaGKCl/BA6S4mwRmJnEqdV7sKhvSTlO9JQT+pRznjA67cF2ZyPfvEkabQ/89vA3bpuk26xLc7cR
#c/U1yeDa7vjqE6OTbERykQi/FW8h/0Y5PRDmj6B8Mv/tptHRpePdal7jUwTusScLVtRxrZKQJ+IgK81Zikp1JirvYd9wmx+omrre
#nSglro+5zZYf4/qoXo4A7DboaPTv4Tl8nJ/i+/9R8w3+0kAVE0AJUZr285+efjQ8iOVm0SDPNePfqgKE+zyOEP+pun40wPmy/tBW
#ddTX58mJOn56fCqkjDpixVhPtPCzQLSIDL27Gx20hknJURxNxE2fwEy4W+Atup2TclkauuEikVx+UB9Q4pMw8RwDEIzE+/sTdsQ9
#ZK01jKylFNL7eWeH/NPvAdDT0ePx9Qhff9TqyiIFLNVcNv+xL94nUJJUNJOSI0WWduA5dCl9aFHbM2rVKQ9KbOu6Y6tj7j76mo4r
#ApgLfr7xcN8wvf4geUlNNHqTkSZV/bedWct/On18nrMWzNLDakXK3354c6H2PQ5SKMIJc9JPpDwG4JfKOIx18Ng3ujS2r8tNsQON
#PffG/n41+uHSS71EkmNtnTcWx84cbz+WZasokyUs8cndJWD0jxPcREatIVrwkG89eaK1Fq9rgZnelq1A1Mzcqc1pahEntNGdt1Jj
#aiCVlh0yy64t+bFyWylmBaUMCj0jYvAlCuiy4CLKNQq+iKzF6ghJR38R0xgEgfVnZis176o6DCH5FCC8/IHff8f2t6FXLd1eoRWr
#OfidETF/B44CH4lO5vmXWNPbPX5rLzMG6TEJGOGHGwi1j8J31zeaOgVLD4/8aMgVnVg73yZj3NYixZduwlUI/hDICUj3MOiznNSV
#76EU3RreDTRQxy3Y5Nv/BuTrhivZC+z98vaHfzf8N87T4/GkkdC6AQAZhGBAILwvHDR5XbhVfuppc+Sb4gdudYoFFh97t5Sao42k
#HJq6NwTQorGvLHvc22o8HsC+Af6BGzTRnyR/gHzfBX6qn2F0PZdwkhbxFBz/Uo3g5BWB8x2gg15S8E/x4XtSeVIrl/TkN9XrEcEr
#4wt3YXzIO77WXffGr+DZ2+8uSKS82V5vy/aObzAjv3K+97Tv7FlHff8SiCP4a4keDXIez6ePHF6D3f6xk2b1/uYNdf8IZf5eu47P
#/b7xa/DL/wU9ry8lJ10Z/fhesvHHk2Q35sdor8/OjV/cPd4nkE7ZPeyp2c6QD3W5VPZHblB58uW9Gv6UdU4vJSOOCd33j9HE4LKu
#Yw95k5/JW97o/nrJ8tPO+RVLmt9RuAsRXZLALElMKTLX4/eZhA8zGFcl8jKZuZw4XloXTJniAXlKAay1p4Blelh2dbdu3Ff+H0dX
#z+EmoLcmFdBBPzfPJMj3XLlGm5mrpg7W2tnSPo5kbSFvl7LUzSUBqKbGxgYXvQZ69fZ2Du7mljOL+mgejCTJCY/R6uhHZjOzVkL1
#WI83WC1nS/S4OO2eXv7l+8oPyatLklzlAVbqv+iVPTPbNnzj6z6KB19HMQry/bcJVB6eumtU50shLvq7RwmroDOpCeyyS7IJSBa3
#BkMLd3z5QNL9QD5wF62OMXyy6XdYx46HieccAxbwSAwY1cUGfeXbHtIllTtOjuZp7IhGnOgGSlbwjltfJCxYmdXigwFwB/mbQtCJ
#6zEgoaMVIKnCSGTLS6AwwWOgPJFIssGBhsFCrJShRU6J2MAsK+yeoF0C69m1RTf7AwUy+UYa1WmtSzYZd9ctlsm9Qt1bg6GC2lak
#lBHRZMKyXm3LA6vi7zetzg1Spye4lbIqlITSceo+SpAawNa6I09qLcvY8uaxf2sU1uCxHLhWHLK7tTs5OkkaqmwV3oGxGp1RcLNh
#VmjUTLCTVjy+3OCNUXy7lgo7dgskNGEVaaswNbWws0HBWRq9id5GCK3Z1/JOX1vNPBKAgo0fg+5Vt4rG9R9EIlWop50Wrn3uQ5KM
#RqOR7lOW5jmpBhpjV/WZ/Oc9YOi0DfN+uj1pFdTxJHrpOmsXUSaUSqWek+Tgos2vXxrXp1PLhPvQoEHkh9PYBdlColG6rBsKw0WD
#CKSAFKpouFOqGHQGIYpi2JbBjHAXd7GlGfXGYW899jWPZBjl4Xlel7ep8P8eO+mNCKJxnhQBrGtKS55Et8dsnJSZ+T/QQqWMBxqK
#rboM3bx/All7msTjuF8r8EMUc2TKMB4a9X8O5WmUzNC6F9ggmxfVyxCPFSXISZbU/f0wTU45LxJouDkPG4i5zLYumv2vmGEEbxQz
#b5Btcso0ssJGtPm7FL7NQzVMmqkyLR2HHmXZV2mYZ9kodV8+PdMIxzKM4kjXNozk/XAcw5jGcddnUm/Dtuv6KXk4kQi72i+xbW6p
#6WGZy/WXa9euZAruiwYVew52Eprqu5sx3XK2Fzd2x/u8H+ecvYn2d438oAN2xbgxgtdbxK3F7HFR7OrbK9GU3e3xanp9wm5yLP/z
#wvgHKk7fDoXz3AqcTi9JLVnDVpVidTjjTUQMkqkMUmwpJnkqASW1Jj55JqDEUFRFAXIrqMCgoLQQEwQkyAwmBQYFlbWY7K1y24ZS
#qyXoLlTNdhmuP3Nq6j77W05gZjwWR5s9qhbcvl8UjbtqBVMdiY2xFSsb5mvoBhm+k1d34VcmZ9u3I+IDweTJsLYvxNL+iw+OEllK
#qxccjXF7Z03t9OKoGxzcuxbuyMTbauug8szwugeN1BewQ1XLFV10XT1f8MqwhskVzQDvAfWIiYCIq3jAV1FJaDCaCkN5wHzpUCNI
#eGZ2EQg0XdLdWo73wPOl9F1KmR4hDQNVmP0EtIYgxIqx5gtWKChnPnoxlVTFvDJVZWiBfCJOdyDBAcipWp6bOqo5fxSN4PIA35o2
#H9Aqq6xMnJFbCOZEkyoXr64jgI+HVMMd/WN7xNEbG+jR+79O5Ps/mf8H/7OxhaG1kyGtg6mLscX/F+3z/5n/sf+ZiZmFmeX/5n9m
#ZGb83/7n/yX5v/zP5DgAcP/VG3AAAJAN/b/6nz2wu01wQjz+S/9MgwgBtScyhgUd7PPftc/hLv+lfSYDD4fExlNEXZ7NJdjgAPh+
#kA2hCIoFRljSiSvyajZ4/QsHsZtQsDbwFyojkRPMljXehBaRlJKqoSC1lPlJK27R+ViDsZvefxzAtMl/y1usvTB2qNykLj9sBMUT
#iDG0i+EZubUMTMcpbJR3iixq/Yyv2fMMOAG4QA4wEq9Q8D0MQIWahNKgUGtZF2cxb/ZOn5YEkUxAiYMeZBFMPlBCHaHCs8iNgqqM
#APat7ACt1fTLc1/m72rWwdymKpxlsgCoVewDHB0EBtbGvHfEp4soABmvYW3lR2Iuq8ywbcssYwwO14RmAifTnZ4h9HkBr2m3f3M+
#Bg0sl2RF1hCQBWHEucjM3VvvRGUTZ3DlaDBGYbWUCW1E7pKSBf6DkGYsXsoGGuuJ/BCU6aY9A2Oc52951lUnTXu34UsF3G7nW13f
#BK5ggKYYKSKl5GyHiQMEeLMTzBP5hplygbE93erddfFbK7wiNg49SLl5/NX9/av/qZ714zY/lX8HUZBdyRYQ7PC/viIyic2Zy4Vn
#/5INJFcu0s4jqpSfbq/D0sAwiWSqGiuZOv1TWUU1j6D7Weqyxk9baVyh1eYh43ZwHzg8Pq4RYkQDRa864R1SMhJKbeKm/BwsbaHF
#6zUjWpbWHrPBTKP166Z9+7q50VrwPl6psT9JIJ71V+6H7b/Btryx7yecSAojIGKK0MAMitj423Xlxln+qf9iCJvS/ZMKkAVgJkCj
#gUGBiTG+iC6R+E0QwJxrPvFiF9UbPApeiR1/D6t3PlyaAEUnTMdtNBEqJvOonkdnAyqbbIVzvFIuAXjtBT0lFfAvyGEZZCAp0EYl
#E7Kvj0gY+YNnQTnLw9eGNCn8QNPB63AeTSN4JBUgjHzRi+FIJ6hAlVc5sjSv/BVSAEVgIVEFwwckoaCK2lY2RaiQ+35p7ocBDcs/
#D0eMKoWpt/q3SK6SsRsKjaMXk4Bw4aUKQ88H/BFz4lpp+GkXFK7nuXFxIrcE5+4N2/6XOavd3ka7PzSrfdxY53ZKnekYdmlAJTG2
#8S6taTSZ0Znh20qxgQGrrI8mtERC5oef3jdGurUE79saIJX/ome/QZo7OORH2Mrv1jTu7dPK67ARvsi7uxdXp6gdWjpNe3l/+WZr
#4WrLmu9oDsJXHiq6SiNScg5XBOyUGDcyf60gh4y1Thme3V/9YqzrZCLOKmTTAPT4EfD3r1m27zk0XuruqW19hO6C/7NKC757X9fO
#FbhsW/fS6DbVKup77ko1MvQnf+nK5pl0pnXeLWomwTrJBlMOqdhwBz6eYSYwQ8T/mRd/OYF9pPmcf6JWB/AjyULO+cACJF1eZ/aS
#9LEjL0Hf7lcJsgfkQN0vlUzAh8HziQ6gr1TtCtQElJNvy4bKLsDbU02vuofQXmJWinX1SWcHd0FqCY8PX5Wdc4r0PSiFbTam2JQq
#9q/ULLOjKPaYNW5nOS/TXShRNQvJwxfXuHdHqRB797UDkHFrQJ8/ziyV/D3/6mDut31dXB2Ya56HOfrhYE55JA6Rq+EJwFjl4FVu
#dZaLMEj3ggidwW7NlxLAFc7A3M3M3HWjEpjD983lwMtYjTQxCZdH9Jx5VUZb1V61V9fVpRqZBz/hL+53KorYGIllacIjUwCZObWT
#qrdmSlXG/JXk61OoRLxtcEEY2jXZcxFwWKHiTuiApExZzknU8IvbpGlHqB2fHFMU4nAceD4yVyURdZCVxc2UdBiT2PyD/JtX4rxL
#9ZZAb994zgD1pHAltCE2MtvjifkmD4/znP5naH/iICcY5J/cb9gpwJYRoc4lX0ZROBnBykma8OFvVYZJtQbyY6WDln08/jy0swsk
#8lwSDzAFnIfmYE4DtplEAkkVYKyurBPIMha5TVlPuqECbPiL8OKbLSVr4MQqw7ZZe+8r90UDcRzXWUiyXGUwpAROWMpMYLECp59U
#WjmA06AKXUpSizIRV6KNiKIUS2upf4cRmJhGDUoOC2ZJ0wlsAjzV4utdadeVWFk6HwpUirgCYNVCvNS/cijgiqUCylsYtpxeKakK
#KAviGKAYsCiwtgaQsSpAVGblRNuUtmymV6UpPykODtLLBuMEZZTq5QbuagaYa12qtjoUlSKlWh0Hov5IaNgZowqvYIOr8bRDgEWp
#Q1fgoFWURs8OQgubPacmwniBcZRAFWjy7Ntgo22n5yFX3N65BlcjRY5+lfGqHOy1AtVpnio8x05RxrzZp4HjYUjS39jpT1XJMMKT
#LimEdHJK1XsoDUNStUqZasHZzY+mzMG0XbT88ZHwlFfUYGp0Ur282a6ppMe1AeICg39ks1K+U4kTTiMyduD0ju3RBAOg6mkSdGdB
#8D5+KHhruZClItV37KY0l1J73yrV4JbOKuEamn4+lMJ1xUA1cDEal8fy3jl1g6hd/KqV6YA4XJ73pWh1yn+qhr/uYhwz7ZFIi2Fs
#KcthbC2kZdCjJBJvJRgSK1Le3JUJzsKlSlJFSVBVFSVRUlUXAuN7kZIkxFITi5JLbFJqMsCq2W6UX36E6zWSiUD/htiMSIlLQMSV
#RMk6kFp/8hblchb2Sru6ZNwPRwRLmqDo1X8dQvsmXiQTijJYMKcml8JiOkAoiyrEkHfn84gGP06LD3hz3gmtvXp6MdyXk1WKVQep
#nHc7tWKJrJKf2CIMGlbWXynqmCjqSx+Wz5qrTsXiuLfXdZENBQ+u6RofEzwdCCFQaMBS2vQoAWQhU/EpcNguxt1IeaajA94eJC7E
#i3ZRtbjy+IwnrZMXTzjGN6BNnWwTufHyiq3RslJuYmo4o5wmitGYjSJ+tgQAgkzFDh1usAyqtKha2repbpDqls/4wzk1cxsudmqg
#yRPRKNFHdN8ScAUtj92fbTcF112NaxGkCTymLVOHhh8Rs+qb67NNPI36wZfQSQMgAyyMyBym/KikrMjHx5sqTkfllczoVAqJasTv
#M7PPER4DF8/OyDMDF4yGYZ6PuPR1HcXuGnKTwFHJs5pVVMWOPlI5HAtVrAmiHzhIhUHxea2BOLu7WJQ6xdTSGFlp4/Hb3bsJe7OA
#I08gdKyg8oA4IdGEYaGFjzaSkwR/dn2IqiIiIiQTSnKIqCQVBRltJyIuc8TYeZWJLHvzjjEnAWNOAMScaMCdIYgxhhZxiuj9Aq6C
#ZSHsrJO8M2+slHeHXdBnHGKx3I3cwLtPOVEWFOn45SJvu478KpC2vSd/GMAPLwycIIjgtB+2bRBa3nXoi9XkxwI27/KljRs4YNxI
#klo+faI/gLPDG3JLnzm74jDLt0pCe74Aj7To37eVOplK4RGLc2R93bDb/hRsLiAFAfw9T+KkPV7wJQyioi2/25HYcCBWejyeKwn7
#vt+hS1BF6UWrXDadTqaS62v5/lMyz5RMXeAvLpPtGw28EMdGgEfGiLB2mtoKohhSyP5TJSPiciNj1d8CiNqLUEXUNZMYI1WU4PlH
#4pz8RohDAKeqKgKKMlIwGAC67pDyiUR8pMSTECBCQohJKSFulpk7JUj35CSb2ElnKxQv4k3+n3NFu+ixgSA4gx9G7DsHHyhgJUgY
#pRCDlFJ0U8mqmlncgasIExVBZGCCVRopGb2E9eLI1EkbCvgppFzFxDzkJc8Uit5zCKz/Psg/qlrqIQqElBhiUsKCVOoinRlkc0KA
#7mlq6Pvf3MmKanCSsKMMMP0tlSYmtMV65DnNLhUrARgsGA0HWyaDBgwYMGCBAgQIFWBLiZH/bWanb1W2bYv8kqeBkQQdrCrM8INJ
#lGJoIkbqmA2rGk7O4U3o4B3SCE/sqQgilKTMgsFA0JexYmDfTEbV1GrL9Azb9zQZhUmMPJw3irbXIPOxxHQy8eGm9fYEkYuKOgQv
#JmEVf1GFLd6l/2Bm7LRSUh/S/qxq6wylOdEJ72NW0QIOE0bW8Qa6V1FVO7HsIHOolPLj0ioEFcRPl4aspQhYk0LAoH3SS6jgA9Ti
#6ywDliFK5iADOomDAEAMgPEKMMKVesgwpWt/DRgnGEiUIEcECswqrApCTbZcPlh7vwnyKxJ/bPmmTWsojlr1mjD7zYZe7ech+WxA
#1gH8MsYqLtlLmuSurJrM4ApPLb1sOwtwLDgMPBhAABArUuaN0ul60rwrfU/gNL42wNfXNjCIDPPYvv/e6vN87KuPSGKEQI6Pskjg
#vqdnEQUC3dx0HBD4ug1iXBxp4230QIIVCCcJ+n1kP/wm7T4aNYZ9e6KngUZdqresKMlFlvTzTAFSrDC5y7f6YMnI86ICBtxmPnlC
#OuukUEAetF2+0VVcRgE4/jxwcoQ8RtVMRgaI6Y38fWFe/asPwQdfO59OgAylT0cDpF0vnmH7pbWNrrdMWJPasVVwcu7n1HZ+yInc
#KJx1rLhNqhagTt1YDgRipoN/sgwjLCgKfA1EoBACC4zgAAM2Yk1Fk4jqwK2VKu/QD4OTAcBL4m+nb4fwjQ3nX0RcBUu86Gz/9zMS
#YgX6DGiO8VAnnlnZAxYLpJxZywNZDg9pTJBXgx3h4/sfKcPnaoT5STMEgb8n0gTw4ABQOERKzWn+G3IHkIFBmcHiGOdAFI+Tbt6/
#wPgoiCQDiNlmIQXIngM6D0guQXoS6OHQ3MW7K9DFaAu3O6lq1AxJBCH73uFMvEyVdwQCLEH4ZvQckPTpZahF/aUX+oFQgC4whsaf
#+s/6h3LHHZAx/b8u0AD9fP/X22Pgea28SXzo+Z28PL8Q3qmLWl8nEIQBxAMr/nDQCWvN4dQz1TJmenNU8ftZs7/t0yDwPA7jel+3
#rqmbBqxu24ZFW/bdplVjEkhKTm04HE7HMWdih/JDSoUGhMIWlyKRZeYIxwW88B33HfhGJVMkhKSEpETl5SXCi0SZqEzNlKYqhUqp
#Vq6vXtcBXXNbxznSc93XOeZ9XvY5yDecxyH5+p3GBSJ9ntZddegY9yWq6do2WNmQISRjB5OUmw1lh9KlMGhsPB/Px7P5cVc/olBI
#9EGKCYFKs6jx8WQyXbRHjy/d6dKSJOBgFIYJZZJ919KpWUPlsjGbVqOUr21vtPyVSvchylY5IYV2LwAM4Cd6AyCZL8QMV3KGLcAV
#ZwCoCotycEKgIAOMJgOyzlZy68RBX9W9pw/oXOq9yND5OMg4o96zKw3XFP3pVG/JCwtSo/Eyi369Npds00yfU7/YhdjEB0RAJvSQ
#ZU7IzDiT6Cgk/CDEOU0bWqLtZJ8JH1JpRsDDCZGsbHjd1RZmDST2JWELCcXJzjm7ByFqIyvXHVIq6Njs5UhFJq/hIIBrpM+iHriL
#E8v3BqX04Wh4pVzVVPA+JuPWs8LKFRtVVGNsgULhewjvaO68uyYABuussF2WVU2VtMDwCWbYBgTyBSxkj9ToNctdzlHN7gBXOS6l
#PhCWGiLiuYcrVE+uX7kGfwaQymI+86qY47if+grFwD/YwkcPbHTQr8I4DREN1jpT1UMnYl1Q+p64AhcboWpsRQ1Xnj3ufKvosCJ5
#EznHsqk5AtIg1fPsouopfXKKPS5RGxu0oKAKdmCrx5ZhWTAiKaWWuuuCQroWk8TQwSsdlEyDotJF2hLNL1p3HfU1Du8ZNecgX7lT
#aF+WB+m0XG390frUfjr1wW/Zz28G49c4vLHO7snLURn2mUorKi+tVqVjksQTrmSYSHA8quF4aawcCoO9YK8f1+QoTjh626VPWgrX
#1sBk3VXNXkMUFdrVejkhx+UoaJrCOWyKdsGLm8g0FSvVUWfTb8xAVLUbyljPcu2rRn0GuRSol2IVpWOA/YMj13HLKGsRaMYuaCKe
#8blPeKV+ndQot+XVI5lji/GWTxHhqMfapfX0gYYXI2qJNAYiY5q/ioUU9kxdC8mg7LU7xLLsPlrppN5beuW78g9tXyRiIzHXRyqQ
#hHszRgO7SoODeNIPydGaAWaeMM/Im6bCJNGvdCBwzWsk6Cwws1jueTsfnkJAxjqw7i3GSAZ5PIh1iNB+0TQZZyFbNEtodxy9E0RN
#S/j0vgmdnNeuX7e6LuBzd9Ir+9XmhSArnl6WBSyLiP5Eal1fO6Z1Dafz2XcowSjeCQjvyjoaRWuP97xJFclrDVAy6pjBihnWOEBt
#BWPsNWc9PEsfy3BU7ibR3Ji8jBbqaOP4iDZH/HCz+OgDNmiwqTyXKwhyoFRN6XVNNipnufD6NYvsT0ozTsO9gT89GjpOe0n3UwP7
#3KVKR41s9EAnzLSCntsgbystDVe9yQpBwYV+QXjJ0CPmkBAtsyh6Dj9K1LQtzK5gGy4PqnjQVtDXoEexhOyJvOkzcJC+05cyA4WE
#i1mUyP7boKhLGXEmpadAIeHRMSyQcJ3IlitM016r1v+DnXeKGS5o2ywf27Zt27Zt23of27Zt27Zt27Yx35/uTCednj6Yg56TuSo7
#d6WSXZW9U0mlkpV1YDTBjjoA24fnrlMVVKeTE9M1SbkCnHjWF1y2nYqGL7KwdBwxy6D66nRaBXqIlpytWyQtZQJrr8N6ubovxUGd
#KaLLlnl0APfaWcZupPS0RtObSeTHAorr94p8U/ZqFcjCexmA7DPA4Qia1ajKEGlHhitqbNkgcThSIcswXE/jvPrlKTlSyYNDRLOe
#N9uVCr+GLLvmFHPpMW27fSgX5RzQpPg5VYx75o1B1D9MJ0lEY757CfZzEWQ0mltDwXK4tV5Mebb6oZNbLOtdyGxvGzq8zlnzq5EV
#Rw0mQs0o5kMx0+6FNbzWt/qG6q0VvUYVYzMLbvvU1k6Kh3xTs+kMY1yEyQPRtsRzHnDGiUN9tIob2yC56rEpYi+OoCE1Em9CF+d3
#ozN7jEJOd8YxQCnmcqjnsOOm31piyLTaX2QHG2sLYiXGS7NKobdSYhhuLt0+QQDWML9veafzgbZcYjEfQ9JRUXvQDTj27iHPgb2z
#rl6qfC5SSploXeGWTkhS9yB/y8MmbdvpnCgrbHxpb/3B7uSlVzwpJHPI95GwSDCTdRbMW5lDx+gDaSo3jz9FbBTvYBYmF3l5KUGM
#o0Z3SQ2mu57E8aNsPy9Aw2ywokeVEpT71T6qZrNLrihRFhzpJWwy+lYTJ7rgoF+02cVzGNQDL6yNSg7k2BKE1ak14p941hHkdCLk
#aDckvPl7xXEncOCR6vhk/xzFFfdRdcOf+LeitQe/1x33pf4HeV30B33E70N3Jj2REOhOJekhViNppQos1oI4PCEthJiSt6e6fZ1x
#B/eRgZe32v/3CL+fykdDK0tFh1ZkGatnn9W2xggbsQZOPqC+zhdAJubUHtzC1QFV6A11XqQsLYVtCiRm26h1Z+2kHNLtshtuyAAc
#ZTqCjQK2Wlpvqvi+YDZymifmLp/SWVPuXZxa5Versp0qygv1lIcDSg6GqDBK2mf2e63ZqfXARwA2m9El+BDpfixEAwodkJ7Z2f/O
#icbz1efaBZYx8VzZfrzoc71x5voPwhne2TIidCUD5jHp1WH86+dA8K9Ceu1uqyntbvNqq066ecVi9EvsUgc8gCs2pXenAUUA/4pw
#CinX4qCjOFXz64cmTPmHbbcdnclS+XyabvVIz8DNsE6D0NdGDe/0lXkzNfwmy0PjQu6k7GeB028cGxajBa2AXzIROfYUY9trB1Ew
#3vUGfrG/gRi98W+ubYCZxb0c/JTsX6q6WJqvaJEAQ7e7M8kN8EJQ2HkzzduE+7FW1LxPgkQiysHucSwAMNJF2c33TMsyJ0YCLwQj
#wiQZxjJwZQJWdPyYgQRA1EMoj4LvUDBAE9QCyp3PHQpJs9aGgfxJzuwjb07KWygTQAwRNKavNaYT+BB7niBd4bhb6J4YGOTP0Z2T
#s/r8LsHTHaf80/RswmyC2TvOz4ZhsXsvytz7oqAwQlF1xH2LFH7l8U15yi8cZCRXCJHCwfbyB+kvf3AuYTONeGmymz3ygdUrcCYB
#lhYegXlYUuzcctHZ4BpZLXUlf3RZ5SAfkuuZSU+aEm7y7SiMvfo2HOV48NjJ6TX58/TvBchOmru+p62Zcxt6IiSboPf8FfPDRG5N
#7lp1RrR5LfwvgO26m2oH8DsX7MJ5SYAJr3IdP+V+7Ch9papUSZNy4HgMlWLUWwm6XZnDkzUC1pK1fTb2B3EEFRlvGCZx3JQ1Ck7m
#YNLYiIYKlmNW1mP2iwDTwOIV8PNnkJjIz3nxhZIDEUU6neu/jhKDrfIEi8iWzZbDSKELrIlMOJzvPM3nT98MFzLBruatHmU6ruo1
#5pdPY6WIZb8yuaeet5J/tXrgF+j3dZBGtJJ0I1O8xTOj/QFR6ciH5A4FBRi/OOAPTTU5jvrcs+k8TQ5Nen1AhVmyt/6uD3bV1HoO
#pRZXST58olW3M71xwG6AfeHCn8wtakUVAwyArZAFpu4dZf5ToplQUioa6SrLFgQTrOWuvGeocNch9/16EV81XVkv9+1ZKRYH6UlZ
#OWNU3iZuxXa6F7hbJ3CQ17hte7C/8PFNTWvahM+5OdfyFz6fZQ27xMuyHMW9SpVLcmFHbsY2CuPH4gd7J5CE9iC5Qm/dryyJoStY
#F1kXnEVFUSOo2k567fh2EwLBUA7IOypO/U/GsQNe55xSK38lq4OFmBzD5Ur39EOvISVi2wlTthXv0KpGjbH1yeHaUqYepfAGWjW3
#wvwdqlooH5jKFW4W3PxWFZ2SC5nnUJvVvzIVigodRUyo4NgJpQnnXM24VSVVF7dIltjDV2lHqHbd1TZYvzo55gzVgKeYmX3je70Q
#uL6p8Ed5FyEvvqmf29+3vAkrV9i5iKLOP9XOL/cz28B7uAy4n+1/JRdZvC9eMrp18L1hb3M0En9qVDkR8u7tKztF5KvPCzsE2h4w
#7VHkU95FjWnStXM+Uq9Y++ExuzHvYjEqyrUr1cjqKpVJggRWdGoXWyU3GZgrWjUoRp1p+X5+EoaUfsVGjQL14v6i4eumzldL7kda
#GsiWCPUvSmanDbk3dz/gA9+rH2riVcCHMX7YMUnRTfPgnH1Jfin26M/HzVHObZYndCCO0JGQlK7pUmJYwUIIWhaLImnjdUIwSkUk
#l0Qt+U/dh97mzK6ZUpHpMj225Fs45giRgZFoqrxHAk3qFQp0AnzwmUB6pz6AiBJBiRVPyUsRJ9lpc7vsgST6xCiQD+c+H1XR8VA+
#N3x3vaTjnv4K+ELP7E5vfG9aNa0LsCeDjiGRT6jCzFCEmLrnR2/XSrzfvdDC/b/N8zvPCQNhvrQLPetP803rsBcSoRq3SbdRPLv0
#ELz2LJ2vfLyn3WpUPm/8h474DsI3crrVjcFJLZrAQncPE4hgmyquYHl7KaPiaf/AdccSB7QTCwvE0y2Zh6yarIY4WYhjauUkj/BP
#n2h9fEosvdG7x2pP8EJ+gzQ3aArIHE749jZpgQnFBpXlo+li1UT0vZIJHs1q5c/Ynz7k6nHgOhmpBXcpBRGIWdmXoBYXPeOpwsuZ
#/h1A39hbemZmGE9vyB4tVjILCNKWSEAKUi+x8eFIniNv8kYHO4B2GYodIHzXow0y59yzHuy2OAgn1vzC2EKmVVApFrt3ZG3vKC+o
#bHT/G+toULNNE5v6bQZDXbgrdh9APv39Be5KwqfVxNum7io+jito/bzlFfaCsanIGf/Z1L8J5DJM/zUfSFmc8oY0HJkMrr/zEMr9
#1A6MTfCDSe5r6j2pegq5izCs/gYO7X7TYGb3q1WosnYY6QUzjk6c9BELMjlAl6vZnxSt1HByNsWpDo6gU8plaIeRpkSqH2iLjLQy
#aULhpzCbsDJw9zAgmaZDpgoFM4/a0KKBKJDSbOUmgIb+hQLa2WicdD6Vg79G3CdGYVkLlA74i3OMK5H1lV0cM1davPvuxea2D5iP
#iGgcZodNCtkxzqmGA+MilSs/Dv6oJ0isuUE+ZQ0ObRr8NOqYJtr/BH9dMjSOoq3fGzh35pAZeFaF1rIN+FIeDe1DERX5+Xa1o8MA
#YTOB/sm1BswiEe0Qdapil8/Ny6Jv8CYFijUW6gJw/t60K4IMWa5LrgdCtg3jACHifj13ItZZ2CrSVdwizD5gxIiUTiZNsTg8MP/T
#7A147FFneHHXyu5KTfrH+J9TbHFf5ot5BjQXoX3oitQP8TdRVJx3bybWUsKGTo6KsmYK8dRkwDIwqdnrYpggfjIwM1gKlG6Al20r
#J/Cbxkjq73iUV55U/gkUCiudKavB9duVqRNVc6ue7fe6Y7fRcrxn0CetYEJ0sGm31na4lW7jw46A5bb9mkMGunELd+a1dLqWNS24
#a6aBTyZPYz43Zi6M7Y+fLRoywTF3Ghj2Dqv0SksepBVvgP9b1tsdTjn3K7LvoQXZXQEkzPzJRBdXRDyN57JmeDX+/WjxyMF0WIMU
#Gf0yoTAC58LgXR4ylVlScw4aN1jpuCjJgh1zXZIovfd67fn5hVcb5Y6SlUUpFJM6O0fO8cwaWNHNrZCJmRibTZd6qEXaishLnNus
#R2XgGUcX03B2Cs0lIg2slwZ/6EjNkgW8edPMHgYto3x7bfOzcOZhrBJfyxyX29XqMoP5Ykj77Z/hAft1r4KqaRJvEX7iAqSv54to
#MB8CCH5Z292lzrXH7NKDO9MuarAG8EltD+Ht3c69h9jFFOc+cxxrFfh4FqssG8+jq4tahQq8ozqPkdJ6YH11AV5Hd8mkXtdT99fz
#IIPgcIh4uaGkhtw7n5mgRVtx15b7PPaNxeiyTRcvyNgcc5JbHh1dqUBU2TgZZW+NluKOAoPqqLZ5B8Gyb233do1Nxm4WCVodWOvs
#3qRgEBqnGc835e+VJGv1cjDnam/DnyOS4Ua2kA2QGgfLGXuOkN9kGA/p2MmZd4g0mbG099yE4ae7MJYf23q34PDLMO5mUCjRIb10
#XAVxWgSIJewv/yzRKMJTyBsy7rAmEFoLddV8ZMnq5OHneo9jz/VOAv98G5Rwc/IGvpkp27QbuiF2MsIOou7rMZ7ohhOsOqL7RSEg
#s5JXvPhuVTTmU9km5mvF08AaB4wO8+HWkj5M22MFZKyLRQ46cSQg/kp1tGPPtC9fjq6uXk7mRFSil5bBTa3n4NVfDf9UFw9zZ9AC
#m34bVqsBhGwnR7HkWnGEboIe6/3xuYVG2xVIPFL7NWof4FV8v4kso4MhMltYaj2jTcPqbGqcWJOu0DASUbroWRtbhdg6jlZ1glAH
#L827XBIYd/rZ5CxElrD0ukVNTmxAjkxbcDipSH0+czADRkPFAZy5QMhMQcmoFH61XcO/GoPVC1lH6CzhKNbCIW6ppaKl79MPNLZZ
#z+S3+qgfWs+iDnJ/oOYUK6j/Nh+Ot6fyez1n83I82E54fAqQBaY8G/IxbpMm29bpus7s1G3qDuztdSDoPn/KFs2Jjy2dtLU5b/Ps
#4AYD6siWSPbL8usqp+YJ610vNpps0S3x+/76t7sG2jauIkqXqPFGrwkDmL29dmfzeI/s+/RPepWibt2ozz7rxaJJ8dxjiKbOfDNr
#wKZU+RJkY41/p7/5d3RMdvTVnC0wRh0Svy+rmW4S8x7+cNJffzg2IN5F0pr/JSVArCxgOuzla23gxhrT1nWwOsHwJpoZ+9Mz1aNg
#KZp6mvpJ6S34+KX5tny/F6GX+WHSyUuNf5iXFtOXlpk29pJdY5bDElF/qfTLskT8XrdJi3WG4V4lN0OgFHRVz2R0+tQjSgQnTd20
#7M6/eNWUL+DumOpHQPrETVc6bJt6wwk3U8kMgEd562q3kAy889wPf6y5M+bILVck2EiC934gcxXC+qymkHdFWgsvA/Ab3CzLt62N
#14CeEOpKwvza0sfENBtpqgafwKrjBKY059qoQFt4bGeyh/6iH/WzU94t0sRPfgSE+5GNU3zPKc4/C8YHuP0s8Xlanl/4lumyvYem
#hfcdUJlQQCA9vNPuvAveh3/o7+1scdTgM8LT6hV4JM9qW2jrmdJqPtD2obDS+2KKTTTkCRwaGWtc2MAOhJ8a+vFnB/KoYPon/hYW
#yl5t94AtR49uCQImQchiv2UqpEJwGoaG0NlSw5hVs0pvalP1qXPBTMhaPRgc+soPMlUaRF5to5ZSAmKiRiRCRJxxw6Esh9dQZYkH
#SSDJJ28X+Mc9y/Ikq0+G1eZSKfJ98SloMvONExS3Jw/78RB5S2pjozAg3hwZ9n8mDCBquIM0ox1mif5dE/z1roB8dfHqQjaEyXkL
#yc3blKMWGzIGbipqPpHJAMaABQTSk8droudLfnHdYIMVPByQYfLAyI14eTQjnNSQ0SPjs7fr0ipEmWbBGzQkcRMyjSHLSfqSdWx/
#Jm8hMLBu6hJ3Vpwb+hXV3yJDO5gHQzKxz7XExsfqBH5LyBBh0RJ4STDAu6n3Vmv5JXyqtbyfkI5AvYjZox19XeRrEO+EmwwHY8ul
#eLFev/gEPXvBr+4JvAY6ZOQYFlb61FzKD9+mIC6ocqokkIUFrC92Gn8uz3bVCjNDGswoRK0wJs1spf9UfHjI2f6aaFQvOw1qlATp
#CTiFQxO6iuNpiH4k9LOvPtM+hqiJH8bNBhtB9Gm3C43c10FKMwwgMKTRSGLHXx5YMdILk/FZjAC80/ddQQ5PRiBkTlchAncnKS7w
#CBMp/oGMCGOMlwJsV/DANEgh4eCRxcVYQp9Am2KAmXm1gTVQIlHLgyWwiBUbsZFEAJ08YsgmFQnwJUGhUYHaFLSpVYokKwgK2fUG
#INBTiFTOm1AexSSziD4oXrQ4g+jbCwPxFZRX7LeLgIlyLEebPMWKXTiLGW5O8TSQOfeFMyJWogIpIruESwiyexD85dKwajPQwyA/
#Chkv1F9H6Zqolv4wkZk3BgoOikppDiOte77zLKWEl5yzUIgZDJmsv1h9EWrVrWEUAxC7c9xVC3WhbhjzyetFyj7nxiWebYSzy+94
#+UvTdR1WCggGHqkHjqlHXmReTW7X9+N5XbD0UrDiUE7S/udoe4W23cLWHJbwRbwpyqoJHgGjZEqefG5zWS38VjhF6IeI2GbUKaFC
#bTyC7xiG9PdWWjGxWq5Qty5q6GxeKwMmTfngmlrJXwA5qrC0uPi+as+N5baNabmmpNAnoNHT80JJEyARYzFCiOIgEVQiEXYySboX
#cVg8WzfH0PeOYSJmYiqqJz2LbAO2BP5n9pcpFmlEDideiE4i2l0fbdYHjJTz2hcEx3kdbttapSoeHBM5IYdYBqtMM8NhktnCIZV/
#apYAlEUKEWtNtGAg89/ZVX2SyN3faK5mGQhe/dMqmelimdlkGVkYZx7HOR3JW6/rX4o3aZJH9J5y93mHBksDUYhAo99Lz5qWLAwj
#xCmNkfUiefgGTkYNQsZRjdENvYDS5cUA0jmt6DTpXHOK1YSh9sVIqWSesQVP+nbktyqqpL+6KQsX2m40zuaCSZZ0QC+mAnFe0sWi
#X9XCcTZG+E8c/FVCq4X5wMlCAwFCZYVnSC8NN1Dn9Koh6k90P02WNsf5fF/QkKBALJKRoFB+3QQfkP9zCN7/p/lf8J9Ghk429v9o
#nU1tLWmN7e1MTO2cTU3+OwjK9v8GBP3f85+sLKzs/zP/yczIyvL/85//J/I/+E9NbwDE/6oLxf/pY/4/8p8BXNgNQDgRbv8FgKJB
#BBBAZqMiQkAFFosEfJJBB5P8NxA0XOS/QFA08AgAmAA1bJYOUpsssRk78HwJZx+MGbF1O3BFJUOYWJhhDHAGZjnx1z9z0hRCOlo+
#WQwb886iQE3VksrArwO5N4OMIgcGi0t/mey0vfOQlOVIHeS3q5dvbH4DbGJiYsxpuJMXUWV4OB21R8Cmy5RN1B4xyo6CgiTm2YCy
#h2myd6euA/ad76RCAhWeJFSMyIkxq+esL34ob6Sn2tAvKC8sOc+lWXEdkFFa7+VsT4/fj5+HP+Nan1ngnHx7cgxC5gBVG3pfyp69
#crA2v7tfD187v1mfu5pMVA68otHxBFvlWSmmaovqUXtFfXL9Bkaoonexl/2/rxLuur8d2f4xzshSbpbBdjMWORO6Hz9+f9u5L0Ao
#FiVy4WJOk6gVRpIgYxYX4cjpF8Kc1T5MQCwJsA2aGJPTiKP8o2p27EVAg6Ub15m/bb0gYO+navA/4RzKHBwS5Es5JpBxx95it5t6
#2bmn2zUaE2XpQ+43pXyhnGyuwt3XOHHWuP6n9j17cy+qvR+jTdE3oYJEZFikAiO1rKc7PYiT+8rLuSuzuzr6q7Rha7uD1hZnzRuT
#IiIwXyMFEsgia0z+Is7caq3v7FzSl+BlPMUAqP09Jt1ZMAh1zhroPRRVfzIBg6+/FfLfIroTQynNkLJfoA1QqHyYNafBT1HKs22G
#PQbrrFwcvFy2l4CuMBwRfwwSQdqxAHJCB41AEAmcQxJ0y+bEThOllD0267eqCovPNrnmHbWPnIiVSqeevAzVFV5gnrNvolVCEy2z
#E84YrBCgmO+2MdjejX/cfUX56VtP0aDCTBrRPsBrm65Pg04O0oEE4QYLf5t3Y7OF8tIEKhAp8SLVKHDNXmdhgRcuMSJCml5N+iiu
#eb/LUaFNrDRVIB86PkXYNIWgmVNQWsotH3xljCGIJGijgJRP9pWmX38wYkBsQFPSgt3jXc6HHRYiUnCafGXSKTna6vh/fwN5H36h
#AGD7SBiJWmK0EFQE1c8SEo9DMPmoAE5vCdvD0JxBkjKLeKme3cUxi5KxjKmUKCusJVWfnuimd2eTKT9xprO7XeJb87dlLG3IqIVy
#HJ3VQkVFdaQHZ6aW0MzXuLqmlLaWuqCalfEYa12RhZYqqHgxYhTw33/Olb1f4mSkUoJya6V4cw9uwA6QUhQ5AvBMDNp0y5u5Nvd3
#Vul3ZTc6zwgiQpilibCaP9vamexyMrGkbaJsdDsEaUSXROYmhMFitc7fnl68r8x8EDawdTYZmUp99jrGZkF6klelCeH+eESmCS16
#zH9j6WYzR//mnlc4ApFRnuE4QGzv4gG0AcwE3dYR8xEMgEB+53SjyPyHcQhg0ZgeQ79DhA4GCyQkFbBtC+AW82F8Cn4fC5BKFDoI
#5xmG8hHFhI1lhLYdwR3neM/93grC8ITuuoOuCcIJkPIHCeApIKYR7DCcBiUpdfvvz86EJwUCwVy6/CmiezgoWGZl12CoguZxfUvo
#QPnv4krw4FfkGWIkB+XwQcwnEKeHFE+KpZCygSB2VQy6mpbCIOTLAczsYJrfUoA2fcbyac2DpLoCJ/5dcV5n1EZ9FkZ9ikHbew7M
#fRwR4YdQiGHCYcyBH2UY8ABHkwc8YDDggTmu+8AfEKBzSBa7Oh+CvIATY732eAUYvKMO3vufqrIgXXIy4cg07b64XYgou3THYU1b
#+GztVS5bp7PIWGkPvdiqbkWSLvBo8RaZ8pHJh7VEqpmMR3yy7g4hWUt3dM9kDreN88LY+c6AGB8vh12SWQcqZuaq+L0Ef+rhX7ny
#1ny5dmWGQC9YPo5ytaja3qTcqXR2rK5COUWFIswwFi1ZCcUodTQYSqQwltjCVgKY5qZUnwt7aLRN3sMRYDYgcxPw4GOkxaV5xTeW
#0KtGS0HEIQB94/rcLL15ZIx5OknbnUrNnpjEHhtUPsXdc2/KjfXik5kaUzXB0NybXv025T9twH8pikPRiruaQkEsUr9SSj87rtv5
#fw5moSAYPPdN4cVUJmiU8n+UwcPyn7tEH8zpKpPs9A7r4YqfT+F/jyx0PEZSA2DBiAZ6ZK5T4mOFfiog6Ny4An3ny4O/9iD7kH2t
#N/TGVBhDJuj7/cumA/C8osLYCufo3nUH+HjQ1etNUFoKB10xtIJ07fKRUdENfb0rtDDJUp8nOz7RVQTgxRJfjDWTnDDp994sHm7B
#onAPIMMvG+1gqIH7J+lDzJkonSmeUxNpeOOAgyjJ4LEjryVUGBYBgMJYKjIeZfy6HJazGMP7lNhYkJc8XulPVLMD4kRZlGv3XEA/
#hDGgUVpP3dV0l+6bUqzc4huQ2GZcbEGsV2zgKxOdXW7OFr5z668jUAItQNgQ+w/wuaju74KDOrPSvH/TYBs55L7gX/uGCAWW1NwW
#iIDZOKwG8JeegmHQOmuLsX7sfoj3X5TDVVn9kggeAs90dZ8ynFqKCVOwlVNAznMQiAvukwSSCHYAtAnVfFY2DFx58GdbpXFi4JSh
#d9L22MiZBB6fR1nrtZLEF764ZZl+FAwdv3uu8ACDY/qyhdgW7y7xgF3HMoJLRBbC+X2jdVhmrGCg+4oxWYjUmKY8TYxG/uDQigmC
#bKCiWx8evRtoqeffx7st9zcY4HXQMMBhleJVvVia7sp16hYEcuZ8QXlLYnpwdHNLYnZmIhmBMUQ4B/j7OiIg8RrR/mgyy1OvCz5o
#8jcQEyAg59RFPsNBuIQiBWNixBnLRIKcPzVx3oK836Im3gGFCsuLESgGKWDFor+IpkCFN2stlPA9DCuM7fuqlmGwokWRdlU0O+Ca
#yMCxTOIRuS9XMWo4Ik4YsIix/5GTvxOrgDUaDLXfN6GSh8X8LSU2IyxCdX1G8o4ed187f9pAKgStrre+S0FHy7DTWRXk4ifjxPiP
#J59L2GNQ7OHtRAzIY6GvF7isWN4scIZfj/VGgKUxraNro62ZQNutBaMmFhUr58o4kwiR5aomIy3Sb3r9E9RKWkXgAN3pRA049cEp
#x7VQgvRy2GIFFsRakHDDhqHvWFgi9U1Tz3A4KrleoIik1tRQz5Z0WgFy1e5n8mgPs+lEKrF67jeQYoNBeTdILu+gRJHM8rE5BAJd
#CLncREKWRLMbJwLoMSlRDgO4mvKVJVXPiUIkEkqByAm548GKVKwEX4LQI1ICJ51mC2eqWlluImySNUsFGXK7EnXnBipRiFQwSRUa
#NWQKRznplhCURESek9CzY8S7kxXL44JMRGYwyEtwNIdygYJOpSoMlERSVtEo63vBwPs1Q3A2MwPVTm/eZhZ1NYP262//yAPUDkc0
#TXLl7TSbd/WXBuICkybY4qL85Hk1reNKweVP1xLaJgorGY9nF5kckZBqqIpIiJrFEqIXD5jC4ORS+06aagbUpN+M9aMlXTfFjuc+
#vX5yNV0BU9m9UnFSSJNRRUQCZZpiei5tghWsPt3g5QplqSmvsgCklEfJvPAb1kSpjplCeFUFYTajw6IGjl34JzYfLUzjFHI56/UQ
#aPj9Gfut/T9bxqoCddyOPxNJNMGxew/jbM6tA0/1rSTc0HhXuJ+X3p1PeW/fdPGdZ1siEn7Yql8kSqTRADnebuLbMF2qmRxUnax/
#UdvGH+biGSrJlX0OBLgXTmcvqbvbvgVRyrSyOk4LuhRIteA2aB8FVlpGoaqCVoUmr0a8+Ig4pFNRSE1A0/obswAi+4PRUJWS5aWZ
#wRKw2oqyQkKuQu/GYIBiDeF6uQmSHIUJOjTFiZCPFChto5MVtUJbSv7itB3LUvG/4Z2damlWKIoypCPLihS1GvMBnlxKYrkkTIKU
#HyjCpLzSIgxkQSWEEUiKXZhamyc0oMUSylClI9GSHN478XkYu+Ok9FPoFMn+PSIUQmSJNA86SjKO4Qpx2gOr5iElzWwSD+/l4q0G
#XuFOlFVXNz59nrmClIai9FPFUdByTU7uPTnxZ2cwYwcHyAiyvZux+nLCYxnY//B4MtI/7k/G9P0lGKOiiadUMOyeL/f/FXHEGYS9
#xxFr8AQgK4CAWQ0fEIFxQHFgcYBxoHHAceBxAHJYCmwB3oA1488bCowBUgIrgRfDjmtQMA9WA26MC9I9xscB0dcuLUIiS16FruRR
#Zz4jEgMUeuDMhFY5LqMqzRzPBzP6LPiQgzn0g8J7QxDQoL3QD/9gRkiXTQUASZXvA7RYV6/X07klItbeuv37NwCcyzAAY/+W8HUx
#+4sMVBqxIVmNEOZOQoAoKQG3VZ1Pu1nAy5VPrBQf2cxddkdhbPnDtuT3JMMDbUIM3jEuzAfVXf9K1N0el0iedltqU/CIq2pjT4AR
#PICBBLczWu/yTicWHAdStLjAHM2eJ/AwXLJyLV+zdvCCs9PeW4r6fZwe/oOI4nhNL/5GjxEATOe+Lwxg2GCqsq5zMILILHpLQlWd
#obJVf2CCbbFWm5KNLIZ29UsLi8hBBSR4P3+rlQ8NGSgKLM5IaDHPX6tWyZmNFMejJpFh97kprrR6JGyoj5mqDLI1FaNSs7KxapZJ
#rMSAqMnItWttaHLDwZev3qvfPlw9IrkGxCY/gpxYoYWUHqRyi4JBrntcM7bzJ9xENhPLXb7J37pVvsgEPc0klAH0Q5BSUZphF5ph
#lmEb23GqaZs007plWOZjg8UrJoPPao7HAk6hfs9yVFCTbT9T3NLMhiD01Rr6GpAbzuegMmFtvPlca0CQghn1ZnzWwxeV0QS2DcVq
#Fn37z2mpgFkoj6+5p+4zAt1OO8T5OqRGU+OVtyBqI/hudUWU37etaf7kzNL8ei4sFt8KaMfuIHHR4XRWPTwd27F4XwWYnS9QVHja
#619Z6+GkdjwFjjSyoqNRs2wA0QNRZHwiMboeDZFcLDEIyvOoHQjEWBjMMHnZ0YQ+BlZ5HzFDTHQqOH+B0d97YzMQdpevi6umB+Xm
#7C/tLhri7Z06O/qpuZGqvIcbpN2JZ+0h0uyVPLMdrhYXBPnHzZ11sHF8nxch7BVwcDqR00R8PFEiGTgSa0bKPFpco4HgnfOb3AoE
#NTN9kR4Kho9I/SANKk/+X0RwwrCJsttd4yJVlaqWcY3r6pbBEYVmZhZGhmmXV1RNK+odbJdKD3s33c808fwnEVY+claYt9PtyPlg
#HDYvJtVdUKVlnOT1RMRbIWb5BES0rvIbXlB9Zj2zLv7Rv8ZPo2yYbsm32pDqBbCxLkfMAFd7ub9IgacaAJ3QkSCCKJT4PCv/D7zW
#xdFIbDlnKpskquNBn4YbXJwtd/ekSCsGM4iWilNRZZ3CxPhdaE9AdiE8ezEfoZiABFbHTshd+n9EH80fHVdDzpPp7rb/duXRQrLN
#PAude1LDrC8DLEDLzJ0q+oH8MA+Tn/rA31T/8xcbyHEAsXsV5r64MWJhhwbFAS6GwaqzMvMvNIMDxdZIcAlV9/KQGbL6II7WFxJn
#TauSXLtu2YotIuU7apUbPFf7sTTh2cJjTJKmhCdVNVfKGbjWURmwqQWKXzSNaoQDCBViDl8oNGmvmqsF2IRad3NecATYfbcmkNf0
#T+wBZb4ff/oA9/7sG5Tf1qh6+FvMtWpbdQBAOEA4tnTjyZsma04MpxLAm4bds4LsOC/97nxcthzJcR40ashYsdYIL6TnejA+CUC5
#R4qPqemXFk1zGnQwSopbi+00QGrBdkmFii3KcJ1HtdGR/rP1vHBvXDC2lGuovPnlUaWG+AEbH/7wuC/SlHfbr+K98Cwe5u3ziAPp
#ybpOW5p6xYD2eh7jeB8OcuSxkPrtlHX+9fuuwB0ZOkA4PEBKcigoKFmKziUgY6qT3fKke3hOSpcTDAiJPKiSCVZzSB6SSq2qZcYq
#FV8WRNV2Wtr762g2nkw9yOQSgmGZ1CdERh/W9Ov7rSdAq7N2nTdS03WwpuaY7jjGy42s+SwjBGS3OUHmy10Mj1JxvDdUathugl2+
#rAfkqoxx91aNtPjtVb0D07Ny492u8ZCFx2HN9SruX4GO3vYp+X6fcGqV/uGJScjbFyPSq8LksyYLG9M+yElc4oGBqsfHn1ipxCtV
#rwcCLeBCM6uT64wEIwROuZQ6bdygVbiN5WdIqI7EHu60l+nqQsWmzNpumbwdbEwMbeWfjSOtkdtwdccj/PuV8JrqtAI2So3PSCQn
#AU/VWq8XBP/tkWx4X/liqzRbV+B7VeNA6vzZUm6VrJtd2tE9s3B8bfj3WjtezO/27JwixFgx5qW0fwcTHb+7Bj7/sn/PlHWFvwgi
#gyTIagu7mF9B+LAfMVVjZztzrMTY5o5JX4jhdKUnYaHSVU6yUT4KbOufOmwpGGEhwGi09kq5+bychqMqhWW9BF4V2FiHGJA9K3Wk
#4G/LKrP0YB2opPqiTHUjLCShXPRXn+3VI9iw/mi4NGz7UqjWReL3TMoeXz6jUZ0vZOW5W0Q9LDCznIiMYFslsRktoQVJZWpqHVyw
#YQhLL8IyNzB7mpKoUb504vK6ibHcbs5m5X8QTTSkEk+iKeSDQqzxpVQjdmYJPTXA0f/I1NGGhEJktdyVJ1NukzwLHp5IjTC6Wu2C
#gyX49lDaJlbN18RDNijTFfuRUtxnkJwCVk/8qcTVTpq4BFC6HxTeihpekONejEcn0qxUYyaD36xCGIQXUI1xtqabN+JWA49xOb4O
#GFFA++d6xmRlQ0quRZbBqHpj+VDiX+wWbdpCLjt0Mo4aHUuYgawQnmq+d6IEk7brlfOzsDiZNZ9m6O4PxtohSUmMlQwRBJgmkILc
#68rMQMsaEb6Tm65bl30osurafYUpDwc7JB1ZIEIZ7cR7UY0gcfk0PUhCRn5Kth0uOJ+Yx9AVkI0z/k1Nv7cWiMZslocdnwoxLoFi
#Qgp4TIK4ngjymAgDlQgUmQglldjaJQk52J1cVdelp5Do/Q9TRa0VqlUrt+9mSzvj7C9G4RTkzMy6IitX2fvAwZYDNZtKDnZswNER
#Izbs6GjZEet9mTBVserW2KBUiHRNd6VWimXxQe5YzDPaomNx8idmkZxBQAKcZHbqXI8vDXtswF8P5thhz3Gbdtg3gzTL9pvadR7j
#s9T7dz/c3d7lLh3ZJNDYh02SrYjFWnY6BwAgVs2UL85mdYZ9MlhjtP8ZpAAopYJy6mrqyjUzQlQicGC5wdkssiOMIkW2mC7pM3s3
#r5QS9wB+Zp6brcPXjM3rRDO3h4BxzAUf1ZiMKMLmUGtt/qloWbLfKVOQe4pDShVxUk5iEYwfW2P00cuP5rM6i1R3mq4C207clXCl
#mHhxlXnysokHxsPFqpKYykVIsoE6MM2CZXjI4YwqLxrogCqk2XEXwrWluAEJlh2j/lDIBfIRIbwYRbELah0lCkyiADqKKxvtYqH5
#TmMgn3ieEpWEcOrpt+YKwzV3FagWsc1gLFSWpoCAuGwlib6BZjWYjlOGaWSwHEdt5YwXA6s/UUJdO7LM/W59F3l/BRsPzknnBjaE
#fYASCYZgkbrshH2m1ZPGOsOL7Yln8fXa2T5rJuLfymSqb8nchGgtrbM8nTMVO4Y+O9PMcCNFlYk8DJ1R+lCpon9uOIu1FXvvCokP
#Rsl01WyfyarXYII1Zy4/ERjE6O0+43VJmumuRrWLFiuizs3oqbPAszU0a47aaiXxtK+78bSbR5X43eqp0K5kB3NbBTDzNdJJcnNX
#O5/+wINIujUI6aZKVUDjLeaMIl5cNft1ADJpTFLGLhsIT/qFLnj2o0VpWai/edMYOh4wwtNlaT7pPjC7zzrwqLjdZzvpPnLbTdkn
#R+vcqEgeO4i3YSk993503fSzq3A/u1mXvezheB+2ss8e0n3Q1q04E5Kv09IcLWBf+46v6ajbvVufIjqUWxpjqDn30lETiDfvlBfB
#Eyv3BB/5BFZf4iQqE/tkBvpJ14eJ21jgSA4amWZUYrfmdhpdanBUyYGRZrtGL4FWgkmNzKMZajJqdSzUqgiodVGgK3Thi+RqKIk8
#cmfT9M9WnvLyYBMD6CO75EjI4alZ90/pm4xg43t3xOcdYTOgYVsXqAlfPpv/NLD1n3H9xb9+B+7yv4HXPkEPDDW/fYrxeGQmN7Hu
#RhyWLTTVHon65maWD4cFtz2BVnIwD7fMkcqjmiw1UhOanpEtoxguXsHIiaXg70621qQb+KX1MRQ4GOZeMj4lsprhZkbNwaz0ZWHU
#tqiBZmIPVktWsA0uU43BaNUm+6azOPP6hcdzIZRTGUB9ut1xRwZ7NGS9SSDiRhGFd0oyz4D4jBkQI01GVZFo6zCKOROhijNTqOn5
#F6A4pYjkZNDCRJXC3fbPH8LVWxVlMzZU6f0RejG9NIAry/pkmWMV8hfLWGFK2SmPCO8USdvElILkWlPSBN3MVTBN2uRFEzVSAYZ+
#TgLxK/xw2y4lWBD3YCKAdP9LXLf2nzT2SUdlDrzUE5FrqCXGUzrr4mE5qzLSqupwCBRM/UB7Zah0Gz5ryNiBMbdIghEZLX9EQQxC
#IocdHmc5hxAUUMR+vMkLaulrraCJgH1ISZDP6H5OjpwrEOdsWpjwQENsyIgSPjKpiiIy9+cQTn3DrK+wyaJCxsATyJJhosV+FJiQ
#4AGb3z2SCBBN/UmZeDQGRpCIUAzguM5eJMGE6OuYSwmrua/BKTFodZ/mNAiUJQ8GUMdhxgr5N+g7Dvcx7C7gDTyBGnqqJrgoGGYQ
#vRgZ/ai6AiN2m2hHhvpFAfS6WNaxx7H806LcbkhCC0RJkbxgbo7iR9fPR5wFyYtEp0H7ESC6eoXYq5Yij2FgR+9PlqDraCQrw3Ab
#o7hLcDJuUa+uAu67+MH1t/fQhR1BwnedcKcBdxCGfIhI4PQLBW0YgRryoWiE2Fx8c2qDfcDRwn0OIRCCvpxHJp7QCQaJ5oxttixS
#8e8AoHrS1woLyLsFqXtCyNgPp5LOKInldFg5sD4EEPf3zdl15+iwbofrHSLEwjZQZuM/KihkxPHLNsbXpCuxJi8NnJ9Bwnmx4l4l
#p+0HfRxSmtOqr/tHIKdseh4EXlxow2oKN7VoiDbXV/ABVbuLTXZEIuYvfocMXRMAYsZjSjf9BaQ6HrXKcUhcW2EdnIIQ2L+ZpzIh
#g1wvQtGCfSKGcMGocSSWDvHqgdi+KttwCcJ+ZZCciIRueQELHBNmb/4oKkRfGH5EFUeAf4wc4UHqtLVE9E4Yz+LBZ7dTfCCDzy7G
#ianhTmyGCuBYCekTYDboCF4+DNqp6r5rEMaMEjlwiWVGWCK3U2QFmx+mhZ/Bcv94HcBVCH4xYw4AQhGK4UhaL/ZZ05ipqv0bTPBX
#Z9z5uANWsoxSxie8EZDzjs1ONEiMoh4EhKTrMX3TKzifPqKzZ6cJcHjRvq0wovY8VblNc3YhSVkhEPFv1CjFDTobiooGNrEddqSs
#3PLKeOShahgpR250OZb9RaTpiQr3brftrQ5EFscjIcj3oJYWA14DcTv08gHcJkbNXPoGgHgsxtnkJKPpVpmsYhEsUo83Ena6EUOX
#h+HahFd20vWsqBZEkVvHEL++gSpD7hziBLsCYfopNOUuC6mtuHWI/SUbx1QuSgl+o5P2V2OTD4NTdWIBFaenFgIVsrktxSf/LBlb
#1J0Do4s+oV1w8GccmpCRwggYvHqYbbx1r+yhkqJ7nageuBm3Ir+NCmgm8nExLf1z0bo1Bh/53DWi4HZAi/1KDESLR9GLi7i8UYRm
#ImwxGvUqyHbnyKRyLVXdVvB6jQmLKGR90lMzC/iAFJV1OO1X2Tz3SiW5sSPpZh9G+MLnTeBq0nPqf1kUnz4CpRW/IKpA7aKpWtNN
#VLY6JuKjKWu6AwoKvcm2RSIE1BVmTxJU5Hp2e2X5DDutRHrafXdX2xqTtH9Uoyj8cexAdHUB3JVsKgRgut96X06YwYEd7x81yuJ6
#rO0i9xwIDweDVW026Fo1X6ivpd5+Lo5kJKC5vu50At4tf7zkFPdsq5p+5+0vx7cahlACMcZ54J19zc6MfGyWAnvZErwKlr4BZ2Wu
#owEZYlKY8lkR/T7U59bQLuBKxIK7FFkDBr6WIA3vNw8Hf9T11X8LRoZ7nl/FpPMLqakzlK9EyuOGU+isYEBrrDJSKZS7rIFrqzjG
#13lFwfadiIL24KprjvdabsmtrcZtlxZpM5Dy7mtyFcavSHEu5VBhQDzskIdfurwA9A4TK2cm13eZv2SsVllt/G1c53O3UifrMufe
#I3RlKEqX6GN1wV9wzy89Og2277BIEaE0jkAuwNXwWkKfGYhudRsbqAp/FC15C4vI4QTrT2AtGHu3VZSwM4nahrtO85s7o1WCzrux
#5c0PNaQbZue0qDFKNRERnETW/rPqLK32sY5LlsczMFbNx5UTYkM4+1hMAWI05l9vfvoHuK6d+Y/6Mmof4ZAkR2S9ErnGKW7iatq+
#aamw0OFvKDgXQXCaJEmTdW6+l2F7VGiWW5VPQZDFlRIJ9zrAhtrVkR/cW0dhzgU8d575YHrcCAZ7NNRNaLGZUI0l+LbUOcGD7rn1
#dj0Ma3wStztSOpfP1wSqdRdqyqnjQhB9u8tBqlHktaJk2Ng9lMibVNVvzSuJt410Ilex9nRz1NWcEkjFj7JtWwu7OA/UmfbQ94SZ
#cyA5a/ksAY6smC12u7Q/nNpChKCaeHgAicXBP0EBn5a2QB8klrT67RggaeZsJxv+ivFgY5zQDjP569t1HOryAZVfv+LCCFXWdn3T
#UmWueBakkPfOnkPag7Rxb8aTCeTx7FfAclEstAdBziUZizB/gVjPxMZJOA6BjpfKZwwsyR0scHQuQzU5BTuMtSUA4TI81I2tzkp/
#8uBtn9QPlCQJEbiFJ5qX4C9VG3B8tdV2RqvqCABgtDPKNuDuWRuUy6H6/YvegHuAs5DqyJ/SWWdyHtATo4OmiaMT9mINQgjayhZk
#mWQI6p6QK6cCmUZ89jBtxCxHSjpSKX1QXsWYNKVhCffnfp9CD/KG2MP1vPnnl54INhB6ge/WviXX2CoXWzHUHFDCh2PGu/fpFoTa
#xg6X45Yzfk/qqYBCj8knDm1CxQNc9AVQ4psIsIyUB063wy5pRIggSU1vywhoj0NKX//dZag+zAJHr/9cny2nfZfsQipFOI1xCqKA
#QsRm2JlH8JzaLPDls1TTGOO4/K2/7BuQgA1Y4bb/6ZOVS8JKo+MiKLYZPUfpm1a8aRz+QMfr1qCmaR70gtPMBJgO1mGjyweiV0Zq
#pZzufvLcVa5aaMunCEqopqCyA1tCJkSWY4+k68y2JM4m39dQ1eWrfotXo3ybzQcdKbXoFaRXFIbahGnzRfiszuJQ9pgT0hVK47TE
#v/FHCD/Wb6R4+Z4I7ZdCM8XOa8DCFrsk+Ob0QF7TOCB7WAnybQLzFf6Jx0TYEcEeUG/b8+E578TYOUVI0cRE5EDQ9JRfFdjD0bUN
#WKWIOe3D2VFRX9OwU2j+VLTVAk7WLORyK0KVSC6TZt76ik5ncZktxVKZgLlT6a/x2xGQdjAlrR+s6WUvSfHMjPP3UK9GVOVQdZ21
#DDnKkqOkFfKffNS2fIsh/Hsyua7EwVAc4rIpbVBb5CSzh+XfV40h8qV15QcnwF4TMVAwpKtDMGaqaSrRf0efECV6FCHAjjPuJGOX
#O+nWuIn4yIvXIrh7ilqMazl/mS9NoIhi23L9iCeP6T8QTDuokldAJzDU67rHwiCqkL/KT3Ito8c9BKlQK1IqmTnzk4ecYBndrsZZ
#6qbHwXrBtBMhApRliIVz7NhsFIvHYgC6zYRk10brrVgf3Aoj4tvO2RKZKh/C7GhyueKbdc+qtIAnOCgYXoM8rfLRMgBt5O0qjwx5
#NVA+dhhs1eiDLY7pXJUbHb7MWMeqUuOS15LuBWqkgUPR2VDVCaSmB5+aNkmALBg1BFG3F97iTCkW+5RM7JZlz3YOc2FqjNL2w3rz
#T93Aa58qNvswY4dfQpWjJK+0VhuWokFBRPA4HpV6SLTEBOsa3zCCk0WosWtlLlDGSLpVpe4a49MG1kxplalbBSMyvuoI7tVMMgwk
#V5ykplZT7Co1BbIpO2xrLN6yaFSfcdQqZJpRasBMMaLFNy2/KByojFC8UTgxLsEaKZuGkvXabx0+Qp2ljvxLXBNTnGK4Gmi64uyH
#skUJqqOXho1nB7fgnUHMn/f1c0kqeaUQYnyIEV4LuL69YsZf0twvJqRjYvVbM1bOkz8/k7pxHdvZCLliOmG/kY7SBOzXnN+oa3sY
#ZwfZl+51t93y1lt48yaXQ0RG2I/XSrmVEuG5dTDt0Bu8qzw83WWWruC2Pz7ZqR5oGS19ynyt9ABG+GaCQYUpz7jB7IROqvIjU/bx
#RAjaePiowjDlBy0iCURJR4K+PGevMkp0AzIBcoD1N/YHSIDKIGmH05G6gHYc4QPAC+s4h+FOLAVFMU0KzTvYLk2EpDOlBiDEOLWp
#qvypyNhZcaMvlm/dC9U7x7S1voqxdqCJiFW/BlAHtKAdgCXdTVyV5QdjrJ6IB9sHA9jZxW5u3tjUKyivby2RxZPHamptL89Hbxag
#Qasy6TG0UzSi0lQ3kjBh0MxFFABYT3kVG+VZneO/S3h/0tjj1Zk6v6edb2ou8uuiqwd9YLyzKYxSQpCdrKqYrMSPXlsfugebmfUu
#cX6NJsn87vHLqXsuFUSXvDo+zhjsZAHQt8LLMQMX/VEDiFwlAYOIBfRt+eUuVfLZvP8DgDgNMuhhB5BIapaTesmyJXj0V5udNE/h
#aV/Mnq6GwMP5gXXs6vB0tGwNl6S+XNcvds2otqWLuTJ34VzKoppJK0+q01c3WvfHmje2LtxC8IJWrofi+1N7LT2LdQNHy93LWDCK
#cp9mIhc+dX2M1jP6yN4bD1pdNIMtAfI4Cvz0l2Ov/esNrWj71M0g3bCs7pfKgUU0Od5OBsfkbZaaagGCej5EoguJRZA44WMFNdsi
#0pnkragXyXZfOO7800qbyE1Ha2a7Onsji3b6lN9AoDO64p8QPGCXEb7V1nWUptN3k+5bGk2QEzvBjosqTYSrXcIN/5khd7rcpFuy
#X+yiXaWD3/sR1gZ5W6XUTsu6Ewy+8lx4ppQx4jIVecsiWfdtxp8Rr4STqm1MFNrQoFuQiAN9g00w+P7rv+Te8rKoJHx8RHAIuoUF
#3+SZ7zl+LXopM0h3Xswk9tUNymXq0ZKaMQ/iSGsZVU4PiX2VwlSMHRdHAZnd8aYzMbkaPAWDXr1IbK+PBYvirDbGLuDZ1Uk4u/BS
#hO2cy/dz2NkmGvIZ+beWKWOh7YGZaTWIAw1owA2Hb3nM7OsxHh7i+gOwDZS/t1NrmRygZvCMfWPckmoMSPOVP+Y+SxCqerEJ2A4p
#0LX3pVK2snhyMIY0BMgGxW5Sz7oCUBRw7UU0+8azfFPfudQWE+S5k6/Y4un62SbcpsQr3B+CNe+Gxu/MYkRKa5q76JZEbh6bDbOU
#EMuONeAM8Gx9TVquu3TXISeNXQ0bq1dG/oI7uaDHkAKREoIueqBeGa2xvMvAvHMqWZRqZm7neKRzA1fUKqHaPpMEU9ntKVxSYiln
#v/kz26wfJ3SHB3DIbuHZz9Yvkaf0k5c6GvBB91Ue1wAuLfVqiO8X130FiNLkoArD4q7NywrJnG4pwnu2Zhdm9qsExcXsYlebuUHb
#W7mb1npu8Kg9q7z4coagdoTuf8mWe8aszeSqDf+UMTGQ5ckkYOnuFK2EpYATo0DxeTZWMp+RE+5z7Vzh8vwkJQZO+68GTuzk3Jxp
#Y93crVj52W/RwS7HHaD6pSu9EhMTakQgNDKjdMNJno+hPI9IVUYdIT/VjvZdQm6qH0nn5vPJ2gp1WQwWi2319ffPNSj6GpiRBzV8
#DZZk0wjg/hjbZKTAP3QDEACwBX7YaLuix4kZQC9Hh+wSQU9TxnoIOSL3slULAGRSVGrg1v/WININDBMrPFRaqLFcBQty4kX1pwVG
#vztlpBAwPotSbTLEK5akDcT9djJbf+ven7T2c0souKbysU7WAB5Ak+dNMeGdAmpCvo9dXw/IX54aDXp0OCuPjpaWfxoubKjWgHsM
#4mHhk/cTL9jJJSAlEJdZzosHXdjsST/M7P1UJkqXwz5RbJlgwOM3ciS8r40M76aODxaViSI6SJIrZKDsJIxs5LDIrm9D8WiXLhWH
#0rT/6NZsE9OMbWcrLzwLOG5x89veT+mTyXBTdXAx9vdEywj00JiPE4zp+QSF4KvwNMTCpjA0gydA8OMLGp/JaTMIephbzvMBciAW
#NWUEh9gl7phrr6BvmnDW/P6RWKiLtOkKKjTtlVCPCC/qZRhBP21saQWjItOHYc9dm+Y0u0sYzXztpMDlhSm89yNVXK1nAGQpHqXo
#YJU3VhJnCjYwgz9bjUZSwuCD4BpzI6oQ9faG6GBBA7Sy2skePdJtWOaP2RIRLQpUwDDhi/WiJuKmYCbi2nn2EY5HISvWFExIaxrH
#SOWVbRgbnEvwuukcsa0bwh8YoB70nLRB+YMe0NsfABKATR5p/BkAhQFAK16dEFIExE5pLOR3pHHnH4smAAmVdx/gw87Jy0aU+JnZ
#bi6SolH1FbbqgV8sZnxC0qNnJrFEfkunG+SQNvbQT9Q6RTI9K9d8JC7RQqxGzsh5nC5SxJraM+KyCJUi7NXWiRI/TcqPuG5s2kwf
#GCanNPCqp36dwjo1CiLRgQ7hKXH/GU+iaOUMjY8ZUOL+2rsSzMES5SoUAnIYqplpkdczycHlGPDHyIOZKW4Fbk9GXfPgMYpHB2CZ
#sACF18wFmBi8UJBJk5tzexW12JBHxuVxG0q4LuKZktv2XDldTjq8GYwScUUmRTvoSWaJ0cWQlXrvEXcPO/+Ur+UTQfKPgsAbszac
#sGWexMYp6Qlzxh87RQu6uBONv9LXi87W2h5Kg/4y1gf+EjT/y1D9BZmh35W98O7cEK78Qusr5deqtnP66pa/Cm0LZypRyo/rg4Y9
#LhJOUwosQcFuaDCFz5A1UoTsLvpwIrUeDHPBrmWE3ZtmZH3u3+6LMMWZltNXlisDzU9E1blUheaASoDT7p3+z+omHtZjl0Ia+1Pn
#8hPVW+1fsQKJQ68xrG6iB9nGIbaetOXjccl8qsFAsdbKJVSzlrdS0siajuwyQcBtpQP6IblVZVa1r4zVE+vw5yVG7wEVWhQggP7p
#h8zDq/+S5sGoXi62az7h8xH8zYefW7IJKMA1aL7GPh9VpU/v8okO4XoHU/5R/jzv/B19MjXSLNybvAdP1oZd18sv0Rnvcxsnx/KL
#ezPXrhD88ornjysO8TG/M8PSnvsHuBDO/croxe7BEIaaao8wiQ5yl06DGgmXFiPOew2eu/3C4SRqYA4y3h7kQmwI8IW+RHEE+p53
#X07DTlz7vXk22tNeDhgHT1RejgnfD0uWW9ZTduiep7O1IeLYSYSs/64F6M5pTINPFvStxDA8Oko1f8tSVlb/gwCXnvKe7hF5WJ/x
#KiBQf3cM0kMi0K3pj/Fex4g95reIq/EGLVC3/HNsawvMWzzWoiBp7Jp15iS32NdXJADgoD9A4lWJ2pT+FLA/gJ6Av9GHH8vnk9UJ
#+fk/9iCSrMdjhqXvNK8Dn9lsxFNM2fJJlQqQfoeVHS1mHAcyGyBmw8IxXa0EJms5FYgCHMGUOk69nMGbjWWYqRNsVtODosuIOUKw
#JnBF9TACjEg1y3g8p1C7Q2XWpjqHLs+DMwZjo7hPHHjKvqC5aslHVa4eQHFnZk7lNglrRx/BG/Ao6/fp5Ow1i4z31KGMd7K02Wuj
#TSv2yZOIGMHiNDQpb+GC4KB7yCWJerMmGbUmD+Jgha9qVJXG9NufrrOEgpg9oXG9cHq1u5iVHEPwiE2w69lx2PPvlRFVFdIcOjIB
#Xlp36fFUIfnowfd48vPPiwCvt1OhNk/jzSzijF1tXJL3DVgBWp381W3fmGkXh0imF+/8udTVVbBNiu3ALfh+sAViqt5i6KuXw3x0
#1bWosBXzy+U7Bd08b2Xu7EuuJtwXlijymyAe3LY9mCcwRQr8aZacOzSIP7PA7sVMLVPUCNJClYb0R8Kdqzt5AXnnvvHVUl5d18jR
#Hh7kNfYijKCnYN6CMEo3V7GW4pK5dMB9lF2q41zHELG7bMR3x2WLtzTsvcdRcHkArODGuILQMcaqPZ3UHldKfRB/wfLDi5gjZoh7
#YmHaCawcxuU47bTmypaaKMcozCcNtH/SLUHE5j7Iaz4jRmmTNqnUnJyT1kk3KX3xTYfdj7N+Jc23twBMXJtmdti4ltZr759r7s26
#OzlV/7CdWC91grTzqlZt08W4AP5aWhRlNiaAUAyVHEzU0gL8StKgf1wlPC8paDnamVj5RTiW21Ae31QONR+74tAiY1zYklmLLHpW
#8i3w31bfhPpg31A7dxoMlCvoN7HNPYg9aNSgo1QtrPaoaPQ6LUqxtu7qTZ8YMNJvMwHibXyH5f8E4HHSuWfva7apne29Ht8u3kDX
#CLAal+jlofE4feXwKi/nAVGbqKk7rXE1pTY8TYKnO0CZzlqIthtDbi6ggoV2VDV7T2GgBq1E30MWQmpEAzOIeZk2+ueNBA86ca3w
#+2HJFP9Av4UjqxAmxZBHSiC95J79OGcTsTVv4fzG97QKZn4m4KKGDcSVdf3EYZLOeIR79Ul8NDmBmRqtbWo9/wmeaVV4Spk1TL5h
#JUNnyJmLbUgQ3HWyp3GB+kMhRCHlFFOau/0uoZgf8yEqEF+8q1ZOncq0cfDWuo3Z9IzczoY4LClrxrDNsR/BYlXVyPWcgquff0eX
#yWAkA/sQJvf2jtDiy+olRtJXwzw+1my5yVK0qG8x6q1kWrY8XnYixKFvWnKel2pJITNzZcaEGHG4J0x4uBpmXCSGYN+sF6PG0WLR
#Uc1olC/nsGhDDT1NvRITPzzvJySsttbY3qfVAZW7HFtu2vZTaLwWc2IH/uSDaX6Uh/nloCZ2F5gauNg6yRW/Sfaqe3qDj2Umljcs
#cAa+ar7JyJ9wzqAz7fCqHkjosyDrZ+YFrIKF5JZkiQaGkbFdVseB4mzYGgFM10kx1VlelTTLH1SXXJ2/XL1qWPDf4tB73dbwKskv
#JkHC+8NZf3UOGSa6J8ZI5NQRlF8IprbRK+ESVjb23H5PT9loY3q5Fwm4OEgW6WyyuwhQeFvTDbi95zPBjPu5SbCFbeRqCvFoTjyK
#6BtuLTsz/fAmaASXTz7eqsSnRiTEmgwZePH8QN+iRhx6nVhAmNLDuWNRNfH8DBGNhA7ECC2UFuC18HC6SJBwrSu+Ggjv0trTvXCq
#SGrX5lfa7chGnE3Aibc3zRzUntfPtKalcqX8ZmIJTLalytZZs3Fkx3S+3CWb+ZnD4Hsw1kF9FEq8D6ay8egdHUsYux2k2Pp46/29
#BlkfB8Z0oaGiwt5ukqfuDdOGTOCGkmeJcSXGMGNdm1L6b/NDMeU24NtXTw//23ieYv7mTXAPLp9+tF1JxuXv83bME8rEsvu0EiZ6
#2RbFDnFPPH3inOP2nZHrm3PsrWWG94v4F/Mm5btr/G1Um/SB9WbYCYywH4CkdWsRfckpbsg0Mj7Z1kwEhGERoL1Cm0Uv/cR+fHo7
#O5WowR1346xh2z5ltRGviWjoTKiRf5r7vTzuK0Kj53WcPns/1GnDF2Vq1hDM6Y7b9a5VpsDjWZiewKbUSLjOYvhxE8X+aRlFfQA8
#OAL77GmvcnlxaoORLBPTLrbKyWuxqgS+3QeJqbrymRNpORW52gctAAJAD+8+J5ma5Ak2EtkLgbm7a1qgjFCKemC9kGlzEFTjrfcc
#nP8e2O3miZJnUaQ1NzUE4CIk9srUsH8KPTCt7PkTRU/PfmGHM0ObSeaVw9a0FcGkiwd+RmNwZjPuXJaLKkT1fSrlou9ouKUn2Mp9
#efgwZXR7XR1ZvoQ8jh17qqQNyKETJCW3eXd4p/nvjclp7NBqGM/jC/b6YAf7/QN6trtAUdfTKkb54ZIX/uh9vKGm+/tmDd6rYk5X
#v2bHfqohYYQWolDQmiMbS2XEpJJd2mLktCtjA3TUjq1MWyc+pwB9iGhjpzxCT8sFdUhWNZ6Poi1PWfRJZz+L2A7AdbNtF1v5wo5n
#03ThgsnXsB3INzuwZyjk+x0yIOuBwU2zv/MKEVtJitnhDFx51LQ8sfrwDUGNR9ncQ3+mGZJjpzfL6GBtUA6Z3ZX3CyL+iwxf0uT8
#+dKiVJX5ERUwXvr8ZLp4Tv7TqF0hmp8wu4b7DQV1xRd/SEgFK01a5M9ZPoe3xSTau2CaVLWXRv0338WgUQnhHFQTTlmZWmuVR2D5
#So7d97eLOdmm1Ky7sros+osZNMK8rP+9MrOT+NlDm22B9NRg3mjxrVxTSJ8ODUdL3p9ufLx2LBolk3W8RME6iwHHXqghMDvfBlQv
#riFG4UxcF1y3GFCJOEYHYhmSRcbC3t6qM4xMUCqtNhyXzD8NqvEMaL257w86UFnwViw4hahBhBMeyP25yzIVYJfDiy6BuJbUYPaV
#Nqg41p6vnXH0UsvqWUiR4K5nSE8CmlXacY2REEwUoWUloA2/0MmsCxY6bUebreEblsZEONNSsIPKsKPLoPeklapXgJ2Msv09awaJ
#yu9VJlCyjutWt32fyNUmifKg92VN6s4qltdHYd9cFjEiTbqOk1gsL1HfQc2FKWX4QWUKc2ED6Ldj4iBcuOlX+Uz0x1xLKcDksniC
#uuWh/knrYurSWF424nt8oKwu8y5Vz1nr5AqynkkfhaMd1T8N0EJ50Q84qkZDhWp7NJWI6305aOJXhiDOhFdoA1276XVtVUs0Mx4K
#GtJzHyyRrdBknt9i/Im3QOxeJudAkrXJUhy6px/4GTy+9Jt3CZJlGBs+ypNnC+uJPxqsRyYv9vDJ8iAnXa8OwCzRUgKowfVmqqR/
#W7TpJaPZn7UnTcjS/tiwv7ehkl96o3AyQJ4+rOgMSmDG2O3WWBmwzHkEK+H7xtGfZ8SIjVEzukygqe1wnsNgnikRZXyXuj+pHpav
#Y2+uCJzCHD7usipW76XfhP8a9JhAAB9CbI0eo3QNbChqQWXG7+jLcK7WwuLq8aC7Ns5vGnP2hwCSjdbL8hls7Mk140hWpXsKRLhl
#igFAZgnpNu5Ns81pGOnXkrFzJuXE7M8aeMmisXJtKlRe+8cThz3ZnYcU7Ih1X9rdbsZCJiwdj8P5kX48kLcg+rOWyiZy1PkxQJzB
#Z4q4cHEsSMxFv7yVd9xFDsoK8MFYtQHLc6jDJODX11pxZi/PoGXhQt0T5hOMWLfizPE043TaHYAgxafl4XhfIaoqGK5cxIxLQfls
#MAkLR2b1eYWYEOrIAKqAAGbOtOG7lg2gX9TK+FaU1UmFpyVnM/7NBnaVBnF+OwW+dwlacFJiBPl8gdFzTsIUyL8xycjkFuNcGh6m
#TaVV1TkI4ccAGLqwCq4rSiUpVRAATsIfuCz8iCCDG1fBxprAmZK3iVwDpSUwRPF0sITNRIahjbjfW6wnFyREenezPlyfXAlHoZ2M
#GtNRy1fkoxhXsl6+uCy4Bx6AAfB2S44CPhDcC59hqhVXelEWCj0boL6iKQm2iZubFmV9jG0gWQvrRJLA1MsFeb20thY17VtMQyVZ
#0MeSKWMu68cb/+7iIW+71vPyYClbzOGVL3zARkDN6XR52WFUnRHLQvs0sSJFIrBBamPZWQwKtHmYWCiXNsRbAkHEVs6lAozqSwQd
#UIjFKSxPsFK44CAv0vBr5yAMb3rfQv2lDq1W7U/RchENJmVVQW/8EC/zcm/VtXgiFFu1XGgtvs1IJ2YY4aXSkWnYIBTBFRdkQIG2
#WEwopHckN0gYR6412clO1/Gzew6K6UPQdSMgSfubqkS/aHVcw+plbcRqBmmSlu1jnViwOFlM7XG3aNzEpCKZJimpZOFfnutKlpuq
#Mmnu1x+Z7awWnyKm7pJOvqGrC4yIAzgZJQV7x42QG3GLz49ye41I05I4KMRSqmIyP6xGYdxHI9KdkOlv9MgTeGFVJdbqQpZ7dbxz
#vEM77EI3I2P+CU6CoEq3lYCGVh8Vkmd5i8BINqPTcd+E3HVRn/cHrWppN6+HR8ivaOqvzmVu91d9YD9LsAFLcImGrOa/JwPjHHT7
#HcIDLF6gOKLllcT6VWupQrK0Mo+uYOis7f5gn4Mb/RtVG/vF6WSJS/AtIV/CNTWKkescIcGc/Pc9j/aKe+AeFOdpNOk+hbde9h4Z
#yB40fJoHAb5n20ea6wpDlzn5DlmRsCKhr31p3Jliqs2dDyMlnMBDKsC/ozWxv72vu9C+n/FKJ8RpPHaVAjCfdjXrmDJtyYLqo846
#50wSFR0cpAmW36YaNq2MkrfjfAikNWztaNICrhRRXj3Hdo1nSaXBn/sD2JGRM53IILJNE+srw8Kul3kT6IWqhAgXZDanq5fRIGrh
#gpQIDQtOMqQIVHMjTZ4E4u9+pNAF29CZ0Bqx5/rcCSzjBoJZDnbz7KawptCpklFCAX9GNGX2iNw5DzZTJvYNnFOVSZu2NAhiuKyY
#7ZXry2L1gntLVajtMgXrWZDaRSIhl+J/fNGnJAtQ7WHqjoRUAGwC3z7Q8CwWZz7685zoEoDjYrWM8dYSrz4G1ICR+1sKxSFg6eAr
#WrsLON5ToRbT+3Nc+EMU4uqWxgStJXlBg/jC5RJLrDGb2hwMIwtI2/duElWw2DCbChJVa2HyGI+hQ5SaIlTq074dKoxx277unYR1
#j6VYGSEH0mvHcrLgj93s5i/LsnxNH/crR2tSRuIEMx+RGIDzbCUZtCrVWdDj9Jki+2ualeyAFdb+csIwZtDKMXyQ2PteGfvIkdeY
#5lR9gijRUlC4joyBA3hwMuJEEvNyFHjOG8duROHBlimpAvLxB0gXkzdo9Igmz8yBgELlAwRGyp2cDKIXrYSCK3RZc2GGfHWp3efV
#zN8/3a+9ZD76WXT82QdNwl0YrLFdz0Qf3x2YztR9n2MKerDYrPxLcwrAAEw+xkD+T2YJ/Z/Cj9XGZ+AEXVkpsKHLDZ/G2MwZFmJq
#G7acqBJsRyr9Eb/qhYwUTy9Ir4eTMW8uQW9YkVFXoMyVCqbUFOZ/cjpeyCOjHIniVoCoAxgvXM6jf+3dOrSI/VR1w370mtvRFvEV
#EvWLhtboUFd5ENcaP8Ph62bqWGMsjO7jyWNJaRROHnlEaf+onThXl0PGRRYmwETJr3g7owqk2NiY14/5N24ABlBtmqFDVuRB3La/
#hsPT14cNcnDeLQKvcHZDBoX/M1rtRUDUyk5MiMZCQFZ50Ts0QIdCF9HY1jpYG07XZHkdSwaWNoHrRspBJdNhyeORsCjolsQ9R3Yf
#61ag8CxyPe5zCHBtL6SRcf0EiUUMO3wSk5ERyqM2waIeKKRXaaLmmR8xINVEFMhTahuiZEgTgHwKkfvvrOgiwGDsgYiXxICWFaQk
#rvqK7f2YtxHJxLRf1SGjY5ON2rDWcaDFgVMHXJ366gCsXWhXwpiCnvI/7U/ML2PBzKDIxw5g5vKyv9ZSljW3Ju0Yl/vXBB3sfX+N
#eg7AdyMn52+qjqQIa6408z4yU3iYS9iOMNNfyYvDCVSmey+U/cXtoPksF+gswsOdiB3uc3TjW8NpuyVfWYAFWBvIDtt+3k70JNHD
#vHY6tsnEbQbVcZBl4f6Cng9MuX/5Li7dzCfbnZ/xRCL6Hdq/Zcob+KNPmqb//AteA8RKENvSirY1JezX8bDog8q54N7In6MO33tn
#Gduhtq4coGP4N68+U1bWAPNSFztAKyrzuoEo7Ot5OGQwynIY89RY/d/pxQ2ttvIRF53tbUCRt0EQNFXtkW8/4G7H6h9SuQhzi9UM
#UN3Oil1QmbeQ2K4PtDtvgLhO+apr14liakLlDkJvbBDql4Qq7sDRXikwa47OD8Gj/g+57ztccgyXKc4lh6nWk8XqMcaMxhhOYTnY
#4jR6E9leW4g0nGQlcY1LLkHzanF0Ok4RwjeGQdhdSSBurxlolg8t6rVOfoliIJcCG3AfcCy2lVdlgKlSECeXYfOy0ddtn9fmcWim
#E+a3lOfn02Yb8Kp/bwsHMgl1LVsZhndV7oXs02ulM9Y9di0bAf+mT+tEqDX4pfJmlHM8zmeUrAAUxVMJtUtwWKMqOt63V59uU90f
#v0fB3+iqLuccES8RmwuhV0BXh03IIK2bocOCF4pS7HKViUBG36/ezLl/4BxZ0utdcJfs4JEd66Wz0aWpXQMB4OE7ZC0rNWaCMdz4
#mQbY6n3rzRylR0n314GXjN4WvuuMpRRV39lIuA/KGKtO5yLQCKZNRX9+qJYRYXUEqf+i4WOmaPo/plvjs2Jdy6VYtw0LuvADqFFk
#3Hzc4U5n/3Z0Dp5j6eCGIMeZSZF8YI2jXq0Z+A+8k94ZMGexaQQRuk+orG23AyHQ9R8Je5Vvu9dAWAFsWnDTKiC2/jeRhwsQIlSB
#aPeZO/JMMB6K0z7GDCouWzzFA+hi+3DZLW6p5LOBbOQjSIbsKWBZUMNzADXx9vWAK+dTtQe7GUvGMJoGXe2OQN82oPOJEZEMPZLk
#cRp1cpcrlelVGjLodQ+vARdvLouUsmqArA2OTGWj1hkgKiUKkP1y0gD6MBP/AzjUfOhqkC6Ocn7zkxSQNNPIVA+f6XXIAh2PFGqy
#SwhKnKwhnU1T3rhf37ywfLuj9sBtKBnC0ch+Wu8Nqri0SiEpbacdRjGbMBErDvOPae4ZKGJqjlQdmjIVBQRhaUQDV5R7m0EjDmTt
#WBZLYSKNfHIckTmiaUlq4512bjREwC0K0NFyXJvhyvCN1HkAFEUHSK9c/c5jYzP5ZBA0o8mDRY2808JhgajJmYCh4GTGnU88IOBp
#oQIDmSHHM6RZJkfaCwPFHqIi5D9JynxQUvantaeU2xCF7hAtWzX8VtHPqvKgLFrDUSqygJql8DHMwxLXa06a0PK1PGRcLF/0/3zr
#RjomR7a3s1c1b5UsOERToLWG5L0ELf+qM8/DzLmSSUzLkL7/3994jp6H75dFnRppret4LxMI68r1+yy6YRWaz6h6LLggOq5qCY4S
#oIpVwkwR3uR0FQiHlTgyG1XDS8CxR7OtisGIXRa81KsRK0H/fHU2VgXBvuPuCf6H7pCyZ9UD5KDHWkTSxSKMzVAABDXTevQebqGc
#kNImKjNmaPQRmuP4okQHyH5xS9OY9/4p2mGLnx0Y/FOJEABJ/bC0fUWyshUZKppW1HihYaJmXFzbgBT9oS+QL4BqLHSbJPZ+E42h
#x3rNbjZCU8Tj+ScWzhmFfSMEPUZtW2BQiGkRk32dsqWasGnglqD0moZ6x7a6apRDO+Da94cD+kWlgy2eYfCpfPNwoKJw8pEZqGHQ
#yEsRCsYtAhtnd8i5FHQ7pPR96VfmS5pCsEs0wf1zFEpWB0K/kJNn0/DdPytiwxyHkp1E4n1s4Hl/fu/i+18FvTuhmZypO+ZxtGec
#S+mTxliFBADsR01yT4m1HSFfK7H7wAJIPu9iYlLumiDtZDqUOmcUTIG+OSli9MaUIf7qJeo3gszpPzjxSakexODLGpk4LM4iJH/W
#1eCDtB5LrRL21LbJi/Ak6AFw66jqkBjNmcwCzpqtqQhWhbqCZZbcHVZjTrgZFVjfneoo9z7D92ldVIx54F3r+EqgxWeMSNSEyosp
#PR5ktjvVin7ixDkjDpM27v2PMPD7+4mhsYGpB4eGMd5bLJgKEc48ZyIwv/aRuDOa1lAI6lf9eDGF0Xp2Ld9O1eAWSVCSnDWKHYJP
#qSjQdYH+lplDyGYdzh86dEuKAEDlA+53MhA9A2tAf0IwvlStEbT1cYgulISGFgF/gA264ouNAaB9GPmwrKabQu7bIoOu2zlHxgTQ
#QQ8j7njWEoSvZ3+OqgLCCXOI+FYjbZYFeJpGk6Ye2RohaK7IcqAgzhtzCVKS0MGyf2FZdl2Du69adps1/QmSEBYMbCiuqFbixkeG
#7J2eppKgKt8Y6q54fiygoGYaetlsGoqy88SKphoZ6xWQPSQkdpA+4g6BFJIQhd0KP0QCVtXKVwbVmXx8SSAu/WonfBGWGYH+V9wL
#kdsq7rerTttumO+GwvNQmQucaEuASGl1AHgYwoMZrX2LiDXrNpzfRZ6eJ6kQSKgGfsHWQn1iNrkg33O09XOP4Dw6Fubs1GYGDqir
#uLFKWze/cyQFLQ8VT0r38KFdmGeqoz5kTOM7+kQzPQY9/uQz2Az0ZH25PVrNVB/EqqgEH9GO9ZojMEb4uSKDtL48MgCOUSezJMsV
#RkL1x+YfLvQfadB7kZB7eWlAjhVIQOgrrSDp2SUq/JrDw5Fa5WYnDjH2/S4tSplM3PuKkiUND5D8jwtMp+lRgP16DL1Ehl42Ewk8
#XBQ6WJYPHOjpTtVwPfCv5O4HyzP0b/vuYOuKCqWesI2i3gmkTivAJzwNTC0FdrI1pSoMkdSBZvCyzKZ9bYBzjEYG4m5tezVob1e9
#ZnTZYGpJnCcCrc4NakwT8c+tKGE0Ae1/12fmYLaQx6dmDvXFyJC4w2xLX7q6MmNKHoDTlPJaeTpLBDtkfESD0Gg8WPpYBUpAjxtS
#JDI7977wr/BfbWFbTTfPs53n7UpTTp0vfnAJhrBqZEYSQJOHhU8V6QL0eiDGRwHHDcM3ZJJ4vSvFJuKbYN+h3g5AD6HhiBEUYX4u
#cnUW+o1FTlAUEUToe57kxoLugY7+QINUMaCHRv7dTiR5WA49F6HTTxhJcMmvSfNM4yLe3J6iQaSFgz7Tg6og/SlElKdN/hX+WJUy
#3NyF7Ivd4ycuT5s5cNMMpoDQiTiMj2QsfqtPQdXB4H/jeKgQ7RI9F+FLcmIxa6BNZgnQY0e6lS42jNQUcT0AAERMoe1oz5dYqdLc
#QhCzjG28DNW5c6BVPY6AhVtDoKaHLEGb7eBl1gnf/M6oG2mamEo6mTR6qiXu2xU3y94hUKFtdZmnyyM4sPSArBzgi0LTt44SsKh1
#ScNqcrrY1zyf1R7caZtymU7HLXS+LpJFr1NfL2Tt2WTBz+Jz6h13sDZ0GXnC5MED+TVktl1mRWoDajo3umCDjsZci9gPwSLCtARW
#4Tgxk5Rep4Dm/Xl9f+8/Z3ndfH28uLX/vDn79DKhTHG4ukamfCVOPLw/XpsRanm2XggLO46SzrO9DebyNJ+N5lk6MhOcYt1hC5d4
#NoIQEK+k9H1/De+fHf55NeS1mxyZLHne5qFevkXbxRew9U8nx3KOgLwGNKLKV2OPza8N2dHpWQrlxMRj++yYwQ4azDkPr7KFrNyo
#hwJpNfjUP3XfLp3WJ+kAjERxBvxkZYXMWWUaHGVFrkwvk2E4uyO+Pxtz/Suc+vH8aL+zzggbBi4N832zCghHjm6uqmo5c5y08Lk9
#/oUAy7LqZ507ZYVKRuYrXkSdJdk31Ze379e/wG+b6lVLF1mSf6xNtR067s66oxjoqnaphZ3cou7EpmcAwaBO5s2qIxAI1iM/hYrx
#g++Z2DVusX2iVVtyW898bfLMCbA3s/WgrisDfjr4oGjj8MlGbMJdRTAHzAd7gUqVYH8dh/hDu1go4OGTJsMsPTrarf8MjWsk4rwK
#ZSbwJvtqZacJXmCNm5/BsVOXiNQsRdcf5RD/vvcnEFoJlCjE9J+vDLITthbYgrhDHttEO04LwA120QAH8cY4TsbShXlhcILDsKLs
#xq7rtuxbHhTRccO6rx9G+Z1eQ6NfvsWb2nFl+TZpCwJz6TYpUaeA3+PjiTlN/CGBmW56OV8Ogr5gpmJp5ch+MjqVlOsS0gG1s3tE
#FSOJwzN0rJ7i0g3yiFR4O4QoKl5mY4qb16KBBQL+gzNozDiyNXEyb1bNRP+eM28X3hAGbwHVjbbh1uqrBvKy3NXEhu8mvcky72DD
#Em+eJrvVX+ArdR+B4UpUPLUWVeKZ7XyiVLrdmp7rB2ZXkLLaypfuQ/aVooPonffUsm17ebm6Hymbn6JFIuPLoEPuwKb6qDN+lZYg
#31vOqDt2X79DY95jW2HbOSecsWW72nupGwoaJ7rHxbPAzdo9/lSUI+m0+xoKxw9rbNBzt2obW0z/J0c+GsB9HBsKDICxzBVLCdYU
#HIMFWhgFjXH2PpBeiA3DWgQkerqXsXUAFNOvonpQ6QIpFMYtD1EnZY1TaRZywzuWhrvc3zu0r/xe3WqJ3UJ4ULKK6uqbPlZOsCGl
#u7XQDGpQWMF15k7sVeIAdZqcTLURe5JFizbl4rO0/MRWrat6Fslqu3/rNoZYSRkhtce11Ar7kmqZHZXLuy/+oyTptE39ngb7N4rt
#v2gsL2U65dPvNipwA2/1p7P5Lceq2P/UATfRd54J8EpA2KtqLIAO9g8Apll+OpviSBnHh1SJUv9C1ABs+rmmC/ZSO+nGP7pFs3dH
#Kc+Ih3WYD00TipbrFUz6r7/ibUpOxK/Yl94/n5f46diIXIC74v0gNWB/DrlEOcrc5nYEKwNO5OQpV9c//pv0wqC6ZTNQfMmoyCTp
#+g8HaQTBSVeCQcSYQHJZuqghfxb0UKTFSjU2lZAA8YcYFoMWFbz0SKmk4Y4PaUPO460PwPYMxIvEOfJ+6MOkfMmElE0wHzRUquCB
#rpZJKyvoBOyvyy6HKlgwjYU/rXnTi1JUUDrA3mi+NYhfVu+fUw7ACiQ4UDMdCjUF2SgKtE5My1Elu2P9mFCKu238RI/PPpXNbxjl
#2w17nt/r4/f9qYOXR6/unYXX1q5FGu0Yv8+I3xeEpM4EFjxS2Okk7vc1IKZGr+njhF68PeUle07+OHvDIjqkR13ZnCqAi1amdk46
#JH9WWZydLuit5wby6XvBTMEPiDGXHuCbIIB/VEB0N+BnUiksPsYO8VJaBKBHJasHpd/UwD1erv9y4g5K2c0e+WU2vtRMmIWWkQyu
#QXtjdsbHjRoNEpxYUehYw7moV0rf60jqZijpXkv3GAnoO+8HtZPV0SEbD7ekIji6jKayZv8gKqgG4+/66KB2Bhcz+j/sii5MwgCa
#QaKpQFFJ8J9SuvbLEJAJHdFQI8D0JHoKruQeIQL2zptnCsN/o0FXrqNO4wLGEOJNM4jdWnezNP82EkMQbq6suVN3wdiHxn7fjNkX
#MXlHzxdceIq7Db5GyhuGM8RJulg2ZrkJqLf49ouqBb0hwCl8SWSe5KY9PN9OOfLs1FILfQOzLN8IjI4+DiGOex2Czg97AglFowTa
#RduAI+PAEwvfr08jnULNrVT0fc5+euW55OH2XVLaJ9jNCe0XYoF90BeISwNnc5Pq0HYXj1uXF+JxIqRlYiMjZ4zDFyDUnGT94+4/
#vt9Pf0+pVIl55HrLM/OuTZUAR9whmmtIaJ3gvGOkUgfVglhR1ITMyQvZRYcU+XUFbW3Odl68LSTIEozl2XbRc10ss2daBA8/3Hsa
#x8F94u1mkQyfCgNloL4lxQSdYfHEXcun1N5vbw4yS8ZH6Y/nvUrqgQbw7vdqgX0eR7+8EQw9W0aMkKjJ5uqDHdO9D7UuRIITU7oK
#Bcp2rwx55BjayEm6Amy8QD3F3TYXeTRR3TtyvHMJ70KSy8KIzAwspum5b5f+XfIWvrs/XOwH0sbNr49aAGdnEP0poK/Oi/2BkRdA
#wSOc3zR7QBG4Z5mD/5kSWGcDwR5s2v7hsNEg9GALUAqjUVF0aR1YMbboqoqEYNG6r2PvibRijeHcnCHgXJ5k324J8QxVS5g+44Y9
#J/qdMQZOmn0mR+G+GO4RdyPKMN0QnWnql2OISh2PzKuKUQQayymLZlNS8uaUBmDEU64XLTRXfHCWw1KueuNEXrL6YE5BhqLmnIUZ
#tUkTuQrIJT2lIsl0i6PRq6KOwURFjeTaY81VdmUfMq0yxQF5TRGt+/FOna/79Sjp+50P07QBD65FhFE+JKFz20/5T1wN7bDNEyyL
#0BM017ayE3NGHL9j5jhnFinXpif/uwb4AgnCChkH9LZjsngOBj9PO3CGsDK9uTx5AXwtAAGc4+MNKLvL7f15Nvbe77lB3pGuMPOK
#0Y7RzZvzotKFtckIvMN2H1VVjCCAK0TP+1E/bXJtP0bjvtLPG/vXtXC+Z/lm5sJ2SNv2zh8f9LPtyeqK8404Zb9uaTOHmjuLkKmT
#5f2wun1m6ZVXbkPSHWrmCTCQ1PaGXdhU1l2VcIDZ5Y/g98sdYV8QqBk3I85qJleVjCeb7OsDDpTLm9N/0bRUVjfnPrpk48SVHOlg
#s//2909U7choVVtASjayz9iUmCkALNan5avkvnkzel3LzguY2LbXjpnO5fUROoveend7hoq3yV996sJpQqGXRv+6NerWc1cdKm2C
#yc12J5RyKHKGBM377MYZqzlN4gkjbGlbdi6/dYGtgWh3NI/Jruavwvk0vX8/oNUPMj4ICqScOVqWw94zyZY9ZxZ9xo5uT9YxHzOu
#Z/Zn5+XEbWVXDpzKTMrJ7eN3mkGMx/qDuurDqgVNRm0eJUntSOrzzwkE6elu+YYKhD/rndT0VdK+m37fuR0XtsCZUBJdNeHuGfhu
#VUXn4n6TrbA0cpHj8DnZ6TY2I3VS9hBUTsmuYdpCPy+2xj9NBZi7CPACk83Caf6uWZCSP2pd3GI8RCVdEFgz2cogDDYyMbPCrqxr
#tuYC1NhhWvjiMZ2Vm63Aa6aYYzAOeXV4j+YJe8ZI7Ycum82dpql/0kUdKZs3LcBeV6iC7y5Wf6mH3y2gEiSQx5fzkzz/81Sn019Y
#f/6JdD8XGvG+1L3m59pcpMlfoLavKUyo6A4/4pd+X2kOMM/v/SfYY4/fyZqs8h//O4xivwoIgQE19wCQNx+ty1f49JzY6Bi6vKpt
#kdZ9Sxln0LuzAaelG6LfBbeAPX1hWVWA/TS5P4c++4A3jhJA1GwP8N4xPJoX5eF9sCYad9KuSJ5lrATBp0XM48Cby9E53tXUPz79
#BJU9ySrxgNtnGPIqRu+dMFru3jD/vET8ENkD2XB/e3u9XWM+XqEdlU49pjep8pqNPY/e/rG2FD3AxoxW8yuP2e0WCFfxenqh2j3E
#3va0bk87v/3daC8Y9zdVlRrwMXuWvU7IigBtv+CV2FJ0mh6r1pyiDtof3YLrEFQLXUm/Axfzz+C84T6ZzrUPvI6nad39vJBqk8zf
#e/pA4zmP5UF3IIfGYvu/Ji3eMLynS74134c9A+5z6BkF6CEDiufQgCPZjApVxccw7ST2MSOJItI5CWx4d8eiCYmDJuCcq/vR7T11
#3oLuuuQ6XnF8zfs2PX85SIJvvoZj8htCh0xfVvJ/GVBmFjA3skQdAaG2hBldnji2Ukc0abzdzUhg9ayeQ0YtzCprQeq2ArHCjvT3
#mz9PVffXx0jvqyEqKCUp+wg6ehxls+c8FZ+DR0Ias0S/n9Zb8Jt0zCyvWHSlLPvoPbWfo+70z5gj/OCn2DM/3RxuyWfQhhf6lVdy
#mVCVuQHbAiVY0JlGkWBJ9odXpPVZeE2D8i5p/vjCdN2XXcYV1s2pBYOL6hIXWGPV3kqKK1FQgdPsIMa8dIPlRR39Pnm48xYGmTwo
#OO8AeLPz/EiiXu8SQoUfCcksS1QXB+JMz1J4E4h0GmnXxPuewt0dQiR/1wONsErtl8Jm/XMGPSTPjyJzdXQOnWxKJJMsEhFOQ66p
#VSoFJCeTx+OqZvU6nN4dhkQ0C12wHBIonz8ammi+gaAQe22xiyGqhbljpjAWsmfYlSTLmITTlREaK3TSoV3U0cfCx08s7NQKAFEM
#1XTs6VdIunMKjTqKVI0+SZChoRT7d/0GNMh7pwYrOXUODJwqqc/XqXqZIJEqBKpmonjPQtu+kj1i+fYv0+CUBBR2sxykU3Ybvw3+
#3PCcPD0GiVfNZOYejE+nR9lPdO3j/7AVPXc5/tJ0Uu8qQ17XqcexB4SCoZBrN1hBa6MQKKWa1Y1IiDWLrzXse1Y3KdZWpW9UZL6z
#7PNfuc4pRmCFYZh5oEKlYkJZLhjjC5IQq8WwbKMV2TCs82Z37Z4vtI1Lbz0xzAMjRq8q0nY/3W/ye2M5sP6bcsogpiVZBadVWrQV
#68XPFlIx2Cg5H8U0QRzRVMUxnCvToiiKL9ZRqgrjEIeNjnGU1c4xTpzHOFJ9+iEWPmuu911KrhI1SNciC8PWZdrFCAfKMVjkE5NA
#jUez95WbYMGRXKVKsWoWjpv1HV4Yoe8965DBDkimhQY64t9u1ZjTgU3DDBMpSvgY6h7M0jTbFE4StFT9by564nwwKQ9ihIxKIXLS
#+jDprg6tXSb5hO2bTTWori5+BMMnbBDxxUBnJoPtrAN/ZIbNvcHbuI2nqtc4w/reVgTCjYjXXxMPh8idLb5FHfeP8FcX77cZ8nLC
#Qe5rFu+a1qdauz7sDURHzu7vQ4G52h+POBBeY82dzs7B752eWDUO5/Z8S9m5AaIsvXBX8YcI8I555x4K7ArnYlu/MgAoLB0gUBqo
#LkD7MEUr+giu2ADJEkLo5vSrtId3du/H3x960U9ib+6zKXSInzLv4VYUJm2BI/QLxRTspdrQRbfroR7x0RtbwesF22ifDd06Fual
#kUvpX9Bb5dbw9NU9g9kbvNvd4zSmDzExcytlLG5Q9W3Chjh5bB8HJKV3xnN3ywVMxrfCE4rHEpt1dC7hAhJ94jeaEmj8NEdIFmpg
#jguwKiD6PMDjC9AKSrZVKCsKIYdmTso7xpnnqeup66hrZRaIwDvYtVziV6zRDDUJRD4fMXGdNItsxxrrBoG40otOadKsU74dHU+R
#Cqb6xZSESaezaeetqPdWfRZqQbKiooboAXB8RYdMb5/4+wBzcp/TXIAdFeUG+P8xyfP/Jv8L/7exhaG1kyGtg6mLscV/136z/7/R
#fv/f+d/7v5mYmVgZ/if/NyMzI+P/7//+P5H/4f8mKweA+69qgPOfvuL/o//bHbtLBSfY/b/03zSIEFC7LKOM0EHe/037HebyX9pv
#GvAwSGxqRdTGpxBHbn/P3237g2mBekeAR8ZZEZWkycnfv/r+U4gDFmsPV1GlpXdZfrilMUMgo3qWcJANuKp6p6hO2auFnNdOcqFj
#kmia76cqyOW2uZ839O4T9ICRpjuIGJ9E6eduvz+fl82zaR9gH8P+c2pUJgpkXK0EJspg4vEFi7/+uZq3PyDPYQnDaHmY+HhEShgM
#XgykpMgGQOJTNgxUZ9/6/nzaaG5OUTlGdl6aaOGvWsVaRZPw15TTtKeq5VZ0qVtC37f+Q85mhxL/zpNhv8O5WYKrbags4nQunHXG
#SKEF/O/X11tN5gDfAzLJQZHMcWVIlqbmtd8f8C5Kq7an+wbSChAb81Ja/Ndj1tzRhB8I06RSiLSDMPSAD+xemcSkCZIMmUSTRJL/
#VBLJxj9lVfVs+TLxdmHLlNtsIVhtBPkNndVkNrKvA2ASBw5/1WdmSfQXcQk6kKjIDLLSBRcpa2PbZOpkrcnVMN65oVbw3L/bLDZn
#6zLzgNCOn5hONZYzbcV1SZOi+KMd+DL+rlDuUtF1rACRQu8nJ9n2XXhniuXNziTOnTeKCBEikvu/1rmLJG0B/tT3AdXDneavqam4
#PLpUE6WRRkmHLAYDkEH7qMp5ieiKxPdW/ZXuYSbjvXijwxCWqIS4uZ6tv6WsiNm1W25NzkQS4qKshOjmubqvtjxPeKTz9VzxmiQK
#IioKKizmX67XKSQD0H6acNFOhfz8fmmK4x9mgWasQWEekUKZcBuhcCdVBNZMgswWgR0X5MPWOsJbHpLhQuF6kaRiVPvfLQgG4cYe
#CK9e58WBt2UiTVaOXG01FTgVEYG/Yn+ihV58FMHily8B4VLnybRirEOAX9AvsFR5FVLoagAoxItNMFF3bsH4Nnci5jm6T1UmETr/
#+dBwROADOfwM1kvpBkIQFfHvx5keUCYMfl/gw+IRxmO17kesmQSbdQLn83p4QN71iKMZ03D28EitmJwuaC4zrkXBHmYpshvHOHje
#vB7s7VjbDKcbax7UpBpPU2q9W3cCSoqBGb11oLHn9p0zns9qwfLteRuJrHCk35uu3mvn9Kc3vos3Z7jzoVm3UJknaITIAOz0sYUK
#ueenWNy5o8WF17Y2UcHSBdC7XKrNzU8pLc0BRn4xLinorJ1nMnY5SRIo0V/vmZ+HzpWGZq3c/SPtJGVFH6AMgHOq+L8Z/p4w6N/L
#OV9tn+feNl5cvSekBOdvErvzdPHtu/qubbCA9hw27TN09i2owbMPhMi8tIzSSUax1IHPy4qodLZM9HkPETMIYWETXb5jVb3juek2
#7sciP+AezMKJo23QBaO63Jo/UKS3KwJL4ObwRyo4ht9g/gy4JbJRSAVYq9KXik3QQ8z9Tdf0SL+hGhtWSsnuW1q82XMbwTuU3c7E
#w0rqc8v76BUAch5pXN2X9Nr6+9bZc4EpnvqQpZkDbo7AtywA18xR26PVn92Zzv3NaBi6/2xAYATrIu7gJdcl4sEhL9GhrKbLK11a
#MRAwsNKwBVQjWyEIKWN/jDnQWUTZZlNRtMBYSpwY8ETKwvI58uPOapsE76fCceB6dKc7ODawH3+Rjv4Um74QvE7OZ5mCsgC4zW5Q
#hAyAT5H39HUZNvT1+ghlRIV4qUpL4lT0BDOu02dQqRlocJLI+xpiduotmchLRYI7VAD0Qsmic6F8b2kFgUcY7dc+kYLvmoNRxBhS
#ZInVSjZmAZ76BAaikqnsHLhwu9sKKxmtN9y9WANAkUTYZd7FxbtHMC6m3xiOO/Uv9b8RhMwsBEHenLNzJnBoiMFgTJFMW4XabLtK
#fbxcfV3FuZbGl4cJu4wbaXlneLAkdVvwx1EzaVFK2nLVk/juZQL4LvGGbe2DGrnrS5Ngex2xkr/U1hb/fA6DaUVkshyWk+imWU55
#0ZvCuvzz8OdzBoPwQSARwahLp8PYwSiK7ohwTNF3CAOS+PHAcY17+5ZgiBAoZFn5ancwJMekYv/nmq8NgVSb0EfUQiolNQnOcCkR
#MKqIysjpZRHZ8In0SmKgj9ZWz5h4MooLFe5a+JIrAIkpjAQcUlvkYuPEcTmkAZXk8+gnBHTIF1VoLvZz/m+rbVdGjCJAI0/Dzcp8
#bd8gR+CjVMIGqXsu1yvSipMVfWzG7YdhsR5C2MbRFrhvGJ1lhGN084fQTZw+I60Ln2VoXXiLQe+eCOZWUfe4lslWS+6LnqoPse6P
#iLWP/FXfv1HY6ZWCNW1kQvntpS0IyDS2w3zjTmL12Zcodv+knB0eWlcnq0x/83CmNQ/hHRsrNWwbYNZ27uKJKjvAJJxBdPPrcGr4
#AMDAocLa+PbX4TRhH+WRyphzNzVTH29eW85aSyntehyc+TxXXE0W6oYqYfH09qUzxWTUweNs9g++Z1m9WzpCbxn+J9cdGH4KdVTQ
#AQhiCgzDYEYKNgtBgS6EmhASWlpVGB1KqplQlmjWmP+0HFHNSlLoxHCaGa7IWi6oS6qeZRd9iy1Wk/EIHVb5ofoZ0bD0SEQY+rJO
#/W6VyI7m8cbCccdRnpk4+XyYK+UTvYBxTj8Q8IdoEBR7EwjIRf9nI/Dwfe8PmCOOiwIFXqQq+ocliapad2CN6bGnbIqRl/oCF4UB
#7AjsevX768pJ5Bf8XbrUVU+/W29bDz2aHCBd1WGPcCBqEetQmWGI2h49/95sWc7yz9Q/NZUkh2Yig3/vrOvi1f9axMHpCChlP8x+
#s4E9dAtZsuNsfAZWq2cmbcXKieOG5rTMm0PNvuNR8lmZy+4dK4FpohUr1i8qWVL02P84x41k53HwFPYY6lbZQwf55uyC9yfzctOu
#C7JS5QPjxQUSbZgixWbh9dlsXt3SiLdtzKMF2D4bWmEaffMeJXC5vVIdkfkfRU3kgiupB5FXZ72zKBvBif070Fz8o+zvKQZVO9UI
#jqOnPLFYs6/KphggtKuW2wEKBrnGA7OVO7RKtb82AcmVNyRTQiU7r12MSU0l1NVJtvzGeELCx4E0+vFSkOFTu6tN4U+iJOIufNGJ
#RFaFgiFQBUUURRIzxgulpMUWIXNmOkp3djICbjw3IslwF4qJM9Uk9cGYEgqqTRDc9PMjW2MNRjunMwavKWcQ7Vx2Tvf9NbGYnZEP
#XFDGiWx65UJuV2F76FULurxK3lrwgvHwKaBAhKht8t+iERze8XtWx9fIGUQxx8xbLuZLwJWRPxOf61Q/wvvViDPKR1HJ2dq/HcW2
#nsiDM+S+JnV+XBe4Xh4EljmThEd387yNcYm6m/YLNNUNYu/3OY4f2j6j04uazqIHQqjZqzwMoFBotKI5cCQTHUs0yhQynIyK/T5f
#/1B9zuqLpgoDLxKhEQJsSaYF8pESrYxd5Sjc+BlXzsXAUIVvyMqJh4XZyYdOFBWE1PqKr5KdOnewKAXEoG1d5kXrpBMClQuCuaFF
#ECRRbAojiAkdnSRJhmrAiYx9fDFAEUnEhqsDaAU1goMRDsfqEXQWjDFSI4yk9pUjAQ4WgGGNDbdCGWA0EUIFgtgbr5aBPWSDkNlc
#cZVH0K2dXUM8qeVgMM0x2vcjsat4u6c0ZUASRAbIOqkTxjLIEXASJUKzIo1J7ylF/RlsxyXjiba0s6wsLLtJcPi+mRwQ5AleN4gg
#Agkg/usxQxAH+q8XtJecNtzWhFZbuJoKTpDEIqetpY9Z5s9nPJrDh8b+IcgUx4+JCghCJRxoRbJxnRe26RhQthOzkNfhlGMu+f5I
#Y2MyCk6V9lC7gUDrheAB92lTyIVs9EGytKsJCL6gLDFPltyG6ZOb3dqNUwaiMy4JP9rJo8MjGYWOLvW7T0JczBp7BKJ6MBoqDE30
#VHTdHzQRffsPsjoOrhunuCNRCnmDXv0xQgZuxPkvis1TpPAlwxLV8/6jAOLIfSUc54d59UVhCT4kgkKQgBwQCJRi0B39ZAv5pbDO
#yv/JWwWihcrk5RhCLHI7d1H5Yp053drcbKGvXYBd6K0N5dvZVXd5hnZ5+YcyKZbsqvwHbbcbYwdIz9HTOghF/T0pFYpcNVM0Mqdi
#/8ppMdrl/tbQMBgV56tMjWAQajb3Nzvy7TOoJydQOodvGNfmwtV+M3QyH+BLwB4Bd9pRQuLZDptg5xEgEDYwIhhrrPjDjaAFE/dR
#jSS88ZBYiEThJj5ecTJINK6rqawEybMAwABY5IciAx3lJ0kCYfpeBlI2kbka4n9i672N9BVA0akjcXCCDKk0VuNDIIWvOWU/twKT
#AhYgQblRDyMZyEBng6GKfifOAAhvos85ibCxGxXnWTt+eCD7j3BQg7nAWh4QsyHMHz6zXw4iMZZ8ybRIdlzAsTgKwFM0N0AFgoFO
#dD5pm0vRGtZ7e2WqZk6MAvQfOM+6fSI1IwSy9ou8c2z0aYUJoVq5lUS+HRtyfdqeEVwYJrs/5Zy3EEbgP8M4XuSLenyajXiGP35o
#Bu+aP2BBN6Bj/RUBfJzvZ1gEAqQGsL7bLmNCwYCNbhBL1hPkQ0nlm2j+T2dEoIR8YQd3hYtVFyzcIu4ln/MBFzZdMX6zuI23jbth
#GYYm+TyApoUaRJs+5ge5ykpPfgQsQa9Oyp1EuyYGMt5zbaof+HV8gX8AGm24Xs+pv0sA1T8OvwwA+nsse2x+Vr3mfLa5fPZvz49L
#wWUP8nS8nPAQ/bP9A74xdAK3ExRik7Y4o9uJvr997OI6/7Zt+T2NRovpcZ3n0pnh0h3mCffcjxvmZggXzf0H0zmhU6vn1wuGOBwO
#B6awdtO9QaCQaIa1lOU4bsDRvVHIxKrdI5Sqk6hkU3E6HlEplOSKlVKwjFoux1esnRb15T5mYfM6LFdp/9Gkvw3Qa+m+9jT5vrTt
#+ViH5ex6Wm1z+2zqMBrNlxc1J8RfLBYKxxEyk8kobjS2RsISx+pwGmvMjADbAb0/HtEnl1klDDbUi4Yj0cK9lf9UmE72N+kFCpVE
#piAcekkImAFDVoChYnVQP20zR+l9TbKkRNEpChP8dELVo8Wr+rsajJr3Z0MHVLWkQfYBgih7MU58mBEK8g44w1aggVcj6Xp2h+JX
#RV01azlzo7zRNYp5vkpKOsZmXRZQFQPPaskCYlbsZZzxBafgVHV5fpqcIMaTFUqe6x5sT1ZdFVFX8WZ+ldDItIS6Mi0qAXQmigEX
#3BO5LczJQ1A+ByeLIlcMGRSDREw3mhaWxuNtC+rk6yJxqy5rQMRPa6A4gXQyxAidr+O16FjcVagZfh93dUYFrWg6brCCBQ9I8jcQ
#XCKzNvPZQBOQNgHWIyCk+IHap/FE6qxJUz0XrEqjl+qSFTsf9LdohzAb5yX0bURigsmOpROtG5PoH1Hp0lw1ReK/Z/CZlTbsNXwE
#h28aO43zdkU+GRXmMiKVQqq9QWcgo09UHIT4GfM00w9JjSx3IzaAnxHrGkoudDmFHU6HxMiJQ6rl2UayDpWR9uVbIMYsKShYLa3A
#IsDNkdSTmRMnr7N3LyFA02qyaJrf0EWKrRUuJqpYVM2kctsdIYo3q86WrjsgoWuxeUxMvqgN+HwvXd9Epz4vrHUf7Hme30WvcXP2
#1WTtStJYO3+qIznSwNGCQ7cEJPdB50ghyuLodtdfq2XVP5nNqOebgKmVIJVJ9QM4oynoi8DMyjEqfzrgnlBpLFLTqncyMr1qsHoM
#x1b0xyqs1+9YOh0hbwiNex/K5r8pTalmEx9GRlVFcwBYIwYau6R1W7xDMePGlTo1sKEXqNQvBCuvjLEUsC73LO5bsS9t+foMTUPn
#uJYpGI9hJ1M/Y0eHlAZliM6YU81sFxP3abiZR8zysGrGqE0tYvG3Jbex1r8GH+rhc/gHBtxNPkahDmkLVWfYyRot2u5e4Jo/fIUB
#cWuewyj/lgbUjNYQ/5NawGhfUVG3ngh2akSvlYyoj0btAzi2LsBgWfmSSM/8eWbyxZr/btv+VZ3LWTLprPdy4uuJnEFTfx2+QLHK
#S4NW3bTVAWfvqghdtlwv3pqdrk2j73CmjG0t/2F0pSmKj3pYMKgEiIg+cDuGmQ7JFygtptegutT1LB03xoKBgMlWlWGRE18WWsGE
#NmLzbF3I0MJCkFVzlcHRfVFFg6mEL0aE1ospy00Jv2nePoWzD3iC+oNIeqbdrq2ktX9qkBy79FABCdE0P9SqpKuQ9a2Zvd82LjK/
#cR8DplWv/6xO1QsKZPhzgU2lpK51pJlDjIVnPtGQDuRnvgaDc9moXtm4cd/8v9j567Aot/ZhGKZEwgCkxKKZgaElBIYO6e5ygAGG
#mIGZoaQFlA5BBREJpUtCUFBAOhRQQhoJlVBEQEqB7xrafe/79zzP9z3H+8/7sY/tta4V51rr7PNc6xpTWsV+tJqR/VDnCV9euvXq
#5OEzQQRs86tqBJbj2nz09Ymy5JsWFvaggUsyRq0J17UbWCNeJoimGBc+7P3eaOAntjhoJfn03nI2J4XK4GkWZ2yy+LNzCnIs7byx
#3FncIOf50i+9FOZ1cyLQKqGLKnotgtjJZLcnr8u+wToT+iQGnz1a76T2yRkjek/qEHPu6awg9NkHjpV2GrP7XEmCYcg8od86CGXO
#k36z1LeDjS1uMm0LfN1gL+cqQVFCvF+VZjT+GAodcnwZznVR6Xy35XclaHcPGcawSDDgMZF4UJ7EWJIF/NfbAIHivvPraCoLtg7C
#aMjv682DPUZ3HjuRYLJbxWF9hQEhmXUK4unU+I+jtb6Zv3lQRGCR8zXEhDFADGH4qp7mJ33rfH3HKd9ckuLyhs52jbM+TYGKb0xG
#fUslgvXqzzQU2GZTPJ/z+WNth+bkXRz5TBPtessjp1Gi8ubMC5tMIQzLN8ewwC6s9ykiHherm2ndKlo/rOB8pq2s0zTvlUOIiz1S
#w37m6KbJ7NyXQN2lzC+pYl7aUPHaCumwrXEfKvNl/gZer894pR+7HT2+Ur/52QlFxubo1mXa1c/pcgfqKNf+649nnke4gdC7cHex
#hhs57ISbkeoZyRN6wf29btZh3WeM+iJj3KoC75htZkldDxTtD36+Rmgl7jjGIaSMH5rUl7D63Yu8/47y62GrCv++wWKLPIimiAps
#8MMZff3i/HOeLipGr3/1zXmqDW/wjNBXXdObeTD1kFBef5lDX/PTYvV60rfz/e/6ZMqwdRybRq8gfjpa2dfcpGanK6T1tUepRsdq
#Qs5A+gbv3nX8xV9ip5BRPemXquI0S/3G9ZXnI88zf9jGVVglSoyCTyKQVn0D6uoUPEOWcSfJNWcFB9brPor22DGna8ALOUvKrDpY
#M5cCMx/e77C7Bh2F/Fp97eskwSncWPKq6GJy1kXwyLkGt4Z4VInuky3uez5JJUzWKsxbydF/dEzc2bQYrjcJ2bcreCz/kNOvfTtU
#bjNo11yXYvbIRWjh02SAXLmDFx9f4Q+9p9YXdirrreEChaOnuSQ9Lj58l9JxBRpxz5txkDKVd6vnsub86/yZrfzCuSJXrL/TZo0R
#9lX+3XH6RZZN3Qeb/VuEm9aGo20CYaih83U1HzVABSvK1K3f88hMbYPoyEXyt1kY6EhrWvqrjO53+cYEMm8aRUPsSmsWvPuzKQYn
#XfRn1txS+7Xyun9opsmuGOjN5r6ZJ38mN9COaRpvudPmKsSzVjrGlvz7ZFB6QHk5dzKY6tLNqakm0uT0W7W0i6ZMcVJz1UGdBqGX
#lUoEB4jHpk6MMdcIEC2c75BWYhW7EtJdrwMHvQ3g+/nQrDjPqqHnxUkdkdkgz4tGaGHkbfOGty4VZo/xxPK4Wwq1PJ030nQCMvPE
#fcMGylgHEmZW6Ku89Z2hEY2FEc6L6d+M57ofS8l2dwuOOW532/1gOPXm5PBZb/cr6elO37K0EaI3mN9o2j8m4mxpYU2YueUdzcrx
#tdZFfedccmcaGaWsKX6mhLDklw96CMiwBbSz8c2ihui37m5qys+fQVzMzFbg7PWBHRubV/nUKVOfJcgCJWcYXkEsUiC0waFLNBWu
#3wQJmBS7WpZcT/9gKBblyo85OZbZ+UfnXCCf4UTUL6uyqgHTuOraDFKn1bRfaI7FDIhfLpFnvne0oPXN8OF3yhejN+XVVRzs9OxZ
#fjCc3Y5eiRnnpHopD3vz+01fQbSZ1Nq0XvG7YbKvEoJJ8w8cUMZoLEcFYXJdXXWvNmM5FRnvkjHvWcmShUgQT8nvcbYBm15W+nax
#MsdS1fU/GH3nvMW4h+k8JwaKFhVoEkYuVtz6wmdVeu+dTrI+mps9vBBTMPHV8N5dMqZKao2LnTVzczwKgaS8tXi6Af60jjy2GhGp
#YAsw482Q2z1R2e6qJYwK2gpNpDdIDS/ikb2qLEZBy6YWl0htWr4Mz1pyBbg5eZriM3FF5YLnTZ4MTLzh4JRXUQhUFhPPfT0Dt3eP
#xmh4mDjMBT50rXLIZlX/VP0l79nvAYvvASLZVWdP9NbmTZLff6l5mjavoj0aOvvGr0zKpfZ0kL5HPQzbWL0iRdMhWfAm2wgsRudH
#K/tFNq1b9nTvAM0VOg+28fmlC5dOiJMlNwm76DLEW88ZTlXVrzexC1Msl3Reaw7SCy2lSdJO2njN7q1uqy62mPEid7jxQz3VQ4Jn
#Gc9ThF/xjzlMeHht6G+caKyX7+C5LDcQiyIo0AusYxQu0HyXYetCRnaGjibX32LqhQYHvlIs11d2VhedZaM8ynvZBO0qzmWO6Bax
#FuKmIC5Ft8meT5b9haCrGj9vdtMUMwgKfDhbn49ECFNajD4wGHqDVThPL/+WLE8zRaLhVsJ3LvVrZlaUlaRzecRImequHfFfth7G
#lhMLuj86t073zr6X5xmEfbhyxd/Ts9ko1dTp5P1MPYY8DjGW9QsO7A+JNRW+Nmn4hg9OfmOWtDQfTSeLwisS8DZpGgSPJYF7X9le
#CrhkpdTiM3G15YrAPdHMpzn9hT1cq3kLelkhpte/GrzDd/+G1vlQSFJjiKoJGmHqUVog3P7QojObdmu+UK+vQOzJlcuPXOY1HTZK
#c1SigpbT+Nhpmxlp6SLkhZnf33ANLdJaIubTFrp8WvfZRI/64DtNXjXpqxbQ5CHeQesHs76LwY+ie5E7bUGC50sjNR6V17OOufER
#ecQRxdyJf0bXf+91LOnQc06uBwrMHot0WwvZPcltLUHPlL8tfpUKk68NlX9rqOMkWMHNk04UNMmX4jMY4d4Ra7FIa/7hmWZ4RaqN
#I0/JuQ0Y0bkVrdOiXXWNA0K8JJTwiccDou54qefCtumJshZ/P3jzuSK4aShAHTbMH4vkXEy4Kr909nl9OkfLDOYnhuddm9mCoVnR
#jBrHTx9X/IHm2yKm48qpmEvF7wq26r2ixe1GLyLfdDFYPqF0ubtQ31N+8lbEzsrWd90v5wbzPFzOPRzOO23kJL+c97L32peRSt6y
#jWUeQjD4tLJy2eKo5GRh+Lf6KW1oQBPdn95WVTWfxNjW/PUqxpepp1gwGpiki7GV/p1u0aknx/IsaDqj0uOELktRCVOdlV3++QvB
#Gq1HhFQjJpY6FeNM4hzqxs8UUSfkdbMsVtb62VbCi7vMnGUjF8Q6L39E0lue9w+Dj+Tlij/mHyEXcxshnP9ABI64wCBZUV7+WLJE
#I71aV1T/2rmCHo3G05H3MqpvVQ+RVDgqbYopLn/zXL0bsdIzZSt/0/DMXWjXmQ1hgjVfW+eou84VLTSNjn8gljqpZk4YPZlXxNrh
#W6a6YkLd6fUvCXtHhzfijKvuDA9VXBfN86RRKj1xCs5bnqG2wfhhK7ER3qR4pb3DQ1kg6sEUVbn/owfNSXfNvyYQ+l1DJglvnGT1
#uXg6NMuxnC28gyxs9fx3r0XYDSIaFTLfNrnJn6aryquBC8WTlukdxShNDxtrUYEy/MROu21xX4w3/rXHxXdEo+7jTc2EbKCaZ3su
#vW+MMZ0uIgt78IlKxXKwpDhV19wwBf3qCVi35evF5SHnYvRdST1zufEYzN342BTvHJgi+v3Vq2rLLkDon6O9RBzY8cpCny3nvp5h
#eKdE6ZgdF0m+6FI9JoaDUEOpw09i7oRs9zeCmLKF5hu+tIPnfSL8OyIENHlHqcIYk1MvnapmqDVgu8Ca78Fa5NF17muKI2IjP+t2
#9qKVakkN20+d604Pz59qcaOO8YxOc4TW+LEaDf2UR1++G3TS4RWXwa2x122+4b7xVrX8fPX+dDtnzAqLitzmyzlfTMBSayXUotfl
#DDXnZrLoX98ipo94Hfj+vYAKcrAPIcJbYorXfKvxi/ga1uHqEOnNk03xr8PHlOcuGJz6vU4iOSCX4eprxFFb8Ghc2z7tzJnH50CP
#lhprKWjSCh22vyt28ViiU1Fn+RQXMC/PUS7mfHVYNKC5jGV+co3FSJPOODbl7n2bUyFxDR9efaEMsbv68Ot2cmEdyLZfvdMDb/ty
#mqJS/5evqRCQ/dXVtx+XH/5o+XnvknjR2uoC5R/PqdsNhaaZhsXb2uajSZunrN8ZdG7k11VPfjhnkyX71NLgcVoa71nejlgUyzAL
#C1tBLhmlqVL4SoH0ibpwry+3Tz+4tnOZ5yOmbv5O+mJc8NmIiPDHDVwms6AcunWh0c6u8cYHqmf7J+FFMhSstT/Rp9tPUC75muBH
#zn6aRQxefVeiWl1Fyyxyp6S+pdnRoVPGzc0+hNtC+IKEy+/wxbw58jp7v6HuxUi8z0h0xpOYoCshazrDnvYgi2tUje4Yl9PWHQ76
#+XqSkt0pxmZUOjpLHqMtI0MJlKxu8vc5HjM/s4l0OQ9TOXUK44pGC+JVfehpgV7pYJLLNPttOuo22TKuxU+hHn+vX+XFVH67+2cP
#lYHNJoFL37E6zxgdfD9t5oCbg0jdFyysYl8Y0l8OmtcSXWz+0tgFl07S+qk1/pGrYgFlzRZrrXXh6iXTt7aGQT8mWVtTPi9IUI+c
#EdwZqsGzqqV+WlsharD+Z+DTTOEszSwFVsv2aVS7cRNFKQvLvZKEBxSfdMg3+iqMx/0Ihn8MJv54th25eopvqFssUqh85dek1s8q
#Z6Gk+U9P6qjkb8jGg5At0x1LCht3/7AZv2ledqi/zyvCe7t3Qt7JzS/qcixvB10bVdbvlvgz79y7Cb9SZg/54Oo+q9qc+N0qtPT5
#S1MsgZntndZPz0GRQpAWPIjlfV6d3psNQ7wbq2SfGr2EYK0PPkfYkGZ35Qd24Ept7c+XNe7/FtQLYFiTd4+7/LzIqAZimcAbRwN5
#bHiOY6PUJ07AI2DoJlcwPm8Vx03px8KlSU5Mpm3Cr0bfnDIjsM5CEVKksvyYbQm1S7oqWVTD5v72BLNBiXSrJ7ffhKkgOGHkGmFm
#ONn6bPqKbRg+XokoA57d5EIc6yTHuU0RmuURRSH3M3iq5z5iaz5L+xnwe2dzR2vzO3RCb2SupxukKSwwpZ2RYHmXqHCONPdP5doJ
#o+oby8XpYWtgsSuPn1NLafmz1n02/4k374g/4EZ2g8hN34Ng0Kw4UKnmXoJ82qWrjMlPTsdG4Buf+TnGt4rYWLC2dOeuJq/zFhgu
#0Pte+0yFoNuNgTl5XmixnL2NbZrKJ4yYZKApUqIiWRYV1+GmUcd6q+bp7TDhngAzdo71wiJ6Vaax+WYL7nHfmY7Omt/ZM9zUExJT
#zrJtY3o0xtK0aSf0Pc1G2Sr8ivjRL78QLXw/8zCQ4A6DqsUvegPWLMr33ezyMr6tb8YuKn3mMpcWJ2/dmKYrveD1yEyphmN8In9L
#K6b7ioQje5PoWvPPzRa7St7fLfm0ST/vfDG7Oa6mWPNV8fVLXRECDX88fILHoo/MTaVJt3r6mSF4PlivCZFvs1JdvRs/ngw3LnuT
#yZKTUSxW8U8l3+7yoCOYZLrhzBZXyL3Ms6ZrfhYR9J1Z6yyF9jDp4sD0lz/hyM+m+sFG37RMX3Rf4uRnHLswU+KdPqDlKJgoEkxh
#WZaq95Uug53R1bJsXXo88S4+4bOgkaoTtk0yYDf9lRvQmQqGAgfypw5Erxoc/S9yXjxrREBzT9neq54oIar9K9XwPQuQ14KerLU8
#3kOrRu9L0Eerdt8WDF0Jh64JyE9fXP2wRFKY8JI/TuH+YHPyl/RPT9+8jd26d1+01525lE7FlRQv5s/ZXg6tDhKdwo6GT+1cBXn1
#qBWr6IsNTJaNjqqnn5c+i/pMEcPQUa6k/zu1lic2j8ZWGdZM6VABu3euu/SKypmJWFq5vKkGlFaY0XMmsyGLX6ebrbiUPIKnJtO6
#VhgjORA3Hpad4Kmpeo1RIxnNTTTK3fhZEBjL0Z8CdcN36ElBgyj9VBjStK2TrrXbxEteDTMZWDLY4Ppk2HntBxPHl7dvSf2+kgXO
#eShT6DlslQUTN99tGFhO4QQ96tDK8yNHEo2Mxv86wZvkn0RslAZLCHgVIml57vnnU+smepa/GgqQfBAl/rcNwTcsOeX9y7peKFxg
#VvxF0UDG232OWj3dB3u6UIEsIdzzFT+Ka/lKj9EzzjtpNuLsFgIkZ1lruktJMSTPDKi5J65ffmwRRKBLRBIrc7Jumf+UHTPktbV9
#sr0t1bq4SDxJj1Q8q86mmoCYpe26S12YzRte2rcd3PqyGRJ2pepLrPB7q7DeWIqlepogFpUkZmYqBZ2Eu2DtZrmnDPfWPVWUp0GG
#Bk+WvyDeWQsTvQYrpV0vzHRMgGq5SaVEiKWTb2L0LVSz363EzS0UgpzCZmTLycqmsh8qRBmX3F6wC2nH3k3sfyZtO+vzU+U9G1NB
#Qo52ul7b6ZgZRt6ySw/Ggp2dVREGORIfc/Xfxqcw6L9K2CjVrTdFCE9m9RMOPr5rXqR19s6QZsOKe+EJsDSlaNXn21Yt9xK7O8IE
#JW/bmSX4NUetRued9BCZj65e+PmpjYvoggQUP+v3ZYqbT7tI430gr237LjF2W49LfEdZ3jG97PDe5NvHge0lLr38UstyeiErKJ2S
#mqxDkCcplauPUla0WeFTCqbzIqzXSzRe651+eNURKx3Bm/n++oPA7OGbSSbP57vZVSsuvrR4wdhV3rE60EF9b3D+znPD8e0Y8vPv
#ZcspL8nTvZdboSRspEhnVOSPJnVAWTFwol5HGL+1plSN1B7I2CB4L5PIb+hsFfBWXhS6uURD1mBFzaUhxvZB6KP6te+RZdEMHm2G
#17HWUfUKJsZNilslb7pLH3Sml9nZZTPfke+OdrYX7Q7UHSpooTUvIU8hIC85S3tHtBncCWtkK3LtmHtR1ndufJi93W679aIU5FpQ
#AxN6XUigcGhuSYhEBf70DuJ7ZACRsk7w1M1KIeE7jKxy1wcaMy3wt3KF+jJTXyVCenawctyP2PrOJXx03dJ0O+Us1Jf727V+Otsd
#/11b8EfOu9g2xyYxvFRd+zgpwQ/M/s4Z/YO9EnVl5kapcZtnE6gf6OoX6OqhT9yiGCeujssvXVLZVtdeKH3I8N6QhyBbNdWS5XeB
#Quj/cxfi/l/29y/3P61gaCeUBzcG7ozgtkYhbeBIDNxm/yLo1f9vLoL+z/c/hQSFBK7+4/6nID/Q/f9///P/gb+j+5+GeniUuGfr
#CB6ewY//ev8zUOzCM6OLYe64C6C0JIGMpI9oKEnIbsUTBX6TJQ9m3bsIGiqPuwgqdjIM71SgwQWVUjYnw7PIk9JrS2uXktREPMge
#nZz40SHTfGtWWHPanSJ7svXinx2wsvXFUZ7awryA7IC3rKb6sDvPSDfxJsygkc7RLr1aGSFj6V6CguIabBbpwXzFTwzoT664mnkU
#vWtNOCEkxSuweQoffBvK9kxL9KFpvNw5g6VEctvSxejLEBaqMFZIkYuFyNjOW3ro6/ULY1NRdLXf8A38Bmw4LNEE5Dd/OjCKS4Uw
#cRos6G95PexZ296KIKVkPD3BcMuIxEqGQY82h5STpidJrxc0n1MWDnZW4lD87LmduvW4osvXv5kyPpjjV/PD4EQl2jibsdDg6X5b
#t8aM9vOPscvx1Q+mF0rUCFhhtpa05x88541gDaZgjOWjiWVL09eqMhdV+l3rWG70W9+scBzZMmfiPvD8+1A4ZeUoeXheBKXE4suN
#rZf8jDKFbPa3amRvJRC8tp/XjHz7li7ul6zT8638USmzHveyrPq37W1igAW6TOA50SCsnkOv36jLqjjngv1+9Zz/H4szW13fPf1o
#ZYekg9708tA49l2l/+YpsuU9/7qPRD6PeXio6Hv4n9fMZMrJ4Vsgit8f76O12QrqQFI+KBHp26dnW0k2ZdoqazLctfPzFQV+Wz5/
#O+a9s/O2oOD+O4KrGc3PGD9lkoGvkqN59Xu1NLmDMqIqGx6Hnll7/eh015TZF/OqabyNs7FDlCRQR/YRhJDIJalhXrszJCKD3+j8
#U7VOXm3Rql/vbxUbnFizI9OPNLiVQZyWYGruR996jmHF1R6N/8cU2aBCbCbydMlmbtTXpZeYhf40g/PmatVoZ0dxSBUx5eDMs9iA
#8zRrUtk/Kv/0RF2KE2BLJ8ZTXGH/YRH1iDghoIvD54TGh/aJ8WSHezXj6tcD3vLw3y+7f1H1+7VZJxVtu4IIHveoHb+y6p0ft2fZ
#2dJkVKilHaRbA4OfBoZeo2FgdMO77uwqcWf+UpdXKMVX+36X64hLH+cjK5M8lN1lymdDZrPonrYRvYef3Bkvvue+/WjL6sG4O4WN
#Hmc9Xl7vA+feuXSt8VktOwXUnb4MslsPowixZ0ILGpYo229/3ahFFX9/TkBaQL5ulqxZdkYapdAjfZ6dviJjvefONlz398LZLAIO
#CoZcw49ajSI1uVqPqbdTwjZ9ZdAImAwJUzCphW37wOfSGJi6kfdCG2vbKHLHdupCxbDcLSJSZip5WQrUtsd57kvFH+7LLDIGPtKD
#9JdHujMjnrVnzP6CWL5yj0Q8Z090/h5pFUVsAyKMlF369Z2A6BMhnjTxT0YZPAqidcbAmNFRLarrGidfTjKWSYPkqalZiEtVAz/A
#pQeX0mUJ09/kpd08rRVP2Q16ksbfLHdOTW7E9aRrF3Qm8E63dUy6RgrFWQk+Gda6YAVKPooA+Ujt1iS7r7RBs/fvUkalSePjdVkz
#El+wZAhIIxKxFC+gzLi49d79Vp/lx+7JJ+5EjrRJJa54rAO/nn3PP6thIivDh3d9BXL35SC+jXzGANGzt77sSLO05z0EvzAfKp13
#aqEeyLlniLgHyiedMrJvR18RYwrXDkfrUeKt6tVdPjswhedNdOPsyW+BsXjj4nIBshQ2uWlxcTPF9NoDFWdkpCtl6Sm1oqAGlzoU
#PigPi3wIkQyR9GNrKVRimWdKHQxCylXa0/GREL93u8TV3TQDtakRUlJ5OCMjzslyvvxyIT9VhY+t6FIwaZ+YHCVHo/1g/hP6lNuy
#eK9bC0FRfwL/JHB7XDzFPM6cynKF+QdjMQsvp+d5r2gJWMp91wKxJRI03iDblFS7k2w/Y8fik5g1ZvJZuYWlJG0bolnDnEczskOM
#6gbmNo060Jzu8yuMwkHB9qEjSlTpepOMIadZUilPXcNz+EMiy7sotx34qkwsYzX7ZWpyjFXRF3TnF5voL1qrNsN6cpcfsry4Llzg
#UMapunTpD/mVcKWuoKGez7eGyhDfq2PPCsafTIidb+Rlf5n89qp186Cr1ShkMIX4UkQB8eL9cayP4lK/W7Dt2PkfMx+IcirGA+fy
#wqmDklme3By7ODEUuB3rB86dEo4VGRzm0avcjpaN0lBaeZRON2Eu3t2hnHWDnW0HcX4Hvy5SRWwZglQMHfG2xVvVjNhGGhnKOOUW
#dJbSUt8UkBO482BaVpL6Rdbn78tlPjc3zwneqmnDsMZX5iheoxUGKQZ+HqEMs1Nd8Xz9St3hTmpvZmNT1V2TB6xXx6We+Mmh9VMk
#hZ9rR7mnksnmhpsTkmjD6mQp3sifU2V+ufJUhNCUOKnllPcpB8OdiQKz2YvfmI02+AU/yPn/MokZrncwuNGG8SHBy3GDbKEumpW4
#udAWeMffmLBOCR5PPtUkpx17miwAgqf2zLlOb7gnc4Py+dsJba+3NMH3NwJBBLLBo398vucNMt8jS3fudTrVP25AsO7PuEL05vqD
#s/dybg89PzfOzBgmi39N6GUw9sbkqO4SD6d8RHLN1tWPfvIl3/pq7zepXr18ybM6YjldwwQs/K5SZHn9RwplxwjhmrGlFpEActiv
#mj1mYY1w6fW1ScxUh3h8c+Gy8urPimzm4GCLk8TRN43s06uTy01lrM782Xlw/dSfpDKHDjZDM7cO516WP1o6OgICDGgyThUVBoeb
#DEVmuYmJrZ5LrM0T1xO93j9bfELFGKsSy8hgYMApLOyQLptuz09SLRpJlDv94fM5kJZ0jhZTP2MQ+F4Ou9aT+zopYgU3fyUwXNWy
#773+RPlcui1LaORVMqEhe55m+jsMKInCtiyKhw6cBtXuBOZV3RSsjEokF12J3mdF1bE94Ct6catqjrOfu5JJIAR0YyFJyGYEj+Tr
#E/e31e60wfUbl5UIHRI2rUApTgOI4Z/8ZJ+zo+UXfl9Ux2rako66qG9IBC38eHBnrthJxa/KOolAles7ibw5uXq1eAPkjUVJguPd
#SegfE98J4vbnLN+8ZjRB6qAoTre6jIRBrUGK5Fk+kgLm0XBNfgFCA3vZVe1ccuIgojxEsFqB/71KWymiDeXYnJN3WNt0nqqHnISD
#tWYENbZ+LX6iymxPyNfKVaHJS6ZyYPhNF8PfL6r7fJ4Mv75AmBR7m8/w+jkdMdZQdFJXXcKjL3nFs79EMvE/5GhRbSlnSbQJfdS6
#EEovHw56YMz4tCIpPnfrTDcCH/Oe/R4tJqyju3t4yYQy6paG6wuNDGo1rmhSQUYq+rBkijgkF6ECDefDRAPWEgojUgZZznTHRCIq
#UD3VshwXF9nAAwOWHC+CWBnDnZe/pkvY3fLs7ZKo/VdrlNqiIJE1Cvwr8ayovpxeF3q+Fv2HV+XL/aZJdsDRH6zHHSf9czNUQlO9
#MgXjt9NuMduSgDVkG01uC2eE5+fy6ShyCvPdze6pjvR0Vm5N7NVHFj7rdThtVKJ8n0TGwFu7nPl6csASc+P10zSFz01s6kltzJas
#m6Q9nfVy6y2WX6bSJM/qL/nIjWkWI/o/+lqT3/oV+z59ZPC7eepvKanEyI2P43c1X3hSgawiaz580Opc0RKuWtBzGcrRTvXxEr/K
#fBrvxBIKkrZ9XuuRfVzaEzMrrB7ytGbehwvK9uwLIF6W0rwNFv1nOgtKKf19uhecDX5yDefz2pos6tj80mo5kfq9E/xmpdyLLy3t
#9YlWmLaEzwqzgtXAK0p617buc6oPzruohwRZYDdU/1B9c/OTWiUmq3jAfxlGWXL98gmZQPIlEGgac6I4yBwN5xxLqLib/pXYXTq3
#Lb3FljjEYND+ObIEea1KE5b0ttSB652CoWVX4rO6J5BnsvkSgp6P+j5/pFDm59ZiZp+43JN3ozsEGpyj1/SaWirdOmmSLCIsXLF+
#VvssVGQxjy/wo1rLPG39Bdrm5DtKz96d0m0dqbd7kyH6XtbS+AaTLVPomkXgk7Hg/tc3ZyVbbr7OH6+/U+Raq7f9KqU7+/Q5Kb7N
#ZsKf7TuuJmnLhNvBnts09YRkDHpqwTOP/DW10+SjaJ3FRF+s0PPZNF4oMiq1EOHxb9RcF6qtZVpvvsF1P5fBkOnpGUoEVUUB0rok
#9sUcDz7r3BsmZTQL/KQO/tOPNteTSm064rg0/cga7lGl6oB1i2QzOfty8/tPv8vKGxufCVD8vtlCgSdtOK/F/XToodmXBc5LVzMH
#pcsLjUhIwkKVr0cU1Mbpaulg0tMzn3y96Th3pSjuvAXk1cbi5wd4RGRWvlc+1Buwpd9rTN8Ttfsrj1tjwbgsydJ0La/9k2e/iX81
#fYqjSuDULWK+l6OTwqCjOlc1JyWS4Ah536uI4ZLjf+vC0t66fUE/BukY2WUUmd/yMdEpSdbNYe3797u+cP84QsST0bFz5lLBi5e0
#nPiFhnggRMHyjaxP+7rZ35/g7xtgWDWYbB9T/C3MTT8RpEQvYmri/AcQUAUWMkrb12K0CqFaHr7piVYu5AHyLI/ko7YvrUslM02G
#ZZM0O8EiOUzf53oxGTxpb7WlhPBF6dJpJDsGht7UQce/oHlNfPIRGzkV9/im2CyZ/PIFO8l4kgsyJ1mU6MFxmw/qRXd4TfxnF7ud
#6Z6LL8RCKwZv3GOrWQ7xarbXc6Z4KtQDKXvH/1FimftZN3NEYUUz8QXnUt0IYU3KsmRIThAtHiPPk6KMnCuqEOfyyCEVHXu7H2kp
#eHIU04n3r5u9ndO0uXK9CTxU5UYmvsVBx2vanU3ApPUWIdtcMBgbG/6RXHf8Hb7/dpEpiUY1KGp59Lxyk71up8tCzusb2FDdV/DU
#uBdNScu5fgFfw0jAACm4jZ4GPyXqmXA6F8FIOSnzTa66DOpJSs1zRiPLpjzy7QuRyEsWTbEfZrLE/dOtxjWYWM3oe7UHGuuySZj4
#hTxqZOWf1O1cwg/NefETRsP2c670tq1TBHG3UJT66QH0xA52WPqFo/Sojq7+LVNakXt9U2IGi+fGn9kzvnvpbNPA96ji15kaZVH8
#9rWCTG1VPGm0DQmMiY+ROlA3NOnV3Umqlw34Zks8HrzlJ2l52jIivfWNbtssBnk93Kgb6SEVDJm19fFvjfErHaBS5S4bIeMq5PQU
#hcelybedcywss+iqdK74nL64cCo8NYAh1D6EqNJW8PW0TIGVAS0xJ311kL3SyNVNgV9K4HNQmrCwUHx2xkdZN6jpb6Ahdo+TWeOD
#0f6hcaJJIg9qtsSpyilWriRf2B45izf0JmYz9gYjXSsZHn4O5YxSPl7TeUNsSV+F6KNXZWofkkwshy+ZmFg1N1oLcqucQPDTtMVO
#nCJIIutlUL9cZw1RS1G/kRu35PkUNAPhOsnC3Doiv/X7Q/GZkKWFts8rChhOy7QACQlfvOnGWrtXakayeHjVq1/cyP/EUlsmjtBF
#EyzzvO1YxYNyQ05eOYm3vlaO92mI+hPyvdWN2M6rlFKv/TKi8KZlGx8GK8kp9AhwfF0dMY9Nj0z8edOksy5JVPBrQwjGnede9R3v
#a46J5m/FavDum18Tducq8uicOHODVhEbcRszFZlqQU/HtXjbcO5llMjOWz8xLk2pNxx/EHiSfr+bZPA+TUTMz7vNTZT2LT7zGlip
#q/b/vO0ljYfHjxc+emJdzY+K6Ce/JakP6/gAZCrW1O9nnbj/i+8vzkXfdEh1934+mhiJ9ZzVV9+O5hlqv6zXcwH57EUYh4aHLa3M
#eJsWrPLkhTA43Y9y6871dxutTBPa41FJpVE1fQyfWITOrsuX0T2x3PqT2qJx80dC5YLYt8dKC97fgmqZg2rVPd5dqN3kIFvvchx2
#iqEX28oVohpwuD3vPgyPYZE3IqCStdIhE+O5Wi5Bj7V+OtkUI3IF3wf6lVflBUncJJFjAqv2WfDFu5ntsbxKRRK+1PO5DyByeiD9
#LJWXdJxRfL18DVH6jo+k+yQ3QpVozVz7Tjwwc9e+UXVp9eKVH18JfE5RxWsz/hRPZJXuLGzINWR8mqnGfQmFrwNXLacuMHi8k52t
#53A+Uc502NmTalFyavI3WYGFzOQzlTezD+zk7/mtwSJ7l6MbGx0pQ2YwrErNJvVQmaeGAcq38kMZ14SLrjMaOCkQ22smjRSSfsxU
#pLjVwfrRbXCYi7XUg6D9ahjWWrVKCtw4FfdpYOt3oHo0T/if6Rn8lW9RVIZXH0WBcq0Gfltz31wlIhYLL+kN42Ajv6mPeUfM7bkS
#17uh/0eUZ0s79VZYZS7lE/FaaJRwbozVhJ+NaPg7+raSRG8F2jvWqlJ6mSpqpa7JJy6+e0OPGPM+y6roInpygiqM+oT2z7SqUoKw
#dDXF4CccBdG3n7sF3UUUIGiK9a4SCL+ympV7HqVSbsJNhD3dGyFa2ErgG/twIE8m3cmLoTeaWYXe0bAHRXPCzZDESZhc6mK5/VhW
#W5CfWPI3U3/5/ufr98mp1iqDnCs2TueWfW+4HyY+p1B4KzqeAzn0JAubGy6rBUkhuFwlU/7KSBxfpvr6Ej+7X80kdVU2F7FWjEHr
#TPiHFqeZ72JjeqLplVuBrKBJIuXx1xWERDo/pJMEUKTlk2fvPrxR1TafYlZQdVrfilrVS/HivYh4fpkyOgcxtAi/yQcizgVpGUHT
#Ob3LLD9sOkxZDCxNebSYz3UFf/7ZQKMv6haQn0CjlK5hJu6Wm3AxJA+VZnCqoPPui4yVpFdjufcDrsrPvnC/9eDHrT5o6qyhZqrO
#NjcHjZDR6Gp+9U7Uee/2h50mNq3YNTc6oej1hZyKh6b36R/co8vgZKQlsnkb8VVMUVkJ+TC7/orBS4N+b5usQHxS5VfwBJXzl1VI
#X8KvJ5Pcy7dNK1gJlZ2hsanhKWyQbxYcXMa+P+PLqXcbrS6ckZbudp+kcU218gNrJgdS7cVtYfmP24Gy/bHPmTo2KjbluebimMbf
#f+JkeqFMNMJGfIoqBElFrqiMd/kuhdpdEgm2n2+kSZjIdRYrqr6eEPrptQlScovtN/Dt0Pz4qVCSu3ac+SJ74rMk6zYOkS7x7GwB
#t+xEsAU1eVPypNzPzHXtP2D8hLRyGnv6U0xPCEfHuu/VzKwatYhUnnHtvR2L1BwVqlGQxT8lg1KZfFSwcu4kuoeIxDpbz4CInWUg
#Mh1pe218DfXciNIiW1m6h7Ium4CYmZ8pK7Hxcbw9P2KOJt2FWF5+CiXwgEXUcqnyOnX3DSPFR4y/YrSa7Hs9Hobzs2tbMZYb0Eeo
#5Sye+rVAtbLSBsn2EuQupdxuhTSEDN2j//Ln3UfRoTOygUWp9ELccy1lkZunMz9c0zA4fRVMXBU2r/BdRCWwxzoTuxGrkNXtupit
#947zSWmnk8LoB2895usW97XPm61xxm50NCy11GQzaJEWxt4b6NcSoT3989nKvefq8jKcLXEyjwSzueLeeCSyxNmvnX82xXyKdFFa
#5ZaQ9v0+d+UUG1ZrPhVzE1WruU3SlsrGgOEWMWaedyNv+4nuUCVK4jE8chd8RPKmwKiBxq6yrPh9qNBQEmGqgpA1gXU/ZOchzMbA
#5vWQUJFSbdXJjGfdzQ1XHpe+XNO65Fb3yU2Q5mV5/jp32ZPLUf2DzS817H881ay2rsjSWOWHdRiKnSgfrnuZe+OR+oj6S3cp3cg2
#ENnTLG5SxBlqTwexS6FK7TwGhDc/wt3on79tatNUur8eee6rV/k4122nrMz3v75lXkgSvC/ia/BTtlnG3u2htc3D9lE7eDFtZt8t
#m6SNWRRd4uzm6fErn/1sSgWvtdaN0j9R7opiKNFs9WYFrZwQIm6bf41wlyQ2TSL7pUiThqe+ZqdtX9DFwPqomXMuwJb6Qr5dkDzv
#1PiY6Alm2KZoPipCXsru14/ARPxOhgFm/tYNAVHhcxcEnPU+MGo7FJSesdd4WcLJwMoZVay/Tu/9q1xfPUK+cPm5htqtm3ZC5dev
#ivknx6bLTT833syaCk1nNb+t7z8W68Mg6aqUo8i62SofNZQ2n/L+PVwNW2zd9OfGyGb3urz69d7G0zfPsivEtL23VllJrCJTV+1d
#aVw+Bfr9NlKyLKPr24ygHc3D5ByvsNSN9Qfb/VuptxzSL/9ojBAy6HMDbbInAmzh4/iD/PYzCTa8ukt4eNeeiZd2TeHjLbfhrQhL
#b58ITCVgoY+vofQPpZBJUwkO2/RkTlh0arCnuydICdZdVySeVVFDzxZqT2XUmJ2QVGxuf3yTeL3gdvcd/kSzcNikz/qs8IuT8raM
#zIio3iZyxRunTGDcZxG6Df31CautNt7hcQrX1CdfY98h7uX/fFgT3jZhLZRE1eaxzbrS4akt9rJwMDuLAYTJhSw1PdRT8RbBngyb
#ih4Lc0U6N99crex+/3TiosPFFFrbCGuLOomPV2/QZAy7ZVanTBddvydLZN1LzX6hsJBt4JQQ6ebwZO7b29zJ0DXUatUDZNnoZPkI
#3VfnurmEi6dbm/K3xMTbbkaEzOc1roe8CIh4nXq3691wi2hI4ssaxy8a2dZT57cHQyZXWpTnnC9otrrlBmldvUqj7+cloj0dmtaB
#N6TAeipRGhRPIpof+ZjShSIVv8H4Infsk+nAktLu7VqD3Ev1lBfNsFeWb7EltNJrndcNT9FgfcF3x1roiYg96eMsp84rbLfNZ0jg
#aDrNRvBowGOHxS7lWwV4UX6egx3jWDkEFXF4zriz92LeV5dWJeM/idKhD/p9qdQeKQZS95GmdUAFQ5wfRu+8rZpx+F5jM13NKDhK
#l8A4+I32Dt84ZeD5YMVEl4amIB3DmPQuM5ibrG+fNkNiRuqLZ6FxjKHX0io5Y7ulFkRm9TpIgwokekM/SJuQu4y/7tWxev4phXeT
#807/FDV1k+w0xDTLX3otJc2Sy/6TR0nLgBCrP/XS6Wb8r1TqJDqR+LEIi+cEQpCrkiG6DXKQWc72/CkzpErNiRBfRIrwJ2JnKeOP
#4AxvVpmJgIc9nK4qd/jrpgI+hgmGnpal6xFgG1aol4lHgJRGJnV5eVsovbsSuE7ZWlhVrrRFlt/1LIqNSNTJuGjCQzD/CqEt+SDX
#7zk3/ak1SaOZ0k2jUhO7h9eNbuSkTNUtd5A/zvli8bSX4tOIsenoYyOLeu17L9XUzNYL3vGmvlUP5NhpaSNuCcfvzaZuZmCUcVJr
#/8nRqMzEqXfrmWF4MYYswKGYSAjf+zls8uHd2hH51lY9m4y7TBfDZV5mgcRP1n+wJng6RgrvklMjbCbTrA52ciI3jPx1inobjCdo
#r/KjtdRuROT9iR3dSxfPqcoPJ+XdFti49trp5MvPP2Zd20i+WNsU8SXxCRgXNAyqEtSf8UvSo5im1NbhSRTpx5xm9DXTuV2+TTxI
#JJMWKOtzprkudjSLOip2O/yO9ESiBWctfzd/SD0jgWuy5FPy0ribXyOI0pT1v7d+Y3qmOOefqTiSkU3zB+K/fmJb1c5PsY5YvJvt
#xbcfdeUTIa/eXHuWUP/Y7+S9ObOndTI3VJe/KLo63LMCSRCG8lOFZ+nYlfc13FGjOyuKXRltRZ0aIPNUn8tTTuq6Z2ik4svBReuf
#IvNkVoZ8YsAheETpWgWtN53PN2iPoHlnjKmMzSmIhvv7q2Un71BPbImjs9gG7xbzd50h+DTGmPLYV61DqjWu/s+HOBX4Zft5/9NS
#jW2bDhLZEQ/rq7Mqn5E2tFerWJ1J8A/l8s/N9GfcFCdn15qxeHPr+0UKt7vGHGUNE9GBP1Xeiq+fK/yxyTtUFFbFK7weR/J6XDnW
#5afQBdf+y7IPrxnp5xGWWPCmU0R+iwnugz+vpYs7fatFjsqSMvoUJoE9rT+E/LIB7F2tQgRDVqHvCY40PFL5U2lIodkY83h86YzV
#tys1fnoNdC2nnEMv17HrL/fdojh5jqY1v1fRNN6n7BPB5gXZgi+jJjGJb1f0Bd6FvGNwlM1+LLHtRyPXjx/ostiv36KKare5e5tu
#/Wxb8YdZa9WJrzRUi9laiyu/T7gNtTf583z6PJ73JqxgnCzGyFJU9ab9m289pYWuRYiV7wn8f5okX0crC7Jwxr+8Hit751GNSMKv
#z9egktcpJp4ZIdtvPHRUpGU+8YqTSfFOiF960p3sfNlH+Z8qb59gWW2itqsIW7qBoZCZyl8v8wkEuchk53w29XMdbf40qwP9aZsX
#tBB/eU7yWdVc6sWbRUr22n3TFx2Dv/dCsBjd88j+KcZsuTN9H+6EBZ/UQFIMsp0e45LWSgantMkh6qxW6H8SPfP+Zf/itt1aoENQ
#zis7DLsTU9q1ss9eJPfEhnU8KfsKKhz4uWqtVE68FVaYebxqEizFwaqEmn8QVi77s+K0yruMbG3l4Vui7d83aGQ/xREMslnl9jQp
#zsHVOwasLZE7mohfObqNg3WvLjTDsdF8t3+8mrPr6wi40ePAb3CpYdFF5YtbyOZYO1cWUaipvkJKnfQzYp5g7ATIZD10+qxg2ZuS
#CRaqYh0M8unjXxHIh1EKYU8RZ+aNqTLjqa0VaEx+O1J5PW/TgFRwLo5aXqrMlxVNMN0iNki+IrGM+L7Owrri/UTISXmxin/Ldhj5
#x4Begdq49Rn9XR8FBoJbuv4c+MaZlwNU4PUOP4qecPhuj4EEzRVUjfSDuhC0rzVfW/h13qXjBJv0ChRUBxf4UBswjnN15H5osiD/
#nfOjjOCxSbtyqVjDQKJE74yfgtDzSicn7oEaNeyFGkXp+y4zzCpU/EXqL2Plbg0rWY+rmaIKCWlDeZgeUYoZSNO4sKira5VsMbHX
#X3/9VublRoBCIbOe3Hg+Mn9pNnUY37jiWTW8Wztf5xuDhet4nMHA7/APqvydCjMhsq/88GBVZkjKiJOWTbPkUx7f8WABky7Xq1gv
#3iFuE2Dn4QrGfJieiDWmDa0fVIEwO5xocv2ZyuXI+eTFa81LdLqR8Xn4p645sjAb3sZXdWUVfOiX8TYniov10Ru4Y/BMXF7yr6CX
#PAmMH4n+cOo+DgINMoXe2lq0Kxe9y278uHQs6XY+2Ft5SMtM5xPXm5+dnj/8Rkxsb7Cn00H9bTde5Fu889XxvRjt9r3xUwFbq8uy
#o6WCYIge8f0khrSLcmq0N5RsIxJy3d580PgJsrv71lKuoCMbKa3VEinUDAsSCvAnOwWqZdQmO1tRVkPnvvWEVvNZ3n1+Wm+Y1JjU
#KuGTkIA1BsHBOo/mHqozndRJZ/TXW0joVmaSdL94nRHSbkPMtU1eK3KUnSwnAsucl8hvs73zBcpLMOJfAit4+ERm2eKeFeULtbdM
#0ynxk6+F13JJdASVew2Y+yz19anQRlQc6fyU100+Ftz1tnXX9T09b3x66z0nB9w45SsfFCmpdVLX8/JN8V8FW9ch3DrChXeTbhMz
#q/g859R8LaLKfyM4cON+q2r3o8D+Ob+eNWqFH5grbJXGHAJZH5s6BW7b6P9gH6AXY+YTNTRdlRZ7reiVJMnq9N4NmitnxOunEUPo
#7+udS+/kgXBfOxt10bRvzm3sSl728EhKFMSEb3zm/RO0Pr3LEuezkFBDx6pNUOI5W/0s7UmfBQQD66RkkOGWLPd5IfCXkFe6q5fw
#PefKOVcdZTFFKOfMV6LX1D1A75Y9TwVUk5wjmzHRSQtpvaxyjkD/ch9fZrCtnbu5xjOTC+1TF1NYTV7y7JA/2GJCuII/mbUVpsqc
#YQsUIlBv7EvmkK3y3uo/PcJs0BcQtpnSq+663szBiD1D1WraOvSorOAZFNoduLr92DzvBrfVBqrdgVt51VWYOlilz9E9x296wt8t
#667Njd/b5oIwuXRDzOOc27TnS40uqIX2qBP8vNf07S7pCuOlXOwShCb6vFBIzKDJb1eky6O0/AevclbPZmSennHieDL31uqiwZZK
#GbgOtvONIaGt+a3qSloEeTX7Tngg3VaRb5I6XYHR219W/ByU12i2rOwW0Lc1SUzyWJ7m6FNclZKXxsjmET9fo1P5KfG1JDNWi/RT
#nAGkgojGwkJ9S1/bP5Ghy/+B0p2gXPYphrI6JURCzgDJjcRULo18dP+7LCUTzypDFjmUfcInglV5Ie2H56/D7Oip2aH3LixQL1ue
#WWQa6L0U7bd59pNgQ7BCAEv7cxrhGaGt8U3Wmqer9Qu19l/LnRSME/VTCWM+0ql1+6+sX2XO8fN4YL7lfm/wGr/pyNusCxUzI2l9
#CHDC0AWits0qqkue70QGqXeiDI3N3vI290eGECwrbscWt/NVtMqwX9ET+7ZtOX17xSVjJuiOaYk5ohPfz+TDNR9hC4wIiN17maJs
#TqR0Cqo8u62gwPu0E5p/V5PQ/8Qn1vV71cvnrutJrrgsN+iCL1GHG6i+pKghYBq+fGqwYDvtdfhvN7kCLWIYm686b/LWAOPreN5X
#J/HHCaeN61rUIynWdxourk34DNDfksFMnOBfomLOOu30lGVlO4r4m+rClbV6MrztHGdN6RwHb4KAWnkF/WEsyY/tX3946l3HOFqc
#T6nCbHSieYO14N73gyRI8ZwFg0pTx77V2sVuPlL7WnHK3Y5HWpR0It7Z99L5ZGG/hQjEJyW8BTctv+R4MtEF6DypvMTYjcaXFHjE
#eBHvlIxYykoDv7XecBxulSa+o0X000fJrXE2MjhFKGTU7av5TGtLOr2sge12CKrsld/yyo+MkuzawDdkFkzGn8uK9V3Iv36i7c7U
#/Iz+utxHKkbyta9LrfH5V6GnKd48w+KCUx0S/UnQNQIjgdELnYJeryiHqfCcHrLY/WZ8irpGwoIHYoQEaeEHCIyL+53RKKMRvHpD
#cZkA737/Rv3lNcc1WfWgz/lL+saEDVZL8YU6qwQW9/qWaF5kxDNGagnoMV6rZzjfqmdXlGFgGBGtNtwu7Z70mricxujeH5c6/lN1
#idlNGnIvnrh5pr1bHS/brgO1akk7kBn/mFF4p3XPLNZoTKf/hmXVgvv7BChF+bAs0zA3yY5rc+2sse/5kInqdOL3PTuFglPCWU3Y
#sCjGj4YYSvaFus+atmSZYTzCNzGSEP+nX/EYlZcjH7cbdpWq2VvUUggxqkqdLUMbTYR1URCabPSqB2GupOHfIF+/BP7q4fjm87Um
#J+pM10/6k1Lt9WTf2AwuKFdUveUpLYzCVg9ftzYVueHkvCh7dcHV84kQ8kGk96XLPe4Isss7v85HSMh+lZzrubPaEcobS23xaQz2
#id7TjLmZ8seK6DvXvtX4maYwuLKi6hnpX60cd0Qf2Rbnb6pM3z4f1CcFDWZ8h/SALLjSl1z5EfKKNkIXHqHLwrjMWEZMQFlqqMCZ
#kEUcJGx9duD5oEaJMk2R0TtaJiIX5b6feqIOxe7B1u7eoC85fiDbsgtr0PdCiYiFueJhMY0bwXL+/qg8lrHQju+FwsX4ePg3ovyQ
#8I8Ftt76VRp2JqR1xENbLinPPxQIWVmQrLDRPXzYdTqqXOxuFGGf1tmsc4nCApdmWPigsdgXpwqNg6ZqlosoHm/xzEX80Hod82I4
#OC2iee6d76heds/V4aDtzl/EnbKC4RNfbnm/qcUrEPBiOZPtZG+SOdbGMOsACumWTvGs8KybH4lV/jP16zPvndNzoeC+j0MjkhJl
#cSIuKIUSbqqVoRqBiPFUUYZY/WQ9mVJXA8Pqz0uDtpcHz9ZdRLaJJxfQve5wELz7/XHx2jUR3/fBHWyXxt8VP7H0JlBpdY/I8Rif
#SjWhI4dQDM8AcnrSVLAt9/mwfNfimkRkqQt5Z218TForSWpMPEWy4wlKm23YOcjg5Sv8k3/Eg580Y4Lpr1KoqE68NzmjJPz0CeRt
#eIch3Qf8lJOfX9yjXJduuUuChjC5knp4TTiWDxGWKyll0CPfhJLSgOHniGxhweQ7IoqEUJIoqsgAsSwzJVqCjN4ZJ3t/J2LX8E4V
#FKIw6VlMU2Zo6CgDSN9LMFDeHOVbcQnvpbYC1X1W4mp6Jmway0WelwbO/E/xWgcI2YOa002qEvu+qbNWUw3O4tlHMbDw15bZxGFZ
#+j+eJ2NgVimSr48G/IpOsfu8IwQwfLz0kVQ3+Sn+psnvERsoGx8/3cJNDrHkTnvtaxZatx7gUbhYn3N4FxxkXD7xNbSN4gTjVFpe
#eR7Dr/ssnWm/mavFFL3iheVj2q9tdmyp6sX4nDM8MVd/gn+tzA2sjQig6kpud7zu6z2ZJr/avPHybMmQo2veGOpbo09K23Wbmz5m
#4QGMFFM+F9NX84TOlST20ETwvrdfZTBmi3gRYYS3SJz9UW/YRNh/qzimuWomGTxXlZ53XWelzUyNrOpX7kj9xp9JjqrZT7Xv19tF
#Bb8Kcz+rzaMGtUezveYPN/d9f2ks/ko++Uk9oR3GmyuOYiz6/o4OYYmcp0N1cmu7UmNVKx7bj8+G9d386NGryOz8fN6XVLvE6Zlw
#RSVPdr2l9K3K3y8zbj5+rLyu/cVM6iOvpKRihtpI48zgGIdz+PXnFOunP/7KC7y8ACs8pRbC0j6g8/zmVcUB5/CBHJPXV4VfD4x4
#q5XMOKdehMNf19g7nl4ZngnkHJmBa1/KnZO3E2RhfittRCIN1/4WYFDpjlDTIq5zxEswtT7HML4cccodH+8SBRWFOx7fPcxNMrwy
#grdc9+C5nnKUwSok176spN6sZZTcXhd5gf9FgOHX9+vmBRbBoQO+pJZVxGuVtyeDIJbW9YbiqdzyT8UqVRGpuQaaNlHUiFCkfr7d
#UKrGhzmBML1XP/isHD7O9ifJqRmvGYaGQmPzHJT9u+hGqBdRpOuVF54i1l/S+j00ntpEa2ml1lwad434YcUxvfxl4E4qvX2mVPqy
#iGI8d1L7g4S7pFa+9ybq5j3x+Ls1Lc6WfFOLmI1+fnGzdKjpe9dtSrnPWOhrt2BVKaJ0bZqB6PoL9kJJQ4StGc+upRcxCOgHLapa
#XpD7/TGWiLL00kc2BqlAWhVuWG5V5um3GhRW74TsHrRE29D9GXa8VpRascmrPVhspIyw/Xbld8x0n1zTiSD/kr5U2LmOP0lrmvn9
#1ArwP5fa7PU4N0uTrYXe0fdpX9gaDzSITxVoPmt/1dQkqtc1/qSEH2fIhnh835dCYhsOj2gZSQaviIak0SEz3fjV1f6k+wyx0BHx
#61ZZn1XPeGubtnEofHhthR0iDtuU/pO4rIGAFOUxbK6pbnln1rKbOBv03LIOb/JA6vj1T/+cfdKuWOJZbpIbUc7GX1tbM9ay9JyD
#pcrhc47RyDlth3zxOaMae5ZgJ7w87M+gIY6FsBb9EtLnNyFZ4dU0JfzPbzJXaAjSyt3Ce3UKT1tISNjvwzwpklNaqDtNYNvwFx2e
#OKfSr9B3kf7dGdEduVWorlqm+IsSP53zmFAOjxM5M4fONscjRDrGE1cou/Seaa98xGusVyemKY1va021/L7VK0ccdE0s3SD7u8Kd
#pSeI5zfzR/tXvmKnHX+nMhiK8EhViExf64oWa/Tv4hcO55x5s9lbyVGhMk3XuZOiEqYKVnllk/dkyeBVhD/B+M6FtQF+794Cs3f6
#f0AqdgXMDv23VnMIzxbUBhjVu+k/dA/7dO+c3Lg/X+5PuHXJw/vBFwK1yJkoziL6+EtYnz39tCrz2TGKA0K5rqrk7S8nZ4iKN6Zc
#/p1blGeg6Y1Ced9DWOo/bDC9lPatj/l0sACJ0CZDfgvt1bjVgK8okqh+RFe9Bt7VqrS7pwtnc6Ru5GUxEzJlPrJa+Ham60Ra2Y37
#RdtdCnjajQZPb83aqM8PV4s6uM+cWkuSewO2avhKQuws6n/jVvSH3xzr67KKJAU7kXUXM4fXPXxvl7qg8zCrfkQyJgtdDkz97pY0
#Iw9YbILJfmyscNyYG0GfvMX8zoP6YahOBHbL42L005UVK2EDz5mrUQLz2PXJrIviFMFGJ688IdxkCb4XMqeqhc/E/Ghj0e1h2We3
#3tiI5Tv977Vvagckjlf5spk5rD4Nya3jo+y1zrK8bW82rUqSz1heL/gBtbRm/GDhS0iyPet6K1bPmzRAG/b+0hUyWSnj4BLiyAux
#H09agxnoZJmCRx6QF3JOXA66XpKi1p57v9fNrVx23eXLSZrOxfN+P+dqX5stRs2GhNZ+ExUcG0r/ONt2ffhEAg2Bzbbw8pSU9FM+
#elFeVV4uUwPL+LyTYyLk4+sR20OV2xOPKwWLLB+dy6IgqfhiKUWx4DEXJ/B0XH4eyhuPlxBKQtmlQkqrHniVxEcX/lKxZv6n0nDf
#DRbm1QR9TOLVk1Gdt0ZTQ1fwBuAtnB2qHYpin+woDKQ/v2s9dTblQjgDttO4eBb71fbE56Ub8/NVzn7ZzQPq368m3Gd45JABrvIn
#LwheNA0lGMd/VVz8siZsUv3dlk2v3NcvMP+6foeyQtt3Lw38uwsG/e7DB58/ELlEqT5/X0Pu/CvG+pnzpfcgHoIvUjUARmsot/lx
#cdBYXMTmZnvaeEh4qjmq7JZFT5+FqYi1okC8ibTincrOCufJE2bj15V+nK0wqL36e6Gkjep7uwY8Q7QkGGtOHVzfo5E5I13K7TS4
#LZAc9Oc5a2ixUUiSsFkaNNxnWmT6ZufI7coAVryWr0+v/JB+Y3Qt32WOn8D7DbfkCklK0CPCGw/Of9sMizNeQ482Z27UqIEo3iou
#+fgRvXE510nQrE+ameHeB8n0eYNOlh17fqej8R0Fz+1u7qIxKbw/4SSDXzqo7Aq/i4zXyBbD5Wp4L5FtMvguXigrLspnOY9CaVJD
#llpY7rwyLPRtf3WeppRFaMFEBGkK/ogayGOdniskd/vwmIb0RNwA8oKh+eWsiLgYfK2GeZMfxDPrP+JpF3nesbs4LvOY3KrsS2Eu
#7L9p7RzVoa3/KyR1kv7M8MVh2eecH+gNrzpjhioME0E7CBHy1ns9PCngYs+1JSmHpo+GY/kFPjs7dBrzv4ollAVPRr/K4PD3XDoZ
#t3N9uFmluhipqCQwVtI/PxRMPzPnrONRz+3Z4zio9Un1DoHpy23vQIzVc2XB8vpCLdaKyrwox0pO0i73V19P6VxGylnzUrtcGLXA
#rhK9VdTszqs7r3h6CmJ7Iun9ov8ZKPlHGCaGWLX/G7pk5KNX/+3VsOmRxWy2X0r99+cW8t718oaePY0q/U4V/C17u3M993vYxIUy
#znGqy88djJSNzjzqr96WaI77snSKhK+IxvqROW+JzwUGabrRm7DYGIb6rB8Xs5lU4TqdLC1VJa3TT+JMYqye+l3t+mhy6czz28u+
#m/XOhbYXy5COhpw/TK897R+pZczX0XDSunH/0v1WfOlWlOPZWu7lp1sfbyktf5/e8tp2ukrlREq3ft/w54O5het92JqOfoeVK4kV
#6TenFxIqo6s+W2S8H5MSfqp3pjgxU78yqksb/MPUerjgpmN1YNAfmkw3Gq/IV4Nt/T6LFR09L9/YlwnHKmcaX/cNY1WnufOoaOdt
#42XSjNmCnmu5vpqp6M9jd/PyecyLc9Z/U7XT7EjI6/utdT7XFXvnqFnGRrUpyDu7IlVbZ/rzrGbF98nz/dXVVfV074a1Ewq3NDql
#iAP9RQbyFZdznNxEB6ja13i3n/g2QQoL5js17lltPYxU9PhRKpyZnfL5VxJvIiomydfC1zW164/zdU91+rwCEkMd1xDOqivx0i8m
#LJ7PJoUm9sd8EqVLFlfSOaOaRItpTS3MCCVzR5DqNAvXqChsoObb8hV1ztXX3FzI9X8aWUixxOST8ur7lbYzP/ip8tyW9dmEkzm1
#FMam2mLhVrONdkT9Qqf5WMezkwUxAxdtCn8Z0zFB4Elzm8QKv3WGiZfd39w1FHtvHjU2Guh8/nK+y5daQwx/g87AhmBK0FuitPen
#GB7ATP299Ux/LXSGzi18Jiiqlnl0Irh//lU94S9rONwaRaHQpcHBp/01x9OhzRDGglceIt/4WOvlGe3Ks/Jbn3rwz8dd62bx+uAS
#0qsxl9ghSs69lWjYXnidfexBoT6ZlI+epK5RHJkZiLOKOqcQsnabh4YuBflsXX95c8ZqGokXTEErR397EU7SgYfCBtSFnH4wnik5
#mEib8NHZhO2BXUzXV7o11GZohsUw9EmolG+eDM+V4R7zxPHa+XjvPC/N+fWPcp+N/Fx7DJuaUMS9eNFXuHh5Jmrtej5/cQzz93yF
#KiQo+lUZMK28FKn9+8ol8vrwX85bSYbMfZQKU3QJS5c0dQUUptOqcq3Iicd52nN5i68LPRJ4vGb15ETq+uYUenaijU+1Ue/B1GTF
#EEVszZuWfPp02SALb7ZUwbIQi3q6n+vMNQEsfBedZDd4b7wQpj0hALp1L09cMjASw8FJo0Ty5aTIlQ9dbhHF1+g9Ni20NplYrSK/
#Bmzu1HhXWN7ScAPdc/gQK8fw3aSUSpY/GN42K+hwzjnF7eFoP9fHcc4yWfsM8xxkxe+1K20nFXyYql/QzXszUvTOEiZYKCk3mZRV
#TH5SuW5a93Rz1O/2xlU6mBZhEeLG0NZ9BqORloxzW5elgoTPwMDB5a63a8etpelLVbEJ13Zy7QOSQezObzL1qpRgofie1Xib0o4U
#tnhvWOh5CGaZJPR+XYFOOJqVDaBRAyE/BAO4ciX9IAI7ZS8Ud7ZSQURFalSJgeltn2XvDtfVM4ZRypG/MW37PleW8+T+2YWXXZu5
#7Mg3K6dU0yHpO4tFJzbX4EKndeRYvb9bZk1v85TEuH1dbzaIKrv4UT9/jbeeer1+K/9esXgie4u9fjr36qMKuzupQ++fvKauJMXc
#uUS8Idpxpba34vZS8eCGmZOuu2DPzyr0r+2QFwSm5f7P56rKBuTvRzUYU1xWXr6Dv34hgJLzR0692JkYYivW1FNPFBzuG9UHNQSH
#mzJtiNNKfvgaz2asrECaACV+bykb3YOsChQk4oEFB5w4C5tOfJyoKahC91hfu8Qmr/J2ZYp7D4dq8omIrmbK3I+JQmQULN2TX95D
#aSOcbjQ/V4tAYOluOa26V7VNYQem+Ed9VfyfcywnTBqUn5n7c1HDvMLVImSGvFVsmTWzbLjpyXCUixYzja/phGvLKVcd9jqTmnxy
#U0OBm6R4JiSyQsErJN3FkY3N87UrJzZnUm5Kk/9o+SFjQhHQcrcPsxXyu8vf7lOorwU/WeT421cl42EKZqkR7FRSzI9Ztqt5fdXf
#nv+14Ws2i1ryyxdhrPStcXHxQ/HVoQjfmXOp+3De830Y2+YgdU9ZqvDeyy5spvjU+iZBnCo5fmxd2RM9cPCm4nQmM35Mww/+CKmb
#NqOCMkEOF8KEbJ4UmKledHAPm4gyd71cqI88e2L0/nz1az6MCBt5UoJjhm3ylSIayKRz46KLnW9BjbdtVVId4avyk3hX2OiKXwuN
#9vVQpI6FKlD0M5PXT3qzP3/agZptXPttFe0gGSj1cZGExexFZN0qfrct6ef4012boqG+2cKpAVpBbhw/dKPwKYy63hHjGQ339z1Y
#7T+ZtaH95VLtEzUvV+u3kyTr/YR8bSFtfV8olTW+pZZN1I+qY8+gvwadvn8lDP/ZI6rhGL+b4ngdZI0CtMu1YVMkd2ryc7NeBpo7
#gVfU20s4b7OPWXH/9iRuZxrh10wKuFQgPabuXh38VMJ94bZKQ/jjFr6fraFGEldZJU3PRvB7Gz0619gYQ98QWPdtcNF/LoSs74uA
#pZR72YuZavdt/4hwFI25mbbrt3SllnTwCVln6yu/GR0IiA0qHc8puE4h7we+lxv1Lb3QYz361emLq3jS49ulz6iGlQWabFQfctEN
#W076Bf7Cp7iltfDet+R3kqcXrA/MY1dl/yPxz5N59Jtny0lP0xYbNd89KY4y1qNU4WXT52omeUXGYhCVQV9UHyZDeKnb7jyJmbLN
#TvD0yWyFfptXqTeft3a9sL+U22UfMbsyT6Zrx+4rkBTD+DTDjgLtwO81a2MkhtKJJj8PWnk1Vqy3ykU99XvCVWF6656xnyzyLHpy
#x3J6lFAFnipbIp07Z4jknLGkDePRINd76Vzoy1SyxB22HmOfuR34qjTp9ZaSD22hK6V5jAufWau9rKrFjenrGbLPBQNPnO6xepx+
#LdoIbf7KGVoW/8B0iuHST/lT7/4oWOE9TVWhlN7iN5q4zht9x/D59D2rhobfV5AOdoX37ryFh3z+fHLhfDicvL3p82fVO9HhLnWN
#34xy7hZlb2VX9o5098Weum030klnalWfBklEnlIqPc3kwbhcE+v9ceS8F1XboyvMT2a1k0ebKM/ZfJod+HNFny25K7wpUiUkI+AT
#+x/ZikRMISJ7cn3uXKgMLNr+F8q4KuZxiMsZIIKC4q1YPmK8E/+ARbnq6ihPcY3I1LN8g9dG42r5yAuvVF5ufPxcKtV7N4/3XHVQ
#5bRYT8U9kT+9Eta3einiQnUuqNnZT/wplhWL3KbumPbPzWdXFEcnWL4o2LowptCNSHbra77Bfq7CdriGvVeoS6vpVp/pWFz7eM3w
#iGzJmfLKHz9mEeP+aa8rfzBmztTXRCLN85DOumVvjQ0fvCsqJHx9/peQxXKkg5fKc82kD3p94PfJaoSKP0UI3uiPMY312S0lW9l6
#/x7SajqlLrWm0m/fnsjd7BTx3qqNwS25yent1dKcbEMu/T6G55wZTxiiLmZG5gi1O8y3dIj/WvWirDrXtCgRORCVdgLvBdPbQBeR
#YPZt8lfE+DkEAQ8wghw/tszG8DtpW0MWFUA9ynh6IhHMNHg/Kz8X3H0Y8IuEUV6L0Gr+jKAxTEkkQ0nb2gHtxVbAJ6RCSKQk51iT
#Y8AJzCdQZcEgtN5+0sR8OG/Lws7R+azK+Mv+r+svapylQamN/EVfJuJfrl88y5HZznr1knKejVc7/FmK/NNFEZgBo47YNGv+te01
#W7GgG1q3z/Wef1PeXJXhEXSRiIKdxzaEUM4sOCzX9SXm+rNhRFzV7XqIkC7P6TmZkoDPbuH5J98mnhNUOnm53NGwpN7m1pmZLBPB
#LGrnjLGPBqPdDig9hLhU3PCHTPjs3Q9YY2Pr3MLKrUVD4ne8A+X3WZL4nYs/Xzv3m4/6Jb2Rl7FtQTtJwLcO1ab7qNtpFPWV6UsN
#oBgwZIRyLNyxhZzsfukgSzG8eZshwv5hSGlxY1Mmu4NRTSzX2zq6Sw+LitpIr4y8flOd7OB7ZxyZVpAzLEwuxS+RaLIQP3vq60e6
#r83NbZCx5DMnBMlcLlFdzOQ+Rf+Hk1iCJ4Ilg/+pEUPJulve43cSxbYphmXv8ksm/MQDNQiIM/k/BaZGkYxbWbROynDodlC9XaE1
#uElu+jpTKDa0ST84hKj2FP2IGMmrTFhPqMZ3RQwYxsH37cqp+oA3P/klOqNPxp0Gf5GHaDCKsxrR8omy3W7xKgsCZYFYXVhufCqm
#v2zx9mzdpByr6OyA0I2vpyFOmVe8TUop7tUEI2qCN2qe6ttSRvQgzpAanDjVGTrh+uYbY3sP/4XxB4F8FzydNMgS3yStv1vHf0HH
#jkpmkSIYGa5OHVlAlgxzmd/9nYlMGm7g9vi9TjPbbjGf57VNs0NWbPArXtCUsK5Dgw6fj9ZOSjQjc3C0oohrbDD08vaNgEs7UYun
#69rONG+07WSNDw2Hr859G0+u5g1+TbPAPIRP8RtkLvltyvstUhiL+eVdGILB+kj0XBwU5KKT/EwzEbY4q9SoH/uOpFuCKpD3TiLF
#+ucyNvwacilxkvxVnZn16cxF/4eLEeemzA1j34pnPHKlskYS4i1+m5tN87NvpjMivEJkhu9XrTaJxlj7a0aQaOjZOL3rAAnQtf5s
#KC6hvX4yndiSUP3Kn97h5TU4pxKTR3vO2IioqDaPBK+SDQ/LGJ8dP0HS/DwivRPszjN6685gVJ/XeQWN95fP3PAoIEGHjFzgdfDe
#JFj30xCuXwnojYN2XCzxNbLU+KXRlHIW0/s5Gy2v4VpV9PqLBteVpVOaAVJv28qkElNpaL4sbzapv2dnb5mdsi0Vi5ylNZ05by49
#lvaOECz51Lt3O0WuqrJGdW7mUXz3+tNg0/Lnis4r12yWBELf8567D55KguJ/0TE5Hy5RdNL5s7zmGHGXG3+1Rr5nI22DaNjzz2oX
#E69JGRiscatKqo6oFDwI1TCx4v8wysSncMVtME4Xoq25Q/1s/Vo1hkEr8rw/a4p351aqOkp6juXyORT4UparfMEFtD+B+6S7Wyp1
#Le/o5aAz4c5nUueISj9aiDx496aeu4jJbIVflvHz9SfKxLK68Y/e35FpbrKx0gj+7ubmK/YQ1Wx5hbpjwON3oIFzMq1CzNxAU2cd
#/sSLmPKpeZNpnq90cPmXKXx6GXyZ+sVFrQ/qpSpd57KL1+mCx97yvzkjG/JQAUTCxU8YfBM99pN/+U2d70fxtZY7XC8c7PWlhNcq
#jEUUNEsjvjB7tv4utF2Jl2IippzBd7S4EOWTXEzvu2z7uop9SK5VITUoeaQojg8v+tw9+YZQayieKPZPB3GF6XituYjst8fb96Ue
#w68EU7qhzqmDT/T9qbVNJNYZ+hm2aPriioOMQpWBB6nnOnQqyvXydYzfK3zFtddVTFURDoPBfFfCXhOfkLqUK6r1VrNfgDI8/TVs
#7u5MZpuau5iKDa3SSOFZ64qpeIwqLd5U+l0Ii+sO0kHsXV1/igZF9QXpH2GMdbODpMXfs8+7mdcQpQ/Zpdp09lbIYYOs/hRJrv2Z
#fN9fLZ1FQaHYe+dOl/sVyGkmHTFhAZbbYyw2DP3F8xsND2bSEmwZhLNM4tcbg/rHPIQUxh7k5uyQEECuimDNVWpenCY70en1mBwR
#1Hy6hX9xDrRJLabuVqZRUEP+TZ4z28HkAzKUf3ZVp/cTlmbRXf41WQGjwmRrz5wAfNjZzqamRpdI9tFXGhQPEey1zr326xii3ruT
#GWMSCU4f+04+eqrmVcp8SpNvCq+lI7MnFOssQ3A287rYF/HER3FIRUuhkheV3y4gTRjfirGeiSWr/+lX6d25Npz7IDtvdM1EcodW
#4nHm8wobRudPWUUCQ47KDAUj2mgURfkZkQBBamK8wCX3d6FvaxUM7zxCdzPVKxs/Vuh5toX+sMCYOZBFZ766htVoDvhsd0s664H6
#9vzSdGcI3s55g1EqKDaY2u7DnNunW1xl8uxBrb0FootaD6dNZYwskE7dn2CS5JR1K5Hnnb3OSymJweLuvmD5gT9fnDcqTxl5iTjn
#RT5eN3UWH3pIvcwtoiO6qbJa4dRZQRF/oju5VQkfh9agOWpPBuTcXsDG2FM/vnAE4Z+dbMper66RnIU9qtEjyXnNvWLmw58mjfwq
#kh59usNUzTFEAMGO8CrjYbnK8c5kxiiasImnMEuIT5WTZDqaw2PpwYXuhl88PGmmhgqW5bfCvFKN7cCdzjWG9nRqg8EillquIe6I
#YuvY+jR7nZMk7MqsXp/Ybnydfi8eLhvnoTRGYXxJ7eW8/sOHjmdk21UEFesXZlUbf7OfxKeSKqO5Zm9d14S0D/gzIFLAO85NOYog
#/S2Edn0YSUaf5/jGyMUyWnTdq573jvz8TGO41ix+qgKjEKRmdlZVIiv0qnyh1mpSbqtrBKdG+xJk6P5rr8Dy8Vqpb3W/f7zeWfgz
#u+G6trAYLXemyrn5s6tY4QWrbe/7rsnUTOUqsoL29gZY/vFR4reKdui7q24OZiQK/Xp14YTnz8fI+9pU1dRfjcg15M8LWiqfeIkp
#EJuUX7bmxlOjr/4GcrPf+nnp7bkGE4EC703TVc/73HrZ2stvmWZgoh9m6UcInOxMKsf+8BARLbgNBdMSCbhiPKolharVqYyXkebU
#zsKLymGJopKSM1OflhA/SQmi4Ve4mhbtLZYYPdmShrmMSp6pcltJ0D4etLE1Lrh6Hc/H/0YA5zImgiSxp4bjNxWM98ZrX5+b9KfH
#h6vgj0sXrGKyvze61yVmPApNT51faarTLVgQJbHjvFEte2nIOfOiua1Oy3X5UZFJHozpV6tuPKQlX/ek5Cji5yeRK3I7ZGGwjyQS
#EIi+DjkLS0OR4vwbZWU1l6yb3L+1iKJnIzeqh18vfn5GOlhP8kRcQG2q/OXlqx7xX4ye3qCNUv2VlxhaOAnuuz4UkSsabCV9aZgw
#HKGQ6p9/uas0jbTlhGg6B2L8oxKnwMlHXylF+4tZYmdniEJ5mq50abzPkJxa5mcf+sh94bu1oVuLGim9s+AHss+xTJWkHcIqxALi
#C+ALP3+VCvonFBj3PbP4pFHQMPN16KnlCw0ok5b0mQYD+PWEkRTPqw/WRTbMXlQLc/BVBKq0eV3WOsEf7FwaSvYwvNI9yaFd4UOK
#ymwCN0UrK5/dlxyZ3IhTc7f/6KeXeMT9RM/450j3BX4n8F8tyh1COX/T3ZDwkrNRLGX6cYWl/9bvYKXWoPMGnb9rZMyfWrz+wNz4
#NCXtYnqCbsVj6fsXrmWUoL4ZfGy5WQnekPjilnSxj+bmwDvX5060cW5OGlYJTN9vZW2U326K/y46Kkyz+fVH+EQx43kvGqfFCeSX
#nQbb7wsbazFCmU9P8K60UntSpxpTZk7r2t7JqF9THxkP+t21lmqRGv072XGaH4FpUy0rOtEX4Kgq3bSynbdKGPDL6t4MuOrbg8+N
#k23WFpZXLxSepO0sYvXx6hmdfdLutdlZqNHgUt77jaSCMC2G29chDcIxuerGrLBaHIxHXfrLTp7I5E5izutudqjSan10oRAPIQZ1
#66fFA90NAAeecjUKT+IvsVeWNOKnfKIQKG2ySlXOv7350Erwytuqe5fa1hNfXreqk8ykcsqacvfrKUwutzO74ezKxV2ftLDd+TYV
#LrPwc6FhJ3PeR1NPP/KCd2OCg3g3wR+oSWFoyTz3ZkKuQsnn1TCk5v0wd3eK92/0JKwpi3zWA02uPsJwn5PjZIsZza4e9ZcS4pH0
#TqV7NuYd/gw8olKfrH4OEiI3IpnB0nX+U0yu/VWnqTj15ofTD/1Z4xkG+0P1fEbIp/HRktDYctGm6Qs9Xngh9DHnvl8XUTJ0XOlJ
#vZW6PZFd+/sXr9/KFqrrynit5NiVysp8Xd3v/bc+G18U7X97ikynZgPWI6glTNlnHP/yfY7KW6bM90qR7Yy321+MdF0Zk5R6tLpk
#qy0SQkhDLXZ59G7rahe1ZsmccoZ500hV+/kPifhCFCz8re+pn6vEvDcWdb7g8bTTgtkoh4SLLqzeRtyj9vdKTBZrB7kpNeXA8qvu
#qw2xefPtpPwBuvNn1mQ174S3Za450/KF/kw6aVm6RFUjv5Pf9uvdiYvut+IGMIVJS8q33rlPRCOi4uipA+xqq52ZPnS7mJ3PSEDT
#sxsoh8wsyV4TFb4jjZjZ4dz+SlieRb2arLMekhrXahbOa/v1xnxXA5TWjE5lTquUNZkQP4qeRZTZK5Kd9H581LTOEs21B4/vdoTM
#MwuLZCveKvDgmu6eDbB64q6/wqB1ikHOiHlUdJLSL8R7BVY/Ve/mfGHi5tIz85CBurQUrce2mZ5UocVshuS04bClb3K1PDaCUgNt
#0+9qBCZzpnutghJIZb2VwpVmu2d8nqmq6GsOEieJXPfU9nWdmqj92dwkniiF3yNWsXGP+l0geq7K5lqtZFsPlwumGyGy4vR9raTF
#mlE1JNIneiv6h8JzJ8K022Fnr1lNS7m5+5VZQxvux1S999Fr28YTeFsW9fTqpmelcZCNUr/m9zGJ566e+S9/vZMJg/6mryGkLrwj
#YahFAZm7jKINYKDiue/5ouna6T/nGbWp+jMcynqnx5wt2AnPqyMk0qcDp7ZFdJn5xLkreag6HxuHBFfk3+VMa239MfjagtNv58W4
#RZdHMkjLZ4Xd/yTVy7b2x+SBKgNl44tkqj+EFETmbrKxnYjxuezmdCUpZnvzOW8OL9EXzNLL7KCVjp2o3/zNBKaW5emffS5L6nPP
#7qxTn/3hfPZsqgcHXZlmEjXs5A77mqKTpslvxoDnau6vIvMGUdSJ8mIb0+QU9YmRcC9TIaT3pFyH4dTUvOeriJdDs6upp95W1RhL
#WT8eJnn4jPl0yiOjKU9GlrWaJd6oEN+CpHM8BJXxvobu49wChHZtpwQ0AF1CStYm9ri6x8A45MtTfGVmSwsapM1qxfM0Vz13rL/n
#c/8oeNfXUw/EcoS8Xz1IPl/QJwBOnfOkz3pnGZLcQuXK9Ki0rKa71tVXuA+vEvK7n1MozlB61Mmof3AYs7Vz2XHb41FuPJKvGzkx
#XxHDEnuBtpG6uayu4za+RUuNPCmiaqit1SwwKeu68I1SVS3O2HOIIg2R/LIeYhXHq8zxTkh6KoVH6RI33BwYWoPB6b6tKcJPbYjh
#l/U9xl9m/FhuokHPztpYTGQiJe4GfOGrJR6hW6yOp/hmxfyD9JzrgNlHh8ASq0xYaHUSkSiY36io9eWJhuzt7+sXRO79TAkus1zs
#8sg0Mo+rLNQSC0iesfoO8fDi015Svye5k6K8+u2pPt3nZVTblLGYdn+WX8FbK3RbDv9lWorzVvxC6gzqxvN3MQYe2WvKjuEcQk/O
#rEh8Vit5syaWzarhX93b3SMFnRMgsdngkPozJpI6Xisxemna1uum02UTSe7L36ddyANWzKSfnS6Im49opiGSVNx2+PTYhFTyzKlI
#B9EkA4Oz3kLtxJH0WK+ZQcztJm3UUFbO3ZRTGblRASR3jWgaM7Xm2T7OXbM4Vyxp9F17OgnLtjY9aRQ4UpP0rMzBt0NwNu/FSQK6
#sRqvYh39F0CjPp3Xa5RoEd1sxwvMp3LXSWaCKx6Ks1VIJEXqN/XmZQZVvJJ7wW2y2OGerMIiisn4M12J4ouyj8+wB1xLCyy4JjfQ
#EL8WW1AdsUKQo7ddoQLmktO4p+s6iBgp15O5aOv+ScBQIVOdnkjl+sIUjUN1kXf48qPF6C+K8q6Kjwm4dT+Ya1ckX2j2iGWruhxB
#uhCW3BqSypnOPjz62c1YKsv1fQNbxoM7faW5RK/l0q/EbaQ7nT9r+mAAHsMWL9MfRVTrFMjLJP1mdJiGfHb57I/LP+xqhFANmLXh
#kqv1JmGbY/O3mJomb7tEUOK3r5Q/u9Xx/fs7RGXWV2s6wEsmZoaXZ3+7BpdfuU1S8yLMBM0cPe0TM3k9so01kpt0vf7j+GvJR6vD
#vmUN0rnuIsgxX4/3CQP1bToDZte5qJ2e8Gba54vJZn3Mz+3iftjgXmjzWDGwmt72on3LF4Hkd+6yQt/qGX/T/64pafz5pTRJuSc0
#tVl1pf+ursQYh1fSFyWuqpBLIs9NFR2GBGTZb902rh9ilMZ7+nDA70oXtrjoPMPTJ1K/IGNjRHdOx9h9iagPunrv5DI6XhJVMvuV
#teYCTCHAVuhkN95O8oZywDDnjbvCS14nJPnvdxpLxMSu66aRGMaVk5uPEHvVyP556se6vtYw1FfNjjmd8f1s7TKYSM+qseXi3AD3
#iYGmN8oi2Q+NlBJsrOImfaQff1v5csLZr9mflp//Q6I42VBnqGQqa4T+xOJYrrVZgvuZlY8Ph90gNy/0VNLfu5ryIQujEt++5tKV
#MsCP5iPUzmeUCvnY5t0TvaV/wensxtzdZVcQiY2dVy41U+hnV6/Y5DHjlDwoOOypF9VLYZVPgV/vUpIM8iTnTSqOu0OWv6iebEpr
#Pj2/KixoDz9bUFt8YjPusn5wc18kuwbzNUWdToSKihdjto9x3OU8BmNBlD+M73J36T3/rY4rfqlrLxiqZNFtIcqpdDHQ0WIO5rKb
#TVEbXhYraw7ycvEfMtdG8vPVFy///irgYnnNV4yblvfN7CtRnjOEIj+YFO/EN/RilGd27p+5KEwz9/7poE3L/YGVh02W+cyD6Vpe
#gqdIdSTgKHFzpdbF3OIdAsVPBvRneHdmSSV811a+Z5/1SeL1moqaTKh/xjPvNvWDMvcpCAO6RsPq/Alb3H2/vgftVd+MFjShR/QM
#uk9xx6v/zHLusiX53Sn5HYnq1HI2vPXuvuBkNYM01UMoxDaFxNTiB8Pj55+HFoO1ft717fxQuK7JTKFCTcFUbHeVXzrlYeIErZar
#7uhY/9neItXMxTkfXc2zLQ3fC5IyE/N5hTUWDIIy7oVOzGckXqW7/TRGnic2cVvyREaM/csyrpePG2TaIuUlOWN/RdxMvKhg86Ia
#fktX5GX5pwfZEzZw2oehcB4rKya/pUYZG/4sj9ardwU/3+CAzSfQEFzjSaf+cTLLjTBzJi5tmc3POiKsx8n5uyqp7Y3+bgbPhvBK
#0VhNcfWKZ7DK66Y5YteYvEUkh+cETTyy/ZWdOSInruQoP+EenJ6SbjYXUSqqcPNmGJ8Oub++FixpQnIzj4NgkuODXpUCcvJpMncy
#F1m7gJTl+A1dCumRneWNHZP32as7qhWa+H94/V38PyusV8ac+/OK14s+1B5PlggP79bOH9hF3VsTd+QskU2XHtZJ+G7JTtSaJfPg
#j7Sk2VN/or8NFggfPHmhA3PKmab+EurEtUDaNLv306jb73vbplZNOttkJbeQF5G3+K6YQ74JQKind2rfpjZGq2hvU9318GFXW7CX
#r3MUO98Q5KH/OX+KffwRXSJm28tPVBMuz0wbcsPm8jvflJS+c55fKmYk7i9kehYS1hMqNEMbRURudp/1MObneCrO21Sr8zVuRXLp
#M5Q6WXyB8D1toj/VpSUrlqYdeITa/RUnWAdKgKpF8Oy1pdYhEcHOpzGx6mZlkciuYrcr5F1x37aN3t99hwnzqXyH//4aj6TMSsly
#qz8VVf0jR6drvCBNz8+PRHWNkEK6yPC2a/herDdjnaiUZcMUNKxKQpd39E0TCzJjTlq/8mpOFka7xCQvbHNEndQdedG3lg4yfe1g
#US5VOftVcouqXfeO55q8fMNsUPk1sOTlm+ZBHUlXUpqKC0pKbSRiEF+un5uy11z1nvoddy76zsjy/TgwPLBpO+mVUwW/2hVKfEYY
#ntJJfkL3WGyb+UtNskHdwpid82o2M1OWhVOYEjmRTZ3WYLRaWsb5p/6PBT8TR4yc8PGFtz5Jzfn1allnkyrDnj80RVJWkczCmMUG
#/OU6eYNNjw29nAFjmFW5UR1Jp/SqTV32FfzaADUB4sZpQxb5ae8MNhFI7XXysz0UO3xs9wJTHXjO2SiSLbRZB+B5dEc+T6SYyB6Q
#xbNE5stp4zHfo39BRVhnqByNlMN3rY7SkkdfYDGcd04YjRw2In5eSSofxkfdQiL9nPJBtK0705M7XIJqUedZIPZCIzlrirqb54zZ
#5AOxL+/eo8+yiH8frmevxaIQr/iZ8ypDkezLGxo0eZF644I3mW6rZ0WNc3Ek6BMlJxoG9+iNDJ42FJvXDBdtenT3F01lloiEZj7s
#rpOwu3+GQzGpRmLUGZooXSctbWSRtn0Y+/MT2v2qrOdnFX7VaJ5p+flbon9R0DgzK5E+V0/RuMH+etDzhzT6D8buriq9wkxyTa6R
#LQtGi+NdZKSntXuk45AvMOzzJjkGXWPxU3ei3L12iY5RK7as89qPWzceOEW2b8r5v2fTL1r/4C4e7M0l+xT03srMTf35vNVgU9ia
#yS09VgehGkNTJvUq9vNiNg5j5FJucvC2+ywfT7NECoidikygI9sgq5dN74qcuNrveS6y7IO8OM3GO8TDSreisc1Em/Bc9vn81G1i
#z6nYwOjNJvVOkQCrhDqdDnv7WbMumUpnvwalcIGEJwT3clRSVB+Wz374+tB04fzcff4YNa/mPijGwnipk2P8zxJvWt2t8vWO8e30
#rOk3NoIOQmX60UnqGnUKZ3UEgk7Ftcrcu1H97f43Pk2XmNdWtaYqyahfgvdZ+2XfugTzCQv6PtAiSxm7Frv1Z2XluZAKK1tkKF3J
#Ndsk1OMTWRyvSIJeq9loK9DpOq1OhvOmN96cftbtK8J9d7LCGwnuMEwuyn1zshypuOUr1N9ibM1CePOD/Qk5aJlSib2dmvjVbhHC
#VfdV9zMz0+lMBcUYvqXTLv28F/hsyx9c87axtYnhYTzxBeKS42Jw5Ra/C/GX5aIkEb5oX7asy2KSanc6W6UVCFJ5v4fQtLA65Dyl
#0MqgfiEfSLWhx6wlcEnFVobtlvKQIydZrxYjvRazFiMFNYheS4CRAuTy48wMuHqOhW2KIrfy4cyDpZPXtjy25Zhts29U308auLlo
#XvNsxO3pmxHNpKQtLeGkTvoy6wGlE3pJVWM5lVGlk74Yu7eakac8JgSrPoLT0RCdLcU/6zN1Wpr37drnU6He91layvlShgW9y3ea
#9X6b2P9sQWTHJIHFfM1X6Ufxo2m+qL0Pru4pvyqo3piWuyjm85L/U1252rVPZfR8xcrcsvzq0iF6AsQdHe6aro/b/Nm/nv9zPium
#mfGOzKgSRo2/wPN2szS5hvIsl06SdQ3NeYabrAo7U/TcF+XIbVWzQ0W/7gzIMjj83BqNIsZavasZYWhs6iU8oVN/Yzr/cvb4Qlfd
#ENgG+Y1U8Ww87SmC/8d+uvf/yt9fv//sDkfaoNC8/7fnwP3Ks4iQ0H/5/ee98l+//8wvKAB0ZxT6v72Qf/v7f/nvP/8b/WFIhDOc
#xxmB5HHA/N+Y43/+/e+rAkL8Qv+gv9BVEaH//+9//z/xx8tJxsjJuEdxBwyjuyCPAA8/rgpkDWYEyMHHqOLmhIAhGZVgaCQCjsY1
#6cCd4DAM3IbRDWkDRzNi7eGM6sp6jE4Ia9xPxR/Cc8DwWKOcgVdeMjImWzekNRaBQoKQEDjYmxll5QC3xjJDoVgvFzjKlhHu6YJC
#YzHs7Mw4mLYIJNyGmemg0Rll4+YEl9p78Ox3hcJBYDHmA7BHkPZGs7PvPXlgzjZSe0UQHCyG5NldGW6sLwhrj8BADtcFLMoNA2fE
#YNEIYGHi7gBTIKHebi42MCxcDOnm5ASxgtshkHtFJxTKRfbo1doehrSD/0fF8bIcytnFCX4ACjf+7xrr/2gX44fYINDw3dWJMe/9
#6D4zBOaGRbk4wbzEmPggWGArTsDONG1tMXCsGJ8vBA71tnFDw3aH8MMFITZwXFc+CCDX8gdFGAaBtBNjxlFQ0w2r4ATDAKIP4ocw
#8giBmSFoFEAAHCgs1JQZi4YhMU4AAoyYIUcvxsdfTIAXNApQH/DDgtFhyfiwhOuGsYY5wQ+eRgcF44PCbhdHuMf+w2j/iWt3gaMx
#LjhMuOPGO8MAGnkeFgRtmM0haKi3nK6umLcvBOOCBvaHAYq+4gfEZYTh2A6CBXuj4Vg3NJJRHYa1xyk40F4B5rnLlkAH38MhqD1O
#3R+A5EEAfOmpaQtwkSQ3/1E3t390A7Spkxdol4hwsC+OixBQbxgaLXYkAIe9ZdBomBcPArP7BOp9IYBY/FtHFEhzV154XABsonCM
#zoNF6WJxG+UBUOcEdIUw73VhBqC4YO3/DQqCBwAPvLOzI3nsYRhND6QWGgWgFusFYgagwpzU4Eg7rD0OAsbd7t8gADCQgLpEWuME
#TddAScEJ7gxHYn0hCKTL/7L/dT11NWWkC47l9kfZoJz/dRQPEmUD1wN26eOD4AGWsosaQDD/pTMzZhcLR+KP9IXYIq3/red/qgqg
#L47Z/2UJ7iiEDSMfFAoFuiARTv+OTWAs8O7jgyP2Xld7uOe/dOUFWbCY8nFfk+FWNPcW9mUF+xyvEAQqeBE8WDgGu7tPtJ3Vv8Gw
#AOp5j3rZY/5tUbwWQP2xXtao/7J0YKG7S0fwAGD3S8DQ3UGOcK+jQYciw/QfPIMFGIkJ/m+1zIBFtYNjMYAGh2KBVwCiLRrmDN+r
#OC6X1rhV4YQEDuU1A4FMLcDmXGAzMC+g5OG4NvH9FcOl4Kb85jwYFycEFgRIPhiQWRfQv2zNBYbGwBWdULBdBIDFTM2PRBWzJ6q4
#6bBQHHQICgoD7dERa8pnDpbiF8M9ITz8EH4+PjDE7VgzP66Zj08MVzrsgDnWQWC3gxiucNhue6xdEGjHNQseNTtBd9UPxhWNBbnx
#osAQGyiGFyTAeayWEwUGQ1ygNhL8Uk7H6vm5bThtwIA2d4fyQ+x3m0E2nE7ctmBeFzFuWy6nIxTbHaAYCwWwyInkBeyCGPIAsdjd
#sbuAAbsK4sZyAmDAnCD3vcmsURiQCycWzGW/PzmgMnHvYDGQO1CHBXMeH+oEhuzKjI8PP+4hBdggbqzvIQmPqZQDoqN59tW1KdJc
#HIFTrge9xW1RaNDesvkgMCifuDgYaMfBtQNhuaD8vMJgsDdQw8UFk4TyC4Ot0HCYoy/cCTDhuN64kSgolhOE68gJbPlgw8dnhKIg
#KN8j/rD9VwXAzg5CQvlxxDxYPPxvM2INRziBYCA4hB/OLQzhB3MiwbhpAfbbVf9OEBuAgP/YOQCRHzDW/LwgJDc/+IhY2L+sCT+3
#ICecS5ATebRG9F8dgGZu4ePNsGNb+GvcrjWDoA4aQSAsCPfKieRC7xZwJWAPuOc/bNvRIADiwSigtwAn+gAEbuABmY80BwQNgUEQ
#u0Tik8DpAawElJ+dHSjD2NlhQHkPFdZQJNyDcVdkBQUOLCGOF7CAskD7+MCABwJ8wA0YgLYYCaQ4FxcGbG2KAUgIwnAClh0CO9QV
#/6IVsAAh0cCkwAMBcOU/mBQFwlEeWC4C/Bc3oMHeB9MiACbEAKJmCwXoJY4BlmTLzo6bXwKK3l0LggsK32U6JyiCC4Tmtjbl5saY
#g3lBQCcufnNuXF8wsFAbqBvI6a/l2khCefj4+KWOO8hAh2OT4/gZJnEVmAe2hzIEAGSvDw5PuN0gjuQGzg0FofabuZGAaTkUQF8Q
#GrI39y4GbKSOG4e9SYG2w2ndIAiINTA1yA1AMgIK5wJhueFgXoHdXgBkST4pLBQhBociILtyALPCgNzAkoAUiLCzc3FZS/DziR/u
#EoGbHAFBcO3RytfXFwQGlBfICeqN82Bh6OO64b8TEgkMBHDorQuM+d8bwc99qMiQe8pKS5lXAFgARA6Btv4/grGveQHmxw2XhVk7
#/m8uGpAXECCN3LvTygIOtvX/avEHNACwBb0qjpQAgeB7tsIF5QESgHBzAyoYUBy8/PxHKObnPexxFSII9OAW4RESFhDiPKwG4fSF
#AEBCAW4kZHcx+97/X3wA8Ng/lB9AqYMaILAClgJECuJ7uhnnWOOsGSA+UJwOBEybwP8kif8QPcBoHNsWPx/nrj4EHxkb3Ds3+tAo
#ainvt+GCGEDJAmjgPNbGi8ZxFsSUWdsNZgO4CXJuVghr4Am8orG7TwQS91QAQkhmcx4Aywowa3vQ37u3wVmG/y3CHi4dGMeFw6cv
#GLLvqAMuDwZkA/6XKQ5MH24acSfT3ThMGcnMBUwKh+y/A3HZbsWxhWH/cyHoYwwK3+0CcCcOA5BDsP+ngNASPEJS+7AABQ+witgh
#bG6gggvHPUcTAOD3l/5/NAHo2Hpxs+CmAR3NCnAAF//uPAA+nY5ZR/s9AgE6D8EDOPkALg/UHnKfHZEHLiKIGYzz5NBQd1OsOeA/
#7DqTGA8EFqAFsEBrYPHMe44As9g+jD33UHy3yRrHOLLwmwg4+rDdDeSCU9t7Q7FwF8yxFltciw3cFubmhD2qRe9qur89MSza6wAX
#NihrN1wgxOPqBkd76cKdAMZBoWV2wzlfaxhuqYe8dgyM8x4WjvwjJI/TbuCGE0G03S5IzH6VJFRA6rAO8FzF9gQZQIipOeD98omj
#JLDiKC4unG+FAoI1xn32dIMiTVHm4vC96BINcYOgILjAEcbj4oaxB9T8gVGBHa3L668QDg23cbOG/0O0DlutUUhggwAZgcgYcB6k
#vHDJGcCJgJiaHwvBrf6KWXBdkWBAaQDDgKhvN5AFtJPdXgwGhvwVbGoAEaQaAoMFWv4Zg8qhnJz2sipSpkBIgctaHQTRYoBMHptf
#/R+rxqCc4f8WdCBxitH32EDPIzH39j3yZPcQDAc4EkAv1vwwuDka6HE8RMFBORyM3huMNUUDeuKfQRcaDMRHaHMxJPDPoWd/BNXx
#f4YK34O6H9ACxf8ZmuZfVNmLH6VAWCgvUARiODMbLogZhtPUzMb8qICL6ez2gjo4FBBbKWagMwzEzIULp7iYAa+ZWQwudhCXSoHQ
#UBwHuTjBABbitWCRApnCuG0BQOD/LLDyIiDHuWzPdzpALRecCwv8h+ZCA7oEBj0Oy1vAF/zfygDQvdWiwZCDpe6GlspILAiGCwGB
#kANY91+1Av9aK3hQC+wRLHYQZkv9h0HYc7+gvED7HhbBOOyBAPTxAPhj++vlCJs43scNgf0vxxx/OT4eUAP/2BkfmFdQmA+Ifv+x
#N6AeCFshCOg/drdfbw2FmV41B2z7kcLG/CPthpXgA2QWF76BIVhJflyZe7csAYRpUkguYU4QHPAsObFi2F1DBDwEeAWBhr1qEPAC
#+DWcwmJI3z3H1w0Mh2KhaChCHBf57SLSForAjUUAMRiXG4BwLjduBKcbEGsLcCK4bcXhUAzggNtCUFz8vILAzAevOAdmv8iNa9lX
#cAfEFxASAkIxHGlxJexhCb1bsuZiBjP74hTInn4VP0bRI8GRO5bsMOXiNpcys+E04wH+5QJJiZnx4MgnBZRM4Qrm+824CjYfF08f
#F6wP3NkHDfyPQPpYO/s4O/vAPX2s7X1crH3cPXzc7X3cnYEWd2eYp48N3M4HDbPxwS0fLMV6lEv5K74GKH20Mq2/FN2BcZUCQl2e
#vVQOBM6DsIHgso5YmBNY7FiMqPwPHQl0lsFi0QgrNywu437UUf6AF4BlqINMsRBmYKG4/PCup7aLa3OIHC4EPYpl9qIfNI+crq4p
#IMi7KQKmPT0FO+wG2w/2D82pNRoOw8L3s4wgJLAFOw2YMxyXz0HyALwL1OLMAy4NevQGhHQHAKSO14sdgrVC2XiJu+ESvHCkjZw9
#wskGBHANCrBFXk5wwA3EIHD7hDIDcRDKyQ2XDz9o80DYYO2hgIxwYcX3Ql6gzIviQe3m7Q1xrQBggLood/gBYPG9aNea81hGC37o
#WR+hBIqBYI6QLHsMyfBdi7G3hD2+QwOW41Cr4tTdTZweleE2AQJVOwgzKz83qwAzGCCyGsoDjpYDHB0QTmnuwzCFA8INkBd3bgFs
#z0YXVwmwCY7kB5bIAObkBgeUpo8PMx/zoe2QwtEeBixLDHbMj9H7B9PZoJx3bTpAYATSZc+8A2Ukwgm0x2Tgo3QwQDtgOYAZgR3w
#GrPYEQR1EMCwQOPuIQVg6pyPNx6rZdqNZ3ZxBvS2xgAeHS6XywTFAZc6OKPal+mjhSvg5HjXCd2D+Xe4to8tnsNpAFwwA8qFF2Tm
#AWjevSQn564KxuEW7gGEES7iuFTYrpxiweJgGA/AFiCciELguLyi+KGzdbQIxSNbtyslEFyUDj84ZMGlMvm4QCgQDAgqjg5rmHGE
#OX6YAjguMClmF09mMaDr4UEO0Gv3dfc0BsAMTlD3sQAG1L/CPtEBfvTxcTukMk6bH+0a8EAB92tvIxAEoGj/agKiTiggkOhdzkAA
#mxBDHG1N5mhr+x77Hqvsu+3HqLo/9R4u0ACD7XvvmCPf/EAi9lqOsct++x5r/dN3R+4yO98xfGsc96F4LUBmnFAfMy6oDzcU/JeG
#ZcL+HZOgoXK7Rhrnc/8lygd2dz9ZfSiYuxloZmbwUbgCVOCy03u75zpcOYwLxYXe2xb3USX3YSXnUSUnUHlsL7rH4ihrlNOxOEpz
#fxe8ZhjAQ9g/R/hnkCW3my2D4vQkxs0K54rzQQ5iEG7sfgF8lGOGS6G54GLoo/nV/pL8o9zKYTwN5/HkRvJ4QgTAXMfqvIA6L6Du
#mFFx+GeyBFDdKCDGxwDr20sbwySwPEg3Zys4WtNWGQt3xojDgHDHez8/jGNjXC1gTsRhkjjnBM0FVdvLiELgUNRBmHNs8a770r9r
#6vSOjs3Ax03gsXrQISEPLdHfGnafsNYItLXTEV+ioEjIYWKDUxmEAqSTeZ+L0btqab+jANAI6BEI866VYQZz7VZAmO3hCDt77MEQ
#XJLtcIgayNtTTBnnZEOYPfmZwRAv3BuE2Ysfd/a31wa0CBxrAcq++6BcUE5ef4HDEeGoyQ6FPGzBQnfd/QOaOABsz6UGOsL6P0jD
#jXMFDxv5wHvnp/t+FAR1RIPrx4UR7uPj7YvjRx64k4/Pv2bR/rL74ntGBA7Ygv3SsUZA+8KhxyuOgjQc1+OcEWB9uByeDQJpJ+eE
#ALrpAOQA4eR5F1XuCLiHLMqTeff4aM/041xjnj16QDDAOve7+PiAUFKog4wFIxAdmPJBAL8bYn2o8r3hTmJoyH5/MQwE+B9QBbz8
#AF1w4TxQ8BBzg9iLWUPcDYEawEt3vw48Bc2PSbvBgU9w7BABeyzJt6u4oXzgfXUFOBWSUH4p4CHGJ37I03CnXTOPo6MMdp+x0Xv0
#gUEBcgAdAB0AYBOHBzQIt3k0CEdPBPAEHtaAuuAXA/DBC+NxN8RhYffVHvd6/UhAXPb9iH2Z8DzgJBAK0AgwHk8wp/Uep3kda/EC
#WrzAnJh9FY+0OyZG/KJ8+wlDLAwpAOg7L243QIkgAHBuADjefQE7hi7WvxT9/7afDlhzNFQXmMAFa7/rO/McO1IXw4HkYj7wiLxR
#aIQdAgnD0XZPADBiaB5n2F5ySuqouHvKqbHbA8cc5pC9026M2EEGxMcHUK77HITdPe082ojhsTgdcFOkvEBHOZRdwFZgMVzsjhv2
#jwj6KGA7vPaABP8zyWF0FM4YHj+q/cfR7BE0771YAkAGwkYMC9nFjxj8IHl15B6IeeNcBzGcm4FLAR7NaPx3HgO+Z6os9vJ4+8fe
#gBbYveAC3nVHDi7DAKHdYQPAk/t4OPCKD4yXuMDeORHT/k2J3TNhJBToBXi1QNAjthcZwQ/BAvg/PslRA++hbBzLW+ESvgcW+V+Q
#tLeWo0saTEe8JHa4hMPzlN0gCM2ze8EHt9f9IiBXfABO96ohB70Orv/sdTx4g+KOxWAHhhsQeZ6ja0KAgff9r4fsjrsLPk4Zk+OU
#McXlXeE8h6f+h9kmGC4iQe+eIDiC/l1RO4O8QMj/Nu/x3DrudP/YmezxlBTQvtv8v8hBHl3owWUlkHuZTcAvQ+5mIQFfYteqHM9h
#71EUlxsTx5rCzKH/udD/lvPbWxQg2wDKYTgE8OwSdDcNCBb7l4wgYIf3vJcD+dh1W9Cgo3NDrC8uOQXH+Sn74GEAebF72/BGAogX
#A0IuDzgciREzBoIJmDkEh5R/SegpHSPekcbfG/r3Dg9x8I/zol2yH9s1+lgqGQbV2k0q4rzsPWHArRN3AAS4Lf+Ug0Py7GUkABLv
#bx/AGdAbJ5CQ3WQlzPdQQx2K3zF3+qgW51HsScbfzXsCgkMiZNcXh+1RBLBbe4tEgaVQuIQ5CjBdciA33F0PmaN0CJIHh2CINW6s
#LSBzQHQDhPMHWh0DcToOhc9czBZiA0BxAvSFHAiDu9Bh7eNj87csu+GE0w1qCzgZPLZolDOUFeQEccG9YVFAWQPkBnEC71Xgbqxi
#d2eF4+7qATXAE7pfzwXb2xzuuY8DLtihZOP67qpBqD3ooAiBHcMWjAeB0QKMInRP+6COavR2t66MxCBs4LoGStCD+iM3ag85eyPk
#UE4onDbDxRd7GzrEz7EOOLLy7F453E0DQmEQmO+e5tSGegNhnNh/sUtHKQkoFpCUg6juf+j+V1oKp70ge+H9fx2yD/vQLP3rWTlg
#f9DHA10sLmoAbMhuhOvjAzsINHCmf6/fv585orgAv4sZxMyF5GIGMzL7giH/kUYAgpHjN6du7g3EGeF/PWT8SwEd5n+0QDhdA0Hu
#pXX2mRkFsCYa57HJAHEDdvekB3DbNEC6gGygcBzrBigZN5wPp4frABbXNrU23+2KAJZ5ZLchTHzgv+y15V8a939U7f/wGuD/eYZ4
#TNPogZBHeUmcIO7dFznYpBJAiD1f3RR9aN0OdKs37u4f4H0ceJpiexAguHvBgI9o5QRY2QO1iYYcXqbdlaD967RoQKL3ZOzoXu2R
#hOGuNuzprn83UEwHFwePY0rn+PaOnef96+3Iv6/9Sv2zAnd5F4bTxoe+xqGGxEod3Hfdv6eKe4X8V6Lg/BYu5OFwYD9iRy4OBHbo
#cRzcpv0/ArqLqz2IB4rp0C+ROloz9/8vK+ZGHpFld6ojNbirZFT2b4qp4nwW/f+4pHUkbXAcdx1aN6jqAYX2bDRa/EDOVQEzK44C
#wkc3DNxGCqS665oDLggMAqg3NDc3WAyIV7AIa0cQTk0CFt0XCYVJ8kmh4a5ugPcqs8uEwISKOMcJdya6n3vcP4z4l7vxB+lpdvbD
#RDXMxkbBHSjgzj/hSDgaBMSkGIQVAggSvPYuozMfv/YOx6VxMLiktqE9HCm/D+U6wsYGvnv/A+gDOMHWuBNUp38sEAnsR/Vf1c8h
#s1qiDkEaHK4CBDA/RB8EBuOex5aC9PHBTcfO/j+tyceHCXRAAEk+nAuOhP43/IFx94yOyIg8us/BxPQvmLPfneBILOHIf4mUvX33
#Q2XcATqgNXEnYrjTL9wNMVz6+Gg62yOX0APwNlEePFqAHURgcEcPcA/G/Zd/wxsA6chVQ/IANEdg7OE2UDgEfnSpEOIOsYfYQbwg
#VhB1KMgGijs8doJice6FB6ACnXAXrExALriCPdQI5LSvMwH/ww5qCbKHuIMhXlAdkB3OqbCCqkBUuLggjiAbiDcQnllBrHEHEWg4
#EhcdHilHjJj9/huwYIyY3ZGG9DrSDHtq0uufOtLruDCK24LUj1HG8/BipDrP4VcP4swwJywcjcTlpJn2biMda4UefBOBa5I6eBFj
#RsPdgYAazgyGqPPsl22gTEdlCPp/5tjDMUdDjqvq48ffRz2k1I8pnePnY3LAxvb4RBNYvLUbGpdY0gMU9u4lURyfu8DhNuD/OIsD
#eAQOOBVwINbihv9Dw4P/On47Hj7xAT6UOs8RgXbTYvsBBPyYnsIC3g3uxIDniLIAF6P2nX6AmRGHhhPgagRg78WtAexjgPgM8W8X
#YZESu7rVF3fpxscHc3TBAHcDGsmN2XNNgeceSwCicuRy8h6VcX4zRgOmAbLFHWBg9v1T4A13MxrnYu/nPwAOx+y5jQCLA/xpv9e6
#n0s5UM520P3bLl6AlvaSsBf3Osj8Wh20eP410NTLHOIB1Ox6q0d1Pj584lZA9Z67K2UAwuzHCk6cnhDMv3vHYDEPLidOkCe3ByCO
#OMwdebxekgKAzrLau8+3uwmQFacLmNcFcBfc98I3qz0f2BFqc0A8wL9xBHvbQW0ABB8iVxPYl6aEo7gmbl82pprmu3pJDuikycVv
#DtGCuuPq9jCqhVOUdlxQOSktLjkxLS5cvtF37740gCccVG1TgP6AUTEHuR16hocJOUDPuB1z9XDnnvu8vHvkB7WDwLm4fP867QV7
#q5sizdnZAdFzgWEwevbAXu2AaAFXC8j+X4eWB2rySIp2GXmPW5ygcG71I9NtA909pVDHrc0ODcfgLuHb8MI5cXcQ+PYu1h/KpRYw
#wApmDSBS4i/hgwB0OC78uDPpf44BH4mVtTicm1scjBNNNO7ccfe2AeOxG+riWAlrcSxAhr0uQFDvC7IBQ4CtW8HtYIDi+mv23YOG
#/SYoEx9EHsS8+20ZM3h3yP7HZf9t2GHz/tDDb9Fww212b1rzASrxr6Hs7MogAC8gG0mo0z+g4g5BAZOKS4cr49IfNpI4iyjhJIVT
#VwfftcEAq/v3O27yg4qDL9kANcuPW9Gxz+FwazqsAVSyMoAWsNhfkHY39R+AjqDvT3cM8kE3HPC/9oLjBIAH4LjqfcQDg/a+4QMm
#R0ru3l/FmWwctZ1hgFlF2gEcuoevYzXHXri5j3eWAqGgiAOsH60D8hdZ+CHHDBcUetyksbMDlg7wmtT3fcT9jR7sew/Lx7Hwn1Ph
#0HD09k/pYt73KpiBsG/P6cBpHxDgZgEyh/vzPWa7AFvyn18mHDfAfwHHbexvdOPWfiiFuy/HNmV1gIx/4OY/6PrXjvn/nav+U6KP
#V9pAD60+7mLxcYJB92YHDCEO7p5LI35MsqHoQ/uIE/GjToCc72EIcCCPlIPNIbfgoPr4/E1o5F5ia68R/BcbAb6VMuhf/QUxIGoG
#VvyvjjJUDmj5i0rHI+q9HABEHTccF1T8FS4iADygcEdMUAQYIgsCIbhAbty4Dz2OfI5d2PC/h8mCcNp1t22XmMf54zh9Ab9mtw8u
#XvuXLntCfUDBPUzs4vIYk/BDVPfMnToYB243IPA9IupxsJ67A4+xyTF3bn8lAPzdtNhfizk2KbDQg464ezZ/h9ZIEO4IA6J+AGl/
#0MHHtrj17wEAkH1ot7DIf97EPUzWYnd5CdcM2IJjTtZBimzXudsLDbFAaHjs+56/Eh3wv105+BEHY/cODY5S60d8DMPNve/noXFp
#3yM/Dwdnb6gbGLDnewN8fFCHcA+r0McjV1/ssfqDEnyPjqBDhQKMxlFk1zPf/YqcGXLAalB+yP8U0eH4CWhHuyF3JVZ19+U/qXQk
#tbvEwh6G4XvoBlAHh6ju2l4cAADNUJndaYHCTVzBGoUEFojV8oTK415dcFnOf0svHRyuSeFuGuGyt0gc7n18ANfiv3/Z4H2YUAIg
#OYlhdz+hvY4L84+fA7oCFZwgNO6+5O6XCnvLk4dh7Pfugv213729uh47W/tHHhP38SvKEc5tA4yH4b6cYsapA/geWCzMzg6O/ucG
#//6O4yCUxXHaodIHlNrBx+Y4ltvzwaXsQQdF8N4n6jCgzQ6NsAGiYIBNPREYgM/gu64z7rKLNZTZFoHG4L7wh7oBIQSzNUBtOHrv
#1RbKjMuP7r04HR6RAZ6dk9TxOzG4dL/YX190Ao7/P7rwm+99BikHcpLCvYntXbaxA9ayqw+AFy6gyQZ3pOWMixVwwcC/5Bb3v1Sz
#3vMPwBDMbgGEwH1lIwBYz91X3BuEyfngisshR9oDMO0lEOL2OEccgAI7CDMwUiDcocUuEDE3NlwZiNV3a/n3a3fDAFvAYKBBbrx7
#JxyeUCtu+73OHlB17mM97Pd7OB77ctST05PLg9MDLM7sicMoClipI5TbEwxh9jr2DsQhznva1hG85/bvvx59u8VtD4TlXtB/S7g5
#A1IOwHGGOv8PmTdeLzAnLrSHHDfG2P95GEoKKcEnxc3PiRQD4ubDtXhx757vHagWOxwJQS7/H/audr1tG1n/11Wg6smWamTFduwk
#devmUWw58cZftZQmaeLlQ5GUxYoiFYKy7Gbd+9nbOFd25h18EJQdJ2efbvdP1ToigcFgMBjMF0BqJWo9uNqKaAU5sRMtpW+ncMp5
#Ud2/UKvKBMz1BVV/rsmR/sxZZM6OEoXTyKY5m4Btm9J/aTcQS+TOS8e7MMqcn27O6i7U6nX+48ra3/5mU4N5e61S4+rxRqOZv5ck
#T6E3x7OD36toekIkLDi/TY1MQmfbXv3znyYzLvXTiNVoCN7YM9jekZNJKatrKq8nG7bNedun6dYRmYO01Q5ZransxDK4IjQCS0et
#70NEQXMlaJGqmm2fevN2jd1qe05He2WVB55VQZ+7zefEiIqGVVBjrHbpWO3SWG1s5LBcmM0vNgBxlpGGvGBzE5CrPL3dzXLWn5I7
#hvVafFj9/lqrdT8DbpKm//bLXP6NT+39P8nak+wPf/vTv/P+p/VN+vrr/U9/wufm/Md47VOe/YF93P3+p7XNx4/Xl+Z/Y3Vz9a/3
#P/0Zn48NIZo+qf/mlmimZdFsoyALLjpyksxQ2KdvUeaC3OcyxuOzFiA5J3+dQehK0KWtgkc6zIMiQu2uvamalnEw5Za4EOQ7jxK8
#G8jUp/l5Pi8BcJCfC1xWVUF2Pg/OY64011w7ohkiy3mOXQDR/N9/iZ3++lHvzat+R+yQq0Du5wremTOJxbpIpAhEWQQRxefFROQj
#8XOQXsQEWMxyZV06YjAmMJmUMcCzvBTBiMhMKNiPxCIpx6pNx+l9mkexRO/Pg2ks1F1V+2uu2PUiX4ChfFvVjoIPqNzr/qQKh2RZ
#y5THSQMRMi7IqRI4RGDq5XxK1F8B4uPsWsDWkdsl8gzmWARhkUspPspr3VZ2TMMszxjvUW6qRFDEpmGBg6o03gXxbRyHE4F8C44R
#BDQi3iezBMRBEY55HvlKDK8EdtNFXghy+OpgNHPDOHWAddcGCtzqBClDdOlLF4+IMRfMmOAiL2gypFNTxDyOF4EUuBYyzUtbL/OC
#HADUH+ayNOyp1fJ04Eh2rRSko5UzAhRX9NPdMvUGO1U/EB/Jfb5e7tDM/t/ttKsyhcjUaLwGIMxnPL87+HbKwmlkimlhkhhkkVOd
#xKaWrjrihIItkmE+CoKXtUGcaDXLPI2F93vL8rPOZ8GHyK4rmSEPa56WNbkRfFI1lkCLjHiCbFglZ2FKM82U4MJUm9p4Oit5cAOi
#SeOjhcbFHfEsZlo5ijSrxSJeBMV0zpP0Wl0ZGQI5au5woUuxZhzhq81bFJdBki7VClWqgSJ3ck/cSY1uiErEYqxkLorr7avmpnyC
#opfmTilL24afTacW+NZlYammVSmzQVwUNFOytNRw9c1iPO7Dg8NjP6TbKoRTmlTU3P+YXQu+MT1dqK4G4kKKgS1Nc6kUEi7qXBon
#eEauyBcKQl9VVUaSQyWy5HqHZV10GUwL4UgLoVNTKRt9xVWsNaJ4NJdK7e/qy6pynCMXovSEvqwqSXpkEYRc26VrcYqbqv58np1D
#PUClz/ESxKlbG01VlxQVTCuB46rfuM0v+XSYxKInw2DmNpTzYsQzgu+qeDjOWZye4bsqnvzGcvKLS/eCAbuvT9zChOnp0ldVSCEN
#r+p55hTmtLRYHo/5giuCIdlZx+Ysm0xjKShWFYjvr1jB8Sk1FwGtdBbkLpkqMqhYezCv+bwQlRmTHdEndT0mQ0jzf2VNl2OFSCxY
#Aej9BtiTNgoy1gRQZWTEREgx9ASWOhZ6w1YUMZkCORYIA5HzxLP9V20hc3GVz0WQLohoMaNmZM+01inHQckuQVjOAY2LxFp2Na5w
#raNX33QWE5cwONAYuQJnQWdqlVDkn4Ri82JTDEkSDKzAm5q4h5VoXl5haLKteKAdC9Z88zTFArG9FfM0lnWa1hVNt4iZBZhpObsA
#CuBNshEtPeqJqEiRK2iLcBzkxCgmRBFQm5Vc8Voxq07AQ0UA5Ji5UUmuBVAEpElECiNfZKIIptQLCRH1SrP465xvM4F871TPNMlH
#j0WMnFDiQkrylmKCFnFKHFmamA1FQ7UMmZJZARaH8RKoNRpiPoNAFIJWjRjGJNU0n0RcNiHWYM23QSO5iETjvOTdGMZbkNKbxJpN
#RUyzCReW+rVzw5bKriPH2SP81RJwYNeUnnclEnlUni0+NOrArivBAjC7CyBJOdH5LM7kTU8Xy5XG6eJ4yP3ROtEvb9W+wFNxgo08
#8TsWFzig+MjOgwKDO7Gsu13EG4q55GmgV7ShucTo0zyIIGY5zAZznUlm/CRkxoUOPtzq81qXGABrnQ+GrVEu9m8y9qkLGyyxCyuP
#JFsjDikocTi4YFkL5hmJ0A0+AswMHfwUb0mbhAHhSyWCI7Jqmpcud9o8LVwTQYixR2B9L+2OMas9XP0uJvFVy2F7UjqsWVcjfz2+
#UuGLHsS+mJCvzvGJRgiZeeq2Yy4cZ+mVVeKs8W7z+blQkmKm+KebKWdsWU3qjRohSzAMD8QHhV4Qq0ZpOHQ/VHTvYrayOAbHSf2F
#YDBkQ8ZKvDRpT92GgfI223ZY6H42H9KEktJXbVmcoFiQxJDMPKUFKHor8wKqX4WnisIAumwFSUuahyjeEjjzIr46j0vcGhYaAWE2
#EUbevdATHIFrCooQryR46+R57Ax4Qw14h8a5L2RAend6JYxHc8s4N9Q435IG0UuQkSMvAXl1pbUjbBikZoqwRyCauaCcroIpvtLi
#qZzuioHgOOxuDnGg0qkmPK2WXr/OL4z4h2Hxo9VJrgJLrcGnoACZ7kWu11SW62VFwTzpBvE8LpeZX6m5JFvhZWAZzrNCioTck9hS
#KLUN1prvyjgWtViMwZQLQhBwd9oMS6pILdpf58QGFkTixdAu2Tiq+tF2Fe+gFT/IGbExhC3fft+cvG/+aITlhweo+hGsAt1O62gp
#rMHD3YkxGoF4tELwsE+sDEAgzwYf0yW9UOaOxk5rMaAVVNuZtsC9uoCCbQ4I04Oxp+CtERcsGpupUbRxOTtuWE1zckuWVpW1cmkV
#D79FI5cojE5RHPGU6qFSkGEghuXNxBHaxeFExz07+poRdzrV3FATFd72+cppnk9sp6Rf4hmmVLxWLkNbh7NfGeBRonIgXcUwEtsJ
#3JBQWb34cpYUWGMjEL4ppkk2h4W3Wt/oZ5qs3NJGkVcnyS4CcnaUAASlwp7I7JtScAW8inEgdQ9E4OBz+ge2NBA4MUyLp9ZXFpdG
#0EgQY7iL8zRiU0ByTc4JMRQ9kCMVnAc2flaNCxxaQes8V+5eUJZQ9zRINuGBHrRajreiSPNwUkOxKHKasQqR7Rnj+iivpSvUn8lS
#OCywc0+6MckzK3P6nrRzBAxGb6ke9VoD31iEdCjZGcdpmrMhVZLB6a12LdsxxosNaiLmrA5Dl5X3cQcLhvOR1cJxqzrzGY/0FR9E
#kzp62iRMpHoiC8orrRob3+kqFRso608rm5W7LtMQenHa5ubeVOtA/4AcMSfQH3dIVhLD0G8Is3YjrNFxkoEv0DOccJqRb0yacatC
#ZLTwFyQWa+MiZyHnaJi0+S2ZM2JMqKnfGYgtk40Yd4gJmnBTAl9QsUldiY8LChjtpCZZPT+EgZrjawbm9syS7KjTDAikOSFFjkdm
#qti+qXQ01ag7UxWoRlzj2HJTD0vICwgW0Z1QVWXEUKdyKTStmzrpTvuhO+OaYEuaorpGWwVguuF8N/3PYj662UJNo/YlMaE0laau
#SilT+VVcmvKFWq7IL72uGKa4gsIDUxgVwcIU6iTYzPIP3yZAdud0ZjlYLnNwppKrRhikKXV0CGM197p6FhrS7sG7ULFKYrI+sypp
#CXeHuuNKUrUkoqSDMHIt3NMKdE8/vmGzpeyAUfzJa1mZGJXrzCic5GMNFgnfScMYfafrcNa80hcIsD3SsS1TveDerOnXtwI/eyHc
#dFVnErH/+VI8ELv017UIFJteG+5M7cwd5GYXYmonbhffhjKVacwLJ+2YF6b29nTotJYOndbSoVPlIVvKoin7CLvBtErndaYXKhf7
#84klwyiOfmhVHk7vjHgQHi40t8oOZBmyws6hkesSj7UZ5k/ZtOSmZkxcN1VjtyIKrkx5hFyTU3UVk40rNEB1w7XzzlQ3m5qCsSoZ
#X49JMVbFKfQVVaifX1nT5XEHUTaPlqwazTJZ4gXyKcooL8YJuZYAwa9GNBvXav/v5v6v2WCTf9g28N37v/RZ31j+/Z+Hjzf+2v/9
#Mz4fSXAyFUCcU3w4borrxn+bpr8+f95Hr3+V2p1d/Uf6uHP9r61t0Gf5/M/DR2t/rf8/4/P1Vw/msngwTHDw50LMrspxnj1sNJtI
#wB7Fl3Mk3YcqvNzSjrnyCrHZb9M2nMRQeQPloKr9jCoHZ5IHjUa/pIASCYc0GRYBBUKc+/BOuGfxsPPkfosCx0XO6So8vyy3yLx9
#q9N+QghPxiU2MWUHPwTWFi8GgxNE1fjutyhCgC9FRPPJjfuCBDzBr5wRiiTjhzVS4a2tP+6s0n9rWxaZqfSBFWi44Syd01gffCvw
#zAKGDOTMl4MkmwhVLTykk1Tarnuyz1lcsLCRTIFMnP+WzNqI+sc0ZrqYBiH9W5bwRsEt7E6Fk7hEtqWYh/QN00tMI98SiTDiZk5/
#H+bxnNhc0B+FjkVcSpXbDFKDwKL7kNLgH9KFRN2VRAa1iNn2t9llbYt5kRI1Hf3odINTcaF9NzYFAor2CPWqlikO83yCVJau7id4
#JmOHCxWUxsuntA0UlfF9W/1Aj/9BNhrdkxN/d/9UbNPY+DA+DqEiCPfMfTCU+PZ8H6eDfL/VavQH3cH+zlI7+PeeRtemWIKdmWar
#sdsddCtQEu+EPCF+c2WTzwX5J92j3oEPsCa1e5DPygehXF9hYX9AsXpASPq9wWD/6Hnf39s/6C13anpAr0aOMHXo/NnnWnA3nWhI
#wI3d3l731cGgT+A4kYVQg/hGdvnJ6pNVgqX1ya7dKkvtKsitySvVrT/eXAUoSa1PAghodgyxc5/jKSRVQm5oKv0w5jb23jag24JU
#ok9x8SWK9oKUpk2h0UubZ4OqPs0JBlvReXrFD40Ce3vmtNkSv1HF/Ts7QLzQmrZ7jtR8ON7wfx+vY7hQPX5ZIhH5kMfPZ8v8Oheu
#G42d492e3z04edF91hsQm5vdZzvE9ecv/v7y4PDo5KfT/uDVz6/fvP1l/eHG5qPHT75rkrD1uof+6RuCLmJ++ogG7hXNf7yPPq49
#vv4fmrij7mHP3znodY+Wgd69v1xdXXl/uTZ6f/l4dEawB/s/9/y9017/BcGubwr7+dpkgjjLlM+Re5MZsWPMiTy9NWnzTvMMCVlJ
#4ekIUXjjsPvGf3a8+5awrvlkUfFHapZuoyQsPSNaEEkqQ4AO4Tw43nlJt1YtdE4PSIV4ikyI4bVY+nytSfCTSKz8WFGIXoR3XzT9
#UpphfhL7aXfwKezJDGhZ3yD0hpaipTydSW50E6XG6BuxDJHuBO7mVGcFIA68jLfEuzOSgUYUj2C8vKk8b22xVJFu7MgyQjZzgW0V
#r3lPinvyfdYU94SnkjBlMcIFVe2JewOSZYH2reX2oxTH3Fu2myDyjVLwdG/naT4k89Pnm1tmCMVlcaWA8eG0I7YQvZoeonFR1Czi
#jKQf59mb83K08qTZgliMqtbcS0c9/+p9nGyJC04mT9p0ga13WpkcNHqjVifBGzi9lkhGgg/7GaKuFVXxJRLqYo+E+ygv95CH6OGc
#UdUZ+FrXgpxMHPFj+mQ+EY/q1+xCTBykPf5CIhd58SWMYZABDSZd1LBv0TRhkmKFq/9Oqcwz4iqpRs/et75HXV1bOkBLFZi+r8XK
#H/kREMFhIONGf+dF77AL5UO+wc5pD2th0H1GVmJ/TxwdD0TvzX6fjAD5GoX0WJGJQe/NQJyc7h92T9+Kl723bXXCkovR5OjVwYGZ
#LPHNN22VuPORoBT7R4Pe896phVOKFGkvX7lwGoDMchFfLJcxnIvHFql9Z1XY+v6ukUA7S493Nm4OxBmgpbAaXdtRN5YA9W736ObI
#lH+2XGwZs1qRuX+023tzG5m+ouf4SFPNt3cPT5sk6ZX5JCbLRB7el47z0yMxe083a0hDAsvdYzE0VcOxVH7BiOC1+7ZBxXp3RKL7
#anC8f0RYDntHg0+M78bkOXU6O3+zAhm5m4J12yhnzvjqNHOx0/9n8fAJjZtoTHtF1efkgIEhu07L23hXE3BeTjgi49y6C+7uTnVI
#9aWTdMd8zKl0afoqqvgxythZg7zb9gndwhlXv6yAVUHolCwSPHZV3aucdnX/6mj/p1c9l/9EXusLWOHrbSNP3d060s+pHK62pODw
#mUNZhBNmzj1O98myKmAORJyTroCmFzO5xI6a2pVxVvpB6RNXq3JnHu1oNPGtu+V5OqvWRZ0rX7D4gwuyVHdYnlGsthBu8jWf3KF7
#aZxEQJ4FRnvB/CkvKRry8lvyj3af8V2O/a1JTOGCdOKL+JKY7ueT7UEx17afHVsd83b0cQ5PB2A4dhaHE1/SJPvKedxWQY1IZJ7y
#ox4+HzDchmusomPywbfXNg3yTpEv/FGAX+e6cjo6zRcGAD8AwE9kn5x2n5OF/5VCFPgUOH2y/bp70Gx9ClJeZeGYwtJ8LrePjk8P
#b4GVYZHMyFdh56HyEcGecEw9VCNdzR+trtZcq+O+8tL4aE7DePFKxanzXAvsQbEKxL4apzDUWQJZ5rMZTmsVOGabw7wSONUnBWsq
#PnaW6UdCGtZZ1aFF5cW5g351sgvZq2laQZ6tUvzbgkIZTxmHttg57h70+js9j1zfg97OwFGPe6fHh8pJEnPx+kXvtCfm6pkiwlFD
#rkpbxuS0WhpcGZo+C6pm+DKtu9Qr0cp9WVpVa2OhfxBPyQv34ElypMBRQqvVbn0eI7sYGp1xBT6BTqyIJ482KLZtmdiCGG9WjHmH
#7FIbDYgHMDI2S94F6bntRxv1ZlX4ij1gD/E/3n1wgXQafoOCX7g181rvtrIzjbLMfXRG6KJtWtlpvr2ytvrtt9+1xTjZ5ivdBcvo
#hXa0L2pS6eHMCwtmW/D7o/i6tWXIilwa8evsaY5kWOaNEwpdHDYUU5hPb6q7xPSD/qmm35BPQQ6JudeyP7LRfP+eMz566tFual7E
#T4XvVtbOXBIK3olHUP+PYOW31ZXv/PcrZ0BAf1NizqONs/9A2GBOUPCxPQ/RaRlnJgWpjqnGRYs5wfkxDW8kY0aDovimlrQ5uxlh
#TksnRXUelxw7e7NKgikgJJivtkU90H6no+yzerhZBayz/0eQyoaT6HAj0hrAct8c1SOKe3fJIe0lQtYItCbS/N6fd9nm+FodqHXL
#VQ4wiRDKk3S2zu7sS48TMlLeGrZWY7FaVgvO7WSbDEFyEfv8rIInycPZqnSoTaFUmMEdFDPpAHfnxxy4JK1AyiJ6x5mYM/GDaqJy
#TnWG37bQODOkSHP8WYc2MFqC0beJmyZFVrwV29s4lcC06WIgbLZuJQXrVr5TEGdqdBjzEpMatRFHt2M1gzPY7jBOBXXhqmhtatgj
#1Jq/8uy1urae6TarayKLNHOHfSPioNdyeeoVhghQrU7mVkX8Hg7zzNm9CNkMHmSjcbK/6x92T25myr42+yB6K0bn4tj20bWnXbgW
#Y/hUyqy73r81B7ec4vvYLDkly+S2OXuLL3s8CyWXzevqGC82g3A0jPwC/lFTgaQKuruLFJsTXdtsqEy/zeRdN3warpPZ4wNyqx1O
#iecR0rtDTlqf/6YuTZJvlkR+PtI+b6UPsfPSyeIF+RRKdEyauMUWI+N0c6vDKgs/fqYY69zrPZyOHAfrm49a+MHKKDnHD0+QGVh7
#5Iia4X8la3pO383O2EwRYldSZpryYF36zDtP7W4Zd3S181gPhLznrpxUjw6YRydLGacj4fXJ9wxjxX+KpnZPWnj2KSDzPOQ3lSEP
#VzvWr47xO3llPtzVgZOu6PtA9A7/j71vDW4rOw+7AMgLEqQeJCXqtV5BWFO6IAEQfIgrUaS0lERpuaZErUjtw1wuDBGgBAkgIFxQ
#opbLrR+JE7t2Yjtx6q5T19m62diN66RxY4/H6Tiup+5jPLF/dBona9WZTBqnGafNuHVdu9X2e5xz77kPgNSuNrNJjV1d3nue3znn
#O9/jnO98J/bM6tKS+m9OVDS5fAVtwR7H+nDNm3OZ2Ebak0rxH0N8TZzJTJ2fnJM7VqlZ6KPM6bMXJ86JBdUUrfJRow3x12dhFJMt
#52plA8CDSRizNvQAG2gDL+4gnSaw/sWbxsCwlI8FHSkCo8rFo8fHo0eZoswPjx5eQMp1OTYRcxIqtcpoHyQ9PHp0YYO6N1n/WHQE
#EVDUfgBrn4r5kkki0lYBUPKI9YUbB8AQbWaG9DpDd26gPz1j2EV4r+H6M3uxMXB407itVHDCjqem+MZDIzdfGL2Gjs9pLghmjjye
#ZSq8sYwAugZ9M6CA2DceHUTKAsUAhbJZJRMREKCATV8u1xBhoAroUHhiEdbb4IKbsq8xRRpF8NBLElMm/sR8FoUaJekxnbCOsiWp
#qrigXBC9ur4BS3f3OxnpFR2YSNqRtfCPExj9/0nGKDZWl8VBxtTSChRob6DOEUW8UC4XJ4kJlasCIOgPb5wBYGfQVh0aM36Ex4ot
#u1AbtoFyzBX8FU1CDrMeE3eJToJf05q4r5BExST4po/nQMaG8lE1Jz9PxWzpci4bXR1ViNmqtRyfQFjica8AiAzSG0pjMB8jgWac
#ZRzfNER0JacZxbd5ECdADlnAfFUrzwZ7DtRXuO8AoLt2GKhfaUOomM9XYDopA+4rxlnQOEgRhDqFOCmu+EpyUpCz+SQJDV5Zjam2
#AoIo9jJgj+GSopDWOKGWbWHhwi3bASvwPz22UklFJxVeYjIbwT5dqUSNm4UssSlbFohbbAXmaoLMqIlm4WtNjOyGYiYKlUBSeXSP
#USHopsspFvsIj8eiyMmcDVeJMe4zyQGoRW84kQLdnxSWV/IKAXNSWxy9Uc8cqWBD0H1EHimoRZigwSB2jNszxUjCDKH1RoxblSKi
#1FzjIF4MH1nwTo9KUdLntViFjp0I0acyzzvhNOMkvazIcnGfnV2wQBAngyCun8IsUGK86smh4p1ILJ/TgUB6W1i3u1JhGmsxggll
#ZAsIkvRVyR3R0aCDMWvrcU/EjToRXrk54UsYpCWFi6TFhKMGBRoKiYu1gzqFMaNxQYuBfsBa4abrW1pmeGG1GBdJBgrCxJk80Ox3
#VWPL4+n6YK/6gb1aB+xVF9irsgoKTtepRCz+Q0UAuPxYUOAm8wyxIaCmWnQn8y+/sJyRBziIqgklcN6OIFy3jnA4E4lgSlIto+k1
#om9R4C3iLE5TwzktV5nIOAg1JHVSS9REFFJ5io5dRR+bnTkfNfrQ9itunYcWypvizGeUT07h2T/g70hA6ahIPnp5pVDM4cq5sA6x
#KCcycmWtT6rENWAYtrYkOMfx6EAqbVMNhFQus+Tw4D1MUPvYjpv4K8Y4s/PilSgHJiYetY50u5KtonW/OW7EEigQjuLCoVSZrKpt
#0KRBQs0cryUIpHF8JKJXnhvH3iIjGjyTY3Dw4bij++2C3oA1N2HPl8f7U0wa46uAPqiSYmsQHmk3IlabkXxgMM8UprgJWjuV44K8
#RFoSiZsdVbVUadlajE4wit2JGPlxQQOmKT5SKITYVIxFVlqjGFeXeG04mErGLXSxxSb/ZZBl/2WQUzOXzs8ZvfHoonfRmtowfiI6
#cf60tYB9nBewxQ4sIiTuR6hrI/OxxZiDZS6j7jXiq+rU6w7rtCGDIwwY6awnn1tcyt+yDmyKzsKfz0YEl4AbEOSSesCnbRSRtpul
#KHcu/WowHXeLDLk8GXuwiZyw2UxBV6DjT4dBWtxd2IhLifQI9O4WTZ2fnbw4h7twM4rVhVjB4D1OZRPYsj+IR5+YmL40OWucSIj/
#4nV4k/j5FSv2BJR5IOtBF/1Rt0KMv8tQ/XVHqBDM5e7a1HItf6VaqN12mRnZneuSx5B13Bse2Wda/ZFE7VLFJEe22ja0Ubbu3f0Z
#x43YUzPnz0xPnZoTEz96eiYqEBBRD0sbh9YXV/AU67J0MeTteWef2/3qbCcqgsIuEr7wz/zo0ALo0bFkDJ4UMDRKdJysJnFfhSwn
#hUGUZVC5EI/L5TRBBKXJn4MQkjDeCAMSyPcH4P90b++IRRYxH+g16U1TQbvEdR+6JhV8SyS3hG8FKIcUM7+AS3aDqlAtqLWiB1fk
#FgJk8CXkVaPiJf0eOuBRHfjYqyUkS3+IVJ6f4K5Q+YqDxNuCvBgCEU2B3PXw/1AduRB/ltTvLIBDrRJw8IbjqjrgTC6C3enr1yqM
#JzwFyXBvzfI0nzM9h3Jq2okc5iyHG1UulBdnSRTordY6VOxMLYLjNBPTyO36gNsRotSETInThVatvYPoZtVYXzpuLWT5piTtIREd
#GbaXrzzTjkR3qwmDR1yd4BGh7ZxWTNwrQ9upRHjcXa4t+nspgYiywDp69GjcqQjUybPozuSs09aVrLVE2viC8tYb7qVh0DzQH1qH
#hzGyBTqiH/YEtImIqMEmLSbxas5EG8Cj0ezNzK0sNMPMNBK1VAZzcvLs1HnF/MDD5OtxI397swRxBmlUltgsT7IM5fz40qmJ2UmU
#is5HHRxq7PihQ9E5T3B0chqS89v507aBm83eLOhslumKtI7W+/5ou41GzV7K4C+cHgteYcM9hJuXolSWTz2rMHwL0oRiEusjS70W
#7t+4axxGuJ54y7lA3Z/CXxLqelCN/ue1QHeeh0ghJSMh6XID9VLu0VGKAOkfT7Ozqx1HSpTLbl0VviPYkKjhEDS0EQKh3Cuiq8Y8
#FGCh9NhxUkhq1FKr1f6NFMzfRw0aYO3HCZEXDGVf2AMWQuEBQdGL/Ne962Gmn8GrTQWEqZMDGeM+ALBJDQQKVsaTx9kxKKgRjfMC
#iGupoPCzbhM7EYv20poVJ/fp39cwxg06lHuclHA0OJw6HzV6zDiuBN5IROcZk1HoFeA4NQ2PpnD/4RNo50U1tZpTM+fOTc0pDKD+
#NpQ768WZ6emTE6feFosfA42xYObraAIuCZ7F1tcrvq9QJl8hZYWzgJDiFvSlCA0pNi3zX84KpxlC5lek/Mo9SPiuza2Kahe0SYm+
#kRHJPbH0xRW3zYmY2TMXo1Nnz89cnOQ5Lq277XkNHZdAzikMshNkh50Q4lVCikwJtq9OsFm1lyVtUs2XnHaF1go2Eke9+MMw2vLb
#MJAHtg70SU0twbSkz7nTNwZz0wLnaxIyN1Ed97dD1/ImEo5bHDV5SS3gBtoa0x6al0CVeNat8O3ykK7gZaQbSzv488e+i5MXpidO
#qegnbcfrItGmEAlQqcTm6y7ltoFSu4EyuylddSOoNqfBblY9dRXGnmkcqUbuGSQ8O+Asw9v2BvovCC6AVFK7dRw1AALJWy1vDu5U
#zWcruM1p7aHMqjvN0hIdzW/I76hYhjJHWZ4URukkdZLXAYtls8E6m6tb51Vp70RupvgaT9ib/APpBqS85muQUE/rlD8gjUVcFp5n
#AiutNXkFmINwApOxp3Ios6Zadh5XDDtVS0iL/fkYa2DJNZO1VoDAC5g/c6s3xPdJRDLrieMbdSP+hHQhemvUVuyVfVPnJv3G7Xxt
#RwBq6r7AZk1MGOsVK5M3woicHS2zVWhk4gnhD4HsR+DrcXgntxKpx/GJ5kVm4bn8+GG0U4P4C6DGT50/iwslZJ8BQXNz05kZtOUc
#RB49NJJOy9AzE1PTGK4EPzozS04NhDTFrhlwgw/lqux1oJKFqznyYylP7qPj5JXlQu22TEWhqIuLC2go3LK9uZkhFxHqjprcpnV4
#h3iCDw9xd/RFQW2pXFFL4ZUbpRQgENQl6BRceJTHQ+noPI1x65Ap/Nty5/LxmQJ5KC4VTDruDNOuXLQ3bhtsBgqjA7dg3EDorGO5
#LI5o0Ykswlsx9E59Vd3OclsuW3bK0gqpOh8TpaIpUtSwcQCTziM1F6bMCh6wcG3Q0W2RBHtDjEnBRNsewzl6cf/mSxUUp7mNkb5J
#HRTaTsvGQVSHGvt4qrJSy0Ars4WaGi2mL0+LMyvFom+ZuYKJDpllRkakDLpIySApXqkW0SFOqaCY8B6xEBR1Z6f/ldRF/ssZr+az
#ObTwW4tdAsRPTlzBi5cUlxjJC+QyYyCVjq0ri42uIuGTTmKQiawEQprUIlGqehQxkD+haoMARyNMUKDofcGeKcVy+fpKxT1XLgp7
#d0a3DLVCnPojCS/OdpCzvIWFNid82g6ftlHY9TyaJ0jjbKcnj7jrUI9EDohrYPfoOFViGvYAxfDNHO1HLz98SqyCplb5HNKX/ikC
#FDu//2y+xm4KZ+m6pULe7L852H8C7UR6zIOUs5Azx5mIo/mIPKhJa/rptFvEIrsxQzBsoCsVYCrC7Mhj0SPUWLeeUCl6+ZY0Iy/O
#pxeEqEpDgddIcDmeqFI+V1ghwVqJEoPGkvg9szTBbiqF6FIWZnjOZULpGB60cPUZDy8X6Bf3g5n9PWb/idVScXyATL4Ylwa5kxsY
#Jls1lthJC98fY1RjY9wPOMePjx14Zv4UnjJ9Zt5I9Z6IP7PwzMLxsX4lBZS5Sh3pU8Q56srGhYg0VIzD8sJRHrVq6nS9omS0sxR5
#2qSUugKaJoitJDKWbFtRGGNj2RG5rESqZK+hMw5Tva5NDDFJlz2Wsazcpc7HPeDZM17hu2TLLCV/P2lcWtoQxb5iWYniD3jceDR9
#zDpePO40j/cQA5UqoSWoi5i5pxkkJy4Gf/kyYROprI2pMWZy2eXbhiE9XOFLnO4ckhehxehASY7zXmUx/6pgZiQe+Sz+4jkxx+wg
#yIcZ0/1WrjEDbfOP20c1ckfwb8xfdK6VKtwDCgMmuQgiYr457JN9kAS3CC/Lo3zRJeE7B6Hwt84um9bZS8rt4vz+eXB0B+6ZBAlx
#rMd0kSA/xKyvCtRbencckU9Iaat8PSHQ6jXYf4hC7L0cRYazA6EKibrj1tFoK1bEJCR8MqDB4oxlTsJrbkr5cYeYVEfgsRDJVpbT
#qeE3wn0Oyv6E4EQzSnnAnNt0RlQVQTZj5bbiLzL3qufJNy0m408I9Csbn9TBizn8a1dMsmYvnTOsoUVNGdAnKXdzzPwi6Mp4QN6d
#JE7rGwnbWm954/2qsxdnLl2InnxaOe83c/H05EUMotWS01CD2MOoWZ4nuA+yxaLSB6X6TSulxFp0VLhiztTsV/RyWEkRbSdonQuO
#lehjM1PnLYfZ7M4iVciNV1KWdw9uUSVVd7BsQOXphPHo/JqytzGKuon9uaDYqCsHYJ1pyHRBOO4fJZspil80WcMhIw7ajLV89kM8
#+TFfSFg+7EwOXo4trBM/oGM02JHigHa5lkUp0Vwp4ZlYWd2CfTRCNEhgOx51wONTyA0tCwUqk0ZHlfJNkjfwIscMXjpeta3/q4rN
#tvK1WJPmzwLjqYzxKK57Qytu4fkuhUgXlRTFMvmpLjZIIpyH5+wk4q4AhZXXWwmyVrXIzsa1ZDbqZua4fsaGAt4ltFGviZbIhbxd
#sQcZFwc3laMdVKRtpe/ltlaDnJjnPBLhOm9tGQI5TBuE0Y8MW6UwxaKHI2xjeNWOh+OkDXyjhWjFloczKVihGu2okYscK05aLOdX
#a4bzCFmjY2fiII84Lh4XOmFDEG3Tn/n7cOzFsvBy7IXf02kYaZsme6RxFzsbI0F0I9m65wCRC9l8zxDJ6v3OEC2se4Cy7XCdi2DO
#BXvbPpFEBmeXS21X9vaK0tu2yQxHKN8LklDKSyog2nZDZ0fbme3PBR9TMOHzkWgn5LUuq+AX2y+pNd1MmlHy/oy1GOUUJ2+IbpIh
#HN8hcSvB5IySYvFIuPA9t44Np7sDavZuhkVfhS8yZKGLNUEckBiRSjMeHSTzW7z/Ce/hpOMElJIVsqKScsiTcpH4skhp5kc9cof4
#JkJN6iCSoeOiAHY9QBTaihtzxBFpFi1inovHVaTUKJa2yktLZr6mHnr0LlQ2kA/ICCWliEClFNmGlVJykzuKp+9z/OIrQ8grMqQ0
#gX9puuILz1B8k766/HUbgUb3RxCxJSkBOwlTwG7OTc1FIfbMGZT6TzTcNvXvZo9cI4Z4XhyzqzIlTUQbyzjWjdONpRzmQFWb/chN
#fS5SfGAE799TML+6qZ/CU6p1GUrVxU2sq08gQrwrBLzqc26x6kupqwqldoFlGyFDIvlBdcu7ru9dVvJIdOoU4iuT5eiWnOeFPVOn
#xIKDz9SpJzczKkrMlIZptoBcUvzINdBosGIvQSGQGupQcpowGNJDSsnXQwr+KvWUIsdJB3oXc1rOaDFYCeFvj/3sCf96Hr96m+ko
#a9IKkk2O+nDiSjeAUiNSW+OZiWIillwT0TXXSnXmWslvrpX851rJnmvq9CqpmOlkkspUK9WbaiXHVPObBYga9kRwVOcstr659vza
#G3Ae2Z7KFedUFqYYnJ7fGwlnbHRBqemtjnQHvBO070w+Wy3eptOQNToK7TSyIJm9jnTnlqIUwVUR/Cqm5beaXKdnbwL5yF4uWiaj
#7PRjjQW7HLv8spys+7j7wpKX6PZsM4X8HJIZOZfWgr6K0ZmD6hmMnKOhXL/kWSaFUClikjVeLFXBG+bFHiv/zfPLrfzlilg1rebF
#/mc19uz8RPLttmO1vrdCWoTBT5laqc1jlKwQt/eX1OVr6fDQJjEul1x8evd+r1FlV2pXWfbL1vKZ8nXeBxLcGwSwXPmWslDlPr1L
#1N9ycm7DjtuEGIwucYTrbC6YnKQb6kImLZzfoJ69MZ/GfVpUeLnm0eiNVKVcQYR1knqUdG+Q9xuC1KL4ZIdpQyHPKdU8mRE4yB89
#nE6nnYNFfsYRHeavO3yOU3MUsxacOORu8CY63RNgo/XAwiinBcCN6wlln0LAiJsElrydy+dL4mBioSI6Wpy+VHz3WVgmffehRRrf
#5yvcHa5UyAwpojQR4+PokmfEyxA3s+hYZ5++18cNJDoLdR86pUY15NVVOnLE+/TiUCctbzQ617fxguXmD8sy2Aqsnp2bqkXaGhXP
#669YvK0FjtsKYkLxW+4+BSCNrV2bCeSUm0xX+OAtO+leqRbN7FLeGBr099LpPGfj8e9tHX0VfW356ybU2+xpWsPpSIzLtw7NO/yK
#WRXW+JCZGE7nbRgLcWF0Q1A4JorMjTVYLmM4L3Y5V22rpohSFORF93tCcNMWUV1r0HZfCmwXHchnNe6lY2ju1fW9Z6Md27SojnPu
#N/3HjboI3REdfXylYHk7E/dqzUmvd+cKq1PLjqt/UnRrER8f4j7NZfMlGBv2lIfyMVE6jAFps3wrU83DsGWyuRzdFK5EC7OPDBmu
#ZNCMC92DDTOlwjtfaqtiWZUH7iGyjZybnqXDAdDf1/PwhqTelHfwiiKF274EO5IzAYroYrGAdwuK2xku403A4tJldIRF7bBPHZA9
#v4Hu6RKyyIQoQTZEIUkINl6rARw9U1heKhvx+YEFN9VTzPmB6Bun2OkzYJlwKzvHZi7iyzSLqdnZafElZAQ3GRQ2edxiApltVmhv
#u0pbiE6YyfVYnnwn8dA/Ss2tGur4ngRpBcdY2PeIJPL0BWsBuBiFO5rjtoUPGfgIV3q3TTWFsCWTV1mNK9y6Ui3Xyovlopoc6+4f
#SA0I3yHcLWill7aHCcQL3ASH8VG6hNHlCiistRoPnnVbVUygU0zly2JwMFvBpDHCOJcLPSxFmicpfv4GXLvaajq0ea+tpm5Vs5WM
#dCWoRFtODfACVMUnOBWzQuw8xe1T8BKGOlOCEQRlQKDlUglK6s3GXYJjhCcKz/F8ETdIrUIKni6D5gvTJfUSJRearS4RS4IWCCsv
#zvFU8ky5eiuLt8jiG587cYvaq0sWVV5dkg6LE7E4Wu9YrpqHD3sc5lF1HuRVEWA5l0EzKdEb5cvXEuIi6/FBZCrSII2GW/FnxnYK
#ij8ZygkUZAW0wKy5WCiws3XLIYx0AmyPESMW1C9toQyu2C8Jg2HETrEpaBL9SJMlaQW6YpF8ufcjMMfo1nkY9vH61bnLms4vX6ld
#FVIheV9Ca4Z4w6zohSaJBVTLRXKUWk7ifXd5b4WLK+jLQuQ0FSlOFY4NES0OL416q8SUrrLtWLVYirqFmy0O2wxlxF0QuVDZ29in
#kmqvJ2fICIPdw5bN5cLSUsNevphfApKaryYvlGGkbovOqorQhllhZlSzJUeNpyfPP72pQZ0VzVSqFYpU0qwuRg9hzkPHooXSFeWb
#0Hr0GAzNsjMZe+J3BtVuF/Nq3kMryyheJgu07QAplgh45FQmOXg6hFdlQziqsUkAzgoATCgls8TERGExZcCQAdtTVBmpZfv8npeq
#uJDbOkti3RmGNp4O3gqag4wc5bMbiot2IGzlMgji1SsqileztyRJqxLGkQ3psmpmdjm2tm4vvbuMMiG/y3qPbT0hi0fbUfh+Thzj
#8wMTyBCIAyhZwh88W+amiDm7Z/lGQ0H5yFa1gT3pIi6xKHce+vY5RqheoFx1L85jLQupmwgwNQxNxWD+L4qtF7unGh+5kTs8Mbsx
#JNK7MMRiAorUzxyBmxBbXpV2Igixk0ag6yurod5CyT8EegeTlwou8KnKeetawQV2MefHGNk1eENWeAFFGvYlznZ3ck4Ipow3XZdz
#NlPOlTNnJ+fcwHotAdkAm032CAJc5XIZ6iZoAWaFouybK42VFPmz9B6UxmKkXFbXQNemVTSZ1ZOv62jiN+wpt0KNp9tI7S1MT2nk
#ES1nOFzSOYsS1q/WqpswS+035tPJo9nk0sLawMh6/BlctcMVuIoHkFKdM0OWq2ughhmoRDi6psG0LVJ97RYhg799or0bnfG3DoTM
#dU8TZOJxnx6iRPZBkIx1DCRBmrO3mvsxYnSrpQ8woigR7V7bXW9YZN7HptPyR4c10Ayv6+GAktYHyf8kNm/KU3sHvCUjQfcY5m2y
#P3OqZ8vXDY27q/qtHf43WZfVxwhpkeDddBds3rjBdJIWbcUZgcH0Qpz00UE+rX84Hfek511kkUGmV8+nuvHOSzEcfdpvPJPri2+a
#VrwJUNRnDxY7SCFSbyTWWtdhxurRDYeZOdGO/lhdUubY6UEPJyPo1Y2uCtqoZD6H16hs655lLPgIFjySHj6STlNhGKAWaMRQVAZY
#obU3oYxyFYq2Thh75yftElHqfnI/n7paK5H+1M9jiG90pccmoIs5SvCrjajBUvZmYREkTnj4kWNvsTID72V5GcS94Wb9oZdXIp2s
#4krnhYJ1MZK9pHUxD9NWXJHklFDk3pZS0Ib28SAeOY5rSOHHaRmPP7rBaZMNFB5t+Xsd6Y+rvzySrLLAIgS3CzOzG0tuFX/JjZ73
#KJHxaTM/+XOiUki+LX/bZxFGlEznOOet60MWpHMTumAE/ddmQXAWC9W0Y6cmruPt594wamUZ9xzL1cJz+Vxdoif8/Yr1MqlA+rZI
#4ZriznvhQdIfLI9b3E0WKk/hb1Sw09XkJguXhrANS1Zc4LwWke+eCLofbp1/Kkb7ibEBKIJ+D0UXQSkql8Qq22h0sVo2zaRZqOVp
#UcCUy+wIUbRQe51Qo1MdsXjKcNclmti1iGWCLHvRtlCR2GWdyHSVRDuUYk88VqiMogvSAmhWRxLSW6IjBV8AGUPfhWlKcT+miuUw
#OFur4c03puUpmL0Ep6gbBo++9vlTJUGJdqFtny80f+K0IVe3Z+5L89BHBm1jF8zorWqZD55fRfJPG2u5VBRX7KIHACre7V62r5PH
#5cdsdDl/C128pXzxAX/qJqLjOg35W8TDWspCwniPeSx6AWjyeP+x6KOguOMFEseis9lSfhbwenw6u3osei67imebx9mFP+/1JTbY
#4PRXI61FVmu5AoQHgKkPgIJaKcZr+tmwn8k/CR0vTUTnjdhsvpa0VnYWr8cXNjNpyis1n1lTo5NtdVdg/BoIWfxRZWOnHfjbpFML
#dWfWfy+2zk7svVLSRn2rItHmUSgdc4/Im1VAs5cpffbGXh/13qwIiILWm1EGVBeyeDl2UenQK88hicEbAmKkQXiZ6wRtQCcnxY2T
#lssA937V4jxeGEdmAVAoqSkQRBfK2VtnPhtTg2qD7ueuFAHis91jFWk1KSF6oBEcT2SrJLp6uuPNuwv2unaypP4mDAzK5RqaGRTx
#EvPVTPZK3rFqXSRWXUwVeb/UugMWf+grQbF5BI5fpBVFhysZq/y4Y/yIgEB+VS/2FIR58Zh1Ge+Sq1jij2shE4upc0nm6yVmizWU
#BMZB8Cnl8RUmDlASM4PvXC8aD+KsUZG3vFgDCg0dhtY0aqOpOMfSAtqI9vPE47pI13fMhOzNLG+k+c0RDCugkW6/efNK3yoo9W5n
#6lQq83XndEKAYiIoxptFyyK5e1vFFKatuA7CzbZpaC17BSIPxXpWkz2rsUN8cjyFXovRWiGzjFbm9I0WNnGFOmWIrb8mAsXOchr2
#ZkzpN7thFIHd5gyCvrNDHGjqhWlqKYm7+slz7P0bhRjqgz4YtySQSSZO2DjRi/F6fMuik0NuVchLNCbnskjMNqjJt5S6RGQDQmLP
#IytI+JtBDJCjao8ygeLhHcoNpdR/UISjgykZCOJe4xfbgQLXF6taHhS8q5VcGWsdhkfUJNBGZSrnpTkYCKqTJ49FzKNj0cFMOp3O
#eIx2lZRKM9HAFwTvUUfT0Xej3wKukmYeugbts+novhcTXiNX9aK06Iy/nczzXufBJtgvbwES90tmLe1K8EJamxevXDpwaxquN5Zb
#Cwu5KbEYJy3lnOZwilGbYt5dygLXFSlweylDhmPLV2S1ucsZmlX8xSsIUd7noxDL6Z2DjaNrHbHUK3xmiA6AVKXs9XyuAO2Su4X5
#1QKQhvJ1xb7MvsmYrTuNGlpF1MYtnzYJYcnJeZisCxht7pvN5Zj3NmCRqWsSNL98TmaJyZH4Wybs7oVKl0OfJycunkdvapAuKtKw
#ewHu4RSLrXRzGd+MNXFhCqlbrmDiTqU0rFAGjs1fnZfizuKpdE6RsW4BdaECFyTuR7OKgZyXC3ySZla5QdSRxwTkpauwyEDAcrXX
#2CihkYkHGT4Kk1Ga2qs1Az8vXJyZmzk1M52Zm57NzE5efGLyYtydM1UqLBdKKyXFBBOzQo4nOABfbw5kBj0ZCbUR2gzIMICgDvgT
#TosKp5JJfZayTXzh6eSJjg4y61uX1NMX0UZ4sbxS5IsxLwPlWKbRJ5/rx2gpCd0dVooAdxQNTuu5/Kq/WkFnJulOjca25HRKIKYe
#v7NOUFUz9hGqiF/zRm19vN7sZZecDaZu3Wkvbv19DVnl1GDzWjxkl7/ZEAYakwoaCEdXKqjEj/b3w6Mnh7c72NPUmoEQE2c9nxCB
#cMkzq3xnqapm1coVozejbs3UaY/AR/PqSi1XvrXcoCFm4Qq1m/4Y4mt26uzc5MVzCaqxcbqp83NqMlmx2o3eLhPehMn5J5CJDB3J
#zGRo8S6TQWaTyYhFO+Y8Ee3v8C8l907ewDrQa9nDhw/TX/i5/9L7wOHBkcGBwfTg0MNaegBeHtaih99AmKzfCiJkNKqhat4o3Ubx
#f0t/1vjTqYPpwvL1+48J9z7+Q0C7fjr+fxM/n/EXkkuqtnqfGowDPDI83GD8R1zjf3jo8IAWTd+f6hv//j8f/wEQEAb/TnO4n/4a
#/Xzmv/WWyhWL96OOxvN/xIf+Hz48nP7p/P+b+J17+4e0EPxtgn+vvqppXxThj2wi7zvh39b9X9qqfb71Gwe+GJj+xoE5co9fLV+p
#gr4mz4bmo9WVZdLsZmajpXIun9qyJfJWUcaFSU2bDoS0H/7w5Ltkud/VYtG2AIz+U/Chc1jsJjyiolJN207vQYZb0+y/2lc4HH8h
#7R0/i0nxf/uv9Yd+31zRtBnRmAdCPo38pKa1Yx5IN7eJPrF+AF+L8tkC348q3ylcVYC/xhOiXU/ZcCtFvCNVNauLmoANYKSGvt2Z
#7hH4P1XNF8uLDCvCTGU960l30g1m003++yhladZyxzTtN49qWmBTjfT+HgyuQdam3lgwtE4vEBCUAUEREJIBIRHQJAOaRECzDGgW
#AboM0EVAWAaERUCLDGgRAa0ygF4Atq50ULsg4AzuIvDgDwIVrMJHhcAJVvvxFQEJxqArH6Eag/u3UUXBPVR8sDqAibDgoLFL0yK9
#e6sTEAJ/LvGfLP95H/4BWCISFvli7AHUBqD2pXXthQD1d0ew+lhAq1QvwyN4V98PCczdUDYmjQQhJI0he+FjlwHJ+zDoAAY9QEFB
#ETSAQW+hoJAIimHQgxTUJIIGMWg/BTWLoCEMimKFuggZxpAYhkDb+0KJq8ZD8PECPJp6krsOvgBRTXf1I5gK5nOk550YY0AH9ZUP
#wnek70G9fAhe2oJrWyAmXDbgY9oA4PRyHF71MvRAJPlHdyJ6QtfLffDxyp3QwTtaELteeyRo7MakbfAwEtgJd3UDK0si3GYKAYPB
#iqzvpHGA7olUvwidt+eD0NZAT3ewDH0RealnlygHGqq/1LNbfMHg6R+AqR94yRjEEYS3B3AOfEvr/YkmJKKXtHw4EMLSzgTXdlKz
#gwd7jSFO35UOaFt5qnUYw9jgTs04jHFfDe4wRuAl0RMsP4x/3xIsH8Gm7gyWYXJFzibbg9wZ3dfuhnq7e6EsXZsNIM3SOsxRAC2i
#B9d7oMaQAdXryUBvqE0XHbh+iDoTUkXaRWMgm56Iio8wPo5htVuVtnantwTD1b1BrWJEEfdoGLYE17ZBYfoaFtnZVB7DXPOtHU1P
#i5wwbvq1/qlguLN5f2qXMQ7xnc3V57CU4/SupsN8TxtQWR+k+WU7jfEIDhXVqtbXykhgTiDuVP8I0ruHpnySov4KovTnMYtxCgJE
#6I8htIXeX2jHKBizvvWDWPpd/RiiySTWegYeB7F/m7Qsk8+OUKe2ey83Ras2hSSY2gtnMUMbgq8JSDoQ9R7l2Ck7Vs3VJOKpkeXH
#GDWgvpAGKAsUFeorvw2RQ6eRTOwL6t0GgKnzpNB5TMvTCGd377PBNaizKbkFp5qe1INGD45d7z6gXcinYGp2VFuwdmhznwEl9PUk
#2w92and3Airu0/v2GzPYO46wNuMCIp35uMDRizgn7zQf7G67o4V7tYBgiI8+qjUjrsu6wvXr2uZT1zZR1yyEPWbOiboubVRXSAPW
#yvRv1zq2Pdi93kkTGhF0vQtf16AdTeUncACIAh2gqdh1cMdd/UGb+hxwUZ9tkvqEd1GHC3LzFyq5wbFCmLDF+67xvN+XbtZ+rBH/
#7hDDEehlGEI8Wp1a+Uks6jETprveI0LXuxEsHlaZMEhTKhmmxvQFWtaB5jZFHIXp5adwGoRoQq/vQpxoWo9S/NM4bG3h3YNhPby+
#G7E3VH47dXnTwR19zcY8vG9pTQzrreVnsNfX92Du1vICfezlj2fpYx9/ZOjjAfwIld9BHw/yR5Y+AMwmIsG9mhirD2lLP9RCEi9y
#EALTs6M70t1WjSFubMUOv4y0qC/ZgiIIQMSA7x6KtJZzWGykr1OE7RlqEWFtLTwc/+FOpCWhtyjUXw+beZxGTI93aEfPSXrcpF16
#WsIS0pBHRHCMDKAj+p09kWD1JECkl5cQUa7gI4kRdltgTFu0PXHKr2sRoJptSG+PC3rbR2i3eYIa6DWvIoJtHim79CNPI6ozZnaF
#gx0CNxlrOgSFLxewZ3Y7A22+2d3V0t3V2t0VgSg3OnS1dbQlHuxoY4ToaoE3woauVngjVOiKUC+HBd1F4iqqcFPXDmYyIuTZEIXQ
#MKrU+SqGt6ghNQxpVUPejSERNeQjXBqhoBr+CQ6/Bh9vU8N/A8JdnXQdnh9YkEnKoKtGOniOj3787quv3mnv0BPhDjHRSaxrr/4u
#omxJ6bNletcPcjz1jHEIJ/VaGVF5rYJ92rQxj7K5UU/132IlN+ye+yZ+VxFaJcMfUoOQunzgHXbof8WkSPrVwB9BoKM7W5qgk5rU
#kL0QQghid0hPNQqBYXrvatY7mhU2mWA2ecLNJrWJaZ4nX4J/IKloP9BIJtFwzqFKAV2nFQGDvx0Quob4/SV843zcErTT4xy7GKR0
#go4mWoJrSNsTQE93EZW/l6nT1+mdN2LAk3/mHG3gIVifMpIRGsk2463ICMJPGSZSrBYxmMC69P5Arx5OR8J6OtTd17SnL7B7i+A7
#NQTxrU6h9yiCuUJgYoyxDTkk0Ji+zeAKyCKVzpZdu1kGaVFSGR0oX7RUjzRJ+QJ6DFkgS1UtLGT4Y9lYEyIUJlZxYNoPMRChdDdC
#hdWAp5pcKLcEAY5JHiUcFNgVXIO2N1VrGKbgmbmK4N3WSHTvcyKbENg/Bln2CoGdWgPyupDLe3aHxcseqOg5OX9seZ349mlt/yKj
#Iup3DyMOAr6B5LGG7DSFcq0WXO+nvzvXk/T3eQ42Okmaoy9jnQrFMkAMRLkey3gByxgWZRymv6H1EfrbtP6wKHOIy+RkRheXiV/G
#O0WZugZ5tG2oJ7yFec3aDoh/ev/qNUC7oL6+w9ZgdjdrlV2iQ0IvGe/CIn4cNLtQGELtMWi+G4HaQq/vwdetdug2ev0ZfN1ORf4s
#Zv918704ZHuvGT+H4/Hz8HgnML4m830Y3F1+Pwa0k5aMcutRS279+zhxdKHLHNJZl9mvsy6zyyHAKtwJ9FshtcJLL70IsRb4J81/
#lGt7SQFGuRw4K67JdIhJK+U/W+gT2qCi/aG82YbyJimAB3sfE2r7Lmr0B7DRKROg1d8Z49UADrsY4iZEQtSE7rsB1r2atO8IOqYw
#xdDz3T4aR2gN61BYYmgNBTM3Qwyt7XGF1ih0ryv03RS6zxU60oyhD7hCT1PoW1yhH6ESHnSFnqe0UQd3sbpBmSsdylwZF3h+XOD1
#GOM1Bxs7GK/HrblilYb9Nwj0v5PoPJTeROqd8UHN0npIgDZw5HeLFKjbwjSIY0LSDPXOwP7xB5gkBhQFK6CoZQEls1tBCygKWqBa
#bLbz/4KaH4Hwy/ARO4Otyemdwf29eximoAJTUIEp2ACmoFJFsPo9q4qgoizagyLHpEsZk5NiTE6JMZngMeFgYyePyUmbfqHuEoex
#2EFjkWRlA4lfm544DDMrTTMLn+3Bll1P0XfL/h1j/x71PSLiwecHEMF/EYo7+nmcEnrifJgD1z6Ek5FfP4wNS2BzP4JyUmfI+CUk
#CieC3T0RorLB1vVBKo5obShowGzq+86HcL1kDSO2BJ/HP3d3wpTYF9wpckE5H8UZzbB0NpV/Bb++M/Xqq692NYerYzrwOBuW6mUd
#GQ4L/P9AkwL/vjt7uvTg/rsMBwHQoRsfg/g7Xc5g4x+K+YC6hgaU/+f/QOuLkzq6Vfur/8O6wginDRkvcmKUax4GuWYn9fEQ9/Fh
#6uNdI48GjY9DsrC95LS/v/yr2G9ryDdILTH/Ec7R4BoyEOMT2I6r0A7zHyNOfBJH/QiqOnriur7rGHcYBpR/DVO+H1KGFbXkJRRO
#2mhUKdE/wUI+hUwZes/4pzgmEzQmCGewo2l9lBpPzIoXL/u+UwpgHRjRBVGjNCoPyFEh7tZkvIyjDGN6lEDblTodXMPX8m9gfZ/G
#x0dIEuhsZkSYCO6yKm1eP2ZXyitGfd/5ETUMI0B8eP6YExWo0mZCBVHPZ+A1+j8A0P5ONeTDEDI0vG+XiXO0S+/Uq5/Q5SzTlYQs
#WOk078x/Bo/n2u88qXf3d3GaRJtIS9Ijhx8R4UescJA7AXuoTTtojODPUatlHWHjNxHFYo0StRifJSRCORvl6R/Cv6/Dv9+DduyW
#a9PwD1Q57TkI+49KuMZyifafIez78A+IrCbwc5jw859L/AxpX4L4bsLPMcbP40wDhoLmGEoSJwhj8Ble77Xed6wb1nv1M9CR63HG
#xMfCRN+q7WHAvjVcZLPnPiHaL9mINiYQ7RFq9LhAtD045ocI0R4RiPaIc8zHGNFwzDub7+7ETYiOZuNzGsrp5d+Sw5sCCIBI/Day
#8Qfh5V/Ay56hHQwzfP8Ozh9sRd9RJdcRzBXmXAdE2jClxdUrDiBeRA2+sxUwoFVZlYh2tYgOOB1GZdezwsAl3NXHpYBifB5RIdrV
#isgwxlhwwuqQjlamRnt9YyVRkjjyb+AfSMbawwEef/mbRFyBsLMB3kKKi20bTHMD3v6eEj7CRSs0LKQNQ/wuwpEJxpFTjCMTML3f
#EV7D1RADhfbyv8QxAKb1uzaFxxzBlvXTBDRxo2DQ2Itj/Cc0r08Th3n+NA3xGCqPO0UuKOcLUA7SkEmupFohrEo4sMriKGNESCaY
#o0za9QFHAbGp704tuDbJ7GTSiU8TCjuBkWgSlb0YJr3FPYLAMppxNCasGgD5bJZhB/PoML+4qZX/TItKfvG/wwHJL06qfX1y9rGT
#AbGjhorKzeFUOjWUHhpAQRskbdxkPwIM+yHQNj4Ffz8JAsBDs7UqWmBjitOAzl8BYv/QpVmtKc37lw+dvTQFnavtgO+PgW740Mki
#LsJJ+hF4ctdLba24avbjwBASAqz9OutGhDdnGS9Qzte+gLRGI1wgfEP8QZqD+5fYTMwLVdAi3D6q4eEIt0bXulq+sFXXXqDnH+sv
#btmm/aetGH4u/ESrruVbrrbp2u+H8fkCPT9OzyEKD9D7d8OYd5pK+G/6F7ZGtG2tNV3XvgLvW7Xd4ZNtEe1AW/e2iPZKpKZHtJ9o
#Nb1T+27H3vatWuf2V9q6ta8HVoO69iMoZ6/2F1q0Uwfq93Ikov11+6e3Q8kQG9G+1o5lXup4OaJrH+7A2J+0fXaLrv1CO9b4+x1Y
#coWe4XZ8/lonpv+mhimHKPxdEQz5ctvLkW7t7VRjQcfSBgn+t0Ze2KZrbYEXAM7HCM5/3YrPF+n57DaE5HcCmD5HuYapdeHOV9q2
#an/Z8Qr0w/EAhhjb8f3JdixzKfwiQLhnyxe2dmofbd7brmudAXz/NLy/R/tBK+5c9wVwXCrNWMsfbK/p2wJ/3gSaZuD3OjH8v2yd
#Dj6ofbl5CPL+sYb98IfUD0tbXgVov96MkLzSis8stCumrbUfhVG7FcD3r207Cgh0pBnT/xyl+b8QvlU7swUh/HfUMz/Y/lFo7we7
#sPb/vhWfVXq/Qe8HqN/WqN/u0oicaJ/YDmVumYbe+1Lk5UhGew4397RvRLDk97edbOvUHqCWplu/39mpLXXube/UavT8le1L2zu1
#98PzoPZk83s7tmpbm19pI2ykffMA/bdde7WlOzJuff15pDuCy8c7tFBgu/YszKzbMB0Oa++Br8Ugfh0A3Tx0YLtWo68YfkEcCHzw
#1aON0tdH6cvQxujrNH31acfpC2fOt7Sk9gh94a7yt7Qh7SR9fS6IX2OQA7++Sl8T2hmA7FDTp5oD2iuhl+G5pekz8PwqP0MYnm/6
#LDwfoTTvpeevU+z/DP1W84DW0/55eH6v7YvNB7Tx0Jfhmd7yNXju6cD3X235BqT8XCuWvEbl/3bnt+H5/TZ8/q/2V5p17X2R78Kz
#W/8MPH8m8il4/qtt+CzRs6MDn+9uxufYdnz+so7PkdC34Xm88+Xmbu2rkT9tHtGGgt+H987gn8IzoP01xNa2aTDaD3dhyb9Itdxu
#xvcPbsHnlUCT7kzzOSp5ub1FhAe0FwPY3u8FtsD7V7Wdup3mLVbeP2nFvFhCQHsp0AMpfxDopfT/r71ngZKrqPLWe/153T3dM91N
#JIkEeyAhGUh6ZpKJSSAEJvNJRjKTSaYnIXzsvOl5mWnS0930J8kYgR4haIS4RmQP/0NUXLOIiosseECJ8hEPrpuVsMDKkawIZlHZ
#uHogi+Lee6ted88nsO7Z1XPceUnfd++tqlu3bt26Ve9Nd1Ujwi+L6lJSsgP598KKSTJl6vnMb1Vle2nShCeNN737hICLFaX7yKNM
#pq43TtfnCQ2Sijpb3+zSIKco09svdPiIotLeOtDhWkWtDPcLB9ygqDXhOlxefVZR/6btE064Q1Fv4tTuhHsUdWbgMtT0PkUtC2xF
#6kFF/Yd/n3DDtxTlCwhww1OKuiiwTxjwQ0V9GNMMeF5RM1AXD7ysqLmoiwd+IamZJYw8XlhbL9v+I2e/8MJ6RdX6iNqkqH4/UZcr
#6klOG2TqVc8xw8IIkFLUb4wrkCpKSnToV7h8UJLlcLbc7KoBehtMVBgpP6xkaj/4w1lXADYp6imMJwH4BFNjsM35EVct/HyupJaE
#r3UF4eJ5kkoEP+kKw6cV9dnQX7tmwJfmSSln13zOdSqccpak7tJf106F0lky50MYAzFtvqR07xcx58IFMqev9j7XLHhogUzzYFSc
#DW8pqtZP1GULJfUpD1HPRCX1nOcWfTbUNUrqndCDrtkwqKhf++pwnv1iY8Xyc+BnTO2feb3/kGsO1DXJnBF4Aql+RX0cDrs+AB9W
#1I3iJVc9DCnqReGCM6GkKIdWh9RTTZUa5sKLTZUa5sKr49J+xdS1cJp2DNMczZLy4fw8D37ZXMl5Fryl0i6BW/Sz4LzF1Wnti2Xa
#14Gojy2pTrtxiUy7gsv9I1NHxSshSpu7VFJrXC1ItSytpM2Hx5dV0ubDs8sqaQvg5ysqaQvgrRWVtAaInVdJo3WPgH8y/ucw4iHo
#0SuwuYbgBX5aQc2osTkanAgR/ppB+HHPRFzm6QyBugRGNuIsCxP+kPfdylbjOY2lhW2+gM2uyVAHGtNHsB+P4Dr0CK4Fj+CIL/kF
#BIF6ZRZCL1qn5K+DZoYrGLYy7GK4geEWhiaXTSKcgc8nBMdYzl5O3c+pxJ8NhxDOB1OU/IvgIPfIQe6JFwTlH+VSQiv5O+FW+HfH
#OpytJf7Vmg/jyCB8LsOFDFsY1qv879R8FRoYb9ZeqPsOzraEr9DSriM47+b8vwOUF6oRXdqFWlDE4C7vHLFBeyU0T2zRbsMoamrB
#cINIsoTLsOxycSv8qmYVwmtr1iOkaDemLfFtES9AB473E+AKD4sTcMQ/IvZqg+ErEd6Ls8Ex+CTK7NKGtN0Ia1z9Yr/2qmcf1vik
#sV94sKW3IWzA2cAj9uhfRdhZ0y8Gue2DrNWt2m5Pvzig/cS4V6S4FUnxpu9Jcb/2nPdFQaXq4H7tm64Xsa6uYB3MEn+vv4rynzde
#F83ar5xvixXa14N+7WHt94F67ZA237lbFLhFBbg7WCMOaTfry7WPMuejzLkONuBa6zrW8DrW4WntK9712jG4IxDTDmvv1F2ivaB9
#s3Y5wiRDf5Dg1c7lmOfTLoL7/cu1G9nOn2U7H9WIfwfWMkd0ib1OssPq4E3aF7ilMdgYfh31n+95RovBzd7DyJ+tLxfHtbcdz2vH
#tQeNfnEHespPUMKz4qfaCe1fna8hfKXudY16KqRfB+fXztS/rHr5suBifYX2vdDF+gNc4yPwFWO5wLpC+8Rh8SXXHv2w+E7oBoQR
#7y364/Al198iJM7jEPE+rI9pWc8WtCHpdh3DRxjeyvAgw6D+mv8p/SA8H/oH/X7m3A93+Y7oo2z/48xp1o5ov9Pv1150vIg6BLzz
#HA9wKx7gVjwD8/xLHM/CdvSTwyKmtyP+DNr/Efi8Mc9B9rnEcVg87BtA+FzQBYd5dNTrPwx9HFN/4tjnOIH+8xlHg362dpujWS/5
#70bOJaGDCK+u+5qjS5+tP+g4CDdpjzh+zHW9wnU9DlTXK1zXMdETOuZYod+pveE4JtY6dWeXoHH6OFC9j8NzweWYn+q9X3zOtdR5
#v3gzeIHzYXF1uAMhOHsQXof+eUJ7vyvmTIp5/qzzqKBajopnUOcI5OEBdz3DeXADdLrmw6Xwa6MBdsPbRhSjTq07CmF8ooviU+Qy
#hGfChQjPgRLCJfBXCM+DOxC2wUGEFzG/D+GFLLOVYRsk4GmjDZ9lN7g6GHah/IBnK6eaDBOcJ8GpCZxj/sWwGE9izvd7SpxnjOG1
#mHODaw+n7sXUBs/dzD/A8PMM7+HUg5i61PMYcw4x/C7Dp5Hf5nmZ8aMMf8rwGPIv9oAgXDDUGXrEbrjSE2G8nuGZDBuQv8dzIeOt
#DNsYbmWYYFhieDfDxxi+zPAVsR0edoPGdWk3wUFDaDfAI0aEORcyPKBRnqMInzZAJ06E4Vz9JnjFeExPYGq9g1raytBkOMbwAMND
#DF92kMWEk/B6hq0Mtzpvh2+7TcZLiL/uHmP8KENwcY0M612kYb3rBvihcSFzWl3kLVsZL7lIfonxMRfXzvAQw6MMwc06uAmPMF7P
#eKub5bipLVvdt8Msw2TOIU59mfkvI980jjJHGJQaMf6O7MzQNIh/N+MHOPVlxs+DhCiJZ9HTj4v5Woe2Vdun3aq9oZX0u/Tv6j/W
#X9OP65qjxpF0eJyXOjWcbXV+W3KO7z9x7o3q7yDMeTU3wEVhgm9rxD8v4EK8NkD4AMMFnPrPToJhH8EtfoLfZ3yWx+uWsgXO/Dp/
#nIg7ENJ3t92Io3EQd+O8Tit9D+IeHHkCtfEh7sM5X+Dc70fcD7VA31+tRbwWVwD0tBxEPIhjVEAIIX33agatZ3A1rOFT8yyEp+LY
#1WAmrlAF0nNQbglXDF74GI5jH0bQBoTXI14Dn0C8Bj6JuB9uRNwPn0I8Av04Pj6Gq4O74Rn4DTjF+0Sj+IJ4VMzWmrXztaJ2tXa9
#9pg2V0/rRf3z+kLH+Y7vO37kcJQmfif9fV6wvxbG117nPJdcQwHsLGddx+8GqvN9Rr01GF92ds1k3h9qJ/Miocm8JZPK3u48MkXZ
#tcxzcK/RWkzHftKxl3TsI/IXHW2no83caCsPLIMR/HwUPzfg5zb8HMTI+CB+HsHY+AZcA3eLvfCAuAZeEreDW7sTP7dDRvsldOtv
#MP8K/QTcpP8BHsD7L/DjdjSI9Y5u8WP8vIX42c4GsQM/V9NLwJWrVsTjLU3xJljZmUwn88O8H9CqAZu5LmMOErV4KVGrEvF4ezJP
#Z7q20cYei1dMxV3C3PXpNVahLTNoUXGkY8nE9q502sopujNVzA+vGsSKmsdV0zxlNcRdHqfbOLnELtKts5hObG2GnmKK99JHtKsj
#XRyxcopqy6QTxVzOShc20DlplN7Lv4DChG3JIaRjZn473lrzo+kE4d18xMTqYjI1aOUwYY05YnXsQAFqFwpVpHWnmSwwZVdYyBC1
#LpkvELNgjWDtfXNZ/VQmYabyyE0XliyGlX1WenCjuZONsHicEZBKr1oap3vOulJh1NLFsqWLgfcTjBWz2LrF0J7kDQnN3CgSVOV4
#aUtgJZ29SWKWkMC8xPpRjQ+2jMvZIh0CsaXj+EthyCrE+2OdyykDrOzODBZT1irm9tHmC13taOIi7SNAb7C3W33DZi4bbe3twvzr
#OVtXfu262CaIU/dC32geFYq2ZVIpuZdiPrrGQt9IYhIahTsBNlomYvKNuOSsnOBVqwaRNd6xkIU5evnU4c5cZkRqNyg15Z0KkchX
#E9RMGM4UNlq0Fwf0p/nWOijLdMg9L7iIjX8ok0zjLX6FvK9XTtRLe5BhSfKIfj4OiFLo0JiCNahsUKHjOYu2W6ACfM5qZyY3QjvV
#ypyxTMFMbeQzmbktdnns9qTE+/NorkFyItmOVdvj8dVmYjsaqzNppTBFqTs5Qao7mc+nz/XnUpNT1C4mU4kapCNxUrTlQ5+VyKC+
#kzP1qV2dT5qhO5nmuCMbPEUtw2ahN2dtS+6anNaaTV5kjU7ir0GdIJZLjnSkqYe6zSwh2KvYAyM4ggHDnTQkj6SLiPpQPpOuULT3
#qAwCnG2zmRspZnvR6Mho60gXkoXRLnUokRoHdH4ZGYSLVpFlp4W1mcz2bkJoO1Uu1c5nUzPaLY+m49Ib1TZZ43m8/6fNqsQ36KJo
#meG9eaQkHp49GLEkaWYZpya3plKse9LKrx5tt2hXDStXzinHDZM91q4Cn8BlD9aNOLyTSHbxWKTmWd1mYhiHAI7Zwjg6X03ISDWa
#tWDzsJWzThInMBbklB3prG2QLbKABxW08amrGDqa43EWjrIwpAENpyQGYw4edC5rawHFDhQxqd0aKA4NkUkqPHt6qHBa83lrZCA1
#GksWqtnkCb25TNbKFUbJGtUFJjS+khTjjVDYZrQX1ERVrNza5OCglZ5ceSc2QY2wyYld6W0cGSi+p06aSw7pYo7zVZI3Wtv6MA4V
#RjeiP+SrVKWJoyNljeB8Ru2rSpImNeUGtylzF2P5yTWieQaLicJk46q9k6bScSRrpkertJMexfxCciCZwiFVSZUnmuIYRjeVaEda
#3uVoo2mBfYuy4ACTOJ+uhe0eyewgv8wlMWB+RBaRNuJIrtDyb54VTad2Vi8LcJjyjYcGVgf2vnDQnaTd2jPbCtGOXQUrzdspR9dl
#hoYocfyAiapOoxTMgXGE0VhGNoGmK4VVrcCAlxpt+c3JNEdlyYyrOAl9tJ1OVcbVFlbcY+2ULF5aAeLDQDufsfpykzpIgop/bWYq
#NYABE43HMMnoaK9lba+YRU5FuMpRc9Q6WuqYKRj/W/GLkghYDRk+1A7JnegP0nJqWmHLl4m2GE7M0NbWx3eepoH3cZIzHRqQ8zMi
#DSq1wRw9xRFYjZOOZaZhZdOqeHxtEZsEdPhrH3oYrMlZVrqqMyv6KprDvuwVrsTGK7HT5nTLfb1wkrE52IVVQ9Lu6xh6fJSiRtT2
#OZncmqjOhcNRrXdkVKysfzjidA2lMfSh+QaTBVu1dnlu4cQkjLjlDa6q1MaAzhvITaUZxOkobXI/Gni2H1BbKmtbpuj0Xbt0j1WI
#0tyDS1Y5AdoJaM0raVW9ycyVXbkV3Yo2iDzJIhrDdyEeH1BEF40WvLNzStRuK00P2UyK4rkUrJbcOKyHcFlt5arX4eRCZb+jzRCZ
#Jzt/Ahdnf/KRHMQLfLPF0VqdJhAoLyWrl/Y0QG00joOe7nLRBVmugfuuHGpyVd3Rymd1VD8ZkLAqKpqQkG9WTpXd1Ju3zdyeNLHn
#84VkIn+yiVNWlY+qDs1jd/Snk7t4NMgFF/BCWOEyEk5atamwOJnPwXb8Ak6unyfwWPNx6zjONoE1RWfF5RjhOIR9TaZNJiwp8CRJ
#EwKsvQoop8sJl07epsProb9AUwuueKh68nWeDbmCCkWBhZceJzU0rVCi5fkpX1k85qtHS2+OzudK7iCR5GWdKXNI5m3HNcxwHkdB
#SzxeGE6WS8UqO6qh171nP1NrpEAKvHmQg6cyDb3r3BRtHcgXcvK40fwUj2ETfFkdvsrc9kyiSOsFm9e9I/vePrkDl28TY0l0rdw/
#lNtg45RQjdsHZyvWe9TDls6DPZDzlWdA5ZjmLpukZwlscKacgs5J6znlcPk8ysgDH3HTWsAnd1zxs+9ynjhxKkWIzKQTZgGw19OF
#WIaEw3o+hRRjBBkVF/+4lE3IKbF6lqziVuwD7Rj0qDHr+dA2sJc163MqNuIaIZcvVEh6oMBnBUIxr8L6yhhZso0PgOYuVCs+bunG
#TKZg09XdKwOEfFcy1XN65U0KNtrK0z2r7mqRRZvi2qssxmUQtynWSeGyRFFhXfnVGTKYbe+cMlgVLc/xkTg/1Uk0lqGul6sNjJZc
#uzoLHrpxJUgPM9UTIvA+HOr9i3ycLiR6Mjtx0bRLKlV+4pQtqZB95ijQmQHSXfjhk7MolFpmJtN5wvFBKzcKmWy8K43ebNLyVs5M
#8ulRrVvt54xxwamXjkoFgEXDgMpCFs6FRvzXDIthGUShSX2akU+cpUg10UvQ2kuhByzYBUXIw+UA4Qq1Dhd/afo2oK9ZlV4MML8H
#OqAXPz0Qgy78F8FaItAGfZhaKQulb7dBBounkZVAhfKYqQDDSNEfgCzIwQ6GxM1UpU0UFIGdiA/gPQsmS0thEyJQD0OIF1B2Bga5
#ZAqxIVZ5IVNJroHKpbDkKNeW5zSqHycbzEEaSt4I5iFpw5wWBTg1wXniE+qB/jVMRzA/yc5xPVR2vA6RKs22IZarauPkFoE52ewR
#2A2b4Col1WRZg0gtqCpHefoxz8JJVk1y3t1ozauggdoTj520dspNlk5jPQUlie5FzBNhG0ndZa7x9YxyXpQ/qxclWWByOtViYn6S
#Ah0RLjeAfGkJi62XxzZSS4eqLGQqHYaVdNuGKD9cXW+c2we+PNvdpJ+betJ8xx7Ssc5ZCdV3kpfDtqS4Z+lXgJRil4tzz1PZIc4H
#7y+g7ATbfxu3IcV2J58DT7k233ZOSZFE/yBzSWukak3lW3n2etIxoVoNnqxqMfivQF6S7Y/tCA4jRfnLbXCTVll134U5KG+8ykvB
#TxbOIYd6CWortVDbIFhN0/gDJ2tTO340gLsoLakvAlFLGpDMgtTKZ2Gd0uuotqQazWgjfw5lFzkVZZzZyLomMRCQ9KIaAY3V2l7T
#XcbJrpROFhpWPi19bDd0s6Sr2Nox5sR4BCxivE1RdF/InB6mx7cpwq3OcutlS6Ig5kweX+eqGq/iHjRZ2yHupRH0siy1bE6WZZHn
#pVFWnNsQB2kXmBeBLWyH3ElGPvtMf4THLMWIlBqVSzneUN4iaygjENkgha2gMUVSSY7J8qh+q2oMNgD0RTAEp7m0HO2FcSO1Ms7z
#nEYjKMJR1R63ZHtTjcWkHMHzElxvinW0Y8EgR4hkuRw4uVX11E9ZTkmwVWQsbYQrUDJhEL4Ye62V/WIRXISlR0H41mLPxXD6QAmm
#HY+q49BUGgxwrhyPsYTymCj7R46tZfIol5ZPqUico/bUn8wvy7HcU8Z8VCbHPgPnVCI31XollrR4dE4RERpOVkeex3KW7UztgDMn
#cqaQBpA6a+TgrK8vat/z+q2X1D7UeCk4IkIYGNGEE5FgkMgAASfRc5yuGaENImQwEXAhDJXuk7cjXrc2I3SlCBVDRWdEE6fNNCK6
#CARCY8KYERpzYpZHA01CE0ycDsExj9NLTDt1H5P7bPIQk4ds8mYmb7bJJ5h8wtUkBMoiYizIcIYHYEaodBD1wLylH2ihojarTqBq
#Y/WYs3zDlNNBc2CRopuZmD8C1IAwuGQ7HBEIoz2gzoeMyzWf143NCkNYoHk0J2g1NTXGjGDpVhEsPU0GCUNdRA+N1ITGllbYEBpb
#gfkDHtBRuxWBOac53CJI+3gFr0K+1wOaFhrrwP9Uk1bjdoVOCxUDXm+wtAfTDSOiaSg4LMimhqF7hZe1CZxmYKsCp0Noi+EVioMN
#6UezfMMPBG3KiRWW9mguHQvrWDu3jDpJoGQP9hopq2m+OiGUeQJsystr6kTFZC6ZjVtk2qUMQ7INUt5ws5lCdR63I1RneEOlO4nt
#5CJJgqU7A26HYbB5SwfwP/fiAUN2QOmAW6Wg0KRmGKh4qHQPWjoQCJzlrgnN5Y6VbQ2QGEJsnzMMA+X7qrJQ5R50zjB1KVpkbDSg
#u8KAH6EDBPBjnOH2YDmjqtB4oWg3rB5z+Mg3xvZo1P1+6Vd1MuvsOk05lxjvXKcLr7ecK8jGxVrK9sTOMLidgYB3RsgSEiXnoJ3P
#gqVjbvLtutMBfRRZZL1vUOpCsvgJESA/JyTMGRZ6SMHSw0jqbnQREMGxvV4amXiXt31et7D9kgQ1Ubkmr1vnZnJLsc0+SmqhpJaZ
#brcRYhc/KgJSPewO/I/ytDoeJlhhgGqmLGF2EczqbdI0UryOLSB5wQVucAToktHinjlu7K8aFPhbzmDfA6gH9zm6zH6MOwGdBh3i
#AWbdzDEF71LM2J3sWwdobAQC/ohgjVBWqPR7w8YNu4IapQyiwYVc8E5DWS1QUZRSgmMHI26vgSOx9EKw9JKt2c8Qx//SCJUSTTiG
#MSNloLKll2jMBuoQYVH3YWegqktPcbuM0Nxg6bgsJqVwgeNur4Yw2FKR2WJ87YL4NcEj3nONZ3aH//CDRS9tMO57eHR5w0tf2aq5
#DM2laa6A5qrRXSEDP/342eJWYcpwqXFIcct2LM3lxTwjmsvncdlxERkzA65x3owsknmaw0UeqPzTrTrWrVzP4UL7Evitx2VbFAtF
#8DOXCh73ClC/fQEnf+WFZhANw1kNITUUfngKQd0BvOh3GkVfjYZcaczFSMAXQZvsxQkhVNpv4zcjjiU0mUUzaAhQoPBGNNmNARrV
#ws7+aFXRQ1X4E4hT9AsVvRE17EN1+gIw8KPhJ4CfGscCVNIQarfM0+lHFjHtfZtzZrYnky6/2o4N5zI788JQDYYLBMyK9nTE6FVc
#aza7UL2UP39Hc1O0CSUETin/+U19gYT+uuWhIhHKEhDgqfx1A2oEuDdaKcuknaeIaOajE2hDDgHOZok6yMRO1uAcAWdV/vYx4a8K
#54z7SgssErDgXfKO/+4H/Zhz9bvknuqLN+dM8W2IP1bOEiln0lcoICQt7qC/Hzn4dQfZx8FOJ6TfIfQJ3vWHOdhH3+M+8suioqAl
#Cszm712RRL/8q5r9lxS2uP2dCipmlP84RJJd6o0Kp5S/rQGnCKid+O4ZZgoIT/XyGqcTCEx4BQ21ArxVL3Tsq6Vm7F4Q3b2kPP1W
#crCIn82Vb3KRG4RB/v76IKYdrEqjq248CRv72vuanv3AjEu6rllz/YKl3tmHvnUfyWgsjGQbtw009qxrzAxc0aj8rzFtFchDq/Zh
#zg4OQN/a1sVLPwhKzt90Kjmka+xEw/5TVj3nuGXXjUNvFSv1huw9c6e47H1f5RXHYdSeSnWbyTSM5Ondt1Xe/PkP81DGxCZNX3+R
#l+COnmnvslzFJ39tmoJPF+0dfDGmPFa1f/FjWgvCTdCHj9WbcBRtRKwL1uOjahzvPdApd12GRx1vvCPliHEyL1AUBZoJ2yLz7y8F
#SqXH3E71oNWFD2H0somuuVyKHiNNfg2YqnqQldfXHBH+xUwf8nPq1c1kSb8TlKep/K8FH1nph1Et4EU+vQYdUQ+5o9gi9YIHryne
#tMJKLmPX0c4PngmuOztOt6nKNuHcWCm7Sb0OqZRprnoP3MR1BTB/V/k1QppfUVQ0nFxHFB9UU/w7dJyYsew6zDHEpaiVWWwfaToE
#9A5ahpR2rmO94idVHbaO6f9WXdKOvfx4Poh56HXWe9mxiZ4wJpSZaJHmKlssZ9u18qs7CyUPqFcxJy8jy/2/ubJyT4K5H/xzKzJ9
#/TmuKc5/kAw++u9/p473Ov9lWcuk8x+WLJ4+/+VPcu32RiJn0AlodG502QfOWEhsdRAQpfAxMZJr8ldZOHtHb0dPrKsr0hhp61vM
#hWWWwcqXjyif+hpYPkIHso1G1DHxhQyfK2mXjOy0BiJ8Qtu5kWwuucMsWJH6IatAf36n49uS6YWRVHIHHUTJf75fyAgKy/PXGviA
#x238tTlrMMJ/G7by0Yj9bUjkZbFOVfXAKFedMotpzJaLSq0T6mszqPKlfPzb7opllCJ0vuaExuFzV8Qsa0wHKdM3UaTGEVaejjak
#6soNjCzAR5adacycGiUzjGaKfFgzPok0RKmKIn2tl4TXV9VrppL4dMDaXR65ChW8XGlNLWR2pf948J5xufeq9zzZJ9q4qWNjX9f6
#nv9DH/vjz3/i48Kmx/+f4GqO4tCePv9p+pq+pq/pa/qavqav6Wv6mr6mr+lr+pq+pq/pa/qavv4ir/8CcVRhQgBgBAA=
#__NEXUS_PAYLOAD_END__