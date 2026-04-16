# Sección 4 — Gestión de Secretos

> [← Sección anterior](./03_kms_cifrado.md) | [Siguiente →](./05_seguridad_avanzada.md)

---

## 4.1 Secrets Manager vs. SSM Parameter Store

AWS ofrece dos servicios para almacenar configuración y secretos. La elección depende del tipo de dato, requisitos de rotación y presupuesto:

| Aspecto | SSM Parameter Store | Secrets Manager |
|---------|--------------------|-----------------| 
| **Uso principal** | Configuración y secretos simples | Secretos complejos (JSON) |
| **Cifrado** | SecureString con KMS | Nativo con KMS (CMK recomendada) |
| **Rotación** | Sin rotación nativa automática | Rotación nativa con Lambda integrada |
| **Versionado** | Manual | `AWSCURRENT`/`AWSPREVIOUS` automático |
| **Coste** | Gratuito (tier estándar) | ~$0.40/secreto/mes + API calls |
| **Ideal para** | Feature flags, endpoints, AMI IDs | Credenciales de BD, API keys, OAuth |
| **Compliance** | General | PCI-DSS, GDPR ✅ |

---

## 4.2 SSM Parameter Store: Tipos y Jerarquías

SSM Parameter Store soporta tres tipos de parámetros y permite organizar valores en rutas jerárquicas tipo filesystem:

| Tipo | Uso | Cifrado |
|------|-----|---------|
| `String` | Endpoints, AMI IDs, nombres | Sin cifrado por defecto |
| `StringList` | Listas de IPs, subnets, tags (separados por comas) | Sin cifrado |
| `SecureString` | Tokens, passwords simples | Cifrado con KMS (CMK) |

**Patrón de rutas jerárquicas:**
```
/prod/database/endpoint    → Organización por entorno
/prod/database/password    → SecureString cifrado
/staging/api/feature-flags → Configuración por app
```

**Código: Parámetros Jerárquicos en SSM**

```hcl
# Parámetro de tipo String
resource "aws_ssm_parameter" "db_endpoint" {
  name  = "/prod/database/endpoint"
  type  = "String"
  value = "mydb.cluster-abc.us-east-1.rds.amazonaws.com"
}

# Parámetro SecureString (cifrado con KMS)
resource "aws_ssm_parameter" "db_password" {
  name   = "/prod/database/password"
  type   = "SecureString"
  value  = var.db_password
  key_id = aws_kms_key.main.arn
}

# StringList para múltiples subnets
resource "aws_ssm_parameter" "private_subnets" {
  name  = "/prod/network/private_subnets"
  type  = "StringList"
  value = "subnet-aaa,subnet-bbb,subnet-ccc"
}
```

---

## 4.3 Secrets Manager: El Contenedor Seguro

`aws_secretsmanager_secret` define el recurso contenedor — nombre, descripción, política de acceso y llave KMS. El **valor real** se almacena por separado en una `secret_version`:

**Ciclo de vida del secreto:**
```
Creación  → secret + secret_version
Rotación  → Lambda actualiza el valor automáticamente
Versionado → AWSCURRENT / AWSPREVIOUS / AWSPENDING
Eliminación → Recovery window (7-30 días): protección anti-borrado
```

**Integración nativa con KMS:**
- AWS managed key (`aws/secretsmanager`): gratuita pero sin control de políticas
- CMK personalizada (recomendado): control total, auditoría separada en CloudTrail, cross-account access, compliance GDPR/PCI-DSS

---

## 4.4 Secret vs. Secret Version: La Separación Clave

```
aws_secretsmanager_secret              →    aws_secretsmanager_secret_version
name = "prod/db-credentials"                secret_string = jsonencode({
kms_key_id = aws_kms_key.main.arn               username = "admin"
recovery_window = 30                            password = "s3cR3t!"
(El contenedor)                            })
                                          (El valor actual)
```

**Staging Labels (Versionado):**
- `AWSCURRENT` → Versión activa, la que retorna `GetSecretValue` por defecto
- `AWSPREVIOUS` → Versión anterior, disponible para rollback inmediato
- `AWSPENDING` → Versión en proceso de rotación (transitoria)

**Código: Secreto JSON con Múltiples Campos**

