import { httpRouter } from "convex/server";
import { authComponent, createAuth } from "./auth";

const http = httpRouter();

authComponent.registerRoutes(http, createAuth, {
  cors: {
    exposedHeaders: ["set-auth-token", "Set-Auth-Token"],
  },
});

export default http;
