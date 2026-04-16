# ── Data sources ─────────────────────────────────────────────────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Par de claves SSH ─────────────────────────────────────────────────────────
# La clave publica se sube a AWS; la privada permanece solo en tu maquina.
# Genera el par antes del primer apply:
#   ssh-keygen -t ed25519 -f ~/.ssh/lab37_key -N ""
resource "aws_key_pair" "lab" {
  key_name   = "${var.project}-key"
  public_key = file("${var.ssh_private_key_path}.pub")

  tags = {
    Name    = "${var.project}-key"
    Project = var.project
  }
}

# ── Security Group ────────────────────────────────────────────────────────────
resource "aws_security_group" "web" {
  name        = "${var.project}-web-sg"
  description = "HTTP publico + SSH restringido para el provisioner de Terraform"

  tags = {
    Name    = "${var.project}-web-sg"
    Project = var.project
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.web.id
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.ssh_allowed_cidr
  description       = "SSH para terraform provisioner - restringir a tu IP"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP publico para verificar el despliegue"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Todo el trafico saliente (dnf update, etc.)"
}

# ── IAM Instance Profile ──────────────────────────────────────────────────────
# Permite gestion via SSM Session Manager como alternativa al SSH
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name    = "${var.project}-ec2-role"
    Project = var.project
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Name    = "${var.project}-ec2-profile"
    Project = var.project
  }
}

# ── Instancia EC2 ─────────────────────────────────────────────────────────────
resource "aws_instance" "web" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.lab.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true

  # IMDSv2 obligatorio: previene ataques SSRF contra el metadata service
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name    = "${var.project}-web"
    Project = var.project
  }
}

# ── terraform_data: orquestacion imperativa post-despliegue ───────────────────
#
# terraform_data es un recurso del provider "terraform" integrado (sin bloque
# required_providers). Sustituye a null_resource desde Terraform 1.4 con
# dos mejoras clave:
#   - triggers_replace: reemplaza el recurso (destruye + crea) cuando cambia
#     cualquier valor del mapa, disparando todos los provisioners de nuevo.
#   - input / output: permite almacenar y recuperar valores arbitrarios.
#
# Cuando se reemplaza el recurso, los provisioners se ejecutan en orden:
#   1. file      → sube el script al servidor
#   2. remote-exec → ejecuta el script
#   3. local-exec  → registra el despliegue en un log local
resource "terraform_data" "app_deploy" {

  # triggers_replace: cualquier cambio en estos valores destruye y recrea
  # este recurso, forzando la re-ejecucion de todos los provisioners.
  #   - app_version: permite redesplegar la aplicacion sin tocar la instancia.
  #   - instance_id: garantiza que si la instancia se reemplaza, los
  #     provisioners se vuelven a ejecutar automaticamente sobre la nueva.
  triggers_replace = {
    app_version = var.app_version
    instance_id = aws_instance.web.id
  }

  # Bloque connection: define como Terraform abre el canal SSH.
  # Se aplica a todos los provisioners que no declaren su propio connection.
  # timeout: tiempo maximo que Terraform espera a que la instancia acepte SSH
  # (cloud-init puede tardar 1-2 min en arrancar sshd en una instancia nueva).
  connection {
    type        = "ssh"
    host        = aws_instance.web.public_ip
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  # Paso 1 — provisioner "file": sube el script al servidor remoto.
  # - source:      ruta local al fichero (relativa a path.module)
  # - destination: ruta absoluta en el servidor remoto
  # Nota: el directorio destino debe existir y el usuario debe tener permiso
  # de escritura. /tmp siempre es valido para ec2-user.
  provisioner "file" {
    source      = "${path.module}/../scripts/deploy.sh"
    destination = "/tmp/deploy.sh"
  }

  # Paso 2 — provisioner "remote-exec": ejecuta comandos en el servidor.
  # Se conecta via SSH usando el bloque connection del recurso.
  # inline: lista de comandos ejecutados en orden con un interprete /bin/sh.
  # La version de la aplicacion se pasa como variable de entorno al script.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/deploy.sh",
      "sudo APP_VERSION=${var.app_version} PROJECT=${var.project} /tmp/deploy.sh",
    ]
  }

  # Paso 3 — provisioner "local-exec": registra el despliegue en la maquina
  # que ejecuta Terraform (no en el servidor remoto).
  #
  # on_failure = continue: si el comando falla (por ejemplo, el fichero
  # deployment.log esta bloqueado por otra escritura concurrente), Terraform
  # registra el error como advertencia y continua el apply sin abortar.
  # Sin este parametro, un fallo aqui rollbackearia todo el despliegue.
  #
  # self.triggers_replace: referencia a los valores del mapa triggers_replace
  # del propio recurso terraform_data. Permite acceder a app_version e
  # instance_id sin crear dependencias circulares.
  provisioner "local-exec" {
    on_failure  = continue
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | version=${self.triggers_replace.app_version} | instance=${self.triggers_replace.instance_id} | ip=${aws_instance.web.public_ip}" \
        >> deployment.log
      echo "Despliegue registrado en deployment.log"
    EOT
  }
}
