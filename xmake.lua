set_project("mff")
set_version("0.0.1")
set_xmakever("2.8.0")

add_rules("mode.debug", "mode.release")

set_allowedplats("macosx")
set_allowedarchs("arm64", "x86_64")
-- 13.0 lets the x86_64 slice link against the Command Line Tools Swift
-- runtime, so a universal binary can be built without a full Xcode install.
set_config("target_minver", "13.0")

target("mff")
    set_kind("binary")
    add_files("src/*.swift")
    add_frameworks("Cocoa", "Quartz", "UniformTypeIdentifiers", "QuickLookUI", "AVKit", "AVFoundation")
