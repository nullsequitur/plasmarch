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

  # Profile resolution for bash / zsh
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
# Test Suite 6: TUI Checklist Engine (CLI Fallback & Toggling)
# ------------------------------------------------------------------------------
test_tui_checklist() {
  echo "Running Test Suite 6: TUI Checklist Engine (Pure-Bash Fallback)..."

  # Test default confirmation (all pre-selected items confirmed by pressing Enter)
  local res1
  res1=$(printf "\n" | prompt_checklist_cli "Test Menu" "dolphin" "File Manager" "ON" "firefox" "Web Browser" "ON" "ark" "Archiver" "ON")
  if [[ "$res1" == "dolphin firefox ark" ]]; then
    pass "prompt_checklist_cli confirms all default ON items on Enter"
  else
    fail "prompt_checklist_cli default confirm" "Expected 'dolphin firefox ark', got: '$res1'"
  fi

  # Test toggling item 2 (firefox) to OFF, then confirming
  local res2
  res2=$(printf "2\n\n" | prompt_checklist_cli "Test Menu" "dolphin" "File Manager" "ON" "firefox" "Web Browser" "ON" "ark" "Archiver" "ON")
  if [[ "$res2" == "dolphin ark" ]]; then
    pass "prompt_checklist_cli toggles item 2 from ON to OFF"
  else
    fail "prompt_checklist_cli toggle item 2" "Expected 'dolphin ark', got: '$res2'"
  fi

  # Test selecting 'n' (none)
  local res3
  res3=$(printf "n\n\n" | prompt_checklist_cli "Test Menu" "dolphin" "File Manager" "ON" "firefox" "Web Browser" "ON")
  if [[ -z "$res3" ]]; then
    pass "prompt_checklist_cli selecting 'n' clears all items"
  else
    fail "prompt_checklist_cli selecting 'n'" "Expected empty string, got: '$res3'"
  fi

  # Test multi-selection with spaces and commas (e.g. '1, 3')
  local res4
  res4=$(printf "1, 3\n\n" | prompt_checklist_cli "Test Menu" "dolphin" "File Manager" "OFF" "firefox" "Web Browser" "OFF" "ark" "Archiver" "OFF")
  if [[ "$res4" == "dolphin ark" ]]; then
    pass "prompt_checklist_cli supports comma and space separated toggles ('1, 3')"
  else
    fail "prompt_checklist_cli comma/space toggle" "Expected 'dolphin ark', got: '$res4'"
  fi
}

# ------------------------------------------------------------------------------
# Test Suite 7: Categorized Installation & Pre-Installed Host Detection
# ------------------------------------------------------------------------------
test_categorized_install_workflow() {
  echo "Running Test Suite 7: Categorized Installation Workflow..."

  (
    # Mock pacman: pretend 'firefox' is ALREADY installed on the host, but 'dolphin' is not
    pacman() {
      if [[ "$1" == "-Qq" ]]; then
        shift
        local found=()
        for p in "$@"; do
          if [[ "$p" == "firefox" ]]; then
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

    sudo() {
      echo "SUDO_INSTALL: $*" >> "$SANDBOX_DIR/install_sudo.log"
      return 0
    }

    export -f pacman sudo
    export PLASMARCH_FORCE_CLI_MENU=1

    # Simulate user input to install_tier:
    # 1. Target user prompt: Enter (skip user config)
    # 2. Checklist prompt: Enter (accept defaults: dolphin, konsole, firefox, ark, gwenview)
    printf "\n\n" | install_tier > "$SANDBOX_DIR/install_run.log" 2>&1 || true

    # Verify: pacman -S --needed was invoked
    if grep -q "SUDO_INSTALL: pacman -S --needed" "$SANDBOX_DIR/install_sudo.log"; then
      pass "install_tier executes pacman -S --needed"
    else
      fail "install_tier pacman invocation" "Log: $(cat "$SANDBOX_DIR/install_sudo.log" 2>/dev/null || echo 'empty')"
    fi

    # Verify: Layer 1 (plasma-desktop) is present
    if grep -q "plasma-desktop" "$SANDBOX_DIR/install_sudo.log"; then
      pass "install_tier includes Layer 1 core plasma packages"
    else
      fail "install_tier core plasma" "Missing plasma-desktop in install queue"
    fi

    # Verify: Default selected Layer 2 apps (dolphin, konsole, firefox, ark, gwenview) are in queue
    local install_cmd
    install_cmd=$(cat "$SANDBOX_DIR/install_sudo.log")
    if [[ "$install_cmd" =~ "dolphin" ]] && [[ "$install_cmd" =~ "konsole" ]] && [[ "$install_cmd" =~ "firefox" ]] && [[ "$install_cmd" =~ "ark" ]] && [[ "$install_cmd" =~ "gwenview" ]]; then
      pass "install_tier includes default ON applications from catalog"
    else
      fail "install_tier default apps" "Missing default apps in: $install_cmd"
    fi

    # Verify: Default OFF applications (chromium, okular, kate) are NOT installed by default
    if [[ ! "$install_cmd" =~ "chromium" ]] && [[ ! "$install_cmd" =~ "okular" ]] && [[ ! "$install_cmd" =~ "kate" ]]; then
      pass "install_tier excludes default OFF applications (chromium, okular, kate)"
    else
      fail "install_tier default OFF apps" "Found unexpected apps in: $install_cmd"
    fi

    # Verify: Layer 3 daemons (networkmanager, bluez) are in queue
    if [[ "$install_cmd" =~ "networkmanager" ]] && [[ "$install_cmd" =~ "bluez" ]]; then
      pass "install_tier includes Layer 3 system daemons"
    else
      fail "install_tier system daemons" "Missing networkmanager or bluez in: $install_cmd"
    fi

    # Verify: Host pre-installed package (firefox) was detected and tagged in menu output
    if grep -q "firefox.*(installed)" "$SANDBOX_DIR/install_run.log"; then
      pass "install_tier detects host-installed firefox and tags it as '(installed)'"
    else
      fail "install_tier host detection" "Expected '(installed)' tag for firefox in log"
    fi
  )
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
test_tui_checklist
test_categorized_install_workflow

echo "=========================================================="
echo "Test Summary: Total: $TEST_COUNT | Passed: $PASS_COUNT | Failed: $FAIL_COUNT"
echo "=========================================================="

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0
