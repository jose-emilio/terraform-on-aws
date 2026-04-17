# Sección 6 — LocalStack: Alternativa local a AWS

> [← Sección anterior](./05_proyectos_terraform_aws.md) | [← Volver al índice](./README.md)

---

## 6.1 ¿Qué es LocalStack?

Cada vez que ejecutas `terraform apply` contra AWS real, ocurren dos cosas: se consumen recursos de tu cuenta (con su coste asociado) y existe el riesgo de crear infraestructura incorrecta que puede tardar minutos en desplegarse antes de descubrir que hay un error. Para flujos de aprendizaje, desarrollo y CI/CD, esto es ineficiente y caro.

**LocalStack** resuelve exactamente este problema. Es un emulador de servicios de AWS que se ejecuta en un **contenedor Docker local**, permitiendo desarrollar y probar infraestructura sin conexión a internet y sin coste alguno. No es una copia del código fuente de Amazon — es una implementación independiente de las mismas APIs que responde de forma idéntica a las herramientas oficiales.

```
# Flujo tradicional (con costes y riesgos)
Terraform → AWS Real → $$$ Factura + posibles recursos huérfanos

# Flujo con LocalStack (GRATIS y sin riesgo)
Terraform → LocalStack → Docker local
```

Los mismos comandos de Terraform, la misma sintaxis HCL. **Cero coste, cero riesgo.**

### Ventajas clave

| Ventaja | Descripción |
|---------|-------------|
| **Sin costes accidentales** | Los recursos solo existen en tu máquina local — no generan factura |
| **Sin conexión a internet** | Funciona en entornos aislados, VPNs restrictivas o incluso en un avión |
| **Feedback instantáneo** | Sin latencia de red real — el ciclo de iteración es mucho más rápido |
| **Ideal para CI/CD** | Prueba tu infraestructura en cada commit sin gastar ni un céntimo |

---

## 6.2 Arquitectura: El Edge Proxy

El diseño técnico central de LocalStack es su **Edge Proxy**. Las versiones antiguas (< 0.11.5) exponían cada servicio en un puerto distinto, lo que generaba una configuración compleja y frágil. A partir de LocalStack v2, todo se centraliza en un **único puerto: el 4566**.

```
  Terraform / AWS CLI
         |
         ▼
  localhost:4566   ← Edge Proxy — punto de entrada único para todos los servicios
     /      |       \       \
   S3     IAM     Lambda   DynamoDB  ...
```

El Edge Proxy identifica el servicio destino de cada petición basándose en la cabecera `Host` de la solicitud HTTP o en la ruta de la URL, y la redirige internamente al microservicio correspondiente. Desde el punto de vista de Terraform y el AWS CLI, es completamente transparente: hablan exactamente con las mismas URLs que usarían con AWS real.

---

## 6.3 Instalación y Requisitos

### Requisitos previos

LocalStack se ejecuta dentro de Docker, por lo que es el único requisito previo:

```bash
# Verificar que Docker está instalado y en ejecución
docker --version
docker compose version
```

### Instalar y arrancar LocalStack

```bash
# 1. Instalar el CLI de LocalStack (gestor del contenedor)
pip install localstack

# 2. Iniciar LocalStack en segundo plano (-d = detached)
localstack start -d

# 3. Verificar el estado de los servicios disponibles
localstack status services
```

Una vez iniciado, LocalStack está escuchando en `http://localhost:4566` y todos los servicios soportados están disponibles inmediatamente.

### Verificación del servicio

```bash
# Comprobar que el Edge Proxy responde correctamente
curl http://localhost:4566/_localstack/health | python3 -m json.tool
```

---

## 6.4 Planes de licencia

LocalStack ofrece cuatro planes. El plan **Hobby** es gratuito pero solo para uso no comercial. Los demás son de pago y añaden servicios y capacidades de forma progresiva.

