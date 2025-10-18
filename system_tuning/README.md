# System Tuning and Initial Setup Script for Solana Validator

This script is designed to perform initial system configuration and install necessary dependencies on a new Ubuntu server to prepare it for building and running a Solana (or Agave-based) validator.

## Shell Compatibility

**This script supports both Bash and Zsh shells!**

* Automatically detects your default shell (bash or zsh)
* Configures the appropriate RC file:
  * Bash users: Updates `~/.bashrc`
  * Zsh users: Updates `~/.zshrc`
* Creates RC files if they don't exist
* Works seamlessly regardless of which shell you use
* All configurations work identically in both shell environments

## Purpose

The primary goal of this script is to automate common setup tasks, including:
- **Shell-aware Configuration:** Detects user's shell and configures the correct RC file (`.bashrc` or `.zshrc`)
- Installation of Rust and its components for the user running the script
- Installation of essential APT packages required for building the validator from source
- Configuration of persistent `PATH` environment variables for user convenience
- Application of recommended kernel (`sysctl`) tunings for performance
- Configuration of system-wide (`systemd`) and user-session (`security/limits`) open file descriptor limits
- Setup of log rotation for the validator's log file
- Checking and optionally updating the `--log` path in a specified validator start script to match the logrotate configuration
- Checking and optionally updating the `Environment="PATH=..."` line in a specified systemd service file if an old `active_release` path is found

**This script should typically be run once on a new server by the user who will be managing/running the validator (e.g., `solval`), and this user must have `sudo` privileges for system-wide changes.**

## Features

- **Interactive Confirmation:** Prompts the user before performing major groups of actions (e.g., installing Rust, installing APT packages, applying system tunings, updating script/service files).
- **Configurable Paths & Settings:** Allows user input at the beginning to confirm or change key paths and names, with sensible defaults provided in the script.
- **Dependency Installation:**
    - **Rust:** Checks for Rust (via `cargo` and `rustup`). If not found, offers to install it using the official `rustup.rs` script into the current user's `$HOME`. Adds `rustfmt` component and runs `rustup update`.
    - **APT Packages:** Checks for a predefined list of essential build dependencies (e.g., `libssl-dev`, `llvm`, `clang`, `git`, `curl`, `protobuf-compiler`, `bc`, `jq`, `sed`, `gawk`) and offers to install any missing ones.
