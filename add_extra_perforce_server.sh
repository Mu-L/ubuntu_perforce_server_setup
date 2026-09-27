#!/usr/bin/env bash

# ==============================================================================
# Perforce Secondary Server Installer
# ==============================================================================
#
# Creates an additional independent Helix Core (p4d) server instance using
# p4dctl.
#
# Intended for Unreal Engine projects.
#
# An existing Perforce server is selected as the source for the Unreal typemap.
#
# Requirements:
#   - Ubuntu/Debian
#   - helix-p4d installed
#   - p4d
#   - p4dctl
#   - p4 client
#   - perforce OS user/group
#   - sudo/root
#
# Usage:
#   sudo ./install-perforce-secondary.sh
#   sudo ./install-perforce-secondary.sh --dry-run
#
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Colours / output
# ------------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

log()
{
    echo -e "${BLUE}[INFO]${NC} $*"
}

ok()
{
    echo -e "${GREEN}[ OK ]${NC} $*"
}

warn()
{
    echo -e "${YELLOW}[WARN]${NC} $*"
}

fail()
{
    echo -e "${RED}[FAIL]${NC} $*" >&2
    exit 1
}

section()
{
    echo
    echo "--------------------------------------------------------------"
    echo " $*"
    echo "--------------------------------------------------------------"
    echo
}

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------

DRY_RUN=false

P4D_BIN=""
P4DCTL_BIN=""
P4_BIN=""

PERFORCE_USER=""
PERFORCE_GROUP=""

# Existing server selected as the source for the Unreal typemap.
SOURCE_SERVICE=""
SOURCE_PORT=""
SOURCE_ROOT=""
SOURCE_USER=""

# New server.
SERVICE_NAME=""
P4PORT=""
INSTANCE_BASE=""
ROOT_DIR=""
SSL_DIR=""

LOG_FILE=""
JOURNAL_DIR=""
ARCHIVE_DIR=""
LOG_DIR=""

ADMIN_USER=""
ADMIN_EMAIL=""
ADMIN_FULLNAME=""
ADMIN_PASSWORD=""

SOURCE_PASSWORD=""

# Authentication files for the new server.
NEW_TICKET_FILE=""
NEW_TRUST_FILE=""

ENABLE_UFW=true
ENABLE_MAINTENANCE=true
ENABLE_SECURITY_SETTINGS=true

TMP_FILES=()

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

cleanup()
{
    local file

    for file in "${TMP_FILES[@]:-}"; do
        [[ -n "$file" ]] && rm -f "$file" 2>/dev/null || true
    done
}

trap cleanup EXIT

# ------------------------------------------------------------------------------
# Error handler
# ------------------------------------------------------------------------------

on_error()
{
    local exit_code=$?
    local line_number=$1

    trap - ERR

    echo
    echo -e "${RED}[FAIL]${NC} Installer failed at line ${line_number}."
    echo -e "${RED}[FAIL]${NC} No existing Perforce instance was intentionally modified."
    echo

    exit "$exit_code"
}

trap 'on_error $LINENO' ERR

# ------------------------------------------------------------------------------
# Root check
# ------------------------------------------------------------------------------

require_root()
{
    if [[ "${EUID}" -ne 0 ]]; then
        fail "This installer must be run as root. Use sudo."
    fi
}

# ------------------------------------------------------------------------------
# Detect installation
# ------------------------------------------------------------------------------

detect_binaries()
{
    section "Detecting Perforce Installation"

    P4D_BIN="$(command -v p4d || true)"
    P4DCTL_BIN="$(command -v p4dctl || true)"
    P4_BIN="$(command -v p4 || true)"

    [[ -x "$P4D_BIN" ]] ||
        fail "p4d not found in PATH."

    [[ -x "$P4DCTL_BIN" ]] ||
        fail "p4dctl not found in PATH."

    [[ -x "$P4_BIN" ]] ||
        fail "p4 client not found in PATH."

    ok "p4d:    $P4D_BIN"
    ok "p4dctl: $P4DCTL_BIN"
    ok "p4:     $P4_BIN"
}

# ------------------------------------------------------------------------------
# Detect Perforce user
# ------------------------------------------------------------------------------

detect_perforce_user()
{
    section "Detecting Perforce User"

    if ! id perforce >/dev/null 2>&1; then
        fail "OS user 'perforce' does not exist."
    fi

    PERFORCE_USER="perforce"
    PERFORCE_GROUP="$(id -gn "$PERFORCE_USER")"

    ok "User:  $PERFORCE_USER"
    ok "Group: $PERFORCE_GROUP"
}

# ------------------------------------------------------------------------------
# Check p4dctl configuration
# ------------------------------------------------------------------------------

