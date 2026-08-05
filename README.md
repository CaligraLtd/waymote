# Waymote

Waymote streams an interactive wlroots-based Wayland session to a browser. It
captures a compositor output, encodes low-latency H.264 and Opus with FFmpeg,
and forwards video, audio, input, clipboard, and output-size messages through a
Go WebSocket gateway. The browser client is a framework-free ESM package with
TypeScript declarations.

The included Amp demo runs a fixed 1280x720, 30 Hz headless Labwc session with
Quake III Arena. Waymote is not tied to Labwc, but the compositor must expose
the wlroots protocols listed under
[Compositor requirements](#compositor-requirements).

## Browser SDK

The SDK source and package manifest live in `gateway/sdk/`. Install that
directory from a checkout, or import the ESM module directly from a running
gateway at `/waymote.js`:

```ts
import { WaymoteSession } from "@rockorager/waymote";

const canvas = document.querySelector<HTMLCanvasElement>("#display")!;
const session = new WaymoteSession({
  endpoint: "https://desktop.example.com",
  remoteDisplay: { mode: "fixed", width: 1280, height: 720, scale: 1 },
});
const surface = session.attachSurface({ canvas });

session.on("state", (state) => renderConnectionState(state));
session.on("stats", (stats) => renderPerformanceMetrics(stats));
session.connect();

// Call from a click or other user gesture.
await session.audio.enable();
await surface.requestPointerLock();
```

The SDK owns connection recovery, WebCodecs video/audio, presentation timing,
input and IME forwarding, clipboard transport, and output-size requests. It
does not query or render application UI. Frontends own every visible control,
status message, CSS rule, and clipboard-permission interaction. Focus and
pointer lock are exposed by the returned surface handle; video, audio, input,
clipboard, and remote-display behavior are grouped under controllers on the
session. State snapshots are immutable, and `state`, `stats`, `clipboard`,
`resize`, `quality`, and `error` events let React, Vue, Svelte, or a plain DOM
application render their own interface. See `gateway/sdk/README.md` and the
complete plain-JavaScript client in `gateway/examples/web/`.

Remote sizing is manual by default; changing a canvas's CSS or backing size
does not resize the compositor. Use a stable explicit output with
`remoteDisplay: { mode: "fixed", width: 1280, height: 720, scale: 1 }`.
Responsive remote sizing is opt-in: pass
`remoteDisplay: { mode: "observe", element: canvas }` and the SDK applies its
safe debounce, device-pixel-ratio, and 2560x1440 limits. Local CSS scaling
always remains independent of remote sizing. The bundled demo uses a fixed
size so multiple viewers cannot repeatedly reconfigure one shared encoder.

## Build and test

Waymote requires Zig 0.16, Go 1.26, Wayland client development files,
libxkbcommon, and FFmpeg with `libx264`. Build the two executables from the
repository root:

```sh
zig build install -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

This installs `zig-out/bin/waymote-streamd` and
`zig-out/bin/waymote-gateway`. The `.agents/setup` script provisions all demo
dependencies in a fresh Amp orb.

## Architecture

The gateway is the only internet-facing process:

```text
wlroots compositor
  -> wlr-screencopy SHM
  -> waymote-streamd three-slot latest-frame pool
  -> encoder worker-owned FFmpeg low-delay H.264
  -> Go WebSocket gateway
  -> browser WebCodecs VideoDecoder

session PipeWire/Pulse sink monitor
  -> waymote-streamd FFmpeg low-delay Opus
  -> bounded Go audio WebSocket
  -> browser WebCodecs AudioDecoder
  -> AudioWorklet jitter buffer

browser pointer/keyboard/viewport events
  -> bounded control WebSocket
  -> validated records on waymote-streamd stdin
  -> input through Wayland virtual pointer and virtual keyboard protocols
  -> output sizing through wlr-output-management-v1

browser text clipboard <-> controller-only WebSocket messages
  <-> bounded gateway/streamd frames
  <-> ext-data-control-v1 Wayland selection
```

## Compositor requirements

The native daemon is an ordinary privileged Wayland client; it does not import
or link compositor implementation code. Capture requires
`zwlr_screencopy_manager_v1`. Remote pointer and keyboard control require
`zwlr_virtual_pointer_manager_v1` and `zwp_virtual_keyboard_manager_v1`.
Output resizing uses `zwlr_output_manager_v1` when available, and text input
uses `zwp_input_method_manager_v2`. Labwc is the tested compositor in this
repository; other wlroots compositors exposing these protocols should work.

## Version 2 wire protocol

All integers are little-endian. Browser input records are 16 bytes:
`version:u8=2, type:u8, state:u8, reserved:u8, a:u32, b:u32,
sequence:u32`. Types 1–5 are absolute motion, button, scroll, key, and
release-all; type 8 is relative motion (`a`/`b` are finite bounded f32 bits).
Resize (type 6) uses width and height in `a`/`b`, with scale in the low 16 bits
and request ID in the high 16 bits of the final word. Quality (type 9) carries
kbps, FPS, and encoded scale percent. Text (type 10) is followed by at most
4000 UTF-8 bytes without NUL; state 1 is preedit and state 0 is commit, payload
length is `a`, and input sequence is `b`.

streamd stdout events have an 8-byte header
`version:u8=2, type:u8, reserved:u16, payload_length:u32`. Type 1 is clipboard.
Type 2 has a fixed 32-byte frame metadata payload: generation `u32`, encoded
width/height `u16`, capture CLOCK_MONOTONIC nanoseconds `u64`, media sequence
`u64`, latest input sequence `u32`, encoder FPS `u32`. Type 3 is the 20-byte
resize-applied event: request ID `u16`, padding, width/height `u32`, scale
`u16`, padding, generation `u32`.

Browser video messages use a 40-byte header: version/type/flags/reserved (4),
media sequence (8), media timestamp microseconds (8), generation (4), encoded
width/height (2 each), capture monotonic nanoseconds (8), and latest applied
input sequence (4), followed by one Annex-B access unit. Capture and browser
clocks are not assumed comparable. Low-RTT ping/pong samples estimate the
offset between server `CLOCK_MONOTONIC` and browser `performance.now()`.

Browser audio messages use a 24-byte header: version/type/flags/reserved (4),
extended RTP sequence (8), estimated monotonic capture timestamp in
microseconds (8), and stream generation (4), followed by one raw Opus packet.
The gateway maps the extended 48 kHz RTP clock onto its monotonic clock using
a filtered lower envelope of packet arrival times. The discontinuity flag is
set after packet loss, encoder restarts, and per-client queue overflow.

Once clock confidence is established, the browser schedules decoded video and
audio to the selected 60, 100, or 180 ms capture-to-presentation target. Video
uses a bounded decoded-frame queue; audio is placed at matching AudioContext
frames by the AudioWorklet. If clock or AudioContext output timing is not yet
usable, audio retains the bounded 60 ms queue fallback and drops back to that
target instead of allowing latency to grow beyond 200 ms.

`waymote-streamd` is an ordinary privileged Wayland client. It imports no
compositor implementation source. The gateway receives only Annex-B H.264 and
is the sole internet-facing process. Input follows public Wayland protocols;
validated output modes use `wlr-output-management-v1`. Stream capture and input
remain available at the compositor's existing fixed size when output management
is not advertised. Output creation remains a session-launcher or
compositor-specific responsibility.

## Run in an Amp orb

Build and start the declared supervised service:

```sh
amp orb services ensure
```

The command prints the authenticated portal URL. The demo starts with a
1280x720, 30 Hz ReleaseSafe CPU-rendered headless compositor. The bundled
frontend and gateway both enforce that fixed output size. The launcher starts
the Quake III demo on `q3dm1` with a bot, and falls back to a fullscreen Foot
terminal if the game data is unavailable.

## Run manually

Build the installed artifacts from the repository root:

```sh
zig build install -Doptimize=ReleaseSafe
```

Start a compositor and export the `WAYLAND_DISPLAY` value it prints. Then run:

```sh
zig-out/bin/waymote-gateway \
  -streamd zig-out/bin/waymote-streamd \
  -listen 127.0.0.1:8080 \
  -frame-rate 30 \
  -bitrate 12000 \
  -xkb-layout us
```

The browser client is available from the gateway root. Click the stream to
focus it, then use the pointer, buttons, wheel, and keyboard normally. Only one
browser may own the control channel and drive session resolution at a time;
other browsers can still watch but cannot read the session clipboard. Clipboard
text is synchronized automatically when browser permission allows it; the web
UI also provides explicit send/copy buttons. Paste shortcuts synchronize the
local clipboard before forwarding the key chord. Losing focus or disconnecting
releases every held key and button without disconnecting the persistent control
WebSocket. Audio uses a dedicated per-session null sink when PipeWire/Pulse is
available. Click **Enable audio** once to satisfy browser autoplay policy, and
use the latency selector to trade immediacy for additional jitter tolerance.
`waymote-streamd` supervises the optional audio encoder with pidfd and capped restart
backoff; an audio failure does not interrupt video or input.

Video capture copies into a fixed three-slot pool. One frame may be entering
FFmpeg while one waits; newer captures replace that pending frame instead of
building latency. A dedicated worker owns FFmpeg, its nonblocking input pipe,
pidfd supervision, and capped restart backoff, so encoder pressure and failure
cannot stall Wayland dispatch, input, clipboard, or audio. Every replacement
encoder uses a new RTP SSRC and stream generation; the gateway discards stale
metadata from the previous process and resumes at the replacement keyframe.

Production deployment must terminate TLS in the gateway or a trusted ingress.
The prototype has no remote-session authentication of its own, so exposing it
without an authenticated proxy also exposes compositor input control.

## Current limits

- Clipboard synchronization is text-only and capped at 1 MiB. Browser clipboard
  permissions can require the explicit send/copy buttons. Session audio is
  optional and requires a Pulse-compatible server plus a monitor source passed
  with `-audio-source`; video and input continue if audio is unavailable.
  `-xkb-layout` (or `XKB_DEFAULT_LAYOUT`, default `us`) selects the static
  keymap. Physical `KeyboardEvent.code` input remains available for games and
  terminals; browser composition is forwarded through input-method-v2 when a
  focused Wayland client activates it.
- The prototype encoder invokes the system FFmpeg `libx264` encoder. This is a
  development fallback, not the distributable encoder backend. Production
  work will replace it with an LGPL-compatible hardware path and a
  permissively distributable software fallback.
- When a browser accumulates eight encoded frames, the gateway drops its stale
  queue and resumes that connection at the next IDR instead of preserving
  latency or forcing a reconnect loop.
