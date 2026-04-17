# Laboratorio 39 — Despliegue Global y Adopción de Infraestructura Existente

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 9 — Terraform Avanzado](../../modulos/modulo-09/README.md)


## Visión general

En proyectos reales, Terraform rara vez opera sobre una única región ni
parte de cero. Este laboratorio aborda dos situaciones que aparecen juntas
con frecuencia al madurar un proyecto de infraestructura:

1. **Despliegue global**: usar múltiples alias de proveedor para crear recursos
   simultaneamente en `us-east-1` y `eu-west-3` desde un único `terraform apply`.

2. **Drift y sincronizacion**: alguien modifica un tag directamente en la consola
   de AWS sin pasar por Terraform. El estado queda desincronizado con la realidad
   (*drift*). `terraform plan -refresh-only` detecta la discrepancia y
   `terraform apply -refresh-only` la resuelve sin tocar la infraestructura real.

3. **Adopción de recursos existentes**: un bucket S3 fue creado manualmente antes
   de que el equipo adoptara Terraform. El nuevo bloque `import` (Terraform 1.5+)
   junto con la opción `-generate-config-out` permiten incorporarlo al estado
   y generar automáticamente el código HCL necesario, sin borrar ni recrear nada.

## Objetivos

- Configurar dos bloques `provider "aws"` con alias distintos para desplegar
  recursos simultaneamente en `us-east-1` (`aws.primary`) y `eu-west-3`
  (`aws.secondary`).
- Entender por que todos los recursos deben declarar `provider` explicito cuando
  no hay proveedor sin alias.
- Simular drift modificando un tag manualmente en la consola de S3 y detectarlo
  con `terraform plan -refresh-only`.
- Aplicar `terraform apply -refresh-only` para sincronizar el estado con la
  realidad sin generar cambios en la infraestructura.
- Usar el bloque `import {}` de Terraform 1.5+ para declarar la intencion de
  adoptar un recurso existente.
- Ejecutar `terraform plan -generate-config-out=generated.tf` para que Terraform
  escriba automáticamente el bloque `resource` completo del recurso importado.
- Revisar, ajustar e integrar el HCL generado al codigo del proyecto.
- Completar el flujo de adopción con `terraform apply` y verificar que el recurso
  queda gestionado sin haber sido recreado.

## Requisitos previos

- Terraform >= 1.5 instalado.
- AWS CLI configurado con perfil `default`.
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado.
- Permisos IAM sobre S3 y SSM Parameter Store en **ambas regiones**.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
```

## Arquitectura

```
Terraform CLI (maquina local)
│
├─► provider "aws" alias = "primary"  [us-east-1]
│   │
│   ├─► aws_s3_bucket.artifacts_primary
│   │     lab39-artifacts-<ACCOUNT_ID>-use1
│   │     Versionado habilitado · Acceso publico bloqueado
│   │     Tags: Name, Project, Environment, Region, Owner  ◄── TARGET DEL DRIFT
│   │
│   ├─► aws_s3_bucket_versioning.artifacts_primary
│   ├─► aws_s3_bucket_public_access_block.artifacts_primary
│   │
│   └─► aws_ssm_parameter.config_primary
│         /${project}/config/primary-region = "us-east-1"
│
└─► provider "aws" alias = "secondary" [eu-west-3]
    │
    ├─► aws_s3_bucket.artifacts_secondary
    │     lab39-artifacts-<ACCOUNT_ID>-euw3
    │     Versionado habilitado · Acceso publico bloqueado
    │
    ├─► aws_s3_bucket_versioning.artifacts_secondary
    ├─► aws_s3_bucket_public_access_block.artifacts_secondary
    │
    └─► aws_ssm_parameter.config_secondary
          /${project}/config/secondary-region = "eu-west-3"

── Flujo de adopción de infraestructura existente ────────────────────────────

AWS CLI (fuera de Terraform)        Terraform state
┌───────────────────────────────┐   ┌────────────────────────────────────────┐
│  s3api create-bucket          │   │                                        │
│  lab39-legacy-logs-<ACCOUNT>  │   │  aws_s3_bucket.legacy_logs             │
│  (bucket sin gestion IaC)     │──►│  adoptado via bloque import {}         │
│                               │   │  HCL generado con -generate-config-out │
└───────────────────────────────┘   └────────────────────────────────────────┘

Pasos del flujo de importacion:
  1. Crear bucket con AWS CLI
  2. Escribir bloque import {} en main.tf
  3. terraform plan -generate-config-out=generated.tf
  4. Revisar y mover generated.tf → main.tf
  5. Eliminar bloque import {}
  6. terraform apply  →  recurso adoptado (sin recreacion)
```

## Conceptos clave

### Alias de proveedor

Cuando necesitas recursos en varias regiones dentro de la misma configuración,
declaras varios bloques `provider` del mismo tipo con aliases distintos:

```hcl
provider "aws" {
  alias  = "primary"
  region = "us-east-1"
}

