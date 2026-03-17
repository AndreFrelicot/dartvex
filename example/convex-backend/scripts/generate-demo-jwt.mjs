import { createSign } from "node:crypto";

const privateKeyPem = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgcZP2wl/IC4t64+w3
k0nz6ay9akZDTWBv9Kg/W+KjGuahRANCAATbaZgxkWkLi2xvBV+7GIlpswKdR5fd
iAI4pwmFNv8mIul0MxNM5iR9DsF31Cp4kaOHDOFDES3JG0wtJO96Rhr0
-----END PRIVATE KEY-----`;

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
