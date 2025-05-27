# System Tuning and Initial Setup Script for Solana Validator

This script is designed to perform initial system configuration and install necessary dependencies on a new Ubuntu server to prepare it for building and running a Solana (or Agave-based) validator.

## Purpose

The primary goal of this script is to automate common setup tasks, including:
- Installation of Rust and its components for the user running the script.
- Installation of essential APT packages required for building the validator from source.
- Configuration of persistent `PATH` environment variables for user convenience.
- Application of recommended kernel (`sysctl`) tunings for performance.
- Configuration of system-wide (`systemd`) and user-session (`security/limits`) open file descriptor limits.
- Setup of log rotation for the validator's log file.

**This script should typically be run once on a new server by the user who will be managing/running the validator (e.g., `solval`), and this user must have `sudo` privileges for system-wide changes.**

## Features

- **Interactive Confirmation:** Prompts the user before performing major groups of actions (e.g., installing Rust, installing APT packages, applying system tunings).
- **Configurable Paths & Settings:** Allows user input at the beginning to confirm or change key paths and names, with sensible defaults provided in the script.
- **Dependency Installation:**
    - **Rust:** Checks for Rust (via `cargo` and `rustup`). If not found, offers to install it using the official `rustup.rs` script into the current user's `$HOME`. Adds `rustfmt` component and runs `rustup update`.
    - **APT Packages:** Checks for a predefined list of essential build dependencies (e.g., `libssl-dev`, `llvm`, `clang`, `git`, `curl`, `protobuf-compiler`, `bc`, `jq`, `sed`, `gawk`) and offers to install any missing ones.
- **PATH Configuration:**
    - Configures the current user's `~/.bashrc` to include `$HOME/.cargo/bin` in the `PATH` for Rust tools.
    - Configures the current user's `~/.bashrc` to include the configured `active_release` path (e.g., `$HOME/data/compiled/active_release`) in the `PATH`.
    - Warns if other active `active_release` paths are detected in `~/.bashrc`.
- **System Tuning:**
    - **Sysctl:** Applies kernel parameter tunings by creating `/etc/sysctl.d/21-agave-validator.conf` to:
        - Increase maximum UDP buffer sizes (`net.core.rmem_max`, `net.core.wmem_max`).
        - Increase the memory-mapped files limit (`vm.max_map_count`).
        - Increase the system-wide open file descriptors limit (`fs.nr_open`).
    - **Systemd Limits:** Configures `DefaultLimitNOFILE` in `/etc/systemd/system.conf` to increase the default open file limit for services managed by systemd.
    - **Security Limits:** Creates `/etc/security/limits.d/90-solana-nofiles.conf` to increase the open file descriptor limit for user sessions.
- **Logrotate Setup:**
    - Creates a logrotate configuration file (e.g., `/etc/logrotate.d/solana-validator-script-setup`) for the validator's log file.
    - Creates the log directory if it doesn't exist and attempts to set ownership to the configured user.
    - Defaults to using `postrotate` with `systemctl kill -s USR1` for log reopening.
- **Logging:** Provides timestamped log messages for its operations, with color-coded output for readability.
- **Error Handling:** Uses `set -euo pipefail` to exit on errors.
- **Watermarks:** Includes a plain text and a Base64 encoded watermark for script identification.

## Prerequisites

1.  **Ubuntu System:** The script is tailored for Ubuntu-like systems using `apt-get`.
2.  **Sudo Access:** The user running this script must have `sudo` privileges (ideally passwordless for smoother operation of the script itself, though it will prompt for `sudo` password if needed by `sudo` commands).
3.  **Standard Linux Utilities:** Assumes common utilities are available.
4.  **Internet Access:** Required for downloading Rust and APT packages.

## Configuration (Interactive and In-Script Defaults)

The script will prompt you at the beginning to confirm or change the following default values (defined at the top of the script):

- **`CONFIGURABLE_ACTIVE_RELEASE_PATH`**: Path for the symlink pointing to the active validator binaries (used for user's `PATH`).
  *(Default: `$HOME/data/compiled/active_release`)*
- **`CONFIGURABLE_VALIDATOR_LOG_FILE_PATH`**: Location for the main validator log, used by logrotate.
  *(Default: `$HOME/data/logs/solana-validator.log`)*
- **`CONFIGURABLE_VALIDATOR_LOG_DIR_USER`**: The user that will own the validator log directory.
  *(Default: `sol` - **Change this to your validator user, e.g., `solval`**)*
- **`CONFIGURABLE_VALIDATOR_SERVICE_NAME`**: The systemd service name of your validator.
  *(Default: `validator.service`)*

Other internal defaults that can be modified by editing the script:
- `REQUIRED_APT_PACKAGES` array.
- Specific values for `sysctl`, `systemd` (`DefaultLimitNOFILE`), and `security/limits` (`nofile`).
- Logrotate parameters (e.g., `rotate 7`, `daily`).

## Usage

1.  Save the script to a file (e.g., `system_tuning_setup.sh`).
2.  Make it executable: `chmod +x system_tuning_setup.sh`.
3.  **Run it as the user who will manage the validator and whose `~/.bashrc` should be configured (e.g., `solval`). This user needs `sudo` privileges.**
    ```bash
    ./system_tuning_setup.sh
    ```
    If you are logged in as root and want to set it up for `solval`, you might run:
    ```bash
    sudo -u solval ./system_tuning_setup.sh
    ```
    (Ensure `solval` has the necessary sudo rights for the `sudo` commands *within* the script).

4.  Follow the interactive prompts to confirm path configurations and each major section of changes.

## Important Notes

* **Run Once:** This script is generally intended to be run once on a new server for a specific user.
* **Reboot:** Some changes, particularly to `systemd` limits or kernel parameters (if they were modified via GRUB - though this script uses `sysctl`), might require a system reboot to take full effect for all services and sessions. The script will remind you of this.
* **Source `~/.bashrc`:** For `PATH` changes made to `~/.bashrc` to apply to your current interactive terminal session, you need to run `source ~/.bashrc` or open a new terminal session after the script completes.
* **User Context:** The script modifies `$HOME/.bashrc` for the user *executing* the script.
* **Review Output:** Carefully review the script's output and any log messages for errors or warnings.

This script provides a solid foundation for preparing a server for a Solana validator. Always understand what a script does before running it, especially one that makes system-level changes.
EOF
