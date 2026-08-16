variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "bucket_name" {
  description = "S3 bucket name for frontend"
  type        = string
  default     = "springboard-talent-frontend"
}

variable "domain_name" {
  description = "Domain name for CloudFront"
  type        = string
  default     = "springboard-talent.com"
}

variable "api_domain" {
  description = "Backend API domain"
  type        = string
  default     = "api.springboard-talent.com"
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS"
  type        = string
}

variable "enable_versioning" {
  description = "Enable S3 versioning"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags for resources"
  type        = map(string)
  default = {
    Project     = "Springboard Talent"
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}
