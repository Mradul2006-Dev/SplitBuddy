import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import pg from "pg";

const { Pool } = pg;
const pool = new Pool({ database: process.env.PGDATABASE || "splitbuddy", max: 6 });
const port = Number(process.env.PORT || 4100);

class RequestError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function loadQueries(sql) {
  const entries = sql.split(/(?=^-- (?:READ|WRITE) [RW]\d+ — )/m).slice(1);
  return new Map(entries.map(entry => {
    const match = entry.match(/^-- (?:READ|WRITE) ([RW]\d+) — [^\n]+\n(?:-- [^\n]*\n)*PREPARE (splitbuddy_[a-z_]+)(?: \(([^)]+)\))? AS\n([\s\S]+);\s*$/);
    if (!match) throw new Error("Invalid query declaration in dbms/04_queries.sql");
    const [, id, name, signature, sqlBody] = match;
    const types = signature ? signature.split(", ") : [];
    const text = sqlBody.replace(/\$(\d+)/g, (argument, position) => {
      const type = types[Number(position) - 1];
      if (!["bigint", "bigint[]", "text", "timestamptz"].includes(type)) {
        throw new Error("Invalid parameter type in " + id);
      }
      return argument + "::" + type;
    });
    return [id, { name, text }];
  }));
}

const queries = loadQueries(await readFile(new URL("./dbms/04_queries.sql", import.meta.url), "utf8"));
const assets = new Map(await Promise.all([
  ["/", "index.html", "text/html; charset=utf-8"],
  ["/app.js", "app.js", "text/javascript; charset=utf-8"],
  ["/app.css", "app.css", "text/css; charset=utf-8"],
  ["/ui.woff2", "ui.woff2", "font/woff2"],
].map(async ([path, file, type]) => [path, {
  type,
  body: await readFile(new URL("./public/" + file, import.meta.url)),
}])));

function id(value, label) {
  const text = typeof value === "number" && Number.isSafeInteger(value) ? String(value) : value;
  if (typeof text !== "string" || !/^[1-9]\d{0,18}$/.test(text) || BigInt(text) > 9223372036854775807n) {
    throw new RequestError(400, "Choose a valid " + label + ".");
  }
  return text;
}

function paise(value, allowZero = false) {
  if (allowZero && (value === "0" || value === 0)) return "0";
  return id(value, "amount");
}

function label(value, blankMessage, maxLength) {
  const trimmed = typeof value === "string" ? value.trim() : "";
  if (!trimmed || trimmed.length > maxLength) throw new RequestError(400, blankMessage);
  return trimmed;
}

function query(client, key, values = []) {
  const { name, text } = queries.get(key);
  return client.query({ name, text, values }).then(result => result.rows);
}

function saved(rows, message) {
  if (!rows.length) throw new RequestError(400, message);
  return rows;
}

function cursor(params) {
  const time = params.get("before");
  const kind = params.get("kind");
  const event = params.get("event");
  if (!time && !kind && !event) return [null, null, null];
  if (!time || !Number.isFinite(Date.parse(time)) || !["expense", "settlement"].includes(kind)) {
    throw new RequestError(400, "Open the latest history to restart paging.");
  }
  return [time, kind, id(event, "history event")];
}

async function groupView(group, user, historyCursor) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
    const members = await query(client, "R3", [group, user]);
    if (!members.length) throw new RequestError(404, "This group is available to its members.");
    const balances = await query(client, "R4", [group, user]);
    const history = await query(client, "R5", [group, user, ...historyCursor]);
    await client.query("COMMIT");
    return { members, balances, history };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}

async function jsonBody(request) {
  if (request.headers["content-type"]?.split(";")[0] !== "application/json") {
    throw new RequestError(415, "Send the form as JSON.");
  }
  let raw = "";
  request.setEncoding("utf8");
  for await (const chunk of request) {
    raw += chunk;
    if (Buffer.byteLength(raw) > 32768) throw new RequestError(413, "This form is too large.");
  }
  try {
    const values = JSON.parse(raw);
    if (!values || typeof values !== "object" || Array.isArray(values)) throw new Error();
    return values;
  } catch {
    throw new RequestError(400, "Enter valid form values.");
  }
}

