# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Identidades para la supply chain privada
# ═══════════════════════════════════════════════════════════════════════════════
#
# Estructura de identidades:
#
#   Usuarios IAM
#   ├── ci-publisher  → grupo supply-chain-publishers
#   │                   (publica paquetes en CodeArtifact)
#   └── ci-consumer   → grupo supply-chain-consumers
#                       (descarga paquetes para terraform init)
#
#   Grupos IAM
#   ├── supply-chain-publishers
#   │   └── politica: publisher-codeartifact
#   │       - sts:GetServiceBearerToken        (necesario para get-authorization-token)
#   │       - codeartifact:GetAuthorizationToken en el dominio
#   │       - codeartifact:GetRepositoryEndpoint en el repositorio
#   │       (las acciones de paquete se delegan a la politica de recurso del repo)
#   │
#   └── supply-chain-consumers
#       └── politica: consumer-codeartifact
#           - sts:GetServiceBearerToken
#           - codeartifact:GetAuthorizationToken en el dominio
#           - codeartifact:GetRepositoryEndpoint en el repositorio
#           (las acciones de paquete se delegan a la politica de recurso del repo)
#
# Principio de doble capa:
#   CodeArtifact evalua AMBAS capas antes de conceder acceso:
#   1. Politica de identidad (IAM) — el usuario tiene el permiso en su politica
#   2. Politica de recurso (dominio/repo) — el recurso permite al usuario actuar
#   Si falta cualquiera de las dos capas el acceso se deniega (implicit deny).

# ── Usuarios IAM — publishers ─────────────────────────────────────────────────
resource "aws_iam_user" "publisher" {
  for_each = toset(var.publisher_usernames)

  name = each.key
  path = "/supply-chain/publishers/"

  tags = {
    Project   = var.project
    Role      = "publisher"
    ManagedBy = "terraform"
  }
}

# ── Usuarios IAM — consumers ──────────────────────────────────────────────────
resource "aws_iam_user" "consumer" {
  for_each = toset(var.consumer_usernames)

  name = each.key
  path = "/supply-chain/consumers/"

  tags = {
    Project   = var.project
    Role      = "consumer"
    ManagedBy = "terraform"
  }
}

# ── Grupos IAM ────────────────────────────────────────────────────────────────
resource "aws_iam_group" "publishers" {
  name = "${var.project}-publishers"
  path = "/supply-chain/"
}

resource "aws_iam_group" "consumers" {
  name = "${var.project}-consumers"
  path = "/supply-chain/"
}

# ── Membresias ────────────────────────────────────────────────────────────────
resource "aws_iam_user_group_membership" "publisher" {
  for_each = toset(var.publisher_usernames)

  user   = each.key
  groups = [aws_iam_group.publishers.name]

  depends_on = [aws_iam_user.publisher, aws_iam_group.publishers]
}

resource "aws_iam_user_group_membership" "consumer" {
  for_each = toset(var.consumer_usernames)

  user   = each.key
  groups = [aws_iam_group.consumers.name]

  depends_on = [aws_iam_user.consumer, aws_iam_group.consumers]
}

