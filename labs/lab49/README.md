# Laboratorio 49 — Compliance as Code y Remediación Automática

[← Módulo 11 — Observabilidad, Tagging y FinOps](../../modulos/modulo-11/README.md)


## Visión general

En este laboratorio construirás un sistema de **postura de seguridad continua** sobre AWS
combinando controles preventivos en el pipeline y controles detectivos con autocorrección
en el runtime. El resultado es una arquitectura de seguridad en tres capas que cubre todo
el ciclo de vida de un recurso: antes de existir, en el momento de crearse y mientras vive.

La arquitectura tiene cuatro pilares:

1. **Vigilancia de configuración (detectivo)**: una regla gestionada de AWS Config
   (`encrypted-volumes`) evalúa continuamente todos los volúmenes EBS de la cuenta y
   marca como no-conformes aquellos que no están cifrados. La evaluación ocurre cada vez
   que un volumen cambia de estado y en una ventana periódica.

2. **Autocorrección en runtime (correctivo)**: una segunda regla Config
   (`S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED`) detecta buckets S3 con acceso público
   habilitado y dispara automáticamente una `aws_config_remediation_configuration` que
   ejecuta el documento SSM `AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock`,
   restaurando el bloqueo de acceso público sin intervención humana.

3. **Guardrail en el pipeline (preventivo)**: una política escrita en **Rego** para
   **Open Policy Agent (OPA)** evalúa el JSON del plan de Terraform antes del `apply`.
   Si el plan intenta crear un `aws_lb_listener` con `protocol = "HTTP"`, la política
   devuelve un error y bloquea el despliegue. La herramienta `conftest` es el puente
   entre `terraform show -json` y el motor OPA.

4. **Postura unificada (visibilidad)**: AWS Security Hub agrega en un único panel todos
   los hallazgos generados por las reglas de Config, más los controles del estándar
   **AWS Foundational Security Best Practices (FSBP)**, que audita decenas de recursos
   automáticamente con puntuación de cumplimiento normalizada.

## Objetivos

- Entender la diferencia entre controles preventivos, detectivos y correctivos en AWS
- Habilitar el AWS Config Recorder con canal de entrega a S3
- Desplegar una regla gestionada de Config para detectar volúmenes EBS sin cifrar
- Desplegar una regla de Config con remediación automática vinculada a SSM Automation
- Comprender el rol IAM necesario para que SSM Automation ejecute la remediación
- Escribir una política Rego en OPA para denegar listeners HTTP en Load Balancers
- Usar `conftest` para evaluar un plan de Terraform contra políticas OPA desde el CLI
- Habilitar AWS Security Hub y suscribirse al estándar FSBP
- Correlacionar los hallazgos de Config con los controles de Security Hub
- Verificar el ciclo completo: recurso no-conforme → detección → remediación → conforme

## Requisitos previos

- Laboratorio 02 completado (bucket S3 para el backend de Terraform)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.9 instalado
- `conftest` >= 0.46 instalado (instrucciones en el Paso 4)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION="us-east-1"
```

## Dependencias entre pasos

| Paso | Requiere | Variables que genera |
|------|----------|----------------------|
| Paso 1 — Desplegar infraestructura | `ACCOUNT_ID`, `REGION` | `RECORDER_NAME`, `CONFIG_BUCKET`, `RULE_EBS`, `RULE_S3`, `REMEDIATION_ROLE_ARN`, `SECURITYHUB_ARN` |
| Paso 2 — Verificar Config Recorder | Paso 1 | — |
| Paso 3 — Verificar regla EBS | Paso 1 | `INSTANCE_ID`, `VOLUME_ID` |
| Paso 4 — Verificar remediación S3 | Paso 1 | `BUCKET_TEST` |
| Paso 5 — OPA / conftest | `conftest` instalado (independiente de Paso 1) | — |
| Paso 6 — Security Hub | Paso 1, recorder activo ≥ 10 min | `FSBP_SUBSCRIPTION_ARN` |
| Reto 1 | Paso 1 | — |
| Reto 2 | Paso 5 completado | — |
| Reto 3 | Paso 1 | — |
| Reto 4 | Paso 1, `terraform init` tras añadir provider `archive` | — |

## Arquitectura

```
  ╔═══════════════════════════════════════════════════════════════════════════════╗
  ║  CAPA 1 — PREVENTIVA (pipeline, pre-deploy)                                   ║
  ║                                                                               ║
  ║  terraform plan ──► terraform show -json ──► conftest test                    ║
  ║                                                  │                            ║
  ║                                    ┌─────────────┴──────────────┐             ║
  ║                                    │  Política OPA / Rego       │             ║
  ║                                    │  alb_https_only.rego       │             ║
  ║                                    │                            │             ║
  ║                                    │  aws_lb_listener.protocol  │             ║
  ║                                    │    == "HTTP"  → DENY ✗     │             ║
  ║                                    │    == "HTTPS" → PASS ✓     │             ║
  ║                                    └────────────────────────────┘             ║
  ╚═══════════════════════════════════════════════════════════════════════════════╝

  ╔═══════════════════════════════════════════════════════════════════════════════╗
  ║  CAPA 2 — DETECTIVA + CORRECTIVA (runtime, post-deploy)                       ║
  ║                                                                               ║
  ║  Recurso creado                                                               ║
  ║       │                                                                       ║
  ║       ▼                                                                       ║
  ║  AWS Config Recorder ──► Snapshot en S3 (lab49-config-delivery-*)             ║
  ║       │                                                                       ║
  ║       ├──► Regla: ENCRYPTED_VOLUMES                                           ║
  ║       │         │                                                             ║
  ║       │    EBS sin cifrar → NON_COMPLIANT ──► Sin remediación automática      ║
  ║       │    EBS cifrado    → COMPLIANT                     (alerta manual)     ║
  ║       │                                                                       ║
  ║       └──► Regla: S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED                    ║
  ║                 │                                                             ║
  ║            S3 público  → NON_COMPLIANT                                        ║
  ║                 │                                                             ║
  ║                 ▼                                                             ║
  ║            Remediación automática                                             ║
  ║                 │                                                             ║
  ║                 ▼                                                             ║
  ║            SSM Automation                                                     ║
  ║            AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock            ║
  ║                 │                                                             ║
  ║                 ▼                                                             ║
  ║            s3:PutBucketPublicAccessBlock (bloquear acceso público)            ║
  ║                 │                                                             ║
  ║                 ▼                                                             ║
  ║            Config re-evalúa → COMPLIANT ✓                                     ║
  ╚═══════════════════════════════════════════════════════════════════════════════╝

  ╔═══════════════════════════════════════════════════════════════════════════════╗
  ║  CAPA 3 — POSTURA UNIFICADA (visibilidad continua)                            ║
  ║                                                                               ║
  ║  AWS Security Hub                                                             ║
  ║  ┌─────────────────────────────────────────────────────────────────────────┐  ║
  ║  │  Estándar: AWS Foundational Security Best Practices (FSBP) v1.0.0       │  ║
  ║  │                                                                         │  ║
  ║  │  Fuentes de hallazgos:                                                  │  ║
  ║  │  ├── AWS Config (reglas EBS y S3 de este lab)                           │  ║
  ║  │  ├── FSBP controles automáticos (EC2, IAM, S3, CloudTrail, RDS...)      │  ║
  ║  │  └── Inspector, GuardDuty (si están habilitados en la cuenta)           │  ║
  ║  │                                                                         │  ║
  ║  │  Puntuación de seguridad: 0-100%  ·  Severidades: CRITICAL/HIGH/MEDIUM  │  ║
  ║  └─────────────────────────────────────────────────────────────────────────┘  ║
  ╚═══════════════════════════════════════════════════════════════════════════════╝
