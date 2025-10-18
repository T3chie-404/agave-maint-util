#!/bin/bash
set -euo pipefail # Exit on error, unset variable, or pipe failure

# Script for initial system tuning and dependency installation for a Solana validator.
# This script should typically be run once on a new server setup.
# It will configure persistent PATH settings in ~/.bashrc but not alter the
# PATH for its own immediate execution regarding the active_release path.

# Color Definitions
NC='\033[0m' # No Color
YELLOW='\033[0;33m'
YELLOW_BOLD='\033[1;33m' 
RED='\033[0;31m'
GREEN='\033[1;32m' 
CYAN_BOLD='\033[1;36m' 

# ##############################################################################
# #                                                                            #
# #                  CHECK THESE CONFIGURATION VARIABLES                       #
# #                                                                            #
# ##############################################################################

# --- Configuration Variables (User can modify these defaults) ---
# Path for the symlink pointing to the active validator binaries (used for user's PATH)
# Defaulting to a path within the user's home directory.
# If using a shared /mnt/data, change this to, e.g., "/mnt/data/compiled/active_release"
CONFIGURABLE_ACTIVE_RELEASE_PATH="$HOME/data/compiled/active_release"

# Path for the validator's main log file (for logrotate setup)
# Defaulting to a path within the user's home directory.
# If using a shared /mnt/data, change this to, e.g., "/mnt/data/logs/solana-validator.log"
CONFIGURABLE_VALIDATOR_LOG_FILE_PATH="$HOME/data/logs/solana-validator.log"

# User that should own the validator log directory (for logrotate setup)
# This should typically be the user the validator service runs as.
CONFIGURABLE_VALIDATOR_LOG_DIR_USER="sol" # Change if your validator runs as a different user

# Name of the systemd service for the validator (for logrotate postrotate action)
CONFIGURABLE_VALIDATOR_SERVICE_NAME="validator.service"

# Name of the main validator binary
CONFIGURABLE_VALIDATOR_BINARY_NAME="agave-validator"

# Specific old path segment to look for and replace in the validator service's PATH environment
OLD_SERVICE_PATH_SEGMENT_TO_REPLACE="/home/sol/.local/share/xandeum/install/releases/active_release"

# Path to the validator start script (e.g., a .sh file that execs the validator)
CONFIGURABLE_VALIDATOR_START_SCRIPT_PATH="$HOME/validator-start.sh"
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

# --- Utility Functions ---

log_msg() {
    echo -e "${CYAN_BOLD}$(date +'%a %b %d %H:%M:%S %Z %Y') - $1${NC}" # Using CYAN_BOLD
}

confirm_action() {
    local prompt_message="$1"
    local full_prompt_string
    
    printf -v full_prompt_string "%b%s (yes/no): %b" "${YELLOW_BOLD}" "${prompt_message}" "${NC}"
    echo -n -e "${full_prompt_string}"
    
    local confirmation_input
    read -r confirmation_input

    if [[ "${confirmation_input,,}" != "yes" && "${confirmation_input,,}" != "y" ]]; then
        echo -e "\n${RED}Action cancelled by user.${NC}"
        return 1 # False
    fi
    echo # Add a newline for clarity after "yes"
    return 0 # True
}

