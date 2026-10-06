import { pool } from "@/lib/db";

// ─────────────────────────────────────────────────────────────────────────────
// Live database introspection for the /docs Swagger UI (Postbase deploy overlay).
//
// Postbase keeps every project in its own PostgreSQL schema named
// `proj_<projectId without hyphens>` (see lib/project-db.ts) and stores project
// metadata in `_postbase.projects`. This module reads the real columns from
// `information_schema` and turns each table into an OpenAPI component schema so
// the generated `openapi.json` always reflects the actual database.
// ─────────────────────────────────────────────────────────────────────────────

type ProjectRow = { id: string; name: string; slug: string };

type ColumnRow = {
  table_schema: string;
  table_name: string;
  column_name: string;
  data_type: string;
  udt_name: string;
  is_nullable: "YES" | "NO";
  column_default: string | null;
};

type SchemaObject = {
  type: string;
  title?: string;
  description?: string;
  properties: Record<string, Record<string, unknown>>;
  required?: string[];
  "x-postgres-schema"?: string;
};

// Map a PostgreSQL type (information_schema data_type / udt_name) to OpenAPI.
function toOpenApiType(dataType: string, udtName: string): Record<string, unknown> {
  const dt = dataType.toLowerCase();

  if (dt === "array") return { type: "array", items: { type: "string" } };
  if (dt === "boolean") return { type: "boolean" };
  if (dt === "smallint" || dt === "integer" || dt === "bigint") {
    return { type: "integer", format: dt === "smallint" ? "int32" : "int64" };
  }
  if (dt === "numeric" || dt === "decimal" || dt === "real" || dt === "double precision") {
    return { type: "number" };
  }
  if (dt === "uuid") return { type: "string", format: "uuid" };
  if (dt === "json" || dt === "jsonb") return { type: "object" };
  if (dt === "bytea") return { type: "string", format: "binary" };
  if (dt.startsWith("timestamp")) return { type: "string", format: "date-time" };
  if (dt === "date") return { type: "string", format: "date" };
  if (dt.startsWith("time")) return { type: "string" };
  // text, character varying, character, enum domains, inet, etc.
  void udtName;
  return { type: "string" };
}

/**
 * Detect the Postbase database and return one OpenAPI component schema per
 * table (named `<table>` for a single project, `<projectSlug>.<table>` when the
 * instance hosts several). Never throws: if the metadata or a project schema is
 * not ready yet (e.g. before /setup) it returns whatever it could read.
 */
export async function getDbOpenApiComponents(): Promise<Record<string, SchemaObject>> {
  const schemas: Record<string, SchemaObject> = {};

  let projects: ProjectRow[] = [];
  try {
    const res = await pool.query(
      `SELECT id, name, slug FROM "_postbase"."projects" ORDER BY created_at`
    );
    projects = res.rows as ProjectRow[];
  } catch {
    // _postbase schema not created yet — fall back to scanning proj_* schemas.
  }

  const projectBySchema = new Map<string, ProjectRow>();
  for (const project of projects) {
    projectBySchema.set(`proj_${project.id.replace(/-/g, "")}`, project);
  }

  let columns: ColumnRow[] = [];
  try {
    const res = await pool.query(
      `SELECT table_schema, table_name, column_name, data_type, udt_name,
              is_nullable, column_default
         FROM information_schema.columns
        WHERE table_schema LIKE 'proj\\_%'
        ORDER BY table_schema, table_name, ordinal_position`
    );
    columns = res.rows as ColumnRow[];
  } catch {
    return schemas;
  }

  const multiProject = projects.length > 1;

  for (const column of columns) {
    const project = projectBySchema.get(column.table_schema);
    const scope = project ? project.slug : column.table_schema;
    const schemaName = multiProject ? `${scope}.${column.table_name}` : column.table_name;

    let entry = schemas[schemaName];
    if (!entry) {
      entry = {
        type: "object",
        title: project ? `${project.name} — ${column.table_name}` : `${column.table_schema}.${column.table_name}`,
        description: `Auto-detected from PostgreSQL schema \`${column.table_schema}\`.`,
        properties: {},
        "x-postgres-schema": column.table_schema,
      };
      schemas[schemaName] = entry;
    }

    const property = toOpenApiType(column.data_type, column.udt_name);

    if (column.column_default) {
      property["x-default"] = column.column_default;
      if (/gen_random_uuid|uuid_generate/u.test(column.column_default)) {
        property.format = "uuid";
        property.readOnly = true;
      } else if (column.column_default.startsWith("nextval(")) {
        property.readOnly = true;
      }
    }

    entry.properties[column.column_name] = property;

    if (column.is_nullable === "NO" && !property.readOnly) {
      entry.required = entry.required ?? [];
      entry.required.push(column.column_name);
    }
  }

  return schemas;
}
