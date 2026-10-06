import { NextResponse } from "next/server";
import { getDbOpenApiComponents } from "@/lib/openapi-from-db";
// Base REST spec frozen at build time from the @swagger JSDoc in src/app/api
// (the sources are not present in the standalone runtime). See
// scripts/generate-openapi.mjs.
import restSpec from "../rest-spec.json";

// Always build the document on the fly so it reflects the current database.
export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET() {
  const base = restSpec as Record<string, unknown>;
  const baseComponents = (base.components as Record<string, unknown> | undefined) ?? {};
  const baseSchemas = (baseComponents.schemas as Record<string, unknown> | undefined) ?? {};

  const dbSchemas = await getDbOpenApiComponents();

  const spec = {
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

  return NextResponse.json(spec, {
    headers: { "Cache-Control": "no-store" },
  });
}
