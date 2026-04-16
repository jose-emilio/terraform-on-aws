resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "vpc-lab11"
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}

resource "aws_security_group" "app" {
  name        = "app-lab11"
  description = "Security group de la aplicacion (Lab11)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Permite todo el trafico saliente"
  }

  tags = {
    Name        = "app-lab11"
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}
