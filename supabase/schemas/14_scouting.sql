-- Scouting data submitted by our users

CREATE TYPE scouting_category AS ENUM (
  'match',
  'pit'
);

-- Matches assigned to users for scouting
CREATE TABLE assigned_matches (
  user_id uuid NOT NULL
    REFERENCES profiles ON DELETE CASCADE,
  alliance frc_alliance_color NOT NULL,
  station smallint NOT NULL,
  match_key citext NOT NULL,

  PRIMARY KEY (user_id, match_key),
  FOREIGN KEY (match_key, alliance, station)
    REFERENCES frc_match_teams ON DELETE CASCADE
);

CREATE INDEX ON assigned_matches (match_key, alliance, station);

-- Pits assigned to users for scouting
CREATE TABLE assigned_pits (
  user_id uuid NOT NULL
    REFERENCES profiles ON DELETE CASCADE,
  team_num smallint NOT NULL,
  event_key citext NOT NULL,

  PRIMARY KEY (user_id, event_key, team_num),
  FOREIGN KEY (event_key, team_num)
    REFERENCES frc_event_teams ON DELETE CASCADE
);

CREATE INDEX ON assigned_pits (event_key, team_num);

-- Scouting questions tree
CREATE TABLE questions (
  id uuid PRIMARY KEY
    DEFAULT gen_random_uuid(),
  category scouting_category NOT NULL,
  season smallint NOT NULL,
  index smallint NOT NULL
    DEFAULT 0,
  parent_id uuid
    REFERENCES questions ON DELETE CASCADE,
  label text,

  UNIQUE NULLS DISTINCT (parent_id, index)
);

CREATE INDEX ON questions (season, category);

-- Scouting questions leaf tables
-- These are the actual questions and parameters
-- One per destination data type
-- Types are:
-- - integer (also includes boolean as 0/1)
-- - options

CREATE TABLE questions_integer (
  question_id uuid PRIMARY KEY
    REFERENCES questions ON DELETE CASCADE,
  minimum integer NOT NULL
    DEFAULT 0,              -- implicit minimum
  maximum integer NOT NULL  -- must specify maximum
);

CREATE TABLE questions_options (
  question_id uuid PRIMARY KEY
    REFERENCES questions ON DELETE CASCADE,
  minimum_selections smallint NOT NULL
    DEFAULT 1
    CONSTRAINT minimum_selections_positive CHECK (minimum_selections >= 0),
  maximum_selections smallint
    DEFAULT 1
    CONSTRAINT maximum_selections_positive CHECK (maximum_selections >= 0)
);

CREATE TABLE questions_options_choices (
  question_id uuid NOT NULL
    REFERENCES questions_options ON DELETE CASCADE,
  option_id smallint NOT NULL,
  label text NOT NULL,

  PRIMARY KEY (question_id, option_id)
);

-- Scouting submission metadata
CREATE TABLE submissions (
  id uuid PRIMARY KEY
    DEFAULT gen_random_uuid(),
  category scouting_category NOT NULL,
  season smallint NOT NULL,
  scouted_team smallint NOT NULL,
  created_at timestamptz NOT NULL
    DEFAULT now(),
  scouting_user uuid
    REFERENCES profiles ON DELETE SET NULL
    DEFAULT auth.uid(),
  scouting_team smallint
    REFERENCES teams ON DELETE SET NULL,
  event_key citext
    REFERENCES frc_events ON DELETE SET NULL,
  match_key citext
    REFERENCES frc_matches ON DELETE SET NULL,
  match_replay smallint,

  CHECK ((match_key IS NULL) = (category = 'pit')),
  FOREIGN KEY (event_key, scouted_team)
    REFERENCES frc_event_teams ON DELETE SET NULL (event_key),
  FOREIGN KEY (scouting_team, scouting_user)
    REFERENCES team_users (team_num, user_id) ON DELETE SET NULL (scouting_user)
);

-- Scouting submission data tables

-- Integer data
-- Boolean: 0 = false, 1 = true
CREATE TABLE submissions_data_integer (
  question_id uuid NOT NULL
    REFERENCES questions_integer ON DELETE RESTRICT,
  submission_id uuid NOT NULL
    REFERENCES submissions ON DELETE CASCADE,
  value smallint NOT NULL,

  PRIMARY KEY (question_id, submission_id) INCLUDE (value)
);

CREATE INDEX ON submissions_data_integer (submission_id, question_id);

