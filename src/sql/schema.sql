BEGIN TRANSACTION;

CREATE TABLE interfaces (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    comment TEXT,
    privkey TEXT NOT NULL UNIQUE,
    hostname TEXT,
    port INTEGER,
    address TEXT NOT NULL UNIQUE,
    prefix INTEGER,
    dns TEXT,
    routing_table TEXT,
    mtu INTEGER,
    pre_up TEXT,
    post_up TEXT,
    pre_down TEXT,
    post_down TEXT
);

CREATE TABLE peers (
    id INTEGER PRIMARY KEY,
    interface1 INTEGER NOT NULL,
    interface2 INTEGER NOT NULL,
    psk TEXT,
    keep_alive INTEGER,
    FOREIGN KEY (interface1) REFERENCES interfaces (id) ON DELETE CASCADE,
    FOREIGN KEY (interface2) REFERENCES interfaces (id) ON DELETE CASCADE,
    UNIQUE (interface1, interface2)
);

CREATE TABLE allowed_ips (
    id INTEGER PRIMARY KEY,
    peer INTEGER,
    address TEXT,
    prefix INTEGER,
    FOREIGN KEY (peer) REFERENCES peers (id) ON DELETE CASCADE,
    UNIQUE (peer, address, prefix)
);

COMMIT TRANSACTION;
