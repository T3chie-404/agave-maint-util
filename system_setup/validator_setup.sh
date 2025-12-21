#!/bin/bash
set -euo pipefail

# Script to setup validator.service and validator-start.sh for Solana/Agave validators
# This script should be run after system_tuning has been completed.
#
# Usage:
#   ./validator_setup.sh

# Color Definitions
NC='\033[0m'
YELLOW='\033[0;33m'
YELLOW_BOLD='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
MAGENTA='\033[0;35m'

# ##############################################################################
#                     CONFIGURATION VARIABLES
# ##############################################################################

# --- Path Configuration ---
LEDGER_DIR="/mnt/ledger"
ACCOUNTS_DIR="/mnt/accounts"
LOG_FILE="/mnt/data/logs/solana-validator.log"
SNAPSHOTS_INCREMENTAL_DIR="/mnt/data/snapshots_incremental"
ACTIVE_RELEASE_PATH="/mnt/data/compiled/active_release"

# --- Service Configuration ---
SERVICE_NAME="validator.service"
START_SCRIPT_NAME="validator-start.sh"

# --- Mainnet-Beta Configuration ---
METRICS_CONFIG="host=https://metrics.solana.com:8086,db=mainnet-beta,u=mainnet-beta_write,p=password"
EXPECTED_GENESIS_HASH="5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"

# Mainnet-Beta Entrypoints
ENTRYPOINTS=(
    "entrypoint.mainnet-beta.solana.com:8001"
    "entrypoint2.mainnet-beta.solana.com:8001"
    "entrypoint3.mainnet-beta.solana.com:8001"
    "entrypoint4.mainnet-beta.solana.com:8001"
    "entrypoint5.mainnet-beta.solana.com:8001"
)

# Mainnet-Beta Known Validators
KNOWN_VALIDATORS=(
    "PUmpKiNnSVAZ3w4KaFX6jKSjXUNHFShGkXbERo54xjb"
    "Ninja1spj6n9t5hVYgF3PdnYz2PLnkt7rvaw3firmjs"
    "CXPeim1wQMkcTvEHx9QdhgKREYYJD8bnaCCqPRwJ1to1"
    "A4hyMd3FyvUJSRafDUSwtLLaQcxRP4r1BRC9w2AJ1to2"
    "23U4mgK9DMCxsv2StC4y2qAptP25Xv5b2cybKCeJ1to3"
    "Ei8VLKR3chZAhJzWwj8PopeuedpQiths2ovVCQ2BCvK7"
    "DiGifdKABxzru2KsjN3YkZZmWP9mVMYK8HWadjtPtJit"
    "9FXD1NXrK6xFU8i4gLAgjj2iMEWTqJhSuQN8tQuDfm2e"
    "CmGiehaqWfEZwyhmN9rckNtnVMeZtsjz1obusNWGyj4p"
)

# --- Default Settings ---
DEFAULT_RPC_PORT="8899"
DEFAULT_DYNAMIC_PORT_RANGE="8000-8020"
DEFAULT_LEDGER_LIMIT="50000000"

# --- End Configuration ---

# ##############################################################################
#                          HELPER FUNCTIONS
# ##############################################################################

log_msg() {
    echo -e "${CYAN}$(date +'%a %b %d %H:%M:%S %Z %Y') - $1${NC}"
}

confirm_action() {
    local prompt_message="$1"
    echo -n -e "${YELLOW_BOLD}${prompt_message} (yes/no): ${NC}"
    local confirmation_input
    read -r confirmation_input
    if [[ "${confirmation_input,,}" == "yes" || "${confirmation_input,,}" == "y" ]]; then
        return 0
    fi
    return 1
}

# ##############################################################################
#                          SETUP FUNCTIONS
# ##############################################################################

