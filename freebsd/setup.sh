#!/bin/sh
#
# setup.sh — Configuración inicial de FreeBSD + KDE
#
# Qué hace:
#   1. Habilita servicios en /etc/rc.conf (con sysrc)
#   2. Crea un usuario nuevo (si no existe)
#   3. Lo agrega a los grupos wheel, video y operator
#   4. Instala sudo y le da permisos en sudoers
#   5. Descarga archivos de configuración desde GitHub a su carpeta home
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
# 1. Servicios en /etc/rc.conf
# ---------------------------------------------------------------------------
# sysrc es la herramienta oficial para editar rc.conf: evita líneas
# duplicadas y errores de sintaxis que pueden pasar al editar a mano.
info "Habilitando servicios en /etc/rc.conf"

for servicio in $SERVICIOS; do
    sysrc "${servicio}_enable=YES"
done

# ---------------------------------------------------------------------------
# 2. Crear el usuario
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
# 3. Grupos
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
# 4. sudo
# ---------------------------------------------------------------------------
# En FreeBSD, sudo es un paquete y su configuración vive en /usr/local/etc.
# En vez de editar el archivo sudoers principal, creamos uno propio dentro
# de sudoers.d. Así es más fácil de mantener y de borrar.
info "Instalando y configurando sudo"

# -y responde "sí" automáticamente
pkg install -y sudo

SUDOERS_ARCHIVO="/usr/local/etc/sudoers.d/$USUARIO"
SUDOERS_TMP="$(mktemp)"

echo "$USUARIO ALL=(ALL:ALL) ALL" > "$SUDOERS_TMP"

# visudo -c valida la sintaxis ANTES de instalar el archivo.
# Un sudoers con errores puede dejarte sin poder usar sudo.
if visudo -cf "$SUDOERS_TMP" >/dev/null; then
    # install copia el archivo y le asigna dueño y permisos en un solo paso
    install -o root -g wheel -m 0440 "$SUDOERS_TMP" "$SUDOERS_ARCHIVO"
    echo "Creado $SUDOERS_ARCHIVO"
else
    rm -f "$SUDOERS_TMP"
    error "La regla de sudoers no es válida"
fi
rm -f "$SUDOERS_TMP"

# ---------------------------------------------------------------------------
# 5. Descargar archivos de configuración al home del usuario
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
