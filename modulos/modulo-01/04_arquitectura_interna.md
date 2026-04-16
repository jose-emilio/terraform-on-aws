# Sección 4 — Arquitectura Interna de Terraform

> [← Sección anterior](./03_instalacion_entorno.md) | [← Volver al índice](./README.md) | [Siguiente sección →](./05_proyectos_terraform_aws.md)

---

## 4.1 Core Engine y Plugins

Para usar Terraform de forma profesional, es fundamental entender qué ocurre por dentro cuando ejecutas un comando. La arquitectura de Terraform no es una caja negra: está diseñada de forma deliberada para ser modular, estable y extensible. Esta sección desmonta esa arquitectura pieza por pieza.

Terraform se divide internamente en dos componentes completamente diferentes, con responsabilidades bien delimitadas:

### Terraform Core — "el cerebro"

El motor central es el componente que descarga cuando instalas Terraform. Es **agnóstico a cualquier nube** y su única misión es orquestar. Se encarga de:

- Leer y parsear los archivos de configuración (`.tf`)
- Gestionar el **state file** (`terraform.tfstate`)
- Construir el **Resource Graph** (DAG) de dependencias
- Calcular el plan de ejecución comparando estado deseado vs. estado actual
- Orquestar la comunicación con los plugins
- Gestionar el lock del estado para evitar modificaciones simultáneas
- Resolver el orden de dependencias entre recursos
- Paralelizar operaciones donde sea posible

### Plugins / Providers — "las manos"

Los providers son piezas externas descargables que contienen **toda la lógica específica** de cada nube o servicio. El Core no sabe absolutamente nada de cómo crear un bucket en S3, una red en Azure o una función en Lambda. Ese conocimiento vive en los providers:

- Traducen el código HCL en llamadas a las APIs reales de cada servicio
- Se comunican con el Core mediante **gRPC** (protocolo de alto rendimiento)
- Son **procesos independientes** del Core — se ejecutan por separado
- Se versionan de forma independiente: el AWS Provider puede publicar una nueva versión sin que Terraform Core cambie
- Hay más de **3.500 providers** disponibles en el Registry oficial
- Cualquier empresa puede crear su propio provider para sus APIs internas

> **Separación de responsabilidades:** El Core no sabe nada de AWS, Azure o GCP. Solo sabe orquestar. Los providers son los que realmente entienden las APIs externas. Esta separación es la razón por la que Terraform puede gestionar más de 3.500 servicios distintos con el mismo binario.

---

## 4.2 Providers y comunicación gRPC

### ¿Por qué gRPC?

Terraform y sus proveedores se comunican mediante **gRPC**, un protocolo de alto rendimiento desarrollado por Google que usa Protocol Buffers para serializar los mensajes. Esta arquitectura permite que Core y Plugins sean **procesos independientes**, lo que mejora radicalmente la estabilidad y permite actualizaciones por separado sin romper la compatibilidad.

> **Analogía:** gRPC es como un traductor universal que permite a Terraform hablar cualquier "idioma" de nube sin cambiar su núcleo. El intérprete (provider) cambia dependiendo del destino; el emisor (Core) siempre habla el mismo idioma.

### Flujo de comunicación

```
Código HCL
    ↓
Terraform Core Engine
    ↓ gRPC (Protocol Buffers — proceso independiente)
Provider Plugin
    ↓ HTTPS / API nativa del servicio
Cloud API (AWS, Azure, GCP, Datadog, GitHub...)
```

### Ventajas de esta arquitectura

| Ventaja | Descripción |
|---------|-------------|
| **Independencia** | Core y plugins se actualizan por separado, sin acoplamiento entre versiones |
| **Estabilidad** | Un fallo en el provider de Kubernetes no afecta al Core ni al provider de AWS |
| **Extensibilidad** | Cualquiera puede crear su propio provider publicándolo en el Registry — basta con implementar la interfaz gRPC que el Core espera |

