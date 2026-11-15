#!/usr/bin/env bash
# Build the React app and publish it to S3 + CloudFront.
# Usage: ./scripts/deploy-frontend.sh /path/to/urbanserve-web
set -euo pipefail

WEB_DIR="${1:?Usage: $0 /path/to/urbanserve-web}"
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"

BUCKET="$(terraform -chdir="$TF_DIR" output -raw site_bucket)"
DIST_ID="$(terraform -chdir="$TF_DIR" output -raw cloudfront_distribution_id)"
SITE_URL="$(terraform -chdir="$TF_DIR" output -raw site_url)"

echo "==> Building $WEB_DIR"
cd "$WEB_DIR"
npm ci || npm install
# UI and API share one CloudFront domain, so API calls stay relative (/api/...).
VITE_API_BASE="" npm run build

echo "==> Uploading hashed assets (cached 1 year)"
aws s3 sync dist/ "s3://$BUCKET/" --delete \
  --exclude "index.html" \
  --cache-control "public, max-age=31536000, immutable"

echo "==> Uploading index.html (always revalidated)"
aws s3 cp dist/index.html "s3://$BUCKET/index.html" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --content-type "text/html; charset=utf-8"

echo "==> Invalidating CloudFront"
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/index.html" "/" >/dev/null

echo "Done: $SITE_URL"
