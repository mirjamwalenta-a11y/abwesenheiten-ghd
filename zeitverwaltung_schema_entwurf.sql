-- ════════════════════════════════════════════════════════════
--  A Great Hair Day · Zeitverwaltung
--  ENTWURF – NOCH NICHT IM LIVE-PROJEKT AUSFÜHREN.
--  Erst gemeinsam durchsehen (siehe ZEITVERWALTUNG.md, „Offene Fragen“),
--  dann im Supabase SQL-Editor ausführen. Sicher mehrfach ausführbar.
--
--  Setzt voraus: rls_haertung_abwesenheit.sql, rls_haertung_abw_team_spalten.sql,
--  ausgeschieden_mitarbeitende.sql (abw_team, abw_anfragen,
--  abw_is_owner(), abw_current_person_id()).
--
--  Grundsätze (CLAUDE.md):
--    * Jede neue Tabelle hat RLS ab dem Anlegen, anon bekommt nichts.
--    * Wer Chefin/Vorgesetzte/r ist, entscheidet die Datenbank – nie der Browser.
--    * Arbeitszeiten werden NICHT direkt per REST geschrieben, sondern nur über
--      SECURITY-DEFINER-Funktionen: Stempeln mit Serverzeit, jede Änderung
--      mit Pflicht-Grund und Protokoll, abgeschlossene Monate gesperrt.
--
--  Personen-Stammdaten bleiben in abw_team (eine zentrale Personenliste für
--  Abwesenheiten UND Zeiterfassung). Urlaub/Krankenstand bleiben in abw_anfragen.
-- ════════════════════════════════════════════════════════════

-- ── Arbeitszeitmodelle ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS zeit_arbeitsmodelle (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name      text NOT NULL,
  std_mo    numeric(4,2) NOT NULL DEFAULT 0 CHECK (std_mo BETWEEN 0 AND 12),
  std_di    numeric(4,2) NOT NULL DEFAULT 0 CHECK (std_di BETWEEN 0 AND 12),
  std_mi    numeric(4,2) NOT NULL DEFAULT 0 CHECK (std_mi BETWEEN 0 AND 12),
  std_do    numeric(4,2) NOT NULL DEFAULT 0 CHECK (std_do BETWEEN 0 AND 12),
  std_fr    numeric(4,2) NOT NULL DEFAULT 0 CHECK (std_fr BETWEEN 0 AND 12),
  std_sa    numeric(4,2) NOT NULL DEFAULT 0 CHECK (std_sa BETWEEN 0 AND 12),
  std_so    numeric(4,2) NOT NULL DEFAULT 0 CHECK (std_so BETWEEN 0 AND 12),
  beginn    time NOT NULL DEFAULT '09:00',
  aktiv     boolean NOT NULL DEFAULT true
);
ALTER TABLE zeit_arbeitsmodelle ENABLE ROW LEVEL SECURITY;

-- ── Zeit-Profil je Person (Ergänzung zu abw_team) ──────────────
-- Rolle „Admin“ = abw_team.role = 'owner' (bestehend). Vorgesetzte ergeben
-- sich aus vorgesetzter_id: wer bei jemandem eingetragen ist, darf dort
-- genehmigen und korrigieren.
CREATE TABLE IF NOT EXISTS zeit_profil (
  person_id        text PRIMARY KEY REFERENCES abw_team(id),
  personalnr       text UNIQUE,
  abteilung        text,
  funktion         text,
  vorgesetzter_id  text REFERENCES abw_team(id),
  kjbg             boolean NOT NULL DEFAULT false,   -- Jugendliche unter 18
  saldo_start_min  integer NOT NULL DEFAULT 0,       -- Übertrag Zeitkonto beim Start
  urlaub_uebertrag numeric(4,1) NOT NULL DEFAULT 0,
  CHECK (vorgesetzter_id IS NULL OR vorgesetzter_id <> person_id)
);
ALTER TABLE zeit_profil ENABLE ROW LEVEL SECURITY;

