# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Identidades y politicas de acceso para CodeCommit
# ═══════════════════════════════════════════════════════════════════════════════
#
# Estructura de identidades:
#
#   Usuarios IAM
#   ├── alice-dev, bob-dev          → grupo platform-developers
#   └── carlos-lead, diana-lead     → grupo platform-tech-leads
#
#   Grupos IAM
#   ├── platform-developers
#   │   └── politica: developer-codecommit  (allow lectura + push a ramas de trabajo)
#   │                                       (DENY explicito a ramas protegidas)
#   └── platform-tech-leads
#       ├── politica: tech-lead-codecommit  (acceso completo al repositorio)
#       └── politica: assume-tech-lead-approver (sts:AssumeRole sobre el rol de aprobacion)
#
#   Rol IAM — platform-tech-lead-approver
#   └── Referenciado en el Approval Rule Template como pool de aprobadores.
#       Los tech leads lo asumen con sts:AssumeRole para aprobar PRs via CLI.

# ── Usuarios IAM del equipo de desarrollo ─────────────────────────────────────
resource "aws_iam_user" "developer" {
  for_each = toset(var.developer_usernames)

  name = each.key
  path = "/platform/developers/"

  tags = {
    Project   = var.project
    Team      = "developers"
    ManagedBy = "terraform"
  }
}

# ── Usuarios IAM del equipo de lideres tecnicos ───────────────────────────────
resource "aws_iam_user" "tech_lead" {
  for_each = toset(var.tech_lead_usernames)

  name = each.key
  path = "/platform/tech-leads/"

  tags = {
    Project   = var.project
    Team      = "tech-leads"
    ManagedBy = "terraform"
  }
}

# ── Grupos IAM ────────────────────────────────────────────────────────────────
resource "aws_iam_group" "developers" {
  name = "${var.project}-developers"
  path = "/platform/"
}

resource "aws_iam_group" "tech_leads" {
  name = "${var.project}-tech-leads"
  path = "/platform/"
}

# ── Membresías de grupo ───────────────────────────────────────────────────────
resource "aws_iam_user_group_membership" "developer" {
  for_each = toset(var.developer_usernames)

  user   = each.key
  groups = [aws_iam_group.developers.name]

  depends_on = [aws_iam_user.developer, aws_iam_group.developers]
}

resource "aws_iam_user_group_membership" "tech_lead" {
  for_each = toset(var.tech_lead_usernames)

  user   = each.key
  groups = [aws_iam_group.tech_leads.name]

  depends_on = [aws_iam_user.tech_lead, aws_iam_group.tech_leads]
}

# ── Politica IAM de privilegio minimo para desarrolladores ────────────────────
#
# Diseno de la politica (principio del menor privilegio):
#
# CAPA ALLOW:
#   1. Lectura completa del repositorio (GitPull, Get*, List*, Describe*).
#      Sin restriccion de rama — clonar y navegar el historial es libre.
#
#   2. Push a ramas de trabajo: develop, feature/*, bugfix/*, hotfix/*.
#      La condicion StringLike filtra por el ref exacto que CodeCommit
#      envia en el contexto de la peticion.
#
#   3. Borrado de ramas de trabajo propias (feature/*, bugfix/*, hotfix/*).
#      NO incluye develop — esa rama es compartida y persistente.
#
#   4. Operaciones de Pull Request: crear, actualizar, comentar.
#      Un PR no bypasea la proteccion de rama; es solo una solicitud de
#      revision que el tech lead decidira si aprobar o rechazar.
#
# CAPA DENY (invalida cualquier Allow):
#   5. Push/merge/delete directo a ramas protegidas (main, release/*, etc.).
#      El Deny explicito es la barrera definitiva: aunque una politica de
#      administrador otorgue un Allow mas amplio al grupo, este Deny
#      tiene precedencia porque IAM evalua Deny antes que Allow.
#
#   6. Modificar reglas de aprobacion del repositorio.
#      Impide que un desarrollador elimine o anule la Approval Rule
#      adjuntada automaticamente por el template.

