#!/usr/bin/env bash
# niri-dms-setup.sh
# Minimal Niri + Dux Modular Shell (DMS, formerly DankMaterialShell) desktop
# on a Fedora Everything Network Install.
#
# Covers: Anaconda software selection notes, first dnf upgrade, Dux Labs COPRs,
# niri + Dux Greeter (dms-greeter) login, NetworkManager, PipeWire, Bluetooth,
# portals, and a niri config that includes the official DMS fragments.
#
# ---------------------------------------------------------------------------
# 0. Fedora Everything Network Install (Anaconda)
# ---------------------------------------------------------------------------
# Download the Everything / Network Install ISO from:
#   https://fedoraproject.org/misc
#   (Fedora Everything Network Install — not Workstation Live, not Server netinst)
#
# Write it to USB (example):
#   sudo dd if=Fedora-Everything-netinst-x86_64-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
#
# Boot the USB, then in Anaconda:
#   1. Language + keyboard
#   2. Network & Host Name  — connect now (this ISO pulls packages from mirrors)
#   3. Installation Destination — Btrfs is a good default; use the whole disk or
#      custom partitions. Encryption is optional.
#   4. Software Selection:
#        Environment:  "Minimal Install"  or  "Custom Operating System"
#        Add-ons:      none. Do not pick GNOME, KDE, XFCE, or any other DE.
#        Optional:     "Standard" utilities only if you want extra CLI tools.
#   5. User Creation — create a regular admin user, check "Make this user
#      administrator". Root password optional.
#   6. Begin Installation, reboot when asked.
#
# First boot is a TTY. Log in as the user you created, then:
#   chmod +x niri-dms-setup.sh
#   ./niri-dms-setup.sh
#
# Requirements
#   - Minimal Fedora from Everything Network Install (no desktop environment)
#   - Working internet
#   - Run as that user, not as root
#
# Sources
#   niri (official Fedora repos / Dux repo) + DMS / dux-greeter (Dux Labs COPRs)
#   Official quick start: https://niri-wm.github.io/niri/Getting-Started.html
#   DMS compositor setup:  https://duxlabs.dev/docs/dms/compositors
#   DMS CLI setup:         https://duxlabs.dev/docs/dms/cli-setup
#   Greeter installation:  https://duxlabs.dev/docs/dms-greeter/installation
#   Fedora Dux repo:       https://duxlabs.dev/docs/repo
#   niri config includes:  https://github.com/niri-wm/niri/wiki/Configuration:-Include
#
# Notes on this revision (rev5)
#   - Two different commands, do not mix them:
#       greetd default_session (login UI) =
#         dms-greeter --command niri -C /etc/greetd/niri.kdl
#       session after password =
#         niri-session   (from /usr/share/wayland-sessions/niri.desktop)
#   - Config includes require niri >= 25.11; older niri gets a standalone file.
#   - Includes are `optional=true` where niri supports it (>= 26.04); older
#     niri gets plain includes. Duplicate binds are stripped when
#     dms/binds.kdl already owns the key. niri validate runs before reboot.
#   - getty@tty1 is disabled but never stopped (script often runs on tty1).
#   - DMS is started once: `systemctl --user add-wants niri.service dms`.
#   - `dms setup` is headless only (stdin closed). No interactive TUI fallback.
#   - cups + cups-pk-helper for the DMS printer panel. No blueman / nm-applet /
#     polkit-gnome; DMS owns those UIs.
#
# rev5 fixes
#   - `set -E` so the ERR trap actually fires inside functions (before, any
#     failure inside a function exited silently, defeating on_err).
#   - Root-owned files are written via mktemp, not fixed /tmp names (symlink
#     race), and no longer log "Wrote /tmp/..." for files that land elsewhere.
#   - User config writes are idempotent (no new .bak on every identical re-run)
#     and alacritty.toml is never clobbered if it already exists (dms setup
#     --terminal alacritty may have put its theme import there).
#   - COPR: dnf5 needs dnf5-plugins, not just dnf-plugins-core.
#   - seatd removed: logind already provides the seat, and a running seatd can
#     be picked first by libseat and then refuse the user (not in `seat` group).
#   - ${USER} replaced by `id -un` (unset under `set -u` in some shells); the
#     login user is no longer added to the `input` group (keylogger-grade
#     access, not needed with logind).
#   - greeter group fix runs AFTER dms-greeter enable, when the user exists.
#   - Redundant fallback greetd config block removed (pin_greetd_command
#     already writes it).
#   - Bind-key parser tracks brace depth (multi-line binds no longer end the
#     binds block early) and normalizes modifier order (Shift+Mod+X == Mod+Shift+X).
#   - `add-wants` failure no longer aborts the script; sudo keepalive added so
#     long upgrades don't re-prompt for a password mid-run.
#   - pipefail/SIGPIPE-prone `| grep -q` pipelines replaced.
#   - Stray backslashes in the rendered KDL comment removed.
#
# Notes on this revision (rev6)
#   - Switched to the official Dux Labs COPRs (duxlabs/dux-repo + duxlabs/dms);
#     the legacy avengemedia repos are kept only as a fallback.
#   - Greeter package is now `dux-greeter`; legacy `dms-greeter` is a fallback.
#   - `dms-greeter install --yes` (or `enable`) now performs the full greeter
#     setup, including ACLs and theme sync; `dms-greeter status` verifies it.
#     Greeter setup moved AFTER `dms setup` so the DMS config already exists.
#   - niri `include` needs >= 25.11, but `optional=true` needs >= 26.04. The
#     script detects both and emits plain includes on 25.11-26.03.
#   - Added the new DMS fragments `dms/input.kdl` and `dms/binds-next.kdl` in
#     the include order recommended by DMS (binds-next before binds).
#   - Added QT_QPA_PLATFORMTHEME_QT6 and ~/.config/environment.d/90-dms.conf.
#   - DMS shell app-id changed to dev.duxlabs.shell; the wallpaper bind now
#     uses the current `dms ipc call dash toggle wallpaper` command.
#   - Fixed: a final `niri validate` failure now fails the script instead of
#     printing "installed"; Bluetooth service failure is no longer fatal.
#   - Renamed the script to niri-dms-setup.sh and added a Fedora >= 43 check.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

readonly SCRIPT_NAME="niri-dms-setup"
readonly ACCENT="#89b4fa"
USER_NAME=$(id -un)
SUDO_KEEPALIVE_PID=""

# Minimum niri version that understands `include` in config.kdl (25.11).
readonly NIRI_INCLUDE_MIN_MAJOR=25
readonly NIRI_INCLUDE_MIN_MINOR=11
# `optional=true` on includes arrived later, in niri 26.04.
readonly NIRI_OPTIONAL_MIN_MAJOR=26
readonly NIRI_OPTIONAL_MIN_MINOR=4

# Set by detect_niri_features() / setup_dms_fragments().
NIRI_SUPPORTS_INCLUDE=0
NIRI_SUPPORTS_OPTIONAL_INCLUDE=0
DMS_FRAGMENTS=()
DMS_HAS_BINDS=0
DMS_BOUND_KEYS=()

