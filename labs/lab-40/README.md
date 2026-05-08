# Laboratorio 40 — Despliegue Global Multi-Región con `configuration_aliases` y KMS Multi-Region

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 9 — Terraform Avanzado](../../modulos/modulo-09/README.md)


## Visión general

En este laboratorio construirás una pila multi-región que se despliega en **tres regiones AWS** desde un único `terraform apply`, sobre **tres cuentas simuladas** mediante `assume_role`. El núcleo del lab es practicar **`configuration_aliases`** — el mecanismo que permite a un módulo declarar que necesita varios providers AWS configurados sin instanciarlos él mismo, y al root pasárselos explícitamente con `providers = { ... }`.

La arquitectura es la que aparece en cualquier despliegue global real: una **cuenta core** (us-east-1) hospeda los recursos compartidos (KMS multi-region primary, hosted zone privada Route53), y **cada región de aplicación** (eu-west-3, ap-northeast-1) ejecuta el mismo módulo `app-region/` que crea su propia replica KMS, su bucket S3 cifrado, su parámetro SSM y un registro CNAME en la zona privada compartida.

## Objetivos de aprendizaje

- Configurar tres providers AWS con `alias` distintos y `assume_role` para simular una arquitectura multi-cuenta sobre una sola cuenta AWS.
- Entender por qué un proyecto sin provider default obliga a declarar `provider = aws.<alias>` en cada recurso.
- Diseñar un módulo reutilizable que requiere **dos** providers (`aws.this` y `aws.shared`) declarados con `configuration_aliases`.
- Pasar providers a un módulo con la sintaxis `providers = { aws.this = aws.eu, aws.shared = aws.core }`.
- Crear una **KMS multi-region primary key** y dos **replicas** (una por región) referenciando la primary mediante `aws_kms_replica_key`.
- Asociar una hosted zone privada de Route53 a una VPC y registrar CNAMEs regionales desde el propio módulo.
- Inspeccionar el `.terraform.lock.hcl` y entender cómo añadir hashes para múltiples plataformas.
- Destruir recursos en el orden correcto cuando hay dependencias cross-region (replicas KMS antes que primary).

## Requisitos previos

- **Terraform >= 1.10** instalado (`use_lockfile` en backend S3: 1.10).
- AWS CLI configurado con perfil `default` y permisos de administrador en la cuenta de pruebas.
- Laboratorio 02 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
```

> **Nota importante:** este laboratorio crea **tres roles IAM con `AdministratorAccess`** en la cuenta de pruebas. Ejecútalo solo en cuentas dedicadas a aprendizaje. Al destruir el lab, los roles se eliminan limpiamente.

## Arquitectura

![Multi-cuenta simulada con assume_role: aws.core (us-east-1) hospeda KMS multi-region primary y zona privada Route53; aws.eu (eu-west-3) y aws.jp (ap-northeast-1) instancian el mismo módulo app-region con configuration_aliases pasando aws.this y aws.shared](arch/diagrama.svg)

Tres providers `aws` declarados con alias (`core`, `eu`, `jp`), cada uno con `assume_role` apuntando a un rol IAM que simula una cuenta diferente. El root crea **recursos globales** en `aws.core`: una KMS multi-region primary con `multi_region = true`, una VPC mínima de soporte y una hosted zone privada `lab40.internal`. Para cada región de aplicación, el root instancia el mismo módulo `app-region/` pasándole dos providers: `aws.this` (la región destino) y `aws.shared` (la cuenta core). El módulo declara ambos con `configuration_aliases = [aws.this, aws.shared]` y crea recursos en ambos lados — `aws_kms_replica_key`, S3 + cifrado + versionado, SSM parameter en `aws.this`, y un CNAME `<region_short>.lab40.internal` en la zona privada de `aws.shared`. Resultado: un único `terraform apply` despliega coherentemente recursos en tres regiones cruzando cuentas simuladas.

## Conceptos clave

### Providers múltiples con `alias`

Cuando necesitas operar contra varias regiones o cuentas en el mismo proyecto, declaras varios bloques `provider "aws"` distinguidos por su `alias`:

```hcl
provider "aws" {
  alias  = "core"
  region = "us-east-1"
  # ... más adelante: assume_role para simular multi-cuenta
}

