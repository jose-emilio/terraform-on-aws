# Sección 1 — AWS IAM: Usuarios, Grupos y Roles

> [← Volver al índice](./README.md) | [Siguiente →](./02_politicas_iam.md)

---

## 1.1 IAM: El Marco de Identidades de AWS

Antes de definir permisos, debes establecer **identidades**. IAM (Identity and Access Management) controla **QUIÉN** puede hacer **QUÉ** en tu cuenta AWS.

Existen tres tipos fundamentales de identidades, cada una con un propósito distinto:

| Identidad | Recurso Terraform | Característica |
|-----------|------------------|----------------|
| **Usuarios (Users)** | `aws_iam_user` | Identidad permanente para personas. Credenciales de larga duración: contraseñas y Access Keys |
| **Grupos (Groups)** | `aws_iam_group` | Organización lógica de usuarios. Best practice: asignar permisos siempre al grupo, nunca directamente al usuario |
| **Roles** | `aws_iam_role` | Identidad temporal y asumible. Para servicios y máquinas. Sin credenciales permanentes |

---

## 1.2 Usuarios y Grupos: Identidades Estáticas

Un **User** es una identidad permanente con credenciales propias. Un **Group** organiza usuarios y centraliza la asignación de permisos.

```
aws_iam_user               aws_iam_group
• Representa a una persona  • Colección lógica de usuarios
• Nombre único en la cuenta • Las políticas se adjuntan al grupo
• Puede tener contraseña    • Todos los miembros heredan permisos
• Puede tener Access Keys   • Facilita on/off-boarding del equipo
• ARN: arn:aws:iam::        • Un usuario puede estar en N grupos
    ACCOUNT:user/NAME
```

**Código: Estructura de Usuarios y Membresía**

```hcl
# Grupo de Desarrolladores
resource "aws_iam_group" "developers" {
  name = "developers"
}

# Usuario
resource "aws_iam_user" "alice" {
  name = "alice"
}

# Membresía: vincula usuario al grupo
resource "aws_iam_group_membership" "dev_team" {
  name  = "dev-team-membership"
  group = aws_iam_group.developers.name
  users = [aws_iam_user.alice.name]
}
```

> **Best Practice:** La mejor práctica es siempre asignar políticas a grupos, nunca directamente a usuarios. Cuando el equipo crece, añadir un usuario al grupo correcto es todo lo que necesitas.

---

## 1.3 IAM Roles: La Identidad del Recurso

Un **Rol** es una identidad temporal y asumible. No tiene contraseña ni Access Keys permanentes. Las credenciales se generan dinámicamente con cada asunción (`AssumeRole`) y **expiran automáticamente**.

Características clave:
- No pertenece a un usuario específico — cualquier entidad autorizada puede asumirlo
- Credenciales temporales (STS) — se renuevan automáticamente
- Compuesto de dos partes: **Trust Policy** (quién puede asumir) + **Permissions Policy** (qué puede hacer)
- Casos de uso: EC2, Lambda, ECS, Cross-Account, CI/CD, SSO

---

## 1.4 Trust Policies: ¿Quién Puede Asumir Este Rol?

La **Trust Policy** (Assume Role Policy) es un documento JSON que define qué entidades tienen permiso para asumir el rol. Es el **filtro de seguridad previo** a cualquier permiso.

Entidades que pueden asumir un rol:
- Servicios AWS (EC2, Lambda, ECS)
- Usuarios IAM de otra cuenta
- Proveedores OIDC (GitHub, GitLab)
- Proveedores SAML (SSO corporativo)
- El propio root de la cuenta

**Estructura básica del documento:**

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { ... },
    "Action": "sts:AssumeRole"
  }]
}
```

**Código: Rol con Confianza para EC2**

```hcl
# Trust Policy: permite a EC2 asumir este rol
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Rol IAM para EC2
resource "aws_iam_role" "ec2_role" {
  name               = "ec2-app-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}
```

---

## 1.5 IAM Instance Profile: El Contenedor para EC2

EC2 **no puede recibir un rol directamente** — necesita un contenedor intermedio llamado **Instance Profile** que actúa como adaptador entre el rol y la instancia física.

```
Por qué existe el Instance Profile:
• EC2 fue el primer servicio de AWS → requirió un mecanismo específico
• Lambda, ECS, etc. NO necesitan Instance Profile (usan rol directamente)
• Relación 1:1 → Un Instance Profile contiene exactamente un Rol
```

```hcl
# Instance Profile: contenedor del rol para EC2
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-app-profile"
  role = aws_iam_role.ec2_role.name
}

# EC2 con identidad IAM
resource "aws_instance" "app_server" {
  ami                  = data.aws_ami.amazon_linux.id   # Obtener AMI con data source, nunca hardcodeado
  instance_type        = "t3.micro"
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  tags = { Name = "app-server" }
}
```

---

## 1.6 Service-Linked Roles: Roles de la Plataforma

Son roles predefinidos por AWS que permiten a servicios como Auto Scaling, ELB o RDS operar recursos en tu nombre. Su Trust Policy es **inmutable** — AWS la gestiona:

| Service-Linked Role | Propósito |
|--------------------|-----------| 
| `AWSServiceRoleForAutoScaling` | Gestiona instancias del ASG |
| `AWSServiceRoleForELB` | Registra targets en balanceadores |
| `AWSServiceRoleForRDS` | Gestiona snapshots y mantenimiento |

> ⚠️ No puedes modificar su Trust Policy. Se crean automáticamente al usar el servicio. En Terraform: `aws_iam_service_linked_role` (raramente necesario crearlo explícitamente).

---

## 1.7 Acceso Multi-cuenta (Cross-Account)

Permite que un usuario o servicio de la Cuenta A asuma un rol en la Cuenta B. Es el patrón estándar en arquitecturas empresariales con múltiples cuentas AWS:

```
Cuenta A (Origen)                    Cuenta B (Destino)
• El usuario/rol tiene permiso        • El Rol tiene una Trust Policy
  sts:AssumeRole sobre el ARN del       que permite al Principal de A
  rol de la Cuenta B                 • El Rol tiene permisos propios
