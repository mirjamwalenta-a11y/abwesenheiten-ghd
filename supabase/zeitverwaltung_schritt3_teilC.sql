-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · SCHRITT 3 · TEIL C – Anbindung der App
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql mit supabase/erzeugen.py.
--  Einstellungen an einer Stelle, Feiertage, Automatik-Job (pg_cron),
--  Tablet-Liste mit Plan. Erst NACH Teil A und B ausführen.
--  Vorher: Supabase → Database → Extensions → pg_cron aktivieren.
--  Läuft als EINE Transaktion: bei einem Fehler wird gar nichts geändert.
--  Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════
BEGIN;
DO $pruef$ BEGIN
  IF to_regclass('public.zeit_nachrichten') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil A und Teil B ausführen.'; END IF;
END $pruef$;
-- ════════════════════════════════════════════════════════════
--  SCHRITT 3 – ANBINDUNG DER APP
--  * Alle Einstellungen der Zeitverwaltung liegen in EINEM Datensatz
--    abw_einstellungen (schluessel = 'zeitverwaltung'), den nur die Chefin
--    ändern darf (bestehende RLS). Server und App lesen dieselben Werte.
--  * Feinere Abwesenheitsarten neben urlaub/krankenstand/sonstige.
--  * Automatik-Job alle 15 Minuten (pg_cron), erst ab Start der Zeitverwaltung.
-- ════════════════════════════════════════════════════════════
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS zeit_art text;   -- z. B. berufsschule, arzt, pflege …
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS offen boolean NOT NULL DEFAULT false;  -- Krankenstand ohne Ende

