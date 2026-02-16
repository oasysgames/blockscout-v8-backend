#!/bin/bash

# =============================================================================
# Error Log Scanner Script
# =============================================================================
# Scans error logs, uploads to S3, and sends Slack notifications
#
# Configuration Priority:
# 1. Environment variables (highest priority)
# 2. .env file (error-scanner/config/.env)
# 3. Script defaults (lowest priority)
# =============================================================================

# Note: set -e is NOT used here to prevent daemon from stopping on errors
# Errors are handled explicitly in daemon mode to ensure continuous monitoring

# =============================================================================
# Configuration Variables
# =============================================================================
# These can be overridden via environment variables or .env file

# -----------------------------------------------------------------------------
# Log Directories
# -----------------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/logs}"
NGINX_LOG_DIR="${NGINX_LOG_DIR:-/logs/nginx}"
BACKEND_LOG_DIR="${BACKEND_LOG_DIR:-/logs/backend}"

# -----------------------------------------------------------------------------
# S3 Configuration
# -----------------------------------------------------------------------------
S3_BUCKET="${S3_ERROR_LOGS_BUCKET:-oasys-blockscout-error-logs-bucket}"
S3_PREFIX="${S3_LOG_PREFIX:-blockscout/errors}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

# -----------------------------------------------------------------------------
# Scanner Configuration
# -----------------------------------------------------------------------------
SCAN_INTERVAL="${SCAN_INTERVAL:-300}"  # Default: 5 minutes
MAX_LOG_AGE="${MAX_LOG_AGE:-86400}"    # Default: 24 hours

# -----------------------------------------------------------------------------
# Slack Configuration
# -----------------------------------------------------------------------------
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_USERNAME="${SLACK_USERNAME:-Error Scanner}"
SLACK_ICON_EMOJI="${SLACK_ICON_EMOJI:-:warning:}"

# -----------------------------------------------------------------------------
# Notification Tracking Configuration
# -----------------------------------------------------------------------------
# This file stores transaction hashes and block numbers that have already been
# notified to prevent duplicate notifications for the same transaction/block.
# NOTE: Records are kept permanently (no automatic cleanup).
# Use cleanup_old_notifications() manually if needed.
NOTIFICATION_TRACK_FILE="${NOTIFICATION_TRACK_FILE:-/tmp/blockscout_notifications_track.json}"

# Use shared volume if available (for multi-container scenarios)
if [ -d "/tmp/notifications" ]; then
    NOTIFICATION_TRACK_FILE="/tmp/notifications/blockscout_notifications_track.json"
fi

# Retention period for notification tracking (hours)
# Used only for manual cleanup (automatic cleanup is disabled)
# NOTE: Blockscout indexing scans each transaction/block only once. If an error occurs
# and is not fixed, the same error will repeat continuously. This retention period
# prevents spam notifications for the same error. After this period, the same error
# can be notified again (useful for detecting long-term persistent issues).
NOTIFICATION_RETENTION_HOURS="${NOTIFICATION_RETENTION_HOURS:-720}"  # Default: 30 days (720 hours)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

# Helper function for date calculations (Alpine Linux compatible)
# Calculates date relative to now using epoch seconds
# Usage: date_relative <seconds_ago> <format>
# Example: date_relative 60 '+%Y-%m-%dT%H:%M:%S'  # 1 minute ago
date_relative() {
    local seconds_ago="$1"
    local format="${2:-'+%Y-%m-%d %H:%M:%S'}"
    local epoch=$(($(date +%s) - seconds_ago))
    
    # Try GNU date first (supports -d @epoch)
    if date -u -d "@${epoch}" "${format}" 2>/dev/null; then
        return 0
    fi
    
    # Try busybox date format (if available)
    if date -u -D '%s' -d "${epoch}" "${format}" 2>/dev/null; then
        return 0
    fi
    
    # Fallback: use current date (better than failing)
    date -u "${format}"
}

# Initialize notification tracking file
init_notification_track() {
    if [ ! -f "$NOTIFICATION_TRACK_FILE" ]; then
        echo '{"transactions":[],"blocks":[]}' > "$NOTIFICATION_TRACK_FILE"
    else
        # Remove duplicates from existing file
        local temp_file=$(mktemp)
        jq '.transactions = (.transactions | unique_by(.hash)) | .blocks = (.blocks | unique_by(.number))' \
           "$NOTIFICATION_TRACK_FILE" > "$temp_file" 2>/dev/null
        if [ $? -eq 0 ]; then
            mv "$temp_file" "$NOTIFICATION_TRACK_FILE"
        else
            rm -f "$temp_file"
        fi
    fi
}

# Check if notification was already sent for transaction/block
check_notification_sent() {
    local tx_hash="$1"
    local block_num="$2"
    
    init_notification_track
    
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - NOTIFICATION_RETENTION_HOURS * 3600))
    
    # Check transaction hash - only consider recent notifications (within retention period)
    if [ -n "$tx_hash" ]; then
        local last_sent_time=$(jq -r ".transactions[] | select(.hash == \"$tx_hash\") | .timestamp" "$NOTIFICATION_TRACK_FILE" 2>/dev/null | head -1)
        if [ -n "$last_sent_time" ] && [ "$last_sent_time" -gt "$cutoff_time" ]; then
            return 0  # Already sent within retention period
        fi
    fi
    
    # Check block number - only consider recent notifications (within retention period)
    if [ -n "$block_num" ]; then
        local last_sent_time=$(jq -r ".blocks[] | select(.number == \"$block_num\") | .timestamp" "$NOTIFICATION_TRACK_FILE" 2>/dev/null | head -1)
        if [ -n "$last_sent_time" ] && [ "$last_sent_time" -gt "$cutoff_time" ]; then
            return 0  # Already sent within retention period
        fi
    fi
    
    return 1  # Not sent yet, or sent outside retention period (can send again)
}

