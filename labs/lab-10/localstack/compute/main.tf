# Capa de Computo (LocalStack) — lee la VPC de la capa de red via terraform_remote_state.
#
# En LocalStack se usa el backend "local" en lugar de S3 para simplificar la configuración.
# El concepto es idéntico al de AWS real: terraform_remote_state lee el estado de otra
# capa sin acceso directo a sus recursos ni a su configuración interna.
#
# Aislamiento de fallos (blast radius):
# - Un error en esta capa no toca el archivo terraform.tfstate de la capa de red.
# - Si este proyecto se destruye por completo, la VPC sigue existiendo en LocalStack.

data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    path = var.network_state_path
  }
}

locals {
  vpc_id    = data.terraform_remote_state.network.outputs.vpc_id
  subnet_id = data.terraform_remote_state.network.outputs.subnet_id
}

# Security group asociado a la VPC de la capa de red.
# Referencia vpc_id sin conocer cómo se creó ni qué otros recursos existen en red.
resource "aws_security_group" "app" {
  name        = "app-lab10"
  description = "Security group de la capa de computo (Lab10)"
  vpc_id      = local.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "app-lab10"
    ManagedBy = "terraform"
    Layer     = "compute"
  }
}
