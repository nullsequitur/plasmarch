#!/bin/bash
set -euo pipefail

# ==========================================
# TIER 1: Core Plasma & Settings GUI
# Always removed during 'remove'
# ==========================================
readonly LAYER1=(
  plasma-desktop
  plasma-nm
  bluedevil
  plasma-pa
  powerdevil
  kscreen
  polkit-kde-agent
  xdg-desktop-portal-kde
)

# ==========================================
# TIER 2 Application Catalog
# Format: pkg_name|description|default_state
# ==========================================
readonly APP_CATALOG=(
  "dolphin|File Manager: KDE Dolphin|ON"
  "konsole|Terminal: KDE Konsole|ON"
  "firefox|Browser: Mozilla Firefox|ON"
  "chromium|Browser: Chromium|OFF"
  "ark|Archiver: KDE Ark|ON"
  "gwenview|Image Viewer: KDE Gwenview|ON"
  "okular|PDF/Document: KDE Okular|OFF"
  "kate|Text Editor: KDE Kate|OFF"
)

# Legacy Layer 2 fallback list for removal if catalog not used
readonly LAYER2=(
  dolphin
  konsole
  firefox
  chromium
  ark
  gwenview
  okular
  kate
)

# ==========================================
# TIER 3: Core System Daemons (Strictly Protected)
# NEVER removed by this script
# ==========================================
readonly LAYER3=(
  networkmanager
  bluez
)

readonly AUTOSTART_START="# --- KDE PLASMA AUTOSTART ---"
readonly AUTOSTART_END="# --- END KDE PLASMA AUTOSTART ---"
readonly SCRIPT_DIR="${PLASMARCH_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
readonly CURATED_PRESETS_DIR="$SCRIPT_DIR/presets/curated/.config"

check_privileges() {
  local current_uid="${PLASMARCH_TEST_EUID:-${EUID:-$(id -u)}}"
  if [[ "$current_uid" -eq 0 ]]; then
    echo "Error: Do not run this script directly as root or with sudo." >&2
    echo "Run it as a regular user; sudo will be prompted when required." >&2
    exit 1
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: 'sudo' command not found. Please install sudo." >&2
    exit 1
  fi

  # Validate sudo access upfront
  sudo -v || exit 1
}

validate_user() {
  local user="${1:-}"
  if [[ -z "$user" ]]; then
    echo "Error: Username cannot be empty." >&2
    return 1
  fi

  if [[ ! "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ ]]; then
    echo "Error: Invalid username format '$user'." >&2
    return 1
  fi

  if ! id "$user" &>/dev/null; then
    echo "Error: User '$user' does not exist on this system." >&2
    return 1
  fi

  local uid
  uid=$(id -u "$user")
  if (( uid < 1000 )); then
    echo "Error: User '$user' is a system account (UID $uid < 1000). Only regular user accounts are supported." >&2
    return 1
  fi

  return 0
}

get_user_home() {
  local user="$1"
  local home_dir
  home_dir=$(getent passwd "$user" | cut -d: -f6)
  if [[ -z "$home_dir" || ! -d "$home_dir" || "$home_dir" == "/" || "$home_dir" == "/root" ]]; then
    echo "Error: Home directory for '$user' is invalid or not found ('$home_dir')." >&2
    return 1
  fi
  echo "$home_dir"
}

get_user_profile() {
  local user="$1"
  local home_dir="$2"
  local shell_bin
  shell_bin=$(getent passwd "$user" | cut -d: -f7)
  local shell_name
  shell_name=$(basename "${shell_bin:-bash}")

  case "$shell_name" in
    zsh)
      echo "$home_dir/.zprofile"
      ;;
    *)
      if [[ -f "$home_dir/.bash_profile" || ! -f "$home_dir/.profile" ]]; then
        echo "$home_dir/.bash_profile"
      else
        echo "$home_dir/.profile"
      fi
      ;;
  esac
}

apply_user_preset() {
  local target_user="$1"
  local user_home="$2"
  local preset_dir="${3:-$CURATED_PRESETS_DIR}"

  if [[ ! -d "$preset_dir" ]]; then
    echo "Warning: Preset directory '$preset_dir' not found. Skipping preset application." >&2
    return 1
  fi

  local target_config="$user_home/.config"
  sudo mkdir -p "$target_config"
  sudo cp -r "$preset_dir/." "$target_config/"
  sudo chown -R "$target_user:$target_user" "$target_config"
  echo -e "Applied curated desktop preset (\033[1;32mBreeze Dark, Pinned Taskbar, Enhanced Dolphin Previews\033[0m) for $target_user."
  return 0
}

