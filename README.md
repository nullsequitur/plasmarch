# PlasmArch

> A layered, state-aware installer and manager for deploying a KDE Plasma (Wayland) desktop environment for secondary users on Arch Linux without compromising host minimalism.

---

## 1. Scope & Philosophy

On minimal, keyboard-driven Arch Linux setups (such as those running **Hyprland**, Sway, or tiling window managers), the host system is intentionally kept lean, bloat-free, and terminal-focused. However, sharing a workstation with a family member, colleague, or secondary user often requires a traditional, full-featured desktop environment with familiar GUI applications.

**PlasmArch** bridges this gap:
- **Host Protection:** Keeps the base system lean and keyboard-centric. It deploys KDE Plasma specifically for a designated target user without forcing display managers or desktop services onto the primary user.
- **State-Aware & Layered:** Categorizes packages into three distinct architectural tiers to prevent dependency entanglement.
- **Non-Destructive Life-cycle:** Ensures that installing or uninstalling Plasma never removes vital shared daemons (such as NetworkManager or Bluetooth) and allows standalone GUI applications (like Firefox) to be preserved independently.

---

## 2. 3-Tier Layered Architecture

PlasmArch structures all managed software into three distinct tiers with clear installation and removal policies:

| Tier | Role | Packages | Removal Policy |
| :--- | :--- | :--- | :--- |
| **Tier 1<br>(Core Plasma)** | Base Plasma desktop, Wayland session, session polkit, portals, and desktop applets. | `plasma-desktop`, `plasma-nm`, `bluedevil`, `plasma-pa`, `powerdevil`, `kscreen`, `polkit-kde-agent`, `xdg-desktop-portal-kde` | **Always removed** automatically when uninstallation is triggered. |
| **Tier 2<br>(GUI Applications)** | Common desktop applications, file managers, browsers, viewers, and editors. | `dolphin`, `konsole`, `firefox`, `chromium`, `ark`, `gwenview`, `okular`, `kate` | **Interactive checklist** (per-application toggle during both install and remove). |
| **Tier 3<br>(System Daemons)** | Critical networking and hardware communication daemons shared across environments. | `networkmanager`, `bluez` | **Strictly protected** (never removed or modified during uninstallation). |

### Why Tier 3 Protection Matters
In a typical Arch Linux setup, removing a meta-package or desktop group can inadvertently pull down core networking or Bluetooth stacks. PlasmArch explicitly insulates Tier 3 packages (`networkmanager`, `bluez`) from `pacman -Rns` operations, ensuring that the host's existing networking and peripheral connections remain uninterrupted when tearing down Plasma.

---

## 3. Installation Workflow

To install the Plasma environment, execute:

```bash
chmod +x installer.sh
./installer.sh install
```

### Installation Steps & Features

1. **Privilege & User Validation:**
   - Must be executed by a regular user with `sudo` permissions (running as `root` directly is prevented to avoid misconfigured home paths).
   - Validates that the specified target user exists and has a regular user ID (`UID >= 1000`).
2. **Interactive TUI Checklist:**
   - Displays an interactive menu for Tier 2 application selection.
   - Uses `whiptail` if a graphical TTY is available, with an automatic, resilient fallback to a pure-Bash CLI checklist (`[1] [X] pkg - description`) for headless or non-standard terminals.
   - Can be forced to CLI mode via `PLASMARCH_FORCE_CLI_MENU=1`.
3. **Pre-Installed Host Package Detection:**
   - Queries `pacman -Qq` before rendering the checklist. Any application already present on the host system (e.g., Firefox) is tagged with `(installed)` so you know it will not require extra downloads or disk space.
4. **Targeted Package Installation:**
   - Executes `sudo pacman -S --needed` with Tier 1 core packages, user-selected Tier 2 applications, and Tier 3 system daemons.
5. **TTY Autostart Configuration:**
   - Prompts to configure automated Wayland launch for the target user.
   - Detects the target user's shell profile (`.bash_profile`, `.profile`, or `.zprofile`).
   - Injects an idempotent launch block guarded by `XDG_VTNR=1`:
     ```bash
     # --- KDE PLASMA AUTOSTART ---
     if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "${XDG_VTNR:-0}" = 1 ]; then
       if [ -x /usr/lib/plasma-dbus-run-session-if-needed ]; then
         exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland
       else
         exec /usr/bin/startplasma-wayland
       fi
     fi
     # --- END KDE PLASMA AUTOSTART ---
     ```
   - Automatically leaves other virtual terminals (VT2+) free for the primary user's Hyprland or CLI sessions.

