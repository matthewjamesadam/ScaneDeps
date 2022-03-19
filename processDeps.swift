#!/usr/bin/swift

//
//  processDeps.swift
//  Scane
//
//  Created by Matt Adam on 2021-12-30.
//

import Foundation

struct DepLib {
    let name: String
    let version: String
    let libName: String
    let dylibName: String
    let shas: [String:String]
}

// List of all dependencies we pull from homebrew
let saneLib = DepLib(
    name: "sane-backends",
    version: "1.1.1",
    libName: "libsane",
    dylibName: "libsane.dylib",
    shas: [
        "arm64":  "5ce5536fb913f7a9da86681e0dfe280024f06243ffc34e6290c74bec3ca0beb4", // arm64_monterey
        "x86_64": "3d8d4820d67a24d31aeef2252a52fdfe295ac9fa6ac62b9646b9c48af0867a79", // monterey
])

let usbLib = DepLib(
    name: "libusb",
    version: "1.0.25",
    libName: "libusb",
    dylibName: "libusb-1.0.dylib",
    shas: [
        "arm64":  "ff2e884605bc72878fcea2935e4c001e4abd4edf97996ea9eaa779557d07983d", // arm64_monterey
        "x86_64": "95c09d4f1f6e7a036b8d09a5ced561c0b8be29e6caa06030624e77f10ad2521a", // monterey
])

let pngLib = DepLib(
    name: "libpng",
    version: "1.6.37",
    libName: "libpng",
    dylibName: "libpng.dylib",
    shas: [
        "arm64":  "40b9dd222c45fb7e2ae3d5c702a4529aedf8c9848a5b6420cb951e72d3ad3919", // arm64_monterey
        "x86_64": "7209cfe63b2e8fdbd9615221d78201bfac44405f5206f7b08867bcd0c6046757", // monterey
])

let tiffLib = DepLib(
    name: "libtiff",
    version: "4.3.0",
    libName: "libtiff",
    dylibName: "libtiff.dylib",
    shas: [
        "arm64":  "112b3bb5e0654331812403b0a6e62b4d1ddbcb1634894898072633d24fe8adee", // arm64_monterey
        "x86_64": "c4c73629e4bc92019e02fb19aced2a5d35cd1b9c4e20452d490efb97b7045a18", // monterey
])

let jpegLib = DepLib(
    name: "jpeg",
    version: "9e",
    libName: "libjpeg",
    dylibName: "libjpeg.dylib",
    shas: [
        "arm64":  "5d4520a90181dd83b3f58b580cd3b952cacf7f7aa035d5fd7fddd98c1e6210d1", // arm64_monterey
        "x86_64": "208af924cc7a42f53ab8ce50084eb76faadc3c1942e842484acbb2e74a54465c", // monterey
])


let depLibs = [ saneLib, usbLib, pngLib, tiffLib, jpegLib ]

extension URL {
    func appendingPathComponents(_ args: String...) -> URL {
        var url = self
        for arg in args {
            url = url.appendingPathComponent(arg)
        }
        return url
    }
}

// Helpers for running processes
struct RunOutput {
    let status: Int32
    let output: [String]
}

enum RunError: Error {
    case error(RunOutput)
}

@discardableResult
func run(_ args: String...) throws -> RunOutput {
    try run(args)
}

@discardableResult
func run(_ args: [String]) throws -> RunOutput {
    
    let task = Process()
    let pipe = Pipe()
    
    task.standardOutput = pipe
    task.standardError = pipe
    
    task.launchPath = "/usr/bin/env"
    task.arguments = args
    task.launch()
    task.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)!.components(separatedBy: .newlines)
    let runOutput = RunOutput(status: task.terminationStatus, output: output)

    if task.terminationStatus != 0 {
        throw RunError.error(runOutput)
    }
    
    return runOutput
}

// Get clean name for a dependency
func cleanDepName(depName: String) -> String {
    for depLib in depLibs {
        if depName.contains(depLib.libName) {
            return depLib.dylibName
        }
    }

    return depName
}

// Clean a single dependency for a single library
func cleanLibDep(lib: URL, depPath: String, depFolderPath: String) throws {
    let depUrl = URL(fileURLWithPath: depPath)
    let depName = cleanDepName(depName: depUrl.lastPathComponent)

    if lib.lastPathComponent == depName {
        try run("install_name_tool", "-id", "@rpath/\(depName)", lib.path)
    }
    else {
        try run("install_name_tool", "-change", depPath, "\(depFolderPath)/\(depName)", lib.path)
    }
}

// Clean all dependencies for a single library
func cleanLibDeps(lib: URL, depFolderPath: String) throws {
    let otoolOutput = try run("otool", "-L", "-X", lib.path)

    try otoolOutput.output.forEach { depString in
        if let range = depString.range(of: #"^\s*\S+"#, options: .regularExpression) {
            let path = depString[range].description.trimmingCharacters(in: .whitespacesAndNewlines)

            if path.contains("@@HOMEBREW_PREFIX@@") {
                try cleanLibDep(lib: lib, depPath: path, depFolderPath: depFolderPath)
            }
        }
    }
    
    try run("codesign", "--force", "--sign", "-", "--timestamp=none", lib.path)
}

