#!/bin/bash

# CineStream Master Deployment Script v21.0
# Clear Linux OS Edition
# Manages multi-site deployment with Nginx, MongoDB, and Systemd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_CONF_DIR="/etc/nginx/conf.d"
SYSTEMD_DIR="/etc/systemd/system"
WWW_ROOT="/var/www"
MONGO_DATA_DIR="/opt/mongodb/data"
MONGO_LOG_DIR="/opt/mongodb/logs"

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
        log_warning "This script is designed for Clear Linux OS. Proceeding anyway..."
    fi
}

# Disable Clear Linux telemetry
disable_clear_linux_telemetry() {
    log_info "Disabling Clear Linux telemetry..."
    
    # Disable clr-telemetry systemd service if it exists
    if systemctl list-unit-files | grep -q "clr-telemetry"; then
        log_info "Stopping and disabling clr-telemetry service..."
        systemctl stop clr-telemetry.service 2>/dev/null || true
        systemctl disable clr-telemetry.service 2>/dev/null || true
        systemctl mask clr-telemetry.service 2>/dev/null || true
        log_success "Disabled clr-telemetry service (persistent)"
    else
        log_info "clr-telemetry service not found (may not be installed)"
    fi
    
    # Disable telemetry timer if it exists
    if systemctl list-unit-files | grep -q "clr-telemetry.timer"; then
        log_info "Stopping and disabling clr-telemetry timer..."
        systemctl stop clr-telemetry.timer 2>/dev/null || true
        systemctl disable clr-telemetry.timer 2>/dev/null || true
        systemctl mask clr-telemetry.timer 2>/dev/null || true
        log_success "Disabled clr-telemetry timer (persistent)"
    fi
    
    # Reload systemd to ensure service changes are persistent
    systemctl daemon-reload 2>/dev/null || true
    
    # Create/update telemetry configuration file to disable telemetry
    TELEMETRY_CONF="/etc/telemetry.conf"
    log_info "Configuring telemetry settings..."
    
    # Create telemetry configuration with telemetry disabled
    cat > "$TELEMETRY_CONF" <<'EOF'
# Clear Linux Telemetry Configuration
# Telemetry is disabled - no data will be sent

[telemetry]
enabled = false
EOF
    
    chmod 644 "$TELEMETRY_CONF"
    log_success "Created persistent telemetry configuration: $TELEMETRY_CONF"
    
    # Disable swupd telemetry if clr-telemetry command exists
    if command -v clr-telemetry &> /dev/null; then
        log_info "Disabling telemetry via clr-telemetry command..."
        clr-telemetry disable 2>/dev/null || {
            # If the command doesn't support disable, try to configure it
            log_info "Attempting to configure telemetry settings..."
            # Set telemetry to disabled via persistent configuration
            mkdir -p /etc/telemetry 2>/dev/null || true
            echo "disabled" > /etc/telemetry/status 2>/dev/null || true
            chmod 644 /etc/telemetry/status 2>/dev/null || true
        }
        log_success "Telemetry disabled via clr-telemetry (persistent)"
    fi
    
    # Configure swupd to not send telemetry
    SWUPD_CONF="/etc/swupd/config"
    if [[ ! -d "$(dirname "$SWUPD_CONF")" ]]; then
        mkdir -p "$(dirname "$SWUPD_CONF")" 2>/dev/null || true
    fi
    
    # Add telemetry disable setting to swupd config if file exists or create it
    if [[ -f "$SWUPD_CONF" ]]; then
        # Remove any existing telemetry settings
        sed -i '/^telemetry/d' "$SWUPD_CONF" 2>/dev/null || true
    fi
    
    # Add telemetry disable setting
    echo "telemetry=false" >> "$SWUPD_CONF" 2>/dev/null || {
        log_warning "Could not write to swupd config, but telemetry should still be disabled"
    }
    
    if [[ -f "$SWUPD_CONF" ]]; then
        log_success "Updated persistent swupd configuration to disable telemetry"
    fi
    
    log_success "Clear Linux telemetry disabled (0 telemetry sent - all settings persistent)"
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

# Initialize server: OS updates, packages, MongoDB
init_server() {
    log_info "Initializing Clear Linux server..."
    
    # Update Clear Linux
    log_info "Updating Clear Linux OS..."
    swupd update -y || log_warning "swupd update failed, continuing..."
    
    # Disable Clear Linux telemetry (persistent configuration)
    log_info ""
    disable_clear_linux_telemetry
    
    # Disable system logging (persistent configuration)
    log_info ""
    disable_system_logging
    
    log_info ""
    
    # Install required bundles
    log_info "Installing required bundles..."
    swupd bundle-add python3-basic nginx git openssh-server dev-utils sysadmin-basic nodejs-basic -y
    
    # Install MongoDB manually (not in swupd)
    log_info "Installing MongoDB..."
    install_mongodb
    
    # Optimize system for web server + MongoDB workload
    log_info "Optimizing system configuration..."
    optimize_system
    
    # Install Claude CLI globally
    log_info "Installing Claude CLI..."
    npm install -g @anthropic-ai/claude-code || log_warning "Failed to install Claude CLI, continuing..."
    
    # Create web root directory
    mkdir -p "$WWW_ROOT"
    chmod 755 "$WWW_ROOT"
    
    # Ensure Nginx directories exist
    mkdir -p "$NGINX_CONF_DIR"
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    
    # Start and enable MongoDB (after optimization)
    systemctl daemon-reload
    systemctl enable mongodb.service
    systemctl enable disable-transparent-hugepages.service 2>/dev/null || true
    systemctl enable configure-io-scheduler.service 2>/dev/null || true
    # Restart MongoDB to apply new configuration if it was already running
    if systemctl is-active --quiet mongodb.service 2>/dev/null; then
        systemctl restart mongodb.service || systemctl start mongodb.service
    else
        systemctl start mongodb.service
    fi
    
    # Create CineStream master target for coordinated startup
    create_master_target
    
    # Install CPU affinity management scripts (needed before configuring services)
    install_cpu_affinity_scripts
    
    # Configure Nginx CPU affinity (P-cores)
    configure_nginx_affinity
    
    # Start and enable Nginx
    systemctl daemon-reload
    systemctl enable nginx.service
    systemctl start nginx.service
    
    # Deploy application automatically
    log_info "Deploying CineStream application..."
    deploy_application
    
    log_success "Server initialization complete!"
    log_info "MongoDB is running on 127.0.0.1:27017"
    log_info "Nginx is configured and running"
    log_info "Application deployed and configured"
    log_info "All services configured to auto-start on boot"
    log_info "CPU affinity: MongoDB & Nginx -> P-cores (0-5), Python apps -> E-cores (6-13)"
    log_info "System optimized: swappiness=1, noatime, TCP tuning, MongoDB performance config"
    log_info "Telemetry disabled: 0 telemetry sent (all settings persistent)"
    log_info "System logging disabled: logs only in volatile RAM (all settings persistent)"
    log_info ""
    log_info "Next steps:"
    log_info "1. Configure .env file: nano /var/www/cinestream/.env"
    log_info "2. Set domain: sudo ./deploy.sh set-domain <domain>"
    log_info "3. Configure DNS and install SSL: sudo ./deploy.sh install-ssl <domain>"
    log_info ""
    log_warning "Note: Some system optimizations may require reboot for full effect"
    log_info "To re-apply optimizations: sudo ./deploy.sh optimize-system"
}

# Install CPU affinity management scripts
install_cpu_affinity_scripts() {
    log_info "Installing CPU affinity management scripts..."
    
    # Determine script source directory (scripts are in the same repo)
    local SCRIPT_SOURCE_DIR="$SCRIPT_DIR/scripts"
    if [[ ! -d "$SCRIPT_SOURCE_DIR" ]]; then
        # Try alternative location (if deploy.sh is in root)
        SCRIPT_SOURCE_DIR="$(dirname "$SCRIPT_DIR")/scripts"
        if [[ ! -d "$SCRIPT_SOURCE_DIR" ]]; then
            # Create scripts directory if it doesn't exist
            mkdir -p "$SCRIPT_DIR/scripts"
            SCRIPT_SOURCE_DIR="$SCRIPT_DIR/scripts"
        fi
    fi
    
    # Install affinity scripts to /usr/local/bin
    if [[ -f "$SCRIPT_SOURCE_DIR/set_cpu_affinity.sh" ]]; then
        cp "$SCRIPT_SOURCE_DIR/set_cpu_affinity.sh" /usr/local/bin/cinestream-set-cpu-affinity.sh
        chmod +x /usr/local/bin/cinestream-set-cpu-affinity.sh
        log_success "Installed CPU affinity script"
    else
        log_warning "CPU affinity script not found at $SCRIPT_SOURCE_DIR/set_cpu_affinity.sh"
        log_info "Creating default CPU affinity script..."
        
        # Create a basic script if source not found
        cat > /usr/local/bin/cinestream-set-cpu-affinity.sh <<'AFFINITY_EOF'
#!/bin/bash
# CPU Affinity Management Script for CineStream
P_CORES="0-5"
E_CORES="6-13"

set_affinity() {
    local pattern="$1"
    local cores="$2"
    local pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    for pid in $pids; do
        taskset -pc "$cores" "$pid" >/dev/null 2>&1 || true
    done
}

case "${1:-all}" in
    mongodb) set_affinity "mongod" "$P_CORES" ;;
    nginx) set_affinity "nginx" "$P_CORES" ;;
    python) set_affinity "main.py.*--port" "$E_CORES" ;;
    all) set_affinity "mongod" "$P_CORES"; sleep 1; set_affinity "nginx" "$P_CORES"; sleep 1; set_affinity "main.py.*--port" "$E_CORES" ;;
