-- 회원 탈퇴: 본인 Auth 계정 + 백업 데이터 동시 삭제
-- Supabase SQL Editor에서 실행

create or replace function public.delete_my_account()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid;
  v_backup_deleted boolean := false;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'UNAUTHORIZED';
  end if;

  delete from public.user_backups where user_id = v_uid;
  v_backup_deleted := found;

  delete from auth.users where id = v_uid;
  if not found then
    raise exception 'USER_NOT_FOUND';
  end if;

  return jsonb_build_object(
    'ok', true,
    'user_id', v_uid,
    'backup_deleted', v_backup_deleted,
    'auth_deleted', true
  );
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;
