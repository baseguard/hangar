# Hangar

macOS, Linux and Windows VMs on your Mac, with every connection they make watched and filtered from outside the guest.

```sh
hangar create kestrel --os macos --image base
hangar policy kestrel --mode allowlist \
  --allow anthropic.com --allow github.com
hangar run kestrel --background
ssh admin@$(hangar ip kestrel --wait 60)
# inside, let it rip: claude, approvals off
# it reaches anthropic.com and github.com. that's all ☕
```

Needs macOS 27 or later on Apple silicon. [Download](https://github.com/baseguard/hangar/releases) ·
[Getting started](docs/getting-started.mdx) · [Docs](docs)
