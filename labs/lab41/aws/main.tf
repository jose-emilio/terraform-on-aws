# ── Data sources ───────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Repositorio CodeCommit — Fuente de la Verdad ───────────────────────────────
#
# Este repositorio es el SoT (Source of Truth) del equipo de plataforma.
# La gobernanza se implementa en tres capas complementarias:
#
#   Capa 1 — IAM (preventiva):
#     Politica de privilegio minimo adjunta al grupo de desarrolladores.
#     Un Deny explicito impide push directo a main aunque exista algun Allow
#     heredado de otra politica. Esta capa actua ANTES de que la peticion
#     llegue a CodeCommit.
#
#   Capa 2 — Approval Rule Template (de proceso):
#     Exige N aprobaciones de un pool de lideres tecnicos antes de que el
#     boton "Merge" quede habilitado en la consola o la CLI. Un tech lead
#     puede hacer merge pero no puede auto-aprobarse si el pool solo lo
#     incluye a el.
#
#   Capa 3 — Notificaciones (reactiva / auditoria):
#     CodeStar Notifications + EventBridge publican en SNS ante eventos de
#     Pull Request y cambios en ramas protegidas. Cualquier actor (incluido
#     un administrador que ignore las capas 1 y 2) dejara una traza auditada.

resource "aws_codecommit_repository" "this" {
  repository_name = var.repo_name
  description     = "Backend de la plataforma — rama main = produccion protegida. Lab41."

  tags = {
    Name        = var.repo_name
    Project     = var.project
    ManagedBy   = "terraform"
    Lab         = "41"
    Environment = "multi"
  }
}

