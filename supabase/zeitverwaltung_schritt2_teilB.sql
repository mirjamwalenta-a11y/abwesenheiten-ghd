-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · SCHRITT 2 · TEIL B – Urlaubssperre + Nachrichten
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql.
--  ACHTUNG: wirkt auch in der Abwesenheiten-App (Trigger auf abw_anfragen):
--  ein zweiter Stylist / Lehrling kann dort nicht mehr gleichzeitig Urlaub
--  beantragen, und bei jedem neuen Antrag entsteht eine Nachricht.
--  Erst NACH Teil A ausführen. Eine Transaktion, mehrfach ausführbar.
--  Rückgängig: DROP TRIGGER zeit_urlaub_sperre ON abw_anfragen;
--              DROP TRIGGER zeit_anfrage_nachricht ON abw_anfragen;
-- ════════════════════════════════════════════════════════════
BEGIN;
DO $pruef$ BEGIN
  IF to_regclass('public.zeit_profil') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil A ausführen.'; END IF;
END $pruef$;
-- ════════════════════════════════════════════════════════════
--  URLAUBSSPERRE JE GRUPPE + NACHRICHTEN
--  Achtung: Die Trigger hängen an abw_anfragen und wirken damit auch in der
--  LIVE-Abwesenheiten-App (dort werden Urlaube beantragt). Vor dem Ausführen
--  mit der Chefin abstimmen und in der Abwesenheiten-App testen.
-- ════════════════════════════════════════════════════════════
ALTER TABLE zeit_profil ADD COLUMN IF NOT EXISTS urlaub_gruppe text;
ALTER TABLE zeit_profil DROP CONSTRAINT IF EXISTS zeit_profil_urlaub_gruppe_check;
ALTER TABLE zeit_profil ADD CONSTRAINT zeit_profil_urlaub_gruppe_check
  CHECK (urlaub_gruppe IN ('stylist', 'lehrling', 'rezeption', 'assistenz', 'keine'));
ALTER TABLE zeit_stempel_regel ADD COLUMN IF NOT EXISTS urlaubssperre boolean NOT NULL DEFAULT true;

