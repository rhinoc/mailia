#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
APP_SERVER_BIN="${MAILIA_APP_SERVER_BIN:-$REPO_ROOT/mailia-mail/target/release/mailia-mail}"

if [[ ! -x "$APP_SERVER_BIN" ]]; then
  cargo build --release --manifest-path "$REPO_ROOT/mailia-mail/Cargo.toml" --bin mailia-mail >/dev/null
fi

TMPDIR="$(mktemp -d)"
cleanup() {
  if [[ -n "${SMTP_PID:-}" ]]; then
    kill "$SMTP_PID" 2>/dev/null || true
    wait "$SMTP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

FAKE_BIN="$TMPDIR/bin"
MAILDIR_ROOT="$TMPDIR/maildir"
CONFIG="$TMPDIR/config.toml"
SPAWN_LOG="$TMPDIR/himalaya-spawns.log"
DOWNLOADS_DIR="$TMPDIR/downloads"
SMTP_SERVER="$TMPDIR/fake-smtp.mjs"
SMTP_PORT_FILE="$TMPDIR/smtp-port"
SMTP_LOG="$TMPDIR/smtp.json"
mkdir -p "$FAKE_BIN" "$MAILDIR_ROOT/cur" "$MAILDIR_ROOT/new" "$MAILDIR_ROOT/tmp" "$DOWNLOADS_DIR"

cat > "$FAKE_BIN/himalaya" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MAILIA_AUDIT_SPAWN_LOG"
exit 99
SH
chmod +x "$FAKE_BIN/himalaya"

cat > "$SMTP_SERVER" <<'JS'
import fs from "node:fs";
import net from "node:net";

const portFile = process.argv[2];
const logFile = process.argv[3];
let commands = [];
let data = "";
let mode = "command";

const server = net.createServer(socket => {
  socket.setEncoding("utf8");
  socket.write("220 localhost ESMTP\r\n");
  let buffer = "";

  socket.on("data", chunk => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const rawLine = buffer.slice(0, newline + 1);
      buffer = buffer.slice(newline + 1);
      const line = rawLine.replace(/\r?\n$/, "");

      if (mode === "data") {
        if (line === ".") {
          mode = "command";
          socket.write("250 OK\r\n");
          fs.writeFileSync(logFile, JSON.stringify({ commands, data }));
          setTimeout(() => {
            socket.end();
            server.close();
          }, 10);
        } else {
          data += rawLine;
        }
        continue;
      }

      commands.push(line);
      if (line.startsWith("EHLO ") || line.startsWith("HELO ")) {
        socket.write("250-localhost\r\n250 SIZE\r\n");
      } else if (line.startsWith("MAIL FROM:") || line.startsWith("RCPT TO:")) {
        socket.write("250 OK\r\n");
      } else if (line === "DATA") {
        mode = "data";
        socket.write("354 End data\r\n");
      } else if (line === "QUIT") {
        socket.write("221 Bye\r\n");
        socket.end();
        server.close();
      } else {
        socket.write("500 Unexpected command\r\n");
      }
    }
  });
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portFile, String(server.address().port));
});
JS

node "$SMTP_SERVER" "$SMTP_PORT_FILE" "$SMTP_LOG" &
SMTP_PID=$!
for _ in {1..50}; do
  if [[ -s "$SMTP_PORT_FILE" ]]; then
    break
  fi
  sleep 0.1
done
if [[ ! -s "$SMTP_PORT_FILE" ]]; then
  echo "fake SMTP server did not start" >&2
  exit 1
fi
SMTP_PORT="$(cat "$SMTP_PORT_FILE")"

cat > "$MAILDIR_ROOT/cur/synthetic-1:2,S" <<'MAIL'
Date: Sat, 13 Jun 2026 10:00:00 +0000
From: Sender <sender@example.com>
To: Recipient <recipient@example.net>
Subject: Synthetic audit
Message-ID: <synthetic-audit@example.com>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="MAILIA-AUDIT"

--MAILIA-AUDIT
Content-Type: text/plain; charset=utf-8

Synthetic body from the app-server audit.

--MAILIA-AUDIT
Content-Type: text/plain; name="audit.txt"
Content-Disposition: attachment; filename="audit.txt"
Content-Transfer-Encoding: base64

YXR0YWNobWVudAo=
--MAILIA-AUDIT--
MAIL

cat > "$CONFIG" <<TOML
[accounts.work]
default = true
email = "sender@example.com"
display-name = "Sender"
maildir.root = "$MAILDIR_ROOT"
smtp.server = "smtp://127.0.0.1:$SMTP_PORT"
TOML

