# Módulo 4 — Seguridad e IAM con Terraform

![Terraform on AWS](../../images/modulo-banner.svg)


> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

Gestionar IAM como código es uno de los pilares de la seguridad en AWS. Este módulo cubre desde usuarios y roles hasta KMS, secretos, OIDC para CI/CD y cumplimiento de seguridad con Terraform.

---

## Contexto

> En el Módulo 3 configuraste un backend S3 con locking DynamoDB. Para que funcione de forma segura necesitas: un bucket con política correcta, una clave KMS para cifrado y un rol IAM con los permisos precisos. El Módulo 4 te enseña a construir toda esa capa de identidad y seguridad como código.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [AWS IAM: Usuarios, Grupos y Roles](./01_iam_identidades.md) | Users, Groups, Roles, Trust Policies, OIDC e Instance Profiles |
| 2 | [Políticas de IAM](./02_politicas_iam.md) | Managed Policies, inline policies, aws_iam_policy_document |
| 3 | [AWS KMS y Cifrado](./03_kms_cifrado.md) | CMKs, Key Policies, rotación y alias |
| 4 | [Administración de Secretos](./04_secretos.md) | Secrets Manager, SSM Parameter Store y rotación |
| 5 | [Seguridad Avanzada y Compliance](./05_seguridad_avanzada.md) | SCPs, Permission Boundaries, AWS Config y Security Hub |
| 6 | [Terraform y Seguridad del Pipeline](./06_seguridad_pipeline.md) | OIDC Federation, Checkov, Trivy y análisis estático |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 12](../../labs/lab-12/README.md) | Gestión de Identidades y Acceso Seguro para EC2 |
| [Lab 13](../../labs/lab-13/README.md) | Cifrado Transversal con KMS y Jerarquía de Llaves |
| [Lab 14](../../labs/lab-14/README.md) | Automatización de Secretos «Zero-Touch» |
| [Lab 15](../../labs/lab-15/README.md) | Blindaje del Pipeline DevSecOps |

---

## Objetivos de aprendizaje

- Crear y gestionar usuarios, grupos y roles IAM como código.
- Escribir Trust Policies y políticas de permisos con `aws_iam_policy_document`.
- Configurar OIDC Federation para pipelines CI/CD sin Access Keys.
- Gestionar claves KMS y secretos con Secrets Manager.
- Aplicar análisis estático de seguridad (Checkov, Trivy) al código IaC.

---

---

## ¿Qué sigue?

> Tienes identidad y seguridad configuradas: roles IAM, secretos en Secrets Manager, claves KMS. Ahora puedes construir sobre ese cimiento la red donde vivirán los recursos. El Módulo 5 crea la VPC, subredes, gateways y firewalls que serán la base de servidores, contenedores y bases de datos.

---

*[← Módulo 3](../modulo-03/README.md) | [Módulo 5 →](../modulo-05/README.md)*
