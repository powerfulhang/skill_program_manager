#!/usr/bin/env bash
# Ref: GNU Bash Manual section 3.2.5 (compound commands), 3.4 (shell parameters),
# 6.7 (arrays); POSIX awk utility for text processing.
set -euo pipefail
IFS=$'\n\t'

usage() {
    cat <<'EOF'
Usage:
  sos_admin.sh [options] add    <group> <user> [user ...]
  sos_admin.sh [options] remove <group> <user>
  sos_admin.sh [options] add-group    <group>
  sos_admin.sh [options] remove-group <group>
  sos_admin.sh [options] groups <user>
  sos_admin.sh [options] users  <group>
  sos_admin.sh [options] list-groups

Options:
      --config <path>    Path to sos_admin.conf.
                         Default: user_config/sos_admin.conf.
  -c, --cfg <path>       Path to sosd.cfg symlink or real file.
                         Default: derive from current SOS workspace path.
  -u, --user-list <path> Path to user_config/user_list.
                         Default: sibling of config/sos_config when discoverable.
  -s, --server <name>    SOS server name for "sosadmin readcfg".
                         Default: config, SOS_SERVER_NAME, SOS_SERVER, or script_config.
      --no-readcfg       Do not run "sosadmin readcfg" after changes.
      --dry-run          Validate and print intended changes, but do not edit files.
  -h, --help             Show this help.

Examples:
  sos_admin.sh add-group design_phy
  sos_admin.sh remove-group design_phy
  sos_admin.sh --config /path/to/sos_admin.conf add analog user03
  sos_admin.sh add design_analog alice bob
  sos_admin.sh remove design_analog alice
  sos_admin.sh groups alice
  sos_admin.sh users design_analog
  sos_admin.sh list-groups
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

info() {
    printf '%s\n' "$*"
}

validate_name() {
    local kind="$1"
    local value="$2"

    [[ -n "$value" ]] || die "$kind must not be empty."
    [[ "$value" =~ ^[A-Za-z0-9_.@+-]+$ ]] \
        || die "Invalid $kind '$value'. Allowed characters: A-Z a-z 0-9 _ . @ + -"
}

is_valid_name() {
    local value="$1"

    [[ -n "$value" && "$value" =~ ^[A-Za-z0-9_.@+-]+$ ]]
}

is_numeric_user_name() {
    local user="$1"

    [[ "$user" =~ ^[0-9]+$ ]]
}

validate_user_name_arg() {
    local user="$1"

    validate_name "user" "$user"
    [[ ! "$user" =~ ^[0-9]+$ ]] || die "Invalid user '$user': numeric UIDs are not accepted; enter a login name."
}

is_valid_user_name_arg() {
    local user="$1"

    is_valid_name "$user" && ! is_numeric_user_name "$user"
}

system_user_exists() {
    local user="$1"

    is_numeric_user_name "$user" && return 1

    # Ref: POSIX id utility; getent is preferred on NSS-enabled Linux systems.
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$user" >/dev/null 2>&1
        return
    fi

    if command -v id >/dev/null 2>&1; then
        id -u "$user" >/dev/null 2>&1
        return
    fi

    die "Cannot validate system users: neither getent nor id is available."
}

validate_system_user() {
    local user="$1"

    system_user_exists "$user" || die "System user does not exist: $user"
}

is_protected_group() {
    local group="$1"

    case "$group" in
        cad|analog|digital|layout)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_new_group_name() {
    local group="$1"

    validate_name "group" "$group"
    [[ "$group" == design_* ]] || die "Only RD groups with prefix design_ can be added: $group"
    if is_protected_group "$group"; then
        die "Protected group cannot be added manually: $group"
    fi
}

validate_removable_group_name() {
    local group="$1"

    validate_name "group" "$group"
    if is_protected_group "$group"; then
        die "Protected group cannot be removed: $group"
    fi
    [[ "$group" == design_* ]] || die "Only RD groups with prefix design_ can be removed: $group"
}

real_path() {
    local path="$1"

    [[ -e "$path" ]] || die "Path does not exist: $path"
    # Ref: GNU coreutils readlink invocation; -f resolves symlink chains.
    if command -v readlink >/dev/null 2>&1 && readlink -f "$path" >/dev/null 2>&1; then
        readlink -f "$path"
        return
    fi

    local dir
    local base
    dir=$(dirname -- "$path")
    base=$(basename -- "$path")
    (cd "$dir" && printf '%s/%s\n' "$(pwd -P)" "$base")
}

read_config_value() {
    local config_file="$1"
    local key="$2"

    [[ -f "$config_file" ]] || return 0

    # Ref: POSIX awk utility. The config parser accepts only KEY=VALUE data,
    # so the file is never executed as shell code.
    awk -v key="$key" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            if (line !~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) {
                next
            }
            name = line
            sub(/[[:space:]]*=.*/, "", name)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name != key) {
                next
            }
            value = line
            sub(/^[^=]*=[[:space:]]*/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$config_file"
}

discover_cfg() {
    local dir="$PWD"
    local candidate
    local wafer=""
    local prefix=""
    local -a candidates=()
    local -a matches=()
    local match

    # Ref: GNU Bash Manual section 3.5.8 (pattern matching). In the common SOS
    # work area layout, /project/Design_Data/<wafer>/work_libs/... maps to
    # /sos_data/*.rep/<wafer>/setup/sosd.cfg.
    if [[ "$PWD" == /project/Design_Data/*/work_libs/* ]]; then
        prefix=${PWD#/project/Design_Data/}
        wafer=${prefix%%/*}
        if [[ -n "${SOS_REP_NAME:-}" ]]; then
            candidates+=("/sos_data/${SOS_REP_NAME}/${wafer}/setup/sosd.cfg")
        fi
        for match in /sos_data/*.rep/"$wafer"/setup/sosd.cfg; do
            [[ -e "$match" ]] && matches+=("$match")
        done
        if ((${#matches[@]} == 1)); then
            printf '%s\n' "${matches[0]}"
            return
        fi
        if ((${#matches[@]} > 1)); then
            die "Multiple sosd.cfg files match wafer $wafer under /sos_data/*.rep. Use --cfg."
        fi
    fi

    if [[ -n "$wafer" ]]; then
        candidates+=("/project/Design_Data/${wafer}/config/sos_config/sosd.cfg")
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -e "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    while [[ "$dir" != "/" && -n "$dir" ]]; do
        candidate="$dir/config/sos_config/sosd.cfg"
        if [[ -e "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
        dir=$(dirname -- "$dir")
    done

    return 1
}

default_user_list_for_cfg() {
    local cfg_path="$1"
    local cfg_dir
    local config_dir
    local wafer

    if [[ "$cfg_path" == /sos_data/*.rep/*/setup/sosd.cfg ]]; then
        wafer=${cfg_path#/sos_data/*.rep/}
        wafer=${wafer%%/*}
        printf '/project/Design_Data/%s/config/user_config/user_list\n' "$wafer"
        return
    fi

    cfg_dir=$(dirname -- "$cfg_path")
    config_dir=$(dirname -- "$cfg_dir")
    printf '%s/user_config/user_list\n' "$config_dir"
}

default_workspace_script_for_cfg() {
    local cfg_path="$1"
    local cfg_dir
    local config_dir

    cfg_dir=$(dirname -- "$cfg_path")
    config_dir=$(dirname -- "$cfg_dir")
    printf '%s/script_config/tapeout_create_workspace.sh\n' "$config_dir"
}

discover_server_name() {
    local workspace_script="$1"

    if [[ -n "${SOS_SERVER_NAME:-}" ]]; then
        printf '%s\n' "$SOS_SERVER_NAME"
        return 0
    fi

    if [[ -n "${SOS_SERVER:-}" ]]; then
        printf '%s\n' "$SOS_SERVER"
        return 0
    fi

    [[ -f "$workspace_script" ]] || return 1

    # Ref: POSIX awk utility; match extracts sosserver_name assignment from
    # the workspace creation script described in sos-member-management-reference.md.
    awk '
        /^[[:space:]]*sosserver_name[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "", $0)
            gsub(/["'\'']/, "", $0)
            gsub(/[[:space:]]+$/, "", $0)
            print
            exit
        }
    ' "$workspace_script"
}

group_exists() {
    local cfg="$1"
    local group="$2"

    awk -v group="$group" '
        $1 == "GROUP" && $2 == group { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$cfg"
}

resolve_group_name() {
    local cfg="$1"
    local requested="$2"
    local candidate
    local resolved=""

    if group_exists "$cfg" "$requested"; then
        printf '%s\n' "$requested"
        return 0
    fi

    # Ref: POSIX awk utility. Resolve existing GROUP names case-insensitively
    # while preserving the canonical spelling recorded in sosd.cfg.
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if [[ -z "$resolved" ]]; then
            resolved="$candidate"
        else
            warn "Multiple GROUP names differ only by case; using first match '$resolved' for requested '$requested'."
            break
        fi
    done < <(
        awk -v requested="$requested" '
            $1 == "GROUP" && tolower($2) == tolower(requested) { print $2 }
        ' "$cfg"
    )

    [[ -n "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

warn_group_name_abnormal() {
    local requested="$1"
    local resolved="$2"

    if [[ "$requested" != "$resolved" ]]; then
        info "WARN: GROUP name differs from sosd.cfg: requested '$requested', using '$resolved'."
    fi
}

list_group_users_unsorted() {
    local cfg="$1"
    local group="$2"

    awk -v group="$group" "${member_awk_lib}"'
        $1 == "GROUP" && $2 == group {
            in_group = 1
            depth = brace_delta($0)
            next
        }
        in_group && $1 == "MEMBER" {
            member_count = parse_members($0, members, order)
            for (i = 1; i <= member_count; i++) {
                print order[i]
            }
        }
        in_group {
            depth += brace_delta($0)
            if (depth <= 0) {
                in_group = 0
            }
        }
    ' "$cfg"
}

member_awk_lib='
    function brace_delta(text,    tmp, opens, closes) {
        tmp = text
        opens = gsub(/\{/, "{", tmp)
        tmp = text
        closes = gsub(/\}/, "}", tmp)
        return opens - closes
    }

    function trim(text) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", text)
        return text
    }

    function clear_array(array,    key) {
        for (key in array) {
            delete array[key]
        }
    }

    function parse_members(line, members, order,    count, parts, i, member, member_count) {
        clear_array(members)
        clear_array(order)
        sub(/^[[:space:]]*MEMBER[[:space:]]+/, "", line)
        sub(/[[:space:]]*#.*/, "", line)
        sub(/[[:space:]]*;[[:space:]]*$/, "", line)
        gsub(/,/, " ", line)
        gsub(/;/, " ", line)
        count = split(line, parts, /[[:space:]]+/)
        member_count = 0
        for (i = 1; i <= count; i++) {
            member = trim(parts[i])
            if (member != "" && !(member in members)) {
                members[member] = 1
                member_count++
                order[member_count] = member
            }
        }
        return member_count
    }

    function print_members(prefix, members, order, member_count, add_user, remove_user,    i, seen, out, sep, member) {
        seen = 0
        out = prefix
        sep = ""
        for (i = 1; i <= member_count; i++) {
            member = order[i]
            if (member == remove_user) {
                continue
            }
            if (member == add_user) {
                seen = 1
            }
            out = out sep member
            sep = ", "
        }
        if (add_user != "" && seen == 0) {
            out = out sep add_user
        }
        print out ";"
    }
'

member_exists_in_group() {
    local cfg="$1"
    local group="$2"
    local user="$3"

    awk -v group="$group" -v user="$user" "${member_awk_lib}"'
        $1 == "GROUP" && $2 == group {
            in_group = 1
            depth = brace_delta($0)
            next
        }
        in_group && $1 == "MEMBER" {
            parse_members($0, members, order)
            if (user in members) {
                found = 1
            }
        }
        in_group {
            depth += brace_delta($0)
            if (depth <= 0) {
                in_group = 0
            }
        }
        END { exit found ? 0 : 1 }
    ' "$cfg"
}

list_group_users() {
    local cfg="$1"
    local group="$2"

    list_group_users_unsorted "$cfg" "$group" | sort -u
}

list_groups() {
    local cfg="$1"

    # Ref: POSIX awk utility. SOS GROUP declarations use "GROUP <name>".
    awk '$1 == "GROUP" && $2 != "" { print $2 }' "$cfg" | sort -u
}

list_user_groups() {
    local cfg="$1"
    local user="$2"

    awk -v user="$user" "${member_awk_lib}"'
        $1 == "GROUP" {
            current_group = $2
            in_group = 1
            depth = brace_delta($0)
            next
        }
        in_group && $1 == "MEMBER" {
            parse_members($0, members, order)
            if (user in members) {
                print current_group
            }
        }
        in_group {
            depth += brace_delta($0)
            if (depth <= 0) {
                current_group = ""
                in_group = 0
            }
        }
    ' "$cfg" | sort -u
}

user_has_group_in_section() {
    local cfg="$1"
    local section="$2"
    local user="$3"
    local existing_group
    local existing_section

    while IFS= read -r existing_group; do
        [[ -n "$existing_group" ]] || continue
        existing_section=$(user_list_section_for_group "$existing_group" 2>/dev/null || true)
        if [[ "$existing_section" == "$section" ]]; then
            return 0
        fi
    done < <(list_user_groups "$cfg" "$user")

    return 1
}

rewrite_group_member() {
    local cfg="$1"
    local action="$2"
    local group="$3"
    local user="$4"
    local tmp="${cfg}.tmp.$$"

    # Ref: POSIX awk utility; the script only rewrites MEMBER lines inside the
    # selected SOS GROUP block, preserving all other configuration text.
    awk -v action="$action" -v group="$group" -v user="$user" "${member_awk_lib}"'
        function rewrite_member(line,    prefix, member_count) {
            if (match(line, /^[[:space:]]*MEMBER[[:space:]]*/)) {
                prefix = substr(line, RSTART, RLENGTH)
            } else {
                print line
                return
            }

            member_count = parse_members(line, members, order)
            if (action == "add") {
                print_members(prefix, members, order, member_count, user, "")
            } else {
                print_members(prefix, members, order, member_count, "", user)
            }
        }

        $1 == "GROUP" && $2 == group {
            in_group = 1
            add_done = 0
            depth = brace_delta($0)
            print
            next
        }
        in_group && $1 == "MEMBER" {
            if (action == "remove" || add_done == 0) {
                rewrite_member($0)
                add_done = 1
            } else {
                print
            }
            next
        }
        in_group {
            depth += brace_delta($0)
            if (depth <= 0 && action == "add" && add_done == 0) {
                print "    MEMBER  " user ";"
                add_done = 1
            }
            print
            if (depth <= 0) {
                in_group = 0
            }
            next
        }
        { print }
    ' "$cfg" > "$tmp"

    mv -- "$tmp" "$cfg"
}

add_group_block() {
    local cfg="$1"
    local group="$2"
    local tmp="${cfg}.tmp.$$"

    # Ref: POSIX awk utility. Normalize trailing blank lines before appending a
    # new GROUP block so repeated add/remove cycles do not create large gaps.
    awk '
        {
            lines[NR] = $0
        }
        END {
            last = NR
            while (last > 0 && lines[last] ~ /^[[:space:]]*$/) {
                last--
            }
            for (i = 1; i <= last; i++) {
                print lines[i]
            }
        }
    ' "$cfg" > "$tmp"
    mv -- "$tmp" "$cfg"

    cat >> "$cfg" <<EOF

GROUP $group {
    MEMBER  ;
    ACL {
        READ        world;
        WRITE       group;
        MODIFY_ACL  yes;
    }
}
EOF
}

remove_group_block() {
    local cfg="$1"
    local group="$2"
    local tmp="${cfg}.tmp.$$"

    # Ref: POSIX awk utility. Brace depth is used so nested ACL blocks do not
    # terminate the selected GROUP block too early.
    awk -v group="$group" '
        function brace_delta(text,    tmp, opens, closes) {
            tmp = text
            opens = gsub(/\{/, "{", tmp)
            tmp = text
            closes = gsub(/\}/, "}", tmp)
            return opens - closes
        }

        $1 == "GROUP" && $2 == group {
            skip = 1
            depth = brace_delta($0)
            next
        }
        skip {
            depth += brace_delta($0)
            if (depth <= 0) {
                skip = 0
            }
            next
        }
        { print }
    ' "$cfg" > "$tmp"

    mv -- "$tmp" "$cfg"
}

backup_cfg() {
    local cfg="$1"
    local stamp
    local backup
    local counter=1

    stamp=$(date +%Y%m%d%H%M%S)
    backup="${cfg}.bak.${stamp}"
    while [[ -e "$backup" ]]; do
        backup="${cfg}.bak.${stamp}.${counter}"
        ((counter++))
    done
    cp -- "$cfg" "$backup"
    info "Backup created: $backup"
}

user_list_section_for_group() {
    local group="$1"

    case "$group" in
        cad)
            printf 'CAD\n'
            ;;
        analog)
            printf 'Analog\n'
            ;;
        digital)
            printf 'Digital\n'
            ;;
        layout)
            printf 'Layout\n'
            ;;
        design_*)
            printf 'Design\n'
            ;;
        *)
            die "No user_list section mapping for GROUP: $group"
            ;;
    esac
}

