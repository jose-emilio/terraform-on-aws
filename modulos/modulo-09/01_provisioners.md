# Sección 1 — Provisioners y Recursos Especiales

> [← Volver al índice](./README.md) | [Siguiente →](./02_expresiones_avanzadas.md)

---

## 1. ¿Qué son los Provisioners — y por qué evitarlos?

Terraform es declarativo: dices qué quieres, y él lo consigue. Los provisioners rompen esa promesa — son bloques imperativos que ejecutan comandos durante la creación o destrucción de un recurso. Son necesarios en casos que la API del provider no cubre, pero HashiCorp los considera un último recurso.

> **El profesor explica:** "Los provisioners son como el duct tape de Terraform. Funcionan, resuelven el problema inmediato, pero crean deuda técnica. Si un plan falla a mitad porque un script remoto devolvió exit 1, el recurso queda marcado como 'tainted' y la siguiente ejecución lo destruye y recrea. Si no tienes idempotencia en tus scripts, esto es una bomba de tiempo."

**Tres tipos de provisioners:**

| Provisioner | Ejecuta en | Requiere connection |
|-------------|-----------|---------------------|
| `local-exec` | Máquina donde corre Terraform | No |
| `remote-exec` | El recurso remoto (SSH/WinRM) | Sí |
| `file` | Copia archivos al recurso | Sí |

---

## 2. `local-exec` — Ejecución en el Host Local

Ejecuta un comando en la máquina donde corre `terraform apply`. Ideal para tareas de automatización local: generar archivos, invocar scripts, enviar notificaciones a Slack.

```hcl
resource "aws_instance" "web" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.micro"

  # Ejecuta al crear el recurso
  provisioner "local-exec" {
    command = "echo ${self.private_ip} >> ips.txt"
  }

  # Script con variables de entorno (más seguro que interpolación)
  provisioner "local-exec" {
    command     = "deploy.sh"
    interpreter = ["bash", "-c"]
    environment = {
      SERVER_IP = self.private_ip   # Más seguro: env var vs interpolación
    }
  }
}
```

**Parámetros clave:**
- `command` — El comando a ejecutar (requerido).
- `working_dir` — Directorio de trabajo para el comando.
- `interpreter` — Shell alternativo (`["python3", "-c"]`, etc.).
- `environment` — Variables de entorno. Preferir esto sobre interpolación en `command`.

---

## 3. `remote-exec` — Ejecución en el Recurso Remoto

Se conecta vía SSH o WinRM al recurso recién creado y ejecuta comandos directamente en él. Requiere un bloque `connection`.

```hcl
resource "aws_instance" "web" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.micro"
  key_name      = "mi-llave"

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_rsa")
    host        = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt update",
      "sudo apt install -y nginx",
      "sudo systemctl enable nginx",
    ]
  }
}
```

**Modos de ejecución:**

| Modo | Descripción |
|------|-------------|
| `inline` | Lista de comandos, cada uno se ejecuta independientemente |
| `script` | Ruta a un script local que se copia y ejecuta |
| `scripts` | Lista de scripts, se copian y ejecutan en orden |

**Regla crítica:** Si cualquier comando devuelve exit code != 0, el recurso se marca como `tainted`.

---

## 4. `file` — Transferencia de Archivos

Copia archivos o directorios desde la máquina local al recurso remoto vía SCP.

```hcl
resource "aws_instance" "app" {
  ami           = var.ami_id
  instance_type = "t3.micro"

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file("~/.ssh/key.pem")
    host        = self.public_ip
  }

  # Copiar archivo de configuración
  provisioner "file" {
    source      = "config/app.conf"
    destination = "/etc/myapp/app.conf"
  }

  # Contenido inline (no requiere archivo local)
  provisioner "file" {
    content     = "HOST=${self.private_ip}"
    destination = "/tmp/env.txt"
  }
}
```

**Limitación:** Solo se ejecuta al crear el recurso, no en actualizaciones. Si necesitas actualizar la configuración, debes forzar la recreación del recurso.

---

## 5. Bloque `connection` — Configurar Acceso Remoto

```hcl
resource "aws_instance" "web" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t2.micro"
  key_name      = "mi-llave-ssh"

  connection {
    type        = "ssh"          # "ssh" o "winrm"
    user        = "ubuntu"
    private_key = file("~/.ssh/id_rsa")
    host        = self.public_ip
    timeout     = "2m"           # Tiempo de espera para conectar
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt update",
      "sudo apt install -y nginx",
    ]
  }
}
```

**Conexión WinRM (Windows):**
```hcl
connection {
  type     = "winrm"
  user     = "Administrator"
  password = var.admin_password
  https    = true
  timeout  = "5m"
}
```

---

## 6. Ciclo de Vida: `when` y `on_failure`

### `when = destroy`

Por defecto los provisioners corren al crear. Con `when = destroy` corren al destruir — útil para deregistrar el servidor de un balanceador o enviar notificaciones.

