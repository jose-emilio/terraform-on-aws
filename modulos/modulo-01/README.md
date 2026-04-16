# Módulo 1 — Fundamentos de Infraestructura como Código y Terraform

> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor  
> **Nivel:** Fundamentos

---

## Descripción del módulo

Este módulo sienta las bases conceptuales y prácticas necesarias para trabajar con Terraform en entornos AWS profesionales. Partiendo de cero, el alumno comprenderá el porqué de la Infraestructura como Código y terminará desplegando su primera infraestructura real.

---

## Contexto

> Este es el punto de entrada del curso: no hay módulo anterior. Si ya conoces otros sistemas IaC como CloudFormation o Ansible, este módulo te muestra en qué se diferencia Terraform. Si partes de cero, aquí construyes los cimientos conceptuales y prácticos sobre los que descansa todo lo demás.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|---|
| 1 | [Introducción a la IaC](./01_introduccion_iac.md) | Qué es IaC, principios, paradigmas y cultura DevOps |
| 2 | [Ecosistema HashiCorp y Terraform](./02_ecosistema_hashicorp.md) | Suite HashiCorp, licencias, Registry y Providers |
| 3 | [Instalación y Configuración del entorno](./03_instalacion_entorno.md) | Terraform, AWS CLI, tfenv, VS Code y herramientas de calidad |
| 4 | [Arquitectura interna de Terraform](./04_arquitectura_interna.md) | Core Engine, DAG, ciclo de vida de comandos y State File |
| 5 | [Proyectos de Terraform con AWS](./05_proyectos_terraform_aws.md) | Estructura de proyecto, primer recurso S3 y flujo completo |
| 6 | [LocalStack: AWS local](./06_localstack.md) | Emulación local de AWS, instalación y uso con Terraform |

---

## Laboratorios

| Lab | Título | Sección relacionada |
|-----|--------|---------------------|
| [Lab 0](../../labs/lab00/README.md) | Entorno de desarrollo remoto con VSCode en EC2 | Sección 3 |
| [Lab 1](../../labs/lab01/README.md) | Primeros pasos: Terraform, AWS CLI y LocalStack | Secciones 3 y 6 |
| [Lab 2](../../labs/lab02/README.md) | Primer despliegue en AWS: bucket S3 con versionado y cifrado | Sección 5 |

---

## Objetivos de aprendizaje

Al finalizar este módulo, el alumno será capaz de:

- Explicar qué es IaC y por qué ha reemplazado la gestión manual de infraestructura.
- Diferenciar el enfoque **imperativo** del **declarativo** con ejemplos reales.
- Navegar el ecosistema de HashiCorp e identificar el rol de cada herramienta.
- Instalar y configurar Terraform, AWS CLI, tfenv y las extensiones del editor.
- Describir el funcionamiento interno de Terraform (Core, Providers, DAG, State).
- Ejecutar el ciclo completo `init → plan → apply → destroy` en AWS.
- Usar **LocalStack** para desarrollar infraestructura sin coste y sin riesgo.

---

## Requisitos previos

- Cuenta de AWS con permisos de administrador (o usuario IAM con política suficiente).
- Terminal con acceso a internet.
- Visual Studio Code instalado.
- Conocimientos básicos de línea de comandos (Linux/macOS/WSL).

---

## Recursos adicionales

- [Documentación oficial de Terraform](https://developer.hashicorp.com/terraform/docs)
- [Terraform Registry](https://registry.terraform.io)
- [AWS Provider — Documentación](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [LocalStack — Documentación](https://docs.localstack.cloud)

---

---

## ¿Qué sigue?

> Ejecutaste tu primer `terraform apply` con un recurso S3 básico. Funcionó, pero el código era rígido: valores *hardcodeados*, sin reutilización. El Módulo 2 resuelve eso: aprenderás a parametrizar, reutilizar y hacer dinámico ese mismo tipo de código con el lenguaje HCL.

---

*Siguiente módulo → [Módulo 2: Lenguaje HCL y Configuración Avanzada](../modulo-02/README.md)*
