import { getDbOpenApiComponents } from "./openapi-from-db";
// REST portion of the spec, frozen at build time from the @swagger JSDoc in
// src/app/api by scripts/generate-openapi.mjs. The standalone runtime does not
// ship the TypeScript sources, so this JSON is compiled into the build.
import restSpec from "../app/docs/rest-spec.json";

export type OpenApiDocument = Record<string, unknown>;

/**
 * Builds the OpenAPI document shared by two consumers in this deploy overlay:
 *   - /docs/openapi.json → the Swagger UI at /docs
 *   - /mcp               → the auto-generated MCP tools
 *
 * It merges:
 *   1. the REST endpoints frozen at build time, and
 *   2. the live database — one component schema per table of every proj_* schema.
 *
 * It is rebuilt on every call (the route handlers are force-dynamic), so the
 * document always reflects the current database.
 */
export async function buildOpenApiSpec(): Promise<OpenApiDocument> {
  const base = restSpec as OpenApiDocument;
  const baseComponents: OpenApiDocument = (base.components as OpenApiDocument | undefined) ?? {};
  const baseSchemas: OpenApiDocument = (baseComponents.schemas as OpenApiDocument | undefined) ?? {};

  const dbSchemas = await getDbOpenApiComponents();

  return {
    ...base,
    tags: [
      ...(Array.isArray(base.tags) ? base.tags : []),
      {
        name: "Database (auto-detected)",
        description:
          "Component schemas detected live from PostgreSQL: one per table in every proj_* project schema.",
      },
    ],
    components: {
      ...baseComponents,
      schemas: {
        ...baseSchemas,
        ...dbSchemas,
      },
    },
  };
}
