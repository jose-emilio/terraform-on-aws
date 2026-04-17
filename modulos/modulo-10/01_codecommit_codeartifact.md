# Sección 1 — AWS CodeCommit y CodeArtifact

> [← Volver al índice](./README.md) | [Siguiente →](./02_codebuild.md)

---

## 1. CodeCommit: La Fuente de Verdad de la IaC

AWS CodeCommit es un servicio Git gestionado que proporciona la base del pipeline CI/CD. Alta disponibilidad con réplicas en múltiples AZs, escalabilidad automática y seguridad nativa integrada con IAM. Aquí reside el código de infraestructura que gobierna toda la nube.

> **En la práctica:** "CodeCommit no es solo un repositorio de código — es el origen de la verdad de toda la infraestructura. Cada recurso AWS que existe debería poder rastrearse hasta un commit en CodeCommit. Si alguien creó algo directamente en la consola, ese recurso no existe desde el punto de vista de la gobernanza. La pregunta que siempre hago es: '¿Puede tu equipo reconstruir toda la infraestructura desde cero solo con git clone + terraform apply?' Si la respuesta es sí, están bien. Si es no, tienen deuda técnica."

```hcl
resource "aws_codecommit_repository" "iac_repo" {
  repository_name = "terraform-iac-prod"
  description     = "Repositorio central de IaC"

  tags = {
    Name        = "${var.project}-iac"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.team
  }
}

output "repo_clone_url" {
  value = aws_codecommit_repository.iac_repo.clone_url_http
}
```

---

## 2. Monorepo vs Multi-repo

| Característica | Monorepo | Multi-repo |
|----------------|----------|------------|
| Visibilidad | Total del proyecto | Por componente |
| Refactoring | Sencillo (un solo repo) | Complejo (N repos) |
| Permisos | Todo o nada por default | Granulares por repo |
| Blast radius | Amplio | Reducido |
| Ideal para | Equipos pequeños, arranque | Equipos grandes, múltiples squads |
| Riesgo principal | Cambios que afectan todo | Duplicación de módulos |

**Recomendación:** Empezar con monorepo y extraer a multi-repo cuando el equipo supera 10 personas o cuando squads distintos gestionan componentes distintos.

---

## 3. Estrategias de Branching

### GitFlow — Para entornos con controles de cambio rigurosos

```
main ────────────────────────────────── (producción)
  │
develop ─────────────────────────────── (integración)
  │
feature/vpc-update ──────────────────── (trabajo aislado, vida: días)
  │
hotfix/security-patch ───────────────── (corrección urgente)
```

- `main` → Entorno **PROD**: solo merges aprobados, rama protegida.
- `develop` → Entorno **DEV/STG**: integración continua.
- `feature/*` → Ramas efímeras, PR obligatorio para merge a develop.

### Trunk-Based Development — El estándar moderno

Todos los desarrolladores integran directamente a `main` con validaciones automáticas constantes. Elimina el "merge hell" y reduce el tiempo entre commit y despliegue.

| Aspecto | GitFlow | Trunk-Based |
|---------|---------|-------------|
| Complejidad | Alta | Baja |
| Feedback loop | Lento (días) | Rápido (minutos) |
| Conflictos de merge | Frecuentes | Mínimos |
| Requiere | Proceso riguroso | CI/CD maduro + tests sólidos |
| Ideal para | Regulado/compliance | Agilidad empresarial |

---

## 4. Seguridad: IAM como Identidad Única

CodeCommit elimina usuarios locales de Git — IAM es la identidad única. Todo acceso se gestiona con políticas IAM, con auditoría completa via CloudTrail.

```hcl
# Política de privilegio mínimo: solo push a rama develop
data "aws_iam_policy_document" "dev_push" {
  statement {
    sid    = "AllowPushToDevelop"
    effect = "Allow"
    actions = [
      "codecommit:GitPush",
    ]
    resources = [
      aws_codecommit_repository.iac_repo.arn,
    ]
    condition {
      test     = "StringEqualsIfExists"
      variable = "codecommit:References"
      values   = ["refs/heads/develop"]
      # Cualquier push a main o feature/* queda bloqueado
    }
  }
}
```

**Métodos de autenticación:**
- HTTPS Git Credentials (usuario/contraseña generados desde IAM).
- SSH Keys gestionadas en el perfil IAM.
- `git-remote-codecommit` — Usa credenciales temporales de STS (recomendado para CI/CD).
- Federación con SAML/SSO para identidades corporativas.

---

## 5. Approval Rules — Peer Review Obligatorio

