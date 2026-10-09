# via-proxy als Ersatz für EZproxy – Analyse

Stand: Oktober 2026, Grundlage ist der aktuelle Inhalt dieses Repositorys
(76 `VirtualHost`-Blöcke für ca. 30 Anbieter, Konfiguration für FFZG Zagreb).

## Kurzfazit

via-proxy ist **kein Drop-in-Ersatz** für EZproxy, sondern eine Sammlung
handgepflegter Apache-Konfigurationen, die das Kernprinzip von EZproxy
("Proxy by Hostname") nachbaut. Für eine überschaubare Zahl von Anbietern mit
klassischen, serverseitig gerenderten HTML-Seiten funktioniert das gut und
kostet keine Lizenzgebühren. Es fehlen aber die Teile, die EZproxy im
Bibliotheksbetrieb eigentlich ausmachen: Starting-Point-URLs
(`/login?url=…`) für Discovery/Linkresolver, eine gepflegte Stanza-Bibliothek,
robustes JavaScript-Rewriting, Session- und Missbrauchskontrolle sowie
Shibboleth/SAML-Anbindung. Diese Lücken sind teils mit überschaubarem Aufwand
schließbar (Starting Point, SSO, Hostnamen-Schema, Statistik), teils
strukturell (Single-Page-Apps großer Anbieter, Pflegeaufwand pro Anbieter).

Empfehlung: via-proxy eignet sich als **ergänzende oder Übergangslösung**
für einzelne Anbieter bzw. für Einrichtungen mit Apache-Know-how und kleinem
Portfolio. Als vollständige Ablösung von EZproxy nur zusammen mit dem
Ausbau aus Abschnitt 5 – und parallel sollte geprüft werden, wie viele
Anbieter sich direkt per föderiertem Login (Shibboleth/DFN-AAI,
SeamlessAccess) anbinden lassen, sodass gar kein Proxy mehr nötig ist.

## 1. Wie via-proxy funktioniert

| Baustein | Umsetzung in via-proxy | EZproxy-Entsprechung |
|---|---|---|
| Hostnamen-Schema | `www.jstor.org` → `www.jstor.org.p.vbz.ffzg.hr` (ein `VirtualHost` pro Ursprungshost) | `Option ProxyByHostname` (`www-jstor-org.ezproxy…`) |
| Weiterleitung | `mod_proxy`: `ProxyPass` / `ProxyPassReverse` | interner Proxy |
| Inhalts-Rewriting | `mod_substitute` mit festen `s|https://host|https://host.p…|`, gefiltert auf `text/html` | automatisches Rewriting aller bekannten Hosts (`H`/`HJ`/`DJ`), `Find`/`Replace` |
| Redirects | `Header edit* Location …` | automatisch |
| Cookies | `Header edit* Set-Cookie` biegt `domain=` auf die Proxy-Domain um; Cookies landen im Browser | Cookies bleiben serverseitig in der EZproxy-Session |
| Authentifizierung `p.` | HTTP Basic Auth (htpasswd, dann LDAP) direkt im `<Location />` jedes Hosts (`ssl.conf`) | `user.txt` mit `::LDAP`, `::CGI`, `::Shibboleth` … |
| Authentifizierung `p2.` | Cookie-SSO mit `mod_auth_pubtkt` (`sso-pubtkt.conf`), Login über externes `login.pl` (nicht im Repo) | EZproxy-Session-Cookie über alle Hosts |
| Campus-IP | `Require ip 193.198.212.0/22`, zusätzlich Redirect der Campus-Nutzer direkt zum Anbieter | `AutoLoginIP`, `ExcludeIP` |
| Neue Anbieter | `add-provider.pl` / `add-provider-p2.pl` erzeugen eine Konfig-Datei, danach Handarbeit | Stanza aus OCLC-Liste in `config.txt` kopieren |
| Zertifikat | Let's Encrypt, SAN-Liste bzw. DNS-01-Wildcard (`certbot-wildcard.txt`) | ein Wildcard-Zertifikat `*.ezproxy.example.edu` |
| Linkliste | statische `index.html` | `menu.htm`, Starting-Point-URLs |