# --- Detect or ask for the validator user ---
get_validator_user() {
    local current_user
    current_user=$(whoami)
    
    echo -e "\n${CYAN}--- User Configuration ---${NC}"
    echo -e "Current user: ${GREEN}${current_user}${NC}"
    
    read -r -p "Enter the username that will run the validator [default: ${current_user}]: " input_user
    if [ -n "${input_user}" ]; then
        VALIDATOR_USER="${input_user}"
    else
        VALIDATOR_USER="${current_user}"
    fi
    
    # Get home directory for this user
    if [ "${VALIDATOR_USER}" == "root" ]; then
        VALIDATOR_HOME="/root"
    else
        VALIDATOR_HOME="/home/${VALIDATOR_USER}"
    fi
    
    # Verify user exists
    if ! id "${VALIDATOR_USER}" &>/dev/null; then
        echo -e "${RED}ERROR: User '${VALIDATOR_USER}' does not exist.${NC}"
        echo -e "${YELLOW}Please create the user first with: sudo useradd -m ${VALIDATOR_USER}${NC}"
        exit 1
    fi
    
    log_msg "Validator will run as user: ${VALIDATOR_USER}"
    log_msg "Home directory: ${VALIDATOR_HOME}"
    
    # Set derived paths
    KEYS_DIR="${VALIDATOR_HOME}/keys"
    START_SCRIPT_PATH="${VALIDATOR_HOME}/${START_SCRIPT_NAME}"
    SERVICE_FILE_PATH="/etc/systemd/system/${SERVICE_NAME}"
}

# --- Ask if this is a Validator or RPC node ---
get_node_type() {
    echo -e "\n${CYAN}--- Node Type Configuration ---${NC}"
    echo -e "What type of node is this?"
    echo -e "  ${GREEN}1)${NC} Validator (voting, uses staked/unstaked identity for failover)"
    echo -e "  ${GREEN}2)${NC} RPC (non-voting, full RPC API)"
    
    local choice
    read -r -p "Enter choice [1/2]: " choice
    
    case "${choice}" in
        1)
            NODE_TYPE="validator"
            log_msg "Node type: ${GREEN}Validator${NC}"
            ;;
        2)
            NODE_TYPE="rpc"
            log_msg "Node type: ${GREEN}RPC${NC}"
            ;;
        *)
            echo -e "${RED}Invalid choice. Defaulting to Validator.${NC}"
            NODE_TYPE="validator"
            ;;
    esac
}

# --- Create keys directory with proper permissions ---
setup_keys_directory() {
    echo -e "\n${CYAN}--- Keys Directory Setup ---${NC}"
    
    if [ -d "${KEYS_DIR}" ]; then
        log_msg "Keys directory already exists: ${KEYS_DIR}"
    else
        log_msg "Creating keys directory: ${KEYS_DIR}"
        sudo mkdir -p "${KEYS_DIR}"
        sudo chown "${VALIDATOR_USER}:${VALIDATOR_USER}" "${KEYS_DIR}"
    fi
    
    # Set restrictive permissions
    sudo chmod 700 "${KEYS_DIR}"
    log_msg "Keys directory permissions set to 700 (owner only)"
    
    echo -e "\n${YELLOW_BOLD}Required keypairs in ${KEYS_DIR}:${NC}"
    
    if [ "${NODE_TYPE}" == "validator" ]; then
        echo -e "  - ${CYAN}staked-identity.json${NC}     (your main validator identity)"
        echo -e "  - ${CYAN}unstaked-identity.json${NC}   (for passive/failover mode)"
        echo -e "  - ${CYAN}vote-account-keypair.json${NC} (vote account)"
        echo -e "  - ${CYAN}identity.json${NC}            (symlink, created automatically)"
    else
        echo -e "  - ${CYAN}identity.json${NC}            (RPC node identity, regular file)"
    fi
}