provider "aws" {
  alias  = "eu"
  region = "eu-west-3"
  # ...
}
```

**Regla del provider default**: si ningún bloque `provider` carece de alias, **no hay default**. Cada recurso, data source y módulo debe declarar explícitamente qué provider usa. Omitirlo da el error `No default provider configured`.

### `assume_role` para simular multi-cuenta

En multi-cuenta real, cada cuenta tiene su propia cuenta AWS (ej. `123456789012` para "core", `234567890123` para "prod-eu"). El provider asume un rol cross-account antes de cada llamada API:

```hcl
provider "aws" {
  alias  = "core"
  region = "us-east-1"

  assume_role {
    role_arn     = "arn:aws:iam::123456789012:role/OrgAdmin"
    session_name = "terraform-core"
  }
}
```

Para que este lab sea ejecutable con un solo perfil AWS, simulamos las tres cuentas creando **tres roles IAM en la misma cuenta** (ver [`bootstrap/`](aws/bootstrap/)). El patrón Terraform es idéntico al multi-cuenta real — solo cambia que los `role_arn` apuntan al mismo Account ID.

### `configuration_aliases` — declarar providers requeridos en un módulo

Un módulo reutilizable que necesite varios providers AWS no debe instanciarlos él mismo (eso atrapa al consumidor en regiones fijas). Lo correcto es **declarar los aliases que necesita** y dejar que el root los provea:

```hcl
# modules/app-region/providers.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"

      configuration_aliases = [
        aws.this,    # provider de la región donde se despliega la app
        aws.shared,  # provider de la cuenta core (recursos compartidos)
      ]
    }
  }
}
```

Dentro del módulo, los recursos referencian estos aliases declarativamente:

```hcl
resource "aws_kms_replica_key" "this" {
  provider        = aws.this
  primary_key_arn = var.primary_kms_arn
  ...
}

resource "aws_route53_record" "regional_endpoint" {
  provider = aws.shared
  zone_id  = var.private_zone_id
  ...
}
```

### Pasar providers al módulo desde el root

El root mapea sus providers reales a los aliases que el módulo declara:

```hcl
module "app_eu" {
  source = "./modules/app-region"

  providers = {
    aws.this   = aws.eu
    aws.shared = aws.core
  }
  # ... variables
}
```

El módulo no sabe ni le importa qué regiones reales se le pasan: para él son `aws.this` y `aws.shared`. Eso es lo que lo convierte en **reutilizable** — la misma pieza de código se instancia para EU, JP, US-WEST sin tocarla.

### KMS Multi-Region Keys

Una CMK **multi-region** es una clave KMS que puede tener réplicas exactas en otras regiones, todas compartiendo el mismo material criptográfico:

```hcl
resource "aws_kms_key" "global_primary" {
  multi_region = true   # marca la CMK como elegible para tener replicas
  ...
}

resource "aws_kms_replica_key" "this" {
  provider        = aws.this
  primary_key_arn = var.primary_kms_arn   # ARN completo de la primary
  ...
}
```

Beneficio operacional: un texto cifrado generado con la primary en us-east-1 se puede descifrar en eu-west-3 con la replica local — sin llamadas cross-region en el data plane. Esencial para arquitecturas globales con cifrado de datos en reposo.

| Aspecto | Single-region key | Multi-region key |
|---------|-------------------|------------------|
| Cifrar y descifrar en otra región | Llamadas KMS cross-region (latencia + coste) | Llamadas a la replica local |
| Rotación de claves | Independiente | Coordinada entre primary y replicas |
| Eliminación | Inmediata (con ventana) | Se debe eliminar replicas antes que primary |

### Tipos especiales: `aws_kms_replica_key` vs `aws_kms_key`

- `aws_kms_key` con `multi_region = true` → crea la **primary**
- `aws_kms_replica_key` → crea una **replica** referenciando una primary existente

El recurso replica vive en la región DESTINO (definida por su provider), pero `primary_key_arn` contiene la región ORIGEN. AWS infiere la dirección de la replicación desde ahí.

### Hosted zone privada compartida cross-region

Una zona privada de Route53 está asociada a una o más VPCs y solo es resoluble desde dentro de ellas. En este lab, la zona vive en `aws.core` y los registros se crean desde el módulo regional vía `aws.shared` — el patrón típico de "DNS de servicio" en arquitecturas con un control plane centralizado.

## Estructura del proyecto

```
lab-40/
├── arch/
│   └── diagrama.svg
└── aws/
    ├── aws.s3.tfbackend                 # parámetros del backend S3
    ├── providers.tf                     # 3 providers con alias y assume_role
    ├── variables.tf                     # account_id, project, environment, private_zone_name
    ├── main.tf                          # KMS primary + VPC + zona privada + 2x module
    ├── outputs.tf                       # outputs globales y por región
    │
    ├── bootstrap/                       # subproyecto de preparación
    │   └── main.tf                      # crea los 3 roles IAM (lab40-{core,eu,jp}-admin)
    │
    └── modules/
        └── app-region/                  # módulo reutilizable
            ├── providers.tf             # configuration_aliases = [aws.this, aws.shared]
            ├── variables.tf
            ├── main.tf                  # KMS replica + S3 + SSM en aws.this; CNAME en aws.shared
            └── outputs.tf