Es gibt zwei Generationen nebeneinander: `p.vbz.ffzg.hr` (Basic Auth, große
Datei `p.vbz.ffzg.hr.conf`) und `p2.vbz.ffzg.hr` (pubtkt-SSO, bisher nur
5 Provider-Dateien). Der Wechsel auf `p2` war nötig, weil Basic Auth vom
Browser **pro Hostname** gemerkt wird – Nutzer mussten sich bei jedem neuen
Anbieterhost (z. B. DOI-Redirects) erneut anmelden.

## 2. Was gut funktioniert

- **Keine Lizenzkosten**, nur Standard-Apache-Module
  (`proxy_http`, `substitute`, `headers`, `rewrite`, optional `auth_pubtkt`).
- **Transparent und debugbar**: jede Regel steht im Klartext, Fehler lassen
  sich mit Apache-Logs und `curl` nachvollziehen.
- **Campus-Bypass**: Nutzer im Campusnetz werden direkt zum Anbieter
  umgeleitet, belasten den Proxy also nicht.
- **Statistik möglich**: Zugriffe laufen in `access-p*.log`
  (`vhost_combined`, inkl. Benutzername bei Basic Auth/pubtkt) und können z. B.
  mit ezPAARSE ausgewertet werden (benötigt ein passendes Log-Format).
- **SSO-Muster mit pubtkt ist tragfähig**: ein zentraler Login-Host setzt ein
  signiertes Cookie für `*.p2…`; alle Anbieterhosts prüfen nur die Signatur.
  Dahinter lässt sich jede Login-Methode hängen (siehe 5.2).

## 3. Lücken gegenüber EZproxy

### 3.1 Funktional (für den Bibliotheksbetrieb entscheidend)

1. **Keine Starting-Point-URL.** Discovery-Systeme, Linkresolver, ERM und
   Katalog arbeiten mit einem Proxy-Präfix
   (`https://ezproxy…/login?url=https://www.jstor.org/stable/123`).
   via-proxy kennt so etwas nicht; Links müssen bereits im Proxy-Hostnamen
   vorliegen. Ohne diese Funktion ist eine Migration aus Primo/Alma/EDS/SFX
   heraus praktisch nicht machbar. (Gut nachrüstbar, siehe 5.1.)
2. **Keine Stanza-Bibliothek.** OCLC pflegt Stanzas für tausende
   Datenbanken. In via-proxy muss jeder Anbieter einzeln erarbeitet
   werden – inkl. aller Neben-Hosts (CDNs, Auth-Hosts, API-Hosts). Das ist
   der größte Dauer-Aufwand.
3. **JavaScript-/SPA-Anbieter funktionieren schlecht.** Das
   Rewriting von JS und CSS wurde wegen Fehlern weitgehend abgeschaltet
   (Commit „remove css and javascript filtering“, Fehler
   `AH01328: Line too long`). Web of Science ist laut `index.html` und
   Commit-Historie trotz Aufwand **nicht funktionsfähig**. Moderne
   Plattformen mit `fetch()`-APIs, dynamisch zusammengesetzten URLs,
   Content-Security-Policy, Subresource-Integrity-Hashes (werden durch
   `Substitute` ungültig) oder Service Workern sind mit reinem Text-Ersetzen
   kaum beherrschbar. EZproxy hat hier ebenfalls Grenzen, aber deutlich mehr
   Heuristik und gepflegte Workarounds.
4. **Unbekannte Hosts „verlassen“ den Proxy.** Links auf nicht
   konfigurierte Hosts werden nicht umgeschrieben; der Nutzer landet ohne
   Proxy beim Anbieter und hat keinen Zugriff. Es gibt keine
   Hinweisseite „Host nicht konfiguriert“.
5. **Keine Gruppen/Berechtigungen pro Datenbank.** Jeder angemeldete Nutzer
   darf alles (EZproxy: `Group`, `user.txt`-Regeln).

