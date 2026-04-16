# Consulta la identidad activa (cuenta, usuario/rol) sin crear ningún recurso.
# Se usa en outputs para auditoría del despliegue.
data "aws_caller_identity" "current" {}

# Busca dinámicamente la AMI de Amazon Linux 2023 más reciente para arm64.
# El filtro de arquitectura es obligatorio: las instancias t4g usan Graviton (ARM)
# y no son compatibles con AMIs x86_64.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# Crea un usuario IAM por cada entrada del map var.iam_users.
# for_each indexa cada instancia por nombre (each.key), lo que hace el estado
# más robusto que count: eliminar un usuario no reindexará los demás.
resource "aws_iam_user" "team" {
  for_each = var.iam_users

  name = each.key # nombre del usuario = clave del map

  tags = {
    Department = each.value.department  # metadatos del valor del map
    CostCenter = each.value.cost_center
    ManagedBy  = "terraform"
  }
}

# Launch template que referencia la AMI resuelta dinámicamente por el data source.
# create_before_destroy garantiza que ante cualquier reemplazo (cambio de AMI,
# tipo de instancia, etc.) el nuevo recurso exista antes de destruir el antiguo,
# evitando downtime en los Auto Scaling Groups que lo referencien.
resource "aws_launch_template" "app" {
  name_prefix   = "${var.app_name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t4g.small"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.app_name
  }
}
