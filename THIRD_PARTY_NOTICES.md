# Third-party notices

Rolltop includes code adapted from Hidden Bar (https://github.com/dwarvesf/hidden), compared
with Hidden Bar's source at commit 7980e7b on 2026-11-25.

Adapted from Hidden Bar's code:

- Rolltop/Platform/MenuBarRestriction/RLTMenuBarRestriction.m and .h, from
  hidden/Features/StatusBar/Engine/Native/HBNativeVisibilityShim.m and .h
  (the MenuBarClientCore allow-list boundary).
- NotificationCenterPanel in Rolltop/Platform/WindowList.swift, and the click watching,
  clock hit area (isOnClock) and replay sequence in Rolltop/Platform/ClockBridge.swift, from
  hidden/Features/StatusBar/Engine/Native/MenuBarClock.swift (opening Notification Center
  while the menu bar is restricted).
- Rolltop/Features/Reveal/RevealHitProbe.swift and the role cases of BarHitClassifier.classify
  in Rolltop/Features/Reveal/BarHitClassifier.swift, from
  hidden/Features/Reveal/RevealHitTester.swift and HitClassifier in
  hidden/Features/Reveal/RevealGestures.swift (telling empty menu bar space from items).

Same technique and measured timings as Hidden Bar, written for Rolltop:

- Rolltop/Engine/ItemActivator.swift (allow one hidden item, press it, watch its menu or
  panel, end the allow when it closes), after hidden/Features/Palette/PaletteRevealSession.swift
  and PaletteItemPresser.swift.

Hidden Bar's license follows.

----------------------------------------------------------------------------------------

MIT License

Copyright (c) 2019 Dwarves Foundation
Copyright (c) 2026 Console Labs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