check_p4dctl_configuration()
{
    section "Checking p4dctl Configuration"

    [[ -f "/etc/perforce/p4dctl.conf" ]] ||
        fail "Missing p4dctl configuration: /etc/perforce/p4dctl.conf"

    [[ -d "/etc/perforce/p4dctl.conf.d" ]] ||
        fail "Missing p4dctl configuration directory: /etc/perforce/p4dctl.conf.d"

    if ! grep -Eq \
        '^[[:space:]]*include[[:space:]]+/etc/perforce/p4dctl\.conf\.d[[:space:]]*$' \
        "/etc/perforce/p4dctl.conf"
    then
        warn "The expected p4dctl.conf.d include was not found."
        warn "This installer will continue, but verify your p4dctl configuration."
    fi

    # p4dctl itself must be run as root.
    #
    # Owner = perforce in each service configuration controls the OS user
    # running the actual p4d process.
    if ! "$P4DCTL_BIN" list >/dev/null; then
        fail "Existing p4dctl configuration cannot be parsed."
    fi

    ok "Existing p4dctl configuration parses correctly."
}

# ------------------------------------------------------------------------------
# Extract configuration value
# ------------------------------------------------------------------------------

get_config_value()
{
    local file="$1"
    local key="$2"

    awk -F= -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value=$2

            gsub(/^[[:space:]]+/, "", value)
            gsub(/[[:space:]]+$/, "", value)

            gsub(/^"/, "", value)
            gsub(/"$/, "", value)

            print value
            exit
        }
    ' "$file"
}

# ------------------------------------------------------------------------------
# Discover source server
# ------------------------------------------------------------------------------

discover_source_server()
{
    section "Discovering Existing Perforce Servers"

    local configs=()
    local config
    local service
    local port
    local root
    local user
    local index=0
    local choice

    while IFS= read -r config; do

        [[ -f "$config" ]] || continue

        service="$(
            awk '
                /^[[:space:]]*p4d[[:space:]]+/ {
                    print $2
                    exit
                }
            ' "$config"
        )"

        [[ -n "$service" ]] || continue

        port="$(get_config_value "$config" P4PORT)"
        root="$(get_config_value "$config" P4ROOT)"
        user="$(get_config_value "$config" P4USER)"

        [[ -n "$port" ]] || continue
        [[ -n "$root" ]] || continue

        configs+=("$config")

        ((index += 1))

        echo "  $index) $service"
        echo "     P4PORT: $port"
        echo "     P4ROOT: $root"

        if [[ -n "$user" ]]; then
            echo "     P4USER: $user"
        fi

        echo

    done < <(
        find /etc/perforce/p4dctl.conf.d \
            -maxdepth 1 \
            -type f \
            -name '*.conf' \
            -print |
        sort
    )

    (( index > 0 )) ||
        fail "No existing Perforce servers were found."

    echo

    read -r -p \
        "Select the server to clone the Unreal typemap from [1]: " \
        choice

    choice="${choice:-1}"

    [[ "$choice" =~ ^[0-9]+$ ]] ||
        fail "Invalid server selection."

    (( choice >= 1 && choice <= index )) ||
        fail "Invalid server selection: $choice"

    config="${configs[$((choice - 1))]}"

    SOURCE_SERVICE="$(
        awk '
            /^[[:space:]]*p4d[[:space:]]+/ {
                print $2
                exit
            }
        ' "$config"
    )"

    SOURCE_PORT="$(get_config_value "$config" P4PORT)"
    SOURCE_ROOT="$(get_config_value "$config" P4ROOT)"
    SOURCE_USER="$(get_config_value "$config" P4USER)"

    SOURCE_USER="${SOURCE_USER:-AdminUser}"

    ok "Typemap source selected:"
    ok "  Service: $SOURCE_SERVICE"
    ok "  P4PORT:  $SOURCE_PORT"
    ok "  P4ROOT:  $SOURCE_ROOT"
    ok "  P4USER:  $SOURCE_USER"
}

# ------------------------------------------------------------------------------
# Extract numeric port
# ------------------------------------------------------------------------------

