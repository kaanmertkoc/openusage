import crypto from "node:crypto"
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest"
import { makeCtx } from "../test-helpers.js"

// The claude-work tile is pinned to a second account at this absolute dir.
// Keep in sync with ACCOUNT_CONFIG_DIR in plugin.js.
const ACCOUNT_CONFIG_DIR = "/Users/kaankoc/.claude-work"
const ACCOUNT_CRED_FILE = ACCOUNT_CONFIG_DIR + "/.credentials.json"
const expectedHash = (path) =>
  crypto.createHash("sha256").update(path).digest("hex").slice(0, 8)
const HASHED_SERVICE = "Claude Code-credentials-" + expectedHash(ACCOUNT_CONFIG_DIR)
const LEGACY_SERVICE = "Claude Code-credentials" // the DEFAULT account's entry

const USAGE_OK = {
  status: 200,
  bodyText: JSON.stringify({
    five_hour: { utilization: 10, resets_at: "2099-01-01T00:00:00.000Z" },
  }),
}

let plugin = null

beforeAll(async () => {
  await import("./plugin.js")
  plugin = globalThis.__openusage_plugin
})

beforeEach(() => {
  plugin?._resetState()
})

describe("claude-work plugin (second-account isolation)", () => {
  it("exposes the claude-work id", () => {
    expect(plugin.id).toBe("claude-work")
  })

  it("reads the pinned account's credentials file and passes its dir to ccusage", () => {
    const ctx = makeCtx()
    const creds = JSON.stringify({
      claudeAiOauth: { accessToken: "work-token", subscriptionType: "max" },
    })
    ctx.host.fs.exists = vi.fn((path) => path === ACCOUNT_CRED_FILE)
    ctx.host.fs.readText = vi.fn((path) => {
      if (path !== ACCOUNT_CRED_FILE) throw new Error("unexpected readText: " + path)
      return creds
    })
    ctx.host.http.request.mockReturnValue(USAGE_OK)
    ctx.host.ccusage.query = vi.fn(() => ({ status: "ok", data: { daily: [] } }))

    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
    expect(ctx.host.fs.readText).toHaveBeenCalledWith(ACCOUNT_CRED_FILE)
    expect(ctx.host.ccusage.query).toHaveBeenCalledWith(
      expect.objectContaining({ homePath: ACCOUNT_CONFIG_DIR })
    )
  })

  it("looks up ONLY the hashed keychain service, never the legacy default entry", () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockImplementation((service) =>
      service === HASHED_SERVICE
        ? JSON.stringify({ claudeAiOauth: { accessToken: "work-token", subscriptionType: "max" } })
        : null
    )
    ctx.host.http.request.mockReturnValue(USAGE_OK)

    const result = plugin.probe(ctx)

    expect(result.lines.find((l) => l.label === "Session")).toBeTruthy()
    const services = ctx.host.keychain.readGenericPasswordForCurrentUser.mock.calls.map((c) => c[0])
    expect(services).toEqual([HASHED_SERVICE])
    expect(services).not.toContain(LEGACY_SERVICE)
  })

  it("does NOT inherit the default account's unhashed credentials (isolation)", () => {
    const ctx = makeCtx()
    ctx.host.fs.exists = () => false
    // Only the DEFAULT account's legacy entry has credentials. The work tile
    // must ignore it and report not-logged-in until its own account is set up.
    ctx.host.keychain.readGenericPasswordForCurrentUser.mockImplementation((service) =>
      service === LEGACY_SERVICE
        ? JSON.stringify({ claudeAiOauth: { accessToken: "personal-token", subscriptionType: "pro" } })
        : null
    )
    ctx.host.keychain.readGenericPassword.mockImplementation((service) =>
      service === LEGACY_SERVICE
        ? JSON.stringify({ claudeAiOauth: { accessToken: "personal-token", subscriptionType: "pro" } })
        : null
    )

    expect(() => plugin.probe(ctx)).toThrow("Not logged in")
  })

  it("ignores CLAUDE_CONFIG_DIR from the shared process env", () => {
    const ctx = makeCtx()
    // Even if some other account's dir leaks into the env, this tile stays pinned.
    ctx.host.env.get.mockImplementation((name) =>
      name === "CLAUDE_CONFIG_DIR" ? "/Users/kaankoc/.claude-other" : null
    )
    ctx.host.fs.exists = vi.fn((path) => path === ACCOUNT_CRED_FILE)
    ctx.host.fs.readText = vi.fn((path) => {
      if (path !== ACCOUNT_CRED_FILE) throw new Error("unexpected readText: " + path)
      return JSON.stringify({ claudeAiOauth: { accessToken: "work-token", subscriptionType: "max" } })
    })
    ctx.host.http.request.mockReturnValue(USAGE_OK)
    ctx.host.ccusage.query = vi.fn(() => ({ status: "ok", data: { daily: [] } }))

    plugin.probe(ctx)

    expect(ctx.host.ccusage.query).toHaveBeenCalledWith(
      expect.objectContaining({ homePath: ACCOUNT_CONFIG_DIR })
    )
  })
})
