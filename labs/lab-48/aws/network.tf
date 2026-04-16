# ═══════════════════════════════════════════════════════════════════════════════
# VPC — Red base del laboratorio
# ═══════════════════════════════════════════════════════════════════════════════
#
# VPC simple con dos subredes públicas en distintas AZs para que el Auto Scaling
# Group pueda distribuir instancias en múltiples zonas de disponibilidad.
# Multi-AZ es imprescindible para las Spot Instances: si AWS interrumpe las
# instancias en una AZ, el ASG lanza reemplazos en otra.

data "aws_availability_zones" "available" {
  state = "available"

  # Filtra únicamente las AZs estándar de la región. Sin este filtro el data
  # source también devuelve Local Zones y Wavelength Zones, que no soportan
  # todos los tipos de volumen (gp3) ni todos los tipos de instancia.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  # La tag Name se define en el recurso, no en default_tags, porque es única por recurso.
  # Las demás tags (Environment, Project, ManagedBy, CostCenter) las inyecta default_tags.
  tags = {
    Name = module.naming["vpc"].name
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = module.naming["igw"].name
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = count.index == 0 ? module.naming["sn_pub_a"].name : module.naming["sn_pub_b"].name
    # Etiqueta estándar para que el AWS Load Balancer Controller descubra la subred.
    # No es necesaria en este laboratorio, pero es buena práctica incluirla.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = module.naming["rt_pub"].name
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
