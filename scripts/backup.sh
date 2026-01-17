#!/bin/bash
# PathSteer local backup - runs hourly, keeps 48 hours locally
# Optionally syncs to controller

BACKUP_DIR="/opt/pathsteer/backups"
MAX_AGE_HOURS=48
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

# Prune old backups
find "$BACKUP_DIR" -name "pathsteer_*.tar.gz" -mmin +$((MAX_AGE_HOURS * 60)) -delete

# Optional: sync to controller (uncomment when ready)
# rsync -az "$BACKUP_DIR/" controller.pathsteer.com:/backups/edge-protectli-1/

echo "Backup complete: pathsteer_$TIMESTAMP.tar.gz"
ls -lh "$BACKUP_DIR" | tail -5
