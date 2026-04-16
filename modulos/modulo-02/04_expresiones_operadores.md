# Sección 4 — Expresiones y Operadores

> [← Sección anterior](./03_outputs_datasources.md) | [← Volver al índice](./README.md) | [Siguiente →](./05_funciones.md)

---

## 4.1 ¿Qué es una expresión?

Una **expresión** es cualquier fragmento de código HCL que devuelve un valor. Es el motor de cálculo de Terraform: gracias a las expresiones, tu infraestructura deja de ser estática y se convierte en dinámica, capaz de adaptarse según variables, condiciones y datos externos.

Sin expresiones, toda la configuración sería texto fijo — la misma instancia, el mismo bucket, el mismo nombre, sin posibilidad de diferenciación por entorno. Con expresiones, un único código base puede producir configuraciones completamente distintas para desarrollo, staging y producción.

| Tipo | Ejemplo | Descripción |
|------|---------|-------------|
| **Literal** | `"us-east-1"`, `3`, `true` | Valor fijo escrito directamente |
| **Referencia** | `var.region`, `aws_vpc.main.id` | Valor de otra variable o recurso |
| **Función** | `cidrsubnet(var.cidr, 8, 1)` | Valor calculado por una función |
| **Condicional** | `var.env == "prod" ? "large" : "micro"` | Valor elegido según una condición |

---

## 4.2 Referencias a Recursos y Atributos

Para conectar un recurso con otro, se usa la sintaxis:

```
<TIPO_RECURSO>.<NOMBRE_LOGICO>.<ATRIBUTO>
```

Cada recurso expone atributos que otros recursos pueden consumir directamente:

```hcl
# La instancia EC2 usa el ID de la subred — referencia implícita
resource "aws_instance" "web" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.main.id   # ← referencia al atributo .id de la subnet
}
```

Este mecanismo de referencias crea automáticamente el **Grafo de Dependencias** de Terraform: al detectar que `aws_instance.web` referencia `aws_subnet.main.id`, Terraform sabe que debe crear la subred primero. No necesitas indicarlo manualmente — Terraform lo infiere de las referencias.

---

## 4.3 Operadores Aritméticos y de Comparación

### Operadores aritméticos

Manipulan números directamente en la configuración:

```hcl
locals {
  precio_base   = var.precio * var.cantidad            # multiplicación: *
  con_descuento = local.precio_base - (local.precio_base * 0.15)  # resta: -
  instancias    = var.replicas / 2                     # división: /
  sobrantes     = var.replicas % 2                     # módulo (resto): %
}
```

### Operadores de comparación

Devuelven valores booleanos (`true`/`false`) para usar en condiciones:

```hcl
resource "aws_instance" "web" {
  instance_type = var.cpu_count >= 8 ? "m5.xlarge" : "t3.micro"  # >= mayor/igual
  count         = var.env == "prod" ? 3 : 1         # == igualdad exacta
  monitoring    = var.env != "dev"                  # != desigualdad
}
```

Puedes comparar el conteo de instancias para activar características: si `var.instance_count > 3`, se habilita un balanceador de carga; si es menor, se usa acceso directo.

---

## 4.4 Operadores Lógicos: AND, OR, NOT

Los operadores lógicos combinan expresiones booleanas para construir condiciones compuestas. Son esenciales para controlar el flujo de recursos basado en múltiples criterios:

```hcl
locals {
  # AND: ambas condiciones deben ser true
  puede_desplegar = var.enabled && var.env == "prod"

  # OR: al menos una debe ser true
  tiene_acceso = var.is_admin || var.is_owner

  # NOT: invierte el valor
  sin_monitoring = !var.skip_monitoring

  # Combinando con paréntesis para claridad
  deploy = (var.is_prod && var.approved) || var.force
}
```

> **Consejo Pro:** Usa paréntesis para agrupar condiciones compuestas. `(a && b) || c` es más claro que `a && b || c` — elimina ambigüedades que generan errores difíciles de debuggear.

---

## 4.5 Prioridad de Operadores

