import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// In dev, the API runs on :8000. In production FastAPI serves the built files itself.
export default defineConfig({
  plugins: [react()],
  server: {
    host: true,
    proxy: {
      "/walker": "http://localhost:8000",
      "/user": "http://localhost:8000",
      "/demo": "http://localhost:8000",
      "/healthz": "http://localhost:8000",
    },
  },
});