-- Modell-Zuordnung mit „gültig ab“, damit Modellwechsel alte Monate nicht verändern
CREATE TABLE IF NOT EXISTS zeit_modell_zuordnung (
  person_id  text NOT NULL REFERENCES abw_team(id),
  gueltig_ab date NOT NULL,
  modell_id  uuid NOT NULL REFERENCES zeit_arbeitsmodelle(id),
  PRIMARY KEY (person_id, gueltig_ab)
);
ALTER TABLE zeit_modell_zuordnung ENABLE ROW LEVEL SECURITY;

-- ── Arbeitszeit-Buchungen (eine pro Person und Tag) ────────────
CREATE TABLE IF NOT EXISTS zeit_buchungen (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id    text NOT NULL REFERENCES abw_team(id),
  datum        date NOT NULL,
  beginn       time NOT NULL,
  ende         time,
  pause_min    integer NOT NULL DEFAULT 0 CHECK (pause_min >= 0),
  pause_start  time,
  quelle       text NOT NULL DEFAULT 'stempel' CHECK (quelle IN ('stempel', 'manuell', 'korrektur')),
  notiz        text,
  erstellt_am  timestamptz NOT NULL DEFAULT now(),
  geaendert_am timestamptz,
  UNIQUE (person_id, datum),
  CHECK (ende IS NULL OR ende >= beginn)
);
ALTER TABLE zeit_buchungen ENABLE ROW LEVEL SECURITY;

-- ── Korrekturanträge von Mitarbeiter/innen ─────────────────────
CREATE TABLE IF NOT EXISTS zeit_korrekturen (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id       text NOT NULL REFERENCES abw_team(id),
  datum           date NOT NULL,
  neu_beginn      time,            -- alle drei NULL = Eintrag löschen
  neu_ende        time,
  neu_pause_min   integer,
  grund           text NOT NULL CHECK (length(trim(grund)) > 0),
  status          text NOT NULL DEFAULT 'offen' CHECK (status IN ('offen', 'genehmigt', 'abgelehnt')),
  beantragt_von   text NOT NULL REFERENCES abw_team(id),
  beantragt_am    timestamptz NOT NULL DEFAULT now(),
  entschieden_von text REFERENCES abw_team(id),
  entschieden_am  timestamptz
);
ALTER TABLE zeit_korrekturen ENABLE ROW LEVEL SECURITY;

-- ── Änderungsprotokoll (nur lesbar, geschrieben nur von Funktionen) ─
CREATE TABLE IF NOT EXISTS zeit_protokoll (
  id         bigserial PRIMARY KEY,
  am         timestamptz NOT NULL DEFAULT now(),
  von_person text,
  person_id  text NOT NULL,
  datum      date NOT NULL,
  aktion     text NOT NULL,
  alt        jsonb,
  neu        jsonb,
  grund      text
);
ALTER TABLE zeit_protokoll ENABLE ROW LEVEL SECURITY;

-- ── Monatsabschluss ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS zeit_monatsabschluss (
  person_id        text NOT NULL REFERENCES abw_team(id),
  monat            date NOT NULL CHECK (extract(day FROM monat) = 1),
  bestaetigt_am    timestamptz,
  abgeschlossen_am timestamptz,
  abgeschlossen_von text REFERENCES abw_team(id),
  PRIMARY KEY (person_id, monat)
);
ALTER TABLE zeit_monatsabschluss ENABLE ROW LEVEL SECURITY;

-- ── Ergänzungen an abw_anfragen (Krankenstand/Abwesenheiten) ───
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS au_bestaetigung boolean;
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS notiz text;
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS entschieden_von text REFERENCES abw_team(id);
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS entschieden_am timestamptz;

-- Nicht-anonym, sonst nichts: anon hat auf keiner Zeit-Tabelle etwas verloren
REVOKE ALL ON zeit_arbeitsmodelle, zeit_profil, zeit_modell_zuordnung, zeit_buchungen,
              zeit_korrekturen, zeit_protokoll, zeit_monatsabschluss FROM anon;

