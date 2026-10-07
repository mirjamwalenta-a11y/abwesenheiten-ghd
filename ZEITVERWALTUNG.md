# Zeitverwaltung · Great Hair Day

Zentrale Anwendung für **Arbeitszeit, Urlaub und Krankenstand/Abwesenheiten**.
Stand: Prototyp (Oberfläche fertig, Datenbank als Entwurf).

| Datei | Inhalt |
|---|---|
| `zeitverwaltung.html` | Oberfläche, läuft mit erfundenen Demo-Daten nur im Browser |
| `zeitverwaltung_schema_entwurf.sql` | Datenbankstruktur inkl. RLS – **noch nicht live ausgeführt** |
| `abwesenheiten.html` | bestehende Abwesenheiten-App (bleibt unverändert in Betrieb) |

## 1. Was der Prototyp kann

Navigation: **Dashboard → Zeiterfassung → Urlaub → Krankenstand → Mitarbeiter → Kalender → Auswertungen → Einstellungen**

- **Login** – Demo-Auswahl einer Person; Rolle Administrator / Vorgesetzte / Mitarbeiter.
- **Dashboard** – Stempeluhr, Zeitkonto, Resturlaub; für die Leitung: wer heute im Dienst ist, wer fehlt, offene Anträge, offene Monatsabschlüsse, ausständige AU-Bestätigungen, Verstöße gegen das Arbeitszeitgesetz.
- **Zeiterfassung** – Kommen / Pause / Gehen, Monatsliste mit Beginn, Ende, Pause, Ist, Soll, Saldo; Zeitkonto kumuliert; Korrekturen (Mitarbeiter beantragt, Vorgesetzte genehmigt bzw. ändert direkt – immer mit Grund und Änderungsprotokoll); Monatsabschluss in zwei Schritten (Mitarbeiter bestätigt → Leitung schließt ab → Monat gesperrt; nur Admin öffnet wieder, mit Grund); Arbeitszeitnachweis zum Drucken mit Unterschriftszeilen.
- **Urlaub** – Antrag mit Vorschau (gezählte Urlaubstage laut Arbeitszeitmodell, ausgenommene Feiertage, wer gleichzeitig weg ist, Rest danach), Genehmigen/Ablehnen, Stornieren, Urlaubskonto (Anspruch, Übertrag, verbraucht, geplant, beantragt, Rest).
- **Krankenstand & Abwesenheiten** – Krankenstand, Arbeitsunfall, Pflegefreistellung, Dienstverhinderung, Berufsschule, Fortbildung, Zeitausgleich, unbezahlter Urlaub; offenes Ende plus „Gesund melden“; AU-Bestätigung; Krankenstandstage pro Person mit Anspruch auf Entgeltfortzahlung.
- **Lehrlinge & Berufsschule** – Lehrbeginn je Lehrling, das Lehrjahr wird automatisch berechnet. Berufsschultage pro Woche je Lehrjahr (Wien: 1. Lehrjahr 1,5 Tage, 2. und 3. Lehrjahr 1 Tag; unter *Einstellungen* änderbar). „Berufsschule planen“ trägt die Schultage für ein ganzes Schuljahr ein: ganzer Tag plus halber Tag im 1. Lehrjahr, Feiertage und Sommerferien ausgelassen, Wechsel ins nächste Lehrjahr automatisch. Halbe Schultage werden zur Hälfte angerechnet, den Rest arbeitet der Lehrling im Salon.
- **Mitarbeiter** – Name, Personalnummer, Abteilung, Funktion, Eintritt/Austritt, Arbeitszeitmodell, Urlaubstage (mit Vorschlag nach UrlG, aliquot zu den Arbeitstagen), Vorgesetzte/r, Rolle, KJBG-Kennzeichen, aktiv/inaktiv.
- **Kalender** – Teamkalender pro Monat mit Abwesenheitsarten, Anträgen, Feiertagen und Schließtagen. Kolleg/innen sehen bei anderen nur „A“ (abwesend), nicht den Grund.
- **Auswertungen** – Monats- und Jahresübersicht (Soll, Ist, angerechnete Abwesenheit, Saldo, Zeitkonto, Mehrarbeit, Überstunden, Urlaub, Krankenstand, Abschluss-Status). Export als **CSV für Excel** (Semikolon, Dezimalkomma, Umlaute korrekt) und als **PDF** über den Druckdialog.
- **Einstellungen** – Arbeitszeitmodelle (Stunden je Wochentag), gesetzliche Grenzen, KJBG-Werte, Zuschläge, Urlaubsbasis, AU-Regel, Schließtage, Übersicht der Rollen und Berechtigungen.

