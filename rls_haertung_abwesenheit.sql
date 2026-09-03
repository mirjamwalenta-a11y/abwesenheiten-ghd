-- ════════════════════════════════════════════════════════════
--  A Great Hair Day · Abwesenheiten
--  RLS-Härtung: abw_team, abw_anfragen, abw_einstellungen
--  Im Supabase SQL-Editor ausführen. Sicher mehrfach ausführbar
--  (DROP POLICY IF EXISTS / CREATE OR REPLACE vor jeder Änderung).
--
--  Identität: Es gibt keine Rollen-Spalte, die direkt an auth.uid() hängt —
--  jede Person loggt sich über <name>.abwesenheit@greathairday.at ein
--  (siehe abwEmail() im Frontend). Die zwei Hilfsfunktionen unten bilden
--  genau diese im Frontend bereits verbindliche Zuordnung nach.
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

-- ── abw_team ───────────────────────────────────────────────────
-- Fachlich: Name/Rolle aller Personen bleiben für den gemeinsamen Kalender lesbar,
-- Anlegen/Ändern/Löschen (Urlaubsanspruch, PIN, Eintrittsdatum, ...) ist Chefin-Sache.
-- Der PIN wird im Frontend nirgends zurückgelesen (write-only) — deshalb zusätzlich
-- komplett von SELECT ausgenommen, statt nur per RLS "irgendwie" mitzulaufen.
ALTER TABLE abw_team ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "abw_team_select" ON abw_team;
CREATE POLICY "abw_team_select" ON abw_team FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "abw_team_insert" ON abw_team;
CREATE POLICY "abw_team_insert" ON abw_team FOR INSERT TO authenticated
  WITH CHECK (abw_is_owner());

DROP POLICY IF EXISTS "abw_team_update" ON abw_team;
CREATE POLICY "abw_team_update" ON abw_team FOR UPDATE TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

DROP POLICY IF EXISTS "abw_team_delete" ON abw_team;
CREATE POLICY "abw_team_delete" ON abw_team FOR DELETE TO authenticated
  USING (abw_is_owner());

-- PIN nie per REST/API zurücklesbar, für niemanden (auch nicht die Chefin über diesen Weg) —
-- er wird ausschließlich geschrieben (PATCH), nie gelesen.
REVOKE SELECT (pin) ON abw_team FROM authenticated, anon;

-- ── abw_anfragen ───────────────────────────────────────────────
-- Fachlich (bereits im Frontend-Kommentar so festgehalten, jetzt echt erzwungen):
-- Mitarbeiter:innen sehen genehmigte Anfragen aller + jeden Status der eigenen;
-- eigene Anfragen dürfen nur für sich selbst und nur als "ausstehend" angelegt werden;
-- genehmigen/ablehnen/direkt eintragen ist Chefin-Sache.
ALTER TABLE abw_anfragen ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "abw_anfragen_select" ON abw_anfragen;
CREATE POLICY "abw_anfragen_select" ON abw_anfragen FOR SELECT TO authenticated
  USING (
    status = 'genehmigt'
    OR person_id = abw_current_person_id()
    OR abw_is_owner()
  );

DROP POLICY IF EXISTS "abw_anfragen_insert" ON abw_anfragen;
CREATE POLICY "abw_anfragen_insert" ON abw_anfragen FOR INSERT TO authenticated
  WITH CHECK (
    abw_is_owner()
    OR (person_id = abw_current_person_id() AND status = 'ausstehend')
  );

DROP POLICY IF EXISTS "abw_anfragen_update" ON abw_anfragen;
CREATE POLICY "abw_anfragen_update" ON abw_anfragen FOR UPDATE TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

DROP POLICY IF EXISTS "abw_anfragen_delete" ON abw_anfragen;
CREATE POLICY "abw_anfragen_delete" ON abw_anfragen FOR DELETE TO authenticated
  USING (abw_is_owner());

-- ── abw_einstellungen ──────────────────────────────────────────
-- Fachlich: Schließtage/Warnschwelle/Sperrzeiten müssen alle lesen können
-- (fürs Kalender-Blocking), ändern darf nur die Chefin.
ALTER TABLE abw_einstellungen ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "abw_einstellungen_select" ON abw_einstellungen;
CREATE POLICY "abw_einstellungen_select" ON abw_einstellungen FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "abw_einstellungen_insert" ON abw_einstellungen;
CREATE POLICY "abw_einstellungen_insert" ON abw_einstellungen FOR INSERT TO authenticated
  WITH CHECK (abw_is_owner());

DROP POLICY IF EXISTS "abw_einstellungen_update" ON abw_einstellungen;
CREATE POLICY "abw_einstellungen_update" ON abw_einstellungen FOR UPDATE TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

DROP POLICY IF EXISTS "abw_einstellungen_delete" ON abw_einstellungen;
CREATE POLICY "abw_einstellungen_delete" ON abw_einstellungen FOR DELETE TO authenticated
  USING (abw_is_owner());
