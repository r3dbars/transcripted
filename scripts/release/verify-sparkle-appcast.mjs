import { createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";

// Sparkle 2.9 signs the original bytes before its trailing signature comment.
// Keep this check on bytes so XML serialization and newline conversion cannot
// alter the input to Ed25519. Accept only the trailer produced by sign_update.
function verifyAppcast(bytes, publicKey) {
    const marker = Buffer.from("<!-- sparkle-signatures:\n");
    const boundary = bytes.lastIndexOf(marker);
    if (boundary <= 0) {
        throw new Error("The appcast is missing its Sparkle signature.");
    }

    const trailer = bytes.subarray(boundary + marker.length).toString("latin1");
    const fields = /^edSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n$/.exec(trailer);
    if (!fields || fields[0] !== trailer || fields[2] !== String(boundary)) {
        throw new Error("The appcast signature trailer or signed length is invalid.");
    }

    const rawKey = Buffer.from(publicKey, "base64");
    if (rawKey.length !== 32 || rawKey.toString("base64") !== publicKey) {
        throw new Error("SUPublicEDKey must be a base64-encoded 32-byte Ed25519 public key.");
    }

    // DER SubjectPublicKeyInfo prefix for a 32-byte Ed25519 public key.
    const spkiPrefix = Buffer.from("302a300506032b6570032100", "hex");
    const key = createPublicKey({ key: Buffer.concat([spkiPrefix, rawKey]), format: "der", type: "spki" });
    const signature = Buffer.from(fields[1], "base64");
    if (!verify(null, bytes.subarray(0, boundary), key, signature)) {
        throw new Error("The appcast signature does not match SUPublicEDKey.");
    }
}

if (process.argv.length !== 4) {
    console.error("Usage: node scripts/release/verify-sparkle-appcast.mjs <appcast.xml> <SUPublicEDKey>");
    process.exit(1);
}

const [, , path, publicKey] = process.argv;
let bytes;
try {
    bytes = readFileSync(path);
} catch {
    console.error("Could not read the appcast.");
    process.exit(1);
}
try {
    verifyAppcast(bytes, publicKey);
    console.log("Sparkle appcast signature verified.");
} catch (error) {
    console.error(error.message);
    process.exitCode = 1;
}
