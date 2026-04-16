# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Grupo IAM de Desarrolladores ─────────────────────────────────────────────
#
# Un grupo agrupa usuarios con las mismas necesidades de acceso.
# Las políticas se adjuntan al grupo, no a los usuarios individuales,
# lo que simplifica la gestión y evita inconsistencias.

resource "aws_iam_group" "developers" {
  name = "${var.project}-developers"
  path = "/"
}

# Política inline del grupo: lectura de recursos EC2 e IAM.
# Con esta política, cualquier miembro del grupo puede inspeccionar la
# infraestructura sin poder modificarla.
resource "aws_iam_group_policy" "developers_read" {
  name  = "${var.project}-developers-read"
  group = aws_iam_group.developers.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EC2ReadOnly"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "ec2:Get*"]
        Resource = "*"
      },
      {
        Sid      = "IAMReadOnly"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*"]
        Resource = "*"
      },
      {
        Sid      = "STSCallerIdentity"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      }
    ]
  })
}

# ── Usuario IAM dev-01 ────────────────────────────────────────────────────────
#
# Terraform crea el objeto usuario pero no genera Access Keys.
# Las credenciales de acceso programático deben crearse manualmente en la
# consola o con la CLI de AWS para evitar almacenarlas en el estado de Terraform
# (el tfstate no está cifrado por defecto en disco local).
#
# force_destroy = true permite eliminar el usuario aunque tenga Access Keys
# vinculadas, facilitando la limpieza al final del laboratorio.

resource "aws_iam_user" "dev01" {
  name          = "${var.project}-dev-01"
  path          = "/"
  force_destroy = true

  tags = merge(local.tags, { Name = "${var.project}-dev-01" })
}

# Membresía programática: asocia dev-01 al grupo de desarrolladores.
# A partir de este momento, dev-01 hereda todas las políticas del grupo.
resource "aws_iam_user_group_membership" "dev01" {
  user   = aws_iam_user.dev01.name
  groups = [aws_iam_group.developers.name]
}

# ── Trust Policy del Rol EC2 ──────────────────────────────────────────────────
#
# La Trust Policy (política de confianza) responde a la pregunta:
# "¿Quién puede asumir este rol?".
#
# Principal = "ec2.amazonaws.com" significa que únicamente el servicio EC2
# de AWS puede llamar a sts:AssumeRole sobre este rol. Ningún usuario,
# otra función Lambda, ni ningún servicio externo puede hacerlo.
#
# Se usa data source (aws_iam_policy_document) en lugar de jsonencode()
# para aprovechar la validación de sintaxis que hace el provider.

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ── Rol IAM para EC2 ──────────────────────────────────────────────────────────
#
# El rol define QUÉ puede hacer la instancia una vez que lo asume.
# Las políticas adjuntas al rol responden a: "¿A qué recursos puede acceder?".
#
# Flujo completo de asunción de rol:
#   1. EC2 detecta el Instance Profile al arrancar.
#   2. El agente de EC2 llama a sts:AssumeRole usando la Trust Policy.
#   3. STS devuelve credenciales temporales (AccessKeyId + SecretAccessKey + Token).
#   4. Las credenciales se renuevan automáticamente antes de expirar y se
#      exponen en el IMDS en: /latest/meta-data/iam/security-credentials/<rol>.

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-ec2-role"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  description        = "Rol para instancias EC2 del Lab12"

  tags = merge(local.tags, { Name = "${var.project}-ec2-role" })
}

# AmazonSSMManagedInstanceCore: permite que SSM Agent gestione la instancia.
# Sin esta política no es posible abrir sesiones con SSM Session Manager.
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# AmazonEC2ReadOnlyAccess: permite que la instancia llame a ec2:Describe*
# para demostrar que las credenciales temporales funcionan con la API de AWS.
resource "aws_iam_role_policy_attachment" "ec2_readonly" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

# ── Instance Profile ──────────────────────────────────────────────────────────
#
# El Instance Profile es el contenedor que une un Rol IAM con una instancia EC2.
# EC2 no puede usar un rol directamente; necesita este "envoltorio".
# Una instancia solo puede tener un Instance Profile (con un único rol dentro).

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = merge(local.tags, { Name = "${var.project}-ec2-profile" })
}

# ── Data Source: AMI Amazon Linux 2023 (ARM64) ────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Security Group ────────────────────────────────────────────────────────────
#
# Sin reglas inbound: la instancia no necesita recibir conexiones entrantes.
# SSM Session Manager funciona en modo "salida" — el SSM Agent en la instancia
# abre una conexión WebSocket saliente hacia los endpoints de SSM en AWS.
#
# Egress 443 es imprescindible para que SSM Agent y las llamadas a la API
# de AWS (STS, EC2, etc.) funcionen correctamente.

resource "aws_security_group" "ec2" {
  name        = "${var.project}-ec2-sg"
  description = "Sin inbound; egress HTTPS para SSM Agent y AWS API"

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS para SSM Agent, STS y EC2 API"
  }

  tags = merge(local.tags, { Name = "${var.project}-ec2-sg" })
}

# ── Instancia EC2 ─────────────────────────────────────────────────────────────
#
# Al asociar iam_instance_profile, EC2 expone credenciales temporales en IMDS.
# El script user_data.sh valida este comportamiento leyendo el IMDS y
# ejecutando aws sts get-caller-identity.
#
# IMDSv2 (http_tokens = "required") obliga a usar un token de sesión en cada
# petición al metadata service, bloqueando ataques SSRF que intentan
# leer http://169.254.169.254 sin autenticación.

resource "aws_instance" "app" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.ec2.name

  vpc_security_group_ids      = [aws_security_group.ec2.id]
  user_data                   = file("${path.module}/../user_data.sh")
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(local.tags, { Name = "${var.project}-app" })

  depends_on = [
    aws_iam_role_policy_attachment.ec2_ssm,
    aws_iam_role_policy_attachment.ec2_readonly,
  ]
}
