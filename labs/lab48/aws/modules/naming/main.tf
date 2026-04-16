# ═══════════════════════════════════════════════════════════════════════════════
# Módulo de naming centralizado
# ═══════════════════════════════════════════════════════════════════════════════
#
# Genera nombres de recursos consistentes con el patrón:
#
#   {app}-{env}-{component}-{resource}
#
# Ejemplos:
#   myapp-prd-api-alb      → Application Load Balancer del componente API en producción
#   myapp-prd-compute-asg  → Auto Scaling Group del componente compute en producción
#   myapp-dev-network-vpc  → VPC del componente network en desarrollo
#   myapp-stg-data-rds     → Base de datos RDS del componente data en staging
#
# Ventajas de un módulo de naming centralizado:
#   1. Consistencia: todos los nombres siguen el mismo patrón
#   2. Legibilidad: el nombre identifica app, entorno, componente y tipo de recurso
#   3. Filtrado: en la consola AWS puedes buscar "myapp-prd" y ver todos tus recursos
#   4. Automatización: scripts de billing, monitoreo y cleanup pueden parsear el nombre
#   5. Mantenimiento: si cambia la convención, se modifica en UN solo lugar

locals {
  # Nombre completo del recurso. Incluye el tipo de recurso como sufijo
  # para que el nombre sea autoexplicativo en la consola AWS.
  name = "${var.app}-${var.env}-${var.component}-${var.resource}"

  # Prefijo sin el tipo de recurso. Útil para generar nombres de recursos
  # relacionados que comparten el mismo prefijo.
  prefix = "${var.app}-${var.env}-${var.component}"

  # Mapa de etiquetas que el módulo recomienda añadir a los recursos.
  # Complementan las default_tags del provider con metadatos de naming.
  tags = {
    Component = var.component
    App       = var.app
  }
}
