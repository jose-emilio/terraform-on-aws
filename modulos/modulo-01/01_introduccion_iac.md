# Sección 1 — Introducción a la Infraestructura como Código (IaC)

> [← Volver al índice](./README.md) | [Siguiente sección →](./02_ecosistema_hashicorp.md)

---

## 1.1 ¿Qué es la Infraestructura como Código?

**Infraestructura como Código** es la capacidad de gestionar y aprovisionar recursos de infraestructura mediante archivos de definición legibles por máquina, en lugar de configuración manual en consolas web o mediante clics.

En la práctica, esto significa tratar servidores, redes, bases de datos y balanceadores de carga **exactamente igual que el código fuente** de una aplicación: con control de versiones, revisiones de código, pruebas automatizadas y despliegues controlados.

IaC elimina el error humano y garantiza entornos repetibles en **cada despliegue**. No importa si estás creando el entorno por primera vez o reconstruyéndolo tras un desastre: el resultado es siempre el mismo porque el código no olvida, no se equivoca y no tiene un "mal día".

### Principios fundamentales

| Principio | Descripción |
|-----------|-------------|
| **Reproducibilidad** | El código garantiza que cada despliegue sea idéntico al anterior. Dev, Staging y Producción se convierten en gemelos técnicos, eliminando el "en mi local funciona". La consistencia es una propiedad intrínseca del código. |
| **Ingeniería de Software** | IaC permite aplicar las prácticas de ingeniería de software al hardware: control de versiones, testing automatizado, code reviews y CI/CD. La infraestructura se convierte en un artefacto de software más. |
| **Idempotencia** | El mismo código, ejecutado N veces, produce siempre el mismo resultado sin efectos secundarios. Si el recurso ya existe en el estado correcto, Terraform no hace nada. |
| **Versionado** | Todo cambio queda registrado en Git: quién hizo el cambio, cuándo y con qué motivo. El historial de la infraestructura es tan transparente como el del código de la aplicación. |

---

## 1.2 Evolución: de scripts manuales a herramientas declarativas

La gestión de infraestructura ha evolucionado por etapas, y entender esta evolución ayuda a comprender **por qué** llegamos a Terraform.

```
Scripts Manuales → Gestión de Configuración → Declarativo
  (Bash/Python)      (Ansible/Chef/Puppet)    (Terraform/CloudFormation)
      1                       2                        3
```

| Etapa | Herramientas | Característica principal |
|-------|-------------|--------------------------|
| **1 — Scripts Manuales** | Bash, Python, scripts ad-hoc | Frágiles, difíciles de mantener y propensos a fallos en redes complejas. El estado final depende de que cada paso anterior haya funcionado correctamente. |
| **2 — Gestión de Configuración** | Ansible, Chef, Puppet | Mejor estructura y reutilización, pero siguen estando enfocadas en pasos secuenciales. Son ideales para configurar software dentro de servidores ya creados. |
| **3 — Declarativo** | Terraform, CloudFormation | Defines el **estado deseado** y la herramienta resuelve el *cómo* llegar a él, incluyendo el orden de creación y las dependencias. |

### El cambio de paradigma

Las herramientas declarativas modernas se centran en el **estado deseado** y no en los pasos individuales. El ingeniero define la arquitectura objetivo y Terraform resuelve las dependencias complejas, el orden de creación y la paralelización automáticamente.

Este cambio liberó a los equipos de infraestructura para **pensar en arquitectura** en vez de en procedimientos. Ya no escribes "crea primero la VPC, luego la subred, luego la instancia". Simplemente declaras que quieres una instancia en una subred de una VPC, y Terraform calcula el orden correcto solo.

---

## 1.3 Reproducibilidad

### Entornos consistentes

IaC resuelve uno de los problemas más frustrantes del desarrollo de software: los entornos inconsistentes. Con IaC, Dev, Staging y Producción son **gemelos técnicos** generados desde el mismo código fuente.

