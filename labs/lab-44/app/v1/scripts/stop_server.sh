#!/bin/bash
# ApplicationStop: detiene Apache si esta en ejecucion.
# Este hook se ejecuta en las instancias EXISTENTES antes de instalar la nueva
# version. En un primer despliegue sobre instancias recien creadas, Apache puede
# no estar corriendo todavia — por eso se comprueba antes de detener.
if systemctl is-active --quiet httpd; then
  systemctl stop httpd
fi
