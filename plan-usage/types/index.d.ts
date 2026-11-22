export type Window = { kind: string; percentUsed: number; resetsAt?: string }

export type Context = { tokens?: number; window: number; percent?: number }

// What was last measured, and the clock time (ms) it was read or re-timed at.
// `context` and `costUsd` are optional so a snapshot stored by the first
// version (windows and time only) still reads.
export type Snapshot = {
  windows: Window[]
  at: number
  context?: Context
  costUsd?: number
}

declare module 'claude-code' {
  interface PluginState {
    'plan-usage': { snapshot: Snapshot | null }
  }
}
