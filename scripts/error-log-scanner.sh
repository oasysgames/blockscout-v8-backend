#!/bin/bash

# Error Log Scanner Script
# Scans error logs and uploads to S3

set -e

# Configuration
LOG_DIR="./logs"
NGINX_LOG_DIR="./logs/nginx"
BACKEND_LOG_DIR="./logs/backend"
S3_BUCKET="${S3_ERROR_LOGS_BUCKET:-oasys-blockscout-error-logs-bucket}"
S3_PREFIX="${S3_LOG_PREFIX:-blockscout/errors}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SCAN_INTERVAL="${SCAN_INTERVAL:-300}" # 5 minutes
MAX_LOG_AGE="${MAX_LOG_AGE:-86400}" # 24 hours

# Slack Configuration
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#blockscout-alerts}"
SLACK_USERNAME="${SLACK_USERNAME:-Error Scanner}"
SLACK_ICON_EMOJI="${SLACK_ICON_EMOJI:-:warning:}"

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

# Send Slack notification
send_slack_alert() {
    local message="$1"
    local error_type="${2:-error}"
    local transaction_hash="${3:-}"
    local block_number="${4:-}"
    local s3_url="${5:-}"
    
    if [ -z "$SLACK_WEBHOOK_URL" ]; then
        warn "Slack webhook URL not configured, skipping notification"
        return 0
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
        \"channel\": \"$SLACK_CHANNEL\",
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
                        \"value\": \"$(date '+%Y-%m-%d %H:%M:%S UTC')\",
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
    
    # Send to Slack
    local response=$(curl -s -X POST -H 'Content-type: application/json' \
        --data "$slack_message" \
        "$SLACK_WEBHOOK_URL")
    
    if [ $? -eq 0 ]; then
        log "Slack notification sent successfully"
    else
        error "Failed to send Slack notification: $response"
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
    log "Checking AWS credentials..."
    
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured or invalid"
        exit 1
    fi
    
    log "AWS credentials check passed"
}

