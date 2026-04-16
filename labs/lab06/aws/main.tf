# Consulta la identidad activa: account_id, arn y user_id.
# Evita hardcodear el ID de cuenta en políticas IAM y otros recursos.
data "aws_caller_identity" "current" {}

# Obtiene el nombre y descripción de la región activa del provider.
# Útil para construir ARNs dinámicamente sin hardcodear la región.
data "aws_region" "current" {}

# Localiza la VPC de producción por tag sin conocer su ID de antemano.
# Si no existe ninguna VPC con ese tag, Terraform lanzará un error en el plan.
data "aws_vpc" "production" {
  filter {
    name   = "tag:Env"
    values = [var.target_env]
  }
}

# Obtiene todas las subredes que pertenecen a la VPC encontrada.
# El filtro por vpc-id garantiza que solo se devuelven subredes de esa VPC.
data "aws_subnets" "production" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.production.id]
  }
}

# Consulta las instancias EC2 en ejecución dentro de la VPC de producción.
# El filtro instance-state-name excluye instancias terminadas o detenidas.
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

# Localiza la política IAM gestionada ReadOnlyAccess por su nombre.
# Evita hardcodear el ARN completo, que varía entre particiones (aws, aws-cn, etc.).
data "aws_iam_policy" "read_only" {
  name = "ReadOnlyAccess"
}

# Lista todas las AZs disponibles en la región del provider.
# El filtro state = "available" excluye zonas en mantenimiento o degradadas.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Lista completa de nombres de AZs disponibles
  az_names = [for az in data.aws_availability_zones.available.names : az]

  # Lista filtrada: solo AZs cuyo sufijo está en var.primary_az_suffixes.
  # La cláusula if dentro de la expresión for actúa como un where en SQL.
  # Ejemplo con suffixes = ["a","b"]: ["us-east-1a", "us-east-1b"]
  primary_az_names = [
    for az in data.aws_availability_zones.available.names : az
    if contains(var.primary_az_suffixes, substr(az, -1, 1))
  ]

  # Map de IPs privadas de las instancias en ejecución, indexado por ID.
  # Resultado: { "i-0abc..." = "10.0.1.5", "i-0def..." = "10.0.2.8" }
  instance_private_ips = {
    for i, id in data.aws_instances.production.ids :
    id => data.aws_instances.production.private_ips[i]
  }
}

# Genera un archivo de reporte de auditoría en disco combinando todos los
# data sources mediante una plantilla. Conecta templatefile() con la auditoría.
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