```hcl
# Contenedor del secreto
resource "aws_secretsmanager_secret" "db_creds" {
  name                    = "prod/database/credentials"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 30
}

# Valor del secreto en formato JSON estructurado
resource "aws_secretsmanager_secret_version" "db_creds" {
  secret_id = aws_secretsmanager_secret.db_creds.id

  secret_string = jsonencode({
    username = "admin"
    password = "S3cur3P@ssw0rd!"
    engine   = "mysql"
    host     = "mydb.cluster-abc.rds.amazonaws.com"
    port     = 3306
    dbname   = "production"
  })
}
```

---

## 4.5 Patrón Zero-Touch: `random_password` + Secrets Manager

El patrón más seguro: genera una contraseña aleatoria en Terraform y almacénala directamente en Secrets Manager. **Ningún humano necesita conocer o escribir la contraseña inicial**:

```
1. Generar Password     →   2. Almacenar en SM     →   3. Usar en Recurso
   random_password             secret_version              aws_db_instance
   Criptográficamente          Cifrado con CMK             Password inyectada
   segura                      Versionado automático       automáticamente
```

**Código: Automatización Zero-Touch**

```hcl
# 1. Generar password aleatoria criptográficamente segura
resource "random_password" "db_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}:?"
}

# 2. Almacenar en Secrets Manager
resource "aws_secretsmanager_secret" "db" {
  name       = "prod/db/master-credentials"
  kms_key_id = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.db_master.result
  })
}

# 3. Usar en la base de datos
resource "aws_db_instance" "main" {
  master_username = "admin"
  master_password = random_password.db_master.result
  # ... otras configuraciones
}
```

**Beneficios de seguridad:**
- Ningún humano conoce la contraseña → elimina vector de phishing
- `lifecycle { ignore_changes = [secret_string] }` evita que Terraform sobrescriba rotaciones futuras
- Auditabilidad completa vía CloudTrail + KMS logs

---

## 4.6 Rotación Automática con Lambda

Secrets Manager invoca una función Lambda para cambiar la contraseña en la base de datos y actualizar el secreto simultáneamente:

```
1. Trigger → SM detecta que la rotación es necesaria (cada N días)
2. Create  → Lambda genera nueva password y la marca como AWSPENDING
3. Set     → Lambda cambia la password en la base de datos real
4. Finish  → Lambda promueve AWSPENDING a AWSCURRENT
```

**Código: Configuración de Rotación**

```hcl
# Configurar rotación automática del secreto
resource "aws_secretsmanager_secret_rotation" "db" {
  secret_id           = aws_secretsmanager_secret.db.id
  rotation_lambda_arn = aws_lambda_function.rotator.arn

  rotation_rules {
    automatically_after_days = 30   # Rotar cada 30 días
  }
}

# Permiso para que SM invoque la Lambda
resource "aws_lambda_permission" "sm_invoke" {
  statement_id  = "AllowSecretsManager"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotator.function_name
  principal     = "secretsmanager.amazonaws.com"
}
```

> **Nota:** AWS provee Lambdas pre-construidas para RDS MySQL, PostgreSQL, Oracle y SQL Server. Para nuevos proyectos, usa estos blueprints en lugar de escribir la Lambda desde cero.

---

## 4.7 ¿Quién Debe Leer el Secreto? Terraform vs. Runtime

Esta es la pregunta de diseño más importante en la gestión de secretos:

| Enfoque | Flujo | Riesgo |
|---------|-------|--------|
| ❌ **Terraform Lee** | `data.aws_secretsmanager_secret_version` → valor en el `.tfstate` | Secreto en texto plano en el state. Exposición en logs de CI/CD. `terraform show` revela credenciales |
| ✅ **App Lee en Runtime** | TF solo pasa el ARN/nombre. App llama `GetSecretValue` vía AWS SDK | State file limpio de credenciales. Rotación transparente para la app. Auditoría por request en CloudTrail |

**La recomendación es clara: la aplicación debe leer el secreto en tiempo de ejecución, nunca Terraform.**

---

## 4.8 El Gran Peligro: Secretos en el State

> ⚠️ **ADVERTENCIA CRÍTICA:** Cualquier valor pasado como argumento a un recurso Terraform queda almacenado en texto plano dentro de `terraform.tfstate`.

**Qué queda expuesto:**
- Passwords de bases de datos (RDS, Aurora)
- API keys y tokens en variables
- Certificados TLS
- Valores de secretos leídos vía data sources