### 3.2 Betrieb und Sicherheit

1. **Kein Missbrauchsschutz.** EZproxy bietet `UsageLimit`,
   `MaxSessions`, `Audit`, Erkennung kompromittierter Konten. Anbieter
   sperren bei systematischem Download die **gesamte Proxy-IP** – ohne
   Limits trifft das alle Nutzer. Nachrüstbar z. B. mit
   `mod_security`/`mod_evasive` oder fail2ban auf Basis der Logs, aber nicht
   vorhanden.
2. **Cookies liegen im Browser.** Anbieter-Cookies werden auf die
   Proxy-Domain umgeschrieben; alle Anbieter teilen sich damit eine
   Cookie-Domain (`*.p2.vbz.ffzg.hr`). In `p.` wird zusätzlich das
   `secure`-Flag entfernt. EZproxy isoliert Anbieter-Cookies serverseitig.
3. **Basic Auth** (Generation `p.`) schickt das Passwort bei jedem Request
   an jeden Host; nur `p2.` mit pubtkt ist zeitgemäß.
4. **Halboffener Proxy für CloudFront**: der Host
   `*.cloudfront.net.p2…` (`providers/www.webofscience.com.conf`) leitet
   per `RewriteRule … [P]` an *beliebige* CloudFront-Distributionen weiter
   (für angemeldete Nutzer).
5. **Geheimnis im Repository**: `certbot-wildcard.txt` enthält den
   TSIG-Schlüssel für dynamische DNS-Updates im Klartext. Der Schlüssel
   sollte rotiert und die Datei bereinigt werden.
6. **Debug in Produktion**: `TKTAuthDebug 3`, `LogLevel Debug` (Cambridge),
   pubtkt mit `TKTAuthDigest sha1`.
7. **`Accept-Encoding` wird entfernt**, damit `mod_substitute` Klartext
   bekommt – höhere Bandbreite zum Anbieter.

### 3.3 Zertifikate und Hostnamen

Das Schema „Ursprungshost + Suffix“ (`www.jstor.org.p2.vbz.ffzg.hr`) erzeugt
Namen mit mehreren Labels unterhalb der Proxy-Domain. Ein Wildcard-Zertifikat
`*.p2.vbz.ffzg.hr` deckt aber **nur ein Label** ab – deshalb listet jedes
Provider-Skript „add domains to SSL certificate“ und es braucht zusätzliche
Wildcards wie `*.bmj.com.p2…`. Let's Encrypt erlaubt max. 100 Namen pro
Zertifikat. EZproxy umgeht das, indem es Punkte durch Bindestriche ersetzt
(`www-jstor-org.ezproxy…`), sodass ein einziges Wildcard-Zertifikat reicht.

### 3.4 Wartbarkeit

- Domain, IP-Bereiche, Zertifikatspfade, Login-URL und Logpfade sind in
  jeder Datei fest auf FFZG verdrahtet.
- Zwei fast identische Generator-Skripte; die erzeugten Dateien werden
  danach von Hand angepasst und sind nicht reproduzierbar.
- Das Login-Skript `login.pl` für pubtkt liegt nicht im Repository.
- Es gibt keine Tests; Funktionsprüfung erfolgt manuell im Browser.

## 4. Gegenüberstellung

| Kriterium | EZproxy | via-proxy |
|---|---|---|
| Kosten | OCLC-Abo (selbst gehostet oder Hosted) | frei |
| Anbieter-Konfigurationen | gepflegte OCLC-Stanzas | selbst erstellen und pflegen |
| Starting-Point-URL / Proxy-Präfix | ja | nein |
| Proxy by Hostname | ja, 1 Wildcard-Zertifikat | ja, viele SAN-/Wildcard-Einträge |
| JS-lastige Plattformen | eingeschränkt, mit Workarounds | weitgehend nein |
| Shibboleth/SAML, CAS, LDAP | ja | LDAP (Basic Auth); SAML nur über eigene Login-Komponente |
| SSO über alle Anbieter | ja | ja (`p2` mit pubtkt) |
| Campus-IP-Bypass | ja | ja |
| Usage Limits / Audit | ja | nein |
| Logs für Statistik | ja | ja (Apache-Logs) |
| Admin-Oberfläche | ja | nein |
| Support / Community | OCLC, große Nutzerbasis | ein Hauptentwickler, Einzelinstallation |

