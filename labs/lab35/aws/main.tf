# ── Locales y datos de cuenta ─────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
  public_subnets = {
    "${var.region}a" = "10.31.10.0/24"
    "${var.region}b" = "10.31.11.0/24"
  }
  private_subnets = {
    "${var.region}a" = "10.31.1.0/24"
    "${var.region}b" = "10.31.2.0/24"
    "${var.region}c" = "10.31.3.0/24"
  }
}

data "aws_caller_identity" "current" {}

# ── VPC y subnets privadas ────────────────────────────────────────────────────
#
# RDS Multi-AZ requiere al menos dos subnets en AZs distintas.
# Se despliegan tres para dar mas opciones de placement al motor RDS.
# Las subnets son privadas: RDS no debe ser accesible desde internet.

resource "aws_vpc" "main" {
  cidr_block           = "10.31.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.project}-vpc" })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project}-igw" })
}

# ── Subnets publicas (ALB y NAT) ──────────────────────────────────────────────

resource "aws_subnet" "public" {
  for_each                = local.public_subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${var.project}-public-${each.key}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.tags, { Name = "${var.project}-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ── Subnets privadas (RDS y EC2 app) ──────────────────────────────────────────

resource "aws_subnet" "private" {
  for_each          = local.private_subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key
  tags              = merge(local.tags, { Name = "${var.project}-private-${each.key}" })
}

# ── NAT Gateway (salida a internet para EC2 en subnet privada) ────────────────
#
# La instancia EC2 esta en una subnet privada para no exponerse directamente.
# Necesita salida a internet para descargar paquetes en el user_data y
# para llamar a la API de Secrets Manager (alternativa: VPC endpoint).

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags       = merge(local.tags, { Name = "${var.project}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["${var.region}a"].id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(local.tags, { Name = "${var.project}-nat" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = merge(local.tags, { Name = "${var.project}-private-rt" })
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ── DB Subnet Group ───────────────────────────────────────────────────────────
#
# aws_db_subnet_group es el "mapa de red" de RDS: le indica al motor en qué
# subnets (y por tanto en qué AZs) puede colocar la instancia primaria y la
# standby de Multi-AZ. Debe incluir subnets en al menos dos AZs distintas.
# Todos los despliegues de RDS en VPC requieren un subnet group.

resource "aws_db_subnet_group" "main" {
  name        = "${var.project}-subnet-group"
  description = "Subnets privadas para RDS PostgreSQL Multi-AZ"
  subnet_ids  = [for s in aws_subnet.private : s.id]
  tags        = local.tags
}

# ── Security Group RDS ────────────────────────────────────────────────────────
#
# Solo se permite el puerto PostgreSQL (5432) desde dentro de la VPC.
# En produccion restringe aun mas usando el SG de las instancias de aplicacion
# como source_security_group_id en lugar del CIDR de la VPC.

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds"
  description = "Permite PostgreSQL TCP 5432 desde dentro de la VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL desde la VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-rds" })
}

# ── KMS CMK para RDS ──────────────────────────────────────────────────────────
#
# Una Customer Managed Key propia permite rotar el material criptografico,
# auditar cada operacion de cifrado en CloudTrail y revocar el acceso
# deshabilitando la clave — imposible con la clave gestionada por AWS (aws/rds).

resource "aws_kms_key" "rds" {
  description             = "CMK para cifrado en reposo de RDS y Secrets Manager"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.tags
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.project}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# ── Contraseña maestra (random) ───────────────────────────────────────────────
#
# random_password genera una contraseña criptograficamente segura localmente,
# sin llamadas a AWS. Se almacena en el estado de Terraform (cifrado en S3)
# y en Secrets Manager. Con override_special se evitan caracteres que pueden
# causar problemas en cadenas de conexion PostgreSQL (@, /, \, comillas).

resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}:?"
}

# ── Secrets Manager ───────────────────────────────────────────────────────────
#
# Almacenar la contraseña en Secrets Manager en lugar de en variables de entorno
# o ficheros de configuracion elimina los secretos en texto plano. Las
# aplicaciones recuperan el secreto en tiempo de ejecucion via SDK o VPC endpoint,
# sin necesidad de reiniciar para rotar credenciales.
#
# El secreto se cifra con la CMK propia para poder auditar y revocar el acceso.

resource "aws_secretsmanager_secret" "db_password" {
  name        = "${var.project}/db/master-password"
  description = "Credenciales del usuario maestro de RDS PostgreSQL"
  kms_key_id  = aws_kms_key.rds.arn
  tags        = local.tags
}

# La version del secreto se crea despues de que RDS este disponible (depends_on).
# El host y el puerto se incluyen en el secreto para que las aplicaciones
# puedan construir la cadena de conexion recuperando un unico secreto.

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = aws_db_instance.main.db_name
    username = aws_db_instance.main.username
    password = random_password.master.result
  })

  depends_on = [aws_db_instance.main]
}