ensure_user_list_section() {
    local user_list="$1"
    local section="$2"

    if grep -Eq "^[[:space:]]*#\\[${section}\\][[:space:]]*$" "$user_list"; then
        return 0
    fi

    {
        printf '\n'
        printf '#[%s]\n' "$section"
    } >> "$user_list"
}

update_user_list_section_add() {
    local user_list="$1"
    local section="$2"
    local user="$3"
    local tmp="${user_list}.tmp.$$"

    ensure_user_list_section "$user_list" "$section"

    # Ref: POSIX awk utility. Inserts the user at the end of the requested
    # #[Section], before the next section header; preserves comments/header text.
    awk -v section="$section" -v user="$user" '
        function is_section(line) {
            return line ~ /^[[:space:]]*#\[[^]]+\][[:space:]]*$/
        }
        function is_target(line) {
            return line == "#[" section "]"
        }
        function flush_pending() {
            if (pending != "") {
                printf "%s", pending
                pending = ""
            }
        }
        function maybe_insert() {
            if (in_target && !seen && !inserted) {
                print user
                inserted = 1
            }
        }
        {
            trimmed = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
            if (is_section(trimmed)) {
                maybe_insert()
                flush_pending()
                in_target = is_target(trimmed)
                print
                next
            } else if (in_target && trimmed == user) {
                seen = 1
            } else if (in_target && trimmed == "") {
                pending = pending $0 "\n"
                next
            }
            flush_pending()
            print
        }
        END {
            maybe_insert()
            flush_pending()
        }
    ' "$user_list" > "$tmp"

    mv -- "$tmp" "$user_list"
}

