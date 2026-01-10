#!/bin/bash
# Backup training data to cloud

DB_PATH="/opt/pathsteer/data/training.db"
BACKUP_DIR="/opt/pathsteer/backups"
mkdir -p $BACKUP_DIR

# Local backup with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp $DB_PATH $BACKUP_DIR/training_$TIMESTAMP.db 2>/dev/null || true

# Keep only last 24 backups
ls -t $BACKUP_DIR/training_*.db 2>/dev/null | tail -n +25 | xargs rm -f 2>/dev/null

# Git push (if configured)
cd /opt/pathsteer
git add -A 2>/dev/null
git commit -m "Auto backup $TIMESTAMP" 2>/dev/null
git push 2>/dev/null || true

echo "Backup complete: $TIMESTAMP"
