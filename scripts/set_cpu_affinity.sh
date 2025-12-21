#!/bin/bash
# CPU Affinity Management Script for CineStream
# Sets MongoDB and Nginx to P-cores, Python apps to E-cores on Intel i9-12900HK

set -euo pipefail

# CPU core configuration for Intel i9-12900HK
# P-cores (Performance): 0-5 (6 cores, 12 threads with HT)
# E-cores (Efficiency): 6-13 (8 cores, 8 threads)
P_CORES="0-5"      # P-cores for MongoDB and Nginx
E_CORES="6-13"     # E-cores for Python apps

LOG_FILE="/var/log/cinestream-cpu-affinity.log"

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Set CPU affinity for a process by name pattern
set_affinity_by_name() {
    local pattern="$1"
    local cores="$2"
    local description="$3"
    
    # Find all PIDs matching the pattern
    local pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    
    if [[ -z "$pids" ]]; then
        return 0
    fi
    
    for pid in $pids; do
        # Check if process is still running
        if ! kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        
        # Set new affinity
        if taskset -pc "$cores" "$pid" >/dev/null 2>&1; then
            log_info "Set $description (PID $pid) to cores $cores"
        else
            log_info "Failed to set affinity for PID $pid ($description)"
        fi
    done
}

# Set MongoDB affinity to P-cores
set_mongodb_affinity() {
    log_info "Setting MongoDB affinity to P-cores ($P_CORES)..."
    
    # Try to set affinity for mongod process
    set_affinity_by_name "mongod" "$P_CORES" "MongoDB"
    
    # Also try to set via systemd if service is running
    if systemctl is-active --quiet mongodb.service 2>/dev/null; then
        local main_pid=$(systemctl show -p MainPID mongodb.service | cut -d= -f2)
        if [[ -n "$main_pid" && "$main_pid" != "0" ]]; then
            # Set affinity for main process and all children
            if taskset -pc "$P_CORES" "$main_pid" >/dev/null 2>&1; then
                log_info "Set MongoDB main process (PID $main_pid) to P-cores"
            fi
            
            # Set affinity for all child processes
            local child_pids=$(pgrep -P "$main_pid" 2>/dev/null || true)
            for child_pid in $child_pids; do
                if taskset -pc "$P_CORES" "$child_pid" >/dev/null 2>&1; then
                    log_info "Set MongoDB child process (PID $child_pid) to P-cores"
                fi
            done
        fi
    fi
}

# Set Nginx affinity to P-cores
set_nginx_affinity() {
    log_info "Setting Nginx affinity to P-cores ($P_CORES)..."
    
    # Try to set affinity for nginx processes
    set_affinity_by_name "nginx" "$P_CORES" "Nginx"
    
    # Also try to set via systemd if service is running
    if systemctl is-active --quiet nginx.service 2>/dev/null; then
        local main_pid=$(systemctl show -p MainPID nginx.service | cut -d= -f2)
        if [[ -n "$main_pid" && "$main_pid" != "0" ]]; then
            # Set affinity for main process
            if taskset -pc "$P_CORES" "$main_pid" >/dev/null 2>&1; then
                log_info "Set Nginx main process (PID $main_pid) to P-cores"
            fi
            
            # Set affinity for all worker processes
            local worker_pids=$(pgrep -P "$main_pid" 2>/dev/null || true)
            for worker_pid in $worker_pids; do
                if taskset -pc "$P_CORES" "$worker_pid" >/dev/null 2>&1; then
                    log_info "Set Nginx worker process (PID $worker_pid) to P-cores"
                fi
            done
            
            # Also set affinity for any nginx worker processes (they might not be direct children)
            local all_nginx_pids=$(pgrep nginx 2>/dev/null || true)
            for nginx_pid in $all_nginx_pids; do
                if [[ "$nginx_pid" != "$main_pid" ]]; then
                    if taskset -pc "$P_CORES" "$nginx_pid" >/dev/null 2>&1; then
                        log_info "Set Nginx process (PID $nginx_pid) to P-cores"
                    fi
                fi
            done
        fi
    fi
}

# Set Python app affinity to E-cores
set_python_apps_affinity() {
    log_info "Setting Python app affinity to E-cores ($E_CORES)..."
    
    # Find all Python processes running main.py
    local python_pids=$(pgrep -f "main.py.*--port" 2>/dev/null || true)
    
    if [[ -z "$python_pids" ]]; then
        log_info "No Python app processes found"
        return 0
    fi
    
    for pid in $python_pids; do
        # Check if process is still running
        if ! kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        
        # Set affinity to E-cores
        if taskset -pc "$E_CORES" "$pid" >/dev/null 2>&1; then
            log_info "Set Python app (PID $pid) to E-cores"
        else
            log_info "Failed to set affinity for Python app PID $pid"
        fi
    done
}

# Set affinity for all processes
set_all_affinity() {
    log_info "=== Setting CPU affinity for all CineStream processes ==="
    set_mongodb_affinity
    sleep 1
    set_nginx_affinity
    sleep 1
    set_python_apps_affinity
    log_info "=== CPU affinity setup complete ==="
}

# Main execution
main() {
    # Create log file if it doesn't exist
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    case "${1:-all}" in
        mongodb)
            set_mongodb_affinity
            ;;
        nginx)
            set_nginx_affinity
            ;;
        python)
            set_python_apps_affinity
            ;;
        all)
            set_all_affinity
            ;;
        *)
            echo "Usage: $0 [mongodb|nginx|python|all]"
            echo "  mongodb - Set affinity for MongoDB only"
            echo "  nginx   - Set affinity for Nginx only"
            echo "  python  - Set affinity for Python apps only"
            echo "  all     - Set affinity for all processes (default)"
            exit 1
            ;;
    esac
}

main "$@"

