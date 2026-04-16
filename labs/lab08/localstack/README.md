# Laboratorio 8: LocalStack: Refactorización Declarativa y Adopción de Infraestructura

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

> El bloque `import {}` es idempotente: si el recurso ya está en el estado con el mismo ID, no hace nada. Es seguro dejarlo en el código como documentación.

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

## Estructura del Laboratorio

```
lab08/
├── aws/
│   ├── providers.tf   # Requiere Terraform >= 1.7
│   ├── variables.tf   # Nombre del bucket a importar
│   ├── main.tf        # Evoluciona en cada fase del laboratorio
│   └── outputs.tf
└── localstack/
    ├── providers.tf   # Endpoints apuntando a LocalStack
    ├── variables.tf   # Nombre del bucket con valor por defecto
    ├── main.tf
    └── outputs.tf
```

---

## 1. Despliegue en LocalStack

### 1.1 Diferencias en `localstack/providers.tf`

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
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = "http://localhost.localstack.cloud:4566"
  }
}
```

El endpoint de S3 apunta a LocalStack. El resto del comportamiento de los bloques `import {}`, `moved {}` y `removed {}` es idéntico al de AWS real porque todos operan sobre el estado local de Terraform.

### 1.2 Fase 1 — Adopción (LocalStack)

**Paso 1** — Asegúrate de que LocalStack esté en ejecución:

```bash
localstack status
```

**Paso 2** — Crea el bucket fuera de Terraform en LocalStack:

```bash
aws --profile localstack s3 mb s3://lab8-import-local
```

**Paso 3** — Inicializa y genera la configuración:

```bash
# Desde lab08/localstack/
terraform fmt
terraform init
terraform plan -generate-config-out=generated.tf
```

> LocalStack puede generar atributos adicionales o con valores distintos a AWS real. Aplica los mismos criterios de limpieza: elimina los atributos computados (`id`, `arn`, `bucket_domain_name`, `hosted_zone_id`, `region`, `tags_all`) antes de integrar el bloque en `main.tf`.

**Pasos 4 al 6** — Idénticos a la sección AWS real: integra el bloque `resource` en `main.tf`, activa los outputs en `outputs.tf` y ejecuta `terraform apply`.

### 1.3 Fase 2 — Refactorización (LocalStack)

Idéntica a la sección AWS real. Los bloques `moved {}` operan exclusivamente sobre el estado local de Terraform; no realizan llamadas a la API de LocalStack ni recrean ningún recurso.

### 1.4 Fase 3 — Remoción (LocalStack)

Idéntica a la sección AWS real. El bloque `removed { lifecycle { destroy = false } }` opera exclusivamente sobre el estado local; no envía ninguna llamada de eliminación a LocalStack.

**Verificación tras el apply:**

```bash
terraform state list
aws --profile localstack s3 ls | grep lab8-import-local
```

El primer comando devuelve una lista vacía (el recurso fue retirado del estado). El segundo confirma que el bucket sigue existiendo en LocalStack.

### 1.5 Destruir los Recursos

```bash
aws --profile localstack s3 rb s3://lab8-import-local --force
```

---

## 2. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| Crear recurso previo | Consola o `aws s3 mb` | `aws --profile localstack s3 mb` |
| `-generate-config-out` | Genera config completa del recurso real | Soportado; algunos atributos pueden diferir |
| `moved {}` | Opera solo en estado local | Idéntico |
| `removed { destroy = false }` | Opera solo en estado local | Idéntico |
| Verificar existencia post-remoción | `aws s3 ls` | `aws --profile localstack s3 ls` |

---

## 3. Buenas Prácticas

- **Prefiere primitivas declarativas sobre comandos imperativos.** Los bloques `import {}`, `moved {}` y `removed {}` quedan en el historial de Git y son revisables en PR. `terraform state mv` y `terraform state rm` modifican el estado sin trazabilidad en el código.
- **Elimina `moved {}` y `removed {}` tras el apply en producción.** Son bloques de migración de un solo uso. Mantenerlos indefinidamente no causa errores pero aumenta el ruido en el código.
- **Revisa siempre `generated.tf` antes de aplicar.** El archivo puede contener atributos computados (`arn`, `id`, `tags_all`) que provocarán errores en el apply. Limpia el archivo o usa solo los atributos que necesitas gestionar.
- **Usa `import {}` en combinación con `-generate-config-out` para adoptar recursos existentes.** Si el recurso tiene una configuración compleja con muchos atributos, la generación automática ahorra tiempo y evita errores tipográficos.
- **`destroy = false` no es permanente en el ciclo de vida del recurso.** Una vez retirado del estado, si otro proyecto lo importa con `destroy = true` por defecto, el recurso podría eliminarse. Coordina con el equipo que tomará la gestión del recurso.
- **El bloque `import {}` es idempotente.** Si el recurso ya está en el estado con el mismo ID, el bloque no hace nada. Es seguro dejarlo en el código como documentación del origen del recurso.

---

## 4. Recursos Adicionales

- [Bloque `import` - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/import)
- [Generación de configuración con `-generate-config-out`](https://developer.hashicorp.com/terraform/language/import/generating-configuration)
- [Bloque `moved` - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/block/moved)
- [Bloque `removed` - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/resources/syntax#removing-resources)
- [Recurso aws_s3_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket)
