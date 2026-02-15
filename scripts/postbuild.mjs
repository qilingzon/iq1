import { spawnSync } from "node:child_process";

const context = process.env.CONTEXT;
const force = process.env.PAGEFIND_FORCE === "1";
const skip = process.env.PAGEFIND_SKIP === "1";
const isProductionLike = context === "production" || process.env.NODE_ENV === "production";
const shouldRunPagefind = force || (!skip && isProductionLike);

if (!shouldRunPagefind) {
  console.log("[postbuild] Skip Pagefind indexing for non-production context.");
  process.exit(0);
}

console.log("[postbuild] Running Pagefind indexing...");
const result = spawnSync(
  process.platform === "win32" ? "npx.cmd" : "npx",
  ["pagefind", "--site", "dist", "--output-path", "dist/_pagefind"],
  { stdio: "inherit" },
);

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}
