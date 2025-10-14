-- These tables store raw data directly from Nexus, hardly touched
-- Nexus API v1: https:--frc.nexus/api/v1/docs

CREATE SCHEMA nexus;

GRANT USAGE ON SCHEMA nexus TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA nexus TO service_role;
GRANT ALL ON ALL ROUTINES IN SCHEMA nexus TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA nexus TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA nexus GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA nexus GRANT ALL ON ROUTINES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA nexus GRANT ALL ON SEQUENCES TO service_role;

-- List of events currently active on Nexus
CREATE TABLE nexus.events (
  event_key text PRIMARY KEY,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now(),
  delete_time timestamptz
);

CREATE FUNCTION nexus.events_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      UPDATE frc_events
        SET has_nexus = TRUE
        WHERE key = NEW.event_key;

      -- TODO: use other data from this API?

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER events_insert AFTER INSERT ON nexus.events
  FOR EACH ROW EXECUTE FUNCTION nexus.events_trigger();
-- no update trigger yet

-- Event snapshots from Nexus
CREATE TABLE nexus.event_data (
  event_key text PRIMARY KEY,
  data jsonb NOT NULL,
  data_as_of_time timestamptz NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now()
);

CREATE FUNCTION nexus.event_data_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      WITH nexus_announcements AS (
        SELECT
          j->>'id' AS id,
          j->>'announcement' AS message,
          TO_TIMESTAMP((j->'postedTime')::bigint / 1000) AS posted_time
        FROM jsonb_array_elements(NEW.data->'announcements') AS a(j)
        UNION
        SELECT
          j->>'id' AS id,
          ('Team ' || j->>'requestedByTeam' || ' is requesting ' || j->>'parts') AS message,
          TO_TIMESTAMP((j->'postedTime')::bigint / 1000) AS posted_time
        FROM jsonb_array_elements(NEW.data->'partsRequests') AS a(j)
      )
      MERGE INTO frc_announcements fa
        USING nexus_announcements na ON
          fa.id = na.id
      WHEN NOT MATCHED BY TARGET
        THEN INSERT
        (posted_time, id, event_key, message) VALUES
        (na.posted_time, na.id, NEW.event_key, na.message)
      WHEN MATCHED
        THEN UPDATE SET
          fa.posted_time = na.posted_time,
          fa.message = na.message,
          fa.event_key = na.event_key
      WHEN NOT MATCHED BY SOURCE
        AND fa.event_key = NEW.event_key
        THEN UPDATE SET
          fa.resolved = TRUE;

      WITH nexus_matches AS (
        SELECT
          j->>'label' AS label,
          j->>'status' AS status,
          TO_TIMESTAMP((j#>'{times,scheduledStartTime}')::bigint / 1000) AS scheduled_time,
          TO_TIMESTAMP((j#>'{times,actualQueueTime}')::bigint / 1000) AS actual_queue_time,
          TO_TIMESTAMP((j#>'{times,estimatedQueueTime}')::bigint / 1000) AS estimated_queue_time
        FROM jsonb_array_elements(NEW.data->'matches') AS a(j)
      ), processed_matches AS (
        SELECT
          SUBSTRING(label FROM '\d+')::smallint AS number,
          (
            CASE
              WHEN label ~ 'Practice' THEN 'practice'::frc_match_level
              WHEN label ~ 'Qualification' THEN 'qualification'::frc_match_level
              WHEN label ~ 'Playoff' THEN 'playoff'::frc_match_level
              WHEN label ~ 'Final' THEN 'final'::frc_match_level
            END
          ) AS level,
          (
            CASE
              WHEN label ~ 'Replay' THEN COALESCE(
                SUBSTRING(label FROM '\d+$')::int,
                1
              )
              ELSE 0
            END
          ) AS replay,
          (
            CASE
              WHEN nm.status = 'Queuing soon' THEN 'scheduled'
              WHEN nm.status = 'Now queuing' THEN 'queuing'
              WHEN nm.status = 'On deck' THEN 'queuing'
              WHEN nm.status = 'On field' THEN 'on_field'
            END
          ) AS status,
          nm.scheduled_time,
          COALESCE(nm.actual_queue_time, nm.estimated_queue_time) AS queue_time
      ), filtered_matches AS (
        SELECT *
        FROM processed_matches pm
        WHERE pm.replay = (
          SELECT MAX(pm2.replay)
          FROM processed_matches pm2
          WHERE
            pm2.level = pm.level AND
            pm2.number = pm.number
        )
      )
      MERGE INTO frc_matches fm
        USING filtered_matches pm ON
          fm.event_key = NEW.event_key AND
          fm.level = pm.level AND
          fm.set = 1 AND
          fm.number = pm.number
      WHEN NOT MATCHED BY TARGET
        THEN INSERT
        (
          status,
          level,
          set,
          number,
          event_key,
          replay,
          scheduled_time,
          queue_time
        ) VALUES (
          pm.status,
          pm.level,
          1,
          pm.number,
          NEW.event_key,
          pm.replay,
          pm.scheduled_time,
          pm.queue_time
        )
      WHEN MATCHED
        THEN UPDATE SET
          status = (
            CASE
              WHEN fm.replay != pm.replay THEN pm.status
              WHEN fm.status = 'score_posted' THEN fm.status
              ELSE pm.status
            END
          ),
          replay = pm.replay,
          scheduled_time = pm.scheduled_time,
          queue_time = pm.queue_time
      WHEN NOT MATCHED BY SOURCE
        AND fm.event_key = NEW.event_key
        THEN DO NOTHING; -- TODO: do something maybe?

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER event_data_insert AFTER INSERT ON nexus.event_data
  FOR EACH ROW EXECUTE FUNCTION nexus.event_data_trigger();
CREATE TRIGGER event_data_update AFTER UPDATE OF data ON nexus.event_data
  FOR EACH ROW EXECUTE FUNCTION nexus.event_data_trigger();

CREATE TABLE nexus.pit_maps (
  event_key text PRIMARY KEY,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now()
);

-- TODO: pit maps in usable format

CREATE TABLE nexus.pit_addresses (
  event_key text PRIMARY KEY,
  data jsonb NOT NULL,
  create_time timestamptz NOT NULL
    DEFAULT now(),
  update_time timestamptz NOT NULL
    DEFAULT now()
);

CREATE FUNCTION nexus.pit_addresses_trigger() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$
    BEGIN
      WITH nexus_pits AS (
        SELECT
          k::smallint AS team_num,
          v::text AS pit_address
        FROM jsonb_each(NEW.data) AS a(k, v)
      )
      MERGE INTO frc_event_teams fet
        USING nexus_pits np ON
          fet.event_key = NEW.event_key AND
          fet.team_num = np.team_num
      WHEN MATCHED
        THEN UPDATE SET
          pit_address = np.pit_address
      WHEN NOT MATCHED BY SOURCE
        AND fet.event_key = NEW.event_key
        THEN UPDATE SET
          pit_address = NULL;

      RETURN NULL;
    END;
  $$;

CREATE TRIGGER pit_addresses_insert AFTER INSERT ON nexus.pit_addresses
  FOR EACH ROW EXECUTE FUNCTION nexus.pit_addresses_trigger();
CREATE TRIGGER pit_addresses_update AFTER UPDATE OF data ON nexus.pit_addresses
  FOR EACH ROW EXECUTE FUNCTION nexus.pit_addresses_trigger();