# Scan error logs
scan_error_logs() {
    local log_file="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local temp_file="/tmp/error_scan_${timestamp}.log"
    
    log "Scanning error logs in: $log_file"
    
    # Extract error lines with transaction context
    grep -E "(error|ERROR|failed|FAILED|timeout|TIMEOUT|exception|EXCEPTION)" "$log_file" | \
    while IFS= read -r line; do
        # Extract transaction hash if present
        tx_hash=$(echo "$line" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
        
        # Extract block number if present
        block_num=$(echo "$line" | grep -oE 'block[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
        
        # Extract error type
        error_type="unknown"
        if echo "$line" | grep -q "timeout"; then
            error_type="timeout"
        elif echo "$line" | grep -q "connection"; then
            error_type="connection"
        elif echo "$line" | grep -q "validation"; then
            error_type="validation"
        elif echo "$line" | grep -q "import"; then
            error_type="import"
        elif echo "$line" | grep -q "fetch"; then
            error_type="fetch"
        fi
        
        # Create structured log entry
        echo "{\"timestamp\":\"$(date -Iseconds)\",\"error_type\":\"$error_type\",\"transaction_hash\":\"$tx_hash\",\"block_number\":\"$block_num\",\"message\":\"$line\"}" >> "$temp_file"
    done
    
    # Upload to S3 if errors found
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        local error_count=$(wc -l < "$temp_file")
        log "Found $error_count errors, uploading to S3..."
        
        local s3_key="${S3_PREFIX}/error_scan_${timestamp}.json"
        
        if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION"; then
            log "Successfully uploaded error log to S3: s3://${S3_BUCKET}/${s3_key}"
            
            # Send Slack alert for critical errors
            local s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
            
            # Check for critical errors in the original log file
            local critical_errors=$(grep -E "(timeout|connection|critical)" "$log_file" | wc -l)
            local total_errors=$(wc -l < "$temp_file")
            
            log "Debug: Found $critical_errors critical errors out of $total_errors total errors"
            
            if [ "$critical_errors" -gt 0 ]; then
                send_slack_alert "🚨 Critical errors detected in Blockscout logs ($critical_errors critical, $total_errors total)" "critical" "" "" "$s3_url"
            elif [ "$total_errors" -gt 0 ]; then
                send_slack_alert "⚠️ Errors detected in Blockscout logs ($total_errors errors)" "warning" "" "" "$s3_url"
            fi
        else
            error "Failed to upload error log to S3"
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
    
    # Extract nginx error lines
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
        
        # Create structured log entry
        echo "{\"timestamp\":\"$(date -Iseconds)\",\"error_type\":\"$error_type\",\"ip_address\":\"$ip_addr\",\"status_code\":\"$status_code\",\"message\":\"$line\"}" >> "$temp_file"
    done
    
    # Upload to S3 if errors found
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        local error_count=$(wc -l < "$temp_file")
        log "Found $error_count nginx errors, uploading to S3..."
        
        local s3_key="${S3_PREFIX}/nginx_error_scan_${timestamp}.json"
        
        if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION"; then
            log "Successfully uploaded nginx error log to S3: s3://${S3_BUCKET}/${s3_key}"
            
            # Send Slack alert for nginx errors
            local s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
            
            # Check for critical nginx errors
            local critical_errors=$(grep -E "(crit|alert|emerg)" "$log_file" | wc -l)
            local total_errors=$(wc -l < "$temp_file")
            
            log "Debug: Found $critical_errors critical nginx errors out of $total_errors total errors"
            
            if [ "$critical_errors" -gt 0 ]; then
                send_slack_alert "🚨 Critical nginx errors detected ($critical_errors critical, $total_errors total)" "nginx_critical" "" "" "$s3_url"
            elif [ "$total_errors" -gt 0 ]; then
                send_slack_alert "⚠️ Nginx errors detected ($total_errors errors)" "nginx_warning" "" "" "$s3_url"
            fi
        else
            error "Failed to upload nginx error log to S3"
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
            fi
            
            # Create structured log entry
            echo "{\"timestamp\":\"$timestamp\",\"error_type\":\"$error_type\",\"level\":\"$level\",\"application\":\"$application\",\"transaction_hash\":\"$tx_hash\",\"block_number\":\"$block_num\",\"message\":\"$message\"}" >> "$temp_file"
        else
            # Plain text format - extract basic info
            tx_hash=$(echo "$line" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
            block_num=$(echo "$line" | grep -oE 'block[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
            
            # Determine error type
            error_type="backend_error"
            if echo "$line" | grep -q "timeout"; then
                error_type="backend_timeout"
            elif echo "$line" | grep -q "connection"; then
                error_type="backend_connection"
            elif echo "$line" | grep -q "validation"; then
                error_type="backend_validation"
            elif echo "$line" | grep -q "import"; then
                error_type="backend_import"
            elif echo "$line" | grep -q "fetch"; then
                error_type="backend_fetch"
            fi
            
            # Create structured log entry
            echo "{\"timestamp\":\"$(date -Iseconds)\",\"error_type\":\"$error_type\",\"transaction_hash\":\"$tx_hash\",\"block_number\":\"$block_num\",\"message\":\"$line\"}" >> "$temp_file"
        fi
    done
    
    # Upload to S3 if errors found
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        local error_count=$(wc -l < "$temp_file")
        log "Found $error_count backend errors, uploading to S3..."
        
        local s3_key="${S3_PREFIX}/backend_error_scan_${timestamp}.json"
        
        if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION"; then
            log "Successfully uploaded backend error log to S3: s3://${S3_BUCKET}/${s3_key}"
            
            # Send Slack alert for backend errors
            local s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
            
            # Check for critical backend errors
            local critical_errors=$(grep -E "(timeout|connection|critical)" "$log_file" | wc -l)
            local total_errors=$(wc -l < "$temp_file")
            
            log "Debug: Found $critical_errors critical backend errors out of $total_errors total errors"
            
            if [ "$critical_errors" -gt 0 ]; then
                send_slack_alert "🚨 Critical backend errors detected ($critical_errors critical, $total_errors total)" "backend_critical" "" "" "$s3_url"
            elif [ "$total_errors" -gt 0 ]; then
                send_slack_alert "⚠️ Backend errors detected ($total_errors errors)" "backend_warning" "" "" "$s3_url"
            fi
        else
            error "Failed to upload backend error log to S3"
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
    docker logs -f --since="$(date -d '1 minute ago' '+%Y-%m-%dT%H:%M:%S')" "$container_name" > "$pipe" 2>&1 &
    local log_pid=$!
    
    # Monitor the pipe
    while true; do
        if read -t 60 line < "$pipe"; then
            # Check if line contains error
            if echo "$line" | grep -qE "(error|ERROR|failed|FAILED|timeout|TIMEOUT|exception|EXCEPTION)"; then
                # Extract transaction context
                tx_hash=$(echo "$line" | grep -oE '0x[a-fA-F0-9]{64}' | head -1)
                block_num=$(echo "$line" | grep -oE 'block[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
                
                if [ -n "$tx_hash" ] || [ -n "$block_num" ]; then
                    local timestamp=$(date '+%Y%m%d_%H%M%S')
                    local temp_file="/tmp/realtime_error_${timestamp}.log"
                    
                    echo "{\"timestamp\":\"$(date -Iseconds)\",\"transaction_hash\":\"$tx_hash\",\"block_number\":\"$block_num\",\"message\":\"$line\"}" > "$temp_file"
                    
                    local s3_key="${S3_PREFIX}/realtime_error_${timestamp}.json"
                    
                    if aws s3 cp "$temp_file" "s3://${S3_BUCKET}/${s3_key}" --region "$AWS_REGION"; then
                        log "Uploaded realtime error to S3: $s3_key"
                        
                        # Send immediate Slack alert for real-time errors
                        local s3_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET}/${s3_key}"
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
                    fi
                    
                    rm -f "$temp_file"
                fi
            fi
        else
            # Timeout reached, check if process is still running
            if ! kill -0 "$log_pid" 2>/dev/null; then
                error "Docker log process died, restarting..."
                docker logs -f --since="$(date -d '1 minute ago' '+%Y-%m-%dT%H:%M:%S')" "$container_name" > "$pipe" 2>&1 &
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
    local cutoff_date=$(date -d '30 days ago' '+%Y-%m-%d')
    
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --region "$AWS_REGION" | \
    while read -r line; do
        local file_date=$(echo "$line" | awk '{print $1}')
        local file_key=$(echo "$line" | awk '{print $4}')
        
        if [ "$file_date" \< "$cutoff_date" ]; then
            log "Deleting old log file: $file_key"
            aws s3 rm "s3://${S3_BUCKET}/${file_key}" --region "$AWS_REGION"
        fi
    done
}

# Generate error report
generate_error_report() {
    local report_file="/tmp/error_report_$(date '+%Y%m%d_%H%M%S').json"
    
    log "Generating error report..."
    
    # Get error logs from S3 for the last 24 hours
    local start_date=$(date -d '24 hours ago' '+%Y-%m-%d')
    
    echo "{\"report_date\":\"$(date -Iseconds)\",\"errors\":[" > "$report_file"
    
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --region "$AWS_REGION" | \
    awk -v start="$start_date" '$1 >= start {print $4}' | \
    while read -r file_key; do
        if [ -n "$file_key" ]; then
            aws s3 cp "s3://${S3_BUCKET}/${file_key}" - --region "$AWS_REGION" 2>/dev/null | \
            jq -c '.' 2>/dev/null || true
        fi
    done | jq -s '.' >> "$report_file"
    
    echo "]}" >> "$report_file"
    
    # Upload report to S3
    local report_key="reports/error_report_$(date '+%Y%m%d_%H%M%S').json"
    if aws s3 cp "$report_file" "s3://${S3_BUCKET}/${report_key}" --region "$AWS_REGION"; then
        log "Error report uploaded to S3: s3://${S3_BUCKET}/${report_key}"
    fi
    
    rm -f "$report_file"
}

# Main function
main() {
    case "${1:-scan}" in
        "scan")
            check_dependencies
            check_aws_credentials
            
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
            ;;
        "monitor")
            check_dependencies
            check_aws_credentials
            monitor_docker_logs "${2:-backend}"
            ;;
        "monitor-nginx")
            check_dependencies
            check_aws_credentials
            monitor_docker_logs "proxy"
            ;;
        "monitor-backend")
            check_dependencies
            check_aws_credentials
            monitor_docker_logs "backend"
            ;;
        "cleanup")
            check_aws_credentials
            cleanup_old_logs
            ;;
        "report")
            check_dependencies
            check_aws_credentials
            generate_error_report
            ;;
        "daemon")
            check_dependencies
            check_aws_credentials
            
            log "Starting error log scanner daemon..."
            
            while true; do
                main scan
                sleep "$SCAN_INTERVAL"
            done
            ;;
        *)
            echo "Usage: $0 {scan|monitor|cleanup|report|daemon}"
            echo ""
            echo "Commands:"
            echo "  scan     - Scan error logs once"
            echo "  monitor  - Monitor Docker logs in real-time"
            echo "  monitor-nginx - Monitor nginx logs in real-time"
            echo "  monitor-backend - Monitor backend logs in real-time"
            echo "  cleanup  - Clean up old logs"
            echo "  report   - Generate error report"
            echo "  daemon   - Run as daemon (scan every $SCAN_INTERVAL seconds)"
            echo ""
            echo "Environment variables:"
            echo "  S3_ERROR_LOGS_BUCKET - S3 bucket for error logs (default: your-blockscout-error-logs-bucket)"
            echo "  S3_LOG_PREFIX        - S3 prefix for logs (default: blockscout/errors)"
            echo "  AWS_REGION           - AWS region (default: us-east-1)"
            echo "  SCAN_INTERVAL        - Scan interval in seconds (default: 300)"
            echo "  MAX_LOG_AGE          - Maximum log age in seconds (default: 86400)"
            echo ""
            echo "Slack Configuration:"
            echo "  SLACK_WEBHOOK_URL    - Slack webhook URL for notifications"
            echo "  SLACK_CHANNEL        - Slack channel (default: #blockscout-alerts)"
            echo "  SLACK_USERNAME       - Slack username (default: Error Scanner)"
            echo "  SLACK_ICON_EMOJI     - Slack icon emoji (default: :warning:)"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