---

## 4. Removal Workflow

To tear down the Plasma environment and restore system state, execute:

```bash
./installer.sh remove
```

### Removal Steps & Features

1. **Automated Tier 1 Core Teardown:**
   - Automatically uninstalls all core Plasma desktop packages (`LAYER1`) via `sudo pacman -Rns`.
2. **Selective GUI Application Removal:**
   - Discovers all currently installed Tier 2 applications and presents an interactive checklist.
   - **The "Dolphin vs. Firefox" Principle:** You can select KDE-specific utilities (like `dolphin`, `konsole`, `ark`) for removal while unchecking standalone applications (like `firefox` or `chromium`) to keep them available for the host system.
   - Displays a green summary of all preserved GUI applications upon completion.
3. **Strict Tier 3 Preservation:**
   - Verifies that `networkmanager` and `bluez` remain untouched.
4. **Idempotent Autostart Removal:**
   - Locates the bounded autostart block between `# --- KDE PLASMA AUTOSTART ---` and `# --- END KDE PLASMA AUTOSTART ---` and purges it cleanly from the target user's profile without altering any pre-existing environment variables.
5. **User Remnant Deep Cleanup:**
   - Prompts for confirmation to optionally purge orphaned user-level KDE/Plasma cache and configuration directories:
     - `~/.config/` (`plasma*`, `kde*`, `kwin*`, `dolphinrc`, `konsolerc`, `arkrc`, `gwenviewrc`)
     - `~/.local/share/` (`plasma*`, `dolphin*`, `konsole*`, `ark*`, `gwenview*`)
     - `~/.cache/` (`plasma*`, `kde*`, `kwin*`)

---

## 5. Automated Testing

PlasmArch includes a comprehensive mock unit test suite in `tests/test_installer.sh`. 

The test runner operates in an isolated temporary sandbox (`mktemp -d`), mocking `pacman` and `sudo` commands. It verifies all business logic without needing root privileges or making any changes to the host operating system.

### Running the Test Suite

```bash
chmod +x tests/test_installer.sh
./tests/test_installer.sh
```

### Test Coverage

The test suite validates:
1. **Privilege Checks:** Rejection when executed directly as root (`EUID=0`).
2. **User Validation:** Strict validation of username formatting, existence in `/etc/passwd`, and rejection of system accounts (`UID < 1000`).
3. **Dynamic Home & Shell Resolution:** Accurate resolution of home directories and login profiles across Bash and Zsh.
4. **Array Filtering:** Ensuring `pacman -Rns` is only invoked with packages that are actually installed, avoiding pacman errors.
5. **Autostart Life-cycle:** Ingestion and clean removal of marker blocks without file corruption.
6. **TUI Checklist Engine:** Default confirmation, single and multi-item toggling (`1, 3`), select-all (`a`), and select-none (`n`) operations in pure-Bash fallback mode.
7. **Selective Removal:** Verifying that Tier 1 is purged, selected Tier 2 apps (`dolphin`) are removed, unselected Tier 2 apps (`firefox`) are strictly preserved, and Tier 3 daemons are never touched.
8. **Categorized Installation:** Verifying installation queues, default selections, and detection of host pre-installed packages.

---

## 6. Project Structure

```text
PlasmArch/
├── installer.sh          # Main entrypoint script (install | remove)
├── README.md             # Project documentation and architectural overview
└── tests/
    └── test_installer.sh # Isolated mock unit test suite
```

---

## 7. Prerequisites & Best Practices

- **Arch Linux:** Target host running an up-to-date Arch Linux installation.
- **Target User Pre-creation:** The target user account must exist prior to running the installer:
  ```bash
  sudo useradd -m -G wheel <username>
  sudo passwd <username>
  ```
- **Execution Privileges:** Always run `./installer.sh` from your regular user account. Do not invoke with `sudo ./installer.sh`.