## 5. Was für einen produktiven Ersatz nötig wäre

Priorisiert nach Nutzen:

1. **Starting-Point-Endpunkt** `https://proxy…/login?url=<URL>`: Ziel-Host
   gegen eine Allowlist prüfen (`RewriteMap` aus den konfigurierten
   `ServerName`s oder ein kleines CGI wie `login.pl`), auf den Proxy-Host
   umschreiben und – falls nicht angemeldet – über den Login zurückleiten.
   Für unbekannte Hosts direkt zum Original weiterleiten oder eine
   Hinweisseite zeigen.
2. **Login per Shibboleth/DFN-AAI (oder LDAP) auf dem Login-Host**, der
   danach das pubtkt-Cookie ausstellt (`mod_shib` oder `mod_auth_mellon`
   nur auf diesem einen Host). So bleibt das bewährte pubtkt-Muster erhalten
   und die Anbieterhosts brauchen keine SAML-Konfiguration. `login.pl` ins
   Repo aufnehmen.
3. **Hostnamen-Schema mit Bindestrichen** (`www-jstor-org.proxy…`) und ein
   einziges Wildcard-Zertifikat. Erfordert angepasste
   `Substitute`/`Location`-Regeln (Punkt→Bindestrich) – gut mit generierten
   Regeln machbar.
4. **Parametrisierung**: alle einrichtungsspezifischen Werte (Domain,
   IP-Bereiche, Zertifikat, Login-URL, Logpfad) zentral definieren, z. B.
   mit `mod_macro` oder einem einzigen Generator mit Template; generierte
   Dateien nicht mehr von Hand editieren, sondern Anbieter-Besonderheiten
   als Daten (zusätzliche Hosts, Substitutionen, Content-Types) ablegen.
5. **Missbrauchsschutz**: Rate-Limits pro Benutzer, Alarmierung bei
   auffälligen Download-Mengen, Sperrliste für Konten.
6. **Sicherheitsbereinigung**: TSIG-Schlüssel rotieren und aus der
   Historie entfernen, Debug-Level zurücknehmen, CloudFront-Proxy auf
   konkrete Distributionen einschränken, Generation `p.` (Basic Auth)
   auslaufen lassen.
7. **Statistik**: Log-Format für ezPAARSE festlegen (Benutzer, Host, URL,
   Status, Größe) und regelmäßig auswerten (COUNTER-nahe Auswertung).
8. **Anbieter-Inventur**: Für jeden lizenzierten Anbieter prüfen
   (a) funktioniert direkter föderierter Zugriff (Shibboleth/SeamlessAccess)?
   (b) wenn nicht: gibt es eine OCLC-Stanza als Vorlage und funktioniert die
   Plattform über via-proxy? Daraus ergibt sich, ob der verbleibende
   Proxy-Bedarf den Pflegeaufwand rechtfertigt.

## 6. Vorgehen bei einer Evaluierung

1. Testinstanz mit eigener Domain und Wildcard-Zertifikat aufsetzen
   (Apache 2.4, Module `proxy_http substitute headers rewrite`).
2. Die 10–20 meistgenutzten Anbieter laut EZproxy-Statistik auswählen und
   mit `add-provider-p2.pl` (angepasst) einrichten.
3. Pro Anbieter typische Abläufe testen: Suche, Volltext-PDF, Export,
   DOI-Auflösung, Login-Redirects des Anbieters.
4. Ergebnis je Anbieter dokumentieren: läuft / läuft mit Anpassung / läuft
   nicht. Erst danach über Starting-Point, SSO und Migration entscheiden.
5. Anbieter informieren bzw. IP-Freischaltung für den neuen Proxy-Server
   beantragen (gleiche Anforderung wie bei EZproxy).