extract_port_number()
{
    local port="$1"

    if [[ "$port" =~ :([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
    else
        echo ""
    fi
}

# ------------------------------------------------------------------------------
# Find next free port
# ------------------------------------------------------------------------------

find_next_port()
{
    local port=1667
    local used=false
    local config
    local existing_port
    local existing_port_number

    while true; do

        used=false

        while IFS= read -r config; do

            [[ -f "$config" ]] || continue

            existing_port="$(get_config_value "$config" P4PORT)"
            existing_port_number="$(extract_port_number "$existing_port")"

            if [[ "$existing_port_number" == "$port" ]]; then
                used=true
                break
            fi

        done < <(
            find /etc/perforce/p4dctl.conf.d \
                -maxdepth 1 \
                -type f \
                -name '*.conf' \
                -print
        )

        if [[ "$used" == false ]]; then

            if command -v ss >/dev/null 2>&1; then

                if ! ss -lnt 2>/dev/null |
                    grep -Eq ":${port}[[:space:]]"
                then
                    echo "$port"
                    return
                fi

            else
                echo "$port"
                return
            fi
        fi

        ((port += 1))
    done
}

# ------------------------------------------------------------------------------
# User input
# ------------------------------------------------------------------------------

collect_configuration()
{
    section "New Perforce Server Configuration"

    local suggested_port
    local port_number
    local default_root
    local source_parent
    local answer

    suggested_port="$(find_next_port)"

    read -r -p "Service name [project3]: " SERVICE_NAME
    SERVICE_NAME="${SERVICE_NAME:-project3}"

    if [[ ! "$SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        fail "Invalid service name: $SERVICE_NAME"
    fi

    read -r -p "Port [$suggested_port]: " port_number
    port_number="${port_number:-$suggested_port}"

    if [[ ! "$port_number" =~ ^[0-9]+$ ]]; then
        fail "Invalid port: $port_number"
    fi

    if (( port_number < 1024 || port_number > 65535 )); then
        fail "Port must be between 1024 and 65535."
    fi

    # --------------------------------------------------------------------------
    # Preserve the source P4PORT format.
    #
    # Example:
    #
    #   Source = ssl:SERVER:1666
    #   New    = ssl:SERVER:1667
    #
    # Or:
    #
    #   Source = ssl:1666
    #   New    = ssl:1667
    # --------------------------------------------------------------------------

    if [[ "$SOURCE_PORT" =~ ^([^:]+):(.+):([0-9]+)$ ]]; then

        P4PORT="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${port_number}"

    elif [[ "$SOURCE_PORT" =~ ^([^:]+):([0-9]+)$ ]]; then

        P4PORT="${BASH_REMATCH[1]}:${port_number}"

    else
        fail "Unable to derive new P4PORT from source P4PORT: $SOURCE_PORT"
    fi

    # --------------------------------------------------------------------------
    # Derive the new instance from the source P4ROOT.
    #
    # Source:
    #
    #   /mnt/DRIVE/Perforce/root
    #
    # New project3:
    #
    #   /mnt/DRIVE/Perforce/project3/root
    # --------------------------------------------------------------------------

    source_parent="$(dirname "$SOURCE_ROOT")"
    default_root="$source_parent/$SERVICE_NAME/root"

    read -r -p "P4ROOT [$default_root]: " ROOT_DIR
    ROOT_DIR="${ROOT_DIR:-$default_root}"

    INSTANCE_BASE="$(dirname "$ROOT_DIR")"

    SSL_DIR="$ROOT_DIR/ssl"

    # --------------------------------------------------------------------------
    # Administrator
    # --------------------------------------------------------------------------

    read -r -p "Admin username [AdminUser]: " ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-AdminUser}"

    read -r -p "Admin email [${ADMIN_USER}@localhost]: " ADMIN_EMAIL
    ADMIN_EMAIL="${ADMIN_EMAIL:-${ADMIN_USER}@localhost}"

    read -r -p "Admin full name [${ADMIN_USER}]: " ADMIN_FULLNAME
    ADMIN_FULLNAME="${ADMIN_FULLNAME:-${ADMIN_USER}}"

    # --------------------------------------------------------------------------
    # Passwords
    # --------------------------------------------------------------------------

    if [[ "$DRY_RUN" == true ]]; then

        ADMIN_PASSWORD="<dry-run>"
        SOURCE_PASSWORD="<dry-run>"

    else

        echo
        read -r -s -p "New server admin password: " ADMIN_PASSWORD
        echo

        [[ -n "$ADMIN_PASSWORD" ]] ||
            fail "Admin password cannot be empty."

        echo
        echo "The SOURCE server password is required only to read"
        echo "the existing Unreal typemap."
        echo

        read -r -s \
            -p "SOURCE admin password ($SOURCE_USER): " \
            SOURCE_PASSWORD

        echo

        [[ -n "$SOURCE_PASSWORD" ]] ||
            fail "SOURCE password cannot be empty."

    fi

    # --------------------------------------------------------------------------
    # Optional settings
    # --------------------------------------------------------------------------

    echo
    read -r -p "Enable UFW rule for TCP $port_number? [Y/n]: " answer

    case "${answer:-Y}" in
        y|Y|yes|YES)
            ENABLE_UFW=true
            ;;
        *)
            ENABLE_UFW=false
            ;;
    esac

    echo
    read -r -p "Enable MAINTENANCE=true? [Y/n]: " answer

    case "${answer:-Y}" in
        y|Y|yes|YES)
            ENABLE_MAINTENANCE=true
            ;;
        *)
            ENABLE_MAINTENANCE=false
            ;;
    esac

    echo
    read -r -p \
        "Apply standard Perforce security settings? [Y/n]: " \
        answer

    case "${answer:-Y}" in
        y|Y|yes|YES)
            ENABLE_SECURITY_SETTINGS=true
            ;;
        *)
            ENABLE_SECURITY_SETTINGS=false
            ;;
    esac

    # --------------------------------------------------------------------------
    # Per-instance storage
    # --------------------------------------------------------------------------

    JOURNAL_DIR="$INSTANCE_BASE/journals"
    ARCHIVE_DIR="$INSTANCE_BASE/archives"

    LOG_DIR="/var/log/perforce"
    LOG_FILE="$LOG_DIR/$SERVICE_NAME.log"

    # --------------------------------------------------------------------------
    # Display configuration
    # --------------------------------------------------------------------------

    echo
    echo "Configuration:"
    echo
    echo "  Source service: $SOURCE_SERVICE"
    echo "  Source P4PORT:  $SOURCE_PORT"
    echo
    echo "  New service:    $SERVICE_NAME"
    echo "  New P4PORT:     $P4PORT"
    echo "  P4ROOT:         $ROOT_DIR"
    echo "  Instance base:  $INSTANCE_BASE"
    echo "  SSL:            $SSL_DIR"
    echo "  Journal dir:    $JOURNAL_DIR"
    echo "  Archive dir:    $ARCHIVE_DIR"
    echo "  Log file:       $LOG_FILE"
    echo "  p4dctl config:  /etc/perforce/p4dctl.conf.d/$SERVICE_NAME.conf"
    echo "  Admin:          $ADMIN_USER"
    echo
}

