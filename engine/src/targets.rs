use super::*;

// Supplemental discovery remains constrained to category-specific locations, not arbitrary paths.
pub(super) fn allowed(home: &Path, target: &Target) -> bool {
    let p = &target.path;
    if !p.is_absolute() || p == home || p.components().any(|c| matches!(c, Component::ParentDir)) {
        return false;
    }
    let below = |root: PathBuf| p != &root && p.starts_with(root);
    let within = |root: PathBuf| p.starts_with(root);
    let library = home.join("Library");
    let real_home = std::env::var_os("HOME")
        .and_then(|h| fs::canonicalize(h).ok())
        .is_some_and(|h| h == home);
    match target.category.as_str() {
        "electronCaches" => p.file_name().is_some_and(|n| n == "Cache") &&
            (below(library.join("Application Support")) || below(library.join("Containers"))),
        "appCaches" => ["Application Support/Adobe/Common/Media Cache Files", "Application Support/Spotify/PersistentCache/Storage", "Application Support/Telegram Desktop/tdata/user_data/cache", "Application Support/Telegram Desktop/tdata/user_data/media_cache", "Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data/cache", "Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data/media_cache", "Containers/com.tencent.tenvideo/Data/Library/Application Support/Download/video", "Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic", "Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE", "Containers/com.apple.Photos/Data/Library/Application Support/Photos Desktop/0"].iter().any(|s| within(library.join(s)))
            || (below(library.join("Group Containers/6N38VWS5BX.ru.keepcoder.Telegram")) && p.ends_with("postbox/media"))
            || (below(library.join("Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9")) && p.ends_with("Message/MessageTemp"))
            || (real_home && below(PathBuf::from("/Library/SystemMigration/History")) && p.ends_with("QuarantineRoot/private/var/db/dyld")),
        "iosBackups" => p.parent() == Some(library.join("Application Support/MobileSync/Backup").as_path()),
        "brokenPreferences" => p.parent() == Some(library.join("Preferences").as_path()) && p.extension().is_some_and(|e| e.eq_ignore_ascii_case("plist")),
        "brokenAgents" => p.extension().is_some_and(|e| e == "plist") && (p.parent() == Some(library.join("LaunchAgents").as_path()) || (real_home && ["/Library/LaunchAgents", "/Library/LaunchDaemons"].iter().any(|r| p.parent() == Some(Path::new(r))))),
        "mailDownloads" => below(library.join("Mail Downloads")) || below(library.join("Containers/com.apple.mail/Data/Library/Mail Downloads")),
        "mailTrash" => below(library.join("Mail")) && p.extension().is_some_and(|e| e == "emlx" || e == "emlxpart"),
        "quarantineLogs" => ["com.apple.LaunchServices.QuarantineEventsV2", "com.apple.LaunchServices.QuarantineEvents"].iter().any(|name| p == &library.join("Preferences").join(name)),
        "diagnosticLogs" => real_home && p == Path::new("/private/var/db/diagnostics"),
        "applications" => p.extension().is_some_and(|e| e == "app") && (below(home.join("Applications")) || (real_home && below("/Applications".into()))) && target.owner.as_deref().is_some_and(|o| !o.starts_with("com.apple.") && o != "local.cleanmymac.CleanMyMacLocal"),
        "mailAttachments" => below(library.join("Mail")),
        "diskImages" => below(home.into()) && p.extension().is_some_and(|e| ["dmg", "img", "sparseimage", "sparsebundle"].iter().any(|s| e.eq_ignore_ascii_case(s))),
        "downloads" => below(home.into()) && !within(library.clone()) && !within(home.join(".Trash")) && target.owner.as_deref().is_some_and(|o| ["com.apple.Safari", "com.google.Chrome", "com.tinyspeck.slackmacgap"].contains(&o)),
        "leftovers" => ["Caches", "Preferences", "Application Support", "Saved Application State", "Containers", "Logs", "Cookies", "LaunchAgents", "LaunchDaemons", "Internet Plug-Ins", "Plug-Ins", "PDF Services", "Help", "Group Containers", "Application Scripts"].iter().any(|s| below(library.join(s))) && !target.owner.as_deref().is_some_and(|o| o.starts_with("com.apple.")),
        "xcodeArchives" => below(library.join("Developer/Xcode/Archives")) && p.extension().is_some_and(|e| e == "xcarchive"),
        "deviceSupport" => ["iOS DeviceSupport", "macOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport"].iter().any(|s| below(library.join("Developer/Xcode").join(s))),
        "xcodeDocumentation" => below(library.join("Developer/Xcode/DocumentationCache")),
        "moduleCaches" => within(library.join("Developer/Xcode/DerivedData/ModuleCache.noindex")) || within(library.join("Developer/Xcode/DerivedData/SymbolCache.noindex")) || (below(library.join("Caches")) && p.components().any(|c| c.as_os_str().to_string_lossy().starts_with("org.llvm.clang"))) || within(library.join("Caches/com.apple.dt.Xcode")) || (real_home && darwin_root().is_some_and(|r| within(r) && p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("org.llvm.clang")))),
        "simulatorCaches" => p == &library.join("Developer/CoreSimulator/Caches"),
        "simulators" => p.parent() == Some(library.join("Developer/CoreSimulator/Devices").as_path()),
        "deviceLogs" => p == &library.join("Developer/Xcode/iOS Device Logs"),
        "darwinCaches" => real_home && darwin_root().is_some_and(|r| below(r)),
        "systemCaches" => real_home && (below("/Library/Caches".into()) || (below("/Library/SystemMigration/History".into()) && p.ends_with("QuarantineRoot/private/var/db/dyld")) || within("/System/Library/Caches/com.apple.coresymbolicationd".into())),
        "systemLogs" => real_home && (below("/Library/Logs".into()) || within("/private/var/log/asl".into()) || below("/private/var/log".into())),
        "deletedUsers" => real_home && p.parent() == Some(Path::new("/Users/Deleted Users")) && p.extension().is_some_and(|e| e.eq_ignore_ascii_case("dmg")),
        "trash" => below(home.join(".Trash")) || ["Mobile Documents/com~apple~CloudDocs/.Trash", "CloudStorage/iCloud Drive/.Trash", "Mobile Documents/.Trash"].iter().any(|s| below(library.join(s)))
            || (below(library.join("Mobile Documents")) && p.ancestors().any(|a| a.ends_with("Documents/.Trash")))
            || (real_home && p.starts_with("/Volumes") && p.ancestors().any(|a| a.file_name().is_some_and(|n| n == unsafe { libc::geteuid() }.to_string().as_str()) && a.parent().is_some_and(|r| r.file_name().is_some_and(|n| n == ".Trashes")))),
        "simulatorRuntimes" => real_home && (below("/Library/Developer/CoreSimulator/Volumes".into()) || below("/Library/Developer/CoreSimulator/Profiles/Runtimes".into()) || below("/Library/Developer/CoreSimulator/Images".into())),
        "documentVersions" => real_home && (p.starts_with("/.DocumentRevisions-V100") || (p.starts_with("/Volumes") && p.components().any(|c| c.as_os_str() == ".DocumentRevisions-V100"))),
        _ => false,
    }
}
fn darwin_root() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let mut buf = vec![0u8; 4096];
        let length = unsafe {
            libc::confstr(
                libc::_CS_DARWIN_USER_CACHE_DIR,
                buf.as_mut_ptr().cast(),
                buf.len(),
            )
        };
        if length > 0 && length <= buf.len() {
            let path = std::ffi::CStr::from_bytes_until_nul(&buf).ok()?;
            return fs::canonicalize(Path::new(std::ffi::OsStr::from_bytes(path.to_bytes()))).ok();
        }
    }
    None
}
