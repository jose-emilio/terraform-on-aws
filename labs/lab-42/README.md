# Laboratorio 42 — Repositorio Privado de Módulos Terraform con CodeArtifact

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 10 — CI/CD y Automatización con Terraform](../../modulos/modulo-10/README.md)


## Visión general

En cualquier proyecto de infraestructura a escala, los módulos de Terraform
son componentes reutilizables que se comparten entre equipos. Si esos módulos
se consumen directamente desde GitHub o desde el Terraform Registry público,
el pipeline de despliegue depende de internet: un módulo puede desaparecer,
ser comprometido o simplemente cambiar sin aviso entre dos runs de `terraform init`.

Este laboratorio implementa una **supply chain privada e inmutable** sobre AWS
CodeArtifact. El registro privado actúa como única fuente de verdad para los
módulos: los pipelines de CI/CD publican versiones versionadas semánticamente
y los consumidores (workstations de desarrolladores, pipelines de despliegue)
los descargan exclusivamente del registro interno, sin acceso a internet.

La inmutabilidad es la propiedad clave: una vez publicado `vpc-module@1.0.0`,
CodeArtifact impide sobrescribir esa versión. La misma URL siempre devuelve
el mismo binario, verificable por hash SHA-256.

## Objetivos

- Aprovisionar un dominio y un repositorio CodeArtifact cifrados con una CMK
  gestionada por Terraform (no la clave AWS/codeartifact por defecto).

- Publicar un módulo VPC local como Generic Package con versión semántica
  `1.0.0` usando la CLI de AWS con credenciales de un usuario `ci-publisher`.

- Verificar la inmutabilidad intentando publicar la misma versión dos veces
  — CodeArtifact rechaza la sobreescritura con un error explícito.

- Configurar `~/.netrc` dinámicamente inyectando el token de autorización de
  CodeArtifact para que Terraform pueda autenticarse sin credenciales
  hardcodeadas.

- Consumir el módulo desde un proyecto Terraform de demostración usando la
  URL HTTPS del registro privado — sin clonar ningún repositorio git.

- Demostrar la separación de roles entre publishers (CI/CD de empaquetado) y
  consumers (CI/CD de despliegue) mediante políticas de identidad IAM y
  políticas de recurso del repositorio.

## Requisitos previos

- Terraform >= 1.5 instalado.
- AWS CLI v2 configurado con perfil `default` y permisos de administrador.
- `jq` instalado (usado en los scripts de credenciales).
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado
  habilitado (necesario para el backend S3 del estado).

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
export REGION="us-east-1"
```

## Arquitectura

```
Supply chain completa:
─────────────────────────────────────────────────────────────────────────────

  ┌──────────────────────────┐
  │  module/vpc/             │  Código fuente del módulo (en este repositorio)
  │  main.tf, variables.tf,  │
  │  outputs.tf              │
  └──────────┬───────────────┘
             │ tar -czf
             ▼
  vpc-module-1.0.0.tar.gz   (asset local, SHA-256 calculado)
             │
             │ aws codeartifact publish-package-version
             │ (credenciales ci-publisher)
             ▼
  ┌────────────────────────────────────────────────────────────────────────┐
  │  AWS CodeArtifact                                                      │
  │                                                                        │
  │  Dominio: supply-chain  (CMK: alias/lab42-codeartifact)                │
  │  └── Repositorio: terraform-modules  (format: generic)                 │
  │      └── Package: vpc-module                                           │
  │          └── Version: 1.0.0  (IMMUTABLE)                               │
  │              └── Asset: vpc-module-1.0.0.tar.gz  (SHA-256 verificado)  │
  └──────────────────────────────────────────────┬─────────────────────────┘
                                                  │
                                                  │ AWS Sig V4 (get-package-version-asset)
                                                  │ (credenciales ci-consumer)
                                                  ▼
  ┌──────────────────────────────────────────────────────────┐
  │  get-package-version-asset  →  /tmp/vpc-module/          │
  │                                                          │
  │  consumer/main.tf                                        │
  │  module "vpc" {                                          │
  │    source = "/tmp/vpc-module"   (ruta local extraída)    │
  │  }                                                       │
  │                                                          │
  │  terraform init  →  carga módulo desde ruta local        │
  └──────────────────────────────────────────────────────────┘

Gobernanza de acceso:
─────────────────────────────────────────────────────────────────────────────

  Capa 1 — IAM (identidad)
  ┌────────────────────────────────────────────────────────────────────────┐
  │  ci-publisher: GetAuthorizationToken, sts:GetServiceBearerToken        │
  │  ci-consumer:  GetAuthorizationToken, sts:GetServiceBearerToken        │
  │                                                                        │
  │  AMBOS necesitan el token antes de cualquier operacion de paquete.     │
  └────────────────────────────────────────────────────────────────────────┘

  Capa 2 — Recurso (politica del repositorio)
  ┌────────────────────────────────────────────────────────────────────────┐
  │  ci-publisher: PublishPackageVersion, PutPackageMetadata, Read*        │
  │  ci-consumer:  GetPackageVersionAsset, ReadFromRepository, List*       │
  │                                                                        │
  │  ci-consumer NO tiene PublishPackageVersion — solo lectura.            │
  └────────────────────────────────────────────────────────────────────────┘
```

## Conceptos clave

### Dominio, repositorio, paquete y asset

CodeArtifact organiza los artefactos en cuatro niveles:

| Nivel         | Descripción                                                       | Ejemplo                          |
|---------------|-------------------------------------------------------------------|----------------------------------|
| **Dominio**   | Contenedor de facturación y gobernanza. Una cuenta puede tener N. | `supply-chain`                   |
| **Repositorio** | Colección de paquetes de un formato dado dentro del dominio.    | `terraform-modules` (generic)    |
| **Paquete**   | Unidad lógica de código con nombre propio.                        | `vpc-module`                     |
| **Asset**     | Fichero binario adjunto a una versión específica del paquete.     | `vpc-module-1.0.0.tar.gz`        |

La URL de descarga de un asset en formato generic sigue este patrón:

```
https://<domain>-<account>.d.codeartifact.<region>.amazonaws.com
  /generic/<repo>/<namespace>/<package>/<version>/<asset>
