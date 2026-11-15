#!/usr/bin/env bash
# Build urbanserve-dispatch, upload it, restart its service via SSM (no SSH) and check its health.
# Usage: ./scripts/deploy-dispatch.sh /path/to/urbanserve-dispatch
set -euo pipefail

DISPATCH_DIR="${1:?Usage: $0 /path/to/urbanserve-dispatch}"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

BUCKET="$(terraform -chdir="$TF_DIR" output -raw artifacts_bucket)"
INSTANCE="$(terraform -chdir="$TF_DIR" output -raw app_instance_id)"

echo "==> Building jar"
(cd "$DISPATCH_DIR" && mvn -q clean package -DskipTests)
JAR="$DISPATCH_DIR/target/urbanserve-dispatch.jar"
[ -f "$JAR" ] || JAR="$(ls "$DISPATCH_DIR"/target/urbanserve-dispatch*.jar | grep -v original | head -1)"

echo "==> Uploading $JAR"
aws s3 cp "$JAR" "s3://$BUCKET/backend/dispatch.jar"

echo "==> Restarting urbanserve-dispatch on $INSTANCE and waiting for it to be healthy"
CMD_ID="$(aws ssm send-command --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl restart urbanserve-dispatch","for i in $(seq 1 30); do curl -fsS http://127.0.0.1:8090/actuator/health && exit 0; sleep 5; done; journalctl -u urbanserve-dispatch -n 50 --no-pager; exit 1"]' \
  --query Command.CommandId --output text)"
aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$INSTANCE" || true
STATUS="$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE" --query Status --output text)"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE" --query StandardOutputContent --output text

if [ "$STATUS" = "Success" ]; then
  echo "Dispatch is up."
else
  echo "Dispatch did not become healthy ($STATUS). Logs: aws ssm start-session --target $INSTANCE  then  journalctl -u urbanserve-dispatch -n 100" >&2
  exit 1
fi
