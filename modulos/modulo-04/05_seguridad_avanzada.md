# Sección 5 — Seguridad Avanzada y Cumplimiento

> [← Sección anterior](./04_secretos.md) | [Siguiente →](./06_seguridad_pipeline.md)

---

## 5.1 De Reactiva a Proactiva: El Ecosistema de Vigilancia

La seguridad tradicional reacciona a incidentes. AWS permite un modelo **proactivo**: detectar amenazas en tiempo real, agregar hallazgos en un panel único y gobernar el cumplimiento automáticamente.

| Servicio | Rol | Función |
|---------|-----|---------|
| **GuardDuty** | Detectar | ML sobre VPC Flow Logs, CloudTrail y DNS. Alertas de amenazas en tiempo real |
| **Security Hub** | Agregar | Panel centralizado. Estándares CIS/PCI-DSS. Scoring de postura de seguridad |
| **AWS Config** | Gobernar | Historial de cambios. Reglas de cumplimiento. Remediación automática |

**Principio de Defensa en Profundidad:** Ningún servicio es suficiente por sí solo. La estrategia es combinarlos todos en un ecosistema integrado vía Terraform.

---

## 5.2 GuardDuty: El Detective Inteligente

GuardDuty analiza continuamente logs de tu cuenta usando **Machine Learning**, sin necesidad de instalar agentes ni afectar al rendimiento de tus recursos:

```
VPC Flow Logs  →
CloudTrail     →   GuardDuty ML   →   Findings (Hallazgos)
DNS Logs       →   + Threat feeds
```

**Ejemplos de hallazgos:**
- `CryptoCurrency:EC2/BitcoinTool.B` — Minería de criptomonedas detectada
- `Exfiltration:S3/MaliciousIPCaller` — Exfiltración de datos desde S3
- `UnauthorizedAccess:IAMUser/Console` — Acceso no autorizado a la consola

> **Zero impacto en rendimiento:** GuardDuty opera fuera de tu VPC, analizando copias de los logs.

**Código: Habilitando el GuardDuty Detector**

```hcl
resource "aws_guardduty_detector" "main" {
  enable = true

  # Frecuencia de publicación de hallazgos
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  # Fuentes de datos opcionales
  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs { enable = true }
    }
  }
}
```

---

## 5.3 AWS Security Hub: El Panel de Control Único

Security Hub recopila alertas de GuardDuty, Inspector, Macie, Config y terceros en un **panel único**. Evalúa tu postura contra estándares de cumplimiento (CSPM):

| Estándar | Descripción |
|---------|------------|
| **CIS AWS Foundations** | 49+ controles de seguridad. Best practices de la industria. Benchmark más adoptado |
| **PCI DSS v3.2.1** | Cumplimiento de pagos. Obligatorio para e-commerce |
| **AWS Foundational** | Best practices propias de AWS. Recomendado como base mínima |

**Integraciones automáticas:** GuardDuty, Inspector, Macie, Config, IAM Access Analyzer envían hallazgos automáticamente en formato ASFF unificado.

**Código: Activación de Security Hub y Estándares**

```hcl
# Habilitar Security Hub en la cuenta
resource "aws_securityhub_account" "main" {}

# Suscribirse al estándar CIS AWS Foundations Benchmark v5.0 (versión actual)
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/cis-aws-foundations-benchmark/v/5.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# Estándar AWS Foundational Security Best Practices
resource "aws_securityhub_standards_subscription" "aws_bp" {
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}
```

---

## 5.4 AWS Config: El Historiador de Recursos

AWS Config graba **cada cambio** en la configuración de tus recursos, permitiéndote responder: ¿Qué cambió? ¿Quién lo cambió? ¿Cuándo?

```
T1: Estado Inicial          T2: Cambio Detectado        T3: Estado Actual
SG abierto al mundo    →    IP restringida a       →    Cifrado habilitado
0.0.0.0/0 en puerto 22      10.0.0.0/16                 Compliant ✓
```

**Capacidades clave:**
- **Configuration Timeline:** historial completo de cada recurso con snapshots
- **Relaciones entre recursos:** "esta SG está asociada a estas 3 instancias"
- Delivery a S3 y SNS para integración con pipelines de gobernanza

---

## 5.5 Config Rules: Políticas en Tiempo Real

