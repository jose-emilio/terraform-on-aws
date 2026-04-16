# Laboratorio 11 — Gestión de Drift y Disaster Recovery (3-2-1)

[← Módulo 3 — Gestión del Estado (State)](../../modulos/modulo-03/README.md)


## Visión general

Aprender a detectar y gestionar el **drift de infraestructura** (divergencia entre el estado deseado y la realidad) y a aplicar una estrategia de **Disaster Recovery 3-2-1** para recuperar el estado de Terraform desde el versionado de S3.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **Drift** | Divergencia entre el estado registrado en `terraform.tfstate` y la infraestructura real |
| **`terraform plan`** | Detecta drift al comparar estado con la realidad (refresca antes de calcular el plan) |
| **`terraform apply -refresh-only`** | Actualiza el estado para reflejar la realidad *sin* modificar infraestructura |
| **Terraform gana** | Estrategia de reconciliación: aplicar para revertir los cambios manuales |
| **La realidad gana** | Estrategia de reconciliación: actualizar el código para que refleje el cambio manual |
| **Versioning S3** | Cada `terraform apply` genera una nueva versión del `.tfstate`; permite restaurar versiones anteriores |
| **Disaster Recovery 3-2-1** | 3 copias, 2 medios distintos, 1 offsite — el S3 con versioning proporciona la copia offsite |

## Prerrequisitos

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado
- lab07/aws desplegado (bucket S3 con versionado habilitado)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.5

```bash
# Exportar el Account ID y nombre del bucket para usar en los comandos
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab11/
├── README.md                    ← Esta guía
├── aws/
│   ├── providers.tf             ← Backend S3 parcial
│   ├── variables.tf
│   ├── main.tf                  ← VPC + Security Group con tags explícitos
│   ├── outputs.tf
│   └── aws.s3.tfbackend         ← Parámetros del backend (sin bucket)
└── localstack/
    ├── README.md                ← Guía específica para LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf
    ├── outputs.tf
    └── localstack.s3.tfbackend  ← Backend completo para LocalStack
```

## 1. Despliegue inicial

```bash
cd labs/lab11/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

Anota los outputs, los necesitarás en los pasos siguientes:

```bash
terraform output
# vpc_id            = "vpc-0abc123..."
# security_group_id = "sg-0def456..."
# security_group_name = "app-lab11"
```

Verifica el estado almacenado en S3:

```bash
aws s3 ls s3://$BUCKET/lab11/
# 2024-01-15 10:00:00       1234 terraform.tfstate
```

---

## 2. Fase 1: Detección de Drift

El drift ocurre cuando alguien modifica infraestructura fuera de Terraform (consola web, CLI, otro proceso). Terraform no lo sabe hasta que ejecuta un `plan` o `apply`.

### 2.1 Introducir drift manualmente

Obtén el ID del security group desplegado:

```bash
SG_ID=$(terraform output -raw security_group_id)
echo "Security Group: $SG_ID"
```

**Cambio 1: Modificar un tag** (simula un cambio "legítimo" pero no registrado en el código):

```bash
aws ec2 create-tags \
  --resources $SG_ID \
  --tags Key=Environment,Value=production
```

**Cambio 2: Abrir un puerto SSH** (simula un cambio accidental o de emergencia):

```bash
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

### 2.2 Detectar el drift con Terraform

```bash
terraform plan
```

Terraform actualizará automáticamente su vista de la realidad y mostrará las diferencias:

```
  # aws_security_group.app will be updated in-place
  ~ resource "aws_security_group" "app" {
        id                     = "sg-xxxxxxxxxxx"
        name                   = "app-lab11"
      ~ tags                   = {
          ~ "Environment" = "production" -> "lab"
            "ManagedBy"   = "terraform"
            "Name"        = "app-lab11"
        }
      ~ tags_all               = {
          ~ "Environment" = "production" -> "lab"
            # (2 unchanged elements hidden)
        }
        # (8 unchanged attributes hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

> **Nota:** El plan solo muestra el drift del tag. La regla de ingreso del puerto 22 **no aparece** porque `aws_security_group` únicamente reconcilia los atributos declarados en el código: al no haber ningún bloque `ingress {}` definido, Terraform no gestiona las reglas de ingreso y las ignora por completo. Este comportamiento es intencional: Terraform solo es responsable de lo que tú le dices que gestione.

---

## 3. Fase 2: Reconciliación

Ante un drift, tienes dos estrategias posibles. La elección depende de si el cambio manual fue un error o una decisión válida que hay que incorporar al código.

### Estrategia A: "Terraform gana" — Revertir al estado deseado

Úsala cuando el cambio manual fue un **error** o no autorizado.

```bash
terraform apply
```

Terraform revertirá el tag `Environment` a `"lab"`. La regla de ingreso del puerto 22 **no será eliminada**: como no hay bloques `ingress` en el código, Terraform no la gestiona y la ignora.

Para eliminar la regla fuera de Terraform, usa AWS CLI:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

Tras la revocación, la infraestructura coincide exactamente con el código.

### Estrategia B: "La realidad gana" — Actualizar el código

Úsala cuando el cambio manual fue **válido** y hay que mantenerlo.

**Paso 1**: Actualiza el estado de Terraform para que refleje la realidad sin tocar infraestructura:

```bash
terraform apply -refresh-only
```

Terraform mostrará los cambios detectados y pedirá confirmación para actualizar *solo el estado*:

```
~ aws_security_group.app
  ~ tags
    ~ Environment = "lab" -> "production"
  + ingress { ... puerto 22 ... }

