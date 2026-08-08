import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";

const site = process.env.SITE_URL ?? "https://agent-activity.vercel.app";

export default defineConfig({
  site,
  output: "static",
  outDir: "./site-dist",
  integrations: [sitemap()],
});