function createExpense(group, user, values) {
  const description = label(values.description, "Enter an expense description up to 160 characters.", 160);
  if (!Array.isArray(values.participants) || !values.participants.length) {
    throw new RequestError(400, "Choose at least one member for the split.");
  }
  const participants = values.participants.map(value => id(value, "member"));
  const parameters = [group, user, description, paise(values.amount), participants];
  if (values.method === "equal") return query(pool, "W3", parameters);
  if (values.method === "custom" && Array.isArray(values.shares)) {
    return query(pool, "W4", [...parameters, values.shares.map(value => paise(value, true))]);
  }
  throw new RequestError(400, "Choose an equal or custom split.");
}

function sendJSON(response, status, data) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  response.end(JSON.stringify(data));
}

async function serve(request, response) {
  const url = new URL(request.url, "http://127.0.0.1");
  const asset = assets.get(url.pathname);
  if (request.method === "GET" && asset) {
    response.writeHead(200, { "Content-Type": asset.type, "X-Content-Type-Options": "nosniff" });
    response.end(asset.body);
    return;
  }
  if (request.method === "GET" && url.pathname === "/api/users") {
    return sendJSON(response, 200, await query(pool, "R1"));
  }
  if (url.pathname === "/api/groups") {
    const user = id(url.searchParams.get("user"), "demo account");
    if (request.method === "GET") return sendJSON(response, 200, await query(pool, "R2", [user]));
    if (request.method === "POST") {
      const values = await jsonBody(request);
      const name = label(values.name, "Enter a group name up to 80 characters.", 80);
      const rows = saved(await query(pool, "W1", [user, name]), "Choose an existing demo account.");
      return sendJSON(response, 201, rows[0]);
    }
  }
  const groupRoute = url.pathname.match(/^\/api\/groups\/([1-9]\d*)(?:\/(members|expenses|settlements)(?:\/([1-9]\d*))?)?$/);
  if (groupRoute) {
    const [, groupText, action, expense] = groupRoute;
    const group = id(groupText, "group");
    const user = id(url.searchParams.get("user"), "demo account");
    if (request.method === "GET" && !action) {
      return sendJSON(response, 200, await groupView(group, user, cursor(url.searchParams)));
    }
    if (request.method === "GET" && action === "expenses" && expense) {
      const rows = await query(pool, "R6", [group, user, id(expense, "expense")]);
      if (!rows.length) throw new RequestError(404, "This expense is available to its group members.");
      return sendJSON(response, 200, rows);
    }
    if (request.method === "POST" && action && !expense) {
      const values = await jsonBody(request);
      if (action === "members") {
        const rows = await query(pool, "W2", [group, user, id(values.person, "member")]);
        return sendJSON(response, 201, saved(rows, "Choose someone the group creator can add."));
      }
      if (action === "expenses") {
        const rows = await createExpense(group, user, values);
        return sendJSON(response, 201, saved(rows, "Choose group members and make the shares add up to the total."));
      }
      const rows = await query(pool, "W5", [group, user, id(values.to, "recipient"), paise(values.amount)]);
      return sendJSON(response, 201, saved(rows, "Choose a different member in this group."));
    }
  }
  throw new RequestError(404, "This page or group was not found.");
}

if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Set PORT to a number from 1 to 65535.");
const connection = await pool.connect();
connection.release();

const server = createServer((request, response) => {
  serve(request, response).catch(error => {
    if (response.headersSent) return response.end();
    if (error instanceof RequestError) return sendJSON(response, error.status, { error: error.message });
    console.error("SplitBuddy request failed", error.code || error.name);
    return sendJSON(response, 500, { error: "Check the local PostgreSQL connection and try again." });
  });
});
server.listen(port, "127.0.0.1", () => console.log("SplitBuddy is ready at http://127.0.0.1:" + port));
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => server.close(() => pool.end()));
}
