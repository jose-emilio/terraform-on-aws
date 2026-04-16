# ── Locals ──────────────────────────────────────────────────────────────────
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── KMS: Clave maestra (emulada por LocalStack) ───────────────────────────────
resource "aws_kms_key" "secrets" {
  description             = "CMK para ${var.project_name}: cifra Secrets Manager y RDS"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-secrets-cmk"
  })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ── Contraseña criptográficamente segura ────────────────────────────────────
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Secrets Manager: contenedor del secreto ─────────────────────────────────
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project_name}/rds/master-credentials"
  description = "Credenciales maestras de RDS para ${var.project_name}"
  kms_key_id  = aws_kms_key.secrets.key_id

  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-db-credentials"
  })
}

# ── Secrets Manager: versión con credenciales en formato JSON ────────────────
# El host se deja como placeholder ya que RDS no está disponible en
# LocalStack Community. En AWS real, se reemplaza por aws_db_instance.main.address.
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    engine   = "mysql"
    host     = "localhost"
    port     = 3306
    dbname   = var.db_name
  })
}

# RDS, VPC, subredes y security group se omiten en LocalStack Community:
# el servicio RDS no está incluido en la licencia Community.
# Todos esos recursos están disponibles en la versión aws/.
