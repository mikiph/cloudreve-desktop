import assert from "node:assert/strict";
import test from "node:test";
import { getRecoveryProgress } from "../src/pages/popup/recoveryProgress.ts";
import type { StatusSummary } from "../src/pages/popup/types.ts";

type Health = NonNullable<StatusSummary["sync_health"]>[number];
function drive(phase: "checking" | "applying" | "completed", completed: number, total: number, items = 0): Health {
  return {
    drive_id: "test", connected: true,
    recovery: {
      phase, items_checked: items, folders_checked: 0, updated_at: 0,
      folder_progress: { completed, total, remaining: total - completed, items_checked: items, pages_checked: completed, retrying: 0 },
    },
  };
}

test("aggregates active folder checks without stale completed-drive counters", () => {
  assert.deepEqual(getRecoveryProgress([
    drive("applying", 37, 129), drive("completed", 3000, 3000), drive("applying", 3, 10),
  ]), { kind: "folders", completed: 40, total: 139 });
});

test("shows only server items while the server checking phase is displayed", () => {
  assert.deepEqual(getRecoveryProgress([
    drive("applying", 37, 129, 5000), drive("checking", 0, 0, 482),
    drive("checking", 0, 0, 18), drive("completed", 3000, 3000, 99999),
  ]), { kind: "items", checked: 500 });
});

test("keeps large counts and accepts total growth without inventing a percentage", () => {
  assert.deepEqual(getRecoveryProgress([drive("applying", 1209, 3000)]),
    { kind: "folders", completed: 1209, total: 3000 });
  assert.deepEqual(getRecoveryProgress([drive("applying", 1209, 3017)]),
    { kind: "folders", completed: 1209, total: 3017 });
});

test("does not display a previous check or a zero-total delivery wait", () => {
  assert.equal(getRecoveryProgress([drive("completed", 3000, 3000)]), null);
  assert.equal(getRecoveryProgress([drive("applying", 0, 0)]), null);
  assert.deepEqual(getRecoveryProgress([drive("checking", 0, 0)]), { kind: "items", checked: 0 });
});
