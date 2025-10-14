-- https://supabase.com/docs/guides/database/postgres/custom-claims-and-role-based-access-control-rbac
CREATE FUNCTION public.jwt_claims_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  claims jsonb;
  user_team_num smallint;
  user_requested_team_num smallint;
  user_permissions text[];
BEGIN
  claims := event->'claims';

  -- team
  SELECT team_num INTO user_team_num FROM public.team_users
    WHERE user_id = (event->>'user_id')::uuid;

  IF user_team_num IS NOT NULL THEN
    claims := jsonb_set(claims, '{team_num}', to_jsonb(user_team_num));
    claims := jsonb_set(claims, '{team_name}', to_jsonb(
      (
        SELECT name FROM public.teams t WHERE t.number = user_team_num
      )::text
    ));
  END IF;

  -- team request
  SELECT team_num INTO user_requested_team_num FROM public.team_requests
    WHERE user_id = (event->>'user_id')::uuid;

  IF user_requested_team_num IS NOT NULL THEN
    claims := jsonb_set(claims, '{requested_team_num}', to_jsonb(user_requested_team_num));
    claims := jsonb_set(claims, '{requested_team_name}', to_jsonb(
      (
        SELECT name FROM public.teams t WHERE t.number = user_requested_team_num
      )::text
    ));
  END IF;

  -- permissions
  SELECT array_agg(type) INTO user_permissions FROM public.permissions
    WHERE user_id = (event->>'user_id')::uuid;

  IF user_permissions IS NOT NULL THEN
    claims := jsonb_set(claims, '{permissions}', to_jsonb(user_permissions));
  END IF;

  -- Inject the claims into the event
  RETURN jsonb_set(event, '{claims}', claims);
END;
$$;

GRANT USAGE ON SCHEMA public TO supabase_auth_admin;

GRANT EXECUTE
  ON FUNCTION public.jwt_claims_hook
  TO supabase_auth_admin;

REVOKE EXECUTE
  ON FUNCTION public.jwt_claims_hook
  FROM authenticated, anon, public;

GRANT SELECT
  ON TABLE public.team_users
  TO supabase_auth_admin;

GRANT SELECT
  ON TABLE public.team_requests
  TO supabase_auth_admin;

GRANT SELECT
  ON TABLE public.permissions
  TO supabase_auth_admin;

CREATE POLICY "Supabase Auth can read team names" ON public.teams
  FOR SELECT TO supabase_auth_admin
  USING (true);

CREATE POLICY "Supabase Auth can read team numbers" ON public.team_users
  FOR SELECT TO supabase_auth_admin
  USING (true);

CREATE POLICY "Supabase Auth can read team requests" ON public.team_requests
  FOR SELECT TO supabase_auth_admin
  USING (true);

CREATE POLICY "Supabase Auth can read permissions" ON public.permissions
  FOR SELECT TO supabase_auth_admin
  USING (true);

CREATE FUNCTION create_user_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.profiles
    (user_id, name, created_at) VALUES
    (
      NEW.id,
      NEW.raw_user_meta_data->>'full_name',
      NEW.created_at
    );
  RETURN NEW;
END;
$$;

CREATE FUNCTION update_user_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.profiles
    SET
      name = NEW.raw_user_meta_data->>'full_name'
    WHERE
      user_id = NEW.id;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION create_user_profile FROM public, anon, authenticated;
REVOKE EXECUTE ON FUNCTION update_user_profile FROM public, anon, authenticated;

CREATE TRIGGER create_profile
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION create_user_profile();

CREATE TRIGGER update_profile
AFTER UPDATE ON auth.users
FOR EACH ROW EXECUTE FUNCTION update_user_profile();