APP_SERVER_BIN="$APP_SERVER_BIN" \
HIMALAYA_CONFIG="$CONFIG" \
MAILIA_AUDIT_FAKE_BIN="$FAKE_BIN" \
MAILIA_AUDIT_SPAWN_LOG="$SPAWN_LOG" \
MAILIA_AUDIT_DOWNLOADS_DIR="$DOWNLOADS_DIR" \
MAILIA_AUDIT_SMTP_LOG="$SMTP_LOG" \
node <<'NODE'
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

const bin = process.env.APP_SERVER_BIN;
const spawnLog = process.env.MAILIA_AUDIT_SPAWN_LOG;
const startedAt = process.hrtime.bigint();
const requests = [
  { id: 1, method: "initialize", params: {} },
  { id: 2, method: "account/list", params: {} },
  { id: 3, method: "account/health", params: { account: "work" } },
  { id: 4, method: "folder/list", params: { account: "work" } },
  {
    id: 5,
    method: "message/list",
    params: { account: "work", folder: "INBOX", page: 1, pageSize: 5 },
  },
  {
    id: 6,
    method: "message/get",
    params: { account: "work", folder: "INBOX", id: "synthetic-1" },
  },
  {
    id: 7,
    method: "message/modify",
    params: {
      account: "work",
      folder: "INBOX",
      id: "synthetic-1",
      addFlags: ["flagged"],
      removeFlags: [],
    },
  },
  {
    id: 8,
    method: "attachment/download",
    params: {
      account: "work",
      folder: "INBOX",
      messageId: "synthetic-1",
      downloadsDir: process.env.MAILIA_AUDIT_DOWNLOADS_DIR,
    },
  },
  {
    id: 9,
    method: "message/send",
    params: {
      account: "work",
      raw: "From: Sender <sender@example.com>\r\nTo: Recipient <recipient@example.net>\r\nSubject: Synthetic send audit\r\n\r\nSynthetic SMTP body\r\n",
    },
  },
  { id: 10, method: "shutdown", params: {} },
];

const child = spawn(bin, ["app-server", "--listen", "stdio://"], {
  env: {
    ...process.env,
    PATH: `${process.env.MAILIA_AUDIT_FAKE_BIN}:${process.env.PATH || ""}`,
  },
  stdio: ["pipe", "pipe", "pipe"],
});

let stdout = "";
let stderr = "";
child.stdout.setEncoding("utf8");
child.stderr.setEncoding("utf8");
child.stderr.on("data", chunk => { stderr += chunk; });
const stdoutLines = readline.createInterface({ input: child.stdout });
const stdoutIterator = stdoutLines[Symbol.asyncIterator]();

const timeout = setTimeout(() => {
  child.kill("SIGKILL");
}, 5000);

const closePromise = new Promise(resolve => {
  child.on("close", code => resolve(code));
});

function readNextResponse(request) {
  return Promise.race([
    stdoutIterator.next(),
    new Promise((_, reject) => {
      setTimeout(() => {
        reject(new Error(`app-server response timeout for ${request.method}`));
      }, 5000);
    }),
  ]).then(result => {
    if (result.done) {
      throw new Error(`app-server stdout closed before response for ${request.method}`);
    }
    stdout += `${result.value}\n`;
    return JSON.parse(result.value);
  });
}

async function sendRequest(request) {
  child.stdin.write(`${JSON.stringify(request)}\n`);
  return await readNextResponse(request);
}

