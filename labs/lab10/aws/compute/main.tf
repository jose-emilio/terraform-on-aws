# Capa de Cómputo — lee la VPC de la capa de red mediante terraform_remote_state.
#
# terraform_remote_state NO copia ni duplica recursos: accede al archivo de estado
# remoto de otro proyecto y expone sus outputs como atributos de solo lectura.
#
# Aislamiento de fallos (blast radius):
# - Un error en esta capa no toca el estado de la capa de red.
# - Si este proyecto se destruye por completo, la VPC sigue existiendo.
# - La capa de red puede desplegarse y modificarse de forma totalmente independiente.

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.network_state_bucket
    key    = var.network_state_key
    region = var.region
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