## 2. Österreichische Vorgaben, die geprüft bzw. abgebildet werden

| Thema | Regel | Umsetzung |
|---|---|---|
| Aufzeichnungspflicht | § 26 AZG | Beginn, Ende, Pausen je Tag; jede Änderung mit Person, Zeitpunkt, Grund |
| Ruhepause | § 11 AZG: > 6 h → 30 min (teilbar 2×15 / 3×10) | Warnung in Stempeluhr, Fehler in der Monatsprüfung |
| Höchstarbeitszeit | § 9 AZG: 12 h/Tag, 60 h/Woche, Ø 48 h in 17 Wochen | Warnung ab 10 h und 48 h, Fehler über 12 h und 60 h |
| Tägliche Ruhezeit | § 12 AZG: 11 h | Prüfung gegen das Arbeitsende des Vortags |
| Sonn- und Feiertage | ARG | Hinweis bei Arbeit an Sonn- und Feiertagen |
| Jugendliche (Lehrlinge unter 18) | KJBG: Pause ab 4,5 h, 8 h/Tag (9 h bei Verteilung), 40 h/Woche, 12 h Ruhezeit, Nachtruhe 20–6 Uhr | strengere Prüfung bei KJBG-Kennzeichen |
| Überstunden / Mehrarbeit | § 10 AZG 50 %, § 19d AZG 25 % bei Teilzeit | Mehrarbeit und Überstunden getrennt ausgewiesen (vereinfacht pro Woche) |
| Urlaub | § 2 UrlG: 25 Arbeitstage (5-Tage-Woche), ab 25 Dienstjahren 30 | Vorschlag aliquot zu den Arbeitstagen pro Woche; Feiertage zählen nicht |
| Verjährung Urlaub | § 4 Abs 5 UrlG | Hinweis im Urlaubskonto |
| Krankenstand | Entgeltfortzahlung 6 / 8 / 10 / 12 Wochen nach Dienstjahren | Anspruch je Person angezeigt |
| Pflegefreistellung | § 16 UrlG: bis 1 Woche pro Arbeitsjahr | eigene Abwesenheitsart |
| Feiertage | 13 gesetzliche Feiertage | automatisch berechnet (inkl. Ostern) |
| Aufbewahrung | u. a. § 132 BAO (7 Jahre) | Ausgetretene werden deaktiviert, nicht gelöscht |

**Wichtig:** Der Kollektivvertrag für das Friseurgewerbe kann abweichende Werte vorsehen (Normalarbeitszeit, Durchrechnung, Zuschläge, Samstagsarbeit, Arbeitszeit von Lehrlingen). Alle Grenzwerte sind deshalb unter *Einstellungen* änderbar. Bitte die Werte einmal mit der Lohnverrechnung bzw. der WKO abstimmen – die App ersetzt keine Rechtsberatung.

## 3. Datenbankstruktur (Entwurf)

Grundidee: **eine** Personenliste für alle Apps. Personen bleiben in `abw_team`, Urlaub und Krankenstand bleiben in `abw_anfragen` – die bestehende Abwesenheiten-App läuft also unverändert weiter.

```
abw_team (bestehend)  ── 1:1 ── zeit_profil            Personalnr, Abteilung, Vorgesetzte/r, KJBG, Übertrag
     │                ── 1:n ── zeit_modell_zuordnung  Modell „gültig ab“ ── zeit_arbeitsmodelle
     │                ── 1:n ── zeit_buchungen         1 Zeile pro Person und Tag
     │                ── 1:n ── zeit_korrekturen       Anträge der Mitarbeiter/innen
     │                ── 1:n ── zeit_protokoll         jede Änderung (nur lesbar)
     │                ── 1:n ── zeit_monatsabschluss   bestätigt / abgeschlossen
     └──────────────── 1:n ── abw_anfragen (bestehend) + au_bestaetigung, notiz, entschieden_von/_am
```

