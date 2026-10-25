#!/bin/bash
set -euo pipefail

# ==============================================================================
# PlasmArch Mock Unit Test Suite
# Tests installer.sh functions in isolation without modifying host system state
# ==============================================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_SCRIPT="$PROJECT_ROOT/installer.sh"
export PLASMARCH_SCRIPT_DIR="$PROJECT_ROOT"

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Colors for test output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() {
  echo "PASS" >> "$SANDBOX_DIR/test_results.log"
  echo -e "  [${GREEN}PASS${NC}] $1"
}

fail() {
  echo "FAIL" >> "$SANDBOX_DIR/test_results.log"
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
# Test Suite 7: Selective Layer 2 Removal (The Dolphin vs. Firefox Test)
# ------------------------------------------------------------------------------
test_selective_layer2_removal() {
  echo "Running Test Suite 7: Selective Removal (Dolphin removed, Firefox preserved)..."

  (
    # Mock environment:
    # Packages installed: plasma-desktop (Layer 1), dolphin, konsole, firefox (Layer 2), networkmanager (Layer 3)
    pacman() {
      if [[ "$1" == "-Qq" ]]; then
        shift
        local found=()
        for p in "$@"; do
          if [[ "$p" == "plasma-desktop" || "$p" == "dolphin" || "$p" == "konsole" || "$p" == "firefox" || "$p" == "networkmanager" ]]; then
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
      echo "SUDO_CALL: $*" >> "$SANDBOX_DIR/selective_sudo.log"
      return 0
    }

    export -f pacman sudo
    export PLASMARCH_FORCE_CLI_MENU=1

    # Simulate user input to remove_tier:
    # 1. Target user prompt: Enter (leave blank to skip user configs)
    # 2. Checklist prompt: '3' then Enter (uncheck item 3: firefox), then Enter to confirm removal
    # (Installed Layer 2 items in order: dolphin [1], konsole [2], firefox [3])
    printf "\n3\n\n" | remove_tier > "$SANDBOX_DIR/remove_run.log" 2>&1 || true

    # Verify: Layer 1 (plasma-desktop) was removed
    if grep -q "SUDO_CALL: pacman -Rns plasma-desktop" "$SANDBOX_DIR/selective_sudo.log"; then
      pass "remove_tier automatically removed Layer 1 (plasma-desktop)"
    else
      fail "remove_tier Layer 1 removal" "plasma-desktop not in log"
    fi

    # Verify: Layer 2 removed dolphin and konsole, but DID NOT remove firefox
    if grep -q "SUDO_CALL: pacman -Rns dolphin konsole" "$SANDBOX_DIR/selective_sudo.log"; then
      pass "remove_tier removed selected GUI apps (dolphin, konsole)"
    else
      fail "remove_tier Layer 2 removal" "Expected 'pacman -Rns dolphin konsole' in: $(cat "$SANDBOX_DIR/selective_sudo.log" 2>/dev/null)"
    fi

    # Verify: firefox was NEVER passed to pacman -Rns
    if ! grep -q "pacman -Rns.*firefox" "$SANDBOX_DIR/selective_sudo.log"; then
      pass "remove_tier STRICTLY PRESERVED firefox (not passed to pacman -Rns)"
    else
      fail "remove_tier firefox preservation" "firefox was unexpectedly found in pacman -Rns call!"
    fi

    # Verify: Layer 3 (networkmanager) was NEVER passed to pacman -Rns
    if ! grep -q "pacman -Rns.*networkmanager" "$SANDBOX_DIR/selective_sudo.log"; then
      pass "remove_tier STRICTLY PRESERVED Layer 3 daemons (networkmanager not removed)"
    else
      fail "remove_tier daemon preservation" "networkmanager was passed to pacman -Rns!"
    fi
  )
}

# ------------------------------------------------------------------------------
# Test Suite 8: Categorized Installation & Pre-Installed Host Detection
# ------------------------------------------------------------------------------
test_categorized_install_workflow() {
  echo "Running Test Suite 8: Categorized Installation Workflow..."

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
# Test Suite 9: Curated User Configuration Preset Seeding
# ------------------------------------------------------------------------------
test_user_presets() {
  echo "Running Test Suite 9: Curated User Configuration Preset Seeding..."

  (
    local fake_home="$SANDBOX_DIR/fake_user_home"
    mkdir -p "$fake_home"

    sudo() {
      echo "SUDO_CALL: $*" >> "$SANDBOX_DIR/preset_sudo.log"
      if [[ "$1" == "chown" || "$1" == "-v" ]]; then
        return 0
      fi
      "$@"
    }
    export -f sudo

    # 1. Test missing preset directory handling
    local err_out
    if err_out=$(apply_user_preset "testuser" "$fake_home" "$SANDBOX_DIR/nonexistent_preset" 2>&1); then
      fail "apply_user_preset nonexistent" "Expected error return code when preset dir is missing"
    else
      pass "apply_user_preset gracefully fails when preset directory is missing"
    fi

    # 2. Test successful preset deployment using actual presets/curated directory
    rm -f "$SANDBOX_DIR/preset_sudo.log"
    apply_user_preset "testuser" "$fake_home" >/dev/null

    local cfg_dir="$fake_home/.config"
    if [[ -f "$cfg_dir/kdeglobals" ]] && grep -q "ColorScheme=BreezeDark" "$cfg_dir/kdeglobals"; then
      pass "apply_user_preset provisions BreezeDark in kdeglobals"
    else
      fail "apply_user_preset kdeglobals" "Missing or invalid kdeglobals"
    fi

    if [[ -f "$cfg_dir/plasmarc" ]] && grep -q "name=breeze-dark" "$cfg_dir/plasmarc"; then
      pass "apply_user_preset provisions breeze-dark in plasmarc"
    else
      fail "apply_user_preset plasmarc" "Missing or invalid plasmarc"
    fi

    if [[ -f "$cfg_dir/dolphinrc" ]] && grep -q "PreviewSettings" "$cfg_dir/dolphinrc"; then
      pass "apply_user_preset provisions enhanced preview settings in dolphinrc"
    else
      fail "apply_user_preset dolphinrc" "Missing or invalid dolphinrc"
    fi

    local appletsrc="$cfg_dir/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -f "$appletsrc" ]] && grep -q "launchers=applications:org.kde.konsole.desktop,applications:org.kde.dolphin.desktop,applications:firefox.desktop" "$appletsrc"; then
      pass "apply_user_preset pins taskbar apps (konsole, dolphin, firefox) in exact sequential order"
    else
      fail "apply_user_preset appletsrc" "Launchers order incorrect or file missing in $appletsrc"
    fi

    if grep -q "chown -R testuser:testuser" "$SANDBOX_DIR/preset_sudo.log"; then
      pass "apply_user_preset enforces ownership on target user config directory"
    else
      fail "apply_user_preset ownership" "Expected chown -R in: $(cat "$SANDBOX_DIR/preset_sudo.log" 2>/dev/null || echo 'empty')"
    fi

    # 3. Test install_tier integrates preset application when user accepts
    local fake_target_home="$SANDBOX_DIR/fake_target_user_home"
    mkdir -p "$fake_target_home"
    get_user_home() { echo "$fake_target_home"; }
    validate_user() { return 0; }
    get_user_profile() { echo "$fake_target_home/.bash_profile"; }
    pacman() { return 0; }
    export -f get_user_home validate_user get_user_profile pacman

    # Inputs:
    # 1. target user: "myuser"
    # 2. TTY autostart: "N"
    # 3. Presets: "Y"
    # 4. Checklist: Enter
    printf "myuser\nN\nY\n\n" | install_tier > "$SANDBOX_DIR/install_preset_run.log" 2>&1 || true

    if [[ -f "$fake_target_home/.config/kdeglobals" ]] && grep -q "ColorScheme=BreezeDark" "$fake_target_home/.config/kdeglobals"; then
      pass "install_tier successfully triggers apply_user_preset during target user setup"
    else
      fail "install_tier preset trigger" "Presets were not deployed during install_tier run. Log: $(cat "$SANDBOX_DIR/install_preset_run.log" 2>/dev/null || echo 'empty')"
    fi
  )
}

# ------------------------------------------------------------------------------
# Test Suite 10: Dynamic Preset Catalog & Discovery Engine
# ------------------------------------------------------------------------------
test_dynamic_preset_catalog() {
  echo "Running Test Suite 10: Dynamic Preset Catalog & Discovery Engine..."

  (
    sudo() {
      echo "SUDO_CALL: $*" >> "$SANDBOX_DIR/dyn_preset_sudo.log"
      if [[ "$1" == "chown" || "$1" == "-v" ]]; then
        return 0
      fi
      "$@"
    }
    export -f sudo

    # 1. Test list_presets output for built-in system presets
    local list_out
    list_out=$(list_presets)
    if [[ "$list_out" =~ "curated" ]] && [[ "$list_out" =~ "minimal" ]]; then
      pass "list_presets lists both curated and minimal presets"
    else
      fail "list_presets built-ins" "Expected curated and minimal in: $list_out"
    fi

    if [[ "$list_out" =~ "(system)" ]]; then
      pass "list_presets correctly tags built-in presets as (system)"
    else
      fail "list_presets tags" "Missing (system) tag in: $list_out"
    fi

    # 2. Test direct execution of --list-presets flag
    local cli_out
    if cli_out=$("$INSTALLER_SCRIPT" --list-presets); then
      if [[ "$cli_out" =~ "Available Desktop Presets:" ]] && [[ "$cli_out" =~ "curated" ]]; then
        pass "installer.sh --list-presets exits 0 and displays catalog"
      else
        fail "installer.sh --list-presets" "Unexpected catalog output: $cli_out"
      fi
    else
      fail "installer.sh --list-presets" "Failed with exit code $?"
    fi

    # 3. Test minimal preset deployment
    local min_home="$SANDBOX_DIR/min_user_home"
    mkdir -p "$min_home"
    rm -f "$SANDBOX_DIR/dyn_preset_sudo.log"
    apply_preset "testuser" "$min_home" "minimal" >/dev/null

    local min_cfg="$min_home/.config"
    if [[ -f "$min_cfg/kdeglobals" ]] && grep -q "ColorScheme=BreezeDark" "$min_cfg/kdeglobals"; then
      pass "apply_preset minimal deploys dark theme in kdeglobals"
    else
      fail "apply_preset minimal kdeglobals" "Missing kdeglobals"
    fi

    local min_applets="$min_cfg/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -f "$min_applets" ]] && grep -q "launchers=applications:org.kde.konsole.desktop" "$min_applets" && ! grep -q "firefox" "$min_applets"; then
      pass "apply_preset minimal provisions lean taskbar with terminal launcher only"
    else
      fail "apply_preset minimal applets" "Did not find expected minimal launchers in $min_applets"
    fi

    if grep -q "chown -R testuser:testuser" "$SANDBOX_DIR/dyn_preset_sudo.log"; then
      pass "apply_preset minimal enforces ownership via chown -R"
    else
      fail "apply_preset minimal chown" "Missing chown in: $(cat "$SANDBOX_DIR/dyn_preset_sudo.log" 2>/dev/null || echo 'empty')"
    fi

    # 4. Test user-level custom presets discovery & deployment (~/.config/plasmarch/presets/<name>/)
    local fake_user_presets="$SANDBOX_DIR/user_presets"
    mkdir -p "$fake_user_presets/nord/.config"
    echo "ColorScheme=NordicDark" > "$fake_user_presets/nord/.config/kdeglobals"
    echo "Nordic Arctic Ice dark theme" > "$fake_user_presets/nord/description.txt"

    export PLASMARCH_USER_PRESETS_DIR="$fake_user_presets"

    local user_list
    user_list=$(list_presets)
    if [[ "$user_list" =~ "nord" ]] && [[ "$user_list" =~ "Nordic Arctic Ice dark theme" ]] && [[ "$user_list" =~ "(user)" ]]; then
      pass "list_presets discovers custom presets in user config directory with (user) tag"
    else
      fail "list_presets user discovery" "Expected nord (user) in: $user_list"
    fi

    local nord_home="$SANDBOX_DIR/nord_user_home"
    mkdir -p "$nord_home"
    apply_preset "testuser" "$nord_home" "nord" >/dev/null

    if [[ -f "$nord_home/.config/kdeglobals" ]] && grep -q "ColorScheme=NordicDark" "$nord_home/.config/kdeglobals"; then
      pass "apply_preset resolves and deploys user custom preset"
    else
      fail "apply_preset user preset" "Missing or incorrect custom preset files"
    fi

    # 5. Test user-level preset overrides system preset of same name
    mkdir -p "$fake_user_presets/curated/.config"
    echo "ColorScheme=UserOverriddenCurated" > "$fake_user_presets/curated/.config/kdeglobals"

    local override_home="$SANDBOX_DIR/override_user_home"
    mkdir -p "$override_home"
    apply_preset "testuser" "$override_home" "curated" >/dev/null

    if [[ -f "$override_home/.config/kdeglobals" ]] && grep -q "ColorScheme=UserOverriddenCurated" "$override_home/.config/kdeglobals"; then
      pass "apply_preset prioritizes user-level preset over system preset of the same name"
    else
      fail "apply_preset user override" "Did not prioritize user preset"
    fi

    # 6. Test invalid preset error handling with available presets listed
    local invalid_err=""
    if invalid_err=$(apply_preset "testuser" "$min_home" "nonexistent_profile_xyz" 2>&1); then
      fail "apply_preset invalid" "Expected non-zero exit for non-existent preset"
    else
      if [[ "$invalid_err" =~ "Error: Preset 'nonexistent_profile_xyz' not found." ]] && [[ "$invalid_err" =~ "Available presets:" ]]; then
        pass "apply_preset outputs clear error with available preset list and exits 1"
      else
        fail "apply_preset invalid error output" "Unexpected error message: $invalid_err"
      fi
    fi

    # 7. Test install_tier with PLASMARCH_PRESET=minimal
    local fake_target_home="$SANDBOX_DIR/fake_target_minimal_home"
    mkdir -p "$fake_target_home"
    get_user_home() { echo "$fake_target_home"; }
    validate_user() { return 0; }
    get_user_profile() { echo "$fake_target_home/.bash_profile"; }
    pacman() { return 0; }
    export -f get_user_home validate_user get_user_profile pacman

    # Reset PLASMARCH_USER_PRESETS_DIR so it doesn't interfere
    unset PLASMARCH_USER_PRESETS_DIR
    export PLASMARCH_PRESET="minimal"

    printf "myuser\nN\nY\n\n" | install_tier > "$SANDBOX_DIR/install_minimal_run.log" 2>&1 || true

    local deployed_appletsrc="$fake_target_home/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -f "$deployed_appletsrc" ]] && grep -q "launchers=applications:org.kde.konsole.desktop" "$deployed_appletsrc" && ! grep -q "firefox" "$deployed_appletsrc"; then
      pass "install_tier successfully deploys minimal preset when specified"
    else
      fail "install_tier minimal preset" "Minimal preset not deployed. Log: $(cat "$SANDBOX_DIR/install_minimal_run.log" 2>/dev/null || echo 'empty')"
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
test_selective_layer2_removal
test_categorized_install_workflow
test_user_presets
test_dynamic_preset_catalog

PASS_COUNT=$(grep -c "^PASS$" "$SANDBOX_DIR/test_results.log" 2>/dev/null || true)
FAIL_COUNT=$(grep -c "^FAIL$" "$SANDBOX_DIR/test_results.log" 2>/dev/null || true)
PASS_COUNT="${PASS_COUNT:-0}"
FAIL_COUNT="${FAIL_COUNT:-0}"
TEST_COUNT=$((PASS_COUNT + FAIL_COUNT))

echo "=========================================================="
echo "Test Summary: Total: $TEST_COUNT | Passed: $PASS_COUNT | Failed: $FAIL_COUNT"
echo "=========================================================="

if (( FAIL_COUNT > 0 )); then
  exit 1
fi
exit 0
