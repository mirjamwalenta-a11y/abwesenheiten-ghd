-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · SCHRITT 4 · TEIL D – Testen bis zum Start
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql mit supabase/erzeugen.py.
--  Testdaten vor dem Start löschen (nur Chefin, nur vor dem Starttag).
--  Erst NACH Teil C ausführen.
--  Läuft als EINE Transaktion: bei einem Fehler wird gar nichts geändert.
--  Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════
BEGIN;
DO $pruef$ BEGIN
  IF to_regprocedure('public.zeit_einst(text)') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil C ausführen.'; END IF;
END $pruef$;
-- ════════════════════════════════════════════════════════════
--  SCHRITT 4 – TESTEN BIS ZUM START
--  Vor dem Start (Einstellung kontoStart, z. B. 01.01.2027) darf die Chefin
--  alle Testeinträge löschen. Nach dem Start ist das gesperrt – dann sind es
--  echte Arbeitszeitaufzeichnungen (Aufbewahrungspflicht).
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_testdaten_loeschen() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_heute date := (now() AT TIME ZONE 'Europe/Vienna')::date;
  v_start date := NULLIF(zeit_einst('kontoStart') #>> '{}', '')::date;
  n_b int; n_k int; n_p int;
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Nur die Chefin'; END IF;
  IF v_start IS NULL OR v_heute >= v_start THEN
    RAISE EXCEPTION 'Testdaten löschen geht nur vor dem Start der Zeitverwaltung (Starttag in den Einstellungen festlegen).';
  END IF;
  DELETE FROM zeit_monatsabschluss;                       -- sonst sperrt der Abschluss das Löschen
  DELETE FROM zeit_korrekturen;                GET DIAGNOSTICS n_k = ROW_COUNT;
  DELETE FROM zeit_buchungen;                  GET DIAGNOSTICS n_b = ROW_COUNT;
  DELETE FROM zeit_protokoll;                  GET DIAGNOSTICS n_p = ROW_COUNT;
  DELETE FROM zeit_pin_versuche;
  DELETE FROM zeit_aussentermine WHERE datum < v_start;
  INSERT INTO zeit_personal_verlauf (von_person, person_id, aktion, details)
    VALUES (abw_current_person_id(), abw_current_person_id(), 'Testdaten gelöscht',
            n_b || ' Arbeitszeiten, ' || n_k || ' Korrekturanträge, ' || n_p || ' Protokolleinträge (vor dem Start am ' || to_char(v_start, 'DD.MM.YYYY') || ')');
  RETURN jsonb_build_object('buchungen', n_b, 'korrekturen', n_k, 'protokoll', n_p);
END $$;
REVOKE ALL ON FUNCTION zeit_testdaten_loeschen() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_testdaten_loeschen() TO authenticated;


COMMIT;