```hcl
# Template de aprobación: 1 aprobación de un Tech Lead para merge a main
resource "aws_codecommit_approval_rule_template" "main_protection" {
  name        = "RequireOneApproval"
  description = "Requiere 1 aprobación para main"

  content = jsonencode({
    Version               = "2018-11-08"
    DestinationReferences = ["refs/heads/main"]
    Statements = [{
      Type                    = "Approvers"
      NumberOfApprovalsNeeded = 1
      ApprovalPoolMembers = [
        "arn:aws:iam::123456789012:role/TechLead",
      ]
    }]
  })
}

# Asociar la template al repositorio
resource "aws_codecommit_approval_rule_template_association" "assoc" {
  approval_rule_template_name = aws_codecommit_approval_rule_template.main_protection.name
  repository_name             = aws_codecommit_repository.iac_repo.repository_name
}
```

---

## 6. Higiene del Repositorio — `.gitignore`

```gitignore
# Terraform — NUNCA subir estos archivos
**/.terraform/*            # Binarios de providers (cientos de MB)
*.tfstate                  # Contiene IPs, ARNs, IDs en texto plano
*.tfstate.*                # Backups de state
crash.log
crash.*.log

# Variables con secretos
*.tfvars                   # Passwords, tokens, API keys
*.tfvars.json
!*.tfvars.example          # Excepto los ejemplos sin secretos reales

# Override files
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Outputs de plan (binarios — no legibles en PR)
*.plan
**/plans/

# IDE y OS
.idea/
.vscode/
.DS_Store
Thumbs.db
*.log
*.tmp
```

**Nota:** `.terraform.lock.hcl` SÍ debe incluirse en Git — garantiza reproducibilidad del `terraform init`.

---

## 7. Pre-commit Hooks — El Filtro Automático Local

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.88.0
    hooks:
      - id: terraform_fmt          # Auto-formatea antes de commit
      - id: terraform_validate     # Valida sintaxis HCL
      - id: terraform_tflint       # Linting con reglas AWS
      - id: terraform_trivy        # Escaneo de seguridad
      - id: terraform_checkov      # Compliance frameworks (CIS, SOC2)
```

```bash
# Instalar y activar
pip install pre-commit
pre-commit install

# Ejecutar manualmente en todo el repo
pre-commit run --all-files
```

**Flujo con pre-commit:**
```
git commit → pre-commit hooks → fmt ✓ → validate ✓ → trivy ✓ → commit ok
                                                      → trivy ✗ → commit bloqueado
