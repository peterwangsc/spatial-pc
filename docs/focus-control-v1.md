# Focus control v1 — exact revision for review

Supersedes pc-focus-orchestration-draft-20260915.md. Accepted for isolated implementation with the two corrections in mac-focus-orchestration-revision-accepted-20260915.md incorporated here. No live changes.

## Transport and authority

Same backend, optional TCP47994, TLS1.3 mTLS, ALPN `spatialpc-control/1`. Existing saved CA/leaf/hostname/expiry checks and actual enrolled client fingerprint lookup; revoked/expired peers rejected. No tickets, early data, reconnect/resume or extra hello. No nonces, connectionId, seq, event counter, replay cache or credential fields.

Ownership is the authenticated socket plus an internal generation and server-created sessionId (32 lowercase hex). IDs are not bearer authority. Bind only the selected assigned Private address. Apple remains local TCP55000 with separate system QR; no custom token/pin API. The returned address must equal the established control socket's concrete remote address from Mac's perspective. IPv6 scope uses Mac's local interface index, never a copied Windows index. Accept Apple's connection only from the control peer address; this is routing restriction, not cryptographic ClientID binding.

Remote starts require master access enabled, a local Focus grant for this actual enrolled device, and reviewed components. New-device Focus consent can be included in the same Windows pairing approval. Existing ungranted devices get one local grant step. Already-granted devices get no additional prompt. Existing grants are never inferred or migrated automatically.

Mac resolves saved Bonjour service name/domain into concrete addresses WITHOUT opening desktop TLS; its saved SRV port is the desktop port, not control. Dial those addresses at fixed47994. Manual hosts use their saved address and47994. Never pass SavedHost.endpoint directly to control. Preserve local IPv6 scope and existing pins. No new Windows Bonjour service is required.

## Exact records

4-byte unsigned BIG-endian length +1..8192 strict UTF-8 JSON bytes. Apple55000 remains LITTLE-endian. Exact keys only; reject duplicate keys, unknown fields, floats/NaN, integer booleans and nesting>6.

Request: `{version:1,type:"request",id:integer,operation:string,parameters:object}`.

IDs are consecutive integers1..4096 on this socket, starting1. Duplicates/gaps reject and close; no retransmit. At4096 keep one reader watching EOF or any extra byte while the final response is pending; either cancels owned work immediately. No request4097 is processed. On normal completion drain the final response, confirm owned cleanup, then close. Replies can finish out of order and correlate only by id.

Successful response: `{version:1,type:"result",id:integer,result:object}`.

Error response: `{version:1,type:"error",id:integer,code:string}`.

Progress: `{version:1,type:"progress",id:integer,sessionId:string|null,state:string}`. id is the originating permission/prepare request; same request may have several progress records and exactly one terminal response. After prepare's response, its id still identifies session progress. No progress record is a second operation/result.

Codes: `unsupported`, `accessDisabled`, `permissionRequired`, `busy`, `rateLimited`, `wrongOwner`, `invalidState`, `desktopStopTimeout`, `setupTimeout`, `runtimeStartFailed`, `cleanupFailed`, `interfaceChanged`, `expired`, `canceled`. Invalid record framing/schema/IDs closes the socket instead of returning parser detail.

## Operations

| operation | exact parameters | terminal result |
|---|---|---|
| `capabilities` | `{}` | `{focusCompiled:bool,runtimeConfigured:bool,hardwareValidated:bool,consumerReady:bool,focusAllowed:bool,accessEnabled:bool,available:bool,mediaMode:"idle"|"desktop"|"focus"|"failed",content:"plain-scene-development",systemTrust:"apple-qr-separate",systemTrustPersistence:"unverified",mediaSecurity:"development-only",setupWindowSeconds:180,sessionLimitSeconds:600}` |
| `focus.requestPermission` | `{}` | `{granted:bool,reason:"none"|"denied"|"timeout"|"canceled"}` |
| `focus.prepare` | `{intent:"setup"|"enter"}` | `{sessionId:string,endpoint:{address:string,port:55000},setupRemainingSeconds:integer}` |
| `focus.stop` | `{sessionId:string|null,returnToDesktop:bool}` | `{stopped:true,desktopAllowed:bool}` |
| `heartbeat` | `{}` | `{idleRemainingSeconds:15,sessionRemainingSeconds:integer}` |

`requestPermission`: already granted => immediate true/none. Otherwise progress `awaitingPermission` with sessionId:null, then actual local grant/deny/60s-timeout result keyed by the SAME request id. Grant commit checks live socket/generation after local approval; canceled/expired approval cannot save it. EOF requires cleanup, not a response to a dead socket. Does not reserve media or enable master access.

`prepare`: one admitted request combines prepare/start authorization. It returns only AFTER desktop cleanup, atomic Focus claim and local55000 listener readiness. Response does not mean runtime or headset ready. A fresh Apple WAITING in this generation permits startMedia; there is no separate start/armed operation. Busy duplicate prepare does not change the first generation, prior access state or deadlines. Setup intent follows the same real system lifecycle, not a fake QR-only success.