| Servicio / Característica | Hobby (Gratis) | Base | Ultimate | Enterprise |
|---------------------------|:--------------:|:----:|:--------:|:----------:|
| S3, Lambda, EC2 | ✅ | ✅ | ✅ | ✅ |
| DynamoDB, SQS, SNS, SWF | ✅ | ✅ | ✅ | ✅ |
| IAM, KMS, STS, ACM, Secrets Manager | ✅ | ✅ | ✅ | ✅ |
| Step Functions, EventBridge, Kinesis, OpenSearch | ✅ | ✅ | ✅ | ✅ |
| RDS, ElastiCache, ECR, ECS, Cognito, Amazon MQ | ❌ | ✅ | ✅ | ✅ |
| EKS, EFS, Athena, Glue, DocumentDB, MemoryDB | ❌ | ❌ | ✅ | ✅ |
| Persistencia de estado local | ❌ | ✅ | ✅ | ✅ |
| Cloud Pods (guardar estados entre sesiones) | ❌ | 300 MB | 3 GB | 5 GB/usuario |
| IAM Policy Enforcement | ❌ | ✅ | ✅ | ✅ |
| Kubernetes Operator / SSO / SCIM | ❌ | ❌ | ❌ | ✅ |

> **Para Terraform básico y CI/CD estándar, el plan Hobby es suficiente**, aunque está limitado a uso no comercial. La cobertura de servicios evoluciona con cada release: consulta siempre la [documentación oficial de licencias](https://docs.localstack.cloud/aws/licensing/) para saber exactamente qué está soportado en tu versión.

---

## 6.5 Acceso mediante AWS CLI: `awslocal`

### Con el AWS CLI estándar

El AWS CLI oficial funciona perfectamente con LocalStack usando el flag `--endpoint-url` para redirigir las llamadas:

```bash
# Listar buckets S3 en LocalStack
aws --endpoint-url=http://localhost:4566 s3 ls

# Crear un bucket
aws --endpoint-url=http://localhost:4566 s3 mb s3://mi-bucket
```

### Con `awslocal` (la forma recomendada)

Escribir `--endpoint-url=http://localhost:4566` en cada comando es tedioso y propenso a errores. `awslocal` es un wrapper que apunta automáticamente a LocalStack. Misma sintaxis exacta que el AWS CLI real, sin ningún parámetro adicional.

```bash
# Instalar awslocal
pip install awscli-local

# Uso idéntico al AWS CLI real — awslocal reemplaza a aws
awslocal s3 ls
awslocal s3 mb s3://mi-bucket
awslocal lambda list-functions
awslocal dynamodb list-tables
```

> `awslocal` es simplemente un alias que añade `--endpoint-url=http://localhost:4566` automáticamente a cada llamada. Si algo funciona con `awslocal`, funcionará con el AWS CLI apuntando a LocalStack.

---

## 6.6 Acceso mediante Terraform: Bloque `endpoints`

Para que Terraform dirija sus llamadas a LocalStack en lugar de AWS real, se necesita configurar el bloque `provider` con las URLs locales. Cada servicio se mapea manualmente a la dirección del Edge Proxy:

```hcl
provider "aws" {
  region     = "us-east-1"
  access_key = "test"          # Valor ficticio — LocalStack no valida credenciales
  secret_key = "test"          # Valor ficticio

  endpoints {
    s3       = "http://localhost:4566"
    iam      = "http://localhost:4566"
    lambda   = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
    sqs      = "http://localhost:4566"
    sns      = "http://localhost:4566"
  }
}
```

Todos los servicios apuntan al mismo puerto `4566` — el Edge Proxy se encarga de redirigir cada petición al servicio correcto.

---

## 6.7 Parámetros de compatibilidad

Además de los endpoints, se necesitan algunos parámetros adicionales para evitar errores de compatibilidad con las validaciones del provider de AWS:

```hcl
provider "aws" {
  region     = "us-east-1"
  access_key = "test"
  secret_key = "test"

  endpoints {
    s3 = "http://localhost:4566"
    # ... resto de servicios
  }

  # Parámetros necesarios solo para desarrollo con LocalStack
  s3_use_path_style           = true   # LocalStack no soporta resolución DNS por subdominio
  skip_credentials_validation = true   # Las claves "test/test" no son válidas en AWS real
  skip_metadata_api_check     = true   # No hay servicio de metadatos EC2 en local
  skip_requesting_account_id  = true   # LocalStack no tiene un account ID real de AWS
}
```

### ¿Por qué estos parámetros?

| Parámetro | Razón |
|-----------|-------|
| `s3_use_path_style` | LocalStack no soporta resolución DNS por subdominio (`mi-bucket.localhost`). Usa path-style: `localhost/mi-bucket` |
| `skip_credentials_validation` | Las claves `test/test` no pasarían la validación contra AWS STS real |
| `skip_metadata_api_check` | No hay servicio de metadatos EC2 (IMDS) en el entorno local |
| `skip_requesting_account_id` | LocalStack no tiene un account ID real de AWS que consultar |

> ⚠️ **Importante:** Estas opciones son **SOLO** para desarrollo local. Usa variables de entorno o archivos `tfvars` separados para cada entorno, de forma que nunca lleguen a producción.

---

## 6.8 Integración con VS Code: Extensión oficial

Busca `LocalStack` en el marketplace de VS Code. La extensión oficial proporciona una interfaz visual completa para explorar los recursos creados en LocalStack sin necesidad de abrir la terminal.

| Funcionalidad | Descripción |
|---------------|-------------|
| **Explorar Recursos** | Navega buckets S3, tablas DynamoDB y funciones Lambda desde el panel lateral del IDE |
| **Logs en Tiempo Real** | Visualiza la salida de funciones Lambda directamente en VS Code para depuración rápida |
| **Flujo Integrado** | Edita código, aplica con Terraform y verifica resultados sin salir del editor |

El resultado es un flujo de desarrollo completamente integrado: escribir HCL → `terraform apply` → ver el recurso en el panel de LocalStack → depurar, todo sin abandonar VS Code.

---

## 6.9 Persistencia con Docker Compose

Por defecto, los recursos de LocalStack **desaparecen al reiniciar** el contenedor. Para proyectos de mayor duración donde necesitas mantener el estado entre sesiones de trabajo, usa Docker Compose con la variable `PERSISTENCE`:

```yaml
# docker-compose.yml
services:
  localstack:
    image: localstack/localstack:latest
    ports:
      - "4566:4566"
    environment:
      - PERSISTENCE=1               # Mantener datos entre reinicios del contenedor
      - DEFAULT_REGION=us-east-1
    volumes:
      - "./data:/var/lib/localstack"             # Datos persistentes
      - "./init:/docker-entrypoint-initaws.d"    # Scripts de inicialización automática
      - "/var/run/docker.sock:/var/run/docker.sock"
```

```bash
# Iniciar con persistencia activada
docker compose up -d

# Detener sin perder los datos creados
docker compose stop

# Destruir todo, incluyendo los datos almacenados
docker compose down -v
```

Los scripts en el directorio `./init/` se ejecutan automáticamente al arrancar LocalStack, permitiendo pre-crear recursos (buckets, tablas, colas) como parte de la inicialización del entorno de desarrollo.

---

## 6.10 Servicios disponibles y limitaciones

### Servicios incluidos en el plan Hobby (gratuito)

Organizados por categoría, estos son los servicios disponibles sin coste:

| Categoría | Servicios |
|-----------|-----------|
| **Almacenamiento** | S3, S3 Control |
| **Cómputo** | Lambda, EC2 |
| **Bases de datos** | DynamoDB, DynamoDB Streams |
| **Mensajería** | SQS, SNS, SWF, Step Functions, EventBridge, EventBridge Scheduler |
| **Seguridad e identidad** | IAM, KMS, STS, ACM, Secrets Manager |
| **Analytics** | Kinesis Streams, Kinesis Firehose, OpenSearch, Redshift |

### Servicios que requieren plan de pago

- **Base:** RDS, ElastiCache, ECR, ECS, Cognito, Amazon MQ
- **Ultimate:** EKS, EFS, Athena, AWS Glue, DocumentDB, MemoryDB, Neptune
- **Enterprise:** Kubernetes Operator, SSO/SCIM, Shield, WAF

### Limitaciones a tener en cuenta

Al ser una emulación, hay diferencias respecto a AWS real:

- Las **validaciones de IAM** no se aplican en el plan Hobby — las políticas se aceptan aunque tengan errores que AWS rechazaría
- El plan Hobby **no tiene persistencia**: los recursos desaparecen al reiniciar el contenedor
- No todas las APIs están implementadas al **100%** de compatibilidad con AWS real

> **Recurso:** Consulta la [documentación oficial de licencias](https://docs.localstack.cloud/aws/licensing/) para saber exactamente qué está soportado en cada plan.

---

## 6.11 Debugging y Observabilidad

Una de las ventajas más útiles de LocalStack es poder ver exactamente qué llamadas API está realizando Terraform durante un `apply`. Esto es invaluable para aprender cómo funciona Terraform internamente y para depurar configuraciones incorrectas.

```bash
# Activar logs de debug al iniciar LocalStack
LS_LOG=debug localstack start

# Ejemplo de lo que verás en los logs tras terraform apply
2024-01-15 INFO  PUT /mi-bucket HTTP/1.1
2024-01-15 INFO  Status: 200 (OK)
2024-01-15 DEBUG s3.CreateBucket { BucketName: "mi-bucket", Region: "us-east-1" }

# Ver logs del contenedor Docker en tiempo real
docker logs localstack -f
```

Con `LS_LOG=debug`, verás el rastro completo de cada petición que Terraform realiza: qué endpoint llama, qué parámetros envía y qué respuesta recibe. Es como tener un inspector de tráfico HTTP para tu infraestructura.

---

## 6.12 LocalStack en pipelines CI/CD

El uso más profesional de LocalStack es como servicio sidecar en pipelines de GitHub Actions. Cada vez que alguien hace un push al repositorio, el pipeline levanta LocalStack, aplica la infraestructura Terraform y ejecuta tests de integración — todo sin coste. Solo el código que pasa estas pruebas llega a AWS real.

```yaml
# .github/workflows/test-infra.yml
name: Validate Terraform Infrastructure

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      localstack:
        image: localstack/localstack:latest
        ports:
          - "4566:4566"

    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        run: terraform init

      - name: Terraform Apply (LocalStack)
        run: terraform apply -auto-approve
        env:
          AWS_ACCESS_KEY_ID: test
          AWS_SECRET_ACCESS_KEY: test
          AWS_DEFAULT_REGION: us-east-1

      - name: Run Integration Tests
        run: pytest tests/
```

---

## 6.13 Seguridad: Credenciales ficticias

LocalStack **no valida** las credenciales contra AWS: podemos usar cualquier valor ficticio como `test/test`. Sin embargo, el provider de AWS de Terraform requiere que las variables de credenciales estén definidas para inicializar correctamente.

```bash
# Variables de entorno ficticias — suficientes para LocalStack
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"

# Con estas variables, Terraform inicializa y aplica contra LocalStack sin problemas
terraform init
terraform plan
terraform apply -auto-approve
```

> ⚠️ **NUNCA** mezcles tus credenciales reales de producción con la configuración dirigida a LocalStack. Usa perfiles separados en `~/.aws/credentials` o archivos `.env` diferentes para cada entorno. Las credenciales reales no deben aparecer nunca en el código ni en los archivos de configuración de LocalStack.

---

## 6.14 Conclusión: El Flujo Local-Primero

LocalStack no **sustituye** a AWS — es imposible emular al 100% todos los servicios de Amazon. Lo que hace es **acelerar el ciclo de feedback** del desarrollador: en lugar de esperar minutos para saber si un recurso se crea correctamente en AWS, lo sabes en segundos en local.

La filosofía de trabajo adoptada con LocalStack se resume en tres pasos:

```
1. ESCRIBIR
   Código Terraform en tu editor favorito

        ↓

2. PROBAR
   En local con LocalStack, sin coste ni riesgo
   terraform apply → awslocal s3 ls → validar comportamiento

        ↓

3. DESPLEGAR
   Solo código validado llega a la nube real de AWS
   terraform apply (apuntando a AWS real)
```

> *"Dominar LocalStack es una habilidad clave para cualquier ingeniero DevOps que busque eficiencia y seguridad operativa en su flujo de trabajo diario."*

---

> **[← Volver al índice del Módulo 1](./README.md)**
