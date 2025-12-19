# git-fuse

A FUSE filesystem for mounting Git repositories. Exposes the Git index (staging area) as read-write and commits as read-only.

## Building

With Nix:
```bash
nix build
```

With dub:
```bash
dub build
```

## Usage

```bash
git-fuse <repo-path> <mount-point>
```

For example:
```bash
mkdir /tmp/mnt
git-fuse . /tmp/mnt
```

Then browse:
- `/tmp/mnt/index/` - read-write access to staged files
- `/tmp/mnt/commits/<sha>/` - read-only access to any commit

To unmount:
```bash
fusermount -u /tmp/mnt
```

## Options

- `-f, --foreground` - run in foreground (don't daemonize)
- `-o, --options=STR` - additional FUSE options (e.g. `debug`)

## Testing

```bash
nix flake check
```

## License

MPL 2.0
