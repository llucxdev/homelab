#!/usr/bin/env bash

set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

TMP_SUFFIX=".embedtmp.mkv"

BAZARR_MODE=0
BAZARR_SUBTITLE=""
BAZARR_LANGUAGE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$SCRIPT_DIR/embed-subtitles.log"
CONFIG="$SCRIPT_DIR/embed-subtitles.conf"

if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

TMP=""

log() {
    printf '%(%F %T)T | %s\n' -1 "$*" >> "$LOGFILE"
}

error_handler() {
    local exit_code=$?
    local line=$1

    log "ERROR | Línea=$line | ExitCode=$exit_code | Video=${VIDEO:-desconocido}"
}

trap 'error_handler $LINENO' ERR


cleanup() {
    if [[ -n "${TMP:-}" && -f "$TMP" ]]; then
        rm -f "$TMP"
        log "INFO | Temporal eliminado | $TMP"
    fi
}

trap cleanup EXIT


########################################
# Dependencias
########################################

check_dependencies() {

    command -v mkvmerge >/dev/null 2>&1 || {
        echo "ERROR: mkvmerge no está instalado."
        exit 1
    }

    command -v curl >/dev/null 2>&1 || {
        echo "ERROR: curl no está instalado."
        exit 1
    }
}


########################################
# Notificar Radarr
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
# Notificar Sonarr
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
# Notificar *arr
########################################

notify_arr() {

    if [[ -n "${SERIES_ID:-}" ]]; then
        notify_sonarr
    else
        notify_radarr
    fi
}


########################################
# Buscar subtítulos
########################################

find_subtitles() {

    local DIR="$1"
    local NAME="$2"

    mapfile -d '' SUBS < <(
        find "$DIR" \
            -maxdepth 1 \
            -type f \
            -iname "$NAME*.srt" \
            -print0 |
        sort -z
    )

    VALID_SUBS=()

    for SUB in "${SUBS[@]}"; do

        [[ -s "$SUB" ]] || continue

        # Nunca usar nuestro temporal
        [[ "$SUB" == *"$TMP_SUFFIX"* ]] && continue

        VALID_SUBS+=("$SUB")
    done

    SUBS=("${VALID_SUBS[@]}")
}


########################################
# Identificar idioma/tipo
########################################

get_subtitle_info() {

    local BASE="$1"

    LANG="und"
    TITLE="Subtitle"
    DEFAULT=0
    FORCED=0

    case "$BASE" in

        *.es.forced.srt|*.spa.forced.srt)
            LANG="spa"
            TITLE="Español Forzado"
            FORCED=1
            ;;

        *.es.hi.srt|*.spa.hi.srt)
            LANG="spa"
            TITLE="Español SDH"
            ;;

        *.es.srt|*.spa.srt)
            LANG="spa"
            TITLE="Español"
            ;;

        *.en.forced.srt|*.eng.forced.srt)
            LANG="eng"
            TITLE="English Forced"
            FORCED=1
            ;;

        *.en.hi.srt|*.eng.hi.srt)
            LANG="eng"
            TITLE="English SDH"
            ;;

        *.en.srt|*.eng.srt)
            LANG="eng"
            TITLE="English"
            ;;

    esac
}


########################################
# Procesar vídeo
########################################

