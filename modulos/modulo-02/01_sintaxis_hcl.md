# Sección 1 — Sintaxis y Estructura de HCL

> [← Volver al índice](./README.md) | [Siguiente →](./02_variables.md)

---

## 1.1 Introducción a HCL: HashiCorp Configuration Language

Si Terraform es el motor, HCL es el idioma en el que le hablamos. Antes de escribir una sola línea de infraestructura, es fundamental entender la gramática de ese idioma.

**HCL** (HashiCorp Configuration Language) fue diseñado para ocupar un espacio muy concreto: ser legible por humanos como si fuera texto natural, pero lo suficientemente estructurado para que las máquinas lo procesen sin ambigüedades. Está a medio camino entre JSON (demasiado rígido para leer) y los lenguajes de programación tradicionales (demasiado complejos para describir configuración).

La característica fundamental de HCL es que es **declarativo**: describes el estado deseado de la infraestructura y Terraform se encarga de calcular los pasos para alcanzarlo. No escribes "crea primero esto y luego aquello"; escribes "quiero que exista esto" y Terraform resuelve el orden.

| Característica | Descripción |
|---------------|-------------|
| **Legible** | Sintaxis clara entre JSON y lenguajes de programación. Fácil de aprender y mantener por cualquier miembro del equipo |
| **Declarativo** | Describes QUÉ quieres, no CÓMO hacerlo. Terraform gestiona los pasos |
| **Estándar IaC** | Su equilibrio entre simplicidad y expresividad lo convirtió en el estándar de facto para Infraestructura como Código |

---

## 1.2 Anatomía de un Bloque: La Fórmula Maestra

El bloque es la **unidad fundamental de construcción** en HCL. Todo en Terraform —recursos, variables, outputs, providers— se define dentro de bloques. Esta es la fórmula que repetirás en cada archivo `.tf`:

```hcl
# Esquema visual de un bloque
tipo_bloque  "etiqueta1"  "etiqueta2" {
  argumento1 = valor1
  argumento2 = valor2
}

# Ejemplo real
resource "aws_s3_bucket" "mi_bucket" {
  bucket = "datos-produccion"
}
```

- **`tipo_bloque`:** El tipo de bloque — `resource`, `variable`, `output`, `data`, `module`, `provider`, `terraform`, `locals`
- **`"etiqueta1"` y `"etiqueta2"`:** Identifican el bloque. En recursos, la primera es el tipo de recurso AWS y la segunda es el nombre local dentro del proyecto.
- **`{ }`:** Delimitan obligatoriamente el cuerpo del bloque. No son opcionales.

Las llaves de apertura y cierre son siempre obligatorias. Esta es la fórmula maestra que repetirás constantemente — apréndela de memoria.

---

## 1.3 Argumentos y Expresiones

Dentro de un bloque, los datos se asignan mediante **argumentos** — parejas `nombre = valor`:

```hcl
# Argumento ESTÁTICO — valor fijo, no cambia
ami           = "ami-0c55b159cbfafe1f0"   # placeholder — los IDs de AMI son específicos por región y cambian con cada actualización
instance_type = "t2.micro"

# Expresión DINÁMICA — valor calculado en tiempo de ejecución
ami  = var.ami_id                    # referencia a una variable
name = "srv-${var.entorno}"          # interpolación: mezcla texto con variable
```

Los argumentos estáticos son simples y directos. Las expresiones son el mecanismo que hace el código dinámico: pueden referenciar variables, resultados de funciones, atributos de otros recursos o calcular valores en tiempo de ejecución.

---

## 1.4 Identificadores y Convenciones de Nombres

Los identificadores en HCL siguen reglas gramaticales estrictas. El estándar de la comunidad es **snake_case** — palabras en minúscula separadas por guiones bajos:

```hcl
# Nombres CORRECTOS — snake_case descriptivo
mi_servidor_web
bucket_produccion
vpc_principal

# Nombres INCORRECTOS
1_servidor     # ✗ no puede empezar por número
MiServidor     # ✗ camelCase — no es el estándar
recurso1       # ✗ no descriptivo — ¿qué recurso es?
```

> **Consejo Pro:** Usa nombres descriptivos pero concisos que indiquen la función del recurso. Evita genéricos como `recurso1` o `servidor2`. Un buen nombre es aquel que otro ingeniero puede leer y entender sin necesitar un comentario adicional.

---

## 1.5 Comentarios: Documentar el Código para Humanos

Un código bien comentado reduce el miedo a tocar la infraestructura. HCL admite dos estilos:

```hcl
# Comentario de una sola línea — el más común
// También válido para una sola línea

/*
  Bloque de comentario multilínea.
  Este recurso gestiona el balanceador de carga
  de la zona EU-WEST-1. Creado por el equipo de red.
*/

port = 8080   # Puerto del servidor web (configurable via var.port)
ami  = "ami-0c55b159cbfafe1f0"   # placeholder — AMI específica de us-east-1; usa un data source en código real
```

Comenta el **por qué**, no el **qué**. El código ya explica qué hace; el comentario debe explicar por qué se tomó esa decisión o por qué ese valor concreto.

---

## 1.6 Formato Canónico: `terraform fmt`

El estilo del código importa. Un código desorganizado con sangrías inconsistentes y signos `=` desalineados es difícil de revisar y propenso a errores en `git diff`.

