# Política de Seguridad

## Alcance

Este repositorio contiene **material educativo** del curso Terraform on AWS: documentación en Markdown y ejemplos de código HCL. No es una aplicación en producción ni un módulo publicado en el Terraform Registry.

Los problemas de seguridad relevantes para este repositorio son:

- Ejemplos de código HCL con **políticas IAM excesivamente permisivas** que un alumno podría copiar directamente a producción (ej. `"Action": "*"` o `"Principal": "*"` sin restricciones)
- Buckets S3 de ejemplo **sin bloqueo de acceso público** cuando el contexto no lo justifica
- Ejemplos con **credenciales hardcodeadas** o secretos en texto plano
- Configuraciones KMS o Secrets Manager con **key policies inseguras**
- Cualquier fragmento de código que, seguido literalmente, introduzca una **vulnerabilidad real** en la infraestructura del alumno

## Cómo reportar

Usa el canal de **reporte privado de vulnerabilidades** de GitHub para no exponer el problema públicamente antes de que sea corregido:

1. Ve a la pestaña **Security** de este repositorio
2. Haz clic en **"Report a vulnerability"**
3. Describe el fragmento de código afectado, el riesgo concreto y, si es posible, una propuesta de corrección

Si el repositorio aún no tiene activado el reporte privado, escribe directamente a: **joseemilio@aws-training.org**

## Tiempo de respuesta

| Severidad | Criterio | Objetivo de respuesta |
|-----------|----------|-----------------------|
| **Alta** | El código, copiado literalmente, abre un vector de ataque real (bucket público, rol con `*`) | 48 horas |
| **Media** | Configuración subóptima o que viola el principio de mínimo privilegio sin ser explotable directamente | 1 semana |
| **Baja** | Mejora de buenas prácticas, sin riesgo inmediato | Próxima iteración del curso |

## Fuera de alcance

- Vulnerabilidades en los propios servicios de AWS o en Terraform/OpenTofu
- Problemas de seguridad en la cuenta AWS del alumno derivados de una mala configuración propia
- Solicitudes de pentest o escaneos automatizados del repositorio
