#!/bin/sh
#
# setup.sh — Configuración inicial de FreeBSD + KDE
#
# Qué hace:
#   1. Actualiza el sistema de paquetes e instala Xorg, KDE Plasma, SDDM,
#      Konsole, Dolphin y sudo
#   2. Habilita servicios en /etc/rc.conf (con sysrc)
#   3. Crea un usuario nuevo (si no existe)
#   4. Lo agrega a los grupos wheel, video y operator
#   5. Habilita sudo para el grupo wheel (descomenta la línea en sudoers)
#   6. Descarga archivos de configuración desde GitHub a su carpeta home
#
# Uso (como root):
#   sh setup.sh <usuario>
#
# Ejemplo:
#   sh setup.sh jesus
#
# El script es "idempotente": puedes ejecutarlo varias veces sin romper nada.
# Si el usuario ya existe, no lo vuelve a crear; si un servicio ya está
# habilitado, solo lo reescribe con el mismo valor.

# ---------------------------------------------------------------------------
# Opciones de seguridad del shell
#   -e : termina el script si cualquier comando falla
#   -u : marca como error usar una variable que no fue definida
# ---------------------------------------------------------------------------
set -eu

# ---------------------------------------------------------------------------
# Configuración — edita estos valores según lo que necesites
# ---------------------------------------------------------------------------

# Paquetes a instalar
#   xorg            : servidor gráfico
#   plasma6-plasma  : escritorio KDE Plasma 6
#   sddm            : pantalla de inicio de sesión
#   konsole         : terminal de KDE
#   dolphin         : explorador de archivos de KDE
#   sudo            : ejecutar comandos como root desde tu usuario
PAQUETES="xorg plasma6-plasma sddm konsole dolphin sudo"

# Servicios que se habilitan en /etc/rc.conf como <servicio>_enable="YES"
SERVICIOS="dbus sddm"

# Grupos adicionales del usuario
GRUPOS="wheel video operator"

# Shell del usuario nuevo
SHELL_USUARIO="/bin/sh"

# URL base de los archivos "raw" del repositorio
REPO_RAW="https://raw.githubusercontent.com/jesusherrera13/unix-setup-scripts/main"

# Archivos a descargar: "ruta_en_el_repo:ruta_dentro_del_home"
ARCHIVOS="
freebsd/kde/.config/kxkbrc:.config/kxkbrc
freebsd/kde/.config/plasma-localerc:.config/plasma-localerc
"

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------

# Imprime un mensaje destacado
info() {
    printf '\n==> %s\n' "$*"
}

# Imprime un error y termina el script
error() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Validaciones previas
# ---------------------------------------------------------------------------

# id -u devuelve 0 cuando el usuario es root
if [ "$(id -u)" -ne 0 ]; then
    error "Este script debe ejecutarse como root (usa: su -)"
fi

