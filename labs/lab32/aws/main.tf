# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
  azs = ["${var.region}a", "${var.region}b"]
}

# ── Empaquetado del código fuente ─────────────────────────────────────────────

data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/src/function"
  output_path = "${path.module}/function.zip"
}

# ── Red ───────────────────────────────────────────────────────────────────────
#
# La VPC aloja dos tipos de subredes:
#   - Privadas (Lambda): sin ruta a internet — Lambda accede a recursos internos
#     de la VPC a través de su ENI (Elastic Network Interface).
#   - Públicas (ECS): ruta directa a través del Internet Gateway para que las
#     tareas Fargate puedan descargar imágenes de contenedor.

resource "aws_vpc" "main" {
  cidr_block           = "10.28.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.project}-vpc" })
}

# Subredes privadas — Lambda
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.28.0.0/16", 8, count.index + 1)
  availability_zone = local.azs[count.index]
  tags              = merge(local.tags, { Name = "${var.project}-private-${local.azs[count.index]}" })
}

# Subredes públicas — ECS (requiere IGW para descargar imágenes)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet("10.28.0.0/16", 8, count.index + 10)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${var.project}-public-${local.azs[count.index]}" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project}-igw" })
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
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Security Groups ───────────────────────────────────────────────────────────
#
# SG dedicado a Lambda: sin inbound (Lambda se invoca a través del servicio
# AWS, no mediante conexiones de red directas). Egress abierto para que Lambda
# pueda conectarse a recursos internos de la VPC como RDS o ElastiCache.

resource "aws_security_group" "lambda" {
  name        = "${var.project}-lambda-sg"
  description = "SG dedicado a la funcion Lambda - sin inbound, egress a la VPC"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Egress abierto para acceso a recursos de la VPC"
  }

  tags = merge(local.tags, { Name = "${var.project}-lambda-sg" })
}

# SG para las tareas ECS: permite tráfico HTTP entrante
resource "aws_security_group" "ecs" {
  name        = "${var.project}-ecs-sg"
  description = "SG para tareas ECS Fargate"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP publico"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-ecs-sg" })
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project}-function"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}"
  retention_in_days = 7
  tags              = local.tags
}

# ── IAM — Lambda ──────────────────────────────────────────────────────────────
#
# AWSLambdaVPCAccessExecutionRole es necesaria para que el servicio Lambda
# cree y elimine las ENIs en las subredes de la VPC.

resource "aws_iam_role" "lambda" {
  name = "${var.project}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${var.project}-lambda-role" })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Sin esta política, Terraform aplica correctamente pero Lambda falla al
# arrancar porque no puede crear la ENI en la subred privada.
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ── IAM — ECS ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ecs_execution" {
  name = "${var.project}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${var.project}-ecs-execution-role" })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── Lambda Function ───────────────────────────────────────────────────────────
#
# publish = true: cada terraform apply que cambia el código genera una nueva
# versión numerada e inmutable. Las versiones son necesarias para configurar
# Provisioned Concurrency en un qualifier específico.
#
# vpc_config: crea una ENI en cada combinación de subred + SG especificada.
# Lambda usará esas ENIs para comunicarse con recursos dentro de la VPC
# (RDS, ElastiCache, etc.) sin exponer esos recursos a internet.

resource "aws_lambda_function" "main" {
  function_name    = "${var.project}-function"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  runtime          = var.runtime
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.lambda.arn
  publish          = true
  timeout          = 30

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      APP_ENV     = var.app_env
      APP_PROJECT = var.project
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = merge(local.tags, { Name = "${var.project}-function" })
}

# ── Lambda Alias ──────────────────────────────────────────────────────────────
#
# El alias "live" apunta a la versión publicada más reciente.
# Provisioned Concurrency se configura sobre el alias (no sobre $LATEST),
# por lo que cualquier cliente que invoque el alias obtiene siempre una
# instancia pre-calentada.
#
# Cuando se publica una nueva versión, el alias avanza automáticamente
# (function_version = aws_lambda_function.main.version). Los clientes
# que invoquen el alias verán el nuevo código sin cambiar su integración.

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.main.function_name
  function_version = aws_lambda_function.main.version
}

# ── Provisioned Concurrency ───────────────────────────────────────────────────
#
# Mantiene var.provisioned_concurrency contenedores Lambda inicializados y
# listos para responder. El coste es proporcional al tiempo de reserva
# (no solo a las invocaciones), pero elimina los cold starts.
#
# Se aplica sobre el alias "live", no sobre la función directa, de modo que
# solo las invocaciones al alias (no a $LATEST) reciben la concurrencia
# aprovisionada.

resource "aws_lambda_provisioned_concurrency_config" "live" {
  function_name                  = aws_lambda_function.main.function_name
  qualifier                      = aws_lambda_alias.live.name
  provisioned_concurrent_executions = var.provisioned_concurrency
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
#
# containerInsights = "enabled" activa el monitoreo detallado a nivel de
# contenedor en CloudWatch: métricas de CPU, memoria, red y disco por tarea.
# Sin Container Insights, CloudWatch solo proporciona métricas a nivel de
# servicio (CPU/memoria agregadas).

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

# ── Capacity Providers — Estrategia Spot 3:1 ─────────────────────────────────
#
# La estrategia asigna 3 de cada 4 tareas a FARGATE_SPOT (hasta 70% más barato)
# y 1 de cada 4 a FARGATE On-Demand.
# base = 1 en FARGATE garantiza al menos 1 tarea On-Demand siempre activa,
# evitando que el servicio quede sin tareas si Spot no está disponible.

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ── ECS Task Definition ───────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([{
    name      = "app"
    image     = "public.ecr.aws/nginx/nginx:stable-alpine"
    essential = true
    portMappings = [{
      containerPort = 80
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])

  tags = local.tags
}

# ── ECS Service con Estrategia Spot ──────────────────────────────────────────
#
# La estrategia de capacity_provider_strategy del servicio sobreescribe la
# estrategia por defecto del cluster. Se repite aquí explícitamente para
# documentar la intención: 75% Spot, 25% On-Demand, al menos 1 On-Demand.
#
# Las tareas ECS corren en subredes públicas con assign_public_ip = true para
# poder descargar la imagen de contenedor desde public.ecr.aws sin NAT Gateway.

resource "aws_ecs_service" "app" {
  name                   = "${var.project}-service"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.app.arn
  desired_count          = var.ecs_desired_count
  wait_for_steady_state  = false

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
    base              = 0
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  tags = local.tags
}

# ── SNS Topic ─────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
  tags = local.tags
}

# Suscripción email opcional: solo se crea si alert_email no está vacío.
# AWS enviará un email de confirmación — el destinatario debe confirmar
# antes de recibir notificaciones.
resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── CloudWatch Alarm ──────────────────────────────────────────────────────────
#
# La alarma se activa si CPUUtilization del servicio ECS supera el 80%
# durante 2 periodos consecutivos de 60 segundos (2 minutos sostenidos).
# Requiere evaluation_periods = 2 para evitar falsos positivos por picos
# momentáneos de CPU al arrancar contenedores.

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name        = "${var.project}-ecs-cpu-high"
  alarm_description = "CPU del servicio ECS supera el 80% durante 2 periodos consecutivos"

  namespace   = "AWS/ECS"
  metric_name = "CPUUtilization"
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }

  period             = 60
  evaluation_periods = 2
  statistic          = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold          = 80
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}
