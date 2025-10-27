# Agave Validator Upgrade, Rollback, Clean and List Script (`start-upgrade.sh`)

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
* **List Tags/Branches Mode:**
    * `--list-tags <variant>`: Fetches and lists available Git tags for the specified variant (agave, jito, xandeum), sorted newest first. Shows top 20.
    * `--list-branches <variant>`: Fetches and lists available Git branches for the specified variant, sorted by most recent commit first. Shows top 20.
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
* **Version-Aware Exit Command:**
    * Automatically detects validator version capabilities by checking exit command help output.
    * Dynamically includes `--no-wait-for-exit` flag only when supported by the validator version.
    * Regenerates `~/exit-validator.sh` convenience script after each upgrade with correct syntax.
    * Ensures backward compatibility with older validator versions.
* **Colored Output:** Uses colors for better readability of messages.
* **Error Handling:** Includes `set -euo pipefail` for robust error handling.

## Shell Compatibility

**These scripts support both Bash and Zsh shells!**

* The scripts execute in Bash (`#!/bin/bash` shebang)
* Shell detection automatically identifies your default shell (bash or zsh)
* PATH configurations are written to the appropriate RC file:
  * Bash users: `~/.bashrc`
  * Zsh users: `~/.zshrc`
* All PATH operations, symlinks, and environment setups work identically in both shells
* Seamlessly switch between shells without reconfiguration

See `ZSH_SUPPORT_ANALYSIS.md` and `ZSH_TESTING_GUIDE.md` for detailed compatibility information and testing procedures.

## Prerequisites

1.  **Shell:** The scripts are written for Bash but support both Bash and Zsh user environments.
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

Make the script executable: `chmod +x start-upgrade.sh`

### 1. Upgrade to a New Version

```
./start-upgrade.sh <version_tag> [-j <number_of_jobs>]`
```

* `<version_tag>`: The Git tag of the version you want to build and install.
    * If the tag ends with `-jito` (e.g., `v2.2.14-jito`), the script will build from `JITO_SOURCE_DIR`.
    * If the tag starts with `x` (e.g., `x2.2.0-munich`) and does not end with `-jito`, it will prompt to confirm building the Xandeum-Agave client from `XANDEUM_SOURCE_DIR`.
    * For other tags (not ending in `-jito`, not starting with `x`), it will prompt to confirm building the vanilla Agave client from `VANILLA_SOURCE_DIR`.
* `-j <number_of_jobs>` (Optional): Specifies the number of parallel jobs for `cargo build` by setting the `CARGO_BUILD_JOBS` environment variable.

**Examples:**
```
./start-upgrade.sh v2.2.14-jito
./start-upgrade.sh v2.2.14-jito -j 32
./start-upgrade.sh x2.2.0-munich # Will prompt for Xandeum confirmation
./start-upgrade.sh v1.10.0      # Will prompt for Vanilla Agave confirmation
```

### 2. List Available Tags or Branches

```
./start-upgrade-agave.sh --list-tags <variant>
./start-upgrade-agave.sh --list-branches <variant>
```
* `<variant>`: Can be `agave`, `jito`, or `xandeum`.
* This will fetch the latest information from the remote repository and list the newest ~20 tags (sorted by version) or branches (sorted by last commit date).

### 3. Rollback to a Previously Compiled Version

```
./start-upgrade.sh rollback
```
This command will:
1.  List previously compiled versions.
2.  Prompt for selection via a numbered menu.
3.  Update the `active_release` symlink.
4.  Prompt before initiating a validator restart.

### 4. Clean Old Compiled Versions

```
./start-upgrade.sh clean
```
This command will:
1.  List deletable compiled versions with numbers (active version is excluded).
2.  Prompt for selection of multiple versions by number.
3.  Show estimated space to be freed and ask for final confirmation.
4.  Permanently delete selected version directories.

## Script Workflow (Simplified)

* **Upgrade:** Parses args, selects source repo (with prompts if ambiguous), clones if needed (using `sudo mkdir/chown` for the source directory if it doesn't exist, then `git clone` as user), fetches, checks out tag, updates submodules, runs `cargo clean` to remove cached artifacts, builds (preferring `./scripts/cargo-install-all.sh .` with `CI_COMMIT` and `CARGO_BUILD_JOBS` set), copies binaries, updates symlink, verifies, prompts for restart.
* **Rollback:** Lists versions, prompts for selection, updates symlink, verifies, prompts for restart.
* **Clean:** Lists deletable versions, prompts for numbered selection, confirms, deletes.

## Important Notes

* **Run as Correct User:** Ensure this script is run by the user intended to own the source code and compiled binaries (e.g., `solval`). This user will also need `sudo` privileges for creating the source directory if it doesn't exist.
* **PATH Variable:** For convenient command-line use of `agave-validator` and for the secondary verification test to pass naturally, ensure `${ACTIVE_RELEASE_SYMLINK}` (e.g., `$HOME/data/compiled/active_release`) is added to the system `PATH` (e.g., via `~/.bashrc` or `~/.zshrc`, typically handled by the system tuning script which automatically detects your shell).
* **Backup:** The script backs up the `active_release` symlink. The `clean` command permanently deletes version directories.
* **Error Handling:** Uses `set -euo pipefail`.
* **Fresh Builds:** The script runs `cargo clean` before each build to remove cached artifacts and ensure a clean compilation. This prevents issues where cached artifacts from previous versions could be reused, ensuring each build truly reflects the checked-out version.
* **`./scripts/cargo-install-all.sh`:** This script is preferred for building to ensure all components and version information are correctly compiled. If the script returns an error but essential binaries (like `agave-validator`) were successfully built, the upgrade will continue with a warning. This handles cases where auxiliary tools like `cargo-build-sbf` may not be built in certain versions. A fallback to `cargo build --release` is provided with a warning if the script is not found.
* **Irreversible Deletion:** The `clean` command uses `rm -rf`. Double-check selections before confirming deletion as this action is permanent.
EOF
