# Módulo 6 — Módulos de Terraform

> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

Los módulos son el mecanismo de reutilización de Terraform. Este módulo enseña a diseñar, documentar, versionar y publicar módulos profesionales, así como a consumir módulos públicos del Registry.

---

## Contexto

> Los módulos 1–5 construyeron una base amplia: IaC, HCL, State, Seguridad y Red. A medida que los proyectos crecen surge la necesidad de reutilizar patrones: la misma VPC en cinco entornos, el mismo bucket S3 con las mismas políticas. Los módulos de Terraform son la respuesta profesional a esa necesidad.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [Fundamentos de Módulos](./01_fundamentos_modulos.md) | Root vs. Child, bloque `module {}`, inputs/outputs y fuentes |
| 2 | [Diseño de Módulos Reutilizables](./02_diseno_modulos.md) | Principios de diseño, interfaces limpias y composición |
| 3 | [Fuentes y Versionado](./03_fuentes_versionado.md) | Registry, Git, S3, SemVer y `.terraform.lock.hcl` |
| 4 | [Módulos Públicos AWS en el Registry](./04_registry_publico.md) | terraform-aws-modules: VPC, EKS, RDS y más |
| 5 | [Pruebas de Módulos](./05_testing_modulos.md) | `terraform test`, Terratest y estrategias de validación |
| 6 | [Documentación, Publicación y Gobernanza](./06_publicacion_gobernanza.md) | terraform-docs, publicación en Registry y políticas de módulos |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 22](../../labs/lab22/README.md) | Refactorización Avanzada de S3 (De Monolítico a Modular) |
| [Lab 23](../../labs/lab23/README.md) | Diseño de Interfaz Robusta y «Fail-Safe» |
| [Lab 24](../../labs/lab24/README.md) | Composición de Módulos Públicos con Estándares Corporativos |
| [Lab 25](../../labs/lab25/README.md) | Framework de Pruebas: Plan, Apply e Idempotencia |
| [Lab 26](../../labs/lab26/README.md) | Gobernanza, Documentación y Publicación «Lean» |

---

## Objetivos de aprendizaje

- Entender la jerarquía Root Module / Child Modules.
- Crear módulos con interfaces claras: variables tipadas y outputs documentados.
- Consumir módulos desde fuentes locales, Git y el Registry público.
- Aplicar SemVer para versionar módulos de forma profesional.
- Escribir tests para módulos con `terraform test`.
- Publicar módulos en el Registry con documentación automática.

---

---

## ¿Qué sigue?

> Ya puedes empaquetar y reutilizar infraestructura. El siguiente paso es desplegar algo *sobre* esa red y esos módulos: servidores, contenedores y funciones. El Módulo 7 añade la capa de cómputo a la arquitectura que has ido construyendo módulo a módulo.

---

*[← Módulo 5](../modulo-05/README.md) | [Módulo 7 →](../modulo-07/README.md)*
