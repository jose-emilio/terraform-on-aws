# Capa de Red — despliega la VPC base que comparten las capas superiores.
#
# Esta capa publica sus identificadores como outputs. Otras capas los consumen
# a través de terraform_remote_state sin necesidad de copiar ni hardcodear
# ningún valor. La capa de red ignora por completo lo que hacen sus consumidores.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "vpc-lab10"
    ManagedBy = "terraform"
    Layer     = "network"
  }
}

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, 1)

  tags = {
    Name      = "subnet-public-lab10"
    ManagedBy = "terraform"
    Layer     = "network"
  }
}
