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
# --- End Configuration Variables ---

# ##############################################################################
# #                                                                            #
# ##############################################################################


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
    local active_release_path_to_add="${CONFIGURABLE_ACTIVE_RELEASE_PATH}" 
    local bashrc_file="$HOME/.bashrc" 
    
    # Expand $HOME in the path to add for accurate comparison and writing
    local expanded_active_release_path_to_add
    expanded_active_release_path_to_add=$(eval echo "${active_release_path_to_add}")
    local new_path_line_literal="export PATH=\"${expanded_active_release_path_to_add}:\$PATH\""

    if [ ! -f "${bashrc_file}" ]; then
        log_msg "${RED}ERROR: ${bashrc_file} not found for user $(whoami). Cannot make PATH modification persistent.${NC}"
        return 1
    fi

    # Check if the exact new path line already exists and is NOT commented out
    # grep -Fx: Fixed string, exact match of whole line
    # grep -vE '^[[:space:]]*#': Exclude commented lines
    if grep -Fxq -- "${new_path_line_literal}" "${bashrc_file}" && \
       grep -Fx -- "${new_path_line_literal}" "${bashrc_file}" | grep -qvE -- "^[[:space:]]*#"; then
        log_msg "${GREEN}'${expanded_active_release_path_to_add}' (exact match) already actively configured in PATH in ${bashrc_file}.${NC}"
    else
        # The exact line we want to add is not currently active (it's missing or commented).
        # Now, check for ANY OTHER active lines that set an active_release path.
        local generic_active_release_pattern="export PATH=\"[^\"]*/active_release:\$PATH\""
        
        # Get all lines matching the generic pattern that are NOT commented out
        mapfile -t all_active_generic_lines < <(grep -E -- "${generic_active_release_pattern}" "${bashrc_file}" | grep -vE -- "^[[:space:]]*#")
        
        local other_conflicting_lines_found=false
        if [ ${#all_active_generic_lines[@]} -gt 0 ]; then
            local temp_other_lines=()
            for line in "${all_active_generic_lines[@]}"; do
                # Only consider it a "conflicting other" if it's not the exact line we intend to manage
                if [ "$line" != "$new_path_line_literal" ]; then
                    temp_other_lines+=("$line")
                fi
            done
            
            if [ ${#temp_other_lines[@]} -gt 0 ]; then
                other_conflicting_lines_found=true
                log_msg "${YELLOW_BOLD}WARNING: Found OTHER existing ACTIVE line(s) in ${bashrc_file} that appear to set an 'active_release' PATH (different from the one being configured):${NC}"
                for found_line in "${temp_other_lines[@]}"; do
                    local line_num
                    line_num=$(grep -nF -- "${found_line}" "${bashrc_file}" | head -n1 | cut -d: -f1)
                    log_msg "${YELLOW}  L${line_num}: ${found_line}${NC}"
                done
                log_msg "${YELLOW}It is highly recommended to manually review ${bashrc_file} and remove old/conflicting 'active_release' PATH entries to avoid unexpected behavior.${NC}"
            fi
        fi

        # Add the new_path_line_literal if it's not currently active.
        # The first 'if' condition already determined it's not active.
        log_msg "Adding new PATH line for '${expanded_active_release_path_to_add}' to ${bashrc_file}..."
        echo '' >> "${bashrc_file}" 
        echo "# Add Solana active_release to PATH (managed by system_tuning_setup.sh on $(date))" >> "${bashrc_file}"
        echo "${new_path_line_literal}" >> "${bashrc_file}"
        log_msg "${GREEN}Added '${expanded_active_release_path_to_add}' to PATH in ${bashrc_file}.${NC}"
        echo -e "${YELLOW}Please run 'source ~/.bashrc' or open a new terminal for this PATH change to take full effect in your interactive session.${NC}"
    fi
}

install_rust_and_components() {
    log_msg "Checking for Rust installation for user $(whoami)..."
    # Check if cargo is in PATH; source .cargo/env if not, for the current script session
    if ! command -v cargo &> /dev/null && [ -f "$HOME/.cargo/env" ]; then
        log_msg "Cargo not in PATH, attempting to source $HOME/.cargo/env for this session..."
        source "$HOME/.cargo/env"
    fi

    if ! command -v cargo &> /dev/null || ! command -v rustup &> /dev/null; then
        log_msg "${YELLOW}Rust (cargo/rustup) not found or not in PATH for user $(whoami).${NC}" 
        if confirm_action "Install Rust for user $(whoami) using 'curl https://sh.rustup.rs -sSf | sh'?"; then
            log_msg "Installing Rust for user $(whoami)..."
            # Run as the current user. rustup installs to $HOME/.cargo
            curl https://sh.rustup.rs -sSf | sh -s -- -y --no-modify-path
            if [ -f "$HOME/.cargo/env" ]; then
                source "$HOME/.cargo/env" # Source for current script session
                log_msg "${GREEN}Rust installed for $(whoami). Sourced $HOME/.cargo/env for current script session.${NC}"
                
                log_msg "Adding 'source \"\$HOME/.cargo/env\"' to $HOME/.bashrc for persistence..."
                if ! grep -qF 'source "$HOME/.cargo/env"' "$HOME/.bashrc"; then 
                    echo '' >> "$HOME/.bashrc" 
                    echo '# Rust/Cargo PATH setup (managed by system_tuning_setup.sh)' >> "$HOME/.bashrc"
                    echo 'source "$HOME/.cargo/env"' >> "$HOME/.bashrc"
                    log_msg "Added Rust source line to $HOME/.bashrc."
                else
                    log_msg "Rust source line already exists in $HOME/.bashrc."
                fi
                
                log_msg "${GREEN}Rust PATH configured in $HOME/.bashrc for future sessions.${NC}"
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
        "git" "curl" "bc" "jq" "sed" "gawk" # Changed awk to gawk
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
    SYSCTL_CONF_FILE="/etc/sysctl.d/21-agave-validator.conf" # Name can be configured if needed
    
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
    LIMIT_SETTING="DefaultLimitNOFILE=2000000" # Value can be configured if needed

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
    SECURITY_LIMITS_FILE="/etc/security/limits.d/90-solana-nofiles.conf" # Name can be configured
    NOFILE_LIMIT="2000000" # Value can be configured
    
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
        if sudo chown "${LOG_DIR_USER}":"${LOG_DIR_USER}" "${LOG_DIR}"; then # Use variable for user
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
  # copytruncate # This is now the alternative
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
    echo -e "${YELLOW}Note: Using 'postrotate' with USR1 signal. If ${VALIDATOR_SERVICE_NAME} does not support this, uncomment 'copytruncate' and comment out the 'postrotate' block.${NC}"
}


# --- Main Execution ---
log_msg "Starting System Tuning and Initial Setup Script..."
log_msg "Current PATH for script: $PATH" 

# Prompt for user-configurable paths if they want to change defaults
echo -e "\n${CYAN_BOLD}--- Path Configurations ---${NC}"
echo -e "${YELLOW_BOLD}IMPORTANT: Before configuring the 'active_release' PATH, please manually check your${NC} ${YELLOW_BOLD}~/.bashrc${NC}"
echo -e "${YELLOW_BOLD}If you have any old 'export PATH=.../active_release:\$PATH' lines, consider removing or commenting them out to avoid conflicts.${NC}"
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


if confirm_action "Configure persistent PATH for '${CONFIGURABLE_ACTIVE_RELEASE_PATH}' in ~/.bashrc?"; then
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

log_msg "${GREEN}System Tuning and Initial Setup Script finished.${NC}"
echo -e "${GREEN}Please review the output and logs. A reboot may be required for some changes (like systemd limits or kernel parameters if they were part of GRUB) to take full effect.${NC}"
echo -e "${YELLOW}Remember to run 'source ~/.bashrc' or open a new terminal session to activate any PATH changes made to ~/.bashrc for user $(whoami).${NC}"
log_msg "Final PATH for script: $PATH" 
# Q3VzdG9taXplZCBieSBUNDNoaWUtNDA0
exit 0
