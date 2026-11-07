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

Needs macOS 27 or later on Apple silicon. [Download](https://hangar.baseguard.io/download) ·
[Getting started](https://hangar.baseguard.io/docs/getting-started) · [Docs](https://hangar.baseguard.io/docs)

## Credits

- [Mustafa Akın](https://mustafaakin.dev/blog/windows-on-tart/), for showing that Windows runs on Apple's
  Virtualization framework.