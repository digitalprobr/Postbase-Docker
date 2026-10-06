import ReactSwagger from "./react-swagger";

export const metadata = {
  title: "Postbase API Documentation",
};

// Swagger UI at /docs. The spec is served by /docs/openapi.json, which combines
// the hand-annotated REST endpoints with the live, auto-detected database
// schemas (see src/lib/openapi-from-db.ts).
export default function DocsPage() {
  return (
    <section className="container bg-background">
      <ReactSwagger url="/docs/openapi.json" />
    </section>
  );
}
