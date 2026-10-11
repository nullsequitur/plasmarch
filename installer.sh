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
# TIER 2: GUI Apps (Prompted on removal)
# ==========================================
readonly LAYER2=(
  dolphin
  konsole
  firefox
  ark
  gwenview
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
  local user_home=""

  if [ -n "$target_user" ]; then
    if ! validate_user "$target_user"; then
      echo "Error: Target user validation failed. Aborting installation." >&2
      exit 1
    fi
    user_home=$(get_user_home "$target_user")
    read -r -p "Do you want to enable TTY auto-start for $target_user? (Y/n): " AUTO || true
    [ -z "$AUTO" ] && AUTO="Y"
  fi

  echo -e "\n--- Installing all tiers ---"
  if ! sudo pacman -S --needed "${LAYER1[@]}" "${LAYER2[@]}" "${LAYER3[@]}"; then
    echo "Error: Package installation failed or was aborted." >&2
    exit 1
  fi

  if [ -n "$target_user" ] && [[ "$AUTO" =~ ^[Yy]$ ]]; then
    echo -e "\n--- Autostart Configuration ---"
    local profile
    profile=$(get_user_profile "$target_user" "$user_home")

    if ! sudo grep -q "$AUTOSTART_START" "$profile" 2>/dev/null; then
      # If creating .bash_profile for the first time, ensure standard ~/.bashrc is sourced
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
  local RM_APPS="N"
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

  echo -e "\n--- App Layer (Layer 2) ---"
  read -r -p "Do you also want to remove GUI apps (Dolphin, Konsole, Firefox, Ark, Gwenview)? [y/N]: " RM_APPS || true
  if [[ "$RM_APPS" =~ ^[Yy]$ ]]; then
    remove_packages "${LAYER2[@]}"
  else
    echo "Keeping GUI apps intact."
  fi

  echo -e "\n--- System Daemons (Layer 3) ---"
  echo "NetworkManager and Bluez are strictly protected. Skipping."

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
