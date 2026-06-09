// headgate-web talks to the local headgate API. By default that's the headgate
// app serving on localhost:10000 (override with VITE_HEADGATE_API at build/dev
// time). The data never leaves the machine — this is a local-only frontend.
//
// Contract (to be served by the headgate app):
//   POST  {API_BASE}/chat   { "message": string }  ->  { "reply": string }

export const API_BASE: string =
  import.meta.env.VITE_HEADGATE_API ?? "http://localhost:10000";

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
