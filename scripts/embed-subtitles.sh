#!/usr/bin/env bash

set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

########################################
# CONFIGURACIÓN
########################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOGFILE="$SCRIPT_DIR/embed-subtitles.log"
CONFIG="$SCRIPT_DIR/embed-subtitles.conf"

BAZARR_MODE=0
BAZARR_SUBTITLE=""
BAZARR_LANGUAGE=""
BAZARR_LANGUAGE_FULL=""

MEDIA_ID=""
SERIES_ID=""

VIDEO=""
TMP=""
TAG_XMLS=()

########################################
# CONFIG OPCIONAL
########################################

if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

########################################
# LOGGING
########################################

log() {
    printf '%(%F %T)T | %s\n' -1 "$*" >> "$LOGFILE"
}

########################################
# MANEJO DE ERRORES
########################################

error_handler() {
    local exit_code=$?
    local line=$1

    log "ERROR | Línea=$line | ExitCode=$exit_code | Video=${VIDEO:-desconocido}"
}

trap 'error_handler $LINENO' ERR

########################################
# LIMPIEZA
########################################

cleanup() {

    if [[ -n "${TMP:-}" && -f "$TMP" ]]; then
        rm -f -- "$TMP"
        log "INFO | Temporal eliminado | $TMP"
    fi

    for TAG_XML in "${TAG_XMLS[@]:-}"; do
        [[ -n "$TAG_XML" && -f "$TAG_XML" ]] && rm -f -- "$TAG_XML"
    done
}

trap cleanup EXIT

########################################
# DEPENDENCIAS
########################################

check_dependencies() {

    local missing=0

    for CMD in mkvmerge mkvextract jq curl sed awk find sort mktemp df stat sync numfmt sha256sum grep python3 flock realpath; do

        if ! command -v "$CMD" >/dev/null 2>&1; then
            echo "ERROR: $CMD no está instalado."
            log "ERROR | Dependencia ausente | $CMD"
            missing=1
        fi

    done

    if [[ "$missing" -ne 0 ]]; then
        exit 1
    fi
}

########################################
# NOTIFICAR RADARR
########################################

notify_radarr() {

    [[ -n "${MEDIA_ID:-}" ]] || return 0
    [[ -n "${RADARR_URL:-}" ]] || return 0
    [[ -n "${RADARR_API_KEY:-}" ]] || return 0

    log "INFO | Actualizando Radarr | MovieId=$MEDIA_ID"

    if ! curl -fsS \
        -X POST \
        -H "X-Api-Key: $RADARR_API_KEY" \
        -H "Content-Type: application/json" \
        "$RADARR_URL/api/v3/command" \
        -d "{\"name\":\"RefreshMovie\",\"movieIds\":[${MEDIA_ID}]}" \
        >/dev/null
    then
        log "WARN | No se pudo actualizar Radarr"
    fi
}

########################################
# NOTIFICAR SONARR
########################################

notify_sonarr() {

    [[ -n "${SERIES_ID:-}" ]] || return 0
    [[ -n "${SONARR_URL:-}" ]] || return 0
    [[ -n "${SONARR_API_KEY:-}" ]] || return 0

    log "INFO | Actualizando Sonarr | SeriesId=$SERIES_ID"

    if ! curl -fsS \
        -X POST \
        -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        "$SONARR_URL/api/v3/command" \
        -d "{\"name\":\"RescanSeries\",\"seriesId\":${SERIES_ID}}" \
        >/dev/null
    then
        log "WARN | No se pudo actualizar Sonarr"
    fi
}

########################################
# NOTIFICAR *ARR
########################################

notify_arr() {

    if [[ -n "${SERIES_ID:-}" ]]; then
        notify_sonarr
    else
        notify_radarr
    fi
}

########################################
# INFORMACIÓN DEL SUBTÍTULO
########################################

