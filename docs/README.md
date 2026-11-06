# Hangar docs

Hangar runs macOS, Linux and Windows VMs on Apple silicon, and watches or restricts each VM's network traffic from
outside the guest. These pages cover the app and the `hangar` command line, which work on the same VMs.

## Start

- [Getting started](getting-started.mdx): install Hangar and create a VM in about a minute.
- [Running AI agents](ai-agents.mdx): give a coding agent a whole VM, only the hosts it needs, and a snapshot to roll
  back to.
- [Creating VMs](creating-vms.mdx): every guest, image and installer.
- [Commands](commands.mdx): the everyday commands, and every command the CLI has.

## Use

- [Shared folders](shared-folders.mdx): share folders with a VM, browse its files, copy with `hangar cp`, drag and
  drop.
- [Snapshots and images](snapshots.mdx): snapshots, clones, and sharing a VM through a registry or a file.
- [Guest agent](guest-agent.mdx): what Hangar's agent does inside a VM, how to install or update it, `hangar exec`,
  the shared clipboard.
- [Templates](templates.mdx): a VM's recipe in a `.hangarvm` file.

## Network

- [Networking](networking.mdx): the three networks a VM can have, and Hangar's own network.
- [Traffic rules](traffic-rules.mdx): watch every connection a VM makes, and decide which ones get through.
- [Secrets](secrets.mdx): give a VM API tokens it can use but never holds.

## Project

- [Building the macOS images](macos-images.mdx): how the `vanilla`, `base` and `xcode` images are built and published.
- [Building from source](building.mdx): the tools the build needs, and its make targets.
- [License](license.mdx): who can use Hangar for free.
