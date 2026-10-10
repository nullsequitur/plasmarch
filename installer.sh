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
  echo "--- Installing all tiers ---"
  sudo pacman -S --needed $LAYER1 $LAYER2 $LAYER3

  echo -e "\n--- Autostart Configuration ---"
  read -p "Do you want to enable TTY auto-start for her user? [y/N]: " AUTO
  if [[ "$AUTO" =~ ^[Yy]$ ]]; then
    read -p "Enter her exact username: " HER_USER
    if validate_user "$HER_USER"; then
      local profile="/home/$HER_USER/.bash_profile"
      if ! sudo grep -q "KDE PLASMA AUTOSTART" "$profile" 2>/dev/null; then
        echo -e "\n# --- KDE PLASMA AUTOSTART ---\nif [ -z \"\$DISPLAY\" ] && [ \"\$XDG_VTNR\" = 1 ]; then\n  exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland\nfi\n# --- END KDE PLASMA AUTOSTART ---" | sudo tee -a "$profile" >/dev/null
        sudo chown "$HER_USER:" "$profile"
        echo "Autostart added successfully to $profile"
      else
        echo "Autostart already exists in $profile. Skipping."
      fi
    fi
  fi
}

remove_tier() {
  echo "--- Removing Core Plasma (Layer 1) ---"
  remove_packages "$LAYER1"

  echo -e "\n--- App Layer (Layer 2) ---"
  read -p "Do you also want to remove her GUI apps (Dolphin, Konsole, Ark, Gwenview)? [y/N]: " RM_APPS
  if [[ "$RM_APPS" =~ ^[Yy]$ ]]; then
    remove_packages "$LAYER2"
  else
    echo "Keeping GUI apps intact."
  fi

  echo -e "\n--- System Daemons (Layer 3) ---"
  echo "NetworkManager and Bluez are strictly protected. Skipping."

  echo -e "\n--- Autostart Cleanup ---"
  read -p "Did you set up TTY auto-start for her? (Enter her username to clean it, or leave blank to skip): " HER_USER
  if [ -n "$HER_USER" ]; then
    if validate_user "$HER_USER"; then
      local profile="/home/$HER_USER/.bash_profile"
      if sudo test -f "$profile"; then
        sudo sed -i '/# --- KDE PLASMA AUTOSTART ---/,/# --- END KDE PLASMA AUTOSTART ---/d' "$profile"
        echo "Cleaned autostart logic from $profile"
      fi
    fi
  fi

  echo -e "\n--- User Residue Cleanup ---"
  read -p "Do you want to completely wipe her local KDE config residues? (Enter her username, or leave blank for default NO): " CLEAN_USER
  if [ -n "$CLEAN_USER" ]; then
    if validate_user "$CLEAN_USER"; then
      local user_dir="/home/$CLEAN_USER"
      echo "Cleaning residues in $user_dir..."
      
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
      
      echo "Residues safely destroyed."
    fi
  else
    echo "Keeping user configurations."
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
