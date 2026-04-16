# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# VPCs — una por cada entrada en var.vpc_config
# ══════════════════════════════════════════════════════════════════════════════

resource "aws_vpc" "this" {
  for_each = local.vpcs_map

  cidr_block           = each.value.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project}-vpc-${each.key}"
    VpcName = each.key
  }

  lifecycle {
    # ── ignore_changes para tags gestionadas por AWS ──────────────────────────
    # AWS Organizations, Security Hub, AWS Config y otras herramientas de
    # gobernanza anaden automaticamente tags a los recursos (por ejemplo,
    # "aws:cloudformation:stack-name", "CreatedBy", "aws:organizations:*").
    # Sin ignore_changes, el siguiente terraform plan detectaria esas tags
    # como drift y las eliminaria, rompiendo las politicas de gobernanza.
    #
    # ignore_changes acepta una lista de atributos o subatributos.
    # La sintaxis tags["clave"] permite ignorar tags individuales sin
    # ignorar el bloque tags completo (lo que ocultaria cambios legitimos).
    ignore_changes = [
      tags["CreatedBy"],
      tags["aws:cloudformation:stack-name"],
      tags["aws:organizations:delegated-administrator"],
    ]
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# SUBREDES — Flatten Pattern + merge() de etiquetas
#
# local.subnets_map contiene una entrada por cada subred de todos los VPCs,
# con clave compuesta "vpc_key/subnet_key". Esto permite crear todas las
# subredes de todos los VPCs en un unico bloque resource con for_each,
# en lugar de tener un bloque por VPC.
# ══════════════════════════════════════════════════════════════════════════════

resource "aws_subnet" "this" {
  for_each = local.subnets_map

  vpc_id                  = aws_vpc.this[each.value.vpc_key].id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = each.value.public

  # merge() — las etiquetas resultantes (calculadas en locals.tf) fusionan
  # las etiquetas de departamento con las de identificacion del recurso.
  # Las etiquetas corporativas llegan automaticamente via default_tags.
  tags = local.subnet_tags[each.key]

  lifecycle {
    # El mismo patron que en aws_vpc.this: ignorar tags que AWS o herramientas
    # de gobernanza puedan anadir automaticamente sobre las subredes.
    ignore_changes = [
      tags["CreatedBy"],
      tags["aws:cloudformation:stack-name"],
      tags["kubernetes.io/role/elb"],           # anadida por EKS para ALBs
      tags["kubernetes.io/role/internal-elb"],  # anadida por EKS para NLBs internos
    ]
  }
}

# ── Internet Gateway (solo para VPCs con subredes publicas) ───────────────────
resource "aws_internet_gateway" "this" {
  for_each = local.vpcs_with_public_subnets

  vpc_id = aws_vpc.this[each.key].id

  tags = {
    Name = "${var.project}-igw-${each.key}"
  }
}

# ── Route tables publicas y asociaciones ──────────────────────────────────────
# Necesarias para que el bloque check {} pueda verificar via data source
# que las subredes publicas tienen ruta a Internet.
resource "aws_route_table" "public" {
  for_each = local.vpcs_with_public_subnets

  vpc_id = aws_vpc.this[each.key].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[each.key].id
  }

  tags = {
    Name = "${var.project}-rt-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets_map

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public[each.value.vpc_key].id
}

# ══════════════════════════════════════════════════════════════════════════════
# INSTANCIA DE MONITOREO — precondition + postcondition + optional()
#
# Esta instancia solo se crea cuando monitoring_config.enabled = true.
# Demuestra dos mecanismos de validacion en runtime:
#
#   precondition:  se evalua ANTES de crear el recurso (durante el plan).
#                  Si falla, el plan se aborta con un mensaje descriptivo.
#                  Util para validar configuraciones antes de gastar tiempo
#                  o dinero en un apply que va a fallar.
#
#   postcondition: se evalua DESPUES de crear el recurso (durante el apply).
#                  Si falla, Terraform marca el recurso como tainted y aborta.
#                  Util para verificar invariantes que AWS debe garantizar
#                  pero que quieres comprobar explicitamente.
# ══════════════════════════════════════════════════════════════════════════════

resource "aws_security_group" "monitoring" {
  count = var.monitoring_config.enabled ? 1 : 0

  name        = "${var.project}-monitoring-sg"
  description = "Trafico de salida para la instancia de monitoreo"
  vpc_id      = aws_vpc.this["networking"].id

  tags = {
    Name = "${var.project}-monitoring-sg"
    Role = "monitoring"
  }
}

resource "aws_vpc_security_group_egress_rule" "monitoring_all" {
  count = var.monitoring_config.enabled ? 1 : 0

  security_group_id = aws_security_group.monitoring[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Todo el trafico saliente (actualizaciones, metricas)"
}

resource "aws_instance" "monitoring" {
  count = var.monitoring_config.enabled ? 1 : 0

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.monitoring_config.instance_type
  subnet_id                   = aws_subnet.this["networking/public-a"].id
  vpc_security_group_ids      = [aws_security_group.monitoring[0].id]
  associate_public_ip_address = var.monitoring_config.associate_public_ip

  root_block_device {
    volume_size = var.monitoring_config.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name = "${var.project}-monitoring"
    Role = "monitoring"
  }

  lifecycle {
    # ── precondition ─────────────────────────────────────────────────────────
    # Se evalua durante el PLAN, antes de que Terraform intente crear o
    # modificar este recurso. Si la condicion es false, el plan falla
    # inmediatamente con el mensaje de error definido.
    #
    # Caso de uso: el equipo de seguridad define una lista de AZs autorizadas
    # para despliegues de produccion. Desplegar en una AZ no autorizada
    # puede incumplir requisitos de residencia de datos o de SLA.
    #
    # self.availability_zone no esta disponible en precondition porque el
    # recurso aun no existe — usamos la variable directamente.
    precondition {
      condition = contains(
        var.monitoring_config.allowed_azs,
        var.monitoring_config.availability_zone
      )
      error_message = <<-EOT
        La zona de disponibilidad '${var.monitoring_config.availability_zone}'
        no esta en la lista de zonas autorizadas para este entorno:
        ${jsonencode(var.monitoring_config.allowed_azs)}.
        Actualiza monitoring_config.availability_zone con un valor permitido.
      EOT
    }

    # ── postcondition ─────────────────────────────────────────────────────────
    # Se evalua despues de que AWS crea el recurso y Terraform recibe
    # su estado actual. Si la condicion es false, Terraform marca el recurso
    # como tainted y aborta el apply.
    #
    # Caso de uso: la instancia de monitoreo necesita IP publica para que
    # los agentes externos puedan reportar metricas. Si AWS no asigna la IP
    # (por ejemplo, la subnet no tiene auto-assign IP y associate_public_ip
    # no funciono como esperabamos), queremos detectarlo inmediatamente en
    # lugar de descubrirlo horas despues cuando los dashboards dejen de
    # actualizarse.
    #
    # self referencia el recurso recien creado — todos sus atributos
    # estan disponibles aqui, incluidos los calculados por AWS.
    postcondition {
      condition     = self.public_ip != null && self.public_ip != ""
      error_message = <<-EOT
        La instancia de monitoreo ${self.id} no tiene direccion IP publica
        asignada. Verifica que:
          - associate_public_ip_address = true en monitoring_config
          - La subnet 'networking/public-a' tiene map_public_ip_on_launch = true
          - El VPC 'networking' tiene enable_dns_hostnames = true
      EOT
    }
  }
}

# ── SNS + CloudWatch Alarm (solo si se proporciona alarm_email) ───────────────
# Usa local.monitoring_alarm_enabled (calculado con can() en locals.tf)
# en lugar de evaluar la condicion directamente en cada count.
# Ventaja: la logica de decision esta centralizada en un unico local;
# si las condiciones cambian (por ejemplo, se añade un nuevo requisito),
# solo hay que modificar locals.tf, no cada recurso individualmente.

resource "aws_sns_topic" "monitoring_alerts" {
  count = local.monitoring_alarm_enabled ? 1 : 0
  name  = "${var.project}-monitoring-alerts"

  tags = {
    Name = "${var.project}-monitoring-alerts"
    Role = "monitoring"
  }
}

resource "aws_sns_topic_subscription" "monitoring_email" {
  count     = local.monitoring_alarm_enabled ? 1 : 0
  topic_arn = aws_sns_topic.monitoring_alerts[0].arn
  protocol  = "email"
  # try() — acceso seguro: si alarm_email fuera null aqui (no deberia porque
  # monitoring_alarm_enabled ya lo verifica), devuelve "" en lugar de error.
  endpoint  = try(local.monitoring_alarm_email, "")
}

resource "aws_cloudwatch_metric_alarm" "monitoring_cpu" {
  count = local.monitoring_alarm_enabled ? 1 : 0

  alarm_name          = "${var.project}-monitoring-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "CPU de la instancia de monitoreo supera el 80% durante 10 minutos"

  dimensions = {
    InstanceId = aws_instance.monitoring[0].id
  }

  alarm_actions = [aws_sns_topic.monitoring_alerts[0].arn]

  tags = {
    Name = "${var.project}-monitoring-cpu-high"
    Role = "monitoring"
  }
}

# ══════════════════════════════════════════════════════════════════════════════
# CHECK BLOCK — verificacion post-apply de conectividad de subredes publicas
#
# check {} es diferente de postcondition:
#   - Se evalua al FINAL del apply, despues de que TODOS los recursos existen.
#   - Si falla, emite una ADVERTENCIA pero NO aborta el apply ni taintea nada.
#   - Tiene acceso a data sources propios declarados dentro del bloque.
#   - Util para healthchecks E2E que no deben bloquear el despliegue pero
#     si deben avisar al operador de que algo no esta como se espera.
#
# Caso de uso: verificar que la subred publica principal tiene efectivamente
# una ruta por defecto (0.0.0.0/0) hacia el Internet Gateway. Esto podria
# fallar si alguien eliminara manualmente la ruta (drift) o si la asociacion
# de route table fallara silenciosamente.
# ══════════════════════════════════════════════════════════════════════════════

check "public_subnet_has_internet_route" {
  # El data source dentro de check {} se evalua al final del apply.
  # Solo puede haber UN data source por bloque check (sin for_each).
  # Inspeccionamos la subred principal: networking/public-a.
  data "aws_route_table" "networking_public_a" {
    subnet_id = aws_subnet.this["networking/public-a"].id
  }

  assert {
    condition = anytrue([
      for route in data.aws_route_table.networking_public_a.routes :
      route.cidr_block == "0.0.0.0/0" && route.gateway_id != null && route.gateway_id != ""
    ])
    error_message = <<-EOT
      La subred 'networking/public-a' no tiene ruta por defecto (0.0.0.0/0)
      hacia un Internet Gateway. Las instancias en esta subred no podran
      alcanzar Internet. Verifica aws_route_table.public["networking"] y
      aws_route_table_association.public["networking/public-a"].
    EOT
  }
}
