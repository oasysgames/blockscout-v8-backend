#!/bin/bash

# Analytics Service Runner Script
# Runs analytics service independently from root directory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYTICS_DIR="${SCRIPT_DIR}/analytics"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"
}

# Check if analytics directory exists
check_analytics_dir() {
    if [ ! -d "$ANALYTICS_DIR" ]; then
        error "Analytics directory not found: $ANALYTICS_DIR"
        exit 1
    fi
    
    if [ ! -f "$ANALYTICS_DIR/docker-compose.yml" ]; then
        error "Analytics docker-compose.yml not found"
        exit 1
    fi
    
    log "Analytics directory verified: $ANALYTICS_DIR"
}

# Load environment variables if .env exists
load_env() {
    if [ -f "${ANALYTICS_DIR}/.env" ]; then
        log "Loading environment variables from analytics/.env"
        set -a
        source "${ANALYTICS_DIR}/.env"
        set +a
    else
        warn "No .env file found in analytics/ directory"
        warn "Using default environment variables"
    fi
}

# Main command handler
main() {
    command="${1:-start}"
    
    check_analytics_dir
    
    cd "$ANALYTICS_DIR"
    
    # Load environment
    load_env
    
    case "$command" in
        "start"|"up")
            log "Starting analytics service..."
            docker compose up -d
            ;;
        "stop"|"down") 
            log "Stopping analytics service..."
            docker compose down
            ;;
        "restart")
            log "Restarting analytics service..."
            docker compose down
            sleep 2
            docker compose up -d
            ;;
        "logs")
            log "Showing analytics service logs..."
            docker compose logs -f access-log-analyzer
            ;;
        "test")
            log "Running analytics test..."
            docker compose run --rm access-log-analyzer scripts/access-log-analyzer.sh test
            ;;
        "analyze")
            local date_param="$2"
            if [ -n "$date_param" ]; then
                log "Running analysis for date: $date_param"
                docker compose run --rm access-log-analyzer scripts/access-log-analyzer.sh analyze "$date_param"
            else
                log "Running analysis for yesterday..."
                docker compose run --rm access-log-analyzer scripts/access-log-analyzer.sh analyze
            fi
            ;;
        "status")
            log "Analytics service status:"
            docker compose ps
            ;;
        "shell")
            log "Opening shell in analytics container..."
            docker compose run --rm access-log-analyzer /bin/sh
            ;;
        *)
            echo "Analytics Service Runner"
            echo ""
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  start, up     - Start analytics service (default)"
            echo "  stop, down    - Stop analytics service"
            echo "  restart       - Restart analytics service"
            echo "  logs          - Show service logs"
            echo "  status        - Show service status"
            echo "  test          - Run test analysis"
            echo "  analyze [date] - Run analysis (default: yesterday)"
            echo "  shell         - Open shell in container"
            echo ""
            echo "Examples:"
            echo "  $0 start                          # Start analytics service"
            echo "  $0 analyze 2023-12-15            # Analyze specific date"
            echo "  $0 logs                          # Monitor logs"
            echo ""
            echo "Environment:"
            echo "  Create analytics/.env file with required variables"
            echo "  Copy from analytics/env.example"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"