- **PATH Configuration:**
    - Automatically detects user's shell (Bash or Zsh)
    - Configures the appropriate RC file (`~/.bashrc` for Bash, `~/.zshrc` for Zsh`) to include `$HOME/.cargo/bin` in the `PATH` for Rust tools
    - Configures the appropriate RC file to include the configured `active_release` path (e.g., `$HOME/data/compiled/active_release`) in the `PATH`
    - Creates RC file if it doesn't exist
    - Warns if other active `active_release` paths are detected in the RC file
- **System Tuning:**
    - **Sysctl:** Applies kernel parameter tunings by creating `/etc/sysctl.d/21-agave-validator.conf`.
    - **Systemd Limits:** Configures `DefaultLimitNOFILE` in `/etc/systemd/system.conf`.
    - **Security Limits:** Creates `/etc/security/limits.d/90-solana-nofiles.conf` to increase the open file descriptor limit for user sessions.
- **Logrotate Setup:**
    - Creates a logrotate configuration file for the validator's log file.
- **Systemd Service Management:**
    - **Creates new service files** if they don't exist (with user confirmation)
    - Displays the complete contents before creation
    - **Updates existing service files** by replacing old PATH segments
    - Shows current file contents and proposed changes before updating
    - Creates backup files before modifications
    - Automatically reloads systemd after changes
    - Optionally enables service on boot
- **Convenience Scripts:**
    - Creates helpful scripts in `$HOME` for common validator tasks:
        - `tail_logs.sh` - Tail the validator log file
        - `mon.sh` - Monitor validator using agave-validator monitor
        - `catchup.sh` - Check validator catchup status
        - `exit-validator.sh` - Gracefully exit validator (takes snapshot before shutdown)
    - All scripts are executable and use paths configured during setup
    - `exit-validator.sh` is automatically regenerated after each upgrade with version-appropriate flags
    - Creates the log directory if it doesn't exist and attempts to set ownership to the configured user.
    - Defaults to using `postrotate` with `systemctl kill -s USR1` for log reopening.
- **Validator Script/Service Path Alignment:**
    - **Start Script:** Checks a user-specified validator start script (e.g., `~/validator-start.sh`) for an active `--log <path>` argument. If the path differs from the one configured for logrotate, it prompts the user to update it.
    - **Systemd Service:** Checks the validator's systemd service file for an `Environment="PATH=..."` line. If a specified old `active_release` path segment is found, it prompts the user to replace it with the new `CONFIGURABLE_ACTIVE_RELEASE_PATH`.
- **Logging:** Provides timestamped log messages for its operations, with color-coded output for readability.
- **Error Handling:** Uses `set -euo pipefail` to exit on errors.
- **Watermarks:** Includes a plain text and a Base64 encoded watermark for script identification.

## Prerequisites

1.  **Ubuntu System:** The script is tailored for Ubuntu-like systems using `apt-get`.
2.  **Sudo Access:** The user running this script must have `sudo` privileges (ideally passwordless for smoother operation of the script itself, though it will prompt for `sudo` password if needed by `sudo` commands).
3.  **Standard Linux Utilities:** Assumes common utilities are available.
4.  **Internet Access:** Required for downloading Rust and APT packages.
5.  **Validator Start Script (Optional):** If you want the script to check/update the `--log` path, ensure the `CONFIGURABLE_VALIDATOR_START_SCRIPT_PATH` points to your actual validator start script.
6.  **Validator Systemd Service File (Optional):** If you want the script to check/update the `Environment="PATH=..."`, ensure `CONFIGURABLE_VALIDATOR_SERVICE_NAME` is correct.

## Configuration (Interactive and In-Script Defaults)

The script will prompt you at the beginning to confirm or change the following default values (defined at the top of the script):

- **`CONFIGURABLE_ACTIVE_RELEASE_PATH`**: Path for the symlink pointing to the active validator binaries (used for user's `PATH`).
  *(Default: `$HOME/data/compiled/active_release`)*
- **`CONFIGURABLE_VALIDATOR_LOG_FILE_PATH`**: Location for the main validator log, used by logrotate and for checking the start script.
  *(Default: `$HOME/data/logs/solana-validator.log`)*
- **`CONFIGURABLE_VALIDATOR_LOG_DIR_USER`**: The user that will own the validator log directory.
  *(Default: `sol` - **Change this to your validator user, e.g., `solval`**)*
- **`CONFIGURABLE_VALIDATOR_SERVICE_NAME`**: The systemd service name of your validator.
  *(Default: `validator.service`)*
- **`CONFIGURABLE_VALIDATOR_START_SCRIPT_PATH`**: Path to your validator's startup shell script.
  *(Default: `$HOME/validator-start.sh`)*
- **`OLD_SERVICE_PATH_SEGMENT_TO_REPLACE`**: A specific old path string to look for in the systemd service file's `Environment="PATH=..."` line for replacement.
  *(Default: `/home/sol/.local/share/xandeum/install/releases/active_release`)*

Other internal defaults that can be modified by editing the script:
- `REQUIRED_APT_PACKAGES` array.
- Specific values for `sysctl`, `systemd` (`DefaultLimitNOFILE`), and `security/limits` (`nofile`).
- Logrotate parameters (e.g., `rotate 7`, `daily`).
- `CONFIGURABLE_VALIDATOR_BINARY_NAME` (used by the service path update logic, though not directly configurable via prompt in this script version).

## Usage

1.  Save the script to a file (e.g., `system-tuner.sh`).
2.  Make it executable: `chmod +x system-tuner.sh`.
3.  **Run it as the user who will manage the validator and whose `~/.bashrc` should be configured (e.g., `solval`). This user needs `sudo` privileges.**
    ```
    ./system-tuner.sh
    ```
    If you are logged in as root and want to set it up for `solval`, you might run:
    ```
    sudo -u solval ./system-tuner.sh
    ```
    (Ensure `solval` has the necessary sudo rights for the `sudo` commands *within* the script).

4.  Follow the interactive prompts to confirm path configurations and each major section of changes.

## Important Notes

* **Run Once:** This script is generally intended to be run once on a new server for a specific user.
* **Shell Support:** The script automatically detects whether you use Bash or Zsh and configures the appropriate RC file. No manual configuration needed!
* **Reboot:** Some changes (systemd limits, kernel parameters if they were modified via GRUB - though this script uses `sysctl`) might require a system reboot to take full effect.
* **Source RC File:** For `PATH` changes to apply to your current interactive terminal session, run `source ~/.bashrc` (for Bash) or `source ~/.zshrc` (for Zsh), or open a new terminal session after the script completes.
* **User Context:** The script modifies the appropriate RC file (`~/.bashrc` or `~/.zshrc`) for the user *executing* the script, based on shell detection.
* **Review Output:** Carefully review the script's output and any log messages for errors or warnings. The script will clearly indicate which shell it detected and which RC file it's configuring.
* **Backup of Modified Files:** The script attempts to back up `/etc/systemd/system.conf` and the validator start script before modifying them.

This script provides a solid foundation for preparing a server for a Solana validator. Always understand what a script does before running it, especially one that makes system-level changes.