`stop`: string sessionId must match this socket's owned session or its last terminal session. Null cancels this socket's pending permission/prepare or its current owned session even if prepare's response has not arrived yet. It never affects another socket's session. An idle null stop succeeds; a repeated matching terminal stop is idempotent without replaying work or changing restoration. Canceling an unfinished request also completes that original request with canceled (permission uses false/canceled) if the socket remains writable. No preferential desktop handback slot.

Progress states: `awaitingPermission`, `waitingForDesktop`, `waitingForSystem`, `qrPresented`, `startingMedia`, `mediaReady`, `stopping`, `stopped`, `failed`. Permission states use null sessionId; prepare states before its terminal response may expose its already-created sessionId. `mediaReady` is host runtime/scene readiness only. Mac requires actual system/client success for its success stage; QR render, scan request and WAITING alone are not setup success.

## Reader, lifetime and cancellation

Two total control sockets including handshakes, one per enrolled device, one mutating request/session globally. Other mutations return busy. Handshake5s; first record3s; frame completion5s from first byte; writer drain2s. Bounds: dispatcher8, writer16. Capability polling<=1/s; prepare budget3/180s per device and10/10min globally, counted before side effects. Capability/prepare rate excess returns rateLimited without closing the socket or starting media; it does not replenish budgets. Dispatcher/writer overflow, invalid framing/schema/IDs and extra input after4096 close the affected socket and cancel its owned work. Excess connection admission rejects the incoming socket, preserving existing admitted owners. Cancellation is never dropped.

ONE reader validates IDs/frames continuously while permission, desktop cleanup, native RPC or QR waits are suspended. It handles stop immediately outside the work queue: invalidate owned generation, signal cancellation and schedule bounded cleanup before waiting for any response. EOF, revoke, disable, Quit and interface loss enter the same path directly. Heartbeats are handled immediately by the reader, not behind long operations. Serialized writer items check their own operation cancellation state before publishing terminal success: a canceled unsent prepare yields canceled, not a late endpoint/ready response. Starting another operation does not cancel a completed permission decision, and later Stop does not rewrite that completed decision. Generation checks still reject obsolete progress. Already-written replies cannot be undone; Mac discards them after its own cancel state.

Heartbeat every5s, control idle timeout15s. It renews liveness only. Setup deadline180s from accepted prepare, including desktop wait; media hard deadline600s from startMedia. Both clipped to certificate expiry. No heartbeat/capability/repeated WAITING extends them; no restart after EOF/reconnect. If Apple's system UI suspends app heartbeats, fail safely and validate that lifecycle before changing timers.

## Desktop, QR and stop order

Mac stops owned input, closes its desktop TLS and suspends desktop autoreconnect BEFORE prepare. Host waits up to8s for that same device's existing media owner to finish verified capture/input cleanup. It does not force another owner off. If another device owns media, return busy. Once idle, existing MediaOwner.claim(focus) is atomic; if a desktop admission wins the race, return busy. Then pause the ordinary desktop listener. Accepted-but-not-admitted desktop TLS still checks MediaOwner and is rejected while Focus owns it. No transferable lease or transition protocol is added.

Local55000 admits one system connection; native prepare16s, QR render receipt15s, native media start16s, all clipped to setup remaining time. Windows automatically displays the real vendor QR in the same wizard stage and sends its bounded presentation receipt. Credentials stay in that local memory-only path. Actual Apple ClientID remains untrusted metadata; SPP2 control authority does not authenticate that separate media identity. Continuous Apple read pump remains active through every await.

Stop invalidates generation first, closes admission/QR/system TCP, cancels pending calls, and confirms native job/pipe cleanup within11s. Check generation after every await and before side effects. Uncertain cleanup poisons media owner and keeps access disabled. Local revoke stops the whole owned Focus runtime; no selective Apple/SPP2 identity claim.

After EVERY confirmed cleanup (explicit stop, cancellation, EOF, deadline or failure), restore previously permitted desktop LISTENING unless current local disable/interface policy or poisoned cleanup forbids it. Revoking one device does not disable unrelated approved devices. returnToDesktop expresses only Mac automatic reconnect intent following successful explicit stop; it does not gate host listener restoration. Mac performs ordinary Connect and handles busy if another authorized owner wins. No5s reservation. On control loss/error, there is no automatic Mac reconnect. Restoring the listener never starts capture.

## Remaining gates and focused fixtures

Current61c9e86 forces QR per generation. Scan-once persistence, desktop content inside XR, media protection and consumerReady remain unverified/incomplete. The wizard can integrate real QR now without claiming those capabilities.

Mac accepted isolated implementation. Fixtures cover cert/ALPN/revoke, strict IDs/framing, permission grant/deny/timeout/cancel, duplicate prepare, owner-idle races, immediate stop/EOF/revoke while each await is suspended, live heartbeat handling, no late success, queue bounds, deadline expiry, cleanup failure, desktop listener restore after EOF/cancel and suppression after local disable/poisoning, and unchanged pairing/desktop protocol. Mac owns the empty-address Bonjour resolution fixture proving no47991 connection. Pending cancellation replies remain deliverable independently of obsolete success/progress. Per-operation cancellation tokens live only with the current operation and bounded writer queue. No live work authorized by this document.
