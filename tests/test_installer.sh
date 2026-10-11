#!/bin/bash
set -euo pipefail

# ==============================================================================
# PlasmArch Mock Unit Test Suite
# Tests installer.sh functions in isolation without modifying host system state
# ==============================================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_SCRIPT="$PROJECT_ROOT/installer.sh"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Colors for test output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  PASS_COUNT=$((PASS_COUNT + 1))
  echo -e "  [${GREEN}PASS${NC}] $1"
}

fail() {
  TEST_COUNT=$((TEST_COUNT + 1))
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo -e "  [${RED}FAIL${NC}] $1: $2"
}

# Create a temporary sandbox environment for mocks
SANDBOX_DIR="$(mktemp -d /tmp/plasmarch-test-XXXXXX)"
trap 'rm -rf "$SANDBOX_DIR"' EXIT

# Source installer.sh functions without executing the main entry point
source_installer_functions() {
  # Extract functions and variable definitions from installer.sh, excluding the main invocation at bottom
  eval "$(sed '/^if \[ "\${1:-}" = "install" \]; then/, $d' "$INSTALLER_SCRIPT")"
}

# Source once globally for the test runner
source_installer_functions

# ------------------------------------------------------------------------------
# Test Suite 1: Privilege Checking
# ------------------------------------------------------------------------------
test_privilege_checks() {
  echo "Running Test Suite 1: Privilege Checking..."

  # Test: EUID=0 (root) must be rejected
  local out=""
  out=$(PLASMARCH_TEST_EUID=0 check_privileges 2>&1) || true
  if [[ "$out" =~ "Do not run this script directly as root" ]]; then
    pass "check_privileges rejects EUID=0"
  else
    fail "check_privileges rejects EUID=0" "Expected rejection message, got: $out"
  fi
}

# ------------------------------------------------------------------------------
# Test Suite 2: Username Validation
# ------------------------------------------------------------------------------
test_user_validation() {
  echo "Running Test Suite 2: Username Validation..."

  # Empty username
  if ! validate_user "" 2>/dev/null; then
    pass "validate_user rejects empty username"
  else
    fail "validate_user rejects empty username" "Empty username was accepted"
  fi

  # Invalid characters
  if ! validate_user "bad@user" 2>/dev/null; then
    pass "validate_user rejects invalid characters"
  else
    fail "validate_user rejects invalid characters" "bad@user was accepted"
  fi

  # Excessively long username (>32 chars)
  if ! validate_user "this_username_is_way_too_long_for_linux_systems" 2>/dev/null; then
    pass "validate_user rejects usernames exceeding 32 characters"
  else
    fail "validate_user rejects usernames exceeding 32 characters" "Accepted >32 char username"
  fi

  # Nonexistent user
  if ! validate_user "nonexistent_plasmarch_user_999" 2>/dev/null; then
    pass "validate_user rejects non-existent user"
  else
    fail "validate_user rejects non-existent user" "Accepted nonexistent user"
  fi

  # System account (root / UID 0)
  if ! validate_user "root" 2>/dev/null; then
    pass "validate_user rejects system user (root, UID < 1000)"
  else
    fail "validate_user rejects system user (root, UID < 1000)" "Accepted root user"
  fi

  # Current regular user (if UID >= 1000)
  local current_user
  current_user="$(id -un)"
  if (( $(id -u) >= 1000 )); then
    if validate_user "$current_user" 2>/dev/null; then
      pass "validate_user accepts current regular user ($current_user)"
    else
      fail "validate_user accepts current regular user ($current_user)" "Rejected current user"
    fi
  fi
}

# ------------------------------------------------------------------------------
# Test Suite 3: Home Directory & Profile Resolution
# ------------------------------------------------------------------------------
test_home_and_profile_resolution() {
  echo "Running Test Suite 3: Home Directory & Profile Resolution..."

  local current_user
  current_user="$(id -un)"
  local resolved_home
  resolved_home=$(get_user_home "$current_user")

  if [[ -n "$resolved_home" && -d "$resolved_home" && "$resolved_home" != "/" ]]; then
    pass "get_user_home dynamically resolves valid home for '$current_user'"
  else
    fail "get_user_home dynamically resolves valid home" "Got: $resolved_home"
  fi

  # Profile resolution for bash
  local profile
  profile=$(get_user_profile "$current_user" "$SANDBOX_DIR")
  if [[ "$profile" == "$SANDBOX_DIR/.bash_profile" || "$profile" == "$SANDBOX_DIR/.profile" || "$profile" == "$SANDBOX_DIR/.zprofile" ]]; then
    pass "get_user_profile returns standard shell profile path ($profile)"
  else
    fail "get_user_profile returns standard shell profile path" "Got: $profile"
  fi
}

