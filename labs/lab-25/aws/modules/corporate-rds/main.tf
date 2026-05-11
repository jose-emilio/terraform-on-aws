# ===========================================================================
# Módulo corporate-rds — Wrapper corporativo: VPC + RDS
# ===========================================================================
# Orquesta módulos públicos del Registry inyectando estándares de
# seguridad obligatorios que el usuario final no puede desactivar:
#   - storage_encrypted   = true  (siempre cifrado)
#   - deletion_protection = true  (protección contra borrado)
#   - Bloqueo de acceso público    (sin public access)
#   - Security group restrictivo   (solo desde subredes privadas)
# ===========================================================================

# --- Data Sources ---

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# --- Locals ---

locals {
  azs = length(var.azs) > 0 ? var.azs : slice(data.aws_availability_zones.available.names, 0, 2)

  effective_tags = merge(var.tags, {
    Module = "corporate-rds"
  })

  # Coherencia engine ↔ version. Lista los prefijos validos por motor
  # para detectar combinaciones imposibles (ej: mysql con 15.4) ANTES de
  # crear el security group. Si alguien añade un motor nuevo aqui debe
  # tambien añadirlo a la validation de var.db_engine.
  valid_engine_version_prefixes = {
    mysql    = ["5.7", "8.0", "8.4"]
    mariadb  = ["10.4", "10.5", "10.6", "10.11", "11.4"]
    postgres = ["12.", "13.", "14.", "15.", "16.", "17."]
  }

  engine_version_is_valid = anytrue([
    for prefix in local.valid_engine_version_prefixes[var.db_engine] :
    startswith(var.db_engine_version, prefix)
  ])
}

# ===========================================================================
# Módulo público: VPC (terraform-aws-modules/vpc/aws)
# ===========================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs              = local.azs
  private_subnets  = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  database_subnets = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, 20 + i)]
  public_subnets   = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, i)]

  # NAT Gateway para que las subredes privadas tengan salida a Internet.
  # single_nat_gateway = true → un único NAT GW para todas las AZs,
  # mas barato (~$32/mes en lugar de $32 × N). Aceptable en lab y dev.
  # En PRODUCCION usa single_nat_gateway = false (uno por AZ) para que
  # la caida de una AZ no rompa la salida a Internet del resto.
  enable_nat_gateway = true
  single_nat_gateway = true

  # Grupo de subredes para RDS (creado por el módulo de VPC)
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  # DNS (requerido para endpoints de RDS)
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.effective_tags
}

# ===========================================================================
# Security Group para RDS — Solo acceso desde subredes privadas
# ===========================================================================

resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "Acceso a RDS solo desde subredes privadas"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = var.db_port
    to_port     = var.db_port
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
    description = "Acceso desde subredes privadas"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Todo el trafico saliente"
  }

  tags = merge(local.effective_tags, {
    Name = "${var.project_name}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true

    # Precondition: aborta antes de crear NADA si la combinacion
    # engine+version no es coherente. Usamos el SG como punto de entrada
    # porque se crea muy temprano en el grafo y porque las validation
    # individuales en variables.tf solo ven una variable a la vez.
    precondition {
      condition     = local.engine_version_is_valid
      error_message = "Combinación engine='${var.db_engine}' con engine_version='${var.db_engine_version}' no válida. Versiones soportadas: mysql=[5.7, 8.0, 8.4], mariadb=[10.4, 10.5, 10.6, 10.11, 11.4], postgres=[12-17]."
    }
  }
}

# ===========================================================================
# Módulo público: RDS (terraform-aws-modules/rds/aws)
# ===========================================================================

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.0"

  identifier = "${var.project_name}-db"

  # --- Configuración del motor (delegada al usuario) ---
  engine            = var.db_engine
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage

  # --- Base de datos y usuario ---
  db_name  = var.db_name
  username = var.db_username
  port     = var.db_port

  # Contraseña gestionada automáticamente por RDS en Secrets Manager
  manage_master_user_password = true

  # ─── PARÁMETROS HARDCODED DE CUMPLIMIENTO ───
  # El usuario del wrapper NO puede desactivar estos valores.
  # Esto garantiza que todas las bases de datos de la empresa cumplan
  # los estándares de seguridad mínimos. Para destruir el lab, el README
  # (sección 8) explica el procedimiento manual: cambiar el flag a false,
  # aplicar, y entonces destruir. Es intencional — fuerza una decisión
  # consciente al borrar datos críticos.
  storage_encrypted   = true  # Cifrado en reposo obligatorio
  deletion_protection = true  # Protección contra borrado accidental
  publicly_accessible = false # Sin acceso público NUNCA

  # ─── OUTPUTS ENCADENADOS DEL MÓDULO VPC ───
  # El vpc_id y las subredes generadas por el módulo de VPC se pasan
  # directamente como entradas al módulo de RDS.
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  subnet_ids             = module.vpc.database_subnets

  # --- Otros parámetros (también hardcoded por política corporativa) ---
  multi_az = var.multi_az

  # ⚠ skip_final_snapshot = true: al destruir la BD, RDS NO crea un
  # snapshot final. Está pensado para entornos de laboratorio donde la
  # BD es desechable. EN PRODUCCIÓN ponlo a `false` (o, mejor, exponlo
  # como variable y déjalo a false por defecto): perder datos al destruir
  # sin querer es irrecuperable.
  skip_final_snapshot = true

  # backup_retention_period = 7: snapshots diarios automáticos durante
  # 7 días (compromiso entre coste y RPO razonable). RDS permite 0–35.
  # Hardcoded en el wrapper para garantizar que NINGUNA BD del estándar
  # corporativo se quede sin backups por olvido del equipo de producto.
  backup_retention_period = 7

  # Family para parameter group (derivado del motor)
  family = "${var.db_engine}${var.db_engine_version}"

  # Major engine version para option group
  major_engine_version = var.db_engine_version

  tags = local.effective_tags
}
