# Laboratorio 0 — Entorno de Desarrollo Remoto con VSCode en EC2

[← Módulo 1 — Fundamentos de Infraestructura como Código y Terraform](../../modulos/modulo-01/README.md)


## Visión general

En este laboratorio preliminar lanzarás manualmente una instancia EC2 con **Amazon Linux 2023 (ARM64)** e instalarás **code-server** para usar VSCode como IDE remoto desde el navegador de tu máquina local. Esto te permitirá trabajar en los laboratorios del curso directamente desde la nube.

## Requisitos Previos

- Cuenta de AWS con permisos para crear instancias EC2 y Security Groups
- Acceso a la consola de AWS ([console.aws.amazon.com](https://console.aws.amazon.com))

---

## 1. Crear un Par de Claves SSH

1. En la consola de AWS, ve a **EC2 → Network & Security → Key Pairs**
2. Haz clic en **Create key pair**
3. Configura:
   - **Name:** `vscode-ide-key`
   - **Key pair type:** RSA
   - **Private key file format:** `.pem`
4. Haz clic en **Create key pair** — el archivo `.pem` se descargará automáticamente
5. Mueve el archivo a un lugar seguro y ajusta sus permisos:

```bash
mkdir -p ~/.ssh
mv ~/Downloads/vscode-ide-key.pem ~/.ssh/
chmod 400 ~/.ssh/vscode-ide-key.pem
```

---

## 2. Crear un Rol IAM para la Instancia

La instancia necesita permisos para desplegar infraestructura con Terraform. En lugar de configurar credenciales estáticas, se asigna un **Instance Profile** con un rol IAM — las credenciales se rotan automáticamente y nunca se almacenan en disco.

1. Ve a **IAM → Roles → Create role**
2. Configura:
   - **Trusted entity type:** AWS service
   - **Use case:** EC2
3. Haz clic en **Next**
4. En **Permissions policies**, busca y selecciona `AdministratorAccess`
5. Haz clic en **Next**
6. En **Role name**, escribe `vscode-ide-role`
7. Haz clic en **Create role**

---

## 3. Crear un Security Group

1. Ve a **EC2 → Network & Security → Security Groups**
2. Haz clic en **Create security group**
3. Configura:
   - **Security group name:** `vscode-ide-sg`
   - **Description:** `Acceso SSH y VSCode remoto`
4. En **Inbound rules**, añade una única regla:

| Type | Protocol | Port | Source | Description |
|------|----------|------|--------|-------------|
| SSH | TCP | 22 | My IP | Acceso SSH |

> El puerto 8080 no se abre: el acceso al IDE se hará a través de un túnel SSH cifrado, sin exponer el puerto a internet.

5. Haz clic en **Create security group**

---

## 4. Lanzar la Instancia EC2

1. Ve a **EC2 → Instances → Launch instances**
2. Configura los siguientes campos:

**Name and tags**
- **Name:** `vscode-ide`

**Application and OS Images (AMI)**
- Haz clic en **Browse more AMIs**
- Busca `Amazon Linux 2023`
- Selecciona **Amazon Linux 2023 AMI** — asegúrate de elegir la arquitectura **64-bit (Arm)**

**Instance type**
- Selecciona `t4g.large`

> `t4g` usa procesadores **Graviton (ARM64)**. Es obligatorio seleccionar la AMI ARM64 — una AMI x86_64 no arrancará en este tipo de instancia.

**Key pair**
- Selecciona `vscode-ide-key`

**Network settings**
- Haz clic en **Select existing security group**
- Selecciona `vscode-ide-sg`

**Configure storage**
- Deja el valor por defecto (8 GiB gp3)

**Advanced details**
- En **IAM instance profile**, selecciona `vscode-ide-role`

3. Haz clic en **Launch instance**

---

## 5. Asignar una IP Elástica

Una IP elástica es una IP pública fija asociada a tu cuenta. Al detener y volver a arrancar la instancia, la IP no cambia, por lo que no tendrás que actualizar tu comando SSH ni la URL del IDE.

1. Ve a **EC2 → Network & Security → Elastic IPs**
2. Haz clic en **Allocate Elastic IP address**
3. Deja la configuración por defecto y haz clic en **Allocate**
4. Selecciona la IP recién creada y haz clic en **Actions → Associate Elastic IP address**
5. Configura:
   - **Resource type:** Instance
   - **Instance:** selecciona `vscode-ide`
6. Haz clic en **Associate**

A partir de ahora usa siempre esta IP para conectarte, tanto por SSH como en el navegador.

> Una IP elástica es gratuita mientras esté asociada a una instancia en ejecución. Si la instancia está **detenida** o la IP está **sin asociar**, se aplica un pequeño cargo por hora.

---

## 6. Conectarse a la Instancia por SSH

Espera a que el estado de la instancia sea **Running** y las comprobaciones de estado muestren **2/2 checks passed**.

Obtén la IP elástica desde la consola y conéctate:

```bash
ssh -i ~/.ssh/vscode-ide-key.pem ec2-user@<IP_PUBLICA>
```

---

## 7. Instalar code-server

Una vez dentro de la instancia, ejecuta:

```bash
# Instalar code-server con el script oficial de Coder
curl -fsSL https://code-server.dev/install.sh | sh

# Configurar: escuchando solo en localhost (no expuesto a internet)
mkdir -p ~/.config/code-server
cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: 127.0.0.1:8080
auth: none
cert: false
EOF

# Habilitar e iniciar el servicio
sudo systemctl enable --now code-server@ec2-user
```

Verifica que el servicio está activo:

```bash
sudo systemctl status code-server@ec2-user
```

---

## 8. Acceder a VSCode mediante Túnel SSH

El túnel SSH redirige el puerto 8080 de la instancia a tu máquina local a través de la conexión SSH cifrada. El puerto nunca queda expuesto en internet.

Desde tu máquina local, abre una terminal y ejecuta:

```bash
ssh -i ~/.ssh/vscode-ide-key.pem -L 8080:localhost:8080 -N ec2-user@<IP_ELASTICA>
```

| Flag | Significado |
|------|-------------|
| `-L 8080:localhost:8080` | Redirige el puerto local 8080 al puerto 8080 de la instancia |
| `-N` | No ejecuta ningún comando remoto, solo mantiene el túnel abierto |

Deja esta terminal abierta mientras uses el IDE. Luego abre en el navegador:

```
http://localhost:8080
```

Verás la interfaz completa de VSCode. Todo el tráfico viaja cifrado por SSH.

---

## 9. Instalar el Plugin de Terraform

1. En la barra lateral de VSCode, haz clic en el icono de **Extensiones** (o `Ctrl+Shift+X`)
2. Busca `HashiCorp Terraform`
3. Haz clic en **Install**

La extensión proporciona:
- Resaltado de sintaxis HCL
- Autocompletado de recursos y atributos
- Validación en tiempo real
- Navegación entre referencias

---

## 10. Instalar Terraform en la Instancia

Desde la terminal integrada de VSCode (`Ctrl+ñ` o **Terminal → New Terminal**):

```bash
# Añadir el repositorio oficial de HashiCorp
sudo dnf install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo

# Instalar Terraform
sudo dnf install -y terraform

# Verificar
terraform -version
```

---

## 11. Destruir los Recursos al Terminar

> La instancia `t4g.large` genera costos mientras esté en ejecución. Libera también la IP elástica: si queda sin asociar se cobra igualmente.

1. Ve a **EC2 → Network & Security → Elastic IPs**, selecciona la IP, haz clic en **Actions → Disassociate Elastic IP address** y luego **Actions → Release Elastic IP address**
2. Ve a **EC2 → Instances**, selecciona `vscode-ide` y haz clic en **Instance state → Terminate instance**
3. Elimina el Security Group y el Key Pair desde sus respectivas secciones en la consola

---

## Verificación final

Comprueba que el entorno queda operativo antes de iniciar los laboratorios:

```bash
# Confirmar que Terraform está instalado
terraform -version

# Confirmar que el servicio code-server está activo
sudo systemctl status code-server@ec2-user

# Confirmar que el túnel SSH está activo abriendo en el navegador
# http://localhost:8080
```

| Recurso | Valor |
|---------|-------|
| AMI | Amazon Linux 2023 ARM64 |
| Tipo de instancia | `t4g.large` (Graviton) |
| Rol IAM | `vscode-ide-role` (`AdministratorAccess`) |
| Puerto IDE | `8080` (solo en localhost, acceso vía túnel SSH) |
| IDE | code-server (VSCode en el navegador) |
| Plugin instalado | HashiCorp Terraform |

---

## Buenas prácticas aplicadas

- **Usa un Instance Profile en lugar de credenciales estáticas**: asignar un rol IAM a la instancia evita almacenar claves de acceso en disco. Las credenciales temporales se rotan automáticamente y nunca quedan expuestas en el sistema de archivos.
- **Restringe el Security Group a tu IP**: la regla de ingress SSH solo permite el acceso desde tu IP pública. Evita usar `0.0.0.0/0` en el puerto 22.
- **Túnel SSH en lugar de abrir el puerto 8080**: code-server escucha en `127.0.0.1:8080` y el acceso se hace mediante reenvío de puertos SSH (`-L`). El tráfico viaja cifrado y el puerto nunca queda expuesto a internet.
- **IP elástica para una IP fija**: sin una IP elástica, la IP pública cambia cada vez que la instancia se detiene. La IP elástica garantiza que el comando SSH y la configuración del túnel no cambian entre sesiones.
- **Libera la IP elástica al terminar**: una IP elástica sin asociar genera costos. Desasocia y libera la IP antes de terminar el laboratorio.

---

## Recursos

- [Documentación de code-server](https://coder.com/docs/code-server)
- [Amazon EC2 Instance Types: t4g](https://aws.amazon.com/ec2/instance-types/t4/)
- [Amazon Linux 2023](https://docs.aws.amazon.com/linux/al2023/ug/what-is-amazon-linux.html)
- [Elastic IP Addresses](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html)
- [IAM Instance Profiles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html)
- [Extensión HashiCorp Terraform para VSCode](https://marketplace.visualstudio.com/items?itemName=HashiCorp.terraform)
