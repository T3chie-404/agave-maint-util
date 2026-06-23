# Build Error Fix - cargo-build-sbf Missing

## Problem Identified

When building Jito validator v3.0.6-jito.1, the build process was failing with:
```
cp: cannot stat 'target/release/cargo-build-sbf': No such file or directory
ERROR: Build failed using ./scripts/cargo-install-all.sh for ref v3.0.6-jito.1
```

However, the actual compilation **succeeded** - all validator binaries were built successfully in 2m 08s.

## Root Cause

The issue was in the Jito repository's `cargo-install-all.sh` script, which tries to copy `cargo-build-sbf` from `target/release/` but this binary is not built in certain Jito versions (or may have been removed/renamed).

The `start-upgrade.sh` script was treating ANY error from `cargo-install-all.sh` as fatal, even when:
- The compilation succeeded
- All essential binaries (like `agave-validator`) were built successfully
- Only auxiliary/optional tools were missing

## Solution Implemented

Modified `start-upgrade.sh` to be **resilient to non-critical build script failures**:

### Changes Made (lines 753-772):

**Before:**
```bash
if ! "${CARGO_INSTALL_ALL_SCRIPT}" .; then 
    echo -e "${RED}ERROR: Build failed using ${CARGO_INSTALL_ALL_SCRIPT} for ref ${target_ref}${NC}"
    exit 1
fi
```

**After:**
```bash
if ! "${CARGO_INSTALL_ALL_SCRIPT}" .; then 
    echo -e "${YELLOW}WARNING: ${CARGO_INSTALL_ALL_SCRIPT} returned an error. Checking if essential binaries were built...${NC}"
    
    # Check if agave-validator binary exists (the most critical binary)
    # Check in multiple possible locations
    if [ -f "./target/release/${VALIDATOR_BINARY_NAME}" ] || \
       [ -f "./bin/${VALIDATOR_BINARY_NAME}" ] || \
       [ -f "${CARGO_TARGET_DIR}/release/${VALIDATOR_BINARY_NAME}" ]; then
        echo -e "${GREEN}Essential validator binary found. Build appears successful despite script error.${NC}"
        echo -e "${YELLOW}Note: Some auxiliary tools like cargo-build-sbf may not have been built/copied.${NC}"
    else
        echo -e "${RED}ERROR: Essential validator binary (${VALIDATOR_BINARY_NAME}) not found after build.${NC}"
        echo -e "${RED}Checked locations: ./target/release/, ./bin/, ${CARGO_TARGET_DIR}/release/${NC}"
        echo -e "${RED}Build failed using ${CARGO_INSTALL_ALL_SCRIPT} for ref ${target_ref}${NC}"
        exit 1
    fi
fi
```

## How It Works

1. **Runs cargo-install-all.sh** as before
2. **If it fails**, instead of immediately exiting:
   - Checks if `agave-validator` binary exists in multiple locations:
     - `./target/release/` (standard location)
     - `./bin/` (where cargo-install-all.sh copies binaries)
     - `${CARGO_TARGET_DIR}/release/` (custom target directory if set)
   - If found in ANY location → **continues with warning** (build succeeded, only auxiliary tools missing)
   - If not found → **exits with error** (real build failure)

## Benefits

- **Resilient**: Handles upstream build script issues gracefully
- **Safe**: Still fails if critical binaries are missing
- **Informative**: Warns user about missing auxiliary tools
- **Backward Compatible**: Works with all existing versions

## Testing

To test this fix, try building v3.0.6-jito.1 again:
```bash
./start-upgrade.sh v3.0.6-jito.1
```

Expected behavior:
1. Build completes successfully
2. Warning about cargo-install-all.sh error
3. Message: "Essential validator binary found. Build appears successful despite script error."
4. Upgrade continues normally

## Documentation Updated

- Updated `README.md` to document this resilient behavior
- Added note about handling cases where auxiliary tools may not be built

## Related Issues

This fix addresses similar issues that may occur with:
- Missing `cargo-build-sbf`
- Missing `cargo-build-bpf` (older versions)
- Other auxiliary tools that aren't critical for validator operation
- Upstream build script changes in different Jito/Agave versions

## Additional Fixes

### Build Output Detection

The build script must choose a directory that actually contains the validator binary for the commit being built, not merely a directory that exists. Some client variants create a `${CARGO_TARGET_DIR}/release` directory while `cargo-install-all.sh` still populates `./bin`; other versions may build directly under the target directory.

**Current rule:** accept only directories containing `${VALIDATOR_BINARY_NAME}` when that binary's `--version` output includes the current `CI_COMMIT` source hash.

**Priority Order:**
1. `${SOURCE_DIR}/bin` - Freshly removed before each build, then populated by `cargo-install-all.sh`
2. `${CARGO_TARGET_DIR}/release` - Used when it contains the validator binary
3. `${SOURCE_DIR}/target/release` - Standard fallback when it contains the validator binary

This avoids deploying an empty or partial target directory and prevents stale binaries such as `agave-validator 2.1.6 (src:00000000...)` from being accepted for a newer requested ref.

### Runtime Artifact Validation

Some Agave/Jito releases can produce a valid `agave-validator` binary even when `cargo-install-all.sh` exits before copying runtime libraries. For example, a failed copy of an auxiliary binary can prevent `fetch-perf-libs.sh` from running, leaving the compiled release without `perf-libs/libpoh-simd.so`.

Before `active_release` can be updated, the script now validates the compiled release:

1. `${COMPILED_VERSION_BIN_DIR}/${VALIDATOR_BINARY_NAME}` exists and reports the expected source hash
2. On Linux x86_64, `${COMPILED_VERSION_BIN_DIR}/perf-libs/libpoh-simd.so` exists
3. If perf libs are missing, the script tries to copy them from build outputs or runs `${SOURCE_DIR}/fetch-perf-libs.sh`

If `libpoh-simd.so` is still missing after that, the upgrade fails before the symlink prompt.

### Cargo Clean and ./bin Directory Removal (lines 734-748)

Added two critical cleaning steps before each build:

1. **`cargo clean`** - Removes cached build artifacts from the Cargo cache
2. **`rm -rf ./bin`** - Removes the `./bin` directory where `cargo-install-all.sh` copies final binaries

**Why both are needed:**
- `cargo clean` only cleans build caches, not the final `./bin` output directory
- The `./bin` directory may contain stale binaries from previous builds
- Even when `cargo-install-all.sh` succeeds, it may not overwrite all existing binaries in `./bin`
- Removing `./bin` ensures `cargo-install-all.sh` creates fresh binaries, not a mix of old and new

This prevents the critical issue where version 3.0.6 binaries remained in `./bin` even after successfully building version 3.0.8.

## Files Modified

- `start-upgrade.sh` (lines 734-748, 760-784, 833-856)
- `README.md` (lines 155, 165)
- `BUILD_FIX_SUMMARY.md` (this file)

## Status

✅ **Fixed and ready for testing**

The build should now complete successfully for v3.0.6-jito.1 and other versions where auxiliary tools may be missing.

