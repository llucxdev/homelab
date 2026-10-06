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
}

trap cleanup EXIT

########################################
# DEPENDENCIAS
########################################

check_dependencies() {

    local missing=0

    for CMD in mkvmerge mkvextract jq curl sha256sum sed awk find sort mktemp df stat sync numfmt; do

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
# HASH DE SUBTÍTULO
########################################

subtitle_hash() {

    local FILE="$1"

    sed 's/\r$//' "$FILE" |
        sha256sum |
        awk '{print $1}'
}

########################################
# OBTENER PISTAS DE TEXTO
########################################

get_text_subtitle_tracks() {

    local FILE="$1"

    mkvmerge -J "$FILE" |
        jq -r '
            .tracks[]
            |
            select(
                .type == "subtitles"
                and (
                    .codec_id == "S_TEXT/UTF8"
                    or .codec_id == "S_TEXT/ASS"
                    or .codec_id == "S_TEXT/SSA"
                    or .codec_id == "S_TEXT/WEBVTT"
                )
            )
            |
            "\(.id)\t\(.codec_id)"
        '
}

########################################
# COMPROBAR DUPLICADO
########################################

subtitle_already_embedded() {
    local video="$1"
    local subtitle="$2"
    local subtitle_lang="$3"

    local temp_dir
    temp_dir=$(mktemp -d)

    cleanup_duplicate_check() {
        rm -rf "$temp_dir"
    }

    normalize_subtitle() {
        sed '1s/^\xEF\xBB\xBF//' "$1" |
        sed 's/\r$//' |
        sed 's/[[:space:]]*$//' |
        sed '/^[[:space:]]*$/d' |
        sha256sum |
        awk '{print $1}'
    }

    local external_hash
    external_hash=$(normalize_subtitle "$subtitle")

    local tracks
    tracks=$(
        mkvmerge -J "$video" |
        jq -r --arg lang "$subtitle_lang" '
            .tracks[]
            | select(.type == "subtitles")
            | select(.codec | test("SubRip|SSA|ASS"; "i"))
            | select((.properties.language // "") == $lang)
            | .id
        '
    )

    if [[ -z "$tracks" ]]; then
        cleanup_duplicate_check
        return 1
    fi

    local track_id
    local extracted
    local internal_hash

    while read -r track_id; do
        [[ -z "$track_id" ]] && continue

        extracted="$temp_dir/track_${track_id}.srt"

        if ! mkvextract tracks \
            "$video" \
            "$track_id:$extracted" >/dev/null 2>&1; then
            continue
        fi

        internal_hash=$(normalize_subtitle "$extracted")

        if [[ "$external_hash" == "$internal_hash" ]]; then
            cleanup_duplicate_check
            return 0
        fi
    done <<< "$tracks"

    cleanup_duplicate_check
    return 1
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
# PROCESAR VÍDEO
########################################

process_video() {

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
    # Evitar duplicados
    ########################################

    FILTERED_SUBS=()

    for SUB in "${SUBS[@]}"; do

        # Obtener idioma/metadatos antes de comprobar duplicados.
        # Esto es especialmente importante en modo Bazarr,
        # donde el idioma viene directamente de Bazarr.
        prepare_subtitle_metadata "$SUB"

        if subtitle_already_embedded "$VIDEO" "$SUB" "$LANG"; then

            log "SKIP | Subtítulo ya embebido | $SUB"

            echo "[SKIP] $(basename "$SUB") ya está embebido"

            continue
        fi

        FILTERED_SUBS+=("$SUB")

    done

    SUBS=("${FILTERED_SUBS[@]}")

    if [[ ${#SUBS[@]} -eq 0 ]]; then

        log "SKIP | Todos los subtítulos ya estaban embebidos | $VIDEO"

        echo "[SKIP] $FILE (subtítulos ya embebidos)"

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

    for SUB in "${SUBS[@]}"; do

        prepare_subtitle_metadata "$SUB"

        CMD+=(
            --language "0:$LANG"
            --track-name "0:$TITLE"
            --default-track-flag "0:$DEFAULT"
            --forced-display-flag "0:$FORCED"
            --hearing-impaired-flag "0:$HEARING_IMPAIRED"
            --compression "0:none"
            "$SUB"
        )

    done

    ########################################
    # Ejecutar mkvmerge
    ########################################

    log "INFO | Ejecutando mkvmerge | Video=$VIDEO | NuevosSubs=${#SUBS[@]}"

    "${CMD[@]}"

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

        mv -f -- "$TMP" "$FINAL"

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