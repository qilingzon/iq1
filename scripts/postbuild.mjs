import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

const context = process.env.CONTEXT;
const force = process.env.PAGEFIND_FORCE === "1";
const skip = process.env.PAGEFIND_SKIP === "1";
const isProductionLike = context === "production" || process.env.NODE_ENV === "production";
const shouldRunPagefind = force || (!skip && isProductionLike);

if (!shouldRunPagefind) {
  console.log("[postbuild] Skip Pagefind indexing for non-production context.");
  process.exit(0);
}

const startMs = Date.now();
console.log("[postbuild] Running Pagefind indexing...");

const localBin = process.platform === "win32" ? "node_modules/.bin/pagefind.cmd" : "node_modules/.bin/pagefind";
const hasLocal = existsSync(localBin);

const isWin = process.platform === "win32";

const runLocal = () => {
  if (isWin) {
    const abs = resolve(localBin);
    const cmd = `"${abs}" --site dist --output-path dist/_pagefind`;
    return spawnSync(cmd, { stdio: "inherit", shell: true });
  }

  return spawnSync(localBin, ["--site", "dist", "--output-path", "dist/_pagefind"], {
    stdio: "inherit",
  });
};

const runNpx = () => {
  if (isWin) {
    const cmd = "npx pagefind --site dist --output-path dist/_pagefind";
    return spawnSync(cmd, { stdio: "inherit", shell: true });
  }

  return spawnSync("npx", ["pagefind", "--site", "dist", "--output-path", "dist/_pagefind"], {
    stdio: "inherit",
  });
};

let result;
if (hasLocal) {
  result = runLocal();
  if (result.error || result.status == null) {
    console.log(
      `[postbuild] Local Pagefind spawn failed (${result.error?.code ?? "unknown"}); falling back to npx.
${result.error?.message ?? ""}`,
    );
    result = runNpx();
  }
} else {
  console.log("[postbuild] Local Pagefind binary not found; falling back to npx.");
  result = runNpx();
}

if (result.error) {
  console.error(
    `[postbuild] Pagefind failed to start (${result.error.code ?? "unknown"}).\n${result.error.message ?? ""}`,
  );
  if (force) {
    process.exit(1);
  }
  console.warn("[postbuild] Continuing build because PAGEFIND_FORCE is not enabled.");
  process.exit(0);
}

const durationSec = Math.round((Date.now() - startMs) / 100) / 10;
console.log(`[postbuild] Pagefind finished in ${durationSec}s (status=${result.status ?? "unknown"}).`);

if (result.status !== 0) {
  if (force) {
    process.exit(result.status ?? 1);
  }
  console.warn(
    `[postbuild] Pagefind exited with status ${result.status ?? "unknown"}; continuing build because PAGEFIND_FORCE is not enabled.`,
  );
  process.exit(0);
}