# --- Check for required keypairs ---
check_keypairs() {
    echo -e "\n${CYAN}--- Keypair Check ---${NC}"
    local missing_keys=false
    
    if [ "${NODE_TYPE}" == "validator" ]; then
        # Check for staked identity
        if [ -f "${KEYS_DIR}/staked-identity.json" ]; then
            echo -e "  ${GREEN}✓${NC} staked-identity.json found"
        else
            echo -e "  ${RED}✗${NC} staked-identity.json ${RED}MISSING${NC}"
            missing_keys=true
        fi
        
        # Check for unstaked identity
        if [ -f "${KEYS_DIR}/unstaked-identity.json" ]; then
            echo -e "  ${GREEN}✓${NC} unstaked-identity.json found"
        else
            echo -e "  ${RED}✗${NC} unstaked-identity.json ${RED}MISSING${NC}"
            missing_keys=true
        fi
        
        # Check for vote account
        if [ -f "${KEYS_DIR}/vote-account-keypair.json" ]; then
            echo -e "  ${GREEN}✓${NC} vote-account-keypair.json found"
        else
            echo -e "  ${RED}✗${NC} vote-account-keypair.json ${RED}MISSING${NC}"
            missing_keys=true
        fi
        
        # Create identity symlink (pointing to unstaked for passive boot)
        if [ -f "${KEYS_DIR}/unstaked-identity.json" ]; then
            log_msg "Creating identity.json symlink -> unstaked-identity.json (passive boot)"
            sudo -u "${VALIDATOR_USER}" ln -sf "${KEYS_DIR}/unstaked-identity.json" "${KEYS_DIR}/identity.json"
            echo -e "  ${GREEN}✓${NC} identity.json symlink created"
        fi
        
    else
        # RPC node - just needs identity.json as a real file
        if [ -f "${KEYS_DIR}/identity.json" ] && [ ! -L "${KEYS_DIR}/identity.json" ]; then
            echo -e "  ${GREEN}✓${NC} identity.json found (regular file)"
        elif [ -L "${KEYS_DIR}/identity.json" ]; then
            echo -e "  ${YELLOW}!${NC} identity.json exists but is a symlink"
            echo -e "    ${YELLOW}For RPC nodes, identity.json should be a regular file${NC}"
        else
            echo -e "  ${RED}✗${NC} identity.json ${RED}MISSING${NC}"
            echo -e "    ${YELLOW}Generate with: agave-keygen new -o ${KEYS_DIR}/identity.json${NC}"
            missing_keys=true
        fi
    fi
    
    if [ "${missing_keys}" == "true" ]; then
        echo -e "\n${YELLOW_BOLD}WARNING: Some keypairs are missing.${NC}"
        echo -e "${YELLOW}You can continue setup, but the validator won't start without them.${NC}"
        if ! confirm_action "Continue anyway?"; then
            echo -e "${RED}Setup cancelled.${NC}"
            exit 1
        fi
    fi
}

