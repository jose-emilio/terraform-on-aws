# Sección 5 — Comandos del State

> [← Sección anterior](./04_otros_backends.md) | [Siguiente →](./06_workspaces.md)

---

## 5.1 La Maestría Quirúrgica del State

Saber crear infraestructura es solo la mitad del trabajo. La otra mitad es saber gestionar el State a lo largo del tiempo: renombrar recursos sin recrearlos, adoptar infraestructura existente, desvincular recursos obsoletos. Estos comandos te dan control quirúrgico sobre la memoria de Terraform.

La evolución del tooling refleja una filosofía clara: **preferir código sobre terminal**. Verás cómo cada comando imperativo tiene hoy su equivalente declarativo.

---

## 5.2 Auditoría del State: `list` y `show`

Antes de cualquier operación sobre el State, el primer paso es saber qué contiene:

```bash
# Listar todos los recursos gestionados
$ terraform state list
aws_instance.web
aws_s3_bucket.data
aws_vpc.main
```

`state list` es tu **inventario rápido** — el punto de partida para cualquier auditoría.

```bash
# Ver los atributos reales de un recurso específico
$ terraform state show aws_instance.web
id    = "i-0abc123def456"
ami   = "ami-0abcdef1234"
ip    = "10.0.1.42"
type  = "t3.micro"
...
```

`state show` muestra los valores reales almacenados en el State: el ID de la instancia en AWS, la IP asignada, el tipo de máquina. Esto te permite verificar el estado real sin abrir la consola web de AWS.

---

## 5.3 Refactorización Clásica: `terraform state mv`

Cuando renombras un recurso en tu código `.tf`, Terraform interpretaría un `delete + create`. El comando `state mv` actualiza el puntero en el State **sin tocar el recurso real en la nube**:

```bash
# Renombras en código: "web" → "server_prod"
$ terraform state mv \
    aws_instance.web \
    aws_instance.server_prod

# Move "aws_instance.web" to
# "aws_instance.server_prod"
Successfully moved 1 object(s).
```

**Efectos inmediatos:**
- El recurso en AWS sigue corriendo — sin downtime
- El State actualiza la referencia al nuevo nombre
- Las dependencias se recalculan automáticamente

> **Limitación:** `state mv` es un comando imperativo — se ejecuta en terminal y no queda registrado en el código. Para trabajo en equipo, el enfoque declarativo con `moved {}` es superior.

---

## 5.4 Refactoring Moderno: `moved` Blocks (v1.5+)

El bloque `moved` es la evolución declarativa de `state mv`. Permite reorganizar recursos o moverlos hacia módulos **directamente en el código HCL**, con trazabilidad completa en Git:

```hcl
moved {
  from = aws_instance.a
  to   = module.web.aws_instance.b
}

# git pull + terraform plan = 0 cambios
# El movimiento es transparente para todo el equipo
```

**Ventajas sobre `state mv`:**

| Aspecto | `state mv` | `moved {}` |
|---------|-----------|-----------|
| Trazabilidad | Solo en historial de terminal | En Git con Code Review |
| Trabajo en equipo | Cada miembro debe ejecutarlo | Solo `git pull` |
| Auditoría | Ninguna | Historial completo |
| Disponibilidad | Desde siempre | Terraform v1.5+ |

---

## 5.5 Extracción y Olvido: `terraform state rm`

El comando `rm` elimina un recurso del State **sin borrarlo de la nube**. Es la forma de sacar un recurso del control de Terraform para gestionarlo manualmente o moverlo a otro stack:

```bash
$ terraform state rm aws_instance.legacy
Removed aws_instance.legacy
Successfully removed 1 resource(s).
```

**Casos de uso:**
- Gestión manual: sacar un recurso para administrarlo fuera de Terraform
- Migración entre stacks: mover un recurso a otro proyecto Terraform
- Evitar delete accidental: el recurso en la nube permanece intacto

