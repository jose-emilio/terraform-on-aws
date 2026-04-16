# Sección 2 — Políticas IAM con Terraform

> [← Sección anterior](./01_iam_identidades.md) | [Siguiente →](./03_kms_cifrado.md)

---

## 2.1 IAM Policies: El Lenguaje de los Permisos

Una política IAM es un documento JSON que define **QUÉ** acciones están permitidas o denegadas sobre **QUÉ** recursos y bajo **QUÉ** condiciones. Tiene cuatro componentes:

| Elemento | Descripción | Ejemplo |
|---------|------------|---------|
| `Effect` | `Allow` o `Deny`. Define si la regla permite o bloquea | `Allow` |
| `Action` | Operaciones permitidas | `s3:GetObject`, `ec2:RunInstances` |
| `Resource` | ARN del recurso objetivo | `arn:aws:s3:::mi-bucket/*` |
| `Condition` | Filtros opcionales | IP, región, tags, MFA |

---

## 2.2 Managed vs. Inline Policies

Terraform soporta dos formas de adjuntar políticas a identidades:

| Aspecto | Managed Policy | Inline Policy |
|---------|---------------|---------------|
| Reutilización | ✅ Adjuntable a múltiples identidades | ❌ Relación 1:1 |
| Versionado | ✅ Automático (hasta 5 versiones) | ❌ No |
| Visibilidad | ✅ Visible en consola como entidad | ❌ Solo dentro de la identidad |
| Al eliminar identidad | Permanece intacta | Se borra con ella |
| Recursos Terraform | `aws_iam_policy` + `aws_iam_role_policy_attachment` | `aws_iam_role_policy` |

> **Regla:** Usa siempre Managed Policies. Las Inline Policies son difíciles de auditar y no se pueden reutilizar.

---

## 2.3 `aws_iam_policy_document`: El Flujo Profesional

El Data Source `aws_iam_policy_document` genera JSON dinámico con **validación de tipos**. Es superior a escribir JSON puro:

| JSON Puro (heredoc) | Data Source (HCL) |
|--------------------|------------------|
| Errores de sintaxis silenciosos | Validación en `terraform plan` |
| Sin autocompletado ni validación | Tipos nativos de Terraform |
| Interpolación propensa a errores | Composición de múltiples statements |
| Difícil de componer dinámicamente | Referencia directa a otros recursos HCL |

**Código: Policy Document con Data Source**

```hcl
# Data Source: genera JSON dinámico y validado
data "aws_iam_policy_document" "s3_read" {
  statement {
    sid     = "AllowS3Read"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.bucket_name}",
      "arn:aws:s3:::${var.bucket_name}/*"
    ]
  }
}

# Política Managed usando el Data Source
resource "aws_iam_policy" "s3_read" {
  name   = "s3-read-policy"
  policy = data.aws_iam_policy_document.s3_read.json
}
```

---

## 2.4 Precisión en la Definición de Recursos

El uso de comodines (`*`) en `Action` o `Resource` viola el principio de mínimo privilegio:

| Nivel | Definición | Riesgo |
|-------|-----------|--------|
| ❌ **Peligroso** | `Resource: "*"` + `Action: "s3:*"` | Acceso total a todos los buckets S3 |
| ⚠️ **Mejor** | `Resource: "arn:...bucket"` + `Action: "s3:*"` | Todas las acciones pero solo en un bucket |
| ✅ **Óptimo** | `Resource: "arn:...bucket/*"` + `Action: "s3:GetObject"` | Solo lectura en un bucket específico |

**Código: Política Granular de Recursos**

```hcl
# Solo PutItem en una tabla DynamoDB específica
data "aws_iam_policy_document" "dynamo_write" {
  statement {
    sid    = "AllowDynamoPut"
    effect = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [
      "arn:aws:dynamodb:${var.region}:${var.account_id}:table/${var.table_name}"
    ]
  }
}
```

---

## 2.5 Condiciones Avanzadas I: `StringEquals` y `ArnLike`