# --- Generate validator-start.sh ---
generate_start_script() {
    echo -e "\n${CYAN}--- Generating ${START_SCRIPT_NAME} ---${NC}"
    
    if [ -f "${START_SCRIPT_PATH}" ]; then
        echo -e "${YELLOW}WARNING: ${START_SCRIPT_PATH} already exists.${NC}"
        if ! confirm_action "Overwrite existing file?"; then
            log_msg "Skipping start script generation."
            return
        fi
        # Backup existing
        sudo cp "${START_SCRIPT_PATH}" "${START_SCRIPT_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        log_msg "Backed up existing file."
    fi
    
    # Build entrypoint arguments
    local entrypoint_args=""
    for ep in "${ENTRYPOINTS[@]}"; do
        entrypoint_args+="  --entrypoint ${ep} \\\\\n"
    done
    
    # Build known validator arguments
    local known_validator_args=""
    for kv in "${KNOWN_VALIDATORS[@]}"; do
        known_validator_args+="  --known-validator ${kv} \\\\\n"
    done
    
    # Generate script based on node type
    if [ "${NODE_TYPE}" == "validator" ]; then
        cat > /tmp/validator-start.sh << EOF
#!/bin/bash
export SOLANA_METRICS_CONFIG="${METRICS_CONFIG}"

# Mainnet-Beta Validator Start Script
exec agave-validator \\
  --identity ${KEYS_DIR}/identity.json \\
  --authorized-voter ${KEYS_DIR}/staked-identity.json \\
  --vote-account ${KEYS_DIR}/vote-account-keypair.json \\
  --ledger ${LEDGER_DIR} \\
  --limit-ledger-size ${DEFAULT_LEDGER_LIMIT} \\
  --accounts ${ACCOUNTS_DIR} \\
  --incremental-snapshot-archive-path ${SNAPSHOTS_INCREMENTAL_DIR} \\
  --log ${LOG_FILE} \\
  --rpc-port ${DEFAULT_RPC_PORT} \\
  --private-rpc \\
  --dynamic-port-range ${DEFAULT_DYNAMIC_PORT_RANGE} \\
  --no-poh-speed-test \\
  --no-port-check \\
  --minimal-snapshot-download-speed 500000000 \\
$(for kv in "${KNOWN_VALIDATORS[@]}"; do echo "  --known-validator ${kv} \\"; done)
$(for ep in "${ENTRYPOINTS[@]}"; do echo "  --entrypoint ${ep} \\"; done)
  --expected-genesis-hash ${EXPECTED_GENESIS_HASH} \\
  --wal-recovery-mode skip_any_corrupted_record
EOF
    else
        # RPC node configuration
        cat > /tmp/validator-start.sh << EOF
#!/bin/bash
export SOLANA_METRICS_CONFIG="${METRICS_CONFIG}"

# Mainnet-Beta RPC Node Start Script
exec agave-validator \\
  --identity ${KEYS_DIR}/identity.json \\
  --no-voting \\
  --ledger ${LEDGER_DIR} \\
  --limit-ledger-size ${DEFAULT_LEDGER_LIMIT} \\
  --accounts ${ACCOUNTS_DIR} \\
  --incremental-snapshot-archive-path ${SNAPSHOTS_INCREMENTAL_DIR} \\
  --log ${LOG_FILE} \\
  --rpc-port ${DEFAULT_RPC_PORT} \\
  --rpc-bind-address 0.0.0.0 \\
  --dynamic-port-range ${DEFAULT_DYNAMIC_PORT_RANGE} \\
  --no-poh-speed-test \\
  --no-port-check \\
  --full-rpc-api \\
  --account-index program-id \\
  --account-index spl-token-owner \\
  --account-index spl-token-mint \\
  --minimal-snapshot-download-speed 500000000 \\
$(for kv in "${KNOWN_VALIDATORS[@]}"; do echo "  --known-validator ${kv} \\"; done)
$(for ep in "${ENTRYPOINTS[@]}"; do echo "  --entrypoint ${ep} \\"; done)
  --expected-genesis-hash ${EXPECTED_GENESIS_HASH} \\
  --wal-recovery-mode skip_any_corrupted_record
EOF
    fi
    
    sudo mv /tmp/validator-start.sh "${START_SCRIPT_PATH}"
    sudo chown "${VALIDATOR_USER}:${VALIDATOR_USER}" "${START_SCRIPT_PATH}"
    sudo chmod 755 "${START_SCRIPT_PATH}"
    
    log_msg "${GREEN}Created ${START_SCRIPT_PATH}${NC}"
}

# --- Generate validator.service ---
generate_service_file() {
    echo -e "\n${CYAN}--- Generating ${SERVICE_NAME} ---${NC}"
    
    if [ -f "${SERVICE_FILE_PATH}" ]; then
        echo -e "${YELLOW}WARNING: ${SERVICE_FILE_PATH} already exists.${NC}"
        if ! confirm_action "Overwrite existing file?"; then
            log_msg "Skipping service file generation."
            return
        fi
        # Backup existing
        sudo cp "${SERVICE_FILE_PATH}" "${SERVICE_FILE_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        log_msg "Backed up existing file."
    fi
    
    # Build ExecStartPre for validator (passive boot symlink)
    local exec_start_pre=""
    if [ "${NODE_TYPE}" == "validator" ]; then
        exec_start_pre="ExecStartPre=/bin/bash -c 'ln -sf ${KEYS_DIR}/unstaked-identity.json ${KEYS_DIR}/identity.json'"
    fi
    
    cat > /tmp/validator.service << EOF
[Unit]
Description=Solana ${NODE_TYPE^} (Mainnet-Beta)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=3
User=${VALIDATOR_USER}
LimitNOFILE=2000000
LimitMEMLOCK=2000000000
LogRateLimitIntervalSec=0
Environment="PATH=${ACTIVE_RELEASE_PATH}:${VALIDATOR_HOME}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF

    # Add ExecStartPre only for validators
    if [ "${NODE_TYPE}" == "validator" ]; then
        cat >> /tmp/validator.service << EOF

# Force boot to passive (unstaked) identity before starting validator
${exec_start_pre}
EOF
    fi

    cat >> /tmp/validator.service << EOF

ExecStart=${START_SCRIPT_PATH}

[Install]
WantedBy=multi-user.target
EOF
    
    sudo mv /tmp/validator.service "${SERVICE_FILE_PATH}"
    sudo chmod 644 "${SERVICE_FILE_PATH}"
    
    log_msg "${GREEN}Created ${SERVICE_FILE_PATH}${NC}"
    
    # Reload systemd
    log_msg "Reloading systemd daemon..."
    sudo systemctl daemon-reload
}

