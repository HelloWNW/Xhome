/* Xhome — site configuration.
 *
 * Everything installation-specific lives here so the page itself contains no
 * addresses, coordinates or secrets. Copy this file to config.js, fill it in,
 * and deploy (GitHub Pages deploys web/public as it is).
 *
 * NOTE ON THE PASSCODE: `passSha256` only hides the UI. It is a client-side
 * gate, so it keeps casual visitors out but does NOT protect the YouTube
 * links, which are public in this file.
 */
window.XHOME_CONFIG = {
  // ---- video: YouTube lives -------------------------------------------
  // Live N starts at t0 + (N-1) * stepHours. The page switches to live N+1
  // at exactly that moment (viewers' own clocks are used, so no server).
  t0: "2026-11-21T00:00:00+09:00",
  stepHours: 10,
  lives: [
    { n: 1, videoId: "Ca5Q0RrikT0" },
    { n: 2, videoId: "-cNnrWdyc6w" },
    { n: 3, videoId: "ux84riqPNnk" },
    // lives 4-7: add { n: 4, videoId: "..." } etc. when they are booked
    // optional per live: videoStart: "2026-11-21T00:01:30+09:00"  (when the YouTube
    // broadcast really began; improves replay <-> GPS alignment)
  ],

  // Test stream: until `until`, this video is shown instead of the schedule.
  // Remove the block (or let it expire) for the real run.
  dev: { videoId: "qJuRZvWImMc", until: "2026-11-21T00:00:00+09:00" },

  // ---- data endpoint (GPS / track / status / lives.json), no trailing slash.
  // Served by the stream container through a Tailscale Funnel. Leave empty
  // until it exists: the site then simply shows no GPS data.
  dataBase: "",

  // GPS history for replay, one file per UTC day (YYYY-MM-DD.jsonl).
  historyBase: "https://raw.githubusercontent.com/HelloWNW/Xhome/data/gps/",

  // ---- journey ---------------------------------------------------------
  // Endpoints: [latitude, longitude]
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
