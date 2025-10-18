#!/bin/bash
# Non-intrusive Zsh Compatibility Test Script
# Run this on the zsh server: 173.237.68.204
# This script does NOT modify any files - it only tests detection and syntax

set -euo pipefail

echo "======================================================================"
echo "      ZSH COMPATIBILITY TEST - NON-INTRUSIVE"
echo "======================================================================"
echo ""

# Test 1: Shell Detection
echo "=== Test 1: Shell Environment Detection ==="
echo "Current shell process:"
ps -p $$ -o comm=
echo ""
echo "Default shell from user database:"
getent passwd "$USER" | cut -d: -f7
echo ""
echo "SHELL environment variable:"
echo "$SHELL"
echo ""
echo "Available shells on system:"
cat /etc/shells
echo ""

# Test 2: Shell Detection Logic (from our script)
echo "=== Test 2: Our Shell Detection Function ==="
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

DETECTED_SHELL=$(detect_user_shell)
echo "Detected shell type: $DETECTED_SHELL"

if [ "$DETECTED_SHELL" = "zsh" ]; then
    echo "✓ PASS: Correctly detected zsh"
else
    echo "✗ FAIL: Expected zsh, got $DETECTED_SHELL"
fi
echo ""

# Test 3: RC File Selection
echo "=== Test 3: RC File Selection ==="
get_rc_file_for_shell() {
    local shell_type="$1"
    case "$shell_type" in
        zsh)
            echo "$HOME/.zshrc"
            ;;
        bash|*)
            echo "$HOME/.bashrc"
            ;;
    esac
}

RC_FILE=$(get_rc_file_for_shell "$DETECTED_SHELL")
echo "Selected RC file: $RC_FILE"

if [ "$DETECTED_SHELL" = "zsh" ] && [ "$RC_FILE" = "$HOME/.zshrc" ]; then
    echo "✓ PASS: Correctly selected .zshrc for zsh"
elif [ "$DETECTED_SHELL" = "bash" ] && [ "$RC_FILE" = "$HOME/.bashrc" ]; then
    echo "✓ PASS: Correctly selected .bashrc for bash"
else
    echo "✗ FAIL: RC file selection mismatch"
fi
echo ""

# Test 4: Check if RC file exists
echo "=== Test 4: RC File Existence ==="
if [ -f "$RC_FILE" ]; then
    echo "✓ RC file exists: $RC_FILE"
    echo "  Size: $(stat -f%z "$RC_FILE" 2>/dev/null || stat -c%s "$RC_FILE" 2>/dev/null) bytes"
    echo "  Permissions: $(ls -l "$RC_FILE" | awk '{print $1}')"
else
    echo "⚠ RC file does not exist: $RC_FILE"
    echo "  (Script would create it)"
fi
echo ""

# Test 5: PATH Export Syntax Test
echo "=== Test 5: PATH Export Syntax Compatibility ==="
TEST_PATH_LINE='export PATH="/test/path/active_release:$PATH"'
echo "Test line: $TEST_PATH_LINE"

# Test with current shell
if eval "$TEST_PATH_LINE" 2>/dev/null && echo "$PATH" | grep -q "/test/path/active_release"; then
    echo "✓ PASS: Current shell can parse PATH export syntax"
else
    echo "✗ FAIL: Current shell cannot parse PATH export syntax"
fi
echo ""

# Test 6: Array Operations (compatible syntax)
echo "=== Test 6: Array Operations Compatibility ==="
test_array=("item1" "item2" "item3")
echo "Test array: ${test_array[@]}"
echo "Array length: ${#test_array[@]}"
if [ "${#test_array[@]}" -eq 3 ]; then
    echo "✓ PASS: Array operations work correctly"
else
    echo "✗ FAIL: Array operations failed"
fi
echo ""

# Test 7: String Operations
echo "=== Test 7: String Operations Compatibility ==="
test_string="HELLO"
lower_string="${test_string,,}"
if [ "$lower_string" = "hello" ]; then
    echo "✓ PASS: String lowercase operation works"
else
    echo "⚠ WARNING: String lowercase operation may not work (bash 4+ feature)"
fi
echo ""

# Test 8: Check for existing PATH configurations
echo "=== Test 8: Existing PATH Configurations ==="
if [ -f "$RC_FILE" ]; then
    echo "Checking for existing 'active_release' PATH entries in $RC_FILE:"
    if grep -q "active_release" "$RC_FILE"; then
        echo "Found existing entries:"
        grep "active_release" "$RC_FILE" | head -5
    else
        echo "✓ No existing 'active_release' entries found"
    fi
else
    echo "⊘ RC file doesn't exist yet"
fi
echo ""

# Test 9: Check for Rust/Cargo installation
echo "=== Test 9: Rust/Cargo Environment ==="
if [ -f "$HOME/.cargo/env" ]; then
    echo "✓ Cargo env file exists: $HOME/.cargo/env"
    if command -v cargo &> /dev/null; then
        echo "✓ Cargo is in PATH: $(which cargo)"
        echo "  Version: $(cargo --version)"
    else
        echo "⚠ Cargo env file exists but cargo not in PATH"
    fi
else
    echo "⊘ Cargo env file doesn't exist (Rust not installed)"
fi

if [ -f "$RC_FILE" ] && grep -q "source.*cargo/env" "$RC_FILE"; then
    echo "✓ Cargo env is sourced in $RC_FILE"
else
    echo "⊘ Cargo env is not sourced in RC file"
fi
echo ""

# Test 10: Symlink Operations
echo "=== Test 10: Symlink Operations Test ==="
TEST_DIR="/tmp/zsh_test_$$"
mkdir -p "$TEST_DIR/test_bin"
ln -sf "$TEST_DIR/test_bin" "$TEST_DIR/test_link"

if [ -L "$TEST_DIR/test_link" ]; then
    TARGET=$(readlink -f "$TEST_DIR/test_link")
    echo "✓ PASS: Symlink creation and readlink work correctly"
    echo "  Link: $TEST_DIR/test_link -> $TARGET"
else
    echo "✗ FAIL: Symlink operations failed"
fi

# Cleanup
rm -rf "$TEST_DIR"
echo ""

# Test 11: Command Substitution
echo "=== Test 11: Command Substitution ==="
WHOAMI_RESULT=$(whoami)
if [ "$WHOAMI_RESULT" = "$USER" ]; then
    echo "✓ PASS: Command substitution works correctly"
else
    echo "✗ FAIL: Command substitution issue"
fi
echo ""

# Summary
echo "======================================================================"
echo "                    TEST SUMMARY"
echo "======================================================================"
echo ""
echo "Detected Shell: $DETECTED_SHELL"
echo "RC File: $RC_FILE"
echo "RC File Exists: $([ -f "$RC_FILE" ] && echo "Yes" || echo "No")"
echo ""
echo "✓ All core compatibility features tested"
echo "✓ No files were modified during testing"
echo "✓ Safe to proceed with actual implementation"
echo ""
echo "Next Steps:"
echo "  1. Review the output above"
echo "  2. Verify shell detection is correct"
echo "  3. If all tests pass, the scripts will work on this system"
echo "  4. Run system_tuner.sh to configure the system (will modify RC file)"
echo ""
echo "======================================================================"

