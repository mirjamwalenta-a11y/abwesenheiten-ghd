-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · SCHRITT 6 · TEIL F – Freie Tage gesperrt
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql mit supabase/erzeugen.py.
--  Einstempeln am freien Tag (laut Dienstplan) oder Feiertag nur mit
--  Freigabe der Chefin (Außentermin oder Einspringen). Erst NACH Teil E ausführen.
--  Läuft als EINE Transaktion: bei einem Fehler wird gar nichts geändert.
--  Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════
BEGIN;
DO $pruef$ BEGIN
  IF to_regprocedure('public.zeit_pause_faellig_ab(text, date)') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil E ausführen.'; END IF;
END $pruef$;
-- ════════════════════════════════════════════════════════════
--  SCHRITT 6 – FREIE TAGE GESPERRT
--  An einem Tag ohne Dienst laut Dienstplan (z. B. So + Mo geschlossen)
--  oder an einem Feiertag kann niemand einstempeln – weder am Handy noch
--  an der Stempeluhr. Ausnahme: die Chefin gibt den Tag frei, entweder als
--  „Außentermin“ (Handy überall, z. B. Hochzeit) oder als „Einspringen“
--  (nur der freie Tag wird freigegeben, gestempelt wird wie sonst).
--  Nachträgliche Einträge der Chefin (✎) und die Automatik sind nicht betroffen.
-- ════════════════════════════════════════════════════════════
ALTER TABLE zeit_aussentermine ADD COLUMN IF NOT EXISTS art text NOT NULL DEFAULT 'aussen';
ALTER TABLE zeit_aussentermine DROP CONSTRAINT IF EXISTS zeit_aussentermine_art_check;
ALTER TABLE zeit_aussentermine ADD CONSTRAINT zeit_aussentermine_art_check CHECK (art IN ('aussen', 'einspringen'));

-- Handy überall nur bei echtem Außentermin (nicht bei „Einspringen“)
CREATE OR REPLACE FUNCTION zeit_handy_stempeln_erlaubt() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM zeit_aussentermine
                 WHERE person_id = abw_current_person_id() AND art = 'aussen'
                   AND datum = (now() AT TIME ZONE 'Europe/Vienna')::date)
  OR CASE COALESCE(zeit_einst('stempelOrt') #>> '{}', 'tablet')
    WHEN 'ueberall' THEN true
    WHEN 'salon' THEN EXISTS (SELECT 1 FROM zeit_salon_netze WHERE ip = zeit_client_ip())
    ELSE false END;
$$;

-- Freier Tag laut Dienstplan oder Feiertag – und nicht von der Chefin freigegeben?
CREATE OR REPLACE FUNCTION zeit_tag_gesperrt(p_person text, p_datum date) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT ((zeit_plan_am(p_person, p_datum)).beginn IS NULL
          OR EXISTS (SELECT 1 FROM zeit_feiertage WHERE datum = p_datum))
     AND NOT EXISTS (SELECT 1 FROM zeit_aussentermine WHERE person_id = p_person AND datum = p_datum);
$$;
REVOKE ALL ON FUNCTION zeit_tag_gesperrt(text, date) FROM PUBLIC, anon;

-- Prüfung beim Einstempeln (Handy und Stempeluhr laufen beide hier durch)
CREATE OR REPLACE FUNCTION zeit_freier_tag_pruefen() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.quelle = 'stempel' AND zeit_tag_gesperrt(NEW.person_id, NEW.datum) THEN
    RAISE EXCEPTION 'Heute ist laut Dienstplan frei – einstempeln geht nur, wenn die Chefin den Tag freigibt.';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zeit_freier_tag ON zeit_buchungen;
CREATE TRIGGER zeit_freier_tag BEFORE INSERT ON zeit_buchungen
  FOR EACH ROW EXECUTE FUNCTION zeit_freier_tag_pruefen();

-- Verständliche Meldung, wenn das Handy nicht stempeln darf
CREATE OR REPLACE FUNCTION zeit_stempeln(p_aktion text, p_auto_pause boolean DEFAULT true) RETURNS zeit_buchungen
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF abw_current_person_id() IS NULL THEN RAISE EXCEPTION 'Nicht angemeldet'; END IF;
  IF NOT zeit_handy_stempeln_erlaubt() THEN
    RAISE EXCEPTION '%', CASE WHEN COALESCE(zeit_einst('stempelOrt') #>> '{}', 'tablet') = 'salon'
      THEN 'Stempeln am Handy nur im Salon-WLAN (oder an der Stempeluhr).'
      ELSE 'Stempeln nur an der Stempeluhr im Salon.' END;
  END IF;
  RETURN zeit__stempeln_fuer(abw_current_person_id(), p_aktion, p_auto_pause);
END $$;

-- Stempeluhr-Liste zusätzlich mit „heute gesperrt“ (freier Tag ohne Freigabe)
DROP FUNCTION IF EXISTS zeit_terminal_liste();
CREATE FUNCTION zeit_terminal_liste()
RETURNS TABLE (person_id text, vorname text, status text, seit time, plan_beginn time, plan_ende time, abwesend text, urlaub_ab date, pause_faellig boolean, gesperrt boolean)
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
           (SELECT min(a.von) FROM abw_anfragen a WHERE a.person_id = t.id AND a.typ = 'urlaub' AND a.status = 'genehmigt'
               AND a.von > v_heute AND a.von <= v_heute + 14
               AND NOT EXISTS (SELECT 1 FROM generate_series(v_heute + 1, a.von - 1, interval '1 day') g
                               WHERE (zeit_plan_am(t.id, g::date)).beginn IS NOT NULL
                                 AND NOT EXISTS (SELECT 1 FROM zeit_feiertage f WHERE f.datum = g::date))),
           (b.id IS NOT NULL AND b.ende IS NULL AND b.pause_start IS NULL AND b.pause_min = 0
             AND COALESCE((zeit_einst('pausenErinnerung'))::boolean, true)
             AND zeit_pause_faellig_ab(t.id, v_heute) IS NOT NULL AND v_jetzt::time >= zeit_pause_faellig_ab(t.id, v_heute)),
           (b.id IS NULL AND zeit_tag_gesperrt(t.id, v_heute))
    FROM abw_team t
    LEFT JOIN zeit_buchungen b ON b.person_id = t.id AND b.datum = v_heute
    WHERE t.ausgeschieden_am IS NULL OR t.ausgeschieden_am >= v_heute
    ORDER BY t.name;
END $$;
REVOKE ALL ON FUNCTION zeit_terminal_liste() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_terminal_liste() TO authenticated;


COMMIT;

SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zeit_freier_tag') THEN 'Freie Tage gesperrt – eingerichtet'
            ELSE 'FEHLT – Teil F nochmal ausführen' END AS freie_tage;
