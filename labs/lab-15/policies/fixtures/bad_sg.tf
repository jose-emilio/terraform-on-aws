# Fixture de prueba — NO desplegar
# Demuestra que sg_no_public_ingress.rego detecta security groups permisivos

# SG con ingress IPv4 abierto → FAIL [sg-no-public-ingress]
resource "aws_security_group" "open_ipv4" {
  name = "open-ipv4"
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG con ingress IPv6 abierto → FAIL [sg-no-public-ingress-ipv6]
resource "aws_security_group" "open_ipv6" {
  name = "open-ipv6"
  ingress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    ipv6_cidr_blocks = ["::/0"]
  }
}

# aws_security_group_rule con ingress abierto → FAIL [sg-rule-no-public-ingress]
resource "aws_security_group_rule" "open_rule" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "sg-00000000"
}

# SG con ingress restringido → sin fallos (1 passed)
resource "aws_security_group" "restricted" {
  name = "restricted"
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }
}
