# Laboratorio 41 — Gobernanza y Control de Versiones en CodeCommit

[← Módulo 10 — CI/CD y Automatización con Terraform](../../modulos/modulo-10/README.md)


## Visión general

En equipos de ingeniería que trabajan con infraestructura crítica o aplicaciones
en producción, el repositorio de código es la **Fuente de la Verdad** (Source
of Truth). Cualquier cambio en el sistema debe pasar por él, y el repositorio
debe ser el primer lugar donde se apliquen los controles de calidad y seguridad.

Este laboratorio implementa un modelo de gobernanza real sobre AWS CodeCommit
organizado en tres capas de defensa complementarias:

1. **Capa preventiva (IAM)**: Una política de privilegio mínimo con un `Deny`
   explícito impide que los desarrolladores hagan push directo a la rama `main`.
   Esta barrera actúa en la capa de autorización de AWS, antes de que la
   petición llegue a CodeCommit.

2. **Capa de proceso (Approval Rule Template)**: CodeCommit exige al menos una
   aprobación de un líder técnico antes de que el botón "Merge" quede habilitado
   en cualquier Pull Request cuyo destino sea `main`. Ni siquiera un desarrollador
   con políticas más amplias puede saltarse este requisito sin que quede registrado.

3. **Capa reactiva/auditoría (Notificaciones)**: CodeStar Notifications y
   EventBridge publican en un SNS Topic ante cada evento de Pull Request y ante
   cualquier escritura directa en `main`. Las alertas llegan a Slack, Teams o
   email en tiempo real.

El resultado es un flujo de trabajo real de GitFlow simplificado donde cada
cambio a producción tiene al menos dos pares de ojos sobre él.

## Objetivos

- Aprovisionar un repositorio CodeCommit con estructura inicial de ramas
  (`main` y `develop`) usando Terraform y la CLI de AWS desde `local-exec`.

- Construir una política IAM de privilegio mínimo con `Deny` explícito que
  separe los permisos de desarrolladores y líderes técnicos.

- Demostrar con credenciales reales de alice-dev que el `Deny` IAM prevalece
  sobre cualquier `Allow` heredado: push prohibido a `main`, permitido a `develop`.

- Configurar un Approval Rule Template que exija N aprobaciones de un pool de
  líderes técnicos antes de hacer merge a `main`.

- Simular el flujo completo de aprobación desde la CLI: crear PR, asumir el
  rol de tech lead, aprobar, verificar que el merge queda habilitado.

- Establecer una Notification Rule de CodeStar y una regla de EventBridge para
  alertar ante eventos de Pull Request y escrituras directas en `main`.

- Implementar una CloudWatch Alarm que detecte intentos de anular reglas de
  aprobación (`OverridePullRequestApprovalRules`).

## Requisitos previos

- Terraform >= 1.5 instalado.
- AWS CLI v2 configurado con perfil `default` y permisos de administrador.
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado
  habilitado (necesario para el backend S3 del estado).

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
export REGION="us-east-1"
```

## Arquitectura

```
labs/lab41/aws/
├── providers.tf        ── Backend S3, proveedor AWS
├── variables.tf        ── Parámetros: repo, usuarios, ramas protegidas, webhooks
├── main.tf             ── CodeCommit repo, bootstrap, SNS Topic, Approval Rule Template
├── iam.tf              ── Usuarios, grupos, roles, políticas IAM
├── notifications.tf    ── CodeStar rule, suscripciones SNS, EventBridge, CloudWatch Alarm
├── outputs.tf          ── URLs de clonación, ARNs, comandos de verificación
└── aws.s3.tfbackend    ── Configuración parcial del backend S3

Flujo de trabajo gobernado:
─────────────────────────────────────────────────────────────────────────────

  Desarrollador (alice-dev / bob-dev)
  │
  ├─ git push origin feature/JIRA-123-nuevo-endpoint  ✓  (permitido)
  ├─ git push origin develop                           ✓  (permitido)
  ├─ git push origin main                              ✗  (IAM Deny)
  │
  └─ aws codecommit create-pull-request               ✓  (permitido)
       --source-reference develop
       --destination-reference main
              │
              ▼
  CodeCommit adjunta automáticamente:
    "Approval Rule: Requiere 1 aprobación de tech lead"
              │
              ▼
  Líder Técnico (carlos-lead / diana-lead)
  │
  ├─ Revisa el diff, deja comentarios
  ├─ Asume rol lab41-tech-lead-approver via sts:AssumeRole
  └─ update-pull-request-approval-state → APPROVE
              │
              ▼
  Botón "Merge" habilitado → PR merged a main
              │
              ▼
  SNS Topic ──► Slack/Teams
             ──► Email
             ──► Registros de auditoría (EventBridge)

