//! Terminal output formatting helpers.

use colored::Colorize;

/// Print the Locus header/banner.
pub fn print_header() {
    println!(
        "{} {}",
        "locus".bold().cyan(),
        format!("v{}", env!("CARGO_PKG_VERSION")).dimmed()
    );
}

/// Print a success message.
pub fn success(message: &str) {
    println!("  {} {}", "✓".green().bold(), message);
}

/// Print an info message.
pub fn info(message: &str) {
    println!("  {} {}", "·".dimmed(), message);
}

/// Print a warning message.
pub fn warn(message: &str) {
    println!("  {} {}", "!".yellow().bold(), message);
}

/// Print an error message.
pub fn error(message: &str) {
    eprintln!("  {} {}", "✗".red().bold(), message);
}

/// Print a section header.
pub fn section(title: &str) {
    println!("\n  {}", title.bold());
}

/// Print a key-value pair with alignment.
#[allow(dead_code)]
pub fn field(key: &str, value: &str) {
    println!("  {} {}", format!("{:<16}", key).dimmed(), value);
}

/// Print a list item.
pub fn list_item(label: &str, description: &str) {
    println!("    {} {}", label.bold(), description.dimmed());
}
