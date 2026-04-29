# Laboratorio 8: Refactorización Declarativa y Adopción de Infraestructura

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 3 — Gestión del Estado (State)](../../modulos/modulo-03/README.md)


## Visión general

En este laboratorio aprenderás a gestionar el ciclo de vida completo de un recurso usando las primitivas declarativas de Terraform 1.5+/1.7+: adoptarás un recurso existente con `import {}` y `-generate-config-out`, lo renombrarás en el estado sin recrearlo con `moved {}`, y finalmente dejarás de gestionarlo sin eliminarlo con `removed {}`.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear un recurso fuera de Terraform y adoptarlo con el bloque `import {}`
- Generar automáticamente la configuración HCL con el flag `-generate-config-out`
- Renombrar un recurso en el estado sin destruirlo usando el bloque `moved {}`
- Retirar un recurso de la gestión de Terraform sin eliminarlo con `removed { lifecycle { destroy = false } }`
- Entender cuándo usar cada primitiva y sus diferencias con los comandos imperativos equivalentes

## Requisitos Previos

- Terraform >= 1.7 instalado
- Laboratorio 1 completado (entorno configurado)
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### Bloque `import {}`

Permite adoptar de forma declarativa un recurso existente en la infraestructura (creado fuera de Terraform, por la consola o por otro proceso) y añadirlo al estado de Terraform. Está disponible desde Terraform 1.5.

```hcl
import {
  to = aws_s3_bucket.app
  id = var.bucket_name
}
```

**Cuándo usarlo vs el equivalente imperativo:**

El comando clásico `terraform import <addr> <id>` es imperativo: modifica el estado en ese momento pero no queda registrado en el código. Si alguien hace `terraform init` en un repo nuevo o destruye el estado, no hay rastro de que ese recurso fue importado.

El bloque `import {}` es declarativo: vive en el código, se puede revisar en un Pull Request y sirve como documentación del origen del recurso. Además, combinado con `-generate-config-out`, puede generar automáticamente el bloque `resource` correspondiente.

> El bloque `import {}` es de migración de un solo uso, igual que `moved {}` y `removed {}`. Tras el apply, elimínalo del código. Aunque es idempotente (si el recurso ya está en el estado con ese ID, no hace nada), mantenerlo indefinidamente añade ruido.

### Flag `-generate-config-out`

Flag del comando `terraform plan` que genera automáticamente el bloque `resource` para recursos importados cuando dicho bloque todavía no existe en el código:

```bash
terraform plan -generate-config-out=generated.tf
```

Terraform consulta la API del proveedor para leer el estado real del recurso y vuelca toda su configuración en el archivo indicado. Requiere que:

1. Haya un bloque `import {}` apuntando al recurso.
2. El resource address (`to`) NO tenga todavía un bloque `resource` en el código.

El archivo generado debe revisarse y limpiarse antes de aplicar: suele incluir atributos de solo lectura (computados) como `id`, `arn` o `tags_all` que Terraform no puede establecer y que causarán un error.

### Bloque `moved {}`

Actualiza el estado de Terraform para reflejar un renombrado en el código, sin destruir ni recrear el recurso real en la nube. Disponible desde Terraform 1.1.

```hcl
moved {
  from = aws_s3_bucket.app
  to   = aws_s3_bucket.application
}
```

**Cuándo usarlo vs el equivalente imperativo:**

El comando clásico `terraform state mv <from> <to>` renombra el recurso en el estado pero no queda registrado en el código. El bloque `moved {}` es trazable en Git, revisable en PR y puede eliminarse del código tras el apply.

> Tras el apply, el bloque `moved {}` puede eliminarse del código. Mantenlo si el repositorio tiene ramas que aún referencian el nombre antiguo.

### Bloque `removed {}`

Retira un recurso del estado de Terraform. Con `lifecycle { destroy = false }`, el recurso real en la nube se mantiene intacto. Disponible desde Terraform 1.7.

```hcl
removed {
  from = aws_s3_bucket.application
  lifecycle {
    destroy = false
  }
}
```

**Cuándo usarlo vs el equivalente imperativo:**

