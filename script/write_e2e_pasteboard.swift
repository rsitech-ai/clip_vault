#!/usr/bin/env swift
import AppKit
import Darwin
import Foundation

private let pasteboardName = NSPasteboard.Name("com.andrzej.ClipVault.e2e.capture")
private let maximumTokenBytes = 4_096

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: write_e2e_pasteboard.swift <token>\n".utf8))
    Darwin.exit(EX_USAGE)
}

let token = CommandLine.arguments[1]
guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      token.lengthOfBytes(using: .utf8) <= maximumTokenBytes else {
    FileHandle.standardError.write(Data("E2E pasteboard token is empty or too large.\n".utf8))
    Darwin.exit(EX_DATAERR)
}

let pasteboard = NSPasteboard(name: pasteboardName)
pasteboard.clearContents()
guard pasteboard.setString(token, forType: .string) else {
    FileHandle.standardError.write(Data("Could not write the E2E pasteboard token.\n".utf8))
    Darwin.exit(EX_IOERR)
}
