"use client";

import SwaggerUI from "swagger-ui-react";
import "swagger-ui-react/swagger-ui.css";
// Import the dark theme CSS statically (matches /docs/api).
import "swagger-themes/themes/dark.css";

type Props = {
  // URL of the OpenAPI document to render. Swagger UI fetches it client-side so
  // the /docs page stays a static shell while /docs/openapi.json is dynamic.
  url: string;
};

function ReactSwagger({ url }: Props) {
  return <SwaggerUI url={url} />;
}

export default ReactSwagger;
