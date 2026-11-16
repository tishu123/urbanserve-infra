#!/usr/bin/env bash
# Build urbanserve-payment, upload it, restart its service via SSM (no SSH) and check it answers.
# Its config (DB, Razorpay keys, internal token) comes from SSM on start, set via terraform.tfvars.
# Usage: ./scripts/deploy-payment.sh /path/to/urbanserve-payment
set -euo pipefail

PAYMENT_DIR="${1:?Usage: $0 /path/to/urbanserve-payment}"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

BUCKET="$(terraform -chdir="$TF_DIR" output -raw artifacts_bucket)"
INSTANCE="$(terraform -chdir="$TF_DIR" output -raw app_instance_id)"

echo "==> Building jar"
(cd "$PAYMENT_DIR" && mvn -q clean package -DskipTests)
JAR="$PAYMENT_DIR/target/urbanserve-payment.jar"
[ -f "$JAR" ] || JAR="$(ls "$PAYMENT_DIR"/target/urbanserve-payment*.jar | grep -v original | head -1)"

echo "==> Uploading $JAR"
aws s3 cp "$JAR" "s3://$BUCKET/backend/payment.jar"

echo "==> Restarting urbanserve-payment on $INSTANCE and waiting for it to be healthy"
CMD_ID="$(aws ssm send-command --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl restart urbanserve-payment","for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8091/ && echo payment-up && exit 0; sleep 5; done; journalctl -u urbanserve-payment -n 50 --no-pager; exit 1"]' \
  --query Command.CommandId --output text)"
aws ssm wait command-executed --command-id "$CMD_ID" --instance-id "$INSTANCE" || true
STATUS="$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE" --query Status --output text)"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE" --query StandardOutputContent --output text

if [ "$STATUS" = "Success" ]; then
  echo "Payment is up."
else
  echo "Payment did not become healthy ($STATUS). Logs: aws ssm start-session --target $INSTANCE  then  journalctl -u urbanserve-payment -n 100" >&2
  exit 1
fi
