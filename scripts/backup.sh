#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GCS_BUCKET="${GCS_BUCKET:-hybridmod-db-backups_rt}"

cd "$PROJECT_DIR"
mkdir -p backups

# cli avl.
if ! command -v gcloud >/dev/null 2>&1; then
    echo "ERROR: Google Cloud CLI is not installed."
    exit 1
fi

# bucket acc.
if ! gcloud storage buckets describe "gs://${GCS_BUCKET}" >/dev/null 2>&1; then
    echo "ERROR: Cannot access bucket gs://${GCS_BUCKET}"
    echo "Check your Google Cloud login, project, and permissions."
    exit 1
fi

TIMESTAMP="$(date -u +'%Y%m%dT%H%M%SZ')"
BACKUP_FILE="backups/hybridmod_${TIMESTAMP}.dump"

echo "Checking PostgreSQL..."

if ! docker compose exec -T db pg_isready -U hybriduser -d hybridmod >/dev/null; then
    echo "ERROR: PostgreSQL is not ready."
    exit 1
fi

echo "Creating database backup..."

if ! docker compose exec -T db \
    pg_dump -U hybriduser -d hybridmod -Fc > "$BACKUP_FILE"; then
    rm -f "$BACKUP_FILE"
    echo "ERROR: Database backup failed."
    exit 1
fi

if [[ ! -s "$BACKUP_FILE" ]]; then
    rm -f "$BACKUP_FILE"
    echo "ERROR: Backup file is empty."
    exit 1
fi

echo "Validating backup archive..."

if ! docker compose exec -T db \
    pg_restore --list < "$BACKUP_FILE" >/dev/null; then
    rm -f "$BACKUP_FILE"
    echo "ERROR: Backup archive validation failed."
    exit 1
fi

echo "Generating SHA-256 checksum..."

sha256sum "$BACKUP_FILE" | tee "${BACKUP_FILE}.sha256"

echo "Uploading database backup to Google Cloud Storage..."

gcloud storage cp "$BACKUP_FILE" "gs://${GCS_BUCKET}/"
gcloud storage cp "${BACKUP_FILE}.sha256" "gs://${GCS_BUCKET}/"

# Confirm both objects exist in the bucket.
gcloud storage ls "gs://${GCS_BUCKET}/$(basename "$BACKUP_FILE")" >/dev/null
gcloud storage ls "gs://${GCS_BUCKET}/$(basename "${BACKUP_FILE}.sha256")" >/dev/null

echo
echo "SUCCESS: Backup created and uploaded."
echo "Local file: $BACKUP_FILE"
echo "Cloud destination: gs://${GCS_BUCKET}/"