Las Config Rules definen el estado deseado de tus recursos. Cada cambio dispara una evaluación automática: `COMPLIANT` o `NON_COMPLIANT`:

**Reglas Gestionadas por AWS (+300 predefinidas):**
- `S3_BUCKET_PUBLIC_READ_PROHIBITED`
- `ENCRYPTED_VOLUMES`
- `RDS_INSTANCE_PUBLIC_ACCESS_CHECK`
- `IAM_PASSWORD_POLICY`

**Código: Regla de Config para S3 Public Access**

```hcl
resource "aws_config_config_rule" "s3_public_read" {
  name = "s3-bucket-public-read-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  # Scope: solo evaluar buckets S3
  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder.main]
}
```

---

## 5.6 Conformance Packs: Cumplimiento como Código

Un **Conformance Pack** es una colección de Config Rules + Remediation Actions empaquetadas en un template YAML. Permite desplegar compliance a escala:

| Pack | Descripción |
|------|------------|
| **CIS AWS Foundations** | 87 reglas basadas en el template AWS managed `Operational-Best-Practices-for-CIS-AWS-v1.4` (versión disponible para Config Conformance Packs; distinta del estándar Security Hub, que ya usa v5.0) |
| **NIST 800-53** | Controles federales de seguridad. Familias: AC, AU, CM, IA, SC |
| **Custom Pack** | Tu propio paquete con reglas específicas de la organización + remediation actions |

> **Nota:** Los templates de Conformance Packs gestionados por AWS siguen versionados en CIS v1.4. El estándar **Security Hub** usa CIS v5.0 (sección 5.3). Son productos distintos con cadencias de versión independientes.

```hcl
resource "aws_config_conformance_pack" "cis" {
  name = "cis-aws-foundations-v1-4"

  # Template YAML almacenado en S3
  template_s3_uri = "s3://${var.bucket}/cis-pack.yaml"

  # Variables del pack (parametrizables)
  input_parameter {
    parameter_name  = "AccessKeysRotatedParamMaxDays"
    parameter_value = "90"
  }

  depends_on = [aws_config_configuration_recorder.main]
}
```

---

## 5.7 CloudTrail: Auditoría de API Calls

CloudTrail registra **cada llamada a la API de AWS**: quién, qué, cuándo y desde dónde. Es el log de auditoría forense de toda la cuenta:

```
API Call → CloudTrail → S3 + CW Logs → Athena / SIEM
(acción)   (captura)    (almacenamiento)  (análisis)
```

**Campos clave de un evento CloudTrail:**
- `userIdentity`: ARN del actor (usuario, rol, servicio)
- `eventName`: acción ejecutada (`RunInstances`, `PutObject`...)
- `sourceIPAddress`: IP de origen de la llamada
- `errorCode`: si la acción fue denegada (`AccessDenied`)

**Código: CloudTrail Multi-Región**

```hcl
resource "aws_cloudtrail" "org_trail" {
  name           = "org-security-trail"
  s3_bucket_name = aws_s3_bucket.trail.id

  # Captura TODAS las regiones
  is_multi_region_trail = true
  is_organization_trail = true

  # Seguridad del trail
  enable_log_file_validation = true    # Detecta manipulación de logs
  kms_key_id                 = aws_kms_key.trail.arn

  # Enviar a CloudWatch para alertas en tiempo real
  cloud_watch_logs_group_arn = aws_cloudwatch_log_group.trail.arn
  cloud_watch_logs_role_arn  = aws_iam_role.trail_cw.arn
}
```

---

## 5.8 VPC Flow Logs: Visibilidad de Red

VPC Flow Logs captura **metadatos de cada conexión de red**: IPs origen/destino, puertos, protocolo y si fue `ACCEPT` o `REJECT`:

```
Formato: version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes action
Ejemplo: 2 123456789 eni-abc123 10.0.1.5 52.94.76.0 443 HTTPS 6 20 4000 ACCEPT
```

**Niveles de captura:**
- **VPC Level:** Captura tráfico de todas las ENIs de la VPC completa
- **Subnet Level:** Foco en una subnet específica. Útil para aislar segmentos
- **ENI Level:** Granularidad máxima. Una interfaz de red específica

**Código: VPC Flow Logs a CloudWatch**

