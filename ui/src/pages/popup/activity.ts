import type { TaskRecord } from "./types";

const HISTORY_WINDOW_SECONDS = 2 * 60;

export function groupRecentTasks(tasks: TaskRecord[]): TaskRecord[][] {
  const groups: TaskRecord[][] = [];
  const nativeTransfers = new Map<string, TaskRecord[]>();

  for (const task of tasks) {
    // Native retries can be hours apart and interleaved with unrelated files.
    // Keep one row per transfer target, with its full history available on demand.
    if (task.id.startsWith("fp-transfer-")) {
      const key = JSON.stringify([task.drive_id, task.local_path, task.task_type]);
      const existing = nativeTransfers.get(key);
      if (existing) {
        existing.push(task);
      } else {
        const group = [task];
        nativeTransfers.set(key, group);
        groups.push(group);
      }
      continue;
    }
    const current = groups[groups.length - 1];
    const newest = current?.[0];
    const belongsToCurrent =
      newest &&
      !newest.id.startsWith("fp-transfer-") &&
      newest.drive_id === task.drive_id &&
      newest.local_path === task.local_path &&
      task.updated_at <= newest.updated_at &&
      newest.updated_at - task.updated_at <= HISTORY_WINDOW_SECONDS;

    if (belongsToCurrent) {
      current.push(task);
    } else {
      groups.push([task]);
    }
  }

  return groups;
}
