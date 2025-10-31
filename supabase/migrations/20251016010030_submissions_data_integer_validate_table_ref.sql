alter table "public"."submissions" drop constraint "submissions_scouting_team_scouting_user_fkey";

alter table "public"."submissions" alter column "match_replay" set not null;

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.submissions_data_integer_validate()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
        WHERE qi.question_id = NEW.question_id;

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
  $function$
;