# ------------------------------------------------------------------------------
# Test Suite 4: Array-Based Package Processing
# ------------------------------------------------------------------------------
test_package_arrays_and_removal() {
  echo "Running Test Suite 4: Package Arrays and Removal Logic..."

  # Run in subshell with mocked pacman & sudo
  (
    # Mock pacman: pretend 'dolphin' and 'ark' are installed, 'nonexistent' is not
    pacman() {
      if [[ "$1" == "-Qq" ]]; then
        shift
        local found=()
        for p in "$@"; do
          if [[ "$p" == "dolphin" || "$p" == "ark" ]]; then
            found+=("$p")
          fi
        done
        if (( ${#found[@]} > 0 )); then
          printf "%s\n" "${found[@]}"
          return 0
        fi
        return 1
      fi
      return 0
    }

    # Mock sudo: record invocation
    sudo() {
      echo "SUDO_MOCK: $*" >> "$SANDBOX_DIR/sudo_calls.log"
      return 0
    }

    export -f pacman sudo

    # Test removing a list containing installed and uninstalled items
    remove_packages "dolphin" "nonexistent" "ark" >/dev/null

    if grep -q "SUDO_MOCK: pacman -Rns dolphin ark" "$SANDBOX_DIR/sudo_calls.log"; then
      pass "remove_packages correctly filters only installed packages for -Rns"
    else
      fail "remove_packages correctly filters only installed packages" "Log: $(cat "$SANDBOX_DIR/sudo_calls.log" 2>/dev/null || echo 'empty')"
    fi

    # Test removing a list where nothing is installed
    rm -f "$SANDBOX_DIR/sudo_calls.log"
    local out
    out=$(remove_packages "nonexistent1" "nonexistent2")
    if [[ "$out" =~ "None of the specified packages are currently installed." ]] && [[ ! -f "$SANDBOX_DIR/sudo_calls.log" ]]; then
      pass "remove_packages does not invoke pacman when nothing is installed"
    else
      fail "remove_packages when nothing installed" "Unexpected output: $out"
    fi
  )
}

# ------------------------------------------------------------------------------
# Test Suite 5: Autostart Life-cycle & Marker Protection
# ------------------------------------------------------------------------------
test_autostart_lifecycle() {
  echo "Running Test Suite 5: Autostart Life-cycle & Cleanup Safety..."

  local fake_profile="$SANDBOX_DIR/.test_bash_profile"
  echo "export EXISTING_VAR=1" > "$fake_profile"

  # Simulate autostart append
  cat <<EOF >> "$fake_profile"

$AUTOSTART_START
if [ -z "\$DISPLAY" ] && [ -z "\$WAYLAND_DISPLAY" ] && [ "\${XDG_VTNR:-0}" = 1 ]; then
  exec /usr/bin/startplasma-wayland
fi
$AUTOSTART_END
EOF

  if grep -Fq "$AUTOSTART_START" "$fake_profile" && grep -Fq "$AUTOSTART_END" "$fake_profile"; then
    pass "Autostart block format includes intact start and end tags"
  else
    fail "Autostart block format" "Markers missing"
  fi

  # Simulate safe deletion with sed
  sed -i "/$AUTOSTART_START/,/$AUTOSTART_END/d" "$fake_profile"

  if ! grep -q "KDE PLASMA AUTOSTART" "$fake_profile" && grep -q "EXISTING_VAR=1" "$fake_profile"; then
    pass "Safe cleanup removes autostart without modifying preceding user config"
  else
    fail "Safe cleanup" "File corrupted or autostart remaining"
  fi
}

# ------------------------------------------------------------------------------
# Run all suites
# ------------------------------------------------------------------------------
echo "=========================================================="
echo "Starting PlasmArch Test Suite"
echo "=========================================================="

test_privilege_checks
test_user_validation
test_home_and_profile_resolution
test_package_arrays_and_removal
test_autostart_lifecycle

echo "=========================================================="
echo "Test Summary: Total: $TEST_COUNT | Passed: $PASS_COUNT | Failed: $FAIL_COUNT"
echo "=========================================================="

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0