provider "aws" {
  alias  = "secondary"
  region = "eu-west-3"
}
```

Cada recurso declara a cual de los dos proveedores pertenece:

```hcl
resource "aws_s3_bucket" "mi_bucket" {
  provider = aws.primary   # aws.<alias>
  bucket   = "mi-bucket"
}
```

**Regla importante**: cuando todos los bloques `provider` tienen alias, no
existe proveedor por defecto. Cualquier recurso que omita `provider` causara un
error `No default provider configured`. Debes ser explicito en cada recurso.

| Situación | Comportamiento |
|---|---|
| Un bloque sin alias | Es el proveedor por defecto; los recursos sin `provider` lo usan |
| Todos con alias | No hay proveedor por defecto; todos los recursos deben declarar `provider` |
| Mezcla | El bloque sin alias es el default; los bloques con alias son adicionales |

### Data sources con alias de proveedor

Los data sources tambien deben declarar `provider` cuando no hay proveedor por
defecto. `aws_caller_identity` se usa en el proveedor primario porque el
Account ID es el mismo en todas las regiones:

```hcl
data "aws_caller_identity" "current" {
  provider = aws.primary
}
```

### Drift y `terraform plan -refresh-only`

**Drift** es la discrepancia entre lo que Terraform registra en el estado
(`.tfstate`) y el estado real de la infraestructura en el proveedor.

Se produce cuando alguien modifica un recurso directamente en la consola,
con AWS CLI, o mediante otra herramienta fuera del flujo de Terraform.

```
Estado Terraform            Realidad en AWS
────────────────────────    ──────────────────────────────
Owner = "platform-team"     Owner = "devops-team"   ← drift
```

`terraform plan` normal detecta drift pero mezcla los cambios de drift con
los cambios de codigo, lo que puede generar confusión. La opción `-refresh-only`
separa ambas preocupaciones:

```bash
# Solo muestra lo que ha cambiado en AWS respecto al estado almacenado.
# No propone cambios de codigo. No toca la infraestructura real.
terraform plan -refresh-only

# Aplica solo la actualizacion del estado para que refleje la realidad actual.
# No modifica ningun recurso en AWS — solo reescribe el fichero .tfstate.
terraform apply -refresh-only
```

**¿Cuándo usar cada opción?**:

| Opción | Cuándo usarla |
|---|---|
| `terraform plan` | Proponer cambios de codigo a aplicar |
| `terraform plan -refresh-only` | Auditar drift sin proponer cambios de codigo |
| `terraform apply -refresh-only` | Aceptar el drift actual como estado correcto |
| `terraform apply` (despues del -refresh-only) | Revertir el drift aplicando el codigo como fuente de verdad |

Si quieres **revertir** el drift (volver al estado declarado en el codigo),
no uses `-refresh-only`; simplemente ejecuta `terraform apply` normal. Terraform
detectara la diferencia y restaurara el tag al valor del codigo.

### Bloque `import` (Terraform 1.5+)

El bloque `import` sustituye al comando `terraform import` (que sigue existiendo
pero es mas limitado). La ventaja del bloque declarativo es que se puede revisar
en pull request y forma parte del codigo fuente:

```hcl
import {
  provider = aws.primary          # obligatorio cuando no hay proveedor default
  to       = aws_s3_bucket.legacy_logs   # direccion del recurso en el estado
  id       = "nombre-del-bucket"         # identificador unico en AWS
}
```

**El bloque `import` solo declara la intencion** — Terraform no adopta el recurso
hasta que existe el bloque `resource` correspondiente en el codigo. Si ejecutas
`plan` con el bloque `import` pero sin el `resource`, Terraform falla con
`Configuration for import target does not exist`.

### `-generate-config-out`: generación automática de HCL

La opción `-generate-config-out` resuelve el problema de tener que escribir
manualmente el bloque `resource` para un recurso existente (que puede tener
decenas de atributos):

```bash
terraform plan -generate-config-out=generated.tf
```

Terraform inspecciona el recurso real en AWS, lee todos sus atributos y escribe
un bloque `resource` completo en `generated.tf`. El fichero generado:

- Incluye **todos** los atributos del recurso, incluidos los calculados por AWS.
- Puede contener atributos que no son necesarios o que conviene reemplazar por
  referencias a variables.
- Es un punto de partida que debes **revisar y limpiar** antes de integrarlo
  al codigo del proyecto.

**Flujo completo**:

```
1. Crear recurso fuera de Terraform (AWS CLI / consola)
          │
          ▼
2. Escribir bloque import {} en main.tf
   (SIN bloque resource todavia)
          │
          ▼
3. terraform plan -generate-config-out=generated.tf
   Terraform escribe el resource completo en generated.tf
          │
          ▼
4. Revisar generated.tf:
   - Eliminar atributos de solo lectura (id, arn, etc.) si causan errores
   - Reemplazar valores hardcoded por variables o referencias
   - Ajustar tags al estandar del proyecto
          │
          ▼
5. Mover el bloque resource de generated.tf a main.tf
   Eliminar (o comentar) el bloque import {}
          │
          ▼
6. terraform plan  →  "1 to import, 0 to add, 0 to change, 0 to destroy"
          │
          ▼