Las condiciones añaden filtros lógicos a los statements. El permiso solo se concede si **todas** las condiciones se cumplen:

**`StringEquals` — comparación exacta:**
- Restringir a una región: `aws:RequestedRegion = "eu-west-1"`
- Validar un tag específico
- Requerir MFA activo

**`ArnLike` — coincidencia con comodines en ARNs:**
- Filtrar por cuenta de origen
- Validar roles con patrón
- Restringir acceso por servicio

**Código: Política Condicional por Región**

```hcl
# Solo permitir EC2 en eu-west-1
data "aws_iam_policy_document" "ec2_region" {
  statement {
    sid       = "AllowEC2InRegion"
    effect    = "Allow"
    actions   = ["ec2:RunInstances", "ec2:TerminateInstances"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["eu-west-1"]
    }
  }
}
```

---

## 2.6 Condiciones Avanzadas II: ABAC — Permisos Basados en Etiquetas

ABAC (Attribute-Based Access Control) permite escalar permisos sin tocar las políticas: añadir un tag a un recurso o un usuario es suficiente para cambiar sus permisos.

**`IpAddress` — restricción por rango CIDR:**
```hcl
condition {
  test     = "IpAddress"
  variable = "aws:SourceIp"
  values   = ["10.0.0.0/8"]   # Solo desde la VPN corporativa
}
```

**ABAC por tags — permisos dinámicos:**
```hcl
condition {
  test     = "StringEquals"
  variable = "aws:ResourceTag/Owner"
  values   = ["${aws:username}"]   # Solo puede tocar recursos que le pertenecen
}
```

**Código: ABAC — Solo Terminar Instancias Propias**

```hcl
# Solo terminar instancias cuyo tag Owner = usuario activo
data "aws_iam_policy_document" "abac_owner" {
  statement {
    sid       = "TerminateOwnInstances"
    effect    = "Allow"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Owner"
      values   = ["${aws:username}"]
    }
  }
}
```

---

## 2.7 Permission Boundaries: El Techo de Permisos

Un **Permission Boundary** no otorga permisos — define el **techo máximo**. El permiso efectivo es la intersección entre la política asignada y el boundary:

```
Política Asignada          Boundary                   Efectivo
• ec2:RunInstances    ∩    • ec2:*              =      ✅ ec2:Run
• s3:GetObject             • s3:Get*                   ✅ s3:Get
• iam:CreateUser           (No iam:* ni rds:*)         ❌ iam:Create
• rds:DeleteDB                                         ❌ rds:Delete
```

**Código: Permission Boundary en Terraform**

```hcl
# Boundary: solo EC2 y S3
data "aws_iam_policy_document" "boundary" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:*", "s3:*", "cloudwatch:*"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name   = "dev-boundary"
  policy = data.aws_iam_policy_document.boundary.json
}

# Asignar boundary al usuario junior
resource "aws_iam_user" "dev" {
  name                 = "junior-dev"
  permissions_boundary = aws_iam_policy.boundary.arn
}
```

---

## 2.8 Service Control Policies (SCP)

Las SCPs son barreras de la organización que limitan qué acciones son posibles en las cuentas hijas. Se heredan de arriba hacia abajo en la jerarquía de OUs:

```
Organization
└── SCP Root
    └── OU: Desarrollo (SCP + Herencia)
        └── Cuenta: dev-01 (Permiso efectivo)
```

Características clave:
- Se heredan de arriba hacia abajo en la jerarquía de OUs
- Requieren AWS Organizations con "All Features" habilitado
- **No afectan a la cuenta de administración** (management account)
- Se gestionan con `aws_organizations_policy` en Terraform

**Código: SCP que Bloquea Todas las Regiones Excepto EU**

```hcl
resource "aws_organizations_policy" "deny_regions" {
  name = "deny-non-eu-regions"
  type = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonEURegions"
      Effect    = "Deny"
      Action    = "*"
      Resource  = "*"
      Condition = {
        StringNotEquals = {
          "aws:RequestedRegion" = ["eu-west-1"]
        }
      }
    }]
  })
}
```

---

