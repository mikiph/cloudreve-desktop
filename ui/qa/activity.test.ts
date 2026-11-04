import assert from "node:assert/strict";
import test from "node:test";
import { groupRecentTasks } from "../src/pages/popup/activity.ts";
import type { TaskRecord } from "../src/pages/popup/types.ts";
function task(id: string, time: number, path = "/App.app/Contents/PlugIns/Extension.appex", drive = "one", status: TaskRecord["status"] = "Failed"): TaskRecord {
  return { id, drive_id: drive, task_type: "upload", local_path: path, status,
    progress: 0, total_bytes: 96, processed_bytes: 0, created_at: time, updated_at: time,
    error: status === "Failed" ? "An upload error" : undefined };
}
test("hours of interleaved native retries appear once with expandable history", () => {
  const retries = Array.from({ length: 27 }, (_, i) => task(`fp-transfer-${i}`, 100000 - i * 7200));
  const groups = groupRecentTasks([retries[0], task("other-file", 99999, "/other.txt"), ...retries.slice(1)]);
  assert.equal(groups.length, 2);
  assert.equal(groups[0].length, 27);
  assert.equal(groups[0][0].id, "fp-transfer-0");
});
test("successful retry leads the row while earlier errors stay in history", () => {
  const groups = groupRecentTasks([task("fp-transfer-ok", 9000, undefined, undefined, "Completed"), task("fp-transfer-failed", 1000)]);
  assert.equal(groups.length, 1);
  assert.equal(groups[0][0].status, "Completed");
  assert.equal(groups[0][1].status, "Failed");
});
test("never combines different drives, upload/download directions or filenames", () => {
  const first = task("fp-transfer-1", 9000);
  const groups = groupRecentTasks([first, task("fp-transfer-2", 8000, undefined, "two"), task("fp-transfer-3", 7000, "/other.appex"), { ...first, id: "fp-transfer-4", task_type: "download", updated_at: 6000 }]);
  assert.equal(groups.length, 4);
});
test("ordinary activity retains its short grouping window", () => {
  assert.equal(groupRecentTasks([task("one", 9000), task("two", 8950)]).length, 1);
  assert.equal(groupRecentTasks([task("one", 9000), task("two", 1000)]).length, 2);
});
