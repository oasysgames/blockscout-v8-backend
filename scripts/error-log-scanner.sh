#!/bin/bash

# Error Log Scanner for Blockscout
# Monitors Docker containers for transaction-related errors and uploads to S3

set -e

# Configuration
S3_BUCKET="${S3_ERROR_LOGS_BUCKET:-oasys-blockscout-error-logs-bucket}"
S3_PREFIX="${S3_LOG_PREFIX:-blockscout/errors}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
SCAN_INTERVAL="${SCAN_INTERVAL:-600}"
MAX_LOG_AGE="${MAX_LOG_AGE:-86400}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#alert-oasys}"
SLACK_USERNAME="${SLACK_USERNAME:-Error Scanner}"
SLACK_ICON_EMOJI="${SLACK_ICON_EMOJI:-:warning:}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

# Check AWS credentials
check_aws_credentials() {
    if [ "${AWS_SKIP_AWS_CHECK}" = "true" ]; then
        log "AWS check skipped"
        return 0
    fi
    
    if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
        error "AWS credentials not configured or invalid"
        return 1
    fi
    
    log "AWS credentials verified"
    return 0
}

# Send Slack notification
send_slack_alert() {
    local title="$1"
    local error_type="$2"
    local transaction_hash="$3"
    local block_number="$4"
    local s3_url="$5"
    
    if [ -z "$SLACK_WEBHOOK_URL" ]; then
        warn "SLACK_WEBHOOK_URL not configured, skipping Slack notification"
        return 0
    fi
    
    local message="*${title}*
*Type:* ${error_type}
*Time:* $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    
    if [ -n "$transaction_hash" ]; then
        message="${message}
*Transaction:* \`${transaction_hash}\`"
    fi
    
    if [ -n "$block_number" ]; then
        message="${message}
*Block:* ${block_number}"
    fi
    
    if [ -n "$s3_url" ]; then
        message="${message}
*Log file:* ${s3_url}"
    fi
    
    local payload=$(cat <<EOF
{
    "channel": "${SLACK_CHANNEL}",
    "username": "${SLACK_USERNAME}",
    "icon_emoji": "${SLACK_ICON_EMOJI}",
    "text": "${message}"
}
EOF
)
    
    if curl -X POST -H 'Content-type: application/json' \
        --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1; then
        log "Slack notification sent successfully"
    else
        error "Failed to send Slack notification"
    fi
}

# Scan transaction errors from log content
scan_transaction_errors() {
    local log_content="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
        local temp_file="/tmp/transaction_errors_${timestamp}.log"
    local seen_tx_file="/tmp/seen_transactions_${timestamp}.txt"
    
    # Initialize seen transactions file
    touch "$seen_tx_file"
    
    log "Scanning transaction errors from log content with deduplication"
    
    # Check if we have recent track file for deduplication
    local track_file="/tmp/transaction_tracker.json"
    if [ ! -f "$track_file" ]; then
        echo "{}" > "$track_file"
    fi
    
    # Extract only transaction-related error lines
    echo "$log_content" | grep -E "(transaction.*error|transaction.*failed|transaction.*timeout|transaction.*exception|tx.*error|tx.*failed|block.*error|block.*failed|invalid.*transaction|transaction.*not.*found|transaction.*execution.*failed)" | \
    while IFS= read -r line; do
        # Extract transaction hash if present
        tx_hash=$(echo "$line" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
        
        # Extract block number if present  
        block_num=$(echo "$line" | grep -oE 'block[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
        
        # If no explicit block number, try alternative patterns
        if [ -z "$block_num" ]; then
            block_num=$(echo "$line" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | head -1)
        fi
        
        # Extract error type
        error_type="transaction_error"
        if echo "$line" | grep -q "timeout"; then
            error_type="transaction_timeout"
        elif echo "$line" | grep -q "invalid"; then
            error_type="invalid_transaction"
        elif echo "$line" | grep -q "failed"; then
            error_type="transaction_execution_failed"
        elif echo "$line" | grep -q "not found"; then
            error_type="transaction_not_found"
        fi
        
        # Only process if we found transaction hash or block number (transaction-related)
        if [ -n "$tx_hash" ] || [ -n "$block_num" ]; then
            # Create unique identifier for this transaction error
            local unique_id=""
            if [ -n "$tx_hash" ]; then
                unique_id="${error_type}_${tx_hash}"
            elif [ -n "$block_num" ]; then
                unique_id="${error_type}_block_${block_num}"
            fi
            
            # Check if we've already seen this transaction error recently
            if [ -n "$unique_id" ] && ! grep -q "^${unique_id}$" "$seen_tx_file"; then
                # Record this transaction as seen
                echo "$unique_id" >> "$seen_tx_file"
                
                # Add to JSON output only if not recently processed
                local current_time=$(date +%s)
                local recent_window=$((SCAN_INTERVAL * 2))  # 2x scan interval window
                local was_processed=$(cat "$track_file" | jq -r ".\"${unique_id}\" // empty" 2>/dev/null || echo "")
                
                if [ -z "$was_processed" ] || [ $((current_time - was_processed)) -gt $recent_window ]; then
                    echo "{\"timestamp\":\"${timestamp}\",\"error_type\":\"${error_type}\",\"transaction_hash\":\"${tx_hash}\",\"block_number\":\"${block_num}\",\"message\":\"${line}\",\"unique_id\":\"${unique_id}\"}" >> "$temp_file"
                    
                    # Update tracking file with current timestamp
                    cat "$track_file" | jq ". + {\"${unique_id}\": ${current_time}}" > "$track_file.tmp" 2>/dev/null && mv "$track_file.tmp" "$track_file" || echo "$unique_id:$current_time" >> "$track_file"
                else
                    log "Skipping duplicate transaction error: ${unique_id} (processed $(((current_time - was_processed)))s ago)"
                fi
            fi
        fi
    done
    
    # Upload to S3 if transaction errors found
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        local error_count=$(wc -l < "$temp_file")
        log "Found ${error_count} transaction-related errors, uploading to S3..."
        
        local s3_key="${S3_PREFIX}/transaction_errors_${timestamp}.json"
        
        if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION" --content-type application/json; then
            log "Successfully uploaded transaction error log to S3: s3://${S3_BUCKET}/${s3_key}"
            
            log "File is publicly accessible via bucket policy"
            
            # Send Slack alert for transaction errors with public URL
            local s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
            send_slack_alert "🚨 Transaction errors detected _(${error_count} errors)_" "transaction" "" "" "$s3_url"
        else
            error "Failed to upload transaction error log to S3"
        fi
        
        # Clean up temp files and old tracking data (keep recent tracking)
        rm -f "$temp_file" "$seen_tx_file"
        
        # Clean up old entries from tracking file (older than 24 hours)
        local cleanup_threshold=$(($(date +%s) - 86400))
        if [ -f "$track_file" ]; then
            cat "$track_file" | jq "with_entries(select(.value > ${cleanup_threshold}))" > "$track_file.tmp" 2>/dev/null && mv "$track_file.tmp" "$track_file" || echo "{}" > "$track_file"
        fi
    else
        log "No transaction-related errors found"
    fi
}

# Monitor Docker containers
monitor_docker_containers() {
    local containers=("backend")
    local found_errors=false
    
    log "Monitoring Docker containers: ${containers[*]}"
    
    for container in "${containers[@]}"; do
        # Check if container exists and is running
        if ! docker ps --format "table {{.Names}}" | grep -q "^${container}$"; then
            warn "Container '$container' is not running or doesn't exist"
            continue
        fi
        
        log "Checking logs for container: $container"
        
        # Get logs from last scan interval (with some buffer)
        local since_time=$(($(date +%s) - SCAN_INTERVAL - 60))
        local logs=$(docker logs --since="${since_time}s" "${container}" 2>&1 || echo "")
        
        if [ -n "$logs" ]; then
            # Look for error-level logs (ERROR, FATAL, etc.)
            local error_logs=$(echo "$logs" | grep -i "error\|fatal\|exception\|failed\|timeout" || echo "")
            
            if [ -n "$error_logs" ]; then
                log "Found error logs in container: $container"
                scan_transaction_errors "$error_logs"
                found_errors=true
            else
                log "No notable errors found in container: $container"
            fi
        else
            log "No logs found for container: $container"
        fi
    done
    
    if [ "$found_errors" = false ]; then
        log "No transaction errors detected across all monitored containers"
    fi
}

# Create S3 bucket if it doesn't exist
create_s3_bucket_if_not_exists() {
    if aws s3 ls "s3://${S3_BUCKET}" --region "$AWS_REGION" >/dev/null 2>&1; then
        log "S3 bucket '${S3_BUCKET}' already exists"
        return 0
    fi
    
    log "Creating S3 bucket: ${S3_BUCKET}"
    if aws s3 mb "s3://${S3_BUCKET}" --region "$AWS_REGION"; then
        log "S3 bucket created successfully"
        
        # Set bucket policy for public read access
        local bucket_policy=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${S3_BUCKET}/blockscout/errors/*"
        }
    ]
}
EOF
)
        
        if aws s3api put-bucket-policy --bucket "${S3_BUCKET}" --policy "$bucket_policy"; then
            log "Bucket policy set for public read access"
        else
            warn "Failed to set bucket policy for public access"
        fi
        
        return 0
    else
        error "Failed to create S3 bucket"
        return 1
    fi
}

# Main daemon function
main() {
    local mode="${1:-scan}"
    
    log "Starting Error Log Scanner (mode: $mode)"
    log "Configuration:"
    log "  S3 Bucket: ${S3_BUCKET}"
    log "  S3 Prefix: ${S3_PREFIX}"
    log "  AWS Region: ${AWS_REGION}"
    log "  Scan Interval: ${SCAN_INTERVAL}s"
    log "  Max Log Age: ${MAX_LOG_AGE}s"
    
    if [ "$mode" = "daemon" ]; then
        log "Starting daemon mode..."
        
        # Check AWS credentials
        if ! check_aws_credentials; then
            error "AWS credentials check failed"
            exit 1
        fi
        
        # Create S3 bucket if needed
        create_s3_bucket_if_not_exists
        
        while true; do
            log "Starting scan cycle..."
            monitor_docker_containers
            log "Scan cycle completed. Sleeping for ${SCAN_INTERVAL} seconds..."
            sleep "$SCAN_INTERVAL"
        done
        
    elif [ "$mode" = "scan" ]; then
        log "Running single scan..."
        
        if ! check_aws_credentials; then
            error "AWS credentials check failed"
            exit 1
        fi
        
        monitor_docker_containers
        
    elif [ "$mode" = "test" ]; then
        log "Running test mode..."
        
        # Simulate finding some errors
        local test_errors="ERROR: Transaction 0x123abc failed
ERROR: Block 12345 has transaction timeout
WARNING: Invalid transaction detected"
        
        scan_transaction_errors "$test_errors"
        
    elif [ "$mode" = "init-s3" ]; then
        log "Initializing S3 bucket..."
        
        if ! check_aws_credentials; then
            error "AWS credentials check failed"
            exit 1
        fi
        
        create_s3_bucket_if_not_exists
        
    else
        echo "Usage: $0 [mode]"
        echo "Modes:"
        echo "  daemon    - Run continuously with ${SCAN_INTERVAL}s intervals"
        echo "  scan      - Run single scan"
        echo "  test      - Test with simulated errors"
        echo "  init-s3   - Initialize S3 bucket"
        exit 1
    fi
}

# Run main function with all arguments
main "$@"