7. terraform apply  →  recurso adoptado en el estado sin recreacion
```

### Diferencia entre `terraform import` (comando) y bloque `import`

| | Comando `terraform import` | Bloque `import {}` |
|---|---|---|
| Versión mínima | Terraform 0.13+ | Terraform 1.5+ |
| Genera HCL | No (debes escribirlo tu) | Si, con `-generate-config-out` |
| Forma parte del codigo | No (es un comando imperativo) | Si (declarativo, revisable en PR) |
| Requiere resource previo | Si | No puede generarlo automáticamente) |
| Reversible en plan | No | Si (se puede hacer plan sin aplicar) |

## Estructura del proyecto

```
lab39/
├── aws/
│   ├── providers.tf        # Terraform >= 1.5 + dos alias de proveedor AWS ~> 6.0
│   ├── variables.tf        # primary_region, secondary_region, project, environment, legacy_bucket_name
│   ├── main.tf             # Recursos multi-region + bloque import (comentado)
│   ├── outputs.tf          # ARNs, nombres de bucket, comandos de verificacion
│   └── aws.s3.tfbackend    # Configuracion parcial del backend S3
└── README.md
```

Durante el Paso 4 (importacion), Terraform generara un fichero adicional:

```
lab39/
└── aws/
    └── generated.tf        # Generado automaticamente por -generate-config-out
                            # Revisar, limpiar e integrar en main.tf
```

## Despliegue en AWS real

### Paso 1 — Inicializar y desplegar la infraestructura multi-región

```bash
cd labs/lab39/aws

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

terraform plan
terraform apply
```

Durante el apply, observa como Terraform lanza llamadas API a dos regiones
distintas en paralelo:

```
aws_s3_bucket.artifacts_primary: Creating...   [us-east-1]
aws_s3_bucket.artifacts_secondary: Creating... [eu-west-3]
aws_ssm_parameter.config_primary: Creating...  [us-east-1]
aws_ssm_parameter.config_secondary: Creating.. [eu-west-3]
...
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
```

### Paso 2 — Verificar recursos en ambas regiones

```bash
# Outputs con los nombres de bucket y los comandos de verificacion
terraform output

# Verificar el bucket primario (us-east-1)
PRIMARY_BUCKET=$(terraform output -raw primary_bucket_name)
aws s3api get-bucket-location --bucket "${PRIMARY_BUCKET}"
# Esperado: { "LocationConstraint": null }  <- null significa us-east-1

aws s3api get-bucket-tagging --bucket "${PRIMARY_BUCKET}"
# Esperado: Tags con Owner = "platform-team"

# Verificar el bucket secundario (eu-west-3)
SECONDARY_BUCKET=$(terraform output -raw secondary_bucket_name)
aws s3api get-bucket-location \
  --bucket "${SECONDARY_BUCKET}" \
  --region eu-west-3
# Esperado: { "LocationConstraint": "eu-west-3" }

# Verificar parametros SSM en ambas regiones
aws ssm get-parameter \
  --name "/lab39/config/primary-region" \
  --region us-east-1 \
  --query "Parameter.Value" \
  --output text
# Esperado: us-east-1

aws ssm get-parameter \
  --name "/lab39/config/secondary-region" \
  --region eu-west-3 \
  --query "Parameter.Value" \
  --output text
# Esperado: eu-west-3
```

---

## Paso 3 — Simular Drift: modificar un tag manualmente

**Opción A — Consola de AWS** (recomendada para visualizar el flujo real):

1. Abre la consola de S3 en `us-east-1`.
2. Navega al bucket `lab39-artifacts-<ACCOUNT_ID>-use1`.
3. En la pestana **Properties** → **Tags**, edita el tag `Owner`.
4. Cambia el valor de `platform-team` a `devops-team` y guarda.

**Opción B — AWS CLI**:

```bash
PRIMARY_BUCKET=$(terraform output -raw primary_bucket_name)

aws s3api put-bucket-tagging \
  --bucket "${PRIMARY_BUCKET}" \
  --tagging '{
    "TagSet": [
      {"Key": "Name",        "Value": "lab39-artifacts-primary"},
      {"Key": "Project",     "Value": "lab39"},
      {"Key": "Environment", "Value": "production"},
      {"Key": "Region",      "Value": "us-east-1"},
      {"Key": "ManagedBy",   "Value": "terraform"},
      {"Key": "Owner",       "Value": "devops-team"}
    ]
  }'

# Verificar que el cambio se aplico en AWS
aws s3api get-bucket-tagging --bucket "${PRIMARY_BUCKET}"
```

En este momento existe drift: el estado de Terraform dice `Owner = "platform-team"`
pero la realidad en AWS es `Owner = "devops-team"`.

---

## Paso 4 — Detectar drift con `-refresh-only`

```bash
# Muestra solo las diferencias entre el estado almacenado y la realidad en AWS.
# NO propone cambios de codigo. NO toca la infraestructura.
terraform plan -refresh-only
```

La salida mostrara algo similar a:

```
Note: Objects have changed outside of Terraform

Terraform detected the following changes made outside of Terraform since the
last "terraform apply" which may have changed the result of "terraform plan":

  # aws_s3_bucket.artifacts_primary has changed
  ~ resource "aws_s3_bucket" "artifacts_primary" {
        id = "lab39-artifacts-123456789012-use1"
      ~ tags = {
          ~ "Owner" = "platform-team" -> "devops-team"
            # (5 unchanged elements hidden)
        }
      ~ tags_all = {
          ~ "Owner" = "platform-team" -> "devops-team"
            # (5 unchanged elements hidden)
        }
      ~ versioning {
          ~ enabled = false -> true
            # (1 unchanged attribute hidden)
        }
        # (7 unchanged attributes hidden)
    }

  # aws_s3_bucket.artifacts_secondary has changed
  ~ resource "aws_s3_bucket" "artifacts_secondary" {
      ~ versioning {
          ~ enabled = false -> true
            # (1 unchanged attribute hidden)
        }
        # (15 unchanged attributes hidden)
    }