# $# es el número de argumentos recibidos
if [ $# -ne 1 ]; then
    error "Uso: sh $0 <usuario>"
fi

USUARIO="$1"

# ---------------------------------------------------------------------------
# 1. Paquetes
# ---------------------------------------------------------------------------
# En una instalación nueva, pkg todavía no está instalado: la primera vez
# pregunta si quieres instalarlo ("bootstrap"). ASSUME_ALWAYS_YES hace que
# pkg responda "sí" a todo, para que el script no se quede esperando.
export ASSUME_ALWAYS_YES=yes

info "Actualizando el catálogo de paquetes"
pkg update

info "Actualizando paquetes instalados"
pkg upgrade

info "Instalando paquetes: $PAQUETES"
# $PAQUETES va sin comillas a propósito: así el shell lo separa en
# varios argumentos (xorg, plasma6-plasma, ...) en lugar de uno solo.
# shellcheck disable=SC2086
pkg install $PAQUETES

# ---------------------------------------------------------------------------
# 2. Servicios en /etc/rc.conf
# ---------------------------------------------------------------------------
# sysrc es la herramienta oficial para editar rc.conf: evita líneas
# duplicadas y errores de sintaxis que pueden pasar al editar a mano.
info "Habilitando servicios en /etc/rc.conf"

for servicio in $SERVICIOS; do
    sysrc "${servicio}_enable=YES"
done

# ---------------------------------------------------------------------------
# 3. Crear el usuario
# ---------------------------------------------------------------------------
# pw usershow devuelve error si el usuario no existe; lo usamos como prueba.
# ">/dev/null 2>&1" oculta la salida normal y los errores.
info "Creando usuario '$USUARIO'"

if pw usershow "$USUARIO" >/dev/null 2>&1; then
    echo "El usuario '$USUARIO' ya existe, se omite la creación."
else
    # -m : crea la carpeta home
    # -s : shell del usuario
    pw useradd -n "$USUARIO" -m -s "$SHELL_USUARIO" -c "$USUARIO"

    echo "Asigna la contraseña para '$USUARIO':"
    passwd "$USUARIO"
fi

# ---------------------------------------------------------------------------
# 4. Grupos
# ---------------------------------------------------------------------------
# Usamos "pw groupmod -m" en lugar de "pw usermod -G" porque -G REEMPLAZA
# todos los grupos del usuario, mientras que groupmod -m solo lo AGREGA.
info "Agregando '$USUARIO' a los grupos: $GRUPOS"

for grupo in $GRUPOS; do
    if pw groupshow "$grupo" >/dev/null 2>&1; then
        pw groupmod "$grupo" -m "$USUARIO"
        echo "  + $grupo"
    else
        echo "  ! El grupo '$grupo' no existe, se omite."
    fi
done

# ---------------------------------------------------------------------------
# 5. sudo
# ---------------------------------------------------------------------------
# En FreeBSD, sudo es un paquete (se instaló en el paso 1) y su
# configuración vive en /usr/local/etc/sudoers. Ese archivo ya trae la
# línea "%wheel ALL=(ALL:ALL) ALL" comentada; solo hay que quitarle el "#".
# Como el usuario ya está en el grupo wheel (paso 4), con eso basta.
#
# Es lo mismo que haces a mano con visudo, pero automatizado con sed.
info "Habilitando sudo para el grupo wheel"

SUDOERS="/usr/local/etc/sudoers"
REGLA_WHEEL='%wheel ALL=(ALL:ALL) ALL'

# grep -q : no imprime nada, solo indica si encontró la línea
#      -x : la línea completa debe coincidir (no solo una parte)
#      -F : busca el texto tal cual, sin interpretar ( ) como regex
if grep -qxF "$REGLA_WHEEL" "$SUDOERS"; then
    echo "La regla ya está habilitada, se omite."
else
    SUDOERS_TMP="$(mktemp)"

    # sed quita el "#" de la línea comentada y deja el resto igual:
    #   ^#[[:space:]]*  : "#" al inicio de la línea + espacios opcionales
    #   \( ... \)       : guarda el resto de la línea como \1
    #   s/.../\1/       : reemplaza la línea completa por solo \1
    sed 's/^#[[:space:]]*\(%wheel ALL=(ALL:ALL) ALL\)$/\1/' \
        "$SUDOERS" > "$SUDOERS_TMP"

    # Si sed no cambió nada, la línea comentada no estaba en el archivo
    if ! grep -qxF "$REGLA_WHEEL" "$SUDOERS_TMP"; then
        rm -f "$SUDOERS_TMP"
        error "No se encontró la línea '# $REGLA_WHEEL' en $SUDOERS"
    fi

    # visudo -c valida la sintaxis ANTES de reemplazar el archivo real.
    # Un sudoers con errores puede dejarte sin poder usar sudo.
    if visudo -cf "$SUDOERS_TMP" >/dev/null; then
        # install copia el archivo y le asigna dueño y permisos en un solo paso
        install -o root -g wheel -m 0440 "$SUDOERS_TMP" "$SUDOERS"
        echo "Habilitada la línea '$REGLA_WHEEL' en $SUDOERS"
    else
        rm -f "$SUDOERS_TMP"
        error "El sudoers modificado no es válido; no se aplicó el cambio"
    fi
    rm -f "$SUDOERS_TMP"
fi

# ---------------------------------------------------------------------------
# 6. Descargar archivos de configuración al home del usuario
# ---------------------------------------------------------------------------
# El campo 9 de "pw usershow" es la carpeta home del usuario.
HOME_USUARIO="$(pw usershow "$USUARIO" | cut -d: -f9)"

info "Descargando archivos de configuración en $HOME_USUARIO"

for entrada in $ARCHIVOS; do
    # Separa "origen:destino" usando expansión de parámetros:
    #   ${var%%:*} borra desde el primer ":" hasta el final  -> origen
    #   ${var#*:}  borra desde el inicio hasta el primer ":" -> destino
    origen="${entrada%%:*}"
    destino="$HOME_USUARIO/${entrada#*:}"

    # Crea la carpeta destino (por ejemplo ~/.config) con el dueño correcto
    install -d -o "$USUARIO" -g "$USUARIO" "$(dirname "$destino")"

    # Si ya existe el archivo, guarda un respaldo con la fecha
    if [ -f "$destino" ]; then
        cp "$destino" "$destino.bak.$(date +%Y%m%d%H%M%S)"
    fi

    # fetch viene incluido en FreeBSD (equivale a curl/wget)
    tmp="$(mktemp)"
    fetch -q -o "$tmp" "$REPO_RAW/$origen"

    # Como el script corre como root, hay que dejar el archivo a nombre
    # del usuario; si no, KDE no podría modificarlo.
    install -o "$USUARIO" -g "$USUARIO" -m 0644 "$tmp" "$destino"
    rm -f "$tmp"

    echo "  + $destino"
done

# ---------------------------------------------------------------------------
# Fin
# ---------------------------------------------------------------------------
info "Listo. Reinicia el sistema (shutdown -r now) para aplicar todo."
