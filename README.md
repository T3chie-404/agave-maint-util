# agave-maint-util
# Agave Validator Upgrade, Rollback, and Clean Script (`start_upgrade-agave.sh`)

This script automates the process of upgrading, rolling back, or cleaning old compiled versions of the Agave validator client (including Jito, vanilla Agave, and Xandeum-Agave variants). It handles fetching specified versions from Git repositories, building the binaries, managing compiled versions, and updating a symbolic link to the active version.

## Features

* **Upgrade Mode:**
    * Builds a specific version tag of the validator client.
    * Supports building different client variants:
        * **Jito:** If the tag ends with `-jito`.
        * **Xandeum-Agave:** If the tag starts with `x` (and does not end with `-jito`); prompts for confirmation.
        * **Vanilla Agave:** For other tags; prompts for confirmation.
    * Clones the required Git repository if the specified source directory does not exist.
    * Allows specifying the number of parallel build jobs via the `-j <num_jobs>` argument (by setting `CARGO_BUILD_JOBS` environment variable for `cargo-install-all.sh`).
    * Uses the project-specific `./scripts/cargo-install-all.sh` for building, ensuring `CI_COMMIT` (source hash) is embedded. Falls back to `cargo build --release` with a warning if `cargo-install-all.sh` is not found.
    * Updates Git submodules (with non-interactive SSH host key acceptance for `github.com`).
    * Forces Git checkout to overwrite local changes like `Cargo.lock`.
* **Rollback Mode:**
    * Lists previously compiled versions available on the system.
    * Allows interactive selection (using a numbered menu) of a version to roll back to.
* **Clean Mode:**
    * Lists previously compiled versions available on the system, marking the active version as non-deletable.
    * Allows interactive selection (by entering numbers) of multiple old versions to delete.
    * Displays the total disk space that will be freed.
    * Prompts for final confirmation before deleting selected versions.
* **Version Management:**
    * Stores compiled binaries in version-specific directories under a base `compiled` directory (e.g., `$HOME/data/compiled/<tag>/bin/`).
    * Uses a symbolic link (`active_release`) to point to the currently active version's `bin` directory.
    * Backs up the `active_release` symlink before an upgrade or rollback by renaming it with a timestamp.
* **Verification:**
    * Performs a primary version check by running the validator binary from the direct symlinked path.
    * Performs a secondary version check by attempting to run the validator binary from the home directory (testing `PATH` resolution).
* **Interactive Prompts:**
    * Includes prompts for user confirmation at critical steps.
    * Allows exiting the script gracefully (with an 'x' option) before a validator restart or at the very end of the script.
* **Colored Output:** Uses colors for better readability of messages.
* **Error Handling:** Includes `set -euo pipefail` for robust error handling.

## Prerequisites

1.  **Bash Shell:** The script is written for Bash.
2.  **Git:** Required for fetching source code, cloning, and checking out versions.
3.  **Rust and Cargo:** Required for building the validator client from source. (Assumed to be pre-installed, e.g., by a separate system tuning script).
4.  **Build Tools & Dependencies:** `rsync`, `mkdir`, `rm`, `ln`, `mv`, `du`, `find`, `awk`, `sort`, and common build essentials (like `libssl-dev`, `pkg-config`, etc., typically handled by a system setup script).
5.  **Validator Source Code (will be cloned if not present):**
    * Jito variant: Default path `JITO_SOURCE_DIR` (e.g., `$HOME/data/jito-solana`).
    * Vanilla Agave: Default path `VANILLA_SOURCE_DIR` (e.g., `$HOME/data/agave`).
    * Xandeum-Agave: Default path `XANDEUM_SOURCE_DIR` (e.g., `$HOME/data/xandeum-agave`).
6.  **Directory Structure:**
    * The script expects a base directory for compiled versions at `$HOME/data/compiled` (or as set in `COMPILED_BASE_DIR`).
    * The user running the script needs write permissions to the parent of the source directories (e.g., `$HOME/data`) if the script needs to clone the repositories. The script will use `sudo` to create the source directory (e.g., `$HOME/data/jito-solana`) and `chown` it to the current user if it doesn't exist.
7.  **Validator Binary Name:** The script assumes the validator binary is named `agave-validator`. This can be changed via the `VALIDATOR_BINARY_NAME` variable.
8.  **Service Manager:** The script assumes an external service manager (like `systemd`) is configured to automatically restart the `agave-validator` process after it exits. The script only sends an `exit` command to the running validator.
9.  **Permissions:** The user running this script needs:
    * Sudo privileges for creating/owning source directories if they don't exist.
    * Permissions to run `git`, `cargo`, `rsync`, etc.
    * Write access to the `COMPILED_BASE_DIR`.
    * Permissions to execute the `agave-validator` binary.

## Configuration Variables

The following variables are defined at the top of the script and can be customized:

* `JITO_SOURCE_DIR`: Path to the Jito variant Git repository (default: `$HOME/data/jito-solana`).
* `JITO_REPO_URL`: Git URL for the Jito variant.
* `VANILLA_SOURCE_DIR`: Path to the vanilla Agave Git repository (default: `$HOME/data/agave`).
* `VANILLA_REPO_URL`: Git URL for the vanilla Agave client.
* `XANDEUM_SOURCE_DIR`: Path to the Xandeum-Agave Git repository (default: `$HOME/data/xandeum-agave`).
* `XANDEUM_REPO_URL`: Git URL for the Xandeum-Agave client.
* `COMPILED_BASE_DIR`: Base directory where compiled versions will be stored (default: `$HOME/data/compiled`).
* `ACTIVE_RELEASE_SYMLINK`: Path to the symbolic link that points to the `bin` directory of the active version (default: `${COMPILED_BASE_DIR}/active_release`).
* `LEDGER_DIR`: Path to the validator's ledger directory (default: `$HOME/ledger`).
* `BUILD_JOBS`: Default number of parallel jobs for `cargo build` (default: `2`). Can be overridden via command-line argument during upgrades.
* `VALIDATOR_BINARY_NAME`: Name of the validator executable (default: `agave-validator`).

## Usage

Make the script executable: `chmod +x start_upgrade-agave.sh`

### 1. Upgrade to a New Version

```bash
./start_upgrade-agave.sh <version_tag> [-j <number_of_jobs>]
