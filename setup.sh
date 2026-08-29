#!/usr/bin/env bash
# =============================================================================
# Fedora KDE Plasma Setup Script
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & basic loggers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { err "$*"; exit 1; }
section() {
    echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  $*${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}"
}

# ---------------------------------------------------------------------------
# Logging — all background-command output lands here
# ---------------------------------------------------------------------------
LOG_FILE="$HOME/fedora-setup-$(date +%Y%m%d-%H%M%S).log"
log "Full output → ${LOG_FILE}"

# ---------------------------------------------------------------------------
# Progress bar
#
# Usage: run_bg "Label shown to user" cmd [args…]
#
# • Runs cmd in the background with stdout+stderr → LOG_FILE
# • Draws a compact bar that fills as time passes (estimated duration)
# • Prints ✓ or ✗ when the job finishes
# ---------------------------------------------------------------------------
BAR_WIDTH=30          # characters wide
BAR_FILL="█"
BAR_EMPTY="░"

_draw_bar() {          # _draw_bar  filled_pct  label
    local pct=$1 label=$2
    local filled=$(( pct * BAR_WIDTH / 100 ))
    local empty=$(( BAR_WIDTH - filled ))
    local bar=""
    for (( i=0; i<filled; i++ )); do bar+="$BAR_FILL"; done
    for (( i=0; i<empty;  i++ )); do bar+="$BAR_EMPTY"; done
    # \r → overwrite same line
    printf "\r  ${CYAN}${bar}${NC} ${DIM}%3d%%${NC}  %s" "$pct" "$label"
}

run_bg() {
    local label="$1"; shift
    # Estimated seconds for a "full" bar — purely cosmetic pacing
    local est_secs="${SETUP_EST_SECS:-30}"

    # Launch the real command, appending all output to the log
    "$@" >> "$LOG_FILE" 2>&1 &
    local job_pid=$!

    local elapsed=0
    local pct=0

    # Animate until the job exits
    while kill -0 "$job_pid" 2>/dev/null; do
        # Ease toward 95 % while running; never quite reaches 100 % until done
        pct=$(( elapsed * 95 / est_secs ))
        (( pct > 95 )) && pct=95
        _draw_bar "$pct" "$label"
        sleep 0.15
        (( elapsed++ )) || true
    done

    # Collect exit status
    wait "$job_pid"
    local status=$?

    if (( status == 0 )); then
        _draw_bar 100 "$label"
        echo -e "  ${GREEN}✓${NC}"
    else
        _draw_bar "$pct" "$label"
        echo -e "  ${RED}✗  (exit $status — see $LOG_FILE)${NC}"
        return "$status"
    fi
}

# Convenience: non-fatal version (warn instead of abort on failure)
run_bg_soft() {
    local label="$1"; shift
    run_bg "$label" "$@" || warn "Non-fatal failure: $label"
}

