FROM rust:1.97-bookworm
RUN rustup component add clippy rustfmt
RUN apt-get update && apt-get install -y --no-install-recommends libgtk-4-dev libadwaita-1-dev libdbus-1-dev pkg-config xvfb dbus-x11 gnome-keyring x11-utils xdotool imagemagick xclip ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
ENV CARGO_BUILD_JOBS=2
