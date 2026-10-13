# Offline-Betrieb aller Great-Hair-Day-Apps

Alle Apps laufen unter `mirjamwalenta-a11y.github.io` und nutzen denselben
Offline-Baustein aus diesem Repo:

| Datei | Wofür |
|---|---|
| `ghd-offline-sw.js` | Service-Worker-Logik (wird von der `sw.js` jeder App per `importScripts` geladen) |
| `ghd-offline.js` | Seiten-Teil: Service Worker anmelden, Anmeldung ohne Netz, Hinweisleiste, Konflikt-Dialog |

Jede App hat nur eine kleine eigene `sw.js` (App-Name, Version, Dateiliste)
und bindet `ghd-offline.js` im `<head>` direkt nach supabase-js ein.

**Reihenfolge beim Ausrollen:** zuerst dieses Repo (abwesenheiten-ghd)
veröffentlichen, dann die anderen Apps. Fehlt der Baustein noch, laufen die
Apps ganz normal weiter, nur eben noch nicht offline.

## Was offline geht

- **App starten:** Alle Dateien werden beim ersten Öffnen mit Netz gespeichert.
- **Daten lesen:** Jede Supabase-Abfrage (`/rest/v1/<tabelle>`) wird im Handy
  gemerkt (IndexedDB, getrennt pro angemeldeter Person). Ohne Netz kommt der
  zuletzt geladene Stand.
- **Speichern:** Neu anlegen, ändern und löschen (POST/PATCH/DELETE) sowie
  Datei-Uploads in Supabase Storage landen ohne Netz in einer Warteschlange und
  werden automatisch nachgeschickt, sobald wieder Netz da ist. Bis dahin zeigt
  die App die eigenen Eingaben schon an. Unten erscheint eine Leiste, z. B.
  „Offline – 3 Änderungen warten“.

## Konfliktregel: nichts überschreiben

- Neue Einträge und Uploads werden immer gespeichert.
- Änderungen und Löschungen werden nur gespeichert, wenn der Eintrag am Server
  noch genau so aussieht wie beim letzten Laden. Hat ihn inzwischen jemand
  anderer geändert, wird **nicht** überschrieben. Die Leiste zeigt dann
  „Änderung wurde nicht übernommen“. Ein Tipp darauf zeigt deine Eingabe und
  was die andere Person geändert hat, mit den Knöpfen *Verwerfen* oder
  *Meine Version trotzdem speichern* (mit Rückfrage).
- „Anlegen oder aktualisieren“ (Upsert mit `on_conflict`, z. B.
  Inventur-Zählungen) wird genauso geprüft. Hat inzwischen jemand anderer
  denselben Eintrag angelegt, wird nicht überschrieben.

## Was bewusst Netz braucht

- **Anmelden:** Ein neuer Login, Mitarbeiter-PIN und Token-Erneuerung brauchen
  Netz. Eine bestehende Supabase-Anmeldung wird ohne Netz weiterverwendet. Das
  ist nur Anzeige, die Rechte prüft beim Nachschicken wieder der Server.
- **RPC-Funktionen** (`/rest/v1/rpc/…`, z. B. Stempeln) und Edge Functions
  (Wörni/KI): Sie prüfen serverseitig Zeit, Ort oder Rechte. Ein späteres
  Nachschicken würde diese Prüfung verfälschen.
- Die **automatische Abmeldung nach 15 Minuten** (`ghd-sitzung.js`) gilt auch
  offline. Danach ist eine neue Anmeldung nötig, und die braucht Netz.

## Gut zu wissen

- Die App muss einmal **online** geöffnet worden sein.
- iPhone/Safari kann den Speicher löschen, wenn eine App wochenlang nicht
  benutzt wurde. Noch nicht hochgeladene Änderungen gingen dann verloren.
  Deshalb die Leiste beachten und bei Netz kurz öffnen.
- Ist niemand mehr angemeldet, löscht die App die gemerkten Daten vom Gerät.
  Noch nicht gesendete eigene Eingaben bleiben erhalten.
- Neue Dateien oder Seiten einer App in deren `sw.js` bei `vorab` eintragen.

## Anleitung für Samsung / Android

### Einrichten (einmal pro App)

1. Die App **mit Netz** öffnen, schließen und noch einmal öffnen. Erst dann
   sind ihre Daten im Handy gemerkt.
2. Die App auf den Startbildschirm holen:
   - **Chrome:** oben rechts **⋮** → **App installieren** oder
     **Zum Startbildschirm hinzufügen**
   - **Samsung Internet:** unten rechts **☰** → **Seite hinzufügen zu** →
     **Startbildschirm**. Manchmal erscheint stattdessen direkt in der
     Adressleiste ein Symbol zum Installieren.
3. Ab jetzt die App über das Symbol auf dem Startbildschirm öffnen. Sie läuft
   dann ohne Browserleiste, wie eine echte App.

### Testen

1. **Flugmodus** einschalten (von oben wischen → Flugzeug-Symbol).
2. Die App öffnen. Unten erscheint die Leiste „Offline – …“.
3. Etwas ändern, dann den Flugmodus ausschalten. Nach ein paar Sekunden
   verschwindet die Leiste, und die Änderung ist hochgeladen.

### Gut zu wissen auf Samsung

- **Hochladen im Hintergrund:** Offline gespeicherte Änderungen werden
  hochgeladen, sobald wieder Netz da ist, auch wenn die App gerade
  geschlossen ist.
- **Energiesparmodus und „Schlafende Apps“:** Samsung legt selten genutzte
  Apps gern schlafen. Dann klappt das Hochladen im Hintergrund nicht, und die
  Änderungen werden erst beim nächsten Öffnen der App hochgeladen.
- **Browserdaten löschen:** Wer in Chrome oder Samsung Internet die
  Browserdaten löscht, löscht auch die gemerkten Daten. Noch nicht
  hochgeladene Änderungen gehen dabei verloren. Vorher prüfen, dass unten
  keine Leiste „… Änderungen warten“ mehr steht.
- Gelöscht wird der Speicher sonst nur, wenn das Handy fast voll ist.
