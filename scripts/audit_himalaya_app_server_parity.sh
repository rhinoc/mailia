#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
APP_SERVER_BIN="${MAILIA_APP_SERVER_BIN:-$REPO_ROOT/mailia-mail/target/release/mailia-mail}"
HIMALAYA_BIN="${HIMALAYA_BIN:-himalaya}"

if [[ ! -x "$APP_SERVER_BIN" ]]; then
  cargo build --release --manifest-path "$REPO_ROOT/mailia-mail/Cargo.toml" --bin mailia-mail >/dev/null
fi

APP_SERVER_BIN="$APP_SERVER_BIN" \
HIMALAYA_BIN="$HIMALAYA_BIN" \
node <<'NODE'
const { spawn, spawnSync } = require("node:child_process");
const crypto = require("node:crypto");

const appServerBin = process.env.APP_SERVER_BIN;
const himalayaBin = process.env.HIMALAYA_BIN || "himalaya";
const accountFilter = (process.env.MAILIA_PARITY_ACCOUNT || "").trim();
const timeoutMs = Number(process.env.MAILIA_PARITY_TIMEOUT_MS || "30000");
const checkFolders = process.env.MAILIA_PARITY_CHECK_FOLDERS === "1";
const checkHealthOnError = process.env.MAILIA_PARITY_CHECK_HEALTH === "1";
const childEnv = {
  ...process.env,
  MAILIA_APP_SERVER_KEYCHAIN_TIMEOUT_MS:
    process.env.MAILIA_APP_SERVER_KEYCHAIN_TIMEOUT_MS || "5000",
};

function redacted(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 10);
}

function parseList(payload, keys) {
  if (Array.isArray(payload)) return payload;
  for (const key of keys) {
    if (Array.isArray(payload?.[key])) return payload[key];
  }
  throw new Error(`expected list payload with keys ${keys.join(",")}`);
}

function runCLI(args) {
  const result = spawnSync(himalayaBin, args, {
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 10 * 1024 * 1024,
  });
  if (result.error) {
    throw new Error(`cli_launch_failed:${result.error.code || result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(`cli_failed:${result.status}`);
  }
  return JSON.parse(result.stdout);
}

function normalizeAccount(account) {
  return {
    name: String(account.name || ""),
    backend: account.backend == null ? null : String(account.backend),
    default: Boolean(account.default),
  };
}

function normalizeFolder(folder) {
  return {
    name: String(folder.name || ""),
    desc: folder.desc == null ? null : String(folder.desc),
  };
}

function sortByName(values) {
  return [...values].sort((lhs, rhs) => lhs.name.localeCompare(rhs.name));
}

function sameJSON(lhs, rhs) {
  return JSON.stringify(lhs) === JSON.stringify(rhs);
}

function diffNames(lhs, rhs) {
  const lhsNames = new Set(lhs.map(item => item.name));
  const rhsNames = new Set(rhs.map(item => item.name));
  return {
    missingInAppServer: [...lhsNames].filter(name => !rhsNames.has(name)).map(redacted),
    extraInAppServer: [...rhsNames].filter(name => !lhsNames.has(name)).map(redacted),
  };
}

function redactHealth(health) {
  return {
    status: String(health?.status || "unknown"),
    issueCodes: Array.isArray(health?.issues)
      ? health.issues.map(issue => String(issue.code || "unknown")).sort()
      : [],
  };
}

class AppServerClient {
  constructor() {
    this.nextId = 1;
    this.pending = new Map();
    this.stdout = "";
    this.stderr = "";
    this.child = spawn(appServerBin, ["app-server", "--listen", "stdio://"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: childEnv,
    });
    this.child.stdout.setEncoding("utf8");
    this.child.stderr.setEncoding("utf8");
    this.child.stdout.on("data", chunk => {
      this.stdout += chunk;
      let newline;
      while ((newline = this.stdout.indexOf("\n")) >= 0) {
        const line = this.stdout.slice(0, newline);
        this.stdout = this.stdout.slice(newline + 1);
        if (line.trim()) this.receive(JSON.parse(line));
      }
    });
    this.child.stderr.on("data", chunk => {
      this.stderr += chunk;
    });
    this.child.on("close", code => {
      for (const { reject } of this.pending.values()) {
        reject(new Error(`app_server_exited:${code}`));
      }
      this.pending.clear();
    });
  }

  receive(response) {
    const pending = this.pending.get(response.id);
    if (!pending) return;
    this.pending.delete(response.id);
    if (response.error) {
      pending.reject(new Error(`app_server_error:${response.error.code}`));
    } else {
      pending.resolve(response.result);
    }
  }

  request(method, params = {}) {
    const id = this.nextId++;
    const payload = JSON.stringify({ id, method, params });
    const request = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`app_server_timeout:${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: value => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: error => {
          clearTimeout(timer);
          reject(error);
        },
      });
    });
    this.child.stdin.write(`${payload}\n`);
    return request;
  }

  async shutdown() {
    if (this.child.exitCode != null) return;
    try {
      await this.request("shutdown", {});
    } finally {
      this.child.stdin.end();
    }
  }
}

