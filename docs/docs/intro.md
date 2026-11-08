---
slug: /
title: Start here
sidebar_position: 1
---

import DocCardList from '@theme/DocCardList';

Eggy is a game engine for Zig 0.17. Your game is a Zig package that builds into a runtime
for players and a desktop editor for making it, and both run the same game code and plugins.
Games run on Windows, macOS, Linux, the web and Android.

New to Eggy? [Install it](getting-started/install.md), then make
[your first game](getting-started/first-game.md) in the editor, or
[a game in code only](getting-started/code-only-game.md).

<DocCardList
  items={[
    { type: 'link', label: 'Get started', href: '/getting-started', description: 'Install Eggy, make a first game, and see how a game runs.' },
    { type: 'link', label: 'The editor', href: '/editor', description: 'Tabs, the Scene panel, the Hierarchy and the Inspector.' },
    { type: 'link', label: 'Scenes and assets', href: '/scenes', description: 'Bring files in, load them, and place scenes inside scenes.' },
    { type: 'link', label: 'Rendering', href: '/rendering', description: 'Meshes, cameras, materials, lights, shaders, 2D and graphics settings.' },
    { type: 'link', label: 'Animation', href: '/animation', description: 'Key clips, blend a model\'s clips, and make cutscenes.' },
    { type: 'link', label: 'Physics', href: '/physics', description: 'Colliders, rigid bodies and collisions.' },
    { type: 'link', label: 'Input and time', href: '/input', description: 'Devices, named controls, timers and ready-made players.' },
    { type: 'link', label: 'Sound', href: '/audio', description: 'Sounds on entities and from code, in 3D or not.' },
    { type: 'link', label: 'Game UI', href: '/ui', description: 'HUDs, menus, in-world panels and translations.' },
    { type: 'link', label: 'Plugins', href: '/plugins', description: 'Install plugins, write your own, and extend the editor.' },
    { type: 'link', label: 'Game code', href: '/game-code', description: 'Lifetimes, errors, saves, debugging and the dev console.' },
    { type: 'link', label: 'Shipping', href: '/shipping', description: 'Export for desktop, the web and Android.' },
    { type: 'link', label: 'Reference', href: '/reference', description: 'Hooks, project files, the command line and platform support.' },
  ]}
/>

Every function's contract, with its errors and an example, is in the
[API reference](pathname:///api/), made from Eggy's source comments.