update_user_list_add() {
    local user_list="$1"
    local group="$2"
    local user="$3"
    local section

    if [[ ! -e "$user_list" ]]; then
        warn "user_list not found, skip updating: $user_list"
        return 0
    fi

    section=$(user_list_section_for_group "$group")
    update_user_list_section_add "$user_list" "$section" "$user"
}

update_user_list_section_remove() {
    local user_list="$1"
    local section="$2"
    local user="$3"
    local tmp="${user_list}.tmp.$$"

    if [[ ! -e "$user_list" ]]; then
        warn "user_list not found, skip updating: $user_list"
        return 0
    fi

    # Ref: POSIX awk utility. Removes the user only inside the mapped
    # #[Section], preserving the same user in other sections.
    awk -v section="$section" -v user="$user" '
        function is_section(line) {
            return line ~ /^[[:space:]]*#\[[^]]+\][[:space:]]*$/
        }
        function is_target(line) {
            return line == "#[" section "]"
        }
        {
            trimmed = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
            if (is_section(trimmed)) {
                in_target = is_target(trimmed)
                print
                next
            }
            if (in_target && trimmed == user) {
                next
            }
            print
        }
    ' "$user_list" > "$tmp"

    mv -- "$tmp" "$user_list"
}

update_user_list_remove() {
    local user_list="$1"
    local group="$2"
    local user="$3"
    local section

    section=$(user_list_section_for_group "$group")
    update_user_list_section_remove "$user_list" "$section" "$user"
}

