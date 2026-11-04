import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export interface ClockPreferences {
  hour12: boolean | null;
  system_hour12: boolean | null;
}

export function useClockPreferences() {
  const [preferences, setPreferences] = useState<ClockPreferences>({ hour12: null, system_hour12: null });
  useEffect(() => {
    let cancelled = false;
    const refresh = () => invoke<ClockPreferences>("get_clock_preferences")
      .then((value) => { if (!cancelled && value) setPreferences(value); })
      .catch(console.error);
    void refresh();
    const listener = listen("clock-preferences-changed", refresh);
    window.addEventListener("focus", refresh);
    return () => {
      cancelled = true;
      window.removeEventListener("focus", refresh);
      void listener.then((unlisten) => unlisten());
    };
  }, []);
  const hour12 = preferences.hour12 ?? preferences.system_hour12 ?? undefined;
  return {
    preferences,
    setPreferences,
    formatTime: (timestamp: number) => new Date(timestamp).toLocaleTimeString(undefined, {
      hour: "numeric", minute: "2-digit",
      hourCycle: hour12 === undefined ? undefined : hour12 ? "h12" : "h23",
    }),
  };
}