# ------------------------------------------------------------------------------
# Collision checks
# ------------------------------------------------------------------------------

check_for_collisions()
{
    section "Checking For Configuration Collisions"

    local config
    local existing_service
    local existing_port
    local existing_root
    local new_config
    local new_port_number
    local existing_port_number
    local root_contents

    new_config="/etc/perforce/p4dctl.conf.d/$SERVICE_NAME.conf"

    new_port_number="$(extract_port_number "$P4PORT")"

    # --------------------------------------------------------------------------
    # Config file
    # --------------------------------------------------------------------------

    if [[ -e "$new_config" ]]; then
        fail "Configuration already exists: $new_config"
    fi

    # --------------------------------------------------------------------------
    # Existing p4dctl instances
    # --------------------------------------------------------------------------

    while IFS= read -r config; do

        [[ -f "$config" ]] || continue

        existing_service="$(
            awk '
                /^[[:space:]]*p4d[[:space:]]+/ {
                    print $2
                    exit
                }
            ' "$config"
        )"

        if [[ "$existing_service" == "$SERVICE_NAME" ]]; then
            fail "Service '$SERVICE_NAME' already exists in $config"
        fi

        existing_port="$(get_config_value "$config" P4PORT)"

        if [[ -n "$existing_port" ]]; then

            existing_port_number="$(extract_port_number "$existing_port")"

            if [[ -n "$existing_port_number" &&
                  "$existing_port_number" == "$new_port_number" ]]; then

                fail "Port '$P4PORT' is already configured in $config"
            fi
        fi

        existing_root="$(get_config_value "$config" P4ROOT)"

        if [[ -n "$existing_root" &&
              "$existing_root" == "$ROOT_DIR" ]]; then

            fail "P4ROOT '$ROOT_DIR' is already configured in $config"
        fi

    done < <(
        find /etc/perforce/p4dctl.conf.d \
            -maxdepth 1 \
            -type f \
            -name '*.conf' \
            -print
    )

    # --------------------------------------------------------------------------
    # Physical P4ROOT
    # --------------------------------------------------------------------------

    if [[ -e "$ROOT_DIR" ]]; then

        root_contents="$(
            find "$ROOT_DIR" \
                -mindepth 1 \
                -maxdepth 1 \
                -print \
                -quit \
                2>/dev/null
        )"

        if [[ -n "$root_contents" ]]; then
            fail "P4ROOT already exists and is not empty: $ROOT_DIR"
        fi

        warn "P4ROOT already exists but is empty: $ROOT_DIR"
    fi

    # --------------------------------------------------------------------------
    # SSL
    # --------------------------------------------------------------------------

    if [[ -e "$SSL_DIR" ]]; then
        fail "SSL directory already exists: $SSL_DIR"
    fi

    # --------------------------------------------------------------------------
    # Instance directory
    # --------------------------------------------------------------------------

    if [[ -e "$INSTANCE_BASE" ]]; then
        fail "Instance directory already exists: $INSTANCE_BASE"
    fi

    # --------------------------------------------------------------------------
    # Log
    # --------------------------------------------------------------------------

    if [[ -e "$LOG_FILE" ]]; then
        fail "Log file already exists: $LOG_FILE"
    fi

    ok "No configuration collisions detected."
}

