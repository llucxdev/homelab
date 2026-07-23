#!/bin/bash

set -e

DATE=$(date +%F)

SOURCE="/srv/docker/media"
DEST="/srv/docker/backups/media"

mkdir -p "$DEST"

echo "Creando backup..."

tar -czf "$DEST/media-$DATE.tar.gz" -C /srv/docker media

echo "Eliminando backups antiguos..."

ls -1t "$DEST"/media-*.tar.gz | tail -n +31 | xargs -r rm

echo "Backup completado correctamente."
