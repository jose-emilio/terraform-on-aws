output "vpc_id" {
  description = "ID de la VPC"
  value       = aws_vpc.main.id
}

output "zone_id" {
  description = "ID de la Zona Hospedada Privada"
  value       = aws_route53_zone.internal.zone_id
}

output "internal_domain" {
  description = "Nombre del dominio interno"
  value       = var.internal_domain
}

output "web_fqdn" {
  description = "FQDN del registro web (Alias → ALB)"
  value       = aws_route53_record.web.fqdn
}

output "db_fqdn" {
  description = "FQDN del registro db (A → IP privada)"
  value       = aws_route53_record.db.fqdn
}

output "db_private_ip" {
  description = "IP privada de la instancia db"
  value       = aws_instance.db.private_ip
}

output "alb_dns_name" {
  description = "DNS interno del ALB"
  value       = aws_lb.main.dns_name
}

output "test_instance_id" {
  description = "ID de la instancia de test"
  value       = aws_instance.test.id
}