**Vectores de exposición:**
- State local en disco sin cifrar
- S3 backend sin server-side encryption
- Logs de `terraform plan`/`apply` en CI/CD
- Acceso broad al bucket del state

**Mitigación mínima obligatoria:**
```hcl
# Backend S3 con cifrado KMS — siempre
backend "s3" {
  encrypt    = true
  kms_key_id = "arn:aws:kms:..."
}
# + IAM restrictivo al bucket
# + .tfstate NUNCA en Git → añadir a .gitignore
```

---

## 4.9 Estrategias para Evitar Secretos en el State

| Estrategia | Implementación | Eficacia |
|-----------|---------------|----------|
| **External Data Sources** | `external` provider ejecuta script que lee el secreto fuera de TF | Alta — valor NO se persiste en state |
| **Variables de Entorno** | `TF_VAR_password=$(...)` antes de `terraform apply` | Media — vive en memoria del proceso, pero aún llega al state vía recurso |
| **Lectura en Runtime (SDK)** | App llama `GetSecretValue` en ejecución. TF solo pasa el ARN | Máxima — valor NUNCA toca el state file ✅ |

---

## 4.10 Integración con ECS y Lambda

**ECS Task Definition:**
```json
"secrets": [
  {
    "name": "DB_PASSWORD",
    "valueFrom": "arn:aws:secretsmanager:...:prod/db"
  }
]
```
El ECS agent descifra el secreto al iniciar el task. El valor vive **solo en memoria del container**. El task role necesita `GetSecretValue`.

**Lambda:**
- Método 1: Pasar el ARN como variable de entorno. Lambda lee el valor vía SDK en runtime.
- Método 2: SDK directo en código — `client.get_secret_value(SecretId=arn)`

---

## 4.11 IAM Policies Granulares para Secretos

Solo ciertos roles deben poder leer ciertos secretos. Usa Resource-level permissions con el ARN específico del secreto:

```hcl
resource "aws_iam_policy" "read_db_secret" {
  name = "AllowReadDBSecret"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.db.arn   # ARN específico, no *
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.main.arn   # Necesario para descifrar el secreto
      }
    ]
  })
}
```

**Separación de funciones:**
- Rol de app: solo `GetSecretValue`
- Rol de admin: `Create` + `Rotate` + `Delete`

---

## 4.12 Gobernanza con AWS Config

AWS Config evalúa continuamente tus secretos contra reglas predefinidas:

| Regla Config | Detección |
|-------------|-----------|
| `secretsmanager-rotation-enabled` | Detecta secretos sin rotación automática configurada |
| `secretsmanager-using-cmk` | Verifica que los secretos usen una CMK y no la llave por defecto |
| `secretsmanager-scheduled-rotation` | Valida que la rotación se ejecute dentro del período definido |

---

## 4.13 Troubleshooting

| Problema | Causa | Fix |
|---------|-------|-----|
| `AWSCURRENT` tiene la password vieja pero la DB tiene la nueva | La rotación falló a mitad del proceso | `aws secretsmanager describe-secret` para verificar staging labels |
| `AccessDeniedException` al leer el secreto | El rol tiene `GetSecretValue` pero le falta `kms:Decrypt` | Añadir `kms:Decrypt` en la política IAM apuntando al ARN de la KMS key |
| Lambda de rotación no encuentra el secreto | La Lambda está en VPC sin acceso a Secrets Manager | Crear VPC Endpoint para `secretsmanager` o configurar NAT Gateway |

---

## 4.14 Resumen: Gestión Profesional de Secretos

| Servicio | Uso ideal |
|---------|----------|
| **SSM Parameter Store** | Configuración, feature flags, endpoints. Gratuito (Standard tier) |
| **Secrets Manager** | Credenciales complejas con rotación. Compliance PCI-DSS/GDPR |
| **Backend S3 cifrado** | Proteger el State que contiene secretos en texto plano |
| **Lectura en Runtime** | La app lee el secreto vía SDK — nunca Terraform |

> **Principio:** El secreto perfecto es el que ningún humano conoce, ningún log captura y ningún archivo almacena. El patrón `random_password` + Secrets Manager + lectura en runtime por SDK es el más cercano a este ideal.

---

> **Siguiente:** [Sección 5 — Seguridad Avanzada →](./05_seguridad_avanzada.md)