• Ejecuta la llamada AssumeRole      • Requiere ambos lados:
• Recibe credenciales temporales       Trust + IAM Policy
```

```hcl
# Rol en Cuenta B que confía en Cuenta A
data "aws_iam_policy_document" "cross_account_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::111111111111:root"]   # Cuenta A
    }
  }
}

resource "aws_iam_role" "cross_account" {
  name               = "cross-account-deploy"
  assume_role_policy = data.aws_iam_policy_document.cross_account_trust.json
}
```

---

## 1.8 OIDC: Autenticación Federada sin Secretos

Los sistemas CI/CD (GitHub Actions, GitLab CI) deben usar **Roles en lugar de Access Keys** estáticas. OpenID Connect (OIDC) permite que proveedores externos obtengan acceso a AWS **sin secretos almacenados**:

**Flujo de autenticación OIDC:**
```
1. GitHub Actions genera un JWT con claims (repo, branch, actor)
2. AWS STS valida el token contra el OIDC Provider registrado
3. La Trust Policy verifica los claims (Subject = repo específico)
4. STS emite credenciales temporales → El pipeline opera con permisos del Rol
```

| Anti-patrón | Best Practice |
|------------|---------------|
| Access Keys en variables de entorno | OIDC Federation (sin secretos) |
| Secretos guardados en el repositorio | Credenciales temporales (15 min) |
| Credenciales que nunca se rotan | Restricción por repo/branch |
| Riesgo de filtración en logs | Auditoría completa en CloudTrail |

**Código: Proveedor OIDC para GitHub Actions**

```hcl
# Registrar GitHub como OIDC Provider en AWS
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS ignora este valor para GitHub Actions; se incluye solo porque
  # el argumento es obligatorio en el provider de AWS.
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]
}
```

> **Nota:** Desde **julio de 2023**, AWS ya no requiere la verificación del thumbprint para proveedores OIDC de GitHub Actions. AWS valida los tokens directamente usando su propia biblioteca de CA raíz. El uso de `data "tls_certificate"` para obtener el thumbprint dinámicamente es innecesario y puede eliminarse de configuraciones existentes.

**Código: Rol OIDC con Restricción de Repositorio**

```hcl
# Trust Policy: solo un repo específico puede asumir este rol
data "aws_iam_policy_document" "github_oidc_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:mi-org/mi-repo:ref:refs/heads/main"]
    }
  }
}
```

La condición `StringEquals` sobre el `sub` del JWT es la clave de seguridad: solo el repositorio `mi-org/mi-repo` en la rama `main` puede asumir el rol. Ningún otro repositorio ni branch puede usarlo.

---

## 1.9 Acceso Federado para Humanos: El Modelo Moderno

Los humanos deben acceder a la consola AWS mediante **SSO/SAML**, asumiendo Roles temporales a través de un Identity Provider corporativo (Okta, Microsoft Entra ID, Google Workspace):

| Modelo Legacy | Modelo Moderno (SSO) |
|--------------|---------------------|
| Un `aws_iam_user` por persona | AWS IAM Identity Center (SSO) |
| Contraseñas gestionadas en IAM | Identidad centralizada en IdP (Okta, Microsoft Entra ID, Google Workspace) |
| MFA por separado | MFA integrado del proveedor |
| Difícil de auditar y escalar | Sesiones temporales por rol |

---

## 1.10 Service Control Policies (SCP)

Las SCPs de AWS Organizations establecen **límites máximos de permisos** para todas las cuentas de la organización:

- Restringir regiones: solo permitir `us-east-1` y `eu-west-1`
- Bloquear servicios: prohibir uso de servicios no aprobados
- Proteger roles críticos: impedir que se borren roles de auditoría
- Forzar condiciones: requerir MFA para acciones destructivas

> ⚠️ Las SCPs **NO otorgan permisos**, solo los limitan. En Terraform: `aws_organizations_policy` con `type = "SERVICE_CONTROL_POLICY"`.

---

## 1.11 Troubleshooting de Identidades

| Error | Causa | Fix |
|-------|-------|-----|
| `AccessDenied when calling AssumeRole` | El Principal en la Trust Policy no coincide con el ARN del llamador | Verificar el formato exacto del ARN y que no haya errores en el Account ID |
| EC2 no puede obtener credenciales del metadata service | Se creó el Rol pero no el `aws_iam_instance_profile`, o no se asignó a la instancia | Crear y asignar el Instance Profile |
| Confusión entre ARN de Usuario vs. Rol | Usar `:user/` donde debería ser `:role/` (o viceversa) | `arn:aws:iam::123:user/dev` ≠ `arn:aws:iam::123:role/dev` |

---

## 1.12 Resumen: El Mapa de Identidades

| Tipo | Cuándo usarlo |
|------|--------------|
| **Usuarios** | Último recurso para acceso directo. Preferir SSO/Federación en todos los casos |
| **Grupos** | Siempre para organizar usuarios. Asignar políticas al grupo, no al usuario |
| **Roles** | Para servicios (EC2, Lambda), CI/CD (OIDC), cross-account y acceso federado humano |

> **Principio:** En AWS moderno, los humanos usan SSO, los servicios usan Roles, y ningún pipeline debería tener Access Keys permanentes.

---

> **Siguiente:** [Sección 2 — Políticas IAM con Terraform →](./02_politicas_iam.md)