```

## Despliegue en AWS

### Paso 1 — Crear los roles IAM simulados

El lab requiere tres roles IAM (`lab40-core-admin`, `lab40-eu-admin`, `lab40-jp-admin`) que los providers asumirán. Estos roles **no existen aún**: hay que crearlos antes del lab principal.

```bash
cd labs/lab-40/aws/bootstrap
terraform init
terraform apply
```

Salida esperada:

```text
account_id = "123456789012"
role_arns = {
  "core" = "arn:aws:iam::123456789012:role/lab40-core-admin"
  "eu"   = "arn:aws:iam::123456789012:role/lab40-eu-admin"
  "jp"   = "arn:aws:iam::123456789012:role/lab40-jp-admin"
}
next_step = "..."
```

> **Nota importante:** el bootstrap usa el state local (`terraform.tfstate` en `bootstrap/`). Es intencional — el bootstrap es una operación efímera de preparación, no infraestructura productiva. Al destruir el lab eliminarás también este state.

### Paso 2 — Inicializar y desplegar el lab principal

```bash
cd ..   # volver a labs/lab-40/aws/
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

terraform init -backend-config=aws.s3.tfbackend \
               -backend-config="bucket=terraform-state-labs-${ACCOUNT_ID}"

terraform plan -var "account_id=${ACCOUNT_ID}"
terraform apply -var "account_id=${ACCOUNT_ID}"
```

Tiempo estimado del apply: **3-5 minutos** (el cuello de botella es la creación de las dos replicas KMS, que tardan ~30s cada una en propagarse).

### Paso 3 — Verificar el despliegue cross-region

```bash
# Recursos globales en core
aws kms describe-key --key-id alias/lab40-primary --region us-east-1 \
  --query 'KeyMetadata.MultiRegionConfiguration'

# Replicas regionales
aws kms describe-key --key-id alias/lab40-euwest3 --region eu-west-3 \
  --query 'KeyMetadata.{Region:Arn, Type:MultiRegionConfiguration.MultiRegionKeyType}'
aws kms describe-key --key-id alias/lab40-apnortheast1 --region ap-northeast-1 \
  --query 'KeyMetadata.{Region:Arn, Type:MultiRegionConfiguration.MultiRegionKeyType}'

# Buckets cifrados
terraform output -json region_eu | jq -r '.bucket_name'
terraform output -json region_jp | jq -r '.bucket_name'

# Registros DNS en la zona privada
ZONE_ID=$(terraform output -raw private_zone_id)
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Type=='CNAME']"
```

El comando `verify_commands` del output reúne todos estos comandos:

```bash
terraform output -raw verify_commands
```

### Paso 4 — Probar la replicación criptográfica

Cifra un texto en la primary (us-east-1) y descífralo en una replica (eu-west-3):

```bash
# 1. Cifrar con la primary y guardar el blob binario en un archivo temporal.
#    --cli-binary-format raw-in-base64-out es OBLIGATORIO en AWS CLI v2:
#    sin este flag, el plaintext "Hola desde el lab 39" se interpretaría
#    como base64 y se cifrarían los bytes resultantes (basura).
aws kms encrypt \
  --key-id alias/lab40-primary --region us-east-1 \
  --plaintext "Hola desde el lab 39" \
  --cli-binary-format raw-in-base64-out \
  --output text --query CiphertextBlob | base64 --decode > /tmp/lab40-ct.bin

# 2. Descifrar con la replica de eu-west-3 leyendo el blob binario
aws kms decrypt \
  --ciphertext-blob fileb:///tmp/lab40-ct.bin \
  --region eu-west-3 \
  --output text --query Plaintext | base64 --decode
echo ""
# → Hola desde el lab 39

