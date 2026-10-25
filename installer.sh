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

get_system_presets_dir() {
  if [[ -n "${PLASMARCH_SYSTEM_PRESETS_DIR:-}" ]]; then
    echo "$PLASMARCH_SYSTEM_PRESETS_DIR"
  elif [[ -d "$SCRIPT_DIR/presets" ]]; then
    echo "$SCRIPT_DIR/presets"
  else
    echo "/usr/share/plasmarch/presets"
  fi
}

readonly SYSTEM_PRESETS_DIR="$(get_system_presets_dir)"
readonly CURATED_PRESETS_DIR="$SYSTEM_PRESETS_DIR/curated/.config"

get_user_presets_dir() {
  echo "${PLASMARCH_USER_PRESETS_DIR:-$HOME/.config/plasmarch/presets}"
}

# ==========================================
# CLI & Engine Configuration
# ==========================================
readonly PLASMARCH_VERSION="0.2.0"
CLI_ACTION=""
CLI_USER=""
CLI_PRESET=""
USER_SPECIFIED=0
PRESET_SPECIFIED=0
NON_INTERACTIVE=0
DRY_RUN=0

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

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    return 0
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

validate_preset() {
  local preset="${1:-}"
  if [[ -z "$preset" ]]; then
    echo "Error: Preset name cannot be empty." >&2
    return 1
  fi

  if [[ "$preset" =~ \.\. || "$preset" =~ / || "$preset" =~ \\ ]]; then
    echo "Error: Invalid preset name '$preset'. Directory traversal characters are not permitted." >&2
    return 1
  fi

  if [[ ! "$preset" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo "Error: Invalid preset name format '$preset'. Preset names must start with an alphanumeric character and contain only letters, numbers, underscores, or hyphens." >&2
    return 1
  fi

  if ! resolve_preset_dir "$preset" &>/dev/null; then
    echo "Error: Preset '$preset' does not exist." >&2
    return 1
  fi

  return 0
}

get_preset_description() {
  local dir="$1"
  local name="$2"

  if [[ -f "$dir/description.txt" ]]; then
    head -n 1 "$dir/description.txt" | tr -d '\r\n'
  elif [[ -f "$dir/preset.conf" ]] && grep -q "^description=" "$dir/preset.conf"; then
    grep "^description=" "$dir/preset.conf" | head -n 1 | cut -d= -f2- | tr -d '\r\n'
  else
    case "$name" in
      curated) echo "Breeze Dark baseline with pinned taskbar and enhanced Dolphin previews" ;;
      minimal) echo "Lean profile with clean, minimal taskbar and basic dark theme" ;;
      *) echo "Custom preset ($name)" ;;
    esac
  fi
}

