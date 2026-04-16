# ── VPCs ──────────────────────────────────────────────────────────────────────
output "vpc_ids" {
  description = "IDs de los VPCs creados, indexados por nombre logico"
  value       = { for k, v in aws_vpc.this : k => v.id }
}

# ── Subredes — resultado del Flatten Pattern ──────────────────────────────────
# Este output demuestra que el for_each sobre local.subnets_map creo
# correctamente una subred por cada entrada de la estructura anidada,
# con claves compuestas "vpc/subred".
output "subnet_ids" {
  description = "IDs de todas las subredes, indexados por clave compuesta vpc/subred"
  value       = { for k, v in aws_subnet.this : k => v.id }
}

output "subnets_by_vpc" {
  description = "IDs de subredes agrupados por VPC para facilitar la consulta"
  value = {
    for vpc_key in keys(local.vpcs_map) : vpc_key => {
      for subnet_key, subnet in aws_subnet.this :
      subnet_key => subnet.id
      if startswith(subnet_key, "${vpc_key}/")
    }
  }
}

# ── Flatten Pattern — estructura interna para inspeccion ──────────────────────
output "flattened_subnets_count" {
  description = "Numero total de subredes creadas a partir del mapa anidado"
  value       = length(local.subnets_map)
}

output "flattened_subnets_keys" {
  description = "Claves compuestas generadas por el Flatten Pattern"
  value       = keys(local.subnets_map)
}

# ── Instancia de monitoreo ─────────────────────────────────────────────────────
output "monitoring_instance_id" {
  description = "ID de la instancia de monitoreo (null si monitoring_config.enabled = false)"
  value       = var.monitoring_config.enabled ? aws_instance.monitoring[0].id : null
}

output "monitoring_public_ip" {
  description = "IP publica de la instancia de monitoreo — verificada por postcondition"
  value       = var.monitoring_config.enabled ? aws_instance.monitoring[0].public_ip : null
}

output "monitoring_instance_type" {
  description = "Tipo de instancia usado — refleja el valor por defecto de optional() si no se especifico"
  value       = var.monitoring_config.instance_type
}

# ── merge() — etiquetas resultantes para inspeccion ──────────────────────────
output "sample_subnet_tags" {
  description = "Etiquetas de una subred de muestra para verificar el resultado del merge()"
  value       = local.subnet_tags["networking/public-a"]
}

# ── Route tables publicas ─────────────────────────────────────────────────────
output "public_route_table_ids" {
  description = "IDs de las route tables publicas, indexados por VPC"
  value       = { for k, v in aws_route_table.public : k => v.id }
}

# ── try() / can() — valores calculados de forma segura ───────────────────────
output "monitoring_alarm_enabled" {
  description = "Indica si la alarma de monitoreo esta activa (calculado con can() en locals.tf)"
  value       = local.monitoring_alarm_enabled
}

output "subnet_billing_codes" {
  description = "Codigos de facturacion por subred — obtenidos con try() para mayor resiliencia"
  value       = local.subnet_billing_codes
}

# ── ignore_changes — tags gestionadas externamente ───────────────────────────
output "ignored_tag_keys" {
  description = "Tags que Terraform ignora en VPCs y subredes para evitar conflictos con herramientas de gobernanza"
  value = [
    "CreatedBy",
    "aws:cloudformation:stack-name",
    "aws:organizations:delegated-administrator",
    "kubernetes.io/role/elb",
    "kubernetes.io/role/internal-elb",
  ]
}

output "account_id" {
  description = "ID de la cuenta AWS activa"
  value       = data.aws_caller_identity.current.account_id
}
