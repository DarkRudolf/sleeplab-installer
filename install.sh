#!/usr/bin/env bash
###############################################################################
# Sleeplab Klinik-Installer (Bootstrap)
#
# Public Bootstrap-Skript:
#   1. Erzeugt zwei SSH-Deploy-Keys (ed25519, einen pro privatem Repo)
#   2. Konfiguriert ~/.ssh/config so dass git ueber Port 443 (statt 22) geht
#      — laeuft damit auch hinter Klinik-Firewalls die SSH-22 blocken.
#   3. Generiert eine vorgefertigte E-Mail mit beiden Public Keys.
#      Klinik-Admin schickt sie an psg-viewer@marco-stankowitz.de.
#   4. Marco fuegt die Keys als Deploy Keys in GitHub ein
#      (Settings → Deploy Keys → Add new, Allow write access: NEIN).
#   5. Klinik-Admin drueckt Enter → SSH-Verbindungstest → Repos klonen.
#
# Verwendung auf einem frischen Klinik-Server:
#   curl -fsSL https://raw.githubusercontent.com/DarkRudolf/sleeplab-installer/main/install.sh -o install.sh
#   chmod +x install.sh
#   sudo ./install.sh
###############################################################################
set -euo pipefail

# ── Farben ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[FEHLER]${NC} $*"; }
log_phase() { echo -e "\n${BOLD}═══ $1 ═══${NC}"; }

# ── Konfiguration ────────────────────────────────────────────────
SUPPORT_EMAIL="${SUPPORT_EMAIL:-psg-viewer@marco-stankowitz.de}"
INSTALL_DIR="${INSTALL_DIR:-/opt/sleeplab}"
PIPELINE_REPO="DarkRudolf/sleep-staging-pipeline"
VIEWER_REPO="DarkRudolf/psg-viewer"

# Keys liegen zentral unter /etc/sleeplab/ssh/
SSH_DIR="/etc/sleeplab/ssh"
KEY_PIPELINE="$SSH_DIR/sleeplab-pipeline"
KEY_VIEWER="$SSH_DIR/sleeplab-psgviewer"
SSH_CONFIG="$SSH_DIR/config"

REQUEST_FILE="/tmp/sleeplab-token-request.txt"

# ── Header ──────────────────────────────────────────────────────
clear || true
cat <<'BANNER'
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║   Sleeplab — Klinik-Installer                              ║
║   PSG-Auswertung mit KI                                    ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
BANNER
echo ""

# ── Phase 0: Voraussetzungen ────────────────────────────────────
log_phase "Voraussetzungen pruefen"

if [[ $EUID -ne 0 ]]; then
    log_err "Dieser Installer muss als root oder mit sudo ausgefuehrt werden"
    exit 1
fi

for cmd in curl git ssh ssh-keygen; do
    if ! command -v "$cmd" &>/dev/null; then
        log_warn "$cmd nicht gefunden — installiere openssh-client + git ..."
        apt-get update -qq && apt-get install -y -qq openssh-client git curl || {
            log_err "Installation fehlgeschlagen. Bitte manuell: apt install openssh-client git curl"
            exit 1
        }
        break
    fi
done
log_ok "curl, git, ssh, ssh-keygen verfuegbar"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown root:root "$SSH_DIR"

# ── Phase 1: Deploy-Keys vorhanden? ────────────────────────────
log_phase "SSH-Deploy-Keys"

# Wir versuchen sofort einen Verbindungstest. Wenn der gruen ist,
# sind die Keys schon freigeschaltet → ueberspringen.
KEYS_VALID=false
if [[ -f "$KEY_PIPELINE" && -f "$KEY_VIEWER" && -f "$SSH_CONFIG" ]]; then
    log_info "Keys vorhanden — teste GitHub-Verbindung..."
    set +e
    SSH_OUT_P=$(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -T git@github.com-sleeplab-pipeline 2>&1)
    SSH_OUT_V=$(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -T git@github.com-sleeplab-psgviewer 2>&1)
    set -e
    if echo "$SSH_OUT_P" | grep -q "successfully authenticated" && \
       echo "$SSH_OUT_V" | grep -q "successfully authenticated"; then
        log_ok "Beide Deploy-Keys sind in GitHub freigeschaltet"
        KEYS_VALID=true
    else
        log_warn "Keys vorhanden, aber GitHub akzeptiert sie noch nicht."
        log_warn "  Pipeline: $(echo "$SSH_OUT_P" | head -1)"
        log_warn "  Viewer:   $(echo "$SSH_OUT_V" | head -1)"
    fi
