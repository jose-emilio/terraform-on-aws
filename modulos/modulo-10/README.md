# Módulo 10 — CI/CD y Automatización con Terraform

![Terraform on AWS](../../images/modulo-banner.svg)


> **Curso:** Terraform on AWS  
> **Instructor:** José Emilio Vera — Champion AWS Authorized Instructor

---

## Descripción

Este módulo cubre la integración de Terraform en pipelines de CI/CD modernos usando los servicios de AWS Developer Tools: CodeCommit, CodeArtifact, CodeBuild, CodeDeploy y CodePipeline. También abarca patrones de GitOps y automatización del ciclo de vida de la infraestructura.

---

## Contexto

> El Módulo 9 llevó las capacidades de Terraform al máximo. El código es maduro, los módulos están probados y los refactorings son seguros. El paso natural es automatizar el ciclo de vida completo: cada merge a `main` dispara un plan, espera aprobación y ejecuta el apply sin intervención manual.

---

## Índice de secciones

| # | Sección | Descripción |
|---|---------|-------------|
| 1 | [AWS CodeCommit y CodeArtifact](./01_codecommit_codeartifact.md) | Repositorios Git gestionados y artefactos privados |
| 2 | [AWS CodeBuild: Build de Infraestructura](./02_codebuild.md) | Compilación, test y plan de Terraform en CodeBuild |
| 3 | [AWS CodeDeploy](./03_codedeploy.md) | Estrategias de despliegue: blue/green, rolling, canary |
| 4 | [AWS CodePipeline: Pipeline Completo](./04_codepipeline.md) | Pipeline end-to-end de IaC con aprobación manual |
| 5 | [GitOps con Terraform](./05_gitops.md) | Patrones GitOps, GitHub Actions y Atlantis |

---

## Laboratorios

| Lab | Título |
|-----|--------|
| [Lab 41](../../labs/lab-41/README.md) | Gobernanza y Control de Versiones en CodeCommit |
| [Lab 42](../../labs/lab-42/README.md) | Repositorio Privado de Módulos Terraform con CodeArtifact |
| [Lab 43](../../labs/lab-43/README.md) | Canalización CI de IaC con CodeBuild y ECR |
| [Lab 44](../../labs/lab-44/README.md) | Entrega Continua con CodeDeploy |
| [Lab 45](../../labs/lab-45/README.md) | Pipeline GitOps de Terraform con CodePipeline |

---

## Objetivos de aprendizaje

- Crear y gestionar repositorios CodeCommit con Terraform.
- Configurar CodeBuild para ejecutar el ciclo de vida de Terraform.
- Implementar pipelines de CI/CD para infraestructura con CodePipeline.
- Aplicar estrategias de despliegue blue/green con CodeDeploy.
- Adoptar patrones GitOps con GitHub Actions y Atlantis.

---

---

## ¿Qué sigue?

> El pipeline está automatizado. Pero, ¿cómo sabes si algo falla en producción? ¿Cómo controlas el gasto? ¿Cómo garantizas que todo lo desplegado cumple las políticas de la organización? El Módulo 11 cierra el ciclo con observabilidad, tagging corporativo, FinOps y compliance como código.

---

*[← Módulo 9](../modulo-09/README.md) | [Módulo 11 →](../modulo-11/README.md)*