prepare_subtitle_metadata() {

    local SUB="$1"

    local BASE
    BASE="$(basename "$SUB")"

    LANG="und"
    TITLE="Subtitle"
    DEFAULT=0
    FORCED=0
    HEARING_IMPAIRED=0

    ########################################
    # Idioma
    ########################################

    if [[ "$BAZARR_MODE" -eq 1 && "$SUB" == "$BAZARR_SUBTITLE" ]]; then

        if [[ -n "$BAZARR_LANGUAGE" ]]; then
            LANG="${BAZARR_LANGUAGE,,}"
        fi

    else

        case "${BASE,,}" in

            *.es.*|*.spa.*)
                LANG="spa"
                ;;

            *.en.*|*.eng.*)
                LANG="eng"
                ;;

            *.ca.*|*.cat.*)
                LANG="cat"
                ;;

            *.fr.*|*.fra.*)
                LANG="fra"
                ;;

            *.de.*|*.deu.*)
                LANG="deu"
                ;;

            *.it.*|*.ita.*)
                LANG="ita"
                ;;

            *.pt.*|*.por.*)
                LANG="por"
                ;;

            *.ja.*|*.jpn.*)
                LANG="jpn"
                ;;

            *.ko.*|*.kor.*)
                LANG="kor"
                ;;

            *.zh.*|*.zho.*|*.chi.*)
                LANG="zho"
                ;;

            *.nl.*|*.nld.*|*.dut.*)
                LANG="nld"
                ;;

            *.ru.*|*.rus.*)
                LANG="rus"
                ;;

            *)
                LANG="und"
                ;;

        esac

    fi

    ########################################
    # Forced
    ########################################

    if [[ "${BASE,,}" == *".forced."* ||
          "${BAZARR_LANGUAGE_FULL,,}" == *":forced"* ]]; then

        FORCED=1
    fi

    ########################################
    # Hearing Impaired / SDH
    ########################################

    if [[ "${BASE,,}" == *".hi."* ||
          "${BASE,,}" == *".sdh."* ||
          "${BASE,,}" == *".cc."* ||
          "${BAZARR_LANGUAGE_FULL,,}" == *":hi"* ]]; then

        HEARING_IMPAIRED=1
    fi

    ########################################
    # Título
    ########################################

    case "$LANG" in

        spa)
            TITLE="Español"
            ;;

        eng)
            TITLE="English"
            ;;

        cat)
            TITLE="Català"
            ;;

        fra)
            TITLE="Français"
            ;;

        deu)
            TITLE="Deutsch"
            ;;

        ita)
            TITLE="Italiano"
            ;;

        por)
            TITLE="Português"
            ;;

        jpn)
            TITLE="日本語"
            ;;

        kor)
            TITLE="한국어"
            ;;

        zho)
            TITLE="中文"
            ;;

        nld)
            TITLE="Nederlands"
            ;;

        rus)
            TITLE="Русский"
            ;;

        *)
            TITLE="Subtitle"
            ;;

    esac

    ########################################
    # Variantes
    ########################################

    if [[ "$FORCED" -eq 1 ]]; then

        TITLE="$TITLE Forced"

    elif [[ "$HEARING_IMPAIRED" -eq 1 ]]; then

        TITLE="$TITLE SDH"

    fi

    ########################################
    # NUEVO SUBTÍTULO NUNCA DEFAULT
    ########################################

    DEFAULT=0

    log "INFO | Nuevo subtítulo | $BASE | lang=$LANG | title=$TITLE | default=$DEFAULT | forced=$FORCED | hearing_impaired=$HEARING_IMPAIRED"
}

########################################
# BUSCAR SUBTÍTULOS - MODO MANUAL
########################################

