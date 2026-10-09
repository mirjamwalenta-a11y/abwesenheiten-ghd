# Zeitverwaltung · Great Hair Day

Zentrale Anwendung für **Arbeitszeit, Urlaub und Krankenstand/Abwesenheiten**.
Stand: Prototyp (Oberfläche fertig, Datenbank als Entwurf).

| Datei | Inhalt |
|---|---|
| `zeitverwaltung.html` | Oberfläche, läuft mit erfundenen Demo-Daten nur im Browser |
| `zeitverwaltung_schema_entwurf.sql` | Datenbankstruktur inkl. RLS – **noch nicht live ausgeführt** |
| `abwesenheiten.html` | bestehende Abwesenheiten-App (bleibt unverändert in Betrieb) |

## 1. Was der Prototyp kann

Design wie die anderen Great-Hair-Day-Apps (index/Schaltzentrale): Poppins, Creme-Hintergrund, Gold-Akzent #896C32, runde Pill-Buttons, Stempeluhr als goldene Karte.

Navigation: **Dashboard → Zeiterfassung → Urlaub → Krankenstand → Mitarbeiter → Kalender → Auswertungen → Einstellungen**

- **Stempeln** – am eigenen Handy (Stempeluhr im Dashboard) oder am **Stempel-Tablet im Salon**: Name antippen → Kommen / Pause / Gehen. Hat jemand das Kommen vergessen, gibt es „Gehen (Kommen vergessen)“ – der Beginn kommt aus dem Dienstplan.
- **Fixer Dienstplan & Automatik** – Dienstplan mit Beginn, Ende und Pause je Wochentag. Vergessenes Gehen, fehlende Pausen und ganz vergessene Tage werden automatisch laut Plan ergänzt (live: jede Nacht per Server-Job). Alles Automatische ist mit „auto“ markiert, steht im Protokoll und wird beim Monatsabschluss geprüft. Überstunden lassen sich abschalten; längere Tage erscheinen dann als Hinweis.
- **Bearbeiten durch die Leitung** – Dienstplan & Pausen (mit „gültig ab“, vergangene Tage behalten den alten Plan; auch eigener Plan pro Person), einzelne Tage (Zeiten, Pause), vergessenen Urlaub oder Krankenstand nachtragen (🌴 in der Zeiterfassung) und bestehende Einträge bearbeiten. Automatisch ergänzte Arbeitstage werden dabei ersetzt.
- **Monatsabschluss & Download** – unter *Auswertungen*: alle abschließen, **Excel** (Übersicht, Arbeitszeiten pro Tag, Abwesenheiten, Änderungsprotokoll) und **Arbeitszeitnachweise als PDF** (eine Seite pro Person mit Unterschriftszeilen).
- **Jahresabschluss für den Steuerberater** – Auswertungen → Jahr: „Beschäftigungsstand (wie bisher)“ im gewohnten Aufbau (Name + Eintritt bzw. von–bis, AT ohne UT, UT, Resttage, Krankenstandstage als Datumsliste) sowie ausführliches Excel (Mitarbeiterstand mit Ein-/Austritten, Urlaub mit **offenen Tagen am 31.12.** für die Rückstellung, Krankenstände mit allen Fällen, Arbeitsunfall, Pflegefreistellung, Arztbesuche, Zeitkonto) und PDF. Im Jahr Ausgetretene stehen mit dem Stand zum letzten Arbeitstag drin (Urlaubsersatzleistung). Erinnerung am Dashboard ab 15.12.
- **Mitarbeiter verwalten** – anlegen, bearbeiten, **Austritt eintragen** (letzter Arbeitstag, Art der Beendigung, Notiz) mit Richtwerten für die Endabrechnung (aliquoter Urlaub, Zeitkonto). Nach dem letzten Arbeitstag ist kein Login mehr möglich, alle Daten bleiben erhalten. Jede Änderung steht im **Verlauf** der Person (wer, wann, was).
- **Bestätigungen hochladen** – bei Krankenstand, Arbeitsunfall, Pflegefreistellung und Arztbesuch Foto oder PDF anhängen (auch von Mitarbeiter/innen selbst am Handy; Fotos werden verkleinert). Im Jahresabschluss als ZIP je Person mit Übersicht – fehlende Bestätigungen werden gemeldet. Live: privater Storage-Bucket, lesbar nur für die Person und die Leitung.
- **Import** – Mitarbeiter → „Import“ liest die bisherige Excel-Liste „Beschäftigungsstand“ (Name, Eintritt bzw. von–bis, UT, Resttage) mit Vorschau ein; Resttage einer Vorjahresliste werden Resturlaub. Die Datei wird nur im Browser gelesen.
- **Testen mit eigenen Mitarbeitern** – Login-Seite „Mit meinen eigenen Mitarbeitern testen“ startet leer; „Testdaten sichern/laden“ (Einstellungen) nimmt die Daten auf ein anderes Gerät mit. Alles bleibt im Browser, bis die Datenbank angebunden ist.
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
| Fixe Arbeitszeit | § 26 AZG: Dienstplan schriftlich festhalten, Einhaltung monatlich bestätigen, nur Abweichungen aufzeichnen; automatische Pausen nur mit schriftlicher Pausen-Vereinbarung | Dienstplan je Wochentag, Automatik mit Kennzeichen „auto“, Bestätigung beim Monatsabschluss |
| Jugendliche (Lehrlinge unter 18) | KJBG: Pause ab 4,5 h, 8 h/Tag (9 h bei Verteilung), 40 h/Woche, 12 h Ruhezeit, Nachtruhe 20–6 Uhr | strengere Prüfung, gesteuert über das Geburtsdatum – ab dem 18. Geburtstag automatisch AZG |
| Überstunden / Mehrarbeit | § 10 AZG 50 %, § 19d AZG 25 % bei Teilzeit | Mehrarbeit und Überstunden getrennt ausgewiesen (vereinfacht pro Woche) |
| Urlaub | § 2 UrlG: 25 Arbeitstage (5-Tage-Woche), ab 25 Dienstjahren 30; Urlaubsjahr = Arbeitsjahr, in den ersten 6 Monaten anteilig | Urlaubsjahr ab Eintrittsdatum, Rest wird übertragen; Feiertage zählen nicht |
| Verjährung Urlaub | § 4 Abs 5 UrlG | Hinweis im Urlaubskonto |
| Krankenstand | Entgeltfortzahlung 6 / 8 / 10 / 12 Wochen nach Dienstjahren | Anspruch je Person angezeigt |
| Pflegefreistellung | § 16 UrlG: bis 1 Woche pro Arbeitsjahr | eigene Abwesenheitsart |
| Feiertage | 13 gesetzliche Feiertage | automatisch berechnet (inkl. Ostern) |
| Aufbewahrung | u. a. § 132 BAO (7 Jahre) | Ausgetretene werden deaktiviert, nicht gelöscht |

