# Red principal. El CIDR se toma de la variable para evitar hardcoding.
resource "aws_vpc" "main" {
  cidr_block = var.network_config.cidr_block

  tags = {
    Name = var.network_config.name
    Env  = var.network_config.env
  }
}

# Dos subredes públicas en AZs distintas.
# cidrsubnet() divide el CIDR de la VPC automáticamente:
#   index 0 → 10.0.0.0/24 (us-east-1a)
#   index 1 → 10.0.1.0/24 (us-east-1b)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.network_config.cidr_block, 8, count.index)
  availability_zone = "us-east-1${["a", "b"][count.index]}"

  tags = {
    Name = "${var.network_config.name}-public-${count.index + 1}"
    Tier = "public"
  }
}

# Dos subredes privadas. Se usa netnum + 10 para dejar espacio entre rangos
# públicos y privados y facilitar la incorporación de nuevas subredes:
#   index 0 → 10.0.10.0/24 (us-east-1a)
#   index 1 → 10.0.11.0/24 (us-east-1b)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.network_config.cidr_block, 8, count.index + 10)
  availability_zone = "us-east-1${["a", "b"][count.index]}"

  tags = {
    Name = "${var.network_config.name}-private-${count.index + 1}"
    Tier = "private"
  }
}

# Security group con reglas de ingress generadas dinámicamente desde
# var.firewall_rules. Añadir o quitar puertos solo requiere modificar la variable.
resource "aws_security_group" "main" {
  name        = "${var.network_config.name}-sg"
  description = "Security group para ${var.network_config.name}"
  vpc_id      = aws_vpc.main.id

  # El bloque dynamic itera sobre cada objeto de var.firewall_rules
  # y genera un bloque ingress por cada uno
  dynamic "ingress" {
    for_each = var.firewall_rules
    content {
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = ingress.value.description
    }
  }

  # Permite todo el tráfico saliente (comportamiento estándar)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_config.name}-sg"
  }
}
