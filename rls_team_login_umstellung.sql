-- ════════════════════════════════════════════════════════════
--  Abwesenheiten: Umstellung auf den gemeinsamen Team-Login
--
--  Bisher meldete sich jede Person über einen eigenen Namen+PIN-Login an
--  (synthetische E-Mail <name>.abwesenheit@greathairday.at). Das Frontend
--  (abwesenheiten.html) wurde umgestellt auf denselben Login wie team.html /
--  Mitarbeiterhandbuch_App.html / salon-checklist.html: echte E-Mail +
--  Passwort gegen dieselbe Tabelle teamapp_persons, inkl. automatischer
--  Anmeldung, falls im selben Browser schon eine Team-Sitzung besteht.
--
--  Diese Migration zieht die serverseitige Identitätsprüfung nach:
--  abw_is_owner() und abw_current_person_id() prüften bisher die Rolle in
--  abw_team über die alte synthetische E-Mail. Jetzt wird die Rolle aus
--  teamapp_persons gelesen (dieselbe Quelle wie im ganzen Team-Bereich) und
--  die abw_team-Zeile über den Namen zugeordnet (abw_team bleibt die
--  fachliche Tabelle für Urlaubsstände — nur die Anmeldung ändert sich).
--
--  VORAUSSETZUNG: Die Funktion public.teamapp_ist_inhaberin() muss bereits
--  existieren — sie liegt in der Migration
--  20260912120000_rls_rollenbasiert_team_handbuch_checkliste.sql im Repo
--  `Team` (gleiches Supabase-Projekt wrxlaltgtgkdomklgrlj). Diese Datei hier
--  erst NACH jener Migration einspielen.
--
--  WICHTIG: Der Namensabgleich (lower(trim(...))) setzt voraus, dass der
--  Name einer Person in abw_team exakt gleich geschrieben ist wie in
--  teamapp_persons (z.B. "Alina" in beiden, nicht "Alina" vs. "Alina M.").
--  Vor dem Einspielen einmal gegenprüfen:
--    select at.name as abw_team, tp.name as teamapp_persons, tp.email
--    from abw_team at
--    left join teamapp_persons tp on lower(trim(tp.name)) = lower(trim(at.name));
--  Zeilen mit NULL in teamapp_persons/email haben (noch) keinen passenden
--  Team-Login-Account — für diese Personen bleibt der Login in
--  Abwesenheiten bis zur Korrektur des Namens gesperrt.
--
--  Sicher mehrfach ausführbar (CREATE OR REPLACE).
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION abw_current_person_id() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT at.id FROM abw_team at
  JOIN teamapp_persons tp ON lower(trim(tp.name)) = lower(trim(at.name))
  WHERE tp.email = auth.jwt() ->> 'email' AND tp.aktiv = true
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION abw_is_owner() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.teamapp_ist_inhaberin();
$$;

-- Kein Schema-Wechsel nötig: abw_team, abw_anfragen, abw_einstellungen und
-- ihre bestehenden Policies (rls_haertung_abwesenheit.sql,
-- rls_haertung_abw_team_spalten.sql) bleiben unverändert — sie rufen bereits
-- abw_is_owner()/abw_current_person_id() auf und übernehmen die neue Logik
-- automatisch. Die pin-Spalte in abw_team wird durch diese Umstellung
-- funktionslos (nicht mehr Teil des Logins), bewusst NICHT entfernt.
