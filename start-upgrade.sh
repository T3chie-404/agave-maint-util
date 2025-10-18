#!/bin/bash
set -euo pipefail # Exit on error, unset variable, or pipe failure

# Script to upgrade, rollback, clean old versions, or show available tags/branches for the Agave Labs Client.
# Assumes that necessary dependencies (Rust, build tools, git) and system tunings
# (including persistent PATH setup) have already been applied to the system.
#
# Usage:
#   Upgrade:         ./script_name <tag_or_branch_for_upgrade> [-j <num_jobs>]
#   Rollback:        ./script_name rollback
#   Clean:           ./script_name clean
#   List Tags:       ./script_name --list-tags <variant> (variant: agave, jito, xandeum)
#   List Branches:   ./script_name --list-branches <variant> (variant: agave, jito, xandeum)


# Color Definitions
NC='\033[0m' # No Color
YELLOW='\033[0;33m'
RED='\033[0;31m'
GREEN='\033[1;32m'
MAGENTA='\033[0;35m'
CYAN='\033[1;36m'

# ##############################################################################
# #                                                                            #
# #               CHECK THESE CONFIGURATION VARIABLES                          #
# #                                                                            #
# ##############################################################################

# --- Configuration Variables ---
JITO_SOURCE_DIR="$HOME/data/jito-solana" 
JITO_REPO_URL="https://github.com/jito-foundation/jito-solana.git"

VANILLA_SOURCE_DIR="$HOME/data/agave"   
VANILLA_REPO_URL="https://github.com/anza-xyz/agave.git" 

XANDEUM_SOURCE_DIR="$HOME/data/xandeum-agave" 
XANDEUM_REPO_URL="https://github.com/Xandeum/xandeum-agave.git"

SOURCE_DIR_TO_SHOW=""
REPO_URL_TO_SHOW=""

COMPILED_BASE_DIR="$HOME/data/compiled" 
ACTIVE_RELEASE_SYMLINK="${COMPILED_BASE_DIR}/active_release" 
# IMPORTANT: If you change COMPILED_BASE_DIR (and thus ACTIVE_RELEASE_SYMLINK),
#            ensure your systemd service file (e.g., /etc/systemd/system/validator.service)
#            points to the correct path for the agave-validator binary,
#            either directly or by having ACTIVE_RELEASE_SYMLINK in its PATH.
#            Also, ensure your user's shell RC file (~/.bashrc or ~/.zshrc, configured by the system tuning script)
#            points to this ACTIVE_RELEASE_SYMLINK for interactive use.

LEDGER_DIR="$HOME/ledger" 
BUILD_JOBS=2 
VALIDATOR_BINARY_NAME="agave-validator" 

# Default values for validator exit command
DEFAULT_MAX_DELINQUENT_STAKE=5
DEFAULT_MIN_IDLE_TIME=5
# --- End Configuration Variables ---

# ##############################################################################
# #                                                                            #
# ##############################################################################

# --- Shell Detection Functions ---

# Detect the user's default shell (bash or zsh)
detect_user_shell() {
    local user_shell
    local shell_basename
    
    # Try to get shell from user database first
    user_shell=$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)
    
    # Fallback to SHELL environment variable
    if [ -z "$user_shell" ] || [ "$user_shell" = "/sbin/nologin" ]; then
        user_shell="${SHELL:-/bin/bash}"
    fi
    
    # Extract basename and determine type
    shell_basename=$(basename "$user_shell")
    case "$shell_basename" in
        zsh)
            echo "zsh"
            ;;
        bash)
            echo "bash"
            ;;
        *)
            # Default to bash for unknown shells
            echo "bash"
            ;;
    esac
}

# Get appropriate RC file path for the detected shell
get_rc_file_for_shell() {
    local shell_type="$1"
    case "$shell_type" in
        zsh)
            # Smart detection for zsh: prefer .zshenv if it has PATH configs
            if [ -f "$HOME/.zshenv" ] && grep -q "PATH" "$HOME/.zshenv" 2>/dev/null; then
                echo "$HOME/.zshenv"
            else
                echo "$HOME/.zshrc"
            fi
            ;;
        bash|*)
            echo "$HOME/.bashrc"
            ;;
    esac
}

# Get appropriate shell name for display
get_shell_display_name() {
    local shell_type="$1"
    case "$shell_type" in
        zsh)
            echo "Zsh"
            ;;
        bash|*)
            echo "Bash"
            ;;
    esac
}

# --- Helper: Get Active Version Directory Name ---
get_active_version_dir_name() {
    local active_dir_name=""
    if [ -L "${ACTIVE_RELEASE_SYMLINK}" ]; then
        local symlink_target
        symlink_target=$(readlink -f "${ACTIVE_RELEASE_SYMLINK}")
        if [ -n "${symlink_target}" ]; then
            local version_dir
            version_dir=$(dirname "${symlink_target}")
            active_dir_name=$(basename "${version_dir}")
        fi
    fi
    echo "${active_dir_name}"
}

