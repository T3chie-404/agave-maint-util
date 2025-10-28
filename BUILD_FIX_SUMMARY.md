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

### CARGO_TARGET_DIR Build Output Detection (lines 833-856)

When `CARGO_TARGET_DIR` is set to a custom directory (e.g., `/tmp/cargo-target-*`), the binaries are built there instead of `./target/release/`. 

**CRITICAL DISCOVERY:** Jito's `cargo-install-all.sh` script **does NOT respect CARGO_TARGET_DIR**. It's hardcoded to look for binaries in `./target/release/` and copy them to `./bin/`. When CARGO_TARGET_DIR is set:
- The actual build happens in `/tmp/cargo-target-*/release/` with the CORRECT version ✅
- But `cargo-install-all.sh` copies from `./target/release/` (which may have old binaries) to `./bin/` ❌
- This results in the wrong version being deployed even though the build succeeded!

**Solution:** ALWAYS prioritize CARGO_TARGET_DIR when it's set, regardless of whether cargo-install-all.sh succeeded:

**New Priority Order:**
1. `${CARGO_TARGET_DIR}/release` - If CARGO_TARGET_DIR is set (ALWAYS use this first) ✅
2. `${SOURCE_DIR}/bin` - If cargo-install-all.sh succeeded AND no CARGO_TARGET_DIR
3. `${SOURCE_DIR}/target/release` - Standard location fallback

This ensures the actual compiled binaries are used, not whatever cargo-install-all.sh copied from the wrong location.

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




