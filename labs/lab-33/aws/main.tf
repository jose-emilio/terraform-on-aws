# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# Incluye el Account ID en el nombre del bucket para garantizar unicidad global.
data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project}-datalake-${data.aws_caller_identity.current.account_id}"
}

# ── VPC y red privada ─────────────────────────────────────────────────────────
#
# La VPC aloja la subred privada desde la que se accede al bucket.
# El Gateway Endpoint de S3 enruta el trafico S3 de esta subred directamente
# a S3 sin salir a internet, y sirve como condicion de la bucket policy.

resource "aws_vpc" "main" {
  cidr_block           = "10.29.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.project}-vpc" })
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.29.1.0/24"
  availability_zone = "${var.region}a"
  tags              = merge(local.tags, { Name = "${var.project}-private" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project}-private-rt" })
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── VPC Gateway Endpoint para S3 ─────────────────────────────────────────────
#
# Un Gateway Endpoint es gratuito (a diferencia del Interface Endpoint).
# Inyecta una ruta en las route tables asociadas para dirigir el trafico S3
# a traves de la red privada de AWS en lugar de a traves de internet.
# El ID del endpoint se usa en la bucket policy como condicion de acceso.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(local.tags, { Name = "${var.project}-s3-endpoint" })
}

# ── Modulo: Bucket Seguro ─────────────────────────────────────────────────────
#
# El modulo secure-bucket encapsula todos los controles de seguridad y ciclo de
# vida del bucket: CMK KMS, SSE-KMS con Bucket Key, public access block,
# versionado, lifecycle y bucket policy restringida al endpoint.

module "datalake" {
  source = "./modules/secure-bucket"

  bucket_name     = local.bucket_name
  project         = var.project
  tags            = local.tags
  vpc_endpoint_id = aws_vpc_endpoint.s3.id
  transition_days = var.transition_days
  expiration_days = var.expiration_days
}
