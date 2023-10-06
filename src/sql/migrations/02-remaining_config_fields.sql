BEGIN TRANSACTION;

ALTER TABLE interfaces
      ADD COLUMN routing_table TEXT;

ALTER TABLE interfaces
      ADD COLUMN mtu INTEGER;

ALTER TABLE interfaces
      ADD COLUMN pre_up TEXT;

ALTER TABLE interfaces
      ADD COLUMN post_up TEXT;

ALTER TABLE interfaces
      ADD COLUMN pre_down TEXT;

ALTER TABLE interfaces
      ADD COLUMN post_down TEXT;

ALTER TABLE peers
      ADD COLUMN keep_alive INTEGER;

COMMIT TRANSACTION;