configure_active_release_path() {
    log_msg "Configuring persistent PATH for active_release symlink..."
    
    # Detect user's shell
    local user_shell_type
    user_shell_type=$(detect_user_shell)
    local shell_display_name
    shell_display_name=$(get_shell_display_name "$user_shell_type")
    local rc_file
    rc_file=$(get_rc_file_for_shell "$user_shell_type")
    
    log_msg "Detected shell: ${GREEN}${shell_display_name}${NC} (will configure ${rc_file})"
    
    local active_release_path_to_add="${CONFIGURABLE_ACTIVE_RELEASE_PATH}" 
    
    # Expand $HOME in the path to add for accurate comparison and writing
    local expanded_active_release_path_to_add
    expanded_active_release_path_to_add=$(eval echo "${active_release_path_to_add}")
    local new_path_line_literal="export PATH=\"${expanded_active_release_path_to_add}:\$PATH\""

    # Create RC file if it doesn't exist
    if [ ! -f "${rc_file}" ]; then
        log_msg "${YELLOW}${rc_file} not found for user $(whoami). Creating it...${NC}"
        touch "${rc_file}"
        if [ $? -ne 0 ]; then
            log_msg "${RED}ERROR: Failed to create ${rc_file}. Cannot make PATH modification persistent.${NC}"
            return 1
        fi
        log_msg "${GREEN}Created ${rc_file}${NC}"
    fi

    # Check if the exact new path line already exists and is NOT commented out
    if grep -qFx -- "${new_path_line_literal}" "${rc_file}" && \
       grep -Fx -- "${new_path_line_literal}" "${rc_file}" | grep -qvE -- "^[[:space:]]*#"; then
        log_msg "${GREEN}'${expanded_active_release_path_to_add}' (exact match) already actively configured in PATH in ${rc_file}.${NC}"
    else
        local generic_active_release_pattern="export PATH=\"[^\"]*/active_release:\$PATH\""
        
        # Use array building method compatible with both bash and zsh
        local existing_active_lines=()
        while IFS= read -r line; do
            existing_active_lines+=("$line")
        done < <(grep -E -- "${generic_active_release_pattern}" "${rc_file}" | grep -vE -- "^[[:space:]]*#" | grep -vF -- "${new_path_line_literal}")

        if [ ${#existing_active_lines[@]} -gt 0 ]; then
            log_msg "${YELLOW_BOLD}WARNING: Found OTHER existing ACTIVE line(s) in ${rc_file} that appear to set an 'active_release' PATH (different from the one being configured):${NC}"
            for found_line in "${existing_active_lines[@]}"; do
                local line_num
                line_num=$(grep -nF -- "${found_line}" "${rc_file}" | head -n1 | cut -d: -f1)
                log_msg "${YELLOW}  L${line_num}: ${found_line}${NC}"
            done
            log_msg "${YELLOW}It is highly recommended to manually review ${rc_file} and remove old/conflicting 'active_release' PATH entries to avoid unexpected behavior.${NC}" 
        fi
        
        if ! grep -qFx -- "${new_path_line_literal}" "${rc_file}"; then
             log_msg "Adding new PATH line for '${expanded_active_release_path_to_add}' to ${rc_file}..."
             echo '' >> "${rc_file}" 
             echo "# Add Solana active_release to PATH (managed by system_tuning_setup.sh on $(date))" >> "${rc_file}"
             echo "${new_path_line_literal}" >> "${rc_file}"
             log_msg "${GREEN}Added '${expanded_active_release_path_to_add}' to PATH in ${rc_file}.${NC}"
        elif grep -qFx -- "#${new_path_line_literal}" "${rc_file}"; then
             log_msg "Found a commented-out version of the target PATH line. Will add a new active one."
             echo '' >> "${rc_file}" 
             echo "# Add Solana active_release to PATH (managed by system_tuning_setup.sh on $(date))" >> "${rc_file}"
             echo "${new_path_line_literal}" >> "${rc_file}"
             log_msg "${GREEN}Added '${expanded_active_release_path_to_add}' to PATH in ${rc_file}.${NC}"
        fi
        
        # Provide shell-specific instructions
        local rc_file_basename
        rc_file_basename=$(basename "${rc_file}")
        echo -e "${YELLOW}Please run 'source ~/${rc_file_basename}' or open a new terminal for this PATH change to take full effect in your interactive session.${NC}"
    fi
}

install_rust_and_components() {
    log_msg "Checking for Rust installation for user $(whoami)..."
    
    # Detect user's shell for proper RC file configuration
    local user_shell_type
    user_shell_type=$(detect_user_shell)
    local shell_display_name
    shell_display_name=$(get_shell_display_name "$user_shell_type")
    local rc_file
    rc_file=$(get_rc_file_for_shell "$user_shell_type")
    
    if ! command -v cargo &> /dev/null && [ -f "$HOME/.cargo/env" ]; then
        log_msg "Cargo not in PATH, attempting to source $HOME/.cargo/env for this session..."
        source "$HOME/.cargo/env"
    fi

    if ! command -v cargo &> /dev/null || ! command -v rustup &> /dev/null; then
        log_msg "${YELLOW}Rust (cargo/rustup) not found or not in PATH for user $(whoami).${NC}" 
        if confirm_action "Install Rust for user $(whoami) using 'curl https://sh.rustup.rs -sSf | sh'?"; then
            log_msg "Installing Rust for user $(whoami)..."
            curl https://sh.rustup.rs -sSf | sh -s -- -y --no-modify-path
            if [ -f "$HOME/.cargo/env" ]; then
                source "$HOME/.cargo/env" 
                log_msg "${GREEN}Rust installed for $(whoami). Sourced $HOME/.cargo/env for current script session.${NC}"
                
                # Create RC file if it doesn't exist
                if [ ! -f "${rc_file}" ]; then
                    log_msg "${YELLOW}${rc_file} not found. Creating it...${NC}"
                    touch "${rc_file}"
                fi
                
                log_msg "Adding 'source \"\$HOME/.cargo/env\"' to ${rc_file} for persistence..."
                if ! grep -qF 'source "$HOME/.cargo/env"' "${rc_file}"; then 
                    echo '' >> "${rc_file}" 
                    echo "# Rust/Cargo PATH setup (managed by system_tuning_setup.sh for ${shell_display_name})" >> "${rc_file}"
                    echo 'source "$HOME/.cargo/env"' >> "${rc_file}"
                    log_msg "Added Rust source line to ${rc_file}."
                else
                    log_msg "Rust source line already exists in ${rc_file}."
                fi
                
                log_msg "${GREEN}Rust PATH configured in ${rc_file} for future ${shell_display_name} sessions.${NC}"
            else
                log_msg "${RED}ERROR: Rust installation completed, but $HOME/.cargo/env not found. Manual PATH setup might be needed for user $(whoami).${NC}"
                exit 1
            fi
        else
            log_msg "${RED}Rust installation skipped by user. Some operations might fail.${NC}"
            return 1 
        fi
    else
        log_msg "${GREEN}Rust (cargo and rustup) already found for user $(whoami).${NC}"
    fi

    if command -v rustup &> /dev/null; then
        log_msg "Ensuring 'rustfmt' component is installed and Rust is updated for user $(whoami)..."
        rustup component add rustfmt
        rustup update
        log_msg "${GREEN}'rustfmt' component checked/added and 'rustup update' executed for user $(whoami).${NC}"
    else
        log_msg "${RED}ERROR: rustup command not found for user $(whoami). Cannot manage Rust components or update.${NC}"
        return 1
    fi
    return 0
}

install_apt_dependencies() {
    log_msg "Checking and installing required APT packages..."
    REQUIRED_APT_PACKAGES=(
        "libssl-dev" "libudev-dev" "pkg-config" "zlib1g-dev" 
        "llvm" "clang" "cmake" "make" 
        "libprotobuf-dev" "protobuf-compiler" "libclang-dev"
        "git" "curl" "bc" "jq" "sed" "gawk" 
    )
    local packages_to_install=()
    for pkg in "${REQUIRED_APT_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            packages_to_install+=("$pkg")
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        log_msg "${YELLOW}The following APT packages are required: ${packages_to_install[*]}${NC}"
        if confirm_action "Install these APT packages now (requires sudo)?"; then
            log_msg "Updating APT package list..."
            sudo apt-get update -y
            log_msg "Installing missing APT packages: ${packages_to_install[*]}..."
            sudo apt-get install -y "${packages_to_install[@]}"
            log_msg "${GREEN}Required APT packages installed.${NC}"
        else
            log_msg "${RED}APT package installation skipped. Some operations might fail.${NC}"
            return 1 
        fi
    else
        log_msg "${GREEN}All required APT packages are already installed.${NC}"
    fi
    return 0
}

configure_sysctl() {
    log_msg "Applying sysctl configurations for Agave validator..."
    SYSCTL_CONF_FILE="/etc/sysctl.d/21-agave-validator.conf" 
    
    cat > /tmp/21-agave-validator.conf <<EOF
# Increase max UDP buffer sizes
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

# Increase memory mapped files limit
vm.max_map_count = 2000000

# Increase number of allowed open file descriptors
fs.nr_open = 2000000
EOF

    log_msg "Moving temporary sysctl config to ${SYSCTL_CONF_FILE}..."
    sudo mv /tmp/21-agave-validator.conf "${SYSCTL_CONF_FILE}"
    sudo chown root:root "${SYSCTL_CONF_FILE}"
    sudo chmod 0644 "${SYSCTL_CONF_FILE}"

    log_msg "Applying new sysctl settings..."
    sudo sysctl -p "${SYSCTL_CONF_FILE}"
    log_msg "${GREEN}Sysctl settings applied.${NC}"
}

configure_systemd_limits() {
    log_msg "Checking and configuring systemd DefaultLimitNOFILE..."
    SYSTEMD_CONF_FILE="/etc/systemd/system.conf"
    LIMIT_SETTING="DefaultLimitNOFILE=2000000" 

    if grep -q "^${LIMIT_SETTING}" "${SYSTEMD_CONF_FILE}"; then
        log_msg "${GREEN}Systemd ${LIMIT_SETTING} already set in ${SYSTEMD_CONF_FILE}.${NC}"
    else
        log_msg "${YELLOW}Systemd ${LIMIT_SETTING} not found. Adding it to ${SYSTEMD_CONF_FILE}.${NC}"
        sudo cp "${SYSTEMD_CONF_FILE}" "${SYSTEMD_CONF_FILE}.bak_$(date +%Y%m%d%H%M%S)"
        log_msg "Backed up ${SYSTEMD_CONF_FILE} to ${SYSTEMD_CONF_FILE}.bak_..."
        
        sudo sed -i '/^DefaultLimitNOFILE=/d' "${SYSTEMD_CONF_FILE}"
        
        echo "${LIMIT_SETTING}" | sudo tee -a "${SYSTEMD_CONF_FILE}" > /dev/null
        log_msg "${GREEN}Added ${LIMIT_SETTING} to ${SYSTEMD_CONF_FILE}.${NC}"
        
        log_msg "Reloading systemd configuration..."
        sudo systemctl daemon-reload
        log_msg "${GREEN}Systemd configuration reloaded.${NC}"
        echo -e "${YELLOW}A reboot might be required for all systemd limit changes to fully apply to all services.${NC}"
    fi
}

configure_security_limits() {
    log_msg "Configuring security limits for open files..."
    SECURITY_LIMITS_FILE="/etc/security/limits.d/90-solana-nofiles.conf" 
    NOFILE_LIMIT="2000000" 
    
    cat > /tmp/90-solana-nofiles.conf <<EOF
# Increase process file descriptor count limit for Solana validator
* - nofile ${NOFILE_LIMIT}
EOF
    log_msg "Moving temporary security limits config to ${SECURITY_LIMITS_FILE}..."
    sudo mv /tmp/90-solana-nofiles.conf "${SECURITY_LIMITS_FILE}"
    sudo chown root:root "${SECURITY_LIMITS_FILE}"
    sudo chmod 0644 "${SECURITY_LIMITS_FILE}"
    log_msg "${GREEN}Security limits for open files configured in ${SECURITY_LIMITS_FILE}.${NC}"
    echo -e "${YELLOW}These limits typically apply upon new login sessions.${NC}"
}

setup_logrotate() {
    log_msg "Setting up logrotate for validator log..."
    LOGROTATE_CONF_FILE="/etc/logrotate.d/solana-validator-script-setup" 
    LOG_FILE_PATH="${CONFIGURABLE_VALIDATOR_LOG_FILE_PATH}" 
    VALIDATOR_SERVICE_NAME="${CONFIGURABLE_VALIDATOR_SERVICE_NAME}"
    LOG_DIR_USER="${CONFIGURABLE_VALIDATOR_LOG_DIR_USER}"

    LOG_DIR=$(dirname "${LOG_FILE_PATH}")
    if [ ! -d "${LOG_DIR}" ]; then
        log_msg "Log directory ${LOG_DIR} does not exist. Creating it..."
        sudo mkdir -p "${LOG_DIR}"
        log_msg "Attempting to set ownership of ${LOG_DIR} to ${LOG_DIR_USER}:${LOG_DIR_USER}..."
        if sudo chown "${LOG_DIR_USER}":"${LOG_DIR_USER}" "${LOG_DIR}"; then 
            log_msg "${GREEN}Log directory ${LOG_DIR} created and ownership set to ${LOG_DIR_USER}.${NC}"
        else
            log_msg "${RED}WARNING: Failed to set ownership of ${LOG_DIR} to ${LOG_DIR_USER}. Log rotation might have permission issues.${NC}"
        fi
    fi

    cat > /tmp/logrotate.sol.tmp <<EOF
${LOG_FILE_PATH} {
  rotate 7
  daily
  missingok
  notifempty
  compress
  delaycompress
  postrotate
    systemctl kill -s USR1 ${VALIDATOR_SERVICE_NAME} > /dev/null 2>&1 || true
  endscript
}
EOF
    log_msg "Moving temporary logrotate config to ${LOGROTATE_CONF_FILE}..."
    sudo mv /tmp/logrotate.sol.tmp "${LOGROTATE_CONF_FILE}"
    sudo chown root:root "${LOGROTATE_CONF_FILE}"
    sudo chmod 0644 "${LOGROTATE_CONF_FILE}"
    
    log_msg "${GREEN}Logrotate configuration created at ${LOGROTATE_CONF_FILE}.${NC}"
    echo -e "${YELLOW}Logrotate will run based on its cron schedule (typically daily).${NC}"
    echo -e "${YELLOW}To test: sudo logrotate -df ${LOGROTATE_CONF_FILE}${NC}"
    echo -e "${YELLOW}Note: Using 'postrotate' with USR1 signal. If ${VALIDATOR_SERVICE_NAME} does not support this, use 'copytruncate' instead and comment out the 'postrotate' block.${NC}"
}

update_validator_service_environment_path() {
    log_msg "Checking validator systemd service for old PATH environment..."
    local service_name="${CONFIGURABLE_VALIDATOR_SERVICE_NAME}"
    local service_file_path="/etc/systemd/system/${service_name}"
    local old_path_segment_to_replace="${OLD_SERVICE_PATH_SEGMENT_TO_REPLACE}"
    local new_path_segment_configurable="${CONFIGURABLE_ACTIVE_RELEASE_PATH}"
    local new_path_segment_expanded
    new_path_segment_expanded=$(eval echo "${new_path_segment_configurable}") # Expand $HOME if present

    if [ ! -f "${service_file_path}" ]; then
        log_msg "${YELLOW}Validator service file ${service_file_path} not found. Skipping PATH update for service.${NC}"
        log_msg "${YELLOW}If you have a service file at a different location, please update it manually if needed.${NC}"
        return
    fi

    log_msg "Found service file: ${service_file_path}"
    local current_env_path_line
    current_env_path_line=$(grep -E '^\s*Environment="PATH=' "${service_file_path}" || true)

    if [ -z "${current_env_path_line}" ]; then
        log_msg "${YELLOW}No 'Environment=\"PATH=...\"' line found in ${service_file_path}. Skipping PATH update for service.${NC}"
        return
    fi

    log_msg "Current Environment PATH line: ${current_env_path_line}"
    
    local current_path_value
    current_path_value=$(echo "${current_env_path_line}" | sed -E 's/^\s*Environment="PATH=([^"]+)".*/\1/')
    
    if [[ "${current_path_value}" == *"${old_path_segment_to_replace}"* ]]; then
        log_msg "${YELLOW}Old path segment '${old_path_segment_to_replace}' found in service PATH.${NC}"
        
        local new_path_value
        new_path_value="${current_path_value//${old_path_segment_to_replace}/${new_path_segment_expanded}}"
        
        local new_env_path_line
        new_env_path_line="Environment=\"PATH=${new_path_value}\"" 

        log_msg "Proposed new Environment PATH line: ${new_env_path_line}"
        if confirm_action "Update the Environment PATH in ${service_file_path}?"; then
            sudo cp "${service_file_path}" "${service_file_path}.bak_$(date +%Y%m%d%H%M%S)"
            log_msg "Backed up ${service_file_path} to ${service_file_path}.bak_..."
            
            local escaped_current_env_path_line
            escaped_current_env_path_line=$(echo "${current_env_path_line}" | sed 's/[&/\]/\\&/g') 
            local escaped_new_env_path_line
            escaped_new_env_path_line=$(echo "${new_env_path_line}" | sed 's/[&/\]/\\&/g')

            if sudo sed -i "s|^${escaped_current_env_path_line}$|${escaped_new_env_path_line}|" "${service_file_path}"; then
                log_msg "${GREEN}Successfully updated Environment PATH in ${service_file_path}.${NC}"
                log_msg "Reloading systemd daemon..."
                sudo systemctl daemon-reload
                log_msg "${GREEN}Systemd daemon reloaded.${NC}"
            else
                log_msg "${RED}ERROR: Failed to update ${service_file_path} with sed.${NC}"
            fi
        else
            log_msg "Skipped updating Environment PATH in ${service_file_path}."
        fi
    else
        log_msg "${GREEN}Old path segment '${old_path_segment_to_replace}' not found in service PATH. No update needed for this specific old path.${NC}"
    fi
}

update_validator_start_script_log_path() {
    log_msg "Checking validator start script for --log path..."
    local start_script_path_configurable="${CONFIGURABLE_VALIDATOR_START_SCRIPT_PATH}"
    local start_script_path
    start_script_path=$(eval echo "${start_script_path_configurable}") 

    local desired_log_path_configurable="${CONFIGURABLE_VALIDATOR_LOG_FILE_PATH}"
    local desired_log_path
    desired_log_path=$(eval echo "${desired_log_path_configurable}") 


    if [ ! -f "${start_script_path}" ]; then
        log_msg "${YELLOW}Validator start script ${start_script_path} not found. Skipping --log path update.${NC}"
        return
    fi

    log_msg "Found validator start script: ${start_script_path}"
    
    local current_log_line=""
    local line_number_of_log_arg=0
    local temp_line_number=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        temp_line_number=$((temp_line_number + 1))
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        if [[ "$line" =~ --log[[:space:]]+([^[:space:]]+) ]]; then
            current_log_line="$line" 
            line_number_of_log_arg="$temp_line_number"
        fi
    done < "${start_script_path}"


    if [ -z "${current_log_line}" ]; then
        log_msg "${YELLOW}No active '--log <path>' argument found in ${start_script_path}. No update needed or manual check required.${NC}"
        return
    fi

    log_msg "Last active --log line found (L${line_number_of_log_arg}): ${current_log_line}"
    local current_log_path
    current_log_path=$(echo "${current_log_line}" | sed -E 's/.*--log[[:space:]]+([^[:space:]]+).*/\1/')
    current_log_path_expanded=$(eval echo "${current_log_path}") 


    log_msg "Current log path in script: '${current_log_path_expanded}'"
    log_msg "Desired log path (from logrotate setup): '${desired_log_path}'"

    if [ "${current_log_path_expanded}" == "${desired_log_path}" ]; then
        log_msg "${GREEN}--log path in ${start_script_path} already matches logrotate configuration.${NC}"
    else
        log_msg "${YELLOW}The --log path in ${start_script_path} ('${current_log_path_expanded}') is DIFFERENT from the logrotate path ('${desired_log_path}').${NC}"
        
        local display_current_log_line="${current_log_line}"
        # Remove trailing backslash and any space before it for display
        if [[ "${display_current_log_line}" == *" \\" ]]; then
            display_current_log_line="${display_current_log_line% \\}"
        fi
        
        local proposed_new_line_display
        # Construct the proposed new line for display by replacing the path part
        # This sed command is tricky because current_log_path might contain special characters.
        # We need to be careful with how we substitute.
        # A safer way to show the proposed line is to reconstruct it.
        # Find the part before --log, the --log itself, and the part after the path.
        local prefix_part=$(echo "${current_log_line}" | sed -E "s|(.*--log[[:space:]]+)${current_log_path}(.*)|\1|")
        local suffix_part=$(echo "${current_log_line}" | sed -E "s|(.*--log[[:space:]]+)${current_log_path}(.*)|\2|")
        proposed_new_line_display="${prefix_part}${desired_log_path}${suffix_part}"

        if [[ "${proposed_new_line_display}" == *" \\" ]]; then
            proposed_new_line_display="${proposed_new_line_display% \\}"
        fi

        echo -e "${YELLOW_BOLD}Proposed change in ${start_script_path} (on line ${line_number_of_log_arg}):${NC}"
        echo -e "${RED}- ${display_current_log_line}${NC}"
        echo -e "${GREEN}+ ${proposed_new_line_display}${NC}"


        if confirm_action "Update the --log path in ${start_script_path} to '${desired_log_path}'?"; then
            sudo cp "${start_script_path}" "${start_script_path}.bak_$(date +%Y%m%d%H%M%S)"
            log_msg "Backed up ${start_script_path} to ${start_script_path}.bak_..."
            
            # Escape paths for sed
            local escaped_current_log_path_for_sed
            escaped_current_log_path_for_sed=$(printf '%s\n' "${current_log_path}" | sed 's:[][\\/.^$*]:\\&:g')
            local escaped_desired_log_path_for_sed
            escaped_desired_log_path_for_sed=$(printf '%s\n' "${desired_log_path}" | sed 's:[][\\/.^$*]:\\&:g')

            if [ -n "$line_number_of_log_arg" ] && [ "$line_number_of_log_arg" -gt 0 ]; then
                # Use | as sed delimiter
                if sudo sed -i "${line_number_of_log_arg}s|--log[[:space:]]\+${escaped_current_log_path_for_sed}|--log ${escaped_desired_log_path_for_sed}|" "${start_script_path}"; then
                     log_msg "${GREEN}Successfully updated --log path in ${start_script_path} on line ${line_number_of_log_arg}.${NC}"
                else
                     log_msg "${RED}ERROR: Failed to update --log path in ${start_script_path} using sed.${NC}"
                fi
            else
                log_msg "${RED}ERROR: Could not determine the line number of the --log argument. Manual update might be needed.${NC}"
            fi
        else
            log_msg "Skipped updating --log path in ${start_script_path}. Please update manually if needed."
        fi
    fi
}


# --- Main Execution ---
log_msg "Starting System Tuning and Initial Setup Script..."
log_msg "Current PATH for script: $PATH" 

# Detect and display user's shell
DETECTED_SHELL_TYPE=$(detect_user_shell)
DETECTED_SHELL_DISPLAY=$(get_shell_display_name "$DETECTED_SHELL_TYPE")
DETECTED_RC_FILE=$(get_rc_file_for_shell "$DETECTED_SHELL_TYPE")

echo -e "\n${CYAN_BOLD}--- Shell Detection ---${NC}"
log_msg "Detected default shell: ${GREEN}${DETECTED_SHELL_DISPLAY}${NC}"
log_msg "Configuration file: ${GREEN}${DETECTED_RC_FILE}${NC}"
echo ""

# Prompt for user-configurable paths if they want to change defaults
echo -e "${CYAN_BOLD}--- Path Configurations ---${NC}"
echo -e "${YELLOW_BOLD}IMPORTANT: Before configuring the 'active_release' PATH, please manually check your ${DETECTED_RC_FILE}${NC}"
echo -e "${YELLOW_BOLD}If you have any old 'export PATH=.../active_release:\$PATH' lines, consider removing it to avoid conflicts.${NC}"
echo -e "${YELLOW_BOLD}This script will add a new entry for the path you specify below if it doesn't already exist in the exact form.${NC}"
read -r -p "Enter path for 'active_release' symlink [default: ${CONFIGURABLE_ACTIVE_RELEASE_PATH}]: " user_active_release_path
if [ -n "${user_active_release_path}" ]; then CONFIGURABLE_ACTIVE_RELEASE_PATH="${user_active_release_path}"; fi
log_msg "Using active_release path: ${CONFIGURABLE_ACTIVE_RELEASE_PATH}"

read -r -p "Enter path for validator log file [default: ${CONFIGURABLE_VALIDATOR_LOG_FILE_PATH}]: " user_validator_log_path
if [ -n "${user_validator_log_path}" ]; then CONFIGURABLE_VALIDATOR_LOG_FILE_PATH="${user_validator_log_path}"; fi
log_msg "Using validator log file path: ${CONFIGURABLE_VALIDATOR_LOG_FILE_PATH}"

read -r -p "Enter user to own validator log directory [default: ${CONFIGURABLE_VALIDATOR_LOG_DIR_USER}]: " user_log_dir_owner
if [ -n "${user_log_dir_owner}" ]; then CONFIGURABLE_VALIDATOR_LOG_DIR_USER="${user_log_dir_owner}"; fi
log_msg "Validator log directory will be owned by: ${CONFIGURABLE_VALIDATOR_LOG_DIR_USER}"

read -r -p "Enter validator systemd service name [default: ${CONFIGURABLE_VALIDATOR_SERVICE_NAME}]: " user_service_name
if [ -n "${user_service_name}" ]; then CONFIGURABLE_VALIDATOR_SERVICE_NAME="${user_service_name}"; fi
log_msg "Using validator service name: ${CONFIGURABLE_VALIDATOR_SERVICE_NAME}"

read -r -p "Enter path to validator start script (e.g., ~/validator-start.sh) [default: ${CONFIGURABLE_VALIDATOR_START_SCRIPT_PATH}]: " user_validator_start_script
if [ -n "${user_validator_start_script}" ]; then CONFIGURABLE_VALIDATOR_START_SCRIPT_PATH="${user_validator_start_script}"; fi
log_msg "Using validator start script path: ${CONFIGURABLE_VALIDATOR_START_SCRIPT_PATH}"

read -r -p "Enter the specific OLD 'active_release' path segment to search for in the service file [default: ${OLD_SERVICE_PATH_SEGMENT_TO_REPLACE}]: " user_old_service_path
if [ -n "${user_old_service_path}" ]; then OLD_SERVICE_PATH_SEGMENT_TO_REPLACE="${user_old_service_path}"; fi
log_msg "Will look for old path segment: ${OLD_SERVICE_PATH_SEGMENT_TO_REPLACE} in service file PATH."


if confirm_action "Configure persistent PATH for '${CONFIGURABLE_ACTIVE_RELEASE_PATH}' in ${DETECTED_RC_FILE}?"; then
    configure_active_release_path
fi

if ! install_rust_and_components; then
    log_msg "${RED}Rust setup failed or was skipped. Some operations might fail.${NC}"
fi

if ! install_apt_dependencies; then
    log_msg "${RED}APT dependency installation failed or was skipped. Some tunings or builds might fail.${NC}"
fi

if confirm_action "Apply sysctl configurations (UDP buffers, mmap count, open files)?"; then
    configure_sysctl
fi

if confirm_action "Configure systemd DefaultLimitNOFILE?"; then
    configure_systemd_limits
fi

if confirm_action "Configure security limits for open files (nofile)?"; then
    configure_security_limits
fi

if confirm_action "Setup logrotate for validator logs?"; then
    setup_logrotate
fi

if confirm_action "Check/update validator systemd service Environment PATH if '${OLD_SERVICE_PATH_SEGMENT_TO_REPLACE}' is found?"; then
    update_validator_service_environment_path
fi

if confirm_action "Check/update --log path in validator start script '${CONFIGURABLE_VALIDATOR_START_SCRIPT_PATH}'?"; then
    update_validator_start_script_log_path
fi

log_msg "${GREEN}System Tuning and Initial Setup Script finished.${NC}"
echo -e "${GREEN}Please review the output and logs. A reboot may be required for some changes (like systemd limits or kernel parameters if they were part of GRUB) to take full effect.${NC}"

# Provide shell-specific instructions
RC_FILE_BASENAME=$(basename "${DETECTED_RC_FILE}")
echo -e "${YELLOW}Remember to run 'source ~/${RC_FILE_BASENAME}' or open a new ${DETECTED_SHELL_DISPLAY} terminal session to activate any PATH changes made for user $(whoami).${NC}"
log_msg "Final PATH for script: $PATH" 
# Q3VzdG9taXplZCBieSBUNDNoaWUtNDA0
exit 0