# --- Show Git Info Function (Tags or Branches) ---
perform_show_git_info() {
    local info_type="$1" # "tags" or "branches"
    local variant_to_show="$2"
    echo -e "${CYAN}--- Showing Available ${info_type} for variant: ${variant_to_show} ---${NC}"

    case "${variant_to_show}" in
        agave)
            SOURCE_DIR_TO_SHOW="${VANILLA_SOURCE_DIR}"
            REPO_URL_TO_SHOW="${VANILLA_REPO_URL}"
            ;;
        jito)
            SOURCE_DIR_TO_SHOW="${JITO_SOURCE_DIR}"
            REPO_URL_TO_SHOW="${JITO_REPO_URL}"
            ;;
        xandeum)
            SOURCE_DIR_TO_SHOW="${XANDEUM_SOURCE_DIR}"
            REPO_URL_TO_SHOW="${XANDEUM_REPO_URL}"
            ;;
        *)
            echo -e "${RED}ERROR: Unknown variant '${variant_to_show}'. Valid variants are 'agave', 'jito', 'xandeum'.${NC}"
            exit 1
            ;;
    esac

    echo -e "${CYAN}Using source directory: ${SOURCE_DIR_TO_SHOW}${NC}"
    echo -e "${CYAN}Repository URL: ${REPO_URL_TO_SHOW}${NC}"

    if [ ! -d "${SOURCE_DIR_TO_SHOW}/.git" ]; then # Check for .git to ensure it's a repo
        echo -e "${YELLOW}Source directory ${SOURCE_DIR_TO_SHOW} does not exist or is not a git repository.${NC}"
        PARENT_OF_SOURCE_DIR=$(dirname "${SOURCE_DIR_TO_SHOW}")

        if [ ! -d "${PARENT_OF_SOURCE_DIR}" ]; then
            echo -e "${RED}ERROR: Parent directory ${PARENT_OF_SOURCE_DIR} for the source code does not exist.${NC}"
            echo -e "${RED}Please create it and ensure user $(whoami) has write permissions, or run this script with a user that does.${NC}"
            exit 1
        fi
        
        echo -e "${CYAN}Attempting to create ${SOURCE_DIR_TO_SHOW} with sudo and set ownership to $(whoami)...${NC}"
        if sudo mkdir -p "${SOURCE_DIR_TO_SHOW}" && sudo chown "$(whoami)":"$(id -gn)" "${SOURCE_DIR_TO_SHOW}"; then
            echo -e "${GREEN}Directory ${SOURCE_DIR_TO_SHOW} created and ownership set to $(whoami).${NC}"
        else
            echo -e "${RED}ERROR: Failed to create or set ownership for ${SOURCE_DIR_TO_SHOW} using sudo.${NC}"
            echo -e "${YELLOW}Please ensure user $(whoami) can use sudo for these operations, or manually create ${SOURCE_DIR_TO_SHOW} and grant ownership to $(whoami).${NC}"
            exit 1
        fi

        echo -e "${CYAN}Attempting to clone repository from ${REPO_URL_TO_SHOW} into ${SOURCE_DIR_TO_SHOW}...${NC}"
        if git clone "${REPO_URL_TO_SHOW}" "${SOURCE_DIR_TO_SHOW}"; then
            echo -e "${GREEN}Repository cloned successfully into ${SOURCE_DIR_TO_SHOW}.${NC}"
        else
            echo -e "${RED}ERROR: Failed to clone repository from ${REPO_URL_TO_SHOW} into ${SOURCE_DIR_TO_SHOW}.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}Source directory ${SOURCE_DIR_TO_SHOW} already exists.${NC}"
        echo -e "${CYAN}Ensuring correct ownership of existing ${SOURCE_DIR_TO_SHOW} for user $(whoami)...${NC}"
        if ! sudo chown -R "$(whoami)":"$(id -gn)" "${SOURCE_DIR_TO_SHOW}"; then
            echo -e "${RED}WARNING: Failed to set ownership for existing ${SOURCE_DIR_TO_SHOW}. Git operations might fail.${NC}"
        fi
    fi

    cd "${SOURCE_DIR_TO_SHOW}"
    echo -e "${CYAN}Fetching updates from remote origin...${NC}"
    git fetch origin --prune --tags -f # Force fetch tags to ensure local is up-to-date

    if [ "${info_type}" == "tags" ]; then
        echo -e "${GREEN}Newest 20 (approx) available tags (sorted newest semantic versions first):${NC}"
        git tag -l --sort=-v:refname | head -n 20
    elif [ "${info_type}" == "branches" ]; then
        echo -e "${GREEN}Newest 20 (approx) available branches (local and remote-tracking, sorted by most recent commit first):${NC}"
        git for-each-ref --sort=-committerdate refs/heads refs/remotes --format='%(committerdate:iso8601)    %(refname:short)' | head -n 20
        echo -e "\n${YELLOW}Tip: Remote branches are prefixed with 'origin/'.${NC}"
    fi

    exit 0
}


