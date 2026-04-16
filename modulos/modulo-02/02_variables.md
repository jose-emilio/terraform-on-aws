# Sección 2 — Variables de Entrada

> [← Sección anterior](./01_sintaxis_hcl.md) | [← Volver al índice](./README.md) | [Siguiente →](./03_outputs_datasources.md)

---

## 2.1 ¿Por qué usar variables?

Imagina que escribes el código Terraform de una infraestructura completa con la región, el tipo de instancia y el nombre del bucket hardcodeados directamente en el código. Funciona perfectamente para ese entorno concreto. Pero cuando necesitas desplegar la misma infraestructura en producción con instancias más grandes, en otra región y con otro nombre de bucket, tendrías que duplicar todo el código cambiando esos valores.

Las variables eliminan exactamente este problema. Permiten que el código sea **reutilizable** evitando valores hardcodeados. Son como los argumentos de una función: el código define la lógica, las variables inyectan los datos.

| Sin Variables | Con Variables |
|--------------|---------------|
| Script de un solo uso | Módulo profesional y reutilizable |
| Valores fijos en el código | Configurable por entorno |
| Imposible reutilizar sin duplicar | Un mismo código → dev, staging, producción |

> **Analogía:** Las variables son como los argumentos de una función. La función define la lógica; los argumentos aportan los datos externos que cambian el resultado en cada llamada.

---

## 2.2 Declaración: bloque `variable {}`

Cada variable se declara con el bloque `variable` seguido de su nombre. Los atributos disponibles son:

- `type` — qué tipo de dato acepta
- `description` — para qué sirve (aparece en la ayuda de Terraform)
- `default` — valor si no se proporciona ninguno
- `validation` — reglas que el valor debe cumplir
- `sensitive` — ocultar el valor en la salida del CLI

```hcl
# Variable mínima — solo declara el tipo
variable "instancia_id" {
  type = string
}

# Variable profesional y completa
variable "region" {
  type        = string
  description = "Región AWS del despliegue"
  default     = "us-east-1"
}
```

---

## 2.3 Tipos Primitivos: string, number y bool

Los tres tipos primitivos cubren la mayoría de los casos de configuración de infraestructura:

```hcl
# string — para texto: nombres, IDs, regiones, URLs
variable "ami_id" {
  type        = string
  description = "ID de la AMI a usar (específico por región — obtener con data source en producción)"
  default     = "ami-0c55b159cbfafe1f0"   # placeholder us-east-1
}

# number — para enteros y decimales: capacidades, puertos, umbrales
variable "cpu_count" {
  type    = number
  default = 2
}

# bool — para interruptores activar/desactivar
variable "monitoring" {
  type    = bool
  default = true
}
```

Cada tipo cubre un caso de uso específico: `string` para texto, `number` para valores numéricos que se usan en cálculos o validaciones, `bool` para habilitar o deshabilitar características.

---

## 2.4 Tipos Complejos I: `list` y `set`

Para colecciones de datos del mismo tipo:

```hcl
# list — secuencia ORDENADA, acceso por índice
variable "subredes" {
  type = list(string)
  default = [
    "10.0.1.0/24",
    "10.0.2.0/24",
    "10.0.3.0/24"
  ]
}
# var.subredes[0] = "10.0.1.0/24"
# var.subredes[1] = "10.0.2.0/24"

# set — colección de valores ÚNICOS, sin orden garantizado
variable "sg_ids" {
  type = set(string)
  default = [
    "sg-abc123",
    "sg-def456"
  ]
}
# No admite duplicados. No hay acceso por índice.
```

Usa `list` cuando el orden importa o necesitas acceder a elementos por posición. Usa `set` cuando solo te importa si un valor está o no está en la colección, sin importar el orden.

---

## 2.5 Tipos Complejos II: `map` y `object`

Para estructuras de datos más ricas con múltiples atributos:

```hcl
# map — clave-valor donde todos los valores son del mismo tipo
variable "regiones" {
  type = map(string)
  default = {
    "us-east-1" = "Virginia"
    "eu-west-1" = "Irlanda"
    "ap-east-1" = "Hong Kong"
  }
}

# object — estructura tipada donde cada clave tiene su propio tipo
variable "servidor" {
  type = object({
    nombre = string
    cpus   = number
    activo = bool
  })
}
# Acceso: var.servidor.nombre, var.servidor.cpus
```

El `object` es más estricto que el `map`: define exactamente qué claves existen y qué tipo tiene cada una. Es ideal para agrupar configuraciones relacionadas como si fuera un struct o una clase.

---

## 2.6 Tipos Complejos III: `tuple`

`tuple` es la variante más rígida — una lista con número fijo de elementos donde **cada posición puede tener un tipo diferente**:

```hcl
# tuple: cada posición tiene su tipo predefinido
variable "config_servidor" {
  type    = tuple([string, number, bool])
  #                nombre, puerto, activo
  default = ["web-api", 8080, true]
}

# Acceso por índice posicional
# var.config_servidor[0] = "web-api"
# var.config_servidor[1] = 8080
# var.config_servidor[2] = true
```

El `tuple` es mucho más rígido y específico que una `list`. Úsalo cuando tengas una estructura fija de configuración donde el orden y el tipo de cada posición son parte del contrato.

---

## 2.7 Valores por Defecto vs. Variables Requeridas

La presencia o ausencia del atributo `default` determina si una variable es opcional u obligatoria:

```hcl
# Variable OPCIONAL — tiene default, no necesita valor externo
variable "region" {
  type    = string
  default = "us-east-1"
}
# Si no se proporciona valor, Terraform usa "us-east-1"

# Variable REQUERIDA — sin default, Terraform detiene la ejecución y pide el valor
variable "entorno" {
  type        = string
  description = "Entorno de despliegue: dev, staging o prod"
  # Sin default → es obligatoria
}
```

```
$ terraform plan
var.entorno
  Entorno de despliegue: dev, staging o prod

  Enter a value: _
```

Usa `default` para configuración estándar que raramente cambia. Sin `default` para datos críticos que deben proporcionarse explícitamente en cada despliegue — como el nombre del entorno o credenciales.

---

## 2.8 Validación Personalizada: `validation {}`

El bloque `validation` añade una capa de defensa temprana: si el valor proporcionado no cumple la regla, Terraform falla **antes de realizar ninguna llamada a la API de AWS**. Es mejor fallar al inicio que a mitad de un despliegue.

```hcl
variable "ami_id" {
  type        = string
  description = "ID de la AMI de Amazon — debe empezar por 'ami-'"

  validation {
    condition     = startswith(var.ami_id, "ami-")
    error_message = "El ID de la AMI debe empezar por 'ami-'. Ejemplo: ami-0c55b159cbfafe1f0"
  }
}
```

El campo `condition` es una expresión booleana que evalúa el valor. Si devuelve `false`, Terraform muestra `error_message` y para. Pueden existir múltiples bloques `validation` en una sola variable.

---

## 2.9 Variables Sensibles: `sensitive = true`

Para evitar que contraseñas, tokens o claves de API aparezcan en texto plano en los logs del plan:

```hcl
variable "db_password" {
  type      = string
  sensitive = true
}
```

```
# En terraform plan, el valor queda oculto:
+ password = (sensitive value)
```

> **Importante:** `sensitive = true` **no cifra** el valor en el archivo `.tfstate`. Solo oculta la salida en la terminal. Para proteger el state, usa backends remotos con cifrado activado (S3 + KMS).

---

## 2.10 Archivos `.tfvars`: El Método Estándar

Los archivos `.tfvars` separan la **declaración de variables** (en `variables.tf`) de los **valores concretos** (en `.tfvars`). Esto permite usar el mismo código con diferentes configuraciones por entorno:

```ini
# dev.tfvars — entorno de desarrollo
region  = "us-east-1"
entorno = "desarrollo"
cpus    = 1
```

