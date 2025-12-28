#!/bin/bash

# Firefox and Video Codecs Installation Script for CachyOS
# Installs Firefox and configures video codecs for playback
# Also disables system logging (logs only in volatile RAM)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check if running on CachyOS/Arch Linux
check_cachyos() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. This script is designed for CachyOS (Arch-based)."
        exit 1
    fi
    
    local os_id
    os_id=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' || echo "")
    
    if [[ "$os_id" != "cachyos" ]] && [[ "$os_id" != "arch" ]]; then
        log_error "This script is designed for CachyOS (Arch-based). Detected: $os_id"
        exit 1
    fi
    
    log_info "Detected CachyOS/Arch Linux"
}

# Install Firefox and multimedia codecs
install_firefox_and_codecs() {
    log_info "Installing Firefox and video codecs..."
    
    # Update system first
    log_info "Updating system packages..."
    pacman -Syu --noconfirm || log_warning "pacman update had issues, continuing..."
    
    # Install Firefox
    log_info "Installing Firefox..."
    if pacman -S --noconfirm firefox; then
        log_success "Firefox installed successfully"
    else
        log_error "Failed to install Firefox"
        exit 1
    fi
    
    # Install multimedia codecs
    log_info "Installing multimedia codecs..."
    
    # Install essential multimedia packages
    pacman -S --noconfirm \
        gstreamer \
        gst-plugins-base \
        gst-plugins-good \
        gst-plugins-bad \
        gst-plugins-ugly \
        gst-libav \
        ffmpeg \
        gst-plugins-rs \
        || log_warning "Some codec packages may have failed to install"
    
    # Install additional codec packages via flatpak (if available)
    log_info "Checking for Flatpak support..."
    if command -v flatpak &> /dev/null; then
        log_info "Flatpak is available, installing codecs via Flatpak..."
        
        # Add Flathub repository if not already added
        if ! flatpak remote-list | grep -q "flathub"; then
            log_info "Adding Flathub repository..."
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        fi
        
        # Install codecs via Flatpak
        log_info "Installing codecs from Flathub..."
        flatpak install -y flathub org.freedesktop.Platform.ffmpeg-full || log_warning "FFmpeg codecs installation had issues"
    else
        log_warning "Flatpak not available, installing via pacman only"
    fi
}

# Install additional codecs if needed
install_additional_codecs() {
    log_info "Installing additional codecs if needed..."
    
    # Install additional codec packages
    pacman -S --noconfirm \
        libvpx \
        libx264 \
        libx265 \
        libvorbis \
        libtheora \
        || log_warning "Some additional codec packages may have failed to install"
    
    log_success "Additional codecs installation complete"
}

# Configure Firefox for video playback
configure_firefox() {
    log_info "Configuring Firefox for video playback..."
    
    # Find Firefox installation
    FIREFOX_BIN=""
    if command -v firefox &> /dev/null; then
        FIREFOX_BIN=$(command -v firefox)
        log_success "Found Firefox at: $FIREFOX_BIN"
    else
        log_error "Firefox not found in PATH"
        return 1
    fi
    
    # Get Firefox version
    FIREFOX_VERSION=$(firefox --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 || echo "unknown")
    log_info "Firefox version: $FIREFOX_VERSION"
    
    # Create user preferences directory if it doesn't exist
    # Note: This will be created per-user, but we can set system-wide defaults
    log_info "Firefox will use system codecs automatically when available"
    
    # Create a helper script to launch Firefox with proper environment
    log_info "Creating Firefox launcher script..."
    cat > /usr/local/bin/firefox-video <<'EOF'
#!/bin/bash
# Firefox launcher with video codec support

# Set environment variables for codec support
export GST_PLUGIN_SYSTEM_PATH="/usr/lib64/gstreamer-1.0:/usr/lib/gstreamer-1.0"
export GST_PLUGIN_SCANNER="/usr/bin/gst-plugin-scanner-1.0"

# Enable hardware acceleration if available
export MOZ_ACCELERATED=1
export MOZ_WEBRENDER=1

# Launch Firefox
exec /usr/bin/firefox "$@"
EOF
    
    chmod +x /usr/local/bin/firefox-video
    log_success "Created Firefox launcher: /usr/local/bin/firefox-video"
    
    # Create desktop file override for better video support
    log_info "Creating desktop file with video support..."
    DESKTOP_FILE="/usr/share/applications/firefox-video.desktop"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Version=1.0
Name=Firefox (Video Support)
GenericName=Web Browser
Comment=Browse the Web with video codec support
Exec=/usr/local/bin/firefox-video %u
Terminal=false
X-MultipleArgs=false
Type=Application
Icon=firefox
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/vnd.mozilla.xul+xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/ftp;x-scheme-handler/chrome;video/webm;audio/webm;video/ogg;audio/ogg;video/quicktime;video/x-msvideo;
StartupNotify=true
EOF
    
    log_success "Created desktop file: $DESKTOP_FILE"
}

