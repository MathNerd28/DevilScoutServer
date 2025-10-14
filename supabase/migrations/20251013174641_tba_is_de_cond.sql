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
        -- https://github.com/the-blue-alliance/the-blue-alliance/blob/py3/pwa/app/lib/api/PlayoffType.ts
        ((e.data->>'playoff_type')::smallint = 10) INTO is_de
        FROM tba.events e
        WHERE e.event_key = NEW.data->>'event_key';

      INSERT INTO frc_matches
      (
        status,
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
          WHEN NEW.data#>>'{alliances,red,score}' IS NOT NULL THEN 'score_posted'::frc_match_status
          ELSE 'scheduled'::frc_match_status
        END,
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
          ELSE (NEW.data->>'set_number')::smallint
        END,
        CASE
          WHEN comp_level = 'sf' AND is_de THEN (NEW.data->'set_number')::smallint
          ELSE (NEW.data->>'match_number')::smallint
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