-- ════════════════════════════════════════════════════════════
--  Hilfsfunktionen (Rollen kommen aus der Datenbank, nicht vom Client)
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_ist_vorgesetzt_von(p_person text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM zeit_profil
    WHERE person_id = p_person
      AND vorgesetzter_id = abw_current_person_id()
      AND person_id <> abw_current_person_id()
  );
$$;

-- Genehmigen/Korrigieren: Chefin bei allen (auch bei sich), Vorgesetzte nur bei Unterstellten
CREATE OR REPLACE FUNCTION zeit_darf_verwalten(p_person text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT abw_is_owner() OR zeit_ist_vorgesetzt_von(p_person);
$$;

CREATE OR REPLACE FUNCTION zeit_darf_sehen(p_person text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_person = abw_current_person_id() OR zeit_darf_verwalten(p_person);
$$;

CREATE OR REPLACE FUNCTION zeit_monat_gesperrt(p_person text, p_datum date) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM zeit_monatsabschluss
    WHERE person_id = p_person
      AND monat = date_trunc('month', p_datum)::date
      AND abgeschlossen_am IS NOT NULL
  );
$$;

-- ════════════════════════════════════════════════════════════
--  RLS-Policies
-- ════════════════════════════════════════════════════════════
-- Modelle: alle Angemeldeten lesen, nur Chefin ändert
DROP POLICY IF EXISTS "zeit_modelle_select" ON zeit_arbeitsmodelle;
CREATE POLICY "zeit_modelle_select" ON zeit_arbeitsmodelle FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "zeit_modelle_write" ON zeit_arbeitsmodelle;
CREATE POLICY "zeit_modelle_write" ON zeit_arbeitsmodelle FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

-- Profil & Modellzuordnung: eigene + verwaltete lesen, nur Chefin ändert
DROP POLICY IF EXISTS "zeit_profil_select" ON zeit_profil;
CREATE POLICY "zeit_profil_select" ON zeit_profil FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_profil_write" ON zeit_profil;
CREATE POLICY "zeit_profil_write" ON zeit_profil FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

DROP POLICY IF EXISTS "zeit_zuordnung_select" ON zeit_modell_zuordnung;
CREATE POLICY "zeit_zuordnung_select" ON zeit_modell_zuordnung FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_zuordnung_write" ON zeit_modell_zuordnung;
CREATE POLICY "zeit_zuordnung_write" ON zeit_modell_zuordnung FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());

-- Buchungen, Protokoll, Abschlüsse: nur lesen. Geschrieben wird ausschließlich
-- über die Funktionen unten (keine INSERT/UPDATE/DELETE-Policy = verboten).
DROP POLICY IF EXISTS "zeit_buchungen_select" ON zeit_buchungen;
CREATE POLICY "zeit_buchungen_select" ON zeit_buchungen FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_protokoll_select" ON zeit_protokoll;
CREATE POLICY "zeit_protokoll_select" ON zeit_protokoll FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_abschluss_select" ON zeit_monatsabschluss;
CREATE POLICY "zeit_abschluss_select" ON zeit_monatsabschluss FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));

-- Korrekturanträge: lesen wie Buchungen; anlegen nur für sich selbst, als „offen“,
-- und nicht in abgeschlossenen Monaten. Entscheiden nur per Funktion.
DROP POLICY IF EXISTS "zeit_korrekturen_select" ON zeit_korrekturen;
CREATE POLICY "zeit_korrekturen_select" ON zeit_korrekturen FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_korrekturen_insert" ON zeit_korrekturen;
CREATE POLICY "zeit_korrekturen_insert" ON zeit_korrekturen FOR INSERT TO authenticated
  WITH CHECK (
    person_id = abw_current_person_id()
    AND beantragt_von = abw_current_person_id()
    AND status = 'offen'
    AND entschieden_von IS NULL
    AND datum <= (now() AT TIME ZONE 'Europe/Vienna')::date
    AND NOT zeit_monat_gesperrt(person_id, datum)
  );