El comando clásico `terraform state rm <addr>` elimina el recurso del estado sin dejar rastro en el código. El bloque `removed {}` es declarativo, revisable en PR y deja claro qué recurso se retiró de la gestión y con qué política (destroy o no).

> Tras el apply, el bloque `removed {}` puede eliminarse del código.

### Tabla Comparativa

| Necesidad | Comando imperativo (clásico) | Primitiva declarativa (1.5+/1.7+) |
|---|---|---|
| Adoptar recurso existente | `terraform import <addr> <id>` | Bloque `import {}` |
| Renombrar recurso en código | `terraform state mv <from> <to>` | Bloque `moved {}` |
| Retirar recurso del estado | `terraform state rm <addr>` | Bloque `removed {}` |

---

## Estructura del proyecto

```
lab08/
├── aws/
│   ├── aws.s3.tfbackend  # Parametros del backend S3 (sin bucket)
│   ├── providers.tf      # Requiere Terraform >= 1.7, backend S3
│   ├── variables.tf      # Nombre del bucket a importar
│   ├── main.tf           # Evoluciona en cada fase del laboratorio
│   └── outputs.tf
└── localstack/
    ├── providers.tf   # Endpoints apuntando a LocalStack
    ├── variables.tf   # Nombre del bucket con valor por defecto
    ├── main.tf
    └── outputs.tf
```

---

## 1. Despliegue en AWS Real

### 1.1 Código Terraform

**`aws/providers.tf`**

```hcl
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}
```

**`aws/variables.tf`**

```hcl
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3 creado fuera de Terraform que se va a importar"
}
```

**`aws/main.tf`** (estado inicial — punto de partida de la Fase 1)

```hcl
# Laboratorio 8 — Fase 1: Adopción de infraestructura existente.
#
# Antes de continuar, crea el bucket fuera de Terraform:
#   aws s3 mb s3://$TF_VAR_bucket_name --region us-east-1
#
# Luego genera la configuración HCL automáticamente:
#   terraform plan -generate-config-out=generated.tf
#
# Revisa generated.tf, integra el bloque resource en este archivo
# y elimina generated.tf. Tras el apply, elimina tambien el bloque import{}.

import {
  to = aws_s3_bucket.app
  id = var.bucket_name
}
```

El archivo `main.tf` entregado contiene únicamente el bloque `import {}` como punto de partida. En cada fase del laboratorio el alumno edita este archivo según las instrucciones. El archivo `outputs.tf` se entrega con los outputs comentados; se activan en la Fase 1.

### 1.2 Fase 1 — Adopción con `import {}`

**Paso 1** — Inicializa el directorio de trabajo:

```bash
export TF_VAR_bucket_name=lab8-import-miempresa-2024
BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
```

**Paso 2** — Crea el bucket fuera de Terraform para simular un recurso existente:

```bash
aws s3 mb s3://$TF_VAR_bucket_name --region us-east-1
```

**Paso 3** — Genera la configuración HCL automáticamente:

```bash
terraform plan -generate-config-out=generated.tf
```

Terraform consulta la API de AWS para leer el estado real del bucket y vuelca toda su configuración en `generated.tf`. El contenido generado tendrá un aspecto similar a este (simplificado):

```hcl
# __generated__ by Terraform
# Please review these resources and move them into your main configuration files.

resource "aws_s3_bucket" "app" {
  bucket              = "lab8-import-miempresa-2024"
  force_destroy       = false
  object_lock_enabled = false
  tags                = {}
}
```

> **Atención:** el archivo generado puede incluir atributos de solo lectura (computados) que debes eliminar antes de aplicar. Los más comunes son: `id`, `arn`, `bucket_domain_name`, `bucket_regional_domain_name`, `hosted_zone_id`, `region` y `tags_all`. Si los dejas, Terraform devolverá un error en el apply porque no puede establecer esos valores: son calculados por AWS, no configurables.

**Paso 4** — Integra el bloque `resource` en `main.tf` y elimina `generated.tf`. El resultado de `main.tf` tras este paso:

```hcl
import {
  to = aws_s3_bucket.app
  id = var.bucket_name
}

resource "aws_s3_bucket" "app" {
  bucket              = var.bucket_name
  force_destroy       = false
  object_lock_enabled = false
  tags                = {}
}
```

