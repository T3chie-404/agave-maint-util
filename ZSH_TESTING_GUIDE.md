# Zsh Support Testing Guide

## Overview
This guide provides comprehensive testing procedures for validating bash and zsh compatibility in the agave-maint-util scripts.

## Prerequisites

### Test Environment Setup
1. A test Ubuntu/Linux system (VM or container recommended)
2. Ability to switch between bash and zsh shells
3. Sudo access for testing system modifications
4. Git access to clone the repository

### Installing Zsh (if not present)
```bash
sudo apt-get update
sudo apt-get install -y zsh
```

### Checking Current Shell
```bash
# Check default shell
echo $SHELL

# Check current shell process
ps -p $$ -o comm=

# List available shells
cat /etc/shells
```

### Changing Default Shell
```bash
# Change to zsh
chsh -s $(which zsh)

# Change to bash
chsh -s $(which bash)

# Note: Logout and login again for changes to take effect
```

## Test Scenarios

### Test 1: Shell Detection (Bash User)

**Setup:**
```bash
# Ensure user's default shell is bash
sudo chsh -s /bin/bash $(whoami)
# Logout and login
```

**Test Steps:**
1. Run `./system_tuning/system_tuner.sh`
2. Observe shell detection output

**Expected Results:**
```
--- Shell Detection ---
<timestamp> - Detected default shell: Bash
<timestamp> - Configuration file: /home/<user>/.bashrc
```

**Verification:**
```bash
# Check that .bashrc was modified
grep "active_release" ~/.bashrc
grep "source.*cargo/env" ~/.bashrc
```

### Test 2: Shell Detection (Zsh User)

**Setup:**
```bash
# Ensure user's default shell is zsh
sudo chsh -s /bin/zsh $(whoami)
# Logout and login
```

**Test Steps:**
1. Run `./system_tuning/system_tuner.sh`
2. Observe shell detection output

**Expected Results:**
```
--- Shell Detection ---
<timestamp> - Detected default shell: Zsh
<timestamp> - Configuration file: /home/<user>/.zshrc
```

**Verification:**
```bash
# Check that .zshrc was modified
grep "active_release" ~/.zshrc
grep "source.*cargo/env" ~/.zshrc

# Verify .bashrc was NOT modified (or has old config)
grep "active_release" ~/.bashrc || echo "Not found (correct)"
```

### Test 3: PATH Configuration (Bash)

**Setup:**
```bash
# Bash user, fresh .bashrc (backup first!)
cp ~/.bashrc ~/.bashrc.backup
```

**Test Steps:**
1. Run system_tuner.sh and confirm PATH configuration
2. Check if PATH line is added correctly

**Expected Results:**
```bash
# .bashrc should contain:
export PATH="/home/<user>/data/compiled/active_release:$PATH"
```

**Verification:**
```bash
# Source the file and verify
source ~/.bashrc
echo $PATH | grep "active_release"

# Start a new bash shell and verify
bash -c 'echo $PATH | grep active_release'
```

### Test 4: PATH Configuration (Zsh)

**Setup:**
```bash
# Zsh user, fresh .zshrc (backup first!)
cp ~/.zshrc ~/.zshrc.backup 2>/dev/null || touch ~/.zshrc
```

**Test Steps:**
1. Run system_tuner.sh and confirm PATH configuration
2. Check if PATH line is added correctly

**Expected Results:**
```bash
# .zshrc should contain:
export PATH="/home/<user>/data/compiled/active_release:$PATH"
```

**Verification:**
```bash
# Source the file and verify
source ~/.zshrc
echo $PATH | grep "active_release"

# Start a new zsh shell and verify
zsh -c 'echo $PATH | grep active_release'
```

### Test 5: Rust Installation (Bash)

**Setup:**
```bash
# Remove existing Rust installation (if in test environment)
# WARNING: Only do this in a test environment!
# rustup self uninstall
```

**Test Steps:**
1. Run system_tuner.sh as bash user
2. Confirm Rust installation when prompted
3. Check that cargo env is added to .bashrc

**Expected Results:**
```bash
# .bashrc should contain:
source "$HOME/.cargo/env"
```

**Verification:**
```bash
# Source and verify cargo is available
source ~/.bashrc
cargo --version
rustc --version

# Start new bash shell and verify
bash -c 'cargo --version'
```

### Test 6: Rust Installation (Zsh)

**Setup:**
```bash
# Remove existing Rust installation (if in test environment)
# WARNING: Only do this in a test environment!
# rustup self uninstall
```

**Test Steps:**
1. Run system_tuner.sh as zsh user
2. Confirm Rust installation when prompted
3. Check that cargo env is added to .zshrc

**Expected Results:**
```bash
# .zshrc should contain:
source "$HOME/.cargo/env"
```

