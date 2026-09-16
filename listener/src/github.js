export function dispatchBody(eventType, submission) {
  return { event_type: eventType, client_payload: submission };
}

export async function dispatch(
  repository, eventType, token, submission,
  request = fetch,
) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository)) throw new Error("Invalid GitHub repository");
  if (!token) throw new Error("GITHUB_TOKEN is not configured");
  const response = await request(`https://api.github.com/repos/${repository}/dispatches`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
      "User-Agent": "ovpn-patchwork-listener",
      "X-GitHub-Api-Version": "2022-11-28",
    },
    body: JSON.stringify(dispatchBody(eventType, submission)),
    signal: AbortSignal.timeout(20_000),
  });
  if (response.status !== 204) {
    throw new Error(`GitHub HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
  }
}
