# via-proxy NG: OpenResty + oauth2-proxy (Prototyp)

Prototyp für einen EZproxy-Ersatz auf Basis von **OpenResty** (nginx + Lua) mit
Login über **OIDC am Shibboleth-IdP** via **oauth2-proxy**. Hintergrund und
Vergleich mit EZproxy: [`../docs/via-proxy-vs-ezproxy.md`](../docs/via-proxy-vs-ezproxy.md).

Status: Prototyp. Ablauf und Rewriting sind mit einem Test-IdP und einem
simulierten Verlag automatisiert getestet, **nicht** gegen echte Anbieter.

## Funktionsweise

```
Browser ── https://login.proxy.example.org/login?url=https://www.jstor.org/stable/123
   │  302
   ▼
https://www-jstor-org.proxy.example.org/stable/123       (OpenResty, ein server-Block für alle Anbieter)
   │  auth_request ──► oauth2-proxy: gültiges SSO-Cookie?
   │      nein ──► login.proxy.example.org/oauth2/start ──► Shibboleth IdP (OIDC) ──► zurück
   │      ja   ──► Proxy zu https://www.jstor.org/stable/123
   ▼
Antwort: Links, Redirects, Cookies werden auf *.proxy.example.org umgeschrieben
```

| Funktion | Umsetzung |
|---|---|
| Hostnamen | EZproxy-Schema: `.` → `-`, `-` → `--` (`www.some-site.co.uk` → `www-some--site-co-uk.<domain>`). Ein Wildcard-Zertifikat `*.<domain>` reicht. |
| Anbieter | eine Datei [`config/providers.json`](config/providers.json), Änderungen werden ohne Neustart übernommen; nur dort gelistete Hosts werden geproxyt (Allowlist), `.example.com` erlaubt alle Subdomains |
| Starting-Point-URL | `https://login.<domain>/login?url=<URL>` (auch `qurl=`), kompatibel zu EZproxy-Links aus Discovery/Linkresolver: dort nur das Präfix tauschen |
| Login | OIDC (Authorization Code + PKCE) am Shibboleth-IdP; ein Session-Cookie für `.<domain>`, also einmal anmelden für alle Anbieter |
| Berechtigung | nur Werte aus `eduperson_scoped_affiliation`, die in `ALLOWED_AFFILIATIONS` stehen (z. B. `member@…`) |
| Campus | Adressen aus [`nginx/campus.conf`](nginx/campus.conf) werden direkt zum Anbieter umgeleitet |
| Inhalte | HTML, CSS, JS und JSON werden komplett gepuffert und alle URLs zu freigegebenen Hosts umgeschrieben (auch `//host` und `https:\/\/host`); `integrity`-Attribute und CSP-Header werden entfernt |
| Header | `Location`, `Link`, `Refresh`, `Access-Control-Allow-Origin` umgeschrieben; `Referer`/`Origin` zurück auf den Original-Host |
| Cookies | Modus `prefix` (Standard): `v.<anbieter>.<name>`, Domain auf `.<domain>` → geteilt zwischen allen Hosts desselben Anbieters, isoliert von anderen. Modus `host`: Name bleibt, Domain-Attribut entfällt (für Seiten, deren JavaScript eigene Cookies liest) |
| SSO-Cookie | wird nie an Anbieter weitergegeben |
| Download-Limits | pro Nutzer: Dokument-Downloads und Datenvolumen im gleitenden Zeitfenster, bei Überschreitung zeitlich begrenzte Sperre (siehe unten) |
| Logging | Access-Log mit Pseudonym (HMAC der OIDC-`sub` mit `VIA_LOG_KEY`), Anbieter und Ziel-Host, z. B. für ezPAARSE |

## Dateien

