# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Grupo IAM de Desarrolladores ─────────────────────────────────────────────

resource "aws_iam_group" "developers" {
  name = "${var.project}-developers"
  path = "/"
}

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

resource "aws_iam_user" "dev01" {
  name          = "${var.project}-dev-01"
  path          = "/"
  force_destroy = true

  tags = merge(local.tags, { Name = "${var.project}-dev-01" })
}

resource "aws_iam_user_group_membership" "dev01" {
  user   = aws_iam_user.dev01.name
  groups = [aws_iam_group.developers.name]
}

# ── Trust Policy y Rol IAM para EC2 ──────────────────────────────────────────

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

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-ec2-role"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  description        = "Rol para instancias EC2 del Lab12"

  tags = merge(local.tags, { Name = "${var.project}-ec2-role" })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_readonly" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

# ── Instance Profile ──────────────────────────────────────────────────────────

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = merge(local.tags, { Name = "${var.project}-ec2-profile" })
}

# La instancia EC2, el Security Group y el data source de AMI se omiten en
# LocalStack: el servicio EC2 de LocalStack Community no propaga el Instance
# Profile correctamente antes de RunInstances, lo que provoca un error 404.
# El objetivo del laboratorio (crear y verificar los recursos IAM) se cubre
# íntegramente con los recursos anteriores.
