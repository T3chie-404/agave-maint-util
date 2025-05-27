#!/bin/bash
set -euo pipefail # Exit on error, unset variable, or pipe failure

# Script to upgrade, rollback, or clean old versions of the Agave Labs Client.
# Assumes that necessary dependencies (Rust, build tools, git) and system tunings
# (including persistent PATH setup) have already been applied to the system.
#
# For upgrade: provide the git tag of the new version.
# - If tag ends with "-jito", it builds the Jito variant.
# - If tag starts with "x", it prompts to confirm building Xandeum-Agave.
# - Otherwise, it prompts to confirm building a vanilla Agave client.
# - Optionally, specify number of build jobs with "-j <num_jobs>".
# For rollback: use the 'rollback' argument.
# For cleaning: use the 'clean' argument.

# Color Definitions
NC='\033[0m' # No Color
YELLOW='\033[0;33m'
RED='\033[0;31m'
GREEN='\033[1;32m'
MAGENTA='\033[0;35m'
CYAN='\033[1;36m'

# ##############################################################################
# #                                                                            #
# #                  CHECK THESE CONFIGURATION VARIABLES                       #
# #                                                                            #
# ##############################################################################

# --- Configuration Variables ---
# First argument is either a git tag for upgrade or "rollback"
MODE_OR_TAG_ARG="${1:-}" # Default to empty if no arg, checked below

JITO_SOURCE_DIR="$HOME/data/jito-solana" # Path to the Jito variant git repository
JITO_REPO_URL="https://github.com/jito-foundation/jito-solana.git" # Git URL for Jito

VANILLA_SOURCE_DIR="$HOME/data/agave"    # Path to the vanilla Agave git repository
VANILLA_REPO_URL="https://github.com/anza-xyz/agave.git" # Git URL for vanilla Agave

XANDEUM_SOURCE_DIR="$HOME/data/xandeum-agave" # Path to Xandeum-Agave git repository
XANDEUM_REPO_URL="https://github.com/Xandeum/xandeum-agave.git" # Git URL for Xandeum-Agave

# SOURCE_DIR will be set dynamically based on the tag
SOURCE_DIR="" 
REPO_URL_TO_CLONE="" # Will be set dynamically

COMPILED_BASE_DIR="$HOME/data/compiled" # Base directory for compiled versions
ACTIVE_RELEASE_SYMLINK="${COMPILED_BASE_DIR}/active_release" # Symlink to the active version's bin directory
# IMPORTANT: If you change COMPILED_BASE_DIR (and thus ACTIVE_RELEASE_SYMLINK),
#            ensure your systemd service file (e.g., /etc/systemd/system/validator.service)
#            points to the correct path for the agave-validator binary,
#            either directly or by having ACTIVE_RELEASE_SYMLINK in its PATH.
#            Also, ensure your user's ~/.bashrc (configured by the system tuning script)
#            points to this ACTIVE_RELEASE_SYMLINK for interactive use.

LEDGER_DIR="$HOME/ledger" # Path to the ledger
BUILD_JOBS=2 # Default number of parallel jobs for cargo build
VALIDATOR_BINARY_NAME="agave-validator" # Name of the validator binary
# --- End Configuration Variables ---

# ##############################################################################
# #                                                                            #
# ##############################################################################


# --- Helper: Get Active Version Tag ---
get_active_version_tag() {
    local active_tag=""
    if [ -L "${ACTIVE_RELEASE_SYMLINK}" ]; then
        local symlink_target
        symlink_target=$(readlink -f "${ACTIVE_RELEASE_SYMLINK}")
        if [ -n "${symlink_target}" ]; then
            local version_dir
            version_dir=$(dirname "${symlink_target}")
            active_tag=$(basename "${version_dir}")
        fi
    fi
    echo "${active_tag}"
}