```ini
# prod.tfvars — entorno de producción
region  = "eu-west-1"
entorno = "produccion"
cpus    = 4
```

```bash
# Aplicar con el entorno correcto
terraform plan -var-file=dev.tfvars
terraform plan -var-file=prod.tfvars
```

El mismo código base. Dos comportamientos completamente distintos. Cero duplicación.

---

## 2.11 Carga Automática: `.auto.tfvars`

Los archivos con la extensión `.auto.tfvars` se cargan automáticamente **sin necesidad de especificar `-var-file`**. Son ideales para configuraciones compartidas que no cambian entre entornos: IDs de organización, etiquetas globales, centros de coste.

```ini
# proyecto.auto.tfvars — se carga AUTOMÁTICAMENTE en cualquier terraform plan
org_id      = "org-abc123"
equipo      = "devops"
cost_center = "CC-4200"
```

```bash
# Sin .auto.tfvars — hay que especificarlo
terraform plan -var-file=proyecto.tfvars

# Con .auto.tfvars — se carga solo
terraform plan
```

---

## 2.12 Variables de Entorno: `TF_VAR_*`

Terraform busca variables de entorno con el prefijo `TF_VAR_`. Si tienes declarada `variable "region"`, Terraform leerá automáticamente el valor de `TF_VAR_region`. Es el método estándar en pipelines CI/CD para inyectar credenciales y configuraciones sin archivos de texto:

```bash
# En la terminal o en la configuración del pipeline
export TF_VAR_region="eu-west-1"
export TF_VAR_token="s3cr3t-t0k3n"

# Terraform lee los valores automáticamente
terraform plan  # No necesita -var-file ni valores interactivos
```

---

## 2.13 Precedencia de Asignación: ¿Quién Gana?

Cuando una variable se define en múltiples fuentes simultáneamente, Terraform aplica una jerarquía estricta de menor a mayor importancia. El valor con **mayor prioridad** siempre gana:

```
1. default en variables.tf          ← Menor prioridad
2. Variables de entorno (TF_VAR_)
3. terraform.tfvars (auto-cargado)
4. *.auto.tfvars (auto-cargado)
5. -var-file=archivo.tfvars         ← Mayor prioridad
6. -var="nombre=valor" en CLI       ← La máxima
```

Esta jerarquía permite construir flujos flexibles: valores por defecto en el código, sobrescritos por archivos de entorno, sobrescritos a su vez por flags del pipeline cuando es necesario.

---

## 2.14 Ejemplo Práctico: Variable Profesional Completa

Una variable de tipo `object` con descripción, validación y `sensitive`. Esta es la plantilla de referencia para el resto del curso:

```hcl
variable "db_config" {
  description = "Configuración completa de la base de datos de producción"

  type = object({
    host     = string
    port     = number
    password = string
  })

  sensitive = true   # Oculta el valor completo del objeto en la salida CLI
}

# Acceso a los atributos del objeto:
# var.db_config.host     → "db.prod.internal"
# var.db_config.port     → 5432
# var.db_config.password → (sensitive value)
```

---

## 2.15 Resumen y Buenas Prácticas

| Práctica | Descripción |
|---------|-------------|
| **Documenta** | Añade `description` clara en cada variable para que cualquier miembro del equipo sepa qué introducir |
| **Separa por entorno** | Un `.tfvars` distinto por entorno: `dev.tfvars`, `staging.tfvars`, `prod.tfvars` |
| **Valida siempre** | Usa `validation {}` para detectar errores de configuración antes del despliegue |
| **Marca sensibles** | Usa `sensitive = true` para cualquier secreto — contraseñas, tokens, claves |

> *"Valida siempre que puedas: es mejor que Terraform falle al inicio, antes del plan, que a mitad de un despliegue."*

---

> **Siguiente:** [Sección 3 — Outputs y Data Sources →](./03_outputs_datasources.md)