# Create desktop shortcut for Firefox
create_desktop_shortcut() {
    log_info "Creating Firefox desktop shortcut..."
    
    # Function to create shortcut for a specific user
    create_shortcut_for_user() {
        local user_home="$1"
        local username="$2"
        
        # Try to find desktop directory
        local desktop_dir=""
        
        # Try XDG user directories first
        if [[ -f "$user_home/.config/user-dirs.dirs" ]]; then
            source "$user_home/.config/user-dirs.dirs" 2>/dev/null || true
            if [[ -n "${XDG_DESKTOP_DIR:-}" ]]; then
                desktop_dir=$(eval echo "$XDG_DESKTOP_DIR")
            fi
        fi
        
        # Fallback to common desktop locations
        if [[ -z "$desktop_dir" ]] || [[ ! -d "$desktop_dir" ]]; then
            for dir in "$user_home/Desktop" "$user_home/desktop" "$user_home/Рабочий стол"; do
                if [[ -d "$dir" ]]; then
                    desktop_dir="$dir"
                    break
                fi
            done
        fi
        
        # Create Desktop directory if it doesn't exist
        if [[ -z "$desktop_dir" ]]; then
            desktop_dir="$user_home/Desktop"
            mkdir -p "$desktop_dir" 2>/dev/null || {
                log_warning "Cannot create desktop directory for $username, skipping shortcut"
                return 1
            }
        fi
        
        # Create desktop shortcut file
        local shortcut_file="$desktop_dir/Firefox.desktop"
        
        cat > "$shortcut_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
GenericName=Web Browser
Comment=Browse the Web with video codec support
Exec=/usr/local/bin/firefox-video %u
Icon=firefox
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/vnd.mozilla.xul+xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/ftp;x-scheme-handler/chrome;video/webm;audio/webm;video/ogg;audio/ogg;video/quicktime;video/x-msvideo;
StartupNotify=true
StartupWMClass=Firefox
EOF
        
        # Make executable
        chmod +x "$shortcut_file" 2>/dev/null || true
        
        # Set ownership if we know the user
        if [[ -n "$username" ]] && id "$username" &>/dev/null; then
            chown "$username:$username" "$shortcut_file" 2>/dev/null || true
        fi
        
        log_success "Created desktop shortcut for $username: $shortcut_file"
    }
    
    # If running as root, create shortcuts for all users with home directories
    if [[ $EUID -eq 0 ]]; then
        log_info "Creating desktop shortcuts for all users..."
        
        # Get list of users with home directories
        while IFS=: read -r username _ _ _ _ home_dir _; do
            # Skip system users and users without home directories
            if [[ -z "$home_dir" ]] || [[ ! -d "$home_dir" ]] || [[ "$home_dir" == "/" ]]; then
                continue
            fi
            
            # Skip if home directory is /root (we'll handle root separately if needed)
            if [[ "$home_dir" == "/root" ]]; then
                continue
            fi
            
            create_shortcut_for_user "$home_dir" "$username"
        done < /etc/passwd
        
        # Also create for root if running as root
        if [[ -d "/root" ]]; then
            create_shortcut_for_user "/root" "root"
        fi
    else
        # Running as regular user, create shortcut for current user only
        create_shortcut_for_user "$HOME" "$(whoami)"
    fi
    
    log_success "Desktop shortcuts created"
}