`terraform fmt` reescribe los archivos automáticamente con el estilo canónico oficial: ajusta sangrías a dos espacios, alinea los signos `=` y normaliza espacios. **No cambia la lógica**, solo el formato.

```hcl
# ANTES (desordenado — difícil de leer)
resource "aws_instance" "web" {
ami= "ami-0c55b"
  instance_type ="t2.micro"
    tags={
Name ="web" }}

# DESPUÉS de terraform fmt (limpio y canónico)
resource "aws_instance" "web" {
  ami           = "ami-0c55b"
  instance_type = "t2.micro"

  tags = {
    Name = "web"
  }
}
```

> Ejecútalo siempre antes de subir código al repositorio. La forma más profesional es conectarlo a un pre-commit hook para que se aplique automáticamente en cada `git commit`.

---

## 1.7 Archivos `.tf`: El Estándar de Texto

Terraform carga **automáticamente todos los archivos `.tf`** del directorio de trabajo. El **orden de los archivos no importa**: el motor construye internamente el grafo de dependencias para determinar el orden de ejecución correcto.

```
mi-proyecto/
  main.tf           # Recursos principales
  variables.tf      # Variables de entrada
  outputs.tf        # Valores de salida
  providers.tf      # Configuración de proveedores
  terraform.tfvars  # Valores de las variables

# Terraform carga TODOS los .tf del directorio
# El orden alfabético de los archivos NO importa
```

Esta separación lógica en varios archivos mejora la mantenibilidad. Cada archivo tiene un propósito claro, lo que reduce la fricción cuando varios ingenieros trabajan en el mismo proyecto.

---

## 1.8 Archivos `.tf.json`: Para Automatización por Máquinas

Terraform también entiende archivos JSON con extensión `.tf.json`. Este formato **no está pensado para humanos** — es para ser generado por scripts, programas externos o herramientas de orquestación que necesitan crear infraestructura de forma programática.

```json
{
  "resource": {
    "aws_s3_bucket": {
      "mi_bucket": {
        "bucket": "generado-por-script"
      }
    }
  }
}
```

> Solo usa `.tf.json` si tu flujo de trabajo requiere que una herramienta externa genere la configuración de forma programática. Para uso humano normal, `.tf` siempre.

---

## 1.9 Override Files: Parches Locales Temporales

Los archivos `_override.tf` permiten **sobrescribir** partes de la configuración de otro archivo sin modificarlo. Terraform procesa primero todos los archivos normales y luego aplica los overrides encima.

```hcl
# main.tf (archivo original — no se toca)
resource "aws_instance" "web" {
  instance_type = "t2.micro"
}

# main_override.tf (parche local temporal)
resource "aws_instance" "web" {
  instance_type = "t3.large"   # Sobrescribe solo este argumento
}
```

> **Precaución:** El uso de overrides debe ser limitado a parches locales temporales — por ejemplo, para desarrollo local sin afectar al código del repositorio. No los integres permanentemente en el código base, ya que dificultan entender qué configuración está activa realmente.

---

## 1.10 Tipos de Datos en HCL

HCL maneja dos categorías de tipos de datos: primitivos para valores simples y complejos para estructuras:

### Tipos primitivos

```hcl
# string — texto
nombre = "servidor-web-prod"
region = "eu-west-1"

# number — entero o decimal
puerto    = 8080
replicas  = 3
umbral    = 0.75

# bool — verdadero o falso
monitoring = true
publico    = false
```

### Tipos complejos

```hcl
# list — secuencia ordenada, acceso por índice
allowed_ips = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
# allowed_ips[0] = "10.0.1.0/24"

# map — clave-valor, todas las claves y valores del mismo tipo
tags = {
  Name        = "web-server"
  Environment = "production"
  Team        = "devops"
}

# object — estructura tipada, cada clave con su propio tipo
config = {
  host    = "db.internal"   # string
  port    = 5432            # number
  ssl     = true            # bool
}
```

---

## 1.11 Reglas de Precedencia y Carga

Terraform sigue un orden determinista al cargar los archivos del proyecto:

```
1. Archivos .tf       → Se cargan en orden alfabético — HCL nativo
2. Archivos .tf.json  → Se fusionan con los .tf — generados por máquinas
3. Overrides          → Se aplican al final, sobrescribiendo lo que toque
```

Una regla crítica que sorprende a muchos: **Terraform solo mira el directorio actual**. No baja a subdirectorios automáticamente. Para trabajar con subcarpetas, se usan módulos — que veremos en detalle más adelante.

---

## 1.12 Mejores Prácticas de Sintaxis

La simpleza en HCL es una virtud. Si un bloque es demasiado complejo para entenderlo de un vistazo, probablemente debería ser un módulo.

| Práctica | Descripción |
|---------|-------------|
| **Bloques claros** | Un recurso por bloque, argumentos bien definidos y ordenados |
| **snake_case** | Nombres descriptivos y consistentes en todo el proyecto |
| **terraform fmt** | Ejecutar siempre antes de subir código al repositorio |
| **Comentarios útiles** | Documenta el *por qué*, no el *qué* — el código ya lo dice |

> **Siguiente:** Con la gramática de HCL dominada, el siguiente paso es dotar a nuestros archivos de dinamismo mediante **variables de entrada profesionales**.

---

> **Siguiente:** [Sección 2 — Variables de entrada →](./02_variables.md)