```

## Conceptos clave

### Controles preventivos, detectivos y correctivos

En un modelo de seguridad maduro los controles se organizan en tres capas que se
complementan. Ninguna capa es suficiente por sí sola:

| Capa | ¿Cuándo actúa? | Herramienta | Ejemplo |
|------|----------------|-------------|---------|
| **Preventivo** | Antes del despliegue (pipeline CI/CD) | OPA + conftest | Bloquea un plan que crea un ALB con HTTP |
| **Detectivo** | Después del despliegue (runtime) | AWS Config Rules | Detecta un EBS sin cifrar que ya existe |
| **Correctivo** | Inmediatamente tras la detección | SSM Automation | Reactiva el Block Public Access en S3 |
| **Visibilidad** | Continuo, agregado | AWS Security Hub | Puntúa la postura global y prioriza hallazgos |

**¿Por qué los tres tipos?**

Un control preventivo solo protege recursos nuevos — no puede detectar recursos
no-conformes que ya existían antes de instalar la política (deuda técnica de seguridad).
Un control detectivo solo avisa — sin remediación automática el tiempo hasta que un
operador actúa puede ser horas o días. La correctivo sin visibilidad unificada genera
ruido sin contexto. Los tres trabajando en paralelo cubren el ciclo completo.

**El modelo de madurez:**

```
Nivel 0: Sin controles    — cualquier cosa se despliega, nadie lo detecta
Nivel 1: Detectivos       — se sabe que hay incumplimientos, se corrigen manualmente
Nivel 2: + Correctivos    — los incumplimientos se autorreparar en minutos
Nivel 3: + Preventivos    — la mayoría de incumplimientos se bloquean antes de crearse
Nivel 4: + Visibilidad    — la postura se mide, se puntúa y se reporta a stakeholders
```

Este laboratorio lleva una cuenta del nivel 0 al nivel 4 en cuatro pasos.

---

### AWS Config: el servicio de inventario y cumplimiento

AWS Config es el servicio que registra continuamente el estado de los recursos de tu
cuenta. Funciona a través de tres componentes encadenados:

**1. Configuration Recorder**

El recorder es el agente que captura los cambios. Cuando un recurso se crea, modifica
o elimina, Config registra el estado anterior y el nuevo estado como un "configuration
item" (CI). Sin el recorder activo, ninguna regla puede evaluar nada.

```hcl
resource "aws_config_configuration_recorder" "main" {
  name     = "lab49-recorder"
  role_arn = aws_iam_role.config.arn          # IAM role con permisos para describir recursos

  recording_group {
    all_supported                 = true       # graba todos los tipos de recurso soportados
    include_global_resource_types = true       # incluye recursos globales como IAM
  }
}
```

El recorder necesita un IAM role con la política gestionada
`arn:aws:iam::aws:policy/service-role/AWS_ConfigRole`. Esta política concede permisos
de solo lectura para describir recursos de los servicios soportados y permisos de
escritura para publicar en SNS y escribir en S3.

**2. Delivery Channel**

El delivery channel define dónde entrega Config los snapshots y los historial de
configuración. El destino obligatorio es un bucket S3; el SNS es opcional pero muy útil
para notificaciones en tiempo real.

```hcl
resource "aws_config_delivery_channel" "main" {
  name           = "lab49-delivery"
  s3_bucket_name = aws_s3_bucket.config_delivery.bucket

  # Opcional: enviar notificaciones a SNS cuando Config evalúa reglas
  # sns_topic_arn = aws_sns_topic.config_notifications.arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"   # snapshot completo diario
  }
}
```

**La política del bucket S3 para Config:**

Config usa un principal de servicio (`config.amazonaws.com`) para escribir en el bucket.
La política debe tener dos statements:
- `s3:GetBucketAcl` sobre el bucket (Config verifica que tiene acceso antes de escribir)
- `s3:PutObject` sobre el prefijo `AWSLogs/{account-id}/Config/*`

Sin esta política, el recorder se activa pero los snapshots fallan silenciosamente.

**3. Configuration Recorder Status**

El recorder se crea inicialmente deshabilitado. El recurso
`aws_config_configuration_recorder_status` lo activa. La separación entre "crear" y
"activar" es intencional: permite crear el recorder y el delivery channel antes de
habilitarlos, garantizando que la cadena está completa cuando empieza a grabar.

```hcl
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]  # activar solo cuando el canal existe
}
```

**Tipos de evaluación de reglas:**

| Tipo | Cuándo se evalúa | Caso de uso |
|------|------------------|-------------|
| `CONFIGURATION_CHANGE` | Cuando el recurso cambia | Reglas sobre propiedades del recurso |
| `PERIODIC` | En intervalos regulares (1h, 3h, 6h, 12h, 24h) | Reglas que comprueban relaciones entre recursos |

Las reglas gestionadas `ENCRYPTED_VOLUMES` y `S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED`
usan `CONFIGURATION_CHANGE`, por lo que se evalúan automáticamente cada vez que un
volumen EBS o un bucket S3 cambia en la cuenta.

**Reglas gestionadas vs reglas personalizadas:**

| Tipo | Implementación | Ventaja | Cuándo usarla |
|------|----------------|---------|---------------|
| Gestionada (`AWS`) | Lógica de evaluación mantenida por AWS | Sin código que mantener | Cuando existe una regla que cubre el caso |
| Personalizada (Lambda) | Función Lambda propia | Lógica de negocio arbitraria | Cuando no existe una regla gestionada adecuada |

La regla gestionada se referencia por su `source_identifier` — un identificador
predefinido que AWS mantiene. En este lab usamos `ENCRYPTED_VOLUMES` y
`S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED`. La lista completa está en la
documentación de AWS Config Managed Rules.

---

### SSM Automation Documents y el rol de remediación

Cuando Config detecta un recurso no-conforme y la remediación automática está habilitada,
el flujo es:

```
Config (NON_COMPLIANT)
    │
    ▼
aws_config_remediation_configuration
    │
    ├── target_type = "SSM_DOCUMENT"
    ├── target_id   = "AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock"
    │
    ▼
SSM Automation (asume el rol de remediación)
    │
    ▼
Ejecuta el documento SSM paso a paso:
    ├── Paso 1: Obtener el nombre del bucket no-conforme (de RESOURCE_ID)
    └── Paso 2: Llamar s3:PutBucketPublicAccessBlock (habilitar los 4 bloqueos)
```

**El rol IAM de remediación — el componente más crítico:**

SSM Automation necesita asumir un rol IAM para ejecutar las acciones de remediación.
Este rol debe tener dos características:

1. **Trust policy** que permita a `ssm.amazonaws.com` asumir el rol:
```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ssm.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

2. **Permisos mínimos** para la acción de remediación concreta. Para bloquear acceso
público en S3 se necesita `s3:PutBucketPublicAccessBlock` y `s3:GetBucketPublicAccessBlock`.

**El parámetro `AutomationAssumeRole` es obligatorio** en los documentos de remediación
de Config. Si se omite o apunta a un rol con permisos insuficientes, la ejecución de
SSM Automation fallará con un error de acceso denegado y la remediación nunca ocurrirá
— sin ningún mensaje de error visible en la consola de Config.

**Los parámetros de la remediación:**

```hcl
resource "aws_config_remediation_configuration" "s3_public_access" {
  config_rule_name = aws_config_config_rule.s3_public_access_prohibited.name
  target_type      = "SSM_DOCUMENT"
  target_id        = "AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock"

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.remediation.arn   # valor fijo para todos los recursos
  }

  parameter {
    name           = "BucketName"
    resource_value = "RESOURCE_ID"                 # se sustituye por el ID del recurso no-conforme
  }

  automatic                  = true                # disparar sin intervención humana
  maximum_automatic_attempts = 3                   # reintentos antes de rendirse
  retry_attempt_seconds      = 60                  # espera entre reintentos
}
```

`RESOURCE_ID` es una palabra clave especial que Config sustituye en tiempo de ejecución
por el identificador del recurso no-conforme. Para un bucket S3, el `RESOURCE_ID` es el
nombre del bucket.

**Controles de ejecución:**

```hcl
execution_controls {
  ssm_controls {
    concurrent_execution_rate_percentage = 25  # máx 25% de recursos en paralelo
    error_percentage                     = 20  # detener si >20% fallan
  }
}
```

En cuentas con cientos de recursos no-conformes, sin estos controles la remediación
podría saturar las cuotas de la API o hacer cambios masivos sin visibilidad.

---

### OPA y Rego: política como código en el pipeline

**¿Qué es Open Policy Agent (OPA)?**

OPA es un motor de políticas de propósito general, de código abierto, que evalúa datos
estructurados (JSON/YAML) contra reglas escritas en el lenguaje **Rego**. No es
específico de AWS ni de Terraform — se usa también para Kubernetes, APIs REST, bases de
datos y cualquier sistema que pueda exponer su estado como JSON.

En el contexto de Terraform, OPA actúa como una capa de validación que se ejecuta
**después del `terraform plan` pero antes del `terraform apply`**, evaluando el JSON
del plan para detectar configuraciones prohibidas.

**La cadena de herramientas: conftest**

`conftest` es una herramienta CLI que simplifica el uso de OPA para validar archivos de
configuración. Actúa como el pegamento entre Terraform y OPA:

```
terraform plan -out=plan.tfplan
        │
        ▼
terraform show -json plan.tfplan > plan.json
        │
        ▼
conftest test plan.json --policy policies/ --all-namespaces
        │                        (--all-namespaces: evalúa todos los paquetes Rego,
        │                         no solo "main")
        ├── PASS: 0 violations → pipeline continúa → terraform apply
        └── FAIL: 1+ violations → pipeline se detiene → NO apply
```

**Anatomía de una política Rego (sintaxis OPA >= 1.0):**

```rego
package terraform.aws.alb           # namespace del paquete (obligatorio)

import rego.v1                      # activa el parser v1 en cualquier build de conftest

# "deny contains msg if" es la sintaxis moderna de set comprehension.
# Si deny tiene al menos un elemento, conftest reporta fallo.
deny contains msg if {
  # Itera sobre todos los cambios de recursos del plan
  resource := input.resource_changes[_]

  # Filtra solo listeners de ALB
  resource.type == "aws_lb_listener"

  # Solo para acciones de creación o actualización (no destrucción)
  # "some action in" es el patrón v1 para iterar y verificar membresía
  some action in resource.change.actions
  action in {"create", "update"}

  # La condición de fallo: el protocolo es HTTP
  resource.change.after.protocol == "HTTP"

  # El mensaje de error que verá el operador en la salida de conftest
  msg := sprintf(
    "VIOLACIÓN [ALB-001] — '%s': uso de HTTP prohibido. Migra a HTTPS (puerto 443) con un certificado ACM.",
    [resource.address]
  )
}
```

**Cómo leer el JSON de un plan de Terraform:**

El JSON generado por `terraform show -json` tiene esta estructura relevante:

```json
{
  "resource_changes": [
    {
      "address": "aws_lb_listener.http_insecure",
      "type": "aws_lb_listener",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {
          "port": 80,
          "protocol": "HTTP",
          "load_balancer_arn": "..."
        }
      }
    }
  ]
}
```

La expresión `input.resource_changes[_]` en Rego itera sobre todos los elementos del
array `resource_changes`. El `_` es un índice anónimo — Rego prueba la regla con
cada elemento del array y acumula todos los mensajes de error que resulten verdaderos.

**Tests unitarios de políticas Rego:**

OPA tiene un framework de tests propio. Los tests se escriben en archivos `_test.rego`
y se ejecutan con `conftest verify` o `opa test`:

```rego
package terraform.aws.alb_test

import data.terraform.aws.alb

test_http_listener_debe_ser_rechazado if {
  count(alb.deny) == 1 with input as { ... }   # exactly 1 violation
}

test_https_listener_debe_pasar if {
  count(alb.deny) == 0 with input as { ... }   # no violations
}
```

---

### AWS Security Hub: postura de seguridad unificada

Security Hub es el servicio de CSPM (Cloud Security Posture Management) de AWS. Agrega
hallazgos de múltiples fuentes y los normaliza en un formato común llamado
**ASFF (Amazon Security Finding Format)**.

**Fuentes de hallazgos que Security Hub puede agregar:**

| Fuente | Tipo de hallazgos |
|--------|-------------------|
| AWS Config (FSBP) | Incumplimientos de controles de FSBP evaluados por Config |
| Amazon Inspector | Vulnerabilidades de software en EC2 y ECR |
| Amazon GuardDuty | Amenazas de comportamiento (accesos sospechosos, malware) |
| AWS IAM Access Analyzer | Recursos con políticas de acceso externo |
| Macie | Datos sensibles expuestos en S3 |
| Integraciones de terceros | CrowdStrike, Palo Alto, etc. |

**El estándar FSBP (AWS Foundational Security Best Practices):**

FSBP es un conjunto de controles de seguridad definidos por AWS basados en las mejores
prácticas documentadas en AWS Well-Architected Framework, CIS y NIST. Cubre más de 300
controles distribuidos en servicios como EC2, S3, RDS, IAM, CloudTrail, Lambda...

Cuando te suscribes al estándar, Security Hub crea automáticamente reglas de Config para
evaluar cada control. Por eso es **imprescindible que AWS Config esté habilitado antes
de activar Security Hub** — si no hay recorder activo, los controles no pueden evaluar
nada y la puntuación queda al 0%.

```hcl
resource "aws_securityhub_account" "main" {}

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}
```

**La puntuación de seguridad:**

Security Hub calcula una puntuación del 0 al 100% para cada estándar:

```
Puntuación = (Controles que pasan / Total de controles aplicables) × 100
```

En una cuenta nueva con recursos mínimos, la puntuación suele ser baja (20-40%) porque
muchos controles detectan ausencia de servicios de seguridad opcionales (CloudTrail,
Config multi-región, GuardDuty habilitado, etc.).

**Severidades según el formato ASFF (AWS Security Finding Format):**

| Severidad | Score CVSS | Descripción |
|-----------|------------|-------------|
| `CRITICAL` | 90-100 | Exposición inmediata — requiere acción en horas |
| `HIGH` | 70-89 | Riesgo elevado — actuar en 24-48h |
| `MEDIUM` | 40-69 | Riesgo moderado — planificar en la próxima semana |
| `LOW` | 1-39 | Riesgo menor — backlog de mejora continua |
| `INFORMATIONAL` | 0 | Contexto sin riesgo directo |

**La relación entre Config y Security Hub:**

Cuando habilitas Security Hub con el estándar FSBP, Security Hub crea sus propias reglas
de Config prefijadas con `securityhub-`. Estas reglas son adicionales a las que tú has
creado manualmente. Los hallazgos que generan estas reglas de FSBP aparecen automáticamente
en el panel de Security Hub. Tus propias reglas de Config (como `lab49-ebs-encrypted-volumes`)
también generan hallazgos que fluyen a Security Hub, pero aparecen bajo la categoría de
hallazgos personalizados.

## Estructura

```
lab49/
├── aws/                             Infraestructura del laboratorio
│   ├── providers.tf                 Provider AWS ~6.0, archive ~2.7, backend S3
│   ├── variables.tf                 Variables: región, entorno, proyecto
│   ├── main.tf                      Data source: aws_caller_identity (ID de cuenta)
│   ├── config.tf                    IAM role Config, S3 bucket, recorder, delivery channel
│   ├── rules.tf                     Config Rules: EBS cifrado + S3 acceso público
│   ├── remediation.tf               IAM role SSM, remediación automática para S3
│   ├── securityhub.tf               Security Hub account + suscripción FSBP
│   ├── outputs.tf                   ARNs, nombres de reglas, bucket de entrega
│   ├── aws.s3.tfbackend             Configuración parcial del backend S3
│   └── lambda/                      Código fuente de la Lambda del Reto 4
│       └── tag_checker.py           Evaluador de tag CostCenter en instancias EC2
└── policies/                        Políticas OPA para el pipeline
    ├── alb_https_only.rego          Política: denegar listeners HTTP en ALB
    ├── alb_https_only_test.rego     Tests unitarios de la política Rego
    └── testdata/                    Planes JSON de referencia para conftest test
        ├── plan_http_denied.json    Listener HTTP → debe producir FAIL
        └── plan_https_allowed.json  Listener HTTPS → debe producir PASS
        (El Reto 2 requiere añadir aquí plan_s3_no_versioning.json y plan_s3_with_versioning.json)
```

## Paso 1 — Desplegar la infraestructura base

```bash
cd labs/lab49/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-${ACCOUNT_ID}" \
  -backend-config="region=${REGION}"

terraform plan
terraform apply
```

El apply crea los siguientes recursos en este orden:

1. **Bucket S3 de entrega** (`lab49-config-delivery-{account-id}`): destino para los
   snapshots y el historial de configuración de Config.
2. **Política del bucket S3**: permite a `config.amazonaws.com` verificar el ACL y
   escribir los objetos de entrega.
3. **IAM role de Config** (`lab49-config-role`): permite al servicio Config describir
   recursos y escribir en el bucket S3.
4. **Configuration Recorder** (`lab49-recorder`): registrado pero todavía inactivo.
5. **Delivery Channel** (`lab49-delivery`): vincula el recorder al bucket S3.
6. **Recorder Status** (`enabled=true`): activa el recorder. A partir de este momento
   Config empieza a grabar cambios.
7. **Config Rule: EBS** (`lab49-ebs-encrypted-volumes`): regla detectiva, sin remediación.
8. **Config Rule: S3** (`lab49-s3-public-access-prohibited`): regla detectiva con remediación.
9. **IAM role de remediación** (`lab49-remediation-role`): para SSM Automation.
10. **Remediación automática S3**: vincula la regla S3 al documento SSM.
11. **Security Hub account**: habilita el servicio en la cuenta.
12. **Suscripción FSBP**: activa el estándar de mejores prácticas.

> **Tiempos de espera tras el apply:**
> - **Inmediato** — Config Recorder activo y Reglas creadas
> - **2-5 min** — Primera evaluación de las reglas sobre recursos existentes
> - **5-10 min** — Primeros hallazgos visibles en Security Hub
> - **15-30 min** — Puntuación FSBP inicial calculada (puede variar según la cuenta)

Guarda los outputs para los pasos siguientes:

```bash
CONFIG_BUCKET=$(terraform output -raw config_bucket_name)
RECORDER_NAME=$(terraform output -raw config_recorder_name)
RULE_EBS=$(terraform output -raw config_rule_ebs_name)
RULE_S3=$(terraform output -raw config_rule_s3_name)
REMEDIATION_ROLE_ARN=$(terraform output -raw remediation_role_arn)
SECURITYHUB_ARN=$(terraform output -raw security_hub_arn)
```

---

## Paso 2 — Verificar el Config Recorder

Comprueba que el recorder está activo y recibiendo configuraciones:

```bash
aws configservice describe-configuration-recorder-status \
  --configuration-recorder-names "$RECORDER_NAME" \
  --query 'ConfigurationRecordersStatus[0].{
    Nombre:name,
    Grabando:recording,
    UltimoEstado:lastStatus,
    UltimoError:lastErrorMessage
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------
|             DescribeConfigurationRecorderStatus             |
+----------+------------------+--------------+----------------+
| Grabando |     Nombre       | UltimoError  | UltimoEstado   |
+----------+------------------+--------------+----------------+
|  True    |  lab49-recorder  |  None        |  SUCCESS       |
+----------+------------------+--------------+----------------+
```

Si `Grabando` es `False`, el recorder no está activo. Verifica que el delivery channel
existe antes de ejecutar `terraform apply` de nuevo.

Verifica que las reglas de Config se han creado correctamente:

```bash
aws configservice describe-config-rules \
  --config-rule-names "$RULE_EBS" "$RULE_S3" \
  --query 'ConfigRules[].{
    Nombre:ConfigRuleName,
    Estado:ConfigRuleState,
    Fuente:Source.SourceIdentifier
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------------------------------------
|                                    DescribeConfigRules                                    |
+--------+--------------------------------------------+-------------------------------------+
| Estado |                  Fuente                    |               Nombre                |
+--------+--------------------------------------------+-------------------------------------+
|  ACTIVE|  ENCRYPTED_VOLUMES                         |  lab49-ebs-encrypted-volumes        |
|  ACTIVE|  S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED  |  lab49-s3-public-access-prohibited  |
+--------+--------------------------------------------+-------------------------------------+
```

Verifica que el bucket de entrega ha recibido los primeros objetos de Config:

```bash
aws s3 ls "s3://${CONFIG_BUCKET}/AWSLogs/${ACCOUNT_ID}/Config/" --recursive \
  | head -10
```

Salida esperada inmediatamente tras el deploy:

```
2026-04-14 12:15:03   0   AWSLogs/{account-id}/Config/ConfigWritabilityCheckFile
```

El `ConfigWritabilityCheckFile` (tamaño 0 bytes) es el primer objeto que escribe Config
para verificar que tiene acceso de escritura al bucket. Es la señal de que el canal de
entrega está correctamente configurado.

Los prefijos `ConfigHistory/` y `ConfigSnapshot/` aparecen más tarde:
- `ConfigHistory/` — tras los primeros cambios de recursos grabados (minutos a horas)
- `ConfigSnapshot/` — en la ventana de entrega periódica definida (`TwentyFour_Hours`)

Si el bucket sigue vacío después de 5 minutos (sin `ConfigWritabilityCheckFile`), la
política del bucket tiene algún error — ver sección Solución de problemas.

---

## Paso 3 — Verificar la regla detectiva: EBS sin cifrar

Esta regla no tiene remediación automática — su objetivo es **detectar y alertar**.
La corrección requiere intervención manual o un proceso separado de reencriptado.

### Estado inicial de la regla

Consulta el cumplimiento actual de la regla de EBS:

```bash
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name "$RULE_EBS" \
  --compliance-types NON_COMPLIANT COMPLIANT \
  --query 'EvaluationResults[].{
    Recurso:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,
    Tipo:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceType,
    Resultado:ComplianceType,
    Hora:ResultRecordedTime
  }' \
  --output table
```

En una cuenta nueva sin volúmenes EBS explícitos, la regla puede no tener resultados
todavía si no hay EBS fuera del volumen raíz de instancias EC2.

### Limitación importante de la regla ENCRYPTED_VOLUMES

> **La regla `ENCRYPTED_VOLUMES` solo evalúa volúmenes en estado `attached`** —
> es decir, volúmenes conectados a una instancia EC2 en ejecución. La descripción
> oficial de AWS es explícita: *"Checks whether the EBS volumes that are **in an
> attached state** are encrypted"*.
>
> Un volumen standalone en estado `available` queda completamente fuera del scope
> de esta regla y nunca aparecerá en los resultados de evaluación, aunque esté sin
> cifrar. Esto es intencionado: AWS asume que un volumen no adjunto no tiene datos
> activos que proteger todavía.

Para probar la regla es necesario lanzar una instancia EC2 con un volumen raíz
explícitamente no cifrado:

```bash
# Obtén la AMI más reciente de Amazon Linux 2023 vía SSM Parameter Store
# (más robusto que describe-images: siempre apunta a la última AMI sin necesidad de filtros)
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' \
  --output text)

echo "AMI: $AMI_ID"

# Lanza una instancia t3.micro con volumen raíz sin cifrar.
# --block-device-mappings sobreescribe la configuración por defecto de la AMI.
# Encrypted=false fuerza explícitamente la ausencia de cifrado.
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --block-device-mappings '[{
    "DeviceName": "/dev/xvda",
    "Ebs": {
      "VolumeSize": 8,
      "VolumeType": "gp3",
      "Encrypted": false,
      "DeleteOnTermination": true
    }
  }]' \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=lab49-test-unencrypted},{Key=CreatedBy,Value=lab49-test}]' \
    'ResourceType=volume,Tags=[{Key=Name,Value=lab49-test-unencrypted-root},{Key=CreatedBy,Value=lab49-test}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instancia lanzada: $INSTANCE_ID"

# Obtén el ID del volumen raíz (estará en estado attached una vez la instancia arranque)
VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text)

echo "Volumen raíz no cifrado: $VOLUME_ID"
```

> **Nota**: la instancia no necesita acceso SSH ni subred especial — se lanzará en
> la VPC por defecto. Tardará ~30 segundos en arrancar y asociar el volumen raíz.

### Verificar que el volumen es detectado como NO_CONFORME

Una vez la instancia esté en estado `running`, el volumen estará `attached` y entrará
en el ámbito de la regla. Fuerza la evaluación manualmente:

```bash
# Espera a que la instancia esté running (el volumen queda attached)
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
echo "Instancia running. Forzando evaluación de Config..."

aws configservice start-config-rules-evaluation \
  --config-rule-names "$RULE_EBS"

echo "Evaluación iniciada. Espera 2 minutos..."
sleep 120

aws configservice get-compliance-details-by-resource \
  --resource-type AWS::EC2::Volume \
  --resource-id "$VOLUME_ID" \
  --query 'EvaluationResults[].{
    Regla:EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName,
    Resultado:ComplianceType
  }' \
  --output table
```

Salida esperada:

```
--------------------------------------------------
|         GetComplianceDetailsByResource         |
+------------------------------+-----------------+
|             Regla            |    Resultado    |
+------------------------------+-----------------+
|  lab49-ebs-encrypted-volumes |  NON_COMPLIANT  |
+------------------------------+-----------------+
```

### Limpiar los recursos de prueba

```bash
# Terminar la instancia (el volumen se elimina automáticamente con DeleteOnTermination=true)
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
echo "Instancia $INSTANCE_ID en proceso de terminación."
echo "El volumen $VOLUME_ID se eliminará automáticamente."
```

---

## Paso 4 — Verificar la remediación automática: S3 con acceso público

Este paso demuestra el ciclo completo de detección + corrección automática. Crearás
un bucket S3, deshabilitarás el Block Public Access para simular un error de
configuración, y observarás cómo Config lo detecta y la remediación lo corrige
automáticamente.

### Crear el bucket de prueba

```bash
BUCKET_TEST="lab49-test-public-$(date +%s)"

aws s3api create-bucket \
  --bucket "$BUCKET_TEST" \
  --region "$REGION"

echo "Bucket creado: $BUCKET_TEST"
```

### Verificar el estado inicial (Block Public Access habilitado)

Por defecto, AWS habilita automáticamente el Block Public Access en todos los buckets
nuevos desde 2023. Verifica que está activo:

```bash
aws s3api get-public-access-block \
  --bucket "$BUCKET_TEST" \
  --query 'PublicAccessBlockConfiguration'
```

Salida esperada:

```json
{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
}
```

Los cuatro valores en `true` significan que el bucket está completamente protegido
contra acceso público. La regla `S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED` lo evaluará
como `COMPLIANT`.

### Simular el error: deshabilitar el Block Public Access

Ahora simularemos el error que cometería un operador que necesita acceso temporal y
desactiva el bloqueo sin restaurarlo:

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET_TEST" \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

echo "Block Public Access deshabilitado. Config detectará esto como NON_COMPLIANT."
```

### Verificar que Config detecta el incumplimiento

Fuerza la evaluación manual para no esperar el trigger automático:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names "$RULE_S3"

echo "Evaluación iniciada. Espera 180 segundos..."
sleep 120

aws configservice get-compliance-details-by-config-rule \
  --config-rule-name "$RULE_S3" \
  --compliance-types NON_COMPLIANT \
  --query 'EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId==`'"$BUCKET_TEST"'`].{
    Recurso:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,
    Resultado:ComplianceType,
    Hora:ResultRecordedTime
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------------------------------
|                          GetComplianceDetailsByConfigRule                           |
+-----------------------------------+--------------------------------+----------------+
|               Hora                |            Recurso             |   Resultado    |
+-----------------------------------+--------------------------------+----------------+
|  2026-04-14T12:51:59.496000+02:00 |  lab49-test-public-XXXXXXXXXX  |  NON_COMPLIANT |
+-----------------------------------+--------------------------------+----------------+
```

Si el bucket aparece como `NON_COMPLIANT`, la remediación automática se habrá
disparado. La remediación puede tardar entre 30 segundos y 3 minutos.

### Observar la ejecución de SSM Automation

Para ver el progreso de la remediación, busca las ejecuciones de SSM Automation:

```bash
aws ssm describe-automation-executions \
  --filters "Key=DocumentNamePrefix,Values=AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock" \
  --query 'AutomationExecutionMetadataList[0:1].{
    ID:AutomationExecutionId,
    Estado:AutomationExecutionStatus,
    Inicio:ExecutionStartTime,
    Fin:ExecutionEndTime
  }' \
  --output table
```

Salida esperada cuando la remediación ha completado:

```
-----------------------------------------------------------------------
|                    ListAutomationExecutions                         |
+--------------------+--------+---------------------------+-----------+
|  ID                | Estado | Inicio                    | Fin       |
+--------------------+--------+---------------------------+-----------+
|  abc123...         | Success| 2026-04-14T10:30:00Z      | 2026-...  |
+--------------------+--------+---------------------------+-----------+
```

### Verificar que el Block Public Access fue restaurado

> **Nota:** La remediación automática no es instantánea. El ciclo completo —
> Config detecta el incumplimiento → dispara la ejecución SSM → SSM aplica el
> bloqueo — puede tardar entre **2 y 10 minutos**. Si el comando siguiente devuelve
> un error `NoSuchPublicAccessBlockConfiguration`, espera unos minutos y vuelve
> a ejecutarlo.

Mientras esperas, puedes seguir el progreso del Automation de SSM que está ejecutando
la remediación:

```bash
# Obtén el ID de la ejecución de Automation más reciente para este bucket
EXECUTION_ID=$(aws ssm describe-automation-executions \
  --filters "Key=DocumentNamePrefix,Values=AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock" \
  --query 'AutomationExecutionMetadataList[0].AutomationExecutionId' \
  --output text)

# Consulta los pasos de la ejecución y su estado
aws ssm get-automation-execution \
  --automation-execution-id "$EXECUTION_ID" \
  --query 'AutomationExecution.StepExecutions[].{
    Paso:StepName,
    Estado:StepStatus,
    Accion:Action
  }' \
  --output table
```

Salida esperada tras la ejecución correcta:

```
-----------------------------------------------------------------------------------
|                             GetAutomationExecution                              |
+--------------------+----------+-------------------------------------------------+
|       Accion       | Estado   |                      Paso                       |
+--------------------+----------+-------------------------------------------------+
|  aws:executeAwsApi |  Success |  PutBucketPublicAccessBlock                     |
|  aws:executeScript |  Success |  GetBucketPublicAccessBlockBeforeStabilization  |
|  aws:sleep         |  Success |  BucketPublicAccessBlockStabilization           |
|  aws:executeScript |  Success |  GetBucketPublicAccessBlock                     |
+--------------------+----------+-------------------------------------------------+
```

El documento ejecuta 4 pasos en secuencia:

| Paso | Tipo | Descripción |
|------|------|-------------|
| `PutBucketPublicAccessBlock` | `aws:executeAwsApi` | Activa los 4 ajustes de bloqueo de acceso público |
| `GetBucketPublicAccessBlockBeforeStabilization` | `aws:executeScript` | Lee el estado actual antes de esperar la propagación |
| `BucketPublicAccessBlockStabilization` | `aws:sleep` | Espera a que los cambios se propaguen en AWS |
| `GetBucketPublicAccessBlock` | `aws:executeScript` | Verifica que los 4 ajustes quedaron en `true` |

Una vez que todos los pasos estén en `Success`, verifica el resultado final:

```bash
echo "Verificando estado de Block Public Access tras la remediación..."
aws s3api get-public-access-block \
  --bucket "$BUCKET_TEST" \
  --query 'PublicAccessBlockConfiguration'
```

Salida esperada (los cuatro valores restaurados a `true`):

```json
{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
}
```

La remediación ha restaurado automáticamente la configuración de seguridad sin
intervención humana.

### Re-evaluar la regla para confirmar que está COMPLIANT

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names "$RULE_S3"

sleep 60

aws configservice get-compliance-details-by-config-rule \
  --config-rule-name "$RULE_S3" \
  --compliance-types COMPLIANT \
  --query 'EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId==`'"$BUCKET_TEST"'`].{
    Recurso:EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,
    Resultado:ComplianceType
  }' \
  --output table
```

Salida esperada:

```
-----------------------------------------------
|      GetComplianceDetailsByConfigRule       |
+-------------------------------+-------------+
|            Recurso            |  Resultado  |
+-------------------------------+-------------+
|  lab49-test-public-XXXXXXXXXX |  COMPLIANT  |
+-------------------------------+-------------+
```

El bucket está de nuevo como `COMPLIANT`. El ciclo completo de detección y
autocorrección ha funcionado.

### Limpiar el bucket de prueba

```bash
aws s3 rb "s3://${BUCKET_TEST}" --force
echo "Bucket $BUCKET_TEST eliminado."
```

> **Nota sobre el estado FAILED en SSM Automation:** Si consultas el historial de ejecuciones
> de SSM después de eliminar el bucket, verás que la ejecución de
> `AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock` aparece como `FAILED` con el error
> `NoSuchBucket`. Esto **no significa que la remediación no funcionó** — el documento SSM
> ejecuta 4 pasos en secuencia:
>
> 1. **`PutBucketPublicAccessBlock`** — activa los 4 ajustes de bloqueo → **ejecutado correctamente**.
> 2. **`GetBucketPublicAccessBlockBeforeStabilization`** — lee el estado actual antes de esperar.
> 3. **`BucketPublicAccessBlockStabilization`** — espera a que los cambios se propaguen en AWS.
> 4. **`GetBucketPublicAccessBlock`** — verifica que los 4 ajustes quedaron en `true`.
>    Si el bucket ya fue eliminado entre los pasos 1 y 4, la verificación final lanza `NoSuchBucket`
>    y la ejecución se marca como fallida aunque la remediación surtió efecto en el paso 1.
>
> La prueba real del éxito es el estado `COMPLIANT` que Config devuelve en la re-evaluación
> anterior, no el estado final del documento SSM.

---

## Paso 5 — Guardrails en el pipeline con OPA (conftest)

Este paso trabaja en el directorio `policies/` del laboratorio, no en `aws/`. La
política OPA actúa en el pipeline, antes del `terraform apply`, por lo que no crea
ningún recurso en AWS.

### Instalar conftest

`conftest` es una herramienta CLI de código abierto que permite testear archivos de
configuración (YAML, JSON, HCL, Dockerfile...) contra políticas escritas en Rego.

```bash
# Detecta la arquitectura y descarga la versión correcta
ARCH=$(uname -m | sed 's/aarch64/arm64/')
CONFTEST_VERSION="0.68.0"

curl -Lo /tmp/conftest.tar.gz \
  "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_${ARCH}.tar.gz"

tar xzf /tmp/conftest.tar.gz -C /tmp conftest
sudo mv /tmp/conftest /usr/local/bin/conftest
rm /tmp/conftest.tar.gz
```

Verifica la instalación:

```bash
conftest --version
```

Salida esperada (la versión de conftest puede mostrarse como `dev` en algunos builds
del tarball oficial — es normal y no afecta al funcionamiento):

```
Conftest: dev
OPA:      1.15.1
```

### Explorar la política Rego

Examina la política OPA ya incluida en el laboratorio:

```bash
cat labs/lab49/policies/alb_https_only.rego
```

El contenido:

```rego
package terraform.aws.alb

# deny acumula mensajes de error. Si tiene al menos un elemento,
# conftest reporta fallo y devuelve exit code != 0.
deny contains msg if {
  resource := input.resource_changes[_]

  # Solo evalúa cambios en listeners de Load Balancer
  resource.type == "aws_lb_listener"

  # Solo para recursos que se están creando o actualizando
  some action in resource.change.actions
  action in {"create", "update"}

  # Condición de fallo: el protocolo es HTTP (inseguro)
  resource.change.after.protocol == "HTTP"

  # Mensaje descriptivo para el operador
  msg := sprintf(
    "VIOLACIÓN [ALB-001] — '%s': uso de HTTP prohibido. Migra a HTTPS (puerto 443) con certificado ACM.",
    [resource.address]
  )
}
```

**Anatomía de la regla línea a línea:**

---

```rego
package terraform.aws.alb
```

Declara el **namespace** de esta política. Rego organiza las reglas en paquetes (como
módulos). `conftest` necesita la flag `--all-namespaces` para buscar reglas `deny` fuera
del paquete por defecto `main`. El nombre del paquete es libre — aquí se usa
`terraform.aws.alb` por convenio descriptivo.

---

```rego
deny contains msg if {
```

Define una **regla de conjunto incremental** (`set rule`). Rego no tiene `if/else` ni
bucles explícitos — en su lugar, usa reglas que acumulan resultados:

- `deny` es el nombre del conjunto que conftest interpreta como errores.
- `contains msg` indica que, cuando la regla es verdadera, el valor de `msg` se **añade**
  al conjunto `deny`. Puede haber múltiples bloques `deny contains msg if { … }` en el
  mismo archivo (o en archivos distintos del mismo paquete) — todos contribuyen al mismo
  conjunto acumulado.
- `if { … }` delimita el **cuerpo** de la regla: una lista de predicados que deben ser
  todos verdaderos simultáneamente para que la regla se active (**AND implícito**).
- Esta sintaxis es la forma moderna de OPA ≥ 1.0. La forma antigua equivalente era
  `deny[msg] { … }`.

---

```rego
  resource := input.resource_changes[_]
```

`input` es la variable global que contiene el documento JSON que conftest le pasa a OPA
(en este caso, el `terraform show -json` del plan). `resource_changes` es el array de
objetos que describen cada cambio planificado.

El operador `[_]` es un **wildcard de iteración**: Rego evaluará el cuerpo de la regla
para **cada** elemento del array, sustituyendo `_` por el índice 0, 1, 2... En cada
iteración, `resource` toma el valor del elemento correspondiente. Si para algún índice
todos los predicados del cuerpo son verdaderos, `msg` se añade al conjunto `deny`.

---

```rego
  resource.type == "aws_lb_listener"
```

**Filtro de tipo de recurso.** En Rego, una igualdad `==` dentro del cuerpo de una regla
actúa como un **predicado de filtro**, no como una asignación: si la comparación es
falsa, Rego descarta esa iteración y pasa a la siguiente. Solo los recursos cuyo campo
`type` sea exactamente `"aws_lb_listener"` continúan evaluándose.

---

```rego
  some action in resource.change.actions
  action in {"create", "update"}
```

`some action in resource.change.actions` declara la variable local `action` e itera
sobre todos los elementos del array `resource.change.actions` (que puede contener valores
como `"create"`, `"update"`, `"delete"`, `"no-op"`). La línea siguiente,
`action in {"create", "update"}`, comprueba que `action` pertenece al conjunto literal
`{"create", "update"}`. Juntas, estas dos líneas significan: *"existe al menos un action
en la lista que sea create o update"*. Si solo hay `"no-op"` o `"delete"`, el predicado
falla y la regla no se activa — evitando falsos positivos en destrucciones o sin cambios.

---

```rego
  resource.change.after.protocol == "HTTP"
```

Accede al campo `protocol` dentro de `change.after`, que representa el estado del
recurso **después** de aplicar el plan. Si el protocolo es `"HTTP"`, el predicado es
verdadero y la regla continúa. Si fuera `"HTTPS"`, el predicado sería falso y Rego
descartaría esa iteración sin generar ningún mensaje de error.

---

```rego
  msg := sprintf(
    "VIOLACIÓN [ALB-001] — '%s': uso de HTTP prohibido. Migra a HTTPS (puerto 443) con certificado ACM.",
    [resource.address]
  )
```

`sprintf` construye el mensaje de error interpolando `resource.address` (la dirección del
recurso en el plan, p.ej. `aws_lb_listener.http_insecure`) en el patrón de formato. El
`:=` es una **asignación local**: liga la variable `msg` a ese string dentro del cuerpo
de la regla. Una vez asignada, `msg` es inmutable en este ámbito — Rego no permite
reasignar variables (propiedad de *single assignment*). Este `msg` es el valor que se
añade al conjunto `deny` cuando todos los predicados anteriores son verdaderos.

---

**Flujo de evaluación completo para un plan con un listener HTTP:**

```
input.resource_changes = [
  { type: "aws_lb_listener", change: { actions: ["create"], after: { protocol: "HTTP" } }, address: "aws_lb_listener.http_insecure" },
  { type: "aws_security_group", … }
]
```

1. Iteración `[0]` → `resource.type == "aws_lb_listener"` ✓ → `action = "create"` ∈ `{"create","update"}` ✓ → `protocol == "HTTP"` ✓ → `msg` generado → **añadido a `deny`**.
2. Iteración `[1]` → `resource.type == "aws_security_group"` ≠ `"aws_lb_listener"` ✗ → descartada.

`deny` = `{"VIOLACIÓN [ALB-001] — …"}` → conjunto no vacío → conftest reporta fallo.

### Probar la política con el archivo de datos de prueba (listener HTTP — debe FALLAR)

```bash
cd labs/lab49

conftest test policies/testdata/plan_http_denied.json \
  --policy policies/ \
  --all-namespaces \
  --output table
```

> `--all-namespaces` es necesario porque la política usa `package terraform.aws.alb`
> en lugar de `package main`. Sin esta flag, conftest solo busca reglas `deny` en el
> namespace `main` e ignora cualquier otro paquete silenciosamente.

Salida esperada:

```
┌─────────┬─────────────────────────────────────────┬───────────────────┬─────────────────────────────────────────────────────────────┐
│ RESULT  │                  FILE                   │     NAMESPACE     │                           MESSAGE                           │
├─────────┼─────────────────────────────────────────┼───────────────────┼─────────────────────────────────────────────────────────────┤
│ failure │ policies/testdata/plan_http_denied.json │ terraform.aws.alb │ VIOLACIÓN [ALB-001] — 'aws_lb_listener.http_insecure': uso  │
│         │                                         │                   │ de HTTP prohibido. Migra a HTTPS (puerto 443) con un        │
│         │                                         │                   │ certificado ACM.                                            │
└─────────┴─────────────────────────────────────────┴───────────────────┴─────────────────────────────────────────────────────────────┘
```

El exit code es distinto de cero, lo que en un pipeline CI/CD detendría la ejecución:

```bash
echo "Exit code: $?"
# Exit code: 1
```

### Probar la política con listener HTTPS (debe PASAR)

```bash
conftest test policies/testdata/plan_https_allowed.json \
  --policy policies/ \
  --all-namespaces \
  --output table
```

Salida esperada (sin filas de failure — el plan pasa la validación):

```
┌─────────┬───────────────────────────────────────────┬───────────────────┬─────────┐
│ RESULT  │                   FILE                    │     NAMESPACE     │ MESSAGE │
├─────────┼───────────────────────────────────────────┼───────────────────┼─────────┤
│ success │ policies/testdata/plan_https_allowed.json │ terraform.aws.alb │ SUCCESS │
└─────────┴───────────────────────────────────────────┴───────────────────┴─────────┘
```

Exit code 0 — el pipeline continuaría con el `terraform apply`.

### Ejecutar los tests unitarios de la política Rego

Además de probar contra datos de entrada reales, puedes verificar la propia política con
tests unitarios escritos en Rego:

```bash
# conftest verify evalúa todos los paquetes del directorio por defecto
# (no necesita --all-namespaces, a diferencia de conftest test)
conftest verify \
  --policy policies/ \
  --output table
```

Salida esperada (una fila por cada función `test_` del archivo):

```
┌─────────┬───────────────────────────────────┬───────────┬─────────┐
│ RESULT  │               FILE                │ NAMESPACE │ MESSAGE │
├─────────┼───────────────────────────────────┼───────────┼─────────┤
│ success │ policies/alb_https_only_test.rego │           │ SUCCESS │
│ success │ policies/alb_https_only_test.rego │           │ SUCCESS │
│ success │ policies/alb_https_only_test.rego │           │ SUCCESS │
│ success │ policies/alb_https_only_test.rego │           │ SUCCESS │
│ success │ policies/alb_https_only_test.rego │           │ SUCCESS │
└─────────┴───────────────────────────────────┴───────────┴─────────┘
```

5 filas = 5 tests definidos en [alb_https_only_test.rego](../policies/alb_https_only_test.rego).

### Integración en un pipeline CI/CD

En un flujo real de CI/CD (GitHub Actions, GitLab CI, Jenkins), la política se integra
entre el plan y el apply:

```yaml
# Ejemplo: .github/workflows/terraform.yml (fragmento)
jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Instalar conftest
        run: |
          ARCH=$(uname -m | sed 's/aarch64/arm64/')
          curl -Lo /tmp/conftest.tar.gz \
            "https://github.com/open-policy-agent/conftest/releases/latest/download/conftest_Linux_${ARCH}.tar.gz"
          tar xzf /tmp/conftest.tar.gz -C /tmp conftest
          sudo mv /tmp/conftest /usr/local/bin/conftest

      - name: Tests unitarios de políticas OPA
        # conftest verify no acepta --all-namespaces; evalúa todos los paquetes por defecto
        run: conftest verify --policy policies/ --output table

      - name: Terraform plan
        run: terraform plan -out=plan.tfplan

      - name: Exportar plan a JSON
        run: terraform show -json plan.tfplan > plan.json

      - name: Validar política OPA contra el plan
        # --all-namespaces es necesario para evaluar paquetes distintos de "main"
        run: conftest test plan.json --policy policies/ --all-namespaces

      - name: Terraform apply
        # Solo se ejecuta si todos los pasos anteriores tuvieron exit code 0
        if: success()
        run: terraform apply plan.tfplan
```

La clave es que `conftest` devuelve exit code 1 cuando hay violaciones, lo que hace
que la etapa `apply` no se ejecute. Los tests unitarios (`conftest verify`) se ejecutan
antes del plan para detectar errores en las propias políticas Rego antes de evaluar
cualquier infraestructura.

---

## Paso 6 — Explorar AWS Security Hub

### Estado inicial de la postura de seguridad

Captura el ARN de la suscripción al estándar FSBP para usarlo en los comandos siguientes:

```bash
FSBP_SUBSCRIPTION_ARN=$(aws securityhub get-enabled-standards \
  --query 'StandardsSubscriptions[0].StandardsSubscriptionArn' \
  --output text)

echo "Security Hub ARN : $SECURITYHUB_ARN"
echo "FSBP subscription: $FSBP_SUBSCRIPTION_ARN"
```

Consulta el estándar FSBP suscrito y su estado:

```bash
aws securityhub get-enabled-standards \
  --query 'StandardsSubscriptions[].{
    Nombre:StandardsArn,
    Estado:StandardsStatus
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------------------------------------------------
|                                          GetEnabledStandards                                          |
+--------+----------------------------------------------------------------------------------------------+
| Estado |                                           Nombre                                             |
+--------+----------------------------------------------------------------------------------------------+
|  READY |  arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0  |
+--------+----------------------------------------------------------------------------------------------+
```

`READY` indica que el estándar está activo y evaluando controles. Si aparece `INCOMPLETE`
o `DELETING`, espera unos minutos y vuelve a ejecutar el comando.

Obtén el resumen de la puntuación de seguridad por estándar:

```bash
aws securityhub list-security-control-definitions \
  --standards-arn "arn:aws:securityhub:${REGION}::standards/aws-foundational-security-best-practices/v/1.0.0" \
  --query 'SecurityControlDefinitions[].SecurityControlId' \
  --output text \
  | wc -w
```

Salida esperada: `363` (controles del estándar FSBP en `us-east-1`).

Consulta los hallazgos activos agrupados por severidad:

```bash
echo "=== Hallazgos CRITICAL ==="
aws securityhub get-findings \
  --filters '{"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]}' \
  --query 'length(Findings)' \
  --output text

echo "=== Hallazgos HIGH ==="
aws securityhub get-findings \
  --filters '{"SeverityLabel":[{"Value":"HIGH","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]}' \
  --query 'length(Findings)' \
  --output text

echo "=== Hallazgos MEDIUM ==="
aws securityhub get-findings \
  --filters '{"SeverityLabel":[{"Value":"MEDIUM","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]}' \
  --query 'length(Findings)' \
  --output text
```

Salida esperada (los valores varían según los recursos de la cuenta):

```
=== Hallazgos CRITICAL ===
2
=== Hallazgos HIGH ===
8
=== Hallazgos MEDIUM ===
7
```

> Los números reflejan el estado de la cuenta en el momento del despliegue. Una cuenta
> nueva con pocos recursos tendrá hallazgos principalmente por ausencia de servicios de
> seguridad opcionales (CloudTrail multi-región, GuardDuty, etc.) que FSBP recomienda.

### Examinar hallazgos individuales de alta severidad

```bash
aws securityhub get-findings \
  --filters '{"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"},{"Value":"HIGH","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]}' \
  --query 'Findings[0:5].{
    Titulo:Title,
    Severidad:Severity.Label,
    Servicio:ProductFields.ControlId,
    Recurso:Resources[0].Type,
    RecursoID:Resources[0].Id
  }' \
  --output table
```

```
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
|                                                                               GetFindings                                                                                                  |
+------------------------------+--------+-------------------------------------------------------------------+----------------------------------+---------------------+
|           Recurso            |Severidad|                              Titulo                              |           RecursoID              |      Servicio       |
+------------------------------+--------+-------------------------------------------------------------------+----------------------------------+---------------------+
|  AwsEc2SecurityGroup         |  HIGH  |  VPC default security groups should not allow inbound or outbound traffic  |  arn:aws:ec2:eu-west-1:...  |  EC2.2              |
|  AwsEc2SnapshotBlockPublicAccess |  HIGH  |  Block public access settings should be enabled for Amazon EBS snapshots  |  arn:aws:ec2:eu-west-1:...  |  EC2.43            |
|  AwsAccount                  |  HIGH  |  Amazon Inspector EC2 scanning should be enabled                  |  arn:aws:iam::...:root           |  Inspector.1        |
|  AwsAccount                  |  HIGH  |  Amazon Inspector Lambda standard scanning should be enabled      |  arn:aws:iam::...:root           |  Inspector.2        |
|  AwsAccount                  |  HIGH  |  Amazon Inspector Lambda code scanning should be enabled          |  arn:aws:iam::...:root           |  Inspector.3        |
+------------------------------+--------+-------------------------------------------------------------------+----------------------------------+---------------------+
```

> Los hallazgos HIGH típicos en una cuenta nueva son controles sobre servicios de seguridad opcionales
> (Amazon Inspector) y configuraciones de red/snapshot por defecto. Ninguno está relacionado con los
> recursos desplegados en este laboratorio.

### Ver los controles del estándar FSBP y su estado

```bash
aws securityhub list-enabled-products-for-import \
  --query 'ProductSubscriptions' \
  --output table
```

```
--------------------------------------------------------------------------------------------------------------------
|                                           ListEnabledProductsForImport                                           |
+------------------------------------------------------------------------------------------------------------------+
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/amazon/route-53-resolver-dns-firewall-advanced  |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/amazon/route-53-resolver-dns-firewall-aws-list  |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/access-analyzer                             |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/config                                      |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/firewall-manager                            |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/guardduty                                   |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/health                                      |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/inspector                                   |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/macie                                       |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/ssm-patch-manager                           |
|  arn:aws:securityhub:us-east-1:123456789012:product-subscription/aws/securityhub                                 |
+------------------------------------------------------------------------------------------------------------------+
```

> Security Hub integra automáticamente con los servicios de seguridad de AWS habilitados en la cuenta.
> Los productos de Amazon/AWS listados (Config, GuardDuty, Inspector, Macie, etc.) son fuentes de hallazgos
> que Security Hub agrega en su panel unificado.

```bash
# Controles FSBP relacionados con S3
aws securityhub describe-standards-controls \
  --standards-subscription-arn "$FSBP_SUBSCRIPTION_ARN" \
  --query 'Controls[?contains(ControlId, `S3`)].{
    Control:ControlId,
    Titulo:Title,
    Estado:ControlStatus,
    Severidad:SeverityRating
  }' \
  --output table
```

```
------------------------------------------------------------------------------------------------------------------------
|                                               DescribeStandardsControls                                              |
+---------+----------+------------+------------------------------------------------------------------------------------+
| Control | Estado   | Severidad  |                                      Titulo                                        |
+---------+----------+------------+------------------------------------------------------------------------------------+
|  S3.1   |  ENABLED |  MEDIUM    |  S3 general purpose buckets should have block public access settings enabled       |
|  S3.12  |  ENABLED |  MEDIUM    |  ACLs should not be used to manage user access to S3 general purpose buckets       |
|  S3.13  |  ENABLED |  LOW       |  S3 general purpose buckets should have Lifecycle configurations                   |
|  S3.19  |  ENABLED |  CRITICAL  |  S3 access points should have block public access settings enabled                 |
|  S3.2   |  ENABLED |  CRITICAL  |  S3 general purpose buckets should block public read access                        |
|  S3.25  |  ENABLED |  LOW       |  S3 directory buckets should have lifecycle configurations                         |
|  S3.3   |  ENABLED |  CRITICAL  |  S3 general purpose buckets should block public write access                       |
|  S3.5   |  ENABLED |  MEDIUM    |  S3 general purpose buckets should require requests to use SSL                     |
|  S3.6   |  ENABLED |  HIGH      |  S3 general purpose bucket policies should restrict access to other AWS accounts   |
|  S3.8   |  ENABLED |  HIGH      |  S3 general purpose buckets should block public access                             |
|  S3.9   |  ENABLED |  MEDIUM    |  S3 general purpose buckets should have server access logging enabled              |
+---------+----------+------------+------------------------------------------------------------------------------------+
```

> FSBP incluye 11 controles S3, todos en estado `ENABLED`. Destaca que S3.2, S3.3 y S3.19 son
> de severidad **CRITICAL** — el bucket público detectado y remediado en el Paso 4 habría disparado
> exactamente estos controles (S3.8 cubre el bloqueo de acceso público a nivel de bucket).

### Marcar un hallazgo como resuelto (workflow management)

Security Hub gestiona el ciclo de vida de los hallazgos a través del campo `WorkflowStatus`,
que es independiente del estado de cumplimiento (`ComplianceStatus`). Los cuatro estados posibles son:

| WorkflowStatus | Significado |
|---|---|
| `NEW` | Hallazgo recién detectado, sin revisar |
| `NOTIFIED` | Notificado al responsable, pendiente de acción |
| `SUPPRESSED` | Ignorado intencionalmente (falso positivo, riesgo aceptado) |
| `RESOLVED` | Problema corregido; se excluye de los contadores activos |

Para identificar un hallazgo se necesitan **dos campos juntos** — `Id` y `ProductArn` — porque
`batch-update-findings` requiere el par completo como identificador único. El `Id` es el ARN del
hallazgo en sí; el `ProductArn` identifica el servicio que lo generó (p.ej., Security Hub propio,
GuardDuty, Inspector). Sin ambos, la API rechaza la petición.

```bash
# Captura Id y ProductArn del primer hallazgo MEDIUM en una sola llamada.
# --max-items 1 evita que el autopaginador de la CLI aplique el query a cada
# página y concatene múltiples resultados separados por saltos de línea.
# La proyección [Id,ProductArn] devuelve ambos valores en una sola fila de texto.
read -r FINDING_ARN PRODUCT_ARN < <(aws securityhub get-findings \
  --filters '{"SeverityLabel":[{"Value":"MEDIUM","Comparison":"EQUALS"}],"WorkflowStatus":[{"Value":"NEW","Comparison":"EQUALS"}]}' \
  --max-items 1 \
  --query 'Findings[0].[Id,ProductArn]' \
  --output text)

echo "Finding ARN : ${FINDING_ARN}"
echo "Product ARN : ${PRODUCT_ARN}"

# Muestra el detalle del hallazgo antes de resolverlo.
# Reutiliza el FINDING_ARN ya capturado para filtrar por Id exacto — evita
# una segunda llamada sin filtro que podría devolver un hallazgo diferente.
aws securityhub get-findings \
  --filters "{\"Id\":[{\"Value\":\"${FINDING_ARN}\",\"Comparison\":\"EQUALS\"}]}" \
  --query 'Findings[0].{
    Titulo:Title,
    Severidad:Severity.Label,
    Control:ProductFields.ControlId,
    Recurso:Resources[0].Type,
    RecursoID:Resources[0].Id,
    Descripcion:Description
  }' \
  --output table

# Transiciona el hallazgo a RESOLVED:
#   --finding-identifiers  → JSON array con el par (Id, ProductArn) que identifica el hallazgo
#   --workflow             → nuevo estado del ciclo de vida
#   --note                 → auditoría: quién lo resolvió y por qué (queda en el historial del hallazgo)
aws securityhub batch-update-findings \
  --finding-identifiers "[{\"Id\":\"${FINDING_ARN}\",\"ProductArn\":\"${PRODUCT_ARN}\"}]" \
  --workflow '{"Status": "RESOLVED"}' \
  --note '{"Text": "Remediado manualmente en lab49", "UpdatedBy": "lab-student"}'
```

```json
{
    "ProcessedFindings": [
        {
            "Id": "arn:aws:config:us-east-1:123456789012:config-rule/config-rule-pybgke/finding/3bb60c43a5e209e42a62291ae9db4a671aaef4e2",
            "ProductArn": "arn:aws:securityhub:us-east-1::product/aws/config"
        }
    ],
    "UnprocessedFindings": []
}
```

> `ProcessedFindings` con un elemento y `UnprocessedFindings` vacío confirma que el hallazgo
> fue aceptado y su estado de workflow actualizado a `RESOLVED`. El hallazgo ya no aparecerá
> en los contadores de hallazgos `NEW`.

> **Importante:** `batch-update-findings` actualiza el workflow del hallazgo en Security Hub pero
> **no** cambia el estado de cumplimiento en AWS Config. Si el recurso subyacente sigue siendo
> no conforme, Config volverá a generar el hallazgo en la siguiente evaluación y aparecerá como `NEW`
> de nuevo. La solución correcta siempre es remediar el recurso, no solo cerrar el hallazgo.

---

## Verificación final

Ejecuta este bloque completo para verificar que todos los componentes están
correctamente configurados:

```bash
# Config Recorder activo
aws configservice describe-configuration-recorder-status \
  --query 'ConfigurationRecordersStatus[0].{recording:recording,lastStatus:lastStatus}'

# Reglas Config activas y con evaluaciones
aws configservice describe-config-rules \
  --query 'ConfigRules[*].{name:ConfigRuleName,state:ConfigRuleState}' \
  --output table

# Remediación automática configurada para S3
aws configservice describe-remediation-configurations \
  --config-rule-names "lab49-s3-public-access-prohibited" \
  --query 'RemediationConfigurations[0].{automatic:Automatic,targetId:TargetId}'

# Security Hub habilitado
aws securityhub describe-hub \
  --query '{HubArn:HubArn,AutoEnableControls:AutoEnableControls}'
```

---

## Retos

### Reto 1 — Añadir remediación automática para EBS sin cifrar

La regla `lab49-ebs-encrypted-volumes` actualmente solo detecta volúmenes no cifrados
sin hacer nada. En este reto añadirás una remediación que, cuando se detecte un volumen
sin cifrar, crea automáticamente un snapshot del volumen.

**Objetivo**: usar el documento SSM `AWS-CreateSnapshot` para crear automáticamente un
snapshot de cualquier volumen EBS no cifrado detectado por Config.

1. Crea un nuevo IAM role `lab49-remediation-ebs-role` con la trust policy de
   `ssm.amazonaws.com` y los permisos `ec2:CreateSnapshot` y `ec2:DescribeSnapshots`
   sobre `Resource = "*"`. El documento `AWS-CreateSnapshot` usa `ec2:DescribeSnapshots`
   internamente para hacer polling del estado de la operación — sin él la ejecución falla
   en la fase de espera aunque el snapshot se haya creado correctamente.

2. Añade en `remediation.tf` un nuevo recurso `aws_config_remediation_configuration`
   con:
   - `config_rule_name = aws_config_config_rule.ebs_encrypted.name`
   - `target_id = "AWS-CreateSnapshot"`
   - Parámetro `AutomationAssumeRole` → el ARN del nuevo rol
   - Parámetro `VolumeId` → `resource_value = "RESOURCE_ID"`
   - `automatic = true`, `maximum_automatic_attempts = 1`

3. Aplica y verifica la remediación:

```bash
terraform apply

# IMPORTANTE: la regla ENCRYPTED_VOLUMES solo evalúa volúmenes ADJUNTOS a una instancia.
# Un volumen en estado "available" (sin adjuntar) nunca aparecerá como NON_COMPLIANT.
# Por eso lanzamos una instancia t3.micro con un volumen raíz sin cifrar.
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"Encrypted":false}}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instancia creada: $INSTANCE_ID"

# Obtén el ID del volumen raíz adjunto
VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text)

echo "Volumen sin cifrar (adjunto): $VOLUME_ID"

# Fuerza la evaluación inmediata de la regla en lugar de esperar el ciclo periódico
aws configservice start-config-rules-evaluation \
  --config-rule-names "$RULE_EBS"

# Espera a que Config evalúe y SSM Automation ejecute la remediación (~3 min)
sleep 180

# Obtén el ID de la ejecución de Automation más reciente para este documento
EXECUTION_ID=$(aws ssm describe-automation-executions \
  --filters "Key=DocumentNamePrefix,Values=AWS-CreateSnapshot" \
  --query 'AutomationExecutionMetadataList[0].AutomationExecutionId' \
  --output text)

# Consulta los pasos de la ejecución y su estado
aws ssm get-automation-execution \
  --automation-execution-id "$EXECUTION_ID" \
  --query 'AutomationExecution.StepExecutions[].{
    Paso:StepName,
    Estado:StepStatus,
    Accion:Action
  }' \
  --output table
```

> **Es posible que aparezca una ejecución fallida anterior.** En pasos previos del
> laboratorio se lanzó una instancia con un volumen sin cifrar y se eliminó después,
> Config, en su momento, marcó ese volumen como `NON_COMPLIANT` y ha disparado ahora el automatismo
> SSM cuando ya no existía el recurso. El resultado es una ejecución `FAILED` con el error
> `InvalidVolume.NotFound`. En ese caso, `AutomationExecutionMetadataList[0]` apuntará
> a esa ejecución fallida.
>
> Para obtener la ejecución correcta (la del volumen actual), usa el índice `[1]` en su
> lugar, o filtra explícitamente por `ExecutionStatus=Success`:
>
> ```bash
> EXECUTION_ID=$(aws ssm describe-automation-executions \
>   --filters "Key=DocumentNamePrefix,Values=AWS-CreateSnapshot" \
>             "Key=ExecutionStatus,Values=Success" \
>   --query 'AutomationExecutionMetadataList[0].AutomationExecutionId' \
>   --output text)
> ```
> Otra opción, es consultar la Consola de Administración de AWS, **AWS Systems Manager** / **Automation**, seleccionando el ID de la ejecución del automatismo correspondiente.

Salida esperada tras la ejecución correcta:

```
-----------------------------------------------------------------
|                    GetAutomationExecution                     |
+---------------------------------+----------+------------------+
|             Accion              | Estado   |      Paso        |
+---------------------------------+----------+------------------+
|  aws:executeAwsApi              |  Success |  createSnapshot  |
|  aws:waitForAwsResourceProperty |  Success |  verifySnapshot  |
+---------------------------------+----------+------------------+
```

El documento `AWS-CreateSnapshot` ejecuta 2 pasos:

| Paso | Tipo | Descripción |
|------|------|-------------|
| `createSnapshot` | `aws:executeAwsApi` | Llama a `ec2:CreateSnapshot` sobre el `VolumeId` proporcionado por Config |
| `verifySnapshot` | `aws:waitForAwsResourceProperty` | Hace polling de `ec2:DescribeSnapshots` hasta que el estado del snapshot es `completed` |

```bash
# Verifica que la remediación se disparó y su estado
aws configservice describe-remediation-execution-status \
  --config-rule-name "$RULE_EBS" \
  --output json | jq '.RemediationExecutionStatuses[] | {
    Recurso: .ResourceKey.ResourceId,
    Estado:  .State,
    Inicio:  .InvocationTime,
    Pasos:   [.StepDetails[]? | {Paso: .Name, Estado: .State, Error: .ErrorMessage}]
  }'
```

Salida esperada (estado inicial tras lanzar la evaluación):

```json
{
  "Recurso": null,
  "Estado": "QUEUED",
  "Inicio": "2026-04-14T14:29:50.034000+02:00",
  "Pasos": [
    {
      "Paso": "createSnapshot",
      "Estado": "PENDING",
      "Error": null
    },
    {
      "Paso": "verifySnapshot",
      "Estado": "PENDING",
      "Error": null
    }
  ]
}
```

> `Recurso: null` es normal en estado `QUEUED` — `ResourceKey.ResourceId` solo se
> popula cuando la ejecución pasa a `IN_PROGRESS`. Los dos pasos del documento
> `AWS-CreateSnapshot` (`createSnapshot` y `verifySnapshot`) deben terminar en
> `Success` para que la ejecución se marque como `SUCCEEDED`.

```bash
# Verifica que se creó un snapshot del volumen
aws ec2 describe-snapshots \
  --filters "Name=volume-id,Values=$VOLUME_ID" \
  --query 'Snapshots[].{
    ID:SnapshotId,
    Estado:State,
    Descripcion:Description
  }' \
  --output table
```

```
--------------------------------------------------------
|                   DescribeSnapshots                  |
+--------------+------------+--------------------------+
|  Descripcion |  Estado    |           ID             |
+--------------+------------+--------------------------+
|              |  completed |  snap-0f0c3cb2db6515589  |
+--------------+------------+--------------------------+
```

> El snapshot en estado `completed` confirma que `AWS-CreateSnapshot` ejecutó correctamente.
> La columna `Descripcion` aparece vacía porque el documento no establece una descripción
> personalizada — en producción conviene añadir un tag o usar un documento personalizado
> que incluya el ID del volumen y la fecha en la descripción.

```bash
# Limpieza: elimina el snapshot creado por la remediación y termina la instancia
SNAPSHOT_ID=$(aws ec2 describe-snapshots \
  --filters "Name=volume-id,Values=$VOLUME_ID" \
  --query 'Snapshots[0].SnapshotId' --output text)

aws ec2 delete-snapshot --snapshot-id "$SNAPSHOT_ID"
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
```

**Pistas:**
- El documento `AWS-CreateSnapshot` tiene el parámetro `VolumeId`, no `ResourceId`
- La regla `ENCRYPTED_VOLUMES` **solo evalúa volúmenes en estado `attached`** (adjuntos a una instancia en ejecución).
  Un volumen `available` no es evaluado y nunca aparecerá como `NON_COMPLIANT`.
- Revisa los logs de SSM Automation si la remediación no se dispara:
  `aws ssm describe-automation-executions --filters "Key=DocumentNamePrefix,Values=AWS-CreateSnapshot"`

---

### Reto 2 — Política OPA para S3 sin versionado

La empresa exige que todos los buckets S3 creados por Terraform tengan el versionado
habilitado. Actualmente la política OPA solo cubre los listeners de ALB.

**Objetivo**: escribir una nueva política Rego que deniegue la creación de buckets S3
sin `aws_s3_bucket_versioning` asociado con `status = "Enabled"`.

1. Crea el archivo `labs/lab49/policies/s3_versioning_required.rego`:

```rego
package terraform.aws.s3

# Obtén todos los buckets S3 que se van a crear o actualizar
buckets_en_plan contains nombre if {
  resource := input.resource_changes[_]
  resource.type == "aws_s3_bucket"
  resource.change.actions[_] in ["create", "update"]
  nombre := resource.address
}

# Obtén todos los recursos de versionado S3 con "Enabled"
buckets_con_versionado contains bucket_ref if {
  resource := input.resource_changes[_]
  resource.type == "aws_s3_bucket_versioning"
  resource.change.actions[_] in ["create", "update"]
  resource.change.after.versioning_configuration[_].status == "Enabled"
  bucket_ref := resource.change.after.bucket
}
```

Completa la regla `deny` que combine ambas condiciones: un bucket sin versionado en
el plan debe generar un mensaje de error.

2. Crea los archivos de datos de prueba en `testdata/`:
   - `plan_s3_no_versioning.json` — bucket sin `aws_s3_bucket_versioning` (debe FALLAR)
   - `plan_s3_with_versioning.json` — bucket con versionado habilitado (debe PASAR)

3. Escribe los tests unitarios en `s3_versioning_required_test.rego`.

4. Verifica:

```bash
cd labs/lab49
conftest test policies/testdata/plan_s3_no_versioning.json --policy policies/ --all-namespaces
conftest verify --policy policies/ --output table
```

**Pistas:**
- La relación entre `aws_s3_bucket_versioning` y `aws_s3_bucket` se establece mediante
  el atributo `bucket` que contiene el nombre o ID del bucket referenciado.
- En el JSON del plan, las referencias entre recursos aparecen como strings resueltos
  en `after` pero pueden ser unknowns (`null`) en el plan antes del apply. Para los
  datos de prueba, usa nombres literales.

---

### Reto 3 — Notificación SNS cuando Config detecta un incumplimiento

Actualmente los incumplimientos solo son visibles consultando la API. En producción, el
equipo de seguridad necesita una notificación inmediata por email o Slack cuando Config
detecta un recurso no-conforme.

**Objetivo**: configurar un EventBridge Rule que capture eventos de Config
`ComplianceChangeNotification` y los envíe a un SNS topic con suscripción de email.

1. Crea el archivo `aws/notifications.tf` con:
   - Un `aws_sns_topic` llamado `lab49-config-alerts`
   - Una política del topic que permita a `events.amazonaws.com` publicar
   - Un `aws_cloudwatch_event_rule` con `event_pattern` que capture:
     ```json
     {
       "source": ["aws.config"],
       "detail-type": ["Config Rules Compliance Change"],
       "detail": {
         "messageType": ["ComplianceChangeNotification"],
         "newEvaluationResult": {
           "complianceType": ["NON_COMPLIANT"]
         }
       }
     }
     ```
   - Un `aws_cloudwatch_event_target` que apunte al SNS topic

2. Aplica y suscribe tu email al topic:

```bash
terraform apply

ALERTS_SNS=$(terraform output -raw config_alerts_sns_arn)

aws sns subscribe \
  --topic-arn "$ALERTS_SNS" \
  --protocol email \
  --notification-endpoint "tu-email@ejemplo.com"

echo "Confirma la suscripción desde tu correo."
```

3. Prueba la notificación creando un volumen EBS sin cifrar y esperando el email.

**Pistas:**
- `aws_cloudwatch_event_rule` usa el argumento `event_pattern` con un JSON como string
- La política del topic SNS necesita `aws:SourceArn` del event bus para evitar confused
  deputy problem
- Los eventos de Config llegan en segundos a EventBridge pero el email puede tardar 1-2 min

---

### Reto 4 — Config Rule personalizada con Lambda

Las reglas gestionadas de Config cubren los casos comunes, pero a veces la lógica de
cumplimiento es específica de tu organización. En este reto crearás una regla
personalizada usando una función Lambda.

**Objetivo**: crear una regla Config personalizada que marque como no-conforme cualquier
instancia EC2 que NO tenga la etiqueta `CostCenter` definida.

1. El código Python de la Lambda ya está disponible en `aws/lambda/tag_checker.py`.
   Léelo para entender su comportamiento antes de implementar el Terraform.

   Crea el archivo `aws/custom_rule.tf`. Tu tarea es implementar en Terraform:
   - Un IAM role para la Lambda con `AWSLambdaBasicExecutionRole`,
     `config:PutEvaluations` y `ec2:DescribeInstances`
   - Un `aws_lambda_permission` que permita a `config.amazonaws.com` invocar la Lambda
   - Un `aws_config_config_rule` con `source.owner = "CUSTOM_LAMBDA"`,
     dos `source_detail` (`ConfigurationItemChangeNotification` y `ScheduledNotification`)
     y scope limitado a `AWS::EC2::Instance`

2. Aplica y verifica:

```bash
terraform apply

aws configservice start-config-rules-evaluation \
  --config-rule-names "lab49-ec2-costcenter-tag-required"

sleep 60

# Observa las invocaciones de la Lambda en tiempo real para confirmar que
# Config la está llamando y qué evaluación está enviando
aws logs tail "/aws/lambda/lab49-ec2-tag-checker" --follow

aws configservice get-compliance-summary-by-config-rule \
  --query 'ComplianceSummariesByConfigRule[?ConfigRuleName==`lab49-ec2-costcenter-tag-required`]'
```

**Pistas:**
- La Lambda necesita un trigger de `CONFIGURATION_CHANGE` para EC2 instances
- El `source.source_detail` en la regla personalizada debe incluir
  `event_source = "aws.config"` y `message_type = "ConfigurationItemChangeNotification"`
- Las tags en `configurationItem` vienen como un mapa `{key: value}` en la mayoría de
  los recursos

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Remediación para EBS (CreateSnapshot)</strong></summary>

### Solución al Reto 1

**Por qué CreateSnapshot en lugar de cifrar directamente:**

AWS no permite modificar el cifrado de un volumen EBS existente directamente. La
secuencia correcta para cifrar un volumen existente es:
1. Crear un snapshot del volumen
2. Copiar el snapshot habilitando cifrado (`aws ec2 copy-snapshot --encrypted`)
3. Crear un nuevo volumen desde el snapshot cifrado
4. Detener la instancia, desconectar el volumen antiguo, conectar el nuevo
5. Arrancar la instancia y verificar

La remediación automática solo hace el paso 1 (el más seguro para automatizar sin
interrumpir la instancia). Los pasos siguientes requieren una ventana de mantenimiento
y validación manual.

**Añadir en `remediation.tf`:**

```hcl
# Rol específico para remediación de EBS
resource "aws_iam_role" "remediation_ebs" {
  name = "lab49-remediation-ebs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "remediation_ebs_policy" {
  name = "lab49-remediation-ebs-policy"
  role = aws_iam_role.remediation_ebs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:CreateSnapshot", "ec2:DescribeSnapshots"]
      Resource = "*"
    }]
  })
}

resource "aws_config_remediation_configuration" "ebs_snapshot" {
  config_rule_name = aws_config_config_rule.ebs_encrypted.name

  resource_type  = "AWS::EC2::Volume"
  target_type    = "SSM_DOCUMENT"
  target_id      = "AWS-CreateSnapshot"

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.remediation_ebs.arn
  }

  parameter {
    name           = "VolumeId"
    resource_value = "RESOURCE_ID"
  }

  automatic                  = true
  maximum_automatic_attempts = 1
  retry_attempt_seconds      = 60

  execution_controls {
    ssm_controls {
      concurrent_execution_rate_percentage = 10
      error_percentage                     = 50
    }
  }
}
```

</details>

---

<details>
<summary><strong>Solución al Reto 2 — Política OPA para S3 sin versionado</strong></summary>

### Solución al Reto 2

**El desafío de las referencias entre recursos en el plan JSON:**

En un plan de Terraform, `aws_s3_bucket_versioning` hace referencia al bucket mediante
el ARN o nombre del bucket. En el JSON del plan, cuando el bucket es nuevo (se crea en
el mismo plan), la referencia aparece como un valor desconocido (`(known after apply)`)
representado con un campo `after_unknown`. Para los datos de prueba usamos valores
literales.

**`policies/s3_versioning_required.rego`:**

```rego
package terraform.aws.s3

# Todos los buckets S3 que se crean o actualizan en el plan
buckets_en_plan contains address if {
  resource := input.resource_changes[_]
  resource.type == "aws_s3_bucket"
  resource.change.actions[_] in ["create", "update"]
  address := resource.address
}

# Todos los buckets que tienen versionado habilitado en el plan
buckets_con_versionado contains bucket_name if {
  resource := input.resource_changes[_]
  resource.type == "aws_s3_bucket_versioning"
  resource.change.actions[_] in ["create", "update"]
  resource.change.after.versioning_configuration[_].status == "Enabled"
  bucket_name := resource.change.after.bucket
}

# Denegar buckets sin versionado
deny contains msg if {
  bucket_address := buckets_en_plan[_]
  resource := input.resource_changes[_]
  resource.address == bucket_address
  resource.change.after.bucket != null
  bucket_name := resource.change.after.bucket

  not buckets_con_versionado[bucket_name]

  msg := sprintf(
    "VIOLACIÓN [S3-001] — '%s': el bucket '%s' no tiene versionado habilitado. Añade aws_s3_bucket_versioning con status = 'Enabled'.",
    [bucket_address, bucket_name]
  )
}
```

**Nota importante**: en planes donde el bucket se crea en el mismo plan y el nombre es
conocido (no generado), esta lógica funciona correctamente. Si el nombre del bucket
contiene referencias a otros recursos, `resource.change.after.bucket` puede ser
desconocido en el plan; en ese caso se necesita una estrategia alternativa como revisar
si existe el recurso `aws_s3_bucket_versioning` para el mismo módulo/contexto.

**Cómo funciona la lógica en dos conjuntos:**

La política usa dos conjuntos intermedios en lugar de una sola regla `deny` para mayor
claridad y testabilidad:

1. `buckets_en_plan` — recorre `resource_changes` y recopila las **direcciones** (`address`)
   de todos los `aws_s3_bucket` que se crean o actualizan.
2. `buckets_con_versionado` — recorre los `aws_s3_bucket_versioning` del plan y recopila
   los **nombres de bucket** (`change.after.bucket`) que tienen `status = "Enabled"`.
3. `deny` — para cada bucket en el plan, obtiene su nombre (`change.after.bucket`) y
   comprueba si ese nombre aparece en `buckets_con_versionado`. Si no aparece,
   emite la violación.

La separación en conjuntos permite testear cada conjunto de forma independiente antes de
testear la regla `deny` completa.

**`policies/s3_versioning_required_test.rego`:**

```rego
package terraform.aws.s3_test

import rego.v1

import data.terraform.aws.s3

test_bucket_sin_versionado_debe_ser_rechazado if {
  count(s3.deny) == 1 with input as {
    "resource_changes": [
      {
        "address": "aws_s3_bucket.datos",
        "type": "aws_s3_bucket",
        "change": {
          "actions": ["create"],
          "before": null,
          "after": {"bucket": "mi-bucket-datos"}
        }
      }
    ]
  }
}

test_bucket_con_versionado_debe_pasar if {
  count(s3.deny) == 0 with input as {
    "resource_changes": [
      {
        "address": "aws_s3_bucket.datos",
        "type": "aws_s3_bucket",
        "change": {
          "actions": ["create"],
          "before": null,
          "after": {"bucket": "mi-bucket-datos"}
        }
      },
      {
        "address": "aws_s3_bucket_versioning.datos",
        "type": "aws_s3_bucket_versioning",
        "change": {
          "actions": ["create"],
          "before": null,
          "after": {
            "bucket": "mi-bucket-datos",
            "versioning_configuration": [{"status": "Enabled"}]
          }
        }
      }
    ]
  }
}

test_destruccion_bucket_debe_pasar if {
  count(s3.deny) == 0 with input as {
    "resource_changes": [
      {
        "address": "aws_s3_bucket.legacy",
        "type": "aws_s3_bucket",
        "change": {
          "actions": ["delete"],
          "before": {"bucket": "bucket-legacy"},
          "after": null
        }
      }
    ]
  }
}

test_plan_sin_buckets_debe_pasar if {
  count(s3.deny) == 0 with input as {
    "resource_changes": [
      {
        "address": "aws_vpc.main",
        "type": "aws_vpc",
        "change": {
          "actions": ["create"],
          "before": null,
          "after": {"cidr_block": "10.0.0.0/16"}
        }
      }
    ]
  }
}
```

**Ejecutar los tests y validar los datos de prueba:**

```bash
# Ejecutar los tests unitarios desde la raíz del lab
# --policy indica el directorio con las políticas (conftest busca "policy" por defecto, no "policies")
conftest verify --policy policies/

# Validar un plan con bucket sin versionado (debe fallar)
cat > /tmp/plan_s3_sin_versionado.json <<'EOF'
{
  "resource_changes": [
    {
      "address": "aws_s3_bucket.datos",
      "type": "aws_s3_bucket",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {"bucket": "mi-bucket-datos"}
      }
    }
  ]
}
EOF

conftest test /tmp/plan_s3_sin_versionado.json --policy policies/ --all-namespaces

# Validar un plan con versionado habilitado (debe pasar)
cat > /tmp/plan_s3_con_versionado.json <<'EOF'
{
  "resource_changes": [
    {
      "address": "aws_s3_bucket.datos",
      "type": "aws_s3_bucket",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {"bucket": "mi-bucket-datos"}
      }
    },
    {
      "address": "aws_s3_bucket_versioning.datos",
      "type": "aws_s3_bucket_versioning",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {
          "bucket": "mi-bucket-datos",
          "versioning_configuration": [{"status": "Enabled"}]
        }
      }
    }
  ]
}
EOF

conftest test /tmp/plan_s3_con_versionado.json --policy policies/ --all-namespaces
```

Salida esperada para el plan sin versionado:

```
FAIL - /tmp/plan_s3_sin_versionado.json - terraform.aws.s3 - VIOLACIÓN [S3-001] — 'aws_s3_bucket.datos': el bucket 'mi-bucket-datos' no tiene versionado habilitado. Añade aws_s3_bucket_versioning con status = 'Enabled'.

2 tests, 1 passed, 0 warnings, 1 failure, 0 exceptions
```

> `2 tests` porque `--all-namespaces` evalúa todas las políticas del directorio: la política
> ALB (`terraform.aws.alb`) no encuentra listeners en el plan y pasa sin violaciones (1 passed),
> mientras que la política S3 detecta el bucket sin versionado (1 failure).

Salida esperada para el plan con versionado:

```
2 tests, 2 passed, 0 warnings, 0 failures, 0 exceptions
```

**Integración con GitHub Actions — completamente testeable:**

No hay que modificar el workflow de GitHub Actions. El hook del Paso 5 ya está
configurado con `--policy policies/` y `--all-namespaces`, por lo que evalúa
**todos los archivos `.rego`** del directorio `policies/` en cada ejecución.
Añadir `s3_versioning_required.rego` es suficiente — el pipeline lo recogerá
automáticamente en el siguiente push.

```yaml
# .github/workflows/terraform.yml — sin cambios respecto al Paso 5
- name: Tests unitarios de políticas OPA
  run: conftest verify --policy policies/ --output table

- name: Aplicar políticas OPA al plan
  run: conftest test plan.json --policy policies/ --all-namespaces
```

Para probarlo end-to-end:

1. Añade `s3_versioning_required.rego` al directorio `policies/`.
2. Haz un push de un cambio en Terraform que cree un `aws_s3_bucket` **sin**
   su correspondiente `aws_s3_bucket_versioning`.
3. El pipeline fallará en el paso `conftest test` con la violación `[S3-001]`
   y bloqueará el `terraform apply` antes de que el recurso se cree en AWS.

</details>

---

<details>
<summary><strong>Solución al Reto 3 — Notificación SNS con EventBridge</strong></summary>

### Solución al Reto 3

**Arquitectura del flujo de notificación:**

```
AWS Config                 EventBridge              SNS Topic
─────────────              ───────────              ─────────
Regla detecta          →   Regla filtra         →   Publica
NON_COMPLIANT              eventos Config           mensaje
                           (event pattern)          → Email / Slack / Lambda
```

El flujo tiene tres actores:

1. **Config** emite un evento al bus de EventBridge cada vez que el estado de
   cumplimiento de un recurso cambia (`ComplianceChangeNotification`).
2. **EventBridge** filtra esos eventos y solo reacciona a los que transicionan
   a `NON_COMPLIANT` — ignorando los `COMPLIANT` para no generar ruido.
3. **SNS** distribuye el mensaje a todos los suscriptores: email, HTTP/S
   (Slack via webhook), Lambda, SQS, etc.

**Por qué hace falta una política en el topic SNS:**

Por defecto, SNS solo permite que el propietario de la cuenta publique mensajes.
EventBridge es un servicio independiente que necesita permiso explícito para
llamar a `sns:Publish`. La condición `ArnLike` en la política restringe ese
permiso a las reglas EventBridge de esta cuenta — evita que cualquier otro
recurso externo publique en el topic usando el ARN del servicio.

**`aws/notifications.tf`:**

```hcl
# Topic SNS que recibirá las alertas de incumplimiento.
# Los suscriptores (email, Lambda, Slack webhook) se añaden aquí o manualmente
# desde la consola de SNS.
resource "aws_sns_topic" "config_alerts" {
  name = "lab49-config-alerts"
}

# Política de acceso del topic: permite a EventBridge publicar mensajes.
# Sin esta política, el envío desde EventBridge falla silenciosamente con
# AccessDenied — el evento se consume pero el mensaje nunca llega a SNS.
resource "aws_sns_topic_policy" "config_alerts" {
  arn = aws_sns_topic.config_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgeToPublish"
      Effect = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.config_alerts.arn
      # Restringe el permiso a reglas EventBridge de esta cuenta y región.
      # Sin la condición, cualquier regla EventBridge de cualquier cuenta
      # podría publicar en este topic si conoce su ARN.
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:aws:events:${var.region}:${data.aws_caller_identity.current.account_id}:rule/*"
        }
      }
    }]
  })
}

# Regla EventBridge que escucha eventos de Config en tiempo real.
# EventBridge recibe todos los eventos del bus por defecto; el event_pattern
# actúa como filtro — solo los eventos que coincidan dispararán el target.
resource "aws_cloudwatch_event_rule" "config_non_compliant" {
  name        = "lab49-config-non-compliant"
  description = "Captura incumplimientos de reglas Config en tiempo real"

  # El patrón filtra en tres niveles:
  #   source       → solo eventos originados en AWS Config
  #   detail-type  → solo cambios de cumplimiento de reglas (no inventario)
  #   detail       → solo transiciones a NON_COMPLIANT (no a COMPLIANT)
  # Filtrar en detail.newEvaluationResult evita alertas cuando un recurso
  # vuelve a COMPLIANT tras ser remediado, reduciendo el ruido operativo.
  #
  # IMPORTANTE: event_pattern DEBE codificarse con jsonencode(). Pasar un objeto
  # HCL literal o un string JSON hardcodeado provoca:
  #   Error: Argument must be a JSON-encoded string
  # jsonencode() serializa el objeto HCL a JSON en tiempo de plan, garantizando
  # que el resultado es un string válido que la API de EventBridge acepta.
  event_pattern = jsonencode({
    source        = ["aws.config"]
    "detail-type" = ["Config Rules Compliance Change"]
    detail = {
      messageType = ["ComplianceChangeNotification"]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })
}

# Target: conecta la regla EventBridge con el topic SNS.
# Un mismo rule puede tener múltiples targets (SNS + Lambda + SQS a la vez).
resource "aws_cloudwatch_event_target" "config_to_sns" {
  rule      = aws_cloudwatch_event_rule.config_non_compliant.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.config_alerts.arn
}
```

Añade el output **al final** de `aws/outputs.tf`, dejando una línea en blanco
de separación respecto al bloque anterior (Terraform requiere una línea en blanco
entre bloques; sin ella el parser lanza `Missing newline after block definition`):

```hcl
output "config_alerts_sns_arn" {
  description = "ARN del topic SNS de alertas — úsalo para suscribir emails o webhooks"
  value       = aws_sns_topic.config_alerts.arn
}
```

**Suscribir un email para recibir las alertas:**

> Ejecuta `terraform apply` antes de continuar. El output `config_alerts_sns_arn`
> no estará disponible hasta que Terraform haya creado el topic SNS y registrado
> su ARN en el estado.

```bash
# Aplica los cambios para crear el topic SNS y la regla EventBridge
terraform apply

SNS_ARN=$(terraform output -raw config_alerts_sns_arn)

aws sns subscribe \
  --topic-arn "$SNS_ARN" \
  --protocol email \
  --notification-endpoint tu@email.com
```

Recibirás un email de confirmación — debes confirmar la suscripción antes de
que los mensajes lleguen.

**Verificar que la regla EventBridge se disparó:**

```bash
# Confirma que la regla existe y está activa
aws events describe-rule \
  --name lab49-config-non-compliant \
  --query '{Nombre:Name,Estado:State,Patron:EventPattern}' \
  --output table

# Ver métricas de invocaciones en CloudWatch (puede tardar 2-3 min en aparecer)
# Si devuelve "null" o "[]" es porque no hubo invocaciones en la ventana temporal,
# no porque el comando sea incorrecto — espera a haber disparado una detección.
aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name Invocations \
  --dimensions Name=RuleName,Value=lab49-config-non-compliant \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 3600 \
  --statistics Sum \
  --query 'Datapoints[].Sum | [0] || `0`'
```



> Si devuelve `0`, indica que la regla está activa pero no ha habido eventos `NON_COMPLIANT`
> en la última hora. Para ver un valor mayor, ejecuta la prueba end-to-end
> del siguiente apartado y espera 2-3 minutos antes de volver a consultar.

**Probar el flujo end-to-end:**

Reutiliza el bucket de prueba del Paso 4 — al deshabilitar el Block Public Access,
Config lo marcará `NON_COMPLIANT` y EventBridge enviará la alerta a SNS en segundos:

```bash
BUCKET_TEST="lab49-test-public-$(date +%s)"

# us-east-1 es la región por defecto de S3 y no acepta LocationConstraint
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET_TEST"
else
  aws s3api create-bucket --bucket "$BUCKET_TEST" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

# Deshabilita el bloqueo para disparar la detección
aws s3api delete-public-access-block --bucket "$BUCKET_TEST"

# Fuerza la reevaluación inmediata en lugar de esperar el ciclo periódico
aws configservice start-config-rules-evaluation \
  --config-rule-names "$RULE_S3"

# Espera 2-3 minutos — deberías recibir el email de alerta (probablemente junto con otras notificaciones de AWS Security Hub)
# La remediación automática del Paso 4 restaurará el bloqueo poco después

# Limpieza
aws s3 rb "s3://$BUCKET_TEST" --force
```

</details>

---

<details>
<summary><strong>Solución al Reto 4 — Config Rule personalizada con Lambda</strong></summary>

### Solución al Reto 4

**Por qué una regla Lambda en lugar de una gestionada:**

Las reglas gestionadas de Config cubren los casos que AWS ha implementado. La lógica
de etiquetado es específica de cada organización — cada empresa usa distintas claves
de tag, distintos valores válidos y distintos recursos obligatorios. Una regla Lambda
permite codificar esa lógica de negocio en Python sin restricciones.

**Flujo de evaluación de una regla personalizada:**

```
Config detecta cambio en EC2
        │
        ▼
Invoca Lambda con evento JSON
        │
        ├── invokingEvent.configurationItem.resourceType
        ├── invokingEvent.configurationItem.resourceId
        ├── invokingEvent.configurationItem.tags   ← dict {key: value}
        └── resultToken  ← devuelto a config.put_evaluations()
        │
        ▼
Lambda llama a config.put_evaluations()
con COMPLIANT o NON_COMPLIANT
        │
        ▼
Config actualiza el estado de cumplimiento del recurso
```

**Nota sobre el formato de tags en `configurationItem`:**

Un error habitual es asumir que las tags llegan como lista de objetos (como en la API
de EC2). En `configurationItem`, las tags ya vienen como diccionario `{key: value}`:

```python
# ❌ Incorrecto — intenta iterar como si fueran objetos {key, value}
tags = {t['key']: t['value'] for t in config_item.get('tags', {}).items()}

# ✅ Correcto — tags ya es {key: value}, se usa directamente
tags = config_item.get('tags', {})
```

El fichero `lambda/tag_checker.py` ya usa el patrón correcto. Fíjate también en
`handle_scheduled`, donde las tags vienen de la API de EC2 (lista) y sí requieren
una comprensión de lista diferente.

La solución se divide en dos ficheros: la infraestructura Lambda en `custom_rule.tf` y
la regla Config en `config.tf`, siguiendo la misma convención que el resto del laboratorio
(las reglas gestionadas `lab49-ebs-encrypted-volumes` y `lab49-s3-public-access-prohibited`
ya viven en `rules.tf`, pero la regla personalizada se añade a `config.tf` porque depende
directamente del recorder y del permission de Lambda).

**`aws/custom_rule.tf`** — Lambda, IAM y permiso de invocación:

```hcl
# Empaqueta el fichero Python externo como ZIP.
# El código reside en lambda/tag_checker.py (mismo módulo Terraform).
# El proveedor "archive" calcula el hash automáticamente → Lambda solo se
# redespliega cuando el código fuente cambia de verdad.
data "archive_file" "tag_checker" {
  type        = "zip"
  source_file = "${path.module}/lambda/tag_checker.py"
  output_path = "${path.module}/lambda/tag_checker.zip"
}

# IAM Role para la Lambda
resource "aws_iam_role" "tag_checker" {
  name = "lab49-tag-checker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "tag_checker_basic" {
  role       = aws_iam_role.tag_checker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "tag_checker_config" {
  name = "lab49-tag-checker-config-policy"
  role = aws_iam_role.tag_checker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Devuelve el resultado de la evaluación a Config
        Effect   = "Allow"
        Action   = ["config:PutEvaluations"]
        Resource = "*"
      },
      {
        # Necesario para el modo ScheduledNotification: listar todas las instancias
        # y evaluar sus tags cuando se invoca start-config-rules-evaluation
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "tag_checker" {
  function_name    = "lab49-ec2-tag-checker"
  role             = aws_iam_role.tag_checker.arn
  filename         = data.archive_file.tag_checker.output_path
  source_code_hash = data.archive_file.tag_checker.output_base64sha256
  runtime          = "python3.12"
  handler          = "tag_checker.lambda_handler"
  timeout          = 30
}

# Permiso para que Config invoque la Lambda.
# Sin este permiso, Config descubre la Lambda pero no puede ejecutarla.
# source_account evita el "confused deputy problem": solo Config de esta cuenta puede invocarla.
resource "aws_lambda_permission" "config" {
  statement_id   = "AllowConfigInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.tag_checker.function_name
  principal      = "config.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}
```

**`aws/config.tf`** — añade al final del fichero la regla personalizada:

```hcl
# Regla Config personalizada vinculada a la Lambda del Reto 4
resource "aws_config_config_rule" "ec2_costcenter_tag" {
  name = "lab49-ec2-costcenter-tag-required"

  source {
    owner             = "CUSTOM_LAMBDA"
    source_identifier = aws_lambda_function.tag_checker.arn

    # Tipo 1: Config invoca la Lambda cuando una instancia EC2 cambia de estado
    # (creación, modificación de tags, parada, terminación)
    source_detail {
      event_source = "aws.config"
      message_type = "ConfigurationItemChangeNotification"
    }

    # Tipo 2: permite que start-config-rules-evaluation dispare la Lambda.
    # Sin este bloque, start-config-rules-evaluation envía una ScheduledNotification
    # que la Lambda ignora y la re-evaluación manual no funciona.
    source_detail {
      event_source = "aws.config"
      message_type = "ScheduledNotification"
    }
  }

  # Limita el scope a EC2 — evita invocaciones innecesarias sobre otros recursos
  scope {
    compliance_resource_types = ["AWS::EC2::Instance"]
  }

  depends_on = [
    aws_config_configuration_recorder_status.main,
    aws_lambda_permission.config
  ]
}
```

**Verificar la evaluación end-to-end:**

```bash
terraform apply

# Lanza una instancia SIN la tag CostCenter para probar NON_COMPLIANT
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)

TEST_INSTANCE=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instancia sin CostCenter: $TEST_INSTANCE"

# Fuerza la evaluación y espera
aws configservice start-config-rules-evaluation \
  --config-rule-names "lab49-ec2-costcenter-tag-required"

sleep 60

# Debe mostrar NON_COMPLIANT
aws configservice get-compliance-details-by-resource \
  --resource-type AWS::EC2::Instance \
  --resource-id "$TEST_INSTANCE" \
  --query 'EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName==`lab49-ec2-costcenter-tag-required`].ComplianceType' \
  --output text
```

Salida esperada:

```
NON_COMPLIANT
```

Ahora añade la tag `CostCenter` y observa cómo Config re-evalúa automáticamente la instancia:

```bash
# Añade la tag CostCenter.
# Añadir una tag es un cambio de configuración: Config captura el nuevo
# configurationItem (con la tag) y envía un ConfigurationItemChangeNotification
# a la Lambda. Este tipo de evento actualiza el cumplimiento inmediatamente,
# a diferencia de ScheduledNotification cuya propagación puede tardar minutos.
aws ec2 create-tags \
  --resources "$TEST_INSTANCE" \
  --tags Key=CostCenter,Value=engineering

echo "Tag CostCenter añadida. Config invocará la Lambda automáticamente..."

# Fuerza la re-evaluación inmediata sin esperar el ciclo periódico de Config.
# El cambio de tag ya disparó un ConfigurationItemChangeNotification, pero
# start-config-rules-evaluation garantiza que la evaluación se encola ahora.
aws configservice start-config-rules-evaluation \
  --config-rule-names "lab49-ec2-costcenter-tag-required"

# Espera activa: sondea cada 10 segundos hasta que el resultado cambie a COMPLIANT
echo "Esperando a que Config propague el resultado..."
until aws configservice get-compliance-details-by-resource \
  --resource-type AWS::EC2::Instance \
  --resource-id "$TEST_INSTANCE" \
  --query 'EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName==`lab49-ec2-costcenter-tag-required`].ComplianceType' \
  --output text | grep -q "^COMPLIANT$"; do
  echo "  Aún NON_COMPLIANT, reintentando en 10 s..."
  sleep 10
done

echo "¡Instancia marcada como COMPLIANT!"

# Muestra el detalle final con la marca de tiempo de la evaluación
aws configservice get-compliance-details-by-resource \
  --resource-type AWS::EC2::Instance \
  --resource-id "$TEST_INSTANCE" \
  --query 'EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ConfigRuleName==`lab49-ec2-costcenter-tag-required`].{
    Estado:ComplianceType,
    Evaluado:ResultRecordedTime
  }' \
  --output table
```

Salida esperada:

```
------------------------------------------
|  GetComplianceDetailsByResource        |
+---------------+------------------------+
|    Estado     |        Evaluado        |
+---------------+------------------------+
|  COMPLIANT    |  2026-04-15T10:23:41Z  |
+---------------+------------------------+
```

El campo `Evaluado` confirma que la evaluación ocurrió **después** de añadir la tag — es la prueba de que Config invocó la Lambda en respuesta al `ConfigurationItemChangeNotification` generado por `ec2:CreateTags`, no una evaluación anterior en caché.

> **Cumplimiento a nivel de recurso vs. regla:**
> `get-compliance-details-by-resource` muestra el estado de la instancia concreta —
> puede ser `COMPLIANT` aunque la regla en la consola aparezca como `NON_COMPLIANT`.
> La regla solo se marca `COMPLIANT` en la consola cuando **todas** las instancias EC2
> en scope tienen la tag `CostCenter`. Si hay otras instancias en la cuenta sin esa tag,
> la regla seguirá mostrando `NON_COMPLIANT` a nivel de regla, lo cual es correcto.

```bash
# Limpieza
aws ec2 terminate-instances --instance-ids "$TEST_INSTANCE"

# Elimina el log group de CloudWatch generado por la Lambda.
# Lambda crea el log group automáticamente en la primera invocación;
# terraform destroy no lo elimina porque no fue creado por Terraform.
aws logs delete-log-group \
  --log-group-name "/aws/lambda/lab49-ec2-tag-checker"
```

**Diagnóstico si la Lambda no se invoca:**

```bash
# Logs de CloudWatch de la Lambda — muestra errores de ejecución
aws logs tail "/aws/lambda/lab49-ec2-tag-checker" --follow

# Verificar que Config tiene permiso de invocación
aws lambda get-policy \
  --function-name lab49-ec2-tag-checker \
  --query 'Policy' \
  --output text | jq '.Statement[] | {Principal: .Principal, Action: .Action}'
```

</details>

---

## Limpieza

```bash
cd labs/lab49/aws

terraform destroy
```

> **Nota sobre Security Hub**: `terraform destroy` desactiva Security Hub y elimina todas
> las suscripciones a estándares. Los hallazgos generados durante el laboratorio se
> eliminan también. Si tenías Security Hub habilitado antes de este laboratorio, revisa
> primero si esto afecta otras suscripciones.

> **Nota sobre Config**: al destruir el recorder, Config deja de grabar cambios. El
> bucket S3 de entrega se elimina con `force_destroy = true`, incluyendo todos los
> snapshots y el historial de configuración almacenados.

Limpieza manual de recursos de prueba si quedaron sin eliminar:

```bash
# Verificar volúmenes EBS de prueba pendientes
aws ec2 describe-volumes \
  --filters "Name=tag:CreatedBy,Values=lab49-test" \
  --query 'Volumes[].VolumeId' --output text \
  | xargs -r -n1 aws ec2 delete-volume --volume-id

# Verificar buckets S3 de prueba pendientes
aws s3api list-buckets \
  --query 'Buckets[?starts_with(Name, `lab49-test-`)].Name' \
  --output text \
  | xargs -r -n1 -I{} aws s3 rb "s3://{}" --force

# Eliminar el log group de CloudWatch de la Lambda del Reto 4.
# Lambda crea este log group automáticamente en la primera invocación y
# terraform destroy no lo gestiona porque no forma parte del estado de Terraform.
aws logs delete-log-group \
  --log-group-name "/aws/lambda/lab49-ec2-tag-checker"
```

---

## Solución de problemas

### Config Recorder activo pero el bucket S3 está vacío

**Causa**: la política del bucket S3 no permite a Config escribir objetos.

**Diagnóstico**:

```bash
# Verifica el último error del recorder
aws configservice describe-configuration-recorder-status \
  --configuration-recorder-names "$RECORDER_NAME" \
  --query 'ConfigurationRecordersStatus[0].{
    UltimoError:lastErrorCode,
    MensajeError:lastErrorMessage,
    UltimoExito:lastSuccessfulDeliveryTime
  }' \
  --output table
```

Si `UltimoError` es `InsufficientDeliveryPolicyException` o similar, la política del
bucket está mal configurada. Ejecuta `terraform apply` para restaurarla.

```bash
# Verifica la política actual del bucket
aws s3api get-bucket-policy --bucket "$CONFIG_BUCKET" \
  --query 'Policy' --output text | python3 -m json.tool
```

La política debe tener dos statements: `AWSConfigBucketPermissionsCheck` (GetBucketAcl)
y `AWSConfigBucketDelivery` (PutObject).

---

### La remediación automática de S3 no se ejecuta

**Causa 1**: el rol IAM de remediación no tiene los permisos correctos.

```bash
# Simula la ejecución del documento SSM manualmente
aws ssm start-automation-execution \
  --document-name "AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock" \
  --parameters "AutomationAssumeRole=${REMEDIATION_ROLE_ARN},BucketName=${BUCKET_TEST}"

# Verifica el resultado
aws ssm describe-automation-executions \
  --filters "Key=DocumentNamePrefix,Values=AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock" \
  --query 'AutomationExecutionMetadataList[0].{Estado:AutomationExecutionStatus,Error:FailureMessage}' \
  --output table
```

Si el error es `AccessDenied`, verifica que el rol `lab49-remediation-role` tiene la
política inline con `s3:PutBucketPublicAccessBlock`.

**Causa 2**: el bucket no fue evaluado como NON_COMPLIANT todavía.

La remediación solo se dispara cuando Config detecta el incumplimiento. Fuerza la
evaluación manualmente:

```bash
aws configservice start-config-rules-evaluation \
  --config-rule-names "$RULE_S3"
```

**Causa 3**: el `maximum_automatic_attempts` ya se agotó.

Si la remediación falló 3 veces (por error de permisos), Config no lo reintentará
hasta que el recurso vuelva a ser evaluado y siga siendo NON_COMPLIANT. Fuerza una
nueva evaluación después de corregir el rol.

---

### conftest: "no policies found"

**Causa**: el directorio de políticas no existe o los archivos `.rego` no están en la
ruta correcta.

```bash
# Verifica que los archivos están en el lugar correcto
ls -la labs/lab49/policies/
# Debe mostrar: alb_https_only.rego, alb_https_only_test.rego, testdata/

# Ejecuta desde el directorio raíz del repositorio con ruta relativa
conftest test labs/lab49/policies/testdata/plan_http_denied.json \
  --policy labs/lab49/policies/ \
  --all-namespaces
```

Si `conftest` no encuentra políticas, verifica que los archivos terminan en `.rego`
(no `.rego.txt` o similar).

---

### Security Hub muestra puntuación 0% o "No data"

**Causa**: AWS Config no estaba habilitado antes de activar Security Hub, o la
evaluación inicial de los controles FSBP todavía no ha completado.

```bash
# Verifica que el recorder está activo
aws configservice describe-configuration-recorder-status \
  --query 'ConfigurationRecordersStatus[0].recording'

# Fuerza la evaluación de todos los controles FSBP
# (puede tardar 10-20 minutos en cuentas con muchos recursos)
aws securityhub describe-standards-controls \
  --standards-subscription-arn "$FSBP_SUBSCRIPTION_ARN" \
  --query 'Controls[0:3].{Control:ControlId,Estado:ControlStatus}' \
  --output table
```

La puntuación se actualiza gradualmente a medida que los controles van evaluándose.
En cuentas nuevas con pocos recursos, la evaluación completa puede tardar 30-60 minutos.

---

### Error "ResourceInUseException" al crear el Config Recorder

**Causa**: ya existe un Configuration Recorder en la cuenta (solo se permite uno por
región). Esto ocurre si otro laboratorio o proceso habilitó Config anteriormente.

```bash
# Verifica recorders existentes
aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[].name'
```

Si ya existe un recorder con nombre diferente, importa el existente al estado de
Terraform en lugar de crear uno nuevo:

```bash
EXISTING_RECORDER=$(aws configservice describe-configuration-recorders \
  --query 'ConfigurationRecorders[0].name' --output text)

terraform import aws_config_configuration_recorder.main "$EXISTING_RECORDER"
terraform import aws_config_configuration_recorder_status.main "$EXISTING_RECORDER"
```

Después de importar, ajusta `variables.tf` si el nombre del recorder existente no
coincide con `"lab49-recorder"`.