find_subtitles() {

    local DIR="$1"
    local NAME="$2"

    mapfile -d '' SUBS < <(
        find "$DIR" \
            -maxdepth 1 \
            -type f \
            \( \
                -iname "$NAME*.srt" \
                -o -iname "$NAME*.ass" \
                -o -iname "$NAME*.ssa" \
            \) \
            -print0 |
        sort -z
    )

    VALID_SUBS=()

    for SUB in "${SUBS[@]}"; do

        [[ -s "$SUB" ]] || continue

        VALID_SUBS+=("$SUB")

    done

    SUBS=("${VALID_SUBS[@]}")
}

########################################
# VALIDAR SUBTÍTULO
########################################

validate_subtitle() {

    local SUBTITLE="$1"

    if [[ ! -f "$SUBTITLE" ]]; then

        log "ERROR | Subtítulo inexistente | $SUBTITLE"

        return 1
    fi

    if [[ ! -s "$SUBTITLE" ]]; then

        log "ERROR | Subtítulo vacío | $SUBTITLE"

        return 1
    fi

    if ! grep -q '[[:alnum:]]' "$SUBTITLE"; then

        log "ERROR | Subtítulo sin contenido reconocible | $SUBTITLE"

        return 1
    fi

    return 0
}

########################################
# COMPROBAR ESPACIO LIBRE
########################################

check_free_space() {

    local FILE="$1"

    local FILE_SIZE
    local FREE_SPACE

    FILE_SIZE="$(stat -c '%s' "$FILE")"
    FREE_SPACE="$(df -B1 --output=avail "$(dirname "$FILE")" | tail -n 1 | tr -d ' ')"

    if [[ "$FREE_SPACE" -lt "$FILE_SIZE" ]]; then

        log "ERROR | Espacio insuficiente | Necesario=$FILE_SIZE | Disponible=$FREE_SPACE"

        echo
        echo "[ERROR] No hay suficiente espacio libre para procesar:"
        echo "$(basename "$FILE")"
        echo
        echo "Necesario:  $(numfmt --to=iec "$FILE_SIZE")"
        echo "Disponible: $(numfmt --to=iec "$FREE_SPACE")"
        echo

        return 1
    fi
}

########################################
# OBTENER RESUMEN DE PISTAS
########################################

get_track_summary() {

    local FILE="$1"

    mkvmerge -J "$FILE" |
        jq -c '
            {
                video: [.tracks[] | select(.type == "video") | .id],
                audio: [.tracks[] | select(.type == "audio") | .id],
                subtitles: [.tracks[] | select(.type == "subtitles") | .id]
            }
        '
}

########################################
# VALIDAR PISTAS ORIGINALES
########################################

validate_original_tracks() {

    local ORIGINAL="$1"
    local NEW="$2"

    local ORIGINAL_INFO
    local NEW_INFO

    ORIGINAL_INFO="$(get_track_summary "$ORIGINAL")"
    NEW_INFO="$(get_track_summary "$NEW")"

    local ORIGINAL_VIDEO
    local NEW_VIDEO

    local ORIGINAL_AUDIO
    local NEW_AUDIO

    local ORIGINAL_SUBS
    local NEW_SUBS

    ORIGINAL_VIDEO="$(jq '.video | length' <<< "$ORIGINAL_INFO")"
    NEW_VIDEO="$(jq '.video | length' <<< "$NEW_INFO")"

    ORIGINAL_AUDIO="$(jq '.audio | length' <<< "$ORIGINAL_INFO")"
    NEW_AUDIO="$(jq '.audio | length' <<< "$NEW_INFO")"

    ORIGINAL_SUBS="$(jq '.subtitles | length' <<< "$ORIGINAL_INFO")"
    NEW_SUBS="$(jq '.subtitles | length' <<< "$NEW_INFO")"

    ########################################
    # Vídeo
    ########################################

    if [[ "$NEW_VIDEO" -lt "$ORIGINAL_VIDEO" ]]; then

        log "ERROR | Se perdió una pista de vídeo | antes=$ORIGINAL_VIDEO después=$NEW_VIDEO"

        return 1
    fi

    ########################################
    # Audio
    ########################################

    if [[ "$NEW_AUDIO" -lt "$ORIGINAL_AUDIO" ]]; then

        log "ERROR | Se perdió una pista de audio | antes=$ORIGINAL_AUDIO después=$NEW_AUDIO"

        return 1
    fi

    ########################################
    # Subtítulos
    ########################################

    if [[ "$NEW_SUBS" -lt "$ORIGINAL_SUBS" ]]; then

        log "ERROR | Se perdió una pista de subtítulos | antes=$ORIGINAL_SUBS después=$NEW_SUBS"

        return 1
    fi

    log "INFO | Validación de pistas OK | video=$ORIGINAL_VIDEO->$NEW_VIDEO | audio=$ORIGINAL_AUDIO->$NEW_AUDIO | subs=$ORIGINAL_SUBS->$NEW_SUBS"

    return 0
}