# 3. Limpieza
rm /tmp/lab40-ct.bin
```

Si funciona, el material criptográfico se está replicando correctamente entre regiones — esto es lo que un servicio S3 hace cuando guarda un objeto cifrado en EU y un consumidor en JP necesita leerlo.

### Paso 5 — Inspeccionar el lock file

```bash
cat .terraform.lock.hcl
```

Verás un único bloque `provider "registry.terraform.io/hashicorp/aws"` con los hashes de la plataforma actual. Para preparar este lab para CI/CD multi-plataforma:

```bash
terraform providers lock \
  -platform=linux_amd64 \
  -platform=darwin_arm64 \
  -platform=darwin_amd64
```

El lock file ahora incluye hashes para las tres plataformas. Versiónalo en Git — garantiza que cualquier developer y el CI obtienen exactamente el mismo binario del provider, descartando "funciona en mi máquina".

## Verificación final

```bash
# ── 1. Outputs de Terraform ──────────────────────────────────────────────────
terraform output -raw account_id
terraform output -raw kms_primary_alias
terraform output -json region_eu
terraform output -json region_jp

# ── 2. KMS multi-region: primary tiene 2 replicas ────────────────────────────
aws kms describe-key --key-id alias/lab40-primary --region us-east-1 \
  --query 'KeyMetadata.MultiRegionConfiguration.ReplicaKeys | length(@)'
# Esperado: 2

# ── 3. Buckets cifrados con replica KMS de su región ─────────────────────────
EU_BUCKET=$(terraform output -json region_eu | jq -r '.bucket_name')
aws s3api get-bucket-encryption --bucket "$EU_BUCKET" --region eu-west-3 \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm'
# Esperado: "aws:kms"

# ── 4. Zona privada con 2 CNAMEs ─────────────────────────────────────────────
ZONE_ID=$(terraform output -raw private_zone_id)
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Type=='CNAME'] | length(@)"
# Esperado: 2
```

## Retos

### Reto 1 — Añadir una tercera región sin tocar el módulo

Despliega el mismo módulo en `us-west-2` (Oregon) sin modificar `modules/app-region/`. Pasos:

1. Crear el rol `lab40-uswest-admin` en `bootstrap/main.tf` añadiendo `"uswest"` a `local.simulated_accounts`.
2. Aplicar el bootstrap.
3. Añadir un nuevo provider `aws.uswest` en `providers.tf` con `region = "us-west-2"` y `assume_role` apuntando al nuevo rol.
4. Añadir un `module "app_uswest"` en `main.tf` con `providers = { aws.this = aws.uswest, aws.shared = aws.core }`.
5. Aplicar y verificar que aparece la tercera replica KMS y un tercer CNAME `uswest2.lab40.internal`.

**Pregunta**: ¿Cuántas líneas de código nuevo has tenido que escribir? La respuesta refleja el valor de `configuration_aliases`: el módulo crece a N regiones sin tocar su contenido.

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Añadir una tercera región sin tocar el módulo</strong></summary>

### Solución al Reto 1 — Añadir una tercera región sin tocar el módulo

El reto demuestra el principal valor de `configuration_aliases`: el módulo `app-region/` no se modifica en absoluto. Solo se añade un rol IAM nuevo, un bloque `provider`, una llamada al módulo y un output. El módulo se reutiliza tal cual.

### Pieza 1 — Añadir la cuenta simulada al bootstrap

Edita `aws/bootstrap/main.tf` añadiendo `"uswest"` al map de cuentas simuladas:

```hcl
# aws/bootstrap/main.tf
locals {
  simulated_accounts = ["core", "eu", "jp", "uswest"]   # +1 entrada
}
```

Aplica el bootstrap para crear el cuarto rol:

```bash
cd aws/bootstrap
terraform apply
# Salida esperada: lab40-uswest-admin añadido al map role_arns
cd ..
```

### Pieza 2 — Declarar el nuevo provider en el root

Añade al final de `aws/providers.tf`:

```hcl
provider "aws" {
  alias  = "uswest"
  region = "us-west-2"

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/lab40-uswest-admin"
    session_name = "lab40-uswest-session"
  }
}
```

### Pieza 3 — Instanciar el módulo para us-west-2

Añade al final de `aws/main.tf`:

```hcl
module "app_uswest" {
  source = "./modules/app-region"

  providers = {
    aws.this   = aws.uswest
    aws.shared = aws.core
  }

