import { randomUUID } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { buildOpenApiSpec } from "@/lib/openapi-spec";

// ─────────────────────────────────────────────────────────────────────────────
// MCP server at /mcp (MCP "Streamable HTTP" transport), auto-generated from the
// OpenAPI document rendered at /docs (see src/lib/openapi-spec.ts):
//
//   initialize → server info + instructions
//   tools/list → one MCP tool per OpenAPI operation (POST /api/db/query, …)
//   tools/call → proxies the call to this same instance's REST API, carrying the
//                caller's `Authorization: Bearer pb_…` key so RLS applies
//
// No extra dependencies: the JSON-RPC 2.0 layer is implemented here directly,
// because the deploy image installs the frozen upstream lockfile (which has no
// @modelcontextprotocol/sdk) before this overlay is copied in.
// ─────────────────────────────────────────────────────────────────────────────

export const dynamic = "force-dynamic";
export const revalidate = 0;
export const runtime = "nodejs";
export const maxDuration = 60;

type Json = Record<string, unknown>;

const SERVER_INFO = { name: "postbase-mcp", version: "1.0.0" };
const DEFAULT_PROTOCOL_VERSION = "2025-06-18";
const SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const HTTP_METHODS = ["get", "post", "put", "patch", "delete", "head", "options", "trace"];

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, Accept, Mcp-Session-Id, MCP-Protocol-Version, Last-Event-ID, X-Postbase-Token, X-Postbase-Session, X-Project-ID",
  "Access-Control-Expose-Headers": "Mcp-Session-Id",
};

const INSTRUCTIONS = [
  "Postbase MCP server. Every tool maps to one operation of this instance's REST API,",
  "generated automatically from the OpenAPI document (also rendered at /docs), which",
  "includes the live tables of every project. Authenticate by sending the Postbase API",
  "key as `Authorization: Bearer pb_anon_…` (respects Row Level Security) or",
  "`pb_service_…` (bypasses RLS). Optionally add `X-Postbase-Token: <user JWT>` to run",
  "a call as a specific end user.",
].join(" ");

type ParameterLocation = "path" | "query" | "header" | "cookie";

type ToolParameter = {
  name: string;
  in: ParameterLocation;
  required: boolean;
  schema: Json;
};

type ToolRoute = {
  method: string;
  path: string;
  parameters: ToolParameter[];
  bodyMode: "none" | "flatten" | "body";
  bodyProperties: string[];
  bodyRequired: boolean;
};

type McpTool = {
  name: string;
  title?: string;
  description: string;
  inputSchema: Json;
};

type Catalog = {
  tools: McpTool[];
  routes: Map<string, ToolRoute>;
};

