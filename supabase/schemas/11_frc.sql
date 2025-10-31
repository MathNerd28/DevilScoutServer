-- Synchronized data read by the application
-- Not user writable
-- Contains only the fields we're interested in

-- Different types of matches
CREATE TYPE frc_match_level AS ENUM (
  'practice',
  'qualification',
  'playoff',
  'octofinal',
  'quarterfinal',
  'semifinal',
  'final'
);

CREATE TYPE frc_match_status AS ENUM (
  -- NOT guaranteed to progress in order
  'scheduled', -- the default state
  'queuing',   -- the match has been queued (Nexus only)
  'on_deck',   -- the match is on deck (Nexus only)
  'on_field', -- the match is ready/running (Nexus only)
  'score_posted' -- the score has been posted on TBA (TBA only)
);

CREATE TYPE frc_alliance_color AS ENUM (
  'red',
  'blue'
);

CREATE TYPE frc_video_type AS ENUM (
  'youtube',
  'tba'
);

-- List of seasons
-- Dynamic, manually populated
-- Must add new seasons; we don't have a source for new season names yet
CREATE TABLE frc_seasons (
  year smallint PRIMARY KEY,
  name text NOT NULL
);

-- List of event types
-- Static, manually populated in seed
-- Source: https://github.com/the-blue-alliance/the-blue-alliance/blob/master/consts/event_type.py
-- TODO: handle this differently?
CREATE TABLE frc_event_types (
  id smallint PRIMARY KEY,
  is_district boolean NOT NULL,
  is_championship boolean NOT NULL,
  is_division boolean NOT NULL,
  is_offseason boolean NOT NULL,
  name text NOT NULL,
  name_short text NOT NULL
);

-- List of award types
-- Static, manually populated in seed
-- Source: https://github.com/the-blue-alliance/the-blue-alliance/blob/master/consts/award_type.py
-- TODO: handle this differently?
CREATE TABLE frc_award_types (
  id smallint PRIMARY KEY,
  name text NOT NULL,
  description text NOT NULL
    DEFAULT ''
);

-- List of districts
-- Synchronized from TBA
CREATE TABLE frc_districts (
  season smallint NOT NULL
    REFERENCES frc_seasons ON DELETE RESTRICT,
  key citext PRIMARY KEY,
  name text NOT NULL
);

-- List of teams
-- Synchronized from TBA
CREATE TABLE frc_teams (
  number smallint PRIMARY KEY,
  rookie_season smallint
    REFERENCES frc_seasons ON DELETE RESTRICT,
  name text NOT NULL,
  country text,
  province text,
  city text,
  website text,

  -- Enable fuzzy text search by name/number
  search_term text NOT NULL
    GENERATED ALWAYS AS (number::text || name) STORED
);

CREATE INDEX ON frc_teams
  USING GIN(search_term gin_trgm_ops);

-- List of all events
-- Synchronized from TBA
CREATE TABLE frc_events (
  season smallint NOT NULL
    REFERENCES frc_seasons ON DELETE RESTRICT,
  type smallint NOT NULL
    REFERENCES frc_event_types ON DELETE RESTRICT,
  start_date date NOT NULL,
  end_date date NOT NULL,
  has_nexus boolean NOT NULL
    DEFAULT false,

  key citext PRIMARY KEY,
  name text NOT NULL,

  name_short text,
  district_key citext
    REFERENCES frc_districts ON DELETE SET NULL,
  country text,
  province text,
  city text,
  location text,
  website text,

  -- speed up fuzzy search over several columns
  search_term text NOT NULL
    GENERATED ALWAYS AS (
      key ||
      name ||
      COALESCE(country, '') ||
      COALESCE(province, '') ||
      COALESCE(city, '')
    ) STORED
);

CREATE INDEX ON frc_events (season, type);
CREATE INDEX ON frc_events (start_date, end_date);
CREATE INDEX ON frc_events (district_key);
CREATE INDEX ON frc_events USING GIN (search_term gin_trgm_ops);

-- List teams attending events
-- Rows synced from TBA
-- Pit address from Nexus
-- team_num does NOT reference frc_teams to handle offseason demos + duplicates
CREATE TABLE frc_event_teams (
  team_num smallint NOT NULL,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  remap_team_num smallint,
  pit_address text,

  PRIMARY KEY (event_key, team_num),
  UNIQUE (team_num, event_key)
);

