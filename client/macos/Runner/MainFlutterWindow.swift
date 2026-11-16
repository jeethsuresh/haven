import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let photosImport = FlutterMethodChannel(
      name: "cool.gravitas.haven/photos_import",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    photosImport.setMethodCallHandler { [weak self] call, result in
      guard let self = self,
            ["chooseLibrary", "chooseFolder", "chooseArchive", "chooseRestoreFolder"].contains(call.method) else {
        result(FlutterMethodNotImplemented)
        return
      }
      let panel = NSOpenPanel()
      let choosingLibrary = call.method == "chooseLibrary"
      let choosingArchive = call.method == "chooseArchive"
      let restoring = call.method == "chooseRestoreFolder"
      panel.title = restoring ? "Choose Local Photos Restore Folder" : "Choose Haven Storage Folder"
      panel.prompt = "Choose"
      panel.canChooseFiles = choosingLibrary || choosingArchive
      panel.canChooseDirectories = !panel.canChooseFiles
      panel.allowsMultipleSelection = false
      panel.treatsFilePackagesAsDirectories = false
      if choosingLibrary {
        panel.title = "Choose Apple Photos Library"
        panel.message = "Copy photos and videos, including hidden items, into this Haven repository."
        panel.allowedContentTypes = [UTType(filenameExtension: "photoslibrary") ?? .package]
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
      } else if choosingArchive {
        panel.title = "Choose Haven Photos Archive"
        panel.allowedContentTypes = [.gzip]
      }
      panel.beginSheetModal(for: self) { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        if restoring && !Self.supportsPhotosRestore(url) {
          result(FlutterError(
            code: "photos_restore_volume",
            message: "Choose a writable folder on a local APFS or Mac OS Extended volume.",
            details: nil
          ))
          return
        }
        result(url.resolvingSymlinksInPath().path)
      }
    }

    super.awakeFromNib()
  }

  private static func supportsPhotosRestore(_ url: URL) -> Bool {
    var volume = statfs()
    guard statfs(url.path, &volume) == 0 else { return false }
    let format = withUnsafeBytes(of: volume.f_fstypename) { bytes in
      String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
    return volume.f_flags & UInt32(MNT_LOCAL) != 0
      && volume.f_flags & UInt32(MNT_RDONLY) == 0
      && ["apfs", "hfs"].contains(format)
  }
}