########################################
# LEER HUELLAS ASOCIADAS A PISTAS DE SUBTÍTULOS
########################################

read_subtitle_hashes() {
    local FILE="$1"
    local JSON_FILE XML_FILE RC

    JSON_FILE="$(mktemp)"
    XML_FILE="$(mktemp)"

    if ! mkvmerge -J "$FILE" > "$JSON_FILE"; then
        rm -f -- "$JSON_FILE" "$XML_FILE"
        log "ERROR | No se pudo identificar el archivo para leer huellas | $FILE"
        return 1
    fi

    # mkvextract escribe en una ruta de salida; se elimina el archivo vacío creado por mktemp.
    rm -f -- "$XML_FILE"
    if ! mkvextract "$FILE" tags "$XML_FILE" >/dev/null 2>&1; then
        rm -f -- "$JSON_FILE" "$XML_FILE"
        log "ERROR | No se pudieron extraer las etiquetas | $FILE"
        return 1
    fi

    if python3 - "$JSON_FILE" "$XML_FILE" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

json_path, xml_path = sys.argv[1:3]
with open(json_path, "r", encoding="utf-8") as f:
    identify = json.load(f)

subtitle_uids = set()
for track in identify.get("tracks", []):
    if track.get("type") == "subtitles":
        uid = track.get("properties", {}).get("uid")
        if uid is not None:
            subtitle_uids.add(str(uid))

xml_file = Path(xml_path)
xml_data = xml_file.read_text(encoding="utf-8", errors="replace").strip() if xml_file.exists() else ""
if not xml_data:
    sys.exit(0)

try:
    root = ET.fromstring(xml_data)
except ET.ParseError as exc:
    print(f"XML de etiquetas inválido: {exc}", file=sys.stderr)
    sys.exit(2)

for tag in root.findall("Tag"):
    targets = tag.find("Targets")
    if targets is None:
        continue
    track_uids = {node.text.strip() for node in targets.findall("TrackUID") if node.text and node.text.strip()}
    if not (track_uids & subtitle_uids):
        continue
    for simple in tag.findall(".//Simple"):
        name = simple.findtext("Name", default="").strip()
        value = simple.findtext("String", default="").strip()
        if name == "SUBTITLE_SHA256" and len(value) == 64 and all(c in "0123456789abcdefABCDEF" for c in value):
            print(value.lower())
PY
    then
        RC=0
    else
        RC=$?
        rm -f -- "$JSON_FILE" "$XML_FILE"
        log "ERROR | No se pudieron interpretar las etiquetas de subtítulos | $FILE"
        return "$RC"
    fi

    rm -f -- "$JSON_FILE" "$XML_FILE"
}

########################################
# VALIDAR HUELLAS DE LAS NUEVAS PISTAS
########################################