```

### Formato Generic vs formatos nativos

CodeArtifact soporta formatos con protocolo propio (npm, PyPI, Maven, NuGet…)
y el formato **generic** para cualquier binario arbitrario. El formato generic:

- No impone estructura de metadatos.
- Acepta cualquier nombre de fichero como asset.
- Es el más adecuado para módulos Terraform, scripts, binarios compilados
  o cualquier artefacto que no encaje en los formatos gestionados.
- La inmutabilidad funciona igual: no se puede sobrescribir una versión publicada.

### Inmutabilidad semántica

Una vez ejecutado `publish-package-version` para `vpc-module@1.0.0`, intentar
publicar de nuevo la misma versión devuelve:

```
An error occurred (ConflictException) when calling the PublishPackageVersion
operation: Cannot update existing generic package version
'terraform/vpc-module/1.0.0' with status 'Published'. Only 'Unfinished'
package versions can be updated.
```

Esto es una garantía del servicio, no una política configurable: ningún usuario
(ni siquiera el administrador) puede sobrescribir un asset de una versión con
estado `Published`. Para corregir un bug hay que publicar `1.0.1`.

### Token de autorización

Todas las operaciones de lectura/escritura de paquetes requieren un token de
corta duración (máximo 12 horas) obtenido con:

```bash
aws codeartifact get-authorization-token \
  --domain <domain> \
  --domain-owner <account> \
  --query authorizationToken --output text
```

El token funciona como contraseña HTTP Basic (`login: aws`) para los
protocolos de package managers nativos que CodeArtifact implementa — npm,
PyPI, Maven, NuGet — que sí exponen endpoints HTTP convencionales.

Para **generic packages**, el endpoint de descarga es una API AWS que exige
**AWS Signature V4**, no Basic auth ni Bearer. La descarga se hace
exclusivamente con el comando `get-package-version-asset` de la AWS CLI,
que firma la petición automáticamente con las credenciales del caller:

```bash
aws codeartifact get-package-version-asset \
  --domain <domain> --domain-owner <account> \
  --repository <repo> --format generic \
  --namespace <namespace> --package <package> \
  --package-version <version> --asset <asset-name> \
  --region <region> \
  /ruta/local/destino.tar.gz
```

Esto implica que Terraform no puede descargar módulos empaquetados como
generic packages directamente desde la URL del repositorio. El patrón
recomendado es: descargar con la CLI → extraer → usar ruta local como
`source` del módulo.

### sts:GetServiceBearerToken

`codeartifact:GetAuthorizationToken` es una operación que internamente hace
que CodeArtifact llame a STS para emitir un bearer token de corta duración.
El usuario solicitante necesita tanto `codeartifact:GetAuthorizationToken`
sobre el ARN del dominio como `sts:GetServiceBearerToken` sobre `*` (con
condición `sts:AWSServiceName = codeartifact.amazonaws.com`). Sin el segundo
permiso, la operación falla con `AccessDeniedException` incluso aunque el
primero esté concedido.

### Separación publisher / consumer

| Operación                    | ci-publisher | ci-consumer |
|-----------------------------|:------------:|:-----------:|
| Obtener token de auth        |     ✓        |     ✓       |
| Descubrir endpoint del repo  |     ✓        |     ✓       |
| Listar paquetes              |     ✓        |     ✓       |
| Descargar asset de paquete   |     ✓        |     ✓       |
| Publicar nueva versión       |     ✓        |     ✗       |
| Modificar metadatos          |     ✓        |     ✗       |
| Eliminar versión             |     ✗        |     ✗       |

Eliminar versiones es deliberadamente imposible para ambos roles: solo el
administrador (cuenta root o usuario con `codeartifact:DeletePackageVersions`
explícito) puede hacerlo. Esto refuerza la auditoría.

## Estructura del proyecto

```
labs/lab42/
├── aws/              ── Infraestructura CodeArtifact + IAM (Terraform)
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf       ── KMS CMK, dominio, repositorio, politicas de recurso
│   ├── iam.tf        ── Usuarios, grupos, politicas de identidad
│   ├── outputs.tf    ── Endpoint, URLs, comandos de verificacion
│   └── aws.s3.tfbackend
│
├── module/
│   └── vpc/          ── Módulo VPC local que se empaqueta y publica
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── consumer/         ── Proyecto Terraform que consume el módulo desde CodeArtifact
│   ├── providers.tf
│   └── main.tf
│
└── README.md
```

---

## Paso 1 — Desplegar la infraestructura de CodeArtifact

```bash
cd labs/lab42/aws

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"
```

Revisa el plan — deben crearse 16 recursos con los valores por defecto:

```bash
terraform plan
```

```
  # aws_kms_key.codeartifact                                     will be created
  # aws_kms_alias.codeartifact                                   will be created
  # aws_codeartifact_domain.this                                 will be created
  # aws_codeartifact_domain_permissions_policy.this              will be created
  # aws_codeartifact_repository.this                             will be created
  # aws_codeartifact_repository_permissions_policy.this          will be created
  # aws_iam_user.publisher["ci-publisher"]                       will be created
  # aws_iam_user.consumer["ci-consumer"]                         will be created
  # aws_iam_group.publishers                                     will be created
  # aws_iam_group.consumers                                      will be created
  # aws_iam_user_group_membership.publisher["ci-publisher"]      will be created
  # aws_iam_user_group_membership.consumer["ci-consumer"]        will be created
  # aws_iam_policy.publisher_codeartifact                        will be created
  # aws_iam_policy.consumer_codeartifact                         will be created
  # aws_iam_group_policy_attachment.publisher_codeartifact       will be created
  # aws_iam_group_policy_attachment.consumer_codeartifact        will be created

  Plan: 16 to add, 0 to change, 0 to destroy.
```

```bash
terraform apply
```

Guarda los outputs para los pasos siguientes:

```bash
DOMAIN=$(terraform output -raw domain_name)
REPO=$(terraform output -raw repository_name)
ENDPOINT=$(terraform output -raw domain_endpoint)
REGISTRY_URL=$(terraform output -raw generic_registry_url)