Sicherheit (nach `CLAUDE.md`):

- Alle neuen Tabellen haben **RLS ab dem Anlegen**, `anon` hat keinen Zugriff.
- Rollen prüft die **Datenbank**: Admin = `abw_is_owner()`, Vorgesetzte/r = `zeit_profil.vorgesetzter_id`.
- Arbeitszeiten sind per REST **nur lesbar**. Geschrieben wird ausschließlich über Funktionen:
  - `zeit_stempeln(aktion)` – Uhrzeit vom Server (Europe/Vienna), nicht vom Handy
  - `zeit_buchung_aendern(...)` – nur Leitung, Grund ist Pflicht, schreibt ins Protokoll
  - `zeit_korrektur_entscheiden(id, ja/nein)`
  - `zeit_monat_bestaetigen`, `zeit_monat_abschliessen`, `zeit_monat_oeffnen` (nur Admin)
- Ein Trigger sperrt abgeschlossene Monate zusätzlich.

Das Skript wurde lokal gegen eine nachgebaute Supabase-Umgebung getestet (zweimal hintereinander ausführbar). Geprüft wurde unter anderem: anon sieht nichts, Mitarbeiter sehen nur sich selbst und können nicht direkt schreiben, Vorgesetzte ändern nur ihr Team (nicht sich selbst), abgeschlossene Monate sind gesperrt, nur die Chefin öffnet wieder.

## 4. Nächste Schritte

1. Offene Fragen unten klären, Schema anpassen.
2. Schema im Supabase-Projekt ausführen, vorher `SICHERHEIT-RLS-CHECK.md` durchgehen.
3. Oberfläche an Supabase anbinden (Login wie in der Abwesenheiten-App, Lesen per REST, Schreiben per RPC).
4. Saldo und Monatsabschluss-Snapshot serverseitig berechnen (eigene Funktion bzw. View), damit die Werte für die Lohnverrechnung nicht vom Browser kommen.
5. Export für die Lohnverrechnung im gewünschten Format (z. B. BMD/RZL-CSV) ergänzen.

## 5. Offene Fragen an dich

1. **Vorgesetzte:** Gibt es neben dir eine Salonleitung, die Urlaub genehmigen soll? Dafür muss eine bestehende Policy von `abw_anfragen` erweitert werden (im SQL auskommentiert vorbereitet).
2. **Arbeitszeitmodelle:** Welche Modelle gibt es wirklich (Tage, Stunden, Schließtage Sonntag + Montag)? Gibt es eine Durchrechnung bzw. Gleitzeit laut KV oder Betriebsvereinbarung?
3. **Überstunden:** Auszahlung oder Zeitausgleich? Ab wann zählen sie (täglich über 8 h oder erst über die Wochenstunden)?
4. **Lehrlinge:** ~~Berufsschule~~ geklärt (Wien: 1. Lj. 1,5 Tage, 2./3. Lj. 1 Tag pro Woche). Offen: Welche Wochentage? Und sind die Lehrlinge unter 18 (strengere KJBG-Regeln)?
5. **Krankenstand mit offenem Ende:** In `abw_anfragen` ist `bis` heute Pflicht. Offenes Ende erlauben (dann muss die Abwesenheiten-App damit umgehen) oder „voraussichtliches Ende“ eintragen?
6. **Datenschutz im Kalender:** Die Abwesenheiten-App zeigt allen genehmigte Einträge inkl. Art. Sollen Kolleg/innen „Krankenstand“ weiterhin sehen oder nur „abwesend“ (so macht es der Prototyp)?
7. **Stempeln wo:** Am eigenen Handy, oder an einem Salon-Tablet? Beim Tablet braucht es einen anderen Login (z. B. PIN pro Person mit Server-Prüfung).