# ── Rotacion automatica de secretos ──────────────────────────────────────────
#
# aws_secretsmanager_secret_rotation requiere una Lambda de rotacion.
# AWS proporciona una Lambda preconfigurada para RDS PostgreSQL disponible en
# Serverless Application Repository. Para desplegarla:
#
#   aws serverlessrepo create-cloud-formation-change-set \
#     --application-id arn:aws:serverlessrepo:us-east-1:297356227824:applications/SecretsManagerRDSPostgreSQLRotationSingleUser \
#     --stack-name secrets-rotation-pg
#
# Una vez desplegada, pasa su ARN con:
#   terraform apply -var="rotation_lambda_arn=arn:aws:lambda:..."
#
# Si rotation_lambda_arn esta vacio, la rotacion no se configura.

resource "aws_secretsmanager_secret_rotation" "db_password" {
  count               = var.rotation_lambda_arn != "" ? 1 : 0
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = var.rotation_lambda_arn
  rotate_immediately  = false

  rotation_rules {
    automatically_after_days = 30
  }
}

# ── Parameter Group ───────────────────────────────────────────────────────────
#
# Un parameter group es un conjunto de parametros del motor de base de datos.
# Usar uno propio (en lugar del default) permite:
#   - Modificar parametros sin tiempo de inactividad (dynamic parameters).
#   - Forzar SSL en todas las conexiones (rds.force_ssl = 1): cualquier cliente
#     que intente conectar sin SSL recibe un error de autenticacion.
#   - Controlar log_connections, log_min_duration_statement, etc.
#
# La familia "postgres15" cubre todas las versiones 15.x.

resource "aws_db_parameter_group" "main" {
  name        = "${var.project}-pg15"
  family      = "postgres15"
  description = "Parametros personalizados para RDS PostgreSQL 15 - Lab35"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  tags = local.tags
}

# ── Instancia RDS principal (Multi-AZ) ───────────────────────────────────────
#
# multi_az = true despliega automaticamente una instancia standby en una AZ
# distinta a la primaria. El failover es automatico (< 60 segundos) y
# transparente para la aplicacion: el endpoint DNS no cambia.
#
# max_allocated_storage activa el autoscaling de almacenamiento: RDS aumenta
# el storage automaticamente hasta ese limite cuando queda menos del 10% libre,
# sin tiempo de inactividad y sin intervencion manual.
#
# iam_database_authentication_enabled permite autenticacion con tokens IAM
# efimeros en lugar de contrasenas estaticas. El token se genera con
# `aws rds generate-db-auth-token` y caduca a los 15 minutos.
#
# backup_retention_period > 0 es obligatorio para crear read replicas y
# permite restauracion a un punto en el tiempo (PITR).

resource "aws_db_instance" "main" {
  identifier = "${var.project}-main"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.master.result

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  iam_database_authentication_enabled = true

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection = false # true en produccion
  skip_final_snapshot = true  # false en produccion con final_snapshot_identifier

  tags = merge(local.tags, { Name = "${var.project}-main", Role = "primary" })
}

# ── Read Replica ──────────────────────────────────────────────────────────────
#
# La read replica descarga las consultas de solo lectura de la instancia
# principal (reportes, analisis, busquedas). La replicacion es asincrona:
# puede haber un lag de milisegundos entre la escritura en la primaria y
# la visibilidad en la replica.
#
# Con replicate_source_db se heredan automaticamente: engine, db_name,
# usuario, contrasena, parameter_group y subnet_group.
# Solo se especifican los atributos que difieren de la primaria.
#
# availability_zone distinta a la primaria maximiza la separacion de fallos:
# una interrupcion en us-east-1a no afecta a la replica en us-east-1c.

resource "aws_db_instance" "replica" {
  identifier          = "${var.project}-replica"
  replicate_source_db = aws_db_instance.main.identifier
  instance_class      = var.db_instance_class
  availability_zone   = "${var.region}c"

  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  publicly_accessible = false
  skip_final_snapshot = true

  iam_database_authentication_enabled = true

  tags = merge(local.tags, { Name = "${var.project}-replica", Role = "read-replica" })
}

# ── S3: artefactos de la aplicacion ──────────────────────────────────────────
#
# El codigo de la aplicacion Flask (app.py) se almacena en S3 en lugar de
# embeberlo en el user_data. Esto evita el limite de 16 KB de EC2 user_data
# y permite actualizar la app subiendo una nueva version a S3 y lanzando
# un instance refresh en el ASG, sin modificar el Launch Template.

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
  source = "${path.module}/app.py"
  etag   = filemd5("${path.module}/app.py")
  tags   = local.tags
}

# ── AMI Amazon Linux 2023 ────────────────────────────────────────────────────

# AMI Amazon Linux 2023 ARM64 para instancias t4g (Graviton2)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# ── Security Groups de la capa web ────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Trafico HTTP publico hacia el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-alb" })
}

resource "aws_security_group" "app" {
  name        = "${var.project}-app"
  description = "Trafico desde el ALB hacia la instancia EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP desde el ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-app" })
}

# Permite a RDS recibir conexiones desde la instancia EC2
resource "aws_security_group_rule" "rds_from_app" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.app.id
  description              = "PostgreSQL desde la instancia de aplicacion"
}

