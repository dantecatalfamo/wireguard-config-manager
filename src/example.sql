INSERT INTO
  interfaces (name, comment, privkey, port, hostname, address, prefix)
VALUES
  ("center",  "Main hub server", "aabbcc", 43243, "example.com", "192.168.10.1", 24),
  ("desktop", "Desktop machine", "deadbeef", NULL, NULL, "192.168.10.100", 24);

INSERT INTO
  peers (interface1, interface2)
VALUES
  (1, 2),
  (2, 1);


INSERT INTO
  allowed_ips (address, prefix, peer)
VALUES
  ("192.168.10.100", 32, 1),
  ("192.168.10.0", 24, 2);
