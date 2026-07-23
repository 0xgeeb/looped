import assert from "node:assert/strict";
import test from "node:test";

process.env.KEEPER_PRIVATE_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
process.env.VAULT_ADDRESS = "0x0000000000000000000000000000000000000001";

const { assertKeeperIsStrategist } = await import("./keeper.js");

const keeperAddress = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";

test("assertKeeperIsStrategist accepts matching strategist", () => {
  assert.doesNotThrow(() => {
    assertKeeperIsStrategist(keeperAddress, keeperAddress);
  });
});

test("assertKeeperIsStrategist accepts checksum differences", () => {
  assert.doesNotThrow(() => {
    assertKeeperIsStrategist(keeperAddress, "0xF39fD6e51aad88F6F4ce6aB8827279cffFb92266");
  });
});

test("assertKeeperIsStrategist rejects mismatched strategist", () => {
  assert.throws(
    () => assertKeeperIsStrategist(keeperAddress, "0x0000000000000000000000000000000000000002"),
    /does not match vault strategist/,
  );
});
