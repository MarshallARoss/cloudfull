# Third-party notices

Cloudfull includes code adapted from the following third-party project.

## FabBar

- Project: [FabBar](https://github.com/ryanashcraft/FabBar) by Ryan Ashcraft
- License: MIT

Cloudfull adapts FabBar's technique for mounting a real `UISegmentedControl`
(with iOS's native Liquid Glass selection lens) inside a custom SwiftUI
control. The adapted file is:

- `Cloudfull/Feed/ChinTabSegmentedControl.swift` — adapted from FabBar's
  `Sources/FabBar/Internal/TabBarSegmentedControl.swift`, `TabItemContentView.swift`,
  and `FabBarRepresentable.swift`.

`Cloudfull/Feed/ChinNavigation.swift` references this same technique but does
not itself contain adapted FabBar code.

### MIT License text

```
MIT License

Copyright (c) 2025 Ryan Ashcraft

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
```
