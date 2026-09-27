-- ════════════════════════════════════════════════════════════
--  A Great Hair Day · Abwesenheiten
--  Ausgeschiedene Mitarbeitende: markieren statt löschen
--  Im Supabase SQL-Editor ausführen. Sicher mehrfach ausführbar.
--  Setzt rls_haertung_abwesenheit.sql, rls_haertung_abw_team_spalten.sql
--  und fix_abw_team_login_anon.sql voraus.
--
--  Hintergrund: Wer Anfragen (Urlaub, Krankenstand) hat, lässt sich
--  nicht löschen — die Anfragen verweisen auf die Person. Und die
--  Inhaberin braucht diese Anfragen ohnehin noch (Jahreskontrolle).
--  Stattdessen bekommt die Person ein Datum „ausgeschieden_am“:
--    * sie verschwindet aus der Login-Auswahl (abw_team_login)
--    * abw_current_person_id() erkennt sie nicht mehr — damit kann
--      sie serverseitig keine Anfragen mehr stellen und sieht ihre
--      eigenen nicht-genehmigten Anfragen nicht mehr (RLS)
--    * ihre Anfragen bleiben vollständig erhalten und mit Namen
--      sichtbar für die Inhaberin
--  Den Supabase-Login der Person zusätzlich sperren (Authentication →
--  Users → Ban/Delete) — das kann SQL hier nicht übernehmen.
-- ════════════════════════════════════════════════════════════

ALTER TABLE abw_team ADD COLUMN IF NOT EXISTS ausgeschieden_am date;

-- Spaltenrechte: abw_team hat seit der RLS-Härtung nur spaltenweise
-- SELECT-Rechte. Das Datum ist unbedenklich; anon braucht es nur, damit
-- die Login-View danach filtern kann.
GRANT SELECT (ausgeschieden_am) ON abw_team TO authenticated, anon;

-- Ausgeschiedene gelten nicht mehr als „aktuelle Person“.
CREATE OR REPLACE FUNCTION abw_current_person_id() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id FROM abw_team
  WHERE lower(replace(trim(name), ' ', '.')) || '.abwesenheit@greathairday.at' = auth.jwt() ->> 'email'
    AND ausgeschieden_am IS NULL
  LIMIT 1;
$$;

-- Login-Auswahl („Wer bist du?“): nur aktive Personen.
CREATE OR REPLACE VIEW abw_team_login
WITH (security_invoker = true) AS
SELECT id, name, role
FROM abw_team
WHERE ausgeschieden_am IS NULL;

-- Maskierende View: ausgeschieden_am am Ende ergänzt (für alle sichtbar,
-- damit der Kalender Ehemalige erkennen kann; das Datum ist unbedenklich).
CREATE OR REPLACE VIEW abw_team_scoped
WITH (security_invoker = true) AS
SELECT
  id,
  name,
  role,
  CASE WHEN abw_is_owner() OR id = abw_current_person_id() THEN urlaub_anspruch END AS urlaub_anspruch,
  CASE WHEN abw_is_owner() OR id = abw_current_person_id() THEN urlaub_verbraucht END AS urlaub_verbraucht,
  CASE WHEN abw_is_owner() OR id = abw_current_person_id() THEN eintrittsdatum END AS eintrittsdatum,
  ausgeschieden_am
FROM abw_team;

REVOKE ALL ON abw_team_scoped FROM PUBLIC, anon;
GRANT SELECT ON abw_team_scoped TO authenticated;
