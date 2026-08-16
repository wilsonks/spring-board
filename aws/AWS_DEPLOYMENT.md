# AWS S3 + CloudFront Deployment Guide

## Architecture Overview

```
User → CloudFront CDN → S3 (static assets / HTML)
                      → Backend API (api.springboard-talent.com)
```

```
spring-board/
├── frontend/               # React app → S3 + CloudFront
├── backend/                # Spring Boot API → ECS / App Runner
├── aws/
│   ├── terraform/          # Infrastructure as Code
│   ├── deploy.sh           # Manual deployment script
│   ├── .env.production.example
│   └── AWS_DEPLOYMENT.md   (this file)
├── docker-compose.yml      # Local development
├── docker-compose.prod.yml # Production backend only
└── .github/workflows/
    └── deploy-to-s3.yml    # CI/CD pipeline
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Terraform | >= 1.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Node.js | >= 18 | https://nodejs.org/ |

---

## Step 1 — Create an ACM SSL Certificate

CloudFront requires the certificate to be in **us-east-1** regardless of your primary region.

```bash
aws acm request-certificate \
  --domain-name springboard-talent.com \
  --subject-alternative-names "*.springboard-talent.com" \
  --validation-method DNS \
  --region us-east-1
```

1. Open the [ACM console](https://console.aws.amazon.com/acm/home?region=us-east-1).
2. Click the certificate, then **Create records in Route 53** (or add the CNAME manually to your DNS provider).
3. Wait for **Status: Issued** (usually 5–10 minutes).
4. Copy the certificate ARN — you'll need it in `terraform.tfvars`.

---

## Step 2 — Configure Terraform Variables

```bash
cd aws/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region      = "us-east-1"
bucket_name     = "springboard-talent-frontend"
domain_name     = "springboard-talent.com"
api_domain      = "api.springboard-talent.com"
certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

## Step 3 — Deploy Infrastructure with Terraform

```bash
cd aws/terraform

# Initialise providers and backend
terraform init

# Preview changes
terraform plan

# Apply (creates S3 bucket, CloudFront distribution, cache policies)
terraform apply
```

Capture the outputs:

```bash
terraform output
# cloudfront_distribution_id = "E1EXAMPLE"
# cloudfront_domain_name     = "d1234567890abc.cloudfront.net"
# s3_bucket_name             = "springboard-talent-frontend"
```

---

## Step 4 — Create a Limited IAM User for GitHub Actions

### 4a. Create the user

```bash
aws iam create-user --user-name springboard-github-deployer
```

### 4b. Attach a minimal inline policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3Deploy",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::springboard-talent-frontend",
        "arn:aws:s3:::springboard-talent-frontend/*"
      ]
    },
    {
      "Sid": "CloudFrontInvalidate",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation"
      ],
      "Resource": "arn:aws:cloudfront::*:distribution/YOUR_DISTRIBUTION_ID"
    }
  ]
}
```

```bash
aws iam put-user-policy \
  --user-name springboard-github-deployer \
  --policy-name SpringboardDeployPolicy \
  --policy-document file://iam-policy.json
```

### 4c. Generate access keys

```bash
aws iam create-access-key --user-name springboard-github-deployer
```

---

## Step 5 — Configure GitHub Secrets

In your repository → **Settings → Secrets and variables → Actions**, add:

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `AWS_REGION` | e.g. `us-east-1` |
| `S3_BUCKET` | e.g. `springboard-talent-frontend` |
| `CLOUDFRONT_DISTRIBUTION_ID` | From Terraform output |
| `CLOUDFRONT_DOMAIN` | CloudFront domain or custom domain |
| `REACT_APP_API_BASE_URL` | e.g. `https://api.springboard-talent.com/api/v1` |

---

## Step 6 — Manual Deployment

```bash
cp aws/.env.production.example aws/.env.production
# Edit aws/.env.production with your values

chmod +x aws/deploy.sh
./aws/deploy.sh
```

---

## Step 7 — Automatic Deployment (GitHub Actions)

Push any change under `frontend/` to `main`:

```bash
git add frontend/
git commit -m "feat: update landing page"
git push origin main
```

The workflow (`.github/workflows/deploy-to-s3.yml`) will:

1. Install dependencies and build the React app
2. Run the linter (non-blocking)
3. Sync static assets to S3 with long-term cache headers
4. Sync HTML with no-cache headers
5. Create and wait for a CloudFront invalidation
6. Verify the deployment with an HTTP 200 check
7. Post a summary to the GitHub Actions run page

---

## Step 8 — (Optional) Route53 DNS

If you manage DNS with Route53, uncomment the records in `aws/terraform/route53.tf` and re-run `terraform apply`.

For external DNS providers, add a **CNAME** record:

```
springboard-talent.com  →  d1234567890abc.cloudfront.net
```

---

## Verification

```bash
# Check CloudFront domain
curl -I https://d1234567890abc.cloudfront.net

# Check custom domain (after DNS propagation)
curl -I https://springboard-talent.com
```

Expected: `HTTP/2 200`

---

## Troubleshooting

### 403 Forbidden from CloudFront

- Confirm the S3 bucket policy references the correct CloudFront distribution ARN.
- Check that **Block Public Access** is enabled on the bucket (CloudFront uses OAC, not public ACLs).

### Stale content after deployment

- The workflow invalidates `/index.html` and `/*.html` automatically.
- To manually invalidate everything: `aws cloudfront create-invalidation --distribution-id <ID> --paths "/*"`

### Cache not busting for static assets

- Vite/CRA generates content-hashed filenames (e.g. `main.a1b2c3d4.js`), so long-term caching is safe.
- If you see old assets, check that your build tool outputs unique filenames.

### API requests failing (CORS)

- Ensure the backend returns `Access-Control-Allow-Origin: https://springboard-talent.com`.
- CloudFront forwards `Authorization`, `Origin`, and `Content-Type` headers for `/api/*` requests.

### ACM certificate validation pending

- DNS validation can take up to 30 minutes for new domains.
- Email validation is instant but less automated.

---

## Cost Estimates (us-east-1, typical SPA)

| Service | Estimated Monthly Cost |
|---------|----------------------|
| S3 storage (< 1 GB) | < $0.03 |
| S3 requests (10K GET) | < $0.01 |
| CloudFront (10 GB transfer, PriceClass_100) | ~$0.85 |
| CloudFront requests (100K) | ~$0.01 |
| Route53 hosted zone | $0.50 |
| **Total** | **~$1–5/month** |

---

## Security Notes

- The S3 bucket blocks all public access; only CloudFront can read objects via the OAC bucket policy.
- TLS 1.2+ is enforced on the CloudFront distribution.
- IAM credentials for GitHub Actions are scoped to S3 upload + CloudFront invalidation only.
- Do **not** commit `terraform.tfvars` or `aws/.env.production` — they are listed in `.gitignore`.
