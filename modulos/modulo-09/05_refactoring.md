# Sección 5 — Refactorización y Migración

> [← Volver al índice](./README.md) | [Siguiente →](./06_rendimiento_escala.md)

---

## 1. Refactorizar sin Destruir Infraestructura

Refactorizar en Terraform significa reorganizar la configuración — renombrar recursos, extraer módulos, cambiar de `count` a `for_each` — **sin destruir ni recrear la infraestructura existente**. Esta es la habilidad que separa a un equipo que teme tocar el código de uno que lo mantiene con confianza.

> **El profesor explica:** "El miedo más común que veo en los equipos es renombrar un recurso. El nombre en el state no coincide, Terraform quiere destruir y recrear una instancia de producción. La respuesta no es 'no lo tocamos'. La respuesta es el bloque `moved`. Con él, refactorizas el código, el state se actualiza, y el plan muestra cero cambios destructivos."

**Herramientas de refactorización:**

| Herramienta | Versión | Uso |
|-------------|---------|-----|
| `moved` block | TF 1.1+ | Renombrar, mover a módulos, cross-type |
| `removed` block | TF 1.7+ | Dejar de gestionar sin destruir |
| `import` block | TF 1.5+ | Adoptar recursos existentes |
| `terraform state mv` | Legacy | Imperativo, no versionable |
| `-generate-config-out` | TF 1.5+ | Auto-generar HCL desde recursos reales |

---

## 2. Bloque `moved` — Refactorización Declarativa (TF 1.1+)

```hcl
# Ejemplo 1: Renombrar un recurso
moved {
  from = aws_instance.server
  to   = aws_instance.web_server
}

# Ejemplo 2: Mover un recurso a un módulo
moved {
  from = aws_s3_bucket.data
  to   = module.storage.aws_s3_bucket.data
}

# Ejemplo 3: Cross-type move (TF 1.9+)
# Migrar null_resource → terraform_data sin destruir
moved {
  from = null_resource.bootstrap
  to   = terraform_data.bootstrap
}
```

**Flujo de trabajo estándar:**

```
1. Renombrar el recurso en el código .tf
2. Agregar bloque moved { from, to }
3. terraform plan → debe mostrar "moved" sin "destroy + create"
4. terraform apply → state actualizado
5. Eliminar el bloque moved del código
```

**Por qué declarativo es mejor que `terraform state mv`:**
- Es revisable en Pull Requests — el equipo puede ver la intención.
- Se documenta en el historial de Git.
- Terraform valida que el `moved` es correcto antes de aplicar.

---

## 3. Migración `count` → `for_each`

Este es uno de los casos de refactorización más frecuentes y más peligrosos sin `moved`. Con `count`, los recursos se identifican por índice (`[0]`, `[1]`). Eliminar el primer elemento recrea todos los siguientes. Con `for_each`, se identifican por clave estable.

```hcl
# ANTES: count con índices frágiles
resource "aws_subnet" "private" {
  count      = length(var.azs)
  cidr_block = var.cidrs[count.index]
}
# IDs en state: aws_subnet.private[0], [1], [2]
# Eliminar AZ 0 → recrea [1] y [2]

# DESPUÉS: for_each con claves estables + moved
resource "aws_subnet" "private" {
  for_each   = var.subnets   # map(string): az_name => cidr
  cidr_block = each.value
}
# IDs en state: aws_subnet.private["us-east-1a"], ["us-east-1b"]
# Eliminar us-east-1a → no afecta a las demás

# Bloques moved para la transición
moved {
  from = aws_subnet.private[0]
  to   = aws_subnet.private["us-east-1a"]
}
moved {
  from = aws_subnet.private[1]
  to   = aws_subnet.private["us-east-1b"]
}
moved {
  from = aws_subnet.private[2]
  to   = aws_subnet.private["us-east-1c"]
}
```

**Resultado:** `terraform plan` muestra tres `moved`, cero `create`, cero `destroy`.

---

## 4. Extracción a Módulos

Cuando `main.tf` supera las 300-500 líneas, es señal de que hay cohesión suficiente para extraer grupos de recursos a módulos reutilizables.

```hcl
# ANTES: recursos en el root module
resource "aws_vpc" "main" { ... }
resource "aws_subnet" "public" { ... }
resource "aws_internet_gateway" "igw" { ... }

# DESPUÉS: módulo con moved blocks

# 1. Crear módulo y mover recursos
module "networking" {
  source   = "./modules/networking"
  vpc_cidr = "10.0.0.0/16"
}

# 2. Agregar moved blocks para CADA recurso extraído
moved {
  from = aws_vpc.main
  to   = module.networking.aws_vpc.main
}

moved {
  from = aws_subnet.public
  to   = module.networking.aws_subnet.public
}

moved {
  from = aws_internet_gateway.igw
  to   = module.networking.aws_internet_gateway.igw
}
```

**Señales de que es hora de extraer un módulo:**
- Código duplicado entre proyectos o entornos.
- `main.tf` con +500 líneas.
- Grupo de recursos con alta cohesión (networking, compute, security).
- Un equipo diferente gestiona ese grupo de recursos.

---

## 5. `terraform state mv` — El Enfoque Legacy

```bash
# Renombrar un recurso en el state
$ terraform state mv \
  aws_instance.web \
  aws_instance.web_server

# Mover recurso a un módulo
$ terraform state mv \
  aws_instance.web \
  module.compute.aws_instance.web

# Mover entre state files (split state)
$ terraform state mv \
  -state-out=../networking/terraform.tfstate \
  aws_vpc.main \
  aws_vpc.main

# ⚠ Preferir 'moved' block para Terraform >= 1.1
```

**`state mv` vs bloque `moved`:**

