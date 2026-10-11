# PlasmArch

> A layered, state-aware installer to deploy and manage a KDE Plasma (Wayland) desktop environment for a target user on Arch Linux.

## Scope

After basic installation, my ArchLinux system users are configured from the ground up with help of my own [custom scripts](https://github.com/nullsequitur/arch-install). The GUI uses the `hyprland` window manager, it's mostly terminal based and it follows a vim-centric keybind philosophy. The selection of packages is based on these principles, utiliy and minimalism.

The scope of the `PlasmArch` script is twofold:
- Create a fully functional and easy to use desktop environment with basic GUI apps for a new user on my system.
- Leave my main system as free from bloatware as possible.

## Usage

**Prerequisites & Important Notes:** 
- **Create the user first:** The target user must already exist on the system before running the script, as it validates the username for autostart setup.
- **Do not run as root:** Execute the script from a standard user account that has `sudo` privileges. The script will automatically prompt for `sudo` when needed. Do *not* run the script itself with sudo.

Clone this repo. The script should already be executable, but if you get a permission denied error, you can make it executable by running:

```bash
chmod +x installer.sh
```

Then, run the script:

```bash
# Install Plasma and configure autostart
./installer.sh install

# Remove Plasma and optionally clean configuration remnants
./installer.sh remove
```

## Architecture

Deployments are strictly layered to ensure safe removal without compromising the base system:

*   **Tier 1 (Core Plasma):** Base environment (`plasma-desktop`, `plasma-nm`, etc.). Always removed during uninstallation.
*   **Tier 2 (GUI Apps):** Standard applications (`dolphin`, `konsole`, etc.). Prompted for removal.
*   **Tier 3 (System Daemons):** Core networking and bluetooth (`networkmanager`, `bluez`). Strictly protected from removal.

## Features

*   **Non-Destructive:** Designed to safely add or remove a desktop environment on top of my existing Arch installation.
*   **TTY Autostart:** Automatically configures `.bash_profile` to start Plasma Wayland on VT1 login (safely bypassed if a Display Manager is present).
*   **Deep Cleanup:** Optional purging of all local KDE/Plasma configuration remnants during removal.
