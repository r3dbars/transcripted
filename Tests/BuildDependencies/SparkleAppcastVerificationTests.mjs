import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { generateKeyPairSync, sign } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const directory = mkdtempSync(join(tmpdir(), "transcripted-appcast-test-"));
after(() => rmSync(directory, { recursive: true, force: true }));
const version = "99.99.99";
const content = Buffer.from(`<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><title>Transcripted Updates</title><item>
    <title>Transcripted ${version}</title>
    <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
    <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
    <enclosure url="https://github.com/r3dbars/transcripted/releases/download/v${version}/Transcripted-${version}.dmg" length="1" sparkle:edSignature="fixture"/>
  </item></channel>
</rss>
`);
const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const publicBase64 = key => key.export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
const trustedKey = publicBase64(publicKey);
const signature = sign(null, content, privateKey).toString("base64");
const trailer = (length = content.length) =>
    Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${signature}\nlength: ${length}\n-->\n`);
const signed = Buffer.concat([content, trailer()]);
const changed = Buffer.from(signed.toString().replace("Transcripted Updates", "Transcripted updates"));

function verifyFixture(name, bytes, key = trustedKey) {
    const path = join(directory, `${name}.xml`);
    writeFileSync(path, bytes);
    return spawnSync(process.execPath, [join(root, "scripts/release/verify-sparkle-appcast.mjs"), path, key],
        { encoding: "utf8" });
}

test("verifies signed bytes using only the public key", () => {
    const result = verifyFixture("valid", signed);
    assert.equal(result.status, 0, result.stderr);
});

test("rejects a signed feed whose content changed without changing length", () => {
    const result = verifyFixture("changed", changed);
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /does not match SUPublicEDKey/);
});

test("rejects a missing signature, wrong signing key, wrong length and unsigned tail", () => {
    const wrongKey = publicBase64(generateKeyPairSync("ed25519").publicKey);
    assert.equal(verifyFixture("unsigned", content).status, 1);
    assert.equal(verifyFixture("wrong-key", signed, wrongKey).status, 1);
    assert.equal(verifyFixture("wrong-length", Buffer.concat([content, trailer(1)])).status, 1);
    assert.equal(verifyFixture("unsigned-tail", Buffer.concat([signed, Buffer.from("<!-- unsigned -->\n")])).status, 1);
});

test("offline candidate command accepts an unpublished feed and rejects an edit", {
    skip: process.platform !== "darwin" && "the release command uses macOS PlistBuddy",
}, () => {
    const plist = join(directory, "Info.plist");
    copyFileSync(join(root, "Info.plist"), plist);
    for (const command of [`Set :SUPublicEDKey ${trustedKey}`, "Set :LSMinimumSystemVersion 26.0"]) {
        const edit = spawnSync("/usr/libexec/PlistBuddy", ["-c", command, plist], { encoding: "utf8" });
        assert.equal(edit.status, 0, edit.stderr);
    }
    const bin = join(directory, "bin");
    mkdirSync(bin);
    for (const name of ["gh", "curl"]) {
        writeFileSync(join(bin, name), "#!/bin/sh\nexit 99\n", { mode: 0o700 });
    }
    const path = join(directory, "unpublished.xml");
    const options = { encoding: "utf8", env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        VERIFY_APPCAST_FILE: path,
        VERIFY_INFO_PLIST: plist,
    } };
    const argv = [join(root, "scripts/release/verify-sparkle-release.sh"), version];
    writeFileSync(path, signed);
    const passed = spawnSync("bash", argv, options);
    assert.equal(passed.status, 0, passed.stderr);
    assert.match(passed.stdout, /verified offline/);
    writeFileSync(path, changed);
    const failed = spawnSync("bash", argv, options);
    assert.equal(failed.status, 1, failed.stderr);
    assert.match(failed.stderr, /does not match SUPublicEDKey/);
});
