#!/bin/bash
set -euo pipefail

# ==========================================
# TIER 1: Core Plasma & Settings GUI
# Always removed during 'remove'
# ==========================================
LAYER1="plasma-desktop plasma-nm bluedevil plasma-pa powerdevil kscreen polkit-kde-agent xdg-desktop-portal-kde"

# ==========================================
# TIER 2: GUI Apps (Prompted on removal)
# ==========================================
LAYER2="dolphin konsole ark gwenview"

# ==========================================
# TIER 3: Core System Daemons (Strictly Protected)
# NEVER removed by this script
# ==========================================
LAYER3="networkmanager bluez"

validate_user() {
  local user="$1"
  if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Error: Invalid username format."
    return 1
  fi
  if ! id "$user" &>/dev/null; then
    echo "Error: User '$user' does not exist on this system."
    return 1
  fi
  return 0
}

remove_packages() {
  local pkgs="$1"
  # pacman -Qq prints installed packages to stdout and errors to stderr. || true prevents set -e from aborting.
  local to_remove
  to_remove=$(pacman -Qq $pkgs 2>/dev/null || true)
  
  if [ -n "$to_remove" ]; then
    # Convert newlines to spaces for pacman -Rns
    to_remove=$(echo "$to_remove" | tr '\n' ' ')
    sudo pacman -Rns $to_remove
  else
    echo "None of the specified packages are currently installed."
  fi
}

install_tier() {
  echo -e "--- Configuration ---"
  local target_user=""
  read -p "Enter the target username (leave blank to skip user config): " target_user
  local AUTO="N"
  if [ -n "$target_user" ]; then
    if ! validate_user "$target_user"; then
      echo "Error: Target user validation failed. Aborting installation."
      exit 1
    fi
    read -p "Do you want to enable TTY auto-start for $target_user? (Y/n): " AUTO
    [ -z "$AUTO" ] && AUTO="Y"
  fi

  echo -e "\n--- Installing all tiers ---"
  sudo pacman -S --needed $LAYER1 $LAYER2 $LAYER3

  if [[ "$AUTO" =~ ^[Yy]$ ]]; then
    echo -e "\n--- Autostart Configuration ---"
    local profile="/home/$target_user/.bash_profile"
    if ! sudo grep -q "KDE PLASMA AUTOSTART" "$profile" 2>/dev/null; then
      echo -e "\n# --- KDE PLASMA AUTOSTART ---\nif [ -z \"\$DISPLAY\" ] && [ \"\$XDG_VTNR\" = 1 ]; then\n  exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland\nfi\n# --- END KDE PLASMA AUTOSTART ---" | sudo tee -a "$profile" >/dev/null
      sudo chown "$target_user:" "$profile"
      echo "Autostart added successfully to $profile"
    else
      echo "Autostart already exists in $profile. Skipping."
    fi
  fi
}

remove_tier() {
  echo -e "--- Configuration ---"
  read -p "Enter the target username to clean up user-specific configurations (leave blank to skip): " target_user
  if [ -n "$target_user" ]; then
    if ! validate_user "$target_user"; then
      echo "Error: Target user validation failed. Aborting removal."
      exit 1
    fi
  fi

  echo -e "\n--- Removing Core Plasma (Layer 1) ---"
  remove_packages "$LAYER1"

  echo -e "\n--- App Layer (Layer 2) ---"
  read -p "Do you also want to remove the GUI apps (Dolphin, Konsole, Ark, Gwenview)? [y/N]: " RM_APPS
  if [[ "$RM_APPS" =~ ^[Yy]$ ]]; then
    remove_packages "$LAYER2"
  else
    echo "Keeping GUI apps intact."
  fi

  echo -e "\n--- System Daemons (Layer 3) ---"
  echo "NetworkManager and Bluez are strictly protected. Skipping."

  if [ -n "$target_user" ]; then
    echo -e "\n--- Autostart Cleanup ---"
    local profile="/home/$target_user/.bash_profile"
    if sudo test -f "$profile"; then
      sudo sed -i '/# --- KDE PLASMA AUTOSTART ---/,/# --- END KDE PLASMA AUTOSTART ---/d' "$profile"
      echo "Cleaned autostart logic from $profile"
    fi

    echo -e "\n--- User Remnant Cleanup ---"
    read -p "Do you want to completely wipe local KDE config remnants for $target_user? [y/N]: " CLEAN_REMNANTS
    if [[ "$CLEAN_REMNANTS" =~ ^[Yy]$ ]]; then
      local user_dir="/home/$target_user"
      echo "Cleaning remnants in $user_dir..."
      
      # Safe cleanup using find to avoid string interpolation vulnerabilities
      for prefix in plasma kde kwin dolphinrc konsolerc arkrc gwenviewrc; do
        sudo find "$user_dir/.config" -maxdepth 1 -name "${prefix}*" -exec rm -rf {} + 2>/dev/null || true
      done
      
      for prefix in plasma dolphin konsole ark gwenview; do
        sudo find "$user_dir/.local/share" -maxdepth 1 -name "${prefix}*" -exec rm -rf {} + 2>/dev/null || true
      done
      
      for prefix in plasma kde kwin; do
        sudo find "$user_dir/.cache" -maxdepth 1 -name "${prefix}*" -exec rm -rf {} + 2>/dev/null || true
      done
      
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
  echo "Usage: $0 {install|remove}"
  echo "Run this from your standard user account. It will prompt for sudo."
  exit 1
fi