# Disable Firefox telemetry
disable_firefox_telemetry() {
    log_info "Configuring Firefox to disable telemetry..."
    
    # Find Firefox installation directory
    local firefox_prefs_dir=""
    for dir in "/usr/lib/firefox/browser/defaults/preferences" "/usr/lib64/firefox/browser/defaults/preferences"; do
        if [[ -d "$dir" ]]; then
            firefox_prefs_dir="$dir"
            break
        fi
    done
    
    if [[ -z "$firefox_prefs_dir" ]]; then
        # Create directory if it doesn't exist
        firefox_prefs_dir="/usr/lib/firefox/browser/defaults/preferences"
        mkdir -p "$firefox_prefs_dir" 2>/dev/null || {
            log_warning "Could not create Firefox preferences directory"
            return 0
        }
    fi
    
    # Create Firefox preferences file to disable telemetry
    cat > "$firefox_prefs_dir/telemetry-disable.js" <<'EOF'
// Firefox Telemetry Disabled
// This file disables all telemetry in Firefox

pref("toolkit.telemetry.enabled", false);
pref("toolkit.telemetry.unified", false);
pref("toolkit.telemetry.archive.enabled", false);
pref("toolkit.telemetry.bhrPing.enabled", false);
pref("toolkit.telemetry.firstShutdownPing.enabled", false);
pref("toolkit.telemetry.hybridContent.enabled", false);
pref("toolkit.telemetry.newProfilePing.enabled", false);
pref("toolkit.telemetry.shutdownPingSender.enabled", false);
pref("toolkit.telemetry.updatePing.enabled", false);
pref("toolkit.telemetry.server", "");
pref("datareporting.policy.dataSubmissionEnabled", false);
pref("datareporting.healthreport.uploadEnabled", false);
pref("browser.ping-centre.telemetry", false);
pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
pref("browser.newtabpage.activity-stream.telemetry", false);
EOF
    
    chmod 644 "$firefox_prefs_dir/telemetry-disable.js" 2>/dev/null || true
    log_success "Created persistent Firefox telemetry disable preferences"
}

