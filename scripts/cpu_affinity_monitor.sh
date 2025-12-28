#!/bin/bash
# CPU Affinity Monitor - Ensures CPU affinity is maintained
# Runs periodically to correct any processes that lost their affinity
# Compatible with CachyOS/Arch Linux and other Linux distributions

set -euo pipefail

# Use the installed script path (primary) or local script path (fallback)
AFFINITY_SCRIPT="/usr/local/bin/cinestream-set-cpu-affinity.sh"
if [[ ! -f "$AFFINITY_SCRIPT" ]]; then
    # Fallback to local script if installed version doesn't exist
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AFFINITY_SCRIPT="$SCRIPT_DIR/set_cpu_affinity.sh"
fi
LOG_FILE="/var/log/cinestream-cpu-affinity-monitor.log"

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check and fix affinity for all processes
check_and_fix_affinity() {
    log_info "Checking CPU affinity..."
    
    if [[ ! -f "$AFFINITY_SCRIPT" ]]; then
        log_info "ERROR: Affinity script not found at $AFFINITY_SCRIPT"
        return 1
    fi
    
    # Run the affinity script
    bash "$AFFINITY_SCRIPT" all
}

# Main loop (for daemon mode)
daemon_mode() {
    log_info "Starting CPU affinity monitor daemon..."
    
    while true; do
        check_and_fix_affinity
        # Check every 30 seconds
        sleep 30
    done
}

# One-time check
one_time_check() {
    check_and_fix_affinity
}

# Main execution
main() {
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    case "${1:-once}" in
        daemon)
            daemon_mode
            ;;
        once)
            one_time_check
            ;;
        *)
            echo "Usage: $0 [daemon|once]"
            echo "  daemon - Run continuously, checking every 30 seconds"
            echo "  once   - Run once and exit (default)"
            exit 1
            ;;
    esac
}

main "$@"

