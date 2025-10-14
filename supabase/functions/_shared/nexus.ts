const NEXUS_API_URL = "https://frc.nexus/api/v1";
const NEXUS_API_KEY = Deno.env.get("NEXUS_API_KEY")!;
const NEXUS_TOKEN = Deno.env.get("NEXUS_TOKEN")!;

export function isNexusToken(authHeader: string) {
  return authHeader === NEXUS_TOKEN;
}

export async function nexusFetch(path: string) {
  const headers = new Headers({
    "Nexus-Api-Key": NEXUS_API_KEY,
  });

  const response = await fetch(`${NEXUS_API_URL}${path}`, { headers: headers });

  if (response.status != 200) {
    throw new Error(
      `Nexus API call returned status ${response.status} for path: ${path}`,
    );
  }

  return response.json();
}
