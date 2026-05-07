#!/usr/bin/env bash
###############################################################################
# Sleeplab Mac-mini Worker-Installer (Bootstrap)
#
# Wird auf der Mac-Mini-Maschine ausgefuehrt, die als Video-Worker dient.
# Generiert einen Deploy-Key fuer das private sleeplab-video-worker-Repo,
# erstellt die Email-Vorlage zur Freischaltung, klont das Repo und richtet
# den LaunchDaemon ein. Generiert ausserdem ein Self-Signed-TLS-Zertifikat
# fuer die HTTP-API.
#
# Verwendung:
#   curl -fsSL https://raw.githubusercontent.com/DarkRudolf/sleeplab-installer/main/install-mac-worker.sh -o install-mac-worker.sh
#   chmod +x install-mac-worker.sh
#   sudo ./install-mac-worker.sh
#
# Voraussetzung: macOS, Homebrew, ffmpeg via Homebrew installiert.
###############################################################################
set -euo pipefail

# ── Farben ──────────────────────────────────────────────────────
# ANSI-C-Quoting ($'...') legt die echten Escape-Bytes in die Variablen,
# damit auch heredocs (cat <<DONE) sie sauber rendern — nicht nur
# 'echo -e'. Frueher hatten die Vars literale '\033'-Strings, dann blieben
# sie im Final-Block als Text stehen statt zu faerben.
RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'; CYAN=$'\e[0;36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[FEHLER]${NC} $*"; }
log_phase() { echo -e "\n${BOLD}═══ $1 ═══${NC}"; }

# ── Konfiguration ────────────────────────────────────────────────
SUPPORT_EMAIL="${SUPPORT_EMAIL:-psg-viewer@marco-stankowitz.de}"
INSTALL_DIR="${INSTALL_DIR:-/opt/sleeplab-video-worker}"
WORKER_REPO="DarkRudolf/sleeplab-video-worker"

SSH_DIR="/etc/sleeplab/ssh"
KEY_WORKER="$SSH_DIR/sleeplab-video-worker"
SSH_CONFIG="$SSH_DIR/config"

CONFIG_DIR="/etc/sleeplab-video-worker"
TLS_DIR="$CONFIG_DIR/tls"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

WORKER_USER="${WORKER_USER:-ki}"

REQUEST_FILE="/tmp/sleeplab-worker-token-request.txt"

# ── Header ──────────────────────────────────────────────────────
clear || true
cat <<'BANNER'
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║   Sleeplab — Video-Worker Installer (Mac mini)             ║
║   Konvertierung + LLM-Inferenz                             ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
BANNER
echo ""

# ── Phase 0: Voraussetzungen ────────────────────────────────────
log_phase "Voraussetzungen pruefen"

if [[ "$(uname -s)" != "Darwin" ]]; then
    log_err "Dieses Skript ist fuer macOS. Linux/Debian-Setup: install.sh oder docker-Image"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    log_err "Bitte mit sudo ausfuehren: sudo ./install-mac-worker.sh"
    exit 1
fi

# Homebrew + Tools
if ! command -v brew &>/dev/null; then
    log_err "Homebrew nicht gefunden. Installiere zuerst Homebrew:"
    log_err "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
fi

# Brew-Owner ermitteln — brew laeuft NICHT als root, sondern als der User
# der Homebrew installiert hat. Typisch der Klinik-Admin-Login-User.
BREW_PREFIX=$(/usr/bin/env brew --prefix 2>/dev/null || echo "")
if [[ -z "$BREW_PREFIX" ]]; then
    # Fallback fuer den Fall dass brew nicht im PATH ist (z.B. wenn als sudo
    # ohne -i gestartet)
    if [[ -x "/opt/homebrew/bin/brew" ]]; then
        BREW_PREFIX="/opt/homebrew"
    elif [[ -x "/usr/local/bin/brew" ]]; then
        BREW_PREFIX="/usr/local"
    else
        log_err "Homebrew nicht gefunden. Installiere Homebrew zuerst:"
        log_err "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi
fi

BREW_BIN="$BREW_PREFIX/bin/brew"
BREW_OWNER=$(stat -f '%Su' "$BREW_PREFIX" 2>/dev/null || echo "")
if [[ -z "$BREW_OWNER" || "$BREW_OWNER" == "root" ]]; then
    log_err "Homebrew-Verzeichnis $BREW_PREFIX gehoert root oder ist nicht da."
    log_err "Brew muss als Login-User (nicht root) installiert sein."
    exit 1
fi
log_ok "Homebrew: $BREW_BIN (Owner: $BREW_OWNER)"

# Helper: brew als richtigen User aufrufen
run_brew() {
    sudo -u "$BREW_OWNER" -H "$BREW_BIN" "$@"
}

# Python 3.11+ erzwingen — System-Python (3.9) reicht nicht. Erst nach
# vorhandenen Brew-Pythons suchen, sonst python@3.12 installieren.
PYTHON_BIN=""
for cand in python3.13 python3.12 python3.11; do
    if path=$(command -v "$cand" 2>/dev/null); then
        PYTHON_BIN="$path"
        break
    fi
    # Auch direkt im Brew-Prefix suchen — wenn brew nicht im PATH des
    # sudo-Aufrufs liegt
    if [[ -x "$BREW_PREFIX/bin/$cand" ]]; then
        PYTHON_BIN="$BREW_PREFIX/bin/$cand"
        break
    fi
done

if [[ -z "$PYTHON_BIN" ]] && command -v python3 &>/dev/null; then
    if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
        PYTHON_BIN=$(command -v python3)
    fi
fi

if [[ -z "$PYTHON_BIN" ]]; then
    log_warn "Kein Python 3.11+ gefunden — installiere python@3.12 via Homebrew (kann ein paar Minuten dauern)"
    run_brew install python@3.12 || {
        log_err "Homebrew-Install python@3.12 fehlgeschlagen — bitte manuell: brew install python@3.12"
        exit 1
    }
    PYTHON_BIN="$BREW_PREFIX/opt/python@3.12/bin/python3.12"
    [[ ! -x "$PYTHON_BIN" ]] && PYTHON_BIN="$BREW_PREFIX/bin/python3.12"
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
    log_err "Python 3.11+ konnte nicht eingerichtet werden"
    exit 1
fi
PY_VER=$("$PYTHON_BIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])')
log_ok "Python: $PYTHON_BIN (Version $PY_VER)"

# ffmpeg
if ! command -v ffmpeg &>/dev/null && [[ ! -x "$BREW_PREFIX/bin/ffmpeg" ]]; then
    log_warn "Installiere ffmpeg via Homebrew"
    run_brew install ffmpeg || {
        log_err "Homebrew-Install ffmpeg fehlgeschlagen — bitte manuell: brew install ffmpeg"
        exit 1
    }
fi
FFMPEG_BIN=$(command -v ffmpeg || echo "$BREW_PREFIX/bin/ffmpeg")
log_ok "ffmpeg: $FFMPEG_BIN"

# Restliche System-Tools (git, ssh, openssl) sind im macOS Default
for cmd in git ssh ssh-keygen openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        log_err "$cmd nicht gefunden — sollte mit Xcode-CLI-Tools mitkommen"
        log_err "Installiere mit: xcode-select --install"
        exit 1
    fi
done
log_ok "System-Tools (git, ssh, openssl) verfuegbar"

# Worker-User pruefen
if ! id "$WORKER_USER" &>/dev/null; then
    log_err "User '$WORKER_USER' existiert nicht. WORKER_USER=<existing> setzen oder User anlegen."
    exit 1
fi
log_ok "Worker-User: $WORKER_USER"

# Verzeichnisse vorbereiten
mkdir -p "$SSH_DIR" "$CONFIG_DIR" "$TLS_DIR" "$INSTALL_DIR"
chmod 700 "$SSH_DIR" "$TLS_DIR"
chmod 755 "$CONFIG_DIR"
chown -R root:wheel "$SSH_DIR" "$CONFIG_DIR"

# ── Phase 1: Deploy-Key ─────────────────────────────────────────
log_phase "SSH-Deploy-Key fuer sleeplab-video-worker"

KEY_VALID=false
if [[ -f "$KEY_WORKER" && -f "$SSH_CONFIG" ]]; then
    log_info "Key vorhanden — teste GitHub-Verbindung..."
    set +e
    SSH_OUT=$(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -T git@github.com-sleeplab-video-worker 2>&1)
    set -e
    if echo "$SSH_OUT" | grep -q "successfully authenticated"; then
        log_ok "Deploy-Key ist in GitHub freigeschaltet"
        KEY_VALID=true
    else
        log_warn "Key vorhanden, aber GitHub akzeptiert ihn noch nicht."
        log_warn "  $(echo "$SSH_OUT" | head -1)"
    fi
fi

if ! $KEY_VALID; then
    if [[ ! -f "$KEY_WORKER" ]]; then
        cat <<EXPLAIN

Der Mac mini bekommt einen eigenen SSH-Deploy-Key fuer das private
sleeplab-video-worker-Repo. Der Public Key wird in eine vorgefertigte
E-Mail an Marco gepackt — er traegt den Key in GitHub ein, dann darf
dieser Mac mini das Repo klonen + automatisch updaten.

EXPLAIN
        read -p "Klinik/Praxis-Name             > " CLINIC_NAME
        read -p "Mac-Mini-Hostname              > " SERVER_HOSTNAME
        read -p "Dein Name (Ansprechpartner)    > " CONTACT_NAME
        read -p "Deine Email (fuer Antwort)     > " CONTACT_EMAIL
        read -p "Notiz (optional, Enter zum Ueberspringen) > " NOTES

        [[ -z "$CLINIC_NAME"     ]] && { log_err "Klinik-Name fehlt";     exit 1; }
        [[ -z "$SERVER_HOSTNAME" ]] && { log_err "Mac-Hostname fehlt";    exit 1; }
        [[ -z "$CONTACT_NAME"    ]] && { log_err "Name fehlt";            exit 1; }
        [[ -z "$CONTACT_EMAIL"   ]] && { log_err "Email fehlt";           exit 1; }
        if ! [[ "$CONTACT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_err "Email-Format ungueltig"; exit 1
        fi

        CLINIC_SLUG=$(echo "$CLINIC_NAME" | tr '[:upper:]' '[:lower:]' \
            | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
        DATE_TAG=$(date '+%Y%m%d')

        log_info "Generiere SSH-Deploy-Key (ed25519)..."
        ssh-keygen -t ed25519 -N "" -C "sleeplab-video-worker-${CLINIC_SLUG}-${DATE_TAG}" \
            -f "$KEY_WORKER" >/dev/null
        chmod 600 "$KEY_WORKER"
        chmod 644 "${KEY_WORKER}.pub"

        # SSH-Config schreiben (oder ergaenzen falls schon vorhanden)
        if [[ ! -f "$SSH_CONFIG" ]]; then
            touch "$SSH_CONFIG"
            chmod 600 "$SSH_CONFIG"
        fi
        if ! grep -q "Host github.com-sleeplab-video-worker" "$SSH_CONFIG"; then
            cat >> "$SSH_CONFIG" <<EOF

# sleeplab-video-worker Deploy-Key (Mac-Worker)
# SSH ueber Port 443 fuer Klinik-Firewalls
Host github.com-sleeplab-video-worker
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile $KEY_WORKER
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
            log_ok "SSH-Config-Eintrag hinzugefuegt"
        fi

        log_ok "Key erstellt: $KEY_WORKER"
    else
        # Key existiert, vielleicht noch nicht freigeschaltet — Email-Text reproduzieren
        CLINIC_SLUG=$(ssh-keygen -l -f "${KEY_WORKER}.pub" | awk '{print $3}' \
            | sed 's/sleeplab-video-worker-//' | sed 's/-[0-9]\{8\}$//')
        log_warn "Key liegt bereits vor (Klinik: $CLINIC_SLUG)"
        CLINIC_NAME="${CLINIC_NAME:-(siehe Key-Kommentar: $CLINIC_SLUG)}"
        SERVER_HOSTNAME="${SERVER_HOSTNAME:-$(hostname || echo 'mac-mini')}"
        CONTACT_NAME="${CONTACT_NAME:-Admin}"
        CONTACT_EMAIL="${CONTACT_EMAIL:-?}"
        NOTES="${NOTES:-}"
    fi

    # ── Email-Text generieren ───────────────────────────────────
    SYS_HOSTNAME="$(hostname || echo 'mac-mini')"
    SYS_OS="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
    SYS_ARCH="$(uname -m)"
    NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    PUBKEY_WORKER=$(cat "${KEY_WORKER}.pub")
    SUBJECT="[Sleeplab Worker] Deploy-Key-Anfrage von ${CLINIC_NAME}"

    cat > "$REQUEST_FILE" <<EOF
An:       ${SUPPORT_EMAIL}
Betreff:  ${SUBJECT}

Hallo Marco,

der Mac mini fuer Sleeplab steht — ich brauche Deploy-Key-Freischaltung
fuer das Worker-Repo. Anbei der Public Key zum Einfuegen.

────────────────────────────────────────────────────────────
KLINIK-DATEN (Mac-Worker-Maschine)
────────────────────────────────────────────────────────────
Klinik / Praxis:    ${CLINIC_NAME}
Mac-Hostname:       ${SERVER_HOSTNAME}
Ansprechpartner:    ${CONTACT_NAME}
Antwort-Email:      ${CONTACT_EMAIL}

System-Info:
  macOS:            ${SYS_OS}
  Architektur:      ${SYS_ARCH}
  System-Hostname:  ${SYS_HOSTNAME}
  Datum:            ${NOW}

Notiz:
${NOTES:-(keine)}

────────────────────────────────────────────────────────────
DEPLOY KEY — fuer DarkRudolf/sleeplab-video-worker
────────────────────────────────────────────────────────────
GitHub-URL:
  https://github.com/${WORKER_REPO}/settings/keys/new

Title:               sleeplab-video-worker-${CLINIC_SLUG}
Allow write access:  NEIN (uncheck)
Key (eine Zeile):

${PUBKEY_WORKER}

────────────────────────────────────────────────────────────

Eine kurze Bestaetigung an ${CONTACT_EMAIL} reicht — das install-mac-worker.sh
laeuft hier offen und prueft dann selbst die Verbindung.

Danke!
${CONTACT_NAME}
EOF
    chmod 600 "$REQUEST_FILE"

    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  EMAIL VERSENDEN${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}An:${NC}       ${CYAN}${SUPPORT_EMAIL}${NC}"
    echo -e "  ${BOLD}Betreff:${NC}  ${CYAN}${SUBJECT}${NC}"
    echo ""
    echo -e "${DIM}  ───── Body (komplett kopieren) ────────────────────────────${NC}"
    sed -n '/^Hallo Marco/,$p' "$REQUEST_FILE"
    echo -e "${DIM}  ─────────────────────────────────────────────────────────${NC}"
    echo ""
    cat <<HINTS
Naechste Schritte:

  1. Email mit obigem Text an ${SUPPORT_EMAIL} schicken.
  2. Marco fuegt den Key in GitHub ein.
  3. Sobald die Bestaetigung kommt: hier Enter druecken — das Skript
     prueft selbststaendig die Verbindung.

Tipp: Der Email-Text liegt auch hier zum Wieder-Anschauen:
  ${REQUEST_FILE}

HINTS
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    while true; do
        read -p "Marco hat freigeschaltet — Verbindung testen? [Enter / q zum Abbrechen] " ANSWER
        if [[ "$ANSWER" == "q" ]]; then
            log_warn "Abgebrochen. Spaeter erneut: sudo ./install-mac-worker.sh"
            exit 0
        fi
        log_info "Teste GitHub-Verbindung..."
        set +e
        SSH_OUT=$(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 \
            -T git@github.com-sleeplab-video-worker 2>&1)
        set -e
        if echo "$SSH_OUT" | grep -q "successfully authenticated"; then
            log_ok "Deploy-Key freigeschaltet"
            break
        fi
        log_err "Noch nicht aktiv: $(echo "$SSH_OUT" | head -1)"
        echo ""
    done

    rm -f "$REQUEST_FILE"
fi

# ── Phase 2: Repo klonen + persistenter SSH-Config-Include ──────
log_phase "Worker-Repo klonen"

export GIT_SSH_COMMAND="ssh -F $SSH_CONFIG"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    log_info "Repo existiert — git pull"
    (cd "$INSTALL_DIR" && git pull --ff-only) || log_warn "Pull fehlgeschlagen"
else
    log_info "Klone $WORKER_REPO..."
    git clone "git@github.com-sleeplab-video-worker:$WORKER_REPO.git" "$INSTALL_DIR"
fi
chown -R "$WORKER_USER":staff "$INSTALL_DIR"
log_ok "Worker-Code in $INSTALL_DIR"

# SSH-Config-Include in ~$WORKER_USER/.ssh/config einrichten — sonst kennen
# spaetere 'git pull' (z.B. /admin/update vom psg-viewer aus) den Host-Alias
# 'github.com-sleeplab-video-worker' nicht und failen mit
# "Could not resolve hostname". GIT_SSH_COMMAND-Env greift nur waehrend dieses
# Skript-Laufs.
USER_HOME=$(dscl . -read "/Users/$WORKER_USER" NFSHomeDirectory 2>/dev/null \
    | awk '{print $2}')
USER_HOME="${USER_HOME:-/Users/$WORKER_USER}"
USER_SSH_DIR="$USER_HOME/.ssh"
USER_SSH_CFG="$USER_SSH_DIR/config"
INCLUDE_LINE="Include $SSH_CONFIG"

mkdir -p "$USER_SSH_DIR"
chmod 700 "$USER_SSH_DIR"
chown "$WORKER_USER":staff "$USER_SSH_DIR"

if [[ ! -f "$USER_SSH_CFG" ]] || ! grep -qF "$INCLUDE_LINE" "$USER_SSH_CFG"; then
    if [[ -f "$USER_SSH_CFG" ]]; then
        # Include muss am Anfang stehen, sonst greift's nicht fuer alle Hosts
        { echo "$INCLUDE_LINE"; cat "$USER_SSH_CFG"; } > "${USER_SSH_CFG}.tmp"
        mv "${USER_SSH_CFG}.tmp" "$USER_SSH_CFG"
    else
        echo "$INCLUDE_LINE" > "$USER_SSH_CFG"
    fi
    chmod 600 "$USER_SSH_CFG"
    chown "$WORKER_USER":staff "$USER_SSH_CFG"
    log_ok "SSH-Config-Include in $USER_SSH_CFG"
fi

# ── Phase 3: Python-venv + Dependencies ────────────────────────
log_phase "Python-venv anlegen"

# Pruefen ob ein vorhandenes venv die richtige Python-Version hat. Das
# Skript wird haeufiger einmal mit System-Python 3.9 angefangen worden
# sein und dann hier abgebrochen — danach liegt ein kaputtes venv rum.
EXISTING_PY="$INSTALL_DIR/.venv/bin/python"
if [[ -x "$EXISTING_PY" ]]; then
    if "$EXISTING_PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
        log_info "Bestehendes venv ist kompatibel — behalte"
    else
        log_warn "Bestehendes venv hat zu altes Python — wird neu erstellt"
        rm -rf "$INSTALL_DIR/.venv"
    fi
fi

# Venv mit dem ermittelten PYTHON_BIN erzeugen falls nicht da
if [[ ! -x "$INSTALL_DIR/.venv/bin/python" ]]; then
    sudo -u "$WORKER_USER" "$PYTHON_BIN" -m venv "$INSTALL_DIR/.venv" \
        || { log_err "venv-Erzeugung fehlgeschlagen"; exit 1; }
    log_ok "venv erstellt mit Python $PY_VER"
fi

# Pip + Wheel + Worker-Paket installieren
sudo -u "$WORKER_USER" "$INSTALL_DIR/.venv/bin/pip" install --upgrade pip wheel >/dev/null \
    || { log_err "pip-Upgrade fehlgeschlagen"; exit 1; }
sudo -u "$WORKER_USER" bash -lc "cd $INSTALL_DIR && .venv/bin/pip install -e ." \
    || { log_err "Worker-Install fehlgeschlagen"; exit 1; }
log_ok "Worker-Code installiert (.venv)"

# ── Phase 4: TLS-Self-Signed-Cert ──────────────────────────────
log_phase "TLS-Zertifikat erzeugen"

if [[ -f "$TLS_DIR/server.crt" && -f "$TLS_DIR/server.key" ]]; then
    log_warn "TLS-Cert existiert bereits — neu erzeugen? [y/N]"
    read -t 30 ANSWER || ANSWER="N"
    if [[ "$ANSWER" =~ ^[Yy] ]]; then
        rm -f "$TLS_DIR/server.crt" "$TLS_DIR/server.key"
    fi
fi

if [[ ! -f "$TLS_DIR/server.crt" ]]; then
    # IP fuer SAN ermitteln (erste private IPv4)
    LOCAL_IP=$(ifconfig | awk '/inet / && !/127.0/ && !/inet6/ { print $2; exit }')
    LOCAL_IP="${LOCAL_IP:-192.168.0.1}"
    LOCAL_HOSTNAME=$(hostname -s 2>/dev/null || hostname || echo 'mac-mini')

    log_info "Cert fuer IP=$LOCAL_IP, Hostname=$LOCAL_HOSTNAME (10 Jahre Laufzeit)"

    cat > "$TLS_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = req_dn
req_extensions     = v3_req
prompt             = no

[req_dn]
CN = sleeplab-video-worker

[v3_req]
subjectAltName = @alt
extendedKeyUsage = serverAuth

[alt]
DNS.1 = ${LOCAL_HOSTNAME}
DNS.2 = ${LOCAL_HOSTNAME}.local
DNS.3 = localhost
IP.1  = ${LOCAL_IP}
IP.2  = 127.0.0.1
EOF

    openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
        -keyout "$TLS_DIR/server.key" \
        -out    "$TLS_DIR/server.crt" \
        -config "$TLS_DIR/openssl.cnf" \
        -extensions v3_req >/dev/null 2>&1

    chmod 600 "$TLS_DIR/server.key"
    chmod 644 "$TLS_DIR/server.crt"
    chown root:wheel "$TLS_DIR/server.key" "$TLS_DIR/server.crt"

    FINGERPRINT=$(openssl x509 -in "$TLS_DIR/server.crt" -noout -fingerprint -sha256 \
        | sed 's/^.*=//' | tr -d ':')
    log_ok "TLS-Cert erstellt: $TLS_DIR/server.crt"
    echo "$FINGERPRINT" > "$TLS_DIR/fingerprint.sha256"
fi

FINGERPRINT=$(cat "$TLS_DIR/fingerprint.sha256")

# ── Phase 5: Shared Secret + Config-Datei ──────────────────────
log_phase "Worker-Konfiguration"

if [[ ! -f "$CONFIG_FILE" ]]; then
    SHARED_SECRET=$(openssl rand -hex 32)

    # Default-NAS-Pfade fuer Mac mini
    cat > "$CONFIG_FILE" <<EOF
# Sleeplab Video-Worker — Klinik-Konfiguration
# Generiert von install-mac-worker.sh am ${NOW:-$(date)}
#
# Diese Datei wird vom psg-viewer-Admin-Panel ueberschrieben (Pfade, Encoder).
# shared_secret bleibt — der wird einmalig hier gesetzt.

server:
  host: "0.0.0.0"
  port: 8443
  shared_secret: "${SHARED_SECRET}"
  tls:
    enabled: true
    cert_file: "${TLS_DIR}/server.crt"
    key_file: "${TLS_DIR}/server.key"

storage:
  asf_source: "/Users/${WORKER_USER}/nas/MSV_Data"
  mp4_cache:  "/Users/${WORKER_USER}/nas/Import/_video_cache"
  work_dir:   "/var/sleeplab-worker/tmp"

encoder:
  backend: "auto"

jobs:
  max_parallel: 1
  nice: 10

cache:
  retention_days: 30

logging:
  level: "INFO"
  file: "/var/log/sleeplab-video-worker.log"
EOF
    chmod 600 "$CONFIG_FILE"
    chown root:wheel "$CONFIG_FILE"
    log_ok "Konfig erstellt: $CONFIG_FILE"
else
    log_info "Konfig existiert: $CONFIG_FILE (bleibt unveraendert)"
    SHARED_SECRET=$(awk '/shared_secret:/ { gsub(/["'\'']/, "", $2); print $2; exit }' "$CONFIG_FILE")
fi

# work_dir vorbereiten
mkdir -p /var/sleeplab-worker/tmp
chown -R "$WORKER_USER":staff /var/sleeplab-worker

# ── Phase 6: LaunchDaemon ──────────────────────────────────────
log_phase "LaunchDaemon installieren"

PLIST="/Library/LaunchDaemons/de.sleeplab.video-worker.plist"
if [[ -f "$PLIST" ]]; then
    log_info "LaunchDaemon existiert — entlade alten Stand"
    launchctl unload "$PLIST" 2>/dev/null || true
fi

# Plist aus dem Repo nehmen, ggf. Pfade anpassen
cp "$INSTALL_DIR/launchd/de.sleeplab.video-worker.plist" "$PLIST"

# UserName + Install-Pfad in der plist setzen falls die Defaults nicht passen.
# PATH muss den Brew-Prefix enthalten damit ffmpeg auf Apple Silicon
# (/opt/homebrew/bin) wie auch Intel (/usr/local/bin) gefunden wird.
PLIST_PATH="${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"

sed -i.bak \
    -e "s|/opt/sleeplab-video-worker|$INSTALL_DIR|g" \
    -e "s|<string>ki</string>|<string>$WORKER_USER</string>|g" \
    -e "s|/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin|$PLIST_PATH|g" \
    "$PLIST"
rm -f "$PLIST.bak"

# WORKER_CONFIG-Env in der plist auf die echte Klinik-Config zeigen
# (das Repo-Default zeigt auf /etc/sleeplab-video-worker/config.yaml — passt)

chown root:wheel "$PLIST"
chmod 644       "$PLIST"

# Log-Verzeichnisse
touch /var/log/sleeplab-video-worker.{out,err,log}.log 2>/dev/null || true
chown "$WORKER_USER":staff /var/log/sleeplab-video-worker.*.log 2>/dev/null || true

launchctl load "$PLIST"
log_ok "LaunchDaemon geladen"

# Sudoers-Eintrag damit der Worker-User passwortlos den Service per
# 'launchctl kickstart' restarten darf. Wird vom /admin/update-Endpoint
# gebraucht wenn der psg-viewer-Admin den Worker aktualisieren will.
SUDOERS_FILE="/etc/sudoers.d/sleeplab-video-worker"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    cat > "$SUDOERS_FILE" <<EOF
# Sleeplab Video-Worker — Self-Update
# Erlaubt dem Worker-User passwortlosen Restart des LaunchDaemons.
# Wird vom POST /admin/update-Endpoint genutzt.
$WORKER_USER ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/de.sleeplab.video-worker
EOF
    chmod 440 "$SUDOERS_FILE"
    chown root:wheel "$SUDOERS_FILE"
    if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
        log_ok "sudoers-Eintrag fuer Self-Update angelegt: $SUDOERS_FILE"
    else
        log_warn "sudoers-Eintrag invalid — entferne wieder"
        rm -f "$SUDOERS_FILE"
    fi
fi

# ── Phase 7: Health-Check ──────────────────────────────────────
log_phase "Smoke-Test"

sleep 2
HEALTH_URL="https://127.0.0.1:8443/healthz"
if curl -sk --max-time 5 "$HEALTH_URL" >/dev/null; then
    log_ok "Worker antwortet auf $HEALTH_URL"
    HEALTH=$(curl -sk "$HEALTH_URL")
    ENCODER=$(echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('encoder',{}).get('description','?'))" 2>/dev/null || echo "?")
    log_info "Encoder: $ENCODER"
else
    log_warn "Worker antwortet noch nicht — Logs pruefen:"
    log_warn "  tail -f /var/log/sleeplab-video-worker.err.log"
fi

# ── Phase 8: Zusammenfassung ───────────────────────────────────
log_phase "Fertig"

LOCAL_IP=$(ifconfig | awk '/inet / && !/127.0/ && !/inet6/ { print $2; exit }')
LOCAL_IP="${LOCAL_IP:-?.?.?.?}"

cat <<DONE

${GREEN}${BOLD}Video-Worker laeuft.${NC}

  URL:          https://${LOCAL_IP}:8443
  TLS-Pinning:  ${FINGERPRINT}
  Shared:       ${SHARED_SECRET}

  Im psg-viewer Admin-Panel (Box 1, Debian-VM) eintragen:
    Worker-URL:        https://${LOCAL_IP}:8443
    Shared-Secret:     ${SHARED_SECRET}
    TLS-Fingerprint:   ${FINGERPRINT}

  Logs:
    tail -f /var/log/sleeplab-video-worker.{out,err}.log

  Service kontrollieren:
    sudo launchctl unload  /Library/LaunchDaemons/de.sleeplab.video-worker.plist
    sudo launchctl load    /Library/LaunchDaemons/de.sleeplab.video-worker.plist

DONE
