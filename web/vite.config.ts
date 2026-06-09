import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// headgate-web dev server. The app talks to the local headgate API (default
// http://localhost:10000) — override with VITE_HEADGATE_API.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
});
