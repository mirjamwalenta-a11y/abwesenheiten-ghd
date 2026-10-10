-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · SCHRITT 5 · TEIL E – Pausen-Erinnerung
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql mit supabase/erzeugen.py.
--  Nachricht „Es wird Zeit für deine Pause“ (alle 5 Minuten, pg_cron).
--  Erst NACH Teil C ausführen.
--  Läuft als EINE Transaktion: bei einem Fehler wird gar nichts geändert.
--  Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════
BEGIN;
DO $pruef$ BEGIN
  IF to_regprocedure('public.zeit_einst(text)') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil C ausführen.'; END IF;
END $pruef$;
-- ════════════════════════════════════════════════════════════
--  SCHRITT 5 – PAUSEN-ERINNERUNG
--  Wer eingestempelt ist und noch keine Pause hatte, bekommt zur Pausenzeit
--  laut Dienstplan (fixe Pause) bzw. zu Beginn des Pausenfensters eine
--  Nachricht „Es wird Zeit für deine Pause“. Einmal pro Tag und Person.
--  Läuft alle 5 Minuten (pg_cron). Abschaltbar in den Einstellungen.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_pause_faellig_ab(p_person text, p_datum date) RETURNS time
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN COALESCE((zeit_plan_am(p_person, p_datum)).pause_min, 0) <= 0 THEN NULL
    ELSE COALESCE((zeit_plan_am(p_person, p_datum)).pause_beginn,
                  NULLIF(zeit_einst('pausenFensterVon') #>> '{}', '')::time, '11:30'::time) END;
$$;
REVOKE ALL ON FUNCTION zeit_pause_faellig_ab(text, date) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION zeit_pausen_erinnerung() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_jetzt timestamp := now() AT TIME ZONE 'Europe/Vienna';
  v_heute date := v_jetzt::date; v_zeit time := v_jetzt::time;
  b record; v_ab time; v_plan zeit_modell_tage; v_n int := 0;
BEGIN
  IF NOT COALESCE((zeit_einst('pausenErinnerung'))::boolean, true) THEN RETURN 0; END IF;
  FOR b IN SELECT * FROM zeit_buchungen WHERE datum = v_heute AND ende IS NULL AND pause_start IS NULL AND pause_min = 0 LOOP
    v_ab := zeit_pause_faellig_ab(b.person_id, v_heute);
    CONTINUE WHEN v_ab IS NULL OR v_zeit < v_ab OR v_zeit > v_ab + interval '2 hours';
    CONTINUE WHEN EXISTS (SELECT 1 FROM zeit_nachrichten WHERE an_person = b.person_id AND seite = 'pause'
                          AND (erstellt_am AT TIME ZONE 'Europe/Vienna')::date = v_heute);
    v_plan := zeit_plan_am(b.person_id, v_heute);
    INSERT INTO zeit_nachrichten (an_person, text, seite)
      VALUES (b.person_id, '☕ Es wird Zeit für deine Pause' ||
        CASE WHEN v_plan.pause_beginn IS NOT NULL THEN ' (' || to_char(v_plan.pause_beginn, 'HH24:MI') || '–' || to_char(v_plan.pause_beginn + make_interval(mins => v_plan.pause_min), 'HH24:MI') || ')' ELSE '' END || '.', 'pause');
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION zeit_pausen_erinnerung() FROM PUBLIC, anon, authenticated;

-- Tablet-Liste zusätzlich mit „Pause fällig“
DROP FUNCTION IF EXISTS zeit_terminal_liste();
CREATE FUNCTION zeit_terminal_liste()
RETURNS TABLE (person_id text, vorname text, status text, seit time, plan_beginn time, plan_ende time, abwesend text, urlaub_ab date, pause_faellig boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_jetzt timestamp := now() AT TIME ZONE 'Europe/Vienna'; v_heute date := v_jetzt::date;
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
                                 AND NOT EXISTS (SELECT 1 FROM zeit_feiertage f WHERE f.datum = g::date))),
           (b.id IS NOT NULL AND b.ende IS NULL AND b.pause_start IS NULL AND b.pause_min = 0
             AND COALESCE((zeit_einst('pausenErinnerung'))::boolean, true)
             AND zeit_pause_faellig_ab(t.id, v_heute) IS NOT NULL AND v_jetzt::time >= zeit_pause_faellig_ab(t.id, v_heute))
    FROM abw_team t
    LEFT JOIN zeit_buchungen b ON b.person_id = t.id AND b.datum = v_heute
    WHERE t.ausgeschieden_am IS NULL OR t.ausgeschieden_am >= v_heute
    ORDER BY t.name;
END $$;
REVOKE ALL ON FUNCTION zeit_terminal_liste() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_terminal_liste() TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('zeit-pausen-erinnerung', '*/5 * * * *', 'SELECT public.zeit_pausen_erinnerung()');
  ELSE
    RAISE NOTICE 'pg_cron ist nicht aktiviert – Pausen-Erinnerung NICHT eingerichtet.';
  END IF;
END $cron$;


COMMIT;

SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN 'Pausen-Erinnerung eingerichtet (alle 5 Minuten)'
            ELSE 'Pausen-Erinnerung FEHLT – pg_cron aktivieren und Teil E nochmal ausführen' END AS pausen_erinnerung;