data "aws_iam_policy_document" "developer_codecommit" {
  # ── Allow: operaciones de lectura ────────────────────────────────────────
  statement {
    sid    = "AllowRead"
    effect = "Allow"

    actions = [
      "codecommit:BatchGet*",
      "codecommit:BatchDescribe*",
      "codecommit:Get*",
      "codecommit:Describe*",
      "codecommit:List*",
      "codecommit:GitPull",
    ]

    resources = [aws_codecommit_repository.this.arn]
  }

  # ── Allow: push y creacion de archivos — sin condicion de rama ───────────
  #
  # El Allow NO lleva condicion de rama. Esto es intencional:
  #
  # Cuando git ejecuta el handshake HTTP (GET /info/refs?service=git-receive-pack),
  # CodeCommit evalua el permiso GitPush antes de que el cliente haya indicado
  # a que rama va a hacer push. En ese momento el contexto 'codecommit:References'
  # NO existe. Un Allow condicionado con StringLike evalua a false si la clave
  # esta ausente → implicit deny → HTTP 403 en TODAS las ramas.
  #
  # El patron correcto para proteccion de ramas en CodeCommit es:
  #   Allow GitPush sin condicion  → habilita la capacidad
  #   Deny  GitPush con condicion  → bloquea las ramas protegidas
  #
  # La proteccion real la proporciona el Deny explicito de mas abajo,
  # que si se evalua con contexto de rama y prevalece sobre cualquier Allow.
  statement {
    sid    = "AllowPushOperations"
    effect = "Allow"

    actions = [
      "codecommit:GitPush",
      "codecommit:PutFile",
      "codecommit:CreateBranch",
    ]

    resources = [aws_codecommit_repository.this.arn]
  }

  # ── Allow: borrar ramas de trabajo (no develop, que es compartida) ────────
  statement {
    sid    = "AllowDeleteOwnWorkBranches"
    effect = "Allow"

    actions = ["codecommit:DeleteBranch"]

    resources = [aws_codecommit_repository.this.arn]

    condition {
      test     = "StringLike"
      variable = "codecommit:References"
      values = [
        "refs/heads/feature/*",
        "refs/heads/bugfix/*",
        "refs/heads/hotfix/*",
      ]
    }
  }

  # ── Allow: operaciones de Pull Request ───────────────────────────────────
  #
  # Crear y gestionar PRs no implica acceso a las ramas protegidas en si.
  # El merge del PR lo controla el Approval Rule Template.
  statement {
    sid    = "AllowPullRequestOperations"
    effect = "Allow"

    actions = [
      "codecommit:CreatePullRequest",
      "codecommit:UpdatePullRequest*",
      "codecommit:PostCommentFor*",
      "codecommit:PostCommentReply",
      "codecommit:UpdateComment",
      "codecommit:DeleteCommentContent",
    ]

    resources = [aws_codecommit_repository.this.arn]
  }

  # ── DENY: push directo y merge a ramas protegidas ────────────────────────
  #
  # Se usa StringLike (no StringLikeIfExists) porque todas las acciones de
  # escritura listadas abajo incluyen SIEMPRE la clave codecommit:References
  # en el contexto real de la peticion. StringLike es mas preciso:
  #
  #   - El Deny solo aplica cuando el ref coincide con una rama protegida.
  #   - Con StringLikeIfExists, si la clave no existiese (edge case), la
  #     condicion seria TRUE y se denegarian todas las acciones del listado
  #     sin importar la rama — efecto no deseado.
  #   - Con StringLike, el simulador IAM (simulate-principal-policy) muestra
  #     correctamente "explicitDeny" al pasar el context-entry de la rama.
  #
  # La lista cubre TODOS los vectores de escritura a ramas protegidas:
  #   - GitPush             : push de git desde la linea de comandos
  #   - PutFile             : API REST de CodeCommit (consola web)
  #   - MergeBy*            : merge de ramas desde la consola o CLI
  #   - MergePullRequestBy* : merge del PR una vez aprobado
  #   - DeleteBranch        : borrar main accidentalmente
  statement {
    sid    = "DenyDirectWriteToProtectedBranches"
    effect = "Deny"

    actions = [
      "codecommit:GitPush",
      "codecommit:PutFile",
      "codecommit:DeleteBranch",
      "codecommit:MergeBranchesByFastForward",
      "codecommit:MergeBranchesBySquash",
      "codecommit:MergeBranchesByThreeWay",
      "codecommit:MergePullRequestByFastForward",
      "codecommit:MergePullRequestBySquash",
      "codecommit:MergePullRequestByThreeWay",
    ]

    resources = [aws_codecommit_repository.this.arn]

    condition {
      test     = "StringLike"
      variable = "codecommit:References"
      values   = [for b in var.protected_branches : "refs/heads/${b}"]
    }
  }

  # ── DENY: modificar o anular las reglas de aprobacion ────────────────────
  #
  # Sin este bloque, un desarrollador podria:
  #   a) Crear una Approval Rule propia en el PR con 0 aprobaciones requeridas
  #   b) Anular las reglas existentes con OverridePullRequestApprovalRules
  # Esto dejaria el Approval Rule Template sin efecto.
  statement {
    sid    = "DenyModifyApprovalRules"
    effect = "Deny"

    actions = [
      "codecommit:CreatePullRequestApprovalRule",
      "codecommit:DeletePullRequestApprovalRule",
      "codecommit:UpdatePullRequestApprovalRuleContent",
      "codecommit:UpdatePullRequestApprovalRuleStatus",
      "codecommit:OverridePullRequestApprovalRules",
    ]

    resources = [aws_codecommit_repository.this.arn]
  }
}