DROP FUNCTION IF EXISTS zeit_automatik(date, boolean, boolean, boolean);
CREATE OR REPLACE FUNCTION zeit_automatik(
  p_datum date DEFAULT ((now() AT TIME ZONE 'Europe/Vienna')::date - 1),
  p_auto_gehen boolean DEFAULT true, p_auto_pause boolean DEFAULT true, p_auto_fehltag boolean DEFAULT true,
  p_nach_min integer DEFAULT 15
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p      record;
  v_plan zeit_modell_tage;
  b      zeit_buchungen;
  n      integer := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM zeit_feiertage WHERE datum = p_datum) THEN RETURN 0; END IF;
  FOR p IN SELECT id FROM abw_team WHERE ausgeschieden_am IS NULL OR ausgeschieden_am >= p_datum LOOP
    v_plan := zeit_plan_am(p.id, p_datum);
    CONTINUE WHEN v_plan.beginn IS NULL OR zeit_monat_gesperrt(p.id, p_datum);
    -- heute erst, wenn Dienstende laut Plan + p_nach_min vorbei ist (automatisch ausstempeln am selben Abend)
    CONTINUE WHEN p_datum >= (now() AT TIME ZONE 'Europe/Vienna')::date
      AND (now() AT TIME ZONE 'Europe/Vienna')::time < v_plan.ende + make_interval(mins => p_nach_min);
    SELECT * INTO b FROM zeit_buchungen WHERE person_id = p.id AND datum = p_datum FOR UPDATE;
    IF NOT FOUND THEN
      -- jede genehmigte Abwesenheit (auch halbe Tage, Arztbesuch) → nichts automatisch anlegen
      CONTINUE WHEN NOT p_auto_fehltag OR EXISTS (
        SELECT 1 FROM abw_anfragen WHERE person_id = p.id AND status = 'genehmigt'
          AND p_datum BETWEEN von AND CASE WHEN offen THEN 'infinity'::date ELSE bis END);
      INSERT INTO zeit_buchungen (person_id, datum, beginn, ende, pause_min, quelle, auto)
        VALUES (p.id, p_datum, v_plan.beginn, v_plan.ende, v_plan.pause_min, 'auto', ARRAY['tag']);
      INSERT INTO zeit_protokoll (person_id, datum, aktion, grund)
        VALUES (p.id, p_datum, 'automatisch ergänzt: ganzer Tag', 'nicht gestempelt – laut Dienstplan');
      n := n + 1;
      CONTINUE;
    END IF;
    IF b.ende IS NULL AND p_auto_gehen THEN
      UPDATE zeit_buchungen
        SET ende = greatest(v_plan.ende, beginn),
            pause_min = pause_min + COALESCE((extract(epoch FROM greatest(v_plan.ende, beginn) - pause_start) / 60)::int, 0),
            pause_start = NULL, auto = auto || 'gehen'::text
        WHERE id = b.id RETURNING * INTO b;
      INSERT INTO zeit_protokoll (person_id, datum, aktion, grund)
        VALUES (p.id, p_datum, 'automatisch ergänzt: Gehen', 'nicht ausgestempelt – Dienstende laut Plan');
      n := n + 1;
    END IF;
    IF p_auto_pause AND zeit_auto_pause_erlaubt() AND zeit_pause_noetig(p.id, b) THEN
      UPDATE zeit_buchungen SET pause_min = greatest(v_plan.pause_min, 30), auto = auto || 'pause'::text WHERE id = b.id;
      INSERT INTO zeit_protokoll (person_id, datum, aktion, grund)
        VALUES (p.id, p_datum, 'automatisch ergänzt: Pause', 'keine Pause gestempelt – laut Dienstplan');
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- abw_einstellungen.wert ist eine text-Spalte (die App speichert JSON als Text, teils doppelt
-- verpackt als JSON-String). to_jsonb() + Auspacken funktioniert für text und jsonb gleich.
CREATE OR REPLACE FUNCTION zeit_einst(p_key text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE w jsonb; i int := 0;
BEGIN
  SELECT to_jsonb(wert) INTO w FROM abw_einstellungen WHERE schluessel = 'zeitverwaltung';
  WHILE jsonb_typeof(w) = 'string' AND i < 3 LOOP
    BEGIN w := (w #>> '{}')::jsonb; EXCEPTION WHEN others THEN RETURN NULL; END;
    i := i + 1;
  END LOOP;
  IF jsonb_typeof(w) <> 'object' THEN RETURN NULL; END IF;
  RETURN w -> p_key;
END $$;
REVOKE ALL ON FUNCTION zeit_einst(text) FROM anon, public;
GRANT EXECUTE ON FUNCTION zeit_einst(text) TO authenticated;

CREATE OR REPLACE FUNCTION zeit_handy_stempeln_erlaubt() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM zeit_aussentermine
                 WHERE person_id = abw_current_person_id() AND datum = (now() AT TIME ZONE 'Europe/Vienna')::date)
  OR CASE COALESCE(zeit_einst('stempelOrt') #>> '{}', 'tablet')
    WHEN 'ueberall' THEN true
    WHEN 'salon' THEN EXISTS (SELECT 1 FROM zeit_salon_netze WHERE ip = zeit_client_ip())
    ELSE false END;
$$;

CREATE OR REPLACE FUNCTION zeit_stempel_status() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('modus', COALESCE(zeit_einst('stempelOrt') #>> '{}', 'tablet'),
                            'erlaubt', zeit_handy_stempeln_erlaubt(),
                            'im_salon_netz', EXISTS (SELECT 1 FROM zeit_salon_netze WHERE ip = zeit_client_ip()));
$$;

CREATE OR REPLACE FUNCTION zeit_runden(p_zeit time, p_plan time, p_art text) RETURNS time
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p_plan IS NOT NULL AND COALESCE((zeit_einst('rundungAn'))::boolean, true) AND
    p_zeit BETWEEN p_plan - make_interval(mins => COALESCE((zeit_einst(CASE WHEN p_art = 'beginn' THEN 'rundBVor' ELSE 'rundEVor' END))::int, CASE WHEN p_art = 'beginn' THEN 30 ELSE 5 END))
               AND p_plan + make_interval(mins => COALESCE((zeit_einst(CASE WHEN p_art = 'beginn' THEN 'rundBNach' ELSE 'rundENach' END))::int, CASE WHEN p_art = 'beginn' THEN 5 ELSE 15 END))
    THEN p_plan ELSE p_zeit END;
$$;

-- Pausen automatisch nur mit schriftlicher Pausen-Vereinbarung (Haken in den Einstellungen)
CREATE OR REPLACE FUNCTION zeit_auto_pause_erlaubt() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((zeit_einst('pausenVereinbarung'))::boolean, false) AND COALESCE((zeit_einst('autoPause'))::boolean, true);
$$;

-- Urlaubssperre: Schalter aus den Einstellungen
CREATE OR REPLACE FUNCTION zeit_urlaub_sperre() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_gruppe text; v_name text;
BEGIN
  IF NEW.typ <> 'urlaub' OR NEW.status NOT IN ('ausstehend', 'genehmigt') OR abw_is_owner()
     OR NOT COALESCE((zeit_einst('urlaubsSperre'))::boolean, true) THEN
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

-- Automatik für gestern und heute mit den Einstellungen der Chefin – erst ab Start (kontoStart)
CREATE OR REPLACE FUNCTION zeit_automatik_lauf() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_heute date := (now() AT TIME ZONE 'Europe/Vienna')::date;
  v_start date := NULLIF(zeit_einst('kontoStart') #>> '{}', '')::date;
  v_n integer := 0; d date;
BEGIN
  IF v_start IS NULL THEN RETURN 0; END IF;   -- Zeitverwaltung noch nicht gestartet
  FOREACH d IN ARRAY ARRAY[v_heute - 1, v_heute] LOOP
    CONTINUE WHEN d < v_start;
    v_n := v_n + zeit_automatik(d,
      COALESCE((zeit_einst('autoGehen'))::boolean, true), true,
      COALESCE((zeit_einst('autoFehltag'))::boolean, true),
      COALESCE((zeit_einst('autoGehenNachMin'))::int, 15));
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION zeit_automatik_lauf() FROM PUBLIC, anon, authenticated;

-- Tablet-Liste mit Plan (für den Kaffee- und Abschiedsgruß) und heutiger Abwesenheit
DROP FUNCTION IF EXISTS zeit_terminal_liste();
CREATE FUNCTION zeit_terminal_liste()
RETURNS TABLE (person_id text, vorname text, status text, seit time, plan_beginn time, plan_ende time, abwesend text, urlaub_ab date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_heute date := (now() AT TIME ZONE 'Europe/Vienna')::date;
BEGIN
  IF NOT zeit_ist_terminal() THEN RAISE EXCEPTION 'Kein Stempel-Tablet'; END IF;
  RETURN QUERY
    SELECT t.id, split_part(trim(t.name), ' ', 1),
           CASE WHEN b.id IS NULL THEN 'aus' WHEN b.ende IS NOT NULL THEN 'fertig'
                WHEN b.pause_start IS NOT NULL THEN 'pause' ELSE 'da' END,
           COALESCE(b.pause_start, b.beginn_roh, b.beginn),
           (zeit_plan_am(t.id, v_heute)).beginn, (zeit_plan_am(t.id, v_heute)).ende,
           (SELECT CASE a.typ WHEN 'urlaub' THEN 'Urlaub' WHEN 'krankenstand' THEN 'Krankenstand' ELSE COALESCE(initcap(a.zeit_art), 'Abwesend') END
              FROM abw_anfragen a WHERE a.person_id = t.id AND a.status = 'genehmigt'
               AND v_heute BETWEEN a.von AND CASE WHEN a.offen THEN 'infinity'::date ELSE a.bis END
               AND COALESCE(a.anteil, 1) = 1 AND a.minuten IS NULL LIMIT 1),
           -- Urlaub ab dem nächsten Arbeitstag (kein Arbeitstag laut Plan dazwischen) → „schönen Urlaub“
           (SELECT min(a.von) FROM abw_anfragen a WHERE a.person_id = t.id AND a.typ = 'urlaub' AND a.status = 'genehmigt'
               AND a.von > v_heute AND a.von <= v_heute + 14
               AND NOT EXISTS (SELECT 1 FROM generate_series(v_heute + 1, a.von - 1, interval '1 day') g
                               WHERE (zeit_plan_am(t.id, g::date)).beginn IS NOT NULL
                                 AND NOT EXISTS (SELECT 1 FROM zeit_feiertage f WHERE f.datum = g::date)))
    FROM abw_team t
    LEFT JOIN zeit_buchungen b ON b.person_id = t.id AND b.datum = v_heute
    WHERE t.ausgeschieden_am IS NULL OR t.ausgeschieden_am >= v_heute
    ORDER BY t.name;
END $$;
REVOKE ALL ON FUNCTION zeit_terminal_liste() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_terminal_liste() TO authenticated;

-- Stammdaten-Änderungen aus der App dokumentieren (nur Leitung, nur im eigenen Namen)
DROP POLICY IF EXISTS zeit_verlauf_insert ON zeit_personal_verlauf;
CREATE POLICY zeit_verlauf_insert ON zeit_personal_verlauf FOR INSERT TO authenticated
  WITH CHECK (zeit_darf_verwalten(person_id) AND von_person = abw_current_person_id());
GRANT INSERT ON zeit_personal_verlauf TO authenticated;
GRANT USAGE ON SEQUENCE zeit_personal_verlauf_id_seq TO authenticated;

-- Gesetzliche Feiertage Österreich (für die Server-Automatik)
INSERT INTO zeit_feiertage (datum, name) VALUES
  ('2026-01-01', 'Neujahr'),
  ('2026-01-06', 'Heilige Drei Könige'),
  ('2026-04-06', 'Ostermontag'),
  ('2026-05-01', 'Staatsfeiertag'),
  ('2026-05-14', 'Christi Himmelfahrt'),
  ('2026-05-25', 'Pfingstmontag'),
  ('2026-06-04', 'Fronleichnam'),
  ('2026-08-15', 'Mariä Himmelfahrt'),
  ('2026-10-26', 'Nationalfeiertag'),
  ('2026-11-01', 'Allerheiligen'),
  ('2026-12-08', 'Mariä Empfängnis'),
  ('2026-12-25', 'Christtag'),
  ('2026-12-26', 'Stefanitag'),
  ('2027-01-01', 'Neujahr'),
  ('2027-01-06', 'Heilige Drei Könige'),
  ('2027-03-29', 'Ostermontag'),
  ('2027-05-01', 'Staatsfeiertag'),
  ('2027-05-06', 'Christi Himmelfahrt'),
  ('2027-05-17', 'Pfingstmontag'),
  ('2027-05-27', 'Fronleichnam'),
  ('2027-08-15', 'Mariä Himmelfahrt'),
  ('2027-10-26', 'Nationalfeiertag'),
  ('2027-11-01', 'Allerheiligen'),
  ('2027-12-08', 'Mariä Empfängnis'),
  ('2027-12-25', 'Christtag'),
  ('2027-12-26', 'Stefanitag'),
  ('2028-01-01', 'Neujahr'),
  ('2028-01-06', 'Heilige Drei Könige'),
  ('2028-04-17', 'Ostermontag'),
  ('2028-05-01', 'Staatsfeiertag'),
  ('2028-05-25', 'Christi Himmelfahrt'),
  ('2028-06-05', 'Pfingstmontag'),
  ('2028-06-15', 'Fronleichnam'),
  ('2028-08-15', 'Mariä Himmelfahrt'),
  ('2028-10-26', 'Nationalfeiertag'),
  ('2028-11-01', 'Allerheiligen'),
  ('2028-12-08', 'Mariä Empfängnis'),
  ('2028-12-25', 'Christtag'),
  ('2028-12-26', 'Stefanitag'),
  ('2029-01-01', 'Neujahr'),
  ('2029-01-06', 'Heilige Drei Könige'),
  ('2029-04-02', 'Ostermontag'),
  ('2029-05-01', 'Staatsfeiertag'),
  ('2029-05-10', 'Christi Himmelfahrt'),
  ('2029-05-21', 'Pfingstmontag'),
  ('2029-05-31', 'Fronleichnam'),
  ('2029-08-15', 'Mariä Himmelfahrt'),
  ('2029-10-26', 'Nationalfeiertag'),
  ('2029-11-01', 'Allerheiligen'),
  ('2029-12-08', 'Mariä Empfängnis'),
  ('2029-12-25', 'Christtag'),
  ('2029-12-26', 'Stefanitag'),
  ('2030-01-01', 'Neujahr'),
  ('2030-01-06', 'Heilige Drei Könige'),
  ('2030-04-22', 'Ostermontag'),
  ('2030-05-01', 'Staatsfeiertag'),
  ('2030-05-30', 'Christi Himmelfahrt'),
  ('2030-06-10', 'Pfingstmontag'),
  ('2030-06-20', 'Fronleichnam'),
  ('2030-08-15', 'Mariä Himmelfahrt'),
  ('2030-10-26', 'Nationalfeiertag'),
  ('2030-11-01', 'Allerheiligen'),
  ('2030-12-08', 'Mariä Empfängnis'),
  ('2030-12-25', 'Christtag'),
  ('2030-12-26', 'Stefanitag'),
  ('2031-01-01', 'Neujahr'),
  ('2031-01-06', 'Heilige Drei Könige'),
  ('2031-04-14', 'Ostermontag'),
  ('2031-05-01', 'Staatsfeiertag'),
  ('2031-05-22', 'Christi Himmelfahrt'),
  ('2031-06-02', 'Pfingstmontag'),
  ('2031-06-12', 'Fronleichnam'),
  ('2031-08-15', 'Mariä Himmelfahrt'),
  ('2031-10-26', 'Nationalfeiertag'),
  ('2031-11-01', 'Allerheiligen'),
  ('2031-12-08', 'Mariä Empfängnis'),
  ('2031-12-25', 'Christtag'),
  ('2031-12-26', 'Stefanitag'),
  ('2032-01-01', 'Neujahr'),
  ('2032-01-06', 'Heilige Drei Könige'),
  ('2032-03-29', 'Ostermontag'),
  ('2032-05-01', 'Staatsfeiertag'),
  ('2032-05-06', 'Christi Himmelfahrt'),
  ('2032-05-17', 'Pfingstmontag'),
  ('2032-05-27', 'Fronleichnam'),
  ('2032-08-15', 'Mariä Himmelfahrt'),
  ('2032-10-26', 'Nationalfeiertag'),
  ('2032-11-01', 'Allerheiligen'),
  ('2032-12-08', 'Mariä Empfängnis'),
  ('2032-12-25', 'Christtag'),
  ('2032-12-26', 'Stefanitag'),
  ('2033-01-01', 'Neujahr'),
  ('2033-01-06', 'Heilige Drei Könige'),
  ('2033-04-18', 'Ostermontag'),
  ('2033-05-01', 'Staatsfeiertag'),
  ('2033-05-26', 'Christi Himmelfahrt'),
  ('2033-06-06', 'Pfingstmontag'),
  ('2033-06-16', 'Fronleichnam'),
  ('2033-08-15', 'Mariä Himmelfahrt'),
  ('2033-10-26', 'Nationalfeiertag'),
  ('2033-11-01', 'Allerheiligen'),
  ('2033-12-08', 'Mariä Empfängnis'),
  ('2033-12-25', 'Christtag'),
  ('2033-12-26', 'Stefanitag'),
  ('2034-01-01', 'Neujahr'),
  ('2034-01-06', 'Heilige Drei Könige'),
  ('2034-04-10', 'Ostermontag'),
  ('2034-05-01', 'Staatsfeiertag'),
  ('2034-05-18', 'Christi Himmelfahrt'),
  ('2034-05-29', 'Pfingstmontag'),
  ('2034-06-08', 'Fronleichnam'),
  ('2034-08-15', 'Mariä Himmelfahrt'),
  ('2034-10-26', 'Nationalfeiertag'),
  ('2034-11-01', 'Allerheiligen'),
  ('2034-12-08', 'Mariä Empfängnis'),
  ('2034-12-25', 'Christtag'),
  ('2034-12-26', 'Stefanitag'),
  ('2035-01-01', 'Neujahr'),
  ('2035-01-06', 'Heilige Drei Könige'),
  ('2035-03-26', 'Ostermontag'),
  ('2035-05-01', 'Staatsfeiertag'),
  ('2035-05-03', 'Christi Himmelfahrt'),
  ('2035-05-14', 'Pfingstmontag'),
  ('2035-05-24', 'Fronleichnam'),
  ('2035-08-15', 'Mariä Himmelfahrt'),
  ('2035-10-26', 'Nationalfeiertag'),
  ('2035-11-01', 'Allerheiligen'),
  ('2035-12-08', 'Mariä Empfängnis'),
  ('2035-12-25', 'Christtag'),
  ('2035-12-26', 'Stefanitag')
ON CONFLICT (datum) DO NOTHING;

-- Automatik-Job alle 15 Minuten. Voraussetzung: Supabase → Database → Extensions → pg_cron aktiviert.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('zeit-automatik', '*/15 * * * *', 'SELECT public.zeit_automatik_lauf()');
  ELSE
    RAISE NOTICE 'pg_cron ist nicht aktiviert – Automatik-Job NICHT eingerichtet.';
  END IF;
END $cron$;


COMMIT;

-- ── Kontrolle: alle Tabellen der Zeitverwaltung haben RLS (Spalte rls muss überall true sein) ──
SELECT c.relname AS tabelle, c.relrowsecurity AS rls
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname LIKE 'zeit\_%'
ORDER BY 1;

-- ── Kontrolle: Automatik-Job eingerichtet? (eine Zeile „zeit-automatik“ = ja) ──
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN 'Automatik-Job eingerichtet (alle 15 Minuten)'
            ELSE 'Automatik-Job FEHLT – pg_cron aktivieren und Teil C nochmal ausführen' END AS automatik;
