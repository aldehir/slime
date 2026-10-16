# Third-party notices

slime is built on [libghostty-vt](https://github.com/ghostty-org/ghostty),
the terminal emulation core of Ghostty, which is compiled into the
executable. Ghostty's bundled color themes are also installed alongside it,
and its sprite drawing code (box drawing, blocks, and similar glyphs) is
vendored in `src/font/sprite`.

## Ghostty

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

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

## z2d

The sprite drawing code uses [z2d](https://github.com/vancluever/z2d),
Copyright © 2024-2026 Chris Marchesi, which is compiled into the
executable unmodified. It is licensed under the
[Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/), and its source
is available at https://github.com/vancluever/z2d.

## ConPTY

slime ships `conpty.dll` and `OpenConsole.exe` from the
[Microsoft.Windows.Console.ConPTY](https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY)
package, built from [microsoft/terminal](https://github.com/microsoft/terminal)
under the MIT License, Copyright (c) Microsoft Corporation.