-- ════════════════════════════════════════════════════════════
--  Sicherheitsnetz: abgeschlossene Monate sind auch für Funktionen tabu
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION zeit_buchungen_sperre() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP <> 'INSERT' AND zeit_monat_gesperrt(OLD.person_id, OLD.datum) THEN
    RAISE EXCEPTION 'Monat % ist abgeschlossen', to_char(OLD.datum, 'MM/YYYY');
  END IF;
  IF TG_OP <> 'DELETE' AND zeit_monat_gesperrt(NEW.person_id, NEW.datum) THEN
    RAISE EXCEPTION 'Monat % ist abgeschlossen', to_char(NEW.datum, 'MM/YYYY');
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
DROP TRIGGER IF EXISTS zeit_buchungen_sperre ON zeit_buchungen;
CREATE TRIGGER zeit_buchungen_sperre BEFORE INSERT OR UPDATE OR DELETE ON zeit_buchungen
  FOR EACH ROW EXECUTE FUNCTION zeit_buchungen_sperre();

-- ════════════════════════════════════════════════════════════
--  Funktionen (RPC) – der einzige Schreibweg für Arbeitszeiten
-- ════════════════════════════════════════════════════════════

-- Stempeln: Uhrzeit vom Server (Europe/Vienna), Person aus dem Login.
-- p_aktion: 'kommen' | 'pause_start' | 'pause_ende' | 'gehen'
CREATE OR REPLACE FUNCTION zeit_stempeln(p_aktion text) RETURNS zeit_buchungen
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_person text := abw_current_person_id();
  v_jetzt  timestamp := now() AT TIME ZONE 'Europe/Vienna';
  v_datum  date := v_jetzt::date;
  v_zeit   time := date_trunc('minute', v_jetzt)::time;
  b        zeit_buchungen;
BEGIN
  IF v_person IS NULL THEN RAISE EXCEPTION 'Nicht angemeldet'; END IF;
  SELECT * INTO b FROM zeit_buchungen WHERE person_id = v_person AND datum = v_datum FOR UPDATE;
  IF p_aktion = 'kommen' THEN
    IF FOUND THEN RAISE EXCEPTION 'Heute bereits eingestempelt'; END IF;
    INSERT INTO zeit_buchungen (person_id, datum, beginn, quelle)
      VALUES (v_person, v_datum, v_zeit, 'stempel') RETURNING * INTO b;
  ELSIF NOT FOUND OR b.ende IS NOT NULL THEN
    RAISE EXCEPTION 'Kein laufender Dienst';
  ELSIF p_aktion = 'pause_start' THEN
    IF b.pause_start IS NOT NULL THEN RAISE EXCEPTION 'Pause läuft bereits'; END IF;
    UPDATE zeit_buchungen SET pause_start = v_zeit WHERE id = b.id RETURNING * INTO b;
  ELSIF p_aktion = 'pause_ende' THEN
    IF b.pause_start IS NULL THEN RAISE EXCEPTION 'Keine laufende Pause'; END IF;
    UPDATE zeit_buchungen
      SET pause_min = pause_min + (extract(epoch FROM v_zeit - pause_start) / 60)::int, pause_start = NULL
      WHERE id = b.id RETURNING * INTO b;
  ELSIF p_aktion = 'gehen' THEN
    UPDATE zeit_buchungen
      SET pause_min = pause_min + COALESCE((extract(epoch FROM v_zeit - pause_start) / 60)::int, 0),
          pause_start = NULL, ende = v_zeit
      WHERE id = b.id RETURNING * INTO b;
  ELSE
    RAISE EXCEPTION 'Unbekannte Aktion: %', p_aktion;
  END IF;
  RETURN b;
END $$;

