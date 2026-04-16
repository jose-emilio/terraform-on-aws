output "name" {
  description = "Nombre completo del recurso: {app}-{env}-{component}-{resource}."
  value       = local.name
}

output "prefix" {
  description = "Prefijo del recurso sin tipo: {app}-{env}-{component}. Útil para sub-recursos relacionados."
  value       = local.prefix
}

output "tags" {
  description = "Mapa de etiquetas recomendadas por el módulo de naming (Component, App)."
  value       = local.tags
}