# --- Rollback Function ---
perform_rollback() {
    echo -e "${CYAN}--- Initiating Rollback Process ---${NC}"
    local active_version_tag
    active_version_tag=$(get_active_version_tag)

    echo -e "${YELLOW}Available compiled versions (tags) in ${COMPILED_BASE_DIR}:${NC}"
    mapfile -t available_versions < <(find "${COMPILED_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d -not -name "$(basename "${ACTIVE_RELEASE_SYMLINK}")" -not -name "*_before_*" -printf "%f\n" | sort -V)

    if [ ${#available_versions[@]} -eq 0 ]; then
        echo -e "${RED}No compiled versions found in ${COMPILED_BASE_DIR} to roll back to.${NC}"
        exit 1
    fi

    local display_versions=()
    for version in "${available_versions[@]}"; do
        if [[ "${version}" == "${active_version_tag}" ]]; then
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
    VALIDATOR_EXECUTABLE_PATH_ROLLBACK="${ACTIVE_RELEASE_SYMLINK}/${VALIDATOR_BINARY_NAME}"
    if [ -x "${VALIDATOR_EXECUTABLE_PATH_ROLLBACK}" ]; then
        echo -e "${CYAN}Running: ${VALIDATOR_EXECUTABLE_PATH_ROLLBACK} -V${NC}"
        "${VALIDATOR_EXECUTABLE_PATH_ROLLBACK}" -V
    else
        echo -e "${RED}ERROR: ${VALIDATOR_BINARY_NAME} not found or not executable at ${VALIDATOR_EXECUTABLE_PATH_ROLLBACK}${NC}"
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
          echo -e "${YELLOW}WARNING: Command '${VALIDATOR_BINARY_NAME}' not found in system PATH when run from $(pwd).${NC}"
          echo -e "${YELLOW}Ensure '${ACTIVE_RELEASE_SYMLINK}' is permanently in your system PATH (e.g., via ~/.bashrc and a new terminal session).${NC}"
      fi
      cd "${current_dir_before_cd_test}" 
    )
    echo -e "${GREEN}Secondary verification attempt complete.${NC}"

    echo
    read -r -p "Rollback to ${version_to_rollback_to} prepared. Press 'x' (then Enter) to exit script WITHOUT restarting validator, or just Enter to proceed with restart: " final_user_input_rb_before_restart
    if [[ "${final_user_input_rb_before_restart,,}" == "x" ]]; then
        echo -e "${CYAN}Exiting script now as per user request. Validator restart NOT initiated.${NC}"
        exit 0
    fi

    echo -e "${GREEN}Proceeding with validator exit command...${NC}"
    sleep 1
    "${VALIDATOR_EXECUTABLE_PATH_ROLLBACK}" --ledger "${LEDGER_DIR}" exit --max-delinquent-stake 5 --min-idle-time 25 --monitor
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
# --- End Rollback Function ---

# --- Clean Function ---
perform_clean() {
    echo -e "${CYAN}--- Initiating Cleanup Process for Old Compiled Versions ---${NC}"
    local active_version_tag
    active_version_tag=$(get_active_version_tag)

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
        if [[ "${version_name}" == "${active_version_tag}" ]]; then
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
# --- End Clean Function ---

# --- Main Script Logic ---

# Assumes dependencies (git, cargo, rsync, jq, etc.) are pre-installed.

if [ -z "${1:-}" ]; then 
    echo -e "${RED}\n:::ERROR::: ${CYAN}No argument provided.${NC}"
    echo -e "${CYAN}Usage for Upgrade: ${YELLOW}$(basename "$0") <tag_for_upgrade> [-j <num_jobs>]${NC}"
    echo -e "${CYAN}Usage for Rollback: ${YELLOW}$(basename "$0") rollback${NC}"
    echo -e "${CYAN}Usage for Cleanup:  ${YELLOW}$(basename "$0") clean\n${NC}"
    exit 1
fi

MODE_OR_TAG_ARG="$1"

if [ "${MODE_OR_TAG_ARG}" == "rollback" ]; then
    perform_rollback 
elif [ "${MODE_OR_TAG_ARG}" == "clean" ]; then
    perform_clean 
fi

# If not rollback or clean, assume upgrade. Argument parsing for -j needs to happen here.
if [ "$#" -gt 1 ]; then 
    if [ "$2" == "-j" ]; then
        if [ -n "$3" ] && [[ "$3" =~ ^[0-9]+$ ]] && [ "$3" -gt 0 ]; then
            BUILD_JOBS="$3"
            echo -e "${CYAN}Using custom number of build jobs: ${GREEN}${BUILD_JOBS}${NC}"
        else
            echo -e "${RED}\n:::ERROR::: ${CYAN}Invalid value for -j. Please provide a positive integer for number of jobs.${NC}"
            echo -e "${CYAN}Usage for Upgrade: ${YELLOW}$(basename "$0") <tag_for_upgrade> [-j <num_jobs>]\n${NC}"
            exit 1
        fi
        if [ "$#" -gt 3 ]; then
            echo -e "${RED}\n:::ERROR::: ${CYAN}Too many arguments. Unexpected arguments after -j <num_jobs>.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}\n:::ERROR::: ${CYAN}Invalid arguments. Expected '-j <num_jobs>' or no other arguments after tag.${NC}"
        exit 1
    fi
fi

# Proceed with upgrade logic (if MODE_OR_TAG_ARG was not 'rollback' or 'clean')
target_tag="${MODE_OR_TAG_ARG}"
echo -e "${CYAN}\n--- Initiating Upgrade Process ---${NC}"
echo -e "${CYAN}Target version tag for upgrade: ${GREEN}${target_tag}${NC}"

# Determine which source directory to use based on the tag
if [[ "${target_tag}" == *"-jito" ]]; then
    SOURCE_DIR="${JITO_SOURCE_DIR}"
    REPO_URL_TO_CLONE="${JITO_REPO_URL}"
    echo -e "${GREEN}Tag ends with '-jito'. Using Jito source directory: ${SOURCE_DIR}${NC}"
elif [[ "${target_tag}" == x* ]]; then # If tag starts with 'x', it could be Xandeum
    echo -e "${YELLOW}The provided tag '${target_tag}' starts with 'x'.${NC}"
    echo -e "${YELLOW}This might be a Xandeum-Agave client build.${NC}"
    echo -e " - Xandeum-Agave client will be built from: ${XANDEUM_SOURCE_DIR}"
    
    read -r -p "Do you want to proceed with building the Xandeum-Agave client from ${XANDEUM_SOURCE_DIR}? (yes/no): " confirmation
    if [[ "${confirmation,,}" == "yes" || "${confirmation,,}" == "y" ]]; then
        SOURCE_DIR="${XANDEUM_SOURCE_DIR}"
        REPO_URL_TO_CLONE="${XANDEUM_REPO_URL}"
        echo -e "${GREEN}Confirmed. Using Xandeum-Agave source directory: ${SOURCE_DIR}${NC}"
    else
        echo -e "${RED}Build cancelled by user. For Jito, use '-jito' suffix. For vanilla, use a tag not starting with 'x'.${NC}"
        exit 1
    fi
else # Default to vanilla Agave if not ending in -jito and not starting with x
    echo -e "${YELLOW}The provided tag '${target_tag}' does not end with '-jito' and does not start with 'x'.${NC}"
    echo -e "${YELLOW}This suggests you might want to build the vanilla Agave client.${NC}"
    echo -e " - Vanilla Agave client will be built from: ${VANILLA_SOURCE_DIR}"
    
    read -r -p "Do you want to proceed with building the vanilla Agave client from ${VANILLA_SOURCE_DIR}? (yes/no): " confirmation
    if [[ "${confirmation,,}" == "yes" || "${confirmation,,}" == "y" ]]; then
        SOURCE_DIR="${VANILLA_SOURCE_DIR}"
        REPO_URL_TO_CLONE="${VANILLA_REPO_URL}"
        echo -e "${GREEN}Confirmed. Using vanilla Agave source directory: ${SOURCE_DIR}${NC}"
    else
        echo -e "${RED}Build cancelled by user. For Jito, use '-jito' suffix. For Xandeum, use an 'x' prefixed tag.${NC}"
        exit 1
    fi
fi

# --- Upgrade Path (continues if not rollback or clean) ---

export tag="${target_tag}" 
export RUSTFLAGS="-O -C target-cpu=native"

# Handle SOURCE_DIR creation and cloning
if [ ! -d "${SOURCE_DIR}" ]; then
    echo -e "${YELLOW}Source directory ${SOURCE_DIR} does not exist.${NC}"
    # PARENT_OF_SOURCE_DIR=$(dirname "${SOURCE_DIR}") # Not strictly needed if mkdir -p is used carefully

    echo -e "${CYAN}Attempting to create ${SOURCE_DIR} with sudo and set ownership to $(whoami)...${NC}"
    # Create the target directory itself, mkdir -p will create parents if they don't exist.
    # If parent creation fails due to permissions (e.g. /mnt is not writable by root), mkdir will fail.
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
        echo -e "${YELLOW}Please check permissions for parent directories and sudo capabilities.${NC}"
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
git fetch origin --prune

echo -e "${GREEN}\nStarting upgrade process for tag: ${CYAN}${target_tag}${NC}"
sleep 2

echo -e "${CYAN}Attempting to checkout tag: ${target_tag}${NC}"
echo -e "${YELLOW}Note: Forcing checkout. Any uncommitted local changes in the source directory may be overwritten.${NC}"
git checkout -f "${target_tag}" 
if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to checkout tag ${target_tag}${NC}"
    exit 1
fi
echo -e "${GREEN}Successfully checked out tag: ${target_tag}${NC}"

echo -e "${CYAN}Updating submodules...${NC}"
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR" git submodule update --init --recursive
if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to update submodules for tag ${target_tag}${NC}"
    exit 1
fi

echo -e "${GREEN}Ready to build...${NC}"
sleep 5

echo -e "${GREEN}Building tag ${target_tag} (CARGO_BUILD_JOBS=${BUILD_JOBS})...${NC}"
export CI_COMMIT
CI_COMMIT=$(git rev-parse HEAD)
echo -e "${CYAN}Using CI_COMMIT=${CI_COMMIT} for the build.${NC}"
export CARGO_BUILD_JOBS="${BUILD_JOBS}"

CARGO_INSTALL_ALL_SCRIPT="./scripts/cargo-install-all.sh"
if [ -x "${CARGO_INSTALL_ALL_SCRIPT}" ]; then
    echo -e "${GREEN}Using ${CARGO_INSTALL_ALL_SCRIPT} for build...${NC}"
    if ! "${CARGO_INSTALL_ALL_SCRIPT}" .; then # Pass '.' as the install directory argument
        echo -e "${RED}ERROR: Build failed using ${CARGO_INSTALL_ALL_SCRIPT} for tag ${target_tag}${NC}"
        exit 1
    fi
else
    echo -e "${RED}ERROR: Build script ${CARGO_INSTALL_ALL_SCRIPT} not found or not executable in ${SOURCE_DIR}/scripts/.${NC}"
    echo -e "${RED}This script is required for building with correct version information.${NC}"
    echo -e "${YELLOW}Attempting fallback to 'cargo build --release'. Source hash may not be embedded correctly.${NC}"
    read -r -p "Proceed with fallback build method? (yes/NO): " fallback_confirmation
    if [[ "${fallback_confirmation,,}" != "yes" && "${fallback_confirmation,,}" != "y" ]]; then
        echo -e "${RED}Build cancelled by user due to missing ${CARGO_INSTALL_ALL_SCRIPT}.${NC}"
        exit 1
    fi
    
    if [ -x "./cargo" ]; then
        CARGO_CMD="./cargo"
    else
        CARGO_CMD="cargo"
    fi
    if ! ${CARGO_CMD} b --release -j "${BUILD_JOBS}"; then # CI_COMMIT will likely not be used here
        echo -e "${RED}ERROR: Standard cargo build failed for tag ${target_tag}${NC}"
        exit 1
    fi
fi
unset CARGO_BUILD_JOBS # Clean up environment variable
echo -e "${GREEN}Build successful for ${target_tag}.${NC}"

COMPILED_VERSION_BIN_DIR="${COMPILED_BASE_DIR}/${target_tag}/bin"
echo -e "${CYAN}Creating directory for compiled version: ${COMPILED_VERSION_BIN_DIR}${NC}"
mkdir -p "${COMPILED_VERSION_BIN_DIR}"

echo -e "${CYAN}Syncing compiled binaries...${NC}"
# If cargo-install-all.sh was used, binaries are in $SOURCE_DIR/bin/
# If fallback cargo build was used, binaries are in $SOURCE_DIR/target/release/
BUILD_OUTPUT_DIR="${SOURCE_DIR}/target/release" # Default for fallback
if [ -x "${CARGO_INSTALL_ALL_SCRIPT}" ]; then # Check if cargo-install-all.sh was intended to be used
    # If cargo-install-all.sh exists, assume it places binaries in $SOURCE_DIR/bin
    if [ -d "${SOURCE_DIR}/bin" ]; then
        BUILD_OUTPUT_DIR="${SOURCE_DIR}/bin"
    elif [ ! -d "${SOURCE_DIR}/target/release" ]; then # If $SOURCE_DIR/bin doesn't exist, but target/release also doesn't
        echo -e "${RED}ERROR: Neither ${SOURCE_DIR}/bin nor ${SOURCE_DIR}/target/release found after build!${NC}"
        exit 1
    else # Fallback to target/release if $SOURCE_DIR/bin doesn't exist but target/release does
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
echo -e "${MAGENTA}\nTag used for this upgrade = ${target_tag}${NC}"

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
      echo -e "${YELLOW}WARNING: Command '${VALIDATOR_BINARY_NAME}' not found in system PATH when run from $(pwd).${NC}"
      echo -e "${YELLOW}Ensure '${ACTIVE_RELEASE_SYMLINK}' is permanently in your system PATH (e.g., via ~/.bashrc and a new terminal session).${NC}"
  fi
  cd "${current_dir_before_cd_test}" 
)
echo -e "${GREEN}Secondary verification attempt complete.${NC}"

echo -e "${GREEN}Verification step complete. Pausing before restart prompt...${NC}"
sleep 5

echo -e "${GREEN}\nUpgrade to ${target_tag} is prepared.${NC}"
echo
read -r -p "Press 'x' (then Enter) to exit script WITHOUT restarting validator, or just Enter to proceed with restart: " final_user_input_ug_before_restart
if [[ "${final_user_input_ug_before_restart,,}" == "x" ]]; then
    echo -e "${CYAN}Exiting script now as per user request. Validator restart NOT initiated.${NC}"
    exit 0
fi

echo -e "${GREEN}Proceeding with validator exit command...${NC}"
sleep 1

echo -e "${CYAN}Issuing exit command to validator: ${VALIDATOR_EXECUTABLE_PATH_UPGRADE} --ledger ${LEDGER_DIR} exit ...${NC}"
"${VALIDATOR_EXECUTABLE_PATH_UPGRADE}" --ledger "${LEDGER_DIR}" exit --max-delinquent-stake 5 --min-idle-time 25 --monitor

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
