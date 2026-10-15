-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · SCHRITT 8 · TEIL H – Vergessenes Ausstempeln schon in der Testphase
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql mit supabase/erzeugen.py.
--  Vor dem Starttag wird vergessenes Gehen (und die Pause) automatisch
--  ergänzt; ganze vergessene Tage erst ab dem Starttag. Erst NACH Teil G.
--  Läuft als EINE Transaktion: bei einem Fehler wird gar nichts geändert.
--  Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════
BEGIN;
-- ════════════════════════════════════════════════════════════
--  SCHRITT 8 – VERGESSENES AUSSTEMPELN SCHON IN DER TESTPHASE
--  Vor dem Starttag ergänzt die Automatik vergessenes Gehen (und die Pause
--  laut Plan) bereits automatisch – nur bei Einträgen, die jemand selbst
--  begonnen hat. Ganze vergessene Tage (Fehltage) werden erst ab dem Starttag
--  angelegt, damit für Personen, die noch nicht mittesten, nichts entsteht.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_automatik_lauf() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_heute date := (now() AT TIME ZONE 'Europe/Vienna')::date;
  v_start date := NULLIF(zeit_einst('kontoStart') #>> '{}', '')::date;
  v_n integer := 0; d date; v_test boolean;
BEGIN
  FOREACH d IN ARRAY ARRAY[v_heute - 1, v_heute] LOOP
    v_test := v_start IS NULL OR d < v_start;   -- Testphase: keine ganzen Tage anlegen
    v_n := v_n + zeit_automatik(d,
      COALESCE((zeit_einst('autoGehen'))::boolean, true), true,
      CASE WHEN v_test THEN false ELSE COALESCE((zeit_einst('autoFehltag'))::boolean, true) END,
      COALESCE((zeit_einst('autoGehenNachMin'))::int, 15));
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION zeit_automatik_lauf() FROM PUBLIC, anon, authenticated;


COMMIT;

SELECT CASE WHEN pg_get_functiondef('public.zeit_automatik_lauf()'::regprocedure) LIKE '%v_test%'
            THEN 'Automatik in der Testphase – eingerichtet' ELSE 'FEHLT – Teil H nochmal ausführen' END AS automatik_testphase;