echo "Dominio  : ${DOMAIN}"
echo "Endpoint : ${ENDPOINT}"
echo "Registry : ${REGISTRY_URL}"
```

Verifica que el dominio y el repositorio están activos:

```bash
terraform output verify_commands
```

---

## Paso 2 — Empaquetar el módulo VPC

El módulo VPC está en `labs/lab42/module/vpc/`. Hay que comprimirlo en un
archivo tar.gz que CodeArtifact almacenará como asset del paquete.

```bash
# Desde la raíz del repositorio
cd labs/lab42

# Empaquetar el contenido del módulo VPC (sin la ruta module/vpc/ como prefijo)
# -C module/vpc . → entra en el directorio y empaqueta todo su contenido
tar -czf vpc-module-1.0.0.tar.gz -C module/vpc .

# Verificar el contenido del archive
tar -tzf vpc-module-1.0.0.tar.gz
# Debe mostrar:
# ./
# ./main.tf
# ./variables.tf
# ./outputs.tf
```

Calcula el hash SHA-256 del archivo — CodeArtifact lo exige para verificar
la integridad del asset durante la publicación:

```bash
# Linux
SHA256=$(sha256sum vpc-module-1.0.0.tar.gz | cut -d' ' -f1)

# macOS
SHA256=$(shasum -a 256 vpc-module-1.0.0.tar.gz | cut -d' ' -f1)

echo "SHA-256: ${SHA256}"
```

---

## Paso 3 — Publicar el módulo en CodeArtifact

Este paso simula el pipeline de CI/CD que publica módulos. Se usa el usuario
`ci-publisher` con sus credenciales propias, no las credenciales de administrador.

### Preparar las credenciales de ci-publisher

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — directorio labs/lab42/aws

KEY_JSON=$(aws iam create-access-key --user-name ci-publisher)
echo "Access Key ID:     $(echo $KEY_JSON | jq -r '.AccessKey.AccessKeyId')"
echo "Secret Access Key: $(echo $KEY_JSON | jq -r '.AccessKey.SecretAccessKey')"
```

### 3a — Publicar con credenciales de ci-publisher

```bash
# ⚠️  NUEVA TERMINAL — credenciales de ci-publisher

export AWS_ACCESS_KEY_ID="<AccessKeyId del paso anterior>"
export AWS_SECRET_ACCESS_KEY="<SecretAccessKey del paso anterior>"
export AWS_DEFAULT_REGION="us-east-1"

# Verificar identidad
aws sts get-caller-identity --query 'Arn' --output text
# arn:aws:iam::<ACCOUNT_ID>:user/supply-chain/publishers/ci-publisher

# Copiar desde la terminal de administrador
export DOMAIN="<DOMAIN del Paso 1>"
export REPO="<REPO del Paso 1>"
export ACCOUNT_ID="<ACCOUNT_ID del Paso 1>"

# Calcular SHA-256 del archivo (en labs/lab42/)
cd labs/lab42
SHA256=$(sha256sum vpc-module-1.0.0.tar.gz | cut -d' ' -f1)
# macOS: SHA256=$(shasum -a 256 vpc-module-1.0.0.tar.gz | cut -d' ' -f1)

# Publicar el paquete
aws codeartifact publish-package-version \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO}" \
  --format generic \
  --namespace terraform \
  --package vpc-module \
  --package-version 1.0.0 \
  --asset-name vpc-module-1.0.0.tar.gz \
  --asset-content vpc-module-1.0.0.tar.gz \
  --asset-sha256 "${SHA256}" \
  --region us-east-1
```

Resultado esperado:

```json
{
    "format": "generic",
    "namespace": "terraform",
    "package": "vpc-module",
    "version": "1.0.0",
    "versionRevision": "...",
    "status": "Published",
    "assetName": "vpc-module-1.0.0.tar.gz"
}
```

El campo `"status": "Published"` confirma que la versión ya es inmutable.

### 3b — Verificar el paquete publicado

```bash
# ⚠️  TERMINAL DE ci-publisher

aws codeartifact describe-package-version \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO}" \
  --format generic \
  --namespace terraform \
  --package vpc-module \
  --package-version 1.0.0 \
  --region us-east-1 \
  --query "packageVersion.{version:version,estado:status,revision:revision}"
```

```bash
aws codeartifact list-package-version-assets \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO}" \
  --format generic \
  --namespace terraform \
  --package vpc-module \
  --package-version 1.0.0 \
  --region us-east-1
# Debe mostrar vpc-module-1.0.0.tar.gz con su tamaño y hashes
```

### 3c — Verificar la inmutabilidad (publicar la misma versión debe fallar)

```bash
# ⚠️  TERMINAL DE ci-publisher — intentar sobrescribir 1.0.0

aws codeartifact publish-package-version \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO}" \
  --format generic \
  --namespace terraform \
  --package vpc-module \
  --package-version 1.0.0 \
  --asset-name vpc-module-1.0.0.tar.gz \
  --asset-content vpc-module-1.0.0.tar.gz \
  --asset-sha256 "${SHA256}" \
  --region us-east-1
```

Resultado esperado:

```
An error occurred (ConflictException) when calling the PublishPackageVersion
operation: Cannot update existing generic package version
'terraform/vpc-module/1.0.0' with status 'Published'. Only 'Unfinished'
package versions can be updated.
```

La inmutabilidad es una garantía del servicio, no una política configurable.
Para una corrección habría que publicar `1.0.1`.

Cierra la terminal de ci-publisher.

---

## Paso 4 — Crear credenciales de ci-consumer y verificar descarga

Los generic packages de CodeArtifact se descargan exclusivamente mediante
la API AWS (`get-package-version-asset`), que firma las peticiones con
AWS Signature V4. No existe descarga directa por HTTP con token.

Este paso usa las credenciales de `ci-consumer` — el rol que tienen los
pipelines de despliegue y los desarrolladores para consumir módulos.

### Preparar las credenciales de ci-consumer

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — directorio labs/lab42/aws