---

## 4.3 El Grafo de Recursos (DAG)

### ¿Qué es el DAG?

Antes de ejecutar ninguna acción, Terraform construye un **Grafo Acíclico Dirigido** (*Directed Acyclic Graph*) de todos los recursos y sus conexiones. Piensa en él como un mapa visual de toda tu infraestructura: qué existe, qué depende de qué, y en qué orden se puede construir.

Este grafo permite a Terraform resolver tres preguntas críticas automáticamente:

- ¿Qué recursos son **independientes** entre sí? → Se pueden crear en paralelo.
- ¿Qué recursos tienen **dependencias**? → Se deben crear en orden estricto.
- ¿Existe algún **ciclo infinito** de dependencia? → El plan falla antes de ejecutar nada.

### Ejemplo de grafo

```
       VPC
        ↓
     Subnet ────── Security Group
        ↓                 ↓
              EC2 Instance
```

La instancia EC2 **no puede crearse** hasta que la subred y el Security Group existan. La VPC se crea primero porque es la base de todo. Terraform calcula este orden automáticamente leyendo las referencias entre recursos — el ingeniero no tiene que especificarlo manualmente.

### Dependencias implícitas vs. explícitas

```hcl
# Dependencia IMPLÍCITA — Terraform la detecta automáticamente por la referencia
resource "aws_instance" "web" {
  subnet_id = aws_subnet.main.id   # Terraform lee esta referencia y sabe que necesita
                                   # la subnet antes de crear la instancia
}

# Dependencia EXPLÍCITA — para cuando no hay referencia directa en el código
resource "aws_instance" "web" {
  depends_on = [aws_internet_gateway.main]
  # "Aunque no uso ningún atributo del IGW, quiero que exista antes de crearme"
}
```

El 95% de las dependencias en Terraform son implícitas. Solo necesitas `depends_on` en situaciones donde hay una dependencia operacional que no se refleja en el código.

---

## 4.4 Construcción y Ejecución del Grafo

### Validación en el Plan

Durante `terraform plan`, Terraform construye el grafo y valida que **no existan ciclos infinitos** de dependencia. Si el recurso A depende de B y B depende de A, el plan falla inmediatamente con un mensaje claro indicando el ciclo detectado. Esta validación garantiza que todo grafo es ejecutable antes de realizar ninguna llamada a la API.

### Paralelismo inteligente

Cuando el grafo detecta recursos sin dependencias entre sí, los crea **simultáneamente**. El paralelismo por defecto es de **10 operaciones concurrentes**, ajustable con el flag `-parallelism`.

```bash
# Aumentar paralelismo para despliegues con muchos recursos independientes
terraform apply -parallelism=20

# Default: 10 operaciones simultáneas
```

Imagina un módulo que crea 30 reglas de seguridad independientes. Sin paralelismo, tardaría 30 llamadas API secuenciales. Con paralelismo=10, se completan en solo 3 rondas. Esto reduce drásticamente los tiempos de despliegue en infraestructuras grandes y puede representar la diferencia entre un apply de 2 minutos y uno de 20.

---

## 4.5 El comando `terraform init`

```bash
terraform init
```

`init` es el **primer comando** que se ejecuta en cualquier proyecto Terraform. Es un comando seguro en todos los sentidos: **no modifica ningún recurso en la nube**, no realiza llamadas destructivas y puede ejecutarse tantas veces como sea necesario sin efectos secundarios.

### ¿Qué hace exactamente?

1. Lee el bloque `required_providers` del código.
2. **Descarga los providers** necesarios desde el Terraform Registry.
3. Crea el directorio `.terraform/` con los binarios de los providers.
4. Genera el archivo `.terraform.lock.hcl` (congela las versiones exactas).
5. Inicializa el **backend** (local o remoto, para el state file).

### Ejemplo de salida

