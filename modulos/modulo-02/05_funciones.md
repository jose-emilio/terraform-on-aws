# Sección 5 — Funciones Integradas de Terraform

> [← Sección anterior](./04_expresiones_operadores.md) | [← Volver al índice](./README.md) | [Siguiente →](./06_meta_argumentos.md)

---

## 5.1 Introducción: El Catálogo Nativo de Terraform

Terraform no permite definir funciones personalizadas en HCL. Esta es una decisión de diseño deliberada: en lugar de abrir la puerta a lógica arbitraria y compleja, HashiCorp mantiene un **catálogo estándar de funciones integradas** que cubre la inmensa mayoría de necesidades de transformación de datos.

> **Nota (Terraform 1.8+):** Desde abril de 2024, los providers pueden exponer sus propias *provider-defined functions* que el código HCL puede invocar. Son funciones adicionales que amplían el catálogo nativo, pero siguen siendo proporcionadas por el provider — el usuario final no puede escribir funciones HCL propias desde cero.

Estas funciones son **deterministas**: la misma entrada produce siempre la misma salida, garantizando que `terraform plan` sea predecible y estable en cada ejecución. Si `upper("hola")` devuelve `"HOLA"` hoy, lo hará también en seis meses en cualquier máquina.

```hcl
# Sintaxis general — igual que en cualquier lenguaje de programación
nombre_funcion(arg1, arg2, ...)
```

Categorías disponibles: strings, numéricas, colecciones, encoding, filesystem, fecha/hora, hash/crypto, red/IP, conversión de tipos.

---

## 5.2 Pruebas en Vivo: `terraform console`

Antes de escribir lógica compleja en tus archivos `.tf`, prueba siempre las funciones en la **consola interactiva**. Es un REPL (Read-Eval-Print Loop) donde puedes evaluar cualquier expresión o función en tiempo real sin realizar ningún despliegue:

```bash
# Iniciar la consola interactiva
$ terraform console

# Probar funciones directamente
> upper("hola")
"HOLA"

> max(5, 12, 3)
12

> join(", ", ["web", "api", "db"])
"web, api, db"

> cidrsubnet("10.0.0.0/16", 8, 2)
"10.0.2.0/24"

# Salir
> exit
```

Esta herramienta es invaluable para aprender y para depurar expresiones complejas. Úsala siempre como paso previo antes de añadir lógica nueva al código.

---

## 5.3 Manipulación de Texto I: `format`, `join` y `split`

Las funciones más utilizadas para construir y descomponer cadenas de texto:

```hcl
locals {
  # format() — crea strings con marcadores estilo printf
  nombre_recurso = format("servidor-%s-%03d", var.env, count.index)
  # → "servidor-prod-001"

  # join() — convierte una lista en una cadena con delimitador
  subredes_str = join(", ", ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"])
  # → "10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24"

  # split() — separa una cadena en una lista
  azs = split(",", "us-east-1a,us-east-1b,us-east-1c")
  # → ["us-east-1a", "us-east-1b", "us-east-1c"]
}
```

| Función | Sintaxis | Uso principal |
|---------|----------|---------------|
| `format` | `format(fmt, args...)` | Nombres dinámicos con formato controlado |
| `join` | `join(sep, list)` | Unir lista en cadena para APIs que esperan CSV |
| `split` | `split(sep, string)` | Parsear cadenas recibidas de data sources |

---

## 5.4 Manipulación de Texto II: `replace`, `trim` y `regex`

Para limpiar y validar datos externos que pueden venir en formatos impredecibles:

```hcl
locals {
  # replace() — sustituye subcadenas rápidamente
  nombre_limpio = replace(var.nombre_usuario, " ", "-")
  # "José Emilio" → "José-Emilio"

  # trimprefix / trimsuffix — elimina prefijos o sufijos conocidos
  instance_id = trimprefix("instance/i-abc123", "instance/")
  # → "i-abc123"

  # regex() — extrae datos específicos con expresiones regulares
  # Extraer instance ID de un ARN completo (Account ID = 12 dígitos)
  arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-abc123"
  id  = regex("instance/(.*)", arn)[0]
  # → "i-abc123"
}
```

`regex()` es la más poderosa y la que más atención requiere. Siempre pruébala en `terraform console` antes de incluirla en código de producción.

---

## 5.5 Funciones Numéricas: `min`, `max`, `ceil` y `floor`

Para controlar valores numéricos y poner límites de seguridad:

