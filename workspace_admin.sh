#!/usr/bin/env bash
# Ref: GNU Bash Manual section 3.2.5 (compound commands), 3.4 (shell
# parameters), and 6.7 (arrays); POSIX awk utility for text processing; GNU
# coreutils manual for cp/chown/rm path operations.
set -euo pipefail
IFS=$'\n\t'

readonly DESIGN_DATA_ROOT="/project/Design_Data"
readonly TEMPLATE_NAME="user_temp"
readonly CONFIG_RELATIVE_PATH="config/user_config/sos_admin.conf"
readonly USER_LIST_RELATIVE_PATH="config/user_config/user_list"
readonly EDA_ENV_RELATIVE_PATH="config/eda_config/module_temp.cshrc"
readonly WORKSPACE_RELATIVE_PATH="workspace/CDS_workspace"

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

usage() {
    cat <<'EOF'
Usage:
  workspace_admin.sh [--log]

Options:
  -l, --log   Save detailed soscmd logs under /tmp.
  -h, --help  Show this help.
EOF
}

log_success_suffix() {
    local log_file="$1"

    if [[ "$log_file" == "/dev/null" ]]; then
        return 0
    fi

    printf ' Details: %s' "$log_file"
}

log_failure_suffix() {
    local log_file="$1"

    if [[ "$log_file" == "/dev/null" ]]; then
        printf ' Run with --log for details.'
    else
        printf ' Saved log: %s' "$log_file"
    fi
}

validate_user_name() {
    local user="$1"

    [[ -n "$user" ]] || die "User name must not be empty."
    [[ "$user" != "$TEMPLATE_NAME" ]] || die "Protected template name is not allowed in user_list: $TEMPLATE_NAME"
    [[ ! "$user" =~ ^[0-9]+$ ]] || die "Invalid user name '$user': numeric UIDs are not accepted; enter a login name."
    [[ "$user" =~ ^[A-Za-z0-9_.@+-]+$ ]] \
        || die "Invalid user name '$user'. Allowed characters: A-Z a-z 0-9 _ . @ + -"
}

real_path_existing() {
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

    # Ref: POSIX awk utility. This parser accepts KEY=VALUE data only and does
    # not execute sos_admin.conf as shell code.
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

discover_project_root_from_path() {
    local path="$1"
    local suffix
    local project_name

    case "$path" in
        "$DESIGN_DATA_ROOT"/*)
            suffix=${path#"$DESIGN_DATA_ROOT"/}
            project_name=${suffix%%/*}
            [[ -n "$project_name" ]] || return 1
            printf '%s/%s\n' "$DESIGN_DATA_ROOT" "$project_name"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

discover_project_root() {
    local current_root=""
    local script_dir
    local script_root=""

    current_root=$(discover_project_root_from_path "$PWD" || true)
    if [[ -n "$current_root" ]]; then
        printf '%s\n' "$current_root"
        return
    fi

    script_dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    script_root=$(discover_project_root_from_path "$script_dir" || true)
    if [[ -n "$script_root" ]]; then
        printf '%s\n' "$script_root"
        return
    fi

    die "Run this script from inside $DESIGN_DATA_ROOT/<SOS project name>, or place it under that project tree."
}

project_name_from_root() {
    local project_root="$1"

    printf '%s\n' "${project_root##*/}"
}

select_work_lib() {
    local project_root="$1"
    local work_lib="$project_root/work_libs"

    if [[ -d "$work_lib" ]]; then
        printf '%s\n' "$work_lib"
        return
    fi

    die "Workspace directory not found: expected $work_lib"
}

