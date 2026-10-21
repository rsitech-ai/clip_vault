#[cfg(target_os = "linux")]
mod bridge;
#[cfg(target_os = "linux")]
mod clipboard;
#[cfg(target_os = "linux")]
mod ui;
#[cfg(target_os = "linux")]
mod worker;
#[cfg(target_os = "linux")]
fn main() {
    ui::run();
}
#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("ClipVault Linux requires Linux with GTK4 and GNOME Secret Service.");
}
