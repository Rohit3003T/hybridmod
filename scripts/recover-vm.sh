#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:?Provide the public Docker Hub image, including its tag}"
BUCKET="hybridmod-db-backups_rt"

echo "=== Installing recovery prerequisites ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io curl python3 openssl ca-certificates
systemctl enable --now docker

echo "=== Pulling application image: ${IMAGE} ==="
docker pull "$IMAGE"

echo "=== Authenticating to Google Cloud Storage ==="
TOKEN="$(curl -fsS \
  -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

LIST_JSON="$(curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://storage.googleapis.com/storage/v1/b/${BUCKET}/o?prefix=hybridmod_")"

LATEST_OBJECT="$(printf '%s' "$LIST_JSON" | python3 -c '
import json,sys
data=json.load(sys.stdin)
names=[item["name"] for item in data.get("items", [])
       if item["name"].endswith(".dump")]
print(max(names) if names else "")
')"

if [[ -z "$LATEST_OBJECT" ]]; then
  echo "ERROR: No PostgreSQL dump was found in gs://${BUCKET}"
  exit 1
fi

echo "Latest backup: ${LATEST_OBJECT}"

ENCODED_OBJECT="$(python3 -c \
  'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=""))' \
  "$LATEST_OBJECT")"

curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  "https://storage.googleapis.com/download/storage/v1/b/${BUCKET}/o/${ENCODED_OBJECT}?alt=media" \
  -o /tmp/hybridmod-latest.dump

CHECKSUM_OBJECT="${LATEST_OBJECT}.sha256"
ENCODED_CHECKSUM="$(python3 -c \
  'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=""))' \
  "$CHECKSUM_OBJECT")"

curl -fsS -H "Authorization: Bearer ${TOKEN}" \
  "https://storage.googleapis.com/download/storage/v1/b/${BUCKET}/o/${ENCODED_CHECKSUM}?alt=media" \
  -o /tmp/hybridmod-latest.dump.sha256

EXPECTED="$(awk 'NR==1 {print $1}' /tmp/hybridmod-latest.dump.sha256)"
ACTUAL="$(sha256sum /tmp/hybridmod-latest.dump | awk '{print $1}')"

if [[ "$EXPECTED" != "$ACTUAL" ]]; then
  echo "ERROR: Backup checksum verification failed."
  exit 1
fi
echo "Backup checksum verified."

echo "=== Validating PostgreSQL archive ==="
docker run --rm \
  -v /tmp/hybridmod-latest.dump:/backup.dump:ro \
  postgres:16-alpine pg_restore --list /backup.dump >/dev/null

if [[ ! -s /root/hybridmod-db-password ]]; then
  openssl rand -hex 24 > /root/hybridmod-db-password
  chmod 600 /root/hybridmod-db-password
fi
DB_PASSWORD="$(cat /root/hybridmod-db-password)"

docker network inspect hybridmod-net >/dev/null 2>&1 ||
  docker network create hybridmod-net >/dev/null
docker volume create hybridmod_pgdata >/dev/null

docker rm -f hybridmod-app hybridmod-db >/dev/null 2>&1 || true

echo "=== Starting PostgreSQL ==="
docker run -d \
  --name hybridmod-db \
  --network hybridmod-net \
  --restart unless-stopped \
  -v hybridmod_pgdata:/var/lib/postgresql/data \
  -e POSTGRES_USER=hybriduser \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  -e POSTGRES_DB=hybridmod \
  postgres:16-alpine >/dev/null

for attempt in $(seq 1 60); do
  if docker exec hybridmod-db pg_isready -h 127.0.0.1 -U hybriduser -d hybridmod >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! docker exec hybridmod-db pg_isready -h 127.0.0.1 -U hybriduser -d hybridmod; then
  docker logs hybridmod-db
  echo "ERROR: PostgreSQL did not become ready."
  exit 1
fi

echo "=== Restoring database backup ==="
docker cp /tmp/hybridmod-latest.dump hybridmod-db:/tmp/hybridmod.dump
docker exec hybridmod-db pg_restore \
  --clean --if-exists --no-owner \
  -U hybriduser -d hybridmod /tmp/hybridmod.dump

echo "=== Starting application ==="
docker run -d \
  --name hybridmod-app \
  --network hybridmod-net \
  --restart unless-stopped \
  -e "DATABASE_URL=postgresql://hybriduser:${DB_PASSWORD}@hybridmod-db:5432/hybridmod" \
  -p 80:5000 \
  "$IMAGE" >/dev/null

echo "=== Waiting for application health check ==="
READY=false
for attempt in $(seq 1 60); do
  if curl -fsS http://127.0.0.1/health -o /tmp/hybridmod-health.json; then
    READY=true
    break
  fi
  sleep 2
done

if [[ "$READY" != true ]]; then
  docker logs --tail=50 hybridmod-app
  echo "ERROR: Application health check failed."
  exit 1
fi

echo
echo "=== RECOVERY COMPLETED ==="
cat /tmp/hybridmod-health.json
echo
echo "Application URL: http://$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)"
echo "Restored backup: ${LATEST_OBJECT}"
echo "Database password saved securely at /root/hybridmod-db-password"
