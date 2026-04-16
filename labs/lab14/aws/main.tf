# ── Locals ──────────────────────────────────────────────────────────────────
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # AZs explícitas para garantizar que las dos subredes privadas caen en
  # zonas distintas. RDS exige al menos 2 AZs distintas en el subnet group.
  azs = ["${var.region}a", "${var.region}b"]
}

# ── KMS: Clave maestra para cifrar secretos y almacenamiento ─────────────────
# Esta clave cifra tres capas: Secrets Manager, el almacenamiento RDS y,
# una vez exportada su ARN, el backend S3 con el .tfstate.
resource "aws_kms_key" "secrets" {
  description             = "CMK para ${var.project_name}: cifra Secrets Manager, RDS y el backend de Terraform"
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
# random_password genera entropía real del sistema operativo subyacente.
# El resultado se almacena cifrado en el estado de Terraform; nunca aparece
# en variables del operador ni en la salida del plan.
resource "random_password" "db" {
  length  = 32
  special = true
  # Excluimos caracteres que rompen cadenas de conexión MySQL/JDBC:
  # @, ', ", /, \, `, ^, ~, |, espacio
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Secrets Manager: contenedor del secreto ─────────────────────────────────
resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project_name}/rds/master-credentials"
  description = "Credenciales maestras de RDS para ${var.project_name} - gestionadas por Terraform"
  kms_key_id  = aws_kms_key.secrets.key_id

  # En entorno de lab se elimina sin período de recuperación para facilitar
  # redeployments. En producción usa recovery_window_in_days = 30.
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-db-credentials"
  })
}

# ── Secrets Manager: versión con credenciales en formato JSON ────────────────
# El secreto incluye todos los datos necesarios para conectar a la base de
# datos. Las aplicaciones recuperan este JSON sin conocer la contraseña en
# tiempo de despliegue.
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    engine   = "mysql"
    host     = aws_db_instance.main.address
    port     = 3306
    dbname   = var.db_name
  })
}

# ── Red mínima para RDS ─────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-vpc" })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-db-subnet-group"
  })
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Acceso a RDS restringido al CIDR interno de la VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "MySQL desde la VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Salida sin restricciones"
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-rds-sg" })
}

# ── RDS: inyección directa de la contraseña desde random_password ────────────
# La contraseña nunca aparece como variable de entrada del operador.
# Terraform la genera, la cifra en el estado (via KMS si el backend está
# configurado correctamente) y la inyecta directamente en RDS y en el secreto.
resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-db"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.secrets.arn

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result # <- Zero-Touch: inyeccion directa

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Configuración simplificada para entorno de lab
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  multi_az                = false

  tags = merge(local.common_tags, { Name = "${var.project_name}-db" })
}