```hcl
resource "aws_instance" "web" {
  ami           = var.ami_id
  instance_type = "t3.micro"

  # Corre al crear
  provisioner "local-exec" {
    command = "register-server.sh ${self.private_ip}"
  }

  # Corre al destruir (deregister)
  provisioner "local-exec" {
    when    = destroy
    command = "deregister-server.sh ${self.private_ip}"
  }
}
```

### `on_failure`

```hcl
# Ejemplo 1: Fallo detiene el apply (por defecto)
resource "aws_instance" "web" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = "t2.micro"

  provisioner "local-exec" {
    command    = "./scripts/validar_deploy.sh"
    on_failure = fail       # Marca recurso como tainted si falla
  }
}

# Ejemplo 2: Continuar aunque falle el provisioner
resource "aws_instance" "app" {
  ami           = var.ami_id
  instance_type = "t3.small"

  provisioner "local-exec" {
    command    = "curl -s https://hooks.slack.com/notify"
    on_failure = continue   # Ignora el error, no taints el recurso
  }
}
```

| `on_failure` | Taint recurso | Detiene apply |
|--------------|---------------|---------------|
| `fail` (default) | Sí | Sí |
| `continue` | No | No |

---

## 7. `null_resource` — Provisioner Sin Recurso Real

`null_resource` es un recurso del provider `hashicorp/null` que no gestiona infraestructura real. Es un contenedor para ejecutar provisioners controlado por `triggers`.

```hcl
terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

resource "null_resource" "deploy" {
  # Trigger: se re-ejecuta cuando image_tag cambia
  triggers = {
    image_tag = var.image_tag   # Solo acepta strings
  }

  provisioner "local-exec" {
    command = "kubectl set image deploy/app app=${var.image_tag}"
  }
}
```

**Limitaciones de `null_resource`:**
- `triggers` solo acepta strings (no objetos ni listas complejas).
- Requiere provider externo (`hashicorp/null`).
- Desde Terraform 1.4, se recomienda migrar a `terraform_data`.

---

## 8. `terraform_data` — El Reemplazo Moderno (TF 1.4+)

`terraform_data` es nativo del core de Terraform — sin provider externo. Soporta tipos de datos arbitrarios en `triggers_replace` y tiene `input`/`output` nativos.

```hcl
# No requiere provider externo
resource "terraform_data" "deploy" {
  input = var.image_tag   # Almacena el valor, accesible via output

  provisioner "local-exec" {
    command = "kubectl set image deploy/app app=${var.image_tag}"
  }
}

# Trigger con múltiples recursos (cualquier tipo)
resource "terraform_data" "bootstrap" {
  triggers_replace = [
    aws_instance.web.id,
    aws_instance.database.id,
  ]

  provisioner "local-exec" {
    command = "./scripts/bootstrap-hosts.sh"
  }
}
```

**Migración `null_resource` → `terraform_data` (TF 1.9+):**

```hcl
# Paso 1: Cambiar el recurso
resource "terraform_data" "deploy" {
  triggers_replace = { examplekey = "examplevalue" }

  provisioner "local-exec" {
    command = "echo Hello, World!"
  }
}

# Paso 2: Agregar bloque moved (Terraform >= 1.9)
moved {
  from = null_resource.deploy
  to   = terraform_data.deploy
}

# Pasos 3-6: plan → apply → eliminar moved → eliminar null provider
```

---

## 9. Alternativas Recomendadas a Provisioners

HashiCorp recomienda provisioners **solo como último recurso**. Antes de usarlos, evalúa:

| Necesidad | Alternativa declarativa |
|-----------|------------------------|
| Configurar servidor al arrancar | `user_data` + `cloud-init` en EC2 |
| Imagen pre-configurada | Packer (AMIs con software instalado) |
| Gestión de configuración | Ansible, Chef, Puppet (idempotente) |
| Extensiones Azure | `azurerm_virtual_machine_extension` |
| Notificaciones | `aws_sns_topic_subscription` + EventBridge |

---

## 10. Best Practices

1. **Usa provisioners solo como último recurso** — Si existe alternativa declarativa, úsala.
2. **Haz los scripts idempotentes** — Deben poder ejecutarse varias veces con el mismo resultado.
3. **Usa `environment` en vez de interpolación en `command`** — Evita inyección de comandos.
4. **Prefiere `terraform_data` sobre `null_resource`** en proyectos nuevos.
5. **Nunca almacenes secretos en provisioners** — Aparecen en logs y en el plan.
6. **Mantén los `inline` cortos** — Si la lógica es compleja, extrae a un script externo.
7. **Verifica conectividad de red** antes de usar `remote-exec` — Las instancias EC2 necesitan tiempo de arranque.

---

> [← Volver al índice](./README.md) | [Siguiente →](./02_expresiones_avanzadas.md)
