#!/usr/bin/env node
// Encrypts a HarmonyOS store/key password using the machine-wide auto-signing
// material tree (~/.ohos/config/material), exactly as DevEco Studio does, and
// prints the hex string to place into build-profile.json5 signingConfigs.
//
// hvigor's CommonSignCommandBuilder ALWAYS treats signingConfigs' storePassword
// /keyPassword as an AES-GCM encrypted hex blob (never plain text), and derives
// the key from <storeFile parent dir>/material/{fd,ac,ce}. This script mirrors
// DecipherUtil.* (decipher-util.js):
//   getKey:   key  = PBKDF2(xor(fd0,fd1,fd2,component), salt=ac, 10000, 16)
//             master = AES-GCM-decrypt(key, ce-blob)
//   encrypt:  hex  = AES-GCM-encrypt(master, realPassword)
// Usage: node ohos-sign-password.mjs <materialDir> <realPassword>
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [, , materialDirArg, passwordArg] = process.argv;
if (!materialDirArg || !passwordArg) {
  console.error('usage: node ohos-sign-password.mjs <materialDir> <realPassword>');
  process.exit(2);
}
const materialDir = path.resolve(materialDirArg, 'material'); // e.g. ~/.ohos/config/material
const realPassword = passwordArg;

if (realPassword.length < 32 || realPassword.length % 2 !== 0) {
  console.error(`password must be >=32 chars and even length (got ${realPassword.length})`);
  process.exit(2);
}

const component = Buffer.from([49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119]);

const readDirSingle = (p) => {
  const files = fs.readdirSync(p).filter((f) => f !== '.DS_Store');
  if (files.length !== 1) throw new Error(`expected 1 file in ${p}, got ${files.length}`);
  return fs.readFileSync(path.join(p, files[0]));
};

// --- parse <materialDir>/fd/<n>  ---
const fd0 = readDirSingle(path.join(materialDir, 'fd', '0'));
const fd1 = readDirSingle(path.join(materialDir, 'fd', '1'));
const fd2 = readDirSingle(path.join(materialDir, 'fd', '2'));
if (![fd0, fd1, fd2].every((b) => b.length === 16)) throw new Error('fd components must be 16 bytes');
const salt = readDirSingle(path.join(materialDir, 'ac'));
const ceBlob = readDirSingle(path.join(materialDir, 'ce'));

const xorBufs = (...bufs) => {
  const n = bufs[0].length;
  bufs.forEach((b) => { if (b.length !== n) throw new Error('xor length mismatch'); });
  const out = Buffer.alloc(n);
  for (let i = 0; i < n; i++) { let v = 0; for (const b of bufs) v ^= b[i]; out[i] = v; }
  return out;
};
const xored = xorBufs(fd0, fd1, fd2, component);

// key derivation for the material tree.
// NOTE: hvigor calls pbkdf2Sync(xored.toString('utf8'), ...), so the "password"
// is xored's bytes decoded then re-encoded as UTF-8 (NOT the raw bytes).
const key1 = crypto.pbkdf2Sync(xored.toString('utf8'), salt, 10000, 16, 'sha256');

// Parse an AES-GCM blob exactly as hvigor's DecipherUtil.decrypt segments it:
//   e2 = readUInt32BE(0)          // header
//   i  = blob.len - 4 - e2        // -> IV length
//   IV = blob[4 .. 4+i]
//   ct = blob[4+i .. len-16]
//   tag = blob[len-16 .. len]
const parseBlob = (blob) => {
  const e2 = blob.readUInt32BE(0);
  const i = blob.length - 4 - e2;
  if (i < 0 || 4 + i > blob.length - 16) throw new Error('blob too short');
  const iv = blob.subarray(4, 4 + i);
  const ct = blob.subarray(4 + i, blob.length - 16);
  const tag = blob.subarray(blob.length - 16);
  return { iv, ct, tag };
};

const gcmDecrypt = (key, blob) => {
  const { iv, ct, tag } = parseBlob(blob);
  const d = crypto.createDecipheriv('aes-128-gcm', key, iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]);
};
// Encrypt with the same layout: header = ctLen+16, 16-byte IV, ct, 16-byte tag
const gcmEncrypt = (key, pt) => {
  const iv = crypto.randomBytes(16);
  const e = crypto.createCipheriv('aes-128-gcm', key, iv);
  const ct = Buffer.concat([e.update(pt), e.final()]);
  const tag = e.getAuthTag();
  const blob = Buffer.alloc(4 + iv.length + ct.length + tag.length);
  blob.writeUInt32BE(ct.length + 16, 0);
  iv.copy(blob, 4);
  ct.copy(blob, 4 + iv.length);
  tag.copy(blob, blob.length - tag.length);
  return blob;
};

// master key = decrypted ce (the global signing-material master key)
const master = gcmDecrypt(key1, ceBlob);
const hex = gcmEncrypt(master, Buffer.from(realPassword, 'utf8')).toString('hex');

// self-verify: batch-decrypt with the same master to prove round-trip correctness
const check = gcmDecrypt(master, Buffer.from(hex, 'hex')).toString('utf8');
if (check !== realPassword) { console.error('self-verify FAILED'); process.exit(1); }

console.log(`encryptedHex: ${hex}`);