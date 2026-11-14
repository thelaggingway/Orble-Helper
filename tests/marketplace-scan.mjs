// Runs the Omarchy plugin marketplace's own Automated Security Baseline over this repo.
// Usage: node tests/marketplace-scan.mjs <path to a clone of omacom/omarchy-plugin-marketplace>
// CI clones the marketplace first. Fails unless the outcome is "passed".
import { readFileSync } from "node:fs"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const mkt = process.argv[2]
if (!mkt) { console.error("usage: node tests/marketplace-scan.mjs <marketplace clone>"); process.exit(2) }
const repo = fileURLToPath(new URL("..", import.meta.url))
const { buildSecurityBaseline } = await import(mkt.replace(/\/$/, "") + "/scripts/security-baseline-analysis.mjs")

const listing = execFileSync("git", ["-C", repo, "ls-files", "-s"], { encoding: "utf8" }).trim().split("\n")
const files = listing.map((line) => {
  const [, mode, path] = line.match(/^(\d+) \S+ \d\t(.*)$/)
  const buf = readFileSync(repo + path)
  const binary = buf.includes(0)
  return { path, mode, binary, size: buf.length, content: binary ? "" : buf.toString("utf8") }
})

const result = buildSecurityBaseline({
  repository: "thelaggingway/Orble-Helper",
  repoUrl: "https://github.com/thelaggingway/Orble-Helper",
  commitSha: "0".repeat(40),
  files,
})
console.log(`marketplace-scan: ${result.outcome}`)
for (const item of [...result.findings, ...result.capabilities]) {
  console.log(`  ${item.id}: ${item.evidence.map((e) => `${e.path}:${e.line}`).join(", ")}`)
}
if (result.outcome !== "passed") process.exit(1)
