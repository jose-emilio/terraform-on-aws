# Laboratorio 37 — Orquestación Imperativa con terraform_data

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 9 — Terraform Avanzado](../../modulos/modulo-09/README.md)


## Visión general

Terraform es fundamentalmente **declarativo**: describes el estado deseado y el
motor calcula el plan para alcanzarlo. Sin embargo, hay tareas post-despliegue
que son inherentemente imperativas — ejecutar un script de configuración,
notificar a un sistema externo, registrar un evento — y que no encajan bien en
el modelo declarativo.

`terraform_data` (introducido en Terraform 1.4 para reemplazar `null_resource`)
es el mecanismo oficial para orquestar estas tareas imperativas sin depender de
un provider externo. Junto con los provisioners `file`, `remote-exec` y
`local-exec`, permite configurar servidores remotos directamente desde Terraform
y controlar exactamente *cuando* se vuelven a ejecutar mediante `triggers_replace`.

> **Advertencia**: los provisioners son el ultimo recurso en Terraform. Cuando
> sea posible, usa `user_data` para bootstrap inicial o SSM Run Command para
> configuración posterior. Este laboratorio los usa intencionalmente para
> entender su funcionamiento y sus limitaciones.

## Objetivos

- Entender el ciclo de vida de `terraform_data` y como difiere de los recursos
  de infraestructura convencionales.
- Usar `triggers_replace` para controlar exactamente cuando se re-ejecutan los
  provisioners.
- Subir un fichero a un servidor remoto con `provisioner "file"`.
- Definir un bloque `connection` SSH y ejecutar comandos remotos con `remote-exec`.
- Usar `provisioner "local-exec"` con `on_failure = continue` para tareas de
  registro que no deben bloquear el despliegue.
- Comprender las limitaciones de los provisioners y cuando no usarlos.

## Requisitos previos

- Terraform >= 1.5 instalado (`terraform_data`: 1.4, `postcondition`/`check`: 1.5).
- AWS CLI configurado con perfil `default`.
- Par de claves SSH generado localmente (ver Paso 0 del despliegue).
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
```

## Arquitectura

```
Maquina local (Terraform)
┌───────────────────────────────────────────────────────────┐
│                                                           │
│  terraform apply                                          │
│       │                                                   │
│       ├─► aws_key_pair        → sube clave publica a EC2  │
│       ├─► aws_security_group  → SSH (tu IP) + HTTP        │
│       ├─► aws_iam_*           → Instance Profile + SSM    │
│       ├─► aws_instance        → EC2 con IMDSv2            │
│       │                                                   │
│       └─► terraform_data.app_deploy                       │
│               │                                           │
│               │  triggers_replace: {app_version,          │
│               │                     instance_id}          │
│               │                                           │
│               ├─[connection SSH]──────────────────────┐   │
│               │                                       │   │
│               ├─► provisioner "file"                  │   │
│               │     scripts/deploy.sh → /tmp/         │   │
│               │                                       ▼   │
│               ├─► provisioner "remote-exec"     EC2 remota│
│               │     chmod + sudo APP_VERSION=... ./deploy │
│               │                                       │   │
│               └─► provisioner "local-exec"            │   │
│                     on_failure = continue             │   │
│                     >> deployment.log                 │   │
│                                                       │   │
└───────────────────────────────────────────────────────┼───┘
                                                        │
                              nginx activo en puerto 80 │
                              /version.json con la      │
                              version desplegada ◄──────┘