This is a refresh-only plan, so Terraform will not take any actions to undo
these changes. If you were expecting these changes then you can apply this plan
to update the Terraform state to match the current configuration of the real
infrastructure.
```

Terraform ha detectado el drift pero aun no ha tomado ninguna accion.

> **Nota — drift "fantasma" en `versioning`**: es normal ver `versioning { enabled = false -> true }`
> en **ambos** buckets aunque solo hayas modificado el tag del primario.
> Esto es un artefacto del provider AWS: cuando `aws_s3_bucket` se crea,
> el estado registra `enabled = false`; despues, `aws_s3_bucket_versioning`
> activa el versionado en AWS, pero el estado del recurso `aws_s3_bucket`
> no se actualiza hasta el siguiente refresh. No indica un problema real —
> la infraestructura es correcta. `terraform apply -refresh-only` sincronizara
> ambos atributos (el tag y el versionado) en el estado sin tocar nada en AWS.

---

## Paso 5 — Decidir como gestionar el drift

Tienes dos opciones:

### Opción A: Aceptar el drift (sincronizar el estado con la realidad)

Usa `-refresh-only` cuando la modificacion manual fue intencionada y quieres
que Terraform la reconozca como el nuevo estado correcto. **El codigo HCL
no cambia**, pero el `.tfstate` se actualiza.

```bash
terraform apply -refresh-only
```

```
Do you want to update the Terraform state to reflect these detected changes?
  Only the Terraform state will be updated; the configuration and managed
  infrastructure will remain unchanged.

  Enter a value: yes

Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
```

Tras el apply, el estado ya contiene `Owner = "devops-team"`. Sin embargo,
el codigo HCL sigue declarando `"platform-team"`, por lo que **el trabajo no
termina aqui**. Para que la situación sea estable debes actualizar el HCL
a continuacion:

```hcl
# main.tf — actualizar el tag para que concilie con la realidad aceptada
tags = {
  ...
  Owner = "devops-team"   # actualizado tras aceptar el drift
  ...
}
```

```bash
# Confirmar que codigo y estado coinciden
terraform plan
# Esperado: No changes. Your infrastructure matches the configuration.
```

> **Resumen del flujo completo al aceptar drift**:
> 1. `terraform apply -refresh-only` → sincroniza el **estado** con AWS
> 2. Editar el **HCL** para reflejar el nuevo valor aceptado
> 3. `terraform plan` → confirma que no hay mas diferencias
>
> Omitir el paso 2 deja el codigo desincronizado con el estado. El proximo
> `terraform apply` normal revertira el cambio porque el HCL sigue siendo
> la fuente de verdad.

### Opción B: Revertir el drift (restaurar lo que declara el codigo)

Si la modificacion manual fue un error y quieres restaurar el valor original:

```bash
# NO uses -refresh-only. Ejecuta un apply normal.
# Terraform ve la diferencia (estado vs AWS real) y propone corregirla.
terraform plan    # muestra: ~ Owner = "devops-team" -> "platform-team"
terraform apply   # restaura el tag al valor del codigo HCL
```

---

## Paso 6 — Crear el bucket "legacy" fuera de Terraform

Simula un bucket que existia antes de que el equipo adoptara Terraform.
Lo creamos con AWS CLI para imitar la situación real:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LEGACY_BUCKET="lab39-legacy-logs-${ACCOUNT_ID}"

# Crear el bucket en us-east-1
aws s3api create-bucket \
  --bucket "${LEGACY_BUCKET}" \
  --region us-east-1

# Anadir algunos tags para simular que ya tiene configuracion
aws s3api put-bucket-tagging \
  --bucket "${LEGACY_BUCKET}" \
  --tagging '{
    "TagSet": [
      {"Key": "Name",    "Value": "lab39-legacy-logs"},
      {"Key": "Purpose", "Value": "application-logs"},
      {"Key": "Created", "Value": "manually"}
    ]
  }'

# Bloquear acceso publico (buena practica que Terraform debera reflejar)
aws s3api put-public-access-block \
  --bucket "${LEGACY_BUCKET}" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Bucket legacy creado: ${LEGACY_BUCKET}"
```

---

## Paso 7 — Declarar la intencion de adoptar el bucket con `import {}`

Abre [aws/main.tf](aws/main.tf) y localiza el bloque `import` comentado al
final del fichero. Descomenta las cinco lineas eliminando los `#`:

```hcl
# ANTES (comentado):
# import {
#   provider = aws.primary
#   to       = aws_s3_bucket.legacy_logs
#   id       = var.legacy_bucket_name
# }

# DESPUES (activo):
import {
  provider = aws.primary
  to       = aws_s3_bucket.legacy_logs
  id       = var.legacy_bucket_name
}
```

Los tres atributos del bloque significan:

| Atributo | Valor | Para que sirve |
|---|---|---|
| `provider` | `aws.primary` | Indica a Terraform en qué región buscar el bucket. Obligatorio porque no hay proveedor por defecto en este proyecto. |
| `to` | `aws_s3_bucket.legacy_logs` | Direccion que tendra el recurso dentro del estado de Terraform una vez adoptado. |
| `id` | `var.legacy_bucket_name` | Identificador del recurso en AWS — para un bucket S3 es simplemente su nombre. |

Guarda el fichero. En este momento el bloque `import` existe pero **no hay
ningun bloque `resource "aws_s3_bucket" "legacy_logs"`** en el codigo. Si
ejecutaras `terraform plan` a secas, Terraform fallaria con:

```
Error: Cannot generate a resource configuration for an import target

  on main.tf: import block
    import.to is aws_s3_bucket.legacy_logs

  Configuration for import target does not exist. If you wish to generate
  configuration for this resource, use the -generate-config-out option.
```

Es exactamente lo que esperamos — en el Paso 8 usaremos `-generate-config-out`
para que Terraform genere ese bloque `resource` automáticamente.

---

## Paso 8 — Generar el HCL automáticamente con `-generate-config-out`

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

terraform plan \
  -var="legacy_bucket_name=lab39-legacy-logs-${ACCOUNT_ID}" \
  -generate-config-out=generated.tf
```

Terraform inspeccionara el bucket en AWS, leera todos sus atributos y
escribira el bloque `resource` completo en `generated.tf`. La salida será
similar a:

```
aws_s3_bucket.legacy_logs: Preparing import... [id=lab39-legacy-logs-123456789012]
aws_s3_bucket.legacy_logs: Refreshing state... [id=lab39-legacy-logs-123456789012]

Terraform will perform the following actions:

  # aws_s3_bucket.legacy_logs will be imported
    resource "aws_s3_bucket" "legacy_logs" {
        arn                         = "arn:aws:s3:::lab39-legacy-logs-123456789012"
        bucket                      = "lab39-legacy-logs-123456789012"
        bucket_domain_name          = "lab39-legacy-logs-123456789012.s3.amazonaws.com"
        ...
    }

Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.
```

---

## Paso 9 — Revisar y limpiar el HCL generado

Abre `generated.tf`. Terraform incluye una cabecera de advertencia seguida
del bloque `resource` con los atributos que leyo del bucket real en AWS:

```hcl
# __generated__ by Terraform
# Please review these resources and move them into your main configuration files.

# __generated__ by Terraform from "lab39-legacy-logs-123456789012"
resource "aws_s3_bucket" "legacy_logs" {
  provider            = aws.primary
  bucket              = "lab39-legacy-logs-123456789012"
  bucket_namespace    = "global"
  force_destroy       = false
  object_lock_enabled = false
  region              = "us-east-1"
  tags = {
    Created = "manually"
    Name    = "lab39-legacy-logs"
    Purpose = "application-logs"
  }
  tags_all = {
    Created = "manually"
    Name    = "lab39-legacy-logs"
    Purpose = "application-logs"
  }
}
```

Antes de moverlo a `main.tf`, limpia los atributos que no deben declararse
en el codigo:

```hcl
# ANTES (tal como lo genera Terraform):
resource "aws_s3_bucket" "legacy_logs" {
  provider            = aws.primary
  bucket              = "lab39-legacy-logs-123456789012"  # sustituir por var.legacy_bucket_name
  bucket_namespace    = "global"                          # ELIMINAR: atributo interno, no modificable
  force_destroy       = false                             # opcional, puedes dejarlo
  object_lock_enabled = false                             # opcional, puedes dejarlo
  region              = "us-east-1"                       # ELIMINAR: inferida del proveedor
  tags = {
    Created = "manually"
    Name    = "lab39-legacy-logs"
    Purpose = "application-logs"
  }
  tags_all = {                                            # ELIMINAR: calculado por Terraform
    Created = "manually"
    Name    = "lab39-legacy-logs"
    Purpose = "application-logs"
  }
}

# DESPUES (limpiado y adaptado al estandar del proyecto):
resource "aws_s3_bucket" "legacy_logs" {
  provider = aws.primary
  bucket   = var.legacy_bucket_name

  tags = {
    Name      = "lab39-legacy-logs"
    Project   = var.project
    ManagedBy = "terraform"   # Actualizado: ahora si esta gestionado
    Purpose   = "application-logs"
  }
}
```

**Atributos a eliminar del HCL generado**:

| Atributo | Razon para eliminar |
|---|---|
| `bucket_namespace` | Atributo interno del provider, no se puede gestionar |
| `region` | Inferida del alias de proveedor, declararlo es redundante |
| `tags_all` | Calculado por Terraform (union de `tags` + `default_tags` del provider) |

---

## Paso 10 — Mover el resource a `main.tf` y aplicar

> **Error frecuente**: NO elimines el bloque `import {}` todavia. Debe
> permanecer en `main.tf` durante el `terraform apply` de este paso. Es
> el que le indica a Terraform que el bucket ya existe y debe adoptarlo,
> no crearlo. Si lo eliminas antes del apply, Terraform intentara crear
> el bucket y fallara con `BucketAlreadyExists`.

**Orden correcto**:

1. Copia el bloque `resource "aws_s3_bucket" "legacy_logs"` limpio de
   `generated.tf` a `main.tf`. El bloque `import {}` sigue activo.

2. Borra `generated.tf` (el contenido util ya esta en `main.tf`):

```bash
rm generated.tf
```

3. Verifica que `main.tf` tiene **ambos** bloques al mismo tiempo:

```hcl
# bloque import — todavia activo
import {
  provider = aws.primary
  to       = aws_s3_bucket.legacy_logs
  id       = var.legacy_bucket_name
}