KEY_JSON=$(aws iam create-access-key --user-name ci-consumer)
echo "Access Key ID:     $(echo $KEY_JSON | jq -r '.AccessKey.AccessKeyId')"
echo "Secret Access Key: $(echo $KEY_JSON | jq -r '.AccessKey.SecretAccessKey')"
```

### 4a — Verificar que ci-consumer puede descargar el asset

```bash
# ⚠️  NUEVA TERMINAL — credenciales de ci-consumer

export AWS_ACCESS_KEY_ID="<AccessKeyId del paso anterior>"
export AWS_SECRET_ACCESS_KEY="<SecretAccessKey del paso anterior>"
export AWS_DEFAULT_REGION="us-east-1"

# Copiar desde la terminal de administrador
export DOMAIN="<DOMAIN del Paso 1>"
export REPO="<REPO del Paso 1>"
export ACCOUNT_ID="<ACCOUNT_ID del Paso 1>"

# Verificar identidad
aws sts get-caller-identity --query 'Arn' --output text
# arn:aws:iam::<ACCOUNT_ID>:user/supply-chain/consumers/ci-consumer

# Descargar el asset con las credenciales AWS de ci-consumer
aws codeartifact get-package-version-asset \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO}" \
  --format generic \
  --namespace terraform \
  --package vpc-module \
  --package-version 1.0.0 \
  --asset vpc-module-1.0.0.tar.gz \
  --region us-east-1 \
  /tmp/vpc-module-descargado.tar.gz

# Verificar que el contenido es válido
tar -tzf /tmp/vpc-module-descargado.tar.gz
# Debe mostrar: ./main.tf, ./variables.tf, ./outputs.tf
```

---

## Paso 5 — Consumir el módulo desde Terraform

CodeArtifact generic packages no exponen los assets como endpoint HTTP de
descarga directa con Basic auth — esa autenticación solo aplica a los
protocolos de package managers nativos (npm, PyPI). Para generic, la
descarga se hace con `get-package-version-asset` y el módulo se sirve a
Terraform como ruta local usando el prefijo `file://`.

### 5a — Descargar y extraer el módulo

```bash
# ⚠️  TERMINAL DE ci-consumer — desde labs/lab42/

# Descargar el asset con las credenciales AWS de ci-consumer
aws codeartifact get-package-version-asset \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO:-terraform-modules}" \
  --format generic \
  --namespace terraform \
  --package vpc-module \
  --package-version 1.0.0 \
  --asset vpc-module-1.0.0.tar.gz \
  --region us-east-1 \
  /tmp/vpc-module-1.0.0.tar.gz

# Extraer en un directorio temporal
mkdir -p /tmp/vpc-module
tar -xzf /tmp/vpc-module-1.0.0.tar.gz -C /tmp/vpc-module

# Verificar el contenido extraído
ls /tmp/vpc-module/
# main.tf  outputs.tf  variables.tf
```

### 5b — Actualizar consumer/main.tf con la ruta local

```bash
# ⚠️  TERMINAL DE ci-consumer — desde labs/lab42/

# Linux
sed -i 's|CODEARTIFACT_MODULE_URL|/tmp/vpc-module|g' consumer/main.tf

# macOS
# sed -i '' 's|CODEARTIFACT_MODULE_URL|/tmp/vpc-module|g' consumer/main.tf
```

Verifica la sustitución:

```bash
grep 'source' consumer/main.tf
# source = "/tmp/vpc-module"
```

### 5c — Inicializar el proyecto consumidor

`ci-consumer` descargó el módulo. A partir de aquí el despliegue de
infraestructura corresponde al rol de administrador — `ci-consumer` solo
tiene permisos sobre CodeArtifact, no sobre EC2.

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — labs/lab42/consumer/
# (con las credenciales de administrador, no de ci-consumer)

cd labs/lab42/consumer
terraform init
```

Resultado esperado:

```
Initializing modules...
- vpc in /tmp/vpc-module

Initializing the backend...

Initializing provider plugins...
...

Terraform has been successfully initialized!
```

### 5d — Verificar que el módulo está enlazado localmente

```bash
ls .terraform/modules/vpc/
# main.tf  outputs.tf  variables.tf
```

Los ficheros `.tf` del módulo VPC provienen del tar.gz descargado desde
CodeArtifact y extraído localmente. Terraform los trata exactamente igual
que si estuvieran en un repositorio git o en el Terraform Registry.

### 5e — Planificar y aplicar

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — labs/lab42/consumer/

terraform plan
terraform apply
```

El plan mostrará la creación de los recursos del módulo VPC (aws_vpc,
aws_subnet, aws_internet_gateway, aws_route_table…). Aplica para confirmar
que el módulo descargado desde CodeArtifact funciona end-to-end.

Recuerda destruir los recursos al terminar:

```bash
terraform destroy
```

Cierra la terminal de ci-consumer.

---

## Paso 6 — Verificar que ci-consumer no puede publicar

La separación de roles debe ser real, no solo documental. Verifica que
`ci-consumer` recibe un `AccessDeniedException` al intentar publicar.

```bash
# ⚠️  TERMINAL DE ci-consumer (con sus credenciales activas)

# El CLI exige un fichero real para --asset-content
echo "test" > /tmp/test-asset.txt
SHA_TEST=$(sha256sum /tmp/test-asset.txt | cut -d' ' -f1)

aws codeartifact publish-package-version \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO:-terraform-modules}" \
  --format generic \
  --namespace terraform \
  --package vpc-module \
  --package-version 2.0.0-test \
  --asset-name test.txt \
  --asset-content /tmp/test-asset.txt \
  --asset-sha256 "${SHA_TEST}" \
  --region us-east-1
```

Resultado esperado:

```
An error occurred (AccessDeniedException) when calling the
PublishPackageVersion operation:
User: arn:aws:iam::<ACCOUNT_ID>:user/supply-chain/consumers/ci-consumer
is not authorized to perform: codeartifact:PublishPackageVersion on
resource: arn:aws:codeartifact:us-east-1:<ACCOUNT_ID>:package/
supply-chain/terraform-modules/generic/terraform/vpc-module
because no identity-based policy allows the
codeartifact:PublishPackageVersion action
```

