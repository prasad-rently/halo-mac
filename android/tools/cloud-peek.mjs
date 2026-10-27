#!/usr/bin/env node
// The "Mac side" for emulator testing: makes a pairing code, decrypts what the phone uploaded, and can
// publish a clipboard item the way the desktop does. It implements docs/specs/crypto-parity.md independently
// of the Kotlin and Swift code (Node's own crypto), so a successful decrypt is a cross-implementation check.
//
//   node cloud-peek.mjs pair  <port> <passphrase>            -> prints the pairing code (base64 payload)
//   node cloud-peek.mjs dump  <port> <passphrase>            -> decrypts everything under sms/ and clipboard/
//   node cloud-peek.mjs clip  <port> <passphrase> <text>     -> publishes a clipboard item from device "mac-sim"
//   node cloud-peek.mjs line  <port> <deviceId> <sub> on|off -> flips a SIM line's sync toggle (the desktop's D29 write)
import crypto from "node:crypto";
import fs from "node:fs";

const [cmd, port, pass, ...rest] = process.argv.slice(2);
const base = `http://127.0.0.1:${port}`;
const SALT = Buffer.from("halo-test-salt!!"); // 16 bytes
const ITER = 600000, UID = "uid-test-1", AAD = Buffer.from("halo.cloud.v1");
const saltB64 = SALT.toString("base64");
const key = () => crypto.pbkdf2Sync(pass.normalize("NFC"), SALT, ITER, 32, "sha256");

function open(env, k) {
  const v1 = env.startsWith("v1:"); const raw = Buffer.from(v1 ? env.slice(3) : env, "base64");
  const d = crypto.createDecipheriv("aes-256-gcm", k, raw.subarray(0, 12));
  if (v1) d.setAAD(AAD); d.setAuthTag(raw.subarray(raw.length - 16));
  return Buffer.concat([d.update(raw.subarray(12, raw.length - 16)), d.final()]).toString("utf8");
}
function seal(text, k) {
  const nonce = crypto.randomBytes(12); const c = crypto.createCipheriv("aes-256-gcm", k, nonce); c.setAAD(AAD);
  const ct = Buffer.concat([c.update(text, "utf8"), c.final()]);
  return "v1:" + Buffer.concat([nonce, ct, c.getAuthTag()]).toString("base64");
}
async function login() {
  const r = await fetch(`${base}/identitytoolkit/v1/accounts:signInWithPassword?key=k`, { method: "POST", body: JSON.stringify({ email: "me@halo.test", password: "halo-test-password" }) });
  return (await r.json()).idToken;
}

if (cmd === "pair") {
  // databaseURL is what the EMULATOR dials; the phone reaches the Mac at 10.0.2.2.
  const cfg = { apiKey: "fake-api-key", projectID: "halo-local", googleAppID: "1:1:android:1", gcmSenderID: "1", databaseURL: `http://10.0.2.2:${port}`, storageBucket: null };
  const auth = { email: "me@halo.test", password: "halo-test-password" };
  const schema = 2;
  const fields = [cfg.apiKey, cfg.projectID, cfg.googleAppID, cfg.gcmSenderID, cfg.databaseURL, cfg.storageBucket ?? "", auth.email, auth.password, saltB64, String(schema), String(ITER)];
  const checksum = crypto.createHash("sha256").update(fields.join("|")).digest("hex");
  const payload = { firebaseConfig: cfg, auth, saltBase64: saltB64, schema, iterations: ITER, checksum };
  console.log(Buffer.from(JSON.stringify(payload)).toString("base64"));
} else if (cmd === "dump") {
  const tree = await (await fetch(`${base}/_dump`)).json(); const k = key();
  const out = { devices: tree.devices?.[UID] ?? {}, sms: {}, clipboard: [] };
  for (const [dev, node] of Object.entries(tree.sms?.[UID] ?? {})) {
    out.sms[dev] = { lines: {}, messages: [] };
    for (const [id, l] of Object.entries(node.lines ?? {})) out.sms[dev].lines[id] = { ...l, ownNumber: l.ownNumberEnc ? open(l.ownNumberEnc, k) : null, ownNumberEnc: undefined };
    for (const [id, m] of Object.entries(node.messages ?? {})) out.sms[dev].messages.push({ id, address: open(m.addressEnc, k), body: open(m.bodyEnc, k), date: m.date, sub: m.subscriptionId, read: m.read, type: m.type, hasThreadKey: !!m.threadKey, plaintextLeak: JSON.stringify(m).includes(open(m.bodyEnc, k)) });
  }
  for (const [id, c] of Object.entries(tree.clipboard?.[UID]?.items ?? {})) out.clipboard.push({ id, from: c.deviceName, kind: c.kind, text: open(c.contentEnc, k) });
  console.log(JSON.stringify(out, null, 2));
} else if (cmd === "clip") {
  const tok = await login(); const id = crypto.randomUUID().toUpperCase();
  const env = { itemId: id, deviceId: "mac-sim", deviceName: "Mac (simulated)", kind: "text", contentEnc: seal(rest.join(" "), key()), createdAt: Date.now(), schema: 1 };
  const r = await fetch(`${base}/clipboard/${UID}/items/${id}.json?auth=${tok}`, { method: "PUT", body: JSON.stringify(env) });
  console.log("published", id, r.status);
} else if (cmd === "line") {
  const [dev, sub, onoff] = [pass, ...rest]; const tok = await login();
  const r = await fetch(`${base}/sms/${UID}/${dev}/lines/${sub}/syncEnabled.json?auth=${tok}`, { method: "PUT", body: JSON.stringify(onoff === "on") });
  console.log("line", sub, onoff, r.status);
} else { console.error("usage: see header"); process.exit(2); }