load_user_list() {
    local user_list="$1"
    local line
    local trimmed

    [[ -f "$user_list" ]] || die "user_list not found: $user_list"

    desired_users=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="$line"
        trimmed=${trimmed%%#*}
        trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
        trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
        [[ -n "$trimmed" ]] || continue
        [[ "$trimmed" == \#* ]] && continue
        [[ "$trimmed" == \#\[*\] ]] && continue
        validate_user_name "$trimmed"
        if ((${#desired_users[@]} > 0)) && array_contains "$trimmed" "${desired_users[@]}"; then
            warn "Duplicate user in user_list, keeping one entry: $trimmed"
            continue
        fi
        desired_users+=("$trimmed")
    done < "$user_list"
}

array_contains() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done

    return 1
}

list_workspace_users() {
    local work_lib="$1"
    local path
    local user

    existing_users=()
    shopt -s nullglob
    for path in "$work_lib"/*; do
        [[ -d "$path" ]] || continue
        user=${path##*/}
        [[ "$user" != "$TEMPLATE_NAME" ]] || continue
        if [[ ! -d "$path/$WORKSPACE_RELATIVE_PATH" ]]; then
            warn "Skipping non-workspace directory under work_lib: $path"
            continue
        fi
        validate_user_name "$user"
        existing_users+=("$user")
    done
    shopt -u nullglob
}

require_system_user() {
    local user="$1"

    [[ "$user" =~ ^[0-9]+$ ]] && die "Invalid user name '$user': numeric UIDs are not accepted; enter a login name."

    # Ref: POSIX id utility; getent is preferred on NSS-enabled Linux systems.
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$user" >/dev/null 2>&1 || die "System user does not exist: $user"
        return
    fi

    if command -v id >/dev/null 2>&1; then
        id -u "$user" >/dev/null 2>&1 || die "System user does not exist: $user"
        return
    fi

    die "Cannot validate system users: neither getent nor id is available."
}

primary_group_for_user() {
    local user="$1"

    if command -v id >/dev/null 2>&1; then
        id -gn "$user"
        return
    fi

    printf '%s\n' "$user"
}

ensure_safe_child_path() {
    local parent="$1"
    local child="$2"
    local child_name="$3"
    local parent_real
    local child_parent_real

    [[ "$child_name" != "$TEMPLATE_NAME" ]] || die "Refusing to operate on protected template: $TEMPLATE_NAME"
    parent_real=$(real_path_existing "$parent")
    child_parent_real=$(real_path_existing "$(dirname -- "$child")")
    [[ "$child_parent_real" == "$parent_real" ]] \
        || die "Refusing to operate outside workspace directory: $child"
}

run_workspace_command_as_user() {
    local user="$1"
    local workspace_dir="$2"
    local server_name="$3"
    local project_name="$4"
    local log_file="$5"
    local env_cshrc="$6"
    local tcsh_path

    command -v sudo >/dev/null 2>&1 || die "sudo command not found; cannot run SOS workspace commands as $user."

    if [[ ! -f "$env_cshrc" ]]; then
        warn "Environment setup file not found: $env_cshrc"
        return 1
    fi

    tcsh_path=$(command -v tcsh 2>/dev/null || true)
    if [[ -z "$tcsh_path" ]]; then
        warn "tcsh command not found; cannot source module_temp.cshrc for SOS environment."
        return 1
    fi

    # Ref: sudo(8) command execution model; tcsh source command is used because
    # the project EDA environment file is a csh-style module script.
    if ! sudo -H -u "$user" bash -lc '
        set -euo pipefail
        export WORKSPACE_DIR="$1"
        export SOS_WORKSPACE_SERVER="$2"
        export SOS_WORKSPACE_PROJECT="$3"
        export SOS_ENV_CSHRC="$5"
        export TCSH_PATH="$6"
        unset DISPLAY
        unset XAUTHORITY
        exec >> "$4" 2>&1
        printf "Loading EDA/SOS environment: %s\n" "$SOS_ENV_CSHRC"
        "$TCSH_PATH" -c '"'"'
            cd "$WORKSPACE_DIR"
            source "$SOS_ENV_CSHRC"
            rehash
            which soscmd
            if ( $status != 0 ) exit 127
            soscmd newworkarea "$SOS_WORKSPACE_SERVER" "$SOS_WORKSPACE_PROJECT" -LCACHED
            if ( $status != 0 ) exit $status
            sleep 3
            soscmd populate ./
            if ( $status != 0 ) exit $status
            sleep 2
            soscmd exitsos
            exit 0
        '"'"'
    ' bash "$workspace_dir" "$server_name" "$project_name" "$log_file" "$env_cshrc" "$tcsh_path" >> "$log_file" 2>&1; then
        warn "SOS workspace command failed for $user. See log: $log_file"
        return 1
    fi
}

run_workspace_delete_as_user() {
    local user="$1"
    local workspace_dir="$2"
    local log_file="$3"
    local env_cshrc="$4"
    local tcsh_path

    command -v sudo >/dev/null 2>&1 || die "sudo command not found; cannot run SOS workspace commands as $user."

    if [[ ! -d "$workspace_dir" ]]; then
        warn "CDS workspace not found for $user; skip SOS exit step: $workspace_dir"
        return 1
    fi

    if [[ ! -f "$env_cshrc" ]]; then
        warn "Environment setup file not found: $env_cshrc"
        return 1
    fi

    tcsh_path=$(command -v tcsh 2>/dev/null || true)
    if [[ -z "$tcsh_path" ]]; then
        warn "tcsh command not found; cannot source module_temp.cshrc for SOS environment."
        return 1
    fi

    if ! sudo -H -u "$user" bash -lc '
        set -euo pipefail
        export WORKSPACE_DIR="$1"
        export SOS_ENV_CSHRC="$3"
        export TCSH_PATH="$4"
        unset DISPLAY
        unset XAUTHORITY
        exec >> "$2" 2>&1
        printf "Deleting SOS workarea from: %s\n" "$WORKSPACE_DIR"
        "$TCSH_PATH" -c '"'"'
            cd "$WORKSPACE_DIR"
            source "$SOS_ENV_CSHRC"
            rehash
            which soscmd
            if ( $status != 0 ) exit 127
            soscmd deleteworkarea -U -F
            exit $status
        '"'"'
    ' bash "$workspace_dir" "$log_file" "$env_cshrc" "$tcsh_path" >> "$log_file" 2>&1; then
        warn "SOS deleteworkarea step failed for $user. See log: $log_file"
        return 1
    fi
}

chown_workspace() {
    local path="$1"
    local owner="$2"

    # Ref: GNU coreutils chown invocation.
    command -v sudo >/dev/null 2>&1 || {
        warn "sudo command not found; cannot chown $path."
        return 1
    }
    sudo chown -R "$owner" "$path" >/dev/null 2>&1
}

copy_template_tree() {
    local template_dir="$1"
    local workspace_dir="$2"

    # Ref: GNU coreutils cp invocation; -a preserves template contents while
    # creating a new independent workspace directory.
    command -v sudo >/dev/null 2>&1 || {
        warn "sudo command not found; cannot copy template into work_libs."
        return 1
    }
    sudo cp -a -- "$template_dir" "$workspace_dir"
}

remove_workspace_tree() {
    local path="$1"

    # Ref: GNU coreutils rm invocation. Callers perform the direct-child and
    # user_temp safety checks before reaching this function.
    command -v sudo >/dev/null 2>&1 || die "sudo command not found; cannot remove $path."
    sudo rm -rf -- "$path"
}

create_workspace() {
    local work_lib="$1"
    local user="$2"
    local server_name="$3"
    local project_name="$4"
    local env_cshrc="$5"
    local log_enabled="$6"
    local template_dir="$work_lib/$TEMPLATE_NAME"
    local workspace_dir="$work_lib/$user"
    local cds_workspace="$workspace_dir/$WORKSPACE_RELATIVE_PATH"
    local log_file
    local group

    require_system_user "$user"
    [[ -d "$template_dir" ]] || die "Template directory not found: $template_dir"
    [[ ! -e "$workspace_dir" ]] || die "Workspace already exists, refusing to overwrite: $workspace_dir"
    ensure_safe_child_path "$work_lib" "$workspace_dir" "$user"
    if ((log_enabled)); then
        log_file="/tmp/workspace_admin_${user}_$(date +%Y%m%d%H%M%S).log"
        : > "$log_file"
        chmod a+rw "$log_file" 2>/dev/null || true
    else
        log_file="/dev/null"
    fi

    info "Creating workspace for $user..."
    if ! copy_template_tree "$template_dir" "$workspace_dir"; then
        [[ ! -e "$workspace_dir" ]] || remove_workspace_tree "$workspace_dir"
        die "Failed to copy template for $user."
    fi

    group=$(primary_group_for_user "$user")
    if ! chown_workspace "$workspace_dir" "$user:$group"; then
        warn "Failed to set ownership for $user; removing the incomplete workspace."
        remove_workspace_tree "$workspace_dir"
        die "Failed to set ownership for $user."
    fi

    [[ -d "$cds_workspace" ]] || die "CDS workspace path not found after template copy: $cds_workspace"
    if ! run_workspace_command_as_user "$user" "$cds_workspace" "$server_name" "$project_name" "$log_file" "$env_cshrc"; then
        warn "Workspace creation failed for $user; removing the incomplete workspace."
        remove_workspace_tree "$workspace_dir"
        die "SOS workspace command failed for $user.$(log_failure_suffix "$log_file")"
    fi
    info "Workspace created for $user.$(log_success_suffix "$log_file")"
}

remove_workspace() {
    local work_lib="$1"
    local user="$2"
    local env_cshrc="$3"
    local log_enabled="$4"
    local workspace_dir="$work_lib/$user"
    local cds_workspace="$workspace_dir/$WORKSPACE_RELATIVE_PATH"
    local log_file

    [[ "$user" != "$TEMPLATE_NAME" ]] || die "Refusing to delete protected template: $TEMPLATE_NAME"
    [[ -e "$workspace_dir" ]] || return 0
    ensure_safe_child_path "$work_lib" "$workspace_dir" "$user"
    if ((log_enabled)); then
        log_file="/tmp/workspace_admin_remove_${user}_$(date +%Y%m%d%H%M%S).log"
        : > "$log_file"
        chmod a+rw "$log_file" 2>/dev/null || true
    else
        log_file="/dev/null"
    fi

    info "Removing workspace for $user..."
    if ! run_workspace_delete_as_user "$user" "$cds_workspace" "$log_file" "$env_cshrc"; then
        die "Refusing to remove $workspace_dir because SOS deleteworkarea step failed.$(log_failure_suffix "$log_file")"
    fi
    info "SOS workarea deleted for $user."
    remove_workspace_tree "$workspace_dir"
    info "Workspace directory removed for $user.$(log_success_suffix "$log_file")"
}

main() {
    local log_enabled=0

    while (($# > 0)); do
        case "$1" in
            -l|--log)
                log_enabled=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    local project_root
    local project_name
    local config_file
    local user_list
    local env_cshrc
    local work_lib
    local template_dir
    local server_name
    local -a desired_users=()
    local -a existing_users=()
    local user
    local create_count=0
    local remove_count=0

    project_root=$(discover_project_root)
    project_name=$(project_name_from_root "$project_root")
    config_file="$project_root/$CONFIG_RELATIVE_PATH"
    user_list="$project_root/$USER_LIST_RELATIVE_PATH"
    env_cshrc="$project_root/$EDA_ENV_RELATIVE_PATH"
    work_lib=$(select_work_lib "$project_root")
    template_dir="$work_lib/$TEMPLATE_NAME"

    [[ -f "$config_file" ]] || die "sos_admin.conf not found: $config_file"
    [[ -f "$env_cshrc" ]] || die "EDA environment file not found: $env_cshrc"
    server_name=$(read_config_value "$config_file" SOS_SERVER_NAME)
    [[ -n "$server_name" ]] || die "SOS_SERVER_NAME is empty in $config_file"
    [[ -d "$template_dir" ]] || die "Protected template directory not found: $template_dir"

    info "Workspace admin started."
    info "Project      : $project_name"
    info "Project root : $project_root"
    info "Workspace dir: $work_lib"
    info "User list    : $user_list"
    info "EDA env      : $env_cshrc"
    info "SOS server   : $server_name"
    info "Template     : $template_dir (protected)"

    load_user_list "$user_list"
    list_workspace_users "$work_lib"

    if ((${#desired_users[@]} > 0)); then
        for user in "${desired_users[@]}"; do
            if ((${#existing_users[@]} > 0)) && array_contains "$user" "${existing_users[@]}"; then
                info "OK: workspace already exists for $user."
                continue
            fi
            create_workspace "$work_lib" "$user" "$server_name" "$project_name" "$env_cshrc" "$log_enabled"
            ((create_count+=1))
        done
    fi

    if ((${#existing_users[@]} > 0)); then
        for user in "${existing_users[@]}"; do
            if ((${#desired_users[@]} > 0)) && array_contains "$user" "${desired_users[@]}"; then
                continue
            fi
            remove_workspace "$work_lib" "$user" "$env_cshrc" "$log_enabled"
            ((remove_count+=1))
        done
    fi

    info "Workspace admin finished. Created: $create_count, removed: $remove_count."
}

main "$@"