Se acabó el "en mi local funciona". Cuando todos los entornos nacen del mismo código, los tests en pre-producción reflejan fielmente el comportamiento productivo. Si algo falla en staging, fallará en producción. Si funciona en staging, funcionará en producción. Esta predictibilidad es la base de la confianza operativa.

### Recuperación instantánea

Considera este escenario: son las 3 de la mañana, un operador elimina accidentalmente toda la infraestructura de producción. Sin IaC, eso significaría horas o días de trabajo manual reconstruyendo todo desde la memoria y la documentación (desactualizada). Con IaC, la solución es:

```bash
terraform apply
```

Terraform recrea toda la infraestructura en minutos, en el estado exactamente correcto. La reproducibilidad transforma el **Disaster Recovery** de un proceso manual de días en una ejecución automatizada de minutos.

> **La uniformidad en los despliegues cloud es la base de la confianza operativa.**

---

## 1.4 Versionado y Auditoría

El versionado con Git aplicado a la infraestructura proporciona tres beneficios críticos:

### Viaje en el tiempo (*Time Travel*)

Git permite revertir cambios de red o cómputo con un simple rollback de código. Si el equipo de red introduce un cambio que rompe la conectividad, se puede revertir en segundos con `git revert`. Cada versión del estado de la infraestructura queda registrada y es recuperable.

### Auditoría transparente

El historial de commits proporciona un registro transparente de **quién hizo qué cambio y por qué**. Cada modificación tiene autor, fecha y motivo documentado en el mensaje del commit. Para sectores regulados (banca, salud, gobierno), esta trazabilidad es a menudo un requisito legal. Con IaC, es un efecto secundario gratuito del flujo normal de trabajo.

### Seguridad: Peer Reviews

Las revisiones de código (Pull Requests / Merge Requests) permiten que otro ingeniero valide los cambios **antes** de que lleguen a producción. Un segundo par de ojos puede detectar un error de configuración que habría abierto un puerto innecesario o eliminado un grupo de seguridad crítico. Esta capa de seguridad humana es una de las ventajas más subestimadas de IaC.

---

## 1.5 IaC Imperativo vs. Declarativo

Esta distinción es fundamental para entender **por qué** Terraform es poderoso.

### Enfoque IMPERATIVO — "la receta de cocina"

Pasos secuenciales donde el estado final depende del éxito de cada comando previo. Piensa en ello como una receta: si te saltas un paso o cometes un error, el resultado final será incorrecto.

```bash
#!/bin/bash
COUNT=$(aws ec2 describe-instances --query 'length(Reservations)' --output text)
if [ $COUNT -lt 3 ]; then
  NEEDED=$((3 - COUNT))
  for i in $(seq 1 $NEEDED); do
    aws ec2 run-instances \
      --image-id ami-xxx \
      --count 1
  done
fi
```

**Problemas del enfoque imperativo:**
- ¿Qué pasa si el script falla a mitad? El estado queda inconsistente.
- ¿Y si ya había 2 instancias? El script no sabe si debe crear 1 o 3.
- ¿Y si ya había 4 instancias? El script no elimina el exceso.
- El estado final es imprevisible sin saber el estado inicial.

### Enfoque DECLARATIVO — "declaración de intenciones"

Defines **qué** quieres, no **cómo** conseguirlo. La herramienta calcula los pasos necesarios automáticamente.

```hcl
resource "aws_instance" "web" {
  count         = 3
  ami           = "ami-xxx"
  instance_type = "t3.micro"

  tags = {
    Name = "web-${count.index}"
  }
}
```

Terraform compara el estado actual (cuántas instancias existen hoy) con el estado deseado (3 instancias) y calcula exactamente qué acciones son necesarias: crear, modificar o destruir. Si ya hay 3 instancias correctas, no hace nada.

---

## 1.6 Terraform vs. otras herramientas

