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

## Agent skills

The [`skills/`](skills/) directory contains [Agent Skills](https://agentskills.io/) that teach AI coding agents to use git-fuse:

- [`git-fuse-atomic-commits`](skills/git-fuse-atomic-commits/SKILL.md) - split uncommitted changes into atomic commits, staging partial changes by editing the mounted index

To install them with Claude Code:
```
/plugin marketplace add CyberShadow/git-fuse
/plugin install git-fuse@git-fuse
```

For other agents, use [`npx skills`](https://github.com/vercel-labs/skills):
```bash
npx skills add CyberShadow/git-fuse
```

Or copy the skill directory into your agent's skills directory (e.g. `~/.claude/skills/`).

## Testing

```bash
nix flake check
```

## License

MPL 2.0
