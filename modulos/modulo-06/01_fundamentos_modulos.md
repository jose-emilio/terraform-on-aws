# Sección 1 — Fundamentos de Módulos

> [← Volver al índice](./README.md) | [Siguiente →](./02_diseno_modulos.md)

---

## 1.1 De Scripts a Componentes: ¿Qué es un Módulo?

Imagina que estás construyendo casas. Al principio, describes cada ladrillo, cada tubo de fontanería, cada cable eléctrico de forma individual. Funciona para una casa, pero cuando necesitas construir un barrio entero, copiar esa descripción veinte veces es inmanejable, inconsistente y catastrófico de mantener.

Los **módulos de Terraform** son la respuesta a este problema: una carpeta con archivos `.tf` que encapsula un conjunto de recursos relacionados en un componente reutilizable con una interfaz clara.

En lugar de copiar y pegar los 15 recursos que forman una VPC en cada proyecto, escribes ese código una vez en un módulo y lo invocas cuando lo necesitas, pasando solo los parámetros que cambian entre instancias.

Tres beneficios fundamentales:

| Beneficio | Significado práctico |
|-----------|---------------------|
| **Reutilización** | Escribe una vez, usa en todos los entornos. Sin copy-paste |
| **Abstracción** | El consumidor del módulo no necesita saber cómo funcionan los 15 recursos internos |
| **Agilidad** | Equipos distintos trabajan en paralelo con sus módulos; los cambios están aislados |

---

## 1.2 Root Module vs. Child Modules

> "Toda configuración de Terraform es, técnicamente, un módulo."

Esta frase tiene una implicación importante: la carpeta donde ejecutas `terraform apply` — tu directorio de trabajo — es el **Root Module**. Es el orquestador, el punto de entrada, el que gestiona el estado global.

Los **Child Modules** son los componentes que llamas desde el Root con el bloque `module {}`. Reciben variables del padre como parámetros y exportan outputs que el padre puede consumir.

```
Root Module (environments/prod/)
  ├── module "vpc"      → Child Module (modules/vpc/)
  ├── module "database" → Child Module (modules/database/)
  └── module "app"      → Child Module (modules/app/)
```

La relación es jerárquica pero no infinita: en la práctica, más de 2 niveles de profundidad genera una complejidad difícil de depurar.

---

## 1.3 Estructura Estándar: El Plano de Construcción

Todo módulo bien diseñado sigue una estructura de archivos convencional. Esta convención hace que cualquier ingeniero pueda orientarse en un módulo desconocido en segundos:

```
modules/vpc/
├── main.tf        ← Recursos principales (resource, data)
├── variables.tf   ← Entradas del módulo (variable {})
├── outputs.tf     ← Salidas del módulo (output {})
└── README.md      ← Documentación, uso y ejemplos
```

Opcionalmente puedes añadir:
- `locals.tf` — Variables derivadas internas
- `versions.tf` — Bloque `terraform { required_providers {} }`
- `examples/` — Código de ejemplo ejecutable

---

## 1.4 Convención de Directorios en Proyectos Reales

La separación entre módulos reutilizables y entornos que los consumen es fundamental:

```
proyecto/
├── modules/                  # Componentes locales reutilizables
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── database/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── environments/             # Entornos que consumen los módulos
│   ├── dev/
│   │   ├── main.tf           ← Aquí invocas los módulos con sus variables de dev
│   │   └── variables.tf
│   └── prod/
│       ├── main.tf           ← Mismos módulos, diferentes parámetros
│       └── variables.tf
│
└── README.md
```

Esta separación es clara: `modules/` son las piezas de LEGO; `environments/` son las construcciones que montas con esas piezas.

---

## 1.5 El Bloque `module {}`: Punto de Entrada a la Modularización

El bloque `module {}` es la sintaxis para invocar un child module. El único argumento obligatorio es `source`, que indica dónde está el código:

```hcl
module "nombre_logico" {
  source  = "./ruta/al/modulo"   # OBLIGATORIO — dónde está el código
  version = "~> 1.0"            # Solo para módulos del Registry

  # Variables de entrada del child module
  vpc_cidr    = "10.1.0.0/16"
  environment = "dev"
}
```

El `nombre_logico` es el identificador con el que referencias este módulo desde el Root (`module.nombre_logico.output_name`). Debe ser descriptivo y único dentro del archivo.

Terraform descarga e inicializa los módulos durante `terraform init` y los cachea en `.terraform/modules/`.

---

## 1.6 Ejemplo Completo: Módulo Local con Variables

```hcl
# environments/dev/main.tf
module "vpc" {
  source = "../../modules/vpc"   # Ruta relativa al módulo

  vpc_cidr      = "10.1.0.0/16"
  environment   = "dev"
  enable_nat_gw = false          # Ahorro de costes en dev
  public_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
}
```

El módulo de prod usaría el mismo `source` pero con `enable_nat_gw = true` y un CIDR diferente. El código del módulo es el mismo; los parámetros son distintos.

---

