# Módulo 2 — Lenguaje HCL y Configuración Avanzada

> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

Este módulo profundiza en el lenguaje HCL (HashiCorp Configuration Language): su sintaxis, tipos de datos, variables, outputs, data sources, expresiones, funciones integradas y meta-argumentos. Al terminar, el alumno escribirá código Terraform profesional y dinámico.

---

## Contexto

> En el Módulo 1 aprendiste *qué es* Terraform y ejecutaste el ciclo `init → plan → apply`. Ahora que el flujo funciona, el paso natural es aprender a escribir código HCL profesional: variables que parametrizan, expresiones que calculan y meta-argumentos que eliminan repetición.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [Sintaxis y estructura de HCL](./01_sintaxis_hcl.md) | Bloques, argumentos, tipos de datos y formato |
| 2 | [Variables de entrada](./02_variables.md) | Tipos, validación, sensitive, tfvars y precedencia |
| 3 | [Outputs y Data Sources](./03_outputs_datasources.md) | Exportar valores y consultar recursos existentes |
| 4 | [Expresiones y Operadores](./04_expresiones_operadores.md) | Referencias, condicionales, bucles y splat |
| 5 | [Funciones integradas](./05_funciones.md) | String, numéricas, colecciones, encoding y fecha |
| 6 | [Meta-argumentos y bloques dinámicos](./06_meta_argumentos.md) | count, for_each, lifecycle, depends_on y dynamic |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 3](../../labs/lab03/README.md) | Infraestructura Parametrizada y Dinámica |
| [Lab 4](../../labs/lab04/README.md) | Orquestación de Identidades y Gestión de Ciclo de Vida |
| [Lab 5](../../labs/lab05/README.md) | Configuración Dinámica y Plantillas de Sistema |
| [Lab 6](../../labs/lab06/README.md) | Auditoría Dinámica y Conectividad Externa |

---

## Objetivos de aprendizaje

- Escribir bloques HCL correctos con tipos de datos adecuados.
- Parametrizar configuraciones con variables y `.tfvars`.
- Consultar recursos existentes con `data sources`.
- Usar expresiones condicionales y bucles en HCL.
- Aplicar funciones integradas para transformar datos.
- Gestionar múltiples recursos con `count` y `for_each`.

---

---

## ¿Qué sigue?

> Ya sabes escribir código HCL complejo. Pero cada `terraform apply` guarda una fotografía del estado en un archivo. ¿Dónde vive ese archivo en un equipo de diez personas? ¿Qué pasa si dos personas aplican al mismo tiempo? El Módulo 3 responde esas preguntas.

---

*[← Módulo 1](../modulo-01/README.md) | [Módulo 3 →](../modulo-03/README.md)*
