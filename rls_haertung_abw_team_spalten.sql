-- ════════════════════════════════════════════════════════════
--  A Great Hair Day · Abwesenheiten
--  Restlücke abw_team: maskierende View für fremde Spalten
--  Im Supabase SQL-Editor ausführen. Sicher mehrfach ausführbar
--  (CREATE OR REPLACE VIEW).
--
--  Setzt voraus, dass rls_haertung_abwesenheit.sql bereits ausgeführt wurde
--  (abw_team RLS aktiv, pin per REVOKE gesperrt, Funktionen abw_is_owner()/
--  abw_current_person_id() vorhanden). Die beiden Funktionen werden hier
--  zur Sicherheit trotzdem erneut angelegt (CREATE OR REPLACE, identisch
--  zur anderen Datei) — falls diese Datei isoliert ausgeführt wird.
--
--  Hintergrund: RLS filtert nur ganze Zeilen. Name/Rolle aller Personen
--  müssen für den Team-Kalender für alle sichtbar bleiben, aber
--  Urlaubsanspruch/verbraucht/Eintrittsdatum sind bei FREMDEN Zeilen
--  Chefin-Sache. Das lässt sich nicht per RLS ausdrücken (RLS kennt keine
--  Spalten-Ebene) — deshalb eine View, die diese drei Spalten pro Zeile
--  auf NULL setzt, wenn es weder die eigene Zeile noch die Chefin ist.
-- ════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION abw_current_person_id() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM abw_team
  WHERE lower(replace(trim(name), ' ', '.')) || '.abwesenheit@greathairday.at' = auth.jwt() ->> 'email'
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION abw_is_owner() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM abw_team
    WHERE role = 'owner'
      AND lower(replace(trim(name), ' ', '.')) || '.abwesenheit@greathairday.at' = auth.jwt() ->> 'email'
  );
$$;

-- Absichtlich OHNE pin-Spalte (die bleibt ohnehin per REVOKE gesperrt und wird
-- im Frontend nirgends gelesen). id/name/role bleiben für alle sichtbar (Team-
-- Kalender), die drei sensiblen Spalten nur für die eigene Zeile oder die Chefin.
CREATE OR REPLACE VIEW abw_team_scoped
WITH (security_invoker = true) AS
SELECT
  id,
  name,
  role,
  CASE WHEN abw_is_owner() OR id = abw_current_person_id() THEN urlaub_anspruch END AS urlaub_anspruch,
  CASE WHEN abw_is_owner() OR id = abw_current_person_id() THEN urlaub_verbraucht END AS urlaub_verbraucht,
  CASE WHEN abw_is_owner() OR id = abw_current_person_id() THEN eintrittsdatum END AS eintrittsdatum
FROM abw_team;

REVOKE ALL ON abw_team_scoped FROM PUBLIC, anon;
GRANT SELECT ON abw_team_scoped TO authenticated;
