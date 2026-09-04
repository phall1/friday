# Friday module architecture

## Purpose

This plan deepens Friday's largest modules without changing its product scope or
splitting files merely to reduce line counts. A module earns its seam when it
hides invariants that would otherwise spread across callers. Friday remains a
private Apple Silicon dictation instrument: capture, local recognition,
ephemeral feedback, and exact final-text delivery.

## Non-negotiable invariants

- A hotkey generation has one source identity and one terminal outcome.
- Accepted asynchronous work completes exactly once or retires as cancelled.
- Cancellation cannot affect another generation or a later recycled request.
- Audio callbacks allocate nothing, acquire no lock, and do bounded work.
- Canonical audio remains authoritative until final recognition or explicit
  discard.
- Partial recognition is ephemeral and final text is the only deliverable.
- Transcript text is not logged, persisted, or exposed through diagnostics.
- Untrusted model bytes do not reach an in-process parser.
- Release evidence is bound to exact source, model, runtime, and artifacts.

## Dependency categories

| Dependency | Category | Testing consequence |
| --- | --- | --- |
| Reducers, projections, codecs | In-process | Test directly through the owning module's interface. |
| Filesystem, clipboard, CoreAudio | Local-substitutable | Keep internal production and deterministic test adapters. |
| Native SDK host/channel primitives | True external | Keep one narrow adapter at the application edge. |
| Hugging Face metadata transport | True external | Inject transport only inside the model repository implementation. |
| NeMo C runtime | True external | Keep the C adapter private to recognition/model probing. |

No remote service is owned by Friday. There is no reason to introduce a
network-facing port beyond the private model-source transport seam.

## Target dependency direction

```text
app.native
    |
    v
core.ts (Native SDK root adapter)
    |
    +--> app workflow
    +--> model workflow
    +--> dictation workflow
    +--> view projection
            |
            v
       domain vocabulary + protocol codecs

Native SDK runner
    |
    v
FridayHost (adapter and coordinator)
    |
    +--> OperationRegistry
    +--> SessionArtifacts
    +--> AudioSession
    +--> Recognizer
    +--> ModelRepository
    +--> TextDelivery
    +--> Overlay/Input adapters

AudioSession --> private CaptureBackend + CanonicalAudioStore
ModelRepository --> private ModelPolicy + ModelSource + ModelInstaller + ModelIndex
```

Arrows only point inward toward stable domain vocabulary or downward toward an
owned implementation. Internal modules never import `FridayHost` or `core.ts`.

## TypeScript root

### Current pressure

`src/core.ts` owns the Native SDK contract, the complete model/message
vocabulary, view projection, command routing, startup, settings, model
management, and dictation orchestration. Existing transition files return
`Model | null`; the root must know their priority, invoke workflow handling
twice for selected terminal messages, and supply cross-domain effects. They are
shallow because their routing contract is almost as complex as their bodies.

### Chosen interface

```ts
export type Update = Model | readonly [Model, Cmd<Msg>];

export interface DomainTransition {
  owns(msg: Msg): boolean;
  update(model: Model, msg: Msg): Update;
}

export function update(model: Model, msg: Msg): Update;
```

`DomainTransition` is private to the root implementation. Native SDK callers
continue to learn only `Model`, `Msg`, `initialModel`, `update`, and projection
functions. Each message has one owner. Cross-domain policy—such as hiding the
capsule after a terminal workflow transition—belongs to the owning transition,
not a second root pass.

Stable state/message vocabulary moves out of `core.ts` so lower modules do not
import their coordinator. View projection moves as one module, not one file per
selector. Repeated settings persistence and refresh effects become one private
operation inside the app workflow.

### Alternatives rejected

1. A handler map with one function per message maximizes extension points but
   creates a shallow interface and scatters ordering invariants.
2. Keeping nullable transition results preserves today’s code but leaves
   ownership and priority in the root.

### Interface tests and rollback

- Every `Msg` is owned exactly once.
- Terminal dictation outcomes include capsule cleanup in the same result.
- Exact UTF-8 and generation rejection remain observable through `update`.
- Persist/refresh settings effects are identical for every durable setting.

Move vocabulary first, then one workflow at a time. Each move is a standalone
commit that can be reverted without changing persisted schema.

## Native host

### OperationRegistry

This module owns request admission, stage transitions, cancellation claims,
callback retirement, completion queueing, polling, and shutdown fences.

```zig
pub const OperationRegistry = struct {
    pub fn begin(self: *Self, key: u64, kind: Kind) ?Handle;
    pub fn cancel(self: *Self, key: u64) ?Cancellation;
    pub fn complete(self: *Self, handle: Handle, result: Result) CompletionAction;
    pub fn poll(self: *Self) ?HostCompletion;
};
```

`Handle` carries stable slot identity and exposes narrow setters for the small
amount of operation metadata needed by the coordinator. Callers never mutate
slot lifetime flags. `Cancellation` is an immutable cleanup plan. The module
guarantees exactly-once retirement and slot reuse safety.

### SessionArtifacts

This module owns generation-scoped source targets, transcripts, and audio
generation lookup.

```zig
pub const SessionArtifacts = struct {
    pub fn begin(self: *Self, generation: u64, source: SourceTarget) !Session;
    pub fn transact(self: *Self, session: Session, action: Action) Result;
    pub fn cancel(self: *Self, generation: u64) void;
};
```

