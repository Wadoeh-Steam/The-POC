alter table invites alter column invited_email drop not null;

comment on table invites is
  'Parent→child pairing via a shareable invite link, not Apple Family Sharing. See ADR-0004. '
  'Token expiry duration / resend-revoke policy: open item, ARCHITECTURE.md §7.';
