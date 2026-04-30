# ── Data sources ─────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ── OIDC Provider: GitHub Actions ────────────────────────────────────────────
# Desde julio 2023 AWS valida automáticamente los JWT de GitHub Actions contra
# el JWKS público (https://token.actions.githubusercontent.com/.well-known/jwks)
# sin necesidad de configurar thumbprint_list. El provider Terraform lo soporta
# desde 5.x: el campo es opcional. Antes era obligatorio y todo el mundo
# hardcodeaba el thumbprint del DigiCert root CA, requiriendo actualizaciones
# manuales cada vez que GitHub rotaba el certificado.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name      = "${var.project}-github-oidc"
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Trust Policy: sólo el repositorio y la ref autorizados pueden asumir el rol ─
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    sid     = "AllowGitHubOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Formato: repo:<org>/<repo>:<ref>
      # Ejemplos:
      #   allowed_ref = "*"                      → cualquier rama o tag
      #   allowed_ref = "ref:refs/heads/main"    → sólo la rama main
      values = ["repo:${var.github_org}/${var.github_repo}:${var.allowed_ref}"]
    }
  }
}

# ── IAM Role: identidad efímera para el pipeline ─────────────────────────────
resource "aws_iam_role" "github_actions" {
  name               = "${var.project}-github-actions"
  description        = "Rol asumido por GitHub Actions via OIDC - sin llaves de acceso permanentes"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  tags = {
    Name      = "${var.project}-github-actions"
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Permisos del rol: PowerUserAccess ────────────────────────────────────────
#
# Para simplificar el laboratorio adjuntamos la política gestionada por AWS
# `PowerUserAccess`, que concede acceso a casi todos los servicios (S3, KMS,
# EC2, Lambda, etc.) excluyendo la gestión de IAM, organizaciones y account
# settings. Es la política "todoterreno" que permite que el pipeline ejecute
# Terraform contra prácticamente cualquier recurso sin tener que ampliar la
# policy cada vez que el alumno cambia el demo.
#
# ⚠️ EN PRODUCCIÓN NO se usa así.
#
# El principio de privilegio mínimo (PoLP) exige conceder solo los permisos
# imprescindibles para el caso de uso concreto. Una política inline restringida
# a, por ejemplo:
#
#   - s3:Get*/Put*/List* solo sobre el bucket de estado
#   - kms:Encrypt/Decrypt solo sobre la CMK del proyecto
#   - ec2:Describe* y los Create/Delete específicos para los recursos del módulo
#
# reduce el blast radius si las credenciales temporales se vieran filtradas:
# un atacante con esas credenciales solo podría tocar lo que el rol gestiona,
# no exfiltrar otros servicios o cuentas. Esto es lo que un equipo real
# despliega — y cuesta mantener cada vez que la infraestructura crece, motivo
# por el que el lab simplifica con PowerUserAccess. Ver el [Reto 2] del README
# para el ejercicio de convertir esto a privilegio mínimo real.
resource "aws_iam_role_policy_attachment" "github_actions_poweruser" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
