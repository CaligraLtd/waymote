# `@rockorager/waymote`

Framework-free browser client for a Waymote gateway. The SDK owns
WebSocket recovery, WebCodecs video and audio, input and IME forwarding,
clipboard transport, presentation timing, and optional remote-output sizing.
The application owns the canvas, controls, status UI, styling, and browser
permission prompts.

```ts
import { WaymoteSession } from "@rockorager/waymote";

const canvas = document.querySelector<HTMLCanvasElement>("#display")!;
const session = new WaymoteSession({
  endpoint: "https://desktop.example.com",
  remoteDisplay: { mode: "manual" },
});
const surface = session.attachSurface({ canvas });

session.on("state", (state) => renderState(state));
session.on("stats", (stats) => renderStats(stats));
session.connect();
```

During local development, install the package directly from the repository:

```sh
npm install ./gateway/sdk
```

A running gateway also serves the same ESM implementation at `/waymote.js` and
its declarations at `/waymote.d.ts`.

Remote resizing is manual by default. Choose a fixed remote size with
`session.remoteDisplay.fixed({ width, height, scale })`, or explicitly opt into
viewport-driven sizing with `session.remoteDisplay.observe({ element })`.
Changing the canvas's CSS or backing dimensions never implicitly resizes the
remote compositor.

Audio must be enabled from a user gesture with `session.audio.enable()`. The
package includes its AudioWorklet beside the SDK module; `audioWorkletURL` can
override that URL when an application's bundler or content policy requires a
separate asset location.

The browser needs WebCodecs H.264 and Opus support. Clipboard and audio APIs
also require a secure context and their normal browser permissions.
