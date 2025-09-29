#!/bin/bash

# Daily Access Log Analysis Scheduler
# Runs access log analyzer daily at 2AM with retry on failure

set -e

ANALYZER_SCRIPT="/scripts/access-log-analyzer.sh"
MAX_RETRIES=3
RETRY_DELAY=300  # 5 minutes

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"
}

# Wait until 2AM
wait_for_2am() {
    while true; do
        current_hour=$(date '+%H')
        if [ "$current_hour" = "02" ]; then
            log "It's 2AM, starting daily access log analysis"
            return 0
        fi
        
        log "Waiting for 2AM (current time: $(date '+%I:%M %p'))"
        sleep 300  # Check every 5 minutes
    done
}

# Run analysis with retry logic
run_analysis_with_retry() {
    local retry_count=0
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        log "Running access log analysis (attempt $((retry_count + 1))/$MAX_RETRIES)"
        
        if bash "$ANALYZER_SCRIPT" analyze; then
            log "Access log analysis completed successfully"
            return 0
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $MAX_RETRIES ]; then
                error "Analysis failed, retrying in ${RETRY_DELAY} seconds..."
                sleep $RETRY_DELAY
            else
                error "Analysis failed after $MAX_RETRIES attempts"
                return 1
            fi
        fi
    done
}

# Handle different run modes
case "${1:-schedule}" in
    "schedule")
        wait_for_2am
        run_analysis_with_retry
        log "Waiting 24 hours until next scheduled analysis"
        sleep 86400  # 24 hours
        ;;
    "run-now")
        log "Running analysis immediately"
        run_analysis_with_retry
        ;;
    "test")
        log "Running test analysis"
        bash "$ANALYZER_SCRIPT" test
        ;;
    *)
        echo "Usage: $0 [mode]"
        echo "Modes:"
        echo "  schedule  - Run daily scheduler (default)"
        echo "  run-now   - Run analysis immediately"
        echo "  test      - Run test analysis"
        exit 1
        ;;
esac