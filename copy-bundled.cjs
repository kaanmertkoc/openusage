const { cpSync, readdirSync, rmSync } = require("fs")
const { basename, join } = require("path")

const root = __dirname
const exclude = new Set(["mock"])
const srcDir = join(root, "plugins")
const dstDir = join(root, "src-tauri", "resources", "bundled_plugins")

rmSync(dstDir, { recursive: true, force: true })

const plugins = readdirSync(srcDir, { withFileTypes: true })
  .filter((d) => d.isDirectory() && !exclude.has(d.name))
  .map((d) => d.name)

for (const id of plugins) {
  cpSync(join(srcDir, id), join(dstDir, id), {
    recursive: true,
    filter: (path) => !basename(path).endsWith(".test.js"),
  })
}

console.log(`Bundled ${plugins.length} plugins: ${plugins.join(", ")}`)
