# Connection Liveness Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop reachable paired devices from being reported offline after discovery aging or a fatal macOS listener failure.

**Architecture:** Treat mDNS as a source of current host candidates, not proof of reachability: liveness must probe `/v1/id` and match the paired device ID. Keep Windows-discovered peers as last-known host candidates because the Windows DNS-SD browse API reports discoveries but does not provide a reliable 10-second lease. On macOS, observe `NWListener.State` and recreate a listener after `.failed`, using a bounded retry delay.

**Tech Stack:** C#/.NET 8/WPF/xUnit v3; Swift 6.1/Network.framework/Swift Testing.

## Global Constraints

- Preserve wire protocol version `v = 1` and TCP port `51888`.
- A device is online only when `/v1/id` returns its paired device ID.
- Keep existing user pairing data and encryption keys unchanged.
- Do not add external dependencies.

---

### Task 1: Probe mDNS candidates and retain their current hosts on Windows

**Files:**
- Modify: `ClipboardSS.Windows/tests/ClipboardSS.App.Tests/DeviceLivenessTests.cs`
- Modify: `ClipboardSS.Windows/src/ClipboardSS.App/Net/DeviceLiveness.cs`
- Modify: `ClipboardSS.Windows/src/ClipboardSS.App/Net/MdnsService.cs`

**Interfaces:**
- Consumes: `Peer(Id, Name, Host, Port)` from DNS-SD and `PairedDevice(Id, Name, Host)` from storage.
- Produces: `DeviceLiveness.ResolveOnlineDeviceIdsAsync(...)` that probes current mDNS hosts first and falls back to a distinct stored host.

- [ ] **Step 1: Write failing liveness tests**

```csharp
[Fact]
public async Task MdnsPeerMustAnswerWithMatchingIdentityToBeOnline()
{
    var id = Guid.NewGuid();
    var probed = new List<string>();
    var online = await DeviceLiveness.ResolveOnlineDeviceIdsAsync(
        [new PairedDevice(id, "Mac", "192.168.0.10")],
        [new Peer(id, "Mac", "192.168.0.11", 51888)],
        (host, _) => { probed.Add(host); return Task.FromResult<Peer?>(null); });
    Assert.Empty(online);
    Assert.Equal(["192.168.0.11", "192.168.0.10"], probed);
}

[Fact]
public async Task CurrentMdnsHostMarksDeviceOnlineAfterStoredAddressChanges()
{
    var id = Guid.NewGuid();
    var online = await DeviceLiveness.ResolveOnlineDeviceIdsAsync(
        [new PairedDevice(id, "Mac", "192.168.0.10")],
        [new Peer(id, "Mac", "192.168.0.11", 51888)],
        (host, _) => Task.FromResult<Peer?>(host == "192.168.0.11"
            ? new Peer(id, "Mac", host, 51888) : null));
    Assert.Contains(id, online);
}
```

- [ ] **Step 2: Run the targeted tests and verify RED**

Run: `dotnet test ClipboardSS.Windows/tests/ClipboardSS.App.Tests/ClipboardSS.App.Tests.csproj --filter 'FullyQualifiedName~DeviceLivenessTests'`

Expected: `MdnsPeerMustAnswerWithMatchingIdentityToBeOnline` fails because the current code trusts mDNS without probing.

- [ ] **Step 3: Implement candidate probing**

For each paired device, build an ordered, distinct candidate list from the matching mDNS peer host followed by the stored host. Probe candidates until one returns the same device ID; mark the device online only then.

- [ ] **Step 4: Remove the invalid 10-second Windows mDNS lease**

Remove `SeenPeer.LastSeen`, `_pruneTimer`, and `Prune()`. Store discovered `Peer` values directly until the browse session ends; active identity probes now determine online/offline state.

- [ ] **Step 5: Run the targeted and full Windows test suites**

Run: `dotnet test ClipboardSS.Windows/tests/ClipboardSS.App.Tests/ClipboardSS.App.Tests.csproj --filter 'FullyQualifiedName~DeviceLivenessTests'`

Run: `dotnet test ClipboardSS.Windows/ClipboardSS.Windows.sln`

Expected: PASS.

### Task 2: Recover the macOS TCP listener after fatal failure

**Files:**
- Modify: `Tests/ClipboardSSTests/ClipServerTests.swift`
- Modify: `Sources/ClipboardSS/ClipServer.swift`

**Interfaces:**
- Consumes: `NWListener.State.failed`, which Apple defines as fatal for that listener instance.
- Produces: an idempotent `start()`, terminal `stop()`, and internal bounded retry scheduling that creates a fresh `NWListener` after failure.

- [ ] **Step 1: Write failing retry-policy tests**

```swift
@Test("listener retry delay backs off and caps")
func listenerRetryDelay() {
    #expect(ClipServer.retryDelaySeconds(failureCount: 1) == 1)
    #expect(ClipServer.retryDelaySeconds(failureCount: 2) == 2)
    #expect(ClipServer.retryDelaySeconds(failureCount: 8) == 30)
}
```

- [ ] **Step 2: Run the targeted Swift test and verify RED on macOS**

Run: `swift test --filter ClipServerTests`

Expected: FAIL because `retryDelaySeconds(failureCount:)` does not exist.

- [ ] **Step 3: Implement listener state observation and recovery**

Keep listener lifecycle on one private serial queue. On `.ready`, reset the failure count. On `.failed`, log the error, cancel and discard that listener, then create and start a fresh listener after `retryDelaySeconds`; cap the delay at 30 seconds. `stop()` cancels both pending retry work and the active listener.

- [ ] **Step 4: Run the targeted and full Swift test suites on macOS**

Run: `swift test --filter ClipServerTests`

Run: `swift test`

Expected: PASS.

### Task 3: Verify the end-to-end Windows side and document the Mac handoff

**Files:**
- Modify only if needed by build output: files from Tasks 1-2.

**Interfaces:**
- Consumes: running Windows app and the Mac build commands.
- Produces: verified Windows artifacts plus exact Mac commands for build/install verification.

- [ ] **Step 1: Build Windows**

Run: `dotnet build ClipboardSS.Windows/ClipboardSS.Windows.sln`

Expected: PASS with no new warnings.

- [ ] **Step 2: Recheck the regression evidence**

Run: `curl.exe -sS --max-time 2 http://127.0.0.1:51888/v1/id`

Expected: HTTP JSON identity from Windows. The Mac should report online only after its restarted listener answers `/v1/id` with paired ID `8fb5790c-4533-47bb-90af-827291247fe1`.

- [ ] **Step 3: Provide Mac commands**

Provide commands to fetch the branch, run `swift test`, build `ClipboardSS.app`, replace the installed copy, and verify `curl http://<mac-ip>:51888/v1/id` from Windows.

