#!/bin/bash
# BeforeInstall: elimina los ficheros que CodeDeploy va a copiar para evitar
# el error "file already exists". En despliegues sucesivos borra la version
# anterior antes de instalar la nueva.
rm -f /var/www/html/index.html /var/www/html/health /var/www/html/image.png