# ------------------------------------------------------------------------------
# Validate storage paths
# ------------------------------------------------------------------------------

validate_paths()
{
    section "Validating Storage Paths"

    local existing_parent
    local log_parent

    # --------------------------------------------------------------------------
    # The instance directory does not need to exist yet.
    #
    # Find the nearest parent that does exist.
    # --------------------------------------------------------------------------

    existing_parent="$INSTANCE_BASE"

    while [[ ! -e "$existing_parent" ]]; do

        existing_parent="$(dirname "$existing_parent")"

        if [[ "$existing_parent" == "/" ]]; then
            fail "Could not find an existing parent directory for: $INSTANCE_BASE"
        fi

    done

    if [[ ! -d "$existing_parent" ]]; then
        fail "Existing parent is not a directory: $existing_parent"
    fi

    if [[ ! -w "$existing_parent" ]]; then
        fail "Existing parent directory is not writable: $existing_parent"
    fi

    log "Existing storage parent: $existing_parent"

    # --------------------------------------------------------------------------
    # Log directory may also need to be created.
    # --------------------------------------------------------------------------

    log_parent="$(dirname "$LOG_FILE")"

    while [[ ! -e "$log_parent" ]]; do

        log_parent="$(dirname "$log_parent")"

        if [[ "$log_parent" == "/" ]]; then
            fail "Could not find an existing parent for log file: $LOG_FILE"
        fi

    done

    if [[ ! -d "$log_parent" ]]; then
        fail "Log parent is not a directory: $log_parent"
    fi

    if [[ ! -w "$log_parent" ]]; then
        fail "Log parent is not writable: $log_parent"
    fi

    ok "Storage paths are valid."
}

# ------------------------------------------------------------------------------
# Create directories
# ------------------------------------------------------------------------------

create_directories()
{
    section "Creating Perforce Directories"

    mkdir -p \
        "$ROOT_DIR" \
        "$ROOT_DIR/ssl" \
        "$JOURNAL_DIR" \
        "$ARCHIVE_DIR" \
        "$LOG_DIR"

    chown -R \
        "$PERFORCE_USER:$PERFORCE_GROUP" \
        "$ROOT_DIR" \
        "$JOURNAL_DIR" \
        "$ARCHIVE_DIR"

    chmod 700 \
        "$ROOT_DIR" \
        "$ROOT_DIR/ssl" \
        "$JOURNAL_DIR" \
        "$ARCHIVE_DIR"

    # P4LOG is a FILE, not a directory.
    touch "$LOG_FILE"

    chown \
        "$PERFORCE_USER:$PERFORCE_GROUP" \
        "$LOG_FILE"

    chmod 600 "$LOG_FILE"

    ok "Directories created."
}

# ------------------------------------------------------------------------------
# Generate SSL
# ------------------------------------------------------------------------------

generate_ssl()
{
    section "Generating SSL Certificate"

    sudo -u "$PERFORCE_USER" env \
        P4SSLDIR="$SSL_DIR" \
        "$P4D_BIN" \
        -r "$ROOT_DIR" \
        -Gc

    chown -R \
        "$PERFORCE_USER:$PERFORCE_GROUP" \
        "$SSL_DIR"

    chmod 700 "$SSL_DIR"

    ok "SSL certificate generated."
}

# ------------------------------------------------------------------------------
# Generate p4dctl configuration
# ------------------------------------------------------------------------------

generate_p4dctl_config()
{
    section "Creating p4dctl Configuration"

    local config="/etc/perforce/p4dctl.conf.d/$SERVICE_NAME.conf"

    cat > "$config" <<EOF
#-------------------------------------------------------------------------------
# p4dctl configuration file for Helix Core Server
#-------------------------------------------------------------------------------

p4d $SERVICE_NAME
{
    Owner    =  $PERFORCE_USER
    Execute  =  $P4D_BIN
    Umask    =  077
    Enabled  =  true

    Environment
    {
        P4PORT    =      $P4PORT
        P4LOG     =      $LOG_FILE
        P4ROOT    =      $ROOT_DIR
        P4USER    =      $ADMIN_USER
        P4SSLDIR  =      $SSL_DIR
        P4JOURNAL =      $JOURNAL_DIR/journal
        PATH      =      /bin:/usr/bin:/usr/local/bin:/opt/perforce/bin:/opt/perforce/sbin
EOF

    if [[ "$ENABLE_MAINTENANCE" == true ]]; then
        echo "        MAINTENANCE =   true" >> "$config"
    fi

    cat >> "$config" <<EOF
    }
}
EOF

    chown root:root "$config"
    chmod 644 "$config"

    # Validate the new config BEFORE starting p4d.
    if ! "$P4DCTL_BIN" list >/dev/null; then

        rm -f "$config"

        fail "New p4dctl configuration failed validation. It has been removed."
    fi

    ok "Created and validated $config"
}

