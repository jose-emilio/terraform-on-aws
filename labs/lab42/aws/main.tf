# ── Data sources ───────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}

# ── Clave KMS para cifrado del dominio CodeArtifact ────────────────────────────
#
# CodeArtifact cifra todos los assets (paquetes, metadatos) en reposo con la
# clave que se especifica al crear el dominio. Una vez creado, el dominio no
# puede cambiar de clave — es inmutable.
#
# La clave AWS gestionada (aws/codeartifact) es la opcion por defecto, pero
# no permite controlar politicas ni auditar key usage de forma granular.
# Para supply chain critica se usa una CMK con:
#   - Rotacion automatica anual (enable_key_rotation = true)
#   - Politica explicita que solo permite a codeartifact.amazonaws.com usar
#     la clave para GenerateDataKey y Decrypt
#   - La condicion aws:SourceAccount previene el confused-deputy problem
data "aws_iam_policy_document" "codeartifact_kms_policy" {
  # La raiz de la cuenta mantiene acceso completo para administracion de la clave.
  # Sin este statement la clave quedaria inaccesible si se borraran los admins.
  statement {
    sid    = "AllowRootFullAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # CodeArtifact necesita GenerateDataKey para cifrar assets al recibirlos
  # y Decrypt para servirlos a los consumidores.
  statement {
    sid    = "AllowCodeArtifact"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codeartifact.amazonaws.com"]
    }

    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "codeartifact" {
  description             = "CMK para cifrado del dominio CodeArtifact de supply chain. Lab42."
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.codeartifact_kms_policy.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "codeartifact-encryption"
  }
}

resource "aws_kms_alias" "codeartifact" {
  name          = "alias/${var.project}-codeartifact"
  target_key_id = aws_kms_key.codeartifact.key_id
}

# ── Dominio CodeArtifact ───────────────────────────────────────────────────────
#
# El dominio es el contenedor de mas alto nivel en CodeArtifact.
# Todas las operaciones de cross-repo (busqueda, deduplicacion de assets,
# facturacion) ocurren a nivel de dominio.
#
# Propiedades clave:
#   - El nombre del dominio forma parte de la URL del endpoint:
#       <domain>-<account>.d.codeartifact.<region>.amazonaws.com
#   - La clave de cifrado es inmutable — no se puede cambiar tras la creacion.
#   - Los assets duplicados entre repositorios del mismo dominio se almacenan
#     una sola vez (deduplicacion) reduciendo costes de almacenamiento.
resource "aws_codeartifact_domain" "this" {
  domain         = var.domain_name
  encryption_key = aws_kms_key.codeartifact.arn

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Politica de permisos del dominio ──────────────────────────────────────────
#
# La politica de dominio controla quien puede realizar operaciones a nivel de
# dominio: crear repositorios, obtener tokens de autorizacion, describir el
# dominio, listar repositorios.
#
# GetAuthorizationToken se concede en la politica del dominio porque el token
# es valido para todos los repositorios del dominio (no es especifico de un repo).
# sts:GetServiceBearerToken se gestiona en politicas de identidad (ver iam.tf).
data "aws_iam_policy_document" "domain_permissions" {
  # El usuario IAM que ejecuta Terraform necesita acceso completo para
  # poder crear, actualizar y eliminar la política del dominio y el propio
  # dominio. En CodeArtifact, las políticas de recurso del dominio son
  # evaluativas incluso para usuarios IAM de la misma cuenta — un usuario
  # administrador que no aparezca en la política no puede operar sobre el
  # dominio ni destruirlo con terraform destroy.
  # data.aws_caller_identity.current.arn devuelve el ARN del principal
  # que ejecuta terraform apply/destroy, no la cuenta root.
  statement {
    sid    = "AllowAdminFullAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.arn]
    }

    actions   = ["codeartifact:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowPublishersDomainAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [for u in aws_iam_user.publisher : u.arn]
    }

    actions = [
      "codeartifact:GetAuthorizationToken",
      "codeartifact:GetDomainPermissionsPolicy",
      "codeartifact:ListRepositoriesInDomain",
      "codeartifact:DescribeDomain",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowConsumersDomainAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [for u in aws_iam_user.consumer : u.arn]
    }

    actions = [
      "codeartifact:GetAuthorizationToken",
      "codeartifact:GetDomainPermissionsPolicy",
      "codeartifact:ListRepositoriesInDomain",
      "codeartifact:DescribeDomain",
    ]

    resources = ["*"]
  }
}

resource "aws_codeartifact_domain_permissions_policy" "this" {
  domain          = aws_codeartifact_domain.this.domain
  policy_document = data.aws_iam_policy_document.domain_permissions.json
}

# ── Repositorio de modulos Terraform ──────────────────────────────────────────
#
# Almacena paquetes en formato "generic" — el formato de CodeArtifact para
# artefactos binarios arbitrarios que no siguen el esquema de npm/PyPI/Maven.
#
# Un paquete generic tiene:
#   - Namespace (opcional): agrupacion logica, p. ej. "terraform"
#   - Nombre del paquete: p. ej. "vpc-module"
#   - Version semantica: p. ej. "1.0.0"
#   - Uno o mas assets: ficheros que componen el paquete
#
# La inmutabilidad es la propiedad mas importante para supply chain:
# una vez publicada, una version no puede sobrescribirse. Esto garantiza
# que `source = "...vpc-module/1.0.0/..."` siempre sirve exactamente el
# mismo binario, independientemente de cuando se ejecute terraform init.
resource "aws_codeartifact_repository" "this" {
  repository  = var.repo_name
  domain      = aws_codeartifact_domain.this.domain
  description = "Registro privado de modulos Terraform. Paquetes inmutables con version semantica. Lab42."

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Format    = "generic"
  }
}