# Mark notification as sent (with file locking to prevent race conditions)
mark_notification_sent() {
    local tx_hash="$1"
    local block_num="$2"
    local error_type="${3:-unknown}"
    
    init_notification_track
    
    # Use file lock to prevent concurrent writes
    local lock_file="${NOTIFICATION_TRACK_FILE}.lock"
    local lock_timeout=30
    local lock_acquired=0
    
    # Try to acquire lock
    for i in $(seq 1 $lock_timeout); do
        if (set -C; echo $$ > "$lock_file") 2>/dev/null; then
            lock_acquired=1
            trap "rm -f '$lock_file'" EXIT
            break
        fi
        sleep 0.1
    done
    
    if [ $lock_acquired -eq 0 ]; then
        warn "Could not acquire lock for notification tracking, skipping..."
        return 1
    fi
    
    local timestamp=$(date +%s)
    local temp_file=$(mktemp)
    
    # Add transaction if provided (only if not already exists)
    if [ -n "$tx_hash" ]; then
        # Check if transaction already exists before adding (with duplicate removal)
        local exists=$(jq -e ".transactions[] | select(.hash == \"$tx_hash\")" "$NOTIFICATION_TRACK_FILE" 2>/dev/null)
        if [ -z "$exists" ]; then
            # Remove duplicates first, then add new entry, then remove duplicates again
            jq --arg hash "$tx_hash" --arg ts "$timestamp" --arg type "$error_type" \
               '.transactions = ((.transactions | unique_by(.hash)) + [{"hash": $hash, "timestamp": ($ts | tonumber), "error_type": $type}]) | .transactions = (.transactions | unique_by(.hash))' \
               "$NOTIFICATION_TRACK_FILE" > "$temp_file"
            if [ $? -eq 0 ]; then
                mv "$temp_file" "$NOTIFICATION_TRACK_FILE"
            else
                rm -f "$temp_file"
            fi
        fi
    fi
    
    # Add block if provided (only if not already exists)
    if [ -n "$block_num" ]; then
        # Check if block already exists before adding (with duplicate removal)
        local exists=$(jq -e ".blocks[] | select(.number == \"$block_num\")" "$NOTIFICATION_TRACK_FILE" 2>/dev/null)
        if [ -z "$exists" ]; then
            # Remove duplicates first, then add new entry, then remove duplicates again
            jq --arg num "$block_num" --arg ts "$timestamp" --arg type "$error_type" \
               '.blocks = ((.blocks | unique_by(.number)) + [{"number": $num, "timestamp": ($ts | tonumber), "error_type": $type}]) | .blocks = (.blocks | unique_by(.number))' \
               "$NOTIFICATION_TRACK_FILE" > "$temp_file"
            if [ $? -eq 0 ]; then
                mv "$temp_file" "$NOTIFICATION_TRACK_FILE"
            else
                rm -f "$temp_file"
            fi
        fi
    fi
    
    # Final cleanup: remove any duplicates that might have been added
    if [ -f "$NOTIFICATION_TRACK_FILE" ]; then
        jq '.transactions = (.transactions | unique_by(.hash)) | .blocks = (.blocks | unique_by(.number))' \
           "$NOTIFICATION_TRACK_FILE" > "$temp_file" 2>/dev/null
        if [ $? -eq 0 ]; then
            mv "$temp_file" "$NOTIFICATION_TRACK_FILE"
        else
            rm -f "$temp_file"
        fi
    fi
    
    # Release lock
    rm -f "$lock_file"
    trap - EXIT
}

# Cleanup old notification records (older than retention period)
# NOTE: This function is kept for manual cleanup if needed, but automatic cleanup is disabled
# to keep all notification history. Run manually with: cleanup_old_notifications
cleanup_old_notifications() {
    init_notification_track
    
    local cutoff_time=$(($(date +%s) - NOTIFICATION_RETENTION_HOURS * 3600))
    local temp_file=$(mktemp)
    
    # Remove old transactions
    jq --arg cutoff "$cutoff_time" \
       '.transactions = (.transactions | map(select(.timestamp > ($cutoff | tonumber))))' \
       "$NOTIFICATION_TRACK_FILE" > "$temp_file"
    
    # Remove old blocks
    jq --arg cutoff "$cutoff_time" \
       '.blocks = (.blocks | map(select(.timestamp > ($cutoff | tonumber))))' \
       "$temp_file" > "$NOTIFICATION_TRACK_FILE"
    
    rm -f "$temp_file"
}

# Send Slack notification
send_slack_alert() {
    local message="$1"
    local error_type="${2:-error}"
    local transaction_hash="${3:-}"
    local block_number="${4:-}"
    local s3_url="${5:-}"
    local skip_check="${6:-false}"  # Set to true to skip duplicate check
    
    if [ -z "$SLACK_WEBHOOK_URL" ]; then
        warn "Slack webhook URL not configured, skipping notification"
        return 0
    fi
    
    # Check if notification was already sent (unless skip_check is true)
    # Use file lock to prevent race conditions during check
    if [ "$skip_check" != "true" ]; then
        local lock_file="${NOTIFICATION_TRACK_FILE}.lock"
        local lock_acquired=0
        
        # Try to acquire lock for checking
        for i in $(seq 1 10); do
            if [ -f "$lock_file" ]; then
                local lock_pid=$(cat "$lock_file" 2>/dev/null)
                if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                    sleep 0.1
                    continue
                else
                    rm -f "$lock_file"
                fi
            fi
            
            if (set -C; echo $$ > "$lock_file") 2>/dev/null; then
                lock_acquired=1
                break
            fi
            sleep 0.1
        done
        
        if [ $lock_acquired -eq 1 ]; then
            if check_notification_sent "$transaction_hash" "$block_number"; then
                rm -f "$lock_file"
                log "Notification already sent for tx=$transaction_hash block=$block_number, skipping..."
                return 0
            fi
            rm -f "$lock_file"
        fi
    fi
    
    # Determine color based on error type
    local color="danger"
    case "$error_type" in
        "timeout"|"connection") color="danger" ;;
        "validation"|"import") color="warning" ;;
        "fetch") color="good" ;;
        *) color="danger" ;;
    esac
    
    # Build Slack message
    local slack_message="{
        \"username\": \"$SLACK_USERNAME\",
        \"icon_emoji\": \"$SLACK_ICON_EMOJI\",
        \"attachments\": [
            {
                \"color\": \"$color\",
                \"title\": \"🚨 Blockscout Error Alert\",
                \"text\": \"$message\",
                \"fields\": [
                    {
                        \"title\": \"Error Type\",
                        \"value\": \"$error_type\",
                        \"short\": true
                    },
                    {
                        \"title\": \"Timestamp\",
                        \"value\": \"$(date -u '+%Y-%m-%d %H:%M:%S UTC')\",
                        \"short\": true
                    }"
    
    # Add transaction hash if available
    if [ -n "$transaction_hash" ]; then
        slack_message="$slack_message,
                    {
                        \"title\": \"Transaction Hash\",
                        \"value\": \"\`$transaction_hash\`\",
                        \"short\": true
                    }"
    fi
    
    # Add block number if available
    if [ -n "$block_number" ]; then
        slack_message="$slack_message,
                    {
                        \"title\": \"Block Number\",
                        \"value\": \"$block_number\",
                        \"short\": true
                    }"
    fi
    
    # Add S3 URL if available
    if [ -n "$s3_url" ]; then
        slack_message="$slack_message,
                    {
                        \"title\": \"S3 Log File\",
                        \"value\": \"<$s3_url|View Details>\",
                        \"short\": false
                    }"
    fi
    
    slack_message="$slack_message
                ],
                \"footer\": \"Blockscout Error Scanner\",
                \"ts\": $(date +%s)
            }
        ]
    }"
    
    # Send to Slack (skip if webhook URL is not configured)
    if [ -z "$SLACK_WEBHOOK_URL" ]; then
        warn "SLACK_WEBHOOK_URL is not configured - skipping Slack notification"
        return 0
    fi
    
    local response=$(curl -s -X POST -H 'Content-type: application/json' \
        --data "$slack_message" \
        "$SLACK_WEBHOOK_URL" 2>&1)
    
    local curl_exit_code=$?
    if [ $curl_exit_code -eq 0 ] && echo "$response" | grep -q "ok"; then
        log "Slack notification sent successfully"
        # Mark as sent immediately after successful send (only if not already marked)
        if [ "$skip_check" != "true" ] && ([ -n "$transaction_hash" ] || [ -n "$block_number" ]); then
            # Double-check before marking to prevent race conditions
            if ! check_notification_sent "$transaction_hash" "$block_number"; then
                mark_notification_sent "$transaction_hash" "$block_number" "$error_type"
            fi
        fi
    else
        warn "Failed to send Slack notification (continuing anyway): $response"
        # Don't exit - allow script to continue even if Slack fails
    fi
}

