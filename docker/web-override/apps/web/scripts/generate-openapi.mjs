// ─────────────────────────────────────────────────────────────────────────────
// Build-time OpenAPI generator (Postbase deploy overlay).
//
// The upstream app exposes Swagger UI at /docs/api and builds its spec with
// `next-swagger-doc`, which scans the `@swagger` JSDoc comments in
// `apps/web/src/app/api/**` at *runtime*. The standalone image produced by this
// repository does NOT ship the `src/` TypeScript sources, so that scan finds
// nothing in production.
//
// This script runs during `docker build` — while the backend clone still has its
// sources — and freezes the REST portion of the spec into
// `src/app/docs/rest-spec.json`. The route at `/docs/openapi.json` imports that
// JSON (compiled into the build) and appends the live, auto-detected database
// schemas at request time.
//
// Usage (from apps/web): node scripts/generate-openapi.mjs
// ─────────────────────────────────────────────────────────────────────────────
import { createSwaggerSpec } from "next-swagger-doc";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const definition = {
  openapi: "3.0.0",
  info: {
    title: "Postbase API Documentation",
    version: "1.0",
  },
  components: {
    securitySchemes: {
      BearerAuth: {
        type: "http",
        scheme: "bearer",
        bearerFormat: "JWT",
      },
    },
  },
  security: [],
};

const out = resolve("src/app/docs/rest-spec.json");
mkdirSync(dirname(out), { recursive: true });

let spec = definition;
try {
  spec = await createSwaggerSpec({ apiFolder: "src/app/api", definition });
} catch (error) {
  // Never fail the image build over the docs: fall back to the bare definition
  // (the route still appends the auto-detected database schemas at runtime).
  console.warn("[openapi] next-swagger-doc scan failed, writing the base definition:", error);
}

writeFileSync(out, `${JSON.stringify(spec, null, 2)}\n`);

const pathCount = spec && spec.paths ? Object.keys(spec.paths).length : 0;
console.log(`[openapi] wrote ${out} (paths detected: ${pathCount})`);