```hcl
locals {
  # max() — asegurar un mínimo de nodos (guardrail)
  nodos_seguros = max(var.nodos, 2)
  # Si el usuario pide 0 o 1 nodos, Terraform fuerza 2

  # min() — limitar el máximo
  instancias = min(var.replicas, 10)
  # Nunca más de 10 instancias, aunque var.replicas sea mayor

  # ceil() — redondear hacia arriba (para tamaños de disco)
  total_gb   = 100 * 1.15        # → 115.0
  disk_size  = ceil(total_gb)    # → 115 (entero sin decimales)

  # floor() — redondear hacia abajo
  bloques = floor(var.total_bytes / 512)
}
```

> **Consejo Pro:** Usa `max(var.input, MINIMO)` como *guardrail*: si el usuario configura un valor demasiado bajo (o cero), Terraform forzará automáticamente el mínimo seguro. Esto previene configuraciones inválidas antes del despliegue.

---

## 5.6 Colecciones I: `length`, `lookup` y `merge`

Las funciones de colección más usadas en el día a día:

```hcl
locals {
  # length() — contar elementos para validaciones
  num_subredes = length(var.subredes)
  # Usar en count para crear una subnet por elemento

  # lookup() — búsqueda segura en mapa con valor por defecto
  instancia = lookup(var.tipos_instancia, var.env, "t3.micro")
  # Si var.env no está en el mapa → usa "t3.micro" (fallback seguro)

  # merge() — fusionar mapas de tags (el derecho gana en conflictos)
  tags_finales = merge(
    var.tags_empresa,          # Tags corporativos base
    {
      Proyecto = "api-v2"
      Entorno  = var.env
    }
  )
  # Los tags del bloque derecho sobrescriben los del izquierdo
}
```

`merge()` es esencial para políticas de tagging empresarial: permite definir tags globales en un nivel y añadir tags específicos por proyecto sin perder los globales.

---

## 5.7 Colecciones II: `flatten` y `concat`

Para normalizar y combinar listas que provienen de múltiples fuentes:

```hcl
locals {
  # Subredes por zona de disponibilidad (resultado de módulos)
  subredes_az_a = ["subnet-aaa1", "subnet-aaa2"]
  subredes_az_b = ["subnet-bbb1", "subnet-bbb2"]

  # concat() — une listas independientes en una sola
  todas = concat(local.subredes_az_a, local.subredes_az_b)
  # → ["subnet-aaa1", "subnet-aaa2", "subnet-bbb1", "subnet-bbb2"]

  # flatten() — aplana listas de listas en una lista plana
  listas_anidadas = [local.subredes_az_a, local.subredes_az_b]
  plana = flatten(local.listas_anidadas)
  # → ["subnet-aaa1", "subnet-aaa2", "subnet-bbb1", "subnet-bbb2"]
}
```

`flatten()` es especialmente útil cuando trabajas con módulos que devuelven listas de listas — por ejemplo, cuando varios módulos de red devuelven cada uno sus propias subredes y necesitas consolidarlas todas para pasarlas a un balanceador.

---

## 5.8 Mapeo Dinámico: `keys`, `values` y `zipmap`

Para construir inventarios y trabajar con los metadatos de mapas:

```hcl
locals {
  config = {
    web = "10.0.1.10"
    api = "10.0.2.20"
    db  = "10.0.3.30"
  }

  # keys() — extrae solo las claves del mapa
  servicios = keys(local.config)
  # → ["api", "db", "web"]   (orden alfabético)

  # values() — extrae solo los valores
  ips = values(local.config)
  # → ["10.0.2.20", "10.0.3.30", "10.0.1.10"]

  # zipmap() — construye un mapa desde dos listas paralelas
  nombres = ["web-01", "api-01"]
  ips_lista = ["10.0.1.10", "10.0.2.20"]
  inventario = zipmap(local.nombres, local.ips_lista)
  # → {web-01 = "10.0.1.10", api-01 = "10.0.2.20"}
}
```

---

## 5.9 Codificación: `jsonencode` y `yamlencode`

Estas funciones evitan errores de sintaxis al generar JSON y YAML manualmente. Son especialmente críticas para políticas IAM, configuraciones de Lambda y cualquier atributo que espere un JSON como string:

```hcl
# jsonencode() — HCL nativo a JSON string válido
resource "aws_s3_bucket_policy" "main" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject"]
      Resource  = "${aws_s3_bucket.main.arn}/*"
    }]
  })
  # Terraform genera el JSON correctamente — sin errores de comas, llaves, etc.
}

# jsondecode() — JSON string a objeto HCL
locals {
  config = jsondecode(file("config.json"))
  region = local.config.region
}
```