La política de identidad del grupo `consumers` no incluye
`codeartifact:PublishPackageVersion` — la denegación se produce en la
capa de identidad (IAM), antes incluso de evaluar la política de recurso
del repositorio.

## Verificación final

```bash
# Verificar que el dominio y el repositorio existen
aws codeartifact list-domains --region ${REGION} \
  --query "domains[?name=='supply-chain'].{nombre:name,estado:status}"

aws codeartifact list-repositories-in-domain \
  --domain supply-chain --domain-owner ${ACCOUNT_ID} \
  --region ${REGION} \
  --query "repositories[*].{nombre:name,formato:format}"

# Verificar que el paquete fue publicado con estado Published
aws codeartifact describe-package-version \
  --domain supply-chain --domain-owner ${ACCOUNT_ID} \
  --repository terraform-modules --format generic \
  --namespace terraform --package vpc-module \
  --package-version 1.0.0 --region ${REGION} \
  --query "packageVersion.{version:version,estado:status}"

# Verificar que ci-consumer NO tiene PublishPackageVersion
aws iam simulate-principal-policy \
  --policy-source-arn $(aws iam get-user --user-name ci-consumer \
      --query 'User.Arn' --output text) \
  --action-names codeartifact:PublishPackageVersion \
  --resource-arns "*" \
  --query 'EvaluationResults[0].EvalDecision' --output text
# Esperado: implicitDeny

# Verificar la CMK del dominio
aws kms describe-key \
  --key-id alias/lab42-codeartifact --region ${REGION} \
  --query "KeyMetadata.{estado:KeyState,rotacion:KeyRotationStatus}"
```

---

## Retos

### Reto 1 — Publicar una segunda versión con cambios y verificar el pinning

El módulo VPC v1.0.0 no incluye NAT Gateway. Extiéndelo con soporte opcional
de NAT Gateway por AZ y publica como `1.1.0`.

**Pasos**:

1. Añade la variable `enable_nat_gateway` (bool, default `false`) al módulo.
2. Crea un EIP y un NAT Gateway por cada subred pública (uno por AZ).
3. Cambia las tablas de rutas privadas a una por AZ, cada una con ruta `0.0.0.0/0` hacia el NAT Gateway de su zona.
4. Publica la nueva versión como `1.1.0` con credenciales de ci-publisher.
5. Verifica que el consumer, sin cambios, sigue usando `1.0.0`.
6. Descarga `1.1.0` con ci-consumer, actualiza el source en `consumer/main.tf` y ejecuta `terraform init` con credenciales de administrador.
7. Aplica con `enable_nat_gateway = true` y confirma que se crean los NAT Gateways. No destruyas — el VPC es necesario para el Reto 3.

---

### Reto 2 — Añadir un repositorio upstream para dependencias públicas

Crea un proxy npm cacheado dentro del dominio y verifica que los paquetes
se descargan desde CodeArtifact en lugar de desde internet directamente.

**Pasos**:

1. Añade en `aws/main.tf` un repositorio `npm-public` con `external_connections` apuntando a `public:npmjs`, y un repositorio `npm-internal` con upstream hacia `npm-public`.
2. Aplica con `terraform apply`.
3. Configura npm con el endpoint y el token de autorización del repositorio `npm-internal`.
4. Instala cualquier paquete npm y verifica con `list-packages` que aparece cacheado en CodeArtifact.
5. Restaura la configuración de npm al terminar.

---

### Reto 3 — Política de dominio que bloquea el acceso desde fuera de la VPC

Restringe el acceso al dominio CodeArtifact para que solo sea posible desde
dentro de la VPC corporativa a través de VPC endpoints de tipo Interface.

**Requisito previo**: el VPC desplegado en el Reto 1 con el módulo `vpc-module@1.1.0`.

**Pasos**:

1. Añade las variables `vpc_id` y `private_subnet_ids` a `aws/variables.tf`.
2. Crea en `aws/main.tf` dos VPC endpoints de tipo Interface: uno para `codeartifact.api` y otro para `codeartifact.repositories`, con un Security Group que permita HTTPS (443) desde el CIDR del VPC.
3. Añade un `statement` Deny en `data.aws_iam_policy_document.domain_permissions` con condición `StringNotEquals` sobre `aws:SourceVpce` apuntando al endpoint de `codeartifact.repositories`. Añade una segunda condición `ArnNotLike` sobre `aws:PrincipalArn` usando `data.aws_caller_identity.current.arn` para excluir al usuario IAM administrador del Deny — de lo contrario `terraform destroy` falla desde fuera de la VPC.
4. Aplica con `terraform apply` pasando el VPC ID y las subredes privadas obtenidos de los outputs del Reto 1.
5. Verifica que desde tu terminal local (fuera de la VPC) el acceso falla con `AccessDeniedException: explicit deny`.
6. Lanza una instancia EC2 en la subred privada del Reto 1, accede por SSM y confirma que desde dentro de la VPC el acceso funciona correctamente.

---

## Soluciones

<details>
<summary>Reto 1 — Versión 1.1.0 con NAT Gateway por AZ</summary>

**`module/vpc/variables.tf`** — añadir:

```hcl
variable "enable_nat_gateway" {
  type        = bool
  description = "Crear un NAT Gateway por zona de disponibilidad para alta disponibilidad."
  default     = false
}
```

**`module/vpc/main.tf`** — EIP y NAT Gateway indexados por subred pública:

```hcl
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? length(var.public_subnet_cidrs) : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? length(var.public_subnet_cidrs) : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags       = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
  depends_on = [aws_internet_gateway.this]
}
```

**Tablas de rutas privadas** — reemplaza el recurso `aws_route_table.private`
(tabla única sin count) y su asociación por versiones indexadas por AZ:

```hcl
resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[count.index].id
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-private-rt-${count.index}" })
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```

**`module/vpc/outputs.tf`** — reemplazar `private_route_table_id` por lista:

```hcl
output "private_route_table_ids" {
  description = "IDs de las tablas de rutas privadas (una por AZ)."
  value       = aws_route_table.private[*].id
}
```

**Publicar v1.1.0**:

```bash
# ⚠️  TERMINAL DE ci-publisher — labs/lab42/
tar -czf vpc-module-1.1.0.tar.gz -C module/vpc .
SHA256=$(sha256sum vpc-module-1.1.0.tar.gz | cut -d' ' -f1)

aws codeartifact publish-package-version \
  --domain "${DOMAIN}" --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO}" --format generic \
  --namespace terraform \
  --package vpc-module --package-version 1.1.0 \
  --asset-name vpc-module-1.1.0.tar.gz \
  --asset-content vpc-module-1.1.0.tar.gz \
  --asset-sha256 "${SHA256}" \
  --region us-east-1
```

**Verificar pinning** — ci-consumer descarga los assets; el admin ejecuta Terraform:

```bash
# ⚠️  TERMINAL DE ci-consumer — descarga de assets

# v1.0.0 ya está en /tmp/vpc-module (del Paso 5) — no hay nada que cambiar

# Descargar y extraer v1.1.0 en un directorio separado
aws codeartifact get-package-version-asset \
  --domain "${DOMAIN}" --domain-owner "${ACCOUNT_ID}" \
  --repository "${REPO}" --format generic \
  --namespace terraform --package vpc-module \
  --package-version 1.1.0 --asset vpc-module-1.1.0.tar.gz \
  --region us-east-1 /tmp/vpc-module-1.1.0.tar.gz
mkdir -p /tmp/vpc-module-v110 && tar -xzf /tmp/vpc-module-1.1.0.tar.gz -C /tmp/vpc-module-v110
```

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — labs/lab42/consumer/

# Sin cambiar consumer/main.tf (apunta a /tmp/vpc-module = v1.0.0)
terraform init
# - vpc in /tmp/vpc-module  ← sigue siendo v1.0.0

# Actualizar source a v1.1.0
sed -i 's|/tmp/vpc-module$|/tmp/vpc-module-v110|g' main.tf
terraform init
# - vpc in /tmp/vpc-module-v110  ← ahora v1.1.0

# Añadir enable_nat_gateway = true en consumer/main.tf.
# Necesario para que las subredes privadas tengan salida a internet —
# la instancia del Reto 3 lo necesita para resolver el endpoint de
# CodeArtifact a través del VPC endpoint.
# Edita consumer/main.tf y añade dentro del bloque module "vpc":
#
#   enable_nat_gateway = true
#
# El plan mostrará los nuevos recursos:
# + aws_eip.nat[0], aws_eip.nat[1]
# + aws_nat_gateway.this[0], aws_nat_gateway.this[1]
# + aws_route_table.private[0], aws_route_table.private[1]

