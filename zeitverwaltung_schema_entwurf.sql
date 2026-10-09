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
  aktiv     boolean NOT NULL DEFAULT true
);
ALTER TABLE zeit_arbeitsmodelle ENABLE ROW LEVEL SECURITY;

-- Fixer Dienstplan: Beginn, Ende, Pause je Wochentag (0 = Montag … 6 = Sonntag).
-- Kein Eintrag = frei. Sollstunden = Ende − Beginn − Pause.
-- gueltig_ab: jede Änderung ist eine neue Version, vergangene Tage behalten ihren Plan.
CREATE TABLE IF NOT EXISTS zeit_modell_tage (
  modell_id  uuid NOT NULL REFERENCES zeit_arbeitsmodelle(id) ON DELETE CASCADE,
  gueltig_ab date NOT NULL DEFAULT '2000-01-01',
  wochentag  smallint NOT NULL CHECK (wochentag BETWEEN 0 AND 6),
  beginn     time NOT NULL,
  ende       time NOT NULL,
  pause_min  integer NOT NULL DEFAULT 0 CHECK (pause_min >= 0),
  pause_beginn time,                 -- fixe Pausenzeit (optional), z. B. 11:30 → 11:30–12:30
  PRIMARY KEY (modell_id, gueltig_ab, wochentag),
  CHECK (ende > beginn)
);
ALTER TABLE zeit_modell_tage ENABLE ROW LEVEL SECURITY;
ALTER TABLE zeit_modell_tage ADD COLUMN IF NOT EXISTS pause_beginn time;

-- Gesetzliche Feiertage (einmal pro Jahr befüllen; die App berechnet sie ohnehin)
CREATE TABLE IF NOT EXISTS zeit_feiertage (
  datum date PRIMARY KEY,
  name  text NOT NULL
);
ALTER TABLE zeit_feiertage ENABLE ROW LEVEL SECURITY;

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
  geburtsdatum     date,                             -- unter 18 → KJBG, ab dem 18. Geburtstag automatisch AZG
  -- Urlaubsjahr = Arbeitsjahr (ab Eintrittsdatum). Startbestand beim Umstieg auf die App:
  urlaub_start     numeric(5,2),                     -- offene Urlaubstage am Stichtag (inkl. laufendem Urlaubsjahr)
  urlaub_start_am  date,                             -- Stichtag des Startbestands
  austritt_art     text,                             -- Art der Beendigung (Austrittsdatum = abw_team.ausgeschieden_am)
  austritt_notiz   text,
  lehrbeginn       date,                             -- nur Lehrlinge; Lehrjahr wird daraus berechnet
  bs_tag1          smallint CHECK (bs_tag1 BETWEEN 0 AND 6),  -- fixer Berufsschultag (ganz)
  bs_tag2          smallint CHECK (bs_tag2 BETWEEN 0 AND 6),  -- halber Tag im 1. Lehrjahr
  saldo_start_min  integer NOT NULL DEFAULT 0,       -- Übertrag Zeitkonto beim Start
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
  quelle       text NOT NULL DEFAULT 'stempel' CHECK (quelle IN ('stempel', 'manuell', 'korrektur', 'auto')),
  auto         text[] NOT NULL DEFAULT '{}',   -- was laut Dienstplan ergänzt wurde: kommen/gehen/pause/tag
  notiz        text,
  beginn_roh   time,                   -- echte Stempelzeit, wenn auf den Dienstplan gerundet wurde
  ende_roh     time,
  erstellt_am  timestamptz NOT NULL DEFAULT now(),
  geaendert_am timestamptz,
  UNIQUE (person_id, datum),
  CHECK (ende IS NULL OR ende >= beginn)
);
ALTER TABLE zeit_buchungen ENABLE ROW LEVEL SECURITY;
ALTER TABLE zeit_buchungen ADD COLUMN IF NOT EXISTS beginn_roh time;
ALTER TABLE zeit_buchungen ADD COLUMN IF NOT EXISTS ende_roh time;

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

