import type { StatusSummary } from "./types";

type RecoveryProgress =
  | { kind: "items"; checked: number }
  | { kind: "folders"; completed: number; total: number };

// Only include work in the phase shown in the footer. A completed drive can
// retain its previous counters while another drive starts a new check.
export function getRecoveryProgress(
  health: NonNullable<StatusSummary["sync_health"]>,
): RecoveryProgress | null {
  const checking = health.filter((entry) => entry.recovery?.phase === "checking");
  if (checking.length > 0) {
    return {
      kind: "items",
      checked: checking.reduce((sum, entry) => sum + (entry.recovery?.items_checked ?? 0), 0),
    };
  }
  const folders = health
    .filter((entry) => entry.recovery?.phase === "applying")
    .flatMap((entry) => entry.recovery?.folder_progress ? [entry.recovery.folder_progress] : []);
  const total = folders.reduce((sum, progress) => sum + progress.total, 0);
  if (total === 0) return null;
  return {
    kind: "folders",
    completed: folders.reduce((sum, progress) => sum + progress.completed, 0),
    total,
  };
}
