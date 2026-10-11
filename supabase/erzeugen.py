"""Erzeugt die Ausführungs-Skripte (Teil A/B/C) aus zeitverwaltung_schema_entwurf.sql.
Aufruf im Repo-Ordner:  python3 supabase/erzeugen.py
Der Entwurf bleibt die einzige Quelle – hier nichts von Hand ändern."""
import re, pathlib
R = pathlib.Path(__file__).resolve().parent.parent
src = (R / "zeitverwaltung_schema_entwurf.sql").read_text()
zeilen = src.split("\n")
def ab(marke): return [i for i, l in enumerate(zeilen) if marke in l][0] - 1
iB, iC, iD, iE, iF, iG = ab("URLAUBSSPERRE JE GRUPPE + NACHRICHTEN"), ab("SCHRITT 3 – ANBINDUNG DER APP"), ab("SCHRITT 4 – TESTEN BIS ZUM START"), ab("SCHRITT 5 – PAUSEN-ERINNERUNG"), ab("SCHRITT 6 – FREIE TAGE GESPERRT"), ab("SCHRITT 7 – PAUSE LAUT DIENSTPLAN IMMER ABZIEHEN")
teilA, teilB, teilC, teilD, teilE, teilF, teilG = "\n".join(zeilen[:iB]), "\n".join(zeilen[iB:iC]), "\n".join(zeilen[iC:iD]), "\n".join(zeilen[iD:iE]), "\n".join(zeilen[iE:iF]), "\n".join(zeilen[iF:iG]), "\n".join(zeilen[iG:])
# Teil C braucht die aktuelle Automatik-Funktion (offene Krankenstände) – aus Teil A übernehmen
m = re.search(r"DROP FUNCTION IF EXISTS zeit_automatik\(date, boolean, boolean, boolean\);.*?END \$\$;\n", teilA, re.S)
automatik = m.group(0)
kontrolle = """
-- ── Kontrolle: alle Tabellen der Zeitverwaltung haben RLS (Spalte rls muss überall true sein) ──
SELECT c.relname AS tabelle, c.relrowsecurity AS rls
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname LIKE 'zeit\\_%'
ORDER BY 1;
"""
pruefA = """DO $pruef$
BEGIN
  IF to_regclass('public.abw_team') IS NULL OR to_regclass('public.abw_anfragen') IS NULL THEN
    RAISE EXCEPTION 'Abbruch: abw_team / abw_anfragen nicht gefunden – ist das das richtige Supabase-Projekt?';
  END IF;
  IF (SELECT data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'abw_team' AND column_name = 'id') <> 'text' THEN
    RAISE EXCEPTION 'Abbruch: abw_team.id ist nicht vom Typ text – bitte Claude Bescheid geben.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'abw_team' AND column_name = 'ausgeschieden_am') THEN
    RAISE EXCEPTION 'Abbruch: abw_team.ausgeschieden_am fehlt – zuerst ausgeschieden_mitarbeitende.sql ausführen.';
  END IF;
  IF to_regprocedure('public.abw_is_owner()') IS NULL OR to_regprocedure('public.abw_current_person_id()') IS NULL THEN
    RAISE EXCEPTION 'Abbruch: abw_is_owner() / abw_current_person_id() fehlen – zuerst rls_haertung_abwesenheit.sql ausführen.';
  END IF;
END $pruef$;
"""
kopf = lambda titel, text: f"""-- ════════════════════════════════════════════════════════════
--  ZEITVERWALTUNG · {titel}
--  Erzeugt aus zeitverwaltung_schema_entwurf.sql mit supabase/erzeugen.py.
{text}
--  Läuft als EINE Transaktion: bei einem Fehler wird gar nichts geändert.
--  Mehrfach ausführbar.
-- ════════════════════════════════════════════════════════════
BEGIN;
"""
A = kopf("SCHRITT 2 · TEIL A – Tabellen und Funktionen", "--  Ändert NICHTS am Verhalten der Abwesenheiten-App (nur neue Spalten\n--  an abw_anfragen und ein Protokoll-Trigger bei Austritten).") + "\n" + pruefA + "\n" + teilA + "\n\nCOMMIT;\n" + kontrolle
B = kopf("SCHRITT 2 · TEIL B – Urlaubssperre + Nachrichten", "--  ACHTUNG: wirkt auch in der Abwesenheiten-App (Trigger auf abw_anfragen).\n--  Erst NACH Teil A ausführen.\n--  Rückgängig: DROP TRIGGER zeit_urlaub_sperre ON abw_anfragen;\n--              DROP TRIGGER zeit_anfrage_nachricht ON abw_anfragen;") + "DO $pruef$ BEGIN\n  IF to_regclass('public.zeit_profil') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil A ausführen.'; END IF;\nEND $pruef$;\n" + teilB + "\n\nCOMMIT;\n" + kontrolle
C = kopf("SCHRITT 3 · TEIL C – Anbindung der App", "--  Einstellungen an einer Stelle, Feiertage, Automatik-Job (pg_cron),\n--  Tablet-Liste mit Plan. Erst NACH Teil A und B ausführen.\n--  Vorher: Supabase → Database → Extensions → pg_cron aktivieren.") + "DO $pruef$ BEGIN\n  IF to_regclass('public.zeit_nachrichten') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil A und Teil B ausführen.'; END IF;\nEND $pruef$;\n" + teilC.replace("ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS offen boolean NOT NULL DEFAULT false;  -- Krankenstand ohne Ende\n", "ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS offen boolean NOT NULL DEFAULT false;  -- Krankenstand ohne Ende\n\n" + automatik, 1) + "\n\nCOMMIT;\n" + kontrolle + """
-- ── Kontrolle: Automatik-Job eingerichtet? (eine Zeile „zeit-automatik“ = ja) ──
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN 'Automatik-Job eingerichtet (alle 15 Minuten)'
            ELSE 'Automatik-Job FEHLT – pg_cron aktivieren und Teil C nochmal ausführen' END AS automatik;
"""
D = kopf("SCHRITT 4 · TEIL D – Testen bis zum Start", "--  Testdaten vor dem Start löschen (nur Chefin, nur vor dem Starttag).\n--  Erst NACH Teil C ausführen.") + "DO $pruef$ BEGIN\n  IF to_regprocedure('public.zeit_einst(text)') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil C ausführen.'; END IF;\nEND $pruef$;\n" + teilD + "\n\nCOMMIT;\n"
E = kopf("SCHRITT 5 · TEIL E – Pausen-Erinnerung", "--  Nachricht „Es wird Zeit für deine Pause“ (alle 5 Minuten, pg_cron).\n--  Erst NACH Teil C ausführen.") + "DO $pruef$ BEGIN\n  IF to_regprocedure('public.zeit_einst(text)') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil C ausführen.'; END IF;\nEND $pruef$;\n" + teilE + "\n\nCOMMIT;\n" + """
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN 'Pausen-Erinnerung eingerichtet (alle 5 Minuten)'
            ELSE 'Pausen-Erinnerung FEHLT – pg_cron aktivieren und Teil E nochmal ausführen' END AS pausen_erinnerung;
"""
F = kopf("SCHRITT 6 · TEIL F – Freie Tage gesperrt", "--  Einstempeln am freien Tag (laut Dienstplan) oder Feiertag nur mit\n--  Freigabe der Chefin (Außentermin oder Einspringen). Erst NACH Teil E ausführen.") + "DO $pruef$ BEGIN\n  IF to_regprocedure('public.zeit_pause_faellig_ab(text, date)') IS NULL THEN RAISE EXCEPTION 'Abbruch: zuerst Teil E ausführen.'; END IF;\nEND $pruef$;\n" + teilF + "\n\nCOMMIT;\n" + """
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zeit_freier_tag') THEN 'Freie Tage gesperrt – eingerichtet'
            ELSE 'FEHLT – Teil F nochmal ausführen' END AS freie_tage;
"""
G = kopf("SCHRITT 7 · TEIL G – Pause laut Dienstplan immer abziehen", "--  Mit Pausen-Vereinbarung wird die Pause laut Plan immer eingetragen,\n--  wenn keine gestempelt wurde (außer bei Tagen unter 3 h). Erst NACH Teil F.") + teilG + "\n\nCOMMIT;\n" + """
SELECT CASE WHEN pg_get_functiondef('public.zeit_pause_noetig(text, zeit_buchungen)'::regprocedure) LIKE '%180%'
            THEN 'Pause laut Dienstplan – eingerichtet' ELSE 'FEHLT – Teil G nochmal ausführen' END AS pause_laut_plan;
"""
for n, t in [("zeitverwaltung_schritt7_teilG.sql", G), ("zeitverwaltung_schritt6_teilF.sql", F), ("zeitverwaltung_schritt5_teilE.sql", E), ("zeitverwaltung_schritt2_teilA.sql", A), ("zeitverwaltung_schritt2_teilB.sql", B), ("zeitverwaltung_schritt3_teilC.sql", C), ("zeitverwaltung_schritt4_teilD.sql", D)]:
    (R / "supabase" / n).write_text(t)
print("ok")