-- Gruppe einer Person: im Profil gesetzt, sonst aus Lehrbeginn/Funktion abgeleitet
CREATE OR REPLACE FUNCTION zeit_urlaub_gruppe(p_person text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN p.urlaub_gruppe = 'keine' THEN NULL
    WHEN p.urlaub_gruppe IS NOT NULL THEN p.urlaub_gruppe
    WHEN p.lehrbeginn IS NOT NULL OR p.funktion ILIKE '%lehrling%' THEN 'lehrling'
    WHEN p.funktion ILIKE '%styl%' THEN 'stylist'
  END
  FROM zeit_profil p WHERE p.person_id = p_person;
$$;
REVOKE ALL ON FUNCTION zeit_urlaub_gruppe(text) FROM anon, public;

-- Aus jeder Gruppe gleichzeitig nur eine Person auf Urlaub (beantragt oder genehmigt).
-- Die Chefin darf trotzdem eintragen/genehmigen.
CREATE OR REPLACE FUNCTION zeit_urlaub_sperre() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_gruppe text; v_name text;
BEGIN
  IF NEW.typ <> 'urlaub' OR NEW.status NOT IN ('ausstehend', 'genehmigt') OR abw_is_owner()
     OR NOT COALESCE((SELECT urlaubssperre FROM zeit_stempel_regel WHERE id), true) THEN
    RETURN NEW;
  END IF;
  v_gruppe := zeit_urlaub_gruppe(NEW.person_id);
  IF v_gruppe IS NULL THEN RETURN NEW; END IF;
  SELECT t.name INTO v_name
    FROM abw_anfragen a JOIN abw_team t ON t.id = a.person_id
    WHERE a.id IS DISTINCT FROM NEW.id AND a.person_id <> NEW.person_id
      AND a.typ = 'urlaub' AND a.status IN ('ausstehend', 'genehmigt')
      AND a.von <= COALESCE(NEW.bis, NEW.von) AND COALESCE(a.bis, a.von) >= NEW.von
      AND (t.ausgeschieden_am IS NULL OR t.ausgeschieden_am >= NEW.von)
      AND zeit_urlaub_gruppe(a.person_id) = v_gruppe
    LIMIT 1;
  IF v_name IS NOT NULL THEN
    RAISE EXCEPTION 'Urlaubssperre: % hat in diesem Zeitraum schon Urlaub – gleichzeitig nur eine Person aus dieser Gruppe.', v_name;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zeit_urlaub_sperre ON abw_anfragen;
CREATE TRIGGER zeit_urlaub_sperre BEFORE INSERT OR UPDATE OF von, bis, status, typ ON abw_anfragen
  FOR EACH ROW EXECUTE FUNCTION zeit_urlaub_sperre();

-- Nachrichten (Glocke in der App). Geschrieben nur von Triggern; lesen und
-- als gelesen markieren nur die Empfängerin / der Empfänger selbst.
-- E-Mail zusätzlich: Supabase → Database Webhooks → INSERT auf zeit_nachrichten
-- → Edge Function, die an die hinterlegte Adresse schickt. Die Adresse steht als
-- Secret in der Edge Function, NIE im Code (CLAUDE.md Regel 2).
CREATE TABLE IF NOT EXISTS zeit_nachrichten (
  id          bigserial PRIMARY KEY,
  an_person   text NOT NULL REFERENCES abw_team(id),
  text        text NOT NULL,
  seite       text,
  anfrage_id  text,                 -- abw_anfragen.id als Text (Typ dort egal)
  erstellt_am timestamptz NOT NULL DEFAULT now(),
  gelesen_am  timestamptz
);
ALTER TABLE zeit_nachrichten ENABLE ROW LEVEL SECURITY;
ALTER TABLE zeit_nachrichten ALTER COLUMN anfrage_id TYPE text USING anfrage_id::text;
REVOKE ALL ON zeit_nachrichten FROM anon, authenticated;
GRANT SELECT, UPDATE (gelesen_am) ON zeit_nachrichten TO authenticated;
DROP POLICY IF EXISTS zeit_nachrichten_lesen ON zeit_nachrichten;
CREATE POLICY zeit_nachrichten_lesen ON zeit_nachrichten FOR SELECT TO authenticated
  USING (an_person = abw_current_person_id());
DROP POLICY IF EXISTS zeit_nachrichten_gelesen ON zeit_nachrichten;
CREATE POLICY zeit_nachrichten_gelesen ON zeit_nachrichten FOR UPDATE TO authenticated
  USING (an_person = abw_current_person_id()) WITH CHECK (an_person = abw_current_person_id());

CREATE OR REPLACE FUNCTION zeit_anfrage_nachricht() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_name text; v_zr text;
BEGIN
  SELECT name INTO v_name FROM abw_team WHERE id = NEW.person_id;
  v_zr := to_char(NEW.von, 'DD.MM.YYYY') || CASE WHEN COALESCE(NEW.bis, NEW.von) <> NEW.von THEN ' – ' || to_char(NEW.bis, 'DD.MM.YYYY') ELSE '' END;
  IF TG_OP = 'INSERT' AND NEW.status = 'ausstehend' THEN
    -- an die Chefin(nen) und ggf. die zuständige Salonleitung
    INSERT INTO zeit_nachrichten (an_person, text, seite, anfrage_id)
      SELECT DISTINCT x.id, v_name || ' hat ' || CASE NEW.typ WHEN 'urlaub' THEN 'Urlaub' WHEN 'krankenstand' THEN 'Krankenstand' WHEN 'sonstige' THEN 'eine Abwesenheit' ELSE NEW.typ END || ' beantragt: ' || v_zr, 'urlaub', NEW.id::text
      FROM (SELECT id FROM abw_team WHERE role = 'owner'
            UNION SELECT vorgesetzter_id FROM zeit_profil WHERE person_id = NEW.person_id AND vorgesetzter_id IS NOT NULL) x
      WHERE x.id <> NEW.person_id;
  ELSIF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status AND NEW.status IN ('genehmigt', 'abgelehnt') THEN
    INSERT INTO zeit_nachrichten (an_person, text, seite, anfrage_id)
      VALUES (NEW.person_id, 'Dein Antrag ' || CASE NEW.typ WHEN 'urlaub' THEN 'Urlaub' WHEN 'krankenstand' THEN 'Krankenstand' WHEN 'sonstige' THEN 'eine Abwesenheit' ELSE NEW.typ END || ' ' || v_zr || ' wurde ' || NEW.status || '.', 'urlaub', NEW.id::text);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zeit_anfrage_nachricht ON abw_anfragen;
CREATE TRIGGER zeit_anfrage_nachricht AFTER INSERT OR UPDATE OF status ON abw_anfragen
  FOR EACH ROW EXECUTE FUNCTION zeit_anfrage_nachricht();


COMMIT;

-- ── Kontrolle: alle neuen Tabellen haben RLS (Spalte rls muss überall true sein) ──
SELECT c.relname AS tabelle, c.relrowsecurity AS rls
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname LIKE 'zeit\_%'
ORDER BY 1;
