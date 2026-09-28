// Bundles js/app.js, including Svelte components. Replaces the standalone esbuild
// binary because Svelte needs the esbuild-svelte plugin.
import * as esbuild from "esbuild"
import sveltePlugin from "esbuild-svelte"
import path from "node:path"

const watch = process.argv.includes("--watch")
const deploy = process.argv.includes("--deploy")
const mixEnv = process.env.MIX_ENV || "dev"
const mixBuildPath = process.env.MIX_BUILD_PATH || `_build/${mixEnv}`

const options = {
  entryPoints: ["js/app.js"],
  bundle: true,
  target: "es2022",
  outdir: "../priv/static/assets/js",
  external: ["/fonts/*", "/images/*"],
  alias: { "@": "." },
  nodePaths: [path.resolve("../deps"), path.resolve("..", mixBuildPath)],
  conditions: ["svelte", "browser"],
  mainFields: ["svelte", "browser", "module", "main"],
  minify: deploy,
  sourcemap: watch ? "inline" : false,
  logLevel: "info",
  plugins: [
    sveltePlugin({
      compilerOptions: { css: "injected", dev: !deploy },
      filterWarnings: (w) => !w.filename?.includes("node_modules"),
    }),
  ],
}

if (watch) {
  const context = await esbuild.context(options)
  await context.watch()
  // Phoenix closes stdin when the server stops.
  process.stdin.on("close", () => process.exit(0))
  process.stdin.resume()
} else {
  await esbuild.build(options)
}