HCL evalúa las expresiones siguiendo una jerarquía estricta de mayor a menor prioridad. Usa paréntesis para forzar un orden diferente o para mejorar la legibilidad:

```
1°  !, - (negación)           → Mayor prioridad
2°  *, /, % (multiplicativos)
3°  +, - (aditivos)
4°  >, >=, <, <= (comparación)
5°  ==, != (igualdad)
6°  && (AND lógico)
7°  || (OR lógico)            → Menor prioridad
```

> **Regla de oro:** Cuando tengas dudas sobre la prioridad, usa paréntesis. Hacen tu código más legible y eliminan cualquier ambigüedad. `(a + b) * c` siempre es mejor que `a + b * c`.

---

## 4.6 Expresiones Condicionales (Ternarias)

La sintaxis `condición ? valor_si_true : valor_si_false` permite tomar decisiones inline en una sola línea. Es el mecanismo más usado para adaptar la infraestructura al entorno:

```hcl
# Tipo de instancia: grande en prod, pequeña en dev
instance_type = var.env == "prod" ? "t3.large" : "t3.micro"

# Recurso condicional: 1 en prod, 0 (no existe) en dev
count = var.enabled ? 1 : 0

# Nombre dinámico según región
bucket_name = var.region == "us-east-1" ? "main-bucket" : "replica-bucket"
```

El patrón `count = var.enabled ? 1 : 0` es especialmente poderoso: permite activar o desactivar un recurso completo con una variable booleana, sin necesidad de comentar código ni duplicar configuración.

---

## 4.7 Interpolación de Cadenas: `${...}`

Con la sintaxis `${...}` puedes incrustar el resultado de cualquier expresión directamente dentro de una cadena de texto. El valor se convierte automáticamente a string:

```hcl
# Variable simple en una cadena
name = "web-${var.env}"                      # → "web-prod"

# Expresión compleja con función
tags = "created-${formatdate("YYYY-MM-DD", timestamp())}"

# Múltiples variables concatenadas
bucket_name = "${var.prefix}-${var.name}-${var.env}"   # → "corp-datos-prod"
```

> **Buena práctica:** Si la expresión es solo una variable sin nada más, no necesitas interpolación:
> ```hcl
> name = var.env            # ✅ correcto y más limpio
> name = "${var.env}"       # ❌ innecesariamente verboso
> ```

---

## 4.8 Directivas: `%{if}` y `%{for}` dentro de Strings

Las directivas permiten generar texto dinámico directamente dentro de cadenas multilínea, similar a un motor de plantillas. Son perfectas para generar configuraciones, políticas IAM o scripts donde el contenido varía según condiciones:

```hcl
# Directiva if — incluye o excluye bloques de texto
mensaje = <<-EOT
  Servidor: ${var.nombre}
  %{if var.env == "prod"}
  ENTORNO: PRODUCCIÓN — máxima precaución
  %{endif}
EOT

# Directiva for — genera una línea por elemento
reglas = <<-EOT
  %{for ip in var.ips}
  allow ${ip}
  %{endfor}
EOT
```

```
Sintaxis if:  %{if CONDICIÓN}...%{else}...%{endif}
Sintaxis for: %{for VAR in LISTA}...%{endfor}
```

---

## 4.9 Heredoc: Cadenas Multilínea

La sintaxis heredoc `<<EOT...EOT` permite escribir cadenas de múltiples líneas preservando saltos de línea y formato. Es el estándar para scripts de inicialización, políticas JSON y configuraciones extensas:

```hcl
# Heredoc estándar — preserva la indentación exacta
user_data = <<EOT
#!/bin/bash
apt-get update
apt-get install -y nginx
systemctl enable nginx
EOT

# Heredoc indentado (<<~) — elimina la indentación común para alinear con el código
policy = <<~EOT
  {
    "Version": "2012-10-17",
    "Statement": []
  }
EOT
```

El marcador `<<~` (con virgulilla) es especialmente útil: elimina la indentación común de todas las líneas, permitiendo que el heredoc esté indentado al mismo nivel que el código circundante sin que esa indentación aparezca en el valor final.

---