# Disable system logging
disable_system_logging() {
    log_info "Disabling system logging..."
    
    # Disable systemd journal logging by configuring it to use volatile storage only
    log_info "Configuring systemd journal to use volatile storage only..."
    JOURNAL_CONF="/etc/systemd/journald.conf"
    
    # Backup original config if it exists
    if [[ -f "$JOURNAL_CONF" ]]; then
        cp "$JOURNAL_CONF" "${JOURNAL_CONF}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    
    # Create or update journald configuration to disable persistent logging
    cat > "$JOURNAL_CONF" <<'EOF'
[Journal]
# Disable persistent storage - logs only in RAM
Storage=volatile
# Limit journal size
SystemMaxUse=16M
RuntimeMaxUse=16M
# Disable forwarding to syslog
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
# Disable audit logging
Audit=no
EOF
    
    chmod 644 "$JOURNAL_CONF"
    log_success "Configured systemd journal to use volatile storage only"
    
    # Reload systemd and restart journald to apply changes immediately and persistently
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart systemd-journald.service 2>/dev/null || {
        log_warning "Could not restart journald, changes will apply on next boot"
    }
    
    # Disable rsyslog if present
    if systemctl list-unit-files | grep -q "rsyslog.service"; then
        log_info "Stopping and disabling rsyslog..."
        systemctl stop rsyslog.service 2>/dev/null || true
        systemctl disable rsyslog.service 2>/dev/null || true
        systemctl mask rsyslog.service 2>/dev/null || true
        log_success "Disabled rsyslog service (persistent)"
    fi
    
    # Disable syslog if present (alternative logging daemon)
    if systemctl list-unit-files | grep -q "syslog.service"; then
        log_info "Stopping and disabling syslog..."
        systemctl stop syslog.service 2>/dev/null || true
        systemctl disable syslog.service 2>/dev/null || true
        systemctl mask syslog.service 2>/dev/null || true
        log_success "Disabled syslog service (persistent)"
    fi
    
    # Disable auditd if present
    if systemctl list-unit-files | grep -q "auditd.service"; then
        log_info "Stopping and disabling auditd..."
        systemctl stop auditd.service 2>/dev/null || true
        systemctl disable auditd.service 2>/dev/null || true
        systemctl mask auditd.service 2>/dev/null || true
        log_success "Disabled auditd service (persistent)"
    fi
    
    # Reload systemd to ensure all service changes are persistent
    systemctl daemon-reload 2>/dev/null || true
    
    # Configure logrotate to be minimal or disable it
    LOGROTATE_CONF="/etc/logrotate.conf"
    if [[ -f "$LOGROTATE_CONF" ]]; then
        log_info "Configuring logrotate to minimize logging..."
        # Backup original
        cp "$LOGROTATE_CONF" "${LOGROTATE_CONF}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        
        # Update logrotate to rotate more aggressively and compress immediately
        sed -i 's/^#compress/compress/' "$LOGROTATE_CONF" 2>/dev/null || true
        sed -i 's/^compress$/compress/' "$LOGROTATE_CONF" 2>/dev/null || true
        sed -i 's/^weekly/daily/' "$LOGROTATE_CONF" 2>/dev/null || true
        
        # Add aggressive rotation settings
        if ! grep -q "^rotate 1" "$LOGROTATE_CONF"; then
            echo "rotate 1" >> "$LOGROTATE_CONF"
        fi
        if ! grep -q "^maxage 1" "$LOGROTATE_CONF"; then
            echo "maxage 1" >> "$LOGROTATE_CONF"
        fi
        
        log_success "Configured logrotate for minimal logging"
    fi
    
    # Clear existing journal logs
    log_info "Clearing existing journal logs..."
    journalctl --vacuum-time=1s 2>/dev/null || {
        # Alternative: delete journal files directly
        rm -rf /var/log/journal/* 2>/dev/null || true
        rm -rf /run/log/journal/* 2>/dev/null || true
    }
    log_success "Cleared existing journal logs"
    
    # Clear other log directories
    log_info "Clearing other log files..."
    # Clear common log locations (but keep directory structure)
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
    find /var/log -type f -name "*.log.*" -delete 2>/dev/null || true
    
    # Clear syslog files
    truncate -s 0 /var/log/syslog 2>/dev/null || true
    truncate -s 0 /var/log/messages 2>/dev/null || true
    truncate -s 0 /var/log/daemon.log 2>/dev/null || true
    truncate -s 0 /var/log/kern.log 2>/dev/null || true
    
    log_success "Cleared other log files"
    
    # Disable kernel logging to dmesg buffer (reduce buffer size)
    log_info "Configuring kernel logging..."
    
    # Create persistent sysctl configuration
    SYSCTL_CONF="/etc/sysctl.d/99-disable-logging.conf"
    cat > "$SYSCTL_CONF" <<'EOF'
# Disable system logging - Persistent configuration
# Restrict dmesg access
kernel.dmesg_restrict = 1
# Suppress most kernel messages (only critical/emergency messages shown)
# Format: console_loglevel default_message_loglevel minimum_console_loglevel default_console_loglevel
kernel.printk = 3 3 3 3
EOF
    
    chmod 644 "$SYSCTL_CONF"
    
    # Apply sysctl settings immediately and ensure they persist
    sysctl -p "$SYSCTL_CONF" 2>/dev/null || {
        # Alternative: apply via sysctl --system
        sysctl --system 2>/dev/null || true
    }
    
    # Also set directly for immediate effect (sysctl.d will persist on reboot)
    echo 1 > /proc/sys/kernel/dmesg_restrict 2>/dev/null || true
    echo "3 3 3 3" > /proc/sys/kernel/printk 2>/dev/null || true
    
    log_success "Configured kernel logging restrictions (persistent)"
    
    # Disable crash reporting if present
    if systemctl list-unit-files | grep -q "crash"; then
        log_info "Disabling crash reporting services..."
        systemctl stop crash.service 2>/dev/null || true
        systemctl disable crash.service 2>/dev/null || true
        systemctl mask crash.service 2>/dev/null || true
        log_success "Disabled crash reporting (persistent)"
    fi
    
    # Ensure all systemd changes are persistent
    systemctl daemon-reload 2>/dev/null || true
    
    log_success "System logging disabled (logs only in volatile RAM, cleared on reboot - all settings persistent)"
}

# Install additional codecs manually if needed
install_manual_codecs() {
    log_info "Installing additional codecs if needed..."
    
    # Check for common codec libraries
    CODEC_LIBS=(
        "/usr/lib64/libavcodec.so"
        "/usr/lib64/libavformat.so"
        "/usr/lib64/libavutil.so"
        "/usr/lib64/libx264.so"
        "/usr/lib64/libx265.so"
        "/usr/lib64/libvpx.so"
    )
    
    MISSING_LIBS=()
    for lib in "${CODEC_LIBS[@]}"; do
        if [[ ! -f "$lib" ]]; then
            MISSING_LIBS+=("$lib")
        fi
    done
    
    if [[ ${#MISSING_LIBS[@]} -gt 0 ]]; then
        log_warning "Some codec libraries may be missing"
        log_info "Consider installing additional multimedia bundles"
    else
        log_success "Codec libraries are available"
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check Firefox
    if command -v firefox &> /dev/null; then
        FIREFOX_VERSION=$(firefox --version 2>/dev/null || echo "unknown")
        log_success "Firefox is installed: $FIREFOX_VERSION"
    else
        log_error "Firefox is not installed"
        return 1
    fi
    
    # Check for codec support
    log_info "Checking codec support..."
    
    # Check GStreamer
    if command -v gst-inspect-1.0 &> /dev/null; then
        PLUGIN_COUNT=$(gst-inspect-1.0 2>/dev/null | wc -l)
        log_success "GStreamer is available with $PLUGIN_COUNT plugins"
    else
        log_warning "GStreamer inspection tool not found"
    fi
    
    # Check FFmpeg
    if command -v ffmpeg &> /dev/null; then
        FFMPEG_VERSION=$(ffmpeg -version 2>/dev/null | head -1 || echo "unknown")
        log_success "FFmpeg is available: $FFMPEG_VERSION"
    else
        log_warning "FFmpeg command not found (may be library-only)"
    fi
    
    # Check for common video codecs
    log_info "Checking for video codec libraries..."
    CODECS_FOUND=0
    for codec in "libavcodec" "libx264" "libx265" "libvpx"; do
        if find /usr/lib* -name "*${codec}*" 2>/dev/null | grep -q .; then
            ((CODECS_FOUND++))
        fi
    done
    
    if [[ $CODECS_FOUND -gt 0 ]]; then
        log_success "Found $CODECS_FOUND codec library types"
    else
        log_warning "Limited codec support detected"
    fi
}

# Print usage instructions
print_usage() {
    log_info ""
    log_info "=== Firefox Video Codec Installation Complete ==="
    log_info ""
    log_info "Firefox has been installed and configured for video playback."
    log_info "Firefox telemetry has been disabled."
    log_info "System logging has been disabled (logs only in volatile RAM)."
    log_info ""
    log_info "Usage:"
    log_info "  - Standard Firefox: firefox"
    log_info "  - Firefox with video support: firefox-video"
    log_info ""
    log_info "Video formats supported:"
    log_info "  - WebM (VP8, VP9)"
    log_info "  - H.264 (MP4)"
    log_info "  - H.265/HEVC (if codecs installed)"
    log_info "  - Ogg Theora/Vorbis"
    log_info ""
    log_info "Note: Some proprietary codecs (like H.264) may require"
    log_info "additional licensing. Arch repositories include"
    log_info "necessary open-source codecs."
    log_info ""
    log_info "To test video playback:"
    log_info "  1. Launch Firefox: firefox-video"
    log_info "  2. Visit: https://www.youtube.com or https://www.html5test.com"
    log_info ""
}

# Main installation function
main() {
    log_info "=== Firefox and Video Codecs Installation Script ==="
    log_info "For CachyOS (Arch-based)"
    log_info ""
    
    check_root
    check_cachyos
    
    log_info "Starting installation..."
    log_info ""
    
    # Disable Firefox telemetry
    disable_firefox_telemetry
    
    log_info ""
    
    # Disable system logging
    disable_system_logging
    
    log_info ""
    
    # Install Firefox and codecs
    install_firefox_and_codecs
    
    log_info ""
    
    # Install additional codecs
    install_additional_codecs
    
    log_info ""
    
    # Configure Firefox
    configure_firefox
    
    log_info ""
    
    # Create desktop shortcut
    create_desktop_shortcut
    
    log_info ""
    
    # Install manual codecs if needed
    install_manual_codecs
    
    log_info ""
    
    # Verify installation
    verify_installation
    
    log_info ""
    
    # Print usage
    print_usage
    
    log_success "Installation complete!"
}

# Run main function
main "$@"

