import assert from "node:assert/strict";
import test from "node:test";

const validEnv = {
  RPC_URL: "http://127.0.0.1:8545",
  KEEPER_PRIVATE_KEY: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  VAULT_ADDRESS: "0x0000000000000000000000000000000000000001",
};

process.env.KEEPER_PRIVATE_KEY = validEnv.KEEPER_PRIVATE_KEY;
process.env.VAULT_ADDRESS = validEnv.VAULT_ADDRESS;

const { validateConfig } = await import("./config.js");

test("validateConfig accepts required keeper settings", () => {
  const config = validateConfig(validEnv);

  assert.equal(config.rpcUrl, validEnv.RPC_URL);
  assert.equal(config.privateKey, validEnv.KEEPER_PRIVATE_KEY);
  assert.equal(config.vaultAddress, validEnv.VAULT_ADDRESS);
  assert.equal(config.dryRun, false);
});

test("validateConfig rejects missing private key", () => {
  assert.throws(
    () => validateConfig({ ...validEnv, KEEPER_PRIVATE_KEY: "" }),
    /KEEPER_PRIVATE_KEY/,
  );
});

test("validateConfig rejects zero vault address", () => {
  assert.throws(
    () => validateConfig({ ...validEnv, VAULT_ADDRESS: "0x0000000000000000000000000000000000000000" }),
    /VAULT_ADDRESS/,
  );
});

test("validateConfig parses dry run flag", () => {
  const config = validateConfig({ ...validEnv, DRY_RUN: "true" });

  assert.equal(config.dryRun, true);
});
