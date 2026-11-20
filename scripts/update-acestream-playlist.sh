
#!/bin/bash
set -Eeuo pipefail

# Configuración
PLAYLIST_URL="https://search-ace.stream/playlist?category=sport"
TARGET="/srv/media/iptv/channels.m3u"
LOG="/srv/docker/scripts/update-acestream-playlist.log"

# Evitar ejecuciones simultáneas
exec 9>/tmp/update-acestream-playlist.lock
flock -n 9 || exit 0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# Archivos temporales en el mismo directorio que el destino
RAW=$(mktemp "${TARGET}.raw.XXXXXX")
NEW=$(mktemp "${TARGET}.new.XXXXXX")

cleanup() {
    rm -f "$RAW" "$NEW"
}
trap cleanup EXIT

log "Iniciando actualización de la lista"

# Descargar la lista
if ! curl -fsSL --retry 3 --retry-delay 5 "$PLAYLIST_URL" -o "$RAW"; then
    log "ERROR: No se pudo descargar la lista"
    exit 1
fi

# Comprobar que no está vacía y que parece una M3U
if [[ ! -s "$RAW" ]] || ! grep -q '^#EXTM3U' "$RAW"; then
    log "ERROR: La respuesta descargada no parece una lista M3U válida"
    exit 1
fi

# Sustituir localhost por el nombre del contenedor AceStream
sed -E \
    's#(https?://)(127\.0\.0\.1|localhost)(:6878)#\1acestream\3#g' \
    "$RAW" > "$NEW"

# Comprobar que no quedan direcciones locales
if grep -Eq 'https?://(127\.0\.0\.1|localhost):6878' "$NEW"; then
    log "ERROR: Todavía quedan direcciones localhost en la lista"
    exit 1
fi

# Sustituir el archivo de forma atómica
mv "$NEW" "$TARGET"

log "Actualización completada correctamente"
