output "tgw_id" {
  description = "ID del Transit Gateway"
  value       = aws_ec2_transit_gateway.main.id
}

output "client_a_vpc_id" {
  description = "ID de la VPC client-a"
  value       = aws_vpc.client_a.id
}

output "client_b_vpc_id" {
  description = "ID de la VPC client-b"
  value       = aws_vpc.client_b.id
}

output "inspection_vpc_id" {
  description = "ID de la VPC de inspeccion"
  value       = aws_vpc.inspection.id
}

output "egress_vpc_id" {
  description = "ID de la VPC de egress"
  value       = aws_vpc.egress.id
}

output "tgw_attachment_client_a" {
  description = "ID del TGW attachment de client-a"
  value       = aws_ec2_transit_gateway_vpc_attachment.client_a.id
}

output "tgw_attachment_client_b" {
  description = "ID del TGW attachment de client-b"
  value       = aws_ec2_transit_gateway_vpc_attachment.client_b.id
}

output "tgw_attachment_inspection" {
  description = "ID del TGW attachment de inspeccion"
  value       = aws_ec2_transit_gateway_vpc_attachment.inspection.id
}

output "tgw_attachment_egress" {
  description = "ID del TGW attachment de egress"
  value       = aws_ec2_transit_gateway_vpc_attachment.egress.id
}

output "appliance_mode" {
  description = "Estado del Appliance Mode en el attachment de inspeccion"
  value       = aws_ec2_transit_gateway_vpc_attachment.inspection.appliance_mode_support
}

output "inspection_flow_log_group" {
  description = "Nombre del CloudWatch Log Group de Flow Logs de inspection"
  value       = aws_cloudwatch_log_group.inspection_flow_logs.name
}

output "ram_resource_share" {
  description = "ARN del RAM Resource Share del TGW"
  value       = aws_ram_resource_share.tgw.arn
}

output "nat_public_ips" {
  description = "IPs publicas de los NAT Gateways de egress (una por AZ)"
  value = {
    for key, eip in aws_eip.nat_egress : key => eip.public_ip
  }
}

output "test_instance_client_a_id" {
  description = "ID de la instancia de test en client-a"
  value       = aws_instance.test_client_a.id
}

output "test_instance_client_b_id" {
  description = "ID de la instancia de test en client-b"
  value       = aws_instance.test_client_b.id
}

output "test_instance_client_a_private_ip" {
  description = "IP privada de la instancia de test en client-a"
  value       = aws_instance.test_client_a.private_ip
}

output "test_instance_client_b_private_ip" {
  description = "IP privada de la instancia de test en client-b"
  value       = aws_instance.test_client_b.private_ip
}
