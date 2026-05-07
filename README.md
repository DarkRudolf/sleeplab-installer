# Sleeplab Klinik-Installer

Bootstrap-Installer für **Sleeplab** — Polysomnographie-Auswertung mit KI für Schlaflabore.

Komplett-Stack: PostgreSQL + Supabase, U-Sleep / DeepResNet / Transformer / YASA Modelle, EDF-Pipeline, PSG-Viewer-Web-UI, Bericht-Generator. Optional: separater Mac-mini-Worker für Video-Konvertierung (ASF→MP4) und LLM-Inferenz.

## Zwei Installations-Pfade

| Pfad | Wann | Befehl |
|---|---|---|
| **`install.sh`** | Hauptbox (Debian-VM) — pipeline + psg-viewer + sleepyland | siehe Schritt 4 unten |
| **`install-mac-worker.sh`** | Optional: Mac mini als Video-Worker | siehe Abschnitt „Mac-Worker einrichten" |

Wenn du **alles auf einer Linux-Box** laufen lassen willst, nutzt du nur `install.sh` mit Default-Setting (`INCLUDE_WORKER=yes`) — dann werden alle drei Repos in `/opt/sleeplab/` installiert.

Wenn der Worker auf einer **separaten Mac mini** läuft, ist `install.sh` mit `INCLUDE_WORKER=no` zu starten und der Mac mini bekommt seinen eigenen Bootstrap.

---

## Hardware-Anforderungen

| | Minimum | Empfohlen |
|---|---|---|
| **CPU** | 8 Kerne | 16 Kerne |
| **RAM** | 16 GB | 32 GB |
| **Disk** | 200 GB SSD | 500 GB+ NVMe |
| **Architektur** | x86_64 oder ARM64 | — |
| **OS** | Debian 12+ oder Ubuntu 22.04+ | Debian 13 (trixie) |
| **Internet** | nur Port 443/HTTPS outbound | — |

---

## Komplett-Anleitung — von Debian minimal bis Sleeplab läuft

Alle Befehle als `root` (oder mit `sudo`) auf dem frisch installierten Debian-minimal-Server.

### Schritt 1 — Grund-Tools installieren

Frisch installiertes Debian-minimal bringt fast nichts mit. Erstmal das Nötigste:

```bash
apt update
apt install -y curl ca-certificates gnupg lsb-release sudo openssh-server
```

> **Hinweis:** `openssh-server` ist nur nötig falls du den Server **remote** verwalten willst (z.B. via SSH-Login von deinem Arbeits-PC aus). Bei direktem Zugang am Server kann es weggelassen werden.

### Schritt 2 — Docker installieren

Sleeplab läuft komplett in Docker-Containern. Offizielle Docker-Installation:

```bash
# Docker-Repository hinzufügen
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker installieren
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Test
docker --version
docker compose version
```

### Schritt 3 — Firewall-Check (optional, nur falls relevant)

Sleeplab braucht **eingehend**:
- **Port 8887** (PSG-Viewer-Web-UI) — von Klinik-LAN aus erreichbar
- **Port 22** (SSH) — für deine Wartung

Sleeplab braucht **ausgehend**:
- **Port 443** (HTTPS) — für GitHub, Docker-Hub und Updates

Falls eine `ufw`-Firewall aktiv ist:

```bash
ufw allow 22/tcp        # SSH-Zugang
ufw allow 8887/tcp      # PSG Viewer (im Klinik-Netz)
ufw allow out 443/tcp   # HTTPS outbound
ufw enable              # nur falls noch nicht aktiv
```

### Schritt 4 — Sleeplab-Bootstrap herunterladen + ausführen

