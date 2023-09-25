PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS interfaces (
  id INTEGER PRIMARY KEY,
  name TEXT,
  comment TEXT,
  privkey TEXT,
  port INTEGER,
  hostname TEXT,
  address TEXT,
  prefix INTEGER,
  psk TEXT
);

CREATE TABLE IF NOT EXISTS peers (
  id INTEGER PRIMARY KEY,
  interface1 INTEGER,
  interface2 INTEGER,
  FOREIGN KEY (interface1) REFERENCES interfaces(id) ON DELETE CASCADE,
  FOREIGN KEY (interface2) REFERENCES interfaces(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS allowed_ips (
  address TEXT,
  prefix INTEGER,
  interface INTEGER,
  FOREIGN KEY (peer) REFERENCES peers(id) ON DELETE CASCADE
);