get_available_presets() {
  local names=()
  local user_presets_dir
  user_presets_dir="$(get_user_presets_dir)"
  local sys_presets_dir
  sys_presets_dir="$(get_system_presets_dir)"

  if [[ -d "$user_presets_dir" ]]; then
    for dir in "$user_presets_dir"/*; do
      [[ -d "$dir" ]] && names+=("$(basename "$dir")")
    done
  fi
  if [[ -d "$sys_presets_dir" ]]; then
    for dir in "$sys_presets_dir"/*; do
      if [[ -d "$dir" ]]; then
        local bname
        bname="$(basename "$dir")"
        local exists=false
        for n in "${names[@]:-}"; do
          if [[ "$n" == "$bname" ]]; then exists=true; break; fi
        done
        $exists || names+=("$bname")
      fi
    done
  fi
  echo "${names[*]:-}"
}

list_presets() {
  echo "Available Desktop Presets:"
  local found=()
  local preset_name
  local user_presets_dir
  user_presets_dir="$(get_user_presets_dir)"
  local sys_presets_dir
  sys_presets_dir="$(get_system_presets_dir)"

  # Scan user-level custom presets: ~/.config/plasmarch/presets/<name>/
  if [[ -d "$user_presets_dir" ]]; then
    for dir in "$user_presets_dir"/*; do
      if [[ -d "$dir" ]]; then
        preset_name=$(basename "$dir")
        local desc
        desc=$(get_preset_description "$dir" "$preset_name")
        printf "  - %-12s : %s (user)\n" "$preset_name" "$desc"
        found+=("$preset_name")
      fi
    done
  fi

  # Scan system-level presets: presets/<name>/
  if [[ -d "$sys_presets_dir" ]]; then
    for dir in "$sys_presets_dir"/*; do
      if [[ -d "$dir" ]]; then
        preset_name=$(basename "$dir")
        local overridden=false
        for f in "${found[@]:-}"; do
          if [[ "$f" == "$preset_name" ]]; then
            overridden=true
            break
          fi
        done
        if ! $overridden; then
          local desc
          desc=$(get_preset_description "$dir" "$preset_name")
          printf "  - %-12s : %s (system)\n" "$preset_name" "$desc"
          found+=("$preset_name")
        fi
      fi
    done
  fi

  if (( ${#found[@]} == 0 )); then
    echo "  (No presets found)"
  fi
}

resolve_preset_dir() {
  local preset_arg="${1:-curated}"

  # Reject path traversal
  if [[ "$preset_arg" =~ \.\. || "$preset_arg" =~ \\ ]]; then
    return 1
  fi

  # Direct directory path support (only if safe path, not traversal or system root)
  if [[ -d "$preset_arg" && "$preset_arg" != "/" && "$preset_arg" != "/etc"* ]]; then
    echo "$preset_arg"
    return 0
  fi

  # If explicit path with / was given and does not exist, fail immediately
  if [[ "$preset_arg" =~ / ]]; then
    return 1
  fi

  local user_presets_dir
  user_presets_dir="$(get_user_presets_dir)"
  local sys_presets_dir
  sys_presets_dir="$(get_system_presets_dir)"

  # 1. User-level custom presets: ~/.config/plasmarch/presets/<name>/
  if [[ -d "$user_presets_dir/$preset_arg" ]]; then
    echo "$user_presets_dir/$preset_arg"
    return 0
  fi

  # 2. System-level presets: presets/<name>/
  if [[ -d "$sys_presets_dir/$preset_arg" ]]; then
    echo "$sys_presets_dir/$preset_arg"
    return 0
  fi

  return 1
}

apply_preset() {
  local target_user="$1"
  local user_home="$2"
  local preset_arg="${3:-${CLI_PRESET:-${PLASMARCH_PRESET:-${PRESET_NAME:-curated}}}}"

  if [[ "$preset_arg" =~ \.\. || "$preset_arg" =~ \\ ]]; then
    echo "Error: Directory traversal is not permitted in preset path." >&2
    return 1
  fi

  local resolved_dir=""
  if ! resolved_dir=$(resolve_preset_dir "$preset_arg"); then
    local avail
    avail=$(get_available_presets)
    echo "Error: Preset '$preset_arg' not found." >&2
    echo "Available presets: ${avail:-none}" >&2
    exit 1
  fi

  local target_config="$user_home/.config"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    echo "[DRY-RUN] Would execute: sudo mkdir -p $target_config"
    echo "[DRY-RUN] Would execute: sudo cp -r $resolved_dir/. $target_config/"
    echo "[DRY-RUN] Would execute: sudo chown -R $target_user:$target_user $target_config"
    echo -e "Applied desktop preset '\033[1;32m$preset_arg\033[0m' for $target_user. (dry-run)"
    return 0
  fi

  sudo mkdir -p "$target_config"

  if [[ -d "$resolved_dir/.config" ]]; then
    sudo cp -r "$resolved_dir/.config/." "$target_config/"
  else
    # Direct config folder (e.g., when passing curated/.config directly or a custom folder)
    for item in "$resolved_dir"/* "$resolved_dir"/.*; do
      local base
      base=$(basename "$item")
      if [[ "$base" == "." || "$base" == ".." || "$base" == "*" || "$base" == "description.txt" || "$base" == "preset.conf" ]]; then
        continue
      fi
      if [[ -e "$item" ]]; then
        sudo cp -r "$item" "$target_config/"
      fi
    done
  fi

  if [[ -d "$resolved_dir/.local" ]]; then
    sudo mkdir -p "$user_home/.local"
    sudo cp -r "$resolved_dir/.local/." "$user_home/.local/"
    sudo chown -R "$target_user:$target_user" "$user_home/.local"
  fi

  sudo chown -R "$target_user:$target_user" "$target_config"
  echo -e "Applied desktop preset '\033[1;32m$preset_arg\033[0m' for $target_user."
  return 0
}

apply_user_preset() {
  apply_preset "$@"
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
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      echo "[DRY-RUN] Would execute: sudo pacman -Rns ${to_remove[*]}"
      return 0
    fi
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
  local target_user="${CLI_USER:-}"
  local AUTO="${CLI_AUTO:-}"
  local APPLY_PRESET="${CLI_APPLY_PRESET:-}"
  local user_home=""

  if [ -z "$target_user" ] && [ "${NON_INTERACTIVE:-0}" -eq 0 ]; then
    read -r -p "Enter the target username (leave blank to skip user config): " target_user || true
  fi

  if [ -n "$target_user" ]; then
    if ! validate_user "$target_user"; then
      echo "Error: Target user validation failed. Aborting installation." >&2
      exit 1
    fi
    user_home=$(get_user_home "$target_user")
    if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
      [ -z "$AUTO" ] && AUTO="Y"
      [ -z "$APPLY_PRESET" ] && APPLY_PRESET="Y"
    else
      if [ -z "$AUTO" ]; then
        read -r -p "Do you want to enable TTY auto-start for $target_user? (Y/n): " AUTO || true
        [ -z "$AUTO" ] && AUTO="Y"
      fi
      if [ -z "$APPLY_PRESET" ]; then
        read -r -p "Do you want to apply curated desktop presets (Breeze Dark, pinned taskbar) for $target_user? (Y/n): " APPLY_PRESET || true
        [ -z "$APPLY_PRESET" ] && APPLY_PRESET="Y"
      fi
    fi
  fi

  echo -e "\n--- GUI Application Selection (Layer 2) ---"
  local selected_layer2=()

  if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
    echo "Non-interactive mode active: Selecting all default catalog applications."
    for item in "${APP_CATALOG[@]}"; do
      local pkg=""
      local desc=""
      local default_state=""
      IFS='|' read -r pkg desc default_state <<< "$item"
      if [[ "$default_state" == "ON" ]]; then
        selected_layer2+=("$pkg")
      fi
    done
  else
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
    if selected_apps_str=$(prompt_checklist "Layer 2 Application Selection" "Select applications to install (Space to toggle, Enter to confirm):" "${checklist_items[@]}"); then
      read -ra selected_layer2 <<< "$selected_apps_str"
    fi
  fi

  echo -e "\nSelected GUI applications: ${selected_layer2[*]:-(none)}"

  local install_queue=("${LAYER1[@]}")
  if (( ${#selected_layer2[@]} > 0 )); then
    install_queue+=("${selected_layer2[@]}")
  fi
  install_queue+=("${LAYER3[@]}")

  echo -e "\n--- Installing selected packages ---"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    echo "[DRY-RUN] Would execute: sudo pacman -S --needed ${install_queue[*]}"
  else
    if ! sudo pacman -S --needed "${install_queue[@]}"; then
      echo "Error: Package installation failed or was aborted." >&2
      exit 1
    fi
  fi

  if [ -n "$target_user" ] && [[ "$APPLY_PRESET" =~ ^[Yy]$ ]]; then
    echo -e "\n--- Desktop Presets ---"
    apply_user_preset "$target_user" "$user_home" "${CLI_PRESET:-${PRESET_NAME:-${PLASMARCH_PRESET:-curated}}}"
  fi

  if [ -n "$target_user" ] && [[ "$AUTO" =~ ^[Yy]$ ]]; then
    echo -e "\n--- Autostart Configuration ---"
    local profile
    profile=$(get_user_profile "$target_user" "$user_home")

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      echo "[DRY-RUN] Would append autostart configuration to $profile for $target_user"
    else
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
  fi
}

remove_tier() {
  check_privileges
  echo -e "--- Configuration ---"
  local target_user="${CLI_USER:-}"
  local user_home=""
  local CLEAN_REMNANTS="N"

  if [ -z "$target_user" ] && [ "${NON_INTERACTIVE:-0}" -eq 0 ]; then
    read -r -p "Enter the target username to clean up user-specific configurations (leave blank to skip): " target_user || true
  fi

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
    local to_remove_apps=()

    if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
      echo "Non-interactive mode active: Removing all installed Layer 2 applications."
      to_remove_apps=("${installed_layer2[@]}")
      remove_packages "${to_remove_apps[@]}"
    else
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
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      echo "[DRY-RUN] Would clean autostart logic from $profile"
    else
      if sudo test -f "$profile"; then
        if sudo grep -Fq "$AUTOSTART_START" "$profile" && sudo grep -Fq "$AUTOSTART_END" "$profile"; then
          sudo sed -i.bak "/$AUTOSTART_START/,/$AUTOSTART_END/d" "$profile"
          sudo rm -f "${profile}.bak"
          echo "Cleaned autostart logic from $profile"
        else
          echo "Notice: Autostart markers not found or incomplete in $profile. Skipping removal."
        fi
      fi
    fi

    echo -e "\n--- User Remnant Cleanup ---"
    if [ "${NON_INTERACTIVE:-0}" -eq 0 ]; then
      read -r -p "Do you want to completely wipe local KDE config remnants for $target_user? [y/N]: " CLEAN_REMNANTS || true
    fi
    if [[ "$CLEAN_REMNANTS" =~ ^[Yy]$ ]]; then
      echo "Cleaning remnants in $user_home..."
      if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "[DRY-RUN] Would wipe KDE config remnants in $user_home/.config, .local/share, .cache"
      else
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
      fi
    else
      echo "Keeping user configurations."
    fi
  fi

  echo -e "\nPlasma desktop environment cleanly managed."
}

# ------------------------------------------------------------------------------
# CLI Argument Parser & Execution Engine
# ------------------------------------------------------------------------------
show_help() {
  cat <<EOF
PlasmArch $PLASMARCH_VERSION - Layered KDE Plasma deployment and lifecycle manager

Usage:
  $0 [command] [options]
  $0 [options]

Commands:
  install                 Deploy KDE Plasma, GUI apps, and desktop configuration
  remove                  Remove KDE Plasma and clean up desktop configurations
  --list-presets          List all available desktop preset profiles

Options:
  -i, --install           Set action to install
  -r, --remove            Set action to remove
  --list-presets          List all available desktop preset profiles
  -u, --user <username>   Specify target username for desktop configurations
  -p, --preset <name>     Desktop preset profile to apply (default: "curated")
  -y, --yes,
  --non-interactive       Unattended non-interactive mode (skips all prompts, uses defaults)
  -d, --dry-run           Simulation mode (prints commands without modifying host)
  -h, --help              Show this help message and exit
  -v, --version           Print PlasmArch version and exit

Examples:
  # Interactive installation (classic workflow)
  $0 install

  # List available desktop presets
  $0 --list-presets

  # Unattended installation for a specific user with curated presets
  $0 --install --user alice --yes

  # Simulation dry-run of unattended removal
  $0 --remove --user alice --non-interactive --dry-run

  # Positional command with flags
  $0 install -u bob -y
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --list-presets|list-presets)
        list_presets
        exit 0
        ;;
      -i|--install|install)
        if [[ -n "$CLI_ACTION" ]]; then
          if [[ "$CLI_ACTION" != "install" ]]; then
            echo "Error: Conflicting actions specified ('$CLI_ACTION' and 'install')." >&2
          else
            echo "Error: Duplicate action '$1' specified." >&2
          fi
          exit 1
        fi
        CLI_ACTION="install"
        shift
        ;;
      -r|--remove|remove)
        if [[ -n "$CLI_ACTION" ]]; then
          if [[ "$CLI_ACTION" != "remove" ]]; then
            echo "Error: Conflicting actions specified ('$CLI_ACTION' and 'remove')." >&2
          else
            echo "Error: Duplicate action '$1' specified." >&2
          fi
          exit 1
        fi
        CLI_ACTION="remove"
        shift
        ;;
      -u|--user)
        if [[ "$USER_SPECIFIED" -eq 1 ]]; then
          echo "Error: Duplicate option '$1' specified." >&2
          exit 1
        fi
        if (( $# < 2 )) || [[ -z "$2" ]] || [[ "$2" =~ ^- ]]; then
          echo "Error: Option '$1' requires a valid username argument." >&2
          exit 1
        fi
        CLI_USER="$2"
        USER_SPECIFIED=1
        shift 2
        ;;
      --user=*)
        if [[ "$USER_SPECIFIED" -eq 1 ]]; then
          echo "Error: Duplicate option '--user' specified." >&2
          exit 1
        fi
        local user_val="${1#*=}"
        if [[ -z "$user_val" ]]; then
          echo "Error: Option '--user' requires a valid username argument." >&2
          exit 1
        fi
        CLI_USER="$user_val"
        USER_SPECIFIED=1
        shift
        ;;
      -u=*)
        if [[ "$USER_SPECIFIED" -eq 1 ]]; then
          echo "Error: Duplicate option '-u' specified." >&2
          exit 1
        fi
        local user_val="${1#*=}"
        if [[ -z "$user_val" ]]; then
          echo "Error: Option '-u' requires a valid username argument." >&2
          exit 1
        fi
        CLI_USER="$user_val"
        USER_SPECIFIED=1
        shift
        ;;
      -p|--preset)
        if [[ "$PRESET_SPECIFIED" -eq 1 ]]; then
          echo "Error: Duplicate option '$1' specified." >&2
          exit 1
        fi
        if (( $# < 2 )) || [[ -z "$2" ]] || [[ "$2" =~ ^- ]]; then
          echo "Error: Option '$1' requires a valid preset name argument." >&2
          exit 1
        fi
        CLI_PRESET="$2"
        PRESET_SPECIFIED=1
        shift 2
        ;;
      --preset=*)
        if [[ "$PRESET_SPECIFIED" -eq 1 ]]; then
          echo "Error: Duplicate option '--preset' specified." >&2
          exit 1
        fi
        local preset_val="${1#*=}"
        if [[ -z "$preset_val" ]]; then
          echo "Error: Option '--preset' requires a valid preset name argument." >&2
          exit 1
        fi
        CLI_PRESET="$preset_val"
        PRESET_SPECIFIED=1
        shift
        ;;
      -p=*)
        if [[ "$PRESET_SPECIFIED" -eq 1 ]]; then
          echo "Error: Duplicate option '-p' specified." >&2
          exit 1
        fi
        local preset_val="${1#*=}"
        if [[ -z "$preset_val" ]]; then
          echo "Error: Option '-p' requires a valid preset name argument." >&2
          exit 1
        fi
        CLI_PRESET="$preset_val"
        PRESET_SPECIFIED=1
        shift
        ;;
      -y|--yes|--non-interactive)
        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
          echo "Error: Duplicate option '$1' specified." >&2
          exit 1
        fi
        NON_INTERACTIVE=1
        shift
        ;;
      -d|--dry-run)
        if [[ "$DRY_RUN" -eq 1 ]]; then
          echo "Error: Duplicate option '$1' specified." >&2
          exit 1
        fi
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      -v|--version)
        echo "PlasmArch $PLASMARCH_VERSION"
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Error: Unknown option '$1'. Use --help for usage information." >&2
        exit 1
        ;;
      *)
        echo "Error: Unexpected argument '$1'. Use --help for usage information." >&2
        exit 1
        ;;
    esac
  done

  # Validate user if specified
  if [[ -n "$CLI_USER" ]]; then
    if ! validate_user "$CLI_USER"; then
      exit 1
    fi
  fi

  # If preset not explicitly specified via CLI, check environment or use default
  if [[ "$PRESET_SPECIFIED" -eq 0 ]]; then
    CLI_PRESET="${PLASMARCH_PRESET:-${PRESET_NAME:-${CLI_PRESET:-curated}}}"
  fi

  # Validate preset if specified or default
  if [[ -n "$CLI_PRESET" ]]; then
    if ! validate_preset "$CLI_PRESET"; then
      exit 1
    fi
  fi
}

run_action() {
  if [[ -z "$CLI_ACTION" ]]; then
    echo "Error: No action specified. Please specify 'install' or 'remove'." >&2
    echo "Usage: $0 {install|remove} [options]" >&2
    echo "Run '$0 --help' for detailed usage and examples." >&2
    exit 1
  fi

  case "$CLI_ACTION" in
    install)
      install_tier
      ;;
    remove)
      remove_tier
      ;;
    *)
      echo "Error: Invalid action '$CLI_ACTION'. Must be 'install' or 'remove'." >&2
      exit 1
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Script Execution Guard (Direct execution vs Sourcing)
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  RUN_MAIN=1
else
  RUN_MAIN=0
fi

# ------------------------------------------------------------------------------
# Script Entry Point (with backward-compatible sed pattern preservation)
# ------------------------------------------------------------------------------
if [ "${1:-}" = "install" ]; then
  if [[ "$RUN_MAIN" -eq 1 ]]; then
    CLI_ACTION="install"
    shift || true
    parse_args "$@"
    run_action
  fi
elif [ "${1:-}" = "remove" ]; then
  if [[ "$RUN_MAIN" -eq 1 ]]; then
    CLI_ACTION="remove"
    shift || true
    parse_args "$@"
    run_action
  fi
elif [ "${1:-}" = "--list-presets" ] || [ "${1:-}" = "list-presets" ]; then
  if [[ "$RUN_MAIN" -eq 1 ]]; then
    list_presets
    exit 0
  fi
else
  if [[ "$RUN_MAIN" -eq 1 ]]; then
    parse_args "$@"
    run_action
  fi
fi