# bloque resource — recien anadido desde generated.tf
resource "aws_s3_bucket" "legacy_logs" {
  provider = aws.primary
  bucket   = var.legacy_bucket_name
  tags     = { ... }
}
```

4. Ejecuta plan para confirmar que Terraform ve el import, no una creacion:

```bash
terraform plan \
  -var="legacy_bucket_name=lab39-legacy-logs-${ACCOUNT_ID}"
```

La linea clave del resumen debe decir **import**, no **add**:

```
Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.
```

Si ves `1 to change`, revisa los atributos del resource y ajustalos para
que coincidan con el estado real del bucket antes de continuar.

5. Aplica para adoptar el bucket en el estado de Terraform:

```bash
terraform apply \
  -var="legacy_bucket_name=lab39-legacy-logs-${ACCOUNT_ID}"
```

```
aws_s3_bucket.legacy_logs: Importing... [id=lab39-legacy-logs-123456789012]
aws_s3_bucket.legacy_logs: Import complete [id=lab39-legacy-logs-123456789012]

Apply complete! Resources: 1 imported, 0 added, 0 changed, 0 destroyed.
```

6. **Ahora si** elimina o comenta el bloque `import {}` de `main.tf`. Ya
   no es necesario: el recurso esta registrado en el estado y Terraform lo
   gestionara como cualquier otro recurso a partir de este momento.

7. Opcionalmente, elimina la variable `legacy_bucket_name` de `variables.tf`
   y sustituye su uso en el bloque `resource` por el nombre literal del bucket.
   La variable solo fue necesaria durante el flujo de importacion; una vez
   completado, el nombre del bucket es un valor fijo que no cambiara:

```hcl
# Antes (con variable):
resource "aws_s3_bucket" "legacy_logs" {
  provider = aws.primary
  bucket   = var.legacy_bucket_name
  ...
}

# Despues (nombre literal — ya no necesitas pasar -var en cada comando):
resource "aws_s3_bucket" "legacy_logs" {
  provider = aws.primary
  bucket   = "lab39-legacy-logs-123456789012"
  ...
}
```

**El bucket existe exactamente igual que antes en AWS** — Terraform solo ha
registrado su existencia en el estado. A partir de ahora cualquier cambio
en el bloque `resource` se gestionara mediante `terraform apply`.

---

## Verificación final

```bash
# El bucket legacy aparece ahora en el estado de Terraform
terraform state list | grep legacy
# Esperado: aws_s3_bucket.legacy_logs

# Ver todos los atributos que Terraform conoce del bucket
terraform state show aws_s3_bucket.legacy_logs

# Un plan sin cambios de codigo confirma que la adopción fue limpia
terraform plan -var="legacy_bucket_name=lab39-legacy-logs-${ACCOUNT_ID}"
# Esperado: No changes. Your infrastructure matches the configuration.
```

---

## Retos

### Reto 1 — Revertir drift en la región secundaria

El ejercicio principal de drift se realizo sobre el bucket de `us-east-1`.
En este reto lo reproduciras sobre `eu-west-3` y exploraras la diferencia
entre los dos enfoques de resolucion.

**Objetivo**:

1. Modifica manualmente el tag `Owner` del bucket `lab39-artifacts-<ACCOUNT_ID>-euw3`
   en la región `eu-west-3` (consola o AWS CLI).

2. Ejecuta `terraform plan -refresh-only` y confirma que Terraform detecta
   el drift solo en el recurso secundario.

3. Esta vez elige **revertir** el drift en lugar de aceptarlo: ejecuta
   `terraform apply` (sin `-refresh-only`) y verifica que el tag vuelve al
   valor declarado en el codigo.

4. Explica en un comentario en `main.tf` en que situaciones elegiras
   "aceptar el drift" (`-refresh-only`) frente a "revertir el drift"
   (`apply` normal).

**Pista**: para modificar el tag via CLI en `eu-west-3` necesitas pasar
`--region eu-west-3` a todos los comandos `s3api`.

---

### Reto 2 — Adoptar un parametro SSM existente

El bloque `import` no se limita a buckets S3. Cualquier recurso de Terraform
soportado puede adoptarse con la misma tecnica.

**Objetivo**:

1. Crea manualmente un parametro SSM en `us-east-1` con AWS CLI:

```bash
aws ssm put-parameter \
  --name "/lab39/legacy/db-endpoint" \
  --value "legacy-db.internal.example.com" \
  --type "String" \
  --description "Endpoint de base de datos legada — creado antes de IaC" \
  --region us-east-1
