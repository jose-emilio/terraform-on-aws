#!/bin/bash
# ApplicationStop: detiene Apache si esta en ejecucion.
if systemctl is-active --quiet httpd; then
  systemctl stop httpd
fi
