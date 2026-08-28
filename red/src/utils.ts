// Launcher contract and name derivations, the port of
// io.github.getcolors.agent-network-k8s.utils.

// Bump on any change a launcher pinned to an older commit could not survive.
export const contract = 1;

// The registrable (zone) domain of a hostname: its last two labels. Good
// enough for the zones this package serves; a public-suffix list would be a
// dependency for a case no deployment has.
export function registrableDomain(host: unknown): string {
  const labels = String(host).split(".");
  return labels.slice(Math.max(0, labels.length - 2)).join(".");
}

// What this deployment calls its container registry. Vultr registry names
// accept lowercase alphanumerics only, so the profile-derived name (Compute
// Name Standard) is the profile with every other character removed.
export function registryName(profile: unknown): string {
  return String(profile).toLowerCase().replace(/[^a-z0-9]/g, "");
}