-- Individual team rankings
-- Synced from TBA
-- subteam for duplicates (e.g. 1678 @ 2022mttd)
CREATE TABLE frc_rankings (
  team_num smallint NOT NULL,
  rank smallint NOT NULL,
  wins smallint NOT NULL,
  losses smallint NOT NULL,
  ties smallint NOT NULL,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  subteam char(1),

  PRIMARY KEY (event_key, team_num, subteam),
  FOREIGN KEY (event_key, team_num)
    REFERENCES frc_event_teams ON DELETE CASCADE
);

CREATE INDEX ON frc_rankings (team_num, event_key);

-- List of event awards
-- Synced from TBA
-- Team/awardee can be null if awarded to the other type
CREATE TABLE frc_awards (
  type smallint NOT NULL
    REFERENCES frc_award_types ON DELETE RESTRICT,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  award_name text NOT NULL,
  team_num smallint,
  awardee_name text,
  subteam char(1),

  -- TODO: no primary key is possible! (type, event_key, name) is not unique!

  FOREIGN KEY (event_key, team_num)
    REFERENCES frc_event_teams ON DELETE CASCADE,
  CONSTRAINT frc_awards_team_or_individual
    CHECK (team_num IS NOT NULL OR awardee_name IS NOT NULL)
);

CREATE INDEX ON frc_awards (event_key, type);
CREATE INDEX ON frc_awards (team_num, event_key)
  WHERE team_num IS NOT NULL;

-- List of alliances at events
-- Synced from TBA
CREATE TABLE frc_alliances (
  team_num smallint NOT NULL,
  alliance smallint NOT NULL,
  pick_index smallint NOT NULL,
  event_key citext NOT NULL,
  subteam char(1),

  PRIMARY KEY (event_key, alliance, pick_index),
  FOREIGN KEY (event_key, team_num)
    REFERENCES frc_event_teams ON DELETE CASCADE,
  UNIQUE (team_num, event_key, subteam)
);

-- List of public event announcements
-- Synced from Nexus
CREATE TABLE frc_announcements (
  posted_time timestamptz NOT NULL,
  is_resolved boolean NOT NULL
    DEFAULT false,
  id text PRIMARY KEY,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  message text NOT NULL
);

DROP TABLE IF EXISTS frc_matches;

-- match keys are formatted as follows:
-- - event key (same as TBA/Nexus) followed by an underscore _
-- - match type:
--   - practice: pm
--   - qualification: qm
--   - eight-final: ef
--   - quarterfinal: qf
--   - semifinal: sf
--   - playoff: po
--   - final: fn
-- - set number (this is deprecated, but remains for historical compatibility)
-- - "_m" followed by the match number within the set

-- To map TBA to match keys:
-- - if event's playoff_type = 5 and match is semifinal:
--   - this is the new double-elimination bracket
--   - type is playoff
--   - set is 1
--   - match is set
-- - otherwise:
--   - leave everything as-is

-- To map Nexus to match keys:
-- - event key: as-is
-- - match type: playoff = semifinal
-- - set number: always 1 (all events from 2022 or later)

