#!/usr/bin/env node

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const configPath = process.argv[2];
if (!configPath) {
  process.stderr.write("Usage: generate_asc_jwt.js <asc-api-key.json>\n");
  process.exit(64);
}

const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
const keyPath = path.resolve(config.keyPath);
const privateKey = fs.readFileSync(keyPath, "utf8");
const now = Math.floor(Date.now() / 1000);

function base64URL(value) {
  return Buffer.from(value)
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

const header = base64URL(
  JSON.stringify({
    alg: "ES256",
    kid: config.keyId,
    typ: "JWT",
  }),
);
const payload = base64URL(
  JSON.stringify({
    iss: config.issuerId,
    iat: now - 5,
    exp: now + 15 * 60,
    aud: "appstoreconnect-v1",
  }),
);
const signingInput = `${header}.${payload}`;
const signature = crypto.sign(
  "sha256",
  Buffer.from(signingInput),
  {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  },
);

process.stdout.write(`${signingInput}.${base64URL(signature)}`);

