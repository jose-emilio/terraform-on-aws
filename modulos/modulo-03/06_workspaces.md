# Sección 6 — Workspaces y Stacks

> [← Sección anterior](./05_comandos_state.md) | [Siguiente →](./07_estrategias_avanzadas.md)

---

## 6.1 Concepto de Workspaces en Terraform OSS

> **Importante — dos conceptos distintos:** Esta sección cubre los **workspaces CLI** (Terraform OSS / OpenTofu), que son una funcionalidad local del cliente para separar estados dentro de un mismo directorio. No confundir con los **HCP Terraform Workspaces**, que son entidades de servidor en la plataforma HCP Terraform que agrupan configuraciones, variables, permisos y pipelines remotos. Ambos se llaman "workspaces" pero su alcance y propósito son diferentes. Los HCP Terraform Workspaces se tratan en la [sección 6.10](#610-hcp-terraform-workspaces).

Imagina Git: puedes tener `main`, `develop` y `feature/login` — tres ramas del mismo repositorio, cada una con su propio estado. Los **Workspaces** de Terraform funcionan igual, pero aplicado al State: cada workspace mantiene su propio `.tfstate`, completamente independiente, usando exactamente los mismos archivos `.tf`.

```
Workspace "dev"      → terraform.tfstate.d/dev/terraform.tfstate
Workspace "staging"  → terraform.tfstate.d/staging/terraform.tfstate
Workspace "prod"     → terraform.tfstate.d/prod/terraform.tfstate
```

Un `terraform destroy` en el workspace `dev` no toca `prod`. Los recursos están completamente separados a nivel de estado.

**Caso de uso principal:** Equipos que despliegan la misma infraestructura en múltiples entornos con configuraciones ligeramente distintas: tamaño de instancia, número de réplicas, naming de recursos.

---

## 6.2 Gestión desde la CLI: Comandos Esenciales

Terraform incluye un workspace llamado `default` que no puede eliminarse. Es el workspace activo si nunca has creado ninguno:

| Comando | Acción |
|---------|--------|
| `terraform workspace new dev` | Crea el workspace `dev` y cambia a él automáticamente |
| `terraform workspace select prod` | Cambia el contexto activo al workspace `prod` |
| `terraform workspace list` | Lista todos los workspaces. Un `*` marca el activo |
| `terraform workspace show` | Imprime el nombre del workspace actualmente seleccionado |
| `terraform workspace delete staging` | Elimina el workspace `staging`. No se puede eliminar el activo ni `default` |

---

## 6.3 Inyección de Contexto: `terraform.workspace`

El objeto `terraform.workspace` devuelve el nombre del workspace activo como string. Úsalo para interpolar nombres de recursos, etiquetas y configuraciones dinámicamente — **sin cambiar el código HCL**:

```hcl
resource "aws_instance" "web" {
  ami           = "ami-0abcdef1234"
  instance_type = "t3.micro"

  tags = {
    Name = "server-${terraform.workspace}"   # → server-dev, server-prod
    Env  = terraform.workspace
  }
}
```

Con un solo bloque `resource`, Terraform crea recursos con nombres distintos según el workspace activo. El equipo de operaciones puede identificar inmediatamente a qué entorno pertenece cada recurso en la consola AWS.

---

## 6.4 Configuración Dinámica por Workspace: Mapas + `lookup()`

El patrón más poderoso para adaptar la configuración por entorno sin duplicar código:

```hcl
locals {
  # Mapa: workspace → tipo de instancia
  env_config = {
    dev  = "t3.micro"    # Instancia pequeña (ahorro ~90%)
    prod = "m5.large"    # Instancia potente para producción
  }

  # lookup(mapa, clave, fallback): si el workspace no está en el mapa,
  # usa "t3.micro" como valor seguro por defecto
  instance_type = lookup(local.env_config, terraform.workspace, "t3.micro")
}

resource "aws_instance" "web" {
  instance_type = local.instance_type   # ← Resuelto dinámicamente
}

# Resultado:
# workspace "dev"  → t3.micro
# workspace "prod" → m5.large
# workspace "qa"   → t3.micro (fallback)
```

Este patrón es escalable: añade `staging`, `qa`, `preprod` al mapa sin tocar el bloque `resource`.

---

## 6.5 Lógica de Red Dinámica por Workspace

Cuando dev y prod coexisten en la misma cuenta AWS, los rangos IP deben ser distintos para evitar colisiones — especialmente si usas VPC peering:

```hcl
locals {
  # Operador ternario: prod usa 10.0, cualquier otro entorno usa 10.1
  network_prefix = terraform.workspace == "prod" ? "10.0" : "10.1"
}

resource "aws_vpc" "main" {
  cidr_block = "${local.network_prefix}.0.0/16"

  tags = {
    Name = "vpc-${terraform.workspace}"   # → "vpc-prod" o "vpc-dev"
  }
}

# prod → 10.0.0.0/16 | dev → 10.1.0.0/16 | Sin colisiones de IP ✓
```

---

## 6.6 Workspaces vs. Directorios Separados

Esta es una de las decisiones arquitectónicas más frecuentes en proyectos nuevos. No hay respuesta universal — depende del grado de divergencia entre entornos:

| Característica | Workspaces | Directorios Separados |
|---------------|-----------|----------------------|
| Archivos `.tf` | Un solo set compartido | Carpeta independiente por entorno |
| Estado | Aislado por workspace | Aislado por directorio |
| Ideal para | Entornos casi idénticos | Entornos que divergen mucho |
| Diferencias gestionadas con | Variables y mapas | Código distinto por entorno |
| Riesgo principal | Drift silencioso si divergen | Duplicación y desincronización |

**Regla de decisión:** Si los entornos difieren solo en tamaños de instancia, réplicas o nombres → Workspaces. Si la arquitectura es fundamentalmente distinta entre dev y prod → Directorios separados.

---

## 6.7 Gestión de Secretos y `-var-file` por Workspace

El reto: compartir código entre entornos sin exponer secretos de producción en desarrollo. La solución: archivos `.tfvars` por workspace con credenciales separadas:

```
project/
├── main.tf
├── variables.tf
├── dev.tfvars        # db_password = "dev-pass-insegura"
└── prod.tfvars       # db_password = (referencia a Vault/SSM)
```

```bash
# Comando de ejecución con el archivo correcto por workspace
$ terraform plan -var-file="${terraform.workspace}.tfvars"
```

**Buenas prácticas:**
- Añadir `*.tfvars` a `.gitignore` para evitar que lleguen al repositorio
- Usar Vault o SSM Parameter Store para secretos de producción
- Nunca hardcodear credenciales directamente en archivos `.tf`

---

## 6.8 Workspaces en Pipelines CI/CD

Los workspaces son especialmente potentes en GitHub Actions o GitLab CI para crear **entornos efímeros por Pull Request**:

```yaml
# GitHub Actions: entorno efímero por PR
env:
  ENV: pr-${{ github.event.number }}

steps:
  - run: |
      # Seleccionar o crear el workspace del PR
      terraform workspace select $ENV \
        || terraform workspace new $ENV

      terraform apply -auto-approve

# PR #42 → workspace "pr-42" → infraestructura efímera
# Al merge: terraform destroy + workspace delete
```

Cada PR tiene su propio entorno de integración aislado. Cuando el PR se cierra, el workspace se destruye automáticamente, eliminando los costes asociados.

---

## 6.9 Limitaciones y el Bloque `check` como Guarda

Los workspaces CLI tienen riesgos reales: sin confirmación de contexto, un `terraform destroy` en el workspace equivocado puede eliminar infraestructura de producción sin advertencia.

**Patrón de seguridad: bloque `check` (Terraform >= 1.5)**

```hcl
variable "is_prod" {
  type    = bool
  default = false   # Seguro por defecto
}

# Valida durante el plan: si is_prod=true y workspace≠"prod" → ABORT
check "workspace_guard" {
  assert {
    condition     = !(var.is_prod && terraform.workspace != "prod")
    error_message = "STOP: is_prod=true pero workspace != prod"
  }
}

# Para producción:
# $ terraform apply -var="is_prod=true"
# Si workspace no es "prod" → falla antes de apply ✓
```

Este guardia detiene el `plan` si el contexto no coincide. El operador debe confirmar explícitamente que está en el workspace correcto antes de que Terraform haga nada.

---

## 6.10 HCP Terraform Workspaces: Una Unidad Completa

En HCP Terraform, un Workspace no es solo un archivo `.tfstate`. Es una **entidad completa** que incluye:

| Feature | Descripción |
|---------|-------------|
| **Estado Remoto** | State almacenado, versionado y bloqueado automáticamente |
| **Variables + Secretos** | Variables de entorno y Terraform con cifrado integrado |
| **VCS Integration** | Trigger automático desde GitHub/GitLab en cada push o PR |
| **RBAC + Policies** | Control de acceso granular y Sentinel policies para gobernanza |

La diferencia clave con la CLI: un workspace de TF Cloud es una unidad de trabajo completa con su propio contexto de seguridad, no solo un State aislado.

---

## 6.11 Terraform Stacks (v1.10+): La Evolución

Los workspaces son silos independientes — no tienen coordinación nativa entre regiones o cuentas. **Terraform Stacks** (v1.10+) supera esta limitación: gestiona infraestructuras multi-región y multi-cuenta como una sola unidad orquestada.

**Modelo tradicional (Workspaces):**
```
Workspace US → apply manual
Script Bash: copiar VPC ID
Workspace EU → apply manual
Riesgo: orden incorrecto = fallo
Sin rollback coordinado
```

**Platform Engineering (Stacks):**
```
Stack define US + EU como una unidad
VPC ID pasa automáticamente entre componentes
Plan global: ve todo el impacto
Apply coordinado: orden correcto
Rollback nativo si falla una región
```

---

## 6.12 Código: Configuración de un Stack

Un Stack se define en dos archivos: `tfstacks.hcl` (componentes) y `tfdeploy.hcl` (despliegues):

```hcl
# tfstacks.hcl — Componentes del Stack
component "networking" {
  source = "./modules/networking"
  inputs = {
    environment = var.env_name
  }
}

component "kubernetes" {
  source = "./modules/eks"
  inputs = {
    # Referencia cruzada: crea dependencia implícita
    # Stacks ejecuta networking ANTES que kubernetes
    vpc_id = component.networking.vpc_id
  }
}
```

```hcl
# tfdeploy.hcl — Despliegues multi-región
# Autenticación OIDC sin secretos estáticos
identity_token "aws" {
  audience = ["sts.amazonaws.com"]
}

deployment "us-east" {
  inputs = {
    region   = "us-east-1"
    role_arn = var.us_role
  }
}

deployment "eu-west" {
  inputs = {
    region   = "eu-west-1"
    role_arn = var.eu_role
  }
}
# Stacks ejecuta ambos deployments en paralelo si no hay deps
```

---

## 6.13 Guía de Decisión: Workspaces vs. Stacks vs. Directorios

| Escenario | Solución recomendada |
|-----------|---------------------|
| App simple, 2-3 entornos casi idénticos | Workspaces CLI |
| Múltiples entornos con RBAC y políticas | HCP Terraform Workspaces |
| Multi-región con dependencias cruzadas | Terraform Stacks |
| Entornos que divergen significativamente | Directorios separados |
| Platform team + múltiples equipos producto | Stacks + HCP Terraform |

---

## 6.14 Checklist de Buenas Prácticas

**Workspaces CLI:**
- Nunca borrar workspace `default`
- Usar `-var-file` por workspace para separar credenciales
- Añadir guards de validación con bloque `check`
- Nombrar workspaces igual que los entornos (`dev`, `staging`, `prod`)
- Automatizar `workspace select` en CI/CD

**HCP Terraform:**
- Un workspace = una responsabilidad
- Variables sensibles cifradas en la plataforma
- Sentinel policies obligatorias para producción
- VCS trigger configurado por workspace
- RBAC: prod = solo administradores

**Terraform Stacks:**
- Componentes pequeños y reusables
- Usar dependencias explícitas entre componentes
- Un deployment por región/cuenta
- Identity tokens sin secretos estáticos
- Validar el plan global antes de cualquier apply

---

> **Siguiente:** [Sección 7 — Estrategias Avanzadas de State →](./07_estrategias_avanzadas.md)
