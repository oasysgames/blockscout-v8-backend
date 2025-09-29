# Analytics Service

## Overview
Independent analytics service for Blockscout access log analysis, separate from main backend.

## Structure
```
analytics/
├── docker-compose.yml           # Docker service configuration
├── scripts/
│   ├── access-log-analyzer.sh   # Main analysis script
│   └── run-daily-analysis.sh   # Daily scheduler
├── env.example                  # Environment variables template
├── README.md                   # Documentation
└── SERVICE_SUMMARY_JP.md       # Japanese documentation
```

## Features
- **Daily Access Log Analysis**: Automatically analyzes S3 access logs every day at 2AM
- **API v2/addresses Monitoring**: Focuses on `/api/v2/addresses/{address}` endpoint usage
- **Top IP Statistics**: Generates top 10 IPs by request count
- **Access Pattern Tracking**: Maps unique addresses accessed per IP per day
- **S3 Reports**: Uploads analysis results to S3 with public access
- **Slack Integration**: Sends daily reports with statistics and file links

## Deployment

### 1. Setup Environment Variables
```bash
# Copy template
cd analytics/
cp env.example .env

# Update with real values
nano .env
```

### 2. Run Analytics Service
```bash
# From root directory
docker compose -f analytics/docker-compose.yml up -d

# Or use helper script
../run-analytics.sh start
```

### 3. Manual Testing
```bash
# Test with simulated data
docker compose -f analytics/docker-compose.yml run --rm access-log-analyzer scripts/access-log-analyzer.sh test

# Run analysis for specific date
docker compose -f analytics/docker-compose.yml run --rm access-log-analyzer scripts/access-log-analyzer.sh analyze 2023-12-15
```

## Configuration

### Required Environment Variables
- `S3_ACCESS_LOG_BUCKET`: Bucket containing access logs
- `S3_ERROR_LOGS_BUCKET`: Bucket for storing analysis results  
- `SLACK_WEBHOOK_URL`: Slack webhook for notifications
- `AWS_REGION`: AWS region (default: ap-northeast-1)

### Optional Environment Variables
- `S3_ACCESS_LOG_PREFIX`: AWS ELB log prefix path
- `S3_ANALYSIS_PREFIX`: Analysis prefix path
- `AWS_SKIP_AWS_CHECK`: Skip AWS credential validation
- `SLACK_CHANNEL`: Slack channel for notifications

## Independence from Backend
This analytics service operates independently from the main Blockscout backend:
- Uses separate Docker Compose file
- Has its own directory structure  
- Can be deployed separately
- Does not interfere with backend operations
- Clean git history with no secrets