#!/bin/bash

set -e

DATE=$(date +%F)
DEST="/srv/backups/media"

mkdir -p "$DEST"

echo "Creando backup..."

tar -czf "$DEST/media-$DATE.tar.gz" -C /srv/docker media

echo "Eliminando backups antiguos..."

ls -1t "$DEST"/media-*.tar.gz | tail -n +31 | xargs -r rm

echo "Backup completado correctamente."
