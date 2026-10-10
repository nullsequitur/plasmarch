# PlasmArch

A layered, state-aware installer to deploy and manage a KDE Plasma (Wayland) desktop environment for a target user on Arch Linux.

## Usage

Execute the script from a standard user account. Sudo privileges are required.

```bash
# Install Plasma and configure autostart
./installer.sh install

# Remove Plasma and optionally clean configuration residues
./installer.sh remove
```

## Architecture

Deployments are strictly layered to ensure safe removal without compromising the base system:

*   **Tier 1 (Core Plasma):** Base environment (`plasma-desktop`, `plasma-nm`, etc.). Always removed during uninstallation.
*   **Tier 2 (GUI Apps):** Standard applications (`dolphin`, `konsole`, etc.). Prompted for removal.
*   **Tier 3 (System Daemons):** Core networking and bluetooth (`networkmanager`, `bluez`). Strictly protected from removal.

## Features

*   **Non-Destructive:** Designed to safely add or remove a desktop environment on top of an existing Arch installation.
*   **TTY Autostart:** Automatically configures `.bash_profile` to start Plasma Wayland on VT1 login (safely bypassed if a Display Manager is present).
*   **Deep Cleanup:** Optional purging of all local KDE/Plasma configuration residues during removal.