## 1.7 Flujo de Datos: Variables (Inputs) y Outputs

El flujo de datos entre Root Module y Child Module funciona así:

**El Child Module declara sus variables en `variables.tf`:**

```hcl
# modules/vpc/variables.tf
variable "vpc_cidr" {
  type        = string
  description = "CIDR block de la VPC"
}

variable "environment" {
  type        = string
  description = "Entorno: dev, stg o prod"
}
```

**El Root Module pasa los valores en el bloque `module {}`:**

```hcl
# environments/dev/main.tf
module "vpc" {
  source      = "../../modules/vpc"
  vpc_cidr    = "10.1.0.0/16"   # ← Mapea a variable "vpc_cidr"
  environment = "dev"            # ← Mapea a variable "environment"
}
```

**El Child Module exporta lo que otros necesitan en `outputs.tf`:**

```hcl
# modules/vpc/outputs.tf
output "vpc_id" {
  description = "El ID de la VPC creada"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas"
  value       = aws_subnet.private[*].id
}
```

**El Root Module accede a los outputs con `module.NOMBRE.OUTPUT`:**

```hcl
# El módulo de base de datos necesita las subredes privadas de la VPC
module "database" {
  source     = "../../modules/database"
  subnet_ids = module.vpc.private_subnet_ids   # ← Sintaxis: module.nombre.output
}
```

> Si un valor no está declarado en `outputs.tf`, no es accesible desde fuera del módulo. Esto es **encapsulamiento real**: el consumidor solo ve lo que tú decides exponer.

---

## 1.8 Múltiples Instancias del Mismo Módulo

El mismo módulo puede instanciarse múltiples veces con diferentes configuraciones, simplemente dándole diferentes nombres lógicos:

```hcl
# Servidor web (instancia del módulo "servidor")
module "web_server" {
  source        = "./modules/servidor"
  instance_type = "t3.medium"
  role          = "web"
  port          = 80
}

# Servidor de aplicación (mismo código, diferentes parámetros)
module "app_server" {
  source        = "./modules/servidor"   # Mismo source
  instance_type = "t3.large"            # Diferente tamaño
  role          = "app"
  port          = 8080
}
```

Esto elimina el anti-patrón de tener `main_web.tf` y `main_app.tf` con el código duplicado.

---

## 1.9 Fuentes de Módulos: Local, Git y Registry

El argumento `source` admite múltiples tipos de origen:

```hcl
# Local: desarrollo y proyectos monorepo
module "vpc" {
  source = "./modules/vpc"
}

# Git con tag de versión (estándar corporativo)
module "eks" {
  source = "git::https://github.com/mi-org/tf-modules.git//eks?ref=v1.2.3"
  #                                                           ↑↑         ↑
  #                                               subcarpeta//  versión exacta
}

# Terraform Registry (público)
module "vpc_publico" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
}

# S3 (registro privado corporativo)
module "vpc_empresa" {
  source = "s3::https://tf-modules.s3.amazonaws.com/vpc/v1.2.0.zip"
}
```

---

## 1.10 Mejores Prácticas: Módulos de Calidad

| Práctica | Detalle |
|----------|---------|
| **Pequeños y enfocados** | Un módulo = una responsabilidad. Máximo ~200 líneas de HCL. Composición sobre complejidad |
| **Versionados con SemVer** | Tags `v1.0.0`, `v1.1.0`. MAJOR = breaking changes, MINOR = nuevas features, PATCH = bugfixes |
| **Documentados** | README.md generado con `terraform-docs`. Incluir ejemplos de uso |
| **Validados** | Bloques `validation` en variables para detectar errores antes de `apply` |

```bash
# Genera documentación automáticamente
$ terraform-docs markdown table ./modules/vpc/ > README.md
```

---

## 1.11 Resumen: La Arquitectura Modular

```
Caja Negra (Child Module)
    variables.tf → Contrato de entrada (parámetros que acepta)
    outputs.tf   → Contrato de salida  (valores que expone)
    main.tf      → Implementación interna (15+ recursos ocultos)

Orquestador (Root Module)
    module "vpc" { source = "..." vpc_cidr = "10.0.0.0/16" }
    module "db"  { subnet_ids = module.vpc.private_subnet_ids }
```

| Concepto | Rol |
|----------|-----|
| `aws_vpc.main.id` | Dirección directa a un recurso (dentro del módulo) |
| `module.vpc.vpc_id` | Acceso al output de un módulo (desde el Root) |
| `variable "vpc_cidr"` | Parámetro de entrada del módulo |
| `output "vpc_id"` | Valor exportado por el módulo |

> **Principio:** Los módulos transforman recursos técnicos crudos en bloques funcionales con interfaces claras. No son solo una forma de organizar código — son la unidad de abstracción de la infraestructura. Bien diseñados, permiten que un equipo construya arquitecturas complejas sin conocer los detalles de implementación de cada componente.

---

> **Siguiente:** [Sección 2 — Diseño de Módulos Reutilizables →](./02_diseno_modulos.md)