esac
AFFINITY_EOF
        chmod +x /usr/local/bin/cinestream-set-cpu-affinity.sh
    fi
    
    # Create CPU affinity monitor service
    cat > "$SYSTEMD_DIR/cinestream-cpu-affinity.service" <<EOF
[Unit]
Description=CineStream CPU Affinity Manager
After=network.target mongodb.service nginx.service
PartOf=cinestream.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/cinestream-set-cpu-affinity.sh all
# Run again after a delay to catch any late-starting processes
ExecStartPost=/bin/bash -c 'sleep 10 && /usr/local/bin/cinestream-set-cpu-affinity.sh all || true'

[Install]
WantedBy=cinestream.target
EOF

    # Create CPU affinity monitor timer (runs every 5 minutes to ensure affinity is maintained)
    cat > "$SYSTEMD_DIR/cinestream-cpu-affinity.timer" <<EOF
[Unit]
Description=CineStream CPU Affinity Monitor Timer
Requires=cinestream-cpu-affinity.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable cinestream-cpu-affinity.service
    systemctl enable cinestream-cpu-affinity.timer
    systemctl start cinestream-cpu-affinity.timer
    
    log_success "CPU affinity management installed and enabled"
}

# Create master systemd target for coordinated startup
create_master_target() {
    log_info "Creating CineStream master startup target..."
    
    # Create a target that groups all CineStream services
    cat > "$SYSTEMD_DIR/cinestream.target" <<EOF
[Unit]
Description=CineStream Application Stack
After=network.target mongodb.service nginx.service
Wants=mongodb.service nginx.service

[Install]
WantedBy=multi-user.target
EOF

    # Create a startup service that ensures everything is running
    cat > "$SYSTEMD_DIR/cinestream-startup.service" <<EOF
[Unit]
Description=CineStream Startup Service
After=network-online.target mongodb.service nginx.service cinestream-cpu-affinity.service
Wants=network-online.target mongodb.service nginx.service
PartOf=cinestream.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 5 && for conf in /var/www/*/.deploy_config; do [ -f "\$conf" ] && source "\$conf" && PROCESS_COUNT=\${PROCESS_COUNT:-10} && START_PORT=\${START_PORT:-8001} && APP_NAME=\$(basename \$(dirname "\$conf")) && for i in \$(seq 0 \$((PROCESS_COUNT-1))); do systemctl start "\${APP_NAME}@\$((START_PORT+i)).service" 2>/dev/null || true; done; done'
# Set CPU affinity after starting all services
ExecStartPost=/bin/bash -c 'sleep 3 && /usr/local/bin/cinestream-set-cpu-affinity.sh all || true'
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cinestream.target
    systemctl enable cinestream-startup.service
    
    log_success "Master startup target created and enabled"
}

# Install MongoDB manually
install_mongodb() {
    local MONGO_VERSION="7.0.0"
    local MONGO_DIR="/opt/mongodb"
    local MONGO_TARBALL="mongodb-linux-x86_64-${MONGO_VERSION}.tgz"
    local MONGO_URL="https://fastdl.mongodb.org/linux/${MONGO_TARBALL}"
    
    if [[ -d "$MONGO_DIR/bin" ]]; then
        log_info "MongoDB already installed at $MONGO_DIR"
        return
    fi
    
    log_info "Downloading MongoDB ${MONGO_VERSION}..."
    cd /tmp
    wget "$MONGO_URL" || {
        log_error "Failed to download MongoDB. Please check your internet connection."
        exit 1
    }
    
    log_info "Extracting MongoDB..."
    tar -xzf "$MONGO_TARBALL"
    mv "mongodb-linux-x86_64-${MONGO_VERSION}" "$MONGO_DIR"
    rm "$MONGO_TARBALL"
    
    # Create data and log directories
    mkdir -p "$MONGO_DATA_DIR"
    mkdir -p "$MONGO_LOG_DIR"
    chown -R mongodb:mongodb "$MONGO_DATA_DIR" "$MONGO_LOG_DIR" 2>/dev/null || true
    
    # Create MongoDB user if it doesn't exist
    if ! id "mongodb" &>/dev/null; then
        useradd -r -s /bin/false mongodb || true
    fi
    
    # Create systemd service file with CPU affinity for P-cores (0-5)
    cat > "$SYSTEMD_DIR/mongodb.service" <<EOF
[Unit]
Description=MongoDB Database Server
Documentation=https://docs.mongodb.com/manual
After=network.target

[Service]
User=mongodb
Group=mongodb
Type=forking
# CPU Affinity: P-cores (0-5) for Intel i9-12900HK
CPUAffinity=0 1 2 3 4 5
ExecStart=$MONGO_DIR/bin/mongod --dbpath=$MONGO_DATA_DIR --logpath=$MONGO_LOG_DIR/mongod.log --logappend --fork
ExecStop=$MONGO_DIR/bin/mongod --shutdown --dbpath=$MONGO_DATA_DIR
PIDFile=$MONGO_DATA_DIR/mongod.lock
Restart=on-failure
RestartSec=10
# Ensure affinity is set after start
ExecStartPost=/bin/bash -c 'sleep 2 && /usr/local/bin/cinestream-set-cpu-affinity.sh mongodb || true'

[Install]
WantedBy=multi-user.target
EOF
    
    # Add MongoDB to PATH
    if ! grep -q "$MONGO_DIR/bin" /etc/profile; then
        echo "export PATH=\$PATH:$MONGO_DIR/bin" >> /etc/profile
    fi
    
    log_success "MongoDB installed successfully"
}

# Optimize system for web server + MongoDB workload
optimize_system() {
    log_info "Optimizing system for web server + MongoDB workload..."
    
    # Calculate system memory for MongoDB cache sizing
    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_gb=$((total_mem_kb / 1024 / 1024))
    
    log_info "Detected system memory: ${total_mem_gb}GB"
    
    # 1. Configure swap and swappiness (low swappiness for database workloads)
    log_info "Configuring swap and swappiness..."
    
    # Set swappiness to 1 (very low - only swap in emergency)
    # For web server + MongoDB: we want to avoid swapping database pages
    if ! grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "" >> /etc/sysctl.conf
        echo "# CineStream: Optimize for web server + MongoDB" >> /etc/sysctl.conf
        echo "vm.swappiness=1" >> /etc/sysctl.conf
        sysctl -w vm.swappiness=1
        log_success "Set vm.swappiness=1 (low swap usage for database)"
    else
        sed -i 's/^vm.swappiness=.*/vm.swappiness=1/' /etc/sysctl.conf
        sysctl -w vm.swappiness=1
        log_success "Updated vm.swappiness=1"
    fi
    
    # Set dirty ratio for better write performance
    if ! grep -q "^vm.dirty_ratio" /etc/sysctl.conf; then
        echo "vm.dirty_ratio=15" >> /etc/sysctl.conf
        sysctl -w vm.dirty_ratio=15
    fi
    
    if ! grep -q "^vm.dirty_background_ratio" /etc/sysctl.conf; then
        echo "vm.dirty_background_ratio=5" >> /etc/sysctl.conf
        sysctl -w vm.dirty_background_ratio=5
    fi
    
    # 2. Disable last accessed file metadata (noatime)
    log_info "Configuring filesystem mount options (noatime)..."
    
    # Get MongoDB data directory filesystem
    local mongo_fs
    mongo_fs=$(df -T "$MONGO_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $2}' || echo "")
    
    # Update /etc/fstab to add noatime for MongoDB data partition
    if [[ -n "$mongo_fs" ]] && [[ "$mongo_fs" != "tmpfs" ]]; then
        local mongo_device
        mongo_device=$(df "$MONGO_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $1}' || echo "")
        
        if [[ -n "$mongo_device" ]] && [[ "$mongo_device" != "tmpfs" ]]; then
            # Backup fstab
            cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
            
            # Check if already has noatime
            if ! grep -q "$mongo_device.*noatime" /etc/fstab; then
                # Add noatime to existing mount options
                sed -i "s|^\($mongo_device[[:space:]].*\)|\1,noatime|" /etc/fstab 2>/dev/null || {
                    log_warning "Could not automatically update /etc/fstab for noatime"
                    log_info "Manually add 'noatime' to the mount options for $mongo_device in /etc/fstab"
                }
                log_success "Added noatime to filesystem mount options"
            else
                log_info "noatime already configured for MongoDB data partition"
            fi
        fi
    fi
    
    # Also set noatime for root filesystem if it's the same
    local root_device
    root_device=$(findmnt -n -o SOURCE / | head -1)
    if [[ -n "$root_device" ]] && ! grep -q "$root_device.*noatime" /etc/fstab; then
        sed -i "s|^\($root_device[[:space:]].*\)|\1,noatime|" /etc/fstab 2>/dev/null || true
    fi
    
    # 3. Kernel parameters for web server workload
    log_info "Configuring kernel parameters for web server workload..."
    
    # TCP optimizations for high concurrency
    cat >> /etc/sysctl.conf <<'SYSCTL_EOF'

# TCP optimizations for web server
net.core.somaxconn=4096
net.core.netdev_max_backlog=5000
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_tw_recycle=0
net.ipv4.ip_local_port_range=10000 65535

# Increase file descriptor limits
fs.file-max=2097152

# Network buffer sizes
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Connection tracking
net.netfilter.nf_conntrack_max=262144
SYSCTL_EOF
    
    # Apply settings immediately
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
    log_success "Applied kernel parameters"
    
    # 4. Increase file descriptor limits
    log_info "Configuring file descriptor limits..."
    
    cat >> /etc/security/limits.conf <<'LIMITS_EOF'

# CineStream: Increase file descriptor limits for web server + MongoDB
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
mongodb soft nofile 64000
mongodb hard nofile 64000
LIMITS_EOF
    
    log_success "Configured file descriptor limits"
    
    # 5. MongoDB performance tuning
    log_info "Configuring MongoDB performance settings..."
    
    # Define MongoDB directory (should match install_mongodb)
    local MONGO_DIR="/opt/mongodb"
    local wt_cache_gb=""
    
    # Check if MongoDB is installed
    if [[ ! -d "$MONGO_DIR/bin" ]]; then
        log_warning "MongoDB not found at $MONGO_DIR, skipping MongoDB optimizations"
        log_info "Run 'sudo ./deploy.sh init-server' to install MongoDB first"
    else
        # Create MongoDB configuration file with performance optimizations
        local mongo_conf="$MONGO_DIR/mongod.conf"
        
        # Calculate WiredTiger cache size (50% of RAM, but max 32GB for MongoDB 7.0)
        if [[ $total_mem_gb -lt 8 ]]; then
            wt_cache_gb=2
        elif [[ $total_mem_gb -lt 16 ]]; then
            wt_cache_gb=$((total_mem_gb / 2))
        elif [[ $total_mem_gb -lt 64 ]]; then
            wt_cache_gb=$((total_mem_gb / 2))
        else
            wt_cache_gb=32  # MongoDB 7.0 max recommended
        fi
        
        log_info "Configuring WiredTiger cache: ${wt_cache_gb}GB"
        
        cat > "$mongo_conf" <<EOF
# MongoDB Configuration for CineStream
# Optimized for web server + database workload

storage:
  dbPath: $MONGO_DATA_DIR
  journal:
    enabled: true
    commitIntervalMs: 100
  wiredTiger:
    engineConfig:
      cacheSizeGB: $wt_cache_gb
      journalCompressor: snappy
      directoryForIndexes: false
    collectionConfig:
      blockCompressor: snappy
    indexConfig:
      prefixCompression: true

systemLog:
  destination: file
  logAppend: true
  path: $MONGO_LOG_DIR/mongod.log
  logRotate: reopen

net:
  port: 27017
  bindIp: 127.0.0.1
  maxIncomingConnections: 1000

processManagement:
  fork: true
  pidFilePath: $MONGO_DATA_DIR/mongod.lock

operationProfiling:
  mode: slowOp
  slowOpThresholdMs: 100

setParameter:
  # Connection pool settings
  connPoolMaxShardedConnsPerHost: 200
  connPoolMaxConnsPerHost: 200
  
  # Query execution
  internalQueryExecMaxBlockingSortBytes: 33554432
  
  # Write concern
  writePeriodicNoops: true
  periodicNoopIntervalSecs: 10
EOF
    
        chown mongodb:mongodb "$mongo_conf" 2>/dev/null || true
        log_success "Created MongoDB configuration: $mongo_conf"
        
        # Update MongoDB systemd service to use config file
        if [[ -f "$SYSTEMD_DIR/mongodb.service" ]]; then
            # Backup service file
            cp "$SYSTEMD_DIR/mongodb.service" "$SYSTEMD_DIR/mongodb.service.backup.$(date +%Y%m%d_%H%M%S)"
            
            # Update ExecStart to use config file
            sed -i "s|ExecStart=.*mongod.*|ExecStart=$MONGO_DIR/bin/mongod --config $mongo_conf|" "$SYSTEMD_DIR/mongodb.service"
            log_success "Updated MongoDB service to use configuration file"
        fi
    fi
    
    # 6. Disable transparent hugepages for MongoDB (recommended by MongoDB)
    log_info "Configuring transparent hugepages (disabled for MongoDB)..."
    
    cat > /etc/systemd/system/disable-transparent-hugepages.service <<'THP_EOF'
[Unit]
Description=Disable Transparent Hugepages for MongoDB
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongodb.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null'
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null'

[Install]
WantedBy=basic.target
THP_EOF
    
    systemctl daemon-reload
    systemctl enable disable-transparent-hugepages.service
    systemctl start disable-transparent-hugepages.service
    
    # Also set it immediately
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    
    log_success "Disabled transparent hugepages for MongoDB"
    
    # 7. I/O scheduler optimization (use deadline or none for SSDs)
    log_info "Configuring I/O scheduler..."
    
    # Detect if we're on SSD
    local is_ssd=false
    for disk in /sys/block/sd* /sys/block/nvme*; do
        if [[ -f "$disk/queue/rotational" ]]; then
            if [[ $(cat "$disk/queue/rotational" 2>/dev/null) == "0" ]]; then
                is_ssd=true
                break
            fi
        fi
    done
    
    if [[ "$is_ssd" == "true" ]]; then
        # Use none or mq-deadline for SSDs
        cat > /etc/systemd/system/configure-io-scheduler.service <<'IO_EOF'
[Unit]
Description=Configure I/O Scheduler for SSDs
After=sysinit.target
Before=mongodb.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for disk in /sys/block/sd* /sys/block/nvme*; do [ -f "$disk/queue/scheduler" ] && echo none > "$disk/queue/scheduler" 2>/dev/null || echo mq-deadline > "$disk/queue/scheduler" 2>/dev/null; done'

[Install]
WantedBy=basic.target
IO_EOF
        
        systemctl daemon-reload
        systemctl enable configure-io-scheduler.service
        systemctl start configure-io-scheduler.service
        log_success "Configured I/O scheduler for SSD (none/mq-deadline)"
    else
        log_info "HDD detected, using default I/O scheduler"
    fi
    
    # 8. Set readahead for MongoDB data directory
    log_info "Configuring readahead for MongoDB..."
    
    local mongo_block_device
    mongo_block_device=$(df "$MONGO_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' || echo "")
    
    if [[ -n "$mongo_block_device" ]] && [[ -f "/sys/block/$(basename "$mongo_block_device")/queue/read_ahead_kb" ]]; then
        echo 256 > "/sys/block/$(basename "$mongo_block_device")/queue/read_ahead_kb" 2>/dev/null || true
        log_success "Set readahead for MongoDB data device"
    fi
    
    log_success "System optimization complete!"
    log_info ""
    log_info "Optimizations applied:"
    log_info "  - Swappiness: 1 (minimal swap usage)"
    log_info "  - Filesystem: noatime (disable last access time)"
    log_info "  - TCP: Optimized for high concurrency"
    log_info "  - File descriptors: 65536"
    if [[ -d "$MONGO_DIR/bin" ]] && [[ -n "${wt_cache_gb:-}" ]]; then
        log_info "  - MongoDB: WiredTiger cache ${wt_cache_gb}GB, performance tuned"
        log_info "  - Transparent hugepages: Disabled (MongoDB requirement)"
    else
        log_info "  - MongoDB: Not installed (skipped MongoDB optimizations)"
    fi
    log_info "  - I/O scheduler: Optimized for storage type"
    log_info ""
    log_warning "Note: Some changes require reboot to take full effect"
    log_warning "Run 'sudo sysctl -p' to apply kernel parameters immediately"
}

# Configure Nginx CPU affinity to P-cores
configure_nginx_affinity() {
    log_info "Configuring Nginx CPU affinity to P-cores (0-5)..."
    
    # Create systemd override directory for nginx
    mkdir -p "$SYSTEMD_DIR/nginx.service.d"
    
    # Create override file with CPU affinity
    cat > "$SYSTEMD_DIR/nginx.service.d/cpu-affinity.conf" <<EOF
[Service]
# CPU Affinity: P-cores (0-5) for Intel i9-12900HK
CPUAffinity=0 1 2 3 4 5
# Ensure affinity is set after start
ExecStartPost=/bin/bash -c 'sleep 1 && /usr/local/bin/cinestream-set-cpu-affinity.sh nginx || true'
EOF
    
    log_success "Nginx CPU affinity configured"
}

# Stop all services
stop_all() {
    log_info "Stopping all services..."
    
    # Stop all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            # Default to 10 processes if not specified
            PROCESS_COUNT=${PROCESS_COUNT:-10}
            START_PORT=${START_PORT:-8001}
            APP_NAME=$(basename "$app_dir")
            
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                systemctl stop "${APP_NAME}@${port}.service" || true
            done
            systemctl stop "${APP_NAME}-refresh.timer" || true
        fi
    done
    
    # Stop Nginx and MongoDB
    systemctl stop nginx.service || true
    systemctl stop mongodb.service || true
    
    log_success "All services stopped"
}

# Start all services
start_all() {
    log_info "Starting all services..."
    
    # Start MongoDB first
    systemctl start mongodb.service
    sleep 2
    
    # Start Nginx
    systemctl start nginx.service
    
    # Start all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            # Default to 10 processes if not specified
            PROCESS_COUNT=${PROCESS_COUNT:-10}
            START_PORT=${START_PORT:-8001}
            APP_NAME=$(basename "$app_dir")
            
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                systemctl start "${APP_NAME}@${port}.service" || true
            done
            systemctl start "${APP_NAME}-refresh.timer" || true
        fi
    done
    
    log_success "All services started"
}

# Uninitialize server: Remove all CineStream components
uninit_server() {
    local REMOVE_MONGODB="${1:-no}"
    
    log_warning "This will remove ALL CineStream components from the server!"
    log_warning "This includes:"
    log_warning "  - All deployed sites and applications"
    log_warning "  - All systemd services"
    log_warning "  - All Nginx configurations"
    log_warning "  - CPU affinity configurations"
    log_warning "  - CineStream systemd targets and timers"
    if [[ "$REMOVE_MONGODB" == "yes" ]]; then
        log_warning "  - MongoDB service and data (DESTRUCTIVE!)"
    fi
    echo ""
    read -p "Are you sure you want to continue? Type 'yes' to confirm: " CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Cancelled."
        exit 0
    fi
    
    log_info "Starting server cleanup..."
    
    # Stop all services first
    log_info "Stopping all services..."
    stop_all
    
    # Remove all deployed sites
    log_info "Removing all deployed sites..."
    if [[ -d "$WWW_ROOT" ]]; then
        for app_dir in "$WWW_ROOT"/*; do
            if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
                source "$app_dir/.deploy_config"
                # Default to 10 processes if not specified
                PROCESS_COUNT=${PROCESS_COUNT:-10}
                START_PORT=${START_PORT:-8001}
                APP_NAME=$(basename "$app_dir")
                log_info "Removing site: $APP_NAME"
                
                # Stop and remove all process services
                for ((i=0; i<PROCESS_COUNT; i++)); do
                    local port=$((START_PORT + i))
                    systemctl stop "${APP_NAME}@${port}.service" 2>/dev/null || true
                    systemctl disable "${APP_NAME}@${port}.service" 2>/dev/null || true
                done
                
                # Stop and remove timer
                systemctl stop "${APP_NAME}-refresh.timer" 2>/dev/null || true
                systemctl disable "${APP_NAME}-refresh.timer" 2>/dev/null || true
                
                # Remove systemd files
                rm -f "$SYSTEMD_DIR/${APP_NAME}@.service"
                rm -f "$SYSTEMD_DIR/${APP_NAME}-refresh.service"
                rm -f "$SYSTEMD_DIR/${APP_NAME}-refresh.timer"
                
                # Remove Nginx config
                rm -f "$NGINX_CONF_DIR/${APP_NAME}.conf"
            fi
        done
        
        # Remove all app directories
        rm -rf "$WWW_ROOT"/*
        log_success "All deployed sites removed"
    fi
    
    # Remove CineStream systemd services and targets
    log_info "Removing CineStream systemd services..."
    systemctl stop cinestream-cpu-affinity.timer 2>/dev/null || true
    systemctl disable cinestream-cpu-affinity.timer 2>/dev/null || true
    systemctl stop cinestream-cpu-affinity.service 2>/dev/null || true
    systemctl disable cinestream-cpu-affinity.service 2>/dev/null || true
    systemctl stop cinestream-startup.service 2>/dev/null || true
    systemctl disable cinestream-startup.service 2>/dev/null || true
    systemctl stop cinestream.target 2>/dev/null || true
    systemctl disable cinestream.target 2>/dev/null || true
    
    # Remove systemd files
    rm -f "$SYSTEMD_DIR/cinestream.target"
    rm -f "$SYSTEMD_DIR/cinestream-startup.service"
    rm -f "$SYSTEMD_DIR/cinestream-cpu-affinity.service"
    rm -f "$SYSTEMD_DIR/cinestream-cpu-affinity.timer"
    
    # Remove CPU affinity script
    log_info "Removing CPU affinity management script..."
    rm -f /usr/local/bin/cinestream-set-cpu-affinity.sh
    
    # Remove Nginx CPU affinity override
    log_info "Removing Nginx CPU affinity configuration..."
    rm -rf "$SYSTEMD_DIR/nginx.service.d"
    
    # Remove MongoDB if requested
    if [[ "$REMOVE_MONGODB" == "yes" ]]; then
        log_warning "Removing MongoDB (this will delete all data!)..."
        systemctl stop mongodb.service 2>/dev/null || true
        systemctl disable mongodb.service 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/mongodb.service"
        
        # Ask for confirmation before deleting data
        read -p "Delete MongoDB data directory? Type 'yes' to confirm: " DELETE_DATA
        if [[ "$DELETE_DATA" == "yes" ]]; then
            rm -rf "$MONGO_DATA_DIR"
            rm -rf "$MONGO_LOG_DIR"
            log_warning "MongoDB data deleted"
        else
            log_info "MongoDB data preserved at $MONGO_DATA_DIR"
        fi
        
        # Remove MongoDB installation
        read -p "Remove MongoDB installation? Type 'yes' to confirm: " REMOVE_INSTALL
        if [[ "$REMOVE_INSTALL" == "yes" ]]; then
            rm -rf /opt/mongodb
            log_warning "MongoDB installation removed"
        fi
    else
        log_info "MongoDB service and data preserved (use 'uninit-server yes' to remove)"
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    # Clean up log files
    log_info "Cleaning up log files..."
    rm -f /var/log/cinestream-cpu-affinity.log
    rm -f /var/log/cinestream-cpu-affinity-monitor.log
    
    log_success "Server cleanup complete!"
    log_info "Remaining components:"
    if [[ "$REMOVE_MONGODB" != "yes" ]]; then
        log_info "  - MongoDB (service and data preserved)"
    fi
    log_info "  - Nginx (service preserved, configurations removed)"
    log_info "  - System packages (not removed)"
    log_info ""
    log_info "To completely reinitialize, run: $0 init-server"
}

# Deploy application automatically
deploy_application() {
    local APP_NAME="cinestream"
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    # Use global SCRIPT_DIR (defined at top of script)
    
    log_info "Deploying application to $APP_DIR..."
    
    # Create application directory
    mkdir -p "$APP_DIR"
    mkdir -p "$APP_DIR/src/static/movie_images"
    
    # Copy application files
    log_info "Copying application files..."
    if [[ -d "$SCRIPT_DIR/src" ]]; then
        cp -r "$SCRIPT_DIR/src" "$APP_DIR/"
        cp "$SCRIPT_DIR/requirements.txt" "$APP_DIR/" 2>/dev/null || true
    else
        log_error "Source directory not found: $SCRIPT_DIR/src"
        log_error "Please run deploy.sh from the project root directory"
        return 1
    fi
    
    # Create Python virtual environment (Clear Linux requirement: all Python code must run in venv)
    log_info "Creating Python virtual environment..."
    if [[ ! -d "$APP_DIR/venv" ]]; then
        python3 -m venv "$APP_DIR/venv"
        log_success "Created virtual environment at $APP_DIR/venv"
    else
        log_info "Virtual environment already exists"
    fi
    
    # Verify venv was created successfully
    if [[ ! -f "$APP_DIR/venv/bin/python" ]]; then
        log_error "Failed to create virtual environment. Python binary not found."
        return 1
    fi
    
    # Install Python dependencies
    log_info "Installing Python dependencies..."
    "$APP_DIR/venv/bin/pip" install --upgrade pip --quiet
    "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" --quiet
    
    # Create .env file template if it doesn't exist
    if [[ ! -f "$APP_DIR/.env" ]]; then
        log_info "Creating .env file template..."
        # Generate SECRET_KEY using venv Python (Clear Linux requirement: use venv for all Python code)
        local secret_key
        secret_key=$("$APP_DIR/venv/bin/python" -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null || echo "change-me-in-production")
        cat > "$APP_DIR/.env" <<EOF
# MongoDB connection (default: no authentication)
MONGO_URI=mongodb://127.0.0.1:27017/movie_db

# If MongoDB has authentication enabled:
# MONGO_URI=mongodb://username:password@127.0.0.1:27017/movie_db?authSource=admin

# Anthropic API key (REQUIRED - get from https://console.anthropic.com/)
ANTHROPIC_API_KEY=your-api-key-here

# Flask secret key (auto-generated)
SECRET_KEY=$secret_key

# Optional: Claude model selection (haiku = fastest/cheapest, sonnet = more capable)
CLAUDE_MODEL=haiku
EOF
        chmod 600 "$APP_DIR/.env"
        log_warning ".env file created with default values. Please update ANTHROPIC_API_KEY!"
    else
        log_info ".env file already exists, skipping creation"
    fi
    
    # Create deployment configuration
    log_info "Creating deployment configuration..."
    cat > "$APP_DIR/.deploy_config" <<EOF
APP_NAME=$APP_NAME
START_PORT=8001
PROCESS_COUNT=10
DOMAIN_NAME=""
EOF
    
    # Initialize database (if .env is configured)
    log_info "Initializing database..."
    if grep -q "your-api-key-here" "$APP_DIR/.env" 2>/dev/null; then
        log_warning "Skipping database initialization - please update ANTHROPIC_API_KEY in .env first"
    else
        if "$APP_DIR/venv/bin/python" "$APP_DIR/src/scripts/init_db.py" 2>/dev/null; then
            log_success "Database initialized"
        else
            log_warning "Database initialization failed (may need .env configuration)"
        fi
    fi
    
    # Verify venv exists before creating services
    if [[ ! -f "$APP_DIR/venv/bin/python" ]]; then
        log_error "Virtual environment not found. Cannot create services."
        return 1
    fi
    
    # Create systemd service template
    log_info "Creating systemd services..."
    log_info "All Python processes will use venv: $APP_DIR/venv/bin/python (Clear Linux requirement)"
    local SERVICE_USER
    # Use SUDO_USER if available (when running with sudo), otherwise use current user
    if [[ -n "${SUDO_USER:-}" ]]; then
        SERVICE_USER="$SUDO_USER"
    else
        SERVICE_USER=$(whoami)
    fi
    
    cat > "$SYSTEMD_DIR/${APP_NAME}@.service" <<EOF
[Unit]
Description=CineStream Web Worker (Port %i)
After=network.target mongodb.service
PartOf=cinestream.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/src/main.py --port %i
Restart=always
RestartSec=10
CPUAffinity=6 7 8 9 10 11 12 13
ExecStartPost=/bin/bash -c 'sleep 1 && /usr/local/bin/cinestream-set-cpu-affinity.sh python || true'

[Install]
WantedBy=cinestream.target
EOF
    
    # Create daily refresh service
    log_info "Creating daily refresh service and timer..."
    cat > "$SYSTEMD_DIR/${APP_NAME}-refresh.service" <<EOF
[Unit]
Description=CineStream Daily Refresh Job
After=network.target mongodb.service
PartOf=cinestream.target

[Service]
Type=oneshot
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/src/scripts/daily_refresh.py
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=cinestream.target
EOF

    # Create daily refresh timer (runs at 06:00 AM daily, with catch-up after power outages)
    cat > "$SYSTEMD_DIR/${APP_NAME}-refresh.timer" <<EOF
[Unit]
Description=CineStream Daily Refresh Timer
Requires=${APP_NAME}-refresh.service

[Timer]
# Run daily at 06:00 AM
OnCalendar=06:00
# Persistent=true ensures missed runs are caught up after system boot/power outage
Persistent=true
# Randomize start time within 5 minutes to avoid thundering herd
RandomizedDelaySec=300
# Accuracy: allow 1 hour window for execution
AccuracySec=1h

[Install]
WantedBy=timers.target
EOF

    # Reload systemd
    systemctl daemon-reload
    
    # Enable and start the timer
    systemctl enable "${APP_NAME}-refresh.timer" 2>/dev/null || true
    systemctl start "${APP_NAME}-refresh.timer" 2>/dev/null || true
    
    # Enable and start all 10 processes
    log_info "Starting application processes..."
    for port in {8001..8010}; do
        systemctl enable "${APP_NAME}@${port}.service" 2>/dev/null || true
        systemctl start "${APP_NAME}@${port}.service" 2>/dev/null || true
    done
    
    # Configure firewall
    log_info "Configuring firewall..."
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-service=http 2>/dev/null || true
        firewall-cmd --permanent --add-service=https 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_success "Firewall configured"
    else
        log_warning "firewall-cmd not found, skipping firewall configuration"
    fi
    
    # Wait a moment for processes to start
    sleep 2
    
    # Check if processes are running
    local running=0
    for port in {8001..8010}; do
        if systemctl is-active --quiet "${APP_NAME}@${port}.service" 2>/dev/null; then
            ((running++))
        fi
    done
    
    if [[ $running -gt 0 ]]; then
        log_success "Application deployed successfully!"
        log_info "  - $running/10 processes running"
        log_info "  - Application directory: $APP_DIR"
        log_info "  - Services: ${APP_NAME}@8001.service to ${APP_NAME}@8010.service"
    else
        log_warning "Application deployed but processes may not be running"
        log_warning "Check .env file and logs: sudo journalctl -u ${APP_NAME}@8001.service"
    fi
}

# Auto-detect application name (finds first app in /var/www with .deploy_config)
detect_app_name() {
    local APP_NAME=""
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            APP_NAME=$(basename "$app_dir")
            echo "$APP_NAME"
            return 0
        fi
    done
    return 1
}

# Install SSL certificate for an application
install_ssl() {
    local DOMAIN="${1:-}"
    
    if [[ -z "$DOMAIN" ]]; then
        log_error "Usage: $0 install-ssl <domain>"
        log_error "Example: $0 install-ssl movies.example.com"
        exit 1
    fi
    
    # Auto-detect app name
    local APP_NAME
    APP_NAME=$(detect_app_name)
    if [[ -z "$APP_NAME" ]]; then
        log_error "No application found in $WWW_ROOT"
        log_error "Please deploy an application first"
        exit 1
    fi
    
    log_info "Detected application: $APP_NAME"
    
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    local NGINX_CONF="$NGINX_CONF_DIR/${APP_NAME}.conf"
    
    if [[ ! -f "$NGINX_CONF" ]]; then
        log_error "Nginx configuration not found for '$APP_NAME'"
        log_error "Please run 'set-domain' first: $0 set-domain $DOMAIN"
        exit 1
    fi
    
    log_info "Installing SSL certificate for '$DOMAIN'..."
    
    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        log_info "Certbot not found. Installing certbot..."
        swupd bundle-add certbot -y || {
            log_error "Failed to install certbot. Please install manually: swupd bundle-add certbot"
            exit 1
        }
        log_success "Certbot installed"
    fi
    
    # Verify DNS is pointing to this server
    log_info "Verifying DNS configuration..."
    local SERVER_IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "")
    
    if [[ -z "$SERVER_IP" ]]; then
        log_warning "Could not determine server IP. Skipping DNS verification."
    else
        local DNS_IP
        DNS_IP=$(dig +short "$DOMAIN" A | head -n1)
        
        if [[ -z "$DNS_IP" ]]; then
            log_warning "DNS lookup failed for $DOMAIN. Make sure DNS is configured."
        elif [[ "$DNS_IP" != "$SERVER_IP" ]]; then
            log_warning "DNS mismatch detected!"
            log_warning "  Domain $DOMAIN points to: $DNS_IP"
            log_warning "  This server IP is: $SERVER_IP"
            log_warning "  Certificate installation may fail if DNS is not correct."
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Cancelled. Please fix DNS first."
                exit 1
            fi
        else
            log_success "DNS verified: $DOMAIN -> $SERVER_IP"
        fi
    fi
    
    # Ensure ACME challenge directory exists
    mkdir -p /var/www/html/.well-known/acme-challenge
    chmod 755 /var/www/html/.well-known/acme-challenge
    
    # Install certificate using certbot
    log_info "Requesting SSL certificate from Let's Encrypt..."
    log_info "This may take a few moments..."
    
    # Use webroot method (doesn't require nginx plugin, works with our existing config)
    if certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --non-interactive --agree-tos --email "admin@${DOMAIN}" 2>&1 | tee /tmp/certbot_output.log; then
        log_success "SSL certificate installed successfully!"
    else
        log_error "SSL certificate installation failed!"
        log_error "Check the output above for details."
        log_error ""
        log_error "Common issues:"
        log_error "  1. DNS not pointing to this server"
        log_error "  2. Port 80 not accessible from internet"
        log_error "  3. Firewall blocking port 80"
        log_error "  4. Domain already has a certificate (use --force-renewal to renew)"
        exit 1
    fi
    
    # Update Nginx configuration with SSL paths
    log_info "Updating Nginx configuration with SSL certificate paths..."
    
    # Backup original config
    cp "$NGINX_CONF" "${NGINX_CONF}.backup"
    
    # Uncomment and update SSL certificate paths
    sed -i "s|# ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;|ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;|" "$NGINX_CONF"
    sed -i "s|# ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;|ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;|" "$NGINX_CONF"
    sed -i "s|# ssl_protocols|ssl_protocols|" "$NGINX_CONF"
    sed -i "s|# ssl_ciphers|ssl_ciphers|" "$NGINX_CONF"
    sed -i "s|# ssl_prefer_server_ciphers|ssl_prefer_server_ciphers|" "$NGINX_CONF"
    sed -i "s|# add_header Strict-Transport-Security|add_header Strict-Transport-Security|" "$NGINX_CONF"
    
    log_success "Nginx configuration updated"
    
    # Test Nginx configuration
    log_info "Testing Nginx configuration..."
    if nginx -t 2>/dev/null; then
        log_success "Nginx configuration is valid"
        
        # Reload Nginx
        log_info "Reloading Nginx..."
        if systemctl reload nginx.service 2>/dev/null; then
            log_success "Nginx reloaded successfully"
            log_info ""
            log_success "SSL certificate is now active for $DOMAIN!"
            log_info ""
            log_info "Certificate details:"
            log_info "  - Certificate: /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
            log_info "  - Private Key: /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            log_info "  - Valid for: 90 days"
            log_info "  - Auto-renewal: Enabled via certbot.timer"
            log_info ""
            log_info "Test your HTTPS site: https://${DOMAIN}"
        else
            log_error "Failed to reload Nginx. Check logs: journalctl -u nginx.service"
            log_info "Restoring backup configuration..."
            mv "${NGINX_CONF}.backup" "$NGINX_CONF"
            exit 1
        fi
    else
        log_error "Nginx configuration test failed!"
        log_error "Restoring backup configuration..."
        mv "${NGINX_CONF}.backup" "$NGINX_CONF"
        exit 1
    fi
    
    # Ensure certbot auto-renewal is enabled
    log_info "Ensuring certbot auto-renewal is enabled..."
    systemctl enable certbot.timer 2>/dev/null || true
    systemctl start certbot.timer 2>/dev/null || true
    
    if systemctl is-active --quiet certbot.timer; then
        log_success "Certbot auto-renewal is active"
    else
        log_warning "Certbot auto-renewal timer is not active. Enable manually:"
        log_warning "  systemctl enable --now certbot.timer"
    fi
}

# Set domain for an application
set_domain() {
    local DOMAIN="${1:-}"
    
    if [[ -z "$DOMAIN" ]]; then
        log_error "Usage: $0 set-domain <domain>"
        log_error "Example: $0 set-domain movies.example.com"
        exit 1
    fi
    
    # Auto-detect app name
    local APP_NAME
    APP_NAME=$(detect_app_name)
    if [[ -z "$APP_NAME" ]]; then
        log_error "No application found in $WWW_ROOT"
        log_error "Please deploy an application first"
        exit 1
    fi
    
    log_info "Detected application: $APP_NAME"
    
    local APP_DIR="$WWW_ROOT/$APP_NAME"
    
    if [[ ! -f "$APP_DIR/.deploy_config" ]]; then
        log_error "Application '$APP_NAME' is not properly deployed (missing .deploy_config)"
        exit 1
    fi
    
    # Load existing config
    source "$APP_DIR/.deploy_config"
    PROCESS_COUNT=${PROCESS_COUNT:-10}
    START_PORT=${START_PORT:-8001}
    
    log_info "Setting domain '$DOMAIN' for application '$APP_NAME'..."
    
    # Update .deploy_config with domain
    if grep -q "^DOMAIN_NAME=" "$APP_DIR/.deploy_config" 2>/dev/null; then
        # Update existing domain
        sed -i "s|^DOMAIN_NAME=.*|DOMAIN_NAME=\"$DOMAIN\"|" "$APP_DIR/.deploy_config"
        log_info "Updated domain in .deploy_config"
    else
        # Add new domain
        echo "DOMAIN_NAME=\"$DOMAIN\"" >> "$APP_DIR/.deploy_config"
        log_info "Added domain to .deploy_config"
    fi
    
    # Generate Nginx configuration
    log_info "Generating Nginx configuration..."
    
    local UPSTREAM_NAME="${APP_NAME}_backend"
    local NGINX_CONF="$NGINX_CONF_DIR/${APP_NAME}.conf"
    
    cat > "$NGINX_CONF" <<EOF
# Upstream backend for ${APP_NAME} - ${PROCESS_COUNT} worker processes
upstream ${UPSTREAM_NAME} {
    ip_hash;  # Sticky sessions - same IP routes to same backend
EOF
    
    # Add all backend servers
    for ((i=0; i<PROCESS_COUNT; i++)); do
        local port=$((START_PORT + i))
        echo "    server 127.0.0.1:${port};" >> "$NGINX_CONF"
    done
    
    cat >> "$NGINX_CONF" <<EOF
}

# HTTP server - redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    
    # Allow Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }
    
    # Redirect all other traffic to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Catch-all HTTP server - redirect any HTTP requests to HTTPS
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    # Allow Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }
    
    # Redirect all other traffic to HTTPS (using the configured domain)
    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    
    # SSL configuration (update paths after certificate generation)
    # ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    # SSL settings (uncomment after certificate is installed)
    # ssl_protocols TLSv1.2 TLSv1.3;
    # ssl_ciphers HIGH:!aNULL:!MD5;
    # ssl_prefer_server_ciphers on;
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # Logging
    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;
    
    # Proxy settings
    location / {
        proxy_pass http://${UPSTREAM_NAME};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # WebSocket support (if needed in future)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # Static files (if served directly by Nginx)
    location /static/ {
        alias ${APP_DIR}/src/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
EOF
    
    log_success "Nginx configuration generated: $NGINX_CONF"
    
    # Test Nginx configuration
    log_info "Testing Nginx configuration..."
    if nginx -t 2>/dev/null; then
        log_success "Nginx configuration is valid"
        
        # Reload Nginx
        log_info "Reloading Nginx..."
        if systemctl reload nginx.service 2>/dev/null; then
            log_success "Nginx reloaded successfully"
            log_info ""
            log_info "Domain '$DOMAIN' is now configured for '$APP_NAME'"
            log_info ""
            log_info "Next steps:"
            log_info "1. Point DNS A record for '$DOMAIN' to this server's IP address"
            log_info "2. Wait for DNS propagation (can take up to 48 hours)"
            log_info "3. Install SSL certificate:"
            log_info "   $0 install-ssl $DOMAIN"
        else
            log_error "Failed to reload Nginx. Check logs: journalctl -u nginx.service"
            exit 1
        fi
    else
        log_error "Nginx configuration test failed!"
        log_error "Please check the configuration file: $NGINX_CONF"
        exit 1
    fi
}

# Main command dispatcher
main() {
    check_root
    check_clear_linux
    
    case "${1:-}" in
        init-server)
            init_server
            ;;
        uninit-server)
            uninit_server "${2:-no}"
            ;;
        stop-all)
            stop_all
            ;;
        start-all)
            start_all
            ;;
        enable-autostart)
            enable_autostart
            ;;
        status)
            show_status
            ;;
        optimize-system)
            optimize_system
            ;;
        set-domain)
            set_domain "${2:-}"
            ;;
        install-ssl)
            install_ssl "${2:-}"
            ;;
        *)
            echo "CineStream Master Deployment Script v21.0"
            echo ""
            echo "Usage: $0 <command> [arguments]"
            echo ""
            echo "Commands:"
            echo "  init-server                    Initialize Clear Linux server"
            echo "  uninit-server [yes]            Remove all CineStream components"
            echo "                                (use 'yes' to also remove MongoDB)"
            echo "  start-all                      Start all services"
            echo "  stop-all                       Stop all services"
            echo "  enable-autostart               Enable all services to start on boot"
            echo "  status                         Show status of all services"
            echo "  optimize-system                Optimize system for web server + MongoDB"
            echo "                                (swap, swappiness, noatime, kernel params)"
            echo "  set-domain <domain>            Configure domain for the application"
            echo "                                Example: $0 set-domain movies.example.com"
            echo "  install-ssl <domain>          Install SSL certificate for a domain"
            echo "                                Example: $0 install-ssl movies.example.com"
            exit 1
            ;;
    esac
}

# Enable all services to auto-start on boot
enable_autostart() {
    log_info "Enabling all services for auto-start on boot..."
    
    # Ensure CPU affinity management is installed
    if [[ ! -f /usr/local/bin/cinestream-set-cpu-affinity.sh ]]; then
        log_info "CPU affinity management not found. Installing..."
        install_cpu_affinity_scripts
    fi
    
    # Enable CPU affinity services (critical for proper CPU core assignment)
    log_info "Enabling CPU affinity management services..."
    systemctl enable cinestream-cpu-affinity.service 2>/dev/null || true
    systemctl enable cinestream-cpu-affinity.timer 2>/dev/null || true
    systemctl start cinestream-cpu-affinity.timer 2>/dev/null || true
    
    # Enable core services
    systemctl enable mongodb.service 2>/dev/null || true
    systemctl enable nginx.service 2>/dev/null || true
    
    # Create master target if it doesn't exist
    if [[ ! -f "$SYSTEMD_DIR/cinestream.target" ]]; then
        create_master_target
    fi
    
    # Enable all app services
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            # Default to 10 processes if not specified
            PROCESS_COUNT=${PROCESS_COUNT:-10}
            START_PORT=${START_PORT:-8001}
            APP_NAME=$(basename "$app_dir")
            
            log_info "Enabling $APP_NAME services..."
            
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                systemctl enable "${APP_NAME}@${port}.service" 2>/dev/null || true
            done
            
            # Enable daily refresh timer
            systemctl enable "${APP_NAME}-refresh.timer" 2>/dev/null || true
        fi
    done
    
    # Enable master target
    systemctl enable cinestream.target 2>/dev/null || true
    systemctl enable cinestream-startup.service 2>/dev/null || true
    
    systemctl daemon-reload
    
    log_success "All services enabled for auto-start on boot!"
    log_info "CPU affinity management is active and will maintain proper CPU core assignment"
    log_info "Run 'sudo systemctl status cinestream.target' to verify"
    log_info "Run 'sudo systemctl status cinestream-cpu-affinity.timer' to check affinity timer"
}

# Show status of all services
show_status() {
    echo "=== CineStream System Status ==="
    echo ""
    
    echo "--- Core Services ---"
    echo -n "MongoDB:     "
    systemctl is-active mongodb.service 2>/dev/null || echo "not installed"
    echo -n "Nginx:       "
    systemctl is-active nginx.service 2>/dev/null || echo "not installed"
    echo ""
    
    echo "--- Auto-Start Status ---"
    echo -n "MongoDB enabled:     "
    systemctl is-enabled mongodb.service 2>/dev/null || echo "no"
    echo -n "Nginx enabled:       "
    systemctl is-enabled nginx.service 2>/dev/null || echo "no"
    echo -n "CineStream target:   "
    systemctl is-enabled cinestream.target 2>/dev/null || echo "no"
    echo ""
    
    echo "--- Application Services ---"
    for app_dir in "$WWW_ROOT"/*; do
        if [[ -d "$app_dir" && -f "$app_dir/.deploy_config" ]]; then
            source "$app_dir/.deploy_config"
            # Default to 10 processes if not specified
            PROCESS_COUNT=${PROCESS_COUNT:-10}
            START_PORT=${START_PORT:-8001}
            APP_NAME=$(basename "$app_dir")
            
            echo "[$APP_NAME] Domain: $DOMAIN_NAME"
            
            local running=0
            local total=$PROCESS_COUNT
            for ((i=0; i<PROCESS_COUNT; i++)); do
                local port=$((START_PORT + i))
                if systemctl is-active --quiet "${APP_NAME}@${port}.service" 2>/dev/null; then
                    ((running++))
                fi
            done
            
            echo "  Processes: $running/$total running (ports $START_PORT-$((START_PORT + PROCESS_COUNT - 1)))"
            echo -n "  Auto-start: "
            systemctl is-enabled "${APP_NAME}@${START_PORT}.service" 2>/dev/null || echo "no"
            echo -n "  Daily refresh: "
            systemctl is-active "${APP_NAME}-refresh.timer" 2>/dev/null || echo "inactive"
            echo ""
        fi
    done
    
    if [[ ! -d "$WWW_ROOT" ]] || [[ -z "$(ls -A $WWW_ROOT 2>/dev/null)" ]]; then
        echo "  No applications deployed yet."
        echo ""
    fi
}

main "$@"