log()  { printf '\n\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

# Fail loudly and say where, instead of exiting silently mid-way through.
# Needs `set -E` (above) to fire inside functions.
on_err() {
    local code=$? line=${1:-?}
    printf '\n\033[1;31m  ✗\033[0m %s failed at line %s (exit %s).\n' \
        "${SCRIPT_NAME}" "${line}" "${code}" >&2
    printf '    The script is re-runnable: fix the cause and run it again.\n' >&2
    exit "${code}"
}
trap 'on_err "${LINENO}"' ERR

cleanup() {
    if [[ -n ${SUDO_KEEPALIVE_PID} ]]; then
        kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

need_user() {
    if [[ ${EUID} -eq 0 ]]; then
        die "Run this as a regular user with sudo, not as root. User configs must land in your home directory."
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        die "sudo is required. From a root shell: dnf install -y sudo && usermod -aG wheel ${USER_NAME}"
    fi
    sudo -v || die "sudo authentication failed."

    # Keep the sudo timestamp fresh: a big dnf upgrade can outlast the default
    # 5-minute window and re-prompt in the middle of an unattended run.
    (
        while kill -0 "$$" 2>/dev/null; do
            sudo -n true 2>/dev/null || exit 0
            sleep 50
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
}

need_fedora() {
    [[ -f /etc/os-release ]] || die "/etc/os-release missing."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == fedora ]] || die "This script is for Fedora Linux (found ID=${ID:-unknown})."

    # The Dux Labs COPRs carry packages for Fedora 43/44/45 and Rawhide.
    # Fail early with a clear message instead of a confusing dnf "no package".
    local ver=${VERSION_ID:-0}
    if [[ ${ver} =~ ^[0-9]+$ ]] && (( 10#${ver} < 43 )); then
        die "Dux packages need Fedora 43+ (found Fedora ${ver})."
    fi

    ok "Fedora ${VERSION_ID:-unknown} (${VARIANT_ID:-unknown})"
}

backup_if_exists() {
    local path=$1
    if [[ -e ${path} && ! -L ${path} ]]; then
        local bak
        bak="${path}.bak.$(date +%Y%m%d%H%M%S)"
        mv "${path}" "${bak}"
        warn "Moved existing ${path} -> ${bak}"
    fi
}

# Write stdin to a user-owned file. Identical content is left alone; differing
# content backs the old file up first. Symlinks are written through.
write_file() {
    local dest=$1 tmp
    mkdir -p "$(dirname "${dest}")"
    tmp=$(mktemp)
    cat > "${tmp}"
    if [[ -f ${dest} ]] && cmp -s "${tmp}" "${dest}"; then
        rm -f "${tmp}"
        ok "Unchanged ${dest}"
        return 0
    fi
    backup_if_exists "${dest}"
    cat "${tmp}" > "${dest}"
    rm -f "${tmp}"
    ok "Wrote ${dest}"
}

# Write stdin to a root-owned file via a private mktemp file (no predictable
# /tmp names).
write_root_file() {
    local dest=$1 mode=${2:-0644} tmp
    tmp=$(mktemp)
    cat > "${tmp}"
    # Root-owned files are rewritten on re-runs too (greetd config, niri.kdl).
    # Keep one timestamped copy so a bad rewrite is reversible.
    if [[ -f ${dest} ]]; then
        sudo cp -a "${dest}" "${dest}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    sudo install -D -m "${mode}" "${tmp}" "${dest}"
    rm -f "${tmp}"
    ok "Wrote ${dest}"
}

dnf_install() {
    sudo dnf install -y --setopt=install_weak_deps=True "$@"
}

# Install what is available; skip names this Fedora release does not ship.
# One transaction. dnf5 (F41+) has --skip-unavailable; dnf4 has --setopt=strict=0.
dnf_install_available() {
    if sudo dnf install -y --skip-unavailable --setopt=install_weak_deps=True "$@"; then
        return 0
    fi
    warn "--skip-unavailable not accepted; retrying with strict=0"
    if sudo dnf install -y --setopt=strict=0 --setopt=install_weak_deps=True "$@"; then
        return 0
    fi
    warn "Bulk install failed; falling back to one package at a time"
    local pkg
    for pkg in "$@"; do
        dnf_install "${pkg}" >/dev/null 2>&1 \
            || warn "Skipping unavailable or broken package: ${pkg}"
    done
}

# ---------------------------------------------------------------------------
# 1. First dnf command: refresh and full upgrade
# ---------------------------------------------------------------------------
dnf_bootstrap() {
    log "Tuning DNF and upgrading the minimal base"

    # max_parallel_downloads only. Do not set defaultyes=True: this script
    # already passes -y, and defaultyes would confirm future interactive
    # `dnf remove` / `dnf autoremove` with a bare Enter.
    if [[ -f /etc/dnf/dnf.conf ]] && ! grep -Eq '^[[:space:]]*max_parallel_downloads[[:space:]]*=' /etc/dnf/dnf.conf; then
        printf 'max_parallel_downloads=10\n' | sudo tee -a /etc/dnf/dnf.conf >/dev/null
        ok "Set DNF max_parallel_downloads=10"
    fi

    sudo dnf upgrade --refresh -y
    sudo dnf group upgrade core -y || true
    ok "dnf upgrade complete"
}

# ---------------------------------------------------------------------------
# 2. COPRs for Dux Modular Shell and Dux Greeter
#    niri itself is in official Fedora repos (F43+).
# ---------------------------------------------------------------------------
enable_coprs() {
    log "Enabling Dux Labs COPRs for DMS and Dux Greeter"
    # dnf5 (F41+) ships `copr` in dnf5-plugins; dnf4 in dnf-plugins-core.
    # Install whichever exists on this release.
    dnf_install_available dnf5-plugins dnf-plugins-core
    sudo dnf copr --help >/dev/null 2>&1 \
        || die "'dnf copr' is unavailable even after installing the plugin packages."

    # Official repos since the DankMaterialShell -> Dux Modular Shell rename.
    # Enabling duxlabs/dms also pulls in duxlabs/dux-repo automatically, but
    # enabling it explicitly is harmless and makes the dependency obvious.
    if sudo dnf copr enable -y duxlabs/dux-repo \
        && sudo dnf copr enable -y duxlabs/dms; then
        ok "COPR repos enabled: duxlabs/dux-repo, duxlabs/dms"
        return 0
    fi

    # Fallback for a Fedora release or mirror that has not picked up the new
    # COPRs yet. The legacy repos still carry the DMS 1.x packages.
    warn "Dux Labs COPRs unavailable; falling back to legacy AvengeMedia COPRs"
    sudo dnf copr enable -y avengemedia/dms \
        || die "Could not enable any DMS COPR repo."
    sudo dnf copr enable -y avengemedia/danklinux || true
    ok "COPR repos enabled: avengemedia/dms, avengemedia/danklinux"
}

# ---------------------------------------------------------------------------
# 3. Desktop package set
#    DMS replaces Waybar, Mako, Fuzzel, Swaylock, Swayidle, and the polkit agent.
# ---------------------------------------------------------------------------
install_packages() {
    log "Installing Niri, DMS, greeter, and the minimal desktop stack"

    local required=(
        niri
        quickshell
        xwayland-satellite
        dms
        greetd
        alacritty
    )

    dnf_install "${required[@]}"

    # The greeter package was renamed `dms-greeter` -> `dux-greeter` in DMS 2.x.
    # Both ship the `dms-greeter` CLI. Prefer the new name, fall back to old.
    if ! dnf_install dux-greeter; then
        warn "dux-greeter not available; trying legacy dms-greeter package"
        dnf_install dms-greeter
    fi
    ok "Niri + DMS + Dux Greeter installed"

    local extras=(
        # portals + secrets + polkit
        xdg-desktop-portal
        xdg-desktop-portal-gtk
        xdg-desktop-portal-gnome
        gnome-keyring
        gnome-keyring-pam
        polkit
        # NOTE: no polkit-gnome. DMS ships its own polkit agent; running two
        # agents means they race for the same D-Bus name and auth dialogs
        # intermittently never appear.

        # networking (Everything minimal often has no NM)
        NetworkManager
        NetworkManager-wifi
        NetworkManager-tui
        NetworkManager-bluetooth
        nm-connection-editor
        # no network-manager-applet: DMS has a network panel, and a tray
        # applet with no tray is just a failed spawn at every login.

        # audio
        pipewire
        pipewire-pulseaudio
        pipewire-alsa
        pipewire-jack-audio-connection-kit
        wireplumber
        pavucontrol
        playerctl
        alsa-sof-firmware

        # bluetooth stack only. No blueman: DMS has the bluetooth panel, and
        # blueman-applet has no tray to dock into. Install blueman later if
        # you want the standalone manager (`sudo dnf install blueman`).
        bluez
        bluez-tools

        # clipboard / idle helpers DMS can use
        wl-clipboard
        cliphist
        brightnessctl
        udiskie

        # files + browser
        xdg-user-dirs
        xdg-utils
        nautilus
        gvfs
        gvfs-mtp
        sushi
        firefox

        # fonts + icons + gtk
        google-noto-sans-fonts
        google-noto-sans-cjk-fonts
        google-noto-serif-fonts
        google-noto-emoji-fonts
        jetbrains-mono-fonts
        adwaita-icon-theme
        papirus-icon-theme
        adw-gtk3-theme

        # wayland / gpu (Intel + AMD; NVIDIA needs RPM Fusion later)
        mesa-dri-drivers
        mesa-vulkan-drivers
        mesa-libGL
        vulkan-loader
        intel-media-driver
        libva
        qt5-qtwayland
        qt6-qtwayland
        qt6-qtmultimedia

        # DMS recommended companions (from COPR / Fedora)
        cava
        matugen
        accountsservice
        power-profiles-daemon
        linux-firmware

        # `dms doctor` optional-feature packages. None of these are required —
        # dms runs fine without them — they just light up specific panels.
        cups                    # cupsd; required for the printer panel
        cups-pk-helper          # polkit helper the DMS printer panel talks to
        qt6-qtimageformats      # WebP/TIFF/GIF/JP2/ICNS previews
        kf6-kimageformats       # AVIF/HEIF/JXL/EXR previews
        i2c-tools               # External monitor brightness via DDC/CI.
                                # Also needs the user in the `i2c` group and
                                # the i2c-dev kernel module — handled in
                                # configure_system(), not by this package alone.
        khal                    # CalDAV/local calendar events in the dash calendar

        # small utilities
        git
        jq
        curl
        wget
        ImageMagick
        grim
        slurp
        rfkill
    )

    dnf_install_available "${extras[@]}"
    ok "Companion packages installed"
}

# ---------------------------------------------------------------------------
# 3b. Feature detection
#     `include` in config.kdl landed in niri 25.11. On anything older, every
#     include line is a syntax error and niri refuses to load the config,
#     which means a black screen at login. Detect instead of assuming.
# ---------------------------------------------------------------------------
detect_niri_features() {
    log "Checking niri capabilities"

    NIRI_SUPPORTS_INCLUDE=0
    NIRI_SUPPORTS_OPTIONAL_INCLUDE=0

    local raw ver major minor
    raw=$(niri --version 2>/dev/null || true)
    ver=$(printf '%s\n' "${raw}" | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)

    if [[ -z ${ver} ]]; then
        warn "Could not parse 'niri --version' (${raw:-no output}); assuming no include support"
        warn "Writing a standalone config; DMS theming fragments will not be applied"
        return 0
    fi

    major=$((10#${ver%%.*}))
    # Strip a leading zero so 25.08 -> 8, not an invalid octal literal.
    minor=$((10#${ver##*.}))

    if (( major > NIRI_INCLUDE_MIN_MAJOR )) \
        || { (( major == NIRI_INCLUDE_MIN_MAJOR )) && (( minor >= NIRI_INCLUDE_MIN_MINOR )); }; then
        NIRI_SUPPORTS_INCLUDE=1
        ok "niri ${ver} supports config includes"
    else
        warn "niri ${ver} predates config includes (need >= ${NIRI_INCLUDE_MIN_MAJOR}.${NIRI_INCLUDE_MIN_MINOR})"
        warn "Writing a standalone config; DMS theming fragments will not be applied"
        return 0
    fi

    # `optional=true` on an include is newer than `include` itself. When it is
    # unsupported, use plain includes: we only include fragments that exist,
    # so a missing-file error cannot occur.
    if (( major > NIRI_OPTIONAL_MIN_MAJOR )) \
        || { (( major == NIRI_OPTIONAL_MIN_MAJOR )) && (( minor >= NIRI_OPTIONAL_MIN_MINOR )); }; then
        NIRI_SUPPORTS_OPTIONAL_INCLUDE=1
        ok "niri ${ver} supports optional=true includes"
    else
        warn "niri ${ver} predates optional=true includes (need >= ${NIRI_OPTIONAL_MIN_MAJOR}.${NIRI_OPTIONAL_MIN_MINOR})"
        warn "Using plain includes for the fragments that exist"
    fi
}

# ---------------------------------------------------------------------------
# 4. System services: login, networking, bluetooth, seat, graphical target
# ---------------------------------------------------------------------------
configure_system() {
    log "Configuring system services"

    # Graphical-session groups for the installing user. Deliberately NOT
    # `input`: with systemd-logind the compositor gets input devices through
    # the seat, and `input` membership would let any process of this user read
    # raw keystrokes. `wheel` is already set by Anaconda; kept for safety.
    sudo usermod -aG video,audio,wheel "${USER_NAME}" || true
    ok "Ensured ${USER_NAME} is in video,audio,wheel"

    # No seatd: systemd-logind already provides seat management, and a running
    # seatd can be preferred by libseat and then deny a user who is not in the
    # `seat` group.

    # DDC/CI external-monitor brightness control (dms doctor: "I2C/DDC").
    # i2c-tools alone is not enough: the i2c-dev module has to be loaded so
    # /dev/i2c-* exists, and the user has to be in the i2c group to read/write
    # those nodes without root. All steps are optional — dms works without
    # them, you just lose external-monitor brightness sliders.
    if command -v i2cdetect >/dev/null 2>&1; then
        sudo modprobe i2c-dev 2>/dev/null || true
        if [[ ! -d /sys/module/i2c_dev ]]; then
            warn "i2c-dev did not load (no I2C-capable GPU/adapter on this machine?)"
        fi
        printf 'i2c-dev\n' | sudo tee /etc/modules-load.d/i2c-dev.conf >/dev/null
        sudo groupadd -f i2c
        sudo usermod -aG i2c "${USER_NAME}" || true
        ok "i2c-dev set to load at boot; ${USER_NAME} added to the i2c group"
        warn "New group membership needs a fresh login (or reboot) to take effect"
    fi

    if systemctl is-enabled NetworkManager.service >/dev/null 2>&1 \
        || rpm -q NetworkManager >/dev/null 2>&1; then
        if systemctl is-enabled systemd-networkd.service >/dev/null 2>&1; then
            sudo systemctl disable --now systemd-networkd.service systemd-networkd.socket || true
            warn "Disabled systemd-networkd so NetworkManager can own the interfaces"
        fi
        if sudo systemctl enable --now NetworkManager.service; then
            ok "NetworkManager enabled"
        else
            warn "NetworkManager failed to start; check 'systemctl status NetworkManager'"
        fi
    fi

    if rpm -q bluez >/dev/null 2>&1; then
        sudo systemctl enable --now bluetooth.service || warn "Bluetooth service failed to start"
        rfkill unblock bluetooth >/dev/null 2>&1 || true
        ok "Bluetooth enabled"
    fi

    if rpm -q power-profiles-daemon >/dev/null 2>&1; then
        sudo systemctl enable --now power-profiles-daemon.service || true
    fi

    if rpm -q cups >/dev/null 2>&1; then
        sudo systemctl enable --now cups.service || true
        ok "CUPS enabled"
    fi

    sudo systemctl set-default graphical.target
    ok "Default target is graphical.target"

    # Leftover display managers, if any. Stopping these is safe: we are not
    # running under them.
    local dm
    for dm in gdm sddm lightdm ly; do
        if [[ -n $(systemctl list-unit-files "${dm}.service" --no-legend 2>/dev/null) ]]; then
            sudo systemctl disable --now "${dm}.service" >/dev/null 2>&1 || true
        fi
    done

    # Greeter setup (greetd config, permissions, theme sync, getty@tty1) lives
    # in setup_greeter(), which runs AFTER `dms setup` so the DMS config files
    # it syncs with actually exist.

    # PipeWire user units start with the graphical session.
    systemctl --user enable pipewire.service pipewire-pulse.service wireplumber.service >/dev/null 2>&1 || true
    ok "PipeWire user units enabled"

    # Official niri + DMS hookup: start DMS only when the niri session starts.
    # This is the ONLY place DMS is started. There is deliberately no
    # `spawn-at-startup "dms" "run"` in config.kdl — that would start a second
    # instance on every normal login.
    if systemctl --user add-wants niri.service dms; then
        ok "systemctl --user add-wants niri.service dms"
    else
        warn "add-wants failed (no user systemd bus in this shell?)"
        warn "After your first graphical login run: systemctl --user add-wants niri.service dms"
    fi
}

write_greetd_niri_kdl() {
    # Minimal compositor config for the greeter seat (user "greeter"),
    # not the logged-in session. DMS_RUN_GREETER tells Quickshell to
    # draw the login UI instead of the desktop shell.
    write_root_file /etc/greetd/niri.kdl <<'EOF'
hotkey-overlay {
    skip-at-startup
}

environment {
    DMS_RUN_GREETER "1"
}

gestures {
    hot-corners {
        off
    }
}

layout {
    background-color "#000000"
}
EOF
}

pin_greetd_command() {
    # Known-good greetd *greeter* command. --command must be the compositor
    # name "niri". niri-session is what the user picks AFTER the password
    # (wayland-sessions/niri.desktop), not what hosts the login UI.
    local cmd='dms-greeter --command niri -C /etc/greetd/niri.kdl'
    local current=""
    if [[ -f /etc/greetd/config.toml ]]; then
        current=$(grep -E '^[[:space:]]*command[[:space:]]*=' /etc/greetd/config.toml | tail -n1 || true)
    fi
    if grep -q -- '--command niri' <<<"${current}" \
        && ! grep -q 'niri-session' <<<"${current}" \
        && grep -q '/etc/greetd/niri.kdl' <<<"${current}"; then
        ok "greetd command already pinned: ${cmd}"
    else
        if [[ -n ${current} ]]; then
            warn "greetd command was: ${current}"
            warn "Rewriting to --command niri -C /etc/greetd/niri.kdl"
        fi
        write_root_file /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
user = "greeter"
command = "${cmd}"
EOF
    fi

    local desk=/usr/share/wayland-sessions/niri.desktop
    if [[ -f ${desk} ]] && grep -q '^Exec=niri-session' "${desk}"; then
        ok "After-login session is niri-session (${desk})"
    elif [[ -f ${desk} ]]; then
        warn "${desk} Exec= is not niri-session; pick Niri in the greeter anyway"
        warn "TTY fallback remains: niri-session"
    else
        warn "No ${desk}; after password the greeter may not list a Niri session"
        warn "TTY fallback: Ctrl+Alt+F2, then niri-session"
    fi
}

# ---------------------------------------------------------------------------
# 4b. Greeter setup
#     Runs after `dms setup`: the official helper syncs the user's DMS theme,
#     wallpapers and ACLs, so those files must already exist.
# ---------------------------------------------------------------------------
setup_greeter() {
    log "Configuring Dux Greeter (dms-greeter) and greetd"

    command -v dms-greeter >/dev/null 2>&1 \
        || die "dms-greeter CLI is missing after package install."

    # Minimal compositor config for the greeter seat (user "greeter").
    write_greetd_niri_kdl

    # `dms-greeter install` is the documented one-shot setup: it writes
    # /etc/greetd/config.toml, disables other display managers, sets up the
    # greeter user, ACLs and theme sync, and enables greetd. --yes keeps it
    # unattended. Fall back to `enable` on older Dux Greeter releases.
    if dms-greeter install --yes </dev/null \
        || dms-greeter install </dev/null \
        || sudo dms-greeter enable --command niri >/dev/null 2>&1 \
        || sudo dms-greeter enable >/dev/null 2>&1; then
        ok "dms-greeter setup ran"
    else
        warn "dms-greeter setup failed; writing greetd config by hand"
    fi

    # Ensure the greeter user can access the GPU and input devices. Missing
    # video/render/input membership is a frequent cause of black screens or
    # "greeter exited without creating session" on laptops.
    if id greeter >/dev/null 2>&1; then
        sudo usermod -aG video,render,input,audio greeter 2>/dev/null || true
        ok "Ensured greeter user is in video,render,input,audio"
    else
        warn "greeter user does not exist; greetd may fail to start the greeter"
    fi

    # The installing user needs the `greeter` group for theme sync.
    sudo usermod -aG greeter "${USER_NAME}" 2>/dev/null || true

    # Force the known-good greeter command, including -C so the greeter seat
    # uses /etc/greetd/niri.kdl (DMS_RUN_GREETER=1) instead of the user config.
    pin_greetd_command

    sudo systemctl enable greetd.service
    ok "greetd enabled"

    # greetd wants VT1, so getty@tty1 has to go. Two deliberate choices here:
    #
    #   1. `disable` WITHOUT `--now`. This script is documented to run from the
    #      TTY after first boot, i.e. tty1. agetty execs login which execs your
    #      shell as the unit's main process, so `stop` would SIGTERM the shell
    #      running this script, somewhere mid-install. The reboot at the end
    #      does the actual switchover.
    #   2. Only disable it once /etc/greetd/config.toml actually exists, so a
    #      failed greeter setup still leaves a login prompt on VT1.
    if [[ -s /etc/greetd/config.toml ]]; then
        sudo systemctl disable getty@tty1.service >/dev/null 2>&1 || true
        ok "getty@tty1 disabled for next boot (greetd takes VT1)"
    else
        warn "/etc/greetd/config.toml is missing or empty — leaving getty@tty1 enabled"
        warn "You will get a text login on VT1; start the session with: niri-session"
    fi

    # Report sync status now, while there is still a shell to fix things from.
    if dms-greeter status </dev/null; then
        ok "dms-greeter status passed"
    else
        warn "dms-greeter status reported problems (see above)"
        warn "You can retry later with: dms-greeter sync"
    fi
}

# ---------------------------------------------------------------------------
# 5. XDG dirs
# ---------------------------------------------------------------------------
prepare_home() {
    log "Preparing XDG directories"
    mkdir -p \
        "${HOME}/.config" \
        "${HOME}/.local/bin" \
        "${HOME}/.local/share" \
        "${HOME}/.config/niri" \
        "${HOME}/.config/xdg-desktop-portal" \
        "${HOME}/.config/environment.d" \
        "${HOME}/.config/systemd/user" \
        "${HOME}/Pictures/Wallpapers" \
        "${HOME}/Pictures/Screenshots"
    if command -v xdg-user-dirs-update >/dev/null 2>&1; then
        xdg-user-dirs-update
        ok "XDG user directories updated"
    fi
}

# ---------------------------------------------------------------------------
# 6. DMS compositor fragments + niri config
#    dms setup writes ~/.config/niri/dms/{binds,colors,layout,...}.kdl
# ---------------------------------------------------------------------------
setup_dms_fragments() {
    log "Deploying DMS compositor defaults"

    if ! command -v dms >/dev/null 2>&1; then
        die "dms CLI is missing after package install."
    fi

    mkdir -p "${HOME}/.config/niri/dms"

    # Documented non-interactive path for scripts and installers.
    # --skip-existing warns and moves on instead of failing when a config is
    # already there; without it (and without --force) the command exits
    # non-zero by design so scripts notice. The two flags cannot be combined.
    # --terminal also wires the terminal into the generated keybinds.
    #
    # stdin is explicitly closed (</dev/null) on every attempt. There is
    # deliberately NO fallback to plain interactive `dms setup`: an unattended
    # run hanging with no error is worse than one that stops and tells you why.
    if dms setup headless --compositor niri --terminal alacritty --skip-existing </dev/null; then
        ok "dms setup headless completed (terminal: alacritty)"
    elif dms setup headless --compositor niri --skip-existing </dev/null; then
        ok "dms setup headless completed (no terminal config)"
    else
        warn "dms setup headless failed both attempts (see output above)"
        warn "Continuing with whatever fragments exist; includes are optional where supported"
        warn "You can retry by hand later: dms setup headless --compositor niri"
    fi

    # Record which fragments actually exist AND have content. Only these get
    # included, and every include is optional where the installed niri supports it.
    local f name
    DMS_FRAGMENTS=()
    DMS_HAS_BINDS=0
    # Order matters: DMS recommends colors, layout, alttab, then binds-next
    # (version-dependent binds) BEFORE binds so user binds win. input.kdl and
    # the remaining fragments are included as well; every include below is
    # last in config.kdl so DMS values win on merge.
    for name in colors layout alttab input binds-next binds windowrules cursor outputs; do
        f="${HOME}/.config/niri/dms/${name}.kdl"
        if [[ -s ${f} ]]; then
            DMS_FRAGMENTS+=("${name}")
            if [[ ${name} == binds ]]; then DMS_HAS_BINDS=1; fi
        fi
    done

    if ((${#DMS_FRAGMENTS[@]})); then
        ok "DMS fragments found: ${DMS_FRAGMENTS[*]}"
    else
        warn "No DMS fragments under ~/.config/niri/dms — config.kdl will stand alone"
    fi

    collect_dms_bound_keys
}

# niri treats a second bind on the same key as a PARSING FAILURE, not a
# warning, so config.kdl must not redefine anything dms/binds.kdl binds.
# Keys are normalized so modifier order and aliases do not defeat the match:
# "Shift+Mod+E", "Super+Shift+e" and "Mod+Shift+E" all compare equal.
normalize_bind_key() {
    local k=${1,,}
    k=${k//super+/mod+}
    k=${k//win+/mod+}
    k=${k//control+/ctrl+}
    local -a parts=()
    IFS='+' read -ra parts <<<"${k}"
    local n=${#parts[@]}
    if (( n <= 1 )); then
        printf '%s' "${k}"
        return 0
    fi
    local mods
    mods=$(printf '%s\n' "${parts[@]:0:n-1}" | sort | paste -sd+ -)
    printf '%s+%s' "${mods}" "${parts[n-1]}"
}

# Read dms/binds.kdl and record every key it takes. Brace depth is tracked, so
# a bind whose body spans several lines does not end the binds block early.
# Only depth-1 lines (direct children of `binds {`) are treated as binds.
# Anything at depth 1 that is not recognisable gets a visible warning rather
# than a silent skip, since an unrecorded bind resurfaces later as a puzzling
# `niri validate` duplicate-bind failure.
collect_dms_bound_keys() {
    DMS_BOUND_KEYS=()
    local frag="${HOME}/.config/niri/dms/binds.kdl"
    [[ -s ${frag} ]] || return 0

    local line key opens closes
    local depth=0 in_binds=0 unparsed=0
    while IFS= read -r line; do
        [[ ${line} =~ ^[[:space:]]*// ]] && continue
        [[ -z ${line//[[:space:]]/} ]] && continue

        if (( ! in_binds )); then
            if [[ ${line} =~ ^[[:space:]]*binds[[:space:]]*\{ ]]; then
                in_binds=1
                depth=1
            fi
            continue
        fi

        if (( depth == 1 )); then
            if [[ ${line} == *"{"* ]]; then
                key=${line#"${line%%[![:space:]]*}"}
                key=${key%%[[:space:]]*}
                if [[ ${key} =~ ^[A-Za-z][A-Za-z0-9_+]*$ ]]; then
                    DMS_BOUND_KEYS+=("$(normalize_bind_key "${key}")")
                else
                    unparsed=$((unparsed + 1))
                fi
            elif [[ ! ${line} =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
                unparsed=$((unparsed + 1))
            fi
        fi

        opens=${line//[^\{]/}
        closes=${line//[^\}]/}
        depth=$(( depth + ${#opens} - ${#closes} ))
        if (( depth <= 0 )); then
            in_binds=0
            depth=0
        fi
    done < "${frag}"

    if ((unparsed)); then
        warn "${unparsed} line(s) in dms/binds.kdl did not match the expected bind format"
        warn "Those keys are NOT in the exclusion list — if niri validate fails with a"
        warn "duplicate-bind error, check dms/binds.kdl by hand against config.kdl"
    fi

    if ((${#DMS_BOUND_KEYS[@]})); then
        ok "dms/binds.kdl binds ${#DMS_BOUND_KEYS[@]} keys; config.kdl will not redefine them"
    elif ((! unparsed)); then
        warn "Could not find any binds in dms/binds.kdl"
    fi
}

bind_is_taken() {
    local want candidate
    want=$(normalize_bind_key "$1")
    for candidate in ${DMS_BOUND_KEYS[@]+"${DMS_BOUND_KEYS[@]}"}; do
        [[ ${candidate} == "${want}" ]] && return 0
    done
    return 1
}

# Passes bind lines through, commenting out any key dms/binds.kdl already owns.
filter_binds() {
    local skip_known=$1 line key
    while IFS= read -r line; do
        if (( ! skip_known )) || [[ ${line} =~ ^[[:space:]]*// ]] || [[ ${line} != *"{"* ]]; then
            printf '%s\n' "${line}"
            continue
        fi
        key=${line#"${line%%[![:space:]]*}"}
        key=${key%%[[:space:]]*}
        if bind_is_taken "${key}"; then
            printf '    // %s omitted: already bound in dms/binds.kdl\n' "${key}"
        else
            printf '%s\n' "${line}"
        fi
    done
}

# Renders config.kdl. Two toggles, because niri is strict about both:
#
#   $2 skip_known_binds : 1 = comment out any bind that dms/binds.kdl already
#        owns. niri treats a second bind on the same key as a PARSING FAILURE,
#        so with the fragment included this is not optional.
#   $3 use_includes : 1 = append include lines for whichever DMS fragments
#        exist. Requires niri >= 25.11.
#   $4 use_optional : 1 = write `include optional=true "..."`. Requires niri
#        >= 26.04. On 25.11-26.03 plain includes are used instead; only
#        fragments that exist are ever included, so no missing-file error.
#
# The heredocs are quoted ('KDL_HEAD') so the shell does not touch backslashes,
# `$` or backticks in the KDL. Values are substituted afterwards via @TOKEN@.
render_niri_config() {
    local dest=$1 skip_known=$2 use_includes=$3 use_optional=$4
    mkdir -p "$(dirname "${dest}")"

    {
    cat <<'KDL_HEAD'
// Niri + Dux Modular Shell (DMS) config written by @SCRIPT_NAME@.
// Live-reloads on save. Validate with: niri validate
// Docs: https://niri-wm.github.io/niri/Configuration:-Introduction
// DMS:  https://danklinux.com/docs/dankmaterialshell/compositors
//
// Do not spawn waybar / mako / fuzzel here. DMS owns the shell.
// Do not spawn dms here either: it is started by
//   systemctl --user add-wants niri.service dms

input {
    keyboard {
        xkb {
            // layout "us"
            // options "ctrl:nocaps,compose:ralt"
        }
        numlock
    }

    touchpad {
        tap
        natural-scroll
        dwt
    }

    mouse {
    }

    warp-mouse-to-focus
    focus-follows-mouse max-scroll-amount="0%"
}

// Outputs are auto-configured. Pin a mode after running: niri msg outputs
//
// output "eDP-1" {
//     mode "1920x1080@60"
//     scale 1.0
//     variable-refresh-rate on-demand=true
// }

layout {
    gaps 8
    center-focused-column "on-overflow"
    always-center-single-column
    background-color "transparent"

    preset-column-widths {
        proportion 0.33333
        proportion 0.5
        proportion 0.66667
    }

    default-column-width { proportion 0.5; }

    // These colors are a fallback. If dms/colors.kdl is included below, it is
    // merged last and wins.
    focus-ring {
        width 2
        active-color "@ACCENT@"
        inactive-color "#313244"
        urgent-color "#f38ba8"
    }

    border {
        off
        width 2
        active-color "@ACCENT@"
        inactive-color "#313244"
        urgent-color "#f38ba8"
    }

    shadow {
        on
        softness 30
        spread 4
        offset x=0 y=6
        color "#00000066"
    }

    struts {
        left 6
        right 6
        top 6
        bottom 6
    }
}

// DMS is started by systemd:  systemctl --user add-wants niri.service dms
// There is intentionally no `spawn-at-startup "dms" "run"` here. With both,
// a normal login starts two shells.
//
// No polkit-gnome either: DMS provides the polkit agent. Two agents fight over
// the same D-Bus name and auth prompts stop appearing at random.
//
// No nm-applet / blueman-applet: DMS has network and bluetooth panels, and
// there is no system tray for them to dock into.
spawn-at-startup "udiskie" "--no-tray"
spawn-sh-at-startup "gnome-keyring-daemon --start --components=secrets,ssh"

hotkey-overlay {
    skip-at-startup
}

prefer-no-csd

screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

environment {
    XDG_CURRENT_DESKTOP "niri"
    XDG_SESSION_TYPE "wayland"
    XDG_SESSION_DESKTOP "niri"
    QT_QPA_PLATFORM "wayland"
    QT_WAYLAND_DISABLE_WINDOWDECORATION "1"
    QT_QPA_PLATFORMTHEME "gtk3"
    QT_QPA_PLATFORMTHEME_QT6 "gtk3"
    MOZ_ENABLE_WAYLAND "1"
    ELECTRON_OZONE_PLATFORM_HINT "auto"
    _JAVA_AWT_WM_NONREPARENTING "1"
    CLUTTER_BACKEND "wayland"
    SDL_VIDEODRIVER "wayland"
}

cursor {
    xcursor-theme "Adwaita"
    xcursor-size 24
}

overview {
    zoom 0.5
    backdrop-color "#11111b"
}

xwayland-satellite {
    path "xwayland-satellite"
}

window-rule {
    geometry-corner-radius 12
    clip-to-geometry true
}

window-rule {
    match app-id=r#"^org\.wezfurlong\.wezterm$"#
    match app-id="Alacritty"
    // NOT default-column-width {} — an empty block means "let the window pick
    // its own width," which fights layout's default-column-width proportion
    // 0.5 above, so terminals stopped splitting evenly with everything else.
    // Terminals use the same 50% default as any other window.
    draw-border-with-background false
}

window-rule {
    match app-id=r#"firefox$"# title="^Picture-in-Picture$"
    open-floating true
}

window-rule {
    match app-id=r#"^org\.pulseaudio\.pavucontrol$"#
    match app-id=r#"^blueman-manager$"#
    match app-id=r#"^nm-connection-editor$"#
    // DMS 2.x uses dev.duxlabs.shell; keep the old ID for compatibility.
    match app-id=r#"^(dev\.duxlabs\.shell|com\.danklinux\.dms)$"#
    open-floating true
}

layer-rule {
    match namespace="^quickshell$"
    place-within-backdrop true
}

layer-rule {
    match namespace="dms:blurwallpaper"
    place-within-backdrop true
}

binds {
KDL_HEAD

    # Every bind goes through filter_binds, which comments out anything
    # dms/binds.kdl already owns. This covers the terminal bind that
    # `dms setup --terminal alacritty` writes into the fragment.
    filter_binds "${skip_known}" <<'KDL_BINDS'
    Mod+Shift+Slash { show-hotkey-overlay; }

    Mod+Return hotkey-overlay-title="Terminal" { spawn "alacritty"; }
    Mod+T      hotkey-overlay-title="Terminal" { spawn "alacritty"; }
    Mod+B      hotkey-overlay-title="Browser"  { spawn "firefox"; }
    Mod+E      hotkey-overlay-title="Files"    { spawn "nautilus"; }

    // DMS shell, via the official IPC. Any of these that dms/binds.kdl also
    // binds will be commented out automatically when the fragment is included.
    Mod+Space  hotkey-overlay-title="Application Launcher" { spawn "dms" "ipc" "call" "spotlight" "toggle"; }
    Mod+D      hotkey-overlay-title="Application Launcher" { spawn "dms" "ipc" "call" "spotlight" "toggle"; }
    Mod+V      hotkey-overlay-title="Clipboard Manager"    { spawn "dms" "ipc" "call" "clipboard" "toggle"; }
    Mod+N      hotkey-overlay-title="Notification Center"  { spawn "dms" "ipc" "call" "notifications" "toggle"; }
    Mod+Comma  hotkey-overlay-title="Settings"             { spawn "dms" "ipc" "call" "settings" "focusOrToggle"; }
    Mod+M      hotkey-overlay-title="Task Manager"         { spawn "dms" "ipc" "call" "processlist" "focusOrToggle"; }
    Mod+Y      hotkey-overlay-title="Browse Wallpapers"    { spawn "dms" "ipc" "call" "dash" "toggle" "wallpaper"; }
    Super+Alt+L hotkey-overlay-title="Lock"                { spawn "dms" "ipc" "call" "lock" "lock"; }

    XF86AudioRaiseVolume allow-when-locked=true { spawn "dms" "ipc" "call" "audio" "increment" "3"; }
    XF86AudioLowerVolume allow-when-locked=true { spawn "dms" "ipc" "call" "audio" "decrement" "3"; }
    XF86AudioMute        allow-when-locked=true { spawn "dms" "ipc" "call" "audio" "mute"; }
    XF86AudioMicMute     allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"; }

    XF86AudioPlay  allow-when-locked=true { spawn "playerctl" "play-pause"; }
    XF86AudioPause allow-when-locked=true { spawn "playerctl" "play-pause"; }
    XF86AudioStop  allow-when-locked=true { spawn "playerctl" "stop"; }
    XF86AudioPrev  allow-when-locked=true { spawn "playerctl" "previous"; }
    XF86AudioNext  allow-when-locked=true { spawn "playerctl" "next"; }

    XF86MonBrightnessUp   allow-when-locked=true { spawn "dms" "ipc" "call" "brightness" "increment" "5" ""; }
    XF86MonBrightnessDown allow-when-locked=true { spawn "dms" "ipc" "call" "brightness" "decrement" "5" ""; }

    Mod+O repeat=false { toggle-overview; }
    Mod+Q repeat=false { close-window; }

    Mod+Left  { focus-column-left; }
    Mod+Down  { focus-window-down; }
    Mod+Up    { focus-window-up; }
    Mod+Right { focus-column-right; }
    Mod+H     { focus-column-left; }
    Mod+J     { focus-window-down; }
    Mod+K     { focus-window-up; }
    Mod+L     { focus-column-right; }

    Mod+Ctrl+Left  { move-column-left; }
    Mod+Ctrl+Down  { move-window-down; }
    Mod+Ctrl+Up    { move-window-up; }
    Mod+Ctrl+Right { move-column-right; }
    Mod+Ctrl+H     { move-column-left; }
    Mod+Ctrl+J     { move-window-down; }
    Mod+Ctrl+K     { move-window-up; }
    Mod+Ctrl+L     { move-column-right; }

    Mod+Home { focus-column-first; }
    Mod+End  { focus-column-last; }
    Mod+Ctrl+Home { move-column-to-first; }
    Mod+Ctrl+End  { move-column-to-last; }

    Mod+Shift+Left  { focus-monitor-left; }
    Mod+Shift+Down  { focus-monitor-down; }
    Mod+Shift+Up    { focus-monitor-up; }
    Mod+Shift+Right { focus-monitor-right; }
    Mod+Shift+H     { focus-monitor-left; }
    Mod+Shift+J     { focus-monitor-down; }
    Mod+Shift+K     { focus-monitor-up; }
    Mod+Shift+L     { focus-monitor-right; }

    Mod+Shift+Ctrl+Left  { move-column-to-monitor-left; }
    Mod+Shift+Ctrl+Down  { move-column-to-monitor-down; }
    Mod+Shift+Ctrl+Up    { move-column-to-monitor-up; }
    Mod+Shift+Ctrl+Right { move-column-to-monitor-right; }
    Mod+Shift+Ctrl+H     { move-column-to-monitor-left; }
    Mod+Shift+Ctrl+J     { move-column-to-monitor-down; }
    Mod+Shift+Ctrl+K     { move-column-to-monitor-up; }
    Mod+Shift+Ctrl+L     { move-column-to-monitor-right; }

    Mod+Page_Down      { focus-workspace-down; }
    Mod+Page_Up        { focus-workspace-up; }
    Mod+U              { focus-workspace-down; }
    Mod+I              { focus-workspace-up; }
    Mod+Ctrl+Page_Down { move-column-to-workspace-down; }
    Mod+Ctrl+Page_Up   { move-column-to-workspace-up; }
    Mod+Ctrl+U         { move-column-to-workspace-down; }
    Mod+Ctrl+I         { move-column-to-workspace-up; }

    Mod+Shift+Page_Down { move-workspace-down; }
    Mod+Shift+Page_Up   { move-workspace-up; }
    Mod+Shift+U         { move-workspace-down; }
    Mod+Shift+I         { move-workspace-up; }

    Mod+WheelScrollDown      cooldown-ms=150 { focus-workspace-down; }
    Mod+WheelScrollUp        cooldown-ms=150 { focus-workspace-up; }
    Mod+Ctrl+WheelScrollDown cooldown-ms=150 { move-column-to-workspace-down; }
    Mod+Ctrl+WheelScrollUp   cooldown-ms=150 { move-column-to-workspace-up; }
    Mod+WheelScrollRight      { focus-column-right; }
    Mod+WheelScrollLeft       { focus-column-left; }
    Mod+Ctrl+WheelScrollRight { move-column-right; }
    Mod+Ctrl+WheelScrollLeft  { move-column-left; }

    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    Mod+6 { focus-workspace 6; }
    Mod+7 { focus-workspace 7; }
    Mod+8 { focus-workspace 8; }
    Mod+9 { focus-workspace 9; }
    Mod+Ctrl+1 { move-column-to-workspace 1; }
    Mod+Ctrl+2 { move-column-to-workspace 2; }
    Mod+Ctrl+3 { move-column-to-workspace 3; }
    Mod+Ctrl+4 { move-column-to-workspace 4; }
    Mod+Ctrl+5 { move-column-to-workspace 5; }
    Mod+Ctrl+6 { move-column-to-workspace 6; }
    Mod+Ctrl+7 { move-column-to-workspace 7; }
    Mod+Ctrl+8 { move-column-to-workspace 8; }
    Mod+Ctrl+9 { move-column-to-workspace 9; }

    Mod+BracketLeft  { consume-or-expel-window-left; }
    Mod+BracketRight { consume-or-expel-window-right; }
    Mod+Period { expel-window-from-column; }

    Mod+R { switch-preset-column-width; }
    Mod+Shift+R { switch-preset-column-width-back; }
    Mod+Ctrl+Shift+R { switch-preset-window-height; }
    Mod+Ctrl+R { reset-window-height; }

    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+Ctrl+F { expand-column-to-available-width; }
    Mod+C { center-column; }
    Mod+Ctrl+C { center-visible-columns; }

    Mod+Minus { set-column-width "-10%"; }
    Mod+Equal { set-column-width "+10%"; }
    Mod+Shift+Minus { set-window-height "-10%"; }
    Mod+Shift+Equal { set-window-height "+10%"; }

    Mod+Shift+V { switch-focus-between-floating-and-tiling; }
    Mod+W       { toggle-column-tabbed-display; }
    Mod+Shift+W { toggle-window-floating; }

    Print     { screenshot; }
    Ctrl+Print { screenshot-screen; }
    Alt+Print  { screenshot-window; }

    Mod+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }
    Mod+Shift+E { quit; }
    Ctrl+Alt+Delete { quit; }
    Mod+Shift+P { power-off-monitors; }
KDL_BINDS
    printf '}\n'

    # --- DMS fragments, last so their values win on merge. ---
    if (( use_includes )) && ((${#DMS_FRAGMENTS[@]})); then
        printf '\n// DMS fragments, written by `dms setup`. Keep these last: sections\n'
        printf '// merge across includes, so whatever DMS sets here overrides the above.\n'
        if (( use_optional )); then
            printf '// optional=true means a fragment you later delete cannot stop niri\n'
            printf '// from loading your config at login.\n'
        fi
        local name
        for name in "${DMS_FRAGMENTS[@]}"; do
            if (( use_optional )); then
                printf 'include optional=true "dms/%s.kdl"\n' "${name}"
            else
                printf 'include "dms/%s.kdl"\n' "${name}"
            fi
        done
    fi
    } > "${dest}.tmp"

    sed -e "s|@SCRIPT_NAME@|${SCRIPT_NAME}|g" \
        -e "s|@ACCENT@|${ACCENT}|g" \
        "${dest}.tmp" > "${dest}"
    rm -f "${dest}.tmp"
    ok "Wrote ${dest} (skip-known-binds=${skip_known}, includes=${use_includes}, optional=${use_optional})"
}

# Write config.kdl, then prove it parses. niri refuses to load a config with a
# duplicate keybind or an unknown node, and a refused config at login is a
# black screen, so degrade in steps rather than shipping something broken.
write_niri_config() {
    log "Writing ~/.config/niri/config.kdl (no Waybar, single DMS instance)"

    local cfg="${HOME}/.config/niri/config.kdl"
    backup_if_exists "${cfg}"

    local skip_known=0 use_includes=0 use_optional=0
    if (( NIRI_SUPPORTS_INCLUDE )); then use_includes=1; fi
    if (( NIRI_SUPPORTS_OPTIONAL_INCLUDE )); then use_optional=1; fi
    if (( use_includes && DMS_HAS_BINDS )); then skip_known=1; fi

    render_niri_config "${cfg}" "${skip_known}" "${use_includes}" "${use_optional}"
    if niri validate --config "${cfg}" >/dev/null 2>&1; then
        ok "niri validate passed"
        return 0
    fi

    # Fallback: drop the includes. Loses DMS theming and DMS binds, keeps you
    # able to log in and fix it with a working terminal.
    if (( use_includes )); then
        warn "niri validate failed; retrying without DMS includes"
        use_includes=0
        use_optional=0
        skip_known=0
        render_niri_config "${cfg}" "${skip_known}" "${use_includes}" "${use_optional}"
        if niri validate --config "${cfg}" >/dev/null 2>&1; then
            warn "Config is valid but DMS fragments are NOT included."
            warn "Add them back one at a time, checking 'niri validate' after each:"
            warn "  include \"dms/colors.kdl\"   (add optional=true on niri >= 26.04)"
            return 0
        fi
    fi

    warn "niri validate is still failing. Full output:"
    niri validate --config "${cfg}" || true
    warn "Fix the above before rebooting, or you will get a black screen at login."
    warn "Common causes: duplicate binds, syntax error in a dms/*.kdl include, or niri too old for 'include'."
    warn "TTY recovery: Ctrl+Alt+F2, log in, edit ~/.config/niri/config.kdl, then 'niri validate'."
    # A config niri refuses to parse means a black screen at login. Do not let
    # main() continue printing a "complete" summary in this state.
    return 1
}

write_support_configs() {
    log "Writing portal, environment, and GTK defaults"

    write_file "${HOME}/.config/xdg-desktop-portal/niri-portals.conf" <<'EOF'
[preferred]
default=gtk
org.freedesktop.impl.portal.Secret=gnome-keyring
org.freedesktop.impl.portal.Screenshot=gnome
org.freedesktop.impl.portal.ScreenCast=gnome
org.freedesktop.impl.portal.RemoteDesktop=gnome
org.freedesktop.impl.portal.FileChooser=gtk
EOF

    # environment.d applies to EVERY user session, including the dms.service
    # systemd user unit that starts DMS before niri exports its own `environment {}`
    # block. The official installer uses the name 90-dms.conf for these values.
    write_file "${HOME}/.config/environment.d/90-dms.conf" <<'EOF'
QT_QPA_PLATFORM=wayland
QT_QPA_PLATFORMTHEME=gtk3
QT_QPA_PLATFORMTHEME_QT6=gtk3
ELECTRON_OZONE_PLATFORM_HINT=auto
EOF

    write_file "${HOME}/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=adw-gtk3-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Noto Sans 11
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=1
EOF
    write_file "${HOME}/.config/gtk-4.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=adw-gtk3-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Noto Sans 11
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=1
EOF

    # Never overwrite an existing alacritty.toml: `dms setup --terminal
    # alacritty` may have written one that imports the DMS color theme, and
    # replacing it would silently drop dynamic theming. This also keeps
    # re-runs from clobbering your own edits.
    local alacritty_conf="${HOME}/.config/alacritty/alacritty.toml"
    if [[ -e ${alacritty_conf} ]]; then
        ok "Keeping existing ${alacritty_conf}"
    else
        write_file "${alacritty_conf}" <<'EOF'
[window]
# Padding trimmed and font a point smaller than the original 10px/12.0pt:
# at the default niri tiled column width, that combination landed a couple
# columns under 80, which trips the minimum-terminal-size check some CLI
# tools (including `dms doctor`/`dms setup`) enforce. If you still see a
# "Terminal size too small" message on your monitor, either drop `size`
# further, cycle to a wider column with Mod+R, or fullscreen with Mod+F.
padding = { x = 6, y = 6 }
decorations = "None"
opacity = 0.96

[font]
size = 11.0

[font.normal]
family = "JetBrains Mono"
style = "Regular"

[font.bold]
family = "JetBrains Mono"
style = "Bold"

[colors.primary]
background = "#1e1e2e"
foreground = "#cdd6f4"

[colors.normal]
black   = "#45475a"
red     = "#f38ba8"
green   = "#a6e3a1"
yellow  = "#f9e2af"
blue    = "#89b4fa"
magenta = "#cba6f7"
cyan    = "#94e2d5"
white   = "#bac2de"

[colors.bright]
black   = "#585b70"
red     = "#f38ba8"
green   = "#a6e3a1"
yellow  = "#f9e2af"
blue    = "#89b4fa"
magenta = "#cba6f7"
cyan    = "#94e2d5"
white   = "#a6adc8"
EOF
    fi
}

ensure_path() {
    local line='export PATH="${HOME}/.local/bin:${PATH}"'
    local rc
    for rc in "${HOME}/.bash_profile" "${HOME}/.bashrc" "${HOME}/.zprofile" "${HOME}/.profile"; do
        if [[ -f ${rc} ]] && grep -Fq '.local/bin' "${rc}"; then
            return 0
        fi
    done
    if [[ -f ${HOME}/.bash_profile ]]; then
        printf '\n%s\n' "${line}" >> "${HOME}/.bash_profile"
    elif [[ -f ${HOME}/.bashrc ]]; then
        printf '\n%s\n' "${line}" >> "${HOME}/.bashrc"
    else
        printf '%s\n' "${line}" >> "${HOME}/.profile"
    fi
    ok "Ensured ~/.local/bin is on PATH for login shells"
}

# Quick post-install sanity check while there is still a shell to fix things.
# Warn-only: a companion package can be absent on a particular Fedora release.
verify_installation() {
    log "Verifying installed components"
    local bin
    for bin in niri dms dms-greeter greetd alacritty xwayland-satellite \
               pipewire wireplumber nautilus firefox; do
        if command -v "${bin}" >/dev/null 2>&1; then
            ok "${bin}"
        else
            warn "${bin} not found in PATH"
        fi
    done
    if [[ -f /usr/share/wayland-sessions/niri.desktop ]]; then
        ok "niri.desktop session file"
    else
        warn "/usr/share/wayland-sessions/niri.desktop missing"
    fi
}

# DMS's own self-check. Worth running while you still have a shell.
run_doctor() {
    if command -v dms >/dev/null 2>&1; then
        log "Running dms doctor"
        dms doctor || warn "dms doctor reported problems (see above)"
    fi
}

print_summary() {
    cat <<EOF

============================================================
 Minimal Niri + DMS desktop is installed
============================================================

 How you got here
   Fedora Everything Network Install
     Software Selection = Minimal / Custom OS, no DE
   This script
     official niri + Dux Labs COPR (dms + dux-greeter)

 Login
   Reboot. greetd starts dms-greeter, then niri-session.
   TTY fallback: Ctrl+Alt+F2, log in, run: niri-session

 First-run checks
   niri validate
   niri msg outputs
   dms doctor
   dms-greeter status
    systemctl --user status niri dms
   wpctl status
   nmcli device status
   bluetoothctl show

 Default binds  (Mod = Super)
   Mod+Return / Mod+T   Alacritty
   Mod+Space / Mod+D    DMS launcher
   Mod+B                Firefox
   Mod+E                Files
   Mod+,                DMS settings
   Mod+N                notification center
   Mod+V                clipboard
   Mod+Y                wallpapers
   Mod+O                overview
   Super+Alt+L          lock (DMS)
   Print                niri screenshot
   Mod+Shift+E          quit niri

 Files
   ~/.config/niri/config.kdl
   ~/.config/niri/dms/*.kdl     (from \`dms setup\`)
    ~/.config/environment.d/90-dms.conf  (Qt/Electron env for dms.service)
   /etc/greetd/config.toml      (dms-greeter --command niri -C …/niri.kdl)
   /etc/greetd/niri.kdl         (greeter compositor; DMS_RUN_GREETER)
   /usr/share/wayland-sessions/niri.desktop  (Exec=niri-session)

 Notes
   Do not add spawn-at-startup "waybar" — DMS is the shell.
   Do not add spawn-at-startup "dms" — systemd already starts it once.
   Do not bind a key in config.kdl that dms/binds.kdl already binds:
     niri treats duplicate binds as a parse error and loads nothing.
   getty@tty1 was disabled for the NEXT boot only; this shell is unaffected.
   Group changes (i2c, video, audio) apply after a fresh login / reboot.
   Bluetooth UI is the DMS panel. Standalone manager if you want it:
     sudo dnf install blueman
   NVIDIA: enable RPM Fusion, install akmod-nvidia, reboot.
   Extra wallpapers: DMS Settings → wallpaper picker.
   Greeter theme sync was attempted by this script; re-run after theme changes:
     dms-greeter sync

 Reboot now?
   sudo reboot
============================================================
EOF
}

main() {
    need_user
    need_fedora
    dnf_bootstrap
    enable_coprs
    install_packages
    detect_niri_features
    configure_system
    prepare_home
    # Order matters: fragments must exist before the config that includes them,
    # and DMS_HAS_BINDS decides whether config.kdl writes its own DMS binds.
    setup_dms_fragments
    write_niri_config
    write_support_configs
    ensure_path
    # Greeter last: `dms-greeter install` syncs with the DMS config written above.
    setup_greeter
    verify_installation
    run_doctor
    print_summary
}

main "$@"