El bloque `import {}` se mantiene junto al `resource` para que el apply lo importe al estado. Tras el apply lo eliminaremos (Paso 7).

**Paso 5** — Activa los outputs en `outputs.tf`:

```hcl
output "bucket_id" {
  description = "ID del bucket adoptado por Terraform"
  value       = aws_s3_bucket.app.id
}

output "bucket_arn" {
  description = "ARN del bucket"
  value       = aws_s3_bucket.app.arn
}
```

**Paso 6** — Aplica:

```bash
terraform apply
```

El plan mostrará `1 to import, 0 to add, 0 to change, 0 to destroy`. El recurso pasa a estar gestionado por Terraform sin haber sido recreado ni interrumpido su servicio.

**Verificación:**

```bash
terraform state list
terraform state show aws_s3_bucket.app
aws s3 ls | grep $TF_VAR_bucket_name
```

**Paso 7** — Tras el apply, elimina el bloque `import {}` de `main.tf`. Ya cumplió su función: el recurso está en el estado y el bloque es de un solo uso, equivalente a `moved {}` y `removed {}`. Un nuevo `terraform plan` debe seguir mostrando `No changes`.

### 1.3 Fase 2 — Refactorización con `moved {}`

El nombre `app` es demasiado genérico. Lo renombraremos a `application` para seguir la convención de nomenclatura del equipo. Si simplemente cambiáramos el nombre en el código sin el bloque `moved {}`, Terraform interpretaría que el recurso `aws_s3_bucket.app` fue eliminado y que hay que crear `aws_s3_bucket.application`: destruiría el bucket existente y crearía uno nuevo.

**Paso 1** — Modifica `main.tf` añadiendo el bloque `moved {}` y renombrando el bloque `resource`:

```hcl
moved {
  from = aws_s3_bucket.app
  to   = aws_s3_bucket.application
}

resource "aws_s3_bucket" "application" {
  bucket              = var.bucket_name
  force_destroy       = false
  object_lock_enabled = false
  tags                = {}
}
```

El bloque `import {}` ya fue eliminado al final de la Fase 1, así que `main.tf` ahora solo contiene el `moved {}` y el `resource` renombrado.

Actualiza también `outputs.tf` para referenciar el nuevo nombre:

```hcl
output "bucket_id" {
  description = "ID del bucket adoptado por Terraform"
  value       = aws_s3_bucket.application.id
}

output "bucket_arn" {
  description = "ARN del bucket"
  value       = aws_s3_bucket.application.arn
}
```

**Paso 2** — Verifica el plan:

```bash
terraform plan
```

El plan debe mostrar:

```
  # aws_s3_bucket.app has moved to aws_s3_bucket.application
```

Con `0 to add, 0 to change, 0 to destroy`. No hay ninguna acción destructiva: Terraform solo actualiza el estado local.

**Paso 3** — Aplica:

```bash
terraform apply
```

**Paso 4** — Tras el apply, el bloque `moved {}` ya no es necesario (el estado refleja el nuevo nombre). Puedes eliminarlo del código. Mantenlo si el repositorio tiene histórico de ramas que podrían hacer checkout de la versión anterior y necesitarían migrar el estado.

**Verificación:**

```bash
terraform state list                          # muestra aws_s3_bucket.application
aws s3 ls | grep $TF_VAR_bucket_name          # el bucket sigue existiendo
```

### 1.4 Fase 3 — Remoción con `removed {}`

El equipo de plataforma tomará el control del bucket desde otro proyecto Terraform. Queremos que este proyecto deje de gestionarlo sin eliminarlo de AWS.

**Paso 1a** — Vacía `outputs.tf` primero. Mientras el resource block exista, Terraform valida que las referencias sean correctas; si se borra el resource y se deja el output en el mismo paso, el plan falla con "reference to undeclared resource":

```hcl
# outputs.tf — vaciar en la Fase 3; el recurso ya no se gestiona en este proyecto
```

**Paso 1b** — Elimina el bloque `resource "aws_s3_bucket" "application"` de `main.tf` y añade el bloque `removed {}`:

```hcl
removed {
  from = aws_s3_bucket.application
  lifecycle {
    destroy = false
  }
}
```

**Paso 2** — Verifica el plan:

```bash
terraform plan
```