## 2.9 El Flujo de Evaluación de Permisos

AWS evalúa cada solicitud API en un orden específico. Si algún nivel deniega, el resultado es DENY aunque otro nivel permita:

```
1. SCP           → Límites de la Organización
2. Boundary      → Techo máximo del usuario/rol
3. Identity      → Política asignada al usuario/rol
4. Resource      → Política del recurso (S3, KMS...)
5. Session       → Política de sesión (AssumeRole)

Regla de oro: Deny explícito SIEMPRE gana sobre cualquier Allow
```

**Casos importantes:**
- Deny explícito en cualquier nivel = acceso denegado (sin excepciones)
- Si ningún nivel deniega: se necesita Allow en todos los niveles aplicables
- Sin política explícita = deny implícito (deny por defecto)
- La cuenta de management está exenta de SCPs

---

## 2.10 Deny Explícito: El Candado Absoluto

Aun si una política permite una acción, un `Deny` explícito en cualquier otra política la bloquea. Es la herramienta definitiva para proteger recursos críticos:

**Código: Deny para Proteger Tablas DynamoDB de Producción**

```hcl
data "aws_iam_policy_document" "protect_prod" {
  statement {
    sid    = "DenyDeleteProdTables"
    effect = "Deny"
    actions = [
      "dynamodb:DeleteTable",
      "dynamodb:DeleteBackup"
    ]
    resources = ["arn:aws:dynamodb:*:*:table/prod-*"]
  }
}

# Se asigna a TODOS los grupos como capa adicional de protección
resource "aws_iam_group_policy_attachment" "protect" {
  group      = aws_iam_group.developers.name
  policy_arn = aws_iam_policy.protect_prod.arn
}
```

> ⚠️ **Advertencia:** Un Deny mal configurado puede bloquear a todos los administradores. Siempre prueba en un sandbox antes de aplicar en producción. Usa condiciones para limitar el alcance del Deny.

---

## 2.11 Least Privilege: El Principio Fundamental

Otorga únicamente los permisos necesarios para realizar una tarea, ni más ni menos. Es un **proceso iterativo** que comienza restrictivo y se ajusta:

| Práctica | Descripción |
|----------|------------|
| ✅ Empieza con cero permisos | Añade solo los necesarios para cada tarea |
| ✅ ARN específico en Resource | Nunca `Resource: "*"` si se puede evitar |
| ✅ Audita con Access Analyzer | Detecta permisos que nunca se usan |
| ❌ `actions = ["*"]` | Permiso total = riesgo total + blast radius ilimitado |

---

## 2.12 Auditoría: IAM Access Analyzer y Policy Simulator

AWS proporciona herramientas nativas para verificar que tus políticas cumplan con least privilege:

| Herramienta | Función |
|-------------|---------|
| **Access Analyzer** | Detecta recursos con acceso externo. Valida políticas antes de aplicar. Genera políticas basadas en uso real |
| **Policy Simulator** | Prueba políticas sin aplicarlas. Verifica acceso antes del deploy. Simula llamadas API |
| **CloudTrail + Athena** | Log de todas las llamadas API. Queries SQL sobre logs. Detecta permisos no usados |

---

## 2.13 Troubleshooting de Políticas

| Problema | Diagnóstico |
|---------|-------------|
| `AccessDenied` inesperado | Verifica si hay un Deny explícito en SCP, Boundary o política de recurso. Usa Policy Simulator para trazar la cadena |
| Política que no tiene efecto | Comprueba que el JSON sea válido. Error común: usar `"Action"` (JSON) en lugar de `"actions"` (HCL) o viceversa |
| Condición que no matchea | Valida las claves de condición: `aws:RequestedRegion` vs `ec2:Region` — son diferentes. Consulta la documentación de condition keys por servicio |
| Recurso no encontrado en ARN | Verifica el formato: `arn:aws:servicio:región:cuenta:recurso`. Un `*` en la región no es lo mismo que omitirla |

---

> **Siguiente:** [Sección 3 — KMS y Cifrado →](./03_kms_cifrado.md)
