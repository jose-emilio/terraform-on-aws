# Consulta la identidad activa. En LocalStack devuelve cuenta "000000000000".
data "aws_caller_identity" "current" {}

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

# LocalStack no dispone de catálogo de AMIs, por lo que no es posible usar
# el data source aws_ami. Se usa un ID ficticio como sustituto.
# create_before_destroy sigue activo para practicar el meta-argumento lifecycle.
resource "aws_launch_template" "app" {
  name_prefix   = "${var.app_name}-"
  image_id      = "ami-00000000000000000" # AMI ficticia para LocalStack
  instance_type = "t4g.small"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.app_name
  }
}
