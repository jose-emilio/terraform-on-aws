# Sección 3 — Bloqueo del State (State Locking)

> [← Sección anterior](./02_backend_s3.md) | [Siguiente →](./04_otros_backends.md)

---

## 3.1 El Problema de la Concurrencia en Equipos

Sin mecanismo de bloqueo, dos ejecuciones simultáneas de `terraform apply` pueden leer el mismo State, calcular cambios independientes y sobrescribirse mutuamente al guardar. El resultado es un **State corrupto e infraestructura inconsistente**.

**Escenario de colisión (Race Condition):**

```
1. Ingeniero A lee el State (v5)
2. Ingeniero B lee el State (v5)
3. A aplica cambios → escribe v6
4. B aplica cambios → sobrescribe con v6'
5. Cambios de A se pierden para siempre
→ State corrupto + recursos huérfanos
```

Las consecuencias de esta situación son graves:
- Recursos creados que el State no conoce (huérfanos en la nube)
- Drift silencioso entre infraestructura real y declarada
- Posible destrucción de recursos de producción en el siguiente `plan`
- Recuperación manual costosa: `terraform import` recurso por recurso

---

## 3.2 Mecanismo de Locking con DynamoDB

DynamoDB actúa como un **semáforo de red**: antes de modificar el State, Terraform intenta adquirir un lock exclusivo. Si otro proceso ya lo tiene, la operación se rechaza hasta que se libere.

**Flujo de bloqueo:**

```
1. Adquisición del Lock
   Terraform escribe un registro en DynamoDB con PutItem condicional

2. Verificación
   Si el registro ya existe → error: "State locked"

3. Ejecución de plan/apply
   Terraform opera con exclusividad garantizada

4. Liberación del Lock
   Terraform elimina el registro de DynamoDB (DeleteItem)
```

> **Clave técnica:** DynamoDB usa escritura condicional (`PutItem` con `ConditionExpression`) que garantiza atomicidad. Si dos procesos intentan crear el lock al mismo tiempo, solo uno gana. El otro recibe un error inmediato.

---

## 3.3 Estructura de la Tabla de Locks

La tabla DynamoDB requiere una única Partition Key llamada exactamente `LockID` de tipo `String`. Terraform almacena un JSON completo con los metadatos del bloqueo:

| Campo | Tipo | Descripción |
|-------|------|-------------|
| `LockID` | String (PK) | Path del State en S3 (`bucket/key`) |
| `ID` | String | UUID único de esta ejecución |
| `Operation` | String | `plan`, `apply` o `destroy` |
| `Who` | String | `usuario@hostname` que tiene el lock |
| `Version` | String | Versión del binario de Terraform |
| `Created` | String | Timestamp ISO 8601 de adquisición |
| `Path` | String | Ruta completa del State bloqueado |

El campo `Who` es especialmente útil: cuando el lock está activo, puedes saber exactamente quién lo tiene y contactarlo.

---

## 3.4 Código: Backend S3 + DynamoDB Lock

Configuración completa con locking:

```hcl
# --- backend.tf ---
terraform {
  backend "s3" {
    bucket          = "mi-empresa-terraform-state"
    key             = "prod/networking/terraform.tfstate"
    region          = "eu-west-1"
    encrypt         = true
    dynamodb_table  = "terraform-lock-table"   # ← Locking con DynamoDB (deprecated desde TF 1.11 — ver Sección 3.4)
  }
}

# --- dynamodb.tf --- (en un proyecto bootstrap separado)
resource "aws_dynamodb_table" "terraform_lock" {
  name         = "terraform-lock-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

---

## 3.5 Permisos IAM: S3 + DynamoDB

La política IAM mínima que necesita el rol de Terraform para operar con locking:

```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
  "Resource": "arn:aws:s3:::mi-bucket/*"
},
{
  "Effect": "Allow",
  "Action": "s3:ListBucket",
  "Resource": "arn:aws:s3:::mi-bucket"
},
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:GetItem",    // Leer lock actual
    "dynamodb:PutItem",    // Adquirir lock
    "dynamodb:DeleteItem"  // Liberar lock
  ],
  "Resource": "arn:aws:dynamodb:*:*:table/terraform-lock-table"
}
```

Principio de mínimo privilegio: limita el `Resource` al ARN exacto de la tabla para evitar acceso a otras tablas.

---

## 3.6 Native S3 Locking (Terraform v1.10+)

A partir de Terraform v1.10, el backend S3 incluye locking nativo sin necesidad de DynamoDB. Con `use_lockfile = true`, Terraform crea automáticamente un archivo `.tflock` junto al `.tfstate` en el mismo bucket:

```hcl
# --- backend.tf --- (Terraform >= 1.10)
terraform {
  backend "s3" {
    bucket       = "mi-empresa-terraform-state"
    key          = "prod/networking/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true   # ← Native S3 Locking — sin DynamoDB
    # dynamodb_table ya NO es necesario
  }
}
```

Estructura en S3:
```
s3://mi-empresa-terraform-state/
├── prod/networking/terraform.tfstate
└── prod/networking/terraform.tfstate.tflock
```

Esto elimina la necesidad de gestionar una tabla DynamoDB adicional, simplificando la arquitectura del backend sin sacrificar la seguridad del bloqueo.

---

## 3.7 Timeouts de Lock: `-lock-timeout`

El flag `-lock-timeout` indica a Terraform que reintente adquirir el lock durante un período en lugar de fallar inmediatamente. Es esencial para CI/CD donde dos pipelines pueden coincidir:

```bash
# Esperar hasta 3 minutos antes de fallar
$ terraform apply -lock-timeout=3m

