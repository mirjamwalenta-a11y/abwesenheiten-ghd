-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · SCHRITT 7 · TEIL G – Pause laut Dienstplan immer abziehen
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql mit supabase/erzeugen.py.
--  Mit Pausen-Vereinbarung wird die Pause laut Plan immer eingetragen,
--  wenn keine gestempelt wurde (außer bei Tagen unter 3 h). Erst NACH Teil F.
--  Läuft als EINE Transaktion: bei einem Fehler wird gar nichts geändert.
--  Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════
BEGIN;
-- ════════════════════════════════════════════════════════════
--  SCHRITT 7 – PAUSE LAUT DIENSTPLAN IMMER ABZIEHEN
--  Mit Pausen-Vereinbarung (§ 26 Abs 5a AZG, Haken in den Einstellungen)
--  wird die Pause laut Dienstplan immer eingetragen, wenn keine (ausreichende)
--  gestempelt wurde – nicht erst ab 6 h Arbeit. Ausnahme: Tage unter 3 h
--  (z. B. krank heimgegangen). Die gesetzliche Mindestpause bleibt wie bisher.
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_pause_noetig(p_person text, b zeit_buchungen) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT b.ende IS NOT NULL AND (
    (b.pause_min < 30
     AND extract(epoch FROM b.ende - b.beginn) / 60 - b.pause_min
         > CASE WHEN zeit_jugendlich(p_person, b.datum) THEN 270 ELSE 360 END)
    OR
    (b.pause_min < COALESCE((zeit_plan_am(p_person, b.datum)).pause_min, 0)
     AND extract(epoch FROM b.ende - b.beginn) / 60 >= 180));
$$;


COMMIT;

SELECT CASE WHEN pg_get_functiondef('public.zeit_pause_noetig(text, zeit_buchungen)'::regprocedure) LIKE '%180%'
            THEN 'Pause laut Dienstplan – eingerichtet' ELSE 'FEHLT – Teil G nochmal ausführen' END AS pause_laut_plan;
