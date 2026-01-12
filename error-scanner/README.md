# Error Scanner

A service that monitors Blockscout error logs, detects critical errors, and sends notifications to Slack.

## Directory Structure

```
error-scanner/
├── config/
│   └── .env              # Configuration file (Slack webhook URL, AWS settings, etc.)
├── scripts/
│   ├── error-log-scanner.sh  # Main script
│   └── cleanup-old-logs.sh   # Log cleanup script
├── README.md             # This file
├── MIGRATION.md          # Migration guide
└── LOGROTATE.md          # Log rotation guide
```

## Setup

### 1. Edit Configuration File

```bash
cd error-scanner/
vi config/.env
```

Edit the following settings:
- `SLACK_WEBHOOK_URL`: Slack webhook URL
- `S3_ERROR_LOGS_BUCKET`: S3 bucket name (optional)
- `AWS_REGION`: AWS region
- `SCAN_INTERVAL`: Scan interval in seconds
- `NOTIFICATION_RETENTION_HOURS`: Notification retention period in hours

### 2. Start with Docker Compose

```bash
cd docker-compose/
docker compose -f external-frontend.yml up -d error-scanner
```

## Features

- **Error Log Monitoring**: Periodically scans Backend and Nginx logs
- **Duplicate Notification Prevention**: Same transaction/block errors are notified only once within the retention period (default: 1 month)
- **S3 Upload**: Uploads error logs to S3 (optional)
- **Slack Notifications**: Sends critical errors to Slack

## Monitored Errors

The following errors are detected and notified:
- `backend_timeout`: Timeout errors
- `backend_connection`: Connection errors
- `backend_fetch`: Data fetch errors
- `backend_block_fetch`: Block fetch errors

The following errors are **not** notified (known issues):
- `Request Entity Too Large returned from single request batch. Cannot shrink batch further`
- `failed to fetch: %Mint.TransportError{reason: :etimedout}`

## Configuration Details

For detailed configuration options, see the comments in the `config/.env` file.

## Log Management

### Log Rotation

- **Backend Logs**: Automatic rotation via Elixir Logger (50MB per file, 19 files kept, ~950MB max)
- **Nginx Logs**: Application log files should be managed by logrotate on the host
- **Docker Container Logs**: Configured in `docker-compose/services/backend.yml` and `nginx.yml`

### Old Log Cleanup

To manually clean up old logs:

```bash
docker exec error-scanner bash /scripts/cleanup-old-logs.sh
```

Or schedule with cron:

```bash
# Delete logs older than 7 days at 2 AM daily
0 2 * * * docker exec error-scanner bash /scripts/cleanup-old-logs.sh
```

For more details, see `LOGROTATE.md`.

## Troubleshooting

### Check Logs

```bash
docker logs error-scanner
```

### Manual Scan

```bash
docker exec error-scanner bash /scripts/error-log-scanner.sh scan /logs/prod/error.log
```

### Check Notification History

```bash
docker exec error-scanner cat /tmp/notifications/blockscout_notifications_track.json | jq .
```

### Check Service Status

```bash
docker ps | grep error-scanner
docker inspect error-scanner --format '{{.State.Health.Status}}'
```

## Configuration Priority

1. Environment variables (highest priority)
2. `.env` file (`error-scanner/config/.env`)
3. Script defaults (lowest priority)

