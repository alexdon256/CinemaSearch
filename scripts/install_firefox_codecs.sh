#!/bin/bash

# Firefox and Video Codecs Installation Script for Clear Linux
# Installs Firefox and configures video codecs for playback

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

# Check if running on Clear Linux
check_clear_linux() {
    if [[ ! -f /usr/lib/os-release ]] || ! grep -q "ID=clear-linux-os" /usr/lib/os-release; then
        log_error "This script is designed for Clear Linux OS only"
        exit 1
    fi
}

# Install Firefox and multimedia bundles
install_firefox_and_codecs() {
    log_info "Installing Firefox and video codecs..."
    
    # Update system first
    log_info "Updating Clear Linux OS..."
    swupd update -y || log_warning "swupd update had issues, continuing..."
    
    # Install Firefox bundle
    log_info "Installing Firefox..."
    if swupd bundle-add firefox -y; then
        log_success "Firefox installed successfully"
    else
        log_error "Failed to install Firefox"
        exit 1
    fi
    
    # Install multimedia bundles for codecs
    log_info "Installing multimedia codecs..."
    
    # Install essential multimedia bundles
    MULTIMEDIA_BUNDLES=(
        "multimedia-audio"      # Audio codecs
        "multimedia-video"       # Video codecs
        "multimedia"             # Complete multimedia bundle
    )
    
    for bundle in "${MULTIMEDIA_BUNDLES[@]}"; do
        log_info "Installing bundle: $bundle..."
        if swupd bundle-add "$bundle" -y 2>/dev/null; then
            log_success "Installed $bundle"
        else
            log_warning "Bundle $bundle not available or already installed"
        fi
    done
    
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
        log_warning "Flatpak not available, installing via swupd only"
    fi
}

# Install FFmpeg and GStreamer plugins (alternative method)
install_ffmpeg_gstreamer() {
    log_info "Installing FFmpeg and GStreamer plugins..."
    
    # Try to install FFmpeg if available
    if swupd bundle-add ffmpeg -y 2>/dev/null; then
        log_success "FFmpeg installed"
    else
        log_warning "FFmpeg bundle not available via swupd"
    fi
    
    # Install GStreamer plugins for video playback
    GSTREAMER_BUNDLES=(
        "gstreamer1"
        "gstreamer1-plugins-base"
        "gstreamer1-plugins-good"
        "gstreamer1-plugins-bad"
        "gstreamer1-plugins-ugly"
        "gstreamer1-libav"
    )
    
    for bundle in "${GSTREAMER_BUNDLES[@]}"; do
        log_info "Installing GStreamer bundle: $bundle..."
        if swupd bundle-add "$bundle" -y 2>/dev/null; then
            log_success "Installed $bundle"
        else
            log_warning "Bundle $bundle not available"
        fi
    done
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
    log_info "additional licensing. Clear Linux bundles should include"
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
    log_info "For Clear Linux OS"
    log_info ""
    
    check_root
    check_clear_linux
    
    log_info "Starting installation..."
    log_info ""
    
    # Install Firefox and codecs
    install_firefox_and_codecs
    
    log_info ""
    
    # Install FFmpeg and GStreamer
    install_ffmpeg_gstreamer
    
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

