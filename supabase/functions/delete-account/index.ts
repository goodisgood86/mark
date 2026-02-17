import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    const requestBody = await req.json().catch(() => ({}));
    const bodyAccessToken =
      typeof requestBody?.access_token === 'string' ? requestBody.access_token.trim() : '';
    const headerToken =
      authHeader && authHeader.startsWith('Bearer ')
        ? authHeader.replace('Bearer ', '').trim()
        : '';
    const accessToken = headerToken.length > 0 ? headerToken : bodyAccessToken;

    if (!accessToken) {
      return new Response(
        JSON.stringify({ ok: false, error: 'UNAUTHORIZED' }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

    if (!supabaseUrl || !supabaseServiceRoleKey) {
      return new Response(
        JSON.stringify({ ok: false, error: 'MISSING_ENV' }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      );
    }

    const adminClient = createClient(supabaseUrl, supabaseServiceRoleKey);
    const adminUser = await adminClient.auth.getUser(accessToken);
    let user = adminUser.data.user;
    let userError = adminUser.error;

    // 일부 환경에서 admin getUser(accessToken) 검증이 불안정해
    // anon 클라이언트 경로로 한 번 더 검증한다.
    if ((!user || userError) && supabaseAnonKey) {
      const userClient = createClient(supabaseUrl, supabaseAnonKey, {
        global: { headers: { Authorization: `Bearer ${accessToken}` } },
      });
      const fallbackUser = await userClient.auth.getUser();
      if (fallbackUser.data.user) {
        user = fallbackUser.data.user;
        userError = null;
      }
    }

    if (userError || !user) {
      return new Response(
        JSON.stringify({
          ok: false,
          error: `INVALID_SESSION:${userError?.message ?? 'unknown'}`,
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      );
    }

    const { error: backupError } = await adminClient
      .from('user_backups')
      .delete()
      .eq('user_id', user.id);

    if (backupError) {
      return new Response(
        JSON.stringify({ ok: false, error: `BACKUP_DELETE_FAILED:${backupError.message}` }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      );
    }

    const { error: deleteError } = await adminClient.auth.admin.deleteUser(user.id);

    if (deleteError) {
      return new Response(
        JSON.stringify({ ok: false, error: `AUTH_DELETE_FAILED:${deleteError.message}` }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        },
      );
    }

    return new Response(
      JSON.stringify({
        ok: true,
        user_id: user.id,
        backup_deleted: true,
        auth_deleted: true,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      },
    );
  } catch (error) {
    return new Response(
      JSON.stringify({ ok: false, error: String(error) }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      },
    );
  }
});