validate_subtitle_hashes() {
    local FILE="$1"
    shift
    local EXPECTED_HASH
    local FOUND_HASHES

    if ! FOUND_HASHES="$(read_subtitle_hashes "$FILE")"; then
        return 1
    fi

    for EXPECTED_HASH in "$@"; do
        if ! grep -Fxq -- "$EXPECTED_HASH" <<< "$FOUND_HASHES"; then
            log "ERROR | No se encontró la huella asociada a una pista de subtítulos | sha256=$EXPECTED_HASH | $FILE"
            return 1
        fi
    done

    log "INFO | Huellas verificadas en pistas de subtítulos | cantidad=$# | $FILE"
    return 0
}

########################################
# PROCESAR VÍDEO (CON BLOQUEO)
########################################

process_video() {
    local CURRENT_VIDEO="$1"
    local CANONICAL_PATH LOCK_KEY LOCK_PATH LOCK_FD_LOCAL RC

    CANONICAL_PATH="$(realpath -m -- "$CURRENT_VIDEO")"
    LOCK_KEY="$(printf '%s' "$CANONICAL_PATH" | sha256sum | awk '{print $1}')"
    LOCK_PATH="${TMPDIR:-/tmp}/embed-subtitles-${UID}-${LOCK_KEY}.lock"

    # El bloqueo se basa en la ruta absoluta para que llamadas con rutas relativas
    # y absolutas al mismo vídeo compartan el mismo candado.
    exec {LOCK_FD_LOCAL}>"$LOCK_PATH"
    log "INFO | Esperando bloqueo de vídeo | $CANONICAL_PATH"
    flock -x "$LOCK_FD_LOCAL"
    log "INFO | Bloqueo adquirido | $CANONICAL_PATH"

    if process_video_locked "$CURRENT_VIDEO"; then
        RC=0
    else
        RC=$?
    fi

    flock -u "$LOCK_FD_LOCAL"
    exec {LOCK_FD_LOCAL}>&-
    log "INFO | Bloqueo liberado | $CANONICAL_PATH"
    return "$RC"
}

########################################
# PROCESAR VÍDEO
########################################

