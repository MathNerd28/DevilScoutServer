set check_function_bodies = off;

CREATE OR REPLACE FUNCTION nexus.event_data_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
  $function$
;


set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tba.matches_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
    DECLARE
      is_de boolean;
      comp_level CONSTANT text := NEW.data->>'comp_level';
      winning_alliance CONSTANT text := NEW.data->>'winning_alliance';
    BEGIN
      SELECT
        ((e.data->>'playoff_type')::smallint = 5) INTO is_de
        FROM tba.events e
        WHERE e.event_key = NEW.data->>'event_key';

      INSERT INTO frc_matches
      (
        level,
        set,
        number,
        event_key,
        scheduled_time,
        start_time,
        red_score,
        blue_score,
        winner
      ) VALUES (
        CASE
          WHEN comp_level = 'sf' AND is_de THEN 'playoff'::frc_match_level
          WHEN comp_level = 'sf' THEN 'semifinal'::frc_match_level
          WHEN comp_level = 'qf' THEN 'quarterfinal'::frc_match_level
          WHEN comp_level = 'ef' THEN 'eighthfinal'::frc_match_level
          WHEN comp_level = 'f' THEN 'final'::frc_match_level
          WHEN comp_level = 'qm' THEN 'qualification'::frc_match_level
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN 1
          ELSE (NEW.data->>'set')::smallint
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN (NEW.data->'set')::smallint
          ELSE (NEW.data->>'match')::smallint
        END,
        NEW.data->>'event_key',
        TO_TIMESTAMP((NEW.data->'time')::bigint),
        TO_TIMESTAMP((NEW.data->'actual_time')::bigint),
        (NEW.data#>>'{alliances,red,score}')::smallint,
        (NEW.data#>>'{alliances,blue,score}')::smallint,
        CASE
          WHEN winning_alliance = 'red' THEN 'red'::frc_alliance_color
          WHEN winning_alliance = 'blue' THEN 'blue'::frc_alliance_color
          ELSE NULL
        END
      )
      ON CONFLICT (key) DO UPDATE SET
        start_time = EXCLUDED.start_time,
        red_score = EXCLUDED.red_score,
        blue_score = EXCLUDED.blue_score,
        winner = EXCLUDED.winner;

      RETURN NULL;
    END;
  $function$
;


