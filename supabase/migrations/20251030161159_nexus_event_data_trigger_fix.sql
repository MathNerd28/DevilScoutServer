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
          ('Team ' || (j->>'requestedByTeam') || ' is requesting ' || (j->>'parts')) AS message,
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
          posted_time = na.posted_time,
          message = na.message,
          event_key = NEW.event_key
      WHEN NOT MATCHED BY SOURCE
        AND fa.event_key = NEW.event_key
        THEN UPDATE SET
          is_resolved = TRUE;

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
          SUBSTRING(nm.label FROM '\d+')::smallint AS number,
          (
            CASE
              WHEN nm.label ~ 'Practice' THEN 'practice'::frc_match_level
              WHEN nm.label ~ 'Qualification' THEN 'qualification'::frc_match_level
              WHEN nm.label ~ 'Playoff' THEN 'playoff'::frc_match_level
              WHEN nm.label ~ 'Final' THEN 'final'::frc_match_level
            END
          ) AS level,
          (
            CASE
              WHEN nm.label ~ 'Replay' THEN COALESCE(
                SUBSTRING(nm.label FROM '\d+$')::int,
                1
              )
              ELSE 0
            END
          ) AS replay,
          (
            CASE
              WHEN nm.status = 'Queuing soon' THEN 'scheduled'::frc_match_status
              WHEN nm.status = 'Now queuing' THEN 'queuing'::frc_match_status
              WHEN nm.status = 'On deck' THEN 'queuing'::frc_match_status
              WHEN nm.status = 'On field' THEN 'on_field'::frc_match_status
            END
          ) AS status,
          nm.scheduled_time,
          COALESCE(nm.actual_queue_time, nm.estimated_queue_time) AS queue_time
        FROM nexus_matches nm
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