function evaluate(code, responses) {
  clearTimeout(timeout);
  const wallDurationMs = Number(process.hrtime.bigint() - startedAt) / 1_000_000;
  const errors = responses.filter(response => response.error);
  const metrics = stderr
    .split("\n")
    .map(line => line.match(/request (?:request_id=(\S+) )?method=(\S+) status=(\S+) duration_ms=(\d+) config_load_count=(\d+) auth_refresh_count=(\d+)/))
    .filter(Boolean)
    .map(match => ({
      requestID: match[1] ?? null,
      method: match[2],
      status: match[3],
      durationMs: Number(match[4]),
      configLoadCount: Number(match[5]),
      authRefreshCount: Number(match[6]),
    }));

  const accountHealth = responses.find(response => response.id === 3)?.result ?? {};
  const messageList = responses.find(response => response.id === 5)?.result?.envelopes ?? [];
  const messageGet = responses.find(response => response.id === 6)?.result ?? {};
  const messageModify = responses.find(response => response.id === 7)?.result ?? {};
  const attachmentDownload = responses.find(response => response.id === 8)?.result?.attachments ?? [];
  const messageSend = responses.find(response => response.id === 9)?.result ?? {};
  const downloadedAttachment = attachmentDownload[0] ?? {};
  const smtpLog = fs.existsSync(process.env.MAILIA_AUDIT_SMTP_LOG)
    ? JSON.parse(fs.readFileSync(process.env.MAILIA_AUDIT_SMTP_LOG, "utf8"))
    : { commands: [], data: "" };
  const spawnCount = fs.existsSync(spawnLog)
    ? fs.readFileSync(spawnLog, "utf8").split("\n").filter(Boolean).length
    : 0;
  const lastMetric = metrics.at(-1) ?? {};
  const totalDurationMs = metrics.reduce((sum, metric) => sum + metric.durationMs, 0);
  const perRequest = metrics
    .map(metric => `${metric.method}:${metric.status}:${metric.durationMs}ms`)
    .join(",");
  const sensitiveStderrNeedles = [
    process.env.HIMALAYA_CONFIG,
    path.dirname(process.env.HIMALAYA_CONFIG),
    process.env.MAILIA_AUDIT_DOWNLOADS_DIR,
    process.env.MAILIA_AUDIT_SMTP_LOG,
    "work",
    "sender@example.com",
    "recipient@example.net",
    "synthetic-1",
    "Synthetic audit",
    "Synthetic body",
    "Synthetic send audit",
    "Synthetic SMTP body",
    "audit.txt",
  ].filter(Boolean);
  const sensitiveStderrLeaks = sensitiveStderrNeedles.filter(needle => stderr.includes(needle));

  const ok = code === 0
    && responses.length === requests.length
    && errors.length === 0
    && metrics.length === requests.length
    && spawnCount === 0
    && lastMetric.configLoadCount === 1
    && lastMetric.authRefreshCount === 0
    && accountHealth.status === "ok"
    && Array.isArray(accountHealth.issues)
    && accountHealth.issues.length === 0
    && messageList.length === 1
    && messageList[0].has_attachment === true
    && messageGet.text?.includes("Synthetic body from the app-server audit.")
    && messageModify.id === "synthetic-1"
    && messageModify.folder === "INBOX"
    && attachmentDownload.length === 1
    && downloadedAttachment.filename === "audit.txt"
    && downloadedAttachment.path?.startsWith(path.resolve(process.env.MAILIA_AUDIT_DOWNLOADS_DIR))
    && fs.existsSync(downloadedAttachment.path)
    && fs.readFileSync(downloadedAttachment.path, "utf8") === "attachment\n"
    && messageSend.sent === true
    && smtpLog.commands.some(command => command.startsWith("EHLO "))
    && smtpLog.commands.includes("MAIL FROM:<sender@example.com>")
    && smtpLog.commands.includes("RCPT TO:<recipient@example.net>")
    && smtpLog.data.includes("Subject: Synthetic send audit")
    && smtpLog.data.includes("Synthetic SMTP body")
    && sensitiveStderrLeaks.length === 0;

  console.log(`mailia_app_server_audit=${ok ? "pass" : "fail"}`);
  console.log(`responses=${responses.length} request_metrics=${metrics.length} total_request_duration_ms=${totalDurationMs} total_wall_duration_ms=${wallDurationMs.toFixed(2)}`);
  console.log(`himalaya_spawn_count=${spawnCount} config_load_count=${lastMetric.configLoadCount ?? "missing"} auth_refresh_count=${lastMetric.authRefreshCount ?? "missing"}`);
  console.log(`health_status=${accountHealth.status ?? "missing"} message_count=${messageList.length} attachment_count=${attachmentDownload.length} sent=${messageSend.sent === true ? 1 : 0}`);
  console.log(`per_request=${perRequest}`);

  if (!ok) {
    if (errors.length > 0) {
      console.error(JSON.stringify(errors));
    }
    if (sensitiveStderrLeaks.length > 0) {
      console.error(`stderr_sensitive_leaks=${JSON.stringify(sensitiveStderrLeaks)}`);
      console.error("stderr omitted because it contains data that should stay out of app-server logs");
    } else if (stderr.trim()) {
      console.error(stderr.trim());
    }
    process.exit(1);
  }
}

(async () => {
  const responses = [];
  try {
    for (const request of requests) {
      responses.push(await sendRequest(request));
    }
    child.stdin.end();
    const code = await closePromise;
    evaluate(code, responses);
  } catch (error) {
    clearTimeout(timeout);
    child.kill("SIGKILL");
    console.error(error instanceof Error ? error.message : String(error));
    if (stdout.trim()) {
      console.error(stdout.trim());
    }
    if (stderr.trim()) {
      console.error(stderr.trim());
    }
    process.exit(1);
  }
})();
NODE