**Verification:**
```bash
# Source and verify cargo is available
source ~/.zshrc
cargo --version
rustc --version

# Start new zsh shell and verify
zsh -c 'cargo --version'
```

### Test 7: start-upgrade.sh Shell-Aware Messages (Bash)

**Setup:**
```bash
# Bash user with compiled validator binary
```

**Test Steps:**
1. Run `./start-upgrade.sh rollback` (or any upgrade command)
2. If PATH verification fails, check the warning message

**Expected Results:**
```
WARNING: Command 'agave-validator' not found in system PATH when run from /home/<user>.
Ensure '<path>/active_release' is permanently in your system PATH (e.g., via /home/<user>/.bashrc and a new terminal session).
```

### Test 8: start-upgrade.sh Shell-Aware Messages (Zsh)

**Setup:**
```bash
# Zsh user with compiled validator binary
```

**Test Steps:**
1. Run `./start-upgrade.sh rollback` (or any upgrade command)
2. If PATH verification fails, check the warning message

**Expected Results:**
```
WARNING: Command 'agave-validator' not found in system PATH when run from /home/<user>.
Ensure '<path>/active_release' is permanently in your system PATH (e.g., via /home/<user>/.zshrc and a new terminal session).
```

### Test 9: RC File Creation (Zsh)

**Setup:**
```bash
# Zsh user with NO existing .zshrc
rm ~/.zshrc 2>/dev/null || true
```

**Test Steps:**
1. Run system_tuner.sh
2. Confirm PATH configuration

**Expected Results:**
- Script creates ~/.zshrc automatically
- PATH line is added successfully
- File permissions are correct (user-readable/writable)

**Verification:**
```bash
ls -la ~/.zshrc
cat ~/.zshrc
```

### Test 10: Mixed Environment (User switches shells)

**Setup:**
```bash
# Start as bash user with existing .bashrc config
# Switch to zsh
```

**Test Steps:**
1. Configure as bash user (run system_tuner.sh)
2. Change default shell to zsh
3. Run system_tuner.sh again

**Expected Results:**
- .bashrc has PATH configuration
- .zshrc gets PATH configuration when run as zsh user
- Both configurations coexist without conflict
- User can switch between shells seamlessly

**Verification:**
```bash
# Check both files
grep "active_release" ~/.bashrc
grep "active_release" ~/.zshrc

# Test both shells
bash -c 'echo $PATH | grep active_release'
zsh -c 'echo $PATH | grep active_release'
```

### Test 11: Duplicate Prevention

**Setup:**
```bash
# User with existing PATH configuration in RC file
```

**Test Steps:**
1. Run system_tuner.sh
2. Observe it detects existing configuration
3. Run system_tuner.sh again
4. Verify no duplicate entries added

**Expected Results:**
- First run: "Adding new PATH line..."
- Second run: "already actively configured in PATH"
- No duplicate entries in RC file

**Verification:**
```bash
# Count occurrences (should be 1)
grep -c "active_release" ~/.bashrc  # or ~/.zshrc
```

### Test 12: Old Path Detection

**Setup:**
```bash
# Manually add an old active_release path
echo 'export PATH="/old/path/active_release:$PATH"' >> ~/.bashrc
```

**Test Steps:**
1. Run system_tuner.sh
2. Observe warning about old PATH entries

**Expected Results:**
```
WARNING: Found OTHER existing ACTIVE line(s) in ~/.bashrc that appear to set an 'active_release' PATH...
```

**Verification:**
- Warning is displayed
- User is advised to manually review
- Both old and new paths exist (user must manually remove old one)

## Automated Test Script

You can create a test script to automate some checks:

```bash
#!/bin/bash
# test-shell-support.sh

echo "=== Shell Support Test Suite ==="
echo ""

# Test 1: Shell detection function
echo "Test 1: Shell Detection"
cd /home/ubuntu/agave-maint-util
source <(grep -A 20 "^detect_user_shell()" ./system_tuning/system_tuner.sh)
DETECTED=$(detect_user_shell)
echo "Detected shell: $DETECTED"
if [ -n "$DETECTED" ]; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi
echo ""

# Test 2: RC file determination
echo "Test 2: RC File Detection"
# Would need to source the functions
echo "(Manual verification required)"
echo ""

# Test 3: Check for sensitive data in scripts
echo "Test 3: Security Check - No Sensitive Data"
echo "Checking for potential secrets..."
SECRETS_FOUND=0

# Check for patterns that might be secrets
if grep -r "password\s*=\s*['\"]" . --exclude="*.md" --exclude-dir=".git" 2>/dev/null; then
    echo "⚠ Found potential password"
    SECRETS_FOUND=1
fi

if grep -r "api[_-]key\s*=\s*['\"]" . --exclude="*.md" --exclude-dir=".git" 2>/dev/null; then
    echo "⚠ Found potential API key"
    SECRETS_FOUND=1
fi

if [ $SECRETS_FOUND -eq 0 ]; then
    echo "✓ PASS - No obvious secrets found"
else
    echo "✗ FAIL - Potential secrets detected"
fi
echo ""

# Test 4: Verify both shells can parse the PATH export
echo "Test 4: PATH Export Syntax Compatibility"
TEST_LINE='export PATH="/test/path:$PATH"'
echo "$TEST_LINE" | bash -c 'source /dev/stdin && echo $PATH' | grep -q "/test/path"
if [ $? -eq 0 ]; then
    echo "✓ Bash can parse PATH export"
else
    echo "✗ Bash cannot parse PATH export"
fi

if command -v zsh &> /dev/null; then
    echo "$TEST_LINE" | zsh -c 'source /dev/stdin && echo $PATH' | grep -q "/test/path"
    if [ $? -eq 0 ]; then
        echo "✓ Zsh can parse PATH export"
    else
        echo "✗ Zsh cannot parse PATH export"
    fi
else
    echo "⊘ Zsh not installed, skipping"
fi
echo ""

echo "=== Test Suite Complete ==="
```