# --- Rollback Function ---
perform_rollback() {
    echo -e "${CYAN}--- Initiating Rollback Process ---${NC}"
    local active_version_dir_name
    active_version_dir_name=$(get_active_version_dir_name)

    echo -e "${YELLOW}Available compiled versions in ${COMPILED_BASE_DIR}:${NC}"
    mapfile -t available_versions < <(find "${COMPILED_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d -not -name "$(basename "${ACTIVE_RELEASE_SYMLINK}")" -not -name "*_before_*" -printf "%f\n" | sort -V)

    if [ ${#available_versions[@]} -eq 0 ]; then
        echo -e "${RED}No compiled versions found in ${COMPILED_BASE_DIR} to roll back to.${NC}"
        exit 1
    fi

    local display_versions=()
    for version in "${available_versions[@]}"; do
        if [[ "${version}" == "${active_version_dir_name}" ]]; then
            display_versions+=("${version} (Currently Active)")
        else
            display_versions+=("${version}")
        fi
    done

    echo -e "${YELLOW}Please select a version to roll back to:${NC}"
    select version_choice in "${display_versions[@]}" "CancelRollback"; do
        local version_to_rollback_to
        version_to_rollback_to=$(echo "$version_choice" | awk '{print $1}') 

        if [[ "$REPLY" == "CancelRollback" || "$version_to_rollback_to" == "CancelRollback" ]]; then
            echo -e "${RED}Rollback cancelled by user.${NC}"
            exit 1
        elif [[ -n "$version_to_rollback_to" ]]; then
            is_valid_selection=false
            for v_check in "${available_versions[@]}"; do
                if [[ "$v_check" == "$version_to_rollback_to" ]]; then
                    is_valid_selection=true
                    break
                fi
            done
            if ! $is_valid_selection; then
                 echo -e "${RED}Invalid selection. Please choose a number from the list or select 'CancelRollback'.${NC}"
                 continue 
            fi

            echo -e "${GREEN}Selected version for rollback: ${version_to_rollback_to}${NC}"
            break
        else
            echo -e "${RED}Invalid selection. Please choose a number from the list or select 'CancelRollback'.${NC}"
        fi
    done

    COMPILED_ROLLBACK_BIN_DIR="${COMPILED_BASE_DIR}/${version_to_rollback_to}/bin"

    if [ ! -d "${COMPILED_ROLLBACK_BIN_DIR}" ]; then
        echo -e "${RED}ERROR: Binary directory ${COMPILED_ROLLBACK_BIN_DIR} does not exist for selected version '${version_to_rollback_to}'.${NC}"
        exit 1
    fi

    echo -e "${CYAN}Preparing to update symlink ${ACTIVE_RELEASE_SYMLINK} to point to ${COMPILED_ROLLBACK_BIN_DIR}${NC}"
    if [ -L "${ACTIVE_RELEASE_SYMLINK}" ]; then
        backup_name="${ACTIVE_RELEASE_SYMLINK}_$(date +%Y%m%d%H%M%S)_before_rollback"
        echo -e "${YELLOW}Backing up current symlink from $(readlink -f "${ACTIVE_RELEASE_SYMLINK}") to: ${backup_name}${NC}"
        mv "${ACTIVE_RELEASE_SYMLINK}" "${backup_name}"
    elif [ -e "${ACTIVE_RELEASE_SYMLINK}" ]; then
       echo -e "${RED}ERROR: ${ACTIVE_RELEASE_SYMLINK} exists but is not a symlink. Manual intervention required.${NC}"
       exit 1
    fi
    
    echo -e "${CYAN}Creating new symlink: ${ACTIVE_RELEASE_SYMLINK} -> ${COMPILED_ROLLBACK_BIN_DIR}${NC}"
    ln -sf "${COMPILED_ROLLBACK_BIN_DIR}" "${ACTIVE_RELEASE_SYMLINK}"

    echo -e "${GREEN}\nVerifying rolled-back version using binary from symlink (direct path)...${NC}"
    VALIDATOR_EXECUTABLE_PATH_ROLLBACK="${ACTIVE_RELEASE_SYMLINK}/${VALIDATOR_BINARY_name}"
    if [ -x "${VALIDATOR_EXECUTABLE_PATH_ROLLBACK}" ]; then
        echo -e "${CYAN}Running: ${VALIDATOR_EXECUTABLE_PATH_ROLLBACK} -V${NC}"
        "${VALIDATOR_EXECUTABLE_PATH_ROLLBACK}" -V
    else
        echo -e "${RED}ERROR: ${VALIDATOR_BINARY_name} not found or not executable at ${VALIDATOR_EXECUTABLE_PATH_ROLLBACK}${NC}"
    fi
    echo -e "${MAGENTA}\nSuccessfully rolled back. Active version now points to binaries from: ${version_to_rollback_to}${NC}"

    echo -e "${GREEN}\nPerforming secondary verification (from home directory using system PATH)...${NC}"
    (
      current_dir_before_cd_test=$(pwd)
      cd ~ 
      echo -e "${CYAN}Temporarily changed to directory: $(pwd)${NC}"
      echo -e "${CYAN}Attempting to run: ${VALIDATOR_BINARY_NAME} -V (using existing system PATH)${NC}"
      if command -v "${VALIDATOR_BINARY_NAME}" &> /dev/null; then
          "${VALIDATOR_BINARY_NAME}" -V
          echo -e "${GREEN}Secondary verification successful: '${VALIDATOR_BINARY_NAME}' found in system PATH.${NC}"
      else
          local detected_shell_type
          detected_shell_type=$(detect_user_shell)
          local detected_rc_file
          detected_rc_file=$(get_rc_file_for_shell "$detected_shell_type")
          echo -e "${YELLOW}WARNING: Command '${VALIDATOR_BINARY_NAME}' not found in system PATH when run from $(pwd).${NC}"
          echo -e "${YELLOW}Ensure '${ACTIVE_RELEASE_SYMLINK}' is permanently in your system PATH (e.g., via ${detected_rc_file} and a new terminal session).${NC}"
      fi
      cd "${current_dir_before_cd_test}" 
    )
    echo -e "${GREEN}Secondary verification attempt complete.${NC}"

    echo
    local max_delinquent_stake="${DEFAULT_MAX_DELINQUENT_STAKE}"
    local min_idle_time="${DEFAULT_MIN_IDLE_TIME}"
    read -r -p "Enter max delinquent stake percentage for restart [default: ${DEFAULT_MAX_DELINQUENT_STAKE}]: " user_max_delinquent
    if [ -n "${user_max_delinquent}" ]; then max_delinquent_stake="${user_max_delinquent}"; fi
    read -r -p "Enter min idle time (seconds) for restart [default: ${DEFAULT_MIN_IDLE_TIME}]: " user_min_idle
    if [ -n "${user_min_idle}" ]; then min_idle_time="${user_min_idle}"; fi

    read -r -p "Rollback to ${version_to_rollback_to} prepared. Press 'x' (then Enter) to exit script WITHOUT restarting validator, or just Enter to proceed with restart (using max_delinquent_stake=${max_delinquent_stake}, min_idle_time=${min_idle_time}): " final_user_input_rb_before_restart
    if [[ "${final_user_input_rb_before_restart,,}" == "x" ]]; then
        echo -e "${CYAN}Exiting script now as per user request. Validator restart NOT initiated.${NC}"
        exit 0
    fi

    echo -e "${GREEN}Proceeding with validator exit command...${NC}"
    sleep 1
    "${VALIDATOR_EXECUTABLE_PATH_ROLLBACK}" --ledger "${LEDGER_DIR}" exit --max-delinquent-stake "${max_delinquent_stake}" --min-idle-time "${min_idle_time}" --monitor
    echo -e "${GREEN}\nExit command sent. Validator should restart with the rolled-back version.${NC}"
    echo -e "${GREEN}ROLLBACK DONE${NC}"
    
    echo
    read -r -p "Press 'x' (then Enter) to exit script now, or just Enter to complete and exit: " final_user_input_rb
    if [[ "${final_user_input_rb,,}" == "x" ]]; then
        echo -e "${CYAN}Exiting script now as per user request.${NC}"
        exit 0
    fi
    exit 0
}

# --- Clean Function ---
perform_clean() {
    # ... (clean function remains the same as previous version) ...
    echo -e "${CYAN}--- Initiating Cleanup Process for Old Compiled Versions ---${NC}"
    local active_version_dir_name
    active_version_dir_name=$(get_active_version_dir_name)

    echo -e "${YELLOW}Identifying compiled versions in ${COMPILED_BASE_DIR} (excluding backups)...${NC}"
    mapfile -t all_compiled_versions < <(find "${COMPILED_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d -not -name "$(basename "${ACTIVE_RELEASE_SYMLINK}")" -not -name "*_before_*" -printf "%f\n" | sort -V)

    if [ ${#all_compiled_versions[@]} -eq 0 ]; then
        echo -e "${RED}No compiled versions found in ${COMPILED_BASE_DIR} to clean.${NC}"
        exit 0
    fi

    local deletable_version_tags=() 
    echo -e "\n${GREEN}Deletable versions (select by number):${NC}"
    
    for i in "${!all_compiled_versions[@]}"; do
        version_name="${all_compiled_versions[$i]}"
        if [[ "${version_name}" == "${active_version_dir_name}" ]]; then
            echo -e "  ${MAGENTA}${version_name} (Currently Active - Not Selectable for Deletion)${NC}"
        else
            deletable_version_tags+=("${version_name}")
            echo -e "  $((${#deletable_version_tags[@]}))) ${CYAN}${version_name}${NC}" 
        fi
    done
    
    if [ ${#deletable_version_tags[@]} -eq 0 ]; then
        echo -e "${YELLOW}No versions eligible for deletion (only active version exists or other non-version directories).${NC}"
        exit 0
    fi

    echo -e "\n${YELLOW}Enter the NUMBERS of the versions you want to delete, separated by spaces (e.g., 1 3 5).${NC}"
    echo -e "${RED}WARNING: This action is irreversible.${NC}"
    read -r -p "Numbers of versions to delete: " version_numbers_input

    if [ -z "${version_numbers_input}" ]; then
        echo -e "${CYAN}No numbers entered. Exiting clean process.${NC}"
        exit 0
    fi

    read -r -a version_numbers_array <<< "$version_numbers_input"
    
    local final_tags_to_delete=()
    local total_space_to_free_mb=0
    echo -e "\n${CYAN}You have selected the following versions for DELETION:${NC}"
    local selection_valid=false
    for num_str in "${version_numbers_array[@]}"; do
        if ! [[ "$num_str" =~ ^[0-9]+$ ]]; then
            echo -e "  - ${RED}'${num_str}' is not a valid number. Skipping.${NC}"
            continue
        fi

        local index=$((num_str - 1)) 

        if [ "$index" -ge 0 ] && [ "$index" -lt "${#deletable_version_tags[@]}" ]; then
            local selected_tag_name="${deletable_version_tags[$index]}"
            
            is_already_selected=false
            for existing_tag in "${final_tags_to_delete[@]}"; do
                if [[ "${existing_tag}" == "${selected_tag_name}" ]]; then
                    is_already_selected=true
                    break
                fi
            done

            if ! $is_already_selected; then
                echo -e "  - ${YELLOW}${selected_tag_name} (from number ${num_str})${NC}"
                final_tags_to_delete+=("${selected_tag_name}")
                
                local dir_to_check="${COMPILED_BASE_DIR}/${selected_tag_name}"
                if [ -d "${dir_to_check}" ]; then
                    local space_mb
                    space_mb=$(du -sm "${dir_to_check}" | awk '{print $1}')
                    if [[ "${space_mb}" =~ ^[0-9]+$ ]]; then
                        total_space_to_free_mb=$((total_space_to_free_mb + space_mb))
                    else
                        echo -e "    ${RED}Warning: Could not determine size for ${selected_tag_name}${NC}"
                    fi
                fi
            else
                 echo -e "  - ${YELLOW}${selected_tag_name} (from number ${num_str} - already listed)${NC}"
            fi
            selection_valid=true
        else
            echo -e "  - ${RED}Number '$num_str' is out of range for deletable versions. Skipping.${NC}"
        fi
    done

    if ! $selection_valid || [ ${#final_tags_to_delete[@]} -eq 0 ]; then
        echo -e "${CYAN}No valid versions marked for deletion. Exiting clean process.${NC}"
        exit 0
    fi

    echo
    echo -e "${YELLOW}Total estimated disk space to be freed: ${GREEN}${total_space_to_free_mb} MB${NC}"
    read -r -p "ARE YOU SURE you want to permanently delete these ${#final_tags_to_delete[@]} version(s)? (yes/no): " final_confirmation
    if [[ "${final_confirmation,,}" != "yes" && "${final_confirmation,,}" != "y" ]]; then
        echo -e "${RED}Deletion cancelled by user.${NC}"
        exit 1
    fi

    echo -e "\n${GREEN}Proceeding with deletion...${NC}"
    for tag_to_delete in "${final_tags_to_delete[@]}"; do
        local dir_to_delete="${COMPILED_BASE_DIR}/${tag_to_delete}"
        if [ -d "${dir_to_delete}" ]; then
            echo -e "${CYAN}Deleting directory: ${dir_to_delete}${NC}"
            if rm -rf "${dir_to_delete}"; then
                echo -e "${GREEN}Successfully deleted ${dir_to_delete}${NC}"
            else
                echo -e "${RED}ERROR: Failed to delete ${dir_to_delete}${NC}"
            fi
        else
            echo -e "${YELLOW}Warning: Directory ${dir_to_delete} for tag '${tag_to_delete}' not found (already deleted or invalid selection).${NC}"
        fi
    done

    echo -e "\n${GREEN}CLEANUP PROCESS COMPLETE.${NC}"
    exit 0
}

# --- Main Script Logic ---

# Assumes dependencies (git, cargo, rsync, jq, etc.) are pre-installed.
if [ -z "${1:-}" ]; then 
    echo -e "${RED}\n:::ERROR::: ${CYAN}No argument provided.${NC}"
    echo -e "${CYAN}Usage for Upgrade: ${YELLOW}$(basename "$0") <tag_or_branch_for_upgrade> [-j <num_jobs>]${NC}"
    echo -e "${CYAN}        or         ${YELLOW}$(basename "$0") --list-tags <variant> | --list-branches <variant>${NC}"
    echo -e "${CYAN}                   (variant: agave, jito, xandeum)${NC}"
    echo -e "${CYAN}Usage for Rollback: ${YELLOW}$(basename "$0") rollback${NC}"
    echo -e "${CYAN}Usage for Cleanup:  ${YELLOW}$(basename "$0") clean\n${NC}"
    exit 1
fi

MODE_OR_REF_ARG="$1"

# Check for --list-tags or --list-branches options
if [ "${MODE_OR_REF_ARG}" == "--list-tags" ]; then
    if [ -z "${2:-}" ]; then
        echo -e "${RED}ERROR: --list-tags option requires a variant (agave, jito, xandeum).${NC}"
        exit 1
    fi
    perform_show_git_info "tags" "$2" # Exits after showing
elif [ "${MODE_OR_REF_ARG}" == "--list-branches" ]; then
    if [ -z "${2:-}" ]; then
        echo -e "${RED}ERROR: --list-branches option requires a variant (agave, jito, xandeum).${NC}"
        exit 1
    fi
    perform_show_git_info "branches" "$2" # Exits after showing
fi


if [ "${MODE_OR_REF_ARG}" == "rollback" ]; then
    perform_rollback 
elif [ "${MODE_OR_REF_ARG}" == "clean" ]; then
    perform_clean 
fi

# If not rollback, clean, or a show option, assume upgrade. 
target_ref="${MODE_OR_REF_ARG}" # $1 is the tag or branch
# Sanitize the ref name for use as a directory name (replaces '/' with '_')
sanitized_ref_name=$(echo "${target_ref}" | tr '/' '_')

# Argument parsing for -j (optional, can be $2 and $3 if present)
if [ "$#" -gt 1 ]; then 
    if [ "$2" == "-j" ]; then
        if [ -n "$3" ] && [[ "$3" =~ ^[0-9]+$ ]] && [ "$3" -gt 0 ]; then
            BUILD_JOBS="$3"
            echo -e "${CYAN}Using custom number of build jobs: ${GREEN}${BUILD_JOBS}${NC}"
        else
            echo -e "${RED}\n:::ERROR::: ${CYAN}Invalid value for -j. Please provide a positive integer for number of jobs.${NC}"
            exit 1
        fi
        if [ "$#" -gt 3 ]; then # $1=ref, $2=-j, $3=jobs. Anything more is an error.
            echo -e "${RED}\n:::ERROR::: ${CYAN}Too many arguments. Unexpected arguments after -j <num_jobs>.${NC}"
            exit 1
        fi
    else # If $2 is present but not -j, it's an error
       echo -e "${RED}\n:::ERROR::: ${CYAN}Invalid arguments. Expected '-j <num_jobs>' or no other arguments after ref.${NC}"
       exit 1
    fi
fi


echo -e "${CYAN}\n--- Initiating Upgrade Process ---${NC}"
echo -e "${CYAN}Target ref (tag/branch) for upgrade: ${GREEN}${target_ref}${NC}"

# Determine which source directory to use based on the ref
if [[ "${target_ref}" == *"-jito" ]]; then
    SOURCE_DIR="${JITO_SOURCE_DIR}"
    REPO_URL_TO_CLONE="${JITO_REPO_URL}"
    echo -e "${GREEN}Ref ends with '-jito'. Using Jito source directory: ${SOURCE_DIR}${NC}"
elif [[ "${target_ref}" == x* ]]; then # If ref starts with 'x', it could be Xandeum
    echo -e "${YELLOW}The provided ref '${target_ref}' starts with 'x'.${NC}"
    echo -e "${YELLOW}This might be a Xandeum-Agave client build.${NC}"
    echo -e " - Xandeum-Agave client will be built from: ${XANDEUM_SOURCE_DIR}"
    
    read -r -p "Do you want to proceed with building the Xandeum-Agave client from ${XANDEUM_SOURCE_DIR}? (yes/no): " confirmation
    if [[ "${confirmation,,}" == "yes" || "${confirmation,,}" == "y" ]]; then
        SOURCE_DIR="${XANDEUM_SOURCE_DIR}"
        REPO_URL_TO_CLONE="${XANDEUM_REPO_URL}"
        echo -e "${GREEN}Confirmed. Using Xandeum-Agave source directory: ${SOURCE_DIR}${NC}"
    else
        echo -e "${RED}Build cancelled by user. For Jito, use '-jito' suffix. For vanilla, use a ref not starting with 'x'.${NC}"
        exit 1
    fi
else # Default to vanilla Agave if not ending in -jito and not starting with x
    echo -e "${YELLOW}The provided ref '${target_ref}' does not end with '-jito' and does not start with 'x'.${NC}"
    echo -e "${YELLOW}This suggests you might want to build the vanilla Agave client.${NC}"
    echo -e " - Vanilla Agave client will be built from: ${VANILLA_SOURCE_DIR}"
    
    read -r -p "Do you want to proceed with building the vanilla Agave client from ${VANILLA_SOURCE_DIR}? (yes/no): " confirmation
    if [[ "${confirmation,,}" == "yes" || "${confirmation,,}" == "y" ]]; then
        SOURCE_DIR="${VANILLA_SOURCE_DIR}"
        REPO_URL_TO_CLONE="${VANILLA_REPO_URL}"
        echo -e "${GREEN}Confirmed. Using vanilla Agave source directory: ${SOURCE_DIR}${NC}"
    else
        echo -e "${RED}Build cancelled by user. For Jito, use '-jito' suffix. For Xandeum, use an 'x' prefixed ref.${NC}"
        exit 1
    fi
fi

# --- Upgrade Path (continues if not rollback or clean) ---

export tag="${target_ref}" 
export RUSTFLAGS="-O -C target-cpu=native"

# Handle SOURCE_DIR creation and cloning
if [ ! -d "${SOURCE_DIR}" ]; then
    echo -e "${YELLOW}Source directory ${SOURCE_DIR} does not exist.${NC}"
    
    echo -e "${CYAN}Attempting to create ${SOURCE_DIR} with sudo and set ownership to $(whoami)...${NC}"
    if sudo mkdir -p "${SOURCE_DIR}"; then
        echo -e "${GREEN}Directory structure ${SOURCE_DIR} ensured/created.${NC}"
        if sudo chown "$(whoami)":"$(id -gn)" "${SOURCE_DIR}"; then
            echo -e "${GREEN}Ownership of ${SOURCE_DIR} set to $(whoami).${NC}"
        else
            echo -e "${RED}ERROR: Failed to set ownership for ${SOURCE_DIR} to $(whoami).${NC}"
            echo -e "${YELLOW}Please check sudo permissions or manually ensure $(whoami) owns ${SOURCE_DIR}.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}ERROR: Failed to create directory ${SOURCE_DIR} using sudo.${NC}"
        echo -e "${YELLOW}Please check permissions for parent directories (e.g. $(dirname "${SOURCE_DIR}")) and sudo capabilities.${NC}"
        exit 1
    fi

    echo -e "${CYAN}Attempting to clone repository from ${REPO_URL_TO_CLONE} into ${SOURCE_DIR}...${NC}"
    if git clone "${REPO_URL_TO_CLONE}" "${SOURCE_DIR}"; then
        echo -e "${GREEN}Repository cloned successfully into ${SOURCE_DIR}.${NC}"
    else
        echo -e "${RED}ERROR: Failed to clone repository from ${REPO_URL_TO_CLONE} into ${SOURCE_DIR}.${NC}"
        echo -e "${YELLOW}This might happen if the directory is not truly empty after creation, or due to other git issues.${NC}"
        echo -e "${YELLOW}Please check clone output above and directory permissions.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}Source directory ${SOURCE_DIR} already exists.${NC}"
    echo -e "${CYAN}Ensuring correct ownership of existing ${SOURCE_DIR} for user $(whoami)...${NC}"
    if ! sudo chown -R "$(whoami)":"$(id -gn)" "${SOURCE_DIR}"; then
        echo -e "${RED}WARNING: Failed to set ownership for existing ${SOURCE_DIR}. Git/Build operations might fail.${NC}"
    fi
fi


echo -e "${CYAN}Navigating to source directory for upgrade: ${SOURCE_DIR}${NC}"
cd "${SOURCE_DIR}"

echo -e "${CYAN}Fetching updates from git remote origin for upgrade...${NC}"
git fetch origin --prune --tags -f

echo -e "${GREEN}\nStarting upgrade process for ref: ${CYAN}${target_ref}${NC}"
sleep 2

echo -e "${CYAN}Attempting to checkout ref: ${target_ref}${NC}"
echo -e "${YELLOW}Note: Forcing checkout. Any uncommitted local changes in the source directory may be overwritten.${NC}"
git checkout -f "${target_ref}" 
if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to checkout ref '${target_ref}'. It may not exist on the remote repository.${NC}"
    exit 1
fi
echo -e "${GREEN}Successfully checked out ref: ${target_ref}${NC}"

# If the checked-out ref is a branch (not a detached HEAD from a tag), pull the latest changes.
if git symbolic-ref -q HEAD &> /dev/null; then
    # We are on a branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    echo -e "${CYAN}Checked out a branch ('${current_branch}'). Pulling latest changes from origin...${NC}"
    if git pull origin "${current_branch}"; then
        echo -e "${GREEN}Successfully pulled latest changes for branch '${current_branch}'.${NC}"
    else
        echo -e "${RED}WARNING: 'git pull' failed for branch '${current_branch}'. The build will proceed with the last known state of the branch, which might be old.${NC}"
    fi
else
    # We are in a detached HEAD state (e.g., from a tag)
    echo -e "${CYAN}Checked out a tag or specific commit (detached HEAD). Skipping 'git pull'.${NC}"
fi


echo -e "${CYAN}Updating submodules...${NC}"
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR" git submodule update --init --recursive
if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to update submodules for ref ${target_ref}${NC}"
    exit 1
fi

echo -e "${GREEN}Ready to build...${NC}"
sleep 5

echo -e "${GREEN}Building ref ${target_ref} (CARGO_BUILD_JOBS=${BUILD_JOBS})...${NC}"
export CI_COMMIT
CI_COMMIT=$(git rev-parse HEAD)
echo -e "${CYAN}Using CI_COMMIT=${CI_COMMIT} for the build.${NC}"
export CARGO_BUILD_JOBS="${BUILD_JOBS}"

CARGO_INSTALL_ALL_SCRIPT="./scripts/cargo-install-all.sh"
if [ -x "${CARGO_INSTALL_ALL_SCRIPT}" ]; then
    echo -e "${GREEN}Using ${CARGO_INSTALL_ALL_SCRIPT} for build...${NC}"
    if ! "${CARGO_INSTALL_ALL_SCRIPT}" .; then 
        echo -e "${RED}ERROR: Build failed using ${CARGO_INSTALL_ALL_SCRIPT} for ref ${target_ref}${NC}"
        exit 1
    fi
else
    echo -e "${RED}ERROR: Build script ${CARGO_INSTALL_ALL_SCRIPT} not found or not executable in ${SOURCE_DIR}/scripts/.${NC}"
    echo -e "${YELLOW}The build process may not embed the source hash correctly without this script.${NC}"
    read -r -p "Proceed with fallback 'cargo build --release' method? (yes/NO): " fallback_confirmation
    if [[ "${fallback_confirmation,,}" != "yes" && "${fallback_confirmation,,}" != "y" ]]; then
        echo -e "${RED}Build cancelled by user due to missing ${CARGO_INSTALL_ALL_SCRIPT}.${NC}"
        exit 1
    fi
    
    if [ -x "./cargo" ]; then
        CARGO_CMD="./cargo"
    else
        CARGO_CMD="cargo"
    fi
    if ! ${CARGO_CMD} b --release -j "${BUILD_JOBS}"; then 
        echo -e "${RED}ERROR: Standard cargo build failed for ref ${target_ref}${NC}"
        exit 1
    fi
fi
unset CARGO_BUILD_JOBS 
echo -e "${GREEN}Build successful for ${target_ref}.${NC}"

COMPILED_VERSION_BIN_DIR="${COMPILED_BASE_DIR}/${sanitized_ref_name}/bin"

if [ ! -d "${COMPILED_BASE_DIR}" ]; then
    echo -e "${YELLOW}Compiled base directory ${COMPILED_BASE_DIR} does not exist.${NC}"
    echo -e "${CYAN}Attempting to create ${COMPILED_BASE_DIR} with sudo and set ownership to $(whoami)...${NC}"
    if sudo mkdir -p "${COMPILED_BASE_DIR}" && sudo chown "$(whoami)":"$(id -gn)" "${COMPILED_BASE_DIR}"; then
        echo -e "${GREEN}Directory ${COMPILED_BASE_DIR} created and ownership set.${NC}"
    else
        echo -e "${RED}ERROR: Failed to create or set ownership for ${COMPILED_BASE_DIR}.${NC}"
        exit 1
    fi
elif ! [ -w "${COMPILED_BASE_DIR}" ] || ! [ "$(stat -c '%U' "${COMPILED_BASE_DIR}")" == "$(whoami)" ]; then
    echo -e "${YELLOW}Compiled base directory ${COMPILED_BASE_DIR} exists but might not be writable/owned by $(whoami).${NC}"
    echo -e "${CYAN}Attempting to set ownership of ${COMPILED_BASE_DIR} to $(whoami)...${NC}"
    if ! sudo chown -R "$(whoami)":"$(id -gn)" "${COMPILED_BASE_DIR}"; then 
        echo -e "${RED}WARNING: Failed to ensure ownership for ${COMPILED_BASE_DIR}. Directory creation might fail.${NC}"
    else
        echo -e "${GREEN}Ownership of ${COMPILED_BASE_DIR} ensured for $(whoami).${NC}"
    fi
fi

echo -e "${CYAN}Creating directory for compiled version: ${COMPILED_VERSION_BIN_DIR}${NC}"
mkdir -p "${COMPILED_VERSION_BIN_DIR}" 

echo -e "${CYAN}Syncing compiled binaries...${NC}"
BUILD_OUTPUT_DIR="${SOURCE_DIR}/target/release" 
if [ -x "${CARGO_INSTALL_ALL_SCRIPT}" ]; then 
    if [ -d "${SOURCE_DIR}/bin" ]; then
        BUILD_OUTPUT_DIR="${SOURCE_DIR}/bin"
    elif [ ! -d "${SOURCE_DIR}/target/release" ]; then 
        echo -e "${RED}ERROR: Neither ${SOURCE_DIR}/bin nor ${SOURCE_DIR}/target/release found after build!${NC}"
        exit 1
    else 
        echo -e "${YELLOW}Warning: ${SOURCE_DIR}/bin not found, attempting to rsync from ${SOURCE_DIR}/target/release instead.${NC}"
        BUILD_OUTPUT_DIR="${SOURCE_DIR}/target/release"
    fi
fi

if [ ! -d "${BUILD_OUTPUT_DIR}" ]; then
    echo -e "${RED}ERROR: Expected build output directory ${BUILD_OUTPUT_DIR} not found after build!${NC}"
    exit 1
fi
rsync -aHA "${BUILD_OUTPUT_DIR}/" "${COMPILED_VERSION_BIN_DIR}/"

read -p "Build complete. Check artifacts in ${COMPILED_VERSION_BIN_DIR}. Press Enter to update active_release symlink..." key
echo -e "${GREEN}Proceeding with symlink update...${NC}"
sleep 1

if [ -L "${ACTIVE_RELEASE_SYMLINK}" ]; then 
    backup_name="${ACTIVE_RELEASE_SYMLINK}_$(date +%Y%m%d%H%M%S)_before_upgrade"
    echo -e "${YELLOW}Backing up current symlink from $(readlink -f "${ACTIVE_RELEASE_SYMLINK}") to: ${backup_name}${NC}"
    mv "${ACTIVE_RELEASE_SYMLINK}" "${backup_name}"
elif [ -e "${ACTIVE_RELEASE_SYMLINK}" ]; then 
   echo -e "${RED}ERROR: ${ACTIVE_RELEASE_SYMLINK} exists but is not a symlink. Manual intervention required.${NC}"
   exit 1
fi 

echo -e "${CYAN}Removing old symlink (if any remaining after backup attempt): ${ACTIVE_RELEASE_SYMLINK}${NC}"
rm -f "${ACTIVE_RELEASE_SYMLINK}" 

echo -e "${CYAN}Creating new symlink ${ACTIVE_RELEASE_SYMLINK} -> ${COMPILED_VERSION_BIN_DIR}${NC}"
ln -sf "${COMPILED_VERSION_BIN_DIR}" "${ACTIVE_RELEASE_SYMLINK}"

echo -e "${GREEN}\nVerifying new version using binary from symlink (direct path)...${NC}"
VALIDATOR_EXECUTABLE_PATH_UPGRADE="${ACTIVE_RELEASE_SYMLINK}/${VALIDATOR_BINARY_NAME}"
if [ -x "${VALIDATOR_EXECUTABLE_PATH_UPGRADE}" ]; then
    echo -e "${CYAN}Running: ${VALIDATOR_EXECUTABLE_PATH_UPGRADE} -V${NC}"
    "${VALIDATOR_EXECUTABLE_PATH_UPGRADE}" -V
else
    echo -e "${RED}ERROR: ${VALIDATOR_BINARY_NAME} not found or not executable at ${VALIDATOR_EXECUTABLE_PATH_UPGRADE}${NC}"
fi
echo -e "${MAGENTA}\nRef used for this upgrade = ${target_ref} (compiled into directory: ${sanitized_ref_name})${NC}"

echo -e "${GREEN}\nPerforming secondary verification (from home directory using system PATH)...${NC}"
( 
  current_dir_before_cd_test=$(pwd)
  cd ~ 
  echo -e "${CYAN}Temporarily changed to directory: $(pwd)${NC}"
  echo -e "${CYAN}Attempting to run: ${VALIDATOR_BINARY_NAME} -V (using existing system PATH)${NC}"
  if command -v "${VALIDATOR_BINARY_NAME}" &> /dev/null; then
      "${VALIDATOR_BINARY_NAME}" -V
      echo -e "${GREEN}Secondary verification successful: '${VALIDATOR_BINARY_NAME}' found in system PATH.${NC}"
  else
      local detected_shell_type
      detected_shell_type=$(detect_user_shell)
      local detected_rc_file
      detected_rc_file=$(get_rc_file_for_shell "$detected_shell_type")
      echo -e "${YELLOW}WARNING: Command '${VALIDATOR_BINARY_NAME}' not found in system PATH when run from $(pwd).${NC}"
      echo -e "${YELLOW}Ensure '${ACTIVE_RELEASE_SYMLINK}' is permanently in your system PATH (e.g., via ${detected_rc_file} and a new terminal session).${NC}"
  fi
  cd "${current_dir_before_cd_test}" 
)
echo -e "${GREEN}Secondary verification attempt complete.${NC}"

echo -e "${GREEN}Verification step complete. Pausing before restart prompt...${NC}"
sleep 5

echo -e "${GREEN}\nUpgrade to ${target_ref} is prepared.${NC}"
echo

user_max_delinquent_stake="${DEFAULT_MAX_DELINQUENT_STAKE}" 
user_min_idle_time="${DEFAULT_MIN_IDLE_TIME}"         

read -r -p "Enter max delinquent stake percentage for restart [default: ${DEFAULT_MAX_DELINQUENT_STAKE}]: " input_max_delinquent
if [ -n "${input_max_delinquent}" ]; then user_max_delinquent_stake="${input_max_delinquent}"; fi

read -r -p "Enter min idle time (seconds) for restart [default: ${DEFAULT_MIN_IDLE_TIME}]: " input_min_idle
if [ -n "${input_min_idle}" ]; then user_min_idle_time="${input_min_idle}"; fi


read -r -p "Press 'x' (then Enter) to exit script WITHOUT restarting validator, or just Enter to proceed with restart (using max_delinquent_stake=${user_max_delinquent_stake}, min_idle_time=${user_min_idle_time}): " final_user_input_ug_before_restart
if [[ "${final_user_input_ug_before_restart,,}" == "x" ]]; then
    echo -e "${CYAN}Exiting script now as per user request. Validator restart NOT initiated.${NC}"
    exit 0
fi

echo -e "${GREEN}Proceeding with validator exit command...${NC}"
sleep 1

echo -e "${CYAN}Issuing exit command to validator: ${VALIDATOR_EXECUTABLE_PATH_UPGRADE} --ledger ${LEDGER_DIR} exit --max-delinquent-stake ${user_max_delinquent_stake} --min-idle-time ${user_min_idle_time} --no-wait-for-exit --monitor${NC}"
"${VALIDATOR_EXECUTABLE_PATH_UPGRADE}" --ledger "${LEDGER_DIR}" exit --max-delinquent-stake "${user_max_delinquent_stake}" --min-idle-time "${user_min_idle_time}" --no-wait-for-exit --monitor

echo -e "${GREEN}\nExit command sent. Validator should restart with the new version if managed by a service (e.g., systemd).${NC}"
echo -e "${GREEN}UPGRADE DONE${NC}"

echo
read -r -p "Press 'x' (then Enter) to exit script now, or just Enter to complete and exit: " final_user_input_ug
if [[ "${final_user_input_ug,,}" == "x" ]]; then
    echo -e "${CYAN}Exiting script now as per user request.${NC}"
    exit 0
fi
# Q3VzdG9taXplZCBieSBUNDNoaWUtNDA0
exit 0
