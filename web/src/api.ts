// headgate-web talks to the local headgate API over same-origin relative paths.
// In production the headgate server (src/server.mojo, :10000) serves both this
// static app and the API, so `/chat` is same-origin. In dev (Vite :5173) the
// dev-server proxies `/chat` + `/health` to :10000 (see vite.config.ts). Override
// the base with VITE_HEADGATE_API if you serve the API elsewhere. The data never
// leaves the machine — this is a local-only frontend.
//
// Contract (served by the headgate app):
//   POST  {API_BASE}/chat   { "message": string }  ->  { "reply": string }

export const API_BASE: string = import.meta.env.VITE_HEADGATE_API ?? "";

export interface ChatReply {
  reply: string;
}

/** Send a chat message to the local headgate API and return its reply text. */
export async function sendMessage(
  message: string,
  signal?: AbortSignal,
): Promise<string> {
  const res = await fetch(`${API_BASE}/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message }),
    signal,
  });
  if (!res.ok) {
    throw new Error(`headgate API returned ${res.status} ${res.statusText}`);
  }
  const data = (await res.json()) as Partial<ChatReply>;
  return data.reply ?? "";
}