# ── IAM Role para EC2: SSM + Secrets Manager + RDS IAM Auth ──────────────────
#
# La instancia usa tres mecanismos:
#   - SSM: acceso sin SSH a la instancia desde la consola AWS.
#   - Secrets Manager: recupera la contrasena maestra para el bootstrap inicial.
#   - rds-db:connect: demostracion de autenticacion IAM en los retos.

resource "aws_iam_role" "app" {
  name        = "${var.project}-app-role"
  description = "Rol de la aplicacion: SSM + Secrets Manager + RDS IAM Auth"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-app-profile"
  role = aws_iam_role.app.name
}

# ── ALB ───────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id]
  tags               = local.tags
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.project}-tg"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 0

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ── Launch Template ───────────────────────────────────────────────────────────
#
# El Launch Template define la configuracion de cada instancia que el ASG
# arrancara. Centralizar aqui los parametros permite actualizarlos sin
# reemplazar el ASG: basta con publicar una nueva version del template y
# lanzar un instance refresh.
#
# user_data ejecuta el bootstrap completo en cada instancia:
#   1. Instala dependencias (Flask, psycopg2, boto3).
#   2. Recupera credenciales de Secrets Manager.
#   3. Espera a que RDS acepte conexiones.
#   4. Puebla la BD si aun no existe (ON CONFLICT DO NOTHING).
#   5. Lanza el servicio systemd con la aplicacion Flask.

resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-app-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.app_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_tokens = "required"
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    secret_name    = aws_secretsmanager_secret.db_password.name
    replica_host   = aws_db_instance.replica.address
    replica_port   = aws_db_instance.replica.port
    db_name        = var.db_name
    region         = var.region
    project        = var.project
    bucket_name    = aws_s3_bucket.app_artifacts.bucket
    db_instance_id = aws_db_instance.main.identifier
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${var.project}-app" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_db_instance.main,
    aws_db_instance.replica,
    aws_nat_gateway.main,
    aws_secretsmanager_secret_version.db_password,
    aws_s3_object.app_py,
  ]
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────
#
# El ASG mantiene entre min_size y max_size instancias distribuidas entre las
# subnets privadas de las dos AZs. La integracion con el ALB (target_group_arns)
# registra y desregistra instancias automaticamente.
#
# health_check_type = "ELB": el ASG utiliza los health checks del ALB en lugar
# de los de EC2 (que solo detectan si la instancia esta encendida). Asi el ASG
# reemplaza instancias que el ALB marca como unhealthy (/health devuelve != 200).
#
# health_check_grace_period = 600: da 10 minutos a cada instancia para completar
# el user_data (instalar paquetes, esperar RDS, iniciar Flask) antes de que el
# ASG empiece a evaluar su salud.
#
# instance_refresh: cuando el Launch Template cambia (nueva AMI, nuevo user_data),
# el ASG reemplaza las instancias en rodillo sin tiempo de inactividad.

resource "aws_autoscaling_group" "app" {
  name                      = "${var.project}-asg"
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  vpc_zone_identifier       = [for k, s in aws_subnet.private : s.id if k != "${var.region}c"]
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 600

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-app"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [
    aws_db_instance.main,
    aws_db_instance.replica,
    aws_nat_gateway.main,
    aws_secretsmanager_secret_version.db_password,
  ]
}

# ── Auto Scaling Policy ───────────────────────────────────────────────────────
#
# Target Tracking: el ASG ajusta automaticamente el numero de instancias para
# mantener la CPU media en el 60 %. Si la carga sube, escala hacia arriba;
# si baja, elimina instancias hasta min_size. AWS gestiona el cooldown.

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.project}-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

# ── Politica IAM para autenticacion con base de datos ────────────────────────
#
# La autenticacion IAM requiere:
#   1. iam_database_authentication_enabled = true en la instancia RDS.
#   2. Una politica IAM que conceda rds-db:connect al resource_id especifico.
#
# El resource_id (ej. db-ABCDE12345) difiere del identifier ("lab35-main").
# Se obtiene con: aws rds describe-db-instances --query '..DbiResourceId'

resource "aws_iam_policy" "rds_iam_auth" {
  name        = "${var.project}-rds-iam-auth"
  description = "Permite autenticacion IAM a RDS PostgreSQL sin contrasena estatica"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "RDSIAMAuth"
      Effect = "Allow"
      Action = "rds-db:connect"
      Resource = [
        "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/${var.db_username}",
        "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.replica.resource_id}/${var.db_username}"
      ]
    }]
  })

  tags = local.tags
}

# Permiso a Secrets Manager para que la instancia EC2 recupere las credenciales
resource "aws_iam_role_policy" "app_secrets" {
  name = "${var.project}-app-secrets"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db_password.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.rds.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.app_artifacts.arn}/*"
      },
      {
        Effect = "Allow"
        Action = ["rds:DescribeDBInstances", "rds:RebootDBInstance"]
        Resource = "arn:aws:rds:${var.region}:${data.aws_caller_identity.current.account_id}:db:${aws_db_instance.main.identifier}"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rds_iam_auth" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.rds_iam_auth.arn
}