terraform apply
# No destruyas — el VPC y los NAT Gateways son necesarios para el Reto 3.
```

</details>

<details>
<summary>Reto 2 — Repositorio upstream npm</summary>

**Añadir a `aws/main.tf`**:

```hcl
# Repositorio proxy que se conecta a npmjs público.
# external_connections acepta un único origen por repositorio.
resource "aws_codeartifact_repository" "npm_upstream" {
  repository  = "npm-public"
  domain      = aws_codeartifact_domain.this.domain
  description = "Proxy cacheado de npm public."

  external_connections {
    external_connection_name = "public:npmjs"
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# Repositorio interno que delega a npm-public cuando un paquete
# no está cacheado todavía. Los consumers usan este repositorio,
# nunca el upstream directamente.
resource "aws_codeartifact_repository" "npm_internal" {
  repository  = "npm-internal"
  domain      = aws_codeartifact_domain.this.domain
  description = "Registro npm interno con upstream hacia npm-public."

  upstream {
    repository_name = aws_codeartifact_repository.npm_upstream.repository
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
```

**Aplicar**:

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — labs/lab42/aws/
terraform apply
```

Plan esperado:

```
# aws_codeartifact_repository.npm_upstream   will be created
# aws_codeartifact_repository.npm_internal   will be created

Plan: 2 to add, 0 to change, 0 to destroy.
```

**Obtener el endpoint y el token de autorización**:

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — labs/lab42/aws/

DOMAIN=$(terraform output -raw domain_name)
ACCOUNT_ID=$(terraform output -raw domain_owner)

ENDPOINT_NPM=$(aws codeartifact get-repository-endpoint \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository npm-internal \
  --format npm \
  --query repositoryEndpoint \
  --output text \
  --region us-east-1)

TOKEN=$(aws codeartifact get-authorization-token \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --query authorizationToken \
  --output text \
  --region us-east-1)

echo "Endpoint npm: ${ENDPOINT_NPM}"
```

**Configurar npm para usar el repositorio interno**:

```bash
# npm usa Bearer token, no AWS Sig V4 — el token de CodeArtifact
# se inyecta como _authToken en la configuración por host.
npm config set registry "${ENDPOINT_NPM}"
npm config set //${ENDPOINT_NPM##https://}:_authToken "${TOKEN}"

# Verificar
npm config get registry
# https://supply-chain-<ACCOUNT>.d.codeartifact.us-east-1.amazonaws.com/npm/npm-internal/
```

**Instalar un paquete y verificar el cacheo**:

```bash
mkdir /tmp/npm-test && cd /tmp/npm-test
npm install lodash

# lodash se descargó desde npmjs a través de npm-public y quedó
# cacheado en npm-internal. Verificar:
aws codeartifact list-packages \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository npm-internal \
  --format npm \
  --region us-east-1 \
  --query "packages[?package=='lodash']"
# Debe mostrar lodash con su versión instalada
```

**Restaurar la configuración de npm**:

```bash
npm config delete registry
npm config delete //${ENDPOINT_NPM##https://}:_authToken

# Verificar que npm vuelve a usar el registry público
npm config get registry
# https://registry.npmjs.org/
```

**Destruir los repositorios npm al terminar**:

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — labs/lab42/aws/
terraform destroy -target=aws_codeartifact_repository.npm_internal \
                  -target=aws_codeartifact_repository.npm_upstream
```

</details>

<details>
<summary>Reto 3 — Política de dominio con restricción por VPC endpoint</summary>

**Añadir variables en `aws/variables.tf`**:

```hcl
variable "vpc_id" {
  type        = string
  description = "ID del VPC donde se crean los VPC endpoints de CodeArtifact."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "IDs de las subredes privadas donde se despliegan las ENIs de los VPC endpoints."
}
```

**Añadir en `aws/main.tf`** el data source del VPC, el Security Group y los dos endpoints:

```hcl
data "aws_vpc" "selected" {
  id = var.vpc_id
}

# Security Group para las ENIs de los VPC endpoints.
# Solo permite HTTPS entrante desde el CIDR del VPC — las llamadas
# a la API de CodeArtifact siempre van por el puerto 443.
resource "aws_security_group" "vpce" {
  name        = "${var.project}-vpce-sg"
  description = "Permite HTTPS desde el CIDR del VPC hacia los endpoints de CodeArtifact."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS desde el VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = var.project, ManagedBy = "terraform" }
}

# Endpoint para la API de control (GetAuthorizationToken, DescribeDomain…).
# Necesita private_dns_enabled = true para que el hostname
# codeartifact.<region>.amazonaws.com resuelva a la ENI privada.
resource "aws_vpc_endpoint" "codeartifact_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.codeartifact.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Project = var.project, ManagedBy = "terraform", Purpose = "codeartifact-api" }
}

# Endpoint para las operaciones de paquetes (PublishPackageVersion,
# GetPackageVersionAsset, ListPackages…).
# Es el endpoint cuyo ID se usa en la condición aws:SourceVpce.
resource "aws_vpc_endpoint" "codeartifact_repositories" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.codeartifact.repositories"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Project = var.project, ManagedBy = "terraform", Purpose = "codeartifact-repositories" }
}
```

**Añadir el Deny en `data.aws_iam_policy_document.domain_permissions`** (en `aws/main.tf`):

```hcl
# Este statement se evalúa ANTES que los Allow. Un Deny explícito
# con StringNotEquals sobre aws:SourceVpce bloquea cualquier petición
# que no llegue a través del endpoint de repositorios — incluso si el
# caller tiene permisos de identidad válidos.
#
# aws:SourceVpce solo está presente en peticiones que atraviesan un
# VPC endpoint Interface. Las peticiones desde internet no incluyen
# esta clave, por lo que StringNotEquals evalúa como true y el Deny
# se aplica.
#
# La segunda condición ArnNotLike excluye al usuario IAM administrador
# (el que ejecutó terraform apply) del Deny. En IAM, múltiples conditions
# en un mismo statement se evalúan con AND: el Deny solo se aplica cuando
# AMBAS son verdaderas. Sin esta excepción, terraform destroy fallaría
# porque el administrador también quedaría bloqueado fuera de la VPC.
# data.aws_caller_identity.current.arn resuelve al ARN exacto del
# usuario que ejecuta Terraform — no a la cuenta root.
statement {
  sid    = "DenyAccessOutsideVPCEndpoint"
  effect = "Deny"

  principals {
    type        = "AWS"
    identifiers = ["*"]
  }

  actions   = ["codeartifact:*"]
  resources = ["*"]

  condition {
    test     = "StringNotEquals"
    variable = "aws:SourceVpce"
    values   = [aws_vpc_endpoint.codeartifact_repositories.id]
  }

  condition {
    test     = "ArnNotLike"
    variable = "aws:PrincipalArn"
    values   = [data.aws_caller_identity.current.arn]
  }
}
```

**Aplicar**:

```bash
# ⚠️  TERMINAL DE ADMINISTRADOR — labs/lab42/consumer/

# Obtener el VPC ID y las subredes privadas de los outputs del Reto 1
VPC_ID=$(terraform output -raw vpc_id)
SUBNET_IDS=$(terraform output -json private_subnet_ids)

cd ../aws

terraform apply \
  -var="vpc_id=${VPC_ID}" \
  -var="private_subnet_ids=${SUBNET_IDS}"
```

Plan esperado (además de los recursos existentes):

```
# aws_security_group.vpce                          will be created
# aws_vpc_endpoint.codeartifact_api                will be created
# aws_vpc_endpoint.codeartifact_repositories       will be created
# aws_codeartifact_domain_permissions_policy.this  will be updated

Plan: 3 to add, 1 to change, 0 to destroy.
```

**Verificar bloqueo desde fuera de la VPC**:

```bash
# ⚠️  TERMINAL LOCAL (fuera del VPC del Reto 1) — debe fallar

DOMAIN=$(cd labs/lab42/aws && terraform output -raw domain_name)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws codeartifact list-packages \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository terraform-modules \
  --format generic \
  --region us-east-1
```

Resultado esperado:

```
An error occurred (AccessDeniedException) when calling the ListPackages
operation: User: arn:aws:iam::<ACCOUNT_ID>:user/supply-chain/consumers/ci-consumer
is not authorized to perform: codeartifact:ListPackages on resource:
arn:aws:codeartifact:us-east-1:<ACCOUNT_ID>:repository/supply-chain/terraform-modules
with an explicit deny in a resource-based policy
```

**Verificar acceso desde dentro de la VPC**:

```bash
# Lanzar una instancia EC2 Amazon Linux 2023 en una subred privada
# del VPC del Reto 1, con un Instance Profile que tenga permisos
# de administrador. Acceder via SSM Session Manager.

SUBNET_ID=$(cd labs/lab42/consumer && terraform output -json private_subnet_ids | jq -r '.[0]')

# Crear la instancia (Amazon Linux 2023, t3.micro)
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
    --query Parameter.Value --output text --region us-east-1) \
  --instance-type t4g.small \
  --subnet-id "${SUBNET_ID}" \
  --iam-instance-profile Name=AmazonSSMRoleForInstancesQuickSetup \
  --no-associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=lab42-vpce-test}]' \
  --region us-east-1 \
  --query 'Instances[0].InstanceId' --output text)

echo "Instance ID: ${INSTANCE_ID}"

# Esperar a que la instancia esté disponible para SSM (~60 segundos)
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region us-east-1

aws ssm start-session --target "${INSTANCE_ID}" --region us-east-1

# Dentro de la instancia EC2:
DOMAIN="supply-chain"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws codeartifact list-packages \
  --domain "${DOMAIN}" \
  --domain-owner "${ACCOUNT_ID}" \
  --repository terraform-modules \
  --format generic \
  --region us-east-1
# Debe listar los paquetes correctamente — la petición llega
# a través del VPC endpoint y la condición aws:SourceVpce coincide.
```


</details>

---

## Limpieza

Terraform no puede eliminar usuarios IAM que tengan access keys activas.
Hay que borrarlas antes de ejecutar `destroy`.

```bash
# Si se realizó el Reto 3, terminar la instancia EC2 antes de destruir
# el VPC — de lo contrario terraform destroy falla al intentar eliminar
# las subredes con ENIs activas.
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=lab42-vpce-test" \
            "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --region us-east-1)

if [ "${INSTANCE_ID}" != "None" ] && [ -n "${INSTANCE_ID}" ]; then
  aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region us-east-1
  aws ec2 wait instance-terminated --instance-ids "${INSTANCE_ID}" --region us-east-1
  echo "Instancia ${INSTANCE_ID} terminada"
fi
```

```bash
cd labs/lab42/aws

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"

# Eliminar todas las access keys de los usuarios creados en el lab
for USER in ci-publisher ci-consumer; do
  for KEY_ID in $(aws iam list-access-keys --user-name "${USER}" \
      --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "${USER}" --access-key-id "${KEY_ID}"
    echo "Clave ${KEY_ID} eliminada de ${USER}"
  done
done

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

# Si se realizó el Reto 3, obtener el VPC ID y subredes privadas para
# que Terraform pueda destruir los VPC endpoints y el Security Group.
# Si no se realizó el Reto 3, ejecutar terraform destroy sin -var.
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=lab42-consumer" \
  --query "Vpcs[0].VpcId" --output text --region us-east-1 2>/dev/null)

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=tag:Tier,Values=private" \
  --query "Subnets[*].SubnetId" --output json --region us-east-1 2>/dev/null)

if [ -n "${VPC_ID}" ] && [ "${VPC_ID}" != "None" ]; then
  terraform destroy \
    -var="vpc_id=${VPC_ID}" \
    -var="private_subnet_ids=${SUBNET_IDS}"
else
  terraform destroy
fi
```

> **ADVERTENCIA**: `terraform destroy` elimina el dominio CodeArtifact y
> **todos los paquetes** publicados en él. Si publicaste módulos que otros
> equipos consumen, avisa antes de destruir.

Limpieza de ficheros locales y del consumer:

```bash
# Destruir la infraestructura del consumer (VPC, subredes, NAT Gateways…).
# El módulo debe estar disponible en /tmp/vpc-module o /tmp/vpc-module-v110
# para que Terraform pueda leer el estado — destruye ANTES de eliminar los
# directorios de /tmp.
cd ../consumer
terraform destroy
cd ..

# Eliminar el estado y los ficheros generados por terraform init del consumer
rm -rf consumer/.terraform consumer/.terraform.lock.hcl consumer/terraform.tfstate*

# Restaurar consumer/main.tf al placeholder original
sed -i 's|/tmp/vpc-module.*|CODEARTIFACT_MODULE_URL|g' consumer/main.tf
# macOS: sed -i '' 's|/tmp/vpc-module.*|CODEARTIFACT_MODULE_URL|g' consumer/main.tf

# Eliminar archivos de paquetes locales y módulos extraídos en /tmp
rm -f vpc-module-*.tar.gz
rm -rf /tmp/vpc-module /tmp/vpc-module-v110 /tmp/vpc-module-*.tar.gz /tmp/vpc-module-descargado.tar.gz
```

---

## Buenas prácticas aplicadas

- **CMK propia en lugar de la clave por defecto**: cifrar el dominio CodeArtifact
  con una CMK gestionada por Terraform permite auditar el uso de la clave en
  CloudTrail, rotar automáticamente y revocar acceso de forma independiente al
  servicio. La clave `aws/codeartifact` no ofrece este nivel de control.

- **Separación publisher / consumer en capas**: los permisos se definen en dos
  capas ortogonales — identidad (política IAM del grupo) y recurso (política del
  repositorio). Si una capa falla en denegar, la otra actúa como red de seguridad.
  `ci-consumer` no puede publicar aunque alguien modificara la política del repositorio.

- **Inmutabilidad semántica de versiones**: CodeArtifact impide sobrescribir una
  versión con estado `Published`. Publicar `1.0.1` en lugar de corregir `1.0.0`
  garantiza que los pipelines que pinearon `1.0.0` nunca reciben código diferente.

- **SHA-256 en la publicación**: `publish-package-version --asset-sha256` verifica
  que el asset no fue alterado en tránsito. CodeArtifact rechaza publicaciones cuyo
  hash no coincide con el asset recibido.

- **Grupos IAM en lugar de políticas de usuario**: la política de permisos se
  adjunta al grupo, no al usuario. Añadir un nuevo pipeline de CI/CD sólo requiere
  crear un usuario y añadirlo al grupo — sin tocar las políticas.

- **`get-package-version-asset` en lugar de descarga HTTP directa**: los generic
  packages no exponen endpoints HTTP con autenticación Basic. Forzar el uso de la
  CLI con AWS Sig V4 garantiza que cada descarga queda registrada en CloudTrail
  con la identidad del caller.

## Recursos

- [AWS CodeArtifact — What is CodeArtifact?](https://docs.aws.amazon.com/codeartifact/latest/ug/welcome.html)
- [AWS CodeArtifact — Generic packages](https://docs.aws.amazon.com/codeartifact/latest/ug/generic-packages-overview.html)
- [AWS CodeArtifact — Tokens and authentication](https://docs.aws.amazon.com/codeartifact/latest/ug/tokens-authentication.html)
- [AWS CodeArtifact — Package version immutability](https://docs.aws.amazon.com/codeartifact/latest/ug/)
- [Terraform — Resource: aws_codeartifact_domain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codeartifact_domain)
- [Terraform — Resource: aws_codeartifact_repository](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codeartifact_repository)
- [Terraform — Resource: aws_codeartifact_repository_permissions_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codeartifact_repository_permissions_policy)
- [AWS KMS — Customer managed keys](https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#customer-cmk)
- [IAM — Policy evaluation logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)
