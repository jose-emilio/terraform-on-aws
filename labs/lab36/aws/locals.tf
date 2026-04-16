locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
  public_subnets = {
    "${var.region}a" = "10.32.10.0/24"
    "${var.region}b" = "10.32.11.0/24"
  }
  private_subnets = {
    "${var.region}a" = "10.32.1.0/24"
    "${var.region}b" = "10.32.2.0/24"
  }
}

data "aws_caller_identity" "current" {}

# AMI Amazon Linux 2023 ARM64 para instancias t4g (Graviton)
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}
