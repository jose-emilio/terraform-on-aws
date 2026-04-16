# ── Lectura del estado remoto del proyecto network/ ───────────────────────────
#
# data "terraform_remote_state" lee los outputs de otro proyecto de Terraform
# directamente desde su fichero de estado en S3, sin necesidad de parametros
# manuales ni de re-desplegar la capa de red.
#
# La clave (key) debe coincidir exactamente con la que usa network/ en su
# aws.s3.tfbackend: "lab40/network/terraform.tfstate".
#
# Acceso a los outputs: data.terraform_remote_state.network.outputs.<nombre>
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "lab40/network/terraform.tfstate"
    region = var.region
  }
}

# ── Security Group de la aplicacion ───────────────────────────────────────────
# El vpc_id proviene del estado remoto del proyecto network/.
# Si el VPC cambia (raro pero posible en rotaciones de infraestructura),
# el proximo plan de este proyecto detectara automaticamente el nuevo valor.
resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "Trafico HTTP/HTTPS de entrada para la capa de aplicacion"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  tags = {
    Name      = "${var.project}-app-sg"
    Project   = var.project
    ManagedBy = "terraform"
    Layer     = "app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.app.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP publico"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.app.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS publico"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Todo el trafico saliente"
}

# ── SSM: informacion de red consumida desde el estado remoto ──────────────────
# Almacenar los valores de red en SSM permite que otras herramientas
# (scripts de despliegue, pipelines de CI/CD) los consuman sin acceso
# directo al estado de Terraform.
resource "aws_ssm_parameter" "vpc_id" {
  name        = "/${var.project}/app/network/vpc-id"
  type        = "String"
  value       = data.terraform_remote_state.network.outputs.vpc_id
  description = "ID del VPC — propagado desde el estado remoto de network/"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Source    = "terraform_remote_state"
  }
}

resource "aws_ssm_parameter" "public_subnet_id" {
  name        = "/${var.project}/app/network/public-subnet-id"
  type        = "String"
  value       = data.terraform_remote_state.network.outputs.public_subnet_id
  description = "ID de la subnet publica — propagado desde el estado remoto de network/"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Source    = "terraform_remote_state"
  }
}

resource "aws_ssm_parameter" "vpc_cidr" {
  name        = "/${var.project}/app/network/vpc-cidr"
  type        = "String"
  value       = data.terraform_remote_state.network.outputs.vpc_cidr
  description = "CIDR del VPC — propagado desde el estado remoto de network/"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Source    = "terraform_remote_state"
  }
}
