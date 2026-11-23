-- LuxChat database schema (Supabase / PostgreSQL)
-- Run this entire file in Supabase SQL Editor.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 phone text unique, display_name text not null default 'LuxChat User',
 avatar_url text, created_at timestamptz not null default now()
);
create table if not exists public.conversations (
 id uuid primary key default gen_random_uuid(),
 type text not null check(type in ('direct','group','channel')),
 title text, created_by uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now()
);
create table if not exists public.conversation_members (
 conversation_id uuid not null references public.conversations(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null default 'member' check(role in ('owner','admin','member')),
 joined_at timestamptz not null default now(), last_read_at timestamptz,
 primary key(conversation_id,user_id)
);
create table if not exists public.messages (
 id uuid primary key default gen_random_uuid(),
 conversation_id uuid not null references public.conversations(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 body text not null default '', attachment_url text, attachment_name text,
 edited_at timestamptz, created_at timestamptz not null default now(),
 constraint message_has_content check(length(trim(body))>0 or attachment_url is not null)
);
create index if not exists idx_members_user on public.conversation_members(user_id);
create index if not exists idx_messages_conversation_time on public.messages(conversation_id,created_at desc);

create or replace function public.is_conversation_member(cid uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.conversation_members m where m.conversation_id=cid and m.user_id=auth.uid()); $$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
 insert into public.profiles(id,phone,display_name)
 values(new.id,new.phone,coalesce(nullif(new.raw_user_meta_data->>'display_name',''),'LuxChat User'))
 on conflict(id) do update set phone=excluded.phone;
 return new;
end; $$;
drop trigger if exists on_auth_user_created_luxchat on auth.users;
create trigger on_auth_user_created_luxchat after insert on auth.users
for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;

drop policy if exists "profile owner reads own" on public.profiles;
create policy "profile owner reads own" on public.profiles for select to authenticated using(id=auth.uid());
drop policy if exists "profile owner updates own" on public.profiles;
create policy "profile owner updates own" on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
drop policy if exists "members read conversations" on public.conversations;
create policy "members read conversations" on public.conversations for select to authenticated using(public.is_conversation_member(id));
drop policy if exists "authenticated creates conversation" on public.conversations;
create policy "authenticated creates conversation" on public.conversations for insert to authenticated with check(created_by=auth.uid());
drop policy if exists "members read memberships" on public.conversation_members;
create policy "members read memberships" on public.conversation_members for select to authenticated using(public.is_conversation_member(conversation_id));
drop policy if exists "creator adds self" on public.conversation_members;
create policy "creator adds self" on public.conversation_members for insert to authenticated
with check(user_id=auth.uid() and exists(select 1 from public.conversations c where c.id=conversation_id and c.created_by=auth.uid()));
drop policy if exists "members read messages" on public.messages;
create policy "members read messages" on public.messages for select to authenticated using(public.is_conversation_member(conversation_id));
drop policy if exists "members send messages" on public.messages;
create policy "members send messages" on public.messages for insert to authenticated with check(sender_id=auth.uid() and public.is_conversation_member(conversation_id));
drop policy if exists "sender edits own messages" on public.messages;
create policy "sender edits own messages" on public.messages for update to authenticated using(sender_id=auth.uid()) with check(sender_id=auth.uid() and public.is_conversation_member(conversation_id));
drop policy if exists "sender deletes own messages" on public.messages;
create policy "sender deletes own messages" on public.messages for delete to authenticated using(sender_id=auth.uid());

create or replace function public.get_public_profiles(p_ids uuid[])
returns table(id uuid,display_name text,avatar_url text)
language sql stable security definer set search_path=public
as $$ select p.id,p.display_name,p.avatar_url from public.profiles p where p.id=any(p_ids) and auth.uid() is not null; $$;

create or replace function public.create_direct_conversation(p_phone text)
returns uuid language plpgsql security definer set search_path=public
as $$
declare target_id uuid; existing_id uuid; new_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select id into target_id from auth.users where phone=trim(p_phone) and id<>auth.uid() limit 1;
 if target_id is null then raise exception 'No account found for this phone number'; end if;
 select c.id into existing_id from public.conversations c
 where c.type='direct'
 and exists(select 1 from public.conversation_members a where a.conversation_id=c.id and a.user_id=auth.uid())
 and exists(select 1 from public.conversation_members b where b.conversation_id=c.id and b.user_id=target_id)
 and (select count(*) from public.conversation_members x where x.conversation_id=c.id)=2 limit 1;
 if existing_id is not null then return existing_id; end if;
 insert into public.conversations(type,created_by) values('direct',auth.uid()) returning id into new_id;
 insert into public.conversation_members(conversation_id,user_id,role)
 values(new_id,auth.uid(),'owner'),(new_id,target_id,'member');
 return new_id;
end; $$;

create or replace function public.create_group_conversation(p_title text,p_phones text[],p_type text default 'group')
returns uuid language plpgsql security definer set search_path=public
as $$
declare new_id uuid; item text; target_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_type not in ('group','channel') then raise exception 'Invalid conversation type'; end if;
 if length(trim(coalesce(p_title,'')))=0 then raise exception 'A title is required'; end if;
 insert into public.conversations(type,title,created_by) values(p_type,trim(p_title),auth.uid()) returning id into new_id;
 insert into public.conversation_members(conversation_id,user_id,role) values(new_id,auth.uid(),'owner');
 foreach item in array coalesce(p_phones,'{}'::text[]) loop
  select id into target_id from auth.users where phone=trim(item) and id<>auth.uid() limit 1;
  if target_id is not null then
   insert into public.conversation_members(conversation_id,user_id,role) values(new_id,target_id,'member') on conflict do nothing;
  end if;
 end loop;
 return new_id;
end; $$;
grant execute on function public.get_public_profiles(uuid[]) to authenticated;
grant execute on function public.create_direct_conversation(text) to authenticated;
grant execute on function public.create_group_conversation(text,text[],text) to authenticated;

do $$ begin
 alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; when undefined_object then null; end $$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('chat-files','chat-files',false,26214400,array['image/*','video/*','audio/*','application/pdf','text/plain'])
on conflict(id) do nothing;
drop policy if exists "members upload chat files" on storage.objects;
create policy "members upload chat files" on storage.objects for insert to authenticated
with check(bucket_id='chat-files' and public.is_conversation_member((storage.foldername(name))[1]::uuid));
drop policy if exists "members read chat files" on storage.objects;
create policy "members read chat files" on storage.objects for select to authenticated
using(bucket_id='chat-files' and public.is_conversation_member((storage.foldername(name))[1]::uuid));