| | `terraform state mv` | Bloque `moved` |
|-|---------------------|----------------|
| Revisable en PR | No | Sí |
| Versionable en Git | No | Sí |
| Plan previo visible | No | Sí |
| Reversible | No (necesita backup) | Sí (eliminar el bloque) |
| Desde | Siempre | TF 1.1+ |

---

## 6. Bloques `import` — Adopción Declarativa (TF 1.5+)

```hcl
# imports.tf
import {
  to = aws_instance.web
  id = "i-0abc123def456"
}

# Import masivo: múltiples buckets S3 existentes
import {
  for_each = var.existing_buckets   # map(string)
  to       = aws_s3_bucket.managed[each.key]
  id       = each.value
}
```

```bash
# Auto-generar el código HCL desde el recurso real
$ terraform plan -generate-config-out=generated.tf

# Revisar generated.tf:
# - Eliminar atributos computed (se gestionan automáticamente)
# - Agregar variables para valores que deben parametrizarse
# - Limpiar valores por defecto redundantes

# Verificar plan limpio
$ terraform plan

# Ejecutar el import
$ terraform apply

# El bloque import se puede eliminar tras el apply exitoso
```

---

## 7. Herramientas de Adopción para Infraestructura Existente

### Terraformer (CLI, Multi-Cloud)

```bash
# Instalar
brew install terraformer

# Exportar recursos AWS a HCL + tfstate
terraformer import aws \
  --resources=ec2_instance,s3,vpc \
  --regions=us-east-1 \
  --profile=default

# Filtrar por tags
terraformer import aws \
  --resources=ec2_instance \
  --filter=aws_instance=Name:web-prod
```

### Former2 (GUI Web, Solo AWS)

- Herramienta web que escanea la cuenta AWS y genera HCL, CloudFormation o CDK.
- No requiere instalación local.
- Soporte para 300+ tipos de recursos.

### cf2tf (CloudFormation → Terraform)

```bash
pip install cf2tf
cf2tf template.yaml -o output.tf
```

**Advertencia:** Ninguna herramienta genera código production-ready automáticamente. Siempre requiere revisión y limpieza manual posterior.

---

## 8. Migración desde CloudFormation — 3 Pasos

Migrar de CloudFormation a Terraform **no requiere recrear recursos**. El proceso es gradual e imperceptible para la infraestructura.

```
Paso 1: Escribir HCL equivalente
  cf2tf template.yaml -o terraform.tf
  + Limpiar y parametrizar el código generado

Paso 2: Importar los recursos (sin recrear)
  terraform plan -generate-config-out=generated.tf
  terraform apply  # Import declarativo

Paso 3: Eliminar el stack CloudFormation
  # En el template, agregar DeletionPolicy: Retain a cada recurso
  # Esto preserva los recursos al borrar el stack
  aws cloudformation delete-stack --stack-name mi-stack
  # Los recursos siguen existiendo, ahora gestionados por Terraform
```

---

## 9. Migración de Backend

```hcl
# Paso 1: Cambiar configuración del backend en main.tf
terraform {
  backend "s3" {
    bucket = "my-new-tf-state"
    key    = "prod/terraform.tfstate"
    region = "us-east-1"
  }
}
```

```bash
# Paso 2: Migrar state automáticamente
$ terraform init -migrate-state
# Terraform detecta el cambio de backend y pregunta:
# "Do you want to copy existing state to the new backend?" → yes
# ✅ State migrado sin pérdida de datos
```

---

## 10. `removed` Block — Dejar de Gestionar (TF 1.7+)

```hcl
# Dejar de gestionar SIN destruir el recurso real
removed {
  from    = aws_s3_bucket.legacy
  destroy = false  # El bucket seguirá existiendo en AWS
}

# Dejar de gestionar Y destruir
removed {
  from    = aws_instance.temp_debug
  destroy = true  # Default: destruir
}
```

**`removed` vs `terraform state rm`:**

```bash
# Legacy (imperativo, no auditable):
$ terraform state rm aws_s3_bucket.legacy
# - No hay plan previo visible
# - No queda en control de versiones
# - Solo elimina del state, NO destruye el recurso

# Moderno (declarativo, revisable en PR):
removed {
  from    = aws_s3_bucket.legacy
  destroy = false
}
# ✅ terraform plan muestra el efecto antes de aplicar
# ✅ Revisable en PR con context para el equipo
# ✅ Funciona en CI/CD pipelines
```

---

## 11. Checklist de Refactorización Segura

**Antes:**
```bash
# Confirmar que no hay cambios pendientes
terraform plan    # Debe mostrar "No changes"

# Hacer backup del state
terraform state pull > backup.tfstate
```

**Durante:**
- Usar `moved` blocks en vez de `terraform state mv`.
- Refactorizar en PRs pequeños y revisables.
- Un componente o módulo por PR.
- Documentar la motivación en el PR (ADR si es un cambio estructural).

**Después:**
```bash
# Verificar que no hay cambios destructivos
terraform plan    # Debe mostrar "No changes" o solo "moved"

# Tras apply exitoso: eliminar los bloques moved del código
```

---

## 12. Estrategias de Adopción de Terraform

| Estrategia | Descripción |
|-----------|-------------|
| **Greenfield first** | Nuevos recursos siempre en Terraform — no a ClickOps |
| **Brownfield gradual** | Importar módulo por módulo, sin prisa |
| **Dev/staging primero** | Nunca comenzar la adopción en producción |
| **Plan obsesivo** | Verificar cada paso con `terraform plan` antes de `apply` |
| **PRs pequeños** | Un servicio o módulo por PR — más fácil de revisar |
| **Documentar decisiones** | ADRs para cambios estructurales grandes |

---

> [← Volver al índice](./README.md) | [Siguiente →](./06_rendimiento_escala.md)