```
openresty/
├── docker-compose.yml       OpenResty + oauth2-proxy
├── .env.example             Konfiguration (Domain, IdP, Secrets)
├── config/providers.json    Anbieterliste und Limits (Beispiele, ungetestet)
├── nginx/
│   ├── nginx.conf           server-Blöcke: login.<domain> und *.<domain>
│   ├── campus.conf          IP-Bereiche für den Campus-Bypass
│   └── resolver.conf        DNS-Resolver für die Anbieter
├── lua/via/
│   ├── config.lua           lädt providers.json, Host-Allowlist, Hot-Reload
│   ├── health.lua           /health und /status
│   ├── hostmap.lua          Host <-> Proxy-Host
│   ├── rewrite.lua          URL-, Cookie- und Body-Rewriting
│   ├── handler.lua          Request-Phasen der Anbieter-Hosts
│   ├── limits.lua           Download-Limits pro Nutzer, Admin-API
│   ├── login.lua            /login?url= und Startseite
│   └── pages.lua            Fehlerseiten
├── scripts/
│   ├── setup_acme.sh        Wildcard-Zertifikat per ACME (HM-CA mit EAB)
│   ├── acme-deploy-hook.sh  certbot-Hook: Zertifikat kopieren, OpenResty neu laden
│   └── dev-cert.sh          selbstsigniertes Wildcard-Zertifikat für Tests
└── tests/
    ├── unit.sh, unit.lua    Unit-Tests (im OpenResty-Image)
    ├── e2e.sh               End-to-End-Test mit Mock-IdP und Test-Verlagen
    ├── acme.sh              Zertifikat ausstellen/erneuern gegen Pebble + BIND
    └── …
```

## Anbieter eintragen

```json
{
  "id": "jstor",
  "name": "JSTOR",
  "start": "https://www.jstor.org/",
  "hosts": ["www.jstor.org", "jstor.org", ".jstor.org"],
  "cookies": "prefix",
  "substitutions": [
    { "pattern": "\"apiHost\":\"api\\.jstor\\.org\"",
      "replace": "\"apiHost\":\"api-jstor-org.{proxy_domain}\"" }
  ]
}
```

- `id`: nur `[a-z0-9]`, wird für Cookie-Präfix und Log verwendet.
- `hosts`: alle Hosts, die der Anbieter braucht (Login, CDN, API). Fehlende
  Hosts erkennt man im Browser daran, dass Links aus dem Proxy herausführen.
- `content_types` (optional): überschreibt die Liste der umgeschriebenen Typen.
- `substitutions` (optional): zusätzliche reguläre Ausdrücke (PCRE) für Fälle,
  die das allgemeine URL-Rewriting nicht erfasst, z. B. Hostnamen ohne Schema
  in JavaScript. `{proxy_domain}` wird ersetzt.

Änderungen an `config/providers.json` übernimmt der Proxy ohne Neustart:
Jeder nginx-Worker prüft die Datei alle `VIA_RELOAD_INTERVAL` Sekunden
(Standard 5) und lädt sie bei Änderungen neu. Eine fehlerhafte Datei (kaputtes
JSON, doppelter Host, ungültige `id` …) wird **nicht** übernommen: Die
bisherige Konfiguration bleibt aktiv, der Fehler steht im Log
(`via-config: keeping version …`) und unter `/status`. Ein *Neustart* mit
fehlerhafter Datei schlägt dagegen fehl (wie bei jeder nginx-Konfiguration). Welche Version aktiv
ist, zeigt:

```sh
curl http://127.0.0.1:8081/status
# {"status":"ok","config":{"version":"3f2a…","providers":42,"last_error":null,…},…}
```

Eingebunden wird das Verzeichnis `config/`, nicht die einzelne Datei: Editoren
ersetzen die Datei beim Speichern, und ein Einzeldatei-Mount in Docker würde
weiter die alte Version zeigen. Änderungen an `nginx/*.conf` (z. B.
Campus-Netze) brauchen weiterhin
`docker compose exec openresty openresty -s reload`. Ein Reload mit fehlerhafter
Konfiguration wird von nginx verworfen, die laufende Instanz bleibt aktiv.