### Terraform vs. CloudFormation

| Característica | Terraform (HashiCorp) | CloudFormation (AWS) |
|---------------|-----------------------|----------------------|
| **Lenguaje** | HCL (declarativo, legible) | JSON / YAML |
| **Alcance** | Multi-cloud: AWS, Azure, GCP, +3000 providers | Solo AWS |
| **Estado** | Archivo `.tfstate` gestionado por el usuario o remotamente | Gestionado por AWS (en el servicio CloudFormation) |
| **Comunidad** | +3500 providers, 12.000+ módulos, 200M+ descargas/mes | Ecosistema AWS nativo |
| **Licencia** | BSL / OpenTofu (OSS) | Gratuito (pagas solo los recursos AWS) |

La elección depende del contexto: si tu empresa usa exclusivamente AWS y quiere integración nativa, CloudFormation es una opción sólida. Si necesitas gestionar múltiples nubes, proveedores de DNS externos, registros Docker o cualquier servicio con API, Terraform es la elección correcta.

### Terraform vs. Pulumi

Pulumi es un enfoque innovador: usa lenguajes de programación tradicionales (Python, TypeScript, Go) para definir infraestructura. Es ideal para equipos que prefieren código real sobre DSLs. Sin embargo, Terraform con HCL tiene una ventaja: su DSL simple y declarativo tiene una curva de aprendizaje suave y es legible incluso para quien no es programador experimentado.

### Terraform vs. Ansible

> **Distinción clave:**  
> `Terraform crea el servidor (Provisioning) → Ansible instala la aplicación (Configuration Management)`

Son herramientas **complementarias**, no competidoras. Terraform construye la infraestructura (VPC, instancias, bases de datos, balanceadores); Ansible configura el software dentro de esa infraestructura (instala nginx, configura la aplicación, gestiona usuarios del sistema).

En entornos modernos con contenedores e imágenes inmutables (ECS, EKS, Lambda), el rol de Ansible se reduce significativamente. Pero en entornos con instancias EC2 que gestionan su propia configuración de software, ambas herramientas trabajan en perfecta sintonía.

---

## 1.7 Cuándo usar IaC (y cuándo no)

No todo requiere IaC. Parte de la madurez profesional es saber cuándo la herramienta añade valor y cuándo añade complejidad innecesaria.

### ✅ SÍ usar IaC cuando...

- La infraestructura es **escalable y crítica** para el negocio
- Se requiere **mantenimiento a largo plazo** (meses o años)
- Hay **múltiples entornos** (Dev / Staging / Prod) que deben ser consistentes
- **Varios ingenieros** colaboran en la misma infraestructura
- Hay **requisitos de compliance y auditoría** (SOC 2, PCI-DSS, ISO 27001)

### ❌ Excepciones válidas — cuándo NO usar IaC

- Labs **temporales** de un solo uso que se destruyen en horas
- **Pruebas de concepto rápidas** donde la velocidad de exploración es crítica
- **Exploración manual** de nuevos servicios AWS para entender cómo funcionan antes de codificarlos
- La automatización añade más sobrecarga que valor

### Checklist de madurez para adoptar Terraform

Antes de invertir en IaC para un proyecto, hazte estas cuatro preguntas:

```
¿Es repetible? → ¿Es productivo? → ¿Participan varios ingenieros? → ¿Necesita auditoría?
```

> Si la respuesta es **SÍ** a 2 o más preguntas: **adopta IaC.**

---

## 1.8 Migración de infraestructura manual a IaC

La migración de una infraestructura existente y gestionada manualmente hacia IaC es uno de los retos más comunes en las organizaciones. Se hace en tres etapas.

### Etapa 1 — Diagnóstico: reconocer los síntomas

Síntomas habituales de infraestructura sin IaC — si reconoces más de dos de estos en tu organización, es el momento de migrar:

