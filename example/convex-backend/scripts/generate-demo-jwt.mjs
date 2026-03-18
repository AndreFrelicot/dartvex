import { createSign } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

let privateKeyPem = process.env.DEMO_PRIVATE_KEY;

if (!privateKeyPem) {
  try {
    const envPath = resolve(__dirname, "../.env");
    if (existsSync(envPath)) {
      const envContent = readFileSync(envPath, "utf-8");
      for (const line of envContent.split("\n")) {
        if (line.startsWith("DEMO_PRIVATE_KEY=")) {
          let val = line.substring("DEMO_PRIVATE_KEY=".length).trim();
          if (val.startsWith('"') && val.endsWith('"')) {
            val = val.substring(1, val.length - 1);
          }
          privateKeyPem = val.replace(/\\n/g, "\n");
          break;
        }
      }
    }
  } catch (e) {
    // Ignore read errors
  }
}

if (!privateKeyPem) {
  console.error("Error: DEMO_PRIVATE_KEY is not set.");
  console.error("Please copy .env.example to .env in example/convex-backend and try again.");
  process.exit(1);
}

const base64UrlEncode = (value) =>
  Buffer.from(
    typeof value === "string" ? value : JSON.stringify(value),
  ).toString("base64url");

const header = {
  alg: "ES256",
  typ: "JWT",
  kid: "demo-key-1",
};

const payload = {
  iss: "https://demo.convex-flutter-sdk.local",
  sub: process.env.DEMO_SUBJECT ?? "demo-user-1",
  aud: "convex-flutter-demo",
  name: process.env.DEMO_NAME ?? "Demo User",
  email: process.env.DEMO_EMAIL ?? "demo@example.com",
  iat: Math.floor(Date.now() / 1000),
  exp: 4102444800,
};

const signingInput = `${base64UrlEncode(header)}.${base64UrlEncode(payload)}`;
const signer = createSign("SHA256");
signer.update(signingInput);
signer.end();

const signature = signer
  .sign({
    key: privateKeyPem,
    dsaEncoding: "ieee-p1363",
  })
  .toString("base64url");

process.stdout.write(`${signingInput}.${signature}\n`);
