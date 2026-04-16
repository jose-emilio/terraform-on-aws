#!/bin/bash
# BeforeInstall: elimina los ficheros que CodeDeploy va a copiar para evitar
# el error "file already exists". El user_data crea index.html y health en el
# primer arranque; este hook los borra antes de que CodeDeploy los sobreescriba.
rm -f /var/www/html/index.html /var/www/html/health /var/www/html/image.png
