// The short name used on buttons that address a person ("Reply to Sarah",
// "Respond to Sarah"): first name when the site leads with full names,
// otherwise the username. Kept short on purpose — these sit in tight rows.
export function shortDisplayName(person, siteSettings) {
  if (!person?.username) {
    return null;
  }
  if (siteSettings?.prioritize_username_in_ux) {
    return person.username;
  }
  const firstName = person.name?.trim().split(/\s+/)[0];
  return firstName || person.username;
}
