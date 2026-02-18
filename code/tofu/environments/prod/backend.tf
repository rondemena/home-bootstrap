# =============================================================================
# OpenTofu Backend Configuration
# =============================================================================
# State backend: MinIO S3-compatible storage on k3s cluster
#
# IMPORTANT: HCL backend blocks cannot use variables. To change the
# MinIO endpoint for your environment, either:
#   1. Edit the endpoint below directly, or
#   2. Use partial configuration: tofu init -backend-config="endpoint=https://minio.your.domain"
#
# Migration from local state:
#   1. Deploy MinIO: make deploy-apps (includes MinIO ArgoCD app)
#   2. Create bucket: mc mb minio/tofu-state
#   3. Uncomment S3 backend below, comment out local backend
#   4. Run: cd code/tofu/environments/prod && tofu init -migrate-state
#   5. Verify: tofu state list
#   6. Remove local terraform.tfstate after confirming migration
# =============================================================================

# S3 backend (MinIO on k3s) - ACTIVE after migration
# Override endpoint via: tofu init -backend-config="endpoint=https://minio.YOUR_DOMAIN"
terraform {
  backend "s3" {
    bucket                      = "tofu-state"
    key                         = "prod/terraform.tfstate"
    region                      = "us-east-1" # Required but unused by MinIO
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
    # Credentials via env vars: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
    # Endpoint via: tofu init -backend-config="endpoint=https://minio.example.com"
  }
}

# Local backend (bootstrap phase only) - COMMENT OUT after migration
# terraform {
#   backend "local" {
#     path = "terraform.tfstate"
#   }
# }