process_video() {

    local VIDEO="$1"

    log "START | $VIDEO"

    [[ -f "$VIDEO" ]] || {
        log "WARN | Archivo no existe | $VIDEO"
        return 0
    }

    local DIR FILE NAME EXT

    DIR="$(dirname "$VIDEO")"
    FILE="$(basename "$VIDEO")"

    NAME="${FILE%.*}"
    EXT="${FILE##*.}"
    EXT="${EXT,,}"

    ####################################
    # Formato
    ####################################

    case "$EXT" in
        mkv|mp4)
            ;;
        *)
            log "SKIP | Formato no soportado | $VIDEO"
            return 0
            ;;
    esac


    ####################################
    # Buscar SRT
    ####################################

    if [[ "$BAZARR_MODE" -eq 1 ]]; then

        # En modo Bazarr usamos EXCLUSIVAMENTE
        # el subtítulo que Bazarr acaba de descargar/sincronizar.

        if [[ ! -s "$BAZARR_SUBTITLE" ]]; then
            echo "[SKIP] $FILE (subtítulo Bazarr vacío o inexistente)"
            log "SKIP | Subtítulo Bazarr vacío/inexistente | $BAZARR_SUBTITLE"
            return 0
        fi

        SUBS=("$BAZARR_SUBTITLE")

    else

        # Modo manual: mantener el comportamiento original.
        find_subtitles "$DIR" "$NAME"

        if [[ ${#SUBS[@]} -eq 0 ]]; then
            echo "[SKIP] $FILE (sin subtítulos)"
            log "SKIP | Sin subtítulos | $VIDEO"
            return 0
        fi

    fi


    log "INFO | Subtítulos a insertar=${#SUBS[@]} | $VIDEO"


    ####################################
    # Temporal
    ####################################

    TMP="$DIR/$NAME$TMP_SUFFIX"

    rm -f "$TMP"


    ####################################
    # Construir comando
    ####################################

    CMD=(
        mkvmerge
        -o "$TMP"
    )


    if [[ "$EXT" == "mkv" ]]; then

        CMD+=(
            --no-subtitles
            "$VIDEO"
        )

    else

        CMD+=(
            "$VIDEO"
        )

    fi


    ####################################
    # Subtítulos
    ####################################

    DEFAULT_ALREADY_SET=0

    for SUB in "${SUBS[@]}"; do

        BASE="$(basename "$SUB")"

    if [[ "$BAZARR_MODE" -eq 1 && "$SUB" == "$BAZARR_SUBTITLE" ]]; then

        case "${BAZARR_LANGUAGE,,}" in
            es|spa)
                LANG="spa"
                TITLE="Español"
                ;;

            en|eng)
                LANG="eng"
                TITLE="English"
                ;;

            *)
                get_subtitle_info "$BASE"
                ;;
        esac

        DEFAULT=0
        FORCED=0

    else

        get_subtitle_info "$BASE"

    fi

        #
        # Español tiene prioridad sobre inglés
        #
        if [[ "$LANG" == "spa" && "$DEFAULT_ALREADY_SET" -eq 0 ]]; then
            DEFAULT=1
            DEFAULT_ALREADY_SET=1
        fi

        #
        # Si no existe español, inglés será default
        #
        if [[ "$LANG" == "eng" && "$DEFAULT_ALREADY_SET" -eq 0 ]]; then

            HAS_SPANISH=0

            for CHECK_SUB in "${SUBS[@]}"; do

                CHECK_BASE="$(basename "$CHECK_SUB")"

                case "$CHECK_BASE" in
                    *.es.srt|*.es.hi.srt|*.es.forced.srt|*.spa.srt|*.spa.hi.srt|*.spa.forced.srt)
                        HAS_SPANISH=1
                        break
                        ;;
                esac

            done

            if [[ "$HAS_SPANISH" -eq 0 ]]; then
                DEFAULT=1
                DEFAULT_ALREADY_SET=1
            fi

        fi


        log "INFO | Añadiendo subtítulo | $(basename "$SUB") | lang=$LANG | default=$DEFAULT | forced=$FORCED"


        CMD+=(
            --language "0:$LANG"
            --track-name "0:$TITLE"
            --default-track "0:$DEFAULT"
            --forced-track "0:$FORCED"
            --compression "0:none"
            "$SUB"
        )

    done


    ####################################
    # Generar MKV
    ####################################

    log "INFO | Generando MKV temporal | $VIDEO"

    "${CMD[@]}"


    ####################################
    # Validar MKV
    ####################################

    if ! mkvmerge -J "$TMP" >/dev/null; then
        log "ERROR | MKV temporal inválido | $TMP"
        return 1
    fi

    log "INFO | MKV temporal validado | $TMP"


    ####################################
    # Reemplazar
    ####################################

    if [[ "$EXT" == "mp4" ]]; then

        FINAL="$DIR/$NAME.mkv"

        log "INFO | MP4 -> MKV | $VIDEO -> $FINAL"

        rm -f "$VIDEO"

        mv -f "$TMP" "$FINAL"

        [[ -f "$FINAL" ]] || {
            log "ERROR | No se pudo crear MKV final | $FINAL"
            return 1
        }

        TMP=""

        #
        # NO hacemos touch
        #
        sync

        notify_arr

        echo "[OK] $(basename "$FINAL")"

        log "OK | Procesado correctamente | $FINAL"

    else

        log "INFO | Sustituyendo MKV | $VIDEO"

        mv -f "$TMP" "$VIDEO"

        [[ -f "$VIDEO" ]] || {
            log "ERROR | No se pudo reemplazar MKV | $VIDEO"
            return 1
        }

        TMP=""

        #
        # NO hacemos touch
        #
        sync

        notify_arr

        echo "[OK] $(basename "$VIDEO")"

        log "OK | Procesado correctamente | $VIDEO"

    fi
}


########################################
# MAIN
########################################

check_dependencies

BAZARR_MODE=0
BAZARR_SUBTITLE=""
BAZARR_LANGUAGE=""

if [[ $# -eq 5 ]]; then

    ########################################
    # Modo Bazarr
    #
    # $1 = subtítulo descargado/sincronizado
    # $2 = vídeo
    # $3 = código de idioma
    # $4 = episode_id / movie_id
    # $5 = series_id
    ########################################

    BAZARR_MODE=1

    BAZARR_SUBTITLE="$1"
    TARGET="$2"
    BAZARR_LANGUAGE="$3"

    MEDIA_ID="$4"
    SERIES_ID="$5"

elif [[ $# -eq 1 || $# -eq 3 ]]; then

    ########################################
    # Modo manual / tradicional
    ########################################

    TARGET="$1"

    MEDIA_ID=""
    SERIES_ID=""

    if [[ $# -eq 3 ]]; then
        MEDIA_ID="$2"
        SERIES_ID="$3"
    fi

else

    echo "Uso:"
    echo "  $0 <video>"
    echo "  $0 <carpeta>"
    echo "  $0 <video> <media_id> <series_id>"
    echo
    echo "Modo Bazarr:"
    echo "  $0 <subtitulo> <video> <idioma> <media_id> <series_id>"

    exit 1

fi


########################################
# Información del modo Bazarr
########################################

if [[ "$BAZARR_MODE" -eq 1 ]]; then

    if [[ ! -f "$BAZARR_SUBTITLE" ]]; then
        echo
        echo "[ERROR] El subtítulo indicado por Bazarr no existe:"
        echo "$BAZARR_SUBTITLE"
        exit 1
    fi

    if [[ ! -f "$TARGET" ]]; then
        echo
        echo "[ERROR] El vídeo indicado por Bazarr no existe:"
        echo "$TARGET"
        exit 1
    fi

    log "BAZARR | Subtitle=$BAZARR_SUBTITLE | Video=$TARGET | Language=$BAZARR_LANGUAGE | MediaId=$MEDIA_ID | SeriesId=$SERIES_ID"

fi


########################################
# Procesar carpeta
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
# Procesar archivo
########################################

elif [[ -f "$TARGET" ]]; then

    process_video "$TARGET"


########################################
# Error
########################################

else

    echo
    echo "No existe:"
    echo "$TARGET"

    exit 1

fi


echo
echo "Proceso finalizado."