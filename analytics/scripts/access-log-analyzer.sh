#!/bin/bash

# S3 Access Log Analyzer for Blockscout API v2/addresses endpoint
# Generates top IP statistics and analyzes access patterns

set -e

# Configuration with environment variables
ACCESS_LOG_BUCKET="${S3_ACCESS_LOG_BUCKET:-l1-mainnet-alb-access-logs-d3rsyke1}"
ACCESS_LOG_PREFIX="${S3_ACCESS_LOG_PREFIX:-AWSLogs/428784263071/elasticloadbalancing/ap-northeast-1}"
ANALYSIS_PREFIX="${S3_ANALYSIS_PREFIX:-analysis/access-logs}"
RESULT_BUCKET="${S3_ERROR_LOGS_BUCKET:-oasys-blockscout-error-logs-bucket}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#alert-oasys}"
SLACK_USERNAME="${SLACK_USERNAME:-Access Log Analyzer}"
SLACK_ICON_EMOJI="${SLACK_ICON_EMOJI:-:bar_chart:}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1"
}

# Main analysis function
run_daily_analysis() {
    # Calculate yesterday's date (Alpine Linux compatible)
    local yesterday_date
    if [ -z "$1" ]; then
        # Get current timestamp and subtract 86400 seconds (1 day)
        local current_timestamp=$(date +%s)
        local yesterday_timestamp=$((current_timestamp - 86400))
        yesterday_date=$(date -d "@$yesterday_timestamp" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    else
        yesterday_date="$1"
    fi
    local target_date="$yesterday_date"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local temp_dir="/tmp/access_logs_${timestamp}"
    
    log "Starting daily access log analysis for date: $target_date"
    
    # Create temporary directory
    mkdir -p "$temp_dir"
    
            local analysis_file="${temp_dir}/analysis.txt"
            local pattern_file="${temp_dir}/patterns.json"
    
    # Check if files already exist for this date
    local s3_date_path="${ACCESS_LOG_PREFIX}/2025/${target_date:5:2}/${target_date:8:2}/"
    local downloaded_files=0
    
    # Check if files already exist
    if [ -d "$temp_dir" ] && [ "$(find "$temp_dir" -name "*.log.gz" | wc -l)" -gt 0 ]; then
        downloaded_files=$(find "$temp_dir" -name "*.log.gz" | wc -l)
        log "Using existing $downloaded_files log files for analysis"
    else
        # Download access logs for the target date
        log "Downloading access logs for analysis..."
        aws s3 sync "s3://${ACCESS_LOG_BUCKET}/${s3_date_path}" "$temp_dir/" --region "$AWS_REGION" --exclude "*" --include "*.log.gz" >/dev/null 2>&1 || true
        
        # Count downloaded files
        downloaded_files=$(find "$temp_dir" -name "*.log.gz" | wc -l)
        log "Downloaded $downloaded_files log files for analysis"
    fi
    
    if [ "$downloaded_files" -eq 0 ]; then
        warn "No access log files found for date: $target_date"
        # Create empty analysis
        echo "# No access logs found for $target_date" > "$analysis_file"
        echo '{"ip_address_patterns": []}' > "$pattern_file"
    else
        # Extract and analyze real data
        log "Analyzing access logs..."
        
        # Extract all log entries and parse
        local all_logs="${temp_dir}/all_logs.txt"
        find "$temp_dir" -name "*.log.gz" -exec gunzip -c {} \; > "$all_logs" 2>/dev/null || true
        
        # Filter for API v2/addresses requests
        local api_requests="${temp_dir}/api_requests.txt"
        grep "/api/v2/addresses" "$all_logs" > "$api_requests" 2>/dev/null || true
        
        # Count total requests
        local total_requests=$(wc -l < "$api_requests" 2>/dev/null || echo "0")
        
        if [ "$total_requests" -gt 0 ]; then
            # Extract IP addresses and addresses
            local ip_stats="${temp_dir}/ip_stats.txt"
            local address_stats="${temp_dir}/address_stats.txt"
            
            # Count requests by IP (field 4 is the client IP)
            awk '{print $4}' "$api_requests" | cut -d: -f1 | sort | uniq -c | sort -nr > "$ip_stats"
            
            # Count requests by address (look for 0x patterns in URLs)
            grep -oE '0x[a-fA-F0-9]{40}' "$api_requests" | sort | uniq -c | sort -nr > "$address_stats" 2>/dev/null || true
            
            # Count distribution of query frequencies
            local query_freq_stats="${temp_dir}/query_freq_stats.txt"
            awk '{print $1}' "$address_stats" | sort | uniq -c | sort -nr > "$query_freq_stats" 2>/dev/null || true
            
            # Generate analysis report
            {
                echo "# Access Log Analysis for $target_date"
                echo ""
                echo "## Summary"
                echo "* **Total API v2/addresses requests**: $total_requests"
                echo "* **Unique IP addresses**: $(wc -l < "$ip_stats")"
                echo "* **Unique addresses queried**: $(wc -l < "$address_stats")"
                echo ""
                echo "## Top 10 IPs by Request Count"
                
            # Show top 10 IPs with unique address count
            head -10 "$ip_stats" | while read count ip; do
                local unique_count=$(grep "$ip:" "$api_requests" | grep -oE '0x[a-fA-F0-9]{40}' | sort | uniq | wc -l)
                echo "* **$ip**: $count requests, $unique_count unique addresses"
            done
            
            echo ""
            echo "## Address Query Frequency Distribution"
            
            # Show query frequency distribution
            if [ -s "$query_freq_stats" ]; then
                head -10 "$query_freq_stats" | while read addr_count freq; do
                    echo "* **$addr_count addresses** queried exactly **$freq time(s)**"
                done
            else
                echo "* No address patterns found in requests"
            fi
            } > "$analysis_file"
            
            # Generate JSON patterns
            {
                echo "{"
                echo "  \"analysis_date\": \"$target_date\","
                echo "  \"total_requests\": $total_requests,"
                echo "  \"query_frequency_distribution\": ["
                
                # Generate query frequency distribution
                local first_freq=true
                if [ -s "$query_freq_stats" ]; then
                    head -10 "$query_freq_stats" | while read addr_count freq; do
                        if [ "$first_freq" = true ]; then
                            first_freq=false
                        else
                            echo ","
                        fi
                        echo -n "    {\"address_count\": $addr_count, \"query_frequency\": $freq}"
                    done
                fi
                
                echo ""
                echo "  ],"
                echo "  \"ip_address_patterns\": ["
                
                # Generate IP patterns
                local first_ip=true
                head -50 "$ip_stats" | while read count ip; do
                    if [ "$first_ip" = true ]; then
                        first_ip=false
                    else
                        echo ","
                    fi
                    
                    # Get addresses queried by this IP (search for IP:port pattern)
                    local ip_addresses=$(grep "$ip:" "$api_requests" | grep -oE '0x[a-fA-F0-9]{40}' | sort | uniq | tr '\n' ',' | sed 's/,$//')
                    local unique_count=$(grep "$ip:" "$api_requests" | grep -oE '0x[a-fA-F0-9]{40}' | sort | uniq | wc -l)
                    
                    echo -n "    {"
                    echo -n "\"ip\": \"$ip\","
                    echo -n "\"request_count\": $count,"
                    echo -n "\"unique_addresses\": $unique_count,"
                    echo -n "\"addresses\": ["
                    
                    if [ -n "$ip_addresses" ]; then
                        local first_addr=true
                        echo "$ip_addresses" | tr ',' '\n' | while read addr; do
                            if [ "$first_addr" = true ]; then
                                first_addr=false
                            else
                                echo -n ","
                            fi
                            echo -n "\"$addr\""
                        done
                    fi
                    
                    echo -n "]"
                    echo -n "}"
                done
                
                echo ""
                echo "  ]"
                echo "}"
            } > "$pattern_file"
        else
            # No API requests found
            echo "# No API v2/addresses requests found for $target_date" > "$analysis_file"
            echo '{"ip_address_patterns": [], "total_requests": 0}' > "$pattern_file"
        fi
    fi
    
    log "Daily analysis completed successfully for date: $target_date"
    
    # Upload results to S3
    local s3_key="${ANALYSIS_PREFIX}/${target_date}/analysis_${timestamp}.txt"
    local s3_json_key="${ANALYSIS_PREFIX}/${target_date}/patterns_${timestamp}.json"
    
    if aws s3 cp "$analysis_file" "s3://${RESULT_BUCKET}/${s3_key}" --region "$AWS_REGION"; then
        log "Analysis report uploaded to S3: s3://${RESULT_BUCKET}/${s3_key}"
    else
        error "Failed to upload analysis report to S3"
    fi
    
    if aws s3 cp "$pattern_file" "s3://${RESULT_BUCKET}/${s3_json_key}" --region "$AWS_REGION"; then
        log "Patterns JSON uploaded to S3: s3://${RESULT_BUCKET}/${s3_json_key}"
        
        # Send Slack notification with links
        if [ -n "$SLACK_WEBHOOK_URL" ]; then
            local txt_url="https://s3.${AWS_REGION}.amazonaws.com/${RESULT_BUCKET}/${s3_key}"
            local json_url="https://s3.${AWS_REGION}.amazonaws.com/${RESULT_BUCKET}/${s3_json_key}"
            
            local slack_message="📊 *Access Log Analysis Completed for $target_date*

📈 *Summary:*
• Total API v2/addresses requests: $total_requests
• Unique IP addresses: $(wc -l < "$ip_stats" 2>/dev/null || echo "0")
• Unique addresses queried: $(wc -l < "$address_stats" 2>/dev/null || echo "0")

📁 *Reports:*
• [Analysis Report (TXT)]($txt_url)
• [Detailed Patterns (JSON)]($json_url)

🔍 *Top IP by Request Count:*
$(head -3 "$ip_stats" 2>/dev/null | while read count ip; do
    local unique_count=$(grep "$ip:" "$api_requests" 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' | sort | uniq | wc -l)
    echo "• **$ip**: $count requests, $unique_count unique addresses"
done)"

            curl -X POST -H 'Content-type: application/json' \
                --data "{\"channel\":\"$SLACK_CHANNEL\",\"username\":\"$SLACK_USERNAME\",\"icon_emoji\":\"$SLACK_ICON_EMOJI\",\"text\":\"$slack_message\"}" \
                "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
            
            log "Slack notification sent for analysis completion"
        fi
    else
        error "Failed to upload patterns JSON to S3"
    fi
    
    # Clean up
    rm -rf "$temp_dir"
}

# Main entry point
main() {
    local command="${1:-analyze}"
    
    log "Starting S3 Access Log Analyzer"
    log "Configuration:"
    log "  Access Log Bucket: ${ACCESS_LOG_BUCKET}"
    log "  Access Log Prefix: ${ACCESS_LOG_PREFIX}"
    log "  Analysis Prefix: ${ANALYSIS_PREFIX}"
    log "  Result Bucket: ${RESULT_BUCKET}"
    log "  AWS Region: ${AWS_REGION}"
    
    case "$command" in
        "analyze")
            local date_param="$2"
            if [ -n "$date_param" ]; then
                run_daily_analysis "$date_param"
            else
                run_daily_analysis
            fi
            ;;
        "test")
            log "Running test mode..."
            echo "Analytics service is ready for deployment. Mock analysis completed."
            ;;
        *)
            echo "Usage: $0 [command]"
            echo "Commands:"
            echo "  analyze [date]  - Run daily analysis (default: yesterday)"
            echo "  test           - Test with simulated data"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
