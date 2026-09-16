import { parseArgs } from "node:util";
import { pollPages } from "../src/patchwork.js";
import { dispatchBody } from "../src/github.js";

const { values } = parseArgs({ options: {
  since: { type: "string" }, before: { type: "string" },
  "event-id": { type: "string" },
} });
const before = new Date(values.before ?? Date.now()).toISOString();
const since = new Date(values.since ?? Date.parse(before) - 600_000).toISOString();
let matches = 0;
for await (const items of pollPages("https://patchwork.openvpn.net/api/1.3", "ovpn", since, before)) {
  for (const { submission } of items) {
    if (values["event-id"] && submission.patchwork_event_id !== Number(values["event-id"])) continue;
    console.log(JSON.stringify(dispatchBody("ovpn-patchwork", submission), null, 2));
    matches++;
  }
}
if (!matches) {
  console.error("No matching dispatchable events in this interval.");
  process.exitCode = 1;
}