Sin `jsonencode`, tendrías que escribir el JSON como string con todas las comillas escapadas — un proceso propenso a errores y difícil de mantener.

---

## 5.10 Filesystem: `file`, `filebase64` y `templatefile`

Para importar contenido de archivos locales directamente en el código:

```hcl
# file() — inyectar texto de un archivo local
resource "aws_key_pair" "deploy" {
  key_name   = "deploy-key"
  public_key = file("~/.ssh/deploy.pub")   # Lee la clave pública SSH
}

# filebase64() — para binarios codificados en base64
certificado = filebase64("certificado.pfx")
```

> **Buena práctica:** Nunca pegues claves SSH o certificados directamente en el código. Usa `file()` para referenciarlos desde archivos locales excluidos del repositorio vía `.gitignore`.

### `templatefile()`: La Más Poderosa

`templatefile()` lee un archivo externo y **sustituye variables de Terraform** dentro de él. Permite crear scripts `user_data` totalmente dinámicos:

```hcl
# user_data.tftpl — archivo de plantilla (fuera del código HCL)
# #!/bin/bash
# export DB_HOST="${db_endpoint}"
# export DB_USER="${db_user}"
# systemctl start app

# Llamada en Terraform — pasa las variables a la plantilla
resource "aws_instance" "app" {
  user_data = templatefile("user_data.tftpl", {
    db_endpoint = aws_db_instance.main.endpoint
    db_user     = var.db_user
  })
}
```

---

## 5.11 Redes: `cidrsubnet` y `cidrhost`

Las herramientas más usadas para el direccionamiento IP en Terraform:

```hcl
# cidrsubnet() — divide una VPC en subredes consecutivas sin solapamiento
vpc_cidr = "10.0.0.0/16"

# cidrsubnet(prefix, newbits, netnum)
# prefix: CIDR base, newbits: bits adicionales, netnum: índice de subred
cidrsubnet(vpc_cidr, 8, 0)   # → "10.0.0.0/24"  (subred 0)
cidrsubnet(vpc_cidr, 8, 1)   # → "10.0.1.0/24"  (subred 1)
cidrsubnet(vpc_cidr, 8, 2)   # → "10.0.2.0/24"  (subred 2)

# cidrhost() — obtiene la IP de un host específico dentro de un rango
cidrhost("10.0.1.0/24", 1)   # → "10.0.1.1"  (primer host)
cidrhost("10.0.1.0/24", 5)   # → "10.0.1.5"  (IP reservada para el ALB)

# cidrnetmask() — CIDR a notación decimal (para sistemas legacy)
cidrnetmask("10.0.0.0/16")   # → "255.255.0.0"
```

`cidrsubnet()` elimina el error humano en el direccionamiento IP: en lugar de calcular manualmente cada rango de subred, Terraform lo calcula automáticamente de forma consistente y sin solapamientos.

---

## 5.12 Fecha, Hora y Criptografía

```hcl
# timestamp() y formatdate() — para metadatos de auditoría
resource "aws_instance" "test" {
  tags = {
    CreatedAt = timestamp()
    Expires   = formatdate("YYYY-MM-DD", timestamp())
  }
}

# sha256() y md5() — hashes para detectar cambios en archivos
data_hash = sha256(file("lambda.zip"))
# Terraform usa esto para saber si el ZIP ha cambiado entre deploys
```

> **Advertencia:** `timestamp()` **no es determinista** — devuelve la hora actual en cada ejecución, lo que hace que Terraform vea un "cambio" en cada `plan`. Usa siempre `lifecycle { ignore_changes = [tags] }` con cualquier atributo que use `timestamp()`.

---

## 5.13 Cuándo (y cuándo no) usar funciones

Las funciones hacen el código **DRY** (Don't Repeat Yourself) y profesional. Pero la legibilidad siempre prima sobre la brevedad:

| Categoría | Cuándo |
|-----------|--------|
| ✅ **Úsalas** | Nombres dinámicos, `merge` de tags, cálculos de red con `cidrsubnet`, lectura de archivos. Una función clara que elimina repetición |
| ⚠️ **Con cuidado** | `regex` complejos, anidamiento de 2 funciones. Documenta siempre el propósito |
| ❌ **Evita** | 3+ funciones anidadas, lógica que nadie puede leer a primera vista, `timestamp()` sin `lifecycle`. Si es ilegible, refactoriza |

> Si una expresión requiere más de 2-3 funciones anidadas, simplifica: define un `local` intermedio con un nombre descriptivo para cada paso.

---

> **Siguiente:** [Sección 6 — Meta-argumentos y Bloques Dinámicos →](./06_meta_argumentos.md)
