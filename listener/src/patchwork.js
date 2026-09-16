function positiveId(value) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new Error("Invalid Patchwork ID");
  }
  return value;
}

export function completion(event, project) {
  if (event?.project?.link_name !== project) {
    throw new Error("Unexpected Patchwork project");
  }
  if (!["series-completed", "patch-completed"].includes(event.category)) return null;
  const eventId = positiveId(event.id);
  if (typeof event.date !== "string" || !Number.isFinite(Date.parse(event.date))) {
    throw new Error(`Invalid date on event ${eventId}`);
  }
  const payload = event.payload;
  if (event.category === "patch-completed") {
    // Missing is an invalid response, not evidence of a standalone patch.
    if (!payload || !("series" in payload)) throw new Error("Missing series field");
    if (payload.series !== null) {
      positiveId(payload.series?.id);
      return null;
    }
  }
  const kind = event.category === "series-completed" ? "series" : "patch";
  return {
    submission: { patchwork_event_id: eventId, kind, id: positiveId(payload?.[kind]?.id) },
    category: event.category,
    date: event.date,
  };
}

export async function* pollPages(
  api, project, since, before,
  request = fetch, maxPages = 20,
) {
  const endpoint = new URL(`${api.replace(/\/$/, "")}/events/`);
  endpoint.search = new URLSearchParams({
    project, since, before, per_page: "100",
  }).toString();
  // This instance accepts only one category value. Read the project's small
  // event stream and select both completion categories locally.
  let next = endpoint;
  for (let page = 0; next; page++) {
    if (page >= maxPages) throw new Error("Patchwork pagination limit reached; watermark retained");
    if (next.origin !== endpoint.origin || next.pathname !== endpoint.pathname) {
      throw new Error("Unexpected Patchwork pagination URL");
    }
    const response = await request(next.toString(), { signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw new Error(`Patchwork HTTP ${response.status}`);
    const events = await response.json();
    if (!Array.isArray(events)) throw new Error("Expected a Patchwork event array");
    const items = events.map(event => completion(event, project));
    yield items.filter(item => item !== null);
    const link = response.headers.get("Link")?.match(/<([^>]+)>;\s*rel="next"/);
    next = link ? new URL(link[1], next) : null;
  }
}