Gobernanza en capas:
─────────────────────────────────────────────────────────────────────────────

  Capa 1 — IAM (preventiva)
  ┌────────────────────────────────────────────────────────────────────┐
  │  Grupo: platform-developers                                        │
  │  Política: developer-codecommit                                    │
  │                                                                    │
  │  ALLOW: GitPull, Get*, List*, Describe*  (sin restricción de rama) │
  │  ALLOW: GitPush, PutFile, CreateBranch   (sin restricción de rama) │
  │  ALLOW: DeleteBranch                     → feature/*, bugfix/*     │
  │  ALLOW: CreatePullRequest, PostComment*  (sin restricción)         │
  │                                                                    │
  │  DENY:  GitPush, PutFile, Merge*, Delete → main (INVALIDA ALLOWS)  │
  │  DENY:  OverridePullRequestApprovalRules (anti-bypass)             │
  └────────────────────────────────────────────────────────────────────┘

  Capa 2 — Approval Rule Template (de proceso)
  ┌────────────────────────────────────────────────────────────────────┐
  │  Template: lab41-require-tech-lead-approval                        │
  │  DestinationReferences: ["refs/heads/main"]                        │
  │  Approvers needed: 1                                               │
  │  Pool: arn:aws:sts::<ID>:assumed-role/lab41-tech-lead-approver/*   │
  └────────────────────────────────────────────────────────────────────┘

  Capa 3 — Notificaciones (reactiva / auditoría)
  ┌────────────────────────────────────────────────────────────────────┐
  │  CodeStar Notifications ─► PR creado, actualizado, merged          │
  │  EventBridge ────────────► Push directo / merge a main             │
  │  CloudWatch Alarm ───────► Override de reglas de aprobación        │
  │                                                                    │
  │  Todos confluyen en SNS Topic → Slack / Teams / Email              │
  └────────────────────────────────────────────────────────────────────┘
```

## Conceptos clave

### Por qué un `Deny` explícito en IAM

En AWS IAM, la evaluación de políticas sigue este orden:

```
1. Deny explícito (cualquier política)    → DENEGAR
2. SCP de Organizations que deniega      → DENEGAR
3. Allow en política de identidad        → PERMITIR
4. Sin Allow                             → DENEGAR (implicit deny)
```

Un `Deny` explícito es la única forma de garantizar que una acción
**jamás** ocurra, independientemente de otros `Allow` que existan en el
mismo usuario, grupo o rol. Sin el Deny explícito, bastaría con que un
administrador adjuntara la política gestionada `AWSCodeCommitFullAccess`
al grupo de desarrolladores para que cualquier restricción de rama quedara
sin efecto.

```hcl
# Allow SIN condicion de rama — habilita la capacidad de push.
# Un Allow condicionado con StringLike evalua a false durante el handshake
# HTTP de git (GET /info/refs), donde codecommit:References aun no existe.
# Eso causaria implicit deny en TODAS las ramas, incluidas las de trabajo.
statement {
  effect  = "Allow"
  actions = ["codecommit:GitPush", "codecommit:PutFile", "codecommit:CreateBranch"]
  # Sin condition block — la proteccion real la da el Deny de abajo.
}

# Deny CON condicion de rama — bloquea las ramas protegidas.
# StringLike evalua a false si codecommit:References esta ausente,
# por lo que el Deny no afecta operaciones sin contexto de rama.
# Cuando la clave SI existe (push real a una rama), el Deny prevalece
# sobre cualquier Allow gracias a la logica de evaluacion de IAM.
statement {
  effect  = "Deny"
  actions = ["codecommit:GitPush", "codecommit:MergePullRequestBy*", ...]
  condition {
    test     = "StringLike"
    variable = "codecommit:References"
    values   = ["refs/heads/main"]
  }
}
```

La clave de condición `codecommit:References` contiene el nombre completo
de la referencia git (`refs/heads/main`, `refs/heads/develop`, etc.) y solo
está presente cuando la petición involucra una rama concreta. `StringLike`
devuelve `false` si la clave no existe en el contexto — por eso es segura
para un `Deny`: no bloquea operaciones sin referencia de rama. En un `Allow`,
ese mismo comportamiento es problemático porque el Allow tampoco aplica
durante el handshake HTTP, dejando implicit deny en todas las ramas.

### Approval Rule Template vs reglas de aprobación directas

CodeCommit tiene dos mecanismos de aprobación:

| Mecanismo                         | Alcance           | Gestionado por    |
|-----------------------------------|-------------------|-------------------|
| **Approval Rule Template**        | N repositorios    | Admin / Terraform |
| **Regla de aprobación del PR**    | Un PR específico  | Quien crea el PR  |

El template es el apropiado para gobernanza corporativa porque:
- Se asocia a uno o más repositorios una sola vez.
- CodeCommit adjunta automáticamente la regla a cada nuevo PR que cumpla
  el criterio de rama destino — sin que el desarrollador tenga que hacer nada.
- Modificar o borrar el template requiere permisos de administrador de
  CodeCommit, no permisos del repositorio.
- El campo `DestinationReferences` filtra por rama destino del PR:
  solo los PRs hacia `main` (o `release/*`) heredan la regla.

```json
{
  "Version": "2018-11-08",
  "DestinationReferences": ["refs/heads/main"],
  "Statements": [{
    "Type": "Approvers",
    "NumberOfApprovalsNeeded": 1,
    "ApprovalPoolMembers": [
      "arn:aws:sts::<ACCOUNT_ID>:assumed-role/lab41-tech-lead-approver/*"
    ]
  }]
}
```

El pool de aprobadores acepta ARNs de roles IAM (formato directo y formato
de sesión asumida) pero **no acepta ARNs de usuarios IAM directamente**.
Por eso el laboratorio usa un rol que los tech leads asumen con
`sts:AssumeRole`.

### CodeStar Notifications vs EventBridge para CodeCommit

| Capacidad                           | CodeStar Notifications | EventBridge      |
|-------------------------------------|------------------------|------------------|
| Eventos de Pull Request             | Sí (nativo)            | Sí (limitado)    |
| Eventos de rama (push, creación)    | No                     | Sí               |
| Eventos de aprobación               | Sí                     | No               |
| Formato del mensaje                 | Enriquecido (FULL)     | Raw JSON         |
| Integración con Chatbot             | Sí (nativa)            | Vía Lambda       |

Usar ambos servicios cubre el espectro completo: CodeStar para el ciclo de
vida del PR y EventBridge para auditoría de escrituras directas que
podrían saltarse el proceso de PR.

### El rol IAM como pool de aprobadores

Un patrón frecuente en equipos es querer que "el grupo de tech leads" sea el
pool de aprobadores. Pero el Approval Rule Template no acepta grupos IAM,
solo ARNs de roles o usuarios.

La solución es crear un **rol compartido** que todos los tech leads pueden
asumir. Cuando `carlos-lead` asume el rol y aprueba el PR, CodeCommit registra
la aprobación bajo el ARN de la sesión del rol (`assumed-role/...`), que
encaja con el pool definido en el template.

Ventajas de este patrón sobre usar ARNs de usuario directamente:
- Añadir un nuevo tech lead no requiere modificar el Approval Rule Template.
- Si un tech lead deja el equipo, se le quita del Trust Policy del rol.
- El rol puede tener una sesión de duración corta (`DurationSeconds`) para
  forzar autenticación frecuente al aprobar PRs.

## Estructura del proyecto

```
lab41/
├── aws/
│   ├── providers.tf        Terraform >= 1.5, AWS ~> 6.0, backend S3
│   ├── variables.tf        Parámetros: repo_name, developer_usernames,
│   │                       tech_lead_usernames, protected_branches,
│   │                       slack_webhook_url, notification_email,
│   │                       min_approvals_required
│   ├── main.tf             CodeCommit repo, bootstrap (terraform_data),
│   │                       SNS Topic + política combinada,
│   │                       Approval Rule Template + asociación
│   ├── iam.tf              Usuarios IAM (developers + tech_leads),
│   │                       Grupos IAM, membresias,
│   │                       Política developer (allow + deny),
│   │                       Política tech_lead (full access),
│   │                       Rol de aprobador + assume_role policy
│   ├── notifications.tf    CodeStar Notification Rule,
│   │                       Suscripción HTTPS (webhook),
│   │                       Suscripción email,
│   │                       EventBridge rule + target (auditoría),
│   │                       CloudWatch metric filter + alarm
│   ├── outputs.tf          URLs, ARNs, comandos de verificación
│   └── aws.s3.tfbackend    key: lab41/terraform.tfstate
└── README.md
```

---

## Paso 1 — Desplegar la infraestructura de gobernanza

```bash
cd labs/lab41/aws

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"
```

Revisa el plan antes de aplicar para entender cuántos recursos se crean:

```bash
terraform plan
```

El plan debe mostrar aproximadamente **28-32 recursos** dependiendo de cuántos
usuarios estén configurados en `var.developer_usernames` y `var.tech_lead_usernames`:

```
  # aws_codecommit_repository.this                                  will be created
  # aws_codecommit_approval_rule_template.tech_lead_required        will be created
  # aws_codecommit_approval_rule_template_association.this          will be created
  # aws_sns_topic.pr_notifications                                  will be created
  # aws_sns_topic_policy.pr_notifications                           will be created
  # aws_codestar_notifications_notification_rule.pull_requests      will be created
  # aws_cloudwatch_event_rule.main_branch_write_audit               will be created
  # aws_cloudwatch_event_target.main_branch_write_audit_to_sns      will be created
  # aws_cloudwatch_log_metric_filter.approval_override_attempts     will be created
  # aws_cloudwatch_metric_alarm.approval_override_alert             will be created
  # aws_iam_user.developer["alice-dev"]                             will be created
  # aws_iam_user.developer["bob-dev"]                               will be created
  # aws_iam_user.tech_lead["carlos-lead"]                           will be created
  # aws_iam_user.tech_lead["diana-lead"]                            will be created
  # aws_iam_group.developers                                        will be created
  # aws_iam_group.tech_leads                                        will be created
  # aws_iam_policy.developer_codecommit                             will be created
  # aws_iam_policy.tech_lead_codecommit                             will be created
  # aws_iam_policy.assume_tech_lead_approver                        will be created
  # aws_iam_role.tech_lead                                          will be created
  # terraform_data.repo_bootstrap                                   will be created
  # ...
```

Aplica la infraestructura:

```bash
terraform apply
```

El `terraform_data.repo_bootstrap` ejecutará un script bash al final del apply
que crea el commit inicial en `main` y la rama `develop`. Verifica el output:

```
module: terraform_data.repo_bootstrap
[bootstrap] Repositorio: platform-backend | Region: us-east-1
[bootstrap] Creando commit inicial en main...
[bootstrap] Commit inicial creado en main.
[bootstrap] Creando .gitignore en main...
[bootstrap] .gitignore creado.
[bootstrap] Creando rama develop...
[bootstrap] Rama develop creada desde abc1234...
[bootstrap] Repositorio listo para el laboratorio.
```

Verifica las ramas creadas:

```bash
aws codecommit list-branches \
  --repository-name platform-backend \
  --region us-east-1
# {
#   "branches": ["develop", "main"]
# }
```

Consulta los outputs del apply para obtener las URLs de clonación y los
comandos de verificación:

```bash
terraform output repository_clone_url_http
terraform output verify_commands
```

---

## Paso 2 — Verificar las restricciones IAM con credenciales reales

La forma más directa y fiable de verificar que las políticas IAM funcionan
es impersonar a `alice-dev` usando sus credenciales e intentar operaciones
reales contra CodeCommit. Un `AccessDeniedException` confirma el Deny; un
resultado exitoso confirma el Allow.

> **IMPORTANTE — usa una terminal nueva para este paso.**
> El objetivo es aislar completamente las credenciales de alice de tu sesión
> de administrador. Si contaminas la sesión actual con las variables de entorno
> de alice, los comandos de Terraform y AWS CLI del lab usarán sus permisos
> restringidos y fallarán. Abre una terminal separada, haz las pruebas,
> y ciérrala al terminar.

### Preparar las credenciales de alice (en tu terminal de administrador)

```bash
# Desde el directorio labs/lab41/aws — con tus credenciales de administrador
REPO_NAME=$(terraform output -raw repository_name)

# Crear access key para alice-dev
KEY_JSON=$(aws iam create-access-key --user-name alice-dev)
echo "Access Key ID:     $(echo $KEY_JSON | jq -r '.AccessKey.AccessKeyId')"
echo "Secret Access Key: $(echo $KEY_JSON | jq -r '.AccessKey.SecretAccessKey')"
```

### 2a — Abrir una nueva terminal e impersonar a alice-dev

**En la terminal nueva**, exportar las credenciales de alice y configurar git:

```bash
# ⚠️  NUEVA TERMINAL — no ejecutar en la sesión de administrador
export AWS_ACCESS_KEY_ID="<AccessKeyId del paso anterior>"
export AWS_SECRET_ACCESS_KEY="<SecretAccessKey del paso anterior>"
export AWS_DEFAULT_REGION="us-east-1"

# Verificar que somos alice-dev
aws sts get-caller-identity --query 'Arn' --output text
# arn:aws:iam::<ACCOUNT_ID>:user/platform/developers/alice-dev

# Configurar git para usar las credenciales IAM del entorno.
# Las comillas simples son necesarias para que bash no interprete
# el ! ni el $@ como expansiones propias del shell.
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
git config --global user.name "alice-dev"
git config --global user.email "alice@lab41.local"

# Clonar el repositorio
CLONE_URL=$(aws codecommit get-repository \
  --repository-name platform-backend \
  --query 'repositoryMetadata.cloneUrlHttp' \
  --output text)

git clone "$CLONE_URL" /tmp/platform-backend
cd /tmp/platform-backend
```

### 2b — Probar que alice-dev NO puede hacer push a main

```bash
# ⚠️  TERMINAL DE ALICE — /tmp/platform-backend

# Crear un commit en local sobre main e intentar el push
echo "test" > test-permisos.txt
git checkout main
git add test-permisos.txt
git commit -m "test: verificacion de permisos [debe fallar]"
git push origin main
```

Resultado esperado:

```
fatal: unable to access 'https://git-codecommit.us-east-1.amazonaws.com/v1/repos/platform-backend/':
The requested URL returned error: 403
```

El Deny de IAM sobre `codecommit:GitPush` se aplica en la fase de handshake
HTTP (`git-receive-pack`), antes de que se establezca el protocolo git.
CodeCommit devuelve un HTTP 403 a nivel de transporte en lugar de un mensaje
`remote: error:` a nivel de protocolo. El efecto es el mismo: alice no puede
hacer push a main y el rechazo se registra en CloudTrail como
`ExplicitDeny`.

Deshaz el commit local para no arrastrar cambios al paso siguiente:

```bash
# --hard restaura también el working tree, evitando archivos no rastreados sueltos
git reset --hard HEAD~1
```

### 2c — Probar que alice-dev SÍ puede hacer push a develop

```bash
# ⚠️  TERMINAL DE ALICE — /tmp/platform-backend

git checkout develop
echo "test" > test-permisos.txt
git add test-permisos.txt
git commit -m "test: verificacion de permisos develop [debe funcionar]"
git push origin develop
```

Resultado esperado: push completado con el `commitId` confirmado por el remote.

Limpia el commit de prueba para mantener el historial limpio:

```bash
git revert HEAD --no-edit
git push origin develop
```

### 2d — Probar que alice-dev NO puede anular reglas de aprobación

No hay comando git para esto — se prueba con la AWS CLI creando un PR de prueba:

```bash
# ⚠️  TERMINAL DE ALICE

TEST_PR=$(aws codecommit create-pull-request \
  --title "Test permisos override" \
  --targets "repositoryName=platform-backend,sourceReference=develop,destinationReference=main" \
  --query 'pullRequest.pullRequestId' --output text)

aws codecommit override-pull-request-approval-rules \
  --pull-request-id "$TEST_PR" \
  --revision-id "$(aws codecommit get-pull-request \
    --pull-request-id "$TEST_PR" \
    --query 'pullRequest.revisionId' --output text)" \
  --override-status OVERRIDE
```

Resultado esperado:

```
An error occurred (AccessDeniedException) when calling the
OverridePullRequestApprovalRules operation:
User: arn:aws:iam::<ACCOUNT_ID>:user/platform/developers/alice-dev is not
authorized to perform: codecommit:OverridePullRequestApprovalRules on resource:
arn:aws:codecommit:us-east-1:<ACCOUNT_ID>:platform-backend with an explicit
deny in an identity-based policy:
arn:aws:iam::<ACCOUNT_ID>:policy/platform/lab41-developer-codecommit
```

La sentencia `DenyModifyApprovalRules` bloquea el intento de saltar
el proceso de revisión obligatoria.

Cierra el PR de prueba para que no interfiera con los pasos siguientes:

```bash
# ⚠️  TERMINAL DE ALICE
aws codecommit update-pull-request-status \
  --pull-request-id "$TEST_PR" \
  --pull-request-status CLOSED
```

> **No borres la access key de alice ni cierres su terminal** — la
> reutilizarás en el Paso 3, donde ya tienes el repo clonado en
> `/tmp/platform-backend`.

> **Nota sobre release/1.0**: la política por defecto solo protege `main`.
> Para que `release/*` también sea inaccesible para alice, actualiza la
> variable en el Reto 1.

---

## Paso 3 — Flujo de desarrollo real como alice-dev

Continúa en la misma terminal de alice con el repo ya clonado en
`/tmp/platform-backend`.

```bash
# ⚠️  TERMINAL DE ALICE
cd /tmp/platform-backend
aws sts get-caller-identity --query 'Arn' --output text
# arn:aws:iam::<ACCOUNT_ID>:user/platform/developers/alice-dev
```

### 3a — Crear la feature branch y hacer un commit

```bash
# ⚠️  TERMINAL DE ALICE — /tmp/platform-backend

git checkout develop
git checkout -b feature/JIRA-101-health-endpoint

mkdir -p src/api
cat > src/api/health.py << 'EOF'
def handler(event, context):
    """Health check endpoint."""
    return {
        "statusCode": 200,
        "body": '{"status": "healthy", "version": "1.0.0"}'
    }
EOF

git add src/api/health.py
git commit -m "feat(JIRA-101): add health check endpoint"

# Push de la feature branch — alice tiene permiso sobre feature/*
git push origin feature/JIRA-101-health-endpoint
```

### 3b — Integrar la feature en develop (flujo GitFlow correcto)

```bash
# ⚠️  TERMINAL DE ALICE — /tmp/platform-backend

git checkout develop
git merge feature/JIRA-101-health-endpoint --no-ff \
  -m "merge: JIRA-101 health check endpoint into develop"

# Push a develop — alice tiene permiso
git push origin develop

# Eliminar la feature branch local y remota — ya está integrada en develop
git branch -d feature/JIRA-101-health-endpoint
git push origin --delete feature/JIRA-101-health-endpoint
```

### 3c — Abrir el Pull Request de develop a main

El PR se crea con la AWS CLI (no existe comando git estándar para esto):

```bash
# ⚠️  TERMINAL DE ALICE

PR_ID=$(aws codecommit create-pull-request \
  --title "feat(JIRA-101): Add health check endpoint" \
  --description "$(cat << 'EOF'
## Descripción
Implementa el endpoint GET /health para monitoreo de la plataforma.

## Cambios
- Nuevo archivo src/api/health.py
- Retorna HTTP 200 con estado y versión del servicio

## Checklist
- [x] Cumple con el coding standard
- [x] Sin secretos hardcodeados
- [x] Revisado por QA en develop
EOF
)" \
  --targets "repositoryName=platform-backend,sourceReference=develop,destinationReference=main" \
  --query "pullRequest.pullRequestId" \
  --output text)

echo "Pull Request creado: PR #${PR_ID}"
```

### 3d — Verificar que la Approval Rule se adjuntó automáticamente

```bash
# ⚠️  TERMINAL DE ALICE

aws codecommit get-pull-request \
  --pull-request-id "${PR_ID}" \
  --query "pullRequest.approvalRules"
```

Resultado esperado:

```json
[
    {
        "approvalRuleId": "...",
        "approvalRuleName": "lab41-require-tech-lead-approval",
        "approvalRuleContent": "{\"DestinationReferences\":[\"refs/heads/main\"],\"Statements\":[{\"ApprovalPoolMembers\":[\"arn:aws:sts::<ACCOUNT_ID>:assumed-role/lab41-tech-lead-approver/*\"],\"NumberOfApprovalsNeeded\":1,\"Type\":\"Approvers\"}],\"Version\":\"2018-11-08\"}",
        "lastModifiedUser": "codecommit.amazonaws.com",
        "originApprovalRuleTemplate": {
            "approvalRuleTemplateId": "...",
            "approvalRuleTemplateName": "lab41-require-tech-lead-approval"
        }
    }
]
```

Tres campos confirman que la gobernanza funciona correctamente:
- `lastModifiedUser: codecommit.amazonaws.com` — la regla la adjuntó CodeCommit automáticamente, no alice ✓
- `originApprovalRuleTemplate` — proviene del template de Terraform, no de una regla manual del PR ✓
- `ApprovalPoolMembers` — referencia el rol `assumed-role/lab41-tech-lead-approver/*` ✓

### 3e — Intentar el merge como alice-dev (debe fallar)

```bash
# ⚠️  TERMINAL DE ALICE

aws codecommit merge-pull-request-by-fast-forward \
  --pull-request-id "${PR_ID}" \
  --repository-name platform-backend
```

Resultado esperado:

```
aws: [ERROR]: An error occurred (AccessDeniedException) when calling the
MergePullRequestByFastForward operation:
User: arn:aws:iam::<ACCOUNT_ID>:user/platform/developers/alice-dev is not
authorized to perform: codecommit:MergePullRequestByFastForward on resource:
arn:aws:codecommit:us-east-1:<ACCOUNT_ID>:platform-backend with an explicit
deny in an identity-based policy:
arn:aws:iam::<ACCOUNT_ID>:policy/platform/lab41-developer-codecommit
```

> **Guarda el valor de `$PR_ID`** — lo necesitarás en el Paso 4 para
> que el tech lead apruebe y complete el merge.

Cierra la terminal de alice para eliminar las variables de entorno de su sesión.

---

## Paso 4 — Simular la aprobacion del tech lead y completar el merge

Un tech lead debe asumir el rol `lab41-tech-lead-approver` para que CodeCommit
reconozca su aprobación como perteneciente al pool autorizado.
La aprobación del PR no tiene equivalente en git — es una operación de la API
de CodeCommit. El merge sí se puede hacer con git, demostrando que el tech
lead puede hacer push directo a `main` (algo que el Deny bloquea a alice).

> **IMPORTANTE — abre una terminal nueva para este paso**, igual que hiciste
> con alice. Así las credenciales de carlos-lead quedan aisladas de tu sesión
> de administrador.

### Preparar las credenciales de carlos-lead (en tu terminal de administrador)

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — directorio labs/lab41/aws

PR_ID=$(aws codecommit list-pull-requests \
  --repository-name platform-backend \
  --pull-request-status OPEN \
  --query 'pullRequestIds[0]' \
  --output text \
  --region us-east-1)
echo "PR activo: #${PR_ID}"

ROLE_ARN=$(terraform output -raw tech_lead_approver_role_arn)
CLONE_URL=$(terraform output -raw repository_clone_url_http)
echo "Rol de aprobador: $ROLE_ARN"

# Crear access key temporal para carlos-lead
KEY_JSON=$(aws iam create-access-key --user-name carlos-lead)
echo "Access Key ID:     $(echo $KEY_JSON | jq -r '.AccessKey.AccessKeyId')"
echo "Secret Access Key: $(echo $KEY_JSON | jq -r '.AccessKey.SecretAccessKey')"
```

### 4a — Abrir una nueva terminal e impersonar a carlos-lead

```bash
# ⚠️  NUEVA TERMINAL

export AWS_ACCESS_KEY_ID="<AccessKeyId del paso anterior>"
export AWS_SECRET_ACCESS_KEY="<SecretAccessKey del paso anterior>"
export AWS_DEFAULT_REGION="us-east-1"

# Copiar estos valores desde la terminal de administrador
export PR_ID="<PR_ID del paso anterior>"
export ROLE_ARN="<ROLE_ARN del paso anterior>"
export CLONE_URL="<CLONE_URL del paso anterior>"

# Verificar que somos carlos-lead
aws sts get-caller-identity --query 'Arn' --output text
# arn:aws:iam::<ACCOUNT_ID>:user/platform/tech-leads/carlos-lead

git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
git config --global user.name "carlos-lead"
git config --global user.email "carlos-lead@empresa.com"
```

### 4b — Asumir el rol de aprobador

carlos-lead necesita asumir el rol para que CodeCommit reconozca su aprobación
como perteneciente al pool del Approval Rule Template.

```bash
# ⚠️  TERMINAL DE CARLOS

CREDS=$(aws sts assume-role \
  --role-arn "${ROLE_ARN}" \
  --role-session-name "approve-pr-${PR_ID}-$(date +%s)" \
  --duration-seconds 900 \
  --query "Credentials" \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.SessionToken')

aws sts get-caller-identity --query 'Arn' --output text
# arn:aws:sts::<ID>:assumed-role/lab41-tech-lead-approver/approve-pr-...
```

### 4c — Clonar el repositorio

```bash
# ⚠️  TERMINAL DE CARLOS

git clone "${CLONE_URL}" /tmp/platform-backend-lead
cd /tmp/platform-backend-lead
```

### 4d — Revisar el código y dejar un comentario

```bash
# ⚠️  TERMINAL DE CARLOS — /tmp/platform-backend-lead

# Revisar los cambios del PR antes de aprobar
git log origin/main..origin/develop --oneline
git diff origin/main...origin/develop

# Dejar un comentario de revisión en el PR
BEFORE_COMMIT=$(git rev-parse origin/main)
AFTER_COMMIT=$(git rev-parse origin/develop)

aws codecommit post-comment-for-pull-request \
  --pull-request-id "${PR_ID}" \
  --repository-name platform-backend \
  --before-commit-id "${BEFORE_COMMIT}" \
  --after-commit-id "${AFTER_COMMIT}" \
  --content "👀 Revisado. El endpoint retorna el formato correcto y no expone información sensible. 🟢 LGTM — aprobado para merge." \
  --region us-east-1
```

### 4e — Aprobar el Pull Request


La aprobación debe hacerse via API — no existe comando git para esto.
CodeCommit comprueba que el ARN de la sesión asumida pertenece al pool
del Approval Rule Template antes de registrar la aprobación.

```bash
# ⚠️  TERMINAL DE CARLOS

REVISION_ID=$(aws codecommit get-pull-request \
  --pull-request-id "${PR_ID}" \
  --query 'pullRequest.revisionId' \
  --output text \
  --region us-east-1)

aws codecommit update-pull-request-approval-state \
  --pull-request-id "${PR_ID}" \
  --revision-id "${REVISION_ID}" \
  --approval-state APPROVE \
  --region us-east-1

echo "PR #${PR_ID} aprobado por $(aws sts get-caller-identity --query Arn --output text)"
```

### 4f — Verificar que las reglas de aprobación están satisfechas

```bash
aws codecommit evaluate-pull-request-approval-rules \
  --pull-request-id "${PR_ID}" \
  --revision-id "${REVISION_ID}" \
  --region us-east-1
```

Resultado esperado:

```json
{
  "evaluation": {
    "approved": true,
    "overridden": false,
    "approvalRulesSatisfied": ["lab41-require-tech-lead-approval"],
    "approvalRulesNotSatisfied": []
  }
}
```

### 4g — Completar el merge con git

El tech lead tiene `codecommit:*` sin Deny — puede hacer push directo a `main`.
Esto contrasta con alice, a quien el Deny bloqueó el mismo intento en el Paso 2.

```bash
# ⚠️  TERMINAL DE CARLOS — /tmp/platform-backend-lead

git checkout main
git pull origin main
git merge origin/develop --no-ff \
  -m "feat(JIRA-101): Add health check endpoint (#${PR_ID})"
git push origin main
```

Resultado esperado: push completado sin errores. Verifica que `main` tiene
los commits de develop:

```bash
git log origin/main --oneline -4
```

Cierra la terminal de carlos para eliminar las variables de entorno de su sesión.

---

## Paso 5 — Configurar las suscripciones de notificación

Antes de verificar que las notificaciones llegan, hay que suscribir al menos
un destino al SNS Topic. El laboratorio soporta dos canales opcionales
controlados por variables: `notification_email` y `slack_webhook_url`.
Aquí se configura el email, que es el más sencillo de probar.

### 5a — Configurar los destinos de notificación

Crea o edita el archivo `terraform.tfvars` en `labs/lab41/aws/` con los
destinos que quieras activar. Puedes usar uno o ambos:

```hcl
# Email — SNS envía el JSON crudo del evento
notification_email = "tu-email@ejemplo.com"

# Webhook HTTPS — útil para pruebas rápidas con https://webhook.site
# Abre webhook.site en el navegador, copia tu URL única y pégala aquí
slack_webhook_url = "https://webhook.site/<tu-uuid>"
```

Aplica el cambio — solo se añaden suscripciones SNS, el resto de la
infraestructura no cambia:

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — directorio labs/lab41/aws
terraform apply
```

> **Email**: SNS envía un mensaje de confirmación a la dirección indicada.
> Debes hacer clic en el enlace **"Confirm subscription"** antes de continuar
> — hasta entonces la suscripción está en `PendingConfirmation` y los mensajes
> no se entregarán.
>
> **webhook.site**: tras el apply, SNS envía una petición POST de confirmación
> a tu URL. Sigue estos pasos para confirmarla manualmente:
>
> 1. Abre webhook.site y localiza la petición con `"Type": "SubscriptionConfirmation"`.
> 2. En el body JSON, copia el valor del campo `SubscribeURL`:
>    ```json
>    {
>      "Type": "SubscriptionConfirmation",
>      "SubscribeURL": "https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&TopicArn=...&Token=...",
>      ...
>    }
>    ```
> 3. Pega esa URL en el navegador. SNS responde con un XML de confirmación y
>    la suscripción pasa de `PendingConfirmation` a `Confirmed`.
>
> Hasta que no completes este paso, SNS no entregará mensajes al webhook.

---

## Paso 6 — Verificar las notificaciones

### 6a — Verificar suscriptores del SNS Topic

```bash
SNS_ARN=$(terraform output -raw sns_topic_arn)

aws sns list-subscriptions-by-topic \
  --topic-arn "${SNS_ARN}" \
  --region us-east-1 \
  --query "Subscriptions[*].{Protocol:Protocol,Endpoint:Endpoint,Status:SubscriptionArn}" \
  --output table
```

La suscripción de email debe aparecer con `Status: arn:aws:sns:...` (confirmada)
o `PendingConfirmation` si aún no has hecho clic en el enlace del email.

### 6b — Publicar un mensaje de prueba en el SNS Topic

```bash
aws sns publish \
  --topic-arn "${SNS_ARN}" \
  --subject "TEST lab41 — Verificación de notificaciones" \
  --message '{"tipo": "prueba", "mensaje": "Notificacion de prueba del lab41", "repositorio": "platform-backend"}' \
  --region us-east-1
```

El mensaje debe llegar al email confirmado y/o aparecer en webhook.site
en pocos segundos.

### 6c — Verificar la regla de auditoría de EventBridge

La regla de EventBridge complementa a CodeStar Notifications cubriendo un
escenario que ésta no detecta: un administrador (o tech lead) que hace push
directo a `main` **sin pasar por un PR**. CodeStar solo emite eventos del
ciclo de vida del PR; EventBridge escucha directamente los eventos de estado
del repositorio que CodeCommit publica en el bus por defecto.

El comando muestra que la regla está activa y el patrón de eventos que filtra:

```bash
aws events describe-rule \
  --name "lab41-main-branch-write-audit" \
  --region us-east-1 \
  --query "{Estado:State,Patron:EventPattern}"
```

Resultado esperado:

```json
{
  "Estado": "ENABLED",
  "Patron": "{\"source\":[\"aws.codecommit\"],\"detail-type\":[\"CodeCommit Repository State Change\"],\"resources\":[\"arn:aws:codecommit:...\"],\"detail\":{\"event\":[\"referenceUpdated\",\"referenceCreated\"],\"referenceType\":[\"branch\"],\"referenceName\":[\"main\"]}}"
}
```

Cuando se produzca cualquier escritura en `main` — ya sea un push directo
del administrador o el merge del Paso 4 — EventBridge capturará el evento
y publicará en el SNS Topic un mensaje con el actor, el commit anterior y
el nuevo, y la hora UTC.

### 6d — Verificar la CodeStar Notification Rule

CodeStar Notifications es el canal nativo para el ciclo de vida de Pull
Requests: creación, actualización, merge, comentarios y cambios de estado
de aprobación. A diferencia de EventBridge, los eventos de PR incluyen
metadatos enriquecidos (título, rama origen/destino, autor, lista de
commits) sin necesidad de transformaciones adicionales.

El comando muestra que la regla está activa, el nivel de detalle configurado
(`FULL` incluye el contenido completo del evento) y el SNS Topic al que
publica:

```bash
aws codestar-notifications describe-notification-rule \
  --arn "$(terraform output -raw notification_rule_arn)" \
  --region us-east-1 \
  --query "{Nombre:Name,Estado:Status,DetallesTipo:DetailType,Targets:Targets}"
```

Resultado esperado:

```json
{
  "Nombre": "lab41-pr-notifications",
  "Estado": "ENABLED",
  "DetallesTipo": "FULL",
  "Targets": [
    {
      "TargetAddress": "arn:aws:sns:us-east-1:<ACCOUNT_ID>:lab41-pr-notifications",
      "TargetType": "SNS",
      "TargetStatus": "ACTIVE"
    }
  ]
}
```

Cada vez que alice abra un PR, carlos-lead lo apruebe o se complete un
merge, esta regla publicará automáticamente en el SNS Topic y el mensaje
llegará al email y/o webhook configurados en el Paso 5.

### 6e — Simular un push a main para disparar la alarma de EventBridge

> **IMPORTANTE**: Este paso usa las credenciales del administrador, NO las
> del usuario alice-dev (que tendría el Deny). Simula el escenario en que
> un administrador con permisos amplios hace un push directo a main, algo
> que debe quedar registrado como alerta de auditoría.

```bash
# Hacer un commit de prueba directamente en main vía API (sin git clone)
CURRENT=$(aws codecommit get-branch \
  --repository-name platform-backend \
  --branch-name main \
  --region us-east-1 \
  --query 'branch.commitId' \
  --output text)

TMPFILE=$(mktemp)
echo "# Commit de auditoría — prueba de notificación" > "$TMPFILE"
echo "Este archivo fue creado directamente en main para verificar la alarma." >> "$TMPFILE"

aws codecommit put-file \
  --repository-name platform-backend \
  --branch-name main \
  --file-path AUDIT_TEST.md \
  --file-content "fileb://$TMPFILE" \
  --parent-commit-id "$CURRENT" \
  --name "Admin Test" \
  --email "admin@empresa.com" \
  --commit-message "test: verify EventBridge audit notification" \
  --region us-east-1

rm -f "$TMPFILE"
echo "Commit directo en main realizado. Verifica que llega la alerta al SNS/Slack."
```

EventBridge captura el evento `referenceUpdated` en `main` y publica en SNS
un mensaje con el formato:
```
[AUDITORIA CODECOMMIT] Escritura en rama protegida | Repositorio: platform-backend |
Rama: main | Tipo: referenceUpdated | Actor: arn:aws:iam::<ID>:user/... | ...
```

## Verificación final

```bash
# Verificar que la rama main está protegida (push directo rechazado)
aws codecommit get-branch \
  --repository-name platform-backend \
  --branch-name main \
  --query 'branch.commitId' --output text

# Listar aprobaciones requeridas por el template
aws codecommit list-approval-rule-templates \
  --query 'approvalRuleTemplateNames' --output text

# Confirmar que la plantilla está asociada al repositorio
aws codecommit list-associated-approval-rule-templates-for-repository \
  --repository-name platform-backend \
  --query 'approvalRuleTemplateNames' --output text

# Verificar la suscripción SNS activa
aws sns list-subscriptions-by-topic \
  --topic-arn $(terraform output -raw notification_topic_arn) \
  --query 'Subscriptions[*].{Protocol:Protocol,Endpoint:Endpoint}' \
  --output table

# Comprobar que alice-dev no puede hacer push a main
aws iam simulate-principal-policy \
  --policy-source-arn $(aws iam get-user --user-name alice-dev \
      --query 'User.Arn' --output text) \
  --action-names codecommit:GitPush \
  --resource-arns "arn:aws:codecommit:us-east-1:$(aws sts get-caller-identity \
      --query Account --output text):platform-backend" \
  --context-entries contextKeyName=codecommit:References,contextKeyValues=refs/heads/main,contextKeyType=stringList \
  --query 'EvaluationResults[0].EvalDecision' --output text
# Esperado: explicitDeny
```

---

## Retos

### Reto 1 — Proteger también las ramas `release/*`

En GitFlow completo, además de `main` existe una rama `release/x.y.z` que
representa el código en proceso de preparación para producción. Esta rama
también debe estar protegida.

**Objetivo**: modificar la variable `protected_branches` para incluir
`release/*` y verificar que:

1. Un desarrollador no puede hacer push a `release/1.2.3`.
2. El Approval Rule Template también exige aprobación para PRs a `release/1.2.3`.

**Pasos**:

1. En tu entorno local, crea un archivo `terraform.tfvars` con:

```hcl
protected_branches = ["main", "release/*"]
```

2. Ejecuta `terraform plan` y observa los cambios:

```bash
terraform plan
```

Deberías ver que el Approval Rule Template y la política IAM cambian
(el contenido del JSON del template se actualiza con la nueva rama).
La infraestructura no se destruye ni recrea — solo se modifica en AWS.

3. Aplica el cambio:

```bash
terraform apply
```

4. Verifica con las credenciales reales de alice-dev que no puede hacer push
   a `release/1.2.3`. Desde la terminal de alice (con sus credenciales exportadas):

```bash
# ⚠️  TERMINAL DE ALICE — /tmp/platform-backend
git fetch origin
git checkout -b release/1.2.3 origin/develop

echo "release test" > release-test.txt
git add release-test.txt
git commit -m "test: verificacion proteccion release"
git push origin release/1.2.3
```

Resultado esperado: mismo `HTTP 403` que al intentar push a `main`.

Limpia la rama local:

```bash
git checkout develop
git branch -D release/1.2.3
```

5. Verifica que el template actualizado ahora cubre `release/*`:

```bash
aws codecommit get-approval-rule-template \
  --approval-rule-template-name "lab41-require-tech-lead-approval" \
  --region us-east-1 \
  --query "approvalRuleTemplate.approvalRuleTemplateContent"
```

---

### Reto 2 — Añadir un segundo tech lead al pool de aprobadores sin downtime

El equipo crece. Hay que incorporar a `elena-lead` como líder técnica sin
recrear el repositorio ni modificar el Approval Rule Template.

**Objetivo**: añadir `"elena-lead"` al grupo de tech leads y verificar,
abriendo una sesión con su usuario, que puede asumir el rol de aprobador
y clonar el repositorio.

**Pasos**:

1. Añade `"elena-lead"` a la lista de tech leads en `terraform.tfvars`.
2. Ejecuta `terraform plan` y presta atención a qué recursos cambian y
   cuáles no.
3. Aplica el cambio.
4. Crea una access key para `elena-lead`, abre una nueva terminal con sus
   credenciales y verifica que puede asumir el rol `lab41-tech-lead-approver`.

---

### Reto 3 — Implementar `min_approvals_required = 2` para un equipo mayor

El equipo de plataforma ha crecido y la política de seguridad ahora exige que
**dos** líderes técnicos aprueben cada cambio a main (four-eyes principle).

**Objetivo**: cambiar `min_approvals_required` a 2 y verificar que el template
se actualiza correctamente.

1. Actualiza la variable:

```hcl
min_approvals_required = 2
```

2. Ejecuta `terraform plan`. El template debe mostrar:
   - `~ content` con `"NumberOfApprovalsNeeded": 2` en el nuevo JSON.

3. Aplica y crea un PR de prueba. Intenta hacer merge con una sola aprobación:

```bash
# Crear rama y PR de prueba (como alice)
git checkout -b feature/reto3-test origin/develop
echo "reto3" > reto3.txt
git add reto3.txt && git commit -m "test: reto3 four-eyes"
git push origin feature/reto3-test

aws codecommit create-pull-request \
  --title "Reto 3: four-eyes test" \
  --targets "repositoryName=platform-backend,sourceReference=feature/reto3-test,destinationReference=main" \
  --region us-east-1

# Obtener PR_ID y REVISION_ID
PR_ID=$(aws codecommit list-pull-requests \
  --repository-name platform-backend \
  --pull-request-status OPEN \
  --query 'pullRequestIds[0]' \
  --output text \
  --region us-east-1)

REVISION_ID=$(aws codecommit get-pull-request \
  --pull-request-id "${PR_ID}" \
  --query 'pullRequest.revisionId' \
  --output text \
  --region us-east-1)

echo "PR_ID=${PR_ID}  REVISION_ID=${REVISION_ID}"

# Aprobar con carlos-lead (asumiendo el rol — ver Paso 4b y 4c del laboratorio)
# ...

aws codecommit evaluate-pull-request-approval-rules \
  --pull-request-id "${PR_ID}" \
  --revision-id "${REVISION_ID}" \
  --region us-east-1
# "approvalRulesNotSatisfied": ["lab41-require-tech-lead-approval"]
# approved: false
```

4. Aprueba también con diana-lead (asumiendo el mismo rol con una sesión distinta)
   y verifica que con dos aprobaciones el merge queda habilitado.

---

## Soluciones

<details>
<summary>Reto 1 — Proteger ramas release/*</summary>

**Crear `terraform.tfvars`**:

```hcl
protected_branches = ["main", "release/*"]
```

**Verificar el plan**:

```bash
terraform plan
# Muestra:
#   ~ resource "aws_codecommit_approval_rule_template" "tech_lead_required"
#       ~ content = jsonencode(...)   # DestinationReferences actualizado
#   ~ resource "aws_iam_policy" "developer_codecommit"
#       ~ policy = jsonencode(...)    # Condition actualizada con refs/heads/release/*
```

**Aplicar**:

```bash
terraform apply
# Plan: 0 to add, 2 to change, 0 to destroy.
```

**Verificar con git usando las credenciales de alice**:

```bash
# ⚠️  TERMINAL DE ALICE — /tmp/platform-backend
git fetch origin
git checkout -b release/1.2.3 origin/develop

echo "release test" > release-test.txt
git add release-test.txt
git commit -m "test: verificacion proteccion release"
git push origin release/1.2.3
# Resultado esperado: HTTP 403 — explicit deny

# Limpiar
git checkout develop
git branch -D release/1.2.3
```

</details>

<details>
<summary>Reto 2 — Añadir elena-lead sin recrear el template</summary>

**Actualizar `variables.tf` o `terraform.tfvars`**:

```hcl
tech_lead_usernames = ["carlos-lead", "diana-lead", "elena-lead"]
```

**Plan esperado**:

```bash
terraform plan
# Plan: 3 to add, 0 to change, 0 to destroy.
#
# + aws_iam_user.tech_lead["elena-lead"]
# + aws_iam_user_group_membership.tech_lead["elena-lead"]
#
# Recursos NO afectados:
#   aws_codecommit_approval_rule_template.tech_lead_required  (no changes)
#   aws_iam_role.tech_lead                                    (no changes)
#   aws_iam_role_policy_attachment.tech_lead_approver_codecommit (no changes)
```

**Razón**: La Trust Policy del rol referencia los ARNs de los usuarios del
`for_each`. Añadir a elena-lead sí actualiza la Trust Policy del rol
(`~ assume_role_policy`), pero el Approval Rule Template en sí no cambia
porque el template referencia el ARN del rol, no de los usuarios.

```bash
terraform apply
```

**Verificar en la consola de IAM que elena-lead tiene la membresía y los permisos correctos**:

Navega a **IAM → Users → elena-lead → Groups** y confirma que pertenece al
grupo `lab41-tech-leads`. En la pestaña **Permissions** verás las políticas
heredadas del grupo:

- `lab41-tech-lead-codecommit` — acceso completo al repositorio
- `lab41-assume-tech-lead-approver` — permiso para asumir el rol de aprobador

Sin estas políticas heredadas, elena-lead no podría ni clonar el repositorio
ni asumir el rol.

**Crear la access key para elena-lead y abrir una nueva terminal**:

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR
KEY_JSON=$(aws iam create-access-key --user-name elena-lead)
echo "Access Key ID:     $(echo $KEY_JSON | jq -r '.AccessKey.AccessKeyId')"
echo "Secret Access Key: $(echo $KEY_JSON | jq -r '.AccessKey.SecretAccessKey')"
ROLE_ARN=$(terraform output -raw tech_lead_approver_role_arn)
CLONE_URL=$(terraform output -raw repository_clone_url_http)
```

**Verificar que elena-lead puede asumir el rol y clonar el repositorio**:

```bash
# ⚠️  NUEVA TERMINAL — elena-lead
export AWS_ACCESS_KEY_ID="<AccessKeyId>"
export AWS_SECRET_ACCESS_KEY="<SecretAccessKey>"
export AWS_DEFAULT_REGION="us-east-1"

aws sts get-caller-identity --query 'Arn' --output text
# arn:aws:iam::<ID>:user/platform/tech-leads/elena-lead

CREDS=$(aws sts assume-role \
  --role-arn "<ROLE_ARN>" \
  --role-session-name "elena-test-$(date +%s)" \
  --duration-seconds 900 \
  --query "Credentials" --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r '.SessionToken')

aws sts get-caller-identity --query 'Arn' --output text
# arn:aws:sts::<ID>:assumed-role/lab41-tech-lead-approver/elena-test-...

git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
git clone "<CLONE_URL>" /tmp/platform-backend-elena
# Clone exitoso — elena-lead tiene acceso completo al repositorio
```

</details>

<details>
<summary>Reto 3 — Four-eyes principle con 2 aprobaciones</summary>

**Actualizar la variable**:

```hcl
min_approvals_required = 2
```

**Plan**:

```bash
terraform plan
# ~ aws_codecommit_approval_rule_template.tech_lead_required
#     ~ content: "NumberOfApprovalsNeeded": 1 → 2
```

**Crear rama y PR de prueba (como alice)**:

```bash
git checkout -b feature/reto3-test origin/develop
echo "reto3" > reto3.txt
git add reto3.txt && git commit -m "test: reto3 four-eyes"
git push origin feature/reto3-test

aws codecommit create-pull-request \
  --title "Reto 3: four-eyes test" \
  --targets "repositoryName=platform-backend,sourceReference=feature/reto3-test,destinationReference=main" \
  --region us-east-1

# Obtener PR_ID y REVISION_ID
PR_ID=$(aws codecommit list-pull-requests \
  --repository-name platform-backend \
  --pull-request-status OPEN \
  --query 'pullRequestIds[0]' \
  --output text \
  --region us-east-1)

REVISION_ID=$(aws codecommit get-pull-request \
  --pull-request-id "${PR_ID}" \
  --query 'pullRequest.revisionId' \
  --output text \
  --region us-east-1)

echo "PR_ID=${PR_ID}  REVISION_ID=${REVISION_ID}"
```

**Flujo de doble aprobación vía CLI**:

```bash
# Aprobación 1: carlos-lead
CREDS1=$(aws sts assume-role \
  --role-arn "${ROLE_ARN}" \
  --role-session-name "approve-carlos-$(date +%s)" \
  --duration-seconds 900 \
  --query "Credentials" --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS1 | jq -r '.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS1 | jq -r '.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS1 | jq -r '.SessionToken')

aws codecommit update-pull-request-approval-state \
  --pull-request-id "${PR_ID}" \
  --revision-id "${REVISION_ID}" \
  --approval-state APPROVE \
  --region us-east-1

echo "Primera aprobación registrada: $(aws sts get-caller-identity --query Arn --output text)"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# Verificar que todavía falta una aprobación
aws codecommit evaluate-pull-request-approval-rules \
  --pull-request-id "${PR_ID}" \
  --revision-id "${REVISION_ID}" \
  --region us-east-1 \
  --query "evaluation.approved"
# false — falta la segunda aprobación

# Aprobación 2: diana-lead (mismo rol, diferente session name)
CREDS2=$(aws sts assume-role \
  --role-arn "${ROLE_ARN}" \
  --role-session-name "approve-diana-$(date +%s)" \
  --duration-seconds 900 \
  --query "Credentials" --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS2 | jq -r '.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS2 | jq -r '.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $CREDS2 | jq -r '.SessionToken')

aws codecommit update-pull-request-approval-state \
  --pull-request-id "${PR_ID}" \
  --revision-id "${REVISION_ID}" \
  --approval-state APPROVE \
  --region us-east-1

# Verificar aprobación completa
aws codecommit evaluate-pull-request-approval-rules \
  --pull-request-id "${PR_ID}" \
  --revision-id "${REVISION_ID}" \
  --region us-east-1 \
  --query "evaluation.approved"
# true

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

> **Limitación del pool con un solo rol**: cuando dos personas asumen el
> mismo rol, CodeCommit puede no contar las dos aprobaciones como distintas
> si los session names son demasiado similares. Para two-person integrity
> real, considera definir dos roles separados en el pool (`carlos-approver`
> y `diana-approver`), o usa Conditional Access con `SamlProvider` en entornos
> con SSO.

</details>

---

## Limpieza

Terraform no puede eliminar usuarios IAM que tengan access keys activas.
Hay que borrarlas antes de ejecutar `destroy`.

```bash
cd labs/lab41/aws

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"

# Eliminar todas las access keys de los usuarios creados en el lab
for USER in alice-dev bob-dev carlos-lead diana-lead; do
  for KEY_ID in $(aws iam list-access-keys --user-name "${USER}" \
      --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "${USER}" --access-key-id "${KEY_ID}"
    echo "Clave ${KEY_ID} eliminada de ${USER}"
  done
done

terraform destroy \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"
```

> **ADVERTENCIA**: `terraform destroy` eliminará el repositorio CodeCommit
> y **todo su contenido** (commits, ramas, Pull Requests). Asegúrate de
> haber completado todos los pasos y retos antes de ejecutar destroy.

Limpieza de los repositorios git locales clonados durante el lab:

```bash
rm -rf /tmp/platform-backend
rm -rf /tmp/platform-backend-lead
rm -rf /tmp/platform-backend-elena   # si se realizó el Reto 2
git config --global --unset credential.helper
git config --global --unset credential.UseHttpPath
```

---

## Buenas prácticas aplicadas

- **Principio de mínimo privilegio con Deny explícito**: usar `Deny` en vez
  de simplemente no conceder `Allow` garantiza que ninguna política adicional
  pueda sobreescribir la restricción de acceso a `main`.
- **Separation of Duties en IAM**: los roles `developer` y `lead` tienen
  permisos completamente separados. Un desarrollador nunca puede aprobar su
  propio Pull Request.
- **Approval Rule Templates reutilizables**: definir la plantilla una sola
  vez y asociarla a repositorios permite escalar la gobernanza sin duplicar
  configuración.
- **Notificaciones reactivas con EventBridge y SNS**: complementar los
  controles preventivos con alertas en tiempo real asegura auditoría continua
  aunque alguien encontrase un bypass.
- **Infrastructure as Code para la gobernanza misma**: las reglas de
  protección de rama, los usuarios IAM y las suscripciones SNS se gestionan
  con Terraform, garantizando que la gobernanza es reproducible y versionada.
- **Two-person integrity**: exigir al menos una aprobación de un segundo
  individuo antes de mergear a `main` cumple el principio de cuatro ojos
  requerido en entornos de producción regulados.

---

## Recursos

- [AWS CodeCommit — Approval Rule Templates](https://docs.aws.amazon.com/codecommit/latest/userguide/approval-rule-templates.html)
- [AWS CodeCommit — Restricciones de rama con IAM](https://docs.aws.amazon.com/codecommit/latest/userguide/how-to-conditional-branch.html)
- [AWS CodeStar Notifications](https://docs.aws.amazon.com/dtconsole/latest/userguide/welcome.html)
- [Amazon SNS — Suscripciones y filtraje de mensajes](https://docs.aws.amazon.com/sns/latest/dg/sns-message-filtering.html)
- [Amazon EventBridge — Reglas de eventos](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rules.html)
- [IAM — Política de privilegio mínimo](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html#grant-least-privilege)
- [Terraform aws_codecommit_repository](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codecommit_repository)
- [Terraform aws_codecommit_approval_rule_template](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codecommit_approval_rule_template)