CREATE FUNCTION submissions_data_integer_validate() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    DECLARE
      submission submissions%ROWTYPE;
      question questions%ROWTYPE;
      parameters questions_integer%ROWTYPE;
    BEGIN
      -- fetch metadata
      SELECT * INTO submission
        FROM submissions s
        WHERE s.id = NEW.submission_id;

      SELECT * INTO question
        FROM questions q
        WHERE q.id = NEW.question_id;

      SELECT * INTO parameters
        FROM questions_integer qi
        WHERE q.id = NEW.question_id;

      -- ensure season & category match
      IF submission.season != question.season OR submission.category != question.category THEN
        RAISE EXCEPTION 'Submission % cannot contain question %', submission.id, question.id;
      END IF;

      -- validate data
      IF NEW.value < parameters.minimum OR NEW.value > parameters.maximum THEN
        RAISE EXCEPTION 'Value % out of range (%, %) for question % on submission %',
          NEW.value, parameters.minimum, parameters.maximum, question.id, submission.id;
      END IF;

      RETURN NULL; -- after trigger; value doesn't matter
    END;
  $$;

CREATE TRIGGER submissions_data_integer_valid AFTER INSERT ON submissions_data_integer
  FOR EACH ROW EXECUTE FUNCTION submissions_data_integer_validate();

-- Options data
CREATE TABLE submissions_data_options (
  question_id uuid NOT NULL,
  submission_id uuid NOT NULL
    REFERENCES submissions ON DELETE CASCADE,
  option_id integer NOT NULL,

  PRIMARY KEY (question_id, option_id, submission_id),
  FOREIGN KEY (question_id, option_id)
    REFERENCES questions_options_choices ON DELETE RESTRICT
);

CREATE INDEX ON submissions_data_options (submission_id, question_id, option_id);

CREATE FUNCTION submissions_data_options_validate() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    DECLARE
      i RECORD;
    BEGIN
      -- check option count
      FOR i IN (
        WITH checks AS (
          SELECT DISTINCT
            n.submission_id,
            n.question_id
          FROM newtable n
        ), counts AS (
          SELECT
            c.submission_id,
            c.question_id,
            COUNT(*) AS count
          FROM checks c
            JOIN submissions_data_options sdo ON
              sdo.submission_id = c.submission_id AND
              sdo.question_id = c.question_id
          GROUP BY
            c.submission_id,
            c.question_id
        )
        SELECT
          c.submission_id,
          c.question_id,
          c.count,
          qo.minimum_count,
          qo.maximum_count
        FROM counts c
          JOIN questions_options qo ON qo.question_id = c.question_id
        WHERE
          c.count < qo.minimum_count OR
          c.count > qo.maximum_count
      ) LOOP
        RAISE EXCEPTION 'Response count % out of range (%, %) for question % on submission %',
          i.count, i.minimum_count, i.maximum_count, i.question_id, i.submission_id;
      END LOOP;

      RETURN NULL; -- after trigger; value doesn't matter
    END;
  $$;

-- need transition table, so must be an after trigger
CREATE TRIGGER submissions_data_options_valid AFTER INSERT ON submissions_data_options
  REFERENCING NEW TABLE AS newtable
  FOR EACH STATEMENT EXECUTE FUNCTION submissions_data_integer_validate();

-- Match integer/boolean data
-- - match key
-- - team num
-- - question id
-- - median of entries (= mode for booleans)
CREATE VIEW data_match_integer AS
  SELECT
    s.match_key,
    s.scouted_team AS team_num,
    sd.question_id,
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY sd.value) AS match_median,
    COUNT(*) AS submission_count
  FROM
    submissions s
    JOIN submissions_data_integer sd ON
      sd.submission_id = s.id
  WHERE
    s.category = 'match'
  GROUP BY
    s.match_key,
    s.scouted_team,
    sd.question_id;

CREATE VIEW data_match_options AS
  WITH counts AS (
    SELECT
      s.match_key,
      s.scouted_team,
      COUNT(*) AS submission_count
    FROM submissions s
    WHERE
      s.category = 'match'
    GROUP BY
      s.match_key,
      s.scouted_team
  )
  SELECT
    s.match_key,
    s.scouted_team AS team_num,
    sd.question_id,
    sd.option_id,
    c.submission_count,
    COUNT(*) AS option_count
  FROM
    submissions s
    JOIN submissions_data_options sd ON
      sd.submission_id = s.id
    JOIN counts c ON
      c.match_key = s.match_key AND
      c.scouted_team = s.scouted_team
  WHERE
    s.category = 'match'
  GROUP BY
    s.match_key,
    s.scouted_team,
    sd.question_id,
    sd.option_id,
    c.submission_count;