-- ── Verlauf der Stammdaten (angelegt, geändert, Austritt) ──────
-- Nur lesbar für Chefin/Vorgesetzte und die Person selbst; geschrieben per Trigger.
CREATE TABLE IF NOT EXISTS zeit_personal_verlauf (
  id         bigserial PRIMARY KEY,
  am         timestamptz NOT NULL DEFAULT now(),
  von_person text,
  person_id  text NOT NULL REFERENCES abw_team(id),
  aktion     text NOT NULL,
  details    text
);
ALTER TABLE zeit_personal_verlauf ENABLE ROW LEVEL SECURITY;

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
-- Halbe Tage (z. B. halber Berufsschultag im 1. Lehrjahr): 1 = ganzer Tag
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS anteil numeric(3,2) NOT NULL DEFAULT 1;
ALTER TABLE abw_anfragen DROP CONSTRAINT IF EXISTS abw_anfragen_anteil_check;
ALTER TABLE abw_anfragen ADD CONSTRAINT abw_anfragen_anteil_check CHECK (anteil IN (0.5, 1));
-- Arztbesuch u. ä. in Stunden: angerechnete Minuten (höchstens die Sollzeit des Tages)
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS minuten integer CHECK (minuten > 0);
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS zeit_art text;   -- feinere Art: berufsschule, arzt, pflege …
ALTER TABLE abw_anfragen ADD COLUMN IF NOT EXISTS offen boolean NOT NULL DEFAULT false;  -- Krankenstand ohne Ende
-- Berufsschultage je Lehrjahr kommen in die bestehende abw_einstellungen,
-- Schlüssel 'bs_tage_je_lehrjahr', z. B. {"1":1.5,"2":1,"3":1,"4":1} (Wien).

-- Nicht-anonym, sonst nichts: anon hat auf keiner Zeit-Tabelle etwas verloren
REVOKE ALL ON zeit_arbeitsmodelle, zeit_modell_tage, zeit_feiertage, zeit_profil, zeit_personal_verlauf, zeit_modell_zuordnung, zeit_buchungen,
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

-- Dienstplan einer Person an einem Tag (gültige Modellzuordnung zu diesem Datum)
CREATE OR REPLACE FUNCTION zeit_plan_am(p_person text, p_datum date) RETURNS zeit_modell_tage
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT t.* FROM zeit_modell_zuordnung z
  JOIN zeit_modell_tage t ON t.modell_id = z.modell_id AND t.wochentag = extract(isodow FROM p_datum)::int - 1
   AND t.gueltig_ab = (SELECT max(gueltig_ab) FROM zeit_modell_tage WHERE modell_id = z.modell_id AND gueltig_ab <= p_datum)
  WHERE z.person_id = p_person AND z.gueltig_ab <= p_datum
    AND z.gueltig_ab = (SELECT max(gueltig_ab) FROM zeit_modell_zuordnung WHERE person_id = p_person AND gueltig_ab <= p_datum);
$$;

CREATE OR REPLACE FUNCTION zeit_jugendlich(p_person text, p_datum date) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT geburtsdatum + interval '18 years' > p_datum FROM zeit_profil WHERE person_id = p_person), false);
$$;

-- Wird nachträglich eine Pause gebraucht? (§ 11 AZG: > 6 h; § 15 KJBG: > 4,5 h → 30 min)
CREATE OR REPLACE FUNCTION zeit_pause_noetig(p_person text, b zeit_buchungen) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT b.ende IS NOT NULL AND b.pause_min < 30
     AND extract(epoch FROM b.ende - b.beginn) / 60 - b.pause_min
         > CASE WHEN zeit_jugendlich(p_person, b.datum) THEN 270 ELSE 360 END;
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

DROP POLICY IF EXISTS "zeit_modell_tage_select" ON zeit_modell_tage;
CREATE POLICY "zeit_modell_tage_select" ON zeit_modell_tage FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "zeit_modell_tage_write" ON zeit_modell_tage;
CREATE POLICY "zeit_modell_tage_write" ON zeit_modell_tage FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());
DROP POLICY IF EXISTS "zeit_feiertage_select" ON zeit_feiertage;
CREATE POLICY "zeit_feiertage_select" ON zeit_feiertage FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "zeit_feiertage_write" ON zeit_feiertage;
CREATE POLICY "zeit_feiertage_write" ON zeit_feiertage FOR ALL TO authenticated
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
DROP POLICY IF EXISTS "zeit_verlauf_select" ON zeit_personal_verlauf;
CREATE POLICY "zeit_verlauf_select" ON zeit_personal_verlauf FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
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

