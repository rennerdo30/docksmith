import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import starlightThemeGalaxy from "starlight-theme-galaxy";

const [owner, repo] = (process.env.GITHUB_REPOSITORY || "rennerdo30/docksmith").split("/");

export default defineConfig({
  site: `https://${owner}.github.io`,
  base: repo === `${owner}.github.io` ? "/" : `/${repo}`,
  integrations: [
    starlight({
      title: "Docksmith",
      description: "Read-only Apple device inspection for macOS",
      plugins: [starlightThemeGalaxy()],
      customCss: ["./src/styles/custom.css"],
      social: [
        { icon: "github", label: "GitHub", href: `https://github.com/${owner}/${repo}` },
      ],
      sidebar: [
        {
          label: "Start here",
          items: [
            { label: "Overview", slug: "index" },
            { label: "Install", slug: "getting-started/installation" },
            { label: "Connect a device", slug: "guides/connect-a-device" },
          ],
        },
        {
          label: "Reference",
          items: [{ label: "Command line", slug: "reference/cli" }],
        },
        {
          label: "Project",
          items: [
            { label: "Architecture", slug: "development/architecture" },
            { label: "Releases", slug: "development/releases" },
            { label: "Roadmap", slug: "roadmap" },
          ],
        },
      ],
    }),
  ],
});