process_video_locked() {

    local CURRENT_VIDEO="$1"

    VIDEO="$CURRENT_VIDEO"

    log "START | $VIDEO"

    ########################################
    # Comprobar vídeo
    ########################################

    if [[ ! -f "$VIDEO" ]]; then

        log "WARN | Archivo no existe | $VIDEO"

        return 0
    fi

    ########################################
    # Formato
    ########################################

    local DIR
    local FILE
    local NAME
    local EXT

    DIR="$(dirname "$VIDEO")"
    FILE="$(basename "$VIDEO")"

    NAME="${FILE%.*}"
    EXT="${FILE##*.}"
    EXT="${EXT,,}"

    case "$EXT" in

        mkv|mp4)
            ;;

        *)
            log "SKIP | Formato no soportado | $VIDEO"
            return 0
            ;;

    esac

    # MP4 se convierte a MKV. Nunca sobrescribir un MKV que ya exista.
    if [[ "$EXT" == "mp4" && -e "$DIR/$NAME.mkv" ]]; then
        log "ERROR | Destino MKV ya existe; se conserva el MP4 y no se sobrescribe nada | $DIR/$NAME.mkv"
        echo "[ERROR] Ya existe el destino MKV; no se modificará ningún archivo: $DIR/$NAME.mkv"
        return 1
    fi

    ########################################
    # Espacio libre
    ########################################

    if ! check_free_space "$VIDEO"; then
        return 1
    fi

    ########################################
    # Obtener subtítulos
    ########################################

    if [[ "$BAZARR_MODE" -eq 1 ]]; then

        if ! validate_subtitle "$BAZARR_SUBTITLE"; then

            echo "[SKIP] $FILE (subtítulo Bazarr inválido)"

            return 0
        fi

        SUBS=("$BAZARR_SUBTITLE")

    else

        find_subtitles "$DIR" "$NAME"

        if [[ ${#SUBS[@]} -eq 0 ]]; then

            echo "[SKIP] $FILE (sin subtítulos)"

            log "SKIP | Sin subtítulos | $VIDEO"

            return 0
        fi

    fi

    ########################################
    # Evitar reinsertar el mismo contenido
    ########################################

    # Las huellas se guardan como etiquetas asociadas a cada pista añadida.
    # En ejecuciones posteriores se leen desde el MKV, sin comparar idiomas.
    local EXISTING_HASHES=""
    local SUB_HASH=""
    local DUPLICATE=0
    local -a FILTERED_SUBS=()
    local -a FILTERED_HASHES=()
    local -a SEEN_HASHES=()
    local PREVIOUS_HASH=""

    if [[ "${VIDEO,,}" == *.mkv ]]; then
        if ! EXISTING_HASHES="$(read_subtitle_hashes "$VIDEO")"; then
            echo "[ERROR] No se pudieron verificar las huellas del MKV. No se modificará el vídeo."
            return 1
        fi
    fi

    for SUB in "${SUBS[@]}"; do
        if ! validate_subtitle "$SUB"; then
            log "WARN | Subtítulo inválido omitido | $SUB"
            echo "[SKIP] $(basename "$SUB") (subtítulo inválido)"
            continue
        fi

        SUB_HASH="$(sha256sum -- "$SUB" | awk '{print $1}')"
        DUPLICATE=0

        if [[ -n "$EXISTING_HASHES" ]] && grep -Fxq -- "$SUB_HASH" <<< "$EXISTING_HASHES"; then
            DUPLICATE=1
        fi

        for PREVIOUS_HASH in "${SEEN_HASHES[@]}"; do
            if [[ "$PREVIOUS_HASH" == "$SUB_HASH" ]]; then
                DUPLICATE=1
                break
            fi
        done

        if [[ "$DUPLICATE" -eq 1 ]]; then
            log "SKIP | Subtítulo ya integrado (misma huella) | $SUB | sha256=$SUB_HASH"
            echo "[SKIP] $(basename "$SUB") (subtítulo ya integrado)"
            continue
        fi

        FILTERED_SUBS+=("$SUB")
        FILTERED_HASHES+=("$SUB_HASH")
        SEEN_HASHES+=("$SUB_HASH")
    done

    SUBS=("${FILTERED_SUBS[@]}")
    SUB_HASHES=("${FILTERED_HASHES[@]}")

    if [[ ${#SUBS[@]} -eq 0 ]]; then
        log "SKIP | Todos los subtítulos ya estaban integrados | $VIDEO"
        return 0
    fi

    ########################################
    # Crear temporal único
    ########################################

    TMP="$(mktemp --tmpdir="$DIR" ".${NAME}.embedtmp.XXXXXX.mkv")"

    rm -f -- "$TMP"

    log "INFO | Temporal creado | $TMP"

    ########################################
    # Construir mkvmerge
    ########################################

    CMD=(
        mkvmerge
        -o "$TMP"
        "$VIDEO"
    )

    ########################################
    # Añadir nuevos subtítulos
    ########################################

    for i in "${!SUBS[@]}"; do

        SUB="${SUBS[$i]}"
        SUB_HASH="${SUB_HASHES[$i]}"
        prepare_subtitle_metadata "$SUB"

        # mkvmerge asigna automáticamente el UID de la pista al importar estas etiquetas.
        TAG_XML="$(mktemp --tmpdir="$DIR" ".${NAME}.subtags.XXXXXX.xml")"
        TAG_XMLS+=("$TAG_XML")
        cat > "$TAG_XML" <<EOF
<Tags>
  <Tag>
    <Simple>
      <Name>SUBTITLE_SHA256</Name>
      <String>${SUB_HASH}</String>
    </Simple>
  </Tag>
</Tags>
EOF

        CMD+=(
            --language "0:$LANG"
            --track-name "0:$TITLE"
            --default-track-flag "0:$DEFAULT"
            --forced-display-flag "0:$FORCED"
            --hearing-impaired-flag "0:$HEARING_IMPAIRED"
            --compression "0:none"
            --tags "0:$TAG_XML"
            "$SUB"
        )

    done

    ########################################
    # Ejecutar mkvmerge
    ########################################

    log "INFO | Ejecutando mkvmerge | Video=$VIDEO | NuevosSubs=${#SUBS[@]}"

    "${CMD[@]}"

    # Las etiquetas ya están incorporadas al temporal; eliminar sus XML auxiliares.
    for TAG_XML in "${TAG_XMLS[@]:-}"; do
        [[ -n "$TAG_XML" && -f "$TAG_XML" ]] && rm -f -- "$TAG_XML"
    done
    TAG_XMLS=()

    ########################################
    # Comprobar temporal
    ########################################

    if [[ ! -f "$TMP" ]]; then

        log "ERROR | mkvmerge no generó temporal | $TMP"

        return 1
    fi

    if ! mkvmerge -J "$TMP" >/dev/null; then

        log "ERROR | MKV temporal inválido | $TMP"

        return 1
    fi

    ########################################
    # Validar pistas
    ########################################

    if ! validate_original_tracks "$VIDEO" "$TMP"; then

        echo
        echo "[ERROR] La validación del MKV ha fallado."
        echo "El archivo original NO será reemplazado."
        echo

        return 1
    fi

    # Confirmar que cada hash quedó asociado a una pista de subtítulos,
    # no simplemente presente como etiqueta global o de otra pista.
    if ! validate_subtitle_hashes "$TMP" "${SUB_HASHES[@]}"; then
        echo
        echo "[ERROR] No se han podido verificar las huellas de los subtítulos nuevos."
        echo "El archivo original NO será reemplazado."
        echo
        return 1
    fi

    ########################################
    # Comprobar que se añadieron
    ########################################

    local ORIGINAL_SUB_COUNT
    local NEW_SUB_COUNT

    ORIGINAL_SUB_COUNT="$(
        mkvmerge -J "$VIDEO" |
            jq '[.tracks[] | select(.type == "subtitles")] | length'
    )"

    NEW_SUB_COUNT="$(
        mkvmerge -J "$TMP" |
            jq '[.tracks[] | select(.type == "subtitles")] | length'
    )"

    local EXPECTED_SUB_COUNT

    EXPECTED_SUB_COUNT=$((ORIGINAL_SUB_COUNT + ${#SUBS[@]}))

    if [[ "$NEW_SUB_COUNT" -lt "$EXPECTED_SUB_COUNT" ]]; then

        log "ERROR | No se añadieron todos los subtítulos | esperado=$EXPECTED_SUB_COUNT obtenido=$NEW_SUB_COUNT"

        echo
        echo "[ERROR] No se han añadido todos los subtítulos solicitados."
        echo "El archivo original NO será reemplazado."
        echo

        return 1
    fi

    ########################################
    # Sustitución
    ########################################

    if [[ "$EXT" == "mkv" ]]; then

        log "INFO | Sustituyendo MKV original | $VIDEO"

        mv -f -- "$TMP" "$VIDEO"

        TMP=""

        if [[ ! -f "$VIDEO" ]]; then

            log "ERROR | El MKV final no existe | $VIDEO"

            return 1
        fi

        sync

        notify_arr

        echo "[OK] $(basename "$VIDEO")"

        log "OK | Procesado correctamente | $VIDEO"

    else

        ########################################
        # MP4 -> MKV
        ########################################

        local FINAL="$DIR/$NAME.mkv"

        log "INFO | MP4 -> MKV | $VIDEO -> $FINAL"

        # -n evita sobrescribir el destino incluso si aparece tras la comprobación inicial.
        if ! mv -n -- "$TMP" "$FINAL"; then
            log "ERROR | No se pudo mover el temporal al destino MKV | $FINAL"
            return 1
        fi

        # GNU mv -n puede devolver éxito sin mover si el destino ya existe.
        if [[ -e "$TMP" ]]; then
            log "ERROR | El destino MKV apareció durante el proceso; no se sobrescribió | $FINAL"
            echo "[ERROR] El destino MKV ya existe; se conserva el MP4 original: $FINAL"
            return 1
        fi

        TMP=""

        if [[ ! -f "$FINAL" ]]; then

            log "ERROR | No se pudo crear MKV final | $FINAL"

            return 1
        fi

        if ! mkvmerge -J "$FINAL" >/dev/null; then

            log "ERROR | MKV final inválido | $FINAL"

            return 1
        fi

        rm -f -- "$VIDEO"

        sync

        notify_arr

        echo "[OK] $(basename "$FINAL")"

        log "OK | MP4 convertido correctamente | $FINAL"

    fi
}

########################################
# MAIN
########################################

check_dependencies

BAZARR_MODE=0
BAZARR_SUBTITLE=""
BAZARR_LANGUAGE=""
BAZARR_LANGUAGE_FULL=""

########################################
# MODO BAZARR
########################################

if [[ $# -eq 6 ]]; then

    BAZARR_MODE=1

    BAZARR_SUBTITLE="$1"
    TARGET="$2"
    BAZARR_LANGUAGE="$3"
    BAZARR_LANGUAGE_FULL="$4"

    MEDIA_ID="$5"
    SERIES_ID="$6"

########################################
# COMPATIBILIDAD CON COMANDO ANTIGUO
########################################

elif [[ $# -eq 5 ]]; then

    BAZARR_MODE=1

    BAZARR_SUBTITLE="$1"
    TARGET="$2"
    BAZARR_LANGUAGE="$3"

    MEDIA_ID="$4"
    SERIES_ID="$5"

########################################
# MODO MANUAL
########################################

elif [[ $# -eq 1 || $# -eq 3 ]]; then

    TARGET="$1"

    MEDIA_ID=""
    SERIES_ID=""

    if [[ $# -eq 3 ]]; then
        MEDIA_ID="$2"
        SERIES_ID="$3"
    fi

else

    echo
    echo "Uso:"
    echo "  $0 <video>"
    echo "  $0 <carpeta>"
    echo "  $0 <video> <media_id> <series_id>"
    echo
    echo "Modo Bazarr:"
    echo "  $0 <subtitulo> <video> <idioma3> <idioma_completo> <media_id> <series_id>"
    echo

    exit 1

fi

########################################
# VALIDACIONES BAZARR
########################################

if [[ "$BAZARR_MODE" -eq 1 ]]; then

    if [[ ! -f "$BAZARR_SUBTITLE" ]]; then

        echo
        echo "[ERROR] El subtítulo indicado por Bazarr no existe:"
        echo "$BAZARR_SUBTITLE"
        echo

        exit 1
    fi

    if [[ ! -f "$TARGET" ]]; then

        echo
        echo "[ERROR] El vídeo indicado por Bazarr no existe:"
        echo "$TARGET"
        echo

        exit 1
    fi

    log "BAZARR | Subtitle=$BAZARR_SUBTITLE | Video=$TARGET | Language3=$BAZARR_LANGUAGE | LanguageFull=$BAZARR_LANGUAGE_FULL | MediaId=$MEDIA_ID | SeriesId=$SERIES_ID"

fi

########################################
# PROCESAR CARPETA
########################################

if [[ -d "$TARGET" ]]; then

    while IFS= read -r -d '' FILE; do

        process_video "$FILE"

    done < <(
        find "$TARGET" \
            -type f \
            \( -iname "*.mkv" -o -iname "*.mp4" \) \
            -print0
    )

########################################
# PROCESAR ARCHIVO
########################################

elif [[ -f "$TARGET" ]]; then

    process_video "$TARGET"

########################################
# ERROR
########################################

else

    echo
    echo "No existe:"
    echo "$TARGET"
    echo

    exit 1

fi

echo
echo "Proceso finalizado."
