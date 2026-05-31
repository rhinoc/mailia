import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, ".", "");
  const timelineSourcemap = env.VITE_MAILIA_TIMELINE_SOURCEMAP === "true";

  return {
    base: "./",
    plugins: [react()],
    server: {
      host: "127.0.0.1",
      port: 5174
    },
    build: {
      outDir: "dist",
      sourcemap: timelineSourcemap
    }
  };
});