- **Falta de visibilidad total** del inventario: nadie sabe exactamente qué recursos existen y para qué sirven
- **Miedo a borrar recursos huérfanos**: "ese servidor lleva meses parado pero nadie sabe si lo usa alguien"
- **Lentitud en despliegues**: crear un nuevo entorno tarda días o semanas porque requiere trabajo manual
- ***Snowflake servers***: servidores únicos e irrepetibles que solo "el experto" sabe configurar
- **Configuration drift constante**: los entornos divergen con el tiempo porque nadie actualiza los manuales

### Etapa 2 — Migración

```bash
# Paso 1: Inventariar los recursos existentes
aws ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId,Tags]'

# Paso 2: Importar los recursos al estado de Terraform
terraform import aws_instance.web i-1234567890abcdef0

# Paso 3: Escribir el código HCL que representa la arquitectura actual
# Paso 4: Crear pipelines CI/CD para el flujo de cambios
# Paso 5: Añadir tests automatizados con checkov, tflint, terraform test
```

### Etapa 3 — Resultados esperados

Las organizaciones que completan la migración reportan mejoras consistentes:

| Métrica | Resultado típico |
|---------|-----------------|
| Tiempo de provisioning | **−70%** |
| Configuration drift | **eliminado (0)** |
| Visibilidad del inventario | **100%** |
| Tiempo de rollback | De horas a **minutos** |
| Coste de compliance | Reducido drásticamente |

---

## 1.9 Idempotencia

### La analogía del interruptor de la luz

> Si la luz ya está encendida, pulsar el botón de "Encender" no hace nada. No se enciende *"más"*. Este es el principio de idempotencia.

### Definición técnica

La idempotencia es la capacidad de ejecutar el mismo código múltiples veces obteniendo siempre el mismo resultado, **sin efectos secundarios ni cambios no deseados**. Cada ejecución converge al estado declarado en el código, independientemente del estado inicial.

Esto es lo que diferencia a Terraform de un script bash: si ejecutas un script bash dos veces, puede crear el doble de recursos. Si ejecutas `terraform apply` dos veces, el segundo apply no hace nada (porque el estado ya es correcto).

### Ejemplo práctico

```hcl
resource "aws_s3_bucket" "data" {
  bucket = "mi-bucket-unico"
}
```

| Situación | Comportamiento de Terraform |
|-----------|----------------------------|
| El bucket **no existe** | Lo crea |
| El bucket **ya existe** con la configuración correcta | No hace nada — *"No changes"* |
| El bucket fue **modificado manualmente** (drift) | Lo corrige, revirtiendo al estado declarado |
| El bucket fue **eliminado manualmente** | Lo vuelve a crear |

> Resultado siempre idéntico. **Estabilidad garantizada.**

---

## 1.10 La Cultura DevOps e IaC

Terraform no es solo una herramienta técnica, sino un **catalizador cultural**. Su adopción rompe el muro que históricamente ha existido entre los equipos de Desarrollo (Dev) y Operaciones (Ops).

Con IaC, la infraestructura deja de ser un "ticket" que el equipo de operaciones resuelve días después. Se convierte en un **Pull Request** que cualquier ingeniero puede escribir, revisar, aprobar y desplegar a través del pipeline de CI/CD, usando exactamente el mismo flujo que se usa para el código de la aplicación.

### El flujo DevOps con IaC

```
Dev escribe IaC → PR + Review → Pipeline CI/CD → Deploy a AWS
```

El ciclo de vida automatizado de la infraestructura potencia las entregas continuas de software (CI/CD), alineando la velocidad de desarrollo con la estabilidad operativa. Los equipos pueden desplegar infraestructura varias veces al día con total confianza, porque el código está testeado, revisado y es reproducible.

---

> **Siguiente:** [Sección 2 — Ecosistema HashiCorp y posicionamiento de Terraform →](./02_ecosistema_hashicorp.md)