```bash
curl -fsSL https://raw.githubusercontent.com/DarkRudolf/sleeplab-installer/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

Der Installer wird dich nach folgendem fragen:

```
Klinik/Praxis-Name             > z.B. HNO Rüsselsheim
Server-Hostname                > z.B. sleeplab.hno-ruesselsheim.de
Dein Name (Ansprechpartner)    > z.B. Dr. Schmidt
Deine Email (für Antwort)      > z.B. dr.schmidt@hno-ruesselsheim.de
Notiz (optional)               > z.B. Erstinstallation
```

### Schritt 5 — Token freischalten lassen

Nach den Eingaben generiert der Installer **die SSH-Deploy-Keys** (zwei oder drei je nach `INCLUDE_WORKER`-Setting) und zeigt einen vorgefertigten E-Mail-Text an. **Kopiere diesen Text komplett** und schicke ihn per E-Mail an:

```
psg-viewer@marco-stankowitz.de
```

Das PSG-Viewer-Team trägt die Public Keys in GitHub ein (Read-Only-Deploy-Keys, keine Push-Rechte) und antwortet dir mit *„freigeschaltet"*.

**Wichtig:** Lass das Terminal-Fenster mit dem laufenden Installer **offen** während du die E-Mail schickst und auf die Antwort wartest.

### Schritt 6 — Antwort abwarten und Enter drücken

Sobald die Bestätigung kommt: zurück ins Terminal, **Enter drücken**. Der Installer testet die Verbindung selbständig. Bei Erfolg klont er die Repos und übergibt an den Pipeline-Installer, der den Rest erledigt:

- Docker-Netzwerk anlegen
- Supabase + PostgreSQL hochfahren
- DB-Schema importieren
- Sleepyland (KI-Modelle) starten
- Pipeline starten
- PSG Viewer starten
- Health-Checks

Nach 5–15 Minuten ist der Stack live. Der Installer zeigt am Ende die URL:

```
PSG Viewer: http://<Server-IP>:8887
```

### Schritt 7 — Erstkonfiguration im Browser

Browser auf `http://<Server-IP>:8887/login` öffnen. Standard-Login:

```
Benutzer:  admin
Passwort:  admin
```

**Sofort ändern!** Im Admin-Panel → Benutzer → Passwort ändern.

Danach optional:
- **Klinik-Logo + Branding** (Admin → Einstellungen → Allgemein)
- **LDAP/AD-Anbindung** (Admin → Einstellungen → AD/LDAP)
- **E-Mail-SMTP** für Berichts-Versand (Admin → Einstellungen → E-Mail)

---

## Mac-Worker einrichten (optional, für Video + LLM)

Wenn du einen Mac mini als Video-Worker einsetzen willst (typische Konstellation: Hauptbox = Debian-VM mit Pipeline + psg-viewer, Mac mini = ffmpeg-Konvertierung + Ollama-LLM), dann:

### 1. Hauptbox ohne Worker installieren

Auf der Debian-VM:

```bash
INCLUDE_WORKER=no sudo ./install.sh
```

Damit erzeugt der Installer nur Deploy-Keys für `pipeline` und `psg-viewer`.

### 2. Mac-mini-Bootstrap

Auf dem Mac mini (frisch eingerichtet, Homebrew installiert):

```bash
curl -fsSL https://raw.githubusercontent.com/DarkRudolf/sleeplab-installer/main/install-mac-worker.sh -o install-mac-worker.sh
chmod +x install-mac-worker.sh
sudo ./install-mac-worker.sh
```

> **Hinweis:** `curl` ohne `sudo` aufrufen — sonst gehört die Datei `root` und `chmod` failt mit *Operation not permitted*. Falls schon passiert: `sudo rm install-mac-worker.sh` und nochmal ohne `sudo` herunterladen.

Das Skript führt durch:

1. Klinik-/Mac-Daten abfragen
2. Eigenen Deploy-Key für `sleeplab-video-worker` generieren
3. **E-Mail-Text mit Public Key** anzeigen — den schickst du an `psg-viewer@marco-stankowitz.de` zur Freischaltung
4. Nach Bestätigung: Repo klonen, venv anlegen, Self-Signed-TLS-Zertifikat erzeugen, `shared_secret` zufällig generieren, LaunchDaemon installieren und starten

