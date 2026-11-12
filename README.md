<p align="center">
  <img src="dist/jetdafih.unn.svg" width="360" alt="unn">
</p>

<p align="center">
  A Wayland terminal emulator written in Zig, built on
  <a href="https://github.com/ghostty-org/ghostty">ghostty</a>'s terminal core.
</p>

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/jetdafih/unn/main/install.sh | sh
```

## Build from source

```sh
zig build -Doptimize=ReleaseFast
zig build test --summary all
```