# ── Politica IAM para publishers ──────────────────────────────────────────────
#
# sts:GetServiceBearerToken es la accion STS interna que CodeArtifact invoca
# cuando el cliente llama a GetAuthorizationToken. Sin este permiso,
# get-authorization-token devuelve AccessDeniedException aunque el usuario
# tenga codeartifact:GetAuthorizationToken.
#
# Ambas acciones son necesarias y complementarias:
#   - codeartifact:GetAuthorizationToken: permiso a nivel CodeArtifact
#   - sts:GetServiceBearerToken: permiso a nivel STS para el token interno
data "aws_iam_policy_document" "publisher_codeartifact" {
  # Obtener token de autorizacion (necesario antes de cualquier operacion)
  statement {
    sid    = "AllowGetAuthToken"
    effect = "Allow"

    actions   = ["codeartifact:GetAuthorizationToken"]
    resources = [aws_codeartifact_domain.this.arn]
  }

  statement {
    sid    = "AllowServiceBearerToken"
    effect = "Allow"

    actions   = ["sts:GetServiceBearerToken"]
    resources = ["*"]

    # Limitar el uso del bearer token exclusivamente a CodeArtifact.
    # Sin esta condicion, el permiso podria usarse para obtener tokens
    # de otros servicios que soporten la misma API.
    condition {
      test     = "StringEquals"
      variable = "sts:AWSServiceName"
      values   = ["codeartifact.amazonaws.com"]
    }
  }

  # Descubrir el endpoint HTTPS del repositorio.
  # Necesario para construir la URL de descarga/subida de paquetes.
  statement {
    sid    = "AllowGetRepositoryEndpoint"
    effect = "Allow"

    actions   = ["codeartifact:GetRepositoryEndpoint"]
    resources = [aws_codeartifact_repository.this.arn]
  }

  # Listar dominios y repositorios — util para scripts de CI que necesitan
  # descubrir la infraestructura sin tener los ARNs hardcodeados.
  statement {
    sid    = "AllowListDomainAndRepos"
    effect = "Allow"

    actions = [
      "codeartifact:ListDomains",
      "codeartifact:ListRepositoriesInDomain",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "publisher_codeartifact" {
  name        = "${var.project}-publisher-codeartifact"
  path        = "/supply-chain/"
  description = "Permisos minimos para que CI/CD obtenga tokens y descubra el repositorio. Las acciones de paquete se delegan a la politica del recurso. Lab42."
  policy      = data.aws_iam_policy_document.publisher_codeartifact.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_iam_group_policy_attachment" "publisher_codeartifact" {
  group      = aws_iam_group.publishers.name
  policy_arn = aws_iam_policy.publisher_codeartifact.arn
}

# ── Politica IAM para consumers ───────────────────────────────────────────────
#
# Los consumers tienen exactamente los mismos permisos de identidad que los
# publishers: obtener token y descubrir el endpoint. La diferencia esta en
# la politica de recurso del repositorio: los consumers no tienen
# PublishPackageVersion ni PutPackageMetadata.
#
# Este diseno evita duplicar la logica de separacion de roles en dos capas
# y centraliza el control de acceso a los paquetes en la politica del repo.
data "aws_iam_policy_document" "consumer_codeartifact" {
  statement {
    sid    = "AllowGetAuthToken"
    effect = "Allow"

    actions   = ["codeartifact:GetAuthorizationToken"]
    resources = [aws_codeartifact_domain.this.arn]
  }

  statement {
    sid    = "AllowServiceBearerToken"
    effect = "Allow"

    actions   = ["sts:GetServiceBearerToken"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "sts:AWSServiceName"
      values   = ["codeartifact.amazonaws.com"]
    }
  }

  statement {
    sid    = "AllowGetRepositoryEndpoint"
    effect = "Allow"

    actions   = ["codeartifact:GetRepositoryEndpoint"]
    resources = [aws_codeartifact_repository.this.arn]
  }

  statement {
    sid    = "AllowListDomainAndRepos"
    effect = "Allow"

    actions = [
      "codeartifact:ListDomains",
      "codeartifact:ListRepositoriesInDomain",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "consumer_codeartifact" {
  name        = "${var.project}-consumer-codeartifact"
  path        = "/supply-chain/"
  description = "Permisos minimos para que los consumidores obtengan tokens y descubran el repositorio. Las acciones de descarga se delegan a la politica del recurso. Lab42."
  policy      = data.aws_iam_policy_document.consumer_codeartifact.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_iam_group_policy_attachment" "consumer_codeartifact" {
  group      = aws_iam_group.consumers.name
  policy_arn = aws_iam_policy.consumer_codeartifact.arn
}