El plan debe mostrar:

```
  # aws_s3_bucket.application will no longer be managed by Terraform, but will not be destroyed
  # (destroy = false is set in the configuration)
```

Con `0 to add, 0 to change, 0 to destroy`. Terraform retira el recurso del estado sin llamar a la API de AWS para eliminarlo.

**Paso 3** — Aplica:

```bash
terraform apply
```

**Paso 4** — Tras el apply, el bloque `removed {}` puede eliminarse del código. Verifica que el bucket sigue existiendo en AWS pero ya no aparece en el estado:

```bash
terraform state list                          # lista vacía
aws s3 ls | grep $TF_VAR_bucket_name          # el bucket SIGUE existiendo
```

---

## Verificación final

```bash
# Verificar que el bucket fue importado correctamente al estado
terraform state list | grep aws_s3_bucket

# Verificar que el recurso renombrado con moved {} no fue recreado:
# si moved {} hubiera recreado el bucket, la CreationDate seria reciente.
aws s3api list-buckets \
  --query "Buckets[?Name=='$TF_VAR_bucket_name'].CreationDate" \
  --output text

# Comprobar que el recurso eliminado con removed {} ya no esta en el estado
terraform state list
# El bucket NO debe aparecer en la lista

# Confirmar que el bucket sigue existiendo en AWS (no fue destruido)
aws s3 ls | grep $TF_VAR_bucket_name
```

---

## 2. Limpieza

Como el bucket fue retirado del estado de Terraform con `removed {}`, `terraform destroy` no puede eliminarlo. Hay que borrarlo manualmente:

```bash
aws s3 rb s3://$TF_VAR_bucket_name --force
```

---

## 3. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

Los bloques `import {}`, `moved {}` y `removed {}` operan sobre el estado local de Terraform, por lo que su comportamiento es idéntico al de AWS real.

---

## 4. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| Crear recurso previo | Consola o `aws s3 mb` | `aws --profile localstack s3 mb` |
| `-generate-config-out` | Genera config completa del recurso real | Soportado; algunos atributos pueden diferir |
| `moved {}` | Opera solo en estado local | Idéntico |
| `removed { destroy = false }` | Opera solo en estado local | Idéntico |
| Verificar existencia post-remoción | `aws s3 ls` | `aws --profile localstack s3 ls` |

---

## Buenas prácticas aplicadas

- **Prefiere primitivas declarativas sobre comandos imperativos.** Los bloques `import {}`, `moved {}` y `removed {}` quedan en el historial de Git y son revisables en PR. `terraform state mv` y `terraform state rm` modifican el estado sin trazabilidad en el código.
- **Elimina `import {}`, `moved {}` y `removed {}` tras el apply en producción.** Son bloques de migración de un solo uso. Mantenerlos indefinidamente no causa errores pero aumenta el ruido en el código y diluye la intención del bloque cuando aparezca en otra migración.
- **Revisa siempre `generated.tf` antes de aplicar.** El archivo puede contener atributos computados (`arn`, `id`, `tags_all`) que provocarán errores en el apply. Limpia el archivo o usa solo los atributos que necesitas gestionar.
- **Usa `import {}` en combinación con `-generate-config-out` para adoptar recursos existentes.** Si el recurso tiene una configuración compleja con muchos atributos, la generación automática ahorra tiempo y evita errores tipográficos.
- **`destroy = false` no es permanente en el ciclo de vida del recurso.** Una vez retirado del estado, si otro proyecto lo importa con `destroy = true` por defecto, el recurso podría eliminarse. Coordina con el equipo que tomará la gestión del recurso.
- **El historial de Git documenta el origen del recurso, no el bloque `import {}`.** El bloque es idempotente y dejarlo no rompe nada, pero la trazabilidad del PR donde se adoptó el recurso es lo que sirve como documentación; el bloque, una vez aplicado, solo es ruido.

---

## Recursos

- [Bloque `import` - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/import)
- [Generación de configuración con `-generate-config-out`](https://developer.hashicorp.com/terraform/language/import/generating-configuration)
- [Bloque `moved` - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/block/moved)
- [Bloque `removed` - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/resources/syntax#removing-resources)
- [Recurso aws_s3_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket)