-- Austritt (abw_team.ausgeschieden_am) automatisch im Verlauf dokumentieren
CREATE OR REPLACE FUNCTION zeit_austritt_verlauf() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.ausgeschieden_am IS DISTINCT FROM OLD.ausgeschieden_am THEN
    INSERT INTO zeit_personal_verlauf (von_person, person_id, aktion, details)
    VALUES (abw_current_person_id(), NEW.id,
            CASE WHEN NEW.ausgeschieden_am IS NULL THEN 'Austritt rückgängig gemacht' ELSE 'Austritt eingetragen' END,
            CASE WHEN NEW.ausgeschieden_am IS NULL THEN 'war ' || to_char(OLD.ausgeschieden_am, 'DD.MM.YYYY')
                 ELSE 'letzter Arbeitstag ' || to_char(NEW.ausgeschieden_am, 'DD.MM.YYYY') END);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zeit_austritt_verlauf ON abw_team;
CREATE TRIGGER zeit_austritt_verlauf AFTER UPDATE OF ausgeschieden_am ON abw_team
  FOR EACH ROW EXECUTE FUNCTION zeit_austritt_verlauf();

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

-- Automatische Pausen nur mit schriftlicher Pausen-Vereinbarung je Person
-- (§ 26 Abs 5 AZG). Derzeit gibt es nur den Kollektivvertrag → AUS.
-- Sobald die Vereinbarungen unterschrieben sind: Funktion auf "SELECT true" ändern.
CREATE OR REPLACE FUNCTION zeit_auto_pause_erlaubt() RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT false $$;

-- Stempel-Logik für eine Person. INTERN – nicht für Benutzer freigegeben;
-- aufgerufen von zeit_stempeln (Handy) und zeit_terminal_stempeln (Tablet).
-- Uhrzeit immer vom Server (Europe/Vienna).
-- p_aktion: 'kommen' | 'pause_start' | 'pause_ende' | 'gehen' | 'nur_gehen' (Kommen vergessen)
-- p_auto_pause: fehlende Pause beim Gehen laut Dienstplan eintragen
CREATE OR REPLACE FUNCTION zeit__stempeln_fuer(p_person text, p_aktion text, p_auto_pause boolean) RETURNS zeit_buchungen
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_person text := p_person;
  v_jetzt  timestamp := now() AT TIME ZONE 'Europe/Vienna';
  v_datum  date := v_jetzt::date;
  v_zeit   time := date_trunc('minute', v_jetzt)::time;
  b        zeit_buchungen;
  v_plan   zeit_modell_tage;
BEGIN
  IF v_person IS NULL THEN RAISE EXCEPTION 'Keine Person'; END IF;
  v_plan := zeit_plan_am(v_person, v_datum);
  SELECT * INTO b FROM zeit_buchungen WHERE person_id = v_person AND datum = v_datum FOR UPDATE;
  IF p_aktion = 'nur_gehen' THEN
    IF FOUND THEN RAISE EXCEPTION 'Heute bereits eingestempelt'; END IF;
    IF v_plan.beginn IS NULL OR v_plan.beginn >= v_zeit THEN RAISE EXCEPTION 'Kein Dienstplan-Beginn vor jetzt'; END IF;
    INSERT INTO zeit_buchungen (person_id, datum, beginn, quelle, auto)
      VALUES (v_person, v_datum, v_plan.beginn, 'stempel', ARRAY['kommen']) RETURNING * INTO b;
    INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, grund)
      VALUES (abw_current_person_id(), v_person, v_datum, 'automatisch ergänzt: Kommen', 'Kommen vergessen – Beginn laut Dienstplan');
    p_aktion := 'gehen';
  END IF;
  IF p_aktion = 'kommen' THEN
    IF FOUND THEN RAISE EXCEPTION 'Heute bereits eingestempelt'; END IF;
    INSERT INTO zeit_buchungen (person_id, datum, beginn, beginn_roh, quelle)
      VALUES (v_person, v_datum, zeit_runden(v_zeit, v_plan.beginn, 'beginn'),
              nullif(v_zeit, zeit_runden(v_zeit, v_plan.beginn, 'beginn')), 'stempel') RETURNING * INTO b;
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
          pause_start = NULL,
          ende = greatest(zeit_runden(v_zeit, v_plan.ende, 'ende'), beginn),
          ende_roh = nullif(v_zeit, greatest(zeit_runden(v_zeit, v_plan.ende, 'ende'), beginn))
      WHERE id = b.id RETURNING * INTO b;
    IF p_auto_pause AND zeit_auto_pause_erlaubt() AND zeit_pause_noetig(v_person, b) THEN
      UPDATE zeit_buchungen SET pause_min = greatest(COALESCE(v_plan.pause_min, 0), 30), auto = auto || 'pause'::text
        WHERE id = b.id RETURNING * INTO b;
      INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, grund)
        VALUES (abw_current_person_id(), v_person, v_datum, 'automatisch ergänzt: Pause', 'keine Pause gestempelt – laut Dienstplan');
    END IF;
  ELSE
    RAISE EXCEPTION 'Unbekannte Aktion: %', p_aktion;
  END IF;
  RETURN b;
