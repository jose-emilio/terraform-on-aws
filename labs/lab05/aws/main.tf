# templatefile() lee la plantilla .tftpl e inyecta las variables antes del
# despliegue. El resultado es el script de bash listo para usarse como User Data.
locals {
  user_data = templatefile("${path.module}/../user_data.tftpl", {
    env         = var.env
    app_name    = var.app_name
    db_endpoint = var.db_endpoint
    services    = var.services
  })

  # Expresión for que transforma la lista de servicios en un map de tags.
  # upper() convierte cada nombre a mayúsculas para usarlo como clave.
  # Resultado: { "NGINX" = "enabled", "POSTGRESQL15" = "enabled", ... }
  service_tags = { for svc in var.services : upper(svc) => "enabled" }
}

# aws_key_pair registra en AWS la clave pública leída con file() desde el disco
# local. Nunca se almacena la clave privada en el estado de Terraform.
resource "aws_key_pair" "lab4" {
  key_name   = "${var.app_name}-key"
  public_key = file(var.public_key_path)

  tags = {
    Name = "${var.app_name}-key"
    Env  = var.env
  }
}

# Launch template que consume el User Data generado por templatefile().
# base64encode() es necesario porque la API de EC2 espera el script en base64.
resource "aws_launch_template" "app" {
  name_prefix   = "${var.app_name}-"
  instance_type = "t4g.small"
  key_name      = aws_key_pair.lab4.key_name

  user_data = base64encode(local.user_data)

  # Los tags de servicios generados dinámicamente se mezclan con los fijos
  tags = merge(
    { Name = var.app_name, Env = var.env },
    local.service_tags
  )
}

# Archivo de configuración local generado con directivas %{if}.
# Incluye o excluye secciones enteras según el valor de var.env,
# sin necesidad de múltiples recursos ni condicionales externos.
resource "local_file" "app_config" {
  filename = "${path.module}/app.conf"
  content  = <<-EOT
    [app]
    name     = ${var.app_name}
    env      = ${var.env}
    db       = ${var.db_endpoint}

    %{ if var.env == "prod" ~}
    [security]
    tls          = true
    min_tls      = TLSv1.2
    hsts         = true
    %{ else ~}
    [security]
    tls          = false
    %{ endif ~}

    [services]
    %{ for svc in var.services ~}
    ${svc} = enabled
    %{ endfor ~}
  EOT
}