**Wichtig:** Der Kollektivvertrag für das Friseurgewerbe kann abweichende Werte vorsehen (Normalarbeitszeit, Durchrechnung, Zuschläge, Samstagsarbeit, Arbeitszeit von Lehrlingen). Alle Grenzwerte sind deshalb unter *Einstellungen* änderbar. Bitte die Werte einmal mit der Lohnverrechnung bzw. der WKO abstimmen – die App ersetzt keine Rechtsberatung.

## 3. Datenbankstruktur (Entwurf)

Grundidee: **eine** Personenliste für alle Apps. Personen bleiben in `abw_team`, Urlaub und Krankenstand bleiben in `abw_anfragen` – die bestehende Abwesenheiten-App läuft also unverändert weiter.

```
abw_team (bestehend)  ── 1:1 ── zeit_profil            Personalnr, Abteilung, Vorgesetzte/r, Geburtsdatum, Lehrbeginn, Schultage
     │                ── 1:n ── zeit_modell_zuordnung  Modell „gültig ab“ ── zeit_arbeitsmodelle ── zeit_modell_tage (Beginn/Ende/Pause je Wochentag)
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
  - `zeit_stempeln(aktion)` – Uhrzeit vom Server (Europe/Vienna), nicht vom Handy; inkl. „Kommen vergessen“ und automatischer Pause
  - `zeit_automatik()` – nächtlicher Job (pg_cron), nur für den Server ausführbar
  - `zeit_buchung_aendern(...)` – nur Leitung, Grund ist Pflicht, schreibt ins Protokoll
  - `zeit_korrektur_entscheiden(id, ja/nein)`
  - `zeit_monat_bestaetigen`, `zeit_monat_abschliessen`, `zeit_monat_oeffnen` (nur Admin)
- Ein Trigger sperrt abgeschlossene Monate zusätzlich.

Das Skript wurde lokal gegen eine nachgebaute Supabase-Umgebung getestet (zweimal hintereinander ausführbar). Geprüft wurde unter anderem: anon sieht nichts, Mitarbeiter sehen nur sich selbst und können nicht direkt schreiben, Vorgesetzte ändern nur ihr Team (nicht sich selbst), abgeschlossene Monate sind gesperrt, nur die Chefin öffnet wieder.

## 4. Stempeln: Handy und Tablet

Beide Wege laufen parallel und schreiben in dieselben Arbeitszeiten. Jede Person hat **eine** PIN – dieselbe wie in der Abwesenheiten-App.

**Handy** – Person wählt sich aus, gibt die PIN ein (Supabase-Login wie in der Abwesenheiten-App), die Anmeldung bleibt gespeichert. Gestempelt wird über `zeit_stempeln()`; die Person kann nur für sich selbst stempeln.

**Tablet im Salon** – einmalig einrichten:
1. In Supabase unter *Authentication → Users* einen eigenen Zugang für das Tablet anlegen (z. B. „terminal.salon@…“ mit langem Passwort, das nur die Chefin kennt).
2. Das Tablet per SQL freischalten: `INSERT INTO zeit_terminals (user_id, name) SELECT id, 'Tablet Empfang' FROM auth.users WHERE email = '…';`
3. Am Tablet einmal mit diesem Zugang anmelden und die Seite auf den Startbildschirm legen; die Anmeldung bleibt gespeichert.

Am Tablet: Name antippen → PIN → Kommen / Pause / Gehen. Der Server prüft die PIN gegen den Login (`zeit_terminal_stempeln`), die PIN wird nirgends gespeichert. Nach 5 falschen PINs ist die Person 15 Minuten gesperrt. Das Tablet sieht nur Vornamen und den heutigen Stempel-Status, sonst keine Daten. Ein Mitarbeiter-Handy kann die Tablet-Funktion nicht nutzen, also nicht für andere stempeln. Ein verlorenes Tablet sperrst du mit `UPDATE zeit_terminals SET aktiv = false …`.

**Wo darf gestempelt werden?** – Einstellung *Einstellungen → Stempeln – wo ist es erlaubt?*:

| Modus | Handy | Tablet |
|---|---|---|
| **Nur am Salon-Tablet** (Standard, empfohlen) | sieht Zeiten, kann nicht stempeln | stempelt |
| **Tablet + Handy im Salon** | nur im Salon-WLAN | stempelt |
| **Überall** | ohne Einschränkung | stempelt |

Live entscheidet das der Server in `zeit_stempeln()` (Tabelle `zeit_stempel_regel`), die App blendet nur die Knöpfe aus. Für „Handy im Salon“ tippt die Chefin einmal **im Salon, im Salon-WLAN** auf „Salon-WLAN merken“ (`zeit_salon_netz_merken()`); gespeichert wird die öffentliche IP des Salon-Internetanschlusses in `zeit_salon_netze`. Wechselt der Anbieter die IP, im Salon nochmal tippen. Vertraut wird nur dem Header `cf-connecting-ip` (setzt die Supabase-Edge), nicht dem vom Client fälschbaren `X-Forwarded-For`; fehlt er, wird abgelehnt. **Vor Go-live testen:** Stempeln mit Handy-Daten (nicht WLAN) und mit gefälschtem `X-Forwarded-For` muss scheitern. Die GPS-Prüfung im Prototyp ist nur eine Vorschau – ein Handy-Standort lässt sich fälschen.

**Wie TimeMoto eingestellt** (Einstellungen → Automatik):
- *Automatisch ausstempeln* 15 Minuten nach Dienstende laut Plan.
- *Auf Dienstplan runden*: Stempelung 30 min vor bis 5 min nach Plan-Beginn zählt ab Plan-Beginn (wer früher kommt, um pünktlich arbeitsbereit zu sein); 5 min vor bis 15 min nach Plan-Ende zählt bis Plan-Ende. Die echte Stempelzeit bleibt gespeichert (`beginn_roh`/`ende_roh`) und steht im Zeitbericht. Muss jemand tatsächlich früher arbeiten, ist das Arbeitszeit → als Korrektur eintragen.
- *Fixe Pausenzeit je Person*: im Dienstplan „Pause ab“ (z. B. 11:30 → 11:30–12:30); bei unterschiedlichen Pausen je Person „Eigener Plan für diese Person“. Automatisch abgezogen wird die Pause erst, wenn die schriftliche Pausen-Vereinbarung vorliegt (§ 26 Abs 5 AZG).

**Außentermine** (z. B. Hochzeit): Die Chefin gibt unter *Einstellungen → Stempeln* für eine Person und einen Tag das Handy-Stempeln frei – an diesem Tag geht es überall, alle anderen Tage bleiben wie eingestellt. Live: Tabelle `zeit_aussentermine` (RLS: eintragen/löschen nur die Chefin), geprüft in `zeit_handy_stempeln_erlaubt()`. Freigabe und Entfernen stehen im Protokoll.

**Vergessen ein- oder auszustempeln:** Am Dashboard („Heute im Salon“) hat jede Person ✎ (Anwesenheit/Zeiten nachtragen) und 🌴 (Abwesenheit eintragen, z. B. krank). Für frühere Tage: *Zeiterfassung* → Person → Tag. Ein nachgetragener Krankenstand ersetzt automatisch ergänzte Arbeitstage. Alles wird mit Grund protokolliert.

**Automatisch ausstempeln beim Verlassen des Salons** ist bewusst nicht eingebaut: Eine Web-App kann den Standort im Hintergrund nicht verfolgen (dafür bräuchte es eine eigene Handy-App mit dauerhafter Ortung), und laufende Standortüberwachung ist eine Kontrollmaßnahme, die in Österreich die schriftliche Zustimmung jeder Person braucht (§ 10 AVRAG, ohne Betriebsrat) und datenschutzrechtlich heikel ist. Stattdessen: **automatisch ausstempeln** wie bei TimeMoto – wer vergisst zu gehen, bekommt noch am selben Abend das Dienstende laut Plan eingetragen (Standard: 60 Minuten nach Dienstende, einstellbar unter *Einstellungen → Automatik*). Live erledigt das der Server-Job `zeit_automatik` alle 15 Minuten (pg_cron, siehe SQL-Entwurf); nachts läuft er zusätzlich für den Vortag.

## 4a. Einfache Ansicht für Mitarbeiter/innen

Mitarbeiter/innen (Rolle „Mitarbeiter/in“) sehen nur drei Reiter – wie im bisherigen System: **Heute** (Stempeluhr, Plan, Urlaubstage), **Meine Zeiten** (Monatsliste Hinein/Hinaus/Stunden, Tag antippen = Änderung beantragen, Monat bestätigen) und **Urlaub & Krank** (beantragen, krank melden, „Du hast noch … UT“). Chefin und Salonleitung behalten die volle Ansicht.

## 4b. Urlaub: Sperre je Gruppe und Nachrichten

- **Urlaubssperre:** Aus jeder Gruppe (Stylist/innen, Lehrlinge, Rezeption, Assistenz) darf gleichzeitig nur eine Person Urlaub haben – beantragt oder genehmigt. Die Gruppe steht im Profil („Automatisch“ erkennt Stylist/innen und Lehrlinge an der Funktion). Die Chefin kann trotzdem eintragen. Einstellung: *Einstellungen → Urlaub*. Live: Trigger `zeit_urlaub_sperre` auf `abw_anfragen` (wirkt auch in der Abwesenheiten-App – vorher abstimmen).
- **Nachrichten (🔔):** Neuer Antrag → Nachricht an die Chefin (und ggf. Salonleitung); Genehmigung/Ablehnung → Nachricht an die Person. Live: Tabelle `zeit_nachrichten` (RLS: nur Empfänger/in liest), E-Mail zusätzlich über Database Webhook + Edge Function, Adresse als Secret.
- **Mein Urlaub & Krankenstand** (Dashboard der Mitarbeiter/innen): „Du hast noch 19 UT. Denk daran: Bei deinem nächsten genehmigten Urlaub werden noch 4 UT abgezogen – danach bleiben dir 15 UT.“ plus Liste der genehmigten/genommenen Urlaube und Krankenstände.

- **Berufsschule & Schulferien Wien:** Der Berufsschul-Planer lässt die Wiener Schulferien automatisch aus (Herbst 26.10.–2.11., 15.11. Leopold, Weihnachten 24.12.–6.1., Semester ab 1. Montag im Februar, Ostern Sa vor Palmsonntag bis Ostermontag, Pfingsten Sa–Mo, Sommer ab Samstag 28.6.–4.7. bis vor dem 1. Montag im September) – jedes Jahr neu berechnet. Schulautonome Tage einzeln stornieren. An Berufsschultagen ist kein Urlaub möglich.

## 4c. Schritt 2 – Datenbank einrichten (Supabase)

Zwei Skripte in `supabase/` (erzeugt aus `zeitverwaltung_schema_entwurf.sql`, der Entwurf bleibt die Quelle):

1. **`zeitverwaltung_schritt2_teilA.sql`** – alle `zeit_*`-Tabellen und -Funktionen. Ändert nichts am Verhalten der Abwesenheiten-App. Prüft vorab das Projekt (abw_team.id = text, ausgeschieden_am, abw_is_owner …) und bricht sonst ohne Änderung ab. Am Ende eine Kontrolltabelle: jede `zeit_*`-Tabelle muss `rls = true` haben.
2. **`zeitverwaltung_schritt2_teilB.sql`** – Urlaubssperre und Nachrichten (Trigger auf `abw_anfragen`, wirkt auch in der Abwesenheiten-App). Erst nach Teil A.

Beide laufen als eine Transaktion (Fehler → nichts geändert) und sind mehrfach ausführbar. Ausführen: Supabase → SQL Editor → New query → Inhalt einfügen → Run.

Sicherheits-Check (CLAUDE.md): jede neue Tabelle mit RLS; keine anon-Policy; Tabellen ohne Policy nur über SECURITY-DEFINER-Funktionen; Rollenprüfung ausschließlich serverseitig (`abw_is_owner()`, `zeit_darf_verwalten()`); keine Zugangsdaten oder E-Mail-Adressen im SQL. `SICHERHEIT-RLS-CHECK.md` war in den verfügbaren Repos nicht vorhanden – die Punkte wurden anhand der CLAUDE.md-Regeln geprüft.

## 4d. Schritt 3 – echter Betrieb

**Adresse:** `zeitverwaltung.html` = echter Betrieb mit der gemeinsamen Datenbank. `zeitverwaltung.html?test` = Testversion mit Beispieldaten (nur im Browser).

**Anmeldung** wie in der Abwesenheiten-App: Name antippen → PIN (Supabase Auth, Passwort = PIN + „-ghd“). Wer in der Abwesenheiten-App am selben Gerät angemeldet ist, ist es auch hier (gleiche Sitzung).

**Wer darf was** – geprüft am Server, nicht in der App:

| Wer | Sieht | Darf |
|---|---|---|
| Mitarbeiter/in | eigene Zeiten, eigenes Profil, eigene + genehmigte Abwesenheiten | stempeln (`zeit_stempeln`), Urlaub/Krank beantragen (Status „ausstehend“), Änderung beantragen, Monat bestätigen |
| Chefin (`role = owner`) | alles | Zeiten ändern (`zeit_buchung_aendern`, mit Grund), genehmigen, Dienstpläne, Profile, Einstellungen, Monatsabschluss |
| Stempel-Tablet (`zeit_terminals`) | Vornamen + heutiger Status | stempeln mit PIN (`zeit_terminal_stempeln`) |

**Wie die App speichert:** Jede Änderung in der Oberfläche wird in die erlaubten Schreibwege übersetzt (`liveSpeichern`) – Tabellen mit RLS oder SECURITY-DEFINER-Funktionen – und danach neu geladen; Daten anderer Geräte holt die App jede Minute. Neue Personen und Namensänderungen nur in der Abwesenheiten-App (Name = Login). Einstellungen liegen als ein Datensatz in `abw_einstellungen` (`zeitverwaltung`), Server-Funktionen lesen sie über `zeit_einst()`.

**Automatik** (vergessenes Gehen, ganz vergessene Tage, Pausen mit Vereinbarung): pg_cron-Job `zeit-automatik` alle 15 Minuten, erst ab `kontoStart` (wird bei der ersten Anmeldung der Chefin gesetzt).

**Noch nicht im echten Betrieb:** Hochladen von Bestätigungen (vorerst auf Papier), Excel-Import legt keine Personen an (aktualisiert nur Eintritt/UT/offenen Urlaub).

**Getestet** gegen PostgREST 12 + Postgres 16 mit nachgebildetem Supabase-Auth: Login/PIN, Ersteinrichtung, Profile/Dienstpläne mit fixer Pause, Einstellungen, Stempeln mit Rundung, Urlaubsantrag + Sperre, Genehmigung + Nachrichten, Korrektur, Korrekturantrag, Krankmeldung, Berufsschul-Planung, Außentermin, Startbestand, Tablet mit PIN-Sperre; 12 direkte Angriffe über die REST-Schnittstelle (fremde Daten lesen/ändern, Einstellungen, Nachrichten, Automatik …) werden abgewiesen.

### Einrichten (Chefin)
1. Supabase → Database → Extensions → **pg_cron** aktivieren.
2. SQL Editor → `supabase/zeitverwaltung_schritt3_teilC.sql` ausführen (Kontrolle am Ende: alle `rls = true`, Automatik-Job eingerichtet).
3. `zeitverwaltung.html` öffnen, als Chefin anmelden → Standard-Dienstpläne werden angelegt und allen zugeordnet, Start = heute.
4. Mitarbeiter → Import (Beschäftigungsstand) oder je Person: Eintritt, offener Urlaub, Funktion; eigene Pausenzeit über „Eigener Plan für diese Person“.
5. Stempel-Tablet: Supabase → Authentication → Add user (eigene Tablet-Adresse, langes Passwort, „Auto Confirm“), dann im SQL Editor
   `INSERT INTO zeit_terminals (user_id, name) SELECT id, 'Tablet Empfang' FROM auth.users WHERE email = '<Tablet-Adresse>';`
   Am Tablet: „Dieses Gerät als Stempel-Tablet einrichten“.

## 4e. Eine App für die Mitarbeiter/innen, Start im Jänner

- **Abwesenheiten-App → „⏱ Zeit“** (untere Leiste) öffnet die Zeitverwaltung – ohne neue Anmeldung (gleiche Sitzung). Zurück über 🌴 („Abwesenheiten-App“), ebenfalls ohne PIN (`abwesenheiten.html?zurueck=1`).
- Den Knopf sieht die **Chefin immer**, alle anderen **erst ab dem Starttag** – oder vorher, wenn „Mitarbeiter/innen dürfen schon vorher testen“ an ist (*Zeitverwaltung → Einstellungen → Start der Zeitverwaltung*). Wer vorher direkt hineingeht, sieht „Die neue Zeiterfassung startet am …“.
- **Starttag** (`kontoStart`): ab dann zählen Zeitkonto und Automatik. Ohne Starttag trägt die Automatik nichts ein.
- **Testdaten löschen** (`zeit_testdaten_loeschen`, Teil D): löscht alle Arbeitszeiten, Korrekturen, Monatsabschlüsse und Protokolle – nur durch die Chefin und nur vor dem Starttag. Dienstpläne, Profile und Urlaube bleiben.

## 5. Nächste Schritte

1. Offene Fragen unten klären, Schema anpassen.
2. Schema im Supabase-Projekt ausführen, vorher `SICHERHEIT-RLS-CHECK.md` durchgehen.
3. Oberfläche an Supabase anbinden (Login wie in der Abwesenheiten-App, Lesen per REST, Schreiben per RPC).
4. Saldo und Monatsabschluss-Snapshot serverseitig berechnen (eigene Funktion bzw. View), damit die Werte für die Lohnverrechnung nicht vom Browser kommen.
5. Export für die Lohnverrechnung im gewünschten Format (z. B. BMD/RZL-CSV) ergänzen.

## 6. Offene Fragen an dich

- **Ausgetretene im Beschäftigungsstand:** geklärt – offene Tage mit „(Ersatzleistung)“, nicht „UT 0“.

- **Urlaubsjahr:** geklärt – **Arbeitsjahr ab dem Eintrittsdatum** (neuer Anspruch am Jahrestag, Rest wird übertragen). Im ersten Halbjahr und bei Austritt anteilig nach Tagen. Beim Umstieg je Person ein Startbestand „offener Urlaub am Stichtag“. Der Jahresabschluss zeigt die offenen Tage am 31.12. im jeweils laufenden Urlaubsjahr.

1. **Vorgesetzte:** Gibt es neben dir eine Salonleitung, die Urlaub genehmigen soll? Dafür muss eine bestehende Policy von `abw_anfragen` erweitert werden (im SQL auskommentiert vorbereitet).
2. **Dienstpläne:** geklärt – fixer Plan, keine Überstunden. Öffnungszeiten: So + Mo geschlossen, Di + Mi 9–18, Do + Fr 9–19, Sa 8–14, Di–Fr je 1 h Pause (= 40 h). Derzeit keine Teilzeit; eigene Pläne pro Person sind möglich.
3. **Pausen-Vereinbarung:** Es gibt nur den Kollektivvertrag, keinen eigenen Dienstvertrag. Daher ist die automatische Pause vorerst **aus** (Einstellung „Schriftliche Pausen-Vereinbarung liegt vor“); Pausen werden gestempelt. Mit einer kurzen schriftlichen Pausen-Vereinbarung je Person (§ 26 Abs 5 AZG) kann sie eingeschaltet werden. Dienstzettel liegt vor. Vorlage für die Pausen-Vereinbarung: 30 min fix eingeteilt + 30 min frei innerhalb eines Zeitfensters (Di–Fr) – nach Unterschrift den Schalter in den Einstellungen setzen.
4. **Lehrlinge:** geklärt – Wien 1. Lj. 1,5 Tage, 2./3. Lj. 1 Tag; Schultage fix je Lehrling; unter/über 18 automatisch über das Geburtsdatum.
5. **Krankenstand mit offenem Ende:** In `abw_anfragen` ist `bis` heute Pflicht. Offenes Ende erlauben (dann muss die Abwesenheiten-App damit umgehen) oder „voraussichtliches Ende“ eintragen?
6. **Kalender:** geklärt – alle sehen den Grund (Urlaub, Krankenstand, Arztbesuch); das ist im Team bekannt. Neue Art „Arztbesuch“ in Stunden.
7. **Stempeln wo:** geklärt – Handy und Tablet (siehe Abschnitt 4).