# --- Enable and optionally start service ---
configure_service() {
    echo -e "\n${CYAN}--- Service Configuration ---${NC}"
    
    if confirm_action "Enable ${SERVICE_NAME} to start on boot?"; then
        sudo systemctl enable "${SERVICE_NAME}"
        log_msg "${GREEN}Service enabled${NC}"
    fi
    
    echo -e "\n${YELLOW}The validator service is NOT started automatically.${NC}"
    echo -e "${YELLOW}When ready, start with: ${GREEN}sudo systemctl start ${SERVICE_NAME}${NC}"
}

# --- Print summary ---
print_summary() {
    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    SETUP COMPLETE                              ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e ""
    echo -e "${CYAN}Node Type:${NC}        ${NODE_TYPE^}"
    echo -e "${CYAN}User:${NC}             ${VALIDATOR_USER}"
    echo -e "${CYAN}Keys Directory:${NC}   ${KEYS_DIR}"
    echo -e "${CYAN}Start Script:${NC}     ${START_SCRIPT_PATH}"
    echo -e "${CYAN}Service File:${NC}     ${SERVICE_FILE_PATH}"
    echo -e ""
    echo -e "${CYAN}Data Paths:${NC}"
    echo -e "  Ledger:         ${LEDGER_DIR}"
    echo -e "  Accounts:       ${ACCOUNTS_DIR}"
    echo -e "  Logs:           ${LOG_FILE}"
    echo -e "  Snapshots:      ${SNAPSHOTS_INCREMENTAL_DIR}"
    echo -e ""
    echo -e "${YELLOW}Next Steps:${NC}"
    if [ "${NODE_TYPE}" == "validator" ]; then
        echo -e "  1. Ensure keypairs are in ${KEYS_DIR}:"
        echo -e "     - staked-identity.json"
        echo -e "     - unstaked-identity.json"
        echo -e "     - vote-account-keypair.json"
    else
        echo -e "  1. Ensure identity.json is in ${KEYS_DIR}"
    fi
    echo -e "  2. Create data directories if needed:"
    echo -e "     sudo mkdir -p ${LEDGER_DIR} ${ACCOUNTS_DIR} ${SNAPSHOTS_INCREMENTAL_DIR}"
    echo -e "     sudo chown ${VALIDATOR_USER}:${VALIDATOR_USER} ${LEDGER_DIR} ${ACCOUNTS_DIR} ${SNAPSHOTS_INCREMENTAL_DIR}"
    echo -e "  3. Start the validator:"
    echo -e "     ${GREEN}sudo systemctl start ${SERVICE_NAME}${NC}"
    echo -e "  4. Check status:"
    echo -e "     ${GREEN}sudo systemctl status ${SERVICE_NAME}${NC}"
    echo -e "     ${GREEN}tail -f ${LOG_FILE}${NC}"
    echo -e ""
}

# ##############################################################################
#                          MAIN EXECUTION
# ##############################################################################

echo -e "${MAGENTA}"
echo "═══════════════════════════════════════════════════════════════"
echo "          Solana/Agave Validator Setup Script"
echo "          Network: Mainnet-Beta"
echo "═══════════════════════════════════════════════════════════════"
echo -e "${NC}"

# Check if running with appropriate permissions
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${YELLOW}Running as root. Service files will be created directly.${NC}"
else
    echo -e "${YELLOW}Not running as root. Will use sudo for system files.${NC}"
fi

# Run setup steps
get_validator_user
get_node_type
setup_keys_directory
check_keypairs
generate_start_script
generate_service_file
configure_service
print_summary

log_msg "${GREEN}Setup script completed.${NC}"
exit 0

