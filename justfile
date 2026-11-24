set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Run VHSCore's tests
test:
    swift test

# Build vhs-drive for release and put it in ~/.local/bin
install:
    swift build -c release --product vhs-drive
    mkdir -p "$HOME/.local/bin"
    install -m 755 "$(swift build -c release --show-bin-path)/vhs-drive" "$HOME/.local/bin/vhs-drive"
    @echo "installed $HOME/.local/bin/vhs-drive"
