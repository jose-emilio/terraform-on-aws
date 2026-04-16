# Sección 1 — Fundamentos del State

> [← Volver al índice](./README.md) | [Siguiente →](./02_backend_s3.md)

---

## 1.1 ¿Qué es el State y por qué es necesario?

Terraform necesita saber qué existe en la nube para poder gestionarlo. Sin una memoria persistente, cada `terraform plan` sería ciego: no sabría si el recurso ya fue creado, si sus atributos coinciden con el código, ni en qué orden destruir lo que ya existe.

El **State** es esa memoria. Es un archivo que mapea cada bloque `resource` de tu código `.tf` con el ID real que devolvió la API de la nube cuando se creó. Sin él, Terraform se convierte en una herramienta completamente ciega.

El State cumple tres funciones críticas:

| Función | Descripción |
|---------|-------------|
| **Mapeo de Recursos** | Vincula cada bloque `resource` del código con el ID real de la nube. Este enlace permite a Terraform saber exactamente qué actualizar o destruir |
| **Metadatos** | Almacena el proveedor, el tipo de recurso, sus atributos actuales y las relaciones entre ellos para cada operación |
| **Dependencias** | Resuelve el orden de creación y destrucción. Sabe que una subnet necesita primero una VPC — evita errores de dependencia |

---

## 1.2 Anatomía del archivo `terraform.tfstate`

El State es un archivo JSON plano almacenado por defecto en el directorio del proyecto con el nombre `terraform.tfstate`. Aunque es legible, su estructura interna agrupa recursos por tipo, nombre y proveedor, y contiene el **ID único que la API de la nube devolvió** al crear cada recurso:

```json
{
  "version": 4,
  "serial": 42,
  "lineage": "a1b2c3d4-e5f6-...",
  "resources": [{
    "type": "aws_instance",
    "name": "web_server",
    "provider": "provider[\"registry.../aws\"]",
    "instances": [{
      "attributes": {
        "id": "i-0abc123def456",
        "ami": "ami-0abcdef1234",
        "instance_type": "t3.micro"
      }
    }]
  }]
}
```

El campo `"id": "i-0abc123def456"` es el vínculo vital. Sin él, Terraform no sabe qué instancia EC2 actualizar en el próximo `apply`.

---

## 1.3 Metadata Crítica: `lineage`, `serial` y `version`

Además de los recursos, el archivo `.tfstate` contiene campos de control internos que garantizan la coherencia entre ejecuciones y entre miembros del equipo:

| Campo | Descripción |
|-------|-------------|
| `version` | Define el formato del esquema del State (actualmente v4). Terraform lo usa para saber cómo interpretar la estructura del archivo y garantizar compatibilidad entre versiones del CLI |
| `lineage` | Identificador UUID único generado al crear el State. Se mantiene durante toda la vida del proyecto para **evitar mezclar accidentalmente estados de proyectos distintos** |
| `serial` | Contador que se incrementa con cada `terraform apply` exitoso. Actúa como mecanismo de protección: si el serial no coincide, Terraform rechaza la operación para evitar sobrescribir cambios |

Estos tres campos son la firma de identidad de tu State. Si el `lineage` no coincide, Terraform sabe que estás intentando usar el State de un proyecto distinto.

---

## 1.4 Cómo Terraform Calcula el Diff: El Flujo de 4 Pasos

Cuando ejecutas `terraform plan`, Terraform sigue un flujo preciso para determinar qué cambiar. El State es la pieza central que permite comparar lo declarado con lo que realmente existe:

```
1. Leer configuración (.tf)         → "¿qué quiero tener?"
2. Leer State actual (.tfstate)     → "¿qué cree Terraform que hay?"
3. Comparar con la nube real        → "¿qué hay realmente en AWS?"
4. Generar el Plan de cambios       → diff preciso: create / update / destroy
```

**Ejemplo: Update de un tag**

```hcl
# Código .tf (nuevo)
tags = { Name = "prod-v2" }

# State (anterior)
tags = { Name = "prod-v1" }

# Plan resultante
~ aws_instance.web (update)
  tags.Name: "prod-v1" → "prod-v2"
```

Terraform detecta que el valor en el código difiere del valor guardado en el State y propone una actualización — sin necesidad de consultar manualmente a AWS.

---

## 1.5 State Local vs. State Remoto

Terraform ofrece dos modelos de almacenamiento. Elegir entre local y remoto es una de las primeras decisiones arquitectónicas de cualquier proyecto profesional:

| Característica | State Local | State Remoto (S3, HCP Terraform...) |
|---------------|-------------|-------------------------------|
| Almacenamiento | `terraform.tfstate` en disco local | Bucket S3, HCP Terraform, etc. |
| Locking | ❌ Sin bloqueo | ✅ Bloqueo por DynamoDB o nativo |
| Backup automático | ❌ No | ✅ Versionado S3 |
| Colaboración en equipo | ❌ Peligroso (colisiones) | ✅ Segura y centralizada |
| Cifrado en reposo | ❌ No | ✅ SSE-S3 / KMS |
| Uso recomendado | Aprendizaje y pruebas individuales | **Todo proyecto profesional** |

> **Regla:** El State local es aceptable para aprender. En cualquier contexto de equipo o producción, un backend remoto es obligatorio.

---

## 1.6 El Peligro de la Manipulación Manual

> ⚠️ **ADVERTENCIA: Nunca edites el `.tfstate` con un editor de texto.**

Un error de sintaxis o una referencia mal borrada puede corromper la infraestructura. Terraform perdería el control de los recursos, generando **recursos huérfanos** imposibles de gestionar sin intervención manual.

| Acción manual | Consecuencia |
|---------------|-------------|
| JSON inválido | Terraform no puede leer el State |
| IDs borrados | Recursos "huérfanos" en la nube que nadie controla |
| Serial alterado | Conflictos de concurrencia |
| Lineage cambiado | Terraform rechaza el State completo |

**Regla de Oro** — Usa siempre los comandos oficiales:

```bash
terraform state list    # Listar recursos gestionados
terraform state show    # Ver atributos de un recurso
terraform state mv      # Renombrar un recurso
terraform state rm      # Desconectar (sin destruir)
```

---

## 1.7 State y Datos Sensibles: La Cruda Realidad

Este es el punto que más sorprende a los equipos que comienzan con Terraform: aunque marques una variable como `sensitive = true`, su **valor real** aparecerá sin cifrar dentro del JSON del State.

```hcl
# En tu código (.tf) — parece seguro
variable "db_password" {
  type      = string
  sensitive = true    # ← Solo oculta en la consola del CLI
}

# En el State (.tfstate) — EXPUESTO en texto plano
"attributes": {
  "password": "SuperSecr3t!Pass"  # ← Visible para quien lea el archivo
}
```

El flag `sensitive` solo evita que el valor aparezca en la salida de `terraform plan` o `apply`. El State siempre almacena los valores reales.

**Implicación directa:** El archivo `terraform.tfstate` **nunca debe estar en un repositorio Git público**, y en backends remotos debe tener cifrado en reposo habilitado.

---

## 1.8 Recuperación: `terraform import` como Herramienta de Rescate

Cuando el archivo de State se pierde o corrompe, `terraform import` permite re-vincular recursos existentes en la nube con un nuevo archivo de State, **sin destruir ni recrear la infraestructura real**:

```bash
# 1. State perdido o corrupto (accidentalmente borrado)
$ rm terraform.tfstate

# 2. Inicializar un nuevo State vacío
$ terraform init

# 3. Re-vincular cada recurso con su ID real en la nube
$ terraform import \
    aws_instance.web i-0abc123

# 4. Verificar que el State es consistente
$ terraform plan   # Debe mostrar: No changes.
```

`terraform import` reconstruye la "memoria" de Terraform sin tocar la infraestructura real. Cada recurso se importa individualmente usando su ID real de la nube (el `i-0abc123` en este caso).

---

## 1.9 Resumen: El State como Activo Crítico

> *"Si cuidas tu State, tu infraestructura será predecible; si lo descuidas, será un caos."*

El State no es un archivo temporal ni un artefacto secundario. Es el **activo más valioso** de tu código de infraestructura y merece el mismo nivel de protección que tus credenciales.

| Prioridad | Acción |
|-----------|--------|
| **Protege** | Cifra en reposo, restringe accesos con IAM. Nunca incluyas en control de versiones público |
| **Migra a Remoto** | Backend S3 con locking nativo (Terraform ≥ 1.10) o S3 + DynamoDB en versiones anteriores. HCP Terraform como alternativa SaaS gestionada |
| **Domina los Comandos** | Usa `state list`, `show`, `mv` y `rm` para operar. Usa `import` para rescatar. Nunca edites el JSON a mano |

---

> **Siguiente:** [Sección 2 — Backend Remoto en AWS (S3) →](./02_backend_s3.md)