## 4.10 Control de Espacios: Strip con `~`

El carácter `~` junto a las llaves de interpolación o directivas elimina espacios en blanco y saltos de línea adyacentes:

```hcl
# Strip en interpolación
"${~var.nombre~}"    # Elimina espacios a ambos lados

# Strip en directivas — evita líneas en blanco extra
%{~for x in var.lista~}
${x}
%{~endfor~}
```

El chomp importa principalmente cuando generas archivos de configuración (YAML, JSON, scripts de bash) donde los espacios en blanco extra pueden romper la sintaxis o causar comportamientos inesperados.

---

## 4.11 El Operador Splat `[*]`

Cuando usas `count` para crear múltiples recursos, el operador splat obtiene una **lista de todos sus atributos** sin necesidad de iterar manualmente:

```hcl
# Crear 5 instancias
resource "aws_instance" "web" {
  count         = 5
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
}

# Obtener la lista de todos los IDs con splat
output "instance_ids" {
  value = aws_instance.web[*].id
  # Resultado: ["i-0a1b2c", "i-3d4e5f", "i-6g7h8i", "i-9j10k", "i-11l12"]
}

# Pasar todos los IDs al target group del ALB
instances = aws_instance.web[*].id
```

Sin splat tendrías que escribir `[aws_instance.web[0].id, aws_instance.web[1].id, ...]` manualmente. Con splat, una expresión obtiene la lista completa.

---

## 4.12 Expresiones `for`: Transformar Colecciones

Las expresiones `for` crean nuevas colecciones transformando cada elemento de una lista o mapa existente. Son extremadamente poderosas combinadas con filtros `if`:

```hcl
variable "names" {
  default = ["web", "api", "db"]
}

locals {
  # Lista → Lista: convertir a mayúsculas
  upper_names = [for n in var.names : upper(n)]
  # Resultado: ["WEB", "API", "DB"]

  # Lista → Mapa: crear clave => valor
  name_map = {for n in var.names : n => upper(n)}
  # Resultado: {web = "WEB", api = "API", db = "DB"}

  # Lista filtrada: solo elementos no vacíos
  non_empty = [for n in var.names : n if n != ""]
}
```

```
Sintaxis lista: [for VAR in COLECCION : EXPRESION]
Sintaxis mapa:  {for k, v in MAP : k => EXPRESION}
Filtrado:       [for VAR in COLECCION : EXPRESION if CONDICION]
```

---

## 4.13 Navegación Segura: `try()` y `can()`

Cuando accedes a atributos de objetos opcionales que pueden no existir, estas funciones protegen tu código de errores en tiempo de ejecución:

```hcl
# try() — intenta evaluar la expresión; si falla, devuelve el fallback
region = try(var.config.region, "us-east-1")
# Si var.config.region no existe → devuelve "us-east-1"

# can() — devuelve true si la expresión es evaluable, false si no
tiene_region = can(var.config.region)
# Devuelve true si var.config.region existe y es accesible
```

Son como el **cinturón de seguridad** de tus expresiones. Úsalos cuando trabajes con datos opcionales de módulos externos o cuando el esquema de un objeto pueda variar entre versiones.

---

## 4.14 Resumen: Dominio de la Lógica HCL

El dominio de las expresiones y operadores es lo que transforma código HCL básico en infraestructura inteligente que se adapta al contexto.

> **La consola interactiva es tu laboratorio:** Usa `terraform console` para experimentar con expresiones, operadores y transformaciones sin riesgo antes de incluirlas en código real.

```bash
$ terraform console
> upper("hola")
"HOLA"
> var.env == "prod" ? "t3.large" : "t3.micro"
"t3.micro"
> [for n in ["web", "api"] : upper(n)]
["WEB", "API"]
> exit
```

> **Principio:** No abuses de la lógica compleja si puedes mantener el código simple. Un ternario es elegante; diez anidados son una pesadilla de mantenimiento. Si la lógica crece demasiado, divídela en `locals` intermedios o extráela a un módulo.

---

> **Siguiente:** [Sección 5 — Funciones Integradas →](./05_funciones.md)