update_user_list_remove_if_section_empty_for_user() {
    local user_list="$1"
    local cfg="$2"
    local group="$3"
    local user="$4"
    local section

    section=$(user_list_section_for_group "$group")
    if ! user_has_group_in_section "$cfg" "$section" "$user"; then
        update_user_list_section_remove "$user_list" "$section" "$user"
    fi
}

run_readcfg() {
    local server="$1"
    local output
    local rc

    if [[ -z "$server" ]]; then
        warn "SOS server name not found; skip sosadmin readcfg. Use --server to enable it."
        return 0
    fi

    if ! command -v sosadmin >/dev/null 2>&1; then
        warn "sosadmin command not found; skip readcfg."
        return 0
    fi

    # Ref: SOS member management reference, section "sosadmin readcfg".
    set +e
    output=$(sosadmin readcfg "$server" 2>&1)
    rc=$?
    set -e
    if ((rc != 0)); then
        printf '%s\n' "$output" >&2
        return "$rc"
    fi
}

require_single_user() {
    local op="$1"
    local joined=""
    local arg

    shift

    if (($# != 1)); then
        for arg in "$@"; do
            joined+="$arg "
        done
        joined=${joined% }
        die "$op accepts exactly one user. Detected $# users: $joined"
    fi
}

config_arg=""
cfg_arg=""
user_list_arg=""
server_arg=""
readcfg=1
dry_run=0

while (($# > 0)); do
    case "$1" in
        --config)
            (($# >= 2)) || die "$1 requires a path."
            config_arg="$2"
            shift 2
            ;;
        -c|--cfg)
            (($# >= 2)) || die "$1 requires a path."
            cfg_arg="$2"
            shift 2
            ;;
        -u|--user-list)
            (($# >= 2)) || die "$1 requires a path."
            user_list_arg="$2"
            shift 2
            ;;
        -s|--server)
            (($# >= 2)) || die "$1 requires a name."
            server_arg="$2"
            shift 2
            ;;
        --no-readcfg)
            readcfg=0
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

(($# >= 1)) || { usage >&2; exit 1; }

command_name="$1"
shift

case "$command_name" in
    add|remove|add-group|remove-group|groups|users|list-groups)
        ;;
    *)
        die "Unknown command: $command_name"
        ;;
esac

if [[ -n "$cfg_arg" ]]; then
    cfg_source="$cfg_arg"
else
    cfg_source=$(discover_cfg) || die "Cannot find config/sos_config/sosd.cfg from current directory. Use --cfg."
fi

default_user_list=$(default_user_list_for_cfg "$cfg_source")
default_config_file="$(dirname -- "$default_user_list")/sos_admin.conf"

config_file=""
if [[ -n "$config_arg" ]]; then
    config_file="$config_arg"
    [[ -f "$config_file" ]] || die "Config file not found: $config_file"
elif [[ -f "$default_config_file" ]]; then
    config_file="$default_config_file"
fi

config_cfg=""
config_user_list=""
config_server=""
if [[ -n "$config_file" ]]; then
    config_cfg=$(read_config_value "$config_file" SOS_CFG)
    config_user_list=$(read_config_value "$config_file" SOS_USER_LIST)
    config_server=$(read_config_value "$config_file" SOS_SERVER_NAME)
fi

if [[ -z "$cfg_arg" && -n "$config_cfg" ]]; then
    cfg_source="$config_cfg"
    default_user_list=$(default_user_list_for_cfg "$cfg_source")
fi

cfg=$(real_path "$cfg_source")
[[ -f "$cfg" ]] || die "sosd.cfg is not a regular file after resolution: $cfg"

if [[ -n "$user_list_arg" ]]; then
    user_list="$user_list_arg"
elif [[ -n "$config_user_list" ]]; then
    user_list="$config_user_list"
else
    user_list="$default_user_list"
fi

workspace_script=$(default_workspace_script_for_cfg "$cfg_source")
server="$server_arg"
if [[ -z "$server" && -n "$config_server" ]]; then
    server="$config_server"
fi
if [[ -z "$server" ]]; then
    server=$(discover_server_name "$workspace_script" || true)
fi

case "$command_name" in
    add)
        (($# >= 2)) || die "add requires <group> <user> [user ...]."
        group="$1"
        shift
        users_to_add=()
        validate_name "group" "$group"
        requested_group="$group"
        group=$(resolve_group_name "$cfg" "$requested_group") || die "GROUP not found: $requested_group"
        warn_group_name_abnormal "$requested_group" "$group"
        user_list_section_for_group "$group" >/dev/null

        for user in "$@"; do
            if ! is_valid_user_name_arg "$user"; then
                warn "Invalid user '$user', skip. Use a login name with A-Z a-z 0-9 _ . @ + -, not a numeric UID."
                continue
            fi
            if ! system_user_exists "$user"; then
                warn "System user does not exist, skip: $user"
                continue
            fi
            users_to_add+=("$user")
        done
        ((${#users_to_add[@]} > 0)) || die "No valid users to add to GROUP $group."

        if ((dry_run)); then
            info "DRY RUN: would add users to GROUP $group: ${users_to_add[*]}"
            exit 0
        fi

        backup_cfg "$cfg"
        for user in "${users_to_add[@]}"; do
            if member_exists_in_group "$cfg" "$group" "$user"; then
                warn "$user already exists in GROUP $group, skip."
                continue
            fi
            rewrite_group_member "$cfg" add "$group" "$user"
            update_user_list_add "$user_list" "$group" "$user"
            info "Added $user to GROUP $group."
        done

        if ((readcfg)); then
            run_readcfg "$server"
        fi
        ;;
    remove)
        (($# >= 2)) || die "remove requires <group> <user>."
        group="$1"
        shift
        require_single_user "remove" "$@"
        user="$1"
        validate_name "group" "$group"
        validate_user_name_arg "$user"
        validate_system_user "$user"
        requested_group="$group"
        group=$(resolve_group_name "$cfg" "$requested_group") || die "GROUP not found: $requested_group"
        warn_group_name_abnormal "$requested_group" "$group"
        user_list_section_for_group "$group" >/dev/null
        member_exists_in_group "$cfg" "$group" "$user" || die "$user is not in GROUP $group."

        if ((dry_run)); then
            info "DRY RUN: would remove user from GROUP $group: $user"
            exit 0
        fi

        backup_cfg "$cfg"
        rewrite_group_member "$cfg" remove "$group" "$user"
        update_user_list_remove_if_section_empty_for_user "$user_list" "$cfg" "$group" "$user"
        info "Removed $user from GROUP $group."

        if ((readcfg)); then
            run_readcfg "$server"
        fi
        ;;
    add-group)
        (($# == 1)) || die "add-group requires exactly one group."
        group="$1"
        validate_name "group" "$group"
        existing_group=$(resolve_group_name "$cfg" "$group" 2>/dev/null || true)
        if [[ -n "$existing_group" ]]; then
            warn_group_name_abnormal "$group" "$existing_group"
            die "GROUP already exists: $existing_group"
        fi
        validate_new_group_name "$group"

        if ((dry_run)); then
            info "DRY RUN: would add GROUP $group."
            exit 0
        fi

        backup_cfg "$cfg"
        add_group_block "$cfg" "$group"
        if [[ -e "$user_list" ]]; then
            ensure_user_list_section "$user_list" Design
        else
            warn "user_list not found, skip ensuring [Design]: $user_list"
        fi
        info "Added GROUP $group."

        if ((readcfg)); then
            run_readcfg "$server"
        fi
        ;;
    remove-group)
        (($# == 1)) || die "remove-group requires exactly one group."
        group="$1"
        validate_name "group" "$group"
        requested_group="$group"
        group=$(resolve_group_name "$cfg" "$requested_group") || die "GROUP not found: $requested_group"
        warn_group_name_abnormal "$requested_group" "$group"
        validate_removable_group_name "$group"

        if ((dry_run)); then
            info "DRY RUN: would remove GROUP $group."
            exit 0
        fi

        removed_users=$(list_group_users_unsorted "$cfg" "$group")
        backup_cfg "$cfg"
        remove_group_block "$cfg" "$group"
        while IFS= read -r user; do
            [[ -n "$user" ]] || continue
            update_user_list_remove_if_section_empty_for_user "$user_list" "$cfg" "$group" "$user"
        done <<< "$removed_users"
        info "Removed GROUP $group."

        if ((readcfg)); then
            run_readcfg "$server"
        fi
        ;;
    groups)
        require_single_user "groups" "$@"
        user="$1"
        validate_user_name_arg "$user"
        validate_system_user "$user"
        list_user_groups "$cfg" "$user"
        ;;
    users)
        (($# == 1)) || die "users requires exactly one group."
        group="$1"
        validate_name "group" "$group"
        requested_group="$group"
        group=$(resolve_group_name "$cfg" "$requested_group") || die "GROUP not found: $requested_group"
        warn_group_name_abnormal "$requested_group" "$group"
        list_group_users "$cfg" "$group"
        ;;
    list-groups)
        (($# == 0)) || die "list-groups does not accept arguments."
        list_groups "$cfg"
        ;;
esac
