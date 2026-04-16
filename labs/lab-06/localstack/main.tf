# Consulta la identidad activa. En LocalStack devuelve cuenta "000000000000".
data "aws_caller_identity" "current" {}

# Obtiene el nombre de la región activa del provider.
data "aws_region" "current" {}

# En AWS real la VPC ya existe y se consulta directamente.
# En LocalStack no hay infraestructura previa, por lo que se crea aquí.
resource "aws_vpc" "production" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Env = var.target_env
  }
}

# Localiza la VPC por tag. depends_on es necesario porque Terraform no puede
# inferir la dependencia entre este data source y el recurso de arriba.
data "aws_vpc" "production" {
  filter {
    name   = "tag:Env"
    values = [var.target_env]
  }

  depends_on = [aws_vpc.production]
}

# Obtiene todas las subredes que pertenecen a la VPC encontrada.
data "aws_subnets" "production" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.production.id]
  }
}

# LocalStack no tiene instancias reales; aws_instances devolverá lista vacía.
# El reporte lo gestiona con el bloque %{if length == 0} de la plantilla.
data "aws_instances" "production" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.production.id]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

# LocalStack no incluye las políticas gestionadas de AWS por defecto.
# Se crea una política de prueba con el mismo nombre para que el data source
# tenga algo que resolver.
resource "aws_iam_policy" "read_only" {
  name = "ReadOnlyAccess"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["*"]
      Resource = ["*"]
    }]
  })
}

# Localiza la política IAM por nombre, igual que en el entorno real.
data "aws_iam_policy" "read_only" {
  name = "ReadOnlyAccess"

  depends_on = [aws_iam_policy.read_only]
}

# Lista todas las AZs disponibles en la región del provider.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Lista completa de nombres de AZs disponibles
  az_names = [for az in data.aws_availability_zones.available.names : az]

  # Lista filtrada: solo AZs cuyo sufijo está en var.primary_az_suffixes
  primary_az_names = [
    for az in data.aws_availability_zones.available.names : az
    if contains(var.primary_az_suffixes, substr(az, -1, 1))
  ]

  # Map de IPs privadas de las instancias en ejecución, indexado por ID
  instance_private_ips = {
    for i, id in data.aws_instances.production.ids :
    id => data.aws_instances.production.private_ips[i]
  }
}

# Genera el reporte de auditoría en disco usando la plantilla compartida.
resource "local_file" "audit_report" {
  filename = "${path.module}/audit_report.txt"
  content = templatefile("${path.module}/../audit_report.tftpl", {
    account_id       = data.aws_caller_identity.current.account_id
    caller_user_id   = data.aws_caller_identity.current.user_id
    region_name      = data.aws_region.current.name
    region_desc      = data.aws_region.current.description
    vpc_id           = data.aws_vpc.production.id
    vpc_cidr         = data.aws_vpc.production.cidr_block
    subnet_ids       = data.aws_subnets.production.ids
    instance_ips     = local.instance_private_ips
    az_names         = local.az_names
    primary_az_names = local.primary_az_names
    policy_arn       = data.aws_iam_policy.read_only.arn
  })
}