END $$;

-- ════════════════════════════════════════════════════════════
--  WO DARF GESTEMPELT WERDEN? (Einstellung der Chefin)
--  'tablet'   = Handy darf NICHT stempeln, nur das Salon-Tablet (Standard)
--  'salon'    = Handy nur aus dem Salon-WLAN (öffentliche IP in zeit_salon_netze)
--  'ueberall' = Handy ohne Einschränkung
--  Das Tablet (zeit_terminal_stempeln) ist davon nicht betroffen.
--  Geprüft wird am Server – die Einstellung in der App blendet nur Knöpfe aus.
-- ════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS zeit_stempel_regel (
  id    boolean PRIMARY KEY DEFAULT true CHECK (id),   -- genau eine Zeile
  modus text NOT NULL DEFAULT 'tablet' CHECK (modus IN ('tablet', 'salon', 'ueberall')),
  geaendert_am timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE zeit_stempel_regel ENABLE ROW LEVEL SECURITY;  -- keine Policy: nur über Funktionen
-- Rundung auf den Dienstplan (wie TimeMoto): Stempelung im Fenster zählt als Plan-Zeit
ALTER TABLE zeit_stempel_regel ADD COLUMN IF NOT EXISTS rundung boolean NOT NULL DEFAULT true;
ALTER TABLE zeit_stempel_regel ADD COLUMN IF NOT EXISTS rund_beginn_vor  integer NOT NULL DEFAULT 30 CHECK (rund_beginn_vor  BETWEEN 0 AND 120);
ALTER TABLE zeit_stempel_regel ADD COLUMN IF NOT EXISTS rund_beginn_nach integer NOT NULL DEFAULT 5  CHECK (rund_beginn_nach BETWEEN 0 AND 60);
ALTER TABLE zeit_stempel_regel ADD COLUMN IF NOT EXISTS rund_ende_vor    integer NOT NULL DEFAULT 5  CHECK (rund_ende_vor    BETWEEN 0 AND 60);
ALTER TABLE zeit_stempel_regel ADD COLUMN IF NOT EXISTS rund_ende_nach   integer NOT NULL DEFAULT 15 CHECK (rund_ende_nach   BETWEEN 0 AND 120);
INSERT INTO zeit_stempel_regel (id) VALUES (true) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS zeit_salon_netze (
  ip          inet PRIMARY KEY,          -- öffentliche IP des Salon-Internetanschlusses
  name        text NOT NULL DEFAULT 'Salon-WLAN',
  angelegt_am timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE zeit_salon_netze ENABLE ROW LEVEL SECURITY;    -- keine Policy: nur über Funktionen
REVOKE ALL ON zeit_stempel_regel, zeit_salon_netze FROM anon, authenticated;

-- Außentermine (z. B. Hochzeit): an diesem Tag darf die Person überall am Handy stempeln.
-- Eintragen/Löschen nur die Chefin (RLS), sehen darf es, wer die Person sehen darf.
CREATE TABLE IF NOT EXISTS zeit_aussentermine (
  person_id   text NOT NULL REFERENCES abw_team(id),
  datum       date NOT NULL,
  notiz       text,
  angelegt_von text,
  angelegt_am timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (person_id, datum)
);
ALTER TABLE zeit_aussentermine ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON zeit_aussentermine FROM anon;

-- Öffentliche IP des Aufrufers. NUR cf-connecting-ip wird vertraut (setzt die
-- Supabase-Edge selbst, vom Client nicht fälschbar); X-Forwarded-For kann der
-- Client vorne ergänzen und wird darum NICHT verwendet. Fehlt der Header → NULL
-- → im Modus 'salon' wird abgelehnt (lieber zu streng als zu offen).
-- VOR GO-LIVE TESTEN: Aufruf mit gefälschtem X-Forwarded-For muss scheitern.
CREATE OR REPLACE FUNCTION zeit_client_ip() RETURNS inet
LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
  v := nullif(trim(current_setting('request.headers', true)::json->>'cf-connecting-ip'), '');
  RETURN v::inet;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION zeit_handy_stempeln_erlaubt() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM zeit_aussentermine
                 WHERE person_id = abw_current_person_id() AND datum = (now() AT TIME ZONE 'Europe/Vienna')::date)
  OR CASE COALESCE((SELECT modus FROM zeit_stempel_regel), 'tablet')
    WHEN 'ueberall' THEN true
    WHEN 'salon' THEN EXISTS (SELECT 1 FROM zeit_salon_netze WHERE ip = zeit_client_ip())
    ELSE false END;
$$;

-- Für die App: welcher Modus gilt, und ist dieses Gerät gerade im Salon-Netz?
CREATE OR REPLACE FUNCTION zeit_stempel_status() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object('modus', COALESCE((SELECT modus FROM zeit_stempel_regel), 'tablet'),
                            'erlaubt', zeit_handy_stempeln_erlaubt());
$$;

-- Nur die Chefin: Modus setzen
CREATE OR REPLACE FUNCTION zeit_stempel_regel_setzen(p_modus text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Nur die Chefin'; END IF;
  UPDATE zeit_stempel_regel SET modus = p_modus, geaendert_am = now() WHERE id;
  INSERT INTO zeit_protokoll (von_person, person_id, datum, aktion, grund)
    VALUES (abw_current_person_id(), abw_current_person_id(), (now() AT TIME ZONE 'Europe/Vienna')::date, 'Einstellung Stempeln: ' || p_modus, NULL);
END $$;

-- Nur die Chefin: Rundung einstellen
CREATE OR REPLACE FUNCTION zeit_rundung_setzen(p_an boolean, p_beginn_vor integer, p_beginn_nach integer, p_ende_vor integer, p_ende_nach integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Nur die Chefin'; END IF;
  UPDATE zeit_stempel_regel SET rundung = p_an, rund_beginn_vor = p_beginn_vor, rund_beginn_nach = p_beginn_nach,
    rund_ende_vor = p_ende_vor, rund_ende_nach = p_ende_nach, geaendert_am = now() WHERE id;
END $$;
REVOKE ALL ON FUNCTION zeit_rundung_setzen(boolean, integer, integer, integer, integer) FROM anon, public;
GRANT EXECUTE ON FUNCTION zeit_rundung_setzen(boolean, integer, integer, integer, integer) TO authenticated;

-- Stempelzeit auf Plan-Beginn/-Ende runden, wenn sie im eingestellten Fenster liegt
CREATE OR REPLACE FUNCTION zeit_runden(p_zeit time, p_plan time, p_art text) RETURNS time
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p_plan IS NOT NULL AND r.rundung AND
    p_zeit BETWEEN p_plan - make_interval(mins => CASE WHEN p_art = 'beginn' THEN r.rund_beginn_vor ELSE r.rund_ende_vor END)
               AND p_plan + make_interval(mins => CASE WHEN p_art = 'beginn' THEN r.rund_beginn_nach ELSE r.rund_ende_nach END)
    THEN p_plan ELSE p_zeit END
  FROM zeit_stempel_regel r WHERE r.id;
$$;
REVOKE ALL ON FUNCTION zeit_runden(time, time, text) FROM anon, public;

-- Nur die Chefin, im Salon am Salon-WLAN aufgerufen: aktuelle IP als Salon-Netz merken.
-- (Wechselt der Internetanbieter die IP, einfach nochmal im Salon tippen.)
CREATE OR REPLACE FUNCTION zeit_salon_netz_merken(p_name text DEFAULT 'Salon-WLAN') RETURNS inet
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v inet := zeit_client_ip();
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Nur die Chefin'; END IF;
  IF v IS NULL THEN RAISE EXCEPTION 'IP-Adresse nicht ermittelbar'; END IF;
  INSERT INTO zeit_salon_netze (ip, name) VALUES (v, p_name)
    ON CONFLICT (ip) DO UPDATE SET name = excluded.name;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION zeit_salon_netz_entfernen(p_ip inet) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Nur die Chefin'; END IF;
  DELETE FROM zeit_salon_netze WHERE ip = p_ip;
END $$;

CREATE OR REPLACE FUNCTION zeit_salon_netze_liste() RETURNS SETOF zeit_salon_netze
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT abw_is_owner() THEN RAISE EXCEPTION 'Nur die Chefin'; END IF;
  RETURN QUERY SELECT * FROM zeit_salon_netze ORDER BY angelegt_am;
END $$;

DROP POLICY IF EXISTS zeit_aussentermine_lesen ON zeit_aussentermine;
CREATE POLICY zeit_aussentermine_lesen ON zeit_aussentermine FOR SELECT TO authenticated
  USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS zeit_aussentermine_chefin ON zeit_aussentermine;
CREATE POLICY zeit_aussentermine_chefin ON zeit_aussentermine FOR ALL TO authenticated
  USING (abw_is_owner()) WITH CHECK (abw_is_owner());
GRANT SELECT, INSERT, UPDATE, DELETE ON zeit_aussentermine TO authenticated;

REVOKE ALL ON FUNCTION zeit_handy_stempeln_erlaubt(), zeit_client_ip() FROM anon, public;
REVOKE ALL ON FUNCTION zeit_stempel_status(), zeit_stempel_regel_setzen(text), zeit_salon_netz_merken(text),
  zeit_salon_netz_entfernen(inet), zeit_salon_netze_liste() FROM anon, public;
GRANT EXECUTE ON FUNCTION zeit_stempel_status(), zeit_stempel_regel_setzen(text), zeit_salon_netz_merken(text),
  zeit_salon_netz_entfernen(inet), zeit_salon_netze_liste() TO authenticated;

-- HANDY: Person kommt aus dem eigenen Login
DROP FUNCTION IF EXISTS zeit_stempeln(text);
CREATE OR REPLACE FUNCTION zeit_stempeln(p_aktion text, p_auto_pause boolean DEFAULT true) RETURNS zeit_buchungen
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF abw_current_person_id() IS NULL THEN RAISE EXCEPTION 'Nicht angemeldet'; END IF;
  IF NOT zeit_handy_stempeln_erlaubt() THEN
    RAISE EXCEPTION 'Stempeln nur im Salon (am Salon-Tablet%)',
      CASE WHEN (SELECT modus FROM zeit_stempel_regel) = 'salon' THEN ' oder im Salon-WLAN' ELSE '' END;
  END IF;
  RETURN zeit__stempeln_fuer(abw_current_person_id(), p_aktion, p_auto_pause);
END $$;

-- ════════════════════════════════════════════════════════════
--  STEMPEL-TABLET IM SALON
--  * Das Tablet meldet sich EINMAL mit einem eigenen Gerätezugang an
--    (Supabase Auth, z. B. terminal.salon@…; Passwort nur die Chefin).
--    Die Sitzung bleibt per Supabase-Refresh-Token bestehen (CLAUDE.md Regel 4).
--  * Nur in zeit_terminals eingetragene Gerätezugänge dürfen Tablet-Funktionen
--    nutzen. Ein Mitarbeiter-Handy kann also NICHT für andere stempeln.
--  * Jede Person bestätigt mit ihrer persönlichen PIN – derselben wie beim
--    Login der Abwesenheiten-App. Geprüft wird nur hier am Server gegen den
--    Passwort-Hash in auth.users; die PIN wird nirgends gespeichert.
--  * Nach 5 falschen PINs in 15 Minuten ist die Person 15 Minuten gesperrt.
-- ════════════════════════════════════════════════════════════
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS zeit_terminals (
  user_id     uuid PRIMARY KEY,          -- auth.users.id des Tablet-Zugangs
  name        text NOT NULL,             -- z. B. 'Tablet Empfang'
  aktiv       boolean NOT NULL DEFAULT true,
  angelegt_am timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE zeit_terminals ENABLE ROW LEVEL SECURITY;   -- keine Policy: nur per SQL/Funktion

CREATE TABLE IF NOT EXISTS zeit_pin_versuche (
  id        bigserial PRIMARY KEY,
  person_id text NOT NULL,
  am        timestamptz NOT NULL DEFAULT now(),
  ok        boolean NOT NULL
);
ALTER TABLE zeit_pin_versuche ENABLE ROW LEVEL SECURITY; -- keine Policy
REVOKE ALL ON zeit_terminals, zeit_pin_versuche FROM anon, authenticated;

CREATE OR REPLACE FUNCTION zeit_ist_terminal() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM zeit_terminals WHERE user_id = auth.uid() AND aktiv);
$$;

-- Liste fürs Tablet: nur Vorname und heutiger Stempel-Status, keine sonstigen Daten
CREATE OR REPLACE FUNCTION zeit_terminal_liste()
RETURNS TABLE (person_id text, vorname text, status text, seit time)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT zeit_ist_terminal() THEN RAISE EXCEPTION 'Kein Stempel-Tablet'; END IF;
  RETURN QUERY
    SELECT t.id, split_part(trim(t.name), ' ', 1),
           CASE WHEN b.id IS NULL THEN 'aus' WHEN b.ende IS NOT NULL THEN 'fertig'
                WHEN b.pause_start IS NOT NULL THEN 'pause' ELSE 'da' END,
           COALESCE(b.pause_start, b.beginn)
    FROM abw_team t
    LEFT JOIN zeit_buchungen b ON b.person_id = t.id AND b.datum = (now() AT TIME ZONE 'Europe/Vienna')::date
    WHERE t.ausgeschieden_am IS NULL
    ORDER BY t.name;
END $$;

-- PIN gegen den Login-Hash prüfen (Login-Passwort = PIN + '-ghd', siehe abwesenheiten.html)
CREATE OR REPLACE FUNCTION zeit__pin_ok(p_person text, p_pin text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_hash text;
BEGIN
  SELECT u.encrypted_password INTO v_hash
  FROM abw_team t JOIN auth.users u
    ON u.email = lower(replace(trim(t.name), ' ', '.')) || '.abwesenheit@greathairday.at'
  WHERE t.id = p_person AND t.ausgeschieden_am IS NULL;
  RETURN v_hash IS NOT NULL AND p_pin ~ '^[0-9]{4}$' AND v_hash = crypt(p_pin || '-ghd', v_hash);
END $$;

-- Stempeln am Tablet. Gibt bei falscher PIN {ok:false} zurück statt einen Fehler zu
-- werfen – sonst würde der Fehlversuch mit zurückgerollt und die Sperre wirkte nicht.
CREATE OR REPLACE FUNCTION zeit_terminal_stempeln(p_person text, p_pin text, p_aktion text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b zeit_buchungen;
BEGIN
  IF NOT zeit_ist_terminal() THEN RAISE EXCEPTION 'Kein Stempel-Tablet'; END IF;
  IF (SELECT count(*) FROM zeit_pin_versuche
      WHERE person_id = p_person AND NOT ok AND am > now() - interval '15 minutes') >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'fehler', 'Zu viele falsche PINs – bitte 15 Minuten warten');
  END IF;
  IF NOT zeit__pin_ok(p_person, p_pin) THEN
    INSERT INTO zeit_pin_versuche (person_id, ok) VALUES (p_person, false);
    RETURN jsonb_build_object('ok', false, 'fehler', 'PIN falsch');
  END IF;
  INSERT INTO zeit_pin_versuche (person_id, ok) VALUES (p_person, true);
  b := zeit__stempeln_fuer(p_person, p_aktion, true);
  RETURN jsonb_build_object('ok', true, 'beginn', b.beginn, 'ende', b.ende, 'pause_min', b.pause_min, 'auto', b.auto);
END $$;

REVOKE ALL ON FUNCTION zeit__stempeln_fuer(text, text, boolean), zeit__pin_ok(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION zeit_ist_terminal(), zeit_terminal_liste(), zeit_terminal_stempeln(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_ist_terminal(), zeit_terminal_liste(), zeit_terminal_stempeln(text, text, text) TO authenticated;
-- Tablet registrieren (einmalig, nachdem der Gerätezugang in Supabase Auth angelegt wurde):
-- INSERT INTO zeit_terminals (user_id, name) SELECT id, 'Tablet Empfang' FROM auth.users WHERE email = '<Tablet-Zugang>';

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
          pause_start = NULL, quelle = 'korrektur', auto = '{}', geaendert_am = now();
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

-- ════════════════════════════════════════════════════════════
--  Nächtliche Automatik (fixer Dienstplan): ergänzt den Vortag
--  * vergessenes Gehen → Dienstende laut Plan
--  * fehlende Pause    → Pause laut Plan (mind. 30 min)
--  * gar nicht gestempelt (und keine Abwesenheit) → ganzer Tag laut Plan
--  Läuft NICHT als Benutzer, sondern per pg_cron. Jede Ergänzung ist in
--  zeit_buchungen.auto markiert und steht im Protokoll.
-- ════════════════════════════════════════════════════════════
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
-- Nur der Server-Job darf das ausführen, kein Benutzer:
REVOKE ALL ON FUNCTION zeit_automatik(date, boolean, boolean, boolean, integer) FROM PUBLIC, anon, authenticated;
-- Einrichten (Supabase → Database → Extensions → pg_cron aktivieren):
-- nachts für den Vortag (Sicherheitsnetz) und alle 15 Minuten für heute (ausstempeln am selben Abend)
-- SELECT cron.schedule('zeit-automatik', '15 2 * * *', $cron$ SELECT zeit_automatik(); $cron$);
-- SELECT cron.schedule('zeit-automatik-heute', '*/15 * * * *', $cron$ SELECT zeit_automatik((now() AT TIME ZONE 'Europe/Vienna')::date); $cron$);

-- ════════════════════════════════════════════════════════════
--  BESTÄTIGUNGEN (Krankenstand, Arbeitsunfall, Pflegefreistellung, Arzt)
--  Gesundheitsbezogene Daten (Art. 9 DSGVO) → privater Storage-Bucket.
--  Lesen: nur die Person selbst und die Leitung (zeit_darf_sehen).
--  Hochladen: für sich selbst oder als Leitung. Löschen: nur Chefin.
--  Ablage: belege/<person_id>/<uuid>.<endung>
--  Aufbewahrung: mit den Lohnunterlagen (7 Jahre), danach löschen.
-- ════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS zeit_belege (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  anfrage_id      text NOT NULL,     -- abw_anfragen.id (Typ beim Einbau prüfen, dann FK ergänzen)
  person_id       text NOT NULL REFERENCES abw_team(id),
  pfad            text NOT NULL UNIQUE,
  dateiname       text NOT NULL,
  typ             text NOT NULL CHECK (typ IN ('application/pdf', 'image/jpeg', 'image/png', 'image/heic')),
  groesse         integer NOT NULL CHECK (groesse BETWEEN 1 AND 10485760),
  hochgeladen_von text NOT NULL,
  hochgeladen_am  timestamptz NOT NULL DEFAULT now(),
  CHECK (split_part(pfad, '/', 1) = person_id)
);
ALTER TABLE zeit_belege ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON zeit_belege FROM anon;

DROP POLICY IF EXISTS "zeit_belege_select" ON zeit_belege;
CREATE POLICY "zeit_belege_select" ON zeit_belege FOR SELECT TO authenticated USING (zeit_darf_sehen(person_id));
DROP POLICY IF EXISTS "zeit_belege_insert" ON zeit_belege;
CREATE POLICY "zeit_belege_insert" ON zeit_belege FOR INSERT TO authenticated
  WITH CHECK (hochgeladen_von = abw_current_person_id()
              AND (person_id = abw_current_person_id() OR zeit_darf_verwalten(person_id)));
DROP POLICY IF EXISTS "zeit_belege_delete" ON zeit_belege;
CREATE POLICY "zeit_belege_delete" ON zeit_belege FOR DELETE TO authenticated USING (abw_is_owner());

INSERT INTO storage.buckets (id, name, public) VALUES ('belege', 'belege', false) ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "belege_lesen" ON storage.objects;
CREATE POLICY "belege_lesen" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'belege' AND zeit_darf_sehen(split_part(name, '/', 1)));
DROP POLICY IF EXISTS "belege_hochladen" ON storage.objects;
CREATE POLICY "belege_hochladen" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'belege' AND (split_part(name, '/', 1) = abw_current_person_id()
                                        OR zeit_darf_verwalten(split_part(name, '/', 1))));
DROP POLICY IF EXISTS "belege_loeschen" ON storage.objects;
CREATE POLICY "belege_loeschen" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'belege' AND abw_is_owner());
-- kein UPDATE: eine hochgeladene Bestätigung wird nicht überschrieben

-- Funktionen: nur für Angemeldete (Supabase gibt sonst auch anon EXECUTE)
REVOKE ALL ON FUNCTION zeit_stempeln(text, boolean), zeit_plan_am(text, date), zeit_jugendlich(text, date),
  zeit_pause_noetig(text, zeit_buchungen), zeit_buchung_aendern(text, date, time, time, integer, text, boolean),
  zeit_korrektur_entscheiden(uuid, boolean), zeit_monat_bestaetigen(date),
  zeit_monat_abschliessen(text, date), zeit_monat_oeffnen(text, date, text),
  zeit_ist_vorgesetzt_von(text), zeit_darf_verwalten(text), zeit_darf_sehen(text),
  zeit_monat_gesperrt(text, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION zeit_stempeln(text, boolean), zeit_plan_am(text, date), zeit_jugendlich(text, date),
  zeit_pause_noetig(text, zeit_buchungen), zeit_buchung_aendern(text, date, time, time, integer, text, boolean),
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

CREATE OR REPLACE FUNCTION zeit_einst(p_key text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT wert -> p_key FROM abw_einstellungen WHERE schluessel = 'zeitverwaltung';
$$;
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