```

---

## 8. Triggers y EventBridge — Disparando la Automatización

```hcl
# EventBridge: captura push a main y dispara el pipeline
resource "aws_cloudwatch_event_rule" "main_push" {
  name        = "codecommit-main-push"
  description = "Push a main en repo IaC"

  event_pattern = jsonencode({
    source      = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    detail = {
      event         = ["referenceUpdated"]
      referenceType = ["branch"]
      referenceName = ["main"]
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule     = aws_cloudwatch_event_rule.main_push.name
  arn      = aws_codepipeline.deploy.arn
  role_arn = aws_iam_role.eventbridge_role.arn
}
```

**Tipos de eventos capturables:**
- `referenceUpdated` — Push a una rama.
- `referenceCreated` — Creación de rama o tag.
- `pullRequestMerged` — Merge de PR completado.
- `commentOnPR` — Comentario en pull request.

---

## 9. Notification Rules — Comunicación Proactiva del Equipo

```hcl
resource "aws_codecommit_notification_rule" "pr_alerts" {
  name     = "iac-pr-notifications"
  resource = aws_codecommit_repository.iac_repo.arn

  detail_type = "FULL"   # FULL = incluye todo el contexto del evento

  event_type_ids = [
    "codecommit-repository-pull-request-created",
    "codecommit-repository-pull-request-merged",
    "codecommit-repository-pull-request-status-changed",
    "codecommit-repository-comments-on-pull-requests",
  ]

  target {
    address = aws_sns_topic.dev_team.arn   # → Slack/Teams via AWS Chatbot
  }
}
```

---

## 10. AWS CodeArtifact — Registro Privado de Módulos

Depender de registros públicos en producción es aceptar riesgo externo no controlado. Un módulo público puede desaparecer, ser comprometido (supply chain attack) o tener una versión removida sin aviso. CodeArtifact es el registro privado inmutable para módulos Terraform.

> **En la práctica:** "El peor momento para descubrir que un módulo público fue eliminado es a las 3 AM durante un incidente cuando el pipeline de DR falla en `terraform init`. CodeArtifact resuelve esto: los módulos son tuyos, están en tu cuenta, están versionados, son inmutables. Si publicas la versión 2.1.0, esa versión existirá para siempre hasta que tú la archives."

---

## 11. Estructura: Dominios y Repositorios

```hcl
# Dominio: contenedor raíz de la organización
resource "aws_codeartifact_domain" "main" {
  domain         = "acme-corp"
  encryption_key = aws_kms_key.artifacts.arn   # CMK para cifrado

  tags = {
    Environment = "shared"
    ManagedBy   = "terraform"
  }
}

# Repositorio: segmenta por equipo o entorno
resource "aws_codeartifact_repository" "tf" {
  repository   = "terraform-modules"
  domain       = aws_codeartifact_domain.main.domain
  domain_owner = data.aws_caller_identity.current.id
  description  = "Módulos Terraform privados"

  tags = {
    Purpose   = "iac-modules"
    ManagedBy = "terraform"
  }
}
```

**Jerarquía:** `Dominio` → `Repositorios` → `Paquetes` → `Versiones`

---

## 12. Publicación de Módulos — Script de CI/CD

```bash
#!/bin/bash
# publish-module.sh — Publica un módulo en CodeArtifact

MODULE_NAME="vpc"
VERSION="1.2.0"
DOMAIN="acme-corp"
REPO="terraform-modules"
NAMESPACE="infra"

# 1. Empaquetar el módulo (excluir .terraform/)
cd modules/${MODULE_NAME}
zip -r ../../${MODULE_NAME}.zip . --exclude ".terraform/*"
cd ../../

# 2. Publicar como Generic Package versionado e inmutable
aws codeartifact publish-package-version \
  --domain     ${DOMAIN}       \
  --repository ${REPO}         \
  --format     generic         \
  --namespace  ${NAMESPACE}    \
  --package    ${MODULE_NAME}  \
  --package-version ${VERSION} \
  --asset-content ${MODULE_NAME}.zip \
  --asset-name    ${MODULE_NAME}.zip \
  --asset-sha256  $(sha256sum ${MODULE_NAME}.zip | cut -d' ' -f1)
```

**SemVer para módulos IaC:**

| Cambio | Versión | Ejemplo |
|--------|---------|---------|
| Breaking change (renombrar variable, eliminar output) | MAJOR | `1.x.x` → `2.0.0` |
| Nueva funcionalidad backward-compatible | MINOR | `2.1.x` → `2.2.0` |
| Corrección de bug sin cambio de interfaz | PATCH | `2.2.0` → `2.2.1` |

**Regla de oro:** Una versión publicada en CodeArtifact es **inmutable**. Para cambios, publica una nueva versión. Nunca sobrescribir — el `terraform apply` de hoy debe dar el mismo resultado mañana.

---

## 13. Consumir Módulos — Autenticación via `.netrc`

Terraform usa HTTP/HTTPS para descargar módulos. CodeArtifact requiere un Bearer token que expira cada 12 horas. La solución es el archivo `.netrc` — estándar Unix para HTTP auth que Terraform lee nativamente.

```yaml
# buildspec.yml — fase pre_build
pre_build:
  commands:
    # 1. Obtener token temporal (válido 12h)
    - export CA_TOKEN=$(aws codeartifact get-authorization-token \
        --domain acme-corp \
        --query authorizationToken \
        --output text)

    # 2. Construir hostname del endpoint
    - export CA_HOST="acme-corp-111111111111.d.codeartifact.us-east-1.amazonaws.com"

    # 3. Generar .netrc dinámicamente (NUNCA en el repo)
    - |
      cat > ~/.netrc <<EOF
      machine ${CA_HOST}
      login aws
      password ${CA_TOKEN}
      EOF
    - chmod 600 ~/.netrc   # Permisos estrictos

    # 4. terraform init ya puede descargar módulos privados
    - terraform init
```

```hcl
# Consumir módulo privado desde CodeArtifact
module "vpc" {
  source = "https://acme-corp-111111111111.d.codeartifact.us-east-1.amazonaws.com/generic/terraform-modules/infra/vpc?version=1.2.0"

  vpc_cidr     = "10.0.0.0/16"
  environment  = var.environment
  project_name = var.project_name
  # El .netrc inyecta el Bearer token automáticamente
}
```

---

## 14. Promoción de Artefactos: Dev → Staging → Prod

```
Dev Repository          Staging Repository      Prod Repository
──────────────          ──────────────────      ───────────────
  CI publica aquí         upstream: dev-repo       upstream: staging
  versiones -alpha        solo versiones            solo releases
  tests de integración    estables                  aprobados por arquitecto
  upstream: ninguno       gate: manual approval     política más restrictiva
```

**Lifecycle de versiones:**

```bash
# Marcar como deprecated (visible pero no recomendado)
aws codeartifact update-package-versions-status \
  --domain acme-corp --repository terraform-modules \
  --format generic --namespace infra --package vpc \
  --versions 1.0.0 --target-status Unlisted

# Archivar (no descargable, solo metadata)
aws codeartifact update-package-versions-status \
  --target-status Archived
```

**Política:** Comunicar deprecaciones con 2-4 sprints de antelación. Publicar release notes con breaking changes en la nueva versión MAJOR.

---

> [← Volver al índice](./README.md) | [Siguiente →](./02_codebuild.md)
