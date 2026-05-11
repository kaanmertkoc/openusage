export type UpdateStatus =
  | { status: "idle" }
  | { status: "checking" }
  | { status: "up-to-date" }
  | { status: "downloading"; progress: number } // 0-100, or -1 if indeterminate
  | { status: "installing" }
  | { status: "ready" }
  | { status: "error"; message: string }

interface UseAppUpdateReturn {
  updateStatus: UpdateStatus
  triggerInstall: () => void
  checkForUpdates: () => void
}

export function useAppUpdate(): UseAppUpdateReturn {
  return {
    updateStatus: { status: "idle" },
    triggerInstall: () => {},
    checkForUpdates: () => {},
  }
}
