# ═══════════════════════════════════════════════════════════════════════════════
# CloudWatch Log Group — Destino centralizado de los VPC Flow Logs
# ═══════════════════════════════════════════════════════════════════════════════
#
# Los VPC Flow Logs capturan metadatos de cada conexión IP que pasa por las
# interfaces de red de la VPC: dirección origen/destino, puertos, protocolo,
# bytes transferidos y si la conexión fue ACEPTADA o RECHAZADA.
#
# Solo se captura el tráfico REJECT (denegado por Security Groups o NACLs).
# Este subconjunto es el más valioso para la seguridad: revela escaneos de
# puertos, intentos de acceso no autorizados y reglas de firewall mal configuradas.
#
# El log group recibe los registros de flujo del agente de VPC Flow Logs,
# que escribe un log stream por interfaz de red (ENI).

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/${var.project}/vpc-flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Rol para que VPC Flow Logs escriba en CloudWatch
# ═══════════════════════════════════════════════════════════════════════════════
#
# El servicio vpc-flow-logs.amazonaws.com necesita asumir este rol para poder
# llamar a la API de CloudWatch Logs y escribir los registros de flujo.
#
# La condición aws:SourceAccount en la política de confianza previene el
# "confused deputy problem": sin ella, otro servicio de otra cuenta podría
# crear un flow log apuntando a este rol para escribir en nuestro log group.

resource "aws_iam_role" "flow_logs" {
  name = "${var.project}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
        }
      }
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.project}-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      # Restringimos el acceso solo al log group de flow logs, no a todos los
      # log groups de la cuenta. El wildcard :* es necesario para cubrir
      # los log streams creados dinámicamente por ENI (uno por interfaz).
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

# ═══════════════════════════════════════════════════════════════════════════════
# VPC Flow Log — Captura el tráfico REJECT de la ENI de la instancia EC2
# ═══════════════════════════════════════════════════════════════════════════════
#
# A diferencia de monitorizar toda una VPC, este flow log apunta a la ENI
# primaria de la instancia generadora de tráfico.
#
# traffic_type = "REJECT" captura únicamente las conexiones bloqueadas por
# Security Groups o NACLs. Este subconjunto es el más valioso para detección
# de amenazas: revela escaneos de puertos, intentos de acceso no autorizados
# y reglas de firewall mal configuradas, con un coste de almacenamiento mínimo.
#
# log_destination_type = "cloud-watch-logs" envía los registros en tiempo
# casi real (latencia de segundos). La alternativa "s3" es más económica
# pero tiene latencia de 5-15 minutos antes de que los objetos estén disponibles.

resource "aws_flow_log" "eni" {
  eni_id                   = aws_instance.traffic_gen.primary_network_interface_id
  traffic_type             = "REJECT"
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  max_aggregation_interval = 60

  tags = { Project = var.project, ManagedBy = "terraform" }
}
