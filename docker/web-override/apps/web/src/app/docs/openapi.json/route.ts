import { NextResponse } from "next/server";
import { buildOpenApiSpec } from "@/lib/openapi-spec";

// Always build the document on the fly so it reflects the current database.
export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET() {
  const spec = await buildOpenApiSpec();

  return NextResponse.json(spec, {
    headers: { "Cache-Control": "no-store" },
  });
}
