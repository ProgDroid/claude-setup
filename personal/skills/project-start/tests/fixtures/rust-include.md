## Clippy Lint Policy

```toml
# Groups get priority -1 so the individual allows override them.
[lints.clippy]
all = { level = "warn", priority = -1 }
pedantic = { level = "warn", priority = -1 }
implicit_return = "allow"
```

- trailing prose