fi

if ! $KEYS_VALID; then
    if [[ ! -f "$KEY_PIPELINE" || ! -f "$KEY_VIEWER" ]]; then
        cat <<EXPLAIN

Es werden zwei SSH-Deploy-Keys generiert (einer pro privatem Repo).
Die ${BOLD}Public Keys${NC} kommen in eine vorgefertigte E-Mail an Marco.
Die ${BOLD}Private Keys${NC} verlassen niemals diesen Server (chmod 600).

EXPLAIN
        read -p "Klinik/Praxis-Name             > " CLINIC_NAME
        read -p "Server-Hostname (z.B. sleeplab.klinik.de) > " SERVER_HOSTNAME
        read -p "Dein Name (Ansprechpartner)    > " CONTACT_NAME
        read -p "Deine Email (fuer Antwort)     > " CONTACT_EMAIL
        read -p "Notiz (optional, Enter zum Ueberspringen) > " NOTES

        [[ -z "$CLINIC_NAME"     ]] && { log_err "Klinik-Name fehlt";     exit 1; }
        [[ -z "$SERVER_HOSTNAME" ]] && { log_err "Server-Hostname fehlt"; exit 1; }
        [[ -z "$CONTACT_NAME"    ]] && { log_err "Name fehlt";            exit 1; }
        [[ -z "$CONTACT_EMAIL"   ]] && { log_err "Email fehlt";           exit 1; }
        if ! [[ "$CONTACT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log_err "Email-Format ungueltig"; exit 1
        fi

        # Klinik-Slug fuer Title in GitHub (lowercase, ohne Sonderzeichen)
        CLINIC_SLUG=$(echo "$CLINIC_NAME" | tr '[:upper:]' '[:lower:]' \
            | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
        DATE_TAG=$(date '+%Y%m%d')

        log_info "Generiere SSH-Deploy-Keys (ed25519)..."
        ssh-keygen -t ed25519 -N "" -C "sleeplab-pipeline-${CLINIC_SLUG}-${DATE_TAG}" \
            -f "$KEY_PIPELINE" >/dev/null
        ssh-keygen -t ed25519 -N "" -C "sleeplab-psgviewer-${CLINIC_SLUG}-${DATE_TAG}" \
            -f "$KEY_VIEWER" >/dev/null
        chmod 600 "$KEY_PIPELINE" "$KEY_VIEWER"
        chmod 644 "${KEY_PIPELINE}.pub" "${KEY_VIEWER}.pub"
        chown -R root:root "$SSH_DIR"
        log_ok "Keys erstellt: $KEY_PIPELINE, $KEY_VIEWER"

        # SSH-Config schreiben — nutzt ssh.github.com auf Port 443,
        # damit das auch hinter Firewalls funktioniert die Port 22 blockieren.
        cat > "$SSH_CONFIG" <<EOF
# Sleeplab Deploy-Key Aliases
# SSH ueber Port 443 (HTTPS-Port) gegen ssh.github.com — funktioniert
# auch hinter Klinik-Firewalls die Port 22 outbound blockieren.

Host github.com-sleeplab-pipeline
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile $KEY_PIPELINE
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host github.com-sleeplab-psgviewer
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile $KEY_VIEWER
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
        chmod 600 "$SSH_CONFIG"
        log_ok "SSH-Config geschrieben: $SSH_CONFIG"
    else
        # Keys existieren — Klinik-Daten aus Key-Kommentar zurueckholen
        # damit der Email-Text wieder ausgegeben werden kann
        CLINIC_SLUG=$(ssh-keygen -l -f "${KEY_PIPELINE}.pub" | awk '{print $3}' \
            | sed 's/sleeplab-pipeline-//' | sed 's/-[0-9]\{8\}$//')
        log_warn "Keys liegen bereits vor (Klinik: $CLINIC_SLUG)"
        log_warn "Falls noch nicht freigeschaltet — Email-Text wird erneut angezeigt."
        # Wenn Klinik-Daten interaktiv erfragen — sonst nimm Defaults
        CLINIC_NAME="${CLINIC_NAME:-(siehe Key-Kommentar: $CLINIC_SLUG)}"
        SERVER_HOSTNAME="${SERVER_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
        CONTACT_NAME="${CONTACT_NAME:-Admin}"
        CONTACT_EMAIL="${CONTACT_EMAIL:-?}"
        NOTES="${NOTES:-}"
    fi

    # ── Email-Text generieren ───────────────────────────────────
    SYS_HOSTNAME="$(hostname -f 2>/dev/null || hostname || echo 'unbekannt')"
    SYS_OS="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
    SYS_ARCH="$(uname -m)"
    NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    PUBKEY_PIPELINE=$(cat "${KEY_PIPELINE}.pub")
    PUBKEY_VIEWER=$(cat "${KEY_VIEWER}.pub")

    SUBJECT="[Sleeplab] Deploy-Key-Anfrage von ${CLINIC_NAME}"

    cat > "$REQUEST_FILE" <<EOF
An:       ${SUPPORT_EMAIL}
Betreff:  ${SUBJECT}

Hallo Marco,

ich moechte Sleeplab installieren und brauche Deploy-Key-Freischaltung
fuer die beiden privaten Repos. Anbei beide Public Keys zum Einfuegen.

────────────────────────────────────────────────────────────
KLINIK-DATEN
────────────────────────────────────────────────────────────
Klinik / Praxis:    ${CLINIC_NAME}
Server-Hostname:    ${SERVER_HOSTNAME}
Ansprechpartner:    ${CONTACT_NAME}
Antwort-Email:      ${CONTACT_EMAIL}

System-Info:
  OS:               ${SYS_OS}
  Architektur:      ${SYS_ARCH}
  System-Hostname:  ${SYS_HOSTNAME}
  Datum:            ${NOW}

Notiz:
${NOTES:-(keine)}

────────────────────────────────────────────────────────────
DEPLOY KEY 1 — fuer DarkRudolf/sleep-staging-pipeline
────────────────────────────────────────────────────────────
GitHub-URL:
  https://github.com/${PIPELINE_REPO}/settings/keys/new

Title:               sleeplab-pipeline-${CLINIC_SLUG}
Allow write access:  NEIN (uncheck)
Key (eine Zeile):

${PUBKEY_PIPELINE}

────────────────────────────────────────────────────────────
DEPLOY KEY 2 — fuer DarkRudolf/psg-viewer
────────────────────────────────────────────────────────────
GitHub-URL:
  https://github.com/${VIEWER_REPO}/settings/keys/new

Title:               sleeplab-psgviewer-${CLINIC_SLUG}
Allow write access:  NEIN (uncheck)
Key (eine Zeile):

${PUBKEY_VIEWER}

────────────────────────────────────────────────────────────

Eine kurze Bestaetigung an ${CONTACT_EMAIL} reicht — das install.sh
laeuft hier offen und prueft dann selbst die Verbindung.

Danke!
${CONTACT_NAME}
EOF
    chmod 600 "$REQUEST_FILE"

    # ── Praesentation ───────────────────────────────────────────
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
  2. Marco fuegt beide Keys in GitHub ein (eine Mausklick-Aktion pro Key).
  3. Sobald die Bestaetigung kommt: hier Enter druecken — das Skript
     prueft selbststaendig die Verbindung.

Tipp: Der Email-Text liegt auch hier zum Wieder-Anschauen:
  ${REQUEST_FILE}

HINTS
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    # Loop: warten bis Verbindung steht
    while true; do
        read -p "Marco hat freigeschaltet — Verbindung testen? [Enter / q zum Abbrechen] " ANSWER
        if [[ "$ANSWER" == "q" ]]; then
            log_warn "Abgebrochen. Spaeter erneut: sudo ./install.sh"
            log_warn "Keys bleiben auf dem Server unter $SSH_DIR/"
            exit 0
        fi

        log_info "Teste GitHub-Verbindung (SSH ueber Port 443)..."
        set +e
        SSH_OUT_P=$(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 \
            -T git@github.com-sleeplab-pipeline 2>&1)
        SSH_OUT_V=$(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 \
            -T git@github.com-sleeplab-psgviewer 2>&1)
        set -e

        OK_P=false
        OK_V=false
        echo "$SSH_OUT_P" | grep -q "successfully authenticated" && OK_P=true
        echo "$SSH_OUT_V" | grep -q "successfully authenticated" && OK_V=true

        if $OK_P && $OK_V; then
            log_ok "Beide Deploy-Keys sind in GitHub freigeschaltet"
            break
        fi

        log_err "Noch nicht beide Keys aktiv:"
        $OK_P && echo -e "    ${GREEN}✓${NC} sleep-staging-pipeline" \
              || echo -e "    ${RED}✗${NC} sleep-staging-pipeline: $(echo "$SSH_OUT_P" | head -1)"
        $OK_V && echo -e "    ${GREEN}✓${NC} psg-viewer" \
              || echo -e "    ${RED}✗${NC} psg-viewer: $(echo "$SSH_OUT_V" | head -1)"
        echo ""
    done

    # Anfrage-Datei aufraeumen
    rm -f "$REQUEST_FILE"
fi

# ── Phase 2: Repos klonen ──────────────────────────────────────
log_phase "Repos klonen"

mkdir -p "$INSTALL_DIR"
export GIT_SSH_COMMAND="ssh -F $SSH_CONFIG"

# pipeline
if [[ -d "$INSTALL_DIR/pipeline/.git" ]]; then
    log_info "pipeline existiert — git pull"
    (cd "$INSTALL_DIR/pipeline" && git pull --ff-only) || log_warn "Pull fehlgeschlagen"
else
    log_info "Klone $PIPELINE_REPO..."
    git clone "git@github.com-sleeplab-pipeline:$PIPELINE_REPO.git" "$INSTALL_DIR/pipeline"
fi

# psg-viewer
if [[ -d "$INSTALL_DIR/psg-viewer/.git" ]]; then
    log_info "psg-viewer existiert — git pull"
    (cd "$INSTALL_DIR/psg-viewer" && git pull --ff-only) || log_warn "Pull fehlgeschlagen"
else
    log_info "Klone $VIEWER_REPO..."
    git clone "git@github.com-sleeplab-psgviewer:$VIEWER_REPO.git" "$INSTALL_DIR/psg-viewer"
fi

log_ok "Beide Repos verfuegbar in $INSTALL_DIR"

# ── Phase 3: Persistenter SSH-Config-Eintrag fuer kuenftige git pulls ──
# Damit "git pull" in den Repos auch ohne GIT_SSH_COMMAND funktioniert,
# wird die Sleeplab-SSH-Config in /root/.ssh/config inkludiert.
ROOT_SSH_CFG="/root/.ssh/config"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
INCLUDE_LINE="Include $SSH_CONFIG"
if [[ ! -f "$ROOT_SSH_CFG" ]] || ! grep -qF "$INCLUDE_LINE" "$ROOT_SSH_CFG"; then
    # Include-Direktive muss am Anfang stehen, sonst greift nicht fuer alle Hosts
    if [[ -f "$ROOT_SSH_CFG" ]]; then
        { echo "$INCLUDE_LINE"; cat "$ROOT_SSH_CFG"; } > "${ROOT_SSH_CFG}.tmp"
        mv "${ROOT_SSH_CFG}.tmp" "$ROOT_SSH_CFG"
    else
        echo "$INCLUDE_LINE" > "$ROOT_SSH_CFG"
    fi
    chmod 600 "$ROOT_SSH_CFG"
    log_ok "Sleeplab-SSH-Config in /root/.ssh/config inkludiert"
fi

# ── Phase 4: Pipeline-Installer ausfuehren ─────────────────────
log_phase "Sleeplab-Stack installieren"

PIPELINE_INSTALLER="$INSTALL_DIR/pipeline/install.sh"

if [[ ! -f "$PIPELINE_INSTALLER" ]]; then
    log_err "Pipeline-Installer nicht gefunden: $PIPELINE_INSTALLER"
    log_err "Repo unvollstaendig geklont? Pruefe $INSTALL_DIR/pipeline/"
    exit 1
fi

log_info "Uebergebe an $PIPELINE_INSTALLER ..."
echo ""
exec "$PIPELINE_INSTALLER" "$@"
