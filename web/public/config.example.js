/* Xhome — site configuration.
 *
 * Everything installation-specific lives here so the page itself contains no
 * addresses, coordinates or secrets. Copy this file, fill it in, and deploy.
 *
 * NOTE ON THE PASSCODE: `passSha256` only hides the UI. It is a client-side
 * gate, so it keeps casual visitors out but does NOT protect the stream URLs,
 * which stay publicly fetchable. If you need real protection, put auth in
 * front of the origin (Caddy basic_auth, Cloudflare Access, or similar).
 */
window.XHOME_CONFIG = {
  // Base URL of the broadcast origin (Caddy). No trailing slash.
  streamBase: "https://stream.example.com",

  // Journey endpoints: [latitude, longitude]
  start: [35.0000, 135.0000],
  goal:  [35.5000, 135.5000],
  startName: { ja: "スタート地点", en: "Start" },
  goalName:  { ja: "ゴール地点",   en: "Goal" },

  walkMps: 1.35,   // assumed walking pace, m/s (~4.9 km/h)
  gapM:    250,    // gap beyond which a missing stretch is route-filled

  // SHA-256 of the passcode, lowercase hex. Empty string disables the gate.
  //   printf '%s' 'your-passcode' | shasum -a 256
  passSha256: "",

  // Set once a journey has ended, otherwise leave null.
  giveUp: null,
  // giveUp: {
  //   ts:  1700000000,                 // unix seconds when it ended
  //   pos: [35.2000, 135.2000],        // where it ended
  //   msg: { ja: "ギブアップ", en: "GAVE UP" },
  //   at:  "17:30 JST",
  // },
};