resource "aws_iam_policy" "developer_codecommit" {
  name        = "${var.project}-developer-codecommit"
  path        = "/platform/"
  description = "Privilegio minimo: lectura libre, push a ramas de trabajo, Deny a ramas protegidas y reglas de aprobacion. Lab41."
  policy      = data.aws_iam_policy_document.developer_codecommit.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_iam_group_policy_attachment" "developer_codecommit" {
  group      = aws_iam_group.developers.name
  policy_arn = aws_iam_policy.developer_codecommit.arn
}

# ── Politica IAM para lideres tecnicos ───────────────────────────────────────
#
# Los tech leads tienen acceso completo al repositorio.
# Aunque puedan hacer push directo a main (necesario para hotfixes urgentes),
# el Approval Rule Template les exige que no se auto-aprueben.
# Esta politica tambien permite listar repositorios en la consola.
data "aws_iam_policy_document" "tech_lead_codecommit" {
  statement {
    sid    = "FullRepositoryAccess"
    effect = "Allow"

    actions   = ["codecommit:*"]
    resources = [aws_codecommit_repository.this.arn]
  }

  statement {
    sid    = "AllowListRepositories"
    effect = "Allow"

    actions   = ["codecommit:ListRepositories"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "tech_lead_codecommit" {
  name        = "${var.project}-tech-lead-codecommit"
  path        = "/platform/"
  description = "Acceso completo al repositorio para lideres tecnicos. Lab41."
  policy      = data.aws_iam_policy_document.tech_lead_codecommit.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_iam_group_policy_attachment" "tech_lead_codecommit" {
  group      = aws_iam_group.tech_leads.name
  policy_arn = aws_iam_policy.tech_lead_codecommit.arn
}

# ── Rol IAM de aprobador — pool del Approval Rule Template ───────────────────
#
# El Approval Rule Template referencia este rol como pool de aprobadores.
# Los tech leads asumen el rol con sts:AssumeRole para que CodeCommit
# identifique su accion de aprobacion como perteneciente al pool autorizado.
#
# Flujo de aprobacion con CLI:
#   1. carlos-lead obtiene credenciales del rol:
#        aws sts assume-role \
#          --role-arn arn:aws:iam::<ID>:role/lab41-tech-lead-approver \
#          --role-session-name "approve-pr-123"
#
#   2. Exporta las credenciales temporales:
#        export AWS_ACCESS_KEY_ID=...
#        export AWS_SECRET_ACCESS_KEY=...
#        export AWS_SESSION_TOKEN=...
#
#   3. Aprueba el PR:
#        aws codecommit update-pull-request-approval-state \
#          --pull-request-id 1 \
#          --revision-id <rev> \
#          --approval-state APPROVE
#
#   4. Verifica que se habilito el merge:
#        aws codecommit evaluate-pull-request-approval-rules \
#          --pull-request-id 1 \
#          --revision-id <rev>
#
# La condicion aws:RequestedRegion limita el alcance del rol a la region
# del laboratorio, reduciendo el radio de impacto de credenciales filtradas.
resource "aws_iam_role" "tech_lead" {
  name        = "${var.project}-tech-lead-approver"
  path        = "/platform/"
  description = "Rol que los lideres tecnicos asumen para aprobar Pull Requests. Lab41."

  assume_role_policy = data.aws_iam_policy_document.tech_lead_assume_role.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "codecommit-pr-approver"
  }
}

data "aws_iam_policy_document" "tech_lead_assume_role" {
  statement {
    sid    = "AllowTechLeadsToAssume"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [for u in aws_iam_user.tech_lead : u.arn]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

resource "aws_iam_role_policy_attachment" "tech_lead_approver_codecommit" {
  role       = aws_iam_role.tech_lead.name
  policy_arn = aws_iam_policy.tech_lead_codecommit.arn
}

# ── Politica para asumir el rol de aprobador ──────────────────────────────────
#
# Los tech leads necesitan permiso explicito de sts:AssumeRole para
# asumir el rol de aprobador. Este permiso se adjunta a su grupo IAM
# en lugar de a usuarios individuales, facilitando la incorporacion
# de nuevos lideres sin modificar politicas.
data "aws_iam_policy_document" "assume_tech_lead_approver" {
  statement {
    sid    = "AllowAssumeApproverRole"
    effect = "Allow"

    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.tech_lead.arn]
  }
}

resource "aws_iam_policy" "assume_tech_lead_approver" {
  name        = "${var.project}-assume-tech-lead-approver"
  path        = "/platform/"
  description = "Permite a los tech leads asumir el rol de aprobador de PRs en CodeCommit. Lab41."
  policy      = data.aws_iam_policy_document.assume_tech_lead_approver.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

resource "aws_iam_group_policy_attachment" "assume_tech_lead_approver" {
  group      = aws_iam_group.tech_leads.name
  policy_arn = aws_iam_policy.assume_tech_lead_approver.arn
}