async function main() {
  const appServer = new AppServerClient();
  let ok = false;
  const folderResults = [];

  try {
    await appServer.request("initialize", {});

    const cliAccounts = sortByName(parseList(
      runCLI(["account", "list", "-o", "json"]),
      ["accounts", "items", "data"]
    ).map(normalizeAccount));
    const appAccounts = sortByName(parseList(
      await appServer.request("account/list", {}),
      ["accounts", "items", "data"]
    ).map(normalizeAccount));

    const selectedAccounts = accountFilter
      ? cliAccounts.filter(account => account.name === accountFilter)
      : cliAccounts;

    if (accountFilter && selectedAccounts.length === 0) {
      throw new Error("account_filter_not_found");
    }

    const accountShapeMatches = sameJSON(cliAccounts, appAccounts);
    const accountDiff = diffNames(cliAccounts, appAccounts);

    if (checkFolders) {
      for (const account of selectedAccounts) {
        let cliFolders;
        let appFolders;
        try {
          cliFolders = sortByName(parseList(
            runCLI(["folder", "list", "-a", account.name, "-o", "json"]),
            ["folders", "items", "data"]
          ).map(normalizeFolder));
        } catch (error) {
          folderResults.push({
            account: redacted(account.name),
            status: "cli_error",
            error: error.message,
          });
          continue;
        }

        try {
          appFolders = sortByName(parseList(
            await appServer.request("folder/list", { account: account.name }),
            ["folders", "items", "data"]
          ).map(normalizeFolder));
        } catch (error) {
          let health;
          if (checkHealthOnError) {
            try {
              health = redactHealth(await appServer.request("account/health", { account: account.name }));
            } catch (healthError) {
              health = { error: healthError.message };
            }
          }
          const result = {
            account: redacted(account.name),
            status: "app_server_error",
            error: error.message,
            cliFolderCount: cliFolders.length,
          };
          if (health) result.health = health;
          folderResults.push(result);
          continue;
        }

        folderResults.push({
          account: redacted(account.name),
          status: sameJSON(cliFolders, appFolders) ? "match" : "mismatch",
          cliFolderCount: cliFolders.length,
          appServerFolderCount: appFolders.length,
          diff: diffNames(cliFolders, appFolders),
        });
      }
    }

    const mismatches = folderResults.filter(result => result.status !== "match");
    ok = accountShapeMatches && (!checkFolders || mismatches.length === 0);

    console.log(`himalaya_app_server_parity=${ok ? "pass" : "fail"}`);
    console.log(`account_count_cli=${cliAccounts.length} account_count_app_server=${appAccounts.length} account_shape_match=${accountShapeMatches}`);
    console.log(`account_name_diff=${JSON.stringify(accountDiff)}`);
    console.log(`folder_check=${checkFolders ? "enabled" : "skipped"}`);
    console.log(`health_on_error=${checkHealthOnError ? "enabled" : "skipped"}`);
    console.log(`folder_accounts_checked=${folderResults.length} folder_mismatch_count=${mismatches.length}`);
    console.log(`folder_results=${JSON.stringify(folderResults)}`);
  } finally {
    await appServer.shutdown().catch(() => {});
  }

  if (!ok) process.exit(1);
}

main().catch(error => {
  console.log("himalaya_app_server_parity=fail");
  console.log(`error=${error.message}`);
  process.exit(1);
});
NODE
