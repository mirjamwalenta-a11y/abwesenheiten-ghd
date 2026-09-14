# Sicherheitsregeln für dieses Projekt

Diese Regeln gelten für jede Änderung an Code oder Datenbank-Schema in
diesem und den verwandten greathairday-Repos (gemeinsames Supabase-Projekt
`wrxlaltgtgkdomklgrlj`). Sie existieren, weil am 2026-09-14 mehrere reale
Lücken gefunden wurden, die durch diese Regeln verhindert worden wären:
`salon_personen` ohne RLS (komplette Mitarbeiter-PINs öffentlich lesbar
über den anon-Key), ein Auth-Bypass über eine erratbare Session-ID
(`id:'salon-chef'`), und die private E-Mail der Inhaberin hartcodiert in
vier Dateien über drei Repos.

**Diese Regeln gelten für jede Änderung, nicht nur für "Sicherheits-Tasks".**
Eine neue Tabelle, ein neuer Login-Weg, ein neues Admin-Feature — bei
jedem davon gilt die Checkliste unten, auch wenn die eigentliche Aufgabe
etwas anderes war.

## Verbindlich vor jedem Merge/Deploy

1. **Jede neue Supabase-Tabelle bekommt RLS, bevor sie mit einer Live-App
   verbunden wird.** `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` gehört
   zum "Tabelle anlegen"-Schritt, nicht zu einem späteren Review. Unsicher,
   welche Policy richtig ist? Erstmal keine anon-Policy anlegen (RLS ohne
   Policy verweigert per Default für alle) und explizit nachfragen statt
   zu raten.

2. **Nie Zugangsdaten, private E-Mail-Adressen oder andere persönliche
   Daten im Klartext in Code, Kommentaren oder Dokumentation.** Auch nicht
   als "Convenience"-Vorbefüllung in einem Input-Feld (`value="..."`) —
   das ist im öffentlichen Quelltext genauso sichtbar wie im Code selbst,
   ganz ohne Login.

3. **Rollenprüfungen (wer ist Chefin/Admin) müssen serverseitig
   durchgesetzt werden** (RLS, SECURITY DEFINER-Funktion, Edge Function)
   — nie nur durch eine clientseitige JS-Prüfung wie
   `if (email === 'x@y.at')` oder `if (!istChefin()) return`. Die
   Client-Prüfung darf UI ein-/ausblenden, sie ist aber niemals die
   eigentliche Absicherung.

4. **Sessions/"Angemeldet bleiben" dürfen nie auf einer erratbaren oder
   vom Client frei setzbaren ID beruhen.** Ein zufälliges, ablaufendes
   Token ist der Mindeststandard (siehe `salon_sessions`-Muster in
   `supabase/migrations/20260914130000_p0_salon_personen_session_token.sql`).

5. **Vor jedem Merge, der eine neue Tabelle oder einen neuen Login-Weg
   einführt:** kurz `SICHERHEIT-RLS-CHECK.md` in diesem Repo durchgehen.

## Automatische Prüfung

`.github/workflows/rls-audit.yml` prüft wöchentlich automatisch alle
Tabellen im Supabase-Projekt auf fehlende RLS und legt bei einem Fund ein
GitHub-Issue an (Setup: `SUPABASE_DB_URL`-Secret, siehe
`SICHERHEIT-RLS-CHECK.md`). Das ersetzt keine der obigen Regeln, ist aber
das Sicherheitsnetz für den Fall, dass eine davon trotzdem übersehen wird.

## Historie der Funde (2026-09-14)

- `salon_personen`: keine RLS → live behoben, siehe
  `supabase/migrations/20260914120000_p0_salon_personen_rls.sql`
- Session-Reload vertraute der Personen-`id` ohne PIN-Prüfung → behoben,
  siehe `20260914130000_p0_salon_personen_session_token.sql` +
  Code-Fix in `index.greathairday`
- Private E-Mail hartcodiert in `salon-checklist.html` und drei Stellen
  in `lernquiz.greathairday` → entfernt, rollenbasiert ersetzt