```hcl
resource "aws_flow_log" "vpc_flow" {
  vpc_id       = aws_vpc.main.id
  traffic_type = "ALL"   # ALL | ACCEPT | REJECT

  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow_log.arn

  # Formato custom para más campos de análisis
  log_format = join(" ", [
    "${version} ${account-id} ${interface-id}",
    "${srcaddr} ${dstaddr} ${srcport} ${dstport}",
    "${protocol} ${packets} ${bytes} ${action}"
  ])
}
```

---

## 5.9 Inspector v2: Escaneo de Vulnerabilidades

AWS Inspector v2 escanea automáticamente EC2, Lambda y ECR en busca de **CVEs y configuraciones inseguras**, sin afectar al rendimiento:

| Target | Cómo funciona |
|--------|--------------|
| **EC2 Scanning** | SSM Agent detecta paquetes instalados. Compara contra NVD y ALAS |
| **ECR Scanning** | Escaneo de imágenes Docker al hacer push. Detecta CVEs en capas del contenedor |
| **Lambda Scanning** | Analiza dependencias del código (packages). Python, Node.js, Java, .NET, Go |

**Severidades:**
- `CRITICAL`/`HIGH`: Remediar inmediatamente (CVSS ≥ 7.0)
- `MEDIUM`: Planificar remediación (CVSS 4.0-6.9)
- `LOW`/`INFORMATIONAL`: Monitorear (CVSS < 4.0)

**Código: Habilitación de Inspector v2**

```hcl
resource "aws_inspector2_enabler" "this" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2", "ECR", "LAMBDA"]
}

# Filtro de supresión para falsos positivos conocidos
resource "aws_inspector2_filter" "suppress_low" {
  name   = "suppress-informational"
  action = "SUPPRESS"

  filter_criteria {
    severity {
      comparison = "EQUALS"
      value      = "INFORMATIONAL"
    }
  }
}
```

---

## 5.10 Macie: Protección de Datos Sensibles

Amazon Macie usa ML y pattern matching para identificar **datos sensibles** (PII, credenciales, datos financieros) almacenados en buckets S3:

**Tipos de datos detectados:**
- PII: nombres, direcciones, teléfonos
- Financieros: tarjetas de crédito, cuentas bancarias
- Credenciales: API keys, tokens, passwords en código
- Salud: números de paciente, diagnósticos (HIPAA)
- Custom: tus propios patrones regex

**Flujo de descubrimiento:**
```
1. Inventario: cataloga todos los buckets S3
2. Clasificación: analiza objetos
3. Findings: genera hallazgos detallados
4. Integración: envía a Security Hub
5. Remediación: cifrar, mover, eliminar
```

---

## 5.11 Troubleshooting de Servicios de Seguridad

| Problema | Causa Probable | Fix |
|---------|---------------|-----|
| GuardDuty no genera findings | No está habilitado en la región correcta, o CloudTrail/DNS Logs están inactivos | Verificar habilitación por región. Los findings iniciales pueden tardar hasta 24h |
| Config Rules siempre `NON_COMPLIANT` | Configuration Recorder inactivo, scope incorrecto, o permisos del IAM Role | Confirmar que el Recorder está activo (`depends_on`). Verificar tipo de recurso en scope |
| Security Hub sin datos | Integraciones no habilitadas explícitamente, o servicios en distintas regiones | Habilitar cada integración en la misma región. Verificar estándar de compliance activo |
| CloudTrail: `AccessDenied` en S3 | Bucket policy no permite `cloudtrail.amazonaws.com`, o KMS key policy incorrecta | Verificar bucket policy. Revisar que el prefijo del trail sea correcto |

---

## 5.12 Resumen: El Ecosistema de Seguridad AWS

```
GuardDuty    → Detección de amenazas con ML en tiempo real
Security Hub → Panel centralizado de compliance y findings
Config       → Historial de cambios y reglas de cumplimiento
CloudTrail   → Auditoría forense de todas las API calls
Inspector    → Escaneo de CVEs en EC2, ECR y Lambda
Macie        → Descubrimiento de datos sensibles en S3
```

> **Principio de Defensa en Profundidad:** Ningún servicio es suficiente por sí solo. La estrategia es combinar detección, cumplimiento, auditoría, vulnerabilidades y datos en un ecosistema integrado. Terraform permite habilitarlos todos de forma declarativa y reproducible.

---

> **Siguiente:** [Sección 6 — Seguridad en el Pipeline de Terraform →](./06_seguridad_pipeline.md)