# ------------------------------------------------------------------------------
# Configure UFW
# ------------------------------------------------------------------------------

configure_ufw()
{
    section "Configuring Firewall"

    if [[ "$ENABLE_UFW" != true ]]; then
        warn "UFW configuration skipped."
        return
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        warn "UFW is not installed. Skipping firewall configuration."
        return
    fi

    local port_number

    port_number="$(extract_port_number "$P4PORT")"

    ufw allow "$port_number/tcp"

    ok "UFW rule added for TCP $port_number."
}

# ------------------------------------------------------------------------------
# Start server
# ------------------------------------------------------------------------------

start_server()
{
    section "Starting Perforce Server"

    echo
    echo "DEBUG: service state immediately before start:"
    "$P4DCTL_BIN" status "$SERVICE_NAME" || true

    if ! "$P4DCTL_BIN" start "$SERVICE_NAME"; then
        fail "Failed to start p4d instance '$SERVICE_NAME'."
    fi

    ok "p4dctl start command completed for $SERVICE_NAME."
}

# ------------------------------------------------------------------------------
# Wait for server
# ------------------------------------------------------------------------------

wait_for_server()
{
    section "Waiting For Perforce Server"

    local port_number
    local attempt

    port_number="$(extract_port_number "$P4PORT")"

    for attempt in {1..30}; do

        if ss -lntH 2>/dev/null |
            awk -v port="$port_number" '
                $4 ~ ":" port "$" {
                    found=1
                    exit
                }
                END {
                    exit(found ? 0 : 1)
                }
            '
        then
            ok "Perforce is listening on TCP $port_number."
            return
        fi

        sleep 1
    done

    echo
    echo "Current listening sockets:"
    ss -lnt 2>/dev/null || true
    echo

    fail "Perforce did not begin listening on TCP $port_number."
}

# ------------------------------------------------------------------------------
# Prepare temporary file for Perforce user
# ------------------------------------------------------------------------------

make_temp_for_perforce()
{
    local file="$1"

    chown "$PERFORCE_USER:$PERFORCE_GROUP" "$file"
    chmod 600 "$file"
}

# ------------------------------------------------------------------------------
# Create administrator
# ------------------------------------------------------------------------------

create_admin()
{
    section "Creating Perforce Administrator"

    local form_file
    local ticket_file
    local trust_file

    form_file="$(mktemp)"
    ticket_file="$(mktemp)"
    trust_file="$(mktemp)"

    TMP_FILES+=(
        "$form_file"
        "$ticket_file"
        "$trust_file"
    )

    # Write the user form while root owns the file.
    cat > "$form_file" <<EOF
User: $ADMIN_USER
Email: $ADMIN_EMAIL
FullName: $ADMIN_FULLNAME
EOF

    # Now give the temporary files to the Perforce OS user.
    make_temp_for_perforce "$form_file"
    make_temp_for_perforce "$ticket_file"
    make_temp_for_perforce "$trust_file"

    NEW_TICKET_FILE="$ticket_file"
    NEW_TRUST_FILE="$trust_file"

    # Trust the new server's SSL certificate.
    sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4TICKETS="$ticket_file" \
        P4TRUST="$trust_file" \
        "$P4_BIN" trust -y >/dev/null 2>&1 || true

    # Create the administrator.
    sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$ticket_file" \
        P4TRUST="$trust_file" \
        "$P4_BIN" user -i -f < "$form_file" \
        || fail "Failed to create Perforce administrator '$ADMIN_USER'."

    # Set the administrator password.
    printf '%s\n%s\n' \
        "$ADMIN_PASSWORD" \
        "$ADMIN_PASSWORD" |
        sudo -u "$PERFORCE_USER" env \
            P4PORT="$P4PORT" \
            P4USER="$ADMIN_USER" \
            P4TICKETS="$ticket_file" \
            P4TRUST="$trust_file" \
            "$P4_BIN" passwd >/dev/null \
        || fail "Failed to set password for '$ADMIN_USER'."

    # Log in as the new administrator.
    # This creates the authenticated ticket used by later commands.
    printf '%s\n' "$ADMIN_PASSWORD" |
        sudo -u "$PERFORCE_USER" env \
            P4PORT="$P4PORT" \
            P4USER="$ADMIN_USER" \
            P4TICKETS="$ticket_file" \
            P4TRUST="$trust_file" \
            "$P4_BIN" login >/dev/null \
        || fail "Failed to authenticate administrator '$ADMIN_USER'."

    ok "Administrator '$ADMIN_USER' created and authenticated."
}