# ── Politica de permisos del repositorio ─────────────────────────────────────
#
# La politica del repositorio complementa las politicas de identidad (IAM).
# Un principal necesita permiso en AMBAS capas (identidad + recurso) para
# operar — esto es la defensa en profundidad de CodeArtifact.
#
# Separacion de roles:
#   Publishers — pueden crear y publicar versiones de paquetes
#   Consumers  — pueden leer y descargar paquetes (solo lectura)
#
# PublishPackageVersion sin DeletePackageVersions:
#   Los publishers pueden crear nuevas versiones pero no borrar las existentes.
#   Esto refuerza la inmutabilidad: solo un administrador puede eliminar
#   versiones auditadas.
data "aws_iam_policy_document" "repo_permissions" {
  # Mismo razonamiento que en la política del dominio: el usuario IAM
  # que ejecuta Terraform necesita acceso explícito para que terraform
  # destroy pueda eliminar la política del repositorio y el repositorio mismo.
  statement {
    sid    = "AllowAdminFullAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.arn]
    }

    actions   = ["codeartifact:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowPublishers"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [for u in aws_iam_user.publisher : u.arn]
    }

    actions = [
      "codeartifact:PublishPackageVersion",
      "codeartifact:PutPackageMetadata",
      "codeartifact:DescribePackageVersion",
      "codeartifact:GetPackageVersionAsset",
      "codeartifact:GetPackageVersionReadme",
      "codeartifact:GetRepositoryEndpoint",
      "codeartifact:ListPackageVersionAssets",
      "codeartifact:ListPackageVersions",
      "codeartifact:ListPackages",
      "codeartifact:ReadFromRepository",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowConsumers"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [for u in aws_iam_user.consumer : u.arn]
    }

    actions = [
      "codeartifact:DescribePackageVersion",
      "codeartifact:GetPackageVersionAsset",
      "codeartifact:GetPackageVersionReadme",
      "codeartifact:GetRepositoryEndpoint",
      "codeartifact:ListPackageVersionAssets",
      "codeartifact:ListPackageVersions",
      "codeartifact:ListPackages",
      "codeartifact:ReadFromRepository",
    ]

    resources = ["*"]
  }
}

resource "aws_codeartifact_repository_permissions_policy" "this" {
  repository      = aws_codeartifact_repository.this.repository
  domain          = aws_codeartifact_domain.this.domain
  policy_document = data.aws_iam_policy_document.repo_permissions.json
}