-- Direkte Änderung durch Chefin/Vorgesetzte – immer mit Grund, immer protokolliert
CREATE OR REPLACE FUNCTION zeit_buchung_aendern(
  p_person text, p_datum date, p_beginn time, p_ende time, p_pause_min integer,
  p_grund text, p_loeschen boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_alt   zeit_buchungen;
  v_gab   boolean;
BEGIN
  IF NOT zeit_darf_verwalten(p_person) THEN RAISE EXCEPTION 'Keine Berechtigung'; END IF;
  IF COALESCE(trim(p_grund), '') = '' THEN RAISE EXCEPTION 'Grund fehlt'; END IF;
  IF p_datum > (now() AT TIME ZONE 'Europe/Vienna')::date THEN RAISE EXCEPTION 'Datum liegt in der Zukunft'; END IF;
  SELECT * INTO v_alt FROM zeit_buchungen WHERE person_id = p_person AND datum = p_datum FOR UPDATE;
  v_gab := FOUND;
  IF p_loeschen THEN
    IF NOT v_gab THEN RAISE EXCEPTION 'Kein Eintrag vorhanden'; END IF;
    DELETE FROM zeit_buchungen WHERE id = v_alt.id;
  ELSE
    IF p_beginn IS NULL OR p_ende IS NULL OR p_ende <= p_beginn THEN RAISE EXCEPTION 'Beginn/Ende ungültig'; END IF;
    INSERT INTO zeit_buchungen (person_id, datum, beginn, ende, pause_min, quelle)
      VALUES (p_person, p_datum, p_beginn, p_ende, COALESCE(p_pause_min, 0), 'manuell')
    ON CONFLICT (person_id, datum) DO UPDATE
      SET beginn = EXCLUDED.beginn, ende = EXCLUDED.ende, pause_min = EXCLUDED.pause_min,
          pause_start = NULL, quelle = 'korrektur', geaendert_am = now();
  END IF;
  INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, alt, neu, grund)
  VALUES (
    abw_current_person_id(), p_person, p_datum,
    CASE WHEN p_loeschen THEN 'gelöscht' WHEN v_gab THEN 'korrigiert' ELSE 'nachgetragen' END,
    CASE WHEN v_gab THEN jsonb_build_object('beginn', v_alt.beginn, 'ende', v_alt.ende, 'pause_min', v_alt.pause_min) END,
    CASE WHEN NOT p_loeschen THEN jsonb_build_object('beginn', p_beginn, 'ende', p_ende, 'pause_min', COALESCE(p_pause_min, 0)) END,
    p_grund
  );
END $$;

