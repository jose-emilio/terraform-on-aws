# ── S3: artefactos de la aplicacion ──────────────────────────────────────────
#
# app.py se sube a S3 en lugar de embeberse en el user_data para evitar el
# limite de 16 KB de EC2 user_data y permitir actualizaciones sin recrear
# el Launch Template: basta con subir una nueva version a S3 y reiniciar la instancia.

resource "aws_s3_bucket" "app_artifacts" {
  bucket        = "${var.project}-app-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "app_artifacts" {
  bucket                  = aws_s3_bucket.app_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "app_py" {
  bucket = aws_s3_bucket.app_artifacts.id
  key    = "app.py"
  source = "${path.module}/app/app.py"
  etag   = filemd5("${path.module}/app/app.py")
  tags   = local.tags
}

# ── EC2: instancia de la aplicacion ──────────────────────────────────────────
#
# Instancia ARM64 (t4g) en la subnet publica. Recibe IP publica automatica
# y puede acceder directamente a AWS APIs via internet (DynamoDB, S3,
# Secrets Manager), sin necesidad de NAT Gateway ni VPC endpoints.
#
# La comunicacion con Redis se realiza via routing interno de la VPC:
# EC2 (public subnet) → Redis (private subnet), ambos en la misma VPC.
# Los Security Groups controlan que solo esta instancia pueda conectar a Redis.

resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.app_instance_type
  subnet_id              = aws_subnet.public["${var.region}a"].id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  metadata_options {
    http_tokens = "required"
  }

  user_data_base64 = base64encode(templatefile("${path.module}/scripts/user_data.sh.tpl", {
    region            = var.region
    project           = var.project
    bucket_name       = aws_s3_bucket.app_artifacts.bucket
    dynamo_table      = aws_dynamodb_table.products.name
    events_table      = aws_dynamodb_table.events.name
    redis_host        = aws_elasticache_replication_group.redis.primary_endpoint_address
    redis_secret_name = aws_secretsmanager_secret.redis_auth.name
    cache_ttl         = var.cache_ttl
  }))

  tags = merge(local.tags, { Name = "${var.project}-app" })

  depends_on = [
    aws_internet_gateway.main,
    aws_elasticache_replication_group.redis,
    aws_secretsmanager_secret_version.redis_auth,
    aws_s3_object.app_py,
    aws_dynamodb_table.products,
    aws_dynamodb_table.events,
  ]
}