```
$ terraform init

Initializing the backend...

Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 6.0"...
- Installing hashicorp/aws v6.0.0...
- Installed hashicorp/aws v6.0.0 (signed by HashiCorp)

Terraform has been successfully initialized!
```

### El archivo `.terraform.lock.hcl`

Este archivo **congela las versiones exactas** de los providers usadas. Es el equivalente al `package-lock.json` de npm o al `Pipfile.lock` de Python: garantiza que todo el equipo usa exactamente el mismo binario de provider.

```hcl
# .terraform.lock.hcl (generado automáticamente — sí debe commitearse a Git)
provider "registry.terraform.io/hashicorp/aws" {
  version     = "6.0.0"
  constraints = "~> 6.0"
  hashes = [
    "h1:abc123...",   # Hash criptográfico para verificar integridad
  ]
}
```

> **Regla:** `.terraform/` **nunca** se sube a Git (está en el `.gitignore`). `.terraform.lock.hcl` **siempre** se sube (fija versiones del equipo).

---

## 4.6 El comando `terraform plan`

```bash
terraform plan
```

`plan` es la **red de seguridad** de Terraform. Ejecuta una simulación completa que compara tres fuentes de información:

```
Código .tf  ──→  PLAN  ←──  Estado actual (.tfstate)  ←──  Estado real de AWS
```

Muestra exactamente qué se añadirá, destruirá o modificará **antes de que ocurra nada**. No realiza ningún cambio en la nube. Es el equivalente a un `git diff` aplicado a la infraestructura.

### Símbolos en la salida del plan

| Símbolo | Significado |
|---------|-------------|
| `+` | Recurso a **CREAR** — nuevo, no existía |
| `-` | Recurso a **DESTRUIR** — se elimina de AWS |
| `~` | Recurso a **MODIFICAR** — se actualiza in-place |
| `-/+` | Recurso a **RECREAR** — debe destruirse y volver a crear (implica downtime) |

### Ejemplo de salida

```
$ terraform plan

  + resource "aws_s3_bucket" "data" {
      + bucket = "mi-bucket-unico"
      + id     = (known after apply)
      + arn    = (known after apply)
    }

Plan: 1 to add, 0 to change, 0 to destroy.
```

> **Buena práctica:** Revisa **siempre** el plan antes de aplicar. Un `-/+` inesperado puede significar tiempo de inactividad para un recurso en producción. La mayoría de los incidentes por Terraform se producen por aplicar sin leer el plan.

### Guardar el plan en un archivo

```bash
# Guardar el plan en disco para aplicarlo de forma determinista después
terraform plan -out=mi-plan.tfplan

# Aplicar exactamente el plan guardado (sin pedir confirmación de nuevo)
terraform apply mi-plan.tfplan
```

Este patrón es el estándar en CI/CD: el plan se genera en un step, se revisa por un humano, y se aplica en un step posterior sin posibilidad de que haya cambiado algo entre medias.

---

## 4.7 El comando `terraform apply`

```bash
terraform apply
```

`apply` es el comando que **materializa la infraestructura** realizando llamadas reales a las APIs de AWS. Por defecto, muestra el plan y pide confirmación explícita (`yes`) antes de proceder, lo que da una última oportunidad de revisar.

```
$ terraform apply

  Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

aws_s3_bucket.data: Creating...
aws_s3_bucket.data: Creation complete after 2s [id=mi-bucket-unico]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

### Aplicar sin confirmación (para pipelines CI/CD)

```bash
terraform apply -auto-approve
```

> Usa `-auto-approve` **solo** en pipelines automatizados donde el plan ya fue revisado y aprobado manualmente antes de este step. En entornos de trabajo manual, siempre lee el plan que muestra antes de escribir `yes`.

---

## 4.8 El comando `terraform destroy`

```bash
terraform destroy
```

`destroy` elimina de forma **ordenada** todos los recursos gestionados por el proyecto. Respeta el grafo de dependencias al eliminar: destruye en **orden inverso** al de creación. Si la EC2 depende de la subnet, primero elimina la EC2 y luego la subnet.

```
$ terraform destroy

  - resource "aws_s3_bucket" "data" {
      - bucket = "mi-bucket-unico" -> null
    }