CREATE OR REPLACE FUNCTION zeit_korrektur_entscheiden(p_id uuid, p_genehmigt boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE k zeit_korrekturen;
BEGIN
  SELECT * INTO k FROM zeit_korrekturen WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR k.status <> 'offen' THEN RAISE EXCEPTION 'Antrag nicht (mehr) offen'; END IF;
  IF NOT zeit_darf_verwalten(k.person_id) THEN RAISE EXCEPTION 'Keine Berechtigung'; END IF;
  IF p_genehmigt THEN
    PERFORM zeit_buchung_aendern(k.person_id, k.datum, k.neu_beginn, k.neu_ende, k.neu_pause_min,
                                 'Korrekturantrag: ' || k.grund, k.neu_beginn IS NULL);
  END IF;
  UPDATE zeit_korrekturen
    SET status = CASE WHEN p_genehmigt THEN 'genehmigt' ELSE 'abgelehnt' END,
        entschieden_von = abw_current_person_id(), entschieden_am = now()
    WHERE id = p_id;
END $$;

-- Mitarbeiter/in bestätigt einen vergangenen Monat
CREATE OR REPLACE FUNCTION zeit_monat_bestaetigen(p_monat date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_person text := abw_current_person_id(); v_monat date := date_trunc('month', p_monat)::date;
BEGIN
  IF v_person IS NULL THEN RAISE EXCEPTION 'Nicht angemeldet'; END IF;
  IF v_monat >= date_trunc('month', now() AT TIME ZONE 'Europe/Vienna')::date THEN RAISE EXCEPTION 'Monat ist noch nicht vorbei'; END IF;
  INSERT INTO zeit_monatsabschluss (person_id, monat, bestaetigt_am) VALUES (v_person, v_monat, now())
  ON CONFLICT (person_id, monat) DO UPDATE SET bestaetigt_am = now()
    WHERE zeit_monatsabschluss.abgeschlossen_am IS NULL;
END $$;

-- Chefin/Vorgesetzte schließt ab → Monat gesperrt
CREATE OR REPLACE FUNCTION zeit_monat_abschliessen(p_person text, p_monat date) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_monat date := date_trunc('month', p_monat)::date;
BEGIN
  IF NOT zeit_darf_verwalten(p_person) THEN RAISE EXCEPTION 'Keine Berechtigung'; END IF;
  IF v_monat >= date_trunc('month', now() AT TIME ZONE 'Europe/Vienna')::date THEN RAISE EXCEPTION 'Monat ist noch nicht vorbei'; END IF;
  IF EXISTS (SELECT 1 FROM zeit_korrekturen WHERE person_id = p_person AND status = 'offen'
             AND date_trunc('month', datum)::date = v_monat) THEN
    RAISE EXCEPTION 'Es gibt offene Korrekturanträge';
  END IF;
  IF EXISTS (SELECT 1 FROM zeit_buchungen WHERE person_id = p_person AND ende IS NULL
             AND date_trunc('month', datum)::date = v_monat) THEN
    RAISE EXCEPTION 'Ein Tag hat noch kein Arbeitsende';
  END IF;
  INSERT INTO zeit_monatsabschluss (person_id, monat, abgeschlossen_am, abgeschlossen_von)
    VALUES (p_person, v_monat, now(), abw_current_person_id())
  ON CONFLICT (person_id, monat) DO UPDATE
    SET abgeschlossen_am = now(), abgeschlossen_von = abw_current_person_id();
END $$;

-- Nur die Chefin darf wieder öffnen – mit Grund im Protokoll
CREATE OR REPLACE FUNCTION zeit_monat_oeffnen(p_person text, p_monat date, p_grund text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_monat date := date_trunc('month', p_monat)::date;
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Keine Berechtigung'; END IF;
  IF COALESCE(trim(p_grund), '') = '' THEN RAISE EXCEPTION 'Grund fehlt'; END IF;
  UPDATE zeit_monatsabschluss SET abgeschlossen_am = NULL, abgeschlossen_von = NULL
    WHERE person_id = p_person AND monat = v_monat;
  INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, grund)
    VALUES (abw_current_person_id(), p_person, v_monat, 'Monat wieder geöffnet', p_grund);
END $$;

-- Funktionen: nur für Angemeldete (Supabase gibt sonst auch anon EXECUTE)
REVOKE ALL ON FUNCTION zeit_stempeln(text), zeit_buchung_aendern(text, date, time, time, integer, text, boolean),
  zeit_korrektur_entscheiden(uuid, boolean), zeit_monat_bestaetigen(date),
  zeit_monat_abschliessen(text, date), zeit_monat_oeffnen(text, date, text),
  zeit_ist_vorgesetzt_von(text), zeit_darf_verwalten(text), zeit_darf_sehen(text),
  zeit_monat_gesperrt(text, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_stempeln(text), zeit_buchung_aendern(text, date, time, time, integer, text, boolean),
  zeit_korrektur_entscheiden(uuid, boolean), zeit_monat_bestaetigen(date),
  zeit_monat_abschliessen(text, date), zeit_monat_oeffnen(text, date, text),
  zeit_ist_vorgesetzt_von(text), zeit_darf_verwalten(text), zeit_darf_sehen(text),
  zeit_monat_gesperrt(text, date)
  TO authenticated;

-- ════════════════════════════════════════════════════════════
--  OPTIONAL, ERST NACH RÜCKSPRACHE: Vorgesetzte dürfen Urlaub/Abwesenheiten
--  ihres Teams genehmigen. Ändert eine LIVE-Policy der Abwesenheiten-App
--  (bisher: nur Chefin). Darum auskommentiert.
-- ════════════════════════════════════════════════════════════
-- DROP POLICY IF EXISTS "abw_anfragen_update" ON abw_anfragen;
-- CREATE POLICY "abw_anfragen_update" ON abw_anfragen FOR UPDATE TO authenticated
--   USING (abw_is_owner() OR zeit_ist_vorgesetzt_von(person_id))
--   WITH CHECK (abw_is_owner() OR zeit_ist_vorgesetzt_von(person_id));
