# headgate-web

**headgate for the web** — a local chat interface for the privacy harness.

A small React + TypeScript (Vite) single-screen app: type a question about your
data, get an answer back. It runs entirely on your machine and talks to the
local headgate app — your data never leaves the box.

## Run

```sh
npm install
npm run dev        # http://localhost:5173
```

`npm run build` type-checks and builds to `dist/`; `npm run preview` serves it.

## Backend

The app POSTs to the local headgate API (default **`http://localhost:10000`**),
expecting:

```
POST {API_BASE}/chat
  { "message": string }   ->   { "reply": string }
```

Override the endpoint with `VITE_HEADGATE_API` (e.g.
`VITE_HEADGATE_API=http://localhost:9000 npm run dev`).

> **Status:** the headgate app doesn't serve this HTTP endpoint *yet* — this is
> the frontend half. Until headgate exposes `/chat` on port 10000, requests show
> a "couldn't reach headgate" message. Wiring headgate's pipeline (sanitize →
> codegen → sandbox run) behind this endpoint is the next step.
