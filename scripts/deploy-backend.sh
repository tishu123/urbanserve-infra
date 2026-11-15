#!/usr/bin/env bash
# Build the Spring Boot jar, upload it, and restart the service via SSM (no SSH).
# Usage: ./scripts/deploy-backend.sh /path/to/urbanserve
set -euo pipefail

API_DIR="${1:?Usage: $0 /path/to/urbanserve}"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

BUCKET="$(terraform -chdir="$TF_DIR" output -raw artifacts_bucket)"
INSTANCE="$(terraform -chdir="$TF_DIR" output -raw app_instance_id)"
SITE_URL="$(terraform -chdir="$TF_DIR" output -raw site_url)"

echo "==> Building jar"
(cd "$API_DIR" && mvn -q clean package -DskipTests)
JAR="$API_DIR/target/urbanserve.jar"
[ -f "$JAR" ] || JAR="$(ls "$API_DIR"/target/urbanserve*.jar | grep -v original | head -1)"

echo "==> Uploading $JAR"
aws s3 cp "$JAR" "s3://$BUCKET/backend/urbanserve.jar"

echo "==> Restarting service on $INSTANCE"
CMD_ID="$(aws ssm send-command --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl restart urbanserve"]' \
  --query Command.CommandId --output text)"
aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$INSTANCE" || true

echo "==> Waiting for health check"
for i in $(seq 1 30); do
  if curl -fsS "$SITE_URL/api/categories" >/dev/null 2>&1; then echo "API is up: $SITE_URL/api/categories"; exit 0; fi
  sleep 5
done
echo "API did not come up in time. Check logs: aws ssm start-session --target $INSTANCE  then  journalctl -u urbanserve -n 100" >&2
exit 1