```

2. Escribe un bloque `import {}` en `main.tf` para el recurso
   `aws_ssm_parameter.legacy_db`:

```hcl
import {
  provider = aws.primary
  to       = aws_ssm_parameter.legacy_db
  id       = "/lab39/legacy/db-endpoint"
}
```

3. Ejecuta `terraform plan -generate-config-out=generated_ssm.tf`. Observaras
   que el plan falla con un error de validación: Terraform genera `value = null`
   porque no vuelca el valor real del parametro en el fichero (podría ser un
   secreto). Deberas añadir el valor manualmente en el paso de limpieza.

4. Limpia el HCL generado, muevelo a `main.tf` y completa el flujo de
   adopcion con `terraform apply`.

5. Verifica con `terraform state show aws_ssm_parameter.legacy_db` que
   el parametro esta ahora gestionado por Terraform.

**Por que es interesante**: el identificador de un parametro SSM en el
bloque `import` es el **nombre completo** del parametro (con el slash
inicial), no su ARN. Cada tipo de recurso tiene su propio formato de ID
para el import — siempre puedes consultarlo en la sección "Import" de la
documentacion del recurso en el Terraform Registry.

---

## Soluciones

<details>
<summary>Reto 1 — Revertir drift en la región secundaria</summary>

**Simular drift en eu-west-3 con CLI**:

```bash
SECONDARY_BUCKET=$(terraform output -raw secondary_bucket_name)

aws s3api put-bucket-tagging \
  --bucket "${SECONDARY_BUCKET}" \
  --region eu-west-3 \
  --tagging '{
    "TagSet": [
      {"Key": "Name",        "Value": "lab39-artifacts-secondary"},
      {"Key": "Project",     "Value": "lab39"},
      {"Key": "Environment", "Value": "production"},
      {"Key": "Region",      "Value": "eu-west-3"},
      {"Key": "ManagedBy",   "Value": "terraform"},
      {"Key": "Owner",       "Value": "devops-team"}
    ]
  }'
```

**Detectar drift con -refresh-only**:

```bash
terraform plan -refresh-only
```

Terraform mostrara el drift en `aws_s3_bucket.artifacts_secondary` sin
proponer ningun otro cambio.

**Revertir el drift con apply normal**:

```bash
# Sin -refresh-only: Terraform usa el codigo como fuente de verdad
terraform plan   # muestra: ~ Owner = "devops-team" -> "platform-team"
terraform apply  # restaura el tag
```

**Verificar**:

```bash
aws s3api get-bucket-tagging \
  --bucket "${SECONDARY_BUCKET}" \
  --region eu-west-3 \
  --query "TagSet[?Key=='Owner'].Value" \
  --output text
# Esperado: platform-team  (valor del codigo HCL)
```

**Cuando aceptar vs revertir drift**:

```hcl
# Pautas para decidir (añadir como comentario en main.tf):
#
# Acepta el drift (-refresh-only apply) cuando:
#   - El cambio manual fue intencional y acordado por el equipo.
#   - No tienes tiempo de actualizar el codigo ahora pero lo haras pronto.
#   - El cambio refleja una realidad operacional que el codigo aun no captura.
#
# Revierte el drift (apply normal) cuando:
#   - El cambio manual fue un error o no autorizado.
#   - El codigo HCL es la fuente de verdad y el estado actual viola esa definicion.
#   - Quieres mantener la trazabilidad completa: todo cambio pasa por git.
```

</details>

<details>
<summary>Reto 2 — Adoptar un parametro SSM existente</summary>

**1. Crear el parametro SSM con AWS CLI**:

```bash
aws ssm put-parameter \
  --name "/lab39/legacy/db-endpoint" \
  --value "legacy-db.internal.example.com" \
  --type "String" \
  --description "Endpoint de base de datos legada — creado antes de IaC" \
  --region us-east-1

# Verificar que existe
aws ssm get-parameter \
  --name "/lab39/legacy/db-endpoint" \
  --region us-east-1
```

**2. Bloque import en `main.tf`**:

```hcl
import {
  provider = aws.primary
  to       = aws_ssm_parameter.legacy_db
  id       = "/lab39/legacy/db-endpoint"
}
```

**3. Generar HCL**:

```bash
terraform plan -generate-config-out=generated_ssm.tf
cat generated_ssm.tf
```

El HCL generado tendra un aspecto similar a:

```hcl
resource "aws_ssm_parameter" "legacy_db" {
  provider         = aws.primary
  allowed_pattern  = null
  arn              = "arn:aws:ssm:us-east-1:123456789012:parameter/lab39/legacy/db-endpoint"
  data_type        = "text"
  description      = "Endpoint de base de datos legada — creado antes de IaC"
  name             = "/lab39/legacy/db-endpoint"
  overwrite        = null
  region           = "us-east-1"
  tags             = {}
  tags_all         = {}
  tier             = "Standard"
  type             = "String"
  value            = null # sensitive
  value_wo         = null # sensitive
  value_wo_version = null
}
```

> **Limitacion de `-generate-config-out` con SSM**: Terraform marca `value`
> y `value_wo` como `null # sensitive` porque no vuelca valores sensibles en
> ficheros de texto plano. Si intentas ejecutar `terraform plan` con el fichero
> tal cual, el provider falla con `one of insecure_value,value,value_wo must
> be specified`. Deberás añadir el valor manualmente en el paso de limpieza.

**4. HCL limpio para `main.tf`**:

Elimina los atributos que no deben declararse y añade el valor manualmente:

