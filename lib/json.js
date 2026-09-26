.pragma library

// Parses `text` as JSON, returning `fallback` (default null) instead of
// throwing when it isn't valid JSON.
function tryParse(text, fallback) {
  try { return JSON.parse(text) } catch (e) { return fallback === undefined ? null : fallback }
}