function isJsonObject(value: unknown): value is Json {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function cors(extra: Record<string, string> = {}): Record<string, string> {
  return { ...CORS_HEADERS, ...extra };
}

// ── Minimal JSON-Schema resolver (local $ref / allOf) ───────────────────────

function resolvePointer(root: unknown, pointer: string): unknown {
  if (!pointer.startsWith("#/")) return undefined;
  let current: unknown = root;
  for (const rawSegment of pointer.slice(2).split("/")) {
    if (!isJsonObject(current)) return undefined;
    const segment = rawSegment.replace(/~1/g, "/").replace(/~0/g, "~");
    current = current[segment];
  }
  return current;
}

function resolveSchema(root: Json, schema: unknown, seen: Set<string> = new Set(), depth = 0): Json {
  if (depth > 8 || !isJsonObject(schema)) return {};

  if (typeof schema.$ref === "string") {
    if (seen.has(schema.$ref)) return { type: "object" };
    const target = resolvePointer(root, schema.$ref);
    if (target === undefined) return { type: "object" };
    const nextSeen = new Set(seen);
    nextSeen.add(schema.$ref);
    return resolveSchema(root, target, nextSeen, depth + 1);
  }

  const out: Json = {};
  for (const [key, value] of Object.entries(schema)) {
    if (key === "allOf" || key === "properties" || key === "items") continue;
    out[key] = value;
  }

  const collected: Json = {};
  const required = new Set<string>();
  const collect = (source: Json): void => {
    if (isJsonObject(source.properties)) {
      for (const [name, value] of Object.entries(source.properties)) collected[name] = value;
    }
    if (Array.isArray(source.required)) {
      for (const entry of source.required) if (typeof entry === "string") required.add(entry);
    }
  };

  if (Array.isArray(schema.allOf)) {
    for (const sub of schema.allOf) {
      const resolved = resolveSchema(root, sub, seen, depth + 1);
      collect(resolved);
      for (const [key, value] of Object.entries(resolved)) {
        if (key === "properties" || key === "required") continue;
        if (out[key] === undefined) out[key] = value;
      }
    }
  }
  collect(schema);

  if (Object.keys(collected).length > 0) {
    const properties: Json = {};
    for (const [name, value] of Object.entries(collected)) {
      properties[name] = resolveSchema(root, value, seen, depth + 1);
    }
    out.properties = properties;
    out.type = out.type ?? "object";
  }

  if (required.size > 0) out.required = [...required];
  if (schema.items !== undefined) out.items = resolveSchema(root, schema.items, seen, depth + 1);

  return out;
}

// ── OpenAPI → MCP catalog ───────────────────────────────────────────────────

function sanitizeName(raw: string): string {
  const cleaned = raw.replace(/[^A-Za-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "");
  return (cleaned || "tool").slice(0, 64);
}

function toolNameFor(method: string, path: string, operationId: unknown, used: Set<string>): string {
  let candidate: string;
  if (typeof operationId === "string" && operationId.trim()) {
    candidate = operationId.trim();
  } else {
    const segments = path
      .split("/")
      .filter(Boolean)
      .map((segment) =>
        segment.startsWith("{") && segment.endsWith("}") ? `by_${segment.slice(1, -1)}` : segment
      );
    candidate = [method.toLowerCase(), ...segments].join("_");
  }

  let name = sanitizeName(candidate);
  if (used.has(name)) {
    let suffix = 2;
    while (used.has(`${name}_${suffix}`)) suffix += 1;
    name = `${name}_${suffix}`;
  }
  used.add(name);
  return name;
}

function describeOperation(method: string, path: string, operation: Json): string {
  const parts = [`${method.toUpperCase()} ${path}`];
  if (typeof operation.summary === "string" && operation.summary.trim()) parts.push(operation.summary.trim());
  if (typeof operation.description === "string" && operation.description.trim()) {
    parts.push(operation.description.trim());
  }
  return parts.join(" — ");
}

function pickJsonSchema(content: Json): unknown {
  for (const key of ["application/json", "application/*+json", "*/*"]) {
    const media = content[key];
    if (isJsonObject(media) && media.schema !== undefined) return media.schema;
  }
  for (const media of Object.values(content)) {
    if (isJsonObject(media) && media.schema !== undefined) return media.schema;
  }
  return undefined;
}

function buildCatalog(spec: Json): Catalog {
  const tools: McpTool[] = [];
  const routes = new Map<string, ToolRoute>();
  const used = new Set<string>();
  const paths: Json = isJsonObject(spec.paths) ? spec.paths : {};

  for (const [path, rawPathItem] of Object.entries(paths)) {
    if (!isJsonObject(rawPathItem)) continue;
    const pathItem = resolveSchema(spec, rawPathItem);
    const sharedParameters = Array.isArray(pathItem.parameters) ? pathItem.parameters : [];

    for (const method of HTTP_METHODS) {
      const operation = pathItem[method];
      if (!isJsonObject(operation)) continue;

      const parameters: ToolParameter[] = [];
      const properties: Json = {};
      const required: string[] = [];

      const rawParameters = [
        ...sharedParameters,
        ...(Array.isArray(operation.parameters) ? operation.parameters : []),
      ];
      for (const rawParameter of rawParameters) {
        const parameter = resolveSchema(spec, rawParameter);
        const name = typeof parameter.name === "string" ? parameter.name : undefined;
        const location = parameter.in;
        if (!name || typeof location !== "string") continue;

        const where: ParameterLocation =
          location === "path" || location === "query" || location === "header" || location === "cookie"
            ? location
            : "query";
        const schema: Json = isJsonObject(parameter.schema) ? resolveSchema(spec, parameter.schema) : { type: "string" };
        const isRequired = where === "path" ? true : parameter.required === true;

        parameters.push({ name, in: where, required: isRequired, schema });
        properties[name] =
          typeof parameter.description === "string" && schema.description === undefined
            ? { ...schema, description: parameter.description }
            : schema;
        if (isRequired && !required.includes(name)) required.push(name);
      }

      let bodyMode: ToolRoute["bodyMode"] = "none";
      const bodyProperties: string[] = [];
      let bodyRequired = false;

      if (isJsonObject(operation.requestBody)) {
        const requestBody = resolveSchema(spec, operation.requestBody);
        bodyRequired = requestBody.required === true;
        const content: Json = isJsonObject(requestBody.content) ? requestBody.content : {};
        const rawBodySchema = pickJsonSchema(content);
        const bodySchema: Json = rawBodySchema !== undefined ? resolveSchema(spec, rawBodySchema) : { type: "object" };
        const bodyProps: Json = isJsonObject(bodySchema.properties) ? bodySchema.properties : {};
        const bodyPropNames = Object.keys(bodyProps);
        const collides = bodyPropNames.some((key) => properties[key] !== undefined);

        if (bodySchema.type === "object" && bodyPropNames.length > 0 && !collides) {
          // Flatten the JSON body to the tool's top level so the model can pass
          // { operation, table, data } directly for POST /api/db/query, etc.
          bodyMode = "flatten";
          bodyProperties.push(...bodyPropNames);
          for (const key of bodyPropNames) properties[key] = bodyProps[key];
          if (Array.isArray(bodySchema.required)) {
            for (const key of bodySchema.required) {
              if (typeof key === "string" && !required.includes(key)) required.push(key);
            }
          }
        } else {
          bodyMode = "body";
          properties.body = bodySchema;
          if (bodyRequired) required.push("body");
        }
      }

      const name = toolNameFor(method, path, operation.operationId, used);
      const tool: McpTool = {
        name,
        description: describeOperation(method, path, operation),
        inputSchema: { type: "object", properties, ...(required.length > 0 ? { required } : {}) },
      };
      if (typeof operation.summary === "string" && operation.summary.trim()) tool.title = operation.summary.trim();
      tools.push(tool);
      routes.set(name, { method: method.toUpperCase(), path, parameters, bodyMode, bodyProperties, bodyRequired });
    }
  }

  tools.sort((a, b) => a.name.localeCompare(b.name));
  return { tools, routes };
}

// The catalog is rebuilt from the live database at most once every 10s, so a
// burst of tools/list + tools/call requests costs a single introspection query.
let catalogCache: { at: number; catalog: Catalog } | null = null;
const CATALOG_TTL_MS = 10_000;

async function getCatalog(): Promise<Catalog> {
  if (catalogCache && Date.now() - catalogCache.at < CATALOG_TTL_MS) return catalogCache.catalog;
  const catalog = buildCatalog(await buildOpenApiSpec());
  catalogCache = { at: Date.now(), catalog };
  return catalog;
}

// ── Tool execution (proxy to this instance's REST API) ──────────────────────

function internalBaseUrl(request: NextRequest): string {
  const explicit = process.env.POSTBASE_MCP_BASE_URL?.trim();
  if (explicit) return explicit.replace(/\/+$/, "");
  const port = process.env.PORT?.trim();
  if (port) return `http://127.0.0.1:${port}`;
  return new URL(request.url).origin.replace(/\/+$/, "");
}

async function callTool(request: NextRequest, route: ToolRoute, args: Json): Promise<Json> {
  let pathname = route.path;
  const search = new URLSearchParams();
  const headers: Record<string, string> = { Accept: "application/json" };

  for (const parameter of route.parameters) {
    const value = args[parameter.name];
    if (value === undefined || value === null) continue;

    if (parameter.in === "path") {
      pathname = pathname.split(`{${parameter.name}}`).join(encodeURIComponent(String(value)));
    } else if (parameter.in === "query") {
      for (const item of Array.isArray(value) ? value : [value]) search.append(parameter.name, String(item));
    } else if (parameter.in === "header") {
      headers[parameter.name] = String(value);
    }
  }

  let payload: unknown;
  let hasBody = false;
  if (route.bodyMode === "flatten") {
    const body: Json = {};
    for (const key of route.bodyProperties) if (args[key] !== undefined) body[key] = args[key];
    if (Object.keys(body).length > 0 || route.bodyRequired) {
      payload = body;
      hasBody = true;
    }
  } else if (route.bodyMode === "body" && args.body !== undefined) {
    payload = args.body;
    hasBody = true;
  }

  // The caller's key is what makes RLS apply: forward it verbatim, plus the
  // end-user JWT headers Postbase uses to impersonate an authenticated user.
  const forwardedAuth = request.headers.get("authorization");
  if (forwardedAuth) headers.Authorization = forwardedAuth;
  for (const headerName of ["x-postbase-token", "x-postbase-session", "x-project-id"]) {
    if (headers[headerName] === undefined) {
      const value = request.headers.get(headerName);
      if (value) headers[headerName] = value;
    }
  }
  if (hasBody) headers["Content-Type"] = "application/json";

  const query = search.toString();
  const url = `${internalBaseUrl(request)}${pathname}${query ? `?${query}` : ""}`;

  let response: Response;
  try {
    response = await fetch(url, {
      method: route.method,
      headers,
      body: hasBody ? JSON.stringify(payload) : undefined,
      cache: "no-store",
      redirect: "manual",
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: "text", text: `Request ${route.method} ${route.path} failed: ${message}` }],
      isError: true,
    };
  }

  const text = await response.text();
  let rendered = text;
  try {
    rendered = JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    // Non-JSON response body — return it as-is.
  }

  const summary = `HTTP ${response.status}${response.statusText ? ` ${response.statusText}` : ""}`;
  const result: Json = { content: [{ type: "text", text: rendered ? `${summary}\n${rendered}` : summary }] };
  if (!response.ok) result.isError = true;
  return result;
}

// ── JSON-RPC 2.0 / MCP ──────────────────────────────────────────────────────

type JsonRpcId = string | number | null;

function rpcResult(id: JsonRpcId, result: unknown): Json {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id: JsonRpcId, code: number, message: string): Json {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function messageId(value: unknown): JsonRpcId {
  return typeof value === "string" || typeof value === "number" ? value : null;
}

async function handleMessage(request: NextRequest, message: Json): Promise<Json | null> {
  // Notifications (no id) are never answered — not even on error.
  if (message.id === undefined || message.id === null) return null;

  const id = messageId(message.id);
  const method = typeof message.method === "string" ? message.method : "";
  const params: Json = isJsonObject(message.params) ? message.params : {};

  switch (method) {
    case "initialize": {
      const requested = typeof params.protocolVersion === "string" ? params.protocolVersion : DEFAULT_PROTOCOL_VERSION;
      const protocolVersion = SUPPORTED_PROTOCOL_VERSIONS.includes(requested) ? requested : DEFAULT_PROTOCOL_VERSION;
      return rpcResult(id, {
        protocolVersion,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: INSTRUCTIONS,
      });
    }
    case "ping":
    case "logging/setLevel":
      return rpcResult(id, {});
    case "tools/list": {
      const { tools } = await getCatalog();
      return rpcResult(id, { tools });
    }
    case "tools/call": {
      const name = typeof params.name === "string" ? params.name : "";
      const args: Json = isJsonObject(params.arguments) ? params.arguments : {};
      const { routes } = await getCatalog();
      const route = routes.get(name);
      if (!route) return rpcError(id, -32602, `Unknown tool: ${name}`);
      return rpcResult(id, await callTool(request, route, args));
    }
    case "resources/list":
      return rpcResult(id, { resources: [] });
    case "prompts/list":
      return rpcResult(id, { prompts: [] });
    default:
      return rpcError(id, -32601, `Method not found: ${method}`);
  }
}

// ── HTTP transport (MCP "Streamable HTTP") ──────────────────────────────────

export async function POST(request: NextRequest): Promise<Response> {
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json(rpcError(null, -32700, "Parse error"), { status: 400, headers: cors() });
  }

  const batch = Array.isArray(payload);
  const messages: unknown[] = Array.isArray(payload) ? payload : [payload];
  const responses: Json[] = [];
  let initialized = false;

  for (const raw of messages) {
    if (!isJsonObject(raw) || raw.jsonrpc !== "2.0" || typeof raw.method !== "string") {
      responses.push(rpcError(messageId(isJsonObject(raw) ? raw.id : null), -32600, "Invalid Request"));
      continue;
    }
    if (raw.method === "initialize") initialized = true;
    const response = await handleMessage(request, raw);
    if (response) responses.push(response);
  }

  const headers = cors({ "Cache-Control": "no-store" });
  if (initialized) headers["Mcp-Session-Id"] = randomUUID();

  // Every message was a notification → 202 Accepted with no body.
  if (responses.length === 0) return new Response(null, { status: 202, headers });
  return NextResponse.json(batch ? responses : responses[0], { status: 200, headers });
}

// This server only pushes responses to a POST; it offers no server-initiated
// SSE stream, so GET is explicitly rejected (the spec allows 405 here).
export async function GET(): Promise<Response> {
  return NextResponse.json(rpcError(null, -32000, "No server-initiated SSE stream; send JSON-RPC over POST."), {
    status: 405,
    headers: cors({ Allow: "POST, DELETE, OPTIONS" }),
  });
}

// Session termination. Sessions are stateless here, so there is nothing to drop.
export async function DELETE(): Promise<Response> {
  return new Response(null, { status: 204, headers: cors() });
}

export async function OPTIONS(): Promise<Response> {
  return new Response(null, { status: 204, headers: cors() });
}