> **Importante:** Tras ejecutar `state rm`, si haces `terraform plan`, Terraform verá el recurso como "no gestionado" y querrá crearlo de nuevo (si su bloque `resource` sigue en el código). Elimina también el bloque del código o usa `removed {}`.

---

## 5.6 Remoción Declarativa: `removed` Blocks (v1.7+)

El bloque `removed` es el sucesor declarativo de `state rm`. Desconecta un recurso del State dejando constancia en Git — nada se borra sin un Code Review:

```hcl
# Desconectar recurso legacy sin destruirlo en la nube
removed {
  from = aws_instance.legacy

  lifecycle {
    destroy = false   # ← Clave: NO destruir la instancia EC2
  }
}

# terraform apply → Recurso sale del State
# La instancia EC2 sigue corriendo en AWS ✓
```

**Ventajas sobre `state rm`:**

| Aspecto | `state rm` | `removed {}` |
|---------|-----------|-------------|
| Declarativo | ❌ Comando de terminal | ✅ Vive en código HCL |
| Auditable | ❌ Sin registro | ✅ Trazable vía Git |
| Code Review | ❌ No | ✅ Aprobación del equipo |
| Disponibilidad | Siempre | Terraform v1.7+ |

---

## 5.7 El Método Clásico: `terraform import`

Cuando tienes infraestructura creada manualmente en la nube que quieres pasar a control de Terraform, `terraform import` es la herramienta tradicional. Requiere trabajo en dos pasos:

```hcl
# Paso 1: Escribir bloque resource vacío en el código
resource "aws_instance" "legacy" {
  # vacío por ahora — Terraform completará los atributos
}
```

```bash
# Paso 2: Ejecutar import con el ID real de AWS
$ terraform import \
    aws_instance.legacy \
    i-0abc123def456
```

```hcl
# Paso 3: Corregir errores
# Completar manualmente todos los atributos requeridos
# que Terraform detecta como faltantes en el plan
```

> ⚠️ **Proceso manual y propenso a errores.** Terraform importa el recurso al State pero no genera el código HCL — ese trabajo es manual. El bloque `import {}` moderno resuelve exactamente esto.

---

## 5.8 Importación Moderna: `import` Blocks (v1.5+)

El bloque `import` reemplaza el CLI imperativo con una importación auditable, repetible y versionada. Usa los argumentos `to` (dirección en código) e `id` (identificador en la nube):

```hcl
import {
  to = aws_instance.legacy
  id = "i-0abc123def456"
}

# terraform plan → importa sin borrar nada
# terraform apply → consolida bajo control de Terraform
```

**Beneficios clave:**

| Aspecto | `terraform import` | `import {}` |
|---------|------------------|-------------|
| Declarativo | ❌ | ✅ |
| En Git | ❌ | ✅ |
| Repetible | ❌ Idempotente | ✅ |
| Genera HCL | ❌ | ✅ Con `-generate-config-out` |

---

## 5.9 Generación Automática de Código: `-generate-config-out`

La combinación de `import {}` con `-generate-config-out` es el flujo más potente para adoptar infraestructura existente — Terraform **escribe el HCL por ti**:

```hcl
# 1. Define el bloque import
import {
  to = aws_s3_bucket.datos
  id = "mi-bucket-produccion"
}
```

```bash
# 2. Terraform genera el HCL automáticamente
$ terraform plan \
    -generate-config-out=generated.tf

# → Archivo generated.tf creado con toda la configuración
#   del recurso importado, sin escribir una línea de HCL manual
```

```bash
# Flujo completo:
# 1. Escribir bloque import (to + id)
# 2. terraform plan -generate-config-out=file.tf
# 3. Revisar file.tf y ajustar valores si es necesario
# 4. terraform apply → recurso adoptado ✓
```

---

## 5.10 Importación en Masa: `for_each` en `import` (v1.7+)

¿Tienes 50 buckets creados manualmente? Con `for_each` dentro de bloques `import` puedes importarlos todos con un solo bloque dinámico, eliminando decenas de bloques individuales:

```hcl
# Sin for_each ✗ — 50 bloques manuales:
import { to = aws_s3_bucket.migrados["bucket1"], id = "bucket1" }
import { to = aws_s3_bucket.migrados["bucket2"], id = "bucket2" }
# ... y 48 más

# Con for_each ✓ — 1 bloque = N importaciones:
variable "recursos_manuales" {
  type = map(string)
  default = {
    logs   = "bucket-logs-prod"
    data   = "bucket-data-prod"
    backup = "bucket-bk-prod"
  }
}

import {
  for_each = var.recursos_manuales
  to       = aws_s3_bucket.migrados[each.key]
  id       = each.value
}

# terraform plan → importa los 3 buckets en una sola ejecución
# Escala a N recursos solo añadiendo entradas al mapa ✓
```

---

## 5.11 Mantenimiento: `state replace-provider`

Cuando migras de un registry privado, un fork comunitario o actualizas el namespace de un proveedor, este comando actualiza el `source` en el State sin destruir ni recrear recursos:

```bash
$ terraform state replace-provider \
    registry.acme.com/acme/aws \
    registry.terraform.io/hashicorp/aws

# Reemplaza ORIGEN → DESTINO
Successfully replaced provider for 12 resource(s).
```

**Escenarios de uso:**
- Registry privado → público: migrar de mirror interno al oficial
- Fork → proveedor oficial: volver al upstream original
- Cambio de namespace: HashiCorp renombra la organización

---

## 5.12 Operaciones Raw: `state pull` y `state push`

Operaciones de bajo nivel para descargar y subir el State como JSON crudo. Solo para emergencias y migraciones de backends críticos:

```bash
# state pull — descarga el State completo a stdout
$ terraform state pull > backup.tfstate
# Útil para backups manuales o inspecciones del JSON crudo
# Riesgo: Bajo ✓

# state push — sube un archivo JSON como el nuevo State al backend
$ terraform state push backup.tfstate
# Sobrescribe el State actual completamente
# ⚠ Riesgo: EXTREMO — Solo para emergencias
```

> **Caso de uso legítimo:** Migrar entre dos backends (por ejemplo, de S3 a HCP Terraform) cuando `terraform init -migrate-state` no funciona. `pull` del origen + `push` al destino. Siempre con backup previo.

---

## 5.13 Caso Real: De Nube Manual a Terraform Pro

Workflow profesional para absorber infraestructura heredada en tres pasos:

```
1. DECLARAR
   Crear bloques import con for_each apuntando
   a todos los recursos manuales existentes en la nube
   import { for_each = var.recursos }

2. GENERAR
   Ejecutar terraform plan con -generate-config-out
   para que Terraform escriba el HCL automáticamente
   $ terraform plan -generate-config-out=generated.tf

3. CONSOLIDAR
   Revisar el código generado, ajustar y ejecutar
   terraform apply para consolidar toda la infraestructura
   $ terraform apply
```

Este flujo convierte semanas de trabajo manual de documentación en horas de revisión del código generado.

---

## 5.14 Resumen: Imperativo vs. Declarativo

Un experto en Terraform prefiere siempre el código sobre la terminal. La evolución del tooling refleja esta filosofía: auditoría, trazabilidad y automatización total:

| Operación | Imperativo (CLI) | Declarativo (HCL) | Versión |
|-----------|-----------------|-------------------|---------|
| Renombrar | `state mv` | `moved {}` | v1.5+ |
| Desconectar | `state rm` | `removed {}` | v1.7+ |
| Importar | `terraform import` | `import {}` | v1.5+ |
| Importar masivo | — | `import { for_each }` | v1.7+ |

**Best Practices:**
- Código > Terminal — siempre preferir lo declarativo
- Auditoría total — todo cambio pasa por Git
- Automatización — `for_each` + `generate-config-out` para migraciones masivas

---

> **Siguiente:** [Sección 6 — Workspaces y Stacks →](./06_workspaces.md)