# ---------------------------------------------------------------------------
# Script root
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight_checks() {
    [[ -f /etc/fedora-release ]] || die "This script is intended for Fedora only."
    sudo -v || die "This script requires sudo privileges."
    ( while true; do sudo -v; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
}

# ---------------------------------------------------------------------------
# DNF Configuration & System Update
# ---------------------------------------------------------------------------
configure_dnf() {
    section "DNF Configuration & System Update"

    local dnf_conf=/etc/dnf/dnf.conf
    if ! grep -q "^max_parallel_downloads" "$dnf_conf" 2>/dev/null; then
        echo 'max_parallel_downloads=10' | sudo tee -a "$dnf_conf" > /dev/null
        ok "Set max_parallel_downloads=10"
    else
        warn "max_parallel_downloads already configured — skipping"
    fi

    SETUP_EST_SECS=120 run_bg "System update" \
        sudo dnf update -y
}

# ---------------------------------------------------------------------------
# RPM Fusion
# ---------------------------------------------------------------------------
setup_rpmfusion() {
    section "RPM Fusion"

    local fedora_version
    fedora_version="$(rpm -E %fedora)"

    if ! rpm -q rpmfusion-free-release &>/dev/null; then
        SETUP_EST_SECS=20 run_bg "RPM Fusion Free" \
            sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm"
        ok "RPM Fusion Free enabled"
    else
        warn "RPM Fusion Free is already installed — skipping"
    fi

    if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
        SETUP_EST_SECS=20 run_bg "RPM Fusion Nonfree" \
            sudo dnf install -y \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm"
        ok "RPM Fusion Nonfree enabled"
    else
        warn "RPM Fusion Nonfree is already installed — skipping"
    fi

    SETUP_EST_SECS=15 run_bg "Refresh DNF metadata" \
        sudo dnf makecache

    ok "RPM Fusion configured"
}

# ---------------------------------------------------------------------------
# Multimedia Codecs
# ---------------------------------------------------------------------------
configure_codecs() {
    section "Multimedia Codecs"


    SETUP_EST_SECS=30 run_bg "Replace FFmpeg" \
        sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing

    SETUP_EST_SECS=30 run_bg "Install multimedia codecs" \
        sudo dnf group install -y multimedia

    SETUP_EST_SECS=20 run_bg "Install additional codecs" \
        sudo dnf group install -y sound-and-video

    ok "Multimedia codecs configured"
}

# ---------------------------------------------------------------------------
# Package Installation
# ---------------------------------------------------------------------------
install_packages() {
    section "Package Installation"

    local core_plasma=(
        plasma-desktop konsole dolphin plasma-nm plasma-pa
        plasma-systemmonitor plasma-firewall firewalld
        kscreen kwalletmanager kwallet-pam bluedevil powerdevil
        xdg-desktop-portal-kde kde-gtk-config breeze-gtk
        cups ffmpegthumbs kf6-baloo-file
    )
    local essential_plasma=(
        kwrite kate gwenview spectacle ark unrar tar zip 7zip
        sddm sddm-kcm sddm-breeze bluez kinfocenter okular
        qrca kde-partitionmanager filelight kcalc
    )
    local fonts=(
        google-noto-sans-devanagari-fonts
        google-noto-color-emoji-fonts
        rsms-inter-fonts
        jetbrains-mono-fonts
    )
    local other=(
        git gh
        qbittorrent pdfarranger
        flatpak flatpak-kcm
        libreoffice
    )

    SETUP_EST_SECS=90  run_bg "Core Plasma packages" \
        sudo dnf install -y "${core_plasma[@]}"

    SETUP_EST_SECS=60  run_bg "Essential Plasma apps" \
        sudo dnf install -y "${essential_plasma[@]}"

    SETUP_EST_SECS=30  run_bg "Fonts" \
        sudo dnf install -y "${fonts[@]}"

    SETUP_EST_SECS=30  run_bg "Other packages (git, qbittorrent…)" \
        sudo dnf install -y "${other[@]}"
}

# ---------------------------------------------------------------------------
# Systemd Services
# ---------------------------------------------------------------------------
configure_systemd() {
    section "Systemd Services"

    sudo systemctl set-default graphical.target
    sudo systemctl enable sddm
    sudo systemctl enable firewalld
    ok "Systemd targets/services configured"
}

# ---------------------------------------------------------------------------
# VSCodium
# ---------------------------------------------------------------------------
install_vscodium() {
    section "VSCodium"

    local repo=/etc/yum.repos.d/vscodium.repo
    if [[ ! -f "$repo" ]]; then
        sudo tee "$repo" > /dev/null << 'EOF'
[gitlab.com_paulcarroty_vscodium_repo]
name=gitlab.com_paulcarroty_vscodium_repo
baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
metadata_expire=1h
EOF
        ok "VSCodium repo added"
    else
        warn "VSCodium repo already exists — skipping"
    fi

    SETUP_EST_SECS=45 run_bg "VSCodium install" \
        sudo dnf install -y codium
}

# ---------------------------------------------------------------------------
# Brave Browser
# ---------------------------------------------------------------------------
install_brave() {
    section "Brave Browser"

    if command -v brave-browser &>/dev/null; then
        warn "Brave is already installed — skipping"
    else
        SETUP_EST_SECS=45 run_bg "Brave Browser install" \
            bash -c 'curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh'
    fi
}

# ---------------------------------------------------------------------------
# Flatpak & Flathub Apps
# ---------------------------------------------------------------------------
install_flatpak_apps() {
    section "Flatpak & Flathub"

    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo >> "$LOG_FILE" 2>&1

    local apps=(
        com.spotify.Client
        com.discordapp.Discord
        org.onlyoffice.desktopeditors
    )

    SETUP_EST_SECS=120 run_bg "Flatpak apps (Spotify, Discord, OnlyOffice)" \
        flatpak install -y flathub "${apps[@]}"

    SETUP_EST_SECS=30  run_bg_soft "SpotX patch" \
        bash -c 'bash <(curl -sSL https://spotx-official.github.io/run.sh)'
}

# ---------------------------------------------------------------------------
# Fingerprint Sensor
# ---------------------------------------------------------------------------
install_fingerprint() {
    section "Fingerprint Sensor"

    run_bg "Enable libfprint COPR" \
        sudo dnf copr enable -y dolmushcu/libfprint-tod

    SETUP_EST_SECS=30 run_bg "Fingerprint packages" \
        sudo dnf install -y libfprint-2-tod1-elan-0c4b fprintd fprintd-pam

    sudo systemctl enable --now fprintd
    ok "fprintd enabled"
}

# ---------------------------------------------------------------------------
# SDDM
# ---------------------------------------------------------------------------
configure_sddm() {
    section "SDDM"

    local wallpaper_src="${SCRIPT_DIR}/sddm.jpg"
    local wallpaper_dst=/usr/share/wallpapers/custom/sddm.jpg

    if [[ -f "$wallpaper_src" ]]; then
        sudo mkdir -p /usr/share/wallpapers/custom/
        sudo cp "$wallpaper_src" "$wallpaper_dst"
        ok "SDDM wallpaper copied"
    else
        warn "Wallpaper '${wallpaper_src}' not found — SDDM background may be missing"
    fi

    sudo mkdir -p /usr/share/sddm/themes/breeze
    sudo tee /usr/share/sddm/themes/breeze/theme.conf > /dev/null << EOF
[General]
showlogo=hidden
showClock=true
logo=/usr/share/sddm/themes/breeze/default-logo.svg
type=image
color=#1d99f3
fontSize=10
background=${wallpaper_dst}
needsFullUserModel=false
EOF
    ok "SDDM configured"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    for dir in "${HOME}/Public" "${HOME}/Templates"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            ok "Removed $dir"
        fi
    done

    SETUP_EST_SECS=15 run_bg_soft "Remove plasma-welcome" \
        sudo dnf remove -y plasma-welcome

    local stale_paths=(
        /usr/share/sddm/themes/01-breeze-fedora
        /usr/share/plasma/look-and-feel/org.fedoraproject*
        /usr/share/plasma/look-and-feel/org.kde.breezetwilight.desktop
    )
    for path in "${stale_paths[@]}"; do
        for expanded in $path; do
            if [[ -e "$expanded" ]]; then
                sudo rm -rf "$expanded"
                ok "Removed $expanded"
            fi
        done
    done

    ok "Cleanup complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    preflight_checks

    configure_dnf
    setup_rpmfusion
    configure_codecs
    install_packages
    configure_systemd
    install_vscodium
    install_brave
    install_flatpak_apps
    install_fingerprint
    configure_sddm
    cleanup

    section "Setup Complete"
    echo -e "${GREEN}${BOLD}All steps finished. Full log: ${LOG_FILE}${NC}"
    echo -e "${YELLOW}A reboot is recommended.${NC}"
}

main "$@"