```

## Conceptos clave

### `terraform_data`

Es un recurso del provider `terraform` integrado — no necesita bloque
`required_providers`. Su único propósito es agrupar provisioners y disparar su
ejecución de forma controlada.

Tiene dos atributos principales:

| Atributo | Uso |
|---|---|
| `triggers_replace` | Mapa de valores cuyo cambio fuerza la *destrucción y recreación* del recurso (y re-ejecución de provisioners) |
| `input` | Almacena valores arbitrarios; accesibles en outputs via `output` |

```hcl
resource "terraform_data" "ejemplo" {
  triggers_replace = {
    version = var.app_version   # Cambia esto → provisioners vuelven a correr
  }
}
```

### Por que `triggers_replace` y no `triggers`

`null_resource` usaba `triggers` (un mapa de strings). `terraform_data` usa
`triggers_replace`, que es conceptualmente mas honesto: cuando cambia el valor,
el recurso se **reemplaza** — primero se ejecutan los provisioners de destruccion
(`when = destroy`) y luego los de creacion. Esto hace el ciclo de vida explicito.

### Provisioner `file`

Transfiere un fichero o directorio desde la maquina local al servidor remoto
via SSH (o WinRM). La conexión la define el bloque `connection` del recurso padre.

```hcl
provisioner "file" {
  source      = "${path.module}/../scripts/deploy.sh"  # Ruta local
  destination = "/tmp/deploy.sh"                        # Ruta en el servidor
}
```

**Limitaciones**:
- El directorio destino debe existir.
- El usuario de la conexión debe tener permiso de escritura en el destino.
- `/tmp` es siempre seguro para `ec2-user`.

### Provisioner `remote-exec`

Ejecuta comandos en el servidor remoto via SSH. Tiene tres modos:

| Modo | Descripción |
|---|---|
| `inline` | Lista de comandos ejecutados en orden con `/bin/sh -c` |
| `script` | Sube un script local y lo ejecuta (equivale a `file` + `inline`) |
| `scripts` | Como `script` pero con múltiples ficheros en orden |

```hcl
provisioner "remote-exec" {
  inline = [
    "chmod +x /tmp/deploy.sh",
    "sudo APP_VERSION=${var.app_version} /tmp/deploy.sh",
  ]
}
```

Si cualquier comando devuelve un codigo de salida distinto de 0, el provisioner
falla y el recurso queda marcado como *tainted* — Terraform lo recrea en el
siguiente apply.

### Bloque `connection`

Define el canal de comunicación entre Terraform y el servidor remoto. Cuando se
declara a nivel de recurso, todos los provisioners del recurso lo heredan.

```hcl
connection {
  type        = "ssh"
  host        = aws_instance.web.public_ip
  user        = "ec2-user"
  private_key = file(var.ssh_private_key_path)
  timeout     = "5m"  # Tiempo de espera mientras la instancia arranca
}
```

El parámetro `timeout` es crítico: una instancia EC2 recien creada tarda 1-2
minutos en que cloud-init arranque sshd. Sin un timeout suficiente, el
provisioner fallara antes de que el servidor este listo.

### Provisioner `local-exec`

Ejecuta un comando en la **maquina que corre Terraform** (no en el servidor
remoto). Util para:
- Registrar eventos en logs locales o sistemas externos.
- Invocar scripts de notificación (Slack, PagerDuty...).
- Actualizar inventarios de CMDB.

```hcl
provisioner "local-exec" {
  on_failure  = continue   # Si falla, advertencia en lugar de error
  interpreter = ["/bin/bash", "-c"]
  command     = "echo '...' >> deployment.log"
}
```

**`on_failure`** puede ser:
- `fail` (defecto): un fallo aborta el apply y *taint*-ea el recurso.
- `continue`: el fallo se registra como advertencia y el apply prosigue.

Usa `continue` únicamente para operaciones de registro o notificación que no
son críticas para el estado de la infraestructura.

### `self` dentro de provisioners

Dentro de un bloque `provisioner`, `self` referencia el recurso que contiene
el provisioner. En `terraform_data`, permite acceder a los valores de
`triggers_replace` sin crear dependencias circulares:

```hcl
# En un provisioner de terraform_data.app_deploy:
"version=${self.triggers_replace.app_version}"
```

### El problema del estado de los provisioners

Terraform **no conoce el resultado** de un provisioner — solo sabe si termino
con exito o con error. Si el provisioner `remote-exec` se ejecuto correctamente
pero el servidor fallo mas tarde, Terraform no lo detecta. Por eso:

- Incluye validaciones en el propio script (`set -euo pipefail`, checks de HTTP).
- Usa `output` para exponer URLs verificables post-apply.
- Considera complementar con healthchecks externos (ALB, Route53 health check).

## Estructura del proyecto

```
lab37/
├── aws/
│   ├── providers.tf          # Terraform >= 1.4 + provider AWS ~> 6.0
│   ├── variables.tf          # region, project, app_version, ssh_*, instance_type
│   ├── main.tf               # AMI, key pair, SG, IAM, EC2, terraform_data
│   ├── outputs.tf            # IPs, URLs, version desplegada, comando SSH
│   └── aws.s3.tfbackend      # Configuracion parcial del backend S3
├── scripts/
│   └── deploy.sh             # Script subido via "file" y ejecutado via "remote-exec"
└── README.md
```

## Despliegue en AWS real

### Paso 0 — Generar el par de claves SSH

```bash
# Genera un par de claves ed25519 sin passphrase (para uso automatizado)
ssh-keygen -t ed25519 -f ~/.ssh/lab37_key -N ""