## Manual Checklist

Use this checklist when performing manual testing:

- [ ] Shell detection works for bash users
- [ ] Shell detection works for zsh users
- [ ] .bashrc is updated correctly for bash users
- [ ] .zshrc is updated correctly for zsh users
- [ ] .zshrc is created if it doesn't exist
- [ ] Duplicate PATH entries are prevented
- [ ] Old PATH entries trigger warnings
- [ ] Rust installation adds to correct RC file (bash)
- [ ] Rust installation adds to correct RC file (zsh)
- [ ] start-upgrade.sh shows correct RC file in warnings (bash)
- [ ] start-upgrade.sh shows correct RC file in warnings (zsh)
- [ ] No hardcoded references to .bashrc remain
- [ ] Comments mention both shell types
- [ ] User can switch between shells without issues
- [ ] PATH works correctly after sourcing RC file
- [ ] PATH works correctly in new terminal session
- [ ] No sensitive data exposed in any script

## Common Issues and Troubleshooting

### Issue: Shell detection returns "bash" for zsh user
**Cause:** User may have zsh installed but bash set as default shell
**Solution:** Verify with `grep "^$USER:" /etc/passwd | cut -d: -f7`

### Issue: PATH not working in new terminal
**Cause:** RC file not being sourced
**Solution:** 
- For bash: Ensure .bash_profile sources .bashrc
- For zsh: .zshrc is sourced by default for interactive shells

### Issue: Cargo not found after installation
**Cause:** RC file not sourced, or cargo env not added
**Solution:**
- Manually source: `source ~/.cargo/env`
- Verify RC file contains cargo env line
- Open new terminal

### Issue: Duplicate PATH entries
**Cause:** Script run multiple times or manual modifications
**Solution:**
- Edit RC file and remove duplicates
- Script should prevent this with duplicate detection

## Performance Testing

### Test: Script execution time
Compare execution time between bash and zsh detection:

```bash
time ./system_tuning/system_tuner.sh # (exit immediately after shell detection)
```

Should be nearly identical (<0.1s difference).

### Test: Shell startup time
Measure impact of PATH modifications:

```bash
# Before modifications
time bash -c 'exit'
time zsh -c 'exit'

# After modifications  
time bash -c 'exit'
time zsh -c 'exit'
```

Should have negligible impact (<0.01s).

## Integration Testing

### End-to-End Test: Full Validator Setup

1. **Fresh User Setup (Bash)**
   - Create test user with bash as default shell
   - Run system_tuner.sh
   - Verify all configurations
   - Run start-upgrade.sh with test tag
   - Verify validator binary in PATH

2. **Fresh User Setup (Zsh)**
   - Create test user with zsh as default shell
   - Run system_tuner.sh
   - Verify all configurations
   - Run start-upgrade.sh with test tag
   - Verify validator binary in PATH

3. **Migration Test**
   - User with existing bash setup
   - Switch to zsh
   - Run system_tuner.sh
   - Verify both configs work
   - Test switching between shells

## Reporting Issues

When reporting issues, please include:
1. Output of `echo $SHELL`
2. Output of `ps -p $$ -o comm=`
3. Content of shell detection section from script output
4. Relevant RC file contents
5. OS and version info (`uname -a`)

## Success Criteria

All tests pass when:
- ✅ Shell detection works accurately
- ✅ Correct RC files are modified
- ✅ PATH modifications are persistent
- ✅ Rust environment works in both shells
- ✅ No duplicate entries created
- ✅ No regressions in bash functionality
- ✅ Zsh users have same experience as bash users
- ✅ No sensitive data exposed
- ✅ All documentation is accurate

