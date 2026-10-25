############################################################################
# ECR: AWS's private cupboard for container images (Module 11.1)
############################################################################
resource "aws_ecr_repository" "account_service" {
  name = "${var.prefix}/account-service"

  # Never deploy "latest": it means "whatever was pushed most recently", so a
  # rollback is not exact. IMMUTABLE makes re-pushing an existing tag an error.
  image_tag_mutability = "IMMUTABLE"

  # destroy can remove the repo even if it still holds images (lab setting).
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
}

resource "aws_ecr_lifecycle_policy" "account_service" {
  repository = aws_ecr_repository.account_service.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