let fileMgr = FileManager.default
let tmpFolder = fileMgr.temporaryDirectory

func clearFolder(url: URL) throws {
    try? fileMgr.removeItem(at: url)
    try fileMgr.createDirectory(at: url, withIntermediateDirectories: true)
}

let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: fileMgr.currentDirectoryPath))
if !fileMgr.fileExists(atPath: scriptPath.path) || scriptPath.lastPathComponent != "processDeps.swift" {
    print("Could not determine parent folder")
    exit(1)
}

let scriptFolder = scriptPath.deletingLastPathComponent()

let libFolder = scriptFolder.appendingPathComponents("lib")
let etcFolder = scriptFolder.appendingPathComponent("etc")
let includeFolder = scriptFolder.appendingPathComponent("include")

func createLib(lib: DepLib) throws {

    // Fetch libs
    try lib.shas.forEach({ arch, sha in
        print("Fetching \(lib.name) \(arch)...")

        let rootPath = "\(lib.name)-\(arch)"
        let tarPath = tmpFolder.appendingPathComponent("\(rootPath).tar.gz")
        let libPath = tmpFolder.appendingPathComponent(rootPath)

        try? fileMgr.removeItem(at: tarPath)
        try? fileMgr.removeItem(at: libPath)
        try fileMgr.createDirectory(at: libPath, withIntermediateDirectories: true)

        try run("curl", "-L", "-H", "Authorization: Bearer QQ==", "-f", "-o", tarPath.path, "https://ghcr.io/v2/homebrew/core/\(lib.name)/blobs/sha256:\(sha)")
        try run("tar", "-xzvf", tarPath.path, "-C", libPath.path)
    })

    // Create merged universal library
    print("Creating \(lib.dylibName)...")
    var lipoArgs = ["lipo", "-create"]
    lib.shas.forEach({ arch, _ in
        let srcPath = tmpFolder.appendingPathComponents("\(lib.name)-\(arch)", lib.name, lib.version, "lib", lib.dylibName)
        lipoArgs.append(contentsOf: ["-arch", arch, srcPath.path])
    })
    
    let destPath = libFolder.appendingPathComponent(lib.dylibName)
    lipoArgs.append(contentsOf: ["-output", destPath.path])
    
    try run(lipoArgs)
    
    try cleanLibDeps(lib: destPath, depFolderPath: "@loader_path")
}

func getSaneLibFolder(arch: String) -> URL {
    return tmpFolder.appendingPathComponents("\(saneLib.name)-\(arch)", saneLib.name, saneLib.version, "lib", "sane")
}

func creeateSaneLib(libName: String) throws {

    // Create merged universal library
    print("Creating \(libName)...")
    var lipoArgs = ["lipo", "-create"]
    saneLib.shas.forEach({ arch, _ in
        let srcPath = getSaneLibFolder(arch: arch).appendingPathComponents(libName)
        lipoArgs.append(contentsOf: ["-arch", arch, srcPath.path])
    })
    
    let destPath = libFolder.appendingPathComponents("sane", libName)
    lipoArgs.append(contentsOf: ["-output", destPath.path])
    
    try run(lipoArgs)
    
    try cleanLibDeps(lib: destPath, depFolderPath: "@loader_path/..")
}

func embedLibs() throws {

    // Set up a clean state
    try clearFolder(url: libFolder)
    try clearFolder(url: etcFolder)
    try clearFolder(url: includeFolder)
    try fileMgr.createDirectory(at: libFolder.appendingPathComponents("sane"), withIntermediateDirectories: true)
    try fileMgr.createDirectory(at: etcFolder.appendingPathComponents("sane.d"), withIntermediateDirectories: true)

    // Create root dylibs
    for depLib in depLibs {
        try createLib(lib: depLib)
    }

    // Create sane dylibs
    let saneLibPath = getSaneLibFolder(arch: "arm64")
    let paths = try FileManager.default.contentsOfDirectory(at: saneLibPath, includingPropertiesForKeys: nil)
    try paths.filter({$0.path.contains(".1.so")}).forEach { path in
        try creeateSaneLib(libName: path.lastPathComponent)
    }

    // Copy /etc
    let srcEtcFolder = tmpFolder.appendingPathComponents("\(saneLib.name)-arm64", saneLib.name, saneLib.version, "etc", "sane.d")
    print("Copying /etc files...")
    try run("rsync", "-rtvh", "--delete", srcEtcFolder.path, etcFolder.path)

    // Copy /include
    let srcIncludeFolder = tmpFolder.appendingPathComponents("\(saneLib.name)-arm64", saneLib.name, saneLib.version, "include", "sane")
    print("Copying /include files...")
    try run("rsync", "-rtvh", "--delete", srcIncludeFolder.path, includeFolder.path)
}

try embedLibs()
