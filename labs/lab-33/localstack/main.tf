# Version LocalStack de Lab33.
#
# Limitaciones conocidas en Community:
#   SSE-KMS       — la CMK se crea correctamente pero el cifrado real no se aplica.
#   VPC endpoint  — el recurso se crea pero no enruta trafico real.
#   Bucket policy — la condicion aws:sourceVpce se acepta pero no se evalua.
#
# Los recursos S3 (bucket, public access block, versionado, lifecycle) funcionan
# plenamente en LocalStack Community.

# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
  bucket_name = "${var.project}-datalake"
}

# ── VPC y VPC Endpoint ────────────────────────────────────────────────────────
# Recursos de red creados para demostrar la configuracion; no enrutan
# trafico real en LocalStack Community.

resource "aws_vpc" "main" {
  cidr_block = "10.29.0.0/16"
  tags       = merge(local.tags, { Name = "${var.project}-vpc" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project}-private-rt" })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(local.tags, { Name = "${var.project}-s3-endpoint" })
}

# ── Modulo: Bucket Seguro ─────────────────────────────────────────────────────

module "datalake" {
  source = "./modules/secure-bucket"

  bucket_name     = local.bucket_name
  project         = var.project
  tags            = local.tags
  vpc_endpoint_id = aws_vpc_endpoint.s3.id
  transition_days = var.transition_days
  expiration_days = var.expiration_days
}
