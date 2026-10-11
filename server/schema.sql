-- Flow Command usage server. No instructions, screens or page text are stored — only counts.
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,            -- anonymous hash of the computer, never the hardware id itself
  first_seen INTEGER NOT NULL,    -- unix seconds; starts the 14-day trial
  license TEXT                    -- Lemon Squeezy license key activated on this computer
);
CREATE TABLE IF NOT EXISTS tasks (
  device TEXT NOT NULL,
  week TEXT NOT NULL,             -- Monday of the week, e.g. 2026-10-12
  day TEXT NOT NULL,
  task_id TEXT NOT NULL,
  calls INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (device, week, task_id)
);
CREATE TABLE IF NOT EXISTS licenses (
  key TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  checked_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS activations (
  key TEXT NOT NULL,
  device TEXT NOT NULL,
  instance_id TEXT NOT NULL,
  PRIMARY KEY (key, device)
);
