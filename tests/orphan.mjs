// The harness for tests/orphan.sh. Reproduces, without a daemon and without a
// Neovim, the two ways the editor goes away.
//
// It has to be a real process rather than a shell, because the thing under test
// is what happens to the sidecar when THE OWNER OF ITS PIPES disappears. A
// shell cannot close pipe ends it does not own.
//
// Usage:
//   node orphan.mjs severed <argv...>   destroy the read ends, then provoke a
//                                       write; exit 0 if the child dies
//   node orphan.mjs orphan  <argv...>   print the child's pid and exit,
//                                       leaving the caller to poll

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";

const [mode, ...argv] = process.argv.slice(2);

/** utime+stime in seconds, straight from /proc -- the number that showed the bug. */
function cpu(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    // The comm field can contain spaces and parentheses; everything after the
    // last ')' is positional.
    const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return (Number(fields[11]) + Number(fields[12])) / 100;
  } catch {
    return null;
  }
}

const alive = (pid) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

const child = spawn(argv[0], argv.slice(1), { stdio: ["pipe", "pipe", "pipe"] });

/** Resolves on the sidecar's `ready` line, so the test never races its boot. */
function ready() {
  return new Promise((resolve, reject) => {
    let seen = "";
    const timer = setTimeout(() => reject(new Error(`no ready line in 15s; saw: ${seen}`)), 15_000);
    child.stdout.on("data", (chunk) => {
      seen += chunk;
      if (seen.includes('"ready"')) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`the sidecar exited during boot (code ${code}): ${seen}`));
    });
  });
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

if (mode === "orphan") {
  // The plain case: the editor dies, taking every pipe end with it. Print the
  // pid and go -- node closes the parent ends on exit, which is exactly what a
  // dying Neovim does.
  await ready();
  console.log(child.pid);
  process.exit(0);
}

// THE REGRESSION, precisely.
//
// Closing only the READ ends is what makes this deterministic: stdin stays
// open, so the sidecar's EOF path cannot rescue it and the only thing under
// test is what it does when a write fails. Sixteen orphans at 90% of a core
// were 202 million writes that moved 1153 bytes -- an uncaughtException handler
// reporting a broken stdout by writing to stdout.
await ready();
child.stdout.destroy();
child.stderr.destroy();

// A line that cannot be parsed. The sidecar answers it with `protocol_error`,
// which is a write, which is now an EPIPE.
child.stdin.write("{ this is not json\n");

const deadline = Date.now() + 5_000;
const before = cpu(child.pid);
while (Date.now() < deadline && alive(child.pid)) await sleep(50);

if (alive(child.pid)) {
  const burnt = (cpu(child.pid) ?? 0) - (before ?? 0);
  console.error(
    `FAIL: the sidecar (pid ${child.pid}) is still alive 5s after its stdout closed, ` +
      `having burnt ${burnt.toFixed(2)}s of CPU in that time`,
  );
  child.kill("SIGKILL");
  process.exit(1);
}

console.log("ok: the sidecar exited when its stdout closed");
process.exit(0);