# ------------------------------------------------------------------------------
# TUI Checklist Engine (Whiptail with pure-Bash fallback)
# ------------------------------------------------------------------------------
prompt_checklist_cli() {
  local title="$1"
  shift
  local tags=()
  local labels=()
  local states=()

  while (( $# >= 3 )); do
    tags+=("$1")
    labels+=("$2")
    states+=("$3")
    shift 3
  done

  local count=${#tags[@]}
  if (( count == 0 )); then
    echo ""
    return 0
  fi

  # Interactive toggle loop
  while true; do
    echo -e "\n=== $title ===" >&2
    echo "Toggle selection by entering item numbers (e.g. 1 or 1,3). Press [Enter] to confirm." >&2
    echo "" >&2
    for ((i=0; i<count; i++)); do
      local mark=" "
      [[ "${states[i]}" == "ON" ]] && mark="X"
      printf "  [%d] [%s] %-15s - %s\n" "$((i+1))" "$mark" "${tags[i]}" "${labels[i]}" >&2
    done
    echo "" >&2

    local input=""
    read -r -p "Enter numbers to toggle, 'a' for all, 'n' for none, or press [Enter] to confirm: " input || true
    local clean_input
    clean_input=$(echo "$input" | tr -d '[:space:]')

    if [[ -z "$clean_input" ]]; then
      break
    elif [[ "$clean_input" =~ ^[Aa]$ ]]; then
      for ((i=0; i<count; i++)); do states[i]="ON"; done
    elif [[ "$clean_input" =~ ^[Nn]$ ]]; then
      for ((i=0; i<count; i++)); do states[i]="OFF"; done
    else
      # Support both comma and space-separated numbers (e.g. '1,3' or '1 3')
      local nums=()
      read -ra nums <<< "$(echo "$input" | tr ',' ' ')"
      for num in "${nums[@]}"; do
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= count )); then
          local idx=$((num - 1))
          if [[ "${states[idx]}" == "ON" ]]; then
            states[idx]="OFF"
          else
            states[idx]="ON"
          fi
        fi
      done
    fi
  done

  local selected=()
  for ((i=0; i<count; i++)); do
    if [[ "${states[i]}" == "ON" ]]; then
      selected+=("${tags[i]}")
    fi
  done

  echo "${selected[*]:-}"
}

prompt_checklist() {
  local title="$1"
  local prompt_text="$2"
  shift 2
  local triplets=("$@")

  if [[ "${PLASMARCH_FORCE_CLI_MENU:-0}" -ne 1 ]] && command -v whiptail >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
    local whiptail_args=()
    local i=0
    while (( i < ${#triplets[@]} )); do
      whiptail_args+=("${triplets[i]}" "${triplets[i+1]}" "${triplets[i+2]}")
      i=$((i + 3))
    done

    local choice_str=""
    if choice_str=$(whiptail --title "$title" --checklist "$prompt_text" 20 75 10 "${whiptail_args[@]}" 3>&1 1>&2 2>&3); then
      choice_str=$(echo "$choice_str" | tr -d '"')
      echo "$choice_str"
      return 0
    else
      return 1
    fi
  else
    prompt_checklist_cli "$title" "${triplets[@]}"
    return 0
  fi
}

remove_packages() {
  local pkgs=("$@")
  local to_remove=()
  local pkg

  for pkg in "${pkgs[@]}"; do
    if pacman -Qq "$pkg" &>/dev/null; then
      to_remove+=("$pkg")
    fi
  done

  if (( ${#to_remove[@]} > 0 )); then
    echo "Removing packages: ${to_remove[*]}"
    if ! sudo pacman -Rns "${to_remove[@]}"; then
      echo "Error: pacman removal encountered an issue." >&2
      return 1
    fi
  else
    echo "None of the specified packages are currently installed."
  fi
}

install_tier() {
  check_privileges
  echo -e "--- Configuration ---"
  local target_user=""
  read -r -p "Enter the target username (leave blank to skip user config): " target_user || true
  local AUTO="N"
  local APPLY_PRESET="N"
  local user_home=""

  if [ -n "$target_user" ]; then
    if ! validate_user "$target_user"; then
      echo "Error: Target user validation failed. Aborting installation." >&2
      exit 1
    fi
    user_home=$(get_user_home "$target_user")
    read -r -p "Do you want to enable TTY auto-start for $target_user? (Y/n): " AUTO || true
    [ -z "$AUTO" ] && AUTO="Y"
    read -r -p "Do you want to apply curated desktop presets (Breeze Dark, pinned taskbar) for $target_user? (Y/n): " APPLY_PRESET || true
    [ -z "$APPLY_PRESET" ] && APPLY_PRESET="Y"
  fi

  echo -e "\n--- GUI Application Selection (Layer 2) ---"
  echo "Select GUI applications for the target environment."
  echo "Locally pre-installed packages are marked as '(installed)' for fast/offline setup."

  local checklist_items=()
  for item in "${APP_CATALOG[@]}"; do
    local pkg=""
    local desc=""
    local default_state=""
    IFS='|' read -r pkg desc default_state <<< "$item"
    if pacman -Qq "$pkg" &>/dev/null; then
      desc="$desc (installed)"
    fi
    checklist_items+=("$pkg" "$desc" "$default_state")
  done

  local selected_apps_str=""
  local selected_layer2=()
  if selected_apps_str=$(prompt_checklist "Layer 2 Application Selection" "Select applications to install (Space to toggle, Enter to confirm):" "${checklist_items[@]}"); then
    read -ra selected_layer2 <<< "$selected_apps_str"
  fi

  echo -e "\nSelected GUI applications: ${selected_layer2[*]:-(none)}"

  local install_queue=("${LAYER1[@]}" "${selected_layer2[@]:-}" "${LAYER3[@]}")

  echo -e "\n--- Installing selected packages ---"
  if ! sudo pacman -S --needed "${install_queue[@]}"; then
    echo "Error: Package installation failed or was aborted." >&2
    exit 1
  fi

  if [ -n "$target_user" ] && [[ "$APPLY_PRESET" =~ ^[Yy]$ ]]; then
    echo -e "\n--- Desktop Presets ---"
    apply_user_preset "$target_user" "$user_home"
  fi

  if [ -n "$target_user" ] && [[ "$AUTO" =~ ^[Yy]$ ]]; then
    echo -e "\n--- Autostart Configuration ---"
    local profile
    profile=$(get_user_profile "$target_user" "$user_home")

    if ! sudo grep -q "$AUTOSTART_START" "$profile" 2>/dev/null; then
      if ! sudo test -f "$profile" && [[ "$(basename "$profile")" == ".bash_profile" ]]; then
        cat <<'EOF' | sudo tee "$profile" >/dev/null
# Source ~/.bashrc if present
[[ -f ~/.bashrc ]] && . ~/.bashrc

EOF
      fi

      cat <<EOF | sudo tee -a "$profile" >/dev/null

$AUTOSTART_START
if [ -z "\$DISPLAY" ] && [ -z "\$WAYLAND_DISPLAY" ] && [ "\${XDG_VTNR:-0}" = 1 ]; then
  if [ -x /usr/lib/plasma-dbus-run-session-if-needed ]; then
    exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland
  else
    exec /usr/bin/startplasma-wayland
  fi
fi
$AUTOSTART_END
EOF
      sudo chown "$target_user:$(id -gn "$target_user")" "$profile"
      echo "Autostart added successfully to $profile"
    else
      echo "Autostart already exists in $profile. Skipping."
    fi
  fi
}

remove_tier() {
  check_privileges
  echo -e "--- Configuration ---"
  local target_user=""
  local user_home=""
  local CLEAN_REMNANTS="N"

  read -r -p "Enter the target username to clean up user-specific configurations (leave blank to skip): " target_user || true
  if [ -n "$target_user" ]; then
    if ! validate_user "$target_user"; then
      echo "Error: Target user validation failed. Aborting removal." >&2
      exit 1
    fi
    user_home=$(get_user_home "$target_user")
  fi

  echo -e "\n--- Removing Core Plasma (Layer 1) ---"
  remove_packages "${LAYER1[@]}"

  echo -e "\n--- Application Layer (Layer 2) ---"
  local installed_layer2=()
  for pkg in "${LAYER2[@]}"; do
    if pacman -Qq "$pkg" &>/dev/null; then
      installed_layer2+=("$pkg")
    fi
  done

  if (( ${#installed_layer2[@]} > 0 )); then
    echo "Found ${#installed_layer2[@]} installed GUI application(s)."
    echo "Select which applications to remove. Uncheck any package you wish to keep."

    local checklist_items=()
    for pkg in "${installed_layer2[@]}"; do
      local desc=""
      case "$pkg" in
        dolphin)  desc="KDE File Manager" ;;
        konsole)  desc="KDE Terminal Emulator" ;;
        firefox)  desc="Firefox Web Browser" ;;
        chromium) desc="Chromium Web Browser" ;;
        ark)      desc="KDE Archive Manager" ;;
        gwenview) desc="KDE Image Viewer" ;;
        okular)   desc="KDE Document/PDF Viewer" ;;
        kate)     desc="KDE Advanced Text Editor" ;;
        *)        desc="GUI Application" ;;
      esac
      checklist_items+=("$pkg" "$desc" "ON")
    done

    local selected_to_remove=""
    if selected_to_remove=$(prompt_checklist "Layer 2 GUI Applications Removal" "Select apps to remove (Space to toggle, Enter to confirm):" "${checklist_items[@]}"); then
      read -ra to_remove_apps <<< "$selected_to_remove"
      if (( ${#to_remove_apps[@]} > 0 )); then
        remove_packages "${to_remove_apps[@]}"
      else
        echo "No GUI applications selected for removal. Keeping all Layer 2 applications."
      fi

      local preserved=()
      for pkg in "${installed_layer2[@]}"; do
        local is_removed=false
        for r_pkg in "${to_remove_apps[@]:-}"; do
          if [[ "$pkg" == "$r_pkg" ]]; then
            is_removed=true
            break
          fi
        done
        if ! $is_removed; then
          preserved+=("$pkg")
        fi
      done
      if (( ${#preserved[@]} > 0 )); then
        echo -e "Preserved GUI apps on host: \033[1;32m${preserved[*]}\033[0m"
      fi
    else
      echo "Application removal cancelled. Keeping all GUI applications intact."
    fi
  else
    echo "No Layer 2 GUI applications are currently installed."
  fi

  echo -e "\n--- System Daemons (Layer 3) ---"
  echo -e "Protected system daemons (\033[1;32m${LAYER3[*]}\033[0m) are strictly preserved."

  if [ -n "$target_user" ]; then
    echo -e "\n--- Autostart Cleanup ---"
    local profile
    profile=$(get_user_profile "$target_user" "$user_home")
    if sudo test -f "$profile"; then
      if sudo grep -Fq "$AUTOSTART_START" "$profile" && sudo grep -Fq "$AUTOSTART_END" "$profile"; then
        sudo sed -i.bak "/$AUTOSTART_START/,/$AUTOSTART_END/d" "$profile"
        sudo rm -f "${profile}.bak"
        echo "Cleaned autostart logic from $profile"
      else
        echo "Notice: Autostart markers not found or incomplete in $profile. Skipping removal."
      fi
    fi

    echo -e "\n--- User Remnant Cleanup ---"
    read -r -p "Do you want to completely wipe local KDE config remnants for $target_user? [y/N]: " CLEAN_REMNANTS || true
    if [[ "$CLEAN_REMNANTS" =~ ^[Yy]$ ]]; then
      echo "Cleaning remnants in $user_home..."

      local prefix
      if [ -d "$user_home/.config" ]; then
        for prefix in plasma kde kwin dolphinrc konsolerc arkrc gwenviewrc; do
          sudo find "$user_home/.config" -mindepth 1 -maxdepth 1 -name "${prefix}*" -exec rm -rf {} +
        done
      fi

      if [ -d "$user_home/.local/share" ]; then
        for prefix in plasma dolphin konsole ark gwenview; do
          sudo find "$user_home/.local/share" -mindepth 1 -maxdepth 1 -name "${prefix}*" -exec rm -rf {} +
        done
      fi

      if [ -d "$user_home/.cache" ]; then
        for prefix in plasma kde kwin; do
          sudo find "$user_home/.cache" -mindepth 1 -maxdepth 1 -name "${prefix}*" -exec rm -rf {} +
        done
      fi

      echo "Remnants safely removed."
    else
      echo "Keeping user configurations."
    fi
  fi

  echo -e "\nPlasma desktop environment cleanly managed."
}

if [ "${1:-}" = "install" ]; then
  install_tier
elif [ "${1:-}" = "remove" ]; then
  remove_tier
else
  echo "Usage: $0 {install|remove}" >&2
  echo "Run this from your standard user account. It will prompt for sudo." >&2
  exit 1
fi
