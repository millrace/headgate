import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { sendMessage, API_BASE } from "./api";

type Role = "user" | "assistant" | "error";

interface Message {
  role: Role;
  text: string;
}

export default function App() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const endRef = useRef<HTMLDivElement>(null);

  // Keep the latest message in view.
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, busy]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    const text = input.trim();
    if (!text || busy) return;
    setMessages((m) => [...m, { role: "user", text }]);
    setInput("");
    setBusy(true);
    try {
      const reply = await sendMessage(text);
      setMessages((m) => [...m, { role: "assistant", text: reply }]);
    } catch (err) {
      setMessages((m) => [
        ...m,
        {
          role: "error",
          text: `Couldn't reach headgate at ${API_BASE}. Is the local app running? (${String(err)})`,
        },
      ]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="app">
      <header className="bar">
        <span className="logo">headgate</span>
        <span className="sub">local · private</span>
      </header>

      <main className="chat">
        {messages.length === 0 && (
          <div className="empty">
            <h1>Ask your vault.</h1>
            <p className="hint">
              headgate has a model write code that runs locally over your private
              vault — nothing leaves your machine.
            </p>
          </div>
        )}

        {messages.map((m, i) => (
          <div key={i} className={`row ${m.role}`}>
            <div className="bubble">{m.text}</div>
          </div>
        ))}

        {busy && (
          <div className="row assistant">
            <div className="bubble typing">
              <span />
              <span />
              <span />
            </div>
          </div>
        )}

        <div ref={endRef} />
      </main>

      <form className="composer" onSubmit={submit}>
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Ask your vault…"
          aria-label="Message"
          autoFocus
        />
        <button type="submit" disabled={busy || !input.trim()}>
          Send
        </button>
      </form>
    </div>
  );
}