The transaction interface hides array compaction, ownership transfer, exact
text lifetime, and stale-generation rejection. Delivery can take final text
once; diagnostics cannot read it.

### FridayHost after extraction

`FridayHost` remains the only Native SDK adapter. It translates host commands
into subsystem intent, connects callbacks to registry handles, and executes the
cleanup plan returned by cancellation. Diagnostics and automation move behind
a private evidence builder that receives immutable snapshots, never subsystem
internals.

### Alternatives rejected

1. A generic event bus would obscure ordering and duplicate Native SDK channel
   semantics.
2. One module per callback would be shallow and retain shared mutable state.
3. Giving every subsystem its own operation table would destroy one-owner
   cancellation.

### Interface tests and rollback

- 10,000 concurrent cancel/complete/reallocate iterations cross
  `OperationRegistry` directly.
- Completion saturation and shutdown prove no duplicate or lost terminal work.
- Session cancellation destroys source and transcript once and rejects stale
  access.
- Removing registry retirement or artifact generation checks fails tests.

Extract the registry first without changing host routing, then session
artifacts, then diagnostics. Each commit keeps `FridayHost.binding()` stable.

## Audio

### External interface

`AudioSession` remains the only interface its callers learn:

```zig
start(session_id, completion)
stop(session_id, completion)
cancel(session_id)
retryAudio() ?AuthoritativeAudio
discardRetry()
```

Backend selection, route generations, power events, canonical conversion,
storage durability, and metering stay hidden.

### Internal seams

- `CaptureBackend`: production CoreAudio and Native SDK test/compatibility
  adapters. It owns device binding, route liveness, callback quiescence, and
  raw-format facts. Its context is backend-private; it never receives
  `*AudioSession`.
- `CanonicalAudioStore`: consumes worker-side frames, converts to 16 kHz mono
  Float32, meters intervals, enforces duration/storage bounds, fsyncs, and owns
  retry publication/deletion.

The callback writes only to the bounded ring. The worker is the sole caller of
the store.

### Alternatives rejected

1. Separate public route/converter/storage modules would make callers sequence
   capture internals correctly.
2. The current function-pointer table taking `*AudioSession` is not a real seam;
   adapters can reach every invariant.
3. A protocol-independent “audio framework” would add extension surface Friday
   does not need.

### Interface tests and rollback

- Production and fake capture adapters run the same start/route-loss/stop
  contract suite.
- Converter fixtures cover actual 44.1/48/96 kHz channel layouts and exact
  frame accounting.
- Store tests prove no cross-session tail and authoritative retry lifecycle.
- Callback allocation/lock checks and latency budgets remain release gates.

Extract C declarations and backend state only after the production-path tests
exist; extract canonical storage second. `AudioSession` callers do not change.

## Models

### External interface

The repository owns operation identity atomically:

```zig
pub const ModelRepository = struct {
    pub fn submit(self: *Self, intent: Intent, completion: Completion) !Ticket;
    pub fn cancel(self: *Self, ticket: Ticket) void;
    pub fn snapshot(self: *Self) Snapshot;
};
```

`Intent` covers install-default, resume, resolve-source, install-resolved,
add-allowlisted-local, select, remove, and cleanup. The returned `Ticket`
contains a monotonic epoch but callers treat it as opaque. Progress and final
completion carry the same ticket. The repository worker owns all mutation.

### Internal modules

- `ModelPolicy`: allowlist, immutable identity, capability schema, bounded
  manifest parsing, and runtime-probe eligibility.
- `ModelSource`: metadata-only Hugging Face resolution behind a transport
  adapter; it never authorizes parser access.
- `ModelInstaller`: resumable transport, validators, exact hashing, staged
  runtime probe, atomic publication, fsync, and cancellation checkpoints.
- `ModelIndex`: durable records, migration, snapshots, safe managed deletion,
  and orphan reconciliation.

These are implementation modules, not additional interfaces for `FridayHost`.

### Alternatives rejected

1. Exposing `beginOperation()` plus epoch parameters leaks cancellation
   choreography and permits enqueue races.
2. Separate public downloader, verifier, and selector interfaces force callers
   to reproduce the security-critical publication sequence.
3. A plugin model provider interface is unjustified until a second trusted
   source exists.

### Interface tests and rollback

- Cancelled tickets retire; fresh tickets complete under recycled host keys.
- Untrusted metadata and malformed manifests never invoke the parser adapter.
- Removing hash, fsync, probe, or rename steps fails installer contract tests.
- Index tests reach 128 records, delete every managed active model safely, and
  preserve local references.

Move policy and codecs first, then index, then installer/source internals, and
collapse the external interface last. Preserve the on-disk schema at every
step so each commit is independently revertible.

## Mirrored runner

The app-owned Native SDK runner is duplication, not a module. Delete it after a
focused extension-lifecycle test proves host create/bind/destroy wiring through
the patched SDK runner. There is no replacement wrapper.

## Validation after every extraction

1. `git diff --check`
2. `npm run check`
3. `npm test`
4. `npm run build`
5. Focused deletion-sensitive interface tests
6. Package/UI/performance checks when native lifecycle, rendering, callback, or
   startup behavior is touched

The final audit rejects circular imports, duplicated state ownership, adapters
with only a pass-through implementation, tests that reach past interfaces, and
any increase in caller ordering knowledge.