Would you like to update the Terraform state to reflect these detected changes?
  Terraform will write these changes to the state without modifying your infrastructure.
  As a result, your Terraform plan may differ from this plan.

  Only 'yes' will be accepted to confirm.
```

**Paso 2**: Ahora el código y el estado no coinciden. Actualiza `main.tf` para incorporar el cambio que quieres conservar:

```hcl
# En main.tf, actualiza el tag del grupo de seguridad:
tags = {
  Name        = "app-lab11"
  Environment = "production"   # ← incorporamos el cambio válido
  ManagedBy   = "terraform"
}
```

**Paso 3**: Aplica. Como el tag ya coincide entre código y realidad, Terraform no hará ningún cambio:

```bash
terraform apply
# No changes. Your infrastructure matches the configuration.
```

La regla de ingreso del puerto 22 **sigue en AWS** y también está registrada en el estado (desde el paso 1). Como el código no declara bloques `ingress`, Terraform no la considera un drift a resolver. Para eliminarla usa CLI:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

> **Lección clave:** Terraform solo gestiona lo que declaras en el código. `apply -refresh-only` actualiza el estado para reflejar la realidad, pero no amplía el alcance de gestión de Terraform: si un atributo no está declarado en el código, seguirá fuera del control de Terraform incluso después del `refresh-only`.

---

## 4. Fase 3: Disaster Recovery — Restaurar Estado desde S3

Simularás la corrupción o pérdida del archivo de estado y lo recuperarás usando el versionado de S3.

### 4.1 Listar versiones del archivo de estado

Antes de corromper nada, lista las versiones disponibles:

```bash
aws s3api list-object-versions \
  --bucket $BUCKET \
  --prefix lab11/terraform.tfstate \
  --query 'Versions[*].[VersionId,LastModified,IsLatest]' \
  --output table
```

Deberías ver al menos una versión (la creada por el `apply` inicial). Guarda el `VersionId` de la versión sana:

```bash
GOOD_VERSION=$(aws s3api list-object-versions \
  --bucket $BUCKET \
  --prefix lab11/terraform.tfstate \
  --query 'Versions[?IsLatest==`true`].VersionId' \
  --output text)
echo "Versión sana: $GOOD_VERSION"
```

### 4.2 Simular la corrupción del estado

```bash
# Sobreescribir el estado con contenido inválido
echo '{"version":4,"corrupted":true}' | \
  aws s3 cp - s3://$BUCKET/lab11/terraform.tfstate
```

Verifica que Terraform ya no puede leer el estado:

```bash
terraform plan
# ╷#
 Error: state data in S3 does not have the expected content.
│
│ The state data in S3 does not have the expected content.
│
```

### 4.3 Restaurar el estado sano desde S3

Usa `s3api copy-object` para restaurar la versión anterior sin descargar el archivo:

```bash
aws s3api copy-object \
  --bucket $BUCKET \
  --copy-source "$BUCKET/lab11/terraform.tfstate?versionId=$GOOD_VERSION" \
  --key lab11/terraform.tfstate
```

### 4.4 Verificar la restauración

```bash
terraform plan
# No changes. Your infrastructure matches the configuration.
```

El estado está restaurado. Terraform puede operar con normalidad.

> **La estrategia 3-2-1 en la práctica:**
> - **3 copias**: estado local (si existe), S3 (versión actual), S3 (versiones anteriores)
> - **2 medios**: disco local + almacenamiento en la nube (S3)
> - **1 offsite**: S3 está en AWS, físicamente separado de tu máquina local

---

## 5. Reto: Drift Selectivo con `apply -refresh-only`

Ahora que conoces las dos estrategias de reconciliación, enfrenta un escenario más realista:

**Situación**: Tu equipo introduce dos cambios manuales simultáneos en el security group:
1. Cambian el tag `Environment` de `"lab"` a `"staging"` — cambio **válido**, acordado en reunión
2. Añaden el tag `Owner = "equipo-de-ops"` — cambio **accidental**, no debe quedar en el código

**Tu objetivo**: Reconciliar la infraestructura de forma que:
- El tag `Environment = "staging"` quede **en el código** y en la infraestructura
- El tag `Owner = "equipo-de-ops"` sea **eliminado** de la infraestructura
- Al finalizar, `terraform plan` muestre `No changes`

**Restricciones**:
- No puedes hacer `terraform destroy` y volver a aplicar
- Debes usar `terraform apply -refresh-only` en algún punto del proceso

**Pistas**:
- ¿En qué orden debes ejecutar `refresh-only` y editar el código?
- ¿Qué muestra `terraform plan` antes y después del `refresh-only`?
- ¿Cómo sabes que has terminado correctamente?

La solución está en la [sección 6](#6-solución-del-reto).

---

## 6. Solución del Reto

### Paso 1: Introducir los dos drifts

```bash
SG_ID=$(terraform output -raw security_group_id)