# Verificar que se crearon ambos ficheros:
ls -la ~/.ssh/lab37_key ~/.ssh/lab37_key.pub
```

La clave privada (`lab37_key`) nunca sale de tu maquina. Terraform sube solo la
publica (`lab37_key.pub`) a AWS como `aws_key_pair`.

### Paso 1 — Obtener tu IP para restringir SSH

```bash
# Obtener tu IP publica actual
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "Tu IP: ${MY_IP}"
```

Abrir el puerto 22 a `0.0.0.0/0` es funcional pero inseguro. Restringirlo a tu
IP elimina la exposicion a scanners automaticos de Internet.

### Paso 2 — Inicializar y desplegar

```bash
cd labs/lab37/aws

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
export MY_IP=$(curl -s https://checkip.amazonaws.com)

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

terraform plan \
  -var="ssh_allowed_cidr=${MY_IP}/32"

terraform apply \
  -var="ssh_allowed_cidr=${MY_IP}/32"
```

**Durante el apply**, observa la secuencia de mensajes:

```
aws_key_pair.lab: Creating...
aws_security_group.web: Creating...
aws_iam_role.ec2: Creating...
...
aws_instance.web: Creation complete after 15s
terraform_data.app_deploy: Creating...
terraform_data.app_deploy: Provisioning with 'file'...
terraform_data.app_deploy: Provisioning with 'remote-exec'...
terraform_data.app_deploy (remote-exec): [2024-...] Iniciando despliegue v1.0.0
terraform_data.app_deploy (remote-exec): [2024-...] Actualizando paquetes...
terraform_data.app_deploy (remote-exec): [2024-...] Instalando nginx...
terraform_data.app_deploy (remote-exec): [2024-...] Despliegue v1.0.0 completado
terraform_data.app_deploy: Provisioning with 'local-exec'...
terraform_data.app_deploy: Creation complete
```

El apply tarda aproximadamente 3-4 minutos: 1-2 min para que la instancia
arranque sshd y 1-2 min para el script de configuración.

## Verificación final

### Comprobar la aplicacion desplegada

```bash
PUBLIC_IP=$(terraform output -raw public_ip)

# Pagina principal con la version
curl http://${PUBLIC_IP}
# Esperado: HTML con version 1.0.0

# Endpoint JSON de version (para healthchecks automaticos)
curl http://${PUBLIC_IP}/version.json
# Esperado: {"project":"lab37","version":"1.0.0","deployed_at":"..."}
```

### Verificar el log de despliegue local

```bash
# El local-exec escribe en deployment.log en el directorio desde donde ejecutas terraform
cat deployment.log
# Esperado: 2024-...T...Z | version=1.0.0 | instance=i-0abc... | ip=54.xx.xx.xx
```

### Conectarse al servidor y revisar el log remoto

```bash
# Usar el comando SSH del output
$(terraform output -raw ssh_command)

# Una vez dentro, ver el log del script de despliegue
sudo cat /var/log/lab37-deploy.log
sudo systemctl status nginx
```

### Probar triggers_replace — redespliegue sin cambiar la instancia

Cambia la versión de la aplicación y aplica de nuevo:

```bash
terraform apply \
  -var="ssh_allowed_cidr=${MY_IP}/32" \
  -var="app_version=2.0.0"
```

Terraform mostrara:

```
terraform_data.app_deploy: Destroying...  ← se destruye el recurso anterior
terraform_data.app_deploy: Destruction complete
terraform_data.app_deploy: Creating...    ← se crea uno nuevo
terraform_data.app_deploy: Provisioning with 'file'...
terraform_data.app_deploy: Provisioning with 'remote-exec'...
terraform_data.app_deploy (remote-exec): [2024-...] Iniciando despliegue v2.0.0
...
```

La instancia EC2 NO se modifica — solo `terraform_data` se recrea. Al finalizar:

```bash
curl http://$(terraform output -raw public_ip)/version.json
# Esperado: {"version":"2.0.0",...}

cat deployment.log
# Esperado: dos lineas, una por cada version desplegada
```

## Retos

### Reto 1 — Historial de versiones desplegadas con `terraform_data` e `input`/`output`

Actualmente `terraform_data.app_deploy` solo usa `triggers_replace`. El recurso
tiene un segundo atributo — `input` — que permite almacenar valores arbitrarios
en el estado y recuperarlos despues via `output`.

**Objetivo**: construir un historial de las ultimas versiones desplegadas
combinando `input`/`output` de `terraform_data` con un fichero local que
persiste entre ejecuciones.

Implementa lo siguiente en `main.tf` y `outputs.tf`:

1. Añade un `local` llamado `previous_version` que lea el contenido del fichero
   `aws/.last_version` con la función `file()`. Usa `try()` para devolver
   `"none"` si el fichero no existe aun (primer despliegue).

2. Añade un segundo recurso `terraform_data` llamado `version_history` cuyo
   `input` sea un objeto con `current = var.app_version` y
   `previous = local.previous_version`.

3. Añade un `provisioner "local-exec"` en ese recurso que escriba `var.app_version`
   en el fichero `.last_version` al finalizar cada apply exitoso.

4. Añade un output `version_history` que exponga `terraform_data.version_history.output`.

**Por que no se puede usar una auto-referencia**: Terraform resuelve el grafo
de dependencias en la fase de plan. Si un recurso se referenciara a si mismo
(`terraform_data.version_history.output.current` dentro del mismo recurso),
se crearia un ciclo que el motor no puede resolver — de ahi el error
`Self-referential block`. El fichero local rompe el ciclo: `file()` es una
función que se evalúa en local antes del plan, sin depender del grafo.

#### Prueba

```bash
# Primer despliegue (el fichero .last_version no existe aun)
terraform apply -var="ssh_allowed_cidr=${MY_IP}/32" -var="app_version=1.0.0"
terraform output version_history
# Esperado: { current = "1.0.0", previous = "none" }

# El local-exec ha escrito "1.0.0" en aws/.last_version
cat aws/.last_version

# Segundo despliegue
terraform apply -var="ssh_allowed_cidr=${MY_IP}/32" -var="app_version=2.0.0"
terraform output version_history
# Esperado: { current = "2.0.0", previous = "1.0.0" }

# Tercer despliegue
terraform apply -var="ssh_allowed_cidr=${MY_IP}/32" -var="app_version=3.0.0"
terraform output version_history
# Esperado: { current = "3.0.0", previous = "2.0.0" }
```

---

### Reto 2 — Verificación del despliegue con `postcondition` y `check`

Actualmente Terraform no tiene forma de saber si `deploy.sh` dejo la aplicacion
funcionando correctamente — solo sabe que el provisioner termino sin error.
Un script puede completarse con exit 0 y aun asi dejar nginx caido si las
verificaciones internas no son suficientes.

Terraform ofrece dos mecanismos nativos para verificar el estado real de la
infraestructura despues de un apply:

- **`postcondition`**: se evalua dentro del bloque `lifecycle` de un recurso.
  Si falla, el apply se considera erroneo y el recurso queda marcado como
  tainted. Se ejecuta despues de crear o actualizar el recurso.
- **`check`**: bloque de nivel raiz (fuera de cualquier recurso). Se evalua
  al final del apply. Si falla, emite una advertencia pero **no** aborta el
  apply ni tainta el recurso — util para healthchecks que no deben bloquear.

**Objetivo**: añade ambos mecanismos a `main.tf`:

1. Un bloque `lifecycle { postcondition {} }` en `aws_instance.web` que
   verifique que la instancia tiene IP publica asignada antes de que
   `terraform_data` intente conectarse via SSH.

2. Un bloque `check` de nivel raiz que haga una peticion HTTP a
   `http://<public_ip>/version.json` y verifique que la respuesta contiene
   la versión actualmente desplegada (`var.app_version`). Usa un
   `data "http"` para la peticion.

**Pistas**:
- El provider `http` necesita declararse en `required_providers`:
  `hashicorp/http ~> 3.0`.
- `data "http"` devuelve el cuerpo de la respuesta en `response_body`.
  La función `strcontains()` permite verificar que contiene un substring.
- En el bloque `check`, el `data source` se declara dentro del propio bloque.

#### Prueba

```bash
terraform apply -var="ssh_allowed_cidr=${MY_IP}/32" -var="app_version=2.0.0"
# Al final del apply debe aparecer:
# Check block "healthcheck_version" passed.  ← si nginx responde con la version correcta
# o:
# Warning: Check block assertion failed      ← si nginx no esta listo aun (race condition)
```

## Soluciones

<details>
<summary>Reto 1 — Historial de versiones con terraform_data input/output</summary>

Añade en `main.tf`:

```hcl
locals {
  # file() se evalua en local antes del plan — no participa en el grafo
  # de dependencias, por lo que no crea ciclos.
  # try() devuelve "none" si el fichero no existe aun (primer despliegue).
  previous_version = try(trimspace(file("${path.module}/.last_version")), "none")
}

resource "terraform_data" "version_history" {
  # input se evalua durante el plan con los valores actuales de las variables
  # y del fichero local. Terraform lo persiste en el estado como "output"
  # una vez que el apply termina con exito.
  input = {
    current  = var.app_version
    previous = local.previous_version
  }

  # Despues de cada apply exitoso, escribe la version actual en el fichero.
  # El proximo plan leerá este valor como "previous" via local.previous_version.
  provisioner "local-exec" {
    command = "printf '%s' '${var.app_version}' > '${path.module}/.last_version'"
  }
}
```

Añade en `outputs.tf`:

```hcl
output "version_history" {
  description = "Version actual y version desplegada anteriormente"
  value       = terraform_data.version_history.output
}
```

Añade `.last_version` al `.gitignore` del repositorio para no versionar el
fichero de estado local:

```bash
echo "labs/lab37/aws/.last_version" >> .gitignore
```

**Por que funciona — flujo entre ejecuciones**:

```
Apply 1.0.0                          Apply 2.0.0
─────────────────────────────────────────────────────────────
Plan:                                Plan:
  local.previous_version = "none"      local.previous_version = "1.0.0"
  input = { current="1.0.0"           input = { current="2.0.0"
             previous="none" }                   previous="1.0.0" }
         │                                      │
         ▼ apply                                ▼ apply
  output = { current="1.0.0"          output = { current="2.0.0"
              previous="none" }                   previous="1.0.0" }
         │                                      │
         ▼ local-exec                           ▼ local-exec
  .last_version = "1.0.0"             .last_version = "2.0.0"
```

`file()` lee el fichero *antes* del plan — siempre contiene el valor escrito
por el `local-exec` del apply anterior. Si el apply falla antes de llegar al
`local-exec`, el fichero no se actualiza y el siguiente plan seguira viendo
la versión anterior correcta.

**Verificacion**:

```bash
# Primer despliegue
terraform apply -var="ssh_allowed_cidr=${MY_IP}/32" -var="app_version=1.0.0"
terraform output version_history
# { "current" = "1.0.0", "previous" = "none" }
cat .last_version   # 1.0.0

# Segundo despliegue
terraform apply -var="ssh_allowed_cidr=${MY_IP}/32" -var="app_version=2.0.0"
terraform output version_history
# { "current" = "2.0.0", "previous" = "1.0.0" }

# Ver lo que Terraform guarda en el estado
terraform state show terraform_data.version_history
```

**Limitacion**: el fichero `.last_version` es local a la maquina que ejecuta
Terraform. En un equipo con backend remoto, cada miembro tendría su propio
fichero. Para un historial compartido, la alternativa es persistir la versión
en SSM Parameter Store con `aws_ssm_parameter` y leerla con un `data source`
en el siguiente plan.

</details>

<details>
<summary>Reto 2 — Verificacion del despliegue con postcondition y check</summary>

**Paso 1 — Declarar el provider `http` en `providers.tf`**:

```hcl
terraform {
  required_version = ">= 1.4"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
  backend "s3" {}
}
```

**Paso 2 — `postcondition` en `aws_instance.web`**:

Añade un bloque `lifecycle` al recurso `aws_instance.web`:

```hcl
resource "aws_instance" "web" {
  # ... resto de argumentos sin cambios ...

  lifecycle {
    create_before_destroy = true

    # postcondition se evalua despues de crear o actualizar el recurso.
    # Si falla, el apply falla y el recurso queda tainted — se recrea
    # en el siguiente apply.
    # Aqui verificamos que la instancia tiene IP publica antes de que
    # terraform_data intente abrir la conexion SSH.
    postcondition {
      condition     = self.public_ip != ""
      error_message = "La instancia ${self.id} no tiene IP publica asignada. Verifica que associate_public_ip_address = true y que la subred tiene auto-assign IP habilitado."
    }
  }
}
```

`self` dentro de `postcondition` referencia el recurso al que pertenece el
bloque `lifecycle` — en este caso `aws_instance.web`. Es la única excepción
en Terraform donde `self` esta disponible fuera de un provisioner.

**Paso 3 — bloque `check` de nivel raiz**:

```hcl
# check se evalua al FINAL del apply, despues de que todos los recursos
# esten creados. Usa un data source interno para hacer la peticion HTTP.
# Si el assert falla, emite una advertencia pero NO aborta el apply
# ni tainta ningun recurso — ideal para healthchecks post-despliegue.
check "healthcheck_version" {
  data "http" "version_json" {
    url = "http://${aws_instance.web.public_ip}/version.json"
  }

  assert {
    condition = data.http.version_json.status_code == 200
    error_message = "El endpoint /version.json respondio con HTTP ${data.http.version_json.status_code} en lugar de 200."
  }

  assert {
    condition     = strcontains(data.http.version_json.response_body, var.app_version)
    error_message = "La respuesta de /version.json no contiene la version '${var.app_version}'. Puede que el despliegue no haya terminado aun."
  }
}
```

**Diferencia clave entre `postcondition` y `check`**:

| | `postcondition` | `check` |
|---|---|---|
| Ubicacion | Dentro de `lifecycle {}` de un recurso | Bloque raiz independiente |
| Cuando se evalua | Justo despues de crear/actualizar ese recurso | Al final del apply, tras todos los recursos |
| Si falla | Apply falla, recurso tainted | Advertencia, apply continua |
| Acceso a recursos | Solo `self` | Cualquier recurso o data source |
| Uso tipico | Invariantes del recurso (IP asignada, ARN valido) | Healthchecks externos, validaciones E2E |

**Verificacion**:

```bash
terraform init   # necesario para descargar el provider http
terraform apply -var="ssh_allowed_cidr=${MY_IP}/32" -var="app_version=2.0.0"

# Salida esperada al final del apply:
# ...
# Check block "healthcheck_version":
#   "healthcheck_version" passed.   ← ambos asserts OK

# Si nginx aun no ha arrancado cuando check se evalua:
# Warning: Check block assertion failed
#   The endpoint /version.json respondio con HTTP 000 ...
# (no es un error — el apply termina correctamente)
```

</details>

## Limpieza

```bash
cd labs/lab37/aws

terraform destroy \
  -var="ssh_allowed_cidr=${MY_IP}/32"

# Borrar el log local de despliegues (opcional)
rm -f deployment.log
```

## Buenas prácticas aplicadas

- **Provisioners como ultimo recurso**: el lab los usa para aprender su
  funcionamiento, pero en producción prefiere `user_data` para el bootstrap
  inicial y SSM Run Command o Ansible para configuración posterior.
- **`timeout` en `connection`**: evita que el apply falle si sshd no esta listo
  inmediatamente. Un timeout de 5 minutos cubre la mayoria de escenarios de
  arranque lento.
- **SSH restringido por IP**: `ssh_allowed_cidr` permite abrir el puerto 22 solo
  desde la IP del operador, no desde todo Internet.
- **`on_failure = continue` solo para tareas no criticas**: el log local y el
  webhook son operaciones de observabilidad; un fallo en ellas no debe impedir
  el despliegue de la infraestructura.
- **IMDSv2 obligatorio**: `http_tokens = "required"` en la instancia previene
  ataques SSRF contra el metadata service.
- **`triggers_replace` con `instance_id`**: garantiza que si la instancia se
  reemplaza (por un `taint` o un cambio de AMI), los provisioners se vuelven a
  ejecutar automáticamente sobre la nueva instancia.
- **Endpoint `/version.json`**: expone la versión actualmente desplegada en un
  formato machine-readable, util para healthchecks automaticos y verificacion
  post-despliegue.

## Recursos

- [terraform_data — Documentacion oficial](https://developer.hashicorp.com/terraform/language/resources/terraform-data)
- [Provisioners — Documentacion oficial](https://developer.hashicorp.com/terraform/language/provisioners)
- [Provisioner file](https://developer.hashicorp.com/terraform/language/provisioners)
- [Provisioner remote-exec](https://developer.hashicorp.com/terraform/language/provisioners)
- [Provisioner local-exec](https://developer.hashicorp.com/terraform/language/provisioners)
- [Bloque connection](https://developer.hashicorp.com/terraform/language/provisioners)
- [Migracion de null_resource a terraform_data](https://developer.hashicorp.com/terraform/language/resources/terraform-data#migration-from-null_resource)