Plan: 0 to add, 0 to change, 1 to destroy.

Do you really want to destroy all resources?
  Only 'yes' will be accepted to confirm.

  Enter a value: yes

Destroy complete! Resources: 1 destroyed.
```

### Destruir un recurso específico

```bash
# Destruir solo un recurso concreto sin tocar el resto
terraform destroy -target=aws_s3_bucket.data
```

> ⚠️ Usa `-target` con precaución: puede dejar el estado inconsistente si hay dependencias entre el recurso destruido y otros recursos que permanecen. El uso de `-target` está pensado para operaciones puntuales de emergencia, no como flujo habitual.

---

## 4.9 El State File: La pieza más crítica

### ¿Qué es `terraform.tfstate`?

El state file es la **base de datos** de Terraform. Es un archivo JSON que asocia cada nombre de recurso en el código con el **ID real asignado por AWS** tras su creación. Sin este archivo, Terraform no puede saber que la infraestructura existe y pensaría que tiene que crearla de nuevo.

```json
// terraform.tfstate (fragmento)
{
  "resources": [{
    "type": "aws_s3_bucket",
    "name": "data",
    "instances": [{
      "attributes": {
        "id":     "mi-bucket-unico",
        "arn":    "arn:aws:s3:::mi-bucket-unico",
        "region": "eu-west-1"
      }
    }]
  }]
}
```

### ¿Por qué es tan crítico?

- Si se **pierde**: Terraform ya no sabe que esos recursos existen e intentará recrearlos, generando recursos duplicados en AWS.
- Si se **corrompe**: toda la gestión de esa infraestructura queda bloqueada hasta que se repare manualmente.
- Si se **edita a mano**: puede causar comportamientos completamente impredecibles en el siguiente `apply`.
- Si se **sube a Git público**: expone información sensible de toda tu arquitectura (IDs, ARNs, IPs, etc.).

### Las 4 Reglas de Oro del State

1. **Nunca editar manualmente** el archivo `.tfstate`. Usa `terraform state` para operaciones sobre el estado.
2. **Nunca subir a Git público** — contiene información sensible de tu infraestructura completa.
3. **Siempre usar backend remoto en producción** (S3 con locking nativo desde Terraform ≥ 1.10, o S3 + DynamoDB en versiones anteriores).
4. **Activar versionado** del bucket S3 que almacene el estado, para poder recuperar versiones anteriores.

---

## 4.10 Terraform Registry: Providers y Módulos

### ¿Cómo descarga Terraform los providers?

Durante `terraform init`, Terraform busca los providers declarados en el código en el **Terraform Registry** (`registry.terraform.io`) y los descarga al directorio `.terraform/providers/` local.

```
Código .tf
    ↓
terraform init
    ↓
Registry (registry.terraform.io)
    ↓
Descarga local (.terraform/providers/)
    ↓
Binario del provider listo para usar
```

### Módulos del Registry

El Registry también ofrece **módulos pre-construidos** por la comunidad y por HashiCorp para desplegar arquitecturas complejas con muy pocas líneas de código. En lugar de definir una VPC con todas sus subredes, tablas de rutas y NAT Gateways desde cero, se puede invocar un módulo que lo hace todo:

```hcl
# Una VPC completa en 6 líneas usando el módulo de la comunidad
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.0"

  cidr            = "10.0.0.0/16"
  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}
```

Este módulo crea automáticamente una VPC completa con subredes públicas y privadas, Internet Gateway, NAT Gateways, tablas de rutas y todas las asociaciones necesarias — sin que el ingeniero tenga que definir cada recurso por separado.

---

> **Siguiente:** [Sección 5 — Proyectos de Terraform con AWS →](./05_proyectos_terraform_aws.md)