# ------------------------------------------------------------------------------
# Configure protections
# ------------------------------------------------------------------------------

configure_protections()
{
    section "Configuring Protections"

    local protect_file

    protect_file="$(mktemp)"

    TMP_FILES+=("$protect_file")

    # Write while root owns the file.
    cat > "$protect_file" <<EOF
Protections:
	super user $ADMIN_USER * //...
EOF

    # Then give the file to the Perforce user.
    chown "$PERFORCE_USER:$PERFORCE_GROUP" "$protect_file"
    chmod 600 "$protect_file"

    if ! sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$NEW_TICKET_FILE" \
        P4TRUST="$NEW_TRUST_FILE" \
        "$P4_BIN" protect -i < "$protect_file"
    then
        fail "Failed to configure protections."
    fi

    ok "Protections configured."
}

# ------------------------------------------------------------------------------
# Configure security
# ------------------------------------------------------------------------------

configure_security()
{
    section "Configuring Perforce Security"

    if [[ "$ENABLE_SECURITY_SETTINGS" != true ]]; then
        warn "Security configurables skipped."
        return
    fi

    sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$NEW_TICKET_FILE" \
        P4TRUST="$NEW_TRUST_FILE" \
        "$P4_BIN" configure set net.rfc3484=1

    sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$NEW_TICKET_FILE" \
        P4TRUST="$NEW_TRUST_FILE" \
        "$P4_BIN" configure set dm.user.noautocreate=2

    sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$NEW_TICKET_FILE" \
        P4TRUST="$NEW_TRUST_FILE" \
        "$P4_BIN" configure set run.users.authorize=1

    ok "Security settings applied."
}

# ------------------------------------------------------------------------------
# Configure journal
# ------------------------------------------------------------------------------

configure_journal()
{
    section "Configuring Journal"

    sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$NEW_TICKET_FILE" \
        P4TRUST="$NEW_TRUST_FILE" \
        "$P4_BIN" configure set \
        "journalPrefix=$JOURNAL_DIR/journal"

    ok "Journal prefix configured."
}

# ------------------------------------------------------------------------------
# Clone Unreal typemap from source
# ------------------------------------------------------------------------------

copy_unreal_typemap()
{
    section "Cloning Unreal Typemap From Source"

    local typemap_file
    local source_ticket_file
    local source_trust_file
    local new_typemap_file

    typemap_file="$(mktemp)"
    source_ticket_file="$(mktemp)"
    source_trust_file="$(mktemp)"
    new_typemap_file="$(mktemp)"

    TMP_FILES+=(
        "$typemap_file"
        "$source_ticket_file"
        "$source_trust_file"
        "$new_typemap_file"
    )

    # The ticket/trust files are accessed directly by p4 running as
    # the Perforce OS user.
    chmod 600 \
        "$source_ticket_file" \
        "$source_trust_file"

    chown \
        "$PERFORCE_USER:$PERFORCE_GROUP" \
        "$source_ticket_file" \
        "$source_trust_file"

    # Typemap files are intentionally left root-owned.
    #
    # The shell performs the redirection as root, while p4 itself runs
    # as the Perforce user. The file descriptor is already open when
    # p4 receives stdin/stdout.

    chmod 600 \
        "$typemap_file" \
        "$new_typemap_file"

    # --------------------------------------------------------------------------
    # Trust source server
    # --------------------------------------------------------------------------

    sudo -u "$PERFORCE_USER" env \
        P4PORT="$SOURCE_PORT" \
        P4TRUST="$source_trust_file" \
        "$P4_BIN" trust -y >/dev/null 2>&1 || true

    # --------------------------------------------------------------------------
    # Login to source server
    # --------------------------------------------------------------------------

    if ! printf '%s\n' "$SOURCE_PASSWORD" |
        sudo -u "$PERFORCE_USER" env \
            P4PORT="$SOURCE_PORT" \
            P4USER="$SOURCE_USER" \
            P4TICKETS="$source_ticket_file" \
            P4TRUST="$source_trust_file" \
            "$P4_BIN" login >/dev/null
    then
        fail "Unable to authenticate to SOURCE Perforce server at $SOURCE_PORT."
    fi

    # --------------------------------------------------------------------------
    # Export source typemap
    # --------------------------------------------------------------------------

    if ! sudo -u "$PERFORCE_USER" env \
        P4PORT="$SOURCE_PORT" \
        P4USER="$SOURCE_USER" \
        P4TICKETS="$source_ticket_file" \
        P4TRUST="$source_trust_file" \
        "$P4_BIN" typemap -o > "$typemap_file"
    then
        fail "Failed to export SOURCE typemap."
    fi

    if [[ ! -s "$typemap_file" ]]; then
        fail "SOURCE typemap export is empty."
    fi

    ok "SOURCE Unreal typemap exported."

    # --------------------------------------------------------------------------
    # Import into new server
    # --------------------------------------------------------------------------

    if ! sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$NEW_TICKET_FILE" \
        P4TRUST="$NEW_TRUST_FILE" \
        "$P4_BIN" typemap -i < "$typemap_file"
    then
        fail "Failed to import Unreal typemap into $SERVICE_NAME."
    fi

    ok "Unreal typemap imported."

    # --------------------------------------------------------------------------
    # Verify
    # --------------------------------------------------------------------------

    if ! sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$NEW_TICKET_FILE" \
        P4TRUST="$NEW_TRUST_FILE" \
        "$P4_BIN" typemap -o > "$new_typemap_file"
    then
        fail "Failed to read back the new typemap."
    fi

    if diff -u "$typemap_file" "$new_typemap_file" >/dev/null; then

        ok "Typemap verified: identical to SOURCE."

    else

        echo
        warn "The new typemap differs from SOURCE:"
        diff -u "$typemap_file" "$new_typemap_file" || true

        fail "Typemap verification failed."
    fi
}

