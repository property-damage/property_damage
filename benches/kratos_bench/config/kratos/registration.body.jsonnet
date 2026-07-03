// Body Kratos POSTs to the mock web_hook on registration. `ctx.identity.traits`
// is populated at the pre-persistence hook point, so the mock sees the email the
// client submitted and can key its injected event on it.
function(ctx) {
  email: ctx.identity.traits.email,
}