## Download-Limits

Anbieter sperren bei systematischem Herunterladen meist die IP des Proxys,
also den Zugang für alle. Wie EZproxys `UsageLimit` zählt der Proxy deshalb
pro Nutzer und sperrt auffällige Kennungen vorübergehend. Konfiguriert wird das
in `config/providers.json`:

```json
"limits": {
  "window": 3600,
  "max_downloads": 150,
  "max_mb": 2000,
  "block": 3600,
  "contact": "Bibliothek, it-bibliothek@example.org"
}
```

- **Downloads** sind Antworten mit Status 200 und einem Typ aus
  `download_types` (Standard: PDF, EPUB, ZIP, `octet-stream`, RIS, BibTeX,
  Excel) oder mit `Content-Disposition: attachment`. Range-Requests von
  PDF-Viewern zählen nur einmal, nämlich für den Abschnitt ab Byte 0.
- **Volumen** zählt alle über den Proxy übertragenen Bytes.
- Gezählt wird in einem gleitenden Fenster von `window` Sekunden. Wer
  `max_downloads` oder `max_mb` überschreitet, wird für `block` Sekunden
  gesperrt und sieht eine Hinweisseite (HTTP 429 mit `Retry-After` und
  `contact`). Die Anfrage, die das Limit überschreitet, wird noch ausgeliefert.
- Ohne `limits` ist die Funktion aus. Die Werte oben sind Startwerte und
  sollten an der bisherigen EZproxy-Statistik geprüft werden.
- Sperren werden als `via-limit: user <pseudonym> blocked …` (Level `warn`)
  geloggt und lassen sich so für Alarme auswerten.

Zusätzlich kann jeder Anbieter eigene Limits bekommen:

```json
{ "id": "jstor", "hosts": ["www.jstor.org"],
  "limits": { "max_downloads": 50, "window": 3600 } },
{ "id": "doi", "hosts": ["doi.org"], "limits": false }
```

- **Objekt:** eigene Zähler und Schwellen für diesen Anbieter, *zusätzlich*
  zu den globalen Limits. Nicht gesetzte Werte (`window`, `block`,
  `contact`, `download_types`) werden von den globalen Limits übernommen.
  Eine Sperre gilt dann **nur für diesen Anbieter**; andere bleiben
  erreichbar. Sinnvoll für Anbieter mit strengeren Vertragsklauseln.
- **`false`:** Zugriffe auf diesen Anbieter werden gar nicht gezählt, z. B.
  beim DOI-Resolver, der nur weiterleitet.
- Fehlt `limits`, gelten nur die globalen Limits. Anbieter-Limits
  funktionieren auch ohne globalen `limits`-Block.

Admin-API, nur vom Server selbst erreichbar (Port 8081 auf `127.0.0.1`):

```sh
curl http://127.0.0.1:8081/limits                            # Sperren (global und je Anbieter)
curl http://127.0.0.1:8081/limits?user=<pseudonym>           # Zähler eines Nutzers
curl -X POST http://127.0.0.1:8081/limits?unblock=<pseudonym> # alle Sperren aufheben
```

Nutzer werden nur über ihr Pseudonym geführt (HMAC der OIDC-`sub` mit
`VIA_LOG_KEY`). Um eine Person zu kontaktieren, berechnet jemand mit Zugriff
auf den Schlüssel das Pseudonym für die infrage kommenden `sub`-Werte:

```sh
printf %s "<sub>" | openssl dgst -sha1 -hmac "$VIA_LOG_KEY" | awk '{print $NF}' | cut -c1-16
```

Zähler und Sperren liegen im Arbeitsspeicher (`lua_shared_dict`). Sie gelten
also pro Server und gehen bei einem Neustart verloren, ein Reload behält sie.
Für mehrere Proxy-Server müsste der Zustand nach Redis.

## Betrieb: Health und Status

