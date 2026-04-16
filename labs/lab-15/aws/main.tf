# ── Data sources ─────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ── OIDC Provider: GitHub Actions ────────────────────────────────────────────
# El thumbprint corresponde al certificado raíz de token.actions.githubusercontent.com.
# GitHub publica actualizaciones en: https://github.blog/changelog/
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint SHA-1 del certificado raíz (DigiCert High Assurance EV Root CA)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

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

# ── Política inline: permisos mínimos para Terraform plan/apply ──────────────
data "aws_iam_policy_document" "terraform_permissions" {
  # Leer y escribir el estado en S3
  statement {
    sid    = "TerraformStateS3"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::terraform-state-labs-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::terraform-state-labs-${data.aws_caller_identity.current.account_id}/*",
    ]
  }

  # Permisos IAM de sólo lectura (para terraform plan sin cambios en IAM)
  statement {
    sid    = "IAMReadOnly"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetOpenIDConnectProvider",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_terraform" {
  name   = "${var.project}-terraform-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.terraform_permissions.json
}