# ------------------------------------------------------------------------------
# Final verification
# ------------------------------------------------------------------------------

verify_server()
{
    section "Final Verification"

    echo "p4dctl instances:"
    "$P4DCTL_BIN" list

    echo
    echo "New server information:"

    if ! sudo -u "$PERFORCE_USER" env \
        P4PORT="$P4PORT" \
        P4USER="$ADMIN_USER" \
        P4TICKETS="$NEW_TICKET_FILE" \
        P4TRUST="$NEW_TRUST_FILE" \
        "$P4_BIN" info
    then
        fail "Final p4 info check failed."
    fi

    ok "Final verification completed."
}

# ------------------------------------------------------------------------------
# Dry run
# ------------------------------------------------------------------------------

show_dry_run()
{
    section "DRY RUN"

    echo "No changes have been made."
    echo
    echo "Would create:"
    echo
    echo "  Source service: $SOURCE_SERVICE"
    echo "  Source P4PORT:  $SOURCE_PORT"
    echo
    echo "  New service:    $SERVICE_NAME"
    echo "  P4PORT:         $P4PORT"
    echo "  P4ROOT:         $ROOT_DIR"
    echo "  SSL:            $SSL_DIR"
    echo "  Journal:        $JOURNAL_DIR"
    echo "  Archives:       $ARCHIVE_DIR"
    echo "  Log file:       $LOG_FILE"
    echo "  p4dctl config:  /etc/perforce/p4dctl.conf.d/$SERVICE_NAME.conf"
    echo "  Admin:          $ADMIN_USER"
    echo
    echo "Would clone Unreal typemap from:"
    echo
    echo "  $SOURCE_SERVICE ($SOURCE_PORT)"
    echo
    echo "Would configure UFW:"
    echo

    if [[ "$ENABLE_UFW" == true ]]; then
        echo "  TCP $(extract_port_number "$P4PORT")"
    else
        echo "  No"
    fi

    echo
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main()
{
    require_root

    if [[ "${1:-}" == "--dry-run" ]]; then
        DRY_RUN=true
    elif [[ $# -gt 0 ]]; then
        fail "Unknown argument: $1"
    fi

    section "Perforce Secondary Server Installer"

    detect_binaries
    detect_perforce_user
    check_p4dctl_configuration
    discover_source_server
    collect_configuration
    check_for_collisions
    validate_paths

    if [[ "$DRY_RUN" == true ]]; then
        show_dry_run
        exit 0
    fi

    create_directories
    generate_ssl
    generate_p4dctl_config
    configure_ufw

    start_server
    wait_for_server

    create_admin
    configure_protections
    configure_security
    configure_journal

    copy_unreal_typemap

    verify_server

    section "Installation Complete"

    ok "Perforce server '$SERVICE_NAME' is installed and running."

    echo
    echo "Connection:"
    echo
    echo "  $P4PORT"
    echo
    echo "P4ROOT:"
    echo
    echo "  $ROOT_DIR"
    echo
    echo "Admin:"
    echo
    echo "  $ADMIN_USER"
    echo
    echo "The Unreal typemap was cloned from:"
    echo
    echo "  $SOURCE_SERVICE ($SOURCE_PORT)"
    echo
}

main "$@"