| Atributo | Accion |
|---|---|
| `arn` | Eliminar — calculado por AWS |
| `allowed_pattern = null` | Eliminar — null es el valor por defecto |
| `overwrite = null` | Eliminar — null es el valor por defecto |
| `region` | Eliminar — inferida del proveedor |
| `tags_all` | Eliminar — calculado por Terraform |
| `value_wo = null` | Eliminar — no aplica para parametros de tipo String |
| `value_wo_version = null` | Eliminar — asociado a value_wo |
| `value = null` | Sustituir por el valor real del parametro (`legacy-db.internal.example.com`) |

```hcl
resource "aws_ssm_parameter" "legacy_db" {
  provider    = aws.primary
  name        = "/lab39/legacy/db-endpoint"
  type        = "String"
  tier        = "Standard"
  description = "Endpoint de base de datos legada — adoptado via import"
  value       = "legacy-db.internal.example.com"   # anadir manualmente

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
```

**5. Completar la adopción**:

```bash
# Eliminar el fichero generado (el contenido ya esta en main.tf)
rm generated_ssm.tf

# Verificar plan (1 to import, 0 to change, 0 to destroy)
terraform plan

# Adoptar el recurso
terraform apply
```

Una vez completado el apply, elimina el bloque `import {}` de `main.tf`.
A partir de este momento el parametro esta registrado en el estado y el
bloque `import` ya no tiene efecto:

```bash
# Confirmar que no hay cambios pendientes tras eliminar el bloque import
terraform plan
# Esperado: No changes. Your infrastructure matches the configuration.

# Confirmar que el parametro esta en el estado
terraform state show aws_ssm_parameter.legacy_db
```

**El formato de ID para distintos recursos**:

| Recurso | Formato del ID en import |
|---|---|
| `aws_s3_bucket` | Nombre del bucket |
| `aws_ssm_parameter` | Nombre completo del parametro (con `/` inicial) |
| `aws_instance` | ID de la instancia (`i-0abc1234...`) |
| `aws_iam_role` | Nombre del rol |
| `aws_security_group` | ID del security group (`sg-0abc1234...`) |
| `aws_vpc` | ID del VPC (`vpc-0abc1234...`) |

Siempre consulta la sección **Import** al final de la documentacion del
recurso en `registry.terraform.io/providers/hashicorp/aws` para el formato
exacto.

</details>

---

## Limpieza

```bash
cd labs/lab39/aws

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Si adoptaste el bucket legacy, terraform destroy lo incluira en la destruccion.
# Para preservarlo (si fuera un recurso real de produccion), eliminalo
# del estado antes de destruir:
#   terraform state rm aws_s3_bucket.legacy_logs

terraform destroy

# Si el bucket legacy no fue adoptado por Terraform, eliminalo manualmente:
aws s3 rm "s3://lab39-legacy-logs-${ACCOUNT_ID}" --recursive
aws s3api delete-bucket \
  --bucket "lab39-legacy-logs-${ACCOUNT_ID}" \
  --region us-east-1

# Eliminar el parametro SSM legacy si lo creaste en el Reto 2
aws ssm delete-parameter \
  --name "/lab39/legacy/db-endpoint" \
  --region us-east-1

# Limpiar ficheros temporales generados durante el laboratorio
rm -f generated.tf generated_ssm.tf
```

---

## Buenas prácticas aplicadas

- **Todos los recursos declaran `provider` explicito**: al no haber proveedor
  sin alias, omitir `provider` causaría un error. La declaración explícita
  tambien hace que la intencion regional sea evidente en el codigo.
- **Sufijos de región en los nombres de bucket**: `-use1` y `-euw3` evitan
  colisiones accidentales y hacen inmediatamente visible la región de cada
  recurso en listados y logs.
- **`-refresh-only` antes de decidir**: ejecutar `plan -refresh-only` como
  primer paso ante cualquier sospecha de drift proporciona visibilidad sin
  riesgo. Nunca apliques drift sin haberlo revisado primero.
- **Revision del HCL generado**: `-generate-config-out` es un punto de
  partida, no código de producción. Revisa siempre el fichero generado antes
  de integrarlo: elimina atributos de solo lectura, reemplaza valores
  hardcoded por variables y actualiza los tags al estandar del proyecto.
- **El bloque `import` como codigo revisable**: a diferencia del comando
  `terraform import`, el bloque declarativo forma parte del historial de git
  y puede revisarse en pull request, documentando la decision de adoptar cada
  recurso.
- **`terraform state rm` antes de destruir recursos adoptados**: si decides
  destruir la infraestructura del laboratorio pero quieres preservar un recurso
  adoptado (por ejemplo, el bucket legacy es de producción), elimínalo del
  estado con `terraform state rm` antes de ejecutar `destroy`. Esto le dice
  a Terraform que deje de gestionar ese recurso sin borrarlo de AWS.

---

## Recursos

- [Multiple Provider Configurations — Terraform Docs](https://developer.hashicorp.com/terraform/language/providers/configuration#alias-multiple-provider-configurations)
- [Import block — Terraform 1.5+](https://developer.hashicorp.com/terraform/language/import)
- [Generating Configuration — `-generate-config-out`](https://developer.hashicorp.com/terraform/language/import/generating-configuration)
- [Refresh-Only Plans — Terraform Docs](https://developer.hashicorp.com/terraform/cli/commands/plan#planning-modes)
- [Resource: aws_s3_bucket — Import](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket#import)
- [Resource: aws_ssm_parameter — Import](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter#import)