  project           = var.project
  primary_kms_arn   = aws_kms_key.global_primary.arn
  private_zone_id   = aws_route53_zone.private.zone_id
  private_zone_name = aws_route53_zone.private.name

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```

### Pieza 4 — Output regional adicional

Añade al final de `aws/outputs.tf`:

```hcl
output "region_uswest" {
  description = "Recursos desplegados por la instancia US-West del módulo"
  value = {
    region             = module.app_uswest.region
    bucket_name        = module.app_uswest.bucket_name
    bucket_arn         = module.app_uswest.bucket_arn
    kms_replica_arn    = module.app_uswest.kms_replica_arn
    kms_alias_name     = module.app_uswest.kms_alias_name
    ssm_parameter_name = module.app_uswest.ssm_parameter_name
    regional_dns_name  = module.app_uswest.regional_dns_name
  }
}
```

### Aplicación y verificación

```bash
# Reinicializar: la nueva llamada a `module "app_uswest"` requiere registrar
# la instancia en .terraform/modules/. Si te lo saltas, terraform plan
# fallará con: "Error: Module not installed".
terraform init -backend-config=aws.s3.tfbackend \
               -backend-config="bucket=terraform-state-labs-${ACCOUNT_ID}"

terraform apply -var "account_id=${ACCOUNT_ID}"

# Verificar que la primary tiene ahora 3 replicas (eu, jp, uswest)
aws kms describe-key --key-id alias/lab40-primary --region us-east-1 \
  --query 'KeyMetadata.MultiRegionConfiguration.ReplicaKeys | length(@)'
# Esperado: 3

# Tercer CNAME en la zona privada
ZONE_ID=$(terraform output -raw private_zone_id)
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Type=='CNAME'].Name"
# Esperado: ["euwest3.lab40.internal.", "apnortheast1.lab40.internal.", "uswest2.lab40.internal."]
```

Balance del ejercicio: **~25 líneas nuevas**, **0 líneas modificadas en `modules/app-region/`**. Eso es el valor de `configuration_aliases` — el módulo escala a N regiones sin tocarlo.

</details>


## Limpieza

KMS multi-region tiene una particularidad: **no se puede destruir la primary mientras existan replicas**. Terraform genera el orden correcto automáticamente porque las replicas dependen de la primary, pero conviene saberlo si te encuentras un caso atascado.

```bash
# 1. Destruir el lab principal (incluye replicas KMS, S3, SSM, Route53 y la primary)
terraform destroy -var "account_id=${ACCOUNT_ID}"

# 2. Eliminar los roles IAM del bootstrap
cd bootstrap
terraform destroy
cd ..
```

Coste total estimado del lab si se destruye al terminar: **menos de 0,50 €** (KMS keys cobran por solicitud y por mes prorrateado; con un destroy en menos de 1h el coste es despreciable).

## Buenas prácticas aplicadas

- **`configuration_aliases` para módulos multi-provider**: el módulo declara qué providers necesita en lugar de instanciar los suyos propios, lo que lo hace verdaderamente reutilizable.
- **`assume_role` por provider** para modelar multi-cuenta: cada provider asume un rol distinto antes de cada llamada API, igual que en producción real.
- **No hay provider default**: la ausencia de un bloque `provider "aws"` sin alias obliga a declarar `provider = aws.<alias>` en cada recurso. Hace explícita la región/cuenta destino y elimina ambigüedades.
- **KMS multi-region keys** en lugar de KMS por región independiente: simplifica el cifrado de datos en arquitecturas globales y evita llamadas cross-region en el data plane.
- **Hosted zone privada compartida** registrada por el módulo: cada región se autoanuncia en el DNS interno sin que el root tenga que conocer los nombres regionales.
- **Lock file con hashes multi-plataforma**: `terraform providers lock -platform=...` garantiza determinismo entre developers locales y CI/CD.

## Recursos

- [Terraform: `configuration_aliases`](https://developer.hashicorp.com/terraform/language/modules/develop/providers#provider-aliases-within-modules)
- [Terraform: pasar providers a módulos](https://developer.hashicorp.com/terraform/language/modules/develop/providers)
- [Terraform: `assume_role` en el AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#assume_role-configuration-block)
- [AWS KMS — Multi-Region Keys](https://docs.aws.amazon.com/kms/latest/developerguide/multi-region-keys-overview.html)
- [`aws_kms_replica_key` resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_replica_key)
- [Route 53 — Private Hosted Zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)
- [Terraform: `terraform providers lock`](https://developer.hashicorp.com/terraform/cli/commands/providers/lock)