# ── Bootstrap del repositorio ─────────────────────────────────────────────────
#
# CodeCommit no permite crear ramas hasta que exista al menos un commit.
# Este recurso usa la CLI de AWS para:
#   1. Crear el commit inicial en 'main' con un README y .gitignore
#   2. Crear la rama 'develop' apuntando al mismo commit inicial
#
# Usamos la API put-file (no git clone/push) para evitar la necesidad de
# credenciales HTTPS o SSH de CodeCommit configuradas en la maquina local.
#
# La logica es idempotente: si las ramas ya existen (re-apply), el script
# las detecta y no repite la operacion.
resource "terraform_data" "repo_bootstrap" {
  triggers_replace = [aws_codecommit_repository.this.repository_name]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail

      REPO="${aws_codecommit_repository.this.repository_name}"
      REGION="${var.region}"

      echo "[bootstrap] Repositorio: $REPO | Region: $REGION"

      # ── Crear commit inicial en main ──────────────────────────────────────
      EXISTING=$(aws codecommit get-branch \
        --repository-name "$REPO" \
        --branch-name main \
        --region "$REGION" \
        --query 'branch.commitId' \
        --output text 2>/dev/null || echo "NONE")

      if [ "$EXISTING" = "NONE" ]; then
        echo "[bootstrap] Creando commit inicial en main..."

        # Escribir contenido a archivo temporal para evitar problemas de
        # codificacion con base64 entre distintos OS (Linux vs macOS).
        TMPFILE=$(mktemp)
        cat > "$TMPFILE" << 'README_CONTENT'
# platform-backend

Repositorio principal del backend de la plataforma.

## Flujo de trabajo (GitFlow simplificado)

```
feature/mi-funcionalidad  ─────────────────┐
                                            ▼
                                        develop  ──────────────┐
                                                                ▼
                                                              main  (= produccion)
```

### Reglas de gobernanza

| Accion                         | Desarrollador | Tech Lead |
|-------------------------------|:-------------:|:---------:|
| `git pull` / clonar           |      ✓        |     ✓     |
| Push a `feature/*`, `bugfix/*` |      ✓        |     ✓     |
| Push a `develop`               |      ✓        |     ✓     |
| Push directo a `main`          |      ✗        |     ✓     |
| Crear Pull Request             |      ✓        |     ✓     |
| Aprobar Pull Request a `main`  |      ✗        |     ✓     |
| Hacer merge a `main`           |      ✗ (*)    |     ✓     |

(*) Requiere aprobacion previa de un tech lead.

## Estructura de ramas

- `main` — rama de produccion, protegida
- `develop` — rama de integracion
- `feature/<ticket>-<descripcion>` — funcionalidades nuevas
- `bugfix/<ticket>-<descripcion>` — correcciones no urgentes
- `hotfix/<version>` — correcciones urgentes sobre produccion
README_CONTENT

        aws codecommit put-file \
          --repository-name "$REPO" \
          --branch-name main \
          --file-path README.md \
          --file-content "fileb://$TMPFILE" \
          --name "Terraform Bootstrap" \
          --email "terraform@lab41.local" \
          --commit-message "chore: initial repository setup [skip ci]" \
          --region "$REGION"

        rm -f "$TMPFILE"
        echo "[bootstrap] Commit inicial creado en main."
      else
        echo "[bootstrap] Rama main ya existe ($EXISTING). Saltando commit inicial."
      fi

      # ── Crear .gitignore en el segundo commit ─────────────────────────────
      CURRENT_COMMIT=$(aws codecommit get-branch \
        --repository-name "$REPO" \
        --branch-name main \
        --region "$REGION" \
        --query 'branch.commitId' \
        --output text)

      GITIGNORE_EXISTS=$(aws codecommit get-file \
        --repository-name "$REPO" \
        --commit-specifier main \
        --file-path .gitignore \
        --region "$REGION" \
        --query 'fileSize' \
        --output text 2>/dev/null || echo "NONE")

      if [ "$GITIGNORE_EXISTS" = "NONE" ]; then
        echo "[bootstrap] Creando .gitignore en main..."

        TMPFILE=$(mktemp)
        cat > "$TMPFILE" << 'GITIGNORE_CONTENT'
# Dependencias
node_modules/
vendor/
.venv/
__pycache__/

# Build
target/
build/
dist/
*.class
*.jar
*.war

# Variables de entorno y secretos
.env
.env.*
!.env.example
*.pem
*.key
secrets.yaml
secrets.json

# IDEs
.idea/
.vscode/
*.iml

# OS
.DS_Store
Thumbs.db

# Logs
*.log
npm-debug.log*
GITIGNORE_CONTENT

        aws codecommit put-file \
          --repository-name "$REPO" \
          --branch-name main \
          --file-path .gitignore \
          --file-content "fileb://$TMPFILE" \
          --name "Terraform Bootstrap" \
          --email "terraform@lab41.local" \
          --commit-message "chore: add .gitignore [skip ci]" \
          --parent-commit-id "$CURRENT_COMMIT" \
          --region "$REGION"

        rm -f "$TMPFILE"
        echo "[bootstrap] .gitignore creado."
      fi

      # ── Crear rama develop ────────────────────────────────────────────────
      DEVELOP_EXISTS=$(aws codecommit get-branch \
        --repository-name "$REPO" \
        --branch-name develop \
        --region "$REGION" \
        --query 'branch.commitId' \
        --output text 2>/dev/null || echo "NONE")

      if [ "$DEVELOP_EXISTS" = "NONE" ]; then
        echo "[bootstrap] Creando rama develop..."

        COMMIT_ID=$(aws codecommit get-branch \
          --repository-name "$REPO" \
          --branch-name main \
          --region "$REGION" \
          --query 'branch.commitId' \
          --output text)

        aws codecommit create-branch \
          --repository-name "$REPO" \
          --branch-name develop \
          --commit-id "$COMMIT_ID" \
          --region "$REGION"

        echo "[bootstrap] Rama develop creada desde $COMMIT_ID."
      else
        echo "[bootstrap] Rama develop ya existe. Saltando."
      fi

      echo "[bootstrap] Repositorio listo para el laboratorio."
    BASH
  }

  depends_on = [aws_codecommit_repository.this]
}

# ── Clave KMS para cifrado del SNS Topic ─────────────────────────────────────
#
# La clave gestionada por AWS (alias/aws/sns) no permite añadir grants en su
# política, por lo que servicios como CodeStar Notifications necesitan una
# clave propia con permisos explícitos para publicar en topics cifrados.
#
# Grants necesarios:
#   - sns.amazonaws.com                    : kms:GenerateDataKey*, kms:Decrypt
#       SNS cifra los mensajes entrantes y los descifra al entregarlos.
#       Sin este grant, ningún publicador puede completar la operación.
#   - codestar-notifications.amazonaws.com : kms:GenerateDataKey*, kms:Decrypt
#   - events.amazonaws.com (EventBridge)   : kms:GenerateDataKey*, kms:Decrypt
#   - cloudwatch.amazonaws.com             : kms:GenerateDataKey*, kms:Decrypt
#
# La condición aws:SourceAccount previene el "confused deputy problem":
# evita que otros accounts usen estos servicios para cifrar datos en
# nuestra clave.
data "aws_iam_policy_document" "sns_kms_policy" {
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

  statement {
    sid    = "AllowSNS"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AllowCodeStarNotifications"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["codestar-notifications.amazonaws.com"]
    }
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AllowEventBridge"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AllowCloudWatch"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "sns" {
  description             = "Clave KMS para cifrado del SNS Topic de notificaciones de gobernanza. Lab41."
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.sns_kms_policy.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "sns-encryption"
  }
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${var.project}-sns"
  target_key_id = aws_kms_key.sns.key_id
}