# Drift 1: tag válido
aws ec2 create-tags \
  --resources $SG_ID \
  --tags Key=Environment,Value=staging

# Drift 2: tag accidental
aws ec2 create-tags \
  --resources $SG_ID \
  --tags Key=Owner,Value=equipo-de-ops
```

### Paso 2: Verificar el drift

```bash
terraform plan
```

El plan muestra ambos cambios de tags en `aws_security_group.app`:

```
~ resource "aws_security_group" "app" {
    ~ tags = {
        ~ "Environment" = "staging" -> "lab"
        + "Owner"       = "equipo-de-ops" -> null
      }
  }

Plan: 0 to add, 1 to change, 0 to destroy.
```

Terraform quiere revertir `Environment` a `"lab"` y eliminar `Owner` (porque ninguno de los dos está en el código).

### Paso 3: Capturar el estado real con refresh-only

```bash
terraform apply -refresh-only
```

Confirma con `yes`. Ahora el estado refleja la realidad: `Environment = "staging"` y `Owner = "equipo-de-ops"`.

### Paso 4: Actualizar el código para el cambio válido

Edita `aws/main.tf`, añade `Environment = "staging"` pero **no** añadas `Owner`:

```hcl
tags = {
  Name        = "app-lab11"
  Environment = "staging"    # ← incorporamos el cambio válido
  ManagedBy   = "terraform"
}
```

### Paso 5: Aplicar para revertir solo el cambio accidental

```bash
terraform plan
```

Ahora el plan muestra *únicamente* la eliminación del tag `Owner` (el tag `Environment` ya coincide entre código y realidad):

```
~ resource "aws_security_group" "app" {
    ~ tags = {
        - "Owner" = "equipo-de-ops" -> null
          # (3 unchanged elements hidden)
      }
  }

Plan: 0 to add, 1 to change, 0 to destroy.
```

```bash
terraform apply
```

### Paso 6: Verificar el resultado final

```bash
terraform plan
# No changes. Your infrastructure matches the configuration.
```

El tag `Environment = "staging"` está en el código y en la infraestructura. El tag `Owner` fue eliminado.

---

## 7. Limpieza

```bash
terraform destroy \
  -var="region=us-east-1"
```

> **Nota:** No destruyas el bucket S3, ya que es un recurso compartido entre laboratorios (lab02).

---

## 8. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

El flujo es idéntico, sustituyendo `aws` por `awslocal` en todos los comandos de AWS CLI.

---

## Verificación final

```bash
# Verificar el estado actual del bucket de aplicacion
aws s3api get-bucket-tagging \
  --bucket $(terraform output -raw app_bucket_name)

# Detectar drift (si los tags han sido modificados manualmente)
terraform plan -refresh-only

# Comprobar las versiones del state en S3
aws s3api list-object-versions \
  --bucket $(terraform output -raw state_bucket_name) \
  --prefix "lab11/terraform.tfstate" \
  --query 'Versions[*].{Version:VersionId,LastModified:LastModified}' \
  --output table

# Confirmar que el estado esta sincronizado (no hay cambios pendientes)
terraform plan -detailed-exitcode
echo "Exit code: $? (0=sin cambios, 2=hay cambios)"
```

---

## Buenas prácticas aplicadas

- **`-refresh-only` para decisión controlada**: aplicar un refresh-only muestra exactamente qué ha cambiado en la nube sin modificar la infraestructura real. Permite decidir si aceptar el drift (actualizar el estado) o revertirlo (aplicar el plan completo).
- **Versionado del state en S3**: el versionado del bucket de estado permite restaurar el estado anterior si se corrompe o se aplica un plan incorrecto, implementando la regla "1 copia en un soporte diferente" del principio 3-2-1.
- **Nunca editar el state manualmente**: editar `terraform.tfstate` a mano puede corromper el estado. Usar `terraform state mv`, `terraform state rm` y el bloque `import {}` son las operaciones seguras de manipulación de estado.
- **`terraform plan -refresh-only` en pipelines**: ejecutar un plan refresh-only periódicamente (por ejemplo, en un scheduled pipeline diario) detecta drift antes de que cause problemas en el siguiente despliegue.
- **`ignore_changes` para drift esperado**: si ciertos atributos son modificados por procesos externos de forma intencional (por ejemplo, tags de Cost Explorer), usar `lifecycle { ignore_changes = [tags] }` evita falsos positivos de drift.
- **State locking con DynamoDB**: el locking evita que dos operaciones de Terraform concurrentes corrompan el estado. Siempre habilitarlo en entornos de equipo.

---

## Recursos

- [Terraform: When to use `refresh-only`](https://developer.hashicorp.com/terraform/tutorials/state/refresh)
- [S3 Object Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [Managing Drift in Terraform](https://developer.hashicorp.com/terraform/tutorials/state/resource-drift)
