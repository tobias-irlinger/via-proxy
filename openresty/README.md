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
| Anbieter | eine Datei [`providers.json`](providers.json); nur dort gelistete Hosts werden geproxyt (Allowlist), `.example.com` erlaubt alle Subdomains |
| Starting-Point-URL | `https://login.<domain>/login?url=<URL>` (auch `qurl=`), kompatibel zu EZproxy-Links aus Discovery/Linkresolver: dort nur das Präfix tauschen |
| Login | OIDC (Authorization Code + PKCE) am Shibboleth-IdP; ein Session-Cookie für `.<domain>`, also einmal anmelden für alle Anbieter |
| Berechtigung | nur Werte aus `eduperson_scoped_affiliation`, die in `ALLOWED_AFFILIATIONS` stehen (z. B. `member@…`) |
| Campus | Adressen aus [`nginx/campus.conf`](nginx/campus.conf) werden direkt zum Anbieter umgeleitet |
| Inhalte | HTML, CSS, JS und JSON werden komplett gepuffert und alle URLs zu freigegebenen Hosts umgeschrieben (auch `//host` und `https:\/\/host`); `integrity`-Attribute und CSP-Header werden entfernt |
| Header | `Location`, `Link`, `Refresh`, `Access-Control-Allow-Origin` umgeschrieben; `Referer`/`Origin` zurück auf den Original-Host |
| Cookies | Modus `prefix` (Standard): `v.<anbieter>.<name>`, Domain auf `.<domain>` → geteilt zwischen allen Hosts desselben Anbieters, isoliert von anderen. Modus `host`: Name bleibt, Domain-Attribut entfällt (für Seiten, deren JavaScript eigene Cookies liest) |
| SSO-Cookie | wird nie an Anbieter weitergegeben |
| Logging | Access-Log mit Pseudonym (HMAC der OIDC-`sub` mit `VIA_LOG_KEY`), Anbieter und Ziel-Host, z. B. für ezPAARSE |

## Dateien

```
openresty/
├── docker-compose.yml       OpenResty + oauth2-proxy
├── .env.example             Konfiguration (Domain, IdP, Secrets)
├── providers.json           Anbieterliste (Beispiele, ungetestet)
├── nginx/
│   ├── nginx.conf           server-Blöcke: login.<domain> und *.<domain>
│   ├── campus.conf          IP-Bereiche für den Campus-Bypass
│   └── resolver.conf        DNS-Resolver für die Anbieter
├── lua/via/
│   ├── config.lua           lädt providers.json, Host-Allowlist
│   ├── hostmap.lua          Host <-> Proxy-Host
│   ├── rewrite.lua          URL-, Cookie- und Body-Rewriting
│   ├── handler.lua          Request-Phasen der Anbieter-Hosts
│   ├── login.lua            /login?url= und Startseite
│   └── pages.lua            Fehlerseiten
├── scripts/dev-cert.sh      selbstsigniertes Wildcard-Zertifikat für Tests
└── tests/
    ├── unit.sh, unit.lua    Unit-Tests (im OpenResty-Image)
    ├── e2e.sh               End-to-End-Test mit Mock-IdP und Test-Verlag
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

Änderungen an `providers.json` werden mit `docker compose restart openresty`
(oder `openresty -s reload`) aktiv.

## Einrichtung

1. **DNS**: `*.proxy.example.org` (und `login.proxy.example.org`) auf den Server.
2. **Zertifikat**: Wildcard `*.proxy.example.org` (Let's Encrypt nur per
   DNS-01). `fullchain.pem` und `privkey.pem` in `certs/` ablegen bzw.
   `VIA_CERT_DIR` setzen. Achtung: `/etc/letsencrypt/live/…` enthält Symlinks,
   die im Container nicht auflösbar sind. Am einfachsten kopiert ein
   certbot-Deploy-Hook die Dateien.
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

## Tests

```sh
tests/unit.sh     # Lua-Unit-Tests (36 Fälle)
tests/e2e.sh      # kompletter Ablauf mit Docker (27 Fälle), DEBUG=1 für Details
```

`e2e.sh` startet zusätzlich einen Mock-OIDC-IdP
(navikt/mock-oauth2-server) und einen simulierten Verlag mit zwei Hosts und
prüft u. a. Login, Ablehnung von Nicht-Mitgliedern, URL-, Header- und
Cookie-Rewriting sowie dass weder das SSO-Cookie noch Klarnamen nach außen
bzw. ins Log gelangen.

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
- **Kein Missbrauchsschutz** (Download-Limits pro Nutzer). Das Pseudonym im
  Log ist die Grundlage dafür, z. B. per Lua-Zähler in `lua_shared_dict`.
- Ports in Ziel-URLs (`https://host:8443/`) werden nicht unterstützt.
- Datenschutz: Aufbewahrungsfrist für Logs festlegen. Die IP-Adresse steht
  weiterhin im Log und muss ggf. gekürzt werden.