### 3. Im psg-viewer-Admin-Panel verbinden

Am Ende zeigt der Mac-Installer die drei Werte für die Hauptbox:

```
Worker-URL:        https://192.168.x.y:8443
Shared-Secret:     <hex>
TLS-Fingerprint:   <SHA256>
```

Diese drei Werte trägst du im psg-viewer Admin-Panel unter „Video-Worker" ein. Damit weiß der psg-viewer wie er den Mac mini erreicht und prüft das TLS-Cert per Pinning gegen den Fingerprint — kein öffentliches CA-Cert nötig, weil's interne LAN-Kommunikation ist.

### 4. Updates

Updates des Worker-Codes triggerst du aus dem psg-viewer-Admin-Panel (Button „Worker aktualisieren"). Der psg-viewer ruft den `POST /admin/update`-Endpunkt am Worker, der seinerseits `git pull` macht und sich neu startet. Manuell:

```bash
sudo -u ki bash -c 'cd /opt/sleeplab-video-worker && git pull && .venv/bin/pip install -e .'
sudo launchctl unload /Library/LaunchDaemons/de.sleeplab.video-worker.plist
sudo launchctl load   /Library/LaunchDaemons/de.sleeplab.video-worker.plist
```

---

## Schnell-Übersicht (für erfahrene Admins)

**Hauptbox alles in einer Linux-VM** (kein separater Mac):

```bash
apt update && apt install -y curl ca-certificates gnupg sudo
curl -fsSL https://get.docker.com | sh
curl -fsSL https://raw.githubusercontent.com/DarkRudolf/sleeplab-installer/main/install.sh -o install.sh
chmod +x install.sh && sudo ./install.sh
```

**Hauptbox + Mac-mini-Worker**:

```bash
# Box 1 — Debian-VM
INCLUDE_WORKER=no sudo ./install.sh

# Box 2 — Mac mini (curl OHNE sudo, sonst root-owned → chmod failt)
curl -fsSL https://raw.githubusercontent.com/DarkRudolf/sleeplab-installer/main/install-mac-worker.sh -o install-mac-worker.sh
chmod +x install-mac-worker.sh
sudo ./install-mac-worker.sh
```

## Sicherheit

- **Private SSH-Schlüssel verlassen nie den Server** — chmod 600, root-only, unter `/etc/sleeplab/ssh/`
- **Read-Only-Deploy-Keys** in GitHub — kein Push-Zugriff, auch wenn der Schlüssel kompromittiert wird
- **Pro Server eigenes Schlüsselpaar** — können einzeln in GitHub revoked werden
- **SSH über Port 443** (`ssh.github.com:443`) — funktioniert auch hinter Klinik-Firewalls die Port 22 sperren

## Updates

```bash
cd /opt/sleeplab/pipeline && git pull
cd /opt/sleeplab/psg-viewer && git pull
docker compose up -d --build
```

Oder über das CLI-Tool nach der Installation:

```bash
sleeplab update
```

## Bei Problemen

| Problem | Erste Diagnose |
|---|---|
| `apt install docker-ce` schlägt fehl | Repository-Config prüfen: `cat /etc/apt/sources.list.d/docker.list` |
| `git clone` Permission denied (publickey) | Marco hat den Key noch nicht eingetragen — abwarten und nochmal Enter im Installer |
| Container startet nicht | `docker logs <container-name>` zeigt warum |
| Web-UI nicht erreichbar | Firewall: `ufw status`, Container-Health: `docker ps` |

Bei dauerhaften Problemen: **psg-viewer@marco-stankowitz.de** mit Server-Hostname und Output von `docker logs` anfragen.

## Lizenz

Bootstrap-Installer: MIT (siehe LICENSE).
PSG Viewer + Pipeline: privat (Lizenz pro Klinik nach Vereinbarung).
