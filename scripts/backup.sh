#!/bin/bash
# PathSteer local backup - runs hourly, keeps 2 weeks locally

BACKUP_DIR="/opt/pathsteer/backups"
MAX_AGE_DAYS=14
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

# Create tarball of source and config
tar czf "$BACKUP_DIR/pathsteer_$TIMESTAMP.tar.gz" \
    /opt/pathsteer/src \
    /opt/pathsteer/scripts \
    /opt/pathsteer/web \
    /opt/pathsteer/bin/pathsteerd \
    /etc/pathsteer \
    2>/dev/null

# Prune backups older than 2 weeks
find "$BACKUP_DIR" -name "pathsteer_*.tar.gz" -mtime +$MAX_AGE_DAYS -delete

# Also prune old training DBs
find "$BACKUP_DIR" -name "training_*.db" -mtime +$MAX_AGE_DAYS -delete

echo "$(date): Backup complete, pruned files older than ${MAX_AGE_DAYS} days"
