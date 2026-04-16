# Contribuir al curso Terraform on AWS

Gracias por tomarte el tiempo de mejorar este material. Cualquier contribución —desde corregir una errata hasta proponer un nuevo laboratorio— es bienvenida.

---

## Tipos de contribución

### 1. Reportar un error en un laboratorio

Si encuentras un paso que no funciona, un comando incorrecto o un recurso AWS que ha cambiado de comportamiento, abre un **Issue** usando la plantilla **"Error en laboratorio"**. Incluye:

- Número de lab y paso exacto donde falla
- Mensaje de error completo (`terraform plan/apply` output)
- Versión de Terraform (`terraform version`)
- Si es AWS real o LocalStack

### 2. Sugerir una mejora de contenido

¿Falta un concepto importante? ¿Un ejemplo podría ser más claro? ¿La versión de un servicio AWS está desactualizada? Abre un Issue con la plantilla **"Mejora de contenido"**.

### 3. Enviar un Pull Request

Los PRs son bienvenidos para:

- Correcciones ortográficas o de código
- Actualización de versiones de servicios o providers
- Mejoras en los ejemplos de código HCL
- Corrección de enlaces rotos

**No se aceptan PRs que:**

- Añadan módulos o laboratorios completos sin discusión previa en un Issue
- Cambien la estructura pedagógica sin consenso
- Incluyan archivos `terraform.tfstate`, `.terraform/` o credenciales

---

## Proceso de Pull Request

1. **Abre un Issue primero** si el cambio es significativo (nuevo contenido, reestructuración)
2. Haz fork del repositorio y crea una rama descriptiva: `fix/lab07-backend-config`, `update/terraform-1.8`
3. Aplica los cambios siguiendo la guía de estilo (ver abajo)
4. Abre el PR con la plantilla provista y enlaza el Issue relacionado

---

## Guía de estilo

### Markdown

- Encabezados en español, con tildes correctas (`## Configuración`, no `## Configuracion`)
- Bloques de código con lenguaje explícito: ` ```hcl `, ` ```bash `, ` ```yaml `
- Nombres de productos: **HCP Terraform** (no "Terraform Cloud"), **AWS CLI** (no "aws cli")
- Rutas de archivos: siempre en backticks — `labs/lab07/README.md`

### Código HCL

- Formatear con `terraform fmt` antes de cualquier commit
- Variables tipadas con `type` y `description` siempre presentes
- Sin valores *hardcodeados* de región, cuenta o ARN — usar variables o `data` sources

---

## Código de conducta

Este repositorio sigue las normas básicas de convivencia:

- Lenguaje respetuoso en Issues y PRs
- Críticas al contenido, no a las personas
- Issues duplicados se cierran con referencia al original

---

## Contacto

Para preguntas sobre el contenido del curso que no sean errores ni mejoras concretas, utiliza la sección [Discussions](https://github.com/jose-emilio/terraform-on-aws/discussions) del repositorio.