-- List of matches
-- Synced from both TBA and Nexus
-- Nexus can increment replay
-- If event uses Nexus, then Nexus controls the times completely
CREATE TABLE frc_matches (
  level frc_match_level NOT NULL,
  set smallint NOT NULL,
  number smallint NOT NULL,

  key citext PRIMARY KEY
    GENERATED ALWAYS AS (
      event_key ||
      '-' ||
      (
        CASE
          WHEN level = 'practice' THEN 'p'
          WHEN level = 'qualification' THEN 'q'
          WHEN level = 'playoff' THEN 'pf'
          WHEN level = 'octofinal' THEN 'of'
          WHEN level = 'quarterfinal' THEN 'qf'
          WHEN level = 'semifinal' THEN 'sf'
          WHEN level = 'final' THEN 'f'
        END
      ) ||
      set::text ||
      '-m' ||
      number::text
    ) STORED,
  event_key citext NOT NULL
    REFERENCES frc_events ON DELETE CASCADE,
  label text NOT NULL
    GENERATED ALWAYS AS (
      (
        CASE level
          -- These all (probably) have only one set
          WHEN 'practice' THEN 'Practice ' || number::text
          WHEN 'qualification' THEN 'Qualification ' || number::text
          WHEN 'playoff' THEN 'Playoff ' || number::text
          WHEN 'final' THEN 'Final ' || number::text
          -- These can sometimes have multiple sets
          WHEN 'octofinal' THEN 'Octofinal ' || set::text || '-' || number::text
          WHEN 'quarterfinal' THEN 'Quarterfinal ' || set::text || '-' || number::text
          WHEN 'semifinal' THEN 'Semifinal ' || set::text || '-' || number::text
          ELSE '???'
        END
      ) || (
        CASE
          WHEN replay = 0 THEN ''
          WHEN replay = 1 THEN ' Replay'
          ELSE ' Replay ' || replay::text
        END
      )
    ) STORED,
  replay smallint NOT NULL
    DEFAULT 0,
  score_counter smallint NOT NULL,
  tba_status frc_match_status,
  nexus_status frc_match_status,

  tba_scheduled_time timestamptz,
  tba_estimated_time timestamptz,
  tba_actual_time timestamptz,
  nexus_scheduled_time timestamptz,
  nexus_estimated_time timestamptz,
  nexus_queue_time timestamptz,

  red_score smallint,
  blue_score smallint,
  winner frc_alliance_color,

  UNIQUE (event_key, level, set, number)
);

CREATE FUNCTION frc_matches_check_score_counter() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF (
          NEW.red_score IS NOT NULL OR
          NEW.blue_score IS NOT NULL OR
          NEW.winner IS NOT NULL
        ) THEN
          NEW.score_counter := 1;
        ELSE
          NEW.score_counter := 0;
        END IF;
      ELSIF TG_OP = 'UPDATE' THEN
        IF (
          (NEW.red_score IS DISTINCT FROM OLD.red_score) OR
          (NEW.blue_score IS DISTINCT FROM OLD.blue_score) OR
          (NEW.winner IS DISTINCT FROM OLD.winner)
        ) THEN
          NEW.score_counter := OLD.score_counter + 1;
        ELSE
          NEW.score_counter := OLD.score_counter;
        END IF;
      END IF;
    END;
  $$;

REVOKE EXECUTE ON FUNCTION frc_matches_check_score_counter FROM public, anon, authenticated;

CREATE TRIGGER frc_matches_score_counter_trigger BEFORE INSERT OR UPDATE ON frc_matches
  FOR EACH ROW EXECUTE FUNCTION frc_matches_check_score_counter();

-- Teams in a match
-- Synced from both TBA and Nexus
CREATE TABLE frc_match_teams (
  team_num smallint NOT NULL
    REFERENCES frc_teams ON DELETE NO ACTION,
  station smallint NOT NULL,
  alliance frc_alliance_color NOT NULL,
  is_surrogate boolean NOT NULL
    DEFAULT false,
  is_disqualified boolean NOT NULL
    DEFAULT false,
  match_key citext NOT NULL
    REFERENCES frc_matches ON DELETE CASCADE,
  subteam char(1),

  PRIMARY KEY (match_key, alliance, station)
);

CREATE INDEX ON frc_match_teams (team_num, match_key, alliance);

-- Match breakdowns
-- Synced from TBA
-- TODO: how to parse into this format?
CREATE TABLE frc_match_breakdowns (
  match_key citext NOT NULL
    REFERENCES frc_matches ON DELETE CASCADE,
  alliance frc_alliance_color NOT NULL,
  path text NOT NULL,
  data jsonb NOT NULL,

  PRIMARY KEY (match_key, alliance, path)
);

CREATE INDEX ON frc_match_breakdowns
  USING gin (path gin_trgm_ops);

-- Match videos
-- Synced from TBA
CREATE TABLE frc_match_videos (
  match_key citext NOT NULL
    REFERENCES frc_matches ON DELETE CASCADE,
  video_type frc_video_type NOT NULL,
  video_key text NOT NULL,

  PRIMARY KEY (match_key, video_type, video_key)
);
