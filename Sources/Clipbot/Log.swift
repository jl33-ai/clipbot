import os

/// Diagnostics only. NEVER log clip or snippet content — only event names, kinds, counts and reasons.
enum Log {
    static let app = Logger(subsystem: "io.linus.clipbot", category: "app")
}
