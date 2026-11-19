import { defineApp } from "convex/server";
import betterAuth from "@convex-dev/better-auth/convex.config";
import auth from "@convex-dev/auth/convex.config";
import authPassword from "@convex-dev/auth/components/password/convex.config";
import authUsername from "@convex-dev/auth/components/username/convex.config";

const app = defineApp();
app.use(betterAuth);
// Convex Auth v2 (the "Convex Auth" mode of the Flutter demo): the core
// component must keep its default name, `auth`, and each sign-in method
// brings its own components.
app.use(auth);
app.use(authPassword);
app.use(authUsername);

export default app;
