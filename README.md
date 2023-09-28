# wireguard-config-manager
Command line wireguard configuration manager

## Usage
```
usage: wgcm <command> [args]
commands:
  list                                      List all interfaces
  list     <name>                           Display detailed view of an interface
  add      <name> <ip[/prefix]>             Add a new interface with name and IP/subnet
  peer     <name1> <name2>                  Peer two interfaces
  unpeer   <name1> <name2>                  Remove the connection between two interfaces
  route    <name> <router_name>             Peer two interfaces, where <name> accepts the entire subnet from <router_if>
  allow    <name> <peer_name> <ip[/prefix]> Allow an IP or subnet into <name> from <peer_name>
  unallow  <name> <peer_name> <ip[/prefix]> Unallow an IP or subnet into <name> from <peer_name>
  remove   <name>                           Remove an interface
  export   <name>                           Export the configuration for an interface in wg-quick format to stdout
  openbsd  <name>                           Export the configuration for an interface in OpenBSD hostname.if format to stdout
  genpsk   <name1> <name2>                  Generate a preshared key between two interfaces
  clearpsk <name1> <name2>                  Remove the preshared key between two interfaces
  set      <name> <field> <value>           Set a value for a field on an interface
  dump     <directory>                      Export all configuration files to a directory
fields:
  name
  comment
  privkey
  hostname
  address  (ip/prefix)
  port
  dns
```

## Dependencies

- `sqlite3`

## Building

Using the latest master build of zig
- `zig build -Doptimize=ReleaseSafe`

## Database location

The default database is located at `~/.config/wireguard-config-manager/wgcm.db`

You can customize the location of the database using the `WGCM_DB_PATH` environment variable.