# Plan con espera de 60 segundos
$ terraform plan -lock-timeout=60s

# Destroy con timeout largo para operaciones críticas
$ terraform destroy -lock-timeout=5m
```

**Cuándo usarlo:**
- Pipelines de CI/CD concurrentes — dos PRs mergeados casi simultáneamente
- Multi-workspace deploys — despliegues paralelos a dev y staging
- Equipos grandes — varios ingenieros operando en el mismo entorno

> **Valor recomendado:** Entre 2m y 5m. Suficiente para esperar un plan corto sin bloquear el pipeline indefinidamente.

---

## 3.8 Desactivación del Lock: `-lock=false`

El flag `-lock=false` desactiva completamente el mecanismo de bloqueo. Terraform no intentará adquirir ni liberar el lock:

```bash
# Inspección de emergencia (solo lectura) — uso aceptable
$ terraform state list -lock=false
$ terraform state show -lock=false aws_instance.web

# ⛔ NUNCA hacer esto en producción:
$ terraform apply -lock=false
$ terraform destroy -lock=false
# Escribir sin lock = invitar a la corrupción del State
```

> ❌ **Mala Práctica:** Usar `-lock=false` con operaciones de escritura (`apply`/`destroy`) es una de las formas más seguras de corromper tu State.  
> ✅ **Uso aceptable:** Solo inspección de emergencia con `state list` o `state show`.

---

## 3.9 Caso Real: Resolución de Conflicto de Lock

**Escenario:** Un pipeline de CI excedió el timeout de 30 minutos durante un `terraform apply`. GitHub Actions mató el runner, pero el lock en DynamoDB sigue activo. Nadie puede desplegar.

**SOP (Standard Operating Procedure):**

```
Paso 1: Verificar logs de CI
  Confirmar que el job fue cancelado por timeout (no está ejecutándose)
  $ gh run view 12345 --log-failed

Paso 2: Obtener el Lock ID
  Ejecutar terraform plan localmente para ver el mensaje de error
  $ terraform plan
  Error: Error acquiring the state lock
  Lock Info: ID: a1b2c3d4-e5f6-...

Paso 3: Forzar unlock desde local
  Con credenciales AWS y el Lock ID anotado:
  $ terraform force-unlock a1b2c3d4-e5f6-...

Paso 4: Verificar y re-ejecutar
  $ terraform plan  # Confirmar que el State es consistente
  # Relanzar el pipeline de CI
```

> **Precaución:** Antes de ejecutar `force-unlock`, asegúrate al 100% de que no hay ningún proceso activo usando el lock. Forzar un unlock mientras hay un `apply` en curso garantiza corrupción del State.

---

## 3.10 Resumen: La Importancia del Orden

El locking no es una molestia burocrática — es la salvaguarda que protege tu infraestructura de la corrupción. Sin él, la colaboración en equipo es una bomba de relojería.

| Herramienta | Propósito |
|-------------|-----------|
| DynamoDB locking | Exclusividad con escrituras condicionales (Terraform < 1.10) |
| S3 Native Locking | Mismo efecto sin DynamoDB (Terraform >= 1.10) |
| `-lock-timeout` | Resiliencia en pipelines CI/CD concurrentes |
| `force-unlock` | Recuperación de locks huérfanos tras fallos de CI |
| `-lock=false` | Solo para inspecciones de emergencia de solo lectura |

---

> **Siguiente:** [Sección 4 — Otros Backends →](./04_otros_backends.md)
