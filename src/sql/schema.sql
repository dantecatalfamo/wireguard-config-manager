PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS interfaces (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    comment TEXT,
    privkey TEXT NOT NULL UNIQUE,
    hostname TEXT,
    port INTEGER,
    address TEXT NOT NULL UNIQUE,
    prefix INTEGER
);

CREATE TABLE IF NOT EXISTS peers (
    id INTEGER PRIMARY KEY,
    interface1 INTEGER NOT NULL,
    interface2 INTEGER NOT NULL,
    psk TEXT,
    FOREIGN KEY (interface1) REFERENCES interfaces (id) ON DELETE CASCADE,
    FOREIGN KEY (interface2) REFERENCES interfaces (id) ON DELETE CASCADE,
    UNIQUE (interface1, interface2)
);

CREATE TABLE IF NOT EXISTS allowed_ips (
    id INTEGER PRIMARY KEY,
    peer INTEGER,
    address TEXT,
    prefix INTEGER,
    FOREIGN KEY (peer) REFERENCES peers (id) ON DELETE CASCADE,
    UNIQUE (peer, address, prefix)
);
