-- Deleting a workspace must remove every row that belongs to it. Child tables that referenced the
-- workspace only through departments/providers/shift types now cascade from workspaces directly.
-- (Their other foreign keys stay NO ACTION, which is checked at the end of the statement, so a
-- whole-workspace delete succeeds while ordinary deletes of in-use providers/types are still refused.)
alter table public.affiliations add constraint affiliations_workspace_fk foreign key (workspace_id) references public.workspaces(id) on delete cascade;
alter table public.assignments  add constraint assignments_workspace_fk  foreign key (workspace_id) references public.workspaces(id) on delete cascade;
alter table public.requests     add constraint requests_workspace_fk     foreign key (workspace_id) references public.workspaces(id) on delete cascade;
alter table public.periods      add constraint periods_workspace_fk      foreign key (workspace_id) references public.workspaces(id) on delete cascade;
