#!/usr/bin/env bash
# deploy.sh — Manual deployment script for Spring Board frontend
# Usage: ./aws/deploy.sh

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Colour

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Global paths (set once, used by all functions) ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FRONTEND_DIR="${REPO_ROOT}/frontend"
DIST_DIR="${FRONTEND_DIR}/dist"

# ── Prerequisites ──────────────────────────────────────────────────────────────
check_prerequisites() {
  info "Checking prerequisites..."

  if ! command -v aws &>/dev/null; then
    error "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    exit 1
  fi

  if ! command -v node &>/dev/null; then
    error "Node.js not found. Install it: https://nodejs.org/"
    exit 1
  fi

  if ! command -v npm &>/dev/null; then
    error "npm not found. Install Node.js: https://nodejs.org/"
    exit 1
  fi

  info "All prerequisites satisfied."
}

# ── Load environment variables ─────────────────────────────────────────────────
load_env() {
  ENV_FILE="${SCRIPT_DIR}/.env.production"

  if [[ -f "${ENV_FILE}" ]]; then
    info "Loading environment from ${ENV_FILE}"
    # shellcheck disable=SC1090
    set -o allexport
    source "${ENV_FILE}"
    set +o allexport
  else
    warn "No ${ENV_FILE} found — relying on environment variables already set."
  fi

  : "${S3_BUCKET:?S3_BUCKET is not set}"
  : "${CLOUDFRONT_DISTRIBUTION_ID:?CLOUDFRONT_DISTRIBUTION_ID is not set}"
  : "${AWS_REGION:?AWS_REGION is not set}"
}

# ── Build frontend ─────────────────────────────────────────────────────────────
build_frontend() {
  info "Installing Node dependencies..."
  (cd "${FRONTEND_DIR}" && npm ci)

  info "Building React application..."
  (cd "${FRONTEND_DIR}" && npm run build)

  if [[ ! -d "${DIST_DIR}" ]]; then
    error "Build output not found at ${DIST_DIR}"
    exit 1
  fi

  info "Build complete: ${DIST_DIR}"
}

# ── Upload to S3 ───────────────────────────────────────────────────────────────
upload_to_s3() {
  info "Uploading static assets (long-term cache)..."
  aws s3 sync "${DIST_DIR}/static" "s3://${S3_BUCKET}/static" \
    --region "${AWS_REGION}" \
    --cache-control "public, max-age=31536000, immutable" \
    --delete

  info "Uploading HTML and remaining files (no cache)..."
  aws s3 sync "${DIST_DIR}" "s3://${S3_BUCKET}" \
    --region "${AWS_REGION}" \
    --exclude "static/*" \
    --cache-control "no-cache, no-store, must-revalidate" \
    --delete

  info "S3 upload complete."
}

# ── CloudFront invalidation ────────────────────────────────────────────────────
invalidate_cloudfront() {
  info "Creating CloudFront invalidation..."

  INVALIDATION_ID=$(aws cloudfront create-invalidation \
    --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
    --paths "/index.html" "/*.html" \
    --query 'Invalidation.Id' \
    --output text)

  info "Invalidation created: ${INVALIDATION_ID}"
  info "Waiting for invalidation to complete (this may take a few minutes)..."

  aws cloudfront wait invalidation-completed \
    --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
    --id "${INVALIDATION_ID}"

  info "CloudFront invalidation complete."
}

# ── Verify deployment ──────────────────────────────────────────────────────────
verify_deployment() {
  if [[ -z "${CLOUDFRONT_DOMAIN:-}" ]]; then
    warn "CLOUDFRONT_DOMAIN not set — skipping HTTP verification."
    return
  fi

  info "Verifying deployment at https://${CLOUDFRONT_DOMAIN} ..."

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${CLOUDFRONT_DOMAIN}")

  if [[ "${HTTP_STATUS}" -eq 200 ]]; then
    info "✅ Deployment verified — HTTP ${HTTP_STATUS}"
  else
    error "Deployment verification failed — HTTP ${HTTP_STATUS}"
    exit 1
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "=========================================="
  echo "  Spring Board — Frontend Deployment"
  echo "=========================================="
  echo ""

  check_prerequisites
  load_env
  build_frontend
  upload_to_s3
  invalidate_cloudfront
  verify_deployment

  echo ""
  info "🚀 Deployment complete!"
  echo ""
}

main "$@"