| Endpunkt | Erreichbar | Inhalt |
|---|---|---|
| `https://login.<domain>/health` | öffentlich | `ok` (200) oder `unavailable` (503); prüft auch, ob oauth2-proxy antwortet. Für externes Monitoring |
| `http://127.0.0.1:8081/health` | nur Server | dasselbe, nutzt der Docker-Healthcheck |
| `http://127.0.0.1:8081/status` | nur Server | JSON: geladene Konfigurationsversion, Anzahl Anbieter, letzter Ladefehler |

OpenResty startet und lädt neu, auch wenn oauth2-proxy gerade nicht läuft
(der Name wird erst pro Anfrage aufgelöst); `/health` meldet dann 503.
`docker compose ps` zeigt den OpenResty-Container erst als `healthy`, wenn auch
oauth2-proxy bereit ist (OIDC-Discovery am IdP erfolgreich). Das
oauth2-proxy-Image hat keine Shell für einen eigenen Healthcheck, deshalb prüft
OpenResty es mit.

## Einrichtung

1. **DNS**: `*.proxy.example.org` (und `login.proxy.example.org`) auf den Server.
2. **Zertifikat**: Wildcard `*.proxy.example.org` per
   `scripts/setup_acme.sh` (siehe [Zertifikat per ACME](#zertifikat-per-acme)),
   oder `fullchain.pem` und `privkey.pem` von Hand in `certs/` ablegen.
3. **Shibboleth IdP** (ab 4.1 mit OIDC-OP-Plugin): Client (RP) registrieren
   - Redirect-URI: `https://login.proxy.example.org/oauth2/callback`
   - Grant: Authorization Code, PKCE erlaubt, Client-Secret (`client_secret_basic`)
   - Claims im ID-Token bzw. Userinfo: `sub` (am besten pairwise),
     `eduperson_scoped_affiliation` (als Liste). E-Mail ist nicht nötig.
4. **`.env`** aus `.env.example` erstellen, Secrets erzeugen:
   `openssl rand -base64 32 | tr -- '+/' '-_'` (Cookie),
   `openssl rand -hex 32` (Log-Pseudonym).
5. **Campus-Netze** in `nginx/campus.conf` eintragen.
6. `docker compose up -d`, dann `https://login.proxy.example.org/` aufrufen.
7. Bei den Anbietern die **ausgehende IP** des Servers für IP-basierten
   Zugang freischalten lassen (wie bei EZproxy).

Für Discovery/Linkresolver das bisherige EZproxy-Präfix
`https://ezproxy.example.org/login?url=` durch
`https://login.proxy.example.org/login?url=` ersetzen.

## Zertifikat per ACME

`scripts/setup_acme.sh` folgt dem Vorgehen aus `HM_template`: certbot am
internen ACME-Server der HM (`https://acme.hm.edu/acme/acme/directory`) mit
EAB-Zugangsdaten vom PKI-Team. Die Einstellungen stehen in `.env`
(`ACME_*`, siehe `.env.example`).

```sh
./scripts/setup_acme.sh      # einmalig; danach erneuert certbot.timer automatisch
sudo certbot renew --dry-run # Erneuerung testen
```

Unterschiede zum Template:

- **Wildcard**: ausgestellt wird für `<domain>` und `*.<domain>`. ACME
  verlangt für Wildcards die **DNS-Challenge**, der Standalone-Modus des
  Templates (HTTP-01) reicht dafür nicht.
  - `ACME_CHALLENGE=dns-rfc2136` (Standard): certbot setzt den TXT-Eintrag
    `_acme-challenge.<domain>` per dynamischem DNS-Update (RFC 2136). Dafür
    braucht es einen TSIG-Schlüssel, der für die Zone TXT-Updates darf
    (`ACME_RFC2136_SERVER`, `_NAME`, `_SECRET`); den stellt das DNS-Team aus.
    certbot legt die Zugangsdaten mit Rechten 600 ab.
  - `ACME_CHALLENGE=webroot`: OpenResty liefert
    `/.well-known/acme-challenge/` auf Port 80 aus. Das genügt **nur**, wenn
    die CA das Wildcard ohne DNS-Challenge ausstellt (Domain dort vorab
    validiert). Ob der HM-ACME-Server das tut, muss das PKI-Team sagen.
- **Kein Standalone**: Port 80 gehört OpenResty, certbot muss ihn nicht
  übernehmen; es gibt keine Unterbrechung.
- **Erneuerung**: der Deploy-Hook `scripts/acme-deploy-hook.sh` wird nur für
  dieses Zertifikat registriert (nicht global unter `renewal-hooks/`). Er
  kopiert Zertifikat und Schlüssel (600) nach `VIA_CERT_DIR` und lädt
  OpenResty per `openresty -s reload` neu: laufende Verbindungen und die
  Zähler der Download-Limits bleiben erhalten.

Wichtig: Das Zertifikat muss in den Browsern der Nutzer gültig sein (also von
einer öffentlich vertrauten CA stammen, z. B. über DFN/GÉANT TCS), da der
Proxy auch von privaten Geräten außerhalb des Campus genutzt wird.

## Tests

```sh
tests/unit.sh     # Lua-Unit-Tests (76 Fälle)
tests/e2e.sh      # kompletter Ablauf mit Docker (62 Fälle), DEBUG=1 für Details
tests/acme.sh     # ACME: Ausstellen + Erneuern (18 Fälle), braucht certbot
```

`e2e.sh` startet zusätzlich einen Mock-OIDC-IdP
(navikt/mock-oauth2-server) und einen simulierten Verlag mit zwei Hosts und
prüft u. a. Login, Ablehnung von Nicht-Mitgliedern, URL-, Header- und
Cookie-Rewriting, Download- und Volumen-Limits (global und je Anbieter)
inkl. Admin-API, Health- und
Status-Endpunkte, Docker-Healthcheck, Hot-Reload der Anbieterliste (auch mit
fehlerhafter Datei) sowie dass weder das SSO-Cookie noch Klarnamen nach außen
bzw. ins Log gelangen.

Die CI ([`.github/workflows/openresty.yml`](../.github/workflows/openresty.yml))
führt bei jedem Push und Pull Request, der `openresty/` betrifft, shellcheck,
eine JSON-Prüfung, die Unit-Tests, die End-to-End-Tests und den ACME-Test aus.

`acme.sh` startet Pebble (Test-CA von Let's Encrypt, mit EAB) und einen
BIND-Server mit TSIG-Schlüssel, stellt über `scripts/setup_acme.sh` ein
Wildcard-Zertifikat per DNS-01 aus, erzwingt eine Erneuerung und prüft, dass
OpenResty jeweils das neue Zertifikat ausliefert.

## Bekannte Grenzen / nächste Schritte

- **Nicht gegen echte Anbieter getestet.** Nächster Schritt: Top-10/20 der
  EZproxy-Statistik eintragen und Suche, PDF, Export und DOI-Links testen.
- **JavaScript-lastige Plattformen** (z. B. Web of Science), die URLs zur
  Laufzeit zusammensetzen, brauchen anbieterspezifische `substitutions` oder
  funktionieren nicht – wie bei jedem umschreibenden Proxy.
- **Cookies im Modus `prefix`** sind für JavaScript unter anderem Namen
  sichtbar; Seiten mit CSRF-Token im Cookie brauchen `"cookies": "host"`.
- Hostnamen mit mehr als 63 Zeichen nach der Kodierung passen nicht in ein
  DNS-Label (gleiche Grenze wie EZproxy).
- Bodies über `max_rewrite_bytes` (Standard 10 MB) werden unverändert
  durchgereicht.
- Ports in Ziel-URLs (`https://host:8443/`) werden nicht unterstützt.
- Datenschutz: Aufbewahrungsfrist für Logs festlegen. Die IP-Adresse steht
  weiterhin im Log und muss ggf. gekürzt werden.