# Check dependencies
check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        error "jq is not installed. Please install it first."
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        error "curl is not installed. Please install it first."
        exit 1
    fi
    
    log "Dependencies check passed"
}

# Check AWS credentials
check_aws_credentials() {
    # Skip check if AWS_SKIP_AWS_CHECK is set to true
    if [ "${AWS_SKIP_AWS_CHECK:-false}" = "true" ]; then
        log "Skipping AWS credentials check (AWS_SKIP_AWS_CHECK=true)"
        return 0
    fi
    
    log "Checking AWS credentials..."
    
    if ! aws sts get-caller-identity &> /dev/null; then
        warn "AWS credentials not configured or invalid - S3 upload will be skipped"
        warn "Set AWS_SKIP_AWS_CHECK=true to suppress this warning"
        # Don't exit - allow script to continue without S3 upload
        return 1
    fi
    
    log "AWS credentials check passed"
}

# Scan error logs
scan_error_logs() {
    local log_file="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local temp_file="/tmp/error_scan_${timestamp}.log"
    local individual_alerts_sent=0  # Track if individual alerts were sent
    
    # Check if another scan is already running
    local scan_lock_file="/tmp/error_scan.lock"
    if [ -f "$scan_lock_file" ]; then
        local lock_pid=$(cat "$scan_lock_file" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log "Another scan is already running (PID: $lock_pid), skipping..."
            return 0
        else
            # Lock file exists but process is dead, remove it
            rm -f "$scan_lock_file"
        fi
    fi
    
    # Create lock file
    echo $$ > "$scan_lock_file"
    trap "rm -f '$scan_lock_file'" EXIT
    
    log "Scanning error logs in: $log_file"
    
    # Extract error lines - for JSON format, only process lines with severity="error"
    # For non-JSON format, use grep pattern matching
    # First, try to filter JSON logs by severity="error" using jq
    if command -v jq >/dev/null 2>&1; then
        # Try to filter JSON logs first (more efficient)
        jq -c 'select(.severity == "error")' "$log_file" 2>/dev/null | while IFS= read -r line; do
            # JSON format - extract fields using jq
            severity=$(echo "$line" | jq -r '.severity // "unknown"')
            message=$(echo "$line" | jq -r '.message // ""')
            log_time=$(echo "$line" | jq -r '.time // ""')
            metadata=$(echo "$line" | jq -c '.metadata // {}')
            
            # Extract transaction hash from multiple possible locations
            tx_hash=$(echo "$line" | jq -r '.metadata.transaction_hash // .metadata.tx_hash // .transaction_hash // ""')
            if [ -z "$tx_hash" ]; then
                # Try to extract from message text
                tx_hash=$(echo "$message" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
            fi
            
            # Extract block number from multiple possible locations
            block_num=$(echo "$line" | jq -r '.metadata.block_number // .metadata.block_num // .block_number // ""')
            if [ -z "$block_num" ] || [ "$block_num" = "null" ]; then
                # Try to extract from message text - handle multiple formats
                # Format 1: "for blocks [1, 5877948, ...]"
                block_list=$(echo "$message" | grep -oE 'blocks\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | head -1)
                if [ -n "$block_list" ]; then
                    block_num="$block_list"
                else
                    # Format 2: "block_number: 1" or "block 123"
                    block_num=$(echo "$message" | grep -oE 'block[[:space:]]*[_:]?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
                fi
            fi
            
            # Extract all block numbers if message contains "for blocks [...]"
            block_numbers=""
            if echo "$message" | grep -q "for blocks \["; then
                block_numbers=$(echo "$message" | grep -oE 'blocks\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '|')
            fi
            
            # Extract error type
            error_type="unknown"
            if echo "$message" | grep -qi "timeout"; then
                error_type="timeout"
            elif echo "$message" | grep -qi "connection"; then
                # Check if this is an API request error (skip) or indexing error (alert)
                if echo "$message" | grep -qiE "(Request: GET /api|Request: POST /api|BlockScoutWeb\.Endpoint|Server:.*http)"; then
                    # This is an API request error - skip it
                    log "Skipping connection error from API request"
                    continue
                else
                    # This is likely an indexing error - process it
                    error_type="connection"
                fi
            elif echo "$message" | grep -qi "validation"; then
                error_type="validation"
            elif echo "$message" | grep -qi "import"; then
                error_type="import"
            elif echo "$message" | grep -qi "fetch"; then
                error_type="fetch"
            elif echo "$message" | grep -qi "failed to fetch.*blocks"; then
                error_type="block_fetch"
            elif echo "$message" | grep -qi "max fee per gas"; then
                error_type="gas_fee"
            elif echo "$message" | grep -qi "not found"; then
                error_type="not_found"
            fi
            
            # Only process connection and fetch errors - skip all others
            if [ "$error_type" != "connection" ] && [ "$error_type" != "fetch" ] && [ "$error_type" != "block_fetch" ]; then
                continue
            fi
            
            # Create structured log entry using jq to properly escape JSON
            jq -n \
                --arg timestamp "$log_time" \
                --arg severity "$severity" \
                --arg error_type "$error_type" \
                --arg tx_hash "$tx_hash" \
                --arg block_num "$block_num" \
                --arg block_numbers "$block_numbers" \
                --argjson metadata "$metadata" \
                --arg message "$message" \
                '{timestamp: $timestamp, severity: $severity, error_type: $error_type, transaction_hash: $tx_hash, block_number: $block_num, block_numbers: $block_numbers, metadata: $metadata, message: $message}' >> "$temp_file"
            
            # Send notification for specific transaction/block errors (avoid duplicates)
            if [ -n "$tx_hash" ] || [ -n "$block_num" ]; then
                # Check if notification was already sent before processing
                if check_notification_sent "$tx_hash" "$block_num"; then
                    log "Notification already sent for tx=$tx_hash block=$block_num, skipping..."
                    continue
                fi
                local short_message=$(echo "$message" | cut -c1-200)
                if [ ${#message} -gt 200 ]; then
                    short_message="${short_message}..."
                fi
                send_slack_alert "🔴 Error: $short_message" "$error_type" "$tx_hash" "$block_num" ""
                individual_alerts_sent=1
            fi
        done
    else
        # Fallback: if jq filtering fails, use grep for non-JSON logs
        grep -E "(error|ERROR|failed|FAILED|timeout|TIMEOUT|exception|EXCEPTION)" "$log_file" | while IFS= read -r line; do
            # Plain text format - extract basic info
            tx_hash=$(echo "$line" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
            
            # Extract block number - handle multiple formats
            block_num=""
            # Format 1: "for blocks [1, 5877948, ...]"
            block_list=$(echo "$line" | grep -oE 'blocks\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | head -1)
            if [ -n "$block_list" ]; then
                block_num="$block_list"
            else
                # Format 2: "block_number: 1" or "block 123"
                block_num=$(echo "$line" | grep -oE 'block[[:space:]]*[_:]?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
            fi
            
            # Extract all block numbers if present
            block_numbers=""
            if echo "$line" | grep -q "for blocks \["; then
                block_numbers=$(echo "$line" | grep -oE 'blocks\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '|')
            fi
            
            # Determine error type
            error_type="unknown"
            if echo "$line" | grep -qi "timeout"; then
                error_type="timeout"
            elif echo "$line" | grep -qi "connection"; then
                # Check if this is an API request error (skip) or indexing error (alert)
                if echo "$line" | grep -qiE "(Request: GET /api|Request: POST /api|BlockScoutWeb\.Endpoint|Server:.*http)"; then
                    # This is an API request error - skip it
                    log "Skipping connection error from API request"
                    continue
                else
                    # This is likely an indexing error - process it
                    error_type="connection"
                fi
            elif echo "$line" | grep -qi "validation"; then
                error_type="validation"
            elif echo "$line" | grep -qi "import"; then
                error_type="import"
            elif echo "$line" | grep -qi "fetch"; then
                error_type="fetch"
            elif echo "$line" | grep -qi "failed to fetch.*blocks"; then
                error_type="block_fetch"
            elif echo "$line" | grep -qi "max fee per gas"; then
                error_type="gas_fee"
            elif echo "$line" | grep -qi "not found"; then
                error_type="not_found"
            fi
            
            # Only process connection and fetch errors - skip all others
            if [ "$error_type" != "connection" ] && [ "$error_type" != "fetch" ] && [ "$error_type" != "block_fetch" ]; then
                continue
            fi
            
            # Create structured log entry using jq to properly escape JSON
            jq -n \
                --arg timestamp "$(date -Iseconds)" \
                --arg error_type "$error_type" \
                --arg tx_hash "$tx_hash" \
                --arg block_num "$block_num" \
                --arg block_numbers "$block_numbers" \
                --arg message "$line" \
                '{timestamp: $timestamp, error_type: $error_type, transaction_hash: $tx_hash, block_number: $block_num, block_numbers: $block_numbers, message: $message}' >> "$temp_file" 2>/dev/null || {
                # Fallback if jq fails
                echo "{\"timestamp\":\"$(date -Iseconds)\",\"error_type\":\"$error_type\",\"transaction_hash\":\"$tx_hash\",\"block_number\":\"$block_num\",\"block_numbers\":\"$block_numbers\",\"message\":\"$(echo "$line" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')\"}" >> "$temp_file"
            }
            
            # Send notification for specific transaction/block errors (avoid duplicates)
            if [ -n "$tx_hash" ] || [ -n "$block_num" ]; then
                # Check if notification was already sent before processing
                if check_notification_sent "$tx_hash" "$block_num"; then
                    log "Notification already sent for tx=$tx_hash block=$block_num, skipping..."
                    continue
                fi
                local short_message=$(echo "$line" | cut -c1-200)
                if [ ${#line} -gt 200 ]; then
                    short_message="${short_message}..."
                fi
                send_slack_alert "🔴 Error: $short_message" "$error_type" "$tx_hash" "$block_num" ""
                individual_alerts_sent=1
            fi
        done
    fi
    
    # Check if individual alerts were sent (need to check from outside the pipe)
    local has_individual_alerts=0
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        # Check if any errors have transaction hash or block number
        if jq -e '[.[] | select(.transaction_hash != "" or .block_number != "")] | length > 0' "$temp_file" >/dev/null 2>&1; then
            has_individual_alerts=1
        fi
    fi
    
    # Upload to S3 if errors found (only if AWS credentials are available)
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        local error_count=$(wc -l < "$temp_file")
        log "Found $error_count errors"
        
        # Try to upload to S3 (skip if AWS credentials are not available)
        local s3_key="${S3_PREFIX}/error_scan_${timestamp}.json"
        local s3_upload_success=0
        
        if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION" 2>/dev/null; then
            log "Successfully uploaded error log to S3: s3://${S3_BUCKET}/${s3_key}"
            s3_upload_success=1
        else
            warn "Failed to upload to S3 (AWS credentials may not be configured) - continuing without S3 upload"
        fi
        
        if [ "$s3_upload_success" -eq 1 ]; then
            log "Successfully uploaded error log to S3: s3://${S3_BUCKET}/${s3_key}"
            
            # Send Slack alert for critical errors
            local s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
            
            # Check for critical errors in the original log file
            local critical_errors=$(grep -E "(timeout|connection|critical)" "$log_file" | wc -l)
            local total_errors=$(wc -l < "$temp_file")
            
            log "Debug: Found $critical_errors critical errors out of $total_errors total errors"
            
            # Check if any errors have transaction hash or block number (individual alerts were sent)
            # temp_file contains one JSON object per line, so we need to convert to array first
            local has_individual_alerts=0
            if jq -s -e '[.[] | select((.transaction_hash != "" and .transaction_hash != null) or (.block_number != "" and .block_number != null))] | length > 0' "$temp_file" >/dev/null 2>&1; then
                has_individual_alerts=1
                log "Individual alerts were sent for errors with transaction/block context"
            fi
            
            # Send summary notifications only if no individual alerts were sent
            # This prevents duplicate notifications when individual errors already have transaction/block context
            if [ "$has_individual_alerts" -eq 0 ]; then
                if [ "$critical_errors" -gt 0 ]; then
                    send_slack_alert "🚨 Critical errors detected in Blockscout logs ($critical_errors critical, $total_errors total)" "critical" "" "" "$s3_url" "true"
                elif [ "$total_errors" -gt 0 ]; then
                    send_slack_alert "⚠️ Errors detected in Blockscout logs ($total_errors errors)" "warning" "" "" "$s3_url" "true"
                fi
            else
                log "Skipping summary notification - individual alerts already sent for errors with transaction/block context"
            fi
        fi
        
        # Clean up temp file
        rm -f "$temp_file"
    else
        log "No errors found in $log_file"
    fi
}

# Scan nginx error logs
scan_nginx_logs() {
    local log_file="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local temp_file="/tmp/nginx_error_scan_${timestamp}.log"
    
    log "Scanning nginx error logs in: $log_file"
    
    # Skip nginx logs - only process connection and fetch errors from main logs
    log "Skipping nginx logs - only connection and fetch errors are processed"
    return 0
    
    # Extract nginx error lines (disabled - only connection and fetch errors are processed)
    grep -E "(error|ERROR|warn|WARN|crit|CRIT|alert|ALERT|emerg|EMERG)" "$log_file" | \
    while IFS= read -r line; do
        # Extract IP address if present
        ip_addr=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        
        # Extract HTTP status code if present
        status_code=$(echo "$line" | grep -oE '[0-9]{3}' | head -1)
        
        # Extract error type
        error_type="nginx_error"
        if echo "$line" | grep -q "warn"; then
            error_type="nginx_warning"
        elif echo "$line" | grep -q "crit"; then
            error_type="nginx_critical"
        elif echo "$line" | grep -q "alert"; then
            error_type="nginx_alert"
        elif echo "$line" | grep -q "emerg"; then
            error_type="nginx_emergency"
        fi
        
        # Create structured log entry using jq to properly escape JSON
        jq -n \
            --arg timestamp "$(date -Iseconds)" \
            --arg error_type "$error_type" \
            --arg ip_addr "$ip_addr" \
            --arg status_code "$status_code" \
            --arg message "$line" \
            '{timestamp: $timestamp, error_type: $error_type, ip_address: $ip_addr, status_code: $status_code, message: $message}' >> "$temp_file" 2>/dev/null || {
            # Fallback if jq fails
            echo "{\"timestamp\":\"$(date -Iseconds)\",\"error_type\":\"$error_type\",\"ip_address\":\"$ip_addr\",\"status_code\":\"$status_code\",\"message\":\"$(echo "$line" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')\"}" >> "$temp_file"
        }
    done
    
    # Upload to S3 if errors found (only if AWS credentials are available)
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        local error_count=$(wc -l < "$temp_file")
        log "Found $error_count nginx errors"
        
        local s3_key="${S3_PREFIX}/nginx_error_scan_${timestamp}.json"
        local s3_upload_success=0
        local s3_url=""
        
        # Try to upload to S3 (skip if AWS credentials are not available)
        if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION" 2>/dev/null; then
            log "Successfully uploaded nginx error log to S3: s3://${S3_BUCKET}/${s3_key}"
            s3_upload_success=1
            s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
        else
            warn "Failed to upload nginx error log to S3 (AWS credentials may not be configured) - continuing without S3 upload"
        fi
        
        # Send Slack alert for nginx errors (only if S3 upload succeeded or if we want to send without S3)
        if [ "$s3_upload_success" -eq 1 ] || [ -n "$SLACK_WEBHOOK_URL" ]; then
            # Check for critical nginx errors
            local critical_errors=$(grep -E "(crit|alert|emerg)" "$log_file" | wc -l)
            local total_errors=$(wc -l < "$temp_file")
            
            log "Debug: Found $critical_errors critical nginx errors out of $total_errors total errors"
            
            # Send summary notifications (skip duplicate check for summaries)
            if [ "$critical_errors" -gt 0 ]; then
                send_slack_alert "🚨 Critical nginx errors detected ($critical_errors critical, $total_errors total)" "nginx_critical" "" "" "$s3_url" "true"
            elif [ "$total_errors" -gt 0 ]; then
                send_slack_alert "⚠️ Nginx errors detected ($total_errors errors)" "nginx_warning" "" "" "$s3_url" "true"
            fi
        fi
        
        # Clean up temp file
        rm -f "$temp_file"
    else
        log "No nginx errors found in $log_file"
    fi
}

# Scan backend error logs
scan_backend_logs() {
    local log_file="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local temp_file="/tmp/backend_error_scan_${timestamp}.log"
    local individual_alerts_sent=0  # Track if individual alerts were sent
    
    log "Scanning backend error logs in: $log_file"
    
    # Extract backend error lines (JSON format)
    grep -E "(error|ERROR|failed|FAILED|timeout|TIMEOUT|exception|EXCEPTION)" "$log_file" | \
    while IFS= read -r line; do
        # Try to parse JSON if it's JSON format
        if echo "$line" | jq . >/dev/null 2>&1; then
            # JSON format - extract fields
            level=$(echo "$line" | jq -r '.level // "unknown"')
            message=$(echo "$line" | jq -r '.message // "unknown"')
            timestamp=$(echo "$line" | jq -r '.timestamp // "unknown"')
            application=$(echo "$line" | jq -r '.application // "unknown"')
            
            # Extract transaction hash if present
            tx_hash=$(echo "$line" | jq -r '.transaction_hash // .tx_hash // ""')
            
            # Extract block number if present
            block_num=$(echo "$line" | jq -r '.block_number // .block_num // ""')
            
            # Skip known non-critical errors that don't need alerts
            if echo "$message" | grep -qi "Request Entity Too Large.*Cannot shrink batch further"; then
                continue  # Skip this error - known issue, no alert needed
            fi
            # Skip timeout errors with :etimedout reason (network timeout, not critical)
            if echo "$message" | grep -qi "failed to fetch.*Mint.TransportError.*reason: :etimedout"; then
                continue  # Skip this error - network timeout, no alert needed
            fi
            
            # Determine error type
            error_type="backend_error"
            if echo "$message" | grep -q "timeout"; then
                error_type="backend_timeout"
            elif echo "$message" | grep -q "connection"; then
                error_type="backend_connection"
            elif echo "$message" | grep -q "validation"; then
                error_type="backend_validation"
            elif echo "$message" | grep -q "import"; then
                error_type="backend_import"
            elif echo "$message" | grep -q "fetch"; then
                error_type="backend_fetch"
            elif echo "$message" | grep -qi "max fee per gas"; then
                error_type="backend_gas_fee"
            elif echo "$message" | grep -qi "not found"; then
                error_type="backend_not_found"
            fi
            
            # Process backend_connection, backend_fetch, and backend_timeout errors
            # Timeout errors are critical for indexing issues
            if [ "$error_type" != "backend_connection" ] && [ "$error_type" != "backend_fetch" ] && [ "$error_type" != "backend_block_fetch" ] && [ "$error_type" != "backend_timeout" ]; then
                continue
            fi
            
            # Create structured log entry using jq to properly escape JSON
            jq -n \
                --arg timestamp "$timestamp" \
                --arg error_type "$error_type" \
                --arg level "$level" \
                --arg application "$application" \
                --arg tx_hash "$tx_hash" \
                --arg block_num "$block_num" \
                --arg message "$message" \
                '{timestamp: $timestamp, error_type: $error_type, level: $level, application: $application, transaction_hash: $tx_hash, block_number: $block_num, message: $message}' >> "$temp_file" 2>/dev/null || {
                # Fallback if jq fails
                echo "{\"timestamp\":\"$timestamp\",\"error_type\":\"$error_type\",\"level\":\"$level\",\"application\":\"$application\",\"transaction_hash\":\"$tx_hash\",\"block_number\":\"$block_num\",\"message\":\"$(echo "$message" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')\"}" >> "$temp_file"
            }
            
            # Send notification for specific transaction/block errors (avoid duplicates)
            if [ -n "$tx_hash" ] || [ -n "$block_num" ]; then
                # Check if notification was already sent before processing
                if check_notification_sent "$tx_hash" "$block_num"; then
                    log "Notification already sent for tx=$tx_hash block=$block_num, skipping..."
                    continue
                fi
                local short_message=$(echo "$message" | cut -c1-200)
                if [ ${#message} -gt 200 ]; then
                    short_message="${short_message}..."
                fi
                send_slack_alert "🔴 Backend Error: $short_message" "$error_type" "$tx_hash" "$block_num" ""
                individual_alerts_sent=1
            fi
        else
            # Plain text format - extract basic info
            tx_hash=$(echo "$line" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
            
            # Extract block number - handle multiple formats
            block_num=""
            # Format 1: "block_number [10987037, 10987038, ...]" (from error.log)
            block_list=$(echo "$line" | grep -oE 'block_number\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | head -1)
            if [ -n "$block_list" ]; then
                block_num="$block_list"
            else
                # Format 2: "for blocks [1, 5877948, ...]"
                block_list=$(echo "$line" | grep -oE 'blocks\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | head -1)
                if [ -n "$block_list" ]; then
                    block_num="$block_list"
                else
                    # Format 3: "first_block_number=10986925 last_block_number=10986916"
                    block_num=$(echo "$line" | grep -oE 'first_block_number=[0-9]+' | grep -oE '[0-9]+' | head -1)
                    if [ -z "$block_num" ]; then
                        # Format 4: "block_number: 1" or "block 123"
                        block_num=$(echo "$line" | grep -oE 'block[[:space:]]*[_:]?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
                    fi
                fi
            fi
            
            # Extract all block numbers if present
            block_numbers=""
            if echo "$line" | grep -q "block_number\s*\["; then
                block_numbers=$(echo "$line" | grep -oE 'block_number\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '|')
            elif echo "$line" | grep -q "for blocks \["; then
                block_numbers=$(echo "$line" | grep -oE 'blocks\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '|')
            fi
            
            # Skip known non-critical errors that don't need alerts
            if echo "$line" | grep -qi "Request Entity Too Large.*Cannot shrink batch further"; then
                continue  # Skip this error - known issue, no alert needed
            fi
            # Skip timeout errors with :etimedout reason (network timeout, not critical)
            if echo "$line" | grep -qi "failed to fetch.*Mint.TransportError.*reason: :etimedout"; then
                continue  # Skip this error - network timeout, no alert needed
            fi
            
            # Determine error type
            error_type="backend_error"
            if echo "$line" | grep -qi "timeout"; then
                error_type="backend_timeout"
            elif echo "$line" | grep -qi "connection"; then
                error_type="backend_connection"
            elif echo "$line" | grep -qi "validation"; then
                error_type="backend_validation"
            elif echo "$line" | grep -qi "import"; then
                error_type="backend_import"
            elif echo "$line" | grep -qi "fetch"; then
                error_type="backend_fetch"
            elif echo "$line" | grep -qi "failed to fetch.*blocks"; then
                error_type="backend_block_fetch"
            elif echo "$line" | grep -qi "max fee per gas"; then
                error_type="backend_gas_fee"
            elif echo "$line" | grep -qi "not found"; then
                error_type="backend_not_found"
            fi
            
            # Process backend_connection, backend_fetch, and backend_timeout errors
            # Timeout errors are critical for indexing issues
            if [ "$error_type" != "backend_connection" ] && [ "$error_type" != "backend_fetch" ] && [ "$error_type" != "backend_block_fetch" ] && [ "$error_type" != "backend_timeout" ]; then
                continue
            fi
            
            # Create structured log entry using jq to properly escape JSON
            jq -n \
                --arg timestamp "$(date -Iseconds)" \
                --arg error_type "$error_type" \
                --arg tx_hash "$tx_hash" \
                --arg block_num "$block_num" \
                --arg block_numbers "$block_numbers" \
                --arg message "$line" \
                '{timestamp: $timestamp, error_type: $error_type, transaction_hash: $tx_hash, block_number: $block_num, block_numbers: $block_numbers, message: $message}' >> "$temp_file" 2>/dev/null || {
                # Fallback if jq fails
                echo "{\"timestamp\":\"$(date -Iseconds)\",\"error_type\":\"$error_type\",\"transaction_hash\":\"$tx_hash\",\"block_number\":\"$block_num\",\"block_numbers\":\"$block_numbers\",\"message\":\"$(echo "$line" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')\"}" >> "$temp_file"
            }
            
            # Send notification for specific transaction/block errors (avoid duplicates)
            if [ -n "$tx_hash" ] || [ -n "$block_num" ]; then
                # Check if notification was already sent before processing
                if check_notification_sent "$tx_hash" "$block_num"; then
                    log "Notification already sent for tx=$tx_hash block=$block_num, skipping..."
                    continue
                fi
                local short_message=$(echo "$line" | cut -c1-200)
                if [ ${#line} -gt 200 ]; then
                    short_message="${short_message}..."
                fi
                send_slack_alert "🔴 Backend Error: $short_message" "$error_type" "$tx_hash" "$block_num" ""
                individual_alerts_sent=1
            fi
        fi
    done
    
    # Check if individual alerts were sent (need to check from outside the pipe)
    local has_individual_alerts=0
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        # Check if any errors have transaction hash or block number
        if jq -e '[.[] | select(.transaction_hash != "" or .block_number != "")] | length > 0' "$temp_file" >/dev/null 2>&1; then
            has_individual_alerts=1
        fi
    fi
    
    # Upload to S3 if errors found (only if AWS credentials are available)
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        local error_count=$(wc -l < "$temp_file")
        log "Found $error_count backend errors"
        
        local s3_key="${S3_PREFIX}/backend_error_scan_${timestamp}.json"
        local s3_upload_success=0
        local s3_url=""
        
        # Try to upload to S3 (skip if AWS credentials are not available)
        if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION" 2>/dev/null; then
            log "Successfully uploaded backend error log to S3: s3://${S3_BUCKET}/${s3_key}"
            s3_upload_success=1
            s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
        else
            warn "Failed to upload backend error log to S3 (AWS credentials may not be configured) - continuing without S3 upload"
        fi
        
        # Send Slack alert for backend errors (only if S3 upload succeeded or if we want to send without S3)
        # NOTE: Summary notifications are disabled to prevent spam
        # Individual error notifications with transaction/block context are sent instead
        if [ "$s3_upload_success" -eq 1 ] || [ -n "$SLACK_WEBHOOK_URL" ]; then
            # Check for critical backend errors (for logging only)
            local critical_errors=$(grep -E "(timeout|connection|critical)" "$log_file" | wc -l)
            local total_errors=$(wc -l < "$temp_file")
            
            log "Debug: Found $critical_errors critical backend errors out of $total_errors total errors"
            
            # Check if any errors have transaction hash or block number (individual alerts were sent)
            # temp_file contains one JSON object per line, so we need to convert to array first
            local has_individual_alerts=0
            if jq -s -e '[.[] | select((.transaction_hash != "" and .transaction_hash != null) or (.block_number != "" and .block_number != null))] | length > 0' "$temp_file" >/dev/null 2>&1; then
                has_individual_alerts=1
                log "Individual alerts were sent for errors with transaction/block context"
            fi
            
            # Summary notifications are disabled to prevent spam
            # Only individual error notifications with transaction/block context are sent
            # if [ "$has_individual_alerts" -eq 0 ]; then
            #     if [ "$critical_errors" -gt 0 ]; then
            #         send_slack_alert "🚨 Critical backend errors detected ($critical_errors critical, $total_errors total)" "backend_critical" "" "" "$s3_url" "true"
            #     elif [ "$total_errors" -gt 0 ]; then
            #         send_slack_alert "⚠️ Backend errors detected ($total_errors errors)" "backend_warning" "" "" "$s3_url" "true"
            #     fi
            # else
            #     log "Skipping summary notification - individual alerts already sent for errors with transaction/block context"
            # fi
            log "Summary notifications disabled - only individual error notifications are sent"
        fi
        
        # Clean up temp file
        rm -f "$temp_file"
    else
        log "No backend errors found in $log_file"
    fi
}

# Monitor Docker logs
monitor_docker_logs() {
    local container_name="${1:-backend}"
    
    log "Starting Docker log monitoring for container: $container_name"
    
    # Create named pipe for log streaming
    local pipe="/tmp/docker_logs_${container_name}.pipe"
    mkfifo "$pipe" 2>/dev/null || true
    
    # Start log streaming in background
    # Use helper function for Alpine Linux compatibility
    docker logs -f --since="$(date_relative 60 '+%Y-%m-%dT%H:%M:%S')" "$container_name" > "$pipe" 2>&1 &
    local log_pid=$!
    
    # Monitor the pipe
    while true; do
        if read -t 60 line < "$pipe"; then
            # Check if line contains error
            if echo "$line" | grep -qE "(error|ERROR|failed|FAILED|timeout|TIMEOUT|exception|EXCEPTION)"; then
                # Extract transaction context
                tx_hash=$(echo "$line" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
                
                # Extract block number - handle multiple formats
                block_num=""
                # Format 1: "for blocks [1, 5877948, ...]"
                block_list=$(echo "$line" | grep -oE 'blocks\s*\[[0-9,\s]+\]' | grep -oE '\[[0-9,\s]+\]' | tr -d '[]' | tr ',' '\n' | tr -d ' ' | head -1)
                if [ -n "$block_list" ]; then
                    block_num="$block_list"
                else
                    # Format 2: "block_number: 1" or "block 123"
                    block_num=$(echo "$line" | grep -oE 'block[[:space:]]*[_:]?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
                fi
                
                if [ -n "$tx_hash" ] || [ -n "$block_num" ]; then
                    local timestamp=$(date '+%Y%m%d_%H%M%S')
                    local temp_file="/tmp/realtime_error_${timestamp}.log"
                    
                    # Create structured log entry using jq to properly escape JSON
                    jq -n \
                        --arg timestamp "$(date -Iseconds)" \
                        --arg tx_hash "$tx_hash" \
                        --arg block_num "$block_num" \
                        --arg message "$line" \
                        '{timestamp: $timestamp, transaction_hash: $tx_hash, block_number: $block_num, message: $message}' > "$temp_file" 2>/dev/null || {
                        # Fallback if jq fails
                        echo "{\"timestamp\":\"$(date -Iseconds)\",\"transaction_hash\":\"$tx_hash\",\"block_number\":\"$block_num\",\"message\":\"$(echo "$line" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')\"}" > "$temp_file"
                    }
                    
                    local s3_key="${S3_PREFIX}/realtime_error_${timestamp}.json"
                    local s3_upload_success=0
                    local s3_url=""
                    
                    # Try to upload to S3 (skip if AWS credentials are not available)
                    if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION" 2>/dev/null; then
                        log "Uploaded realtime error to S3: $s3_key"
                        s3_upload_success=1
                        s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
                    else
                        warn "Failed to upload realtime error to S3 (AWS credentials may not be configured) - continuing without S3 upload"
                    fi
                    
                    # Send immediate Slack alert for real-time errors (even if S3 upload failed)
                    local error_type="realtime"
                    
                    # Determine error type from message
                    if echo "$line" | grep -q "timeout"; then
                        error_type="timeout"
                    elif echo "$line" | grep -q "connection"; then
                        error_type="connection"
                    elif echo "$line" | grep -q "validation"; then
                        error_type="validation"
                    fi
                    
                    send_slack_alert "⚡ Real-time error detected: $line" "$error_type" "$tx_hash" "$block_num" "$s3_url"
                    
                    rm -f "$temp_file"
                fi
            fi
        else
            # Timeout reached, check if process is still running
            if ! kill -0 "$log_pid" 2>/dev/null; then
                error "Docker log process died, restarting..."
                # Use helper function for Alpine Linux compatibility
                docker logs -f --since="$(date_relative 60 '+%Y-%m-%dT%H:%M:%S')" "$container_name" > "$pipe" 2>&1 &
                log_pid=$!
            fi
        fi
    done
}

# Clean old logs
cleanup_old_logs() {
    log "Cleaning up old logs..."
    
    find "$LOG_DIR" -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
    
    # Clean up old S3 logs (older than 30 days)
    # Use helper function for Alpine Linux compatibility (30 days = 2592000 seconds)
    local cutoff_date=$(date_relative 2592000 '+%Y-%m-%d')
    
    # Try to cleanup old S3 logs (skip if AWS credentials are not available)
    if aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --region "$AWS_REGION" 2>/dev/null | \
        while read -r line; do
            local file_date=$(echo "$line" | awk '{print $1}')
            local file_key=$(echo "$line" | awk '{print $4}')
            
            if [ "$file_date" \< "$cutoff_date" ]; then
                log "Deleting old log file: $file_key"
                aws s3 rm "s3://${S3_BUCKET}/${file_key}" --region "$AWS_REGION" 2>/dev/null || warn "Failed to delete old log file: $file_key"
            fi
        done; then
        log "S3 cleanup completed"
    else
        warn "Failed to cleanup old S3 logs (AWS credentials may not be configured) - skipping cleanup"
    fi
}

# Generate error report
generate_error_report() {
    local report_file="/tmp/error_report_$(date '+%Y%m%d_%H%M%S').json"
    
    log "Generating error report..."
    
    # Get error logs from S3 for the last 24 hours (skip if AWS credentials are not available)
    # Use helper function for Alpine Linux compatibility (24 hours = 86400 seconds)
    local start_date=$(date_relative 86400 '+%Y-%m-%d')
    
    echo "{\"report_date\":\"$(date -Iseconds)\",\"errors\":[" > "$report_file"
    
    # Try to fetch from S3, but continue even if it fails
    if aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --region "$AWS_REGION" 2>/dev/null | \
        awk -v start="$start_date" '$1 >= start {print $4}' | \
        while read -r file_key; do
            if [ -n "$file_key" ]; then
                aws s3 cp "s3://${S3_BUCKET}/${file_key}" - --region "$AWS_REGION" 2>/dev/null | \
                jq -c '.' 2>/dev/null || true
            fi
        done | jq -s '.' >> "$report_file" 2>/dev/null; then
        log "Successfully fetched error logs from S3"
    else
        warn "Failed to fetch error logs from S3 (AWS credentials may not be configured) - generating report with empty errors array"
        echo "[]" >> "$report_file"
    fi
    
    echo "]}" >> "$report_file"
    
    # Upload report to S3 (skip if AWS credentials are not available)
    local report_key="reports/error_report_$(date '+%Y%m%d_%H%M%S').json"
    if aws s3 cp "$report_file" "s3://${S3_BUCKET}/${report_key}" --region "$AWS_REGION" 2>/dev/null; then
        log "Error report uploaded to S3: s3://${S3_BUCKET}/${report_key}"
    else
        warn "Failed to upload error report to S3 (AWS credentials may not be configured) - report saved locally: $report_file"
    fi
    
    rm -f "$report_file"
}

# Main function
main() {
    # Initialize notification tracking
    init_notification_track
    
    case "${1:-scan}" in
        "scan")
            check_dependencies
            # Check AWS credentials but don't exit if they're not configured
            check_aws_credentials || warn "AWS credentials check failed - S3 upload will be skipped"
            
            # If a file path is provided as second argument, scan that file directly
            if [ -n "$2" ] && [ -f "$2" ]; then
                log "Scanning specified file: $2"
                scan_error_logs "$2"
            else
                # Scan all log directories
                if [ -d "$LOG_DIR" ]; then
                    find "$LOG_DIR" -name "*.log" -type f -mmin -60 | while read -r log_file; do
                        scan_error_logs "$log_file"
                    done
                else
                    warn "Log directory $LOG_DIR not found"
                fi
                
                # Scan nginx logs separately
                if [ -d "$NGINX_LOG_DIR" ]; then
                    find "$NGINX_LOG_DIR" -name "*.log" -type f -mmin -60 | while read -r log_file; do
                        scan_nginx_logs "$log_file"
                    done
                else
                    warn "Nginx log directory $NGINX_LOG_DIR not found"
                fi
                
                # Scan backend logs separately
                if [ -d "$BACKEND_LOG_DIR" ]; then
                    find "$BACKEND_LOG_DIR" -name "*.log" -type f -mmin -60 | while read -r log_file; do
                        scan_backend_logs "$log_file"
                    done
                else
                    warn "Backend log directory $BACKEND_LOG_DIR not found"
                fi
            fi
            ;;
        "monitor")
            check_dependencies
            # Check AWS credentials but don't exit if they're not configured
            check_aws_credentials || warn "AWS credentials check failed - S3 upload will be skipped"
            monitor_docker_logs "${2:-backend}"
            ;;
        "monitor-nginx")
            check_dependencies
            # Check AWS credentials but don't exit if they're not configured
            check_aws_credentials || warn "AWS credentials check failed - S3 upload will be skipped"
            monitor_docker_logs "proxy"
            ;;
        "monitor-backend")
            check_dependencies
            # Check AWS credentials but don't exit if they're not configured
            check_aws_credentials || warn "AWS credentials check failed - S3 upload will be skipped"
            monitor_docker_logs "backend"
            ;;
        "cleanup")
            # Check AWS credentials but don't exit if they're not configured
            check_aws_credentials || warn "AWS credentials check failed - S3 cleanup will be skipped"
            cleanup_old_logs
            ;;
        "report")
            check_dependencies
            # Check AWS credentials but don't exit if they're not configured
            check_aws_credentials || warn "AWS credentials check failed - S3 report generation will be skipped"
            generate_error_report
            ;;
        "daemon")
            check_dependencies
            # Check AWS credentials but don't exit if they're not configured
            check_aws_credentials || warn "AWS credentials check failed - S3 upload will be skipped"
            
            log "Starting error log scanner daemon..."
            
            while true; do
                if ! main scan; then
                    error "Scan failed, retrying in ${SCAN_INTERVAL}s..."
                fi
                sleep "$SCAN_INTERVAL"
            done
            ;;
        *)
            echo "Usage: $0 {scan|monitor|cleanup|report|daemon}"
            echo ""
            echo "Commands:"
            echo "  scan [file] - Scan error logs once (optionally specify a file path)"
            echo "  monitor  - Monitor Docker logs in real-time"
            echo "  monitor-nginx - Monitor nginx logs in real-time"
            echo "  monitor-backend - Monitor backend logs in real-time"
            echo "  cleanup  - Clean up old logs"
            echo "  report   - Generate error report"
            echo "  daemon   - Run as daemon (scan every $SCAN_INTERVAL seconds)"
            echo ""
            echo "Environment variables:"
            echo "  S3_ERROR_LOGS_BUCKET - S3 bucket for error logs"
            echo "  S3_LOG_PREFIX        - S3 prefix for logs (default: blockscout/errors)"
            echo "  AWS_REGION           - AWS region (default: ap-northeast-1)"
            echo "  SCAN_INTERVAL        - Scan interval in seconds (default: 300)"
            echo "  MAX_LOG_AGE          - Maximum log age in seconds (default: 86400)"
            echo "  LOG_DIR              - Log directory (default: /logs)"
            echo "  NGINX_LOG_DIR         - Nginx log directory (default: /logs/nginx)"
            echo "  BACKEND_LOG_DIR       - Backend log directory (default: /logs/backend)"
            echo ""
            echo "Slack Configuration:"
            echo "  SLACK_WEBHOOK_URL    - Slack webhook URL for notifications (required)"
            echo "  SLACK_USERNAME       - Slack username (default: Error Scanner)"
            echo "  SLACK_ICON_EMOJI     - Slack icon emoji (default: :warning:)"
            echo ""
            echo "Configuration files:"
            echo "  error-scanner/config/.env - Main configuration file"
            echo ""
            echo "Note: Configuration priority: Environment variables > .env file > Script defaults"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
