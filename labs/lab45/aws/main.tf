# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ═══════════════════════════════════════════════════════════════════════════════
# KMS — Clave de cifrado para artefactos del pipeline
# ═══════════════════════════════════════════════════════════════════════════════
#
# Todos los artefactos del pipeline (source ZIP, tfplan.bin, tfplan.json)
# se cifran con esta clave en reposo. La politica delega la autorizacion
# en IAM: los roles de CodePipeline, CodeBuild y Lambda reciben el permiso
# kms:Decrypt en sus politicas inline para poder leer los artefactos.

resource "aws_kms_key" "artifacts" {
  description             = "Clave de cifrado para artefactos del pipeline ${var.project}."
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      }
    ]
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "pipeline-artifact-encryption"
  }
}

resource "aws_kms_alias" "artifacts" {
  name          = "alias/${var.project}-artifacts"
  target_key_id = aws_kms_key.artifacts.key_id
}

# ═══════════════════════════════════════════════════════════════════════════════
# S3 — Bucket de artefactos del pipeline
# ═══════════════════════════════════════════════════════════════════════════════
#
# CodePipeline usa este bucket para pasar artefactos entre etapas:
#   pipeline/  → artefactos gestionados por CodePipeline (source ZIP, plan ZIP)
#   tfstate/   → estado de Terraform del codigo gestionado por el pipeline
#
# El versionado garantiza que CodePipeline puede recuperar artefactos de
# ejecuciones anteriores. La politica de ciclo de vida limpia versiones antiguas.

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project}-pipeline-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "pipeline-artifacts-and-tfstate"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts.arn
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "artifacts_bucket_policy" {
  statement {
    sid    = "DenyNonTLS"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_bucket_policy.json

  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-pipeline-artifacts"
    status = "Enabled"

    filter {
      prefix = "pipeline/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# CodeCommit — Repositorio fuente del codigo Terraform gestionado por el pipeline
# ═══════════════════════════════════════════════════════════════════════════════
#
# El repositorio contiene el codigo Terraform del directorio repo/ del laboratorio:
#   target/         Recursos que el pipeline despliega
#   buildspecs/     Ficheros buildspec de cada proyecto CodeBuild
#   .tflint.hcl     Configuracion de TFLint
#
# Un trigger EventBridge lanza el pipeline en cada push a la rama configurada.

resource "aws_codecommit_repository" "terraform" {
  repository_name = "${var.project}-terraform"
  description     = "Codigo Terraform gestionado por el pipeline ${var.project}."

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── EventBridge — dispara el pipeline en cada push ────────────────────────────

resource "aws_cloudwatch_event_rule" "on_push" {
  name        = "${var.project}-on-push-${var.branch}"
  description = "Dispara el pipeline ${var.project} en cada push a la rama ${var.branch}."

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    detail-type = ["CodeCommit Repository State Change"]
    resources   = [aws_codecommit_repository.terraform.arn]
    detail = {
      event         = ["referenceUpdated", "referenceCreated"]
      referenceType = ["branch"]
      referenceName = [var.branch]
    }
  })

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule     = aws_cloudwatch_event_rule.on_push.name
  arn      = aws_codepipeline.main.arn
  role_arn = aws_iam_role.events.arn
}

# ── CloudWatch Log Groups para CodeBuild ──────────────────────────────────────

resource "aws_cloudwatch_log_group" "validate" {
  name              = "/aws/codebuild/${var.project}-validate"
  retention_in_days = var.log_retention_days

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_cloudwatch_log_group" "security_scan" {
  name              = "/aws/codebuild/${var.project}-security-scan"
  retention_in_days = var.log_retention_days

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_cloudwatch_log_group" "plan" {
  name              = "/aws/codebuild/${var.project}-plan"
  retention_in_days = var.log_retention_days

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_cloudwatch_log_group" "apply" {
  name              = "/aws/codebuild/${var.project}-apply"
  retention_in_days = var.log_retention_days

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_cloudwatch_log_group" "smoketest" {
  name              = "/aws/codebuild/${var.project}-smoketest"
  retention_in_days = var.log_retention_days

  tags = { Project = var.project, ManagedBy = "terraform" }
}