# ── SNS Topic para notificaciones de Pull Requests ────────────────────────────
#
# Central de mensajeria para todos los eventos de gobernanza:
#   - CodeStar Notifications publica eventos de PR (creado, actualizado, merged)
#   - EventBridge publica alertas de auditoria (push directo a main)
#
# Cifrado con la clave KMS gestionada por Terraform (aws_kms_key.sns).
# La clave tiene grants explícitos para codestar-notifications, events y
# cloudwatch — necesarios porque la clave AWS/SNS no admite modificacion de
# politica.
resource "aws_sns_topic" "pr_notifications" {
  name              = "${var.project}-pr-notifications"
  kms_master_key_id = aws_kms_key.sns.arn

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "codecommit-governance-notifications"
  }
}

# ── Politica combinada del SNS Topic ─────────────────────────────────────────
#
# Un SNS Topic solo admite UNA politica de recurso. Esta politica combina
# los tres principales que necesitan publicar en el topic:
#
#   1. codestar-notifications.amazonaws.com — eventos de Pull Request
#   2. events.amazonaws.com (EventBridge)   — auditoria de push a main
#   3. La cuenta raiz (owner)               — administracion del topic
#
# La condicion aws:SourceAccount en los permisos de servicio previene el
# "confused deputy problem": otro account no puede usar estos servicios
# para publicar en nuestro topic.
data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid    = "AllowOwnerFullAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    # Conjunto exacto que AWS usa en la política por defecto de un topic nuevo.
    # Son las únicas acciones garantizadas como válidas en topic resource policies.
    actions = [
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:AddPermission",
      "SNS:RemovePermission",
      "SNS:DeleteTopic",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
    ]
    resources = [aws_sns_topic.pr_notifications.arn]
  }

  statement {
    sid    = "AllowCodeStarNotificationsPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codestar-notifications.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.pr_notifications.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AllowEventBridgePublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.pr_notifications.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "pr_notifications" {
  arn    = aws_sns_topic.pr_notifications.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

# ── Approval Rule Template ────────────────────────────────────────────────────
#
# Un Approval Rule Template define los requisitos de aprobacion que CodeCommit
# aplica AUTOMATICAMENTE a todos los Pull Requests cuyo destino coincida con
# DestinationReferences (aqui: refs/heads/main).
#
# Cuando un desarrollador abre un PR hacia main, CodeCommit adjunta
# automaticamente una Approval Rule que bloquea el boton "Merge" hasta que
# al menos `var.min_approvals_required` miembros del pool hayan aprobado.
#
# ¿Quien puede aprobar?
#   Pool de aprobadores = lideres tecnicos que asumen el rol IAM
#   'platform-tech-lead-approver'.
#
#   CodeCommit Approval Rule Templates SOLO aceptan ARNs de STS assumed-role,
#   no ARNs de rol IAM directos (arn:aws:iam::...:role/... no está soportado).
#   El formato correcto es:
#
#     arn:aws:sts::<ID>:assumed-role/<NOMBRE>/*
#
#   El wildcard /* acepta cualquier nombre de sesión, lo que cubre tanto
#   la consola AWS (que genera un nombre de sesión automáticamente) como
#   los pipelines de CI/CD que federan credenciales con assume-role.
resource "aws_codecommit_approval_rule_template" "tech_lead_required" {
  name        = "${var.project}-require-tech-lead-approval"
  description = "Exige ${var.min_approvals_required} aprobacion(es) de lider tecnico antes de mergear a main. Gestionado por Terraform — Lab41."

  content = jsonencode({
    Version               = "2018-11-08"
    DestinationReferences = [for b in var.protected_branches : "refs/heads/${b}"]
    Statements = [
      {
        Type                    = "Approvers"
        NumberOfApprovalsNeeded = var.min_approvals_required
        ApprovalPoolMembers = [
          "arn:aws:sts::${data.aws_caller_identity.current.account_id}:assumed-role/${var.project}-tech-lead-approver/*",
        ]
      }
    ]
  })
}

# Asocia el template con el repositorio especifico.
# Sin esta asociacion, el template existe pero no se aplica a ningun repo.
resource "aws_codecommit_approval_rule_template_association" "this" {
  approval_rule_template_name = aws_codecommit_approval_rule_template.tech_lead_required.name
  repository_name             = aws_codecommit_repository.this.repository_name

  depends_on = [aws_codecommit_repository.this]
}
